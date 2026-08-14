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
            LibraryView(model: libraryViewModel)
                .tabItem { Label("Library", systemImage: "pin.fill") }

            NavigationStack {
                ContentUnavailableView(
                    "Extract is coming next",
                    systemImage: "text.viewfinder",
                    description: Text("The next milestone adds explicit system paste intake and on-device value extraction.")
                )
                .navigationTitle("Extract")
            }
            .tabItem { Label("Extract", systemImage: "text.viewfinder") }

            PhoneSettingsView(storageStatus: libraryViewModel.storageStatus)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
