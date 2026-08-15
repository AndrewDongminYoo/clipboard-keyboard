import SwiftUI
import UniformTypeIdentifiers

struct ClipFileDocument: FileDocument {
    static let readableContentTypes = ClipDocumentFormat.allCases.map(\.contentType)
    static let writableContentTypes = readableContentTypes

    let document: ClipDocument

    init(document: ClipDocument) {
        self.document = document
    }

    init(configuration: ReadConfiguration) throws {
        guard let format = Self.resolvedFormat(for: configuration.contentType),
              let data = configuration.file.regularFileContents
        else {
            throw ClipDocumentCodecError.formatMismatch
        }
        document = try ClipDocumentCodec().decode(data: data, declaredType: format)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard Self.canWrite(documentFormat: document.format, contentType: configuration.contentType) else {
            throw ClipDocumentCodecError.formatMismatch
        }
        let export = try ClipDocumentCodec().encode(document, as: document.format)
        return FileWrapper(regularFileWithContents: export.data)
    }

    static func canWrite(documentFormat: ClipDocumentFormat, contentType: UTType) -> Bool {
        resolvedFormat(for: contentType) == documentFormat
    }

    private static func resolvedFormat(for contentType: UTType) -> ClipDocumentFormat? {
        ClipDocumentFormat(contentType: contentType)
    }
}
