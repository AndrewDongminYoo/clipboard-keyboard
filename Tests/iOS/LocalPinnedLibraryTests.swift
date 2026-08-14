import ClipboardCore
@testable import ClipboardKeyboardiOS
import CryptoKit
import XCTest

final class LocalPinnedLibraryTests: XCTestCase {
    func testPinAndReviseUseImmutableGenerationsAndDurablePendingJournal() async throws {
        let fixture = LocalLibraryFixture()
        defer { fixture.remove() }
        let original = payload("deploy preview", title: "Deploy", category: .code)

        let pinned = try await fixture.library.pin(original)
        let revised = try await fixture.library.revise(
            itemID: pinned.itemID,
            payload: payload("deploy production", title: "Deploy safely", category: .code)
        )

        XCTAssertEqual(pinned.itemGeneration, 1)
        XCTAssertEqual(revised.itemGeneration, 2)
        XCTAssertEqual(pinned.payload, original)
        let items = try await fixture.library.allItems()
        XCTAssertEqual(items, [revised])
        let searchResults = try await fixture.library.search("production", limit: 20)
        XCTAssertEqual(searchResults.map(\.itemID), [pinned.itemID])
        let state = try await fixture.store.load()
        XCTAssertEqual(
            Set(state.pendingJournal.pending.map(\.mutationID)),
            Set([pinned.revisionID, revised.revisionID])
        )
    }

    func testCategoryProjectionTreatsNilAsUncategorizedWithoutAutomaticPin() async throws {
        let fixture = LocalLibraryFixture()
        defer { fixture.remove() }
        _ = try await fixture.library.pin(payload("prompt", title: "Prompt", category: .prompts))
        _ = try await fixture.library.pin(payload("code", title: "Code", category: .code))
        _ = try await fixture.library.pin(payload("note", title: "Note", category: .everyday))
        let uncategorized = try await fixture.library.pin(payload("loose", title: "Loose", category: nil))

        let prompts = try await fixture.library.items(category: .prompts)
        let code = try await fixture.library.items(category: .code)
        let everyday = try await fixture.library.items(category: .everyday)
        let uncategorizedItems = try await fixture.library.items(category: nil)
        let state = try await fixture.store.load()
        XCTAssertEqual(prompts.map(\.payload.title), ["Prompt"])
        XCTAssertEqual(code.map(\.payload.title), ["Code"])
        XCTAssertEqual(everyday.map(\.payload.title), ["Note"])
        XCTAssertEqual(uncategorizedItems.map(\.itemID), [uncategorized.itemID])
        XCTAssertEqual(state.primaryRevisions.count, 4)
    }

    func testDeleteDisappearsImmediatelyWhileTombstoneAndPendingMutationRemainDurable() async throws {
        let fixture = LocalLibraryFixture()
        defer { fixture.remove() }
        let pinned = try await fixture.library.pin(payload("delete secret", title: "Delete", category: nil))

        let tombstone = try await fixture.library.delete(itemID: pinned.itemID)

        XCTAssertEqual(tombstone.itemGeneration, 2)
        let items = try await fixture.library.allItems()
        let searchResults = try await fixture.library.search("secret", limit: 20)
        XCTAssertEqual(items, [])
        XCTAssertEqual(searchResults, [])
        let state = try await fixture.store.load()
        XCTAssertEqual(state.primaryRevisions, [])
        XCTAssertEqual(state.tombstones, [tombstone])
        XCTAssertEqual(state.pendingJournal.pending.count, 1)
        guard case let .tombstone(persistedTombstone)? = state.pendingJournal.pending.first(where: {
            if case .tombstone = $0 {
                return true
            }
            return false
        }) else {
            return XCTFail("Expected deletion pending mutation")
        }
        XCTAssertEqual(persistedTombstone, tombstone)
        XCTAssertEqual(fixture.ownedArtifactURLs, [])
    }

    func testRemoteTombstoneScrubsOnlyDeletedItemsPendingContent() async throws {
        let fixture = LocalLibraryFixture()
        defer { fixture.remove() }
        let deleted = try await fixture.library.pin(payload("remote delete secret", title: "Deleted", category: nil))
        let retained = try await fixture.library.pin(payload("keep intact", title: "Retained", category: .everyday))
        let before = try await fixture.store.load()
        let retainedMutation = try XCTUnwrap(before.pendingJournal.pending.first(where: { $0.mutationID == retained.revisionID }))
        let tombstone = PinnedTombstone(
            itemID: deleted.itemID,
            tombstoneID: UUID(),
            libraryGeneration: deleted.libraryGeneration,
            itemGeneration: deleted.itemGeneration + 1,
            modifiedAt: deleted.modifiedAt.addingTimeInterval(1),
            deviceID: "remote-device"
        )

        _ = try await fixture.library.applyRemote(.tombstone(tombstone))

        let after = try await fixture.store.load()
        XCTAssertEqual(after.primaryRevisions, [retained])
        XCTAssertEqual(after.pendingJournal.pending, [retainedMutation])
        XCTAssertFalse(after.pendingJournal.pending.contains { mutation in
            switch mutation {
            case let .revision(revision): revision.itemID == deleted.itemID
            case let .tombstone(tombstone): tombstone.itemID == deleted.itemID
            case .reset: false
            }
        })
    }

    func testLockRevokesBackendPermanently() async throws {
        let fixture = LocalLibraryFixture()
        defer { fixture.remove() }
        let pinned = try await fixture.library.pin(payload("unlock search", title: "Locked", category: nil))
        let unlockedResults = try await fixture.library.search("unlock", limit: 20)
        XCTAssertEqual(unlockedResults.map(\.itemID), [pinned.itemID])

        await fixture.library.protectedDataWillBecomeUnavailable()
        await XCTAssertThrowsLocalError(try await fixture.library.search("unlock", limit: 20)) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectedDataUnavailable)
        }

        await XCTAssertThrowsLocalError(try await fixture.library.reopenProtectedData()) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectedDataUnavailable)
        }
    }

    func testSearchRejectsNegativeLimitsAndCapsResultsAtCoreIndexMaximum() async throws {
        let fixture = LocalLibraryFixture()
        defer { fixture.remove() }
        for index in 0 ..< 105 {
            _ = try await fixture.library.pin(payload("common \(index)", title: "Item \(index)", category: nil))
        }

        await XCTAssertThrowsLocalError(try await fixture.library.search("common", limit: -1)) { error in
            XCTAssertEqual(error as? LocalPinnedLibraryError, .invalidLimit)
        }
        let cappedResults = try await fixture.library.search("common", limit: 1000)
        XCTAssertEqual(cappedResults.count, 100)
    }

    func testInFlightSearchCannotReturnDeletedPlaintext() async throws {
        let barrier = LocalAsyncBarrier()
        let fixture = LocalLibraryFixture(beforeReturningSearch: { await barrier.suspend() })
        defer { fixture.remove() }
        let pinned = try await fixture.library.pin(payload("stale deleted plaintext", title: "Private", category: nil))

        let search = Task { try await fixture.library.search("plaintext", limit: 20) }
        await barrier.waitUntilEntered()
        _ = try await fixture.library.delete(itemID: pinned.itemID)
        await barrier.release()

        let staleSearchResults = try await search.value
        XCTAssertEqual(staleSearchResults, [])
        let resultsAfterDelete = try await fixture.library.search("plaintext", limit: 20)
        XCTAssertEqual(resultsAfterDelete, [])
    }

    func testTwoCommittedConcurrentMutationsBothSucceed() async throws {
        let barrier = ArmedLocalAsyncBarrier()
        let fixture = LocalLibraryFixture(beforeReturningMutation: { await barrier.suspendIfArmed() })
        defer { fixture.remove() }
        let firstPayload = payload("first concurrent", title: "First", category: nil)
        let secondPayload = payload("second concurrent", title: "Second", category: nil)
        await barrier.arm()

        let firstMutation = Task { try await fixture.library.pin(firstPayload) }
        await barrier.waitUntilEntered()
        let secondRevision = try await fixture.library.pin(secondPayload)
        await barrier.release()
        let firstRevision = try await firstMutation.value

        XCTAssertNotEqual(firstRevision.itemID, secondRevision.itemID)
        let items = try await fixture.library.allItems()
        XCTAssertEqual(items.count, 2)
    }

    func testStaleAllItemsSnapshotRetriesCurrentStoreState() async throws {
        let barrier = ArmedLocalAsyncBarrier()
        let fixture = LocalLibraryFixture(beforeReturningSnapshot: { await barrier.suspendIfArmed() })
        defer { fixture.remove() }
        _ = try await fixture.library.pin(payload("existing snapshot", title: "Existing", category: nil))
        await barrier.arm()

        let snapshot = Task { try await fixture.library.allItems() }
        await barrier.waitUntilEntered()
        let fresh = try await fixture.library.pin(payload("fresh snapshot", title: "Fresh", category: nil))
        await barrier.release()
        let items = try await snapshot.value

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains { $0.itemID == fresh.itemID })
    }

    @MainActor
    func testAllItemsSnapshotChurnExhaustionLeavesLeaseActiveAndViewModelUnavailable() async throws {
        let barrier = RepeatingLocalAsyncBarrier()
        let fixture = LocalLibraryFixture(beforeReturningSnapshot: { await barrier.suspend() })
        defer { fixture.remove() }
        _ = try await fixture.library.pin(payload("initial snapshot", title: "Initial", category: nil))
        let model = LibraryViewModel(
            library: fixture.library,
            textTransformer: TextTransformer { Data($0.reversed()) }
        )

        let load = Task { await model.load() }
        for attempt in 1 ... 3 {
            await barrier.waitUntilEntered(attempt)
            _ = try await fixture.library.pin(payload("churn \(attempt)", title: "Churn", category: nil))
            await barrier.release(attempt)
        }
        await load.value

        XCTAssertTrue(fixture.lease.isActive)
        XCTAssertEqual(model.storageStatus, .unavailable)
        XCTAssertEqual(model.items, [])
    }

    @MainActor
    func testSearchSnapshotChurnExhaustionLeavesLeaseActiveAndViewModelUnavailable() async throws {
        let barrier = RepeatingLocalAsyncBarrier()
        let fixture = LocalLibraryFixture(beforeReturningSearch: { await barrier.suspend() })
        defer { fixture.remove() }
        _ = try await fixture.library.pin(payload("search target", title: "Target", category: nil))
        let model = LibraryViewModel(
            library: fixture.library,
            textTransformer: TextTransformer { Data($0.reversed()) }
        )
        await model.load()

        let search = Task { await model.updateQuery("target") }
        for attempt in 1 ... 3 {
            await barrier.waitUntilEntered(attempt)
            _ = try await fixture.library.pin(payload("search churn \(attempt)", title: "Churn", category: nil))
            await barrier.release(attempt)
        }
        await search.value

        XCTAssertTrue(fixture.lease.isActive)
        XCTAssertEqual(model.storageStatus, .unavailable)
        XCTAssertEqual(model.items, [])
    }

    func testInFlightMutationCannotSucceedAfterLock() async throws {
        let barrier = ArmedLocalAsyncBarrier()
        let fixture = LocalLibraryFixture(beforeReturningMutation: { await barrier.suspendIfArmed() })
        defer { fixture.remove() }
        let pinned = try await fixture.library.pin(payload("original secret", title: "Private", category: nil))
        let replacement = payload("stale replacement", title: "Private", category: nil)
        await barrier.arm()

        let revision = Task {
            try await fixture.library.revise(
                itemID: pinned.itemID,
                payload: replacement
            )
        }
        await barrier.waitUntilEntered()
        await fixture.library.protectedDataWillBecomeUnavailable()
        await barrier.release()

        await XCTAssertThrowsLocalError(try await revision.value) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectedDataUnavailable)
        }
    }

    func testEnsurePinnedUsesFixedIDAndRetryCreatesOneRevisionAndJournalEntry() async throws {
        let fixture = LocalLibraryFixture()
        defer { fixture.remove() }
        let itemID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000111"))
        let value = payload("shared text", title: "Shared", category: nil)

        let first = try await fixture.library.ensurePinned(payload: value, itemID: itemID)
        let retry = try await fixture.library.ensurePinned(payload: value, itemID: itemID)

        guard case let .inserted(revision) = first else { return XCTFail("Expected insert") }
        XCTAssertEqual(revision.itemID, itemID)
        XCTAssertEqual(retry, .alreadyPresent)
        let state = try await fixture.store.load()
        XCTAssertEqual(state.primaryRevisions.count, 1)
        XCTAssertEqual(state.pendingJournal.pending.count, 1)
    }

    func testEnsurePinnedConflictingPayloadNeverOverwrites() async throws {
        let fixture = LocalLibraryFixture()
        defer { fixture.remove() }
        let itemID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000112"))
        let original = payload("original", title: "Shared", category: nil)
        _ = try await fixture.library.ensurePinned(payload: original, itemID: itemID)

        let result = try await fixture.library.ensurePinned(
            payload: payload("conflict", title: "Shared", category: nil),
            itemID: itemID
        )

        XCTAssertEqual(result, .conflict)
        let state = try await fixture.store.load()
        XCTAssertEqual(state.primaryRevisions.first?.payload, original)
        XCTAssertEqual(state.primaryRevisions.count, 1)
    }

    func testEnsurePinnedNeverResurrectsTombstonedID() async throws {
        let fixture = LocalLibraryFixture()
        defer { fixture.remove() }
        let itemID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000113"))
        let value = payload("deleted", title: "Shared", category: nil)
        _ = try await fixture.library.ensurePinned(payload: value, itemID: itemID)
        _ = try await fixture.library.delete(itemID: itemID)

        let result = try await fixture.library.ensurePinned(payload: value, itemID: itemID)

        XCTAssertEqual(result, .conflict)
        let state = try await fixture.store.load()
        XCTAssertEqual(state.primaryRevisions, [])
        XCTAssertEqual(state.tombstones.map(\.itemID), [itemID])
    }

    func testConcurrentEnsurePinnedSameIDCreatesExactlyOneRevision() async throws {
        let fixture = LocalLibraryFixture()
        defer { fixture.remove() }
        let itemID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000114"))
        let value = payload("concurrent", title: "Shared", category: nil)

        async let first = fixture.library.ensurePinned(payload: value, itemID: itemID)
        async let second = fixture.library.ensurePinned(payload: value, itemID: itemID)
        let results = try await [first, second]

        XCTAssertEqual(results.filter {
            if case .inserted = $0 {
                true
            } else {
                false
            }
        }.count, 1)
        XCTAssertEqual(results.filter { $0 == .alreadyPresent }.count, 1)
        let state = try await fixture.store.load()
        XCTAssertEqual(state.primaryRevisions.count, 1)
        XCTAssertEqual(state.pendingJournal.pending.count, 1)
    }

    func testCancelledEnsurePinnedBeforeTransactionCreatesNothing() async throws {
        let barrier = LocalAsyncBarrier()
        let fixture = LocalLibraryFixture(beforeEnsurePinnedTransaction: { await barrier.suspend() })
        defer { fixture.remove() }
        let itemID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000115"))
        let value = payload("cancelled", title: "Shared", category: nil)
        let operation = Task { try await fixture.library.ensurePinned(payload: value, itemID: itemID) }
        await barrier.waitUntilEntered()

        operation.cancel()
        await barrier.release()

        await XCTAssertThrowsLocalError(try await operation.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let state = try await fixture.store.load()
        XCTAssertEqual(state.primaryRevisions, [])
    }

    func testStoreFailureBeforeEnsurePinnedCommitCreatesNothing() async throws {
        let fixture = LocalLibraryFixture()
        defer { fixture.remove() }
        fixture.fileOperations.failNextWrite = true
        let itemID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000116"))

        await XCTAssertThrowsLocalError(
            try await fixture.library.ensurePinned(
                payload: payload("failed", title: "Shared", category: nil),
                itemID: itemID
            )
        ) { _ in }

        let state = try await fixture.store.load()
        XCTAssertEqual(state.primaryRevisions, [])
        XCTAssertEqual(state.pendingJournal.pending, [])
    }

    private func payload(_ text: String, title: String, category: ClipCategory?) -> PinPayload {
        PinPayload(
            representations: [.init(kind: .plainText, originalBytes: Data(text.utf8), keyedDigest: Data([1]))],
            canonicalInsertionString: text,
            title: title,
            contentKind: category == .code ? .code : .plainText,
            category: category
        )
    }
}

private final class LocalLibraryFixture: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileOperations = LocalProtectedFileOperations()
    let lease = ProtectedDataLease()
    let store: EncryptedPhonePinnedStore
    let library: LocalPinnedLibrary

    var ownedArtifactURLs: [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".pinned.") }) ?? []
    }

    init(
        beforeReturningSearch: @escaping @Sendable () async -> Void = {},
        beforeReturningMutation: @escaping @Sendable () async -> Void = {},
        beforeReturningSnapshot: @escaping @Sendable () async -> Void = {},
        beforeEnsurePinnedTransaction: @escaping @Sendable () async -> Void = {}
    ) {
        store = EncryptedPhonePinnedStore(
            fileURL: root.appendingPathComponent("pinned-replica.encrypted"),
            key: SymmetricKey(data: Data(repeating: 4, count: 32)),
            operations: fileOperations.operations,
            lease: lease
        )
        library = LocalPinnedLibrary(
            store: store,
            lease: lease,
            deviceID: "phone-test",
            now: { Date(timeIntervalSince1970: 200) },
            beforeReturningSearch: beforeReturningSearch,
            beforeReturningMutation: beforeReturningMutation,
            beforeReturningSnapshot: beforeReturningSnapshot,
            beforeEnsurePinnedTransaction: beforeEnsurePinnedTransaction
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ArmedLocalAsyncBarrier {
    private var isArmed = false
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func arm() {
        isArmed = true
    }

    func suspendIfArmed() async {
        guard isArmed else { return }
        isArmed = false
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor LocalAsyncBarrier {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        guard !entered else { return }
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor RepeatingLocalAsyncBarrier {
    private var enteredCount = 0
    private var enteredWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedIterations: Set<Int> = []

    func suspend() async {
        enteredCount += 1
        let iteration = enteredCount
        let readyWaiters = enteredWaiters.filter { $0.0 <= enteredCount }
        enteredWaiters.removeAll { $0.0 <= enteredCount }
        for (_, waiter) in readyWaiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            if releasedIterations.remove(iteration) != nil {
                continuation.resume()
            } else {
                releaseWaiters[iteration] = continuation
            }
        }
    }

    func waitUntilEntered(_ target: Int) async {
        guard enteredCount < target else { return }
        await withCheckedContinuation { enteredWaiters.append((target, $0)) }
    }

    func release(_ iteration: Int) {
        if let waiter = releaseWaiters.removeValue(forKey: iteration) {
            waiter.resume()
        } else {
            releasedIterations.insert(iteration)
        }
    }
}

private final class LocalProtectedFileOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var protectionByURL: [URL: FileProtectionType] = [:]
    private var shouldFailNextWrite = false

    var failNextWrite: Bool {
        get { lock.withLock { shouldFailNextWrite } }
        set { lock.withLock { shouldFailNextWrite = newValue } }
    }

    var operations: PhonePinnedFileOperations {
        PhonePinnedFileOperations(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
            createEmpty: { url in
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw LocalPinnedLibraryError.itemNotFound
                }
            },
            read: { try Data(contentsOf: $0) },
            write: { [self] data, url in
                let shouldFail = lock.withLock {
                    let value = shouldFailNextWrite
                    shouldFailNextWrite = false
                    return value
                }
                if shouldFail {
                    throw LocalPinnedLibraryError.itemNotFound
                }
                try data.write(to: url)
            },
            setCompleteProtection: { [self] url in
                lock.withLock { protectionByURL[url] = .complete }
            },
            protection: { [self] url in
                lock.withLock { protectionByURL[url] }
            },
            replace: { [self] temporaryURL, finalURL in
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
                lock.withLock { protectionByURL[finalURL] = protectionByURL[temporaryURL] }
            },
            removeIfExists: { url in
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        )
    }
}

private func XCTAssertThrowsLocalError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
