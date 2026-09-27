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

    /// True when the bytes coming back from the browser are a close frame.
    /// Anything else from the client is ignored - this stream is one-way.
    static func isCloseFrame(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        return (first & 0x0F) == 0x8
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
