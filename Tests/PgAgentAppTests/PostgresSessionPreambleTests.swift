import XCTest
@testable import PgAgentApp

// `pgExecute` prefixes every statement with a read-only SET. The core only
// routes the user's statement through its cursor path when something real
// follows the last top-level `;`, so a trailing `;` must never survive into
// the submitted text — otherwise browse tabs lose cursors and column types.
final class PostgresSessionPreambleTests: XCTestCase {

    private let prefixOn = "SET default_transaction_read_only = on;\n"

    func testTrailingSemicolonIsStrippedFromSingleStatement() {
        let submission = PostgresSessionPreamble.wrap("SELECT * FROM t;", readOnly: true)
        XCTAssertEqual(submission.sql, prefixOn + "SELECT * FROM t")
    }

    func testTrailingWhitespaceAndCommentTailAreStripped() {
        let submission = PostgresSessionPreamble.wrap("  SELECT 1;\n -- done\n", readOnly: false)
        XCTAssertEqual(submission.sql, "SET default_transaction_read_only = off;\nSELECT 1")
    }

    func testSingleStatementPositionMapsBackOntoUserText() {
        // Server positions are relative to the trimmed main statement.
        let submission = PostgresSessionPreamble.wrap("\n\n  SELECT bogus;", readOnly: true)
        XCTAssertEqual(submission.userPosition(fromServer: 8), 12)
    }

    func testEmptyInputIsSentUnchanged() {
        let submission = PostgresSessionPreamble.wrap("  -- nothing\n", readOnly: true)
        XCTAssertEqual(submission.sql, "  -- nothing\n")
        XCTAssertEqual(submission.userPosition(fromServer: 3), 3)
    }

    func testMultiStatementKeepsCursorOnLastStatement() {
        let submission = PostgresSessionPreamble.wrap("SET x = 1; SELECT 1;\n", readOnly: true)
        XCTAssertEqual(submission.sql, prefixOn + "SET x = 1; SELECT 1")
    }

    func testMultiStatementPositionInLastStatement() {
        // "SELECT oops" starts at user offset 11; server reports within main.
        let submission = PostgresSessionPreamble.wrap("SET x = 1; SELECT oops;", readOnly: true)
        XCTAssertEqual(submission.userPosition(fromServer: 8), 19)
    }

    func testMultiStatementPositionInPreambleSubtractsPrefix() {
        let user = "SET x = 1; SET yyyyyyyyyyyyyyyyyyyy = 2; SELECT 1"
        let submission = PostgresSessionPreamble.wrap(user, readOnly: true)
        let serverPosition = UInt32(prefixOn.count + 15)
        XCTAssertEqual(submission.userPosition(fromServer: serverPosition), 15)
    }
}
