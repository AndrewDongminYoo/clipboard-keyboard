import ClipboardCore
@testable import ClipboardKeyboardMac
import XCTest

@MainActor
final class ExplicitSaveSessionTests: XCTestCase {
    private let representations = [
        RawTextRepresentation(kind: .plainText, data: Data("secret".utf8), textProjection: "secret"),
        RawTextRepresentation(kind: .html, data: Data("<p>secret</p>".utf8), textProjection: nil),
    ]

    func testBeginExposesOnlyKindsAndByteCountThenConfirmationConsumesBytes() throws {
        let session = ExplicitSaveSession()
        let now = Date(timeIntervalSince1970: 100)

        let request = session.begin(changeCount: 4, representations: representations, now: now)

        XCTAssertEqual(request.token, ExplicitSaveToken(changeCount: 4, expiresAt: now.addingTimeInterval(30)))
        XCTAssertEqual(request.summary.representationKinds, [.plainText, .html])
        XCTAssertEqual(request.summary.totalByteCount, 19)
        XCTAssertEqual(try session.takeForConfirmation(token: request.token, now: now.addingTimeInterval(29)), representations)
        XCTAssertFalse(session.hasPendingBytes)
    }

    func testCancelTimeoutAndPasteboardChangePurgePendingBytes() {
        let session = ExplicitSaveSession()
        let now = Date(timeIntervalSince1970: 100)

        _ = session.begin(changeCount: 1, representations: representations, now: now)
        session.cancel()
        XCTAssertFalse(session.hasPendingBytes)

        let expired = session.begin(changeCount: 2, representations: representations, now: now)
        XCTAssertThrowsError(try session.takeForConfirmation(token: expired.token, now: now.addingTimeInterval(31)))
        XCTAssertFalse(session.hasPendingBytes)

        _ = session.begin(changeCount: 3, representations: representations, now: now)
        session.pasteboardDidChange(to: 4)
        XCTAssertFalse(session.hasPendingBytes)
    }

    func testWrongTokenPurgesPendingBytes() {
        let session = ExplicitSaveSession()
        let now = Date(timeIntervalSince1970: 100)
        _ = session.begin(changeCount: 5, representations: representations, now: now)

        XCTAssertThrowsError(try session.takeForConfirmation(
            token: ExplicitSaveToken(changeCount: 6, expiresAt: now.addingTimeInterval(30)),
            now: now
        ))
        XCTAssertFalse(session.hasPendingBytes)
    }

    func testAutonomousExpiryPurgesPendingBytesWithoutAnotherSessionCall() async {
        let scheduler = ExplicitSaveExpirySchedulerStub()
        let session = ExplicitSaveSession(confirmationInterval: 30, expirySleep: scheduler.sleep)

        _ = session.begin(changeCount: 7, representations: representations, now: Date())
        await scheduler.waitForSleeperCount(1)
        await scheduler.releaseSleeper(at: 0)
        await Task.yield()

        XCTAssertFalse(session.hasPendingBytes)
    }

    func testStaleExpiryCannotPurgeNewerSession() async {
        let scheduler = ExplicitSaveExpirySchedulerStub()
        let session = ExplicitSaveSession(confirmationInterval: 30, expirySleep: scheduler.sleep)

        _ = session.begin(changeCount: 8, representations: representations, now: Date())
        await scheduler.waitForSleeperCount(1)
        _ = session.begin(changeCount: 9, representations: representations, now: Date())
        await scheduler.waitForSleeperCount(2)

        await scheduler.releaseSleeper(at: 0)
        await Task.yield()
        XCTAssertTrue(session.hasPendingBytes)

        await scheduler.releaseSleeper(at: 1)
        await Task.yield()
        XCTAssertFalse(session.hasPendingBytes)
    }
}

private actor ExplicitSaveExpirySchedulerStub {
    private var sleepers: [CheckedContinuation<Void, Error>?] = []

    func sleep(for _: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sleepers.append(continuation)
        }
    }

    func waitForSleeperCount(_ count: Int) async {
        while sleepers.count < count {
            await Task.yield()
        }
    }

    func releaseSleeper(at index: Int) {
        sleepers[index]?.resume()
        sleepers[index] = nil
    }
}
