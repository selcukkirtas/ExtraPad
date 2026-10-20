using System.Runtime.InteropServices;

namespace ExtraPadWindows.Capture;

/// Mirrors the Mac host's InputInjector: turns the D/M/U touch phases coming
/// off the WebSocket into cursor movement and clicks. Coordinates arrive
/// already in the captured screen's own pixel space (see toDisplay() in the
/// client JS), so no scaling happens here.
public static class InputInjector
{
    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, nint extraInfo);

    private const uint MouseEventLeftDown = 0x0002;
    private const uint MouseEventLeftUp = 0x0004;

    private static bool isDown;

    public static void Handle(string phase, int x, int y)
    {
        SetCursorPos(x, y);
        switch (phase)
        {
            case "D":
                mouse_event(MouseEventLeftDown, 0, 0, 0, 0);
                isDown = true;
                break;
            case "U":
                mouse_event(MouseEventLeftUp, 0, 0, 0, 0);
                isDown = false;
                break;
            // "M" just moves the cursor, already done above.
        }
    }

    /// Matches releaseIfHeld() on the Mac side - called when a client goes
    /// away mid-drag, so a dropped connection cannot leave the mouse pinned
    /// down.
    public static void ReleaseIfHeld()
    {
        if (!isDown) return;
        mouse_event(MouseEventLeftUp, 0, 0, 0, 0);
        isDown = false;
    }
}
