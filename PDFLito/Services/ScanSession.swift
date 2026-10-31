import SwiftUI

/// One scan in progress: pages, quality results, the suggested name and the finished PDF.
@MainActor
final class ScanSession: ObservableObject, Identifiable {
    let id = UUID()
    let settings: AppSettings

    @Published private(set) var pages: [ScanPage] = []
    @Published private(set) var fileName = ""
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var pendingPages = 0
    @Published private(set) var estimatedBytes: Int?
    @Published var colorMode: ColorMode {
        didSet {
            if oldValue != colorMode { scheduleEstimate() }
        }
    }

    private var nameEditedByUser = false
    private var documentDate: Date?
    private var estimateTask: Task<Void, Never>?
    private var cachedPDF: (key: String, data: Data)?

    init(images: [UIImage], settings: AppSettings) {
        self.settings = settings
        self.colorMode = settings.colorMode
        add(images)
    }

    var isAnalyzing: Bool { pendingPages > 0 }
    var includedPages: [ScanPage] { pages.filter(\.isIncluded) }
    var rejectedCount: Int { pages.filter(\.isRejected).count }
    var canSave: Bool { !isAnalyzing && !includedPages.isEmpty }

    var finalName: String {
        let clean = FileNamer.sanitize(fileName)
        return clean.isEmpty ? FileNamer.fallbackTitle() : clean
    }

    // MARK: - Pages

    func add(_ images: [UIImage], replacing pageID: ScanPage.ID? = nil) {
        guard !images.isEmpty else { return }
        var start: Int?
        if let pageID, let index = pages.firstIndex(where: { $0.id == pageID }) {
            pages.remove(at: index)
            start = index
        }
        pendingPages += images.count
        let strictness = settings.strictness
        let firstIndex = start
        Task {
            var insertAt = firstIndex
            for image in images {
                let page = await Task.detached(priority: .userInitiated) {
                    ScanSession.process(image, strictness: strictness)
                }.value
                if let index = insertAt {
                    pages.insert(page, at: min(index, pages.count))
                    insertAt = index + 1
                } else {
                    pages.append(page)
                }
                pendingPages -= 1
                refreshName()
            }
            scheduleEstimate()
        }
    }

    func remove(_ pageID: ScanPage.ID) {
        pages.removeAll { $0.id == pageID }
        refreshName()
        scheduleEstimate()
    }

    func keepAnyway(_ pageID: ScanPage.ID) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[index].keepAnyway = true
        refreshName()
        scheduleEstimate()
    }

    /// Runs off the main thread: straightens the image, checks sharpness and reads the text.
    nonisolated static func process(_ image: UIImage, strictness: Strictness) -> ScanPage {
        let upright = ImageProcessor.normalizedImage(image, maxLongSide: 2600)
        let data = upright.jpegData(compressionQuality: 0.85) ?? Data()
        let thumbnail = ImageProcessor.normalizedImage(upright, maxLongSide: 360)
        let fallback = PageAnalysis(lines: [], sharpness: nil, brightness: 1, characterCount: 0,
                                    meanConfidence: 0, verdict: .littleText)
        let analysis = upright.cgImage.map { QualityChecker.analyze($0, strictness: strictness) } ?? fallback
        return ScanPage(imageData: data, thumbnail: thumbnail, analysis: analysis)
    }

    // MARK: - Name

    func setFileNameByUser(_ name: String) {
        fileName = name
        nameEditedByUser = true
    }

    func applySuggestion(_ suggestion: String) {
        fileName = FileNamer.fileName(title: suggestion, date: datePrefix)
        nameEditedByUser = true
    }

    private var datePrefix: Date? {
        settings.includeDate ? (documentDate ?? Date()) : nil
    }

    private func refreshName() {
        let source = pages.first(where: \.isIncluded) ?? pages.first
        suggestions = TitleExtractor.suggestions(from: source?.analysis?.lines ?? [])
        documentDate = pages.lazy
            .compactMap { page in page.analysis.flatMap { TitleExtractor.documentDate(in: $0.lines) } }
            .first
        guard !nameEditedByUser else { return }
        if let best = suggestions.first {
            fileName = FileNamer.fileName(title: best, date: datePrefix)
        } else {
            fileName = FileNamer.fallbackTitle()
        }
    }

    // MARK: - PDF

    private var cacheKey: String {
        let ids = includedPages.map(\.id.uuidString).joined(separator: ",")
        return "\(colorMode.rawValue)|\(settings.compression.rawValue)|\(settings.searchableText)|\(ids)"
    }

    private func scheduleEstimate() {
        estimateTask?.cancel()
        estimatedBytes = nil
        guard canSave else { return }
        estimateTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let data = await pdfData()
            guard !Task.isCancelled else { return }
            estimatedBytes = data?.count
        }
    }

    func pdfData() async -> Data? {
        let key = cacheKey
        if let cachedPDF, cachedPDF.key == key {
            return cachedPDF.data
        }
        let pages = includedPages
        guard !pages.isEmpty else { return nil }
        let mode = colorMode
        let compression = settings.compression
        let includeText = settings.searchableText
        let title = suggestions.first ?? ""
        let data = await Task.detached(priority: .userInitiated) {
            ScanSession.makePDF(pages: pages, mode: mode, compression: compression, includeText: includeText, title: title)
        }.value
        if let data {
            cachedPDF = (key, data)
        }
        return data
    }

    nonisolated static func makePDF(pages: [ScanPage], mode: ColorMode, compression: CompressionLevel,
                                    includeText: Bool, title: String) -> Data? {
        var pdfPages: [PDFPage] = []
        for page in pages {
            autoreleasepool {
                guard let image = UIImage(data: page.imageData),
                      let encoded = ImageProcessor.encode(image, mode: mode, compression: compression) else { return }
                pdfPages.append(PDFPage(image: encoded, lines: includeText ? (page.analysis?.lines ?? []) : []))
            }
        }
        return pdfPages.isEmpty ? nil : PDFWriter.makePDF(pages: pdfPages, title: title)
    }

    // MARK: - Saving

    /// Saves to the location chosen in the settings and returns a short confirmation.
    func saveToDefaultLocation(library: DocumentLibrary) async throws -> String {
        guard let data = await pdfData() else { throw ScanError.nothingToSave }
        let name = finalName
        switch settings.destination {
        case .app:
            try library.save(data, named: name)
            return "„\(name)“ gespeichert"
        case .folder:
            guard let bookmark = settings.folderBookmark else { throw ScanError.noFolder }
            let result = try await Task.detached(priority: .userInitiated) {
                try FolderSaver.save(data, baseName: name, bookmark: bookmark)
            }.value
            if let refreshed = result.refreshedBookmark {
                settings.updateBookmark(refreshed)
            }
            if settings.keepCopyInApp {
                try library.save(data, named: name)
            }
            let folder = settings.folderName ?? "Ordner"
            return "In „\(folder)“ gespeichert"
        }
    }

    /// The PDF under its final name in a temporary folder, for "Woanders sichern" and "Teilen".
    func temporaryFile() async throws -> URL {
        guard let data = await pdfData() else { throw ScanError.nothingToSave }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(finalName).appendingPathExtension("pdf")
        try data.write(to: url)
        return url
    }

    /// After exporting or sharing, keeps a copy in PDFLito when the settings ask for it.
    func keepCopyIfNeeded(library: DocumentLibrary) {
        guard settings.storesInApp, let cachedPDF else { return }
        _ = try? library.save(cachedPDF.data, named: finalName)
    }
}
