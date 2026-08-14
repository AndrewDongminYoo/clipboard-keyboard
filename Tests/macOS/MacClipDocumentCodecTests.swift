import AppKit
import ClipboardCore
@testable import ClipboardKeyboardMac
import CryptoKit
import XCTest

final class MacClipDocumentCodecTests: XCTestCase {
    func testEverySupportedFormatRoundTripsExactSameFormatBytes() throws {
        let fixtures: [(MacClipDocumentFormat, Data)] = [
            (.txt, Data("plain\ntext".utf8)),
            (.md, Data("# heading\n\nbody".utf8)),
            (.rtf, Data("{\\rtf1\\ansi exact}".utf8)),
            (.html, Data("<!doctype html><b>exact</b>".utf8)),
        ]
        let codec = MacClipDocumentCodec()

        for (format, bytes) in fixtures {
            let decoded = try codec.decode(bytes, as: format)
            XCTAssertEqual(decoded.format, format)
            XCTAssertEqual(try codec.encode(decoded, as: format), bytes)
        }
    }

    func testMalformedAndCrossFormatDocumentsAreRejected() {
        let codec = MacClipDocumentCodec()

        XCTAssertThrowsError(try codec.decode(Data([0xFF]), as: .txt))
        XCTAssertThrowsError(try codec.decode(Data("not rtf".utf8), as: .rtf))
        XCTAssertThrowsError(try codec.decode(Data("plain".utf8), as: .html))
        XCTAssertThrowsError(try codec.encode(.init(format: .txt, bytes: Data("text".utf8)), as: .md))
    }

    func testCancelledExportRemovesOnlyItsTemporaryFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = MacImportExportController(temporaryDirectory: root)
        let document = MacClipDocument(format: .txt, bytes: Data("temporary-sentinel".utf8))

        let temporaryURL = try controller.prepareTemporaryExport(document)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))

        try controller.cancelTemporaryExport(temporaryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testImportRequiresExplicitPinAndPreservesOriginalFormatBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("# exact import".utf8)
        try original.write(to: sourceURL)
        let store = EncryptedMacPinnedStore(
            fileURL: root.appendingPathComponent("pinned.encrypted"),
            key: SymmetricKey(data: Data(repeating: 3, count: 32))
        )
        let library = LocalMacPinnedLibrary(store: store, deviceID: "import-test")
        let controller = MacImportExportController(temporaryDirectory: root, digestProvider: { _ in Data([5]) })

        let document = try controller.importDocument(at: sourceURL, as: .md)
        let itemsBeforePin = try await library.allItems()
        XCTAssertEqual(itemsBeforePin, [])

        let revision = try await controller.pinImportedDocument(document, title: "Imported", using: library)

        XCTAssertEqual(revision.payload.representations.first?.kind, .markdown)
        XCTAssertEqual(revision.payload.representations.first?.originalBytes, original)
        XCTAssertEqual(revision.payload.representations.first?.keyedDigest, Data([5]))
    }

    func testRichImportsUseFormatSpecificCanonicalProjectionAndPreserveBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rtf = try NSAttributedString(string: "RTF canonical").data(
            from: NSRange(location: 0, length: 13), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let html = Data("<p>HTML <b>canonical</b></p>".utf8)
        let store = EncryptedMacPinnedStore(fileURL: root.appendingPathComponent("pinned.encrypted"), key: SymmetricKey(data: Data(repeating: 8, count: 32)))
        let library = LocalMacPinnedLibrary(store: store, deviceID: "projection")
        let controller = MacImportExportController(temporaryDirectory: root, digestProvider: { _ in Data([9]) })

        let rtfRevision = try await controller.pinImportedDocument(.init(format: .rtf, bytes: rtf), title: "RTF", using: library)
        let htmlRevision = try await controller.pinImportedDocument(.init(format: .html, bytes: html), title: "HTML", using: library)
        XCTAssertEqual(rtfRevision.payload.canonicalInsertionString, "RTF canonical")
        XCTAssertEqual(rtfRevision.payload.representations.first?.originalBytes, rtf)
        XCTAssertEqual(htmlRevision.payload.canonicalInsertionString, "HTML canonical")
        XCTAssertEqual(htmlRevision.payload.representations.first?.originalBytes, html)
    }
}
