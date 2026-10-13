import AppKit
import CoreGraphics

/// Watches whether the Mac is actually in use.
///
/// Three different events all mean the same thing to an iPad acting as a second
/// display - the screen was locked, the Mac went to sleep, or the displays went
/// dark on their own. In every case nobody is looking, so capture should stop
/// and the iPad should be free to sleep too.
///
/// Lock state is the awkward one: there is no public notification for it, so it
/// comes from the distributed notification the login session posts, and the
/// initial value from the session dictionary - without which an app launched
/// while the screen is locked would believe the Mac is in use.
@MainActor
final class HostPresence {

    /// Called whenever availability flips, with the new value.
    var onChange: ((Bool) -> Void)?

    private(set) var isLocked = false
    private(set) var isAsleep = false

    /// Somebody could be looking at the Mac right now.
    var isAwake: Bool { !isLocked && !isAsleep }

    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init() {
        isLocked = Self.screenIsLockedNow()
    }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked") { $0.isLocked = true }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.isLocked = false }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification.rawValue) { $0.isAsleep = true }
        observe(workspace, NSWorkspace.didWakeNotification.rawValue) { $0.isAsleep = false }
    }

    // Deliberately *not* watched: the screen saver starting, and the Mac's own
    // displays going dark. Neither means nobody is there - somebody watching a
    // video on the iPad touches nothing for twenty minutes, and cutting their
    // stream off would be a worse bug than the one this class exists to fix.
    // The usual setting ("require a password after the screen saver begins")
    // posts a real lock anyway, and that is what gets acted on.

    func stop() {
        for entry in observers { entry.center.removeObserver(entry.token) }
        observers.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: String,
                         _ apply: @escaping (HostPresence) -> Void) {
        let observer = center.addObserver(forName: Notification.Name(name), object: nil,
                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let was = self.isAwake
                apply(self)
                if self.isAwake != was { self.onChange?(self.isAwake) }
            }
        }
        observers.append((center, observer))
    }

    /// The only way to read lock state at launch. A missing key means unlocked:
    /// the dictionary omits it entirely rather than reporting false.
    private static func screenIsLockedNow() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as NSDictionary?,
              let locked = session["CGSSessionScreenIsLocked"] as? Bool else { return false }
        return locked
    }
}
