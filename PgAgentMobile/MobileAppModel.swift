import Foundation
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

/// Where a tapped alert should land: the affected instance, plus enough
/// context to open the most relevant tab of the instance detail —
/// blocked/deadlock kinds go to the lock chain (with the root blocker
/// highlighted when known), slow/busy kinds to the activity list, offline
/// to the fleet overview.
struct MobileAlertRoute: Equatable, Sendable {
    let instanceId: String
    let kind: FleetAlertKind?
    /// Root blocker pid from the alert payload, when the hub captured one.
    /// Nil is fine — the lock view falls back to highlighting the current
    /// root blocker after a fresh fetch (highlight-by-refetch).
    let blockerPid: Int32?
}

/// The value an extra iPad window is opened with (`openWindow(value:)`).
/// The `id` makes every request a new window — SwiftUI would otherwise bring
/// forward an existing window opened with an equal value, even one that has
/// since moved to another database.
struct MobileWindowTarget: Codable, Hashable, Sendable {
    var id = UUID()
    /// The database the window starts on (its Query tab); `nil` starts on Pulse.
    var profileId: String?
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

    /// A tapped alert this window claimed; Pulse pushes its detail and clears it.
    var alertRoute: MobileAlertRoute?

    /// Show a tapped alert: Pulse, in front of everything.
    func showAlert(_ route: MobileAlertRoute) {
        dismissSheet()
        selectedTab = .pulse
        alertRoute = route
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
