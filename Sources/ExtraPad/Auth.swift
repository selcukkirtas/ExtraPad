import Foundation
import ExtraPadProtocol

/// Shared-secret access control for the local network.
///
/// Anyone who can reach the port can otherwise watch the screen and - since
/// touch input landed - drive the mouse. That needs a gate.
///
/// The shape is dictated by the client: Safari on iOS 9. No fetch, no modern
/// crypto, and JavaScript cannot set headers on a WebSocket handshake. What it
/// does have is cookies, and the browser attaches them to same-origin WebSocket
/// upgrades automatically. So: the key travels once in the URL, the server
/// hands back a cookie, and every later request - page, stream, socket - is
/// authorised by that cookie.
///
/// Honest about what this is: a shared secret over plain HTTP on a LAN. It stops
/// someone who simply knows the address. It does not stop someone who can read
/// your network traffic, because the key and the screen both travel in the
/// clear. TLS would fix that, but iOS 9 makes a self-signed certificate painful
/// enough that it would cost more than it buys here.
enum Auth {

    private static let defaultsKey = "ExtraPadAccessKey"
    private static let codeKey = "ExtraPadPairingCode"
    static let cookieName = WireNames.accessCookie
    static let queryName = WireNames.keyQuery

    /// Stable across launches on purpose: the iPad's home-screen shortcut has
    /// the key baked into its URL, and rotating on every start would break it.
    static var key: String {
        if let stored = UserDefaults.standard.string(forKey: defaultsKey), !stored.isEmpty {
            return stored
        }
        let fresh = generate()
        store(fresh, forKey: defaultsKey)
        return fresh
    }

    // MARK: - Pairing code
    //
    // Typing a long key into an old iPad's URL bar is miserable, so the key
    // itself never has to be typed: the address is short and the secret is six
    // digits entered into a field, which iOS shows a number pad for.

    private static let lock = NSLock()
    private static var failures = 0

    static var pairingCode: String {
        if let stored = UserDefaults.standard.string(forKey: codeKey), stored.count == 6 {
            return stored
        }
        let fresh = generateCode()
        store(fresh, forKey: codeKey)
        return fresh
    }

    /// Written through immediately. UserDefaults flushes lazily, and quitting
    /// the app soon after first launch was losing the freshly generated code -
    /// so the code shown in the menu changed by itself on the next start.
    private static func store(_ value: String, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        UserDefaults.standard.synchronize()
    }

    @discardableResult
    static func rotateCode() -> String {
        let fresh = generateCode()
        store(fresh, forKey: codeKey)
        lock.lock(); failures = 0; lock.unlock()
        return fresh
    }

    private static func generateCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { Character(String(Int($0) % 10)) })
    }

    /// Six digits is a small space, so a wrong guess costs time and enough wrong
    /// guesses retire the code entirely. Brute force then needs a new code,
    /// which only the Mac's owner can read.
    static func checkPairingCode(_ candidate: String?) -> Bool {
        guard let candidate, candidate.count == 6 else { return false }
        if matchesConstantTime(pairingCode, candidate) {
            lock.lock(); failures = 0; lock.unlock()
            return true
        }
        lock.lock()
        failures += 1
        let count = failures
        lock.unlock()
        // Slow down a script; barely noticeable to a person who mistyped.
        Thread.sleep(forTimeInterval: min(Double(count) * 0.25, 2.0))
        if count >= 20 { rotateCode() }
        return false
    }

    @discardableResult
    static func rotate() -> String {
        let fresh = generate()
        store(fresh, forKey: defaultsKey)
        rotateCode()
        return fresh
    }

    /// 20 chars from an unambiguous alphabet - no 0/O or 1/l - because people
    /// read this off a menu and type it on an iPad.
    private static func generate() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    /// Length-independent comparison, so a wrong guess leaks nothing through
    /// how long the check took.
    static func matches(_ candidate: String?) -> Bool {
        guard let candidate else { return false }
        return matchesConstantTime(key, candidate)
    }

    private static func matchesConstantTime(_ expectedString: String, _ candidate: String) -> Bool {
        let expected = Array(expectedString.utf8)
        let given = Array(candidate.utf8)
        guard expected.count == given.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= expected[index] ^ given[index] }
        return difference == 0
    }

    static let deviceCookieName = WireNames.deviceCookie

    static func deviceCookieHeader(_ id: String) -> String {
        "Set-Cookie: \(deviceCookieName)=\(id); Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax\r\n"
    }

    /// Pulls a named cookie out of a raw request head.
    static func cookieValue(named name: String, in requestHead: String) -> String? {
        for line in requestHead.split(separator: "\r\n") {
            guard line.lowercased().hasPrefix("cookie:") else { continue }
            let value = line.dropFirst("cookie:".count)
            for pair in value.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces) == name else { continue }
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Pulls our cookie out of a raw request head.
    static func cookieValue(in requestHead: String) -> String? {
        cookieValue(named: cookieName, in: requestHead)
    }

    static var setCookieHeader: String {
        // Session-length, path-wide, and not readable from JavaScript.
        "Set-Cookie: \(cookieName)=\(key); Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax\r\n"
    }
}
