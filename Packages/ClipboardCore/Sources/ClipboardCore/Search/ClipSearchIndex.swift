import Foundation

public enum SearchScope: String, Codable, CaseIterable, Sendable {
    case all
    case title
    case content
    case category
}

public struct ClipSearchDocument: Codable, Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let title: String
    public let canonicalInsertionString: String
    public let category: ClipCategory?
    public let contentKind: ContentKind

    public init(
        id: UUID,
        capturedAt: Date,
        title: String,
        canonicalInsertionString: String,
        category: ClipCategory?,
        contentKind: ContentKind
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.title = title
        self.canonicalInsertionString = canonicalInsertionString
        self.category = category
        self.contentKind = contentKind
    }
}

public struct ClipSearchResult: Equatable, Sendable {
    public let document: ClipSearchDocument

    public init(document: ClipSearchDocument) {
        self.document = document
    }
}

public actor ClipSearchIndex {
    private static let maximumResultCount = 100
    private var documents: [UUID: ClipSearchDocument] = [:]

    public init() {}

    public func replace(_ documents: [ClipSearchDocument]) {
        self.documents = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
    }

    public func remove(ids: Set<UUID>) {
        for id in ids {
            documents.removeValue(forKey: id)
        }
    }

    public func search(_ query: String, scope: SearchScope, limit: Int) -> [ClipSearchResult] {
        let effectiveLimit = min(max(limit, 0), Self.maximumResultCount)
        guard effectiveLimit > 0 else { return [] }
        let normalizedQuery = normalize(query)

        return documents.values
            .filter { document in
                let searchableValues: [String] = switch scope {
                case .all:
                    [document.title, document.canonicalInsertionString, document.category?.rawValue ?? "", document.contentKind.rawValue]
                case .title:
                    [document.title]
                case .content:
                    [document.canonicalInsertionString]
                case .category:
                    [document.category?.rawValue ?? ""]
                }
                return normalizedQuery.isEmpty || searchableValues.contains { normalize($0).contains(normalizedQuery) }
            }
            .sorted {
                if $0.capturedAt == $1.capturedAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.capturedAt > $1.capturedAt
            }
            .prefix(effectiveLimit)
            .map(ClipSearchResult.init)
    }

    public func purge() {
        documents.removeAll(keepingCapacity: false)
    }

    private func normalize(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
