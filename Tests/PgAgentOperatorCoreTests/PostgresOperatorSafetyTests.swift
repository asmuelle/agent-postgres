import XCTest
@testable import PgAgentOperatorCore

final class PostgresOperatorSafetyTests: XCTestCase {
    func testDefaultExplainNeverExecutesUnderlyingStatement() throws {
        let plan = try PostgresExplainPolicy.plan(
            for: "DELETE FROM invoices WHERE paid = false",
            mode: .estimated
        )

        XCTAssertTrue(plan.explainSQL.hasPrefix("EXPLAIN (COSTS, VERBOSE, FORMAT JSON)"))
        XCTAssertFalse(plan.explainSQL.uppercased().contains("ANALYZE"))
        XCTAssertTrue(plan.prelude.isEmpty)
    }

    func testAnalyzeRequiresExplicitConfirmationAndReadOnlyStatement() {
        XCTAssertThrowsError(
            try PostgresExplainPolicy.plan(
                for: "SELECT * FROM invoices",
                mode: .analyze(confirmed: false)
            )
        )
        XCTAssertThrowsError(
            try PostgresExplainPolicy.plan(
                for: "UPDATE invoices SET paid = true",
                mode: .analyze(confirmed: true)
            )
        )
    }

    func testConfirmedAnalyzeUsesSafetyTimeouts() throws {
        let plan = try PostgresExplainPolicy.plan(
            for: "SELECT * FROM invoices",
            mode: .analyze(confirmed: true)
        )

        XCTAssertTrue(plan.explainSQL.contains("ANALYZE"))
        XCTAssertTrue(plan.prelude.contains { $0.contains("SET LOCAL statement_timeout") })
        XCTAssertTrue(plan.prelude.contains { $0.contains("SET LOCAL lock_timeout") })
        XCTAssertTrue(plan.prelude.contains("SET TRANSACTION READ ONLY"))
        XCTAssertEqual(plan.cleanup, "ROLLBACK")
    }

    func testAnalyzeRejectsMultipleStatements() {
        XCTAssertThrowsError(
            try PostgresExplainPolicy.plan(
                for: "SELECT 1; SELECT 2",
                mode: .analyze(confirmed: true)
            )
        )
    }

    func testProductionTerminationRequiresTypedPhrase() {
        let challenge = PostgresSessionActionPolicy.challenge(
            action: .terminate,
            isProduction: true,
            profileName: "orders-prod",
            pid: 4242
        )

        XCTAssertEqual(challenge.requiredPhrase, "TERMINATE 4242")
        XCTAssertFalse(challenge.accepts("terminate 4242"))
        XCTAssertTrue(challenge.accepts("TERMINATE 4242"))
    }

    func testCancelOutsideProductionUsesOrdinaryConfirmation() {
        let challenge = PostgresSessionActionPolicy.challenge(
            action: .cancel,
            isProduction: false,
            profileName: "orders-stage",
            pid: 42
        )

        XCTAssertNil(challenge.requiredPhrase)
    }
}
