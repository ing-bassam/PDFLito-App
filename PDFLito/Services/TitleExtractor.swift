import Foundation
import CoreGraphics

/// Finds a good file name in the recognized text: the most prominent heading, a subject line
/// ("Betreff: …") or a line naming the document type ("Rechnung", "Kündigung" …).
enum TitleExtractor {
    struct Block {
        var text: String
        var height: CGFloat
        var top: CGFloat
        var bottom: CGFloat
        var minX: CGFloat
        var maxX: CGFloat
        var lineCount: Int
    }

    static let documentKeywords = [
        "rechnung", "angebot", "auftrag", "kündigung", "vertrag", "bescheid", "mahnung", "lieferschein",
        "quittung", "gutschrift", "bestätigung", "kostenvoranschlag", "protokoll", "bericht", "gutachten",
        "antrag", "bescheinigung", "zeugnis", "abrechnung", "kontoauszug", "beleg", "vollmacht",
        "einladung", "bewerbung", "attest", "rezept", "befund", "police", "versicherungsschein",
        "invoice", "receipt", "contract", "offer", "quotation", "order", "statement", "certificate",
    ]

    /// Longest first, so "betr.:" is stripped before "betr.".
    static let subjectPrefixes = ["betreff:", "betr.:", "betr.", "subject:", "re:"]

    static func suggestions(from lines: [RecognizedLine], limit: Int = 4) -> [String] {
        let candidates = lines
            .filter(isCandidate)
            .sorted { $0.box.maxY > $1.box.maxY }
        let ranked = mergeIntoBlocks(candidates)
            .map { (block: $0, score: score($0)) }
            .sorted { $0.score > $1.score }
        var result: [String] = []
        for entry in ranked {
            let name = FileNamer.sanitize(entry.block.text)
            guard name.count >= 3,
                  !result.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            result.append(name)
            if result.count == limit { break }
        }
        return result
    }

    static func isCandidate(_ line: RecognizedLine) -> Bool {
        guard line.confidence >= 0.3 else { return false }
        let text = line.text
        let scalars = text.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        let visible = scalars.filter { !CharacterSet.whitespaces.contains($0) }.count
        guard letters >= 3, Double(letters) / Double(max(visible, 1)) >= 0.45 else { return false }
        let lower = text.lowercased()
        if lower.contains("@") || lower.contains("www.") || lower.contains("http") { return false }
        if lower.hasPrefix("seite ") || lower.hasPrefix("page ") { return false }
        if lower.hasPrefix("tel") || lower.hasPrefix("fax") || lower.hasPrefix("iban") || lower.hasPrefix("bic") { return false }
        return true
    }

    /// Joins consecutive lines of the same size into one block (multi-line headings).
    static func mergeIntoBlocks(_ lines: [RecognizedLine]) -> [Block] {
        var blocks: [Block] = []
        for line in lines {
            let box = line.box
            let height = box.height
            if var last = blocks.last, last.lineCount < 3, height > 0, last.height > 0 {
                let ratio = height / last.height
                let gap = last.bottom - box.maxY
                let similarSize = ratio > 0.8 && ratio < 1.25
                let close = gap > -height * 0.3 && gap < height * 0.9
                let aligned = abs(box.minX - last.minX) < 0.08 || (box.minX < last.maxX && box.maxX > last.minX)
                if similarSize && close && aligned && !isSubjectLine(line.text) {
                    last.text += " " + line.text
                    last.height = (last.height * CGFloat(last.lineCount) + height) / CGFloat(last.lineCount + 1)
                    last.bottom = box.minY
                    last.minX = min(last.minX, box.minX)
                    last.maxX = max(last.maxX, box.maxX)
                    last.lineCount += 1
                    blocks[blocks.count - 1] = last
                    continue
                }
            }
            blocks.append(Block(text: line.text, height: height, top: box.maxY, bottom: box.minY,
                                minX: box.minX, maxX: box.maxX, lineCount: 1))
        }
        return blocks
    }

    static func score(_ block: Block) -> Double {
        var score = Double(block.height)
        let center = Double(block.top + block.bottom) / 2
        score *= 0.8 + 0.4 * center
        let length = block.text.count
        if length < 4 {
            score *= 0.5
        } else if length > 70 {
            score *= 0.6
        }
        if block.lineCount > 1 {
            score *= 0.9
        }
        if containsKeyword(block.text) {
            score *= 1.6
        }
        if isSubjectLine(block.text) {
            score *= 3
        }
        let visible = block.text.filter { !$0.isWhitespace }
        let digits = visible.filter(\.isNumber).count
        if !visible.isEmpty && Double(digits) / Double(visible.count) > 0.3 {
            score *= 0.7
        }
        return score
    }

    static func containsKeyword(_ text: String) -> Bool {
        let lower = text.lowercased()
        return documentKeywords.contains { lower.contains($0) }
    }

    static func isSubjectLine(_ text: String) -> Bool {
        let lower = text.lowercased()
        return subjectPrefixes.contains { lower.hasPrefix($0) }
    }

    // MARK: - Dates

    private static let numericDate = try! NSRegularExpression(pattern: #"\b(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4}|\d{2})\b"#)
    private static let isoDate = try! NSRegularExpression(pattern: #"\b(\d{4})-(\d{2})-(\d{2})\b"#)
    private static let namedDate = try! NSRegularExpression(pattern: #"\b(\d{1,2})\.?\s+([A-Za-zÄÖÜäöü]{3,9})\.?\s+(\d{4})\b"#)

    private static let months: [String: Int] = [
        "januar": 1, "jan": 1, "january": 1, "jänner": 1,
        "februar": 2, "feb": 2, "february": 2,
        "märz": 3, "maerz": 3, "mär": 3, "mrz": 3, "march": 3, "mar": 3,
        "april": 4, "apr": 4,
        "mai": 5, "may": 5,
        "juni": 6, "jun": 6, "june": 6,
        "juli": 7, "jul": 7, "july": 7,
        "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9,
        "oktober": 10, "okt": 10, "october": 10, "oct": 10,
        "november": 11, "nov": 11,
        "dezember": 12, "dez": 12, "december": 12, "dec": 12,
    ]

    /// The first plausible date printed on the document.
    static func documentDate(in lines: [RecognizedLine]) -> Date? {
        let text = lines.map(\.text).joined(separator: "\n")
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        var found: [(location: Int, date: Date)] = []

        for match in numericDate.matches(in: text, range: range) {
            var year = Int(nsText.substring(with: match.range(at: 3))) ?? 0
            if year < 100 { year += 2000 }
            if let date = makeDate(day: Int(nsText.substring(with: match.range(at: 1))) ?? 0,
                                   month: Int(nsText.substring(with: match.range(at: 2))) ?? 0, year: year) {
                found.append((match.range.location, date))
            }
        }
        for match in isoDate.matches(in: text, range: range) {
            if let date = makeDate(day: Int(nsText.substring(with: match.range(at: 3))) ?? 0,
                                   month: Int(nsText.substring(with: match.range(at: 2))) ?? 0,
                                   year: Int(nsText.substring(with: match.range(at: 1))) ?? 0) {
                found.append((match.range.location, date))
            }
        }
        for match in namedDate.matches(in: text, range: range) {
            let monthName = nsText.substring(with: match.range(at: 2)).lowercased()
            guard let month = months[monthName] else { continue }
            if let date = makeDate(day: Int(nsText.substring(with: match.range(at: 1))) ?? 0, month: month,
                                   year: Int(nsText.substring(with: match.range(at: 3))) ?? 0) {
                found.append((match.range.location, date))
            }
        }
        return found.min { $0.location < $1.location }?.date
    }

    static func makeDate(day: Int, month: Int, year: Int) -> Date? {
        guard (1...31).contains(day), (1...12).contains(month), (1990...2100).contains(year) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day,
              calendar.component(.month, from: date) == month else { return nil }
        return date
    }
}

enum FileNamer {
    static let maxLength = 80

    /// Turns any text into a safe, tidy file name (without extension).
    static func sanitize(_ raw: String) -> String {
        var text = raw
        var changed = true
        while changed {
            changed = false
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()
            for prefix in TitleExtractor.subjectPrefixes + ["aw:", "wg:", "fw:", "fwd:"] where lower.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                changed = true
                break
            }
        }
        if text.lowercased().hasSuffix(".pdf") {
            text = String(text.dropLast(4))
        }
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        text = String(String.UnicodeScalarView(text.unicodeScalars.map { forbidden.contains($0) ? " " : $0 }))
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .-_,;"))
        if text.count > maxLength {
            let cut = String(text.prefix(maxLength))
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > maxLength / 2 {
                text = String(cut[..<space])
            } else {
                text = cut
            }
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .-_,;"))
        }
        return text
    }

    static func fileName(title: String, date: Date?) -> String {
        var base = sanitize(title)
        if base.isEmpty {
            base = "Scan"
        }
        if let date {
            base = "\(day(date)) \(base)"
        }
        return base
    }

    static func fallbackTitle(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return "Scan \(formatter.string(from: date))"
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// "Name.pdf", or "Name (2).pdf" … when the name is already taken in `directory`.
    static func uniqueURL(in directory: URL, baseName: String, pathExtension: String = "pdf") -> URL {
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(pathExtension)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) (\(counter))").appendingPathExtension(pathExtension)
            counter += 1
        }
        return candidate
    }
}
