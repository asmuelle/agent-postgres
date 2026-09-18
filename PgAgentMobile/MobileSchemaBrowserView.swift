import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// MARK: - Schema Browser View
struct MobileSchemaBrowserView: View {
    let profile: PostgresProfile
    let connectionId: String?
    @ObservedObject var schemaStore: PgSchemaStore
    var onOpenNodeTab: (PgSchemaNode, [String: String]) -> Void
    
    @State private var expandedDatabasesGroup = true
    @State private var expandedRoles = false
    @State private var expandedTablespaces = false
    
    @State private var expandedDatabases = Set<String>()
    @State private var expandedDbLanguages = Set<String>() // database name
    @State private var expandedDbSchemas = Set<String>() // database name
    @State private var expandedSchemas = Set<String>() // "<database>.<schema>"
    @State private var expandedCategories = Set<String>() // "<database>.<schema>.<category>"
    @State private var expandedRelations = Set<String>() // "<database>.<schema>.<table_name>"
    @State private var expandedMetaSections = Set<String>() // "<key>:<title>"
    @State private var isRefreshing = false
    
    var body: some View {
        ZStack {
            MidnightColors.primaryBackground.ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    databasesGroupSection
                    rolesGroupSection
                    tablespacesGroupSection
                }
                .padding(.vertical)
            }
        }
        .task(id: schemaStore.connectionId) {
            if case .idle = schemaStore.databasesState {
                await schemaStore.loadDatabases()
                await schemaStore.loadSchemas(database: profile.database)
                expandedDatabases.insert(profile.database)
            }
        }
    }
    
    @ViewBuilder
    private var databasesGroupSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    expandedDatabasesGroup.toggle()
                    if expandedDatabasesGroup {
                        Task {
                            if !schemaStore.databasesState.isLoaded {
                                await schemaStore.loadDatabases()
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(expandedDatabasesGroup ? 90 : 0))
                        .foregroundStyle(.secondary)
                    
                    Image(systemName: "cylinder.split.1x2.fill")
                        .foregroundStyle(MidnightColors.accentCyan)
                    
                    let countText: String = {
                        if case .loaded(let dbs) = schemaStore.databasesState {
                            return " (\(dbs.count))"
                        }
                        return ""
                    }()
                    Text("Databases" + countText)
                        .font(MidnightMobileDesign.FontToken.label)
                    
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if expandedDatabasesGroup {
                VStack(alignment: .leading, spacing: 2) {
                    switch schemaStore.databasesState {
                    case .idle, .loading:
                        ProgressView().padding(.leading, 40)
                    case .failed(let err):
                        Text("Error: \(err)").foregroundStyle(.red).padding(.leading, 40)
                    case .loaded(let dbNodes):
                        ForEach(dbNodes) { dbNode in
                            databaseSection(store: schemaStore, dbNode: dbNode)
                        }
                    }
                }
                .padding(.leading, 12)
            }
        }
    }
    
    @ViewBuilder
    private func databaseSection(store: PgSchemaStore, dbNode: PgSchemaNode) -> some View {
        let dbName = dbNode.name
        let isExpanded = expandedDatabases.contains(dbName)
        let isLangExpanded = expandedDbLanguages.contains(dbName)
        let isSchemasExpanded = expandedDbSchemas.contains(dbName)
        
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedDatabases.remove(dbName)
                    } else {
                        expandedDatabases.insert(dbName)
                        Task {
                            if store.schemasState[dbName] == nil {
                                await store.loadSchemas(database: dbName)
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
                    
                    Image(systemName: "cylinder.fill")
                        .foregroundStyle(dbName == profile.database ? MidnightColors.accentCyan : .secondary)
                    
                    Text(dbName)
                        .font(MidnightMobileDesign.FontToken.label)
                        .foregroundStyle(dbName == profile.database ? .primary : .secondary)
                    
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    // Languages Subgroup
                    VStack(alignment: .leading, spacing: 2) {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                if isLangExpanded {
                                    expandedDbLanguages.remove(dbName)
                                } else {
                                    expandedDbLanguages.insert(dbName)
                                    Task {
                                        if store.languagesState[dbName] == nil {
                                            await store.loadLanguages(database: dbName)
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .rotationEffect(.degrees(isLangExpanded ? 90 : 0))
                                    .foregroundStyle(.secondary)
                                
                                Image(systemName: "globe")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                
                                let countText: String = {
                                    if case .loaded(let langs) = store.languagesState[dbName] {
                                        return " (\(langs.count))"
                                    }
                                    return ""
                                }()
                                Text("Languages" + countText)
                                    .font(MidnightMobileDesign.FontToken.caption)
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        
                        if isLangExpanded {
                            switch store.languagesState[dbName] ?? .idle {
                            case .idle, .loading:
                                ProgressView().padding(.leading, 40)
                            case .failed(let err):
                                Text(err).font(MidnightMobileDesign.FontToken.caption).foregroundStyle(.red).padding(.leading, 40)
                            case .loaded(let langs):
                                if langs.isEmpty {
                                    Text("(empty)").font(MidnightMobileDesign.FontToken.caption).foregroundStyle(.secondary).padding(.leading, 40)
                                } else {
                                    ForEach(langs) { langNode in
                                        Button {
                                            onOpenNodeTab(langNode, ["kind": "properties"])
                                        } label: {
                                            HStack(spacing: 8) {
                                                Spacer().frame(width: 24)
                                                Image(systemName: "character.book.closed")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                Text(langNode.name)
                                                    .font(MidnightMobileDesign.FontToken.caption)
                                                Spacer()
                                            }
                                            .padding(.vertical, 4)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.leading, 12)
                    
                    // Schemas Subgroup
                    VStack(alignment: .leading, spacing: 2) {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                if isSchemasExpanded {
                                    expandedDbSchemas.remove(dbName)
                                } else {
                                    expandedDbSchemas.insert(dbName)
                                    Task {
                                        if store.schemasState[dbName] == nil {
                                            await store.loadSchemas(database: dbName)
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .rotationEffect(.degrees(isSchemasExpanded ? 90 : 0))
                                    .foregroundStyle(.secondary)
                                
                                Image(systemName: "folder")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                
                                let countText: String = {
                                    if case .loaded(let schemas) = store.schemasState[dbName] {
                                        return " (\(schemas.count))"
                                    }
                                    return ""
                                }()
                                Text("Schemas" + countText)
                                    .font(MidnightMobileDesign.FontToken.caption)
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        
                        if isSchemasExpanded {
                            switch store.schemasState[dbName] ?? .idle {
                            case .idle, .loading:
                                ProgressView().padding(.leading, 40)
                            case .failed(let err):
                                Text(err).font(MidnightMobileDesign.FontToken.caption).foregroundStyle(.red).padding(.leading, 40)
                            case .loaded(let schemas):
                                ForEach(schemas) { schemaNode in
                                    schemaSection(store: store, database: dbName, schemaNode: schemaNode)
                                }
                                .padding(.leading, 12)
                            }
                        }
                    }
                    .padding(.leading, 12)
                }
                .padding(.leading, 12)
            }
        }
    }
    
    @ViewBuilder
    private var rolesGroupSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    expandedRoles.toggle()
                    if expandedRoles {
                        Task {
                            if !schemaStore.rolesState.isLoaded {
                                await schemaStore.loadRoles()
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(expandedRoles ? 90 : 0))
                        .foregroundStyle(.secondary)
                    
                    Image(systemName: "person.3.fill")
                        .foregroundStyle(MidnightColors.accentCyan)
                    
                    let countText: String = {
                        if case .loaded(let roles) = schemaStore.rolesState {
                            return " (\(roles.count))"
                        }
                        return ""
                    }()
                    Text("Login/Group Roles" + countText)
                        .font(MidnightMobileDesign.FontToken.label)
                    
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if expandedRoles {
                VStack(alignment: .leading, spacing: 2) {
                    switch schemaStore.rolesState {
                    case .idle, .loading:
                        ProgressView().padding(.leading, 40)
                    case .failed(let err):
                        Text("Error: \(err)").foregroundStyle(.red).padding(.leading, 40)
                    case .loaded(let roles):
                        if roles.isEmpty {
                            Text("(empty)").font(MidnightMobileDesign.FontToken.caption).foregroundStyle(.secondary).padding(.leading, 40)
                        } else {
                            ForEach(roles) { roleNode in
                                Button {
                                    onOpenNodeTab(roleNode, ["kind": "properties"])
                                } label: {
                                    HStack(spacing: 8) {
                                        Spacer().frame(width: 24)
                                        Image(systemName: "person.2.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(roleNode.name)
                                            .font(MidnightMobileDesign.FontToken.caption)
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.leading, 12)
            }
        }
    }
    
    @ViewBuilder
    private var tablespacesGroupSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    expandedTablespaces.toggle()
                    if expandedTablespaces {
                        Task {
                            if !schemaStore.tablespacesState.isLoaded {
                                await schemaStore.loadTablespaces()
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(expandedTablespaces ? 90 : 0))
                        .foregroundStyle(.secondary)
                    
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(MidnightColors.accentCyan)
                    
                    let countText: String = {
                        if case .loaded(let tspaces) = schemaStore.tablespacesState {
                            return " (\(tspaces.count))"
                        }
                        return ""
                    }()
                    Text("Tablespaces" + countText)
                        .font(MidnightMobileDesign.FontToken.label)
                    
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if expandedTablespaces {
                VStack(alignment: .leading, spacing: 2) {
                    switch schemaStore.tablespacesState {
                    case .idle, .loading:
                        ProgressView().padding(.leading, 40)
                    case .failed(let err):
                        Text("Error: \(err)").foregroundStyle(.red).padding(.leading, 40)
                    case .loaded(let tspaces):
                        if tspaces.isEmpty {
                            Text("(empty)").font(MidnightMobileDesign.FontToken.caption).foregroundStyle(.secondary).padding(.leading, 40)
                        } else {
                            ForEach(tspaces) { tspaceNode in
                                Button {
                                    onOpenNodeTab(tspaceNode, ["kind": "properties"])
                                } label: {
                                    HStack(spacing: 8) {
                                        Spacer().frame(width: 24)
                                        Image(systemName: "folder.badge.gearshape.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(tspaceNode.name)
                                            .font(MidnightMobileDesign.FontToken.caption)
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.leading, 12)
            }
        }
    }
    
    @ViewBuilder
    private func schemaSection(store: PgSchemaStore, database: String, schemaNode: PgSchemaNode) -> some View {
        let schemaName = schemaNode.name
        let key = "\(database).\(schemaName)"
        let isExpanded = expandedSchemas.contains(key)
        
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedSchemas.remove(key)
                    } else {
                        expandedSchemas.insert(key)
                        Task {
                            await store.loadSchemaContents(database: database, schema: schemaName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    
                    Image(systemName: "folder.fill")
                        .foregroundStyle(MidnightColors.accentPurple)
                    
                    Text(schemaName)
                        .font(MidnightMobileDesign.FontToken.subheadline)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    switch store.schemaContentsState[key] ?? .idle {
                    case .idle, .loading:
                        ProgressView().padding(.leading, 40)
                    case .failed(let msg):
                        Text(msg).font(MidnightMobileDesign.FontToken.caption).foregroundStyle(.red).padding(.leading, 40)
                    case .loaded(let bundle):
                        ForEach(PgCategoryKind.allCases, id: \.self) { category in
                            if bundle.count(for: category) > 0 {
                                categorySection(bundle: bundle, category: category)
                            }
                        }
                    }
                }
                .padding(.leading, 14)
            }
        }
    }
    
    @ViewBuilder
    private func categorySection(bundle: PgSchemaContentsBundle, category: PgCategoryKind) -> some View {
        let key = "\(bundle.database).\(bundle.schema).\(category.rawValue)"
        let isExpanded = expandedCategories.contains(key)
        let nodes = bundle.nodes(for: category)
        
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
                        .foregroundStyle(MidnightColors.accentCyan)
                    
                    Text(category.displayName)
                        .font(MidnightMobileDesign.FontToken.caption)
                    Text("(\(bundle.count(for: category)))")
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
                VStack(alignment: .leading, spacing: 1) {
                    if nodes.isEmpty {
                        Text("(empty)")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 32)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(nodes) { node in
                            nodeRow(node: node, bundle: bundle)
                        }
                    }
                }
                .padding(.leading, 12)
            }
        }
    }
    
    @ViewBuilder
    private func nodeRow(node: PgSchemaNode, bundle: PgSchemaContentsBundle) -> some View {
        let key = "\(bundle.database).\(bundle.schema).\(node.name)"
        let isExpanded = expandedRelations.contains(key)
        
        let isRelation: Bool = {
            if case .relation = node.kind { return true }
            return false
        }()
        
        let symbol: String = {
            switch node.kind {
            case .relation(let kind): return kind.sfSymbol
            case .sequence: return "number"
            case .routine(let kind, _, _): return kind.sfSymbol
            case .objectType(let kind): return kind.sfSymbol
            default: return "tablecells"
            }
        }()
        
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if isRelation {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        if isExpanded {
                            expandedRelations.remove(key)
                        } else {
                            expandedRelations.insert(key)
                            Task {
                                if schemaStore.columnsState[key] == nil || schemaStore.columnsState[key]?.isLoaded == false {
                                    await schemaStore.loadColumns(database: bundle.database, schema: bundle.schema, table: node.name)
                                }
                                if schemaStore.metaState[key] == nil || schemaStore.metaState[key]?.isLoaded == false {
                                    await schemaStore.loadMeta(database: bundle.database, schema: bundle.schema, table: node.name)
                                }
                            }
                        }
                    }
                    onOpenNodeTab(node, ["kind": "relation", "schema": bundle.schema, "name": node.name])
                } else {
                    onOpenNodeTab(node, ["kind": "properties"])
                }
            } label: {
                HStack(spacing: 8) {
                    if isRelation {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                    } else {
                        Spacer().frame(width: 12)
                    }
                    
                    Image(systemName: "\(symbol).fill")
                        .font(.caption2)
                        .foregroundStyle(MidnightColors.accentCyan)
                    
                    Text(node.name)
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.primary)
                    
                    Spacer()
                    
                    if let rows = node.estimatedRows, rows >= 0 {
                        Text(formatRowCount(rows))
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.02))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if isRelation {
                    Button {
                        onOpenNodeTab(node, ["kind": "relation", "schema": bundle.schema, "name": node.name])
                    } label: {
                        Label("Open Query Workspace", systemImage: "terminal")
                    }
                } else {
                    Button {
                        onOpenNodeTab(node, ["kind": "properties"])
                    } label: {
                        Label("Show Properties", systemImage: "info.circle")
                    }
                }
            }
            
            if isRelation && isExpanded {
                relationChildrenMobileView(database: bundle.database, schema: bundle.schema, table: node.name)
                    .padding(.leading, 32)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func relationChildrenMobileView(
        database: String,
        schema: String,
        table: String
    ) -> some View {
        let key = "\(database).\(schema).\(table)"
        
        VStack(alignment: .leading, spacing: 8) {
            // Columns
            mobileMetaSection(tableKey: key, title: "Columns", state: schemaStore.columnsState[key] ?? .idle) { nodes in
                ForEach(nodes) { col in
                    Button {
                        onOpenNodeTab(col, ["kind": "properties"])
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "list.bullet")
                                .foregroundStyle(.secondary)
                                .font(.caption2)
                            Text(col.name)
                                .font(MidnightMobileDesign.FontToken.caption)
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Keys/Constraints/Triggers
            switch schemaStore.metaState[key] ?? .idle {
            case .idle, .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading metadata...").font(MidnightMobileDesign.FontToken.caption).foregroundStyle(.secondary)
                }
            case .failed(let err):
                Text("Error: \(err)").foregroundStyle(.red).font(MidnightMobileDesign.FontToken.caption)
            case .loaded(let metaNodes):
                let keys = metaNodes.filter { if case .key = $0.kind { return true }; return false }
                let constraints = metaNodes.filter { if case .constraint = $0.kind { return true }; return false }
                let triggers = metaNodes.filter { if case .trigger = $0.kind { return true }; return false }
                
                if !keys.isEmpty {
                    mobileMetaSection(tableKey: key, title: "Keys (\(keys.count))", state: .loaded(keys)) { nodes in
                        ForEach(nodes) { keyNode in
                            Button {
                                onOpenNodeTab(keyNode, ["kind": "properties"])
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "key.fill")
                                        .foregroundStyle(.yellow)
                                        .font(.caption2)
                                    Text(keyNode.name)
                                        .font(MidnightMobileDesign.FontToken.caption)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                
                if !constraints.isEmpty {
                    mobileMetaSection(tableKey: key, title: "Constraints (\(constraints.count))", state: .loaded(constraints)) { nodes in
                        ForEach(nodes) { constNode in
                            Button {
                                onOpenNodeTab(constNode, ["kind": "properties"])
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "lock.shield")
                                        .foregroundStyle(.orange)
                                        .font(.caption2)
                                    Text(constNode.name)
                                        .font(MidnightMobileDesign.FontToken.caption)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                
                if !triggers.isEmpty {
                    mobileMetaSection(tableKey: key, title: "Triggers (\(triggers.count))", state: .loaded(triggers)) { nodes in
                        ForEach(nodes) { trigNode in
                            Button {
                                onOpenNodeTab(trigNode, ["kind": "properties"])
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "bolt.fill")
                                        .foregroundStyle(.cyan)
                                        .font(.caption2)
                                    Text(trigNode.name)
                                        .font(MidnightMobileDesign.FontToken.caption)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
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
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    switch state {
                    case .idle, .loading:
                        ProgressView().controlSize(.small)
                    case .failed(let err):
                        Text("Error: \(err)").foregroundStyle(.red).font(MidnightMobileDesign.FontToken.caption)
                    case .loaded(let nodes):
                        if nodes.isEmpty {
                            Text("(none)")
                                .font(MidnightMobileDesign.FontToken.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 12)
                        } else {
                            content(nodes)
                                .padding(.leading, 12)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
    
    private func formatRowCount(_ rows: Float) -> String {
        let n = Int(rows)
        if n < 1_000 { return "\(n) rows" }
        if n < 1_000_000 { return String(format: "%.1fK rows", rows / 1_000) }
        return String(format: "%.1fM rows", rows / 1_000_000)
    }
}

