import AppKit
import CoreGraphics
import VirtualDisplayBridge
import ExtraPadProtocol

/// Owns the whole pipeline: virtual display -> ScreenCaptureKit -> JPEG -> HTTP.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {

    private var config: Config
    private var virtualDisplay: EPVirtualDisplay?
    private var streamer: ScreenStreamer?
    private var server: MJPEGServer?
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private var urls: [String] = []
    private var statusLine = "starting..."
    private var needsScreenPermission = false
    private var needsInputPermission = false
    private var injector: InputInjector?
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
                self?.rebuildMenu()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        retryTask?.cancel()
        server?.stop()
        virtualDisplay?.invalidate()
    }

    // MARK: - Pipeline

    private func startPipeline() async {
        var captureID: CGDirectDisplayID = 0

        if config.mirror {
            statusLine = "mirroring the main display"
        } else if EPVirtualDisplay.supported {
            let display = EPVirtualDisplay(
                name: "ExtraPad",
                pixelsWide: UInt(config.width * config.scale),
                pixelsHigh: UInt(config.height * config.scale),
                refreshRate: config.refreshRate,
                scale: UInt(config.scale)
            )
            if let display, display.displayID != 0 {
                virtualDisplay = display
                captureID = display.displayID
                // macOS attaches new displays as mirrors; without this the iPad
                // would show a squashed copy of the built-in screen.
                DisplayArrangement.arrange(display.displayID, position: config.position)
                if DisplayArrangement.isMirroring(display.displayID) {
                    statusLine = "virtual display is mirroring - choose Extend in Settings > Displays"
                    log("[ExtraPad] WARNING: \(statusLine)")
                } else {
                    statusLine = "virtual display active"
                }
            } else {
                config.mirror = true
                statusLine = "could not create a virtual display, fell back to mirroring"
                log(statusLine)
            }
        } else {
            config.mirror = true
            statusLine = "no virtual display on this macOS, mirroring instead"
            log(statusLine)
        }

        let streamer = ScreenStreamer(config: config)
        streamer.showHUD = config.hud
        self.streamer = streamer

        let server = MJPEGServer(config: config,
                                 broadcaster: streamer.broadcaster,
                                 patchBroadcaster: streamer.patchBroadcaster,
                                 videoBroadcaster: streamer.videoBroadcaster)
        server.onVideoKeyframeRequest = { [weak streamer] in streamer?.requestVideoKeyframe() }
        server.videoParameterSets = { [weak streamer] in streamer?.videoParameterSets }
        server.devices.onApprovalNeeded = { [weak self] device in
            Task { @MainActor in self?.askAbout(device) }
        }
        server.onKeyframeRequest = { [weak streamer] in streamer?.requestKeyframe() }
        if config.input, captureID != 0 {
            let injector = InputInjector(displayID: captureID)
            self.injector = injector
            // Without Accessibility permission macOS drops every synthetic
            // event without a word, so check before the first touch arrives.
            needsInputPermission = !InputInjector.isPermitted
            if needsInputPermission { InputInjector.requestPermission() }
            server.onInput = { phase, x, y in
                guard let phase = InputInjector.Phase(rawValue: phase) else { return }
                injector.handle(phase: phase, x: x, y: y)
            }
            server.onInputRelease = { injector.releaseIfHeld() }
        }
        server.deltaStatsProvider = { [weak streamer] in streamer?.deltaStats ?? DeltaEncoder.Stats() }
        server.resetDeltaStats = { [weak streamer] in streamer?.resetDeltaStats() }
        server.onSettingsChange = { [weak streamer] quality, fps in
            Task { await streamer?.update(quality: quality, fps: fps) }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            fail("Could not start the HTTP server on port \(config.port): \(error.localizedDescription)")
            return
        }

        // Trigger the Screen Recording prompt ourselves; without it SCK just
        // fails with an opaque TCC error on first run.
        if !CGPreflightScreenCaptureAccess() {
            needsScreenPermission = true
            statusLine = "waiting for Screen Recording permission"
            rebuildMenu()
            CGRequestScreenCaptureAccess()
        }

        urls = buildURLs()

        // Permission is granted out-of-process and macOS does not call us back,
        // so poll until the capture actually starts rather than giving up.
        if !(await startCaptureWithRetry(streamer: streamer, displayID: captureID)) {
            return
        }
        needsScreenPermission = false
        log("""

        ────────────────────────────────────────────────
         ExtraPad ready - \(statusLine)
         \(config.width)x\(config.height) @ \(config.fps) fps, quality \(config.quality)

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
        let dropped = streamer?.droppedFrames ?? 0
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

        if virtualDisplay != nil {
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
        streamer?.showHUD = config.hud
        rebuildMenu()
    }

    @objc private func choosePosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let position = DisplayPosition(rawValue: raw),
              let displayID = virtualDisplay?.displayID else { return }
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
