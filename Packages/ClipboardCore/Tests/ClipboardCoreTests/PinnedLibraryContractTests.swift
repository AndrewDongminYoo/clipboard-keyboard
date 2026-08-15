import ClipboardCore
import Foundation
import XCTest

final class PinnedLibraryContractTests: XCTestCase {
    func testEnvelopeToPayloadPreservesOnlyPinnedBoundaryFields() throws {
        let candidate = ValueCandidate(
            kind: .accountNumber,
            original: "123-456-789012",
            digitsOnly: "123456789012",
            normalized: "123456789012",
            context: "source-secret-message",
            bankName: nil
        )
        let representation = ClipRepresentation(
            kind: .plainText,
            originalBytes: Data("canonical".utf8),
            keyedDigest: Data([9, 8, 7])
        )
        let envelope = ClipEnvelope(
            id: uuid(1),
            capturedAt: Date(timeIntervalSince1970: 100),
            retentionClass: .localHistory,
            sourceConfidence: .inferredStableForeground,
            representations: [representation],
            canonicalInsertionString: "canonical",
            title: "source title",
            contentKind: .plainText,
            category: .prompts,
            preview: "source-secret-preview",
            valueCandidates: [candidate]
        )

        let payload = PinPayload(envelope: envelope, title: "Pinned", category: .everyday)

        XCTAssertEqual(payload.representations, envelope.representations)
        XCTAssertEqual(payload.canonicalInsertionString, envelope.canonicalInsertionString)
        XCTAssertEqual(payload.title, "Pinned")
        XCTAssertEqual(payload.contentKind, envelope.contentKind)
        XCTAssertEqual(payload.category, .everyday)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            Set(["representations", "canonicalInsertionString", "title", "contentKind", "category"])
        )
        XCTAssertNil(object["sourceConfidence"])
        XCTAssertNil(object["preview"])
        XCTAssertNil(object["valueCandidates"])
    }

    func testCandidatePayloadContainsSelectedValueAndNeverSourceMessage() throws {
        let sourceMessage = "source-secret-message"
        let selected = "010-1234-5678"
        let candidate = ValueCandidate(
            kind: .phoneNumber,
            original: selected,
            digitsOnly: "01012345678",
            normalized: "01012345678",
            context: sourceMessage,
            bankName: nil
        )

        let payload = try PinPayload(
            candidate: candidate,
            keyedDigest: Data([1, 3, 3, 7]),
            title: "Phone",
            category: nil
        )
        let encoded = try JSONEncoder().encode(payload)
        let encodedString = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertEqual(payload.canonicalInsertionString, selected)
        XCTAssertEqual(payload.representations.map(\.originalBytes), [Data(selected.utf8)])
        XCTAssertFalse(encodedString.contains(sourceMessage))
        XCTAssertFalse(encodedString.contains("digitsOnly"))
        XCTAssertFalse(encodedString.contains("normalized"))
        XCTAssertFalse(encodedString.contains("context"))
    }

    func testOnlyExplicitPinCreatesSynchronizedRevisionAndDeleteIsContentFree() async throws {
        let sourceMessage = "source-secret-message"
        let selected = "selected-secret-value"
        let candidate = ValueCandidate(
            kind: .oneTimeCode,
            original: selected,
            digitsOnly: "123456",
            normalized: "123456",
            context: sourceMessage,
            bankName: nil
        )
        let payload = try PinPayload(
            candidate: candidate,
            keyedDigest: Data([1]),
            title: "Selected",
            category: nil
        )
        let library = FakePinnedLibrary()

        let beforePin = try await library.allItems()
        XCTAssertTrue(beforePin.isEmpty)
        _ = payload
        let afterPayloadCreation = try await library.allItems()
        XCTAssertTrue(afterPayloadCreation.isEmpty)

        let revision = try await library.pin(payload)
        let afterPin = try await library.allItems()
        XCTAssertEqual(afterPin, [revision])

        let tombstone = try await library.delete(itemID: revision.itemID)
        let encoded = try JSONEncoder().encode(tombstone)
        let encodedString = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(encodedString.contains(selected))
        XCTAssertFalse(encodedString.contains(sourceMessage))
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}

private actor FakePinnedLibrary: PinnedLibrary {
    enum Error: Swift.Error {
        case itemNotFound
    }

    private var revisions: [PinnedRevision] = []
    private var resetGeneration: Int64 = 1

    func allItems() async throws -> [PinnedRevision] {
        revisions
    }

    func search(_ query: String, limit: Int) async throws -> [PinnedRevision] {
        let matches = revisions.filter {
            query.isEmpty
                || $0.payload.title.localizedCaseInsensitiveContains(query)
                || $0.payload.canonicalInsertionString.localizedCaseInsensitiveContains(query)
        }
        return Array(matches.prefix(max(0, limit)))
    }

    func pin(_ payload: PinPayload) async throws -> PinnedRevision {
        let revision = PinnedRevision(
            itemID: UUID(),
            revisionID: UUID(),
            libraryGeneration: resetGeneration,
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(revisions.count + 1)),
            deviceID: "fake-device",
            payload: payload
        )
        revisions.append(revision)
        return revision
    }

    func revise(itemID: UUID, payload: PinPayload) async throws -> PinnedRevision {
        guard let current = revisions.first(where: { $0.itemID == itemID }) else {
            throw Error.itemNotFound
        }
        let revision = PinnedRevision(
            itemID: itemID,
            revisionID: UUID(),
            libraryGeneration: resetGeneration,
            itemGeneration: current.itemGeneration + 1,
            modifiedAt: current.modifiedAt.addingTimeInterval(1),
            deviceID: "fake-device",
            payload: payload
        )
        revisions.removeAll { $0.itemID == itemID }
        revisions.append(revision)
        return revision
    }

    func delete(itemID: UUID) async throws -> PinnedTombstone {
        guard let current = revisions.first(where: { $0.itemID == itemID }) else {
            throw Error.itemNotFound
        }
        revisions.removeAll { $0.itemID == itemID }
        return PinnedTombstone(
            itemID: itemID,
            tombstoneID: UUID(),
            libraryGeneration: resetGeneration,
            itemGeneration: current.itemGeneration + 1,
            modifiedAt: current.modifiedAt.addingTimeInterval(1),
            deviceID: "fake-device"
        )
    }

    func applyRemote(_ mutation: PinnedMutation) async throws -> MergeOutcome {
        switch mutation {
        case let .revision(revision):
            revisions.removeAll { $0.itemID == revision.itemID }
            revisions.append(revision)
            return .updated(revision.itemID)
        case let .tombstone(tombstone):
            revisions.removeAll { $0.itemID == tombstone.itemID }
            return .deleted(tombstone.itemID)
        case let .reset(reset):
            revisions.removeAll()
            resetGeneration = reset.generation
            return .deleted(reset.resetID)
        }
    }

    func advanceResetGeneration() async throws -> LibraryResetGeneration {
        resetGeneration += 1
        revisions.removeAll()
        return LibraryResetGeneration(
            resetID: UUID(),
            generation: resetGeneration,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(resetGeneration)),
            deviceID: "fake-device"
        )
    }
}
