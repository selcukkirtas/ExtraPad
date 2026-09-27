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

    init(id: String, config: Config, slot: Int) {
        var config = config
        config.positionSlot = slot
        self.id = id
        self.config = config
        self.streamer = ScreenStreamer(config: config)
        self.streamer.showHUD = config.hud
        createDisplay(slot: slot)
    }

    private func createDisplay(slot: Int) {
        guard !config.mirror, EPVirtualDisplay.supported else { return }
        guard let created = EPVirtualDisplay(
            name: "ExtraPad \(slot + 1)",
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

    func startCapture() async throws {
        try await streamer.start(displayID: displayID)
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
