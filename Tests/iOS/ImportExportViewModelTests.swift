import ClipboardCore
@testable import ClipboardKeyboardiOS
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ImportExportViewModelTests: XCTestCase {
    func testPhoneGateDigestsTheExactImportedRepresentationBytes() throws {
        let gate = PhonePinnedLibraryGate()
        let unlock = gate.beginUnlock()
        XCTAssertTrue(gate.install(ImportLibraryFake(), textTransformer: TextTransformer { Data($0.reversed()) }, for: unlock))
        let bytes = Data("<p>exact</p>".utf8)
        let raw = RawTextRepresentation(kind: .html, data: bytes, textProjection: "exact")

        let representations = try gate.representations(for: raw)

        XCTAssertEqual(representations, [
            .init(kind: .html, originalBytes: bytes, keyedDigest: Data(bytes.reversed())),
        ])
    }

    func testPhoneGateResolvesRawRepresentationBeforeDigesting() throws {
        let gate = PhonePinnedLibraryGate()
        let unlock = gate.beginUnlock()
        XCTAssertTrue(gate.install(ImportLibraryFake(), textTransformer: TextTransformer { Data($0.reversed()) }, for: unlock))
        let forgedProjection = RawTextRepresentation(kind: .plainText, data: Data("exact".utf8), textProjection: "forged")

        XCTAssertThrowsError(try gate.representations(for: forgedProjection)) { error in
            XCTAssertEqual(error as? RepresentationResolverError, .projectionDoesNotMatchBytes(.plainText))
        }
    }

    func testImportPreviewsBeforeDistinctPinAndPinPreservesBytesKindAndCanonicalText() async throws {
        let library = ImportLibraryFake()
        let model = makeModel(library: library)
        let original = Data("# 제목\r\n\r\n  body".utf8)

        try model.acceptImportedData(original, declaredType: .markdown)

        XCTAssertEqual(model.importPreview?.bytes, original)
        XCTAssertEqual(model.importPreview?.canonicalInsertionString, "# 제목\r\n\r\n  body")
        XCTAssertEqual(library.payloads, [])

        try await model.pinImportedDocument(title: "Imported")

        let payload = try XCTUnwrap(library.payloads.first)
        XCTAssertEqual(payload.representations.count, 1)
        XCTAssertEqual(payload.representations[0].kind, .markdown)
        XCTAssertEqual(payload.representations[0].originalBytes, original)
        XCTAssertEqual(payload.representations[0].keyedDigest, Data(original.reversed()))
        XCTAssertEqual(payload.canonicalInsertionString, "# 제목\r\n\r\n  body")
        XCTAssertNil(model.importPreview)
    }

    func testURLImportResolvesTypeAndReadsOnlyInsideBalancedSecurityScope() throws {
        let access = ImportAccessRecorder()
        let url = URL(fileURLWithPath: "/virtual/scoped.md")
        let markdown = try XCTUnwrap(UTType("net.daringfireball.markdown"))
        let model = ImportExportViewModel(
            library: ImportLibraryFake(),
            representations: { _ in [] },
            startAccessingImportedURL: { importedURL in access.start(importedURL) },
            stopAccessingImportedURL: { importedURL in access.stop(importedURL) },
            importedContentType: { importedURL in try access.contentType(of: importedURL, returning: markdown) },
            readImportedData: { importedURL in try access.read(importedURL, returning: Data("# scoped".utf8)) }
        )

        try model.importFile(at: url)

        XCTAssertEqual(access.events, ["start", "type", "read", "stop"])
        XCTAssertFalse(access.isActive)
        XCTAssertEqual(model.importPreview?.format, .markdown)
        XCTAssertEqual(model.importPreview?.bytes, Data("# scoped".utf8))
    }

    func testURLImportTypeMismatchFailsClosedBeforeReadAndNeverPins() async throws {
        let access = ImportAccessRecorder()
        let library = ImportLibraryFake()
        let url = URL(fileURLWithPath: "/virtual/mismatch.txt")
        let markdown = try XCTUnwrap(UTType("net.daringfireball.markdown"))
        let model = ImportExportViewModel(
            library: library,
            representations: { _ in [] },
            startAccessingImportedURL: { importedURL in access.start(importedURL) },
            stopAccessingImportedURL: { importedURL in access.stop(importedURL) },
            importedContentType: { importedURL in try access.contentType(of: importedURL, returning: markdown) },
            readImportedData: { importedURL in try access.read(importedURL, returning: Data("must not read".utf8)) }
        )

        XCTAssertThrowsError(try model.importFile(at: url))
        try? await model.pinImportedDocument(title: "Must not pin")

        XCTAssertEqual(access.events, ["start", "type", "stop"])
        XCTAssertFalse(access.isActive)
        XCTAssertNil(model.importPreview)
        XCTAssertEqual(model.importErrorMessage, "Unable to preview this file.")
        XCTAssertEqual(library.payloads, [])
    }

    func testURLImportMissingTypeFailsClosedInsideBalancedScope() throws {
        let access = ImportAccessRecorder()
        let url = URL(fileURLWithPath: "/virtual/missing.txt")
        let model = ImportExportViewModel(
            library: ImportLibraryFake(),
            representations: { _ in [] },
            startAccessingImportedURL: { importedURL in access.start(importedURL) },
            stopAccessingImportedURL: { importedURL in access.stop(importedURL) },
            importedContentType: { importedURL in try access.missingContentType(of: importedURL) },
            readImportedData: { importedURL in try access.read(importedURL, returning: Data("must not read".utf8)) }
        )

        XCTAssertThrowsError(try model.importFile(at: url))

        XCTAssertEqual(access.events, ["start", "type", "stop"])
        XCTAssertFalse(access.isActive)
        XCTAssertNil(model.importPreview)
        XCTAssertEqual(model.importErrorMessage, "Unable to preview this file.")
    }

    func testImportCancellationAndLockPurgePreviewWithoutPinning() throws {
        let cancelledLibrary = ImportLibraryFake()
        let cancelled = makeModel(library: cancelledLibrary)
        try cancelled.acceptImportedData(Data("cancel".utf8), declaredType: .plainText)
        cancelled.cancelImport()
        XCTAssertNil(cancelled.importPreview)
        XCTAssertEqual(cancelledLibrary.payloads, [])

        let lockedLibrary = ImportLibraryFake()
        let locked = makeModel(library: lockedLibrary)
        try locked.acceptImportedData(Data("lock secret".utf8), declaredType: .plainText)
        locked.protectedDataWillBecomeUnavailable()
        XCTAssertNil(locked.importPreview)
        XCTAssertNil(locked.errorMessage)
        XCTAssertEqual(lockedLibrary.payloads, [])
    }

    func testCancelDuringRepresentationGenerationPreventsOldDocumentPin() async throws {
        let barrier = ImportRepresentationBarrier()
        let library = ImportLibraryFake()
        let model = makeModel(library: library, representations: { raw in try await barrier.render(raw) })
        try model.acceptImportedData(Data("old".utf8), declaredType: .plainText)

        let pin = Task { try? await model.pinImportedDocument(title: "Old") }
        await barrier.waitUntilEntered()
        model.cancelImport()
        await barrier.release()
        await pin.value

        XCTAssertNil(model.importPreview)
        XCTAssertEqual(library.payloads, [])
    }

    func testReplacementDuringRepresentationGenerationPreventsOldDocumentPin() async throws {
        let barrier = ImportRepresentationBarrier()
        let library = ImportLibraryFake()
        let model = makeModel(library: library, representations: { raw in try await barrier.render(raw) })
        try model.acceptImportedData(Data("old".utf8), declaredType: .plainText)

        let pin = Task { try? await model.pinImportedDocument(title: "Old") }
        await barrier.waitUntilEntered()
        try model.acceptImportedData(Data("new".utf8), declaredType: .plainText)
        await barrier.release()
        await pin.value

        XCTAssertEqual(model.importPreview?.bytes, Data("new".utf8))
        XCTAssertEqual(library.payloads, [])
    }

    func testLockDuringRepresentationGenerationPreventsOldDocumentPin() async throws {
        let barrier = ImportRepresentationBarrier()
        let library = ImportLibraryFake()
        let model = makeModel(library: library, representations: { raw in try await barrier.render(raw) })
        try model.acceptImportedData(Data("old".utf8), declaredType: .plainText)

        let pin = Task { try? await model.pinImportedDocument(title: "Old") }
        await barrier.waitUntilEntered()
        model.protectedDataWillBecomeUnavailable()
        await barrier.release()
        await pin.value

        XCTAssertNil(model.importPreview)
        XCTAssertEqual(library.payloads, [])
    }

    func testOneItemFileDocumentAndSharePreserveOnlySelectedRepresentation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(library: ImportLibraryFake(), temporaryDirectory: root)
        let plain = Data("plain".utf8)
        let html = Data("<p>rich</p>".utf8)
        let item = revision(representations: [
            .init(kind: .plainText, originalBytes: plain, keyedDigest: Data([1])),
            .init(kind: .html, originalBytes: html, keyedDigest: Data([2])),
        ], canonical: "plain")

        let document = try model.document(for: item, as: .html)
        let fileDocument = ClipFileDocument(document: document)
        let shareURL = try model.prepareTemporaryShare(of: item, as: .html)

        XCTAssertEqual(fileDocument.document.bytes, html)
        XCTAssertEqual(Set(ClipFileDocument.writableContentTypes.map(\.identifier)), Set(ClipDocumentFormat.allCases.map(\.contentType.identifier)))
        XCTAssertEqual(try Data(contentsOf: shareURL), html)
        XCTAssertEqual(shareURL.pathExtension, "html")
        XCTAssertNotNil(UUID(uuidString: shareURL.deletingPathExtension().lastPathComponent))
        XCTAssertEqual(shareURL.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
    }

    func testTemporaryShareCleanupCoversSuccessCancelFailureAndViewTeardown() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = revision(representations: [
            .init(kind: .plainText, originalBytes: Data("one".utf8), keyedDigest: Data([1])),
        ], canonical: "one")
        let model = makeModel(library: ImportLibraryFake(), temporaryDirectory: root)

        let successURL = try model.prepareTemporaryShare(of: item, as: .plainText)
        try model.completeShare()
        XCTAssertFalse(FileManager.default.fileExists(atPath: successURL.path))

        let cancelURL = try model.prepareTemporaryShare(of: item, as: .plainText)
        try model.cancelShare()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelURL.path))

        let teardownURL = try model.prepareTemporaryShare(of: item, as: .plainText)
        model.viewDidDisappear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: teardownURL.path))

        let failing = makeModel(
            library: ImportLibraryFake(),
            temporaryDirectory: root,
            writeTemporaryFile: { data, url in
                try data.prefix(1).write(to: url)
                throw ImportTestError.writeFailed
            }
        )
        XCTAssertThrowsError(try failing.prepareTemporaryShare(of: item, as: .plainText))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testFailedRemovalRetainsTrackingUntilScavengeRetriesSuccessfully() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let removal = FailsFirstRemoval()
        let model = makeModel(
            library: ImportLibraryFake(),
            temporaryDirectory: root,
            removeTemporaryItem: removal.remove
        )
        let item = revision(representations: [
            .init(kind: .plainText, originalBytes: Data("retry".utf8), keyedDigest: Data([1])),
        ], canonical: "retry")
        let url = try model.prepareTemporaryShare(of: item, as: .plainText)

        XCTAssertThrowsError(try model.completeShare())
        XCTAssertEqual(model.temporaryShareURL, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try model.scavengeTemporaryExports()
        XCTAssertNil(model.temporaryShareURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(removal.attempts, 2)
    }

    func testFailedRemovalIsRetriedByOwnedFileDeinit() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let removal = FailsFirstRemoval()
        var model: ImportExportViewModel? = makeModel(
            library: ImportLibraryFake(),
            temporaryDirectory: root,
            removeTemporaryItem: removal.remove
        )
        let item = revision(representations: [
            .init(kind: .plainText, originalBytes: Data("deinit".utf8), keyedDigest: Data([1])),
        ], canonical: "deinit")
        let url = try XCTUnwrap(try model?.prepareTemporaryShare(of: item, as: .plainText))

        XCTAssertThrowsError(try model?.completeShare())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        model = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(removal.attempts, 2)
    }

    func testPartialWriteCleanupFailureRetainsTrackingUntilTeardownRetries() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let removal = FailsFirstRemoval()
        let model = makeModel(
            library: ImportLibraryFake(),
            temporaryDirectory: root,
            writeTemporaryFile: { data, url in
                try data.prefix(1).write(to: url)
                throw ImportTestError.writeFailed
            },
            removeTemporaryItem: removal.remove
        )
        let item = revision(representations: [
            .init(kind: .plainText, originalBytes: Data("partial".utf8), keyedDigest: Data([1])),
        ], canonical: "partial")

        XCTAssertThrowsError(try model.prepareTemporaryShare(of: item, as: .plainText))
        let partialURL = try XCTUnwrap(model.temporaryShareURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partialURL.path))

        model.viewDidDisappear()
        XCTAssertNil(model.temporaryShareURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
        XCTAssertEqual(removal.attempts, 2)
    }

    func testImportAndShareViewTeardownPurgeOnlyTheirOwnedState() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(library: ImportLibraryFake(), temporaryDirectory: root)
        let item = revision(representations: [
            .init(kind: .plainText, originalBytes: Data("shared".utf8), keyedDigest: Data([1])),
        ], canonical: "shared")
        try model.acceptImportedData(Data("preview".utf8), declaredType: .plainText)
        let shareURL = try model.prepareTemporaryShare(of: item, as: .plainText)

        model.importViewDidDisappear()
        XCTAssertNil(model.importPreview)
        XCTAssertEqual(model.temporaryShareURL, shareURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shareURL.path))

        try model.acceptImportedData(Data("second preview".utf8), declaredType: .plainText)
        model.shareViewDidDisappear()
        XCTAssertEqual(model.importPreview?.bytes, Data("second preview".utf8))
        XCTAssertNil(model.temporaryShareURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shareURL.path))
    }

    func testImportAndShareErrorsRemainContentFreeAndIndependentAcrossViewTeardown() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let removal = FailsFirstRemoval()
        let model = makeModel(
            library: ImportLibraryFake(),
            temporaryDirectory: root,
            removeTemporaryItem: removal.remove
        )
        let item = revision(representations: [
            .init(kind: .plainText, originalBytes: Data("shared".utf8), keyedDigest: Data([1])),
        ], canonical: "shared")
        _ = try model.prepareTemporaryShare(of: item, as: .plainText)
        XCTAssertThrowsError(try model.completeShare())
        let shareError = try XCTUnwrap(model.shareErrorMessage)

        model.importViewDidDisappear()
        XCTAssertEqual(model.shareErrorMessage, shareError)
        XCTAssertFalse(shareError.contains("shared"))

        XCTAssertThrowsError(try model.acceptImportedData(Data([0xFF]), declaredType: .plainText))
        let importError = try XCTUnwrap(model.importErrorMessage)
        model.shareViewDidDisappear()
        XCTAssertEqual(model.importErrorMessage, importError)
        XCTAssertFalse(importError.contains("FF"))
    }

    func testBoundedScavengeRemovesOnlyOwnedUUIDFilesAndPreservesUnrelatedFiles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = root.appendingPathComponent("\(UUID().uuidString).txt")
        let unrelated = root.appendingPathComponent("notes.txt")
        let unsupported = root.appendingPathComponent("\(UUID().uuidString).bin")
        try Data("owned".utf8).write(to: owned)
        try Data("unrelated".utf8).write(to: unrelated)
        try Data("unsupported".utf8).write(to: unsupported)

        _ = makeModel(library: ImportLibraryFake(), temporaryDirectory: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unsupported.path))
    }

    private func makeModel(
        library: ImportLibraryFake,
        temporaryDirectory: URL? = nil,
        writeTemporaryFile: @escaping (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) },
        removeTemporaryItem: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        representations: @escaping @MainActor @Sendable (RawTextRepresentation) async throws -> [ClipRepresentation] = { raw in
            [.init(kind: raw.kind, originalBytes: raw.data, keyedDigest: Data(raw.data.reversed()))]
        }
    ) -> ImportExportViewModel {
        ImportExportViewModel(
            library: library,
            representations: representations,
            temporaryDirectory: temporaryDirectory ?? temporaryRoot(),
            writeTemporaryFile: writeTemporaryFile,
            removeTemporaryItem: removeTemporaryItem
        )
    }

    private func temporaryRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func revision(representations: [ClipRepresentation], canonical: String) -> PinnedRevision {
        let payload = PinPayload(
            representations: representations,
            canonicalInsertionString: canonical,
            title: "One item",
            contentKind: .plainText,
            category: nil
        )
        return PinnedRevision(
            itemID: UUID(), revisionID: UUID(), libraryGeneration: 0, itemGeneration: 1,
            modifiedAt: Date(), deviceID: "files-test", payload: payload
        )
    }
}

private final class ImportLibraryFake: PinnedLibrary, @unchecked Sendable {
    private(set) var payloads: [PinPayload] = []

    func allItems() async throws -> [PinnedRevision] {
        []
    }

    func search(_: String, limit _: Int) async throws -> [PinnedRevision] {
        []
    }

    func pin(_ payload: PinPayload) async throws -> PinnedRevision {
        payloads.append(payload)
        return PinnedRevision(
            itemID: UUID(), revisionID: UUID(), libraryGeneration: 0, itemGeneration: 1,
            modifiedAt: Date(), deviceID: "import-test", payload: payload
        )
    }

    func revise(itemID _: UUID, payload _: PinPayload) async throws -> PinnedRevision {
        throw ImportTestError.unsupported
    }

    func delete(itemID _: UUID) async throws -> PinnedTombstone {
        throw ImportTestError.unsupported
    }

    func applyRemote(_: PinnedMutation) async throws -> MergeOutcome {
        throw ImportTestError.unsupported
    }

    func advanceResetGeneration() async throws -> LibraryResetGeneration {
        throw ImportTestError.unsupported
    }
}

private enum ImportTestError: Error {
    case unsupported
    case writeFailed
    case removeFailed
    case scopeInactive
}

private actor ImportRepresentationBarrier {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func render(_ raw: RawTextRepresentation) async throws -> [ClipRepresentation] {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
        return [.init(kind: raw.kind, originalBytes: raw.data, keyedDigest: Data(raw.data.reversed()))]
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class FailsFirstRemoval: @unchecked Sendable {
    private(set) var attempts = 0

    func remove(_ url: URL) throws {
        attempts += 1
        if attempts == 1 {
            throw ImportTestError.removeFailed
        }
        try FileManager.default.removeItem(at: url)
    }
}

private final class ImportAccessRecorder {
    private(set) var events: [String] = []
    private(set) var isActive = false

    func start(_: URL) -> Bool {
        events.append("start")
        isActive = true
        return true
    }

    func stop(_: URL) {
        events.append("stop")
        isActive = false
    }

    func contentType(of _: URL, returning type: UTType) throws -> UTType {
        guard isActive else { throw ImportTestError.scopeInactive }
        events.append("type")
        return type
    }

    func missingContentType(of _: URL) throws -> UTType? {
        guard isActive else { throw ImportTestError.scopeInactive }
        events.append("type")
        return nil
    }

    func read(_: URL, returning data: Data) throws -> Data {
        guard isActive else { throw ImportTestError.scopeInactive }
        events.append("read")
        return data
    }
}
