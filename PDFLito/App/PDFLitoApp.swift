import SwiftUI

@main
struct PDFLitoApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var library = DocumentLibrary()

    init() {
        DemoContent.prepareIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(settings)
                .environmentObject(library)
        }
    }
}
