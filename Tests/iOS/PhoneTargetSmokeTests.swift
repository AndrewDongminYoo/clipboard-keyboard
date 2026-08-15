@testable import ClipboardKeyboardiOS
import XCTest

final class PhoneTargetSmokeTests: XCTestCase {
    func testAppTargetBundleIdentifier() {
        _ = ClipboardKeyboardApp.self

        XCTAssertEqual(Bundle.main.bundleIdentifier, "kr.donminzzi.clipboardkeyboard.ios")
    }
}
