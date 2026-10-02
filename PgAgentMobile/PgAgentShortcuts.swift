import AppIntents

// =============================================================================
// PgAgentShortcuts — what Siri, Spotlight and the Shortcuts app offer without
// any setup. Two things worth asking a phone: "are my databases OK?" and
// "take me to one".
// =============================================================================
struct PgAgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckDatabasesIntent(),
            phrases: [
                "Check my databases in \(.applicationName)",
                "How are my databases in \(.applicationName)",
                "Check \(\.$database) in \(.applicationName)",
            ],
            shortTitle: "Check Databases",
            systemImageName: "waveform.path.ecg"
        )
        AppShortcut(
            intent: OpenDatabaseIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Query \(\.$target) in \(.applicationName)",
            ],
            shortTitle: "Open Database",
            systemImageName: "cylinder"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}
