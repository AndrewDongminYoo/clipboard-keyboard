import ClipboardCore
import Foundation
import UniformTypeIdentifiers

enum ClipDocumentFormat: String, CaseIterable, Equatable, Sendable {
    case plainText
    case markdown
    case rtf
    case html

    var representationKind: RepresentationKind {
        switch self {
        case .plainText: .plainText
        case .markdown: .markdown
        case .rtf: .rtf
        case .html: .html
        }
    }

    var fileExtension: String {
        switch self {
        case .plainText: "txt"
        case .markdown: "md"
        case .rtf: "rtf"
        case .html: "html"
        }
    }

    var contentType: UTType {
        switch self {
        case .plainText: .plainText
        case .markdown: UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
        case .rtf: .rtf
        case .html: .html
        }
    }

    init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "txt", "text": self = .plainText
        case "md", "markdown": self = .markdown
        case "rtf": self = .rtf
        case "html", "htm": self = .html
        default: return nil
        }
    }

    init?(contentType: UTType) {
        if let exact = Self.allCases.first(where: { $0.contentType.identifier == contentType.identifier }) {
            self = exact
            return
        }
        for format in [Self.markdown, .rtf, .html, .plainText] where contentType.conforms(to: format.contentType) {
            self = format
            return
        }
        return nil
    }

    init?(pathExtension: String, contentType: UTType) {
        guard let extensionFormat = Self(pathExtension: pathExtension) else { return nil }
        guard contentType.conforms(to: extensionFormat.contentType),
              Self(contentType: contentType) == extensionFormat
        else { return nil }
        self = extensionFormat
    }
}

struct ClipDocument: Equatable, Sendable {
    let format: ClipDocumentFormat
    let bytes: Data
    let canonicalInsertionString: String
}

struct ClipDocumentExport: Equatable, Sendable {
    let data: Data
    let fileExtension: String
}

enum ClipDocumentCodecError: Error, Equatable {
    case malformedDocument
    case formatMismatch
}

struct ClipDocumentCodec: Sendable {
    private let rtfProjector = PhoneRTFTextProjector()
    private let htmlProjector = HTMLTextProjector()

    func decode(data: Data, declaredType: ClipDocumentFormat) throws -> ClipDocument {
        let canonicalInsertionString: String
        switch declaredType {
        case .plainText, .markdown:
            guard let value = String(data: data, encoding: .utf8) else {
                throw ClipDocumentCodecError.malformedDocument
            }
            guard !containsBinaryControl(in: value) else {
                throw ClipDocumentCodecError.malformedDocument
            }
            guard !looksLikeRTF(value), !looksLikeHTML(value) else {
                throw ClipDocumentCodecError.formatMismatch
            }
            canonicalInsertionString = value
        case .rtf:
            if let value = String(data: data, encoding: .utf8), looksLikeHTML(value) {
                throw ClipDocumentCodecError.formatMismatch
            }
            do {
                canonicalInsertionString = try rtfProjector.project(data)
            } catch {
                throw ClipDocumentCodecError.malformedDocument
            }
        case .html:
            guard let value = String(data: data, encoding: .utf8) else {
                throw ClipDocumentCodecError.malformedDocument
            }
            guard !looksLikeRTF(value) else {
                throw ClipDocumentCodecError.formatMismatch
            }
            guard HTMLStructureValidator().isValid(value) else {
                throw ClipDocumentCodecError.malformedDocument
            }
            do {
                canonicalInsertionString = try htmlProjector.project(data)
            } catch {
                throw ClipDocumentCodecError.malformedDocument
            }
        }
        return ClipDocument(format: declaredType, bytes: data, canonicalInsertionString: canonicalInsertionString)
    }

    func encode(_ document: ClipDocument, as format: ClipDocumentFormat) throws -> ClipDocumentExport {
        guard document.format == format else {
            throw ClipDocumentCodecError.formatMismatch
        }
        _ = try decode(data: document.bytes, declaredType: format)
        return ClipDocumentExport(data: document.bytes, fileExtension: format.fileExtension)
    }

    private func looksLikeRTF(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(#"{\rtf"#)
    }

    private func looksLikeHTML(_ value: String) -> Bool {
        HTMLStructureValidator().isValid(value)
    }

    private func containsBinaryControl(in value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control && scalar != "\t" && scalar != "\n" && scalar != "\r"
        }
    }
}

private struct HTMLStructureValidator {
    private let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]

    func isValid(_ html: String) -> Bool {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "<", trimmed.last == ">" else { return false }
        var cursor = trimmed.startIndex
        var stack: [String] = []
        var foundElement = false

        while let open = trimmed[cursor...].firstIndex(of: "<") {
            guard let close = tagEnd(in: trimmed, after: open) else { return false }
            let raw = trimmed[trimmed.index(after: open) ..< close].trimmingCharacters(in: .whitespacesAndNewlines)
            cursor = trimmed.index(after: close)
            guard !raw.isEmpty else { return false }
            if raw.hasPrefix("!") || raw.hasPrefix("?") {
                continue
            }

            let isClosing = raw.hasPrefix("/")
            let nameStart = raw.index(raw.startIndex, offsetBy: isClosing ? 1 : 0)
            let remainder = raw[nameStart...]
            let nameEnd = remainder.firstIndex { $0.isWhitespace || $0 == "/" } ?? remainder.endIndex
            let name = String(remainder[..<nameEnd]).lowercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return false }
            foundElement = true

            if isClosing {
                guard stack.popLast() == name else { return false }
            } else if !raw.hasSuffix("/"), !voidElements.contains(name) {
                stack.append(name)
            }
        }
        return foundElement && stack.isEmpty && cursor == trimmed.endIndex
    }

    private func tagEnd(in html: String, after open: String.Index) -> String.Index? {
        var cursor = html.index(after: open)
        var quote: Character?
        while cursor < html.endIndex {
            let character = html[cursor]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return cursor
            }
            cursor = html.index(after: cursor)
        }
        return nil
    }
}
