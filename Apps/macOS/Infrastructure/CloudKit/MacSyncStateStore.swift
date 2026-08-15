import CloudKit
import CryptoKit
import Foundation

enum MacSyncStateStoreError: Error, Equatable {
    case authenticationFailed
    case corruptState
    case accountMismatch
    case writeFailed
}

actor MacSyncStateStore {
    private struct Envelope: Codable {
        let accountIdentity: String
        let stateData: Data?
    }

    private static let schemaVersion: UInt8 = 2
    private static let context = Data("clipboard-keyboard.mac.cloudkit-state".utf8)
    private let fileURL: URL
    private let key: SymmetricKey
    private var boundAccountIdentity: String?

    init(fileURL: URL, key: SymmetricKey) {
        self.fileURL = fileURL
        self.key = key
    }

    func bind(accountIdentity: String) throws {
        if let envelope = try readEnvelope() {
            guard envelope.accountIdentity == accountIdentity else {
                throw MacSyncStateStoreError.accountMismatch
            }
        } else {
            try writeEnvelope(Envelope(accountIdentity: accountIdentity, stateData: nil))
        }
        boundAccountIdentity = accountIdentity
    }

    func load(accountIdentity: String) throws -> CKSyncEngine.State.Serialization? {
        guard let data = try loadRawState(accountIdentity: accountIdentity) else { return nil }
        do {
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            throw MacSyncStateStoreError.corruptState
        }
    }

    func load() throws -> CKSyncEngine.State.Serialization? {
        guard let boundAccountIdentity else { throw MacSyncStateStoreError.corruptState }
        return try load(accountIdentity: boundAccountIdentity)
    }

    func save(_ state: CKSyncEngine.State.Serialization) throws {
        guard let boundAccountIdentity else { throw MacSyncStateStoreError.corruptState }
        try saveRawState(JSONEncoder().encode(state), accountIdentity: boundAccountIdentity)
    }

    func loadRawState(accountIdentity: String) throws -> Data? {
        guard let envelope = try readEnvelope() else { return nil }
        guard envelope.accountIdentity == accountIdentity else {
            throw MacSyncStateStoreError.accountMismatch
        }
        boundAccountIdentity = accountIdentity
        return envelope.stateData
    }

    func saveRawState(_ stateData: Data, accountIdentity: String) throws {
        guard let envelope = try readEnvelope(), envelope.accountIdentity == accountIdentity else {
            throw MacSyncStateStoreError.accountMismatch
        }
        try writeEnvelope(Envelope(accountIdentity: accountIdentity, stateData: stateData))
        boundAccountIdentity = accountIdentity
    }

    func resetForRecovery() throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            boundAccountIdentity = nil
            return
        }
        guard !isDirectory.boolValue else { throw MacSyncStateStoreError.writeFailed }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw MacSyncStateStoreError.writeFailed
        }
        boundAccountIdentity = nil
    }

    private func readEnvelope() throws -> Envelope? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let document = try Data(contentsOf: fileURL)
        guard document.first == Self.schemaVersion else { throw MacSyncStateStoreError.corruptState }
        do {
            let box = try AES.GCM.SealedBox(combined: document.dropFirst())
            let plaintext = try AES.GCM.open(box, using: key, authenticating: Self.context)
            return try JSONDecoder().decode(Envelope.self, from: plaintext)
        } catch is CryptoKitError {
            throw MacSyncStateStoreError.authenticationFailed
        } catch let error as MacSyncStateStoreError {
            throw error
        } catch {
            throw MacSyncStateStoreError.corruptState
        }
    }

    private func writeEnvelope(_ envelope: Envelope) throws {
        do {
            let plaintext = try JSONEncoder().encode(envelope)
            let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Self.context)
            guard let combined = sealed.combined else { throw MacSyncStateStoreError.authenticationFailed }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (Data([Self.schemaVersion]) + combined).write(to: fileURL, options: [.atomic])
        } catch let error as MacSyncStateStoreError {
            throw error
        } catch {
            throw MacSyncStateStoreError.writeFailed
        }
    }
}
