import AppKit
import SwiftUI

// =============================================================================
// PostgresNodeContextMenu — node-kind-dependent right-click menu for the
// Object Explorer tree.
//
// Philosophy: navigation actions (Open Data, Properties, Refresh) act
// immediately; anything that changes the database (DROP / TRUNCATE /
// ALTER / VACUUM / REFRESH MATERIALIZED VIEW …) is *scripted, not
// executed* — the menu opens a query tab pre-filled with the statement
// so the user reviews and runs it deliberately. This mirrors pgAdmin's
// "Scripts" pattern and keeps the explorer itself side-effect free.
//
// The menu communicates exclusively through the same notification
// details dictionary the sidebar already posts for taps — the `post`
// closure wraps `postOpenTabNotification`, so no new plumbing between
// sidebar and workspace beyond the new "sql" / "wizard" /
// "backupRestore" kinds.
// =============================================================================

/// Quote a Postgres identifier defensively — mixed-case and
/// reserved-word identifiers silently target the wrong object when
/// unquoted.
func pgQuoteIdent(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

/// Escape a value for inclusion in a single-quoted SQL literal.
func pgQuoteLiteral(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
}

struct PostgresNodeContextMenu: View {
    let node: PgSchemaNode
    /// Bare object name. Defaults to `node.name`; pass explicitly for
    /// constraint/key rows whose display name carries the definition.
    let objectName: String
    let database: String?
    let schema: String?
    /// Parent table for column / constraint / key / trigger rows.
    let table: String?
    /// Query tabs execute against the profile's connected database
    /// only, so SQL-generating items are disabled for objects that
    /// live in another database.
    let isConnectedDb: Bool
    /// Posts an `.openPostgresObjectTab` notification with the given
    /// details (the sidebar adds profileId + node).
    let post: ([String: Any]) -> Void
    /// Re-fetches this node's children from the server.
    let refresh: (() -> Void)?

    init(
        node: PgSchemaNode,
        objectName: String? = nil,
        database: String? = nil,
        schema: String? = nil,
        table: String? = nil,
        isConnectedDb: Bool = true,
        post: @escaping ([String: Any]) -> Void,
        refresh: (() -> Void)? = nil
    ) {
        self.node = node
        self.objectName = objectName ?? node.name
        self.database = database
        self.schema = schema
        self.table = table
        self.isConnectedDb = isConnectedDb
        self.post = post
        self.refresh = refresh
    }

    var body: some View {
        switch node.kind {
        case .database:
            databaseMenu
        case .schema:
            schemaMenu
        case .category:
            refreshButton
        case .relation(let kind):
            relationMenu(kind)
        case .sequence:
            sequenceMenu
        case .routine(let kind, let signature, _):
            routineMenu(kind: kind, signature: signature)
        case .objectType(let kind):
            objectTypeMenu(kind)
        case .column(let typeName, let notNull):
            columnMenu(typeName: typeName, notNull: notNull)
        case .key, .constraint:
            constraintMenu
        case .trigger:
            triggerMenu
        case .language:
            languageMenu
        case .role:
            roleMenu
        case .tablespace:
            tablespaceMenu
        }
    }

    // MARK: - Per-kind menus

    @ViewBuilder
    private var databaseMenu: some View {
        propertiesButton
        refreshButton
        Divider()
        if isConnectedDb {
            Button {
                post(["kind": "backupRestore"])
            } label: {
                Label("Backup / Restore…", systemImage: "arrow.up.doc.fill.and.arrow.down.doc.fill")
            }
        }
        Divider()
        copyNameButton
        // Dropping another database works from the connected session;
        // dropping the connected one fails server-side — the comment
        // in the generated SQL explains both.
        sqlButton(
            "Drop Database…", systemImage: "trash", destructive: true,
            tabTitle: "Drop \(objectName)",
            sql: """
            -- A database cannot be dropped while sessions are connected
            -- to it (including this one). Postgres 13+ can evict them:
            --   DROP DATABASE \(pgQuoteIdent(objectName)) WITH (FORCE);
            DROP DATABASE \(pgQuoteIdent(objectName));
            """
        )
    }

    @ViewBuilder
    private var schemaMenu: some View {
        Button {
            post(["kind": "erd", "schema": objectName])
        } label: {
            Label("Schema Diagram", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .disabled(!isConnectedDb)
        Button {
            post(["kind": "wizard", "schema": objectName])
        } label: {
            Label("Create Object Wizard…", systemImage: "wand.and.stars")
        }
        .disabled(!isConnectedDb)
        propertiesButton
        refreshButton
        Divider()
        copyNameButton
        sqlButton(
            "Drop Schema…", systemImage: "trash", destructive: true,
            tabTitle: "Drop \(objectName)",
            sql: """
            DROP SCHEMA \(pgQuoteIdent(objectName)) RESTRICT;
            -- DROP SCHEMA \(pgQuoteIdent(objectName)) CASCADE;  -- also drop all contained objects
            """
        )
    }

    @ViewBuilder
    private func relationMenu(_ kind: PgRelationDisplayKind) -> some View {
        openDataButton
        propertiesButton
        refreshButton
        Divider()
        copyNameButton
        copyQualifiedNameButton
        sqlButton(
            "Count Rows", systemImage: "number.circle",
            tabTitle: "Count \(objectName)",
            sql: "SELECT count(*) FROM \(qualifiedName);"
        )
        Divider()
        switch kind {
        case .table, .partitionedTable:
            tableActions
        case .view:
            viewActions
        case .materializedView:
            materializedViewActions
        case .foreignTable:
            foreignTableActions
        }
    }

    @ViewBuilder
    private var tableActions: some View {
        Button {
            post([
                "kind": "tableDDL",
                "schema": schema ?? "public",
                "name": objectName,
            ])
        } label: {
            Label("Show CREATE Script", systemImage: "doc.text.magnifyingglass")
        }
        .disabled(!isConnectedDb)
        sqlButton(
            "Modify Schema…", systemImage: "slider.horizontal.3",
            tabTitle: "Alter \(objectName)",
            sql: """
            ALTER TABLE \(qualifiedName)
                ADD COLUMN new_column text;
            -- Common alterations:
            -- ALTER TABLE \(qualifiedName) RENAME TO new_name;
            -- ALTER TABLE \(qualifiedName) RENAME COLUMN old_name TO new_name;
            -- ALTER TABLE \(qualifiedName) ALTER COLUMN col TYPE new_type;
            -- ALTER TABLE \(qualifiedName) ALTER COLUMN col SET NOT NULL;
            -- ALTER TABLE \(qualifiedName) DROP COLUMN col;
            """
        )
        Menu("Import / Export") {
            sqlButton(
                "Export to CSV (COPY)…", systemImage: "square.and.arrow.up",
                tabTitle: "Export \(objectName)",
                sql: """
                -- The file is written by the Postgres *server* process —
                -- the path below must be writable on the server host.
                COPY \(qualifiedName) TO '/tmp/\(objectName).csv' WITH (FORMAT csv, HEADER true);
                """
            )
            sqlButton(
                "Import from CSV (COPY)…", systemImage: "square.and.arrow.down",
                tabTitle: "Import \(objectName)",
                sql: """
                -- The file is read by the Postgres *server* process —
                -- the path below must exist on the server host.
                COPY \(qualifiedName) FROM '/tmp/\(objectName).csv' WITH (FORMAT csv, HEADER true);
                """
            )
        }
        Menu("Maintenance") {
            sqlButton(
                "VACUUM", systemImage: "sparkles",
                tabTitle: "Vacuum \(objectName)",
                sql: "VACUUM (VERBOSE) \(qualifiedName);"
            )
            sqlButton(
                "VACUUM ANALYZE", systemImage: "sparkles",
                tabTitle: "Vacuum \(objectName)",
                sql: "VACUUM (ANALYZE, VERBOSE) \(qualifiedName);"
            )
            sqlButton(
                "VACUUM FULL", systemImage: "sparkles",
                tabTitle: "Vacuum \(objectName)",
                sql: """
                -- VACUUM FULL rewrites the whole table and takes an
                -- ACCESS EXCLUSIVE lock — blocks all reads and writes.
                VACUUM (FULL, VERBOSE) \(qualifiedName);
                """
            )
            sqlButton(
                "ANALYZE", systemImage: "chart.bar",
                tabTitle: "Analyze \(objectName)",
                sql: "ANALYZE (VERBOSE) \(qualifiedName);"
            )
            sqlButton(
                "REINDEX", systemImage: "arrow.triangle.2.circlepath",
                tabTitle: "Reindex \(objectName)",
                sql: "REINDEX TABLE \(qualifiedName);"
            )
        }
        Divider()
        sqlButton(
            "Truncate…", systemImage: "xmark.bin", destructive: true,
            tabTitle: "Truncate \(objectName)",
            sql: """
            TRUNCATE TABLE \(qualifiedName);
            -- Variants:
            -- TRUNCATE TABLE \(qualifiedName) RESTART IDENTITY;          -- also reset owned sequences
            -- TRUNCATE TABLE \(qualifiedName) CASCADE;                   -- also truncate FK-referencing tables
            """
        )
        sqlButton(
            "Drop Table…", systemImage: "trash", destructive: true,
            tabTitle: "Drop \(objectName)",
            sql: """
            DROP TABLE \(qualifiedName);
            -- DROP TABLE \(qualifiedName) CASCADE;  -- also drop dependent objects (views, FKs, …)
            """
        )
    }

    @ViewBuilder
    private var viewActions: some View {
        sqlButton(
            "Show Definition", systemImage: "doc.text.magnifyingglass",
            tabTitle: "Definition \(objectName)",
            sql: "SELECT pg_get_viewdef(\(pgQuoteLiteral(qualifiedName))::regclass, true) AS definition;"
        )
        sqlButton(
            "Alter View…", systemImage: "slider.horizontal.3",
            tabTitle: "Alter \(objectName)",
            sql: """
            -- Replace the body below with the new definition. Run
            -- "Show Definition" first to copy the current one.
            CREATE OR REPLACE VIEW \(qualifiedName) AS
            SELECT 1;
            """
        )
        Divider()
        sqlButton(
            "Drop View…", systemImage: "trash", destructive: true,
            tabTitle: "Drop \(objectName)",
            sql: """
            DROP VIEW \(qualifiedName);
            -- DROP VIEW \(qualifiedName) CASCADE;  -- also drop dependent objects
            """
        )
    }

    @ViewBuilder
    private var materializedViewActions: some View {
        sqlButton(
            "Refresh Materialized View", systemImage: "arrow.clockwise.circle",
            tabTitle: "Refresh \(objectName)",
            sql: "REFRESH MATERIALIZED VIEW \(qualifiedName);"
        )
        sqlButton(
            "Refresh Concurrently", systemImage: "arrow.triangle.2.circlepath.circle",
            tabTitle: "Refresh \(objectName)",
            sql: """
            -- Doesn't block readers, but requires a UNIQUE index on the
            -- materialized view.
            REFRESH MATERIALIZED VIEW CONCURRENTLY \(qualifiedName);
            """
        )
        sqlButton(
            "Show Definition", systemImage: "doc.text.magnifyingglass",
            tabTitle: "Definition \(objectName)",
            sql: "SELECT pg_get_viewdef(\(pgQuoteLiteral(qualifiedName))::regclass, true) AS definition;"
        )
        Divider()
        sqlButton(
            "Drop Materialized View…", systemImage: "trash", destructive: true,
            tabTitle: "Drop \(objectName)",
            sql: """
            DROP MATERIALIZED VIEW \(qualifiedName);
            -- DROP MATERIALIZED VIEW \(qualifiedName) CASCADE;
            """
        )
    }

    @ViewBuilder
    private var foreignTableActions: some View {
        sqlButton(
            "Drop Foreign Table…", systemImage: "trash", destructive: true,
            tabTitle: "Drop \(objectName)",
            sql: "DROP FOREIGN TABLE \(qualifiedName);"
        )
    }

    @ViewBuilder
    private var sequenceMenu: some View {
        Button {
            guard let schema else { return }
            post(["kind": "sequence", "schema": schema, "name": objectName])
        } label: {
            Label("Open", systemImage: "number")
        }
        .disabled(!isConnectedDb)
        propertiesButton
        Divider()
        sqlButton(
            "Next Value", systemImage: "arrow.forward.circle",
            tabTitle: "nextval \(objectName)",
            sql: "SELECT nextval(\(pgQuoteLiteral(qualifiedName)));"
        )
        sqlButton(
            "Current Value", systemImage: "equal.circle",
            tabTitle: "currval \(objectName)",
            sql: "SELECT last_value, is_called FROM \(qualifiedName);"
        )
        sqlButton(
            "Restart Sequence…", systemImage: "arrow.counterclockwise",
            tabTitle: "Restart \(objectName)",
            sql: "ALTER SEQUENCE \(qualifiedName) RESTART WITH 1;"
        )
        Divider()
        copyNameButton
        sqlButton(
            "Drop Sequence…", systemImage: "trash", destructive: true,
            tabTitle: "Drop \(objectName)",
            sql: "DROP SEQUENCE \(qualifiedName);"
        )
    }

    @ViewBuilder
    private func routineMenu(kind: PgRoutineDisplayKind, signature: String) -> some View {
        Button {
            guard let schema else { return }
            post(["kind": "routine", "schema": schema, "name": objectName, "signature": signature])
        } label: {
            Label("View Definition", systemImage: "doc.text.magnifyingglass")
        }
        .disabled(!isConnectedDb)
        propertiesButton
        Divider()
        switch kind {
        case .procedure:
            sqlButton(
                "Call Procedure…", systemImage: "play.circle",
                tabTitle: "Call \(objectName)",
                sql: """
                -- signature: \(signature)
                CALL \(qualifiedName)(/* arguments */);
                """
            )
        case .function, .window:
            sqlButton(
                "Execute Function…", systemImage: "play.circle",
                tabTitle: "Execute \(objectName)",
                sql: """
                -- signature: \(signature)
                SELECT * FROM \(qualifiedName)(/* arguments */);
                """
            )
        case .aggregate:
            EmptyView()
        }
        Divider()
        copyNameButton
        sqlButton(
            "Drop \(dropKeyword(for: kind))…", systemImage: "trash", destructive: true,
            tabTitle: "Drop \(objectName)",
            sql: "DROP \(dropKeyword(for: kind).uppercased()) \(qualifiedName)\(signature);"
        )
    }

    @ViewBuilder
    private func objectTypeMenu(_ kind: PgObjectTypeDisplayKind) -> some View {
        Button {
            guard let schema else { return }
            post(["kind": "objectType", "schema": schema, "name": objectName, "typeKind": kind.rawValue])
        } label: {
            Label("Open", systemImage: kind.sfSymbol)
        }
        .disabled(!isConnectedDb)
        propertiesButton
        Divider()
        if kind == .enum {
            sqlButton(
                "Add Enum Value…", systemImage: "plus.circle",
                tabTitle: "Alter \(objectName)",
                sql: """
                ALTER TYPE \(qualifiedName) ADD VALUE 'new_value';
                -- ALTER TYPE \(qualifiedName) ADD VALUE 'new_value' BEFORE 'existing_value';
                """
            )
        }
        copyNameButton
        sqlButton(
            "Drop \(kind == .domain ? "Domain" : "Type")…", systemImage: "trash", destructive: true,
            tabTitle: "Drop \(objectName)",
            sql: "DROP \(kind == .domain ? "DOMAIN" : "TYPE") \(qualifiedName);"
        )
    }

    @ViewBuilder
    private func columnMenu(typeName: String, notNull: Bool) -> some View {
        propertiesButton
        copyNameButton
        Divider()
        if let qualifiedTable {
            sqlButton(
                "Rename Column…", systemImage: "pencil",
                tabTitle: "Alter \(objectName)",
                sql: "ALTER TABLE \(qualifiedTable) RENAME COLUMN \(pgQuoteIdent(objectName)) TO new_name;"
            )
            sqlButton(
                "Change Type…", systemImage: "arrow.left.arrow.right",
                tabTitle: "Alter \(objectName)",
                sql: """
                -- current type: \(typeName)
                ALTER TABLE \(qualifiedTable) ALTER COLUMN \(pgQuoteIdent(objectName)) TYPE new_type;
                """
            )
            sqlButton(
                notNull ? "Drop NOT NULL…" : "Set NOT NULL…", systemImage: "exclamationmark.circle",
                tabTitle: "Alter \(objectName)",
                sql: "ALTER TABLE \(qualifiedTable) ALTER COLUMN \(pgQuoteIdent(objectName)) \(notNull ? "DROP" : "SET") NOT NULL;"
            )
            Divider()
            sqlButton(
                "Drop Column…", systemImage: "trash", destructive: true,
                tabTitle: "Drop \(objectName)",
                sql: "ALTER TABLE \(qualifiedTable) DROP COLUMN \(pgQuoteIdent(objectName));"
            )
        }
    }

    @ViewBuilder
    private var constraintMenu: some View {
        propertiesButton
        copyNameButton
        if let qualifiedTable {
            Divider()
            sqlButton(
                "Drop Constraint…", systemImage: "trash", destructive: true,
                tabTitle: "Drop \(objectName)",
                sql: "ALTER TABLE \(qualifiedTable) DROP CONSTRAINT \(pgQuoteIdent(objectName));"
            )
        }
    }

    @ViewBuilder
    private var triggerMenu: some View {
        propertiesButton
        copyNameButton
        if let qualifiedTable {
            Divider()
            sqlButton(
                "Disable Trigger…", systemImage: "pause.circle",
                tabTitle: "Disable \(objectName)",
                sql: "ALTER TABLE \(qualifiedTable) DISABLE TRIGGER \(pgQuoteIdent(objectName));"
            )
            sqlButton(
                "Enable Trigger…", systemImage: "play.circle",
                tabTitle: "Enable \(objectName)",
                sql: "ALTER TABLE \(qualifiedTable) ENABLE TRIGGER \(pgQuoteIdent(objectName));"
            )
            Divider()
            sqlButton(
                "Drop Trigger…", systemImage: "trash", destructive: true,
                tabTitle: "Drop \(objectName)",
                sql: "DROP TRIGGER \(pgQuoteIdent(objectName)) ON \(qualifiedTable);"
            )
        }
    }

    @ViewBuilder
    private var languageMenu: some View {
        propertiesButton
        copyNameButton
        Divider()
        sqlButton(
            "Drop Language…", systemImage: "trash", destructive: true,
            tabTitle: "Drop \(objectName)",
            sql: """
            DROP LANGUAGE \(pgQuoteIdent(objectName));
            -- DROP LANGUAGE \(pgQuoteIdent(objectName)) CASCADE;  -- also drop functions written in it
            """
        )
    }

    @ViewBuilder
    private var roleMenu: some View {
        propertiesButton
        copyNameButton
        Divider()
        sqlButton(
            "Alter Role…", systemImage: "slider.horizontal.3",
            tabTitle: "Alter \(objectName)",
            sql: """
            ALTER ROLE \(pgQuoteIdent(objectName)) WITH /* options */;
            -- Options: LOGIN | NOLOGIN | SUPERUSER | NOSUPERUSER |
            --          CREATEDB | CREATEROLE | PASSWORD 'new_password' |
            --          CONNECTION LIMIT n | VALID UNTIL 'timestamp'
            """
        )
        sqlButton(
            "Drop Role…", systemImage: "trash", destructive: true,
            tabTitle: "Drop \(objectName)",
            sql: """
            -- If the role owns objects, reassign or drop them first:
            -- REASSIGN OWNED BY \(pgQuoteIdent(objectName)) TO new_owner;
            -- DROP OWNED BY \(pgQuoteIdent(objectName));
            DROP ROLE \(pgQuoteIdent(objectName));
            """
        )
    }

    @ViewBuilder
    private var tablespaceMenu: some View {
        propertiesButton
        copyNameButton
        Divider()
        sqlButton(
            "Drop Tablespace…", systemImage: "trash", destructive: true,
            tabTitle: "Drop \(objectName)",
            sql: """
            -- A tablespace must be empty before it can be dropped.
            DROP TABLESPACE \(pgQuoteIdent(objectName));
            """
        )
    }

    // MARK: - Shared building blocks

    private var propertiesButton: some View {
        Button {
            post(["kind": "properties"])
        } label: {
            Label("Properties", systemImage: "info.circle")
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        if let refresh {
            Button {
                refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private var openDataButton: some View {
        Button {
            guard let schema else { return }
            post(["kind": "relation", "schema": schema, "name": objectName])
        } label: {
            Label("Open Data", systemImage: "tablecells")
        }
        .disabled(!isConnectedDb)
    }

    private var copyNameButton: some View {
        Button {
            copyToPasteboard(objectName)
        } label: {
            Label("Copy Name", systemImage: "doc.on.doc")
        }
    }

    private var copyQualifiedNameButton: some View {
        Button {
            copyToPasteboard(qualifiedName)
        } label: {
            Label("Copy Qualified Name", systemImage: "doc.on.doc.fill")
        }
    }

    /// Menu item that opens a query tab pre-filled with `sql` for
    /// review — nothing executes until the user presses Run.
    private func sqlButton(
        _ title: String,
        systemImage: String,
        destructive: Bool = false,
        tabTitle: String,
        sql: String
    ) -> some View {
        Button(role: destructive ? .destructive : nil) {
            post(["kind": "sql", "title": tabTitle, "sql": sql])
        } label: {
            Label(title, systemImage: systemImage)
        }
        .disabled(!isConnectedDb)
    }

    // MARK: - Helpers

    /// `"schema"."name"` when a schema is known, else `"name"`.
    private var qualifiedName: String {
        if let schema {
            return "\(pgQuoteIdent(schema)).\(pgQuoteIdent(objectName))"
        }
        return pgQuoteIdent(objectName)
    }

    /// `"schema"."table"` for rows that hang off a relation
    /// (columns, constraints, triggers); `nil` elsewhere.
    private var qualifiedTable: String? {
        guard let schema, let table else { return nil }
        return "\(pgQuoteIdent(schema)).\(pgQuoteIdent(table))"
    }

    private func dropKeyword(for kind: PgRoutineDisplayKind) -> String {
        switch kind {
        case .function, .window: return "Function"
        case .procedure:         return "Procedure"
        case .aggregate:         return "Aggregate"
        }
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
