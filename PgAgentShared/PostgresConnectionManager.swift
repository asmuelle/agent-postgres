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

    private init() {}

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
