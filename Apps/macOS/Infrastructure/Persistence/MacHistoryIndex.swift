import ClipboardCore
import Foundation

protocol MacHistorySearchOperating: Sendable {
    func search(
        documents: [ClipSearchDocument],
        query: String,
        scope: SearchScope,
        limit: Int
    ) async -> [ClipSearchResult]
}

struct ClipSearchOperation: MacHistorySearchOperating {
    func search(
        documents: [ClipSearchDocument],
        query: String,
        scope: SearchScope,
        limit: Int
    ) async -> [ClipSearchResult] {
        let index = ClipSearchIndex()
        await index.replace(documents)
        return await index.search(query, scope: scope, limit: limit)
    }
}

actor MacHistoryIndex {
    private var documents: [UUID: ClipSearchDocument] = [:]
    private var generation: UInt = 0
    private let searchOperation: any MacHistorySearchOperating

    init(searchOperation: any MacHistorySearchOperating = ClipSearchOperation()) {
        self.searchOperation = searchOperation
    }

    func unlock(from store: EncryptedMacClipStore, now: Date = Date()) async throws {
        generation &+= 1
        let unlockGeneration = generation
        documents.removeAll(keepingCapacity: false)

        _ = try await store.applyRetention(now: now)
        guard unlockGeneration == generation else { return }
        let metadata = try await store.listMetadata()
        guard unlockGeneration == generation else { return }

        var unlockedDocuments: [UUID: ClipSearchDocument] = [:]
        for item in metadata {
            guard unlockGeneration == generation else { return }
            guard let envelope = try await store.load(id: item.id) else { continue }
            guard unlockGeneration == generation else { return }
            unlockedDocuments[envelope.id] = ClipSearchDocument(
                id: envelope.id,
                capturedAt: envelope.capturedAt,
                title: envelope.title,
                canonicalInsertionString: envelope.canonicalInsertionString,
                category: envelope.category,
                contentKind: envelope.contentKind
            )
        }
        guard unlockGeneration == generation else { return }
        documents = unlockedDocuments
    }

    func search(_ query: String, scope: SearchScope = .all, limit: Int = 100) async -> [ClipSearchResult] {
        let searchGeneration = generation
        let snapshot = Array(documents.values)
        let results = await searchOperation.search(documents: snapshot, query: query, scope: scope, limit: limit)
        guard searchGeneration == generation else { return [] }
        return results
    }

    func remove(ids: Set<UUID>) {
        generation &+= 1
        for id in ids {
            documents.removeValue(forKey: id)
        }
    }

    func lock() {
        generation &+= 1
        documents.removeAll(keepingCapacity: false)
    }
}
