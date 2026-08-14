import ClipboardCore
@testable import ClipboardKeyboardiOS
import Foundation
import XCTest

@MainActor
final class KeyboardSnapshotPublisherTests: XCTestCase {
    func testPublishWritesProtectedValidatedSnapshotAndRereadsFinalDigest() throws {
        let fixture = PublisherFixture()
        defer { fixture.remove() }
        let publisher = fixture.publisher(now: { Date(timeIntervalSince1970: 2000) })

        try publisher.publish(
            items: [revision(2), revision(1)],
            generation: 4,
            lastCloudRefresh: Date(timeIntervalSince1970: 1000)
        )

        let finalData = try Data(contentsOf: fixture.finalURL)
        guard case let .valid(snapshot) = KeyboardSnapshotValidator().validate(finalData) else {
            return XCTFail("Expected a validated final snapshot")
        }
        XCTAssertEqual(snapshot.items.map(\.id), [uuid(1), uuid(2)])
        XCTAssertEqual(snapshot.generation, 4)
        XCTAssertEqual(fixture.operations.protection(at: fixture.finalURL), FileProtectionType.complete)
        XCTAssertGreaterThanOrEqual(fixture.operations.finalReadCount, 1)
        XCTAssertTrue(fixture.operations.protectedBeforeWritten)
        XCTAssertEqual(fixture.temporaryFiles, [])
    }

    func testNondestructiveFailurePreservesPriorValidSnapshotAndRemovesTemporaryFile() throws {
        let fixture = PublisherFixture()
        defer { fixture.remove() }
        let publisher = fixture.publisher()
        try publisher.publish(items: [revision(1)], generation: 1, lastCloudRefresh: nil)
        let priorData = try Data(contentsOf: fixture.finalURL)
        fixture.operations.failure = .replacement

        XCTAssertThrowsError(
            try publisher.publish(items: [revision(2)], generation: 1, lastCloudRefresh: nil)
        )

        XCTAssertEqual(try Data(contentsOf: fixture.finalURL), priorData)
        XCTAssertEqual(fixture.temporaryFiles, [])
    }

    func testReplaceThatMutatesFinalThenThrowsKeepsPriorProtectedFallbackReadable() throws {
        let fixture = PublisherFixture()
        defer { fixture.remove() }
        let publisher = fixture.publisher()
        try publisher.publish(items: [revision(1)], generation: 1, lastCloudRefresh: nil)
        fixture.operations.failure = .replacementAfterMutation

        XCTAssertThrowsError(try publisher.publish(items: [revision(2)], generation: 1, lastCloudRefresh: nil))

        let fallback = try Data(contentsOf: fixture.previousURL)
        guard case let .valid(snapshot) = KeyboardSnapshotValidator().validate(fallback) else {
            return XCTFail("Expected prior fallback snapshot")
        }
        XCTAssertEqual(snapshot.items.map(\.id), [uuid(1)])
        XCTAssertEqual(fixture.operations.protection(at: fixture.previousURL), FileProtectionType.complete)
        XCTAssertEqual(try Data(contentsOf: fixture.previousDigestURL), Data(snapshot.contentDigest.utf8))
        XCTAssertEqual(fixture.operations.protection(at: fixture.previousDigestURL), FileProtectionType.complete)
        XCTAssertEqual(fixture.temporaryFiles, [])

        try Data("partial".utf8).write(to: fixture.finalURL)
        fixture.operations.failure = .write
        XCTAssertThrowsError(try publisher.publish(items: [revision(3)], generation: 1, lastCloudRefresh: nil))
        guard case let .valid(preservedSnapshot) = try KeyboardSnapshotValidator().validate(
            Data(contentsOf: fixture.previousURL)
        ) else {
            return XCTFail("Expected the prior fallback to survive a second failure")
        }
        XCTAssertEqual(preservedSnapshot.items.map(\.id), [uuid(1)])
    }

    func testPostReplaceProtectionFailureKeepsPriorFallback() throws {
        let fixture = PublisherFixture()
        defer { fixture.remove() }
        let publisher = fixture.publisher()
        try publisher.publish(items: [revision(1)], generation: 1, lastCloudRefresh: nil)
        fixture.operations.failure = .finalProtection

        XCTAssertThrowsError(try publisher.publish(items: [revision(2)], generation: 1, lastCloudRefresh: nil))

        let fallback = try Data(contentsOf: fixture.previousURL)
        guard case let .valid(snapshot) = KeyboardSnapshotValidator().validate(fallback) else {
            return XCTFail("Expected prior fallback snapshot")
        }
        XCTAssertEqual(snapshot.items.map(\.id), [uuid(1)])
    }

    func testDestructivePublicationKeepsFenceOnFailureAndRemovesItLastOnSuccess() throws {
        let fixture = PublisherFixture()
        defer { fixture.remove() }
        let publisher = fixture.publisher()
        try publisher.publish(items: [revision(1)], generation: 1, lastCloudRefresh: nil)
        fixture.operations.failure = .replacementAfterMutation
        XCTAssertThrowsError(try publisher.publish(items: [revision(2)], generation: 1, lastCloudRefresh: nil))
        fixture.operations.failure = .none
        try publisher.armRevocationFence()
        fixture.operations.failure = .write

        XCTAssertThrowsError(
            try publisher.completeDestructivePublication(items: [], generation: 2, lastCloudRefresh: nil)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fenceURL.path))

        fixture.operations.failure = .none
        try publisher.completeDestructivePublication(items: [], generation: 2, lastCloudRefresh: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fenceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.previousURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.previousDigestURL.path))
        guard case let .valid(snapshot) = try KeyboardSnapshotValidator().validate(Data(contentsOf: fixture.finalURL)) else {
            return XCTFail("Expected authoritative empty snapshot")
        }
        XCTAssertEqual(snapshot.items, [])
        XCTAssertEqual(
            fixture.operations.removalOrder.suffix(3),
            [fixture.previousURL, fixture.previousDigestURL, fixture.fenceURL]
        )
    }

    func testFenceWriteFailureScrubsContentAndAllowsAuthoritativePublication() throws {
        let fixture = PublisherFixture()
        defer { fixture.remove() }
        let publisher = fixture.publisher()
        try publisher.publish(items: [revision(1)], generation: 1, lastCloudRefresh: nil)
        fixture.operations.failure = .replacementAfterMutation
        XCTAssertThrowsError(try publisher.publish(items: [revision(2)], generation: 1, lastCloudRefresh: nil))
        fixture.operations.failure = .fenceWrite

        try publisher.armRevocationFence()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.previousURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.previousDigestURL.path))
        fixture.operations.failure = .none
        try publisher.completeDestructivePublication(items: [], generation: 2, lastCloudRefresh: nil)
        guard case let .valid(snapshot) = try KeyboardSnapshotValidator().validate(Data(contentsOf: fixture.finalURL)) else {
            return XCTFail("Expected authoritative publication after verified scrub")
        }
        XCTAssertEqual(snapshot.items, [])
    }

    func testFenceWriteFailureWithPartialScrubThrowsAndLeavesContentArtifact() throws {
        let fixture = PublisherFixture()
        defer { fixture.remove() }
        let publisher = fixture.publisher()
        try publisher.publish(items: [revision(1)], generation: 1, lastCloudRefresh: nil)
        fixture.operations.failure = .fenceWriteAndFinalRemoval

        XCTAssertThrowsError(try publisher.armRevocationFence()) { error in
            XCTAssertEqual(error as? KeyboardSnapshotPublisherError, .revocationFenceUnavailable)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.finalURL.path))
    }

    private func revision(_ suffix: Int) -> PinnedRevision {
        PinnedRevision(
            itemID: uuid(suffix),
            revisionID: UUID(),
            libraryGeneration: 1,
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(suffix)),
            deviceID: "test",
            payload: PinPayload(
                representations: [],
                canonicalInsertionString: "Insert \(suffix)",
                title: "Title \(suffix)",
                contentKind: .plainText,
                category: .prompts
            )
        )
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}

@MainActor
private final class PublisherFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let operations = RecordingSnapshotFileOperations()

    var finalURL: URL {
        root.appendingPathComponent("keyboard-snapshot-v1.json")
    }

    var previousURL: URL {
        root.appendingPathComponent("keyboard-snapshot-v1.previous")
    }

    var previousDigestURL: URL {
        root.appendingPathComponent("keyboard-snapshot-v1.previous.digest")
    }

    var fenceURL: URL {
        root.appendingPathComponent("keyboard-snapshot-v1.revoked")
    }

    var temporaryFiles: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.contains(".tmp") } ?? []
    }

    init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func publisher(now: @escaping @Sendable () -> Date = { Date() }) -> KeyboardSnapshotPublisher {
        KeyboardSnapshotPublisher(containerURL: { self.root }, operations: operations.value, now: now)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RecordingSnapshotFileOperations: @unchecked Sendable {
    enum Failure {
        case none
        case write
        case replacement
        case replacementAfterMutation
        case finalProtection
        case fenceWrite
        case fenceWriteAndFinalRemoval
    }

    var failure = Failure.none
    private(set) var finalReadCount = 0
    private(set) var removalOrder: [URL] = []
    private var protections: [URL: FileProtectionType] = [:]
    private var events: [(String, URL)] = []
    private var finalProtectionCount = 0

    var protectedBeforeWritten: Bool {
        guard let writeIndex = events.firstIndex(where: { $0.0 == "write" }) else { return false }
        return events[..<writeIndex].contains { $0.0 == "protect" }
    }

    func protection(at url: URL) -> FileProtectionType? {
        protections[url]
    }

    var value: PhonePinnedFileOperations {
        PhonePinnedFileOperations(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
            createEmpty: { url in
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw SnapshotTestError.injected
                }
            },
            read: { [self] url in
                if url.lastPathComponent == "keyboard-snapshot-v1.json" {
                    finalReadCount += 1
                }
                return try Data(contentsOf: url)
            },
            write: { [self] data, url in
                events.append(("write", url))
                if failure == .write
                    || (failure == .fenceWrite && url.lastPathComponent.hasSuffix("revocation.tmp"))
                    || (failure == .fenceWriteAndFinalRemoval && url.lastPathComponent.hasSuffix("revocation.tmp"))
                {
                    throw SnapshotTestError.injected
                }
                try data.write(to: url)
            },
            setCompleteProtection: { [self] url in
                if url.lastPathComponent == "keyboard-snapshot-v1.json" {
                    finalProtectionCount += 1
                    if failure == .finalProtection, finalProtectionCount > 1 {
                        throw SnapshotTestError.injected
                    }
                }
                events.append(("protect", url))
                protections[url] = .complete
            },
            protection: { [self] url in protections[url] },
            replace: { [self] temporary, final in
                let isFinalSnapshot = final.lastPathComponent == "keyboard-snapshot-v1.json"
                if failure == .replacement, isFinalSnapshot {
                    throw SnapshotTestError.injected
                }
                if FileManager.default.fileExists(atPath: final.path) {
                    try FileManager.default.removeItem(at: final)
                }
                try FileManager.default.moveItem(at: temporary, to: final)
                protections[final] = protections[temporary]
                if failure == .replacementAfterMutation, isFinalSnapshot {
                    throw SnapshotTestError.injected
                }
            },
            removeIfExists: { [self] url in
                if failure == .fenceWriteAndFinalRemoval,
                   url.lastPathComponent == "keyboard-snapshot-v1.json"
                {
                    throw SnapshotTestError.injected
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                    removalOrder.append(url)
                }
            }
        )
    }
}

private enum SnapshotTestError: Error { case injected }
