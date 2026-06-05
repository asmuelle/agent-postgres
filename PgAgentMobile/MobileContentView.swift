import SwiftUI
import StoreKit
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// MARK: - App Color Palette
enum MidnightColors {
    static let primaryBackground = Color(red: 0.05, green: 0.05, blue: 0.08)
    static let cardBackground = Color(red: 0.10, green: 0.10, blue: 0.14)
    static let accentCyan = Color(red: 0.15, green: 0.75, blue: 0.85)
    static let accentPurple = Color(red: 0.55, green: 0.35, blue: 0.85)
    static let borderGray = Color(red: 0.20, green: 0.20, blue: 0.26)
    
    static func glowGradient() -> LinearGradient {
        LinearGradient(
            colors: [accentCyan.opacity(0.15), accentPurple.opacity(0.15)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

@MainActor
fileprivate final class MobileStoreCache {
    static var schemaStores: [String: PgSchemaStore] = [:]
    static var queryStores: [String: PostgresQueryTabsStore] = [:]
}

// MARK: - Main Mobile Content View
struct MobileContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var profileStore: PostgresProfileStore
    @EnvironmentObject private var entitlementsStore: MobileEntitlementsStore
    
    // Top-Level Active State Shared Per Profile
    @State private var selectedProfileId: String?
    @State private var activeConnections: [String: String] = [:] // profileId -> connectionId
    
    // Unified Object Explorer node selection bindings
    @State private var selectedNodeId: String? = nil
    @State private var selectedNode: PgSchemaNode? = nil
    
    @State private var editingProfile: PostgresProfile?
    @State private var creatingProfile = false
    @State private var showingProUpgrade = false
    @State private var showingCSVImport = false
    
    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $creatingProfile) {
            PostgresMobileConnectionEditView(profile: nil) { newProfile in
                profileStore.saveOrUpdate(newProfile)
                creatingProfile = false
                selectedProfileId = newProfile.id
            }
        }
        .sheet(item: $editingProfile) { profile in
            PostgresMobileConnectionEditView(profile: profile) { updatedProfile in
                profileStore.saveOrUpdate(updatedProfile)
                editingProfile = nil
            }
        }
        .sheet(isPresented: $showingProUpgrade) {
            MobileProUpgradeView(currentSavedHosts: profileStore.profiles.count)
                .environmentObject(entitlementsStore)
        }
        .sheet(isPresented: $showingCSVImport) {
            ConnectionCSVImportView { importedProfiles in
                for p in importedProfiles {
                    profileStore.saveOrUpdate(p)
                }
                showingCSVImport = false
            }
        }
        // Properties sheet removed to present all node details directly in the main query workspace pane.
    }
    
    // MARK: - iPadOS Two-Pane Adaptive Split Layout
    private var regularLayout: some View {
        NavigationSplitView {
            MobileObjectExplorerView(
                selectedProfileId: $selectedProfileId,
                selectedNodeId: $selectedNodeId,
                selectedNode: $selectedNode,
                onAddProfile: handleAddProfile,
                onEditProfile: { p in editingProfile = p },
                onShowCSVImport: { showingCSVImport = true },
                onOpenNodeTab: { profile, node, details in
                    let qStore = queryStore(forProfileId: profile.id)
                    let kind = details["kind"] ?? ""
                    let schema = details["schema"] ?? ""
                    let name = details["name"] ?? ""
                    
                    switch kind {
                    case "relation":
                        qStore.openRelationTab(schema: schema, name: name)
                    case "routine":
                        let signature = details["signature"] ?? ""
                        qStore.openRoutineTab(schema: schema, name: name, signature: signature)
                    case "sequence":
                        qStore.openSequenceTab(schema: schema, name: name)
                    case "objectType":
                        let typeKind = details["typeKind"] ?? ""
                        qStore.openObjectTypeTab(schema: schema, name: name, typeKind: typeKind)
                    case "properties":
                        qStore.openPropertyTab(node: node)
                    default:
                        break
                    }
                }
            )
            .navigationTitle("Object Explorer")
        } detail: {
            if let profileId = selectedProfileId,
               let profile = profileStore.profiles.first(where: { $0.id == profileId }) {
                
                // Tabbed SQL Query Workspace & Results
                MobileProfileWorkspaceView(
                    profile: profile,
                    connectionId: binding(forProfileId: profileId),
                    schemaStore: schemaStore(forProfileId: profileId, connectionId: activeConnections[profileId]),
                    queryStore: queryStore(forProfileId: profileId),
                    onConnectSuccess: { connId in
                        activeConnections[profileId] = connId
                    },
                    forceRegularMode: true
                )
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "cylinder.split.1x2.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(MidnightColors.borderGray)
                    Text("Select a Database Server")
                        .font(MidnightMobileDesign.FontToken.headline)
                        .foregroundStyle(.primary)
                    Text("Select or expand a server in the Object Explorer sidebar to begin.")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MidnightColors.primaryBackground)
            }
        }
    }
    
    // MARK: - iOS Compact NavigationStack Layout
    private var compactLayout: some View {
        NavigationStack {
            MobileConnectionListView(
                selectedProfileId: $selectedProfileId,
                onAddProfile: handleAddProfile,
                onEditProfile: { p in editingProfile = p },
                onShowCSVImport: { showingCSVImport = true },
                onShowProUpgrade: { showingProUpgrade = true }
            )
            .navigationTitle("pgAgent")
            .navigationDestination(item: $selectedProfileId) { profileId in
                if let profile = profileStore.profiles.first(where: { $0.id == profileId }) {
                    MobileProfileWorkspaceView(
                        profile: profile,
                        connectionId: binding(forProfileId: profileId),
                        schemaStore: schemaStore(forProfileId: profileId, connectionId: activeConnections[profileId]),
                        queryStore: queryStore(forProfileId: profileId),
                        onConnectSuccess: { connId in
                            activeConnections[profileId] = connId
                        },
                        forceRegularMode: false
                    )
                }
            }
        }
    }
    
    // MARK: - Helpers
    private func handleAddProfile() {
        if entitlementsStore.canCreateConnection(currentCount: profileStore.profiles.count) {
            creatingProfile = true
        } else {
            showingProUpgrade = true
        }
    }
    
    private func binding(forProfileId profileId: String) -> Binding<String?> {
        Binding(
            get: { activeConnections[profileId] },
            set: { activeConnections[profileId] = $0 }
        )
    }
    
    private func schemaStore(forProfileId profileId: String, connectionId: String?) -> PgSchemaStore? {
        guard let connId = connectionId else { return nil }
        if let existing = MobileStoreCache.schemaStores[profileId], existing.connectionId == connId {
            return existing
        }
        let newStore = PgSchemaStore(connectionId: connId)
        MobileStoreCache.schemaStores[profileId] = newStore
        return newStore
    }
    
    private func queryStore(forProfileId profileId: String) -> PostgresQueryTabsStore {
        if let existing = MobileStoreCache.queryStores[profileId] {
            return existing
        }
        let newStore = PostgresQueryTabsStore()
        newStore.openBlankTab()
        MobileStoreCache.queryStores[profileId] = newStore
        return newStore
    }
}

// MARK: - Profile ID Navigation extension
extension String: Identifiable {
    public var id: String { self }
}

// MARK: - Connection List View
struct MobileConnectionListView: View {
    @Binding var selectedProfileId: String?
    var onAddProfile: () -> Void
    var onEditProfile: (PostgresProfile) -> Void
    var onShowCSVImport: () -> Void
    var onShowProUpgrade: () -> Void
    
    @EnvironmentObject private var profileStore: PostgresProfileStore
    @EnvironmentObject private var entitlementsStore: MobileEntitlementsStore
    @ObservedObject private var statusStore = PostgresConnectionStatusStore.shared
    
    @State private var searchField: String = ""
    
    private var filteredProfiles: [PostgresProfile] {
        let needle = searchField.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty {
            return profileStore.profiles
        }
        return profileStore.profiles.filter {
            $0.name.lowercased().contains(needle) ||
            $0.host.lowercased().contains(needle) ||
            $0.database.lowercased().contains(needle)
        }
    }
    
    private var folderGroups: [String: [PostgresProfile]] {
        Dictionary(grouping: filteredProfiles) { profile in
            profile.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? profile.folderPath!
                : "Unfiled Favorites"
        }
    }
    
    var body: some View {
        ZStack {
            MidnightColors.primaryBackground.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Search Bar
                searchBar
                
                if filteredProfiles.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(folderGroups.keys.sorted(), id: \.self) { folderName in
                            Section(header: Text(folderName).font(MidnightMobileDesign.FontToken.label).foregroundStyle(MidnightColors.accentCyan)) {
                                ForEach(folderGroups[folderName] ?? []) { profile in
                                    profileRow(profile)
                                        .listRowBackground(MidnightColors.cardBackground)
                                        .listRowSeparatorTint(MidnightColors.borderGray)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
                
                // Bottom Pro Upgrade Gating banner
                proGatingBanner
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    Button(action: onShowCSVImport) {
                        Label("Import CSV", systemImage: "square.and.arrow.down")
                    }
                    Button(action: onAddProfile) {
                        Label("Add Profile", systemImage: "plus")
                    }
                }
            }
        }
    }
    
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search hosts or databases...", text: $searchField)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchField.isEmpty {
                Button(action: { searchField = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(MidnightColors.borderGray, lineWidth: 1))
        .padding()
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.system(size: 48))
                .foregroundStyle(MidnightColors.borderGray)
            Text("No Database Connections")
                .font(MidnightMobileDesign.FontToken.headline)
            Text("Tap the + button to save your first Postgres profile, or import a CSV profile list.")
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxHeight: .infinity)
    }
    
    private func environmentBadgeColor(_ profile: PostgresProfile) -> Color? {
        switch profile.color {
        case "production": return .red
        case "development": return .green
        case "testing": return .yellow
        default: return nil
        }
    }

    private func environmentBadgeLabel(_ profile: PostgresProfile) -> String? {
        switch profile.color {
        case "production": return "PROD"
        case "development": return "DEV"
        case "testing": return "TEST"
        default: return nil
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: PostgresProfile) -> some View {
        let status = statusStore.statusByProfile[profile.id] ?? .disconnected
        
        Button {
            selectedProfileId = profile.id
        } label: {
            HStack(spacing: 14) {
                // Connection indicator
                Circle()
                    .fill(MidnightMobileDesign.statusColor(status))
                    .frame(width: 8, height: 8)
                    .shadow(color: MidnightMobileDesign.statusColor(status).opacity(0.5), radius: 4)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(MidnightMobileDesign.FontToken.label)
                            .foregroundStyle(.primary)
                        
                        if let envColor = environmentBadgeColor(profile), let envLabel = environmentBadgeLabel(profile) {
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
                Spacer()
                
                // Ellipsis settings action
                Menu {
                    Button {
                        onEditProfile(profile)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button {
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
                    } label: {
                        Label("Duplicate", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        profileStore.delete(profile)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .midnightMobileMinimumTapTarget()
        }
        .buttonStyle(.plain)
    }
    
    private var proGatingBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entitlementsStore.isPro ? "PRO LIFETIME ACTIVE" : "FREE PLAN LIMIT")
                    .font(MidnightMobileDesign.FontToken.captionStrong)
                    .foregroundStyle(entitlementsStore.isPro ? MidnightColors.accentCyan : .orange)
                Text(entitlementsStore.limitSummary)
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !entitlementsStore.isPro {
                Button(action: onShowProUpgrade) {
                    Text("Unlock Pro")
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            LinearGradient(
                                colors: [MidnightColors.accentCyan, MidnightColors.accentPurple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.3))
        .overlay(Rectangle().stroke(MidnightColors.borderGray, margins: 0))
    }
}

// Custom stroke helper
extension View {
    func stroke(_ color: Color, margins: CGFloat) -> some View {
        overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(color),
            alignment: .top
        )
    }
}

// MARK: - Workspace Detail Workspace View
struct MobileProfileWorkspaceView: View {
    let profile: PostgresProfile
    @Binding var connectionId: String?
    let schemaStore: PgSchemaStore?
    let queryStore: PostgresQueryTabsStore
    var onConnectSuccess: (String) -> Void
    var forceRegularMode: Bool
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var connectionError: String?
    @State private var isConnecting = false
    
    // Segment tab state for compact iOS screens
    @State private var compactTabSelected: Int = 1 // 0: Explorer, 1: Query, 2: Console
    
    var body: some View {
        ZStack {
            MidnightColors.primaryBackground.ignoresSafeArea()
            
            if isConnecting {
                connectingOverlay
            } else if let error = connectionError {
                connectionErrorPanel(error)
            } else if connectionId != nil, let store = schemaStore {
                if horizontalSizeClass == .compact && !forceRegularMode {
                    // iPhone Tabbed Workspace
                    VStack(spacing: 0) {
                        customSegmentControl
                        Divider().background(MidnightColors.borderGray)
                        
                        TabView(selection: $compactTabSelected) {
                            MobileSchemaBrowserView(
                                profile: profile,
                                connectionId: $connectionId,
                                schemaStore: store,
                                onOpenNodeTab: { node, details in
                                    let kind = details["kind"] ?? ""
                                    if kind == "relation" {
                                        let schema = details["schema"] ?? ""
                                        let name = details["name"] ?? ""
                                        queryStore.openRelationTab(schema: schema, name: name)
                                    } else if kind == "properties" {
                                        queryStore.openPropertyTab(node: node)
                                    }
                                    // Smoothly snap to SQL/Properties tab on select
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                        compactTabSelected = 1
                                    }
                                }
                            )
                            .tag(0)
                            
                            MobileQueryWorkspaceView(
                                store: queryStore,
                                connectionId: connectionId,
                                profileId: profile.id,
                                schemaStore: store
                            )
                            .tag(1)
                            
                            MobileConsoleMetricsView(
                                profileId: profile.id,
                                queryStore: queryStore
                            )
                            .tag(2)
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                    }
                } else {
                    // iPadOS/Regular Full screen Query workspace
                    MobileQueryWorkspaceView(
                        store: queryStore,
                        connectionId: connectionId,
                        profileId: profile.id,
                        schemaStore: store
                    )
                }
            } else {
                Color.clear
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(connectionId != nil ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(profile.name)
                        .font(MidnightMobileDesign.FontToken.label)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { Task { await disconnect() } }) {
                    Text("Disconnect")
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                        .foregroundStyle(.red)
                }
            }
        }
        .task {
            await connectIfNeeded()
        }
    }
    
    // Custom Segmented Pill Control with Premium aesthetics
    private var customSegmentControl: some View {
        HStack(spacing: 4) {
            segmentButton("Explorer", index: 0, icon: "cylinder.split.1x2")
            segmentButton("Query", index: 1, icon: "terminal")
            segmentButton("Console", index: 2, icon: "chart.bar")
        }
        .padding(4)
        .background(Color.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(MidnightColors.borderGray, lineWidth: 1))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private func segmentButton(_ title: String, index: Int, icon: String) -> some View {
        let isSelected = compactTabSelected == index
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                compactTabSelected = index
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(title)
                    .font(MidnightMobileDesign.FontToken.captionStrong)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(isSelected ? MidnightColors.accentCyan.opacity(0.15) : Color.clear)
            .foregroundStyle(isSelected ? MidnightColors.accentCyan : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
    
    private var connectingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(MidnightColors.accentCyan)
            Text("Establishing Postgres Session...")
                .font(MidnightMobileDesign.FontToken.label)
                .foregroundStyle(MidnightColors.accentCyan)
            Text("\(profile.user)@\(profile.host)")
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private func connectionErrorPanel(_ msg: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Connection Failed")
                .font(MidnightMobileDesign.FontToken.headline)
            Text(msg)
                .font(MidnightMobileDesign.FontToken.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            
            HStack(spacing: 16) {
                Button(action: {
                    dismiss()
                }) {
                    Text("Go Back")
                        .font(MidnightMobileDesign.FontToken.label)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    Task { await connectIfNeeded(force: true) }
                }) {
                    Text("Retry")
                        .font(MidnightMobileDesign.FontToken.label)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(MidnightColors.accentCyan)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // Database connection trigger
    private func connectIfNeeded(force: Bool = false) async {
        if !force && (connectionId != nil || isConnecting) { return }
        isConnecting = true
        connectionError = nil
        PostgresConnectionStatusStore.shared.markConnecting(profileId: profile.id)
        
        do {
            let id = try await BridgeManager.shared.pgConnect(profile: profile)
            onConnectSuccess(id)
            connectionId = id
            
            PostgresConnectionStatusStore.shared.markConnected(profileId: profile.id)
            await PostgresProfileStore.shared.markConnected(profile)
        } catch {
            connectionError = error.localizedDescription
            PostgresConnectionStatusStore.shared.markError(error.localizedDescription, profileId: profile.id)
        }
        isConnecting = false
    }
    
    private func disconnect() async {
        guard let id = connectionId else { return }
        isConnecting = true
        await BridgeManager.shared.pgDisconnect(connectionId: id)
        connectionId = nil
        PostgresConnectionStatusStore.shared.markDisconnected(profileId: profile.id)
        isConnecting = false
        dismiss()
    }
}

// MARK: - Schema Browser View
struct MobileSchemaBrowserView: View {
    let profile: PostgresProfile
    @Binding var connectionId: String?
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

// MARK: - Query Workspace View
struct MobileQueryWorkspaceView: View {
    @ObservedObject var store: PostgresQueryTabsStore
    let connectionId: String?
    let profileId: String
    let schemaStore: PgSchemaStore?
    
    @State private var runTask: Task<Void, Never>?
    @State private var executionDuration: TimeInterval = 0
    @State private var showSQLToolbar = true

    private var profile: PostgresProfile? {
        PostgresProfileStore.shared.profile(withId: profileId)
    }

    private var environmentColor: Color? {
        guard let p = profile else { return nil }
        switch p.color {
        case "production": return .red
        case "development": return .green
        case "testing": return .yellow
        default: return nil
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if let envColor = environmentColor {
                Rectangle()
                    .fill(envColor)
                    .frame(height: 2)
            }

            // Tab Header Strip
            queryTabHeaderStrip
            
            Divider().background(MidnightColors.borderGray)
            
            if let activeId = store.activeTabId,
               let tab = store.tabs.first(where: { $0.id == activeId }) {
                
                switch tab.kind {
                case .properties(let node):
                    if let sStore = schemaStore {
                        MobilePropertyInspectorView(
                            node: node,
                            connectionId: connectionId,
                            schemaStore: sStore,
                            onClose: {
                                store.closeTab(id: tab.id)
                            }
                        )
                    } else {
                        Text("No schema store available")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                default:
                    // Editor Panel
                    ZStack(alignment: .bottom) {
                        VStack(spacing: 0) {
                            TextEditor(text: Binding(
                                get: { tab.sql },
                                set: { store.setSQL($0, forTab: activeId) }
                            ))
                            .font(.system(size: 15, design: .monospaced))
                            .padding(8)
                            .background(Color.black.opacity(0.2))
                            .keyboardType(.asciiCapable)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            
                            // SQL quick assistants toolbar
                            if showSQLToolbar {
                                sqlQuickBar(tabId: activeId, currentSQL: tab.sql)
                            }
                        }
                        
                        // Glassmorphic status / play / cancel pill
                        floatingActionBar(tab: tab)
                            .padding(.bottom, 12)
                    }
                    .frame(maxHeight: 280)
                    
                    Divider().background(MidnightColors.borderGray)
                    
                    // Collapsible results display pane
                    resultsDisplayPane(tab: tab)
                }
            } else {
                emptyTabArea
            }
        }
        .background(MidnightColors.primaryBackground)
    }
    
    private var queryTabHeaderStrip: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.tabs) { tab in
                        let isActive = tab.id == store.activeTabId
                        HStack(spacing: 6) {
                            Text(tab.title)
                                .font(MidnightMobileDesign.FontToken.captionStrong)
                                .foregroundStyle(isActive ? MidnightColors.accentCyan : .secondary)
                            
                            Button {
                                closeTab(tab)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isActive ? MidnightColors.accentCyan.opacity(0.12) : Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isActive ? MidnightColors.accentCyan : MidnightColors.borderGray, lineWidth: 1))
                        .onTapGesture {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                store.setActive(tab.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            
            Button {
                store.openBlankTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(MidnightColors.accentCyan)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.04))
                    .clipShape(Circle())
                    .padding(.trailing, 8)
            }
            .buttonStyle(.plain)
        }
        .background(Color.black.opacity(0.3))
    }
    
    @ViewBuilder
    private func sqlQuickBar(tabId: UUID, currentSQL: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sqlHelperButton("SELECT *", tabId: tabId, current: currentSQL)
                sqlHelperButton("FROM", tabId: tabId, current: currentSQL)
                sqlHelperButton("WHERE", tabId: tabId, current: currentSQL)
                sqlHelperButton("LIMIT 100", tabId: tabId, current: currentSQL)
                sqlHelperButton("ORDER BY", tabId: tabId, current: currentSQL)
                sqlHelperButton("COUNT(*)", tabId: tabId, current: currentSQL)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color.black.opacity(0.4))
    }
    
    @ViewBuilder
    private func sqlHelperButton(_ keyword: String, tabId: UUID, current: String) -> some View {
        Button {
            let space = current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("\n") ? "" : " "
            store.setSQL(current + space + keyword + " ", forTab: tabId)
        } label: {
            Text(keyword)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(MidnightColors.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(MidnightColors.borderGray, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private func floatingActionBar(tab: PostgresQueryTab) -> some View {
        HStack(spacing: 12) {
            switch tab.execState {
            case .running:
                Button {
                    runTask?.cancel()
                    if let connId = connectionId {
                        Task {
                            _ = await BridgeManager.shared.pgCancel(
                                connectionId: connId,
                                sessionId: tab.id.uuidString
                            )
                        }
                    }
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                        .foregroundStyle(.red)
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            default:
                Button {
                    executeSQL(tab: tab)
                } label: {
                    Label("Execute", systemImage: "play.fill")
                        .foregroundStyle(.black)
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(MidnightColors.accentCyan)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(tab.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(MidnightColors.borderGray, lineWidth: 1))
        .shadow(radius: 8)
    }
    
    @ViewBuilder
    private func resultsDisplayPane(tab: PostgresQueryTab) -> some View {
        ZStack {
            MidnightColors.primaryBackground.ignoresSafeArea()
            
            switch tab.execState {
            case .idle:
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Ready to execute query")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                }
            case .running:
                VStack(spacing: 16) {
                    ProgressView().tint(MidnightColors.accentCyan)
                    Text("Fetching query rows...")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                }
            case .completed(let elapsed, _):
                if let result = tab.lastResult {
                    MobileResultsGridView(
                        columns: result.columns,
                        rows: result.rows,
                        elapsed: elapsed,
                        hasMore: tab.hasMore,
                        pendingEdits: tab.pendingEdits,
                        onLoadMore: {
                            loadMoreRows(tab: tab)
                        }
                    )
                } else {
                    Text("Command executed successfully. No rows returned.")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let msg, _):
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ERROR")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.red)
                        Text(msg)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.2), lineWidth: 1))
                    .padding()
                }
            case .cancelled:
                Text("Execution cancelled.")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var emptyTabArea: some View {
        VStack {
            Text("No open tabs. Tap + to draft a query.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func closeTab(_ tab: PostgresQueryTab) {
        if let connId = connectionId {
            let sessionId = tab.id.uuidString
            let cursorId = tab.lastResult?.cursorId
            Task {
                if case .running = tab.execState {
                    _ = await BridgeManager.shared.pgCancel(connectionId: connId, sessionId: sessionId)
                }
                if let cursorId {
                    _ = await BridgeManager.shared.pgCloseQuery(connectionId: connId, sessionId: sessionId, cursorId: cursorId)
                }
                _ = await BridgeManager.shared.pgReleaseSession(connectionId: connId, sessionId: sessionId)
            }
        }
        store.closeTab(id: tab.id)
        if store.tabs.isEmpty {
            store.openBlankTab()
        }
    }
    
    private func executeSQL(tab: PostgresQueryTab) {
        guard let connId = connectionId else { return }
        let trimmed = tab.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        runTask?.cancel()
        let started = Date()
        store.setExecState(.running(startedAt: started), forTab: tab.id)
        
        let tabId = tab.id
        let sessionId = tab.id.uuidString
        let pageSize = store.pageSize
        
        runTask = Task { @MainActor in
            do {
                let result = try await BridgeManager.shared.pgExecute(
                    connectionId: connId,
                    sessionId: sessionId,
                    sql: trimmed,
                    pageSize: pageSize
                )
                let elapsed = Date().timeIntervalSince(started)
                guard !Task.isCancelled else {
                    store.setExecState(.cancelled(elapsed: elapsed), forTab: tabId)
                    return
                }
                store.setResult(result, forTab: tabId)
                store.setExecState(.completed(elapsed: elapsed, atTime: Date()), forTab: tabId)
                
                // Save to execution logs
                let rowsReturned = result.columns.isEmpty ? nil : result.rows.count
                PostgresHistoryStore.shared.record(
                    profileId: profileId,
                    sql: trimmed,
                    durationMs: UInt32(min(elapsed * 1000, Double(UInt32.max))),
                    rowsReturned: rowsReturned
                )
            } catch {
                let elapsed = Date().timeIntervalSince(started)
                store.setExecState(.failed(message: error.localizedDescription, elapsed: elapsed), forTab: tabId)
            }
        }
    }
    
    private func loadMoreRows(tab: PostgresQueryTab) {
        guard let connId = connectionId,
              let result = tab.lastResult,
              let cursorId = result.cursorId else { return }
        
        store.setLoadingMore(true, forTab: tab.id)
        let tabId = tab.id
        let sessionId = tab.id.uuidString
        
        Task { @MainActor in
            do {
                let page = try await BridgeManager.shared.pgFetchPage(
                    connectionId: connId,
                    sessionId: sessionId,
                    cursorId: cursorId,
                    count: store.pageSize
                )
                store.appendPage(page, forTab: tabId)
            } catch {
                store.setPaginationError(error.localizedDescription, forTab: tabId)
            }
        }
    }
}

// MARK: - Results Grid Cell View
struct MobileResultsGridCellView: View {
    let cell: String?
    let rIdx: Int
    let cIdx: Int
    let pendingEdits: [PostgresPendingEditKey: PostgresPendingEdit]

    private var isStaged: Bool {
        let key = PostgresPendingEditKey(rowIndex: rIdx, columnIndex: cIdx)
        return pendingEdits[key] != nil
    }
    
    var body: some View {
        Text(cell ?? "NULL")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(cell == nil ? Color.secondary.opacity(0.5) : Color.primary)
            .lineLimit(1)
            .frame(width: 140, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isStaged
                    ? MidnightColors.accentCyan.opacity(0.18)
                    : (rIdx % 2 == 0 ? Color.black.opacity(0.1) : Color.white.opacity(0.02))
            )
            .border(MidnightColors.borderGray, width: 0.5)
    }
}

// MARK: - Results Grid Row View
struct MobileResultsGridRowView: View {
    let rIdx: Int
    let row: FfiPgRow
    let pendingEdits: [PostgresPendingEditKey: PostgresPendingEdit]
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array<Int>(0..<row.cells.count), id: \.self) { cIdx in
                MobileResultsGridCellView(cell: row.cells[cIdx], rIdx: rIdx, cIdx: cIdx, pendingEdits: pendingEdits)
            }
        }
    }
}

// MARK: - Results Grid View
struct MobileResultsGridView: View {
    let columns: [FfiPgColumn]
    let rows: [FfiPgRow]
    let elapsed: TimeInterval
    let hasMore: Bool
    let pendingEdits: [PostgresPendingEditKey: PostgresPendingEdit]
    var onLoadMore: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Metrics Banner
            HStack {
                Label("\(rows.count) rows fetched", systemImage: "tablecells")
                Spacer()
                Text(String(format: "%.0f ms", elapsed * 1000))
                    .monospacedDigit()
            }
            .font(MidnightMobileDesign.FontToken.captionStrong)
            .foregroundStyle(MidnightColors.accentCyan)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.3))
            
            Divider().background(MidnightColors.borderGray)
            
            // Grid Canvas
            if rows.isEmpty {
                VStack {
                    Spacer()
                    Text("No results to display")
                        .foregroundStyle(.secondary)
                        .font(MidnightMobileDesign.FontToken.caption)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Header Row
                        HStack(spacing: 0) {
                            ForEach(columns, id: \.name) { col in
                                Text(col.name)
                                    .font(MidnightMobileDesign.FontToken.captionStrong)
                                    .foregroundStyle(MidnightColors.accentCyan)
                                    .lineLimit(1)
                                    .frame(width: 140, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(MidnightColors.cardBackground)
                                    .border(MidnightColors.borderGray, width: 0.5)
                            }
                        }
                        
                        // Data Rows
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(0..<rows.count, id: \.self) { rIdx in
                                MobileResultsGridRowView(rIdx: rIdx, row: rows[rIdx], pendingEdits: pendingEdits)
                            }
                            
                            // Load more indicator
                            if hasMore {
                                Button(action: onLoadMore) {
                                    HStack {
                                        Spacer()
                                        Label("Load More Pages", systemImage: "arrow.down.circle")
                                            .font(MidnightMobileDesign.FontToken.captionStrong)
                                            .foregroundStyle(MidnightColors.accentCyan)
                                            .padding()
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                                .frame(height: 50)
                            }
                        }
                    }
                }
            }
        }
        .background(MidnightColors.primaryBackground)
    }
}

// MARK: - Console Metrics View
struct MobileConsoleMetricsView: View {
    let profileId: String
    let queryStore: PostgresQueryTabsStore
    
    @State private var logs: [PostgresHistoryEntry] = []
    
    var body: some View {
        ZStack {
            MidnightColors.primaryBackground.ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Execution History")
                        .font(MidnightMobileDesign.FontToken.label)
                        .foregroundStyle(MidnightColors.accentCyan)
                        .padding(.horizontal)
                        .padding(.top)
                    
                    if logs.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("No executed queries logged")
                                .font(MidnightMobileDesign.FontToken.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(logs) { record in
                                logRecordView(record)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
        .onAppear {
            loadLogs()
        }
    }
    
    @ViewBuilder
    private func logRecordView(_ record: PostgresHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.executedAt, style: .time)
                    .font(MidnightMobileDesign.FontToken.captionStrong)
                    .foregroundStyle(.secondary)
                Spacer()
                if let duration = record.durationMs {
                    Text("\(duration) ms")
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                        .foregroundStyle(MidnightColors.accentCyan)
                }
            }
            Text(record.sql)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)
            
            if let rows = record.rowsReturned {
                Text("\(rows) rows returned")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(MidnightColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(MidnightColors.borderGray, lineWidth: 1))
    }
    
    private func loadLogs() {
        logs = PostgresHistoryStore.shared.entries(forProfile: profileId)
    }
}

// MARK: - CSV Text Paste/Import Sheet
struct ConnectionCSVImportView: View {
    @Environment(\.dismiss) private var dismiss
    var onImport: ([PostgresProfile]) -> Void
    
    @State private var csvText = ""
    @State private var parsedProfiles: [PostgresProfile] = []
    @State private var validationMessage: String?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Paste connection details below in CSV format:")
                    .font(MidnightMobileDesign.FontToken.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                
                Text("Format: `name,host,port,database,username,password`")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                
                TextEditor(text: $csvText)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(8)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(MidnightColors.borderGray, lineWidth: 1))
                    .padding(.horizontal)
                    .onChange(of: csvText) { _ in
                        validateCSV()
                    }
                
                if let msg = validationMessage {
                    Text(msg)
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }
                
                if !parsedProfiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ready to import \(parsedProfiles.count) profiles:")
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .foregroundStyle(.green)
                        
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(parsedProfiles, id: \.name) { p in
                                    Text("• \(p.name) (\(p.host))")
                                        .font(MidnightMobileDesign.FontToken.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxHeight: 100)
                    }
                    .padding()
                    .background(MidnightColors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
                }
                
                Spacer()
            }
            .padding(.top)
            .background(MidnightColors.primaryBackground)
            .navigationTitle("Import CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        onImport(parsedProfiles)
                    }
                    .disabled(parsedProfiles.isEmpty)
                }
            }
        }
    }
    
    private func validateCSV() {
        parsedProfiles = []
        validationMessage = nil
        let lines = csvText.components(separatedBy: .newlines)
        
        var temp: [PostgresProfile] = []
        for line in lines {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 5 else { continue }
            
            let name = parts[0]
            let host = parts[1]
            let portStr = parts[2]
            let database = parts[3]
            let user = parts[4]
            let port = UInt16(portStr) ?? 5432
            
            guard !name.isEmpty && !host.isEmpty && !database.isEmpty && !user.isEmpty else { continue }
            
            let profile = PostgresProfile(
                name: name,
                host: host,
                port: port,
                database: database,
                user: user,
                auth: .keychain
            )
            temp.append(profile)
        }
        
        if !temp.isEmpty {
            parsedProfiles = temp
            validationMessage = "Successfully parsed \(temp.count) entries."
        } else if !csvText.isEmpty {
            validationMessage = "No valid lines parsed. Make sure to specify name, host, port, database, username."
        }
    }
}
