import ClipboardCore
@testable import ClipboardKeyboardiOS
import CryptoKit
import Foundation
import XCTest

@MainActor
final class ProtectedDataIntegrationTests: XCTestCase {
    func testLockedIntentFailsWithoutOpeningLibraryOrWritingPasteboard() async {
        let dependencies = IntentDependencies(
            readiness: { _ in
                XCTFail("Forbidden protected-data library open")
                throw ClipboardIntentError.unavailable
            },
            protectedDataAvailable: false,
            pasteboardWrite: { _ in XCTFail("Forbidden plaintext pasteboard write") }
        )

        do {
            _ = try await dependencies.findPinned(query: "secret", copy: true, select: { _ in
                XCTFail("Forbidden selection")
                throw ClipboardIntentError.selectionCancelled
            })
            XCTFail("Expected locked error")
        } catch {
            XCTAssertEqual(error as? ClipboardIntentError, .unavailable)
        }
    }

    func testRevokedProtectedDataLeaseRejectsSaveBeforeAnySnapshotWrite() async {
        let lease = ProtectedDataLease()
        lease.revoke()
        let operations = PhonePinnedFileOperations(
            fileExists: { _ in false },
            createDirectory: { _ in XCTFail("Forbidden directory mutation") },
            createEmpty: { _ in XCTFail("Forbidden snapshot write") },
            read: { _ in XCTFail("Forbidden plaintext read"); return Data() },
            write: { _, _ in XCTFail("Forbidden snapshot write") },
            setCompleteProtection: { _ in XCTFail("Forbidden protection mutation") },
            protection: { _ in XCTFail("Forbidden protection read"); return nil },
            replace: { _, _ in XCTFail("Forbidden snapshot publication") },
            removeIfExists: { _ in XCTFail("Forbidden cleanup mutation") }
        )
        let store = EncryptedPhonePinnedStore(
            fileURL: URL(fileURLWithPath: "/protected/replica.encrypted"),
            key: SymmetricKey(data: Data(repeating: 7, count: 32)),
            operations: operations,
            lease: lease
        )

        do {
            try await store.save(.init())
            XCTFail("Expected protected-data rejection")
        } catch {
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectedDataUnavailable)
        }
    }

    func testProtectedDataLossPurgesInstalledLibraryFromMemoryBeforeFurtherReads() async throws {
        let publisher = ForbiddenContentSnapshotPublisher()
        let backend = SensitivePinnedLibrary()
        let gate = PhonePinnedLibraryGate(snapshotPublisher: publisher)
        let unlock = gate.beginUnlock()
        XCTAssertTrue(gate.install(backend, for: unlock, generation: 1))

        let visible = try await gate.allItems()
        XCTAssertEqual(visible.map(\.payload.canonicalInsertionString), ["memory-only-secret"])

        gate.lock()

        XCTAssertFalse(unlock.lease.isActive)
        do {
            _ = try await gate.allItems()
            XCTFail("Expected protected-data memory purge")
        } catch {
            XCTAssertEqual(error as? EncryptedPhonePinnedStoreError, .protectedDataUnavailable)
        }
        let readCount = await backend.readCount
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(publisher.armCount, 2)
    }
}

@MainActor
private final class ForbiddenContentSnapshotPublisher: KeyboardSnapshotPublishing {
    private(set) var armCount = 0

    func publish(items _: [PinnedRevision], generation _: Int64, lastCloudRefresh _: Date?) throws {
        XCTFail("Forbidden snapshot content write")
    }

    func armRevocationFence() throws {
        armCount += 1
    }

    func completeDestructivePublication(items _: [PinnedRevision], generation _: Int64, lastCloudRefresh _: Date?) throws {
        XCTFail("Forbidden snapshot content write")
    }

    func clear(generation _: Int64) throws {
        XCTFail("Forbidden snapshot mutation")
    }
}

private actor SensitivePinnedLibrary: PinnedLibrary {
    private(set) var readCount = 0

    func allItems() async throws -> [PinnedRevision] {
        readCount += 1
        return [PinnedRevision(
            itemID: UUID(),
            revisionID: UUID(),
            libraryGeneration: 1,
            itemGeneration: 1,
            modifiedAt: Date(timeIntervalSince1970: 1),
            deviceID: "integration",
            payload: PinPayload(
                representations: [],
                canonicalInsertionString: "memory-only-secret",
                title: "Private",
                contentKind: .plainText,
                category: nil
            )
        )]
    }

    func search(_: String, limit _: Int) async throws -> [PinnedRevision] {
        XCTFail("Forbidden post-lock search")
        return []
    }

    func pin(_: PinPayload) async throws -> PinnedRevision {
        XCTFail("Forbidden mutation")
        throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
    }

    func revise(itemID _: UUID, payload _: PinPayload) async throws -> PinnedRevision {
        XCTFail("Forbidden mutation")
        throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
    }

    func delete(itemID _: UUID) async throws -> PinnedTombstone {
        XCTFail("Forbidden mutation")
        throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
    }

    func applyRemote(_: PinnedMutation) async throws -> MergeOutcome {
        XCTFail("Forbidden CloudKit mutation")
        throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
    }

    func advanceResetGeneration() async throws -> LibraryResetGeneration {
        XCTFail("Forbidden mutation")
        throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
    }
}
