import AppIntents

struct ClipboardKeyboardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PinTextIntent(),
            phrases: ["Pin text with \(.applicationName)"],
            shortTitle: "Pin Text",
            systemImageName: "pin.fill"
        )
        AppShortcut(
            intent: ExtractValuesIntent(),
            phrases: ["Extract values with \(.applicationName)"],
            shortTitle: "Extract Values",
            systemImageName: "text.viewfinder"
        )
        AppShortcut(
            intent: FindPinnedIntent(),
            phrases: ["Find pinned text with \(.applicationName)"],
            shortTitle: "Find Pinned",
            systemImageName: "magnifyingglass"
        )
    }
}
