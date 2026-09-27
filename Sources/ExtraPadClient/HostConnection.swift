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
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var image: CGImage?
    @Published private(set) var framesPerSecond: Double = 0
    @Published private(set) var megabitsPerSecond: Double = 0

    private let baseURL: URL
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private let canvas = ScreenCanvas(size: CGSize(width: 1024, height: 768))

    private var frameCount = 0
    private var byteCount = 0
    private var windowStart = Date()

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        self.session = URLSession(configuration: configuration)
    }

    /// Tries the host without a code first: a device that has paired before
    /// still holds a cookie, and asking again would be pointless friction.
    func begin() async {
        state = .connecting
        if await canReachScreen() {
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
            await openStream()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        state = .idle
    }

    // MARK: - Streaming

    private func canReachScreen() async -> Bool {
        guard let url = URL(string: baseURL.absoluteString + "/version") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func openStream() async {
        var components = URLComponents(url: baseURL.appendingPathComponent("ws"),
                                       resolvingAgainstBaseURL: false)
        components?.scheme = "ws"
        components?.queryItems = [URLQueryItem(name: WireNames.versionQuery,
                                               value: String(WireProtocol.version))]
        guard let url = components?.url else {
            state = .failed("Could not build the stream address.")
            return
        }
        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        state = .streaming
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
                    guard self.socket != nil else { return }
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func handle(_ data: Data) {
        byteCount += data.count
        guard let message = AtlasMessage.decode(data) else { return }
        if let picture = canvas.apply(message) {
            image = picture
            frameCount += 1
        }
        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed >= 1 {
            framesPerSecond = Double(frameCount) / elapsed
            megabitsPerSecond = Double(byteCount) * 8 / elapsed / 1_000_000
            frameCount = 0
            byteCount = 0
            windowStart = Date()
        }
    }

    // MARK: - Input

    /// Touch coordinates in the host display's own pixel space.
    func send(phase: String, x: Int, y: Int) {
        socket?.send(.string("\(phase) \(x) \(y)")) { _ in }
    }

    var displaySize: CGSize { canvas.size }
}
