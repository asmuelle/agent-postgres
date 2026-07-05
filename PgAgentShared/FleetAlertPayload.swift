import CloudKit
import Foundation

// =============================================================================
// FleetAlertPayload — the wire format of one fleet alert relayed from the Mac
// monitoring hub to iPhone/iPad through the user's private CloudKit database.
// Pure value type + CKRecord mapping; no networking here so the mapping and
// the deterministic-id scheme stay unit-testable without a CloudKit account.
// =============================================================================

/// Shared CloudKit names. Both sides (hub publisher, iOS subscriber) must
/// agree on these — change them only with a migration story.
enum FleetAlertCloudKit {
    static let containerIdentifier = "iCloud.com.pgagent.pgagent"
    static let zoneName = "FleetAlerts"
    static let recordType = "FleetAlert"
    static let subscriptionID = "fleet-alerts-v1"
    static let notificationCategory = "FLEET_ALERT"

    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }
}

struct FleetAlertPayload: Codable, Equatable, Sendable, Identifiable {
    /// Deterministic — derived from (instance, kind, time bucket) so a hub
    /// restart re-publishing the same ongoing condition maps to the SAME
    /// CloudKit record name and dedupes server-side instead of double-pushing.
    let alertId: String
    let instanceId: String
    let instanceName: String
    /// "critical" | "warning" — coarse, for notification styling/sorting.
    let severity: String
    /// FleetAlertKind rawValue ("longRunning" | "blockedLocks" | "unreachable").
    let kind: String
    let title: String
    let detail: String
    let createdAt: Date
    /// Root blocker pid for blocked-locks alerts (roadmap 1.2 deep link).
    /// Optional and backward-compatible: old hubs simply omit it, old
    /// receivers ignore it (Codable decodeIfPresent / optional CKRecord field).
    let blockerPid: Int32?

    var id: String { alertId }

    // MARK: - Deterministic id scheme

    /// Alerts raised for the same (instance, kind) inside one bucket collapse
    /// into one CloudKit record. 15 minutes: long enough to absorb hub
    /// restarts, short enough that a condition which clears and recurs later
    /// still produces a fresh alert record.
    static let idBucketSeconds: TimeInterval = 15 * 60

    static func deterministicId(
        instanceId: String,
        kind: String,
        at date: Date,
        bucketSeconds: TimeInterval = FleetAlertPayload.idBucketSeconds
    ) -> String {
        let bucket = Int(date.timeIntervalSince1970 / bucketSeconds)
        return "\(instanceId):\(kind):\(bucket)"
    }

    /// The key the iOS background monitor uses for its edge-triggered firing
    /// set (`FleetAlert.id` == "profileId:kind"). Dropping the trailing time
    /// bucket from a relay alertId yields exactly that key, which is how a
    /// hub push and a locally-generated BGAppRefresh alert dedupe against
    /// each other.
    static func localAlertKey(forAlertId alertId: String) -> String {
        guard let idx = alertId.lastIndex(of: ":") else { return alertId }
        return String(alertId[..<idx])
    }

    var localAlertKey: String { Self.localAlertKey(forAlertId: alertId) }

    /// The FleetAlertKind rawValue baked into a relay alertId
    /// ("instanceId:kind:bucket") — the last component of the local alert
    /// key. Used to route a notification tap when the push's recordFields
    /// were truncated. Nil when the id has no kind component.
    static func kind(forAlertId alertId: String) -> String? {
        let key = localAlertKey(forAlertId: alertId)
        guard let idx = key.lastIndex(of: ":") else { return nil }
        return String(key[key.index(after: idx)...])
    }

    // MARK: - From the shared alert engine

    init(alert: FleetAlert, at date: Date = Date()) {
        self.init(
            alertId: Self.deterministicId(instanceId: alert.profileId, kind: alert.kind.rawValue, at: date),
            instanceId: alert.profileId,
            instanceName: alert.profileName,
            severity: Self.severity(for: alert.kind),
            kind: alert.kind.rawValue,
            title: alert.title,
            detail: alert.body,
            createdAt: date,
            blockerPid: alert.blockerPid
        )
    }

    init(
        alertId: String, instanceId: String, instanceName: String, severity: String,
        kind: String, title: String, detail: String, createdAt: Date,
        blockerPid: Int32? = nil
    ) {
        self.alertId = alertId
        self.instanceId = instanceId
        self.instanceName = instanceName
        self.severity = severity
        self.kind = kind
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
        self.blockerPid = blockerPid
    }

    static func severity(for kind: FleetAlertKind) -> String {
        switch kind {
        case .blockedLocks, .unreachable: return "critical"
        case .longRunning: return "warning"
        }
    }

    // MARK: - CKRecord mapping

    private enum Field {
        static let alertId = "alertId"
        static let instanceId = "instanceId"
        static let instanceName = "instanceName"
        static let severity = "severity"
        static let kind = "kind"
        static let title = "title"
        static let detail = "detail"
        static let createdAt = "createdAt"
        static let blockerPid = "blockerPid"
    }

    /// Record name IS the alertId, so `.ifServerRecordUnchanged` turns hub
    /// republishes into benign `serverRecordChanged` no-ops.
    func toRecord(zoneID: CKRecordZone.ID = FleetAlertCloudKit.zoneID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: alertId, zoneID: zoneID)
        let record = CKRecord(recordType: FleetAlertCloudKit.recordType, recordID: recordID)
        record[Field.alertId] = alertId
        record[Field.instanceId] = instanceId
        record[Field.instanceName] = instanceName
        record[Field.severity] = severity
        record[Field.kind] = kind
        record[Field.title] = title
        record[Field.detail] = detail
        record[Field.createdAt] = createdAt
        // Optional field: absent (not null) when there is no blocker pid, so
        // records from pre-1.2 hubs and pidless alerts look identical.
        if let blockerPid {
            record[Field.blockerPid] = Int64(blockerPid)
        }
        return record
    }

    init?(record: CKRecord) {
        guard record.recordType == FleetAlertCloudKit.recordType,
              let instanceId = record[Field.instanceId] as? String,
              let title = record[Field.title] as? String
        else { return nil }
        self.init(
            alertId: (record[Field.alertId] as? String) ?? record.recordID.recordName,
            instanceId: instanceId,
            instanceName: (record[Field.instanceName] as? String) ?? instanceId,
            severity: (record[Field.severity] as? String) ?? "warning",
            kind: (record[Field.kind] as? String) ?? FleetAlertKind.longRunning.rawValue,
            title: title,
            detail: (record[Field.detail] as? String) ?? "",
            createdAt: (record[Field.createdAt] as? Date) ?? record.creationDate ?? Date(),
            blockerPid: (record[Field.blockerPid] as? Int64).flatMap { Int32(exactly: $0) }
        )
    }
}
