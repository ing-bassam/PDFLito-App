import UIKit
import CoreImage

/// Sample documents for the Simulator (no camera) and App Store screenshots.
/// Only active when the app is launched with the `-demo` argument.
enum DemoContent {
    struct SampleDocument {
        let fileName: String
        let sender: String
        let title: String
        let paragraphs: [String]
        let rows: [(String, String)]
    }

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-demo")
    }

    /// Screen to open on launch (`-screen review` or `-screen settings`).
    static var launchScreen: String? {
        isActive ? UserDefaults.standard.string(forKey: "screen") : nil
    }

    static let invoice = SampleDocument(
        fileName: "Rechnung Nr. 2026-1047",
        sender: "Stadtwerke Musterstadt",
        title: "Rechnung Nr. 2026-1047",
        paragraphs: [
            "Sehr geehrter Herr Mustermann,",
            "für den Abrechnungszeitraum 01.09.2026 bis 30.09.2026 berechnen wir Ihnen folgende Leistungen. Bitte überweisen Sie den Betrag innerhalb von 14 Tagen auf das unten genannte Konto.",
        ],
        rows: [("Strom Grundpreis", "12,50 €"), ("Arbeitspreis 214 kWh", "68,48 €"), ("Wasser und Abwasser", "31,20 €"),
               ("Netto", "112,18 €"), ("MwSt. 19 %", "21,31 €"), ("Gesamtbetrag", "133,49 €")])

    static let invoiceTerms = SampleDocument(
        fileName: "Zahlungsbedingungen",
        sender: "Stadtwerke Musterstadt",
        title: "Zahlungsbedingungen",
        paragraphs: [
            "Der Rechnungsbetrag ist ohne Abzug innerhalb von 14 Tagen nach Rechnungsdatum fällig.",
            "Bei Fragen zu Ihrer Rechnung erreichen Sie unseren Kundenservice montags bis freitags von 8 bis 18 Uhr.",
            "Bitte geben Sie bei jeder Zahlung die Rechnungsnummer an, damit wir Ihre Zahlung schnell zuordnen können.",
        ],
        rows: [])

    static let library: [SampleDocument] = [
        invoice,
        SampleDocument(fileName: "Protokoll Baubesprechung KW 43", sender: "Muster Bau GmbH", title: "Protokoll Baubesprechung KW 43",
                       paragraphs: ["Teilnehmer: Bauherr, Architekt, Statik, Haustechnik.", "1. Termine Rohbau bestätigt. 2. Fensterlieferung verschiebt sich um eine Woche."],
                       rows: []),
        SampleDocument(fileName: "Kündigung Mobilfunkvertrag", sender: "Max Mustermann", title: "Kündigung Mobilfunkvertrag",
                       paragraphs: ["Hiermit kündige ich meinen Vertrag fristgerecht zum nächstmöglichen Zeitpunkt.", "Bitte bestätigen Sie mir die Kündigung schriftlich."],
                       rows: []),
        SampleDocument(fileName: "Bauantrag Erweiterung Lagerhalle", sender: "Ingenieurbüro Muster", title: "Bauantrag Erweiterung Lagerhalle",
                       paragraphs: ["Antrag auf Baugenehmigung für die Erweiterung der bestehenden Lagerhalle um 320 m².", "Anlagen: Lageplan, Bauzeichnungen, Baubeschreibung, Standsicherheitsnachweis."],
                       rows: []),
        SampleDocument(fileName: "Mietvertrag Wohnung Gartenstraße 12", sender: "Hausverwaltung Muster", title: "Mietvertrag Wohnung Gartenstraße 12",
                       paragraphs: ["Zwischen der Hausverwaltung Muster und Herrn Max Mustermann wird folgender Mietvertrag geschlossen."],
                       rows: []),
    ]

    static func prepareIfNeeded() {
        guard isActive else { return }
        AppSettings.shared.applyDemoFolder(named: "Scans")
        let fileManager = FileManager.default
        let directory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let existing = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in existing where url.pathExtension.lowercased() == "pdf" {
            try? fileManager.removeItem(at: url)
        }
        for (index, document) in library.enumerated() {
            guard let page = ImageProcessor.encode(render(document), mode: .blackWhite, compression: .maximum) else { continue }
            let data = PDFWriter.makePDF(pages: [PDFPage(image: page, lines: [])], title: document.title)
            let url = directory.appendingPathComponent(document.fileName).appendingPathExtension("pdf")
            try? data.write(to: url)
            let date = Date().addingTimeInterval(-Double(index) * 86_400 * 2.3 - 3_600)
            try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    /// A sharp invoice page and, optionally, a second page that is far too blurry.
    static func samplePages(includeBlurred: Bool = true) -> [UIImage] {
        if includeBlurred {
            return [render(invoice), blurred(render(invoiceTerms), radius: 7)]
        }
        return [render(invoiceTerms)]
    }

    // MARK: - Rendering

    static func render(_ document: SampleDocument, size: CGSize = CGSize(width: 1240, height: 1754)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let accent = UIColor(red: 0.12, green: 0.36, blue: 0.72, alpha: 1)
            accent.setFill()
            context.fill(CGRect(x: 100, y: 100, width: 64, height: 64))
            draw(document.sender, x: 184, y: 100, font: .systemFont(ofSize: 32, weight: .semibold), color: .darkGray)
            draw("Musterweg 5 · 12345 Musterstadt", x: 184, y: 142, font: .systemFont(ofSize: 21), color: .gray)

            var y: CGFloat = 300
            for line in ["Max Mustermann", "Lindenallee 8", "12345 Musterstadt"] {
                draw(line, x: 100, y: y, font: .systemFont(ofSize: 25), color: .black)
                y += 36
            }
            draw("Musterstadt, 28.10.2026", x: 860, y: 300, font: .systemFont(ofSize: 23), color: .black)

            draw(document.title, x: 100, y: 520, font: .systemFont(ofSize: 56, weight: .bold), color: .black)

            y = 640
            let bodyFont = UIFont.systemFont(ofSize: 26)
            for paragraph in document.paragraphs {
                y += drawWrapped(paragraph, x: 100, y: y, width: 1040, font: bodyFont) + 22
            }

            if !document.rows.isEmpty {
                y += 20
                UIColor(white: 0.85, alpha: 1).setFill()
                for (index, row) in document.rows.enumerated() {
                    let isTotal = index == document.rows.count - 1
                    let font = isTotal ? UIFont.systemFont(ofSize: 27, weight: .bold) : bodyFont
                    draw(row.0, x: 100, y: y, font: font, color: .black)
                    let width = (row.1 as NSString).size(withAttributes: [.font: font]).width
                    draw(row.1, x: 1140 - width, y: y, font: font, color: .black)
                    y += 46
                    context.fill(CGRect(x: 100, y: y - 8, width: 1040, height: 2))
                }
            }

            draw("IBAN DE00 1234 5678 9012 3456 78 · Musterbank", x: 100, y: 1640, font: .systemFont(ofSize: 19), color: .gray)
        }
    }

    static func blurred(_ image: UIImage, radius: Double) -> UIImage {
        guard let input = CIImage(image: image), let filter = CIFilter(name: "CIGaussianBlur") else { return image }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let cgImage = CIContext().createCGImage(output, from: input.extent) else { return image }
        return UIImage(cgImage: cgImage)
    }

    private static func draw(_ text: String, x: CGFloat, y: CGFloat, font: UIFont, color: UIColor) {
        (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
    }

    private static func drawWrapped(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, font: UIFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        let bounds = (text as NSString).boundingRect(with: CGSize(width: width, height: 1000),
                                                     options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
        (text as NSString).draw(with: CGRect(x: x, y: y, width: width, height: ceil(bounds.height)),
                                options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
        return ceil(bounds.height)
    }
}
