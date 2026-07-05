import Foundation

// =============================================================================
// FleetAlertModel — pure, edge-triggered evaluation of which instances warrant a
// notification, given their health and the user's thresholds. Kept free of
// BackgroundTasks / UserNotifications so the "when do we notify, and avoid
// re-notifying every poll" logic is unit-testable.
// =============================================================================

struct FleetMonitorThresholds: Equatable, Sendable {
    /// A query counts as "slow" once active for at least this many seconds.
    /// Also drives the live FleetHealthStore long-running tally.
    var longRunningSeconds: Int
    /// Notify when an instance has at least this many slow queries (0 = off).
    var longRunningCountAlert: Int
    /// Notify when an instance has at least this many blocked backends (0 = off).
    var blockedLockAlert: Int
    /// Notify when an instance becomes unreachable.
    var alertOnUnreachable: Bool

    static let defaults = FleetMonitorThresholds(
        longRunningSeconds: 5,
        longRunningCountAlert: 1,
        blockedLockAlert: 1,
        alertOnUnreachable: false
    )
}

enum FleetAlertKind: String, Sendable, Equatable {
    case longRunning, blockedLocks, unreachable
}

struct FleetAlert: Identifiable, Equatable, Sendable {
    let profileId: String
    let profileName: String
    let kind: FleetAlertKind
    let title: String
    let body: String
    /// Root blocker of the lock chain for `.blockedLocks` alerts, when the
    /// health snapshot captured one — lets a notification tap deep-link to
    /// the offending session. Nil for other kinds.
    var blockerPid: Int32? = nil

    /// Stable per (instance, condition) so the same ongoing problem doesn't
    /// re-notify on every poll — see `evaluateFleetAlerts`.
    var id: String { "\(profileId):\(kind.rawValue)" }
}

/// Edge-triggered alert evaluation. Returns the alerts whose condition is firing
/// now but was NOT in `previouslyFiring` (so a persistent problem notifies once,
/// not every poll), plus the full set of currently-firing keys to persist for
/// the next call. A condition that clears drops out of `firingNow`, so it can
/// notify again the next time it recurs.
func evaluateFleetAlerts(
    healths: [FleetInstanceHealth],
    names: [String: String],
    thresholds: FleetMonitorThresholds,
    previouslyFiring: Set<String>
) -> (newAlerts: [FleetAlert], firingNow: Set<String>) {
    var firingNow = Set<String>()
    var newAlerts: [FleetAlert] = []

    for health in healths {
        let name = names[health.profileId] ?? health.profileId

        func consider(
            _ kind: FleetAlertKind, active: Bool, title: String, body: String,
            blockerPid: Int32? = nil
        ) {
            guard active else { return }
            let alert = FleetAlert(
                profileId: health.profileId, profileName: name, kind: kind,
                title: title, body: body, blockerPid: blockerPid
            )
            firingNow.insert(alert.id)
            if !previouslyFiring.contains(alert.id) {
                newAlerts.append(alert)
            }
        }

        if thresholds.alertOnUnreachable {
            consider(
                .unreachable,
                active: !health.reachable,
                title: "\(name) unreachable",
                body: health.errorMessage ?? "Can't connect to this instance."
            )
        }

        guard health.reachable else { continue }

        consider(
            .longRunning,
            active: thresholds.longRunningCountAlert > 0 && health.longRunningCount >= thresholds.longRunningCountAlert,
            title: "\(name): slow queries",
            body: "\(health.longRunningCount) query\(health.longRunningCount == 1 ? "" : "s") running over \(thresholds.longRunningSeconds)s."
        )

        consider(
            .blockedLocks,
            active: thresholds.blockedLockAlert > 0 && health.blockedLockCount >= thresholds.blockedLockAlert,
            title: "\(name): lock contention",
            body: "\(health.blockedLockCount) backend\(health.blockedLockCount == 1 ? "" : "s") blocked on locks.",
            blockerPid: health.rootBlockerPid
        )
    }

    return (newAlerts, firingNow)
}
