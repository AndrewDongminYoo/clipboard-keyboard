import AppKit
import ClipboardCore
import CryptoKit
import Foundation

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
    private let watcher = PasteboardWatcher()
    private let digestProvider: ((Data) throws -> Data)?

    private init(
        settings: MacSettingsModel,
        shortcut: GlobalPaletteShortcut,
        privateCopyService: PrivateCopyService,
        paletteViewModel: PaletteViewModel,
        historyStore: EncryptedMacClipStore?,
        liveDataSource: LivePaletteDataSource?,
        historyRoot: URL?,
        historyKey: SymmetricKey?,
        digestProvider: ((Data) throws -> Data)?
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
        panelController = PalettePanelController(viewModel: paletteViewModel, settings: settings)
        statusItemController = StatusItemController(panelController: panelController)
        shortcut.setHandler { [weak panelController] in panelController?.toggle() }
        settings.captureConsentChanged = { [weak self] enabled in self?.configureCapture(enabled: enabled) }
        settings.retentionChanged = { [weak self] retention in self?.updateRetention(retention) }
        settings.capturePauseChanged = { [weak self] duration in
            if let duration {
                self?.captureCoordinator?.pauseCapture(for: duration)
            } else {
                self?.captureCoordinator?.resumeCapture()
            }
        }
    }

    static func makeLive() -> MacAppModel {
        let settings = MacSettingsModel()
        let shortcut = GlobalPaletteShortcut()
        let privateCopyService = PrivateCopyService()
        do {
            let key = try MacKeychainMasterKeyStore().loadOrCreateKey()
            let root = try applicationSupportRoot()
            let historyStore = EncryptedMacClipStore(
                rootURL: root.appendingPathComponent("History", isDirectory: true),
                cipher: AESGCMClipCipher(key: key),
                retentionPolicy: RetentionPolicy(maxAge: 24 * 60 * 60, maxUnpinnedCount: 200, historyEnabled: true)
            )
            let pinnedStore = EncryptedMacPinnedStore(
                fileURL: root.appendingPathComponent("Pinned/pinned-replica.encrypted"),
                key: key
            )
            let pinnedLibrary = LocalMacPinnedLibrary(
                store: pinnedStore,
                deviceID: Host.current().localizedName ?? "mac"
            )
            let dataSource = LivePaletteDataSource(historyStore: historyStore, pinnedLibrary: pinnedLibrary)
            let viewModel = PaletteViewModel(
                dataSource: dataSource,
                pasteboardWriter: LivePalettePasteboardWriter(),
                exporter: MacPaletteExporter()
            )
            let digest: (Data) throws -> Data = { data in
                Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
            }
            return MacAppModel(
                settings: settings,
                shortcut: shortcut,
                privateCopyService: privateCopyService,
                paletteViewModel: viewModel,
                historyStore: historyStore,
                liveDataSource: dataSource,
                historyRoot: root.appendingPathComponent("History", isDirectory: true),
                historyKey: key,
                digestProvider: digest
            )
        } catch {
            settings.protectedStorageLocked = true
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
        if !shortcut.registerDefault() {
            privateCopyFallback.shortcutDidConflict()
        }
    }

    func pauseCaptureFor60Seconds() {
        settings.pauseCaptureFor60Seconds()
    }

    private func configureCapture(enabled: Bool) {
        watcher.stop()
        captureCoordinator = nil
        guard enabled, let historyStore, let digestProvider else { return }
        let coordinator = ClipboardCaptureCoordinator(
            pasteboard: MacPasteboardClient(),
            sourceTracker: SourceObservationTracker(),
            policy: .standard(
                consentGranted: true,
                ignoredApplications: Set(settings.ignoredApplications.map(\.identity))
            ),
            envelopeBuilder: MacClipEnvelopeBuilder(digestProvider: digestProvider),
            commit: { envelope in try await historyStore.save(envelope) }
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
        Task { try? await store.applyRetention(now: Date()) }
        configureCapture(enabled: settings.captureConsentGranted)
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
    func export(_ item: PaletteItem) async throws {
        guard let representation = item.representations.first,
              let format = MacClipDocumentFormat.allCases.first(where: { $0.representationKind == representation.kind })
        else { throw MacClipDocumentError.malformedDocument }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Clipboard Item.\(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try MacImportExportController().export(.init(format: format, bytes: representation.originalBytes), to: url)
    }
}
