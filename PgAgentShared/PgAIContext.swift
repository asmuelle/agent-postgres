import Foundation
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PgAIContext — pure helpers for packing database context into a prompt that
// fits the on-device model's ~4,096-token window (instructions + prompt +
// tool output + generated output all share it).
//
// No FoundationModels dependency — just string/result shaping, so it's
// unit-testable without the model being available.
// =============================================================================

enum PgAIContext {
    /// Rough chars-per-token for budgeting. The on-device tokenizer isn't
    /// exposed, so we use a conservative 4 chars/token and clamp generously.
    static let charsPerToken = 4

    /// Clamp a free-text fragment to `maxChars`, appending an elision marker
    /// so the model knows content was cut rather than malformed.
    static func clamp(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let head = text.prefix(maxChars)
        return "\(head)\n… [truncated, \(text.count - maxChars) more characters]"
    }

    /// A compact, model-friendly rendering of a result set: a header line of
    /// column names, then up to `maxRows` rows with each cell truncated to
    /// `maxCellChars`. NULLs render as `NULL`. Hidden `__pg_` columns are
    /// dropped. Designed for grounding "explain these results" and tool output.
    static func summarize(
        _ result: FfiPgExecutionResult,
        maxRows: Int = 20,
        maxCellChars: Int = 80
    ) -> String {
        let visibleIndexes = result.columns.indices.filter {
            !result.columns[$0].name.hasPrefix("__pg_")
        }

        if visibleIndexes.isEmpty {
            return result.rowsAffected.map { "\($0) row(s) affected." }
                ?? "Statement completed with no result rows."
        }

        let header = visibleIndexes
            .map { "\(result.columns[$0].name) (\(result.columns[$0].typeName))" }
            .joined(separator: " | ")

        let shown = result.rows.prefix(maxRows)
        let rowLines = shown.map { row -> String in
            visibleIndexes.map { idx -> String in
                let cell = idx < row.cells.count ? row.cells[idx] : nil
                guard let value = cell else { return "NULL" }
                return clampCell(value, maxChars: maxCellChars)
            }
            .joined(separator: " | ")
        }

        var out = header + "\n" + rowLines.joined(separator: "\n")
        if result.rows.count > maxRows {
            out += "\n… [\(result.rows.count - maxRows) more rows not shown]"
        }
        return out
    }

    private static func clampCell(_ value: String, maxChars: Int) -> String {
        let oneLine = value.replacingOccurrences(of: "\n", with: " ")
        guard oneLine.count > maxChars else { return oneLine }
        return oneLine.prefix(maxChars) + "…"
    }

    /// Strip a wrapping ```sql … ``` markdown fence, if present. The model is
    /// told not to add fences, but defends against it anyway so generated SQL
    /// is never inserted with stray backticks.
    static func stripSQLFences(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
