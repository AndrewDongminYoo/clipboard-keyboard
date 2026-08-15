import ClipboardCore
@testable import ClipboardKeyboardMac
import CloudKit
import XCTest

final class MacCloudRecordCodecTests: XCTestCase {
    func testStorageModeUsesExactSerializedPayloadBoundary() throws {
        let codec = MacCloudRecordCodec()

        XCTAssertEqual(try codec.storageMode(forSerializedByteCount: 524_288), .encryptedInline)
        XCTAssertEqual(try codec.storageMode(forSerializedByteCount: 524_289), .encryptedAsset)
    }

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

    func testLargeRevisionUsesOnlyEncryptedAssetAndContentKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let codec = MacCloudRecordCodec(assetStore: MacEncryptedAssetStore(directoryURL: directory))
        let revision = makeRevision(byteCount: 600_000)

        let record = try codec.encode(.revision(revision))

        let asset = try XCTUnwrap(record["asset"] as? CKAsset)
        XCTAssertNotNil(asset.fileURL)
        XCTAssertEqual((record.encryptedValues["contentKey"] as? Data)?.count, 32)
        XCTAssertNil(record.encryptedValues["payload"])
        XCTAssertNil(record.encryptedValues["metadata"])
        XCTAssertEqual(try codec.decode(record), .revision(revision))
        XCTAssertFalse(try FileManager.default.fileExists(atPath: XCTUnwrap(asset.fileURL).path))
    }

    func testExplicitStagingCleanupRemovesAssetsAfterSendFailureOrCancellation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let codec = MacCloudRecordCodec(assetStore: MacEncryptedAssetStore(directoryURL: directory))
        let record = try codec.encode(.revision(makeRevision(byteCount: 600_000)))
        let assetURL = try XCTUnwrap((record["asset"] as? CKAsset)?.fileURL)

        codec.cleanupStagedAsset(recordName: record.recordID.recordName)
        codec.cleanupStagedAsset(recordName: record.recordID.recordName)

        XCTAssertFalse(FileManager.default.fileExists(atPath: assetURL.path))
    }

    func testInvalidDownloadedRecordStillRemovesAsset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let codec = MacCloudRecordCodec(assetStore: MacEncryptedAssetStore(directoryURL: directory))
        let record = try codec.encode(.revision(makeRevision(byteCount: 600_000)))
        let assetURL = try XCTUnwrap((record["asset"] as? CKAsset)?.fileURL)
        record["schemaVersion"] = NSNumber(value: 99)

        XCTAssertThrowsError(try codec.decode(record)) { error in
            XCTAssertEqual(error as? MacCloudRecordCodecError, .invalidSchema)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: assetURL.path))
    }

    func testInboundDecodeCleanupNeverRemovesOutboundAssetWithSameRecordName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let codec = MacCloudRecordCodec(assetStore: MacEncryptedAssetStore(directoryURL: directory))
        let outbound = try codec.encode(.revision(makeRevision(byteCount: 600_000)))
        let outboundURL = try XCTUnwrap((outbound["asset"] as? CKAsset)?.fileURL)
        let inboundURL = directory.appendingPathComponent("inbound.cloudasset")
        try Data("downloaded".utf8).write(to: inboundURL)
        let inbound = CKRecord(recordType: outbound.recordType, recordID: outbound.recordID)
        inbound["schemaVersion"] = NSNumber(value: 99)
        inbound["asset"] = CKAsset(fileURL: inboundURL)

        XCTAssertThrowsError(try codec.decode(inbound))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inboundURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outboundURL.path))

        codec.cleanupStagedAsset(recordName: outbound.recordID.recordName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outboundURL.path))
    }

    private func makeRevision(byteCount: Int? = nil) -> PinnedRevision {
        let plainBytes = byteCount.map { Data(repeating: 97, count: $0) } ?? Data("plain".utf8)
        return PinnedRevision(
            itemID: uuid(1), revisionID: uuid(2), libraryGeneration: 2, itemGeneration: 3,
            modifiedAt: Date(timeIntervalSince1970: 11), deviceID: "mac",
            payload: PinPayload(
                representations: [
                    ClipRepresentation(kind: .plainText, originalBytes: plainBytes, keyedDigest: Data([1])),
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
