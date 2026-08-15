import ClipboardCore
@testable import ClipboardKeyboardiOS
import Foundation
import XCTest

@MainActor
final class PhonePinnedLibrarySnapshotTests: XCTestCase {
    func testBeginUnlockArmsRevocationFenceBeforeAsyncReopen() {
        let publisher = SnapshotPublisherSpy()
        let gate = PhonePinnedLibraryGate(snapshotPublisher: publisher)

        _ = gate.beginUnlock()

        XCTAssertEqual(publisher.armCount, 1)
    }

    func testInstallAndMutationsPublishCurrentLocalPinnedRevisions() async throws {
        let publisher = SnapshotPublisherSpy()
        let backend = SnapshotLibraryFake(items: [revision(1)])
        let gate = PhonePinnedLibraryGate(snapshotPublisher: publisher, now: { Date(timeIntervalSince1970: 50) })
        let unlock = gate.beginUnlock()
        XCTAssertTrue(gate.install(backend, for: unlock, generation: 3))

        try await gate.refreshKeyboardSnapshot()
        let pinned = try await gate.pin(payload(2))
        _ = try await gate.revise(itemID: uuid(1), payload: payload(3))

        XCTAssertEqual(publisher.publishedItemIDs.last, Set([uuid(1), pinned.itemID]))
        XCTAssertEqual(publisher.publishCount, 3)
    }

    func testRemoteRevisionRefreshesSnapshotWithoutEnqueuingLocalNotification() async throws {
        let publisher = SnapshotPublisherSpy()
        let backend = SnapshotLibraryFake(items: [])
        let gate = installedGate(publisher: publisher, backend: backend)
        var localNotificationCount = 0
        gate.localMutationCommitted = { localNotificationCount += 1 }
        let remote = revision(44)

        _ = try await gate.applyRemote(.revision(remote))
        _ = try await gate.applyRemote(.revision(remote))

        XCTAssertEqual(publisher.publishedItemIDs.last, Set([remote.itemID]))
        XCTAssertEqual(localNotificationCount, 0)
    }

    func testRemoteMutationWithoutCompletedFetchKeepsPriorRefreshTimestampUntilExplicitSuccess() async throws {
        let clock = SnapshotClock(now: Date(timeIntervalSince1970: 100))
        let publisher = SnapshotPublisherSpy()
        let backend = SnapshotLibraryFake(items: [])
        let gate = PhonePinnedLibraryGate(snapshotPublisher: publisher, now: { clock.now() })
        let unlock = gate.beginUnlock()
        XCTAssertTrue(gate.install(backend, for: unlock, generation: 1))

        try await gate.markCloudRefreshSucceeded()
        clock.set(Date(timeIntervalSince1970: 200))
        _ = try await gate.applyRemote(.revision(revision(45)))

        XCTAssertEqual(publisher.lastCloudRefreshes.last, Date(timeIntervalSince1970: 100))

        clock.set(Date(timeIntervalSince1970: 300))
        try await gate.markCloudRefreshSucceeded()
        XCTAssertEqual(publisher.lastCloudRefreshes.last, Date(timeIntervalSince1970: 300))
    }

    func testStaleMutationCompletionAfterLockCannotRepublishContent() async throws {
        let barrier = SnapshotBarrier()
        let publisher = SnapshotPublisherSpy()
        let backend = SnapshotLibraryFake(items: [revision(1)], mutationBarrier: barrier)
        let gate = PhonePinnedLibraryGate(snapshotPublisher: publisher)
        let unlock = gate.beginUnlock()
        XCTAssertTrue(gate.install(backend, for: unlock, generation: 1))
        let mutation = Task { try await gate.pin(payload(2)) }
        await barrier.waitUntilEntered()

        gate.lock()
        await barrier.release()

        await XCTAssertThrowsSnapshotError(try await mutation.value)
        XCTAssertEqual(publisher.publishCount, 0)
        XCTAssertEqual(publisher.armCount, 2)
    }

    func testDeletePublicationFailureKeepsFenceAndPropagatesContentFreeError() async throws {
        let publisher = SnapshotPublisherSpy()
        let backend = SnapshotLibraryFake(items: [revision(1)])
        let gate = PhonePinnedLibraryGate(snapshotPublisher: publisher)
        let unlock = gate.beginUnlock()
        XCTAssertTrue(gate.install(backend, for: unlock, generation: 1))
        try await gate.refreshKeyboardSnapshot()
        publisher.failDestructivePublication = true

        await XCTAssertThrowsPublisherError(
            try await gate.delete(itemID: uuid(1)),
            expected: .publicationFailed
        )

        XCTAssertTrue(publisher.fenceArmed)
        XCTAssertEqual(publisher.publishedItemIDs.first, Set([uuid(1)]))
    }

    func testDeleteDoesNotMutateBackendWhenRevocationFenceCannotBeArmed() async throws {
        let publisher = SnapshotPublisherSpy()
        let backend = SnapshotLibraryFake(items: [revision(1)])
        let gate = installedGate(publisher: publisher, backend: backend)
        publisher.failArm = true

        await XCTAssertThrowsPublisherError(
            try await gate.delete(itemID: uuid(1)),
            expected: .revocationFenceUnavailable
        )

        let deleteCount = await backend.deleteCount
        let remainingItemIDs = try await backend.allItems().map(\.itemID)
        XCTAssertEqual(deleteCount, 0)
        XCTAssertEqual(remainingItemIDs, [uuid(1)])
        await XCTAssertThrowsSnapshotError(try await gate.allItems())
    }

    func testDeletePurgesDeletionRecoveryContentBeforeBackendMutation() async throws {
        let recovery = DeletionRecoveryState()
        let backend = SnapshotLibraryFake(items: [revision(1)], onDestructiveMutation: {
            await MainActor.run { recovery.recordBackendMutation() }
        })
        let gate = installedGate(publisher: SnapshotPublisherSpy(), backend: backend)
        try recovery.populate(for: gate)
        gate.preDestructivePurge = { [weak recovery] in
            guard let recovery else { throw SnapshotTestFailure.injected }
            try recovery.purge()
        }

        _ = try await gate.delete(itemID: uuid(1))

        XCTAssertTrue(recovery.wasPurgedBeforeBackendMutation)
        XCTAssertTrue(recovery.isEmpty)
        let deleteCount = await backend.deleteCount
        XCTAssertEqual(deleteCount, 1)
    }

    func testAdvanceResetGenerationPurgesDeletionRecoveryContentBeforeBackendMutation() async throws {
        let recovery = DeletionRecoveryState()
        let backend = SnapshotLibraryFake(items: [revision(1)], onDestructiveMutation: {
            await MainActor.run { recovery.recordBackendMutation() }
        })
        let gate = installedGate(publisher: SnapshotPublisherSpy(), backend: backend)
        try recovery.populate(for: gate)
        gate.preDestructivePurge = { [weak recovery] in
            guard let recovery else { throw SnapshotTestFailure.injected }
            try recovery.purge()
        }

        _ = try await gate.advanceResetGeneration()

        XCTAssertTrue(recovery.wasPurgedBeforeBackendMutation)
        XCTAssertTrue(recovery.isEmpty)
        let resetCount = await backend.resetCount
        XCTAssertEqual(resetCount, 1)
    }

    func testNoopOrphanRemovalFailsClosedBeforeDeleteOrReset() async throws {
        let recovery = UnremovedDeletionRecoveryState()
        let backend = SnapshotLibraryFake(items: [revision(1)])
        let gate = installedGate(publisher: SnapshotPublisherSpy(), backend: backend)
        try recovery.populate(for: gate)
        gate.preDestructivePurge = { [weak recovery] in
            guard let recovery else { throw SnapshotTestFailure.injected }
            try recovery.purge()
        }

        await XCTAssertThrowsPublisherError(
            try await gate.delete(itemID: uuid(1)),
            expected: .publicationFailed
        )
        await XCTAssertThrowsPublisherError(
            try await gate.advanceResetGeneration(),
            expected: .publicationFailed
        )

        XCTAssertTrue(recovery.orphanStillExists)
        let deleteCount = await backend.deleteCount
        let resetCount = await backend.resetCount
        XCTAssertEqual(deleteCount, 0)
        XCTAssertEqual(resetCount, 0)
    }

    func testPurgeFailurePreventsEveryBackendDestructiveMutationWithContentFreeError() async throws {
        let deleteBackend = SnapshotLibraryFake(items: [revision(1)])
        let deleteGate = installedGate(publisher: SnapshotPublisherSpy(), backend: deleteBackend)
        deleteGate.preDestructivePurge = { throw SensitivePurgeFailure("delete plaintext") }
        await XCTAssertThrowsPublisherError(
            try await deleteGate.delete(itemID: uuid(1)),
            expected: .publicationFailed
        )

        let resetBackend = SnapshotLibraryFake(items: [revision(1)])
        let resetGate = installedGate(publisher: SnapshotPublisherSpy(), backend: resetBackend)
        resetGate.preDestructivePurge = { throw SensitivePurgeFailure("reset plaintext") }
        await XCTAssertThrowsPublisherError(
            try await resetGate.advanceResetGeneration(),
            expected: .publicationFailed
        )

        let remoteBackend = SnapshotLibraryFake(items: [revision(1)])
        let remoteGate = installedGate(publisher: SnapshotPublisherSpy(), backend: remoteBackend)
        remoteGate.preDestructivePurge = { throw SensitivePurgeFailure("remote plaintext") }
        let tombstone = PinnedTombstone(
            itemID: uuid(1), tombstoneID: UUID(), libraryGeneration: 1, itemGeneration: 2,
            modifiedAt: Date(), deviceID: "remote"
        )
        await XCTAssertThrowsPublisherError(
            try await remoteGate.applyRemote(.tombstone(tombstone)),
            expected: .publicationFailed
        )

        let deleteCount = await deleteBackend.deleteCount
        let resetCount = await resetBackend.resetCount
        let applyRemoteCount = await remoteBackend.applyRemoteCount
        XCTAssertEqual(deleteCount, 0)
        XCTAssertEqual(resetCount, 0)
        XCTAssertEqual(applyRemoteCount, 0)
    }

    func testRemoteTombstoneAndResetPurgeBeforeApplyingBackendMutations() async throws {
        let backend = SnapshotLibraryFake(items: [revision(1)])
        let gate = installedGate(publisher: SnapshotPublisherSpy(), backend: backend)
        var purgeCount = 0
        gate.preDestructivePurge = { purgeCount += 1 }
        let tombstone = PinnedTombstone(
            itemID: uuid(1), tombstoneID: UUID(), libraryGeneration: 1, itemGeneration: 2,
            modifiedAt: Date(), deviceID: "remote"
        )

        _ = try await gate.applyRemote(.tombstone(tombstone))
        _ = try await gate.applyRemote(.reset(LibraryResetGeneration(
            resetID: UUID(), generation: 2, modifiedAt: Date(), deviceID: "remote"
        )))

        XCTAssertEqual(purgeCount, 2)
        let applyRemoteCount = await backend.applyRemoteCount
        XCTAssertEqual(applyRemoteCount, 2)
    }

    func testQueuedOldSessionDeleteCannotUseNewlyInstalledBackend() async throws {
        let allItemsBarrier = OneShotSnapshotBarrier()
        let publisher = SnapshotPublisherSpy()
        let oldBackend = SnapshotLibraryFake(items: [revision(1)], allItemsBarrier: allItemsBarrier)
        let gate = installedGate(publisher: publisher, backend: oldBackend)
        let refresh = Task { try await gate.refreshKeyboardSnapshot() }
        await allItemsBarrier.waitUntilEntered()
        let queuedDelete = Task { try await gate.delete(itemID: self.uuid(1)) }
        await waitForSnapshotOperationRequest(2, gate: gate)
        gate.lock()
        let newBackend = SnapshotLibraryFake(items: [revision(1)])
        let newUnlock = gate.beginUnlock()
        XCTAssertTrue(gate.install(newBackend, for: newUnlock, generation: 1))
        await allItemsBarrier.release()

        await XCTAssertThrowsSnapshotError(try await refresh.value)
        await XCTAssertThrowsSnapshotError(try await queuedDelete.value)
        let newBackendDeleteCount = await newBackend.deleteCount
        XCTAssertEqual(newBackendDeleteCount, 0)
    }

    func testCancelledQueuedDeletePerformsNoFenceOrBackendMutation() async throws {
        let allItemsBarrier = OneShotSnapshotBarrier()
        let publisher = SnapshotPublisherSpy()
        let backend = SnapshotLibraryFake(items: [revision(1)], allItemsBarrier: allItemsBarrier)
        let gate = installedGate(publisher: publisher, backend: backend)
        let refresh = Task { try await gate.refreshKeyboardSnapshot() }
        await allItemsBarrier.waitUntilEntered()
        let queuedDelete = Task { try await gate.delete(itemID: self.uuid(1)) }
        await waitForSnapshotOperationRequest(2, gate: gate)
        queuedDelete.cancel()
        await allItemsBarrier.release()
        try await refresh.value

        await XCTAssertThrowsCancellationError(try await queuedDelete.value)
        XCTAssertEqual(publisher.armCount, 1)
        let deleteCount = await backend.deleteCount
        XCTAssertEqual(deleteCount, 0)
    }

    func testCancellationAfterDestructiveMutationStillCompletesSafePublication() async throws {
        let deleteBarrier = SnapshotBarrier()
        let publisher = SnapshotPublisherSpy()
        let backend = SnapshotLibraryFake(items: [revision(1)], deleteBarrier: deleteBarrier)
        let gate = installedGate(publisher: publisher, backend: backend)
        let deletion = Task { try await gate.delete(itemID: uuid(1)) }
        await deleteBarrier.waitUntilEntered()

        deletion.cancel()
        await deleteBarrier.release()

        _ = try await deletion.value
        XCTAssertEqual(publisher.destructivePublicationCount, 1)
        XCTAssertFalse(publisher.fenceArmed)
        XCTAssertEqual(publisher.publishedItemIDs.last, [])
    }

    func testResetImmediatelyPublishesEmptySnapshot() async throws {
        let publisher = SnapshotPublisherSpy()
        let backend = SnapshotLibraryFake(items: [revision(1)])
        let gate = PhonePinnedLibraryGate(snapshotPublisher: publisher)
        let unlock = gate.beginUnlock()
        XCTAssertTrue(gate.install(backend, for: unlock, generation: 1))

        _ = try await gate.advanceResetGeneration()

        XCTAssertEqual(publisher.publishedItemIDs.last, [])
        XCTAssertEqual(publisher.generations.last, 2)
    }

    func testExplicitRefreshCannotRepublishPreDeletePlaintextAfterDeleteMutates() async throws {
        let barrier = OneShotSnapshotBarrier()
        let publisher = SnapshotPublisherSpy(monitoredStaleItemID: uuid(1))
        let backend = SnapshotLibraryFake(
            items: [revision(1)],
            allItemsBarrier: barrier,
            onDestructiveMutation: { await MainActor.run { publisher.markDestructiveMutation() } }
        )
        let gate = installedGate(publisher: publisher, backend: backend)
        let refresh = Task { try await gate.refreshKeyboardSnapshot() }
        await barrier.waitUntilEntered()

        let deletion = Task { try await gate.delete(itemID: uuid(1)) }
        await Task.yield()
        XCTAssertFalse(publisher.destructiveMutationOccurred)
        await barrier.release()

        _ = try await refresh.value
        _ = try await deletion.value
        XCTAssertFalse(publisher.stalePublicationDetected)
    }

    func testExplicitRefreshCannotRepublishPreResetPlaintextAfterResetMutates() async throws {
        let barrier = OneShotSnapshotBarrier()
        let publisher = SnapshotPublisherSpy(monitoredStaleItemID: uuid(1))
        let backend = SnapshotLibraryFake(
            items: [revision(1)],
            allItemsBarrier: barrier,
            onDestructiveMutation: { await MainActor.run { publisher.markDestructiveMutation() } }
        )
        let gate = installedGate(publisher: publisher, backend: backend)
        let refresh = Task { try await gate.refreshKeyboardSnapshot() }
        await barrier.waitUntilEntered()

        let reset = Task { try await gate.advanceResetGeneration() }
        await Task.yield()
        XCTAssertFalse(publisher.destructiveMutationOccurred)
        await barrier.release()

        _ = try await refresh.value
        _ = try await reset.value
        XCTAssertFalse(publisher.stalePublicationDetected)
    }

    func testExplicitRefreshCannotRepublishPreTombstonePlaintextAfterRemoteDeleteMutates() async throws {
        let barrier = OneShotSnapshotBarrier()
        let publisher = SnapshotPublisherSpy(monitoredStaleItemID: uuid(1))
        let backend = SnapshotLibraryFake(
            items: [revision(1)],
            allItemsBarrier: barrier,
            onDestructiveMutation: { await MainActor.run { publisher.markDestructiveMutation() } }
        )
        let gate = installedGate(publisher: publisher, backend: backend)
        let refresh = Task { try await gate.refreshKeyboardSnapshot() }
        await barrier.waitUntilEntered()
        let tombstone = PinnedTombstone(
            itemID: uuid(1), tombstoneID: UUID(), libraryGeneration: 1, itemGeneration: 2,
            modifiedAt: Date(timeIntervalSince1970: 100), deviceID: "remote"
        )

        let remoteDelete = Task { try await gate.applyRemote(.tombstone(tombstone)) }
        await Task.yield()
        XCTAssertFalse(publisher.destructiveMutationOccurred)
        await barrier.release()

        _ = try await refresh.value
        _ = try await remoteDelete.value
        XCTAssertFalse(publisher.stalePublicationDetected)
    }

    func testShareEnsureUsesInboxIDAndPublishesOnlyForNewInsert() async throws {
        let publisher = SnapshotPublisherSpy()
        let backend = SnapshotLibraryFake(items: [])
        let gate = PhonePinnedLibraryGate(snapshotPublisher: publisher)
        let unlock = gate.beginUnlock()
        XCTAssertTrue(gate.install(
            backend,
            textTransformer: TextTransformer { Data($0) },
            for: unlock,
            generation: 1
        ))
        let item = try ShareInboxItem.make(
            id: uuid(77),
            createdAt: Date(timeIntervalSince1970: 100),
            kind: .text,
            data: Data("shared".utf8)
        )

        let inserted = try await gate.ensurePinnedShareItem(item)
        let retried = try await gate.ensurePinnedShareItem(item)

        guard case let .inserted(revision) = inserted else { return XCTFail("Expected insert") }
        XCTAssertEqual(revision.itemID, item.id)
        XCTAssertEqual(revision.payload.representations.map(\.originalBytes), [item.data])
        XCTAssertEqual(revision.payload.representations.map(\.keyedDigest), [item.data])
        XCTAssertEqual(retried, .alreadyPresent)
        let backendItems = try await backend.allItems()
        XCTAssertEqual(backendItems.map(\.itemID), [item.id])
        XCTAssertEqual(publisher.publishCount, 1)
    }

    func testShareEnsureRevalidatesForgedItemBeforeResolutionOrStoreMutation() async throws {
        let publisher = SnapshotPublisherSpy()
        let backend = SnapshotLibraryFake(items: [])
        let gate = PhonePinnedLibraryGate(snapshotPublisher: publisher)
        let unlock = gate.beginUnlock()
        XCTAssertTrue(gate.install(
            backend,
            textTransformer: TextTransformer { Data($0) },
            for: unlock,
            generation: 1
        ))
        let valid = try ShareInboxItem.make(
            id: uuid(78),
            createdAt: Date(timeIntervalSince1970: 100),
            kind: .text,
            data: Data("shared".utf8)
        )
        let forged = ShareInboxItem(
            schemaVersion: valid.schemaVersion,
            id: valid.id,
            createdAt: valid.createdAt,
            kind: valid.kind,
            data: valid.data,
            digest: String(repeating: "0", count: 64)
        )

        do {
            _ = try await gate.ensurePinnedShareItem(forged)
            XCTFail("Expected validation failure")
        } catch {}

        let backendItems = try await backend.allItems()
        XCTAssertEqual(backendItems.count, 0)
        XCTAssertEqual(publisher.publishCount, 0)
    }

    private func installedGate(
        publisher: SnapshotPublisherSpy,
        backend: SnapshotLibraryFake
    ) -> PhonePinnedLibraryGate {
        let gate = PhonePinnedLibraryGate(snapshotPublisher: publisher)
        let unlock = gate.beginUnlock()
        XCTAssertTrue(gate.install(backend, for: unlock, generation: 1))
        return gate
    }

    private func waitForSnapshotOperationRequest(_ count: Int, gate: PhonePinnedLibraryGate) async {
        while gate.snapshotOperationRequestCount < count {
            await Task.yield()
        }
    }

    private func revision(_ suffix: Int) -> PinnedRevision {
        PinnedRevision(
            itemID: uuid(suffix), revisionID: UUID(), libraryGeneration: 1, itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(suffix)), deviceID: "test", payload: payload(suffix)
        )
    }

    private func payload(_ suffix: Int) -> PinPayload {
        PinPayload(
            representations: [], canonicalInsertionString: "Insert \(suffix)", title: "Title \(suffix)",
            contentKind: .plainText, category: .everyday
        )
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}

@MainActor
private final class DeletionRecoveryState {
    private var root: URL?
    private var model: ImportExportViewModel?
    private var trackedURL: URL?
    private var orphanURLs: [URL] = []
    private(set) var wasPurgedBeforeBackendMutation = false

    var isEmpty: Bool {
        guard let model else { return false }
        return model.importPreview == nil &&
            model.temporaryShareURL == nil &&
            [trackedURL].compactMap { $0 }.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } &&
            orphanURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
    }

    deinit {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func populate(for library: any PinnedLibrary) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = ImportExportViewModel(library: library, representations: { _ in [] }, temporaryDirectory: root)
        let item = PinnedRevision(
            itemID: UUID(), revisionID: UUID(), libraryGeneration: 1, itemGeneration: 1,
            modifiedAt: Date(), deviceID: "recovery-test", payload: PinPayload(
                representations: [.init(kind: .plainText, originalBytes: Data("shared".utf8), keyedDigest: Data([1]))],
                canonicalInsertionString: "shared", title: "Shared", contentKind: .plainText, category: nil
            )
        )
        try model.acceptImportedData(Data("preview".utf8), declaredType: .plainText)
        let trackedURL = try model.prepareTemporaryShare(of: item, as: .plainText)
        let orphanURLs = [
            root.appendingPathComponent("00000000-0000-0000-0000-000000000101.txt"),
            root.appendingPathComponent("00000000-0000-0000-0000-000000000102.txt"),
        ]
        for orphanURL in orphanURLs {
            try Data("orphan".utf8).write(to: orphanURL)
        }
        self.root = root
        self.model = model
        self.trackedURL = trackedURL
        self.orphanURLs = orphanURLs
    }

    func purge() throws {
        try model?.purgeDeletionRecoveryContent()
    }

    func recordBackendMutation() {
        wasPurgedBeforeBackendMutation = isEmpty
    }
}

@MainActor
private final class UnremovedDeletionRecoveryState {
    private var root: URL?
    private var model: ImportExportViewModel?
    private var orphanURL: URL?

    var orphanStillExists: Bool {
        orphanURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    deinit {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func populate(for library: any PinnedLibrary) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = ImportExportViewModel(
            library: library,
            representations: { _ in [] },
            temporaryDirectory: root,
            removeTemporaryItem: { _ in }
        )
        let orphanURL = root.appendingPathComponent("00000000-0000-0000-0000-000000000201.txt")
        try Data("orphan".utf8).write(to: orphanURL)
        try model.acceptImportedData(Data("preview".utf8), declaredType: .plainText)
        self.root = root
        self.model = model
        self.orphanURL = orphanURL
    }

    func purge() throws {
        try model?.purgeDeletionRecoveryContent()
    }
}

private struct SensitivePurgeFailure: Error, LocalizedError {
    let plaintext: String

    init(_ plaintext: String) {
        self.plaintext = plaintext
    }

    var errorDescription: String? {
        plaintext
    }
}

private final class SnapshotClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) {
        value = now
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func set(_ value: Date) {
        lock.withLock { self.value = value }
    }
}

@MainActor
private final class SnapshotPublisherSpy: KeyboardSnapshotPublishing {
    var failPublish = false
    var failArm = false
    var failDestructivePublication = false
    private let monitoredStaleItemID: UUID?
    private(set) var publishedItemIDs: [Set<UUID>] = []
    private(set) var generations: [Int64] = []
    private(set) var lastCloudRefreshes: [Date?] = []
    private(set) var armCount = 0
    private(set) var destructivePublicationCount = 0
    private(set) var fenceArmed = false
    private(set) var destructiveMutationOccurred = false
    private(set) var stalePublicationDetected = false

    init(monitoredStaleItemID: UUID? = nil) {
        self.monitoredStaleItemID = monitoredStaleItemID
    }

    var publishCount: Int {
        publishedItemIDs.count
    }

    func publish(items: [PinnedRevision], generation: Int64, lastCloudRefresh: Date?) throws {
        if failPublish {
            throw SnapshotTestFailure.injected
        }
        let itemIDs = Set(items.map(\.itemID))
        if destructiveMutationOccurred,
           let monitoredStaleItemID,
           itemIDs.contains(monitoredStaleItemID)
        {
            stalePublicationDetected = true
        }
        publishedItemIDs.append(itemIDs)
        generations.append(generation)
        lastCloudRefreshes.append(lastCloudRefresh)
    }

    func armRevocationFence() throws {
        armCount += 1
        if failArm {
            throw KeyboardSnapshotPublisherError.revocationFenceUnavailable
        }
        fenceArmed = true
    }

    func completeDestructivePublication(
        items: [PinnedRevision],
        generation: Int64,
        lastCloudRefresh: Date?
    ) throws {
        destructivePublicationCount += 1
        if failDestructivePublication {
            throw KeyboardSnapshotPublisherError.publicationFailed
        }
        try publish(items: items, generation: generation, lastCloudRefresh: lastCloudRefresh)
        fenceArmed = false
    }

    func clear(generation _: Int64) throws {
        try armRevocationFence()
        fenceArmed = false
    }

    func markDestructiveMutation() {
        destructiveMutationOccurred = true
    }
}

private actor SnapshotLibraryFake: ShareFixedIDPinnedLibrary {
    private var items: [PinnedRevision]
    private var generation: Int64 = 1
    private let mutationBarrier: SnapshotBarrier?
    private let allItemsBarrier: OneShotSnapshotBarrier?
    private let deleteBarrier: SnapshotBarrier?
    private let onDestructiveMutation: @Sendable () async -> Void
    private(set) var deleteCount = 0
    private(set) var applyRemoteCount = 0
    private(set) var resetCount = 0

    init(
        items: [PinnedRevision],
        mutationBarrier: SnapshotBarrier? = nil,
        allItemsBarrier: OneShotSnapshotBarrier? = nil,
        deleteBarrier: SnapshotBarrier? = nil,
        onDestructiveMutation: @escaping @Sendable () async -> Void = {}
    ) {
        self.items = items
        self.mutationBarrier = mutationBarrier
        self.allItemsBarrier = allItemsBarrier
        self.deleteBarrier = deleteBarrier
        self.onDestructiveMutation = onDestructiveMutation
    }

    func allItems() async throws -> [PinnedRevision] {
        let snapshot = items
        await allItemsBarrier?.suspendOnce()
        return snapshot
    }

    func search(_: String, limit: Int) async throws -> [PinnedRevision] {
        Array(items.prefix(limit))
    }

    func pin(_ payload: PinPayload) async throws -> PinnedRevision {
        let revision = PinnedRevision(
            itemID: UUID(), revisionID: UUID(), libraryGeneration: generation, itemGeneration: 1,
            modifiedAt: Date(), deviceID: "test", payload: payload
        )
        items.append(revision)
        await mutationBarrier?.suspend()
        return revision
    }

    func ensurePinned(payload: PinPayload, itemID: UUID) async throws -> SharePinEnsureResult {
        if let existing = items.first(where: { $0.itemID == itemID }) {
            return existing.payload == payload ? .alreadyPresent : .conflict
        }
        let revision = PinnedRevision(
            itemID: itemID, revisionID: UUID(), libraryGeneration: generation, itemGeneration: 1,
            modifiedAt: Date(), deviceID: "test", payload: payload
        )
        items.append(revision)
        return .inserted(revision)
    }

    func revise(itemID: UUID, payload: PinPayload) async throws -> PinnedRevision {
        let current = items.first { $0.itemID == itemID }!
        let revision = PinnedRevision(
            itemID: itemID, revisionID: UUID(), libraryGeneration: generation,
            itemGeneration: current.itemGeneration + 1, modifiedAt: Date(), deviceID: "test", payload: payload
        )
        items.removeAll { $0.itemID == itemID }
        items.append(revision)
        return revision
    }

    func delete(itemID: UUID) async throws -> PinnedTombstone {
        deleteCount += 1
        let current = items.first { $0.itemID == itemID }!
        items.removeAll { $0.itemID == itemID }
        await onDestructiveMutation()
        await deleteBarrier?.suspend()
        return PinnedTombstone(
            itemID: itemID, tombstoneID: UUID(), libraryGeneration: generation,
            itemGeneration: current.itemGeneration + 1, modifiedAt: Date(), deviceID: "test"
        )
    }

    func applyRemote(_ mutation: PinnedMutation) async throws -> MergeOutcome {
        applyRemoteCount += 1
        switch mutation {
        case let .tombstone(tombstone):
            items.removeAll { $0.itemID == tombstone.itemID }
            await onDestructiveMutation()
        case .reset:
            items = []
            await onDestructiveMutation()
        case let .revision(revision):
            items.removeAll { $0.itemID == revision.itemID }
            items.append(revision)
        }
        return .inserted(mutation.mutationID)
    }

    func advanceResetGeneration() async throws -> LibraryResetGeneration {
        resetCount += 1
        generation += 1
        items = []
        await onDestructiveMutation()
        return LibraryResetGeneration(resetID: UUID(), generation: generation, modifiedAt: Date(), deviceID: "test")
    }
}

private actor OneShotSnapshotBarrier {
    private var isArmed = true
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendOnce() async {
        guard isArmed else { return }
        isArmed = false
        entered = true
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor SnapshotBarrier {
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        releaseContinuation?.resume(); releaseContinuation = nil
    }
}

private enum SnapshotTestFailure: Error { case injected }

@MainActor
private func XCTAssertThrowsPublisherError<T>(
    _ expression: @autoclosure () async throws -> T,
    expected: KeyboardSnapshotPublisherError
) async {
    do {
        _ = try await expression()
        XCTFail("Expected publisher error")
    } catch {
        XCTAssertEqual(error as? KeyboardSnapshotPublisherError, expected)
    }
}

@MainActor
private func XCTAssertThrowsSnapshotError<T>(_ expression: @autoclosure () async throws -> T) async {
    do {
        _ = try await expression()
        XCTFail("Expected protected-data error")
    } catch {
        XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectedDataUnavailable)
    }
}

@MainActor
private func XCTAssertThrowsCancellationError<T>(_ expression: @autoclosure () async throws -> T) async {
    do {
        _ = try await expression()
        XCTFail("Expected cancellation error")
    } catch {
        XCTAssertTrue(error is CancellationError)
    }
}
