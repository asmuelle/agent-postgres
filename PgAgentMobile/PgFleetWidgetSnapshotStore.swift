import Foundation

// =============================================================================
// PgFleetWidgetSnapshotStore — where PgFleetWidgetSnapshot lives: one JSON
// file in the App Group container, on the existing SharedJSONFileStore
// (Sources/PgAgentMacOS), which both targets compile.
//
// ⚠️ Dual-target file, like PgFleetWidgetSnapshot.swift: compiled into BOTH
// PgAgentMobile and PgAgentMobileWidgets (explicit entry in project.yml).
// =============================================================================

/// Thin wrapper over the shared App Group JSON store.
final class PgFleetWidgetSnapshotStore: @unchecked Sendable {
    private let store: SharedJSONFileStore<PgFleetWidgetSnapshot>

    init(directoryURL: URL? = nil) {
        store = SharedJSONFileStore(
            fileName: PgFleetWidgetConfiguration.fileName,
            directoryURL: directoryURL
        )
    }

    func load() throws -> PgFleetWidgetSnapshot? {
        try store.load()
    }

    func save(_ snapshot: PgFleetWidgetSnapshot) throws {
        try store.save(snapshot)
    }
}
