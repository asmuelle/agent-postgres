// Routine-check line → editor offset mapping and the shared error-underline
// range both work in code points (what Postgres reports and the editors
// consume), so emoji and CRLF line endings before the target can't shift it.

import XCTest
@testable import PgAgentApp

final class FCodePointOffsetTests: XCTestCase {

    func testLineOffsetCountsCodePointsAfterEmoji() {
        // "👍🏽" is one Character but two code points.
        let text = "-- 👍🏽\n  x := 1;"
        let offset = PostgresRoutineCheck.charOffset(ofLine: 2, in: text)
        XCTAssertEqual(offset, "-- 👍🏽\n  ".unicodeScalars.count)
    }

    func testLineOffsetCountsCRLFAsTwoCodePoints() {
        let text = "a\r\nb\r\n\tc"
        XCTAssertEqual(PostgresRoutineCheck.charOffset(ofLine: 1, in: text), 0)
        XCTAssertEqual(PostgresRoutineCheck.charOffset(ofLine: 2, in: text), 3)
        XCTAssertEqual(PostgresRoutineCheck.charOffset(ofLine: 3, in: text), 7)
        XCTAssertNil(PostgresRoutineCheck.charOffset(ofLine: 4, in: text))
        XCTAssertNil(PostgresRoutineCheck.charOffset(ofLine: 0, in: text))
    }

    func testBodyLineMappingWithCRLF() {
        let def = "CREATE FUNCTION f() RETURNS int\r\nLANGUAGE plpgsql AS $$\r\nBEGIN\r\n  RETURN 1;\r\nEND $$;"
        // Body line 3 → editor line 4 ("  RETURN 1;"), first non-blank.
        let offset = PostgresRoutineCheck.bodyLineToCharOffset(editorText: def, bodyLine: 3)
        let expected = def.unicodeScalars.count
            - "RETURN 1;\r\nEND $$;".unicodeScalars.count
        XCTAssertEqual(offset, expected)
    }

    func testSharedErrorWordRangeMapsCodePointsToUTF16() throws {
        // Code point 3 is "b" in "é👍 bad" only when counted in scalars.
        let text = "é👍 bad"
        let offset = "é👍 ".unicodeScalars.count
        let range = try XCTUnwrap(SQLSyntaxHighlighting.errorWordRange(in: text, codePointOffset: offset))
        XCTAssertEqual((text as NSString).substring(with: range), "bad")
    }

    func testSharedErrorWordRangeOnePastEndUnderlinesLastCodePoint() throws {
        let text = "SELECT 1 +"
        let range = try XCTUnwrap(SQLSyntaxHighlighting.errorWordRange(in: text, codePointOffset: text.unicodeScalars.count))
        XCTAssertEqual((text as NSString).substring(with: range), "+")
        XCTAssertNil(SQLSyntaxHighlighting.errorWordRange(in: text, codePointOffset: text.unicodeScalars.count + 1))
    }
}
