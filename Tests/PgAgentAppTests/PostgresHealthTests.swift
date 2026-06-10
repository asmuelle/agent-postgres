// Tests for PgHealthParser — health dashboard row→model mapping.

import XCTest
@testable import PgAgentApp

final class PostgresHealthTests: XCTestCase {

    func testTopQueriesParsing() {
        let rows: [[String?]] = [
            ["SELECT 1", "120", "532.1", "4.43", "120"],
            [nil, "1", "1", "1", "1"],  // NULL query text → skipped
            ["short"],  // malformed → skipped
        ]
        let parsed = PgHealthParser.topQueries(rows)

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].query, "SELECT 1")
        XCTAssertEqual(parsed[0].calls, "120")
        XCTAssertEqual(parsed[0].totalMs, "532.1")
        XCTAssertEqual(parsed[0].meanMs, "4.43")
        XCTAssertEqual(parsed[0].rows, "120")
    }

    func testDeadTuplesParsingWithNullFallbacks() {
        let rows: [[String?]] = [
            ["public", "orders", "10000", "2500", "20.0", "2026-06-01 10:00:00"],
            ["public", "events", nil, "9", nil, nil],
        ]
        let parsed = PgHealthParser.deadTuples(rows)

        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].table, "orders")
        XCTAssertEqual(parsed[0].deadPercent, "20.0")
        XCTAssertEqual(parsed[1].liveTuples, "0")
        XCTAssertEqual(parsed[1].lastVacuum, "never")
    }

    func testUnusedIndexesParsing() {
        let rows: [[String?]] = [
            ["public", "orders", "orders_note_idx", "12 MB"],
            [nil, "t", "i", "1 kB"],  // NULL schema → skipped
        ]
        let parsed = PgHealthParser.unusedIndexes(rows)

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].index, "orders_note_idx")
        XCTAssertEqual(parsed[0].size, "12 MB")
    }
}
