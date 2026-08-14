@testable import ClipboardCore
import Foundation
import XCTest

final class ShareInboxItemTests: XCTestCase {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    private let date = Date(timeIntervalSince1970: 1_723_456_789.125)

    func testTextRoundTripUsesDeterministicEncodingAndValidates() throws {
        let item = try ShareInboxItem.make(id: id, createdAt: date, kind: .text, data: Data("hello \u{1F30D}".utf8))
        let codec = ShareInboxItemCodec()

        let first = try codec.encode(item)
        let second = try codec.encode(item)

        XCTAssertEqual(first, second)
        XCTAssertEqual(ShareInboxItemValidator().validate(first), .valid(item))
    }

    func testHTTPAndHTTPSURLsValidateButOtherOrRelativeURLsFailClosed() throws {
        for value in ["https://example.com/path?q=1", "http://localhost:8080/a"] {
            let item = try ShareInboxItem.make(id: id, createdAt: date, kind: .url, data: Data(value.utf8))
            XCTAssertEqual(try ShareInboxItemValidator().validate(ShareInboxItemCodec().encode(item)), .valid(item))
        }
        for value in ["file:///private/tmp/a", "example.com/path", "mailto:a@example.com"] {
            XCTAssertThrowsError(
                try ShareInboxItem.make(id: id, createdAt: date, kind: .url, data: Data(value.utf8))
            ) { XCTAssertEqual($0 as? ShareInboxItemValidationFailure, .invalidURL) }
        }
    }

    func testMalformedPartialUnknownSchemaInvalidUTF8AndDigestMismatchFailClosed() throws {
        let valid = try ShareInboxItem.make(id: id, createdAt: date, kind: .text, data: Data("hello".utf8))
        let encoded = try ShareInboxItemCodec().encode(valid)
        XCTAssertEqual(ShareInboxItemValidator().validate(Data(encoded.dropLast())), .invalid(.malformed))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 2
        XCTAssertEqual(validate(object), .invalid(.unsupportedSchema))

        object["schemaVersion"] = 1
        object["data"] = Data([0xFF]).base64EncodedString()
        XCTAssertEqual(validate(object), .invalid(.digestMismatch))

        let invalidUTF8 = try ShareInboxItem(
            schemaVersion: 1,
            id: id,
            createdAt: date,
            kind: .text,
            data: Data([0xFF]),
            digest: ShareInboxItem.digest(
                schemaVersion: 1, id: id, createdAt: date, kind: .text, data: Data([0xFF])
            )
        )
        XCTAssertEqual(
            try ShareInboxItemValidator().validate(ShareInboxItemCodec().encode(invalidUTF8)),
            .invalid(.invalidUTF8)
        )

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["digest"] = String(repeating: "0", count: 64)
        XCTAssertEqual(validate(object), .invalid(.digestMismatch))
    }

    func testDigestCoversSchemaIDDateKindAndData() throws {
        let original = try ShareInboxItem.make(id: id, createdAt: date, kind: .text, data: Data("https://example.com".utf8))
        let mutations: [ShareInboxItem] = [
            ShareInboxItem(schemaVersion: 2, id: original.id, createdAt: original.createdAt, kind: original.kind, data: original.data, digest: original.digest),
            ShareInboxItem(schemaVersion: 1, id: UUID(), createdAt: original.createdAt, kind: original.kind, data: original.data, digest: original.digest),
            ShareInboxItem(schemaVersion: 1, id: original.id, createdAt: original.createdAt.addingTimeInterval(1), kind: original.kind, data: original.data, digest: original.digest),
            ShareInboxItem(schemaVersion: 1, id: original.id, createdAt: original.createdAt, kind: .url, data: original.data, digest: original.digest),
            ShareInboxItem(schemaVersion: 1, id: original.id, createdAt: original.createdAt, kind: original.kind, data: Data("changed".utf8), digest: original.digest),
        ]

        let results = try mutations.map { try ShareInboxItemValidator().validate(ShareInboxItemCodec().encode($0)) }
        XCTAssertEqual(results[0], .invalid(.unsupportedSchema))
        XCTAssertTrue(results.dropFirst().allSatisfy { $0 == .invalid(.digestMismatch) })
    }

    private func validate(_ object: [String: Any]) -> ShareInboxItemValidationResult {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return ShareInboxItemValidator().validate(data)
    }
}
