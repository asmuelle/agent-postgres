import Foundation
import OSLog

// =============================================================================
// PostgresSavedQueriesStore — per-profile bookmarks of SQL the user
// wants to keep around.
//
// Distinct from `PostgresHistoryStore`:
//   - History is automatic, capped, and time-ordered.
//   - Saved queries are explicit (named, kept indefinitely) and ordered
//     by most-recently-edited.
//
// Persistence mirrors history:
// `Application Support/com.mc-ssh/postgres-saved/<profile-id>.json`.
//
// Duplicate names are allowed — the user might keep "list locks" and
// "list locks (verbose)" separately. The popover surfaces newest first
// so the latest edit wins visually.
// =============================================================================

struct PostgresSavedQuery: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let profileId: String
    var name: String
    var sql: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        profileId: String,
        name: String,
        sql: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.profileId = profileId
        self.name = name
        self.sql = sql
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@MainActor
final class PostgresSavedQueriesStore: ObservableObject {
    static let shared = PostgresSavedQueriesStore()
    private let logger = Logger(subsystem: "com.mc-ssh", category: "postgres-saved")

    /// Cached entries by profile id, sorted newest-updated first.
    /// Loaded lazily on first read per profile.
    @Published private(set) var entriesByProfile: [String: [PostgresSavedQuery]] = [:]

    private init() {}

    // MARK: - Reads

    func entries(forProfile profileId: String) -> [PostgresSavedQuery] {
        if let cached = entriesByProfile[profileId] {
            return cached
        }
        let loaded = loadFromDisk(profileId: profileId)
        entriesByProfile[profileId] = loaded
        return loaded
    }

    // MARK: - Mutations

    /// Save a new bookmark with the supplied name and SQL. Returns
    /// the created entry.
    @discardableResult
    func add(profileId: String, name: String, sql: String) -> PostgresSavedQuery {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSql = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = PostgresSavedQuery(
            profileId: profileId,
            name: trimmedName.isEmpty ? "Untitled" : trimmedName,
            sql: trimmedSql
        )
        var current = entries(forProfile: profileId)
        current.insert(entry, at: 0)
        entriesByProfile[profileId] = current
        persist(profileId: profileId, entries: current)
        return entry
    }

    func update(_ entry: PostgresSavedQuery) {
        var current = entries(forProfile: entry.profileId)
        guard let idx = current.firstIndex(where: { $0.id == entry.id }) else { return }
        var updated = entry
        updated.updatedAt = Date()
        current[idx] = updated
        // Bring the just-edited entry to the top.
        current.sort { $0.updatedAt > $1.updatedAt }
        entriesByProfile[entry.profileId] = current
        persist(profileId: entry.profileId, entries: current)
    }

    func remove(entryId: UUID, fromProfile profileId: String) {
        var current = entries(forProfile: profileId)
        current.removeAll { $0.id == entryId }
        entriesByProfile[profileId] = current
        persist(profileId: profileId, entries: current)
    }

    /// Profile-delete hook — wipes the on-disk file alongside other
    /// per-profile state so a recreated profile with the same id
    /// (unlikely, since ids are UUIDs, but defensive) doesn't inherit
    /// the previous user's bookmarks.
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
            .appendingPathComponent("postgres-saved")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(forProfile profileId: String) -> URL {
        // Defensive sanitization mirrors the history store — profile
        // ids are UUIDs in practice, but a future change to free-text
        // ids shouldn't accidentally escape the directory.
        let sanitized = profileId.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return directoryURL().appendingPathComponent("\(sanitized).json")
    }

    private func loadFromDisk(profileId: String) -> [PostgresSavedQuery] {
        let url = Self.fileURL(forProfile: profileId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let entries = try decoder.decode([PostgresSavedQuery].self, from: data)
            return entries.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            logger.error("saved-queries load failed for \(profileId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func persist(profileId: String, entries: [PostgresSavedQuery]) {
        let url = Self.fileURL(forProfile: profileId)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("saved-queries persist failed for \(profileId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
