import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// Keeps the picture the host has sent so far and applies each update to it.
///
/// The stream is incremental: a frame carries only the rectangles that changed,
/// so the client has to hold the whole screen and paint onto it. A bitmap
/// context is exactly that, and drawing a decoded region into it is cheap.
final class ScreenCanvas {

    private(set) var size: CGSize
    private var context: CGContext?

    init(size: CGSize) {
        self.size = size
        rebuild()
    }

    func resize(to newSize: CGSize) {
        guard newSize != size, newSize.width > 0, newSize.height > 0 else { return }
        size = newSize
        rebuild()
    }

    private func rebuild() {
        context = CGContext(data: nil,
                            width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.setFillColor(UIColor.black.cgColor)
        context?.fill(CGRect(origin: .zero, size: size))
    }

    /// Applies one frame. Returns the picture to show, or nil if the message
    /// could not be used.
    func apply(_ message: AtlasMessage) -> CGImage? {
        guard context != nil else { return nil }
        guard let source = CGImageSourceCreateWithData(message.jpeg as CFData, nil),
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        // A keyframe covers everything; the canvas is sized from it so a host
        // that changes resolution does not need a separate message.
        if message.isKeyframe, let region = message.regions.first {
            resize(to: CGSize(width: region.width, height: region.height))
        }
        guard let ctx = self.context else { return nil }

        for region in message.regions {
            guard let piece = atlas.cropping(to: CGRect(x: 0, y: region.sourceY,
                                                        width: region.width,
                                                        height: region.height))
            else { continue }
            // CoreGraphics draws from the bottom left; the wire format is top
            // left, like the screen it came from.
            let destination = CGRect(x: region.destX,
                                     y: Int(size.height) - region.destY - region.height,
                                     width: region.width, height: region.height)
            ctx.draw(piece, in: destination)
        }
        return ctx.makeImage()
    }
}
