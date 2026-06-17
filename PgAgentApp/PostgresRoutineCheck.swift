import Foundation
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresRoutineCheck — inline plpgsql_check integration (Slice 4). Pure /
// FFI-free so it's unit-testable.
//
// plpgsql_check (okbob, PG14–18) runs the plpgsql parser/evaluator over a
// function and reports the large class of bugs CREATE FUNCTION silently
// accepts — wrong column/field references, type mismatches in embedded SQL,
// unused variables, dead code. It needs only `CREATE EXTENSION plpgsql_check`
// (no shared_preload_libraries for the check functions), so it works on most
// managed Postgres where pldebugger does not — our debugger substitute.
//
//   - `probeQuery` reports whether the extension exists + the routine's language.
//   - `checkQuery` runs `plpgsql_check_function_tb(oid)` for the exact overload.
//   - `parseFindings` turns the rows into `[RoutineCheckFinding]`.
//   - `bodyLineToCharOffset` maps a finding's body line number onto a character
//     offset in the editor's full CREATE text, so clicking a finding jumps to
//     the offending line. plpgsql_check counts lines 1-based from prosrc (the
//     dollar-quoted body), so editorLine = openerDelimiterLine + lineno - 1.
// =============================================================================

struct RoutineCheckProbe: Equatable, Sendable {
    let hasExtension: Bool
    let language: String
    var isPlpgsql: Bool { language == "plpgsql" }
}

struct RoutineCheckFinding: Equatable, Sendable, Identifiable {
    enum Level: Sendable { case error, warning, performance, other }
    let level: Level
    /// Body line number (1-based, relative to the function body) reported by
    /// plpgsql_check, or nil when it didn't attribute one.
    let lineno: Int?
    let message: String
    let detail: String?
    let hint: String?
    let sqlstate: String?
    /// Stable enough for SwiftUI within one check pass (line + message).
    var id: String { "\(lineno ?? -1):\(message)" }
}

enum PostgresRoutineCheck {

    // MARK: - Queries

    /// has_extension (text bool), language. Always one row.
    static func probeQuery(schema: String, name: String, signature: String) -> String {
        """
        SELECT
          EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'plpgsql_check')::text,
          (SELECT l.lanname
             FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             LEFT JOIN pg_language l ON l.oid = p.prolang
            WHERE n.nspname = \(pgQuoteLiteral(schema))
              AND p.proname = \(pgQuoteLiteral(name))
              AND pg_get_function_identity_arguments(p.oid) = \(pgQuoteLiteral(signature))
            LIMIT 1);
        """
    }

    /// Findings for the exact overload. Columns: 0 level, 1 lineno, 2 message,
    /// 3 detail, 4 hint, 5 sqlstate.
    static func checkQuery(schema: String, name: String, signature: String) -> String {
        """
        SELECT cf.level, cf.lineno::text, cf.message, cf.detail, cf.hint, cf.sqlstate
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        CROSS JOIN LATERAL plpgsql_check_function_tb(p.oid) cf
        WHERE n.nspname = \(pgQuoteLiteral(schema))
          AND p.proname = \(pgQuoteLiteral(name))
          AND pg_get_function_identity_arguments(p.oid) = \(pgQuoteLiteral(signature))
        ORDER BY cf.lineno NULLS LAST
        LIMIT 200;
        """
    }

    // MARK: - Parsing

    static func parseProbe(row: [String?]?) -> RoutineCheckProbe? {
        guard let row else { return nil }
        func c(_ i: Int) -> String? { i < row.count ? row[i] : nil }
        return RoutineCheckProbe(hasExtension: c(0) == "true", language: c(1) ?? "")
    }

    static func parseFindings(rows: [[String?]]) -> [RoutineCheckFinding] {
        rows.compactMap { row in
            func c(_ i: Int) -> String? {
                guard i < row.count, let v = row[i], !v.isEmpty else { return nil }
                return v
            }
            guard let message = c(2) else { return nil }
            return RoutineCheckFinding(
                level: level(from: c(0)),
                lineno: c(1).flatMap { Int($0) },
                message: message,
                detail: c(3),
                hint: c(4),
                sqlstate: c(5)
            )
        }
    }

    private static func level(from raw: String?) -> RoutineCheckFinding.Level {
        let l = (raw ?? "").lowercased()
        if l.contains("error") { return .error }
        if l.contains("performance") { return .performance }
        if l.contains("warning") { return .warning }
        return .other
    }

    // MARK: - Line mapping

    /// Character offset (0-based, in Characters — matching the editor's
    /// `errorCharOffset`) of the first non-whitespace character on the editor
    /// line that corresponds to plpgsql_check body line `bodyLine`. Returns nil
    /// when out of range.
    static func bodyLineToCharOffset(editorText: String, bodyLine: Int) -> Int? {
        guard bodyLine >= 1 else { return nil }
        // The body (prosrc) starts at the opening dollar-quote delimiter; its
        // line 1 is whatever follows that `$tag$` on the same line. So map
        // prosrc line N → opener line + N - 1.
        let openerLine = dollarQuoteOpenerLine(in: editorText) ?? 1
        let targetLine = openerLine + bodyLine - 1
        return charOffset(ofLine: targetLine, in: editorText)
    }

    /// 1-based line number of the first `$tag$` / `$$` delimiter, or nil.
    static func dollarQuoteOpenerLine(in text: String) -> Int? {
        guard let range = text.range(of: "\\$[A-Za-z_0-9]*\\$", options: .regularExpression) else {
            return nil
        }
        let prefix = text[text.startIndex..<range.lowerBound]
        return 1 + prefix.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
    }

    /// 0-based Character offset of the first non-whitespace character on the
    /// 1-based `line`, or nil when the line is out of range.
    static func charOffset(ofLine line: Int, in text: String) -> Int? {
        guard line >= 1 else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard line <= lines.count else { return nil }
        var offset = 0
        for i in 0..<(line - 1) {
            offset += lines[i].count + 1 // + newline
        }
        let target = lines[line - 1]
        let lead = target.prefix(while: { $0 == " " || $0 == "\t" }).count
        return offset + lead
    }
}
