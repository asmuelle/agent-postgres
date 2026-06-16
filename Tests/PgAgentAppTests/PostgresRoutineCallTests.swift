// Tests for the routine runner's pure logic: parsing catalog introspection
// rows into RoutineCallInfo, and building correct, type-aware invocations
// (named vs positional, NULL/DEFAULT, VARIADIC, CALL vs SELECT).

import XCTest
@testable import PgAgentApp

final class PostgresRoutineCallParseTests: XCTestCase {

    // Introspection column layout: prokind, retset, arg_name, arg_type, arg_mode, has_default.
    private func row(_ kind: String, _ retset: String, _ name: String?, _ type: String?,
                     _ mode: String, _ hasDefault: String) -> [String?] {
        [kind, retset, name, type, mode, hasDefault]
    }

    func testParsesFunctionInputParams() {
        let rows = [
            row("f", "false", "a", "integer", "i", "false"),
            row("f", "false", "b", "integer", "i", "true"),
        ]
        let info = PostgresRoutineCall.parseParams(rows: rows)
        XCTAssertNotNil(info)
        XCTAssertFalse(info!.isProcedure)
        XCTAssertEqual(info!.params.count, 2)
        XCTAssertEqual(info!.params[0].name, "a")
        XCTAssertEqual(info!.params[1].hasDefault, true)
        XCTAssertEqual(info!.params[1].ordinal, 2)
    }

    func testProcedureAndInoutDetected() {
        let rows = [
            row("p", "false", "counter", "integer", "b", "false"),
            row("p", "false", "step", "integer", "i", "true"),
        ]
        let info = PostgresRoutineCall.parseParams(rows: rows)!
        XCTAssertTrue(info.isProcedure)
        XCTAssertEqual(info.params.first?.mode, "b") // INOUT is an input
        XCTAssertEqual(info.params.count, 2)
    }

    func testOutAndTableColumnsExcludedFromInputs() {
        let rows = [
            row("f", "true", "in_a", "integer", "i", "false"),
            row("f", "true", "out_x", "integer", "o", "false"),  // pure OUT
            row("f", "true", "tbl_y", "text", "t", "false"),     // TABLE column
        ]
        let info = PostgresRoutineCall.parseParams(rows: rows)!
        XCTAssertTrue(info.returnsSet)
        XCTAssertEqual(info.params.map(\.name), ["in_a"])
    }

    func testZeroArgRoutineHasNoParams() {
        let info = PostgresRoutineCall.parseParams(rows: [row("f", "false", nil, nil, "i", "false")])!
        XCTAssertTrue(info.params.isEmpty)
        XCTAssertFalse(info.isProcedure)
    }

    func testEmptyRowsReturnNil() {
        XCTAssertNil(PostgresRoutineCall.parseParams(rows: []))
    }

    func testIntrospectionQueryEscapesLiterals() {
        let q = PostgresRoutineCall.introspectionQuery(
            schema: "we'ird", name: "fn'x", signature: "a integer")
        XCTAssertTrue(q.contains("'we''ird'"))
        XCTAssertTrue(q.contains("'fn''x'"))
        XCTAssertTrue(q.contains("'a integer'"))
    }
}

final class PostgresRoutineCallBuildTests: XCTestCase {

    private func info(_ isProc: Bool, _ params: [RoutineParam]) -> RoutineCallInfo {
        RoutineCallInfo(isProcedure: isProc, returnsSet: false, params: params)
    }

    private func p(_ ord: Int, _ name: String, _ type: String, _ mode: String = "i",
                   _ hasDefault: Bool = false) -> RoutineParam {
        RoutineParam(ordinal: ord, name: name, type: type, mode: mode, hasDefault: hasDefault)
    }

    func testNamedNotationWithCasts() {
        let i = info(false, [p(1, "a", "integer"), p(2, "b", "text")])
        let sql = PostgresRoutineCall.buildInvocation(
            schema: "public", name: "f", info: i,
            values: [1: .init(text: "5"), 2: .init(text: "hi")])
        XCTAssertEqual(sql, #"SELECT * FROM "public"."f"("a" => '5'::integer, "b" => 'hi'::text);"#)
    }

    func testNamedNotationOmitsDefault() {
        let i = info(false, [p(1, "a", "integer"), p(2, "b", "integer", "i", true)])
        let sql = PostgresRoutineCall.buildInvocation(
            schema: "public", name: "adder", info: i,
            values: [1: .init(text: "5"), 2: .init(useDefault: true)])
        XCTAssertEqual(sql, #"SELECT * FROM "public"."adder"("a" => '5'::integer);"#)
    }

    func testNullArgument() {
        let i = info(false, [p(1, "a", "text")])
        let sql = PostgresRoutineCall.buildInvocation(
            schema: "s", name: "f", info: i, values: [1: .init(isNull: true)])
        XCTAssertEqual(sql, #"SELECT * FROM "s"."f"("a" => NULL);"#)
    }

    func testProcedureUsesCall() {
        let i = info(true, [p(1, "counter", "integer", "b")])
        let sql = PostgresRoutineCall.buildInvocation(
            schema: "app", name: "bump", info: i, values: [1: .init(text: "41")])
        XCTAssertEqual(sql, #"CALL "app"."bump"("counter" => '41'::integer);"#)
    }

    func testZeroArgFunction() {
        let sql = PostgresRoutineCall.buildInvocation(
            schema: "public", name: "nowish", info: info(false, []), values: [:])
        XCTAssertEqual(sql, #"SELECT * FROM "public"."nowish"();"#)
    }

    func testVariadicForcesPositionalWithKeyword() {
        let i = info(false, [p(1, "nums", "integer[]", "v")])
        let sql = PostgresRoutineCall.buildInvocation(
            schema: "s", name: "sumall", info: i, values: [1: .init(text: "{1,2,3}")])
        XCTAssertEqual(sql, #"SELECT * FROM "s"."sumall"(VARIADIC '{1,2,3}'::integer[]);"#)
    }

    func testUnnamedArgsUsePositional() {
        // No names → positional; casts still applied.
        let i = info(false, [p(1, "", "integer"), p(2, "", "text")])
        let sql = PostgresRoutineCall.buildInvocation(
            schema: "s", name: "f", info: i,
            values: [1: .init(text: "1"), 2: .init(text: "x")])
        XCTAssertEqual(sql, #"SELECT * FROM "s"."f"('1'::integer, 'x'::text);"#)
    }

    func testPositionalTrailingDefaultOmitted() {
        let i = info(false, [p(1, "", "integer"), p(2, "", "integer", "i", true)])
        let sql = PostgresRoutineCall.buildInvocation(
            schema: "s", name: "f", info: i,
            values: [1: .init(text: "1"), 2: .init(useDefault: true)])
        XCTAssertEqual(sql, #"SELECT * FROM "s"."f"('1'::integer);"#)
    }

    func testPseudoTypeSkipsCast() {
        let i = info(false, [p(1, "x", "anyelement")])
        let sql = PostgresRoutineCall.buildInvocation(
            schema: "s", name: "f", info: i, values: [1: .init(text: "5")])
        XCTAssertEqual(sql, #"SELECT * FROM "s"."f"("x" => '5');"#)
    }

    func testValueLiteralIsEscaped() {
        let expr = PostgresRoutineCall.valueExpr(.init(text: "O'Brien"), type: "text")
        XCTAssertEqual(expr, "'O''Brien'::text")
    }
}
