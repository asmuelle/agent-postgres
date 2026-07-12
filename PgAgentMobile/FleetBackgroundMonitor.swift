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

    private let store = FleetHealthStore.withWidgetPublishing()
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
        let previous = loadFiring()
        var firingNow = Set<String>()
        var newAlerts: [FleetAlert] = []
        for profile in profiles {
            let thresholds = FleetEnvironmentPolicy.alertThresholds(
                for: profile.effectiveEnvironment.rawValue,
                user: settings.thresholds)
            let result = evaluateFleetAlerts(
                healths: [store.health(for: profile.id)],
                names: names,
                thresholds: thresholds,
                previouslyFiring: previous)
            firingNow.formUnion(result.firingNow)
            newAlerts.append(contentsOf: result.newAlerts)
        }

        saveFiring(firingNow)
        for alert in newAlerts {
            await post(alert)
        }
    }

    // MARK: - Hub-alert dedupe

    /// A Mac-hub push arrived for `alertId` ("instanceId:kind:bucket"). Mark
    /// the underlying condition ("instanceId:kind") as already-notified so
    /// the next BGAppRefresh pass doesn't post a duplicate local
    /// notification for the same ongoing problem. If the condition clears
    /// before that pass, the key drops out of the firing set as usual.
    func noteHubAlert(alertId: String) {
        var firing = loadFiring()
        firing.insert(FleetAlertPayload.localAlertKey(forAlertId: alertId))
        saveFiring(firing)
    }

    // MARK: - Notifications

    private func post(_ alert: FleetAlert) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        // Same category as hub pushes → same explicit "View" action.
        content.categoryIdentifier = FleetAlertCloudKit.notificationCategory
        // Route notification taps to the affected instance AND the specific
        // problem (kind + optional blocker pid) — HubAlertReceiver is the
        // shared UNUserNotificationCenter delegate and parses these keys.
        var userInfo: [String: Any] = [
            "instanceId": alert.profileId,
            "kind": alert.kind.rawValue,
        ]
        if let blockerPid = alert.blockerPid {
            userInfo["blockerPid"] = NSNumber(value: blockerPid)
        }
        content.userInfo = userInfo
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
