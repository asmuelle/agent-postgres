import XCTest

@testable import PgAgentApp

/// Postgres reports error positions in code points (Unicode scalars). The
/// whole position → editor underline path must count code points, not Swift
/// Characters (CRLF = 1 Character / 2 code points; ZWJ emoji = 1 / many).
@MainActor
final class QueryPipelineCodePointTests: XCTestCase {

    // MARK: - Preamble mapping

    func testPreamblePositionAfterCRLFAndEmoji() {
        // Two statements; the error sits in the last one. Offsets are code
        // points: "SELECT '👨‍👩‍👧';\r\n" is 8 + 5 + 2 + 2 = 17 code points.
        let user = "SELECT '👨‍👩‍👧';\r\nSELECT bogus"
        let submission = PostgresSessionPreamble.wrap(user, readOnly: true)
        // "bogus" is at 1-based position 8 within the final statement.
        XCTAssertEqual(submission.userPosition(fromServer: 8), 17 + 8)
    }

    func testPreambleBodyPreservesCodePointsExactly() {
        // e + combining acute: 1 Character, 2 code points.
        let user = "SELECT 'e\u{301}' ;\r\n"
        let submission = PostgresSessionPreamble.wrap(user, readOnly: false)
        XCTAssertEqual(
            Array(submission.sql.unicodeScalars),
            Array("SET default_transaction_read_only = off;\nSELECT 'e\u{301}'".unicodeScalars)
        )
    }

    func testPreamblePositionInBatchPartCountsPrefixInCodePoints() {
        let user = "SET a = '🐘'; SET yyyyyyyyyyyyyyyyyyyy = 2; SELECT 1"
        let prefix = "SET default_transaction_read_only = on;\n"
        let submission = PostgresSessionPreamble.wrap(user, readOnly: true)
        // Server position = prefix + 1-based code-point offset into the user text.
        // "SET a = '🐘'; " is 13 code points → the second SET is at 1-based 14.
        let userPos = 14
        let server = UInt32(prefix.unicodeScalars.count + userPos)
        XCTAssertEqual(submission.userPosition(fromServer: server), UInt32(userPos))
    }

    // MARK: - Store mapping (leading whitespace)

    func testStoreShiftsByLeadingWhitespaceCodePoints() {
        // "\r\n\r\n  " is 6 code points (2 Characters + 2 spaces = 4 Characters).
        let offset = PostgresQueryTabsStore.editorScalarOffset(
            forServerPosition: 8,
            inTrimmedSQLOf: "\r\n\r\n  SELECT bogus"
        )
        XCTAssertEqual(offset, 6 + 7)
    }

    func testStoreRejectsOutOfRangePositions() {
        XCTAssertNil(PostgresQueryTabsStore.editorScalarOffset(forServerPosition: 0, inTrimmedSQLOf: "SELECT"))
        XCTAssertNil(PostgresQueryTabsStore.editorScalarOffset(forServerPosition: 99, inTrimmedSQLOf: "SELECT"))
        // One past the end is allowed (e.g. `SELECT 1 +`).
        XCTAssertEqual(PostgresQueryTabsStore.editorScalarOffset(forServerPosition: 7, inTrimmedSQLOf: "SELECT"), 6)
    }

    func testSetErrorPositionUsesCodePoints() {
        let store = PostgresQueryTabsStore()
        let id = store.openBlankTab()
        store.setSQL("\r\nSELECT '👨‍👩‍👧', bogus", forTab: id)
        // "bogus" in the trimmed text: "SELECT '" (8) + 5 + "', " (3) → position 17.
        store.setErrorPosition(17, forTab: id)
        XCTAssertEqual(store.tabs.first?.errorCharOffset, 2 + 16)
    }

    // MARK: - Editor range

    func testErrorWordRangeAfterEmojiAndCRLF() throws {
        let text = "SELECT '👨‍👩‍👧';\r\nSELECT bogus FROM t"
        let offset = text.unicodeScalars.count - "bogus FROM t".unicodeScalars.count
        let range = try XCTUnwrap(PostgresSQLEditor.Coordinator.errorWordRange(in: text, charOffset: offset))
        XCTAssertEqual((text as NSString).substring(with: range), "bogus")
    }

    func testErrorWordRangeOnePastEndUnderlinesLastCodePoint() throws {
        let text = "SELECT 1 +"
        let range = try XCTUnwrap(PostgresSQLEditor.Coordinator.errorWordRange(
            in: text, charOffset: text.unicodeScalars.count
        ))
        XCTAssertEqual((text as NSString).substring(with: range), "+")
    }

    func testErrorWordRangeRejectsOutOfRange() {
        XCTAssertNil(PostgresSQLEditor.Coordinator.errorWordRange(in: "SELECT", charOffset: 7))
        XCTAssertNil(PostgresSQLEditor.Coordinator.errorWordRange(in: "", charOffset: 0))
    }

    // MARK: - End to end (splitter → server position → editor range)

    func testScriptStatementOffsetMapsToEditorRange() throws {
        let script = "SELECT '🐘';\r\n  SELECT nope FROM t"
        let statements = PostgresStatementSplitter.split(script)
        XCTAssertEqual(statements.count, 2)
        // Server reports "nope" at 1-based position 8 of statement 2.
        let absolute = statements[1].startScalarOffset + 8 - 1
        let range = try XCTUnwrap(PostgresSQLEditor.Coordinator.errorWordRange(in: script, charOffset: absolute))
        XCTAssertEqual((script as NSString).substring(with: range), "nope")
    }
}
