import ClipboardCore
import Foundation
import XCTest

final class ValueExtractorTests: XCTestCase {
    func testVersionedKoreanPositiveFixturesExtractOnlyTheMatchedValue() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.version, 1)

        for testCase in fixture.positive {
            let candidates = ValueExtractor().candidates(in: testCase.source)
            let candidate = try XCTUnwrap(
                candidates.first { $0.kind == testCase.kind && $0.original == testCase.original },
                testCase.source
            )
            XCTAssertNotEqual(candidate.original, testCase.source)
            XCTAssertLessThanOrEqual(candidate.context.count, 48)
        }
    }

    func testVersionedKoreanNegativeFixturesRejectContextFreeNumbers() throws {
        for testCase in try loadFixture().negative {
            XCTAssertNil(
                ValueExtractor().candidates(in: testCase.source).first { $0.kind == testCase.forbiddenKind },
                testCase.source
            )
        }
    }

    func testAccountCandidateUsesBoundedNearbyContextWithoutInferringABank() throws {
        let source = String(repeating: "머리말", count: 30) + " 입금 계좌 123-456-789012 입니다 " + String(repeating: "꼬리말", count: 30)

        let account = try XCTUnwrap(ValueExtractor().candidates(in: source).first { $0.kind == .accountNumber })

        XCTAssertEqual(account.original, "123-456-789012")
        XCTAssertEqual(account.digitsOnly, "123456789012")
        XCTAssertNil(account.bankName)
        XCTAssertLessThanOrEqual(account.context.count, 48)
        XCTAssertNotEqual(account.context, source)
    }

    private func loadFixture() throws -> ValueFixture {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "korean-value-cases",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(ValueFixture.self, from: Data(contentsOf: url))
    }
}

private struct ValueFixture: Decodable {
    let version: Int
    let positive: [PositiveValueCase]
    let negative: [NegativeValueCase]
}

private struct PositiveValueCase: Decodable {
    let source: String
    let kind: ValueKind
    let original: String
}

private struct NegativeValueCase: Decodable {
    let source: String
    let forbiddenKind: ValueKind
}
