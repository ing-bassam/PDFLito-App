import XCTest
@testable import PDFLito

final class CaptureGateTests: XCTestCase {
    private let page = Quad(topLeft: CGPoint(x: 0.1, y: 0.9), topRight: CGPoint(x: 0.9, y: 0.9),
                            bottomRight: CGPoint(x: 0.9, y: 0.1), bottomLeft: CGPoint(x: 0.1, y: 0.1))

    private func shifted(_ quad: Quad, by offset: CGFloat) -> Quad {
        func move(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + offset, y: point.y) }
        return Quad(topLeft: move(quad.topLeft), topRight: move(quad.topRight),
                    bottomRight: move(quad.bottomRight), bottomLeft: move(quad.bottomLeft))
    }

    func testQuadGeometry() {
        XCTAssertEqual(page.area, 0.64, accuracy: 0.0001)
        XCTAssertEqual(page.center.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(page.maximumCornerDistance(to: shifted(page, by: 0.05)), 0.05, accuracy: 0.0001)
    }

    func testDoesNotFireTheMomentAPageAppears() {
        var gate = CaptureGate()
        XCTAssertEqual(gate.update(quad: nil, isSteady: true, isFocusing: false, now: 0), .searching)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 0.1), .holding(progress: 0))
        XCTAssertNotEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 0.5), .ready)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 0.95), .ready)
    }

    func testMovementRestartsTheWait() {
        var gate = CaptureGate()
        _ = gate.update(quad: page, isSteady: true, isFocusing: false, now: 0)
        XCTAssertEqual(gate.update(quad: page, isSteady: false, isFocusing: false, now: 0.7), .moving)
        XCTAssertNotEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 0.9), .ready,
                          "the calm time before the shake must not count")
        XCTAssertEqual(gate.update(quad: shifted(page, by: 0.05), isSteady: true, isFocusing: false, now: 1.0), .moving,
                       "a page sliding through the picture is movement too")
        _ = gate.update(quad: shifted(page, by: 0.05), isSteady: true, isFocusing: false, now: 1.1)
        XCTAssertEqual(gate.update(quad: shifted(page, by: 0.05), isSteady: true, isFocusing: false, now: 2.0), .ready)
    }

    func testWaitsWhileTheLensIsFocusing() {
        var gate = CaptureGate()
        _ = gate.update(quad: page, isSteady: true, isFocusing: false, now: 0)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: true, now: 0.7), .focusing)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: true, now: 3), .focusing)
        XCTAssertNotEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 3.1), .ready)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 4), .ready)
    }

    func testSmallPageAsksToComeCloser() {
        var gate = CaptureGate()
        let small = Quad(topLeft: CGPoint(x: 0.4, y: 0.6), topRight: CGPoint(x: 0.6, y: 0.6),
                         bottomRight: CGPoint(x: 0.6, y: 0.4), bottomLeft: CGPoint(x: 0.4, y: 0.4))
        XCTAssertEqual(gate.update(quad: small, isSteady: true, isFocusing: false, now: 0), .tooSmall)
        XCTAssertEqual(gate.update(quad: small, isSteady: true, isFocusing: false, now: 5), .tooSmall)
    }

    func testSamePageIsNotCapturedTwice() {
        var gate = CaptureGate()
        _ = gate.update(quad: page, isSteady: true, isFocusing: false, now: 0)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 1), .ready)
        gate.didCapture(quad: page, accepted: true, now: 1)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 5), .waitingForNextPage)
        // The page is taken away and the next one is laid down.
        XCTAssertEqual(gate.update(quad: nil, isSteady: true, isFocusing: false, now: 6), .searching)
        _ = gate.update(quad: page, isSteady: true, isFocusing: false, now: 6.5)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 7.5), .ready)
    }

    func testBlurryShotIsRetriedAfterAnotherCalmMoment() {
        var gate = CaptureGate()
        _ = gate.update(quad: page, isSteady: true, isFocusing: false, now: 0)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 1), .ready)
        gate.didCapture(quad: page, accepted: false, now: 1)
        XCTAssertNotEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 1.1), .ready)
        XCTAssertNotEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 1.5), .waitingForNextPage)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 2.4), .ready)
    }
}
