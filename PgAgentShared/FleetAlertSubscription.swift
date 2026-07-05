import CloudKit
import Foundation

// =============================================================================
// FleetAlertSubscription — receiver-side CloudKit plumbing. Creates (or
// removes) the CKQuerySubscription that turns a hub-published FleetAlert
// record into a user-visible push on this device. Idempotent: the fixed
// subscription ID means re-saving replaces rather than duplicates.
//
// The push itself is user-visible (title/body come straight from the record
// via localization args), so the receiving app only needs to route the tap —
// it must NOT post a second local notification for the same alert.
// =============================================================================
enum FleetAlertSubscription {
    /// Create/refresh the FleetAlert push subscription in the private DB.
    static func ensure(
        container: CKContainer = CKContainer(identifier: FleetAlertCloudKit.containerIdentifier)
    ) async throws {
        let subscription = CKQuerySubscription(
            recordType: FleetAlertCloudKit.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: FleetAlertCloudKit.subscriptionID,
            options: [.firesOnRecordCreation]
        )

        let info = CKSubscription.NotificationInfo()
        // Title/body are lifted from the record fields — "%1$@" renders the
        // arg verbatim, so the push shows exactly what the hub composed.
        info.titleLocalizationKey = "%1$@"
        info.titleLocalizationArgs = ["title"]
        info.alertLocalizationKey = "%1$@"
        info.alertLocalizationArgs = ["detail"]
        info.soundName = "default"
        info.category = FleetAlertCloudKit.notificationCategory
        // Keep the payload small (CloudKit caps desiredKeys); everything else
        // is re-fetchable via the record ID, and the record name IS the
        // alertId anyway.
        info.desiredKeys = ["alertId", "instanceId", "kind"]
        subscription.notificationInfo = info

        _ = try await container.privateCloudDatabase.save(subscription)
    }

    /// Remove the subscription (user turned hub alerts off on this device).
    /// Missing subscription counts as success.
    static func remove(
        container: CKContainer = CKContainer(identifier: FleetAlertCloudKit.containerIdentifier)
    ) async throws {
        do {
            _ = try await container.privateCloudDatabase.deleteSubscription(
                withID: FleetAlertCloudKit.subscriptionID
            )
        } catch let error as CKError where error.code == .unknownItem {
            // Already gone — the desired end state.
        }
    }
}
