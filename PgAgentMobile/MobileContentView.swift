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
// current database, the window's query tabs and keyboard-shortcut relay, the
// sheets any screen can request, alert routing, incoming Handoff, and where
// Siri, Spotlight, the Control Center control and pgAgent:// links send it.
//
// One per window: on iPad each database can have its own window
// (`openWindow(value: MobileWindowTarget(…))`), side by side in Split View or
// Stage Manager.
// =============================================================================
struct MobileContentView: View {
    /// Set when this window was opened as an extra window ("Open in New
    /// Window", ⌥⌘N); with a database it starts on that database's Query tab.
    var opening: MobileWindowTarget? = nil

    @EnvironmentObject private var profileStore: PostgresProfileStore
    @EnvironmentObject private var entitlementsStore: MobileEntitlementsStore
    @EnvironmentObject private var alertRouter: MobileAlertRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    /// Used for claim/release only — not observed, so schema loads don't
    /// re-evaluate the whole root.
    private let connectionManager = PostgresConnectionManager.shared
    private let navigator = MobileSystemNavigator.shared

    @State private var app = MobileAppModel()
    @StateObject private var queryStores = MobileQueryStores()
    @StateObject private var shortcutRelay = MobileShortcutRelay()
    /// The tabs mount only after the scene state is restored, so a launch
    /// into Query never builds (and polls from) Pulse first.
    @State private var hasRestored = false
    /// A Handoff that arrived before the scene state was restored; applied
    /// right after, so the restore can't put the window back elsewhere.
    @State private var pendingHandoff: PgQueryHandoff?
    @SceneStorage("selectedTab") private var storedTab: MobileAppTab = .pulse
    @SceneStorage("currentProfileId") private var storedProfileId: String = ""
    /// The window's opening target was applied; from then on its own scene
    /// storage decides (even "All Databases", stored as an empty id).
    @SceneStorage("appliedOpeningTarget") private var appliedOpeningTarget = false

    var body: some View {
        Group {
            if hasRestored {
                tabs
            } else {
                Color.clear
            }
        }
        .environment(app)
        .environmentObject(queryStores)
        .environmentObject(shortcutRelay)
        // Menu-bar shortcuts act on the window in front only.
        .focusedSceneValue(\.mobileShortcutRelay, shortcutRelay)
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
            queryStores.retain(only: available)
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
        // A tapped alert goes to one window — the one in front — when it
        // arrives, or when a window comes to the front with one waiting.
        .onChange(of: alertRouter.pendingRoute) { _, _ in
            routePendingAlert()
        }
        .onChange(of: scenePhase) { _, _ in
            routePendingAlert()
            openSystemDestination()
        }
        // Siri / Shortcuts / Spotlight / Control Center ask for a place in
        // the app; widgets link to it (pgAgent://fleet). The window in front
        // goes there.
        .onChange(of: navigator.pending) { _, _ in
            openSystemDestination()
        }
        .onOpenURL { url in
            if let destination = MobileSystemDestination(url: url) {
                navigator.request(destination)
            }
        }
        // A query handed off from the user's Mac or other device: open it in
        // a new tab on that connection — never run it.
        .onContinueUserActivity(PgQueryHandoff.activityType) { activity in
            guard let handoff = PgQueryHandoff(userInfo: activity.userInfo) else { return }
            if hasRestored {
                openHandoff(handoff)
            } else {
                pendingHandoff = handoff
            }
        }
        .onReceive(shortcutRelay.actions) { action in
            switch action {
            case .newConnection:
                app.present(.newConnection)
            case .newWindow:
                if supportsMultipleWindows {
                    openWindow(value: MobileWindowTarget(profileId: app.currentProfileId))
                }
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

    /// Restore tab + database before the tabs exist, then let a Handoff or
    /// a pending alert (cold launch from a notification) win over it.
    private func restoreSceneState() {
        guard !hasRestored else { return }
        if let opening, !appliedOpeningTarget {
            // An extra window starts on its database's Query tab (or Pulse);
            // after that its own scene storage takes over.
            appliedOpeningTarget = true
            if let profileId = opening.profileId {
                app.open(profileId: profileId, in: .query)
            }
        } else {
            if !storedProfileId.isEmpty {
                app.currentProfileId = storedProfileId
            }
            app.selectedTab = storedTab
        }
        app.reconcile(availableProfileIds: Set(profileStore.profiles.map(\.id)))
        if let pendingHandoff {
            self.pendingHandoff = nil
            openHandoff(pendingHandoff)
        }
        routePendingAlert()
        hasRestored = true
        openSystemDestination()
    }

    /// Takes a pending system request (Siri, Spotlight, a control, a widget
    /// link) if this window is in front and restored, and goes there.
    private func openSystemDestination() {
        guard hasRestored, scenePhase == .active, let destination = navigator.take() else { return }
        app.dismissSheet()
        switch destination {
        case .pulse:
            app.selectedTab = .pulse
        case .query(let profileId):
            show(.query, profileId: profileId)
        case .browse(let profileId):
            show(.browse, profileId: profileId)
        }
    }

    /// `tab` on `profileId`, or on the current database when there's none
    /// (or it was deleted).
    private func show(_ tab: MobileAppTab, profileId: String?) {
        if let profileId, profileStore.profile(withId: profileId) != nil {
            app.open(profileId: profileId, in: tab)
        } else {
            app.selectedTab = tab
        }
    }

    private func openHandoff(_ handoff: PgQueryHandoff) {
        guard profileStore.profile(withId: handoff.profileId) != nil else { return }
        queryStores.store(for: handoff.profileId).openSqlTab(title: handoff.title, sql: handoff.sql)
        app.open(profileId: handoff.profileId, in: .query)
    }

    /// Alert deep link (Mac-hub push or local background alert). The window
    /// in front claims it — only one window jumps to Pulse — and its Pulse
    /// pushes the alerted instance's detail.
    private func routePendingAlert() {
        guard scenePhase == .active, let route = alertRouter.pendingRoute else { return }
        alertRouter.pendingRoute = nil
        // Profile deleted since the alert fired: drop it, so it can't fire
        // against an unrelated future selection.
        guard profileStore.profiles.contains(where: { $0.id == route.instanceId }) else { return }
        app.showAlert(route)
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
