import Foundation
import CoreGraphics
import Combine

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
    @Published private(set) var image: CGImage?
    @Published private(set) var framesPerSecond: Double = 0
    @Published private(set) var megabitsPerSecond: Double = 0

    private let baseURL: URL
    private let hostID: String
    private let session: URLSession
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

    init(baseURL: URL, hostID: String) {
        self.baseURL = baseURL
        self.hostID = hostID
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        self.session = URLSession(configuration: configuration)
        restoreSavedPairing()

        video.onFrame = { [weak self] frame in
            Task { @MainActor in self?.present(frame) }
        }
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
            await openStream()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        wantsConnection = false
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
        components?.scheme = "ws"
        // Ask for the best the host offers; it refuses anything it cannot
        // serve, so this cannot silently produce an unreadable stream.
        negotiatedVersion = hostProtocolVersion
        components?.queryItems = [URLQueryItem(name: WireNames.versionQuery,
                                               value: String(negotiatedVersion))]
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
                    if case let .data(data) = message { self.handle(data) }
                    self.receive()
                case .failure(let error):
                    guard self.socket != nil, self.wantsConnection else { return }
                    await self.scheduleReconnect(after: error)
                }
            }
        }
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
