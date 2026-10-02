import Foundation
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

/// Per-database query tabs. UI state, not a connection, so it outlives the
/// views that show it: switching tabs or databases keeps your queries.
@MainActor
enum MobileQueryStores {
    private static var stores: [String: PostgresQueryTabsStore] = [:]

    static func store(for profileId: String) -> PostgresQueryTabsStore {
        if let existing = stores[profileId] {
            return existing
        }
        let store = PostgresQueryTabsStore()
        store.openBlankTab()
        stores[profileId] = store
        return store
    }

    /// Drop the queries and results of deleted connections, in step with
    /// the profile store's privacy purge.
    static func retain(only profileIds: Set<String>) {
        stores = stores.filter { profileIds.contains($0.key) }
    }
}
