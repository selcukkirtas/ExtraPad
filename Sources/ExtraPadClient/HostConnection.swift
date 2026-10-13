import Foundation
import CoreGraphics
import Combine
import UIKit

/// Pairs with a host and then streams its screen.
///
/// Pairing and streaming share one URLSession so the cookie the host sets when
/// the code is accepted is attached automatically to the WebSocket upgrade -
/// which is exactly how the web client already works.
@MainActor
final class HostConnection: ObservableObject {

    enum State: Equatable {
        case idle
        case needsCode
        case wrongCode
        case connecting
        case streaming
        /// Lost the socket but still trying. Distinct from `failed` because the
        /// last picture stays on screen and the user need do nothing.
        case reconnecting(attempt: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// What the Mac last said about itself. Drives the wake lock and the
    /// overlay; starts optimistic because a host too old to say anything is
    /// one that is running.
    @Published private(set) var hostStatus: HostStatus = .awake
    @Published private(set) var image: CGImage?
    @Published private(set) var framesPerSecond: Double = 0
    @Published private(set) var megabitsPerSecond: Double = 0

    private let baseURL: URL
    private let hostID: String
    private let tlsFingerprint: String?
    /// Recreated on every reconnect, not reused across the connection's whole
    /// lifetime. URLSession caches TLS session tickets per instance, and a
    /// ticket cut before the host last restarted is one the host's new process
    /// no longer recognises - resuming it then fails the handshake the same
    /// way every time, which is a wedged "trying to reconnect" that never
    /// clears on its own rather than the one retry it should have taken.
    private var session: URLSession
    private var trust: PinnedTrust?
    private var socket: URLSessionWebSocketTask?
    private let canvas = ScreenCanvas(size: CGSize(width: 1024, height: 768))
    private let video = VideoDecoder()
    /// Which format this connection settled on. The host serves both, so this
    /// is decided by what it agreed to rather than assumed.
    private var negotiatedVersion = WireProtocol.atlas

    private var frameCount = 0
    private var byteCount = 0
    private var windowStart = Date()

    private var reconnectAttempt = 0
    private var wantsConnection = false
    private var hostProtocolVersion = WireProtocol.atlas

    private(set) var isEncrypted = false

    private var wakeLock: AnyCancellable?
    private var orientationObserver: NSObjectProtocol?
    /// What the host last built the display for. Compared against on every
    /// rotation notification, because that notification fires for face-up/
    /// face-down too - only an actual width/height swap is worth a reconnect.
    private var lastKnownScreenSize: CGSize = HostConnection.currentScreenSize

    /// `UIScreen.main.bounds` stopped rotating with the interface back in
    /// iOS 8 - it stays fixed in the device's native orientation no matter
    /// which way the app is actually facing, which is why the display kept
    /// coming up in the same shape it started in regardless of how the iPad
    /// was held. The key window's bounds are what actually track rotation.
    private static var currentScreenSize: CGSize {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        return window?.bounds.size ?? UIScreen.main.bounds.size
    }

    init(baseURL: URL, hostID: String, tlsFingerprint: String? = nil) {
        self.baseURL = baseURL
        self.hostID = hostID
        self.tlsFingerprint = tlsFingerprint
        self.isEncrypted = baseURL.scheme == "https"
        let (session, trust) = Self.makeSession(baseURL: baseURL, tlsFingerprint: tlsFingerprint)
        self.session = session
        self.trust = trust
        restoreSavedPairing()

        video.onFrame = { [weak self] frame in
            Task { @MainActor in self?.present(frame) }
        }

        // The iPad's own auto-lock is left alone except while there is
        // something live on screen. Holding it off permanently is what forced
        // Auto-Lock to Never, and that is how a locked Mac ended up with an
        // iPad burning next to it all night.
        wakeLock = Publishers.CombineLatest($state, $hostStatus)
            .map { state, status in state == .streaming && status == .awake }
            .removeDuplicates()
            .sink { keepAwake in
                UIApplication.shared.isIdleTimerDisabled = keepAwake
            }

        // The host sizes the virtual display once, at connect time - turning
        // the iPad after that needs a fresh connection to tell it the screen
        // changed shape. Portrait and landscape otherwise worked only by
        // accident, whichever one happened to be current when the app
        // launched.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.handleOrientationChange() }
        }
    }

    deinit {
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
        }
    }

    /// Debounced against the rotation animation, and against the
    /// notification firing for orientations that don't change the screen's
    /// shape (face-up, face-down, unknown).
    private func handleOrientationChange() async {
        try? await Task.sleep(nanoseconds: 350_000_000)
        let newSize = Self.currentScreenSize
        guard newSize != lastKnownScreenSize else { return }
        lastKnownScreenSize = newSize
        guard state == .streaming else { return }
        socket?.cancel()
        socket = nil
        await openStream()
    }

    /// A self-signed certificate is refused by the default trust evaluation,
    /// so the session is given a delegate that checks the fingerprint instead.
    /// Without a fingerprint there is nothing to check against and the
    /// connection stays plain.
    private static func makeSession(baseURL: URL,
                                    tlsFingerprint: String?) -> (URLSession, PinnedTrust?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        if let tlsFingerprint, baseURL.scheme == "https" {
            let pinned = PinnedTrust(fingerprint: tlsFingerprint)
            return (URLSession(configuration: configuration, delegate: pinned, delegateQueue: nil), pinned)
        }
        return (URLSession(configuration: configuration), nil)
    }

    @MainActor
    private func present(_ frame: CGImage) {
        image = frame
        frameCount += 1
        updateRates()
    }

    /// A previous pairing is replayed into the session's cookie jar, so a
    /// returning device goes straight to the screen. The cookie lives in the
    /// Keychain; the session's own storage is ephemeral and does not survive a
    /// launch.
    /// Both cookies matter. The access cookie says the secret was checked; the
    /// device cookie is how the host recognises this iPad as one it has already
    /// been told to trust. Restoring only the first makes the host treat a
    /// returning device as a brand new one and hold it for approval - which
    /// shows up as a WebSocket that answers 200 instead of upgrading.
    private static let persistedCookies = [WireNames.accessCookie, WireNames.deviceCookie]

    private func restoreSavedPairing() {
        guard let host = baseURL.host else { return }
        for (name, value) in PairingStore.cookies(for: hostID)
        where Self.persistedCookies.contains(name) {
            guard let cookie = HTTPCookie(properties: [
                .name: name, .value: value, .domain: host, .path: "/",
            ]) else { continue }
            session.configuration.httpCookieStorage?.setCookie(cookie)
        }
    }

    private func rememberPairing() {
        guard let stored = session.configuration.httpCookieStorage?.cookies(for: baseURL)
        else { return }
        let wanted = stored.filter { Self.persistedCookies.contains($0.name) }
        guard !wanted.isEmpty else { return }
        PairingStore.save(Dictionary(uniqueKeysWithValues: wanted.map { ($0.name, $0.value) }),
                          for: hostID)
        PairingStore.lastHostID = hostID
    }

    func forgetPairing() {
        PairingStore.forget(hostID)
    }

    /// Tries the host without a code first: a device that has paired before
    /// still holds a cookie, and asking again would be pointless friction.
    func begin() async {
        wantsConnection = true
        state = .connecting
        if await canReachScreen() {
            rememberPairing()
            await openStream()
        } else {
            state = .needsCode
        }
    }

    func submit(code: String) async {
        state = .connecting
        var components = URLComponents(url: baseURL.appendingPathComponent("pair"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "code", value: code)]
        guard let url = components?.url else {
            state = .failed("Could not build the pairing address.")
            return
        }
        do {
            let (data, _) = try await session.data(from: url)
            let body = String(decoding: data, as: UTF8.self)
            if body.contains("not right") {
                state = .wrongCode
                return
            }
            wantsConnection = true
            rememberPairing()
            // Ask what the host speaks before opening the stream. Without this
            // a client that has just paired falls back to the oldest format,
            // because the version is only learned on the path that skips
            // pairing entirely.
            _ = await canReachScreen()
            await openStream()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        wantsConnection = false
        hostStatus = .awake
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        state = .idle
    }

    // MARK: - Streaming

    /// A 200 is not enough to conclude anything: the pairing page and the
    /// "waiting for approval" page are both 200. Only a real version payload
    /// means this client is actually allowed through.
    private func canReachScreen() async -> Bool {
        guard let url = URL(string: baseURL.absoluteString + "/version") else { return false }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hostVersion = json["protocol"] as? Int else { return false }
            guard WireProtocol.canServe(hostVersion) else { return false }
            hostProtocolVersion = min(hostVersion, WireProtocol.version)
            return true
        } catch {
            return false
        }
    }

    private func openStream() async {
        var components = URLComponents(url: baseURL.appendingPathComponent("ws"),
                                       resolvingAgainstBaseURL: false)
        components?.scheme = (baseURL.scheme == "https") ? "wss" : "ws"
        // Ask for the best the host offers; it refuses anything it cannot
        // serve, so this cannot silently produce an unreadable stream.
        negotiatedVersion = hostProtocolVersion
        let screenSize = Self.currentScreenSize
        components?.queryItems = [
            URLQueryItem(name: WireNames.versionQuery, value: String(negotiatedVersion)),
            URLQueryItem(name: WireNames.deviceNameQuery, value: UIDevice.current.name),
            // Whatever shape the screen is right now - portrait or landscape,
            // the host sizes the virtual display to match. Safari sends this
            // too; the native client simply never had before.
            URLQueryItem(name: "size", value: "\(Int(screenSize.width))x\(Int(screenSize.height))"),
        ]
        guard let url = components?.url else {
            state = .failed("Could not build the stream address.")
            return
        }
        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        state = .streaming
        reconnectAttempt = 0
        windowStart = Date()
        receive()
    }

    private func receive() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .data(let data): self.handle(data)
                    case .string(let text): self.handle(text: text)
                    @unknown default: break
                    }
                    self.receive()
                case .failure(let error):
                    guard self.socket != nil, self.wantsConnection else { return }
                    await self.scheduleReconnect(after: error)
                }
            }
        }
    }

    /// The host only ever says one thing in words: whether it is in use. An
    /// unrecognised line is ignored rather than treated as an error, so a
    /// future host can add another without breaking this version.
    private func handle(text: String) {
        guard let status = HostStatus.decode(text) else { return }
        hostStatus = status
        // The last frame was the Mac's screen. Leaving it up on an iPad while
        // the Mac itself is locked shows exactly what the lock was hiding - so
        // it goes, and the host sends a fresh keyframe when it comes back.
        if status == .locked { image = nil }
    }

    private func handle(_ data: Data) {
        byteCount += data.count

        if negotiatedVersion >= WireProtocol.video {
            guard let message = VideoMessage.decode(data) else { return }
            // Frames arrive from the decoder's callback, so the rate is counted
            // there rather than here.
            video.handle(message)
            updateRates()
            return
        }

        guard let message = AtlasMessage.decode(data) else { return }
        if let picture = canvas.apply(message) {
            image = picture
            frameCount += 1
        }
        updateRates()
    }

    private func updateRates() {
        let elapsed = Date().timeIntervalSince(windowStart)
        guard elapsed >= 1 else { return }
        framesPerSecond = Double(frameCount) / elapsed
        megabitsPerSecond = Double(byteCount) * 8 / elapsed / 1_000_000
        frameCount = 0
        byteCount = 0
        windowStart = Date()
    }

    /// Wi-Fi drops, the Mac sleeps, the app is backgrounded. None of those
    /// should end with a dead screen and a button to press - the client keeps
    /// the last picture up and retries with a widening gap.
    private func scheduleReconnect(after error: Error) async {
        socket?.cancel()
        socket = nil
        reconnectAttempt += 1
        state = .reconnecting(attempt: reconnectAttempt)

        // Give up asking politely after a while and tell the user something is
        // actually wrong, rather than spinning forever.
        guard reconnectAttempt <= 20 else {
            state = .failed(error.localizedDescription)
            return
        }
        let delay = min(Double(reconnectAttempt) * 0.5, 5.0)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard wantsConnection else { return }

        // A fresh session for the retry, not the one that just failed: a
        // URLSession keeps its TLS session tickets for as long as it lives,
        // and a ticket cut before the host last restarted its process is one
        // the new process will not recognise. Resuming it then fails the
        // handshake identically on every attempt - stuck "reconnecting"
        // rather than the one retry this should have taken. restoreSavedPairing
        // puts the cookies back since the new session's jar starts empty.
        let (freshSession, freshTrust) = Self.makeSession(baseURL: baseURL, tlsFingerprint: tlsFingerprint)
        session = freshSession
        trust = freshTrust
        restoreSavedPairing()

        if await canReachScreen() {
            await openStream()
        } else {
            // The pairing was revoked while we were away.
            state = .needsCode
        }
    }

    // MARK: - Input

    /// Touch coordinates in the host display's own pixel space.
    func send(phase: String, x: Int, y: Int) {
        socket?.send(.string("\(phase) \(x) \(y)")) { _ in }
    }

    /// Where touches are mapped to. With video the frame itself is the
    /// authority, since the host's resolution arrives in the parameter sets.
    var displaySize: CGSize {
        if negotiatedVersion >= WireProtocol.video, let image {
            return CGSize(width: image.width, height: image.height)
        }
        return canvas.size
    }
}
