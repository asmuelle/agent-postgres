import XCTest

// `MaintenanceModel.swift` + `PostgresSQLQuoting.swift` are compiled directly
// into this logic-test target (see project.yml) — the same pure parsing and SQL
// the Maintenance tab ships, with no app host or FFI bridge required.

final class MaintenanceModelTests: XCTestCase {

    // MARK: - Row parsing

    func testParsesAndRanksByDeadTuplesDescending() {
        let rows: [[String?]] = [
            ["public", "small", "10", "90", "2026-06-20 10:00", nil],
            ["public", "big", "5000", "5000", nil, "2026-06-19 02:00"],
        ]
        let candidates = vacuumCandidates(fromRows: rows)
        XCTAssertEqual(candidates.map(\.table), ["big", "small"])
        XCTAssertEqual(candidates[0].deadTuples, 5000)
        XCTAssertEqual(candidates[0].liveTuples, 5000)
        XCTAssertEqual(candidates[0].lastAutovacuum, "2026-06-19 02:00")
        XCTAssertNil(candidates[0].lastVacuum)
    }

    func testDeadRatio() {
        let rows: [[String?]] = [["s", "t", "25", "75", nil, nil]]
        XCTAssertEqual(vacuumCandidates(fromRows: rows)[0].deadRatio, 0.25, accuracy: 0.0001)
    }

    func testEmptyTableHasZeroRatioNotNaN() {
        let rows: [[String?]] = [["s", "t", "0", "0", nil, nil]]
        XCTAssertEqual(vacuumCandidates(fromRows: rows)[0].deadRatio, 0)
    }

    func testRowsMissingIdentityColumnsAreDropped() {
        let rows: [[String?]] = [
            [nil, "t", "5", "5", nil, nil],   // no schema
            ["s", nil, "5", "5", nil, nil],   // no table
            ["s", "t"],                       // too few cells
        ]
        XCTAssertTrue(vacuumCandidates(fromRows: rows).isEmpty)
    }

    func testTieOnDeadTuplesBreaksByIdStably() {
        let rows: [[String?]] = [
            ["public", "zeta", "100", "0", nil, nil],
            ["public", "alpha", "100", "0", nil, nil],
        ]
        XCTAssertEqual(vacuumCandidates(fromRows: rows).map(\.table), ["alpha", "zeta"])
    }

    // MARK: - SQL building (quoting + option ordering)

    func testVacuumAnalyzeSQLQuotesIdentifiers() {
        let c = VacuumCandidate(schema: "public", table: "orders", deadTuples: 1, liveTuples: 1, lastVacuum: nil, lastAutovacuum: nil)
        XCTAssertEqual(c.vacuumSQL(analyze: true, full: false), "VACUUM (ANALYZE) \"public\".\"orders\";")
    }

    func testVacuumFullAnalyzeOptionOrder() {
        let c = VacuumCandidate(schema: "s", table: "t", deadTuples: 1, liveTuples: 1, lastVacuum: nil, lastAutovacuum: nil)
        XCTAssertEqual(c.vacuumSQL(analyze: true, full: true), "VACUUM (FULL, ANALYZE) \"s\".\"t\";")
    }

    func testPlainVacuumHasNoOptionClause() {
        let c = VacuumCandidate(schema: "s", table: "t", deadTuples: 1, liveTuples: 1, lastVacuum: nil, lastAutovacuum: nil)
        XCTAssertEqual(c.vacuumSQL(analyze: false, full: false), "VACUUM \"s\".\"t\";")
    }

    func testQualifiedNameEscapesEmbeddedQuotes() {
        let c = VacuumCandidate(schema: "we\"ird", table: "t", deadTuples: 0, liveTuples: 0, lastVacuum: nil, lastAutovacuum: nil)
        // A double-quote in the identifier must be doubled, not allow injection.
        XCTAssertEqual(c.qualifiedName, "\"we\"\"ird\".\"t\"")
    }
}
