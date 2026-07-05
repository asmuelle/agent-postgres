import XCTest
@testable import PgAgentApp

// Tests for the TextMate-style snippet placeholder parser: expansion of
// `${n:default}` / `$n` / `$0` markup, tab-stop ordering by number, UTF-16
// range correctness (what the NSTextView session consumes), and escape /
// malformed-markup behavior.
final class PostgresSnippetPlaceholdersTests: XCTestCase {

    // MARK: - Plain text

    func testPlainTextHasNoStops() {
        let parsed = PostgresSnippetPlaceholders.parse("SELECT 1;")
        XCTAssertEqual(parsed.text, "SELECT 1;")
        XCTAssertTrue(parsed.tabStops.isEmpty)
        XCTAssertNil(parsed.finalCursorUTF16)
    }

    func testContainsPlaceholdersDetection() {
        XCTAssertFalse(PostgresSnippetPlaceholders.containsPlaceholders("SELECT 1"))
        XCTAssertTrue(PostgresSnippetPlaceholders.containsPlaceholders("SELECT ${1:x}"))
        XCTAssertTrue(PostgresSnippetPlaceholders.containsPlaceholders("SELECT 1;$0"))
    }

    // MARK: - Braced placeholders

    func testBracedPlaceholderExpandsDefaultAndRecordsRange() {
        let parsed = PostgresSnippetPlaceholders.parse("SELECT ${1:*} FROM t")
        XCTAssertEqual(parsed.text, "SELECT * FROM t")
        XCTAssertEqual(parsed.tabStops.count, 1)
        XCTAssertEqual(parsed.tabStops[0].number, 1)
        XCTAssertEqual(parsed.tabStops[0].location, 7)
        XCTAssertEqual(parsed.tabStops[0].length, 1)
    }

    func testEmptyBracedPlaceholder() {
        let parsed = PostgresSnippetPlaceholders.parse("WHERE ${1}")
        XCTAssertEqual(parsed.text, "WHERE ")
        XCTAssertEqual(parsed.tabStops, [
            PostgresSnippetTabStop(number: 1, location: 6, length: 0)
        ])
    }

    func testMultiplePlaceholdersOrderByNumberNotPosition() {
        // $2 appears before $1 in the body — tab order must still be 1, 2.
        let parsed = PostgresSnippetPlaceholders.parse("${2:b} and ${1:a}")
        XCTAssertEqual(parsed.text, "b and a")
        XCTAssertEqual(parsed.tabStops.map(\.number), [1, 2])
        XCTAssertEqual(parsed.tabStops[0].location, 6) // "a"
        XCTAssertEqual(parsed.tabStops[1].location, 0) // "b"
    }

    func testEqualNumbersOrderByPosition() {
        let parsed = PostgresSnippetPlaceholders.parse("${1:x} ${1:y}")
        XCTAssertEqual(parsed.tabStops.count, 2)
        XCTAssertEqual(parsed.tabStops[0].location, 0)
        XCTAssertEqual(parsed.tabStops[1].location, 2)
    }

    // MARK: - Bare placeholders and $0

    func testBarePlaceholderIsEmptyStop() {
        let parsed = PostgresSnippetPlaceholders.parse("LIMIT $1;")
        XCTAssertEqual(parsed.text, "LIMIT ;")
        XCTAssertEqual(parsed.tabStops, [
            PostgresSnippetTabStop(number: 1, location: 6, length: 0)
        ])
    }

    func testFinalCursor() {
        let parsed = PostgresSnippetPlaceholders.parse("SELECT ${1:1};$0\n")
        XCTAssertEqual(parsed.text, "SELECT 1;\n")
        XCTAssertEqual(parsed.finalCursorUTF16, 9) // just after the ;
        XCTAssertEqual(parsed.tabStops.map(\.number), [1])
    }

    func testFirstFinalCursorWins() {
        let parsed = PostgresSnippetPlaceholders.parse("a$0b$0c")
        XCTAssertEqual(parsed.text, "abc")
        XCTAssertEqual(parsed.finalCursorUTF16, 1)
    }

    // MARK: - Escapes and malformed markup

    func testEscapedDollarIsLiteral() {
        let parsed = PostgresSnippetPlaceholders.parse(#"SELECT '\$1'"#)
        XCTAssertEqual(parsed.text, "SELECT '$1'")
        XCTAssertTrue(parsed.tabStops.isEmpty)
    }

    func testLoneDollarPassesThrough() {
        // Postgres dollar-quoting must survive: $$ … $$ has no digits.
        let parsed = PostgresSnippetPlaceholders.parse("SELECT $$a$$")
        XCTAssertEqual(parsed.text, "SELECT $$a$$")
        XCTAssertTrue(parsed.tabStops.isEmpty)
    }

    func testUnterminatedBracedPlaceholderStaysVerbatim() {
        let parsed = PostgresSnippetPlaceholders.parse("SELECT ${1:oops")
        XCTAssertEqual(parsed.text, "SELECT ${1:oops")
        XCTAssertTrue(parsed.tabStops.isEmpty)
    }

    func testEscapedClosingBraceInsideContent() {
        let parsed = PostgresSnippetPlaceholders.parse(#"${1:a\}b}"#)
        XCTAssertEqual(parsed.text, "a}b")
        XCTAssertEqual(parsed.tabStops[0].length, 3)
    }

    // MARK: - UTF-16 offsets

    func testOffsetsAreUTF16ForNonBMPCharacters() {
        // 🐘 is 2 UTF-16 units; the stop after it must account for that.
        let parsed = PostgresSnippetPlaceholders.parse("🐘 ${1:x}")
        XCTAssertEqual(parsed.text, "🐘 x")
        XCTAssertEqual(parsed.tabStops[0].location, 3) // 2 (🐘) + 1 (space)
        XCTAssertEqual(parsed.tabStops[0].length, 1)
    }

    // MARK: - Starter snippets sanity

    func testStarterSnippetsAllParseWithStopsAndFinalCursor() {
        for snippet in PostgresSnippetsStore.starterSnippets {
            let parsed = PostgresSnippetPlaceholders.parse(snippet.body)
            XCTAssertFalse(parsed.tabStops.isEmpty, "\(snippet.title) should have tab stops")
            XCTAssertNotNil(parsed.finalCursorUTF16, "\(snippet.title) should define $0")
            XCTAssertFalse(parsed.text.contains("${"), "\(snippet.title) left raw markup")
            // Stops must be in strictly valid ranges of the expanded text.
            let utf16Count = parsed.text.utf16.count
            for stop in parsed.tabStops {
                XCTAssertGreaterThanOrEqual(stop.location, 0)
                XCTAssertLessThanOrEqual(stop.location + stop.length, utf16Count)
            }
        }
    }
}
