import XCTest

// `PulseSummary.swift` is compiled directly into this logic-test target (see
// project.yml): what Siri says for "Check my databases" — the same words as
// the Pulse tiles, problems first.

final class PulseSummaryTests: XCTestCase {
    private let healthy = PulseStatus(title: "Healthy", detail: "Idle · 20 ms", tone: .good, systemImage: "checkmark.circle")
    private let cantConnect = PulseStatus(title: "Can't Connect", detail: nil, tone: .critical, systemImage: "bolt.horizontal.circle")
    private let slow = PulseStatus(title: "2 Slow Queries", detail: nil, tone: .warning, systemImage: "tortoise")

    func testNoDatabases() {
        XCTAssertEqual(PulseSummary.spoken([]), "You haven't added a database yet.")
    }

    func testOneHealthyDatabase() {
        XCTAssertEqual(PulseSummary.spoken([("Flank", healthy)]), "Flank is healthy.")
    }

    func testAllHealthy() {
        XCTAssertEqual(
            PulseSummary.spoken([("Flank", healthy), ("Keycloak", healthy), ("Local", healthy)]),
            "All 3 databases are healthy."
        )
    }

    func testProblemsComeFirstThenTheHealthyOne() {
        XCTAssertEqual(
            PulseSummary.spoken([("Flank", healthy), ("Keycloak", cantConnect)]),
            "Keycloak: Can't Connect. Flank is healthy."
        )
    }

    func testProblemsThenAHealthyCount() {
        XCTAssertEqual(
            PulseSummary.spoken([("Flank", healthy), ("Keycloak", cantConnect), ("Local", healthy), ("Orders", slow)]),
            "Keycloak: Can't Connect. Orders: 2 Slow Queries. The other 2 are healthy."
        )
    }

    func testOnlyProblems() {
        XCTAssertEqual(
            PulseSummary.spoken([("Keycloak", cantConnect), ("Orders", slow)]),
            "Keycloak: Can't Connect. Orders: 2 Slow Queries."
        )
    }
}
