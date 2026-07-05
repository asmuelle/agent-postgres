import Foundation
import WidgetKit
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// FleetHealthStore+Widgets — the iOS-only tail of a fleet refresh. The store
// itself lives in PgAgentShared (the macOS hub reuses it); this extension owns
// the WidgetKit / App Group plumbing that must not leak into the mac target.
// =============================================================================
extension FleetHealthStore {
    /// Factory for the iOS app: a store that publishes the lock-screen
    /// accessory-widget snapshot after every refresh.
    static func withWidgetPublishing() -> FleetHealthStore {
        let store = FleetHealthStore()
        store.onRefreshCompleted = { [weak store] profiles in
            store?.publishWidgetSnapshot(profiles: profiles)
        }
        return store
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
