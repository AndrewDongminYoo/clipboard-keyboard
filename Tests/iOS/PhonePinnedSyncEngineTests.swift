import ClipboardCore
@testable import ClipboardKeyboardiOS
import CloudKit
import CryptoKit
import Foundation
import XCTest

final class PhonePinnedSyncEngineTests: XCTestCase {
    func testStartupSendAndJournalDrainNeverOverlap() async throws {
        let mutation = makePhoneMutation(50)
        let barrier = PhoneSendBarrier()
        let fake = FakePhoneSyncTransport(sendBarrier: barrier)
        let engine = PhonePinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { [mutation] }
        )
        let enabling = Task { try await engine.setEnabled(true) }
        await barrier.waitUntilEntered()

        await engine.localJournalDidChange()
        for _ in 0 ..< 100 {
            await Task.yield()
        }

        let sendsBeforeRelease = await fake.operationCounts.send
        XCTAssertEqual(sendsBeforeRelease, 1)
        await barrier.release()
        try await enabling.value
        await fake.waitUntilSendCount(2)
        let sendsAfterRelease = await fake.operationCounts.send
        XCTAssertEqual(sendsAfterRelease, 2)
    }

    func testRetryableInitialFetchKeepsEnabledSessionForRefreshSendAndAcknowledgement() async throws {
        let mutation = makePhoneMutation(48)
        let acknowledgements = PhoneAcknowledgementBox()
        let fake = FakePhoneSyncTransport(fetchErrors: [CKError(.networkUnavailable)])
        let engine = PhonePinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { [mutation] },
            acknowledge: { await acknowledgements.record($0) }
        )

        do {
            try await engine.setEnabled(true)
            XCTFail("Expected retryable initial fetch failure")
        } catch {}

        let status = await engine.status
        XCTAssertEqual(status, .pending)
        var counts = await fake.operationCounts
        XCTAssertEqual(counts.start, 1)
        XCTAssertEqual(counts.fetch, 1)
        XCTAssertEqual(counts.send, 0)
        XCTAssertEqual(counts.cancel, 0)

        try await engine.refresh()
        await engine.localJournalDidChange()
        await fake.waitUntilSendCount(1)
        await fake.emit(.sent([mutation.mutationID]))

        counts = await fake.operationCounts
        let acknowledged = await acknowledgements.ids
        XCTAssertEqual(counts.start, 1)
        XCTAssertEqual(counts.fetch, 2)
        XCTAssertEqual(counts.send, 1)
        XCTAssertEqual(counts.cancel, 0)
        XCTAssertEqual(acknowledged, [mutation.mutationID])
    }

    func testRetryablePreSessionStartReconnectsOnRefreshWithoutPreferenceToggle() async throws {
        let mutation = makePhoneMutation(49)
        let fake = FakePhoneSyncTransport(startErrors: [CKError(.networkUnavailable)])
        let engine = PhonePinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { [mutation] }
        )

        do {
            try await engine.setEnabled(true)
            XCTFail("Expected retryable initial start failure")
        } catch {}

        try await engine.refresh()

        let counts = await fake.operationCounts
        XCTAssertEqual(counts.start, 2)
        XCTAssertEqual(counts.fetch, 1)
        XCTAssertEqual(counts.send, 1)
        XCTAssertEqual(counts.cancel, 1)
    }

    func testAccountUnavailableStartMapsStatusAndCancelsTransport() async {
        let fake = FakePhoneSyncTransport(startError: PhonePinnedSyncStartError.accountUnavailable)
        let engine = PhonePinnedSyncEngine(makeTransport: { fake })

        do {
            try await engine.setEnabled(true)
            XCTFail("Expected account unavailable")
        } catch {}

        let status = await engine.status
        let cancelCount = await fake.cancelCount
        XCTAssertEqual(status, .accountUnavailable)
        XCTAssertEqual(cancelCount, 1)
    }

    func testDirectSendAuthenticationFailureMapsAccountUnavailableAndCancels() async {
        let mutation = makePhoneMutation(46)
        let fake = FakePhoneSyncTransport(sendError: CKError(.notAuthenticated))
        let engine = PhonePinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { [mutation] }
        )

        do {
            try await engine.setEnabled(true)
            XCTFail("Expected account unavailable")
        } catch {}

        let status = await engine.status
        let cancelCount = await fake.cancelCount
        XCTAssertEqual(status, .accountUnavailable)
        XCTAssertEqual(cancelCount, 1)
    }

    func testFailedSaveNotAuthenticatedMapsAccountUnavailableWhileTemporaryUnavailableRetries() {
        let id = UUID()
        guard case .accountUnavailable = PhonePinnedSyncEvent.failedSave(id: id, error: CKError(.notAuthenticated))
        else {
            return XCTFail("Expected account unavailable")
        }
        guard case .retryableFailure = PhonePinnedSyncEvent.failedSave(
            id: id,
            error: CKError(.accountTemporarilyUnavailable)
        ) else {
            return XCTFail("Expected retryable failure")
        }
    }

    func testStateVaultBindsAccountAndRejectsMismatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.encrypted")
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let store = PhoneSyncStateStore(fileURL: url, key: key)

        try await store.bind(accountIdentity: "account-a")
        try await store.saveRawState(Data([9, 8]), accountIdentity: "account-a")
        let restored = try await PhoneSyncStateStore(fileURL: url, key: key).loadRawState(accountIdentity: "account-a")

        XCTAssertEqual(restored, Data([9, 8]))
        await XCTAssertThrowsPhoneStateError(
            try await store.bind(accountIdentity: "account-b"),
            expected: .accountMismatch
        )
    }

    func testCancelWhileAccountResolutionIsSuspendedNeverCreatesOrStartsSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let barrier = PhoneAccountResolutionBarrier()
        let session = FakePhoneCloudKitSession()
        let creationCount = PhoneCountBox()
        let transport = PhoneCloudKitTransport(
            stateStore: PhoneSyncStateStore(
                fileURL: directory.appendingPathComponent("state.encrypted"),
                key: SymmetricKey(data: Data(repeating: 10, count: 32))
            ),
            resolveAccount: {
                await barrier.resolve()
                return PhoneCloudAccountContext(accountIdentity: "account", container: nil)
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

    func testEnableFetchesAndAppliesDuplicateRemoteMutationExactlyOnce() async throws {
        let fake = FakePhoneSyncTransport()
        let applied = PhoneAppliedMutationBox()
        let remote = makePhoneMutation(41)
        let engine = PhonePinnedSyncEngine(
            makeTransport: { fake },
            applyRemote: { await applied.record($0) }
        )

        try await engine.setEnabled(true)
        await fake.emit(.fetched(remote))
        await fake.emit(.fetched(remote))
        await fake.emit(.fetchCompleted)

        let fetchCount = await fake.fetchCount
        let mutations = await applied.mutations
        let status = await engine.status
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(mutations, [remote])
        XCTAssertEqual(status, .synced)
    }

    func testFailedRemoteApplyIsRetriedAndOnlySuccessfulDeliveryBecomesSeen() async throws {
        let remote = makePhoneMutation(42)
        let fake = FakePhoneSyncTransport()
        let applied = FailFirstPhoneMutationBox()
        let engine = PhonePinnedSyncEngine(
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

    func testSentPendingReadCannotOverwriteCompletedLock() async throws {
        let pending = SuspendingPhonePendingBox()
        let fake = FakePhoneSyncTransport()
        let engine = PhonePinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { await pending.read() }
        )
        try await engine.setEnabled(true)
        await pending.arm()

        let event = Task { await fake.emit(.sent([UUID()])) }
        await pending.waitUntilEntered()
        await engine.lock()
        await pending.release()
        await event.value

        let status = await engine.status
        XCTAssertEqual(status, .disabled)
    }

    func testSentPendingReadCannotOverwriteCompletedAccountChange() async throws {
        let pending = SuspendingPhonePendingBox()
        let fake = FakePhoneSyncTransport()
        let engine = PhonePinnedSyncEngine(
            makeTransport: { fake },
            pendingMutations: { await pending.read() }
        )
        try await engine.setEnabled(true)
        await pending.arm()

        let sent = Task { await fake.emit(.sent([UUID()])) }
        await pending.waitUntilEntered()
        await fake.emit(.accountChanged)
        await pending.release()
        await sent.value

        let status = await engine.status
        XCTAssertEqual(status, .recoveryRequired)
    }

    func testFailedOldEventCannotOverwriteLockStatus() async throws {
        let apply = SuspendingFailingPhoneApply()
        let fake = FakePhoneSyncTransport()
        let engine = PhonePinnedSyncEngine(
            makeTransport: { fake },
            applyRemote: { try await apply.run($0) }
        )
        try await engine.setEnabled(true)

        let event = Task { await fake.emit(.fetched(makePhoneMutation(43))) }
        await apply.waitUntilEntered()
        let lock = Task { await engine.lock() }
        await waitForPhoneStatus(.disabled, engine: engine)
        await apply.release()
        await lock.value
        await event.value

        let status = await engine.status
        XCTAssertEqual(status, .disabled)
    }

    func testLockAndDisableRejectStaleTransportCallbacks() async throws {
        let fake = FakePhoneSyncTransport()
        let acknowledged = PhoneAcknowledgementBox()
        let engine = PhonePinnedSyncEngine(
            makeTransport: { fake },
            acknowledge: { await acknowledged.record($0) }
        )

        try await engine.setEnabled(true)
        await engine.lock()
        await fake.emit(.sent([UUID()]))

        let ids = await acknowledged.ids
        let status = await engine.status
        let cancelCount = await fake.cancelCount
        XCTAssertEqual(ids, [])
        XCTAssertEqual(status, .disabled)
        XCTAssertEqual(cancelCount, 1)
    }

    func testAccountUnavailableFailsClosedWithoutFetchOrSend() async throws {
        let fake = FakePhoneSyncTransport()
        let engine = PhonePinnedSyncEngine(makeTransport: { fake })
        try await engine.setEnabled(true)
        await fake.emit(.accountUnavailable)

        let status = await engine.status
        let fetchCount = await fake.fetchCount
        let sendCount = await fake.sendCount
        XCTAssertEqual(status, .accountUnavailable)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(sendCount, 0)
    }

    /// Cancelling re-enters CKSyncEngine, and doing that while it is delivering an event
    /// traps the process. Deferring the cancel into a `Task` does not order it after the
    /// callback returns, so every callback-driven teardown must release the transport
    /// without ever cancelling it. Absence of a cancel is the property a fake can prove;
    /// ordering is not, which is why this asserts the counts rather than a timing.
    func testCallbackDrivenTeardownNeverCancelsTheTransport() async throws {
        for event in [PhonePinnedSyncEvent.accountUnavailable, .accountChanged] {
            let fake = FakePhoneSyncTransport()
            let engine = PhonePinnedSyncEngine(makeTransport: { fake })
            try await engine.setEnabled(true)

            await fake.emit(event)

            let cancelCount = await fake.cancelCount
            let releaseCount = await fake.releaseCount
            XCTAssertEqual(cancelCount, 0)
            XCTAssertEqual(releaseCount, 1)
        }
    }

    func testRecoveryRequiresExplicitChoiceAndKeepLocalDoesNotRewriteOrRestart() async throws {
        let fake = FakePhoneSyncTransport()
        let recovery = PhoneRecoveryCallBox()
        let engine = PhonePinnedSyncEngine(
            makeTransport: { fake },
            requeueForRecovery: { await recovery.record("requeue") },
            resetSyncStateForRecovery: { await recovery.record("reset") }
        )
        try await engine.setEnabled(true)
        await fake.emit(.accountChanged)

        var counts = await fake.operationCounts
        var recoveryCalls = await recovery.calls
        XCTAssertEqual(counts.start, 1)
        XCTAssertEqual(counts.fetch, 1)
        XCTAssertEqual(counts.send, 0)
        XCTAssertEqual(recoveryCalls, [])

        await engine.keepLocalAndDisable()

        counts = await fake.operationCounts
        recoveryCalls = await recovery.calls
        let status = await engine.status
        XCTAssertEqual(counts.start, 1)
        XCTAssertEqual(counts.fetch, 1)
        XCTAssertEqual(counts.send, 0)
        XCTAssertEqual(recoveryCalls, [])
        XCTAssertEqual(status, .disabled)
    }

    func testExplicitReuploadOrdersRequeueResetStartFetchAndSend() async throws {
        let mutation = makePhoneMutation(47)
        let journal = PhoneJournalBox()
        let order = PhoneRecoveryCallBox()
        let fake = FakePhoneSyncTransport(
            onStart: { await order.record("start") },
            onFetch: { await order.record("fetch") },
            onSendAsync: { _ in await order.record("send") }
        )
        let engine = PhonePinnedSyncEngine(
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
        let barrier = PhoneRecoveryBarrier()
        let fake = FakePhoneSyncTransport()
        let recovery = PhoneRecoveryCallBox()
        let engine = PhonePinnedSyncEngine(
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

        let counts = await fake.operationCounts
        let recoveryCalls = await recovery.calls
        let status = await engine.status
        XCTAssertEqual(counts.start, 1)
        XCTAssertEqual(counts.fetch, 1)
        XCTAssertEqual(counts.send, 0)
        XCTAssertEqual(recoveryCalls, ["requeue"])
        XCTAssertEqual(status, .disabled)
    }

    func testJournalNotificationDuringSendDrainsTheSecondPendingBatch() async throws {
        let first = makePhoneMutation(44)
        let second = makePhoneMutation(45)
        let barrier = PhoneSendBarrier()
        let secondSend = expectation(description: "second pending batch sent")
        let fake = FakePhoneSyncTransport(
            sendBarrier: barrier,
            onSend: {
                count in if count == 2 {
                    secondSend.fulfill()
                }
            }
        )
        let journal = PhoneJournalBox()
        let engine = PhonePinnedSyncEngine(
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
}

private func XCTAssertThrowsPhoneStateError<T>(
    _ expression: @autoclosure () async throws -> T,
    expected: PhoneSyncStateStoreError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected PhoneSyncStateStoreError", file: file, line: line)
    } catch let error as PhoneSyncStateStoreError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private func makePhoneMutation(_ suffix: Int) -> PinnedMutation {
    .reset(LibraryResetGeneration(
        resetID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!,
        generation: 1,
        modifiedAt: Date(timeIntervalSince1970: 1),
        deviceID: "phone"
    ))
}

private actor PhoneAccountResolutionBarrier {
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

private actor PhoneRecoveryCallBox {
    private(set) var calls: [String] = []
    func record(_ call: String) {
        calls.append(call)
    }

    func clear() {
        calls.removeAll()
    }
}

private actor PhoneRecoveryBarrier {
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

private actor PhoneCountBox {
    private(set) var value = 0
    func increment() {
        value += 1
    }
}

private actor FakePhoneCloudKitSession: PhoneCloudKitSession {
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

private actor PhoneAppliedMutationBox {
    private(set) var mutations: [PinnedMutation] = []
    func record(_ mutation: PinnedMutation) {
        mutations.append(mutation)
    }
}

private actor FailFirstPhoneMutationBox {
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

private actor SuspendingPhonePendingBox {
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

private actor SuspendingFailingPhoneApply {
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

private func waitForPhoneStatus(_ expected: PhonePinnedSyncStatus, engine: PhonePinnedSyncEngine) async {
    while await engine.status != expected {
        await Task.yield()
    }
}

private actor PhoneAcknowledgementBox {
    private(set) var ids: [UUID] = []
    func record(_ values: [UUID]) {
        ids.append(contentsOf: values)
    }
}

private actor PhoneJournalBox {
    private(set) var pending: [PinnedMutation] = []

    func append(_ mutation: PinnedMutation) {
        pending.append(mutation)
    }
}

private actor PhoneSendBarrier {
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

private actor FakePhoneSyncTransport: PhonePinnedSyncTransport {
    private var handler: (@Sendable (PhonePinnedSyncEvent) async -> Void)?
    private(set) var startCount = 0
    private(set) var fetchCount = 0
    private(set) var sendCount = 0
    private(set) var sentBatches: [[PinnedMutation]] = []
    private(set) var cancelCount = 0
    private(set) var releaseCount = 0
    private let sendBarrier: PhoneSendBarrier?
    private let onSend: (@Sendable (Int) -> Void)?
    private let onStart: @Sendable () async -> Void
    private let onFetch: @Sendable () async -> Void
    private let onSendAsync: @Sendable ([PinnedMutation]) async -> Void
    private var startErrors: [Error]
    private var fetchErrors: [Error]
    private let sendError: Error?

    init(
        sendBarrier: PhoneSendBarrier? = nil,
        onSend: (@Sendable (Int) -> Void)? = nil,
        onStart: @escaping @Sendable () async -> Void = {},
        onFetch: @escaping @Sendable () async -> Void = {},
        onSendAsync: @escaping @Sendable ([PinnedMutation]) async -> Void = { _ in },
        startError: Error? = nil,
        startErrors: [Error] = [],
        fetchErrors: [Error] = [],
        sendError: Error? = nil
    ) {
        self.sendBarrier = sendBarrier
        self.onSend = onSend
        self.onStart = onStart
        self.onFetch = onFetch
        self.onSendAsync = onSendAsync
        self.startErrors = startError.map { [$0] } ?? startErrors
        self.fetchErrors = fetchErrors
        self.sendError = sendError
    }

    func start(eventHandler: @escaping @Sendable (PhonePinnedSyncEvent) async -> Void) async throws {
        startCount += 1
        await onStart()
        if !startErrors.isEmpty {
            throw startErrors.removeFirst()
        }
        handler = eventHandler
    }

    func fetch() async throws {
        fetchCount += 1
        await onFetch()
        if !fetchErrors.isEmpty {
            throw fetchErrors.removeFirst()
        }
    }

    func send(_ mutations: [PinnedMutation]) async throws {
        sendCount += 1
        sentBatches.append(mutations)
        onSend?(sendCount)
        await onSendAsync(mutations)
        if let sendError {
            throw sendError
        }
        await sendBarrier?.suspend()
    }

    func cancel() async {
        cancelCount += 1
    }

    func releaseWithoutCancelling() async {
        releaseCount += 1
    }

    func emit(_ event: PhonePinnedSyncEvent) async {
        await handler?(event)
    }

    func waitUntilSendCount(_ expected: Int) async {
        while sendCount < expected {
            await Task.yield()
        }
    }

    var operationCounts: (start: Int, fetch: Int, send: Int, cancel: Int) {
        (startCount, fetchCount, sendCount, cancelCount)
    }
}
