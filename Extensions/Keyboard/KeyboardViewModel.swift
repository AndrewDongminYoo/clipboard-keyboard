import ClipboardCore
import Foundation
import SwiftUI

@MainActor
final class KeyboardViewModel: ObservableObject {
    @Published private(set) var items: [KeyboardSnapshotItem] = []
    @Published private(set) var instruction = "Open the app to sync"
    @Published var selectedCategory: ClipCategory? {
        didSet { updateItems() }
    }

    @Published private(set) var query = ""

    private let loadSnapshot: () -> SnapshotLoadResult
    private let insertText: (String) -> Void
    private var snapshotItems: [KeyboardSnapshotItem] = []

    init(
        load: @escaping () -> SnapshotLoadResult = { KeyboardSnapshotReader().load() },
        insertText: @escaping (String) -> Void
    ) {
        loadSnapshot = load
        self.insertText = insertText
        selectedCategory = nil
    }

    func load() {
        switch loadSnapshot() {
        case let .available(snapshot):
            snapshotItems = snapshot.items
            instruction = freshnessText(for: snapshot)
        case let .refreshRecommended(snapshot):
            snapshotItems = snapshot.items
            instruction = "Refresh recommended"
        case .unavailable:
            snapshotItems = []
            instruction = "Open the app to sync"
        }
        updateItems()
    }

    func search(_ query: String) {
        self.query = query
        updateItems()
    }

    func insert(itemID: UUID) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        insertText(item.canonicalInsertionString)
    }

    func protectedDataWillBecomeUnavailable() {
        snapshotItems = []
        items = []
        query = ""
        selectedCategory = nil
        instruction = "Open the app to sync"
    }

    private func updateItems() {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        items = snapshotItems.filter { item in
            let categoryMatches = selectedCategory == nil || item.category == selectedCategory
            let queryMatches = normalizedQuery.isEmpty
                || item.title.localizedCaseInsensitiveContains(normalizedQuery)
                || item.canonicalInsertionString.localizedCaseInsensitiveContains(normalizedQuery)
            return categoryMatches && queryMatches
        }
    }

    private func freshnessText(for snapshot: KeyboardSnapshot) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Updated \(formatter.localizedString(for: snapshot.createdAt, relativeTo: Date()))"
    }
}
