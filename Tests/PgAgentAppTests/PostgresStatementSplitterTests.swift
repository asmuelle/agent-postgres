import XCTest
@testable import PgAgentApp

// Tests for the top-level statement splitter that powers script execution
// (per-statement timing / result sets). A Swift port of the lexer in
// ssh-commander-pg's exec.rs — these cases mirror that crate's test suite,
// plus offset checks (used to map server error positions back onto the
// editor text).
final class PostgresStatementSplitterTests: XCTestCase {

    private func texts(_ sql: String) -> [String] {
        PostgresStatementSplitter.split(sql).map(\.text)
    }

    // MARK: - Single statements

    func testSingleStatement() {
        XCTAssertEqual(texts("SELECT 1"), ["SELECT 1"])
    }

    func testTrailingSemicolonIsStillSingle() {
        XCTAssertEqual(texts("SELECT 1;"), ["SELECT 1"])
        XCTAssertEqual(texts("SELECT 1;\n  \n"), ["SELECT 1"])
    }

    func testTrailingCommentAfterSemicolonIsDropped() {
        XCTAssertEqual(texts("SELECT 1; -- trailing comment\n"), ["SELECT 1"])
        XCTAssertEqual(texts("SELECT 1; /* block */"), ["SELECT 1"])
    }

    func testEmptyAndWhitespaceOnly() {
        XCTAssertEqual(texts(""), [])
        XCTAssertEqual(texts("   \n\t "), [])
        XCTAssertEqual(texts("-- just a comment\n"), [])
    }

    // MARK: - Multi-statement

    func testTwoStatements() {
        XCTAssertEqual(
            texts("SET x = 1; SELECT 1"),
            ["SET x = 1", "SELECT 1"]
        )
    }

    func testThreeStatementsWithBlankSegments() {
        XCTAssertEqual(
            texts("BEGIN; UPDATE t SET v=1; ; COMMIT;"),
            ["BEGIN", "UPDATE t SET v=1", "COMMIT"]
        )
    }

    func testLeadingCommentStaysWithItsStatement() {
        let statements = PostgresStatementSplitter.split(
            "SELECT 1;\n-- explain the next one\nSELECT 2"
        )
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[1].text, "-- explain the next one\nSELECT 2")
    }

    // MARK: - Semicolons hidden in literals / identifiers / comments

    func testSemicolonInsideStringLiteral() {
        XCTAssertEqual(texts("SELECT 'hello; world'"), ["SELECT 'hello; world'"])
        XCTAssertEqual(texts("SELECT 'it''s; fine'"), ["SELECT 'it''s; fine'"])
        XCTAssertEqual(
            texts("SELECT 'a;b'; SELECT 1"),
            ["SELECT 'a;b'", "SELECT 1"]
        )
    }

    func testSemicolonInsideQuotedIdentifier() {
        XCTAssertEqual(
            texts("SELECT \"weird;name\" FROM t"),
            ["SELECT \"weird;name\" FROM t"]
        )
        XCTAssertEqual(
            texts("SELECT \"col\"; SELECT 1"),
            ["SELECT \"col\"", "SELECT 1"]
        )
    }

    func testSemicolonInsideComments() {
        XCTAssertEqual(texts("SELECT 1 -- ; comment\n"), ["SELECT 1 -- ; comment"])
        XCTAssertEqual(texts("SELECT 1 /* ; */ FROM t"), ["SELECT 1 /* ; */ FROM t"])
        XCTAssertEqual(
            texts("SELECT 1 -- ;\n; SELECT 2"),
            ["SELECT 1 -- ;", "SELECT 2"]
        )
    }

    // MARK: - Dollar quoting

    func testDollarQuotedBodyIsOneStatement() {
        XCTAssertEqual(texts("SELECT $$hello; world$$"), ["SELECT $$hello; world$$"])
        XCTAssertEqual(
            texts("SELECT $tag$hello; world$tag$"),
            ["SELECT $tag$hello; world$tag$"]
        )
        XCTAssertEqual(
            texts("SELECT $$a;b$$; SELECT 1"),
            ["SELECT $$a;b$$", "SELECT 1"]
        )
    }

    func testPlpgsqlFunctionBodySplitsOnlyAtTopLevel() {
        let function = "CREATE FUNCTION f() RETURNS int AS $$ BEGIN; RETURN 1; END; $$ LANGUAGE plpgsql; SELECT f()"
        XCTAssertEqual(
            texts(function),
            [
                "CREATE FUNCTION f() RETURNS int AS $$ BEGIN; RETURN 1; END; $$ LANGUAGE plpgsql",
                "SELECT f()",
            ]
        )
    }

    func testPositionalParameterIsNotADollarQuote() {
        // `$1` must not open a "quote" that swallows the rest of the script.
        XCTAssertEqual(
            texts("SELECT $1; SELECT $2"),
            ["SELECT $1", "SELECT $2"]
        )
    }

    // MARK: - Offsets (error-position mapping)

    func testStartOffsetsAreCharacterOffsetsIntoTheOriginalScript() {
        let sql = "SELECT 1;\n  SELECT 2"
        let statements = PostgresStatementSplitter.split(sql)
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[0].startCharOffset, 0)
        // "SELECT 1;\n  " → the second statement starts at character 12.
        XCTAssertEqual(statements[1].startCharOffset, 12)
        // Round-trip: slicing the original at the offset yields the text.
        for statement in statements {
            let start = sql.index(sql.startIndex, offsetBy: statement.startCharOffset)
            XCTAssertTrue(sql[start...].hasPrefix(statement.text))
        }
    }

    func testOffsetsCountCharactersNotUTF16() {
        // 🐘 is one Character (what errorCharOffset counts) but 2 UTF-16
        // units — the splitter must count Characters.
        let sql = "SELECT '🐘'; SELECT 2"
        let statements = PostgresStatementSplitter.split(sql)
        XCTAssertEqual(statements.count, 2)
        let start = sql.index(sql.startIndex, offsetBy: statements[1].startCharOffset)
        XCTAssertTrue(sql[start...].hasPrefix("SELECT 2"))
    }
}
