import SwiftUI

@main
struct ClipboardKeyboardApp: App {
    @StateObject private var model = PhoneAppModel()

    var body: some Scene {
        WindowGroup {
            PhoneRootView(model: model)
                .task { await model.libraryViewModel.load() }
        }
    }
}

private struct PhoneRootView: View {
    @ObservedObject var model: PhoneAppModel
    @ObservedObject private var libraryViewModel: LibraryViewModel

    init(model: PhoneAppModel) {
        self.model = model
        libraryViewModel = model.libraryViewModel
    }

    var body: some View {
        TabView {
            LibraryView(model: libraryViewModel, filesModel: model.importExportViewModel)
                .tabItem { Label("Library", systemImage: "pin.fill") }

            ExtractView(model: model.extractViewModel)
                .tabItem { Label("Extract", systemImage: "text.viewfinder") }

            PhoneSettingsView(storageStatus: libraryViewModel.storageStatus, filesModel: model.importExportViewModel)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
