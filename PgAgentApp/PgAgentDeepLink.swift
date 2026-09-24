import Foundation

// =============================================================================
// PgAgentDeepLink — parses the `pgAgent://` URLs the app registers in
// Info.plist (CFBundleURLTypes) into a navigation route. Pure value logic so
// it's unit-testable; ContentView's `.onOpenURL` applies the route.
//
// Producers (keep in sync):
//   pgAgent://monitoring              widget overview / alert fallback
//   pgAgent://monitoring/<profileId>  widget row, WidgetSnapshotPublisher,
//                                     LiveActivityModels, port-forward rows
//   pgAgent://fleet                   iOS accessory widget (shared scheme)
//   pgAgent://automation/<op>?profile=<profileId>  LiveActivityModels
//   pgAgent://server|profile|terminal|folder|files/<profileId>  legacy shapes
//                                     from MidnightSSHDeepLink
// Anything else (shell-integration `notify` / `widget` markers, unknown
// hosts, other schemes) just brings the app forward.
// =============================================================================

enum PgAgentDeepLink: Equatable, Sendable {
    /// Fleet overview — the Monitoring Hub pane.
    case monitoringOverview
    /// One instance's health — focus that profile.
    case monitoring(profileId: String)
    /// Focus a profile in the sidebar/workspace.
    case profile(profileId: String)
    /// Recognised-but-unroutable or unknown URL: just activate the app.
    case activate

    static let scheme = "pgagent"

    init(url: URL) {
        // URL schemes are case-insensitive (RFC 3986 §3.1); producers spell
        // it `pgAgent`, but the OS may hand it over lower-cased.
        guard url.scheme?.lowercased() == Self.scheme,
              let host = url.host?.lowercased(), !host.isEmpty
        else {
            self = .activate
            return
        }

        // pathComponents is percent-decoded and starts with "/".
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        let firstPart = parts.first
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [String: String]()) { values, item in
                if let value = item.value, !value.isEmpty { values[item.name] = value }
            } ?? [:]

        switch host {
        case "monitoring", "fleet":
            if let id = firstPart {
                self = .monitoring(profileId: id)
            } else {
                self = .monitoringOverview
            }
        case "server", "profile", "terminal", "folder", "files":
            if let id = firstPart {
                self = .profile(profileId: id)
            } else {
                self = .activate
            }
        case "automation":
            if let id = query["profile"] {
                self = .profile(profileId: id)
            } else {
                self = .activate
            }
        default:
            self = .activate
        }
    }

    /// The `pgAgent://monitoring/<profileId>` URL for one instance; nil only
    /// if the id can't be percent-encoded.
    static func monitoringURLString(profileId: String) -> String? {
        guard let encoded = profileId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        ) else { return nil }
        return "pgAgent://monitoring/\(encoded)"
    }
}
