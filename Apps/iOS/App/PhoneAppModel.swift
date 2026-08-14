import ClipboardCore
import Combine
import CryptoKit
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
final class PhonePinnedLibraryGate: PinnedLibrary {
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
        return try await withSerializedSnapshotOperation(session) { session in
            let (backend, epoch, lease) = session
            let result = try await backend.pin(payload)
            try validate(epoch, lease: lease)
            snapshotGeneration = result.libraryGeneration
            try? await refreshKeyboardSnapshotLocked(session)
            return result
        }
    }

    func revise(itemID: UUID, payload: PinPayload) async throws -> PinnedRevision {
        let session = try currentBackend()
        return try await withSerializedSnapshotOperation(session) { session in
            let (backend, epoch, lease) = session
            let result = try await backend.revise(itemID: itemID, payload: payload)
            try validate(epoch, lease: lease)
            snapshotGeneration = result.libraryGeneration
            try? await refreshKeyboardSnapshotLocked(session)
            return result
        }
    }

    func delete(itemID: UUID) async throws -> PinnedTombstone {
        let session = try currentBackend()
        return try await withSerializedSnapshotOperation(session) { session in
            let (backend, epoch, lease) = session
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
    }

    func applyRemote(_ mutation: PinnedMutation) async throws -> MergeOutcome {
        let session = try currentBackend()
        return try await withSerializedSnapshotOperation(session) { session in
            let (backend, epoch, lease) = session
            let isDestructive: Bool
            switch mutation {
            case .tombstone, .reset:
                isDestructive = true
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
            lastSuccessfulCloudRefresh = now()
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
        return try await withSerializedSnapshotOperation(session) { session in
            let (backend, epoch, lease) = session
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
    }

    func refreshKeyboardSnapshot() async throws {
        let session = try currentBackend()
        try await withSerializedSnapshotOperation(session) { session in
            try await refreshKeyboardSnapshotLocked(session)
        }
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
}

@MainActor
final class PhoneAppModel: ObservableObject {
    let libraryViewModel: LibraryViewModel
    let extractViewModel: ExtractViewModel
    let importExportViewModel: ImportExportViewModel

    private let libraryGate: PhonePinnedLibraryGate
    private var localLibrary: LocalPinnedLibrary?
    private var observers: Set<AnyCancellable> = []

    init() {
        let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        let gate = PhonePinnedLibraryGate(snapshotPublisher: KeyboardSnapshotPublisher())
        libraryGate = gate
        libraryViewModel = LibraryViewModel(
            library: gate,
            representations: { text in try await gate.representations(for: text) }
        )
        extractViewModel = ExtractViewModel(
            library: gate,
            representations: { text in try gate.representations(for: text) }
        )
        importExportViewModel = ImportExportViewModel(
            library: gate,
            representations: { raw in try gate.representations(for: raw) }
        )

        observeProtectedDataLifecycle()
        if protectedDataAvailable {
            Task { await protectedDataDidBecomeAvailable() }
        } else {
            libraryViewModel.protectedDataWillBecomeUnavailable()
        }
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
        libraryGate.lock()
        libraryViewModel.protectedDataWillBecomeUnavailable()
        extractViewModel.protectedDataWillBecomeUnavailable()
        importExportViewModel.protectedDataWillBecomeUnavailable()
        let previousLibrary = localLibrary
        localLibrary = nil
        guard let previousLibrary else { return }
        Task { await previousLibrary.protectedDataWillBecomeUnavailable() }
    }

    private func protectedDataDidBecomeAvailable() async {
        let unlock = libraryGate.beginUnlock()
        do {
            let backend = try makeBackend(lease: unlock.lease)
            try await backend.library.reopenProtectedData()
            let state = try await backend.store.load()
            guard libraryGate.install(
                backend.library,
                textTransformer: backend.textTransformer,
                for: unlock,
                generation: state.libraryGeneration,
                snapshotSafetyInitialized: false
            ) else {
                await backend.library.protectedDataWillBecomeUnavailable()
                return
            }
            do {
                try await libraryGate.initializeKeyboardSnapshotSafety()
            } catch {
                libraryGate.lock()
                localLibrary = nil
                await backend.library.protectedDataWillBecomeUnavailable()
                libraryViewModel.protectedDataWillBecomeUnavailable()
                return
            }
            localLibrary = backend.library
            await libraryViewModel.load()
        } catch {
            if libraryGate.failUnlock(unlock) {
                libraryViewModel.protectedDataWillBecomeUnavailable()
            }
        }
    }

    private func makeBackend(lease: ProtectedDataLease) throws -> PhoneLibraryBackend {
        let key = try PhoneKeychainMasterKeyStore().loadOrCreateKey()
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let store = EncryptedPhonePinnedStore(
            fileURL: directory.appendingPathComponent("phone-pinned-replica.encrypted"),
            key: key,
            lease: lease
        )
        let library = LocalPinnedLibrary(
            store: store,
            lease: lease,
            deviceID: UIDevice.current.identifierForVendor?.uuidString ?? "iphone"
        )
        let textTransformer = TextTransformer { data in
            Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        }
        return PhoneLibraryBackend(library: library, store: store, textTransformer: textTransformer)
    }
}

private struct PhoneLibraryBackend: Sendable {
    let library: LocalPinnedLibrary
    let store: EncryptedPhonePinnedStore
    let textTransformer: TextTransformer
}
