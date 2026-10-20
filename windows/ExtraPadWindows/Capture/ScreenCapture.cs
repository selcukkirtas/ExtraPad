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
    public Size ScreenSize { get; }

    private static readonly ImageCodecInfo JpegCodec =
        ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);

    public ScreenCapture()
    {
        ScreenSize = Screen.PrimaryScreen?.Bounds.Size ?? new Size(1920, 1080);
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
                g.CopyFromScreen(0, 0, 0, 0, ScreenSize, CopyPixelOperation.SourceCopy);
            }

            using var ms = new MemoryStream();
            using var encoderParams = new EncoderParameters(1);
            encoderParams.Param[0] = new EncoderParameter(Encoder.Quality, quality);
            bitmap.Save(ms, JpegCodec, encoderParams);
            return ms.ToArray();
        }
        catch
        {
            // Screen capture can transiently fail around a lock/unlock or a
            // display topology change; the next tick tries again.
            return null;
        }
    }
}
