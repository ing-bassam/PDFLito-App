import UIKit
import ImageIO
import UniformTypeIdentifiers

/// 8-bit grayscale bitmap, rows from top to bottom.
struct GrayImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]
}

/// 8-bit RGBX bitmap (4 bytes per pixel, last byte unused), rows from top to bottom.
struct RGBImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]
}

/// A compressed image stream ready to be embedded into a PDF page.
struct EncodedPage {
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let colorSpace: String
    let bitsPerComponent: Int
    let filter: String?
}

enum ImageProcessor {
    struct OutputProfile {
        let maxLongSide: Int
        let jpegQuality: CGFloat
    }

    /// Output resolution and JPEG quality. An A4 page with 1800 px on the long side is about 150 dpi.
    static func profile(for mode: ColorMode, compression: CompressionLevel) -> OutputProfile {
        switch (mode, compression) {
        case (.blackWhite, .maximum): return OutputProfile(maxLongSide: 1800, jpegQuality: 0)
        case (.blackWhite, .balanced): return OutputProfile(maxLongSide: 2200, jpegQuality: 0)
        case (.blackWhite, .high): return OutputProfile(maxLongSide: 2800, jpegQuality: 0)
        case (.grayscale, .maximum): return OutputProfile(maxLongSide: 1500, jpegQuality: 0.35)
        case (.grayscale, .balanced): return OutputProfile(maxLongSide: 1800, jpegQuality: 0.5)
        case (.grayscale, .high): return OutputProfile(maxLongSide: 2400, jpegQuality: 0.7)
        case (.color, .maximum): return OutputProfile(maxLongSide: 1400, jpegQuality: 0.35)
        case (.color, .balanced): return OutputProfile(maxLongSide: 1700, jpegQuality: 0.5)
        case (.color, .high): return OutputProfile(maxLongSide: 2300, jpegQuality: 0.7)
        }
    }

    // MARK: - Page encoding

    static func encode(_ image: UIImage, mode: ColorMode, compression: CompressionLevel) -> EncodedPage? {
        guard let cgImage = image.cgImage else { return nil }
        let profile = profile(for: mode, compression: compression)
        switch mode {
        case .blackWhite:
            guard let gray = grayscale(cgImage, maxLongSide: profile.maxLongSide) else { return nil }
            let bits = bilevelBits(whitened(gray))
            if let compressed = Zlib.compress(bits) {
                return EncodedPage(data: compressed, pixelWidth: gray.width, pixelHeight: gray.height,
                                   colorSpace: "DeviceGray", bitsPerComponent: 1, filter: "FlateDecode")
            }
            return EncodedPage(data: bits, pixelWidth: gray.width, pixelHeight: gray.height,
                               colorSpace: "DeviceGray", bitsPerComponent: 1, filter: nil)
        case .grayscale:
            guard let gray = grayscale(cgImage, maxLongSide: profile.maxLongSide),
                  let flattened = makeCGImage(whitened(gray)),
                  let jpeg = jpegData(flattened, quality: profile.jpegQuality) else { return nil }
            return EncodedPage(data: jpeg, pixelWidth: gray.width, pixelHeight: gray.height,
                               colorSpace: "DeviceGray", bitsPerComponent: 8, filter: "DCTDecode")
        case .color:
            guard let rgb = rgb(cgImage, maxLongSide: profile.maxLongSide),
                  let flattened = makeCGImage(whitened(rgb)),
                  let jpeg = jpegData(flattened, quality: profile.jpegQuality) else { return nil }
            return EncodedPage(data: jpeg, pixelWidth: rgb.width, pixelHeight: rgb.height,
                               colorSpace: "DeviceRGB", bitsPerComponent: 8, filter: "DCTDecode")
        }
    }

    // MARK: - Drawing

    /// Redraws an image upright (orientation applied) with its long side limited to `maxLongSide` pixels.
    static func normalizedImage(_ image: UIImage, maxLongSide: CGFloat) -> UIImage {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longSide = max(pixelSize.width, pixelSize.height)
        let factor = longSide > maxLongSide ? maxLongSide / longSide : 1
        let target = CGSize(width: max(1, (pixelSize.width * factor).rounded()),
                            height: max(1, (pixelSize.height * factor).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    static func scaledSize(width: Int, height: Int, maxLongSide: Int) -> (width: Int, height: Int) {
        let longSide = max(width, height)
        guard longSide > maxLongSide, longSide > 0 else { return (width, height) }
        let factor = Double(maxLongSide) / Double(longSide)
        return (max(1, Int((Double(width) * factor).rounded())),
                max(1, Int((Double(height) * factor).rounded())))
    }

    static func grayscale(_ image: CGImage, maxLongSide: Int) -> GrayImage? {
        let size = scaledSize(width: image.width, height: image.height, maxLongSide: maxLongSide)
        guard let context = CGContext(data: nil, width: size.width, height: size.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let base = context.data else { return nil }
        let rowBytes = context.bytesPerRow
        let source = base.bindMemory(to: UInt8.self, capacity: rowBytes * size.height)
        var pixels = [UInt8](repeating: 0, count: size.width * size.height)
        pixels.withUnsafeMutableBufferPointer { target in
            guard let destination = target.baseAddress else { return }
            for y in 0..<size.height {
                (destination + y * size.width).update(from: source + y * rowBytes, count: size.width)
            }
        }
        return GrayImage(width: size.width, height: size.height, pixels: pixels)
    }

    static func rgb(_ image: CGImage, maxLongSide: Int) -> RGBImage? {
        let size = scaledSize(width: image.width, height: image.height, maxLongSide: maxLongSide)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size.width, height: size.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let base = context.data else { return nil }
        let rowBytes = context.bytesPerRow
        let packedRow = size.width * 4
        let source = base.bindMemory(to: UInt8.self, capacity: rowBytes * size.height)
        var pixels = [UInt8](repeating: 0, count: packedRow * size.height)
        pixels.withUnsafeMutableBufferPointer { target in
            guard let destination = target.baseAddress else { return }
            for y in 0..<size.height {
                (destination + y * packedRow).update(from: source + y * rowBytes, count: packedRow)
            }
        }
        return RGBImage(width: size.width, height: size.height, pixels: pixels)
    }

    // MARK: - Cleanup

    /// Divides by the paper brightness so shadows and uneven light disappear and the page turns white.
    static func whitened(_ image: GrayImage) -> GrayImage {
        let background = BackgroundMap(image)
        let lookup = background.columnLookup(width: image.width)
        let width = image.width
        var output = [UInt8](repeating: 255, count: image.pixels.count)
        var row = [Float](repeating: 255, count: width)
        image.pixels.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                for y in 0..<image.height {
                    background.fill(row: y, lookup: lookup, into: &row)
                    let base = y * width
                    for x in 0..<width {
                        target[base + x] = levels(Float(source[base + x]) / row[x])
                    }
                }
            }
        }
        return GrayImage(width: image.width, height: image.height, pixels: output)
    }

    static func whitened(_ image: RGBImage) -> RGBImage {
        let background = BackgroundMap(luminance(image))
        let lookup = background.columnLookup(width: image.width)
        let width = image.width
        var output = [UInt8](repeating: 255, count: image.pixels.count)
        var row = [Float](repeating: 255, count: width)
        image.pixels.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                for y in 0..<image.height {
                    background.fill(row: y, lookup: lookup, into: &row)
                    for x in 0..<width {
                        let i = (y * width + x) * 4
                        let paper = row[x]
                        target[i] = levels(Float(source[i]) / paper)
                        target[i + 1] = levels(Float(source[i + 1]) / paper)
                        target[i + 2] = levels(Float(source[i + 2]) / paper)
                        target[i + 3] = 255
                    }
                }
            }
        }
        return RGBImage(width: image.width, height: image.height, pixels: output)
    }

    /// Maps brightness relative to the paper: ≥ 90 % becomes pure white, ≤ 10 % pure black.
    @inline(__always)
    static func levels(_ relative: Float) -> UInt8 {
        let t = (relative - 0.1) / 0.8
        if t <= 0 { return 0 }
        if t >= 1 { return 255 }
        return UInt8(t * 255)
    }

    static func luminance(_ image: RGBImage) -> GrayImage {
        var gray = [UInt8](repeating: 0, count: image.width * image.height)
        image.pixels.withUnsafeBufferPointer { source in
            gray.withUnsafeMutableBufferPointer { target in
                for i in 0..<target.count {
                    let r = Int(source[i * 4]), g = Int(source[i * 4 + 1]), b = Int(source[i * 4 + 2])
                    target[i] = UInt8((77 * r + 150 * g + 29 * b) >> 8)
                }
            }
        }
        return GrayImage(width: image.width, height: image.height, pixels: gray)
    }

    /// Packs a whitened page into 1-bit rows (1 = white), dropping isolated specks.
    static func bilevelBits(_ image: GrayImage, threshold: UInt8 = 185) -> Data {
        let width = image.width, height = image.height
        var ink = [UInt8](repeating: 0, count: width * height)
        image.pixels.withUnsafeBufferPointer { source in
            ink.withUnsafeMutableBufferPointer { target in
                for i in 0..<target.count where source[i] < threshold {
                    target[i] = 1
                }
            }
        }
        let rowBytes = (width + 7) / 8
        var packed = [UInt8](repeating: 0, count: rowBytes * height)
        ink.withUnsafeBufferPointer { inkPixels in
            packed.withUnsafeMutableBufferPointer { bits in
                for y in 0..<height {
                    let row = y * width
                    for x in 0..<width {
                        var isInk = inkPixels[row + x] == 1
                        if isInk && x > 0 && y > 0 && x < width - 1 && y < height - 1 {
                            let above = Int(inkPixels[row - width + x - 1]) + Int(inkPixels[row - width + x]) + Int(inkPixels[row - width + x + 1])
                            let beside = Int(inkPixels[row + x - 1]) + Int(inkPixels[row + x + 1])
                            let below = Int(inkPixels[row + width + x - 1]) + Int(inkPixels[row + width + x]) + Int(inkPixels[row + width + x + 1])
                            isInk = above + beside + below > 0
                        }
                        if !isInk {
                            bits[y * rowBytes + (x >> 3)] |= UInt8(0x80 >> (x & 7))
                        }
                    }
                }
            }
        }
        return Data(packed)
    }

    // MARK: - Encoding helpers

    static func makeCGImage(_ image: GrayImage) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(image.pixels) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func makeCGImage(_ image: RGBImage) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(image.pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func jpegData(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Coarse estimate of the paper brightness across the page.
struct BackgroundMap {
    struct ColumnLookup {
        let x0: [Int]
        let x1: [Int]
        let fraction: [Float]
    }

    let block: Int
    let columns: Int
    let rows: Int
    let grid: [Float]

    init(_ image: GrayImage, block: Int = 24) {
        let columns = max(1, (image.width + block - 1) / block)
        let rows = max(1, (image.height + block - 1) / block)
        let width = image.width, height = image.height
        var values = [Float](repeating: 255, count: columns * rows)
        image.pixels.withUnsafeBufferPointer { pixels in
            for by in 0..<rows {
                let y0 = by * block, y1 = min(height, y0 + block)
                for bx in 0..<columns {
                    let x0 = bx * block, x1 = min(width, x0 + block)
                    var brightest: UInt8 = 0
                    var y = y0
                    while y < y1 {
                        let row = y * width
                        var x = x0
                        while x < x1 {
                            let value = pixels[row + x]
                            if value > brightest { brightest = value }
                            x += 2
                        }
                        y += 2
                    }
                    values[by * columns + bx] = Float(brightest)
                }
            }
        }
        values = BackgroundMap.neighbourhood(values, columns: columns, rows: rows, useMaximum: true)
        values = BackgroundMap.neighbourhood(values, columns: columns, rows: rows, useMaximum: false)
        values = BackgroundMap.neighbourhood(values, columns: columns, rows: rows, useMaximum: false)
        // Keep large dark areas (photos, dark bars) from being washed out to white.
        let sorted = values.sorted()
        let paper = sorted[min(sorted.count - 1, Int(Float(sorted.count) * 0.9))]
        let lowest = max(40, paper * 0.55)
        self.block = block
        self.columns = columns
        self.rows = rows
        self.grid = values.map { max($0, lowest) }
    }

    func columnLookup(width: Int) -> ColumnLookup {
        var x0 = [Int](repeating: 0, count: width)
        var x1 = [Int](repeating: 0, count: width)
        var fraction = [Float](repeating: 0, count: width)
        for x in 0..<width {
            let position = (Float(x) + 0.5) / Float(block) - 0.5
            let left = max(0, min(columns - 1, Int(position.rounded(.down))))
            x0[x] = left
            x1[x] = min(columns - 1, left + 1)
            fraction[x] = max(0, min(1, position - Float(left)))
        }
        return ColumnLookup(x0: x0, x1: x1, fraction: fraction)
    }

    /// Writes the interpolated paper brightness of every pixel in row `y` into `row`.
    func fill(row y: Int, lookup: ColumnLookup, into row: inout [Float]) {
        let position = (Float(y) + 0.5) / Float(block) - 0.5
        let top = max(0, min(rows - 1, Int(position.rounded(.down))))
        let bottom = min(rows - 1, top + 1)
        let fy = max(0, min(1, position - Float(top)))
        let topBase = top * columns, bottomBase = bottom * columns
        for x in 0..<row.count {
            let fx = lookup.fraction[x]
            let upper = grid[topBase + lookup.x0[x]] * (1 - fx) + grid[topBase + lookup.x1[x]] * fx
            let lower = grid[bottomBase + lookup.x0[x]] * (1 - fx) + grid[bottomBase + lookup.x1[x]] * fx
            row[x] = upper * (1 - fy) + lower * fy
        }
    }

    private static func neighbourhood(_ values: [Float], columns: Int, rows: Int, useMaximum: Bool) -> [Float] {
        var output = values
        for y in 0..<rows {
            for x in 0..<columns {
                var maximum: Float = 0
                var sum: Float = 0
                var count: Float = 0
                for dy in -1...1 {
                    let yy = y + dy
                    guard yy >= 0 && yy < rows else { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        guard xx >= 0 && xx < columns else { continue }
                        let value = values[yy * columns + xx]
                        maximum = max(maximum, value)
                        sum += value
                        count += 1
                    }
                }
                output[y * columns + x] = useMaximum ? maximum : sum / count
            }
        }
        return output
    }
}
