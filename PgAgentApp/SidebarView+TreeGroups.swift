import PgAgentMacOS
import SwiftUI

// =============================================================================
// SidebarView tree groups — the lazy-loading disclosure groups for
// Databases / Languages / Schemas / per-schema categories, plus the
// server-level Roles and Tablespaces groups.
//
// Extracted from SidebarView.swift; behavior-preserving.
// =============================================================================

extension SidebarView {
    @ViewBuilder
    func databasesNodeGroup(profile: PostgresProfile, store: PgSchemaStore) -> some View {
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
    func rolesNodeGroup(profile: PostgresProfile, store: PgSchemaStore) -> some View {
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
    func tablespacesNodeGroup(profile: PostgresProfile, store: PgSchemaStore) -> some View {
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
}
