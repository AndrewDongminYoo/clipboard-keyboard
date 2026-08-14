import ClipboardCore
import Foundation

enum PaletteScope: String, CaseIterable, Sendable {
    case recent = "Recent"
    case pinned = "Pinned"
}

enum PaletteKeyCommand: Sendable {
    case upArrow
    case downArrow
    case returnKey
}

struct PaletteItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let capturedAt: Date
    let preview: String
    let contentKind: ContentKind
    let sourceConfidence: SourceConfidence
    let representations: [ClipRepresentation]
    let canonicalInsertionString: String
    let title: String
    let category: ClipCategory?
    let isPinned: Bool
}

@MainActor
protocol PaletteDataSource: AnyObject {
    func recentItems(matching query: String) async throws -> [ClipEnvelope]
    func pinnedItems(matching query: String) async throws -> [PinnedRevision]
    func pin(_ payload: PinPayload) async throws
    func deleteRecent(id: UUID) async throws
    func deletePinned(id: UUID) async throws
}

@MainActor
protocol PalettePasteboardWriting: AnyObject {
    func write(_ representations: [ClipRepresentation]) throws
}

@MainActor
protocol PaletteExporting: AnyObject {
    func export(_ item: PaletteItem, as format: MacClipDocumentFormat) async throws
}

@MainActor
protocol PaletteImporting: AnyObject {
    func importAndPin() async throws
}

@MainActor
protocol PaletteSharing: AnyObject {
    func share(_ item: PaletteItem, as format: MacClipDocumentFormat) async throws
}

@MainActor
final class NoopPaletteExporter: PaletteExporting {
    func export(_: PaletteItem, as _: MacClipDocumentFormat) async throws {}
}

@MainActor final class NoopPaletteImporter: PaletteImporting { func importAndPin() async throws {} }
@MainActor final class NoopPaletteSharer: PaletteSharing { func share(_: PaletteItem, as _: MacClipDocumentFormat) async throws {} }

@MainActor
final class PaletteViewModel: ObservableObject {
    @Published var query = ""
    @Published var scope: PaletteScope = .recent
    @Published private(set) var items: [PaletteItem] = []
    @Published private(set) var selectedItemID: UUID?
    @Published private(set) var shouldClose = false
    @Published private(set) var statusMessage: String?

    private let dataSource: any PaletteDataSource
    private let pasteboardWriter: any PalettePasteboardWriting
    private let exporter: any PaletteExporting
    private let importer: any PaletteImporting
    private let sharer: any PaletteSharing

    init(
        dataSource: any PaletteDataSource,
        pasteboardWriter: any PalettePasteboardWriting,
        exporter: any PaletteExporting = NoopPaletteExporter(),
        importer: any PaletteImporting = NoopPaletteImporter(),
        sharer: any PaletteSharing = NoopPaletteSharer()
    ) {
        self.dataSource = dataSource
        self.pasteboardWriter = pasteboardWriter
        self.exporter = exporter
        self.importer = importer
        self.sharer = sharer
    }

    func search(scope: PaletteScope) async {
        self.scope = scope
        do {
            items = switch scope {
            case .recent:
                try await dataSource.recentItems(matching: query).map(Self.item)
            case .pinned:
                try await dataSource.pinnedItems(matching: query).map(Self.item)
            }
            selectedItemID = items.first?.id
            statusMessage = nil
        } catch {
            items = []
            selectedItemID = nil
            statusMessage = "Protected Storage Locked"
        }
    }

    func handle(_ command: PaletteKeyCommand) async {
        switch command {
        case .upArrow:
            moveSelection(by: -1)
        case .downArrow:
            moveSelection(by: 1)
        case .returnKey:
            await copySelected(as: .originalCompatible)
            if statusMessage == nil {
                shouldClose = true
            }
        }
    }

    func select(id: UUID?) {
        guard let id, items.contains(where: { $0.id == id }) else { return }
        selectedItemID = id
    }

    func copySelected(as format: CopyFormat) async {
        guard let item = selectedItem else { return }
        do {
            try pasteboardWriter.write(representations(for: item, format: format))
            statusMessage = nil
        } catch {
            statusMessage = "Copy Failed"
        }
    }

    func pinSelected() async {
        guard let item = selectedItem, !item.isPinned else { return }
        do {
            try await dataSource.pin(.init(
                representations: item.representations,
                canonicalInsertionString: item.canonicalInsertionString,
                title: item.title,
                contentKind: item.contentKind,
                category: item.category
            ))
            statusMessage = "Sync Pending"
        } catch {
            statusMessage = "Protected Storage Locked"
        }
    }

    func exportSelected(as format: MacClipDocumentFormat) async {
        guard let item = selectedItem else { return }
        do {
            try await exporter.export(item, as: format)
            statusMessage = nil
        } catch {
            statusMessage = "Export Failed"
        }
    }

    func prepareForPresentation() {
        shouldClose = false
    }

    func importAndPin() async {
        do {
            try await importer.importAndPin()
            statusMessage = "Sync Pending"
            await search(scope: .pinned)
        } catch {
            statusMessage = "Import Failed"
        }
    }

    func shareSelected(as format: MacClipDocumentFormat) async {
        guard let item = selectedItem else { return }
        do {
            try await sharer.share(item, as: format)
            statusMessage = nil
        } catch {
            statusMessage = "Share Failed"
        }
    }

    func deleteSelected() async {
        guard let item = selectedItem else { return }
        do {
            if item.isPinned {
                try await dataSource.deletePinned(id: item.id)
                statusMessage = "Deletion Pending"
            } else {
                try await dataSource.deleteRecent(id: item.id)
                statusMessage = nil
            }
            items.removeAll { $0.id == item.id }
            selectedItemID = items.first?.id
        } catch {
            statusMessage = "Delete Failed"
        }
    }

    private var selectedItem: PaletteItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    private func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let current = selectedItemID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        selectedItemID = items[min(max(current + offset, 0), items.count - 1)].id
    }

    private func representations(for item: PaletteItem, format: CopyFormat) throws -> [ClipRepresentation] {
        switch format {
        case .originalCompatible:
            item.representations
        case .plainText:
            [derivedPlainText(item.canonicalInsertionString)]
        case .markdownSource:
            try [requiredOriginal(.markdown, in: item, format: format)]
        case .html:
            try [requiredOriginal(.html, in: item, format: format)]
        case .rtf:
            try [requiredOriginal(.rtf, in: item, format: format)]
        case .digitsOnly:
            [derivedPlainText(item.canonicalInsertionString.filter { $0.wholeNumberValue != nil })]
        case .trimSurroundingWhitespace:
            [derivedPlainText(item.canonicalInsertionString.trimmingCharacters(in: .whitespacesAndNewlines))]
        case .normalizeInternalWhitespace:
            [derivedPlainText(item.canonicalInsertionString.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " "))]
        }
    }

    private func requiredOriginal(_ kind: RepresentationKind, in item: PaletteItem, format: CopyFormat) throws -> ClipRepresentation {
        guard let representation = item.representations.first(where: { $0.kind == kind }) else {
            throw TextTransformationError.noLosslessSource(format)
        }
        return representation
    }

    private func derivedPlainText(_ value: String) -> ClipRepresentation {
        .init(kind: .plainText, originalBytes: Data(value.utf8), keyedDigest: Data([1]))
    }

    private static func item(_ envelope: ClipEnvelope) -> PaletteItem {
        .init(
            id: envelope.id,
            capturedAt: envelope.capturedAt,
            preview: boundedPreview(envelope.canonicalInsertionString),
            contentKind: envelope.contentKind,
            sourceConfidence: envelope.sourceConfidence,
            representations: envelope.representations,
            canonicalInsertionString: envelope.canonicalInsertionString,
            title: envelope.title,
            category: envelope.category,
            isPinned: false
        )
    }

    private static func item(_ revision: PinnedRevision) -> PaletteItem {
        .init(
            id: revision.itemID,
            capturedAt: revision.modifiedAt,
            preview: boundedPreview(revision.payload.canonicalInsertionString),
            contentKind: revision.payload.contentKind,
            sourceConfidence: .unknown,
            representations: revision.payload.representations,
            canonicalInsertionString: revision.payload.canonicalInsertionString,
            title: revision.payload.title,
            category: revision.payload.category,
            isPinned: true
        )
    }

    private static func boundedPreview(_ value: String) -> String {
        String((value.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").prefix(120))
    }
}
