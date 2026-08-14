import AppKit

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    let model = MacAppModel.makeLive()

    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.servicesProvider = model.privateCopyService
        NSUpdateDynamicServices()
        model.start()
    }
}
