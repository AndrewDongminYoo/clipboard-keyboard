import ClipboardCore
import Foundation
import XCTest

final class RepresentationResolverTests: XCTestCase {
    func testResolvePrefersExactPlainTextProjectionAndPreservesOriginalOrderAndBytes() throws {
        let htmlBytes = Data("<p>Hello</p>".utf8)
        let plainBytes = Data("Hello\r\n".utf8)

        let result = try RepresentationResolver().resolve([
            RawTextRepresentation(kind: .html, data: htmlBytes, textProjection: nil),
            RawTextRepresentation(kind: .plainText, data: plainBytes, textProjection: "Hello\r\n"),
        ])

        XCTAssertEqual(result.insertionString, "Hello\r\n")
        XCTAssertEqual(result.originals.map(\.kind), [.html, .plainText])
        XCTAssertEqual(result.originals.map(\.data), [htmlBytes, plainBytes])
    }

    func testResolveUsesExactUserDeclaredMarkdownBeforeRichFallbacks() throws {
        let markdown = "  **값**\n```swift\nlet value = 1  \n```\n"

        let result = try RepresentationResolver().resolve([
            RawTextRepresentation(kind: .html, data: Data("<p>값</p>".utf8), textProjection: nil),
            RawTextRepresentation(kind: .rtf, data: Data("{\\rtf1 값}".utf8), textProjection: "값"),
            RawTextRepresentation(kind: .markdown, data: Data(markdown.utf8), textProjection: markdown),
        ])

        XCTAssertEqual(result.insertionString, markdown)
    }

    func testResolveFallsBackFromRTFToHTMLProjection() throws {
        let rtf = try RepresentationResolver().resolve([
            RawTextRepresentation(kind: .rtf, data: Data("{\\rtf1 Hello}".utf8), textProjection: "Hello\n"),
            RawTextRepresentation(kind: .html, data: Data("<p>ignored</p>".utf8), textProjection: nil),
        ])
        let html = try RepresentationResolver().resolve([
            RawTextRepresentation(kind: .html, data: Data("<p>Hello<br>world</p>".utf8), textProjection: nil),
        ])

        XCTAssertEqual(rtf.insertionString, "Hello\n")
        XCTAssertEqual(html.insertionString, "Hello\nworld")
    }

    func testResolveRejectsUnreadableOrIncompleteSupportedRepresentations() {
        XCTAssertThrowsError(try RepresentationResolver().resolve([
            RawTextRepresentation(kind: .plainText, data: Data([0xFF]), textProjection: nil),
        ]))
        XCTAssertThrowsError(try RepresentationResolver().resolve([
            RawTextRepresentation(kind: .rtf, data: Data("{\\rtf1 partial".utf8), textProjection: nil),
        ]))
        XCTAssertThrowsError(try RepresentationResolver().resolve([]))
    }

    func testResolveRejectsInvalidHTMLEvenWhenPlainTextWouldWinCanonicalPriority() {
        XCTAssertThrowsError(try RepresentationResolver().resolve([
            RawTextRepresentation(kind: .plainText, data: Data("Safe".utf8), textProjection: "Safe"),
            RawTextRepresentation(kind: .html, data: Data([0x3C, 0x70, 0x3E, 0xFF]), textProjection: nil),
        ])) { error in
            XCTAssertEqual(error as? RepresentationResolverError, .invalidTextEncoding(.html))
        }
    }
}
