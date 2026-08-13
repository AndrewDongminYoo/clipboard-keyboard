import ClipboardCore
import XCTest

final class PrivacyGateTests: XCTestCase {
    func testEvaluateDropsBeforeReadForEachPrivacyPrecedenceRule() throws {
        let stableSource = SourceObservation(
            identity: ApplicationIdentity(
                bundleIdentifier: "com.example.editor",
                teamIdentifier: "TEAM123",
                signingIdentifier: "com.example.editor"
            ),
            confidence: .inferredStableForeground
        )
        let ignoredSource = SourceObservation(
            identity: ApplicationIdentity(
                bundleIdentifier: "com.example.ignored",
                teamIdentifier: "TEAM123",
                signingIdentifier: "com.example.ignored"
            ),
            confidence: .inferredStableForeground
        )
        let policy = try CapturePolicy.standard(
            consentGranted: true,
            ignoredApplications: [XCTUnwrap(ignoredSource.identity)]
        )
        let cases: [(name: String, metadata: PasteboardEventMetadata, policy: CapturePolicy, expected: PrivacyDecision)] = [
            (
                "consent not granted",
                metadata(changeCount: 1, source: stableSource),
                CapturePolicy.standard(consentGranted: false, ignoredApplications: []),
                .drop(.consentNotGranted)
            ),
            (
                "Private Copy marker",
                metadata(
                    changeCount: 2,
                    types: ["public.utf8-plain-text", "com.andrewdongminyoo.clipboardkeyboard.private-copy"],
                    source: stableSource
                ),
                policy,
                .drop(.privateCopyMarker)
            ),
            (
                "confidential marker before a supported text declaration",
                metadata(
                    changeCount: 3,
                    types: ["public.utf8-plain-text", "com.agilebits.onepassword"],
                    source: .init(identity: nil, confidence: .unknown)
                ),
                policy,
                .drop(.confidentialType)
            ),
            (
                "capture pause",
                metadata(changeCount: 4, source: stableSource, capturePauseActive: true),
                policy,
                .drop(.capturePaused)
            ),
            (
                "unknown source",
                metadata(changeCount: 5, source: .init(identity: nil, confidence: .unknown)),
                policy,
                .drop(.unknownSource)
            ),
            (
                "verified ignored application",
                metadata(changeCount: 6, source: ignoredSource),
                policy,
                .drop(.ignoredApplication)
            ),
            (
                "unsupported declaration",
                metadata(changeCount: 7, types: ["public.jpeg"], source: stableSource),
                policy,
                .drop(.unsupportedPrimaryTextType)
            ),
            (
                "stable foreground text",
                metadata(changeCount: 8, source: stableSource),
                policy,
                .authorizeRead(changeCount: 8)
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                PrivacyGate().evaluate(testCase.metadata, policy: testCase.policy),
                testCase.expected,
                testCase.name
            )
        }
    }

    private func metadata(
        changeCount: Int,
        types: [String] = ["public.utf8-plain-text"],
        source: SourceObservation,
        capturePauseActive: Bool = false
    ) -> PasteboardEventMetadata {
        PasteboardEventMetadata(
            changeCount: changeCount,
            declaredTypeIdentifiers: types,
            source: source,
            capturePauseActive: capturePauseActive
        )
    }
}
