import ClipboardCore
@testable import ClipboardKeyboardMac
import XCTest

@MainActor
final class MacSettingsTests: XCTestCase {
    func testPrivacyAndSyncDefaultsAreOffAndRetentionIsBounded() {
        let settings = MacSettingsModel()

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
        let settings = MacSettingsModel(now: { now })
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
