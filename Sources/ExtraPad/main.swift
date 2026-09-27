import AppKit

let config = Config.fromCommandLine()

// Top-level code in an SPM executable is not implicitly main-actor isolated,
// and AppController touches AppKit throughout - but this *is* the main thread.
MainActor.assumeIsolated {
    let controller = AppController(config: config)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.delegate = controller
    app.run()
}
