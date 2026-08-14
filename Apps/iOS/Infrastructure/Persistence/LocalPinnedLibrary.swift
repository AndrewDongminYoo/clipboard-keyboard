import ClipboardCore
import Foundation

enum LocalPinnedLibraryError: Error, Equatable {
    case itemNotFound
    case invalidLimit
    case snapshotChanged
}

actor LocalPinnedLibrary: PinnedLibrary {
    private let store: EncryptedPhonePinnedStore
    private let lease: ProtectedDataLease
    private let deviceID: String
    private let now: @Sendable () -> Date
    private let beforeReturningSearch: @Sendable () async -> Void
    private let beforeReturningMutation: @Sendable () async -> Void
    private let beforeReturningSnapshot: @Sendable () async -> Void
    private var lifecycleEpoch: UInt64 = 0
    private var contentRevision: UInt64 = 0

    init(
        store: EncryptedPhonePinnedStore,
        lease: ProtectedDataLease,
        deviceID: String,
        now: @escaping @Sendable () -> Date = Date.init,
        beforeReturningSearch: @escaping @Sendable () async -> Void = {},
        beforeReturningMutation: @escaping @Sendable () async -> Void = {},
        beforeReturningSnapshot: @escaping @Sendable () async -> Void = {}
    ) {
        self.store = store
        self.lease = lease
        self.deviceID = deviceID
        self.now = now
        self.beforeReturningSearch = beforeReturningSearch
        self.beforeReturningMutation = beforeReturningMutation
        self.beforeReturningSnapshot = beforeReturningSnapshot
    }

    func allItems() async throws -> [PinnedRevision] {
        for _ in 0 ..< 3 {
            let lifecycle = lifecycleEpoch
            let revision = contentRevision
            let state = try await store.load()
            await beforeReturningSnapshot()
            try validateLifecycle(lifecycle)
            if revision == contentRevision {
                return state.primaryRevisions.sorted(by: newestFirst)
            }
        }
        throw LocalPinnedLibraryError.snapshotChanged
    }

    func items(category: ClipCategory?) async throws -> [PinnedRevision] {
        try await allItems().filter { $0.payload.category == category }
    }

    func search(_ query: String, limit: Int) async throws -> [PinnedRevision] {
        guard limit >= 0 else {
            throw LocalPinnedLibraryError.invalidLimit
        }
        for _ in 0 ..< 3 {
            let lifecycle = lifecycleEpoch
            let revision = contentRevision
            let state = try await store.load()
            let searchIndex = ClipSearchIndex()
            await searchIndex.replace(Self.searchDocuments(from: state))
            let results = await searchIndex.search(query, scope: .all, limit: limit)
            await beforeReturningSearch()
            try validateLifecycle(lifecycle)
            guard revision == contentRevision else { continue }
            let revisionsByID = Dictionary(uniqueKeysWithValues: state.primaryRevisions.map { ($0.itemID, $0) })
            return results.compactMap { revisionsByID[$0.document.id] }
        }
        throw LocalPinnedLibraryError.snapshotChanged
    }

    func pin(_ payload: PinPayload) async throws -> PinnedRevision {
        let lifecycle = lifecycleEpoch
        let itemID = UUID()
        let revisionID = UUID()
        let modifiedAt = now()
        let deviceID = deviceID
        let result = try await store.transaction { state in
            let revision = PinnedRevision(
                itemID: itemID,
                revisionID: revisionID,
                libraryGeneration: state.libraryGeneration,
                itemGeneration: 1,
                modifiedAt: modifiedAt,
                deviceID: deviceID,
                payload: payload
            )
            Self.applyLocal(.revision(revision), to: &state)
            return revision
        }
        await beforeReturningMutation()
        try validateLifecycle(lifecycle)
        contentRevision &+= 1
        return result
    }

    func revise(itemID: UUID, payload: PinPayload) async throws -> PinnedRevision {
        let lifecycle = lifecycleEpoch
        let revisionID = UUID()
        let modifiedAt = now()
        let deviceID = deviceID
        let result = try await store.transaction { state in
            guard let current = state.primaryRevisions.first(where: { $0.itemID == itemID }) else {
                throw LocalPinnedLibraryError.itemNotFound
            }
            let revision = PinnedRevision(
                itemID: itemID,
                revisionID: revisionID,
                libraryGeneration: state.libraryGeneration,
                itemGeneration: current.itemGeneration + 1,
                modifiedAt: modifiedAt,
                deviceID: deviceID,
                payload: payload
            )
            Self.applyLocal(.revision(revision), to: &state)
            return revision
        }
        await beforeReturningMutation()
        try validateLifecycle(lifecycle)
        contentRevision &+= 1
        return result
    }

    func delete(itemID: UUID) async throws -> PinnedTombstone {
        let lifecycle = lifecycleEpoch
        let tombstoneID = UUID()
        let modifiedAt = now()
        let deviceID = deviceID
        let result = try await store.transaction { state in
            guard let current = state.primaryRevisions.first(where: { $0.itemID == itemID }) else {
                throw LocalPinnedLibraryError.itemNotFound
            }
            let tombstone = PinnedTombstone(
                itemID: itemID,
                tombstoneID: tombstoneID,
                libraryGeneration: state.libraryGeneration,
                itemGeneration: current.itemGeneration + 1,
                modifiedAt: modifiedAt,
                deviceID: deviceID
            )
            Self.applyLocal(.tombstone(tombstone), to: &state)
            return tombstone
        }
        await beforeReturningMutation()
        try validateLifecycle(lifecycle)
        contentRevision &+= 1
        return result
    }

    func applyRemote(_ mutation: PinnedMutation) async throws -> MergeOutcome {
        let lifecycle = lifecycleEpoch
        let result = try await store.transaction { state in
            var replica = PinnedReplica(state: state)
            let outcome = replica.apply(mutation)
            state = replica.state
            if case let .tombstone(tombstone) = mutation, case .deleted = outcome {
                Self.scrubPendingContent(for: tombstone.itemID, from: &state)
            }
            return outcome
        }
        await beforeReturningMutation()
        try validateLifecycle(lifecycle)
        contentRevision &+= 1
        return result
    }

    func advanceResetGeneration() async throws -> LibraryResetGeneration {
        let lifecycle = lifecycleEpoch
        let resetID = UUID()
        let modifiedAt = now()
        let deviceID = deviceID
        let result = try await store.transaction { state in
            let reset = LibraryResetGeneration(
                resetID: resetID,
                generation: state.libraryGeneration + 1,
                modifiedAt: modifiedAt,
                deviceID: deviceID
            )
            Self.applyLocal(.reset(reset), to: &state)
            return reset
        }
        await beforeReturningMutation()
        try validateLifecycle(lifecycle)
        contentRevision &+= 1
        return result
    }

    func protectedDataWillBecomeUnavailable() async {
        lifecycleEpoch &+= 1
        lease.revoke()
        await store.protectedDataWillBecomeUnavailable()
    }

    func reopenProtectedData() async throws {
        let lifecycle = lifecycleEpoch
        try await store.reopen()
        _ = try await store.load()
        try validateLifecycle(lifecycle)
    }

    private static func applyLocal(_ mutation: PinnedMutation, to state: inout PinnedReplicaState) {
        var replica = PinnedReplica(state: state)
        _ = replica.apply(mutation)
        var journal = replica.state.pendingJournal
        if case let .tombstone(tombstone) = mutation {
            Self.scrubPendingContent(for: tombstone.itemID, from: &journal)
        }
        journal.enqueue(mutation)
        state = PinnedReplicaState(
            libraryGeneration: replica.state.libraryGeneration,
            reset: replica.state.reset,
            primaryRevisions: replica.state.primaryRevisions,
            conflictCopies: replica.state.conflictCopies,
            tombstones: replica.state.tombstones,
            seenMutationIDs: replica.state.seenMutationIDs,
            pendingJournal: journal
        )
    }

    private static func scrubPendingContent(for itemID: UUID, from state: inout PinnedReplicaState) {
        var journal = state.pendingJournal
        scrubPendingContent(for: itemID, from: &journal)
        state = PinnedReplicaState(
            libraryGeneration: state.libraryGeneration,
            reset: state.reset,
            primaryRevisions: state.primaryRevisions,
            conflictCopies: state.conflictCopies,
            tombstones: state.tombstones,
            seenMutationIDs: state.seenMutationIDs,
            pendingJournal: journal
        )
    }

    private static func scrubPendingContent(for itemID: UUID, from journal: inout PendingMutationJournal) {
        let mutationIDs = journal.pending.compactMap { mutation -> UUID? in
            switch mutation {
            case let .revision(revision) where revision.itemID == itemID:
                revision.revisionID
            case let .tombstone(tombstone) where tombstone.itemID == itemID:
                tombstone.tombstoneID
            case .revision, .tombstone, .reset:
                nil
            }
        }
        for mutationID in mutationIDs {
            journal.acknowledge(mutationID: mutationID)
        }
    }

    private static func searchDocuments(from state: PinnedReplicaState) -> [ClipSearchDocument] {
        state.primaryRevisions.map { revision in
            ClipSearchDocument(
                id: revision.itemID,
                capturedAt: revision.modifiedAt,
                title: revision.payload.title,
                canonicalInsertionString: revision.payload.canonicalInsertionString,
                category: revision.payload.category,
                contentKind: revision.payload.contentKind
            )
        }
    }

    private func newestFirst(_ lhs: PinnedRevision, _ rhs: PinnedRevision) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt
        }
        return lhs.itemID.uuidString < rhs.itemID.uuidString
    }

    private func validateLifecycle(_ lifecycle: UInt64) throws {
        guard lifecycle == lifecycleEpoch, lease.isActive else {
            throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
        }
    }
}
