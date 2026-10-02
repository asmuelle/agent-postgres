import Foundation

// =============================================================================
// PgFleetWidgetSnapshot — the compact fleet-health handoff between the mobile
// app and the lock-screen accessory widgets. The app serializes one snapshot
// into the App Group container (group.com.pgagent.pgagent) after every fleet
// refresh (foreground pull-to-refresh and BGAppRefresh alike); the widget
// timeline provider reads it back. Persistence: PgFleetWidgetSnapshotStore.
// Pure Foundation, so it also compiles into the hostless PgAgentMobileTests.
//
// ⚠️ Dual-target file: compiled into BOTH PgAgentMobile (via the group source
// entry) and PgAgentMobileWidgets (via an explicit per-file entry in
// project.yml). Both sides must agree on this schema.
// =============================================================================

enum PgFleetWidgetConfiguration {
    static let fileName = "pg-fleet-widget-snapshot.json"
    static let accessoryWidgetKind = "PgFleetAccessoryWidget"
    /// The Control Center / Lock Screen / Action button control.
    static let controlKind = "com.pgagent.mobile.control.database-health"
    /// Snapshots older than this render as stale (BGAppRefresh runs ~15 min).
    static let staleAfter: TimeInterval = 45 * 60
}

/// Mirror of FleetInstanceHealth.Severity that is Codable and available to the
/// widget extension (FleetHealthModel.swift is app-target only).
enum PgFleetInstanceStatus: String, Codable, CaseIterable, Sendable {
    case offline
    case blocked
    case slow
    case busy
    case healthy

    /// Lower is worse — used to pick the fleet-wide worst status.
    var severityRank: Int {
        switch self {
        case .offline: return 0
        case .blocked: return 1
        case .slow: return 2
        case .busy: return 3
        case .healthy: return 4
        }
    }

    var isProblem: Bool {
        switch self {
        case .offline, .blocked, .slow: return true
        case .busy, .healthy: return false
        }
    }
}

struct PgFleetWidgetInstance: Codable, Identifiable, Equatable, Sendable {
    let profileId: String
    let name: String
    let status: PgFleetInstanceStatus
    let activeBackends: Int
    let longRunningCount: Int
    let blockedLockCount: Int

    var id: String { profileId }
}

struct PgFleetWidgetSnapshot: Codable, Equatable, Sendable {
    var generatedAt: Date
    var instances: [PgFleetWidgetInstance]

    /// Worst status across the fleet; healthy when the fleet is empty.
    var worstStatus: PgFleetInstanceStatus {
        instances.map(\.status).min { $0.severityRank < $1.severityRank } ?? .healthy
    }

    var problemCount: Int {
        instances.filter(\.status.isProblem).count
    }

    /// Problem instances first (worst leading), then the rest by name — the
    /// order the rectangular widget lists them in.
    var rankedInstances: [PgFleetWidgetInstance] {
        instances.sorted { lhs, rhs in
            if lhs.status.severityRank != rhs.status.severityRank {
                return lhs.status.severityRank < rhs.status.severityRank
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(generatedAt) > PgFleetWidgetConfiguration.staleAfter
    }
}

/// What the "Database Health" control shows: one short line and a symbol.
/// Says nothing it doesn't know — no snapshot or a stale one is just
/// "Databases", never a false "All Healthy".
struct PgFleetControlStatus: Equatable, Sendable {
    let title: String
    let systemImage: String

    static let unknown = PgFleetControlStatus(title: "Databases", systemImage: "cylinder.split.1x2")

    init(title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    init(snapshot: PgFleetWidgetSnapshot?, now: Date = Date()) {
        guard let snapshot, !snapshot.isStale(now: now) else {
            self = .unknown
            return
        }
        guard !snapshot.instances.isEmpty else {
            self.init(title: "No Databases", systemImage: "cylinder.split.1x2")
            return
        }
        let problems = snapshot.problemCount
        guard problems > 0 else {
            self.init(title: "All Healthy", systemImage: "checkmark.circle")
            return
        }
        self.init(
            title: problems == 1 ? "1 Problem" : "\(problems) Problems",
            systemImage: Self.symbol(for: snapshot.worstStatus)
        )
    }

    private static func symbol(for status: PgFleetInstanceStatus) -> String {
        switch status {
        case .offline: return "bolt.horizontal.circle"
        case .blocked: return "lock.trianglebadge.exclamationmark"
        case .slow: return "tortoise"
        case .busy, .healthy: return "checkmark.circle"
        }
    }
}
