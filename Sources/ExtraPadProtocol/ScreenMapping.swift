import CoreGraphics

/// Maps a touch on the client back to a pixel on the host's display.
///
/// The host's screen is drawn letterboxed inside whatever view the client has,
/// so the visible rectangle is almost never the view's own size. Mapping
/// against the view instead of the drawn rectangle skews every coordinate, and
/// the error grows towards the edges - the kind of bug that looks like
/// "the cursor is a bit off" rather than an obvious failure.
///
/// Kept here, next to the wire format, because it is part of the contract
/// between the two sides - and because it is pure arithmetic that can be tested
/// without a screen.
public struct ScreenMapping {

    public let hostSize: CGSize
    public let viewSize: CGSize

    public init(hostSize: CGSize, viewSize: CGSize) {
        self.hostSize = hostSize
        self.viewSize = viewSize
    }

    /// Scale and origin of the host's picture as actually drawn.
    public var drawnRect: CGRect {
        guard hostSize.width > 0, hostSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / hostSize.width, viewSize.height / hostSize.height)
        let drawn = CGSize(width: hostSize.width * scale, height: hostSize.height * scale)
        return CGRect(x: (viewSize.width - drawn.width) / 2,
                      y: (viewSize.height - drawn.height) / 2,
                      width: drawn.width, height: drawn.height)
    }

    /// The host pixel under a point in the client's view, or nil when the touch
    /// landed on the letterbox rather than on the picture.
    public func hostPixel(at point: CGPoint) -> (x: Int, y: Int)? {
        let rect = drawnRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let inside = CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)
        guard inside.x >= 0, inside.y >= 0,
              inside.x <= rect.width, inside.y <= rect.height else { return nil }

        let scale = rect.width / hostSize.width
        // Clamped because a touch exactly on the edge maps to one past the last
        // pixel, which the host would reject.
        let x = min(Int(inside.x / scale), Int(hostSize.width) - 1)
        let y = min(Int(inside.y / scale), Int(hostSize.height) - 1)
        return (x: max(x, 0), y: max(y, 0))
    }
}
