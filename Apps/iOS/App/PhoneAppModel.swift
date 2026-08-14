import ClipboardCore
import Combine
import Foundation
import UIKit

struct PhoneUnlockContext: Sendable {
    let epoch: UInt64
    let lease: ProtectedDataLease
}

@MainActor
func observePhoneProtectedDataWillBecomeUnavailable(
    notificationCenter: NotificationCenter = .default,
    handler: @escaping @MainActor () -> Void
) -> AnyCancellable {
    notificationCenter.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)
        .sink { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
}

@MainActor
final class PhonePinnedLibraryGate: PinnedLibrary, ShareInboxPinning {
    var localMutationCommitted: (@MainActor @Sendable () async -> Void)?
    var preDestructivePurge: (@MainActor @Sendable () throws -> Void)?
    private typealias Session = (backend: any PinnedLibrary, epoch: UInt64, lease: ProtectedDataLease)

    private let snapshotPublisher: any KeyboardSnapshotPublishing
    private let now: @Sendable () -> Date
    private let snapshotOperationSerializer = AsyncOperationSerializer()
    private var backend: (any PinnedLibrary)?
    private var textTransformer: TextTransformer?
    private var pendingLease: ProtectedDataLease?
    private var installedLease: ProtectedDataLease?
    private var lifecycleEpoch: UInt64 = 0
    private var snapshotGeneration: Int64 = 0
    private var lastSuccessfulCloudRefresh: Date?
    private(set) var snapshotSafetyFailure = false
    private(set) var snapshotOperationRequestCount = 0
    private var snapshotSafetyArmed = false
    private var snapshotSafetyReady = false

    init(
        snapshotPublisher: (any KeyboardSnapshotPublishing)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.snapshotPublisher = snapshotPublisher ?? NoopKeyboardSnapshotPublisher()
        self.now = now
    }

    func beginUnlock() -> PhoneUnlockContext {
        armSnapshotRevocationFence()
        pendingLease?.revoke()
        installedLease?.revoke()
        lifecycleEpoch &+= 1
        backend = nil
        textTransformer = nil
        installedLease = nil
        snapshotSafetyReady = false
        let lease = ProtectedDataLease()
        pendingLease = lease
        return PhoneUnlockContext(epoch: lifecycleEpoch, lease: lease)
    }

    @discardableResult
    func install(
        _ backend: any PinnedLibrary,
        textTransformer: TextTransformer? = nil,
        for unlock: PhoneUnlockContext,
        generation: Int64 = 0,
        snapshotSafetyInitialized: Bool = true
    ) -> Bool {
        guard unlock.epoch == lifecycleEpoch,
              pendingLease === unlock.lease,
              unlock.lease.isActive,
              snapshotSafetyArmed
        else {
            unlock.lease.revoke()
            return false
        }
        self.backend = backend
        self.textTransformer = textTransformer
        pendingLease = nil
        installedLease = unlock.lease
        snapshotGeneration = generation
        snapshotSafetyReady = snapshotSafetyInitialized
        return true
    }

    func initializeKeyboardSnapshotSafety() async throws {
        guard let backend, let installedLease, installedLease.isActive, snapshotSafetyArmed else {
            throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
        }
        let epoch = lifecycleEpoch
        let items = try await backend.allItems()
        try validateInstalled(epoch, lease: installedLease)
        do {
            try snapshotPublisher.completeDestructivePublication(
                items: items,
                generation: snapshotGeneration,
                lastCloudRefresh: lastSuccessfulCloudRefresh
            )
        } catch {
            snapshotSafetyFailure = true
            snapshotSafetyReady = false
            throw error
        }
        try validateInstalled(epoch, lease: installedLease)
        snapshotSafetyArmed = false
        snapshotSafetyFailure = false
        snapshotSafetyReady = true
    }

    @discardableResult
    func failUnlock(_ unlock: PhoneUnlockContext) -> Bool {
        guard unlock.epoch == lifecycleEpoch,
              pendingLease === unlock.lease
        else {
            unlock.lease.revoke()
            return false
        }
        unlock.lease.revoke()
        armSnapshotRevocationFence()
        lifecycleEpoch &+= 1
        backend = nil
        textTransformer = nil
        pendingLease = nil
        installedLease = nil
        snapshotSafetyReady = false
        return true
    }

    @discardableResult
    func failInstalledUnlock(_ unlock: PhoneUnlockContext) -> Bool {
        guard unlock.epoch == lifecycleEpoch,
              installedLease === unlock.lease
        else {
            unlock.lease.revoke()
            return false
        }
        lock()
        return true
    }

    func lock() {
        armSnapshotRevocationFence()
        pendingLease?.revoke()
        installedLease?.revoke()
        lifecycleEpoch &+= 1
        backend = nil
        textTransformer = nil
        pendingLease = nil
        installedLease = nil
        snapshotSafetyReady = false
    }

    func representations(for text: String) throws -> [ClipRepresentation] {
        guard let textTransformer, installedLease?.isActive == true, snapshotSafetyReady else {
            throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
        }
        let content = ResolvedTextContent(
            insertionString: text,
            originals: [
                RawTextRepresentation(kind: .plainText, data: Data(text.utf8), textProjection: text),
            ]
        )
        return try textTransformer.render(content, as: .plainText)
    }

    func representations(for raw: RawTextRepresentation) throws -> [ClipRepresentation] {
        guard let textTransformer, installedLease?.isActive == true, snapshotSafetyReady else {
            throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
        }
        let resolved = try RepresentationResolver().resolve([raw])
        return try textTransformer.render(resolved, as: .originalCompatible)
    }

    func allItems() async throws -> [PinnedRevision] {
        let (backend, epoch, lease) = try currentBackend()
        let result = try await backend.allItems()
        try validate(epoch, lease: lease)
        return result
    }

    func search(_ query: String, limit: Int) async throws -> [PinnedRevision] {
        let (backend, epoch, lease) = try currentBackend()
        let result = try await backend.search(query, limit: limit)
        try validate(epoch, lease: lease)
        return result
    }

    func pin(_ payload: PinPayload) async throws -> PinnedRevision {
        let session = try currentBackend()
        let result = try await withSerializedSnapshotOperation(session) { session in
            let (backend, epoch, lease) = session
            let result = try await backend.pin(payload)
            try validate(epoch, lease: lease)
            snapshotGeneration = result.libraryGeneration
            try? await refreshKeyboardSnapshotLocked(session)
            return result
        }
        await localMutationCommitted?()
        return result
    }

    func pinForIntent(_ payload: PinPayload) async throws -> IntentPinCommit {
        let session = try currentBackend()
        let result = try await withSerializedSnapshotOperation(session) { session in
            let (backend, epoch, lease) = session
            guard let intentBackend = backend as? any IntentPinCommittingLibrary else {
                throw LocalPinnedLibraryError.itemNotFound
            }
            let result = try await intentBackend.pinForIntent(payload)
            if isInstalledCurrent(epoch, lease: lease) {
                snapshotGeneration = result.libraryGeneration
                try? await refreshKeyboardSnapshotLocked(session)
            }
            return result
        }
        await localMutationCommitted?()
        return result
    }

    func ensurePinnedShareItem(_ item: ShareInboxItem) async throws -> SharePinEnsureResult {
        let encoded = try ShareInboxItemCodec().encode(item)
        guard ShareInboxItemValidator().validate(encoded) == .valid(item) else {
            throw ShareInboxItemValidationFailure.malformed
        }
        guard let text = String(data: item.data, encoding: .utf8) else {
            throw ShareInboxItemValidationFailure.invalidUTF8
        }
        let raw = RawTextRepresentation(kind: .plainText, data: item.data, textProjection: text)
        let payload = try PinPayload(
            representations: representations(for: raw),
            canonicalInsertionString: text,
            title: item.kind == .url ? "Shared URL" : "Shared Text",
            contentKind: .plainText,
            category: nil
        )
        let session = try currentBackend()
        let result = try await withSerializedSnapshotOperation(session) { session in
            let (backend, epoch, lease) = session
            guard let fixedIDBackend = backend as? any ShareFixedIDPinnedLibrary else {
                throw LocalPinnedLibraryError.itemNotFound
            }
            let result = try await fixedIDBackend.ensurePinned(payload: payload, itemID: item.id)
            try validate(epoch, lease: lease)
            if case let .inserted(revision) = result {
                snapshotGeneration = revision.libraryGeneration
                try? await refreshKeyboardSnapshotLocked(session)
            }
            return result
        }
        if case .inserted = result {
            await localMutationCommitted?()
        }
        return result
    }

    func revise(itemID: UUID, payload: PinPayload) async throws -> PinnedRevision {
        let session = try currentBackend()
        let result = try await withSerializedSnapshotOperation(session) { session in
            let (backend, epoch, lease) = session
            let result = try await backend.revise(itemID: itemID, payload: payload)
            try validate(epoch, lease: lease)
            snapshotGeneration = result.libraryGeneration
            try? await refreshKeyboardSnapshotLocked(session)
            return result
        }
        await localMutationCommitted?()
        return result
    }

    func delete(itemID: UUID) async throws -> PinnedTombstone {
        let session = try currentBackend()
        let result = try await withSerializedSnapshotOperation(session) { session in
            let (backend, epoch, lease) = session
            try purgeBeforeDestructiveMutation()
            try armFenceForDestructiveMutation()
            let result: PinnedTombstone
            do {
                result = try await backend.delete(itemID: itemID)
            } catch {
                snapshotSafetyFailure = true
                throw contentFreeDestructiveError(error)
            }
            try validateInstalled(epoch, lease: lease)
            snapshotGeneration = result.libraryGeneration
            do {
                try await completeDestructiveSnapshotLocked(backend: backend, epoch: epoch, lease: lease)
            } catch {
                snapshotSafetyFailure = true
                snapshotSafetyReady = false
                throw contentFreeDestructiveError(error)
            }
            return result
        }
        await localMutationCommitted?()
        return result
    }

    func applyRemote(_ mutation: PinnedMutation) async throws -> MergeOutcome {
        let session = try currentBackend()
        return try await withSerializedSnapshotOperation(session) { session in
            let (backend, epoch, lease) = session
            let isDestructive: Bool
            switch mutation {
            case .tombstone, .reset:
                isDestructive = true
                try purgeBeforeDestructiveMutation()
                try armFenceForDestructiveMutation()
            case .revision:
                isDestructive = false
            }
            let result: MergeOutcome
            do {
                result = try await backend.applyRemote(mutation)
            } catch {
                if isDestructive {
                    snapshotSafetyFailure = true
                    throw contentFreeDestructiveError(error)
                }
                throw error
            }
            if isDestructive {
                try validateInstalled(epoch, lease: lease)
            } else {
                try validate(epoch, lease: lease)
            }
            snapshotGeneration = max(snapshotGeneration, mutation.libraryGeneration)
            if isDestructive {
                do {
                    try await completeDestructiveSnapshotLocked(backend: backend, epoch: epoch, lease: lease)
                } catch {
                    snapshotSafetyFailure = true
                    snapshotSafetyReady = false
                    throw contentFreeDestructiveError(error)
                }
            } else {
                try? await refreshKeyboardSnapshotLocked(session)
            }
            return result
        }
    }

    func advanceResetGeneration() async throws -> LibraryResetGeneration {
        let session = try currentBackend()
        let result = try await withSerializedSnapshotOperation(session) { session in
            let (backend, epoch, lease) = session
            try purgeBeforeDestructiveMutation()
            try armFenceForDestructiveMutation()
            let result: LibraryResetGeneration
            do {
                result = try await backend.advanceResetGeneration()
            } catch {
                snapshotSafetyFailure = true
                throw contentFreeDestructiveError(error)
            }
            try validateInstalled(epoch, lease: lease)
            snapshotGeneration = result.generation
            do {
                try await completeDestructiveSnapshotLocked(backend: backend, epoch: epoch, lease: lease)
            } catch {
                snapshotSafetyFailure = true
                snapshotSafetyReady = false
                throw contentFreeDestructiveError(error)
            }
            return result
        }
        await localMutationCommitted?()
        return result
    }

    func refreshKeyboardSnapshot() async throws {
        let session = try currentBackend()
        try await withSerializedSnapshotOperation(session) { session in
            try await refreshKeyboardSnapshotLocked(session)
        }
    }

    func markCloudRefreshSucceeded() async throws {
        lastSuccessfulCloudRefresh = now()
        try await refreshKeyboardSnapshot()
    }

    private func refreshKeyboardSnapshotLocked(_ session: Session) async throws {
        let (backend, epoch, lease) = session
        let items = try await backend.allItems()
        try validateInstalled(epoch, lease: lease)
        try snapshotPublisher.publish(
            items: items,
            generation: snapshotGeneration,
            lastCloudRefresh: lastSuccessfulCloudRefresh
        )
        try validateInstalled(epoch, lease: lease)
    }

    private func completeDestructiveSnapshotLocked(
        backend: any PinnedLibrary,
        epoch: UInt64,
        lease: ProtectedDataLease
    ) async throws {
        let items = try await backend.allItems()
        try validateInstalled(epoch, lease: lease)
        try snapshotPublisher.completeDestructivePublication(
            items: items,
            generation: snapshotGeneration,
            lastCloudRefresh: lastSuccessfulCloudRefresh
        )
        try validateInstalled(epoch, lease: lease)
        snapshotSafetyArmed = false
        snapshotSafetyFailure = false
        snapshotSafetyReady = true
    }

    private func armFenceForDestructiveMutation() throws {
        do {
            try snapshotPublisher.armRevocationFence()
            snapshotSafetyArmed = true
            snapshotSafetyFailure = false
            snapshotSafetyReady = false
        } catch {
            snapshotSafetyFailure = true
            snapshotSafetyReady = false
            throw error
        }
    }

    private func purgeBeforeDestructiveMutation() throws {
        do {
            try preDestructivePurge?()
        } catch {
            throw contentFreeDestructiveError(error)
        }
    }

    private func armSnapshotRevocationFence() {
        do {
            try snapshotPublisher.armRevocationFence()
            snapshotSafetyArmed = true
            snapshotSafetyFailure = false
        } catch {
            snapshotSafetyArmed = false
            snapshotSafetyFailure = true
        }
    }

    private func contentFreeDestructiveError(_ error: Error) -> Error {
        if let publisherError = error as? KeyboardSnapshotPublisherError {
            return publisherError
        }
        if let protectedDataError = error as? EncryptedPhonePinnedStoreError {
            return protectedDataError
        }
        return KeyboardSnapshotPublisherError.publicationFailed
    }

    private func withSerializedSnapshotOperation<T>(
        _ session: Session,
        _ operation: (Session) async throws -> T
    ) async throws -> T {
        snapshotOperationRequestCount &+= 1
        await snapshotOperationSerializer.acquire()
        do {
            try Task.checkCancellation()
            try validate(session.epoch, lease: session.lease)
            let result = try await operation(session)
            await snapshotOperationSerializer.release()
            return result
        } catch {
            await snapshotOperationSerializer.release()
            throw error
        }
    }

    private func currentBackend() throws -> Session {
        guard let backend, let installedLease, installedLease.isActive, snapshotSafetyReady else {
            throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
        }
        return (backend, lifecycleEpoch, installedLease)
    }

    private func validate(_ epoch: UInt64, lease: ProtectedDataLease) throws {
        guard epoch == lifecycleEpoch,
              backend != nil,
              installedLease === lease,
              lease.isActive,
              snapshotSafetyReady
        else {
            throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
        }
    }

    private func validateInstalled(_ epoch: UInt64, lease: ProtectedDataLease) throws {
        guard epoch == lifecycleEpoch,
              backend != nil,
              installedLease === lease,
              lease.isActive
        else {
            throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
        }
    }

    private func isInstalledCurrent(_ epoch: UInt64, lease: ProtectedDataLease) -> Bool {
        epoch == lifecycleEpoch &&
            backend != nil &&
            installedLease === lease &&
            lease.isActive &&
            snapshotSafetyReady
    }
}

@MainActor
final class PhoneAppModel: ObservableObject {
    let libraryViewModel: LibraryViewModel
    let extractViewModel: ExtractViewModel
    let importExportViewModel: ImportExportViewModel
    @Published private(set) var pendingShare: ShareInboxItem?
    @Published private(set) var shareCommitInProgress = false
    @Published private(set) var shareErrorMessage: String?
    @Published private(set) var syncStatus: PhonePinnedSyncStatus = .disabled
    @Published private(set) var recoveryActionInProgress = false
    @Published private(set) var cloudDeletionStatus: CloudDeletionStatus = .idle
    @Published private(set) var cloudDeletionInProgress = false
    @Published var syncEnabled = false {
        didSet {
            guard !isApplyingRecoveryPreference else { return }
            let enabled = syncEnabled
            Task { [runtime] in await runtime.setSyncEnabled(enabled) }
        }
    }

    private let runtime: IntentDependencies
    private let shareInboxConsumer: ShareInboxConsumer?
    private var observers: Set<AnyCancellable> = []
    private var isApplyingRecoveryPreference = false

    init(runtime: IntentDependencies = IntentDependencies()) {
        let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        self.runtime = runtime
        let gate = runtime.gate
        libraryViewModel = LibraryViewModel(
            library: gate,
            representations: { text in try await gate.representations(for: text) }
        )
        extractViewModel = ExtractViewModel(
            library: gate,
            representations: { text in try gate.representations(for: text) }
        )
        let filesModel = ImportExportViewModel(
            library: gate,
            representations: { raw in try gate.representations(for: raw) }
        )
        importExportViewModel = filesModel
        gate.preDestructivePurge = { [weak filesModel] in
            guard let filesModel else {
                throw KeyboardSnapshotPublisherError.publicationFailed
            }
            try filesModel.purgeDeletionRecoveryContent()
        }
        syncEnabled = runtime.desiredSyncEnabled
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.kr.donminzzi.clipboardkeyboard"
        ) {
            shareInboxConsumer = ShareInboxConsumer(
                directory: container.appendingPathComponent("share-inbox", isDirectory: true),
                pinner: gate
            )
        } else {
            shareInboxConsumer = nil
        }
        runtime.installRemoteContentChanged { [weak libraryViewModel] in
            await libraryViewModel?.load()
        }
        runtime.installSyncStatusChanged { [weak self] status in self?.syncStatus = status }
        runtime.installCloudDeletionStatusChanged { [weak self] status in self?.cloudDeletionStatus = status }

        observeProtectedDataLifecycle()
        if protectedDataAvailable {
            Task { await protectedDataDidBecomeAvailable() }
        } else {
            libraryViewModel.protectedDataWillBecomeUnavailable()
            shareInboxConsumer?.protectedDataWillBecomeUnavailable()
        }
    }

    func sceneDidBecomeActive() async {
        guard UIApplication.shared.isProtectedDataAvailable, runtime.isReady else { return }
        await runtime.refreshSync()
        shareInboxConsumer?.protectedDataDidBecomeAvailable()
        await refreshShareInbox()
    }

    func keepLocalAndTurnSyncOff() async {
        guard !recoveryActionInProgress else { return }
        recoveryActionInProgress = true
        await runtime.keepLocalAndTurnSyncOff()
        isApplyingRecoveryPreference = true
        syncEnabled = false
        isApplyingRecoveryPreference = false
        recoveryActionInProgress = false
    }

    func reuploadLocalPins() async {
        guard !recoveryActionInProgress else { return }
        recoveryActionInProgress = true
        try? await runtime.reuploadLocalPins()
        recoveryActionInProgress = false
    }

    func deleteCloudData() async {
        guard !cloudDeletionInProgress else { return }
        cloudDeletionInProgress = true
        defer { cloudDeletionInProgress = false }
        try? await runtime.authenticateAndDeleteCloudData()
        await libraryViewModel.load()
    }

    func confirmPendingShare() async {
        guard let item = pendingShare, let shareInboxConsumer else { return }
        shareCommitInProgress = true
        shareErrorMessage = nil
        do {
            try await shareInboxConsumer.commit(id: item.id)
            pendingShare = nil
            await libraryViewModel.load()
            await refreshShareInbox()
        } catch ShareInboxConsumerError.conflict {
            pendingShare = nil
            await refreshShareInbox()
        } catch {
            shareErrorMessage = "Unable to pin this shared item."
        }
        shareCommitInProgress = false
    }

    func rejectPendingShare() async {
        guard let item = pendingShare, let shareInboxConsumer else { return }
        shareCommitInProgress = true
        shareErrorMessage = nil
        do {
            try shareInboxConsumer.reject(id: item.id)
            pendingShare = nil
            await refreshShareInbox()
        } catch {
            shareErrorMessage = "Unable to remove this shared item."
        }
        shareCommitInProgress = false
    }

    func dismissPendingShare() {
        pendingShare = nil
        shareErrorMessage = nil
    }

    private func observeProtectedDataLifecycle() {
        observePhoneProtectedDataWillBecomeUnavailable { [weak self] in
            self?.protectedDataWillBecomeUnavailable()
        }
        .store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.protectedDataDidBecomeAvailable() }
            }
            .store(in: &observers)
    }

    private func protectedDataWillBecomeUnavailable() {
        runtime.lock()
        shareInboxConsumer?.protectedDataWillBecomeUnavailable()
        pendingShare = nil
        shareErrorMessage = nil
        libraryViewModel.protectedDataWillBecomeUnavailable()
        extractViewModel.protectedDataWillBecomeUnavailable()
        importExportViewModel.protectedDataWillBecomeUnavailable()
    }

    private func protectedDataDidBecomeAvailable() async {
        let lifecycle = runtime.protectedDataDidBecomeAvailable()
        do {
            try await runtime.ensureReady()
            await libraryViewModel.load()
            if UIApplication.shared.applicationState == .active {
                shareInboxConsumer?.protectedDataDidBecomeAvailable()
                await refreshShareInbox()
            }
        } catch {
            if runtime.isCurrentLifecycle(lifecycle) {
                libraryViewModel.protectedDataWillBecomeUnavailable()
            }
        }
    }

    private func refreshShareInbox() async {
        guard let shareInboxConsumer else { return }
        do {
            let items = try await shareInboxConsumer.pendingItems()
            try? shareInboxConsumer.purgeTerminalItems()
            pendingShare = items.first
            shareErrorMessage = nil
        } catch {
            pendingShare = nil
        }
    }
}
