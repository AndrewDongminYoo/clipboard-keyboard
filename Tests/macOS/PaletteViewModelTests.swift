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
        await model.exportSelected(as: .rtf)
        XCTAssertEqual(exporter.exports.map(\.item.id), [first.id])
        XCTAssertEqual(exporter.exports.map(\.format), [.rtf])
        await model.deleteSelected()
        XCTAssertEqual(source.deletedRecentIDs, [first.id])
    }

    func testRepeatedPresentationReturnCopiesAndClosesEachTime() async {
        let item = makeEnvelope(text: "repeat", capturedAt: 1)
        let writer = PalettePasteboardWriterSpy()
        let model = PaletteViewModel(dataSource: PaletteDataSourceStub(recent: [item], pinned: []), pasteboardWriter: writer)
        await model.search(scope: .recent)

        model.prepareForPresentation()
        await model.handle(.returnKey)
        model.prepareForPresentation()
        await model.handle(.returnKey)

        XCTAssertEqual(writer.writeCount, 2)
        XCTAssertTrue(model.shouldClose)
    }

    func testImportAndShareAreWiredThroughPaletteCompositionWithExplicitFormat() async {
        let item = makeEnvelope(text: "share", capturedAt: 1)
        let importer = PaletteImporterSpy()
        let sharer = PaletteSharerSpy()
        let model = PaletteViewModel(
            dataSource: PaletteDataSourceStub(recent: [item], pinned: []),
            pasteboardWriter: PalettePasteboardWriterSpy(),
            importer: importer,
            sharer: sharer
        )
        await model.search(scope: .recent)
        await model.importAndPin()
        await model.search(scope: .recent)
        await model.shareSelected(as: .html)
        XCTAssertEqual(importer.callCount, 1)
        XCTAssertEqual(sharer.formats, [.html])
    }

    func testImportCancellationLeavesScopeAndStatusUnchanged() async {
        let importer = PaletteImporterSpy(outcome: .cancelled)
        let model = PaletteViewModel(
            dataSource: PaletteDataSourceStub(recent: [makeEnvelope(text: "recent", capturedAt: 1)], pinned: []),
            pasteboardWriter: PalettePasteboardWriterSpy(),
            importer: importer
        )
        await model.search(scope: .recent)

        await model.importAndPin()

        XCTAssertEqual(model.scope, .recent)
        XCTAssertNil(model.statusMessage)
    }

    func testUnavailableDefaultFileActionsFailClosedWithoutFalseSuccess() async {
        let model = PaletteViewModel(
            dataSource: PaletteDataSourceStub(recent: [makeEnvelope(text: "locked", capturedAt: 1)], pinned: []),
            pasteboardWriter: PalettePasteboardWriterSpy()
        )
        await model.search(scope: .recent)

        await model.importAndPin()
        XCTAssertEqual(model.statusMessage, "Import Failed")
        await model.exportSelected(as: .txt)
        XCTAssertEqual(model.statusMessage, "Export Failed")
        await model.shareSelected(as: .txt)
        XCTAssertEqual(model.statusMessage, "Share Failed")
    }

    func testProductionShareLifecycleCleansOwnedFilesAndScavengesOnlyExpectedStaleFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stale = root.appendingPathComponent("\(UUID().uuidString).txt")
        let arbitrary = root.appendingPathComponent("keep.txt")
        try Data("stale-share".utf8).write(to: stale)
        try Data("keep".utf8).write(to: arbitrary)
        let picker = MacSharePickerStub()
        var sharer: MacPaletteSharer? = MacPaletteSharer(
            controller: MacImportExportController(temporaryDirectory: root),
            picker: picker
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: arbitrary.path))

        for outcome in [MacSharePickerOutcome.cancelled, .shared, .failed] {
            var result: Result<PaletteShareOutcome, any Error>?
            try sharer?.share(makePaletteItem(text: "share"), as: .txt) { result = $0 }
            let temporaryURL = try XCTUnwrap(picker.lastURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
            picker.complete(outcome)
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
            if outcome == .failed {
                XCTAssertThrowsError(try result?.get())
            }
        }

        try sharer?.share(makePaletteItem(text: "teardown"), as: .txt) { _ in }
        let teardownURL = try XCTUnwrap(picker.lastURL)
        sharer = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: teardownURL.path))
    }

    func testProductionShareCleanupFailureSurfacesContentFreeViewModelError() async {
        enum CleanupFailure: Error { case failed }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let picker = MacSharePickerStub()
        let controller = MacImportExportController(temporaryDirectory: root, removeTemporaryItem: { _ in throw CleanupFailure.failed })
        let sharer = MacPaletteSharer(controller: controller, picker: picker)
        let model = PaletteViewModel(
            dataSource: PaletteDataSourceStub(recent: [makeEnvelope(text: "cleanup", capturedAt: 1)], pinned: []),
            pasteboardWriter: PalettePasteboardWriterSpy(),
            sharer: sharer
        )
        await model.search(scope: .recent)

        await model.shareSelected(as: .txt)
        picker.complete(.cancelled)

        XCTAssertEqual(model.statusMessage, "Share Failed")
    }

    func testProductionShareStartupCleanupFailureDisablesOnlyShareUntilRetrySucceeds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stale = root.appendingPathComponent("\(UUID().uuidString).txt")
        let unrelated = root.appendingPathComponent("keep.txt")
        try Data("stale".utf8).write(to: stale)
        try Data("keep".utf8).write(to: unrelated)
        let remover = TemporaryRemovalStub(failuresRemaining: 2)
        let picker = MacSharePickerStub()
        let sharer = MacPaletteSharer(
            controller: MacImportExportController(temporaryDirectory: root, removeTemporaryItem: remover.remove),
            picker: picker
        )
        let recent = makeEnvelope(text: "healthy-history", capturedAt: 1)
        let pinned = makeRevision(text: "healthy-pinned", modifiedAt: 1)
        let model = PaletteViewModel(
            dataSource: PaletteDataSourceStub(recent: [recent], pinned: [pinned]),
            pasteboardWriter: PalettePasteboardWriterSpy(),
            sharer: sharer
        )

        await model.search(scope: .recent)
        XCTAssertEqual(model.items.map(\.id), [recent.id])
        await model.shareSelected(as: .txt)
        XCTAssertEqual(model.statusMessage, "Share Failed")
        XCTAssertTrue(picker.presentedURLs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        await model.search(scope: .pinned)
        XCTAssertEqual(model.items.map(\.id), [pinned.itemID])

        remover.failuresRemaining = 0
        await model.shareSelected(as: .txt)
        XCTAssertEqual(picker.presentedURLs.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        picker.completeLatest(.shared)
        XCTAssertNil(model.statusMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testProductionShareRejectsOverlapAndIgnoresRetainedStaleCallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let picker = MacSharePickerStub()
        let sharer = MacPaletteSharer(controller: MacImportExportController(temporaryDirectory: root), picker: picker)
        var firstResult: Result<PaletteShareOutcome, any Error>?
        var secondResult: Result<PaletteShareOutcome, any Error>?

        try sharer.share(makePaletteItem(text: "first"), as: .txt) { firstResult = $0 }
        let firstURL = try XCTUnwrap(picker.presentedURLs.first)
        XCTAssertThrowsError(try sharer.share(makePaletteItem(text: "rejected"), as: .txt) { secondResult = $0 })
        XCTAssertEqual(picker.presentedURLs, [firstURL])
        XCTAssertNil(firstResult)
        XCTAssertNil(secondResult)

        picker.complete(at: 0, with: .shared)
        XCTAssertNoThrow(try firstResult?.get())
        try sharer.share(makePaletteItem(text: "second"), as: .txt) { secondResult = $0 }
        let secondURL = try XCTUnwrap(picker.presentedURLs.last)
        XCTAssertNotEqual(secondURL, firstURL)

        picker.complete(at: 0, with: .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertNil(secondResult)
        picker.complete(at: 1, with: .shared)
        XCTAssertNoThrow(try secondResult?.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testProductionShareRuntimeCleanupFailureRetainsURLForNextAttempt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let unrelated = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        let remover = TemporaryRemovalStub()
        let picker = MacSharePickerStub()
        let sharer = MacPaletteSharer(
            controller: MacImportExportController(temporaryDirectory: root, removeTemporaryItem: remover.remove),
            picker: picker
        )
        var firstResult: Result<PaletteShareOutcome, any Error>?

        try sharer.share(makePaletteItem(text: "first"), as: .txt) { firstResult = $0 }
        let firstURL = try XCTUnwrap(picker.lastURL)
        remover.failuresRemaining = 1
        picker.completeLatest(.cancelled)
        XCTAssertThrowsError(try firstResult?.get())
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))

        try sharer.share(makePaletteItem(text: "second"), as: .txt) { _ in }
        XCTAssertEqual(remover.attemptedURLs.filter { $0 == firstURL }.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertEqual(picker.presentedURLs.count, 2)
        XCTAssertTrue(try FileManager.default.fileExists(atPath: XCTUnwrap(picker.lastURL).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
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

    private func makePaletteItem(text: String) -> PaletteItem {
        .init(
            id: UUID(), capturedAt: Date(), preview: text, contentKind: .plainText, sourceConfidence: .unknown,
            representations: [.init(kind: .plainText, originalBytes: Data(text.utf8), keyedDigest: Data([1]))],
            canonicalInsertionString: text, title: "Share", category: nil, isPinned: false
        )
    }
}

@MainActor
private final class MacSharePickerStub: MacSharePickerPresenting {
    private(set) var lastURL: URL?
    private(set) var presentedURLs: [URL] = []
    private var completions: [(MacSharePickerOutcome) -> Void] = []
    func present(url: URL, completion: @escaping @MainActor (MacSharePickerOutcome) -> Void) {
        lastURL = url
        presentedURLs.append(url)
        completions.append(completion)
    }

    func complete(_ outcome: MacSharePickerOutcome) {
        completeLatest(outcome)
    }

    func completeLatest(_ outcome: MacSharePickerOutcome) {
        completions.last?(outcome)
    }

    func complete(at index: Int, with outcome: MacSharePickerOutcome) {
        completions[index](outcome)
    }
}

private enum TemporaryRemovalFailure: Error {
    case failed
}

private final class TemporaryRemovalStub: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailuresRemaining: Int
    private var storedAttemptedURLs: [URL] = []

    init(failuresRemaining: Int = 0) {
        storedFailuresRemaining = failuresRemaining
    }

    var failuresRemaining: Int {
        get { lock.withLock { storedFailuresRemaining } }
        set { lock.withLock { storedFailuresRemaining = newValue } }
    }

    var attemptedURLs: [URL] {
        lock.withLock { storedAttemptedURLs }
    }

    func remove(_ url: URL) throws {
        let shouldFail = lock.withLock {
            storedAttemptedURLs.append(url)
            if storedFailuresRemaining > 0 {
                storedFailuresRemaining -= 1
                return true
            }
            return false
        }
        if shouldFail {
            throw TemporaryRemovalFailure.failed
        }
        try FileManager.default.removeItem(at: url)
    }
}

@MainActor private final class PaletteImporterSpy: PaletteImporting {
    private(set) var callCount = 0
    let outcome: PaletteImportOutcome
    init(outcome: PaletteImportOutcome = .imported) {
        self.outcome = outcome
    }

    func importAndPin() async throws -> PaletteImportOutcome {
        callCount += 1
        return outcome
    }
}

@MainActor private final class PaletteSharerSpy: PaletteSharing {
    private(set) var formats: [MacClipDocumentFormat] = []
    func share(
        _: PaletteItem,
        as format: MacClipDocumentFormat,
        completion: @escaping @MainActor (Result<PaletteShareOutcome, any Error>) -> Void
    ) throws {
        formats.append(format)
        completion(.success(.shared))
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
    private(set) var writeCount = 0
    func write(_ representations: [ClipRepresentation]) throws {
        writeCount += 1
        lastWrite = representations
    }
}

@MainActor
private final class PaletteExporterSpy: PaletteExporting {
    private(set) var exports: [(item: PaletteItem, format: MacClipDocumentFormat)] = []
    func export(_ item: PaletteItem, as format: MacClipDocumentFormat) async throws {
        exports.append((item, format))
    }
}
