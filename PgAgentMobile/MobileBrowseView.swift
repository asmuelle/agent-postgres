import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobileBrowseView — the current database's objects as a plain list instead of
// a pgAdmin tree: one schema at a time (public by default, switchable from the
// toolbar), grouped by kind, searchable. Selecting an object shows it in the
// detail column (iPad) or pushes it (iPhone); server-level objects — roles,
// tablespaces, other databases — sit in a quiet "Server" section at the end.
// =============================================================================

/// What the Browse detail column shows.
enum BrowseItem: Hashable {
    case relation(node: PgSchemaNode, schema: String)
    case routine(node: PgSchemaNode, schema: String, signature: String)
    /// Sequences and types: the property inspector.
    case object(PgSchemaNode)
    case roles
    case tablespaces
    case databases

    /// Equal by object identity, not the whole node: a refresh that changes
    /// a row estimate must not drop the selection or rebuild the detail.
    static func == (lhs: BrowseItem, rhs: BrowseItem) -> Bool {
        lhs.identity == rhs.identity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
    }

    private var identity: String {
        switch self {
        case .relation(let node, _): return "relation:" + node.id
        case .routine(let node, _, _): return "routine:" + node.id
        case .object(let node): return "object:" + node.id
        case .roles: return "roles"
        case .tablespaces: return "tablespaces"
        case .databases: return "databases"
        }
    }
}

struct MobileBrowseView: View {
    @Environment(MobileAppModel.self) private var app
    @State private var selection: BrowseItem?

    var body: some View {
        NavigationSplitView {
            MobileDatabaseScope { profile in
                MobileConnectionGate(profile: profile) { _, schemaStore in
                    BrowseSidebar(profile: profile, schemaStore: schemaStore, selection: $selection)
                }
            }
            .navigationTitle("Browse")
        } detail: {
            NavigationStack {
                BrowseDetail(item: selection)
                    .navigationDestination(for: PgSchemaNode.self) { node in
                        BrowseNodeInspector(node: node)
                    }
            }
            // A new selection starts a fresh detail stack.
            .id(selection)
        }
        .onChange(of: app.currentProfileId) { _, _ in
            selection = nil
        }
    }
}

// MARK: - Sidebar

private struct BrowseSidebar: View {
    let profile: PostgresProfile
    @ObservedObject var schemaStore: PgSchemaStore
    @Binding var selection: BrowseItem?

    /// The user's pick from the schema menu; `schema` falls back to the
    /// default whenever this is unset or no longer exists.
    @State private var chosenSchema: String?
    @State private var search = ""

    private var database: String { profile.database }

    private var schemaNames: [String] {
        guard case .loaded(let nodes) = schemaStore.schemasState[database] else { return [] }
        return nodes.map(\.name)
    }

    /// Derived, not stored, so it follows the schema list as it loads.
    private var schema: String? {
        BrowseSchemaChoice.resolve(current: chosenSchema, available: schemaNames)
    }

    private var contentsState: PgLoadState<PgSchemaContentsBundle>? {
        guard let schema else { return nil }
        return schemaStore.schemaContentsState[PgCompositeKey.schema(database: database, schema: schema)]
    }

    var body: some View {
        List(selection: $selection) {
            contentSections
            serverSection
        }
        .searchable(text: $search, prompt: "Search")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar {
            if schemaNames.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Schema", selection: schemaSelection) {
                            ForEach(schemaNames, id: \.self) { name in
                                Text(name).tag(Optional(name))
                            }
                        }
                    } label: {
                        // The schema's name, not an icon: it says where you are.
                        Text(schema ?? "Schema")
                    }
                }
            }
        }
        .task {
            // The connection primes this; load only if nothing has started.
            if schemaStore.schemasState[database] == nil {
                await schemaStore.loadSchemas(database: database)
            }
        }
        // Re-fires as the schema list arrives and when the user picks one.
        .task(id: schema) {
            guard let schema else { return }
            if contentsState == nil {
                await schemaStore.loadSchemaContents(database: database, schema: schema)
            }
        }
        .refreshable {
            schemaStore.invalidate(database: database)
            await schemaStore.loadSchemas(database: database)
            if let schema {
                await schemaStore.loadSchemaContents(database: database, schema: schema)
            }
        }
    }

    private var schemaSelection: Binding<String?> {
        Binding(get: { schema }, set: { chosenSchema = $0 })
    }

    /// The schema list first (it can fail or be empty), then its contents.
    @ViewBuilder
    private var contentSections: some View {
        switch schemaStore.schemasState[database] {
        case .loaded(let schemas)? where schemas.isEmpty:
            Text("No schemas you can see.")
                .foregroundStyle(.secondary)
        case .loaded?:
            schemaContents
        case .failed(let message)?:
            loadFailure(message) {
                await schemaStore.loadSchemas(database: database)
            }
        case .idle?, .loading?, nil:
            loadingRow
        }
    }

    private var loadingRow: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .listRowBackground(Color.clear)
    }

    private func loadFailure(_ message: String, retry: @escaping () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Button("Try Again") {
                Task { await retry() }
            }
        }
    }

    @ViewBuilder
    private var schemaContents: some View {
        switch contentsState {
        case .loaded(let bundle)?:
            let groups = categoryGroups(in: bundle)
            if groups.isEmpty {
                Text(search.isEmpty ? "This schema is empty." : "No matches.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                Section(group.category.displayName) {
                    ForEach(group.nodes) { node in
                        NavigationLink(value: item(for: node, schema: bundle.schema)) {
                            objectRow(node, category: group.category)
                        }
                    }
                }
            }
        case .failed(let message)?:
            loadFailure(message) {
                if let schema {
                    await schemaStore.loadSchemaContents(database: database, schema: schema)
                }
            }
        case .idle?, .loading?, nil:
            loadingRow
        }
    }

    /// Server-level objects: rarely needed on a tablet, so last and quiet.
    private var serverSection: some View {
        Section("Server") {
            NavigationLink(value: BrowseItem.roles) {
                Label("Roles", systemImage: "person.2")
                    .badge(count(schemaStore.rolesState))
            }
            NavigationLink(value: BrowseItem.tablespaces) {
                Label("Tablespaces", systemImage: "externaldrive")
                    .badge(count(schemaStore.tablespacesState))
            }
            NavigationLink(value: BrowseItem.databases) {
                Label("Databases", systemImage: "cylinder.split.1x2")
                    .badge(count(schemaStore.databasesState))
            }
        }
    }

    private func objectRow(_ node: PgSchemaNode, category: PgCategoryKind) -> some View {
        Label(node.name, systemImage: symbol(for: node, category: category))
            .badge(rowCountText(node.estimatedRows))
    }

    /// Non-empty categories of `bundle`, filtered by the search text.
    private struct CategoryGroup: Identifiable {
        let category: PgCategoryKind
        let nodes: [PgSchemaNode]
        var id: PgCategoryKind { category }
    }

    private func categoryGroups(in bundle: PgSchemaContentsBundle) -> [CategoryGroup] {
        PgCategoryKind.allCases.compactMap { category in
            let nodes = bundle.nodes(for: category).filter(matchesSearch)
            return nodes.isEmpty ? nil : CategoryGroup(category: category, nodes: nodes)
        }
    }

    private func matchesSearch(_ node: PgSchemaNode) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty || node.name.localizedCaseInsensitiveContains(needle)
    }

    private func item(for node: PgSchemaNode, schema: String) -> BrowseItem {
        switch node.kind {
        case .relation:
            return .relation(node: node, schema: schema)
        case .routine(_, let signature, _):
            return .routine(node: node, schema: schema, signature: signature)
        default:
            return .object(node)
        }
    }

    private func symbol(for node: PgSchemaNode, category: PgCategoryKind) -> String {
        switch node.kind {
        case .relation(let kind): return kind.sfSymbol
        case .routine(let kind, _, _): return kind.sfSymbol
        case .objectType(let kind): return kind.sfSymbol
        default: return category.sfSymbol
        }
    }

    private func count(_ state: PgLoadState<[PgSchemaNode]>) -> Int {
        if case .loaded(let nodes) = state { return nodes.count }
        return 0
    }

    private func rowCountText(_ rows: Float?) -> Text? {
        guard let rows, rows >= 0 else { return nil }
        return Text(Int(rows), format: .number.notation(.compactName))
    }
}

// MARK: - Detail

private struct BrowseDetail: View {
    let item: BrowseItem?

    @Environment(MobileAppModel.self) private var app
    @EnvironmentObject private var profileStore: PostgresProfileStore
    @ObservedObject private var connectionManager = PostgresConnectionManager.shared

    var body: some View {
        if let item,
           let profileId = app.currentProfileId,
           let profile = profileStore.profile(withId: profileId),
           let connectionId = connectionManager.activeConnections[profileId],
           let schemaStore = connectionManager.schemaStores[profileId] {
            switch item {
            case .relation(let node, let schema):
                MobileTableDetailView(
                    profile: profile,
                    schemaStore: schemaStore,
                    node: node,
                    schema: schema
                )
            case .routine(let node, let schema, let signature):
                MobileRoutineEditorView(
                    connectionId: connectionId,
                    profileId: profileId,
                    schema: schema,
                    name: node.name,
                    signature: signature
                )
                .navigationTitle(node.name)
                .navigationBarTitleDisplayMode(.inline)
            case .object(let node):
                BrowseNodeInspector(node: node)
            case .roles:
                BrowseNodeList(title: "Roles", state: schemaStore.rolesState) {
                    await schemaStore.loadRoles()
                }
            case .tablespaces:
                BrowseNodeList(title: "Tablespaces", state: schemaStore.tablespacesState) {
                    await schemaStore.loadTablespaces()
                }
            case .databases:
                BrowseNodeList(title: "Databases", state: schemaStore.databasesState) {
                    await schemaStore.loadDatabases()
                }
            }
        } else {
            ContentUnavailableView(
                "Nothing Selected",
                systemImage: "square.stack.3d.up",
                description: Text("Choose a table, view or function.")
            )
        }
    }
}

/// Roles, tablespaces or databases; each pushes its inspector.
private struct BrowseNodeList: View {
    let title: String
    let state: PgLoadState<[PgSchemaNode]>
    let reload: () async -> Void

    var body: some View {
        Group {
            switch state {
            case .loaded(let nodes):
                List(nodes) { node in
                    NavigationLink(value: node) {
                        Text(node.name)
                    }
                }
            case .failed(let message):
                ContentUnavailableView(
                    "Couldn't Load \(title)",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
    }
}

/// The property inspector (properties + DDL, the role editor for roles) for
/// the current database's connection.
struct BrowseNodeInspector: View {
    let node: PgSchemaNode

    @Environment(MobileAppModel.self) private var app
    @ObservedObject private var connectionManager = PostgresConnectionManager.shared

    var body: some View {
        if let profileId = app.currentProfileId,
           let schemaStore = connectionManager.schemaStores[profileId] {
            MobilePropertyInspectorView(
                node: node,
                connectionId: connectionManager.activeConnections[profileId],
                schemaStore: schemaStore
            )
            .navigationTitle(node.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
