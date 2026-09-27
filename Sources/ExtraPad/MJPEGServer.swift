import Foundation
import Network

/// Minimal HTTP/1.1 server serving the client page and an
/// `multipart/x-mixed-replace` JPEG stream. Hand-rolled rather than pulled from
/// a package so the project stays dependency-free and offline-buildable.
final class MJPEGServer {

    private static let boundary = "extrapadframe"

    private let config: Config
    private let broadcaster: FrameBroadcaster
    private let queue = DispatchQueue(label: "dev.extrapad.http")
    private var listener: NWListener?

    private let clientLock = NSLock()
    private var _activeStreams = 0

    var activeStreams: Int {
        clientLock.lock(); defer { clientLock.unlock() }
        return _activeStreams
    }

    init(config: Config, broadcaster: FrameBroadcaster) {
        self.config = config
        self.broadcaster = broadcaster
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Nagle would hold back the tail of a frame while we wait for the next.
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: config.port)!)
        listener.service = NWListener.Service(name: "ExtraPad", type: "_http._tcp")
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                FileHandle.standardError.write(
                    "[ExtraPad] HTTP sunucusu basarisiz: \(error)\n".data(using: .utf8)!)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || (isComplete && data == nil) {
                conn.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 16 * 1024 {
                    self.send(conn, status: "431 Request Header Fields Too Large", body: Data(), contentType: "text/plain")
                } else {
                    self.readRequest(conn, buffer: buffer)
                }
                return
            }

            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            self.route(conn, requestHead: head)
        }
    }

    private func route(_ conn: NWConnection, requestHead: String) {
        guard let requestLine = requestHead.split(separator: "\r\n").first else {
            conn.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            send(conn, status: "405 Method Not Allowed", body: Data("GET bekleniyor\n".utf8),
                 contentType: "text/plain; charset=utf-8")
            return
        }
        let path = String(parts[1].split(separator: "?").first ?? "/")

        switch path {
        case "/", "/index.html":
            let html = WebClient.page(width: config.width, height: config.height, fps: config.fps)
            send(conn, status: "200 OK", body: Data(html.utf8), contentType: "text/html; charset=utf-8")

        case "/stream":
            startStream(conn)

        case "/snapshot":
            if let frame = broadcaster.latestFrame {
                send(conn, status: "200 OK", body: frame, contentType: "image/jpeg")
            } else {
                send(conn, status: "503 Service Unavailable", body: Data("Henuz kare yok\n".utf8),
                     contentType: "text/plain; charset=utf-8")
            }

        case "/info":
            let json = """
            {"width":\(config.width),"height":\(config.height),"scale":\(config.scale),\
            "fps":\(config.fps),"quality":\(config.quality),\
            "framesPublished":\(broadcaster.framesPublished),\
            "activeStreams":\(activeStreams)}
            """
            send(conn, status: "200 OK", body: Data(json.utf8), contentType: "application/json")

        case "/favicon.ico":
            send(conn, status: "204 No Content", body: Data(), contentType: "image/x-icon")

        default:
            send(conn, status: "404 Not Found", body: Data("Yok\n".utf8),
                 contentType: "text/plain; charset=utf-8")
        }
    }

    private func send(_ conn: NWConnection, status: String, body: Data, contentType: String) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func startStream(_ conn: NWConnection) {
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: multipart/x-mixed-replace; boundary=\(Self.boundary)\r
        Cache-Control: no-store, no-cache, must-revalidate\r
        Pragma: no-cache\r
        Connection: close\r
        \r

        """
        conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in })

        clientLock.lock(); _activeStreams += 1; clientLock.unlock()

        // One frame in flight at a time. If the iPad cannot keep up we skip
        // frames instead of growing an unbounded send queue.
        let inFlight = Atomic(false)
        var subscription: FrameBroadcaster.SubscriberID?
        let finished = Atomic(false)

        let teardown: () -> Void = { [weak self] in
            guard let self, !finished.exchange(true) else { return }
            if let subscription { self.broadcaster.unsubscribe(subscription) }
            self.clientLock.lock(); self._activeStreams -= 1; self.clientLock.unlock()
            conn.cancel()
        }

        subscription = broadcaster.subscribe { frame in
            if finished.value { return }
            if inFlight.exchange(true) { return }

            var part = Data("--\(Self.boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(frame.count)\r\n\r\n".utf8)
            part.append(frame)
            part.append(Data("\r\n".utf8))

            conn.send(content: part, completion: .contentProcessed { error in
                inFlight.store(false)
                if error != nil { teardown() }
            })
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                teardown()
            default:
                break
            }
        }
    }
}

/// Tiny lock-guarded box; the capture and network queues both touch these flags.
final class Atomic<Value> {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func store(_ newValue: Value) {
        lock.lock(); storage = newValue; lock.unlock()
    }

    /// Sets a new value and returns the previous one.
    func exchange(_ newValue: Value) -> Value {
        lock.lock(); defer { lock.unlock() }
        let old = storage
        storage = newValue
        return old
    }
}
