import Foundation

public struct RetentionPolicy: Hashable, Codable, Sendable {
    public let maxAge: TimeInterval
    public let maxUnpinnedCount: Int
    public let historyEnabled: Bool

    public init(maxAge: TimeInterval, maxUnpinnedCount: Int, historyEnabled: Bool) {
        self.maxAge = maxAge
        self.maxUnpinnedCount = maxUnpinnedCount
        self.historyEnabled = historyEnabled
    }

    public func evictionIDs(for records: [ClipMetadata], now: Date) -> Set<UUID> {
        let unpinnedRecords = records.filter { !$0.isPinned }
        guard historyEnabled else {
            return Set(unpinnedRecords.map(\.id))
        }

        let expiredIDs = unpinnedRecords
            .filter { now.timeIntervalSince($0.capturedAt) > maxAge }
            .map(\.id)
        let retainedByAge = unpinnedRecords.filter { !expiredIDs.contains($0.id) }
        let countEvictedIDs = retainedByAge
            .sorted { lhs, rhs in
                if lhs.capturedAt != rhs.capturedAt {
                    return lhs.capturedAt < rhs.capturedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(max(0, retainedByAge.count - maxUnpinnedCount))
            .map(\.id)

        return Set(expiredIDs).union(countEvictedIDs)
    }
}
