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

    /// One frame's worth of changes, packed into a single JPEG.
    ///
    /// Every region used to be its own image, which meant one
    /// Blob -> objectURL -> Image -> decode round trip per region in the
    /// browser. On an iPad 2 each of those costs 10-20ms, so at tens of regions
    /// per second the client fell behind and the picture lagged behind the
    /// mouse - while the server saw no backpressure at all, because Safari was
    /// happily draining the socket into its own buffer.
    ///
    /// Now the regions are stacked into one atlas image: the client decodes
    /// once per frame and blits each region out of it with a cheap, synchronous
    /// drawImage call.
    struct Atlas {
        struct Region {
            var sourceY: Int      // row in the atlas
            var dest: CGPoint     // where it goes on the canvas
            var size: CGSize
        }
        var regions: [Region]
        var jpeg: Data
        var isKeyframe: Bool
    }

    /// Comparison granularity. 64px keeps the dirty map cheap to compute while
    /// still isolating small changes like a text caret.
    private static let tileSize = 32

    /// Above this fraction of changed tiles, sending one full frame beats
    /// sending many rectangles plus their JPEG headers.
    private static let keyframeThreshold = 0.55

    /// Quality floor used when most of the screen is moving. Detail is wasted on
    /// content that is already blurred by motion, and a 270KB full frame takes
    /// long enough to send that the client falls behind, drops its backlog and
    /// reconnects - which asks for another full frame. That loop is what a
    /// fixed high quality produced here.
    private static let motionQuality = 0.45

    /// How many stale tiles to repaint per idle frame. The screen converges back
    /// to full quality in well under a second, and only while nothing is
    /// happening, so it never competes with real updates.
    private static let refreshTilesPerFrame = 48

    /// More rectangles than this and we merge everything into one bounding box;
    /// past this point the per-rectangle overhead outweighs the pixels saved.
    private static let maxPatches = 12

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Why frames are coming out the way they are. Without this you cannot
    /// tell a delta stream that is working from one that is quietly sending a
    /// full frame every time.
    struct Stats {
        var keyframes = 0
        var deltaFrames = 0
        var keyframeBytes = 0
        var deltaBytes = 0
        var regions = 0
        var dirtyFractionSum = 0.0
        var forcedKeyframes = 0      // asked for by a client
        var thresholdKeyframes = 0   // too much of the screen changed
    }

    private let statsLock = NSLock()
    private var _stats = Stats()

    var stats: Stats {
        statsLock.lock(); defer { statsLock.unlock() }
        return _stats
    }

    func resetStats() {
        statsLock.lock(); _stats = Stats(); statsLock.unlock()
    }

    private func record(_ body: (inout Stats) -> Void) {
        statsLock.lock(); body(&_stats); statsLock.unlock()
    }

    /// Tiles last transmitted below the requested quality. While the screen is
    /// idle these get repainted sharp, so motion costs detail only briefly.
    private var stale: [Bool] = []

    private var previous: [UInt8] = []
    private var previousWidth = 0
    private var previousHeight = 0
    private var forceKeyframe = true

    /// Makes the next frame a full-screen keyframe. Used when a client joins,
    /// since it has no earlier pixels to patch on top of.
    func requestKeyframe() { forceKeyframe = true }

    /// Full quality while little is moving, sliding down to `motionQuality`
    /// once a large part of the screen is changing every frame.
    private static func adaptiveQuality(base: Double, dirtyFraction: Double) -> Double {
        let easyLimit = 0.08
        guard dirtyFraction > easyLimit else { return base }
        let t = min((dirtyFraction - easyLimit) / (keyframeThreshold - easyLimit), 1.0)
        return base + (motionQuality - base) * t
    }

    func encode(_ pixelBuffer: CVPixelBuffer, quality: Double) -> Atlas? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let sizeChanged = (width != previousWidth || height != previousHeight)

        if forceKeyframe || sizeChanged || previous.isEmpty {
            storePrevious(bytes: bytes, stride: stride, width: width, height: height)
            forceKeyframe = false
            record { $0.forcedKeyframes += 1 }
            return keyframe(image, width: width, height: height,
                            quality: min(quality, Self.motionQuality), markStale: true)
        }

        let dirty = dirtyTiles(bytes: bytes, stride: stride, width: width, height: height)
        storePrevious(bytes: bytes, stride: stride, width: width, height: height)

        let tilesAcross = (width + Self.tileSize - 1) / Self.tileSize
        let tilesDown = (height + Self.tileSize - 1) / Self.tileSize
        ensureStaleMap(count: dirty.count)
        let dirtyCount = dirty.reduce(0) { $0 + ($1 ? 1 : 0) }
        if dirtyCount == 0 {
            return refreshPass(image, tilesAcross: tilesAcrossFor(width),
                               tilesDown: tilesDownFor(height),
                               width: width, height: height, quality: quality)
        }

        // Too much changed: one full frame is cheaper than many rectangles.
        let dirtyFraction = Double(dirtyCount) / Double(tilesAcross * tilesDown)
        record { $0.dirtyFractionSum += dirtyFraction }
        if dirtyFraction > Self.keyframeThreshold {
            record { $0.thresholdKeyframes += 1 }
            return keyframe(image, width: width, height: height,
                            quality: min(quality, Self.motionQuality), markStale: true)
        }

        var rects = mergeRects(dirty: dirty, tilesAcross: tilesAcross, tilesDown: tilesDown,
                               width: width, height: height)
        if rects.count > Self.maxPatches, let bounding = rects.dropFirst().reduce(rects.first, { $0?.union($1) }) {
            rects = [bounding]
        }

        let effective = Self.adaptiveQuality(base: quality, dirtyFraction: dirtyFraction)
        markStale(dirty: dirty, stale: effective < quality - 0.001)
        return packAtlas(image, rects: rects, frameHeight: height, quality: effective)
    }

    // MARK: - Progressive refresh

    private func tilesAcrossFor(_ width: Int) -> Int { (width + Self.tileSize - 1) / Self.tileSize }
    private func tilesDownFor(_ height: Int) -> Int { (height + Self.tileSize - 1) / Self.tileSize }

    private func ensureStaleMap(count: Int) {
        if stale.count != count { stale = [Bool](repeating: false, count: count) }
    }

    private func markStale(dirty: [Bool], stale shouldMark: Bool) {
        ensureStaleMap(count: dirty.count)
        for index in dirty.indices where dirty[index] {
            // A tile just sent at full quality is clean again.
            stale[index] = shouldMark
        }
    }

    /// Repaints tiles that were last sent at reduced quality, a batch at a time,
    /// using the idle bandwidth that would otherwise go unused.
    private func refreshPass(_ image: CIImage, tilesAcross: Int, tilesDown: Int,
                             width: Int, height: Int, quality: Double) -> Atlas? {
        var picked: [Bool] = [Bool](repeating: false, count: stale.count)
        var budget = Self.refreshTilesPerFrame
        for index in stale.indices where stale[index] && budget > 0 {
            picked[index] = true
            stale[index] = false
            budget -= 1
        }
        guard budget < Self.refreshTilesPerFrame else { return nil }

        let rects = mergeRects(dirty: picked, tilesAcross: tilesAcross, tilesDown: tilesDown,
                               width: width, height: height)
        guard !rects.isEmpty else { return nil }
        return packAtlas(image, rects: rects, frameHeight: height, quality: quality)
    }

    private func keyframe(_ image: CIImage, width: Int, height: Int,
                          quality: Double, markStale shouldMarkStale: Bool = false) -> Atlas? {
        if shouldMarkStale {
            ensureStaleMap(count: tilesAcrossFor(width) * tilesDownFor(height))
            for index in stale.indices { stale[index] = true }
        }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        guard let jpeg = encodeRegion(image, rect: full, frameHeight: height, quality: quality)
        else { return nil }
        record { $0.keyframes += 1; $0.keyframeBytes += jpeg.count; $0.regions += 1 }
        return Atlas(regions: [Atlas.Region(sourceY: 0, dest: .zero,
                                            size: CGSize(width: width, height: height))],
                     jpeg: jpeg, isKeyframe: true)
    }

    /// Stacks the changed rectangles into one column and encodes that as a
    /// single JPEG. Stacking (rather than real bin packing) keeps the layout
    /// trivial for both sides; the wasted width costs little because JPEG
    /// compresses the untouched margin to almost nothing.
    private func packAtlas(_ image: CIImage, rects: [CGRect],
                           frameHeight: Int, quality: Double) -> Atlas? {
        guard !rects.isEmpty else { return nil }

        let atlasWidth = rects.map(\.width).max() ?? 0
        let atlasHeight = rects.reduce(0) { $0 + $1.height }
        guard atlasWidth > 0, atlasHeight > 0 else { return nil }

        var composed: CIImage?
        var regions: [Atlas.Region] = []
        var cursorY: CGFloat = 0

        for rect in rects {
            // CoreImage's origin is bottom-left; ours is top-left.
            let ciRect = CGRect(x: rect.minX, y: CGFloat(frameHeight) - rect.maxY,
                                width: rect.width, height: rect.height)
            // Place each region so that atlas row 0 is the first rectangle.
            let destY = atlasHeight - cursorY - rect.height
            let piece = image
                .cropped(to: ciRect)
                .transformed(by: CGAffineTransform(translationX: -ciRect.minX + 0,
                                                   y: -ciRect.minY + destY))
            composed = composed.map { piece.composited(over: $0) } ?? piece
            regions.append(Atlas.Region(sourceY: Int(cursorY), dest: rect.origin, size: rect.size))
            cursorY += rect.height
        }

        guard let composed else { return nil }
        let atlasRect = CGRect(x: 0, y: 0, width: atlasWidth, height: atlasHeight)
        guard let jpeg = ciContext.jpegRepresentation(
            of: composed.cropped(to: atlasRect),
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        ) else { return nil }

        record { $0.deltaFrames += 1; $0.deltaBytes += jpeg.count; $0.regions += regions.count }
        return Atlas(regions: regions, jpeg: jpeg, isKeyframe: false)
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
