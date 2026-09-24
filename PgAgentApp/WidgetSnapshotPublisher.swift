import Combine
import Foundation
import OSLog
import PgAgentMacOS
import WidgetKit

// =============================================================================
// WidgetSnapshotPublisher — feeds the macOS monitoring widget. Subscribes to
// the monitoring hub's published fleet health (FleetMonitorHub → the shared
// FleetHealthStore engine), converts each instance into a
// `WidgetMonitorSnapshot`, writes the file into the App Group container the
// sandboxed widget reads, and asks WidgetKit to reload — debounced, and only
// when what the widget shows actually changed (plus a slow heartbeat so a
// steady-state fleet never ages into "Stale" on the widget).
// =============================================================================

@MainActor
final class WidgetSnapshotPublisher {
    static let shared = WidgetSnapshotPublisher()

    /// Coalesces the hub's back-to-back `healths` / `instanceNames` writes
    /// within one poll into a single publish.
    private static let debounce: DispatchQueue.SchedulerTimeType.Stride = .seconds(2)
    /// Re-write + reload even without a visible change so `lastCheckedAt`
    /// stays inside the widget's freshness window (15 min fresh / 60 min
    /// stale). 30 min keeps the daily reload count well inside WidgetKit's
    /// budget.
    private static let heartbeat: TimeInterval = 30 * 60

    private let logger = Logger(subsystem: "com.pgagent.macos", category: "widget-snapshots")
    private let store: WidgetSnapshotStore
    private var cancellable: AnyCancellable?
    private var lastSnapshots: [WidgetMonitorSnapshot] = []
    private var lastPublishedAt: Date?

    init(store: WidgetSnapshotStore = WidgetSnapshotStore()) {
        self.store = store
    }

    /// Idempotent; called once from `applicationDidFinishLaunching`.
    func start() {
        guard cancellable == nil else { return }
        let hub = FleetMonitorHub.shared
        // Seed lastChangedAt continuity from what the widget currently shows.
        lastSnapshots = (try? store.loadSnapshots()) ?? []
        cancellable = hub.$healths
            .combineLatest(hub.$instanceNames, hub.$lastPollAt)
            .debounce(for: Self.debounce, scheduler: DispatchQueue.main)
            .sink { [weak self] healths, names, lastPollAt in
                // Nothing polled yet this launch: keep whatever the widget
                // already has instead of blanking it.
                guard lastPollAt != nil else { return }
                self?.publish(healths: healths, names: names, now: Date())
            }
    }

    private func publish(healths: [FleetInstanceHealth], names: [String: String], now: Date) {
        let snapshots = Self.snapshots(
            healths: healths, names: names, previous: lastSnapshots, now: now)
        let visibleChange = Self.visibleSignature(snapshots) != Self.visibleSignature(lastSnapshots)
        let heartbeatDue = lastPublishedAt.map { now.timeIntervalSince($0) >= Self.heartbeat } ?? true
        guard visibleChange || heartbeatDue else { return }

        do {
            try store.saveSnapshots(snapshots, generatedAt: now)
        } catch {
            logger.error("Widget snapshot write failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        lastSnapshots = snapshots
        lastPublishedAt = now
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotConfiguration.widgetKind)
    }

    // MARK: - Conversion (pure)

    /// One `.postgres` snapshot per polled instance, sorted by display name.
    /// `previous` carries `lastChangedAt` forward while an instance's state
    /// is unchanged.
    nonisolated static func snapshots(
        healths: [FleetInstanceHealth],
        names: [String: String],
        previous: [WidgetMonitorSnapshot] = [],
        now: Date
    ) -> [WidgetMonitorSnapshot] {
        let previousById = Dictionary(
            previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return healths
            .map { health -> WidgetMonitorSnapshot in
                let id = snapshotId(profileId: health.profileId)
                let state = state(for: health)
                let prior = previousById[id]
                let changedAt = (prior?.state == state ? prior?.lastChangedAt : nil) ?? now
                return WidgetMonitorSnapshot(
                    id: id,
                    displayName: names[health.profileId] ?? health.profileId,
                    kind: .postgres,
                    state: state,
                    lastCheckedAt: health.lastUpdated,
                    lastChangedAt: changedAt,
                    summary: summary(for: health),
                    detail: health.errorMessage,
                    openURL: PgAgentDeepLink.monitoringURLString(profileId: health.profileId)
                )
            }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    nonisolated static func snapshotId(profileId: String) -> String {
        "postgres:\(profileId)"
    }

    nonisolated static func state(for health: FleetInstanceHealth) -> WidgetMonitorState {
        // Never sampled (placeholder health) — not a confirmed outage.
        if !health.reachable, health.lastUpdated == nil, health.errorMessage == nil {
            return .unknown
        }
        switch health.severity {
        case .offline: return .down
        case .blocked, .slow: return .degraded
        case .busy, .healthy: return .up
        }
    }

    nonisolated static func summary(for health: FleetInstanceHealth) -> String {
        if state(for: health) == .unknown { return "Not checked yet" }
        switch health.severity {
        case .offline:
            return "Unreachable"
        case .blocked:
            return health.blockedLockCount > 0
                ? "\(health.blockedLockCount) blocked lock\(health.blockedLockCount == 1 ? "" : "s")"
                : "Critical posture"
        case .slow:
            return health.longRunningCount > 0
                ? "\(health.longRunningCount) long-running quer\(health.longRunningCount == 1 ? "y" : "ies")"
                : "Posture warning"
        case .busy:
            return "\(health.activeBackends) active backend\(health.activeBackends == 1 ? "" : "s")"
        case .healthy:
            return "Healthy"
        }
    }

    /// What the widget renders, minus timestamps — a poll that only bumps
    /// `lastCheckedAt` isn't worth a WidgetKit reload.
    private nonisolated static func visibleSignature(_ snapshots: [WidgetMonitorSnapshot]) -> [String] {
        snapshots.map { "\($0.id)|\($0.displayName)|\($0.state.rawValue)|\($0.summary)|\($0.detail ?? "")" }
    }
}
