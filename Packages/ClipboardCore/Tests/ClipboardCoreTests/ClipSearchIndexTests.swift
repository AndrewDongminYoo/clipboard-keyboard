import ClipboardCore
import Foundation
import XCTest

final class ClipSearchIndexTests: XCTestCase {
    func testSearchMatchesTitleCanonicalCategoryCodeSymbolsAndUnicodeWithoutMutatingOriginals() async {
        let index = ClipSearchIndex()
        let documents = [
            document(id: 1, title: "배포 메모", content: "let value = foo?.bar ?? \"기본값\"", category: .code),
            document(id: 2, title: "일상", content: "서울 카페", category: .everyday),
        ]
        await index.replace(documents)

        let title = await index.search("배포", scope: .title, limit: 10)
        let symbols = await index.search("foo?.bar ??", scope: .content, limit: 10)
        let unicode = await index.search("기본값", scope: .all, limit: 10)
        let category = await index.search("code", scope: .category, limit: 10)

        XCTAssertEqual(title.map(\.document.id), [documents[0].id])
        XCTAssertEqual(symbols.map(\.document.id), [documents[0].id])
        XCTAssertEqual(unicode.map(\.document.id), [documents[0].id])
        XCTAssertEqual(category.map(\.document.id), [documents[0].id])
        XCTAssertEqual(symbols.first?.document.canonicalInsertionString, "let value = foo?.bar ?? \"기본값\"")
    }

    func testSearchNormalizesCaseAndWhitespaceForMatchingOnly() async {
        let index = ClipSearchIndex()
        let original = document(id: 3, title: "API Note", content: "Alpha\t Beta\r\nGamma", category: nil)
        await index.replace([original])

        let results = await index.search("alpha beta gamma", scope: .content, limit: 10)

        XCTAssertEqual(results.map(\.document.id), [original.id])
        XCTAssertEqual(results.first?.document.canonicalInsertionString, original.canonicalInsertionString)
    }

    func testSearchUsesStableRecencyOrderingAndHonorsScopeAndHardLimit() async {
        let index = ClipSearchIndex()
        let older = document(id: 9, capturedAt: 10, title: "needle", content: "none", category: nil)
        let lowerTie = document(id: 4, capturedAt: 20, title: "needle", content: "none", category: nil)
        let higherTie = document(id: 5, capturedAt: 20, title: "needle", content: "none", category: nil)
        let contentOnly = document(id: 6, capturedAt: 30, title: "other", content: "needle", category: nil)
        await index.replace([older, higherTie, contentOnly, lowerTie])

        let titleResults = await index.search("needle", scope: .title, limit: 2)
        let zeroResults = await index.search("needle", scope: .all, limit: 0)

        XCTAssertEqual(titleResults.map(\.document.id), [lowerTie.id, higherTie.id])
        XCTAssertTrue(zeroResults.isEmpty)

        let many = (100 ... 250).map { document(id: $0, capturedAt: TimeInterval($0), title: "all", content: "", category: nil) }
        await index.replace(many)
        let limitedResults = await index.search("all", scope: .all, limit: 500)
        XCTAssertEqual(limitedResults.count, 100)
    }

    func testRemoveAndPurgeUpdateOnlyActorMemory() async {
        let index = ClipSearchIndex()
        let first = document(id: 7, title: "first", content: "shared", category: nil)
        let second = document(id: 8, title: "second", content: "shared", category: nil)
        await index.replace([first, second])

        await index.remove(ids: [first.id])
        let afterRemoval = await index.search("shared", scope: .all, limit: 10)
        XCTAssertEqual(afterRemoval.map(\.document.id), [second.id])

        await index.purge()
        let afterPurge = await index.search("shared", scope: .all, limit: 10)
        XCTAssertTrue(afterPurge.isEmpty)
    }

    private func document(
        id: Int,
        capturedAt: TimeInterval = 100,
        title: String,
        content: String,
        category: ClipCategory?
    ) -> ClipSearchDocument {
        ClipSearchDocument(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            capturedAt: Date(timeIntervalSince1970: capturedAt),
            title: title,
            canonicalInsertionString: content,
            category: category,
            contentKind: category == .code ? .code : .plainText
        )
    }
}
