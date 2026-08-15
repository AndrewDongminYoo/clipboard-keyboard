import ClipboardCore
@testable import ClipboardKeyboardiOS
import CryptoKit
import Foundation
import Security
import XCTest

final class EncryptedPhonePinnedStoreTests: XCTestCase {
    func testAuthenticatedRoundTripUsesCompleteProtectionAndContainsNoPlaintext() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore(keyByte: 7)
        let state = stateContaining("secret prompt")

        try await store.save(state)

        let loadedState = try await store.load()
        XCTAssertEqual(loadedState, state)
        XCTAssertNil(try Data(contentsOf: fixture.fileURL).range(of: Data("secret prompt".utf8)))
        XCTAssertEqual(fixture.operations.protectedURLs.count, 2)
        XCTAssertEqual(fixture.operations.protectedURLs.last, fixture.fileURL)
        XCTAssertEqual(fixture.operations.protection(at: fixture.fileURL), .complete)
        XCTAssertEqual(fixture.ownedArtifactURLs, [])
    }

    func testRejectsWrongKeyTamperingAndUnknownSchemaWithoutPlaintextFallback() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        try await fixture.makeStore(keyByte: 3).save(stateContaining("authentication sentinel"))

        await XCTAssertThrowsErrorAsync(try await fixture.makeStore(keyByte: 4).load()) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .authenticationFailed)
        }

        var tampered = try Data(contentsOf: fixture.fileURL)
        tampered[tampered.index(before: tampered.endIndex)] ^= 0xFF
        try tampered.write(to: fixture.fileURL)
        await XCTAssertThrowsErrorAsync(try await fixture.makeStore(keyByte: 3).load()) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .authenticationFailed)
        }

        var unknownSchema = tampered
        unknownSchema[unknownSchema.startIndex] = 99
        try unknownSchema.write(to: fixture.fileURL)
        await XCTAssertThrowsErrorAsync(try await fixture.makeStore(keyByte: 3).load()) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .corruptDocument)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.appendingPathExtension("plaintext").path))
    }

    func testAtomicReplacementAndEveryFailedWritePathRemovesTemporaryFile() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore(keyByte: 5)
        try await store.save(stateContaining("first value"))
        try await store.save(stateContaining("second value"))
        XCTAssertEqual(fixture.operations.replacementCount, 1)
        let replacedState = try await store.load()
        XCTAssertEqual(replacedState, stateContaining("second value"))

        fixture.operations.failure = .afterPartialWrite
        await XCTAssertThrowsErrorAsync(try await store.save(stateContaining("must not persist"))) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .writeFailed)
        }
        XCTAssertEqual(fixture.ownedArtifactURLs, [])

        fixture.operations.failure = .protection
        await XCTAssertThrowsErrorAsync(try await store.save(stateContaining("must not persist either"))) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectionFailed)
        }
        XCTAssertEqual(fixture.ownedArtifactURLs, [])
    }

    func testProtectsEmptyTempBeforeWriteAndRollsBackEveryPostReplaceFailure() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore(keyByte: 9)
        let original = stateContaining("rollback original")
        try await store.save(original)

        fixture.operations.resetEvents()
        try await store.save(stateContaining("ordered write"))
        XCTAssertTrue(fixture.operations.protectedEmptyTempBeforeFirstWrite)

        try await store.save(original)
        fixture.operations.failure = .replacement
        await XCTAssertThrowsErrorAsync(try await store.save(stateContaining("replace failure secret"))) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .writeFailed)
        }
        fixture.operations.failure = .none
        let stateAfterReplacementFailure = try await fixture.makeStore(keyByte: 9).load()
        XCTAssertEqual(stateAfterReplacementFailure, original)

        fixture.operations.failure = .finalProtection
        await XCTAssertThrowsErrorAsync(try await store.save(stateContaining("final protection secret"))) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectionFailed)
        }
        fixture.operations.failure = .none
        let stateAfterFinalProtectionFailure = try await fixture.makeStore(keyByte: 9).load()
        XCTAssertEqual(stateAfterFinalProtectionFailure, original)
        XCTAssertEqual(fixture.ownedArtifactURLs, [])

        let emptyFixture = StoreFixture()
        defer { emptyFixture.remove() }
        emptyFixture.operations.failure = .finalProtection
        await XCTAssertThrowsErrorAsync(
            try await emptyFixture.makeStore(keyByte: 9).save(stateContaining("failed first final"))
        ) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectionFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyFixture.fileURL.path))
        XCTAssertEqual(emptyFixture.ownedArtifactURLs, [])

        try await store.save(original)
        fixture.operations.failure = .replacementAndRollback
        await XCTAssertThrowsErrorAsync(try await store.save(stateContaining("rollback failure secret"))) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .writeFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertEqual(fixture.ownedArtifactURLs, [])
    }

    func testMidWriteLockFailsClosedAndPreservesPriorFinal() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let lease = ProtectedDataLease()
        let store = fixture.makeStore(keyByte: 2, lease: lease)
        let original = stateContaining("mid-write original")
        try await store.save(original)
        fixture.operations.afterWrite = { lease.revoke() }

        await XCTAssertThrowsErrorAsync(try await store.save(stateContaining("mid-write stale secret"))) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectedDataUnavailable)
        }

        fixture.operations.afterWrite = nil
        let restored = try await fixture.makeStore(keyByte: 2).load()
        XCTAssertEqual(restored, original)
        XCTAssertEqual(fixture.ownedArtifactURLs, [])
    }

    func testLeaseRevokedImmediatelyAfterReplacePreservesProtectedNewFinal() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let lease = ProtectedDataLease()
        let store = fixture.makeStore(keyByte: 15, lease: lease)
        try await store.save(stateContaining("pre-replace value"))
        let replacement = stateContaining("post-replace protected value")
        fixture.operations.afterReplace = { lease.revoke() }

        await XCTAssertThrowsErrorAsync(try await store.save(replacement)) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectedDataUnavailable)
        }

        fixture.operations.afterReplace = nil
        let reopened = fixture.makeStore(keyByte: 15)
        try await reopened.reopen()
        let reopenedState = try await reopened.load()
        XCTAssertEqual(reopenedState, replacement)
        XCTAssertEqual(fixture.operations.protection(at: fixture.fileURL), .complete)
        XCTAssertEqual(fixture.ownedArtifactURLs, [])
    }

    func testLeaseRevokedDuringFinalProtectionPreservesProtectedNewFinal() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let lease = ProtectedDataLease()
        let store = fixture.makeStore(keyByte: 16, lease: lease)
        try await store.save(stateContaining("before final protection"))
        let replacement = stateContaining("protected before revoke")
        fixture.operations.duringFinalProtection = { lease.revoke() }

        await XCTAssertThrowsErrorAsync(try await store.save(replacement)) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectedDataUnavailable)
        }

        fixture.operations.duringFinalProtection = nil
        let reopened = fixture.makeStore(keyByte: 16)
        try await reopened.reopen()
        let reopenedState = try await reopened.load()
        XCTAssertEqual(reopenedState, replacement)
        XCTAssertEqual(fixture.operations.protection(at: fixture.fileURL), .complete)
        XCTAssertEqual(fixture.ownedArtifactURLs, [])
    }

    func testLoadAndReopenRejectLeaseRevokedDuringRead() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        try await fixture.makeStore(keyByte: 12).save(stateContaining("mid-read payload"))

        let loadLease = ProtectedDataLease()
        fixture.operations.afterRead = { loadLease.revoke() }
        let reader = fixture.makeStore(keyByte: 12, lease: loadLease)
        await XCTAssertThrowsErrorAsync(try await reader.load()) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectedDataUnavailable)
        }

        let reopenLease = ProtectedDataLease()
        fixture.operations.afterRead = { reopenLease.revoke() }
        let reopeningReader = fixture.makeStore(keyByte: 12, lease: reopenLease)
        await XCTAssertThrowsErrorAsync(try await reopeningReader.reopen()) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectedDataUnavailable)
        }
    }

    func testEveryLoadReadsCurrentEncryptedDocumentWithoutDecodedCache() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        try await fixture.makeStore(keyByte: 13).save(stateContaining("uncached payload"))
        let reader = fixture.makeStore(keyByte: 13)
        let readsBeforeLoad = fixture.operations.readCount

        _ = try await reader.load()
        _ = try await reader.load()

        XCTAssertEqual(fixture.operations.readCount - readsBeforeLoad, 2)
    }

    func testRevokedBackendCannotReopenAfterDifferentUnlockBecomesAvailable() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let oldLease = ProtectedDataLease()
        let oldBackend = fixture.makeStore(keyByte: 14, lease: oldLease)
        try await oldBackend.save(stateContaining("old lease payload"))

        await oldBackend.protectedDataWillBecomeUnavailable()
        let newBackend = fixture.makeStore(keyByte: 14)
        let newBackendState = try await newBackend.load()
        XCTAssertEqual(newBackendState, stateContaining("old lease payload"))

        await XCTAssertThrowsErrorAsync(try await oldBackend.reopen()) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectedDataUnavailable)
        }
    }

    func testLockRevokesBackendAndFreshLeaseReopenValidatesProtection() async throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore(keyByte: 6)
        try await store.save(stateContaining("cached value"))
        _ = try await store.load()

        await store.protectedDataWillBecomeUnavailable()
        await XCTAssertThrowsErrorAsync(try await store.load()) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectedDataUnavailable)
        }
        await XCTAssertThrowsErrorAsync(try await store.save(PinnedReplicaState())) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectedDataUnavailable)
        }

        let reopenedStore = fixture.makeStore(keyByte: 6)
        try await reopenedStore.reopen()
        let reopenedState = try await reopenedStore.load()
        XCTAssertEqual(reopenedState, stateContaining("cached value"))

        fixture.operations.forcedFinalProtection = FileProtectionType.none
        await XCTAssertThrowsErrorAsync(try await fixture.makeStore(keyByte: 6).reopen()) { error in
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectionFailed)
        }

        fixture.operations.forcedFinalProtection = nil
        fixture.operations.failure = .read
        await XCTAssertThrowsErrorAsync(try await fixture.makeStore(keyByte: 6).reopen()) { error in
            XCTAssertNotNil(error as? EncryptedPhonePinnedStoreError)
        }
    }

    func testKeychainUsesDataProtectionUnlockedAccessibilityAndReloadsDuplicateWinner() throws {
        let fake = PhoneKeychainFake(generatedKey: Data(repeating: 7, count: 32))
        fake.addStatus = errSecDuplicateItem
        fake.duplicateWinningKey = Data(repeating: 8, count: 32)
        let store = PhoneKeychainMasterKeyStore(operations: fake.operations)

        XCTAssertEqual(try store.loadOrCreateKey().bytes, Data(repeating: 8, count: 32))
        XCTAssertEqual(fake.randomByteCount, 32)
        XCTAssertEqual(fake.copyQueries.count, 2)
        XCTAssertEqual(fake.addedAttributes?[kSecAttrService as String] as? String, "kr.donminzzi.clipboardkeyboard.master-key.ios")
        XCTAssertEqual(fake.addedAttributes?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlocked as String)
        XCTAssertEqual(fake.addedAttributes?[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(fake.addedAttributes?[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(fake.addedAttributes?[kSecAttrAccount as String] as? String, "master-key")
        XCTAssertEqual((fake.addedAttributes?[kSecValueData as String] as? Data)?.count, 32)
        for query in fake.copyQueries {
            XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
            XCTAssertEqual(query[kSecAttrService as String] as? String, "kr.donminzzi.clipboardkeyboard.master-key.ios")
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, "master-key")
            XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
            XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
            XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        }
    }

    private func stateContaining(_ text: String) -> PinnedReplicaState {
        let payload = PinPayload(
            representations: [.init(kind: .plainText, originalBytes: Data(text.utf8), keyedDigest: Data([1]))],
            canonicalInsertionString: text,
            title: "Fixture",
            contentKind: .plainText,
            category: nil
        )
        let revision = PinnedRevision(
            itemID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            revisionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            libraryGeneration: 0,
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: 100),
            deviceID: "test-device",
            payload: payload
        )
        return PinnedReplicaState(primaryRevisions: [revision])
    }
}

private final class StoreFixture: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    lazy var fileURL = root.appendingPathComponent("pinned-replica.encrypted")
    let operations = RecordingPhoneFileOperations()

    var ownedArtifactURLs: [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".pinned.") }) ?? []
    }

    func makeStore(
        keyByte: UInt8,
        lease: ProtectedDataLease = ProtectedDataLease()
    ) -> EncryptedPhonePinnedStore {
        EncryptedPhonePinnedStore(
            fileURL: fileURL,
            key: SymmetricKey(data: Data(repeating: keyByte, count: 32)),
            operations: operations.operations,
            lease: lease
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RecordingPhoneFileOperations: @unchecked Sendable {
    enum Failure {
        case none
        case afterPartialWrite
        case protection
        case replacement
        case replacementAndRollback
        case finalProtection
        case read
    }

    private let lock = NSLock()
    var failure = Failure.none
    var forcedFinalProtection: FileProtectionType?
    var afterWrite: (@Sendable () -> Void)?
    var afterRead: (@Sendable () -> Void)?
    var afterReplace: (@Sendable () -> Void)?
    var duringFinalProtection: (@Sendable () -> Void)?
    private(set) var protectedURLs: [URL] = []
    private(set) var replacementCount = 0
    private(set) var readCount = 0
    private var protectionByURL: [URL: FileProtectionType] = [:]
    private var events: [(String, URL)] = []

    var protectedEmptyTempBeforeFirstWrite: Bool {
        lock.withLock {
            guard let writeIndex = events.firstIndex(where: { $0.0 == "write" }) else { return false }
            return events[..<writeIndex].contains { $0.0 == "protect" && $0.1.pathExtension == "tmp" }
        }
    }

    func resetEvents() {
        lock.withLock { events.removeAll() }
    }

    var operations: PhonePinnedFileOperations {
        PhonePinnedFileOperations(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
            createEmpty: { url in
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw FixtureError.injected
                }
            },
            read: { [self] url in
                if lock.withLock({ failure == .read }) {
                    throw FixtureError.injected
                }
                let data = try Data(contentsOf: url)
                lock.withLock { readCount += 1 }
                afterRead?()
                return data
            },
            write: { [self] data, url in
                lock.withLock {
                    events.append(("write", url))
                }
                try data.prefix(max(1, data.count / 2)).write(to: url)
                if lock.withLock({ failure == .afterPartialWrite }) {
                    throw FixtureError.injected
                }
                try data.write(to: url)
                afterWrite?()
            },
            setCompleteProtection: { [self] url in
                if lock.withLock({
                    if failure == .protection {
                        return true
                    }
                    if failure == .finalProtection, url.pathExtension == "encrypted" {
                        failure = .none
                        return true
                    }
                    return false
                }) {
                    throw FixtureError.injected
                }
                lock.withLock {
                    events.append(("protect", url))
                    protectedURLs.append(url)
                    protectionByURL[url] = .complete
                }
                if url.pathExtension == "encrypted" {
                    duringFinalProtection?()
                }
            },
            protection: { [self] url in
                lock.withLock {
                    if url.pathExtension == "encrypted", let forcedFinalProtection {
                        return forcedFinalProtection
                    }
                    return protectionByURL[url]
                }
            },
            replace: { [self] temporaryURL, finalURL in
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try FileManager.default.removeItem(at: finalURL)
                    lock.withLock { replacementCount += 1 }
                }
                if lock.withLock({
                    if failure == .replacement {
                        failure = .none
                        return true
                    }
                    return failure == .replacementAndRollback
                }) {
                    throw FixtureError.injected
                }
                try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
                lock.withLock { protectionByURL[finalURL] = protectionByURL[temporaryURL] }
                afterReplace?()
            },
            removeIfExists: { url in
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        )
    }

    func protection(at url: URL) -> FileProtectionType? {
        lock.withLock { protectionByURL[url] }
    }
}

private final class PhoneKeychainFake: @unchecked Sendable {
    private let lock = NSLock()
    private let generatedKey: Data
    private var storedKey: Data?
    var addStatus: OSStatus = errSecSuccess
    var duplicateWinningKey: Data?
    private(set) var randomByteCount: Int?
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

    var operations: PhoneKeychainOperations {
        PhoneKeychainOperations(
            copyMatching: { [self] query in
                lock.withLock {
                    capturedCopyQueries.append(query)
                    guard let storedKey else { return (errSecItemNotFound, nil) }
                    return (errSecSuccess, storedKey)
                }
            },
            add: { [self] attributes in
                lock.withLock {
                    capturedAddedAttributes = attributes
                    if addStatus == errSecDuplicateItem {
                        storedKey = duplicateWinningKey
                        return addStatus
                    }
                    storedKey = attributes[kSecValueData as String] as? Data
                    return addStatus
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

private enum FixtureError: Error {
    case injected
}

private extension SymmetricKey {
    var bytes: Data {
        withUnsafeBytes { Data($0) }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
