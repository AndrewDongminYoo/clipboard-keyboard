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

    func testAcknowledgeRemovesOnlyTheExactSuccessfulMutationIDs() {
        let first = reset(id: uuid(1), generation: 1, modifiedAt: 10, deviceID: "a")
        let second = reset(id: uuid(2), generation: 1, modifiedAt: 20, deviceID: "a")
        let third = reset(id: uuid(3), generation: 1, modifiedAt: 30, deviceID: "a")
        var journal = PendingMutationJournal(pending: [first, second, third])

        journal.acknowledge(mutationIDs: [first.mutationID, third.mutationID])

        XCTAssertEqual(journal.pending, [second])
    }

    func testReplaceForRecoveryRequeuesCurrentNormalizedStateInCanonicalOrder() {
        let reset = LibraryResetGeneration(
            resetID: uuid(10),
            generation: 7,
            modifiedAt: Date(timeIntervalSince1970: 10),
            deviceID: "reset"
        )
        let conflict = revision(
            itemID: uuid(11),
            revisionID: uuid(12),
            generation: 7,
            itemGeneration: 2,
            modifiedAt: 20,
            deviceID: "conflict",
            value: "conflict"
        )
        let primary = revision(
            itemID: conflict.itemID,
            revisionID: uuid(13),
            generation: 7,
            itemGeneration: 2,
            modifiedAt: 30,
            deviceID: "primary",
            value: "primary"
        )
        let acknowledgedPrimary = revision(
            itemID: uuid(14),
            revisionID: uuid(15),
            generation: 7,
            itemGeneration: 1,
            modifiedAt: 40,
            deviceID: "acknowledged",
            value: "acknowledged"
        )
        let tombstone = PinnedTombstone(
            itemID: uuid(16),
            tombstoneID: uuid(17),
            libraryGeneration: 7,
            itemGeneration: 3,
            modifiedAt: Date(timeIntervalSince1970: 50),
            deviceID: "delete"
        )
        let obsolete = revision(
            itemID: uuid(18),
            revisionID: uuid(19),
            generation: 6,
            itemGeneration: 1,
            modifiedAt: 60,
            deviceID: "stale",
            value: "obsolete"
        )
        let state = PinnedReplicaState(
            libraryGeneration: 7,
            reset: reset,
            primaryRevisions: [acknowledgedPrimary, conflict, primary],
            conflictCopies: [PinnedConflictCopy(revision: conflict)],
            tombstones: [tombstone]
        )
        let expected: [PinnedMutation] = [
            .reset(reset),
            .revision(conflict),
            .revision(primary),
            .revision(acknowledgedPrimary),
            .tombstone(tombstone),
        ]
        var journal = PendingMutationJournal(pending: [.revision(obsolete)])

        journal.replaceForRecovery(with: state)

        XCTAssertEqual(journal.pending, expected)
        XCTAssertFalse(journal.pending.contains(.revision(obsolete)))
        XCTAssertTrue(journal.pending.contains(.revision(acknowledgedPrimary)))
        XCTAssertEqual(Set(journal.pending.map(\.mutationID)), Set(expected.map(\.mutationID)))

        journal.replaceForRecovery(with: state)

        XCTAssertEqual(journal.pending, expected)
    }

    func testRecoveryReplaysConflictAsSourceRevisionSoThirdDeviceDeletionWins() {
        let itemID = uuid(21)
        let losing = revision(
            itemID: itemID,
            revisionID: uuid(22),
            generation: 4,
            itemGeneration: 1,
            modifiedAt: 10,
            deviceID: "a",
            value: "losing"
        )
        let primary = revision(
            itemID: itemID,
            revisionID: uuid(23),
            generation: 4,
            itemGeneration: 1,
            modifiedAt: 20,
            deviceID: "b",
            value: "primary"
        )
        var sourceReplica = PinnedReplica()
        _ = sourceReplica.apply(.revision(losing))
        _ = sourceReplica.apply(.revision(primary))
        var journal = PendingMutationJournal()
        journal.replaceForRecovery(with: sourceReplica.state)

        var thirdDevice = PinnedReplica()
        for mutation in journal.pending {
            _ = thirdDevice.apply(mutation)
        }
        let tombstone = PinnedTombstone(
            itemID: itemID,
            tombstoneID: uuid(24),
            libraryGeneration: 4,
            itemGeneration: 2,
            modifiedAt: Date(timeIntervalSince1970: 30),
            deviceID: "c"
        )
        _ = thirdDevice.apply(.tombstone(tombstone))

        XCTAssertEqual(thirdDevice.state.tombstones, [tombstone])
        XCTAssertTrue(thirdDevice.state.primaryRevisions.isEmpty)
        XCTAssertTrue(thirdDevice.state.conflictCopies.isEmpty)
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

    private func revision(
        itemID: UUID,
        revisionID: UUID,
        generation: Int64,
        itemGeneration: Int64,
        modifiedAt: TimeInterval,
        deviceID: String,
        value: String
    ) -> PinnedRevision {
        PinnedRevision(
            itemID: itemID,
            revisionID: revisionID,
            libraryGeneration: generation,
            itemGeneration: itemGeneration,
            modifiedAt: Date(timeIntervalSince1970: modifiedAt),
            deviceID: deviceID,
            payload: PinPayload(
                representations: [
                    ClipRepresentation(
                        kind: .plainText,
                        originalBytes: Data(value.utf8),
                        keyedDigest: Data([1])
                    ),
                ],
                canonicalInsertionString: value,
                title: value,
                contentKind: .plainText,
                category: .everyday
            )
        )
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}
