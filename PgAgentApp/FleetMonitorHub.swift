import Foundation
import SwiftUI
import PgAgentMacOS

// =============================================================================
// FleetMonitorHub — the macOS "always-on monitor" of roadmap slice 1.1. While
// hub mode is enabled it runs a poll loop over every saved profile using the
// SAME shared engine as the iOS fleet monitor (FleetHealthStore +
// evaluateFleetAlerts — one set of health rules, two platforms) and relays
// newly-raised alerts to the user's other devices through FleetAlertRelay
// (private CloudKit database → push).
//
// Edge-triggering: the firing set is persisted, so an ongoing condition is
// relayed once, not every 30 seconds — and survives app restarts. The
// deterministic alertId (instance+kind+time-bucket) is a second, server-side
// guard for the same property.
// =============================================================================
@MainActor
final class FleetMonitorHub: ObservableObject {
    static let shared = FleetMonitorHub()

    @Published private(set) var isRunning = false
    @Published private(set) var lastPollAt: Date?
    @Published private(set) var healths: [FleetInstanceHealth] = []
    @Published private(set) var instanceNames: [String: String] = [:]
    @Published private(set) var activeAlerts: [FleetAlert] = []
    @Published private(set) var driftFindings: [FleetDriftFinding] = []

    let relay = FleetAlertRelay()
    let lifecycle = FleetAlertLifecycleStore.shared

    private let store = FleetHealthStore()
    private let settings = FleetMonitorSettings.shared
    private var pollTask: Task<Void, Never>?

    private static let firingKey = "fleet.hub.firingAlerts"
    private static let minPollIntervalSeconds = 10

    private init() {}

    // MARK: - Lifecycle

    /// Called once at app launch; resumes the hub if the user left it on.
    func startIfEnabled() {
        if settings.hubModeEnabled { start() }
    }

    /// React to the settings toggle.
    func applyHubMode(enabled: Bool) {
        enabled ? start() : stop()
    }

    private func start() {
        guard pollTask == nil else { return }
        isRunning = true
        pollTask = Task { [weak self] in
            await self?.relay.refreshAccountStatus()
            while !Task.isCancelled {
                // The MenuBarExtra's isInserted binding can flip the setting
                // off without going through applyHubMode — honor it here.
                guard let self, self.settings.hubModeEnabled else { break }
                await self.pollOnce()
                let seconds = self.currentPollInterval()
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
            self?.loopEnded()
        }
    }

    /// Loop exited on its own (setting flipped off) — reflect that, but never
    /// clobber a newer loop that may already have been started.
    private func loopEnded() {
        if !settings.hubModeEnabled {
            pollTask = nil
            isRunning = false
        }
    }

    private func stop() {
        pollTask?.cancel()
        pollTask = nil
        isRunning = false
        Task { await store.shutdown() }
    }

    private func currentPollInterval() -> Int {
        max(Self.minPollIntervalSeconds, settings.hubPollIntervalSeconds)
    }

    // MARK: - Poll + relay

    func pollOnce() async {
        let profiles = PostgresProfileStore.shared.profiles
        guard !profiles.isEmpty else {
            healths = []
            activeAlerts = []
            driftFindings = []
            lastPollAt = Date()
            return
        }

        await store.refresh(profiles: profiles)

        let names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.name) })
        let currentHealths = profiles.map { store.health(for: $0.id) }
        instanceNames = names
        healths = currentHealths
        driftFindings = FleetDriftPolicy.findings(in: profiles.map { profile in
            let metrics = store.health(for: profile.id).metrics
            let group = profile.folderPath.map { "\($0)/\(profile.database)" } ?? profile.id
            return FleetDriftSnapshot(
                profileId: profile.id,
                group: group,
                environment: profile.effectiveEnvironment.rawValue,
                serverMajorVersion: metrics?.serverMajorVersion,
                schemaFingerprint: metrics?.schemaFingerprint)
        })
        lastPollAt = Date()

        let previouslyFiring = loadFiring()
        var currentlyFiring: [FleetAlert] = []
        for profile in profiles {
            let result = evaluateFleetAlerts(
                healths: [store.health(for: profile.id)],
                names: names,
                thresholds: thresholds(for: profile),
                previouslyFiring: []
            )
            currentlyFiring.append(contentsOf: result.newAlerts)
        }
        activeAlerts = currentlyFiring
        let firingNow = Set(currentlyFiring.map(\.id))
        saveFiring(firingNow)
        lifecycle.noteResolved(alertIds: previouslyFiring.subtracting(firingNow))
        let lifecycleTransitions = lifecycle.prepareForPoll(
            alerts: currentlyFiring, previouslyFiring: previouslyFiring)

        let newlyRaised = currentlyFiring.filter {
            (!previouslyFiring.contains($0.id) || lifecycleTransitions.contains($0.id))
                && lifecycle.shouldDeliver($0)
        }
        guard !newlyRaised.isEmpty else { return }
        let payloads = newlyRaised.map { FleetAlertPayload(alert: $0) }
        await relay.publish(payloads)
    }

    private func thresholds(for profile: PostgresProfile) -> FleetMonitorThresholds {
        FleetEnvironmentPolicy.alertThresholds(
            for: profile.effectiveEnvironment.rawValue,
            user: settings.thresholds
        )
    }

    // MARK: - Menu bar summary

    /// Worst condition across the fleet — drives the menu bar icon.
    var worstSeverity: FleetInstanceHealth.Severity {
        var worst = FleetInstanceHealth.Severity.healthy
        for health in healths {
            if severityRank(health.severity) < severityRank(worst) {
                worst = health.severity
            }
        }
        return worst
    }

    /// Lower rank = more severe (mirrors the enum's "most severe first" doc).
    private func severityRank(_ severity: FleetInstanceHealth.Severity) -> Int {
        switch severity {
        case .offline: return 0
        case .blocked: return 1
        case .slow: return 2
        case .busy: return 3
        case .healthy: return 4
        }
    }

    var menuBarSymbolName: String {
        switch worstSeverity {
        case .offline, .blocked: return "exclamationmark.octagon.fill"
        case .slow: return "cylinder.split.1x2.fill"
        case .busy, .healthy: return "cylinder.split.1x2"
        }
    }

    var menuBarTint: Color {
        switch worstSeverity {
        case .offline, .blocked: return .red
        case .slow: return .orange
        case .busy, .healthy: return .green
        }
    }

    // MARK: - Firing-state persistence (edge-trigger across restarts)

    private func loadFiring() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.firingKey) ?? [])
    }

    private func saveFiring(_ keys: Set<String>) {
        UserDefaults.standard.set(Array(keys), forKey: Self.firingKey)
    }
}
