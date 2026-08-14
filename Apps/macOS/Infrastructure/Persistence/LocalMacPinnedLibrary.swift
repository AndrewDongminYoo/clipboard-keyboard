import ClipboardCore
import Foundation

enum LocalMacPinnedLibraryError: Error, Equatable {
    case itemNotFound
    case invalidLimit
}

actor LocalMacPinnedLibrary: PinnedLibrary {
    private let store: EncryptedMacPinnedStore
    private let deviceID: String
    private let now: @Sendable () -> Date

    init(store: EncryptedMacPinnedStore, deviceID: String, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.deviceID = deviceID
        self.now = now
    }

    func allItems() async throws -> [PinnedRevision] {
        try await store.load().primaryRevisions.sorted(by: newestFirst)
    }

    func search(_ query: String, limit: Int) async throws -> [PinnedRevision] {
        guard limit >= 0 else { throw LocalMacPinnedLibraryError.invalidLimit }
        let normalized = normalize(query)
        return try await allItems()
            .filter { revision in
                normalized.isEmpty || [
                    revision.payload.title,
                    revision.payload.canonicalInsertionString,
                    revision.payload.category?.rawValue ?? "",
                ].contains { normalize($0).contains(normalized) }
            }
            .prefix(min(limit, 100))
            .map { $0 }
    }

    func pin(_ payload: PinPayload) async throws -> PinnedRevision {
        let state = try await store.load()
        let revision = PinnedRevision(
            itemID: UUID(),
            revisionID: UUID(),
            libraryGeneration: state.libraryGeneration,
            itemGeneration: 1,
            modifiedAt: now(),
            deviceID: deviceID,
            payload: payload
        )
        try await applyLocal(.revision(revision), to: state)
        return revision
    }

    func revise(itemID: UUID, payload: PinPayload) async throws -> PinnedRevision {
        let state = try await store.load()
        guard let current = state.primaryRevisions.first(where: { $0.itemID == itemID }) else {
            throw LocalMacPinnedLibraryError.itemNotFound
        }
        let revision = PinnedRevision(
            itemID: itemID,
            revisionID: UUID(),
            libraryGeneration: state.libraryGeneration,
            itemGeneration: current.itemGeneration + 1,
            modifiedAt: now(),
            deviceID: deviceID,
            payload: payload
        )
        try await applyLocal(.revision(revision), to: state)
        return revision
    }

    func delete(itemID: UUID) async throws -> PinnedTombstone {
        let state = try await store.load()
        guard let current = state.primaryRevisions.first(where: { $0.itemID == itemID }) else {
            throw LocalMacPinnedLibraryError.itemNotFound
        }
        let tombstone = PinnedTombstone(
            itemID: itemID,
            tombstoneID: UUID(),
            libraryGeneration: state.libraryGeneration,
            itemGeneration: current.itemGeneration + 1,
            modifiedAt: now(),
            deviceID: deviceID
        )
        try await applyLocal(.tombstone(tombstone), to: state)
        return tombstone
    }

    func applyRemote(_ mutation: PinnedMutation) async throws -> MergeOutcome {
        var replica = try PinnedReplica(state: await store.load())
        let outcome = replica.apply(mutation)
        try await store.save(replica.state)
        return outcome
    }

    func advanceResetGeneration() async throws -> LibraryResetGeneration {
        let state = try await store.load()
        let reset = LibraryResetGeneration(
            resetID: UUID(),
            generation: state.libraryGeneration + 1,
            modifiedAt: now(),
            deviceID: deviceID
        )
        try await applyLocal(.reset(reset), to: state)
        return reset
    }

    private func applyLocal(_ mutation: PinnedMutation, to state: PinnedReplicaState) async throws {
        var replica = PinnedReplica(state: state)
        _ = replica.apply(mutation)
        var journal = replica.state.pendingJournal
        journal.enqueue(mutation)
        let persisted = PinnedReplicaState(
            libraryGeneration: replica.state.libraryGeneration,
            reset: replica.state.reset,
            primaryRevisions: replica.state.primaryRevisions,
            conflictCopies: replica.state.conflictCopies,
            tombstones: replica.state.tombstones,
            seenMutationIDs: replica.state.seenMutationIDs,
            pendingJournal: journal
        )
        try await store.save(persisted)
    }

    private func normalize(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").lowercased()
    }

    private func newestFirst(_ lhs: PinnedRevision, _ rhs: PinnedRevision) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt
        }
        return lhs.itemID.uuidString < rhs.itemID.uuidString
    }
}
