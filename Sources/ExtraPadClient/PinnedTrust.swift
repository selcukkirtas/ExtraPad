import CryptoKit
import Foundation

/// Accepts exactly one certificate and nothing else.
///
/// The host signs its own certificate, so the usual chain-of-trust check is
/// meaningless - no authority has vouched for it, and none can: the machine has
/// no public name. What replaces that check is knowing in advance which
/// certificate to expect. The fingerprint arrives in the Bonjour record, before
/// any connection is made.
///
/// An attacker who can forge the Bonjour record could name their own
/// fingerprint, so this is not proof of identity on its own. It is proof that
/// the connection was not intercepted *after* discovery, and it is paired with
/// the six-digit code, which such an attacker would also have to know.
final class PinnedTrust: NSObject, URLSessionDelegate {

    private let expected: String

    init(fingerprint: String) {
        self.expected = fingerprint.lowercased()
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                  URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()

        guard digest == expected else {
            NSLog("[ExtraPad] certificate does not match the expected fingerprint; refusing")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // Self-signed, so the system's own verdict is ignored deliberately -
        // the fingerprint is the whole check.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
