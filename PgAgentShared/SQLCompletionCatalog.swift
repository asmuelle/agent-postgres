import Foundation

// =============================================================================
// SQLCompletionCatalog — an immutable snapshot of the schema metadata the
// completion engine ranks against. Built from whatever PgSchemaStore has
// already lazily loaded; the engine itself never triggers catalog loads.
// =============================================================================

struct SQLCompletionCatalog: Equatable, Sendable {
    struct Relation: Equatable, Sendable, Hashable {
        let schema: String
        let name: String
        /// `true` for views and materialized views; tables/partitioned/foreign
        /// tables are `false`. Only affects presentation, not ranking.
        let isView: Bool
        /// Column names, empty when the store hasn't loaded them yet.
        let columns: [String]
    }

    /// Schema names of the active database (system schemas excluded unless
    /// the browser was told to show them).
    var schemas: [String]
    /// All loaded tables + views + materialized views across schemas.
    var relations: [Relation]
    /// Schemas whose relations complete unqualified and rank first.
    /// Currently just `public` — the app connects without a custom
    /// search_path, so this mirrors what the server resolves bare names to.
    var searchPath: [String]

    init(
        schemas: [String] = [],
        relations: [Relation] = [],
        searchPath: [String] = ["public"]
    ) {
        self.schemas = schemas
        self.relations = relations
        self.searchPath = searchPath
    }

    static let empty = SQLCompletionCatalog()

    func isInSearchPath(_ schema: String) -> Bool {
        searchPath.contains { $0.caseInsensitiveCompare(schema) == .orderedSame }
    }

    /// Relations named `name` (case-insensitive), search-path schemas first
    /// so `users.` prefers `public.users` over `audit.users`.
    func relations(named name: String) -> [Relation] {
        relations
            .filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            .sorted { a, b in
                let ap = isInSearchPath(a.schema) ? 0 : 1
                let bp = isInSearchPath(b.schema) ? 0 : 1
                if ap != bp { return ap < bp }
                return a.schema < b.schema
            }
    }

    func relation(schema: String, name: String) -> Relation? {
        relations.first {
            $0.schema.caseInsensitiveCompare(schema) == .orderedSame
                && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }
}

// MARK: - Building from the schema store

extension PgSchemaStore {
    /// Snapshot the already-loaded browser metadata for `database` into a
    /// completion catalog. Pure read — never triggers loads, so completion
    /// quality grows as the user browses.
    func completionCatalog(database: String) -> SQLCompletionCatalog {
        var schemas: [String] = []
        if case .loaded(let nodes) = schemasState[database] {
            schemas = nodes.map(\.name)
        }

        var relations: [SQLCompletionCatalog.Relation] = []
        for state in schemaContentsState.values {
            guard case .loaded(let bundle) = state, bundle.database == database else { continue }
            for category in [PgCategoryKind.tables, .views, .materializedViews] {
                for node in bundle.nodes(for: category) {
                    let columnsKey = "\(database).\(bundle.schema).\(node.name)"
                    var columns: [String] = []
                    if case .loaded(let columnNodes) = columnsState[columnsKey] {
                        columns = columnNodes.map(\.name)
                    }
                    relations.append(
                        SQLCompletionCatalog.Relation(
                            schema: bundle.schema,
                            name: node.name,
                            isView: category != .tables,
                            columns: columns
                        )
                    )
                }
            }
        }
        return SQLCompletionCatalog(schemas: schemas, relations: relations)
    }

    /// Kick off a column load for `schema.table` unless one already ran or
    /// is running. Called by the editor when the completion engine reports a
    /// statement references a relation whose columns aren't cached yet, so
    /// the *next* completion trigger has them.
    func requestColumnsIfIdle(database: String, schema: String, table: String) {
        let key = "\(database).\(schema).\(table)"
        switch columnsState[key] ?? .idle {
        case .idle:
            Task { await self.loadColumns(database: database, schema: schema, table: table) }
        default:
            break
        }
    }
}
