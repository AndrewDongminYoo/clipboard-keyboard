import SwiftUI

struct PhoneSettingsView: View {
    let storageStatus: PhoneStorageStatus
    @ObservedObject var filesModel: ImportExportViewModel
    @Binding private var syncEnabled: Bool
    private let syncStatus: PhonePinnedSyncStatus
    private let recoveryActionInProgress: Bool
    private let keepLocalAndTurnSyncOff: @MainActor () async -> Void
    private let reuploadLocalPins: @MainActor () async -> Void
    @State private var importerPresented = false
    @State private var importTitle = "Imported Item"
    @State private var recoveryConfirmationPresented = false

    init(
        storageStatus: PhoneStorageStatus,
        filesModel: ImportExportViewModel,
        syncStatus: PhonePinnedSyncStatus = .disabled,
        syncEnabled: Binding<Bool> = .constant(false),
        recoveryActionInProgress: Bool = false,
        keepLocalAndTurnSyncOff: @escaping @MainActor () async -> Void = {},
        reuploadLocalPins: @escaping @MainActor () async -> Void = {}
    ) {
        self.storageStatus = storageStatus
        self.filesModel = filesModel
        self.syncStatus = syncStatus
        self.recoveryActionInProgress = recoveryActionInProgress
        self.keepLocalAndTurnSyncOff = keepLocalAndTurnSyncOff
        self.reuploadLocalPins = reuploadLocalPins
        _syncEnabled = syncEnabled
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Synchronization") {
                    Toggle("iCloud Sync", isOn: $syncEnabled)
                    Text(syncEnabled ? "Pinned changes synchronize through your private iCloud database." : "Sync is off. Local pinned changes remain queued on this device.")
                        .foregroundStyle(.secondary)
                    if let statusLabel {
                        LabeledContent("Status", value: statusLabel)
                    }
                    if syncStatus == .recoveryRequired {
                        Text("Cloud account or encrypted sync state changed. Choose how to continue; local pins remain on this iPhone until you decide.")
                            .foregroundStyle(.secondary)
                        Button("Keep Local and Turn Sync Off") {
                            Task { await keepLocalAndTurnSyncOff() }
                        }
                        .disabled(recoveryActionInProgress)
                        Button("Re-upload Local Pins") {
                            recoveryConfirmationPresented = true
                        }
                        .disabled(recoveryActionInProgress)
                    }
                }

                Section("Local Cache") {
                    LabeledContent("Protected storage", value: storageLabel)
                    Text("Pinned content is stored as one authenticated encrypted document and is unavailable while protected data is locked.")
                        .foregroundStyle(.secondary)
                }

                Section("Privacy") {
                    Text("Only items you explicitly pin become durable. This app does not monitor the iPhone clipboard. When sync is enabled, pinned content is stored in encrypted CloudKit fields.")
                }

                Section("Import") {
                    Button("Choose TXT, Markdown, RTF, or HTML") { importerPresented = true }
                    Text("Selecting a file only creates an in-memory preview. Review it, then explicitly Pin to save one item.")
                        .foregroundStyle(.secondary)
                    if let preview = filesModel.importPreview {
                        TextField("Title", text: $importTitle)
                        Text(preview.canonicalInsertionString)
                            .font(.body.monospaced())
                            .lineLimit(5)
                        HStack {
                            Button("Cancel", role: .cancel) { filesModel.cancelImport() }
                            Button("Pin") {
                                Task { try? await filesModel.pinImportedDocument(title: importTitle) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    if let errorMessage = filesModel.importErrorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: ClipFileDocument.readableContentTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result,
                  let url = urls.first
            else {
                filesModel.cancelImport()
                return
            }
            try? filesModel.importFile(at: url)
        }
        .onDisappear { filesModel.importViewDidDisappear() }
        .confirmationDialog(
            "Re-upload local pins?",
            isPresented: $recoveryConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Re-upload Local Pins") {
                Task { await reuploadLocalPins() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the local outgoing queue and starts a new sync session. It does not delete remote records.")
        }
    }

    private var storageLabel: String {
        switch storageStatus {
        case .available: "Available"
        case .locked: "Locked"
        case .unavailable: "Unavailable"
        }
    }

    private var statusLabel: String? {
        switch syncStatus {
        case .pending: "Pending"
        case .unableToSyncFullItem: "Unable to Sync Full Item"
        case .accountUnavailable: "Account Unavailable"
        case .recoveryRequired: "Recovery Required"
        case .disabled, .synced: nil
        }
    }
}
