import ClipboardCore
import SwiftUI

struct PendingShareView: View {
    let item: ShareInboxItem
    let isWorking: Bool
    let errorMessage: String?
    let confirm: () async -> Void
    let reject: () async -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(item.kind == .url ? "Shared URL" : "Shared Text")
                    .font(.headline)
                Text(String(decoding: item.data, as: UTF8.self))
                    .lineLimit(10)
                    .textSelection(.enabled)
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
                Spacer()
                HStack {
                    Button("Reject", role: .destructive) { Task { await reject() } }
                    Spacer()
                    Button("Pin") { Task { await confirm() } }
                        .buttonStyle(.borderedProminent)
                }
                .disabled(isWorking)
            }
            .padding()
            .navigationTitle("Confirm Shared Item")
        }
    }
}
