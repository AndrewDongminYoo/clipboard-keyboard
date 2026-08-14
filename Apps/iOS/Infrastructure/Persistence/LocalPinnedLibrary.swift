import ClipboardCore
import Foundation

enum LocalPinnedLibraryError: Error, Equatable {
    case itemNotFound
    case invalidLimit
    case snapshotChanged
}

enum SharePinEnsureResult: Equatable, Sendable {
    case inserted(PinnedRevision)
    case alreadyPresent
    case conflict
}

protocol ShareFixedIDPinnedLibrary: PinnedLibrary {
    func ensurePinned(payload: PinPayload, itemID: UUID) async throws -> SharePinEnsureResult
}

struct IntentPinCommit: Equatable, Sendable {
    let libraryGeneration: Int64
}

protocol IntentPinCommittingLibrary: Sendable {
    func pinForIntent(_ payload: PinPayload) async throws -> IntentPinCommit
}

actor LocalPinnedLibrary: ShareFixedIDPinnedLibrary, IntentPinCommittingLibrary {
    private let store: EncryptedPhonePinnedStore
    private let lease: ProtectedDataLease
    private let deviceID: String
    private let now: @Sendable () -> Date
    private let beforeReturningSearch: @Sendable () async -> Void
    private let beforeReturningMutation: @Sendable () async -> Void
    private let beforeReturningSnapshot: @Sendable () async -> Void
    private let beforeEnsurePinnedTransaction: @Sendable () async -> Void
    private var lifecycleEpoch: UInt64 = 0
    private var contentRevision: UInt64 = 0

    init(
        store: EncryptedPhonePinnedStore,
        lease: ProtectedDataLease,
        deviceID: String,
        now: @escaping @Sendable () -> Date = Date.init,
        beforeReturningSearch: @escaping @Sendable () async -> Void = {},
        beforeReturningMutation: @escaping @Sendable () async -> Void = {},
        beforeReturningSnapshot: @escaping @Sendable () async -> Void = {},
        beforeEnsurePinnedTransaction: @escaping @Sendable () async -> Void = {}
    ) {
        self.store = store
        self.lease = lease
        self.deviceID = deviceID
        self.now = now
        self.beforeReturningSearch = beforeReturningSearch
        self.beforeReturningMutation = beforeReturningMutation
        self.beforeReturningSnapshot = beforeReturningSnapshot
        self.beforeEnsurePinnedTransaction = beforeEnsurePinnedTransaction
    }

    func allItems() async throws -> [PinnedRevision] {
        for _ in 0 ..< 3 {
            let lifecycle = lifecycleEpoch
            let revision = contentRevision
            let state = try await store.load()
            await beforeReturningSnapshot()
            try validateLifecycle(lifecycle)
            if revision == contentRevision {
                return Self.visibleRevisions(from: state).sorted(by: newestFirst)
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
            let revisionsByID = Dictionary(uniqueKeysWithValues: Self.visibleRevisions(from: state).map { ($0.itemID, $0) })
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

    func pinForIntent(_ payload: PinPayload) async throws -> IntentPinCommit {
        try Task.checkCancellation()
        let itemID = UUID()
        let revisionID = UUID()
        let modifiedAt = now()
        let deviceID = deviceID
        let result = try await store.transaction { state in
            try Task.checkCancellation()
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
            return IntentPinCommit(libraryGeneration: revision.libraryGeneration)
        }
        contentRevision &+= 1
        await beforeReturningMutation()
        return result
    }

    func ensurePinned(payload: PinPayload, itemID: UUID) async throws -> SharePinEnsureResult {
        try Task.checkCancellation()
        await beforeEnsurePinnedTransaction()
        try Task.checkCancellation()
        let lifecycle = lifecycleEpoch
        let revisionID = UUID()
        let modifiedAt = now()
        let deviceID = deviceID
        let result = try await store.transaction { state in
            try Task.checkCancellation()
            if state.tombstones.contains(where: { $0.itemID == itemID }) ||
                state.conflictCopies.contains(where: { $0.sourceItemID == itemID || $0.revision.itemID == itemID })
            {
                return SharePinEnsureResult.conflict
            }
            if let existing = state.primaryRevisions.first(where: { $0.itemID == itemID }) {
                return existing.payload == payload ? .alreadyPresent : .conflict
            }
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
            return .inserted(revision)
        }
        await beforeReturningMutation()
        try validateLifecycle(lifecycle)
        if case .inserted = result {
            contentRevision &+= 1
        }
        return result
    }

    func revise(itemID: UUID, payload: PinPayload) async throws -> PinnedRevision {
        let lifecycle = lifecycleEpoch
        let revisionID = UUID()
        let modifiedAt = now()
        let deviceID = deviceID
        let result = try await store.transaction { state in
            guard let current = Self.visibleRevisions(from: state).first(where: { $0.itemID == itemID }) else {
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
            guard let current = Self.visibleRevisions(from: state).first(where: { $0.itemID == itemID }) else {
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
            let contentItemIDs = Self.contentItemIDs(for: mutation, in: state)
            var replica = PinnedReplica(state: state)
            let outcome = replica.apply(mutation)
            state = replica.state
            if case .deleted = outcome {
                Self.scrubPendingContent(for: contentItemIDs, from: &state)
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
        let contentItemIDs = contentItemIDs(for: mutation, in: state)
        var replica = PinnedReplica(state: state)
        _ = replica.apply(mutation)
        var journal = replica.state.pendingJournal
        if case .tombstone = mutation {
            Self.scrubPendingContent(for: contentItemIDs, from: &journal)
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

    private static func scrubPendingContent(for itemIDs: Set<UUID>, from state: inout PinnedReplicaState) {
        var journal = state.pendingJournal
        scrubPendingContent(for: itemIDs, from: &journal)
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

    private static func scrubPendingContent(for itemIDs: Set<UUID>, from journal: inout PendingMutationJournal) {
        let mutationIDs = journal.pending.compactMap { mutation -> UUID? in
            switch mutation {
            case let .revision(revision) where itemIDs.contains(revision.itemID):
                revision.revisionID
            case let .tombstone(tombstone) where itemIDs.contains(tombstone.itemID):
                tombstone.tombstoneID
            case .revision, .tombstone, .reset:
                nil
            }
        }
        journal.acknowledge(mutationIDs: mutationIDs)
    }

    private static func contentItemIDs(for mutation: PinnedMutation, in state: PinnedReplicaState) -> Set<UUID> {
        guard case let .tombstone(tombstone) = mutation else {
            return []
        }
        return Set(
            [tombstone.itemID]
                + state.conflictCopies
                .filter { $0.sourceItemID == tombstone.itemID || $0.revision.itemID == tombstone.itemID }
                .map(\.revision.itemID)
        )
    }

    private static func visibleRevisions(from state: PinnedReplicaState) -> [PinnedRevision] {
        state.primaryRevisions + state.conflictCopies.map(\.revision)
    }

    private static func searchDocuments(from state: PinnedReplicaState) -> [ClipSearchDocument] {
        visibleRevisions(from: state).map { revision in
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
