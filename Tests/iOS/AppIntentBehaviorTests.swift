import ClipboardCore
@testable import ClipboardKeyboardiOS
import Foundation
import XCTest

@MainActor
final class AppIntentBehaviorTests: XCTestCase {
    func testRecoveryKeepLocalPersistsDisabledPreferenceBeforeEngineAction() async throws {
        let preferences = MemoryPhoneSyncPreferenceStore()
        preferences.save(true)
        let transport = IntentPhoneSyncTransport()
        let engine = PhonePinnedSyncEngine(makeTransport: { transport })
        let dependencies = IntentDependencies(
            gate: PhonePinnedLibraryGate(),
            readiness: { _ in
                IntentReadyBackend(
                    library: IntentLibraryFake(),
                    textTransformer: TextTransformer { $0 },
                    generation: 1,
                    close: { await engine.lock() },
                    syncEngine: engine
                )
            },
            protectedDataAvailable: true,
            syncPreferenceStore: preferences,
            pasteboardWrite: { _ in }
        )

        try await dependencies.ensureReady()
        await transport.waitUntilFetchCount(1)
        await transport.emit(.accountChanged)

        await dependencies.keepLocalAndTurnSyncOff()

        XCTAssertFalse(preferences.load())
        XCTAssertFalse(dependencies.desiredSyncEnabled)
        let finalStatus = await engine.status
        XCTAssertEqual(finalStatus, .disabled)
        let counts = await transport.operationCounts
        XCTAssertEqual(counts.start, 1)
        XCTAssertEqual(counts.fetch, 1)
        XCTAssertEqual(counts.send, 0)
    }

    func testRecoveryReuploadActionForwardsToInstalledEngineWithoutChangingPreference() async throws {
        let preferences = MemoryPhoneSyncPreferenceStore()
        preferences.save(true)
        let transport = IntentPhoneSyncTransport()
        let recovery = IntentRecoveryCallRecorder()
        let engine = PhonePinnedSyncEngine(
            makeTransport: { transport },
            requeueForRecovery: { await recovery.record("requeue") },
            resetSyncStateForRecovery: { await recovery.record("reset") }
        )
        let dependencies = IntentDependencies(
            gate: PhonePinnedLibraryGate(),
            readiness: { _ in
                IntentReadyBackend(
                    library: IntentLibraryFake(),
                    textTransformer: TextTransformer { $0 },
                    generation: 1,
                    close: { await engine.lock() },
                    syncEngine: engine
                )
            },
            protectedDataAvailable: true,
            syncPreferenceStore: preferences,
            pasteboardWrite: { _ in }
        )

        try await dependencies.ensureReady()
        await transport.waitUntilFetchCount(1)
        await transport.emit(.accountChanged)

        try await dependencies.reuploadLocalPins()

        XCTAssertTrue(preferences.load())
        XCTAssertTrue(dependencies.desiredSyncEnabled)
        let recoveryCalls = await recovery.calls
        let startCount = await transport.startCount
        let fetchCount = await transport.fetchCount
        XCTAssertEqual(recoveryCalls, ["requeue", "reset"])
        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(fetchCount, 2)
    }

    func testDisableCancelsInFlightEnableBeforeStartCanFetchOrSend() async throws {
        let preferences = MemoryPhoneSyncPreferenceStore()
        preferences.save(true)
        let startBarrier = IntentSyncReconciliationBarrier()
        let cancelled = expectation(description: "in-flight enable cancelled")
        let cancelSignal = IntentOneShotCallback { cancelled.fulfill() }
        let transport = IntentPhoneSyncTransport(
            startBarrier: startBarrier,
            onCancel: { cancelSignal.call() }
        )
        let engine = PhonePinnedSyncEngine(makeTransport: { transport })
        let dependencies = IntentDependencies(
            gate: PhonePinnedLibraryGate(),
            readiness: { _ in
                IntentReadyBackend(
                    library: IntentLibraryFake(),
                    textTransformer: TextTransformer { $0 },
                    generation: 1,
                    close: { await engine.lock() },
                    syncEngine: engine
                )
            },
            protectedDataAvailable: true,
            syncPreferenceStore: preferences,
            pasteboardWrite: { _ in }
        )

        try await dependencies.ensureReady()
        await startBarrier.waitUntilEntered()
        let disable = Task { await dependencies.setSyncEnabled(false) }
        await fulfillment(of: [cancelled], timeout: 1)

        let countsBeforeRelease = await transport.operationCounts
        XCTAssertEqual(countsBeforeRelease.start, 1)
        XCTAssertEqual(countsBeforeRelease.fetch, 0)
        XCTAssertEqual(countsBeforeRelease.send, 0)
        let statusBeforeRelease = await engine.status
        XCTAssertEqual(statusBeforeRelease, .disabled)

        await startBarrier.release()
        await disable.value
        await Task.yield()
        let finalCounts = await transport.operationCounts
        XCTAssertEqual(finalCounts.fetch, 0)
        XCTAssertEqual(finalCounts.send, 0)
        let finalStatus = await engine.status
        XCTAssertEqual(finalStatus, .disabled)
        XCTAssertFalse(dependencies.desiredSyncEnabled)
    }

    func testReadinessReplayReadsLatestDisabledPreferenceBeforeAnyEngineAction() async throws {
        let preferences = MemoryPhoneSyncPreferenceStore()
        preferences.save(true)
        let reconciliationBarrier = IntentSyncReconciliationBarrier()
        let transport = IntentPhoneSyncTransport()
        let engine = PhonePinnedSyncEngine(makeTransport: { transport })
        let dependencies = IntentDependencies(
            gate: PhonePinnedLibraryGate(),
            readiness: { _ in
                IntentReadyBackend(
                    library: IntentLibraryFake(),
                    textTransformer: TextTransformer { $0 },
                    generation: 1,
                    close: { await engine.lock() },
                    syncEngine: engine
                )
            },
            protectedDataAvailable: true,
            syncPreferenceStore: preferences,
            beforeSyncReconciliation: { await reconciliationBarrier.suspendOnce() },
            pasteboardWrite: { _ in }
        )
        var observedStatuses: [PhonePinnedSyncStatus] = []
        let reconciled = expectation(description: "latest sync preference reconciled")
        dependencies.installSyncStatusChanged {
            observedStatuses.append($0)
            if observedStatuses.count == 3 {
                reconciled.fulfill()
            }
        }

        try await dependencies.ensureReady()
        await reconciliationBarrier.waitUntilEntered()
        await dependencies.setSyncEnabled(false)
        await reconciliationBarrier.release()
        await fulfillment(of: [reconciled], timeout: 1)

        XCTAssertGreaterThanOrEqual(observedStatuses.count, 3)
        let counts = await transport.operationCounts
        XCTAssertEqual(counts.start, 0)
        XCTAssertEqual(counts.fetch, 0)
        XCTAssertEqual(counts.send, 0)
        XCTAssertFalse(dependencies.desiredSyncEnabled)
        XCTAssertFalse(preferences.load())
        let finalStatus = await engine.status
        XCTAssertEqual(finalStatus, .disabled)
    }

    func testFetchedRemoteMutationRoutesThroughInstalledGateWithoutOutgoingSend() async throws {
        let preferences = MemoryPhoneSyncPreferenceStore()
        preferences.save(true)
        let transport = IntentPhoneSyncTransport()
        let engine = PhonePinnedSyncEngine(makeTransport: { transport })
        let library = IntentLibraryFake()
        let dependencies = IntentDependencies(
            gate: PhonePinnedLibraryGate(),
            readiness: { _ in
                IntentReadyBackend(
                    library: library,
                    textTransformer: TextTransformer { $0 },
                    generation: 1,
                    close: { await engine.lock() },
                    syncEngine: engine
                )
            },
            protectedDataAvailable: true,
            syncPreferenceStore: preferences,
            pasteboardWrite: { _ in }
        )
        let remote = revision(index: 77, text: "remote-content")

        try await dependencies.ensureReady()
        await transport.waitUntilFetchCount(1)
        await transport.emit(.fetched(.revision(remote)))

        let items = try await dependencies.gate.allItems()
        let sendCount = await transport.sendCount
        XCTAssertEqual(items.map(\.itemID), [remote.itemID])
        XCTAssertEqual(sendCount, 0)
    }

    func testSyncPreferencePersistsBeforeReadinessAndReplaysAfterLockAndRecreation() async throws {
        let preferences = MemoryPhoneSyncPreferenceStore()
        let transport = IntentPhoneSyncTransport()
        let engine = PhonePinnedSyncEngine(makeTransport: { transport })
        let library = IntentLibraryFake()
        let dependencies = IntentDependencies(
            gate: PhonePinnedLibraryGate(),
            readiness: { _ in
                IntentReadyBackend(
                    library: library,
                    textTransformer: TextTransformer { $0 },
                    generation: 1,
                    close: { await engine.lock() },
                    syncEngine: engine
                )
            },
            protectedDataAvailable: true,
            syncPreferenceStore: preferences,
            pasteboardWrite: { _ in }
        )

        await dependencies.setSyncEnabled(true)
        await dependencies.setSyncEnabled(false)
        await dependencies.setSyncEnabled(true)
        XCTAssertTrue(dependencies.desiredSyncEnabled)
        XCTAssertTrue(preferences.load())
        let startsBeforeReadiness = await transport.startCount
        XCTAssertEqual(startsBeforeReadiness, 0)

        try await dependencies.ensureReady()
        await transport.waitUntilStartCount(1)
        await transport.waitUntilFetchCount(1)
        let fetchCount = await transport.fetchCount
        XCTAssertEqual(fetchCount, 1)

        dependencies.lock()
        _ = dependencies.protectedDataDidBecomeAvailable()
        try await dependencies.ensureReady()
        await transport.waitUntilStartCount(2)

        let recreated = IntentDependencies(
            gate: PhonePinnedLibraryGate(),
            readiness: { _ in throw IntentTestError.backendSecret },
            protectedDataAvailable: false,
            syncPreferenceStore: preferences,
            pasteboardWrite: { _ in }
        )
        XCTAssertTrue(recreated.desiredSyncEnabled)
    }

    func testConcurrentColdCallsPrepareProtectedLibraryOnce() async throws {
        let library = IntentLibraryFake()
        let readiness = ReadinessHarness(library: library, suspended: true)
        let dependencies = makeDependencies(readiness: readiness)

        let first = Task { try await dependencies.ensureReady() }
        let second = Task { try await dependencies.ensureReady() }
        await readiness.waitUntilEntered()

        XCTAssertEqual(readiness.callCount, 1)
        readiness.resume()
        try await first.value
        try await second.value
        XCTAssertTrue(dependencies.isReady)
    }

    func testCancelledReadinessJoinerFinishesBeforeSharedInitializationAndOwnerStillSucceeds() async throws {
        let readiness = ReadinessHarness(library: IntentLibraryFake(), suspended: true)
        let dependencies = makeDependencies(readiness: readiness)
        let owner = Task { try await dependencies.ensureReady() }
        await readiness.waitUntilEntered()
        let joinerFinished = expectation(description: "cancelled joiner finished")
        var joinerError: Error?
        let joiner = Task {
            do {
                try await dependencies.ensureReady()
            } catch {
                joinerError = error
            }
            joinerFinished.fulfill()
        }
        await waitForReadinessWaiterCount(2, dependencies: dependencies)

        joiner.cancel()
        await fulfillment(of: [joinerFinished], timeout: 1)

        XCTAssertTrue(joinerError is CancellationError)
        XCTAssertEqual(readiness.callCount, 1)
        readiness.resume()
        try await owner.value
        await joiner.value
        XCTAssertTrue(dependencies.isReady)
    }

    func testReadinessJoinerCannotReturnExtractedContentAfterLock() async {
        let readiness = ReadinessHarness(library: IntentLibraryFake(), suspended: true)
        let dependencies = makeDependencies(readiness: readiness)
        let owner = Task { try await dependencies.ensureReady() }
        await readiness.waitUntilEntered()
        let extractFinished = expectation(description: "locked extract finished")
        var extractResult: Result<ExtractValuesOutcome, Error>?
        let extract = Task {
            do {
                extractResult = try .success(await dependencies.extractValues("locked-value@example.com"))
            } catch {
                extractResult = .failure(error)
            }
            extractFinished.fulfill()
        }
        await waitForReadinessWaiterCount(2, dependencies: dependencies)

        dependencies.lock()
        await fulfillment(of: [extractFinished], timeout: 1)

        guard case let .failure(error)? = extractResult else {
            readiness.resume()
            await extract.value
            return XCTFail("Expected locked failure")
        }
        XCTAssertEqual(error as? ClipboardIntentError, .unavailable)
        XCTAssertFalse(error.localizedDescription.contains("locked-value"))
        readiness.resume()
        await XCTAssertThrowsIntentError(try await owner.value, expected: .unavailable)
        await extract.value
    }

    func testPinWaitsForReadyAndPreservesExactExplicitText() async throws {
        let library = IntentLibraryFake()
        let readiness = ReadinessHarness(library: library, suspended: true)
        let dependencies = makeDependencies(readiness: readiness)

        let pin = Task { try await dependencies.pinText("  exact text\n") }
        await readiness.waitUntilEntered()
        let payloadsBeforeReady = await library.payloads()
        XCTAssertEqual(payloadsBeforeReady, [])
        readiness.resume()

        let outcome = try await pin.value
        let pinnedPayloads = await library.payloads()
        let payload = try XCTUnwrap(pinnedPayloads.first)
        XCTAssertEqual(payload.canonicalInsertionString, "  exact text\n")
        XCTAssertEqual(payload.representations.first?.originalBytes, Data("  exact text\n".utf8))
        XCTAssertEqual(outcome.dialog, "Text pinned.")
        XCTAssertFalse(outcome.dialog.contains("exact"))
    }

    func testWhitespacePinAndEmptyFindFailBeforePreparingOrWriting() async {
        let library = IntentLibraryFake()
        let readiness = ReadinessHarness(library: library)
        let dependencies = makeDependencies(readiness: readiness)

        await assertIntentError(.invalidInput) {
            _ = try await dependencies.pinText(" \n\t ")
        }
        await assertIntentError(.invalidInput) {
            _ = try await dependencies.findPinned(query: "  ", copy: true) { _ in UUID() }
        }

        XCTAssertEqual(readiness.callCount, 0)
        let pinnedPayloads = await library.payloads()
        XCTAssertEqual(pinnedPayloads, [])
    }

    func testStaleReadinessCompletionAfterLockCannotReopenRuntime() async {
        let readiness = ReadinessHarness(library: IntentLibraryFake(), suspended: true)
        let dependencies = makeDependencies(readiness: readiness)
        let unlock = Task { try await dependencies.ensureReady() }
        await readiness.waitUntilEntered()

        dependencies.lock()
        readiness.resume()

        await XCTAssertThrowsIntentError(try await unlock.value, expected: .unavailable)
        XCTAssertFalse(dependencies.isReady)
        await XCTAssertThrowsIntentError(
            try await dependencies.findPinned(query: "sentinel-query", copy: false) { _ in UUID() },
            expected: .unavailable,
            excluding: ["sentinel-query"]
        )
    }

    func testStaleSnapshotInitializationFailureCannotClobberNewReadyBackend() async throws {
        let snapshotBarrier = IntentPinBarrier()
        let staleClose = IntentSignal()
        let staleLibrary = IntentLibraryFake(snapshotBarrier: snapshotBarrier)
        let currentRevision = revision(index: 42, text: "current-backend-value")
        let currentLibrary = IntentLibraryFake(items: [currentRevision])
        let readiness = ReadinessHarness(
            libraries: [staleLibrary, currentLibrary],
            firstCloseSignal: staleClose
        )
        let dependencies = makeDependencies(readiness: readiness)
        let staleUnlock = Task { try await dependencies.ensureReady() }
        await snapshotBarrier.waitUntilEntered()

        dependencies.lock()
        dependencies.protectedDataDidBecomeAvailable()
        try await dependencies.ensureReady()
        let beforeStaleCompletion = try await dependencies.findPinned(
            query: "current",
            copy: false
        ) { _ in UUID() }
        XCTAssertEqual(beforeStaleCompletion.value, "current-backend-value")

        await snapshotBarrier.release()
        await staleClose.wait()
        await XCTAssertThrowsIntentError(try await staleUnlock.value, expected: .unavailable)

        XCTAssertTrue(dependencies.isReady)
        let afterStaleCompletion = try await dependencies.findPinned(
            query: "current",
            copy: false
        ) { _ in UUID() }
        XCTAssertEqual(afterStaleCompletion.value, "current-backend-value")
    }

    func testCancelledPinWaitingForReadinessPerformsNoWrite() async {
        let library = IntentLibraryFake()
        let readiness = ReadinessHarness(library: library, suspended: true)
        let dependencies = makeDependencies(readiness: readiness)
        let pin = Task { try await dependencies.pinText("cancel-sentinel") }
        await readiness.waitUntilEntered()

        pin.cancel()
        readiness.resume()

        await XCTAssertThrowsCancellationError(try await pin.value)
        let pinnedPayloads = await library.payloads()
        XCTAssertEqual(pinnedPayloads, [])
    }

    func testReadinessFailureIsContentFreeAndRetryable() async throws {
        let library = IntentLibraryFake()
        let readiness = ReadinessHarness(library: library, failuresRemaining: 1)
        let dependencies = makeDependencies(readiness: readiness)

        await XCTAssertThrowsIntentError(
            try await dependencies.pinText("private-input-sentinel"),
            expected: .unavailable,
            excluding: ["private-input-sentinel", "backend-secret-sentinel"]
        )
        _ = try await dependencies.pinText("retry-value")

        XCTAssertEqual(readiness.callCount, 2)
        let pinnedValues = await library.payloads().map(\.canonicalInsertionString)
        XCTAssertEqual(pinnedValues, ["retry-value"])
    }

    func testExtractionReturnsDeterministicOriginalsWithoutPersistenceOrCopy() async throws {
        let library = IntentLibraryFake()
        let writes = PasteboardWrites()
        let dependencies = makeDependencies(
            readiness: ReadinessHarness(library: library),
            writes: writes
        )

        let outcome = try await dependencies.extractValues(
            "Call 010-1234-5678 or EMAIL@example.com then https://example.com/path."
        )

        XCTAssertEqual(outcome.values, ["010-1234-5678", "EMAIL@example.com", "https://example.com/path"])
        XCTAssertEqual(outcome.dialog, "Values extracted.")
        let pinnedPayloads = await library.payloads()
        XCTAssertEqual(pinnedPayloads, [])
        XCTAssertEqual(writes.values, [])
    }

    func testFindSingleResultCopiesOnlyWhenExplicitlyRequested() async throws {
        let library = IntentLibraryFake(items: [revision(index: 1, text: "stored-sentinel")])
        let writes = PasteboardWrites()
        let dependencies = makeDependencies(
            readiness: ReadinessHarness(library: library),
            writes: writes
        )

        let first = try await dependencies.findPinned(query: "stored", copy: false) { _ in
            XCTFail("Single result must not request selection")
            return UUID()
        }
        let second = try await dependencies.findPinned(query: "stored", copy: true) { _ in
            XCTFail("Single result must not request selection")
            return UUID()
        }

        XCTAssertEqual(first.value, "stored-sentinel")
        XCTAssertEqual(second.value, "stored-sentinel")
        XCTAssertEqual(first.dialog, "Pinned text found.")
        XCTAssertEqual(writes.values, ["stored-sentinel"])
        let pinnedPayloads = await library.payloads()
        XCTAssertEqual(pinnedPayloads, [])
    }

    func testFindMultipleUsesStableDistinctChoicesAndReturnsSelectedCanonicalValue() async throws {
        let first = revision(index: 1, text: "first-value", title: "Duplicate")
        let second = revision(index: 2, text: "second-value", title: "Duplicate")
        let library = IntentLibraryFake(items: [first, second])
        let dependencies = makeDependencies(readiness: ReadinessHarness(library: library))

        let outcome = try await dependencies.findPinned(query: "value", copy: false) { choices in
            XCTAssertEqual(choices.map(\.id), [first.itemID, second.itemID])
            XCTAssertEqual(Set(choices.map(\.label)).count, 2)
            return second.itemID
        }

        XCTAssertEqual(outcome.value, "second-value")
    }

    func testFindMultipleLockedDuringSelectionReturnsUnavailableAndNeverCopies() async {
        let writes = PasteboardWrites()
        let first = revision(index: 1, text: "first-selection-secret")
        let second = revision(index: 2, text: "second-selection-secret")
        let selection = SelectionHarness(selectedID: second.itemID)
        let dependencies = makeDependencies(
            readiness: ReadinessHarness(library: IntentLibraryFake(items: [first, second])),
            writes: writes
        )
        let find = Task {
            try await dependencies.findPinned(query: "selection-query", copy: true) { choices in
                try await selection.select(choices)
            }
        }
        await selection.waitUntilEntered()

        dependencies.lock()
        selection.resume()

        await XCTAssertThrowsIntentError(
            try await find.value,
            expected: .unavailable,
            excluding: ["selection-query", "first-selection-secret", "second-selection-secret"]
        )
        XCTAssertEqual(writes.values, [])
    }

    func testFindSelectionCancellationAfterLockReportsUnavailable() async {
        let writes = PasteboardWrites()
        let first = revision(index: 1, text: "first-cancel-secret")
        let second = revision(index: 2, text: "second-cancel-secret")
        let selection = SelectionHarness(selectedID: second.itemID, cancelOnResume: true)
        let dependencies = makeDependencies(
            readiness: ReadinessHarness(library: IntentLibraryFake(items: [first, second])),
            writes: writes
        )
        let find = Task {
            try await dependencies.findPinned(query: "cancel-query", copy: true) { choices in
                try await selection.select(choices)
            }
        }
        await selection.waitUntilEntered()

        dependencies.lock()
        selection.resume()

        await XCTAssertThrowsIntentError(
            try await find.value,
            expected: .unavailable,
            excluding: ["cancel-query", "first-cancel-secret", "second-cancel-secret"]
        )
        XCTAssertEqual(writes.values, [])
    }

    func testIntentPinReportsSuccessWhenLockHappensAfterDurableCommit() async throws {
        let barrier = IntentPinBarrier()
        let library = IntentLibraryFake(intentPinBarrier: barrier)
        let dependencies = makeDependencies(readiness: ReadinessHarness(library: library))
        let pin = Task { try await dependencies.pinText("durable-pin-secret") }
        await barrier.waitUntilEntered()
        let committedPayloads = await library.payloads()
        XCTAssertEqual(committedPayloads.map(\.canonicalInsertionString), ["durable-pin-secret"])

        dependencies.lock()
        await barrier.release()

        let outcome = try await pin.value
        XCTAssertEqual(outcome.dialog, "Text pinned.")
        let finalPayloads = await library.payloads()
        XCTAssertEqual(finalPayloads.map(\.canonicalInsertionString), ["durable-pin-secret"])
    }

    func testIntentPinPrecommitFailureReportsContentFreeFailureAndCommitsNothing() async {
        let library = IntentLibraryFake(intentPinPrecommitFailure: true)
        let dependencies = makeDependencies(readiness: ReadinessHarness(library: library))

        await XCTAssertThrowsIntentError(
            try await dependencies.pinText("precommit-secret"),
            expected: .operationFailed,
            excluding: ["precommit-secret", "backend-secret-sentinel"]
        )
        let payloads = await library.payloads()
        XCTAssertEqual(payloads, [])
    }

    func testLifecycleTokenPreventsOlderUnlockFailureFromPurgingCurrentState() {
        let dependencies = makeDependencies(readiness: ReadinessHarness(library: IntentLibraryFake()))
        let first = dependencies.protectedDataDidBecomeAvailable()
        dependencies.lock()
        let second = dependencies.protectedDataDidBecomeAvailable()

        XCTAssertFalse(dependencies.isCurrentLifecycle(first))
        XCTAssertTrue(dependencies.isCurrentLifecycle(second))
    }

    func testFindSelectionCancellationAndRepositoryFailurePerformNoWritesAndExposeNoContent() async {
        let writes = PasteboardWrites()
        let first = revision(index: 1, text: "first-secret")
        let second = revision(index: 2, text: "second-secret")
        let library = IntentLibraryFake(items: [first, second])
        let dependencies = makeDependencies(
            readiness: ReadinessHarness(library: library),
            writes: writes
        )

        await XCTAssertThrowsIntentError(
            try await dependencies.findPinned(query: "query-secret", copy: true) { _ in
                throw CancellationError()
            },
            expected: .selectionCancelled,
            excluding: ["query-secret", "first-secret", "second-secret"]
        )
        await library.setSearchFailure(true)
        await XCTAssertThrowsIntentError(
            try await dependencies.findPinned(query: "repository-query", copy: true) { _ in first.itemID },
            expected: .operationFailed,
            excluding: ["repository-query", "first-secret", "second-secret"]
        )

        XCTAssertEqual(writes.values, [])
        let pinnedPayloads = await library.payloads()
        XCTAssertEqual(pinnedPayloads, [])
    }

    private func makeDependencies(
        readiness: ReadinessHarness,
        writes: PasteboardWrites = PasteboardWrites()
    ) -> IntentDependencies {
        IntentDependencies(
            gate: PhonePinnedLibraryGate(),
            readiness: { unlock in try await readiness.prepare(unlock: unlock) },
            pasteboardWrite: { value in writes.values.append(value) }
        )
    }

    private func revision(
        index: Int,
        text: String,
        title: String = "Pinned"
    ) -> PinnedRevision {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
        return PinnedRevision(
            itemID: id,
            revisionID: UUID(),
            libraryGeneration: 1,
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(100 - index)),
            deviceID: "test",
            payload: PinPayload(
                representations: [
                    ClipRepresentation(kind: .plainText, originalBytes: Data(text.utf8), keyedDigest: Data([1])),
                ],
                canonicalInsertionString: text,
                title: title,
                contentKind: .plainText,
                category: nil
            )
        )
    }

    private func assertIntentError(
        _ expected: ClipboardIntentError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected error")
        } catch let error as ClipboardIntentError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
    }

    private func waitForReadinessWaiterCount(
        _ expected: Int,
        dependencies: IntentDependencies,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0 ..< 100 where dependencies.readinessWaiterCount < expected {
            await Task.yield()
        }
        XCTAssertEqual(dependencies.readinessWaiterCount, expected, file: file, line: line)
    }
}

private final class MemoryPhoneSyncPreferenceStore: PhoneSyncPreferencePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func load() -> Bool {
        lock.withLock { value }
    }

    func save(_ enabled: Bool) {
        lock.withLock { value = enabled }
    }
}

private actor IntentRecoveryCallRecorder {
    private(set) var calls: [String] = []

    func record(_ call: String) {
        calls.append(call)
    }
}

private final class IntentOneShotCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (() -> Void)?

    init(_ callback: @escaping () -> Void) {
        self.callback = callback
    }

    func call() {
        let callback = lock.withLock {
            defer { self.callback = nil }
            return self.callback
        }
        callback?()
    }
}

private actor IntentPhoneSyncTransport: PhonePinnedSyncTransport {
    private let startBarrier: IntentSyncReconciliationBarrier?
    private let onCancel: @Sendable () -> Void
    private(set) var startCount = 0
    private(set) var fetchCount = 0
    private(set) var sendCount = 0
    private var handler: (@Sendable (PhonePinnedSyncEvent) async -> Void)?
    var operationCounts: (start: Int, fetch: Int, send: Int) {
        (startCount, fetchCount, sendCount)
    }

    init(
        startBarrier: IntentSyncReconciliationBarrier? = nil,
        onCancel: @escaping @Sendable () -> Void = {}
    ) {
        self.startBarrier = startBarrier
        self.onCancel = onCancel
    }

    func start(eventHandler: @escaping @Sendable (PhonePinnedSyncEvent) async -> Void) async throws {
        startCount += 1
        handler = eventHandler
        await startBarrier?.suspendOnce()
    }

    func fetch() async throws {
        fetchCount += 1
    }

    func send(_: [PinnedMutation]) async throws {
        sendCount += 1
    }

    func cancel() async {
        onCancel()
    }

    func waitUntilStartCount(_ expected: Int) async {
        while startCount < expected {
            await Task.yield()
        }
    }

    func waitUntilFetchCount(_ expected: Int) async {
        while fetchCount < expected {
            await Task.yield()
        }
    }

    func emit(_ event: PhonePinnedSyncEvent) async {
        await handler?(event)
    }
}

private actor IntentSyncReconciliationBarrier {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendOnce() async {
        guard !entered else { return }
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private final class ReadinessHarness {
    private let libraries: [IntentLibraryFake]
    private let firstCloseSignal: IntentSignal?
    private let suspended: Bool
    private var failuresRemaining: Int
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    init(library: IntentLibraryFake, suspended: Bool = false, failuresRemaining: Int = 0) {
        libraries = [library]
        firstCloseSignal = nil
        self.suspended = suspended
        self.failuresRemaining = failuresRemaining
    }

    init(libraries: [IntentLibraryFake], firstCloseSignal: IntentSignal) {
        self.libraries = libraries
        self.firstCloseSignal = firstCloseSignal
        suspended = false
        failuresRemaining = 0
    }

    func prepare(unlock _: PhoneUnlockContext) async throws -> IntentReadyBackend {
        let callIndex = callCount
        callCount += 1
        enteredContinuation?.resume()
        enteredContinuation = nil
        if suspended {
            await withCheckedContinuation { continuation = $0 }
        }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw IntentTestError.backendSecret
        }
        let library = libraries[min(callIndex, libraries.count - 1)]
        let closeSignal = callIndex == 0 ? firstCloseSignal : nil
        return IntentReadyBackend(
            library: library,
            textTransformer: TextTransformer { Data($0.reversed()) },
            generation: 1,
            close: { await closeSignal?.signal() }
        )
    }

    func waitUntilEntered() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class PasteboardWrites {
    var values: [String] = []
}

@MainActor
private final class SelectionHarness {
    private let selectedID: UUID
    private let cancelOnResume: Bool
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var selectionContinuation: CheckedContinuation<UUID, Error>?
    private var entered = false

    init(selectedID: UUID, cancelOnResume: Bool = false) {
        self.selectedID = selectedID
        self.cancelOnResume = cancelOnResume
    }

    func select(_ choices: [FindPinnedChoice]) async throws -> UUID {
        XCTAssertTrue(choices.contains { $0.id == selectedID })
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        return try await withCheckedThrowingContinuation { selectionContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func resume() {
        if cancelOnResume {
            selectionContinuation?.resume(throwing: CancellationError())
        } else {
            selectionContinuation?.resume(returning: selectedID)
        }
        selectionContinuation = nil
    }
}

private actor IntentPinBarrier {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor IntentSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signalled = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard !signalled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private enum IntentTestError: Error, LocalizedError {
    case backendSecret

    var errorDescription: String? {
        "backend-secret-sentinel"
    }
}

private actor IntentLibraryFake: PinnedLibrary, IntentPinCommittingLibrary {
    private var items: [PinnedRevision]
    private(set) var pinnedPayloads: [PinPayload] = []
    private var searchFailure = false
    private let intentPinBarrier: IntentPinBarrier?
    private let snapshotBarrier: IntentPinBarrier?
    private let intentPinPrecommitFailure: Bool

    init(
        items: [PinnedRevision] = [],
        intentPinBarrier: IntentPinBarrier? = nil,
        snapshotBarrier: IntentPinBarrier? = nil,
        intentPinPrecommitFailure: Bool = false
    ) {
        self.items = items
        self.intentPinBarrier = intentPinBarrier
        self.snapshotBarrier = snapshotBarrier
        self.intentPinPrecommitFailure = intentPinPrecommitFailure
    }

    func setSearchFailure(_ enabled: Bool) {
        searchFailure = enabled
    }

    func payloads() -> [PinPayload] {
        pinnedPayloads
    }

    func allItems() async throws -> [PinnedRevision] {
        await snapshotBarrier?.suspend()
        return items
    }

    func search(_: String, limit: Int) async throws -> [PinnedRevision] {
        if searchFailure {
            throw IntentTestError.backendSecret
        }
        return Array(items.prefix(limit))
    }

    func pin(_ payload: PinPayload) async throws -> PinnedRevision {
        let revision = commit(payload)
        await intentPinBarrier?.suspend()
        return revision
    }

    func pinForIntent(_ payload: PinPayload) async throws -> IntentPinCommit {
        if intentPinPrecommitFailure {
            throw IntentTestError.backendSecret
        }
        let revision = commit(payload)
        await intentPinBarrier?.suspend()
        return IntentPinCommit(libraryGeneration: revision.libraryGeneration)
    }

    private func commit(_ payload: PinPayload) -> PinnedRevision {
        pinnedPayloads.append(payload)
        let revision = PinnedRevision(
            itemID: UUID(),
            revisionID: UUID(),
            libraryGeneration: 1,
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            deviceID: "test",
            payload: payload
        )
        items.append(revision)
        return revision
    }

    func revise(itemID _: UUID, payload _: PinPayload) async throws -> PinnedRevision {
        throw IntentTestError.backendSecret
    }

    func delete(itemID _: UUID) async throws -> PinnedTombstone {
        throw IntentTestError.backendSecret
    }

    func applyRemote(_ mutation: PinnedMutation) async throws -> MergeOutcome {
        switch mutation {
        case let .revision(revision):
            items.removeAll { $0.itemID == revision.itemID }
            items.append(revision)
        case let .tombstone(tombstone):
            items.removeAll { $0.itemID == tombstone.itemID }
        case .reset:
            items.removeAll()
        }
        return .inserted(mutation.mutationID)
    }

    func advanceResetGeneration() async throws -> LibraryResetGeneration {
        throw IntentTestError.backendSecret
    }
}

@MainActor
private func XCTAssertThrowsIntentError<T>(
    _ expression: @autoclosure () async throws -> T,
    expected: ClipboardIntentError,
    excluding sentinels: [String] = [],
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch let error as ClipboardIntentError {
        XCTAssertEqual(error, expected, file: file, line: line)
        let description = error.localizedDescription
        for sentinel in sentinels {
            XCTAssertFalse(description.contains(sentinel), file: file, line: line)
        }
    } catch {
        XCTFail("Unexpected error: \(type(of: error))", file: file, line: line)
    }
}

@MainActor
private func XCTAssertThrowsCancellationError<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected cancellation", file: file, line: line)
    } catch is CancellationError {
    } catch {
        XCTFail("Unexpected error: \(type(of: error))", file: file, line: line)
    }
}
