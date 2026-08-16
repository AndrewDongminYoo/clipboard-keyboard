import ClipboardCore
@testable import ClipboardKeyboardMac
import CryptoKit
import Foundation
import Security
import XCTest

@MainActor
final class PrivacyBoundaryIntegrationTests: XCTestCase {
    func testOnePasswordMarkerBlocksEverySupportedTextTypeBeforePayloadRead() async {
        for type in CapturePolicy.standard(consentGranted: true, ignoredApplications: []).supportedPrimaryTextTypeIdentifiers {
            let pasteboard = BoundaryPasteboard(
                metadata: .init(changeCount: 1, declaredTypeIdentifiers: [type, "com.agilebits.onepassword"]),
                forbiddenPayloadRead: true
            )
            let coordinator = makeCoordinator(pasteboard: pasteboard, source: stableSource())

            await coordinator.poll()

            XCTAssertEqual(pasteboard.payloadReadCount, 0, type)
        }
    }

    func testIgnoredApplicationAndSourceSwitchRaceFailClosedBeforePayloadRead() async {
        let ignored = identity("com.example.PasswordManager")
        let cases: [(String, SourceObservation)] = [
            ("ignored stable source", .init(identity: ignored, confidence: .inferredStableForeground)),
            ("source switched during observation", .init(identity: nil, confidence: .unknown)),
        ]
        for testCase in cases {
            let pasteboard = BoundaryPasteboard(
                metadata: .init(changeCount: 2, declaredTypeIdentifiers: ["public.utf8-plain-text"]),
                forbiddenPayloadRead: true
            )
            let coordinator = makeCoordinator(
                pasteboard: pasteboard,
                source: testCase.1,
                ignoredApplications: [ignored]
            )

            await coordinator.poll()

            XCTAssertEqual(pasteboard.payloadReadCount, 0, testCase.0)
        }
    }

    func testUnreadableRepresentationPerformsNoDerivationPlaintextWriteOrCommit() async {
        let pasteboard = BoundaryPasteboard(
            metadata: .init(changeCount: 3, declaredTypeIdentifiers: ["public.rtf"]),
            readError: .representationReadFailed
        )
        let coordinator = makeCoordinator(pasteboard: pasteboard, source: stableSource())

        await coordinator.poll()

        XCTAssertEqual(pasteboard.payloadReadCount, 1)
        XCTAssertEqual(pasteboard.plaintextWriteCount, 0)
    }

    func testProgressivelyLargeAuthorizedInputsAreNotSilentlyTruncated() async {
        for byteCount in [1, 4096, 65536] {
            let value = String(repeating: "x", count: byteCount)
            let pasteboard = BoundaryPasteboard(
                metadata: .init(changeCount: byteCount, declaredTypeIdentifiers: ["public.utf8-plain-text"]),
                representations: [.init(kind: .plainText, data: Data(value.utf8), textProjection: value)]
            )
            var committed: ClipEnvelope?
            let coordinator = ClipboardCaptureCoordinator(
                pasteboard: pasteboard,
                sourceTracker: BoundarySourceTracker(observation: stableSource()),
                policy: .standard(consentGranted: true, ignoredApplications: []),
                envelopeBuilder: MacClipEnvelopeBuilder(digestProvider: { Data($0.prefix(32)) }),
                commit: { committed = $0 }
            )

            await coordinator.poll()

            XCTAssertEqual(committed?.canonicalInsertionString.utf8.count, byteCount)
            XCTAssertEqual(committed?.retentionClass, .localHistory)
            XCTAssertEqual(pasteboard.plaintextWriteCount, 0)
        }
    }

    func testResolverPreservesProgressivelyLargeInputsAcrossThe512KiBBoundary() throws {
        for byteCount in [524_287, 524_288, 524_289, 1_048_576] {
            let value = String(repeating: "한", count: byteCount / 3) + String(repeating: "x", count: byteCount % 3)
            let bytes = Data(value.utf8)
            XCTAssertEqual(bytes.count, byteCount)

            let resolved = try RepresentationResolver().resolve([
                .init(kind: .plainText, data: bytes, textProjection: value),
            ])

            XCTAssertEqual(resolved.insertionString.utf8.count, byteCount)
            XCTAssertEqual(resolved.originals.first?.data, bytes)
        }
    }

    func testKeychainDenialFailsBeforeRandomGenerationOrPlaintextFallback() {
        let store = MacKeychainMasterKeyStore(operations: KeychainOperations(
            copyMatching: { _ in (errSecInteractionNotAllowed, nil) },
            add: { _ in
                XCTFail("Forbidden Keychain fallback write")
                return errSecSuccess
            },
            randomBytes: { _ in
                XCTFail("Forbidden key generation after denial")
                return (errSecSuccess, Data())
            }
        ))

        XCTAssertThrowsError(try store.loadOrCreateKey()) { error in
            XCTAssertEqual(error as? PersistenceSecurityError, .keyUnavailable)
        }
    }

    func testCorruptEncryptedRecordAndStoreFailClosedWithoutReturningPlaintext() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = encryptedStore(root: root)
        let envelope = testEnvelope(marker: "corrupt-record-secret")
        try await store.save(envelope)
        let recordURL = root.appendingPathComponent("records/\(envelope.id.uuidString.lowercased()).clip")
        try Data("not ciphertext".utf8).write(to: recordURL)

        do {
            _ = try await store.load(id: envelope.id)
            XCTFail("Expected corrupt encrypted record")
        } catch {
            XCTAssertEqual(error as? PersistenceSecurityError, .corruptRecord)
        }

        try Data("{".utf8).write(to: root.appendingPathComponent("metadata.json"))
        do {
            _ = try await store.listMetadata()
            XCTFail("Expected corrupt encrypted store metadata")
        } catch {
            XCTAssertEqual(error as? PersistenceSecurityError, .corruptRecord)
        }
    }

    func testDiskFullInjectionRejectsCiphertextCommitWithoutPlaintextFallback() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "disk-full-secret"
        let markerData = Data(marker.utf8)
        let store = EncryptedMacClipStore(
            rootURL: root,
            cipher: AESGCMClipCipher(key: SymmetricKey(data: Data(repeating: 8, count: 32))),
            retentionPolicy: .init(maxAge: 3600, maxUnpinnedCount: 10, historyEnabled: true),
            fileOperations: EncryptedStoreFileOperations(
                atomicWrite: { data, _ in
                    XCTAssertNil(data.range(of: markerData), "Forbidden plaintext write")
                    throw CocoaError(.fileWriteOutOfSpace)
                },
                removeItemIfPresent: { _ in }
            )
        )

        do {
            try await store.save(testEnvelope(marker: marker))
            XCTFail("Expected disk-full failure")
        } catch {
            XCTAssertEqual(error as? PersistenceSecurityError, .diskFull)
        }
    }

    func testAuthorizedCapturePersistsOnlyToHistoryAndProducesZeroPinnedCloudWrites() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let historyStore = encryptedStore(root: root.appendingPathComponent("history", isDirectory: true))
        let pinnedStore = EncryptedMacPinnedStore(
            fileURL: root.appendingPathComponent("pinned/pinned-replica.encrypted"),
            key: SymmetricKey(data: Data(repeating: 9, count: 32))
        )
        let pinnedLibrary = LocalMacPinnedLibrary(store: pinnedStore, deviceID: "integration")
        let transport = ForbiddenCloudWriteTransport()
        let engine = MacPinnedSyncEngine(
            makeTransport: { transport },
            pendingMutations: {
                await transport.recordPendingRead()
                return try await pinnedStore.load().pendingJournal.pending
            }
        )

        try await engine.setEnabled(true)
        let readsBeforeCapture = await transport.pendingReadCount
        let marker = "authorized-history-only"
        let pasteboard = BoundaryPasteboard(
            metadata: .init(changeCount: 10, declaredTypeIdentifiers: ["public.utf8-plain-text"]),
            representations: [.init(kind: .plainText, data: Data(marker.utf8), textProjection: marker)]
        )
        let coordinator = ClipboardCaptureCoordinator(
            pasteboard: pasteboard,
            sourceTracker: BoundarySourceTracker(observation: stableSource()),
            policy: .standard(consentGranted: true, ignoredApplications: []),
            envelopeBuilder: MacClipEnvelopeBuilder(
                digestProvider: { Data(SHA256.hash(data: $0)) },
                now: { Date(timeIntervalSince1970: 200) }
            ),
            commit: { try await historyStore.save($0) }
        )

        await coordinator.poll()
        await engine.localJournalDidChange()
        for _ in 0 ..< 1000 {
            if await transport.pendingReadCount > readsBeforeCapture {
                break
            }
            await Task.yield()
        }

        let historyMetadata = try await historyStore.listMetadata()
        let captured: ClipEnvelope?
        if let capturedID = historyMetadata.first?.id {
            captured = try await historyStore.load(id: capturedID)
        } else {
            captured = nil
        }
        let pinnedItems = try await pinnedLibrary.allItems()
        let pinnedState = try await pinnedStore.load()
        let pendingReadCount = await transport.pendingReadCount
        let sendCount = await transport.sendCount
        XCTAssertEqual(historyMetadata.count, 1)
        XCTAssertTrue(historyMetadata.allSatisfy { !$0.isPinned })
        XCTAssertEqual(captured?.canonicalInsertionString, marker)
        XCTAssertEqual(captured?.retentionClass, .localHistory)
        XCTAssertEqual(pinnedItems, [])
        XCTAssertEqual(pinnedState.primaryRevisions, [])
        XCTAssertEqual(pinnedState.conflictCopies, [])
        XCTAssertEqual(pinnedState.tombstones, [])
        XCTAssertEqual(pinnedState.pendingJournal.pending, [])
        XCTAssertGreaterThan(pendingReadCount, readsBeforeCapture)
        XCTAssertEqual(sendCount, 0)
    }

    private func makeCoordinator(
        pasteboard: BoundaryPasteboard,
        source: SourceObservation,
        ignoredApplications: Set<ApplicationIdentity> = []
    ) -> ClipboardCaptureCoordinator {
        ClipboardCaptureCoordinator(
            pasteboard: pasteboard,
            sourceTracker: BoundarySourceTracker(observation: source),
            policy: .standard(consentGranted: true, ignoredApplications: ignoredApplications),
            envelopeBuilder: ForbiddenEnvelopeBuilder(),
            commit: { _ in XCTFail("Forbidden commit") }
        )
    }

    private func stableSource() -> SourceObservation {
        .init(identity: identity("com.example.Editor"), confidence: .inferredStableForeground)
    }

    private func identity(_ bundleIdentifier: String) -> ApplicationIdentity {
        .init(bundleIdentifier: bundleIdentifier, teamIdentifier: "TEAM", signingIdentifier: bundleIdentifier)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func encryptedStore(root: URL) -> EncryptedMacClipStore {
        EncryptedMacClipStore(
            rootURL: root,
            cipher: AESGCMClipCipher(key: SymmetricKey(data: Data(repeating: 7, count: 32))),
            retentionPolicy: .init(maxAge: 3600, maxUnpinnedCount: 10, historyEnabled: true)
        )
    }

    private func testEnvelope(marker: String) -> ClipEnvelope {
        let data = Data(marker.utf8)
        return ClipEnvelope(
            id: UUID(),
            capturedAt: Date(timeIntervalSince1970: 100),
            retentionClass: .localHistory,
            sourceConfidence: .inferredStableForeground,
            representations: [.init(kind: .plainText, originalBytes: data, keyedDigest: Data(repeating: 1, count: 32))],
            canonicalInsertionString: marker,
            title: "Private",
            contentKind: .plainText,
            category: nil,
            preview: marker,
            valueCandidates: []
        )
    }
}

@MainActor
private final class BoundaryPasteboard: MacPasteboardReading {
    let metadata: MacPasteboardMetadata
    let representations: [RawTextRepresentation]
    let readError: MacPasteboardError?
    let forbiddenPayloadRead: Bool
    private(set) var payloadReadCount = 0
    private(set) var plaintextWriteCount = 0

    init(
        metadata: MacPasteboardMetadata,
        representations: [RawTextRepresentation] = [],
        readError: MacPasteboardError? = nil,
        forbiddenPayloadRead: Bool = false
    ) {
        self.metadata = metadata
        self.representations = representations
        self.readError = readError
        self.forbiddenPayloadRead = forbiddenPayloadRead
    }

    func readMetadata() -> MacPasteboardMetadata {
        metadata
    }

    func readSupportedRepresentations(for _: Int) throws -> [RawTextRepresentation] {
        payloadReadCount += 1
        if forbiddenPayloadRead {
            XCTFail("Forbidden payload read")
        }
        if let readError {
            throw readError
        }
        return representations
    }

    func writeRepresentations(_: [RawTextRepresentation], marker _: String?) throws {
        plaintextWriteCount += 1
        XCTFail("Forbidden plaintext write")
    }
}

@MainActor
private final class BoundarySourceTracker: SourceObservationTracking {
    let observation: SourceObservation

    init(observation: SourceObservation) {
        self.observation = observation
    }

    func beginInterval() {}
    func finishInterval() -> SourceObservation {
        observation
    }
}

@MainActor
private final class ForbiddenEnvelopeBuilder: ClipEnvelopeBuilding {
    func makeEnvelope(from _: ResolvedTextContent, sourceConfidence _: SourceConfidence, retentionClass _: RetentionClass) throws -> ClipEnvelope {
        XCTFail("Forbidden payload derivation")
        throw MacPasteboardError.representationReadFailed
    }
}

private actor ForbiddenCloudWriteTransport: MacPinnedSyncTransport {
    private(set) var pendingReadCount = 0
    private(set) var sendCount = 0

    func recordPendingRead() {
        pendingReadCount += 1
    }

    func start(eventHandler _: @escaping @Sendable (MacPinnedSyncEvent) async -> Void) async throws {}
    func fetch() async throws {}
    func send(_: [PinnedMutation]) async throws {
        sendCount += 1
        XCTFail("Forbidden CloudKit write for unpinned local history")
    }

    func cancel() async {}
    func releaseWithoutCancelling() async {}
}
