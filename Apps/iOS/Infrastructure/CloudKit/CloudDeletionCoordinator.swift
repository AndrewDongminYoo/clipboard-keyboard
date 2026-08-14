import ClipboardCore
import CloudKit
import Foundation
import LocalAuthentication

enum CloudDeletionStatus: Equatable, Sendable {
    case idle
    case authenticating
    case pendingCloudConfirmation
    case completed
    case authenticationFailed
}

enum CloudDeletionCoordinatorError: Error, Equatable {
    case authenticationFailed
    case unavailable
    case operationFailed
    case operationInProgress
}

struct CloudDeletionRequest: Codable, Equatable, Sendable {
    var reset: LibraryResetGeneration?
}

@MainActor
protocol CloudDeletionRequestPersisting: AnyObject {
    func load() -> CloudDeletionRequest?
    func save(_ request: CloudDeletionRequest)
    func clear()
}

@MainActor
final class UserDefaultsCloudDeletionRequestStore: CloudDeletionRequestPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "PhonePinnedSync.cloudDeletion.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> CloudDeletionRequest? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CloudDeletionRequest.self, from: data)
    }

    func save(_ request: CloudDeletionRequest) {
        guard let data = try? JSONEncoder().encode(request) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

struct CloudDeletionBackend: Sendable {
    let prepare: @MainActor @Sendable () async -> Void
    let advanceReset: @MainActor @Sendable () async throws -> LibraryResetGeneration
    let deleteRemoteContentKeepingReset: @MainActor @Sendable (LibraryResetGeneration) async throws -> Void
    let resetSyncState: @MainActor @Sendable () async throws -> Void
    let acknowledgeReset: @MainActor @Sendable (UUID) async throws -> Void
    let didComplete: @MainActor @Sendable () async -> Void
}

@MainActor
final class CloudDeletionCoordinator {
    typealias Authenticate = @MainActor @Sendable () async throws -> Void
    typealias Backend = @MainActor @Sendable () throws -> CloudDeletionBackend

    private let requestStore: any CloudDeletionRequestPersisting
    private let authenticate: Authenticate
    private let backend: Backend
    private var statusObserver: (@MainActor @Sendable (CloudDeletionStatus) -> Void)?
    private(set) var status: CloudDeletionStatus
    private(set) var isInProgress = false

    var hasPendingRequest: Bool {
        requestStore.load() != nil
    }

    init(
        requestStore: any CloudDeletionRequestPersisting = UserDefaultsCloudDeletionRequestStore(),
        authenticate: @escaping Authenticate = CloudDeletionCoordinator.authenticateDeviceOwner,
        backend: @escaping Backend
    ) {
        self.requestStore = requestStore
        self.authenticate = authenticate
        self.backend = backend
        status = requestStore.load() == nil ? .idle : .pendingCloudConfirmation
    }

    func installStatusObserver(_ observer: @escaping @MainActor @Sendable (CloudDeletionStatus) -> Void) {
        statusObserver = observer
        observer(status)
    }

    func authenticateAndDeleteCloudData() async throws {
        guard !isInProgress else { throw CloudDeletionCoordinatorError.operationInProgress }
        isInProgress = true
        defer { isInProgress = false }

        updateStatus(.authenticating)
        do {
            try await authenticate()
        } catch {
            updateStatus(hasPendingRequest ? .pendingCloudConfirmation : .authenticationFailed)
            throw CloudDeletionCoordinatorError.authenticationFailed
        }

        var request = requestStore.load() ?? CloudDeletionRequest(reset: nil)
        requestStore.save(request)
        updateStatus(.pendingCloudConfirmation)

        do {
            let deletionBackend = try backend()
            await deletionBackend.prepare()
            let reset: LibraryResetGeneration
            if let existingReset = request.reset {
                reset = existingReset
            } else {
                reset = try await deletionBackend.advanceReset()
                request.reset = reset
                requestStore.save(request)
            }
            try await deletionBackend.deleteRemoteContentKeepingReset(reset)
            try await deletionBackend.resetSyncState()
            try await deletionBackend.acknowledgeReset(reset.resetID)
            requestStore.clear()
            updateStatus(.completed)
            await deletionBackend.didComplete()
        } catch let error as CloudDeletionCoordinatorError {
            updateStatus(.pendingCloudConfirmation)
            throw error
        } catch {
            updateStatus(.pendingCloudConfirmation)
            throw CloudDeletionCoordinatorError.operationFailed
        }
    }

    private func updateStatus(_ newStatus: CloudDeletionStatus) {
        status = newStatus
        statusObserver?(newStatus)
    }

    static func authenticateDeviceOwner() async throws {
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            throw CloudDeletionCoordinatorError.authenticationFailed
        }
        guard try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Authenticate to delete synced clipboard data from iCloud."
        ) else {
            throw CloudDeletionCoordinatorError.authenticationFailed
        }
    }
}

@MainActor
struct PhoneCloudDataDeletionOperations {
    let verifyAccount: @MainActor @Sendable () async throws -> Void
    let deleteZone: @MainActor @Sendable () async throws -> Void
    let recreateZone: @MainActor @Sendable () async throws -> Void
    let saveReset: @MainActor @Sendable (LibraryResetGeneration) async throws -> Void
}

@MainActor
struct PhoneCloudDataDeleter {
    private let operations: PhoneCloudDataDeletionOperations

    init(operations: PhoneCloudDataDeletionOperations) {
        self.operations = operations
    }

    init(
        container: CKContainer = CKContainer(identifier: "iCloud.kr.donminzzi.clipboardkeyboard"),
        codec: PhoneCloudRecordCodec = PhoneCloudRecordCodec()
    ) {
        let database = container.privateCloudDatabase
        operations = PhoneCloudDataDeletionOperations(
            verifyAccount: {
                guard try await container.accountStatus() == .available else {
                    throw CloudDeletionCoordinatorError.unavailable
                }
            },
            deleteZone: {
                do {
                    _ = try await database.deleteRecordZone(withID: PhoneCloudRecordCodec.zoneID)
                } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {}
            },
            recreateZone: {
                _ = try await database.save(CKRecordZone(zoneID: PhoneCloudRecordCodec.zoneID))
            },
            saveReset: { reset in
                _ = try await database.save(codec.encode(.reset(reset)))
            }
        )
    }

    func deleteAllContentKeepingReset(_ reset: LibraryResetGeneration) async throws {
        try await operations.verifyAccount()
        try await operations.deleteZone()
        try await operations.recreateZone()
        try await operations.saveReset(reset)
    }
}
