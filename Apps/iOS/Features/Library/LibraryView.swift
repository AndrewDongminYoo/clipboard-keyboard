import ClipboardCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var filesModel: ImportExportViewModel
    @State private var exportDocument: ClipFileDocument?
    @State private var exportContentType: UTType = .plainText
    @State private var exportFilename = "Clipboard Item.txt"
    @State private var exportPresented = false
    @State private var shareURL: URL?

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
                            Text(item.syncState == .conflict ? "Conflict Copy" : "Sync Pending")
                                .font(.caption)
                                .foregroundStyle(item.syncState == .conflict ? .orange : .secondary)
                        }
                        .swipeActions(edge: .leading) {
                            Button("Edit") { model.beginEditing(item) }
                                .tint(.blue)
                        }
                        .contextMenu {
                            ForEach(availableFormats(for: item), id: \.self) { format in
                                Button("Export .\(format.fileExtension)") { beginExport(item, as: format) }
                                Button("Share .\(format.fileExtension)") { beginShare(item, as: format) }
                            }
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
            .safeAreaInset(edge: .bottom) {
                if let errorMessage = filesModel.shareErrorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
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
        .fileExporter(
            isPresented: $exportPresented,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { _ in
            exportDocument = nil
        }
        .sheet(isPresented: sharePresented) {
            NavigationStack {
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Label("Share Item", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("Share Item")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? filesModel.completeShare()
                        shareURL = nil
                    }
                }
            }
        }
        .onDisappear { filesModel.shareViewDidDisappear() }
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

    private var sharePresented: Binding<Bool> {
        Binding(
            get: { shareURL != nil },
            set: { presented in
                if !presented {
                    try? filesModel.cancelShare()
                    shareURL = nil
                }
            }
        )
    }

    private func availableFormats(for item: PinnedRevision) -> [ClipDocumentFormat] {
        ClipDocumentFormat.allCases.filter { format in
            item.payload.representations.contains { $0.kind == format.representationKind }
        }
    }

    private func beginExport(_ item: PinnedRevision, as format: ClipDocumentFormat) {
        guard let document = try? filesModel.document(for: item, as: format) else { return }
        exportDocument = ClipFileDocument(document: document)
        exportContentType = format.contentType
        exportFilename = "Clipboard Item.\(format.fileExtension)"
        exportPresented = true
    }

    private func beginShare(_ item: PinnedRevision, as format: ClipDocumentFormat) {
        shareURL = try? filesModel.prepareTemporaryShare(of: item, as: format)
    }
}
