import XCTest
@testable import PgAgentApp

/// `PgQueryHandoff` is the payload a query tab hands to the user's other
/// devices (Mac ↔ iPad ↔ iPhone). It carries what to open — never results,
/// never credentials — and the receiving side only opens a tab, never runs.
final class PgQueryHandoffTests: XCTestCase {

    func testRoundTripsThroughUserInfo() throws {
        let handoff = try XCTUnwrap(PgQueryHandoff(profileId: "p1", sql: "SELECT 1", title: "Query 1"))
        let decoded = PgQueryHandoff(userInfo: handoff.userInfo)
        XCTAssertEqual(decoded, handoff)
    }

    func testNothingToHandOffForBlankSQL() {
        XCTAssertNil(PgQueryHandoff(profileId: "p1", sql: "  \n ", title: "Query 1"))
    }

    /// Handoff payloads are meant to be small; a huge script isn't advertised
    /// rather than being cut off mid-statement.
    func testOversizedSQLIsNotHandedOff() {
        let sql = "SELECT '" + String(repeating: "x", count: PgQueryHandoff.maxSQLBytes) + "'"
        XCTAssertNil(PgQueryHandoff(profileId: "p1", sql: sql, title: "Big"))
    }

    func testLongTitleIsShortened() throws {
        let handoff = try XCTUnwrap(PgQueryHandoff(
            profileId: "p1", sql: "SELECT 1", title: String(repeating: "t", count: 500)
        ))
        XCTAssertEqual(handoff.title.count, PgQueryHandoff.maxTitleLength)
    }

    /// Titles arrive from another device and end up in the tab bar and in
    /// file names: line breaks and other control characters become spaces.
    func testTitleControlCharactersBecomeSpaces() throws {
        let handoff = try XCTUnwrap(PgQueryHandoff(profileId: "p1", sql: "SELECT 1", title: "Query\n1\t\u{0}x"))
        XCTAssertEqual(handoff.title, "Query 1  x")
    }

    func testRejectsAnotherVersion() {
        var info = PgQueryHandoff(profileId: "p1", sql: "SELECT 1", title: "Q")!.userInfo
        info["v"] = "99"
        XCTAssertNil(PgQueryHandoff(userInfo: info))
    }

    func testRejectsMissingOrMistypedFields() {
        XCTAssertNil(PgQueryHandoff(userInfo: nil))
        XCTAssertNil(PgQueryHandoff(userInfo: ["v": "1", "sql": "SELECT 1", "title": "Q"]))
        XCTAssertNil(PgQueryHandoff(userInfo: ["v": "1", "profileId": "p1", "sql": 42, "title": "Q"]))
    }

    /// The receiving side applies the same limits as the sending side.
    func testRejectsOversizedIncomingSQL() {
        let sql = String(repeating: "x", count: PgQueryHandoff.maxSQLBytes + 1)
        XCTAssertNil(PgQueryHandoff(userInfo: ["v": "1", "profileId": "p1", "sql": sql, "title": "Q"]))
    }
}

/// Results shared from the iPad as a CSV file.
final class PostgresCSVDocumentTests: XCTestCase {

    func testHeaderRowsAndHiddenHelperColumns() {
        let csv = PostgresExportEncoding.csvDocument(
            columnNames: ["id", "__pg_rowid__", "note"],
            rows: [["1", "(0,1)", "a, b"], ["2", "(0,2)", nil], ["3", "(0,3)", ""]]
        )
        XCTAssertEqual(csv, "id,note\n1,\"a, b\"\n2,\n3,\"\"\n")
    }
}

/// The row inspector shows JSON values re-indented — but otherwise exactly
/// as stored: a database client must never show `19.989999999999998` for a
/// stored `19.99`, drop a duplicate key or reorder keys.
final class PostgresCellFormattingTests: XCTestCase {

    func testIndentsObjectsKeepingKeyOrder() {
        XCTAssertEqual(
            PostgresCellFormatting.prettyJSON(#"{"b":1,"a":[true,null]}"#),
            "{\n  \"b\": 1,\n  \"a\": [\n    true,\n    null\n  ]\n}"
        )
    }

    func testKeepsNumbersExactlyAsStored() {
        XCTAssertEqual(
            PostgresCellFormatting.prettyJSON(#"{"price": 19.99, "qty": 1.10, "big": 123456789012345678901234567890, "tiny": 1.0e-7}"#),
            "{\n  \"price\": 19.99,\n  \"qty\": 1.10,\n  \"big\": 123456789012345678901234567890,\n  \"tiny\": 1.0e-7\n}"
        )
    }

    func testKeepsDuplicateKeys() {
        XCTAssertEqual(
            PostgresCellFormatting.prettyJSON(#"{"a":1,"a":2}"#),
            "{\n  \"a\": 1,\n  \"a\": 2\n}"
        )
    }

    func testLeavesStringsAloneEvenWithStructuralCharacters() {
        XCTAssertEqual(
            PostgresCellFormatting.prettyJSON(#"["a, b: {c} [d]", "q\"u\\", "Zürich 🇨🇭"]"#),
            "[\n  \"a, b: {c} [d]\",\n  \"q\\\"u\\\\\",\n  \"Zürich 🇨🇭\"\n]"
        )
    }

    func testEmptyContainersStayOnOneLine() {
        XCTAssertEqual(
            PostgresCellFormatting.prettyJSON(#"{"a": {}, "b": [ ], "c": [{}]}"#),
            "{\n  \"a\": {},\n  \"b\": [],\n  \"c\": [\n    {}\n  ]\n}"
        )
    }

    func testLeavesNonJSONAlone() {
        XCTAssertNil(PostgresCellFormatting.prettyJSON("hello"))
        XCTAssertNil(PostgresCellFormatting.prettyJSON("42"))
        XCTAssertNil(PostgresCellFormatting.prettyJSON("{not json"))
        XCTAssertNil(PostgresCellFormatting.prettyJSON(#"{"a": 1} trailing"#))
    }
}

/// The file name a shared or dragged CSV gets.
final class PostgresCSVFileNameTests: XCTestCase {

    func testUsesTheTabTitle() {
        XCTAssertEqual(PostgresExportEncoding.csvFileName(forTitle: "public.orders"), "public.orders.csv")
    }

    func testReplacesCharactersFilesCantHold() {
        XCTAssertEqual(PostgresExportEncoding.csvFileName(forTitle: "a/b:c\nd"), "a-b-c-d.csv")
    }

    func testFallsBackForABlankTitle() {
        XCTAssertEqual(PostgresExportEncoding.csvFileName(forTitle: "  "), "Results.csv")
    }
}
