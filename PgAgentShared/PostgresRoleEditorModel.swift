import Foundation

// =============================================================================
// PostgresRoleEditorModel — value model + pure SQL builders for the pgAdmin-
// style role property editor (both platforms): role attributes ("privileges"
// in pgAdmin terms: LOGIN, SUPERUSER, CREATEDB, …), connection limit, expiry,
// comment, and role memberships with ADMIN OPTION.
//
// Everything here is pure (no FFI, no model) so the ALTER/GRANT diff logic is
// exhaustively unit-testable. Loading and execution live in
// PostgresRoleEditorStore.
// =============================================================================

/// One `member of` edge: this role is a member of `role`.
struct PostgresRoleMembership: Equatable, Hashable, Identifiable {
    let role: String
    var adminOption: Bool

    var id: String { role }
}

/// Editable snapshot of a role. `validUntil` is the raw text form
/// (empty = no expiry / infinity); `connectionLimit` of -1 = unlimited.
struct PostgresRoleAttributes: Equatable {
    var name: String
    var canLogin: Bool
    var superuser: Bool
    var createDB: Bool
    var createRole: Bool
    var replication: Bool
    var bypassRLS: Bool
    var inherit: Bool
    var connectionLimit: Int32
    var validUntil: String
    var comment: String
    var memberships: [PostgresRoleMembership]
}

enum PostgresRoleDDL {
    // MARK: - Queries

    /// One row: the role's flags, limit, expiry, and comment.
    /// Column layout: 0 rolcanlogin · 1 rolsuper · 2 rolcreatedb ·
    /// 3 rolcreaterole · 4 rolreplication · 5 rolbypassrls · 6 rolinherit ·
    /// 7 rolconnlimit · 8 rolvaliduntil · 9 comment
    static func attributesQuery(name: String) -> String {
        """
        SELECT r.rolcanlogin::text, r.rolsuper::text, r.rolcreatedb::text,
               r.rolcreaterole::text, r.rolreplication::text, r.rolbypassrls::text,
               r.rolinherit::text, r.rolconnlimit::text, r.rolvaliduntil::text,
               shobj_description(r.oid, 'pg_authid')
        FROM pg_roles r
        WHERE r.rolname = \(pgQuoteLiteral(name));
        """
    }

    /// Roles this role is a member of, one row per parent:
    /// 0 parent rolname · 1 admin_option
    static func membershipsQuery(name: String) -> String {
        """
        SELECT g.rolname, m.admin_option::text
        FROM pg_auth_members m
        JOIN pg_roles g ON g.oid = m.roleid
        JOIN pg_roles r ON r.oid = m.member
        WHERE r.rolname = \(pgQuoteLiteral(name))
        ORDER BY g.rolname;
        """
    }

    /// Every role name, for the membership picker.
    static let allRolesQuery = "SELECT rolname FROM pg_roles ORDER BY rolname;"

    // MARK: - Row parsing (plain cells, FFI-free)

    /// Build attributes from the two query results above. Returns `nil` when
    /// the role row is missing (role dropped since the tree loaded).
    static func parse(
        name: String,
        attributeRow: [String?]?,
        membershipRows: [[String?]]
    ) -> PostgresRoleAttributes? {
        guard let row = attributeRow else { return nil }
        func flag(_ idx: Int) -> Bool { idx < row.count && row[idx] == "true" }
        let rawValidUntil = (8 < row.count ? row[8] : nil) ?? ""
        return PostgresRoleAttributes(
            name: name,
            canLogin: flag(0),
            superuser: flag(1),
            createDB: flag(2),
            createRole: flag(3),
            replication: flag(4),
            bypassRLS: flag(5),
            inherit: flag(6),
            connectionLimit: (7 < row.count ? row[7] : nil).flatMap { Int32($0) } ?? -1,
            validUntil: rawValidUntil == "infinity" ? "" : rawValidUntil,
            comment: (9 < row.count ? row[9] : nil) ?? "",
            memberships: membershipRows.compactMap { mRow in
                guard let parent = mRow.first ?? nil else { return nil }
                return PostgresRoleMembership(
                    role: parent,
                    adminOption: mRow.count > 1 && mRow[1] == "true"
                )
            }
        )
    }

    // MARK: - DDL diff (pure)

    /// Statements that turn `original` into `edited`, in a safe order:
    /// attribute ALTER first, then membership GRANT/REVOKEs, then COMMENT,
    /// and RENAME last so every earlier statement targets the original name.
    static func alterStatements(
        from original: PostgresRoleAttributes,
        to edited: PostgresRoleAttributes
    ) -> [String] {
        let role = pgQuoteIdent(original.name)
        var statements: [String] = []

        // Flag / limit / expiry changes fold into one ALTER ROLE … WITH.
        var options: [String] = []
        func flagDiff(_ old: Bool, _ new: Bool, _ keyword: String) {
            guard old != new else { return }
            options.append(new ? keyword : "NO\(keyword)")
        }
        flagDiff(original.canLogin, edited.canLogin, "LOGIN")
        flagDiff(original.superuser, edited.superuser, "SUPERUSER")
        flagDiff(original.createDB, edited.createDB, "CREATEDB")
        flagDiff(original.createRole, edited.createRole, "CREATEROLE")
        flagDiff(original.replication, edited.replication, "REPLICATION")
        flagDiff(original.bypassRLS, edited.bypassRLS, "BYPASSRLS")
        flagDiff(original.inherit, edited.inherit, "INHERIT")
        if original.connectionLimit != edited.connectionLimit {
            options.append("CONNECTION LIMIT \(edited.connectionLimit)")
        }
        let trimmedValidUntil = edited.validUntil.trimmingCharacters(in: .whitespaces)
        if original.validUntil != trimmedValidUntil {
            options.append("VALID UNTIL \(pgQuoteLiteral(trimmedValidUntil.isEmpty ? "infinity" : trimmedValidUntil))")
        }
        if !options.isEmpty {
            statements.append("ALTER ROLE \(role) WITH \(options.joined(separator: " "));")
        }

        // Membership diffs. Upgrading to ADMIN OPTION is a re-GRANT; dropping
        // just the option is REVOKE ADMIN OPTION FOR.
        let originalByRole = Dictionary(
            uniqueKeysWithValues: original.memberships.map { ($0.role, $0) }
        )
        let editedByRole = Dictionary(
            uniqueKeysWithValues: edited.memberships.map { ($0.role, $0) }
        )
        for membership in edited.memberships {
            let parent = pgQuoteIdent(membership.role)
            if let existing = originalByRole[membership.role] {
                if !existing.adminOption && membership.adminOption {
                    statements.append("GRANT \(parent) TO \(role) WITH ADMIN OPTION;")
                } else if existing.adminOption && !membership.adminOption {
                    statements.append("REVOKE ADMIN OPTION FOR \(parent) FROM \(role);")
                }
            } else {
                let admin = membership.adminOption ? " WITH ADMIN OPTION" : ""
                statements.append("GRANT \(parent) TO \(role)\(admin);")
            }
        }
        for membership in original.memberships where editedByRole[membership.role] == nil {
            statements.append("REVOKE \(pgQuoteIdent(membership.role)) FROM \(role);")
        }

        if original.comment != edited.comment {
            let value = edited.comment.isEmpty ? "NULL" : pgQuoteLiteral(edited.comment)
            statements.append("COMMENT ON ROLE \(role) IS \(value);")
        }

        // Rename last: everything above referenced the original name.
        let trimmedName = edited.name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty, trimmedName != original.name {
            statements.append("ALTER ROLE \(role) RENAME TO \(pgQuoteIdent(trimmedName));")
        }

        return statements
    }

    // MARK: - CREATE reconstruction (DDL tab)

    /// A faithful-enough `CREATE ROLE` script for the DDL source tab.
    static func createStatement(_ attrs: PostgresRoleAttributes) -> String {
        var options: [String] = []
        options.append(attrs.canLogin ? "LOGIN" : "NOLOGIN")
        if attrs.superuser { options.append("SUPERUSER") }
        if attrs.createDB { options.append("CREATEDB") }
        if attrs.createRole { options.append("CREATEROLE") }
        if attrs.replication { options.append("REPLICATION") }
        if attrs.bypassRLS { options.append("BYPASSRLS") }
        options.append(attrs.inherit ? "INHERIT" : "NOINHERIT")
        if attrs.connectionLimit >= 0 { options.append("CONNECTION LIMIT \(attrs.connectionLimit)") }
        if !attrs.validUntil.isEmpty { options.append("VALID UNTIL \(pgQuoteLiteral(attrs.validUntil))") }

        var sql = "CREATE ROLE \(pgQuoteIdent(attrs.name)) WITH\n    \(options.joined(separator: "\n    "));"
        for membership in attrs.memberships {
            let admin = membership.adminOption ? " WITH ADMIN OPTION" : ""
            sql += "\nGRANT \(pgQuoteIdent(membership.role)) TO \(pgQuoteIdent(attrs.name))\(admin);"
        }
        if !attrs.comment.isEmpty {
            sql += "\nCOMMENT ON ROLE \(pgQuoteIdent(attrs.name)) IS \(pgQuoteLiteral(attrs.comment));"
        }
        return sql
    }
}
