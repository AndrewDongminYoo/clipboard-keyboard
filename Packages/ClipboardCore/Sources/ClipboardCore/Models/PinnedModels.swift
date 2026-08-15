import Foundation

public enum PinPayloadError: Error, Equatable {
    case emptyKeyedDigest
}

public struct PinPayload: Codable, Equatable, Sendable {
    public let representations: [ClipRepresentation]
    public let canonicalInsertionString: String
    public let title: String
    public let contentKind: ContentKind
    public let category: ClipCategory?

    public init(
        representations: [ClipRepresentation],
        canonicalInsertionString: String,
        title: String,
        contentKind: ContentKind,
        category: ClipCategory?
    ) {
        self.representations = representations
        self.canonicalInsertionString = canonicalInsertionString
        self.title = title
        self.contentKind = contentKind
        self.category = category
    }

    public init(envelope: ClipEnvelope, title: String, category: ClipCategory?) {
        self.init(
            representations: envelope.representations,
            canonicalInsertionString: envelope.canonicalInsertionString,
            title: title,
            contentKind: envelope.contentKind,
            category: category
        )
    }

    public init(
        candidate: ValueCandidate,
        keyedDigest: Data,
        title: String,
        category: ClipCategory?
    ) throws {
        guard !keyedDigest.isEmpty else {
            throw PinPayloadError.emptyKeyedDigest
        }

        let bytes = Data(candidate.original.utf8)
        self.init(
            representations: [
                ClipRepresentation(kind: .plainText, originalBytes: bytes, keyedDigest: keyedDigest),
            ],
            canonicalInsertionString: candidate.original,
            title: title,
            contentKind: .plainText,
            category: category
        )
    }
}

public struct PinnedRevision: Codable, Equatable, Sendable {
    public let itemID: UUID
    public let revisionID: UUID
    public let libraryGeneration: Int64
    public let itemGeneration: Int64
    public let modifiedAt: Date
    public let deviceID: String
    public let payload: PinPayload
    public let syncState: SyncState?

    public init(
        itemID: UUID,
        revisionID: UUID,
        libraryGeneration: Int64,
        itemGeneration: Int64,
        modifiedAt: Date,
        deviceID: String,
        payload: PinPayload,
        syncState: SyncState? = nil
    ) {
        self.itemID = itemID
        self.revisionID = revisionID
        self.libraryGeneration = libraryGeneration
        self.itemGeneration = itemGeneration
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
        self.payload = payload
        self.syncState = syncState
    }
}

public struct PinnedTombstone: Codable, Equatable, Sendable {
    public let itemID: UUID
    public let tombstoneID: UUID
    public let libraryGeneration: Int64
    public let itemGeneration: Int64
    public let modifiedAt: Date
    public let deviceID: String

    public init(
        itemID: UUID,
        tombstoneID: UUID,
        libraryGeneration: Int64,
        itemGeneration: Int64,
        modifiedAt: Date,
        deviceID: String
    ) {
        self.itemID = itemID
        self.tombstoneID = tombstoneID
        self.libraryGeneration = libraryGeneration
        self.itemGeneration = itemGeneration
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
    }
}

public struct LibraryResetGeneration: Codable, Equatable, Sendable {
    public let resetID: UUID
    public let generation: Int64
    public let modifiedAt: Date
    public let deviceID: String

    public init(resetID: UUID, generation: Int64, modifiedAt: Date, deviceID: String) {
        self.resetID = resetID
        self.generation = generation
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
    }
}

public enum PinnedMutation: Codable, Equatable, Sendable {
    case revision(PinnedRevision)
    case tombstone(PinnedTombstone)
    case reset(LibraryResetGeneration)

    public var mutationID: UUID {
        switch self {
        case let .revision(revision):
            revision.revisionID
        case let .tombstone(tombstone):
            tombstone.tombstoneID
        case let .reset(reset):
            reset.resetID
        }
    }

    public var libraryGeneration: Int64 {
        switch self {
        case let .revision(revision):
            revision.libraryGeneration
        case let .tombstone(tombstone):
            tombstone.libraryGeneration
        case let .reset(reset):
            reset.generation
        }
    }

    public var modifiedAt: Date {
        switch self {
        case let .revision(revision):
            revision.modifiedAt
        case let .tombstone(tombstone):
            tombstone.modifiedAt
        case let .reset(reset):
            reset.modifiedAt
        }
    }

    public var deviceID: String {
        switch self {
        case let .revision(revision):
            revision.deviceID
        case let .tombstone(tombstone):
            tombstone.deviceID
        case let .reset(reset):
            reset.deviceID
        }
    }
}

public enum MergeOutcome: Equatable, Sendable {
    case inserted(UUID)
    case updated(UUID)
    case conflict(primary: UUID, copy: UUID)
    case deleted(UUID)
    case ignoredDuplicate
    case ignoredStaleGeneration
}

public enum SyncState: String, Codable, Sendable {
    case synced
    case pending
    case deletionPending
    case conflict
    case failed
}

public struct PinnedConflictCopy: Codable, Equatable, Sendable {
    public let sourceItemID: UUID
    public let revision: PinnedRevision
    public let syncState: SyncState

    public init(revision sourceRevision: PinnedRevision) {
        self.init(
            sourceItemID: sourceRevision.itemID,
            revision: PinnedRevision(
                itemID: Self.projectedItemID(sourceItemID: sourceRevision.itemID, revisionID: sourceRevision.revisionID),
                revisionID: sourceRevision.revisionID,
                libraryGeneration: sourceRevision.libraryGeneration,
                itemGeneration: sourceRevision.itemGeneration,
                modifiedAt: sourceRevision.modifiedAt,
                deviceID: sourceRevision.deviceID,
                payload: sourceRevision.payload,
                syncState: .conflict
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sourceItemID
        case revision
        case syncState
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRevision = try values.decode(PinnedRevision.self, forKey: .revision)
        guard let decodedSourceItemID = try values.decodeIfPresent(UUID.self, forKey: .sourceItemID) else {
            self.init(revision: decodedRevision)
            return
        }
        self.init(sourceItemID: decodedSourceItemID, revision: decodedRevision)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sourceItemID, forKey: .sourceItemID)
        try values.encode(revision, forKey: .revision)
        try values.encode(syncState, forKey: .syncState)
    }

    var sourceRevision: PinnedRevision {
        PinnedRevision(
            itemID: sourceItemID,
            revisionID: revision.revisionID,
            libraryGeneration: revision.libraryGeneration,
            itemGeneration: revision.itemGeneration,
            modifiedAt: revision.modifiedAt,
            deviceID: revision.deviceID,
            payload: revision.payload
        )
    }

    private static func projectedItemID(sourceItemID: UUID, revisionID: UUID) -> UUID {
        var sourceBytes = sourceItemID.uuid
        var revisionBytes = revisionID.uuid
        var input = [UInt8]()
        withUnsafeBytes(of: &sourceBytes) { input.append(contentsOf: $0) }
        withUnsafeBytes(of: &revisionBytes) { input.append(contentsOf: $0) }
        var bytes = Array(repeating: UInt8(0), count: 16)
        for (index, byte) in input.enumerated() {
            let first = index % 16
            let second = (index * 7 + 3) % 16
            bytes[first] = bytes[first] &* 31 &+ byte &+ UInt8(truncatingIfNeeded: index)
            bytes[second] ^= byte &+ UInt8(truncatingIfNeeded: index &* 17)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        var projected = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        if projected == sourceItemID {
            bytes[15] ^= 0x01
            projected = UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }
        return projected
    }

    private init(sourceItemID: UUID, revision: PinnedRevision) {
        self.sourceItemID = sourceItemID
        self.revision = PinnedRevision(
            itemID: revision.itemID,
            revisionID: revision.revisionID,
            libraryGeneration: revision.libraryGeneration,
            itemGeneration: revision.itemGeneration,
            modifiedAt: revision.modifiedAt,
            deviceID: revision.deviceID,
            payload: revision.payload,
            syncState: .conflict
        )
        syncState = .conflict
    }
}
