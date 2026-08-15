import ClipboardCore
import Foundation
import UniformTypeIdentifiers

enum ImportExportViewModelError: Error, Equatable {
    case noImportPreview
    case representationUnavailable
    case invalidRepresentation
    case staleImport
    case temporaryRemovalIncomplete
    case unsupportedImportType
}

@MainActor
final class ImportExportViewModel: ObservableObject {
    @Published private(set) var importPreview: ClipDocument?
    @Published private(set) var temporaryShareURL: URL?
    @Published private(set) var importErrorMessage: String?
    @Published private(set) var shareErrorMessage: String?

    var errorMessage: String? {
        importErrorMessage ?? shareErrorMessage
    }

    private let library: any PinnedLibrary
    private let representations: @MainActor @Sendable (RawTextRepresentation) async throws -> [ClipRepresentation]
    private let codec = ClipDocumentCodec()
    private let temporaryDirectory: URL
    private let writeTemporaryFile: (Data, URL) throws -> Void
    private let removeTemporaryItem: (URL) throws -> Void
    private let startAccessingImportedURL: (URL) -> Bool
    private let stopAccessingImportedURL: (URL) -> Void
    private let importedContentType: (URL) throws -> UTType?
    private let readImportedData: (URL) throws -> Data
    private let temporaryFileOwner: OwnedTemporaryFile
    private var intentRevision: UInt64 = 0

    init(
        library: any PinnedLibrary,
        representations: @escaping @MainActor @Sendable (RawTextRepresentation) async throws -> [ClipRepresentation],
        temporaryDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardKeyboardPhoneShare", isDirectory: true),
        writeTemporaryFile: @escaping (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) },
        removeTemporaryItem: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        startAccessingImportedURL: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccessingImportedURL: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        importedContentType: @escaping (URL) throws -> UTType? = {
            try $0.resourceValues(forKeys: [.contentTypeKey]).contentType
        },
        readImportedData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.library = library
        self.representations = representations
        self.temporaryDirectory = temporaryDirectory
        self.writeTemporaryFile = writeTemporaryFile
        self.removeTemporaryItem = removeTemporaryItem
        self.startAccessingImportedURL = startAccessingImportedURL
        self.stopAccessingImportedURL = stopAccessingImportedURL
        self.importedContentType = importedContentType
        self.readImportedData = readImportedData
        temporaryFileOwner = OwnedTemporaryFile(directory: temporaryDirectory, remove: removeTemporaryItem)
        try? scavengeTemporaryExports()
    }

    deinit {
        try? temporaryFileOwner.cleanup()
    }

    func acceptImportedData(_ data: Data, declaredType: ClipDocumentFormat) throws {
        cancelImport()
        do {
            importPreview = try codec.decode(data: data, declaredType: declaredType)
        } catch {
            importErrorMessage = "Unable to preview this file."
            throw error
        }
    }

    func importFile(at url: URL) throws {
        cancelImport()
        let accessed = startAccessingImportedURL(url)
        defer {
            if accessed {
                stopAccessingImportedURL(url)
            }
        }
        do {
            guard let contentType = try importedContentType(url),
                  let format = ClipDocumentFormat(pathExtension: url.pathExtension, contentType: contentType)
            else {
                throw ImportExportViewModelError.unsupportedImportType
            }
            try acceptImportedData(readImportedData(url), declaredType: format)
        } catch {
            importErrorMessage = "Unable to preview this file."
            throw error
        }
    }

    func pinImportedDocument(title: String) async throws {
        guard let document = importPreview else {
            throw ImportExportViewModelError.noImportPreview
        }
        let intent = intentRevision
        let raw = RawTextRepresentation(
            kind: document.format.representationKind,
            data: document.bytes,
            textProjection: document.canonicalInsertionString
        )
        do {
            let rendered = try await representations(raw)
            guard intent == intentRevision, importPreview == document else {
                throw ImportExportViewModelError.staleImport
            }
            guard rendered.count == 1,
                  rendered[0].kind == raw.kind,
                  rendered[0].originalBytes == raw.data,
                  !rendered[0].keyedDigest.isEmpty
            else {
                throw ImportExportViewModelError.invalidRepresentation
            }
            let payload = PinPayload(
                representations: rendered,
                canonicalInsertionString: document.canonicalInsertionString,
                title: title,
                contentKind: contentKind(for: document.format),
                category: nil
            )
            _ = try await library.pin(payload)
            guard intent == intentRevision else { return }
            cancelImport()
        } catch {
            guard intent == intentRevision else { throw error }
            if let protectedError = error as? EncryptedPhonePinnedStoreError,
               protectedError == .protectedDataUnavailable
            {
                protectedDataWillBecomeUnavailable()
            } else {
                importErrorMessage = "Unable to pin this file."
            }
            throw error
        }
    }

    func cancelImport() {
        intentRevision &+= 1
        importPreview = nil
        importErrorMessage = nil
    }

    func document(for item: PinnedRevision, as format: ClipDocumentFormat) throws -> ClipDocument {
        do {
            guard let representation = item.payload.representations.first(where: { $0.kind == format.representationKind }) else {
                throw ImportExportViewModelError.representationUnavailable
            }
            return try codec.decode(data: representation.originalBytes, declaredType: format)
        } catch {
            shareErrorMessage = "Unable to export this item."
            throw error
        }
    }

    func prepareTemporaryShare(of item: PinnedRevision, as format: ClipDocumentFormat) throws -> URL {
        try cleanupTrackedShare()
        let document = try document(for: item, as: format)
        let export = try codec.encode(document, as: format)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let url = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(export.fileExtension)")
        temporaryShareURL = url
        temporaryFileOwner.trackedURL = url
        do {
            try writeTemporaryFile(export.data, url)
            return url
        } catch {
            try? cleanupTrackedShare()
            shareErrorMessage = "Unable to prepare this item for sharing."
            throw error
        }
    }

    func completeShare() throws {
        try cleanupTrackedShare()
    }

    func cancelShare() throws {
        try cleanupTrackedShare()
    }

    func protectedDataWillBecomeUnavailable() {
        cancelImport()
        try? cleanupTrackedShare()
    }

    func purgeDeletionRecoveryContent() throws {
        cancelImport()
        try cleanupTrackedShare()
        try scavengeTemporaryExports(limit: .max)
    }

    func viewDidDisappear() {
        importViewDidDisappear()
        shareViewDidDisappear()
    }

    func importViewDidDisappear() {
        cancelImport()
    }

    func shareViewDidDisappear() {
        try? cleanupTrackedShare()
    }

    func scavengeTemporaryExports(limit: Int = 100) throws {
        guard FileManager.default.fileExists(atPath: temporaryDirectory.path) else { return }
        let contents = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let extensions = Set(ClipDocumentFormat.allCases.map(\.fileExtension))
        let owned = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }.filter { url in
            extensions.contains(url.pathExtension.lowercased())
                && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        for url in owned.prefix(max(0, limit)) {
            try removeTemporaryItem(url)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw ImportExportViewModelError.temporaryRemovalIncomplete
            }
        }
        if let trackedURL = temporaryFileOwner.trackedURL,
           !FileManager.default.fileExists(atPath: trackedURL.path)
        {
            try cleanupTrackedShare()
        }
    }

    private func cleanupTrackedShare() throws {
        do {
            try temporaryFileOwner.cleanup()
            temporaryShareURL = nil
            shareErrorMessage = nil
        } catch {
            shareErrorMessage = "Unable to remove the temporary share file."
            throw error
        }
    }

    private func contentKind(for format: ClipDocumentFormat) -> ContentKind {
        switch format {
        case .plainText: .plainText
        case .markdown: .markdown
        case .rtf, .html: .richText
        }
    }
}

private final class OwnedTemporaryFile: @unchecked Sendable {
    var trackedURL: URL?
    private let directory: URL
    private let remove: (URL) throws -> Void

    init(directory: URL, remove: @escaping (URL) throws -> Void) {
        self.directory = directory
        self.remove = remove
    }

    deinit {
        try? cleanup()
    }

    func cleanup() throws {
        guard let url = trackedURL else { return }
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              FileManager.default.fileExists(atPath: url.path)
        else {
            trackedURL = nil
            return
        }
        try remove(url)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ImportExportViewModelError.temporaryRemovalIncomplete
        }
        trackedURL = nil
    }
}
