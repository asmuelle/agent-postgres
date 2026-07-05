import Foundation

// =============================================================================
// UserDataSyncMerge — pure last-writer-wins merge decisions for the iCloud
// user-data sync (roadmap 2.3), plus the engine's persisted state.
//
// No CloudKit types beyond what the record structs carry — everything here is
// deterministic and unit-testable (see CloudSyncEngineTests).
//
// Merge semantics:
// - LWW by `updatedAt`: a remote record replaces the local model only when
//   strictly newer. Ties keep local (our own pushes echo back with equal
//   timestamps).
// - Remote records with no local counterpart are inserted (union).
// - Tombstones (deleted flag) remove the local model only when
//   `honorDeletes` is true AND the tombstone is at least as new as the local
//   copy. The engine passes `honorDeletes = false` for the very first sync
//   after enabling, so enabling sync can never delete local data — the
//   initial merge is a pure union.
// =============================================================================

struct UserDataProfileMerge: Equatable {
    var upserts: [PostgresProfile] = []
    var deleteIds: [String] = []
}

struct UserDataSavedQueryMerge: Equatable {
    var upserts: [PostgresSavedQuery] = []
    /// (profileId, entryId) pairs so the per-profile store file can be found.
    var deletes: [SavedQueryDeletion] = []

    struct SavedQueryDeletion: Equatable {
        let profileId: String
        let entryId: UUID
    }
}

enum UserDataSyncMerge {
    static func mergeProfiles(
        local: [PostgresProfile],
        remote: [SyncedProfileRecord],
        honorDeletes: Bool
    ) -> UserDataProfileMerge {
        let localById = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        var result = UserDataProfileMerge()

        for record in remote {
            if record.deleted {
                guard honorDeletes, let existing = localById[record.id] else { continue }
                let deletedAt = record.deletedAt ?? record.updatedAt
                if deletedAt >= existing.updatedAt {
                    result.deleteIds.append(record.id)
                }
                continue
            }
            guard let remoteProfile = record.profile() else { continue }
            if let existing = localById[record.id] {
                if record.updatedAt > existing.updatedAt {
                    result.upserts.append(remoteProfile)
                }
            } else {
                result.upserts.append(remoteProfile)
            }
        }
        return result
    }

    static func mergeSavedQueries(
        local: [PostgresSavedQuery],
        remote: [SyncedSavedQueryRecord],
        honorDeletes: Bool
    ) -> UserDataSavedQueryMerge {
        let localById = Dictionary(uniqueKeysWithValues: local.map { ($0.id.uuidString, $0) })
        var result = UserDataSavedQueryMerge()

        for record in remote {
            if record.deleted {
                guard honorDeletes,
                      let existing = localById[record.id],
                      let uuid = UUID(uuidString: record.id)
                else { continue }
                let deletedAt = record.deletedAt ?? record.updatedAt
                if deletedAt >= existing.updatedAt {
                    result.deletes.append(.init(profileId: record.profileId, entryId: uuid))
                }
                continue
            }
            guard let remoteEntry = record.savedQuery() else { continue }
            if let existing = localById[record.id] {
                if record.updatedAt > existing.updatedAt {
                    result.upserts.append(remoteEntry)
                }
            } else {
                result.upserts.append(remoteEntry)
            }
        }
        return result
    }
}

// =============================================================================
// Persisted engine state
// =============================================================================

/// A local deletion that still has to reach CloudKit as a tombstone record.
struct PendingSyncTombstone: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case profile
        case savedQuery
    }

    var kind: Kind
    /// The CloudKit record name (profile id / saved-query UUID string).
    var recordName: String
    /// Saved queries only: the owning profile, so the receiving side can
    /// find the right per-profile store file.
    var profileId: String?
    var deletedAt: Date
}

/// Durable engine state: the incremental-fetch server change token, the
/// pending local tombstones, and the first-sync marker. Persisted as JSON in
/// Application Support next to the profile store. All fields decode
/// leniently so older state files keep working as fields are added.
struct CloudSyncEngineState: Codable, Equatable, Sendable {
    /// `CKServerChangeToken` archived via NSKeyedArchiver (the token itself
    /// isn't Codable). Nil forces a full zone fetch, which the merge treats
    /// as a plain union — always safe.
    var changeTokenData: Data?
    /// False until the first successful pull+push after enabling. While
    /// false, remote tombstones are NOT applied locally (union-only merge).
    var hasCompletedInitialSync: Bool
    var pendingTombstones: [PendingSyncTombstone]
    var lastSyncAt: Date?

    init(
        changeTokenData: Data? = nil,
        hasCompletedInitialSync: Bool = false,
        pendingTombstones: [PendingSyncTombstone] = [],
        lastSyncAt: Date? = nil
    ) {
        self.changeTokenData = changeTokenData
        self.hasCompletedInitialSync = hasCompletedInitialSync
        self.pendingTombstones = pendingTombstones
        self.lastSyncAt = lastSyncAt
    }

    private enum CodingKeys: String, CodingKey {
        case changeTokenData, hasCompletedInitialSync, pendingTombstones, lastSyncAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        changeTokenData = try c.decodeIfPresent(Data.self, forKey: .changeTokenData)
        hasCompletedInitialSync = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedInitialSync) ?? false
        pendingTombstones = try c.decodeIfPresent([PendingSyncTombstone].self, forKey: .pendingTombstones) ?? []
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
    }

    /// Drop pending tombstones past the retention window — if they haven't
    /// been pushed in 30 days (sync disabled the whole time), the remote
    /// side no longer needs them and re-announcing an ancient deletion
    /// could clobber a re-created profile.
    mutating func purgeExpiredPendingTombstones(
        now: Date = Date(),
        retention: TimeInterval = UserDataCloudKit.tombstoneRetention
    ) {
        pendingTombstones.removeAll { now.timeIntervalSince($0.deletedAt) > retention }
    }
}
