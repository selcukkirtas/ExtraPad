import AppKit
import Foundation

/// Tells an old install there's something newer, and gets out of the way
/// otherwise.
///
/// No Sparkle, no appcast, no signing keys: a `.app` that isn't notarized
/// yet can't auto-install an update regardless, so all this needs to do is
/// point a person at the download page. A static JSON file on the website
/// is the entire backend - one more thing this project doesn't need a
/// server for.
enum UpdateChecker {

    struct Release: Decodable {
        let version: String
        let notes: String?
        /// Where "get it" sends the person. The website today; a direct
        /// `.zip`/`.dmg` link once notarized builds exist.
        let downloadURL: String
    }

    private static let manifestURL = URL(string: "https://extrapad.app/version.json")!

    /// The version this build was stamped with at build time.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Fetches the manifest and compares it to `currentVersion`. Silent on
    /// any failure - a person offline, or before the manifest exists yet,
    /// should never see an error for this.
    static func checkForUpdate() async -> Release? {
        guard let (data, response) = try? await URLSession.shared.data(from: manifestURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              isNewer(release.version, than: currentVersion)
        else { return nil }
        return release
    }

    /// Numeric, dotted comparison ("0.10.0" > "0.9.0") rather than a string
    /// compare, which would get that pair backwards.
    private static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = installed.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// One alert, with a button straight to the download page. Shown once
    /// per launch at most - `AppController` decides when to call this, this
    /// just presents what it's told to.
    @MainActor
    static func presentAlert(for release: Release) {
        let alert = NSAlert()
        alert.messageText = "ExtraPad \(release.version) is available"
        alert.informativeText = (release.notes.map { $0 + "\n\n" } ?? "")
            + "You're running \(currentVersion)."
        alert.addButton(withTitle: "Get It")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: release.downloadURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
