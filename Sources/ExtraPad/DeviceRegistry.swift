import Foundation

/// Per-device approval, decided by the person sitting at the Mac.
///
/// The access key alone answers "does this client know the address and secret".
/// It cannot answer "is this one of my devices" - and that is the question
/// worth asking now that a client can drive the mouse. Matching iCloud accounts
/// would answer it, but Safari gives a web page nothing about the Apple ID, and
/// the CloudKit route needs a native app, which iOS 9 rules out. So the Mac
/// asks its owner instead.
///
/// A device is remembered by a random id we hand it in a cookie. That is not an
/// identity - it is a capability - but combined with the key and a human
/// approval it means a leaked key is not enough on its own.
final class DeviceRegistry {

    struct Device: Codable {
        var id: String
        var address: String
        var firstSeen: Date
        var lastSeen: Date
    }

    enum Status {
        case approved
        case pending
        case denied
    }

    private static let approvedKey = "ExtraPadApprovedDevices"
    private static let deniedKey = "ExtraPadDeniedDevices"

    private let lock = NSLock()
    private var approved: [String: Device]
    private var denied: Set<String>
    private var pending: Set<String> = []

    /// Called on the main actor when a new device shows up and needs a decision.
    var onApprovalNeeded: ((Device) -> Void)?

    init() {
        approved = Self.load(Self.approvedKey)
        denied = Set(UserDefaults.standard.stringArray(forKey: Self.deniedKey) ?? [])
    }

    /// Issues an id for a client that has none yet.
    static func newDeviceID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func status(of id: String, address: String) -> Status {
        lock.lock()
        if denied.contains(id) {
            lock.unlock()
            return .denied
        }
        if var device = approved[id] {
            device.lastSeen = Date()
            device.address = address
            approved[id] = device
            lock.unlock()
            return .approved
        }
        let isNew = !pending.contains(id)
        pending.insert(id)
        lock.unlock()

        if isNew {
            let device = Device(id: id, address: address, firstSeen: Date(), lastSeen: Date())
            onApprovalNeeded?(device)
        }
        return .pending
    }

    /// Approves without asking. Used when the client just proved it knows the
    /// pairing code: the secret has been checked, so making the owner confirm
    /// the same thing again is friction, not security. The prompt stays for the
    /// case it was meant for - a device that turned up already holding a cookie.
    func approveOnSecret(id: String, address: String) {
        lock.lock()
        let existing = approved[id]
        pending.remove(id)
        denied.remove(id)
        approved[id] = Device(id: id, address: address,
                              firstSeen: existing?.firstSeen ?? Date(), lastSeen: Date())
        let snapshot = approved
        let deniedSnapshot = denied
        lock.unlock()
        Self.save(snapshot, key: Self.approvedKey)
        UserDefaults.standard.set(Array(deniedSnapshot), forKey: Self.deniedKey)
    }

    func approve(_ device: Device) {
        lock.lock()
        pending.remove(device.id)
        denied.remove(device.id)
        approved[device.id] = device
        let snapshot = approved
        let deniedSnapshot = denied
        lock.unlock()
        Self.save(snapshot, key: Self.approvedKey)
        UserDefaults.standard.set(Array(deniedSnapshot), forKey: Self.deniedKey)
    }

    func deny(_ device: Device) {
        lock.lock()
        pending.remove(device.id)
        approved.removeValue(forKey: device.id)
        denied.insert(device.id)
        let snapshot = approved
        let deniedSnapshot = denied
        lock.unlock()
        Self.save(snapshot, key: Self.approvedKey)
        UserDefaults.standard.set(Array(deniedSnapshot), forKey: Self.deniedKey)
    }

    var approvedDevices: [Device] {
        lock.lock(); defer { lock.unlock() }
        return approved.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    func forgetAll() {
        lock.lock()
        approved.removeAll()
        denied.removeAll()
        pending.removeAll()
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: Self.approvedKey)
        UserDefaults.standard.removeObject(forKey: Self.deniedKey)
    }

    private static func load(_ key: String) -> [String: Device] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Device].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save(_ devices: [String: Device], key: String) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
