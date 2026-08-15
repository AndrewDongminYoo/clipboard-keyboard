@testable import ClipboardKeyboardMac
import CloudKit
import Foundation
import XCTest

final class MacEncryptedAssetStoreTests: XCTestCase {
    func testAssetCiphertextRoundTripsWithoutContainingPlaintextAndIsRemovedAfterOpen() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let plaintext = Data(repeating: 0x41, count: 524_289)

        let staged = try fixture.store.makeAsset(for: plaintext)
        let assetURL = try XCTUnwrap(staged.asset.fileURL)
        let ciphertext = try Data(contentsOf: assetURL)

        XCTAssertEqual(staged.contentKey.count, 32)
        XCTAssertNil(ciphertext.range(of: plaintext))
        XCTAssertEqual(try fixture.store.openAsset(staged.asset, contentKey: staged.contentKey), plaintext)
        XCTAssertFalse(FileManager.default.fileExists(atPath: assetURL.path))
    }

    func testWrongKeyAndTamperingFailAuthenticationAndStillRemoveTemporaryFile() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let plaintext = Data("private payload".utf8)

        let wrongKeyAsset = try fixture.store.makeAsset(for: plaintext)
        let wrongKeyURL = try XCTUnwrap(wrongKeyAsset.asset.fileURL)
        XCTAssertThrowsError(
            try fixture.store.openAsset(wrongKeyAsset.asset, contentKey: Data(repeating: 0, count: 32))
        ) { error in
            XCTAssertEqual(error as? MacEncryptedAssetStoreError, .authenticationFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrongKeyURL.path))

        let tamperedAsset = try fixture.store.makeAsset(for: plaintext)
        let tamperedURL = try XCTUnwrap(tamperedAsset.asset.fileURL)
        var tampered = try Data(contentsOf: tamperedURL)
        tampered[tampered.startIndex] ^= 0xFF
        try tampered.write(to: tamperedURL)
        XCTAssertThrowsError(try fixture.store.openAsset(tamperedAsset.asset, contentKey: tamperedAsset.contentKey)) { error in
            XCTAssertEqual(error as? MacEncryptedAssetStoreError, .authenticationFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tamperedURL.path))
    }

    func testInvalidKeyLengthStillRemovesDownloadedTemporaryFile() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let staged = try fixture.store.makeAsset(for: Data("private payload".utf8))
        let assetURL = try XCTUnwrap(staged.asset.fileURL)

        XCTAssertThrowsError(try fixture.store.openAsset(staged.asset, contentKey: Data())) { error in
            XCTAssertEqual(error as? MacEncryptedAssetStoreError, .invalidAsset)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: assetURL.path))
    }

    func testEveryAssetUsesANewContentKeyAndExplicitCleanupIsIdempotent() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let first = try fixture.store.makeAsset(for: Data("one".utf8))
        let second = try fixture.store.makeAsset(for: Data("two".utf8))

        XCTAssertNotEqual(first.contentKey, second.contentKey)
        try fixture.store.removeAsset(first.asset)
        try fixture.store.removeAsset(first.asset)
        XCTAssertFalse(try FileManager.default.fileExists(atPath: XCTUnwrap(first.asset.fileURL).path))
        try fixture.store.removeAsset(second.asset)
    }

    private func makeFixture() -> (directory: URL, store: MacEncryptedAssetStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (directory, MacEncryptedAssetStore(directoryURL: directory))
    }
}
