import ClipboardCore
import CloudKit
import Foundation

enum MacCloudRecordCodecError: Error, Equatable {
    case invalidSchema
    case invalidRecord
}

struct MacCloudRecordCodec: Sendable {
    static let zoneID = CKRecordZone.ID(zoneName: PinnedCloudDocument.zoneName, ownerName: CKCurrentUserDefaultName)
    private let assetStore: MacEncryptedAssetStore
    private let stagedAssets: MacStagedCloudAssetRegistry

    init(
        assetStore: MacEncryptedAssetStore = MacEncryptedAssetStore(),
        stagedAssets: MacStagedCloudAssetRegistry = MacStagedCloudAssetRegistry()
    ) {
        self.assetStore = assetStore
        self.stagedAssets = stagedAssets
    }

    func storageMode(forSerializedByteCount byteCount: Int) throws -> PinnedCloudStorageMode {
        guard byteCount >= 0 else {
            throw MacCloudRecordCodecError.invalidRecord
        }
        return PinnedCloudDocument.storageMode(forSerializedByteCount: byteCount)
    }

    func encode(_ mutation: PinnedMutation) throws -> CKRecord {
        let metadata = PinnedCloudDocument.metadata(for: mutation)
        cleanupStagedAsset(recordName: metadata.recordName)
        let recordID = CKRecord.ID(recordName: metadata.recordName, zoneID: Self.zoneID)
        let record = CKRecord(recordType: metadata.recordType.rawValue, recordID: recordID)
        record["schemaVersion"] = PinnedCloudDocument.schemaVersion as CKRecordValue
        record["libraryGeneration"] = metadata.libraryGeneration as CKRecordValue
        record["mutationKind"] = metadata.mutationKind.rawValue as CKRecordValue
        if let itemGeneration = metadata.itemGeneration {
            record["itemGeneration"] = itemGeneration as CKRecordValue
        }
        let serialized = try PinnedCloudDocument.encodePayload(for: mutation)
        if case .revision = mutation {
            switch try storageMode(forSerializedByteCount: serialized.count) {
            case .encryptedInline:
                record.encryptedValues["payload"] = serialized as CKRecordValue
            case .encryptedAsset:
                let staged = try assetStore.makeAsset(for: serialized)
                record["asset"] = staged.asset
                record.encryptedValues["contentKey"] = staged.contentKey as CKRecordValue
                stagedAssets.insert(staged.asset, recordName: metadata.recordName)
            }
        } else {
            record.encryptedValues["metadata"] = serialized as CKRecordValue
        }
        return record
    }

    func decode(_ record: CKRecord) throws -> PinnedMutation {
        defer { cleanupDecodedAsset(record) }
        guard (record["schemaVersion"] as? NSNumber)?.int64Value == PinnedCloudDocument.schemaVersion,
              record.recordID.zoneID == Self.zoneID
        else {
            throw MacCloudRecordCodecError.invalidSchema
        }
        let serialized: Data
        if record.recordType == PinnedCloudDocument.RecordType.revision.rawValue {
            if let payload = record.encryptedValues["payload"] as? Data,
               record["asset"] == nil,
               record.encryptedValues["contentKey"] == nil,
               try storageMode(forSerializedByteCount: payload.count) == .encryptedInline
            {
                serialized = payload
            } else if let asset = record["asset"] as? CKAsset,
                      let contentKey = record.encryptedValues["contentKey"] as? Data,
                      record.encryptedValues["payload"] == nil
            {
                serialized = try assetStore.openAsset(asset, contentKey: contentKey)
                guard try storageMode(forSerializedByteCount: serialized.count) == .encryptedAsset else {
                    throw MacCloudRecordCodecError.invalidRecord
                }
            } else {
                throw MacCloudRecordCodecError.invalidRecord
            }
        } else if let metadata = record.encryptedValues["metadata"] as? Data,
                  record.encryptedValues["payload"] == nil,
                  record["asset"] == nil,
                  record.encryptedValues["contentKey"] == nil
        {
            serialized = metadata
        } else {
            throw MacCloudRecordCodecError.invalidRecord
        }
        let mutation = try PinnedCloudDocument.decodePayload(serialized)
        let expected = PinnedCloudDocument.metadata(for: mutation)
        guard record.recordType == expected.recordType.rawValue,
              record.recordID.recordName == expected.recordName,
              (record["libraryGeneration"] as? NSNumber)?.int64Value == expected.libraryGeneration,
              record["mutationKind"] as? String == expected.mutationKind.rawValue,
              (record["itemGeneration"] as? NSNumber)?.int64Value == expected.itemGeneration
        else {
            throw MacCloudRecordCodecError.invalidRecord
        }
        return mutation
    }

    func cleanupStagedAsset(recordName: String) {
        guard let asset = stagedAssets.remove(recordName: recordName) else {
            return
        }
        try? assetStore.removeAsset(asset)
    }

    func cleanupAllStagedAssets() {
        for asset in stagedAssets.removeAll() {
            try? assetStore.removeAsset(asset)
        }
    }

    private func cleanupDecodedAsset(_ record: CKRecord) {
        guard let asset = record["asset"] as? CKAsset else { return }
        try? assetStore.removeAsset(asset)
    }
}

final class MacStagedCloudAssetRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var assetsByRecordName: [String: CKAsset] = [:]

    func insert(_ asset: CKAsset, recordName: String) {
        lock.withLock { assetsByRecordName[recordName] = asset }
    }

    func remove(recordName: String) -> CKAsset? {
        lock.withLock { assetsByRecordName.removeValue(forKey: recordName) }
    }

    func removeAll() -> [CKAsset] {
        lock.withLock {
            defer { assetsByRecordName.removeAll() }
            return Array(assetsByRecordName.values)
        }
    }
}
