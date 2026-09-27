import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import ExtraPadProtocol

/// Hardware H.264 for native clients.
///
/// The tile-diffing path exists because a browser on iOS 9 can decode nothing
/// else. Where a real codec is available it wins outright: inter-frame
/// prediction is its whole job, and it does it across the frame rather than in
/// 32px squares, without needing an atlas, a keyframe threshold or progressive
/// refresh to compensate.
final class VideoEncoder {

    /// Called with each encoded access unit, already in wire form. The flag
    /// marks a message a client can resynchronise on - an IDR or the parameter
    /// sets. Without it a client that falls behind is skipped forever, because
    /// the recovery path waits for a message nobody ever marks.
    var onMessage: ((Data, Bool) -> Void)?

    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var lastParameterSets: Data?
    private let lock = NSLock()
    private var wantsKeyframe = true

    private var bitrate: Int
    private var fps: Int

    init(bitrate: Int = 8_000_000, fps: Int = 60) {
        self.bitrate = bitrate
        self.fps = fps
    }

    deinit { teardown() }

    /// Forces the next frame to be an IDR. A client that has just connected has
    /// no reference frames, so anything else is undecodable.
    func requestKeyframe() {
        lock.lock(); wantsKeyframe = true; lock.unlock()
    }

    /// Re-sends SPS/PPS to a newly attached client without waiting for the
    /// format to change.
    var parameterSetMessage: Data? {
        lock.lock(); defer { lock.unlock() }
        return lastParameterSets
    }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        if session == nil || bufferWidth != width || bufferHeight != height {
            prepare(width: bufferWidth, height: bufferHeight)
        }
        guard let session else { return }

        lock.lock()
        let forceKeyframe = wantsKeyframe
        wantsKeyframe = false
        lock.unlock()

        var properties: CFDictionary?
        if forceKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime,
            duration: .invalid, frameProperties: properties,
            sourceFrameRefcon: nil, infoFlagsOut: nil)
    }

    // MARK: - Session

    private func prepare(width newWidth: Int, height newHeight: Int) {
        teardown()
        width = newWidth
        height = newHeight

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(newWidth), height: Int32(newHeight),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sampleBuffer in
                guard status == noErr, let refcon, let sampleBuffer else { return }
                let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
                encoder.handle(sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created)
        guard status == noErr, let session = created else {
            FileHandle.standardError.write(
                "[ExtraPad] Could not create the H.264 encoder (status \(status))\n".data(using: .utf8)!)
            return
        }

        // Screen content, shown live: latency matters far more than squeezing
        // the last few percent out of the bitrate.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: fps))
        // Periodic IDRs cost bandwidth; a client that needs one asks.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: 600))
        VTCompressionSessionPrepareToEncodeFrames(session)

        self.session = session
        lock.lock(); wantsKeyframe = true; lastParameterSets = nil; lock.unlock()
    }

    private func teardown() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    // MARK: - Output

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        let isKeyframe = Self.isKeyframe(sampleBuffer)

        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let message = Self.parameterSetMessage(from: format) {
            lock.lock()
            let changed = lastParameterSets != message
            lastParameterSets = message
            lock.unlock()
            // Only worth re-sending when they actually changed; a client that
            // just joined is given them directly.
            if changed { onMessage?(message, true) }
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }

        // VideoToolbox hands back AVCC already: length-prefixed NAL units.
        let avcc = Data(bytes: pointer, count: length)
        onMessage?(VideoMessage.frame(isKeyframe: isKeyframe, avcc: avcc).encoded(),
                   isKeyframe)
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else { return true }
        let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        guard let raw = CFDictionaryGetValue(first as CFDictionary, key) else { return true }
        return !CFBooleanGetValue(unsafeBitCast(raw, to: CFBoolean.self))
    }

    private static func parameterSetMessage(from format: CMFormatDescription) -> Data? {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil) == noErr, count > 0 else { return nil }

        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        return VideoMessage.parameterSets(width: Int(dimensions.width),
                                          height: Int(dimensions.height),
                                          sets: sets).encoded()
    }
}
