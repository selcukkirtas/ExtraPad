import CoreGraphics
import Foundation

/// Thread-safe view of the live sessions, for the network queue.
///
/// Sessions themselves live on the main actor because they create displays.
/// The server runs on its own queue and cannot reach into them - and reaching
/// anyway, with MainActor.assumeIsolated, traps the process outright.
///
/// So the main actor publishes handles here as sessions come and go, and the
/// server reads them under a lock. Only *creating* a session needs to go back
/// to the main actor, and that is the one path allowed to be asynchronous.
final class SessionRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var handles: [String: SessionHandles] = [:]
    private var order: [String] = []

    func handles(for deviceID: String) -> SessionHandles? {
        lock.lock(); defer { lock.unlock() }
        return handles[deviceID]
    }

    func set(_ value: SessionHandles, for deviceID: String) {
        lock.lock()
        if handles[deviceID] == nil { order.append(deviceID) }
        handles[deviceID] = value
        lock.unlock()
    }

    func remove(_ deviceID: String) {
        lock.lock()
        handles.removeValue(forKey: deviceID)
        order.removeAll { $0 == deviceID }
        lock.unlock()
    }

    /// The oldest session, which is what host-wide endpoints report on.
    var primary: SessionHandles? {
        lock.lock(); defer { lock.unlock() }
        guard let first = order.first else { return nil }
        return handles[first]
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return handles.count
    }
}
