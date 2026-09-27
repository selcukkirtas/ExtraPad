import CoreGraphics
import Foundation

/// Where the virtual display sits relative to the machine's real displays.
enum DisplayPosition: String, CaseIterable {
    case left, right, above, below

    var label: String {
        switch self {
        case .left:  return "Solda"
        case .right: return "Sagda"
        case .above: return "Ustte"
        case .below: return "Altta"
        }
    }
}

/// macOS adds a freshly created virtual display in mirror mode, so capturing it
/// would just hand back a squashed copy of the built-in screen. These are public
/// CoreGraphics calls - only the display's creation needed a private API.
enum DisplayArrangement {

    /// Turns mirroring off and parks the display on the requested side of the
    /// existing arrangement.
    @discardableResult
    static func arrange(_ displayID: CGDirectDisplayID, position: DisplayPosition) -> Bool {
        guard displayID != 0 else { return false }

        let ourSize = CGDisplayBounds(displayID).size
        let others = boundsOfDisplays(excluding: displayID)
        guard !others.isEmpty else { return false }

        // Union of everything already on screen, so the new display lands next
        // to the whole arrangement rather than on top of an attached monitor.
        let union = others.dropFirst().reduce(others[0]) { $0.union($1) }
        let main = CGDisplayBounds(CGMainDisplayID())

        let origin: CGPoint
        switch position {
        case .right: origin = CGPoint(x: union.maxX, y: main.minY)
        case .left:  origin = CGPoint(x: union.minX - ourSize.width, y: main.minY)
        case .below: origin = CGPoint(x: main.minX, y: union.maxY)
        case .above: origin = CGPoint(x: main.minX, y: union.minY - ourSize.height)
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }

        // kCGNullDirectDisplay as the mirror source == "mirror nothing".
        CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
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

    private static func boundsOfDisplays(excluding: CGDirectDisplayID) -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.filter { $0 != excluding }.map { CGDisplayBounds($0) }
    }

    /// True when the display is currently showing another display's contents.
    static func isMirroring(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay
    }
}
