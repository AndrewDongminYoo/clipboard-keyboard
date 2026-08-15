import CloudKit
import CryptoKit
import Foundation

enum PhoneEncryptedAssetStoreError: Error, Equatable {
    case invalidAsset
    case protectedDataUnavailable
    case authenticationFailed
    case protectionFailed
    case writeFailed
}

struct PhoneEncryptedAsset: @unchecked Sendable {
    let asset: CKAsset
    let contentKey: Data
}

struct PhoneEncryptedAssetFileOperations: @unchecked Sendable {
    let createDirectory: (URL) throws -> Void
    let createEmpty: (URL) throws -> Void
    let write: (Data, URL) throws -> Void
    let read: (URL) throws -> Data
    let setCompleteProtection: (URL) throws -> Void
    let protection: (URL) throws -> FileProtectionType?
    let removeIfExists: (URL) throws -> Void

    static let live = PhoneEncryptedAssetFileOperations(
        createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
        createEmpty: { url in
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw PhoneEncryptedAssetStoreError.writeFailed
            }
        },
        write: { data, url in
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        },
        read: { try Data(contentsOf: $0) },
        setCompleteProtection: { url in
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
        },
        protection: { url in
            let value = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
            if let protection = value as? FileProtectionType {
                return protection
            }
            if let rawValue = value as? String {
                return FileProtectionType(rawValue: rawValue)
            }
            return nil
        },
        removeIfExists: { url in
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    )
}

final class PhoneProtectedDataAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var available: Bool

    init(initialValue: Bool) {
        available = initialValue
    }

    var isAvailable: Bool {
        lock.withLock { available }
    }

    func update(_ newValue: Bool) {
        lock.withLock { available = newValue }
    }
}

struct PhoneEncryptedAssetStore: @unchecked Sendable {
    private static let authenticatedContext = Data("clipboard-keyboard.cloud-asset.v1".utf8)

    private let directoryURL: URL
    private let operations: PhoneEncryptedAssetFileOperations
    private let protectedDataAvailable: @Sendable () -> Bool

    init(
        directoryURL: URL = Self.defaultDirectoryURL(),
        operations: PhoneEncryptedAssetFileOperations = .live,
        protectedDataAvailable: @escaping @Sendable () -> Bool
    ) {
        self.directoryURL = directoryURL
        self.operations = operations
        self.protectedDataAvailable = protectedDataAvailable
    }

    func makeAsset(for payload: Data) throws -> PhoneEncryptedAsset {
        guard protectedDataAvailable() else {
            throw PhoneEncryptedAssetStoreError.protectedDataUnavailable
        }
        let key = SymmetricKey(size: .bits256)
        let contentKey = key.withUnsafeBytes { Data($0) }
        let document: Data
        do {
            let sealed = try AES.GCM.seal(payload, using: key, authenticating: Self.authenticatedContext)
            guard let combined = sealed.combined else {
                throw PhoneEncryptedAssetStoreError.authenticationFailed
            }
            document = combined
        } catch let error as PhoneEncryptedAssetStoreError {
            throw error
        } catch {
            throw PhoneEncryptedAssetStoreError.authenticationFailed
        }

        let fileURL = directoryURL.appendingPathComponent("\(UUID().uuidString).cloudasset")
        do {
            try operations.createDirectory(directoryURL)
            try operations.createEmpty(fileURL)
            try operations.setCompleteProtection(fileURL)
            guard try operations.protection(fileURL) == .complete else {
                throw PhoneEncryptedAssetStoreError.protectionFailed
            }
            guard protectedDataAvailable() else {
                throw PhoneEncryptedAssetStoreError.protectedDataUnavailable
            }
            try operations.write(document, fileURL)
            guard try operations.protection(fileURL) == .complete else {
                throw PhoneEncryptedAssetStoreError.protectionFailed
            }
            guard protectedDataAvailable() else {
                throw PhoneEncryptedAssetStoreError.protectedDataUnavailable
            }
        } catch let error as PhoneEncryptedAssetStoreError {
            try? operations.removeIfExists(fileURL)
            throw error
        } catch {
            try? operations.removeIfExists(fileURL)
            throw PhoneEncryptedAssetStoreError.writeFailed
        }
        return PhoneEncryptedAsset(asset: CKAsset(fileURL: fileURL), contentKey: contentKey)
    }

    func openAsset(_ asset: CKAsset, contentKey: Data) throws -> Data {
        guard let fileURL = asset.fileURL else {
            throw PhoneEncryptedAssetStoreError.invalidAsset
        }
        defer { try? operations.removeIfExists(fileURL) }
        guard protectedDataAvailable() else {
            throw PhoneEncryptedAssetStoreError.protectedDataUnavailable
        }
        guard contentKey.count == 32 else {
            throw PhoneEncryptedAssetStoreError.invalidAsset
        }
        let document: Data
        do {
            document = try operations.read(fileURL)
        } catch {
            throw PhoneEncryptedAssetStoreError.protectedDataUnavailable
        }
        guard protectedDataAvailable() else {
            throw PhoneEncryptedAssetStoreError.protectedDataUnavailable
        }
        do {
            let box = try AES.GCM.SealedBox(combined: document)
            let payload = try AES.GCM.open(
                box,
                using: SymmetricKey(data: contentKey),
                authenticating: Self.authenticatedContext
            )
            guard protectedDataAvailable() else {
                throw PhoneEncryptedAssetStoreError.protectedDataUnavailable
            }
            return payload
        } catch let error as PhoneEncryptedAssetStoreError {
            throw error
        } catch {
            throw PhoneEncryptedAssetStoreError.authenticationFailed
        }
    }

    func removeAsset(_ asset: CKAsset) throws {
        guard let fileURL = asset.fileURL else {
            return
        }
        try operations.removeIfExists(fileURL)
    }

    private static func defaultDirectoryURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipboardKeyboard/CloudAssetStaging", isDirectory: true)
    }
}
