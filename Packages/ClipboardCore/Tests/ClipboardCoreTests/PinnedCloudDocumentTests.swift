import ClipboardCore
import Foundation
import XCTest

final class PinnedCloudDocumentTests: XCTestCase {
    func testRevisionPayloadEncodingIsDeterministicAndRoundTrips() throws {
        let revision = makeRevision()

        let first = try PinnedCloudDocument.encodePayload(for: .revision(revision))
        let second = try PinnedCloudDocument.encodePayload(for: .revision(revision))

        XCTAssertEqual(first, second)
        XCTAssertEqual(try PinnedCloudDocument.decodePayload(first), .revision(revision))
    }

    func testSchemaAndOpaqueRecordIdentityContract() {
        let revision = makeRevision()
        let tombstone = PinnedTombstone(
            itemID: revision.itemID,
            tombstoneID: uuid(3),
            libraryGeneration: 7,
            itemGeneration: 10,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_001),
            deviceID: "device"
        )
        let reset = LibraryResetGeneration(
            resetID: uuid(4),
            generation: 8,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_002),
            deviceID: "device"
        )

        XCTAssertEqual(PinnedCloudDocument.schemaVersion, 1)
        XCTAssertEqual(PinnedCloudDocument.zoneName, "PinnedLibrary")
        XCTAssertEqual(PinnedCloudDocument.RecordType.revision.rawValue, "PinnedRevision")
        XCTAssertEqual(PinnedCloudDocument.RecordType.tombstone.rawValue, "PinnedTombstone")
        XCTAssertEqual(PinnedCloudDocument.RecordType.reset.rawValue, "LibraryReset")
        XCTAssertEqual(PinnedCloudDocument.metadata(for: .revision(revision)).recordName, revision.revisionID.uuidString.lowercased())
        XCTAssertEqual(PinnedCloudDocument.metadata(for: .tombstone(tombstone)).recordName, tombstone.tombstoneID.uuidString.lowercased())
        XCTAssertEqual(PinnedCloudDocument.metadata(for: .reset(reset)).recordName, reset.resetID.uuidString.lowercased())
        XCTAssertNil(PinnedCloudDocument.payload(for: .tombstone(tombstone)))
        XCTAssertNil(PinnedCloudDocument.payload(for: .reset(reset)))
    }

    func testRevisionPayloadContainsAllUserAuthoredInlineContent() throws {
        let revision = makeRevision()
        let data = try XCTUnwrap(PinnedCloudDocument.payload(for: .revision(revision)))
        let decoded = try PinnedCloudDocument.decodePayload(data)

        XCTAssertEqual(decoded, .revision(revision))
        for sentinel in ["sentinel-title", "prompts", "sentinel-canonical"] {
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(sentinel))
        }
        guard case let .revision(value) = decoded else {
            return XCTFail("Expected a revision payload")
        }
        let originals = value.payload.representations.map(\.originalBytes)
        XCTAssertEqual(originals, ["plain-bytes", "markdown-bytes", "rtf-bytes", "html-bytes"].map { Data($0.utf8) })
    }

    private func makeRevision() -> PinnedRevision {
        PinnedRevision(
            itemID: uuid(1),
            revisionID: uuid(2),
            libraryGeneration: 7,
            itemGeneration: 9,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000.125),
            deviceID: "device",
            payload: PinPayload(
                representations: [
                    representation(.plainText, "plain-bytes"),
                    representation(.markdown, "markdown-bytes"),
                    representation(.rtf, "rtf-bytes"),
                    representation(.html, "html-bytes"),
                ],
                canonicalInsertionString: "sentinel-canonical",
                title: "sentinel-title",
                contentKind: .richText,
                category: .prompts
            )
        )
    }

    private func representation(_ kind: RepresentationKind, _ value: String) -> ClipRepresentation {
        let data = Data(value.utf8)
        return ClipRepresentation(kind: kind, originalBytes: data, keyedDigest: Data([UInt8(data.count)]))
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}
