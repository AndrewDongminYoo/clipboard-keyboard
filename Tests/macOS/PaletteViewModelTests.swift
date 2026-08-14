import ClipboardCore
@testable import ClipboardKeyboardMac
import XCTest

@MainActor
final class PaletteViewModelTests: XCTestCase {
    func testScopesBoundedPreviewSelectionAndReturnCopiesOriginalsThenCloses() async {
        let recent = makeEnvelope(text: "first line\nprivate second line", capturedAt: 200)
        let pinnedRevision = makeRevision(text: "pinned only", modifiedAt: 100)
        let source = PaletteDataSourceStub(recent: [recent], pinned: [pinnedRevision])
        let writer = PalettePasteboardWriterSpy()
        let model = PaletteViewModel(dataSource: source, pasteboardWriter: writer)

        await model.search(scope: .recent)
        XCTAssertEqual(model.items.map(\.id), [recent.id])
        XCTAssertEqual(model.items.first?.preview, "first line")
        XCTAssertFalse(model.items.first?.preview.contains("private second line") == true)

        await model.search(scope: .pinned)
        XCTAssertEqual(model.items.map(\.id), [pinnedRevision.itemID])

        await model.search(scope: .recent)
        await model.handle(.returnKey)
        XCTAssertEqual(writer.lastWrite?.map(\.kind), [.plainText, .rtf, .html])
        XCTAssertTrue(model.shouldClose)
    }

    func testArrowCopyAsPinExportAndDeleteAreExplicitActions() async {
        let first = makeEnvelope(text: "first", capturedAt: 200)
        let second = makeEnvelope(text: "second", capturedAt: 100)
        let source = PaletteDataSourceStub(recent: [first, second], pinned: [])
        let writer = PalettePasteboardWriterSpy()
        let exporter = PaletteExporterSpy()
        let model = PaletteViewModel(dataSource: source, pasteboardWriter: writer, exporter: exporter)
        await model.search(scope: .recent)

        await model.handle(.downArrow)
        XCTAssertEqual(model.selectedItemID, second.id)
        await model.handle(.upArrow)
        XCTAssertEqual(model.selectedItemID, first.id)

        await model.copySelected(as: .plainText)
        XCTAssertEqual(writer.lastWrite?.map(\.kind), [.plainText])
        XCTAssertFalse(model.shouldClose)

        await model.pinSelected()
        XCTAssertEqual(source.pinnedPayloads.map(\.canonicalInsertionString), ["first"])
        await model.exportSelected()
        XCTAssertEqual(exporter.exportedIDs, [first.id])
        await model.deleteSelected()
        XCTAssertEqual(source.deletedRecentIDs, [first.id])
    }

    private func makeEnvelope(text: String, capturedAt: TimeInterval) -> ClipEnvelope {
        let originals: [ClipRepresentation] = [
            .init(kind: .plainText, originalBytes: Data(text.utf8), keyedDigest: Data([1])),
            .init(kind: .rtf, originalBytes: Data("{\\rtf1 \(text)}".utf8), keyedDigest: Data([2])),
            .init(kind: .html, originalBytes: Data("<p>\(text)</p>".utf8), keyedDigest: Data([3])),
        ]
        return ClipEnvelope(
            id: UUID(),
            capturedAt: Date(timeIntervalSince1970: capturedAt),
            retentionClass: .localHistory,
            sourceConfidence: .inferredStableForeground,
            representations: originals,
            canonicalInsertionString: text,
            title: text,
            contentKind: .richText,
            category: nil,
            preview: text,
            valueCandidates: []
        )
    }

    private func makeRevision(text: String, modifiedAt: TimeInterval) -> PinnedRevision {
        PinnedRevision(
            itemID: UUID(),
            revisionID: UUID(),
            libraryGeneration: 0,
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: modifiedAt),
            deviceID: "test",
            payload: .init(
                representations: [.init(kind: .plainText, originalBytes: Data(text.utf8), keyedDigest: Data([1]))],
                canonicalInsertionString: text,
                title: text,
                contentKind: .plainText,
                category: nil
            )
        )
    }
}

@MainActor
private final class PaletteDataSourceStub: PaletteDataSource {
    let recent: [ClipEnvelope]
    let pinned: [PinnedRevision]
    private(set) var pinnedPayloads: [PinPayload] = []
    private(set) var deletedRecentIDs: [UUID] = []
    private(set) var deletedPinnedIDs: [UUID] = []

    init(recent: [ClipEnvelope], pinned: [PinnedRevision]) {
        self.recent = recent
        self.pinned = pinned
    }

    func recentItems(matching query: String) async throws -> [ClipEnvelope] {
        recent.filter { query.isEmpty || $0.canonicalInsertionString.localizedCaseInsensitiveContains(query) }
    }

    func pinnedItems(matching query: String) async throws -> [PinnedRevision] {
        pinned.filter { query.isEmpty || $0.payload.canonicalInsertionString.localizedCaseInsensitiveContains(query) }
    }

    func pin(_ payload: PinPayload) async throws {
        pinnedPayloads.append(payload)
    }

    func deleteRecent(id: UUID) async throws {
        deletedRecentIDs.append(id)
    }

    func deletePinned(id: UUID) async throws {
        deletedPinnedIDs.append(id)
    }
}

@MainActor
private final class PalettePasteboardWriterSpy: PalettePasteboardWriting {
    private(set) var lastWrite: [ClipRepresentation]?
    func write(_ representations: [ClipRepresentation]) throws {
        lastWrite = representations
    }
}

@MainActor
private final class PaletteExporterSpy: PaletteExporting {
    private(set) var exportedIDs: [UUID] = []
    func export(_ item: PaletteItem) async throws {
        exportedIDs.append(item.id)
    }
}
