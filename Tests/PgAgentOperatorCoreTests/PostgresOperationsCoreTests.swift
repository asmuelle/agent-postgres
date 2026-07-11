import XCTest
@testable import PgAgentOperatorCore

final class PostgresOperationsCoreTests: XCTestCase {
    func testProgressParserHandlesVacuumAndUnknownTotals() throws {
        let vacuum = try PostgresProgressParser.parse([
            "42", "orders", "public.invoices", "VACUUM", "scanning heap", "50", "100"
        ])
        XCTAssertEqual(vacuum.percentComplete, 50)
        XCTAssertEqual(vacuum.operation, .vacuum)

        let unknown = try PostgresProgressParser.parse([
            "43", "orders", "public.idx", "CREATE INDEX", "building index", "10", nil
        ])
        XCTAssertNil(unknown.percentComplete)
    }

    func testProgressSQLUsesPostgres14Views() {
        XCTAssertTrue(PostgresProgressSQL.activeOperations.contains("pg_stat_progress_vacuum"))
        XCTAssertTrue(PostgresProgressSQL.activeOperations.contains("pg_stat_progress_create_index"))
        XCTAssertTrue(PostgresProgressSQL.activeOperations.contains("pg_stat_progress_cluster"))
        XCTAssertTrue(PostgresProgressSQL.activeOperations.contains("pg_stat_progress_analyze"))
    }

    func testDriftPolicyFindsSchemaAndMajorVersionDifferences() {
        let reference = FleetDriftSnapshot(
            profileId: "prod-a", group: "orders", environment: "production",
            serverMajorVersion: 16, schemaFingerprint: "aaa")
        let candidate = FleetDriftSnapshot(
            profileId: "prod-b", group: "orders", environment: "production",
            serverMajorVersion: 15, schemaFingerprint: "bbb")

        let findings = FleetDriftPolicy.findings(in: [reference, candidate])
        XCTAssertEqual(Set(findings.map(\.kind)), [.serverVersion, .schema])
        XCTAssertTrue(findings.allSatisfy { $0.profileId == "prod-b" })
    }

    func testDriftDoesNotCompareUnrelatedGroups() {
        let findings = FleetDriftPolicy.findings(in: [
            FleetDriftSnapshot(profileId: "a", group: "orders", environment: "production", serverMajorVersion: 16, schemaFingerprint: "aaa"),
            FleetDriftSnapshot(profileId: "b", group: "billing", environment: "production", serverMajorVersion: 15, schemaFingerprint: "bbb"),
        ])
        XCTAssertTrue(findings.isEmpty)
    }

    func testRunbooksAreEvidenceFirstAndPostgres14Compatible() {
        let runbooks = PostgresDBARunbook.catalog
        XCTAssertTrue(runbooks.contains { $0.id == "connection-storm" })
        XCTAssertTrue(runbooks.contains { $0.id == "replication-lag" })
        XCTAssertTrue(runbooks.contains { $0.id == "wraparound-risk" })
        XCTAssertTrue(runbooks.flatMap(\.steps).prefix(3).allSatisfy { $0.isReadOnly })
        XCTAssertTrue(runbooks.flatMap(\.steps).allSatisfy { !$0.sql.contains("pg_stat_io") })
    }
}
