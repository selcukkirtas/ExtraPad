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
    /// The device's own name (`UIDevice.current.name`), sent by the native
    /// client so the virtual display it gets can say "iPad Air" instead of
    /// a slot number. The web client has no reliable equivalent - Safari's
    /// user agent does not distinguish iPad models - so this stays unset
    /// for it and the display falls back to its slot name.
    public static let deviceNameQuery = "name"
    public static let bonjourServiceType = "_extrapad._tcp"
}

/// Whether the Mac is actually in use, pushed to clients as it changes.
///
/// This exists because an iPad used as a second display has to be told to stop
/// being one. The client holds the iPad's screen awake for as long as frames
/// are worth looking at, and without a signal from the host "worth looking at"
/// never becomes false: the Mac gets locked, its owner walks away, and the iPad
/// sits there lit up all night showing the last frame it received.
///
/// Sent as a WebSocket text frame rather than inside the frame payload, because
/// the two formats carry nothing in common and a locked Mac has stopped
/// producing frames to piggyback on - which is exactly when this has to arrive.
public enum HostStatus: String {
    /// Somebody is at the Mac; keep the iPad's screen alive.
    case awake
    /// Locked, asleep, or the displays went dark. Nothing is being captured,
    /// and the client should let the iPad sleep on its own schedule.
    case locked

    private static let prefix = "S "

    public var wireText: String { Self.prefix + rawValue }

    public static func decode(_ text: String) -> HostStatus? {
        guard text.hasPrefix(prefix) else { return nil }
        return HostStatus(rawValue: String(text.dropFirst(prefix.count)))
    }
}
