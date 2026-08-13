@testable import ClipboardKeyboardiOS
import XCTest

final class PhoneTargetSmokeTests: XCTestCase {
    func testAppTargetBundleIdentifier() {
        _ = ClipboardKeyboardApp.self

        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.andrewdongminyoo.clipboardkeyboard.ios")
    }
}
