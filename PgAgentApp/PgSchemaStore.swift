import Foundation
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

@MainActor
final class PgSchemaStore: ObservableObject {
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

    /// Identifier names currently known from loaded browser state — databases,
    /// schemas, tables/views/sequences/routines, and any expanded columns.
    /// Best-effort: only what the user has lazily loaded is present, so the
    /// SQL editor's completion grows richer as they browse. Computed on demand.
    var completionIdentifiers: [String] {
        var names = Set<String>()
        func collect(_ state: PgLoadState<[PgSchemaNode]>) {
            if case .loaded(let nodes) = state {
                for node in nodes { names.insert(node.name) }
            }
        }
        // Skip metaState: key/constraint node names embed their definition
        // ("pk (PRIMARY KEY (...))"), which is noise for completion.
        collect(databasesState)
        collect(rolesState)
        collect(tablespacesState)
        for state in schemasState.values { collect(state) }
        for state in columnsState.values { collect(state) }
        for state in languagesState.values { collect(state) }
        for state in schemaContentsState.values {
            if case .loaded(let bundle) = state {
                names.insert(bundle.schema)
                for category in PgCategoryKind.allCases {
                    for node in bundle.nodes(for: category) { names.insert(node.name) }
                }
            }
        }
        return Array(names)
    }

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
        do {
            // 1. Fetch constraints and keys
            let constraintSql = """
            SELECT conname, pg_get_constraintdef(c.oid), contype
            FROM pg_constraint c
            JOIN pg_namespace n ON n.oid = c.connamespace
            JOIN pg_class r ON r.oid = c.conrelid
            WHERE r.relname = '\(table.replacingOccurrences(of: "'", with: "''"))' 
              AND n.nspname = '\(schema.replacingOccurrences(of: "'", with: "''"))';
            """
            
            // 2. Fetch triggers
            let triggerSql = """
            SELECT tgname, pg_get_triggerdef(t.oid)
            FROM pg_trigger t
            JOIN pg_class r ON r.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = r.relnamespace
            WHERE r.relname = '\(table.replacingOccurrences(of: "'", with: "''"))' 
              AND n.nspname = '\(schema.replacingOccurrences(of: "'", with: "''"))' 
              AND NOT tgisinternal;
            """
            
            var nodes: [PgSchemaNode] = []
            let sessionId = "meta-loader-\(UUID().uuidString)"
            let connId = connectionId
            defer {
                Task {
                    await BridgeManager.shared.pgReleaseSession(connectionId: connId, sessionId: sessionId)
                }
            }
            
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
                // Ignore query failures defensively
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
                // Ignore query failures defensively
            }
            
            metaState[key] = .loaded(nodes)
        } catch {
            metaState[key] = .failed(error.localizedDescription)
        }
    }

    func loadLanguages(database: String) async {
        languagesState[database] = .loading
        do {
            let sql = "SELECT lanname FROM pg_language ORDER BY lanname;"
            let sessionId = "languages-loader-\(UUID().uuidString)"
            let connId = connectionId
            defer {
                Task {
                    await BridgeManager.shared.pgReleaseSession(connectionId: connId, sessionId: sessionId)
                }
            }
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
    }

    func loadRoles() async {
        rolesState = .loading
        do {
            let sql = "SELECT rolname FROM pg_roles ORDER BY rolname;"
            let sessionId = "roles-loader-\(UUID().uuidString)"
            let connId = connectionId
            defer {
                Task {
                    await BridgeManager.shared.pgReleaseSession(connectionId: connId, sessionId: sessionId)
                }
            }
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
    }

    func loadTablespaces() async {
        tablespacesState = .loading
        do {
            let sql = "SELECT spcname FROM pg_tablespace ORDER BY spcname;"
            let sessionId = "tablespaces-loader-\(UUID().uuidString)"
            let connId = connectionId
            defer {
                Task {
                    await BridgeManager.shared.pgReleaseSession(connectionId: connId, sessionId: sessionId)
                }
            }
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
    }

    /// Fetch the server version and installed extensions in one
    /// session lease. Loaded lazily by the details panel; cached for
    /// the store's lifetime (a new connection means a new store).
    func loadServerInfo() async {
        serverInfoState = .loading
        let sessionId = "server-info-loader-\(UUID().uuidString)"
        let connId = connectionId
        defer {
            Task {
                await BridgeManager.shared.pgReleaseSession(connectionId: connId, sessionId: sessionId)
            }
        }
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
    }

    /// Drop cached children for one database, including all of its
    /// schemas' contents.
    func invalidate(database: String) {
        schemasState[database] = nil
        let prefix = "\(database)."
        schemaContentsState = schemaContentsState.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - Private

    private func relationKey(database: String, schema: String) -> String {
        "\(database).\(schema)"
    }
}
