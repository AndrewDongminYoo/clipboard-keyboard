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
        statusItem.button?.action = #selector(togglePalette)
    }

    @objc private func togglePalette() {
        panelController.toggle()
    }
}
