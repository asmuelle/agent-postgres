import CloudKit
import Foundation

// =============================================================================
// UserDataSyncRecords — CKRecord mapping for opt-in iCloud sync (roadmap 2.3).
//
// The user's Postgres connection profiles (sans secrets) and saved queries
// live as records in the custom "UserData" zone of the PRIVATE CloudKit
// database — deliberately separate from the "FleetAlerts" zone so alert
// relaying and user-data sync can evolve (and be wiped) independently.
//
// Pure value types + CKRecord mapping, no networking — mirrors
// FleetAlertPayload so the mapping, the secret-free guarantee, and the
// last-writer-wins merge stay unit-testable without a CloudKit account.
//
// SECRETS NEVER SYNC THROUGH THESE RECORDS. `PostgresAuthMethod` already
// encodes only a discriminator (never an ephemeral password), and
// `sanitizedPayloadJSON` re-verifies at encode time that no secret-shaped
// key survived. Passwords travel exclusively via iCloud Keychain when the
// user opts in per connection (see KeychainManager's synchronizable variant).
// =============================================================================

/// Shared CloudKit names for the user-data sync zone. Both platforms must
/// agree on these — change them only with a migration story.
enum UserDataCloudKit {
    /// Same container as the alert relay; different zone.
    static let containerIdentifier = FleetAlertCloudKit.containerIdentifier
    static let zoneName = "UserData"
    static let profileRecordType = "SyncedProfile"
    static let savedQueryRecordType = "SyncedSavedQuery"
    static let subscriptionID = "user-data-sync-v1"

    /// Tombstoned records older than this are purged from CloudKit on sync.
    /// 30 days comfortably covers a device that was offline for a month —
    /// after that, a stale device re-uploading a deleted profile is the
    /// accepted (and recoverable) failure mode.
    static let tombstoneRetention: TimeInterval = 30 * 24 * 60 * 60

    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }
}

enum UserDataSyncRecordError: Error, Equatable {
    /// The sanitized payload still contained a secret-shaped key. This is a
    /// programmer error (a new secret field was added to PostgresProfile
    /// without opting it out of Codable) — the record is NOT uploaded.
    case secretMaterialDetected(String)
}

// =============================================================================
// SyncedProfile — one Postgres connection profile, secret-free
// =============================================================================

/// Record name == profile id, so re-pushes overwrite rather than duplicate.
/// The full (sanitized) profile rides in a `payload` JSON field — schema
/// changes to PostgresProfile don't need CloudKit schema changes. A few
/// fields are surfaced as real record fields for console debugging and
/// potential server-side queries: name, environment tag, read-only flag,
/// color, and the SSH tunnel profile reference id.
struct SyncedProfileRecord: Equatable, Identifiable, Sendable {
    let id: String
    /// Sanitized `PostgresProfile` JSON. Empty for tombstones.
    let payloadJSON: String
    let name: String
    let environment: String
    let isReadOnly: Bool
    let color: String?
    /// `tunnel.sshConnectionId` — a *reference* to an SSH profile on the
    /// destination device; never SSH credentials or key material.
    let sshProfileRef: String?
    let updatedAt: Date
    /// Tombstone flag: the profile was deleted on some device. Tombstones
    /// are kept (not hard-deleted) so offline devices learn about the
    /// deletion; they're purged after `tombstoneRetention`.
    let deleted: Bool
    let deletedAt: Date?

    init(profile: PostgresProfile) throws {
        self.id = profile.id
        self.payloadJSON = try Self.sanitizedPayloadJSON(for: profile)
        self.name = profile.name
        self.environment = profile.environment.rawValue
        self.isReadOnly = profile.isReadOnly
        self.color = profile.color
        self.sshProfileRef = profile.tunnel?.sshConnectionId
        self.updatedAt = profile.updatedAt
        self.deleted = false
        self.deletedAt = nil
    }

    private init(
        id: String, payloadJSON: String, name: String, environment: String,
        isReadOnly: Bool, color: String?, sshProfileRef: String?,
        updatedAt: Date, deleted: Bool, deletedAt: Date?
    ) {
        self.id = id
        self.payloadJSON = payloadJSON
        self.name = name
        self.environment = environment
        self.isReadOnly = isReadOnly
        self.color = color
        self.sshProfileRef = sshProfileRef
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.deletedAt = deletedAt
    }

    /// A deletion marker for a profile. Carries no payload at all.
    static func tombstone(profileId: String, deletedAt: Date) -> SyncedProfileRecord {
        SyncedProfileRecord(
            id: profileId, payloadJSON: "", name: "", environment: "",
            isReadOnly: false, color: nil, sshProfileRef: nil,
            updatedAt: deletedAt, deleted: true, deletedAt: deletedAt
        )
    }

    /// Decode the carried profile. Nil for tombstones or corrupt payloads.
    func profile() -> PostgresProfile? {
        guard !deleted, let data = payloadJSON.data(using: .utf8) else { return nil }
        return try? Self.payloadDecoder.decode(PostgresProfile.self, from: data)
    }

    // MARK: - Secret-free payload

    /// Substrings that must never appear as a key in the synced payload.
    /// `PostgresAuthMethod` encodes only `{"kind":"keychain"}` by design;
    /// this scan is the belt to that suspender.
    static let bannedKeyFragments = ["password", "secret", "token", "passphrase", "credential"]

    static func sanitizedPayloadJSON(for profile: PostgresProfile) throws -> String {
        let data = try payloadEncoder.encode(profile)
        if let leak = firstSecretKeyPath(inJSONData: data) {
            throw UserDataSyncRecordError.secretMaterialDetected(leak)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Recursively scan a JSON object tree for secret-shaped keys holding
    /// secret-capable values. Returns the offending key path, or nil when
    /// clean. Booleans/numbers under a banned key are fine (`syncPassword`
    /// is a Bool opt-in flag, not a secret); a string, array, or object
    /// under a banned key trips the guard.
    static func firstSecretKeyPath(inJSONData data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return firstSecretKeyPath(in: root, path: "")
    }

    private static func firstSecretKeyPath(in value: Any, path: String) -> String? {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                let lowered = key.lowercased()
                if bannedKeyFragments.contains(where: { lowered.contains($0) }),
                   isSecretCapable(child) {
                    return childPath
                }
                if let hit = firstSecretKeyPath(in: child, path: childPath) { return hit }
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                if let hit = firstSecretKeyPath(in: child, path: "\(path)[\(index)]") { return hit }
            }
        }
        return nil
    }

    /// Whether a JSON value could carry secret material. Booleans and
    /// numbers cannot; strings and containers can.
    private static func isSecretCapable(_ value: Any) -> Bool {
        !(value is NSNumber || value is NSNull)
    }

    private static var payloadEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var payloadDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - CKRecord mapping

    private enum Field {
        static let payload = "payload"
        static let name = "name"
        static let environment = "environment"
        static let isReadOnly = "isReadOnly"
        static let color = "color"
        static let sshProfileRef = "sshProfileRef"
        static let updatedAt = "updatedAt"
        static let deleted = "deleted"
        static let deletedAt = "deletedAt"
    }

    func toRecord(zoneID: CKRecordZone.ID = UserDataCloudKit.zoneID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: UserDataCloudKit.profileRecordType, recordID: recordID)
        record[Field.payload] = payloadJSON
        record[Field.name] = name
        record[Field.environment] = environment
        record[Field.isReadOnly] = isReadOnly ? Int64(1) : Int64(0)
        record[Field.color] = color
        record[Field.sshProfileRef] = sshProfileRef
        record[Field.updatedAt] = updatedAt
        record[Field.deleted] = deleted ? Int64(1) : Int64(0)
        record[Field.deletedAt] = deletedAt
        return record
    }

    init?(record: CKRecord) {
        guard record.recordType == UserDataCloudKit.profileRecordType else { return nil }
        let deleted = ((record[Field.deleted] as? Int64) ?? 0) != 0
        let payload = (record[Field.payload] as? String) ?? ""
        // A live record without a payload is unusable; a tombstone needs none.
        guard deleted || !payload.isEmpty else { return nil }
        self.init(
            id: record.recordID.recordName,
            payloadJSON: payload,
            name: (record[Field.name] as? String) ?? "",
            environment: (record[Field.environment] as? String) ?? "",
            isReadOnly: ((record[Field.isReadOnly] as? Int64) ?? 0) != 0,
            color: record[Field.color] as? String,
            sshProfileRef: record[Field.sshProfileRef] as? String,
            updatedAt: (record[Field.updatedAt] as? Date) ?? record.modificationDate ?? Date(),
            deleted: deleted,
            deletedAt: record[Field.deletedAt] as? Date
        )
    }

    /// Whether this tombstone is past its retention window and should be
    /// purged from CloudKit.
    func isExpiredTombstone(now: Date = Date(), retention: TimeInterval = UserDataCloudKit.tombstoneRetention) -> Bool {
        guard deleted else { return false }
        return now.timeIntervalSince(deletedAt ?? updatedAt) > retention
    }
}

// =============================================================================
// SyncedSavedQuery — one saved-query bookmark
// =============================================================================

/// Record name == saved-query UUID string.
struct SyncedSavedQueryRecord: Equatable, Identifiable, Sendable {
    let id: String
    let profileId: String
    let title: String
    let sql: String
    let createdAt: Date
    let updatedAt: Date
    let deleted: Bool
    let deletedAt: Date?

    init(entry: PostgresSavedQuery) {
        self.id = entry.id.uuidString
        self.profileId = entry.profileId
        self.title = entry.name
        self.sql = entry.sql
        self.createdAt = entry.createdAt
        self.updatedAt = entry.updatedAt
        self.deleted = false
        self.deletedAt = nil
    }

    private init(
        id: String, profileId: String, title: String, sql: String,
        createdAt: Date, updatedAt: Date, deleted: Bool, deletedAt: Date?
    ) {
        self.id = id
        self.profileId = profileId
        self.title = title
        self.sql = sql
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.deletedAt = deletedAt
    }

    static func tombstone(queryId: String, profileId: String, deletedAt: Date) -> SyncedSavedQueryRecord {
        SyncedSavedQueryRecord(
            id: queryId, profileId: profileId, title: "", sql: "",
            createdAt: deletedAt, updatedAt: deletedAt, deleted: true, deletedAt: deletedAt
        )
    }

    /// Reconstruct the local model. Nil for tombstones or malformed ids.
    func savedQuery() -> PostgresSavedQuery? {
        guard !deleted, let uuid = UUID(uuidString: id) else { return nil }
        return PostgresSavedQuery(
            id: uuid, profileId: profileId, name: title, sql: sql,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }

    // MARK: - CKRecord mapping

    private enum Field {
        static let profileId = "profileId"
        static let title = "title"
        static let sql = "sql"
        static let createdAt = "createdAt"
        static let updatedAt = "updatedAt"
        static let deleted = "deleted"
        static let deletedAt = "deletedAt"
    }

    func toRecord(zoneID: CKRecordZone.ID = UserDataCloudKit.zoneID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = CKRecord(recordType: UserDataCloudKit.savedQueryRecordType, recordID: recordID)
        record[Field.profileId] = profileId
        record[Field.title] = title
        record[Field.sql] = sql
        record[Field.createdAt] = createdAt
        record[Field.updatedAt] = updatedAt
        record[Field.deleted] = deleted ? Int64(1) : Int64(0)
        record[Field.deletedAt] = deletedAt
        return record
    }

    init?(record: CKRecord) {
        guard record.recordType == UserDataCloudKit.savedQueryRecordType,
              let profileId = record[Field.profileId] as? String
        else { return nil }
        let updatedAt = (record[Field.updatedAt] as? Date) ?? record.modificationDate ?? Date()
        self.init(
            id: record.recordID.recordName,
            profileId: profileId,
            title: (record[Field.title] as? String) ?? "",
            sql: (record[Field.sql] as? String) ?? "",
            createdAt: (record[Field.createdAt] as? Date) ?? updatedAt,
            updatedAt: updatedAt,
            deleted: ((record[Field.deleted] as? Int64) ?? 0) != 0,
            deletedAt: record[Field.deletedAt] as? Date
        )
    }

    func isExpiredTombstone(now: Date = Date(), retention: TimeInterval = UserDataCloudKit.tombstoneRetention) -> Bool {
        guard deleted else { return false }
        return now.timeIntervalSince(deletedAt ?? updatedAt) > retention
    }
}
