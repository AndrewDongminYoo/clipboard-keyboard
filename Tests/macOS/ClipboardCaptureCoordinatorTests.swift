import ClipboardCore
@testable import ClipboardKeyboardMac
import XCTest

@MainActor
final class ClipboardCaptureCoordinatorTests: XCTestCase {
    private let stableIdentity = ApplicationIdentity(
        bundleIdentifier: "com.example.Editor",
        teamIdentifier: "TEAM123",
        signingIdentifier: "com.example.Editor"
    )

    func testBlockedMetadataNeverReadsPayloadOrDerivesOrCommits() async {
        let ignoredIdentity = ApplicationIdentity(bundleIdentifier: "com.example.Ignored", teamIdentifier: "TEAM123", signingIdentifier: "com.example.Ignored")
        let cases: [(String, [String], SourceObservation, Set<ApplicationIdentity>, TimeInterval?)] = [
            ("private copy", ["public.utf8-plain-text", "kr.donminzzi.clipboardkeyboard.private-copy"], stableSource(), [], nil),
            ("confidential", ["public.utf8-plain-text", "com.agilebits.onepassword"], stableSource(), [], nil),
            ("paused", ["public.utf8-plain-text"], stableSource(), [], 60),
            ("unknown source", ["public.utf8-plain-text"], .init(identity: nil, confidence: .unknown), [], nil),
            ("ignored verified application", ["public.utf8-plain-text"], .init(identity: ignoredIdentity, confidence: .inferredStableForeground), [ignoredIdentity], nil),
            ("unsupported", ["public.png"], stableSource(), [], nil),
        ]

        for testCase in cases {
            let pasteboard = PasteboardSpy(metadata: .init(changeCount: 10, declaredTypeIdentifiers: testCase.1))
            let builder = EnvelopeBuilderSpy()
            let commit = CommitSpy()
            let coordinator = makeCoordinator(
                pasteboard: pasteboard,
                source: testCase.2,
                ignoredApplications: testCase.3,
                builder: builder,
                commit: commit
            )
            if let duration = testCase.4 {
                coordinator.pauseCapture(for: duration)
            }

            await coordinator.poll()

            XCTAssertEqual(pasteboard.metadataReadCount, 1, testCase.0)
            XCTAssertEqual(pasteboard.payloadReadCount, 0, testCase.0)
            XCTAssertEqual(builder.makeCallCount, 0, testCase.0)
            XCTAssertEqual(commit.callCount, 0, testCase.0)
            XCTAssertEqual(pasteboard.writeCount, 0, testCase.0)
        }
    }

    func testAuthorizedReadCommitsOnlyAfterCompletePayloadAndDerivation() async {
        let pasteboard = PasteboardSpy(
            metadata: .init(changeCount: 10, declaredTypeIdentifiers: ["public.utf8-plain-text"]),
            representations: [.init(kind: .plainText, data: Data("hello".utf8), textProjection: "hello")]
        )
        let builder = EnvelopeBuilderSpy()
        let commit = CommitSpy()
        let coordinator = makeCoordinator(pasteboard: pasteboard, source: stableSource(), builder: builder, commit: commit)

        await coordinator.poll()

        XCTAssertEqual(pasteboard.events, ["metadata", "payload"])
        XCTAssertEqual(builder.makeCallCount, 1)
        XCTAssertEqual(commit.callCount, 1)
        XCTAssertEqual(commit.envelopes.first?.retentionClass, .localHistory)
        XCTAssertEqual(pasteboard.writeCount, 0)
    }

    func testPayloadFailureDropsWholeEventWithoutDerivationCommitOrPasteboardMutation() async {
        let pasteboard = PasteboardSpy(
            metadata: .init(changeCount: 10, declaredTypeIdentifiers: ["public.utf8-plain-text", "public.rtf"]),
            readError: .representationReadFailed
        )
        let builder = EnvelopeBuilderSpy()
        let commit = CommitSpy()
        let coordinator = makeCoordinator(pasteboard: pasteboard, source: stableSource(), builder: builder, commit: commit)

        await coordinator.poll()

        XCTAssertEqual(pasteboard.payloadReadCount, 1)
        XCTAssertEqual(builder.makeCallCount, 0)
        XCTAssertEqual(commit.callCount, 0)
        XCTAssertEqual(pasteboard.writeCount, 0)
    }

    func testPauseDeadlineAndEarlyResume() async {
        let pasteboard = PasteboardSpy(metadata: .init(changeCount: 10, declaredTypeIdentifiers: ["public.utf8-plain-text"]))
        let builder = EnvelopeBuilderSpy()
        let commit = CommitSpy()
        let coordinator = makeCoordinator(pasteboard: pasteboard, source: stableSource(), builder: builder, commit: commit)
        coordinator.pauseCapture(for: 60)
        await coordinator.poll()
        XCTAssertEqual(pasteboard.payloadReadCount, 0)

        coordinator.resumeCapture()
        pasteboard.metadata = .init(changeCount: 11, declaredTypeIdentifiers: ["public.utf8-plain-text"])
        await coordinator.poll()

        XCTAssertEqual(pasteboard.payloadReadCount, 1)
        XCTAssertEqual(commit.callCount, 1)
    }

    func testExplicitSaveRejectsMarkerBeforeReadAndPurgesAfterCommitFailure() async throws {
        let markedPasteboard = PasteboardSpy(metadata: .init(changeCount: 10, declaredTypeIdentifiers: ["public.utf8-plain-text", "com.agilebits.onepassword"]))
        let blockedCoordinator = makeCoordinator(pasteboard: markedPasteboard, source: stableSource())
        let blockedRequest = await blockedCoordinator.beginExplicitSave()
        XCTAssertNil(blockedRequest)
        XCTAssertEqual(markedPasteboard.payloadReadCount, 0)

        let pasteboard = PasteboardSpy(metadata: .init(changeCount: 20, declaredTypeIdentifiers: ["public.utf8-plain-text"]))
        let commit = CommitSpy(error: .failed)
        let coordinator = makeCoordinator(pasteboard: pasteboard, source: stableSource(), commit: commit)
        let pendingRequest = await coordinator.beginExplicitSave()
        let request = try XCTUnwrap(pendingRequest)

        XCTAssertEqual(request.summary.representationKinds, [.plainText])
        XCTAssertFalse(request.summary.description.contains("hello"))
        let didConfirm = await coordinator.confirmExplicitSave(token: request.token)
        XCTAssertFalse(didConfirm)
        XCTAssertFalse(coordinator.explicitSaveSession.hasPendingBytes)
        XCTAssertEqual(pasteboard.writeCount, 0)
    }

    func testExplicitSaveAuthorizesOtherwiseUnknownCurrentItem() async throws {
        let pasteboard = PasteboardSpy(metadata: .init(changeCount: 30, declaredTypeIdentifiers: ["public.utf8-plain-text"]))
        let coordinator = makeCoordinator(
            pasteboard: pasteboard,
            source: .init(identity: nil, confidence: .unknown)
        )

        let pendingRequest = await coordinator.beginExplicitSave()

        let request = try XCTUnwrap(pendingRequest)
        XCTAssertEqual(request.token.changeCount, 30)
        XCTAssertEqual(pasteboard.payloadReadCount, 1)
    }

    func testSourceObservationIntervalSpansCoordinatorCreationToMetadataTicks() async {
        let pasteboard = PasteboardSpy(metadata: .init(changeCount: 40, declaredTypeIdentifiers: ["public.utf8-plain-text"]))
        let tracker = SourceTrackerStub(observation: stableSource())
        let coordinator = ClipboardCaptureCoordinator(
            pasteboard: pasteboard,
            sourceTracker: tracker,
            policy: .standard(consentGranted: true, ignoredApplications: []),
            envelopeBuilder: EnvelopeBuilderSpy(),
            commit: CommitSpy().call,
            now: { Date(timeIntervalSince1970: 1000) }
        )

        XCTAssertEqual(tracker.events, ["begin"])
        await coordinator.poll()
        XCTAssertEqual(tracker.events, ["begin", "finish", "begin"])

        pasteboard.metadata = .init(changeCount: 41, declaredTypeIdentifiers: ["public.utf8-plain-text"])
        _ = await coordinator.beginExplicitSave()
        XCTAssertEqual(tracker.events, ["begin", "finish", "begin", "finish", "begin"])
    }

    func testExplicitSavePrivacyMatrixOnlyOverridesUnknownSource() async {
        let ignored = ApplicationIdentity(bundleIdentifier: "com.example.Ignored", teamIdentifier: "TEAM123", signingIdentifier: "com.example.Ignored")
        let cases: [(String, SourceObservation, Set<ApplicationIdentity>, Bool, [String], Bool)] = [
            ("unknown allowed", .init(identity: nil, confidence: .unknown), [], false, ["public.utf8-plain-text"], true),
            ("stable allowed without override", stableSource(), [], false, ["public.utf8-plain-text"], true),
            ("paused", .init(identity: nil, confidence: .unknown), [], true, ["public.utf8-plain-text"], false),
            ("ignored verified identity", .init(identity: ignored, confidence: .inferredStableForeground), [ignored], false, ["public.utf8-plain-text"], false),
            ("private copy", .init(identity: nil, confidence: .unknown), [], false, ["public.utf8-plain-text", "kr.donminzzi.clipboardkeyboard.private-copy"], false),
            ("confidential", .init(identity: nil, confidence: .unknown), [], false, ["public.utf8-plain-text", "com.agilebits.onepassword"], false),
            ("unsupported", .init(identity: nil, confidence: .unknown), [], false, ["public.png"], false),
        ]

        for testCase in cases {
            let pasteboard = PasteboardSpy(metadata: .init(changeCount: 50, declaredTypeIdentifiers: testCase.4))
            let coordinator = makeCoordinator(
                pasteboard: pasteboard,
                source: testCase.1,
                ignoredApplications: testCase.2
            )
            if testCase.3 {
                coordinator.pauseCapture(for: 60)
            }

            let request = await coordinator.beginExplicitSave()

            XCTAssertEqual(request != nil, testCase.5, testCase.0)
            XCTAssertEqual(pasteboard.payloadReadCount, testCase.5 ? 1 : 0, testCase.0)
        }
    }

    func testWatcherStartsAfterDeadlineSkipsMissedTicksAndNeverOverlaps() async {
        let clock = PasteboardWatcherClockStub()
        let pollGate = AsyncGate()
        var callbackTimes: [UInt64] = []
        var activeCount = 0
        var maximumActiveCount = 0
        let watcher = PasteboardWatcher(
            intervalNanoseconds: 10,
            clock: .init(nowNanoseconds: clock.now, sleepUntil: clock.sleep)
        )
        watcher.start {
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
            callbackTimes.append(clock.now())
            if callbackTimes.count == 1 {
                await pollGate.wait()
            }
            activeCount -= 1
        }

        await clock.waitForSleeperCount(1)
        XCTAssertEqual(callbackTimes, [])
        clock.advance(to: 10)
        await waitUntil { callbackTimes.count == 1 }
        clock.advance(to: 50)
        XCTAssertEqual(callbackTimes, [10])
        XCTAssertEqual(maximumActiveCount, 1)

        await pollGate.open()
        await clock.waitForSleeperCount(2)
        clock.advance(to: 59)
        XCTAssertEqual(callbackTimes, [10])
        clock.advance(to: 60)
        await waitUntil { callbackTimes.count == 2 }
        XCTAssertEqual(callbackTimes, [10, 60])
        XCTAssertEqual(maximumActiveCount, 1)
        watcher.stop()
    }

    func testWatcherStopAndLifetimeReleasePreventFurtherCallbacks() async {
        let clock = PasteboardWatcherClockStub()
        var callbackCount = 0
        var watcher: PasteboardWatcher? = PasteboardWatcher(
            intervalNanoseconds: 10,
            clock: .init(nowNanoseconds: clock.now, sleepUntil: clock.sleep)
        )
        let weakWatcher = WeakReference(watcher)
        watcher?.start { callbackCount += 1 }
        await clock.waitForSleeperCount(1)

        watcher?.stop()
        clock.advance(to: 10)
        await Task.yield()
        XCTAssertEqual(callbackCount, 0)

        watcher?.start { callbackCount += 1 }
        await clock.waitForSleeperCount(2)
        watcher = nil
        clock.advance(to: 20)
        await Task.yield()
        XCTAssertNil(weakWatcher.value)
        XCTAssertEqual(callbackCount, 0)
    }

    private func stableSource() -> SourceObservation {
        .init(identity: stableIdentity, confidence: .inferredStableForeground)
    }

    private func makeCoordinator(
        pasteboard: PasteboardSpy,
        source: SourceObservation,
        ignoredApplications: Set<ApplicationIdentity> = [],
        builder: EnvelopeBuilderSpy = EnvelopeBuilderSpy(),
        commit: CommitSpy = CommitSpy()
    ) -> ClipboardCaptureCoordinator {
        ClipboardCaptureCoordinator(
            pasteboard: pasteboard,
            sourceTracker: SourceTrackerStub(observation: source),
            policy: .standard(consentGranted: true, ignoredApplications: ignoredApplications),
            envelopeBuilder: builder,
            commit: commit.call,
            now: { Date(timeIntervalSince1970: 1000) }
        )
    }
}

@MainActor
private final class PasteboardSpy: MacPasteboardReading {
    var metadata: MacPasteboardMetadata
    var representations: [RawTextRepresentation]
    var readError: MacPasteboardError?
    var metadataReadCount = 0
    var payloadReadCount = 0
    var writeCount = 0
    var events: [String] = []

    init(
        metadata: MacPasteboardMetadata,
        representations: [RawTextRepresentation] = [.init(kind: .plainText, data: Data("hello".utf8), textProjection: "hello")],
        readError: MacPasteboardError? = nil
    ) {
        self.metadata = metadata
        self.representations = representations
        self.readError = readError
    }

    func readMetadata() -> MacPasteboardMetadata {
        metadataReadCount += 1
        events.append("metadata")
        return metadata
    }

    func readSupportedRepresentations(for _: Int) throws -> [RawTextRepresentation] {
        payloadReadCount += 1
        events.append("payload")
        if let readError {
            throw readError
        }
        return representations
    }

    func writeRepresentations(_: [RawTextRepresentation], marker _: String?) throws {
        writeCount += 1
    }
}

@MainActor
private final class SourceTrackerStub: SourceObservationTracking {
    let observation: SourceObservation
    private(set) var events: [String] = []

    init(observation: SourceObservation) {
        self.observation = observation
    }

    func beginInterval() {
        events.append("begin")
    }

    func finishInterval() -> SourceObservation {
        events.append("finish")
        return observation
    }
}

@MainActor
private final class EnvelopeBuilderSpy: ClipEnvelopeBuilding {
    var makeCallCount = 0

    func makeEnvelope(from content: ResolvedTextContent, sourceConfidence: SourceConfidence, retentionClass: RetentionClass) throws -> ClipEnvelope {
        makeCallCount += 1
        return ClipEnvelope(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            capturedAt: Date(timeIntervalSince1970: 1000),
            retentionClass: retentionClass,
            sourceConfidence: sourceConfidence,
            representations: content.originals.map { .init(kind: $0.kind, originalBytes: $0.data, keyedDigest: Data([1])) },
            canonicalInsertionString: content.insertionString,
            title: "title",
            contentKind: .plainText,
            category: nil,
            preview: "preview",
            valueCandidates: []
        )
    }
}

@MainActor
private final class CommitSpy {
    enum Failure: Error { case failed }
    var callCount = 0
    var envelopes: [ClipEnvelope] = []
    let error: Failure?

    init(error: Failure? = nil) {
        self.error = error
    }

    func call(_ envelope: ClipEnvelope) async throws {
        callCount += 1
        envelopes.append(envelope)
        if let error {
            throw error
        }
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private final class PasteboardWatcherClockStub: @unchecked Sendable {
    private struct Sleeper {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var currentNanoseconds: UInt64 = 0
    private var sleepers: [Sleeper] = []
    private var totalSleeperCount = 0

    func now() -> UInt64 {
        lock.withLock { currentNanoseconds }
    }

    func sleep(until deadline: UInt64) async throws {
        if now() >= deadline {
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                sleepers.append(.init(deadline: deadline, continuation: continuation))
                totalSleeperCount += 1
            }
        }
    }

    func waitForSleeperCount(_ count: Int) async {
        while lock.withLock({ totalSleeperCount }) < count {
            await Task.yield()
        }
    }

    func advance(to nanoseconds: UInt64) {
        let ready: [Sleeper] = lock.withLock {
            currentNanoseconds = nanoseconds
            let ready = sleepers.filter { $0.deadline <= nanoseconds }
            sleepers.removeAll { $0.deadline <= nanoseconds }
            return ready
        }
        ready.forEach { $0.continuation.resume() }
    }
}

@MainActor
private func waitUntil(_ predicate: () -> Bool) async {
    while !predicate() {
        await Task.yield()
    }
}
