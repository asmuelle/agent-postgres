import Foundation

// =============================================================================
// FleetHealthModel — pure, dependency-free value types + formatting for the
// Fleet Monitor. Kept free of the FFI bridge / connection manager so the logic
// (severity derivation, age formatting) is unit-testable in the mobile
// logic-test target without an app host.
// =============================================================================

/// A lightweight health glance for one Postgres instance.
struct FleetInstanceHealth: Identifiable, Sendable, Equatable {
    let profileId: String
    var id: String { profileId }

    var reachable: Bool
    var activeBackends: Int
    var longRunningCount: Int
    var blockedLockCount: Int
    var errorMessage: String?
    var lastUpdated: Date?
    /// End-to-end connection + catalog probe latency for this sample.
    var latencyMilliseconds: Double? = nil
    /// PostgreSQL 14+ posture metrics collected by the lightweight probe.
    var metrics: FleetProbeMetrics? = nil
    /// Head of the biggest lock wait chain at poll time, when one exists —
    /// threaded into blocked-locks alerts so a notification tap can land on
    /// the offending session (roadmap 1.2). Nil when nothing is blocked.
    var rootBlockerPid: Int32? = nil

    /// Most severe condition first — drives the card's status colour.
    enum Severity { case offline, blocked, slow, busy, healthy }

    var severity: Severity {
        if !reachable { return .offline }
        if blockedLockCount > 0 { return .blocked }
        if let metrics, FleetPosturePolicy.severity(metrics: metrics) == .critical { return .blocked }
        if longRunningCount > 0 { return .slow }
        if let metrics, FleetPosturePolicy.severity(metrics: metrics) == .warning { return .slow }
        if activeBackends > 0 { return .busy }
        return .healthy
    }

    static func unknown(_ profileId: String) -> FleetInstanceHealth {
        FleetInstanceHealth(
            profileId: profileId,
            reachable: false,
            activeBackends: 0,
            longRunningCount: 0,
            blockedLockCount: 0,
            errorMessage: nil,
            lastUpdated: nil
        )
    }
}

/// Pick the "root blocker" — the pid worth resolving first — from raw
/// (waiter, blocker) lock-wait pairs: the blocker with the most distinct
/// waiters, preferring blockers that are not themselves waiting on someone
/// else (killing a mid-chain pid only moves the contention up one level).
/// Ties break toward the smaller pid so the choice is deterministic.
/// Self-pairs (a backend "blocking itself") are ignored.
func fleetRootBlockerPid(waitPairs: [(waiterPid: Int32, blockerPid: Int32)]) -> Int32? {
    let pairs = waitPairs.filter { $0.waiterPid != $0.blockerPid }
    guard !pairs.isEmpty else { return nil }

    let waiterPids = Set(pairs.map(\.waiterPid))
    var waitersByBlocker: [Int32: Set<Int32>] = [:]
    for pair in pairs {
        waitersByBlocker[pair.blockerPid, default: []].insert(pair.waiterPid)
    }

    return waitersByBlocker.min { lhs, rhs in
        let lhsIsRoot = !waiterPids.contains(lhs.key)
        let rhsIsRoot = !waiterPids.contains(rhs.key)
        if lhsIsRoot != rhsIsRoot { return lhsIsRoot }
        if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
        return lhs.key < rhs.key
    }?.key
}

enum FleetFormat {
    /// Compact age label for an epoch-seconds timestamp (e.g. query_start).
    static func age(sinceEpoch start: UInt64?, now: Date = Date()) -> String {
        guard let start else { return "—" }
        let secs = max(0, now.timeIntervalSince1970 - Double(start))
        if secs < 60 { return String(format: "%.0fs", secs) }
        if secs < 3_600 {
            let m = Int(secs) / 60
            let s = Int(secs) % 60
            return "\(m)m \(s)s"
        }
        let h = Int(secs) / 3_600
        let m = (Int(secs) % 3_600) / 60
        return "\(h)h \(m)m"
    }
}
