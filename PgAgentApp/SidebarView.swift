import SwiftUI
import PgAgentMacOS

/// Sidebar showing the unified Object Explorer tree matching pgAdmin 4.
/// It contains a single root node "Servers", with lazy database sub-trees,
/// server-level Roles, Tablespaces, database Languages, and a details panel at the bottom.
///
/// This file holds the view struct, its state, the header/list shell,
/// and the server rows. Companion files (extensions of this view):
///   - SidebarView+TreeGroups.swift — Databases/Languages/Schemas/Roles/Tablespaces groups
///   - SidebarView+NodeRows.swift   — sequence/routine/type/relation leaf rows
///   - SidebarView+Helpers.swift    — id parsers, notifications, filtering
///   - SidebarDetailsPanels.swift   — bottom connection-details panels
struct SidebarView: View {
    @ObservedObject var storeManager: ConnectionStoreManager
    @ObservedObject var postgresStore: PostgresProfileStore
    @Binding var selectedPostgresProfileId: String?
    @Binding var selectedNode: PgSchemaNode?
    @Binding var activeConnectionId: String?
    @Binding var activeSchemaStore: PgSchemaStore?

    @StateObject var connectionManager = PostgresConnectionManager.shared

    @State private var showNewPostgresConnection = false
    @State var search = ""
    @State private var editingPostgresProfile: PostgresEditTarget?
    @State private var detailsExpanded = true

    // Tree Expansion States
    @State private var serversExpanded = true
    @State private var expandedServers: Set<String> = [] // profile.id
    @State var expandedDatabasesGroup: Set<String> = [] // profile.id.databases
    @State var expandedDatabases: Set<String> = [] // profile.id.databaseName
    @State var expandedLanguagesGroup: Set<String> = [] // profile.id.databaseName.languages
    @State var expandedSchemasGroup: Set<String> = [] // profile.id.databaseName.schemas
    @State var expandedSchemas: Set<String> = [] // profile.id.databaseName.schemaName
    @State var expandedCategories: Set<String> = [] // profile.id.databaseName.schemaName.category
    @State var expandedRelations: Set<String> = [] // profile.id.databaseName.schemaName.tableName
    @State var expandedRolesGroup: Set<String> = [] // profile.id.roles
    @State var expandedTablespacesGroup: Set<String> = [] // profile.id.tablespaces

    @State var selectedNodeId: String? = nil

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
}
