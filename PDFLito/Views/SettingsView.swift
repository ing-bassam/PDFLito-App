import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var pickingFolder = false
    @State private var folderError: String?

    var body: some View {
        NavigationStack {
            Form {
                destinationSection
                nameSection
                sizeSection
                qualitySection
                privacySection
                Section {
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $pickingFolder) {
            FolderPicker { url in
                pickingFolder = false
                do {
                    try settings.setFolder(url)
                } catch {
                    folderError = error.localizedDescription
                }
            } onCancel: {
                pickingFolder = false
            }
            .ignoresSafeArea()
        }
        .alert("Ordner nicht verfügbar", isPresented: hasFolderError) {
            Button("OK", role: .cancel) { folderError = nil }
        } message: {
            Text(folderError ?? "")
        }
    }

    private var destinationSection: some View {
        Section {
            Picker("Speichern in", selection: destinationBinding) {
                Text("PDFLito (auf diesem iPhone)")
                    .tag(SaveDestination.app)
                Text(settings.folderName.map { "Ordner „\($0)“" } ?? "Eigener Ordner …")
                    .tag(SaveDestination.folder)
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Button {
                pickingFolder = true
            } label: {
                Label(settings.folderBookmark == nil ? "Ordner wählen (z. B. Google Drive) …" : "Anderen Ordner wählen …",
                      systemImage: "folder.badge.plus")
            }

            if settings.destination == .folder {
                Toggle("Kopie zusätzlich in PDFLito behalten", isOn: $settings.keepCopyInApp)
            }
        } header: {
            Text("Speicherort")
        } footer: {
            Text("Google Drive: Google-Drive-App installieren, anmelden und in der Dateien-App unter „Orte“ einschalten. Danach kannst du hier einen Drive-Ordner wählen – jeder Scan landet dann direkt dort. PDFLito selbst braucht keine Anmeldung. Genauso funktionieren iCloud Drive, OneDrive und Dropbox.")
        }
    }

    private var nameSection: some View {
        Section {
            Toggle("Datum voranstellen", isOn: $settings.includeDate)
        } header: {
            Text("Dateiname")
        } footer: {
            Text(settings.includeDate
                 ? "Beispiel: „2026-10-31 Rechnung Stadtwerke.pdf“. Das Datum wird aus dem Dokument gelesen, sonst wird das heutige verwendet."
                 : "Beispiel: „Rechnung Stadtwerke.pdf“. Der Name kommt aus der größten Überschrift oder der Betreffzeile.")
        }
    }

    private var sizeSection: some View {
        Section {
            Picker("Standardformat", selection: $settings.colorMode) {
                ForEach(ColorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker("Komprimierung", selection: $settings.compression) {
                ForEach(CompressionLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            Toggle("Durchsuchbarer Text (OCR)", isOn: $settings.searchableText)
        } header: {
            Text("Dateigröße")
        } footer: {
            Text("Schwarzweiß mit maximaler Komprimierung ergibt die kleinsten Dateien. Durchsuchbarer Text kostet nur wenige Kilobyte und macht die PDF in Google Drive und der Dateien-App durchsuchbar.")
        }
    }

    private var qualitySection: some View {
        Section {
            Picker("Schärfeprüfung", selection: $settings.strictness) {
                ForEach(Strictness.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
        } header: {
            Text("Lesbarkeit")
        } footer: {
            Text("Unscharfe, verwackelte oder zu dunkle Seiten werden erkannt und erst gespeichert, wenn du sie neu gescannt hast.")
        }
    }

    private var privacySection: some View {
        Section {
            Label("Keine Anmeldung, kein Konto", systemImage: "person.crop.circle.badge.xmark")
            Label("Keine Cookies, kein Tracking, keine Werbung", systemImage: "hand.raised")
            Label("Texterkennung nur auf diesem Gerät", systemImage: "iphone")
            Label("Keine Internetverbindung nötig", systemImage: "wifi.slash")
        } header: {
            Text("Datenschutz")
        }
    }

    private var destinationBinding: Binding<SaveDestination> {
        Binding(get: { settings.destination }, set: { newValue in
            if newValue == .folder && settings.folderBookmark == nil {
                pickingFolder = true
            } else {
                settings.destination = newValue
            }
        })
    }

    private var hasFolderError: Binding<Bool> {
        Binding(get: { folderError != nil }, set: { if !$0 { folderError = nil } })
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
