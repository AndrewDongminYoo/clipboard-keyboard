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
    private var backend: (any PinnedLibrary)?
    private var textTransformer: TextTransformer?
    private var pendingLease: ProtectedDataLease?
    private var installedLease: ProtectedDataLease?
    private var lifecycleEpoch: UInt64 = 0

    func beginUnlock() -> PhoneUnlockContext {
        pendingLease?.revoke()
        installedLease?.revoke()
        lifecycleEpoch &+= 1
        backend = nil
        textTransformer = nil
        installedLease = nil
        let lease = ProtectedDataLease()
        pendingLease = lease
        return PhoneUnlockContext(epoch: lifecycleEpoch, lease: lease)
    }

    @discardableResult
    func install(
        _ backend: any PinnedLibrary,
        textTransformer: TextTransformer? = nil,
        for unlock: PhoneUnlockContext
    ) -> Bool {
        guard unlock.epoch == lifecycleEpoch,
              pendingLease === unlock.lease,
              unlock.lease.isActive
        else {
            unlock.lease.revoke()
            return false
        }
        self.backend = backend
        self.textTransformer = textTransformer
        pendingLease = nil
        installedLease = unlock.lease
        return true
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
        lifecycleEpoch &+= 1
        backend = nil
        textTransformer = nil
        pendingLease = nil
        installedLease = nil
        return true
    }

    func lock() {
        pendingLease?.revoke()
        installedLease?.revoke()
        lifecycleEpoch &+= 1
        backend = nil
        textTransformer = nil
        pendingLease = nil
        installedLease = nil
    }

    func representations(for text: String) throws -> [ClipRepresentation] {
        guard let textTransformer, installedLease?.isActive == true else {
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
        let (backend, epoch, lease) = try currentBackend()
        let result = try await backend.pin(payload)
        try validate(epoch, lease: lease)
        return result
    }

    func revise(itemID: UUID, payload: PinPayload) async throws -> PinnedRevision {
        let (backend, epoch, lease) = try currentBackend()
        let result = try await backend.revise(itemID: itemID, payload: payload)
        try validate(epoch, lease: lease)
        return result
    }

    func delete(itemID: UUID) async throws -> PinnedTombstone {
        let (backend, epoch, lease) = try currentBackend()
        let result = try await backend.delete(itemID: itemID)
        try validate(epoch, lease: lease)
        return result
    }

    func applyRemote(_ mutation: PinnedMutation) async throws -> MergeOutcome {
        let (backend, epoch, lease) = try currentBackend()
        let result = try await backend.applyRemote(mutation)
        try validate(epoch, lease: lease)
        return result
    }

    func advanceResetGeneration() async throws -> LibraryResetGeneration {
        let (backend, epoch, lease) = try currentBackend()
        let result = try await backend.advanceResetGeneration()
        try validate(epoch, lease: lease)
        return result
    }

    private func currentBackend() throws -> (any PinnedLibrary, UInt64, ProtectedDataLease) {
        guard let backend, let installedLease, installedLease.isActive else {
            throw EncryptedPhonePinnedStoreError.protectedDataUnavailable
        }
        return (backend, lifecycleEpoch, installedLease)
    }

    private func validate(_ epoch: UInt64, lease: ProtectedDataLease) throws {
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

    private let libraryGate: PhonePinnedLibraryGate
    private var localLibrary: LocalPinnedLibrary?
    private var observers: Set<AnyCancellable> = []

    init() {
        let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        let gate = PhonePinnedLibraryGate()
        libraryGate = gate
        libraryViewModel = LibraryViewModel(
            library: gate,
            representations: { text in try await gate.representations(for: text) }
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
            guard libraryGate.install(
                backend.library,
                textTransformer: backend.textTransformer,
                for: unlock
            ) else {
                await backend.library.protectedDataWillBecomeUnavailable()
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
        return PhoneLibraryBackend(library: library, textTransformer: textTransformer)
    }
}

private struct PhoneLibraryBackend: Sendable {
    let library: LocalPinnedLibrary
    let textTransformer: TextTransformer
}
