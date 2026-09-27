import Foundation
import Network

/// A Mac running ExtraPad, as seen on the network before anything is connected.
struct DiscoveredHost: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    let protocolVersion: Int
    let requiresCode: Bool
    let displaySize: String
    /// Present when the host offers TLS. The fingerprint is what the client
    /// pins, and it arrives here rather than being learned on first connect.
    let tlsPort: UInt16?
    let tlsFingerprint: String?

    static func == (a: DiscoveredHost, b: DiscoveredHost) -> Bool { a.id == b.id }
}

/// Browses for hosts and resolves the one the user picks.
///
/// The TXT record carries enough to draw a useful list - which Mac, what it
/// speaks, whether a code will be asked for - so the user chooses before any
/// connection is made.
@MainActor
final class HostDiscovery: ObservableObject {

    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var isSearching = false
    @Published private(set) var permissionLikelyDenied = false

    private var browser: NWBrowser?
    private var sawAnyUpdate = false

    func start() {
        guard browser == nil else { return }
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: WireNames.bonjourServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.apply(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isSearching = true
                case .failed, .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser

        // On iOS the local network permission has no callback: a denied prompt
        // simply produces no results, forever. Surfacing that as a hint beats
        // an empty list that looks like a broken app.
        Task { @MainActor in
            // Task.sleep(for:) is iOS 16+.
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !self.sawAnyUpdate { self.permissionLikelyDenied = true }
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        sawAnyUpdate = true
        permissionLikelyDenied = false
        hosts = results.compactMap { result in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            var version = 0
            var requiresCode = true
            var size = ""
            var friendly = name
            var tlsPort: UInt16?
            var fingerprint: String?
            if case let .bonjour(txt) = result.metadata {
                version = txt["v"].flatMap(Int.init) ?? 0
                requiresCode = (txt["auth"] ?? "1") == "1"
                size = txt["size"] ?? ""
                friendly = txt["host"] ?? name
                tlsPort = txt["tls"].flatMap(UInt16.init)
                fingerprint = txt["fp"]
            }
            return DiscoveredHost(id: name, name: friendly, endpoint: result.endpoint,
                                  protocolVersion: version, requiresCode: requiresCode,
                                  displaySize: size, tlsPort: tlsPort,
                                  tlsFingerprint: fingerprint)
        }
        .sorted { $0.name < $1.name }
    }

    /// Bonjour gives a service name, but an HTTP request needs a host and port.
    /// Opening a connection and reading the path it resolved to is the supported
    /// way to get them without the deprecated NetService API.
    func resolve(_ host: DiscoveredHost) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(to: host.endpoint, using: .tcp)
            // State callbacks arrive on a network queue and can overlap.
            // Resuming a continuation twice is a crash, so the guard has to be
            // atomic rather than a plain captured flag.
            let resumed = OnceFlag()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumed.claim() else { return }
                    let remote = connection.currentPath?.remoteEndpoint
                    connection.cancel()
                    guard case let .hostPort(nwHost, port) = remote else {
                        continuation.resume(throwing: DiscoveryError.unresolved)
                        return
                    }
                    var text = "\(nwHost)"
                    // IPv6 literals arrive with a zone suffix and need brackets.
                    if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                    let hostPart = text.contains(":") ? "[\(text)]" : text
                    guard let url = URL(string: "http://\(hostPart):\(port.rawValue)") else {
                        continuation.resume(throwing: DiscoveryError.unresolved)
                        return
                    }
                    continuation.resume(returning: url)
                case .failed(let error):
                    guard resumed.claim() else { return }
                    connection.cancel()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    enum DiscoveryError: LocalizedError {
        case unresolved
        var errorDescription: String? { "Could not work out the address of that Mac." }
    }
}


/// One-shot guard: the first caller wins, everyone after is told to stand down.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
