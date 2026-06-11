import SwiftUI
import PgAgentMacOS

/// Sidebar showing the unified Object Explorer tree matching pgAdmin 4.
/// It contains a single root node "Servers", with lazy database sub-trees,
/// server-level Roles, Tablespaces, database Languages, and a details panel at the bottom.
struct SidebarView: View {
    @ObservedObject var storeManager: ConnectionStoreManager
    @ObservedObject var postgresStore: PostgresProfileStore
    @Binding var selectedPostgresProfileId: String?
    @Binding var selectedNode: PgSchemaNode?
    @Binding var activeConnectionId: String?
    @Binding var activeSchemaStore: PgSchemaStore?

    @StateObject private var connectionManager = PostgresConnectionManager.shared

    @State private var showNewPostgresConnection = false
    @State private var search = ""
    @State private var editingPostgresProfile: PostgresEditTarget?
    @State private var detailsExpanded = true

    // Tree Expansion States
    @State private var serversExpanded = true
    @State private var expandedServers: Set<String> = [] // profile.id
    @State private var expandedDatabasesGroup: Set<String> = [] // profile.id.databases
    @State private var expandedDatabases: Set<String> = [] // profile.id.databaseName
    @State private var expandedLanguagesGroup: Set<String> = [] // profile.id.databaseName.languages
    @State private var expandedSchemasGroup: Set<String> = [] // profile.id.databaseName.schemas
    @State private var expandedSchemas: Set<String> = [] // profile.id.databaseName.schemaName
    @State private var expandedCategories: Set<String> = [] // profile.id.databaseName.schemaName.category
    @State private var expandedRelations: Set<String> = [] // profile.id.databaseName.schemaName.tableName
    @State private var expandedRolesGroup: Set<String> = [] // profile.id.roles
    @State private var expandedTablespacesGroup: Set<String> = [] // profile.id.tablespaces

    @State private var selectedNodeId: String? = nil

    private struct PostgresEditTarget: Identifiable {
        let profile: PostgresProfile
        var id: String { profile.id }
    }

    private var selectedPostgresProfile: PostgresProfile? {
        guard let id = selectedPostgresProfileId else { return nil }
        return postgresStore.profile(withId: id)
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                connectionsHeader
                Divider()
                connectionList
            }
            .frame(minHeight: 180)

            if detailsExpanded {
                PostgresDetailsPanel(
                    profile: selectedPostgresProfile,
                    status: selectedPostgresProfile.map { PostgresConnectionStatusStore.shared.status(forProfile: $0.id) },
                    store: selectedPostgresProfile.flatMap { connectionManager.schemaStores[$0.id] },
                    onCollapse: { detailsExpanded = false }
                )
                .frame(minHeight: 140, idealHeight: 200, maxHeight: 320)
            } else {
                CollapsedPostgresDetailsBar(
                    profile: selectedPostgresProfile,
                    status: selectedPostgresProfile.map { PostgresConnectionStatusStore.shared.status(forProfile: $0.id) },
                    onExpand: { detailsExpanded = true }
                )
                .frame(height: 34)
            }
        }
        .frame(minWidth: LayoutConstants.minSidebarWidth)
        .sheet(isPresented: $showNewPostgresConnection) {
            PostgresConnectionEditView(
                store: postgresStore,
                sshStore: storeManager,
                existingProfile: nil
            )
        }
        .sheet(item: $editingPostgresProfile) { target in
            PostgresConnectionEditView(
                store: postgresStore,
                sshStore: storeManager,
                existingProfile: target.profile
            )
        }
        .onChange(of: selectedNodeId) { newValue in
            if let id = newValue {
                if let found = findNodeAcrossStores(id: id) {
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
        .onChange(of: selectedPostgresProfileId) { newProfileId in
            if let profileId = newProfileId {
                activeConnectionId = PostgresConnectionManager.shared.activeConnections[profileId]
                activeSchemaStore = PostgresConnectionManager.shared.schemaStores[profileId]
            } else {
                activeConnectionId = nil
                activeSchemaStore = nil
            }
        }
        .onReceive(PostgresConnectionManager.shared.objectWillChange) { _ in
            DispatchQueue.main.async {
                if let profileId = selectedPostgresProfileId {
                    activeConnectionId = PostgresConnectionManager.shared.activeConnections[profileId]
                    activeSchemaStore = PostgresConnectionManager.shared.schemaStores[profileId]
                }
            }
        }
    }

    // MARK: - Connections Header

    private var connectionsHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Object Explorer")
                    .font(MidnightMacDesign.FontToken.label)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer(minLength: 0)

                Button {
                    showNewPostgresConnection = true
                } label: {
                    Image(systemName: "plus")
                        .font(MidnightMacDesign.FontToken.label)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add new Postgres connection")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(MidnightMacDesign.FontToken.subheadline)
                    .foregroundStyle(.tertiary)

                TextField("Search profiles", text: $search)
                    .textFieldStyle(.plain)
                    .font(MidnightMacDesign.FontToken.callout)

                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(MidnightMacDesign.FontToken.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.small)
                    .fill(MidnightMacDesign.ColorToken.controlBackground.opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.small)
                    .stroke(MidnightMacDesign.ColorToken.separator.opacity(0.4), lineWidth: 1)
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Connection List

    @ViewBuilder
    private var connectionList: some View {
        List(selection: $selectedNodeId) {
            if postgresStore.profiles.isEmpty {
                emptyState
            } else {
                DisclosureGroup(
                    isExpanded: $serversExpanded
                ) {
                    let pgMatches = filteredPostgresProfiles()
                    if pgMatches.isEmpty {
                        Text("No matches")
                            .foregroundColor(.secondary)
                            .font(MidnightMacDesign.FontToken.caption)
                    } else {
                        ForEach(pgMatches) { profile in
                            serverNodeRow(profile: profile)
                        }
                    }
                } label: {
                    Label("Servers", systemImage: "server.rack")
                        .font(MidnightMacDesign.FontToken.headline)
                        .foregroundStyle(.primary)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Server Node & Lazy Connection

    @ViewBuilder
    private func serverNodeRow(profile: PostgresProfile) -> some View {
        let isExpanded = expandedServers.contains(profile.id)

        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { expanded in
                    if expanded {
                        expandedServers.insert(profile.id)
                        Task {
                            await connectionManager.connectIfNeeded(profile: profile)
                        }
                    } else {
                        expandedServers.remove(profile.id)
                    }
                }
            )
        ) {
            if connectionManager.isConnecting[profile.id] == true {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting...")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 8)
            } else if let error = connectionManager.connectionErrors[profile.id] {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Connection failed")
                            .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
                    }
                    Text(error)
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Retry") {
                        Task {
                            await connectionManager.connectIfNeeded(profile: profile)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
                .padding(.leading, 8)
            } else if let store = connectionManager.schemaStores[profile.id] {
                serverConnectedContent(profile: profile, store: store)
            } else {
                Text("Not connected")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
        } label: {
            // All row-interaction modifiers live on the LABEL, never on
            // the DisclosureGroup: modifiers on a DisclosureGroup inside
            // a List apply to every row the group renders, which made
            // the whole subtree inherit this menu (and the tag, which
            // ghost-highlighted children alongside the parent).
            serverRowLabel(profile: profile)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedPostgresProfileId = profile.id
                    selectedNodeId = nil
                    selectedNode = nil
                }
                .contextMenu {
                    Button("Connect") {
                        Task {
                            await connectionManager.connectIfNeeded(profile: profile)
                        }
                    }
                    .disabled(connectionManager.activeConnections[profile.id] != nil || connectionManager.isConnecting[profile.id] == true)

                    Button("Disconnect") {
                        Task {
                            await connectionManager.disconnect(profileId: profile.id)
                        }
                    }
                    .disabled(connectionManager.activeConnections[profile.id] == nil)

                    Divider()

                    Button("Edit...") {
                        editingPostgresProfile = PostgresEditTarget(profile: profile)
                    }

                    Button("Delete", role: .destructive) {
                        if selectedPostgresProfileId == profile.id {
                            selectedPostgresProfileId = nil
                        }
                        postgresStore.delete(profile)
                    }
                }
                .tag("server:\(profile.id)")
        }
    }

    @ViewBuilder
    private func serverRowLabel(profile: PostgresProfile) -> some View {
        let isSelected = selectedPostgresProfileId == profile.id
        let status = PostgresConnectionStatusStore.shared.status(forProfile: profile.id)

        let statusColor: Color = {
            switch status {
            case .connected:    return .green
            case .connecting:   return .yellow
            case .error:        return .red
            case .disconnected: return .secondary.opacity(0.25)
            }
        }()

        let statusSymbol: String = {
            switch status {
            case .connected:        return "checkmark.circle.fill"
            case .connecting:       return "clock.fill"
            case .error:            return "exclamationmark.circle.fill"
            case .disconnected:     return "circle"
            }
        }()

        let environmentBadgeColor: Color? = {
            switch profile.color {
            case "production": return .red
            case "development": return .green
            case "testing": return .yellow
            default: return nil
            }
        }()

        let environmentBadgeLabel: String? = {
            switch profile.color {
            case "production": return "PROD"
            case "development": return "DEV"
            case "testing": return "TEST"
            default: return nil
            }
        }()

        HStack(spacing: 8) {
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(MidnightMacDesign.FontToken.callout.weight(.medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(1)

                    if let envColor = environmentBadgeColor, let envLabel = environmentBadgeLabel {
                        Text(envLabel)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(envColor)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(envColor.opacity(0.12))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(envColor.opacity(0.25), lineWidth: 0.5)
                            )
                    }
                }
                Text("\(profile.user)@\(profile.host):\(profile.port)/\(profile.database)")
                    .font(MidnightMacDesign.FontToken.metadataMono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: statusSymbol)
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(statusColor)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 12, height: 12)
        }
    }

    // MARK: - Server Connected Content

    @ViewBuilder
    private func serverConnectedContent(profile: PostgresProfile, store: PgSchemaStore) -> some View {
        databasesNodeGroup(profile: profile, store: store)
        rolesNodeGroup(profile: profile, store: store)
        tablespacesNodeGroup(profile: profile, store: store)
    }

    // MARK: - Subtrees (Databases, Roles, Tablespaces)

    @ViewBuilder
    private func databasesNodeGroup(profile: PostgresProfile, store: PgSchemaStore) -> some View {
        let key = "\(profile.id).databases"
        let isExpanded = expandedDatabasesGroup.contains(key)
        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { expanded in
                    if expanded {
                        expandedDatabasesGroup.insert(key)
                        Task {
                            if !store.databasesState.isLoaded {
                                await store.loadDatabases()
                            }
                        }
                    } else {
                        expandedDatabasesGroup.remove(key)
                    }
                }
            )
        ) {
            switch store.databasesState {
            case .idle, .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading databases...").font(.caption)
                }
                .padding(.leading, 8)
            case .failed(let msg):
                Text(msg).foregroundStyle(.red).font(.caption).padding(.leading, 8)
            case .loaded(let databases):
                ForEach(databases) { dbNode in
                    databaseNodeRow(profile: profile, store: store, databaseNode: dbNode)
                }
            }
        } label: {
            let countText: String = {
                if case .loaded(let dbs) = store.databasesState {
                    return " (\(dbs.count))"
                }
                return ""
            }()
            Label("Databases" + countText, systemImage: "cylinder.split.1x2")
        }
    }

    @ViewBuilder
    private func databaseNodeRow(profile: PostgresProfile, store: PgSchemaStore, databaseNode: PgSchemaNode) -> some View {
        let dbKey = "\(profile.id).\(databaseNode.name)"
        let isExpanded = expandedDatabases.contains(dbKey)
        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { expanded in
                    if expanded {
                        expandedDatabases.insert(dbKey)
                        Task {
                            if store.schemasState[databaseNode.name] == nil {
                                await store.loadSchemas(database: databaseNode.name)
                            }
                        }
                    } else {
                        expandedDatabases.remove(dbKey)
                    }
                }
            )
        ) {
            languagesNodeGroup(profile: profile, store: store, database: databaseNode.name)
            schemasNodeGroup(profile: profile, store: store, database: databaseNode.name)
        } label: {
            // Interaction modifiers on the label only — see serverNodeRow.
            Label(databaseNode.name, systemImage: "cylinder")
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedPostgresProfileId = profile.id
                    selectedNodeId = databaseNode.id
                    postOpenTabNotification(profile: profile, node: databaseNode, details: ["kind": "properties"])
                }
                .contextMenu {
                    PostgresNodeContextMenu(
                        node: databaseNode,
                        database: databaseNode.name,
                        isConnectedDb: databaseNode.name == profile.database,
                        post: { postOpenTabNotification(profile: profile, node: databaseNode, details: $0) },
                        refresh: {
                            store.invalidate(database: databaseNode.name)
                            Task {
                                await store.loadSchemas(database: databaseNode.name)
                                await store.loadLanguages(database: databaseNode.name)
                            }
                        }
                    )
                }
                .tag(databaseNode.id)
        }
    }

    @ViewBuilder
    private func languagesNodeGroup(profile: PostgresProfile, store: PgSchemaStore, database: String) -> some View {
        let key = "\(profile.id).\(database).languages"
        let isExpanded = expandedLanguagesGroup.contains(key)
        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { expanded in
                    if expanded {
                        expandedLanguagesGroup.insert(key)
                        Task {
                            if store.languagesState[database] == nil {
                                await store.loadLanguages(database: database)
                            }
                        }
                    } else {
                        expandedLanguagesGroup.remove(key)
                    }
                }
            )
        ) {
            switch store.languagesState[database] ?? .idle {
            case .idle, .loading:
                ProgressView().controlSize(.small).padding(.leading, 8)
            case .failed(let msg):
                Text(msg).foregroundStyle(.red).font(.caption).padding(.leading, 8)
            case .loaded(let langs):
                if langs.isEmpty {
                    Text("(empty)").font(.caption).foregroundStyle(.secondary).padding(.leading, 8)
                } else {
                    ForEach(langs) { langNode in
                        Label(langNode.name, systemImage: "character.book.closed")
                            .tag(langNode.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedPostgresProfileId = profile.id
                                selectedNodeId = langNode.id
                                postOpenTabNotification(profile: profile, node: langNode, details: ["kind": "properties"])
                            }
                            .contextMenu {
                                PostgresNodeContextMenu(
                                    node: langNode,
                                    database: database,
                                    isConnectedDb: database == profile.database,
                                    post: { postOpenTabNotification(profile: profile, node: langNode, details: $0) }
                                )
                            }
                    }
                }
            }
        } label: {
            let countText: String = {
                if case .loaded(let langs) = store.languagesState[database] {
                    return " (\(langs.count))"
                }
                return ""
            }()
            Label("Languages" + countText, systemImage: "globe")
        }
    }

    @ViewBuilder
    private func schemasNodeGroup(profile: PostgresProfile, store: PgSchemaStore, database: String) -> some View {
        let key = "\(profile.id).\(database).schemas"
        let isExpanded = expandedSchemasGroup.contains(key)
        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { expanded in
                    if expanded {
                        expandedSchemasGroup.insert(key)
                        Task {
                            if store.schemasState[database] == nil {
                                await store.loadSchemas(database: database)
                            }
                        }
                    } else {
                        expandedSchemasGroup.remove(key)
                    }
                }
            )
        ) {
            switch store.schemasState[database] ?? .idle {
            case .idle, .loading:
                ProgressView().controlSize(.small).padding(.leading, 8)
            case .failed(let msg):
                Text(msg).foregroundStyle(.red).font(.caption).padding(.leading, 8)
            case .loaded(let schemas):
                ForEach(schemas) { schemaNode in
                    schemaNodeRow(profile: profile, store: store, database: database, schemaNode: schemaNode)
                }
            }
        } label: {
            let countText: String = {
                if case .loaded(let schemas) = store.schemasState[database] {
                    return " (\(schemas.count))"
                }
                return ""
            }()
            Label("Schemas" + countText, systemImage: "folder")
        }
    }

    @ViewBuilder
    private func schemaNodeRow(profile: PostgresProfile, store: PgSchemaStore, database: String, schemaNode: PgSchemaNode) -> some View {
        let key = "\(database).\(schemaNode.name)"
        let fullKey = "\(profile.id).\(database).\(schemaNode.name)"
        let isExpanded = expandedSchemas.contains(fullKey)
        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { expanded in
                    if expanded {
                        expandedSchemas.insert(fullKey)
                        Task {
                            if store.schemaContentsState[key] == nil {
                                await store.loadSchemaContents(database: database, schema: schemaNode.name)
                            }
                        }
                    } else {
                        expandedSchemas.remove(fullKey)
                    }
                }
            )
        ) {
            schemaContentsView(profile: profile, store: store, database: database, schema: schemaNode.name)
        } label: {
            // Interaction modifiers on the label only — see serverNodeRow.
            HStack {
                Label(schemaNode.name, systemImage: "folder")
                if case .schema(let isSystem) = schemaNode.kind, isSystem {
                    Text("system")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectedPostgresProfileId = profile.id
                selectedNodeId = schemaNode.id
                postOpenTabNotification(profile: profile, node: schemaNode, details: ["kind": "properties"])
            }
            .contextMenu {
                PostgresNodeContextMenu(
                    node: schemaNode,
                    database: database,
                    isConnectedDb: database == profile.database,
                    post: { postOpenTabNotification(profile: profile, node: schemaNode, details: $0) },
                    refresh: {
                        store.invalidate(database: database, schema: schemaNode.name)
                        Task {
                            await store.loadSchemaContents(database: database, schema: schemaNode.name)
                        }
                    }
                )
            }
            .tag(schemaNode.id)
        }
    }

    @ViewBuilder
    private func schemaContentsView(profile: PostgresProfile, store: PgSchemaStore, database: String, schema: String) -> some View {
        let key = "\(database).\(schema)"
        switch store.schemaContentsState[key] ?? .idle {
        case .idle, .loading:
            ProgressView().controlSize(.small).padding(.leading, 8)
        case .failed(let msg):
            Text(msg).foregroundStyle(.red).font(.caption).padding(.leading, 8)
        case .loaded(let bundle):
            ForEach(PgCategoryKind.allCases, id: \.self) { category in
                // Constraint 1: do not show nodes with (0) elements
                if bundle.count(for: category) > 0 {
                    categoryNodeRow(profile: profile, store: store, bundle: bundle, category: category)
                }
            }
        }
    }

    @ViewBuilder
    private func categoryNodeRow(
        profile: PostgresProfile,
        store: PgSchemaStore,
        bundle: PgSchemaContentsBundle,
        category: PgCategoryKind
    ) -> some View {
        let nodes = bundle.nodes(for: category)
        let count = bundle.count(for: category)
        let key = "\(profile.id).\(bundle.database).\(bundle.schema).\(category.rawValue)"
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
                    contentNodeRow(profile: profile, store: store, database: bundle.database, schema: bundle.schema, node: node)
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
            .contextMenu {
                Button {
                    store.invalidate(database: bundle.database, schema: bundle.schema)
                    Task {
                        await store.loadSchemaContents(database: bundle.database, schema: bundle.schema)
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    @ViewBuilder
    private func contentNodeRow(
        profile: PostgresProfile,
        store: PgSchemaStore,
        database: String,
        schema: String,
        node: PgSchemaNode
    ) -> some View {
        switch node.kind {
        case .relation:
            relationRow(profile: profile, store: store, database: database, schema: schema, rel: node)
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
            .onTapGesture {
                selectedPostgresProfileId = profile.id
                selectedNodeId = node.id
                postOpenTabNotification(profile: profile, node: node, details: ["kind": "properties"])
            }
            .onTapGesture(count: 2) {
                guard let parsed = parsed else { return }
                if isConnectedDb {
                    postOpenTabNotification(
                        profile: profile,
                        node: node,
                        details: ["kind": "sequence", "schema": parsed.schema, "name": parsed.name]
                    )
                } else {
                    presentForeignDatabaseAlert(profile: profile, database: parsed.database)
                }
            }
            .help(isConnectedDb ? "Double-click to view sequence properties" : "Database '\(parsed?.database ?? "?")' isn't connected through this profile.")
            .contextMenu {
                PostgresNodeContextMenu(
                    node: node,
                    database: parsed?.database,
                    schema: parsed?.schema,
                    isConnectedDb: isConnectedDb,
                    post: { postOpenTabNotification(profile: profile, node: node, details: $0) }
                )
            }
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
            .onTapGesture {
                selectedPostgresProfileId = profile.id
                selectedNodeId = node.id
                postOpenTabNotification(profile: profile, node: node, details: ["kind": "properties"])
            }
            .onTapGesture(count: 2) {
                guard let parsed = parsed else { return }
                if isConnectedDb {
                    postOpenTabNotification(
                        profile: profile,
                        node: node,
                        details: ["kind": "routine", "schema": parsed.schema, "name": parsed.name, "signature": signature]
                    )
                } else {
                    presentForeignDatabaseAlert(profile: profile, database: parsed.database)
                }
            }
            .help(isConnectedDb ? "Double-click to view function definition" : "Database '\(parsed?.database ?? "?")' isn't connected through this profile.")
            .contextMenu {
                PostgresNodeContextMenu(
                    node: node,
                    database: parsed?.database,
                    schema: parsed?.schema,
                    isConnectedDb: isConnectedDb,
                    post: { postOpenTabNotification(profile: profile, node: node, details: $0) }
                )
            }
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
            .onTapGesture {
                selectedPostgresProfileId = profile.id
                selectedNodeId = node.id
                postOpenTabNotification(profile: profile, node: node, details: ["kind": "properties"])
            }
            .onTapGesture(count: 2) {
                guard let parsed = parsed else { return }
                if isConnectedDb {
                    postOpenTabNotification(
                        profile: profile,
                        node: node,
                        details: ["kind": "objectType", "schema": parsed.schema, "name": parsed.name, "typeKind": kind.rawValue]
                    )
                } else {
                    presentForeignDatabaseAlert(profile: profile, database: parsed.database)
                }
            }
            .help(isConnectedDb ? "Double-click to view custom type details" : "Database '\(parsed?.database ?? "?")' isn't connected through this profile.")
            .contextMenu {
                PostgresNodeContextMenu(
                    node: node,
                    database: parsed?.database,
                    schema: parsed?.schema,
                    isConnectedDb: isConnectedDb,
                    post: { postOpenTabNotification(profile: profile, node: node, details: $0) }
                )
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func relationRow(
        profile: PostgresProfile,
        store: PgSchemaStore,
        database: String,
        schema: String,
        rel: PgSchemaNode
    ) -> some View {
        let key = "\(database).\(schema).\(rel.name)"
        let fullKey = "\(profile.id).\(database).\(schema).\(rel.name)"
        let isExpanded = expandedRelations.contains(fullKey)
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
                        expandedRelations.insert(fullKey)
                        Task {
                            if store.columnsState[key] == nil || store.columnsState[key]?.isLoaded == false {
                                await store.loadColumns(database: database, schema: schema, table: rel.name)
                            }
                            if store.metaState[key] == nil || store.metaState[key]?.isLoaded == false {
                                await store.loadMeta(database: database, schema: schema, table: rel.name)
                            }
                        }
                    } else {
                        expandedRelations.remove(fullKey)
                    }
                }
            )
        ) {
            relationChildrenView(profile: profile, store: store, database: database, schema: schema, table: rel.name)
                .padding(.leading, 12)
        } label: {
            // Interaction modifiers on the label only — see serverNodeRow.
            HStack {
                Label(rel.name, systemImage: symbol)
                    .foregroundStyle(isConnectedDb ? .primary : .secondary)
                Spacer()
                if let rows = rel.estimatedRows, rows >= 0 {
                    Text(formatRowCount(rows))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectedPostgresProfileId = profile.id
                selectedNodeId = rel.id
                guard let parsed = parsed else { return }
                if isConnectedDb {
                    postOpenTabNotification(
                        profile: profile,
                        node: rel,
                        details: ["kind": "relation", "schema": parsed.schema, "name": parsed.name]
                    )
                } else {
                    presentForeignDatabaseAlert(profile: profile, database: parsed.database)
                }
            }
            .onTapGesture(count: 2) {
                // Double-click = "show me the data now": the single-tap
                // already opened (or reactivated) the browse tab; this
                // re-posts with `autoRun` so the generated SELECT
                // executes immediately. The store dedupes on
                // (schema, table), so no duplicate tab appears.
                guard let parsed = parsed, isConnectedDb else { return }
                postOpenTabNotification(
                    profile: profile,
                    node: rel,
                    details: [
                        "kind": "relation",
                        "schema": parsed.schema,
                        "name": parsed.name,
                        "autoRun": true,
                    ]
                )
            }
            .help(isConnectedDb
                  ? "Click to open a query tab; double-click to run the SELECT immediately"
                  : "Database '\(parsed?.database ?? "?")' isn't connected through this profile.")
            .contextMenu {
                PostgresNodeContextMenu(
                    node: rel,
                    database: database,
                    schema: schema,
                    isConnectedDb: isConnectedDb,
                    post: { postOpenTabNotification(profile: profile, node: rel, details: $0) },
                    refresh: {
                        Task {
                            await store.loadColumns(database: database, schema: schema, table: rel.name)
                            await store.loadMeta(database: database, schema: schema, table: rel.name)
                        }
                    }
                )
            }
            .tag(rel.id)
        }
    }

    @ViewBuilder
    private func relationChildrenView(
        profile: PostgresProfile,
        store: PgSchemaStore,
        database: String,
        schema: String,
        table: String
    ) -> some View {
        let key = "\(database).\(schema).\(table)"

        DisclosureGroup("Columns") {
            switch store.columnsState[key] ?? .idle {
            case .idle, .loading:
                ProgressView().controlSize(.small).padding(.leading, 8)
            case .failed(let err):
                Text("Error: \(err)").foregroundStyle(.red).font(.caption2).padding(.leading, 8)
            case .loaded(let cols):
                if cols.isEmpty {
                    Text("(no columns)").font(.caption2).foregroundStyle(.secondary).padding(.leading, 8)
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
                            selectedNodeId = col.id
                            selectedPostgresProfileId = profile.id
                            postOpenTabNotification(profile: profile, node: col, details: ["kind": "properties"])
                        }
                        .contextMenu {
                            PostgresNodeContextMenu(
                                node: col,
                                database: database,
                                schema: schema,
                                table: table,
                                isConnectedDb: database == profile.database,
                                post: { postOpenTabNotification(profile: profile, node: col, details: $0) }
                            )
                        }
                    }
                }
            }
        }
        .font(.caption)

        switch store.metaState[key] ?? .idle {
        case .idle, .loading:
            ProgressView().controlSize(.small).padding(.leading, 8)
        case .failed(let err):
            Text("Error: \(err)").foregroundStyle(.red).font(.caption2).padding(.leading, 8)
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
                            selectedNodeId = keyNode.id
                            selectedPostgresProfileId = profile.id
                            postOpenTabNotification(profile: profile, node: keyNode, details: ["kind": "properties"])
                        }
                        .contextMenu {
                            PostgresNodeContextMenu(
                                node: keyNode,
                                objectName: bareMetaName(id: keyNode.id, prefix: "key:\(database).\(schema).\(table).") ?? keyNode.name,
                                database: database,
                                schema: schema,
                                table: table,
                                isConnectedDb: database == profile.database,
                                post: { postOpenTabNotification(profile: profile, node: keyNode, details: $0) }
                            )
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
                            selectedNodeId = constNode.id
                            selectedPostgresProfileId = profile.id
                            postOpenTabNotification(profile: profile, node: constNode, details: ["kind": "properties"])
                        }
                        .contextMenu {
                            PostgresNodeContextMenu(
                                node: constNode,
                                objectName: bareMetaName(id: constNode.id, prefix: "const:\(database).\(schema).\(table).") ?? constNode.name,
                                database: database,
                                schema: schema,
                                table: table,
                                isConnectedDb: database == profile.database,
                                post: { postOpenTabNotification(profile: profile, node: constNode, details: $0) }
                            )
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
                            selectedNodeId = trigNode.id
                            selectedPostgresProfileId = profile.id
                            postOpenTabNotification(profile: profile, node: trigNode, details: ["kind": "properties"])
                        }
                        .contextMenu {
                            PostgresNodeContextMenu(
                                node: trigNode,
                                database: database,
                                schema: schema,
                                table: table,
                                isConnectedDb: database == profile.database,
                                post: { postOpenTabNotification(profile: profile, node: trigNode, details: $0) }
                            )
                        }
                    }
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func rolesNodeGroup(profile: PostgresProfile, store: PgSchemaStore) -> some View {
        let key = "\(profile.id).roles"
        let isExpanded = expandedRolesGroup.contains(key)
        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { expanded in
                    if expanded {
                        expandedRolesGroup.insert(key)
                        Task {
                            if !store.rolesState.isLoaded {
                                await store.loadRoles()
                            }
                        }
                    } else {
                        expandedRolesGroup.remove(key)
                    }
                }
            )
        ) {
            switch store.rolesState {
            case .idle, .loading:
                ProgressView().controlSize(.small).padding(.leading, 8)
            case .failed(let msg):
                Text(msg).foregroundStyle(.red).font(.caption).padding(.leading, 8)
            case .loaded(let roles):
                if roles.isEmpty {
                    Text("(empty)").font(.caption).foregroundStyle(.secondary).padding(.leading, 8)
                } else {
                    ForEach(roles) { roleNode in
                        Label(roleNode.name, systemImage: "person.2")
                            .tag(roleNode.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedPostgresProfileId = profile.id
                                selectedNodeId = roleNode.id
                                postOpenTabNotification(profile: profile, node: roleNode, details: ["kind": "properties"])
                            }
                            .contextMenu {
                                PostgresNodeContextMenu(
                                    node: roleNode,
                                    post: { postOpenTabNotification(profile: profile, node: roleNode, details: $0) }
                                )
                            }
                    }
                }
            }
        } label: {
            let countText: String = {
                if case .loaded(let roles) = store.rolesState {
                    return " (\(roles.count))"
                }
                return ""
            }()
            Label("Login/Group Roles" + countText, systemImage: "person.3")
        }
    }

    @ViewBuilder
    private func tablespacesNodeGroup(profile: PostgresProfile, store: PgSchemaStore) -> some View {
        let key = "\(profile.id).tablespaces"
        let isExpanded = expandedTablespacesGroup.contains(key)
        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { expanded in
                    if expanded {
                        expandedTablespacesGroup.insert(key)
                        Task {
                            if !store.tablespacesState.isLoaded {
                                await store.loadTablespaces()
                            }
                        }
                    } else {
                        expandedTablespacesGroup.remove(key)
                    }
                }
            )
        ) {
            switch store.tablespacesState {
            case .idle, .loading:
                ProgressView().controlSize(.small).padding(.leading, 8)
            case .failed(let msg):
                Text(msg).foregroundStyle(.red).font(.caption).padding(.leading, 8)
            case .loaded(let tspaces):
                if tspaces.isEmpty {
                    Text("(empty)").font(.caption).foregroundStyle(.secondary).padding(.leading, 8)
                } else {
                    ForEach(tspaces) { tspaceNode in
                        Label(tspaceNode.name, systemImage: "folder.badge.gearshape")
                            .tag(tspaceNode.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedPostgresProfileId = profile.id
                                selectedNodeId = tspaceNode.id
                                postOpenTabNotification(profile: profile, node: tspaceNode, details: ["kind": "properties"])
                            }
                            .contextMenu {
                                PostgresNodeContextMenu(
                                    node: tspaceNode,
                                    post: { postOpenTabNotification(profile: profile, node: tspaceNode, details: $0) }
                                )
                            }
                    }
                }
            }
        } label: {
            let countText: String = {
                if case .loaded(let tspaces) = store.tablespacesState {
                    return " (\(tspaces.count))"
                }
                return ""
            }()
            Label("Tablespaces" + countText, systemImage: "shippingbox")
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Welcome to pgAgent")
                    .font(MidnightMacDesign.FontToken.headline)
            }

            Text("Add a database profile to start querying your PostgreSQL instances with a premium interface.")
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showNewPostgresConnection = true
            } label: {
                Label("New Postgres", systemImage: "cylinder.split.1x2")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Parsers & Helpers

    private func findNodeAcrossStores(id: String) -> PgSchemaNode? {
        for store in connectionManager.schemaStores.values {
            if let found = store.findNode(byId: id) {
                return found
            }
        }
        return nil
    }

    /// Recover a constraint/key's bare name from its node id —
    /// `loadMeta` bakes the human-readable definition into
    /// `node.name` ("pk_users (PRIMARY KEY (id))"), which is wrong
    /// for generated DDL.
    private func bareMetaName(id: String, prefix: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
    }

    private func postOpenTabNotification(profile: PostgresProfile, node: PgSchemaNode, details: [String: Any]) {
        var info = details
        info["profileId"] = profile.id
        info["node"] = node
        NotificationCenter.default.post(
            name: .openPostgresObjectTab,
            object: nil,
            userInfo: info
        )
    }

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

    private func presentForeignDatabaseAlert(profile: PostgresProfile, database: String) {
        let alert = NSAlert()
        alert.messageText = "“\(database)” isn't connected"
        alert.informativeText = "This profile is connected to “\(profile.database)”. To open a query tab against “\(database)”, edit the profile (or create a new one) with that database selected."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func formatRowCount(_ rows: Float) -> String {
        let n = Int(rows)
        if n < 1_000 { return "\(n) rows" }
        if n < 1_000_000 { return String(format: "%.1fK rows", rows / 1_000) }
        if n < 1_000_000_000 { return String(format: "%.1fM rows", rows / 1_000_000) }
        return String(format: "%.1fB rows", rows / 1_000_000_000)
    }

    private func filteredPostgresProfiles() -> [PostgresProfile] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else {
            return postgresStore.profiles
        }
        let needle = search.lowercased()
        return postgresStore.profiles.filter {
            $0.name.lowercased().contains(needle)
                || $0.host.lowercased().contains(needle)
                || $0.user.lowercased().contains(needle)
                || $0.database.lowercased().contains(needle)
        }
    }
}

// MARK: - Postgres Details Panel

private struct PostgresDetailsPanel: View {
    let profile: PostgresProfile?
    let status: PostgresWorkspaceStatus?
    /// Schema store of the selected profile's live connection;
    /// `nil` while disconnected. Provides server version + extensions.
    let store: PgSchemaStore?
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Connection Details")
                    .font(MidnightMacDesign.FontToken.label)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button(action: onCollapse) {
                    Image(systemName: "chevron.down")
                        .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Collapse connection details")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            if let profile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        detailRow("Name", profile.name)
                        detailRow("Host", profile.host)
                        detailRow("Port", "\(profile.port)")
                        detailRow("User", profile.user)
                        detailRow("Database", profile.database)
                        if let status {
                            statusRow(status)
                        }
                        if let tunnel = profile.tunnel {
                             if let sshProfile = ConnectionStoreManager.shared.connections.first(where: { $0.id == tunnel.sshConnectionId }) {
                                 detailRow("SSH Tunnel", sshProfile.name)
                             } else {
                                 detailRow("SSH Tunnel ID", tunnel.sshConnectionId)
                             }
                             detailRow("Remote Host", tunnel.remoteHost)
                             detailRow("Remote Port", "\(tunnel.remotePort)")
                         }
                        if let store {
                            PostgresServerInfoSection(store: store)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Select a database profile to see details.")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(MidnightMacDesign.FontToken.metadataMono.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusRow(_ status: PostgresWorkspaceStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("State")
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 84, alignment: .leading)
            HStack(spacing: 5) {
                Image(systemName: statusSymbol(status))
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(statusColor(status))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 12, height: 12)
                Text(statusLabel(status))
                    .font(MidnightMacDesign.FontToken.metadataMono.monospacedDigit())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusSymbol(_ status: PostgresWorkspaceStatus) -> String {
        switch status {
        case .connected:        return "checkmark.circle.fill"
        case .connecting:       return "clock.fill"
        case .error:            return "exclamationmark.circle.fill"
        case .disconnected:     return "circle"
        }
    }

    private func statusColor(_ status: PostgresWorkspaceStatus) -> Color {
        switch status {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .error:        return .red
        case .disconnected: return .secondary.opacity(0.4)
        }
    }

    private func statusLabel(_ status: PostgresWorkspaceStatus) -> String {
        switch status {
        case .connected:    return "Connected"
        case .connecting:   return "Connecting"
        case .disconnected: return "Disconnected"
        case .error(let m): return "Error: \(m)"
        }
    }
}

// MARK: - Server Info Section (version + extensions)

/// Lazy server-version + extensions block inside the details panel.
/// Separate view so it can `@ObservedObject` the (optional upstream)
/// schema store and trigger its own load — the panel itself stays a
/// plain value-driven view.
private struct PostgresServerInfoSection: View {
    @ObservedObject var store: PgSchemaStore

    var body: some View {
        Group {
            switch store.serverInfoState {
            case .idle, .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading server info…")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(.red)
            case .loaded(let info):
                infoRow("Server", "PostgreSQL \(info.version)")

                Text("Extensions (\(info.extensions.count))".uppercased())
                    .font(MidnightMacDesign.FontToken.label)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                if info.extensions.isEmpty {
                    Text("No extensions installed")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(info.extensions) { ext in
                        infoRow(ext.name, ext.version)
                    }
                }
            }
        }
        // Keyed on the connection id: a reconnect produces a fresh
        // store (and id), so version/extensions re-fetch automatically.
        .task(id: store.connectionId) {
            if !store.serverInfoState.isLoaded {
                await store.loadServerInfo()
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(MidnightMacDesign.FontToken.metadataMono.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Collapsed Details Bar

private struct CollapsedPostgresDetailsBar: View {
    let profile: PostgresProfile?
    let status: PostgresWorkspaceStatus?
    let onCollapse: () -> Void = {} // Dummy for initialization matching
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 7) {
                if let status {
                    Image(systemName: statusSymbol(status))
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(statusColor(status))
                        .symbolRenderingMode(.hierarchical)
                } else {
                    Image(systemName: "info.circle")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                }
                Text(profile?.name ?? "Connection Details")
                    .font(MidnightMacDesign.FontToken.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(MidnightMacDesign.FontToken.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show connection details")
    }

    private func statusSymbol(_ status: PostgresWorkspaceStatus) -> String {
        switch status {
        case .connected:        return "checkmark.circle.fill"
        case .connecting:       return "clock.fill"
        case .error:            return "exclamationmark.circle.fill"
        case .disconnected:     return "circle"
        }
    }

    private func statusColor(_ status: PostgresWorkspaceStatus) -> Color {
        switch status {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .error:        return .red
        case .disconnected: return .secondary.opacity(0.4)
        }
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    static let openPostgresObjectTab = Notification.Name("openPostgresObjectTab")
}
