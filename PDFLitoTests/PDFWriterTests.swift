import XCTest
import PDFKit
import Compression
@testable import PDFLito

final class PDFWriterTests: XCTestCase {
    private let page = DemoContent.render(DemoContent.invoice)

    func testEveryModeProducesReadableSmallPDF() throws {
        let line = RecognizedLine(text: "Rechnung Nr. 2026-1047 – Müller & Söhne",
                                  box: CGRect(x: 0.08, y: 0.62, width: 0.7, height: 0.035), confidence: 1)
        for mode in ColorMode.allCases {
            for compression in CompressionLevel.allCases {
                let encoded = try XCTUnwrap(ImageProcessor.encode(page, mode: mode, compression: compression))
                let data = PDFWriter.makePDF(pages: [PDFPage(image: encoded, lines: [line])], title: "Rechnung Nr. 2026-1047")
                print("PDFSIZE mode=\(mode.rawValue) compression=\(compression.rawValue) bytes=\(data.count) px=\(encoded.pixelWidth)x\(encoded.pixelHeight)")

                let document = try XCTUnwrap(PDFDocument(data: data), "\(mode) \(compression)")
                XCTAssertEqual(document.pageCount, 1)
                let text = document.page(at: 0)?.string ?? ""
                XCTAssertTrue(text.contains("Rechnung"), "Text layer missing for \(mode) \(compression): \(text)")
                XCTAssertTrue(text.contains("Müller"), "Umlauts lost for \(mode) \(compression): \(text)")
                let dark = darkFraction(of: document)
                print("PDFINK mode=\(mode.rawValue) compression=\(compression.rawValue) dark=\(dark)")
                XCTAssertGreaterThan(dark, 0.003, "Page image not rendered for \(mode) \(compression)")
                XCTAssertLessThan(data.count, 350_000, "\(mode) \(compression) too large")
            }
        }
    }

    func testBlackWhiteMaximumIsTiny() throws {
        let encoded = try XCTUnwrap(ImageProcessor.encode(page, mode: .blackWhite, compression: .maximum))
        let data = PDFWriter.makePDF(pages: [PDFPage(image: encoded, lines: [])], title: "")
        XCTAssertLessThan(data.count, 120_000)
    }

    func testMultiplePagesAndMetadata() throws {
        let encoded = try XCTUnwrap(ImageProcessor.encode(page, mode: .grayscale, compression: .balanced))
        let data = PDFWriter.makePDF(pages: [PDFPage(image: encoded, lines: []), PDFPage(image: encoded, lines: [])],
                                     title: "Kündigung Vertrag")
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Kündigung Vertrag")
        let bounds = try XCTUnwrap(document.page(at: 0)?.bounds(for: .mediaBox))
        XCTAssertEqual(max(bounds.width, bounds.height), 842, accuracy: 1)
    }

    func testZlibStreamRoundTrips() throws {
        var bytes = [UInt8](repeating: 0, count: 50_000)
        for i in bytes.indices { bytes[i] = UInt8((i * 7 + i / 300) & 0xFF) }
        let input = Data(bytes)
        let compressed = try XCTUnwrap(Zlib.compress(input))
        XCTAssertEqual(compressed.prefix(2), Data([0x78, 0x9C]))

        let raw = compressed.dropFirst(2).dropLast(4)
        var output = Data(count: input.count)
        let decoded = output.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Int in
            Data(raw).withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          source.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        XCTAssertEqual(decoded, input.count)
        XCTAssertEqual(output, input)

        let checksum = Zlib.adler32(input)
        XCTAssertEqual(Data(compressed.suffix(4)), Data([UInt8(checksum >> 24 & 0xFF), UInt8(checksum >> 16 & 0xFF),
                                                         UInt8(checksum >> 8 & 0xFF), UInt8(checksum & 0xFF)]))
        XCTAssertEqual(Zlib.adler32(Data("Wikipedia".utf8)), 0x11E60398)
    }

    func testWhiteningRemovesShadows() throws {
        // Paper with a strong shadow from left to right and black text bars.
        let width = 600, height = 400
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let paper = 120 + 120 * x / width
                let isText = (y / 20) % 3 == 1 && (x / 12) % 4 != 3 && x > 40 && x < 560
                pixels[y * width + x] = UInt8(isText ? paper / 5 : paper)
            }
        }
        let cleaned = ImageProcessor.whitened(GrayImage(width: width, height: height, pixels: pixels))
        XCTAssertGreaterThan(cleaned.pixels[5 * width + 20], 245, "dark paper should turn white")
        XCTAssertGreaterThan(cleaned.pixels[5 * width + 580], 245, "bright paper should stay white")
        XCTAssertLessThan(cleaned.pixels[25 * width + 60], 60, "text in the shadow should stay dark")
        XCTAssertLessThan(cleaned.pixels[25 * width + 500], 60, "text in the light should stay dark")
    }

    private func darkFraction(of document: PDFDocument) -> Double {
        guard let page = document.page(at: 0) else { return 0 }
        let image = page.thumbnail(of: CGSize(width: 600, height: 848), for: .mediaBox)
        guard let cgImage = image.cgImage, let gray = ImageProcessor.grayscale(cgImage, maxLongSide: 848) else { return 0 }
        let dark = gray.pixels.filter { $0 < 100 }.count
        return Double(dark) / Double(gray.pixels.count)
    }
}
