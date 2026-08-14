import ClipboardCore
@testable import ClipboardKeyboardMac
import CryptoKit
import XCTest

@MainActor
final class MacSettingsTests: XCTestCase {
    func testPrivacyAndSyncDefaultsAreOffAndRetentionIsBounded() {
        let settings = MacSettingsModel(store: MemoryMacSettingsStore())

        XCTAssertFalse(settings.captureConsentGranted)
        XCTAssertFalse(settings.syncEnabled)
        XCTAssertEqual(settings.retention, .init(maxAgeHours: 24, maxItemCount: 200, historyEnabled: true))
        XCTAssertNoThrow(try settings.updateRetention(maxAgeHours: 1, maxItemCount: 25, historyEnabled: true))
        XCTAssertNoThrow(try settings.updateRetention(maxAgeHours: 0, maxItemCount: 0, historyEnabled: false))
        XCTAssertThrowsError(try settings.updateRetention(maxAgeHours: 25, maxItemCount: 25, historyEnabled: true))
        XCTAssertThrowsError(try settings.updateRetention(maxAgeHours: 1, maxItemCount: 201, historyEnabled: true))
        XCTAssertThrowsError(try settings.updateRetention(maxAgeHours: 0, maxItemCount: 1, historyEnabled: true))
    }

    func testPauseCountdownIgnoredIdentityAndContentFreePendingLabels() {
        var now = Date(timeIntervalSince1970: 1000)
        let settings = MacSettingsModel(store: MemoryMacSettingsStore(), now: { now })
        let identity = ApplicationIdentity(
            bundleIdentifier: "com.example.Editor",
            teamIdentifier: "TEAM",
            signingIdentifier: "com.example.Editor"
        )
        settings.addIgnoredApplication(identity, displayName: "Example Editor")
        settings.pauseCaptureFor60Seconds()

        XCTAssertEqual(settings.capturePauseSecondsRemaining, 60)
        XCTAssertEqual(settings.ignoredApplications.first?.identity, identity)
        XCTAssertEqual(settings.ignoredApplications.first?.displayName, "Example Editor")
        XCTAssertEqual(settings.statusLabels, ["Paused", "Capture Pause Countdown"])

        now.addTimeInterval(60)
        settings.protectedStorageLocked = true
        settings.syncPending = true
        settings.deletionPending = true
        XCTAssertEqual(settings.capturePauseSecondsRemaining, 0)
        XCTAssertEqual(settings.statusLabels, ["Protected Storage Locked", "Sync Pending", "Deletion Pending"])
    }

    func testShortcutConflictDisplaysWithoutReplacingRegistration() {
        let registrar = ShortcutRegistrarStub(results: [.success, .conflict])
        let shortcut = GlobalPaletteShortcut(registrar: registrar)
        XCTAssertEqual(shortcut.current, .defaultPalette)
        XCTAssertEqual(shortcut.current.keyCode, 9)
        XCTAssertEqual(shortcut.current.modifiers, [.command, .option])

        XCTAssertTrue(shortcut.registerDefault())
        let requested = GlobalShortcutDefinition(keyCode: 8, modifiers: [.command, .option])
        XCTAssertFalse(shortcut.update(to: requested))

        XCTAssertEqual(shortcut.current, .defaultPalette)
        XCTAssertEqual(shortcut.conflictMessage, "Shortcut is already in use")
        XCTAssertEqual(registrar.registrations, [.defaultPalette, requested])
    }

    func testPrivacySettingsAndSuccessfulShortcutPersistAcrossRestart() throws {
        let suite = "MacSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsMacSettingsStore(defaults: defaults, key: "settings")
        let identity = ApplicationIdentity(bundleIdentifier: "com.example.Editor", teamIdentifier: "TEAM", signingIdentifier: "editor")
        let first = MacSettingsModel(store: store)
        first.captureConsentGranted = true
        first.syncEnabled = true
        try first.updateRetention(maxAgeHours: 2, maxItemCount: 10, historyEnabled: true)
        first.addIgnoredApplication(identity, displayName: "Editor")
        let registrar = ShortcutRegistrarStub(results: [.success])
        let shortcut = GlobalPaletteShortcut(registrar: registrar)
        XCTAssertTrue(first.updateShortcut(.init(keyCode: 8, modifiers: [.command, .shift]), using: shortcut))

        let restored = MacSettingsModel(store: store)
        XCTAssertTrue(restored.captureConsentGranted)
        XCTAssertTrue(restored.syncEnabled)
        XCTAssertEqual(restored.retention, .init(maxAgeHours: 2, maxItemCount: 10, historyEnabled: true))
        XCTAssertEqual(restored.ignoredApplications.map(\.identity), [identity])
        XCTAssertEqual(restored.paletteShortcut, .init(keyCode: 8, modifiers: [.command, .shift]))
    }

    func testPauseCountdownPublishesTicksAndResumeUpdatesImmediately() {
        var now = Date(timeIntervalSince1970: 1000)
        let ticker = SettingsTickerStub()
        let settings = MacSettingsModel(now: { now }, ticker: ticker)
        settings.pauseCaptureFor60Seconds()
        XCTAssertEqual(settings.capturePauseSecondsRemaining, 60)

        now.addTimeInterval(1)
        ticker.tick()
        XCTAssertEqual(settings.capturePauseSecondsRemaining, 59)
        settings.resumeCapture()
        XCTAssertEqual(settings.capturePauseSecondsRemaining, 0)
        XCTAssertTrue(ticker.didCancel)
    }

    func testHistoryDisabledNeverStartsWatcherOrReadsPayload() async throws {
        let harness = try MacAppHarness(retention: .init(maxAgeHours: 0, maxItemCount: 0, historyEnabled: false))
        harness.settings.captureConsentGranted = true
        await harness.watcher.poll()
        XCTAssertEqual(harness.watcher.startCount, 0)
        XCTAssertEqual(harness.pasteboard.payloadReadCount, 0)
        let metadata = try await harness.store.listMetadata()
        XCTAssertEqual(metadata.count, 0)
    }

    func testEveryAcceptedCaptureEnforcesActiveRetention() async throws {
        let harness = try MacAppHarness(retention: .init(maxAgeHours: 24, maxItemCount: 1, historyEnabled: true))
        harness.settings.captureConsentGranted = true
        harness.pasteboard.changeCount = 1
        await harness.watcher.poll()
        harness.pasteboard.changeCount = 2
        await harness.watcher.poll()
        XCTAssertEqual(harness.pasteboard.payloadReadCount, 2)
        let metadata = try await harness.store.listMetadata()
        XCTAssertEqual(metadata.count, 1)
    }

    func testAddingIgnoredCurrentApplicationRebuildsBeforeNextPollRead() async throws {
        let identity = ApplicationIdentity(bundleIdentifier: "com.example.Current", teamIdentifier: "TEAM", signingIdentifier: "current")
        let harness = try MacAppHarness(retention: .init(maxAgeHours: 24, maxItemCount: 10, historyEnabled: true), identity: identity)
        harness.settings.captureConsentGranted = true
        let startsBeforeIgnore = harness.watcher.startCount
        harness.settings.addIgnoredApplication(identity, displayName: "Current")
        await harness.watcher.poll()
        XCTAssertEqual(harness.watcher.startCount, startsBeforeIgnore + 1)
        XCTAssertEqual(harness.pasteboard.payloadReadCount, 0)
    }

    func testServiceFailureFlowsThroughMacAppCompositionToFallbackAndPauseAction() throws {
        let harness = try MacAppHarness(retention: .init(maxAgeHours: 24, maxItemCount: 10, historyEnabled: true))
        let source = FailingPrivateCopyPasteboard()
        XCTAssertThrowsError(try harness.model.privateCopyService.performPrivateCopy(from: source))
        XCTAssertEqual(harness.model.privateCopyFallback.message, "Private Copy could not complete")
        XCTAssertFalse(harness.model.privateCopyFallback.didReportSuccess)
        harness.model.pauseCaptureFor60Seconds()
        XCTAssertEqual(harness.settings.capturePauseSecondsRemaining, 60)
    }
}

@MainActor
private final class MacAppHarness {
    let settings: MacSettingsModel
    let watcher = CaptureWatcherStub()
    let pasteboard = CapturePasteboardStub()
    let store: EncryptedMacClipStore
    private let root: URL
    private(set) var model: MacAppModel!

    init(retention: MacRetentionSettings, identity: ApplicationIdentity? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MacAppHarness.\(UUID().uuidString)"))
        settings = MacSettingsModel(store: UserDefaultsMacSettingsStore(defaults: defaults, key: "settings"))
        try settings.updateRetention(maxAgeHours: retention.maxAgeHours, maxItemCount: retention.maxItemCount, historyEnabled: retention.historyEnabled)
        store = EncryptedMacClipStore(
            rootURL: root,
            cipher: AESGCMClipCipher(key: SymmetricKey(data: Data(repeating: 2, count: 32))),
            retentionPolicy: .init(
                maxAge: TimeInterval(retention.maxAgeHours * 3600),
                maxUnpinnedCount: retention.maxItemCount,
                historyEnabled: retention.historyEnabled
            )
        )
        let source = CaptureSourceStub(identity: identity ?? .init(
            bundleIdentifier: "com.example.Source", teamIdentifier: "TEAM", signingIdentifier: "source"
        ))
        let shortcut = GlobalPaletteShortcut(registrar: ShortcutRegistrarStub(results: [.success]))
        model = MacAppModel.makeForTesting(
            settings: settings,
            shortcut: shortcut,
            privateCopyService: PrivateCopyService(),
            paletteViewModel: PaletteViewModel(dataSource: EmptyPaletteDataSource(), pasteboardWriter: EmptyPaletteWriter()),
            historyStore: store,
            digestProvider: { _ in Data([1]) },
            watcher: watcher,
            capturePasteboard: pasteboard,
            sourceTracker: source,
            now: Date.init
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class CaptureWatcherStub: MacCaptureWatching {
    private var action: (@MainActor () async -> Void)?
    private(set) var startCount = 0
    func start(poll: @escaping @MainActor () async -> Void) {
        startCount += 1; action = poll
    }

    func stop() {
        action = nil
    }

    func poll() async {
        await action?()
    }
}

@MainActor
private final class CapturePasteboardStub: MacPasteboardReading {
    var changeCount = 1
    private(set) var payloadReadCount = 0
    func readMetadata() -> MacPasteboardMetadata {
        .init(changeCount: changeCount, declaredTypeIdentifiers: ["public.utf8-plain-text"])
    }

    func readSupportedRepresentations(for _: Int) throws -> [RawTextRepresentation] {
        payloadReadCount += 1
        let text = "capture-sentinel-\(changeCount)"
        return [.init(kind: .plainText, data: Data(text.utf8), textProjection: text)]
    }

    func writeRepresentations(_: [RawTextRepresentation], marker _: String?) throws {}
}

@MainActor
private final class CaptureSourceStub: SourceObservationTracking {
    let identity: ApplicationIdentity?
    init(identity: ApplicationIdentity?) {
        self.identity = identity
    }

    func beginInterval() {}
    func finishInterval() -> SourceObservation {
        .init(identity: identity, confidence: identity == nil ? .unknown : .inferredStableForeground)
    }
}

@MainActor
private final class EmptyPaletteDataSource: PaletteDataSource {
    func recentItems(matching _: String) async throws -> [ClipEnvelope] {
        []
    }

    func pinnedItems(matching _: String) async throws -> [PinnedRevision] {
        []
    }

    func pin(_: PinPayload) async throws {}
    func deleteRecent(id _: UUID) async throws {}
    func deletePinned(id _: UUID) async throws {}
}

@MainActor
private final class EmptyPaletteWriter: PalettePasteboardWriting {
    func write(_: [ClipRepresentation]) throws {}
}

@MainActor
private final class FailingPrivateCopyPasteboard: MacPasteboardReading {
    func readMetadata() -> MacPasteboardMetadata {
        .init(changeCount: 1, declaredTypeIdentifiers: [])
    }

    func readSupportedRepresentations(for _: Int) throws -> [RawTextRepresentation] {
        throw MacPasteboardError.representationReadFailed
    }

    func writeRepresentations(_: [RawTextRepresentation], marker _: String?) throws {}
}

@MainActor
private final class SettingsTickerStub: MacSettingsTickScheduling {
    private var action: (@MainActor @Sendable () -> Void)?
    private(set) var didCancel = false
    func start(_ action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    func cancel() {
        didCancel = true; action = nil
    }

    func tick() {
        action?()
    }
}

private final class MemoryMacSettingsStore: @unchecked Sendable, MacSettingsPersisting {
    private var value: MacPersistedSettings?
    func load() throws -> MacPersistedSettings? {
        value
    }

    func save(_ settings: MacPersistedSettings) throws {
        value = settings
    }
}

private final class ShortcutRegistrarStub: @unchecked Sendable, GlobalShortcutRegistering {
    private var results: [GlobalShortcutRegistrationResult]
    private(set) var registrations: [GlobalShortcutDefinition] = []

    init(results: [GlobalShortcutRegistrationResult]) {
        self.results = results
    }

    func register(_ definition: GlobalShortcutDefinition, handler _: @escaping @MainActor @Sendable () -> Void) -> GlobalShortcutRegistrationResult {
        registrations.append(definition)
        return results.removeFirst()
    }

    func unregister() {}
}
