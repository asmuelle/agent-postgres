import CloudKit
import Foundation
import os
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// =============================================================================
// CloudSyncEngine — opt-in iCloud sync of connection profiles (sans secrets)
// and saved queries (roadmap 2.3). Private CloudKit database, custom zone
// "UserData" (separate from "FleetAlerts").
//
// Design points (mirrors FleetAlertRelay where it can):
// - Entitlement guard: CKContainer(identifier:) hard-crashes in a process
//   without the icloud-services entitlement — never construct one unless the
//   entitlement is really present (unsigned CI/dev builds surface
//   `.missingEntitlement` instead of crashing).
// - Incremental pulls via CKFetchRecordZoneChangesOperation with a persisted
//   server change token; a CKRecordZoneSubscription (silent push) makes
//   remote changes arrive without polling.
// - Push on local mutation, debounced; every push is preceded by a pull so
//   last-writer-wins is settled locally before records go up.
// - Transient network errors retry with capped exponential backoff.
//
// SAFETY RAILS:
// - Enabling sync NEVER deletes local data: until the first sync completes,
//   remote tombstones are ignored (initial merge = union, LWW on conflicts).
// - Disabling sync stops the engine and deletes nothing, anywhere.
// - "Remove my data from iCloud" deletes the UserData zone remotely and
//   leaves all local data intact.
// - Record-level hard deletions from the server (console edits, purged
//   tombstones) are deliberately NOT applied locally — deletions only
//   propagate through explicit tombstone records with timestamps.
// =============================================================================

enum CloudSyncStatus: Equatable, Sendable {
    case disabled
    case missingEntitlement
    case noAccount
    case restricted
    case temporarilyUnavailable
    case syncing
    case upToDate
    case error(String)

    var label: String {
        switch self {
        case .disabled: return "Sync is off"
        case .missingEntitlement: return "This build lacks CloudKit entitlements (unsigned dev build)"
        case .noAccount: return "No iCloud account — sign in to sync"
        case .restricted: return "iCloud access restricted"
        case .temporarilyUnavailable: return "iCloud temporarily unavailable"
        case .syncing: return "Syncing…"
        case .upToDate: return "Up to date"
        case .error(let message): return message
        }
    }

    var isHealthy: Bool {
        switch self {
        case .syncing, .upToDate: return true
        default: return false
        }
    }
}

@MainActor
final class CloudSyncEngine: ObservableObject {
    static let shared = CloudSyncEngine()

    @Published private(set) var status: CloudSyncStatus
    @Published private(set) var lastSyncAt: Date?

    private let log = Logger(subsystem: "com.pgagent", category: "CloudSyncEngine")
    private var lazyContainer: CKContainer?
    private var zoneReady = false
    private var subscriptionReady = false
    private var state: CloudSyncEngineState
    private var debounceTask: Task<Void, Never>?
    private var isSyncing = false
    private var needsAnotherPass = false
    /// Expired tombstone record IDs discovered during pull; deleted from the
    /// server on the next push (30-day retention purge).
    private var expiredTombstoneIDs: [CKRecord.ID] = []

    private static let debounceNanoseconds: UInt64 = 2_000_000_000
    private static let maxAttempts = 3
    private static let baseBackoffSeconds: Double = 2
    private static let maxBackoffSeconds: Double = 30
    /// CloudKit rejects batches over 400 records; stay comfortably below.
    private static let batchSize = 350

    private var settings: CloudSyncSettings { CloudSyncSettings.shared }

    private init() {
        state = Self.loadState()
        lastSyncAt = state.lastSyncAt
        status = CloudSyncSettings.shared.syncEnabled ? .upToDate : .disabled
        observeForeground()
    }

    // MARK: - Container / entitlement guard (same rationale as FleetAlertRelay)

    private var container: CKContainer? {
        if let lazyContainer { return lazyContainer }
        guard FleetAlertRelay.processHasCloudKitEntitlement else { return nil }
        let made = CKContainer(identifier: UserDataCloudKit.containerIdentifier)
        lazyContainer = made
        return made
    }

    // MARK: - Lifecycle entry points

    /// Called from both app delegates at launch: resume syncing if the user
    /// left it on last session.
    func startIfEnabled() {
        guard settings.syncEnabled else { return }
        scheduleDebouncedSync()
    }

    /// The master toggle changed. Enabling starts a sync; disabling stops
    /// the engine but deletes nothing (local or remote).
    func masterToggleChanged(enabled: Bool) {
        if enabled {
            status = .syncing
            Task { await self.runSync() }
        } else {
            debounceTask?.cancel()
            debounceTask = nil
            status = .disabled
        }
    }

    /// Explicit "Sync now" from the settings UI.
    func syncNow() async {
        debounceTask?.cancel()
        debounceTask = nil
        await runSync()
    }

    // MARK: - Local-mutation hooks (called by the stores)

    func noteProfilesChanged() {
        guard settings.syncEnabled, settings.syncConnections else { return }
        scheduleDebouncedSync()
    }

    func noteProfileDeleted(id: String) {
        guard settings.syncEnabled, settings.syncConnections else { return }
        state.pendingTombstones.append(
            PendingSyncTombstone(kind: .profile, recordName: id, profileId: nil, deletedAt: Date())
        )
        saveState()
        scheduleDebouncedSync()
    }

    func noteSavedQueriesChanged() {
        guard settings.syncEnabled, settings.syncSavedQueries else { return }
        scheduleDebouncedSync()
    }

    func noteSavedQueryDeleted(id: UUID, profileId: String) {
        guard settings.syncEnabled, settings.syncSavedQueries else { return }
        state.pendingTombstones.append(
            PendingSyncTombstone(
                kind: .savedQuery, recordName: id.uuidString,
                profileId: profileId, deletedAt: Date()
            )
        )
        saveState()
        scheduleDebouncedSync()
    }

    // MARK: - Remote push (silent CKRecordZoneSubscription notification)

    /// Whether an incoming remote notification belongs to the user-data sync
    /// subscription (as opposed to the FleetAlert relay).
    nonisolated static func isSyncPush(userInfo: [AnyHashable: Any]) -> Bool {
        guard let dictionary = userInfo as? [String: Any],
              let note = CKNotification(fromRemoteNotificationDictionary: dictionary)
        else { return false }
        return note.subscriptionID == UserDataCloudKit.subscriptionID
    }

    func handleRemotePush() async {
        guard settings.syncEnabled else { return }
        await runSync()
    }

    // MARK: - Remove-from-iCloud (safety rail #3)

    /// Delete the whole UserData zone from the user's private database.
    /// Local data everywhere stays untouched; sync is switched off.
    func removeCloudData() async {
        guard let container else {
            status = .missingEntitlement
            return
        }
        debounceTask?.cancel()
        status = .syncing
        do {
            _ = try await container.privateCloudDatabase.modifyRecordZones(
                saving: [], deleting: [UserDataCloudKit.zoneID]
            )
        } catch let error as CKError where error.code == .zoneNotFound {
            // Already gone — the desired end state.
        } catch {
            status = .error(shortMessage(for: error))
            log.error("Removing UserData zone failed: \(String(describing: error))")
            return
        }
        zoneReady = false
        subscriptionReady = false
        expiredTombstoneIDs = []
        state = CloudSyncEngineState()
        saveState()
        lastSyncAt = nil
        settings.syncEnabled = false
        status = .disabled
        log.info("UserData zone removed from iCloud; local data untouched")
    }

    // MARK: - Sync loop

    private func scheduleDebouncedSync() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.runSync()
        }
    }

    private func runSync() async {
        guard settings.syncEnabled else {
            status = .disabled
            return
        }
        if isSyncing {
            needsAnotherPass = true
            return
        }
        isSyncing = true
        defer {
            isSyncing = false
            if needsAnotherPass {
                needsAnotherPass = false
                scheduleDebouncedSync()
            }
        }

        guard let container else {
            status = .missingEntitlement
            return
        }
        do {
            switch try await container.accountStatus() {
            case .available: break
            case .noAccount: status = .noAccount; return
            case .restricted: status = .restricted; return
            case .temporarilyUnavailable: status = .temporarilyUnavailable; return
            case .couldNotDetermine: status = .temporarilyUnavailable; return
            @unknown default: status = .temporarilyUnavailable; return
            }
        } catch {
            status = .error(shortMessage(for: error))
            return
        }

        status = .syncing
        let database = container.privateCloudDatabase
        do {
            try await ensureZone(in: database)
            try await ensureSubscription(in: database)
            registerForRemotePushes()
            try await pullChanges(from: database)
            try await pushAll(to: database)
            state.hasCompletedInitialSync = true
            state.lastSyncAt = Date()
            saveState()
            lastSyncAt = state.lastSyncAt
            status = .upToDate
        } catch {
            status = .error(shortMessage(for: error))
            log.error("Sync failed: \(String(describing: error))")
        }
    }

    // MARK: - Pull

    private func pullChanges(from database: CKDatabase) async throws {
        var attempt = 0
        while true {
            do {
                let changes = try await fetchZoneChanges(database: database, since: changeToken)
                apply(records: changes.changed, deletedIDs: changes.deleted)
                if let token = changes.token {
                    changeToken = token
                    saveState()
                }
                return
            } catch let error as CKError where error.code == .changeTokenExpired {
                // Token too old — restart from scratch. A full fetch merges
                // as a union, so this is always safe.
                changeToken = nil
                saveState()
            } catch let error as CKError where error.code == .zoneNotFound {
                // Zone vanished (e.g. "remove my data" ran on another
                // device). Treat the cloud as empty; the following push
                // recreates the zone with this device's data.
                zoneReady = false
                changeToken = nil
                saveState()
                try await ensureZone(in: database)
                return
            } catch {
                attempt += 1
                guard attempt < Self.maxAttempts, let delay = retryDelay(for: error, attempt: attempt) else {
                    throw error
                }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private struct ZoneChanges {
        var changed: [CKRecord] = []
        var deleted: [CKRecord.ID] = []
        var token: CKServerChangeToken?
    }

    private func fetchZoneChanges(
        database: CKDatabase,
        since token: CKServerChangeToken?
    ) async throws -> ZoneChanges {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            configuration.previousServerChangeToken = token
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [UserDataCloudKit.zoneID],
                configurationsByRecordZoneID: [UserDataCloudKit.zoneID: configuration]
            )
            operation.fetchAllChanges = true

            var changes = ZoneChanges()
            var zoneError: Error?

            operation.recordWasChangedBlock = { _, result in
                if case .success(let record) = result {
                    changes.changed.append(record)
                }
            }
            operation.recordWithIDWasDeletedBlock = { recordID, _ in
                changes.deleted.append(recordID)
            }
            operation.recordZoneChangeTokensUpdatedBlock = { _, newToken, _ in
                changes.token = newToken ?? changes.token
            }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let (serverToken, _, _)):
                    changes.token = serverToken
                case .failure(let error):
                    zoneError = error
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    if let zoneError {
                        continuation.resume(throwing: zoneError)
                    } else {
                        continuation.resume(returning: changes)
                    }
                case .failure(let error):
                    continuation.resume(throwing: zoneError ?? error)
                }
            }
            database.add(operation)
        }
    }

    /// Merge pulled records into the local stores (LWW). Also collects
    /// expired tombstones for server-side purge.
    private func apply(records: [CKRecord], deletedIDs: [CKRecord.ID]) {
        // Record-level hard deletions are intentionally ignored for local
        // state (see file header) — they only occur for purged tombstones,
        // whose local models are long gone.
        _ = deletedIDs

        guard !records.isEmpty else { return }
        let honorDeletes = state.hasCompletedInitialSync

        var profileRecords: [SyncedProfileRecord] = []
        var queryRecords: [SyncedSavedQueryRecord] = []
        let now = Date()
        for record in records {
            if let profileRecord = SyncedProfileRecord(record: record) {
                if profileRecord.isExpiredTombstone(now: now) {
                    expiredTombstoneIDs.append(record.recordID)
                } else {
                    profileRecords.append(profileRecord)
                }
            } else if let queryRecord = SyncedSavedQueryRecord(record: record) {
                if queryRecord.isExpiredTombstone(now: now) {
                    expiredTombstoneIDs.append(record.recordID)
                } else {
                    queryRecords.append(queryRecord)
                }
            }
        }

        if settings.syncConnections, !profileRecords.isEmpty {
            let merge = UserDataSyncMerge.mergeProfiles(
                local: PostgresProfileStore.shared.profiles,
                remote: profileRecords,
                honorDeletes: honorDeletes
            )
            PostgresProfileStore.shared.applyRemoteMerge(
                upserts: merge.upserts, deleteIds: merge.deleteIds
            )
        }

        if settings.syncSavedQueries, !queryRecords.isEmpty {
            var upserts: [PostgresSavedQuery] = []
            var deletes: [UserDataSavedQueryMerge.SavedQueryDeletion] = []
            for (profileId, group) in Dictionary(grouping: queryRecords, by: \.profileId) {
                let merge = UserDataSyncMerge.mergeSavedQueries(
                    local: PostgresSavedQueriesStore.shared.entries(forProfile: profileId),
                    remote: group,
                    honorDeletes: honorDeletes
                )
                upserts.append(contentsOf: merge.upserts)
                deletes.append(contentsOf: merge.deletes)
            }
            PostgresSavedQueriesStore.shared.applyRemoteMerge(upserts: upserts, deletes: deletes)
        }
    }

    // MARK: - Push

    /// Push the full local dataset (profiles + saved queries are small —
    /// tens to a few hundred records) plus pending tombstones, and purge
    /// expired remote tombstones. Pull always runs first, so LWW is already
    /// settled locally and `.allKeys` simply makes the server match.
    private func pushAll(to database: CKDatabase) async throws {
        var records: [CKRecord] = []

        if settings.syncConnections {
            for profile in PostgresProfileStore.shared.profiles {
                do {
                    records.append(try SyncedProfileRecord(profile: profile).toRecord())
                } catch {
                    // Secret-material guard tripped — never upload; loud log.
                    log.fault("Profile \(profile.id, privacy: .public) NOT synced: \(String(describing: error))")
                }
            }
        }
        if settings.syncSavedQueries {
            for entry in PostgresSavedQueriesStore.shared.allEntriesAcrossProfiles() {
                records.append(SyncedSavedQueryRecord(entry: entry).toRecord())
            }
        }

        state.purgeExpiredPendingTombstones()
        for tombstone in state.pendingTombstones {
            switch tombstone.kind {
            case .profile:
                records.append(
                    SyncedProfileRecord
                        .tombstone(profileId: tombstone.recordName, deletedAt: tombstone.deletedAt)
                        .toRecord()
                )
            case .savedQuery:
                records.append(
                    SyncedSavedQueryRecord
                        .tombstone(
                            queryId: tombstone.recordName,
                            profileId: tombstone.profileId ?? "",
                            deletedAt: tombstone.deletedAt
                        )
                        .toRecord()
                )
            }
        }

        let deletions = expiredTombstoneIDs
        guard !records.isEmpty || !deletions.isEmpty else { return }

        var pendingRecords = records
        var pendingDeletions = deletions
        while !pendingRecords.isEmpty || !pendingDeletions.isEmpty {
            let saveBatch = Array(pendingRecords.prefix(Self.batchSize))
            pendingRecords.removeFirst(saveBatch.count)
            let deleteBatch = Array(pendingDeletions.prefix(Self.batchSize))
            pendingDeletions.removeFirst(deleteBatch.count)
            try await modifyWithRetry(database, saving: saveBatch, deleting: deleteBatch)
        }

        state.pendingTombstones.removeAll()
        expiredTombstoneIDs = []
        saveState()
    }

    private func modifyWithRetry(
        _ database: CKDatabase,
        saving records: [CKRecord],
        deleting recordIDs: [CKRecord.ID]
    ) async throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let result = try await database.modifyRecords(
                    saving: records,
                    deleting: recordIDs,
                    savePolicy: .allKeys,
                    atomically: false
                )
                for (recordID, outcome) in result.saveResults {
                    if case .failure(let error) = outcome {
                        log.error("Record \(recordID.recordName, privacy: .public) failed to sync: \(String(describing: error))")
                    }
                }
                return
            } catch {
                guard attempt < Self.maxAttempts, let delay = retryDelay(for: error, attempt: attempt) else {
                    throw error
                }
                log.info("Sync push attempt \(attempt) failed; retrying in \(delay, format: .fixed(precision: 1))s")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    // MARK: - Zone + subscription

    private func ensureZone(in database: CKDatabase) async throws {
        if zoneReady { return }
        _ = try await database.save(CKRecordZone(zoneID: UserDataCloudKit.zoneID))
        zoneReady = true
    }

    private func ensureSubscription(in database: CKDatabase) async throws {
        if subscriptionReady { return }
        let subscription = CKRecordZoneSubscription(
            zoneID: UserDataCloudKit.zoneID,
            subscriptionID: UserDataCloudKit.subscriptionID
        )
        let info = CKSubscription.NotificationInfo()
        // Silent content-available push: wakes the app to pull; no banner.
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
        subscriptionReady = true
    }

    private func registerForRemotePushes() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    private func observeForeground() {
        #if os(iOS)
        let name = UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        let name = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in
                guard CloudSyncSettings.shared.syncEnabled else { return }
                CloudSyncEngine.shared.scheduleDebouncedSync()
            }
        }
    }

    // MARK: - Change token + state persistence

    private var changeToken: CKServerChangeToken? {
        get {
            guard let data = state.changeTokenData else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        set {
            state.changeTokenData = newValue.flatMap {
                try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
            }
        }
    }

    private static var stateFileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("com.mc-ssh")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cloud-sync-state.json")
    }

    private static func loadState() -> CloudSyncEngineState {
        guard let data = try? Data(contentsOf: stateFileURL) else { return CloudSyncEngineState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(CloudSyncEngineState.self, from: data)) ?? CloudSyncEngineState()
    }

    private func saveState() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: Self.stateFileURL, options: .atomic)
        } catch {
            log.error("Failed to persist sync state: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Error helpers (same policy as FleetAlertRelay)

    private func retryDelay(for error: Error, attempt: Int) -> Double? {
        guard let ck = error as? CKError else { return nil }
        switch ck.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            let suggested = ck.retryAfterSeconds ?? Self.baseBackoffSeconds * pow(2, Double(attempt - 1))
            return min(suggested, Self.maxBackoffSeconds)
        default:
            return nil
        }
    }

    private func shortMessage(for error: Error) -> String {
        (error as? CKError)?.localizedDescription ?? error.localizedDescription
    }
}
