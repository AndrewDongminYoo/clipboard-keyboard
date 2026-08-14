import ClipboardCore
import Combine
import Foundation

enum ShareInboxConsumerError: Error, Equatable {
    case protectedDataUnavailable
    case itemNotFound
    case conflict
    case cleanupFailed
}

protocol ShareInboxPinning: Sendable {
    func ensurePinnedShareItem(_ item: ShareInboxItem) async throws -> SharePinEnsureResult
}

struct ShareInboxConsumerFileOperations: @unchecked Sendable {
    let list: (URL) throws -> [URL]
    let protection: (URL) throws -> FileProtectionType?
    let read: (URL) throws -> Data
    let removeIfExists: (URL) throws -> Void
    let fileExists: (URL) -> Bool

    static let live = ShareInboxConsumerFileOperations(
        list: { directory in
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        },
        protection: { url in
            let value = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
            if let protection = value as? FileProtectionType {
                return protection
            }
            if let rawValue = value as? String {
                return FileProtectionType(rawValue: rawValue)
            }
            return nil
        },
        read: { try Data(contentsOf: $0) },
        removeIfExists: { url in
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        },
        fileExists: { FileManager.default.fileExists(atPath: $0.path) }
    )
}

@MainActor
final class ShareInboxConsumer: ObservableObject {
    @Published private(set) var cachedPendingItems: [ShareInboxItem] = []

    private let directory: URL
    private let pinner: any ShareInboxPinning
    private let operations: ShareInboxConsumerFileOperations
    private let afterPinBeforeCleanup: @Sendable () async throws -> Void
    private let beforeReturningPending: @Sendable () async -> Void
    private var pendingByID: [UUID: ShareInboxItem] = [:]
    private var terminalURLsByID: [UUID: URL] = [:]
    private var lifecycleEpoch: UInt64 = 0
    private var protectedDataAvailable = true

    init(
        directory: URL,
        pinner: any ShareInboxPinning,
        operations: ShareInboxConsumerFileOperations = .live,
        afterPinBeforeCleanup: @escaping @Sendable () async throws -> Void = {},
        beforeReturningPending: @escaping @Sendable () async -> Void = {}
    ) {
        self.directory = directory
        self.pinner = pinner
        self.operations = operations
        self.afterPinBeforeCleanup = afterPinBeforeCleanup
        self.beforeReturningPending = beforeReturningPending
    }

    func pendingItems() async throws -> [ShareInboxItem] {
        guard protectedDataAvailable else { throw ShareInboxConsumerError.protectedDataUnavailable }
        let epoch = lifecycleEpoch
        let urls: [URL]
        do {
            urls = try operations.list(directory)
        } catch {
            throw ShareInboxConsumerError.protectedDataUnavailable
        }
        var decoded: [ShareInboxItem] = []
        var decodedByID: [UUID: ShareInboxItem] = [:]
        for url in urls {
            guard let filenameID = Self.id(fromFinalFilename: url.lastPathComponent) else { continue }
            guard terminalURLsByID[filenameID] == nil else { continue }
            let protection: FileProtectionType?
            do {
                protection = try operations.protection(url)
            } catch {
                continue
            }
            guard protection == .complete else { continue }
            let data: Data
            do {
                data = try operations.read(url)
            } catch {
                continue
            }
            switch ShareInboxItemValidator().validate(data) {
            case let .valid(item) where item.id == filenameID:
                decoded.append(item)
                decodedByID[item.id] = item
            case .valid, .invalid:
                terminalURLsByID[filenameID] = url
            }
        }
        decoded.sort {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        await beforeReturningPending()
        guard epoch == lifecycleEpoch, protectedDataAvailable else {
            throw ShareInboxConsumerError.protectedDataUnavailable
        }
        pendingByID = decodedByID
        cachedPendingItems = decoded
        return decoded
    }

    func commit(id: UUID) async throws {
        let finalURL = directory.appendingPathComponent(Self.finalFilename(for: id))
        guard protectedDataAvailable else { throw ShareInboxConsumerError.protectedDataUnavailable }
        let epoch = lifecycleEpoch
        guard let item = pendingByID[id] else {
            if !operations.fileExists(finalURL) {
                return
            }
            throw ShareInboxConsumerError.itemNotFound
        }
        try Task.checkCancellation()
        let result = try await pinner.ensurePinnedShareItem(item)
        try validateCommitLifecycle(epoch)
        if result == .conflict {
            terminalURLsByID[id] = finalURL
            do {
                try operations.removeIfExists(finalURL)
                terminalURLsByID.removeValue(forKey: id)
            } catch {
                throw ShareInboxConsumerError.cleanupFailed
            }
            removeDecoded(id: id)
            throw ShareInboxConsumerError.conflict
        }
        try await afterPinBeforeCleanup()
        try validateCommitLifecycle(epoch)
        do {
            try operations.removeIfExists(finalURL)
        } catch {
            throw ShareInboxConsumerError.cleanupFailed
        }
        removeDecoded(id: id)
    }

    func reject(id: UUID) throws {
        let url = directory.appendingPathComponent(Self.finalFilename(for: id))
        do {
            try operations.removeIfExists(url)
        } catch {
            throw ShareInboxConsumerError.cleanupFailed
        }
        terminalURLsByID.removeValue(forKey: id)
        removeDecoded(id: id)
    }

    func purgeTerminalItems() throws {
        for id in Array(terminalURLsByID.keys) {
            guard let url = terminalURLsByID[id] else { continue }
            do {
                try operations.removeIfExists(url)
                terminalURLsByID.removeValue(forKey: id)
            } catch {
                throw ShareInboxConsumerError.cleanupFailed
            }
        }
    }

    func protectedDataWillBecomeUnavailable() {
        lifecycleEpoch &+= 1
        protectedDataAvailable = false
        pendingByID.removeAll(keepingCapacity: false)
        cachedPendingItems.removeAll(keepingCapacity: false)
    }

    func protectedDataDidBecomeAvailable() {
        lifecycleEpoch &+= 1
        protectedDataAvailable = true
    }

    nonisolated static func finalFilename(for id: UUID) -> String {
        "share-v1-\(id.uuidString.lowercased()).json"
    }

    nonisolated static func id(fromFinalFilename name: String) -> UUID? {
        let prefix = "share-v1-"
        let suffix = ".json"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        let rawID = String(name[start ..< end])
        guard let id = UUID(uuidString: rawID), finalFilename(for: id) == name else { return nil }
        return id
    }

    private func removeDecoded(id: UUID) {
        pendingByID.removeValue(forKey: id)
        cachedPendingItems.removeAll { $0.id == id }
    }

    private func validateCommitLifecycle(_ epoch: UInt64) throws {
        guard epoch == lifecycleEpoch, protectedDataAvailable else {
            throw ShareInboxConsumerError.protectedDataUnavailable
        }
    }
}
