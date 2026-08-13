@testable import ClipboardKeyboardMac
import CryptoKit
import Security
import XCTest

final class MacKeychainMasterKeyStoreTests: XCTestCase {
    func testCreatesAndThenLoadsTheSame256BitKeyWithProtectedAccessibility() throws {
        let keyData = Data((0 ..< 32).map(UInt8.init))
        let keychain = KeychainFake(generatedKey: keyData)
        let store = MacKeychainMasterKeyStore(operations: keychain.operations)

        let created = try store.loadOrCreateKey()
        let loaded = try store.loadOrCreateKey()

        XCTAssertEqual(created.bytes, keyData)
        XCTAssertEqual(loaded.bytes, keyData)
        XCTAssertEqual(keychain.randomByteCount, 32)
        XCTAssertEqual(keychain.copyQueries.count, 2)
        try keychain.copyQueries.forEach(assertCopyQuery)
        try assertAddAttributes(XCTUnwrap(keychain.addedAttributes), expectedValue: keyData)
    }

    func testDuplicateItemRaceReloadsTheWinningKey() throws {
        let keychain = KeychainFake(generatedKey: Data(repeating: 7, count: 32))
        keychain.addStatus = errSecDuplicateItem
        keychain.duplicateWinningKey = Data(repeating: 8, count: 32)
        let store = MacKeychainMasterKeyStore(operations: keychain.operations)

        XCTAssertEqual(try store.loadOrCreateKey().bytes, Data(repeating: 8, count: 32))
        XCTAssertEqual(keychain.copyQueries.count, 2)
        try keychain.copyQueries.forEach(assertCopyQuery)
        try assertAddAttributes(XCTUnwrap(keychain.addedAttributes), expectedValue: Data(repeating: 7, count: 32))
    }

    func testReportsKeyUnavailableWhenKeychainAccessIsDenied() {
        let keychain = KeychainFake(generatedKey: Data(repeating: 7, count: 32))
        keychain.copyStatus = errSecInteractionNotAllowed
        let store = MacKeychainMasterKeyStore(operations: keychain.operations)

        XCTAssertThrowsError(try store.loadOrCreateKey()) { error in
            XCTAssertEqual(error as? PersistenceSecurityError, .keyUnavailable)
        }
        XCTAssertEqual(keychain.addCallCount, 0)
    }

    func testRejectsMalformedStoredKeyWithoutGeneratingFallback() {
        let keychain = KeychainFake(generatedKey: Data(repeating: 7, count: 32))
        keychain.initialStoredKey = Data(repeating: 1, count: 31)
        let store = MacKeychainMasterKeyStore(operations: keychain.operations)

        XCTAssertThrowsError(try store.loadOrCreateKey()) { error in
            XCTAssertEqual(error as? PersistenceSecurityError, .keyUnavailable)
        }
        XCTAssertEqual(keychain.addCallCount, 0)
    }

    private func assertCopyQuery(_ query: [String: Any]) throws {
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.andrewdongminyoo.clipboardkeyboard.master-key.mac")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "master-key")
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
    }

    private func assertAddAttributes(_ attributes: [String: Any], expectedValue: Data) throws {
        XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, "com.andrewdongminyoo.clipboardkeyboard.master-key.mac")
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, "master-key")
        XCTAssertEqual(attributes[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlocked as String)
        XCTAssertEqual(attributes[kSecValueData as String] as? Data, expectedValue)
        XCTAssertEqual(expectedValue.count, 32)
    }
}

private final class KeychainFake: @unchecked Sendable {
    private let lock = NSLock()
    private let generatedKey: Data
    private var storedKey: Data?
    var copyStatus: OSStatus = errSecSuccess
    var addStatus: OSStatus = errSecSuccess
    var initialStoredKey: Data? {
        get { lock.withLock { storedKey } }
        set { lock.withLock { storedKey = newValue } }
    }

    var duplicateWinningKey: Data?
    private(set) var randomByteCount: Int?
    private(set) var addCallCount = 0
    private var capturedCopyQueries: [[String: Any]] = []
    private var capturedAddedAttributes: [String: Any]?

    init(generatedKey: Data) {
        self.generatedKey = generatedKey
    }

    var copyQueries: [[String: Any]] {
        lock.withLock { capturedCopyQueries }
    }

    var addedAttributes: [String: Any]? {
        lock.withLock { capturedAddedAttributes }
    }

    var operations: KeychainOperations {
        KeychainOperations(
            copyMatching: { [self] query in
                lock.withLock {
                    capturedCopyQueries.append(query)
                    guard copyStatus == errSecSuccess else { return (copyStatus, nil) }
                    guard let storedKey else { return (errSecItemNotFound, nil) }
                    return (errSecSuccess, storedKey)
                }
            },
            add: { [self] attributes in
                lock.withLock {
                    addCallCount += 1
                    capturedAddedAttributes = attributes
                    if addStatus == errSecDuplicateItem {
                        storedKey = duplicateWinningKey
                        return addStatus
                    }
                    guard addStatus == errSecSuccess else { return addStatus }
                    storedKey = attributes[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            },
            randomBytes: { [self] count in
                lock.withLock {
                    randomByteCount = count
                    return (errSecSuccess, generatedKey)
                }
            }
        )
    }
}

private extension SymmetricKey {
    var bytes: Data {
        withUnsafeBytes { Data($0) }
    }
}
