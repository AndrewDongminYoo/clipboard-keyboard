import ClipboardCore
@testable import ClipboardKeyboardMac
import CryptoKit
import XCTest

final class EncryptedMacClipStoreTests: XCTestCase {
    func testSaveRoundTripWritesOnlyEncryptedContentAndMetadataFields() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let envelope = makeEnvelope(id: UUID(), capturedAt: Date(timeIntervalSince1970: 1_700_000_000), marker: "disk-sentinel", pinned: false)

        try await store.save(envelope)

        let loaded = try await store.load(id: envelope.id)
        let metadataIDs = try await store.listMetadata().map(\.id)
        XCTAssertEqual(loaded, envelope)
        XCTAssertEqual(metadataIDs, [envelope.id])
        let metadataObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("metadata.json"))) as? [[String: Any]])
        XCTAssertEqual(try Set(XCTUnwrap(metadataObject.first).keys), ["id", "capturedAt", "byteCount", "representationKinds", "keyedDigest"])
        XCTAssertNil(try Data(contentsOf: root.appendingPathComponent("metadata.json")).range(of: Data(SourceConfidence.inferredStableForeground.rawValue.utf8)))
        try assertNoFileContains(marker: "disk-sentinel", under: root)
    }

    func testEncryptionFailureLeavesNeitherRecordNorMetadata() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMacClipStore(
            rootURL: root,
            cipher: FailingCipher(),
            retentionPolicy: RetentionPolicy(maxAge: 100, maxUnpinnedCount: 10, historyEnabled: true)
        )

        do {
            try await store.save(makeEnvelope(id: UUID(), capturedAt: Date(), marker: "never-written", pinned: false))
            XCTFail("Expected encryption to fail")
        } catch {
            XCTAssertEqual(error as? PersistenceSecurityError, .authenticationFailed)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("metadata.json").path))
        XCTAssertEqual(try recursiveFiles(under: root), [])
    }

    func testMetadataCommitFailureRollsBackNewCiphertext() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let liveWrites = EncryptedStoreFileOperations.live
        let operations = EncryptedStoreFileOperations(
            atomicWrite: { data, destination in
                if destination.lastPathComponent == "metadata.json" {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try liveWrites.atomicWrite(data, destination)
            },
            removeItemIfPresent: liveWrites.removeItemIfPresent
        )
        let store = EncryptedMacClipStore(
            rootURL: root,
            cipher: AESGCMClipCipher(key: SymmetricKey(data: Data(repeating: 9, count: 32))),
            retentionPolicy: RetentionPolicy(maxAge: 100, maxUnpinnedCount: 10, historyEnabled: true),
            fileOperations: operations
        )

        do {
            try await store.save(makeEnvelope(id: UUID(), capturedAt: Date(), marker: "rollback-sentinel", pinned: false))
            XCTFail("Expected metadata commit to fail")
        } catch {
            XCTAssertEqual(error as? PersistenceSecurityError, .diskFull)
        }

        XCTAssertEqual(try recursiveFiles(under: root), [])
    }

    func testDuplicateIDIsRejectedWithoutChangingExistingFiles() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let id = UUID()
        let original = makeEnvelope(id: id, capturedAt: Date(timeIntervalSince1970: 100), marker: "original-value", pinned: false)
        let replacement = makeEnvelope(id: id, capturedAt: Date(timeIntervalSince1970: 200), marker: "replacement-value", pinned: false)
        try await store.save(original)
        let filesBefore = try fileSnapshot(root: root)

        do {
            try await store.save(replacement)
            XCTFail("Expected duplicate to be rejected")
        } catch {
            XCTAssertEqual(error as? PersistenceSecurityError, .duplicateItem)
        }

        XCTAssertEqual(try fileSnapshot(root: root), filesBefore)
        let loaded = try await store.load(id: id)
        XCTAssertEqual(loaded, original)
    }

    func testRejectsPinnedInputWithoutWritingFiles() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        do {
            try await store.save(makeEnvelope(id: UUID(), capturedAt: Date(), marker: "pinned-rejected", pinned: true))
            XCTFail("Expected pinned input to be rejected")
        } catch {
            XCTAssertEqual(error as? PersistenceSecurityError, .unsupportedRetentionClass)
        }

        XCTAssertEqual(try recursiveFiles(under: root), [])
    }

    func testLoadRejectsCiphertextSwappedBetweenRecordPaths() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let first = makeEnvelope(id: UUID(), capturedAt: Date(timeIntervalSince1970: 100), marker: "first-value", pinned: false)
        let second = makeEnvelope(id: UUID(), capturedAt: Date(timeIntervalSince1970: 200), marker: "second-value", pinned: false)
        try await store.save(first)
        try await store.save(second)
        let firstURL = recordURL(root: root, id: first.id)
        let secondCiphertext = try Data(contentsOf: recordURL(root: root, id: second.id))
        try secondCiphertext.write(to: firstURL)

        do {
            _ = try await store.load(id: first.id)
            XCTFail("Expected swapped record to be rejected")
        } catch {
            XCTAssertEqual(error as? PersistenceSecurityError, .corruptRecord)
        }
    }

    func testPartialDeleteFailureRestoresMetadataAndCiphertext() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cipher = AESGCMClipCipher(key: SymmetricKey(data: Data(repeating: 9, count: 32)))
        let setupStore = EncryptedMacClipStore(
            rootURL: root,
            cipher: cipher,
            retentionPolicy: RetentionPolicy(maxAge: 100, maxUnpinnedCount: 10, historyEnabled: true)
        )
        let first = makeEnvelope(id: UUID(), capturedAt: Date(), marker: "delete-first", pinned: false)
        let second = makeEnvelope(id: UUID(), capturedAt: Date(), marker: "delete-second", pinned: false)
        try await setupStore.save(first)
        try await setupStore.save(second)
        let live = EncryptedStoreFileOperations.live
        let removal = RemovalFailureState()
        let deletingStore = EncryptedMacClipStore(
            rootURL: root,
            cipher: cipher,
            retentionPolicy: RetentionPolicy(maxAge: 100, maxUnpinnedCount: 10, historyEnabled: true),
            fileOperations: EncryptedStoreFileOperations(
                atomicWrite: live.atomicWrite,
                removeItemIfPresent: { url in
                    if removal.nextCallShouldFail() {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try live.removeItemIfPresent(url)
                }
            )
        )

        do {
            try await deletingStore.delete(ids: [first.id, second.id])
            XCTFail("Expected record removal to fail")
        } catch {
            XCTAssertEqual(error as? PersistenceSecurityError, .atomicReplaceFailed)
        }

        let metadataIDs = try Set(await deletingStore.listMetadata().map(\.id))
        let loadedFirst = try await deletingStore.load(id: first.id)
        let loadedSecond = try await deletingStore.load(id: second.id)
        XCTAssertEqual(metadataIDs, [first.id, second.id])
        XCTAssertEqual(loadedFirst, first)
        XCTAssertEqual(loadedSecond, second)
    }

    func testRetentionRemovesExpiredAndOldestOverCountAndKeepsActiveRecords() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 10000)
        let store = EncryptedMacClipStore(
            rootURL: root,
            cipher: AESGCMClipCipher(key: SymmetricKey(data: Data(repeating: 9, count: 32))),
            retentionPolicy: RetentionPolicy(maxAge: 100, maxUnpinnedCount: 2, historyEnabled: true)
        )
        let expired = makeEnvelope(id: UUID(), capturedAt: now.addingTimeInterval(-101), marker: "expired-value", pinned: false)
        let oldest = makeEnvelope(id: UUID(), capturedAt: now.addingTimeInterval(-30), marker: "oldest-value", pinned: false)
        let active1 = makeEnvelope(id: UUID(), capturedAt: now.addingTimeInterval(-20), marker: "active-one", pinned: false)
        let active2 = makeEnvelope(id: UUID(), capturedAt: now.addingTimeInterval(-10), marker: "active-two", pinned: false)
        for envelope in [expired, oldest, active1, active2] {
            try await store.save(envelope)
        }
        XCTAssertEqual(
            try recordFilenames(root: root),
            Set([expired, oldest, active1, active2].map { "\($0.id.uuidString.lowercased()).clip" })
        )

        let removed = try await store.applyRetention(now: now)

        XCTAssertEqual(removed, [expired.id, oldest.id])
        let loadedExpired = try await store.load(id: expired.id)
        let loadedOldest = try await store.load(id: oldest.id)
        let metadataIDs = try Set(await store.listMetadata().map(\.id))
        XCTAssertNil(loadedExpired)
        XCTAssertNil(loadedOldest)
        XCTAssertEqual(metadataIDs, [active1.id, active2.id])
        XCTAssertEqual(
            try recordFilenames(root: root),
            Set([active1, active2].map { "\($0.id.uuidString.lowercased()).clip" })
        )
    }

    func testDuplicateStoredMetadataFailsClosedWithoutChangingCiphertext() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let existing = makeEnvelope(id: UUID(), capturedAt: Date(timeIntervalSince1970: 100), marker: "duplicate-metadata", pinned: false)
        try await store.save(existing)
        let metadataURL = root.appendingPathComponent("metadata.json")
        var metadata = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [[String: Any]])
        try metadata.append(XCTUnwrap(metadata.first))
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: metadataURL)
        let filesBefore = try fileSnapshot(root: root)
        let newEnvelope = makeEnvelope(id: UUID(), capturedAt: Date(timeIntervalSince1970: 200), marker: "must-not-save", pinned: false)

        await assertCorruptRecord { _ = try await store.listMetadata() }
        await assertCorruptRecord { _ = try await store.load(id: existing.id) }
        await assertCorruptRecord { _ = try await store.applyRetention(now: Date(timeIntervalSince1970: 300)) }
        await assertCorruptRecord { try await store.delete(id: existing.id) }
        await assertCorruptRecord { try await store.save(newEnvelope) }

        XCTAssertEqual(try fileSnapshot(root: root), filesBefore)
    }

    func testAccessReconcilesDirectCanonicalOrphansAndPreservesReferencedAndUnrelatedFiles() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let referenced = makeEnvelope(id: UUID(), capturedAt: Date(), marker: "referenced", pinned: false)
        try await store.save(referenced)
        let orphanID = UUID()
        let orphanURL = recordURL(root: root, id: orphanID)
        try Data([1, 2, 3]).write(to: orphanURL)
        let unrelatedURL = root.appendingPathComponent("records/not-a-uuid.clip")
        try Data("unrelated".utf8).write(to: unrelatedURL)
        let noncanonicalUUIDURL = root.appendingPathComponent("records/\(UUID().uuidString.uppercased()).clip")
        try Data("noncanonical".utf8).write(to: noncanonicalUUIDURL)
        let nestedDirectory = root.appendingPathComponent("records/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let nestedOrphanURL = nestedDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).clip")
        try Data([4, 5, 6]).write(to: nestedOrphanURL)
        let reopened = makeStore(root: root)

        let metadataIDs = try await reopened.listMetadata().map(\.id)
        XCTAssertEqual(metadataIDs, [referenced.id])

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL(root: root, id: referenced.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: noncanonicalUUIDURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedOrphanURL.path))
    }

    func testAccessReconcilesRecordLeftAfterMetadataOnlyDeleteCommit() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let deleted = makeEnvelope(id: UUID(), capturedAt: Date(), marker: "delete-orphan", pinned: false)
        try await store.save(deleted)
        try Data("[]".utf8).write(to: root.appendingPathComponent("metadata.json"))
        let orphanURL = recordURL(root: root, id: deleted.id)

        let metadata = try await makeStore(root: root).listMetadata()
        XCTAssertEqual(metadata, [])

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    func testInvalidDuplicateMetadataPerformsNoOrphanCleanup() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let existing = makeEnvelope(id: UUID(), capturedAt: Date(), marker: "invalid-no-cleanup", pinned: false)
        try await store.save(existing)
        let metadataURL = root.appendingPathComponent("metadata.json")
        var metadata = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [[String: Any]])
        try metadata.append(XCTUnwrap(metadata.first))
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        let orphanURL = recordURL(root: root, id: UUID())
        try Data([7, 8, 9]).write(to: orphanURL)
        let filesBefore = try fileSnapshot(root: root)

        await assertCorruptRecord { _ = try await makeStore(root: root).listMetadata() }

        XCTAssertEqual(try fileSnapshot(root: root), filesBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    func testMalformedMetadataPerformsNoOrphanCleanup() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let existing = makeEnvelope(id: UUID(), capturedAt: Date(), marker: "malformed-no-cleanup", pinned: false)
        try await store.save(existing)
        try Data("not-json".utf8).write(to: root.appendingPathComponent("metadata.json"))
        let orphanURL = recordURL(root: root, id: UUID())
        try Data([7, 8, 9]).write(to: orphanURL)
        let filesBefore = try fileSnapshot(root: root)

        await assertCorruptRecord { _ = try await makeStore(root: root).listMetadata() }

        XCTAssertEqual(try fileSnapshot(root: root), filesBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    func testOrphanRemovalFailureSurfacesAndRetriesOnNextAccess() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let setupStore = makeStore(root: root)
        let referenced = makeEnvelope(id: UUID(), capturedAt: Date(), marker: "retry-reference", pinned: false)
        try await setupStore.save(referenced)
        let orphanURL = recordURL(root: root, id: UUID())
        try Data([1]).write(to: orphanURL)
        let live = EncryptedStoreFileOperations.live
        let failure = FirstRemovalFailureState()
        let store = EncryptedMacClipStore(
            rootURL: root,
            cipher: AESGCMClipCipher(key: SymmetricKey(data: Data(repeating: 9, count: 32))),
            retentionPolicy: RetentionPolicy(maxAge: 100, maxUnpinnedCount: 10, historyEnabled: true),
            fileOperations: EncryptedStoreFileOperations(
                atomicWrite: live.atomicWrite,
                removeItemIfPresent: { url in
                    if failure.shouldFail(url: url) {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try live.removeItemIfPresent(url)
                }
            )
        )

        do {
            _ = try await store.listMetadata()
            XCTFail("Expected orphan removal to fail")
        } catch {
            XCTAssertEqual(error as? PersistenceSecurityError, .atomicReplaceFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))

        let metadataIDs = try await store.listMetadata().map(\.id)
        XCTAssertEqual(metadataIDs, [referenced.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    private func makeStore(root: URL) -> EncryptedMacClipStore {
        EncryptedMacClipStore(
            rootURL: root,
            cipher: AESGCMClipCipher(key: SymmetricKey(data: Data(repeating: 9, count: 32))),
            retentionPolicy: RetentionPolicy(maxAge: 100, maxUnpinnedCount: 10, historyEnabled: true)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func recursiveFiles(under root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        return enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private func fileSnapshot(root: URL) throws -> [String: Data] {
        try recursiveFiles(under: root).reduce(into: [:]) { result, url in
            result[url.path.replacingOccurrences(of: root.path, with: "")] = try Data(contentsOf: url)
        }
    }

    private func recordURL(root: URL, id: UUID) -> URL {
        root.appendingPathComponent("records/\(id.uuidString.lowercased()).clip")
    }

    private func recordFilenames(root: URL) throws -> Set<String> {
        let recordsURL = root.appendingPathComponent("records", isDirectory: true)
        return try Set(FileManager.default.contentsOfDirectory(atPath: recordsURL.path))
    }

    private func assertCorruptRecord(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected corrupt metadata to fail closed")
        } catch {
            XCTAssertEqual(error as? PersistenceSecurityError, .corruptRecord)
        }
    }

    private func assertNoFileContains(marker: String, under root: URL) throws {
        for file in try recursiveFiles(under: root) {
            XCTAssertNil(try Data(contentsOf: file).range(of: Data(marker.utf8)), "Plaintext appeared in \(file.lastPathComponent)")
        }
    }

    private func makeEnvelope(id: UUID, capturedAt: Date, marker: String, pinned: Bool) -> ClipEnvelope {
        ClipEnvelope(
            id: id,
            capturedAt: capturedAt,
            retentionClass: pinned ? .pinned : .localHistory,
            sourceConfidence: .inferredStableForeground,
            representations: [ClipRepresentation(kind: .plainText, originalBytes: Data("\(marker)-original".utf8), keyedDigest: Data([4, 5, 6]))],
            canonicalInsertionString: "\(marker)-canonical",
            title: "\(marker)-title",
            contentKind: .plainText,
            category: .everyday,
            preview: "\(marker)-preview",
            valueCandidates: [ValueCandidate(kind: .emailAddress, original: "\(marker)@example.com", normalized: "\(marker)@example.com", context: "\(marker)-context")]
        )
    }
}

private final class RemovalFailureState: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func nextCallShouldFail() -> Bool {
        lock.withLock {
            callCount += 1
            return callCount == 2
        }
    }
}

private final class FirstRemovalFailureState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFailed = false

    func shouldFail(url: URL) -> Bool {
        lock.withLock {
            guard !hasFailed, url.pathExtension == "clip" else { return false }
            hasFailed = true
            return true
        }
    }
}

private struct FailingCipher: ClipCipher {
    func seal(_: ClipEnvelope) throws -> Data {
        throw PersistenceSecurityError.authenticationFailed
    }

    func open(_: Data) throws -> ClipEnvelope {
        throw PersistenceSecurityError.authenticationFailed
    }
}
