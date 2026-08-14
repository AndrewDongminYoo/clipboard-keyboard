import SwiftUI

@main
struct ClipboardKeyboardMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            MacSettingsView(
                model: appDelegate.model.settings,
                shortcut: appDelegate.model.shortcut
            )
        }
    }
}
