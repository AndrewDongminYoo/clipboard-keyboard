import ClipboardCore
import Foundation
import XCTest

final class MacSearchPerformanceTests: XCTestCase {
    func testVersionedFiveThousandRecordFixtureReturnsExpectedResultsAndCollectsTiming() async throws {
        let fixture: SearchFixture = try decodeFixture("search-5000.json")
        let queryFixture: QueryFixture = try decodeFixture("search-queries.json")
        XCTAssertEqual(fixture.version, 1)
        XCTAssertEqual(queryFixture.version, 1)
        XCTAssertEqual(fixture.records.count, 5000)

        let index = ClipSearchIndex()
        await index.replace(fixture.records.map(\.document))
        var elapsedMilliseconds: [Double] = []
        for fixtureQuery in queryFixture.queries {
            let start = ContinuousClock.now
            let results = try await index.search(fixtureQuery.query, scope: fixtureQuery.searchScope, limit: 100)
            elapsedMilliseconds.append(Double(start.duration(to: .now).components.attoseconds) / 1_000_000_000_000_000)
            let resultIDs = Set(results.map(\.document.id))
            XCTAssertTrue(Set(fixtureQuery.expectedRecordIDs).isSubset(of: resultIDs), fixtureQuery.name)
            if fixtureQuery.expectedRecordIDs.isEmpty {
                XCTAssertTrue(results.isEmpty, fixtureQuery.name)
            }
        }

        XCTAssertEqual(elapsedMilliseconds.count, queryFixture.queries.count)
        add(XCTAttachment(string: "query-to-first-result-ms=\(elapsedMilliseconds)"))
    }

    private func decodeFixture<T: Decodable>(_ filename: String) throws -> T {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("Packages/ClipboardCore/Tests/ClipboardCoreTests/Fixtures")
            .appendingPathComponent(filename)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }
}

private struct SearchFixture: Decodable {
    let version: Int
    let records: [SearchRecord]
}

private struct SearchRecord: Decodable {
    let id: UUID
    let capturedAt: Date
    let title: String
    let canonicalInsertionString: String
    let category: String?
    let contentKind: String

    var document: ClipSearchDocument {
        ClipSearchDocument(
            id: id,
            capturedAt: capturedAt,
            title: title,
            canonicalInsertionString: canonicalInsertionString,
            category: category.flatMap(ClipCategory.init(rawValue:)),
            contentKind: ContentKind(rawValue: contentKind)!
        )
    }
}

private struct QueryFixture: Decodable {
    let version: Int
    let queries: [SearchQuery]
}

private struct SearchQuery: Decodable {
    let name: String
    let query: String
    let scope: String
    let expectedRecordIDs: [UUID]

    var searchScope: SearchScope {
        get throws {
            try XCTUnwrap(SearchScope(rawValue: scope))
        }
    }
}
