import XCTest
@testable import PgAgentApp

/// The Mac parks a query handed off from the iPad until the workspace for
/// its connection takes it — exactly once, and only that workspace.
@MainActor
final class PostgresHandoffInboxTests: XCTestCase {
    private func handoff(_ profileId: String, _ sql: String = "SELECT 1") -> PgQueryHandoff {
        PgQueryHandoff(profileId: profileId, sql: sql, title: "Query 1")!
    }

    func testOnlyTheMatchingConnectionTakesIt() {
        let inbox = PostgresHandoffInbox()
        inbox.post(handoff("p1"))

        XCTAssertNil(inbox.take(for: "p2"))
        XCTAssertEqual(inbox.take(for: "p1"), handoff("p1"))
    }

    /// Taken means gone: a workspace created later must not reopen it.
    func testIsTakenOnce() {
        let inbox = PostgresHandoffInbox()
        inbox.post(handoff("p1"))

        _ = inbox.take(for: "p1")

        XCTAssertNil(inbox.pending)
        XCTAssertNil(inbox.take(for: "p1"))
    }

    func testANewerHandoffReplacesAnUntakenOne() {
        let inbox = PostgresHandoffInbox()
        inbox.post(handoff("p1", "SELECT 1"))
        inbox.post(handoff("p1", "SELECT 2"))

        XCTAssertEqual(inbox.take(for: "p1")?.sql, "SELECT 2")
    }
}
