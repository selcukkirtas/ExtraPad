import CryptoKit
import Foundation
import Network
import Security

/// A self-signed certificate for the TLS listener, created once and reused.
///
/// There is no certificate authority here and there cannot be: this host has no
/// public name and lives on a home network. What replaces a CA is pinning - the
/// client is told the certificate's fingerprint out of band and refuses anything
/// else. That defeats a network attacker, which plain HTTP does not.
///
/// The old iPad's Safari cannot use this: trusting a self-signed certificate on
/// iOS 9 means installing a configuration profile. So the plain listener stays
/// for it, and the TLS one exists for clients that can pin.
struct TLSIdentity {

    let identity: sec_identity_t
    /// SHA-256 of the certificate in DER form, lowercase hex. This is what the
    /// client compares against.
    let fingerprint: String

    /// Loads the stored identity, creating one on first run.
    static func load() -> TLSIdentity? {
        let directory = supportDirectory()
        // Versioned filename: an elliptic-curve PKCS#12 written by an earlier
        // build cannot be imported, and the failure is an uncaught Objective-C
        // exception inside Security that kills the process with no message.
        // Ignoring the old file is the only way to survive that upgrade.
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("tls.p12"))
        let p12URL = directory.appendingPathComponent("tls-rsa.p12")

        if !FileManager.default.fileExists(atPath: p12URL.path) {
            guard generate(at: directory, p12URL: p12URL) else { return nil }
        }
        guard let data = try? Data(contentsOf: p12URL) else { return nil }
        return from(p12: data)
    }

    /// Throws the stored certificate away so a new one is made next launch.
    static func reset() {
        try? FileManager.default.removeItem(
            at: supportDirectory().appendingPathComponent("tls-rsa.p12"))
    }

    // MARK: - Creation

    private static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("ExtraPad", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func generate(at directory: URL, p12URL: URL) -> Bool {
        let key = directory.appendingPathComponent("tls-key.pem")
        let cert = directory.appendingPathComponent("tls-cert.pem")
        defer {
            // The PKCS#12 is the only thing worth keeping; leaving a bare
            // private key on disk would be careless.
            try? FileManager.default.removeItem(at: key)
            try? FileManager.default.removeItem(at: cert)
        }

        // The system openssl, not whatever a package manager put on PATH.
        // RSA rather than an elliptic curve: SecPKCS12Import cannot read the
        // EC key LibreSSL produces and throws rather than returning an error.
        guard run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048",
                                       "-keyout", key.path, "-out", cert.path,
                                       "-days", "3650", "-nodes",
                                       "-subj", "/CN=ExtraPad"]),
              run("/usr/bin/openssl", ["pkcs12", "-export", "-out", p12URL.path,
                                       "-inkey", key.path, "-in", cert.path,
                                       "-passout", "pass:\(passphrase)"])
        else { return false }

        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: p12URL.path)
        return true
    }

    /// The passphrase guards nothing on its own - the file next to it is the
    /// secret, and file permissions are what protect it. PKCS#12 simply
    /// requires one.
    private static let passphrase = "extrapad"

    private static func run(_ launchPath: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            FileHandle.standardError.write(
                "[ExtraPad] Could not run \(launchPath): \(error.localizedDescription)\n"
                    .data(using: .utf8)!)
            return false
        }
    }

    // MARK: - Import

    /// Imported into memory rather than into a keychain: nothing else needs to
    /// see it, and this avoids a keychain prompt on every launch.
    private static func from(p12 data: Data) -> TLSIdentity? {
        let options = [kSecImportExportPassphrase as String: passphrase] as CFDictionary
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let rawIdentity = first[kSecImportItemIdentity as String]
        else { return nil }

        let secIdentity = rawIdentity as! SecIdentity
        guard let identity = sec_identity_create(secIdentity) else { return nil }

        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(secIdentity, &certificate) == errSecSuccess,
              let certificate else { return nil }
        let der = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()

        return TLSIdentity(identity: identity, fingerprint: digest)
    }
}
