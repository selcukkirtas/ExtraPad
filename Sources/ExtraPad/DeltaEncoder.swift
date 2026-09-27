import CoreImage
import CoreVideo
import Foundation

/// Turns a captured frame into only the parts that changed since the last one.
///
/// Measurements on this project showed the link, not the iPad's CPU, is the
/// limit - so cutting bytes is the whole game. A typical desktop changes a few
/// percent of its pixels per frame (a cursor, a caret, one scrolling pane), and
/// sending just those regions is what makes full quality affordable.
///
/// The regions are deliberately *few and large* rather than many and small: the
/// client draws each one with a JavaScript call, and on an iPad 2 running a
/// home-screen web app there may be no JIT, so per-region overhead is the thing
/// to economise on - not bytes-per-region.
final class DeltaEncoder {

    struct Patch {
        var rect: CGRect          // top-left origin, pixels
        var jpeg: Data
        var isKeyframe: Bool
    }

    /// Comparison granularity. 64px keeps the dirty map cheap to compute while
    /// still isolating small changes like a text caret.
    private static let tileSize = 32

    /// Above this fraction of changed tiles, sending one full frame beats
    /// sending many rectangles plus their JPEG headers.
    private static let keyframeThreshold = 0.55

    /// More rectangles than this and we merge everything into one bounding box;
    /// past this point the per-rectangle overhead outweighs the pixels saved.
    private static let maxPatches = 12

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private var previous: [UInt8] = []
    private var previousWidth = 0
    private var previousHeight = 0
    private var forceKeyframe = true

    /// Makes the next frame a full-screen keyframe. Used when a client joins,
    /// since it has no earlier pixels to patch on top of.
    func requestKeyframe() { forceKeyframe = true }

    func encode(_ pixelBuffer: CVPixelBuffer, quality: Double) -> [Patch] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let sizeChanged = (width != previousWidth || height != previousHeight)

        if forceKeyframe || sizeChanged || previous.isEmpty {
            storePrevious(bytes: bytes, stride: stride, width: width, height: height)
            forceKeyframe = false
            guard let jpeg = encodeRegion(image, rect: CGRect(x: 0, y: 0, width: width, height: height),
                                          frameHeight: height, quality: quality) else { return [] }
            return [Patch(rect: CGRect(x: 0, y: 0, width: width, height: height),
                          jpeg: jpeg, isKeyframe: true)]
        }

        let dirty = dirtyTiles(bytes: bytes, stride: stride, width: width, height: height)
        storePrevious(bytes: bytes, stride: stride, width: width, height: height)

        let tilesAcross = (width + Self.tileSize - 1) / Self.tileSize
        let tilesDown = (height + Self.tileSize - 1) / Self.tileSize
        let dirtyCount = dirty.reduce(0) { $0 + ($1 ? 1 : 0) }
        if dirtyCount == 0 { return [] }

        // Too much changed: one full frame is cheaper than many rectangles.
        if Double(dirtyCount) / Double(tilesAcross * tilesDown) > Self.keyframeThreshold {
            guard let jpeg = encodeRegion(image, rect: CGRect(x: 0, y: 0, width: width, height: height),
                                          frameHeight: height, quality: quality) else { return [] }
            return [Patch(rect: CGRect(x: 0, y: 0, width: width, height: height),
                          jpeg: jpeg, isKeyframe: true)]
        }

        var rects = mergeRects(dirty: dirty, tilesAcross: tilesAcross, tilesDown: tilesDown,
                               width: width, height: height)
        if rects.count > Self.maxPatches, let bounding = rects.dropFirst().reduce(rects.first, { $0?.union($1) }) {
            rects = [bounding]
        }

        return rects.compactMap { rect in
            guard let jpeg = encodeRegion(image, rect: rect, frameHeight: height, quality: quality)
            else { return nil }
            return Patch(rect: rect, jpeg: jpeg, isKeyframe: false)
        }
    }

    // MARK: - Tile comparison

    private func dirtyTiles(bytes: UnsafePointer<UInt8>, stride: Int,
                            width: Int, height: Int) -> [Bool] {
        let tilesAcross = (width + Self.tileSize - 1) / Self.tileSize
        let tilesDown = (height + Self.tileSize - 1) / Self.tileSize
        var dirty = [Bool](repeating: false, count: tilesAcross * tilesDown)

        previous.withUnsafeBufferPointer { prev in
            guard let prevBase = prev.baseAddress else { return }
            for ty in 0..<tilesDown {
                let y0 = ty * Self.tileSize
                let rows = min(Self.tileSize, height - y0)
                for tx in 0..<tilesAcross {
                    let x0 = tx * Self.tileSize
                    let cols = min(Self.tileSize, width - x0)
                    let rowBytes = cols * 4
                    var changed = false
                    for row in 0..<rows {
                        let offset = (y0 + row) * stride + x0 * 4
                        // memcmp is SIMD-accelerated; this is the hot loop.
                        if memcmp(bytes + offset, prevBase + offset, rowBytes) != 0 {
                            changed = true
                            break
                        }
                    }
                    if changed { dirty[ty * tilesAcross + tx] = true }
                }
            }
        }
        return dirty
    }

    private func storePrevious(bytes: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int) {
        let total = stride * height
        if previous.count != total { previous = [UInt8](repeating: 0, count: total) }
        previous.withUnsafeMutableBufferPointer { buf in
            if let base = buf.baseAddress { memcpy(base, bytes, total) }
        }
        previousWidth = width
        previousHeight = height
    }

    // MARK: - Rectangle merging

    /// Horizontal runs of dirty tiles, then vertically merged when a run sits
    /// directly under an identical one. Cheap, and good enough: the shapes that
    /// actually occur (a cursor, a text line, a scrolling pane) are rectangles.
    private func mergeRects(dirty: [Bool], tilesAcross: Int, tilesDown: Int,
                            width: Int, height: Int) -> [CGRect] {
        struct Span { var x0: Int; var x1: Int; var y0: Int; var y1: Int }
        var open: [Span] = []
        var closed: [Span] = []

        for ty in 0..<tilesDown {
            var runs: [(Int, Int)] = []
            var tx = 0
            while tx < tilesAcross {
                if dirty[ty * tilesAcross + tx] {
                    let start = tx
                    while tx < tilesAcross && dirty[ty * tilesAcross + tx] { tx += 1 }
                    runs.append((start, tx - 1))
                } else {
                    tx += 1
                }
            }

            var stillOpen: [Span] = []
            for run in runs {
                if let index = open.firstIndex(where: { $0.x0 == run.0 && $0.x1 == run.1 && $0.y1 == ty - 1 }) {
                    var span = open.remove(at: index)
                    span.y1 = ty
                    stillOpen.append(span)
                } else {
                    stillOpen.append(Span(x0: run.0, x1: run.1, y0: ty, y1: ty))
                }
            }
            closed.append(contentsOf: open)
            open = stillOpen
        }
        closed.append(contentsOf: open)

        return closed.map { span in
            let x = span.x0 * Self.tileSize
            let y = span.y0 * Self.tileSize
            let w = min((span.x1 + 1) * Self.tileSize, width) - x
            let h = min((span.y1 + 1) * Self.tileSize, height) - y
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    // MARK: - JPEG

    /// `rect` uses top-left origin; CoreImage's is bottom-left, hence the flip.
    private func encodeRegion(_ image: CIImage, rect: CGRect,
                              frameHeight: Int, quality: Double) -> Data? {
        let ciRect = CGRect(x: rect.minX,
                            y: CGFloat(frameHeight) - rect.maxY,
                            width: rect.width, height: rect.height)
        let cropped = image.cropped(to: ciRect)
        // Crop keeps the original extent's origin; move it back to (0,0) so the
        // JPEG contains just the region.
        let moved = cropped.transformed(by: CGAffineTransform(translationX: -ciRect.minX,
                                                             y: -ciRect.minY))
        return ciContext.jpegRepresentation(
            of: moved,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        )
    }
}
