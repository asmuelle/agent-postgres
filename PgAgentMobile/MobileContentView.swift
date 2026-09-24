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
    // Connection + schema state now lives in PostgresConnectionManager.shared
    // (the single source of truth, shared with the sidebar and macOS). Only
    // per-profile query-tab state — which is UI state, not a connection —
    // persists here across view recreations.
    static var queryStores: [String: PostgresQueryTabsStore] = [:]
}

// MARK: - Main Mobile Content View
struct MobileContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var profileStore: PostgresProfileStore
    @EnvironmentObject private var entitlementsStore: MobileEntitlementsStore
    @EnvironmentObject private var alertRouter: MobileAlertRouter

    // Top-Level Active State Shared Per Profile
    @State private var selectedProfileId: String?
    // Connection + schema state comes from the shared manager; observing it
    // keeps the layout in sync as connections open/close from any surface.
    @ObservedObject private var connectionManager = PostgresConnectionManager.shared

    // Unified Object Explorer node selection bindings
    @State private var selectedNodeId: String? = nil
    @State private var selectedNode: PgSchemaNode? = nil
    
    @State private var editingProfile: PostgresProfile?
    @State private var creatingProfile = false
    @State private var showingProUpgrade = false
    @State private var showingCSVImport = false
    @State private var showingFleetMonitor = false
    @State private var showingProviderImport = false
    @State private var showingSSHIdentities = false
    // iPad sidebar visibility, driven by ⌘⇧E (MobileKeyboardCommands).
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

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
        .sheet(isPresented: $showingFleetMonitor) {
            MobileFleetMonitorView()
                .environmentObject(profileStore)
        }
        .sheet(isPresented: $showingProviderImport) {
            MobileProviderImportView()
                .environmentObject(profileStore)
        }
        .sheet(isPresented: $showingSSHIdentities) {
            MobileSSHIdentityListView()
        }
        // Alert-notification deep link: tapping a fleet alert (Mac-hub push or
        // local BGAppRefresh notification) lands on the monitoring surface.
        // This view only presents the fleet monitor; MobileFleetMonitorView
        // consumes the route by pushing the instance detail on the tab that
        // matches the alert kind (locks / activity / fleet overview).
        // `initial: true` also consumes a route set before the view existed
        // (cold launch from a notification).
        .onChange(of: alertRouter.pendingRoute, initial: true) { _, route in
            guard let route else { return }
            guard profileStore.profiles.contains(where: { $0.id == route.instanceId }) else {
                // Profile was deleted since the alert fired — drop the route
                // so it can't fire against an unrelated future selection.
                alertRouter.pendingRoute = nil
                return
            }
            showingFleetMonitor = true
        }
        .onReceive(MobileShortcutRelay.shared.actions) { action in
            guard action == .toggleSidebar, horizontalSizeClass != .compact else { return }
            withAnimation {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }
        // Properties sheet removed to present all node details directly in the main query workspace pane.
    }
    
    // MARK: - iPadOS Two-Pane Adaptive Split Layout
    private var regularLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
                        // Kind-aware so views/foreign tables get a
                        // ctid-free SELECT (no ctid on those).
                        qStore.openRelationTab(
                            schema: schema,
                            name: name,
                            relationKind: connectionManager.schemaStores[profile.id]?
                                .relationDisplayKind(schema: schema, name: name)
                        )
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingFleetMonitor = true } label: {
                        Label("Fleet Monitor", systemImage: "waveform.path.ecg")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingProviderImport = true } label: {
                        Label("Add from Provider", systemImage: "cloud")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingSSHIdentities = true } label: {
                        Label("SSH Identities", systemImage: "key.horizontal")
                    }
                }
            }
        } detail: {
            if let profileId = selectedProfileId,
               let profile = profileStore.profiles.first(where: { $0.id == profileId }) {
                
                // Tabbed SQL Query Workspace & Results
                MobileProfileWorkspaceView(
                    profile: profile,
                    queryStore: queryStore(forProfileId: profileId),
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
                onShowProviderImport: { showingProviderImport = true },
                onShowProUpgrade: { showingProUpgrade = true },
                onShowMonitor: { showingFleetMonitor = true },
                onShowSSHIdentities: { showingSSHIdentities = true }
            )
            .navigationTitle("pgAgent")
            .navigationDestination(item: $selectedProfileId) { profileId in
                if let profile = profileStore.profiles.first(where: { $0.id == profileId }) {
                    MobileProfileWorkspaceView(
                        profile: profile,
                        queryStore: queryStore(forProfileId: profileId),
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
extension String: @retroactive Identifiable {
    public var id: String { self }
}

