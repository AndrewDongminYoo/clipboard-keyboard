import Foundation

public enum RepresentationResolverError: Error, Equatable {
    case noSupportedRepresentation
    case missingCompleteProjection(RepresentationKind)
    case invalidTextEncoding(RepresentationKind)
    case projectionDoesNotMatchBytes(RepresentationKind)
}

public struct RepresentationResolver: Sendable {
    public init() {}

    public func resolve(_ representations: [RawTextRepresentation]) throws -> ResolvedTextContent {
        guard !representations.isEmpty else {
            throw RepresentationResolverError.noSupportedRepresentation
        }

        var htmlProjections: [Int: String] = [:]
        for (index, representation) in representations.enumerated() where representation.kind == .html {
            do {
                htmlProjections[index] = try HTMLTextProjector().project(representation.data)
            } catch HTMLTextProjectorError.invalidUTF8 {
                throw RepresentationResolverError.invalidTextEncoding(.html)
            }
        }
        for representation in representations where representation.kind == .plainText || representation.kind == .markdown {
            guard let decoded = String(data: representation.data, encoding: .utf8) else {
                throw RepresentationResolverError.invalidTextEncoding(representation.kind)
            }
            guard let projection = representation.textProjection else {
                throw RepresentationResolverError.missingCompleteProjection(representation.kind)
            }
            guard projection == decoded else {
                throw RepresentationResolverError.projectionDoesNotMatchBytes(representation.kind)
            }
        }
        for representation in representations where representation.kind == .rtf {
            guard representation.textProjection != nil else {
                throw RepresentationResolverError.missingCompleteProjection(.rtf)
            }
        }

        for preferredKind in [RepresentationKind.plainText, .markdown, .rtf, .html] {
            guard let index = representations.firstIndex(where: { $0.kind == preferredKind }) else { continue }
            let representation = representations[index]
            let insertionString: String
            switch preferredKind {
            case .plainText, .markdown, .rtf:
                guard let projection = representation.textProjection else {
                    throw RepresentationResolverError.missingCompleteProjection(preferredKind)
                }
                insertionString = projection
            case .html:
                guard let projection = htmlProjections[index] else {
                    throw RepresentationResolverError.invalidTextEncoding(.html)
                }
                insertionString = projection
            }
            return ResolvedTextContent(insertionString: insertionString, originals: representations)
        }

        throw RepresentationResolverError.noSupportedRepresentation
    }
}
