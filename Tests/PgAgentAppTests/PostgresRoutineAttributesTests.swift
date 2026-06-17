// Tests for the routine attribute layer: catalog-row parsing, minimal ALTER
// generation (only changed clauses; procedures gated to security + search_path),
// and the security lens findings + one-click fixes.

import XCTest
@testable import PgAgentApp

final class PostgresRoutineAttributesParseTests: XCTestCase {

    // Column layout: prokind, lanname, lanpltrusted, provolatile, proparallel,
    // prosecdef, proisstrict, proleakproof, procost, prorows, proretset,
    // result, arguments, config, public_exec.
    private func row(
        kind: String = "f", lang: String = "sql", trusted: String = "true",
        vol: String = "v", par: String = "u", secdef: String = "false",
        strict: String = "false", leak: String = "false", cost: String = "100",
        rows: String = "0", retset: String = "false", result: String = "integer",
        args: String = "a integer", config: String = "", publicExec: String = "true"
    ) -> [String?] {
        [kind, lang, trusted, vol, par, secdef, strict, leak, cost, rows, retset,
         result, args, config, publicExec]
    }

    func testParsesAllAttributes() {
        let a = PostgresRoutineAttributes.parse(row: row(
            vol: "i", par: "s", secdef: "true", strict: "true", leak: "true",
            cost: "50", config: "search_path=atest, public"))!
        XCTAssertFalse(a.isProcedure)
        XCTAssertEqual(a.volatility, .immutable)
        XCTAssertEqual(a.parallel, .safe)
        XCTAssertTrue(a.securityDefiner)
        XCTAssertTrue(a.strict)
        XCTAssertTrue(a.leakproof)
        XCTAssertEqual(a.cost, 50)
        XCTAssertEqual(a.searchPath, "atest, public")
        XCTAssertTrue(a.publicExecute)
    }

    func testParsesProcedureAndUntrusted() {
        let a = PostgresRoutineAttributes.parse(row: row(
            kind: "p", lang: "plpython3u", trusted: "false"))!
        XCTAssertTrue(a.isProcedure)
        XCTAssertFalse(a.languageTrusted)
    }

    func testSeparatesSearchPathFromOtherConfig() {
        let a = PostgresRoutineAttributes.parse(row: row(
            config: "search_path=public\nwork_mem=64MB"))!
        XCTAssertEqual(a.searchPath, "public")
        XCTAssertEqual(a.otherConfig, ["work_mem=64MB"])
    }

    func testNoConfigMeansNoSearchPath() {
        let a = PostgresRoutineAttributes.parse(row: row(config: ""))!
        XCTAssertNil(a.searchPath)
        XCTAssertTrue(a.otherConfig.isEmpty)
    }
}

final class PostgresRoutineAttributesAlterTests: XCTestCase {

    private func alter(from: RoutineAttributes, to: RoutineAttributes) -> String? {
        PostgresRoutineAttributes.alterStatement(
            schema: "public", name: "f", signature: "a integer", from: from, to: to)
    }

    func testNoChangeReturnsNil() {
        let a = RoutineAttributes(language: "sql")
        XCTAssertNil(alter(from: a, to: a))
    }

    func testSingleVolatilityChange() {
        var to = RoutineAttributes()
        to.volatility = .immutable
        XCTAssertEqual(alter(from: RoutineAttributes(), to: to),
                       #"ALTER FUNCTION "public"."f"(a integer) IMMUTABLE;"#)
    }

    func testCombinedChanges() {
        let from = RoutineAttributes()
        var to = from
        to.securityDefiner = true
        to.parallel = .safe
        to.strict = true
        let sql = alter(from: from, to: to)!
        XCTAssertTrue(sql.hasPrefix(#"ALTER FUNCTION "public"."f"(a integer) "#))
        XCTAssertTrue(sql.contains("SECURITY DEFINER"))
        XCTAssertTrue(sql.contains("PARALLEL SAFE"))
        XCTAssertTrue(sql.contains("STRICT"))
        XCTAssertTrue(sql.hasSuffix(";"))
    }

    func testSearchPathSetAndReset() {
        var pinned = RoutineAttributes()
        pinned.searchPath = "public, pg_temp"
        XCTAssertEqual(alter(from: RoutineAttributes(), to: pinned),
                       #"ALTER FUNCTION "public"."f"(a integer) SET search_path = public, pg_temp;"#)
        XCTAssertEqual(alter(from: pinned, to: RoutineAttributes()),
                       #"ALTER FUNCTION "public"."f"(a integer) RESET search_path;"#)
    }

    func testEmptySearchPathIsTreatedAsReset() {
        var from = RoutineAttributes()
        from.searchPath = "public"
        var to = from
        to.searchPath = "   " // whitespace only → not pinned
        XCTAssertEqual(alter(from: from, to: to),
                       #"ALTER FUNCTION "public"."f"(a integer) RESET search_path;"#)
    }

    func testProcedureGatesFunctionOnlyClauses() {
        var from = RoutineAttributes()
        from.isProcedure = true
        var to = from
        to.volatility = .immutable   // ignored for procedures
        to.strict = true             // ignored
        to.securityDefiner = true    // allowed
        to.searchPath = "app"        // allowed
        let sql = PostgresRoutineAttributes.alterStatement(
            schema: "app", name: "p", signature: "x integer", from: from, to: to)!
        XCTAssertTrue(sql.hasPrefix("ALTER PROCEDURE"))
        XCTAssertTrue(sql.contains("SECURITY DEFINER"))
        XCTAssertTrue(sql.contains("SET search_path = app"))
        XCTAssertFalse(sql.contains("IMMUTABLE"))
        XCTAssertFalse(sql.contains("STRICT"))
    }

    func testRowsOnlyEmittedForSetReturning() {
        var from = RoutineAttributes()
        from.rows = 1000
        var to = from
        to.rows = 5000
        XCTAssertNil(alter(from: from, to: to)) // returnsSet=false → ROWS skipped
        from.returnsSet = true
        to.returnsSet = true
        XCTAssertEqual(alter(from: from, to: to),
                       #"ALTER FUNCTION "public"."f"(a integer) ROWS 5000;"#)
    }
}

final class PostgresRoutineSecurityLensTests: XCTestCase {

    private func findings(_ a: RoutineAttributes) -> [RoutineSecurityFinding] {
        PostgresRoutineAttributes.securityFindings(
            a, schema: "public", name: "f", signature: "a integer")
    }

    func testSecurityDefinerWithoutSearchPathIsCritical() {
        var a = RoutineAttributes(languageTrusted: true)
        a.securityDefiner = true
        a.searchPath = nil
        a.publicExecute = false
        let f = findings(a)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].severity, .critical)
        XCTAssertEqual(f[0].fixSQL,
                       #"ALTER FUNCTION "public"."f"(a integer) SET search_path = "public", pg_temp;"#)
    }

    func testSecurityDefinerWithPinnedSearchPathIsClean() {
        var a = RoutineAttributes(languageTrusted: true)
        a.securityDefiner = true
        a.searchPath = "public, pg_temp"
        a.publicExecute = false
        XCTAssertTrue(findings(a).isEmpty)
    }

    func testUntrustedLanguageWarns() {
        var a = RoutineAttributes(language: "plperlu", languageTrusted: false)
        a.publicExecute = false
        let f = findings(a)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].severity, .warning)
        XCTAssertNil(f[0].fixSQL)
    }

    func testInternalLanguageNotFlaggedUntrusted() {
        // internal/c are not trusted but aren't the untrusted-PL risk.
        var a = RoutineAttributes(language: "internal", languageTrusted: false)
        a.publicExecute = false
        XCTAssertTrue(findings(a).isEmpty)
    }

    func testPublicExecuteInfoWithRevokeFix() {
        var a = RoutineAttributes(languageTrusted: true)
        a.publicExecute = true
        let f = findings(a)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].severity, .info)
        XCTAssertEqual(f[0].fixSQL,
                       #"REVOKE EXECUTE ON FUNCTION "public"."f"(a integer) FROM PUBLIC;"#)
    }

    func testDefinerPlusPublicExecuteEscalatesToWarning() {
        var a = RoutineAttributes(languageTrusted: true)
        a.securityDefiner = true
        a.searchPath = "public"  // pinned, so only the public-execute finding remains
        a.publicExecute = true
        let f = findings(a)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].severity, .warning)
    }

    func testProcedureFixUsesProcedureKeyword() {
        var a = RoutineAttributes(languageTrusted: true)
        a.isProcedure = true
        a.publicExecute = true
        let fix = findings(a).first?.fixSQL
        XCTAssertEqual(fix, #"REVOKE EXECUTE ON PROCEDURE "public"."f"(a integer) FROM PUBLIC;"#)
    }
}
