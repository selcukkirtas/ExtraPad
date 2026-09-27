import SwiftUI

struct ContentView: View {
    @StateObject private var discovery = HostDiscovery()
    @State private var status: String = ""
    @State private var connection: HostConnection?
    @State private var chosen: DiscoveredHost?

    var body: some View {
        if let connection, let chosen {
            ConnectedView(connection: connection, host: chosen, onLeave: leave)
        } else {
            browser
        }
    }

    private var browser: some View {
        // NavigationStack is iOS 16+; this app targets 15.
        NavigationView {
            Group {
                if discovery.hosts.isEmpty {
                    empty
                } else {
                    List(discovery.hosts) { host in
                        Button {
                            Task { await pick(host) }
                        } label: {
                            row(host)
                        }
                    }
                }
            }
            .navigationTitle("ExtraPad")
        }
        .navigationViewStyle(.stack)
        .onAppear {
            discovery.start()
            autoConnectIfAsked()
        }
        .onDisappear { discovery.stop() }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Looking for Macs on this network")
                .foregroundStyle(.secondary)
            if discovery.permissionLikelyDenied {
                Text("Nothing found yet. If you declined the local network prompt, "
                     + "turn ExtraPad back on in Settings > Privacy & Security > Local Network.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
            }
            if !status.isEmpty {
                Text(status).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func row(_ host: DiscoveredHost) -> some View {
        HStack {
            Image(systemName: "display")
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                Text(detail(host))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
    }

    private func detail(_ host: DiscoveredHost) -> String {
        var parts: [String] = []
        if !host.displaySize.isEmpty { parts.append(host.displaySize) }
        parts.append(host.requiresCode ? "code required" : "open")
        if host.tlsFingerprint != nil { parts.append("encrypted") }
        if !WireProtocol.canServe(host.protocolVersion) {
            parts.append("needs a newer app")
        }
        return parts.joined(separator: " · ")
    }

    private func pick(_ host: DiscoveredHost) async {
        status = ""
        guard WireProtocol.canServe(host.protocolVersion) else {
            status = "\(host.name) speaks protocol \(host.protocolVersion); this app speaks \(WireProtocol.version)."
            return
        }
        do {
            var url = try await discovery.resolve(host)
            // Prefer the encrypted listener when the host advertises one.
            if let tlsPort = host.tlsPort, host.tlsFingerprint != nil,
               var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.scheme = "https"
                components.port = Int(tlsPort)
                if let secure = components.url { url = secure }
            }
            let connection = HostConnection(baseURL: url, hostID: host.id,
                                            tlsFingerprint: host.tlsFingerprint)
            self.connection = connection
            self.chosen = host
            discovery.stop()
            await connection.begin()
        } catch {
            status = error.localizedDescription
        }
    }

    /// Smoke-test hook. The Simulator offers no way to tap a button from a
    /// script, so a debug build can be told to pick the first host it sees and
    /// submit a code. Compiled out of release builds entirely.
    private func autoConnectIfAsked() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["EXTRAPAD_AUTOCONNECT"] == "1" else { return }
        let code = environment["EXTRAPAD_CODE"] ?? ""
        Task {
            for _ in 0..<40 {
                if let host = discovery.hosts.first {
                    await pick(host)
                    if let connection, connection.state == .needsCode, !code.isEmpty {
                        await connection.submit(code: code)
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        #endif
    }

    private func leave() {
        connection?.stop()
        connection = nil
        chosen = nil
        discovery.start()
    }
}
