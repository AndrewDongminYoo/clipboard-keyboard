import ClipboardCore
import CryptoKit
import Foundation

protocol ClipCipher: Sendable {
    func seal(_ envelope: ClipEnvelope) throws -> Data
    func open(_ data: Data) throws -> ClipEnvelope
}

struct AESGCMClipCipher: ClipCipher {
    private static let schemaVersion: UInt8 = 1
    private static let authenticatedHeaderByteCount = 17
    private static let minimumCombinedBoxByteCount = 28
    private let key: SymmetricKey
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(key: SymmetricKey) {
        self.key = key
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    func seal(_ envelope: ClipEnvelope) throws -> Data {
        let header = authenticatedHeader(id: envelope.id)
        let plaintext: Data
        do {
            plaintext = try encoder.encode(envelope)
        } catch {
            throw PersistenceSecurityError.corruptRecord
        }

        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: key, authenticating: header)
            guard let combined = sealedBox.combined else {
                throw PersistenceSecurityError.authenticationFailed
            }
            return header + combined
        } catch let error as PersistenceSecurityError {
            throw error
        } catch {
            throw PersistenceSecurityError.authenticationFailed
        }
    }

    func open(_ data: Data) throws -> ClipEnvelope {
        guard data.count >= Self.authenticatedHeaderByteCount + Self.minimumCombinedBoxByteCount else {
            throw PersistenceSecurityError.corruptRecord
        }
        let header = data.prefix(Self.authenticatedHeaderByteCount)
        guard header.first == Self.schemaVersion else {
            throw PersistenceSecurityError.corruptRecord
        }
        let expectedID = uuid(from: header.dropFirst())
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: data.dropFirst(Self.authenticatedHeaderByteCount))
        } catch {
            throw PersistenceSecurityError.corruptRecord
        }

        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealedBox, using: key, authenticating: header)
        } catch {
            throw PersistenceSecurityError.authenticationFailed
        }
        do {
            let envelope = try decoder.decode(ClipEnvelope.self, from: plaintext)
            guard envelope.id == expectedID else {
                throw PersistenceSecurityError.corruptRecord
            }
            return envelope
        } catch let error as PersistenceSecurityError {
            throw error
        } catch {
            throw PersistenceSecurityError.corruptRecord
        }
    }

    private func authenticatedHeader(id: UUID) -> Data {
        var uuidBytes = id.uuid
        var header = Data([Self.schemaVersion])
        withUnsafeBytes(of: &uuidBytes) { header.append(contentsOf: $0) }
        return header
    }

    private func uuid(from bytes: Data.SubSequence) -> UUID {
        let value = Array(bytes)
        return UUID(uuid: (
            value[0], value[1], value[2], value[3],
            value[4], value[5], value[6], value[7],
            value[8], value[9], value[10], value[11],
            value[12], value[13], value[14], value[15]
        ))
    }
}
