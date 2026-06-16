// Tests for PostgresRoutineHeader.identity — the parser that decides whether an
// edit changed the routine's name/argument identity (which CREATE OR REPLACE
// keys on). A wrong answer here is the difference between "replaced in place"
// and "silently created a new overload", so the parse is covered directly.

import XCTest
@testable import PgAgentApp

final class PostgresRoutineHeaderTests: XCTestCase {

    private let base = """
        CREATE OR REPLACE FUNCTION public.greet(who text)
         RETURNS text
         LANGUAGE plpgsql
        AS $function$
        BEGIN
          RETURN 'hello ' || who;
        END;
        $function$
        """

    func testParsesNameAndArgs() {
        XCTAssertEqual(PostgresRoutineHeader.identity(of: base), "public.greet(who text)")
    }

    func testBodyOnlyEditKeepsIdentity() {
        let edited = base.replacingOccurrences(of: "'hello '", with: "'HELLO '")
        XCTAssertEqual(
            PostgresRoutineHeader.identity(of: edited),
            PostgresRoutineHeader.identity(of: base))
    }

    func testArgumentTypeChangeIsDifferentIdentity() {
        let edited = base.replacingOccurrences(of: "(who text)", with: "(who varchar)")
        XCTAssertNotEqual(
            PostgresRoutineHeader.identity(of: edited),
            PostgresRoutineHeader.identity(of: base))
    }

    func testNameChangeIsDifferentIdentity() {
        let edited = base.replacingOccurrences(of: "public.greet", with: "public.salute")
        XCTAssertNotEqual(
            PostgresRoutineHeader.identity(of: edited),
            PostgresRoutineHeader.identity(of: base))
    }

    func testWhitespaceInArgsIsNormalized() {
        let spaced = base.replacingOccurrences(of: "(who text)", with: "(  who   text  )")
        XCTAssertEqual(
            PostgresRoutineHeader.identity(of: spaced),
            PostgresRoutineHeader.identity(of: base))
    }

    func testNestedParensInArgsCaptured() {
        let ddl = "CREATE OR REPLACE FUNCTION s.f(a int DEFAULT (1 + 2), b text) RETURNS int LANGUAGE sql AS $$ SELECT 1 $$"
        // The arg list must include both params, not stop at the inner ')'.
        let id = PostgresRoutineHeader.identity(of: ddl)
        XCTAssertEqual(id, "s.f(a int default (1 + 2), b text)")
    }

    func testProcedureHeaderParsed() {
        let ddl = "CREATE OR REPLACE PROCEDURE app.do_it(flag boolean) LANGUAGE plpgsql AS $$ BEGIN END $$"
        XCTAssertEqual(PostgresRoutineHeader.identity(of: ddl), "app.do_it(flag boolean)")
    }

    func testZeroArgFunction() {
        let ddl = "CREATE OR REPLACE FUNCTION now_utc() RETURNS timestamptz LANGUAGE sql AS $$ SELECT now() $$"
        XCTAssertEqual(PostgresRoutineHeader.identity(of: ddl), "now_utc()")
    }

    func testNonRoutineDDLReturnsNil() {
        // Aggregate / comment-stub / arbitrary text isn't a CREATE FUNCTION.
        XCTAssertNil(PostgresRoutineHeader.identity(of: "CREATE AGGREGATE s.my_sum(numeric) (SFUNC = ...);"))
        XCTAssertNil(PostgresRoutineHeader.identity(of: "-- C/internal routine; body is a compiled symbol"))
    }
}
