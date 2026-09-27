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

    /// Version 1 - JPEG atlas. Changed rectangles packed into one image per
    /// frame. The only thing Safari on iOS 9 can decode, so the web client is
    /// permanently on this.
    public static let atlas = 1

    /// Version 2 - H.264. Inter-frame prediction done properly by a hardware
    /// codec instead of by hand with tile diffing, which needs a native client.
    public static let video = 2

    /// What a client gets if it asks for the best on offer.
    public static let version = video

    /// Oldest version still served. The web client depends on this staying at
    /// `atlas`: it cannot be upgraded, because the browser it runs in cannot.
    public static let minimumSupportedVersion = atlas

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
