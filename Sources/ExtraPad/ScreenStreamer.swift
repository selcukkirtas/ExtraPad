import Foundation
import CoreImage
import CoreMedia
import ScreenCaptureKit

/// Captures one display with ScreenCaptureKit and turns each frame into a JPEG.
/// JPEG rather than H.264 because Safari on iOS 9-11 has neither Media Source
/// Extensions nor WebRTC - a multipart JPEG stream is the only thing it can decode.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {

    enum StreamError: LocalizedError {
        case displayNotFound(CGDirectDisplayID)
        case noDisplays

        var errorDescription: String? {
            switch self {
            case .displayNotFound(let id):
                return "Could not find the display to capture (displayID \(id))."
            case .noDisplays:
                return "No shareable displays found. Has Screen Recording permission been granted?"
            }
        }
    }

    let broadcaster = FrameBroadcaster()
    let patchBroadcaster = PatchBroadcaster()

    private var config: Config
    private let configLock = NSLock()
    private let deltaEncoder = DeltaEncoder()
    private let hudLock = NSLock()
    private var _showHUD = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let sampleQueue = DispatchQueue(label: "dev.extrapad.capture", qos: .userInitiated)
    private var stream: SCStream?

    /// Frames dropped because encoding of the previous one was still running.
    private let statsLock = NSLock()
    private var _droppedFrames: UInt64 = 0
    private var encoding = false

    var droppedFrames: UInt64 {
        statsLock.lock(); defer { statsLock.unlock() }
        return _droppedFrames
    }

    init(config: Config) {
        self.config = config
        super.init()
    }

    /// `displayID` of 0 means "whatever macOS considers the main display".
    func start(displayID: CGDirectDisplayID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard !content.displays.isEmpty else { throw StreamError.noDisplays }

        let target: SCDisplay
        if displayID == 0 {
            guard let main = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first else { throw StreamError.noDisplays }
            target = main
        } else {
            guard let found = content.displays.first(where: { $0.displayID == displayID }) else {
                throw StreamError.displayNotFound(displayID)
            }
            target = found
        }

        let filter = SCContentFilter(display: target, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = config.width * config.scale
        cfg.height = config.height * config.scale
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        cfg.queueDepth = 3
        cfg.showsCursor = true
        // Feeding identical frames wastes the iPad's decoder; SCK already
        // withholds a frame when nothing changed.

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Retunes a running capture. Quality takes effect on the next frame; a new
    /// frame rate is pushed into the live SCStream, so HTTP clients stay connected
    /// and nobody has to reload the page mid-measurement.
    func update(quality: Double?, fps: Int?) async {
        let snapshot = applySettings(quality: quality, fps: fps)

        guard fps != nil, let stream else { return }
        let cfg = SCStreamConfiguration()
        cfg.width = snapshot.width * snapshot.scale
        cfg.height = snapshot.height * snapshot.scale
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(snapshot.fps))
        cfg.queueDepth = 3
        cfg.showsCursor = true
        try? await stream.updateConfiguration(cfg)
    }

    /// Synchronous on purpose: NSLock must not be held across an await.
    private func applySettings(quality: Double?, fps: Int?) -> Config {
        configLock.lock(); defer { configLock.unlock() }
        if let quality { config.quality = max(0.1, min(1.0, quality)) }
        if let fps { config.fps = max(1, min(60, fps)) }
        return config
    }

    var currentConfig: Config {
        configLock.lock(); defer { configLock.unlock() }
        return config
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        // Skip rather than queue: a backlog would only add latency.
        statsLock.lock()
        if encoding {
            _droppedFrames += 1
            statsLock.unlock()
            return
        }
        encoding = true
        statsLock.unlock()
        defer {
            statsLock.lock(); encoding = false; statsLock.unlock()
        }

        configLock.lock()
        let quality = config.quality
        configLock.unlock()

        // Delta clients and full-frame clients need different work, so only do
        // the encoding somebody is actually waiting for.
        let wantsPatches = patchBroadcaster.subscriberCount > 0
        if wantsPatches {
            if let atlas = deltaEncoder.encode(pixelBuffer, quality: quality) {
                let payload = WebSocket.atlasPayload(
                    regions: atlas.regions.map {
                        (sourceY: $0.sourceY, destX: Int($0.dest.x), destY: Int($0.dest.y),
                         width: Int($0.size.width), height: Int($0.size.height))
                    },
                    isKeyframe: atlas.isKeyframe,
                    showHUD: showHUD,
                    jpeg: atlas.jpeg)
                patchBroadcaster.publish(PatchGroup(messages: [payload],
                                                    isKeyframe: atlas.isKeyframe))
            }
        }

        guard broadcaster.subscriberCount > 0 || !wantsPatches else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let jpeg = ciContext.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:
                        quality]
        ) else { return }

        broadcaster.publish(jpeg)
    }

    /// Asks for a full frame on the next capture - used when a client joins and
    /// has no earlier pixels to patch onto.
    func requestKeyframe() { deltaEncoder.requestKeyframe() }

    var showHUD: Bool {
        get { hudLock.lock(); defer { hudLock.unlock() }; return _showHUD }
        set { hudLock.lock(); _showHUD = newValue; hudLock.unlock() }
    }

    var deltaStats: DeltaEncoder.Stats { deltaEncoder.stats }
    func resetDeltaStats() { deltaEncoder.resetStats() }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(
            "[ExtraPad] Capture stopped: \(error.localizedDescription)\n".data(using: .utf8)!)
    }
}
