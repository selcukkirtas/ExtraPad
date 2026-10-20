using System.Drawing;
using System.Drawing.Imaging;
using System.Windows.Forms;

namespace ExtraPadWindows.Capture;

/// v1: mirrors the primary display rather than creating a new virtual one -
/// same fallback the Mac host uses when EPVirtualDisplay isn't available.
/// A real second display (an IddCx-backed virtual monitor) is the planned
/// next step; this is the piece that proves the network/protocol side works
/// end to end without waiting on that driver integration.
public sealed class ScreenCapture
{
    public Size ScreenSize { get; private set; }

    /// Which physical/virtual monitor is being captured - a machine with
    /// more than one display (e.g. a headless box once a virtual display
    /// driver is installed) has no reliable way to know which one is
    /// "right" without being told. Exposed so the tray menu can show a
    /// picker instead of guessing.
    public string CurrentDeviceName { get; private set; } = "";

    /// Where the captured monitor actually sits in the virtual desktop's
    /// coordinate space. On a single-monitor machine this is (0,0), but with
    /// more than one display a monitor is routinely offset - e.g. a display
    /// to its left puts this one's origin at a positive X. CopyFromScreen
    /// takes virtual-desktop coordinates, so capturing from a hardcoded
    /// (0,0) on such a machine grabs whatever happens to be at the *virtual
    /// desktop's* origin - often empty desktop background - rather than the
    /// intended monitor at all.
    private Point origin;

    private static readonly ImageCodecInfo JpegCodec =
        ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);

    public ScreenCapture(int initialIndex = -1)
    {
        var screens = Screen.AllScreens;
        ApplyBounds(initialIndex >= 0 && initialIndex < screens.Length ? screens[initialIndex] : Screen.PrimaryScreen);
    }

    /// Every connected display right now, in a form the tray menu can list
    /// without reaching into System.Windows.Forms itself.
    public static IReadOnlyList<(int Index, string DeviceName, Rectangle Bounds, bool IsPrimary)> AllDisplays()
    {
        var screens = Screen.AllScreens;
        var result = new List<(int, string, Rectangle, bool)>();
        for (var i = 0; i < screens.Length; i++)
        {
            result.Add((i, screens[i].DeviceName, screens[i].Bounds, screens[i].Primary));
        }
        return result;
    }

    /// Switches which monitor gets captured. Falls back to the primary
    /// display if the index no longer exists (a display can disappear
    /// between launches, or a driver can renumber them).
    public void SelectDisplay(int index)
    {
        var screens = Screen.AllScreens;
        ApplyBounds(index >= 0 && index < screens.Length ? screens[index] : Screen.PrimaryScreen);
    }

    private void ApplyBounds(Screen? screen)
    {
        var bounds = screen?.Bounds ?? new Rectangle(0, 0, 1920, 1080);
        origin = bounds.Location;
        ScreenSize = bounds.Size;
        CurrentDeviceName = screen?.DeviceName ?? "(none found)";
    }

    /// Grabs the current frame and JPEG-encodes it. Returns null if nothing
    /// could be captured (e.g. the session has no desktop right now).
    public byte[]? CaptureJpeg(long quality)
    {
        try
        {
            using var bitmap = new Bitmap(ScreenSize.Width, ScreenSize.Height, PixelFormat.Format24bppRgb);
            using (var g = Graphics.FromImage(bitmap))
            {
                g.CopyFromScreen(origin.X, origin.Y, 0, 0, ScreenSize, CopyPixelOperation.SourceCopy);
            }

            using var ms = new MemoryStream();
            using var encoderParams = new EncoderParameters(1);
            encoderParams.Param[0] = new EncoderParameter(Encoder.Quality, quality);
            bitmap.Save(ms, JpegCodec, encoderParams);
            return ms.ToArray();
        }
        catch (Exception ex)
        {
            // Screen capture can transiently fail around a lock/unlock or a
            // display topology change; the next tick tries again. Logged but
            // throttled - at 15fps a persistent failure would otherwise
            // flood the console with an identical line several times a
            // second.
            var now = DateTime.UtcNow;
            if (now - lastErrorLogged > TimeSpan.FromSeconds(5))
            {
                lastErrorLogged = now;
                Console.WriteLine($"[ExtraPad] capture of {CurrentDeviceName} failed: {ex.GetType().Name}: {ex.Message}");
            }
            return null;
        }
    }

    private DateTime lastErrorLogged = DateTime.MinValue;
}
