import SwiftUI

/// Owns the observation of a live connection.
///
/// This exists because @State does not subscribe to an ObservableObject: the
/// parent can hold the connection, but only a view that declares it as
/// @ObservedObject is redrawn when its state changes. Without this the UI sat
/// on "Connecting" while frames were already arriving.
struct ConnectedView: View {
    @ObservedObject var connection: HostConnection
    let host: DiscoveredHost
    var onLeave: () -> Void

    var body: some View {
        switch connection.state {
        case .needsCode, .wrongCode:
            PairingView(hostName: host.name,
                        wasWrong: connection.state == .wrongCode,
                        onSubmit: { code in Task { await connection.submit(code: code) } },
                        onCancel: onLeave)
        case .failed(let message):
            VStack(spacing: 16) {
                Text(message).multilineTextAlignment(.center).padding()
                Button("Back", action: onLeave)
            }
        case .connecting, .idle:
            ProgressView("Connecting to \(host.name)")
        case .streaming, .reconnecting:
            ScreenView(connection: connection, hostName: host.name, onLeave: onLeave)
        }
    }
}
