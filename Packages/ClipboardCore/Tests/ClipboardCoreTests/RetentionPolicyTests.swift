import ClipboardCore
import XCTest

final class RetentionPolicyTests: XCTestCase {
    func testEvictionIDsEvictsEveryUnpinnedRecordWhenHistoryIsDisabled() {
        let unpinned = record(id: 1, capturedAt: 199_999)
        let pinned = record(id: 2, capturedAt: 199_999, isPinned: true)

        let evicted = RetentionPolicy(
            maxAge: 24 * 60 * 60,
            maxUnpinnedCount: 200,
            historyEnabled: false
        ).evictionIDs(for: [unpinned, pinned], now: now)

        XCTAssertEqual(evicted, [unpinned.id])
    }

    func testEvictionIDsEvictsUnpinnedRecordsOlderThanMaximumAge() {
        let expired = record(id: 3, capturedAt: 113_599)
        let boundary = record(id: 4, capturedAt: 113_600)

        let evicted = RetentionPolicy(
            maxAge: 24 * 60 * 60,
            maxUnpinnedCount: 200,
            historyEnabled: true
        ).evictionIDs(for: [expired, boundary], now: now)

        XCTAssertEqual(evicted, [expired.id])
    }

    func testEvictionIDsEvictsOldestUnpinnedRecordOverCountLimit() throws {
        let records = (0 ... 200).map { offset in
            record(id: offset + 10, capturedAt: 200_000 - TimeInterval(offset))
        }

        let evicted = RetentionPolicy(
            maxAge: 24 * 60 * 60,
            maxUnpinnedCount: 200,
            historyEnabled: true
        ).evictionIDs(for: records, now: now)

        XCTAssertEqual(evicted, try [XCTUnwrap(records.last?.id)])
        XCTAssertEqual(records.filter { !evicted.contains($0.id) }.count, 200)
    }

    func testEvictionIDsUsesUUIDStringToBreakEqualCaptureTimeTies() {
        let lowerUUID = record(id: 800, capturedAt: 199_999)
        let higherUUID = record(id: 801, capturedAt: 199_999)
        let policy = RetentionPolicy(maxAge: 24 * 60 * 60, maxUnpinnedCount: 1, historyEnabled: true)

        let forwardEviction = policy.evictionIDs(for: [lowerUUID, higherUUID], now: now)
        let reverseEviction = policy.evictionIDs(for: [higherUUID, lowerUUID], now: now)

        XCTAssertEqual(forwardEviction, [lowerUUID.id])
        XCTAssertEqual(reverseEviction, [lowerUUID.id])
        XCTAssertEqual(forwardEviction, reverseEviction)
    }

    func testEvictionIDsNeverEvictsPinnedRecords() {
        let expiredPinned = record(id: 300, capturedAt: 0, isPinned: true)
        let recentUnpinned = record(id: 301, capturedAt: 199_999)

        let evicted = RetentionPolicy(
            maxAge: 24 * 60 * 60,
            maxUnpinnedCount: 0,
            historyEnabled: false
        ).evictionIDs(for: [expiredPinned, recentUnpinned], now: now)

        XCTAssertFalse(evicted.contains(expiredPinned.id))
        XCTAssertTrue(evicted.contains(recentUnpinned.id))
    }

    func testEvictionIDsUnionsAgeAndCountEvictions() throws {
        let expired = record(id: 400, capturedAt: 0)
        let freshRecords = (0 ... 200).map { offset in
            record(id: offset + 401, capturedAt: 200_000 - TimeInterval(offset))
        }
        let pinned = record(id: 700, capturedAt: 0, isPinned: true)
        let records = [expired] + freshRecords + [pinned]
        let policy = RetentionPolicy(maxAge: 24 * 60 * 60, maxUnpinnedCount: 200, historyEnabled: true)

        let evicted = policy.evictionIDs(for: records, now: now)

        XCTAssertEqual(evicted, try [expired.id, XCTUnwrap(freshRecords.last?.id)])
        XCTAssertFalse(evicted.contains(pinned.id))
        XCTAssertEqual(records.filter { !$0.isPinned && !evicted.contains($0.id) }.count, 200)
    }

    private var now: Date {
        Date(timeIntervalSince1970: 200_000)
    }

    private func record(id: Int, capturedAt: TimeInterval, isPinned: Bool = false) -> ClipMetadata {
        ClipMetadata(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            capturedAt: Date(timeIntervalSince1970: capturedAt),
            byteCount: 1,
            representationKinds: ["public.utf8-plain-text"],
            keyedDigest: Data([0x01]),
            sourceConfidence: .inferredStableForeground,
            isPinned: isPinned
        )
    }
}
