import Testing
import Foundation
@testable import ExtraPadProtocol

/// The encoder runs on the Mac and the decoder will run on the iPad. Nothing
/// else checks that the two agree, and a mismatch shows up as a subtly wrong
/// picture rather than as an error - so it is checked here.
@Suite("Atlas wire format")
struct AtlasMessageTests {

    @Test("A frame survives a round trip unchanged")
    func roundTrip() throws {
        let jpeg = Data((0..<64).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let original = AtlasMessage(
            regions: [
                .init(sourceY: 0, destX: 32, destY: 64, width: 96, height: 128),
                .init(sourceY: 128, destX: 0, destY: 0, width: 1024, height: 768),
            ],
            isKeyframe: true,
            showsDiagnostics: false,
            jpeg: jpeg)

        let decoded = try #require(AtlasMessage.decode(original.encoded()))

        #expect(decoded.regions == original.regions)
        #expect(decoded.isKeyframe)
        #expect(!decoded.showsDiagnostics)
        #expect(decoded.jpeg == jpeg)
    }

    @Test("Both flags are independent")
    func flagsAreIndependent() throws {
        for keyframe in [true, false] {
            for diagnostics in [true, false] {
                let message = AtlasMessage(regions: [], isKeyframe: keyframe,
                                           showsDiagnostics: diagnostics, jpeg: Data([0xFF]))
                let decoded = try #require(AtlasMessage.decode(message.encoded()))
                #expect(decoded.isKeyframe == keyframe)
                #expect(decoded.showsDiagnostics == diagnostics)
            }
        }
    }

    @Test("Coordinates at the top of the u16 range survive")
    func largeCoordinates() throws {
        let message = AtlasMessage(
            regions: [.init(sourceY: 65535, destX: 65535, destY: 65535,
                            width: 65535, height: 65535)],
            isKeyframe: false, showsDiagnostics: true, jpeg: Data())
        let decoded = try #require(AtlasMessage.decode(message.encoded()))
        #expect(decoded.regions.first?.destX == 65535)
        #expect(decoded.regions.first?.height == 65535)
    }

    @Test("Truncated input is refused rather than misread")
    func truncatedInput() {
        let message = AtlasMessage(
            regions: [.init(sourceY: 1, destX: 2, destY: 3, width: 4, height: 5)],
            isKeyframe: false, showsDiagnostics: false, jpeg: Data([1, 2, 3]))
        let full = message.encoded()

        #expect(AtlasMessage.decode(Data()) == nil)
        #expect(AtlasMessage.decode(full.prefix(1)) == nil)
        // Header promises one region but the bytes for it are missing.
        #expect(AtlasMessage.decode(full.prefix(AtlasMessage.headerSize + 4)) == nil)
    }

    @Test("A slice that does not start at zero decodes correctly")
    func decodesFromASlice() throws {
        // What a client actually has: the message sitting partway into a buffer
        // it read off the socket.
        let message = AtlasMessage(
            regions: [.init(sourceY: 7, destX: 11, destY: 13, width: 17, height: 19)],
            isKeyframe: true, showsDiagnostics: false, jpeg: Data([0xAA, 0xBB]))

        var buffer = Data([0xDE, 0xAD, 0xBE, 0xEF])
        buffer.append(message.encoded())
        let slice = buffer.dropFirst(4)
        #expect(slice.startIndex != 0)

        let decoded = try #require(AtlasMessage.decode(slice))
        #expect(decoded.regions == message.regions)
        #expect(decoded.jpeg == Data([0xAA, 0xBB]))
        #expect(decoded.isKeyframe)
    }

    @Test("An empty frame is still a valid frame")
    func noRegions() throws {
        let decoded = try #require(AtlasMessage.decode(
            AtlasMessage(regions: [], isKeyframe: false,
                         showsDiagnostics: false, jpeg: Data()).encoded()))
        #expect(decoded.regions.isEmpty)
        #expect(decoded.jpeg.isEmpty)
    }
}

@Suite("Protocol version")
struct WireProtocolTests {

    @Test("The host serves its own version")
    func servesOwnVersion() {
        #expect(WireProtocol.canServe(WireProtocol.version))
    }

    @Test("Versions outside the supported range are refused")
    func refusesOthers() {
        #expect(!WireProtocol.canServe(WireProtocol.version + 1))
        #expect(!WireProtocol.canServe(WireProtocol.minimumSupportedVersion - 1))
        #expect(!WireProtocol.canServe(0))
    }
}
