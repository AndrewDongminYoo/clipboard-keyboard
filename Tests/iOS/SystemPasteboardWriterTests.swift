@testable import ClipboardKeyboardiOS
import XCTest

@MainActor
final class SystemPasteboardWriterTests: XCTestCase {
    func testWritePassesTheCompleteSelectedStringToTheInjectedWriteOperation() throws {
        var received: String?
        let writer = SystemPasteboardWriter { value in
            received = value
            return true
        }

        try writer.write("계좌 123-456\n끝")

        XCTAssertEqual(received, "계좌 123-456\n끝")
    }

    func testWriteFailureIsReportedWithoutReadingThePasteboard() {
        let writer = SystemPasteboardWriter { _ in false }

        XCTAssertThrowsError(try writer.write("private")) { error in
            XCTAssertEqual(error as? SystemPasteboardWriterError, .writeFailed)
        }
    }
}
