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
            DocumentScannerView { images in
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

    private var filteredDocuments: [StoredDocument] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return library.documents }
        return library.documents.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var documentList: some View {
        List {
            ForEach(filteredDocuments) { document in
                Button {
                    previewURL = document.url
                } label: {
                    DocumentRow(document: document)
                }
                .buttonStyle(.plain)
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
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Dokumente durchsuchen")
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Noch keine Scans")
                .font(.title2.weight(.semibold))
            Text("Tippe auf „Scannen“. PDFLito prüft, ob jede Seite scharf ist, liest die Überschrift und benennt die PDF automatisch.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if settings.destination == .app {
                Button {
                    showSettings = true
                } label: {
                    Label("Speicherort wählen, z. B. Google Drive", systemImage: "folder.badge.gearshape")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var scanButton: some View {
        VStack(spacing: 6) {
            Button(action: startScan) {
                Label("Scannen", systemImage: "doc.viewfinder")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            Text(destinationText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(.bar)
    }

    private var destinationText: String {
        if settings.destination == .folder, let name = settings.folderName {
            return "Speichert in „\(name)“"
        }
        return "Speichert in PDFLito"
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
        guard VNDocumentCameraViewController.isSupported else {
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

struct DocumentRow: View {
    let document: StoredDocument

    var body: some View {
        HStack(spacing: 14) {
            PDFThumbnail(url: document.url)
                .frame(width: 44, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(document.name)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text("\(document.modified.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(document.size), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
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
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.secondarySystemBackground))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.1)))
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
