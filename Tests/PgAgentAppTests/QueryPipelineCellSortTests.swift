import XCTest

@testable import PgAgentApp

/// Client-side column sort comparator: numeric columns compare by value,
/// text keeps the natural (localized) comparison, NULLs sort last ascending.
final class QueryPipelineCellSortTests: XCTestCase {

    private func sorted(_ values: [String?], numeric: Bool) -> [String?] {
        values.sorted { PostgresCellSort.compare($0, $1, numeric: numeric) == .orderedAscending }
    }

    func testNegativeNumbersSortByValue() {
        // localizedStandardCompare put -5 before -10.
        XCTAssertEqual(sorted(["-5", "-10", "3", "0"], numeric: true), ["-10", "-5", "0", "3"])
    }

    func testDecimalFractionsSortByValue() {
        // localizedStandardCompare put 1.5 before 1.25.
        XCTAssertEqual(sorted(["1.5", "1.25", "1.3", "-0.5"], numeric: true), ["-0.5", "1.25", "1.3", "1.5"])
    }

    func testLargeInt8KeepsFullPrecision() {
        // Beyond Double's 53-bit mantissa these two would compare equal.
        XCTAssertEqual(
            PostgresCellSort.compare("9223372036854775807", "9223372036854775806", numeric: true),
            .orderedDescending
        )
    }

    func testFloatExponentFormAndSpecialValues() {
        XCTAssertEqual(
            sorted(["NaN", "1e+100", "Infinity", "-Infinity", "1.5e-07", "2"], numeric: true),
            ["-Infinity", "1.5e-07", "2", "1e+100", "Infinity", "NaN"]
        )
    }

    func testNullsSortAfterValuesAscending() {
        XCTAssertEqual(sorted([nil, "2", nil, "-1"], numeric: true), ["-1", "2", nil, nil])
        XCTAssertEqual(sorted([nil, "b", "a"], numeric: false), ["a", "b", nil])
    }

    func testUnparseableNumericCellFallsBackToTextCompare() {
        XCTAssertEqual(PostgresCellSort.compare("abc", "abd", numeric: true), .orderedAscending)
    }

    func testTextKeepsNaturalOrdering() {
        XCTAssertEqual(sorted(["img10", "img9", "img1"], numeric: false), ["img1", "img9", "img10"])
    }

    func testEqualNumericValuesInDifferentSpellingsAreSame() {
        XCTAssertEqual(PostgresCellSort.compare("1.50", "1.5", numeric: true), .orderedSame)
    }

    func testNumericTypeDetection() {
        XCTAssertTrue(PostgresCellSort.isNumeric(typeOid: 23, typeName: "int4"))
        XCTAssertTrue(PostgresCellSort.isNumeric(typeOid: 1700, typeName: "numeric"))
        XCTAssertTrue(PostgresCellSort.isNumeric(typeOid: 0, typeName: "float8"))
        XCTAssertFalse(PostgresCellSort.isNumeric(typeOid: 25, typeName: "text"))
        // money output is locale-formatted — keep text comparison.
        XCTAssertFalse(PostgresCellSort.isNumeric(typeOid: 790, typeName: "money"))
    }
}
