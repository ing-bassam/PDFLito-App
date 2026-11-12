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
        let pageSharpness = gray.flatMap { QualityChecker.pageSharpness(of: $0) }
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

    /// Sharpness of the whole page, pulled down when parts of it are clearly softer than the rest.
    /// A page that is sharp at the top but smeared at the bottom (the phone moved during the shot, or
    /// the focus sat on one corner) has a decent average yet is unreadable in places – the average
    /// alone would let it through.
    static func pageSharpness(of image: GrayImage) -> Double? {
        guard let overall = sharpness(of: image) else { return nil }
        guard let weakest = weakRegionSharpness(of: image) else { return overall }
        return min(overall, weakest * regionTolerance)
    }

    /// The weakest regions are judged a little more leniently than the page as a whole, because small
    /// print always measures slightly softer than headings.
    static let regionTolerance = 1.1
    static let regionColumns = 4
    static let regionRows = 6

    /// Sharpness of one of the weakest text regions: the page is split into a grid and the value at
    /// the lower eighth of all regions that hold content is returned. Nil when too few regions do.
    ///
    /// A badly smeared region has hardly any strong edges left, so it would silently drop out of an
    /// edge-based measure. Regions that visibly hold ink but lack strong edges are therefore measured
    /// again on their faint edges, which gives them the low value they deserve.
    static func weakRegionSharpness(of image: GrayImage) -> Double? {
        let tileWidth = image.width / regionColumns, tileHeight = image.height / regionRows
        guard tileWidth > 16, tileHeight > 16 else { return nil }
        let levels = contrastLevels(of: image)
        let strongThreshold = levels.range * 12 / 100
        let faintThreshold = max(2, levels.range * 2 / 100)
        let inkDrop = levels.range / 10
        let minimumEdges = max(150, tileWidth * tileHeight / 400)
        var values: [Double] = []
        for row in 0..<regionRows {
            for column in 0..<regionColumns {
                let x = column * tileWidth, y = row * tileHeight
                let strong = edgeSums(of: image, x: x, y: y, width: tileWidth, height: tileHeight,
                                      edgeThreshold: strongThreshold)
                if strong.edgePixels >= minimumEdges, strong.gradient > 0 {
                    values.append(Double(strong.laplace) / Double(strong.gradient))
                    continue
                }
                guard inkShare(of: image, x: x, y: y, width: tileWidth, height: tileHeight, drop: inkDrop) >= 0.02 else {
                    continue
                }
                let faint = edgeSums(of: image, x: x, y: y, width: tileWidth, height: tileHeight,
                                     edgeThreshold: faintThreshold)
                if faint.edgePixels >= minimumEdges, faint.gradient > 0 {
                    values.append(Double(faint.laplace) / Double(faint.gradient))
                }
            }
        }
        guard values.count >= 4 else { return nil }
        values.sort()
        return values[values.count / 8]
    }

    /// Share of pixels in a region that are clearly darker than the paper around them.
    private static func inkShare(of image: GrayImage, x: Int, y: Int, width: Int, height: Int, drop: Int) -> Double {
        var histogram = [Int](repeating: 0, count: 256)
        image.pixels.withUnsafeBufferPointer { p in
            for row in y..<(y + height) {
                let base = row * image.width
                for column in x..<(x + width) {
                    histogram[Int(p[base + column])] += 1
                }
            }
        }
        let paper = percentile(histogram, 0.9)
        let limit = paper - drop
        guard limit > 0 else { return 0 }
        let dark = histogram[0..<limit].reduce(0, +)
        return Double(dark) / Double(width * height)
    }

    /// Ratio of Laplacian to gradient energy on edge pixels. A blurred edge spreads both, but the
    /// Laplacian falls faster, so the ratio tracks the blur radius independently of contrast and of
    /// how much text the page holds. Returns nil when there are too few edges to judge.
    static func sharpness(of image: GrayImage) -> Double? {
        let width = image.width, height = image.height
        guard width > 8, height > 8 else { return nil }
        let sums = edgeSums(of: image, x: 0, y: 0, width: width, height: height,
                            edgeThreshold: contrastLevels(of: image).range * 12 / 100)
        let interior = (width - 2) * (height - 2)
        guard sums.edgePixels >= max(200, interior / 1000), sums.gradient > 0 else { return nil }
        return Double(sums.laplace) / Double(sums.gradient)
    }

    /// Contrast range of the page between its darkest and lightest 2 %. A pixel counts as part of an
    /// edge when its gradient reaches 12 % of that range.
    private static func contrastLevels(of image: GrayImage) -> (low: Int, range: Int) {
        var histogram = [Int](repeating: 0, count: 256)
        for value in image.pixels {
            histogram[Int(value)] += 1
        }
        let low = percentile(histogram, 0.02)
        let high = percentile(histogram, 0.98)
        return (low, max(high - low, 40))
    }

    private static func edgeSums(of image: GrayImage, x: Int, y: Int, width: Int, height: Int,
                                 edgeThreshold: Int) -> (gradient: Int, laplace: Int, edgePixels: Int) {
        let stride = image.width
        let firstRow = max(y, 1), lastRow = min(y + height, image.height - 1)
        let firstColumn = max(x, 1), lastColumn = min(x + width, image.width - 1)
        guard firstRow < lastRow, firstColumn < lastColumn else { return (0, 0, 0) }
        var gradientSum = 0
        var laplaceSum = 0
        var edgePixels = 0
        image.pixels.withUnsafeBufferPointer { p in
            for row in firstRow..<lastRow {
                let base = row * stride
                for column in firstColumn..<lastColumn {
                    let i = base + column
                    let left = Int(p[i - 1]), right = Int(p[i + 1])
                    let up = Int(p[i - stride]), down = Int(p[i + stride])
                    let gradient = abs(right - left) + abs(down - up)
                    if gradient < edgeThreshold { continue }
                    laplaceSum += abs(4 * Int(p[i]) - left - right - up - down)
                    gradientSum += gradient
                    edgePixels += 1
                }
            }
        }
        return (gradientSum, laplaceSum, edgePixels)
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
