import Foundation
import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// FleetHealthStore — polls every saved Postgres profile for a lightweight
// health glance. Used by the mobile Fleet Monitor AND the macOS monitoring
// hub, so it must stay platform-neutral: no WidgetKit / UIKit / BGTask deps.
// Connects lazily through the shared PostgresConnectionManager and reads
// pg_stat_activity / pg_locks via the existing FFI bridge. No Rust changes —
// pure consumer of pgListSessions / pgListLocks.
//
// Platform-specific post-refresh work (e.g. publishing the iOS lock-screen
// widget snapshot) hangs off `onRefreshCompleted` — see
// PgAgentMobile/FleetHealthStore+Widgets.swift.
// =============================================================================
@MainActor
final class FleetHealthStore: ObservableObject {
    @Published private(set) var health: [String: FleetInstanceHealth] = [:]
    @Published private(set) var isRefreshing = false

    /// Invoked after every full fleet refresh with the profiles just polled.
    /// The iOS app uses this to publish the accessory-widget snapshot; the
    /// macOS hub leaves it nil.
    var onRefreshCompleted: (([PostgresProfile]) -> Void)?

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
        onRefreshCompleted?(profiles)
    }

    private func refreshOne(profile: PostgresProfile) async {
        // Acquire through the shared manager so a fleet probe cannot race an
        // interactive connect or accidentally disconnect its connection.
        await connectionManager.acquire(profile: profile)
        defer { connectionManager.release(profileId: profile.id) }

        guard let connectionId = connectionManager.activeConnections[profile.id] else {
            health[profile.id] = FleetInstanceHealth(
                profileId: profile.id,
                reachable: false,
                activeBackends: 0,
                longRunningCount: 0,
                blockedLockCount: 0,
                errorMessage: connectionManager.connectionErrors[profile.id] ?? "Not connected",
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
            let waitPairs = locks.compactMap { lock -> (waiterPid: Int32, blockerPid: Int32)? in
                guard let blocker = lock.blockedByPid else { return nil }
                return (waiterPid: lock.pid, blockerPid: blocker)
            }

            health[profile.id] = FleetInstanceHealth(
                profileId: profile.id,
                reachable: true,
                activeBackends: activeBackends,
                longRunningCount: longRunning,
                blockedLockCount: blocked,
                errorMessage: nil,
                lastUpdated: Date(),
                rootBlockerPid: fleetRootBlockerPid(waitPairs: waitPairs)
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
