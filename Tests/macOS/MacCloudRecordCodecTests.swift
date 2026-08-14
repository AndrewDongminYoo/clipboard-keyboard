import ClipboardCore
@testable import ClipboardKeyboardMac
import CloudKit
import XCTest

final class MacCloudRecordCodecTests: XCTestCase {
    func testRevisionKeepsContentOnlyInEncryptedPayload() throws {
        let revision = makeRevision()
        let record = try MacCloudRecordCodec().encode(.revision(revision))

        XCTAssertEqual(record.recordType, "PinnedRevision")
        XCTAssertEqual(record.recordID.zoneID.zoneName, "PinnedLibrary")
        XCTAssertNotNil(record.encryptedValues["payload"])
        XCTAssertNil(record["payload"])
        for forbidden in ["title", "category", "canonicalInsertionString", "representations", "deviceID", "modifiedAt"] {
            XCTAssertFalse(record.allKeys().contains(forbidden))
        }
        XCTAssertEqual(try MacCloudRecordCodec().decode(record), .revision(revision))
    }

    func testTombstoneAndResetHaveNoContentPayloadAndRoundTrip() throws {
        let tombstone = PinnedTombstone(
            itemID: uuid(1), tombstoneID: uuid(3), libraryGeneration: 2, itemGeneration: 4,
            modifiedAt: Date(timeIntervalSince1970: 12), deviceID: "mac"
        )
        let reset = LibraryResetGeneration(
            resetID: uuid(4), generation: 3, modifiedAt: Date(timeIntervalSince1970: 13), deviceID: "mac"
        )

        for mutation in [PinnedMutation.tombstone(tombstone), .reset(reset)] {
            let record = try MacCloudRecordCodec().encode(mutation)
            XCTAssertNil(record.encryptedValues["payload"])
            XCTAssertNil(record["payload"])
            XCTAssertEqual(try MacCloudRecordCodec().decode(record), mutation)
        }
    }

    private func makeRevision() -> PinnedRevision {
        PinnedRevision(
            itemID: uuid(1), revisionID: uuid(2), libraryGeneration: 2, itemGeneration: 3,
            modifiedAt: Date(timeIntervalSince1970: 11), deviceID: "mac",
            payload: PinPayload(
                representations: [
                    ClipRepresentation(kind: .plainText, originalBytes: Data("plain".utf8), keyedDigest: Data([1])),
                    ClipRepresentation(kind: .markdown, originalBytes: Data("markdown".utf8), keyedDigest: Data([2])),
                    ClipRepresentation(kind: .rtf, originalBytes: Data("rtf".utf8), keyedDigest: Data([3])),
                    ClipRepresentation(kind: .html, originalBytes: Data("html".utf8), keyedDigest: Data([4])),
                ],
                canonicalInsertionString: "canonical", title: "title", contentKind: .richText, category: .code
            )
        )
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}
