import ClipboardCore
import Foundation
import XCTest

final class HTMLTextProjectorTests: XCTestCase {
    func testProjectDecodesEntitiesAndUsesDeterministicBlockSeparators() throws {
        let html = "<h1>A &amp; B</h1><p>첫째<br>둘째&nbsp;줄</p><ul><li>하나</li><li>둘</li></ul>"

        let projected = try HTMLTextProjector().project(Data(html.utf8))

        XCTAssertEqual(projected, "A & B\n첫째\n둘째\u{00A0}줄\n하나\n둘")
    }

    func testProjectIgnoresRemoteResourcesAndExecutableContent() throws {
        let html = """
        <html><head>
        <link rel="stylesheet" href="https://invalid.example/style.css">
        <script src="https://invalid.example/run.js">leaked script text</script>
        </head><body><p>Safe</p><img src="https://invalid.example/pixel.png" alt="remote"></body></html>
        """

        let projected = try HTMLTextProjector().project(Data(html.utf8))

        XCTAssertEqual(projected, "Safe")
        XCTAssertFalse(projected.contains("invalid.example"))
        XCTAssertFalse(projected.contains("leaked"))
    }

    func testProjectRejectsInvalidUTF8InsteadOfReturningAPrefix() {
        XCTAssertThrowsError(try HTMLTextProjector().project(Data([0x3C, 0x70, 0x3E, 0xFF])))
    }

    func testProjectDoesNotEndATagAtGreaterThanInsideAQuotedAttribute() throws {
        let projected = try HTMLTextProjector().project(Data(#"<p title="1 > 0">Safe</p>"#.utf8))

        XCTAssertEqual(projected, "Safe")
    }

    func testProjectIgnoresCommentsContainingGreaterThan() throws {
        let projected = try HTMLTextProjector().project(Data("<!-- hidden > leaked --><p>Safe</p>".utf8))

        XCTAssertEqual(projected, "Safe")
    }

    func testProjectTreatsScriptContentsAsRawTextUntilTheMatchingClosingTag() throws {
        let html = "<script><style>nested</style>leaked</script><p>Safe</p>"

        let projected = try HTMLTextProjector().project(Data(html.utf8))

        XCTAssertEqual(projected, "Safe")
    }

    func testProjectDecodesNumericAndCommonNamedEntitiesAndPreservesUnknownNames() throws {
        let html = "&#169; &#x1F642; &copy; &reg; &trade; &ndash; &mdash; &hellip; &lsquo;x&rsquo; &ldquo;y&rdquo; &bull; &euro; &unknown;"

        let projected = try HTMLTextProjector().project(Data(html.utf8))

        XCTAssertEqual(projected, "© 🙂 © ® ™ – — … ‘x’ “y” • € &unknown;")
    }

    func testProjectPreservesMalformedEntityRunsWithinABoundedDuration() throws {
        let html = String(repeating: "&", count: 5000) + ";tail"
        let clock = ContinuousClock()
        let start = clock.now

        let projected = try HTMLTextProjector().project(Data(html.utf8))
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(projected, html)
        XCTAssertLessThan(elapsed, .milliseconds(250))
    }
}
