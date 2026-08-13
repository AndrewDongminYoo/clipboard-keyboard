import SwiftUI

@main
struct ClipboardKeyboardMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            Text("Clipboard Keyboard")
        }
    }
}
