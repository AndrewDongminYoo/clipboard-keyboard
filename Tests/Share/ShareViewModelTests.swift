import ClipboardCore
@testable import ClipboardKeyboardShare
import Foundation
import UIKit
import XCTest

@MainActor
final class ShareViewModelTests: XCTestCase {
    func testRejectsZeroMultipleAndUnsupportedProvidersWithoutLoading() async {
        let writer = ShareWriterSpy()
        let unsupported = ShareProviderFake(types: ["public.jpeg"], data: Data("secret".utf8))
        let first = ShareProviderFake(types: ["public.utf8-plain-text"], data: Data("first".utf8))
        let second = ShareProviderFake(types: ["public.url"], data: Data("https://example.com".utf8))

        let providerCases: [[ShareProviderFake]] = [[], [unsupported], [first, second]]
        for providers in providerCases {
            let model = ShareViewModel(writer: writer)
            await model.open(providers: providers)
            XCTAssertEqual(model.state, .rejected)
        }

        XCTAssertEqual(unsupported.loadCount, 0)
        XCTAssertEqual(first.loadCount, 0)
        XCTAssertEqual(second.loadCount, 0)
    }

    func testRejectsFileURLProviderWithoutLoadingEvenWhenItAlsoAdvertisesURL() async {
        let provider = ShareProviderFake(
            types: ["public.file-url", "public.url"],
            data: Data("file:///private/tmp/private.txt".utf8)
        )
        let model = ShareViewModel(writer: ShareWriterSpy())

        await model.open(providers: [provider])

        XCTAssertEqual(model.state, .rejected)
        XCTAssertEqual(provider.loadCount, 0)
        XCTAssertEqual(model.preview, "")
    }

    func testProviderAdvertisingBothRepresentationsLoadsURLFirstAndKeepsFullBytesForPin() async throws {
        let fullValue = "https://example.com/" + String(repeating: "a", count: 600)
        let provider = ShareProviderFake(
            types: ["public.utf8-plain-text", "public.url"],
            dataByType: ["public.url": Data(fullValue.utf8)]
        )
        let writer = ShareWriterSpy()
        let model = ShareViewModel(writer: writer, previewLimit: 80)

        await model.open(providers: [provider])

        XCTAssertEqual(provider.loadedTypes, ["public.url"])
        XCTAssertEqual(model.state, .ready)
        XCTAssertLessThanOrEqual(model.preview.count, 81)
        XCTAssertFalse(model.preview.contains(String(repeating: "a", count: 100)))

        try await model.pin()

        let written = await writer.writtenItems()
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0].kind, .url)
        XCTAssertEqual(written[0].data, Data(fullValue.utf8))
        XCTAssertEqual(model.completion, .queuedForContainingApp)
        XCTAssertEqual(model.preview, "")
    }

    func testCancelStopsPendingLoadAndPreventsStalePreviewOrWrite() async {
        let provider = ShareProviderFake(types: ["public.utf8-plain-text"], data: Data("private".utf8), suspended: true)
        let writer = ShareWriterSpy()
        let model = ShareViewModel(writer: writer)
        let opening = Task { await model.open(providers: [provider]) }
        await provider.waitUntilLoading()

        model.cancel()
        provider.resume()
        await opening.value

        XCTAssertEqual(model.state, .cancelled)
        XCTAssertEqual(model.preview, "")
        let written = await writer.writtenItems()
        XCTAssertEqual(written.count, 0)
    }

    func testCancelDuringPinCancelsPendingWriterAndCannotShowStaleQueuedCompletion() async throws {
        let barrier = SharePinBarrier(commitBeforeSuspend: false)
        let writer = ShareWriterSpy(barrier: barrier)
        let model = ShareViewModel(writer: writer)
        await model.open(providers: [ShareProviderFake(types: ["public.utf8-plain-text"], data: Data("private".utf8))])
        let pinning = Task { try await model.pin() }
        await barrier.waitUntilEntered()

        model.cancel()
        await barrier.release()

        await XCTAssertThrowsShareCancellation(try await pinning.value)
        XCTAssertEqual(model.state, .cancelled)
        XCTAssertNil(model.completion)
        let committedCount = await barrier.committedCount
        XCTAssertEqual(committedCount, 0)
    }

    func testCancelAfterDurableWriterCommitPreservesCommitWithoutStaleCompletion() async throws {
        let barrier = SharePinBarrier(commitBeforeSuspend: true)
        let writer = ShareWriterSpy(barrier: barrier)
        let model = ShareViewModel(writer: writer)
        await model.open(providers: [ShareProviderFake(types: ["public.utf8-plain-text"], data: Data("private".utf8))])
        let pinning = Task { try await model.pin() }
        await barrier.waitUntilEntered()

        model.cancel()
        await barrier.release()
        try await pinning.value

        let committedCount = await barrier.committedCount
        XCTAssertEqual(committedCount, 1)
        XCTAssertEqual(model.state, .cancelled)
        XCTAssertNil(model.completion)
        XCTAssertEqual(model.preview, "")
    }

    func testExpirationUsesCancellationBoundaryAndPurgesDecodedContent() async {
        let provider = ShareProviderFake(types: ["public.utf8-plain-text"], data: Data("private".utf8), suspended: true)
        let writer = ShareWriterSpy()
        let model = ShareViewModel(writer: writer)
        let opening = Task { await model.open(providers: [provider]) }
        await provider.waitUntilLoading()

        model.expire()
        provider.resume()
        await opening.value

        XCTAssertEqual(model.state, .cancelled)
        XCTAssertEqual(model.preview, "")
        XCTAssertNil(model.completion)
        let written = await writer.writtenItems()
        XCTAssertEqual(written.count, 0)
    }

    func testProtectedDataNotificationCancelsSuspendedLoadAndPurgesContent() async {
        let notificationCenter = NotificationCenter()
        let provider = ShareProviderFake(types: ["public.utf8-plain-text"], data: Data("private".utf8), suspended: true)
        let writer = ShareWriterSpy()
        let model = ShareViewModel(writer: writer)
        let observer = observeShareProtectedDataWillBecomeUnavailable(notificationCenter: notificationCenter) {
            model.protectedDataWillBecomeUnavailable()
        }
        let opening = Task { await model.open(providers: [provider]) }
        await provider.waitUntilLoading()

        notificationCenter.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        provider.resume()
        await opening.value

        withExtendedLifetime(observer) {}
        XCTAssertEqual(model.state, .cancelled)
        XCTAssertEqual(model.preview, "")
        XCTAssertNil(model.completion)
        let written = await writer.writtenItems()
        XCTAssertEqual(written, [])
    }

    func testProtectedDataNotificationCancelsSuspendedWriteWithoutPublishingCompletion() async throws {
        let notificationCenter = NotificationCenter()
        let barrier = SharePinBarrier(commitBeforeSuspend: false)
        let writer = ShareWriterSpy(barrier: barrier)
        let model = ShareViewModel(writer: writer)
        let observer = observeShareProtectedDataWillBecomeUnavailable(notificationCenter: notificationCenter) {
            model.protectedDataWillBecomeUnavailable()
        }
        await model.open(providers: [ShareProviderFake(types: ["public.utf8-plain-text"], data: Data("private".utf8))])
        let pinning = Task { try await model.pin() }
        await barrier.waitUntilEntered()

        notificationCenter.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        await barrier.release()

        await XCTAssertThrowsShareCancellation(try await pinning.value)
        withExtendedLifetime(observer) {}
        XCTAssertEqual(model.state, .cancelled)
        XCTAssertEqual(model.preview, "")
        XCTAssertNil(model.completion)
        let committedCount = await barrier.committedCount
        XCTAssertEqual(committedCount, 0)
    }

    func testWriteFailureKeepsContentFreeRetryStateThenRetryQueuesExactlyOnce() async throws {
        let writer = ShareWriterSpy(failuresRemaining: 1)
        let model = ShareViewModel(writer: writer)
        await model.open(providers: [ShareProviderFake(types: ["public.utf8-plain-text"], data: Data("retryable".utf8))])

        await XCTAssertThrowsShareError(try await model.pin())

        XCTAssertEqual(model.state, .writeFailed)
        XCTAssertEqual(model.preview, "retryable")
        XCTAssertNil(model.completion)
        let failedAttemptCount = await writer.attemptCount()
        let failedWrittenItems = await writer.writtenItems()
        XCTAssertEqual(failedAttemptCount, 1)
        XCTAssertEqual(failedWrittenItems, [])

        try await model.pin()

        let retryAttemptCount = await writer.attemptCount()
        let retryWrittenItems = await writer.writtenItems()
        XCTAssertEqual(retryAttemptCount, 2)
        XCTAssertEqual(retryWrittenItems.count, 1)
        XCTAssertEqual(model.completion, .queuedForContainingApp)
        XCTAssertEqual(model.preview, "")
    }

    func testExplicitCancelFromWriteFailurePurgesRetryDataAndPreventsAnotherWrite() async {
        let writer = ShareWriterSpy(failuresRemaining: 1)
        let model = ShareViewModel(writer: writer)
        await model.open(providers: [ShareProviderFake(types: ["public.utf8-plain-text"], data: Data("retryable".utf8))])
        await XCTAssertThrowsShareError(try await model.pin())

        model.cancel()
        await XCTAssertThrowsShareError(try await model.pin())

        XCTAssertEqual(model.state, .cancelled)
        XCTAssertEqual(model.preview, "")
        XCTAssertNil(model.completion)
        let attemptCount = await writer.attemptCount()
        XCTAssertEqual(attemptCount, 1)
    }

    func testDoublePinWhileWriterIsSuspendedStartsOneWriteAndOneCompletion() async throws {
        let barrier = SharePinBarrier(commitBeforeSuspend: false)
        let writer = ShareWriterSpy(barrier: barrier)
        let model = ShareViewModel(writer: writer)
        await model.open(providers: [ShareProviderFake(types: ["public.utf8-plain-text"], data: Data("private".utf8))])
        let first = Task { try await model.pin() }
        await barrier.waitUntilEntered()

        let second = Task { try await model.pin() }
        try await second.value
        let suspendedAttemptCount = await writer.attemptCount()
        XCTAssertEqual(suspendedAttemptCount, 1)
        await barrier.release()
        try await first.value

        let finalAttemptCount = await writer.attemptCount()
        let writtenItems = await writer.writtenItems()
        XCTAssertEqual(finalAttemptCount, 1)
        XCTAssertEqual(writtenItems.count, 1)
        XCTAssertEqual(model.completion, .queuedForContainingApp)
    }

    func testAllowedPlainTextSemanticObjectsCanonicalizeKoreanAndEmojiToBOMFreeUTF8() async throws {
        let allowedTypes = [
            "public.utf8-plain-text",
            "public.utf16-external-plain-text",
            "public.utf16-plain-text",
            "public.plain-text",
        ]
        for type in allowedTypes {
            let writer = ShareWriterSpy()
            let provider = ShareProviderFake(types: [type], semanticText: "\u{FEFF}한글😀")
            let model = ShareViewModel(writer: writer)

            await model.open(providers: [provider])
            XCTAssertEqual(model.preview, "한글😀")
            try await model.pin()

            let written = await writer.writtenItems()
            XCTAssertEqual(provider.loadedTypes, [type])
            XCTAssertEqual(written.count, 1)
            XCTAssertEqual(written[0].kind, .text)
            XCTAssertEqual(written[0].data, Data("한글😀".utf8))
            XCTAssertFalse(written[0].data.starts(with: [0xEF, 0xBB, 0xBF]))
        }
    }

    func testRichFileImageAndBroadTextTypesAreRejectedBeforeSemanticLoad() async {
        let rejectedTypes = [
            ["public.text"],
            ["public.rtf"],
            ["public.html"],
            ["public.file-url"],
            ["public.jpeg"],
            ["public.file-url", "public.utf8-plain-text"],
            ["public.jpeg", "public.utf8-plain-text"],
        ]
        for types in rejectedTypes {
            let provider = ShareProviderFake(types: types, semanticText: "private")
            let model = ShareViewModel(writer: ShareWriterSpy())

            await model.open(providers: [provider])

            XCTAssertEqual(model.state, .rejected)
            XCTAssertEqual(provider.loadCount, 0)
        }
    }

    func testRichProviderIsAcceptedOnlyThroughItsAllowedPlainSemanticObject() async throws {
        let provider = ShareProviderFake(
            types: ["public.rtf", "public.utf8-plain-text"],
            semanticText: "plain projection"
        )
        let writer = ShareWriterSpy()
        let model = ShareViewModel(writer: writer)

        await model.open(providers: [provider])
        try await model.pin()

        let written = await writer.writtenItems()
        XCTAssertEqual(provider.loadedTypes, ["public.utf8-plain-text"])
        XCTAssertEqual(written.first?.data, Data("plain projection".utf8))
    }

    func testExactURLIsPreferredOverPlainTextAndLoadedOnceAsSemanticURL() async throws {
        let provider = try ShareProviderFake(
            types: ["public.utf8-plain-text", "public.url"],
            semanticText: "fallback",
            semanticURL: XCTUnwrap(URL(string: "https://example.com/a%20b"))
        )
        let writer = ShareWriterSpy()
        let model = ShareViewModel(writer: writer)

        await model.open(providers: [provider])
        try await model.pin()

        let written = await writer.writtenItems()
        XCTAssertEqual(provider.loadedTypes, ["public.url"])
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0].kind, .url)
        XCTAssertEqual(written[0].data, Data("https://example.com/a%20b".utf8))
    }

    func testInvalidSemanticURLFailsWithoutPlainTextFallbackOrWrite() async throws {
        let invalidURLs = try [
            XCTUnwrap(URL(string: "file:///private/tmp/private.txt")),
            XCTUnwrap(URL(string: "ftp://example.com/private")),
            XCTUnwrap(URL(string: "https:///missing-host")),
        ]
        for invalidURL in invalidURLs {
            let provider = ShareProviderFake(
                types: ["public.url", "public.utf8-plain-text"],
                semanticText: "fallback",
                semanticURL: invalidURL
            )
            let writer = ShareWriterSpy()
            let model = ShareViewModel(writer: writer)

            await model.open(providers: [provider])

            let written = await writer.writtenItems()
            XCTAssertEqual(model.state, .failed)
            XCTAssertEqual(provider.loadedTypes, ["public.url"])
            XCTAssertEqual(written, [])
        }
    }

    func testAllowedMetadataWithoutMatchingSemanticObjectFailsBeforeLoad() async throws {
        let providers = try [
            ShareProviderFake(
                types: ["public.utf8-plain-text"],
                semanticText: "private",
                canLoadStringObject: false
            ),
            ShareProviderFake(
                types: ["public.url"],
                semanticText: "",
                semanticURL: XCTUnwrap(URL(string: "https://example.com")),
                canLoadURLObject: false
            ),
        ]
        for provider in providers {
            let model = ShareViewModel(writer: ShareWriterSpy())

            await model.open(providers: [provider])

            XCTAssertEqual(model.state, .failed)
            XCTAssertEqual(provider.loadCount, 0)
        }
    }

    func testSemanticObjectLoadCancellationCancelsProgressAndIgnoresLateCompletion() async {
        let operation = ShareProviderObjectLoadOperation<String>()
        let progress = Progress(totalUnitCount: 1)
        let callbackBox = ShareObjectCallbackBox<String>()
        let loading = Task {
            try await operation.load { callback in
                callbackBox.install(callback)
                return progress
            }
        }
        while !callbackBox.isInstalled {
            await Task.yield()
        }

        loading.cancel()
        await XCTAssertThrowsShareCancellation(try await loading.value)
        callbackBox.complete("late")

        XCTAssertTrue(progress.isCancelled)
    }
}

@MainActor
private final class ShareProviderFake: ShareItemProviding {
    let registeredTypeIdentifiers: [String]
    let canLoadStringObject: Bool
    let canLoadURLObject: Bool
    private let semanticText: String
    private let semanticURL: URL?
    private let suspended: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var loadedTypes: [String] = []

    init(types: [String], data: Data, suspended: Bool = false) {
        registeredTypeIdentifiers = types
        semanticText = String(decoding: data, as: UTF8.self)
        semanticURL = URL(string: semanticText)
        canLoadStringObject = true
        canLoadURLObject = true
        self.suspended = suspended
    }

    init(types: [String], dataByType: [String: Data], suspended: Bool = false) {
        registeredTypeIdentifiers = types
        let preferred = dataByType["public.url"] ?? dataByType.values.first ?? Data()
        semanticText = String(decoding: preferred, as: UTF8.self)
        semanticURL = URL(string: semanticText)
        canLoadStringObject = true
        canLoadURLObject = true
        self.suspended = suspended
    }

    init(
        types: [String],
        semanticText: String,
        semanticURL: URL? = nil,
        suspended: Bool = false,
        canLoadStringObject: Bool = true,
        canLoadURLObject: Bool = true
    ) {
        registeredTypeIdentifiers = types
        self.semanticText = semanticText
        self.semanticURL = semanticURL
        self.suspended = suspended
        self.canLoadStringObject = canLoadStringObject
        self.canLoadURLObject = canLoadURLObject
    }

    var loadCount: Int {
        loadedTypes.count
    }

    func loadStringObject(forTypeIdentifier typeIdentifier: String) async throws -> String {
        loadedTypes.append(typeIdentifier)
        if suspended {
            await withCheckedContinuation { continuation = $0 }
        }
        try Task.checkCancellation()
        return semanticText
    }

    func loadURLObject(forTypeIdentifier typeIdentifier: String) async throws -> URL {
        loadedTypes.append(typeIdentifier)
        if suspended {
            await withCheckedContinuation { continuation = $0 }
        }
        try Task.checkCancellation()
        guard let semanticURL else { throw ShareProviderFakeError.missingURL }
        return semanticURL
    }

    func waitUntilLoading() async {
        while loadedTypes.isEmpty {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private enum ShareProviderFakeError: Error { case missingURL }

private final class ShareObjectCallbackBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Value?, Error?) -> Void)?

    var isInstalled: Bool {
        lock.withLock { callback != nil }
    }

    func install(_ callback: @escaping @Sendable (Value?, Error?) -> Void) {
        lock.withLock { self.callback = callback }
    }

    func complete(_ value: Value) {
        let callback = lock.withLock { self.callback }
        callback?(value, nil)
    }
}

private actor ShareWriterSpy: ShareInboxWriting {
    private(set) var items: [ShareInboxItem] = []
    private let barrier: SharePinBarrier?
    private var failuresRemaining: Int
    private var attempts = 0

    init(barrier: SharePinBarrier? = nil, failuresRemaining: Int = 0) {
        self.barrier = barrier
        self.failuresRemaining = failuresRemaining
    }

    func write(_ item: ShareInboxItem) async throws -> URL {
        attempts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw ShareWriterSpyError.injected
        }
        if let barrier {
            try await barrier.suspend()
        }
        items.append(item)
        return URL(fileURLWithPath: "/share-v1-\(item.id.uuidString.lowercased()).json")
    }

    func writtenItems() -> [ShareInboxItem] {
        items
    }

    func attemptCount() -> Int {
        attempts
    }
}

private enum ShareWriterSpyError: Error { case injected }

private actor SharePinBarrier {
    private let commitBeforeSuspend: Bool
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var committedCount = 0

    init(commitBeforeSuspend: Bool) {
        self.commitBeforeSuspend = commitBeforeSuspend
    }

    func suspend() async throws {
        if commitBeforeSuspend {
            committedCount += 1
        }
        entered = true
        await withCheckedContinuation { continuation = $0 }
        if !commitBeforeSuspend {
            try Task.checkCancellation()
            committedCount += 1
        }
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

@MainActor
private func XCTAssertThrowsShareCancellation<T>(_ expression: @autoclosure () async throws -> T) async {
    do {
        _ = try await expression()
        XCTFail("Expected cancellation")
    } catch {
        XCTAssertTrue(error is CancellationError)
    }
}

@MainActor
private func XCTAssertThrowsShareError<T>(_ expression: @autoclosure () async throws -> T) async {
    do {
        _ = try await expression()
        XCTFail("Expected error")
    } catch {}
}
