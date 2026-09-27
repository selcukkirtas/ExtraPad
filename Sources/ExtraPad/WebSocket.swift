import CryptoKit
import Foundation

/// Just enough of RFC 6455 to push binary messages at a browser: the handshake,
/// server-to-client framing, and recognising a close from the client.
///
/// Hand-written for the same reason as the HTTP server - one direction, one
/// message type, no dependency worth adding. Note that server frames are never
/// masked, which removes the fiddliest half of the spec.
enum WebSocket {

    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Builds the 101 response for a client handshake, or nil if the request is
    /// not a valid WebSocket upgrade.
    static func handshakeResponse(requestHead: String) -> Data? {
        var key: String?
        var isUpgrade = false
        for line in requestHead.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("sec-websocket-key:") {
                key = line.split(separator: ":", maxSplits: 1)
                    .last?.trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("upgrade:"), lower.contains("websocket") {
                isUpgrade = true
            }
        }
        guard isUpgrade, let key else { return nil }

        let accept = Data(Insecure.SHA1.hash(data: Data((key + guid).utf8))).base64EncodedString()
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r

        """
        return Data(response.utf8)
    }

    /// Wraps a payload in a single unmasked binary frame.
    static func binaryFrame(_ payload: Data) -> Data {
        var frame = Data([0x82])          // FIN + opcode 0x2 (binary)
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((count >> 8) & 0xFF))
            frame.append(UInt8(count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((count >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }

    enum ClientMessage {
        case close
        /// "my canvas is wrong, send a full frame"
        case resync
        /// A touch, in the virtual display's own pixel coordinates.
        case input(phase: String, x: Int, y: Int)
    }

    /// Accumulates bytes and yields whole client frames.
    ///
    /// Client frames are masked, and a message can straddle two reads, so this
    /// has to buffer properly rather than peek at the first byte - which was
    /// enough while the only thing the browser ever sent was "resync".
    struct ClientFrameReader {
        private var buffer = Data()

        mutating func append(_ data: Data) { buffer.append(data) }

        mutating func next() -> ClientMessage? {
            while true {
                guard buffer.count >= 2 else { return nil }
                let bytes = [UInt8](buffer)
                let opcode = bytes[0] & 0x0F
                let masked = (bytes[1] & 0x80) != 0
                var length = Int(bytes[1] & 0x7F)
                var offset = 2

                if length == 126 {
                    guard bytes.count >= 4 else { return nil }
                    length = Int(bytes[2]) << 8 | Int(bytes[3])
                    offset = 4
                } else if length == 127 {
                    guard bytes.count >= 10 else { return nil }
                    length = 0
                    for i in 2..<10 { length = length << 8 | Int(bytes[i]) }
                    offset = 10
                }

                var maskKey: [UInt8] = []
                if masked {
                    guard bytes.count >= offset + 4 else { return nil }
                    maskKey = Array(bytes[offset..<(offset + 4)])
                    offset += 4
                }
                guard bytes.count >= offset + length else { return nil }

                var payload = Array(bytes[offset..<(offset + length)])
                if masked {
                    for i in payload.indices { payload[i] ^= maskKey[i % 4] }
                }
                buffer.removeFirst(offset + length)

                if opcode == 0x8 { return .close }
                guard opcode == 0x1 || opcode == 0x2 else { continue }   // ping/pong etc.
                if let message = parse(String(decoding: payload, as: UTF8.self)) { return message }
            }
        }

        /// Wire text: "R" to resync, or "<phase> <x> <y>" where phase is D, M or U.
        private func parse(_ text: String) -> ClientMessage? {
            if text == "R" { return .resync }
            let parts = text.split(separator: " ")
            guard parts.count == 3,
                  ["D", "M", "U"].contains(String(parts[0])),
                  let x = Int(parts[1]), let y = Int(parts[2]) else { return nil }
            return .input(phase: String(parts[0]), x: x, y: y)
        }
    }
}

extension WebSocket {
    /// Atlas wire format, all big-endian so the browser can read it with
    /// DataView's defaults:
    ///
    ///     u8  flags          bit 0 = keyframe
    ///     u8  regionCount
    ///     regionCount x { u16 sourceY, u16 destX, u16 destY, u16 width, u16 height }
    ///     ... JPEG bytes ...
    ///
    /// One image per frame, however many rectangles it carries: the client
    /// decodes once and then blits each region out of it.
    static func atlasPayload(regions: [(sourceY: Int, destX: Int, destY: Int, width: Int, height: Int)],
                             isKeyframe: Bool, jpeg: Data) -> Data {
        var data = Data(capacity: 2 + regions.count * 10 + jpeg.count)
        data.append(isKeyframe ? 1 : 0)
        data.append(UInt8(clamping: regions.count))
        for region in regions {
            for value in [region.sourceY, region.destX, region.destY,
                          region.width, region.height].map({ UInt16(clamping: $0) }) {
                data.append(UInt8(value >> 8))
                data.append(UInt8(value & 0xFF))
            }
        }
        data.append(jpeg)
        return data
    }
}

/// One screen update: the rectangles that changed, already framed for the wire.
struct PatchGroup {
    var messages: [Data]
    var isKeyframe: Bool
}

/// Fan-out for delta patches.
///
/// Unlike full frames, patches must not be silently dropped: a client that
/// misses one keeps a stale rectangle on screen until the next keyframe. So a
/// client that cannot keep up is marked desynchronised and skipped entirely
/// until a keyframe arrives, rather than being fed a partial update.
final class PatchBroadcaster {
    typealias SubscriberID = UInt64

    private let lock = NSLock()
    private var subscribers: [SubscriberID: (PatchGroup) -> Void] = [:]
    private var nextID: SubscriberID = 1

    private(set) var groupsPublished: UInt64 = 0

    var subscriberCount: Int {
        lock.lock(); defer { lock.unlock() }
        return subscribers.count
    }

    func subscribe(_ handler: @escaping (PatchGroup) -> Void) -> SubscriberID {
        lock.lock(); defer { lock.unlock() }
        let id = nextID
        nextID += 1
        subscribers[id] = handler
        return id
    }

    func unsubscribe(_ id: SubscriberID) {
        lock.lock(); subscribers.removeValue(forKey: id); lock.unlock()
    }

    func publish(_ group: PatchGroup) {
        lock.lock()
        groupsPublished += 1
        let sinks = Array(subscribers.values)
        lock.unlock()
        for sink in sinks { sink(group) }
    }
}
