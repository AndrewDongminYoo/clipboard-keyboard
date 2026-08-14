import AppKit
import Combine
import SwiftUI

@MainActor
final class PalettePanelController: NSWindowController {
    private var closeObservation: AnyCancellable?

    init(viewModel: PaletteViewModel, settings: MacSettingsModel) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: PaletteView(model: viewModel, settings: settings))
        super.init(window: panel)
        closeObservation = viewModel.$shouldClose
            .filter { $0 }
            .sink { [weak self] _ in self?.close() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    func toggle() {
        guard let window else { return }
        if window.isVisible {
            close()
        } else {
            window.center()
            showWindow(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKey()
        }
    }
}
