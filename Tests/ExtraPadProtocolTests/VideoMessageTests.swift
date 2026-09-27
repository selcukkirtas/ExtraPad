import Testing
import Foundation
@testable import ExtraPadProtocol

@Suite("Video wire format")
struct VideoMessageTests {

    @Test("Parameter sets survive a round trip")
    func parameterSets() throws {
        let sps = Data([0x67, 0x42, 0x00, 0x1E])
        let pps = Data([0x68, 0xCE, 0x3C, 0x80])
        let encoded = VideoMessage.parameterSets(width: 2048, height: 1536,
                                                 sets: [sps, pps]).encoded()
        guard case let .parameterSets(width, height, sets) = try #require(VideoMessage.decode(encoded))
        else { Issue.record("wrong case"); return }
        #expect(width == 2048)
        #expect(height == 1536)
        #expect(sets == [sps, pps])
    }

    @Test("A frame survives a round trip, keyframe flag included")
    func frames() throws {
        for keyframe in [true, false] {
            let payload = Data([0, 0, 0, 4, 0x65, 0x88, 0x84, 0x00])
            let encoded = VideoMessage.frame(isKeyframe: keyframe, avcc: payload).encoded()
            guard case let .frame(isKeyframe, avcc) = try #require(VideoMessage.decode(encoded))
            else { Issue.record("wrong case"); return }
            #expect(isKeyframe == keyframe)
            #expect(avcc == payload)
        }
    }

    @Test("A slice that does not start at zero decodes correctly")
    func decodesFromASlice() throws {
        let payload = Data([1, 2, 3, 4, 5])
        var buffer = Data([0xFF, 0xFF])
        buffer.append(VideoMessage.frame(isKeyframe: true, avcc: payload).encoded())
        guard case let .frame(_, avcc) = try #require(VideoMessage.decode(buffer.dropFirst(2)))
        else { Issue.record("wrong case"); return }
        #expect(avcc == payload)
    }

    @Test("Truncated input is refused rather than misread")
    func truncated() {
        let encoded = VideoMessage.parameterSets(width: 100, height: 100,
                                                 sets: [Data([1, 2, 3])]).encoded()
        #expect(VideoMessage.decode(Data()) == nil)
        #expect(VideoMessage.decode(encoded.prefix(1)) == nil)
        // Announces a set longer than the bytes that follow.
        #expect(VideoMessage.decode(encoded.prefix(encoded.count - 1)) == nil)
    }

    @Test("Both protocol versions are servable, and nothing beyond them")
    func versionRange() {
        #expect(WireProtocol.canServe(WireProtocol.atlas))
        #expect(WireProtocol.canServe(WireProtocol.video))
        #expect(!WireProtocol.canServe(WireProtocol.video + 1))
        #expect(!WireProtocol.canServe(0))
    }
}

extension VideoMessage: Equatable {
    public static func == (a: VideoMessage, b: VideoMessage) -> Bool {
        switch (a, b) {
        case let (.frame(k1, d1), .frame(k2, d2)): return k1 == k2 && d1 == d2
        case let (.parameterSets(w1, h1, s1), .parameterSets(w2, h2, s2)):
            return w1 == w2 && h1 == h2 && s1 == s2
        default: return false
        }
    }
}
