import ClipboardCore
@testable import ClipboardKeyboardMac
import CloudKit
import CryptoKit
import Foundation
import XCTest

final class MacPinnedSyncEngineTests: XCTestCase {
    func testStartupSendAndJournalDrainNeverOverlap() async throws {
        let mutation = makeMutation(88)
        let barrier = MacSendBarrier()
        let fake = FakeMacSyncTransport(sendBarrier: barrier)
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { [mutation] }
        )
        let enabling = Task { try await engine.setEnabled(true) }
        await barrier.waitUntilEntered()

        await engine.localJournalDidChange()
        for _ in 0 ..< 100 {
            await Task.yield()
        }

        let sendsBeforeRelease = await fake.calls.filter { $0 == .send }.count
        XCTAssertEqual(sendsBeforeRelease, 1)
        await barrier.release()
        try await enabling.value
        await fake.waitUntilSendCount(2)
        let sendsAfterRelease = await fake.calls.filter { $0 == .send }.count
        XCTAssertEqual(sendsAfterRelease, 2)
    }

    func testRetryableInitialFetchKeepsEnabledSessionForRefreshSendAndAcknowledgement() async throws {
        let mutation = makeMutation(86)
        let journal = JournalBox([mutation])
        let fake = FakeMacSyncTransport(fetchErrors: [CKError(.networkUnavailable)])
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { await journal.pending },
            acknowledge: { await journal.acknowledge($0) }
        )

        do {
            try await engine.setEnabled(true)
            XCTFail("Expected retryable initial fetch failure")
        } catch {}

        let status = await engine.status
        let initialCalls = await fake.calls
        XCTAssertEqual(status, .pending)
        XCTAssertEqual(initialCalls, [.start, .fetch])

        try await engine.refresh()
        await engine.localJournalDidChange()
        await fake.waitUntilSendCount(1)
        await fake.emit(.sent([mutation.mutationID]))

        let calls = await fake.calls
        let pending = await journal.pending
        XCTAssertEqual(calls, [.start, .fetch, .fetch, .send])
        XCTAssertTrue(pending.isEmpty)
    }

    func testRetryablePreSessionStartReconnectsOnRefreshWithoutPreferenceToggle() async throws {
        let mutation = makeMutation(87)
        let journal = JournalBox([mutation])
        let fake = FakeMacSyncTransport(startErrors: [CKError(.networkUnavailable)])
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { await journal.pending }
        )

        do {
            try await engine.setEnabled(true)
            XCTFail("Expected retryable initial start failure")
        } catch {}

        try await engine.refresh()

        let calls = await fake.calls
        XCTAssertEqual(calls, [.start, .cancel, .start, .fetch, .send])
    }

    func testAccountUnavailableStartFailsClosedAndCancelsTransport() async {
        let fake = FakeMacSyncTransport(startError: MacPinnedSyncStartError.accountUnavailable)
        let engine = MacPinnedSyncEngine(makeTransport: { fake })

        do {
            try await engine.setEnabled(true)
            XCTFail("Expected account unavailable")
        } catch {}

        let status = await engine.status
        let calls = await fake.calls
        XCTAssertEqual(status, .accountUnavailable)
        XCTAssertEqual(calls, [.start, .cancel])
    }

    func testDirectFetchAuthenticationFailureMapsAccountUnavailableAndCancels() async {
        let fake = FakeMacSyncTransport(fetchError: CKError(.notAuthenticated))
        let engine = MacPinnedSyncEngine(makeTransport: { fake })

        do {
            try await engine.setEnabled(true)
            XCTFail("Expected account unavailable")
        } catch {}

        let status = await engine.status
        let calls = await fake.calls
        XCTAssertEqual(status, .accountUnavailable)
        XCTAssertEqual(calls, [.start, .fetch, .cancel])
    }

    func testFailedSaveNotAuthenticatedMapsAccountUnavailableWhileTemporaryUnavailableRetries() {
        let id = UUID()
        guard case .accountUnavailable = MacPinnedSyncEvent.failedSave(id: id, error: CKError(.notAuthenticated))
        else {
            return XCTFail("Expected account unavailable")
        }
        guard case .retryableFailure = MacPinnedSyncEvent.failedSave(
            id: id,
            error: CKError(.accountTemporarilyUnavailable)
        ) else {
            return XCTFail("Expected retryable failure")
        }
    }

    func testStateVaultBindsAccountAndRestoresEncryptedPayload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.encrypted")
        let key = SymmetricKey(data: Data(repeating: 3, count: 32))
        let store = MacSyncStateStore(fileURL: url, key: key)

        try await store.bind(accountIdentity: "account-a")
        try await store.saveRawState(Data([1, 2, 3]), accountIdentity: "account-a")

        let restored = try await MacSyncStateStore(fileURL: url, key: key).loadRawState(accountIdentity: "account-a")
        XCTAssertEqual(restored, Data([1, 2, 3]))
        await XCTAssertThrowsMacStateError(
            try await store.bind(accountIdentity: "account-b"),
            expected: .accountMismatch
        )
    }

    func testStateVaultFailsClosedForTamperAndWrongKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.encrypted")
        let key = SymmetricKey(data: Data(repeating: 4, count: 32))
        let store = MacSyncStateStore(fileURL: url, key: key)
        try await store.bind(accountIdentity: "account-a")
        var bytes = try Data(contentsOf: url)
        bytes[bytes.index(before: bytes.endIndex)] ^= 0xFF
        try bytes.write(to: url)

        await XCTAssertThrowsMacStateError(
            try await store.loadRawState(accountIdentity: "account-a"),
            expected: .authenticationFailed
        )
        let wrongKeyStore = MacSyncStateStore(
            fileURL: url,
            key: SymmetricKey(data: Data(repeating: 5, count: 32))
        )
        await XCTAssertThrowsMacStateError(
            try await wrongKeyStore.loadRawState(accountIdentity: "account-a"),
            expected: .authenticationFailed
        )
    }

    func testCancelWhileAccountResolutionIsSuspendedNeverCreatesOrStartsSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let barrier = MacAccountResolutionBarrier()
        let session = FakeMacCloudKitSession()
        let creationCount = MacCountBox()
        let transport = MacCloudKitTransport(
            stateStore: MacSyncStateStore(
                fileURL: directory.appendingPathComponent("state.encrypted"),
                key: SymmetricKey(data: Data(repeating: 9, count: 32))
            ),
            resolveAccount: {
                await barrier.resolve()
                return MacCloudAccountContext(accountIdentity: "account", container: nil)
            },
            makeSession: { _ in
                await creationCount.increment()
                return session
            }
        )

        let start = Task { try await transport.start { _ in } }
        await barrier.waitUntilEntered()
        await transport.cancel()
        await barrier.release()
        try await start.value

        let creations = await creationCount.value
        let calls = await session.calls
        XCTAssertEqual(creations, 0)
        XCTAssertEqual(calls, [])
    }

    func testDisabledFirstLaunchMakesZeroTransportCallsAndEnableStartsExplicitly() async throws {
        let fake = FakeMacSyncTransport()
        let engine = MacPinnedSyncEngine(makeTransport: { fake })

        var calls = await fake.calls
        XCTAssertEqual(calls, [])
        try await engine.setEnabled(true)
        calls = await fake.calls
        XCTAssertEqual(calls, [.start, .fetch])
    }

    func testDisabledPinJournalIsSentOnlyAfterEnableAndSuccessAcknowledgesExactID() async throws {
        let mutation = makeMutation(1)
        let fake = FakeMacSyncTransport()
        let journal = JournalBox([mutation])
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { await journal.pending },
            acknowledge: { await journal.acknowledge($0) }
        )

        await engine.localJournalDidChange()
        var calls = await fake.calls
        var pending = await journal.pending
        XCTAssertEqual(calls, [])
        XCTAssertEqual(pending, [mutation])
        try await engine.setEnabled(true)
        await fake.emit(.sent([mutation.mutationID]))
        await Task.yield()

        calls = await fake.calls
        pending = await journal.pending
        XCTAssertEqual(calls, [.start, .fetch, .send])
        XCTAssertEqual(pending, [])
    }

    func testRetryableAndTerminalFailuresRetainJournalAndDisableRejectsStaleCallback() async throws {
        let mutation = makeMutation(2)
        let fake = FakeMacSyncTransport()
        let journal = JournalBox([mutation])
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { await journal.pending },
            acknowledge: { await journal.acknowledge($0) }
        )
        try await engine.setEnabled(true)
        await fake.emit(.retryableFailure)
        var status = await engine.status
        XCTAssertEqual(status, .pending)
        await fake.emit(.terminalFailure(mutation.mutationID))
        status = await engine.status
        XCTAssertEqual(status, .unableToSyncFullItem)
        try await engine.setEnabled(false)
        await fake.emit(.sent([mutation.mutationID]))
        await Task.yield()

        let pending = await journal.pending
        status = await engine.status
        let calls = await fake.calls
        XCTAssertEqual(pending, [mutation])
        XCTAssertEqual(status, .disabled)
        XCTAssertEqual(calls, [.start, .fetch, .send, .cancel])
    }

    func testManualRefreshIsOutsideDelegateAndAccountChangeFailsClosed() async throws {
        let fake = FakeMacSyncTransport()
        let engine = MacPinnedSyncEngine(makeTransport: { fake })
        try await engine.setEnabled(true)
        try await engine.refresh()
        await fake.emit(.accountChanged)

        // Asserted without waiting: the teardown must complete before the event callback
        // returns, and it must never cancel the transport from inside that callback.
        let calls = await fake.calls
        XCTAssertEqual(calls, [.start, .fetch, .fetch, .release])
        let status = await engine.status
        XCTAssertEqual(status, .recoveryRequired)
    }

    /// Cancelling re-enters CKSyncEngine, and doing that while it is delivering an event
    /// traps the process. Deferring the cancel into a `Task` does not order it after the
    /// callback returns, so every callback-driven teardown must release the transport
    /// without ever cancelling it. Absence of `.cancel` is the property a fake can prove;
    /// ordering is not, which is why this asserts the call list rather than a timing.
    func testCallbackDrivenTeardownNeverCancelsTheTransport() async throws {
        for event in [MacPinnedSyncEvent.accountUnavailable, .accountChanged] {
            let fake = FakeMacSyncTransport()
            let engine = MacPinnedSyncEngine(makeTransport: { fake })
            try await engine.setEnabled(true)

            await fake.emit(event)

            let calls = await fake.calls
            XCTAssertEqual(calls, [.start, .fetch, .release])
            XCTAssertFalse(calls.contains(.cancel))
        }
    }

    func testRecoveryRequiresExplicitChoiceAndKeepLocalDoesNotRewriteOrRestart() async throws {
        let fake = FakeMacSyncTransport()
        let recovery = MacRecoveryCallBox()
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            requeueForRecovery: { await recovery.record("requeue") },
            resetSyncStateForRecovery: { await recovery.record("reset") }
        )
        try await engine.setEnabled(true)
        await fake.emit(.accountChanged)

        var calls = await fake.calls
        XCTAssertEqual(calls, [.start, .fetch, .release])
        var recoveryCalls = await recovery.calls
        XCTAssertEqual(recoveryCalls, [])

        await engine.keepLocalAndDisable()

        calls = await fake.calls
        recoveryCalls = await recovery.calls
        let status = await engine.status
        XCTAssertEqual(calls, [.start, .fetch, .release])
        XCTAssertEqual(recoveryCalls, [])
        XCTAssertEqual(status, .disabled)
    }

    func testExplicitReuploadOrdersRequeueResetStartFetchAndSend() async throws {
        let mutation = makeMutation(85)
        let journal = JournalBox()
        let order = MacRecoveryCallBox()
        let fake = FakeMacSyncTransport(
            onStart: { await order.record("start") },
            onFetch: { await order.record("fetch") },
            onSendAsync: { _ in await order.record("send") }
        )
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { await journal.pending },
            requeueForRecovery: {
                await order.record("requeue")
                await journal.append(mutation)
            },
            resetSyncStateForRecovery: { await order.record("reset") }
        )
        try await engine.setEnabled(true)
        await fake.emit(.accountChanged)
        await order.clear()

        try await engine.reuploadLocalPins()

        let calls = await order.calls
        XCTAssertEqual(calls, ["requeue", "reset", "start", "fetch", "send"])
    }

    func testRecoveryPreparationFailureAndStaleDuplicateActionsPerformNoCloudIO() async throws {
        let barrier = MacRecoveryBarrier()
        let fake = FakeMacSyncTransport()
        let recovery = MacRecoveryCallBox()
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            requeueForRecovery: {
                await recovery.record("requeue")
                try await barrier.suspend()
            },
            resetSyncStateForRecovery: { await recovery.record("reset") }
        )
        try await engine.setEnabled(true)
        await fake.emit(.accountChanged)

        let first = Task { try await engine.reuploadLocalPins() }
        await barrier.waitUntilEntered()
        try await engine.reuploadLocalPins()
        await engine.keepLocalAndDisable()
        await barrier.release(throwing: true)
        do { try await first.value } catch {}

        let calls = await fake.calls
        let recoveryCalls = await recovery.calls
        let status = await engine.status
        XCTAssertEqual(calls, [.start, .fetch, .release])
        XCTAssertEqual(recoveryCalls, ["requeue"])
        XCTAssertEqual(status, .disabled)
    }

    func testExplicitPinWhileDisabledPersistsJournalWithoutCreatingTransport() async throws {
        let (store, library, cleanup) = makeLibrary(notifier: {})
        defer { cleanup() }
        let fake = FakeMacSyncTransport()
        _ = MacPinnedSyncEngine(makeTransport: { fake })

        _ = try await library.pin(payload())

        let calls = await fake.calls
        let pending = try await store.load().pendingJournal.pending
        XCTAssertEqual(calls, [])
        XCTAssertEqual(pending.count, 1)
    }

    func testExplicitPinWhileEnabledSchedulesPendingSendAfterDurableJournal() async throws {
        let signal = TestMacSyncSignal()
        let (store, library, cleanup) = makeLibrary(notifier: { await signal.notify() })
        defer { cleanup() }
        let fake = FakeMacSyncTransport()
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { try await store.load().pendingJournal.pending }
        )
        await signal.install(engine)
        try await engine.setEnabled(true)

        _ = try await library.pin(payload())
        await fake.waitUntilSendCount(1)

        let calls = await fake.calls
        XCTAssertEqual(calls, [.start, .fetch, .send])
    }

    func testEnableFetchAppliesDuplicateRemoteMutationOnceAndPreservesLocalJournal() async throws {
        let local = makeMutation(7)
        let remote = makeMutation(8)
        let fake = FakeMacSyncTransport()
        let journal = JournalBox([local])
        let applied = AppliedMacMutationBox()
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { await journal.pending },
            applyRemote: { await applied.record($0) }
        )

        try await engine.setEnabled(true)
        await fake.emit(.fetched(remote))
        await fake.emit(.fetched(remote))
        await fake.emit(.fetchCompleted)

        let mutations = await applied.mutations
        let pending = await journal.pending
        let status = await engine.status
        XCTAssertEqual(mutations, [remote])
        XCTAssertEqual(pending, [local])
        XCTAssertEqual(status, .pending)
    }

    func testFailedRemoteApplyIsRetriedAndOnlySuccessfulDeliveryBecomesSeen() async throws {
        let remote = makeMutation(81)
        let fake = FakeMacSyncTransport()
        let applied = FailFirstMacMutationBox()
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            applyRemote: { try await applied.apply($0) }
        )

        try await engine.setEnabled(true)
        await fake.emit(.fetched(remote))
        await fake.emit(.fetched(remote))
        await fake.emit(.fetched(remote))

        let attempts = await applied.attempts
        let mutations = await applied.mutations
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(mutations, [remote])
    }

    func testSentPendingReadCannotOverwriteCompletedDisable() async throws {
        let pending = SuspendingMacPendingBox()
        let fake = FakeMacSyncTransport()
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { await pending.read() }
        )
        try await engine.setEnabled(true)
        await pending.arm()

        let event = Task { await fake.emit(.sent([UUID()])) }
        await pending.waitUntilEntered()
        try await engine.setEnabled(false)
        await pending.release()
        await event.value

        let status = await engine.status
        XCTAssertEqual(status, .disabled)
    }

    func testSentPendingReadCannotOverwriteCompletedAccountUnavailable() async throws {
        let pending = SuspendingMacPendingBox()
        let fake = FakeMacSyncTransport()
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { await pending.read() }
        )
        try await engine.setEnabled(true)
        await pending.arm()

        let sent = Task { await fake.emit(.sent([UUID()])) }
        await pending.waitUntilEntered()
        await fake.emit(.accountUnavailable)
        await pending.release()
        await sent.value

        let status = await engine.status
        XCTAssertEqual(status, .accountUnavailable)
    }

    func testFailedOldEventCannotOverwriteDisableStatus() async throws {
        let apply = SuspendingFailingMacApply()
        let fake = FakeMacSyncTransport()
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            applyRemote: { try await apply.run($0) }
        )
        try await engine.setEnabled(true)
        let mutation = makeMutation(82)

        let event = Task { await fake.emit(.fetched(mutation)) }
        await apply.waitUntilEntered()
        let disable = Task { try await engine.setEnabled(false) }
        await waitForMacStatus(.disabled, engine: engine)
        await apply.release()
        try await disable.value
        await event.value

        let status = await engine.status
        XCTAssertEqual(status, .disabled)
    }

    func testJournalNotificationReturnsBeforeBlockedNetworkSend() async throws {
        let mutation = makeMutation(9)
        let barrier = MacSendBarrier()
        let fake = FakeMacSyncTransport(sendBarrier: barrier)
        let journal = JournalBox()
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { await journal.pending }
        )
        try await engine.setEnabled(true)
        await journal.append(mutation)

        await engine.localJournalDidChange()
        await barrier.waitUntilEntered()

        let pending = await journal.pending
        XCTAssertEqual(pending, [mutation])
        await barrier.release()
    }

    func testJournalNotificationDuringSendDrainsTheSecondPendingBatch() async throws {
        let first = makeMutation(83)
        let second = makeMutation(84)
        let barrier = MacSendBarrier()
        let secondSend = expectation(description: "second pending batch sent")
        let fake = FakeMacSyncTransport(
            sendBarrier: barrier,
            onSend: {
                count in if count == 2 {
                    secondSend.fulfill()
                }
            }
        )
        let journal = JournalBox()
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { await journal.pending }
        )
        try await engine.setEnabled(true)

        await journal.append(first)
        await engine.localJournalDidChange()
        await barrier.waitUntilEntered()
        await journal.append(second)
        await engine.localJournalDidChange()
        await barrier.release()

        await fulfillment(of: [secondSend], timeout: 1)
        let batches = await fake.sentBatches
        XCTAssertEqual(batches, [[first], [first, second]])
    }

    func testDisableDuringPendingLookupPreventsLaterSend() async throws {
        let pending = PendingLookupMacBox()
        let fake = FakeMacSyncTransport()
        let engine = MacPinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { await pending.read() }
        )
        try await engine.setEnabled(true)
        await pending.arm(with: makeMutation(10))

        await engine.localJournalDidChange()
        await pending.waitUntilEntered()
        try await engine.setEnabled(false)
        await pending.release()
        await Task.yield()

        let calls = await fake.calls
        XCTAssertEqual(calls, [.start, .fetch, .cancel])
    }

    func testPartialAcknowledgementAndRestartReplayOnlyRemainingMutation() async throws {
        let first = makeMutation(11)
        let second = makeMutation(12)
        let journal = JournalBox([first, second])
        let firstTransport = FakeMacSyncTransport()
        let firstEngine = MacPinnedSyncEngine(
            makeTransport: { firstTransport },
            pendingMutations: { await journal.pending },
            acknowledge: { await journal.acknowledge($0) }
        )
        try await firstEngine.setEnabled(true)
        await firstTransport.emit(.sent([first.mutationID]))
        try await firstEngine.setEnabled(false)

        let secondTransport = FakeMacSyncTransport()
        let restarted = MacPinnedSyncEngine(
            makeTransport: { secondTransport },
            pendingMutations: { await journal.pending }
        )
        try await restarted.setEnabled(true)

        let remaining = await journal.pending
        let replayed = await secondTransport.sentBatches
        XCTAssertEqual(remaining, [second])
        XCTAssertEqual(replayed, [[second]])
    }

    private func makeMutation(_ suffix: Int) -> PinnedMutation {
        .reset(LibraryResetGeneration(
            resetID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!,
            generation: 1, modifiedAt: Date(timeIntervalSince1970: 1), deviceID: "mac"
        ))
    }

    private func makeLibrary(
        notifier: @escaping @Sendable () async -> Void
    ) -> (EncryptedMacPinnedStore, LocalMacPinnedLibrary, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = EncryptedMacPinnedStore(
            fileURL: directory.appendingPathComponent("pinned.encrypted"),
            key: SymmetricKey(data: Data(repeating: 8, count: 32))
        )
        return (
            store,
            LocalMacPinnedLibrary(store: store, deviceID: "mac", notifier: notifier),
            { try? FileManager.default.removeItem(at: directory) }
        )
    }

    private func payload() -> PinPayload {
        PinPayload(
            representations: [ClipRepresentation(
                kind: .plainText,
                originalBytes: Data("pinned".utf8),
                keyedDigest: Data([1])
            )],
            canonicalInsertionString: "pinned",
            title: "Pinned",
            contentKind: .plainText,
            category: nil
        )
    }
}

private func XCTAssertThrowsMacStateError<T>(
    _ expression: @autoclosure () async throws -> T,
    expected: MacSyncStateStoreError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected MacSyncStateStoreError", file: file, line: line)
    } catch let error as MacSyncStateStoreError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private actor TestMacSyncSignal {
    private var engine: MacPinnedSyncEngine?
    func install(_ engine: MacPinnedSyncEngine) {
        self.engine = engine
    }

    func notify() async {
        await engine?.localJournalDidChange()
    }
}

private actor MacRecoveryCallBox {
    private(set) var calls: [String] = []
    func record(_ call: String) {
        calls.append(call)
    }

    func clear() {
        calls.removeAll()
    }
}

private actor MacRecoveryBarrier {
    enum Failure: Error { case expected }

    private var entered = false
    private var shouldThrow = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async throws {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        if shouldThrow {
            throw Failure.expected
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release(throwing: Bool) {
        shouldThrow = throwing
        continuation?.resume()
        continuation = nil
    }
}

private actor MacAccountResolutionBarrier {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func resolve() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor MacCountBox {
    private(set) var value = 0
    func increment() {
        value += 1
    }
}

private actor FakeMacCloudKitSession: MacCloudKitSession {
    enum Call: Equatable { case prepareZone, fetch, send, cancel }
    private(set) var calls: [Call] = []

    func prepareZone() async throws {
        calls.append(.prepareZone)
    }

    func fetch() async throws {
        calls.append(.fetch)
    }

    func send(_: [PinnedMutation]) async throws {
        calls.append(.send)
    }

    func cancel() async {
        calls.append(.cancel)
    }
}

private actor JournalBox {
    var pending: [PinnedMutation]
    init(_ pending: [PinnedMutation] = []) {
        self.pending = pending
    }

    func acknowledge(_ ids: [UUID]) {
        pending.removeAll { ids.contains($0.mutationID) }
    }

    func append(_ mutation: PinnedMutation) {
        pending.append(mutation)
    }
}

private actor AppliedMacMutationBox {
    private(set) var mutations: [PinnedMutation] = []
    func record(_ mutation: PinnedMutation) {
        mutations.append(mutation)
    }
}

private actor FailFirstMacMutationBox {
    enum Failure: Error { case expected }

    private(set) var attempts = 0
    private(set) var mutations: [PinnedMutation] = []

    func apply(_ mutation: PinnedMutation) throws {
        attempts += 1
        if attempts == 1 {
            throw Failure.expected
        }
        mutations.append(mutation)
    }
}

private actor SuspendingMacPendingBox {
    private var armed = false
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func arm() {
        armed = true
    }

    func read() async -> [PinnedMutation] {
        guard armed else { return [] }
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return []
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SuspendingFailingMacApply {
    enum Failure: Error { case expected }

    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run(_: PinnedMutation) async throws {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        throw Failure.expected
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private func waitForMacStatus(_ expected: MacPinnedSyncStatus, engine: MacPinnedSyncEngine) async {
    while await engine.status != expected {
        await Task.yield()
    }
}

private actor MacSendBarrier {
    private var entered = false
    private var didSuspend = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        guard !didSuspend else { return }
        didSuspend = true
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor PendingLookupMacBox {
    private var mutation: PinnedMutation?
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func arm(with mutation: PinnedMutation) {
        self.mutation = mutation
    }

    func read() async -> [PinnedMutation] {
        guard let mutation else { return [] }
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return [mutation]
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor FakeMacSyncTransport: MacPinnedSyncTransport {
    enum Call: Equatable { case start, fetch, send, cancel, release }
    private(set) var calls: [Call] = []
    private(set) var sentBatches: [[PinnedMutation]] = []
    private var handler: (@Sendable (MacPinnedSyncEvent) async -> Void)?
    private let sendBarrier: MacSendBarrier?
    private let onSend: (@Sendable (Int) -> Void)?
    private let onStart: @Sendable () async -> Void
    private let onFetch: @Sendable () async -> Void
    private let onSendAsync: @Sendable ([PinnedMutation]) async -> Void
    private var startErrors: [Error]
    private var fetchErrors: [Error]

    init(
        sendBarrier: MacSendBarrier? = nil,
        onSend: (@Sendable (Int) -> Void)? = nil,
        onStart: @escaping @Sendable () async -> Void = {},
        onFetch: @escaping @Sendable () async -> Void = {},
        onSendAsync: @escaping @Sendable ([PinnedMutation]) async -> Void = { _ in },
        startError: Error? = nil,
        startErrors: [Error] = [],
        fetchError: Error? = nil,
        fetchErrors: [Error] = []
    ) {
        self.sendBarrier = sendBarrier
        self.onSend = onSend
        self.onStart = onStart
        self.onFetch = onFetch
        self.onSendAsync = onSendAsync
        self.startErrors = startError.map { [$0] } ?? startErrors
        self.fetchErrors = fetchError.map { [$0] } ?? fetchErrors
    }

    func start(eventHandler: @escaping @Sendable (MacPinnedSyncEvent) async -> Void) async throws {
        calls.append(.start)
        await onStart()
        if !startErrors.isEmpty {
            throw startErrors.removeFirst()
        }
        handler = eventHandler
    }

    func fetch() async throws {
        calls.append(.fetch)
        await onFetch()
        if !fetchErrors.isEmpty {
            throw fetchErrors.removeFirst()
        }
    }

    func send(_ mutations: [PinnedMutation]) async throws {
        calls.append(.send)
        sentBatches.append(mutations)
        onSend?(sentBatches.count)
        await onSendAsync(mutations)
        await sendBarrier?.suspend()
    }

    func cancel() async {
        calls.append(.cancel)
    }

    func releaseWithoutCancelling() async {
        calls.append(.release)
    }

    func emit(_ event: MacPinnedSyncEvent) async {
        await handler?(event)
    }

    func waitUntilSendCount(_ expected: Int) async {
        while calls.filter({ $0 == .send }).count < expected {
            await Task.yield()
        }
    }
}
