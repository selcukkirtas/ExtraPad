import AppKit
import ApplicationServices
import CoreGraphics

/// Turns touches on the iPad into mouse events on the virtual display.
///
/// Coordinates arrive in the virtual display's own pixel space (0,0 at its top
/// left) and are offset by that display's position in the global arrangement -
/// which the user can move, so it is read fresh each time rather than cached.
///
/// Posting synthetic events needs Accessibility permission. Without it macOS
/// silently swallows every event, so this checks up front and says so rather
/// than looking broken.
final class InputInjector {

    enum Phase: String {
        case down = "D"
        case move = "M"
        case up   = "U"
    }

    private let displayID: CGDirectDisplayID
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonDown = false

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    /// True when macOS will actually deliver the events we post.
    static var isPermitted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that offers to open the Accessibility settings.
    @discardableResult
    static func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func handle(phase: Phase, x: Int, y: Int) {
        let bounds = CGDisplayBounds(displayID)
        guard !bounds.isNull else { return }

        // The stream is in pixels; the arrangement is in points. On this
        // display they are the same (scale 1), but clamping keeps a malformed
        // message from throwing the cursor onto another screen.
        let point = CGPoint(
            x: bounds.minX + min(max(CGFloat(x), 0), bounds.width - 1),
            y: bounds.minY + min(max(CGFloat(y), 0), bounds.height - 1))

        let type: CGEventType
        switch phase {
        case .down:
            buttonDown = true
            type = .leftMouseDown
        case .move:
            type = buttonDown ? .leftMouseDragged : .mouseMoved
        case .up:
            buttonDown = false
            type = .leftMouseUp
        }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left)
        else { return }
        event.post(tap: .cghidEventTap)
    }

    /// Releases the button if a client vanishes mid-drag, so the Mac is not
    /// left with a stuck mouse button.
    func releaseIfHeld() {
        guard buttonDown else { return }
        buttonDown = false
        let location = CGEvent(source: nil)?.location ?? .zero
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}
