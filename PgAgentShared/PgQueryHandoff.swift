import Foundation

// =============================================================================
// PgQueryHandoff — what a query tab hands to the user's other devices via
// Handoff (Mac ↔ iPad ↔ iPhone): which connection, the SQL, the tab title.
//
// Deliberately minimal: never results, never credentials. Profiles share
// ids across devices (CloudSync keys records by id), so the receiver opens
// the same connection; a profile it doesn't have is ignored. The receiver
// only opens a tab with the SQL — nothing runs until the user presses Run.
// =============================================================================
struct PgQueryHandoff: Equatable, Sendable {
    /// NSUserActivity type; declared in both apps' NSUserActivityTypes.
    static let activityType = "com.pgagent.query"
    /// Handoff payloads are meant to stay small (Apple suggests a few KB).
    /// Larger scripts simply aren't advertised — never truncated.
    static let maxSQLBytes = 2_048
    static let maxTitleLength = 80
    private static let version = "1"

    let profileId: String
    let sql: String
    let title: String

    /// `nil` when there's nothing worth handing off (blank or oversized SQL).
    /// The title ends up in the tab bar and in file names, so control
    /// characters (line breaks, tabs…) become spaces.
    init?(profileId: String, sql: String, title: String) {
        // Size first: it's O(1), and this runs on every edit of the tab.
        guard !profileId.isEmpty,
              sql.utf8.count <= Self.maxSQLBytes,
              !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        self.profileId = profileId
        self.sql = sql
        var printable = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            printable.append(scalar.properties.generalCategory == .control ? " " : scalar)
        }
        self.title = String(String(printable).prefix(Self.maxTitleLength))
    }

    /// Decode a received activity's `userInfo`; anything malformed, from
    /// another version, or over the limits is rejected.
    init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              userInfo["v"] as? String == Self.version,
              let profileId = userInfo["profileId"] as? String,
              let sql = userInfo["sql"] as? String,
              let title = userInfo["title"] as? String
        else { return nil }
        self.init(profileId: profileId, sql: sql, title: title)
    }

    var userInfo: [String: String] {
        ["v": Self.version, "profileId": profileId, "sql": sql, "title": title]
    }
}
