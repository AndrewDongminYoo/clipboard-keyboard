import ClipboardCore
@testable import ClipboardKeyboardiOS
import XCTest

@MainActor
final class ExtractViewModelTests: XCTestCase {
    func testKoreanMessageExposesBoundedCandidateContextAndAvailableVariants() {
        let model = makeModel().model

        model.acceptPastedText("입금 계좌 123-456-789012, 주문번호 998877")

        XCTAssertEqual(model.sourceText, "입금 계좌 123-456-789012, 주문번호 998877")
        XCTAssertEqual(model.candidates.count, 1)
        XCTAssertEqual(model.candidates[0].original, "123-456-789012")
        XCTAssertTrue(model.candidates[0].context.contains("입금 계좌"))
        XCTAssertLessThanOrEqual(model.candidates[0].context.count, 48)
        XCTAssertEqual(model.availableVariants(for: model.candidates[0]), [.original, .digitsOnly, .normalized])
    }

    func testNonemptyPasteWithoutCandidatesStillKeepsAnInMemoryPreviewUntilCancel() {
        let model = makeModel().model

        model.acceptPastedText("일반 메모")

        XCTAssertEqual(model.sourceText, "일반 메모")
        XCTAssertEqual(model.candidates, [])
        model.cancel()
        assertPurged(model)
    }

    func testCopyWritesOnlySelectedVariantWithoutSavingThenPurgesSource() throws {
        let setup = makeModel()
        setup.model.acceptPastedText("입금 계좌 123-456-789012")
        let candidate = try XCTUnwrap(setup.model.candidates.first)

        try setup.model.copyCandidate(candidate, variant: .digitsOnly)

        XCTAssertEqual(setup.writes.values, ["123456789012"])
        XCTAssertEqual(setup.library.payloads, [])
        assertPurged(setup.model)
    }

    func testPinStoresOnlySelectedVariantBytesAndDigestThenPurgesSource() async throws {
        let setup = makeModel()
        setup.model.acceptPastedText("입금 계좌 123-456-789012, 주문번호 998877")
        let candidate = try XCTUnwrap(setup.model.candidates.first)

        try await setup.model.pinCandidate(candidate, variant: .digitsOnly)

        let payload = try XCTUnwrap(setup.library.payloads.first)
        XCTAssertEqual(setup.library.payloads.count, 1)
        XCTAssertEqual(payload.canonicalInsertionString, "123456789012")
        XCTAssertEqual(payload.representations.count, 1)
        XCTAssertEqual(payload.representations[0].kind, .plainText)
        XCTAssertEqual(payload.representations[0].originalBytes, Data("123456789012".utf8))
        XCTAssertEqual(payload.representations[0].keyedDigest, Data("123456789012".utf8).reversedData)
        XCTAssertFalse(payload.canonicalInsertionString.contains("주문번호"))
        assertPurged(setup.model)
    }

    func testEmptyPasteCancelLockAndTeardownLeaveNoContentBearingState() {
        let empty = makeModel()
        empty.model.acceptPastedText("")
        assertPurged(empty.model)
        XCTAssertEqual(empty.library.payloads, [])

        let cancelled = populatedModel()
        cancelled.model.cancel()
        assertPurged(cancelled.model)

        let locked = populatedModel()
        locked.model.protectedDataWillBecomeUnavailable()
        assertPurged(locked.model)

        let tornDown = populatedModel()
        tornDown.model.viewDidDisappear()
        assertPurged(tornDown.model)
    }

    func testFailedCopyKeepsCandidateForRetryButUsesContentFreeError() throws {
        let library = ExtractLibraryFake()
        let model = ExtractViewModel(
            library: library,
            representations: digestRepresentations,
            pasteboardWriter: SystemPasteboardWriter { _ in false }
        )
        model.acceptPastedText("입금 계좌 123-456-789012")
        let candidate = try XCTUnwrap(model.candidates.first)

        XCTAssertThrowsError(try model.copyCandidate(candidate, variant: .original))

        XCTAssertEqual(model.candidates.count, 1)
        XCTAssertEqual(model.errorMessage, "Unable to copy the selected value.")
        XCTAssertFalse(model.errorMessage?.contains("123") == true)
    }

    func testStaleCandidateAfterCancelOrReplacementCannotCopyOrPin() async throws {
        let setup = makeModel()
        setup.model.acceptPastedText("입금 계좌 123-456-789012")
        let staleCandidate = try XCTUnwrap(setup.model.candidates.first)

        setup.model.cancel()
        XCTAssertThrowsError(try setup.model.copyCandidate(staleCandidate, variant: .original))
        try? await setup.model.pinCandidate(staleCandidate, variant: .original)

        setup.model.acceptPastedText("새 계좌 555-666-777777")
        XCTAssertThrowsError(try setup.model.copyCandidate(staleCandidate, variant: .original))
        try? await setup.model.pinCandidate(staleCandidate, variant: .original)

        XCTAssertEqual(setup.writes.values, [])
        XCTAssertEqual(setup.library.payloads, [])
    }

    func testCancelDuringRepresentationGenerationPreventsDurablePin() async throws {
        let barrier = ExtractRepresentationBarrier()
        let library = ExtractLibraryFake()
        let model = ExtractViewModel(
            library: library,
            representations: { value in try await barrier.render(value) },
            pasteboardWriter: SystemPasteboardWriter { _ in true }
        )
        model.acceptPastedText("입금 계좌 123-456-789012")
        let candidate = try XCTUnwrap(model.candidates.first)

        let pin = Task { try? await model.pinCandidate(candidate, variant: .original) }
        await barrier.waitUntilEntered()
        model.cancel()
        await barrier.release()
        await pin.value

        assertPurged(model)
        XCTAssertEqual(library.payloads, [])
    }

    func testProtectedDataLockDuringRepresentationGenerationPreventsDurablePin() async throws {
        let barrier = ExtractRepresentationBarrier()
        let library = ExtractLibraryFake()
        let model = ExtractViewModel(
            library: library,
            representations: { value in try await barrier.render(value) },
            pasteboardWriter: SystemPasteboardWriter { _ in true }
        )
        model.acceptPastedText("입금 계좌 123-456-789012")
        let candidate = try XCTUnwrap(model.candidates.first)

        let pin = Task { try? await model.pinCandidate(candidate, variant: .original) }
        await barrier.waitUntilEntered()
        model.protectedDataWillBecomeUnavailable()
        await barrier.release()
        await pin.value

        assertPurged(model)
        XCTAssertEqual(library.payloads, [])
    }

    private func populatedModel() -> (model: ExtractViewModel, library: ExtractLibraryFake, writes: ExtractWrites) {
        let setup = makeModel()
        setup.model.acceptPastedText("입금 계좌 123-456-789012")
        return setup
    }

    private func makeModel() -> (model: ExtractViewModel, library: ExtractLibraryFake, writes: ExtractWrites) {
        let library = ExtractLibraryFake()
        let writes = ExtractWrites()
        let model = ExtractViewModel(
            library: library,
            representations: digestRepresentations,
            pasteboardWriter: SystemPasteboardWriter { value in
                writes.values.append(value)
                return true
            }
        )
        return (model, library, writes)
    }

    private func assertPurged(_ model: ExtractViewModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(model.sourceText, file: file, line: line)
        XCTAssertEqual(model.candidates, [], file: file, line: line)
        XCTAssertNil(model.selectedCandidate, file: file, line: line)
        XCTAssertNil(model.errorMessage, file: file, line: line)
    }
}

private let digestRepresentations: @Sendable (String) async throws -> [ClipRepresentation] = { text in
    let bytes = Data(text.utf8)
    return [.init(kind: .plainText, originalBytes: bytes, keyedDigest: bytes.reversedData)]
}

private final class ExtractWrites {
    var values: [String] = []
}

private actor ExtractRepresentationBarrier {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func render(_ value: String) async throws -> [ClipRepresentation] {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
        let bytes = Data(value.utf8)
        return [.init(kind: .plainText, originalBytes: bytes, keyedDigest: bytes.reversedData)]
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class ExtractLibraryFake: PinnedLibrary, @unchecked Sendable {
    private(set) var payloads: [PinPayload] = []

    func allItems() async throws -> [PinnedRevision] {
        []
    }

    func search(_: String, limit _: Int) async throws -> [PinnedRevision] {
        []
    }

    func pin(_ payload: PinPayload) async throws -> PinnedRevision {
        payloads.append(payload)
        return PinnedRevision(
            itemID: UUID(), revisionID: UUID(), libraryGeneration: 0, itemGeneration: 1,
            modifiedAt: Date(), deviceID: "extract-test", payload: payload
        )
    }

    func revise(itemID _: UUID, payload _: PinPayload) async throws -> PinnedRevision {
        throw ExtractFakeError.unsupported
    }

    func delete(itemID _: UUID) async throws -> PinnedTombstone {
        throw ExtractFakeError.unsupported
    }

    func applyRemote(_: PinnedMutation) async throws -> MergeOutcome {
        throw ExtractFakeError.unsupported
    }

    func advanceResetGeneration() async throws -> LibraryResetGeneration {
        throw ExtractFakeError.unsupported
    }
}

private enum ExtractFakeError: Error {
    case unsupported
}

private extension Data {
    var reversedData: Data {
        Data(reversed())
    }
}
