import ClipboardCore
import Foundation
import XCTest

final class KeyboardSnapshotReaderTests: XCTestCase {
    func testValidSnapshotLoadsAndOldValidSnapshotRecommendsRefresh() throws {
        let snapshot = try makeSnapshot(refreshedAt: Date(timeIntervalSince1970: 100))
        let data = try KeyboardSnapshotCodec().encode(snapshot)
        let reader = reader(data: data, now: { Date(timeIntervalSince1970: 100 + 24 * 60 * 60 + 1) })

        XCTAssertEqual(reader.load(), .refreshRecommended(snapshot))
    }

    func testMissingSnapshotFailsClosed() {
        let reader = KeyboardSnapshotReader(
            containerURL: { URL(fileURLWithPath: "/container") },
            operations: KeyboardSnapshotReadOperations(exists: { _ in false }, protection: { _ in .complete }, read: { _ in Data() })
        )

        XCTAssertEqual(reader.load(), .unavailable(.missing))
    }

    func testLockedSnapshotFailsClosedWithoutReadingContent() {
        var didRead = false
        let reader = KeyboardSnapshotReader(
            containerURL: { URL(fileURLWithPath: "/container") },
            operations: KeyboardSnapshotReadOperations(
                exists: { $0.lastPathComponent == "keyboard-snapshot-v1.json" },
                protection: { _ in FileProtectionType.none },
                read: { _ in didRead = true; return Data() }
            )
        )

        XCTAssertEqual(reader.load(), .unavailable(.locked))
        XCTAssertFalse(didRead)
    }

    func testCorruptDigestPartialAndReplacementRaceFailClosed() throws {
        let valid = try KeyboardSnapshotCodec().encode(makeSnapshot(refreshedAt: Date()))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["contentDigest"] = String(repeating: "f", count: 64)
        let corrupt = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertEqual(reader(data: corrupt).load(), .unavailable(.corrupt))
        XCTAssertEqual(reader(data: Data(#"{"schemaVersion":1"#.utf8)).load(), .unavailable(.corrupt))

        var protectionChecks = 0
        let raced = KeyboardSnapshotReader(
            containerURL: { URL(fileURLWithPath: "/container") },
            operations: KeyboardSnapshotReadOperations(
                exists: { $0.lastPathComponent == "keyboard-snapshot-v1.json" },
                protection: { _ in
                    protectionChecks += 1
                    return protectionChecks == 1 ? .complete : FileProtectionType.none
                },
                read: { _ in valid }
            )
        )
        XCTAssertEqual(raced.load(), .unavailable(.locked))
    }

    func testUnsupportedSchemaFailsClosedWithDistinctReason() throws {
        let valid = try KeyboardSnapshotCodec().encode(makeSnapshot(refreshedAt: Date()))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["schemaVersion"] = 2
        let unsupported = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        XCTAssertEqual(reader(data: unsupported).load(), .unavailable(.unsupported))
    }

    func testRevocationFenceBeforeOrAfterReadFailsClosed() throws {
        let valid = try KeyboardSnapshotCodec().encode(makeSnapshot(refreshedAt: Date()))
        var fenceChecks = 0
        let reader = KeyboardSnapshotReader(
            containerURL: { URL(fileURLWithPath: "/container") },
            operations: KeyboardSnapshotReadOperations(
                exists: { url in
                    if url.lastPathComponent == "keyboard-snapshot-v1.revoked" {
                        fenceChecks += 1
                        return fenceChecks > 1
                    }
                    return url.lastPathComponent == "keyboard-snapshot-v1.json"
                },
                protection: { _ in .complete },
                read: { _ in valid }
            )
        )

        XCTAssertEqual(reader.load(), .unavailable(.revoked))
    }

    func testCompletedFenceABACannotReturnSnapshotSelectedBeforeDestructivePublication() throws {
        let outcome = try completedFenceABALoadResult()

        XCTAssertEqual(outcome.result, .unavailable(.revoked))
        XCTAssertEqual(outcome.selectedReadCount, 2)
    }

    func testUnsupportedPrimaryFailsClosedDespiteValidProtectedFallbackAndMatchingMarker() throws {
        let snapshot = try makeSnapshot(refreshedAt: Date())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: KeyboardSnapshotCodec().encode(snapshot)) as? [String: Any]
        )
        object["schemaVersion"] = 2
        let unsupported = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        XCTAssertEqual(
            try fallbackReader(primaryData: unsupported, primaryProtection: .complete, snapshot: snapshot).load(),
            .unavailable(.unsupported)
        )
    }

    func testCorruptPrimaryFailsClosedDespiteValidProtectedFallbackAndMatchingMarker() throws {
        let snapshot = try makeSnapshot(refreshedAt: Date())

        XCTAssertEqual(
            try fallbackReader(primaryData: Data("partial".utf8), primaryProtection: .complete, snapshot: snapshot).load(),
            .unavailable(.corrupt)
        )
    }

    func testLockedPrimaryFailsClosedDespiteValidProtectedFallbackAndMatchingMarker() throws {
        let snapshot = try makeSnapshot(refreshedAt: Date())

        XCTAssertEqual(
            try fallbackReader(
                primaryData: KeyboardSnapshotCodec().encode(snapshot),
                primaryProtection: FileProtectionType.none,
                snapshot: snapshot
            ).load(),
            .unavailable(.locked)
        )
    }

    func testMissingPrimaryUsesOnlyValidProtectedFallbackWithMatchingContentFreeMarker() throws {
        let snapshot = try makeSnapshot(refreshedAt: Date(timeIntervalSince1970: 1000))
        let fallback = try KeyboardSnapshotCodec().encode(snapshot)
        let marker = Data(snapshot.contentDigest.utf8)
        let reader = KeyboardSnapshotReader(
            containerURL: { URL(fileURLWithPath: "/container") },
            operations: KeyboardSnapshotReadOperations(
                exists: { url in
                    ["keyboard-snapshot-v1.previous", "keyboard-snapshot-v1.previous.digest"].contains(url.lastPathComponent)
                },
                protection: { _ in .complete },
                read: { url in
                    url.lastPathComponent == "keyboard-snapshot-v1.previous" ? fallback : marker
                }
            ),
            now: { Date(timeIntervalSince1970: 1001) }
        )

        XCTAssertEqual(reader.load(), .available(snapshot))
    }

    private func fallbackReader(
        primaryData: Data,
        primaryProtection: FileProtectionType,
        snapshot: KeyboardSnapshot
    ) throws -> KeyboardSnapshotReader {
        let fallback = try KeyboardSnapshotCodec().encode(snapshot)
        let marker = Data(snapshot.contentDigest.utf8)
        return KeyboardSnapshotReader(
            containerURL: { URL(fileURLWithPath: "/container") },
            operations: KeyboardSnapshotReadOperations(
                exists: { url in
                    url.lastPathComponent != "keyboard-snapshot-v1.revoked"
                },
                protection: { url in
                    url.lastPathComponent == "keyboard-snapshot-v1.json" ? primaryProtection : .complete
                },
                read: { url in
                    switch url.lastPathComponent {
                    case "keyboard-snapshot-v1.json": primaryData
                    case "keyboard-snapshot-v1.previous": fallback
                    default: marker
                    }
                }
            )
        )
    }

    private func reader(data: Data, now: @escaping @Sendable () -> Date = { Date() }) -> KeyboardSnapshotReader {
        KeyboardSnapshotReader(
            containerURL: { URL(fileURLWithPath: "/container") },
            operations: KeyboardSnapshotReadOperations(
                exists: { $0.lastPathComponent == "keyboard-snapshot-v1.json" },
                protection: { _ in .complete },
                read: { _ in data }
            ),
            now: now
        )
    }

    private func makeSnapshot(refreshedAt: Date?) throws -> KeyboardSnapshot {
        try KeyboardSnapshot.make(
            items: [
                KeyboardSnapshotItem(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    title: "Prompt", category: .prompts, canonicalInsertionString: "Insert"
                ),
            ],
            generation: 1,
            createdAt: Date(timeIntervalSince1970: 200),
            lastSuccessfulCloudRefresh: refreshedAt
        )
    }
}

private func completedFenceABALoadResult() throws -> (result: SnapshotLoadResult, selectedReadCount: Int) {
    let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let first = try KeyboardSnapshot.make(
        items: [
            KeyboardSnapshotItem(
                id: itemID, title: "Before delete", category: .everyday,
                canonicalInsertionString: "old plaintext"
            ),
        ],
        generation: 1,
        createdAt: Date(timeIntervalSince1970: 1000),
        lastSuccessfulCloudRefresh: Date(timeIntervalSince1970: 1000)
    )
    let authoritative = try KeyboardSnapshot.make(
        items: [],
        generation: 2,
        createdAt: Date(timeIntervalSince1970: 1001),
        lastSuccessfulCloudRefresh: Date(timeIntervalSince1970: 1001)
    )
    let firstData = try KeyboardSnapshotCodec().encode(first)
    let authoritativeData = try KeyboardSnapshotCodec().encode(authoritative)
    var selectedReadCount = 0
    let reader = KeyboardSnapshotReader(
        containerURL: { URL(fileURLWithPath: "/container") },
        operations: KeyboardSnapshotReadOperations(
            exists: { url in
                url.lastPathComponent == "keyboard-snapshot-v1.json"
            },
            protection: { _ in .complete },
            read: { _ in
                selectedReadCount += 1
                return selectedReadCount == 1 ? firstData : authoritativeData
            }
        ),
        now: { Date(timeIntervalSince1970: 1002) }
    )
    let result = reader.load()
    return (result, selectedReadCount)
}
