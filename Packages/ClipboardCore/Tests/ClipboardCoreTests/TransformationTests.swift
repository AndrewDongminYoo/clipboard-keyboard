import ClipboardCore
import Foundation
import XCTest

final class TransformationTests: XCTestCase {
    func testOriginalCompatiblePreservesEveryOriginalByteSequence() throws {
        let content = ResolvedTextContent(
            insertionString: "Hello\n",
            originals: [
                RawTextRepresentation(kind: .html, data: Data("<p>Hello</p>".utf8), textProjection: nil),
                RawTextRepresentation(kind: .plainText, data: Data("Hello\n".utf8), textProjection: "Hello\n"),
            ]
        )

        let rendered = try transformer().render(content, as: .originalCompatible)

        XCTAssertEqual(rendered.map(\.kind), [.html, .plainText])
        XCTAssertEqual(rendered.map(\.originalBytes), content.originals.map(\.data))
        XCTAssertEqual(rendered.map(\.byteSize), content.originals.map(\.data.count))
        XCTAssertEqual(rendered.map(\.keyedDigest), content.originals.map { Self.digest(for: $0.data) })
    }

    func testExplicitTextTransformsCreateNewPlainTextRepresentationsWithoutChangingOriginals() throws {
        let original = Data("  A\t B\r\n123-45  \n".utf8)
        let content = ResolvedTextContent(
            insertionString: "  A\t B\r\n123-45  \n",
            originals: [RawTextRepresentation(kind: .plainText, data: original, textProjection: "  A\t B\r\n123-45  \n")]
        )

        let digits = try transformer().render(content, as: .digitsOnly)
        let trimmed = try transformer().render(content, as: .trimSurroundingWhitespace)
        let normalized = try transformer().render(content, as: .normalizeInternalWhitespace)

        XCTAssertEqual(digits.singleString, "12345")
        XCTAssertEqual(trimmed.singleString, "A\t B\r\n123-45")
        XCTAssertEqual(normalized.singleString, "A B 123-45")
        XCTAssertEqual(digits.first?.keyedDigest, Self.digest(for: Data("12345".utf8)))
        XCTAssertEqual(trimmed.first?.keyedDigest, Self.digest(for: Data("A\t B\r\n123-45".utf8)))
        XCTAssertEqual(normalized.first?.keyedDigest, Self.digest(for: Data("A B 123-45".utf8)))
        XCTAssertEqual(content.originals[0].data, original)
        XCTAssertTrue([digits, trimmed, normalized].allSatisfy { $0.first?.kind == .plainText })
    }

    func testRichAndMarkdownRenderingRequiresTheCorrespondingLosslessOriginal() throws {
        let plain = ResolvedTextContent(
            insertionString: "Hello",
            originals: [RawTextRepresentation(kind: .plainText, data: Data("Hello".utf8), textProjection: "Hello")]
        )

        XCTAssertThrowsError(try transformer().render(plain, as: .html))
        XCTAssertThrowsError(try transformer().render(plain, as: .rtf))
        XCTAssertThrowsError(try transformer().render(plain, as: .markdownSource))

        let htmlBytes = Data("<strong>Hello</strong>".utf8)
        let html = ResolvedTextContent(
            insertionString: "Hello",
            originals: [RawTextRepresentation(kind: .html, data: htmlBytes, textProjection: nil)]
        )
        let rendered = try transformer().render(html, as: .html)
        XCTAssertEqual(rendered.first?.originalBytes, htmlBytes)
        XCTAssertEqual(rendered.first?.keyedDigest, Self.digest(for: htmlBytes))
    }

    func testClipRepresentationRejectsMismatchedByteSize() throws {
        XCTAssertThrowsError(try ClipRepresentation(
            kind: .plainText,
            originalBytes: Data("abc".utf8),
            byteSize: 2,
            keyedDigest: Data([0x01])
        ))
        let representation = ClipRepresentation(
            kind: .plainText,
            originalBytes: Data("abc".utf8),
            keyedDigest: Data([0x01])
        )
        XCTAssertEqual(representation.byteSize, 3)
        XCTAssertEqual(representation.keyedDigest, Data([0x01]))
    }

    func testTransformerRejectsAnEmptyCallerSuppliedDigest() {
        let content = ResolvedTextContent(
            insertionString: "Hello",
            originals: [RawTextRepresentation(kind: .plainText, data: Data("Hello".utf8), textProjection: "Hello")]
        )

        XCTAssertThrowsError(try TextTransformer(digestProvider: { _ in Data() }).render(content, as: .plainText)) { error in
            XCTAssertEqual(error as? TextTransformationError, .emptyKeyedDigest)
        }
    }

    private func transformer() -> TextTransformer {
        TextTransformer(digestProvider: Self.digest(for:))
    }

    private static func digest(for bytes: Data) -> Data {
        var digest = Data([0xA5])
        digest.append(bytes)
        return digest
    }
}

private extension [ClipRepresentation] {
    var singleString: String? {
        guard count == 1 else { return nil }
        return String(data: self[0].originalBytes, encoding: .utf8)
    }
}
