import AppKit
import CoreGraphics
import VirtualDisplayBridge
import ExtraPadProtocol

/// Owns the whole pipeline: virtual display -> ScreenCaptureKit -> JPEG -> HTTP.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {

    private var config: Config
    private var sessions: SessionManager?
    private var server: MJPEGServer?
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private var urls: [String] = []
    private var statusLine = "starting..."
    private var needsScreenPermission = false
    private var needsInputPermission = false
    private var injectors: [String: InputInjector] = [:]
    /// Refreshed on the menu timer so the network queue never has to ask.
    private let statsBox = Atomic(DeltaEncoder.Stats())
    private var latestDeltaStats: DeltaEncoder.Stats { statsBox.value }
    private var retryTask: Task<Void, Never>?

    init(config: Config) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        retryTask = Task { await startPipeline() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if self?.needsInputPermission == true, InputInjector.isPermitted {
                    self?.needsInputPermission = false
                }
                if let first = self?.sessions?.sessions.values.first {
                    self?.statsBox.store(first.streamer.deltaStats)
                }
                self?.rebuildMenu()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        retryTask?.cancel()
        server?.stop()
        MainActor.assumeIsolated {
            Task { await sessions?.shutDownAll() }
        }
    }

    // MARK: - Pipeline

    private func startPipeline() async {
        if config.mirror {
            statusLine = "mirroring the main display"
        } else if EPVirtualDisplay.supported {
            statusLine = "ready for displays"
        } else {
            config.mirror = true
            statusLine = "no virtual display on this macOS, mirroring instead"
            log("[ExtraPad] \(statusLine)")
        }

        // Displays are created per device rather than up front: their
        // resolution has to match the iPad that asked for one, and the host has
        // no way to guess that before a client says so.
        let sessions = SessionManager(config: config)
        self.sessions = sessions
        sessions.onSessionCreated = { [weak self] session in
            Task { @MainActor in await self?.begin(session) }
        }
        sessions.onSessionRemoved = { [weak self] deviceID in
            self?.server?.registry.remove(deviceID)
            self?.injectors.removeValue(forKey: deviceID)
        }

        let server = MJPEGServer(config: config)
        // Creation is the only thing that needs the main actor; everything the
        // network queue reads comes from the registry, under a lock.
        server.createSession = { [weak sessions, weak server] deviceID, size, completion in
            Task { @MainActor in
                guard let session = sessions?.session(for: deviceID, preferredSize: size) else {
                    completion(nil)
                    return
                }
                let handles = session.handles(deviceID: deviceID)
                server?.registry.set(handles, for: deviceID)
                completion(handles)
            }
        }
        server.releaseSession = { [weak sessions] deviceID in
            Task { @MainActor in sessions?.release(deviceID: deviceID) }
        }
        server.onSettingsChange = { [weak sessions] quality, fps in
            Task { @MainActor in await sessions?.apply(quality: quality, fps: fps) }
        }
        // Stats come from whichever session is primary; snapshotting them on
        // the main actor keeps this off the network queue's hands.
        server.deltaStatsProvider = { [weak self] in self?.latestDeltaStats ?? DeltaEncoder.Stats() }
        server.resetDeltaStats = { [weak sessions] in
            Task { @MainActor in sessions?.sessions.values.first?.streamer.resetDeltaStats() }
        }
        server.devices.onApprovalNeeded = { [weak self] device in
            Task { @MainActor in self?.askAbout(device) }
        }

        do {
            try server.start()
            self.server = server
        } catch {
            fail("Could not start the HTTP server on port \(config.port): \(error.localizedDescription)")
            return
        }

        if !CGPreflightScreenCaptureAccess() {
            needsScreenPermission = true
            statusLine = "waiting for Screen Recording permission"
            rebuildMenu()
            CGRequestScreenCaptureAccess()
        }

        if config.input {
            needsInputPermission = !InputInjector.isPermitted
            if needsInputPermission { InputInjector.requestPermission() }
        }

        urls = buildURLs()
        log("""

        ────────────────────────────────────────────────
         ExtraPad ready - \(statusLine)
         \(config.width)x\(config.height) @ \(config.fps) fps, quality \(config.quality)
         Each iPad gets its own display, sized for it.

         Open Safari on the iPad and go to:
        \(urls.map { "   \($0)" }.joined(separator: "\n"))

         Then enter the code it asks for: \(config.auth ? Auth.pairingCode : "(access key disabled)")
        \(server.tlsFingerprint != nil
            ? "\n TLS is on for native clients (port \(server.securePort)); the web client stays on plain HTTP."
            : "\n TLS is off - no certificate could be created.")

         Tip: Share > Add to Home Screen runs it full screen.
        ────────────────────────────────────────────────
        """)
        rebuildMenu()
    }

    /// Brings a freshly created session to life: capture, input, and the
    /// arrangement warning that used to live in the single-display path.
    private func begin(_ session: DisplaySession) async {
        if session.displayID != 0 {
            if DisplayArrangement.isMirroring(session.displayID) {
                log("[ExtraPad] WARNING: a virtual display came up mirroring; "
                    + "choose Extend in Settings > Displays")
            }
            if config.input {
                let injector = InputInjector(displayID: session.displayID)
                injectors[session.id] = injector
                server?.onInput = { [weak self] phase, x, y in
                    guard let phase = InputInjector.Phase(rawValue: phase) else { return }
                    // Input follows whichever display was most recently touched.
                    self?.injectors[session.id]?.handle(phase: phase, x: x, y: y)
                }
                server?.onInputRelease = { [weak self] in
                    self?.injectors.values.forEach { $0.releaseIfHeld() }
                }
            }
        }
        do {
            try await session.startCapture()
            statusLine = "\(sessions?.sessions.count ?? 1) display(s) active"
        } catch {
            needsScreenPermission = !CGPreflightScreenCaptureAccess()
            log("[ExtraPad] Could not start capture for \(session.id): \(error.localizedDescription)")
        }
        rebuildMenu()
    }

    private func buildURLs() -> [String] {
        // The key rides in the URL so the iPad's home-screen shortcut keeps
        // working; the server turns it into a cookie on first load.
        // Short on purpose - this gets typed on an old iPad's keyboard. The
        // secret is entered separately as six digits.
        var result = NetworkInfo.localIPv4Addresses().map { "http://\($0):\(config.port)" }
        if let host = NetworkInfo.localHostName {
            result.append("http://\(host):\(config.port)")
        }
        return result
    }

    /// Keeps trying to start capture. Returns false only if the user quits first.
    private func startCaptureWithRetry(streamer: ScreenStreamer,
                                       displayID: CGDirectDisplayID) async -> Bool {
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            do {
                try await streamer.start(displayID: displayID)
                return true
            } catch {
                needsScreenPermission = !CGPreflightScreenCaptureAccess()
                statusLine = needsScreenPermission
                    ? "Screen Recording permission required"
                    : "capture failed, retrying"
                if attempt == 1 || attempt % 10 == 0 {
                    log("[ExtraPad] \(statusLine): \(error.localizedDescription)")
                }
                rebuildMenu()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        return false
    }

    private func fail(_ message: String) {
        statusLine = "error"
        log("[ExtraPad] ERROR: \(message)")
        rebuildMenu()
        let alert = NSAlert()
        alert.messageText = "ExtraPad could not start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    @objc private func openAccessibilitySettings() {
        InputInjector.openSettings()
    }

    @objc private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    private nonisolated func log(_ message: String) {
        print(message)
        fflush(stdout)
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "display.2",
                                    accessibilityDescription: "ExtraPad")
        item.menu = NSMenu()
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let header = NSMenuItem(title: "ExtraPad - \(statusLine)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let clients = server?.activeStreams ?? 0
        let dropped = sessions?.sessions.values.first?.streamer.droppedFrames ?? 0
        let detail = NSMenuItem(
            title: "\(config.width)x\(config.height) · \(config.fps) fps · \(clients) device(s) · \(dropped) dropped",
            action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)

        if needsInputPermission {
            menu.addItem(.separator())
            let grant = NSMenuItem(title: "Open Accessibility settings for touch input...",
                                   action: #selector(openAccessibilitySettings), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }

        if needsScreenPermission {
            menu.addItem(.separator())
            let grant = NSMenuItem(title: "Open Screen Recording settings...",
                                   action: #selector(openScreenRecordingSettings),
                                   keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
            let hint = NSMenuItem(title: "Restart ExtraPad after granting it",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        if !urls.isEmpty {
            menu.addItem(.separator())
            let label = NSMenuItem(title: "Open on the iPad (click to copy):", action: nil, keyEquivalent: "")
            label.isEnabled = false
            menu.addItem(label)
            for url in urls {
                let item = NSMenuItem(title: url, action: #selector(copyURL(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let hudItem = NSMenuItem(title: "Diagnostic strip on iPad",
                                 action: #selector(toggleHUD), keyEquivalent: "")
        hudItem.target = self
        hudItem.state = config.hud ? .on : .off
        menu.addItem(hudItem)

        if !config.mirror {
            menu.addItem(.separator())
            let positionItem = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for option in DisplayPosition.allCases {
                let entry = NSMenuItem(title: option.label,
                                       action: #selector(choosePosition(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = option.rawValue
                entry.state = (option == config.position) ? .on : .off
                submenu.addItem(entry)
            }
            positionItem.submenu = submenu
            menu.addItem(positionItem)
        }

        if config.auth {
            menu.addItem(.separator())
            // What is connected now, not what has ever been approved: the
            // stored list accumulates every browser that ever paired and says
            // nothing about the present.
            let connected = server?.connectedAddresses ?? []
            let header = NSMenuItem(
                title: connected.isEmpty ? "No devices connected" : "Connected devices: \(connected.count)",
                action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for address in connected.prefix(5) {
                let item = NSMenuItem(title: "   " + address, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            if !(server?.devices.approvedDevices.isEmpty ?? true) {
                let forget = NSMenuItem(title: "Clear saved device approvals",
                                        action: #selector(forgetDevices), keyEquivalent: "")
                forget.target = self
                menu.addItem(forget)
            }

            let code = NSMenuItem(title: "Pairing code:  " + Auth.pairingCode,
                                  action: #selector(copyCode(_:)), keyEquivalent: "")
            code.target = self
            menu.addItem(code)

            let rotate = NSMenuItem(title: "Generate a new code and key",
                                    action: #selector(rotateKey), keyEquivalent: "")
            rotate.target = self
            menu.addItem(rotate)
            let note = NSMenuItem(title: "(connected devices will have to pair again)",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        } else {
            menu.addItem(.separator())
            let warning = NSMenuItem(title: "WARNING: access key is disabled",
                                     action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleHUD() {
        config.hud.toggle()
        Config.rememberHUD(config.hud)
        // Every frame carries the flag, so connected iPads pick this up
        // immediately - no reload.
        sessions?.setHUD(config.hud)
        rebuildMenu()
    }

    @objc private func choosePosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let position = DisplayPosition(rawValue: raw),
              let displayID = sessions?.sessions.values.first?.displayID else { return }
        config.position = position
        Config.savedPosition = position
        DisplayArrangement.arrange(displayID, position: position)
        rebuildMenu()
    }

    /// Asks the person at the Mac whether a newly seen device may connect.
    /// Deliberately a modal alert rather than a notification: this hands over
    /// the screen and the mouse, so it should interrupt.
    private func askAbout(_ device: DeviceRegistry.Device) {
        let consequence = config.input
            ? "see your screen and control the mouse"
            : "see your screen"
        let alert = NSAlert()
        alert.messageText = "A new device wants to connect"
        alert.informativeText = "Address: " + device.address + "\n\n"
            + "If you allow it, this device will be able to " + consequence + ".\n"
            + "If you were not expecting it, choose Deny."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            server?.devices.approve(device)
        } else {
            server?.devices.deny(device)
        }
        rebuildMenu()
    }

    @objc private func forgetDevices() {
        let alert = NSAlert()
        alert.messageText = "Clear all device approvals?"
        alert.informativeText = "Every device will be asked for again."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            server?.devices.forgetAll()
            rebuildMenu()
        }
    }

    @objc private func copyCode(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Auth.pairingCode, forType: .string)
    }

    @objc private func rotateKey() {
        Auth.rotate()
        urls = buildURLs()
        rebuildMenu()
        let alert = NSAlert()
        alert.messageText = "New code and key generated"
        alert.informativeText = "Connected devices were dropped. Open the new address from the "
            + "menu on the iPad and recreate its home-screen shortcut - the old one no longer works."
        alert.runModal()
    }

    @objc private func copyURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
}
