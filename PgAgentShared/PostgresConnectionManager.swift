import Combine
import Foundation
import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresConnectionManager — centralized singleton for live connection IDs
// and PgSchemaStore caches across all PostgresProfiles in the application.
// =============================================================================
@MainActor
final class PostgresConnectionManager: ObservableObject {
    static let shared = PostgresConnectionManager()

    @Published private(set) var activeConnections: [String: String] = [:] // profileId -> connectionId
    @Published private(set) var schemaStores: [String: PgSchemaStore] = [:] // profileId -> PgSchemaStore
    @Published private(set) var connectionErrors: [String: String] = [:] // profileId -> errorMsg
    @Published private(set) var isConnecting: [String: Bool] = [:] // profileId -> Bool

    private var storeSubscriptions: [String: AnyCancellable] = [:]

    /// Live consumers per profile (views that need the connection while
    /// visible). The pool is closed automatically when the last consumer
    /// releases, so a profile's connection lives exactly as long as some UI
    /// shows it — the fix for connections that were previously never freed.
    private var refCounts: [String: Int] = [:]

    private init() {}

    // MARK: - Reference-counted ownership

    /// Register a consumer that needs `profile` connected while it is visible,
    /// connecting if this is the first consumer. Balance every call with
    /// exactly one `release(profileId:)` when the consumer goes away.
    func acquire(profile: PostgresProfile) async {
        refCounts[profile.id, default: 0] += 1
        await connectIfNeeded(profile: profile)
    }

    /// Drop a consumer's claim; closes the pool once the last consumer is gone.
    /// Safe to call for a profile with no outstanding claim (no-op).
    func release(profileId: String) {
        guard let count = refCounts[profileId] else { return }
        if count <= 1 {
            refCounts.removeValue(forKey: profileId)
            Task { await disconnect(profileId: profileId) }
        } else {
            refCounts[profileId] = count - 1
        }
    }

    /// Close every open connection (e.g. an explicit "disconnect all", app
    /// teardown). Clears consumer claims too.
    func disconnectAll() async {
        refCounts.removeAll()
        for profileId in Array(activeConnections.keys) {
            await disconnect(profileId: profileId)
        }
    }

    func connectIfNeeded(profile: PostgresProfile) async {
        if activeConnections[profile.id] != nil || isConnecting[profile.id] == true { return }
        isConnecting[profile.id] = true
        connectionErrors[profile.id] = nil
        PostgresConnectionStatusStore.shared.markConnecting(profileId: profile.id)

        do {
            let id = try await BridgeManager.shared.pgConnect(profile: profile)
            activeConnections[profile.id] = id
            
            let store = PgSchemaStore(connectionId: id)
            schemaStores[profile.id] = store
            
            // Forward change events from the schema store so views observing the connection manager
            // will automatically re-render when tables/schemas load.
            storeSubscriptions[profile.id] = store.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }

            // Load databases, server-level roles, and tablespaces in parallel
            async let dbsLoad: Void = store.loadDatabases()
            async let rolesLoad: Void = store.loadRoles()
            async let tspacesLoad: Void = store.loadTablespaces()
            _ = await (dbsLoad, rolesLoad, tspacesLoad)

            // Prime active database
            await store.loadSchemas(database: profile.database)

            await PostgresProfileStore.shared.markConnected(profile)
            PostgresConnectionStatusStore.shared.markConnected(profileId: profile.id)
        } catch let err as PostgresBridgeError {
            connectionErrors[profile.id] = err.errorDescription ?? "Connection failed"
            PostgresConnectionStatusStore.shared.markError(
                err.errorDescription ?? "Connection failed",
                profileId: profile.id
            )
        } catch {
            connectionErrors[profile.id] = error.localizedDescription
            PostgresConnectionStatusStore.shared.markError(
                error.localizedDescription,
                profileId: profile.id
            )
        }
        isConnecting[profile.id] = false
    }

    func disconnect(profileId: String) async {
        // Closes the connection *now* without touching consumer claims: a
        // manual "Disconnect" button while the workspace is still on screen
        // leaves its claim intact, so a later Connect → navigate-away still
        // balances to a single release. Claims are owned solely by
        // acquire/release/disconnectAll.
        storeSubscriptions.removeValue(forKey: profileId)
        schemaStores.removeValue(forKey: profileId)
        
        if let connectionId = activeConnections[profileId] {
            await BridgeManager.shared.pgDisconnect(connectionId: connectionId)
            activeConnections.removeValue(forKey: profileId)
        }
        
        connectionErrors.removeValue(forKey: profileId)
        isConnecting.removeValue(forKey: profileId)
        PostgresConnectionStatusStore.shared.markDisconnected(profileId: profileId)
    }

    func refreshAll(profile: PostgresProfile) async {
        guard let store = schemaStores[profile.id] else { return }
        store.invalidate(database: profile.database)
        
        async let dbsLoad: Void = store.loadDatabases()
        async let rolesLoad: Void = store.loadRoles()
        async let tspacesLoad: Void = store.loadTablespaces()
        _ = await (dbsLoad, rolesLoad, tspacesLoad)
        
        await store.loadSchemas(database: profile.database)
    }
}
