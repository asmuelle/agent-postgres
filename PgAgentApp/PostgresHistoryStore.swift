import Foundation
import OSLog

// =============================================================================
// PostgresHistoryStore — per-profile rolling SQL history.
//
// Persisted to `Application Support/com.mc-ssh/postgres-history/<profile>.json`.
// One file per profile keeps deletes clean (drop a profile → drop its
// history file) and avoids unbounded growth in shared state.
//
// Each successful `pgExecute` records an entry. Consecutive duplicates
// (same SQL as the last entry on the same profile) are coalesced into
// one — running the same query three times in a row produces one
// history entry, not three. Older identical queries with intervening
// other SQL are kept distinct.
//
// Cap: `MAX_ENTRIES_PER_PROFILE = 100`. Older entries are dropped from
// the tail when adding pushes past the cap.
// =============================================================================

private let MAX_ENTRIES_PER_PROFILE = 100

struct PostgresHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let profileId: String
    let sql: String
    let executedAt: Date
    /// Round-trip duration in milliseconds, when known.
    let durationMs: UInt32?
    /// Number of rows the first page returned, when the statement was
    /// row-returning. `nil` for DDL/DML without RETURNING.
    let rowsReturned: Int?

    init(
        id: UUID = UUID(),
        profileId: String,
        sql: String,
        executedAt: Date = Date(),
        durationMs: UInt32? = nil,
        rowsReturned: Int? = nil
    ) {
        self.id = id
        self.profileId = profileId
        self.sql = sql
        self.executedAt = executedAt
        self.durationMs = durationMs
        self.rowsReturned = rowsReturned
    }
}

@MainActor
final class PostgresHistoryStore: ObservableObject {
    static let shared = PostgresHistoryStore()
    private let logger = Logger(subsystem: "com.mc-ssh", category: "postgres-history")

    /// Cached entries keyed by profile id, newest first. Loaded
    /// lazily on first access per profile so cold-start cost scales
    /// with profiles actually opened, not total profiles.
    @Published private(set) var entriesByProfile: [String: [PostgresHistoryEntry]] = [:]

    private init() {}

    // MARK: - Public API

    /// Recent entries for a profile, newest first. Loads from disk
    /// on first call per profile.
    func entries(forProfile profileId: String) -> [PostgresHistoryEntry] {
        if let cached = entriesByProfile[profileId] {
            return cached
        }
        let loaded = loadFromDisk(profileId: profileId)
        entriesByProfile[profileId] = loaded
        return loaded
    }

    /// Record a new entry. Coalesces consecutive duplicates by SQL
    /// text and bumps the timestamp on the existing entry instead of
    /// appending a new one.
    func record(
        profileId: String,
        sql: String,
        durationMs: UInt32?,
        rowsReturned: Int?
    ) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var current = entries(forProfile: profileId)

        // Dedupe: if the most recent entry has identical SQL, just
        // refresh its timestamp + stats instead of appending. Common
        // when iterating on a query.
        if let first = current.first, first.sql == trimmed {
            let refreshed = PostgresHistoryEntry(
                id: first.id,
                profileId: profileId,
                sql: trimmed,
                executedAt: Date(),
                durationMs: durationMs,
                rowsReturned: rowsReturned
            )
            current[0] = refreshed
        } else {
            current.insert(
                PostgresHistoryEntry(
                    profileId: profileId,
                    sql: trimmed,
                    durationMs: durationMs,
                    rowsReturned: rowsReturned
                ),
                at: 0
            )
            if current.count > MAX_ENTRIES_PER_PROFILE {
                current.removeLast(current.count - MAX_ENTRIES_PER_PROFILE)
            }
        }

        entriesByProfile[profileId] = current
        persist(profileId: profileId, entries: current)
    }

    func remove(entryId: UUID, fromProfile profileId: String) {
        var current = entries(forProfile: profileId)
        current.removeAll { $0.id == entryId }
        entriesByProfile[profileId] = current
        persist(profileId: profileId, entries: current)
    }

    func clear(profileId: String) {
        entriesByProfile[profileId] = []
        persist(profileId: profileId, entries: [])
    }

    /// Search across all profiles' history. Loads any not-yet-loaded
    /// profile files lazily — a one-time disk hit per profile, the
    /// price of cross-profile recall.
    ///
    /// `needle` is matched case-insensitively against SQL text. The
    /// result is flattened, newest-first across all profiles.
    func searchAcrossProfiles(needle: String) -> [PostgresHistoryEntry] {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        // Walk every cached profile + every profile file we haven't
        // touched yet. We don't index — the working set is small
        // (a few profiles × ≤100 entries each).
        primeAllProfiles()
        var hits: [PostgresHistoryEntry] = []
        for entries in entriesByProfile.values {
            for entry in entries {
                if entry.sql.lowercased().contains(trimmed) {
                    hits.append(entry)
                }
            }
        }
        hits.sort { $0.executedAt > $1.executedAt }
        return hits
    }

    /// Lazy-load any history files for profiles not already in the
    /// cache. Used by cross-profile search; safe to call repeatedly.
    private func primeAllProfiles() {
        let dir = Self.directoryURL()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        for url in urls where url.pathExtension == "json" {
            let profileId = url.deletingPathExtension().lastPathComponent
            if entriesByProfile[profileId] == nil {
                entriesByProfile[profileId] = loadFromDisk(profileId: profileId)
            }
        }
    }

    /// Hook used by `PostgresProfileStore.delete` so dropping a
    /// profile also wipes its history file. Doesn't read disk.
    func purge(profileId: String) {
        entriesByProfile.removeValue(forKey: profileId)
        let url = Self.fileURL(forProfile: profileId)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Disk

    private static func directoryURL() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = appSupport
            .appendingPathComponent("com.mc-ssh")
            .appendingPathComponent("postgres-history")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(forProfile profileId: String) -> URL {
        // Profile ids are UUIDs, so they're safe filename components.
        // Defensive sanitize anyway in case a future change uses
        // free-text ids — we don't want a profile id to escape the
        // directory.
        let sanitized = profileId.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return directoryURL().appendingPathComponent("\(sanitized).json")
    }

    private func loadFromDisk(profileId: String) -> [PostgresHistoryEntry] {
        let url = Self.fileURL(forProfile: profileId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let entries = try decoder.decode([PostgresHistoryEntry].self, from: data)
            return entries
        } catch {
            logger.error("history load failed for \(profileId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func persist(profileId: String, entries: [PostgresHistoryEntry]) {
        let url = Self.fileURL(forProfile: profileId)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("history persist failed for \(profileId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
