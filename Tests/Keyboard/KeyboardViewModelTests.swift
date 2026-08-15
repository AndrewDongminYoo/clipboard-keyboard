import ClipboardCore
import Foundation
import XCTest

@MainActor
final class KeyboardViewModelTests: XCTestCase {
    func testSearchUsesOnlyLoadedSnapshotAndSelectedBuiltInCategory() throws {
        let snapshot = try makeSnapshot()
        let model = KeyboardViewModel(load: { .available(snapshot) }, insertText: { _ in })
        model.load()
        model.selectedCategory = .prompts

        model.search("deploy")

        XCTAssertEqual(model.items.map(\.title), ["Deploy prompt"])
    }

    func testInsertUsesInjectedTextInsertionWithoutMutatingSnapshot() throws {
        let snapshot = try makeSnapshot()
        var inserted: [String] = []
        let model = KeyboardViewModel(load: { .available(snapshot) }, insertText: { inserted.append($0) })
        model.load()

        model.insert(itemID: snapshot.items[1].id)

        XCTAssertEqual(inserted, ["git status"])
        XCTAssertEqual(model.items.count, 2)
    }

    func testUnavailableSnapshotExposesContentFreeInstructionAndEmptyLibrary() {
        let model = KeyboardViewModel(load: { .unavailable(.corrupt) }, insertText: { _ in })

        model.load()

        XCTAssertEqual(model.items, [])
        XCTAssertEqual(model.instruction, "Open the app to sync")
    }

    func testRefreshRecommendedKeepsValidItemsAndShowsFreshnessInstruction() throws {
        let snapshot = try makeSnapshot()
        let model = KeyboardViewModel(load: { .refreshRecommended(snapshot) }, insertText: { _ in })

        model.load()

        XCTAssertEqual(model.items.count, 2)
        XCTAssertEqual(model.instruction, "Refresh recommended")
    }

    func testProtectedDataLossPurgesDecodedContentQueryAndPriorInsertionCapability() throws {
        let snapshot = try makeSnapshot()
        var inserted: [String] = []
        let model = KeyboardViewModel(load: { .available(snapshot) }, insertText: { inserted.append($0) })
        model.load()
        model.search("git")
        let priorID = snapshot.items[1].id

        model.protectedDataWillBecomeUnavailable()
        model.insert(itemID: priorID)

        XCTAssertEqual(model.items, [])
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.instruction, "Open the app to sync")
        XCTAssertEqual(inserted, [])
    }

    private func makeSnapshot() throws -> KeyboardSnapshot {
        try KeyboardSnapshot.make(
            items: [
                KeyboardSnapshotItem(id: uuid(1), title: "Deploy prompt", category: .prompts, canonicalInsertionString: "Deploy safely"),
                KeyboardSnapshotItem(id: uuid(2), title: "Git", category: .code, canonicalInsertionString: "git status"),
            ],
            generation: 1,
            createdAt: Date(),
            lastSuccessfulCloudRefresh: Date()
        )
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}
