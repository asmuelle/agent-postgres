import Combine
import OSLog
import PgAgentMacOS
import SwiftUI

// =============================================================================
// PostgresBrowserView — schema tree for one connected Postgres profile.
//
// Sprint 1 surface: connect / disconnect button + lazy three-level tree
// (database → schema → relation). No query editor here — that's Sprint 3.
// The tree is read-only; right-click reveals "Refresh" only.
//
// Connection lifecycle is owned by this view: onAppear triggers connect,
// onDisappear triggers disconnect. A future tabbed home will lift this up
// to a session manager so tabs can survive view tear-down.
// =============================================================================

struct PostgresBrowserView: View {
    let profile: PostgresProfile
    /// Connection identity owned by this view but visible to the
    /// surrounding workspace via a binding. Workspace reads it to
    /// hand to query tabs; the browser still drives the lifecycle
    /// (connect on appear, disconnect on disappear).
    @Binding var connectionId: String?
    /// Selected node in the sidebar tree.
    @Binding var selectedNode: PgSchemaNode?
    /// Exposes the active schema store to the workspace
    @Binding var schemaStore: PgSchemaStore?
    
    /// Invoked when the user double-clicks a relation in the tree.
    /// Workspace handles this by opening a populated query tab.
    /// `nil` is fine for standalone usage — double-click becomes a
    /// no-op.
    var onOpenQuery: ((String, String) -> Void)? = nil
    var onOpenRoutine: ((String, String, String) -> Void)? = nil
    var onOpenSequence: ((String, String) -> Void)? = nil
    var onOpenObjectType: ((String, String, String) -> Void)? = nil
    var onOpenWizard: ((String) -> Void)? = nil
    var onOpenBackupRestore: (() -> Void)? = nil

    @State private var connectionError: String? = nil
    @State private var isConnecting: Bool = false
    @StateObject private var schemaStoreHolder = SchemaStoreHolder()
    @State private var expandedDatabases: Set<String> = []
    @State private var expandedSchemas: Set<String> = []  // "<database>.<schema>"
    @State private var expandedCategories: Set<String> = []  // "<database>.<schema>.<category>"
    @State private var expandedRelations: Set<String> = []  // "<database>.<schema>.<table_name>"
    @State private var selectedNodeId: String? = nil

    private let logger = Logger(subsystem: "com.mc-ssh", category: "postgres-browser")

    init(
        profile: PostgresProfile,
        connectionId: Binding<String?>,
        selectedNode: Binding<PgSchemaNode?>,
        schemaStore: Binding<PgSchemaStore?>,
        onOpenQuery: ((String, String) -> Void)? = nil,
        onOpenRoutine: ((String, String, String) -> Void)? = nil,
        onOpenSequence: ((String, String) -> Void)? = nil,
        onOpenObjectType: ((String, String, String) -> Void)? = nil,
        onOpenWizard: ((String) -> Void)? = nil,
        onOpenBackupRestore: (() -> Void)? = nil
    ) {
        self.profile = profile
        self._connectionId = connectionId
        self._selectedNode = selectedNode
        self._schemaStore = schemaStore
        self.onOpenQuery = onOpenQuery
        self.onOpenRoutine = onOpenRoutine
        self.onOpenSequence = onOpenSequence
        self.onOpenObjectType = onOpenObjectType
        self.onOpenWizard = onOpenWizard
        self.onOpenBackupRestore = onOpenBackupRestore
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 320, minHeight: 400)
        .task(id: profile.id) {
            await connectIfNeeded()
        }
        .onDisappear {
            Task { await disconnect() }
        }
        .onChange(of: selectedNodeId) { newValue in
            if let id = newValue {
                if let store = schemaStoreHolder.store, let found = store.findNode(byId: id) {
                    selectedNode = found
                }
            } else {
                if let current = selectedNode {
                    let isSubRow = current.id.hasPrefix("col:") || current.id.hasPrefix("key:") || current.id.hasPrefix("const:") || current.id.hasPrefix("trig:")
                    if !isSubRow {
                        selectedNode = nil
                    }
                } else {
                    selectedNode = nil
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.headline)
                Text("\(profile.user)@\(profile.host):\(profile.port)/\(profile.database)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge
            Button {
                Task { await refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(connectionId == nil)
            .help("Refresh schema cache")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isConnecting {
            ProgressView().controlSize(.small)
        } else if connectionId != nil {
            Label("Connected", systemImage: "circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .font(.caption)
        } else {
            Label("Disconnected", systemImage: "circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = connectionError {
            errorView(error)
        } else if let store = schemaStoreHolder.store {
            tree(store: store)
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        VStack(spacing: 10) {
            Image(systemName: "cylinder.split.1x2")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Connecting…").font(.headline)
            Text("Opening Postgres session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Connection failed").font(.headline)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
            Button("Retry") {
                Task { await connectIfNeeded(force: true) }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func tree(store: PgSchemaStore) -> some View {
        List(selection: $selectedNodeId) {
            switch store.databasesState {
            case .idle, .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading databases…")
                }
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            case .loaded(let databases):
                ForEach(databases) { db in
                    databaseRow(store: store, database: db)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Rows

    @ViewBuilder
    private func databaseRow(store: PgSchemaStore, database: PgSchemaNode) -> some View {
        let isExpanded = expandedDatabases.contains(database.name)
        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { expanded in
                    if expanded {
                        expandedDatabases.insert(database.name)
                        Task {
                            if store.schemasState[database.name] == nil
                                || store.schemasState[database.name]?.isLoaded == false
                            {
                                await store.loadSchemas(database: database.name)
                            }
                        }
                    } else {
                        expandedDatabases.remove(database.name)
                    }
                }
            )
        ) {
            schemasContent(store: store, database: database.name)
        } label: {
            Label(database.name, systemImage: "cylinder")
        }
        .tag(database.id)
        .contextMenu {
            if database.name == profile.database {
                Button {
                    onOpenBackupRestore?()
                } label: {
                    Label("Backup / Restore...", systemImage: "arrow.up.doc.fill.and.arrow.down.doc.fill")
                }
            }
        }
    }

    @ViewBuilder
    private func schemasContent(store: PgSchemaStore, database: String) -> some View {
        switch store.schemasState[database] ?? .idle {
        case .idle, .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading schemas…").font(.caption)
            }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
        case .loaded(let schemas):
            ForEach(schemas) { schema in
                schemaRow(store: store, database: database, schema: schema)
            }
        }
    }

    @ViewBuilder
    private func schemaRow(store: PgSchemaStore, database: String, schema: PgSchemaNode) -> some View {
        let key = "\(database).\(schema.name)"
        let isExpanded = expandedSchemas.contains(key)
        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { expanded in
                    if expanded {
                        expandedSchemas.insert(key)
                        Task {
                            if store.schemaContentsState[key] == nil
                                || store.schemaContentsState[key]?.isLoaded == false
                            {
                                await store.loadSchemaContents(
                                    database: database, schema: schema.name
                                )
                            }
                        }
                    } else {
                        expandedSchemas.remove(key)
                    }
                }
            )
        ) {
            schemaContentsView(store: store, database: database, schema: schema.name)
        } label: {
            HStack {
                Label(schema.name, systemImage: "folder")
                if case .schema(let isSystem) = schema.kind, isSystem {
                    Text("system")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tag(schema.id)
        .contextMenu {
            Button {
                onOpenWizard?(schema.name)
            } label: {
                Label("Create Object Wizard...", systemImage: "wand.and.stars")
            }
        }
    }

    /// The 6-category DataGrip-style child layout under a schema.
    /// All categories appear (with `(0)` count when empty) so the
    /// user has a stable mental model regardless of what's defined.
    @ViewBuilder
    private func schemaContentsView(
        store: PgSchemaStore,
        database: String,
        schema: String
    ) -> some View {
        let key = "\(database).\(schema)"
        switch store.schemaContentsState[key] ?? .idle {
        case .idle, .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption)
            }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
        case .loaded(let bundle):
            ForEach(PgCategoryKind.allCases, id: \.self) { category in
                if bundle.count(for: category) > 0 {
                    categoryRow(store: store, bundle: bundle, category: category)
                }
            }
        }
    }

    @ViewBuilder
    private func categoryRow(
        store: PgSchemaStore,
        bundle: PgSchemaContentsBundle,
        category: PgCategoryKind
    ) -> some View {
        let nodes = bundle.nodes(for: category)
        let count = bundle.count(for: category)
        let key = "\(bundle.database).\(bundle.schema).\(category.rawValue)"
        let isExpanded = expandedCategories.contains(key)
        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { expanded in
                    if expanded {
                        expandedCategories.insert(key)
                    } else {
                        expandedCategories.remove(key)
                    }
                }
            )
        ) {
            if nodes.isEmpty {
                Text("(empty)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            } else {
                ForEach(nodes) { node in
                    contentNodeRow(node, database: bundle.database, schema: bundle.schema, store: store)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Label(category.displayName, systemImage: category.sfSymbol)
                Text("(\(count))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    /// Dispatch on node kind to render the right row for each item
    /// inside a category. Tables/views/matviews keep their existing
    /// row treatment (which carries the cross-database alert and
    /// double-click-to-query semantics); sequences / routines /
    /// object types render simpler icon+name+caption rows.
    @ViewBuilder
    private func contentNodeRow(_ node: PgSchemaNode, database: String, schema: String, store: PgSchemaStore) -> some View {
        switch node.kind {
        case .relation:
            relationRow(store: store, database: database, schema: schema, rel: node)
        case .sequence:
            let parsed = parseSequenceId(node.id)
            let isConnectedDb = parsed?.database == profile.database
            HStack {
                Label(node.name, systemImage: "number")
                    .foregroundStyle(isConnectedDb ? .primary : .secondary)
                Spacer()
            }
            .tag(node.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard let parsed else { return }
                if isConnectedDb {
                    onOpenSequence?(parsed.schema, parsed.name)
                } else {
                    presentForeignDatabaseAlert(database: parsed.database)
                }
            }
            .help(isConnectedDb ? "Double-click to view sequence properties" : "Database '\(parsed?.database ?? "?")' isn't connected through this profile.")
        case .routine(let rkind, let signature, let returnType):
            let parsed = parseRoutineId(node.id)
            let isConnectedDb = parsed?.database == profile.database
            HStack(spacing: 6) {
                Label(node.name, systemImage: rkind.sfSymbol)
                    .foregroundStyle(isConnectedDb ? .primary : .secondary)
                Text(signature)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if let ret = returnType, !ret.isEmpty {
                    Text("→ \(ret)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .tag(node.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard let parsed else { return }
                if isConnectedDb {
                    onOpenRoutine?(parsed.schema, parsed.name, signature)
                } else {
                    presentForeignDatabaseAlert(database: parsed.database)
                }
            }
            .help(isConnectedDb ? "Double-click to view function definition" : "Database '\(parsed?.database ?? "?")' isn't connected through this profile.")
        case .objectType(let kind):
            let parsed = parseObjectTypeId(node.id)
            let isConnectedDb = parsed?.database == profile.database
            HStack(spacing: 6) {
                Label(node.name, systemImage: kind.sfSymbol)
                    .foregroundStyle(isConnectedDb ? .primary : .secondary)
                Text(kind.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .tag(node.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard let parsed else { return }
                if isConnectedDb {
                    onOpenObjectType?(parsed.schema, parsed.name, kind.rawValue)
                } else {
                    presentForeignDatabaseAlert(database: parsed.database)
                }
            }
            .help(isConnectedDb ? "Double-click to view custom type details" : "Database '\(parsed?.database ?? "?")' isn't connected through this profile.")
        case .database, .schema, .category, .column, .constraint, .key, .trigger, .language, .role, .tablespace:
            // Shouldn't appear at this level; ignore defensively.
            EmptyView()
        }
    }

    @ViewBuilder
    private func relationRow(store: PgSchemaStore, database: String, schema: String, rel: PgSchemaNode) -> some View {
        let key = "\(database).\(schema).\(rel.name)"
        let isExpanded = expandedRelations.contains(key)
        let symbol: String = {
            if case .relation(let kind) = rel.kind { return kind.sfSymbol }
            return "tablecells"
        }()
        let parsed = parseRelationId(rel.id)
        let isConnectedDb = parsed?.database == profile.database
        
        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { expanded in
                    if expanded {
                        expandedRelations.insert(key)
                        Task {
                            if store.columnsState[key] == nil || store.columnsState[key]?.isLoaded == false {
                                await store.loadColumns(database: database, schema: schema, table: rel.name)
                            }
                            if store.metaState[key] == nil || store.metaState[key]?.isLoaded == false {
                                await store.loadMeta(database: database, schema: schema, table: rel.name)
                            }
                        }
                    } else {
                        expandedRelations.remove(key)
                    }
                }
            )
        ) {
            relationChildrenView(store: store, database: database, schema: schema, table: rel.name)
                .padding(.leading, 12)
        } label: {
            HStack {
                Label(rel.name, systemImage: symbol)
                    // Dim relations in non-connected databases — the
                    // tree shows them for awareness, but query tabs
                    // can't target them through this profile.
                    .foregroundStyle(isConnectedDb ? .primary : .secondary)
                Spacer()
                if let rows = rel.estimatedRows, rows >= 0 {
                    Text(formatRowCount(rows))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tag(rel.id)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard let parsed = parsed else { return }
            if isConnectedDb {
                onOpenQuery?(parsed.schema, parsed.name)
            } else {
                presentForeignDatabaseAlert(database: parsed.database)
            }
        }
        .help(isConnectedDb
              ? "Double-click to open a query tab"
              : "Database '\(parsed?.database ?? "?")' isn't connected through this profile.")
    }

    @ViewBuilder
    private func relationChildrenView(
        store: PgSchemaStore,
        database: String,
        schema: String,
        table: String
    ) -> some View {
        let key = "\(database).\(schema).\(table)"
        
        DisclosureGroup("Columns") {
            switch store.columnsState[key] ?? .idle {
            case .idle, .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading...").font(.caption2)
                }
            case .failed(let err):
                Text("Error: \(err)").foregroundStyle(.red).font(.caption2)
            case .loaded(let cols):
                if cols.isEmpty {
                    Text("(no columns)").font(.caption2).foregroundStyle(.secondary)
                } else {
                    ForEach(cols) { col in
                        let isSelected = selectedNode?.id == col.id
                        HStack {
                            Label(col.name, systemImage: "list.bullet")
                            if case .column(let typeName, let notNull) = col.kind {
                                Text(typeName)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                if notNull {
                                    Text("not null")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedNodeId = nil
                            selectedNode = col
                        }
                    }
                }
            }
        }
        .font(.caption)
        
        switch store.metaState[key] ?? .idle {
        case .idle, .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading metadata...").font(.caption2)
            }
        case .failed(let err):
            Text("Error: \(err)").foregroundStyle(.red).font(.caption2)
        case .loaded(let metaNodes):
            let keys = metaNodes.filter { if case .key = $0.kind { return true }; return false }
            let constraints = metaNodes.filter { if case .constraint = $0.kind { return true }; return false }
            let triggers = metaNodes.filter { if case .trigger = $0.kind { return true }; return false }
            
            if !keys.isEmpty {
                DisclosureGroup("Keys (\(keys.count))") {
                    ForEach(keys) { keyNode in
                        let isSelected = selectedNode?.id == keyNode.id
                        HStack {
                            Label(keyNode.name, systemImage: "key.fill")
                                .foregroundStyle(.yellow)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedNodeId = nil
                            selectedNode = keyNode
                        }
                    }
                }
                .font(.caption)
            }
            
            if !constraints.isEmpty {
                DisclosureGroup("Constraints (\(constraints.count))") {
                    ForEach(constraints) { constNode in
                        let isSelected = selectedNode?.id == constNode.id
                        HStack {
                            Label(constNode.name, systemImage: "lock.shield")
                                .foregroundStyle(.orange)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedNodeId = nil
                            selectedNode = constNode
                        }
                    }
                }
                .font(.caption)
            }
            
            if !triggers.isEmpty {
                DisclosureGroup("Triggers (\(triggers.count))") {
                    ForEach(triggers) { trigNode in
                        let isSelected = selectedNode?.id == trigNode.id
                        HStack {
                            Label(trigNode.name, systemImage: "bolt.fill")
                                .foregroundStyle(.cyan)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedNodeId = nil
                            selectedNode = trigNode
                        }
                    }
                }
                .font(.caption)
            }
        }
    }

    /// Parse a relation node id of the form `rel:<db>.<schema>.<name>`
    /// into its three components. Database name is taken as
    /// everything up to the first `.`; schema is everything between
    /// the first and last `.`; name is the tail. Robust against
    /// names with dots (rare in practice, allowed via quoted
    /// identifiers) only when the database name itself contains
    /// none — good enough for v1.
    private func parseRelationId(_ id: String) -> (database: String, schema: String, name: String)? {
        let prefix = "rel:"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        guard let firstDot = rest.firstIndex(of: ".") else { return nil }
        let database = String(rest[rest.startIndex..<firstDot])
        let afterDb = String(rest[rest.index(after: firstDot)...])
        guard let lastDot = afterDb.lastIndex(of: ".") else { return nil }
        let schema = String(afterDb[afterDb.startIndex..<lastDot])
        let name = String(afterDb[afterDb.index(after: lastDot)...])
        return (database, schema, name)
    }

    private func parseSequenceId(_ id: String) -> (database: String, schema: String, name: String)? {
        let prefix = "seq:"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        guard let firstDot = rest.firstIndex(of: ".") else { return nil }
        let database = String(rest[rest.startIndex..<firstDot])
        let afterDb = String(rest[rest.index(after: firstDot)...])
        guard let lastDot = afterDb.lastIndex(of: ".") else { return nil }
        let schema = String(afterDb[afterDb.startIndex..<lastDot])
        let name = String(afterDb[afterDb.index(after: lastDot)...])
        return (database, schema, name)
    }

    private func parseRoutineId(_ id: String) -> (database: String, schema: String, name: String)? {
        let prefix = "fn:"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        guard let firstDot = rest.firstIndex(of: ".") else { return nil }
        let database = String(rest[rest.startIndex..<firstDot])
        let afterDb = String(rest[rest.index(after: firstDot)...])
        guard let parenStart = afterDb.firstIndex(of: "(") else { return nil }
        let nameAndSchema = String(afterDb[afterDb.startIndex..<parenStart])
        guard let lastDot = nameAndSchema.lastIndex(of: ".") else { return nil }
        let schema = String(nameAndSchema[nameAndSchema.startIndex..<lastDot])
        let name = String(nameAndSchema[nameAndSchema.index(after: lastDot)...])
        return (database, schema, name)
    }

    private func parseObjectTypeId(_ id: String) -> (database: String, schema: String, name: String)? {
        let prefix = "type:"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        guard let firstDot = rest.firstIndex(of: ".") else { return nil }
        let database = String(rest[rest.startIndex..<firstDot])
        let afterDb = String(rest[rest.index(after: firstDot)...])
        guard let lastDot = afterDb.lastIndex(of: ".") else { return nil }
        let schema = String(afterDb[afterDb.startIndex..<lastDot])
        let name = String(afterDb[afterDb.index(after: lastDot)...])
        return (database, schema, name)
    }

    /// Surface a polite "wrong database" hint when the user
    /// double-clicks a relation in a non-connected database.
    /// Connecting to a different DB requires either editing the
    /// profile or creating a new one — Postgres connections are
    /// bound at startup and can't be re-routed mid-session.
    private func presentForeignDatabaseAlert(database: String) {
        let alert = NSAlert()
        alert.messageText = "“\(database)” isn't connected"
        alert.informativeText = "This profile is connected to “\(profile.database)”. To open a query tab against “\(database)”, edit the profile (or create a new one) with that database selected."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Lifecycle

    private func connectIfNeeded(force: Bool = false) async {
        if !force && (connectionId != nil || isConnecting) { return }
        isConnecting = true
        connectionError = nil
        // Mark connecting up-front so the sidebar's dot turns yellow
        // while the handshake's in flight. Cleared on success / error.
        PostgresConnectionStatusStore.shared.markConnecting(profileId: profile.id)
        defer { isConnecting = false }
        do {
            let id = try await BridgeManager.shared.pgConnect(profile: profile)
            connectionId = id
            let store = PgSchemaStore(connectionId: id)
            schemaStoreHolder.adopt(store)
            schemaStore = store
            await store.loadDatabases()
            // Prime the working database so the user sees a populated tree
            // immediately instead of having to expand it first.
            await store.loadSchemas(database: profile.database)
            expandedDatabases.insert(profile.database)
            PostgresProfileStore.shared.markConnected(profile)
            PostgresConnectionStatusStore.shared.markConnected(profileId: profile.id)
        } catch let err as PostgresBridgeError {
            connectionError = err.errorDescription ?? "Unknown error"
            logger.error("pg connect failed: \(err.localizedDescription, privacy: .public)")
            PostgresConnectionStatusStore.shared.markError(
                err.errorDescription ?? "Unknown error",
                profileId: profile.id
            )
        } catch {
            connectionError = error.localizedDescription
            PostgresConnectionStatusStore.shared.markError(
                error.localizedDescription,
                profileId: profile.id
            )
        }
    }

    private func disconnect() async {
        guard let id = connectionId else { return }
        await BridgeManager.shared.pgDisconnect(connectionId: id)
        connectionId = nil
        schemaStoreHolder.adopt(nil)
        schemaStore = nil
        PostgresConnectionStatusStore.shared.markDisconnected(profileId: profile.id)
    }

    private func refreshAll() async {
        guard let store = schemaStoreHolder.store else { return }
        store.invalidate(database: profile.database)
        await store.loadDatabases()
        await store.loadSchemas(database: profile.database)
    }

    // MARK: - Formatting

    private func formatRowCount(_ rows: Float) -> String {
        let n = Int(rows)
        if n < 1_000 { return "\(n) rows" }
        if n < 1_000_000 { return String(format: "%.1fK rows", rows / 1_000) }
        if n < 1_000_000_000 { return String(format: "%.1fM rows", rows / 1_000_000) }
        return String(format: "%.1fB rows", rows / 1_000_000_000)
    }
}

// =============================================================================
// SchemaStoreHolder
//
// Why this exists: `@StateObject` requires a non-optional value, but the
// schema store can't exist until we have a connection id. The holder is the
// `@StateObject`; it owns an optional `PgSchemaStore` and republishes
// `objectWillChange` when the inner store changes, so SwiftUI re-renders
// the tree as schemas/relations load. Avoids reaching for the macOS 14+
// `@Observable` macro.
// =============================================================================

private extension String {
    func stripping(prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

@MainActor
final class SchemaStoreHolder: ObservableObject {
    @Published private(set) var store: PgSchemaStore? = nil
    private var subscription: AnyCancellable? = nil

    func adopt(_ newStore: PgSchemaStore?) {
        subscription?.cancel()
        store = newStore
        // Forward the inner store's change events so views observing the
        // holder re-render whenever the store mutates a load state.
        if let newStore {
            subscription = newStore.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }
}
