import ClipboardCore
@testable import ClipboardKeyboardShare
import Foundation
import XCTest

@MainActor
final class ShareLifecycleIntegrationTests: XCTestCase {
    func testPartialWriterFailureDoesNotPublishCompletionAndProtectedDataLossPurgesRetryContent() async {
        let writer = AlwaysFailingShareWriter()
        let provider = IntegrationShareProvider(value: "private share payload")
        let model = ShareViewModel(writer: writer)
        await model.open(providers: [provider])

        do {
            try await model.pin()
            XCTFail("Expected injected partial-write failure")
        } catch {}

        XCTAssertEqual(model.state, .writeFailed)
        XCTAssertNil(model.completion)
        model.protectedDataWillBecomeUnavailable()
        XCTAssertEqual(model.state, .cancelled)
        XCTAssertEqual(model.preview, "")
        XCTAssertNil(model.completion)
        let attempts = await writer.attempts
        XCTAssertEqual(attempts, 1)
    }

    func testUnsupportedRepresentationFailsBeforePayloadReadOrInboxWrite() async {
        let writer = AlwaysFailingShareWriter()
        let provider = IntegrationShareProvider(value: "private", identifiers: ["public.image"])
        let model = ShareViewModel(writer: writer)

        await model.open(providers: [provider])

        XCTAssertEqual(model.state, .rejected)
        XCTAssertEqual(provider.readCount, 0)
        let attempts = await writer.attempts
        XCTAssertEqual(attempts, 0)
    }

    func testActualInboxWriterCleansPartialFileBeforeReportingFailure() async throws {
        let directory = URL(fileURLWithPath: "/app-group/share-inbox", isDirectory: true)
        let marker = "partial-file-secret"
        let item = try ShareInboxItem.make(
            id: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000042")),
            createdAt: Date(timeIntervalSince1970: 42),
            kind: .text,
            data: Data(marker.utf8)
        )
        let recorder = PartialWriteFileOperations(plaintextMarker: Data(marker.utf8))
        let writer = ShareInboxWriter(
            directory: directory,
            operations: recorder.operations,
            temporaryID: { UUID(uuidString: "00000000-0000-0000-0000-000000000099")! }
        )

        do {
            _ = try await writer.write(item)
            XCTFail("Expected partial-file write failure")
        } catch {
            XCTAssertEqual(error as? ShareInboxWriterError, .writeFailed)
        }

        XCTAssertEqual(recorder.writeCount, 1)
        XCTAssertEqual(recorder.remainingURLs, [])
        XCTAssertEqual(recorder.removedURLs.count, 1)
        XCTAssertTrue(recorder.removedURLs[0].lastPathComponent.hasSuffix(".tmp"))
        XCTAssertFalse(recorder.removedURLs.contains {
            $0.lastPathComponent == ShareInboxWriter.finalFilename(for: item.id)
        })
    }
}

private final class IntegrationShareProvider: ShareItemProviding {
    let registeredTypeIdentifiers: [String]
    let canLoadStringObject = true
    let canLoadURLObject = false
    let value: String
    private(set) var readCount = 0

    init(value: String, identifiers: [String] = ["public.utf8-plain-text"]) {
        self.value = value
        registeredTypeIdentifiers = identifiers
    }

    func loadStringObject(forTypeIdentifier _: String) async throws -> String {
        readCount += 1
        return value
    }

    func loadURLObject(forTypeIdentifier _: String) async throws -> URL {
        XCTFail("Forbidden URL payload read")
        throw ShareInboxWriterError.invalidItem
    }
}

private actor AlwaysFailingShareWriter: ShareInboxWriting {
    private(set) var attempts = 0

    func write(_: ShareInboxItem) async throws -> URL {
        attempts += 1
        throw ShareInboxWriterError.writeFailed
    }
}

private final class PartialWriteFileOperations: @unchecked Sendable {
    private let lock = NSLock()
    private let plaintextMarker: Data
    private var files: [URL: Data] = [:]
    private var removals: [URL] = []
    private var writes = 0

    init(plaintextMarker: Data) {
        self.plaintextMarker = plaintextMarker
    }

    var operations: ShareInboxFileOperations {
        ShareInboxFileOperations(
            fileExists: { [self] url in lock.withLock { files[url] != nil } },
            createDirectory: { _ in },
            createEmpty: { [self] url in lock.withLock { files[url] = Data() } },
            setCompleteProtection: { _ in },
            protection: { _ in .complete },
            writeAndSync: { [self] data, url in
                XCTAssertNil(data.range(of: plaintextMarker), "Forbidden plaintext write")
                lock.withLock {
                    writes += 1
                    files[url] = data.prefix(17)
                }
                throw CocoaError(.fileWriteOutOfSpace)
            },
            read: { [self] url in lock.withLock { files[url] ?? Data() } },
            replace: { _, _ in XCTFail("Forbidden final inbox publication after partial write") },
            removeIfExists: { [self] url in
                lock.withLock {
                    removals.append(url)
                    files.removeValue(forKey: url)
                }
            }
        )
    }

    var writeCount: Int {
        lock.withLock { writes }
    }

    var remainingURLs: [URL] {
        lock.withLock { Array(files.keys) }
    }

    var removedURLs: [URL] {
        lock.withLock { removals }
    }
}
