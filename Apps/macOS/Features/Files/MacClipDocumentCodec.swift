import ClipboardCore
import Foundation

enum MacClipDocumentFormat: String, CaseIterable, Sendable {
    case txt
    case md
    case rtf
    case html

    var representationKind: RepresentationKind {
        switch self {
        case .txt: .plainText
        case .md: .markdown
        case .rtf: .rtf
        case .html: .html
        }
    }
}

struct MacClipDocument: Equatable, Sendable {
    let format: MacClipDocumentFormat
    let bytes: Data
}

enum MacClipDocumentError: Error, Equatable {
    case malformedDocument
    case formatMismatch
}

struct MacClipDocumentCodec: Sendable {
    func decode(_ bytes: Data, as format: MacClipDocumentFormat) throws -> MacClipDocument {
        switch format {
        case .txt, .md:
            guard String(data: bytes, encoding: .utf8) != nil else { throw MacClipDocumentError.malformedDocument }
        case .rtf:
            guard String(data: bytes, encoding: .utf8)?.hasPrefix("{\\rtf") == true else {
                throw MacClipDocumentError.malformedDocument
            }
        case .html:
            guard let value = String(data: bytes, encoding: .utf8),
                  value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<"),
                  value.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(">")
            else { throw MacClipDocumentError.malformedDocument }
        }
        return MacClipDocument(format: format, bytes: bytes)
    }

    func encode(_ document: MacClipDocument, as format: MacClipDocumentFormat) throws -> Data {
        guard document.format == format else { throw MacClipDocumentError.formatMismatch }
        _ = try decode(document.bytes, as: format)
        return document.bytes
    }
}
