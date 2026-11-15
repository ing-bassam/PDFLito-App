import XCTest
@testable import PDFLito

final class PageStraightenerTests: XCTestCase {
    /// Twenty full-width lines of print, turned by `angle` (radians) around the page centre.
    private func lines(tiltedBy angle: Double, width: Double = 1240, height: Double = 1754) -> [RecognizedLine] {
        (0..<20).map { index in
            let y = (0.1 + Double(index) * 0.04 - 0.5) * height
            func point(_ x: Double, _ y: Double) -> TextPoint {
                TextPoint(x: (x * cos(angle) - y * sin(angle)) / width + 0.5,
                          y: (x * sin(angle) + y * cos(angle)) / height + 0.5)
            }
            let left = point(-0.4 * width, y), right = point(0.4 * width, y)
            return RecognizedLine(text: "Zeile \(index)", box: CGRect(x: 0.1, y: left.y, width: 0.8, height: 0.02),
                                  confidence: 1, words: [], bottomLeft: left, bottomRight: right,
                                  topLeft: point(-0.4 * width, y + 0.02 * height))
        }
    }

    func testLevelPageIsLeftAlone() {
        XCTAssertNil(PageStraightener.warp(of: lines(tiltedBy: 0), width: 1240, height: 1754))
        XCTAssertNil(PageStraightener.paperSize(width: 1240, height: 1754), "already A4")
    }

    func testTiltIsMeasured() throws {
        let angle = 2.0 * .pi / 180
        let warp = try XCTUnwrap(PageStraightener.warp(of: lines(tiltedBy: angle), width: 1240, height: 1754))
        XCTAssertEqual(warp.rotation, angle, accuracy: 0.002)
        XCTAssertLessThan(warp.largestShift, 0.002, "a plain rotation needs no bending")
    }

    func testTooFewLinesGiveNoCorrection() {
        XCTAssertNil(PageStraightener.warp(of: Array(lines(tiltedBy: 0.05).prefix(3)), width: 1240, height: 1754))
    }

    func testStretchedSheetGetsPaperProportions() throws {
        let portrait = try XCTUnwrap(PageStraightener.paperSize(width: 1100, height: 1400))
        XCTAssertEqual(portrait.width, 990)
        XCTAssertEqual(portrait.height, 1400)
        let landscape = try XCTUnwrap(PageStraightener.paperSize(width: 1400, height: 1100))
        XCTAssertEqual(landscape.width, 1400)
        XCTAssertEqual(landscape.height, 990)
        XCTAssertNil(PageStraightener.paperSize(width: 500, height: 1400), "a till receipt is not A4")
        XCTAssertNil(PageStraightener.paperSize(width: 1400, height: 1400))
    }

    /// The whole chain on a rendered page that was photographed crooked.
    func testCrookedPageComesOutLevel() throws {
        let sharp = DemoContent.render(DemoContent.invoiceTerms)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let crooked = UIGraphicsImageRenderer(size: sharp.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: sharp.size))
            context.cgContext.translateBy(x: sharp.size.width / 2, y: sharp.size.height / 2)
            context.cgContext.rotate(by: 2.5 * .pi / 180)
            sharp.draw(at: CGPoint(x: -sharp.size.width / 2, y: -sharp.size.height / 2))
        }
        let source = try XCTUnwrap(crooked.cgImage)
        let found = TextRecognizer.recognize(source)
        let before = try XCTUnwrap(PageStraightener.warp(of: found, width: source.width, height: source.height))
        XCTAssertEqual(abs(before.rotation), 2.5 * .pi / 180, accuracy: 0.012)

        let result = try XCTUnwrap(PageStraightener.straighten(source, lines: found))
        XCTAssertTrue(result.warped)
        let after = PageStraightener.warp(of: TextRecognizer.recognize(result.image),
                                          width: result.image.width, height: result.image.height)
        XCTAssertLessThan(abs(after?.rotation ?? 0), 0.006, "text should run level after straightening")
    }
}
