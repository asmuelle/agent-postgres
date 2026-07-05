import Foundation
import OSLog

// =============================================================================
// PostgresSnippetsStore — the snippet library: reusable SQL fragments with
// TextMate-style placeholders (see PostgresSnippetPlaceholders).
//
// Distinct from `PostgresSavedQueriesStore` (per-profile bookmarks of
// complete queries): snippets are global — a `SELECT … WHERE …` skeleton is
// useful on every connection — and their bodies carry `${n:default}`
// placeholders the editor turns into a tab-through session on insert.
//
// Persistence mirrors the saved-queries idiom, one JSON file:
// `Application Support/com.mc-ssh/postgres-snippets.json`.
// Starter snippets are seeded on first run (file absent); deleting them
// sticks because the file then exists.
// =============================================================================

struct PostgresSnippet: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    /// Snippet body with optional `${n:default}` / `$0` placeholders.
    var body: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@MainActor
final class PostgresSnippetsStore: ObservableObject {
    static let shared = PostgresSnippetsStore()
    private let logger = Logger(subsystem: "com.mc-ssh", category: "postgres-snippets")

    /// All snippets, sorted newest-updated first. Loaded (or seeded) on
    /// first access.
    @Published private(set) var snippets: [PostgresSnippet] = []

    private var loaded = false

    private init() {}

    // MARK: - Reads

    /// Load-once accessor — views call this instead of touching
    /// `snippets` before the store has hydrated from disk.
    func all() -> [PostgresSnippet] {
        loadIfNeeded()
        return snippets
    }

    // MARK: - Mutations

    @discardableResult
    func add(title: String, body: String) -> PostgresSnippet {
        loadIfNeeded()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = PostgresSnippet(
            title: trimmedTitle.isEmpty ? "Untitled" : trimmedTitle,
            body: body
        )
        snippets.insert(snippet, at: 0)
        persist()
        return snippet
    }

    func update(_ snippet: PostgresSnippet) {
        loadIfNeeded()
        guard let idx = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        var updated = snippet
        updated.updatedAt = Date()
        snippets[idx] = updated
        snippets.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    func remove(id: UUID) {
        loadIfNeeded()
        snippets.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Starter snippets

    /// Seeded on first run only. Bodies use `${n:default}` tab stops with
    /// `$0` as the final caret.
    static let starterSnippets: [PostgresSnippet] = [
        PostgresSnippet(
            title: "SELECT … WHERE",
            body: """
            SELECT ${1:*}
            FROM ${2:table}
            WHERE ${3:condition}
            ORDER BY ${4:1}
            LIMIT ${5:100};$0
            """
        ),
        PostgresSnippet(
            title: "INSERT … RETURNING",
            body: """
            INSERT INTO ${1:table} (${2:column_a, column_b})
            VALUES (${3:value_a, value_b})
            RETURNING *;$0
            """
        ),
        PostgresSnippet(
            title: "UPDATE … WHERE",
            body: """
            UPDATE ${1:table}
            SET ${2:column} = ${3:value}
            WHERE ${4:condition}
            RETURNING *;$0
            """
        ),
        PostgresSnippet(
            title: "CREATE INDEX CONCURRENTLY",
            body: """
            CREATE INDEX CONCURRENTLY IF NOT EXISTS ${1:idx_name}
            ON ${2:table} (${3:column});$0
            """
        ),
        PostgresSnippet(
            title: "EXPLAIN ANALYZE",
            body: """
            EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
            ${1:SELECT 1};$0
            """
        ),
    ]

    // MARK: - Disk

    private static func fileURL() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = appSupport.appendingPathComponent("com.mc-ssh")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("postgres-snippets.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let url = Self.fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            // First run: seed the starters and write the file so later
            // deletions/edits stick.
            snippets = Self.starterSnippets
            persist()
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snippets = try decoder.decode([PostgresSnippet].self, from: data)
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            logger.error("snippets load failed: \(error.localizedDescription, privacy: .public)")
            snippets = []
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snippets)
            try data.write(to: Self.fileURL(), options: .atomic)
        } catch {
            logger.error("snippets persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
