import Foundation

/// Fan-out point between the single capture callback and any number of HTTP
/// clients. Latest-frame-wins: a slow iPad gets fewer frames, never a backlog.
final class FrameBroadcaster {
    typealias SubscriberID = UInt64

    private let lock = NSLock()
    private var subscribers: [SubscriberID: (Data) -> Void] = [:]
    private var nextID: SubscriberID = 1
    private var latest: Data?

    private(set) var framesPublished: UInt64 = 0

    var subscriberCount: Int {
        lock.lock(); defer { lock.unlock() }
        return subscribers.count
    }

    /// Registers a sink and immediately hands it the most recent frame so the
    /// iPad shows something without waiting up to 1/fps seconds.
    func subscribe(_ handler: @escaping (Data) -> Void) -> SubscriberID {
        lock.lock()
        let id = nextID
        nextID += 1
        subscribers[id] = handler
        let primer = latest
        lock.unlock()
        if let primer { handler(primer) }
        return id
    }

    func unsubscribe(_ id: SubscriberID) {
        lock.lock(); subscribers.removeValue(forKey: id); lock.unlock()
    }

    func publish(_ frame: Data) {
        lock.lock()
        latest = frame
        framesPublished += 1
        let sinks = Array(subscribers.values)
        lock.unlock()
        for sink in sinks { sink(frame) }
    }

    var latestFrame: Data? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }
}
