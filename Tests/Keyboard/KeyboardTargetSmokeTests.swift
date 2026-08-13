import Foundation
import XCTest

final class KeyboardTargetSmokeTests: XCTestCase {
    func testKeyboardExtensionDisablesOpenAccess() throws {
        let extensionInfo = try generatedExtensionInfo(named: "ClipboardKeyboardKeyboard")
        let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])

        XCTAssertEqual(extensionInfo["NSExtensionPointIdentifier"] as? String, "com.apple.keyboard-service")
        XCTAssertEqual(attributes["RequestsOpenAccess"] as? Bool, false)
    }

    private func generatedExtensionInfo(named targetName: String) throws -> [String: Any] {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = projectRoot.appendingPathComponent("ClipboardKeyboard.xcodeproj/Generated/\(targetName)-Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let root = try XCTUnwrap(plist as? [String: Any])

        return try XCTUnwrap(root["NSExtension"] as? [String: Any])
    }
}
