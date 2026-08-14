import ClipboardCore
@testable import ClipboardKeyboardMac
import XCTest

@MainActor
final class PrivateCopyServiceTests: XCTestCase {
    func testSuccessfulTransactionPassesEveryRepresentationAndShowsShieldAfterWrite() throws {
        let source = PrivateCopyPasteboardStub(representations: representations)
        let destination = PrivateCopyPasteboardStub()
        let shield = ShieldSpy(destination: destination)
        let service = PrivateCopyService(destination: destination, shieldPresenter: shield)

        try service.performPrivateCopy(from: source)

        XCTAssertEqual(destination.lastWrite?.representations, representations)
        XCTAssertEqual(destination.lastWrite?.marker, PrivateCopyService.markerTypeIdentifier)
        XCTAssertTrue(shield.didShowSuccess)
        XCTAssertTrue(shield.writeWasCompleteWhenShown)
    }

    func testReadAndWriteFailuresNeverShowFalseShield() {
        let readShield = ShieldSpy()
        let readService = PrivateCopyService(
            destination: PrivateCopyPasteboardStub(),
            shieldPresenter: readShield
        )
        XCTAssertThrowsError(try readService.performPrivateCopy(from: PrivateCopyPasteboardStub(readError: .representationReadFailed)))
        XCTAssertFalse(readShield.didShowSuccess)

        let writeShield = ShieldSpy()
        let writeService = PrivateCopyService(
            destination: PrivateCopyPasteboardStub(writeError: .writeFailed),
            shieldPresenter: writeShield
        )
        XCTAssertThrowsError(try writeService.performPrivateCopy(from: PrivateCopyPasteboardStub(representations: representations)))
        XCTAssertFalse(writeShield.didShowSuccess)
    }

    func testUnsupportedServiceAndShortcutConflictExposePauseFallbackDistinctly() {
        let fallback = PrivateCopyFallbackState()

        fallback.serviceWasNotHandled()
        XCTAssertEqual(fallback.message, "Private Copy was not handled")
        XCTAssertEqual(fallback.actionTitle, "Pause Capture for 60 Seconds")
        XCTAssertFalse(fallback.didReportSuccess)

        fallback.shortcutDidConflict()
        XCTAssertEqual(fallback.message, "Private Copy shortcut conflict")
        XCTAssertEqual(fallback.actionTitle, "Pause Capture for 60 Seconds")
        XCTAssertFalse(fallback.didReportSuccess)
    }

    private var representations: [RawTextRepresentation] {
        [
            .init(kind: .plainText, data: Data("plain".utf8), textProjection: "plain"),
            .init(kind: .markdown, data: Data("**markdown**".utf8), textProjection: "**markdown**"),
            .init(kind: .rtf, data: Data("{\\rtf1 rich}".utf8), textProjection: "rich"),
            .init(kind: .html, data: Data("<b>html</b>".utf8), textProjection: nil),
        ]
    }
}

@MainActor
private final class PrivateCopyPasteboardStub: MacPasteboardReading {
    private let representations: [RawTextRepresentation]
    private let readError: MacPasteboardError?
    private let writeError: MacPasteboardError?
    private(set) var lastWrite: (representations: [RawTextRepresentation], marker: String?)?

    init(
        representations: [RawTextRepresentation] = [],
        readError: MacPasteboardError? = nil,
        writeError: MacPasteboardError? = nil
    ) {
        self.representations = representations
        self.readError = readError
        self.writeError = writeError
    }

    func readMetadata() -> MacPasteboardMetadata {
        .init(changeCount: 1, declaredTypeIdentifiers: representations.map { $0.kind.rawValue })
    }

    func readSupportedRepresentations(for _: Int) throws -> [RawTextRepresentation] {
        if let readError {
            throw readError
        }
        return representations
    }

    func writeRepresentations(_ representations: [RawTextRepresentation], marker: String?) throws {
        if let writeError {
            throw writeError
        }
        lastWrite = (representations, marker)
    }
}

@MainActor
private final class ShieldSpy: PrivateCopyShieldPresenting {
    private let destination: PrivateCopyPasteboardStub?
    private(set) var didShowSuccess = false
    private(set) var writeWasCompleteWhenShown = false

    init(destination: PrivateCopyPasteboardStub? = nil) {
        self.destination = destination
    }

    func showPrivateCopySucceeded() {
        didShowSuccess = true
        writeWasCompleteWhenShown = destination?.lastWrite != nil
    }
}
