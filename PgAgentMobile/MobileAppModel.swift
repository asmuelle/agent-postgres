import Observation

// =============================================================================
// MobileAppModel — the app's navigation state: which of the three tabs is
// showing and which database Query and Browse are scoped to. Ids only (no
// PostgresProfile), so it compiles into the hostless PgAgentMobileTests target.
// One instance per scene, persisted through @SceneStorage by MobileContentView.
// =============================================================================

enum MobileAppTab: String, Hashable, CaseIterable {
    case pulse, query, browse
}

/// Sheets any screen can ask for; MobileContentView presents them, so no
/// view has to thread presentation closures through its children.
enum MobileSheet: Hashable, Identifiable {
    case newConnection
    case editConnection(profileId: String)
    case importCSV
    case importFromProvider
    case sshKeys
    case pro
    case alertSettings

    var id: Self { self }
}

@MainActor
@Observable
final class MobileAppModel {
    var selectedTab: MobileAppTab = .pulse {
        didSet {
            if selectedTab != .pulse { hasUsedDatabaseTabs = true }
        }
    }
    /// The database Query and Browse work on.
    var currentProfileId: String?
    private(set) var presentedSheet: MobileSheet?
    /// Set once Query or Browse has been shown. Until then nothing needs the
    /// current database, so launching onto Pulse opens no connection.
    private(set) var hasUsedDatabaseTabs = false

    /// The database whose connection should be held: the current one, once
    /// Query or Browse has been used. Stays claimed across tab switches.
    var connectedProfileId: String? {
        hasUsedDatabaseTabs ? currentProfileId : nil
    }

    /// Make `profileId` the current database and show it in `tab`.
    func open(profileId: String, in tab: MobileAppTab = .query) {
        currentProfileId = profileId
        selectedTab = tab
    }

    /// Ask for a sheet. Ignored while another is showing, so ⌘N can't
    /// replace a half-edited connection form.
    func present(_ sheet: MobileSheet) {
        guard presentedSheet == nil else { return }
        presentedSheet = sheet
    }

    func dismissSheet() {
        presentedSheet = nil
    }

    /// Keep the current database valid as connections are added or removed:
    /// a deleted one is dropped, and with exactly one connection there is
    /// nothing to choose — it becomes current.
    func reconcile(availableProfileIds: Set<String>) {
        if let current = currentProfileId, !availableProfileIds.contains(current) {
            currentProfileId = nil
        }
        if currentProfileId == nil, availableProfileIds.count == 1 {
            currentProfileId = availableProfileIds.first
        }
    }
}
