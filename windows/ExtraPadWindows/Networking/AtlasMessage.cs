namespace ExtraPadWindows.Networking;

/// Mirrors Sources/ExtraPadProtocol/AtlasMessage.swift. Wire format:
///
///     u8  flags          bit 0 = keyframe, bit 1 = show the diagnostic strip
///     u8  regionCount
///     regionCount x { u16 sourceY, u16 destX, u16 destY, u16 width, u16 height }
///     ... JPEG bytes ...
///
/// Big-endian throughout so a browser can read it with DataView's defaults.
public sealed class AtlasMessage
{
    public readonly record struct Region(int SourceY, int DestX, int DestY, int Width, int Height);

    public required IReadOnlyList<Region> Regions { get; init; }
    public required bool IsKeyframe { get; init; }
    public required bool ShowsDiagnostics { get; init; }
    public required byte[] Jpeg { get; init; }

    private const int HeaderSize = 2;
    private const int RegionSize = 10;

    public byte[] Encoded()
    {
        using var ms = new MemoryStream(HeaderSize + Regions.Count * RegionSize + Jpeg.Length);
        ms.WriteByte((byte)((IsKeyframe ? 1 : 0) | (ShowsDiagnostics ? 2 : 0)));
        ms.WriteByte((byte)Math.Clamp(Regions.Count, 0, 255));
        foreach (var region in Regions)
        {
            foreach (var value in new[] { region.SourceY, region.DestX, region.DestY, region.Width, region.Height })
            {
                var clamped = (ushort)Math.Clamp(value, 0, ushort.MaxValue);
                ms.WriteByte((byte)(clamped >> 8));
                ms.WriteByte((byte)(clamped & 0xFF));
            }
        }
        ms.Write(Jpeg);
        return ms.ToArray();
    }
}
