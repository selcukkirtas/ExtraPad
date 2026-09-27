import Foundation

/// One frame of screen updates: several rectangles carried inside a single
/// JPEG, plus where each one belongs on the client's canvas.
///
/// One image per frame rather than one per rectangle is the whole point. The
/// first version sent each region separately, which meant one decode round trip
/// per region in the client; on an old iPad each of those costs 10-20 ms, so at
/// tens of regions per second the picture fell behind the mouse.
public struct AtlasMessage {

    public struct Region: Equatable {
        /// Row of this region inside the atlas image.
        public let sourceY: Int
        /// Where it goes on the canvas.
        public let destX: Int
        public let destY: Int
        public let width: Int
        public let height: Int

        public init(sourceY: Int, destX: Int, destY: Int, width: Int, height: Int) {
            self.sourceY = sourceY
            self.destX = destX
            self.destY = destY
            self.width = width
            self.height = height
        }
    }

    public let regions: [Region]
    public let isKeyframe: Bool
    public let showsDiagnostics: Bool
    public let jpeg: Data

    public init(regions: [Region], isKeyframe: Bool, showsDiagnostics: Bool, jpeg: Data) {
        self.regions = regions
        self.isKeyframe = isKeyframe
        self.showsDiagnostics = showsDiagnostics
        self.jpeg = jpeg
    }

    // MARK: - Wire format
    //
    //     u8  flags          bit 0 = keyframe, bit 1 = show the diagnostic strip
    //     u8  regionCount
    //     regionCount x { u16 sourceY, u16 destX, u16 destY, u16 width, u16 height }
    //     ... JPEG bytes ...
    //
    // Big-endian throughout so a browser can read it with DataView's defaults.

    static let headerSize = 2
    static let regionSize = 10

    public func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + regions.count * Self.regionSize + jpeg.count)
        data.append((isKeyframe ? 1 : 0) | (showsDiagnostics ? 2 : 0))
        data.append(UInt8(clamping: regions.count))
        for region in regions {
            for value in [region.sourceY, region.destX, region.destY,
                          region.width, region.height].map({ UInt16(clamping: $0) }) {
                data.append(UInt8(value >> 8))
                data.append(UInt8(value & 0xFF))
            }
        }
        data.append(jpeg)
        return data
    }

    /// The decoder side, so a native client never has to reimplement the layout
    /// and drift from it.
    public static func decode(_ data: Data) -> AtlasMessage? {
        // Copied into an array on purpose. A client reads these off a socket,
        // so `data` is routinely a slice whose indices do not start at zero;
        // indexing it directly would read the wrong bytes or trap.
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize else { return nil }
        let flags = bytes[0]
        let count = Int(bytes[1])
        let jpegStart = headerSize + count * regionSize
        guard bytes.count >= jpegStart else { return nil }

        var regions: [Region] = []
        regions.reserveCapacity(count)
        for index in 0..<count {
            let base = headerSize + index * regionSize
            func value(_ offset: Int) -> Int {
                Int(bytes[base + offset]) << 8 | Int(bytes[base + offset + 1])
            }
            regions.append(Region(sourceY: value(0), destX: value(2), destY: value(4),
                                  width: value(6), height: value(8)))
        }
        return AtlasMessage(regions: regions,
                            isKeyframe: flags & 1 != 0,
                            showsDiagnostics: flags & 2 != 0,
                            jpeg: Data(bytes[jpegStart...]))
    }
}
