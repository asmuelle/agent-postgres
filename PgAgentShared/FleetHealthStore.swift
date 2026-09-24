import Foundation
import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// FleetHealthStore — polls every saved Postgres profile for a lightweight
// health glance. Used by the mobile Fleet Monitor AND the macOS monitoring
// hub, so it must stay platform-neutral: no WidgetKit / UIKit / BGTask deps.
// Uses dedicated, reusable probe connections rather than the interactive
// workspace connection manager. A health poll never loads schemas, roles, or
// tablespaces and never disconnects a connection another view owns.
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

    private let snapshotStore: FleetSnapshotStore
    private var probeConnections: [String: String] = [:]
    private var probeConnectionKeys: [String: String] = [:]

    /// Refreshes and shutdowns run strictly one at a time: overlapping
    /// refreshes (e.g. a hub stop→start) opened two probes for one profile
    /// and leaked the one whose id was overwritten.
    private let queue = SerialAsyncQueue()

    /// Bumped by `shutdown()`. A refresh still in flight when it changes
    /// discards its results and closes any probe it opened meanwhile, so a
    /// stopped poller can't leave connections behind.
    private var generation: UInt64 = 0

    init(snapshotStore: FleetSnapshotStore = FleetSnapshotStore()) {
        self.snapshotStore = snapshotStore
    }

    func health(for profileId: String) -> FleetInstanceHealth {
        health[profileId] ?? .unknown(profileId)
    }

    /// Refresh every profile concurrently. Each instance fails independently —
    /// one unreachable host never blocks the rest of the fleet.
    func refresh(profiles: [PostgresProfile]) async {
        await queue.run { [weak self] in
            await self?.performRefresh(profiles: profiles)
        }
    }

    private func performRefresh(profiles: [PostgresProfile]) async {
        guard !profiles.isEmpty else {
            await closeAllProbes()
            health = [:]
            isRefreshing = false
            return
        }
        let generation = self.generation
        isRefreshing = true
        defer { isRefreshing = false }
        for batch in FleetPollingPolicy.batches(profiles) {
            guard isCurrent(generation) else { return }
            await withTaskGroup(of: Void.self) { group in
                for profile in batch {
                    group.addTask {
                        await self.refreshOne(profile: profile, generation: generation)
                    }
                }
            }
        }
        guard isCurrent(generation) else { return }
        await removeRetiredConnections(keeping: Set(profiles.map(\.id)))
        onRefreshCompleted?(profiles)
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        self.generation == generation
    }

    private func refreshOne(profile: PostgresProfile, generation: UInt64) async {
        let started = Date()
        do {
            let connectionId = try await probeConnection(for: profile, generation: generation)
            let sessions = try await BridgeManager.shared.pgListSessions(connectionId: connectionId)
            let locks = try await BridgeManager.shared.pgListLocks(connectionId: connectionId)
            let metricsOutcome = await loadMetrics(connectionId: connectionId, profileId: profile.id)
            guard isCurrent(generation) else { return }
            let now = Date().timeIntervalSince1970

            let threshold = TimeInterval(
                FleetEnvironmentPolicy.defaults(for: profile.effectiveEnvironment.rawValue)
                    .longRunningSeconds)
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
                // Reachable but the posture probe failed (commonly missing
                // pg_monitor privileges): say so instead of "no metrics".
                errorMessage: metricsOutcome.errorMessage,
                lastUpdated: Date(),
                latencyMilliseconds: Date().timeIntervalSince(started) * 1_000,
                metrics: metricsOutcome.metrics,
                rootBlockerPid: fleetRootBlockerPid(waitPairs: waitPairs)
            )
            if let current = health[profile.id] {
                await persistSnapshot(current)
            }
        } catch {
            // Shut down meanwhile: the probe is already closed; record nothing.
            guard isCurrent(generation) else { return }
            await invalidateProbeConnection(profileId: profile.id)
            let current = FleetInstanceHealth(
                profileId: profile.id,
                reachable: false,
                activeBackends: 0,
                longRunningCount: 0,
                blockedLockCount: 0,
                errorMessage: error.localizedDescription,
                lastUpdated: Date(),
                latencyMilliseconds: Date().timeIntervalSince(started) * 1_000
            )
            health[profile.id] = current
            await persistSnapshot(current)
        }
    }

    private func probeConnection(for profile: PostgresProfile, generation: UInt64) async throws -> String {
        let key = connectionKey(profile)
        if let existing = probeConnections[profile.id], probeConnectionKeys[profile.id] == key {
            return existing
        }
        await invalidateProbeConnection(profileId: profile.id)
        let connectionId = try await BridgeManager.shared.pgConnect(profile: profile)
        guard isCurrent(generation) else {
            // Shut down while connecting — nobody will ever close this probe.
            await BridgeManager.shared.pgDisconnect(connectionId: connectionId)
            throw CancellationError()
        }
        if let stale = probeConnections[profile.id], stale != connectionId {
            await BridgeManager.shared.pgDisconnect(connectionId: stale)
        }
        probeConnections[profile.id] = connectionId
        probeConnectionKeys[profile.id] = key
        return connectionId
    }

    private func connectionKey(_ profile: PostgresProfile) -> String {
        [
            profile.host, String(profile.port), profile.database, profile.user,
            String(describing: profile.auth), profile.tls.rawValue,
            profile.applicationName ?? "", String(describing: profile.tunnel),
            String(profile.connectTimeoutSecs ?? 10), String(profile.maxPoolSize ?? 5),
        ].joined(separator: "|")
    }

    /// Posture metrics, or why they couldn't be collected. A failure here
    /// doesn't make the instance unreachable — sessions/locks already worked.
    private func loadMetrics(
        connectionId: String,
        profileId: String
    ) async -> (metrics: FleetProbeMetrics?, errorMessage: String?) {
        let sessionId = "fleet-posture-\(profileId)"
        defer {
            Task {
                await BridgeManager.shared.pgReleaseSession(
                    connectionId: connectionId, sessionId: sessionId)
            }
        }
        do {
            let result = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: FleetProbeSQL.posture,
                pageSize: 1
            )
            guard let row = result.rows.first else {
                return (nil, "Metrics unavailable: the posture probe returned no rows.")
            }
            return (try FleetProbeParser.parse(row.cells), nil)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return (nil, "Metrics unavailable: \(detail)")
        }
    }

    private func persistSnapshot(_ current: FleetInstanceHealth) async {
        let record = FleetSnapshotRecord(
            profileId: current.profileId,
            capturedAt: current.lastUpdated ?? Date(),
            reachable: current.reachable,
            activeBackends: current.activeBackends,
            longRunningCount: current.longRunningCount,
            blockedLockCount: current.blockedLockCount,
            latencyMilliseconds: current.latencyMilliseconds,
            metrics: current.metrics ?? .empty,
            errorMessage: current.errorMessage
        )
        try? await snapshotStore.append(record)
    }

    private func invalidateProbeConnection(profileId: String) async {
        probeConnectionKeys.removeValue(forKey: profileId)
        guard let id = probeConnections.removeValue(forKey: profileId) else { return }
        await BridgeManager.shared.pgDisconnect(connectionId: id)
    }

    private func removeRetiredConnections(keeping profileIds: Set<String>) async {
        for id in Array(probeConnections.keys) where !profileIds.contains(id) {
            await invalidateProbeConnection(profileId: id)
        }
    }

    /// Close every probe. Any refresh still in flight is invalidated at once
    /// (it closes what it opens and records nothing); the close itself waits
    /// its turn behind that refresh so nothing is opened after it.
    func shutdown() async {
        generation &+= 1
        await queue.run { [weak self] in
            await self?.closeAllProbes()
        }
    }

    private func closeAllProbes() async {
        for profileId in Array(probeConnections.keys) {
            await invalidateProbeConnection(profileId: profileId)
        }
    }
}
