import CryptoKit
import Foundation

@available(macOS 10.15, iOS 13.0, *)
public actor AsyncOperationSerializer {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waitingOperationCount: Int {
        waiters.count
    }

    public init() {}

    public func withOperation<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    public func acquire() async {
        guard isRunning else {
            isRunning = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        guard !waiters.isEmpty else {
            isRunning = false
            return
        }
        waiters.removeFirst().resume()
    }
}

public struct KeyboardSnapshotItem: Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let category: ClipCategory?
    public let canonicalInsertionString: String

    public init(id: UUID, title: String, category: ClipCategory?, canonicalInsertionString: String) {
        self.id = id
        self.title = title
        self.category = category
        self.canonicalInsertionString = canonicalInsertionString
    }
}

public struct KeyboardSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generation: Int64
    public let createdAt: Date
    public let lastSuccessfulCloudRefresh: Date?
    public let contentDigest: String
    public let itemCount: Int
    public let items: [KeyboardSnapshotItem]

    @available(macOS 10.15, iOS 13.0, *)
    public static func make(
        items: [KeyboardSnapshotItem],
        generation: Int64,
        createdAt: Date,
        lastSuccessfulCloudRefresh: Date?
    ) throws -> KeyboardSnapshot {
        let sortedItems = items.sorted { $0.id.uuidString < $1.id.uuidString }
        let unsigned = UnsignedKeyboardSnapshot(
            schemaVersion: currentSchemaVersion,
            generation: generation,
            createdAt: createdAt,
            lastSuccessfulCloudRefresh: lastSuccessfulCloudRefresh,
            itemCount: sortedItems.count,
            items: sortedItems
        )
        let digest = try SHA256.hash(data: KeyboardSnapshotCodec.encoder.encode(unsigned)).hexString
        return KeyboardSnapshot(
            schemaVersion: currentSchemaVersion,
            generation: generation,
            createdAt: createdAt,
            lastSuccessfulCloudRefresh: lastSuccessfulCloudRefresh,
            contentDigest: digest,
            itemCount: sortedItems.count,
            items: sortedItems
        )
    }

    public func refreshRecommended(at date: Date) -> Bool {
        guard let lastSuccessfulCloudRefresh else { return true }
        return date.timeIntervalSince(lastSuccessfulCloudRefresh) > 24 * 60 * 60
    }

    fileprivate var unsigned: UnsignedKeyboardSnapshot {
        UnsignedKeyboardSnapshot(
            schemaVersion: schemaVersion,
            generation: generation,
            createdAt: createdAt,
            lastSuccessfulCloudRefresh: lastSuccessfulCloudRefresh,
            itemCount: itemCount,
            items: items
        )
    }
}

public struct KeyboardSnapshotCodec: Sendable {
    fileprivate static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public init() {}

    public func encode(_ snapshot: KeyboardSnapshot) throws -> Data {
        try Self.encoder.encode(snapshot)
    }

    public func decode(_ data: Data) throws -> KeyboardSnapshot {
        try Self.decoder.decode(KeyboardSnapshot.self, from: data)
    }
}

public enum KeyboardSnapshotValidationFailure: Equatable, Sendable {
    case malformed
    case unsupportedSchema
    case itemCountMismatch
    case duplicateItemID
    case digestMismatch
}

public enum KeyboardSnapshotValidationResult: Equatable, Sendable {
    case valid(KeyboardSnapshot)
    case invalid(KeyboardSnapshotValidationFailure)
}

@available(macOS 10.15, iOS 13.0, *)
public struct KeyboardSnapshotValidator: Sendable {
    public init() {}

    public func validate(_ data: Data) -> KeyboardSnapshotValidationResult {
        let snapshot: KeyboardSnapshot
        do {
            snapshot = try KeyboardSnapshotCodec().decode(data)
        } catch {
            return .invalid(.malformed)
        }
        guard snapshot.schemaVersion == KeyboardSnapshot.currentSchemaVersion else {
            return .invalid(.unsupportedSchema)
        }
        guard snapshot.itemCount == snapshot.items.count else {
            return .invalid(.itemCountMismatch)
        }
        guard Set(snapshot.items.map(\.id)).count == snapshot.items.count else {
            return .invalid(.duplicateItemID)
        }
        guard let digestData = try? KeyboardSnapshotCodec.encoder.encode(snapshot.unsigned) else {
            return .invalid(.malformed)
        }
        let expectedDigest = SHA256.hash(data: digestData).hexString
        guard snapshot.contentDigest == expectedDigest else {
            return .invalid(.digestMismatch)
        }
        return .valid(snapshot)
    }
}

private struct UnsignedKeyboardSnapshot: Encodable {
    let schemaVersion: Int
    let generation: Int64
    let createdAt: Date
    let lastSuccessfulCloudRefresh: Date?
    let itemCount: Int
    let items: [KeyboardSnapshotItem]
}

@available(macOS 10.15, iOS 13.0, *)
private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
