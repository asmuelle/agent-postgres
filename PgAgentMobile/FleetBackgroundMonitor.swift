import BackgroundTasks
import Foundation
import UserNotifications
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// FleetBackgroundMonitor — drives the periodic BGAppRefresh poll: refresh every
// saved instance's health, evaluate it against the user's thresholds, and post a
// local notification for any newly-crossed condition. Firing state is persisted
// so a persistent problem notifies once, not on every wake.
//
// Registration is handled by the SwiftUI `.backgroundTask(.appRefresh(taskId))`
// scene modifier; this type owns scheduling, the refresh body, and notifications.
// =============================================================================
@MainActor
final class FleetBackgroundMonitor {
    static let shared = FleetBackgroundMonitor()
    static let taskId = "com.pgagent.mobile.fleetrefresh"

    /// iOS won't run app refresh more often than ~15 min regardless; this is the
    /// earliest we ask for.
    private static let earliestInterval: TimeInterval = 15 * 60
    private static let firingKey = "fleet.firingAlerts"

    private let store = FleetHealthStore()
    private let settings = FleetMonitorSettings.shared

    private init() {}

    /// Ask for notification permission the first time the user opts in. Safe to
    /// call repeatedly — only prompts when status is undetermined.
    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings()
        guard current.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Submit the next BGAppRefresh request. No-op when the user has background
    /// alerts disabled.
    func schedule() {
        guard settings.backgroundAlertsEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.earliestInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Cancel any pending refresh — called when the user turns alerts off.
    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskId)
    }

    /// The background work body, invoked by the `.backgroundTask` modifier.
    func runBackgroundRefresh() async {
        guard settings.backgroundAlertsEnabled else { return }

        let profiles = PostgresProfileStore.shared.profiles
        guard !profiles.isEmpty else { return }

        await store.refresh(profiles: profiles)

        let names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.name) })
        let healths = profiles.map { store.health(for: $0.id) }
        let previous = loadFiring()

        let result = evaluateFleetAlerts(
            healths: healths,
            names: names,
            thresholds: settings.thresholds,
            previouslyFiring: previous
        )

        saveFiring(result.firingNow)
        for alert in result.newAlerts {
            await post(alert)
        }
    }

    // MARK: - Notifications

    private func post(_ alert: FleetAlert) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Firing-state persistence

    private func loadFiring() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.firingKey) ?? [])
    }

    private func saveFiring(_ keys: Set<String>) {
        UserDefaults.standard.set(Array(keys), forKey: Self.firingKey)
    }
}
