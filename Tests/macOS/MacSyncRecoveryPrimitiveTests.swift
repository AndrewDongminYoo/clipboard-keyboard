@testable import ClipboardKeyboardMac
import CryptoKit
import Foundation
import XCTest

final class MacSyncRecoveryPrimitiveTests: XCTestCase {
    func testResetForRecoveryRemovesOnlyEncryptedMetadataAndPermitsNewAccountBinding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("state.encrypted")
        let pinnedStoreURL = directory.appendingPathComponent("pinned-store.encrypted")
        let sentinel = Data("mac recovery plaintext sentinel".utf8)
        let pinnedStoreSentinel = Data("pinned content remains local".utf8)
        let store = MacSyncStateStore(
            fileURL: fileURL,
            key: SymmetricKey(data: Data(repeating: 2, count: 32))
        )

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try pinnedStoreSentinel.write(to: pinnedStoreURL)
        try await store.bind(accountIdentity: "account-a")
        try await store.saveRawState(sentinel, accountIdentity: "account-a")

        let encryptedMetadata = try Data(contentsOf: fileURL)
        XCTAssertNil(encryptedMetadata.range(of: sentinel))

        try await store.resetForRecovery()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: pinnedStoreURL), pinnedStoreSentinel)
        try await store.bind(accountIdentity: "account-b")

        try await store.resetForRecovery()
        try await store.resetForRecovery()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: pinnedStoreURL), pinnedStoreSentinel)
    }
}
