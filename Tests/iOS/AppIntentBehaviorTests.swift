import ClipboardCore
@testable import ClipboardKeyboardiOS
import Foundation
import XCTest

@MainActor
final class AppIntentBehaviorTests: XCTestCase {
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

    func applyRemote(_: PinnedMutation) async throws -> MergeOutcome {
        throw IntentTestError.backendSecret
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
