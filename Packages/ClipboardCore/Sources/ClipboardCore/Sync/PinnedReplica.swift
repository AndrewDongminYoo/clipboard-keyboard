import Foundation

public struct PinnedReplicaState: Codable, Equatable, Sendable {
    public private(set) var libraryGeneration: Int64
    public private(set) var reset: LibraryResetGeneration?
    public private(set) var primaryRevisions: [PinnedRevision]
    public private(set) var conflictCopies: [PinnedConflictCopy]
    public private(set) var tombstones: [PinnedTombstone]
    public private(set) var seenMutationIDs: [UUID]
    public private(set) var pendingJournal: PendingMutationJournal

    public init(
        libraryGeneration: Int64 = 0,
        reset: LibraryResetGeneration? = nil,
        primaryRevisions: [PinnedRevision] = [],
        conflictCopies: [PinnedConflictCopy] = [],
        tombstones: [PinnedTombstone] = [],
        seenMutationIDs: [UUID] = [],
        pendingJournal: PendingMutationJournal = PendingMutationJournal()
    ) {
        self.libraryGeneration = libraryGeneration
        self.reset = reset
        self.primaryRevisions = primaryRevisions
        self.conflictCopies = conflictCopies
        self.tombstones = tombstones
        self.seenMutationIDs = seenMutationIDs
        self.pendingJournal = pendingJournal
        normalize()
    }

    mutating func advance(to generation: Int64) {
        libraryGeneration = generation
        reset = nil
        primaryRevisions.removeAll()
        conflictCopies.removeAll()
        tombstones.removeAll()
        pendingJournal.purge(staleBeforeLibraryGeneration: generation)
    }

    mutating func record(reset newReset: LibraryResetGeneration) {
        reset = newReset
    }

    mutating func markSeen(_ mutationID: UUID) {
        guard !seenMutationIDs.contains(mutationID) else {
            return
        }
        seenMutationIDs.append(mutationID)
        seenMutationIDs.sort { $0.uuidString < $1.uuidString }
    }

    func hasSeen(_ mutationID: UUID) -> Bool {
        seenMutationIDs.contains(mutationID)
    }

    func primary(for itemID: UUID) -> PinnedRevision? {
        primaryRevisions.first { $0.itemID == itemID }
    }

    func tombstone(for itemID: UUID) -> PinnedTombstone? {
        tombstones.first { $0.itemID == itemID }
    }

    mutating func replacePrimary(with revision: PinnedRevision, clearConflicts: Bool) {
        primaryRevisions.removeAll { $0.itemID == revision.itemID }
        primaryRevisions.append(revision)
        primaryRevisions.sort(by: primaryPrecedes)
        tombstones.removeAll { $0.itemID == revision.itemID }
        if clearConflicts {
            conflictCopies.removeAll {
                $0.sourceItemID == revision.itemID || $0.revision.itemID == revision.itemID
            }
        }
    }

    mutating func addConflict(_ revision: PinnedRevision) {
        guard !conflictCopies.contains(where: { $0.revision.revisionID == revision.revisionID }) else {
            return
        }
        conflictCopies.append(PinnedConflictCopy(revision: revision))
        conflictCopies.sort(by: conflictPrecedes)
    }

    mutating func apply(tombstone: PinnedTombstone) {
        primaryRevisions.removeAll { $0.itemID == tombstone.itemID }
        conflictCopies.removeAll {
            $0.sourceItemID == tombstone.itemID || $0.revision.itemID == tombstone.itemID
        }
        tombstones.removeAll { $0.itemID == tombstone.itemID }
        tombstones.append(tombstone)
        tombstones.sort(by: tombstonePrecedes)
    }

    private enum CodingKeys: String, CodingKey {
        case libraryGeneration
        case reset
        case primaryRevisions
        case conflictCopies
        case tombstones
        case seenMutationIDs
        case pendingJournal
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            libraryGeneration: values.decode(Int64.self, forKey: .libraryGeneration),
            reset: values.decodeIfPresent(LibraryResetGeneration.self, forKey: .reset),
            primaryRevisions: values.decode([PinnedRevision].self, forKey: .primaryRevisions),
            conflictCopies: values.decode([PinnedConflictCopy].self, forKey: .conflictCopies),
            tombstones: values.decode([PinnedTombstone].self, forKey: .tombstones),
            seenMutationIDs: values.decode([UUID].self, forKey: .seenMutationIDs),
            pendingJournal: values.decodeIfPresent(PendingMutationJournal.self, forKey: .pendingJournal)
                ?? PendingMutationJournal()
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(libraryGeneration, forKey: .libraryGeneration)
        try values.encodeIfPresent(reset, forKey: .reset)
        try values.encode(primaryRevisions, forKey: .primaryRevisions)
        try values.encode(conflictCopies, forKey: .conflictCopies)
        try values.encode(tombstones, forKey: .tombstones)
        try values.encode(seenMutationIDs, forKey: .seenMutationIDs)
        try values.encode(pendingJournal, forKey: .pendingJournal)
    }

    private mutating func normalize() {
        let suppliedPrimaryRevisions = primaryRevisions
        let suppliedConflictCopies = conflictCopies
        let suppliedRevisions = suppliedPrimaryRevisions + suppliedConflictCopies.map(\.revision)
        let suppliedMutationIDs = suppliedRevisions.map(\.revisionID)
            + tombstones.map(\.tombstoneID)
            + [reset?.resetID].compactMap { $0 }
        seenMutationIDs = Array(Set(seenMutationIDs + suppliedMutationIDs)).sorted { $0.uuidString < $1.uuidString }
        pendingJournal = PendingMutationJournal(pending: pendingJournal.pending)

        let suppliedGenerations = [libraryGeneration]
            + suppliedRevisions.map(\.libraryGeneration)
            + tombstones.map(\.libraryGeneration)
            + [reset?.generation].compactMap { $0 }
        libraryGeneration = suppliedGenerations.max() ?? libraryGeneration
        pendingJournal.purge(staleBeforeLibraryGeneration: libraryGeneration)
        if reset?.generation != libraryGeneration {
            reset = nil
        }

        let currentRevisions = suppliedPrimaryRevisions.filter { $0.libraryGeneration == libraryGeneration }
        let currentConflicts = suppliedConflictCopies.filter { $0.revision.libraryGeneration == libraryGeneration }
        let currentTombstones = tombstones.filter { $0.libraryGeneration == libraryGeneration }
        let revisionsByID = currentRevisions.reduce(into: [UUID: PinnedRevision]()) { result, revision in
            guard let current = result[revision.revisionID] else {
                result[revision.revisionID] = revision
                return
            }
            if canonicalBytes(of: current).lexicographicallyPrecedes(canonicalBytes(of: revision)) {
                result[revision.revisionID] = revision
            }
        }
        let revisionsByItem = Dictionary(grouping: revisionsByID.values, by: \.itemID)
        let latestTombstones = Self.latestTombstones(from: currentTombstones)
        let tombstoneByItem = Dictionary(uniqueKeysWithValues: latestTombstones.map { ($0.itemID, $0) })

        var normalizedPrimaries: [PinnedRevision] = []
        var normalizedConflictsByRevisionID: [UUID: PinnedConflictCopy] = [:]
        var survivingTombstones = tombstoneByItem

        for itemID in revisionsByItem.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let revisions = revisionsByItem[itemID],
                  let maximumItemGeneration = revisions.map(\.itemGeneration).max()
            else {
                continue
            }
            let concurrent = revisions
                .filter { $0.itemGeneration == maximumItemGeneration }
                .sorted(by: revisionPrecedes)
            guard let primary = concurrent.last else {
                continue
            }
            if let tombstone = tombstoneByItem[itemID], tombstone.itemGeneration >= primary.itemGeneration {
                continue
            }
            survivingTombstones.removeValue(forKey: itemID)
            normalizedPrimaries.append(primary)
            for conflict in concurrent.dropLast().map(PinnedConflictCopy.init) {
                normalizedConflictsByRevisionID[conflict.revision.revisionID] = conflict
            }
        }

        for conflict in currentConflicts {
            if let sourceTombstone = tombstoneByItem[conflict.sourceItemID],
               sourceTombstone.itemGeneration >= conflict.revision.itemGeneration
            {
                continue
            }
            if let projectedTombstone = tombstoneByItem[conflict.revision.itemID],
               projectedTombstone.itemGeneration >= conflict.revision.itemGeneration
            {
                continue
            }
            if let sourcePrimary = normalizedPrimaries.first(where: { $0.itemID == conflict.sourceItemID }),
               sourcePrimary.itemGeneration > conflict.revision.itemGeneration
            {
                continue
            }
            if normalizedPrimaries.contains(where: { $0.itemID == conflict.revision.itemID }) {
                continue
            }
            guard let current = normalizedConflictsByRevisionID[conflict.revision.revisionID] else {
                normalizedConflictsByRevisionID[conflict.revision.revisionID] = conflict
                continue
            }
            if canonicalBytes(of: current.revision).lexicographicallyPrecedes(canonicalBytes(of: conflict.revision)) {
                normalizedConflictsByRevisionID[conflict.revision.revisionID] = conflict
            }
        }

        primaryRevisions = normalizedPrimaries.sorted(by: primaryPrecedes)
        conflictCopies = normalizedConflictsByRevisionID.values.sorted(by: conflictPrecedes)
        tombstones = survivingTombstones.values.sorted(by: tombstonePrecedes)
    }

    private static func latestTombstones(from tombstones: [PinnedTombstone]) -> [PinnedTombstone] {
        let tombstonesByID = tombstones.reduce(into: [UUID: PinnedTombstone]()) { result, tombstone in
            guard let current = result[tombstone.tombstoneID] else {
                result[tombstone.tombstoneID] = tombstone
                return
            }
            if canonicalBytes(of: current).lexicographicallyPrecedes(canonicalBytes(of: tombstone)) {
                result[tombstone.tombstoneID] = tombstone
            }
        }
        return Dictionary(grouping: tombstonesByID.values, by: \.itemID)
            .values
            .compactMap { values in
                guard let maximumItemGeneration = values.map(\.itemGeneration).max() else {
                    return nil
                }
                return values
                    .filter { $0.itemGeneration == maximumItemGeneration }
                    .sorted(by: tombstonePrecedes)
                    .last
            }
            .sorted(by: tombstonePrecedes)
    }
}

public struct PinnedReplica: Sendable {
    public private(set) var state: PinnedReplicaState

    public init(state: PinnedReplicaState = PinnedReplicaState()) {
        self.state = state
    }

    @discardableResult
    public mutating func apply(_ mutation: PinnedMutation) -> MergeOutcome {
        if state.hasSeen(mutation.mutationID) {
            return .ignoredDuplicate
        }

        state.markSeen(mutation.mutationID)

        guard mutation.libraryGeneration >= state.libraryGeneration else {
            return .ignoredStaleGeneration
        }

        if mutation.libraryGeneration > state.libraryGeneration {
            state.advance(to: mutation.libraryGeneration)
        }

        switch mutation {
        case let .revision(revision):
            return apply(revision)
        case let .tombstone(tombstone):
            return apply(tombstone)
        case let .reset(reset):
            if let current = state.reset {
                guard resetPrecedes(current, reset) else {
                    return .ignoredStaleGeneration
                }
            }
            state.record(reset: reset)
            return .deleted(reset.resetID)
        }
    }

    private mutating func apply(_ revision: PinnedRevision) -> MergeOutcome {
        if let tombstone = state.tombstone(for: revision.itemID),
           tombstone.itemGeneration >= revision.itemGeneration
        {
            return .ignoredStaleGeneration
        }

        guard let current = state.primary(for: revision.itemID) else {
            state.replacePrimary(with: revision, clearConflicts: true)
            return .inserted(revision.itemID)
        }

        if revision.itemGeneration < current.itemGeneration {
            return .ignoredStaleGeneration
        }

        if revision.itemGeneration > current.itemGeneration {
            state.replacePrimary(with: revision, clearConflicts: true)
            return .updated(revision.itemID)
        }

        let primary: PinnedRevision
        let copy: PinnedRevision
        if revisionPrecedes(current, revision) {
            primary = revision
            copy = current
            state.replacePrimary(with: revision, clearConflicts: false)
        } else {
            primary = current
            copy = revision
        }
        state.addConflict(copy)
        return .conflict(primary: primary.revisionID, copy: copy.revisionID)
    }

    private mutating func apply(_ tombstone: PinnedTombstone) -> MergeOutcome {
        let contentGeneration = max(
            state.primary(for: tombstone.itemID)?.itemGeneration ?? Int64.min,
            state.conflictCopies
                .filter { $0.sourceItemID == tombstone.itemID || $0.revision.itemID == tombstone.itemID }
                .map(\.revision.itemGeneration)
                .max() ?? Int64.min
        )
        if tombstone.itemGeneration < contentGeneration {
            return .ignoredStaleGeneration
        }

        if let current = state.tombstone(for: tombstone.itemID) {
            if tombstone.itemGeneration < current.itemGeneration {
                return .ignoredStaleGeneration
            }
            if tombstone.itemGeneration == current.itemGeneration,
               tombstonePrecedes(tombstone, current)
            {
                return .deleted(tombstone.itemID)
            }
        }

        state.apply(tombstone: tombstone)
        return .deleted(tombstone.itemID)
    }
}

private func revisionPrecedes(_ lhs: PinnedRevision, _ rhs: PinnedRevision) -> Bool {
    if lhs.modifiedAt != rhs.modifiedAt {
        return lhs.modifiedAt < rhs.modifiedAt
    }
    if lhs.deviceID != rhs.deviceID {
        return lhs.deviceID < rhs.deviceID
    }
    return lhs.revisionID.uuidString < rhs.revisionID.uuidString
}

private func primaryPrecedes(_ lhs: PinnedRevision, _ rhs: PinnedRevision) -> Bool {
    if lhs.itemID != rhs.itemID {
        return lhs.itemID.uuidString < rhs.itemID.uuidString
    }
    return revisionPrecedes(lhs, rhs)
}

private func conflictPrecedes(_ lhs: PinnedConflictCopy, _ rhs: PinnedConflictCopy) -> Bool {
    primaryPrecedes(lhs.revision, rhs.revision)
}

private func tombstonePrecedes(_ lhs: PinnedTombstone, _ rhs: PinnedTombstone) -> Bool {
    if lhs.itemID != rhs.itemID {
        return lhs.itemID.uuidString < rhs.itemID.uuidString
    }
    if lhs.modifiedAt != rhs.modifiedAt {
        return lhs.modifiedAt < rhs.modifiedAt
    }
    if lhs.deviceID != rhs.deviceID {
        return lhs.deviceID < rhs.deviceID
    }
    return lhs.tombstoneID.uuidString < rhs.tombstoneID.uuidString
}

private func resetPrecedes(_ lhs: LibraryResetGeneration, _ rhs: LibraryResetGeneration) -> Bool {
    if lhs.generation != rhs.generation {
        return lhs.generation < rhs.generation
    }
    if lhs.modifiedAt != rhs.modifiedAt {
        return lhs.modifiedAt < rhs.modifiedAt
    }
    if lhs.deviceID != rhs.deviceID {
        return lhs.deviceID < rhs.deviceID
    }
    return lhs.resetID.uuidString < rhs.resetID.uuidString
}

private func canonicalBytes(of value: some Encodable) -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(value)) ?? Data()
}
