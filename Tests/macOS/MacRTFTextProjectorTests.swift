@testable import ClipboardKeyboardMac
import Foundation
import XCTest

final class MacRTFTextProjectorTests: XCTestCase {
    func testProjectsCompleteRTFToPlainText() throws {
        let rtf = Data(#"{\rtf1\ansi Hello \b world\b0}"#.utf8)

        let projected = try MacRTFTextProjector().project(rtf)

        XCTAssertEqual(projected, "Hello world")
    }

    func testRejectsMalformedRTF() {
        XCTAssertThrowsError(try MacRTFTextProjector().project(Data("not rtf".utf8))) { error in
            XCTAssertEqual(error as? MacRTFTextProjectorError, .invalidRTF)
        }
    }
}
