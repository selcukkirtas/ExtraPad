import AppKit
import CoreGraphics
import VirtualDisplayBridge

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
    private var statusLine = "baslatiliyor..."
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
            statusLine = "ana ekran yansitiliyor"
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
                    statusLine = "sanal ekran yansitma modunda - Ayarlar > Ekranlar'dan 'Genislet' secin"
                    log("[ExtraPad] UYARI: \(statusLine)")
                } else {
                    statusLine = "sanal ekran aktif"
                }
            } else {
                config.mirror = true
                statusLine = "sanal ekran acilamadi, yansitmaya dusuldu"
                log(statusLine)
            }
        } else {
            config.mirror = true
            statusLine = "bu macOS'ta sanal ekran yok, yansitiliyor"
            log(statusLine)
        }

        let streamer = ScreenStreamer(config: config)
        self.streamer = streamer

        let server = MJPEGServer(config: config,
                                 broadcaster: streamer.broadcaster,
                                 patchBroadcaster: streamer.patchBroadcaster)
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
            fail("HTTP sunucusu \(config.port) portunda baslatilamadi: \(error.localizedDescription)")
            return
        }

        // Trigger the Screen Recording prompt ourselves; without it SCK just
        // fails with an opaque TCC error on first run.
        if !CGPreflightScreenCaptureAccess() {
            needsScreenPermission = true
            statusLine = "Ekran Kaydi izni bekleniyor"
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
         ExtraPad hazir - \(statusLine)
         \(config.width)x\(config.height) @ \(config.fps) fps, kalite \(config.quality)

         iPad'de Safari'yi ac ve su adrese git\(config.auth ? " (anahtar dahil)" : ""):
        \(urls.map { "   \($0)" }.joined(separator: "\n"))

         Ipucu: Paylas > Ana Ekrana Ekle ile tam ekran calisir.
        ────────────────────────────────────────────────
        """)
        rebuildMenu()
    }

    private func buildURLs() -> [String] {
        // The key rides in the URL so the iPad's home-screen shortcut keeps
        // working; the server turns it into a cookie on first load.
        let suffix = config.auth ? "?\(Auth.queryName)=\(Auth.key)" : ""
        var result = NetworkInfo.localIPv4Addresses().map { "http://\($0):\(config.port)/\(suffix)" }
        if let host = NetworkInfo.localHostName {
            result.append("http://\(host):\(config.port)/\(suffix)")
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
                    ? "Ekran Kaydi izni gerekli"
                    : "yakalama basarisiz, tekrar deneniyor"
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
        statusLine = "hata"
        log("[ExtraPad] HATA: \(message)")
        rebuildMenu()
        let alert = NSAlert()
        alert.messageText = "ExtraPad baslatilamadi"
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
            title: "\(config.width)x\(config.height) · \(config.fps) fps · \(clients) cihaz · \(dropped) atlanan",
            action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)

        if needsInputPermission {
            menu.addItem(.separator())
            let grant = NSMenuItem(title: "Dokunma girisi icin Erisilebilirlik iznini ac...",
                                   action: #selector(openAccessibilitySettings), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }

        if needsScreenPermission {
            menu.addItem(.separator())
            let grant = NSMenuItem(title: "Ekran Kaydi iznini ac...",
                                   action: #selector(openScreenRecordingSettings),
                                   keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
            let hint = NSMenuItem(title: "Izni verdikten sonra ExtraPad'i yeniden baslatin",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        if !urls.isEmpty {
            menu.addItem(.separator())
            let label = NSMenuItem(title: "iPad'de ac (tiklayinca kopyalanir):", action: nil, keyEquivalent: "")
            label.isEnabled = false
            menu.addItem(label)
            for url in urls {
                let item = NSMenuItem(title: url, action: #selector(copyURL(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                menu.addItem(item)
            }
        }

        if virtualDisplay != nil {
            menu.addItem(.separator())
            let positionItem = NSMenuItem(title: "Konum", action: nil, keyEquivalent: "")
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
            let approved = server?.devices.approvedDevices ?? []
            let header = NSMenuItem(
                title: approved.isEmpty ? "Onayli cihaz yok" : "Onayli cihazlar: \(approved.count)",
                action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for device in approved.prefix(5) {
                let item = NSMenuItem(title: "   " + device.address, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            if !approved.isEmpty {
                let forget = NSMenuItem(title: "Cihaz izinlerini sil",
                                        action: #selector(forgetDevices), keyEquivalent: "")
                forget.target = self
                menu.addItem(forget)
            }

            let rotate = NSMenuItem(title: "Yeni erisim anahtari uret",
                                    action: #selector(rotateKey), keyEquivalent: "")
            rotate.target = self
            menu.addItem(rotate)
            let note = NSMenuItem(title: "(mevcut cihazlarin yeniden baglanmasi gerekir)",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        } else {
            menu.addItem(.separator())
            let warning = NSMenuItem(title: "UYARI: erisim anahtari kapali",
                                     action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Cikis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
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
            ? "ekrani gorecek ve fareyi surebilecek"
            : "ekrani gorecek"
        let alert = NSAlert()
        alert.messageText = "Yeni bir cihaz baglanmak istiyor"
        alert.informativeText = "Adres: " + device.address + "\n\n"
            + "Izin verirseniz bu cihaz " + consequence + ".\n"
            + "Beklemediginiz bir cihazsa Reddet'i secin."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Izin Ver")
        alert.addButton(withTitle: "Reddet")
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
        alert.messageText = "Tum cihaz izinleri silinsin mi?"
        alert.informativeText = "Her cihaz icin yeniden onay sorulacak."
        alert.addButton(withTitle: "Sil")
        alert.addButton(withTitle: "Vazgec")
        if alert.runModal() == .alertFirstButtonReturn {
            server?.devices.forgetAll()
            rebuildMenu()
        }
    }

    @objc private func rotateKey() {
        Auth.rotate()
        urls = buildURLs()
        rebuildMenu()
        let alert = NSAlert()
        alert.messageText = "Yeni erisim anahtari uretildi"
        alert.informativeText = "Bagli cihazlar dustu. Menudeki yeni adresi iPad'de acin ve "
            + "ana ekran kisayolunu yenileyin - eski kisayol artik calismaz."
        alert.runModal()
    }

    @objc private func copyURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
}
