import ClipboardCore
import CryptoKit
import Foundation

actor EncryptedMacPinnedStore {
    private static let schemaVersion: UInt8 = 1
    private static let authenticatedContext = Data("clipboard-keyboard.mac.pinned-replica".utf8)

    private let fileURL: URL
    private let key: SymmetricKey
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(fileURL: URL, key: SymmetricKey) {
        self.fileURL = fileURL
        self.key = key
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    func load() throws -> PinnedReplicaState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PinnedReplicaState()
        }
        let document: Data
        do {
            document = try Data(contentsOf: fileURL)
        } catch {
            throw PersistenceSecurityError.keyUnavailable
        }
        guard document.first == Self.schemaVersion else {
            throw PersistenceSecurityError.corruptRecord
        }
        do {
            let box = try AES.GCM.SealedBox(combined: document.dropFirst())
            let plaintext = try AES.GCM.open(box, using: key, authenticating: Self.authenticatedContext)
            return try decoder.decode(PinnedReplicaState.self, from: plaintext)
        } catch is CryptoKitError {
            throw PersistenceSecurityError.authenticationFailed
        } catch let error as PersistenceSecurityError {
            throw error
        } catch {
            throw PersistenceSecurityError.corruptRecord
        }
    }

    func save(_ state: PinnedReplicaState) throws {
        let plaintext: Data
        do {
            plaintext = try encoder.encode(state)
        } catch {
            throw PersistenceSecurityError.corruptRecord
        }
        let document: Data
        do {
            let box = try AES.GCM.seal(plaintext, using: key, authenticating: Self.authenticatedContext)
            guard let combined = box.combined else {
                throw PersistenceSecurityError.authenticationFailed
            }
            document = Data([Self.schemaVersion]) + combined
        } catch let error as PersistenceSecurityError {
            throw error
        } catch {
            throw PersistenceSecurityError.authenticationFailed
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try EncryptedStoreFileOperations.live.atomicWrite(document, fileURL)
        } catch {
            throw PersistenceSecurityError.atomicReplaceFailed
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
}
