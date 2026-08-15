import ClipboardCore
@testable import ClipboardKeyboardShare
import Foundation
import XCTest

final class ShareInboxWriterTests: XCTestCase {
    func testProtectsEmptyTempBeforePayloadWriteThenPublishesAndRevalidatesFinal() async throws {
        let fixture = ShareWriterFixture()
        let item = try ShareInboxItem.make(
            id: fixture.itemID,
            createdAt: Date(timeIntervalSince1970: 100),
            kind: .text,
            data: Data("full payload".utf8)
        )

        let finalURL = try await fixture.writer.write(item)

        XCTAssertEqual(finalURL.lastPathComponent, "share-v1-00000000-0000-0000-0000-000000000011.json")
        XCTAssertEqual(
            fixture.recorder.events,
            ["mkdir", "empty:tmp", "protect:tmp", "protection:tmp", "write:tmp", "protection:tmp", "read:tmp", "replace", "protect:final", "protection:final", "read:final"]
        )
        XCTAssertEqual(try ShareInboxItemValidator().validate(fixture.operations.read(finalURL)), .valid(item))
    }

    func testFailureBeforePublishRemovesOnlyOwnedTemp() async throws {
        for failEvent in ["protect:tmp", "write:tmp", "replace"] {
            let fixture = ShareWriterFixture(failEvent: failEvent)
            let item = try ShareInboxItem.make(
                id: fixture.itemID,
                createdAt: Date(timeIntervalSince1970: 100),
                kind: .text,
                data: Data("secret".utf8)
            )

            await XCTAssertThrowsShareWriterError(try await fixture.writer.write(item))

            XCTAssertTrue(fixture.recorder.removed.allSatisfy { $0.lastPathComponent.hasSuffix(".tmp") })
            XCTAssertFalse(fixture.recorder.removed.contains { $0.lastPathComponent.hasSuffix(".json") })
        }
    }

    func testFailureAfterPublishRemovesTheNewUnverifiedFinal() async throws {
        for failEvent in ["protect:final", "read:final"] {
            let fixture = ShareWriterFixture(failEvent: failEvent)
            let item = try ShareInboxItem.make(
                id: fixture.itemID,
                createdAt: Date(timeIntervalSince1970: 100),
                kind: .text,
                data: Data("secret".utf8)
            )

            await XCTAssertThrowsShareWriterError(try await fixture.writer.write(item))

            XCTAssertTrue(fixture.recorder.removed.contains { $0.lastPathComponent.hasSuffix(".json") })
            XCTAssertFalse(fixture.recorder.files.keys.contains { $0.pathExtension == "json" })
        }
    }

    func testExistingSameIDFinalIsRejectedWithoutOverwriteOrRemoval() async throws {
        let fixture = ShareWriterFixture()
        let finalURL = URL(fileURLWithPath: "/group/share-inbox/share-v1-00000000-0000-0000-0000-000000000011.json")
        fixture.recorder.files[finalURL] = Data("existing".utf8)
        let item = try ShareInboxItem.make(
            id: fixture.itemID,
            createdAt: Date(timeIntervalSince1970: 100),
            kind: .text,
            data: Data("new".utf8)
        )

        await XCTAssertThrowsShareWriterError(try await fixture.writer.write(item))

        XCTAssertEqual(fixture.recorder.files[finalURL], Data("existing".utf8))
        XCTAssertFalse(fixture.recorder.events.contains("replace"))
        XCTAssertFalse(fixture.recorder.removed.contains(finalURL))
    }

    func testExistingTemporaryCollisionIsNeverOverwrittenOrRemoved() async throws {
        let fixture = ShareWriterFixture()
        let temporaryURL = URL(
            fileURLWithPath: "/group/share-inbox/.share-v1-00000000-0000-0000-0000-000000000011.00000000-0000-0000-0000-000000000099.tmp"
        )
        fixture.recorder.files[temporaryURL] = Data("existing temporary".utf8)
        let item = try ShareInboxItem.make(
            id: fixture.itemID,
            createdAt: Date(timeIntervalSince1970: 100),
            kind: .text,
            data: Data("new".utf8)
        )

        await XCTAssertThrowsShareWriterError(try await fixture.writer.write(item))

        XCTAssertEqual(fixture.recorder.files[temporaryURL], Data("existing temporary".utf8))
        XCTAssertFalse(fixture.recorder.removed.contains(temporaryURL))
    }

    func testCancellationBeforePublishRemovesTempAndPublishesNoFinal() async throws {
        let barrier = ShareWriterBarrier()
        let fixture = ShareWriterFixture(beforePublish: { try await barrier.suspend() })
        let item = try ShareInboxItem.make(
            id: fixture.itemID,
            createdAt: Date(timeIntervalSince1970: 100),
            kind: .text,
            data: Data("secret".utf8)
        )
        let writer = fixture.writer
        let writing = Task { try await writer.write(item) }
        await barrier.waitUntilEntered()

        writing.cancel()
        await barrier.release()
        await XCTAssertThrowsShareWriterCancellation(try await writing.value)

        XCTAssertFalse(fixture.recorder.files.keys.contains { $0.pathExtension == "json" })
        XCTAssertTrue(fixture.recorder.removed.contains { $0.pathExtension == "tmp" })
    }
}

private final class ShareWriterFixture {
    let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    let recorder: ShareFileRecorder
    let operations: ShareInboxFileOperations
    let writer: ShareInboxWriter

    init(
        failEvent: String? = nil,
        beforePublish: @escaping @Sendable () async throws -> Void = {}
    ) {
        recorder = ShareFileRecorder(failEvent: failEvent)
        operations = recorder.operations
        writer = ShareInboxWriter(
            directory: URL(fileURLWithPath: "/group/share-inbox", isDirectory: true),
            operations: operations,
            temporaryID: { UUID(uuidString: "00000000-0000-0000-0000-000000000099")! },
            beforePublish: beforePublish
        )
    }
}

private final class ShareFileRecorder: @unchecked Sendable {
    private let failEvent: String?
    var events: [String] = []
    var files: [URL: Data] = [:]
    var protected: Set<URL> = []
    var removed: [URL] = []

    init(failEvent: String?) {
        self.failEvent = failEvent
    }

    var operations: ShareInboxFileOperations {
        ShareInboxFileOperations(
            fileExists: { [self] url in files[url] != nil },
            createDirectory: { [self] _ in try record("mkdir") },
            createEmpty: { [self] url in try record("empty:tmp"); files[url] = Data() },
            setCompleteProtection: { [self] url in
                let label = url.pathExtension == "tmp" ? "tmp" : "final"
                try record("protect:\(label)")
                protected.insert(url)
            },
            protection: { [self] url in
                let label = url.pathExtension == "tmp" ? "tmp" : "final"
                try record("protection:\(label)")
                return protected.contains(url) ? .complete : nil
            },
            writeAndSync: { [self] data, url in try record("write:tmp"); files[url] = data },
            read: { [self] url in
                let label = url.pathExtension == "tmp" ? "tmp" : "final"
                try record("read:\(label)")
                return files[url] ?? Data()
            },
            replace: { [self] temporary, final in
                try record("replace")
                files[final] = files.removeValue(forKey: temporary)
                if protected.remove(temporary) != nil {
                    protected.insert(final)
                }
            },
            removeIfExists: { [self] url in removed.append(url); files.removeValue(forKey: url) }
        )
    }

    private func record(_ event: String) throws {
        events.append(event)
        if event == failEvent {
            throw ShareWriterTestError.injected
        }
    }
}

private enum ShareWriterTestError: Error { case injected }

private actor ShareWriterBarrier {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async throws {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private func XCTAssertThrowsShareWriterError<T>(_ expression: @autoclosure () async throws -> T) async {
    do {
        _ = try await expression()
        XCTFail("Expected writer error")
    } catch {}
}

private func XCTAssertThrowsShareWriterCancellation<T>(_ expression: @autoclosure () async throws -> T) async {
    do {
        _ = try await expression()
        XCTFail("Expected cancellation")
    } catch {
        XCTAssertTrue(error is CancellationError)
    }
}
