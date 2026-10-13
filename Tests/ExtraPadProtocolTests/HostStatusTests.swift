import Testing
import Foundation
@testable import ExtraPadProtocol

@Suite("Host status")
struct HostStatusTests {

    @Test("Both states survive a round trip")
    func roundTrip() {
        for status in [HostStatus.awake, .locked] {
            #expect(HostStatus.decode(status.wireText) == status)
        }
    }

    @Test("The two states are not each other")
    func distinct() {
        #expect(HostStatus.decode(HostStatus.locked.wireText) != .awake)
    }

    /// Everything else a client sends shares this channel, so a status must
    /// never be read out of a touch or a resync request - and the other way
    /// round, a host adding a line later must not be read as a status.
    @Test("Anything else is ignored rather than guessed at")
    func ignoresOtherText() {
        for text in ["R", "D 10 20", "M 0 0", "U 5 5", "", "S", "S ", "S dozing",
                     "awake", "locked", "s locked"] {
            #expect(HostStatus.decode(text) == nil)
        }
    }

    /// A text frame is the one thing the host sends that is not a frame, so the
    /// opcode has to be right or a client will try to decode words as pixels.
    @Test("A status goes out as a text frame, not a binary one")
    func framedAsText() {
        let frame = WebSocket.textFrame(HostStatus.locked.wireText)
        #expect(frame.first == 0x81)
        #expect(Int(frame[1]) == HostStatus.locked.wireText.utf8.count)
        #expect(String(decoding: frame.dropFirst(2), as: UTF8.self) == "S locked")
    }

    @Test("A frame still goes out as binary")
    func framedAsBinary() {
        #expect(WebSocket.binaryFrame(Data([1, 2, 3])).first == 0x82)
    }
}
