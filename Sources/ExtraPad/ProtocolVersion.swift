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
enum ExtraPadProtocol {

    /// Bump on any change to the wire format that an older client cannot read:
    /// message layout, header size, flag meanings.
    ///
    /// 1 - JPEG atlas: 9-byte header, regions blitted from one image per frame.
    static let version = 1

    /// Lowest version this host can still serve. Kept equal to `version` until
    /// there is a second format to support.
    static let minimumSupportedVersion = 1

    static func canServe(_ clientVersion: Int) -> Bool {
        clientVersion >= minimumSupportedVersion && clientVersion <= version
    }
}
