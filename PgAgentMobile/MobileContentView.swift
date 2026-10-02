import SwiftUI
import StoreKit
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

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
            switch action {
            case .newConnection:
                handleAddProfile()
            case .toggleSidebar where horizontalSizeClass != .compact:
                withAnimation {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            default:
                break
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
                onEditProfile: { p in editingProfile = p },
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
            .navigationTitle("Databases")
            // The sidebar column is too narrow for the title plus three
            // toolbar items ("Datab…"); keep the title for accessibility and
            // window naming, but don't draw it — the rows speak for themselves.
            .toolbar(removing: .title)
            .toolbar { MobileLibraryToolbar(actions: libraryActions, isPro: entitlementsStore.isPro) }
        } detail: {
            if let profileId = selectedProfileId,
               let profile = profileStore.profiles.first(where: { $0.id == profileId }) {

                // Tabbed SQL Query Workspace & Results
                MobileProfileWorkspaceView(
                    profile: profile,
                    queryStore: queryStore(forProfileId: profileId),
                    forceRegularMode: true
                )
            } else if profileStore.profiles.isEmpty {
                MobileNoConnectionsView(actions: libraryActions)
            } else {
                ContentUnavailableView(
                    "Choose a Database",
                    systemImage: "cylinder.split.1x2",
                    description: Text("Pick a connection in the sidebar.")
                )
            }
        }
    }

    // MARK: - iOS Compact NavigationStack Layout
    private var compactLayout: some View {
        NavigationStack {
            MobileConnectionListView(
                selectedProfileId: $selectedProfileId,
                actions: libraryActions,
                onEditProfile: { p in editingProfile = p }
            )
            .navigationTitle("Databases")
            .toolbar { MobileLibraryToolbar(actions: libraryActions, isPro: entitlementsStore.isPro) }
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
    private var libraryActions: MobileLibraryActions {
        MobileLibraryActions(
            showMonitor: { showingFleetMonitor = true },
            addConnection: handleAddProfile,
            importFromProvider: { showingProviderImport = true },
            importCSV: { showingCSVImport = true },
            showSSHKeys: { showingSSHIdentities = true },
            showPro: { showingProUpgrade = true }
        )
    }

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

