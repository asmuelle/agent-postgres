import XCTest
@testable import PgAgentApp

// Tests for the shared export encoders (CSV / TSV clipboard / JSONL) and
// the export outcome → summary mapping. The CRLF cases are the regression
// guard: "\r\n" is a single Swift Character, so Character-based
// `contains("\n")` checks used to miss it and split the row.
final class PostgresExportEncodingTests: XCTestCase {
    private typealias E = PostgresExportEncoding

    // MARK: - CSV field

    func testCSVPlainValuePassesThrough() {
        XCTAssertEqual(E.csvField("hello"), "hello")
        XCTAssertEqual(E.csvField("a b"), "a b")
    }

    func testCSVCommaIsQuoted() {
        XCTAssertEqual(E.csvField("a,b"), "\"a,b\"")
    }

    func testCSVQuoteIsDoubledAndQuoted() {
        XCTAssertEqual(E.csvField("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(E.csvField("\""), "\"\"\"\"")
    }

    func testCSVLineFeedIsQuoted() {
        XCTAssertEqual(E.csvField("a\nb"), "\"a\nb\"")
    }

    func testCSVCarriageReturnIsQuoted() {
        XCTAssertEqual(E.csvField("a\rb"), "\"a\rb\"")
    }

    func testCSVCRLFIsQuoted() {
        XCTAssertEqual(E.csvField("a\r\nb"), "\"a\r\nb\"")
        XCTAssertEqual(E.csvField("\r\n"), "\"\r\n\"")
        XCTAssertTrue(E.csvNeedsQuoting("line1\r\nline2"))
    }

    func testCSVLeadingOrTrailingWhitespaceIsQuoted() {
        XCTAssertEqual(E.csvField(" a"), "\" a\"")
        XCTAssertEqual(E.csvField("a "), "\"a \"")
        XCTAssertEqual(E.csvField("\ta"), "\"\ta\"")
        XCTAssertEqual(E.csvField(" "), "\" \"")
    }

    func testCSVNullIsUnquotedEmptyAndEmptyStringIsQuoted() {
        XCTAssertEqual(E.csvField(nil), "")
        XCTAssertEqual(E.csvField(""), "\"\"")
    }

    func testCSVNonASCIIPassesThrough() {
        XCTAssertEqual(E.csvField("über 🐘"), "über 🐘")
    }

    func testCSVRowJoinsFields() {
        XCTAssertEqual(E.csvRow(["1", nil, "", "x,y", "a\r\nb"]), "1,,\"\",\"x,y\",\"a\r\nb\"")
    }

    // MARK: - TSV (clipboard)

    func testTSVTabBecomesSpace() {
        XCTAssertEqual(E.tsvField("a\tb"), "a b")
    }

    func testTSVAllLineBreaksBecomeLiteralBackslashN() {
        XCTAssertEqual(E.tsvField("a\nb"), "a\\nb")
        XCTAssertEqual(E.tsvField("a\rb"), "a\\nb")
        XCTAssertEqual(E.tsvField("a\r\nb"), "a\\nb")
        XCTAssertEqual(E.tsvField("a\r\n\r\nb"), "a\\n\\nb")
        XCTAssertEqual(E.tsvField("a\n\rb"), "a\\n\\nb")
    }

    func testTSVPlainValueUnchanged() {
        XCTAssertEqual(E.tsvField("plain, \"quoted\""), "plain, \"quoted\"")
    }

    // MARK: - JSON

    func testJSONStringEscapes() {
        XCTAssertEqual(E.jsonString("a\"b\\c"), "\"a\\\"b\\\\c\"")
        XCTAssertEqual(E.jsonString("a\r\nb\tc"), "\"a\\r\\nb\\tc\"")
        XCTAssertEqual(E.jsonString("\u{08}\u{0C}"), "\"\\b\\f\"")
        XCTAssertEqual(E.jsonString("\u{01}\u{1F}"), "\"\\u0001\\u001f\"")
        XCTAssertEqual(E.jsonString("/ über 🐘"), "\"/ über 🐘\"")
    }

    func testJSONObjectKeepsColumnOrderAndNull() {
        XCTAssertEqual(
            E.jsonObject(keys: ["z", "a"], values: ["1", nil]),
            "{\"z\":\"1\",\"a\":null}"
        )
    }

    func testJSONObjectRoundTripsThroughJSONSerialization() throws {
        let values: [String?] = ["a\r\nb", "\"q\"", "\u{00}", nil, "🐘"]
        let keys = ["c1", "c2", "c3", "c4", "c5"]
        let line = E.jsonObject(keys: keys, values: values)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(obj["c1"] as? String, "a\r\nb")
        XCTAssertEqual(obj["c2"] as? String, "\"q\"")
        XCTAssertEqual(obj["c3"] as? String, "\u{00}")
        XCTAssertTrue(obj["c4"] is NSNull)
        XCTAssertEqual(obj["c5"] as? String, "🐘")
    }

    func testUniqueKeysSuffixesDuplicates() {
        XCTAssertEqual(E.uniqueKeys(["id", "name", "id", "id"]), ["id", "name", "id_2", "id_3"])
        // A suffix that collides with a real column name is skipped.
        XCTAssertEqual(E.uniqueKeys(["id", "id_2", "id"]), ["id", "id_2", "id_3"])
    }

    // MARK: - Column plan

    func testPlanSkipsHiddenColumnsAndProjects() {
        let plan = PostgresExportColumnPlan(resultColumnNames: ["__pg_rowid__", "a", "b"])
        XCTAssertEqual(plan.names, ["a", "b"])
        XCTAssertEqual(plan.indices, [1, 2])
        // Short row → missing cells become NULL.
        XCTAssertEqual(plan.project(["ctid", "1"]), ["1", nil])
    }

    func testPlanRendersCSVAndJSONLLines() {
        let plan = PostgresExportColumnPlan(resultColumnNames: ["id", "note", "id"])
        XCTAssertEqual(plan.csvHeaderLine, "id,note,id\n")
        XCTAssertEqual(plan.csvLine(["1", "x\r\ny", nil]), "1,\"x\r\ny\",\n")
        XCTAssertEqual(
            plan.jsonlLine(["1", "x\r\ny", nil]),
            "{\"id\":\"1\",\"note\":\"x\\r\\ny\",\"id_2\":null}\n"
        )
    }

    func testPlanWithOnlyHiddenColumnsIsEmpty() {
        XCTAssertTrue(PostgresExportColumnPlan(resultColumnNames: ["__pg_rowid__"]).isEmpty)
    }

    // MARK: - Outcome summary

    func testOutcomeSummaries() {
        let path = "/tmp/out.csv"
        XCTAssertEqual(
            PostgresExportOutcome.completed(rows: 1).summary(path: path, format: .csv).message,
            "Wrote 1 row to /tmp/out.csv."
        )
        XCTAssertEqual(
            PostgresExportOutcome.cancelled(rows: 3).summary(path: path, format: .jsonl).message,
            "Stopped after 3 rows. The partial file is at /tmp/out.csv."
        )
        XCTAssertEqual(
            PostgresExportOutcome.cancelled(rows: 3).summary(path: path, format: .parquet).message,
            "Stopped after 3 rows. Partial Parquet file at /tmp/out.csv."
        )
        XCTAssertEqual(
            PostgresExportOutcome.openFailed(message: "x").summary(path: path, format: .parquet).title,
            "Couldn't open Parquet file"
        )
        XCTAssertEqual(
            PostgresExportOutcome.failed(rows: 2, message: nil).summary(path: path, format: .csv).message,
            "Unknown error after 2 rows."
        )
    }

    // MARK: - Line file sink

    func testLineFileSinkWritesHeaderAndRows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let plan = PostgresExportColumnPlan(resultColumnNames: ["a", "b"])
        let sink = try PostgresLineFileSink(url: url, format: .csv, plan: plan)
        try sink.append([FfiPgRow(cells: ["1", "x,y"]), FfiPgRow(cells: [nil, "a\r\nb"])][...])
        try sink.finish()
        sink.abort() // no-op after finish
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, "a,b\n1,\"x,y\"\n,\"a\r\nb\"\n")
    }
}
