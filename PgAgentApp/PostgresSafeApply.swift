import Foundation
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresSafeApply — pure plan-building for the Safe-Apply review (Slice 5).
// UI/FFI-free so it's unit-testable. The view orchestrates the transaction
// (BEGIN → statements → ROLLBACK for a dry-run, or COMMIT for real).
//
// Two paths:
//   - In place: just the CREATE OR REPLACE the user edited. CREATE OR REPLACE
//     preserves dependents, so it's the safe default.
//   - DROP + CREATE: forced when the edit changes the return type or a
//     parameter name (CREATE OR REPLACE then errors, SQLSTATE 42P13). This
//     DROPs the routine — CASCADE takes its dependents with it — so it's gated
//     behind the blast-radius preview and an explicit, destructive Commit.
//     search_path SET clauses survive automatically (pg_get_functiondef emits
//     them in the CREATE); only GRANTs are lost on DROP, so they're captured
//     from the live ACL and re-applied after the recreate.
// =============================================================================

enum PostgresSafeApply {

    static func qualified(_ schema: String, _ name: String) -> String {
        "\(pgQuoteIdent(schema)).\(pgQuoteIdent(name))"
    }

    /// `FUNCTION` / `PROCEDURE` for DROP (must match the routine kind);
    /// GRANT/REVOKE use `ROUTINE`, which covers both.
    static func dropKeyword(isProcedure: Bool) -> String {
        isProcedure ? "PROCEDURE" : "FUNCTION"
    }

    // MARK: - Plans

    /// The in-place plan: the edited CREATE OR REPLACE, verbatim.
    static func inPlacePlan(createText: String) -> [String] {
        [createText]
    }

    /// The forced DROP + CREATE plan: drop (CASCADE) the routine, recreate it
    /// from the edited text (which carries any SET search_path), then restore
    /// grants. `grants` should already include a leading REVOKE when the live
    /// ACL was non-default (see `grantStatements`).
    static func dropCreatePlan(
        schema: String, name: String, signature: String, isProcedure: Bool,
        createText: String, grants: [String]
    ) -> [String] {
        var plan = [
            "DROP \(dropKeyword(isProcedure: isProcedure)) "
                + "\(qualified(schema, name))(\(signature)) CASCADE;",
            createText,
        ]
        plan.append(contentsOf: grants)
        return plan
    }

    // MARK: - ACL capture

    /// Query returning the live explicit ACL as rows: privilege_type,
    /// grantee_label ('PUBLIC' or the role name), is_grantable (text bool).
    /// Empty result ⇒ default ACL ⇒ nothing to restore.
    static func aclQuery(schema: String, name: String, signature: String) -> String {
        """
        SELECT a.privilege_type,
               CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE r.rolname END,
               a.is_grantable::text
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        CROSS JOIN LATERAL aclexplode(p.proacl) a
        LEFT JOIN pg_roles r ON r.oid = a.grantee
        WHERE n.nspname = \(pgQuoteLiteral(schema))
          AND p.proname = \(pgQuoteLiteral(name))
          AND pg_get_function_identity_arguments(p.oid) = \(pgQuoteLiteral(signature))
        ORDER BY 2, 1;
        """
    }

    /// Build the GRANT statements that restore the captured ACL after a
    /// recreate. When the ACL is non-default (any rows), a leading
    /// `REVOKE ALL … FROM PUBLIC` resets the recreate's default PUBLIC EXECUTE
    /// so the restored ACL is exact (e.g. a previously-revoked PUBLIC stays
    /// revoked). Empty input ⇒ no statements (default ACL is already correct).
    static func grantStatements(
        schema: String, name: String, signature: String, isProcedure: Bool,
        aclRows: [[String?]]
    ) -> [String] {
        let target = "\(qualified(schema, name))(\(signature))"
        var rows: [(priv: String, grantee: String, grantable: Bool)] = []
        for row in aclRows {
            guard row.count >= 2, let priv = row[0], let grantee = row[1], !grantee.isEmpty
            else { continue }
            rows.append((priv, grantee, (row.count > 2 ? row[2] : nil) == "true"))
        }
        guard !rows.isEmpty else { return [] }
        var out = ["REVOKE ALL ON ROUTINE \(target) FROM PUBLIC;"]
        for r in rows {
            let grantee = r.grantee == "PUBLIC" ? "PUBLIC" : pgQuoteIdent(r.grantee)
            out.append(
                "GRANT \(r.priv) ON ROUTINE \(target) TO \(grantee)"
                    + (r.grantable ? " WITH GRANT OPTION;" : ";"))
        }
        return out
    }

    // MARK: - Probe / classification

    /// The DROP (no CASCADE) used to surface the dependency blast radius — it
    /// fails with a DETAIL enumerating dependents, which Postgres computes
    /// exactly.
    static func dropProbe(schema: String, name: String, signature: String, isProcedure: Bool) -> String {
        "DROP \(dropKeyword(isProcedure: isProcedure)) "
            + "\(qualified(schema, name))(\(signature));"
    }

    /// True when a failed in-place CREATE OR REPLACE means the edit needs a
    /// DROP + CREATE (changed return type or a parameter name). Postgres
    /// reports SQLSTATE 42P13 (invalid_function_definition) for both.
    static func requiresDropCreate(sqlstate: String?, message: String?) -> Bool {
        if sqlstate == "42P13" { return true }
        let m = (message ?? "").lowercased()
        return m.contains("cannot change return type")
            || m.contains("cannot change name of input parameter")
    }
}
