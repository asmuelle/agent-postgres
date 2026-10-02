import AppIntents
import CoreSpotlight
import os
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// DatabaseEntity — one of your connections, as Siri, Shortcuts and Spotlight
// see it. Name, environment and database name only: never the host, the
// user or credentials.
//
// Spotlight: every connection is indexed (MobileSpotlightIndexer); tapping a
// result runs OpenDatabaseIntent, which opens its Query tab.
// =============================================================================
struct DatabaseEntity: AppEntity, IndexedEntity, Equatable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Database",
        numericFormat: "\(placeholder: .int) databases"
    )
    static let defaultQuery = DatabaseEntityQuery()

    let id: String
    let name: String
    /// "Production · orders"; the environment is left out when unspecified.
    let subtitle: String

    init(profile: PostgresProfile) {
        id = profile.id
        name = profile.name
        let environment = profile.effectiveEnvironment
        subtitle = [environment == .unspecified ? nil : environment.displayName, profile.database]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subtitle)",
            image: .init(systemName: "cylinder")
        )
    }
}

struct DatabaseEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [DatabaseEntity] {
        identifiers
            .compactMap { PostgresProfileStore.shared.profile(withId: $0) }
            .map(DatabaseEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [DatabaseEntity] {
        Self.all().filter { $0.name.localizedStandardContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [DatabaseEntity] {
        Self.all()
    }

    @MainActor
    static func all() -> [DatabaseEntity] {
        PostgresProfileStore.shared.profiles
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(DatabaseEntity.init)
    }
}

/// "Open Flank in pgAgent", and what a Spotlight result for a database runs.
struct OpenDatabaseIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Database"
    static let description = IntentDescription("Opens a database's Query tab in pgAgent.")

    @Parameter(title: "Database")
    var target: DatabaseEntity

    init() {}

    init(database: DatabaseEntity) {
        target = database
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        MobileSystemNavigator.shared.request(.query(profileId: target.id))
        return .result()
    }
}

/// Keeps Spotlight and the Siri phrases in step with your connections:
/// re-indexed whenever one is added, renamed or deleted.
enum MobileSpotlightIndexer {
    private static let logger = Logger(subsystem: "com.mc-ssh", category: "spotlight")

    @MainActor
    static func reindex(_ databases: [DatabaseEntity]) {
        Task {
            let index = CSSearchableIndex.default()
            do {
                try await index.deleteAppEntities(ofType: DatabaseEntity.self)
                try await index.indexAppEntities(databases)
            } catch {
                logger.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        PgAgentShortcuts.updateAppShortcutParameters()
    }
}
