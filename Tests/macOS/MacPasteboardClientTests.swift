import AppKit
import ClipboardCore
@testable import ClipboardKeyboardMac
import XCTest

@MainActor
final class MacPasteboardClientTests: XCTestCase {
    func testReadsEveryDeclaredSupportedRepresentationAndIgnoresAuxiliaryTypes() throws {
        let pasteboard = NSPasteboard(name: .init("MacPasteboardClientTests.read.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Data("plain".utf8), forType: .string)
        pasteboard.setData(Data("# heading".utf8), forType: .init("net.daringfireball.markdown"))
        pasteboard.setData(Data("auxiliary".utf8), forType: .init("com.example.auxiliary"))
        let client = MacPasteboardClient(pasteboard: pasteboard, maximumTotalByteCount: 1024)
        let metadata = client.readMetadata()

        let representations = try client.readSupportedRepresentations(for: metadata.changeCount)

        XCTAssertEqual(Set(representations.map(\.kind)), [.plainText, .markdown])
        XCTAssertEqual(representations.first { $0.kind == .plainText }?.data, Data("plain".utf8))
        XCTAssertFalse(representations.contains { $0.data == Data("auxiliary".utf8) })
    }

    func testDropsWholeReadWhenAuthorizedChangeCountIsStale() {
        let pasteboard = NSPasteboard(name: .init("MacPasteboardClientTests.stale.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Data("first".utf8), forType: .string)
        let client = MacPasteboardClient(pasteboard: pasteboard)
        let authorizedChangeCount = client.readMetadata().changeCount
        pasteboard.clearContents()
        pasteboard.setData(Data("second".utf8), forType: .string)

        XCTAssertThrowsError(try client.readSupportedRepresentations(for: authorizedChangeCount)) { error in
            XCTAssertEqual(error as? MacPasteboardError, .changeCountChanged)
        }
    }

    func testIdenticalPlainTextAliasesDeduplicateToOneRepresentation() throws {
        let pasteboard = NSPasteboard(name: .init("MacPasteboardClientTests.aliases.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Data("same".utf8), forType: .init("public.utf8-plain-text"))
        pasteboard.setData(Data("same".utf8), forType: .init("public.plain-text"))
        let client = MacPasteboardClient(pasteboard: pasteboard)
        let metadata = client.readMetadata()

        let representations = try client.readSupportedRepresentations(for: metadata.changeCount)

        XCTAssertEqual(representations, [.init(kind: .plainText, data: Data("same".utf8), textProjection: "same")])
    }

    func testConflictingPlainTextAliasesRejectWholeRead() {
        let pasteboard = NSPasteboard(name: .init("MacPasteboardClientTests.conflict.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Data("utf8".utf8), forType: .init("public.utf8-plain-text"))
        pasteboard.setData(Data("plain".utf8), forType: .init("public.plain-text"))
        let client = MacPasteboardClient(pasteboard: pasteboard)
        let metadata = client.readMetadata()

        XCTAssertThrowsError(try client.readSupportedRepresentations(for: metadata.changeCount)) { error in
            XCTAssertEqual(error as? MacPasteboardError, .conflictingAliases)
        }
    }

    func testWritesCompleteRepresentationsAndMarker() throws {
        let pasteboard = NSPasteboard(name: .init("MacPasteboardClientTests.write.\(UUID().uuidString)"))
        let client = MacPasteboardClient(pasteboard: pasteboard)
        let representations = [
            RawTextRepresentation(kind: .plainText, data: Data("hello".utf8), textProjection: "hello"),
            RawTextRepresentation(kind: .html, data: Data("<b>hello</b>".utf8), textProjection: nil),
        ]

        try client.writeRepresentations(representations, marker: "com.example.private")

        XCTAssertEqual(pasteboard.data(forType: .string), Data("hello".utf8))
        XCTAssertEqual(pasteboard.data(forType: .html), Data("<b>hello</b>".utf8))
        XCTAssertNotNil(pasteboard.data(forType: .init("com.example.private")))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }

    func testConflictingDuplicateKindWritePreservesPasteboardAndChangeCount() {
        let pasteboard = NSPasteboard(name: .init("MacPasteboardClientTests.write-conflict.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Data("existing".utf8), forType: .string)
        let changeCount = pasteboard.changeCount
        let client = MacPasteboardClient(pasteboard: pasteboard)

        XCTAssertThrowsError(try client.writeRepresentations([
            .init(kind: .plainText, data: Data("first".utf8), textProjection: "first"),
            .init(kind: .plainText, data: Data("second".utf8), textProjection: "second"),
        ], marker: nil)) { error in
            XCTAssertEqual(error as? MacPasteboardError, .conflictingRepresentations)
        }
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.data(forType: .string), Data("existing".utf8))
    }
}
