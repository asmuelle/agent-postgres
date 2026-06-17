// Tests for the plpgsql_check layer: probe/findings parsing and — the bug-prone
// part — mapping a body line number onto a character offset in the editor's
// full CREATE text (plpgsql_check counts lines from the dollar-quoted body).

import XCTest
@testable import PgAgentApp

final class PostgresRoutineCheckParseTests: XCTestCase {

    func testParseProbe() {
        let p = PostgresRoutineCheck.parseProbe(row: ["true", "plpgsql"])!
        XCTAssertTrue(p.hasExtension)
        XCTAssertTrue(p.isPlpgsql)
        let p2 = PostgresRoutineCheck.parseProbe(row: ["false", "sql"])!
        XCTAssertFalse(p2.hasExtension)
        XCTAssertFalse(p2.isPlpgsql)
    }

    func testParseFindingsLevelsAndFields() {
        // Columns: level, lineno, message, detail, hint, sqlstate.
        let rows: [[String?]] = [
            ["error", "5", "column t.nope does not exist", nil, "Perhaps you meant t.name.", "42703"],
            ["warning", "9", "variable \"x\" is never used", "unused", nil, nil],
            ["performance", nil, "no RETURN statement", nil, nil, nil],
        ]
        let f = PostgresRoutineCheck.parseFindings(rows: rows)
        XCTAssertEqual(f.count, 3)
        XCTAssertEqual(f[0].level, .error)
        XCTAssertEqual(f[0].lineno, 5)
        XCTAssertEqual(f[0].hint, "Perhaps you meant t.name.")
        XCTAssertEqual(f[0].sqlstate, "42703")
        XCTAssertEqual(f[1].level, .warning)
        XCTAssertEqual(f[1].detail, "unused")
        XCTAssertEqual(f[2].level, .performance)
        XCTAssertNil(f[2].lineno)
    }

    func testParseFindingsSkipsRowsWithoutMessage() {
        XCTAssertTrue(PostgresRoutineCheck.parseFindings(rows: [["error", "1", nil, nil, nil, nil]]).isEmpty)
    }

    func testCheckQueryEscapesLiterals() {
        let q = PostgresRoutineCheck.checkQuery(schema: "we'ird", name: "f'n", signature: "a integer")
        XCTAssertTrue(q.contains("'we''ird'"))
        XCTAssertTrue(q.contains("'f''n'"))
        XCTAssertTrue(q.contains("plpgsql_check_function_tb"))
    }
}

final class PostgresRoutineCheckLineMapTests: XCTestCase {

    // Mirrors pg_get_functiondef layout (verified against live PG 18):
    //   line 1: CREATE OR REPLACE FUNCTION ctest.buggy(p_id integer)
    //   line 2:  RETURNS text
    //   line 3:  LANGUAGE plpgsql
    //   line 4: AS $function$         ← opener
    //   line 5: DECLARE               ← body line 2
    //   line 6:   v_name text;
    //   line 7: BEGIN
    //   line 8:   SELECT t.nope ...;  ← body line 5 (the reported finding)
    private let def = """
        CREATE OR REPLACE FUNCTION ctest.buggy(p_id integer)
         RETURNS text
         LANGUAGE plpgsql
        AS $function$
        DECLARE
          v_name text;
        BEGIN
          SELECT t.nope INTO v_name FROM ctest.t WHERE t.id = p_id;
          RETURN v_undeclared;
        END;
        $function$
        """

    func testOpenerLineDetected() {
        XCTAssertEqual(PostgresRoutineCheck.dollarQuoteOpenerLine(in: def), 4)
    }

    func testBodyLine5MapsToEditorLine8() {
        // plpgsql_check reported lineno=5 for the SELECT; that's editor line 8.
        let offset = PostgresRoutineCheck.bodyLineToCharOffset(editorText: def, bodyLine: 5)!
        // Resolve the offset back to a line and confirm it lands on the SELECT.
        let prefix = String(Array(def)[0..<offset])
        let line = prefix.components(separatedBy: "\n").count // 1-based line of the offset
        XCTAssertEqual(line, 8)
        // And it skips the leading whitespace onto the statement text.
        let idx = def.index(def.startIndex, offsetBy: offset)
        XCTAssertTrue(def[idx...].hasPrefix("SELECT"))
    }

    func testBodyLine2MapsToDeclare() {
        let offset = PostgresRoutineCheck.bodyLineToCharOffset(editorText: def, bodyLine: 2)!
        let idx = def.index(def.startIndex, offsetBy: offset)
        XCTAssertTrue(def[idx...].hasPrefix("DECLARE"))
    }

    func testSingleLineBodyMapsToOpenerLine() {
        // `AS $$ SELECT 1 $$` — body line 1 is on the opener line itself.
        let oneLine = "CREATE FUNCTION f() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$"
        let offset = PostgresRoutineCheck.bodyLineToCharOffset(editorText: oneLine, bodyLine: 1)!
        let idx = oneLine.index(oneLine.startIndex, offsetBy: offset)
        // First non-whitespace at/after the opener line start is the CREATE text.
        XCTAssertTrue(oneLine[idx...].hasPrefix("CREATE"))
    }

    func testOutOfRangeReturnsNil() {
        XCTAssertNil(PostgresRoutineCheck.bodyLineToCharOffset(editorText: def, bodyLine: 999))
        XCTAssertNil(PostgresRoutineCheck.bodyLineToCharOffset(editorText: def, bodyLine: 0))
    }

    func testNoDollarQuoteFallsBackToTextLines() {
        // No dollar-quote → opener defaults to line 1, so body line N == editor line N.
        let text = "line one\nline two\nline three"
        let offset = PostgresRoutineCheck.bodyLineToCharOffset(editorText: text, bodyLine: 2)!
        let idx = text.index(text.startIndex, offsetBy: offset)
        XCTAssertTrue(text[idx...].hasPrefix("line two"))
    }
}
