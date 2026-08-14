import SwiftUI

struct PhoneSettingsView: View {
    let storageStatus: PhoneStorageStatus
    @State private var syncEnabled = false

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
            }
            .navigationTitle("Settings")
        }
    }

    private var storageLabel: String {
        switch storageStatus {
        case .available: "Available"
        case .locked: "Locked"
        case .unavailable: "Unavailable"
        }
    }
}
