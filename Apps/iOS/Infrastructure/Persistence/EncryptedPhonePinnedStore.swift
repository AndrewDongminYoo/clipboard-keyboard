import ClipboardCore
import CryptoKit
import Foundation

enum EncryptedPhonePinnedStoreError: Error, Equatable, CustomStringConvertible {
    case keyUnavailable
    case protectedDataUnavailable
    case authenticationFailed
    case corruptDocument
    case protectionFailed
    case writeFailed

    var description: String {
        switch self {
        case .keyUnavailable: "keyUnavailable"
        case .protectedDataUnavailable: "protectedDataUnavailable"
        case .authenticationFailed: "authenticationFailed"
        case .corruptDocument: "corruptDocument"
        case .protectionFailed: "protectionFailed"
        case .writeFailed: "writeFailed"
        }
    }
}

final class ProtectedDataLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.withLock { active }
    }

    func revoke() {
        lock.withLock { active = false }
    }
}

struct PhonePinnedFileOperations: @unchecked Sendable {
    let fileExists: (URL) -> Bool
    let createDirectory: (URL) throws -> Void
    let createEmpty: (URL) throws -> Void
    let read: (URL) throws -> Data
    let write: (Data, URL) throws -> Void
    let setCompleteProtection: (URL) throws -> Void
    let protection: (URL) throws -> FileProtectionType?
    let replace: (URL, URL) throws -> Void
    let removeIfExists: (URL) throws -> Void

    static let live = PhonePinnedFileOperations(
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
        createEmpty: { url in
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw EncryptedPhonePinnedStoreError.writeFailed
            }
        },
        read: { try Data(contentsOf: $0) },
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
        setCompleteProtection: { url in
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
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
        replace: { temporaryURL, finalURL in
            if FileManager.default.fileExists(atPath: finalURL.path) {
                _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
            }
        },
        removeIfExists: { url in
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    )
}

actor EncryptedPhonePinnedStore {
    private static let schemaVersion: UInt8 = 1
    private static let authenticatedContext = Data("clipboard-keyboard.ios.pinned-replica".utf8)

    private let fileURL: URL
    private let key: SymmetricKey
    private let operations: PhonePinnedFileOperations
    private let lease: ProtectedDataLease
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var isOpen = true

    init(
        fileURL: URL,
        key: SymmetricKey,
        operations: PhonePinnedFileOperations = .live,
        lease: ProtectedDataLease
    ) {
        self.fileURL = fileURL
        self.key = key
        self.operations = operations
        self.lease = lease
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    func load() throws -> PinnedReplicaState {
        try requireOpenLease()
        guard operations.fileExists(fileURL) else {
            try requireOpenLease()
            return PinnedReplicaState()
        }
        try verifyCompleteProtection(at: fileURL)
        try requireOpenLease()
        let document: Data
        do {
            document = try operations.read(fileURL)
        } catch {
            throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
        }
        try requireOpenLease()
        let decoded = try decode(document)
        try requireOpenLease()
        return decoded
    }

    func save(_ state: PinnedReplicaState) throws {
        try requireOpenLease()
        let document = try encode(state)
        let parentURL = fileURL.deletingLastPathComponent()
        let temporaryURL = parentURL.appendingPathComponent(".\(UUID().uuidString).pinned.tmp")
        let restoreURL = parentURL.appendingPathComponent(".\(UUID().uuidString).pinned.restore.tmp")
        let hadFinal = operations.fileExists(fileURL)
        do {
            try operations.createDirectory(parentURL)
        } catch {
            throw EncryptedPhonePinnedStoreError.writeFailed
        }
        defer { try? operations.removeIfExists(temporaryURL) }
        defer { try? operations.removeIfExists(restoreURL) }

        let previousDocument: Data?
        if hadFinal {
            do {
                try verifyCompleteProtection(at: fileURL)
                try requireOpenLease()
                previousDocument = try operations.read(fileURL)
                try requireOpenLease()
                guard let previousDocument else {
                    throw EncryptedPhonePinnedStoreError.writeFailed
                }
                _ = try decode(previousDocument)
                try requireOpenLease()
            } catch let error as EncryptedPhonePinnedStoreError {
                throw error
            } catch {
                throw EncryptedPhonePinnedStoreError.writeFailed
            }
        } else {
            previousDocument = nil
        }

        do {
            try writeProtectedDocument(document, to: temporaryURL)
        } catch let error as EncryptedPhonePinnedStoreError {
            throw error
        } catch {
            throw EncryptedPhonePinnedStoreError.writeFailed
        }
        do {
            try operations.replace(temporaryURL, fileURL)
        } catch {
            guard lease.isActive else {
                throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
            }
            restorePreviousFinal(previousDocument, using: restoreURL, currentFinalMayBeWeak: false)
            guard lease.isActive else {
                throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
            }
            throw EncryptedPhonePinnedStoreError.writeFailed
        }
        try requireOpenLease()
        do {
            try operations.setCompleteProtection(fileURL)
            try verifyCompleteProtection(at: fileURL)
        } catch {
            guard lease.isActive else {
                throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
            }
            restorePreviousFinal(previousDocument, using: restoreURL, currentFinalMayBeWeak: true)
            guard lease.isActive else {
                throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
            }
            if error as? EncryptedPhonePinnedStoreError == .protectedDataUnavailable {
                throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
            }
            throw EncryptedPhonePinnedStoreError.protectionFailed
        }
        try requireOpenLease()
    }

    private func writeProtectedDocument(_ document: Data, to url: URL) throws {
        do {
            try operations.createEmpty(url)
        } catch {
            throw EncryptedPhonePinnedStoreError.writeFailed
        }
        do {
            try operations.setCompleteProtection(url)
            try verifyCompleteProtection(at: url)
            try requireOpenLease()
        } catch let error as EncryptedPhonePinnedStoreError where error == .protectedDataUnavailable {
            throw error
        } catch {
            throw EncryptedPhonePinnedStoreError.protectionFailed
        }
        do {
            try operations.write(document, url)
            try requireOpenLease()
        } catch let error as EncryptedPhonePinnedStoreError where error == .protectedDataUnavailable {
            throw error
        } catch {
            throw EncryptedPhonePinnedStoreError.writeFailed
        }
        do {
            try verifyCompleteProtection(at: url)
            let persistedDocument = try operations.read(url)
            try requireOpenLease()
            _ = try decode(persistedDocument)
            try requireOpenLease()
        } catch let error as EncryptedPhonePinnedStoreError {
            throw error
        } catch {
            throw EncryptedPhonePinnedStoreError.writeFailed
        }
    }

    private func restorePreviousFinal(
        _ previousDocument: Data?,
        using restoreURL: URL,
        currentFinalMayBeWeak: Bool
    ) {
        guard let previousDocument else {
            if currentFinalMayBeWeak {
                try? operations.removeIfExists(fileURL)
            }
            return
        }
        do {
            try writeProtectedDocument(previousDocument, to: restoreURL)
            try operations.replace(restoreURL, fileURL)
            try requireOpenLease()
            try operations.setCompleteProtection(fileURL)
            try verifyCompleteProtection(at: fileURL)
            try requireOpenLease()
        } catch {
            if lease.isActive, currentFinalMayBeWeak {
                try? operations.removeIfExists(fileURL)
            }
            try? operations.removeIfExists(restoreURL)
        }
    }

    func transaction<Result: Sendable>(
        _ operation: @Sendable (inout PinnedReplicaState) throws -> Result
    ) throws -> Result {
        var state = try load()
        let result = try operation(&state)
        try save(state)
        return result
    }

    func protectedDataWillBecomeUnavailable() {
        lease.revoke()
        isOpen = false
    }

    func reopen() throws {
        try requireActiveLease()
        if operations.fileExists(fileURL) {
            try verifyCompleteProtection(at: fileURL)
            try requireActiveLease()
            let document: Data
            do {
                document = try operations.read(fileURL)
            } catch {
                isOpen = false
                throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
            }
            try requireActiveLease()
            _ = try decode(document)
            try requireActiveLease()
        }
        try requireActiveLease()
        isOpen = true
    }

    private func requireOpenLease() throws {
        guard isOpen else {
            throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
        }
        try requireActiveLease()
    }

    private func requireActiveLease() throws {
        guard lease.isActive else {
            isOpen = false
            throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
        }
    }

    private func verifyCompleteProtection(at url: URL) throws {
        do {
            guard try operations.protection(url) == .complete else {
                throw EncryptedPhonePinnedStoreError.protectionFailed
            }
        } catch let error as EncryptedPhonePinnedStoreError {
            throw error
        } catch {
            throw EncryptedPhonePinnedStoreError.protectionFailed
        }
    }

    private func encode(_ state: PinnedReplicaState) throws -> Data {
        do {
            let plaintext = try encoder.encode(state)
            let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Self.authenticatedContext)
            guard let combined = sealed.combined else {
                throw EncryptedPhonePinnedStoreError.authenticationFailed
            }
            return Data([Self.schemaVersion]) + combined
        } catch let error as EncryptedPhonePinnedStoreError {
            throw error
        } catch {
            throw EncryptedPhonePinnedStoreError.authenticationFailed
        }
    }

    private func decode(_ document: Data) throws -> PinnedReplicaState {
        guard document.first == Self.schemaVersion else {
            throw EncryptedPhonePinnedStoreError.corruptDocument
        }
        do {
            let sealed = try AES.GCM.SealedBox(combined: document.dropFirst())
            let plaintext = try AES.GCM.open(sealed, using: key, authenticating: Self.authenticatedContext)
            return try decoder.decode(PinnedReplicaState.self, from: plaintext)
        } catch is CryptoKitError {
            throw EncryptedPhonePinnedStoreError.authenticationFailed
        } catch let error as EncryptedPhonePinnedStoreError {
            throw error
        } catch {
            throw EncryptedPhonePinnedStoreError.corruptDocument
        }
    }
}
