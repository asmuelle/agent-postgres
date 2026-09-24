// Tests for the escape-aware schema-tree node ids (names containing dots,
// backslashes, quotes and unicode must round-trip), the shared identifier
// quoting helpers, and the Property Inspector's ALTER / RENAME builder.

import XCTest
@testable import PgAgentApp

final class PgNodeIDTests: XCTestCase {

    private func node(_ id: String, _ name: String, _ kind: PgSchemaNode.Kind) -> PgSchemaNode {
        PgSchemaNode(id: id, name: name, kind: kind, owner: nil, estimatedRows: nil)
    }

    // MARK: - Round trips

    func testComponentsRoundTripWithDotsBackslashesQuotesAndUnicode() {
        let tricky = [
            "my.app", "v1.2", "a\\b", "trailing\\", "\\.", "..", "", "\"quoted\"",
            "it's", "Ünïcödé.名前", "e\u{301}.x", "🐘.pg", "a:b", "plain",
        ]
        for a in tricky {
            for b in tricky {
                let id = PgNodeID.make(.relation, a, b, "t")
                let parsed = PgNodeID.parse(id)
                XCTAssertEqual(parsed?.prefix, "rel")
                XCTAssertEqual(parsed?.components, [a, b, "t"], "id: \(id)")
            }
        }
    }

    func testPlainNamesKeepTheirHistoricalIdShape() {
        XCTAssertEqual(PgNodeID.make(.relation, "appdb", "public", "users"), "rel:appdb.public.users")
        XCTAssertEqual(PgNodeID.make(.database, "appdb"), "db:appdb")
        XCTAssertEqual(PgNodeID.make(.column, "d", "s", "t", "c"), "col:d.s.t.c")
    }

    func testDottedDatabaseAndTableResolveToTheRightObject() {
        let rel = node(PgNodeID.make(.relation, "my.app", "public", "v1.2"), "v1.2",
                       .relation(kind: .table))
        XCTAssertEqual(PgNodeID.target(for: rel),
                       PgNodeTarget(database: "my.app", schema: "public", table: nil, name: "v1.2"))

        let col = node(PgNodeID.make(.column, "my.app", "sch.ema", "v1.2", "c.d"), "c.d",
                       .column(typeName: "int", notNull: false))
        XCTAssertEqual(PgNodeID.target(for: col),
                       PgNodeTarget(database: "my.app", schema: "sch.ema", table: "v1.2", name: "c.d"))

        let db = node(PgNodeID.make(.database, "my.app"), "my.app", .database)
        XCTAssertEqual(PgNodeID.target(for: db)?.name, "my.app")
    }

    func testRoutineSignatureIsItsOwnComponent() {
        let sig = "integer, public.my.type"
        let fn = node(PgNodeID.make(.routine, "db", "public", "calc.total", sig), "calc.total",
                      .routine(kind: .function, signature: sig, returnType: nil))
        XCTAssertEqual(PgNodeID.target(for: fn),
                       PgNodeTarget(database: "db", schema: "public", table: nil, name: "calc.total"))
    }

    func testLegacyUnescapedIdsStillParse() {
        // Old form: signature glued onto the name, dotted trailing name.
        let fn = node("fn:appdb.public.calc_totalinteger, text", "calc_total",
                      .routine(kind: .function, signature: "integer, text", returnType: nil))
        XCTAssertEqual(PgNodeID.target(for: fn)?.name, "calc_total")
        let rel = node("rel:appdb.public.archive.2024", "archive.2024", .relation(kind: .table))
        XCTAssertEqual(PgNodeID.target(for: rel)?.name, "archive.2024")
    }

    func testCategoryAndMalformedIdsReturnNil() {
        XCTAssertNil(PgNodeID.target(for: node("cat:a.b.tables", "Tables", .category(.tables, count: 0))))
        XCTAssertNil(PgNodeID.target(for: node("rel:only.two", "two", .relation(kind: .table))))
        XCTAssertNil(PgNodeID.parse("no-prefix"))
    }

    func testKeyNodeSeparatesLabelFromName() {
        let key = PgSchemaNode(
            id: PgNodeID.make(.key, "d", "s", "users", "users_pkey"),
            name: "users_pkey",
            kind: .key(type: "p", definition: "PRIMARY KEY (id)"),
            owner: nil, estimatedRows: nil,
            label: "users_pkey (PRIMARY KEY (id))"
        )
        XCTAssertEqual(key.name, "users_pkey")
        XCTAssertEqual(key.label, "users_pkey (PRIMARY KEY (id))")
        // Plain nodes default the label to the name.
        XCTAssertEqual(node("db:x", "x", .database).label, "x")
    }

    // MARK: - Quoting

    func testQuoteIdentAndLiteralEscaping() {
        XCTAssertEqual(pgQuoteIdent("My \"Tbl\""), "\"My \"\"Tbl\"\"\"")
        XCTAssertEqual(pgQuoteLiteral("it's"), "'it''s'")
    }

    func testQuoteIdentIfNeededChecksReservedWords() {
        XCTAssertEqual(pgQuoteIdentIfNeeded("payload"), "payload")
        XCTAssertEqual(pgQuoteIdentIfNeeded("user"), "\"user\"")
        XCTAssertEqual(pgQuoteIdentIfNeeded("order"), "\"order\"")
        XCTAssertEqual(pgQuoteIdentIfNeeded("left"), "\"left\"")
        XCTAssertEqual(pgQuoteIdentIfNeeded("Mixed"), "\"Mixed\"")
        XCTAssertEqual(pgQuoteIdentIfNeeded("has space"), "\"has space\"")
        XCTAssertEqual(pgQuoteIdentIfNeeded(""), "\"\"")
    }

    func testJSONPathExpressionQuotesReservedColumn() {
        let expr = PostgresJSONTree.postgresExpression(
            column: "user", path: [.key("k")], leafIsScalar: true)
        XCTAssertEqual(expr, "\"user\"->>'k'")
    }

    func testBrowseStateUsesSharedQuoting() {
        let state = PostgresBrowseState(schema: "Sales", table: "my \"t\"", sortColumn: "Order")
        XCTAssertEqual(
            state.sql(),
            "SELECT *, ctid AS __pg_rowid__ FROM \"Sales\".\"my \"\"t\"\"\" ORDER BY \"Order\" ASC LIMIT 500;"
        )
    }

    // MARK: - Inspector ALTER / RENAME

    func testRenameKeyUsesBareNameNotDisplayLabel() {
        let key = PgSchemaNode(
            id: PgNodeID.make(.key, "d", "Sales", "users", "users_pkey"),
            name: "users_pkey",
            kind: .key(type: "p", definition: "PRIMARY KEY (id)"),
            owner: nil, estimatedRows: nil,
            label: "users_pkey (PRIMARY KEY (id))"
        )
        var edit = PostgresNodeAlterDDL.initialEdit(for: key)
        XCTAssertEqual(edit.name, "users_pkey")
        XCTAssertEqual(PostgresNodeAlterDDL.statements(for: key, edit: edit), "-- No changes")
        edit.name = "Users \"PK\""
        XCTAssertEqual(
            PostgresNodeAlterDDL.statements(for: key, edit: edit),
            "ALTER TABLE \"Sales\".\"users\" RENAME CONSTRAINT \"users_pkey\" TO \"Users \"\"PK\"\"\";"
        )
    }

    func testColumnEditQuotesAndOrdersStatements() {
        let col = node(PgNodeID.make(.column, "d", "s", "t.1", "old"), "old",
                       .column(typeName: "integer", notNull: false))
        let edit = PostgresNodeAlterDDL.Edit(name: "New", type: "bigint", notNull: true)
        XCTAssertEqual(
            PostgresNodeAlterDDL.statements(for: col, edit: edit),
            """
            ALTER TABLE "s"."t.1" RENAME COLUMN "old" TO "New";
            ALTER TABLE "s"."t.1" ALTER COLUMN "New" TYPE bigint;
            ALTER TABLE "s"."t.1" ALTER COLUMN "New" SET NOT NULL;
            """
        )
    }

    func testTriggerRenameUsesAlterTriggerSyntax() {
        let trig = node(PgNodeID.make(.trigger, "d", "s", "t", "tg"), "tg", .trigger)
        let edit = PostgresNodeAlterDDL.Edit(name: "tg2", type: "", notNull: false)
        XCTAssertEqual(
            PostgresNodeAlterDDL.statements(for: trig, edit: edit),
            "ALTER TRIGGER \"tg\" ON \"s\".\"t\" RENAME TO \"tg2\";"
        )
    }

    func testRoutineRenamePinsOverload() {
        let fn = node(PgNodeID.make(.routine, "d", "s", "f", "integer, text"), "f",
                      .routine(kind: .procedure, signature: "integer, text", returnType: nil))
        let edit = PostgresNodeAlterDDL.Edit(name: "g", type: "", notNull: false)
        XCTAssertEqual(
            PostgresNodeAlterDDL.statements(for: fn, edit: edit),
            "ALTER PROCEDURE \"s\".\"f\"(integer, text) RENAME TO \"g\";"
        )
    }
}
