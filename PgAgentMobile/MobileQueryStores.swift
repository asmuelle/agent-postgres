import Foundation
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

/// One window's query tabs, per database. UI state, not a connection, so it
/// outlives the views that show it: switching tabs or databases keeps your
/// queries. Each window has its own (two windows on one database don't fight
/// over the same tabs); `MobileContentView` owns it and hands it down as an
/// environment object.
@MainActor
final class MobileQueryStores: ObservableObject {
    private var stores: [String: PostgresQueryTabsStore] = [:]

    func store(for profileId: String) -> PostgresQueryTabsStore {
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
    func retain(only profileIds: Set<String>) {
        stores = stores.filter { profileIds.contains($0.key) }
    }

    /// The window is closing: end every tab's server-side state. Another
    /// window can keep the same connection alive, and an open transaction
    /// (row locks, "idle in transaction") must not outlive the window that
    /// had the only way to roll it back.
    isolated deinit {
        let connections = PostgresConnectionManager.shared.activeConnections
        for (profileId, store) in stores {
            // No connection left: its pool, and every session on it, is gone.
            guard let connectionId = connections[profileId] else { continue }
            for tab in store.tabs {
                Self.endServerState(of: tab, connectionId: connectionId)
            }
        }
    }

    /// Cancel a tab's running statement, close its cursor and release its
    /// session (which rolls back an open transaction).
    static func endServerState(of tab: PostgresQueryTab, connectionId: String) {
        let sessionId = tab.id.uuidString
        let cursorId = tab.lastResult?.cursorId
        let isRunning = if case .running = tab.execState { true } else { false }
        Task {
            if isRunning {
                _ = await BridgeManager.shared.pgCancel(connectionId: connectionId, sessionId: sessionId)
            }
            if let cursorId {
                _ = await BridgeManager.shared.pgCloseQuery(
                    connectionId: connectionId, sessionId: sessionId, cursorId: cursorId
                )
            }
            _ = await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
        }
    }
}
