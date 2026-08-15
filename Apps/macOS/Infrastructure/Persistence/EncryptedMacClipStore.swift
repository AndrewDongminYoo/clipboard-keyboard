import ClipboardCore
import Foundation

struct EncryptedStoreFileOperations: @unchecked Sendable {
    let atomicWrite: (Data, URL) throws -> Void
    let removeItemIfPresent: (URL) throws -> Void

    static let live = EncryptedStoreFileOperations(
        atomicWrite: { data, destination in
            let fileManager = FileManager.default
            let temporary = destination
                .deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
            do {
                try data.write(to: temporary, options: .withoutOverwriting)
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try fileManager.moveItem(at: temporary, to: destination)
                }
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw error
            }
        },
        removeItemIfPresent: { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    )
}

actor EncryptedMacClipStore: ClipPersisting {
    typealias Clip = ClipEnvelope

    private struct StoredClipMetadata: Codable {
        let id: UUID
        let capturedAt: Date
        let byteCount: Int
        let representationKinds: [String]
        let keyedDigest: Data

        init(envelope: ClipEnvelope) {
            id = envelope.id
            capturedAt = envelope.capturedAt
            byteCount = envelope.representations.reduce(0) { $0 + $1.byteSize }
            representationKinds = envelope.representations.map { $0.kind.rawValue }
            keyedDigest = envelope.representations.first?.keyedDigest ?? Data()
        }

        var runtimeValue: ClipMetadata {
            ClipMetadata(
                id: id,
                capturedAt: capturedAt,
                byteCount: byteCount,
                representationKinds: representationKinds,
                keyedDigest: keyedDigest,
                sourceConfidence: .unknown,
                isPinned: false
            )
        }
    }

    private let rootURL: URL
    private let recordsURL: URL
    private let metadataURL: URL
    private let cipher: any ClipCipher
    private let retentionPolicy: RetentionPolicy
    private let fileOperations: EncryptedStoreFileOperations
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        rootURL: URL,
        cipher: any ClipCipher,
        retentionPolicy: RetentionPolicy,
        fileOperations: EncryptedStoreFileOperations = .live
    ) {
        self.rootURL = rootURL
        recordsURL = rootURL.appendingPathComponent("records", isDirectory: true)
        metadataURL = rootURL.appendingPathComponent("metadata.json")
        self.cipher = cipher
        self.retentionPolicy = retentionPolicy
        self.fileOperations = fileOperations
        encoder.outputFormatting = [.sortedKeys]
    }

    func save(_ clip: ClipEnvelope) async throws {
        try Task.checkCancellation()
        guard clip.retentionClass == .localHistory else {
            throw PersistenceSecurityError.unsupportedRetentionClass
        }
        let existingMetadata = try storedMetadata()
        guard !existingMetadata.contains(where: { $0.id == clip.id }) else {
            throw PersistenceSecurityError.duplicateItem
        }
        let ciphertext = try cipher.seal(clip)
        let destination = recordURL(id: clip.id)
        let updatedMetadata = existingMetadata + [StoredClipMetadata(envelope: clip)]

        do {
            try createDirectories()
            try fileOperations.atomicWrite(ciphertext, destination)
            try Task.checkCancellation()
            try fileOperations.atomicWrite(encoder.encode(updatedMetadata), metadataURL)
        } catch {
            try? fileOperations.removeItemIfPresent(destination)
            throw mapFileError(error)
        }
    }

    func load(id: UUID) async throws -> ClipEnvelope? {
        guard try storedMetadata().contains(where: { $0.id == id }) else { return nil }
        let destination = recordURL(id: id)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw PersistenceSecurityError.corruptRecord
        }
        do {
            let envelope = try cipher.open(Data(contentsOf: destination))
            guard envelope.id == id else {
                throw PersistenceSecurityError.corruptRecord
            }
            return envelope
        } catch let error as PersistenceSecurityError {
            throw error
        } catch {
            throw PersistenceSecurityError.corruptRecord
        }
    }

    func listMetadata() async throws -> [ClipMetadata] {
        try storedMetadata()
            .map(\.runtimeValue)
            .sorted { lhs, rhs in
                if lhs.capturedAt == rhs.capturedAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.capturedAt > rhs.capturedAt
            }
    }

    func delete(id: UUID) async throws {
        try await delete(ids: [id])
    }

    func delete(ids: Set<UUID>) async throws {
        guard !ids.isEmpty else { return }
        let originalMetadata = try storedMetadata()
        let retained = originalMetadata.filter { !ids.contains($0.id) }
        let originalMetadataData: Data
        let recordSnapshots: [UUID: Data]
        do {
            originalMetadataData = try encoder.encode(originalMetadata)
            recordSnapshots = try ids.reduce(into: [:]) { snapshots, id in
                let url = recordURL(id: id)
                if FileManager.default.fileExists(atPath: url.path) {
                    snapshots[id] = try Data(contentsOf: url)
                }
            }
        } catch {
            throw mapFileError(error)
        }
        do {
            try createDirectories()
            try fileOperations.atomicWrite(encoder.encode(retained), metadataURL)
            for id in ids {
                try fileOperations.removeItemIfPresent(recordURL(id: id))
            }
        } catch {
            try? fileOperations.atomicWrite(originalMetadataData, metadataURL)
            for (id, data) in recordSnapshots {
                try? fileOperations.atomicWrite(data, recordURL(id: id))
            }
            throw mapFileError(error)
        }
    }

    func applyRetention(now: Date) async throws -> Set<UUID> {
        let metadata = try storedMetadata()
        let removed = retentionPolicy.evictionIDs(for: metadata.map(\.runtimeValue), now: now)
        try await delete(ids: removed)
        return removed
    }

    private func storedMetadata() throws -> [StoredClipMetadata] {
        let metadata: [StoredClipMetadata]
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            do {
                metadata = try decoder.decode([StoredClipMetadata].self, from: Data(contentsOf: metadataURL))
            } catch {
                throw PersistenceSecurityError.corruptRecord
            }
        } else {
            metadata = []
        }
        guard Set(metadata.map(\.id)).count == metadata.count else {
            throw PersistenceSecurityError.corruptRecord
        }
        try reconcileOrphanRecords(referencedIDs: Set(metadata.map(\.id)))
        return metadata
    }

    private func reconcileOrphanRecords(referencedIDs: Set<UUID>) throws {
        guard FileManager.default.fileExists(atPath: recordsURL.path) else { return }
        let directEntries: [URL]
        do {
            directEntries = try FileManager.default.contentsOfDirectory(
                at: recordsURL,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        } catch {
            throw mapFileError(error)
        }

        for entry in directEntries {
            guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let id = canonicalRecordID(for: entry),
                  !referencedIDs.contains(id)
            else { continue }
            do {
                try fileOperations.removeItemIfPresent(entry)
            } catch {
                throw mapFileError(error)
            }
        }
    }

    private func canonicalRecordID(for url: URL) -> UUID? {
        guard url.pathExtension == "clip" else { return nil }
        let basename = url.deletingPathExtension().lastPathComponent
        guard let id = UUID(uuidString: basename), basename == id.uuidString.lowercased() else { return nil }
        return id
    }

    private func createDirectories() throws {
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: recordsURL, withIntermediateDirectories: true)
        } catch {
            throw mapFileError(error)
        }
    }

    private func recordURL(id: UUID) -> URL {
        recordsURL.appendingPathComponent("\(id.uuidString.lowercased()).clip")
    }

    private func mapFileError(_ error: Error) -> PersistenceSecurityError {
        if let securityError = error as? PersistenceSecurityError {
            return securityError
        }
        if error is CancellationError {
            return .atomicReplaceFailed
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return .diskFull
        }
        return .atomicReplaceFailed
    }
}
