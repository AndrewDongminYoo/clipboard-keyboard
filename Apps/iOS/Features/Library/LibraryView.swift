import ClipboardCore
import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: LibraryViewModel

    var body: some View {
        NavigationStack {
            Group {
                if model.storageStatus == .locked {
                    ContentUnavailableView(
                        "Protected Storage Locked",
                        systemImage: "lock.fill",
                        description: Text("Unlock the device and reopen the app to load pinned items.")
                    )
                } else if model.items.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                } else {
                    List(model.items, id: \.itemID) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.payload.title).font(.headline)
                            Text(item.payload.canonicalInsertionString)
                                .font(.body.monospaced())
                                .lineLimit(2)
                            Text("Sync Pending")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .leading) {
                            Button("Edit") { model.beginEditing(item) }
                                .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { model.requestDeletion(item) }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .searchable(text: queryBinding, prompt: "Search pinned items")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Category", selection: categoryBinding) {
                            ForEach(LibraryCategoryFilter.allCases) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                    } label: {
                        Label(model.categoryFilter.title, systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        .sheet(isPresented: editingPresented) {
            if let item = model.editingItem {
                PinnedEditorView(item: item) { title, text, category in
                    await model.saveEdit(title: title, text: text, category: category)
                }
            }
        }
        .confirmationDialog(
            "Delete this pinned item?",
            isPresented: deletionPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.confirmDeletion() }
            }
            Button("Cancel", role: .cancel) { model.cancelDeletion() }
        } message: {
            Text("The item disappears locally now while its content-free deletion remains pending.")
        }
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { model.query },
            set: { value in Task { await model.updateQuery(value) } }
        )
    }

    private var categoryBinding: Binding<LibraryCategoryFilter> {
        Binding(
            get: { model.categoryFilter },
            set: { value in model.setCategoryFilter(value) }
        )
    }

    private var editingPresented: Binding<Bool> {
        Binding(
            get: { model.editingItem != nil },
            set: {
                if !$0 {
                    model.cancelEditing()
                }
            }
        )
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { model.pendingDeletion != nil },
            set: {
                if !$0 {
                    model.cancelDeletion()
                }
            }
        )
    }
}
