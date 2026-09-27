import CoreGraphics
import Foundation

/// macOS adds a freshly created virtual display in mirror mode, so capturing it
/// would just hand back a squashed copy of the built-in screen. These are public
/// CoreGraphics calls - only the display's creation needed a private API.
enum DisplayArrangement {

    /// Turns mirroring off and parks the display to the right of the main one,
    /// which is what "extended desktop" means in arrangement terms.
    @discardableResult
    static func makeExtended(_ displayID: CGDirectDisplayID) -> Bool {
        guard displayID != 0 else { return false }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }

        // kCGNullDirectDisplay as the mirror source == "mirror nothing".
        CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)

        // Park it past the right edge of every existing display, not just the
        // main one - otherwise it lands on top of an already-attached monitor
        // and macOS shuffles the arrangement to resolve the overlap.
        let origin = CGPoint(x: rightEdgeOfAllDisplays(excluding: displayID),
                             y: CGDisplayBounds(CGMainDisplayID()).minY)
        CGConfigureDisplayOrigin(config, displayID, Int32(origin.x), Int32(origin.y))

        // .forSession, not .permanently: the arrangement should disappear along
        // with the virtual display instead of littering the user's real setup.
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        if result != .success {
            FileHandle.standardError.write(
                "[ExtraPad] Ekran duzeni ayarlanamadi (kod \(result.rawValue))\n".data(using: .utf8)!)
            return false
        }
        return true
    }

    /// Rightmost x coordinate occupied by any active display except `excluding`.
    private static func rightEdgeOfAllDisplays(excluding: CGDirectDisplayID) -> CGFloat {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return CGDisplayBounds(CGMainDisplayID()).maxX
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return CGDisplayBounds(CGMainDisplayID()).maxX
        }
        return ids
            .filter { $0 != excluding }
            .map { CGDisplayBounds($0).maxX }
            .max() ?? CGDisplayBounds(CGMainDisplayID()).maxX
    }

    /// True when the display is currently showing another display's contents.
    static func isMirroring(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay
    }
}
