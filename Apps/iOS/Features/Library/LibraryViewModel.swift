import ClipboardCore
import Foundation

enum LibraryCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case prompts
    case code
    case everyday
    case uncategorized

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .all: "All"
        case .prompts: "Prompts"
        case .code: "Code"
        case .everyday: "Everyday"
        case .uncategorized: "Uncategorized"
        }
    }
}

enum PhoneStorageStatus: Equatable {
    case available
    case locked
    case unavailable
}

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var items: [PinnedRevision] = []
    @Published var query = ""
    @Published private(set) var categoryFilter: LibraryCategoryFilter = .all
    @Published private(set) var editingItem: PinnedRevision?
    @Published private(set) var pendingDeletion: PinnedRevision?
    @Published private(set) var storageStatus: PhoneStorageStatus = .available

    private let library: any PinnedLibrary
    private let representations: @Sendable (String) async throws -> [ClipRepresentation]
    private var queryItems: [PinnedRevision] = []
    private var intentRevision: UInt64 = 0

    init(library: any PinnedLibrary, textTransformer: TextTransformer) {
        self.library = library
        representations = { text in
            let content = ResolvedTextContent(
                insertionString: text,
                originals: [
                    RawTextRepresentation(kind: .plainText, data: Data(text.utf8), textProjection: text),
                ]
            )
            return try textTransformer.render(content, as: .plainText)
        }
    }

    init(
        library: any PinnedLibrary,
        representations: @escaping @Sendable (String) async throws -> [ClipRepresentation]
    ) {
        self.library = library
        self.representations = representations
    }

    func load() async {
        let intent = beginIntent()
        do {
            let loadedItems = try await library.allItems()
            guard isCurrent(intent) else { return }
            queryItems = loadedItems
            storageStatus = .available
            projectItems()
        } catch let error as EncryptedPhonePinnedStoreError where error == .protectedDataUnavailable {
            guard isCurrent(intent) else { return }
            protectedDataWillBecomeUnavailable()
        } catch {
            guard isCurrent(intent) else { return }
            queryItems.removeAll(keepingCapacity: false)
            items.removeAll(keepingCapacity: false)
            storageStatus = .unavailable
        }
    }

    func updateQuery(_ newQuery: String) async {
        let intent = beginIntent()
        query = newQuery
        do {
            let loadedItems = newQuery.isEmpty
                ? try await library.allItems()
                : try await library.search(newQuery, limit: 100)
            guard isCurrent(intent) else { return }
            queryItems = loadedItems
            storageStatus = .available
            projectItems()
        } catch let error as EncryptedPhonePinnedStoreError where error == .protectedDataUnavailable {
            guard isCurrent(intent) else { return }
            protectedDataWillBecomeUnavailable()
        } catch {
            guard isCurrent(intent) else { return }
            queryItems.removeAll(keepingCapacity: false)
            items.removeAll(keepingCapacity: false)
            storageStatus = .unavailable
        }
    }

    func setCategoryFilter(_ filter: LibraryCategoryFilter) {
        categoryFilter = filter
        projectItems()
    }

    func beginEditing(_ item: PinnedRevision) {
        editingItem = item
    }

    func cancelEditing() {
        editingItem = nil
    }

    func saveEdit(title: String, text: String, category: ClipCategory?) async {
        guard let current = editingItem else { return }
        let intent = beginIntent()
        do {
            let payload = try PinPayload(
                representations: await representations(text),
                canonicalInsertionString: text,
                title: title,
                contentKind: category == .code ? .code : .plainText,
                category: category
            )
            _ = try await library.revise(itemID: current.itemID, payload: payload)
            guard isCurrent(intent) else { return }
            editingItem = nil
            await refreshCurrentQuery()
        } catch let error as EncryptedPhonePinnedStoreError where error == .protectedDataUnavailable {
            guard isCurrent(intent) else { return }
            protectedDataWillBecomeUnavailable()
        } catch {
            guard isCurrent(intent) else { return }
            storageStatus = .unavailable
        }
    }

    func requestDeletion(_ item: PinnedRevision) {
        pendingDeletion = item
    }

    func cancelDeletion() {
        pendingDeletion = nil
    }

    func confirmDeletion() async {
        guard let item = pendingDeletion else { return }
        let intent = beginIntent()
        do {
            _ = try await library.delete(itemID: item.itemID)
            guard isCurrent(intent) else { return }
            pendingDeletion = nil
            await refreshCurrentQuery()
        } catch let error as EncryptedPhonePinnedStoreError where error == .protectedDataUnavailable {
            guard isCurrent(intent) else { return }
            protectedDataWillBecomeUnavailable()
        } catch {
            guard isCurrent(intent) else { return }
            storageStatus = .unavailable
        }
    }

    func protectedDataWillBecomeUnavailable() {
        _ = beginIntent()
        queryItems.removeAll(keepingCapacity: false)
        items.removeAll(keepingCapacity: false)
        query = ""
        editingItem = nil
        pendingDeletion = nil
        storageStatus = .locked
    }

    private func refreshCurrentQuery() async {
        let currentQuery = query
        await updateQuery(currentQuery)
    }

    private func beginIntent() -> UInt64 {
        intentRevision &+= 1
        return intentRevision
    }

    private func isCurrent(_ intent: UInt64) -> Bool {
        intent == intentRevision
    }

    private func projectItems() {
        items = queryItems.filter { item in
            switch categoryFilter {
            case .all: true
            case .prompts: item.payload.category == .prompts
            case .code: item.payload.category == .code
            case .everyday: item.payload.category == .everyday
            case .uncategorized: item.payload.category == nil
            }
        }
    }
}
