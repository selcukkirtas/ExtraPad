import Foundation

/// Wire protocol identity, shared by every client.
///
/// This exists because of a failure already seen in practice: iOS caches the
/// page behind a home-screen shortcut, so an iPad can be running a client from
/// a build several versions older than the host it is talking to. Without a
/// version to compare, the symptom is a blank or subtly wrong screen with no
/// error anywhere.
///
/// It matters more once a native client ships, since an App Store app updates
/// on its own schedule and will routinely be older or newer than the host.
public enum WireProtocol {

    /// Bump on any change to the wire format that an older client cannot read:
    /// message layout, header size, flag meanings.
    ///
    /// 1 - JPEG atlas: 2-byte header plus 10 bytes per region, regions blitted
    ///     out of one image per frame.
    public static let version = 1

    /// Lowest version this host can still serve. Kept equal to `version` until
    /// there is a second format to support.
    public static let minimumSupportedVersion = 1

    public static func canServe(_ clientVersion: Int) -> Bool {
        clientVersion >= minimumSupportedVersion && clientVersion <= version
    }
}

/// Names that both sides have to agree on. Shared rather than retyped, because
/// a mismatch here fails as "mysteriously unauthorised" rather than as an error.
public enum WireNames {
    public static let accessCookie = "extrapad"
    public static let deviceCookie = "extrapad_device"
    public static let keyQuery = "k"
    public static let versionQuery = "v"
    public static let bonjourServiceType = "_extrapad._tcp"
}
