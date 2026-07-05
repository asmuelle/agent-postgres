import Foundation
import OSLog
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PgSchemaStore — `@Observable` cache for the Postgres browser tree.
//
// State is intentionally simple: a load state per node (idle/loading/loaded/
// failed). Lazy loading happens on demand from the view layer. No background
// refresh in Sprint 1 — DDL changes show up after manual refresh, which is
// honest. Background invalidation lands when we have query execution and
// can subscribe to NOTIFY channels.
// =============================================================================

enum PgLoadState<T: Sendable>: Sendable {
    case idle
    case loading
    case loaded(T)
    case failed(String)

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

/// One node in the schema tree. Four levels (database → schema →
/// category → item). Categories are fixed group headers that group
/// same-kind items underneath a schema (Tables, Views, Materialized
/// Views, Sequences, Routines, Object Types).
struct PgSchemaNode: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case database
        case schema(isSystem: Bool)
        /// Fixed category header under a schema.
        case category(PgCategoryKind, count: Int)
        case relation(kind: PgRelationDisplayKind)
        case sequence
        case routine(kind: PgRoutineDisplayKind, signature: String, returnType: String?)
        case objectType(kind: PgObjectTypeDisplayKind)
        
        // Children of relations
        case column(typeName: String, notNull: Bool)
        case constraint(type: String, definition: String)
        case key(type: String)
        case trigger

        case language
        case role
        case tablespace
    }

    /// Stable id derived from the parent path so SwiftUI's diffing
    /// distinguishes `public.users` from `app.users`.
    let id: String
    let name: String
    let kind: Kind
    let owner: String?
    let estimatedRows: Float?
}

/// Fixed category buckets under a schema, in the order DataGrip
/// displays them. The tree always shows all six (with `(0)`
/// counts when empty) so the user has a stable mental layout.
enum PgCategoryKind: String, Hashable, Sendable, CaseIterable {
    case tables
    case views
    case materializedViews
    case sequences
    case routines
    case objectTypes

    var displayName: String {
        switch self {
        case .tables:             return "Tables"
        case .views:              return "Views"
        case .materializedViews:  return "Materialized Views"
        case .sequences:          return "Sequences"
        case .routines:           return "Routines"
        case .objectTypes:        return "Object Types"
        }
    }

    var sfSymbol: String {
        switch self {
        case .tables:             return "tablecells"
        case .views:              return "rectangle.stack"
        case .materializedViews:  return "rectangle.stack.fill"
        case .sequences:          return "number"
        case .routines:           return "function"
        case .objectTypes:        return "cube"
        }
    }
}

/// Routine display variant with its symbol. Mirrors
/// `FfiPgRoutineKind` but keeps the UI module independent of
/// uniffi types.
enum PgRoutineDisplayKind: String, Hashable, Sendable {
    case function
    case procedure
    case aggregate
    case window

    init(_ ffi: FfiPgRoutineKind) {
        switch ffi {
        case .function:  self = .function
        case .procedure: self = .procedure
        case .aggregate: self = .aggregate
        case .window:    self = .window
        }
    }

    var sfSymbol: String {
        switch self {
        case .function:  return "function"
        case .procedure: return "rectangle.dashed"
        case .aggregate: return "sum"
        case .window:    return "macwindow"
        }
    }
}

enum PgObjectTypeDisplayKind: String, Hashable, Sendable {
    case composite
    case `enum`
    case domain
    case range

    init(_ ffi: FfiPgObjectTypeKind) {
        switch ffi {
        case .composite: self = .composite
        case .enum:      self = .enum
        case .domain:    self = .domain
        case .range:     self = .range
        }
    }

    var sfSymbol: String {
        switch self {
        case .composite: return "cube"
        case .enum:      return "list.bullet"
        case .domain:    return "scope"
        case .range:     return "arrow.left.and.right"
        }
    }
}

/// UI-shaped relation kind. Mirrors `FfiPgRelationKind` but the display
/// layer doesn't need to depend on the FFI module.
/// Schema-contents snapshot keyed back to (database, schema). The
/// tree builds child nodes for each category from this bundle.
struct PgSchemaContentsBundle: @unchecked Sendable {
    let database: String
    let schema: String
    let contents: FfiPgSchemaContents

    /// Tree-ready nodes for one category, keyed off the category
    /// kind. Empty arrays still surface the category header so the
    /// layout stays stable.
    func nodes(for category: PgCategoryKind) -> [PgSchemaNode] {
        switch category {
        case .tables:
            return contents.tables.map { rel in
                PgSchemaNode(
                    id: "rel:\(database).\(schema).\(rel.name)",
                    name: rel.name,
                    kind: .relation(kind: PgRelationDisplayKind(rel.kind)),
                    owner: rel.owner,
                    estimatedRows: rel.estimatedRows
                )
            }
        case .views:
            return contents.views.map { rel in
                PgSchemaNode(
                    id: "rel:\(database).\(schema).\(rel.name)",
                    name: rel.name,
                    kind: .relation(kind: PgRelationDisplayKind(rel.kind)),
                    owner: rel.owner,
                    estimatedRows: rel.estimatedRows
                )
            }
        case .materializedViews:
            return contents.materializedViews.map { rel in
                PgSchemaNode(
                    id: "rel:\(database).\(schema).\(rel.name)",
                    name: rel.name,
                    kind: .relation(kind: PgRelationDisplayKind(rel.kind)),
                    owner: rel.owner,
                    estimatedRows: rel.estimatedRows
                )
            }
        case .sequences:
            return contents.sequences.map { s in
                PgSchemaNode(
                    id: "seq:\(database).\(schema).\(s.name)",
                    name: s.name,
                    kind: .sequence,
                    owner: s.owner,
                    estimatedRows: nil
                )
            }
        case .routines:
            return contents.routines.map { r in
                PgSchemaNode(
                    // Routine identity needs the argument signature
                    // — Postgres allows overloading, so name alone
                    // isn't unique within a schema.
                    id: "fn:\(database).\(schema).\(r.name)\(r.argumentSignature)",
                    name: r.name,
                    kind: .routine(
                        kind: PgRoutineDisplayKind(r.kind),
                        signature: r.argumentSignature,
                        returnType: r.returnType
                    ),
                    owner: r.owner,
                    estimatedRows: nil
                )
            }
        case .objectTypes:
            return contents.objectTypes.map { t in
                PgSchemaNode(
                    id: "type:\(database).\(schema).\(t.name)",
                    name: t.name,
                    kind: .objectType(kind: PgObjectTypeDisplayKind(t.kind)),
                    owner: t.owner,
                    estimatedRows: nil
                )
            }
        }
    }

    func count(for category: PgCategoryKind) -> Int {
        switch category {
        case .tables:            return contents.tables.count
        case .views:             return contents.views.count
        case .materializedViews: return contents.materializedViews.count
        case .sequences:         return contents.sequences.count
        case .routines:          return contents.routines.count
        case .objectTypes:       return contents.objectTypes.count
        }
    }
}

enum PgRelationDisplayKind: String, Hashable, Sendable {
    case table
    case view
    case materializedView = "materialized_view"
    case partitionedTable = "partitioned_table"
    case foreignTable = "foreign_table"

    init(_ ffi: FfiPgRelationKind) {
        switch ffi {
        case .table:             self = .table
        case .view:              self = .view
        case .materializedView:  self = .materializedView
        case .partitionedTable:  self = .partitionedTable
        case .foreignTable:      self = .foreignTable
        }
    }

    var sfSymbol: String {
        switch self {
        case .table:             return "tablecells"
        case .view:              return "rectangle.stack"
        case .materializedView:  return "rectangle.stack.fill"
        case .partitionedTable:  return "square.split.bottomrightquarter"
        case .foreignTable:      return "rectangle.connected.to.line.below"
        }
    }
}

/// One installed extension, as reported by `pg_extension`.
struct PgExtensionInfo: Identifiable, Hashable, Sendable {
    let name: String
    let version: String
    var id: String { name }
}

/// Server-level facts shown in the connection details panel.
struct PgServerInfo: Sendable {
    /// Short version, e.g. "16.4" (`server_version` setting).
    let version: String
    let extensions: [PgExtensionInfo]
}

/// One FOREIGN KEY constraint, fully resolved to schema-qualified
/// tables and ordered column lists. Multi-column keys keep their
/// pg_constraint ordering so `fromColumns[i]` pairs with
/// `toColumns[i]`.
struct PgForeignKey: Hashable, Sendable {
    let constraintName: String
    /// The table that declares the constraint.
    let fromSchema: String
    let fromTable: String
    let fromColumns: [String]
    /// The table the constraint points at.
    let toSchema: String
    let toTable: String
    let toColumns: [String]
}

/// Both directions of FK involvement for one table: constraints the
/// table declares (outgoing) and constraints other tables declare
/// against it (incoming). A self-referencing FK appears in both.
struct PgTableForeignKeys: Sendable {
    let outgoing: [PgForeignKey]
    let incoming: [PgForeignKey]

    var isEmpty: Bool { outgoing.isEmpty && incoming.isEmpty }
}

/// Parser for the one-row-per-column FK catalog query in
/// `PgSchemaStore.loadForeignKeys`. Kept off the store so unit tests
/// can exercise it without a connection.
enum PgForeignKeyParser {
    /// Expected cell layout per row:
    /// `[conname, from_schema, from_table, from_column,
    ///   to_schema, to_table, to_column, is_outgoing, is_incoming]`
    /// where the two flags arrive as Postgres boolean text ("t"/"f").
    /// Rows must be ordered by constraint then key position — the
    /// query's `ORDER BY c.oid, k.ord` guarantees this, and the
    /// parser folds consecutive rows of the same constraint into one
    /// `PgForeignKey` with ordered column lists.
    static func parse(rows: [[String?]]) -> PgTableForeignKeys {
        var outgoing: [PgForeignKey] = []
        var incoming: [PgForeignKey] = []
        // (constraint, from, to) uniquely identifies a constraint —
        // names are only unique per declaring table.
        var lastKey: [String]? = nil
        var pending: (fk: PgForeignKey, isOutgoing: Bool, isIncoming: Bool)?

        func flush() {
            guard let p = pending else { return }
            if p.isOutgoing { outgoing.append(p.fk) }
            if p.isIncoming { incoming.append(p.fk) }
            pending = nil
        }

        for cells in rows {
            guard cells.count >= 9,
                  let conname = cells[0],
                  let fromSchema = cells[1],
                  let fromTable = cells[2],
                  let fromColumn = cells[3],
                  let toSchema = cells[4],
                  let toTable = cells[5],
                  let toColumn = cells[6]
            else { continue }
            let key = [conname, fromSchema, fromTable, toSchema, toTable]
            if key == lastKey, let p = pending {
                pending = (
                    PgForeignKey(
                        constraintName: conname,
                        fromSchema: fromSchema,
                        fromTable: fromTable,
                        fromColumns: p.fk.fromColumns + [fromColumn],
                        toSchema: toSchema,
                        toTable: toTable,
                        toColumns: p.fk.toColumns + [toColumn]
                    ),
                    p.isOutgoing,
                    p.isIncoming
                )
            } else {
                flush()
                lastKey = key
                pending = (
                    PgForeignKey(
                        constraintName: conname,
                        fromSchema: fromSchema,
                        fromTable: fromTable,
                        fromColumns: [fromColumn],
                        toSchema: toSchema,
                        toTable: toTable,
                        toColumns: [toColumn]
                    ),
                    cells[7] == "t",
                    cells[8] == "t"
                )
            }
        }
        flush()
        return PgTableForeignKeys(outgoing: outgoing, incoming: incoming)
    }
}

@MainActor
final class PgSchemaStore: ObservableObject {
    private let logger = Logger(subsystem: "com.mc-ssh", category: "pg-schema-store")

    /// The connection this store is bound to. Held for the store's
    /// lifetime — switching connections means a new store.
    let connectionId: String

    /// Top-level databases. Loaded once at the first refresh.
    @Published private(set) var databasesState: PgLoadState<[PgSchemaNode]> = .idle

    /// Schemas per database name.
    @Published private(set) var schemasState: [String: PgLoadState<[PgSchemaNode]>] = [:]

    /// Schema contents per `"<database>.<schema>"` composite key.
    /// Holds the six category arrays the tree groups by; loaded
    /// in one round-trip via `pgListSchemaContents`.
    @Published private(set) var schemaContentsState: [String: PgLoadState<PgSchemaContentsBundle>] = [:]

    /// Columns per `"<database>.<schema>.<table_name>"` composite key.
    @Published private(set) var columnsState: [String: PgLoadState<[PgSchemaNode]>] = [:]

    /// Constraints, keys, and triggers per `"<database>.<schema>.<table_name>"` composite key.
    @Published private(set) var metaState: [String: PgLoadState<[PgSchemaNode]>] = [:]

    /// Resolved FK constraints (both directions) per
    /// `"<database>.<schema>.<table_name>"` composite key. Backs the
    /// result grid's "Go to referenced row" navigation.
    @Published private(set) var foreignKeysState: [String: PgLoadState<PgTableForeignKeys>] = [:]

    /// Languages per database name
    @Published private(set) var languagesState: [String: PgLoadState<[PgSchemaNode]>] = [:]

    /// Login/Group roles
    @Published private(set) var rolesState: PgLoadState<[PgSchemaNode]> = .idle

    /// Tablespaces
    @Published private(set) var tablespacesState: PgLoadState<[PgSchemaNode]> = .idle

    /// Server version + installed extensions for the details panel.
    @Published private(set) var serverInfoState: PgLoadState<PgServerInfo> = .idle

    /// Whether to surface system schemas (`pg_catalog`, `information_schema`).
    /// Off by default — the noise outweighs the value for an explorer.
    @Published var showSystemSchemas: Bool = false

    init(connectionId: String) {
        self.connectionId = connectionId
    }

    // The old flat `completionIdentifiers` list was replaced by the
    // structured snapshot in `completionCatalog(database:)` — see
    // SQLCompletionCatalog.swift.

    // MARK: - Loaders

    func loadDatabases() async {
        databasesState = .loading
        do {
            let dbs = try await BridgeManager.shared.pgListDatabases(connectionId: connectionId)
            let nodes = dbs.map { db in
                PgSchemaNode(
                    id: "db:\(db.name)",
                    name: db.name,
                    kind: .database,
                    owner: db.owner,
                    estimatedRows: nil
                )
            }
            databasesState = .loaded(nodes)
        } catch {
            databasesState = .failed(error.localizedDescription)
        }
    }

    func loadSchemas(database: String) async {
        schemasState[database] = .loading
        do {
            // Pass the database explicitly so the core routes to a
            // side connection for non-default DBs. Without this,
            // expanding any database in the tree shows the connected
            // DB's schemas — Postgres connections are bound to one
            // database at startup.
            let schemas = try await BridgeManager.shared.pgListSchemas(
                connectionId: connectionId,
                database: database
            )
            let filtered = showSystemSchemas ? schemas : schemas.filter { !$0.isSystem }
            let nodes = filtered.map { s in
                PgSchemaNode(
                    id: "schema:\(database).\(s.name)",
                    name: s.name,
                    kind: .schema(isSystem: s.isSystem),
                    owner: s.owner,
                    estimatedRows: nil
                )
            }
            schemasState[database] = .loaded(nodes)
        } catch {
            schemasState[database] = .failed(error.localizedDescription)
        }
    }

    /// Load the six schema-contents categories in one round-trip.
    /// The tree groups them as fixed-position child nodes under the
    /// schema (Tables, Views, Materialized Views, Sequences,
    /// Routines, Object Types).
    func loadSchemaContents(database: String, schema: String) async {
        let key = relationKey(database: database, schema: schema)
        schemaContentsState[key] = .loading
        do {
            let contents = try await BridgeManager.shared.pgListSchemaContents(
                connectionId: connectionId,
                schema: schema,
                database: database
            )
            schemaContentsState[key] = .loaded(
                PgSchemaContentsBundle(database: database, schema: schema, contents: contents)
            )
        } catch {
            schemaContentsState[key] = .failed(error.localizedDescription)
        }
    }

    func loadColumns(database: String, schema: String, table: String) async {
        let key = "\(database).\(schema).\(table)"
        columnsState[key] = .loading
        do {
            let cols = try await BridgeManager.shared.pgDescribeColumns(
                connectionId: connectionId,
                schema: schema,
                table: table
            )
            let nodes = cols.map { col in
                PgSchemaNode(
                    id: "col:\(database).\(schema).\(table).\(col.name)",
                    name: col.name,
                    kind: .column(typeName: col.typeName, notNull: col.notNull),
                    owner: nil,
                    estimatedRows: nil
                )
            }
            columnsState[key] = .loaded(nodes)
        } catch {
            columnsState[key] = .failed(error.localizedDescription)
        }
    }

    func loadMeta(database: String, schema: String, table: String) async {
        let key = "\(database).\(schema).\(table)"
        metaState[key] = .loading
        let sessionId = "meta-loader-\(UUID().uuidString)"
        let connId = connectionId
        do {
            // Resolve the table to its OID once via to_regclass on the safely
            // quoted, schema-qualified identifier, then anchor both catalog
            // queries on that OID. This is injection-safe (the identifier is
            // quoted, not string-matched into a WHERE clause) and also resolves
            // mixed-case / reserved-word object names correctly.
            let regclassArg = pgQuoteLiteral(pgQuoteIdent(schema) + "." + pgQuoteIdent(table))

            // 1. Fetch constraints and keys
            let constraintSql = """
            SELECT conname, pg_get_constraintdef(c.oid), contype
            FROM pg_constraint c
            WHERE c.conrelid = to_regclass(\(regclassArg));
            """

            // 2. Fetch triggers
            let triggerSql = """
            SELECT tgname, pg_get_triggerdef(t.oid)
            FROM pg_trigger t
            WHERE t.tgrelid = to_regclass(\(regclassArg))
              AND NOT tgisinternal;
            """

            var nodes: [PgSchemaNode] = []

            // Execute constraints query
            do {
                let res = try await BridgeManager.shared.pgExecute(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    sql: constraintSql,
                    pageSize: 100
                )
                for row in res.rows {
                    if row.cells.count >= 3,
                       let name = row.cells[0],
                       let def = row.cells[1],
                       let type = row.cells[2] {
                        if type == "p" || type == "f" || type == "u" {
                            nodes.append(PgSchemaNode(
                                id: "key:\(database).\(schema).\(table).\(name)",
                                name: "\(name) (\(def))",
                                kind: .key(type: type),
                                owner: nil,
                                estimatedRows: nil
                            ))
                        } else {
                            nodes.append(PgSchemaNode(
                                id: "const:\(database).\(schema).\(table).\(name)",
                                name: "\(name) (\(def))",
                                kind: .constraint(type: type, definition: def),
                                owner: nil,
                                estimatedRows: nil
                            ))
                        }
                    }
                }
            } catch {
                // Keep the metadata pane usable without constraints, but
                // leave a trace — a permission-denied on pg_constraint is
                // otherwise undiagnosable.
                logger.warning("constraint introspection failed for \(schema, privacy: .public).\(table, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            // Execute triggers query
            do {
                let res = try await BridgeManager.shared.pgExecute(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    sql: triggerSql,
                    pageSize: 100
                )
                for row in res.rows {
                    if row.cells.count >= 1,
                       let name = row.cells[0] {
                        nodes.append(PgSchemaNode(
                            id: "trig:\(database).\(schema).\(table).\(name)",
                            name: name,
                            kind: .trigger,
                            owner: nil,
                            estimatedRows: nil
                        ))
                    }
                }
            } catch {
                // Same defensive posture as constraints above: don't fail
                // the pane, but record why triggers are missing.
                logger.warning("trigger introspection failed for \(schema, privacy: .public).\(table, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            metaState[key] = .loaded(nodes)
        } catch {
            metaState[key] = .failed(error.localizedDescription)
        }
        // Release the lease within this structured context — awaited on both
        // the success and failure paths — rather than via `defer { Task { … } }`,
        // whose unstructured task could race the next loader or be dropped.
        await BridgeManager.shared.pgReleaseSession(connectionId: connId, sessionId: sessionId)
    }

    /// Load FK constraints touching `schema.table` — both those the
    /// table declares and those declared against it. Returns the
    /// cached value when already loaded (FK topology changes rarely;
    /// `invalidate(database:schema:)` callers drop it with the rest).
    /// Returns `nil` on failure — navigation simply doesn't light up.
    @discardableResult
    func loadForeignKeys(database: String, schema: String, table: String) async -> PgTableForeignKeys? {
        let key = "\(database).\(schema).\(table)"
        switch foreignKeysState[key] ?? .idle {
        case .loaded(let cached):
            return cached
        case .loading:
            // Another tab's load is in flight — the `await` below
            // suspends off the main actor, so re-entry is real. Let
            // the first request win rather than firing a duplicate.
            return nil
        default:
            break
        }
        foreignKeysState[key] = .loading
        let sessionId = "fk-loader-\(UUID().uuidString)"
        let connId = connectionId
        // Same injection-safe anchoring as `loadMeta`: resolve the
        // quoted identifier to an OID once, then filter on it.
        let regclassArg = pgQuoteLiteral(pgQuoteIdent(schema) + "." + pgQuoteIdent(table))
        // One row per key column; the parser folds multi-column keys
        // back together. Avoids parsing `{a,b}` array literals (which
        // would break on identifiers containing commas or quotes).
        // LIMIT matches `pageSize` below so the cap is explicit in
        // SQL — past it (a pathological FK count) extra constraints
        // silently don't get menu items, which is acceptable for a
        // navigation affordance.
        let sql = """
        SELECT
          c.conname,
          fn.nspname, fc.relname, fa.attname,
          tn.nspname, tc.relname, ta.attname,
          (c.conrelid  = to_regclass(\(regclassArg))),
          (c.confrelid = to_regclass(\(regclassArg)))
        FROM pg_constraint c
        CROSS JOIN LATERAL unnest(c.conkey, c.confkey)
          WITH ORDINALITY AS k(con_attnum, conf_attnum, ord)
        JOIN pg_class fc      ON fc.oid = c.conrelid
        JOIN pg_namespace fn  ON fn.oid = fc.relnamespace
        JOIN pg_attribute fa  ON fa.attrelid = c.conrelid  AND fa.attnum = k.con_attnum
        JOIN pg_class tc      ON tc.oid = c.confrelid
        JOIN pg_namespace tn  ON tn.oid = tc.relnamespace
        JOIN pg_attribute ta  ON ta.attrelid = c.confrelid AND ta.attnum = k.conf_attnum
        WHERE c.contype = 'f'
          AND (c.conrelid = to_regclass(\(regclassArg))
               OR c.confrelid = to_regclass(\(regclassArg)))
        ORDER BY c.oid, k.ord
        LIMIT 1000;
        """
        var loaded: PgTableForeignKeys?
        do {
            let res = try await BridgeManager.shared.pgExecute(
                connectionId: connId,
                sessionId: sessionId,
                sql: sql,
                pageSize: 1000
            )
            let fks = PgForeignKeyParser.parse(rows: res.rows.map { $0.cells })
            foreignKeysState[key] = .loaded(fks)
            loaded = fks
        } catch {
            foreignKeysState[key] = .failed(error.localizedDescription)
        }
        await BridgeManager.shared.pgReleaseSession(connectionId: connId, sessionId: sessionId)
        return loaded
    }

    func loadLanguages(database: String) async {
        languagesState[database] = .loading
        let sessionId = "languages-loader-\(UUID().uuidString)"
        let connId = connectionId
        do {
            let sql = "SELECT lanname FROM pg_language ORDER BY lanname;"
            let res = try await BridgeManager.shared.pgExecute(
                connectionId: connId,
                sessionId: sessionId,
                sql: sql,
                pageSize: 100
            )
            let nodes = res.rows.compactMap { row -> PgSchemaNode? in
                guard let name = row.cells.first ?? nil else { return nil }
                return PgSchemaNode(
                    id: "lang:\(database).\(name)",
                    name: name,
                    kind: .language,
                    owner: nil,
                    estimatedRows: nil
                )
            }
            languagesState[database] = .loaded(nodes)
        } catch {
            languagesState[database] = .failed(error.localizedDescription)
        }
        await BridgeManager.shared.pgReleaseSession(connectionId: connId, sessionId: sessionId)
    }

    func loadRoles() async {
        rolesState = .loading
        let sessionId = "roles-loader-\(UUID().uuidString)"
        let connId = connectionId
        do {
            let sql = "SELECT rolname FROM pg_roles ORDER BY rolname;"
            let res = try await BridgeManager.shared.pgExecute(
                connectionId: connId,
                sessionId: sessionId,
                sql: sql,
                pageSize: 200
            )
            let nodes = res.rows.compactMap { row -> PgSchemaNode? in
                guard let name = row.cells.first ?? nil else { return nil }
                return PgSchemaNode(
                    id: "role:\(name)",
                    name: name,
                    kind: .role,
                    owner: nil,
                    estimatedRows: nil
                )
            }
            rolesState = .loaded(nodes)
        } catch {
            rolesState = .failed(error.localizedDescription)
        }
        await BridgeManager.shared.pgReleaseSession(connectionId: connId, sessionId: sessionId)
    }

    func loadTablespaces() async {
        tablespacesState = .loading
        let sessionId = "tablespaces-loader-\(UUID().uuidString)"
        let connId = connectionId
        do {
            let sql = "SELECT spcname FROM pg_tablespace ORDER BY spcname;"
            let res = try await BridgeManager.shared.pgExecute(
                connectionId: connId,
                sessionId: sessionId,
                sql: sql,
                pageSize: 100
            )
            let nodes = res.rows.compactMap { row -> PgSchemaNode? in
                guard let name = row.cells.first ?? nil else { return nil }
                return PgSchemaNode(
                    id: "tspace:\(name)",
                    name: name,
                    kind: .tablespace,
                    owner: nil,
                    estimatedRows: nil
                )
            }
            tablespacesState = .loaded(nodes)
        } catch {
            tablespacesState = .failed(error.localizedDescription)
        }
        await BridgeManager.shared.pgReleaseSession(connectionId: connId, sessionId: sessionId)
    }

    /// Fetch the server version and installed extensions in one
    /// session lease. Loaded lazily by the details panel; cached for
    /// the store's lifetime (a new connection means a new store).
    func loadServerInfo() async {
        serverInfoState = .loading
        let sessionId = "server-info-loader-\(UUID().uuidString)"
        let connId = connectionId
        do {
            let versionRes = try await BridgeManager.shared.pgExecute(
                connectionId: connId,
                sessionId: sessionId,
                sql: "SELECT current_setting('server_version');",
                pageSize: 1
            )
            let version = (versionRes.rows.first?.cells.first ?? nil) ?? "unknown"

            let extRes = try await BridgeManager.shared.pgExecute(
                connectionId: connId,
                sessionId: sessionId,
                sql: "SELECT extname, extversion FROM pg_extension ORDER BY extname;",
                pageSize: 500
            )
            let extensions = extRes.rows.compactMap { row -> PgExtensionInfo? in
                guard row.cells.count >= 2, let name = row.cells[0] else { return nil }
                return PgExtensionInfo(name: name, version: row.cells[1] ?? "?")
            }
            serverInfoState = .loaded(PgServerInfo(version: version, extensions: extensions))
        } catch {
            serverInfoState = .failed(error.localizedDescription)
        }
        await BridgeManager.shared.pgReleaseSession(connectionId: connId, sessionId: sessionId)
    }

    func findNode(byId id: String) -> PgSchemaNode? {
        // 1. Check databases
        if case .loaded(let dbs) = databasesState {
            if let db = dbs.first(where: { $0.id == id }) { return db }
        }
        // 2. Check schemas
        for state in schemasState.values {
            if case .loaded(let schemas) = state {
                if let s = schemas.first(where: { $0.id == id }) { return s }
            }
        }
        // 3. Check schema contents
        for state in schemaContentsState.values {
            if case .loaded(let bundle) = state {
                for cat in PgCategoryKind.allCases {
                    let nodes = bundle.nodes(for: cat)
                    if let n = nodes.first(where: { $0.id == id }) { return n }
                }
            }
        }
        // 4. Check columns
        for state in columnsState.values {
            if case .loaded(let cols) = state {
                if let c = cols.first(where: { $0.id == id }) { return c }
            }
        }
        // 5. Check metadata
        for state in metaState.values {
            if case .loaded(let metas) = state {
                if let m = metas.first(where: { $0.id == id }) { return m }
            }
        }
        // 6. Check languages
        for state in languagesState.values {
            if case .loaded(let langs) = state {
                if let l = langs.first(where: { $0.id == id }) { return l }
            }
        }
        // 7. Check roles
        if case .loaded(let roles) = rolesState {
            if let r = roles.first(where: { $0.id == id }) { return r }
        }
        // 8. Check tablespaces
        if case .loaded(let tspaces) = tablespacesState {
            if let t = tspaces.first(where: { $0.id == id }) { return t }
        }
        return nil
    }

    /// Drop cached children for one schema. Used by the "Refresh" menu
    /// item without invalidating the entire database tree.
    func invalidate(database: String, schema: String) {
        schemaContentsState[relationKey(database: database, schema: schema)] = nil
        let prefix = "\(database).\(schema)."
        foreignKeysState = foreignKeysState.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Drop cached children for one database, including all of its
    /// schemas' contents.
    func invalidate(database: String) {
        schemasState[database] = nil
        let prefix = "\(database)."
        schemaContentsState = schemaContentsState.filter { !$0.key.hasPrefix(prefix) }
        foreignKeysState = foreignKeysState.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - Private

    private func relationKey(database: String, schema: String) -> String {
        "\(database).\(schema)"
    }
}
