import CoreGraphics
import Foundation
import VirtualDisplayBridge
import ExtraPadProtocol

/// One iPad's own screen: a virtual display, the capture attached to it, and
/// the encoders feeding whoever is watching.
///
/// Sessions exist because resolution belongs to the display, not to the
/// connection. An iPad 2 wants 1024x768 and a Retina mini wants 2048x1536, and
/// no single shared display can be right for both - so each device that asks
/// for one gets its own.
@MainActor
final class DisplaySession {

    let id: String
    private(set) var config: Config
    private(set) var displayID: CGDirectDisplayID = 0
    let streamer: ScreenStreamer

    private var display: EPVirtualDisplay?
    private var captureTask: Task<Void, Never>?

    /// When the last viewer left. A session outlives a brief disconnection on
    /// purpose: tearing the display down makes macOS relocate every window on
    /// it, so a dropped Wi-Fi packet would scatter the user's work.
    private(set) var idleSince: Date?

    var isIdle: Bool { idleSince != nil }

    init(id: String, config: Config, slot: Int, deviceName: String? = nil) {
        var config = config
        config.positionSlot = slot
        self.id = id
        self.config = config
        self.streamer = ScreenStreamer(config: config)
        self.streamer.showHUD = config.hud
        createDisplay(slot: slot, deviceName: deviceName)
    }

    /// "ExtraPad - iPad Air" when the client said who it is (the native app
    /// only - Safari's user agent cannot tell an iPad 2 from an iPad Air), a
    /// slot number otherwise.
    private func createDisplay(slot: Int, deviceName: String?) {
        guard !config.mirror, EPVirtualDisplay.supported else { return }
        let name = deviceName.flatMap { trimmed -> String? in
            let value = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : "ExtraPad - \(value)"
        } ?? "ExtraPad \(slot + 1)"
        guard let created = EPVirtualDisplay(
            name: name,
            pixelsWide: UInt(config.width * config.scale),
            pixelsHigh: UInt(config.height * config.scale),
            refreshRate: config.refreshRate,
            scale: UInt(config.scale),
            serial: UInt32(0x1000 + slot)), created.displayID != 0
        else { return }

        display = created
        displayID = created.displayID
        DisplayArrangement.arrange(created.displayID, position: config.position, slot: slot)
    }

    /// Whether capture is running right now. False between a lock and the
    /// unlock that follows it, with the display itself still in place.
    private(set) var isCapturing = false

    func startCapture() async throws {
        try await streamer.start(displayID: displayID)
        isCapturing = true
    }

    /// Stops capturing but keeps the virtual display, used while the Mac is
    /// locked.
    ///
    /// Two reasons, and the first one is the important one: a locked Mac that
    /// carries on streaming its screen to an iPad has not really been locked.
    /// The second is that nobody is looking, so the encoding is waste. The
    /// display stays because tearing it down makes macOS relocate every window
    /// on it - a lock must not rearrange the user's desk.
    func pauseCapture() async {
        guard isCapturing else { return }
        isCapturing = false
        await streamer.stop()
    }

    func resumeCapture() async throws {
        guard !isCapturing else { return }
        try await startCapture()
        // Whoever is watching still has the frame from before the lock on
        // screen, and both encoders have lost the pixels they were predicting
        // against - so neither may send a difference against it.
        streamer.requestKeyframe()
        streamer.requestVideoKeyframe()
    }

    /// A thread-safe view of this session for the network layer.
    nonisolated func handles(deviceID: String) -> SessionHandles {
        MainActor.assumeIsolated {
            SessionHandles(
                deviceID: deviceID,
                frames: streamer.broadcaster,
                patches: streamer.patchBroadcaster,
                video: streamer.videoBroadcaster,
                requestPatchKeyframe: { [streamer] in streamer.requestKeyframe() },
                requestVideoKeyframe: { [streamer] in streamer.requestVideoKeyframe() },
                videoParameterSets: { [streamer] in streamer.videoParameterSets },
                width: config.width, height: config.height, scale: config.scale)
        }
    }

    func markBusy() { idleSince = nil }
    func markIdle() { idleSince = Date() }

    func shutDown() async {
        captureTask?.cancel()
        isCapturing = false
        await streamer.stop()
        display?.invalidate()
        display = nil
        displayID = 0
    }

    /// Settings that can change without rebuilding the display.
    func apply(quality: Double?, fps: Int?) async {
        if let quality { config.quality = quality }
        if let fps { config.fps = fps }
        await streamer.update(quality: quality, fps: fps)
    }

    func setHUD(_ on: Bool) {
        config.hud = on
        streamer.showHUD = on
    }
}
