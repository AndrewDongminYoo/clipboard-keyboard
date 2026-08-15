@preconcurrency import AppKit
import ClipboardCore
import CryptoKit
import Foundation
import UniformTypeIdentifiers

@MainActor
protocol MacCaptureWatching: AnyObject {
    func start(poll: @escaping @MainActor () async -> Void)
    func stop()
}

private final class MacPinnedSyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: MacPinnedSyncEngine?

    func install(_ engine: MacPinnedSyncEngine) {
        lock.withLock { self.engine = engine }
    }

    func notify() async {
        let engine: MacPinnedSyncEngine? = lock.withLock { self.engine }
        await engine?.localJournalDidChange()
    }
}

extension PasteboardWatcher: MacCaptureWatching {}

@MainActor
final class MacAppModel: ObservableObject {
    let settings: MacSettingsModel
    let shortcut: GlobalPaletteShortcut
    let privateCopyService: PrivateCopyService
    let privateCopyFallback = PrivateCopyFallbackState()
    let paletteViewModel: PaletteViewModel

    private let panelController: PalettePanelController
    private let statusItemController: StatusItemController
    private var historyStore: EncryptedMacClipStore?
    private let liveDataSource: LivePaletteDataSource?
    private let historyRoot: URL?
    private let historyKey: SymmetricKey?
    private var captureCoordinator: ClipboardCaptureCoordinator?
    private let watcher: any MacCaptureWatching
    private let capturePasteboard: any MacPasteboardReading
    private let sourceTracker: any SourceObservationTracking
    private let now: () -> Date
    private let digestProvider: ((Data) throws -> Data)?
    private let setSyncEnabled: (@Sendable (Bool) async -> Void)?
    private let keepLocalRecovery: (@Sendable () async -> Void)?
    private let reuploadRecovery: (@Sendable () async throws -> Void)?
    private let beforeSyncReconciliation: @MainActor @Sendable () async -> Void
    private var syncReconciliationRevision: UInt64 = 0
    private var syncReconciliationTask: Task<Void, Never>?

    private init(
        settings: MacSettingsModel,
        shortcut: GlobalPaletteShortcut,
        privateCopyService: PrivateCopyService,
        paletteViewModel: PaletteViewModel,
        historyStore: EncryptedMacClipStore?,
        liveDataSource: LivePaletteDataSource?,
        historyRoot: URL?,
        historyKey: SymmetricKey?,
        digestProvider: ((Data) throws -> Data)?,
        watcher: any MacCaptureWatching = PasteboardWatcher(),
        capturePasteboard: any MacPasteboardReading = MacPasteboardClient(),
        sourceTracker: any SourceObservationTracking = SourceObservationTracker(),
        now: @escaping () -> Date = Date.init,
        pinnedSyncEngine: MacPinnedSyncEngine? = nil,
        setSyncEnabled: (@Sendable (Bool) async -> Void)? = nil,
        keepLocalRecovery: (@Sendable () async -> Void)? = nil,
        reuploadRecovery: (@Sendable () async throws -> Void)? = nil,
        beforeSyncReconciliation: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.settings = settings
        self.shortcut = shortcut
        self.privateCopyService = privateCopyService
        self.paletteViewModel = paletteViewModel
        self.historyStore = historyStore
        self.liveDataSource = liveDataSource
        self.historyRoot = historyRoot
        self.historyKey = historyKey
        self.digestProvider = digestProvider
        self.watcher = watcher
        self.capturePasteboard = capturePasteboard
        self.sourceTracker = sourceTracker
        self.now = now
        if let setSyncEnabled {
            self.setSyncEnabled = setSyncEnabled
        } else if let pinnedSyncEngine {
            self.setSyncEnabled = { enabled in try? await pinnedSyncEngine.setEnabled(enabled) }
        } else {
            self.setSyncEnabled = nil
        }
        if let keepLocalRecovery {
            self.keepLocalRecovery = keepLocalRecovery
        } else if let pinnedSyncEngine {
            self.keepLocalRecovery = { await pinnedSyncEngine.keepLocalAndDisable() }
        } else {
            self.keepLocalRecovery = nil
        }
        if let reuploadRecovery {
            self.reuploadRecovery = reuploadRecovery
        } else if let pinnedSyncEngine {
            self.reuploadRecovery = { try await pinnedSyncEngine.reuploadLocalPins() }
        } else {
            self.reuploadRecovery = nil
        }
        self.beforeSyncReconciliation = beforeSyncReconciliation
        panelController = PalettePanelController(viewModel: paletteViewModel, settings: settings, fallback: privateCopyFallback)
        statusItemController = StatusItemController(panelController: panelController)
        shortcut.setHandler { [weak panelController] in panelController?.toggle() }
        settings.captureConsentChanged = { [weak self] enabled in self?.configureCapture(enabled: enabled) }
        settings.retentionChanged = { [weak self] retention in self?.updateRetention(retention) }
        settings.ignoredApplicationsChanged = { [weak self] in
            guard let self else { return }
            self.configureCapture(enabled: self.settings.captureConsentGranted)
        }
        settings.shortcutConflict = { [weak self] in self?.privateCopyFallback.shortcutDidConflict() }
        settings.capturePauseChanged = { [weak self] duration in
            if let duration {
                self?.captureCoordinator?.pauseCapture(for: duration)
            } else {
                self?.captureCoordinator?.resumeCapture()
            }
        }
        privateCopyService.failureHandler = { [weak self] in self?.privateCopyFallback.serviceDidFail() }
        settings.syncEnabledChanged = { [weak self] _ in
            guard let self else { return }
            let revision = self.requestSyncReconciliation()
            guard !self.settings.syncEnabled else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      revision == self.syncReconciliationRevision,
                      !self.settings.syncEnabled,
                      let setSyncEnabled = self.setSyncEnabled
                else { return }
                await setSyncEnabled(false)
            }
        }
        settings.keepLocalRecoveryRequested = { [weak self] in
            await self?.keepLocalRecovery?()
        }
        settings.reuploadRecoveryRequested = { [weak self] in
            try await self?.reuploadRecovery?()
        }
    }

    static func makeLive() -> MacAppModel {
        let settings = MacSettingsModel()
        let shortcut = GlobalPaletteShortcut()
        let privateCopyService = PrivateCopyService()
        do {
            let key = try MacKeychainMasterKeyStore().loadOrCreateKey()
            let root = try applicationSupportRoot()
            let digest: @Sendable (Data) throws -> Data = { data in
                Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
            }
            let retained = settings.retention
            let historyStore = EncryptedMacClipStore(
                rootURL: root.appendingPathComponent("History", isDirectory: true),
                cipher: AESGCMClipCipher(key: key),
                retentionPolicy: RetentionPolicy(
                    maxAge: TimeInterval(retained.maxAgeHours * 3600),
                    maxUnpinnedCount: retained.maxItemCount,
                    historyEnabled: retained.historyEnabled
                )
            )
            let pinnedStore = EncryptedMacPinnedStore(
                fileURL: root.appendingPathComponent("Pinned/pinned-replica.encrypted"),
                key: key
            )
            let syncSignal = MacPinnedSyncSignal()
            let pinnedLibrary = LocalMacPinnedLibrary(
                store: pinnedStore,
                deviceID: Host.current().localizedName ?? "mac",
                notifier: { await syncSignal.notify() }
            )
            let syncStateStore = MacSyncStateStore(
                fileURL: root.appendingPathComponent("CloudKit/sync-state.encrypted"),
                key: key
            )
            let syncEngine = MacPinnedSyncEngine(
                makeTransport: { MacCloudKitTransport(stateStore: syncStateStore) },
                pendingMutations: { try await pinnedStore.load().pendingJournal.pending },
                acknowledge: { ids in
                    try await pinnedStore.transaction { state in
                        var journal = state.pendingJournal
                        journal.acknowledge(mutationIDs: ids)
                        state = PinnedReplicaState(
                            libraryGeneration: state.libraryGeneration,
                            reset: state.reset,
                            primaryRevisions: state.primaryRevisions,
                            conflictCopies: state.conflictCopies,
                            tombstones: state.tombstones,
                            seenMutationIDs: state.seenMutationIDs,
                            pendingJournal: journal
                        )
                    }
                },
                applyRemote: { mutation in _ = try await pinnedLibrary.applyRemote(mutation) },
                requeueForRecovery: {
                    try await pinnedStore.transaction { state in
                        var journal = state.pendingJournal
                        journal.replaceForRecovery(with: state)
                        state = PinnedReplicaState(
                            libraryGeneration: state.libraryGeneration,
                            reset: state.reset,
                            primaryRevisions: state.primaryRevisions,
                            conflictCopies: state.conflictCopies,
                            tombstones: state.tombstones,
                            seenMutationIDs: state.seenMutationIDs,
                            pendingJournal: journal
                        )
                    }
                },
                resetSyncStateForRecovery: { try await syncStateStore.resetForRecovery() }
            )
            Task {
                await syncEngine.installStatusObserver { status in
                    await MainActor.run { settings.syncStatus = status }
                }
            }
            syncSignal.install(syncEngine)
            let dataSource = LivePaletteDataSource(historyStore: historyStore, pinnedLibrary: pinnedLibrary)
            let viewModel = PaletteViewModel(
                dataSource: dataSource,
                pasteboardWriter: LivePalettePasteboardWriter(),
                exporter: MacPaletteExporter(),
                importer: MacPaletteImporter(library: pinnedLibrary, digestProvider: digest),
                sharer: MacPaletteSharer()
            )
            return MacAppModel(
                settings: settings,
                shortcut: shortcut,
                privateCopyService: privateCopyService,
                paletteViewModel: viewModel,
                historyStore: historyStore,
                liveDataSource: dataSource,
                historyRoot: root.appendingPathComponent("History", isDirectory: true),
                historyKey: key,
                digestProvider: digest,
                pinnedSyncEngine: syncEngine
            )
        } catch {
            settings.recordProtectedStorageFailure(error)
            return MacAppModel(
                settings: settings,
                shortcut: shortcut,
                privateCopyService: privateCopyService,
                paletteViewModel: PaletteViewModel(
                    dataSource: LockedPaletteDataSource(),
                    pasteboardWriter: LivePalettePasteboardWriter()
                ),
                historyStore: nil,
                liveDataSource: nil,
                historyRoot: nil,
                historyKey: nil,
                digestProvider: nil
            )
        }
    }

    func start() {
        let configuredShortcut = settings.paletteShortcut
        if !settings.updateShortcut(configuredShortcut, using: shortcut),
           configuredShortcut != .defaultPalette
        {
            _ = settings.updateShortcut(.defaultPalette, using: shortcut)
        }
        configureCapture(enabled: settings.captureConsentGranted)
        if settings.syncEnabled {
            requestSyncReconciliation()
        }
    }

    func pauseCaptureFor60Seconds() {
        settings.pauseCaptureFor60Seconds()
    }

    private func configureCapture(enabled: Bool) {
        watcher.stop()
        captureCoordinator = nil
        guard enabled, settings.retention.historyEnabled, let historyStore, let digestProvider else { return }
        let coordinator = ClipboardCaptureCoordinator(
            pasteboard: capturePasteboard,
            sourceTracker: sourceTracker,
            policy: .standard(
                consentGranted: true,
                ignoredApplications: Set(settings.ignoredApplications.map(\.identity))
            ),
            envelopeBuilder: MacClipEnvelopeBuilder(digestProvider: digestProvider),
            commit: { [weak self] envelope in
                do {
                    try await historyStore.save(envelope)
                    _ = try await historyStore.applyRetention(now: self?.now() ?? Date())
                } catch {
                    self?.settings.recordProtectedStorageFailure(error)
                    throw error
                }
            },
            now: now
        )
        captureCoordinator = coordinator
        let remainingPause = settings.capturePauseSecondsRemaining
        if remainingPause > 0 {
            coordinator.pauseCapture(for: TimeInterval(remainingPause))
        }
        watcher.start { [weak coordinator] in await coordinator?.poll() }
    }

    private func updateRetention(_ retention: MacRetentionSettings) {
        guard let historyRoot, let historyKey, let liveDataSource else { return }
        let store = EncryptedMacClipStore(
            rootURL: historyRoot,
            cipher: AESGCMClipCipher(key: historyKey),
            retentionPolicy: RetentionPolicy(
                maxAge: TimeInterval(retention.maxAgeHours * 60 * 60),
                maxUnpinnedCount: retention.maxItemCount,
                historyEnabled: retention.historyEnabled
            )
        )
        historyStore = store
        liveDataSource.replaceHistoryStore(store)
        Task { [weak self] in
            do {
                _ = try await store.applyRetention(now: self?.now() ?? Date())
            } catch {
                self?.settings.recordProtectedStorageFailure(error)
            }
        }
        configureCapture(enabled: settings.captureConsentGranted)
    }

    static func makeForTesting(
        settings: MacSettingsModel,
        shortcut: GlobalPaletteShortcut,
        privateCopyService: PrivateCopyService,
        paletteViewModel: PaletteViewModel,
        historyStore: EncryptedMacClipStore,
        digestProvider: @escaping (Data) throws -> Data,
        watcher: any MacCaptureWatching,
        capturePasteboard: any MacPasteboardReading,
        sourceTracker: any SourceObservationTracking,
        now: @escaping () -> Date = Date.init,
        setSyncEnabled: (@Sendable (Bool) async -> Void)? = nil,
        keepLocalRecovery: (@Sendable () async -> Void)? = nil,
        reuploadRecovery: (@Sendable () async throws -> Void)? = nil,
        beforeSyncReconciliation: @escaping @MainActor @Sendable () async -> Void = {}
    ) -> MacAppModel {
        MacAppModel(
            settings: settings, shortcut: shortcut, privateCopyService: privateCopyService,
            paletteViewModel: paletteViewModel, historyStore: historyStore, liveDataSource: nil,
            historyRoot: nil, historyKey: nil, digestProvider: digestProvider, watcher: watcher,
            capturePasteboard: capturePasteboard, sourceTracker: sourceTracker, now: now,
            setSyncEnabled: setSyncEnabled, keepLocalRecovery: keepLocalRecovery,
            reuploadRecovery: reuploadRecovery, beforeSyncReconciliation: beforeSyncReconciliation
        )
    }

    @discardableResult
    private func requestSyncReconciliation() -> UInt64 {
        syncReconciliationRevision &+= 1
        let revision = syncReconciliationRevision
        guard setSyncEnabled != nil, syncReconciliationTask == nil else { return revision }
        syncReconciliationTask = Task { @MainActor [weak self] in
            await self?.runSyncReconciliation()
        }
        return revision
    }

    private func runSyncReconciliation() async {
        while true {
            await beforeSyncReconciliation()
            let revision = syncReconciliationRevision
            let enabled = settings.syncEnabled
            guard let setSyncEnabled else {
                syncReconciliationTask = nil
                return
            }
            await setSyncEnabled(enabled)
            guard revision != syncReconciliationRevision else {
                syncReconciliationTask = nil
                return
            }
        }
    }

    private static func applicationSupportRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("ClipboardKeyboard", isDirectory: true)
    }
}

@MainActor
private final class LivePaletteDataSource: PaletteDataSource {
    private var historyStore: EncryptedMacClipStore
    private let pinnedLibrary: LocalMacPinnedLibrary

    init(historyStore: EncryptedMacClipStore, pinnedLibrary: LocalMacPinnedLibrary) {
        self.historyStore = historyStore
        self.pinnedLibrary = pinnedLibrary
    }

    func replaceHistoryStore(_ store: EncryptedMacClipStore) {
        historyStore = store
    }

    func recentItems(matching query: String) async throws -> [ClipEnvelope] {
        _ = try await historyStore.applyRetention(now: Date())
        let metadata = try await historyStore.listMetadata()
        var results: [ClipEnvelope] = []
        for item in metadata {
            if let envelope = try await historyStore.load(id: item.id),
               query.isEmpty || envelope.canonicalInsertionString.localizedCaseInsensitiveContains(query)
            {
                results.append(envelope)
            }
        }
        return results
    }

    func pinnedItems(matching query: String) async throws -> [PinnedRevision] {
        try await pinnedLibrary.search(query, limit: 100)
    }

    func pin(_ payload: PinPayload) async throws {
        _ = try await pinnedLibrary.pin(payload)
    }

    func deleteRecent(id: UUID) async throws {
        try await historyStore.delete(id: id)
    }

    func deletePinned(id: UUID) async throws {
        _ = try await pinnedLibrary.delete(itemID: id)
    }
}

@MainActor
private final class LockedPaletteDataSource: PaletteDataSource {
    func recentItems(matching _: String) async throws -> [ClipEnvelope] {
        throw PersistenceSecurityError.keyUnavailable
    }

    func pinnedItems(matching _: String) async throws -> [PinnedRevision] {
        throw PersistenceSecurityError.keyUnavailable
    }

    func pin(_: PinPayload) async throws {
        throw PersistenceSecurityError.keyUnavailable
    }

    func deleteRecent(id _: UUID) async throws {
        throw PersistenceSecurityError.keyUnavailable
    }

    func deletePinned(id _: UUID) async throws {
        throw PersistenceSecurityError.keyUnavailable
    }
}

@MainActor
private final class LivePalettePasteboardWriter: PalettePasteboardWriting {
    private let pasteboard = MacPasteboardClient()

    func write(_ representations: [ClipRepresentation]) throws {
        let raw = representations.map {
            RawTextRepresentation(kind: $0.kind, data: $0.originalBytes, textProjection: nil)
        }
        try pasteboard.writeRepresentations(raw, marker: nil)
    }
}

@MainActor
private final class MacPaletteExporter: PaletteExporting {
    func export(_ item: PaletteItem, as format: MacClipDocumentFormat) async throws {
        guard let representation = item.representations.first(where: { $0.kind == format.representationKind })
        else { throw MacClipDocumentError.malformedDocument }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Clipboard Item.\(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try MacImportExportController().export(.init(format: format, bytes: representation.originalBytes), to: url)
    }
}

@MainActor
protocol MacImportSelecting: AnyObject {
    func selectURL(allowedContentTypes: [UTType]) -> URL?
}

@MainActor
private final class OpenPanelMacImportSelector: MacImportSelecting {
    func selectURL(allowedContentTypes: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = allowedContentTypes
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

@MainActor
final class MacPaletteImporter: PaletteImporting {
    private let library: any PinnedLibrary
    private let controller: MacImportExportController
    private let selector: any MacImportSelecting

    init(
        library: any PinnedLibrary,
        digestProvider: @escaping @Sendable (Data) throws -> Data,
        selector: any MacImportSelecting = OpenPanelMacImportSelector()
    ) {
        self.library = library
        controller = MacImportExportController(digestProvider: digestProvider)
        self.selector = selector
    }

    func importAndPin() async throws -> PaletteImportOutcome {
        guard let url = selector.selectURL(allowedContentTypes: [
            .plainText,
            UTType("net.daringfireball.markdown")!,
            .rtf,
            .html,
        ]),
            let format = Self.documentFormat(forPathExtension: url.pathExtension)
        else { return .cancelled }
        let document = try controller.importDocument(at: url, as: format)
        _ = try await controller.pinImportedDocument(document, title: "Imported Clipboard Item", using: library)
        return .imported
    }

    private static func documentFormat(forPathExtension pathExtension: String) -> MacClipDocumentFormat? {
        switch pathExtension.lowercased() {
        case "txt", "text":
            .txt
        case "md", "markdown":
            .md
        case "rtf":
            .rtf
        case "html", "htm":
            .html
        default:
            nil
        }
    }
}

@MainActor
enum MacSharePickerOutcome: Equatable, Sendable {
    case shared
    case cancelled
    case failed
}

@MainActor
protocol MacSharePickerPresenting: AnyObject {
    func present(url: URL, completion: @escaping @MainActor (MacSharePickerOutcome) -> Void)
}

@MainActor
private final class AppKitMacSharePicker: NSObject, MacSharePickerPresenting,
    @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate
{
    private var picker: NSSharingServicePicker?
    private var completion: (@MainActor (MacSharePickerOutcome) -> Void)?

    func present(url: URL, completion: @escaping @MainActor (MacSharePickerOutcome) -> Void) {
        guard let view = NSApplication.shared.keyWindow?.contentView else {
            completion(.failed)
            return
        }
        self.completion = completion
        let picker = NSSharingServicePicker(items: [url])
        self.picker = picker
        picker.delegate = self
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(_: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard let service else {
            finish(.cancelled)
            return
        }
        service.delegate = self
    }

    func sharingService(_: NSSharingService, didShareItems _: [Any]) {
        finish(.shared)
    }

    func sharingService(_: NSSharingService, didFailToShareItems _: [Any], error _: any Error) {
        finish(.failed)
    }

    private func finish(_ outcome: MacSharePickerOutcome) {
        let completion = completion
        self.completion = nil
        picker = nil
        completion?(outcome)
    }
}

private enum MacPaletteShareError: Error {
    case failed
}

@MainActor
final class MacPaletteSharer: PaletteSharing {
    private let controller: MacImportExportController
    private let picker: any MacSharePickerPresenting
    private var temporaryURL: URL?
    private var sessionID: UUID?
    private var startupCleanupPending = false

    init(
        controller: MacImportExportController = MacImportExportController(),
        picker: any MacSharePickerPresenting = AppKitMacSharePicker()
    ) {
        self.controller = controller
        self.picker = picker
        do {
            try controller.scavengeTemporaryExports()
        } catch {
            startupCleanupPending = true
        }
    }

    func share(
        _ item: PaletteItem,
        as format: MacClipDocumentFormat,
        completion: @escaping @MainActor (Result<PaletteShareOutcome, any Error>) -> Void
    ) throws {
        guard sessionID == nil else { throw MacPaletteShareError.failed }
        guard let representation = item.representations.first(where: { $0.kind == format.representationKind })
        else { throw MacClipDocumentError.malformedDocument }
        try retryStartupCleanupIfNeeded()
        try cleanupOwnedTemporaryFile()
        let url = try controller.prepareTemporaryExport(.init(format: format, bytes: representation.originalBytes))
        let sessionID = UUID()
        temporaryURL = url
        self.sessionID = sessionID
        picker.present(url: url) { [weak self] outcome in
            guard let self, self.sessionID == sessionID else { return }
            self.sessionID = nil
            do {
                try self.cleanupOwnedTemporaryFile()
                switch outcome {
                case .shared:
                    completion(.success(.shared))
                case .cancelled:
                    completion(.success(.cancelled))
                case .failed:
                    completion(.failure(MacPaletteShareError.failed))
                }
            } catch {
                completion(.failure(MacPaletteShareError.failed))
            }
        }
    }

    private func retryStartupCleanupIfNeeded() throws {
        guard startupCleanupPending else { return }
        do {
            try controller.scavengeTemporaryExports()
            startupCleanupPending = false
        } catch {
            throw MacPaletteShareError.failed
        }
    }

    private func cleanupOwnedTemporaryFile() throws {
        if let temporaryURL {
            try controller.cancelTemporaryExport(temporaryURL)
            self.temporaryURL = nil
        }
    }

    deinit {
        if let temporaryURL {
            try? controller.cancelTemporaryExport(temporaryURL)
        }
    }
}
