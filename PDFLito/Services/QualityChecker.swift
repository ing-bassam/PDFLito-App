import CoreGraphics

/// Decides whether a scanned page is sharp and legible enough to be saved.
enum QualityChecker {
    struct Thresholds {
        let minimumSharpness: Double
        /// Stricter bar when the text recognition cannot confirm legibility (little or no text found).
        let minimumSharpnessWithLittleText: Double
        let minimumConfidence: Double
    }

    /// Measured on rendered pages (blur radius in pixels → sharpness): 0 → 0.72, 0.7 → 0.50, 1 → 0.41,
    /// 1.5 → 0.31, 2 → 0.23, 3 → 0.16. Beyond that the value levels off around 0.15, so the limits stay above it.
    static func thresholds(for strictness: Strictness) -> Thresholds {
        switch strictness {
        case .strict: return Thresholds(minimumSharpness: 0.26, minimumSharpnessWithLittleText: 0.34, minimumConfidence: 0.75)
        case .normal: return Thresholds(minimumSharpness: 0.20, minimumSharpnessWithLittleText: 0.28, minimumConfidence: 0.6)
        case .relaxed: return Thresholds(minimumSharpness: 0.18, minimumSharpnessWithLittleText: 0.23, minimumConfidence: 0.45)
        }
    }

    /// Below this many recognized characters the OCR confidence says little about legibility.
    static let minimumTextForConfidence = 20
    static let analysisLongSide = 1600
    static let minimumBrightness = 0.22

    static func analyze(_ image: CGImage, strictness: Strictness) -> PageAnalysis {
        let lines = TextRecognizer.recognize(image)
        let characters = lines.reduce(0) { $0 + $1.text.count }
        let weighted = lines.reduce(0.0) { $0 + Double($1.confidence) * Double($1.text.count) }
        let confidence = characters > 0 ? weighted / Double(characters) : 0
        let gray = ImageProcessor.grayscale(image, maxLongSide: analysisLongSide)
        let pageSharpness = gray.flatMap { sharpness(of: $0) }
        let pageBrightness = gray.map { brightness(of: $0) } ?? 1
        let result = verdict(sharpness: pageSharpness, brightness: pageBrightness,
                             characterCount: characters, meanConfidence: confidence, strictness: strictness)
        return PageAnalysis(lines: lines, sharpness: pageSharpness, brightness: pageBrightness,
                            characterCount: characters, meanConfidence: confidence, verdict: result)
    }

    static func verdict(sharpness: Double?, brightness: Double, characterCount: Int,
                        meanConfidence: Double, strictness: Strictness) -> QualityVerdict {
        let limits = thresholds(for: strictness)
        if brightness < minimumBrightness {
            return .tooDark
        }
        if let sharpness, sharpness < limits.minimumSharpness {
            return .blurry
        }
        if characterCount >= minimumTextForConfidence {
            return meanConfidence >= limits.minimumConfidence ? .good : .unreadable
        }
        if let sharpness, sharpness < limits.minimumSharpnessWithLittleText {
            return .blurry
        }
        return .littleText
    }

    /// Ratio of Laplacian to gradient energy on edge pixels. A blurred edge spreads both, but the
    /// Laplacian falls faster, so the ratio tracks the blur radius independently of contrast and of
    /// how much text the page holds. Returns nil when there are too few edges to judge.
    static func sharpness(of image: GrayImage) -> Double? {
        let width = image.width, height = image.height
        guard width > 8, height > 8 else { return nil }
        var histogram = [Int](repeating: 0, count: 256)
        for value in image.pixels {
            histogram[Int(value)] += 1
        }
        let low = percentile(histogram, 0.02)
        let high = percentile(histogram, 0.98)
        let range = max(high - low, 40)
        let edgeThreshold = range * 12 / 100
        var gradientSum = 0
        var laplaceSum = 0
        var edgePixels = 0
        image.pixels.withUnsafeBufferPointer { p in
            for y in 1..<(height - 1) {
                let row = y * width
                for x in 1..<(width - 1) {
                    let i = row + x
                    let left = Int(p[i - 1]), right = Int(p[i + 1])
                    let up = Int(p[i - width]), down = Int(p[i + width])
                    let gradient = abs(right - left) + abs(down - up)
                    if gradient < edgeThreshold { continue }
                    laplaceSum += abs(4 * Int(p[i]) - left - right - up - down)
                    gradientSum += gradient
                    edgePixels += 1
                }
            }
        }
        let interior = (width - 2) * (height - 2)
        guard edgePixels >= max(200, interior / 1000), gradientSum > 0 else { return nil }
        return Double(laplaceSum) / Double(gradientSum)
    }

    static func brightness(of image: GrayImage) -> Double {
        guard !image.pixels.isEmpty else { return 1 }
        let total = image.pixels.reduce(0) { $0 + Int($1) }
        return Double(total) / Double(image.pixels.count) / 255
    }

    private static func percentile(_ histogram: [Int], _ fraction: Double) -> Int {
        let total = histogram.reduce(0, +)
        let target = Int(Double(total) * fraction)
        var accumulated = 0
        for (value, count) in histogram.enumerated() {
            accumulated += count
            if accumulated > target {
                return value
            }
        }
        return 255
    }
}
