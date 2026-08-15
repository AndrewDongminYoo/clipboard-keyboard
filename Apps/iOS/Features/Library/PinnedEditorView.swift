import ClipboardCore
import SwiftUI

struct PinnedEditorView: View {
    let item: PinnedRevision
    let onSave: (String, String, ClipCategory?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var text: String
    @State private var category: ClipCategory?

    init(item: PinnedRevision, onSave: @escaping (String, String, ClipCategory?) async -> Void) {
        self.item = item
        self.onSave = onSave
        _title = State(initialValue: item.payload.title)
        _text = State(initialValue: item.payload.canonicalInsertionString)
        _category = State(initialValue: item.payload.category)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextEditor(text: $text)
                    .frame(minHeight: 180)
                    .font(.body.monospaced())
                Picker("Category", selection: $category) {
                    Text("Uncategorized").tag(nil as ClipCategory?)
                    ForEach(ClipCategory.allCases, id: \.self) { category in
                        Text(category.rawValue.capitalized).tag(Optional(category))
                    }
                }
                Section {
                    Text("Saving creates a new immutable revision.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Pinned Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await onSave(title, text, category)
                            dismiss()
                        }
                    }
                    .disabled(title.isEmpty || text.isEmpty)
                }
            }
        }
    }
}
