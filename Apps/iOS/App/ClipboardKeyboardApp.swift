import SwiftUI

@main
struct ClipboardKeyboardApp: App {
    @StateObject private var model = PhoneAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneRootView(model: model)
                .task { await model.libraryViewModel.load() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await model.sceneDidBecomeActive() }
                }
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
        .sheet(
            isPresented: Binding(
                get: { model.pendingShare != nil },
                set: {
                    if !$0 {
                        model.dismissPendingShare()
                    }
                }
            )
        ) {
            if let item = model.pendingShare {
                PendingShareView(
                    item: item,
                    isWorking: model.shareCommitInProgress,
                    errorMessage: model.shareErrorMessage,
                    confirm: { await model.confirmPendingShare() },
                    reject: { await model.rejectPendingShare() }
                )
            }
        }
    }
}
