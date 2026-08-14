import ClipboardCore
@testable import ClipboardKeyboardMac
import CryptoKit
import XCTest

final class LocalMacPinnedLibraryTests: XCTestCase {
    func testPinReviseDeleteAreImmutableRetentionExemptAndPersistPendingJournal() async throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = EncryptedMacPinnedStore(
            fileURL: fileURL,
            key: SymmetricKey(data: Data(repeating: 7, count: 32))
        )
        let library = LocalMacPinnedLibrary(store: store, deviceID: "mac-test", now: { Date(timeIntervalSince1970: 100) })
        let original = payload(text: "pinned-disk-sentinel", title: "Original")

        let pinned = try await library.pin(original)
        let revised = try await library.revise(
            itemID: pinned.itemID,
            payload: payload(text: "revised-disk-sentinel", title: "Revised")
        )

        XCTAssertEqual(pinned.itemGeneration, 1)
        XCTAssertEqual(revised.itemGeneration, 2)
        XCTAssertEqual(pinned.payload, original)
        let revisedItems = try await library.allItems()
        let searchResults = try await library.search("revised", limit: 10)
        let stateAfterRevision = try await store.load()
        XCTAssertEqual(revisedItems.map(\.payload.title), ["Revised"])
        XCTAssertEqual(searchResults.map(\.itemID), [pinned.itemID])
        XCTAssertEqual(stateAfterRevision.pendingJournal.pending.count, 2)
        XCTAssertFalse(try Data(contentsOf: fileURL).contains(Data("pinned-disk-sentinel".utf8)))
        XCTAssertFalse(try Data(contentsOf: fileURL).contains(Data("revised-disk-sentinel".utf8)))

        _ = try await library.delete(itemID: pinned.itemID)

        let itemsAfterDelete = try await library.allItems()
        let stateAfterDelete = try await store.load()
        XCTAssertEqual(itemsAfterDelete, [])
        XCTAssertEqual(stateAfterDelete.pendingJournal.pending.count, 3)
    }

    func testTamperedPinnedDocumentFailsClosedWithoutPlaintextFallback() async throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = EncryptedMacPinnedStore(fileURL: fileURL, key: SymmetricKey(data: Data(repeating: 9, count: 32)))
        try await store.save(PinnedReplicaState())
        var bytes = try Data(contentsOf: fileURL)
        bytes[bytes.index(before: bytes.endIndex)] ^= 0xFF
        try bytes.write(to: fileURL)

        do {
            _ = try await store.load()
            XCTFail("Expected authenticated document rejection")
        } catch {
            XCTAssertEqual(error as? PersistenceSecurityError, .authenticationFailed)
        }
    }

    private func payload(text: String, title: String) -> PinPayload {
        PinPayload(
            representations: [.init(kind: .plainText, originalBytes: Data(text.utf8), keyedDigest: Data([1]))],
            canonicalInsertionString: text,
            title: title,
            contentKind: .plainText,
            category: nil
        )
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pinned-replica.encrypted")
    }
}
