import CloudKit
import Foundation
import SwiftUI
import UIKit
import UserNotifications
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// HubAlertReceiver — iOS side of the Mac-as-monitoring-hub relay. When
// "Receive alerts from your Mac hub" is on, this device holds a
// CKQuerySubscription on FleetAlert records: the Mac hub saves a record, iOS
// gets a user-visible push within seconds — even if the app was never opened
// that day.
//
// The CKQuerySubscription push is ALREADY user-visible (title/body baked in
// by FleetAlertSubscription), so receipt handling only:
//   1. Dedupes against the local BGAppRefresh monitor — the alertId's
//      instance:kind prefix is inserted into FleetBackgroundMonitor's firing
//      set, so the next local poll treats the condition as already-notified.
//   2. Routes notification taps to the *problem*, not just the instance:
//      MobileAlertRouter carries (instanceId, alert kind, optional blocker
//      pid) so a lock-contention tap lands on the lock-chain tab with the
//      offending session highlighted (roadmap 1.2).
// =============================================================================

extension Notification.Name {
    /// Posted after a hub alert push arrives, so fleet UI can refresh.
    static let pgFleetHubAlertReceived = Notification.Name("pgFleetHubAlertReceived")
}

/// Where a tapped alert should land: the affected instance, plus enough
/// context to open the most relevant tab of the instance detail —
/// blocked/deadlock kinds go to the lock chain (with the root blocker
/// highlighted when known), slow/busy kinds to the activity list, offline
/// to the fleet overview.
struct MobileAlertRoute: Equatable, Sendable {
    let instanceId: String
    let kind: FleetAlertKind?
    /// Root blocker pid from the alert payload, when the hub captured one.
    /// Nil is fine — the lock view falls back to highlighting the current
    /// root blocker after a fresh fetch (highlight-by-refetch).
    let blockerPid: Int32?
}

/// Pending deep-link route. The root view observes this, presents the fleet
/// monitor, and MobileFleetMonitorView consumes the route by pushing the
/// instance detail on the right tab.
@MainActor
final class MobileAlertRouter: ObservableObject {
    static let shared = MobileAlertRouter()
    @Published var pendingRoute: MobileAlertRoute?
}

@MainActor
final class HubAlertReceiver: NSObject, ObservableObject {
    static let shared = HubAlertReceiver()

    /// Human-readable subscription state for the settings UI.
    @Published private(set) var statusMessage: String?

    private override init() { super.init() }

    // MARK: - Enable / disable (settings toggle)

    func enable() async {
        await FleetBackgroundMonitor.shared.requestAuthorizationIfNeeded()
        UIApplication.shared.registerForRemoteNotifications()
        do {
            try await FleetAlertSubscription.ensure()
            statusMessage = nil
        } catch {
            statusMessage = "Couldn't subscribe: \(error.localizedDescription)"
        }
    }

    func disable() async {
        do {
            try await FleetAlertSubscription.remove()
            statusMessage = nil
        } catch {
            statusMessage = "Couldn't remove subscription: \(error.localizedDescription)"
        }
    }

    /// Re-assert the subscription at launch (cheap, idempotent) so a restore
    /// from backup or an expired subscription heals itself.
    func refreshIfEnabled() async {
        guard FleetMonitorSettings.shared.receiveHubAlertsEnabled else { return }
        UIApplication.shared.registerForRemoteNotifications()
        try? await FleetAlertSubscription.ensure()
    }

    // MARK: - Push receipt

    /// Handle an incoming CloudKit push. The alert UI was already shown by
    /// the system; we only dedupe + let live views refresh.
    func handleRemoteNotification(userInfo: [AnyHashable: Any]) -> UIBackgroundFetchResult {
        guard let dictionary = userInfo as? [String: Any],
              let note = CKNotification(fromRemoteNotificationDictionary: dictionary),
              let query = note as? CKQueryNotification,
              note.subscriptionID == FleetAlertCloudKit.subscriptionID
        else { return .noData }

        // The record name IS the deterministic alertId — no fetch needed.
        let alertId = (query.recordFields?["alertId"] as? String)
            ?? query.recordID?.recordName

        if let alertId {
            FleetBackgroundMonitor.shared.noteHubAlert(alertId: alertId)
        }

        NotificationCenter.default.post(name: .pgFleetHubAlertReceived, object: nil)
        return .newData
    }

    /// Deep-link route from a hub push's userInfo (CloudKit envelope), or nil
    /// when the payload isn't a hub alert.
    nonisolated static func route(fromPushUserInfo userInfo: [AnyHashable: Any]) -> MobileAlertRoute? {
        guard let dictionary = userInfo as? [String: Any],
              let note = CKNotification(fromRemoteNotificationDictionary: dictionary),
              let query = note as? CKQueryNotification
        else { return nil }

        let fields = query.recordFields
        let alertId = query.recordID?.recordName

        let instanceId: String? = (fields?["instanceId"] as? String) ?? alertId.flatMap { id in
            // alertId = "<instanceId>:<kind>:<bucket>" — strip the two suffixes.
            let localKey = FleetAlertPayload.localAlertKey(forAlertId: id)
            guard let idx = localKey.lastIndex(of: ":") else { return nil }
            return String(localKey[..<idx])
        }
        guard let instanceId else { return nil }

        let kindRaw = (fields?["kind"] as? String) ?? alertId.flatMap(FleetAlertPayload.kind(forAlertId:))
        return MobileAlertRoute(
            instanceId: instanceId,
            kind: kindRaw.flatMap(FleetAlertKind.init(rawValue:)),
            blockerPid: (fields?["blockerPid"] as? NSNumber)?.int32Value
        )
    }

    /// Deep-link route from a local BGAppRefresh notification's userInfo
    /// (FleetBackgroundMonitor stamps the keys directly), or nil.
    nonisolated static func route(fromLocalUserInfo userInfo: [AnyHashable: Any]) -> MobileAlertRoute? {
        guard let instanceId = userInfo["instanceId"] as? String else { return nil }
        return MobileAlertRoute(
            instanceId: instanceId,
            kind: (userInfo["kind"] as? String).flatMap(FleetAlertKind.init(rawValue:)),
            blockerPid: (userInfo["blockerPid"] as? NSNumber)?.int32Value
        )
    }

    // MARK: - Notification category (explicit "View" action)

    /// The FLEET_ALERT category both the hub push (subscription info.category)
    /// and local BGAppRefresh alerts are stamped with. One explicit "View"
    /// action — destructive fixes deliberately do NOT appear here: killing a
    /// backend must go through the in-app preview + biometric flow.
    nonisolated static let viewActionIdentifier = "PG_FLEET_ALERT_VIEW"

    nonisolated static func registerNotificationCategories(
        center: UNUserNotificationCenter = .current()
    ) {
        let view = UNNotificationAction(
            identifier: viewActionIdentifier,
            title: "View",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: FleetAlertCloudKit.notificationCategory,
            actions: [view],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }
}

// MARK: - UNUserNotificationCenterDelegate (tap routing)

extension HubAlertReceiver: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Default tap and the explicit "View" action route identically; a
        // dismissed notification routes nowhere.
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier
            || response.actionIdentifier == Self.viewActionIdentifier
        else {
            completionHandler()
            return
        }
        let userInfo = response.notification.request.content.userInfo
        // Hub push? Parse the CloudKit envelope. Local BGAppRefresh alert?
        // FleetBackgroundMonitor stamps the route keys into userInfo directly.
        let route = Self.route(fromPushUserInfo: userInfo)
            ?? Self.route(fromLocalUserInfo: userInfo)
        if let route {
            Task { @MainActor in
                MobileAlertRouter.shared.pendingRoute = route
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}

// MARK: - App delegate (remote-notification plumbing)

@MainActor
final class MobileAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = HubAlertReceiver.shared
        HubAlertReceiver.registerNotificationCategories()
        Task { await HubAlertReceiver.shared.refreshIfEnabled() }
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let result = HubAlertReceiver.shared.handleRemoteNotification(userInfo: userInfo)
        completionHandler(result)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Simulator / entitlement-less builds land here — non-fatal: the
        // BGAppRefresh fallback path still works.
    }
}
