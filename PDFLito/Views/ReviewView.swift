import SwiftUI
import VisionKit

/// After scanning: check the pages, confirm the suggested name and save.
struct ReviewView: View {
    @ObservedObject var session: ScanSession
    var onSaved: (String) -> Void

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: DocumentLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var showScanner = false
    @State private var replacingPage: ScanPage.ID?
    @State private var exportItem: FileItem?
    @State private var shareItem: FileItem?
    @State private var pendingMessage: String?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var confirmDiscard = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    nameSection
                    pagesSection
                    if session.rejectedCount > 0 {
                        rejectionBanner
                    }
                    formatSection
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Prüfen & speichern")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Verwerfen") { confirmDiscard = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        replacingPage = nil
                        startScanner()
                    } label: {
                        Label("Seite hinzufügen", systemImage: "plus")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
        }
        .interactiveDismissDisabled()
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView { images in
                session.add(images, replacing: replacingPage)
                replacingPage = nil
                showScanner = false
            } onCancel: {
                replacingPage = nil
                showScanner = false
            }
            .ignoresSafeArea()
        }
        .sheet(item: $exportItem, onDismiss: finishIfDone) { item in
            ExportPicker(url: item.url) { success in
                if success { pendingMessage = "„\(session.finalName)“ gesichert" }
                exportItem = nil
            }
            .ignoresSafeArea()
        }
        .sheet(item: $shareItem, onDismiss: finishIfDone) { item in
            ShareSheet(items: [item.url]) { completed in
                if completed { pendingMessage = "„\(session.finalName)“ geteilt" }
                shareItem = nil
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Scan verwerfen?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Verwerfen", role: .destructive) { dismiss() }
            Button("Weiter bearbeiten", role: .cancel) {}
        }
        .alert("Speichern nicht möglich", isPresented: hasError) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dateiname")
                .font(.headline)
            HStack(spacing: 6) {
                TextField("Dateiname", text: nameBinding)
                    .focused($nameFocused)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { nameFocused = false }
                Text(".pdf")
                    .foregroundStyle(.secondary)
                if !session.fileName.isEmpty {
                    Button {
                        session.setFileNameByUser("")
                        nameFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityLabel("Name löschen")
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))

            if session.suggestions.isEmpty {
                if session.isAnalyzing {
                    Label("Lese Überschriften …", systemImage: "text.viewfinder")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Vorschläge aus dem Dokument")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(session.suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                session.applySuggestion(suggestion)
                            }
                            .lineLimit(1)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                        }
                    }
                }
            }
        }
    }

    private var pagesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Seiten")
                    .font(.headline)
                Spacer()
                if session.isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Prüfe Schärfe …")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(session.pages.enumerated()), id: \.element.id) { index, page in
                        PageCard(page: page, number: index + 1,
                                 onRescan: { rescan(page.id) },
                                 onKeep: { session.keepAnyway(page.id) },
                                 onRemove: { session.remove(page.id) })
                    }
                    ForEach(0..<session.pendingPages, id: \.self) { _ in
                        PlaceholderCard()
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var rejectionBanner: some View {
        let count = session.rejectedCount
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(count == 1 ? "1 Seite ist nicht gut lesbar" : "\(count) Seiten sind nicht gut lesbar")
                    .font(.subheadline.weight(.semibold))
                Text("Diese Seiten werden nicht gespeichert. Tippe auf „Neu scannen“ – mit ruhiger Hand und gutem Licht.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Format")
                .font(.headline)
            Picker("Format", selection: $session.colorMode) {
                ForEach(ColorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            HStack(alignment: .firstTextBaseline) {
                Text(session.colorMode.hint)
                Spacer()
                sizeLabel
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sizeLabel: some View {
        let count = session.includedPages.count
        if let bytes = session.estimatedBytes {
            Text("\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) · \(count == 1 ? "1 Seite" : "\(count) Seiten")")
                .monospacedDigit()
                .foregroundStyle(.primary)
        } else if session.canSave {
            ProgressView()
                .controlSize(.mini)
        }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            Button {
                Task { await saveToDefault() }
            } label: {
                HStack(spacing: 8) {
                    if isWorking {
                        ProgressView()
                            .tint(.white)
                    }
                    VStack(spacing: 2) {
                        Text("Speichern")
                            .font(.headline)
                        Text(destinationText)
                            .font(.caption)
                            .opacity(0.85)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!session.canSave || isWorking)

            HStack(spacing: 10) {
                Button {
                    Task { await prepareExport() }
                } label: {
                    Label("Woanders sichern", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                Button {
                    Task { await prepareShare() }
                } label: {
                    Label("Teilen", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
            }
            .buttonStyle(.bordered)
            .disabled(!session.canSave || isWorking)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private var destinationText: String {
        if settings.destination == .folder, let name = settings.folderName {
            return "in „\(name)“"
        }
        return "in PDFLito"
    }

    private var nameBinding: Binding<String> {
        Binding(get: { session.fileName }, set: { session.setFileNameByUser($0) })
    }

    private var hasError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    // MARK: - Actions

    private func startScanner() {
        if DemoContent.isActive {
            session.add(DemoContent.samplePages(includeBlurred: false), replacing: replacingPage)
            replacingPage = nil
            return
        }
        guard VNDocumentCameraViewController.isSupported else { return }
        showScanner = true
    }

    private func rescan(_ pageID: ScanPage.ID) {
        replacingPage = pageID
        startScanner()
    }

    private func saveToDefault() async {
        nameFocused = false
        isWorking = true
        defer { isWorking = false }
        do {
            let message = try await session.saveToDefaultLocation(library: library)
            onSaved(message)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareExport() async {
        nameFocused = false
        isWorking = true
        defer { isWorking = false }
        do {
            exportItem = FileItem(url: try await session.temporaryFile())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareShare() async {
        nameFocused = false
        isWorking = true
        defer { isWorking = false }
        do {
            shareItem = FileItem(url: try await session.temporaryFile())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finishIfDone() {
        guard let message = pendingMessage else { return }
        pendingMessage = nil
        session.keepCopyIfNeeded(library: library)
        onSaved(message)
        dismiss()
    }
}

private struct PageCard: View {
    let page: ScanPage
    let number: Int
    var onRescan: () -> Void
    var onKeep: () -> Void
    var onRemove: () -> Void

    private var verdict: QualityVerdict? { page.analysis?.verdict }

    private var statusColor: Color {
        guard let verdict else { return .secondary }
        if page.isRejected { return .orange }
        return verdict == .good ? .green : (verdict.isAcceptable ? .teal : .orange)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(uiImage: page.thumbnail)
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 172)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(page.isRejected ? Color.orange : Color.primary.opacity(0.12), lineWidth: page.isRejected ? 3 : 1))
                .opacity(page.isRejected ? 0.55 : 1)
                .overlay(alignment: .topTrailing) {
                    if let verdict {
                        Image(systemName: page.isRejected ? "exclamationmark.triangle.fill" : verdict.symbol)
                            .font(.title3)
                            .foregroundStyle(.white, statusColor)
                            .padding(6)
                    }
                }

            HStack(spacing: 4) {
                Text("Seite \(number)")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Menu {
                    Button {
                        onRescan()
                    } label: {
                        Label("Neu scannen", systemImage: "camera.viewfinder")
                    }
                    if page.isRejected {
                        Button {
                            onKeep()
                        } label: {
                            Label("Trotzdem verwenden", systemImage: "checkmark")
                        }
                    }
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("Seite entfernen", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                }
                .accessibilityLabel("Aktionen für Seite \(number)")
            }
            if let verdict {
                Text(page.keepAnyway ? "Manuell behalten" : verdict.title)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            if page.isRejected {
                Button("Neu scannen", action: onRescan)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
            }
        }
        .frame(width: 128)
    }
}

private struct PlaceholderCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(width: 128, height: 172)
                .overlay(ProgressView())
            Text("Wird geprüft …")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 128)
    }
}
