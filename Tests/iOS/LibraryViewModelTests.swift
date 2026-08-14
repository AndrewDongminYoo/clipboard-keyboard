import ClipboardCore
@testable import ClipboardKeyboardiOS
import XCTest

@MainActor
final class LibraryViewModelTests: XCTestCase {
    func testLoadSearchAndCategoryFiltersIncludeNilAsUncategorized() async {
        let prompt = revision(item: 1, text: "Release prompt", title: "Prompt", category: .prompts)
        let code = revision(item: 2, text: "deploy command", title: "Code", category: .code)
        let uncategorized = revision(item: 3, text: "deploy note", title: "Loose", category: nil)
        let library = LibraryFake(items: [prompt, code, uncategorized])
        let model = makeModel(library: library)

        await model.load()
        model.setCategoryFilter(.uncategorized)
        XCTAssertEqual(model.items.map(\.itemID), [uncategorized.itemID])

        model.setCategoryFilter(.all)
        await model.updateQuery("deploy")
        XCTAssertEqual(Set(model.items.map(\.itemID)), [code.itemID, uncategorized.itemID])
    }

    func testEditingCreatesNewRevisionAndRefreshesProjection() async {
        let original = revision(item: 1, text: "old body", title: "Old", category: .everyday)
        let library = LibraryFake(items: [original])
        let model = makeModel(library: library)
        await model.load()

        model.beginEditing(original)
        await model.saveEdit(title: "New", text: "new body", category: .code)

        let revised = await library.lastRevised
        XCTAssertEqual(revised?.itemID, original.itemID)
        XCTAssertEqual(revised?.payload.title, "New")
        XCTAssertEqual(revised?.payload.canonicalInsertionString, "new body")
        XCTAssertEqual(revised?.payload.category, .code)
        XCTAssertNotEqual(
            revised?.payload.representations.first?.keyedDigest,
            original.payload.representations.first?.keyedDigest
        )
        XCTAssertNil(model.editingItem)
        XCTAssertEqual(model.items.first?.itemGeneration, 2)
    }

    func testDeletionRequiresConfirmationBeforeRemovingItem() async {
        let original = revision(item: 1, text: "delete me", title: "Delete", category: nil)
        let library = LibraryFake(items: [original])
        let model = makeModel(library: library)
        await model.load()

        model.requestDeletion(original)
        XCTAssertEqual(model.pendingDeletion?.itemID, original.itemID)
        let countBeforeConfirmation = await library.currentDeleteCount()
        XCTAssertEqual(countBeforeConfirmation, 0)

        await model.confirmDeletion()
        let countAfterConfirmation = await library.currentDeleteCount()
        XCTAssertEqual(countAfterConfirmation, 1)
        XCTAssertNil(model.pendingDeletion)
        XCTAssertEqual(model.items, [])
    }

    func testProtectedDataPurgeClearsEveryContentBearingViewState() async {
        let original = revision(item: 1, text: "sensitive", title: "Private", category: nil)
        let library = LibraryFake(items: [original])
        let model = makeModel(library: library)
        await model.load()
        await model.updateQuery("sensitive")
        model.beginEditing(original)
        model.requestDeletion(original)

        model.protectedDataWillBecomeUnavailable()

        XCTAssertEqual(model.items, [])
        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.editingItem)
        XCTAssertNil(model.pendingDeletion)
        XCTAssertEqual(model.storageStatus, .locked)
    }

    func testSameViewModelStartsLockedAndAcceptsOnlyCurrentUnlockBackend() async {
        let original = revision(item: 1, text: "restored", title: "Restored", category: nil)
        let firstBackend = LibraryFake(items: [original])
        let secondBackend = LibraryFake(items: [original])
        let gate = PhonePinnedLibraryGate()
        let model = LibraryViewModel(
            library: gate,
            textTransformer: TextTransformer { Data($0.reversed()) }
        )
        model.protectedDataWillBecomeUnavailable()

        await model.load()
        let initialFirstBackendCallCount = await firstBackend.currentAllItemsCount()
        XCTAssertEqual(initialFirstBackendCallCount, 0)
        XCTAssertEqual(model.storageStatus, .locked)

        let staleEpoch = gate.beginUnlock()
        gate.lock()
        XCTAssertFalse(gate.install(firstBackend, for: staleEpoch))
        XCTAssertFalse(staleEpoch.lease.isActive)
        let currentEpoch = gate.beginUnlock()
        XCTAssertTrue(gate.install(secondBackend, for: currentEpoch))

        await model.load()
        XCTAssertEqual(model.items, [original])
        let nextEpoch = gate.beginUnlock()
        XCTAssertFalse(currentEpoch.lease.isActive)
        XCTAssertFalse(gate.install(firstBackend, for: currentEpoch))
        XCTAssertTrue(gate.install(firstBackend, for: nextEpoch))
        await model.load()
        let finalFirstBackendCallCount = await firstBackend.currentAllItemsCount()
        let finalSecondBackendCallCount = await secondBackend.currentAllItemsCount()
        XCTAssertEqual(finalFirstBackendCallCount, 1)
        XCTAssertEqual(finalSecondBackendCallCount, 1)
    }

    func testStaleUnlockFailureCannotPurgeInstalledNewBackend() async throws {
        let current = revision(item: 1, text: "current unlock", title: "Current", category: nil)
        let currentBackend = LibraryFake(items: [current])
        let gate = PhonePinnedLibraryGate()
        let model = LibraryViewModel(
            library: gate,
            textTransformer: TextTransformer { Data($0.reversed()) }
        )
        let staleUnlock = gate.beginUnlock()
        gate.lock()
        let currentUnlock = gate.beginUnlock()
        XCTAssertTrue(gate.install(currentBackend, for: currentUnlock))
        await model.load()
        XCTAssertEqual(model.items, [current])

        let shouldPurge = gate.failUnlock(staleUnlock)
        if shouldPurge {
            model.protectedDataWillBecomeUnavailable()
        }

        XCTAssertFalse(shouldPurge)
        XCTAssertFalse(staleUnlock.lease.isActive)
        XCTAssertTrue(currentUnlock.lease.isActive)
        let installedItems = try await gate.allItems()
        XCTAssertEqual(installedItems, [current])
        XCTAssertEqual(model.items, [current])
        XCTAssertEqual(model.storageStatus, .available)
    }

    func testProtectedDataNotificationSynchronouslyPurgesContentAndRevokesInstalledLease() async {
        let original = revision(item: 1, text: "notification secret", title: "Private", category: nil)
        let backend = LibraryFake(items: [original])
        let gate = PhonePinnedLibraryGate()
        let model = LibraryViewModel(
            library: gate,
            textTransformer: TextTransformer { Data($0.reversed()) }
        )
        let unlock = gate.beginUnlock()
        XCTAssertTrue(gate.install(backend, for: unlock))
        await model.load()
        XCTAssertEqual(model.items, [original])
        let center = NotificationCenter()
        let observer = observePhoneProtectedDataWillBecomeUnavailable(notificationCenter: center) {
            gate.lock()
            model.protectedDataWillBecomeUnavailable()
        }

        center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)

        XCTAssertEqual(model.items, [])
        XCTAssertEqual(model.storageStatus, .locked)
        XCTAssertFalse(unlock.lease.isActive)
        withExtendedLifetime(observer) {}
    }

    func testInFlightLoadCannotRepopulateAfterLock() async {
        let original = revision(item: 1, text: "stale load", title: "Stale", category: nil)
        let barrier = AsyncTestBarrier()
        let library = BarrierLibraryFake(items: [original], allItemsBarrier: barrier)
        let model = makeBarrierModel(library: library)

        let load = Task { await model.load() }
        await barrier.waitUntilEntered()
        model.protectedDataWillBecomeUnavailable()
        await barrier.release()
        await load.value

        XCTAssertEqual(model.items, [])
        XCTAssertEqual(model.storageStatus, .locked)
    }

    func testOlderSearchCannotOverwriteNewerQuery() async {
        let old = revision(item: 1, text: "old result", title: "Old", category: nil)
        let new = revision(item: 2, text: "new result", title: "New", category: nil)
        let barrier = AsyncTestBarrier()
        let library = BarrierLibraryFake(items: [old, new], oldSearchBarrier: barrier)
        let model = makeBarrierModel(library: library)

        let oldSearch = Task { await model.updateQuery("old") }
        await barrier.waitUntilEntered()
        await model.updateQuery("new")
        await barrier.release()
        await oldSearch.value

        XCTAssertEqual(model.query, "new")
        XCTAssertEqual(model.items.map(\.itemID), [new.itemID])
    }

    func testInFlightEditCannotReturnContentAfterLock() async {
        let original = revision(item: 1, text: "old secret", title: "Old", category: nil)
        let barrier = AsyncTestBarrier()
        let library = BarrierLibraryFake(items: [original], reviseBarrier: barrier)
        let model = makeBarrierModel(library: library)
        model.beginEditing(original)

        let edit = Task { await model.saveEdit(title: "New", text: "new secret", category: nil) }
        await barrier.waitUntilEntered()
        model.protectedDataWillBecomeUnavailable()
        await barrier.release()
        await edit.value

        XCTAssertEqual(model.items, [])
        XCTAssertNil(model.editingItem)
        XCTAssertEqual(model.storageStatus, .locked)
    }

    private func revision(item: UInt8, text: String, title: String, category: ClipCategory?) -> PinnedRevision {
        PinnedRevision(
            itemID: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02X", item))")!,
            revisionID: UUID(),
            libraryGeneration: 0,
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(item)),
            deviceID: "view-model-test",
            payload: PinPayload(
                representations: [.init(kind: .plainText, originalBytes: Data(text.utf8), keyedDigest: Data([item]))],
                canonicalInsertionString: text,
                title: title,
                contentKind: category == .code ? .code : .plainText,
                category: category
            )
        )
    }

    private func makeModel(library: LibraryFake) -> LibraryViewModel {
        LibraryViewModel(
            library: library,
            textTransformer: TextTransformer { Data($0.reversed()) }
        )
    }

    private func makeBarrierModel(library: BarrierLibraryFake) -> LibraryViewModel {
        LibraryViewModel(
            library: library,
            textTransformer: TextTransformer { Data($0.reversed()) }
        )
    }
}

private actor AsyncTestBarrier {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor BarrierLibraryFake: PinnedLibrary {
    private var items: [PinnedRevision]
    private let allItemsBarrier: AsyncTestBarrier?
    private let oldSearchBarrier: AsyncTestBarrier?
    private let reviseBarrier: AsyncTestBarrier?

    init(
        items: [PinnedRevision],
        allItemsBarrier: AsyncTestBarrier? = nil,
        oldSearchBarrier: AsyncTestBarrier? = nil,
        reviseBarrier: AsyncTestBarrier? = nil
    ) {
        self.items = items
        self.allItemsBarrier = allItemsBarrier
        self.oldSearchBarrier = oldSearchBarrier
        self.reviseBarrier = reviseBarrier
    }

    func allItems() async -> [PinnedRevision] {
        if let allItemsBarrier {
            await allItemsBarrier.suspend()
        }
        return items
    }

    func search(_ query: String, limit: Int) async -> [PinnedRevision] {
        if query == "old", let oldSearchBarrier {
            await oldSearchBarrier.suspend()
        }
        return items.filter {
            $0.payload.canonicalInsertionString.contains(query)
        }.prefix(limit).map { $0 }
    }

    func pin(_: PinPayload) throws -> PinnedRevision {
        throw LibraryFakeError.unsupported
    }

    func revise(itemID: UUID, payload: PinPayload) async throws -> PinnedRevision {
        if let reviseBarrier {
            await reviseBarrier.suspend()
        }
        guard let current = items.first(where: { $0.itemID == itemID }) else {
            throw LibraryFakeError.unsupported
        }
        let revised = PinnedRevision(
            itemID: itemID,
            revisionID: UUID(),
            libraryGeneration: current.libraryGeneration,
            itemGeneration: current.itemGeneration + 1,
            modifiedAt: current.modifiedAt.addingTimeInterval(1),
            deviceID: current.deviceID,
            payload: payload
        )
        items = [revised]
        return revised
    }

    func delete(itemID _: UUID) throws -> PinnedTombstone {
        throw LibraryFakeError.unsupported
    }

    func applyRemote(_: PinnedMutation) throws -> MergeOutcome {
        throw LibraryFakeError.unsupported
    }

    func advanceResetGeneration() throws -> LibraryResetGeneration {
        throw LibraryFakeError.unsupported
    }
}

private actor LibraryFake: PinnedLibrary {
    private var storedItems: [PinnedRevision]
    private(set) var lastRevised: PinnedRevision?
    private(set) var deleteCount = 0
    private(set) var allItemsCount = 0

    init(items: [PinnedRevision]) {
        storedItems = items
    }

    func allItems() -> [PinnedRevision] {
        allItemsCount += 1
        return storedItems
    }

    func search(_ query: String, limit: Int) -> [PinnedRevision] {
        let normalized = query.lowercased()
        return storedItems.filter {
            $0.payload.title.lowercased().contains(normalized)
                || $0.payload.canonicalInsertionString.lowercased().contains(normalized)
        }.prefix(max(0, limit)).map { $0 }
    }

    func pin(_: PinPayload) throws -> PinnedRevision {
        throw LibraryFakeError.unsupported
    }

    func revise(itemID: UUID, payload: PinPayload) throws -> PinnedRevision {
        guard let current = storedItems.first(where: { $0.itemID == itemID }) else {
            throw LibraryFakeError.unsupported
        }
        let revised = PinnedRevision(
            itemID: itemID,
            revisionID: UUID(),
            libraryGeneration: current.libraryGeneration,
            itemGeneration: current.itemGeneration + 1,
            modifiedAt: current.modifiedAt.addingTimeInterval(1),
            deviceID: current.deviceID,
            payload: payload
        )
        storedItems.removeAll { $0.itemID == itemID }
        storedItems.append(revised)
        lastRevised = revised
        return revised
    }

    func delete(itemID: UUID) throws -> PinnedTombstone {
        guard let current = storedItems.first(where: { $0.itemID == itemID }) else {
            throw LibraryFakeError.unsupported
        }
        storedItems.removeAll { $0.itemID == itemID }
        deleteCount += 1
        return PinnedTombstone(
            itemID: itemID,
            tombstoneID: UUID(),
            libraryGeneration: current.libraryGeneration,
            itemGeneration: current.itemGeneration + 1,
            modifiedAt: current.modifiedAt.addingTimeInterval(1),
            deviceID: current.deviceID
        )
    }

    func applyRemote(_: PinnedMutation) throws -> MergeOutcome {
        throw LibraryFakeError.unsupported
    }

    func advanceResetGeneration() throws -> LibraryResetGeneration {
        throw LibraryFakeError.unsupported
    }

    func currentDeleteCount() -> Int {
        deleteCount
    }

    func currentAllItemsCount() -> Int {
        allItemsCount
    }
}

private enum LibraryFakeError: Error {
    case unsupported
}
