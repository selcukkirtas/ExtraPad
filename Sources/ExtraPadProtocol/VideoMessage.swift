import Foundation

/// Protocol version 2: H.264 instead of hand-rolled tile diffing.
///
/// Version 1 exists because Safari on iOS 9 can decode nothing else. A native
/// client has a hardware codec, and inter-frame prediction is exactly what a
/// codec does - better than comparing 32px tiles ever could, and without the
/// atlas, the keyframe policy or the progressive refresh those tiles needed.
public enum VideoMessage {

    /// SPS/PPS. A decoder cannot start without these, so they are sent when a
    /// client connects and again whenever the format changes.
    case parameterSets(width: Int, height: Int, sets: [Data])

    /// One access unit in AVCC form: each NAL unit prefixed by its 4-byte
    /// length, which is what VideoToolbox produces and consumes.
    case frame(isKeyframe: Bool, avcc: Data)

    private enum Kind: UInt8 {
        case parameterSets = 0
        case frame = 1
    }

    public func encoded() -> Data {
        switch self {
        case let .parameterSets(width, height, sets):
            var data = Data([Kind.parameterSets.rawValue, UInt8(clamping: sets.count)])
            data.append(bigEndian: UInt16(clamping: width))
            data.append(bigEndian: UInt16(clamping: height))
            for set in sets {
                data.append(bigEndian: UInt16(clamping: set.count))
                data.append(set)
            }
            return data

        case let .frame(isKeyframe, avcc):
            var data = Data([Kind.frame.rawValue, isKeyframe ? 1 : 0])
            data.append(avcc)
            return data
        }
    }

    public static func decode(_ data: Data) -> VideoMessage? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, let kind = Kind(rawValue: bytes[0]) else { return nil }

        switch kind {
        case .frame:
            return .frame(isKeyframe: bytes[1] & 1 != 0, avcc: Data(bytes[2...]))

        case .parameterSets:
            guard bytes.count >= 6 else { return nil }
            let count = Int(bytes[1])
            let width = Int(bytes[2]) << 8 | Int(bytes[3])
            let height = Int(bytes[4]) << 8 | Int(bytes[5])
            var sets: [Data] = []
            var offset = 6
            for _ in 0..<count {
                guard bytes.count >= offset + 2 else { return nil }
                let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard bytes.count >= offset + length else { return nil }
                sets.append(Data(bytes[offset..<(offset + length)]))
                offset += length
            }
            return .parameterSets(width: width, height: height, sets: sets)
        }
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }
}
