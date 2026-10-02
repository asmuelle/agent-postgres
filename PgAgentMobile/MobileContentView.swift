import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobileContentView — the app's root: three tabs, one code path for iPhone
// (tab bar) and iPad (top tab bar / sidebar, via .sidebarAdaptable).
//
//   Pulse   — is every database OK? (home; also where connections are added)
//   Query   — the SQL workspace for the current database
//   Browse  — the current database's objects
//
// Owns the scene-level pieces every tab shares: the MobileAppModel (tab +
// current database, persisted per scene), the single connection claim on the
// current database, the sheets any screen can request, and alert routing.
// =============================================================================
struct MobileContentView: View {
    @EnvironmentObject private var profileStore: PostgresProfileStore
    @EnvironmentObject private var entitlementsStore: MobileEntitlementsStore
    @EnvironmentObject private var alertRouter: MobileAlertRouter
    /// Used for claim/release only — not observed, so schema loads don't
    /// re-evaluate the whole root.
    private let connectionManager = PostgresConnectionManager.shared

    @State private var app = MobileAppModel()
    /// The tabs mount only after the scene state is restored, so a launch
    /// into Query never builds (and polls from) Pulse first.
    @State private var hasRestored = false
    @SceneStorage("selectedTab") private var storedTab: MobileAppTab = .pulse
    @SceneStorage("currentProfileId") private var storedProfileId: String = ""

    var body: some View {
        Group {
            if hasRestored {
                tabs
            } else {
                Color.clear
            }
        }
        .environment(app)
        .sheet(item: sheetBinding) { sheet in
            sheetContent(sheet)
        }
        .onAppear(perform: restoreSceneState)
        .onChange(of: app.selectedTab) { _, tab in storedTab = tab }
        .onChange(of: app.currentProfileId) { _, id in storedProfileId = id ?? "" }
        .onChange(of: profileStore.profiles.map(\.id)) { _, ids in
            let available = Set(ids)
            app.reconcile(availableProfileIds: available)
            // Deleted connections take their open queries and results along.
            MobileQueryStores.retain(only: available)
        }
        // Hold the current database's connection once Query or Browse has
        // been used — across tab switches — and move the claim when the
        // selection changes.
        .task(id: app.connectedProfileId) {
            guard let profileId = app.connectedProfileId,
                  let profile = profileStore.profile(withId: profileId)
            else { return }
            // Claim before the first suspension so the release always pairs
            // with it, even when the task is cancelled mid-connect.
            let lease = connectionManager.claim(profile: profile)
            defer { connectionManager.release(lease) }
            await connectionManager.connectIfNeeded(profile: profile)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        // Alert tapped while running; a cold launch is handled by the restore.
        .onChange(of: alertRouter.pendingRoute) { _, _ in
            routePendingAlert()
        }
        .onReceive(MobileShortcutRelay.shared.actions) { action in
            switch action {
            case .newConnection:
                app.present(.newConnection)
            case .showTab(let tab):
                app.selectedTab = tab
            default:
                break
            }
        }
    }

    private var tabs: some View {
        TabView(selection: $app.selectedTab) {
            Tab("Pulse", systemImage: "waveform.path.ecg", value: MobileAppTab.pulse) {
                MobilePulseView()
            }
            Tab("Query", systemImage: "terminal", value: MobileAppTab.query) {
                MobileQueryTab()
            }
            Tab("Browse", systemImage: "square.stack.3d.up", value: MobileAppTab.browse) {
                MobileBrowseView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    private var sheetBinding: Binding<MobileSheet?> {
        Binding(
            get: { app.presentedSheet },
            set: { if $0 == nil { app.dismissSheet() } }
        )
    }

    /// Restore tab + database before the tabs exist, then let a pending
    /// alert (cold launch from a notification) win over the restored tab.
    private func restoreSceneState() {
        guard !hasRestored else { return }
        if !storedProfileId.isEmpty {
            app.currentProfileId = storedProfileId
        }
        app.selectedTab = storedTab
        app.reconcile(availableProfileIds: Set(profileStore.profiles.map(\.id)))
        routePendingAlert()
        hasRestored = true
    }

    /// Alert deep link (Mac-hub push or local background alert): show Pulse,
    /// which pushes the alerted instance's detail.
    private func routePendingAlert() {
        guard let route = alertRouter.pendingRoute else { return }
        guard profileStore.profiles.contains(where: { $0.id == route.instanceId }) else {
            // Profile deleted since the alert fired — drop the route so it
            // can't fire against an unrelated future selection.
            alertRouter.pendingRoute = nil
            return
        }
        app.dismissSheet()
        app.selectedTab = .pulse
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: MobileSheet) -> some View {
        switch sheet {
        case .newConnection:
            if entitlementsStore.canCreateConnection(currentCount: profileStore.profiles.count) {
                PostgresMobileConnectionEditView(profile: nil) { newProfile in
                    profileStore.saveOrUpdate(newProfile)
                    app.dismissSheet()
                    app.currentProfileId = newProfile.id
                }
            } else {
                proUpgrade
            }
        case .editConnection(let profileId):
            if let profile = profileStore.profile(withId: profileId) {
                PostgresMobileConnectionEditView(profile: profile) { updated in
                    profileStore.saveOrUpdate(updated)
                    app.dismissSheet()
                }
            }
        case .importCSV:
            ConnectionCSVImportView { imported in
                for profile in imported {
                    profileStore.saveOrUpdate(profile)
                }
                app.dismissSheet()
            }
        case .importFromProvider:
            MobileProviderImportView()
                .environmentObject(profileStore)
        case .sshKeys:
            MobileSSHIdentityListView()
        case .pro:
            proUpgrade
        case .alertSettings:
            MobileMonitorSettingsView()
        }
    }

    private var proUpgrade: some View {
        MobileProUpgradeView(currentSavedHosts: profileStore.profiles.count)
            .environmentObject(entitlementsStore)
    }
}
