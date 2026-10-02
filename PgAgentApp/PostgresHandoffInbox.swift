import Combine
import Foundation

/// A query handed off from the user's iPad or iPhone, waiting for its
/// connection's workspace. ContentView selects the profile and posts the
/// handoff here; the workspace showing that profile takes it — once — and
/// opens it as a new tab. Nothing runs.
///
/// Take-once on purpose: a handoff left behind would reappear as a stale tab
/// whenever a workspace for that connection is created later.
@MainActor
final class PostgresHandoffInbox: ObservableObject {
    static let shared = PostgresHandoffInbox()

    /// The handoff nobody has taken yet; a newer one replaces it.
    @Published private(set) var pending: PgQueryHandoff?

    func post(_ handoff: PgQueryHandoff) {
        pending = handoff
    }

    /// The pending handoff if it's for `profileId`, removing it.
    func take(for profileId: String) -> PgQueryHandoff? {
        guard let handoff = pending, handoff.profileId == profileId else { return nil }
        pending = nil
        return handoff
    }
}
