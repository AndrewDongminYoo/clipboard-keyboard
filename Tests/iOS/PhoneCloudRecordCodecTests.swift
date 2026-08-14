import ClipboardCore
@testable import ClipboardKeyboardiOS
import CloudKit
import XCTest

final class PhoneCloudRecordCodecTests: XCTestCase {
    func testStorageModeUsesExactSerializedPayloadBoundary() throws {
        let codec = PhoneCloudRecordCodec()

        XCTAssertEqual(try codec.storageMode(forSerializedByteCount: 524_288), .encryptedInline)
        XCTAssertEqual(try codec.storageMode(forSerializedByteCount: 524_289), .encryptedAsset)
    }

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

    func testLargeRevisionUsesOnlyEncryptedAssetAndContentKey() throws {
        let operations = PhoneAssetOperationsRecorder()
        let codec = PhoneCloudRecordCodec(assetStore: PhoneEncryptedAssetStore(
            directoryURL: URL(fileURLWithPath: "/protected-assets"),
            operations: operations.operations,
            protectedDataAvailable: { true }
        ))
        let revision = PinnedRevision(
            itemID: uuid(3), revisionID: uuid(4), libraryGeneration: 5, itemGeneration: 9,
            modifiedAt: Date(timeIntervalSince1970: 43), deviceID: "phone",
            payload: PinPayload(
                representations: [ClipRepresentation(
                    kind: .plainText, originalBytes: Data(repeating: 97, count: 600_000), keyedDigest: Data([8])
                )],
                canonicalInsertionString: "large", title: "private", contentKind: .plainText, category: .everyday
            )
        )

        let record = try codec.encode(.revision(revision))

        let asset = try XCTUnwrap(record["asset"] as? CKAsset)
        XCTAssertEqual((record.encryptedValues["contentKey"] as? Data)?.count, 32)
        XCTAssertNil(record.encryptedValues["payload"])
        XCTAssertNil(record.encryptedValues["metadata"])
        XCTAssertEqual(try codec.decode(record), .revision(revision))
        XCTAssertFalse(try operations.exists(XCTUnwrap(asset.fileURL)))
    }

    func testExplicitStagingCleanupRemovesAssetsAfterSendFailureOrCancellation() throws {
        let operations = PhoneAssetOperationsRecorder()
        let codec = PhoneCloudRecordCodec(assetStore: PhoneEncryptedAssetStore(
            directoryURL: URL(fileURLWithPath: "/protected-assets"),
            operations: operations.operations,
            protectedDataAvailable: { true }
        ))
        let revision = PinnedRevision(
            itemID: uuid(5), revisionID: uuid(6), libraryGeneration: 5, itemGeneration: 10,
            modifiedAt: Date(timeIntervalSince1970: 44), deviceID: "phone",
            payload: PinPayload(
                representations: [ClipRepresentation(
                    kind: .plainText, originalBytes: Data(repeating: 97, count: 600_000), keyedDigest: Data([7])
                )],
                canonicalInsertionString: "large", title: "private", contentKind: .plainText, category: .everyday
            )
        )
        let record = try codec.encode(.revision(revision))
        let assetURL = try XCTUnwrap((record["asset"] as? CKAsset)?.fileURL)

        codec.cleanupStagedAsset(recordName: record.recordID.recordName)
        codec.cleanupStagedAsset(recordName: record.recordID.recordName)

        XCTAssertFalse(operations.exists(assetURL))
    }

    func testProtectedDataRevocationRejectsDecodeWithoutReadingAndRemovesAsset() throws {
        let availability = PhoneProtectedDataAvailability(initialValue: true)
        let operations = PhoneAssetOperationsRecorder()
        let store = PhoneEncryptedAssetStore(
            directoryURL: URL(fileURLWithPath: "/protected-assets"),
            operations: operations.operations,
            protectedDataAvailable: { availability.isAvailable }
        )
        let codec = PhoneCloudRecordCodec(
            assetStore: store,
            protectedDataAvailable: { availability.isAvailable }
        )
        let revision = PinnedRevision(
            itemID: uuid(7), revisionID: uuid(8), libraryGeneration: 5, itemGeneration: 11,
            modifiedAt: Date(timeIntervalSince1970: 45), deviceID: "phone",
            payload: PinPayload(
                representations: [ClipRepresentation(
                    kind: .plainText, originalBytes: Data(repeating: 97, count: 600_000), keyedDigest: Data([6])
                )],
                canonicalInsertionString: "large", title: "private", contentKind: .plainText, category: .everyday
            )
        )
        let record = try codec.encode(.revision(revision))
        let assetURL = try XCTUnwrap((record["asset"] as? CKAsset)?.fileURL)

        availability.update(false)

        XCTAssertThrowsError(try codec.decode(record)) { error in
            XCTAssertEqual(error as? PhoneCloudRecordCodecError, .protectedDataUnavailable)
        }
        XCTAssertFalse(operations.events.contains(.read))
        XCTAssertFalse(operations.exists(assetURL))
    }

    func testInboundDecodeCleanupNeverRemovesOutboundAssetWithSameRecordName() throws {
        let operations = PhoneAssetOperationsRecorder()
        let store = PhoneEncryptedAssetStore(
            directoryURL: URL(fileURLWithPath: "/protected-assets"),
            operations: operations.operations,
            protectedDataAvailable: { true }
        )
        let codec = PhoneCloudRecordCodec(assetStore: store)
        let revision = PinnedRevision(
            itemID: uuid(9), revisionID: uuid(10), libraryGeneration: 5, itemGeneration: 12,
            modifiedAt: Date(timeIntervalSince1970: 46), deviceID: "phone",
            payload: PinPayload(
                representations: [ClipRepresentation(
                    kind: .plainText, originalBytes: Data(repeating: 97, count: 600_000), keyedDigest: Data([5])
                )],
                canonicalInsertionString: "large", title: "private", contentKind: .plainText, category: .everyday
            )
        )
        let outbound = try codec.encode(.revision(revision))
        let outboundURL = try XCTUnwrap((outbound["asset"] as? CKAsset)?.fileURL)
        let inboundURL = URL(fileURLWithPath: "/protected-assets/inbound.cloudasset")
        try operations.operations.createEmpty(inboundURL)
        let inbound = CKRecord(recordType: outbound.recordType, recordID: outbound.recordID)
        inbound["schemaVersion"] = NSNumber(value: 99)
        inbound["asset"] = CKAsset(fileURL: inboundURL)

        XCTAssertThrowsError(try codec.decode(inbound))
        XCTAssertFalse(operations.exists(inboundURL))
        XCTAssertTrue(operations.exists(outboundURL))

        codec.cleanupStagedAsset(recordName: outbound.recordID.recordName)
        XCTAssertFalse(operations.exists(outboundURL))
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}
