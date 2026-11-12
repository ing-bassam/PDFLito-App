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
    @State private var saveWarning: ScanSession.SaveOutcome?
    @State private var confirmDiscard = false
    @State private var detailPage: PageReference?
    @State private var rescanAfterDetail: ScanPage.ID?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
            DocumentScannerView(settings: settings, singlePage: replacingPage != nil) { images in
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
        .sheet(item: $detailPage, onDismiss: rescanIfRequested) { reference in
            if let index = session.pages.firstIndex(where: { $0.id == reference.id }) {
                let page = session.pages[index]
                PageDetailView(page: page, number: index + 1,
                               onRescan: { rescanAfterDetail = page.id },
                               onKeep: { session.keepAnyway(page.id) },
                               onRemove: { session.remove(page.id) })
            }
        }
        .confirmationDialog("Scan verwerfen?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Verwerfen", role: .destructive) { dismiss() }
            Button("Weiter bearbeiten", role: .cancel) {}
        }
        .alert("An anderem Ort gespeichert", isPresented: hasSaveWarning) {
            Button("OK", role: .cancel) {
                if let outcome = saveWarning {
                    saveWarning = nil
                    onSaved(outcome.message)
                    dismiss()
                }
            }
        } message: {
            Text(saveWarning?.warning ?? "")
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
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemFill)))

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
        .card()
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
                } else if !session.pages.isEmpty {
                    if session.rejectedCount == 0 {
                        StatusPill(text: "Alle gut lesbar", symbol: "checkmark.circle.fill", color: .green)
                    } else {
                        StatusPill(text: "\(session.rejectedCount) neu scannen",
                                   symbol: "exclamationmark.triangle.fill", color: .orange)
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(session.pages.enumerated()), id: \.element.id) { index, page in
                        PageCard(page: page, number: index + 1, count: session.pages.count,
                                 onOpen: { nameFocused = false; detailPage = PageReference(id: page.id) },
                                 onMove: { offset in withAnimation { session.move(page.id, by: offset) } },
                                 onRescan: { rescan(page.id) },
                                 onKeep: { session.keepAnyway(page.id) },
                                 onRemove: { session.remove(page.id) })
                    }
                    ForEach(0..<session.pendingPages, id: \.self) { _ in
                        PlaceholderCard()
                    }
                    AddPageCard {
                        replacingPage = nil
                        startScanner()
                    }
                }
                .padding(.vertical, 2)
            }
            Text("Tippe auf eine Seite, um sie groß anzusehen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .card()
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
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Color.orange.opacity(0.14)))
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
        .card()
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

    private var asksForPlace: Bool { settings.destination == .ask }

    private var actionBar: some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    if asksForPlace {
                        await prepareExport()
                    } else {
                        await saveToDefault()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if isWorking {
                        ProgressView()
                            .tint(.white)
                    }
                    VStack(spacing: 2) {
                        Text(asksForPlace ? "Speichern …" : "Speichern")
                            .font(.headline)
                        Text(settings.destinationPhrase)
                            .font(.caption)
                            .opacity(0.85)
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!session.canSave || isWorking)

            HStack(spacing: 10) {
                if asksForPlace {
                    Button {
                        Task { await saveToDefault() }
                    } label: {
                        Label("Nur in PDFLito", systemImage: "iphone")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                } else {
                    Button {
                        Task { await prepareExport() }
                    } label: {
                        Label("Woanders sichern", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
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
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .disabled(!session.canSave || isWorking)

            if !session.isAnalyzing && session.includedPages.isEmpty && !session.pages.isEmpty {
                Text("Keine Seite ist gut lesbar. Scanne neu oder wähle bei einer Seite „Trotzdem verwenden“.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private var nameBinding: Binding<String> {
        Binding(get: { session.fileName }, set: { session.setFileNameByUser($0) })
    }

    private var hasSaveWarning: Binding<Bool> {
        Binding(get: { saveWarning != nil }, set: { _ in })
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
        guard DocumentScannerView.isAvailable else { return }
        showScanner = true
    }

    private func rescan(_ pageID: ScanPage.ID) {
        replacingPage = pageID
        startScanner()
    }

    private func rescanIfRequested() {
        guard let pageID = rescanAfterDetail else { return }
        rescanAfterDetail = nil
        rescan(pageID)
    }

    private func saveToDefault() async {
        nameFocused = false
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try await session.saveToDefaultLocation(library: library)
            if outcome.warning != nil {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                saveWarning = outcome
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onSaved(outcome.message)
                dismiss()
            }
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
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onSaved(message)
        dismiss()
    }
}

private struct PageCard: View {
    let page: ScanPage
    let number: Int
    let count: Int
    var onOpen: () -> Void
    var onMove: (Int) -> Void
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
            Button(action: onOpen) {
                Image(uiImage: page.thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 128, height: 172)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(page.isRejected ? Color.orange : Color.primary.opacity(0.12), lineWidth: page.isRejected ? 3 : 1))
                    .opacity(page.isRejected ? 0.6 : 1)
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Seite \(number) groß ansehen")

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
                    if number > 1 {
                        Button {
                            onMove(-1)
                        } label: {
                            Label("Nach vorn", systemImage: "arrow.left")
                        }
                    }
                    if number < count {
                        Button {
                            onMove(1)
                        } label: {
                            Label("Nach hinten", systemImage: "arrow.right")
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
                StatusPill(text: page.keepAnyway ? "Manuell behalten" : verdict.title,
                           symbol: page.isRejected ? "exclamationmark.triangle.fill" : verdict.symbol,
                           color: statusColor)
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 128, height: 172)
                .overlay(ProgressView())
            Text("Wird geprüft …")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 128)
    }
}

private struct AddPageCard: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.largeTitle)
                Text("Seite hinzufügen")
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Color.accentColor)
            .frame(width: 128, height: 172)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct PageReference: Identifiable {
    let id: ScanPage.ID
}

/// One page in large, so the user can judge the sharpness before saving.
private struct PageDetailView: View {
    let page: ScanPage
    let number: Int
    var onRescan: () -> Void
    var onKeep: () -> Void
    var onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var zoomed = false

    private var statusColor: Color {
        guard let verdict = page.analysis?.verdict else { return .secondary }
        if page.isRejected { return .orange }
        return verdict == .good ? .green : (verdict.isAcceptable ? .teal : .orange)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Image(uiImage: image ?? page.thumbnail)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geometry.size.width * (zoomed ? 2.5 : 1),
                                   height: geometry.size.height * (zoomed ? 2.5 : 1))
                    }
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.25)) { zoomed.toggle() }
                    }
                }
                .background(Color(.systemGroupedBackground))

                VStack(alignment: .leading, spacing: 12) {
                    if let verdict = page.analysis?.verdict {
                        HStack(alignment: .top, spacing: 10) {
                            StatusPill(text: page.keepAnyway ? "Manuell behalten" : verdict.title,
                                       symbol: page.isRejected ? "exclamationmark.triangle.fill" : verdict.symbol,
                                       color: statusColor)
                            Text(verdict.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 10) {
                        Button {
                            onRescan()
                            dismiss()
                        } label: {
                            Label("Neu scannen", systemImage: "camera.viewfinder")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        if page.isRejected {
                            Button {
                                onKeep()
                                dismiss()
                            } label: {
                                Label("Trotzdem verwenden", systemImage: "checkmark")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 12))
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Seite \(number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .destructive) {
                        onRemove()
                        dismiss()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Seite entfernen")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { zoomed.toggle() }
                    } label: {
                        Image(systemName: zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass")
                    }
                    .accessibilityLabel(zoomed ? "Verkleinern" : "Vergrößern")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .task {
            let data = page.imageData
            image = await Task.detached(priority: .userInitiated) { UIImage(data: data) }.value
        }
    }
}
