import ClipboardCore
import ServiceManagement
import SwiftUI

struct MacRetentionSettings: Equatable, Sendable {
    let maxAgeHours: Int
    let maxItemCount: Int
    let historyEnabled: Bool
}

struct IgnoredApplicationDisplay: Equatable, Sendable, Identifiable {
    var id: ApplicationIdentity {
        identity
    }

    let identity: ApplicationIdentity
    let displayName: String
}

enum MacSettingsError: Error, Equatable {
    case invalidRetention
}

@MainActor
final class MacSettingsModel: ObservableObject {
    @Published var captureConsentGranted = false {
        didSet { captureConsentChanged?(captureConsentGranted) }
    }

    @Published var syncEnabled = false
    @Published private(set) var retention = MacRetentionSettings(maxAgeHours: 24, maxItemCount: 200, historyEnabled: true)
    @Published private(set) var ignoredApplications: [IgnoredApplicationDisplay] = []
    @Published var protectedStorageLocked = false
    @Published var syncPending = false
    @Published var deletionPending = false
    @Published var launchAtLogin = false

    private let now: () -> Date
    private var pauseDeadline: Date?
    var captureConsentChanged: ((Bool) -> Void)?
    var retentionChanged: ((MacRetentionSettings) -> Void)?
    var capturePauseChanged: ((TimeInterval?) -> Void)?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
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
        retentionChanged?(retention)
    }

    func pauseCaptureFor60Seconds() {
        pauseDeadline = now().addingTimeInterval(60)
        capturePauseChanged?(60)
        objectWillChange.send()
    }

    func resumeCapture() {
        pauseDeadline = nil
        capturePauseChanged?(nil)
        objectWillChange.send()
    }

    func addIgnoredApplication(_ identity: ApplicationIdentity, displayName: String) {
        ignoredApplications.removeAll { $0.identity == identity }
        ignoredApplications.append(.init(identity: identity, displayName: displayName))
        ignoredApplications.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        launchAtLogin = enabled
    }
}

struct MacSettingsView: View {
    @ObservedObject var model: MacSettingsModel
    @ObservedObject var shortcut: GlobalPaletteShortcut

    var body: some View {
        Form {
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
                Text(shortcut.conflictMessage ?? "Option-Command-V")
            }
            IgnoredApplicationPicker(model: model)
        }
        .padding()
        .frame(minWidth: 460, minHeight: 420)
    }
}
