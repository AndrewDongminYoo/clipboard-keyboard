import ClipboardCore
import Foundation

struct MacImportExportController: Sendable {
    private let codec = MacClipDocumentCodec()
    private let temporaryDirectory: URL
    private let digestProvider: (@Sendable (Data) throws -> Data)?

    init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardKeyboard", isDirectory: true),
        digestProvider: (@Sendable (Data) throws -> Data)? = nil
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.digestProvider = digestProvider
    }

    func importDocument(at url: URL, as format: MacClipDocumentFormat) throws -> MacClipDocument {
        try codec.decode(Data(contentsOf: url), as: format)
    }

    func pinImportedDocument(
        _ document: MacClipDocument,
        title: String,
        using library: any PinnedLibrary
    ) async throws -> PinnedRevision {
        guard let digestProvider else { throw PersistenceSecurityError.keyUnavailable }
        let text = String(data: document.bytes, encoding: .utf8) ?? ""
        let payload = try PinPayload(
            representations: [
                ClipRepresentation(
                    kind: document.format.representationKind,
                    originalBytes: document.bytes,
                    keyedDigest: digestProvider(document.bytes)
                ),
            ],
            canonicalInsertionString: text,
            title: title,
            contentKind: document.format == .md ? .markdown : (document.format == .txt ? .plainText : .richText),
            category: nil
        )
        return try await library.pin(payload)
    }

    func export(_ document: MacClipDocument, to destination: URL) throws {
        let data = try codec.encode(document, as: document.format)
        try data.write(to: destination, options: .atomic)
    }

    func prepareTemporaryExport(_ document: MacClipDocument) throws -> URL {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let url = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(document.format.rawValue)")
        try export(document, to: url)
        return url
    }

    func cancelTemporaryExport(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == temporaryDirectory.standardizedFileURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
