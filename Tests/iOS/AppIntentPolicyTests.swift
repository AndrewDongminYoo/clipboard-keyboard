import AppIntents
@testable import ClipboardKeyboardiOS
import XCTest

final class AppIntentPolicyTests: XCTestCase {
    func testEveryClipboardIntentRequiresLocalDeviceAuthentication() {
        XCTAssertEqual(PinTextIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
        XCTAssertEqual(ExtractValuesIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
        XCTAssertEqual(FindPinnedIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
    }
}
