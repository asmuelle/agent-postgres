import XCTest
@testable import PgAgentApp

// Tests for the shared read-only statement classifier that enforces
// per-connection read-only mode at the bridge layer. Security boundary:
// negative cases (writes hidden in CTEs, trailing statements, EXPLAIN
// ANALYZE of a write) matter most. The classifier is deliberately
// conservative — false blocks are acceptable, false allows are not.
final class PostgresStatementClassifierTests: XCTestCase {

    // MARK: - Allowed (reads)

    func testPlainSelectAllowed() {
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("SELECT * FROM users WHERE id = 1"))
    }

    func testMixedCaseSelectAllowed() {
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("SeLeCt id, name FROM accounts"))
    }

    func testTrailingSemicolonAllowed() {
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("SELECT 1;"))
    }

    func testExplainSelectAllowed() {
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("EXPLAIN SELECT * FROM users"))
        // EXPLAIN ANALYZE executes the statement and is not safe for an
        // application-level read-only boundary.
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("EXPLAIN ANALYZE SELECT * FROM users"))
    }

    func testShowValuesTableFetchAllowed() {
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("SHOW search_path"))
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("VALUES (1), (2)"))
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("TABLE users"))
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("FETCH 10 FROM my_cursor"))
    }

    func testReadOnlyCteAllowed() {
        let sql = """
        WITH recent AS (
            SELECT * FROM orders WHERE created_at > now() - interval '7 days'
        )
        SELECT count(*) FROM recent
        """
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly(sql))
    }

    func testLeadingLineCommentAllowed() {
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("-- top comment\nSELECT 1"))
    }

    func testLeadingBlockCommentAllowed() {
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("/* header /* nested */ note */ SELECT 1"))
    }

    func testWriteKeywordInsideStringLiteralAllowed() {
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("SELECT 'DROP TABLE users' AS note"))
    }

    func testWriteKeywordInsideCommentAllowed() {
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("SELECT 1 -- UPDATE foo SET x=1\n"))
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("SELECT 1 /* DELETE FROM t */"))
    }

    func testWriteKeywordInQuotedIdentifierAllowed() {
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly(#"SELECT "insert" FROM audit_shadow"#))
    }

    func testMultipleReadStatementsAllowed() {
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("SELECT 1; SELECT 2; SHOW server_version"))
    }

    func testSemicolonInsideStringIsNotASeparator() {
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("SELECT 'a;b;c' AS s"))
    }

    func testEmptyInputAllowed() {
        // Nothing executable → nothing can write.
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("   \n\t"))
    }

    // MARK: - Blocked (writes / DDL / side effects)

    func testInsertBlocked() {
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("INSERT INTO users (name) VALUES ('x')"))
    }

    func testUpdateBlocked() {
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("UPDATE users SET name = 'x' WHERE id = 1"))
    }

    func testDeleteBlocked() {
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("delete from users where id = 1"))
    }

    func testMergeBlocked() {
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DO NOTHING"))
    }

    func testDdlBlocked() {
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("DROP TABLE users"))
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("ALTER TABLE users ADD COLUMN x int"))
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("TRUNCATE users"))
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("CREATE TABLE t (id int)"))
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("GRANT ALL ON t TO alice"))
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("VACUUM FULL users"))
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("COMMENT ON TABLE t IS 'x'"))
    }

    func testDataModifyingCteBlocked() {
        let sql = "WITH gone AS (DELETE FROM users WHERE id = 1 RETURNING *) SELECT * FROM gone"
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly(sql))
        let insertCte = "WITH ins AS (INSERT INTO audit VALUES (1) RETURNING id) SELECT * FROM ins"
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly(insertCte))
    }

    func testExplainAnalyzeOfWriteBlocked() {
        // EXPLAIN ANALYZE actually executes the statement it explains.
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("EXPLAIN ANALYZE INSERT INTO t VALUES (1)"))
    }

    func testMultiStatementWithTrailingWriteBlocked() {
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("SELECT 1; DROP TABLE users"))
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("SELECT 1;\n-- sneaky\nDELETE FROM t;"))
    }

    func testWriteWithLeadingCommentBlocked() {
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("-- looks harmless\nUPDATE t SET x = 1"))
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("/* c */ INSERT INTO t VALUES (1)"))
    }

    func testNonReadLeadingKeywordsBlocked() {
        // Not in the allowed leading set → conservatively blocked, even
        // where the statement is arguably harmless (SET, BEGIN).
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("SET search_path TO public"))
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("BEGIN; SELECT 1; COMMIT"))
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("CALL do_things()"))
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("DO $$ BEGIN NULL; END $$"))
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("COPY t FROM '/tmp/x.csv'"))
    }

    func testSelectForUpdateBlocked() {
        // Documented conservative bias: row locks ride on the UPDATE token.
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("SELECT * FROM users FOR UPDATE"))
    }

    func testKnownSideEffectingFunctionCallsBlocked() {
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("SELECT nextval('orders_id_seq')"))
        XCTAssertFalse(PostgresStatementClassifier.isReadOnly("SELECT set_config('app.mode', 'unsafe', false)"))
    }

    func testDollarQuotedWriteBodyIsData() {
        // The DELETE lives inside a dollar-quoted literal — it's data here
        // (the leading keyword SELECT decides), not an executable write.
        XCTAssertTrue(PostgresStatementClassifier.isReadOnly("SELECT $q$DELETE FROM t$q$::text"))
    }
}
