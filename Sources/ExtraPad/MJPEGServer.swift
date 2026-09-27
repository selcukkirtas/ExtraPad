import Foundation
import Network

/// Minimal HTTP/1.1 server serving the client page and an
/// `multipart/x-mixed-replace` JPEG stream. Hand-rolled rather than pulled from
/// a package so the project stays dependency-free and offline-buildable.
final class MJPEGServer {

    private static let boundary = "extrapadframe"

    private var config: Config
    private let broadcaster: FrameBroadcaster
    private let patchBroadcaster: PatchBroadcaster
    let devices = DeviceRegistry()
    private let queue = DispatchQueue(label: "dev.extrapad.http")
    private var listener: NWListener?

    /// What the server actually pushed to one client. Tells apart "the stream
    /// stalled" from "the stream is fine but the browser is not rendering it".
    struct ClientStats {
        var address: String
        var framesSent: Int = 0
        var bytesSent: Int = 0
        var framesSkipped: Int = 0     // dropped because the client was still busy
        var startedAt = Date()
    }

    private let clientLock = NSLock()
    private var _clients: [UInt64: ClientStats] = [:]

    var activeStreams: Int {
        clientLock.lock(); defer { clientLock.unlock() }
        return _clients.count
    }

    var clientStats: [ClientStats] {
        clientLock.lock(); defer { clientLock.unlock() }
        return Array(_clients.values)
    }

    /// Addresses with a live connection right now, one entry each - a single
    /// device can hold more than one socket.
    var connectedAddresses: [String] {
        clientLock.lock(); defer { clientLock.unlock() }
        var seen: [String] = []
        for client in _clients.values {
            let address = client.address.replacingOccurrences(of: " (delta)", with: "")
            if !seen.contains(address) { seen.append(address) }
        }
        return seen.sorted()
    }

    /// Called when /set asks for new capture settings.
    var onSettingsChange: ((Double?, Int?) -> Void)?
    /// Called when a delta client needs a full frame to draw on top of.
    var onKeyframeRequest: (() -> Void)?
    /// Called with each touch coming back from a client.
    var onInput: ((String, Int, Int) -> Void)?
    /// Called when a client that might be mid-drag goes away.
    var onInputRelease: (() -> Void)?
    /// Delta-encoder counters, for /info.
    var deltaStatsProvider: (() -> DeltaEncoder.Stats)?
    var resetDeltaStats: (() -> Void)?

    init(config: Config, broadcaster: FrameBroadcaster, patchBroadcaster: PatchBroadcaster) {
        self.config = config
        self.broadcaster = broadcaster
        self.patchBroadcaster = patchBroadcaster
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
                    "[ExtraPad] HTTP server failed: \(error)\n".data(using: .utf8)!)
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
            send(conn, status: "405 Method Not Allowed", body: Data("GET expected\n".utf8),
                 contentType: "text/plain; charset=utf-8")
            return
        }
        let target = String(parts[1])
        var path = String(target.split(separator: "?").first ?? "/")
        let query: [String: String] = {
            guard let q = target.split(separator: "?").dropFirst().first else { return [:] }
            var out: [String: String] = [:]
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
            }
            return out
        }()

        // Everything behind the key: the stream shows the screen and the socket
        // drives the mouse, so neither may be reachable by address alone.
        var authorised = !config.auth
        var issueCookie = false
        if config.auth {
            if Auth.matches(query[Auth.queryName]) {
                authorised = true
                issueCookie = true
            } else if Auth.matches(Auth.cookieValue(in: requestHead)) {
                authorised = true
            }
        }

        // Unpaired devices get the code entry page instead of a bare refusal:
        // the whole point is that the address stays short enough to type.
        if !authorised, path == "/pair" {
            if Auth.checkPairingCode(query["code"]) {
                authorised = true
                issueCookie = true
                path = "/"
            } else {
                sendPage(conn, status: "200 OK", html: WebClient.pairingPage(wrong: true))
                return
            }
        }

        guard authorised else {
            let wantsPage = (path == "/" || path == "/index.html"
                             || path == "/delta" || path == "/mjpeg")
            if wantsPage {
                sendPage(conn, status: "200 OK", html: WebClient.pairingPage(wrong: false))
            } else {
                sendPage(conn, status: "401 Unauthorized", html: WebClient.unauthorisedPage())
            }
            return
        }

        // The key proves the client knows the secret. It cannot prove the client
        // is one of the owner's devices - so the owner is asked, once, per
        // device. A leaked key is then still not enough by itself.
        var deviceCookie: String?
        if config.auth {
            let existing = Auth.cookieValue(named: Auth.deviceCookieName, in: requestHead)
            let deviceID = existing ?? DeviceRegistry.newDeviceID()
            if existing == nil { deviceCookie = deviceID }

            let address: String
            if case let .hostPort(host, _) = conn.endpoint { address = "\(host)" } else { address = "unknown" }

            // `issueCookie` means this request carried the pairing code or the
            // key - the secret was just verified, so let the device in.
            if issueCookie {
                devices.approveOnSecret(id: deviceID, address: address)
            }

            switch devices.status(of: deviceID, address: address) {
            case .approved:
                break
            case .pending:
                sendPage(conn, status: "200 OK", html: WebClient.pendingApprovalPage(),
                         setCookie: issueCookie, deviceCookie: deviceCookie)
                return
            case .denied:
                sendPage(conn, status: "403 Forbidden", html: WebClient.deniedPage(),
                         deviceCookie: deviceCookie)
                return
            }
        }

        switch path {
        case "/", "/index.html", "/delta":
            // Delta is the default: same quality at roughly a tenth of the
            // bytes and several times the frame rate.
            let html = WebClient.deltaPage(width: config.width, height: config.height)
            send(conn, status: "200 OK", body: Data(html.utf8),
                 contentType: "text/html; charset=utf-8",
                 setCookie: issueCookie, deviceCookie: deviceCookie)

        case "/mjpeg":
            // Kept as a fallback: it needs no WebSocket, no canvas and no
            // JavaScript in the pixel path, so it works where delta will not.
            let html = WebClient.page(width: config.width, height: config.height,
                                      fps: config.fps, showHUD: config.hud)
            send(conn, status: "200 OK", body: Data(html.utf8),
                 contentType: "text/html; charset=utf-8", setCookie: issueCookie)

        case "/stream":
            startStream(conn)

        case "/version":
            let json = """
            {"protocol":\(ExtraPadProtocol.version),\
            "minimum":\(ExtraPadProtocol.minimumSupportedVersion)}
            """
            send(conn, status: "200 OK", body: Data(json.utf8), contentType: "application/json")

        case "/ws":
            // A client that names a version we cannot serve is refused clearly
            // rather than being left to misparse the stream.
            if let raw = query["v"], let clientVersion = Int(raw),
               !ExtraPadProtocol.canServe(clientVersion) {
                send(conn, status: "409 Conflict",
                     body: Data("Protocol \(clientVersion) not supported; host speaks \(ExtraPadProtocol.version)\n".utf8),
                     contentType: "text/plain; charset=utf-8")
                return
            }
            startWebSocket(conn, requestHead: requestHead)

        case "/snapshot":
            if let frame = broadcaster.latestFrame {
                send(conn, status: "200 OK", body: frame, contentType: "image/jpeg")
            } else {
                send(conn, status: "503 Service Unavailable", body: Data("No frame yet\n".utf8),
                     contentType: "text/plain; charset=utf-8")
            }

        case "/info":
            let clients = clientStats.map { c -> String in
                let seconds = max(Date().timeIntervalSince(c.startedAt), 0.001)
                let rate = Double(c.framesSent) / seconds
                return """
                {"address":"\(c.address)","framesSent":\(c.framesSent),\
                "framesSkipped":\(c.framesSkipped),"bytesSent":\(c.bytesSent),\
                "seconds":\(String(format: "%.1f", seconds)),\
                "fps":\(String(format: "%.1f", rate))}
                """
            }.joined(separator: ",")
            var delta = ""
            if let stats = deltaStatsProvider?() {
                let frames = max(stats.keyframes + stats.deltaFrames, 1)
                delta = """
                ,"delta":{"keyframes":\(stats.keyframes),"deltaFrames":\(stats.deltaFrames),\
                "avgKeyframeKB":\(String(format: "%.1f", Double(stats.keyframeBytes) / Double(max(stats.keyframes, 1)) / 1024)),\
                "avgDeltaKB":\(String(format: "%.1f", Double(stats.deltaBytes) / Double(max(stats.deltaFrames, 1)) / 1024)),\
                "avgRegionsPerFrame":\(String(format: "%.1f", Double(stats.regions) / Double(frames))),\
                "avgDirtyPct":\(String(format: "%.1f", 100 * stats.dirtyFractionSum / Double(max(stats.deltaFrames + stats.thresholdKeyframes, 1)))),\
                "keyframesByThreshold":\(stats.thresholdKeyframes),"keyframesRequested":\(stats.forcedKeyframes)}
                """
            }
            let json = """
            {"width":\(config.width),"height":\(config.height),"scale":\(config.scale),\
            "fps":\(config.fps),"quality":\(config.quality),\
            "framesPublished":\(broadcaster.framesPublished),\
            "activeStreams":\(activeStreams),"clients":[\(clients)],\
            "input":{"enabled":\(config.input),"permitted":\(InputInjector.isPermitted)}\(delta)}
            """
            send(conn, status: "200 OK", body: Data(json.utf8), contentType: "application/json")

        case "/resetstats":
            resetDeltaStats?()
            send(conn, status: "200 OK", body: Data("{\"ok\":true}".utf8), contentType: "application/json")

        case "/set":
            let quality = query["quality"].flatMap(Double.init)
            let fps = query["fps"].flatMap(Int.init)
            if quality == nil && fps == nil {
                send(conn, status: "400 Bad Request",
                     body: Data("Provide quality and/or fps\n".utf8),
                     contentType: "text/plain; charset=utf-8")
            } else {
                if let quality { config.quality = max(0.1, min(1.0, quality)) }
                if let fps { config.fps = max(1, min(60, fps)) }
                Config.remember(fps: fps == nil ? nil : config.fps,
                                quality: quality == nil ? nil : config.quality)
                onSettingsChange?(quality, fps)
                let body = "{\"quality\":\(config.quality),\"fps\":\(config.fps)}"
                send(conn, status: "200 OK", body: Data(body.utf8), contentType: "application/json")
            }

        case "/icon.png":
            // Cached hard on purpose: iOS fetches this once when the user adds
            // the page to the home screen.
            let icon = AppIcon.pngData
            var header = "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: image/png\r\n"
            header += "Content-Length: \(icon.count)\r\n"
            header += "Cache-Control: max-age=86400\r\n"
            header += "Connection: close\r\n\r\n"
            var out = Data(header.utf8)
            out.append(icon)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })

        case "/favicon.ico":
            send(conn, status: "204 No Content", body: Data(), contentType: "image/x-icon")

        default:
            // A bare "not found" on a phone browser reads as "the whole thing is
            // broken", so point the way back instead.
            sendPage(conn, status: "404 Not Found", html: WebClient.notFoundPage())
        }
    }

    private func sendPage(_ conn: NWConnection, status: String, html: String,
                          setCookie: Bool = false, deviceCookie: String? = nil) {
        send(conn, status: status, body: Data(html.utf8),
             contentType: "text/html; charset=utf-8",
             setCookie: setCookie, deviceCookie: deviceCookie)
    }

    private func send(_ conn: NWConnection, status: String, body: Data, contentType: String,
                      setCookie: Bool = false, deviceCookie: String? = nil) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        if setCookie { header += Auth.setCookieHeader }
        if let deviceCookie { header += Auth.deviceCookieHeader(deviceCookie) }
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - WebSocket delta stream

    private func startWebSocket(_ conn: NWConnection, requestHead: String) {
        guard let handshake = WebSocket.handshakeResponse(requestHead: requestHead) else {
            send(conn, status: "400 Bad Request", body: Data("WebSocket upgrade expected\n".utf8),
                 contentType: "text/plain; charset=utf-8")
            return
        }
        conn.send(content: handshake, completion: .contentProcessed { _ in })

        let clientID = UInt64(bitPattern: Int64(ObjectIdentifier(conn).hashValue))
        let address: String
        if case let .hostPort(host, _) = conn.endpoint { address = "\(host)" } else { address = "unknown" }
        clientLock.lock()
        _clients[clientID] = ClientStats(address: address + " (delta)")
        clientLock.unlock()

        let inFlight = Atomic(false)
        let desynced = Atomic(false)
        let finished = Atomic(false)
        // A keyframe is an order of magnitude bigger than a delta, so a client
        // that falls behind must not ask for one per frame - that buries the
        // very client that was already struggling.
        //
        // This is a time throttle rather than a "one pending request" latch,
        // because a latch deadlocks: if the keyframe it waits for is itself
        // dropped (the client was still busy when it arrived), the latch never
        // opens and the client is skipped silently forever.
        let lastKeyframeRequest = Atomic(Date.distantPast)
        let sendStartedAt = Atomic(Date.distantPast)

        func requestKeyframeIfDue() {
            let now = Date()
            guard now.timeIntervalSince(lastKeyframeRequest.value) > 0.75 else { return }
            lastKeyframeRequest.store(now)
            self.onKeyframeRequest?()
        }
        var subscription: PatchBroadcaster.SubscriberID?

        let teardown: () -> Void = { [weak self] in
            guard let self, !finished.exchange(true) else { return }
            if let subscription { self.patchBroadcaster.unsubscribe(subscription) }
            self.clientLock.lock(); self._clients.removeValue(forKey: clientID); self.clientLock.unlock()
            conn.cancel()
        }

        // The client's canvas is blank, and an idle screen produces no new
        // frames to build a keyframe from - so prime it with the last full
        // frame we already have, then ask for a fresh one.
        if let latest = broadcaster.latestFrame {
            let payload = WebSocket.atlasPayload(
                regions: [(sourceY: 0, destX: 0, destY: 0,
                           width: config.width * config.scale,
                           height: config.height * config.scale)],
                isKeyframe: true, showHUD: config.hud, jpeg: latest)
            conn.send(content: WebSocket.binaryFrame(payload), completion: .contentProcessed { _ in })
        }
        onKeyframeRequest?()

        subscription = patchBroadcaster.subscribe { [weak self] group in
            guard let self, !finished.value else { return }

            // A missed patch leaves a stale rectangle on the canvas forever, so
            // a client that falls behind is skipped until the next keyframe
            // rather than fed a partial update.
            if desynced.value && !group.isKeyframe {
                self.clientLock.lock()
                self._clients[clientID]?.framesSkipped += 1
                self.clientLock.unlock()
                requestKeyframeIfDue()
                return
            }
            if inFlight.value {
                // A send that never completes means the connection is wedged;
                // dropping it lets the client reconnect instead of staring at a
                // frozen picture.
                if Date().timeIntervalSince(sendStartedAt.value) > 5 {
                    teardown()
                    return
                }
                desynced.store(true)
                self.clientLock.lock()
                self._clients[clientID]?.framesSkipped += 1
                self.clientLock.unlock()
                requestKeyframeIfDue()
                return
            }
            inFlight.store(true)
            sendStartedAt.store(Date())
            desynced.store(false)

            // One write per screen update, however many rectangles it contains.
            var payload = Data()
            for message in group.messages { payload.append(WebSocket.binaryFrame(message)) }
            let size = payload.count

            conn.send(content: payload, completion: .contentProcessed { error in
                inFlight.store(false)
                if error != nil { teardown(); return }
                self.clientLock.lock()
                self._clients[clientID]?.framesSent += 1
                self._clients[clientID]?.bytesSent += size
                self.clientLock.unlock()
            })
        }

        // The browser sends resync requests and touches.
        var reader = WebSocket.ClientFrameReader()
        func readClient() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if error != nil || isComplete { self.onInputRelease?(); teardown(); return }
                if let data {
                    reader.append(data)
                    while let message = reader.next() {
                        switch message {
                        case .close:
                            self.onInputRelease?()
                            teardown()
                            return
                        case .resync:
                            requestKeyframeIfDue()
                        case let .input(phase, x, y):
                            self.onInput?(phase, x, y)
                        }
                    }
                }
                if !finished.value { readClient() }
            }
        }
        readClient()

        conn.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: teardown()
            default: break
            }
        }
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

        let clientID = UInt64(bitPattern: Int64(ObjectIdentifier(conn).hashValue))
        let address: String
        if case let .hostPort(host, _) = conn.endpoint {
            address = "\(host)"
        } else {
            address = "unknown"
        }
        clientLock.lock()
        _clients[clientID] = ClientStats(address: address)
        clientLock.unlock()

        // One frame in flight at a time. If the iPad cannot keep up we skip
        // frames instead of growing an unbounded send queue.
        let inFlight = Atomic(false)
        var subscription: FrameBroadcaster.SubscriberID?
        let finished = Atomic(false)

        let teardown: () -> Void = { [weak self] in
            guard let self, !finished.exchange(true) else { return }
            if let subscription { self.broadcaster.unsubscribe(subscription) }
            self.clientLock.lock(); self._clients.removeValue(forKey: clientID); self.clientLock.unlock()
            conn.cancel()
        }

        subscription = broadcaster.subscribe { [weak self] frame in
            guard let self, !finished.value else { return }
            if inFlight.exchange(true) {
                self.clientLock.lock()
                self._clients[clientID]?.framesSkipped += 1
                self.clientLock.unlock()
                return
            }

            var part = Data("--\(Self.boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(frame.count)\r\n\r\n".utf8)
            part.append(frame)
            part.append(Data("\r\n".utf8))

            let partSize = part.count
            conn.send(content: part, completion: .contentProcessed { error in
                inFlight.store(false)
                if error != nil { teardown(); return }
                self.clientLock.lock()
                self._clients[clientID]?.framesSent += 1
                self._clients[clientID]?.bytesSent += partSize
                self.clientLock.unlock()
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
