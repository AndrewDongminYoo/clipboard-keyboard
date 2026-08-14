import ClipboardCore
import CryptoKit
import Foundation
import UIKit

enum ClipboardIntentError: Error, Equatable, LocalizedError {
    case invalidInput
    case unavailable
    case notFound
    case selectionCancelled
    case operationFailed

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            "Enter nonempty text."
        case .unavailable:
            "The protected library is unavailable."
        case .notFound:
            "No pinned text was found."
        case .selectionCancelled:
            "No pinned text was selected."
        case .operationFailed:
            "The action could not be completed."
        }
    }
}

struct IntentReadyBackend: Sendable {
    let library: any PinnedLibrary
    let textTransformer: TextTransformer
    let generation: Int64
    let close: @MainActor @Sendable () async -> Void
}

struct IntentActionOutcome: Equatable, Sendable {
    let dialog: String
}

struct ExtractValuesOutcome: Equatable, Sendable {
    let values: [String]
    let dialog: String
}

struct FindPinnedOutcome: Equatable, Sendable {
    let value: String
    let dialog: String
}

struct FindPinnedChoice: Equatable, Sendable {
    let id: UUID
    let label: String
}

struct IntentRuntimeLifecycleToken: Equatable, Sendable {
    let epoch: UInt64
}

@MainActor
final class IntentDependencies: @unchecked Sendable {
    typealias Readiness = @MainActor @Sendable (PhoneUnlockContext) async throws -> IntentReadyBackend
    typealias PasteboardWrite = @MainActor @Sendable (String) throws -> Void
    typealias Selection = @MainActor @Sendable ([FindPinnedChoice]) async throws -> UUID

    let gate: PhonePinnedLibraryGate

    private struct ReadinessOperation {
        let id: UUID
        let task: Task<Void, Error>
    }

    private let readiness: Readiness
    private let pasteboardWrite: PasteboardWrite
    private let extractor: ValueExtractor
    private var readinessOperation: ReadinessOperation?
    private var readinessWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var installedClose: (@MainActor @Sendable () async -> Void)?
    private var lifecycleEpoch: UInt64 = 0
    private var protectedDataAvailable: Bool
    private(set) var isReady = false

    var readinessWaiterCount: Int {
        readinessWaiters.count
    }

    init(
        gate: PhonePinnedLibraryGate = PhonePinnedLibraryGate(snapshotPublisher: KeyboardSnapshotPublisher()),
        readiness: @escaping Readiness = IntentDependencies.prepareProductionBackend,
        extractor: ValueExtractor = ValueExtractor(),
        protectedDataAvailable: Bool = UIApplication.shared.isProtectedDataAvailable,
        pasteboardWrite: @escaping PasteboardWrite = { value in try SystemPasteboardWriter().write(value) }
    ) {
        self.gate = gate
        self.readiness = readiness
        self.extractor = extractor
        self.protectedDataAvailable = protectedDataAvailable
        self.pasteboardWrite = pasteboardWrite
    }

    func ensureReady() async throws {
        let callerEpoch = lifecycleEpoch
        guard protectedDataAvailable else {
            throw ClipboardIntentError.unavailable
        }
        if isReady {
            try validateReady(epoch: callerEpoch)
            try Task.checkCancellation()
            return
        }
        let operation = readinessOperation ?? startReadinessOperation(epoch: callerEpoch)
        do {
            try await awaitReadiness(operationID: operation.id)
            try validateReady(epoch: callerEpoch)
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            guard callerEpoch == lifecycleEpoch, protectedDataAvailable else {
                throw ClipboardIntentError.unavailable
            }
            throw ClipboardIntentError.unavailable
        }
    }

    func lock() {
        lifecycleEpoch &+= 1
        protectedDataAvailable = false
        readinessOperation?.task.cancel()
        readinessOperation = nil
        finishReadinessWaiters(with: .failure(ClipboardIntentError.unavailable))
        isReady = false
        gate.lock()
        let close = installedClose
        installedClose = nil
        if let close {
            Task { await close() }
        }
    }

    @discardableResult
    func protectedDataDidBecomeAvailable() -> IntentRuntimeLifecycleToken {
        protectedDataAvailable = true
        return IntentRuntimeLifecycleToken(epoch: lifecycleEpoch)
    }

    func isCurrentLifecycle(_ token: IntentRuntimeLifecycleToken) -> Bool {
        protectedDataAvailable && token.epoch == lifecycleEpoch
    }

    private func startReadinessOperation(epoch: UInt64) -> ReadinessOperation {
        let operationID = UUID()
        let unlock = gate.beginUnlock()
        let readiness = self.readiness
        let task = Task { @MainActor [weak self] in
            guard let self else { throw ClipboardIntentError.unavailable }
            let backend: IntentReadyBackend
            do {
                backend = try await readiness(unlock)
            } catch {
                if epoch == lifecycleEpoch {
                    _ = gate.failUnlock(unlock)
                }
                throw ClipboardIntentError.unavailable
            }
            guard epoch == lifecycleEpoch, protectedDataAvailable, !Task.isCancelled else {
                await backend.close()
                throw ClipboardIntentError.unavailable
            }
            guard gate.install(
                backend.library,
                textTransformer: backend.textTransformer,
                for: unlock,
                generation: backend.generation,
                snapshotSafetyInitialized: false
            ) else {
                await backend.close()
                throw ClipboardIntentError.unavailable
            }
            do {
                try await gate.initializeKeyboardSnapshotSafety()
            } catch {
                _ = gate.failInstalledUnlock(unlock)
                await backend.close()
                throw ClipboardIntentError.unavailable
            }
            guard epoch == lifecycleEpoch, protectedDataAvailable, !Task.isCancelled else {
                _ = gate.failInstalledUnlock(unlock)
                await backend.close()
                throw ClipboardIntentError.unavailable
            }
            installedClose = backend.close
            isReady = true
        }
        let operation = ReadinessOperation(id: operationID, task: task)
        readinessOperation = operation
        Task { @MainActor [weak self] in
            let result = await task.result
            self?.completeReadinessOperation(id: operationID, epoch: epoch, result: result)
        }
        return operation
    }

    private func awaitReadiness(operationID: UUID) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if readinessOperation?.id == operationID {
                    readinessWaiters[waiterID] = continuation
                } else if isReady {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ClipboardIntentError.unavailable)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelReadinessWaiter(waiterID)
            }
        }
    }

    private func cancelReadinessWaiter(_ waiterID: UUID) {
        if let continuation = readinessWaiters.removeValue(forKey: waiterID) {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func completeReadinessOperation(
        id: UUID,
        epoch: UInt64,
        result: Result<Void, Error>
    ) {
        guard readinessOperation?.id == id else { return }
        readinessOperation = nil
        if case .failure = result, epoch == lifecycleEpoch {
            isReady = false
        }
        finishReadinessWaiters(with: result)
    }

    private func finishReadinessWaiters(with result: Result<Void, Error>) {
        let continuations = Array(readinessWaiters.values)
        readinessWaiters.removeAll()
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }

    private func validateReady(epoch: UInt64) throws {
        guard epoch == lifecycleEpoch, protectedDataAvailable, isReady else {
            throw ClipboardIntentError.unavailable
        }
    }

    func pinText(_ text: String) async throws -> IntentActionOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClipboardIntentError.invalidInput
        }
        do {
            try await ensureReady()
            let operationEpoch = lifecycleEpoch
            try validateReady(epoch: operationEpoch)
            try Task.checkCancellation()
            let representations = try gate.representations(for: text)
            try validateReady(epoch: operationEpoch)
            try Task.checkCancellation()
            let payload = PinPayload(
                representations: representations,
                canonicalInsertionString: text,
                title: "Pinned Text",
                contentKind: .plainText,
                category: nil
            )
            _ = try await gate.pinForIntent(payload)
            return IntentActionOutcome(dialog: "Text pinned.")
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ClipboardIntentError {
            throw error
        } catch let error as EncryptedPhonePinnedStoreError where error == .protectedDataUnavailable {
            throw ClipboardIntentError.unavailable
        } catch {
            throw ClipboardIntentError.operationFailed
        }
    }

    func extractValues(_ text: String) async throws -> ExtractValuesOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClipboardIntentError.invalidInput
        }
        do {
            try await ensureReady()
            let operationEpoch = lifecycleEpoch
            try validateReady(epoch: operationEpoch)
            try Task.checkCancellation()
            let outcome = ExtractValuesOutcome(
                values: extractor.candidates(in: text).map(\.original),
                dialog: "Values extracted."
            )
            try validateReady(epoch: operationEpoch)
            try Task.checkCancellation()
            return outcome
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ClipboardIntentError {
            throw error
        } catch {
            throw ClipboardIntentError.operationFailed
        }
    }

    func findPinned(
        query: String,
        copy: Bool,
        select: Selection
    ) async throws -> FindPinnedOutcome {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClipboardIntentError.invalidInput
        }
        do {
            try await ensureReady()
            let operationEpoch = lifecycleEpoch
            try validateReady(epoch: operationEpoch)
            try Task.checkCancellation()
            let matches = try await gate.search(query, limit: 100)
            try validateReady(epoch: operationEpoch)
            try Task.checkCancellation()
            guard let first = matches.first else { throw ClipboardIntentError.notFound }
            let selected: PinnedRevision
            if matches.count == 1 {
                selected = first
            } else {
                let choices = matches.enumerated().map { offset, revision in
                    FindPinnedChoice(id: revision.itemID, label: "\(offset + 1). \(revision.payload.title)")
                }
                let selectedID: UUID
                do {
                    selectedID = try await select(choices)
                } catch is CancellationError {
                    try validateReady(epoch: operationEpoch)
                    throw ClipboardIntentError.selectionCancelled
                }
                try validateReady(epoch: operationEpoch)
                guard let match = matches.first(where: { $0.itemID == selectedID }) else {
                    throw ClipboardIntentError.selectionCancelled
                }
                selected = match
            }
            try validateReady(epoch: operationEpoch)
            try Task.checkCancellation()
            if copy {
                try pasteboardWrite(selected.payload.canonicalInsertionString)
            }
            return FindPinnedOutcome(
                value: selected.payload.canonicalInsertionString,
                dialog: copy ? "Pinned text copied." : "Pinned text found."
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ClipboardIntentError {
            throw error
        } catch let error as EncryptedPhonePinnedStoreError where error == .protectedDataUnavailable {
            throw ClipboardIntentError.unavailable
        } catch {
            throw ClipboardIntentError.operationFailed
        }
    }

    private static func prepareProductionBackend(unlock: PhoneUnlockContext) async throws -> IntentReadyBackend {
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
            lease: unlock.lease
        )
        let library = LocalPinnedLibrary(
            store: store,
            lease: unlock.lease,
            deviceID: UIDevice.current.identifierForVendor?.uuidString ?? "iphone"
        )
        try await library.reopenProtectedData()
        let state = try await store.load()
        let transformer = TextTransformer { data in
            Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        }
        return IntentReadyBackend(
            library: library,
            textTransformer: transformer,
            generation: state.libraryGeneration,
            close: { await library.protectedDataWillBecomeUnavailable() }
        )
    }
}
