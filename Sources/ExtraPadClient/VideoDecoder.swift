import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 decoding for protocol version 2.
///
/// The atlas path had the client compositing rectangles into a bitmap by hand.
/// Here the codec hands back a finished frame, so the client's job shrinks to
/// feeding it bytes in order and showing what comes out.
final class VideoDecoder {

    /// Called with each decoded frame, on the decoder's own queue.
    var onFrame: ((CGImage) -> Void)?

    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var hasKeyframe = false

    deinit { teardown() }

    func handle(_ message: VideoMessage) {
        switch message {
        case let .parameterSets(_, _, sets):
            apply(parameterSets: sets)
        case let .frame(isKeyframe, avcc):
            // A decoder started mid-stream has no reference frames; feeding it
            // P-frames produces either garbage or nothing at all.
            if isKeyframe { hasKeyframe = true }
            guard hasKeyframe else { return }
            decode(avcc)
        }
    }

    /// Everything after a format change has to be reinterpreted, so the old
    /// session is thrown away rather than reused.
    private func apply(parameterSets sets: [Data]) {
        guard sets.count >= 2 else { return }

        // Explicit allocation rather than withUnsafeBufferPointer: the pointers
        // have to still be valid when CMVideoFormatDescription... is called,
        // and a pointer taken out of that closure is dangling the moment it
        // returns. That mistake decodes as intermittent garbage, not as a crash.
        let arrays = sets.map { [UInt8]($0) }
        var storage: [UnsafeMutablePointer<UInt8>] = []
        let pointers = UnsafeMutablePointer<UnsafePointer<UInt8>>.allocate(capacity: arrays.count)
        let sizes = UnsafeMutablePointer<Int>.allocate(capacity: arrays.count)
        defer {
            storage.forEach { $0.deallocate() }
            pointers.deallocate()
            sizes.deallocate()
        }
        for (index, bytes) in arrays.enumerated() {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            buffer.update(from: bytes, count: bytes.count)
            storage.append(buffer)
            pointers[index] = UnsafePointer(buffer)
            sizes[index] = bytes.count
        }

        var created: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: arrays.count,
            parameterSetPointers: pointers,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &created)

        guard status == noErr, let created else { return }

        teardown()
        format = created
        hasKeyframe = false

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, imageBuffer, _, _ in
                guard status == noErr, let refcon, let imageBuffer else { return }
                let decoder = Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
                decoder.emit(imageBuffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())

        var session: VTDecompressionSession?
        VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: created,
            decoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ] as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &session)
        self.session = session
    }

    private func decode(_ avcc: Data) {
        guard let session, let format else { return }
        var bytes = [UInt8](avcc)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count,
            flags: 0, blockBufferOut: &block) == noErr, let block else { return }

        guard CMBlockBufferReplaceDataBytes(with: &bytes, blockBuffer: block,
                                            offsetIntoDestination: 0,
                                            dataLength: bytes.count) == noErr else { return }

        var sample: CMSampleBuffer?
        var sampleSize = bytes.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample) == noErr, let sample else { return }

        VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample,
            // Display order is send order: the encoder has frame reordering off.
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil, infoFlagsOut: nil)
    }

    private func emit(_ pixelBuffer: CVImageBuffer) {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        if let image { onFrame?(image) }
    }

    private func teardown() {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        self.session = nil
    }
}
