import ClipboardCore
import ServiceManagement
import SwiftUI

struct MacRetentionSettings: Codable, Equatable, Sendable {
    let maxAgeHours: Int
    let maxItemCount: Int
    let historyEnabled: Bool
}

struct IgnoredApplicationDisplay: Codable, Equatable, Sendable, Identifiable {
    var id: ApplicationIdentity {
        identity
    }

    let identity: ApplicationIdentity
    let displayName: String
}

enum MacSettingsError: Error, Equatable {
    case invalidRetention
}

struct MacPersistedSettings: Codable, Equatable, Sendable {
    var captureConsentGranted = false
    var syncEnabled = false
    var retention = MacRetentionSettings(maxAgeHours: 24, maxItemCount: 200, historyEnabled: true)
    var ignoredApplications: [IgnoredApplicationDisplay] = []
    var paletteShortcut = GlobalShortcutDefinition.defaultPalette
}

protocol MacSettingsPersisting: Sendable {
    func load() throws -> MacPersistedSettings?
    func save(_ settings: MacPersistedSettings) throws
}

struct UserDefaultsMacSettingsStore: MacSettingsPersisting, @unchecked Sendable {
    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = "MacSettings.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> MacPersistedSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(MacPersistedSettings.self, from: data)
    }

    func save(_ settings: MacPersistedSettings) throws {
        try defaults.set(JSONEncoder().encode(settings), forKey: key)
    }
}

@MainActor
protocol MacSettingsTickScheduling: AnyObject {
    func start(_ action: @escaping @MainActor @Sendable () -> Void)
    func cancel()
}

@MainActor
final class TimerMacSettingsTicker: MacSettingsTickScheduling {
    private nonisolated(unsafe) var timer: Timer?
    func start(_ action: @escaping @MainActor @Sendable () -> Void) {
        cancel()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { action() }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }
}

@MainActor
final class MacSettingsModel: ObservableObject {
    @Published var captureConsentGranted = false {
        didSet { persist(); captureConsentChanged?(captureConsentGranted) }
    }

    @Published var syncEnabled = false {
        didSet { persist() }
    }

    @Published private(set) var retention = MacRetentionSettings(maxAgeHours: 24, maxItemCount: 200, historyEnabled: true)
    @Published private(set) var ignoredApplications: [IgnoredApplicationDisplay] = []
    @Published var protectedStorageLocked = false
    @Published var syncPending = false
    @Published var deletionPending = false
    @Published var launchAtLogin = false
    @Published private(set) var paletteShortcut = GlobalShortcutDefinition.defaultPalette
    @Published private var pauseCountdownTick = 0

    private let now: () -> Date
    private let store: any MacSettingsPersisting
    private let ticker: any MacSettingsTickScheduling
    private var pauseDeadline: Date?
    var captureConsentChanged: ((Bool) -> Void)?
    var retentionChanged: ((MacRetentionSettings) -> Void)?
    var capturePauseChanged: ((TimeInterval?) -> Void)?
    var ignoredApplicationsChanged: (() -> Void)?

    init(
        store: any MacSettingsPersisting = UserDefaultsMacSettingsStore(),
        now: @escaping () -> Date = Date.init,
        ticker: any MacSettingsTickScheduling = TimerMacSettingsTicker()
    ) {
        self.store = store
        self.now = now
        self.ticker = ticker
        do {
            if let persisted = try store.load() {
                captureConsentGranted = persisted.captureConsentGranted
                syncEnabled = persisted.syncEnabled
                retention = persisted.retention
                ignoredApplications = persisted.ignoredApplications
                paletteShortcut = persisted.paletteShortcut
            }
        } catch {
            protectedStorageLocked = true
        }
    }

    var capturePauseSecondsRemaining: Int {
        guard let pauseDeadline else { return 0 }
        return max(0, Int(ceil(pauseDeadline.timeIntervalSince(now()))))
    }

    var statusLabels: [String] {
        var labels: [String] = []
        if capturePauseSecondsRemaining > 0 {
            labels.append("Paused")
            labels.append("Capture Pause Countdown")
        }
        if protectedStorageLocked {
            labels.append("Protected Storage Locked")
        }
        if syncPending {
            labels.append("Sync Pending")
        }
        if deletionPending {
            labels.append("Deletion Pending")
        }
        return labels
    }

    func updateRetention(maxAgeHours: Int, maxItemCount: Int, historyEnabled: Bool) throws {
        if historyEnabled {
            guard (1 ... 24).contains(maxAgeHours), (1 ... 200).contains(maxItemCount) else {
                throw MacSettingsError.invalidRetention
            }
        } else if maxAgeHours != 0 || maxItemCount != 0 {
            throw MacSettingsError.invalidRetention
        }
        retention = .init(maxAgeHours: maxAgeHours, maxItemCount: maxItemCount, historyEnabled: historyEnabled)
        persist()
        retentionChanged?(retention)
    }

    func pauseCaptureFor60Seconds() {
        pauseDeadline = now().addingTimeInterval(60)
        updatePauseCountdown()
        ticker.start { [weak self] in self?.updatePauseCountdown() }
        capturePauseChanged?(60)
    }

    func resumeCapture() {
        pauseDeadline = nil
        pauseCountdownTick = 0
        ticker.cancel()
        capturePauseChanged?(nil)
    }

    func addIgnoredApplication(_ identity: ApplicationIdentity, displayName: String) {
        ignoredApplications.removeAll { $0.identity == identity }
        ignoredApplications.append(.init(identity: identity, displayName: displayName))
        ignoredApplications.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        persist()
        ignoredApplicationsChanged?()
    }

    @discardableResult
    func updateShortcut(_ definition: GlobalShortcutDefinition, using shortcut: GlobalPaletteShortcut) -> Bool {
        guard shortcut.update(to: definition) else { return false }
        paletteShortcut = definition
        persist()
        return true
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        launchAtLogin = enabled
    }

    private func updatePauseCountdown() {
        guard let pauseDeadline else { return }
        let remaining = max(0, Int(ceil(pauseDeadline.timeIntervalSince(now()))))
        pauseCountdownTick = remaining
        if remaining == 0 {
            self.pauseDeadline = nil
            ticker.cancel()
            capturePauseChanged?(nil)
        }
    }

    private func persist() {
        do {
            try store.save(.init(
                captureConsentGranted: captureConsentGranted,
                syncEnabled: syncEnabled,
                retention: retention,
                ignoredApplications: ignoredApplications,
                paletteShortcut: paletteShortcut
            ))
        } catch {
            protectedStorageLocked = true
        }
    }
}

struct MacSettingsView: View {
    @ObservedObject var model: MacSettingsModel
    @ObservedObject var shortcut: GlobalPaletteShortcut

    var body: some View {
        Form {
            if !model.captureConsentGranted {
                MacOnboardingView(settings: model)
            }
            Toggle("Enable Automatic Capture", isOn: $model.captureConsentGranted)
            Toggle("Enable Pinned Sync", isOn: $model.syncEnabled)
            Toggle("Launch at Login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { try? model.setLaunchAtLogin($0) }
            ))
            Section("Privacy") {
                Button("Pause Capture for 60 Seconds") { model.pauseCaptureFor60Seconds() }
                if model.capturePauseSecondsRemaining > 0 {
                    Text("Capture Pause Countdown: \(model.capturePauseSecondsRemaining)s")
                }
                ForEach(model.statusLabels, id: \.self) { Text($0) }
            }
            Section("History") {
                Toggle("Keep Recent History", isOn: Binding(
                    get: { model.retention.historyEnabled },
                    set: { enabled in
                        try? model.updateRetention(
                            maxAgeHours: enabled ? 24 : 0,
                            maxItemCount: enabled ? 200 : 0,
                            historyEnabled: enabled
                        )
                    }
                ))
                if model.retention.historyEnabled {
                    Stepper(
                        "Retention: \(model.retention.maxAgeHours) hours",
                        value: Binding(
                            get: { model.retention.maxAgeHours },
                            set: { try? model.updateRetention(maxAgeHours: $0, maxItemCount: model.retention.maxItemCount, historyEnabled: true) }
                        ),
                        in: 1 ... 24
                    )
                    Stepper(
                        "Limit: \(model.retention.maxItemCount) items",
                        value: Binding(
                            get: { model.retention.maxItemCount },
                            set: { try? model.updateRetention(maxAgeHours: model.retention.maxAgeHours, maxItemCount: $0, historyEnabled: true) }
                        ),
                        in: 1 ... 200
                    )
                }
            }
            Section("Palette Shortcut") {
                ShortcutEditor(model: model, shortcut: shortcut)
                if let conflict = shortcut.conflictMessage {
                    Text(conflict).foregroundStyle(.red)
                }
            }
            IgnoredApplicationPicker(model: model)
        }
        .padding()
        .frame(minWidth: 460, minHeight: 420)
    }
}

private struct ShortcutEditor: View {
    let model: MacSettingsModel
    let shortcut: GlobalPaletteShortcut
    @State private var keyCode: Int = .init(GlobalShortcutDefinition.defaultPalette.keyCode)
    @State private var command = true
    @State private var option = true
    @State private var shift = false
    @State private var control = false

    init(model: MacSettingsModel, shortcut: GlobalPaletteShortcut) {
        self.model = model
        self.shortcut = shortcut
        let definition = model.paletteShortcut
        _keyCode = State(initialValue: .init(definition.keyCode))
        _command = State(initialValue: definition.modifiers.contains(.command))
        _option = State(initialValue: definition.modifiers.contains(.option))
        _shift = State(initialValue: definition.modifiers.contains(.shift))
        _control = State(initialValue: definition.modifiers.contains(.control))
    }

    var body: some View {
        HStack {
            Stepper("Key Code: \(keyCode)", value: $keyCode, in: 0 ... 127)
            Toggle("Command", isOn: $command)
            Toggle("Option", isOn: $option)
            Toggle("Shift", isOn: $shift)
            Toggle("Control", isOn: $control)
            Button("Apply") {
                var modifiers: GlobalShortcutModifiers = []
                if command {
                    modifiers.insert(.command)
                }
                if option {
                    modifiers.insert(.option)
                }
                if shift {
                    modifiers.insert(.shift)
                }
                if control {
                    modifiers.insert(.control)
                }
                _ = model.updateShortcut(.init(keyCode: UInt32(keyCode), modifiers: modifiers), using: shortcut)
            }
        }
    }
}
