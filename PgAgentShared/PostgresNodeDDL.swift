import Foundation
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresNodeDDL — reconstruct CREATE/ALTER DDL for any schema-tree node.
//
// One engine for the Property Inspector's "DDL Source" tab. Each node kind
// maps to a catalog query plus a pure renderer (rows in → SQL out), so the
// rendering logic is unit-testable without a live server. Output is an
// honest, readable approximation — not a byte-faithful pg_dump replacement
// (no grants, storage parameters, or ownership chains unless stated).
//
// Routines are the flagship: `pg_get_functiondef` for the exact overload
// (matched on `pg_get_function_identity_arguments`), CREATE AGGREGATE
// reconstruction for aggregates (where pg_get_functiondef raises), and a
// commented shape stub for C/internal functions whose source lives outside
// the database.
// =============================================================================

enum PostgresNodeDDL {

    // MARK: - Node-id parsing

    /// Resolved identity of a tree node, split out of the composite
    /// node id (`kind:db.schema[.table].name`).
    struct Target: Equatable {
        let database: String
        let schema: String
        /// Parent table for table-scoped children (columns, keys,
        /// constraints, triggers); `nil` otherwise.
        let table: String?
        let name: String
    }

    /// Kind-aware parse of the node's composite id. Splits with
    /// `maxSplits` so the trailing object name may itself contain
    /// dots, and strips the routine argument signature using the
    /// *known* signature carried on `node.kind` — the signature has
    /// no surrounding parentheses (`integer, text`), so the old
    /// "search for a `(`" approach mangled every routine that takes
    /// arguments.
    static func target(for node: PgSchemaNode) -> Target? {
        let parts = node.id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let rest = String(parts[1])

        switch node.kind {
        case .database:
            return Target(database: rest, schema: "", table: nil, name: rest)
        case .role, .tablespace:
            return Target(database: "", schema: "", table: nil, name: rest)
        case .schema, .language:
            let p = rest.split(separator: ".", maxSplits: 1).map(String.init)
            guard p.count == 2 else { return nil }
            return Target(database: p[0], schema: p[1], table: nil, name: p[1])
        case .routine(_, let signature, _):
            let p = rest.split(separator: ".", maxSplits: 2).map(String.init)
            guard p.count == 3 else { return nil }
            var name = p[2]
            if !signature.isEmpty, name.hasSuffix(signature) {
                name = String(name.dropLast(signature.count))
            }
            return Target(database: p[0], schema: p[1], table: nil, name: name)
        case .relation, .sequence, .objectType:
            let p = rest.split(separator: ".", maxSplits: 2).map(String.init)
            guard p.count == 3 else { return nil }
            return Target(database: p[0], schema: p[1], table: nil, name: p[2])
        case .column, .key, .constraint, .trigger:
            let p = rest.split(separator: ".", maxSplits: 3).map(String.init)
            guard p.count == 4 else { return nil }
            return Target(database: p[0], schema: p[1], table: p[2], name: p[3])
        case .category:
            return nil
        }
    }

    // MARK: - Entry point

    /// Reconstruct DDL for `node` against the live catalog. Always
    /// returns displayable text — failures come back as SQL comments
    /// so the DDL pane never shows a bare error state.
    static func reconstruct(node: PgSchemaNode, connectionId: String) async -> String {
        guard let target = target(for: node) else {
            return "-- DDL not available: unrecognized node id '\(node.id)'."
        }
        let sessionId = "ddl-loader-\(UUID().uuidString)"
        let ddl = await fetch(
            node: node, target: target, connectionId: connectionId, sessionId: sessionId)
        // Release within this structured context — awaited on every
        // path — rather than via `defer { Task { … } }`, whose
        // unstructured task could lag behind rapid node switching and
        // pile up leased sessions. (Same rationale as PgSchemaStore.)
        await BridgeManager.shared.pgReleaseSession(
            connectionId: connectionId, sessionId: sessionId)
        return ddl
    }

    private static func fetch(
        node: PgSchemaNode, target: Target, connectionId: String, sessionId: String
    ) async -> String {
        func run(_ sql: String, pageSize: UInt32 = 500) async throws -> [[String?]] {
            try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: sql,
                pageSize: pageSize
            ).rows.map(\.cells)
        }

        do {
            switch node.kind {
            case .relation(let kind):
                switch kind {
                case .view, .materializedView:
                    let rows = try await run(viewQuery(schema: target.schema, name: target.name))
                    return renderViewDDL(
                        rows: rows,
                        schema: target.schema,
                        name: target.name,
                        materialized: kind == .materializedView
                    )
                case .table, .partitionedTable, .foreignTable:
                    // The full table generator (columns, defaults,
                    // identity, constraints, secondary indexes,
                    // comments) already exists — reuse it.
                    return try await PostgresTableDDL.generate(
                        connectionId: connectionId,
                        schema: target.schema,
                        table: target.name
                    )
                }
            case .routine(_, let signature, _):
                let rows = try await run(routineQuery(schema: target.schema, name: target.name))
                return renderRoutineDDL(
                    rows: rows, schema: target.schema, name: target.name, signature: signature)
            case .sequence:
                let rows = try await run(sequenceQuery(schema: target.schema, name: target.name))
                return renderSequenceDDL(rows: rows, schema: target.schema, name: target.name)
            case .objectType(let kind):
                let sql = objectTypeQuery(kind: kind, schema: target.schema, name: target.name)
                let rows = try await run(sql)
                return renderObjectTypeDDL(
                    kind: kind, rows: rows, schema: target.schema, name: target.name)
            case .column:
                guard let table = target.table else { break }
                let rows = try await run(columnQuery(
                    schema: target.schema, table: table, column: target.name))
                return renderColumnDDL(
                    rows: rows, schema: target.schema, table: table, column: target.name)
            case .key, .constraint:
                guard let table = target.table else { break }
                let rows = try await run(constraintQuery(
                    schema: target.schema, table: table, name: target.name))
                return rows.first?.first.flatMap { $0 }
                    ?? "-- Constraint \(target.name) not found on \(target.schema).\(table)."
            case .trigger:
                guard let table = target.table else { break }
                let rows = try await run(triggerQuery(
                    schema: target.schema, table: table, name: target.name))
                if let def = rows.first?.first.flatMap({ $0 }) {
                    return def + ";"
                }
                return "-- Trigger \(target.name) not found on \(target.schema).\(table)."
            case .database:
                let rows = try await run(databaseQuery(name: target.name))
                return renderDatabaseDDL(rows: rows, name: target.name)
            case .schema:
                let rows = try await run(schemaQuery(name: target.name))
                return renderSchemaDDL(rows: rows, name: target.name)
            case .role:
                let rows = try await run(roleQuery(name: target.name))
                return renderRoleDDL(rows: rows, name: target.name)
            case .tablespace:
                let rows = try await run(tablespaceQuery(name: target.name))
                return renderTablespaceDDL(rows: rows, name: target.name)
            case .language:
                let rows = try await run(languageQuery(name: target.name))
                return renderLanguageDDL(rows: rows, name: target.name)
            case .category:
                break
            }
        } catch {
            return "-- Failed to fetch DDL: \(error.localizedDescription)"
        }
        return "-- DDL reconstruction not supported for \(node.name)."
    }

    // MARK: - SQL builders (pure)

    /// `'"schema"."name"'` literal for `to_regclass` anchoring —
    /// injection-safe and resolves mixed-case names correctly.
    private static func regclassLiteral(_ schema: String, _ name: String) -> String {
        pgQuoteLiteral(pgQuoteIdent(schema) + "." + pgQuoteIdent(name))
    }

    /// All overloads of (schema, name), one row each. Column layout:
    /// 0 identity args · 1 prokind · 2 language · 3 functiondef
    /// (NULL for aggregates and C/internal) · 4 prosrc · 5 result
    /// type · 6 full argument list · 7 CREATE AGGREGATE (aggregates
    /// only, built server-side where the catalog types are at hand).
    static func routineQuery(schema: String, name: String) -> String {
        """
        SELECT pg_get_function_identity_arguments(p.oid),
               p.prokind::text,
               l.lanname,
               CASE WHEN p.prokind <> 'a' AND l.lanname NOT IN ('internal', 'c')
                    THEN pg_get_functiondef(p.oid) END,
               p.prosrc,
               pg_get_function_result(p.oid),
               pg_get_function_arguments(p.oid),
               CASE WHEN p.prokind = 'a' THEN
                 (SELECT format(
                    E'CREATE AGGREGATE %I.%I(%s) (\\n    SFUNC = %s,\\n    STYPE = %s%s%s\\n);',
                    n.nspname, p.proname,
                    pg_get_function_identity_arguments(p.oid),
                    a.aggtransfn::regproc::text,
                    format_type(a.aggtranstype, NULL),
                    CASE WHEN a.aggfinalfn <> 0
                         THEN E',\\n    FINALFUNC = ' || a.aggfinalfn::regproc::text
                         ELSE '' END,
                    CASE WHEN a.agginitval IS NOT NULL
                         THEN E',\\n    INITCOND = ' || quote_literal(a.agginitval)
                         ELSE '' END)
                  FROM pg_aggregate a WHERE a.aggfnoid = p.oid) END
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        LEFT JOIN pg_language l ON l.oid = p.prolang
        WHERE n.nspname = \(pgQuoteLiteral(schema))
          AND p.proname = \(pgQuoteLiteral(name))
        ORDER BY 1;
        """
    }

    static func viewQuery(schema: String, name: String) -> String {
        "SELECT pg_get_viewdef(to_regclass(\(regclassLiteral(schema, name))), true);"
    }

    /// Sequence parameters from `pg_sequences` (PG10+) plus the
    /// OWNED BY column resolved through `pg_depend`.
    static func sequenceQuery(schema: String, name: String) -> String {
        """
        SELECT s.data_type::text, s.start_value::text, s.increment_by::text,
               s.min_value::text, s.max_value::text, s.cache_size::text,
               s.cycle::text,
               (SELECT quote_ident(n2.nspname) || '.' || quote_ident(c2.relname)
                       || '.' || quote_ident(a2.attname)
                  FROM pg_depend d
                  JOIN pg_class c2 ON c2.oid = d.refobjid
                  JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
                  JOIN pg_attribute a2
                    ON a2.attrelid = d.refobjid AND a2.attnum = d.refobjsubid
                 WHERE d.objid = to_regclass(\(regclassLiteral(schema, name)))
                   AND d.classid = 'pg_class'::regclass
                   AND d.deptype IN ('a', 'i')
                 LIMIT 1)
        FROM pg_sequences s
        WHERE s.schemaname = \(pgQuoteLiteral(schema))
          AND s.sequencename = \(pgQuoteLiteral(name));
        """
    }

    static func objectTypeQuery(
        kind: PgObjectTypeDisplayKind, schema: String, name: String
    ) -> String {
        switch kind {
        case .composite:
            return """
            SELECT a.attname, format_type(a.atttypid, a.atttypmod)
            FROM pg_attribute a
            WHERE a.attrelid = to_regclass(\(regclassLiteral(schema, name)))
              AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum;
            """
        case .enum:
            return """
            SELECT e.enumlabel
            FROM pg_enum e
            JOIN pg_type t ON t.oid = e.enumtypid
            JOIN pg_namespace n ON n.oid = t.typnamespace
            WHERE n.nspname = \(pgQuoteLiteral(schema))
              AND t.typname = \(pgQuoteLiteral(name))
            ORDER BY e.enumsortorder;
            """
        case .domain:
            return """
            SELECT format_type(t.typbasetype, t.typtypmod),
                   t.typnotnull::text,
                   t.typdefault,
                   (SELECT string_agg(pg_get_constraintdef(c.oid, true), E'\\n    ')
                      FROM pg_constraint c WHERE c.contypid = t.oid AND c.contype = 'c')
            FROM pg_type t
            JOIN pg_namespace n ON n.oid = t.typnamespace
            WHERE n.nspname = \(pgQuoteLiteral(schema))
              AND t.typname = \(pgQuoteLiteral(name));
            """
        case .range:
            return """
            SELECT format_type(r.rngsubtype, NULL)
            FROM pg_range r
            JOIN pg_type t ON t.oid = r.rngtypid
            JOIN pg_namespace n ON n.oid = t.typnamespace
            WHERE n.nspname = \(pgQuoteLiteral(schema))
              AND t.typname = \(pgQuoteLiteral(name));
            """
        }
    }

    static func columnQuery(schema: String, table: String, column: String) -> String {
        """
        SELECT format_type(a.atttypid, a.atttypmod),
               a.attnotnull::text,
               pg_get_expr(ad.adbin, ad.adrelid),
               a.attidentity::text,
               a.attgenerated::text,
               col_description(a.attrelid, a.attnum)
        FROM pg_attribute a
        LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
        WHERE a.attrelid = to_regclass(\(regclassLiteral(schema, table)))
          AND a.attname = \(pgQuoteLiteral(column))
          AND NOT a.attisdropped;
        """
    }

    /// The full ALTER TABLE … ADD CONSTRAINT statement, assembled
    /// server-side where `pg_get_constraintdef` lives.
    static func constraintQuery(schema: String, table: String, name: String) -> String {
        """
        SELECT 'ALTER TABLE ' || c.conrelid::regclass::text
               || E'\\n    ADD CONSTRAINT ' || quote_ident(c.conname)
               || ' ' || pg_get_constraintdef(c.oid, true) || ';'
        FROM pg_constraint c
        WHERE c.conrelid = to_regclass(\(regclassLiteral(schema, table)))
          AND c.conname = \(pgQuoteLiteral(name));
        """
    }

    static func triggerQuery(schema: String, table: String, name: String) -> String {
        """
        SELECT pg_get_triggerdef(t.oid)
        FROM pg_trigger t
        WHERE t.tgrelid = to_regclass(\(regclassLiteral(schema, table)))
          AND t.tgname = \(pgQuoteLiteral(name));
        """
    }

    static func databaseQuery(name: String) -> String {
        """
        SELECT pg_encoding_to_char(d.encoding), d.datcollate, d.datctype,
               pg_get_userbyid(d.datdba)
        FROM pg_database d
        WHERE d.datname = \(pgQuoteLiteral(name));
        """
    }

    static func schemaQuery(name: String) -> String {
        """
        SELECT pg_get_userbyid(n.nspowner),
               obj_description(n.oid, 'pg_namespace')
        FROM pg_namespace n
        WHERE n.nspname = \(pgQuoteLiteral(name));
        """
    }

    static func roleQuery(name: String) -> String {
        """
        SELECT r.rolsuper::text, r.rolcreatedb::text, r.rolcreaterole::text,
               r.rolinherit::text, r.rolcanlogin::text, r.rolreplication::text,
               r.rolconnlimit::text, r.rolvaliduntil::text
        FROM pg_roles r
        WHERE r.rolname = \(pgQuoteLiteral(name));
        """
    }

    static func tablespaceQuery(name: String) -> String {
        """
        SELECT pg_get_userbyid(t.spcowner), pg_tablespace_location(t.oid)
        FROM pg_tablespace t
        WHERE t.spcname = \(pgQuoteLiteral(name));
        """
    }

    static func languageQuery(name: String) -> String {
        """
        SELECT l.lanpltrusted::text
        FROM pg_language l
        WHERE l.lanname = \(pgQuoteLiteral(name));
        """
    }

    // MARK: - Renderers (pure)

    private static func cell(_ row: [String?], _ index: Int) -> String? {
        index < row.count ? row[index] : nil
    }

    static func renderRoutineDDL(
        rows: [[String?]], schema: String, name: String, signature: String
    ) -> String {
        guard !rows.isEmpty else {
            return "-- Routine \(schema).\(name) not found in pg_proc."
        }
        // Exact overload first; if the signature doesn't match any
        // row (stale tree, renamed args), show every overload rather
        // than guessing one.
        let wanted = signature.trimmingCharacters(in: .whitespaces)
        let exact = rows.filter {
            (cell($0, 0) ?? "").trimmingCharacters(in: .whitespaces) == wanted
        }
        let chosen = exact.isEmpty ? rows : exact
        var blocks: [String] = []
        if exact.isEmpty && rows.count > 1 {
            blocks.append(
                "-- \(rows.count) overloads of \(schema).\(name) — exact signature match not found, showing all.")
        }
        for row in chosen {
            blocks.append(renderOneRoutine(row: row, schema: schema, name: name))
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func renderOneRoutine(
        row: [String?], schema: String, name: String
    ) -> String {
        if let def = cell(row, 3), !def.isEmpty {
            return def.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let identityArgs = cell(row, 0) ?? ""
        let prokind = cell(row, 1) ?? "f"
        if prokind == "a" {
            if let aggDef = cell(row, 7), !aggDef.isEmpty { return aggDef }
            return "-- Aggregate \(schema).\(name)(\(identityArgs)) — definition unavailable."
        }
        // C / internal routine: the body is a symbol in a shared
        // library, so pg_get_functiondef (which would raise) is
        // skipped server-side. Render the shape with the symbol name.
        let language = cell(row, 2) ?? "internal"
        let args = cell(row, 6) ?? identityArgs
        let returns = cell(row, 5)
        let src = cell(row, 4) ?? ""
        let kindWord = prokind == "p" ? "PROCEDURE" : "FUNCTION"
        var out = "-- \(language) routine — the body is compiled code, not SQL;\n"
        out += "-- showing the declared shape.\n"
        out += "CREATE \(kindWord) \(pgQuoteIdent(schema)).\(pgQuoteIdent(name))(\(args))\n"
        if let returns, !returns.isEmpty {
            out += "    RETURNS \(returns)\n"
        }
        out += "    LANGUAGE \(language)\n"
        out += "    AS \(pgQuoteLiteral(src));"
        return out
    }

    static func renderViewDDL(
        rows: [[String?]], schema: String, name: String, materialized: Bool
    ) -> String {
        guard let def = rows.first?.first.flatMap({ $0 }),
              !def.isEmpty
        else { return "-- View \(schema).\(name) not found." }
        let keyword = materialized ? "CREATE MATERIALIZED VIEW" : "CREATE OR REPLACE VIEW"
        let qualified = "\(pgQuoteIdent(schema)).\(pgQuoteIdent(name))"
        return "\(keyword) \(qualified) AS\n\(def.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    static func renderSequenceDDL(rows: [[String?]], schema: String, name: String) -> String {
        guard let row = rows.first else {
            return "-- Sequence \(schema).\(name) not found in pg_sequences."
        }
        let qualified = "\(pgQuoteIdent(schema)).\(pgQuoteIdent(name))"
        var lines = ["CREATE SEQUENCE \(qualified)"]
        if let dataType = cell(row, 0), dataType != "bigint" {
            lines.append("    AS \(dataType)")
        }
        if let start = cell(row, 1) { lines.append("    START WITH \(start)") }
        if let increment = cell(row, 2) { lines.append("    INCREMENT BY \(increment)") }
        if let min = cell(row, 3) { lines.append("    MINVALUE \(min)") }
        if let max = cell(row, 4) { lines.append("    MAXVALUE \(max)") }
        if let cache = cell(row, 5) { lines.append("    CACHE \(cache)") }
        lines.append("    \(cell(row, 6) == "true" ? "CYCLE" : "NO CYCLE");")
        var out = lines.joined(separator: "\n")
        if let ownedBy = cell(row, 7), !ownedBy.isEmpty {
            out += "\n\nALTER SEQUENCE \(qualified) OWNED BY \(ownedBy);"
        }
        return out
    }

    static func renderObjectTypeDDL(
        kind: PgObjectTypeDisplayKind, rows: [[String?]], schema: String, name: String
    ) -> String {
        let qualified = "\(pgQuoteIdent(schema)).\(pgQuoteIdent(name))"
        switch kind {
        case .composite:
            guard !rows.isEmpty else { return "-- Type \(schema).\(name) not found." }
            let fields = rows.compactMap { row -> String? in
                guard let attr = cell(row, 0), let type = cell(row, 1) else { return nil }
                return "    \(pgQuoteIdent(attr)) \(type)"
            }
            return "CREATE TYPE \(qualified) AS (\n\(fields.joined(separator: ",\n"))\n);"
        case .enum:
            guard !rows.isEmpty else { return "-- Enum \(schema).\(name) not found." }
            let labels = rows
                .compactMap { cell($0, 0) }
                .map { "    \(pgQuoteLiteral($0))" }
                .joined(separator: ",\n")
            return "CREATE TYPE \(qualified) AS ENUM (\n\(labels)\n);"
        case .domain:
            guard let row = rows.first, let baseType = cell(row, 0) else {
                return "-- Domain \(schema).\(name) not found."
            }
            var out = "CREATE DOMAIN \(qualified) AS \(baseType)"
            if let defaultExpr = cell(row, 2), !defaultExpr.isEmpty {
                out += "\n    DEFAULT \(defaultExpr)"
            }
            if cell(row, 1) == "true" {
                out += "\n    NOT NULL"
            }
            if let constraints = cell(row, 3), !constraints.isEmpty {
                out += "\n    \(constraints)"
            }
            return out + ";"
        case .range:
            guard let row = rows.first, let subtype = cell(row, 0) else {
                return "-- Range type \(schema).\(name) not found."
            }
            return "CREATE TYPE \(qualified) AS RANGE (\n    SUBTYPE = \(subtype)\n);"
        }
    }

    static func renderColumnDDL(
        rows: [[String?]], schema: String, table: String, column: String
    ) -> String {
        guard let row = rows.first, let type = cell(row, 0) else {
            return "-- Column \(column) not found on \(schema).\(table)."
        }
        let qualifiedTable = "\(pgQuoteIdent(schema)).\(pgQuoteIdent(table))"
        var def = "\(pgQuoteIdent(column)) \(type)"
        let defaultExpr = cell(row, 2)
        switch cell(row, 4) {
        case "s":
            if let expr = defaultExpr { def += " GENERATED ALWAYS AS (\(expr)) STORED" }
        default:
            switch cell(row, 3) {
            case "a": def += " GENERATED ALWAYS AS IDENTITY"
            case "d": def += " GENERATED BY DEFAULT AS IDENTITY"
            default:
                if let expr = defaultExpr, !expr.isEmpty { def += " DEFAULT \(expr)" }
            }
        }
        if cell(row, 1) == "true" { def += " NOT NULL" }
        var out = "ALTER TABLE \(qualifiedTable)\n    ADD COLUMN \(def);"
        if let comment = cell(row, 5), !comment.isEmpty {
            out += "\n\nCOMMENT ON COLUMN \(qualifiedTable).\(pgQuoteIdent(column)) IS \(pgQuoteLiteral(comment));"
        }
        return out
    }

    static func renderDatabaseDDL(rows: [[String?]], name: String) -> String {
        guard let row = rows.first else { return "-- Database \(name) not found." }
        var lines = ["CREATE DATABASE \(pgQuoteIdent(name))"]
        if let owner = cell(row, 3) { lines.append("    OWNER \(pgQuoteIdent(owner))") }
        if let encoding = cell(row, 0) { lines.append("    ENCODING \(pgQuoteLiteral(encoding))") }
        if let collate = cell(row, 1) { lines.append("    LC_COLLATE \(pgQuoteLiteral(collate))") }
        if let ctype = cell(row, 2) { lines.append("    LC_CTYPE \(pgQuoteLiteral(ctype))") }
        return lines.joined(separator: "\n") + ";"
    }

    static func renderSchemaDDL(rows: [[String?]], name: String) -> String {
        guard let row = rows.first else { return "-- Schema \(name) not found." }
        var out = "CREATE SCHEMA \(pgQuoteIdent(name))"
        if let owner = cell(row, 0) {
            out += " AUTHORIZATION \(pgQuoteIdent(owner))"
        }
        out += ";"
        if let comment = cell(row, 1), !comment.isEmpty {
            out += "\n\nCOMMENT ON SCHEMA \(pgQuoteIdent(name)) IS \(pgQuoteLiteral(comment));"
        }
        return out
    }

    static func renderRoleDDL(rows: [[String?]], name: String) -> String {
        guard let row = rows.first else { return "-- Role \(name) not found." }
        var options: [String] = []
        options.append(cell(row, 0) == "true" ? "SUPERUSER" : "NOSUPERUSER")
        options.append(cell(row, 1) == "true" ? "CREATEDB" : "NOCREATEDB")
        options.append(cell(row, 2) == "true" ? "CREATEROLE" : "NOCREATEROLE")
        options.append(cell(row, 3) == "true" ? "INHERIT" : "NOINHERIT")
        options.append(cell(row, 4) == "true" ? "LOGIN" : "NOLOGIN")
        options.append(cell(row, 5) == "true" ? "REPLICATION" : "NOREPLICATION")
        if let limit = cell(row, 6), limit != "-1" {
            options.append("CONNECTION LIMIT \(limit)")
        }
        if let validUntil = cell(row, 7), !validUntil.isEmpty {
            options.append("VALID UNTIL \(pgQuoteLiteral(validUntil))")
        }
        return """
        -- Password (if any) is not recoverable from the catalog.
        CREATE ROLE \(pgQuoteIdent(name)) WITH
            \(options.joined(separator: "\n    "));
        """
    }

    static func renderTablespaceDDL(rows: [[String?]], name: String) -> String {
        guard let row = rows.first else { return "-- Tablespace \(name) not found." }
        var lines = ["CREATE TABLESPACE \(pgQuoteIdent(name))"]
        if let owner = cell(row, 0) { lines.append("    OWNER \(pgQuoteIdent(owner))") }
        let location = cell(row, 1) ?? ""
        if location.isEmpty {
            lines.append("    -- built-in tablespace; no on-disk location of its own")
        } else {
            lines.append("    LOCATION \(pgQuoteLiteral(location))")
        }
        return lines.joined(separator: "\n") + ";"
    }

    static func renderLanguageDDL(rows: [[String?]], name: String) -> String {
        guard let row = rows.first else { return "-- Language \(name) not found." }
        let trusted = cell(row, 0) == "true" ? "TRUSTED " : ""
        return """
        -- Procedural languages usually arrive via CREATE EXTENSION.
        CREATE \(trusted)LANGUAGE \(pgQuoteIdent(name));
        """
    }
}
