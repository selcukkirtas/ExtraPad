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
    private var retryTask: Task<Void, Never>?

    init(config: Config) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        retryTask = Task { await startPipeline() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rebuildMenu() }
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

        let server = MJPEGServer(config: config, broadcaster: streamer.broadcaster)
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

         iPad'de Safari'yi ac ve su adrese git:
        \(urls.map { "   \($0)" }.joined(separator: "\n"))

         Ipucu: Paylas > Ana Ekrana Ekle ile tam ekran calisir.
        ────────────────────────────────────────────────
        """)
        rebuildMenu()
    }

    private func buildURLs() -> [String] {
        var result = NetworkInfo.localIPv4Addresses().map { "http://\($0):\(config.port)/" }
        if let host = NetworkInfo.localHostName {
            result.append("http://\(host):\(config.port)/")
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

    @objc private func copyURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
}
