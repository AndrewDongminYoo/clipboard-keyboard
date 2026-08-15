import Foundation

public enum TextTransformationError: Error, Equatable {
    case noLosslessSource(CopyFormat)
    case emptyKeyedDigest
}

public struct TextTransformer: Sendable {
    private let digestProvider: @Sendable (Data) throws -> Data

    public init(digestProvider: @escaping @Sendable (Data) throws -> Data) {
        self.digestProvider = digestProvider
    }

    public func render(_ content: ResolvedTextContent, as format: CopyFormat) throws -> [ClipRepresentation] {
        switch format {
        case .originalCompatible:
            return try content.originals.map(makeRepresentation)
        case .plainText:
            return try [makeDerivedPlainText(content.insertionString)]
        case .markdownSource:
            return try [losslessOriginal(in: content, kind: .markdown, format: format)]
        case .html:
            return try [losslessOriginal(in: content, kind: .html, format: format)]
        case .rtf:
            return try [losslessOriginal(in: content, kind: .rtf, format: format)]
        case .digitsOnly:
            let digits = content.insertionString.filter { $0.wholeNumberValue != nil }
            return try [makeDerivedPlainText(digits)]
        case .trimSurroundingWhitespace:
            return try [makeDerivedPlainText(content.insertionString.trimmingCharacters(in: .whitespacesAndNewlines))]
        case .normalizeInternalWhitespace:
            let normalized = content.insertionString
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return try [makeDerivedPlainText(normalized)]
        }
    }

    private func losslessOriginal(
        in content: ResolvedTextContent,
        kind: RepresentationKind,
        format: CopyFormat
    ) throws -> ClipRepresentation {
        guard let original = content.originals.first(where: { $0.kind == kind }) else {
            throw TextTransformationError.noLosslessSource(format)
        }
        return try makeRepresentation(original)
    }

    private func makeRepresentation(_ raw: RawTextRepresentation) throws -> ClipRepresentation {
        try makeRepresentation(kind: raw.kind, bytes: raw.data)
    }

    private func makeDerivedPlainText(_ string: String) throws -> ClipRepresentation {
        try makeRepresentation(kind: .plainText, bytes: Data(string.utf8))
    }

    private func makeRepresentation(kind: RepresentationKind, bytes: Data) throws -> ClipRepresentation {
        let keyedDigest = try digestProvider(bytes)
        guard !keyedDigest.isEmpty else {
            throw TextTransformationError.emptyKeyedDigest
        }
        return ClipRepresentation(kind: kind, originalBytes: bytes, keyedDigest: keyedDigest)
    }
}
