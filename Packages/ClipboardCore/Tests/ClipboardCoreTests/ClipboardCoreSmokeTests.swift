import ClipboardCore
import XCTest

final class ClipboardCoreSmokeTests: XCTestCase {
    func testModuleNameIsStable() {
        XCTAssertEqual(ClipboardCore.moduleName, "ClipboardCore")
    }
}
