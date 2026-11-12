import SwiftUI
import QuickLook
import VisionKit

struct LibraryView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: DocumentLibrary
    @Environment(\.scenePhase) private var scenePhase

    @State private var showScanner = false
    @State private var scannedImages: [UIImage] = []
    @State private var session: ScanSession?
    @State private var showSettings = false
    @State private var previewURL: URL?
    @State private var search = ""
    @State private var renaming: StoredDocument?
    @State private var renameText = ""
    @State private var deleting: StoredDocument?
    @State private var toast: String?
    @State private var showCameraUnavailable = false
    @State private var didApplyLaunchScreen = false
    @AppStorage("librarySort") private var sort = LibrarySort.date

    var body: some View {
        NavigationStack {
            Group {
                if library.documents.isEmpty {
                    emptyState
                } else {
                    documentList
                }
            }
            .navigationTitle("PDFLito")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !library.documents.isEmpty {
                        Menu {
                            Picker("Sortierung", selection: $sort) {
                                ForEach(LibrarySort.allCases) { option in
                                    Label(option.title, systemImage: option.symbol).tag(option)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .accessibilityLabel("Sortierung")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Einstellungen")
                }
            }
            .safeAreaInset(edge: .bottom) {
                scanButton
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                ToastView(text: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { self.toast = nil }
                    }
            }
        }
        .fullScreenCover(isPresented: $showScanner, onDismiss: startReviewIfNeeded) {
            DocumentScannerView(settings: settings) { images in
                scannedImages = images
                showScanner = false
            } onCancel: {
                showScanner = false
            }
            .ignoresSafeArea()
        }
        .sheet(item: $session, onDismiss: { library.reload() }) { session in
            ReviewView(session: session) { message in
                withAnimation { toast = message }
            }
            .environmentObject(settings)
            .environmentObject(library)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
        }
        .quickLookPreview($previewURL)
        .alert("Umbenennen", isPresented: isRenaming) {
            TextField("Dateiname", text: $renameText)
            Button("Abbrechen", role: .cancel) { renaming = nil }
            Button("Sichern") {
                if let document = renaming {
                    try? library.rename(document, to: renameText)
                }
                renaming = nil
            }
        }
        .confirmationDialog("Dokument löschen?", isPresented: isDeleting, titleVisibility: .visible,
                            presenting: deleting) { document in
            Button("„\(document.name)“ löschen", role: .destructive) {
                try? library.delete(document)
                deleting = nil
            }
            Button("Abbrechen", role: .cancel) { deleting = nil }
        }
        .alert("Kamera nicht verfügbar", isPresented: $showCameraUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Auf diesem Gerät kann nicht gescannt werden.")
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { library.reload() }
        }
        .task {
            applyLaunchScreen()
        }
    }

    // MARK: - Content

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var filteredDocuments: [StoredDocument] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty
            ? library.documents
            : library.documents.filter { $0.name.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .date:
            return matching
        case .name:
            return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            return matching.sorted { $0.size > $1.size }
        }
    }

    /// Newest-first lists are grouped by time; every other order is one flat list.
    private var sections: [DocumentSection] {
        let documents = filteredDocuments
        guard sort == .date, !isSearching else {
            return documents.isEmpty ? [] : [DocumentSection(title: "", documents: documents)]
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        var result: [DocumentSection] = []
        for document in documents {
            let title: String
            if document.modified >= today {
                title = "Heute"
            } else if document.modified >= weekAgo {
                title = "Letzte 7 Tage"
            } else {
                title = document.modified.formatted(.dateTime.month(.wide).year())
            }
            if let last = result.indices.last, result[last].title == title {
                result[last].documents.append(document)
            } else {
                result.append(DocumentSection(title: title, documents: [document]))
            }
        }
        return result
    }

    private var summaryText: String {
        let count = library.documents.count
        let bytes = library.documents.reduce(0) { $0 + $1.size }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(count == 1 ? "1 Dokument" : "\(count) Dokumente") · \(size)"
    }

    private var documentList: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.documents) { document in
                        row(for: document)
                    }
                } header: {
                    if !section.title.isEmpty {
                        Text(section.title)
                    }
                }
            }
            if sections.isEmpty {
                noResults
                    .listRowBackground(Color.clear)
            } else if !isSearching {
                Text(summaryText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: sort)
        .refreshable { library.reload() }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Dokumente durchsuchen")
    }

    private func row(for document: StoredDocument) -> some View {
        Button {
            previewURL = document.url
        } label: {
            DocumentRow(document: document)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            ShareLink(item: document.url) {
                Label("Teilen", systemImage: "square.and.arrow.up")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleting = document
            } label: {
                Label("Löschen", systemImage: "trash")
            }
            Button {
                startRename(document)
            } label: {
                Label("Umbenennen", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                previewURL = document.url
            } label: {
                Label("Öffnen", systemImage: "doc.text.magnifyingglass")
            }
            Button {
                startRename(document)
            } label: {
                Label("Umbenennen", systemImage: "pencil")
            }
            ShareLink(item: document.url) {
                Label("Teilen oder in Drive sichern", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                deleting = document
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }

    private var noResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Keine Treffer")
                .font(.headline)
            Text("Kein Dokument heißt wie „\(search)“.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 96)
                    .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.gradient))
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 14, y: 8)
                    .padding(.top, 32)
                VStack(spacing: 6) {
                    Text("Noch keine Scans")
                        .font(.title2.weight(.bold))
                    Text("In drei Schritten zur fertigen PDF")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 18) {
                    StepRow(symbol: "camera.viewfinder", title: "Scannen",
                            text: "Seite ins Bild halten – die Kamera löst erst aus, wenn alles scharf ist.")
                    StepRow(symbol: "checkmark.seal", title: "Prüfen",
                            text: "PDFLito erkennt unscharfe Seiten und schlägt einen Dateinamen vor.")
                    StepRow(symbol: "square.and.arrow.down", title: "Speichern",
                            text: "Als kleine, durchsuchbare PDF – in PDFLito, Google Drive oder einem Ordner.")
                }
                .card()
                if settings.destination == .app {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Speicherort wählen, z. B. Google Drive", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var scanButton: some View {
        VStack(spacing: 8) {
            Button(action: startScan) {
                Label("Scannen", systemImage: "doc.viewfinder")
                    .font(.title3.weight(.semibold))
            }
            .buttonStyle(PrimaryButtonStyle())
            Button {
                showSettings = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(destinationText)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Speicherort ändern")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var destinationText: String {
        "Speichert \(settings.destinationPhrase)"
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    // MARK: - Actions

    private func startScan() {
        if DemoContent.isActive {
            session = ScanSession(images: DemoContent.samplePages(), settings: settings)
            return
        }
        guard DocumentScannerView.isAvailable else {
            showCameraUnavailable = true
            return
        }
        showScanner = true
    }

    private func startReviewIfNeeded() {
        guard !scannedImages.isEmpty else { return }
        session = ScanSession(images: scannedImages, settings: settings)
        scannedImages = []
    }

    private func startRename(_ document: StoredDocument) {
        renameText = document.name
        renaming = document
    }

    private func applyLaunchScreen() {
        guard !didApplyLaunchScreen else { return }
        didApplyLaunchScreen = true
        switch DemoContent.launchScreen {
        case "review":
            session = ScanSession(images: DemoContent.samplePages(), settings: settings)
        case "settings":
            showSettings = true
        default:
            break
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case date
    case name
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .date: return "Neueste zuerst"
        case .name: return "Nach Name"
        case .size: return "Größte zuerst"
        }
    }

    var symbol: String {
        switch self {
        case .date: return "clock"
        case .name: return "textformat"
        case .size: return "internaldrive"
        }
    }
}

private struct DocumentSection: Identifiable {
    let title: String
    var documents: [StoredDocument]

    var id: String { title }
}

private struct StepRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconBadge(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct DocumentRow: View {
    let document: StoredDocument

    private var dateText: String {
        Calendar.current.isDateInToday(document.modified)
            ? "Heute, \(document.modified.formatted(date: .omitted, time: .shortened))"
            : document.modified.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        HStack(spacing: 14) {
            PDFThumbnail(url: document.url)
                .frame(width: 46, height: 62)
            VStack(alignment: .leading, spacing: 5) {
                Text(document.name)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text("\(dateText) · \(ByteCountFormatter.string(fromByteCount: Int64(document.size), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct PDFThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
        .task(id: url) {
            image = await ThumbnailCache.shared.thumbnail(for: url)
        }
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .padding(.top, 8)
    }
}
