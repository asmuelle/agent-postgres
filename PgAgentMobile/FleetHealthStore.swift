import Foundation
import SwiftUI
import WidgetKit
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// FleetHealthStore — polls every saved Postgres profile for a lightweight
// health glance used by the mobile Fleet Monitor. Connects lazily through the
// shared PostgresConnectionManager and reads pg_stat_activity / pg_locks via
// the existing FFI bridge. No Rust changes — pure consumer of pgListSessions /
// pgListLocks.
// =============================================================================
@MainActor
final class FleetHealthStore: ObservableObject {
    @Published private(set) var health: [String: FleetInstanceHealth] = [:]
    @Published private(set) var isRefreshing = false

    private let connectionManager = PostgresConnectionManager.shared

    func health(for profileId: String) -> FleetInstanceHealth {
        health[profileId] ?? .unknown(profileId)
    }

    /// Refresh every profile concurrently. Each instance fails independently —
    /// one unreachable host never blocks the rest of the fleet.
    func refresh(profiles: [PostgresProfile]) async {
        guard !profiles.isEmpty else {
            isRefreshing = false
            return
        }
        isRefreshing = true
        await withTaskGroup(of: Void.self) { group in
            for profile in profiles {
                group.addTask { await self.refreshOne(profile: profile) }
            }
        }
        isRefreshing = false
        publishWidgetSnapshot(profiles: profiles)
    }

    /// Hand the fresh fleet picture to the lock-screen accessory widgets: one
    /// compact JSON snapshot in the App Group container, then a timeline
    /// reload. Best-effort — widget plumbing must never fail a refresh.
    private func publishWidgetSnapshot(profiles: [PostgresProfile]) {
        let instances = profiles.map { profile -> PgFleetWidgetInstance in
            let health = self.health(for: profile.id)
            return PgFleetWidgetInstance(
                profileId: profile.id,
                name: profile.name,
                status: PgFleetInstanceStatus(severity: health.severity),
                activeBackends: health.activeBackends,
                longRunningCount: health.longRunningCount,
                blockedLockCount: health.blockedLockCount
            )
        }
        let snapshot = PgFleetWidgetSnapshot(generatedAt: Date(), instances: instances)
        try? PgFleetWidgetSnapshotStore().save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: PgFleetWidgetConfiguration.accessoryWidgetKind)
    }

    private func refreshOne(profile: PostgresProfile) async {
        await connectionManager.connectIfNeeded(profile: profile)

        guard let connectionId = connectionManager.activeConnections[profile.id] else {
            health[profile.id] = FleetInstanceHealth(
                profileId: profile.id,
                reachable: false,
                activeBackends: 0,
                longRunningCount: 0,
                blockedLockCount: 0,
                errorMessage: connectionManager.connectionErrors[profile.id] ?? "Unreachable",
                lastUpdated: Date()
            )
            return
        }

        do {
            let sessions = try await BridgeManager.shared.pgListSessions(connectionId: connectionId)
            let locks = try await BridgeManager.shared.pgListLocks(connectionId: connectionId)
            let now = Date().timeIntervalSince1970

            let threshold = FleetMonitorSettings.shared.longRunningThreshold
            let activeBackends = sessions.filter { $0.state == "active" }.count
            let longRunning = sessions.filter { session in
                guard session.state == "active", let start = session.queryStart else { return false }
                return now - Double(start) >= threshold
            }.count
            let blocked = locks.filter { $0.blockedByPid != nil || !$0.granted }.count

            health[profile.id] = FleetInstanceHealth(
                profileId: profile.id,
                reachable: true,
                activeBackends: activeBackends,
                longRunningCount: longRunning,
                blockedLockCount: blocked,
                errorMessage: nil,
                lastUpdated: Date()
            )
        } catch {
            health[profile.id] = FleetInstanceHealth(
                profileId: profile.id,
                reachable: false,
                activeBackends: 0,
                longRunningCount: 0,
                blockedLockCount: 0,
                errorMessage: error.localizedDescription,
                lastUpdated: Date()
            )
        }
    }
}

private extension PgFleetInstanceStatus {
    init(severity: FleetInstanceHealth.Severity) {
        switch severity {
        case .offline: self = .offline
        case .blocked: self = .blocked
        case .slow: self = .slow
        case .busy: self = .busy
        case .healthy: self = .healthy
        }
    }
}
