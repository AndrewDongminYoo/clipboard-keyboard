import Foundation

public struct PendingMutationJournal: Codable, Equatable, Sendable {
    public private(set) var pending: [PinnedMutation]

    public init(pending: [PinnedMutation] = []) {
        self.pending = Self.canonicalized(pending)
    }

    public mutating func enqueue(_ mutation: PinnedMutation) {
        if let index = pending.firstIndex(where: { $0.mutationID == mutation.mutationID }) {
            if Self.canonicalBytes(of: pending[index]).lexicographicallyPrecedes(Self.canonicalBytes(of: mutation)) {
                pending[index] = mutation
                pending.sort(by: Self.precedes)
            }
            return
        }

        pending.append(mutation)
        pending.sort(by: Self.precedes)
    }

    public mutating func acknowledge(mutationID: UUID) {
        pending.removeAll { $0.mutationID == mutationID }
    }

    public mutating func acknowledge<S: Sequence>(mutationIDs: S) where S.Element == UUID {
        let acknowledged = Set(mutationIDs)
        pending.removeAll { acknowledged.contains($0.mutationID) }
    }

    public mutating func purge(staleBeforeLibraryGeneration generation: Int64) {
        pending.removeAll { $0.libraryGeneration < generation }
    }

    public mutating func replaceForRecovery(with state: PinnedReplicaState) {
        pending = Self.canonicalized(
            [state.reset.map(PinnedMutation.reset)].compactMap { $0 }
                + state.primaryRevisions.map(PinnedMutation.revision)
                + state.conflictCopies.map { PinnedMutation.revision($0.revision) }
                + state.tombstones.map(PinnedMutation.tombstone)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case pending
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pending = try Self.canonicalized(values.decode([PinnedMutation].self, forKey: .pending))
    }

    private static func canonicalized(_ mutations: [PinnedMutation]) -> [PinnedMutation] {
        var mutationsByID: [UUID: PinnedMutation] = [:]
        for mutation in mutations {
            guard let current = mutationsByID[mutation.mutationID] else {
                mutationsByID[mutation.mutationID] = mutation
                continue
            }
            if canonicalBytes(of: current).lexicographicallyPrecedes(canonicalBytes(of: mutation)) {
                mutationsByID[mutation.mutationID] = mutation
            }
        }
        return mutationsByID.values.sorted(by: precedes)
    }

    private static func precedes(_ lhs: PinnedMutation, _ rhs: PinnedMutation) -> Bool {
        if lhs.libraryGeneration != rhs.libraryGeneration {
            return lhs.libraryGeneration < rhs.libraryGeneration
        }
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt < rhs.modifiedAt
        }
        if lhs.deviceID != rhs.deviceID {
            return lhs.deviceID < rhs.deviceID
        }
        return lhs.mutationID.uuidString < rhs.mutationID.uuidString
    }

    private static func canonicalBytes(of mutation: PinnedMutation) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(mutation)) ?? Data()
    }
}
