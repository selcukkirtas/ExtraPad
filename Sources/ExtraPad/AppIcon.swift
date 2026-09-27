import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Home-screen icon for the iPad. Drawn rather than shipped as a file so the
/// project stays a single buildable target with no resource bundle, and so the
/// icon survives however the app gets copied around.
///
/// iOS 9 ignores SVG and is unreliable with data: URIs in apple-touch-icon, so
/// this is served as a real PNG from /icon.png.
enum AppIcon {

    /// 180x180 is the largest size iOS asks for (iPad Retina @2x is 152, iPhone
    /// @3x is 180); iOS scales down from one oversized icon happily.
    static let pngData: Data = render(size: 180)

    private static func render(size: CGFloat) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: Int(size), height: Int(size),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Data() }

        // iOS applies its own rounded-corner mask, so draw a full-bleed square.
        ctx.setFillColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let unit = size / 180.0

        // Back display: the Mac.
        ctx.setFillColor(red: 0.33, green: 0.35, blue: 0.40, alpha: 1)
        ctx.fill(CGRect(x: 52 * unit, y: 66 * unit, width: 88 * unit, height: 62 * unit))

        // Front display: the iPad, overlapping to read as "a second screen".
        ctx.setFillColor(red: 0.38, green: 0.72, blue: 0.98, alpha: 1)
        ctx.fill(CGRect(x: 34 * unit, y: 44 * unit, width: 70 * unit, height: 52 * unit))

        // Stand.
        ctx.setFillColor(red: 0.33, green: 0.35, blue: 0.40, alpha: 1)
        ctx.fill(CGRect(x: 84 * unit, y: 54 * unit, width: 24 * unit, height: 8 * unit))

        guard let image = ctx.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return Data() }
        return out as Data
    }
}
