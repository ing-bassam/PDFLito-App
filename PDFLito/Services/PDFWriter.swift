import Foundation
import CoreGraphics

struct PDFPage {
    let image: EncodedPage
    /// Recognized text, written as an invisible layer so the PDF is searchable.
    let lines: [RecognizedLine]
}

/// Minimal PDF writer. Writing the file by hand keeps full control over the image streams
/// (JPEG passed through untouched, 1-bit pages Flate-compressed) and keeps the files tiny.
/// The text layer uses the built-in Helvetica font, so no font has to be embedded.
enum PDFWriter {
    /// Long side of every page in points (A4 = 842 pt).
    static let longSidePoints: Double = 842

    static func pageSize(for image: EncodedPage) -> CGSize {
        let width = Double(image.pixelWidth), height = Double(image.pixelHeight)
        let factor = longSidePoints / max(width, height, 1)
        return CGSize(width: (width * factor).rounded(), height: (height * factor).rounded())
    }

    static func makePDF(pages: [PDFPage], title: String, date: Date = Date()) -> Data {
        var writer = ByteWriter()
        writer.write("%PDF-1.4\n")
        writer.write(Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]))

        let catalogID = 1, pagesID = 2, fontID = 3, infoID = 4
        let pageIDs = pages.indices.map { 5 + $0 * 3 }
        let objectCount = 4 + pages.count * 3

        writer.beginObject(catalogID)
        writer.write("<< /Type /Catalog /Pages \(pagesID) 0 R >>\n")
        writer.endObject()

        writer.beginObject(pagesID)
        let kids = pageIDs.map { "\($0) 0 R" }.joined(separator: " ")
        writer.write("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>\n")
        writer.endObject()

        writer.beginObject(fontID)
        writer.write("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\n")
        writer.endObject()

        writer.beginObject(infoID)
        var info = "<< /Producer (PDFLito) /Creator (PDFLito) /CreationDate (\(pdfDate(date)))"
        if !title.isEmpty {
            info += " /Title <\(utf16Hex(title))>"
        }
        writer.write(info + " >>\n")
        writer.endObject()

        for (index, page) in pages.enumerated() {
            let pageID = pageIDs[index], contentID = pageID + 1, imageID = pageID + 2
            let size = pageSize(for: page.image)

            let mediaBox = "[0 0 \(number(Double(size.width))) \(number(Double(size.height)))]"
            let resources = "<< /XObject << /Im0 \(imageID) 0 R >> /Font << /F1 \(fontID) 0 R >> >>"
            writer.beginObject(pageID)
            writer.write("<< /Type /Page /Parent \(pagesID) 0 R /MediaBox \(mediaBox) /Resources \(resources) /Contents \(contentID) 0 R >>\n")
            writer.endObject()

            let content = Data(contentStream(for: page, size: size).utf8)
            if let compressed = Zlib.compress(content) {
                writer.stream(id: contentID, dictionary: "/Filter /FlateDecode", bytes: compressed)
            } else {
                writer.stream(id: contentID, dictionary: "", bytes: content)
            }

            let image = page.image
            var dictionary = "/Type /XObject /Subtype /Image /Width \(image.pixelWidth) /Height \(image.pixelHeight)"
                + " /ColorSpace /\(image.colorSpace) /BitsPerComponent \(image.bitsPerComponent)"
            if let filter = image.filter {
                dictionary += " /Filter /\(filter)"
            }
            writer.stream(id: imageID, dictionary: dictionary, bytes: image.data)
        }

        writer.finish(objectCount: objectCount, rootID: catalogID, infoID: infoID)
        return writer.data
    }

    static func contentStream(for page: PDFPage, size: CGSize) -> String {
        let width = Double(size.width), height = Double(size.height)
        var content = "q\n\(number(width)) 0 0 \(number(height)) 0 0 cm\n/Im0 Do\nQ\n"
        var text = ""
        for line in page.lines {
            let bytes = winAnsi(line.text)
            let boxHeight = Double(line.box.height) * height
            guard !bytes.isEmpty, boxHeight >= 1 else { continue }
            let fontSize = boxHeight * 0.85
            let naturalWidth = Double(textWidth(bytes)) * fontSize / 1000
            let targetWidth = Double(line.box.width) * width
            let scale = naturalWidth > 0 ? min(500, max(10, targetWidth / naturalWidth * 100)) : 100
            let x = Double(line.box.minX) * width
            let y = Double(line.box.minY) * height + boxHeight * 0.2
            text += "/F1 \(number(fontSize)) Tf\n\(number(scale)) Tz\n1 0 0 1 \(number(x)) \(number(y)) Tm\n<\(hex(bytes))> Tj\n"
        }
        if !text.isEmpty {
            content += "BT\n3 Tr\n" + text + "ET\n"
        }
        return content
    }

    // MARK: - Encoding helpers

    static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.2f", rounded)
    }

    static func winAnsi(_ text: String) -> [UInt8] {
        let data = text.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data()
        return [UInt8](data)
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789ABCDEF")
        var result = ""
        result.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0F)])
        }
        return result
    }

    static func utf16Hex(_ text: String) -> String {
        let digits = Array("0123456789ABCDEF")
        var result = "FEFF"
        for unit in text.utf16 {
            result.append(digits[Int((unit >> 12) & 0xF)])
            result.append(digits[Int((unit >> 8) & 0xF)])
            result.append(digits[Int((unit >> 4) & 0xF)])
            result.append(digits[Int(unit & 0xF)])
        }
        return result
    }

    static func pdfDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "D:\(formatter.string(from: date))Z"
    }

    /// Helvetica advance widths (1/1000 em) for WinAnsi codes 32…126.
    private static let asciiWidths: [Int] = [
        278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
        556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
        1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
        667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
        333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
        556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
    ]

    static func textWidth(_ bytes: [UInt8]) -> Int {
        bytes.reduce(0) { total, byte in
            let code = Int(byte)
            if code >= 32 && code <= 126 {
                return total + asciiWidths[code - 32]
            }
            switch code {
            case 0xC4, 0xC0, 0xC1, 0xC2: return total + 667 // Ä À Á Â
            case 0xD6, 0xD2, 0xD3, 0xD4: return total + 778 // Ö Ò Ó Ô
            case 0xDC, 0xD9, 0xDA, 0xDB: return total + 722 // Ü Ù Ú Û
            case 0xDF: return total + 611 // ß
            default: return total + 556
            }
        }
    }
}

/// Collects PDF bytes and remembers object offsets for the cross-reference table.
private struct ByteWriter {
    private(set) var data = Data()
    private var offsets: [Int: Int] = [:]

    mutating func write(_ text: String) {
        data.append(contentsOf: Array(text.utf8))
    }

    mutating func write(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func beginObject(_ id: Int) {
        offsets[id] = data.count
        write("\(id) 0 obj\n")
    }

    mutating func endObject() {
        write("endobj\n")
    }

    mutating func stream(id: Int, dictionary: String, bytes: Data) {
        beginObject(id)
        write("<< \(dictionary) /Length \(bytes.count) >>\nstream\n")
        write(bytes)
        write("\nendstream\n")
        endObject()
    }

    mutating func finish(objectCount: Int, rootID: Int, infoID: Int) {
        let xrefOffset = data.count
        write("xref\n0 \(objectCount + 1)\n")
        write("0000000000 65535 f \n")
        for id in 1...objectCount {
            let offset = String(offsets[id] ?? 0)
            write(String(repeating: "0", count: max(0, 10 - offset.count)) + offset + " 00000 n \n")
        }
        write("trailer\n<< /Size \(objectCount + 1) /Root \(rootID) 0 R /Info \(infoID) 0 R >>\n")
        write("startxref\n\(xrefOffset)\n%%EOF\n")
    }
}
