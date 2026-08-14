@testable import ClipboardKeyboardiOS
import UIKit
import UniformTypeIdentifiers
import XCTest

final class ClipDocumentCodecTests: XCTestCase {
    func testEverySupportedFormatRoundTripsExactBytesAndRequiredExtension() throws {
        let attributed = NSAttributedString(string: "RTF 한글\r\nline")
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let fixtures: [(ClipDocumentFormat, Data, String)] = [
            (.plainText, Data("한글 👋\r\nsecond".utf8), "txt"),
            (.markdown, Data("# 제목\r\n\r\n```swift\r\n  let value = 1\r\n```".utf8), "md"),
            (.rtf, rtf, "rtf"),
            (.html, Data("<!doctype html><p>한글 <b>HTML</b></p>".utf8), "html"),
        ]
        let codec = ClipDocumentCodec()

        for (format, bytes, expectedExtension) in fixtures {
            let document = try codec.decode(data: bytes, declaredType: format)
            let export = try codec.encode(document, as: format)

            XCTAssertEqual(export.data, bytes, "\(format)")
            XCTAssertEqual(export.fileExtension, expectedExtension, "\(format)")
        }
    }

    func testDecodeDerivesCanonicalInsertionWithoutChangingOriginalBytes() throws {
        let html = Data("<p>Hello <b>world</b></p>".utf8)

        let document = try ClipDocumentCodec().decode(data: html, declaredType: .html)

        XCTAssertEqual(document.canonicalInsertionString, "Hello world")
        XCTAssertEqual(document.bytes, html)
    }

    func testMalformedInvalidUTF8AndCrossFormatDocumentsAreRejected() throws {
        let codec = ClipDocumentCodec()
        let validRTF = try NSAttributedString(string: "rich").data(
            from: NSRange(location: 0, length: 4),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )

        assertCodecError(.malformedDocument, from: { try codec.decode(data: Data([0xFF, 0x00]), declaredType: .plainText) })
        assertCodecError(.malformedDocument, from: { try codec.decode(data: Data([0xFF]), declaredType: .markdown) })
        assertCodecError(.malformedDocument, from: { try codec.decode(data: Data("not rtf".utf8), declaredType: .rtf) })
        assertCodecError(.malformedDocument, from: { try codec.decode(data: Data("<p>unterminated".utf8), declaredType: .html) })
        assertCodecError(.formatMismatch, from: { try codec.decode(data: validRTF, declaredType: .html) })
        assertCodecError(.formatMismatch, from: { try codec.decode(data: Data("<p>html</p>".utf8), declaredType: .rtf) })
    }

    func testCrossFormatEncodeIsRejected() throws {
        let codec = ClipDocumentCodec()
        let document = try codec.decode(data: Data("plain".utf8), declaredType: .plainText)

        assertCodecError(.formatMismatch, from: { try codec.encode(document, as: .markdown) })
    }

    func testPlainTextAndMarkdownRejectBinaryControlsButAllowTabLineFeedAndCarriageReturn() throws {
        let codec = ClipDocumentCodec()

        for format in [ClipDocumentFormat.plainText, .markdown] {
            assertCodecError(.malformedDocument, from: {
                try codec.decode(data: Data("visible\u{0000}binary".utf8), declaredType: format)
            })
            assertCodecError(.malformedDocument, from: {
                try codec.decode(data: Data("visible\u{0001}binary".utf8), declaredType: format)
            })
            XCTAssertEqual(
                try codec.decode(data: Data("tab\tline\nreturn\r".utf8), declaredType: format).canonicalInsertionString,
                "tab\tline\nreturn\r"
            )
        }
    }

    func testContentTypeResolutionPrefersMarkdownOverPlainTextAndRejectsExtensionMismatch() throws {
        let markdown = try XCTUnwrap(UTType("net.daringfireball.markdown"))

        XCTAssertEqual(ClipDocumentFormat(contentType: markdown), .markdown)
        XCTAssertEqual(ClipDocumentFormat(contentType: .utf8PlainText), .plainText)
        XCTAssertEqual(ClipDocumentFormat(pathExtension: "md", contentType: markdown), .markdown)
        XCTAssertNil(ClipDocumentFormat(pathExtension: "txt", contentType: markdown))
        XCTAssertNil(ClipDocumentFormat(pathExtension: "txt", contentType: .data))
    }

    func testFileDocumentWriteCompatibilityRejectsPlainMarkdownCrossFormatAndAcceptsExactMarkdown() throws {
        let markdown = try XCTUnwrap(UTType("net.daringfireball.markdown"))

        XCTAssertTrue(ClipFileDocument.canWrite(documentFormat: .markdown, contentType: markdown))
        XCTAssertFalse(ClipFileDocument.canWrite(documentFormat: .plainText, contentType: markdown))
        XCTAssertFalse(ClipFileDocument.canWrite(documentFormat: .markdown, contentType: .plainText))
    }

    private func assertCodecError<T>(
        _ expected: ClipDocumentCodecError,
        from operation: () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? ClipDocumentCodecError, expected, file: file, line: line)
        }
    }
}
