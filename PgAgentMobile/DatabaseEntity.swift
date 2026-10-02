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
///
/// One pass at a time, in order — overlapping passes could put a deleted
/// connection back. Each pass indexes the current set first, then removes
/// only the ones that are gone, so Spotlight is never left empty.
@MainActor
enum MobileSpotlightIndexer {
    private static let logger = Logger(subsystem: "com.mc-ssh", category: "spotlight")
    private static let indexedIdsKey = "spotlight.indexedDatabaseIds"
    private static var lastPass: Task<Void, Never>?

    static func reindex(_ databases: [DatabaseEntity]) {
        let previousPass = lastPass
        lastPass = Task {
            await previousPass?.value
            await index(databases)
        }
        PgAgentShortcuts.updateAppShortcutParameters()
    }

    private static func index(_ databases: [DatabaseEntity]) async {
        let index = CSSearchableIndex.default()
        let current = Set(databases.map(\.id))
        let previous = Set(UserDefaults.standard.stringArray(forKey: indexedIdsKey) ?? [])
        do {
            try await index.indexAppEntities(databases)
            let removed = previous.subtracting(current)
            if !removed.isEmpty {
                try await index.deleteAppEntities(identifiedBy: Array(removed), ofType: DatabaseEntity.self)
            }
            UserDefaults.standard.set(Array(current), forKey: indexedIdsKey)
        } catch {
            logger.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
