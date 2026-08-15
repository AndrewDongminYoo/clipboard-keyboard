import CryptoKit
import Foundation
import Security

protocol PhoneMasterKeyProviding: Sendable {
    func loadOrCreateKey() throws -> SymmetricKey
}

struct PhoneKeychainOperations: @unchecked Sendable {
    let copyMatching: ([String: Any]) -> (OSStatus, Data?)
    let add: ([String: Any]) -> OSStatus
    let randomBytes: (Int) -> (OSStatus, Data)

    static let live = PhoneKeychainOperations(
        copyMatching: { query in
            var result: CFTypeRef?
            let operationStatus = SecItemCopyMatching(query as CFDictionary, &result)
            return (operationStatus, result as? Data)
        },
        add: { attributes in
            SecItemAdd(attributes as CFDictionary, nil)
        },
        randomBytes: { count in
            var bytes = Data(repeating: 0, count: count)
            let operationStatus = bytes.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
            }
            return (operationStatus, bytes)
        }
    )
}

struct PhoneKeychainMasterKeyStore: PhoneMasterKeyProviding {
    private static let keyByteCount = 32
    private static let service = "kr.donminzzi.clipboardkeyboard.master-key.ios"
    private let operations: PhoneKeychainOperations

    init(operations: PhoneKeychainOperations = .live) {
        self.operations = operations
    }

    func loadOrCreateKey() throws -> SymmetricKey {
        let query = baseQuery.merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        let (copyStatus, existingData) = operations.copyMatching(query)

        if copyStatus == errSecSuccess {
            return try key(from: existingData)
        }
        guard copyStatus == errSecItemNotFound else {
            throw EncryptedPhonePinnedStoreError.keyUnavailable
        }

        let (randomStatus, generatedData) = operations.randomBytes(Self.keyByteCount)
        guard randomStatus == errSecSuccess, generatedData.count == Self.keyByteCount else {
            throw EncryptedPhonePinnedStoreError.keyUnavailable
        }
        let attributes = baseQuery.merging([
            kSecValueData as String: generatedData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]) { _, new in new }
        let addStatus = operations.add(attributes)
        if addStatus == errSecDuplicateItem {
            let (reloadStatus, winningData) = operations.copyMatching(query)
            guard reloadStatus == errSecSuccess else {
                throw EncryptedPhonePinnedStoreError.keyUnavailable
            }
            return try key(from: winningData)
        }
        guard addStatus == errSecSuccess else {
            throw EncryptedPhonePinnedStoreError.keyUnavailable
        }
        return SymmetricKey(data: generatedData)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "master-key",
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func key(from data: Data?) throws -> SymmetricKey {
        guard let data, data.count == Self.keyByteCount else {
            throw EncryptedPhonePinnedStoreError.keyUnavailable
        }
        return SymmetricKey(data: data)
    }
}
