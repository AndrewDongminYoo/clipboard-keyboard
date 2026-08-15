import Foundation
import XCTest

@MainActor
final class ShareTargetSmokeTests: XCTestCase {
    func testShareExtensionUsesFunctionalExactOneAllowedPlainTextOrWebURLActivationRule() throws {
        let extensionInfo = try generatedExtensionInfo(named: "ClipboardKeyboardShare")
        let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
        let rule = try XCTUnwrap(attributes["NSExtensionActivationRule"] as? String)

        XCTAssertEqual(extensionInfo["NSExtensionPointIdentifier"] as? String, "com.apple.share-services")
        XCTAssertFalse(rule.contains("TRUEPREDICATE"))
        XCTAssertFalse(rule.contains("FALSEPREDICATE"))
        XCTAssertTrue(rule.contains("== \"public.utf8-plain-text\""))
        XCTAssertTrue(rule.contains("== \"public.utf16-external-plain-text\""))
        XCTAssertTrue(rule.contains("== \"public.utf16-plain-text\""))
        XCTAssertTrue(rule.contains("== \"public.plain-text\""))
        XCTAssertTrue(rule.contains("== \"public.url\""))
        XCTAssertTrue(rule.contains("UTI-CONFORMS-TO \"public.file-url\""))
        XCTAssertTrue(rule.contains("UTI-CONFORMS-TO \"public.image\""))
        XCTAssertTrue(rule.contains("$item.attachments.@count == 1"))
    }

    func testActivationRuleAcceptsOneAllowedSemanticTypeAndRejectsBroadRichFileImageAndMultipleInputs() throws {
        let extensionInfo = try generatedExtensionInfo(named: "ClipboardKeyboardShare")
        let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
        let rule = try XCTUnwrap(attributes["NSExtensionActivationRule"] as? String)
        let predicate = NSPredicate(format: rule)

        for allowedType in [
            "public.utf8-plain-text",
            "public.utf16-external-plain-text",
            "public.utf16-plain-text",
            "public.plain-text",
            "public.url",
        ] {
            XCTAssertTrue(predicate.evaluate(with: activationInput(types: [[allowedType]])))
        }
        XCTAssertFalse(predicate.evaluate(with: activationInput(types: [["public.text"]])))
        XCTAssertFalse(predicate.evaluate(with: activationInput(types: [["public.rtf"]])))
        XCTAssertFalse(predicate.evaluate(with: activationInput(types: [["public.html"]])))
        XCTAssertFalse(predicate.evaluate(with: activationInput(types: [["public.file-url"]])))
        XCTAssertFalse(predicate.evaluate(with: activationInput(types: [["public.jpeg"]])))
        XCTAssertFalse(predicate.evaluate(with: activationInput(types: [["public.file-url", "public.utf8-plain-text"]])))
        XCTAssertFalse(predicate.evaluate(with: activationInput(types: [["public.jpeg", "public.utf8-plain-text"]])))
        XCTAssertFalse(predicate.evaluate(with: activationInput(types: [["public.utf8-plain-text"], ["public.url"]])))
    }

    func testControllerFlattensAllExtensionItemAttachmentsForRuntimeExactOneCheck() throws {
        let first = NSExtensionItem()
        first.attachments = [NSItemProvider(item: "one" as NSString, typeIdentifier: "public.text")]
        let second = NSExtensionItem()
        second.attachments = try [NSItemProvider(item: XCTUnwrap(NSURL(string: "https://example.com")), typeIdentifier: "public.url")]

        let providers = ShareViewController.providers(from: [first, second])

        XCTAssertEqual(providers.count, 2)
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

    private func activationInput(types: [[String]]) -> ShareActivationInput {
        ShareActivationInput(
            extensionItems: [
                ShareActivationItem(
                    attachments: types.map(ShareActivationAttachment.init(registeredTypeIdentifiers:))
                ),
            ]
        )
    }
}

@objcMembers
private final class ShareActivationInput: NSObject {
    let extensionItems: NSArray

    init(extensionItems: [ShareActivationItem]) {
        self.extensionItems = extensionItems as NSArray
    }
}

@objcMembers
private final class ShareActivationItem: NSObject {
    let attachments: NSArray

    init(attachments: [ShareActivationAttachment]) {
        self.attachments = attachments as NSArray
    }
}

@objcMembers
private final class ShareActivationAttachment: NSObject {
    let registeredTypeIdentifiers: NSArray

    init(registeredTypeIdentifiers: [String]) {
        self.registeredTypeIdentifiers = registeredTypeIdentifiers as NSArray
    }
}
