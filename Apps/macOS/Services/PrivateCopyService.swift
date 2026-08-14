import AppKit
import ClipboardCore
import Foundation

@MainActor
protocol PrivateCopyShieldPresenting: AnyObject {
    func showPrivateCopySucceeded()
}

@MainActor
final class MacPrivateCopyShieldPresenter: PrivateCopyShieldPresenting {
    func showPrivateCopySucceeded() {
        let alert = NSAlert()
        alert.messageText = "Private Copy"
        alert.informativeText = "Copied with capture protection"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.beginSheetModalIfPossible()
    }
}

private extension NSAlert {
    func beginSheetModalIfPossible() {
        if let window = NSApplication.shared.keyWindow {
            beginSheetModal(for: window)
        } else {
            runModal()
        }
    }
}

@MainActor
final class PrivateCopyFallbackState: ObservableObject {
    @Published private(set) var message: String?
    let availabilityPrompt = "Private Copy unavailable? Pause Capture for 60 Seconds"
    let actionTitle = "Pause Capture for 60 Seconds"
    @Published private(set) var didReportSuccess = false

    func serviceWasNotHandled() {
        didReportSuccess = false
        message = "Private Copy was not handled"
    }

    func serviceDidFail() {
        didReportSuccess = false
        message = "Private Copy could not complete"
    }

    func shortcutDidConflict() {
        didReportSuccess = false
        message = "Private Copy shortcut conflict"
    }
}

@MainActor
final class PrivateCopyService: NSObject {
    typealias ShieldPresentationScheduler = (@escaping @MainActor () -> Void) -> Void

    static let markerTypeIdentifier = "kr.donminzzi.clipboardkeyboard.private-copy"

    private let destination: any MacPasteboardReading
    private let shieldPresenter: any PrivateCopyShieldPresenting
    private let scheduleShieldPresentation: ShieldPresentationScheduler
    var failureHandler: (@MainActor () -> Void)?

    init(
        destination: any MacPasteboardReading = MacPasteboardClient(),
        shieldPresenter: any PrivateCopyShieldPresenting = MacPrivateCopyShieldPresenter(),
        scheduleShieldPresentation: @escaping ShieldPresentationScheduler = { presentation in
            Task { @MainActor in
                presentation()
            }
        }
    ) {
        self.destination = destination
        self.shieldPresenter = shieldPresenter
        self.scheduleShieldPresentation = scheduleShieldPresentation
    }

    func performPrivateCopy(from source: any MacPasteboardReading) throws {
        do {
            let metadata = source.readMetadata()
            let representations = try source.readSupportedRepresentations(for: metadata.changeCount)
            try destination.writeRepresentations(representations, marker: Self.markerTypeIdentifier)
            scheduleShieldPresentation { [shieldPresenter] in
                shieldPresenter.showPrivateCopySucceeded()
            }
        } catch {
            failureHandler?()
            throw error
        }
    }

    @objc(privateCopy:userData:error:)
    func privateCopy(
        _ pasteboard: NSPasteboard,
        userData _: String?,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        do {
            try performPrivateCopy(from: MacPasteboardClient(pasteboard: pasteboard))
        } catch {
            errorPointer.pointee = "Private Copy could not complete"
        }
    }
}
