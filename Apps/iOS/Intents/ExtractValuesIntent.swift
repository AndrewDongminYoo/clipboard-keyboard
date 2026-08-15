import AppIntents

struct ExtractValuesIntent: AppIntent {
    static let title: LocalizedStringResource = "Extract Values"
    static let description = IntentDescription("Extract values from explicit text.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Text")
    var text: String

    @Dependency
    private var dependencies: IntentDependencies

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let outcome = try await dependencies.extractValues(text)
        return .result(value: outcome.values, dialog: "Values extracted.")
    }
}
