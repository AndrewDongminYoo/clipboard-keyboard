import Foundation

public enum PinnedCloudStorageMode: Equatable, Sendable {
    case encryptedInline
    case encryptedAsset
}

public enum PinnedCloudDocument {
    public static let schemaVersion: Int64 = 1
    public static let zoneName = "PinnedLibrary"
    public static let maximumInlineByteCount = 524_288

    public enum RecordType: String, Codable, Sendable {
        case revision = "PinnedRevision"
        case tombstone = "PinnedTombstone"
        case reset = "LibraryReset"
    }

    public enum MutationKind: String, Codable, Sendable {
        case saveRevision
        case deleteItem
        case resetLibrary
    }

    public struct Metadata: Equatable, Sendable {
        public let recordType: RecordType
        public let mutationKind: MutationKind
        public let recordName: String
        public let libraryGeneration: Int64
        public let itemGeneration: Int64?

        public init(
            recordType: RecordType,
            mutationKind: MutationKind,
            recordName: String,
            libraryGeneration: Int64,
            itemGeneration: Int64?
        ) {
            self.recordType = recordType
            self.mutationKind = mutationKind
            self.recordName = recordName
            self.libraryGeneration = libraryGeneration
            self.itemGeneration = itemGeneration
        }
    }

    public static func metadata(for mutation: PinnedMutation) -> Metadata {
        switch mutation {
        case let .revision(revision):
            Metadata(
                recordType: .revision,
                mutationKind: .saveRevision,
                recordName: opaqueName(revision.revisionID),
                libraryGeneration: revision.libraryGeneration,
                itemGeneration: revision.itemGeneration
            )
        case let .tombstone(tombstone):
            Metadata(
                recordType: .tombstone,
                mutationKind: .deleteItem,
                recordName: opaqueName(tombstone.tombstoneID),
                libraryGeneration: tombstone.libraryGeneration,
                itemGeneration: tombstone.itemGeneration
            )
        case let .reset(reset):
            Metadata(
                recordType: .reset,
                mutationKind: .resetLibrary,
                recordName: opaqueName(reset.resetID),
                libraryGeneration: reset.generation,
                itemGeneration: nil
            )
        }
    }

    public static func payload(for mutation: PinnedMutation) -> Data? {
        guard case .revision = mutation else { return nil }
        return try? encodePayload(for: mutation)
    }

    public static func encryptedMetadata(for mutation: PinnedMutation) throws -> Data {
        try encodePayload(for: mutation)
    }

    public static func encodePayload(for mutation: PinnedMutation) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(mutation)
    }

    public static func decodePayload(_ data: Data) throws -> PinnedMutation {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(PinnedMutation.self, from: data)
    }

    public static func storageMode(forSerializedByteCount byteCount: Int) -> PinnedCloudStorageMode {
        byteCount <= maximumInlineByteCount ? .encryptedInline : .encryptedAsset
    }

    private static func opaqueName(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}
