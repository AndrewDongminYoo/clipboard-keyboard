import ClipboardCore
import CloudKit
import Foundation

enum MacCloudRecordCodecError: Error, Equatable {
    case invalidSchema
    case invalidRecord
}

struct MacCloudRecordCodec: Sendable {
    static let zoneID = CKRecordZone.ID(zoneName: PinnedCloudDocument.zoneName, ownerName: CKCurrentUserDefaultName)

    func encode(_ mutation: PinnedMutation) throws -> CKRecord {
        let metadata = PinnedCloudDocument.metadata(for: mutation)
        let recordID = CKRecord.ID(recordName: metadata.recordName, zoneID: Self.zoneID)
        let record = CKRecord(recordType: metadata.recordType.rawValue, recordID: recordID)
        record["schemaVersion"] = PinnedCloudDocument.schemaVersion as CKRecordValue
        record["libraryGeneration"] = metadata.libraryGeneration as CKRecordValue
        record["mutationKind"] = metadata.mutationKind.rawValue as CKRecordValue
        if let itemGeneration = metadata.itemGeneration {
            record["itemGeneration"] = itemGeneration as CKRecordValue
        }
        record.encryptedValues["metadata"] = try PinnedCloudDocument.encryptedMetadata(for: mutation) as CKRecordValue
        if let payload = PinnedCloudDocument.payload(for: mutation) {
            record.encryptedValues["payload"] = payload as CKRecordValue
        }
        return record
    }

    func decode(_ record: CKRecord) throws -> PinnedMutation {
        guard (record["schemaVersion"] as? NSNumber)?.int64Value == PinnedCloudDocument.schemaVersion,
              record.recordID.zoneID == Self.zoneID,
              let metadata = record.encryptedValues["metadata"] as? Data
        else {
            throw MacCloudRecordCodecError.invalidSchema
        }
        let mutation = try PinnedCloudDocument.decodePayload(metadata)
        let expected = PinnedCloudDocument.metadata(for: mutation)
        guard record.recordType == expected.recordType.rawValue,
              record.recordID.recordName == expected.recordName,
              (record["libraryGeneration"] as? NSNumber)?.int64Value == expected.libraryGeneration,
              record["mutationKind"] as? String == expected.mutationKind.rawValue,
              (record["itemGeneration"] as? NSNumber)?.int64Value == expected.itemGeneration,
              (record.encryptedValues["payload"] as? Data) == PinnedCloudDocument.payload(for: mutation)
        else {
            throw MacCloudRecordCodecError.invalidRecord
        }
        return mutation
    }
}
