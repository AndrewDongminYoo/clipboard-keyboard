import ClipboardCore
@testable import ClipboardKeyboardMac
import XCTest

@MainActor
final class SourceObservationTrackerTests: XCTestCase {
    private let identity = ApplicationIdentity(
        bundleIdentifier: "com.example.Editor",
        teamIdentifier: "TEAM123",
        signingIdentifier: "com.example.Editor"
    )

    func testStableVerifiedIdentityIsInferredStableForeground() {
        let provider = SourceSnapshotProviderStub(results: [
            .success(.init(identity: identity, activationGeneration: 7, helperAmbiguous: false)),
            .success(.init(identity: identity, activationGeneration: 7, helperAmbiguous: false)),
        ])
        let tracker = SourceObservationTracker(provider: provider)

        tracker.beginInterval()
        let observation = tracker.finishInterval()

        XCTAssertEqual(observation, .init(identity: identity, confidence: .inferredStableForeground))
    }

    func testActivationRaceIsUnknown() {
        let provider = SourceSnapshotProviderStub(results: [
            .success(.init(identity: identity, activationGeneration: 7, helperAmbiguous: false)),
            .success(.init(identity: identity, activationGeneration: 8, helperAmbiguous: false)),
        ])
        let tracker = SourceObservationTracker(provider: provider)

        tracker.beginInterval()

        XCTAssertEqual(tracker.finishInterval().confidence, .unknown)
    }

    func testEqualIdentityAfterAtoBtoARaceIsUnknownWhenEpochChanged() {
        let provider = SourceSnapshotProviderStub(results: [
            .success(.init(identity: identity, activationGeneration: 11, helperAmbiguous: false)),
            .success(.init(identity: identity, activationGeneration: 13, helperAmbiguous: false)),
        ])
        let tracker = SourceObservationTracker(provider: provider)

        tracker.beginInterval()

        XCTAssertEqual(tracker.finishInterval(), .init(identity: nil, confidence: .unknown))
    }

    func testFinishConsumesExactlyOnePriorBeginInterval() {
        let provider = SourceSnapshotProviderStub(results: [
            .success(.init(identity: identity, activationGeneration: 4, helperAmbiguous: false)),
            .success(.init(identity: identity, activationGeneration: 4, helperAmbiguous: false)),
        ])
        let tracker = SourceObservationTracker(provider: provider)

        XCTAssertEqual(tracker.finishInterval().confidence, .unknown)
        tracker.beginInterval()
        XCTAssertEqual(tracker.finishInterval().confidence, .inferredStableForeground)
        XCTAssertEqual(tracker.finishInterval().confidence, .unknown)
        XCTAssertEqual(provider.snapshotCount, 2)
    }

    func testMissingSigningDataHelperAmbiguityAndLookupFailureAreUnknown() {
        let cases: [[Result<SourceSnapshot, SourceSnapshotError>]] = [
            [.success(.init(identity: nil, activationGeneration: 1, helperAmbiguous: false)), .success(.init(identity: nil, activationGeneration: 1, helperAmbiguous: false))],
            [.success(.init(identity: identity, activationGeneration: 1, helperAmbiguous: true)), .success(.init(identity: identity, activationGeneration: 1, helperAmbiguous: true))],
            [.failure(.lookupFailed), .success(.init(identity: identity, activationGeneration: 1, helperAmbiguous: false))],
        ]

        for results in cases {
            let tracker = SourceObservationTracker(provider: SourceSnapshotProviderStub(results: results))
            tracker.beginInterval()
            XCTAssertEqual(tracker.finishInterval().confidence, .unknown)
        }
    }
}

@MainActor
private final class SourceSnapshotProviderStub: SourceSnapshotProviding {
    private var results: [Result<SourceSnapshot, SourceSnapshotError>]
    private(set) var snapshotCount = 0

    init(results: [Result<SourceSnapshot, SourceSnapshotError>]) {
        self.results = results
    }

    func snapshot() throws -> SourceSnapshot {
        snapshotCount += 1
        return try results.removeFirst().get()
    }
}
