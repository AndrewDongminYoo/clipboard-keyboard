import ClipboardCore
@testable import ClipboardKeyboardiOS
import Foundation
import XCTest

@MainActor
final class CloudDeletionCoordinatorTests: XCTestCase {
    func testIntentRuntimeUsesInstalledGateForImmediateResetAndFinalizesContentFreeRequest() async throws {
        let calls = CloudDeletionCallLog()
        let store = InMemoryCloudDeletionRequestStore()
        let library = CloudDeletionLibraryFake(items: [revision(10)])
        let engine = PhonePinnedSyncEngine(makeTransport: { CloudDeletionTransport() })
        let dependencies = IntentDependencies(
            gate: PhonePinnedLibraryGate(),
            readiness: { _ in
                IntentReadyBackend(
                    library: library,
                    textTransformer: TextTransformer { $0 },
                    generation: 0,
                    close: { await engine.lock() },
                    syncEngine: engine,
                    cloudDeletionServices: CloudDeletionServices(
                        deleteRemoteContentKeepingReset: { reset in
                            await calls.append("remote-\(reset.generation)")
                        },
                        resetSyncState: { await calls.append("reset-state") },
                        acknowledgeReset: { id in await calls.append("ack-\(id.uuidString)") }
                    )
                )
            },
            protectedDataAvailable: true,
            cloudDeletionRequestStore: store,
            cloudDeletionAuthenticate: { await calls.append("authenticate") },
            pasteboardWrite: { _ in }
        )

        try await dependencies.ensureReady()
        try await dependencies.authenticateAndDeleteCloudData()

        let remaining = try await dependencies.gate.allItems()
        let reset = await library.latestReset
        let recordedCalls = await calls.snapshot()
        let resetID = try XCTUnwrap(reset).resetID.uuidString
        XCTAssertEqual(remaining, [])
        XCTAssertEqual(reset?.generation, 1)
        XCTAssertEqual(recordedCalls.first, "authenticate")
        XCTAssertTrue(recordedCalls.contains("remote-1"))
        XCTAssertTrue(recordedCalls.contains("reset-state"))
        XCTAssertTrue(recordedCalls.contains("ack-\(resetID)"))
        XCTAssertEqual(dependencies.cloudDeletionCoordinator.status, .completed)
        XCTAssertNil(store.request)
    }

    func testAuthenticationFailureCannotCreateResetOrContactCloud() async {
        let calls = CloudDeletionCallLog()
        let store = InMemoryCloudDeletionRequestStore()
        let coordinator = CloudDeletionCoordinator(
            requestStore: store,
            authenticate: {
                await calls.append("authenticate")
                throw TestFailure.expected
            },
            backend: {
                XCTFail("Backend must not be requested before authentication")
                return self.deletionBackend(calls: calls, reset: self.reset(1))
            }
        )

        await XCTAssertThrowsErrorAsync(try await coordinator.authenticateAndDeleteCloudData())

        XCTAssertEqual(coordinator.status, .authenticationFailed)
        XCTAssertFalse(coordinator.hasPendingRequest)
        let recordedCalls = await calls.snapshot()
        XCTAssertEqual(recordedCalls, ["authenticate"])
    }

    func testLocalResetAndPendingMarkerPrecedeRemoteConfirmation() async throws {
        let calls = CloudDeletionCallLog()
        let remoteBarrier = CloudDeletionBarrier()
        let store = InMemoryCloudDeletionRequestStore()
        let expectedReset = reset(2)
        let coordinator = CloudDeletionCoordinator(
            requestStore: store,
            authenticate: { await calls.append("authenticate") },
            backend: {
                CloudDeletionBackend(
                    prepare: { await calls.append("prepare") },
                    advanceReset: {
                        await calls.append("advance")
                        return expectedReset
                    },
                    deleteRemoteContentKeepingReset: { reset in
                        XCTAssertEqual(reset, expectedReset)
                        await calls.append("remote")
                        await remoteBarrier.enterAndWait()
                    },
                    resetSyncState: { await calls.append("reset-state") },
                    acknowledgeReset: { id in
                        XCTAssertEqual(id, expectedReset.resetID)
                        await calls.append("acknowledge")
                    },
                    didComplete: { await calls.append("complete") }
                )
            }
        )

        let deletion = Task { try await coordinator.authenticateAndDeleteCloudData() }
        await remoteBarrier.waitUntilEntered()

        XCTAssertEqual(coordinator.status, .pendingCloudConfirmation)
        XCTAssertEqual(store.request?.reset, expectedReset)
        let pendingCalls = await calls.snapshot()
        XCTAssertEqual(pendingCalls, ["authenticate", "prepare", "advance", "remote"])

        await remoteBarrier.release()
        try await deletion.value

        XCTAssertEqual(coordinator.status, .completed)
        XCTAssertFalse(coordinator.hasPendingRequest)
        let completedCalls = await calls.snapshot()
        XCTAssertEqual(
            completedCalls,
            ["authenticate", "prepare", "advance", "remote", "reset-state", "acknowledge", "complete"]
        )
    }

    func testRemoteFailureKeepsPendingResetAndRetryDoesNotAdvanceAgain() async throws {
        let calls = CloudDeletionCallLog()
        let attempts = CloudDeletionAttemptCounter()
        let store = InMemoryCloudDeletionRequestStore()
        let expectedReset = reset(3)
        let coordinator = CloudDeletionCoordinator(
            requestStore: store,
            authenticate: { await calls.append("authenticate") },
            backend: {
                CloudDeletionBackend(
                    prepare: { await calls.append("prepare") },
                    advanceReset: {
                        await calls.append("advance")
                        return expectedReset
                    },
                    deleteRemoteContentKeepingReset: { reset in
                        XCTAssertEqual(reset, expectedReset)
                        await calls.append("remote")
                        if await attempts.next() == 1 {
                            throw TestFailure.expected
                        }
                    },
                    resetSyncState: { await calls.append("reset-state") },
                    acknowledgeReset: { _ in await calls.append("acknowledge") },
                    didComplete: { await calls.append("complete") }
                )
            }
        )

        await XCTAssertThrowsErrorAsync(try await coordinator.authenticateAndDeleteCloudData())

        XCTAssertEqual(coordinator.status, .pendingCloudConfirmation)
        XCTAssertEqual(store.request?.reset, expectedReset)

        try await coordinator.authenticateAndDeleteCloudData()

        XCTAssertEqual(coordinator.status, .completed)
        let authenticationCount = await calls.count(of: "authenticate")
        let prepareCount = await calls.count(of: "prepare")
        let advanceCount = await calls.count(of: "advance")
        let remoteCount = await calls.count(of: "remote")
        XCTAssertEqual(authenticationCount, 2)
        XCTAssertEqual(prepareCount, 2)
        XCTAssertEqual(advanceCount, 1)
        XCTAssertEqual(remoteCount, 2)
        XCTAssertFalse(coordinator.hasPendingRequest)
    }

    private func deletionBackend(
        calls: CloudDeletionCallLog,
        reset: LibraryResetGeneration
    ) -> CloudDeletionBackend {
        CloudDeletionBackend(
            prepare: { await calls.append("prepare") },
            advanceReset: { reset },
            deleteRemoteContentKeepingReset: { _ in await calls.append("remote") },
            resetSyncState: {},
            acknowledgeReset: { _ in },
            didComplete: {}
        )
    }

    private func reset(_ suffix: Int) -> LibraryResetGeneration {
        LibraryResetGeneration(
            resetID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!,
            generation: Int64(suffix),
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(suffix)),
            deviceID: "test-device"
        )
    }

    private func revision(_ suffix: Int) -> PinnedRevision {
        let text = "value-\(suffix)"
        return PinnedRevision(
            itemID: UUID(),
            revisionID: UUID(),
            libraryGeneration: 0,
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(suffix)),
            deviceID: "test-device",
            payload: PinPayload(
                representations: [
                    ClipRepresentation(
                        kind: .plainText,
                        originalBytes: Data(text.utf8),
                        keyedDigest: Data([1])
                    ),
                ],
                canonicalInsertionString: text,
                title: text,
                contentKind: .plainText,
                category: nil
            )
        )
    }
}

private enum TestFailure: Error {
    case expected
}

@MainActor
private final class InMemoryCloudDeletionRequestStore: CloudDeletionRequestPersisting {
    var request: CloudDeletionRequest?

    func load() -> CloudDeletionRequest? {
        request
    }

    func save(_ request: CloudDeletionRequest) {
        self.request = request
    }

    func clear() {
        request = nil
    }
}

private actor CloudDeletionCallLog {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }

    func count(of value: String) -> Int {
        values.count { $0 == value }
    }
}

private actor CloudDeletionAttemptCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

private actor CloudDeletionLibraryFake: PinnedLibrary {
    private var items: [PinnedRevision]
    private(set) var latestReset: LibraryResetGeneration?

    init(items: [PinnedRevision]) {
        self.items = items
    }

    func allItems() async throws -> [PinnedRevision] {
        items
    }

    func search(_: String, limit _: Int) async throws -> [PinnedRevision] {
        items
    }

    func pin(_ payload: PinPayload) async throws -> PinnedRevision {
        let revision = PinnedRevision(
            itemID: UUID(), revisionID: UUID(), libraryGeneration: 0, itemGeneration: 1,
            modifiedAt: Date(), deviceID: "test", payload: payload
        )
        items.append(revision)
        return revision
    }

    func revise(itemID: UUID, payload: PinPayload) async throws -> PinnedRevision {
        let revision = PinnedRevision(
            itemID: itemID, revisionID: UUID(), libraryGeneration: 0, itemGeneration: 2,
            modifiedAt: Date(), deviceID: "test", payload: payload
        )
        items.removeAll { $0.itemID == itemID }
        items.append(revision)
        return revision
    }

    func delete(itemID: UUID) async throws -> PinnedTombstone {
        items.removeAll { $0.itemID == itemID }
        return PinnedTombstone(
            itemID: itemID, tombstoneID: UUID(), libraryGeneration: 0, itemGeneration: 2,
            modifiedAt: Date(), deviceID: "test"
        )
    }

    func applyRemote(_ mutation: PinnedMutation) async throws -> MergeOutcome {
        var replica = PinnedReplica(state: PinnedReplicaState(primaryRevisions: items))
        let outcome = replica.apply(mutation)
        items = replica.state.primaryRevisions
        return outcome
    }

    func advanceResetGeneration() async throws -> LibraryResetGeneration {
        let reset = LibraryResetGeneration(
            resetID: UUID(), generation: 1, modifiedAt: Date(), deviceID: "test"
        )
        items = []
        latestReset = reset
        return reset
    }
}

private actor CloudDeletionTransport: PhonePinnedSyncTransport {
    func start(eventHandler _: @escaping @Sendable (PhonePinnedSyncEvent) async -> Void) async throws {}
    func fetch() async throws {}
    func send(_: [PinnedMutation]) async throws {}
    func cancel() async {}
}

private actor CloudDeletionBarrier {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
