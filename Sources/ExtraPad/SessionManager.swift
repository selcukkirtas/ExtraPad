import CoreGraphics
import Foundation
import ExtraPadProtocol

/// Hands each device its own display session, and cleans up after them.
@MainActor
final class SessionManager {

    /// More than this and the Mac spends more time encoding than the displays
    /// are worth; each session is a capture stream and an encoder of its own.
    static let maximumSessions = 4

    /// How long a session survives with nobody watching. Long enough that a
    /// dropped connection or a backgrounded app does not scatter the windows
    /// that were on that display, short enough that it does not linger.
    static let idleGrace: TimeInterval = 90

    private(set) var sessions: [String: DisplaySession] = [:]
    private var baseConfig: Config
    private var reaper: Task<Void, Never>?

    /// Called when a session is created, so capture can be started and any
    /// permission flow driven from one place.
    var onSessionCreated: ((DisplaySession) -> Void)?
    /// Called when a session is torn down, so its published handles go away
    /// with it - otherwise the network queue would hand out a dead display.
    var onSessionRemoved: ((String) -> Void)?

    init(config: Config) {
        self.baseConfig = config
        startReaper()
    }

    /// The session for a device, creating one at the size that device asked
    /// for. A device that returns gets its display back rather than a new
    /// one - unless it's asking for a different size than last time, which
    /// is what an iPad rotating looks like from here. A virtual display
    /// can't be resized in place, so that case rebuilds it from scratch at
    /// the new shape, same as if the device were new.
    func session(for deviceID: String, preferredSize: CGSize?,
                deviceName: String? = nil) async -> DisplaySession? {
        if let existing = sessions[deviceID] {
            if let preferredSize, preferredSize.width >= 256, preferredSize.height >= 256,
               (Int(preferredSize.width) != existing.config.width
                || Int(preferredSize.height) != existing.config.height) {
                await existing.shutDown()
                sessions.removeValue(forKey: deviceID)
                onSessionRemoved?(deviceID)
            } else {
                existing.markBusy()
                return existing
            }
        }
        guard sessions.count < Self.maximumSessions else { return nil }

        var config = baseConfig
        if let preferredSize, preferredSize.width >= 256, preferredSize.height >= 256 {
            config.width = Int(preferredSize.width)
            config.height = Int(preferredSize.height)
        }

        let slot = nextFreeSlot()
        let session = DisplaySession(id: deviceID, config: config, slot: slot, deviceName: deviceName)
        sessions[deviceID] = session
        onSessionCreated?(session)
        return session
    }

    func release(deviceID: String) {
        sessions[deviceID]?.markIdle()
    }

    func shutDownAll() async {
        reaper?.cancel()
        for (id, session) in sessions {
            await session.shutDown()
            onSessionRemoved?(id)
        }
        sessions.removeAll()
    }

    func apply(quality: Double?, fps: Int?) async {
        if let quality { baseConfig.quality = quality }
        if let fps { baseConfig.fps = fps }
        for session in sessions.values { await session.apply(quality: quality, fps: fps) }
    }

    func setHUD(_ on: Bool) {
        baseConfig.hud = on
        for session in sessions.values { session.setHUD(on) }
    }

    var activeCount: Int { sessions.values.filter { !$0.isIdle }.count }

    private func nextFreeSlot() -> Int {
        let used = Set(sessions.values.map(\.config.positionSlot))
        var slot = 0
        while used.contains(slot) { slot += 1 }
        return slot
    }

    private func startReaper() {
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.reapIdleSessions()
            }
        }
    }

    private func reapIdleSessions() async {
        let now = Date()
        for (id, session) in sessions {
            guard let idleSince = session.idleSince,
                  now.timeIntervalSince(idleSince) > Self.idleGrace else { continue }
            await session.shutDown()
            sessions.removeValue(forKey: id)
            onSessionRemoved?(id)
        }
    }
}
