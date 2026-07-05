import Foundation
import OSLog

// =============================================================================
// PostgresColumnWidthStore — remembers user-resized column widths so a
// query rerun (or re-opening the same table) restores layout.
//
// Keyed only on `(profileId, schema, table, columnName)` for now —
// generic SQL tabs don't have a stable identifier we can pin widths
// to, so they reset on rerun. Editable tabs (the common case for
// repeated work on the same table) carry editTarget which feeds
// directly into the key.
//
// Persistence: a single JSON file at
// `Application Support/com.mc-ssh/postgres-column-widths.json`.
// One file is fine because the working set is small (one width-float
// per column-per-table the user has resized).
// =============================================================================

@MainActor
final class PostgresColumnWidthStore: ObservableObject {
    static let shared = PostgresColumnWidthStore()
    private let logger = Logger(subsystem: "com.mc-ssh", category: "postgres-column-widths")

    /// Composite key kept stringy for JSON-friendliness. The
    /// canonical separator is `\u{1F}` (unit separator) so a name
    /// containing `/` or `:` can't collide.
    private static func key(
        profileId: String, schema: String, table: String, columnName: String
    ) -> String {
        let sep = "\u{1F}"
        return "\(profileId)\(sep)\(schema)\(sep)\(table)\(sep)\(columnName)"
    }

    private var widths: [String: Double] = [:]
    private var loaded: Bool = false

    private init() {}

    func width(
        forProfile profileId: String,
        schema: String,
        table: String,
        column: String
    ) -> Double? {
        loadIfNeeded()
        return widths[Self.key(profileId: profileId, schema: schema, table: table, columnName: column)]
    }

    func setWidth(
        _ width: Double,
        forProfile profileId: String,
        schema: String,
        table: String,
        column: String
    ) {
        loadIfNeeded()
        let k = Self.key(profileId: profileId, schema: schema, table: table, columnName: column)
        // Only persist meaningful changes — round-trips through
        // float widths can produce micro-deltas that aren't worth
        // a disk write.
        if let existing = widths[k], abs(existing - width) < 0.5 {
            return
        }
        widths[k] = width
        persist()
    }

    // MARK: - Disk

    private static var fileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = appSupport.appendingPathComponent("com.mc-ssh")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("postgres-column-widths.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            widths = try JSONDecoder().decode([String: Double].self, from: data)
        } catch {
            logger.error("column-widths load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        let url = Self.fileURL
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(widths)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("column-widths persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
