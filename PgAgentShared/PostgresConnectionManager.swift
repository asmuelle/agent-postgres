import Combine
import Foundation
import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

/// One consumer's claim on a profile's connection, returned by
/// `PostgresConnectionManager.claim`. Release it exactly once.
struct PostgresConnectionLease: Hashable, Sendable {
    let profileId: String
    fileprivate let serial: UInt64
}

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
    ///
    /// Each claim is a lease (`claim`/`release(_:)`), releasable exactly once,
    /// so a stray or duplicate release can never drop another consumer's claim.
    private var outstandingLeases: [UInt64: String] = [:]   // serial -> profile id
    private var leaseCounts: [String: Int] = [:]
    private var nextLeaseSerial: UInt64 = 0

    /// Generation tokens invalidate in-flight connects when a profile is
    /// disconnected, deleted, or reconfigured.
    private var connectionGenerations: [String: UInt64] = [:]

    private init() {}

    // MARK: - Reference-counted ownership

    /// Register a claim on `profile` without connecting. Synchronous, so a
    /// caller can pair it with `release(_:)` before its first suspension point
    /// (`let lease = claim(...); defer { release(lease) }`).
    func claim(profile: PostgresProfile) -> PostgresConnectionLease {
        nextLeaseSerial &+= 1
        let lease = PostgresConnectionLease(profileId: profile.id, serial: nextLeaseSerial)
        outstandingLeases[lease.serial] = profile.id
        leaseCounts[profile.id, default: 0] += 1
        return lease
    }

    /// Drop a lease's claim; closes the pool once the last consumer is gone.
    /// Releasing a lease twice, or one invalidated by `forget`/`disconnectAll`,
    /// is a no-op.
    func release(_ lease: PostgresConnectionLease) {
        guard outstandingLeases.removeValue(forKey: lease.serial) != nil else { return }
        leaseCounts[lease.profileId] = decremented(leaseCounts[lease.profileId])
        disconnectIfLastClaimDropped(profileId: lease.profileId)
    }

    /// Number of outstanding claims (diagnostics / tests).
    func claimCount(profileId: String) -> Int {
        leaseCounts[profileId] ?? 0
    }

    private func decremented(_ count: Int?) -> Int? {
        guard let count, count > 1 else { return nil }
        return count - 1
    }

    private func disconnectIfLastClaimDropped(profileId: String) {
        guard claimCount(profileId: profileId) == 0 else { return }
        Task { @MainActor [weak self] in
            await self?.disconnectIfUnused(profileId: profileId)
        }
    }

    private func clearClaims(profileId: String) {
        leaseCounts.removeValue(forKey: profileId)
        outstandingLeases = outstandingLeases.filter { $0.value != profileId }
    }

    /// Forget a profile completely. Unlike a manual disconnect, this clears
    /// outstanding claims so a deleted id cannot reconnect later.
    func forget(profileId: String) async {
        clearClaims(profileId: profileId)
        await disconnect(profileId: profileId)
    }

    /// Close every open connection (e.g. an explicit "disconnect all", app
    /// teardown). Clears consumer claims too.
    func disconnectAll() async {
        leaseCounts.removeAll()
        outstandingLeases.removeAll()
        let profileIds = Set(activeConnections.keys).union(isConnecting.keys)
        for profileId in profileIds {
            await disconnect(profileId: profileId)
        }
    }

    func connectIfNeeded(profile: PostgresProfile) async {
        if activeConnections[profile.id] != nil || isConnecting[profile.id] == true { return }
        let generation = nextGeneration(for: profile.id)
        isConnecting[profile.id] = true
        connectionErrors[profile.id] = nil
        PostgresConnectionStatusStore.shared.markConnecting(profileId: profile.id)

        do {
            let id = try await BridgeManager.shared.pgConnect(profile: profile)
            guard isCurrent(profileId: profile.id, generation: generation) else {
                await BridgeManager.shared.pgDisconnect(connectionId: id)
                return
            }
            activeConnections[profile.id] = id
            
            let store = PgSchemaStore(connectionId: id, connectedDatabase: profile.database)
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

            guard isCurrent(profileId: profile.id, generation: generation) else {
                if activeConnections[profile.id] == id {
                    activeConnections.removeValue(forKey: profile.id)
                    await BridgeManager.shared.pgDisconnect(connectionId: id)
                }
                return
            }

            PostgresProfileStore.shared.markConnected(profile)
            PostgresConnectionStatusStore.shared.markConnected(profileId: profile.id)
        } catch let err as PostgresBridgeError {
            guard isCurrent(profileId: profile.id, generation: generation) else { return }
            connectionErrors[profile.id] = err.errorDescription ?? "Connection failed"
            PostgresConnectionStatusStore.shared.markError(
                err.errorDescription ?? "Connection failed",
                profileId: profile.id
            )
        } catch {
            guard isCurrent(profileId: profile.id, generation: generation) else { return }
            connectionErrors[profile.id] = error.localizedDescription
            PostgresConnectionStatusStore.shared.markError(
                error.localizedDescription,
                profileId: profile.id
            )
        }
        if isCurrent(profileId: profile.id, generation: generation) {
            isConnecting[profile.id] = false
        }
    }

    func disconnect(profileId: String) async {
        _ = nextGeneration(for: profileId)
        // Closes the connection *now* without touching consumer claims: a
        // manual "Disconnect" button while the workspace is still on screen
        // leaves its claim intact, so a later Connect → navigate-away still
        // balances to a single release. Claims are owned solely by
        // claim/release/forget/disconnectAll.
        storeSubscriptions.removeValue(forKey: profileId)
        schemaStores.removeValue(forKey: profileId)

        // Remove the mapping before awaiting the bridge. A new acquire may
        // establish a replacement while the old connection is shutting down;
        // never remove that replacement when the old disconnect returns.
        let connectionId = activeConnections.removeValue(forKey: profileId)
        connectionErrors.removeValue(forKey: profileId)
        isConnecting.removeValue(forKey: profileId)
        PostgresConnectionStatusStore.shared.markDisconnected(profileId: profileId)

        if let connectionId {
            await BridgeManager.shared.pgDisconnect(connectionId: connectionId)
        }
    }

    /// Reconnect an active or claimed profile after connection-affecting
    /// settings change.
    func reconnectIfNeeded(profile: PostgresProfile) async {
        let shouldReconnect = activeConnections[profile.id] != nil
            || isConnecting[profile.id] == true
            || claimCount(profileId: profile.id) > 0
        guard shouldReconnect else { return }
        let expectedGeneration = (connectionGenerations[profile.id] ?? 0) &+ 1
        await disconnect(profileId: profile.id)
        guard connectionGenerations[profile.id] == expectedGeneration else {
            return
        }
        await connectIfNeeded(profile: profile)
    }

    private func disconnectIfUnused(profileId: String) async {
        guard claimCount(profileId: profileId) == 0 else { return }
        await disconnect(profileId: profileId)
    }

    private func nextGeneration(for profileId: String) -> UInt64 {
        let next = (connectionGenerations[profileId] ?? 0) &+ 1
        connectionGenerations[profileId] = next
        return next
    }

    private func isCurrent(profileId: String, generation: UInt64) -> Bool {
        connectionGenerations[profileId] == generation
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
