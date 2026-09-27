import Foundation

/// Runtime knobs. Defaults target a non-Retina 9.7" iPad (1024x768 CSS px), which
/// is what every iPad still stuck on iOS 9-11 reports to Safari.
struct Config {
    var width = 1024
    var height = 768
    var refreshRate = 60.0
    /// 1 = one pixel per point (cheapest to encode and to decode on an old iPad).
    var scale = 1
    /// Frames pushed per second. Old iPads JPEG-decode roughly 20-30 fps at 1024x768.
    var fps = 24
    /// JPEG quality, 0...1. Below ~0.45 text starts to smear.
    var quality = 0.6
    var port: UInt16 = 8777
    /// Mirror the main display instead of creating a second one.
    var mirror = false

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
            case "--fps":      if let v = next(), let n = Int(v) { c.fps = max(1, min(60, n)) }
            case "--quality":  if let v = next(), let q = Double(v) { c.quality = max(0.1, min(1.0, q)) }
            case "--port":     if let v = next(), let n = UInt16(v) { c.port = n }
            case "--scale":    if let v = next(), let n = Int(v) { c.scale = max(1, min(2, n)) }
            case "--refresh":  if let v = next(), let r = Double(v) { c.refreshRate = r }
            case "--mirror":   c.mirror = true
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
      --fps N         Saniyedeki kare sayisi (varsayilan 24)
      --quality Q     JPEG kalitesi 0.1-1.0 (varsayilan 0.6)
      --scale 1|2     2 = HiDPI/Retina mod (varsayilan 1)
      --refresh Hz    Sanal ekran tazeleme hizi (varsayilan 60)
      --port N        HTTP portu (varsayilan 8777)
      --mirror        Sanal ekran yerine ana ekrani yansit
    """
}
