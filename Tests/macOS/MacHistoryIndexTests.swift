import ClipboardCore
@testable import ClipboardKeyboardMac
import CryptoKit
import XCTest

final class MacHistoryIndexTests: XCTestCase {
    func testUnlockBuildsBoundedSearchAndLockPurgesMemoryWithoutChangingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMacClipStore(
            rootURL: root,
            cipher: AESGCMClipCipher(key: SymmetricKey(data: Data(repeating: 3, count: 32))),
            retentionPolicy: RetentionPolicy(maxAge: 1000, maxUnpinnedCount: 2, historyEnabled: true)
        )
        let base = Date(timeIntervalSince1970: 10000)
        let oldest = makeEnvelope(marker: "bounded-oldest", capturedAt: base)
        let recent = makeEnvelope(marker: "bounded-recent", capturedAt: base.addingTimeInterval(1))
        let newest = makeEnvelope(marker: "bounded-newest", capturedAt: base.addingTimeInterval(2))
        for envelope in [oldest, recent, newest] {
            try await store.save(envelope)
        }
        let index = MacHistoryIndex()
        try await index.unlock(from: store, now: base.addingTimeInterval(2))
        let filesBeforeLock = try fileSnapshot(root: root)

        let unlockedIDs = await index.search("bounded", limit: 10).map(\.document.id)
        XCTAssertEqual(unlockedIDs, [newest.id, recent.id])
        await index.lock()

        let lockedResults = await index.search("bounded", limit: 10)
        XCTAssertEqual(lockedResults, [])
        XCTAssertEqual(try fileSnapshot(root: root), filesBeforeLock)
    }

    func testRemoveDeletesOnlyInMemoryDocuments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMacClipStore(
            rootURL: root,
            cipher: AESGCMClipCipher(key: SymmetricKey(data: Data(repeating: 3, count: 32))),
            retentionPolicy: RetentionPolicy(maxAge: 1000, maxUnpinnedCount: 2, historyEnabled: true)
        )
        let envelope = makeEnvelope(marker: "remove-memory", capturedAt: Date(timeIntervalSince1970: 10000))
        try await store.save(envelope)
        let index = MacHistoryIndex()
        try await index.unlock(from: store, now: Date(timeIntervalSince1970: 10000))

        await index.remove(ids: [envelope.id])

        let results = await index.search("remove-memory", limit: 10)
        let storedEnvelope = try await store.load(id: envelope.id)
        XCTAssertEqual(results, [])
        XCTAssertNotNil(storedEnvelope)
    }

    func testLockInvalidatesAnUnlockAlreadyInFlight() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CipherGate()
        let key = SymmetricKey(data: Data(repeating: 3, count: 32))
        let writingStore = EncryptedMacClipStore(
            rootURL: root,
            cipher: AESGCMClipCipher(key: key),
            retentionPolicy: RetentionPolicy(maxAge: 1000, maxUnpinnedCount: 2, historyEnabled: true)
        )
        let envelope = makeEnvelope(marker: "in-flight", capturedAt: Date(timeIntervalSince1970: 10000))
        try await writingStore.save(envelope)
        let readingStore = EncryptedMacClipStore(
            rootURL: root,
            cipher: BlockingOpenCipher(base: AESGCMClipCipher(key: key), gate: gate),
            retentionPolicy: RetentionPolicy(maxAge: 1000, maxUnpinnedCount: 2, historyEnabled: true)
        )
        let index = MacHistoryIndex()

        let unlock = Task { try await index.unlock(from: readingStore, now: Date(timeIntervalSince1970: 10000)) }
        XCTAssertTrue(gate.entered.wait(timeout: .now() + 2) == .success)
        await index.lock()
        gate.proceed.signal()
        try await unlock.value

        let results = await index.search("in-flight", limit: 10)
        XCTAssertEqual(results, [])
    }

    func testLockInvalidatesASearchAlreadyInFlight() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(data: Data(repeating: 6, count: 32))
        let store = makeStore(root: root, key: key)
        let envelope = makeEnvelope(marker: "search-in-flight", capturedAt: Date(timeIntervalSince1970: 10000))
        try await store.save(envelope)
        let gate = SearchGate()
        let index = MacHistoryIndex(searchOperation: BlockingSearchOperation(gate: gate))
        try await index.unlock(from: store, now: Date(timeIntervalSince1970: 10000))

        let search = Task { await index.search("search-in-flight", limit: 10) }
        await gate.waitUntilEntered()
        await index.lock()
        await gate.proceed()

        let results = await search.value
        XCTAssertEqual(results, [])
    }

    func testRemoveInvalidatesAnUnlockAlreadyInFlight() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CipherGate()
        let key = SymmetricKey(data: Data(repeating: 4, count: 32))
        let writingStore = makeStore(root: root, key: key)
        let envelope = makeEnvelope(marker: "remove-in-flight", capturedAt: Date(timeIntervalSince1970: 10000))
        try await writingStore.save(envelope)
        let readingStore = EncryptedMacClipStore(
            rootURL: root,
            cipher: BlockingOpenCipher(base: AESGCMClipCipher(key: key), gate: gate),
            retentionPolicy: RetentionPolicy(maxAge: 1000, maxUnpinnedCount: 2, historyEnabled: true)
        )
        let index = MacHistoryIndex()

        let unlock = Task { try await index.unlock(from: readingStore, now: Date(timeIntervalSince1970: 10000)) }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 2), .success)
        await index.remove(ids: [envelope.id])
        gate.proceed.signal()
        try await unlock.value

        let results = await index.search("remove-in-flight", limit: 10)
        XCTAssertEqual(results, [])
    }

    func testNewerOverlappingUnlockSurvivesOlderUnlockCompletion() async throws {
        let olderRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let newerRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: olderRoot)
            try? FileManager.default.removeItem(at: newerRoot)
        }
        let olderGate = CipherGate()
        let key = SymmetricKey(data: Data(repeating: 5, count: 32))
        let olderEnvelope = makeEnvelope(marker: "older-unlock", capturedAt: Date(timeIntervalSince1970: 10000))
        let newerEnvelope = makeEnvelope(marker: "newer-unlock", capturedAt: Date(timeIntervalSince1970: 10001))
        try await makeStore(root: olderRoot, key: key).save(olderEnvelope)
        try await makeStore(root: newerRoot, key: key).save(newerEnvelope)
        let olderStore = EncryptedMacClipStore(
            rootURL: olderRoot,
            cipher: BlockingOpenCipher(base: AESGCMClipCipher(key: key), gate: olderGate),
            retentionPolicy: RetentionPolicy(maxAge: 1000, maxUnpinnedCount: 2, historyEnabled: true)
        )
        let newerStore = makeStore(root: newerRoot, key: key)
        let index = MacHistoryIndex()

        let olderUnlock = Task { try await index.unlock(from: olderStore, now: Date(timeIntervalSince1970: 10001)) }
        XCTAssertEqual(olderGate.entered.wait(timeout: .now() + 2), .success)
        try await index.unlock(from: newerStore, now: Date(timeIntervalSince1970: 10001))
        olderGate.proceed.signal()
        try await olderUnlock.value

        let newerIDs = await index.search("newer-unlock", limit: 10).map(\.document.id)
        let olderResults = await index.search("older-unlock", limit: 10)
        XCTAssertEqual(newerIDs, [newerEnvelope.id])
        XCTAssertEqual(olderResults, [])
    }

    private func fileSnapshot(root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        return try enumerator.compactMap { $0 as? URL }.reduce(into: [:]) { result, url in
            if try (url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result[url.path.replacingOccurrences(of: root.path, with: "")] = try Data(contentsOf: url)
            }
        }
    }

    private func makeEnvelope(marker: String, capturedAt: Date) -> ClipEnvelope {
        ClipEnvelope(
            id: UUID(),
            capturedAt: capturedAt,
            retentionClass: .localHistory,
            sourceConfidence: .inferredStableForeground,
            representations: [ClipRepresentation(kind: .plainText, originalBytes: Data(marker.utf8), keyedDigest: Data([7]))],
            canonicalInsertionString: marker,
            title: marker,
            contentKind: .plainText,
            category: .everyday,
            preview: marker,
            valueCandidates: []
        )
    }

    private func makeStore(root: URL, key: SymmetricKey) -> EncryptedMacClipStore {
        EncryptedMacClipStore(
            rootURL: root,
            cipher: AESGCMClipCipher(key: key),
            retentionPolicy: RetentionPolicy(maxAge: 1000, maxUnpinnedCount: 2, historyEnabled: true)
        )
    }
}

private final class CipherGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
}

private struct BlockingOpenCipher: ClipCipher {
    let base: AESGCMClipCipher
    let gate: CipherGate

    func seal(_ envelope: ClipEnvelope) throws -> Data {
        try base.seal(envelope)
    }

    func open(_ data: Data) throws -> ClipEnvelope {
        gate.entered.signal()
        gate.proceed.wait()
        return try base.open(data)
    }
}

private actor SearchGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var proceedContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            proceedContinuation = continuation
            entered = true
            enteredWaiters.forEach { $0.resume() }
            enteredWaiters.removeAll()
        }
    }

    func waitUntilEntered() async {
        if entered {
            return
        }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func proceed() {
        proceedContinuation?.resume()
        proceedContinuation = nil
    }
}

private struct BlockingSearchOperation: MacHistorySearchOperating {
    let gate: SearchGate

    func search(
        documents: [ClipSearchDocument],
        query: String,
        scope: SearchScope,
        limit: Int
    ) async -> [ClipSearchResult] {
        let index = ClipSearchIndex()
        await index.replace(documents)
        let results = await index.search(query, scope: scope, limit: limit)
        await gate.pause()
        return results
    }
}
