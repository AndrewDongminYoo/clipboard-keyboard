import CloudKit
import CryptoKit
import Foundation

enum MacEncryptedAssetStoreError: Error, Equatable {
    case invalidAsset
    case authenticationFailed
    case writeFailed
}

struct MacEncryptedAsset: @unchecked Sendable {
    let asset: CKAsset
    let contentKey: Data
}

struct MacEncryptedAssetStore: @unchecked Sendable {
    private static let authenticatedContext = Data("clipboard-keyboard.cloud-asset.v1".utf8)

    private let directoryURL: URL

    init(directoryURL: URL = Self.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
    }

    func makeAsset(for payload: Data) throws -> MacEncryptedAsset {
        let key = SymmetricKey(size: .bits256)
        let contentKey = key.withUnsafeBytes { Data($0) }
        let document: Data
        do {
            let sealed = try AES.GCM.seal(payload, using: key, authenticating: Self.authenticatedContext)
            guard let combined = sealed.combined else {
                throw MacEncryptedAssetStoreError.authenticationFailed
            }
            document = combined
        } catch let error as MacEncryptedAssetStoreError {
            throw error
        } catch {
            throw MacEncryptedAssetStoreError.authenticationFailed
        }

        let fileURL = directoryURL.appendingPathComponent("\(UUID().uuidString).cloudasset")
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try document.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: fileURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw MacEncryptedAssetStoreError.writeFailed
        }
        return MacEncryptedAsset(asset: CKAsset(fileURL: fileURL), contentKey: contentKey)
    }

    func openAsset(_ asset: CKAsset, contentKey: Data) throws -> Data {
        guard let fileURL = asset.fileURL else {
            throw MacEncryptedAssetStoreError.invalidAsset
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard contentKey.count == 32 else {
            throw MacEncryptedAssetStoreError.invalidAsset
        }
        let document: Data
        do {
            document = try Data(contentsOf: fileURL)
        } catch {
            throw MacEncryptedAssetStoreError.invalidAsset
        }
        do {
            let box = try AES.GCM.SealedBox(combined: document)
            return try AES.GCM.open(
                box,
                using: SymmetricKey(data: contentKey),
                authenticating: Self.authenticatedContext
            )
        } catch {
            throw MacEncryptedAssetStoreError.authenticationFailed
        }
    }

    func removeAsset(_ asset: CKAsset) throws {
        guard let fileURL = asset.fileURL else {
            return
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func defaultDirectoryURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipboardKeyboard/CloudAssetStaging", isDirectory: true)
    }
}
