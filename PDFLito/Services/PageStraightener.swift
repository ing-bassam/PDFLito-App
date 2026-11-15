import CoreGraphics
import Foundation

/// Makes a scanned page look like it came from a flatbed scanner: text lines run level and an
/// A4 sheet has A4 proportions. The edge detection of the camera is often a little off – one
/// corner sits a few millimetres wrong, or the sheet is not lying flat – and the page ends up
/// tilted, or level at the top and sloping at the bottom. The text itself is the better ruler:
/// its lines tell how every part of the page really lies.
enum PageStraightener {
    /// How the page has to be bent back: one rotation for the whole sheet plus a coarse grid of
    /// vertical shifts that level whatever tilt is left in each part of the page – a sheet that
    /// is level at the top and sloping at the bottom, or a letter that bulges at its folds.
    struct Warp: Equatable {
        /// Radians, counter-clockwise.
        var rotation: Double
        var columns: Int
        var rows: Int
        /// Upward shift as a fraction of the page height; rows from the bottom, columns from the left.
        var shifts: [Double]

        static let none = Warp(rotation: 0, columns: 0, rows: 0, shifts: [])

        var largestShift: Double {
            shifts.map { abs($0) }.max() ?? 0
        }

        /// Shift at a point of the page (0…1 from the left and from the bottom edge).
        func shift(x: Double, y: Double) -> Double {
            guard columns > 1, rows > 1 else { return 0 }
            let px = max(0, min(Double(columns - 1), x * Double(columns - 1)))
            let py = max(0, min(Double(rows - 1), y * Double(rows - 1)))
            let c0 = min(columns - 2, Int(px)), r0 = min(rows - 2, Int(py))
            let fx = px - Double(c0), fy = py - Double(r0)
            let lower = shifts[r0 * columns + c0] * (1 - fx) + shifts[r0 * columns + c0 + 1] * fx
            let upper = shifts[(r0 + 1) * columns + c0] * (1 - fx) + shifts[(r0 + 1) * columns + c0 + 1] * fx
            return lower * (1 - fy) + upper * fy
        }
    }

    struct Result {
        let image: CGImage
        /// The pixels were warped, so text positions found before no longer fit.
        let warped: Bool
    }

    static let gridColumns = 9
    static let gridRows = 13
    /// Rotations below this (about 0.2°) are not worth resampling the page for.
    static let minimumRotation = 0.0035
    /// Shifts below this share of the page height are measuring noise, not a bent page.
    static let minimumShift = 0.004
    /// Beyond this (about 12°) the lines are probably not ordinary body text.
    static let maximumRotation = 0.21
    /// Width ÷ height of ISO paper (A4, A5 …) in portrait.
    static let paperRatio = 1 / 2.0.squareRoot()

    // MARK: - Measuring

    static func warp(of lines: [RecognizedLine], width: Int, height: Int) -> Warp? {
        struct Sample {
            let angle: Double
            /// Middle of the line in pixels, measured from the page centre, y pointing up.
            let x: Double
            let y: Double
            let length: Double
        }
        let w = Double(width), h = Double(height)
        guard w > 0, h > 0 else { return nil }
        var samples: [Sample] = []
        for line in lines {
            guard let left = line.bottomLeft, let right = line.bottomRight else { continue }
            let dx = (right.x - left.x) * w, dy = (right.y - left.y) * h
            let length = (dx * dx + dy * dy).squareRoot()
            // Tiny snippets (page numbers, single short words) give unreliable angles.
            guard dx > 0, length >= 0.12 * w else { continue }
            samples.append(Sample(angle: atan2(dy, dx),
                                  x: ((left.x + right.x) / 2 - 0.5) * w,
                                  y: ((left.y + right.y) / 2 - 0.5) * h,
                                  length: length))
        }
        // The rotation of the sheet comes from the long lines; they are the most reliable.
        let long = samples.filter { $0.length >= 0.22 * w }
        guard long.count >= 5 else { return nil }
        let sortedAngles = long.map(\.angle).sorted()
        let rotation = sortedAngles[sortedAngles.count / 2]
        guard abs(rotation) <= maximumRotation else { return nil }

        // Every line says how steeply the print still runs where it lies, once the sheet is level.
        let columns = gridColumns, rows = gridRows
        let cellX = w / Double(columns - 1), cellY = h / Double(rows - 1)
        var sums = [Double](repeating: 0, count: columns * rows)
        var weights = [Double](repeating: 0, count: columns * rows)
        let c = cos(-rotation), s = sin(-rotation)
        for sample in samples where abs(sample.angle - rotation) < 0.1 {
            let middleX = sample.x * c - sample.y * s + w / 2
            let middleY = sample.x * s + sample.y * c + h / 2
            let slope = tan(sample.angle - rotation)
            let steps = max(2, Int((sample.length / (cellX / 3)).rounded(.up)))
            for step in 0...steps {
                let along = (Double(step) / Double(steps) - 0.5) * sample.length
                let x = middleX + along
                let nodeX = x / cellX, nodeY = middleY / cellY
                for row in max(0, Int(nodeY) - 1)...min(rows - 1, Int(nodeY) + 2) {
                    for column in max(0, Int(nodeX) - 1)...min(columns - 1, Int(nodeX) + 2) where column >= 0 {
                        let dx = nodeX - Double(column), dy = nodeY - Double(row)
                        // Long lines know their direction best.
                        let weight = exp(-(dx * dx + dy * dy)) * sample.length / w
                        sums[row * columns + column] += slope * weight
                        weights[row * columns + column] += weight
                    }
                }
            }
        }
        var slopes = filledGrid(sums: sums, weights: weights, columns: columns, rows: rows)
        slopes = smoothed(slopes, columns: columns, rows: rows)
        // Following the slope from the middle of the page outwards gives the height error of
        // every spot – the same way a line of print would wander off a ruler.
        var shifts = [Double](repeating: 0, count: columns * rows)
        let centre = columns / 2
        for row in 0..<rows {
            let base = row * columns
            for column in (centre + 1)..<columns {
                shifts[base + column] = shifts[base + column - 1]
                    + (slopes[base + column - 1] + slopes[base + column]) / 2 * cellX / h
            }
            for column in stride(from: centre - 1, through: 0, by: -1) {
                shifts[base + column] = shifts[base + column + 1]
                    - (slopes[base + column + 1] + slopes[base + column]) / 2 * cellX / h
            }
        }
        let warp = Warp(rotation: rotation, columns: columns, rows: rows, shifts: shifts)
        guard abs(rotation) >= minimumRotation || warp.largestShift >= minimumShift else { return nil }
        guard warp.largestShift <= 0.08 else { return nil }
        return warp
    }

    /// Parts of the page without text take over the shift of their surroundings.
    private static func filledGrid(sums: [Double], weights: [Double], columns: Int, rows: Int) -> [Double] {
        var values = [Double](repeating: 0, count: sums.count)
        var known = [Bool](repeating: false, count: sums.count)
        for index in sums.indices where weights[index] > 0.08 {
            values[index] = sums[index] / weights[index]
            known[index] = true
        }
        guard known.contains(true) else { return values }
        while known.contains(false) {
            var nextValues = values, nextKnown = known
            for row in 0..<rows {
                for column in 0..<columns where !known[row * columns + column] {
                    var sum = 0.0, count = 0.0
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let c = column + dx, r = row + dy
                        guard c >= 0, r >= 0, c < columns, r < rows, known[r * columns + c] else { continue }
                        sum += values[r * columns + c]
                        count += 1
                    }
                    if count > 0 {
                        nextValues[row * columns + column] = sum / count
                        nextKnown[row * columns + column] = true
                    }
                }
            }
            values = nextValues
            known = nextKnown
        }
        return values
    }

    /// A little smoothing keeps one odd line from bending its surroundings.
    private static func smoothed(_ values: [Double], columns: Int, rows: Int) -> [Double] {
        var output = values
        for row in 0..<rows {
            for column in 0..<columns {
                var sum = 0.0, total = 0.0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let c = column + dx, r = row + dy
                        guard c >= 0, r >= 0, c < columns, r < rows else { continue }
                        let weight = dx == 0 && dy == 0 ? 4.0 : (dx == 0 || dy == 0 ? 2.0 : 1.0)
                        sum += values[r * columns + c] * weight
                        total += weight
                    }
                }
                output[row * columns + column] = sum / total
            }
        }
        return output
    }

    /// The size a page should have when it is (almost certainly) a sheet of ISO paper.
    static func paperSize(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        let ratio = Double(width) / Double(height)
        if ratio >= 0.64 && ratio <= 0.80 {
            let target = Int((Double(height) * paperRatio).rounded())
            return abs(target - width) * 100 > width ? (target, height) : nil
        }
        if ratio >= 1 / 0.80 && ratio <= 1 / 0.64 {
            let target = Int((Double(width) * paperRatio).rounded())
            return abs(target - height) * 100 > height ? (width, target) : nil
        }
        return nil
    }

    // MARK: - Correcting

    /// Returns nil when the page is already level and well proportioned.
    static func straighten(_ image: CGImage, lines: [RecognizedLine]) -> Result? {
        let warp = warp(of: lines, width: image.width, height: image.height)
        let paper = paperSize(width: image.width, height: image.height)
        guard warp != nil || paper != nil else { return nil }
        guard let source = ImageProcessor.rgb(image, maxLongSide: max(image.width, image.height)) else { return nil }
        let target = paper ?? (image.width, image.height)
        let level = resampled(source, warp: warp ?? .none, width: target.width, height: target.height)
        guard let result = ImageProcessor.makeCGImage(level) else { return nil }
        return Result(image: result, warped: warp != nil)
    }

    /// Draws the page level: every output pixel looks up where it lies in the photo.
    static func resampled(_ source: RGBImage, warp: Warp, width: Int, height: Int) -> RGBImage {
        let sourceWidth = source.width, sourceHeight = source.height
        let w = Double(sourceWidth), h = Double(sourceHeight)
        let c = cos(warp.rotation), s = sin(warp.rotation)
        let stepX = w / Double(width), stepY = h / Double(height)
        var output = [UInt8](repeating: 255, count: width * height * 4)
        source.pixels.withUnsafeBufferPointer { pixels in
            output.withUnsafeMutableBufferPointer { target in
                // Rows are independent, so they are spread over all processor cores.
                DispatchQueue.concurrentPerform(iterations: height) { row in
                    // Centre of this output row, measured from the page centre, y pointing up.
                    let levelY = h / 2 - (Double(row) + 0.5) * stepY
                    let normalizedY = levelY / h + 0.5
                    var index = row * width * 4
                    for column in 0..<width {
                        let levelX = (Double(column) + 0.5) * stepX - w / 2
                        // Undo the bend at this spot, then the rotation of the whole page.
                        let bentY = levelY + warp.shift(x: levelX / w + 0.5, y: normalizedY) * h
                        let photoX = levelX * c - bentY * s + w / 2 - 0.5
                        let photoY = h / 2 - (levelX * s + bentY * c) - 0.5
                        let x0 = Int(photoX.rounded(.down)), y0 = Int(photoY.rounded(.down))
                        if x0 >= 0, y0 >= 0, x0 < sourceWidth - 1, y0 < sourceHeight - 1 {
                            let fx = photoX - Double(x0), fy = photoY - Double(y0)
                            let a = (y0 * sourceWidth + x0) * 4, b = a + sourceWidth * 4
                            for channel in 0..<3 {
                                let top = Double(pixels[a + channel]) * (1 - fx) + Double(pixels[a + 4 + channel]) * fx
                                let bottom = Double(pixels[b + channel]) * (1 - fx) + Double(pixels[b + 4 + channel]) * fx
                                target[index + channel] = UInt8(max(0, min(255, (top * (1 - fy) + bottom * fy).rounded())))
                            }
                        }
                        index += 4
                    }
                }
            }
        }
        return RGBImage(width: width, height: height, pixels: output)
    }
}
