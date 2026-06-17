import Foundation
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresRoutineAttributes — pure introspection + ALTER building + a security
// lens for routine attributes (Slice 3). UI/FFI-free so it's unit-testable.
//
//   - `introspectionQuery` reads the exact overload's attributes from pg_proc.
//   - `parse` turns the row into a `RoutineAttributes`.
//   - `alterStatement(from:to:…)` emits a minimal ALTER FUNCTION/PROCEDURE with
//     only the changed clauses (or nil when nothing changed). Procedures only
//     accept SECURITY and SET/RESET — other clauses are gated out.
//   - `securityFindings` flags the deterministic, high-confidence risks:
//       * SECURITY DEFINER without a pinned search_path  → CRITICAL (+ fix)
//       * untrusted-language routine                     → WARNING
//       * EXECUTE granted to PUBLIC                       → INFO / WARNING (+ fix)
// =============================================================================

enum RoutineVolatility: String, CaseIterable, Sendable {
    case volatile, stable, immutable
    init(pgChar: String) {
        switch pgChar {
        case "i": self = .immutable
        case "s": self = .stable
        default: self = .volatile
        }
    }
    var keyword: String { rawValue.uppercased() }
    var label: String { rawValue.capitalized }
}

enum RoutineParallel: String, CaseIterable, Sendable {
    case unsafe, restricted, safe
    init(pgChar: String) {
        switch pgChar {
        case "s": self = .safe
        case "r": self = .restricted
        default: self = .unsafe
        }
    }
    var keyword: String { "PARALLEL \(rawValue.uppercased())" }
    var label: String { rawValue.capitalized }
}

struct RoutineAttributes: Equatable, Sendable {
    var isProcedure: Bool = false
    var language: String = ""
    var languageTrusted: Bool = true
    var returns: String? = nil
    var arguments: String = ""
    var returnsSet: Bool = false
    var volatility: RoutineVolatility = .volatile
    var parallel: RoutineParallel = .unsafe
    var securityDefiner: Bool = false
    var strict: Bool = false
    var leakproof: Bool = false
    var cost: Double = 100
    var rows: Double = 1000
    /// The `search_path` value (text after `search_path=` in proconfig), or nil
    /// when not pinned.
    var searchPath: String? = nil
    /// Other proconfig `SET` items, preserved verbatim (not edited here).
    var otherConfig: [String] = []
    var publicExecute: Bool = false
}

struct RoutineSecurityFinding: Equatable, Sendable, Identifiable {
    enum Severity: Sendable { case critical, warning, info }
    let severity: Severity
    let title: String
    let detail: String
    /// A statement that remediates the finding, runnable with one click. `nil`
    /// for advisory-only findings.
    let fixSQL: String?
    var id: String { title }
}

enum PostgresRoutineAttributes {

    // MARK: - Introspection

    /// Columns: 0 prokind, 1 lanname, 2 lanpltrusted, 3 provolatile,
    /// 4 proparallel, 5 prosecdef, 6 proisstrict, 7 proleakproof, 8 procost,
    /// 9 prorows, 10 proretset, 11 result, 12 arguments, 13 config, 14 public_exec.
    static func introspectionQuery(schema: String, name: String, signature: String) -> String {
        """
        SELECT p.prokind::text,
               l.lanname,
               COALESCE(l.lanpltrusted, true)::text,
               p.provolatile::text,
               p.proparallel::text,
               p.prosecdef::text,
               p.proisstrict::text,
               p.proleakproof::text,
               p.procost::text,
               p.prorows::text,
               p.proretset::text,
               pg_get_function_result(p.oid),
               pg_get_function_arguments(p.oid),
               array_to_string(p.proconfig, E'\\n'),
               (p.proacl IS NULL OR EXISTS (
                  SELECT 1 FROM aclexplode(p.proacl) a
                  WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'))::text
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        LEFT JOIN pg_language l ON l.oid = p.prolang
        WHERE n.nspname = \(pgQuoteLiteral(schema))
          AND p.proname = \(pgQuoteLiteral(name))
          AND pg_get_function_identity_arguments(p.oid) = \(pgQuoteLiteral(signature))
        LIMIT 1;
        """
    }

    static func parse(row: [String?]) -> RoutineAttributes? {
        guard !row.isEmpty else { return nil }
        func c(_ i: Int) -> String? { i < row.count ? row[i] : nil }
        guard let prokind = c(0) else { return nil }

        var configLines = (c(13) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        var searchPath: String?
        let prefix = "search_path="
        if let idx = configLines.firstIndex(where: { $0.hasPrefix(prefix) }) {
            searchPath = String(configLines[idx].dropFirst(prefix.count))
            configLines.remove(at: idx)
        }

        return RoutineAttributes(
            isProcedure: prokind == "p",
            language: c(1) ?? "",
            languageTrusted: c(2) == "true",
            returns: (c(11)?.isEmpty == false) ? c(11) : nil,
            arguments: c(12) ?? "",
            returnsSet: c(10) == "true",
            volatility: RoutineVolatility(pgChar: c(3) ?? "v"),
            parallel: RoutineParallel(pgChar: c(4) ?? "u"),
            securityDefiner: c(5) == "true",
            strict: c(6) == "true",
            leakproof: c(7) == "true",
            cost: Double(c(8) ?? "") ?? 100,
            rows: Double(c(9) ?? "") ?? 0,
            searchPath: searchPath,
            otherConfig: configLines,
            publicExecute: c(14) == "true"
        )
    }

    // MARK: - ALTER building

    /// Minimal ALTER for the changed attributes, or nil when nothing changed.
    /// Procedures accept only SECURITY and SET/RESET search_path; other clauses
    /// are skipped for them (Postgres rejects them on ALTER PROCEDURE).
    static func alterStatement(
        schema: String, name: String, signature: String,
        from original: RoutineAttributes, to edited: RoutineAttributes
    ) -> String? {
        var clauses: [String] = []
        let isProc = edited.isProcedure

        if edited.securityDefiner != original.securityDefiner {
            clauses.append(edited.securityDefiner ? "SECURITY DEFINER" : "SECURITY INVOKER")
        }
        if !isProc {
            if edited.volatility != original.volatility {
                clauses.append(edited.volatility.keyword)
            }
            if edited.parallel != original.parallel {
                clauses.append(edited.parallel.keyword)
            }
            if edited.strict != original.strict {
                clauses.append(edited.strict ? "STRICT" : "CALLED ON NULL INPUT")
            }
            if edited.leakproof != original.leakproof {
                clauses.append(edited.leakproof ? "LEAKPROOF" : "NOT LEAKPROOF")
            }
            if edited.cost != original.cost, edited.cost > 0 {
                clauses.append("COST \(formatReal(edited.cost))")
            }
            if edited.returnsSet, edited.rows != original.rows, edited.rows > 0 {
                clauses.append("ROWS \(formatReal(edited.rows))")
            }
        }
        // search_path SET/RESET — applies to functions and procedures alike.
        let oldPath = normalizedPath(original.searchPath)
        let newPath = normalizedPath(edited.searchPath)
        if oldPath != newPath {
            if let newPath {
                clauses.append("SET search_path = \(newPath)")
            } else {
                clauses.append("RESET search_path")
            }
        }

        guard !clauses.isEmpty else { return nil }
        return "\(alterPrefix(schema: schema, name: name, signature: signature, isProcedure: isProc)) "
            + clauses.joined(separator: " ") + ";"
    }

    /// Trim whitespace; treat empty as "not set" (→ RESET).
    private static func normalizedPath(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func alterPrefix(
        schema: String, name: String, signature: String, isProcedure: Bool
    ) -> String {
        let kind = isProcedure ? "ALTER PROCEDURE" : "ALTER FUNCTION"
        return "\(kind) \(pgQuoteIdent(schema)).\(pgQuoteIdent(name))(\(signature))"
    }

    /// `100` not `100.0`; keeps a fractional value when present.
    static func formatReal(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: - Security lens

    static func securityFindings(
        _ attrs: RoutineAttributes, schema: String, name: String, signature: String
    ) -> [RoutineSecurityFinding] {
        var findings: [RoutineSecurityFinding] = []
        let prefix = alterPrefix(
            schema: schema, name: name, signature: signature, isProcedure: attrs.isProcedure)
        let pathPinned = normalizedPath(attrs.searchPath) != nil

        if attrs.securityDefiner && !pathPinned {
            findings.append(RoutineSecurityFinding(
                severity: .critical,
                title: "SECURITY DEFINER without a pinned search_path",
                detail: "This routine runs with the owner's privileges but resolves "
                    + "unqualified names against the caller's search_path — the classic "
                    + "privilege-escalation vector. Pin search_path explicitly.",
                fixSQL: "\(prefix) SET search_path = \(pgQuoteIdent(schema)), pg_temp;"
            ))
        }

        if !attrs.languageTrusted
            && attrs.language != "internal" && attrs.language != "c"
            && !attrs.language.isEmpty {
            findings.append(RoutineSecurityFinding(
                severity: .warning,
                title: "Untrusted language (\(attrs.language))",
                detail: "Functions in an untrusted language run with full host access "
                    + "(filesystem, network) as the database server's OS user.",
                fixSQL: nil
            ))
        }

        if attrs.publicExecute {
            let kindWord = attrs.isProcedure ? "PROCEDURE" : "FUNCTION"
            findings.append(RoutineSecurityFinding(
                // Definer + PUBLIC means anyone can run it as the owner — worse.
                severity: attrs.securityDefiner ? .warning : .info,
                title: "EXECUTE granted to PUBLIC",
                detail: attrs.securityDefiner
                    ? "Any role can execute this SECURITY DEFINER routine as its owner. "
                        + "Revoke from PUBLIC and grant only to the roles that need it."
                    : "Any role can execute this routine (the default grant). Revoke from "
                        + "PUBLIC if it should be restricted.",
                fixSQL: "REVOKE EXECUTE ON \(kindWord) "
                    + "\(pgQuoteIdent(schema)).\(pgQuoteIdent(name))(\(signature)) FROM PUBLIC;"
            ))
        }

        return findings
    }
}
