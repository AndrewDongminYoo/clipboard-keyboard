import AppIntents

struct PinTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Pin Text"
    static let description = IntentDescription("Pin explicit text to the protected local library.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Text")
    var text: String

    @Dependency
    private var dependencies: IntentDependencies

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await dependencies.pinText(text)
        return .result(dialog: "Text pinned.")
    }
}
