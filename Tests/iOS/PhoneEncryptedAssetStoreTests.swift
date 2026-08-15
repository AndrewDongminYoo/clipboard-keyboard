@testable import ClipboardKeyboardiOS
import CloudKit
import Foundation
import XCTest

final class PhoneEncryptedAssetStoreTests: XCTestCase {
    func testAssetIsProtectedBeforeFirstWriteAndRoundTripsWithCleanup() throws {
        let operations = PhoneAssetOperationsRecorder()
        let directory = URL(fileURLWithPath: "/protected-assets")
        let store = PhoneEncryptedAssetStore(
            directoryURL: directory,
            operations: operations.operations,
            protectedDataAvailable: { true }
        )
        let plaintext = Data(repeating: 0x41, count: 524_289)

        let staged = try store.makeAsset(for: plaintext)
        let assetURL = try XCTUnwrap(staged.asset.fileURL)

        XCTAssertEqual(operations.events.prefix(4), [.createDirectory, .createEmpty, .protect, .write])
        XCTAssertEqual(operations.protection(at: assetURL), .complete)
        XCTAssertNil(try XCTUnwrap(operations.data(at: assetURL)).range(of: plaintext))
        XCTAssertEqual(try store.openAsset(staged.asset, contentKey: staged.contentKey), plaintext)
        XCTAssertFalse(operations.exists(assetURL))
    }

    func testUnavailableProtectedDataAndAuthenticationFailureAreContentFreeAndCleanup() throws {
        let unavailableOperations = PhoneAssetOperationsRecorder()
        let unavailableStore = PhoneEncryptedAssetStore(
            directoryURL: URL(fileURLWithPath: "/unavailable"),
            operations: unavailableOperations.operations,
            protectedDataAvailable: { false }
        )
        XCTAssertThrowsError(try unavailableStore.makeAsset(for: Data("secret".utf8))) { error in
            XCTAssertEqual(error as? PhoneEncryptedAssetStoreError, .protectedDataUnavailable)
        }
        XCTAssertTrue(unavailableOperations.files.isEmpty)

        let operations = PhoneAssetOperationsRecorder()
        let store = PhoneEncryptedAssetStore(
            directoryURL: URL(fileURLWithPath: "/protected"),
            operations: operations.operations,
            protectedDataAvailable: { true }
        )
        let staged = try store.makeAsset(for: Data("secret".utf8))
        let assetURL = try XCTUnwrap(staged.asset.fileURL)
        XCTAssertThrowsError(try store.openAsset(staged.asset, contentKey: Data(repeating: 0, count: 32))) { error in
            XCTAssertEqual(error as? PhoneEncryptedAssetStoreError, .authenticationFailed)
        }
        XCTAssertFalse(operations.exists(assetURL))
    }

    func testInvalidKeyLengthStillRemovesDownloadedTemporaryFile() throws {
        let operations = PhoneAssetOperationsRecorder()
        let store = PhoneEncryptedAssetStore(
            directoryURL: URL(fileURLWithPath: "/protected"),
            operations: operations.operations,
            protectedDataAvailable: { true }
        )
        let staged = try store.makeAsset(for: Data("secret".utf8))
        let assetURL = try XCTUnwrap(staged.asset.fileURL)

        XCTAssertThrowsError(try store.openAsset(staged.asset, contentKey: Data())) { error in
            XCTAssertEqual(error as? PhoneEncryptedAssetStoreError, .invalidAsset)
        }
        XCTAssertFalse(operations.exists(assetURL))
    }

    func testRevokedProtectedDataFailsBeforeReadAndRemovesDownloadedTemporaryFile() throws {
        let availability = PhoneProtectedDataAvailability(initialValue: true)
        let operations = PhoneAssetOperationsRecorder()
        let store = PhoneEncryptedAssetStore(
            directoryURL: URL(fileURLWithPath: "/protected"),
            operations: operations.operations,
            protectedDataAvailable: { availability.isAvailable }
        )
        let staged = try store.makeAsset(for: Data("secret".utf8))
        let assetURL = try XCTUnwrap(staged.asset.fileURL)

        availability.update(false)

        XCTAssertThrowsError(try store.openAsset(staged.asset, contentKey: staged.contentKey)) { error in
            XCTAssertEqual(error as? PhoneEncryptedAssetStoreError, .protectedDataUnavailable)
        }
        XCTAssertFalse(operations.events.contains(.read))
        XCTAssertFalse(operations.exists(assetURL))
    }
}

final class PhoneAssetOperationsRecorder: @unchecked Sendable {
    enum Event: Equatable {
        case createDirectory
        case createEmpty
        case protect
        case write
        case read
        case remove
    }

    private let lock = NSLock()
    private(set) var files: [URL: Data] = [:]
    private var protections: [URL: FileProtectionType] = [:]
    private(set) var events: [Event] = []

    lazy var operations = PhoneEncryptedAssetFileOperations(
        createDirectory: { [weak self] _ in self?.append(.createDirectory) },
        createEmpty: { [weak self] url in
            self?.append(.createEmpty)
            self?.lock.withLock { self?.files[url] = Data() }
        },
        write: { [weak self] data, url in
            self?.append(.write)
            self?.lock.withLock { self?.files[url] = data }
        },
        read: { [weak self] url in
            self?.append(.read)
            return try self?.lock.withLock {
                guard let data = self?.files[url] else { throw CocoaError(.fileReadNoSuchFile) }
                return data
            } ?? Data()
        },
        setCompleteProtection: { [weak self] url in
            self?.append(.protect)
            self?.lock.withLock { self?.protections[url] = .complete }
        },
        protection: { [weak self] url in self?.lock.withLock { self?.protections[url] } },
        removeIfExists: { [weak self] url in
            self?.append(.remove)
            self?.lock.withLock {
                self?.files.removeValue(forKey: url)
                self?.protections.removeValue(forKey: url)
            }
        }
    )

    func data(at url: URL) -> Data? {
        lock.withLock { files[url] }
    }

    func protection(at url: URL) -> FileProtectionType? {
        lock.withLock { protections[url] }
    }

    func exists(_ url: URL) -> Bool {
        lock.withLock { files[url] != nil }
    }

    private func append(_ event: Event) {
        lock.withLock { events.append(event) }
    }
}
