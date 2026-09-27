import Foundation

/// Remembers which hosts this device has already paired with.
///
/// What is remembered is the session cookie the host handed out when the code
/// was accepted - a credential, so it belongs in the Keychain rather than in
/// user defaults. The host's Bonjour name is the key, because its IP address
/// changes with the network and cannot identify it between launches.
enum PairingStore {

    private static let service = "dev.extrapad.client.pairing"
    private static let lastHostKey = "ExtraPadLastHost"

    /// The host to reconnect to on launch, so a returning user sees their
    /// screen rather than a list they have to pick from every time.
    static var lastHostID: String? {
        get { UserDefaults.standard.string(forKey: lastHostKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastHostKey) }
    }

    static func save(_ cookies: [String: String], for hostID: String) {
        var query = baseQuery(hostID)
        SecItemDelete(query as CFDictionary)
        guard let encoded = try? JSONEncoder().encode(cookies) else { return }
        query[kSecValueData as String] = encoded
        // Only readable while the device is unlocked, and never synced to
        // other devices: this authorises access to one Mac on one network.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess { return }

        NSLog("[ExtraPad] could not save pairing (OSStatus \(status))")
        #if DEBUG
        // The Keychain needs an application identifier, which the scripted
        // Simulator build cannot provide - simulator binaries reject a
        // re-signature with entitlements. A real Xcode build has them, so this
        // path exists purely so the flow can be exercised during development
        // and is compiled out of release builds.
        if status == errSecMissingEntitlement { self[debug: hostID] = cookies }
        #endif
    }

    static func cookies(for hostID: String) -> [String: String] {
        var query = baseQuery(hostID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            return decoded
        }
        #if DEBUG
        return debugStore[hostID] ?? [:]
        #else
        return [:]
        #endif
    }

    static func forget(_ hostID: String) {
        SecItemDelete(baseQuery(hostID) as CFDictionary)
        #if DEBUG
        self[debug: hostID] = nil
        #endif
        if lastHostID == hostID { lastHostID = nil }
    }

    #if DEBUG
    /// Development-only stand-in, kept in the app's own container.
    private static var debugStore: [String: [String: String]] {
        get {
            guard let raw = UserDefaults.standard.data(forKey: "ExtraPadDebugPairings"),
                  let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: raw)
            else { return [:] }
            return decoded
        }
        set {
            guard let encoded = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(encoded, forKey: "ExtraPadDebugPairings")
        }
    }

    private static subscript(debug hostID: String) -> [String: String]? {
        get { debugStore[hostID] }
        set {
            var store = debugStore
            store[hostID] = newValue
            debugStore = store
        }
    }
    #endif

    private static func baseQuery(_ hostID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: hostID]
    }
}
