import ClipboardCore
@testable import ClipboardKeyboardKeyboard
import Foundation
import XCTest

@MainActor
final class KeyboardInsertionIntegrationTests: XCTestCase {
    func testInsertionPreservesMultilineUnicodeEmojiAndExactCodeIndentation() throws {
        let values = [
            "first line\nsecond line",
            "한글 café 👩🏽‍💻",
            "func value() {\n    print(\"exact\")\n}\n",
        ]
        let items = values.enumerated().map {
            KeyboardSnapshotItem(id: uuid($0.offset + 1), title: "Item \($0.offset)", category: .code, canonicalInsertionString: $0.element)
        }
        let snapshot = try KeyboardSnapshot.make(items: items, generation: 1, createdAt: Date(), lastSuccessfulCloudRefresh: nil)
        var inserted: [String] = []
        let model = KeyboardViewModel(load: { .available(snapshot) }, insertText: { inserted.append($0) })
        model.load()

        for item in items {
            model.insert(itemID: item.id)
        }

        XCTAssertEqual(inserted, values)
    }

    func testLockedAndCorruptSnapshotsCannotWriteOrRetainContent() {
        for reason in [SnapshotUnavailableReason.locked, .corrupt] {
            let model = KeyboardViewModel(
                load: { .unavailable(reason) },
                insertText: { _ in XCTFail("Forbidden insertion from unavailable snapshot") }
            )
            model.load()
            model.insert(itemID: uuid(99))
            XCTAssertEqual(model.items, [])
            XCTAssertEqual(model.instruction, "Open the app to sync")
        }
    }

    func testActualAppGroupReaderRejectsLockedSnapshotBeforePayloadRead() {
        let container = URL(fileURLWithPath: "/app-group", isDirectory: true)
        let snapshotURL = container.appendingPathComponent("keyboard-snapshot-v1.json")
        let reader = KeyboardSnapshotReader(
            containerURL: { container },
            operations: KeyboardSnapshotReadOperations(
                exists: { $0 == snapshotURL },
                protection: { _ in FileProtectionType.none },
                read: { _ in
                    XCTFail("Forbidden locked snapshot payload read")
                    return Data()
                }
            )
        )

        XCTAssertEqual(reader.load(), .unavailable(.locked))
    }

    func testActualAppGroupReaderRejectsCorruptSnapshotWithoutRetainingContent() {
        let container = URL(fileURLWithPath: "/app-group", isDirectory: true)
        let snapshotURL = container.appendingPathComponent("keyboard-snapshot-v1.json")
        let corrupt = Data("corrupt snapshot payload".utf8)
        let reads = SnapshotReadCounter()
        let reader = KeyboardSnapshotReader(
            containerURL: { container },
            operations: KeyboardSnapshotReadOperations(
                exists: { $0 == snapshotURL },
                protection: { _ in .complete },
                read: { url in
                    XCTAssertEqual(url, snapshotURL)
                    reads.increment()
                    return corrupt
                }
            )
        )
        let model = KeyboardViewModel(
            load: { reader.load() },
            insertText: { _ in XCTFail("Forbidden insertion from corrupt App Group snapshot") }
        )

        model.load()
        model.insert(itemID: uuid(100))

        XCTAssertEqual(reads.value, 2)
        XCTAssertEqual(model.items, [])
        XCTAssertEqual(model.instruction, "Open the app to sync")
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}

private final class SnapshotReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
