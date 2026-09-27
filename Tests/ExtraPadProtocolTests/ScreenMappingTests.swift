import Testing
import CoreGraphics
@testable import ExtraPadProtocol

@Suite("Touch mapping")
struct ScreenMappingTests {

    /// A 1024x768 host inside a 1000x1000 view: the picture is 1000x750 with
    /// 125 points of letterbox above and below.
    private let wideView = ScreenMapping(hostSize: CGSize(width: 1024, height: 768),
                                         viewSize: CGSize(width: 1000, height: 1000))

    @Test("The centre of the picture maps to the centre of the display")
    func centre() throws {
        let rect = wideView.drawnRect
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let pixel = try #require(wideView.hostPixel(at: point))
        #expect(abs(pixel.x - 512) <= 1)
        #expect(abs(pixel.y - 384) <= 1)
    }

    @Test("Corners map to corners, not past them")
    func corners() throws {
        let rect = wideView.drawnRect
        let topLeft = try #require(wideView.hostPixel(at: CGPoint(x: rect.minX, y: rect.minY)))
        #expect(topLeft.x == 0)
        #expect(topLeft.y == 0)

        let bottomRight = try #require(wideView.hostPixel(at: CGPoint(x: rect.maxX, y: rect.maxY)))
        #expect(bottomRight.x == 1023)
        #expect(bottomRight.y == 767)
    }

    @Test("Touching the letterbox is not a touch on the screen")
    func letterboxIsIgnored() {
        // Above the picture: the view is taller than the 4:3 host.
        #expect(wideView.hostPixel(at: CGPoint(x: 500, y: 10)) == nil)
        #expect(wideView.hostPixel(at: CGPoint(x: 500, y: 990)) == nil)
    }

    @Test("Mapping against the view instead of the picture would skew it")
    func mappingIsAgainstTheDrawnPicture() throws {
        // A quarter of the way down the *picture* is a quarter of the way down
        // the display. Measuring from the view's top would land much lower.
        let rect = wideView.drawnRect
        let quarter = CGPoint(x: rect.minX + rect.width / 4, y: rect.minY + rect.height / 4)
        let pixel = try #require(wideView.hostPixel(at: quarter))
        #expect(abs(pixel.x - 256) <= 1)
        #expect(abs(pixel.y - 192) <= 1)
    }

    @Test("A view narrower than the host letterboxes on the sides instead")
    func tallView() throws {
        let mapping = ScreenMapping(hostSize: CGSize(width: 1024, height: 768),
                                    viewSize: CGSize(width: 400, height: 1000))
        let rect = mapping.drawnRect
        #expect(rect.width == 400)
        #expect(abs(rect.height - 300) < 0.001)
        #expect(mapping.hostPixel(at: CGPoint(x: 200, y: 50)) == nil)   // above
        let inside = try #require(mapping.hostPixel(at: CGPoint(x: rect.midX, y: rect.midY)))
        #expect(abs(inside.x - 512) <= 1)
    }

    @Test("A degenerate size does not crash or produce nonsense")
    func degenerate() {
        let mapping = ScreenMapping(hostSize: .zero, viewSize: CGSize(width: 100, height: 100))
        #expect(mapping.drawnRect == .zero)
        #expect(mapping.hostPixel(at: CGPoint(x: 10, y: 10)) == nil)
    }
}
