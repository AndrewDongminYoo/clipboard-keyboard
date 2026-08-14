import AppKit
import ClipboardCore
import Security
import SwiftUI

struct IgnoredApplicationPicker: View {
    @ObservedObject var model: MacSettingsModel

    var body: some View {
        Section("Ignored Applications") {
            ForEach(model.ignoredApplications) { application in
                VStack(alignment: .leading) {
                    Text(application.displayName)
                    Text(application.identity.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Choose Application…", action: chooseApplication)
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier
        else { return }
        guard let identity = verifiedIdentity(at: url, bundleIdentifier: identifier) else { return }
        model.addIgnoredApplication(identity, displayName: url.deletingPathExtension().lastPathComponent)
    }

    private func verifiedIdentity(at url: URL, bundleIdentifier: String) -> ApplicationIdentity? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [CFString: Any],
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String,
              let signingIdentifier = values[kSecCodeInfoIdentifier] as? String,
              !teamIdentifier.isEmpty,
              !signingIdentifier.isEmpty
        else { return nil }
        return ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            signingIdentifier: signingIdentifier
        )
    }
}
