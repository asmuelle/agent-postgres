// Tests for the kind-aware DDL reconstruction engine: node-id parsing
// (especially routine signature stripping — the old parser mangled every
// function that takes arguments) and the pure catalog-row renderers.

import XCTest
@testable import PgAgentApp

final class PostgresNodeDDLTargetTests: XCTestCase {

    private func node(id: String, name: String, kind: PgSchemaNode.Kind) -> PgSchemaNode {
        PgSchemaNode(id: id, name: name, kind: kind, owner: nil, estimatedRows: nil)
    }

    func testRoutineWithArgumentsStripsSignature() {
        // The identity-argument signature carries no parentheses, so
        // the id is "fn:db.schema.name" + "integer, text" verbatim.
        let n = node(
            id: "fn:appdb.public.calc_totalinteger, text",
            name: "calc_total",
            kind: .routine(kind: .function, signature: "integer, text", returnType: "numeric")
        )
        let t = PostgresNodeDDL.target(for: n)
        XCTAssertEqual(t, PostgresNodeDDL.Target(
            database: "appdb", schema: "public", table: nil, name: "calc_total"))
    }

    func testZeroArgRoutine() {
        let n = node(
            id: "fn:appdb.public.now_utc",
            name: "now_utc",
            kind: .routine(kind: .function, signature: "", returnType: "timestamptz")
        )
        XCTAssertEqual(PostgresNodeDDL.target(for: n)?.name, "now_utc")
    }

    func testProcedureSignatureStripping() {
        let n = node(
            id: "fn:appdb.sales.refresh_statsboolean",
            name: "refresh_stats",
            kind: .routine(kind: .procedure, signature: "boolean", returnType: nil)
        )
        let t = PostgresNodeDDL.target(for: n)
        XCTAssertEqual(t?.schema, "sales")
        XCTAssertEqual(t?.name, "refresh_stats")
    }

    func testRelationNameMayContainDots() {
        let n = node(
            id: "rel:appdb.public.archive.2024",
            name: "archive.2024",
            kind: .relation(kind: .table)
        )
        XCTAssertEqual(PostgresNodeDDL.target(for: n)?.name, "archive.2024")
    }

    func testColumnIsTableScoped() {
        let n = node(
            id: "col:appdb.public.users.email",
            name: "email",
            kind: .column(typeName: "text", notNull: true)
        )
        let t = PostgresNodeDDL.target(for: n)
        XCTAssertEqual(t?.table, "users")
        XCTAssertEqual(t?.name, "email")
    }

    func testConstraintNameMayContainDots() {
        let n = node(
            id: "const:appdb.public.users.users.email_check",
            name: "users.email_check (CHECK ...)",
            kind: .constraint(type: "c", definition: "CHECK ...")
        )
        let t = PostgresNodeDDL.target(for: n)
        XCTAssertEqual(t?.table, "users")
        XCTAssertEqual(t?.name, "users.email_check")
    }

    func testDatabaseSchemaRoleTablespaceLanguage() {
        XCTAssertEqual(
            PostgresNodeDDL.target(for: node(id: "db:appdb", name: "appdb", kind: .database))?.name,
            "appdb")
        XCTAssertEqual(
            PostgresNodeDDL.target(
                for: node(id: "schema:appdb.sales", name: "sales", kind: .schema(isSystem: false)))?.name,
            "sales")
        XCTAssertEqual(
            PostgresNodeDDL.target(for: node(id: "role:admin", name: "admin", kind: .role))?.name,
            "admin")
        XCTAssertEqual(
            PostgresNodeDDL.target(
                for: node(id: "tspace:fast_ssd", name: "fast_ssd", kind: .tablespace))?.name,
            "fast_ssd")
        XCTAssertEqual(
            PostgresNodeDDL.target(
                for: node(id: "lang:appdb.plpgsql", name: "plpgsql", kind: .language))?.name,
            "plpgsql")
    }

    func testCategoryHasNoTarget() {
        let n = node(id: "cat:appdb.public.tables", name: "Tables", kind: .category(.tables, count: 3))
        XCTAssertNil(PostgresNodeDDL.target(for: n))
    }
}

final class PostgresNodeDDLRenderTests: XCTestCase {

    // MARK: - Routines

    /// Row layout: identity args, prokind, language, functiondef,
    /// prosrc, result, full args, aggregate def.
    private func routineRow(
        args: String = "",
        prokind: String = "f",
        language: String = "plpgsql",
        def: String? = nil,
        prosrc: String = "",
        result: String? = nil,
        fullArgs: String? = nil,
        aggDef: String? = nil
    ) -> [String?] {
        [args, prokind, language, def, prosrc, result, fullArgs ?? args, aggDef]
    }

    func testRoutinePicksExactOverload() {
        let rows = [
            routineRow(args: "integer", def: "CREATE FUNCTION f(integer) ..."),
            routineRow(args: "text", def: "CREATE FUNCTION f(text) ..."),
        ]
        let ddl = PostgresNodeDDL.renderRoutineDDL(
            rows: rows, schema: "public", name: "f", signature: "text")
        XCTAssertEqual(ddl, "CREATE FUNCTION f(text) ...")
    }

    func testRoutineShowsAllOverloadsWhenNoExactMatch() {
        let rows = [
            routineRow(args: "integer", def: "CREATE FUNCTION f(integer) ..."),
            routineRow(args: "text", def: "CREATE FUNCTION f(text) ..."),
        ]
        let ddl = PostgresNodeDDL.renderRoutineDDL(
            rows: rows, schema: "public", name: "f", signature: "bigint")
        XCTAssertTrue(ddl.contains("2 overloads"))
        XCTAssertTrue(ddl.contains("f(integer)"))
        XCTAssertTrue(ddl.contains("f(text)"))
    }

    func testAggregateUsesServerBuiltDefinition() {
        let rows = [routineRow(
            args: "numeric", prokind: "a", language: "internal",
            aggDef: "CREATE AGGREGATE public.my_sum(numeric) (...);")]
        let ddl = PostgresNodeDDL.renderRoutineDDL(
            rows: rows, schema: "public", name: "my_sum", signature: "numeric")
        XCTAssertEqual(ddl, "CREATE AGGREGATE public.my_sum(numeric) (...);")
    }

    func testInternalFunctionRendersShapeStub() {
        let rows = [routineRow(
            args: "integer", prokind: "f", language: "c",
            prosrc: "my_c_symbol", result: "integer",
            fullArgs: "x integer")]
        let ddl = PostgresNodeDDL.renderRoutineDDL(
            rows: rows, schema: "public", name: "fastpath", signature: "integer")
        XCTAssertTrue(ddl.contains("compiled code"))
        XCTAssertTrue(ddl.contains("CREATE FUNCTION \"public\".\"fastpath\"(x integer)"))
        XCTAssertTrue(ddl.contains("RETURNS integer"))
        XCTAssertTrue(ddl.contains("'my_c_symbol'"))
    }

    func testProcedureStubUsesProcedureKeyword() {
        let rows = [routineRow(prokind: "p", language: "internal", prosrc: "sym")]
        let ddl = PostgresNodeDDL.renderRoutineDDL(
            rows: rows, schema: "public", name: "p1", signature: "")
        XCTAssertTrue(ddl.contains("CREATE PROCEDURE"))
        XCTAssertFalse(ddl.contains("RETURNS"))
    }

    func testRoutineNotFound() {
        let ddl = PostgresNodeDDL.renderRoutineDDL(
            rows: [], schema: "public", name: "ghost", signature: "")
        XCTAssertTrue(ddl.contains("not found"))
    }

    // MARK: - Sequences

    func testSequenceDDLWithOwnedBy() {
        let rows: [[String?]] = [[
            "integer", "100", "5", "1", "2147483647", "20", "true",
            "public.users.id",
        ]]
        let ddl = PostgresNodeDDL.renderSequenceDDL(rows: rows, schema: "public", name: "users_id_seq")
        XCTAssertTrue(ddl.contains("CREATE SEQUENCE \"public\".\"users_id_seq\""))
        XCTAssertTrue(ddl.contains("AS integer"))
        XCTAssertTrue(ddl.contains("START WITH 100"))
        XCTAssertTrue(ddl.contains("INCREMENT BY 5"))
        XCTAssertTrue(ddl.contains("CACHE 20"))
        XCTAssertTrue(ddl.contains("    CYCLE;"))
        XCTAssertTrue(ddl.contains("OWNED BY public.users.id;"))
    }

    func testBigintSequenceOmitsAsClause() {
        let rows: [[String?]] = [["bigint", "1", "1", "1", "9223372036854775807", "1", "false", nil]]
        let ddl = PostgresNodeDDL.renderSequenceDDL(rows: rows, schema: "s", name: "n")
        XCTAssertFalse(ddl.contains("AS bigint"))
        XCTAssertTrue(ddl.contains("NO CYCLE;"))
        XCTAssertFalse(ddl.contains("OWNED BY"))
    }

    // MARK: - Object types

    func testCompositeTypeDDL() {
        let rows: [[String?]] = [["street", "text"], ["zip", "character varying(10)"]]
        let ddl = PostgresNodeDDL.renderObjectTypeDDL(
            kind: .composite, rows: rows, schema: "public", name: "address")
        XCTAssertEqual(
            ddl,
            "CREATE TYPE \"public\".\"address\" AS (\n    \"street\" text,\n    \"zip\" character varying(10)\n);"
        )
    }

    func testEnumTypeDDLQuotesLabels() {
        let rows: [[String?]] = [["new"], ["it's-ok"]]
        let ddl = PostgresNodeDDL.renderObjectTypeDDL(
            kind: .enum, rows: rows, schema: "public", name: "status")
        XCTAssertTrue(ddl.contains("'new'"))
        XCTAssertTrue(ddl.contains("'it''s-ok'"))
    }

    func testDomainDDL() {
        let rows: [[String?]] = [["text", "true", "'unknown'::text", "CHECK (VALUE <> '')"]]
        let ddl = PostgresNodeDDL.renderObjectTypeDDL(
            kind: .domain, rows: rows, schema: "public", name: "nonempty")
        XCTAssertTrue(ddl.contains("CREATE DOMAIN \"public\".\"nonempty\" AS text"))
        XCTAssertTrue(ddl.contains("DEFAULT 'unknown'::text"))
        XCTAssertTrue(ddl.contains("NOT NULL"))
        XCTAssertTrue(ddl.contains("CHECK (VALUE <> '')"))
    }

    func testRangeTypeDDL() {
        let rows: [[String?]] = [["numeric"]]
        let ddl = PostgresNodeDDL.renderObjectTypeDDL(
            kind: .range, rows: rows, schema: "public", name: "price_range")
        XCTAssertTrue(ddl.contains("AS RANGE"))
        XCTAssertTrue(ddl.contains("SUBTYPE = numeric"))
    }

    // MARK: - Columns

    func testColumnDDLWithDefaultAndComment() {
        let rows: [[String?]] = [["text", "true", "'n/a'::text", "", "", "user-visible label"]]
        let ddl = PostgresNodeDDL.renderColumnDDL(
            rows: rows, schema: "public", table: "users", column: "label")
        XCTAssertTrue(ddl.contains("ADD COLUMN \"label\" text DEFAULT 'n/a'::text NOT NULL;"))
        XCTAssertTrue(ddl.contains("COMMENT ON COLUMN"))
    }

    func testIdentityColumnDDL() {
        let rows: [[String?]] = [["bigint", "true", nil, "a", "", nil]]
        let ddl = PostgresNodeDDL.renderColumnDDL(
            rows: rows, schema: "public", table: "users", column: "id")
        XCTAssertTrue(ddl.contains("GENERATED ALWAYS AS IDENTITY NOT NULL"))
    }

    func testGeneratedColumnDDL() {
        let rows: [[String?]] = [["numeric", "false", "(price * qty)", "", "s", nil]]
        let ddl = PostgresNodeDDL.renderColumnDDL(
            rows: rows, schema: "public", table: "orders", column: "total")
        XCTAssertTrue(ddl.contains("GENERATED ALWAYS AS ((price * qty)) STORED"))
        XCTAssertFalse(ddl.contains("DEFAULT"))
    }

    // MARK: - Server objects

    func testRoleDDL() {
        let rows: [[String?]] = [["false", "true", "false", "true", "true", "false", "10", nil]]
        let ddl = PostgresNodeDDL.renderRoleDDL(rows: rows, name: "app_user")
        XCTAssertTrue(ddl.contains("CREATE ROLE \"app_user\" WITH"))
        XCTAssertTrue(ddl.contains("NOSUPERUSER"))
        XCTAssertTrue(ddl.contains("CREATEDB"))
        XCTAssertTrue(ddl.contains("LOGIN"))
        XCTAssertTrue(ddl.contains("CONNECTION LIMIT 10"))
        XCTAssertTrue(ddl.contains("not recoverable"))
    }

    func testDatabaseDDL() {
        let rows: [[String?]] = [["UTF8", "en_US.UTF-8", "en_US.UTF-8", "postgres"]]
        let ddl = PostgresNodeDDL.renderDatabaseDDL(rows: rows, name: "appdb")
        XCTAssertTrue(ddl.contains("CREATE DATABASE \"appdb\""))
        XCTAssertTrue(ddl.contains("OWNER \"postgres\""))
        XCTAssertTrue(ddl.contains("ENCODING 'UTF8'"))
    }

    func testViewDDL() {
        let rows: [[String?]] = [[" SELECT 1;"]]
        let ddl = PostgresNodeDDL.renderViewDDL(
            rows: rows, schema: "public", name: "v", materialized: false)
        XCTAssertEqual(ddl, "CREATE OR REPLACE VIEW \"public\".\"v\" AS\nSELECT 1;")
    }

    func testMaterializedViewKeyword() {
        let rows: [[String?]] = [["SELECT 2;"]]
        let ddl = PostgresNodeDDL.renderViewDDL(
            rows: rows, schema: "public", name: "mv", materialized: true)
        XCTAssertTrue(ddl.hasPrefix("CREATE MATERIALIZED VIEW"))
    }

    // MARK: - Query builders escape literals

    func testQueriesEscapeSingleQuotes() {
        let q = PostgresNodeDDL.routineQuery(schema: "we'ird", name: "fn'name")
        XCTAssertTrue(q.contains("'we''ird'"))
        XCTAssertTrue(q.contains("'fn''name'"))
        XCTAssertFalse(q.contains("'we'ird'"))
    }

    func testRegclassAnchoredQueriesQuoteIdentifiers() {
        let q = PostgresNodeDDL.columnQuery(schema: "Sales", table: "Order", column: "id")
        XCTAssertTrue(q.contains(#"to_regclass('"Sales"."Order"')"#))
    }
}
