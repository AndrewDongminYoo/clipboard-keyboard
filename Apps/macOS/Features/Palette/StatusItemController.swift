import AppKit

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let panelController: PalettePanelController

    init(panelController: PalettePanelController) {
        self.panelController = panelController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clipboard Keyboard")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            showMenu()
        } else {
            panelController.toggle()
        }
    }

    /// The app is `LSUIElement`, so it has no Dock icon and no application menu.
    /// Without this the only way to quit is Activity Monitor, which is how the first
    /// device pass ended.
    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Quit Clipboard Keyboard",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}
