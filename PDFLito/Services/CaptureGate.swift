import CoreGraphics
import Foundation

/// The four corners of a detected page, normalized to 0…1 with the origin bottom-left (like Vision).
struct Quad: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    var center: CGPoint {
        let points = corners
        return CGPoint(x: points.reduce(0) { $0 + $1.x } / 4, y: points.reduce(0) { $0 + $1.y } / 4)
    }

    /// Share of the frame the page covers (shoelace formula).
    var area: Double {
        let points = corners
        var sum = 0.0
        for index in 0..<4 {
            let a = points[index], b = points[(index + 1) % 4]
            sum += Double(a.x * b.y - b.x * a.y)
        }
        return abs(sum) / 2
    }

    /// Largest distance any corner moved compared with `other`.
    func maximumCornerDistance(to other: Quad) -> Double {
        zip(corners, other.corners).map { Double(hypot($0.x - $1.x, $0.y - $1.y)) }.max() ?? 0
    }
}

/// Decides when the camera may release the shutter on its own. A photo is only taken once the page
/// has been in view, the phone has been held still and the lens has stopped focusing for a moment –
/// this is what keeps early, blurry captures from happening.
struct CaptureGate {
    struct Config {
        /// The page must cover at least this share of the frame.
        var minimumArea = 0.12
        /// Corner movement (share of the frame) that still counts as "not moving".
        var maximumDrift = 0.025
        /// Everything must stay calm for this long before the shutter is released.
        var holdDuration: TimeInterval = 0.8
        /// Pause between two automatic photos.
        var minimumInterval: TimeInterval = 1.2
        /// After a photo the page must move at least this far (or vanish) before the next one is taken.
        var pageChangeDistance = 0.07
    }

    enum State: Equatable {
        case searching
        case tooSmall
        case moving
        case focusing
        case holding(progress: Double)
        case ready
        case waitingForNextPage
    }

    var config = Config()
    private var anchor: Quad?
    private var stableSince: TimeInterval?
    private var lastCapture: TimeInterval = -.infinity
    private var capturedQuad: Quad?

    init(config: Config = Config()) {
        self.config = config
    }

    mutating func update(quad: Quad?, isSteady: Bool, isFocusing: Bool, now: TimeInterval) -> State {
        if let captured = capturedQuad {
            if let quad, quad.maximumCornerDistance(to: captured) <= config.pageChangeDistance {
                return .waitingForNextPage
            }
            capturedQuad = nil
            restart()
        }
        guard let quad else {
            restart()
            return .searching
        }
        guard quad.area >= config.minimumArea else {
            restart()
            return .tooSmall
        }
        guard isSteady else {
            restart()
            return .moving
        }
        if let anchor, quad.maximumCornerDistance(to: anchor) > config.maximumDrift {
            restart()
            self.anchor = quad
            return .moving
        }
        if anchor == nil {
            anchor = quad
        }
        guard !isFocusing else {
            stableSince = nil
            return .focusing
        }
        let since = stableSince ?? now
        stableSince = since
        let progress = min(1, max(0, (now - since) / config.holdDuration))
        if progress >= 1, now - lastCapture >= config.minimumInterval {
            return .ready
        }
        return .holding(progress: progress)
    }

    /// Call after every photo. A rejected (blurry) photo is simply tried again after another calm moment.
    mutating func didCapture(quad: Quad?, accepted: Bool, now: TimeInterval) {
        lastCapture = now
        restart()
        capturedQuad = accepted ? quad : nil
    }

    /// Forget the last page, e.g. when the user removes it or switches the mode.
    mutating func reset() {
        capturedQuad = nil
        restart()
    }

    private mutating func restart() {
        anchor = nil
        stableSince = nil
    }
}
