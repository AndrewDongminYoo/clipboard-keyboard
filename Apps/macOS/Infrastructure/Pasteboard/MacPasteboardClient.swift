import AppKit
import ClipboardCore
import Foundation

struct MacPasteboardMetadata: Equatable, Sendable {
    let changeCount: Int
    let declaredTypeIdentifiers: [String]
}

enum MacPasteboardError: Error, Equatable {
    case changeCountChanged
    case representationReadFailed
    case conflictingAliases
    case conflictingRepresentations
    case payloadTooLarge
    case writeFailed
}

@MainActor
protocol MacPasteboardReading: AnyObject {
    func readMetadata() -> MacPasteboardMetadata
    func readSupportedRepresentations(for changeCount: Int) throws -> [RawTextRepresentation]
    func writeRepresentations(_ representations: [RawTextRepresentation], marker: String?) throws
}

@MainActor
final class MacPasteboardClient: MacPasteboardReading {
    private static let supportedTypes: [(NSPasteboard.PasteboardType, RepresentationKind)] = [
        (.init("public.utf8-plain-text"), .plainText),
        (.init("public.plain-text"), .plainText),
        (.init("net.daringfireball.markdown"), .markdown),
        (.rtf, .rtf),
        (.html, .html),
    ]

    private let pasteboard: NSPasteboard
    private let maximumTotalByteCount: Int
    private let rtfProjector: MacRTFTextProjector

    init(
        pasteboard: NSPasteboard = .general,
        maximumTotalByteCount: Int = 512 * 1024,
        rtfProjector: MacRTFTextProjector = .init()
    ) {
        self.pasteboard = pasteboard
        self.maximumTotalByteCount = maximumTotalByteCount
        self.rtfProjector = rtfProjector
    }

    func readMetadata() -> MacPasteboardMetadata {
        MacPasteboardMetadata(
            changeCount: pasteboard.changeCount,
            declaredTypeIdentifiers: (pasteboard.types ?? []).map(\.rawValue)
        )
    }

    func readSupportedRepresentations(for changeCount: Int) throws -> [RawTextRepresentation] {
        guard pasteboard.changeCount == changeCount else {
            throw MacPasteboardError.changeCountChanged
        }

        let declaredTypes = Set(pasteboard.types ?? [])
        var totalByteCount = 0
        var representations: [RawTextRepresentation] = []
        for (type, kind) in Self.supportedTypes where declaredTypes.contains(type) {
            guard pasteboard.changeCount == changeCount else {
                throw MacPasteboardError.changeCountChanged
            }
            guard let data = pasteboard.data(forType: type) else {
                throw MacPasteboardError.representationReadFailed
            }
            totalByteCount += data.count
            guard totalByteCount <= maximumTotalByteCount else {
                throw MacPasteboardError.payloadTooLarge
            }

            let projection: String?
            switch kind {
            case .plainText, .markdown:
                guard let decoded = String(data: data, encoding: .utf8) else {
                    throw MacPasteboardError.representationReadFailed
                }
                projection = decoded
            case .rtf:
                do {
                    projection = try rtfProjector.project(data)
                } catch {
                    throw MacPasteboardError.representationReadFailed
                }
            case .html:
                projection = nil
            }
            representations.append(.init(kind: kind, data: data, textProjection: projection))
        }

        guard pasteboard.changeCount == changeCount else {
            throw MacPasteboardError.changeCountChanged
        }
        guard !representations.isEmpty else {
            throw MacPasteboardError.representationReadFailed
        }
        var unique: [RepresentationKind: RawTextRepresentation] = [:]
        for representation in representations {
            if let existing = unique[representation.kind], existing != representation {
                throw MacPasteboardError.conflictingAliases
            }
            unique[representation.kind] = representation
        }
        return RepresentationKind.allCases.compactMap { unique[$0] }
    }

    func writeRepresentations(_ representations: [RawTextRepresentation], marker: String?) throws {
        var unique: [RepresentationKind: RawTextRepresentation] = [:]
        for representation in representations {
            if let existing = unique[representation.kind], existing != representation {
                throw MacPasteboardError.conflictingRepresentations
            }
            unique[representation.kind] = representation
        }
        let item = NSPasteboardItem()
        for kind in RepresentationKind.allCases {
            guard let representation = unique[kind] else { continue }
            guard item.setData(representation.data, forType: pasteboardType(for: kind)) else {
                throw MacPasteboardError.writeFailed
            }
        }
        if let marker, !item.setData(Data(), forType: .init(marker)) {
            throw MacPasteboardError.writeFailed
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw MacPasteboardError.writeFailed
        }
    }

    private func pasteboardType(for kind: RepresentationKind) -> NSPasteboard.PasteboardType {
        switch kind {
        case .plainText: .init("public.utf8-plain-text")
        case .markdown: .init("net.daringfireball.markdown")
        case .rtf: .rtf
        case .html: .html
        }
    }
}
