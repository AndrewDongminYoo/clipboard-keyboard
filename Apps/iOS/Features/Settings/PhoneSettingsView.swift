import SwiftUI

struct PhoneSettingsView: View {
    let storageStatus: PhoneStorageStatus
    @ObservedObject var filesModel: ImportExportViewModel
    @State private var syncEnabled = false
    @State private var importerPresented = false
    @State private var importTitle = "Imported Item"

    var body: some View {
        NavigationStack {
            Form {
                Section("Synchronization") {
                    Toggle("iCloud Sync", isOn: $syncEnabled)
                        .disabled(true)
                    Text("Sync is off. Local changes stay queued until a later version adds synchronization.")
                        .foregroundStyle(.secondary)
                }

                Section("Local Cache") {
                    LabeledContent("Protected storage", value: storageLabel)
                    Text("Pinned content is stored as one authenticated encrypted document and is unavailable while protected data is locked.")
                        .foregroundStyle(.secondary)
                }

                Section("Privacy") {
                    Text("Only items you explicitly pin become durable. This app does not monitor the iPhone clipboard, and this version does not send pinned content remotely.")
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
    }

    private var storageLabel: String {
        switch storageStatus {
        case .available: "Available"
        case .locked: "Locked"
        case .unavailable: "Unavailable"
        }
    }
}
