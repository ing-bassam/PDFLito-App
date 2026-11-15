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

    /// Output resolution and JPEG quality. An A4 page with 2340 px on the long side is 200 dpi.
    /// Black-and-white pages have no shades of grey to smooth small print, so they need the
    /// most pixels: below about 200 dpi small type breaks up and becomes hard to read.
    static func profile(for mode: ColorMode, compression: CompressionLevel) -> OutputProfile {
        switch (mode, compression) {
        case (.blackWhite, .maximum): return OutputProfile(maxLongSide: 2500, jpegQuality: 0)
        case (.blackWhite, .balanced): return OutputProfile(maxLongSide: 2900, jpegQuality: 0)
        case (.blackWhite, .high): return OutputProfile(maxLongSide: 3400, jpegQuality: 0)
        case (.grayscale, .maximum): return OutputProfile(maxLongSide: 1750, jpegQuality: 0.4)
        case (.grayscale, .balanced): return OutputProfile(maxLongSide: 2100, jpegQuality: 0.5)
        case (.grayscale, .high): return OutputProfile(maxLongSide: 2700, jpegQuality: 0.7)
        case (.color, .maximum): return OutputProfile(maxLongSide: 1650, jpegQuality: 0.4)
        case (.color, .balanced): return OutputProfile(maxLongSide: 2000, jpegQuality: 0.5)
        case (.color, .high): return OutputProfile(maxLongSide: 2600, jpegQuality: 0.7)
        }
    }

    // MARK: - Page encoding

    static func encode(_ image: UIImage, mode: ColorMode, compression: CompressionLevel) -> EncodedPage? {
        guard let cgImage = image.cgImage else { return nil }
        let profile = profile(for: mode, compression: compression)
        guard let source = rgb(cgImage, maxLongSide: profile.maxLongSide) else { return nil }
        let paper = PaperMap(source)
        switch mode {
        case .blackWhite:
            // A book cover or photo has no paper to turn white and no ink to turn black –
            // pure black and white would tear it into blotches. Such pages keep their shades of grey.
            guard paper.isDocument else {
                return grayPicture(cgImage, compression: compression)
            }
            let gray = luminance(whitened(source, paper: paper))
            let bits = bilevelBits(gray)
            if let compressed = Zlib.compress(bits) {
                return EncodedPage(data: compressed, pixelWidth: gray.width, pixelHeight: gray.height,
                                   colorSpace: "DeviceGray", bitsPerComponent: 1, filter: "FlateDecode")
            }
            return EncodedPage(data: bits, pixelWidth: gray.width, pixelHeight: gray.height,
                               colorSpace: "DeviceGray", bitsPerComponent: 1, filter: nil)
        case .grayscale:
            let quality = paper.isDocument ? profile.jpegQuality : pictureQuality(profile.jpegQuality)
            guard let flattened = makeCGImage(luminance(whitened(source, paper: paper))),
                  let jpeg = jpegData(flattened, quality: quality) else { return nil }
            return EncodedPage(data: jpeg, pixelWidth: source.width, pixelHeight: source.height,
                               colorSpace: "DeviceGray", bitsPerComponent: 8, filter: "DCTDecode")
        case .color:
            let quality = paper.isDocument ? profile.jpegQuality : pictureQuality(profile.jpegQuality)
            guard let flattened = makeCGImage(whitened(source, paper: paper)),
                  let jpeg = jpegData(flattened, quality: quality) else { return nil }
            return EncodedPage(data: jpeg, pixelWidth: source.width, pixelHeight: source.height,
                               colorSpace: "DeviceRGB", bitsPerComponent: 8, filter: "DCTDecode")
        }
    }

    /// Pictures show JPEG artefacts sooner than text on white paper.
    static func pictureQuality(_ quality: CGFloat) -> CGFloat {
        min(0.85, quality + 0.2)
    }

    /// A picture page in a black-and-white document: greyscale at the grey resolution.
    private static func grayPicture(_ image: CGImage, compression: CompressionLevel) -> EncodedPage? {
        let profile = profile(for: .grayscale, compression: compression)
        guard let gray = grayscale(image, maxLongSide: profile.maxLongSide),
              let flattened = makeCGImage(gray),
              let jpeg = jpegData(flattened, quality: pictureQuality(profile.jpegQuality)) else { return nil }
        return EncodedPage(data: jpeg, pixelWidth: gray.width, pixelHeight: gray.height,
                           colorSpace: "DeviceGray", bitsPerComponent: 8, filter: "DCTDecode")
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

    /// Cleans up the paper of a colour page. Only what really is paper – bright and without a
    /// colour of its own – is turned white. Coloured areas, photos and whole picture pages
    /// (a book cover, say) stay exactly as they were photographed; brightening them as if they
    /// were paper leaves pale blotches.
    static func whitened(_ image: RGBImage, paper: PaperMap) -> RGBImage {
        guard paper.isDocument else { return image }
        let background = paper.background
        let lookup = background.columnLookup(width: image.width)
        let width = image.width
        var output = [UInt8](repeating: 255, count: image.pixels.count)
        var row = [Float](repeating: 255, count: width)
        var share = [Float](repeating: 1, count: width)
        let light = paper.light
        image.pixels.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                for y in 0..<image.height {
                    background.fill(row: y, lookup: lookup, from: paper.paperLevels, into: &row)
                    background.fill(row: y, lookup: lookup, from: paper.paperness, into: &share)
                    for x in 0..<width {
                        let i = (y * width + x) * 4
                        let level = row[x], isPaper = share[x]
                        for channel in 0..<3 {
                            // Dividing by the brightness and colour of the light takes out shadows
                            // and makes tinted paper white again – everywhere on the page.
                            let relative = Float(source[i + channel]) / (level * light[channel])
                            // Paper additionally gets its last grey pushed to white and ink to
                            // black; coloured areas keep their own shades.
                            let cleaned = Float(levels(relative))
                            let plain = min(255, relative * 255)
                            target[i + channel] = UInt8(max(0, min(255, cleaned * isPaper + plain * (1 - isPaper))))
                        }
                        target[i + 3] = 255
                    }
                }
            }
        }
        return RGBImage(width: image.width, height: image.height, pixels: output)
    }

    static func whitened(_ image: RGBImage) -> RGBImage {
        whitened(image, paper: PaperMap(image))
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
        fill(row: y, lookup: lookup, from: grid, into: &row)
    }

    /// The same interpolation for any other value stored per block.
    func fill(row y: Int, lookup: ColumnLookup, from grid: [Float], into row: inout [Float]) {
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

    static func neighbourhood(_ values: [Float], columns: Int, rows: Int, useMaximum: Bool) -> [Float] {
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

/// Tells paper from picture. Paper is bright and has no colour of its own; a red book cover,
/// a photo or a coloured box is not paper and must not be "cleaned" like paper.
struct PaperMap {
    let background: BackgroundMap
    /// Per block of the background grid: 1 = paper, 0 = coloured or dark area (smoothed at the borders).
    let paperness: [Float]
    /// Brightness of the paper at every block. Under coloured or dark areas it is carried
    /// over from the paper around them, so they are lit like their surroundings.
    let paperLevels: [Float]
    /// Share of the page that is paper.
    let paperShare: Double
    /// Colour of the light on the paper per channel (red, green, blue), scaled so that a
    /// brightness of 1 stays 1. White light is (1, 1, 1).
    let light: [Float]

    /// Below this share the page is treated as a picture and left untouched.
    static let documentShare = 0.5

    var isDocument: Bool { paperShare >= PaperMap.documentShare }

    init(_ image: RGBImage) {
        let background = BackgroundMap(ImageProcessor.luminance(image))
        let block = background.block, columns = background.columns, rows = background.rows
        let width = image.width, height = image.height
        // Brightness of clean paper on this page: blocks darker than a good half of it are not paper.
        let sorted = background.grid.sorted()
        let paperLevel = sorted.isEmpty ? 255 : sorted[min(sorted.count - 1, Int(Float(sorted.count) * 0.9))]
        // The brightest pixel of every block is its background.
        var reds = [Float](repeating: 0, count: columns * rows)
        var greens = [Float](repeating: 0, count: columns * rows)
        var blues = [Float](repeating: 0, count: columns * rows)
        var bright = [Bool](repeating: false, count: columns * rows)
        image.pixels.withUnsafeBufferPointer { pixels in
            for by in 0..<rows {
                let y0 = by * block, y1 = min(height, y0 + block)
                for bx in 0..<columns {
                    let x0 = bx * block, x1 = min(width, x0 + block)
                    var best = -1, red = 0, green = 0, blue = 0
                    var y = y0
                    while y < y1 {
                        var x = x0
                        while x < x1 {
                            let i = (y * width + x) * 4
                            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                            let brightness = 77 * r + 150 * g + 29 * b
                            if brightness > best {
                                best = brightness
                                red = r
                                green = g
                                blue = b
                            }
                            x += 2
                        }
                        y += 2
                    }
                    let index = by * columns + bx
                    reds[index] = Float(red)
                    greens[index] = Float(green)
                    blues[index] = Float(blue)
                    bright[index] = Float(best >> 8) >= paperLevel * 0.55
                }
            }
        }

        // Lamp light tints white paper, sometimes strongly. The typical colour of the bright
        // areas shows that tint – unless it is so strong that it must be the colour of the
        // page itself (a red cover), in which case nothing is excused.
        func median(_ values: [Float]) -> Float {
            let chosen = values.indices.filter { bright[$0] }.map { values[$0] }.sorted()
            return chosen.isEmpty ? 255 : chosen[chosen.count / 2]
        }
        var tint: (red: Float, green: Float, blue: Float) = (median(reds), median(greens), median(blues))
        let strongestTint = max(tint.red, tint.green, tint.blue, 1)
        let weakestTint = min(tint.red, tint.green, tint.blue)
        if (strongestTint - weakestTint) > strongestTint * 0.42 {
            tint = (1, 1, 1)
        } else {
            tint = (max(tint.red, 1) / strongestTint, max(tint.green, 1) / strongestTint, max(tint.blue, 1) / strongestTint)
        }

        var flags = [Float](repeating: 0, count: columns * rows)
        var paperBlocks = 0
        for index in flags.indices where bright[index] {
            let red = reds[index] / tint.red, green = greens[index] / tint.green, blue = blues[index] / tint.blue
            let strongest = max(red, green, blue), weakest = min(red, green, blue)
            if strongest - weakest <= strongest * 0.2 + 6 {
                flags[index] = 1
                paperBlocks += 1
            }
        }
        self.paperLevels = PaperMap.levels(from: background.grid, isPaper: flags, columns: columns, rows: rows)
        let lightBrightness = (77 * tint.red + 150 * tint.green + 29 * tint.blue) / 256
        self.light = [tint.red / lightBrightness, tint.green / lightBrightness, tint.blue / lightBrightness]
        self.background = background
        self.paperShare = columns * rows > 0 ? Double(paperBlocks) / Double(columns * rows) : 1
        // Coloured areas reach one block further than measured, so their rim is treated like
        // their middle and they keep one even colour.
        var shrunk = flags
        for row in 0..<rows {
            for column in 0..<columns where flags[row * columns + column] > 0 {
                for dy in -1...1 {
                    for dx in -1...1 {
                        let c = column + dx, r = row + dy
                        if c >= 0, r >= 0, c < columns, r < rows, flags[r * columns + c] == 0 {
                            shrunk[row * columns + column] = 0
                        }
                    }
                }
            }
        }
        self.paperness = BackgroundMap.neighbourhood(shrunk, columns: columns, rows: rows, useMaximum: false)
    }

    /// Paper brightness per block, with the blocks that are not paper filled in from their neighbours.
    private static func levels(from grid: [Float], isPaper: [Float], columns: Int, rows: Int) -> [Float] {
        var values = grid
        var known = isPaper.map { $0 > 0 }
        guard known.contains(true) else { return grid }
        while known.contains(false) {
            var nextValues = values, nextKnown = known
            for row in 0..<rows {
                for column in 0..<columns where !known[row * columns + column] {
                    var sum: Float = 0, count: Float = 0
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
        return BackgroundMap.neighbourhood(values, columns: columns, rows: rows, useMaximum: false)
    }
}
