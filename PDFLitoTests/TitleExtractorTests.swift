import XCTest
@testable import PDFLito

final class TitleExtractorTests: XCTestCase {
    private func line(_ text: String, y: CGFloat, height: CGFloat, x: CGFloat = 0.1, width: CGFloat = 0.5,
                      confidence: Float = 1) -> RecognizedLine {
        RecognizedLine(text: text, box: CGRect(x: x, y: y, width: width, height: height), confidence: confidence)
    }

    func testPicksLargestHeading() {
        let lines = [
            line("Stadtwerke Musterstadt GmbH", y: 0.93, height: 0.015),
            line("Rechnung Nr. 2026-1047", y: 0.75, height: 0.035),
            line("Sehr geehrte Damen und Herren,", y: 0.60, height: 0.014),
            line("vielen Dank für Ihren Auftrag.", y: 0.58, height: 0.014),
        ]
        XCTAssertEqual(TitleExtractor.suggestions(from: lines).first, "Rechnung Nr. 2026-1047")
    }

    func testSubjectLineBeatsLetterhead() {
        let lines = [
            line("MUSTERMANN BAU", y: 0.90, height: 0.03),
            line("Musterweg 5, 12345 Musterstadt", y: 0.86, height: 0.012),
            line("Betreff: Mängelanzeige Dachsanierung", y: 0.60, height: 0.014),
            line("Sehr geehrte Damen und Herren,", y: 0.55, height: 0.014),
        ]
        XCTAssertEqual(TitleExtractor.suggestions(from: lines).first, "Mängelanzeige Dachsanierung")
    }

    func testMergesMultiLineHeading() {
        let lines = [
            line("Protokoll der", y: 0.80, height: 0.03),
            line("Baubesprechung", y: 0.76, height: 0.03),
            line("Anwesend: Herr Muster, Frau Beispiel", y: 0.65, height: 0.013),
        ]
        XCTAssertEqual(TitleExtractor.suggestions(from: lines).first, "Protokoll der Baubesprechung")
    }

    func testIgnoresContactDetailsAndPageNumbers() {
        let lines = [
            line("info@musterfirma.de", y: 0.95, height: 0.04),
            line("www.musterfirma.de", y: 0.90, height: 0.04),
            line("Seite 1 von 2", y: 0.05, height: 0.04),
            line("Lieferschein", y: 0.70, height: 0.025),
        ]
        XCTAssertEqual(TitleExtractor.suggestions(from: lines).first, "Lieferschein")
    }

    func testOffersSeveralDistinctSuggestions() {
        let lines = [
            line("Angebot", y: 0.80, height: 0.04),
            line("Dachsanierung Halle 3", y: 0.70, height: 0.02, x: 0.5),
            line("angebot", y: 0.30, height: 0.02, x: 0.6),
        ]
        let suggestions = TitleExtractor.suggestions(from: lines)
        XCTAssertEqual(suggestions.first, "Angebot")
        XCTAssertEqual(suggestions.filter { $0.lowercased() == "angebot" }.count, 1)
        XCTAssertTrue(suggestions.contains("Dachsanierung Halle 3"))
    }

    func testFindsNumericAndWrittenDates() throws {
        let day: (Date) -> String = { FileNamer.day($0) }

        let numeric = try XCTUnwrap(TitleExtractor.documentDate(in: [line("Musterstadt, den 31.10.2026", y: 0.8, height: 0.01)]))
        XCTAssertEqual(day(numeric), "2026-10-31")

        let written = try XCTUnwrap(TitleExtractor.documentDate(in: [line("Berlin, 5. März 2025", y: 0.8, height: 0.01)]))
        XCTAssertEqual(day(written), "2025-03-05")

        let short = try XCTUnwrap(TitleExtractor.documentDate(in: [line("Datum: 01.02.25", y: 0.8, height: 0.01)]))
        XCTAssertEqual(day(short), "2025-02-01")

        XCTAssertNil(TitleExtractor.documentDate(in: [line("Tel. 12.34.56", y: 0.8, height: 0.01)]))
        XCTAssertNil(TitleExtractor.documentDate(in: [line("31.02.2026", y: 0.8, height: 0.01)]))
    }

    func testSanitizesFileNames() {
        XCTAssertEqual(FileNamer.sanitize("Rechnung: 12/2026?"), "Rechnung 12 2026")
        XCTAssertEqual(FileNamer.sanitize("AW: Betreff: Angebot"), "Angebot")
        XCTAssertEqual(FileNamer.sanitize("  Vertrag.pdf "), "Vertrag")
        XCTAssertEqual(FileNamer.sanitize("Bericht\n2026"), "Bericht 2026")
        let long = String(repeating: "Wort ", count: 40)
        XCTAssertLessThanOrEqual(FileNamer.sanitize(long).count, FileNamer.maxLength)
        XCTAssertFalse(FileNamer.sanitize(long).hasSuffix(" "))
    }

    func testFileNameWithDatePrefix() throws {
        let date = try XCTUnwrap(TitleExtractor.makeDate(day: 31, month: 10, year: 2026))
        XCTAssertEqual(FileNamer.fileName(title: "Rechnung", date: date), "2026-10-31 Rechnung")
        XCTAssertEqual(FileNamer.fileName(title: "Rechnung", date: nil), "Rechnung")
        XCTAssertEqual(FileNamer.fileName(title: "///", date: nil), "Scan")
    }

    func testUniqueURLAddsCounter() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("Rechnung.pdf"))
        XCTAssertEqual(FileNamer.uniqueURL(in: folder, baseName: "Rechnung").lastPathComponent, "Rechnung (2).pdf")
        XCTAssertEqual(FileNamer.uniqueURL(in: folder, baseName: "Angebot").lastPathComponent, "Angebot.pdf")
    }
}
