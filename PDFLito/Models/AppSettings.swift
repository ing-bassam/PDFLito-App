import Foundation

enum ColorMode: String, CaseIterable, Identifiable {
    case blackWhite
    case grayscale
    case color

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blackWhite: return "Schwarzweiß"
        case .grayscale: return "Graustufen"
        case .color: return "Farbe"
        }
    }

    var hint: String {
        switch self {
        case .blackWhite: return "Kleinste Datei – ideal für Textdokumente."
        case .grayscale: return "Klein – gut bei Stempeln, Fotos oder Bleistift."
        case .color: return "Für farbige Dokumente – etwas größer."
        }
    }
}

enum CompressionLevel: String, CaseIterable, Identifiable {
    case maximum
    case balanced
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .maximum: return "Maximal (kleinste Datei)"
        case .balanced: return "Ausgewogen"
        case .high: return "Hohe Qualität"
        }
    }
}

enum SaveDestination: String, CaseIterable, Identifiable {
    /// PDFLito's own storage on the iPhone.
    case app
    /// A fixed folder picked once in the Files picker (iCloud Drive, OneDrive, Dropbox …).
    case folder
    /// The system's "save to" dialog on every save. This is the way into Google Drive, which does
    /// not let other apps remember one of its folders.
    case ask

    var id: String { rawValue }
}

enum ScannerMode: String, CaseIterable, Identifiable {
    case smart
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart: return "PDFLito-Kamera"
        case .apple: return "Apple-Scanner"
        }
    }
}

enum Strictness: String, CaseIterable, Identifiable {
    case strict
    case normal
    case relaxed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strict: return "Streng"
        case .normal: return "Normal"
        case .relaxed: return "Locker"
        }
    }
}

/// User preferences, persisted in UserDefaults. Nothing ever leaves the device.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let colorMode = "colorMode"
        static let compression = "compression"
        static let destination = "destination"
        static let keepCopyInApp = "keepCopyInApp"
        static let includeDate = "includeDate"
        static let searchableText = "searchableText"
        static let strictness = "strictness"
        static let folderBookmark = "folderBookmark"
        static let folderName = "folderName"
        static let scannerMode = "scannerMode"
        static let autoCapture = "autoCapture"
    }

    private let defaults: UserDefaults

    @Published var colorMode: ColorMode {
        didSet { defaults.set(colorMode.rawValue, forKey: Key.colorMode) }
    }
    @Published var compression: CompressionLevel {
        didSet { defaults.set(compression.rawValue, forKey: Key.compression) }
    }
    @Published var destination: SaveDestination {
        didSet { defaults.set(destination.rawValue, forKey: Key.destination) }
    }
    @Published var keepCopyInApp: Bool {
        didSet { defaults.set(keepCopyInApp, forKey: Key.keepCopyInApp) }
    }
    @Published var includeDate: Bool {
        didSet { defaults.set(includeDate, forKey: Key.includeDate) }
    }
    @Published var searchableText: Bool {
        didSet { defaults.set(searchableText, forKey: Key.searchableText) }
    }
    @Published var strictness: Strictness {
        didSet { defaults.set(strictness.rawValue, forKey: Key.strictness) }
    }
    @Published var scannerMode: ScannerMode {
        didSet { defaults.set(scannerMode.rawValue, forKey: Key.scannerMode) }
    }
    @Published var autoCapture: Bool {
        didSet { defaults.set(autoCapture, forKey: Key.autoCapture) }
    }
    @Published private(set) var folderBookmark: Data?
    @Published private(set) var folderName: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        colorMode = ColorMode(rawValue: defaults.string(forKey: Key.colorMode) ?? "") ?? .blackWhite
        compression = CompressionLevel(rawValue: defaults.string(forKey: Key.compression) ?? "") ?? .maximum
        destination = SaveDestination(rawValue: defaults.string(forKey: Key.destination) ?? "") ?? .app
        keepCopyInApp = defaults.object(forKey: Key.keepCopyInApp) as? Bool ?? true
        includeDate = defaults.bool(forKey: Key.includeDate)
        searchableText = defaults.object(forKey: Key.searchableText) as? Bool ?? true
        strictness = Strictness(rawValue: defaults.string(forKey: Key.strictness) ?? "") ?? .normal
        scannerMode = ScannerMode(rawValue: defaults.string(forKey: Key.scannerMode) ?? "") ?? .smart
        autoCapture = defaults.object(forKey: Key.autoCapture) as? Bool ?? true
        folderBookmark = defaults.data(forKey: Key.folderBookmark)
        folderName = defaults.string(forKey: Key.folderName)
        if destination == .folder && folderBookmark == nil {
            destination = .app
        }
    }

    /// True when scans go to PDFLito's own storage (either as target or as extra copy).
    var storesInApp: Bool {
        destination == .app || keepCopyInApp
    }

    /// Remembers a folder the user picked in the Files picker (iCloud Drive, Google Drive, OneDrive …).
    func setFolder(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let name = FileManager.default.displayName(atPath: url.path)
        folderBookmark = bookmark
        folderName = name
        defaults.set(bookmark, forKey: Key.folderBookmark)
        defaults.set(name, forKey: Key.folderName)
        destination = .folder
    }

    func updateBookmark(_ bookmark: Data) {
        folderBookmark = bookmark
        defaults.set(bookmark, forKey: Key.folderBookmark)
    }

    func clearFolder() {
        folderBookmark = nil
        folderName = nil
        defaults.removeObject(forKey: Key.folderBookmark)
        defaults.removeObject(forKey: Key.folderName)
        if destination == .folder {
            destination = .app
        }
    }

    /// Short text for buttons and captions, e.g. "in „Scans“".
    var destinationPhrase: String {
        switch destination {
        case .app: return "in PDFLito"
        case .folder: return folderName.map { "in „\($0)“" } ?? "in PDFLito"
        case .ask: return "in Google Drive oder an einem anderen Ort"
        }
    }

    /// Only used for App Store screenshots; never persisted.
    func applyDemoFolder(named name: String) {
        folderBookmark = Data([0])
        folderName = name
        destination = .folder
    }
}
