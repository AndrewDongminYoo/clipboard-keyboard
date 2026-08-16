import ClipboardCore
import CloudKit
import Foundation

enum MacPinnedSyncStatus: Equatable, Sendable {
    case disabled
    case pending
    case synced
    case unableToSyncFullItem
    case accountUnavailable
    case recoveryRequired
}

enum MacPinnedSyncStartError: Error {
    case accountUnavailable
}

enum MacPinnedSyncTransportError: Error {
    case accountUnavailable
}

struct MacCloudAccountContext: @unchecked Sendable {
    let accountIdentity: String
    let container: CKContainer?
}

protocol MacCloudKitSession: Sendable {
    func prepareZone() async throws
    func fetch() async throws
    func send(_ mutations: [PinnedMutation]) async throws
    func cancel() async
}

private final class MacCKSyncSession: MacCloudKitSession, @unchecked Sendable {
    private let engine: CKSyncEngine
    private let delegate: MacCloudKitSyncDelegate

    init(engine: CKSyncEngine, delegate: MacCloudKitSyncDelegate) {
        self.engine = engine
        self.delegate = delegate
    }

    func prepareZone() async throws {
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: MacCloudRecordCodec.zoneID))])
        try await engine.sendChanges(.init(scope: .zoneIDs([MacCloudRecordCodec.zoneID])))
    }

    func fetch() async throws {
        try await engine.fetchChanges(.init(scope: .zoneIDs([MacCloudRecordCodec.zoneID])))
    }

    func send(_ mutations: [PinnedMutation]) async throws {
        await delegate.replacePending(mutations)
        let changes = mutations.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(
                CKRecord.ID(
                    recordName: PinnedCloudDocument.metadata(for: $0).recordName,
                    zoneID: MacCloudRecordCodec.zoneID
                )
            )
        }
        engine.state.add(pendingRecordZoneChanges: changes)
        do {
            try await engine.sendChanges(.init(scope: .zoneIDs([MacCloudRecordCodec.zoneID])))
        } catch {
            await delegate.cleanupStagedAssets()
            throw error
        }
    }

    func cancel() async {
        await engine.cancelOperations()
    }
}

actor MacCloudKitTransport: MacPinnedSyncTransport {
    typealias ResolveAccount = @Sendable () async throws -> MacCloudAccountContext
    typealias MakeSession = @Sendable (MacCloudAccountContext) async throws -> any MacCloudKitSession

    private let delegate: MacCloudKitSyncDelegate
    private let resolveAccount: ResolveAccount
    private let makeSession: MakeSession
    private var session: (any MacCloudKitSession)?
    private var generation: UInt64 = 0

    init(stateStore: MacSyncStateStore) {
        let delegate = MacCloudKitSyncDelegate(stateStore: stateStore)
        self.delegate = delegate
        resolveAccount = {
            let container = CKContainer(identifier: "iCloud.kr.donminzzi.clipboardkeyboard")
            let accountStatus: CKAccountStatus
            do {
                accountStatus = try await container.accountStatus()
            } catch {
                throw MacPinnedSyncStartError.accountUnavailable
            }
            guard accountStatus == .available else { throw MacPinnedSyncStartError.accountUnavailable }
            do {
                return try MacCloudAccountContext(
                    accountIdentity: await container.userRecordID().recordName,
                    container: container
                )
            } catch {
                throw MacPinnedSyncStartError.accountUnavailable
            }
        }
        makeSession = { context in
            guard let container = context.container else { throw MacPinnedSyncStartError.accountUnavailable }
            try await stateStore.bind(accountIdentity: context.accountIdentity)
            let restored = try await stateStore.load(accountIdentity: context.accountIdentity)
            var configuration = CKSyncEngine.Configuration(
                database: container.privateCloudDatabase,
                stateSerialization: restored,
                delegate: delegate
            )
            configuration.automaticallySync = true
            return MacCKSyncSession(engine: CKSyncEngine(configuration), delegate: delegate)
        }
    }

    init(
        stateStore: MacSyncStateStore,
        resolveAccount: @escaping ResolveAccount,
        makeSession: @escaping MakeSession
    ) {
        delegate = MacCloudKitSyncDelegate(stateStore: stateStore)
        self.resolveAccount = resolveAccount
        self.makeSession = makeSession
    }

    func start(eventHandler: @escaping @Sendable (MacPinnedSyncEvent) async -> Void) async throws {
        generation &+= 1
        let startGeneration = generation
        await delegate.install(eventHandler: eventHandler)
        let account = try await resolveAccount()
        guard startGeneration == generation else { return }
        let newSession = try await makeSession(account)
        guard startGeneration == generation else {
            await newSession.cancel()
            return
        }
        session = newSession
        do {
            try await newSession.prepareZone()
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    func fetch() async throws {
        guard let session else { return }
        do {
            try await session.fetch()
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    func send(_ mutations: [PinnedMutation]) async throws {
        guard let session else { return }
        do {
            try await session.send(mutations)
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    func cancel() async {
        generation &+= 1
        let oldSession = session
        session = nil
        await oldSession?.cancel()
        await delegate.clear()
    }

    func releaseWithoutCancelling() async {
        generation &+= 1
        session = nil
        await delegate.clear()
    }

    private static func mapTransportError(_ error: Error) -> Error {
        guard let cloudError = error as? CKError else { return error }
        switch cloudError.code {
        case .notAuthenticated:
            return MacPinnedSyncTransportError.accountUnavailable
        default:
            return error
        }
    }
}

private actor MacCloudKitSyncDelegate: CKSyncEngineDelegate {
    private let stateStore: MacSyncStateStore
    private let codec = MacCloudRecordCodec()
    private var eventHandler: (@Sendable (MacPinnedSyncEvent) async -> Void)?
    private var pendingByRecordName: [String: PinnedMutation] = [:]

    init(stateStore: MacSyncStateStore) {
        self.stateStore = stateStore
    }

    func install(eventHandler: @escaping @Sendable (MacPinnedSyncEvent) async -> Void) {
        self.eventHandler = eventHandler
    }

    func replacePending(_ mutations: [PinnedMutation]) {
        codec.cleanupAllStagedAssets()
        pendingByRecordName = Dictionary(uniqueKeysWithValues: mutations.map {
            (PinnedCloudDocument.metadata(for: $0).recordName, $0)
        })
    }

    func clear() {
        codec.cleanupAllStagedAssets()
        eventHandler = nil
        pendingByRecordName.removeAll()
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine _: CKSyncEngine) async {
        guard let eventHandler else { return }
        switch event {
        case let .stateUpdate(update):
            do {
                try await stateStore.save(update.stateSerialization)
                let data = try JSONEncoder().encode(update.stateSerialization)
                await eventHandler(.stateUpdate(data))
            } catch {
                await eventHandler(.retryableFailure)
            }
        case let .accountChange(change):
            switch change.changeType {
            case .signOut:
                await eventHandler(.accountUnavailable)
            case .signIn:
                // The engine reports the signed-in account as soon as a session starts,
                // so this is the expected steady state rather than a change to recover
                // from. Mapping it to .accountChanged tore down the session that had
                // just been established. Recovery belongs to .switchAccounts, which is
                // the case CloudKit itself pairs with deleting local data.
                break
            case .switchAccounts:
                await eventHandler(.accountChanged)
            @unknown default:
                await eventHandler(.accountChanged)
            }
        case let .fetchedDatabaseChanges(changes):
            if changes.deletions.contains(where: { $0.reason == .encryptedDataReset }) {
                await eventHandler(.accountChanged)
            }
        case let .fetchedRecordZoneChanges(changes):
            for modification in changes.modifications {
                guard let mutation = try? codec.decode(modification.record) else {
                    await eventHandler(.terminalFailure(UUID()))
                    continue
                }
                await eventHandler(.fetched(mutation))
            }
        case let .sentRecordZoneChanges(changes):
            for record in changes.savedRecords {
                codec.cleanupStagedAsset(recordName: record.recordID.recordName)
            }
            let ids = changes.savedRecords.compactMap { UUID(uuidString: $0.recordID.recordName) }
            if !ids.isEmpty {
                await eventHandler(.sent(ids))
            }
            for failed in changes.failedRecordSaves {
                codec.cleanupStagedAsset(recordName: failed.record.recordID.recordName)
                let id = UUID(uuidString: failed.record.recordID.recordName) ?? UUID()
                await eventHandler(.failedSave(id: id, error: failed.error))
            }
        default:
            break
        }
    }

    func cleanupStagedAssets() {
        codec.cleanupAllStagedAssets()
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter(context.options.scope.contains)
        let eventHandler = eventHandler
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [codec, pendingByRecordName] id in
            guard let mutation = pendingByRecordName[id.recordName] else { return nil }
            do {
                return try codec.encode(mutation)
            } catch {
                codec.cleanupStagedAsset(recordName: id.recordName)
                await eventHandler?(.terminalFailure(mutation.mutationID))
                return nil
            }
        }
    }
}

enum MacPinnedSyncEvent: Sendable {
    case stateUpdate(Data)
    case fetched(PinnedMutation)
    case fetchCompleted
    case sent([UUID])
    case retryableFailure
    case terminalFailure(UUID)
    case accountUnavailable
    case accountChanged

    static func failedSave(id: UUID, error: CKError) -> Self {
        switch error.code {
        case .notAuthenticated:
            return .accountUnavailable
        case .accountTemporarilyUnavailable, .networkFailure, .networkUnavailable, .requestRateLimited,
             .serviceUnavailable, .zoneBusy:
            return .retryableFailure
        default:
            return .terminalFailure(id)
        }
    }
}

protocol MacPinnedSyncTransport: Sendable {
    func start(eventHandler: @escaping @Sendable (MacPinnedSyncEvent) async -> Void) async throws
    func fetch() async throws
    func send(_ mutations: [PinnedMutation]) async throws
    func cancel() async
    /// Drops the session without cancelling it, for the one path that runs inside a
    /// CKSyncEngine event callback. See `MacPinnedSyncEngine.stopTransport(with:insideEventCallback:)`.
    func releaseWithoutCancelling() async
}

actor MacPinnedSyncEngine {
    typealias TransportFactory = @Sendable () throws -> any MacPinnedSyncTransport
    typealias PendingMutations = @Sendable () async throws -> [PinnedMutation]
    typealias Acknowledge = @Sendable ([UUID]) async throws -> Void
    typealias ApplyRemote = @Sendable (PinnedMutation) async throws -> Void
    typealias PersistState = @Sendable (Data) async throws -> Void

    private(set) var status: MacPinnedSyncStatus = .disabled
    private let makeTransport: TransportFactory
    private let pendingMutations: PendingMutations
    private let acknowledge: Acknowledge
    private let applyRemote: ApplyRemote
    private let persistState: PersistState
    private let requeueForRecovery: @Sendable () async throws -> Void
    private let resetSyncStateForRecovery: @Sendable () async throws -> Void
    private var transport: (any MacPinnedSyncTransport)?
    private var sessionEpoch: UInt64 = 0
    private var drainTask: Task<Void, Never>?
    private var drainDirty = false
    private var sendInProgress = false
    private var seenFetchedMutationIDs: Set<UUID> = []
    private var applyingFetchedMutationIDs: Set<UUID> = []
    private var statusObserver: (@Sendable (MacPinnedSyncStatus) async -> Void)?
    private var activeEventOperationCount = 0
    private var eventIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private var recoveryIncidentEpoch: UInt64?
    private var recoveryInProgress = false
    private var desiredEnabled = false

    init(
        makeTransport: @escaping TransportFactory,
        pendingMutations: @escaping PendingMutations = { [] },
        acknowledge: @escaping Acknowledge = { _ in },
        applyRemote: @escaping ApplyRemote = { _ in },
        persistState: @escaping PersistState = { _ in },
        requeueForRecovery: @escaping @Sendable () async throws -> Void = {},
        resetSyncStateForRecovery: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.makeTransport = makeTransport
        self.pendingMutations = pendingMutations
        self.acknowledge = acknowledge
        self.applyRemote = applyRemote
        self.persistState = persistState
        self.requeueForRecovery = requeueForRecovery
        self.resetSyncStateForRecovery = resetSyncStateForRecovery
    }

    func installStatusObserver(_ observer: @escaping @Sendable (MacPinnedSyncStatus) async -> Void) async {
        statusObserver = observer
        await observer(status)
    }

    func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            desiredEnabled = true
            try await startEnabledSession()
        } else {
            await disableTransport()
        }
    }

    func keepLocalAndDisable() async {
        guard status == .recoveryRequired || recoveryInProgress else { return }
        await disableTransport()
    }

    func reuploadLocalPins() async throws {
        guard status == .recoveryRequired,
              let incidentEpoch = recoveryIncidentEpoch,
              incidentEpoch == sessionEpoch,
              !recoveryInProgress
        else { return }
        recoveryInProgress = true
        defer { recoveryInProgress = false }
        do {
            try await requeueForRecovery()
            guard recoveryIsCurrent(incidentEpoch) else { return }
            try await resetSyncStateForRecovery()
            guard recoveryIsCurrent(incidentEpoch) else { return }
            try await startEnabledSession(recoveryIncidentEpoch: incidentEpoch)
        } catch {
            guard recoveryIsCurrent(incidentEpoch) else { throw error }
            await updateStatus(.recoveryRequired)
            throw error
        }
    }

    private func startEnabledSession(recoveryIncidentEpoch allowedIncident: UInt64? = nil) async throws {
        if let allowedIncident {
            guard recoveryIsCurrent(allowedIncident) else { return }
        } else {
            guard transport == nil, status != .recoveryRequired else { return }
        }
        let newTransport = try makeTransport()
        sessionEpoch &+= 1
        let epoch = sessionEpoch
        transport = newTransport
        recoveryIncidentEpoch = nil
        await updateStatus(.pending)
        var didStart = false
        do {
            guard epoch == sessionEpoch, transport != nil else { return }
            try await newTransport.start { [weak self] event in
                await self?.handle(event, epoch: epoch)
            }
            didStart = true
            guard epoch == sessionEpoch, transport != nil else {
                await newTransport.cancel()
                return
            }
            try await newTransport.fetch()
            await fetchCompleted(epoch: epoch)
            try await sendPending(using: newTransport, epoch: epoch)
        } catch {
            guard epoch == sessionEpoch else { throw error }
            if Self.isAccountUnavailable(error) {
                transport = nil
                await updateStatus(.accountUnavailable)
                await newTransport.cancel()
            } else if error is MacSyncStateStoreError {
                transport = nil
                recoveryIncidentEpoch = sessionEpoch
                await updateStatus(.recoveryRequired)
                await newTransport.cancel()
            } else {
                if !didStart {
                    transport = nil
                    await newTransport.cancel()
                }
                await updateStatus(.pending)
            }
            throw error
        }
    }

    private func disableTransport() async {
        desiredEnabled = false
        sessionEpoch &+= 1
        let oldTransport = transport
        transport = nil
        drainTask?.cancel()
        drainTask = nil
        drainDirty = false
        seenFetchedMutationIDs.removeAll()
        applyingFetchedMutationIDs.removeAll()
        recoveryIncidentEpoch = nil
        recoveryInProgress = false
        await updateStatus(.disabled)
        await oldTransport?.cancel()
        await waitForEventOperationsToFinish()
    }

    func localJournalDidChange() {
        scheduleDrain()
    }

    func refresh() async throws {
        guard desiredEnabled else { return }
        guard let transport else {
            guard status == .pending else { return }
            try await startEnabledSession()
            return
        }
        let epoch = sessionEpoch
        do {
            try await transport.fetch()
            guard epoch == sessionEpoch, self.transport != nil else { return }
            await fetchCompleted(epoch: epoch)
        } catch {
            guard epoch == sessionEpoch, self.transport != nil else { throw error }
            if Self.isAccountUnavailable(error) {
                await stopTransport(with: .accountUnavailable)
            } else {
                await updateStatus(.pending)
            }
            throw error
        }
    }

    private func scheduleDrain() {
        guard transport != nil else { return }
        guard !sendInProgress else {
            drainDirty = true
            return
        }
        guard drainTask == nil else {
            drainDirty = true
            return
        }
        let epoch = sessionEpoch
        drainTask = Task { [weak self] in await self?.drain(epoch: epoch) }
    }

    private func drain(epoch: UInt64) async {
        defer {
            if epoch == sessionEpoch {
                drainTask = nil
            }
        }
        guard let transport, epoch == sessionEpoch else { return }
        do {
            repeat {
                drainDirty = false
                try await sendPending(using: transport, epoch: epoch)
            } while drainDirty && epoch == sessionEpoch && self.transport != nil
        } catch {
            guard epoch == sessionEpoch, self.transport != nil else { return }
            if Self.isAccountUnavailable(error) {
                await stopTransport(with: .accountUnavailable)
            } else {
                await updateStatus(.pending)
            }
        }
    }

    private func sendPending(using transport: any MacPinnedSyncTransport, epoch: UInt64) async throws {
        guard epoch == sessionEpoch, self.transport != nil else { return }
        guard !sendInProgress else {
            drainDirty = true
            return
        }
        sendInProgress = true
        defer {
            sendInProgress = false
            if drainDirty, drainTask == nil, epoch == sessionEpoch, self.transport != nil {
                scheduleDrain()
            }
        }
        let mutations = try await pendingMutations()
        guard epoch == sessionEpoch, self.transport != nil, !mutations.isEmpty else { return }
        try await transport.send(mutations)
    }

    private func fetchCompleted(epoch: UInt64) async {
        guard epoch == sessionEpoch, transport != nil else { return }
        do {
            let isEmpty = try await pendingMutations().isEmpty
            guard epoch == sessionEpoch, transport != nil else { return }
            await updateStatus(isEmpty ? .synced : .pending)
        } catch {
            guard epoch == sessionEpoch, transport != nil else { return }
            await updateStatus(.pending)
        }
    }

    private func handle(_ event: MacPinnedSyncEvent, epoch: UInt64) async {
        guard epoch == sessionEpoch, transport != nil else { return }
        do {
            switch event {
            case let .stateUpdate(data):
                try await withEventLease { try await persistState(data) }
            case let .fetched(mutation):
                guard !seenFetchedMutationIDs.contains(mutation.mutationID),
                      applyingFetchedMutationIDs.insert(mutation.mutationID).inserted
                else { return }
                defer { applyingFetchedMutationIDs.remove(mutation.mutationID) }
                try await withEventLease { try await applyRemote(mutation) }
                guard epoch == sessionEpoch, transport != nil else { return }
                seenFetchedMutationIDs.insert(mutation.mutationID)
            case .fetchCompleted:
                await fetchCompleted(epoch: epoch)
            case let .sent(ids):
                try await withEventLease { try await acknowledge(ids) }
                guard epoch == sessionEpoch, transport != nil else { return }
                let isEmpty = try await pendingMutations().isEmpty
                guard epoch == sessionEpoch, transport != nil else { return }
                await updateStatus(isEmpty ? .synced : .pending)
            case .retryableFailure:
                await updateStatus(.pending)
            case .terminalFailure:
                await updateStatus(.unableToSyncFullItem)
            case .accountUnavailable:
                await stopTransport(with: .accountUnavailable, insideEventCallback: true)
            case .accountChanged:
                await stopTransport(with: .recoveryRequired, insideEventCallback: true)
            }
        } catch {
            guard epoch == sessionEpoch, transport != nil else { return }
            await updateStatus(.pending)
        }
    }

    /// `insideEventCallback` must be true whenever this runs inside a transport event
    /// callback. Cancelling re-enters CKSyncEngine, and doing that while it is delivering
    /// an event trips a CloudKit assertion and traps the process.
    ///
    /// Deferring the cancel into an unstructured `Task` does not avoid that: the task
    /// inherits this actor and becomes runnable the moment the actor next suspends, which
    /// happens while the delegate's `handleEvent` is still unwound. Nothing in Swift
    /// orders a task after a callback frame the caller owns, so on this path we do not
    /// cancel at all. Bumping the epoch, clearing `transport`, and clearing the delegate
    /// already fence off every later event, and none of them re-enter CKSyncEngine.
    ///
    /// The accepted cost: the old CKSyncEngine keeps its in-flight operations until it
    /// deallocates. They target an account that has just gone away, and no event they
    /// produce can reach us once the delegate is cleared.
    private func stopTransport(with newStatus: MacPinnedSyncStatus, insideEventCallback: Bool = false) async {
        let oldTransport = transport
        sessionEpoch &+= 1
        transport = nil
        drainTask?.cancel()
        drainTask = nil
        drainDirty = false
        seenFetchedMutationIDs.removeAll()
        applyingFetchedMutationIDs.removeAll()
        recoveryInProgress = false
        recoveryIncidentEpoch = newStatus == .recoveryRequired ? sessionEpoch : nil
        await updateStatus(newStatus)
        if insideEventCallback {
            await oldTransport?.releaseWithoutCancelling()
        } else {
            await oldTransport?.cancel()
        }
        await waitForEventOperationsToFinish()
    }

    private func recoveryIsCurrent(_ incidentEpoch: UInt64) -> Bool {
        status == .recoveryRequired && recoveryIncidentEpoch == incidentEpoch && sessionEpoch == incidentEpoch
    }

    private static func isAccountUnavailable(_ error: Error) -> Bool {
        if error is MacPinnedSyncStartError || error is MacPinnedSyncTransportError {
            return true
        }
        return (error as? CKError)?.code == .notAuthenticated
    }

    private func updateStatus(_ newStatus: MacPinnedSyncStatus) async {
        status = newStatus
        await statusObserver?(newStatus)
    }

    private func withEventLease<T>(_ operation: () async throws -> T) async throws -> T {
        activeEventOperationCount += 1
        defer {
            activeEventOperationCount -= 1
            if activeEventOperationCount == 0 {
                let waiters = eventIdleWaiters
                eventIdleWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
        return try await operation()
    }

    private func waitForEventOperationsToFinish() async {
        guard activeEventOperationCount > 0 else { return }
        await withCheckedContinuation { eventIdleWaiters.append($0) }
    }
}
