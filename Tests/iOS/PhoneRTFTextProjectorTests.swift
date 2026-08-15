@testable import ClipboardKeyboardiOS
import UIKit
import XCTest

final class PhoneRTFTextProjectorTests: XCTestCase {
    func testProjectsTheCompleteLocalRTFDocument() throws {
        let source = "첫 줄\nSecond 👋\n끝"
        let attributed = NSAttributedString(string: source)
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )

        XCTAssertEqual(try PhoneRTFTextProjector().project(data), source)
    }

    func testRejectsMalformedRTF() {
        XCTAssertThrowsError(try PhoneRTFTextProjector().project(Data("not rtf".utf8))) { error in
            XCTAssertEqual(error as? PhoneRTFTextProjectorError, .invalidRTF)
        }
    }
}
