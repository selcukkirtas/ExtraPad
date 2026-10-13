import SwiftUI

/// The connected screen: the host's picture, plus touches sent back as mouse
/// events in the host display's own pixel space.
struct ScreenView: View {
    @ObservedObject var connection: HostConnection
    let hostName: String
    var onLeave: () -> Void

    /// Starts hidden: the point of a second display is the picture, not a
    /// status bar sitting on top of it. A double tap brings it back.
    @State private var showOverlay = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if connection.hostStatus == .locked {
                lockedCurtain
            } else if let image = connection.image {
                GeometryReader { geometry in
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .gesture(dragGesture(in: geometry.size))
                }
                .ignoresSafeArea()
            } else {
                ProgressView("Waiting for the first frame")
                    .foregroundColor(.white)
            }

            if showOverlay { overlay }
        }
        .statusBar(hidden: true)
        .onTapGesture(count: 2) { showOverlay.toggle() }
    }

    /// Covers the picture completely rather than dimming it. The whole point
    /// of this screen is that it shows the Mac, and while the Mac is locked
    /// that is the one thing it must not do - the last frame it received is
    /// still whatever was open when the lock came down.
    private var lockedCurtain: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 40))
            Text("\(hostName) is locked")
                .font(.headline)
            Text("The screen comes back when you unlock the Mac. Until then this "
                 + "iPad will dim and sleep on its own.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.6))
                .frame(maxWidth: 320)
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    private var overlay: some View {
        HStack {
            Button(action: onLeave) {
                Image(systemName: "xmark.circle.fill").imageScale(.large)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if connection.isEncrypted {
                    Image(systemName: "lock.fill").font(.caption2)
                }
                Text(hostName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if case let .reconnecting(attempt) = connection.state {
                Text("reconnecting (\(attempt))")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text(String(format: "%.0f fps · %.2f Mbit/s",
                            connection.framesPerSecond, connection.megabitsPerSecond))
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.black.opacity(0.7))
        .foregroundColor(.white)
    }

    /// One finger drives the Mac's cursor. The picture is letterboxed inside the
    /// view, so the drawn rectangle has to be worked out before mapping a touch
    /// back to host pixels - using the view's own size would skew everything.
    private func dragGesture(in viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if let point = hostPoint(for: value.location, in: viewSize) {
                    connection.send(phase: started ? "M" : "D", x: point.x, y: point.y)
                    started = true
                }
            }
            .onEnded { value in
                if let point = hostPoint(for: value.location, in: viewSize) {
                    connection.send(phase: "U", x: point.x, y: point.y)
                }
                started = false
            }
    }

    @State private var started = false

    private func hostPoint(for location: CGPoint, in viewSize: CGSize) -> (x: Int, y: Int)? {
        ScreenMapping(hostSize: connection.displaySize, viewSize: viewSize)
            .hostPixel(at: location)
    }
}
