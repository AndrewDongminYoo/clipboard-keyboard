import ClipboardCore
import Foundation
import XCTest

final class PendingMutationJournalTests: XCTestCase {
    func testEnqueueIsIdempotentAndAcknowledgeRemovesExactMutation() {
        let first = reset(id: uuid(1), generation: 1, modifiedAt: 10, deviceID: "a")
        let second = reset(id: uuid(2), generation: 1, modifiedAt: 20, deviceID: "b")
        var journal = PendingMutationJournal()

        journal.enqueue(first)
        journal.enqueue(second)
        journal.enqueue(first)
        XCTAssertEqual(journal.pending, [first, second])

        journal.acknowledge(mutationID: first.mutationID)
        XCTAssertEqual(journal.pending, [second])
    }

    func testPurgeRemovesOnlyOlderLibraryGenerations() {
        let stale = reset(id: uuid(1), generation: 1, modifiedAt: 10, deviceID: "a")
        let equal = reset(id: uuid(2), generation: 2, modifiedAt: 20, deviceID: "a")
        let newer = reset(id: uuid(3), generation: 3, modifiedAt: 30, deviceID: "a")
        var journal = PendingMutationJournal(pending: [newer, stale, equal])

        journal.purge(staleBeforeLibraryGeneration: 2)

        XCTAssertEqual(journal.pending, [equal, newer])
    }

    func testRetryOrderIsIndependentOfInputOrder() {
        let generationFirst = reset(id: uuid(5), generation: 1, modifiedAt: 50, deviceID: "z")
        let dateFirst = reset(id: uuid(4), generation: 2, modifiedAt: 10, deviceID: "z")
        let deviceFirst = reset(id: uuid(3), generation: 2, modifiedAt: 20, deviceID: "a")
        let identifierFirst = reset(id: uuid(1), generation: 2, modifiedAt: 20, deviceID: "b")
        let identifierSecond = reset(id: uuid(2), generation: 2, modifiedAt: 20, deviceID: "b")
        let expected = [generationFirst, dateFirst, deviceFirst, identifierFirst, identifierSecond]

        let forward = PendingMutationJournal(
            pending: [identifierSecond, deviceFirst, generationFirst, identifierFirst, dateFirst]
        )
        let reverse = PendingMutationJournal(pending: Array(expected.reversed()))

        XCTAssertEqual(forward.pending, expected)
        XCTAssertEqual(reverse.pending, expected)
    }

    func testCodableRoundTripCanonicalizesIdenticalDuplicates() throws {
        let first = reset(id: uuid(1), generation: 1, modifiedAt: 10, deviceID: "a")
        let second = reset(id: uuid(2), generation: 2, modifiedAt: 20, deviceID: "b")
        let data = try JSONEncoder().encode(PendingMutationJournal(pending: [second, first, first]))

        let decoded = try JSONDecoder().decode(PendingMutationJournal.self, from: data)

        XCTAssertEqual(decoded.pending, [first, second])
    }

    func testConflictingDuplicateIdentityCanonicalizesIndependentlyOfInputOrder() {
        let mutationID = uuid(7)
        let first = reset(id: mutationID, generation: 1, modifiedAt: 10, deviceID: "a")
        let conflicting = reset(id: mutationID, generation: 9, modifiedAt: 90, deviceID: "z")

        let forward = PendingMutationJournal(pending: [first, conflicting])
        let reverse = PendingMutationJournal(pending: [conflicting, first])

        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.pending.count, 1)
    }

    private func reset(id: UUID, generation: Int64, modifiedAt: TimeInterval, deviceID: String) -> PinnedMutation {
        .reset(
            LibraryResetGeneration(
                resetID: id,
                generation: generation,
                modifiedAt: Date(timeIntervalSince1970: modifiedAt),
                deviceID: deviceID
            )
        )
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}
