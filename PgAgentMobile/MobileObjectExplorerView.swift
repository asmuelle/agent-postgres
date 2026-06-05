import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

/// Unified pgAdmin-style Object Explorer tree for iPadOS/iOS.
/// Features a single root "Servers" disclosure group listing all connection profiles.
/// Server nodes lazily connect and load Databases, Login/Group Roles, and Tablespaces.
struct MobileObjectExplorerView: View {
    @Binding var selectedProfileId: String?
    @Binding var selectedNodeId: String?
    @Binding var selectedNode: PgSchemaNode?
    var onAddProfile: () -> Void
    var onEditProfile: (PostgresProfile) -> Void
    var onShowCSVImport: () -> Void
    var onOpenNodeTab: (PostgresProfile, PgSchemaNode, [String: String]) -> Void

    @EnvironmentObject private var profileStore: PostgresProfileStore
    @StateObject private var connectionManager = PostgresConnectionManager.shared
    @ObservedObject private var statusStore = PostgresConnectionStatusStore.shared

    @State private var search = ""
    @State private var serversExpanded = true
    
    // Tree Expansion States
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
    @State private var expandedMetaSections: Set<String> = [] // tableKey:title

    var body: some View {
        ZStack {
            MidnightColors.primaryBackground.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header & Search
                headerView
                searchBar
                
                // Unified Tree
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        serversDisclosureGroup
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .onChange(of: selectedNodeId) { newValue in
            if let id = newValue {
                if let found = findNodeAcrossStores(id: id) {
                    selectedNode = found
                }
            } else {
                selectedNode = nil
            }
        }
    }

    // MARK: - Header & Search

    private var headerView: some View {
        HStack {
            Text("Object Explorer")
                .font(MidnightMobileDesign.FontToken.headline)
                .foregroundStyle(.primary)
            
            Spacer()
            
            HStack(spacing: 12) {
                Button(action: onShowCSVImport) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(MidnightColors.accentCyan)
                }
                .buttonStyle(.plain)
                
                Button(action: onAddProfile) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(MidnightColors.accentCyan)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search profiles...", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(MidnightMobileDesign.FontToken.subheadline)
            if !search.isEmpty {
                Button(action: { search = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(MidnightColors.borderGray, lineWidth: 1))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Servers Root

    @ViewBuilder
    private var serversDisclosureGroup: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    serversExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(serversExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    
                    Image(systemName: "server.rack")
                        .foregroundStyle(MidnightColors.accentCyan)
                    
                    Text("Servers")
                        .font(MidnightMobileDesign.FontToken.label)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if serversExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    let matches = filteredProfiles()
                    if matches.isEmpty {
                        Text("No matches")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 32)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(matches) { profile in
                            serverNodeRow(profile: profile)
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }
    }

    // MARK: - Server Profile Row

    @ViewBuilder
    private func serverNodeRow(profile: PostgresProfile) -> some View {
        let isExpanded = expandedServers.contains(profile.id)
        
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedServers.remove(profile.id)
                    } else {
                        expandedServers.insert(profile.id)
                        selectedProfileId = profile.id
                        Task {
                            await connectionManager.connectIfNeeded(profile: profile)
                        }
                    }
                }
            } label: {
                serverRowLabel(profile: profile)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                    onEditProfile(profile)
                }

                Button("Duplicate") {
                    let dup = PostgresProfile(
                        name: "\(profile.name) Copy",
                        host: profile.host,
                        port: profile.port,
                        database: profile.database,
                        user: profile.user,
                        auth: profile.auth,
                        tls: profile.tls,
                        folderPath: profile.folderPath,
                        notes: profile.notes
                    )
                    profileStore.saveOrUpdate(dup)
                }

                Button("Delete", role: .destructive) {
                    if selectedProfileId == profile.id {
                        selectedProfileId = nil
                    }
                    profileStore.delete(profile)
                }
            }
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    if connectionManager.isConnecting[profile.id] == true {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Connecting...")
                                .font(MidnightMobileDesign.FontToken.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 32)
                        .padding(.vertical, 6)
                    } else if let error = connectionManager.connectionErrors[profile.id] {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("Connection failed")
                                    .font(MidnightMobileDesign.FontToken.captionStrong)
                            }
                            Text(error)
                                .font(MidnightMobileDesign.FontToken.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Button("Retry") {
                                Task {
                                    await connectionManager.connectIfNeeded(profile: profile)
                                }
                            }
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .foregroundStyle(MidnightColors.accentCyan)
                            .padding(.top, 2)
                        }
                        .padding(.leading, 32)
                        .padding(.vertical, 6)
                    } else if let store = connectionManager.schemaStores[profile.id] {
                        serverConnectedContent(profile: profile, store: store)
                            .padding(.leading, 12)
                    } else {
                        Text("Not connected")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 32)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.leading, 8)
            }
        }
    }

    @ViewBuilder
    private func serverRowLabel(profile: PostgresProfile) -> some View {
        let isSelected = selectedProfileId == profile.id
        let status = statusStore.status(forProfile: profile.id)
        
        let statusColor: Color = {
            switch status {
            case .connected:    return .green
            case .connecting:   return .yellow
            case .error:        return .red
            case .disconnected: return .secondary.opacity(0.4)
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
            Image(systemName: "chevron.right")
                .font(.caption2)
                .rotationEffect(.degrees(expandedServers.contains(profile.id) ? 90 : 0))
                .foregroundStyle(.secondary)
            
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(isSelected ? MidnightColors.accentCyan : .secondary)
                .frame(width: 18)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(MidnightMobileDesign.FontToken.label)
                        .foregroundStyle(isSelected ? MidnightColors.accentCyan : .primary)
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
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            
            Image(systemName: statusSymbol)
                .font(.caption)
                .foregroundStyle(statusColor)
                .symbolRenderingMode(.hierarchical)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(isSelected ? Color.white.opacity(0.04) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Server Connected Content

    @ViewBuilder
    private func serverConnectedContent(profile: PostgresProfile, store: PgSchemaStore) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            databasesNodeGroup(profile: profile, store: store)
            rolesNodeGroup(profile: profile, store: store)
            tablespacesNodeGroup(profile: profile, store: store)
        }
    }

    // MARK: - Databases Group

    @ViewBuilder
    private func databasesNodeGroup(profile: PostgresProfile, store: PgSchemaStore) -> some View {
        let key = "\(profile.id).databases"
        let isExpanded = expandedDatabasesGroup.contains(key)
        
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedDatabasesGroup.remove(key)
                    } else {
                        expandedDatabasesGroup.insert(key)
                        Task {
                            if !store.databasesState.isLoaded {
                                await store.loadDatabases()
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    
                    Image(systemName: "cylinder.split.1x2.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    let countText: String = {
                        if case .loaded(let dbs) = store.databasesState {
                            return " (\(dbs.count))"
                        }
                        return ""
                    }()
                    Text("Databases" + countText)
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    switch store.databasesState {
                    case .idle, .loading:
                        ProgressView().controlSize(.small).padding(.leading, 32)
                    case .failed(let err):
                        Text("Error: \(err)")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.red)
                            .padding(.leading, 32)
                    case .loaded(let databases):
                        ForEach(databases) { dbNode in
                            databaseNodeRow(profile: profile, store: store, databaseNode: dbNode)
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }
    }

    @ViewBuilder
    private func databaseNodeRow(profile: PostgresProfile, store: PgSchemaStore, databaseNode: PgSchemaNode) -> some View {
        let dbKey = "\(profile.id).\(databaseNode.name)"
        let isExpanded = expandedDatabases.contains(dbKey)
        let isSelected = selectedNodeId == databaseNode.id
        
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedDatabases.remove(dbKey)
                    } else {
                        expandedDatabases.insert(dbKey)
                        selectedNodeId = databaseNode.id
                        Task {
                            if store.schemasState[databaseNode.name] == nil {
                                await store.loadSchemas(database: databaseNode.name)
                            }
                        }
                    }
                }
                onOpenNodeTab(profile, databaseNode, ["kind": "properties"])
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    
                    Image(systemName: "cylinder.fill")
                        .font(.caption2)
                        .foregroundStyle(databaseNode.name == profile.database ? MidnightColors.accentCyan : .secondary)
                    
                    Text(databaseNode.name)
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(isSelected ? MidnightColors.accentCyan : .primary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(isSelected ? Color.white.opacity(0.04) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    languagesNodeGroup(profile: profile, store: store, database: databaseNode.name)
                    schemasNodeGroup(profile: profile, store: store, database: databaseNode.name)
                }
                .padding(.leading, 12)
            }
        }
    }

    // MARK: - Languages Group

    @ViewBuilder
    private func languagesNodeGroup(profile: PostgresProfile, store: PgSchemaStore, database: String) -> some View {
        let key = "\(profile.id).\(database).languages"
        let isExpanded = expandedLanguagesGroup.contains(key)
        
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedLanguagesGroup.remove(key)
                    } else {
                        expandedLanguagesGroup.insert(key)
                        Task {
                            if store.languagesState[database] == nil {
                                await store.loadLanguages(database: database)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    
                    Image(systemName: "globe")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    let countText: String = {
                        if case .loaded(let langs) = store.languagesState[database] {
                            return " (\(langs.count))"
                        }
                        return ""
                    }()
                    Text("Languages" + countText)
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    switch store.languagesState[database] ?? .idle {
                    case .idle, .loading:
                        ProgressView().controlSize(.small).padding(.leading, 32)
                    case .failed(let err):
                        Text("Error: \(err)")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.red)
                            .padding(.leading, 32)
                    case .loaded(let langs):
                        if langs.isEmpty {
                            Text("(empty)")
                                .font(MidnightMobileDesign.FontToken.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 32)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(langs) { langNode in
                                let isSelected = selectedNodeId == langNode.id
                                Button {
                                    selectedNodeId = langNode.id
                                    onOpenNodeTab(profile, langNode, ["kind": "properties"])
                                } label: {
                                    HStack(spacing: 8) {
                                        Spacer().frame(width: 12)
                                        Image(systemName: "character.book.closed")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(langNode.name)
                                            .font(MidnightMobileDesign.FontToken.caption)
                                            .foregroundStyle(isSelected ? MidnightColors.accentCyan : .primary)
                                        Spacer()
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 4)
                                    .background(isSelected ? Color.white.opacity(0.04) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Schemas Group

    @ViewBuilder
    private func schemasNodeGroup(profile: PostgresProfile, store: PgSchemaStore, database: String) -> some View {
        let key = "\(profile.id).\(database).schemas"
        let isExpanded = expandedSchemasGroup.contains(key)
        
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedSchemasGroup.remove(key)
                    } else {
                        expandedSchemasGroup.insert(key)
                        Task {
                            if store.schemasState[database] == nil {
                                await store.loadSchemas(database: database)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    
                    Image(systemName: "folder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    let countText: String = {
                        if case .loaded(let schemas) = store.schemasState[database] {
                            return " (\(schemas.count))"
                        }
                        return ""
                    }()
                    Text("Schemas" + countText)
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    switch store.schemasState[database] ?? .idle {
                    case .idle, .loading:
                        ProgressView().controlSize(.small).padding(.leading, 32)
                    case .failed(let err):
                        Text("Error: \(err)")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.red)
                            .padding(.leading, 32)
                    case .loaded(let schemas):
                        ForEach(schemas) { schemaNode in
                            schemaNodeRow(profile: profile, store: store, database: database, schemaNode: schemaNode)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func schemaNodeRow(profile: PostgresProfile, store: PgSchemaStore, database: String, schemaNode: PgSchemaNode) -> some View {
        let key = "\(database).\(schemaNode.name)"
        let fullKey = "\(profile.id).\(database).\(schemaNode.name)"
        let isExpanded = expandedSchemas.contains(fullKey)
        let isSelected = selectedNodeId == schemaNode.id
        
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedSchemas.remove(fullKey)
                    } else {
                        expandedSchemas.insert(fullKey)
                        selectedNodeId = schemaNode.id
                        Task {
                            if store.schemaContentsState[key] == nil {
                                await store.loadSchemaContents(database: database, schema: schemaNode.name)
                            }
                        }
                    }
                }
                onOpenNodeTab(profile, schemaNode, ["kind": "properties"])
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    
                    Image(systemName: "folder.fill")
                        .font(.caption2)
                        .foregroundStyle(MidnightColors.accentPurple)
                    
                    Text(schemaNode.name)
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(isSelected ? MidnightColors.accentCyan : .primary)
                    
                    if case .schema(let isSystem) = schemaNode.kind, isSystem {
                        Text("system")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(3)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(isSelected ? Color.white.opacity(0.04) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    schemaContentsView(profile: profile, store: store, database: database, schema: schemaNode.name)
                }
                .padding(.leading, 12)
            }
        }
    }

    @ViewBuilder
    private func schemaContentsView(profile: PostgresProfile, store: PgSchemaStore, database: String, schema: String) -> some View {
        let key = "\(database).\(schema)"
        switch store.schemaContentsState[key] ?? .idle {
        case .idle, .loading:
            ProgressView().controlSize(.small).padding(.leading, 32)
        case .failed(let msg):
            Text(msg)
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.red)
                .padding(.leading, 32)
        case .loaded(let bundle):
            ForEach(PgCategoryKind.allCases, id: \.self) { category in
                // Hiding empty categories
                if bundle.count(for: category) > 0 {
                    categoryNodeRow(profile: profile, store: store, bundle: bundle, category: category)
                }
            }
        }
    }

    // MARK: - Category Row

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
        
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedCategories.remove(key)
                    } else {
                        expandedCategories.insert(key)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    
                    Image(systemName: category.sfSymbol)
                        .font(.caption2)
                        .foregroundStyle(MidnightColors.accentCyan)
                    
                    Text(category.displayName)
                        .font(MidnightMobileDesign.FontToken.caption)
                    Text("(\(count))")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(nodes) { node in
                        contentNodeRow(profile: profile, store: store, database: bundle.database, schema: bundle.schema, node: node, bundle: bundle)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    // MARK: - Leaf Content Node Row

    @ViewBuilder
    private func contentNodeRow(
        profile: PostgresProfile,
        store: PgSchemaStore,
        database: String,
        schema: String,
        node: PgSchemaNode,
        bundle: PgSchemaContentsBundle
    ) -> some View {
        let isSelected = selectedNodeId == node.id
        let parsed = parseNodeId(node)
        let isConnectedDb = parsed?.database == profile.database
        
        switch node.kind {
        case .relation:
            relationNodeRow(profile: profile, store: store, database: database, schema: schema, relNode: node, isSelected: isSelected, isConnectedDb: isConnectedDb)
        case .sequence:
            Button {
                selectedNodeId = node.id
                onOpenNodeTab(profile, node, ["kind": "properties"])
            } label: {
                HStack {
                    Image(systemName: "number")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(node.name)
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(isSelected ? MidnightColors.accentCyan : (isConnectedDb ? .primary : .secondary))
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(isSelected ? Color.white.opacity(0.04) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onTapGesture(count: 2) {
                if isConnectedDb, let parsed {
                    onOpenNodeTab(profile, node, ["kind": "sequence", "schema": parsed.schema, "name": parsed.name])
                }
            }
        case .routine(let rkind, let signature, let returnType):
            Button {
                selectedNodeId = node.id
                onOpenNodeTab(profile, node, ["kind": "properties"])
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: rkind.sfSymbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(node.name)
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(isSelected ? MidnightColors.accentCyan : (isConnectedDb ? .primary : .secondary))
                        .lineLimit(1)
                    Text(signature)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(isSelected ? Color.white.opacity(0.04) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onTapGesture(count: 2) {
                if isConnectedDb, let parsed {
                    onOpenNodeTab(profile, node, ["kind": "routine", "schema": parsed.schema, "name": parsed.name, "signature": signature])
                }
            }
        case .objectType(let kind):
            Button {
                selectedNodeId = node.id
                onOpenNodeTab(profile, node, ["kind": "properties"])
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: kind.sfSymbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(node.name)
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(isSelected ? MidnightColors.accentCyan : (isConnectedDb ? .primary : .secondary))
                    Text(kind.rawValue)
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(isSelected ? Color.white.opacity(0.04) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onTapGesture(count: 2) {
                if isConnectedDb, let parsed {
                    onOpenNodeTab(profile, node, ["kind": "objectType", "schema": parsed.schema, "name": parsed.name, "typeKind": kind.rawValue])
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func relationNodeRow(
        profile: PostgresProfile,
        store: PgSchemaStore,
        database: String,
        schema: String,
        relNode: PgSchemaNode,
        isSelected: Bool,
        isConnectedDb: Bool
    ) -> some View {
        let key = "\(database).\(schema).\(relNode.name)"
        let fullKey = "\(profile.id).\(database).\(schema).\(relNode.name)"
        let isExpanded = expandedRelations.contains(fullKey)
        let symbol: String = {
            if case .relation(let kind) = relNode.kind { return kind.sfSymbol }
            return "tablecells"
        }()

        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedRelations.remove(fullKey)
                    } else {
                        expandedRelations.insert(fullKey)
                        selectedNodeId = relNode.id
                        Task {
                            if store.columnsState[key] == nil || store.columnsState[key]?.isLoaded == false {
                                await store.loadColumns(database: database, schema: schema, table: relNode.name)
                            }
                            if store.metaState[key] == nil || store.metaState[key]?.isLoaded == false {
                                await store.loadMeta(database: database, schema: schema, table: relNode.name)
                            }
                        }
                    }
                }
                if isConnectedDb, let parsed = parseRelationId(relNode.id) {
                    onOpenNodeTab(profile, relNode, ["kind": "relation", "schema": parsed.schema, "name": parsed.name])
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    
                    Image(systemName: symbol)
                        .font(.caption2)
                        .foregroundStyle(MidnightColors.accentCyan)
                    
                    Text(relNode.name)
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(isSelected ? MidnightColors.accentCyan : (isConnectedDb ? .primary : .secondary))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    if let rows = relNode.estimatedRows, rows >= 0 {
                        Text(formatRowCount(rows))
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(isSelected ? Color.white.opacity(0.04) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onTapGesture(count: 2) {
                if isConnectedDb, let parsed = parseRelationId(relNode.id) {
                    onOpenNodeTab(profile, relNode, ["kind": "relation", "schema": parsed.schema, "name": parsed.name])
                }
            }
            .contextMenu {
                if isConnectedDb, let parsed = parseRelationId(relNode.id) {
                    Button {
                        onOpenNodeTab(profile, relNode, ["kind": "relation", "schema": parsed.schema, "name": parsed.name])
                    } label: {
                        Label("Open Query Workspace", systemImage: "terminal")
                    }
                }
            }
            
            if isExpanded {
                relationChildrenMobileView(profile: profile, store: store, database: database, schema: schema, table: relNode.name)
                    .padding(.leading, 24)
            }
        }
    }

    @ViewBuilder
    private func relationChildrenMobileView(
        profile: PostgresProfile,
        store: PgSchemaStore,
        database: String,
        schema: String,
        table: String
    ) -> some View {
        let key = "\(database).\(schema).\(table)"
        
        VStack(alignment: .leading, spacing: 4) {
            // Columns Subgroup
            mobileMetaSection(tableKey: key, title: "Columns", state: store.columnsState[key] ?? .idle) { nodes in
                ForEach(nodes) { col in
                    let isColSelected = selectedNodeId == col.id
                    Button {
                        selectedNodeId = col.id
                        onOpenNodeTab(profile, col, ["kind": "properties"])
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "list.bullet")
                                .foregroundStyle(.secondary)
                                .font(.caption2)
                            Text(col.name)
                                .font(MidnightMobileDesign.FontToken.caption)
                                .foregroundStyle(isColSelected ? MidnightColors.accentCyan : .primary)
                            
                            if case .column(let typeName, let notNull) = col.kind {
                                Text(typeName)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if notNull {
                                    Text("not null")
                                        .font(MidnightMobileDesign.FontToken.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(isColSelected ? Color.white.opacity(0.04) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Metadata Subgroup (Keys, Constraints, Triggers)
            switch store.metaState[key] ?? .idle {
            case .idle, .loading:
                ProgressView().controlSize(.small).padding(.leading, 8)
            case .failed(let err):
                Text("Error: \(err)")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.red)
            case .loaded(let metaNodes):
                let keys = metaNodes.filter { if case .key = $0.kind { return true }; return false }
                let constraints = metaNodes.filter { if case .constraint = $0.kind { return true }; return false }
                let triggers = metaNodes.filter { if case .trigger = $0.kind { return true }; return false }
                
                if !keys.isEmpty {
                    mobileMetaSection(tableKey: key, title: "Keys (\(keys.count))", state: .loaded(keys)) { nodes in
                        ForEach(nodes) { keyNode in
                            let isKeySelected = selectedNodeId == keyNode.id
                            Button {
                                selectedNodeId = keyNode.id
                                onOpenNodeTab(profile, keyNode, ["kind": "properties"])
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "key.fill")
                                        .foregroundStyle(.yellow)
                                        .font(.caption2)
                                    Text(keyNode.name)
                                        .font(MidnightMobileDesign.FontToken.caption)
                                        .foregroundStyle(isKeySelected ? MidnightColors.accentCyan : .primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(isKeySelected ? Color.white.opacity(0.04) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                
                if !constraints.isEmpty {
                    mobileMetaSection(tableKey: key, title: "Constraints (\(constraints.count))", state: .loaded(constraints)) { nodes in
                        ForEach(nodes) { constNode in
                            let isConstSelected = selectedNodeId == constNode.id
                            Button {
                                selectedNodeId = constNode.id
                                onOpenNodeTab(profile, constNode, ["kind": "properties"])
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "lock.shield")
                                        .foregroundStyle(.orange)
                                        .font(.caption2)
                                    Text(constNode.name)
                                        .font(MidnightMobileDesign.FontToken.caption)
                                        .foregroundStyle(isConstSelected ? MidnightColors.accentCyan : .primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(isConstSelected ? Color.white.opacity(0.04) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                
                if !triggers.isEmpty {
                    mobileMetaSection(tableKey: key, title: "Triggers (\(triggers.count))", state: .loaded(triggers)) { nodes in
                        ForEach(nodes) { trigNode in
                            let isTrigSelected = selectedNodeId == trigNode.id
                            Button {
                                selectedNodeId = trigNode.id
                                onOpenNodeTab(profile, trigNode, ["kind": "properties"])
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "bolt.fill")
                                        .foregroundStyle(.cyan)
                                        .font(.caption2)
                                    Text(trigNode.name)
                                        .font(MidnightMobileDesign.FontToken.caption)
                                        .foregroundStyle(isTrigSelected ? MidnightColors.accentCyan : .primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(isTrigSelected ? Color.white.opacity(0.04) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func mobileMetaSection<Content: View>(
        tableKey: String,
        title: String,
        state: PgLoadState<[PgSchemaNode]>,
        @ViewBuilder content: @escaping ([PgSchemaNode]) -> Content
    ) -> some View {
        let sectionKey = "\(tableKey):\(title)"
        let isExpanded = expandedMetaSections.contains(sectionKey)
        
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedMetaSections.remove(sectionKey)
                    } else {
                        expandedMetaSections.insert(sectionKey)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                        .foregroundStyle(isExpanded ? MidnightColors.accentCyan : .secondary)
                    Spacer()
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    switch state {
                    case .idle, .loading:
                        ProgressView().controlSize(.small).padding(.leading, 12)
                    case .failed(let err):
                        Text("Error: \(err)")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.red)
                            .padding(.leading, 12)
                    case .loaded(let nodes):
                        if nodes.isEmpty {
                            Text("(none)")
                                .font(MidnightMobileDesign.FontToken.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 20)
                        } else {
                            content(nodes)
                                .padding(.leading, 8)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Server-Level Groups (Roles, Tablespaces)

    @ViewBuilder
    private func rolesNodeGroup(profile: PostgresProfile, store: PgSchemaStore) -> some View {
        let key = "\(profile.id).roles"
        let isExpanded = expandedRolesGroup.contains(key)
        
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedRolesGroup.remove(key)
                    } else {
                        expandedRolesGroup.insert(key)
                        Task {
                            if !store.rolesState.isLoaded {
                                await store.loadRoles()
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    
                    Image(systemName: "person.3.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    let countText: String = {
                        if case .loaded(let roles) = store.rolesState {
                            return " (\(roles.count))"
                        }
                        return ""
                    }()
                    Text("Login/Group Roles" + countText)
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    switch store.rolesState {
                    case .idle, .loading:
                        ProgressView().controlSize(.small).padding(.leading, 32)
                    case .failed(let err):
                        Text("Error: \(err)")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.red)
                            .padding(.leading, 32)
                    case .loaded(let roles):
                        if roles.isEmpty {
                            Text("(empty)")
                                .font(MidnightMobileDesign.FontToken.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 32)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(roles) { roleNode in
                                let isRoleSelected = selectedNodeId == roleNode.id
                                Button {
                                    selectedNodeId = roleNode.id
                                    onOpenNodeTab(profile, roleNode, ["kind": "properties"])
                                } label: {
                                    HStack(spacing: 8) {
                                        Spacer().frame(width: 12)
                                        Image(systemName: "person.2.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(roleNode.name)
                                            .font(MidnightMobileDesign.FontToken.caption)
                                            .foregroundStyle(isRoleSelected ? MidnightColors.accentCyan : .primary)
                                        Spacer()
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 4)
                                    .background(isRoleSelected ? Color.white.opacity(0.04) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tablespacesNodeGroup(profile: PostgresProfile, store: PgSchemaStore) -> some View {
        let key = "\(profile.id).tablespaces"
        let isExpanded = expandedTablespacesGroup.contains(key)
        
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedTablespacesGroup.remove(key)
                    } else {
                        expandedTablespacesGroup.insert(key)
                        Task {
                            if !store.tablespacesState.isLoaded {
                                await store.loadTablespaces()
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    
                    Image(systemName: "shippingbox.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    let countText: String = {
                        if case .loaded(let tspaces) = store.tablespacesState {
                            return " (\(tspaces.count))"
                        }
                        return ""
                    }()
                    Text("Tablespaces" + countText)
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    switch store.tablespacesState {
                    case .idle, .loading:
                        ProgressView().controlSize(.small).padding(.leading, 32)
                    case .failed(let err):
                        Text("Error: \(err)")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.red)
                            .padding(.leading, 32)
                    case .loaded(let tspaces):
                        if tspaces.isEmpty {
                            Text("(empty)")
                                .font(MidnightMobileDesign.FontToken.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 32)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(tspaces) { tspaceNode in
                                let isTspaceSelected = selectedNodeId == tspaceNode.id
                                Button {
                                    selectedNodeId = tspaceNode.id
                                    onOpenNodeTab(profile, tspaceNode, ["kind": "properties"])
                                } label: {
                                    HStack(spacing: 8) {
                                        Spacer().frame(width: 12)
                                        Image(systemName: "folder.badge.gearshape.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(tspaceNode.name)
                                            .font(MidnightMobileDesign.FontToken.caption)
                                            .foregroundStyle(isTspaceSelected ? MidnightColors.accentCyan : .primary)
                                        Spacer()
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 4)
                                    .background(isTspaceSelected ? Color.white.opacity(0.04) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helper Resolvers

    private func filteredProfiles() -> [PostgresProfile] {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return profileStore.profiles
        }
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return profileStore.profiles.filter {
            $0.name.lowercased().contains(needle) ||
            $0.host.lowercased().contains(needle) ||
            $0.database.lowercased().contains(needle)
        }
    }

    private func findNodeAcrossStores(id: String) -> PgSchemaNode? {
        for profile in profileStore.profiles {
            if let store = connectionManager.schemaStores[profile.id] {
                if let found = store.findNode(byId: id) {
                    return found
                }
            }
        }
        return nil
    }

    private func parseNodeId(_ node: PgSchemaNode) -> (database: String, schema: String, name: String)? {
        switch node.kind {
        case .relation: return parseRelationId(node.id)
        case .sequence: return parseSequenceId(node.id)
        case .routine: return parseRoutineId(node.id)
        case .objectType: return parseObjectTypeId(node.id)
        default: return nil
        }
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

    private func formatRowCount(_ rows: Float) -> String {
        let n = Int(rows)
        if n < 1_000 { return "\(n) rows" }
        if n < 1_000_000 { return String(format: "%.1fK rows", rows / 1_000) }
        if n < 1_000_000_000 { return String(format: "%.1fM rows", rows / 1_000_000) }
        return String(format: "%.1fB rows", rows / 1_000_000_000)
    }
}
