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
        XCTAssertNotEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 1.0), .ready, "0.9 s of calm is not enough")
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 1.4), .ready)
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
        XCTAssertEqual(gate.update(quad: shifted(page, by: 0.05), isSteady: true, isFocusing: false, now: 2.4), .ready)
    }

    func testWaitsWhileTheLensIsFocusing() {
        var gate = CaptureGate()
        _ = gate.update(quad: page, isSteady: true, isFocusing: false, now: 0)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: true, now: 0.7), .focusing)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: true, now: 3), .focusing)
        XCTAssertNotEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 3.1), .ready)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 4.4), .ready)
    }

    func testPageTouchingTheFrameEdgeIsNotCaptured() {
        var gate = CaptureGate()
        let cut = Quad(topLeft: CGPoint(x: 0.0, y: 0.95), topRight: CGPoint(x: 0.9, y: 0.95),
                       bottomRight: CGPoint(x: 0.9, y: 0.05), bottomLeft: CGPoint(x: 0.0, y: 0.05))
        XCTAssertEqual(gate.update(quad: cut, isSteady: true, isFocusing: false, now: 0), .cutOff)
        XCTAssertEqual(gate.update(quad: cut, isSteady: true, isFocusing: false, now: 5), .cutOff, "a page that leaves the frame is never captured")
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
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 1.3), .ready)
        gate.didCapture(quad: page, accepted: true, now: 1.3)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 5), .waitingForNextPage)
        // The page is taken away and the next one is laid down.
        XCTAssertEqual(gate.update(quad: nil, isSteady: true, isFocusing: false, now: 6), .searching)
        _ = gate.update(quad: page, isSteady: true, isFocusing: false, now: 6.5)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 7.8), .ready)
    }

    func testBlurryShotIsRetriedAfterAnotherCalmMoment() {
        var gate = CaptureGate()
        _ = gate.update(quad: page, isSteady: true, isFocusing: false, now: 0)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 1.3), .ready)
        gate.didCapture(quad: page, accepted: false, now: 1.3)
        XCTAssertNotEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 1.4), .ready)
        XCTAssertNotEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 1.8), .waitingForNextPage)
        XCTAssertEqual(gate.update(quad: page, isSteady: true, isFocusing: false, now: 2.9), .ready)
    }
}
