#!/usr/bin/env swift

import Foundation

struct FixtureRecord: Codable {
    let id: UUID
    let capturedAt: Date
    let title: String
    let canonicalInsertionString: String
    let category: String?
    let contentKind: String
}

struct SearchFixture: Codable {
    let version: Int
    let seed: UInt64
    let records: [FixtureRecord]
}

struct QueryFixture: Codable {
    let name: String
    let query: String
    let scope: String
    let expectedRecordIDs: [UUID]
}

struct SearchQueryFixture: Codable {
    let version: Int
    let queries: [QueryFixture]
}

struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

let recordCount = 5000
let seed: UInt64 = 0x434C_4950_3530_3030
let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
let categories: [String?] = ["prompts", "code", "everyday", "accounts", nil]
let contentKinds = ["plainText", "markdown", "richText"]
let titles = ["Daily prompt", "Swift code", "한국어 일상", "Unicode café", "Whitespace sample"]
let bodies = [
    "Write a concise release prompt for deterministic testing.",
    "func fixtureValue() -> String {\n    return \"exact indentation\"\n}",
    "오늘 저녁 장보기 목록과 약속 시간을 확인해 주세요.",
    "Unicode café 👩🏽‍💻 é 한글 테스트",
    "alpha    beta\n\n gamma",
]

func deterministicUUID(index: Int) -> UUID {
    let suffix = String(format: "%012llx", UInt64(index + 1))
    return UUID(uuidString: "00000000-0000-5000-8000-\(suffix)")!
}

var generator = SeededGenerator(seed: seed)
var latestIndexByVariant: [Int: Int] = [:]
var records: [FixtureRecord] = []
records.reserveCapacity(recordCount)
for index in 0 ..< recordCount {
    let variant = Int(generator.next() % UInt64(bodies.count))
    let contentKind = contentKinds[Int(generator.next() % UInt64(contentKinds.count))]
    latestIndexByVariant[variant] = index
    records.append(FixtureRecord(
        id: deterministicUUID(index: index),
        capturedAt: baseDate.addingTimeInterval(TimeInterval(index)),
        title: "\(titles[variant]) #\(String(format: "%04d", index))",
        canonicalInsertionString: "\(bodies[variant])\nfixture-record-\(String(format: "%04d", index))",
        category: categories[variant],
        contentKind: contentKind
    ))
}

func latestID(for variant: Int) -> UUID {
    deterministicUUID(index: latestIndexByVariant[variant]!)
}

let queries = SearchQueryFixture(
    version: 1,
    queries: [
        QueryFixture(name: "prompt", query: "release prompt", scope: "all", expectedRecordIDs: [latestID(for: 0)]),
        QueryFixture(name: "code", query: "exact indentation", scope: "content", expectedRecordIDs: [latestID(for: 1)]),
        QueryFixture(name: "korean-everyday", query: "장보기 목록", scope: "content", expectedRecordIDs: [latestID(for: 2)]),
        QueryFixture(name: "unicode", query: "café 👩🏽‍💻", scope: "all", expectedRecordIDs: [latestID(for: 3)]),
        QueryFixture(name: "whitespace", query: "alpha beta gamma", scope: "content", expectedRecordIDs: [latestID(for: 4)]),
        QueryFixture(name: "no-match", query: "fixture-query-with-no-match-7f46", scope: "all", expectedRecordIDs: []),
    ]
)

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

let scriptURL = URL(fileURLWithPath: #filePath)
let repositoryRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let fixtureDirectory = repositoryRoot.appendingPathComponent("Packages/ClipboardCore/Tests/ClipboardCoreTests/Fixtures", isDirectory: true)
try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)

func write<T: Encodable>(_ value: T, named filename: String) throws {
    var data = try encoder.encode(value)
    data.append(0x0A)
    try data.write(to: fixtureDirectory.appendingPathComponent(filename), options: .atomic)
}

try write(SearchFixture(version: 1, seed: seed, records: records), named: "search-5000.json")
try write(queries, named: "search-queries.json")

let formatter = Process()
formatter.executableURL = URL(fileURLWithPath: "/usr/bin/env")
formatter.arguments = [
    "trunk", "fmt",
    fixtureDirectory.appendingPathComponent("search-5000.json").path,
    fixtureDirectory.appendingPathComponent("search-queries.json").path,
]
formatter.currentDirectoryURL = repositoryRoot
try formatter.run()
formatter.waitUntilExit()
guard formatter.terminationStatus == 0 else {
    throw NSError(
        domain: "GenerateSearchFixtures",
        code: Int(formatter.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "Trunk could not format generated fixtures."]
    )
}

print("Generated \(recordCount) records and \(queries.queries.count) versioned queries.")
