namespace ExtraPadWindows.Networking;

/// <summary>
/// Mirrors Sources/ExtraPadProtocol/WireProtocol.swift. Must stay numerically
/// identical to the Mac host and the iPad clients - this is what lets an old
/// cached web client talk to a host it has never seen before.
/// </summary>
public static class WireProtocol
{
    public const int Atlas = 1;
    public const int Video = 2;

    /// This host only ever speaks the atlas (JPEG) dialect - no H.264 encoder
    /// here yet, so it never claims protocol 2.
    public const int Version = Atlas;
    public const int MinimumSupportedVersion = Atlas;

    public static bool CanServe(int clientVersion) =>
        clientVersion >= MinimumSupportedVersion && clientVersion <= Version;
}

public static class WireNames
{
    public const string AccessCookie = "extrapad";
    public const string DeviceCookie = "extrapad_device";
    public const string KeyQuery = "k";
    public const string VersionQuery = "v";
    public const string DeviceNameQuery = "name";
}

/// Whether the Windows machine is actually in use. See HostStatus.swift.
public enum HostStatus
{
    Awake,
    Locked
}

public static class HostStatusExtensions
{
    private const string Prefix = "S ";

    public static string WireText(this HostStatus status) =>
        Prefix + (status == HostStatus.Awake ? "awake" : "locked");
}
