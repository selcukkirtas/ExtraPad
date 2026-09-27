import Foundation
import ExtraPadProtocol

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
