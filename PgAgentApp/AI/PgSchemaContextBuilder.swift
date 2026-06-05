import Foundation
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PgSchemaContextBuilder — deterministically assembles a compact schema summary
// to inject into AI prompts.
//
// WHY (not tools): the on-device model has a 4,096-token window and, in
// testing, ran away in tool-call loops (re-calling describe_table dozens of
// times on hallucinated tables until the context overflowed). Fetching a
// bounded schema snapshot up front in Swift and putting it in the prompt is
// loop-proof, predictable against the token budget, and — as on-device testing
// confirmed — produces correct SQL in a single shot.
//
// No FoundationModels dependency — pure data shaping over the Postgres bridge.
// =============================================================================

enum PgSchemaContextBuilder {
    /// Build a compact, budget-bounded description of `schema`: each table as
    /// `name(col type, …)` for up to `maxDescribedTables` tables (columns
    /// fetched in parallel), then any remaining tables and views by name only.
    /// Best-effort — failures degrade to a shorter summary rather than throwing.
    static func build(
        connectionId: String,
        schema: String,
        maxDescribedTables: Int = 12,
        budgetChars: Int = 2_200
    ) async -> String {
        guard let contents = try? await BridgeManager.shared.pgListSchemaContents(
            connectionId: connectionId,
            schema: schema
        ) else {
            return "Schema '\(schema)': (schema details unavailable)"
        }

        let tableNames = contents.tables.map(\.name) + contents.materializedViews.map(\.name)
        let viewNames = contents.views.map(\.name)
        let described = Array(tableNames.prefix(maxDescribedTables))

        // Fetch columns for the described tables in parallel — each is one
        // round trip; the group bounds total latency to the slowest one.
        let columnsByTable = await withTaskGroup(
            of: (String, [FfiPgColumnDetail]).self
        ) { group -> [String: [FfiPgColumnDetail]] in
            for table in described {
                group.addTask {
                    let cols = (try? await BridgeManager.shared.pgDescribeColumns(
                        connectionId: connectionId,
                        schema: schema,
                        table: table
                    )) ?? []
                    return (table, cols)
                }
            }
            var map: [String: [FfiPgColumnDetail]] = [:]
            for await (table, cols) in group { map[table] = cols }
            return map
        }

        var lines = ["Schema '\(schema)':"]
        var used = lines[0].count
        var describedCount = 0

        for table in described {
            let cols = columnsByTable[table] ?? []
            let colStr = cols.map { "\($0.name) \($0.typeName)" }.joined(separator: ", ")
            let line = "- \(table)(\(colStr))"
            if used + line.count > budgetChars { break }
            lines.append(line)
            used += line.count
            describedCount += 1
        }

        let remaining = tableNames.count - describedCount
        if remaining > 0 {
            let names = tableNames.suffix(remaining).joined(separator: ", ")
            lines.append("Other tables: \(names)")
        }
        if !viewNames.isEmpty {
            lines.append("Views: \(viewNames.joined(separator: ", "))")
        }

        // Final hard clamp as a backstop against a very wide schema.
        return PgAIContext.clamp(lines.joined(separator: "\n"), maxChars: budgetChars + 600)
    }
}
