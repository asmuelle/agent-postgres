import CloudKit
import XCTest

@testable import PgAgentApp

/// Pure-logic coverage for the CloudKit alert relay: the deterministic
/// alertId scheme (hub restarts must not duplicate pushes) and the
/// FleetAlertPayload ↔ CKRecord mapping. No CloudKit account required —
/// CKRecord is just a data object here.
final class FleetAlertRelayTests: XCTestCase {

    // MARK: - Deterministic alertId

    func testDeterministicIdStableWithinBucket() {
        // Bucket-aligned epoch (multiple of idBucketSeconds) so the +bucket-1s
        // probe stays inside the same bucket.
        let base = Date(timeIntervalSince1970: 900_000)
        let a = FleetAlertPayload.deterministicId(instanceId: "prof-1", kind: "blockedLocks", at: base)
        let b = FleetAlertPayload.deterministicId(
            instanceId: "prof-1", kind: "blockedLocks",
            at: base.addingTimeInterval(FleetAlertPayload.idBucketSeconds - 1)
        )
        // Same instance+kind inside one bucket → same CloudKit record name,
        // so a hub restart dedupes server-side instead of double-pushing.
        XCTAssertEqual(a, b)
    }

    func testDeterministicIdChangesAcrossBuckets() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let a = FleetAlertPayload.deterministicId(instanceId: "prof-1", kind: "blockedLocks", at: base)
        let b = FleetAlertPayload.deterministicId(
            instanceId: "prof-1", kind: "blockedLocks",
            at: base.addingTimeInterval(FleetAlertPayload.idBucketSeconds)
        )
        XCTAssertNotEqual(a, b)
    }

    func testDeterministicIdSeparatesInstanceAndKind() {
        let at = Date(timeIntervalSince1970: 1_000_000)
        let ids = [
            FleetAlertPayload.deterministicId(instanceId: "prof-1", kind: "blockedLocks", at: at),
            FleetAlertPayload.deterministicId(instanceId: "prof-2", kind: "blockedLocks", at: at),
            FleetAlertPayload.deterministicId(instanceId: "prof-1", kind: "longRunning", at: at),
        ]
        XCTAssertEqual(Set(ids).count, 3)
    }

    func testLocalAlertKeyDropsBucketAndMatchesLocalAlertId() {
        let at = Date(timeIntervalSince1970: 1_000_000)
        let alertId = FleetAlertPayload.deterministicId(instanceId: "prof-1", kind: "longRunning", at: at)
        // Must match FleetAlert.id ("profileId:kind") — that equality is what
        // dedupes a hub push against a locally-generated BGAppRefresh alert.
        let localAlert = FleetAlert(
            profileId: "prof-1", profileName: "Prod", kind: .longRunning, title: "t", body: "b"
        )
        XCTAssertEqual(FleetAlertPayload.localAlertKey(forAlertId: alertId), localAlert.id)
    }

    // MARK: - FleetAlert → payload

    func testPayloadFromFleetAlertMapsFieldsAndSeverity() {
        let at = Date(timeIntervalSince1970: 2_000_000)
        let alert = FleetAlert(
            profileId: "prof-9",
            profileName: "Staging",
            kind: .blockedLocks,
            title: "Staging: lock contention",
            body: "3 backends blocked on locks."
        )
        let payload = FleetAlertPayload(alert: alert, at: at)

        XCTAssertEqual(payload.instanceId, "prof-9")
        XCTAssertEqual(payload.instanceName, "Staging")
        XCTAssertEqual(payload.kind, "blockedLocks")
        XCTAssertEqual(payload.severity, "critical")
        XCTAssertEqual(payload.title, alert.title)
        XCTAssertEqual(payload.detail, alert.body)
        XCTAssertEqual(payload.createdAt, at)
        XCTAssertEqual(
            payload.alertId,
            FleetAlertPayload.deterministicId(instanceId: "prof-9", kind: "blockedLocks", at: at)
        )
    }

    func testSeverityMapping() {
        XCTAssertEqual(FleetAlertPayload.severity(for: .blockedLocks), "critical")
        XCTAssertEqual(FleetAlertPayload.severity(for: .unreachable), "critical")
        XCTAssertEqual(FleetAlertPayload.severity(for: .longRunning), "warning")
    }

    // MARK: - Payload ↔ CKRecord

    func testPayloadRecordRoundTrip() throws {
        let payload = FleetAlertPayload(
            alertId: "prof-1:blockedLocks:1234",
            instanceId: "prof-1",
            instanceName: "Prod EU",
            severity: "critical",
            kind: "blockedLocks",
            title: "Prod EU: lock contention",
            detail: "2 backends blocked on locks.",
            createdAt: Date(timeIntervalSince1970: 3_000_000)
        )

        let record = payload.toRecord()
        XCTAssertEqual(record.recordType, "FleetAlert")
        // Record name == alertId is what makes .ifServerRecordUnchanged a
        // dedupe rather than a duplicate.
        XCTAssertEqual(record.recordID.recordName, payload.alertId)
        XCTAssertEqual(record.recordID.zoneID.zoneName, "FleetAlerts")

        let restored = try XCTUnwrap(FleetAlertPayload(record: record))
        XCTAssertEqual(restored, payload)
    }

    func testPayloadRejectsForeignRecordType() {
        let record = CKRecord(recordType: "SomethingElse")
        record["instanceId"] = "prof-1"
        record["title"] = "t"
        XCTAssertNil(FleetAlertPayload(record: record))
    }

    func testPayloadRejectsRecordMissingRequiredFields() {
        let record = CKRecord(
            recordType: "FleetAlert",
            recordID: CKRecord.ID(recordName: "prof-1:longRunning:7")
        )
        record["title"] = "no instanceId present"
        XCTAssertNil(FleetAlertPayload(record: record))
    }

    func testPayloadFillsDefaultsFromRecordName() throws {
        let record = CKRecord(
            recordType: "FleetAlert",
            recordID: CKRecord.ID(recordName: "prof-1:longRunning:7")
        )
        record["instanceId"] = "prof-1"
        record["title"] = "Prod: slow queries"

        let payload = try XCTUnwrap(FleetAlertPayload(record: record))
        XCTAssertEqual(payload.alertId, "prof-1:longRunning:7")
        XCTAssertEqual(payload.localAlertKey, "prof-1:longRunning")
        XCTAssertEqual(payload.instanceName, "prof-1")
    }
}
