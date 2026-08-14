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
    private let notifier: @Sendable () async -> Void

    init(
        store: EncryptedMacPinnedStore,
        deviceID: String,
        now: @escaping @Sendable () -> Date = Date.init,
        notifier: @escaping @Sendable () async -> Void = {}
    ) {
        self.store = store
        self.deviceID = deviceID
        self.now = now
        self.notifier = notifier
    }

    func allItems() async throws -> [PinnedRevision] {
        let state = try await store.load()
        return Self.visibleRevisions(from: state).sorted(by: newestFirst)
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
        let itemID = UUID()
        let revisionID = UUID()
        let modifiedAt = now()
        let deviceID = deviceID
        let revision = try await store.transaction { state in
            let revision = PinnedRevision(
                itemID: itemID, revisionID: revisionID, libraryGeneration: state.libraryGeneration,
                itemGeneration: 1, modifiedAt: modifiedAt, deviceID: deviceID, payload: payload
            )
            Self.applyLocal(.revision(revision), to: &state)
            return revision
        }
        await notifier()
        return revision
    }

    func revise(itemID: UUID, payload: PinPayload) async throws -> PinnedRevision {
        let revisionID = UUID()
        let modifiedAt = now()
        let deviceID = deviceID
        let revision = try await store.transaction { state in
            guard let current = Self.visibleRevisions(from: state).first(where: { $0.itemID == itemID }) else {
                throw LocalMacPinnedLibraryError.itemNotFound
            }
            let revision = PinnedRevision(
                itemID: itemID, revisionID: revisionID, libraryGeneration: state.libraryGeneration,
                itemGeneration: current.itemGeneration + 1, modifiedAt: modifiedAt, deviceID: deviceID, payload: payload
            )
            Self.applyLocal(.revision(revision), to: &state)
            return revision
        }
        await notifier()
        return revision
    }

    func delete(itemID: UUID) async throws -> PinnedTombstone {
        let tombstoneID = UUID()
        let modifiedAt = now()
        let deviceID = deviceID
        let tombstone = try await store.transaction { state in
            guard let current = Self.visibleRevisions(from: state).first(where: { $0.itemID == itemID }) else {
                throw LocalMacPinnedLibraryError.itemNotFound
            }
            let tombstone = PinnedTombstone(
                itemID: itemID, tombstoneID: tombstoneID, libraryGeneration: state.libraryGeneration,
                itemGeneration: current.itemGeneration + 1, modifiedAt: modifiedAt, deviceID: deviceID
            )
            Self.applyLocal(.tombstone(tombstone), to: &state)
            return tombstone
        }
        await notifier()
        return tombstone
    }

    func applyRemote(_ mutation: PinnedMutation) async throws -> MergeOutcome {
        try await store.transaction { state in
            let contentItemIDs = Self.contentItemIDs(for: mutation, in: state)
            var replica = PinnedReplica(state: state)
            let outcome = replica.apply(mutation)
            state = replica.state
            if case .deleted = outcome {
                Self.scrubPendingContent(for: contentItemIDs, from: &state)
            }
            return outcome
        }
    }

    func advanceResetGeneration() async throws -> LibraryResetGeneration {
        let resetID = UUID()
        let modifiedAt = now()
        let deviceID = deviceID
        let reset = try await store.transaction { state in
            let reset = LibraryResetGeneration(
                resetID: resetID, generation: state.libraryGeneration + 1,
                modifiedAt: modifiedAt, deviceID: deviceID
            )
            Self.applyLocal(.reset(reset), to: &state)
            return reset
        }
        await notifier()
        return reset
    }

    private static func applyLocal(_ mutation: PinnedMutation, to state: inout PinnedReplicaState) {
        let contentItemIDs = contentItemIDs(for: mutation, in: state)
        var replica = PinnedReplica(state: state)
        _ = replica.apply(mutation)
        var journal = replica.state.pendingJournal
        if case .tombstone = mutation {
            scrubPendingContent(for: contentItemIDs, from: &journal)
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

    private static func visibleRevisions(from state: PinnedReplicaState) -> [PinnedRevision] {
        state.primaryRevisions + state.conflictCopies.map(\.revision)
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
