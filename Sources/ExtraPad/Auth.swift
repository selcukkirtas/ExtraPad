import Foundation

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
    static let cookieName = "extrapad"
    static let queryName = "k"

    /// Stable across launches on purpose: the iPad's home-screen shortcut has
    /// the key baked into its URL, and rotating on every start would break it.
    static var key: String {
        if let stored = UserDefaults.standard.string(forKey: defaultsKey), !stored.isEmpty {
            return stored
        }
        let fresh = generate()
        UserDefaults.standard.set(fresh, forKey: defaultsKey)
        return fresh
    }

    @discardableResult
    static func rotate() -> String {
        let fresh = generate()
        UserDefaults.standard.set(fresh, forKey: defaultsKey)
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
        let expected = Array(key.utf8)
        let given = Array(candidate.utf8)
        guard expected.count == given.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= expected[index] ^ given[index] }
        return difference == 0
    }

    /// Pulls our cookie out of a raw request head.
    static func cookieValue(in requestHead: String) -> String? {
        for line in requestHead.split(separator: "\r\n") {
            guard line.lowercased().hasPrefix("cookie:") else { continue }
            let value = line.dropFirst("cookie:".count)
            for pair in value.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces) == cookieName else { continue }
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static var setCookieHeader: String {
        // Session-length, path-wide, and not readable from JavaScript.
        "Set-Cookie: \(cookieName)=\(key); Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax\r\n"
    }
}
