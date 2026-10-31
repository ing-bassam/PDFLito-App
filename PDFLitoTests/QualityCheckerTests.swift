import XCTest
@testable import PDFLito

final class QualityCheckerTests: XCTestCase {
    private let sharpPage = DemoContent.render(DemoContent.invoice)

    func testSharpnessFallsWithBlur() throws {
        var values: [Double] = []
        for radius in [0.0, 0.7, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0] {
            let image = radius == 0 ? sharpPage : DemoContent.blurred(sharpPage, radius: radius)
            let cgImage = try XCTUnwrap(image.cgImage)
            let gray = try XCTUnwrap(ImageProcessor.grayscale(cgImage, maxLongSide: QualityChecker.analysisLongSide))
            let value = QualityChecker.sharpness(of: gray) ?? 0
            print("SHARPNESS radius=\(radius) value=\(value)")
            values.append(value)
        }
        for (sharper, blurrier) in zip(values, values.dropFirst()) {
            XCTAssertGreaterThan(sharper, blurrier * 0.98)
        }
        let threshold = QualityChecker.thresholds(for: .normal).minimumSharpness
        XCTAssertGreaterThan(values[0], threshold)
        XCTAssertGreaterThan(values[2], threshold, "slight softness must still pass")
        XCTAssertLessThan(values[values.count - 1], threshold, "heavy blur must be rejected")
    }

    func testSharpPageIsGoodAndBlurryPageIsRejected() throws {
        let good = QualityChecker.analyze(try XCTUnwrap(sharpPage.cgImage), strictness: .normal)
        print("ANALYSIS sharp chars=\(good.characterCount) confidence=\(good.meanConfidence) sharpness=\(String(describing: good.sharpness)) brightness=\(good.brightness) verdict=\(good.verdict)")
        let blurredPage = DemoContent.samplePages()[1]
        let bad = QualityChecker.analyze(try XCTUnwrap(blurredPage.cgImage), strictness: .normal)
        print("ANALYSIS blurred chars=\(bad.characterCount) confidence=\(bad.meanConfidence) sharpness=\(String(describing: bad.sharpness)) brightness=\(bad.brightness) verdict=\(bad.verdict)")

        XCTAssertFalse(bad.verdict.isAcceptable, "blurred page passed: \(bad.verdict)")
        guard good.characterCount > 0 else {
            throw XCTSkip("Texterkennung ist in diesem Simulator nicht verfügbar")
        }
        XCTAssertEqual(good.verdict, .good)
        let suggestions = TitleExtractor.suggestions(from: good.lines)
        print("SUGGESTIONS \(suggestions)")
        XCTAssertTrue(suggestions.first?.contains("Rechnung") ?? false, "unexpected suggestions \(suggestions)")
        XCTAssertNotNil(TitleExtractor.documentDate(in: good.lines))
    }

    func testVerdictRules() {
        func verdict(_ sharpness: Double?, brightness: Double = 0.85, characters: Int = 400, confidence: Double = 0.95) -> QualityVerdict {
            QualityChecker.verdict(sharpness: sharpness, brightness: brightness, characterCount: characters,
                                   meanConfidence: confidence, strictness: .normal)
        }
        XCTAssertEqual(verdict(0.5), .good)
        XCTAssertEqual(verdict(0.05), .blurry)
        XCTAssertEqual(verdict(0.5, confidence: 0.3), .unreadable)
        XCTAssertEqual(verdict(0.5, brightness: 0.1), .tooDark)
        XCTAssertEqual(verdict(0.5, characters: 5), .littleText)
        XCTAssertEqual(verdict(nil, characters: 0), .littleText)
    }
}
