import Foundation
import PDFKit
import UIKit

struct StoredDocument: Identifiable, Hashable {
    let url: URL
    let name: String
    let modified: Date
    let size: Int

    var id: URL { url }
}

/// PDFs stored inside PDFLito. The folder is also visible in the Files app
/// under "Auf meinem iPhone › PDFLito".
final class DocumentLibrary: ObservableObject {
    @Published private(set) var documents: [StoredDocument] = []
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        reload()
    }

    func reload() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        documents = urls
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return StoredDocument(url: url, name: url.deletingPathExtension().lastPathComponent,
                                      modified: values?.contentModificationDate ?? .distantPast,
                                      size: values?.fileSize ?? 0)
            }
            .sorted { $0.modified > $1.modified }
    }

    @discardableResult
    func save(_ data: Data, named name: String) throws -> URL {
        let url = FileNamer.uniqueURL(in: directory, baseName: name)
        try data.write(to: url, options: .atomic)
        reload()
        return url
    }

    func rename(_ document: StoredDocument, to newName: String) throws {
        let clean = FileNamer.sanitize(newName)
        guard !clean.isEmpty, clean != document.name else { return }
        let target = FileNamer.uniqueURL(in: directory, baseName: clean)
        try FileManager.default.moveItem(at: document.url, to: target)
        reload()
    }

    func delete(_ document: StoredDocument) throws {
        try FileManager.default.removeItem(at: document.url)
        reload()
    }
}

/// Writes into a folder the user picked in the Files picker (iCloud Drive, Google Drive, OneDrive …).
enum FolderSaver {
    struct Result {
        let url: URL
        let refreshedBookmark: Data?
    }

    static func save(_ data: Data, baseName: String, bookmark: Data) throws -> Result {
        var isStale = false
        let folder: URL
        do {
            folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        } catch {
            throw ScanError.folderUnavailable
        }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

        var refreshed: Data?
        if isStale {
            refreshed = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        let target = FileNamer.uniqueURL(in: folder, baseName: baseName)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: .forReplacing,
                                                          error: &coordinationError) { url in
            do {
                try data.write(to: url)
            } catch {
                writeError = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let writeError {
            throw writeError
        }
        return Result(url: target, refreshedBookmark: refreshed)
    }
}

/// Small first-page previews for the document list.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, UIImage>()

    func thumbnail(for url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            return page.thumbnail(of: CGSize(width: 120, height: 170), for: .mediaBox)
        }.value
        if let image {
            cache.setObject(image, forKey: url as NSURL)
        }
        return image
    }
}
