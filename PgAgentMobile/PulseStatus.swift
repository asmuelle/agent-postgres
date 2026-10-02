import Foundation

// =============================================================================
// PulseStatus — the one-word answer to "is my database OK?" that leads every
// Pulse tile. Pure: derived from a FleetInstanceHealth sample, unit-tested in
// PgAgentMobileTests (compiled into that hostless target directly).
// =============================================================================
struct PulseStatus: Equatable {
    enum Tone: Equatable {
        case good, warning, critical, muted
    }

    let title: String
    /// Secondary line: activity + latency when reachable, the error otherwise.
    let detail: String?
    let tone: Tone
    let systemImage: String

    /// - Parameter isProduction: an unreachable production database is an
    ///   incident (critical); any other unreachable database is just off.
    static func make(from health: FleetInstanceHealth, isProduction: Bool) -> PulseStatus {
        guard health.lastUpdated != nil else {
            return PulseStatus(title: "Checking…", detail: nil, tone: .muted, systemImage: "ellipsis.circle")
        }
        guard health.reachable else {
            // Not "Unreachable": a missing password fails here as often as
            // a down host does; the detail line says which.
            return PulseStatus(
                title: "Can't Connect",
                detail: health.errorMessage,
                tone: isProduction ? .critical : .muted,
                systemImage: "bolt.horizontal.circle"
            )
        }

        let activity = activityLine(health)
        let posture = health.metrics.map(FleetPosturePolicy.severity(metrics:))

        // Reachable but unmeasured (the posture probe failed, commonly for
        // lack of pg_monitor): saturation and wraparound went unchecked.
        if health.metrics == nil, let problem = health.errorMessage,
           health.blockedLockCount == 0, health.longRunningCount == 0 {
            return PulseStatus(title: "Reachable", detail: problem, tone: .muted, systemImage: "checkmark.circle")
        }

        if health.blockedLockCount > 0 {
            return PulseStatus(
                title: "\(health.blockedLockCount) Blocked",
                detail: activity, tone: .critical, systemImage: "lock.trianglebadge.exclamationmark"
            )
        }
        if posture == .critical {
            return PulseStatus(
                title: "Needs Attention", detail: activity, tone: .critical,
                systemImage: "exclamationmark.octagon"
            )
        }
        if health.longRunningCount > 0 {
            let noun = health.longRunningCount == 1 ? "Slow Query" : "Slow Queries"
            return PulseStatus(
                title: "\(health.longRunningCount) \(noun)",
                detail: activity, tone: .warning, systemImage: "tortoise"
            )
        }
        if posture == .warning {
            return PulseStatus(
                title: "Needs Attention", detail: activity, tone: .warning,
                systemImage: "exclamationmark.triangle"
            )
        }
        return PulseStatus(title: "Healthy", detail: activity, tone: .good, systemImage: "checkmark.circle")
    }

    private static func activityLine(_ health: FleetInstanceHealth) -> String {
        var parts = [health.activeBackends == 0 ? "Idle" : "\(health.activeBackends) active"]
        if let latency = health.latencyMilliseconds {
            parts.append("\(Int(latency.rounded())) ms")
        }
        return parts.joined(separator: " · ")
    }
}
