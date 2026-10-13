import Foundation
import Security

/// Trial and license state, checked against LemonSqueezy's hosted license API.
///
/// There is no backend of our own here on purpose: LemonSqueezy already does
/// exactly what this needs - issue a key at checkout, activate it against one
/// named instance, and let that instance be looked up again by the buyer's
/// email if the key itself is lost. Building that ourselves would be a second
/// product.
///
/// The trial is a real LemonSqueezy license too, not a date stamped into
/// UserDefaults. A local-only trial is reset by one `defaults delete` or a
/// fresh install - no friction at all, and no way to tell "a new customer"
/// from "the same person again" to put a stop to it. Routing the trial
/// through the same $0 checkout as a purchase means starting one requires an
/// email LemonSqueezy actually collects, and the 14 days are enforced by
/// LemonSqueezy's own key expiry rather than a clock this Mac controls.
enum License {

    enum State: Equatable {
        case unlicensed
        case trial(daysLeft: Int)
        case licensed
    }

    enum ActivationError: LocalizedError {
        case invalidKey
        case alreadyActivatedElsewhere
        case network(String)
        case serverRejected(String)

        var errorDescription: String? {
            switch self {
            case .invalidKey:
                return "That license key doesn't look right. Check it and try again."
            case .alreadyActivatedElsewhere:
                return "This key is already active on another Mac. Deactivate it there first, "
                     + "or use the same email to recover which Mac that is."
            case .network(let message):
                return "Could not reach the license server: \(message)"
            case .serverRejected(let message):
                return message
            }
        }
    }

    // MARK: - Configuration

    static let buyURL = URL(string: "https://extrapad.app/#pricing")!
    /// The $0 "ExtraPad Trial" product's checkout link - a real LemonSqueezy
    /// checkout, just with nothing to pay. Collects the buyer's email and
    /// issues a 14-day license key the same way a purchase issues a
    /// lifetime one.
    static let trialCheckoutURL = URL(string: "https://rainborealis.lemonsqueezy.com/checkout/buy/a642e602-8902-4cfc-b46a-685a746009f5")!

    private static let apiBase = URL(string: "https://api.lemonsqueezy.com/v1/licenses")!

    /// LemonSqueezy's timestamps carry microsecond fractional seconds
    /// ("...21:48:19.000000Z"). The plain `ISO8601DateFormatter()` default
    /// options do not parse that - it fails silently and returns nil, which
    /// read as "no expiry" and turned every trial into a lifetime license.
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Current state

    /// Read synchronously from what was cached at the last successful
    /// activation or validation - never blocks on the network. `refresh()`
    /// is what actually talks to LemonSqueezy.
    static var state: State {
        guard storedKey != nil else { return .unlicensed }
        guard let expiresAt = storedExpiresAt else { return .licensed }
        let daysLeft = Int(ceil(expiresAt.timeIntervalSinceNow / 86400))
        return daysLeft > 0 ? .trial(daysLeft: daysLeft) : .unlicensed
    }

    /// Whether the app is allowed to create displays right now.
    static var isUsable: Bool {
        switch state {
        case .licensed, .trial: return true
        case .unlicensed: return false
        }
    }

    // MARK: - Activation

    static func activate(key: String) async -> Result<Void, ActivationError> {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.invalidKey) }

        var request = URLRequest(url: apiBase.appendingPathComponent("activate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = "license_key=\(urlEncode(trimmed))&instance_name=\(urlEncode(instanceName))"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.network("No response"))
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.network("Could not read the response"))
            }
            let activated = json["activated"] as? Bool ?? false
            guard http.statusCode == 200, activated,
                  let instance = json["instance"] as? [String: Any],
                  let instanceID = instance["id"] as? String
            else {
                let message = (json["error"] as? String) ?? ""
                if message.localizedCaseInsensitiveContains("activation limit") {
                    return .failure(.alreadyActivatedElsewhere)
                }
                return .failure(.serverRejected(message.isEmpty ? "The license server refused this key." : message))
            }
            let expiresAt = (json["license_key"] as? [String: Any])
                .flatMap { $0["expires_at"] as? String }
                .flatMap { dateFormatter.date(from: $0) }
            store(key: trimmed, instanceID: instanceID, expiresAt: expiresAt)
            return .success(())
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// Releases this Mac's activation so the same key can be used elsewhere -
    /// the explicit alternative to waiting for LemonSqueezy's own cleanup.
    static func deactivate() async {
        guard let key = storedKey, let instanceID = storedInstanceID else { return }
        var request = URLRequest(url: apiBase.appendingPathComponent("deactivate"))
        request.httpMethod = "POST"
        let body = "license_key=\(urlEncode(key))&instance_id=\(urlEncode(instanceID))"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        _ = try? await URLSession.shared.data(for: request)
        clearStored()
    }

    /// Re-checks the stored key against the server. Called occasionally, not
    /// on every launch - LemonSqueezy's own cache means this is cheap, but a
    /// revoked, refunded, or now-expired license should not take forever to
    /// take effect. LemonSqueezy itself decides `valid` based on expiry, so
    /// a trial key past its 14 days comes back invalid with no extra logic
    /// needed here.
    @discardableResult
    static func refresh() async -> Bool {
        guard let key = storedKey, let instanceID = storedInstanceID else { return false }
        var request = URLRequest(url: apiBase.appendingPathComponent("validate"))
        request.httpMethod = "POST"
        let body = "license_key=\(urlEncode(key))&instance_id=\(urlEncode(instanceID))"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["valid"] as? Bool == true
        else {
            clearStored()
            return false
        }
        let expiresAt = (json["license_key"] as? [String: Any])
            .flatMap { $0["expires_at"] as? String }
            .flatMap { dateFormatter.date(from: $0) }
        store(key: key, instanceID: instanceID, expiresAt: expiresAt)
        return true
    }

    private static func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    /// What LemonSqueezy shows the buyer as "which Mac is this" when they
    /// look up their activations - the actual machine name beats a UUID.
    private static var instanceName: String {
        Host.current().localizedName ?? "a Mac"
    }

    // MARK: - Storage

    /// The Keychain, not UserDefaults: a license key is a credential, and
    /// uninstalling by dragging the app to the Trash should not silently
    /// orphan it - this makes "reinstall and the key still works" the normal
    /// case rather than something the buyer has to ask support for.
    private static let service = "dev.extrapad.license"

    private static var storedKey: String? {
        keychainRead(account: "key")
    }
    private static var storedInstanceID: String? {
        keychainRead(account: "instanceID")
    }
    private static var storedExpiresAt: Date? {
        keychainRead(account: "expiresAt").flatMap { dateFormatter.date(from: $0) }
    }

    private static func store(key: String, instanceID: String, expiresAt: Date?) {
        keychainWrite(account: "key", value: key)
        keychainWrite(account: "instanceID", value: instanceID)
        if let expiresAt {
            keychainWrite(account: "expiresAt", value: dateFormatter.string(from: expiresAt))
        } else {
            keychainDelete(account: "expiresAt")
        }
    }

    private static func clearStored() {
        keychainDelete(account: "key")
        keychainDelete(account: "instanceID")
        keychainDelete(account: "expiresAt")
    }

    private static func keychainRead(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainWrite(account: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    private static func keychainDelete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
