import Foundation

/// Runtime knobs. Defaults target a non-Retina 9.7" iPad (1024x768 CSS px), which
/// is what every iPad still stuck on iOS 9-11 reports to Safari.
struct Config {
    var width = 1024
    var height = 768
    var refreshRate = 60.0
    /// 1 = one pixel per point (cheapest to encode and to decode on an old iPad).
    var scale = 1
    /// Frames pushed per second. Remembered between launches, like the other
    /// tuning knobs, so a setup you tuned once survives a restart.
    var fps = Config.saved(Config.fpsKey, default: 24)
    /// JPEG quality, 0...1. In delta mode this can sit near 1.0, since only the
    /// changed rectangles are sent.
    var quality = Config.saved(Config.qualityKey, default: 0.8)
    var port: UInt16 = 8777
    /// Mirror the main display instead of creating a second one.
    var mirror = false
    /// Let touches on the iPad drive the Mac's cursor.
    var input = true
    /// Require the access key. Off only for a network you already trust.
    var auth = true
    /// Which side of the existing arrangement the iPad sits on. Remembered
    /// between launches, because the virtual display is new every time and
    /// macOS has nothing to remember it by.
    var position = Config.savedPosition

    static let positionDefaultsKey = "ExtraPadPosition"
    static let fpsKey = "ExtraPadFPS"
    static let qualityKey = "ExtraPadQuality"

    static func saved<T>(_ key: String, default fallback: T) -> T {
        (UserDefaults.standard.object(forKey: key) as? T) ?? fallback
    }

    static func remember(fps: Int?, quality: Double?) {
        if let fps { UserDefaults.standard.set(fps, forKey: fpsKey) }
        if let quality { UserDefaults.standard.set(quality, forKey: qualityKey) }
    }

    static var savedPosition: DisplayPosition {
        get {
            let raw = UserDefaults.standard.string(forKey: positionDefaultsKey) ?? ""
            return DisplayPosition(rawValue: raw) ?? .right
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: positionDefaultsKey) }
    }

    static func fromCommandLine(_ args: [String] = Array(CommandLine.arguments.dropFirst())) -> Config {
        var c = Config()
        var i = 0
        while i < args.count {
            let key = args[i]
            func next() -> String? {
                i += 1
                return i < args.count ? args[i] : nil
            }
            switch key {
            case "--size":
                if let v = next() {
                    let parts = v.lowercased().split(separator: "x")
                    if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                        c.width = w; c.height = h
                    }
                }
            case "--fps":
                if let v = next(), let n = Int(v) {
                    c.fps = max(1, min(60, n))
                    Config.remember(fps: c.fps, quality: nil)
                }
            case "--quality":
                if let v = next(), let q = Double(v) {
                    c.quality = max(0.1, min(1.0, q))
                    Config.remember(fps: nil, quality: c.quality)
                }
            case "--port":     if let v = next(), let n = UInt16(v) { c.port = n }
            case "--scale":    if let v = next(), let n = Int(v) { c.scale = max(1, min(2, n)) }
            case "--refresh":  if let v = next(), let r = Double(v) { c.refreshRate = r }
            case "--mirror":   c.mirror = true
            case "--no-input": c.input = false
            case "--no-auth":  c.auth = false
            case "--position":
                if let v = next(), let p = DisplayPosition(rawValue: v.lowercased()) {
                    c.position = p
                    Config.savedPosition = p
                }
            case "--help", "-h":
                print(Config.usage)
                exit(0)
            default:
                FileHandle.standardError.write("Bilinmeyen secenek: \(key)\n".data(using: .utf8)!)
                print(Config.usage)
                exit(2)
            }
            i += 1
        }
        return c
    }

    static let usage = """
    ExtraPad - eski bir iPad'i Mac'e kablosuz ikinci ekran yapar.

    Kullanim: ExtraPad [secenekler]
      --size WxH      Sanal ekran cozunurlugu (varsayilan 1024x768)
      --fps N         Saniyedeki kare sayisi (hatirlanir, varsayilan 24)
      --quality Q     JPEG kalitesi 0.1-1.0 (hatirlanir, varsayilan 0.8)
      --scale 1|2     2 = HiDPI/Retina mod (varsayilan 1)
      --refresh Hz    Sanal ekran tazeleme hizi (varsayilan 60)
      --port N        HTTP portu (varsayilan 8777)
      --mirror        Sanal ekran yerine ana ekrani yansit
    """
}
