@testable import ClipboardCore
import Foundation
import XCTest

final class KeyboardSnapshotTests: XCTestCase {
    private let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let refreshedAt = Date(timeIntervalSince1970: 1_699_999_000)

    func testCanonicalEncodingIsDeterministicAndContainsOnlyKeyboardFields() throws {
        let snapshot = try makeSnapshot(items: [item(2), item(1)])
        let codec = KeyboardSnapshotCodec()

        let first = try codec.encode(snapshot)
        let second = try codec.encode(snapshot)

        XCTAssertEqual(first, second)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "schemaVersion", "generation", "createdAt", "lastSuccessfulCloudRefresh",
                "contentDigest", "itemCount", "items",
            ])
        )
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["id"] as? String }, [uuid(1).uuidString, uuid(2).uuidString])
        XCTAssertEqual(
            try Set(XCTUnwrap(items.first).keys),
            Set(["id", "title", "category", "canonicalInsertionString"])
        )
        XCTAssertEqual(KeyboardSnapshotValidator().validate(first), .valid(snapshot))
    }

    func testDigestCoversCanonicalPayloadWithoutDigestField() throws {
        let snapshot = try makeSnapshot(items: [item(1)])

        XCTAssertEqual(snapshot.contentDigest, "e5a7393ff3714976c51170df620e4d38959a4edd0af4fe367f2e78b34668c98f")

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: KeyboardSnapshotCodec().encode(snapshot)) as? [String: Any]
        )
        object["contentDigest"] = String(repeating: "0", count: 64)
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertEqual(KeyboardSnapshotValidator().validate(tampered), .invalid(.digestMismatch))
    }

    func testValidatorRejectsItemCountMismatch() throws {
        let data = try modifiedSnapshotData { $0["itemCount"] = 99 }

        XCTAssertEqual(KeyboardSnapshotValidator().validate(data), .invalid(.itemCountMismatch))
    }

    func testValidatorRejectsUnknownSchema() throws {
        let data = try modifiedSnapshotData { $0["schemaVersion"] = 2 }

        XCTAssertEqual(KeyboardSnapshotValidator().validate(data), .invalid(.unsupportedSchema))
    }

    func testValidatorRejectsPartialJSON() {
        let partial = Data(#"{"schemaVersion":1,"items":["#.utf8)

        XCTAssertEqual(KeyboardSnapshotValidator().validate(partial), .invalid(.malformed))
    }

    func testValidatorRejectsDuplicateItemIdentifiers() throws {
        let duplicate = try makeSnapshot(items: [item(1), item(1)])
        let data = try KeyboardSnapshotCodec().encode(duplicate)

        XCTAssertEqual(KeyboardSnapshotValidator().validate(data), .invalid(.duplicateItemID))
    }

    func testOldValidSnapshotRemainsUsableAndRecommendsRefreshAfterTwentyFourHours() throws {
        let snapshot = try makeSnapshot(items: [item(1)])
        let exactlyTwentyFourHours = refreshedAt.addingTimeInterval(24 * 60 * 60)

        XCTAssertFalse(snapshot.refreshRecommended(at: exactlyTwentyFourHours))
        XCTAssertTrue(snapshot.refreshRecommended(at: exactlyTwentyFourHours.addingTimeInterval(1)))
        XCTAssertFalse(snapshot.items.isEmpty)
        XCTAssertEqual(
            try KeyboardSnapshotValidator().validate(KeyboardSnapshotCodec().encode(snapshot)),
            .valid(snapshot)
        )
    }

    func testAsyncOperationSerializerDoesNotAllowASecondOperationToOvertakeTheFirst() async throws {
        let serializer = AsyncOperationSerializer()
        let barrier = CoreSnapshotBarrier()
        let events = CoreEventRecorder()

        let first = Task {
            try await serializer.withOperation {
                await events.append("first-start")
                await barrier.suspend()
                await events.append("first-end")
            }
        }
        await barrier.waitUntilEntered()
        let second = Task {
            try await serializer.withOperation {
                await events.append("second")
            }
        }
        await Task.yield()

        let eventsBeforeRelease = await events.values
        XCTAssertEqual(eventsBeforeRelease, ["first-start"])
        await barrier.release()
        try await first.value
        try await second.value
        let finalEvents = await events.values
        XCTAssertEqual(finalEvents, ["first-start", "first-end", "second"])
    }

    func testAsyncOperationSerializerCancelledWaiterReleasesSlotWithoutRunningOperation() async throws {
        let serializer = AsyncOperationSerializer()
        let holder = CoreSnapshotBarrier()
        let events = CoreEventRecorder()
        let first = Task {
            try await serializer.withOperation {
                await holder.suspend()
            }
        }
        await holder.waitUntilEntered()
        let operation: @Sendable () async throws -> Void = {
            await events.append("cancelled-operation")
        }
        let cancelled = Task<Result<Void, Error>, Never> {
            do {
                try await serializer.withOperation(operation)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        while await serializer.waitingOperationCount == 0 {
            await Task.yield()
        }
        cancelled.cancel()
        await holder.release()
        try await first.value

        switch await cancelled.value {
        case .success:
            XCTFail("Expected cancellation")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError)
        }
        try await serializer.withOperation { await events.append("next-operation") }
        let finalEvents = await events.values
        XCTAssertEqual(finalEvents, ["next-operation"])
    }

    private func makeSnapshot(items: [KeyboardSnapshotItem]) throws -> KeyboardSnapshot {
        try KeyboardSnapshot.make(
            items: items,
            generation: 7,
            createdAt: createdAt,
            lastSuccessfulCloudRefresh: refreshedAt
        )
    }

    private func modifiedSnapshotData(_ modify: (inout [String: Any]) -> Void) throws -> Data {
        let snapshot = try makeSnapshot(items: [item(1)])
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: KeyboardSnapshotCodec().encode(snapshot)) as? [String: Any]
        )
        modify(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func item(_ suffix: Int) -> KeyboardSnapshotItem {
        KeyboardSnapshotItem(
            id: uuid(suffix),
            title: "Title \(suffix)",
            category: suffix == 1 ? .prompts : .code,
            canonicalInsertionString: "Insert \(suffix)"
        )
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}

private actor CoreSnapshotBarrier {
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
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CoreEventRecorder {
    private var events: [String] = []
    var values: [String] {
        events
    }

    func append(_ event: String) {
        events.append(event)
    }
}
