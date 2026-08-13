@testable import ClipboardKeyboardMac
import XCTest

final class MacTargetSmokeTests: XCTestCase {
    func testAppTargetBundleIdentifier() {
        XCTAssertEqual(Bundle(for: MacAppDelegate.self).bundleIdentifier, "com.andrewdongminyoo.clipboardkeyboard.mac")
    }
}
