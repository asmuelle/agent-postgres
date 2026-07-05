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
//   2. Routes notification taps to the affected instance via
//      MobileAlertRouter (full lock-chain deep link is slice 1.2).
// =============================================================================

extension Notification.Name {
    /// Posted after a hub alert push arrives, so fleet UI can refresh.
    static let pgFleetHubAlertReceived = Notification.Name("pgFleetHubAlertReceived")
}

/// Pending deep-link route. The root view observes this and selects the
/// instance when a notification is tapped.
@MainActor
final class MobileAlertRouter: ObservableObject {
    static let shared = MobileAlertRouter()
    @Published var pendingInstanceId: String?
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

    /// Instance id for routing, from a push's userInfo.
    nonisolated static func instanceId(fromPushUserInfo userInfo: [AnyHashable: Any]) -> String? {
        guard let dictionary = userInfo as? [String: Any],
              let note = CKNotification(fromRemoteNotificationDictionary: dictionary),
              let query = note as? CKQueryNotification
        else { return nil }
        if let explicit = query.recordFields?["instanceId"] as? String { return explicit }
        guard let alertId = query.recordID?.recordName else { return nil }
        // alertId = "<instanceId>:<kind>:<bucket>" — strip the two suffixes.
        let localKey = FleetAlertPayload.localAlertKey(forAlertId: alertId)
        guard let idx = localKey.lastIndex(of: ":") else { return nil }
        return String(localKey[..<idx])
    }
}

// MARK: - UNUserNotificationCenterDelegate (tap routing)

extension HubAlertReceiver: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        // Hub push? Parse the CloudKit envelope. Local BGAppRefresh alert?
        // FleetBackgroundMonitor stamps instanceId into userInfo directly.
        let instanceId = Self.instanceId(fromPushUserInfo: userInfo)
            ?? (userInfo["instanceId"] as? String)
        if let instanceId {
            Task { @MainActor in
                MobileAlertRouter.shared.pendingInstanceId = instanceId
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
