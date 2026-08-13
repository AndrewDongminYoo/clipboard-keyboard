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

    public init(
        itemID: UUID,
        revisionID: UUID,
        libraryGeneration: Int64,
        itemGeneration: Int64,
        modifiedAt: Date,
        deviceID: String,
        payload: PinPayload
    ) {
        self.itemID = itemID
        self.revisionID = revisionID
        self.libraryGeneration = libraryGeneration
        self.itemGeneration = itemGeneration
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
        self.payload = payload
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
    public let revision: PinnedRevision
    public let syncState: SyncState

    public init(revision: PinnedRevision) {
        self.revision = revision
        syncState = .conflict
    }
}
