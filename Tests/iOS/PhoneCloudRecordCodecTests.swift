import ClipboardCore
@testable import ClipboardKeyboardiOS
import CloudKit
import XCTest

final class PhoneCloudRecordCodecTests: XCTestCase {
    func testPhoneUsesSharedDeterministicEncryptedPayloadSchema() throws {
        let revision = PinnedRevision(
            itemID: uuid(1), revisionID: uuid(2), libraryGeneration: 5, itemGeneration: 8,
            modifiedAt: Date(timeIntervalSince1970: 42), deviceID: "phone",
            payload: PinPayload(
                representations: [ClipRepresentation(
                    kind: .plainText, originalBytes: Data("secret".utf8), keyedDigest: Data([9])
                )],
                canonicalInsertionString: "secret", title: "private", contentKind: .plainText, category: .everyday
            )
        )

        let record = try PhoneCloudRecordCodec().encode(.revision(revision))

        XCTAssertEqual(record.encryptedValues["payload"] as? Data, try PinnedCloudDocument.encodePayload(for: .revision(revision)))
        XCTAssertNil(record["payload"])
        XCTAssertNil(record["metadata"])
        XCTAssertEqual(
            Set(record.allKeys()).subtracting(["payload", "metadata"]),
            ["schemaVersion", "libraryGeneration", "itemGeneration", "mutationKind"]
        )
        XCTAssertEqual(try PhoneCloudRecordCodec().decode(record), .revision(revision))
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}
