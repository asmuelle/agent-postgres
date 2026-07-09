import XCTest
@testable import PgAgentApp

// Tests for the read-only SQL guard that screens every AI-issued query before
// it reaches `pgExecute`. This is a security boundary, so the negative cases
// (writes disguised in CTEs, multiple statements, EXPLAIN ANALYZE) matter most.
final class PgReadOnlyGuardTests: XCTestCase {

    // MARK: - Allowed

    func testPlainSelectPasses() {
        XCTAssertTrue(PgReadOnlyGuard.isReadOnly("SELECT * FROM users WHERE id = 1"))
    }

    func testLowercaseSelectPasses() {
        XCTAssertTrue(PgReadOnlyGuard.isReadOnly("select id, name from accounts"))
    }

    func testTrailingSemicolonPasses() {
        XCTAssertTrue(PgReadOnlyGuard.isReadOnly("SELECT 1;"))
    }

    func testReadOnlyCteWithSelectPasses() {
        let sql = "WITH recent AS (SELECT * FROM orders WHERE created_at > now() - interval '7 days') SELECT count(*) FROM recent"
        XCTAssertTrue(PgReadOnlyGuard.isReadOnly(sql))
    }

    func testValuesTableShowExplainPass() {
        XCTAssertTrue(PgReadOnlyGuard.isReadOnly("VALUES (1), (2)"))
        XCTAssertTrue(PgReadOnlyGuard.isReadOnly("TABLE users"))
        XCTAssertTrue(PgReadOnlyGuard.isReadOnly("SHOW search_path"))
        XCTAssertTrue(PgReadOnlyGuard.isReadOnly("EXPLAIN SELECT * FROM users"))
    }

    func testForbiddenKeywordInsideStringLiteralIsIgnored() {
        // The literal contains DROP TABLE but it's data, not a statement.
        XCTAssertTrue(PgReadOnlyGuard.isReadOnly("SELECT 'DROP TABLE users' AS note"))
    }

    func testForbiddenKeywordInsideCommentIsIgnored() {
        XCTAssertTrue(PgReadOnlyGuard.isReadOnly("SELECT 1 -- DROP TABLE users\n"))
        XCTAssertTrue(PgReadOnlyGuard.isReadOnly("SELECT 1 /* UPDATE foo SET x=1 */"))
    }

    func testSemicolonInsideStringIsNotMultipleStatements() {
        XCTAssertTrue(PgReadOnlyGuard.isReadOnly("SELECT 'a;b;c' AS s"))
    }

    func testReturnsTrimmedStatement() throws {
        let result = try PgReadOnlyGuard.validate("   SELECT 1   ")
        XCTAssertEqual(result, "SELECT 1")
    }

    // MARK: - Rejected

    func testEmptyRejected() {
        XCTAssertThrowsError(try PgReadOnlyGuard.validate("   ")) { error in
            XCTAssertEqual(error as? PgReadOnlyGuard.Violation, .empty)
        }
    }

    func testInsertRejected() {
        assertViolation("INSERT INTO users (name) VALUES ('x')")
    }

    func testUpdateRejected() {
        assertViolation("UPDATE users SET name = 'x' WHERE id = 1")
    }

    func testDeleteRejected() {
        assertViolation("DELETE FROM users WHERE id = 1")
    }

    func testDdlRejected() {
        assertViolation("DROP TABLE users")
        assertViolation("ALTER TABLE users ADD COLUMN x int")
        assertViolation("TRUNCATE users")
        assertViolation("CREATE TABLE t (id int)")
    }

    func testMultipleStatementsRejected() {
        XCTAssertThrowsError(try PgReadOnlyGuard.validate("SELECT 1; DROP TABLE users")) { error in
            // Either multipleStatements or forbiddenKeyword is acceptable; both block it.
            let v = error as? PgReadOnlyGuard.Violation
            XCTAssertTrue(v == .multipleStatements || v == .forbiddenKeyword("DROP"))
        }
    }

    func testDataModifyingCteRejected() {
        let sql = "WITH gone AS (DELETE FROM users WHERE id = 1 RETURNING *) SELECT * FROM gone"
        assertViolation(sql, expected: .forbiddenKeyword("DELETE"))
    }

    func testExplainAnalyzeRejected() {
        // EXPLAIN ANALYZE actually executes the query — must be blocked.
        assertViolation("EXPLAIN ANALYZE SELECT * FROM users", expected: .forbiddenKeyword("ANALYZE"))
    }

    func testSelectForUpdateRejected() {
        // Row locks are a side effect; conservatively rejected via the UPDATE token.
        assertViolation("SELECT * FROM users FOR UPDATE", expected: .forbiddenKeyword("UPDATE"))
    }

    func testSideEffectingFunctionRejected() {
        assertViolation("SELECT nextval('orders_id_seq')", expected: .forbiddenKeyword("NEXTVAL"))
        assertViolation("SELECT set_config('app.mode', 'unsafe', false)", expected: .forbiddenKeyword("SET_CONFIG"))
    }

    func testNonSelectLeadingRejected() {
        // SET isn't an allowed leading keyword, so the leading-statement check
        // fires before the keyword scan — the more precise violation.
        assertViolation("SET search_path TO public", expected: .notReadOnlyStatement("SET"))
    }

    // MARK: - Helpers

    private func assertViolation(
        _ sql: String,
        expected: PgReadOnlyGuard.Violation? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try PgReadOnlyGuard.validate(sql), file: file, line: line) { error in
            guard let violation = error as? PgReadOnlyGuard.Violation else {
                return XCTFail("Expected PgReadOnlyGuard.Violation, got \(error)", file: file, line: line)
            }
            if let expected {
                XCTAssertEqual(violation, expected, file: file, line: line)
            }
        }
    }
}
