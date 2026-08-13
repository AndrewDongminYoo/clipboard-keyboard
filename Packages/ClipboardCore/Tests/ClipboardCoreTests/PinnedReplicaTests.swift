import ClipboardCore
import Foundation
import XCTest

final class PinnedReplicaTests: XCTestCase {
    func testFirstPinAndHigherItemGenerationEdit() {
        let itemID = uuid(1)
        let first = revision(itemID: itemID, revisionID: uuid(2), itemGeneration: 1, value: "first")
        let edited = revision(itemID: itemID, revisionID: uuid(3), itemGeneration: 2, value: "edited")
        var replica = PinnedReplica()

        XCTAssertEqual(replica.apply(.revision(first)), .inserted(itemID))
        XCTAssertEqual(replica.apply(.revision(edited)), .updated(itemID))
        XCTAssertEqual(replica.state.primaryRevisions, [edited])
        XCTAssertTrue(replica.state.conflictCopies.isEmpty)
    }

    func testConcurrentRevisionsAreOrderIndependentAndPreserveConflictCopy() {
        let itemID = uuid(10)
        let losing = revision(
            itemID: itemID,
            revisionID: uuid(11),
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: 100),
            deviceID: "device-a",
            value: "losing"
        )
        let primary = revision(
            itemID: itemID,
            revisionID: uuid(12),
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: 200),
            deviceID: "device-b",
            value: "primary"
        )

        var forward = PinnedReplica()
        _ = forward.apply(.revision(losing))
        let forwardOutcome = forward.apply(.revision(primary))

        var reverse = PinnedReplica()
        _ = reverse.apply(.revision(primary))
        let reverseOutcome = reverse.apply(.revision(losing))

        let expected = MergeOutcome.conflict(primary: primary.revisionID, copy: losing.revisionID)
        XCTAssertEqual(forwardOutcome, expected)
        XCTAssertEqual(reverseOutcome, expected)
        XCTAssertEqual(forward.state, reverse.state)
        XCTAssertEqual(forward.state.primaryRevisions, [primary])
        XCTAssertEqual(forward.state.conflictCopies, [PinnedConflictCopy(revision: losing)])
    }

    func testNewerRevisionClearsPriorConflictCopies() {
        let itemID = uuid(20)
        let first = revision(itemID: itemID, revisionID: uuid(21), itemGeneration: 1, value: "first")
        let concurrent = revision(
            itemID: itemID,
            revisionID: uuid(22),
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: 200),
            value: "concurrent"
        )
        let newer = revision(itemID: itemID, revisionID: uuid(23), itemGeneration: 2, value: "newer")
        var replica = PinnedReplica()

        _ = replica.apply(.revision(first))
        _ = replica.apply(.revision(concurrent))
        XCTAssertFalse(replica.state.conflictCopies.isEmpty)

        XCTAssertEqual(replica.apply(.revision(newer)), .updated(itemID))
        XCTAssertEqual(replica.state.primaryRevisions, [newer])
        XCTAssertTrue(replica.state.conflictCopies.isEmpty)
    }

    func testTombstoneAtSameOrHigherGenerationWinsAndOlderTombstoneIsIgnored() {
        let itemID = uuid(30)
        let current = revision(itemID: itemID, revisionID: uuid(31), itemGeneration: 2, value: "current")
        let older = tombstone(itemID: itemID, tombstoneID: uuid(32), itemGeneration: 1)
        let equal = tombstone(itemID: itemID, tombstoneID: uuid(33), itemGeneration: 2)
        var replica = PinnedReplica()

        _ = replica.apply(.revision(current))
        XCTAssertEqual(replica.apply(.tombstone(older)), .ignoredStaleGeneration)
        XCTAssertEqual(replica.state.primaryRevisions, [current])

        XCTAssertEqual(replica.apply(.tombstone(equal)), .deleted(itemID))
        XCTAssertTrue(replica.state.primaryRevisions.isEmpty)
        XCTAssertTrue(replica.state.conflictCopies.isEmpty)
        XCTAssertEqual(replica.state.tombstones, [equal])
    }

    func testDuplicateDeliveryIsIdempotent() {
        let value = revision(itemID: uuid(40), revisionID: uuid(41), itemGeneration: 1, value: "value")
        var replica = PinnedReplica()

        _ = replica.apply(.revision(value))

        XCTAssertEqual(replica.apply(.revision(value)), .ignoredDuplicate)
        XCTAssertEqual(replica.state.primaryRevisions, [value])
    }

    func testHigherResetClearsContentAndPriorGenerationMutationStaysStale() {
        let value = revision(
            itemID: uuid(50),
            revisionID: uuid(51),
            libraryGeneration: 1,
            itemGeneration: 1,
            value: "value"
        )
        let reset = LibraryResetGeneration(
            resetID: uuid(52),
            generation: 2,
            modifiedAt: Date(timeIntervalSince1970: 300),
            deviceID: "reset-device"
        )
        var replica = PinnedReplica()

        _ = replica.apply(.revision(value))
        XCTAssertEqual(replica.apply(.reset(reset)), .deleted(reset.resetID))
        XCTAssertEqual(replica.state.libraryGeneration, 2)
        XCTAssertEqual(replica.state.reset, reset)
        XCTAssertTrue(replica.state.primaryRevisions.isEmpty)

        XCTAssertEqual(replica.apply(.revision(value)), .ignoredDuplicate)
        let distinctStale = revision(
            itemID: value.itemID,
            revisionID: uuid(53),
            libraryGeneration: 1,
            itemGeneration: 2,
            value: "stale"
        )
        XCTAssertEqual(replica.apply(.revision(distinctStale)), .ignoredStaleGeneration)
        XCTAssertTrue(replica.state.primaryRevisions.isEmpty)
    }

    func testSameGenerationResetAndRevisionConvergeInEitherDeliveryOrder() {
        let reset = LibraryResetGeneration(
            resetID: uuid(54),
            generation: 2,
            modifiedAt: Date(timeIntervalSince1970: 300),
            deviceID: "reset-device"
        )
        let value = revision(
            itemID: uuid(55),
            revisionID: uuid(56),
            libraryGeneration: 2,
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: 400),
            value: "after-reset"
        )
        var resetFirst = PinnedReplica()
        var revisionFirst = PinnedReplica()

        _ = resetFirst.apply(.reset(reset))
        _ = resetFirst.apply(.revision(value))
        _ = revisionFirst.apply(.revision(value))
        _ = revisionFirst.apply(.reset(reset))

        XCTAssertEqual(resetFirst.state, revisionFirst.state)
        XCTAssertEqual(resetFirst.state.reset, reset)
        XCTAssertEqual(resetFirst.state.primaryRevisions, [value])
    }

    func testSameGenerationResetAndTombstoneConvergeInEitherDeliveryOrder() {
        let reset = LibraryResetGeneration(
            resetID: uuid(57),
            generation: 2,
            modifiedAt: Date(timeIntervalSince1970: 300),
            deviceID: "reset-device"
        )
        let deletion = PinnedTombstone(
            itemID: uuid(58),
            tombstoneID: uuid(59),
            libraryGeneration: 2,
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: 400),
            deviceID: "delete-device"
        )
        var resetFirst = PinnedReplica()
        var tombstoneFirst = PinnedReplica()

        _ = resetFirst.apply(.reset(reset))
        _ = resetFirst.apply(.tombstone(deletion))
        _ = tombstoneFirst.apply(.tombstone(deletion))
        _ = tombstoneFirst.apply(.reset(reset))

        XCTAssertEqual(resetFirst.state, tombstoneFirst.state)
        XCTAssertEqual(resetFirst.state.reset, reset)
        XCTAssertEqual(resetFirst.state.tombstones, [deletion])
    }

    func testCompetingSameGenerationResetsConvergeInEitherDeliveryOrder() {
        let earlier = LibraryResetGeneration(
            resetID: uuid(60),
            generation: 2,
            modifiedAt: Date(timeIntervalSince1970: 300),
            deviceID: "device-a"
        )
        let later = LibraryResetGeneration(
            resetID: uuid(61),
            generation: 2,
            modifiedAt: Date(timeIntervalSince1970: 400),
            deviceID: "device-b"
        )
        var forward = PinnedReplica()
        var reverse = PinnedReplica()

        _ = forward.apply(.reset(earlier))
        _ = forward.apply(.reset(later))
        _ = reverse.apply(.reset(later))
        _ = reverse.apply(.reset(earlier))

        XCTAssertEqual(forward.state, reverse.state)
        XCTAssertEqual(forward.state.reset, later)
    }

    func testDecodingCanonicalizesEquivalentMutationBuiltState() throws {
        let itemID = uuid(63)
        let older = revision(
            itemID: itemID,
            revisionID: uuid(64),
            itemGeneration: 1,
            value: "older"
        )
        let losing = revision(
            itemID: itemID,
            revisionID: uuid(65),
            itemGeneration: 2,
            modifiedAt: Date(timeIntervalSince1970: 200),
            value: "losing"
        )
        let primary = revision(
            itemID: itemID,
            revisionID: uuid(66),
            itemGeneration: 2,
            modifiedAt: Date(timeIntervalSince1970: 300),
            value: "primary"
        )
        let staleDeletion = tombstone(itemID: itemID, tombstoneID: uuid(67), itemGeneration: 1)
        let pendingReset = PinnedMutation.reset(
            LibraryResetGeneration(
                resetID: uuid(68),
                generation: 1,
                modifiedAt: Date(timeIntervalSince1970: 600),
                deviceID: "pending-device"
            )
        )
        let encoded = try JSONEncoder().encode(
            UnnormalizedReplicaState(
                libraryGeneration: 1,
                reset: nil,
                primaryRevisions: [primary, older, losing],
                conflictCopies: [PinnedConflictCopy(revision: losing), PinnedConflictCopy(revision: losing)],
                tombstones: [staleDeletion],
                seenMutationIDs: [
                    primary.revisionID,
                    older.revisionID,
                    losing.revisionID,
                    staleDeletion.tombstoneID,
                    primary.revisionID,
                ],
                pendingJournal: PendingMutationJournal(pending: [pendingReset])
            )
        )

        let decoded = try JSONDecoder().decode(PinnedReplicaState.self, from: encoded)
        var built = PinnedReplica(
            state: PinnedReplicaState(pendingJournal: PendingMutationJournal(pending: [pendingReset]))
        )
        _ = built.apply(.revision(older))
        _ = built.apply(.revision(losing))
        _ = built.apply(.revision(primary))
        _ = built.apply(.tombstone(staleDeletion))

        XCTAssertEqual(decoded, built.state)
        XCTAssertEqual(decoded.primaryRevisions, [primary])
        XCTAssertEqual(decoded.conflictCopies, [PinnedConflictCopy(revision: losing)])
        XCTAssertTrue(decoded.tombstones.isEmpty)
        XCTAssertEqual(decoded.pendingJournal.pending, [pendingReset])
    }

    func testReplicaStateRoundTripIncludesPendingRevisionAndDeletionIntent() throws {
        let value = revision(itemID: uuid(70), revisionID: uuid(71), itemGeneration: 1, value: "pending")
        let deletion = tombstone(itemID: value.itemID, tombstoneID: uuid(72), itemGeneration: 2)
        let state = PinnedReplicaState(
            libraryGeneration: 1,
            pendingJournal: PendingMutationJournal(pending: [.revision(value), .tombstone(deletion)])
        )

        let restored = try JSONDecoder().decode(
            PinnedReplicaState.self,
            from: JSONEncoder().encode(state)
        )

        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored.pendingJournal.pending, [.revision(value), .tombstone(deletion)])
    }

    func testDecodingConflictingDuplicateIdentitiesIsInputOrderIndependent() throws {
        let sharedRevisionID = uuid(73)
        let firstRevision = revision(
            itemID: uuid(74),
            revisionID: sharedRevisionID,
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: 100),
            deviceID: "device-a",
            value: "first"
        )
        let conflictingRevision = revision(
            itemID: firstRevision.itemID,
            revisionID: sharedRevisionID,
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: 200),
            deviceID: "device-b",
            value: "conflicting"
        )
        let sharedTombstoneID = uuid(75)
        let firstTombstone = PinnedTombstone(
            itemID: uuid(76),
            tombstoneID: sharedTombstoneID,
            libraryGeneration: 1,
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: 300),
            deviceID: "device-a"
        )
        let conflictingTombstone = PinnedTombstone(
            itemID: firstTombstone.itemID,
            tombstoneID: sharedTombstoneID,
            libraryGeneration: 1,
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: 400),
            deviceID: "device-b"
        )

        let forward = try decodeState(
            primaryRevisions: [firstRevision, conflictingRevision],
            tombstones: [firstTombstone, conflictingTombstone]
        )
        let reverse = try decodeState(
            primaryRevisions: [conflictingRevision, firstRevision],
            tombstones: [conflictingTombstone, firstTombstone]
        )

        XCTAssertEqual(forward, reverse)
    }

    func testDecodingPurgesPendingMutationsFromOlderLibraryGenerations() throws {
        let stale = PinnedMutation.reset(
            LibraryResetGeneration(
                resetID: uuid(77),
                generation: 1,
                modifiedAt: Date(timeIntervalSince1970: 100),
                deviceID: "stale-device"
            )
        )
        let current = PinnedMutation.reset(
            LibraryResetGeneration(
                resetID: uuid(78),
                generation: 2,
                modifiedAt: Date(timeIntervalSince1970: 200),
                deviceID: "current-device"
            )
        )
        let raw = UnnormalizedReplicaState(
            libraryGeneration: 2,
            reset: nil,
            primaryRevisions: [],
            conflictCopies: [],
            tombstones: [],
            seenMutationIDs: [],
            pendingJournal: PendingMutationJournal(pending: [stale, current])
        )

        let restored = try JSONDecoder().decode(
            PinnedReplicaState.self,
            from: JSONEncoder().encode(raw)
        )

        XCTAssertEqual(restored.pendingJournal.pending, [current])
    }

    func testTombstoneAndResetEncodingAreContentFree() throws {
        let deletion = tombstone(itemID: uuid(60), tombstoneID: uuid(61), itemGeneration: 1)
        let reset = LibraryResetGeneration(
            resetID: uuid(62),
            generation: 2,
            modifiedAt: Date(timeIntervalSince1970: 500),
            deviceID: "reset-device"
        )
        let deletionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(deletion)) as? [String: Any]
        )
        let resetObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(reset)) as? [String: Any]
        )

        XCTAssertEqual(
            Set(deletionObject.keys),
            Set(["itemID", "tombstoneID", "libraryGeneration", "itemGeneration", "modifiedAt", "deviceID"])
        )
        XCTAssertEqual(Set(resetObject.keys), Set(["resetID", "generation", "modifiedAt", "deviceID"]))
    }

    private func revision(
        itemID: UUID,
        revisionID: UUID,
        libraryGeneration: Int64 = 1,
        itemGeneration: Int64,
        modifiedAt: Date = Date(timeIntervalSince1970: 100),
        deviceID: String = "device-a",
        value: String
    ) -> PinnedRevision {
        let bytes = Data(value.utf8)
        return PinnedRevision(
            itemID: itemID,
            revisionID: revisionID,
            libraryGeneration: libraryGeneration,
            itemGeneration: itemGeneration,
            modifiedAt: modifiedAt,
            deviceID: deviceID,
            payload: PinPayload(
                representations: [
                    ClipRepresentation(kind: .plainText, originalBytes: bytes, keyedDigest: Data([1, 2, 3])),
                ],
                canonicalInsertionString: value,
                title: value,
                contentKind: .plainText,
                category: .everyday
            )
        )
    }

    private func tombstone(itemID: UUID, tombstoneID: UUID, itemGeneration: Int64) -> PinnedTombstone {
        PinnedTombstone(
            itemID: itemID,
            tombstoneID: tombstoneID,
            libraryGeneration: 1,
            itemGeneration: itemGeneration,
            modifiedAt: Date(timeIntervalSince1970: 250),
            deviceID: "delete-device"
        )
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    private func decodeState(
        primaryRevisions: [PinnedRevision],
        tombstones: [PinnedTombstone]
    ) throws -> PinnedReplicaState {
        let raw = UnnormalizedReplicaState(
            libraryGeneration: 1,
            reset: nil,
            primaryRevisions: primaryRevisions,
            conflictCopies: [],
            tombstones: tombstones,
            seenMutationIDs: primaryRevisions.map(\.revisionID) + tombstones.map(\.tombstoneID),
            pendingJournal: PendingMutationJournal()
        )
        return try JSONDecoder().decode(PinnedReplicaState.self, from: JSONEncoder().encode(raw))
    }
}

private struct UnnormalizedReplicaState: Codable {
    let libraryGeneration: Int64
    let reset: LibraryResetGeneration?
    let primaryRevisions: [PinnedRevision]
    let conflictCopies: [PinnedConflictCopy]
    let tombstones: [PinnedTombstone]
    let seenMutationIDs: [UUID]
    let pendingJournal: PendingMutationJournal
}
