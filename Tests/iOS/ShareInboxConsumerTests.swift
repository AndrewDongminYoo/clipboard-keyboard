import ClipboardCore
@testable import ClipboardKeyboardiOS
import Foundation
import XCTest

@MainActor
final class ShareInboxConsumerTests: XCTestCase {
    func testEnumeratesOnlyStrictProtectedValidFinalsAndPurgesTerminalWithoutTouchingTransientOrUnknown() async throws {
        let fixture = try ConsumerFixture()
        fixture.files.add(item: fixture.item(1), protection: .complete)
        fixture.files.add(item: fixture.item(2), protection: .completeUnlessOpen)
        fixture.files.addRaw(name: "share-v1-00000000-0000-0000-0000-000000000003.json", data: Data("partial".utf8))
        fixture.files.addRaw(name: ".share-v1-owned.tmp", data: Data("temp".utf8))
        fixture.files.addRaw(name: "unrelated.json", data: Data("unknown".utf8))

        let pending = try await fixture.consumer.pendingItems()

        XCTAssertEqual(pending.map(\.id), [fixture.item(1).id])
        try fixture.consumer.purgeTerminalItems()
        XCTAssertFalse(fixture.files.exists(named: "share-v1-00000000-0000-0000-0000-000000000003.json"))
        XCTAssertTrue(fixture.files.exists(named: "share-v1-00000000-0000-0000-0000-000000000002.json"))
        XCTAssertTrue(fixture.files.exists(named: ".share-v1-owned.tmp"))
        XCTAssertTrue(fixture.files.exists(named: "unrelated.json"))
    }

    func testStoreThrowOrCancellationBeforeCommitRetainsInboxAndPinsNothing() async throws {
        for failure in [ConsumerTestError.store, ConsumerTestError.cancelled] {
            let pinner = ConsumerPinner(failure: failure)
            let fixture = try ConsumerFixture(pinner: pinner)
            fixture.files.add(item: fixture.item(10), protection: .complete)
            _ = try await fixture.consumer.pendingItems()

            await XCTAssertThrowsConsumerError(try await fixture.consumer.commit(id: fixture.item(10).id))

            XCTAssertTrue(fixture.files.exists(item: fixture.item(10)))
            let itemCount = await pinner.itemCount
            XCTAssertEqual(itemCount, 0)
        }
    }

    func testCrashAfterStoreCommitThenRetryPinsOneRevisionAndRemovesInbox() async throws {
        let pinner = ConsumerPinner()
        let fixture = try ConsumerFixture(pinner: pinner, afterPinBeforeCleanup: { throw ConsumerTestError.crash })
        let item = fixture.item(20)
        fixture.files.add(item: item, protection: .complete)
        _ = try await fixture.consumer.pendingItems()

        await XCTAssertThrowsConsumerError(try await fixture.consumer.commit(id: item.id))
        XCTAssertTrue(fixture.files.exists(item: item))

        let retry = ShareInboxConsumer(directory: fixture.directory, pinner: pinner, operations: fixture.files.operations)
        _ = try await retry.pendingItems()
        try await retry.commit(id: item.id)

        let itemCount = await pinner.itemCount
        let insertCount = await pinner.insertCount
        XCTAssertEqual(itemCount, 1)
        XCTAssertEqual(insertCount, 1)
        XCTAssertFalse(fixture.files.exists(item: item))
    }

    func testCleanupFailureRetainsRecoverableFinalAndRetryRemovesWithoutDuplicate() async throws {
        let pinner = ConsumerPinner()
        let fixture = try ConsumerFixture(pinner: pinner)
        let item = fixture.item(30)
        fixture.files.add(item: item, protection: .complete)
        fixture.files.failNextRemove = true
        _ = try await fixture.consumer.pendingItems()

        await XCTAssertThrowsConsumerError(try await fixture.consumer.commit(id: item.id))
        XCTAssertTrue(fixture.files.exists(item: item))

        try await fixture.consumer.commit(id: item.id)

        let insertCount = await pinner.insertCount
        XCTAssertEqual(insertCount, 1)
        XCTAssertFalse(fixture.files.exists(item: item))
    }

    func testCancellationAfterStoreCommitStillFinishesSynchronousCleanup() async throws {
        let barrier = ConsumerBarrier()
        let pinner = ConsumerPinner(afterCommit: { await barrier.suspend() })
        let fixture = try ConsumerFixture(pinner: pinner)
        let item = fixture.item(40)
        fixture.files.add(item: item, protection: .complete)
        _ = try await fixture.consumer.pendingItems()
        let consumer = fixture.consumer
        let commit = Task { try await consumer.commit(id: item.id) }
        await barrier.waitUntilEntered()

        commit.cancel()
        await barrier.release()
        try await commit.value

        let insertCount = await pinner.insertCount
        XCTAssertEqual(insertCount, 1)
        XCTAssertFalse(fixture.files.exists(item: item))
    }

    func testLockAfterDurablePinReturnRetainsFinalThenUnlockRetryCleansWithoutDuplicate() async throws {
        let barrier = ConsumerBarrier()
        let pinner = ConsumerPinner(afterCommit: { await barrier.suspend() })
        let fixture = try ConsumerFixture(pinner: pinner)
        let item = fixture.item(41)
        fixture.files.add(item: item, protection: .complete)
        _ = try await fixture.consumer.pendingItems()
        let consumer = fixture.consumer
        let commit = Task { try await consumer.commit(id: item.id) }
        await barrier.waitUntilEntered()

        consumer.protectedDataWillBecomeUnavailable()
        await barrier.release()

        await XCTAssertThrowsConsumerError(try await commit.value, equals: .protectedDataUnavailable)
        XCTAssertTrue(fixture.files.exists(item: item))
        let committedInsertCount = await pinner.insertCount
        XCTAssertEqual(committedInsertCount, 1)

        consumer.protectedDataDidBecomeAvailable()
        _ = try await consumer.pendingItems()
        try await consumer.commit(id: item.id)

        let retryInsertCount = await pinner.insertCount
        XCTAssertEqual(retryInsertCount, 1)
        XCTAssertFalse(fixture.files.exists(item: item))
    }

    func testLockAfterCleanupHookRetainsFinalThenUnlockRetryCleansWithoutDuplicate() async throws {
        let barrier = ConsumerBarrier()
        let pinner = ConsumerPinner()
        let fixture = try ConsumerFixture(pinner: pinner, afterPinBeforeCleanup: { await barrier.suspend() })
        let item = fixture.item(42)
        fixture.files.add(item: item, protection: .complete)
        _ = try await fixture.consumer.pendingItems()
        let consumer = fixture.consumer
        let commit = Task { try await consumer.commit(id: item.id) }
        await barrier.waitUntilEntered()

        consumer.protectedDataWillBecomeUnavailable()
        await barrier.release()

        await XCTAssertThrowsConsumerError(try await commit.value, equals: .protectedDataUnavailable)
        XCTAssertTrue(fixture.files.exists(item: item))
        let committedInsertCount = await pinner.insertCount
        XCTAssertEqual(committedInsertCount, 1)

        consumer.protectedDataDidBecomeAvailable()
        _ = try await consumer.pendingItems()
        try await consumer.commit(id: item.id)

        let retryInsertCount = await pinner.insertCount
        XCTAssertEqual(retryInsertCount, 1)
        XCTAssertFalse(fixture.files.exists(item: item))
    }

    func testLockAfterConflictReturnRetainsFinalBeforeTerminalCleanup() async throws {
        let barrier = ConsumerBarrier()
        let incoming = try ConsumerFixture().item(43)
        let existing = try ShareInboxItem.make(
            id: incoming.id,
            createdAt: incoming.createdAt,
            kind: .text,
            data: Data("existing".utf8)
        )
        let pinner = ConsumerPinner(beforeReturn: { await barrier.suspend() }, existing: existing)
        let fixture = try ConsumerFixture(pinner: pinner)
        fixture.files.add(item: incoming, protection: .complete)
        _ = try await fixture.consumer.pendingItems()
        let consumer = fixture.consumer
        let commit = Task { try await consumer.commit(id: incoming.id) }
        await barrier.waitUntilEntered()

        consumer.protectedDataWillBecomeUnavailable()
        await barrier.release()

        await XCTAssertThrowsConsumerError(try await commit.value, equals: .protectedDataUnavailable)
        XCTAssertTrue(fixture.files.exists(item: incoming))
        let stored = await pinner.item(for: incoming.id)
        XCTAssertEqual(stored, existing)

        consumer.protectedDataDidBecomeAvailable()
        _ = try await consumer.pendingItems()
        await XCTAssertThrowsConsumerError(try await consumer.commit(id: incoming.id))
        XCTAssertFalse(fixture.files.exists(item: incoming))
    }

    func testLockPurgesDecodedItemsAndStaleRefreshCannotRepopulate() async throws {
        let barrier = ConsumerBarrier()
        let fixture = try ConsumerFixture(beforeReturningPending: { await barrier.suspend() })
        fixture.files.add(item: fixture.item(50), protection: .complete)
        let consumer = fixture.consumer
        let refresh = Task { try await consumer.pendingItems() }
        await barrier.waitUntilEntered()

        consumer.protectedDataWillBecomeUnavailable()
        await barrier.release()

        await XCTAssertThrowsConsumerError(try await refresh.value)
        XCTAssertEqual(consumer.cachedPendingItems, [])
    }

    func testValidURLCommitPinsExactItemIDAndRemovesFinal() async throws {
        let pinner = ConsumerPinner()
        let fixture = try ConsumerFixture(pinner: pinner)
        let item = try ShareInboxItem.make(
            id: fixture.item(60).id,
            createdAt: Date(timeIntervalSince1970: 60),
            kind: .url,
            data: Data("https://example.com/path".utf8)
        )
        fixture.files.add(item: item, protection: .complete)
        _ = try await fixture.consumer.pendingItems()

        try await fixture.consumer.commit(id: item.id)

        let stored = await pinner.item(for: item.id)
        XCTAssertEqual(stored, item)
        XCTAssertFalse(fixture.files.exists(item: item))
    }

    func testExplicitRejectRemovesFinalWithoutPin() async throws {
        let pinner = ConsumerPinner()
        let fixture = try ConsumerFixture(pinner: pinner)
        let item = fixture.item(61)
        fixture.files.add(item: item, protection: .complete)
        _ = try await fixture.consumer.pendingItems()

        try fixture.consumer.reject(id: item.id)

        let itemCount = await pinner.itemCount
        XCTAssertEqual(itemCount, 0)
        XCTAssertFalse(fixture.files.exists(item: item))
    }

    func testSchemaDigestAndFilenameMismatchAreTerminalAndContentFreePurgeable() async throws {
        let fixture = try ConsumerFixture()
        let schemaItem = fixture.item(62)
        let digestItem = fixture.item(63)
        let filenameItem = fixture.item(64)
        try fixture.files.addRaw(
            name: ShareInboxConsumer.finalFilename(for: schemaItem.id),
            data: mutated(schemaItem, key: "schemaVersion", value: 2)
        )
        try fixture.files.addRaw(
            name: ShareInboxConsumer.finalFilename(for: digestItem.id),
            data: mutated(digestItem, key: "digest", value: String(repeating: "0", count: 64))
        )
        try fixture.files.addRaw(
            name: ShareInboxConsumer.finalFilename(for: fixture.item(65).id),
            data: ShareInboxItemCodec().encode(filenameItem)
        )

        let pending = try await fixture.consumer.pendingItems()
        XCTAssertEqual(pending, [])
        try fixture.consumer.purgeTerminalItems()

        XCTAssertFalse(fixture.files.exists(item: schemaItem))
        XCTAssertFalse(fixture.files.exists(item: digestItem))
        XCTAssertFalse(fixture.files.exists(named: ShareInboxConsumer.finalFilename(for: fixture.item(65).id)))
    }

    func testFixedIDConflictNeverOverwritesAndBecomesTerminal() async throws {
        let incoming = try ConsumerFixture().item(66)
        let existing = try ShareInboxItem.make(
            id: incoming.id,
            createdAt: incoming.createdAt,
            kind: .text,
            data: Data("existing".utf8)
        )
        let pinner = ConsumerPinner(existing: existing)
        let fixture = try ConsumerFixture(pinner: pinner)
        fixture.files.add(item: incoming, protection: .complete)
        _ = try await fixture.consumer.pendingItems()

        await XCTAssertThrowsConsumerError(try await fixture.consumer.commit(id: incoming.id))
        let stored = await pinner.item(for: incoming.id)
        XCTAssertEqual(stored, existing)
        XCTAssertFalse(fixture.files.exists(item: incoming))
        let refreshed = try await fixture.consumer.pendingItems()
        XCTAssertEqual(refreshed, [])
    }

    func testConflictCleanupFailureCanRetryFromSamePendingWithoutRevival() async throws {
        let incoming = try ShareInboxItem.make(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000066")),
            createdAt: Date(timeIntervalSince1970: 66),
            kind: .text,
            data: Data("incoming".utf8)
        )
        let existing = try ShareInboxItem.make(
            id: incoming.id,
            createdAt: incoming.createdAt,
            kind: .text,
            data: Data("existing".utf8)
        )
        let pinner = ConsumerPinner(existing: existing)
        let fixture = try ConsumerFixture(pinner: pinner)
        fixture.files.add(item: incoming, protection: .complete)
        _ = try await fixture.consumer.pendingItems()
        fixture.files.failNextRemove = true

        await XCTAssertThrowsConsumerError(try await fixture.consumer.commit(id: incoming.id))
        XCTAssertTrue(fixture.files.exists(item: incoming))

        await XCTAssertThrowsConsumerError(try await fixture.consumer.commit(id: incoming.id))
        XCTAssertFalse(fixture.files.exists(item: incoming))
        let refreshed = try await fixture.consumer.pendingItems()
        XCTAssertEqual(refreshed, [])
        let stored = await pinner.item(for: incoming.id)
        XCTAssertEqual(stored, existing)
    }

    func testTransientReadFailureRetainsFinalForLaterRefresh() async throws {
        let fixture = try ConsumerFixture()
        let item = fixture.item(67)
        fixture.files.add(item: item, protection: .complete)
        fixture.files.failReadNames.insert(ShareInboxConsumer.finalFilename(for: item.id))

        let failedPending = try await fixture.consumer.pendingItems()
        XCTAssertEqual(failedPending, [])
        XCTAssertTrue(fixture.files.exists(item: item))

        fixture.files.failReadNames.removeAll()
        let recoveredPending = try await fixture.consumer.pendingItems()
        XCTAssertEqual(recoveredPending.map(\.id), [item.id])
    }

    private func mutated(_ item: ShareInboxItem, key: String, value: Any) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ShareInboxItemCodec().encode(item)) as? [String: Any]
        )
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

@MainActor
private final class ConsumerFixture {
    let directory = URL(fileURLWithPath: "/group/share-inbox", isDirectory: true)
    let files = ConsumerFiles()
    let consumer: ShareInboxConsumer

    init(
        pinner: ConsumerPinner = ConsumerPinner(),
        afterPinBeforeCleanup: @escaping @Sendable () async throws -> Void = {},
        beforeReturningPending: @escaping @Sendable () async -> Void = {}
    ) throws {
        consumer = ShareInboxConsumer(
            directory: directory,
            pinner: pinner,
            operations: files.operations,
            afterPinBeforeCleanup: afterPinBeforeCleanup,
            beforeReturningPending: beforeReturningPending
        )
    }

    func item(_ suffix: Int) -> ShareInboxItem {
        try! ShareInboxItem.make(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!,
            createdAt: Date(timeIntervalSince1970: TimeInterval(suffix)),
            kind: .text,
            data: Data("share \(suffix)".utf8)
        )
    }
}

private final class ConsumerFiles: @unchecked Sendable {
    private var dataByURL: [URL: Data] = [:]
    private var protectionByURL: [URL: FileProtectionType] = [:]
    var failNextRemove = false
    var failReadNames: Set<String> = []

    var operations: ShareInboxConsumerFileOperations {
        ShareInboxConsumerFileOperations(
            list: { [self] directory in dataByURL.keys.filter { $0.deletingLastPathComponent() == directory } },
            protection: { [self] url in protectionByURL[url] },
            read: { [self] url in
                if failReadNames.contains(url.lastPathComponent) {
                    throw ConsumerTestError.file
                }
                guard let data = dataByURL[url] else { throw ConsumerTestError.file }
                return data
            },
            removeIfExists: { [self] url in
                if failNextRemove {
                    failNextRemove = false
                    throw ConsumerTestError.file
                }
                dataByURL.removeValue(forKey: url)
                protectionByURL.removeValue(forKey: url)
            },
            fileExists: { [self] url in dataByURL[url] != nil }
        )
    }

    func add(item: ShareInboxItem, protection: FileProtectionType) {
        addRaw(name: ShareInboxConsumer.finalFilename(for: item.id), data: try! ShareInboxItemCodec().encode(item))
        protectionByURL[url(named: ShareInboxConsumer.finalFilename(for: item.id))] = protection
    }

    func addRaw(name: String, data: Data) {
        dataByURL[url(named: name)] = data
        protectionByURL[url(named: name)] = .complete
    }

    func exists(item: ShareInboxItem) -> Bool {
        exists(named: ShareInboxConsumer.finalFilename(for: item.id))
    }

    func exists(named name: String) -> Bool {
        dataByURL[url(named: name)] != nil
    }

    private func url(named name: String) -> URL {
        URL(fileURLWithPath: "/group/share-inbox/\(name)")
    }
}

private actor ConsumerPinner: ShareInboxPinning {
    private var items: [UUID: ShareInboxItem] = [:]
    private let failure: ConsumerTestError?
    private let afterCommit: @Sendable () async -> Void
    private let beforeReturn: @Sendable () async -> Void
    private(set) var insertCount = 0

    init(
        failure: ConsumerTestError? = nil,
        afterCommit: @escaping @Sendable () async -> Void = {},
        beforeReturn: @escaping @Sendable () async -> Void = {},
        existing: ShareInboxItem? = nil
    ) {
        self.failure = failure
        self.afterCommit = afterCommit
        self.beforeReturn = beforeReturn
        if let existing {
            items[existing.id] = existing
        }
    }

    var itemCount: Int {
        items.count
    }

    func item(for id: UUID) -> ShareInboxItem? {
        items[id]
    }

    func ensurePinnedShareItem(_ item: ShareInboxItem) async throws -> SharePinEnsureResult {
        if let failure {
            if failure == .cancelled {
                throw CancellationError()
            }
            throw failure
        }
        if let existing = items[item.id] {
            await beforeReturn()
            return existing == item ? .alreadyPresent : .conflict
        }
        items[item.id] = item
        insertCount += 1
        await afterCommit()
        let result = SharePinEnsureResult.inserted(PinnedRevision(
            itemID: item.id,
            revisionID: UUID(),
            libraryGeneration: 0,
            itemGeneration: 1,
            modifiedAt: item.createdAt,
            deviceID: "test",
            payload: PinPayload(
                representations: [],
                canonicalInsertionString: String(decoding: item.data, as: UTF8.self),
                title: "Shared",
                contentKind: .plainText,
                category: nil
            )
        ))
        await beforeReturn()
        return result
    }
}

private actor ConsumerBarrier {
    private var entered = false
    private var hasSuspended = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        guard !hasSuspended else { return }
        hasSuspended = true
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume(); continuation = nil
    }
}

private enum ConsumerTestError: Error, Equatable { case store, cancelled, crash, file }

@MainActor
private func XCTAssertThrowsConsumerError<T>(_ expression: @autoclosure () async throws -> T) async {
    do {
        _ = try await expression()
        XCTFail("Expected consumer error")
    } catch {}
}

@MainActor
private func XCTAssertThrowsConsumerError<T>(
    _ expression: @autoclosure () async throws -> T,
    equals expectedError: ShareInboxConsumerError
) async {
    do {
        _ = try await expression()
        XCTFail("Expected consumer error")
    } catch let error as ShareInboxConsumerError {
        XCTAssertEqual(error, expectedError)
    } catch {
        XCTFail("Unexpected error type")
    }
}
