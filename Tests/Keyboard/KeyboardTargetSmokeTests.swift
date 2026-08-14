import Foundation
import XCTest

final class KeyboardTargetSmokeTests: XCTestCase {
    func testKeyboardExtensionDisablesOpenAccess() throws {
        let extensionInfo = try generatedExtensionInfo(named: "ClipboardKeyboardKeyboard")
        let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])

        XCTAssertEqual(extensionInfo["NSExtensionPointIdentifier"] as? String, "com.apple.keyboard-service")
        XCTAssertEqual(attributes["RequestsOpenAccess"] as? Bool, false)
    }

    func testKeyboardHasOnlyExactAppGroupAndNoCloudOrPushEntitlements() throws {
        let keyboard = try entitlements(named: "Extensions/Keyboard/ClipboardKeyboardKeyboard.entitlements")
        let app = try entitlements(named: "Apps/iOS/ClipboardKeyboardiOS.entitlements")

        XCTAssertEqual(keyboard["com.apple.security.application-groups"] as? [String], ["group.kr.donminzzi.clipboardkeyboard"])
        XCTAssertEqual(app["com.apple.security.application-groups"] as? [String], ["group.kr.donminzzi.clipboardkeyboard"])
        XCTAssertEqual(Set(keyboard.keys), Set(["com.apple.security.application-groups"]))
        XCTAssertNil(keyboard["com.apple.developer.icloud-container-identifiers"])
        XCTAssertNil(keyboard["aps-environment"])
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

    private func entitlements(named relativePath: String) throws -> [String: Any] {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: projectRoot.appendingPathComponent(relativePath))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }
}
