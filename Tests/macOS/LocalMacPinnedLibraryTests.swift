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
        XCTAssertEqual(stateAfterDelete.pendingJournal.pending.count, 1)
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

    func testConcurrentPinsAreCommittedWithoutLostItemsOrJournalEntries() async throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = EncryptedMacPinnedStore(fileURL: fileURL, key: SymmetricKey(data: Data(repeating: 4, count: 32)))
        let library = LocalMacPinnedLibrary(store: store, deviceID: "concurrent-test")

        let firstPayload = payload(text: "concurrent-one", title: "One")
        let secondPayload = payload(text: "concurrent-two", title: "Two")
        async let first = library.pin(firstPayload)
        async let second = library.pin(secondPayload)
        _ = try await (first, second)

        let state = try await store.load()
        XCTAssertEqual(Set(state.primaryRevisions.map(\.payload.title)), ["One", "Two"])
        XCTAssertEqual(state.pendingJournal.pending.count, 2)
    }

    func testInterleavedReviseDeleteResetAndRemoteMutationsRemainSerialized() async throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = EncryptedMacPinnedStore(fileURL: fileURL, key: SymmetricKey(data: Data(repeating: 5, count: 32)))
        let library = LocalMacPinnedLibrary(store: store, deviceID: "serialized-test", now: { Date(timeIntervalSince1970: 200) })
        let revisedItem = try await library.pin(payload(text: "revise-before", title: "Revise"))
        let deletedItem = try await library.pin(payload(text: "delete-before", title: "Delete"))
        let remote = PinnedRevision(
            itemID: UUID(), revisionID: UUID(), libraryGeneration: 0, itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: 201), deviceID: "remote",
            payload: payload(text: "remote-value", title: "Remote")
        )

        let revisedPayload = payload(text: "revise-after", title: "Revised")
        async let revised = library.revise(itemID: revisedItem.itemID, payload: revisedPayload)
        async let deleted = library.delete(itemID: deletedItem.itemID)
        async let merged = library.applyRemote(.revision(remote))
        _ = try await (revised, deleted, merged)
        let reset = try await library.advanceResetGeneration()

        let state = try await store.load()
        XCTAssertEqual(reset.generation, 1)
        XCTAssertEqual(state.libraryGeneration, 1)
        XCTAssertTrue(state.seenMutationIDs.contains(remote.revisionID))
        XCTAssertEqual(state.pendingJournal.pending.last?.mutationID, reset.resetID)
    }

    func testEveryDurableLocalMutationNotifiesAfterJournalPersistence() async throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = EncryptedMacPinnedStore(fileURL: fileURL, key: SymmetricKey(data: Data(repeating: 6, count: 32)))
        let observations = MutationObservationBox()
        let library = LocalMacPinnedLibrary(
            store: store,
            deviceID: "notify-test",
            notifier: {
                if let state = try? await store.load() {
                    await observations.append(state.pendingJournal.pending.count)
                }
            }
        )

        let pinned = try await library.pin(payload(text: "one", title: "One"))
        _ = try await library.revise(itemID: pinned.itemID, payload: payload(text: "two", title: "Two"))
        _ = try await library.delete(itemID: pinned.itemID)
        _ = try await library.advanceResetGeneration()

        let counts = await observations.counts
        XCTAssertEqual(counts, [1, 2, 1, 1])
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

private actor MutationObservationBox {
    private(set) var counts: [Int] = []

    func append(_ count: Int) {
        counts.append(count)
    }
}
