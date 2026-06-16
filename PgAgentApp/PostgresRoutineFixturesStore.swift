import Foundation
import OSLog

// =============================================================================
// PostgresRoutineFixturesStore — named, persisted parameter sets for the
// routine runner. Run a function once, save the inputs as a "fixture", and
// replay them after editing the body — a lightweight regression check.
//
// Mirrors PostgresSavedQueriesStore's persistence:
// `Application Support/com.mc-ssh/postgres-routine-fixtures/<profile-id>.json`.
// A single per-profile file holds fixtures for every routine; reads filter by
// `routineKey` ("schema.name(identity-args)").
// =============================================================================

/// One saved input value, keyed in the fixture by parameter label (name, or
/// `$n` for an unnamed argument).
struct PostgresFixtureValue: Codable, Hashable, Sendable {
    var text: String
    var isNull: Bool
    var useDefault: Bool

    init(text: String = "", isNull: Bool = false, useDefault: Bool = false) {
        self.text = text
        self.isNull = isNull
        self.useDefault = useDefault
    }
}

struct PostgresRoutineFixture: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let profileId: String
    /// "schema.name(identity-args)" — scopes the fixture to one overload.
    let routineKey: String
    var name: String
    /// Values keyed by parameter label.
    var values: [String: PostgresFixtureValue]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        profileId: String,
        routineKey: String,
        name: String,
        values: [String: PostgresFixtureValue],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.profileId = profileId
        self.routineKey = routineKey
        self.name = name
        self.values = values
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@MainActor
final class PostgresRoutineFixturesStore: ObservableObject {
    static let shared = PostgresRoutineFixturesStore()
    private let logger = Logger(subsystem: "com.mc-ssh", category: "postgres-routine-fixtures")

    /// All fixtures by profile id (every routine), newest-updated first.
    @Published private(set) var entriesByProfile: [String: [PostgresRoutineFixture]] = [:]

    private init() {}

    /// Stable key for a routine overload.
    static func routineKey(schema: String, name: String, signature: String) -> String {
        "\(schema).\(name)(\(signature))"
    }

    // MARK: - Reads

    private func allEntries(forProfile profileId: String) -> [PostgresRoutineFixture] {
        if let cached = entriesByProfile[profileId] { return cached }
        let loaded = loadFromDisk(profileId: profileId)
        entriesByProfile[profileId] = loaded
        return loaded
    }

    /// Fixtures for one routine overload, newest-updated first.
    func fixtures(forProfile profileId: String, routineKey: String) -> [PostgresRoutineFixture] {
        allEntries(forProfile: profileId).filter { $0.routineKey == routineKey }
    }

    // MARK: - Mutations

    /// Save (or overwrite by name) a fixture for a routine. Re-saving an
    /// existing name updates it in place rather than stacking duplicates.
    @discardableResult
    func save(
        profileId: String,
        routineKey: String,
        name: String,
        values: [String: PostgresFixtureValue]
    ) -> PostgresRoutineFixture {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Untitled" : trimmed
        var current = allEntries(forProfile: profileId)
        if let idx = current.firstIndex(where: {
            $0.routineKey == routineKey && $0.name == finalName
        }) {
            var updated = current[idx]
            updated.values = values
            updated.updatedAt = Date()
            current[idx] = updated
            current.sort { $0.updatedAt > $1.updatedAt }
            entriesByProfile[profileId] = current
            persist(profileId: profileId, entries: current)
            return updated
        }
        let entry = PostgresRoutineFixture(
            profileId: profileId, routineKey: routineKey, name: finalName, values: values
        )
        current.insert(entry, at: 0)
        entriesByProfile[profileId] = current
        persist(profileId: profileId, entries: current)
        return entry
    }

    func remove(id: UUID, fromProfile profileId: String) {
        var current = allEntries(forProfile: profileId)
        current.removeAll { $0.id == id }
        entriesByProfile[profileId] = current
        persist(profileId: profileId, entries: current)
    }

    func purge(profileId: String) {
        entriesByProfile.removeValue(forKey: profileId)
        try? FileManager.default.removeItem(at: Self.fileURL(forProfile: profileId))
    }

    // MARK: - Disk

    private static func directoryURL() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("com.mc-ssh")
            .appendingPathComponent("postgres-routine-fixtures")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(forProfile profileId: String) -> URL {
        let sanitized = profileId.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return directoryURL().appendingPathComponent("\(sanitized).json")
    }

    private func loadFromDisk(profileId: String) -> [PostgresRoutineFixture] {
        let url = Self.fileURL(forProfile: profileId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let entries = try decoder.decode([PostgresRoutineFixture].self, from: Data(contentsOf: url))
            return entries.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            logger.error("fixtures load failed for \(profileId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func persist(profileId: String, entries: [PostgresRoutineFixture]) {
        let url = Self.fileURL(forProfile: profileId)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: url, options: .atomic)
        } catch {
            logger.error("fixtures persist failed for \(profileId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
