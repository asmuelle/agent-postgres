import CloudKit
import XCTest

@testable import PgAgentApp

/// Pure-logic coverage for the iCloud user-data sync (roadmap 2.3): the
/// record ↔ model mapping (including the secret-free guarantee), the
/// last-writer-wins merge decisions incl. tombstones, and the persisted
/// engine state (change token + pending tombstones). No CloudKit account
/// required — CKRecord is just a data object here (same approach as
/// FleetAlertRelayTests).
final class CloudSyncEngineTests: XCTestCase {

    // Whole-second dates: the profile payload serializes dates as ISO-8601
    // (no fractional seconds), so sub-second inputs wouldn't round-trip.
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_000_100)
    private let t2 = Date(timeIntervalSince1970: 1_000_200)

    private func makeProfile(
        id: String = "prof-1",
        name: String = "Prod EU",
        updatedAt: Date? = nil
    ) -> PostgresProfile {
        PostgresProfile(
            id: id,
            name: name,
            host: "db.example.com",
            port: 5433,
            database: "appdb",
            user: "alice",
            auth: .keychain,
            tls: .verifyFull,
            tunnel: PostgresTunnel(sshConnectionId: "ssh-42", remoteHost: "127.0.0.1", remotePort: 5432),
            maxPoolSize: 3,
            folderPath: "Work/EU",
            createdAt: t0,
            color: "production",
            notes: "primary",
            environment: .production,
            isReadOnly: true,
            updatedAt: updatedAt ?? t1,
            syncPassword: true
        )
    }

    // MARK: - SyncedProfile record mapping

    func testProfileRecordRoundTrip() throws {
        let profile = makeProfile()
        let record = try SyncedProfileRecord(profile: profile).toRecord()

        XCTAssertEqual(record.recordType, "SyncedProfile")
        // Record name == profile id → re-pushes overwrite, never duplicate.
        XCTAssertEqual(record.recordID.recordName, "prof-1")
        XCTAssertEqual(record.recordID.zoneID.zoneName, "UserData")
        // Surfaced console/debug fields.
        XCTAssertEqual(record["name"] as? String, "Prod EU")
        XCTAssertEqual(record["environment"] as? String, "production")
        XCTAssertEqual(record["isReadOnly"] as? Int64, 1)
        XCTAssertEqual(record["color"] as? String, "production")
        XCTAssertEqual(record["sshProfileRef"] as? String, "ssh-42")
        XCTAssertEqual(record["updatedAt"] as? Date, t1)
        XCTAssertEqual(record["deleted"] as? Int64, 0)

        let restored = try XCTUnwrap(SyncedProfileRecord(record: record))
        XCTAssertFalse(restored.deleted)
        let restoredProfile = try XCTUnwrap(restored.profile())
        XCTAssertEqual(restoredProfile, profile)
    }

    func testProfilePayloadNeverContainsSecrets() throws {
        // Worst case: an in-memory profile carrying an ephemeral password.
        var profile = makeProfile()
        profile.auth = .ephemeralPassword("hunter2-super-secret")

        let record = try SyncedProfileRecord(profile: profile).toRecord()
        let payload = try XCTUnwrap(record["payload"] as? String)

        XCTAssertFalse(payload.contains("hunter2"), "secret value leaked into the synced payload")
        XCTAssertNil(
            SyncedProfileRecord.firstSecretKeyPath(inJSONData: Data(payload.utf8)),
            "payload contains a secret-shaped key"
        )
        // The auth enum degrades to its discriminator only.
        XCTAssertTrue(payload.contains(#""kind":"keychain""#))
    }

    func testSecretKeyScannerCatchesInjectedKeys() throws {
        // Guards the guard: if someone adds a `password` field to the
        // profile's Codable surface, the scanner must trip.
        let leaky = #"{"host":"h","nested":{"proxyPassword":"x"},"arr":[{"apiToken":"y"}]}"#
        let hit = SyncedProfileRecord.firstSecretKeyPath(inJSONData: Data(leaky.utf8))
        XCTAssertNotNil(hit)

        let clean = #"{"host":"h","auth":{"kind":"keychain"},"port":5432}"#
        XCTAssertNil(SyncedProfileRecord.firstSecretKeyPath(inJSONData: Data(clean.utf8)))

        // Boolean flags whose *name* mentions passwords are fine — a Bool
        // can't carry a secret (this is exactly `syncPassword`) — but the
        // same key holding a string must trip.
        let boolFlag = #"{"syncPassword":true,"port":5432}"#
        XCTAssertNil(SyncedProfileRecord.firstSecretKeyPath(inJSONData: Data(boolFlag.utf8)))
        let stringLeak = #"{"syncPassword":"hunter2"}"#
        XCTAssertNotNil(SyncedProfileRecord.firstSecretKeyPath(inJSONData: Data(stringLeak.utf8)))
    }

    func testProfileTombstoneRecordRoundTrip() throws {
        let record = SyncedProfileRecord.tombstone(profileId: "prof-9", deletedAt: t1).toRecord()
        XCTAssertEqual(record["deleted"] as? Int64, 1)
        XCTAssertEqual(record["deletedAt"] as? Date, t1)

        let restored = try XCTUnwrap(SyncedProfileRecord(record: record))
        XCTAssertTrue(restored.deleted)
        XCTAssertNil(restored.profile(), "tombstones carry no profile")
        XCTAssertFalse(restored.isExpiredTombstone(now: t1.addingTimeInterval(29 * 24 * 3600)))
        XCTAssertTrue(restored.isExpiredTombstone(now: t1.addingTimeInterval(31 * 24 * 3600)))
    }

    func testLiveProfileRecordWithoutPayloadIsRejected() {
        let record = CKRecord(
            recordType: "SyncedProfile",
            recordID: CKRecord.ID(recordName: "prof-1", zoneID: UserDataCloudKit.zoneID)
        )
        record["deleted"] = Int64(0)
        XCTAssertNil(SyncedProfileRecord(record: record))
    }

    // MARK: - SyncedSavedQuery record mapping

    func testSavedQueryRecordRoundTrip() throws {
        let entry = PostgresSavedQuery(
            id: UUID(),
            profileId: "prof-1",
            name: "list locks",
            sql: "SELECT * FROM pg_locks;",
            createdAt: t0,
            updatedAt: t1
        )
        let record = SyncedSavedQueryRecord(entry: entry).toRecord()
        XCTAssertEqual(record.recordType, "SyncedSavedQuery")
        XCTAssertEqual(record.recordID.recordName, entry.id.uuidString)
        XCTAssertEqual(record["title"] as? String, "list locks")

        let restored = try XCTUnwrap(SyncedSavedQueryRecord(record: record))
        XCTAssertEqual(try XCTUnwrap(restored.savedQuery()), entry)
    }

    func testSavedQueryTombstoneAndExpiry() throws {
        let id = UUID()
        let record = SyncedSavedQueryRecord
            .tombstone(queryId: id.uuidString, profileId: "prof-1", deletedAt: t0)
            .toRecord()
        let restored = try XCTUnwrap(SyncedSavedQueryRecord(record: record))
        XCTAssertTrue(restored.deleted)
        XCTAssertNil(restored.savedQuery())
        XCTAssertFalse(restored.isExpiredTombstone(now: t0.addingTimeInterval(1 * 24 * 3600)))
        XCTAssertTrue(restored.isExpiredTombstone(now: t0.addingTimeInterval(31 * 24 * 3600)))
    }

    // MARK: - LWW merge: profiles

    func testProfileMergeRemoteNewerWins() throws {
        let local = makeProfile(name: "Old name", updatedAt: t0)
        var newer = makeProfile(name: "New name", updatedAt: t1)
        newer.notes = "edited elsewhere"
        let remote = try SyncedProfileRecord(profile: newer)

        let merge = UserDataSyncMerge.mergeProfiles(local: [local], remote: [remote], honorDeletes: true)
        XCTAssertEqual(merge.upserts.map(\.name), ["New name"])
        XCTAssertTrue(merge.deleteIds.isEmpty)
    }

    func testProfileMergeLocalNewerKept() throws {
        let local = makeProfile(name: "Local newest", updatedAt: t2)
        let older = makeProfile(name: "Stale remote", updatedAt: t0)
        let remote = try SyncedProfileRecord(profile: older)

        let merge = UserDataSyncMerge.mergeProfiles(local: [local], remote: [remote], honorDeletes: true)
        XCTAssertTrue(merge.upserts.isEmpty, "older remote must not clobber newer local")
    }

    func testProfileMergeEqualTimestampKeepsLocal() throws {
        // Our own pushes echo back with identical stamps — must be a no-op.
        let local = makeProfile(updatedAt: t1)
        let remote = try SyncedProfileRecord(profile: local)
        let merge = UserDataSyncMerge.mergeProfiles(local: [local], remote: [remote], honorDeletes: true)
        XCTAssertTrue(merge.upserts.isEmpty)
    }

    func testProfileMergeInsertsUnknownRemote() throws {
        let incoming = makeProfile(id: "prof-new", updatedAt: t0)
        let remote = try SyncedProfileRecord(profile: incoming)
        let merge = UserDataSyncMerge.mergeProfiles(local: [], remote: [remote], honorDeletes: true)
        XCTAssertEqual(merge.upserts.map(\.id), ["prof-new"])
    }

    func testProfileMergeTombstoneDeletesWhenNewer() {
        let local = makeProfile(updatedAt: t0)
        let tombstone = SyncedProfileRecord.tombstone(profileId: "prof-1", deletedAt: t1)
        let merge = UserDataSyncMerge.mergeProfiles(local: [local], remote: [tombstone], honorDeletes: true)
        XCTAssertEqual(merge.deleteIds, ["prof-1"])
        XCTAssertTrue(merge.upserts.isEmpty)
    }

    func testProfileMergeTombstoneLosesToNewerLocalEdit() {
        // Deleted on device A at t0, edited on device B at t1 → edit wins.
        let local = makeProfile(updatedAt: t1)
        let tombstone = SyncedProfileRecord.tombstone(profileId: "prof-1", deletedAt: t0)
        let merge = UserDataSyncMerge.mergeProfiles(local: [local], remote: [tombstone], honorDeletes: true)
        XCTAssertTrue(merge.deleteIds.isEmpty)
    }

    func testProfileMergeFirstSyncIsUnionNeverDeletes() {
        // Safety rail: before the first sync completes, tombstones are
        // ignored so enabling sync can never delete local data.
        let local = makeProfile(updatedAt: t0)
        let tombstone = SyncedProfileRecord.tombstone(profileId: "prof-1", deletedAt: t2)
        let merge = UserDataSyncMerge.mergeProfiles(local: [local], remote: [tombstone], honorDeletes: false)
        XCTAssertTrue(merge.deleteIds.isEmpty)
        XCTAssertTrue(merge.upserts.isEmpty)
    }

    func testProfileMergeTombstoneForUnknownProfileIsNoop() {
        let tombstone = SyncedProfileRecord.tombstone(profileId: "prof-gone", deletedAt: t1)
        let merge = UserDataSyncMerge.mergeProfiles(local: [], remote: [tombstone], honorDeletes: true)
        XCTAssertTrue(merge.deleteIds.isEmpty)
        XCTAssertTrue(merge.upserts.isEmpty)
    }

    // MARK: - LWW merge: saved queries

    func testSavedQueryMergeLWWAndTombstones() {
        let keptId = UUID()
        let replacedId = UUID()
        let deletedId = UUID()
        let local = [
            PostgresSavedQuery(id: keptId, profileId: "p", name: "kept", sql: "SELECT 1", createdAt: t0, updatedAt: t2),
            PostgresSavedQuery(id: replacedId, profileId: "p", name: "old", sql: "SELECT 2", createdAt: t0, updatedAt: t0),
            PostgresSavedQuery(id: deletedId, profileId: "p", name: "doomed", sql: "SELECT 3", createdAt: t0, updatedAt: t0),
        ]
        let remote = [
            // Older than the local "kept" edit → skipped.
            SyncedSavedQueryRecord(entry: PostgresSavedQuery(
                id: keptId, profileId: "p", name: "stale", sql: "SELECT 0", createdAt: t0, updatedAt: t1
            )),
            // Newer than local → replaces.
            SyncedSavedQueryRecord(entry: PostgresSavedQuery(
                id: replacedId, profileId: "p", name: "new", sql: "SELECT 22", createdAt: t0, updatedAt: t1
            )),
            // Tombstone newer than local → deletes.
            .tombstone(queryId: deletedId.uuidString, profileId: "p", deletedAt: t1),
            // Brand-new remote entry → inserted.
            SyncedSavedQueryRecord(entry: PostgresSavedQuery(
                profileId: "p", name: "fresh", sql: "SELECT 4", createdAt: t0, updatedAt: t0
            )),
        ]

        let merge = UserDataSyncMerge.mergeSavedQueries(local: local, remote: remote, honorDeletes: true)
        XCTAssertEqual(Set(merge.upserts.map(\.name)), ["new", "fresh"])
        XCTAssertEqual(merge.deletes.map(\.entryId), [deletedId])
        XCTAssertEqual(merge.deletes.map(\.profileId), ["p"])
    }

    func testSavedQueryMergeFirstSyncIgnoresTombstones() {
        let id = UUID()
        let local = [
            PostgresSavedQuery(id: id, profileId: "p", name: "mine", sql: "SELECT 1", createdAt: t0, updatedAt: t0)
        ]
        let remote: [SyncedSavedQueryRecord] = [
            .tombstone(queryId: id.uuidString, profileId: "p", deletedAt: t2)
        ]
        let merge = UserDataSyncMerge.mergeSavedQueries(local: local, remote: remote, honorDeletes: false)
        XCTAssertTrue(merge.deletes.isEmpty)
    }

    // MARK: - Engine state persistence (change token + tombstones)

    func testEngineStateRoundTripsThroughJSON() throws {
        let tokenBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        var state = CloudSyncEngineState(
            changeTokenData: tokenBytes,
            hasCompletedInitialSync: true,
            pendingTombstones: [
                PendingSyncTombstone(kind: .profile, recordName: "prof-1", profileId: nil, deletedAt: t0),
                PendingSyncTombstone(kind: .savedQuery, recordName: UUID().uuidString, profileId: "prof-1", deletedAt: t1),
            ],
            lastSyncAt: t2
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(CloudSyncEngineState.self, from: encoder.encode(state))
        XCTAssertEqual(restored, state)

        // Retention purge: only tombstones inside the 30-day window survive.
        state.purgeExpiredPendingTombstones(now: t1.addingTimeInterval(31 * 24 * 3600))
        XCTAssertEqual(state.pendingTombstones.count, 0)

        var fresh = restored
        fresh.purgeExpiredPendingTombstones(now: t1.addingTimeInterval(1 * 24 * 3600))
        XCTAssertEqual(fresh.pendingTombstones.count, 2)
    }

    func testEngineStateDecodesFromEmptyObject() throws {
        // Forward/backward compatibility: an old (or missing-fields) state
        // file must decode to safe defaults, never crash the engine.
        let state = try JSONDecoder().decode(CloudSyncEngineState.self, from: Data("{}".utf8))
        XCTAssertNil(state.changeTokenData)
        XCTAssertFalse(state.hasCompletedInitialSync)
        XCTAssertTrue(state.pendingTombstones.isEmpty)
        XCTAssertNil(state.lastSyncAt)
    }

    // MARK: - Model backward compatibility

    func testProfileDecodesWithoutSyncFields() throws {
        // A profile persisted before roadmap 2.3 has neither `updatedAt`
        // nor `syncPassword` — it must decode with updatedAt == createdAt
        // and password sync off.
        let legacy = """
        {
          "id": "prof-legacy",
          "name": "Old",
          "host": "h",
          "port": 5432,
          "database": "d",
          "user": "u",
          "auth": {"kind": "keychain"},
          "tls": "require",
          "createdAt": "2025-01-02T03:04:05Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(PostgresProfile.self, from: Data(legacy.utf8))
        XCTAssertEqual(profile.updatedAt, profile.createdAt)
        XCTAssertFalse(profile.syncPassword)
    }
}
