import Foundation
import Observation

// =============================================================================
// MobileSystemNavigator — where the system sends the app: Siri and Shortcuts
// ("Open Flank in pgAgent"), a Spotlight result, the Control Center control,
// a widget tap (pgAgent://fleet). Requests are taken once, by the window in
// front (MobileContentView), like a tapped alert.
//
// ⚠️ Dual-target file: also compiled into PgAgentMobileWidgets, because the
// control's OpenPgAgentIntent calls it (the system runs that intent in the
// app). Foundation-only; also compiled into the hostless PgAgentMobileTests.
// =============================================================================

/// A place in the app the system can open.
enum MobileSystemDestination: Equatable, Sendable {
    case pulse
    /// `nil` keeps the window's current database.
    case query(profileId: String?)
    case browse(profileId: String?)

    static let urlScheme = "pgagent"

    /// `pgAgent://fleet` / `pulse`, `pgAgent://query?db=<profile id>`,
    /// `pgAgent://browse?db=<profile id>`; anything else is not ours.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.urlScheme else { return nil }
        let profileId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "db" }?.value
            .flatMap { $0.isEmpty ? nil : $0 }
        switch url.host()?.lowercased() {
        case "fleet", "pulse": self = .pulse
        case "query": self = .query(profileId: profileId)
        case "browse": self = .browse(profileId: profileId)
        default: return nil
        }
    }
}

@MainActor
@Observable
final class MobileSystemNavigator {
    static let shared = MobileSystemNavigator()

    /// The request no window has taken yet; a newer one replaces it.
    private(set) var pending: MobileSystemDestination?

    func request(_ destination: MobileSystemDestination) {
        pending = destination
    }

    /// The pending request, removing it.
    func take() -> MobileSystemDestination? {
        defer { pending = nil }
        return pending
    }
}
