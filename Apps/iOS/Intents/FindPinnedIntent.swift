import AppIntents

struct FindPinnedIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Pinned"
    static let description = IntentDescription("Find text in the protected local library.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Query")
    var query: String

    @Parameter(title: "Copy", default: false)
    var copy: Bool

    @Parameter(title: "Result")
    var selectedResult: String?

    @Dependency
    private var dependencies: IntentDependencies

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let outcome = try await dependencies.findPinned(query: query, copy: copy) { choices in
            let labels = choices.map(\.label)
            let selected = try await $selectedResult.requestDisambiguation(
                among: labels,
                dialog: "Choose a pinned item."
            )
            guard let choice = choices.first(where: { $0.label == selected }) else {
                throw ClipboardIntentError.selectionCancelled
            }
            return choice.id
        }
        return .result(
            value: outcome.value,
            dialog: copy ? "Pinned text copied." : "Pinned text found."
        )
    }
}
