import SwiftUI

struct ContentView: View {
    @StateObject private var discovery = HostDiscovery()
    @State private var status: String = ""

    var body: some View {
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
        .onAppear { discovery.start() }
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
        if !WireProtocol.canServe(host.protocolVersion) {
            parts.append("needs a newer app")
        }
        return parts.joined(separator: " · ")
    }

    private func pick(_ host: DiscoveredHost) async {
        status = ""
        do {
            let url = try await discovery.resolve(host)
            status = "Resolved \(host.name) to \(url.absoluteString)"
        } catch {
            status = error.localizedDescription
        }
    }
}
