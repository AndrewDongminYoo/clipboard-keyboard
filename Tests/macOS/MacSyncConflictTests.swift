import ClipboardCore
@testable import ClipboardKeyboardMac
import CryptoKit
import Foundation
import XCTest

final class MacSyncConflictTests: XCTestCase {
    func testConcurrentRemoteRevisionCreatesVisibleOpaqueConflictAndPreservesCategory() async throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let local = try await fixture.library.pin(payload("local", title: "Shared", category: .code))
        let remote = PinnedRevision(
            itemID: local.itemID,
            revisionID: UUID(),
            libraryGeneration: local.libraryGeneration,
            itemGeneration: local.itemGeneration,
            modifiedAt: local.modifiedAt.addingTimeInterval(1),
            deviceID: "remote-phone",
            payload: payload("remote", title: "Shared", category: .code)
        )

        let outcome = try await fixture.library.applyRemote(.revision(remote))

        guard case .conflict = outcome else { return XCTFail("Expected conflict") }
        let items = try await fixture.library.allItems()
        let state = try await fixture.store.load()
        let conflict = try XCTUnwrap(state.conflictCopies.first)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains { $0.itemID == conflict.revision.itemID })
        XCTAssertNotEqual(conflict.revision.itemID, local.itemID)
        XCTAssertEqual(conflict.revision.payload.category, .code)
        XCTAssertEqual(conflict.revision.syncState, .conflict)
        XCTAssertEqual(conflict.syncState, .conflict)
    }

    func testProjectedConflictCanBeRevisedIntoIndependentPrimaryAndDeleted() async throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let local = try await fixture.library.pin(payload("local", title: "Shared", category: .code))
        let remote = PinnedRevision(
            itemID: local.itemID,
            revisionID: UUID(),
            libraryGeneration: local.libraryGeneration,
            itemGeneration: local.itemGeneration,
            modifiedAt: local.modifiedAt.addingTimeInterval(1),
            deviceID: "remote-phone",
            payload: payload("remote", title: "Shared", category: .code)
        )
        _ = try await fixture.library.applyRemote(.revision(remote))
        let conflictState = try await fixture.store.load()
        let conflictID = try XCTUnwrap(conflictState.conflictCopies.first?.revision.itemID)

        let revised = try await fixture.library.revise(
            itemID: conflictID,
            payload: payload("resolved", title: "Resolved", category: .code)
        )

        XCTAssertEqual(revised.itemID, conflictID)
        XCTAssertNil(revised.syncState)
        let revisedState = try await fixture.store.load()
        XCTAssertTrue(revisedState.conflictCopies.isEmpty)

        _ = try await fixture.library.delete(itemID: conflictID)

        let finalState = try await fixture.store.load()
        XCTAssertEqual(finalState.primaryRevisions.map(\.itemID), [local.itemID])
        XCTAssertEqual(finalState.tombstones.map(\.itemID), [conflictID])
    }

    func testRemoteTombstonePurgesContentAndPendingRevisionsBeforeKeepingContentFreeDeletion() async throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let local = try await fixture.library.pin(payload("delete-sentinel", title: "Delete", category: .everyday))
        let tombstone = PinnedTombstone(
            itemID: local.itemID,
            tombstoneID: UUID(),
            libraryGeneration: local.libraryGeneration,
            itemGeneration: local.itemGeneration + 1,
            modifiedAt: local.modifiedAt.addingTimeInterval(1),
            deviceID: "remote-phone"
        )

        _ = try await fixture.library.applyRemote(.tombstone(tombstone))

        let state = try await fixture.store.load()
        let items = try await fixture.library.allItems()
        XCTAssertEqual(items, [])
        XCTAssertEqual(state.primaryRevisions, [])
        XCTAssertEqual(state.conflictCopies, [])
        XCTAssertEqual(state.pendingJournal.pending, [])
        XCTAssertEqual(state.tombstones, [tombstone])
        XCTAssertFalse(try JSONEncoder().encode(state).contains(Data("delete-sentinel".utf8)))
    }

    func testNewerResetPurgesOlderJournalAndStaleReconnectCannotRepublish() async throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let local = try await fixture.library.pin(payload("stale-sentinel", title: "Stale", category: nil))
        let reset = LibraryResetGeneration(
            resetID: UUID(),
            generation: local.libraryGeneration + 1,
            modifiedAt: local.modifiedAt.addingTimeInterval(2),
            deviceID: "remote-phone"
        )

        _ = try await fixture.library.applyRemote(.reset(reset))
        let staleOutcome = try await fixture.library.applyRemote(.revision(local))

        let state = try await fixture.store.load()
        let items = try await fixture.library.allItems()
        XCTAssertEqual(staleOutcome, .ignoredDuplicate)
        XCTAssertEqual(items, [])
        XCTAssertEqual(state.pendingJournal.pending, [])
        XCTAssertEqual(state.reset, reset)
        XCTAssertFalse(try JSONEncoder().encode(state).contains(Data("stale-sentinel".utf8)))
    }

    private func makeFixture() -> MacConflictFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = EncryptedMacPinnedStore(
            fileURL: root.appendingPathComponent("pinned-replica.encrypted"),
            key: SymmetricKey(data: Data(repeating: 6, count: 32))
        )
        return MacConflictFixture(
            root: root,
            store: store,
            library: LocalMacPinnedLibrary(
                store: store,
                deviceID: "mac-test",
                now: { Date(timeIntervalSince1970: 100) }
            )
        )
    }

    private func payload(_ text: String, title: String, category: ClipCategory?) -> PinPayload {
        PinPayload(
            representations: [.init(kind: .plainText, originalBytes: Data(text.utf8), keyedDigest: Data([1]))],
            canonicalInsertionString: text,
            title: title,
            contentKind: category == .code ? .code : .plainText,
            category: category
        )
    }
}

private struct MacConflictFixture {
    let root: URL
    let store: EncryptedMacPinnedStore
    let library: LocalMacPinnedLibrary

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
