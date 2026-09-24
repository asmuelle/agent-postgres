// Tests for the Object Wizard's DDL generator (identifier quoting, DEFAULT
// literal handling, composite primary keys), the EXPLAIN JSON decoder
// (Postgres 18 fractional row counts) and the shared DDL helpers the
// sequence / type visualizers now use.

import XCTest
@testable import PgAgentApp

final class PostgresObjectWizardDDLTests: XCTestCase {

    func testQuotesEveryIdentifier() {
        let ddl = PostgresObjectWizardDDL.generate(
            schema: "Sales",
            table: "Order Items",
            columns: [
                WizardColumn(name: "ID", type: "integer", isNullable: false, isPrimaryKey: true),
                WizardColumn(name: "user", type: "character varying", length: "40"),
            ],
            indexes: [WizardIndex(name: "Idx Name", columns: ["user"], type: "btree")],
            constraints: [WizardConstraint(
                name: "fk \"x\"", localColumn: "user", foreignSchema: "Auth",
                foreignTable: "Users", foreignColumn: "Name", onDelete: "CASCADE")]
        )
        XCTAssertTrue(ddl.contains("CREATE TABLE IF NOT EXISTS \"Sales\".\"Order Items\" ("))
        XCTAssertTrue(ddl.contains("    \"ID\" integer NOT NULL PRIMARY KEY"))
        XCTAssertTrue(ddl.contains("    \"user\" character varying(40)"))
        XCTAssertTrue(ddl.contains(
            "CREATE INDEX IF NOT EXISTS \"Idx Name\" ON \"Sales\".\"Order Items\" USING btree (\"user\");"))
        XCTAssertTrue(ddl.contains("ADD CONSTRAINT \"fk \"\"x\"\"\""))
        XCTAssertTrue(ddl.contains("FOREIGN KEY (\"user\")"))
        XCTAssertTrue(ddl.contains("REFERENCES \"Auth\".\"Users\" (\"Name\")"))
        XCTAssertTrue(ddl.contains("ON DELETE CASCADE;"))
    }

    func testCompositePrimaryKeyBecomesTableConstraint() {
        let ddl = PostgresObjectWizardDDL.generate(
            schema: "public", table: "t",
            columns: [
                WizardColumn(name: "a", type: "integer", isNullable: false, isPrimaryKey: true),
                WizardColumn(name: "b", type: "integer", isNullable: false, isPrimaryKey: true),
            ],
            indexes: [], constraints: []
        )
        XCTAssertFalse(ddl.contains(" PRIMARY KEY,"))
        XCTAssertTrue(ddl.contains("    PRIMARY KEY (\"a\", \"b\")"))
    }

    func testDefaultExpressionsPassThroughAndTextIsQuoted() {
        XCTAssertEqual(PostgresObjectWizardDDL.defaultExpression("NOW()"), "NOW()")
        XCTAssertEqual(PostgresObjectWizardDDL.defaultExpression("0"), "0")
        XCTAssertEqual(PostgresObjectWizardDDL.defaultExpression("-1.5"), "-1.5")
        XCTAssertEqual(PostgresObjectWizardDDL.defaultExpression("true"), "true")
        XCTAssertEqual(PostgresObjectWizardDDL.defaultExpression("CURRENT_TIMESTAMP"), "CURRENT_TIMESTAMP")
        XCTAssertEqual(PostgresObjectWizardDDL.defaultExpression("'x'::text"), "'x'::text")
        XCTAssertEqual(PostgresObjectWizardDDL.defaultExpression("pending"), "'pending'")
        XCTAssertEqual(PostgresObjectWizardDDL.defaultExpression("it's"), "'it''s'")
    }

    func testIncompleteDesignIsNotExecutable() {
        let good = [WizardColumn(name: "id")]
        XCTAssertTrue(PostgresObjectWizardDDL.isComplete(table: "t", columns: good))
        XCTAssertFalse(PostgresObjectWizardDDL.isComplete(table: "  ", columns: good))
        XCTAssertFalse(PostgresObjectWizardDDL.isComplete(table: "t", columns: []))
        XCTAssertFalse(PostgresObjectWizardDDL.isComplete(table: "t", columns: [WizardColumn(name: "")]))
    }
}

final class PostgresExplainDecodeTests: XCTestCase {

    func testDecodesFractionalActualRows() throws {
        // Postgres 18 EXPLAIN (ANALYZE, FORMAT JSON) shape.
        let json = """
        [{"Plan": {"Node Type": "Nested Loop", "Plan Rows": 10, "Plan Width": 8,
          "Total Cost": 12.5, "Actual Rows": 0.50, "Actual Loops": 2,
          "Plans": [{"Node Type": "Index Scan", "Relation Name": "t",
                     "Plan Rows": 1, "Actual Rows": 1.00, "Actual Loops": 4,
                     "Shared Hit Blocks": 12}]}}]
        """
        let results = try JSONDecoder().decode([PgExplainResult].self, from: Data(json.utf8))
        let root = try XCTUnwrap(results.first?.plan)
        XCTAssertEqual(root.actualRows, 0.5)
        XCTAssertEqual(root.actualLoops, 2)
        XCTAssertEqual(root.planRows, 10)
        XCTAssertEqual(root.plans?.first?.sharedHitBlocks, 12)
    }

    func testFormatCount() {
        XCTAssertEqual(PgPlanNode.formatCount(1200), "1200")
        XCTAssertEqual(PgPlanNode.formatCount(0.5), "0.50")
        XCTAssertEqual(PgPlanNode.formatCount(0), "0")
    }
}

final class PostgresVisualizerDDLTests: XCTestCase {

    func testEnumLabelsAndNamesAreQuoted() {
        let ddl = PostgresNodeDDL.renderObjectTypeDDL(
            kind: .enum, rows: [["it's"], ["ok"]], schema: "My Schema", name: "Mood")
        XCTAssertEqual(ddl, "CREATE TYPE \"My Schema\".\"Mood\" AS ENUM (\n    'it''s',\n    'ok'\n);")
    }

    func testSequenceDDLIncludesEscapedComment() {
        let rows: [[String?]] = [[
            "bigint", "1", "1", "1", "9223372036854775807", "1", "false", nil, "Bob's seq",
        ]]
        let ddl = PostgresNodeDDL.renderSequenceDDL(rows: rows, schema: "S", name: "n.1")
        XCTAssertTrue(ddl.hasPrefix("CREATE SEQUENCE \"S\".\"n.1\""))
        XCTAssertTrue(ddl.hasSuffix("COMMENT ON SEQUENCE \"S\".\"n.1\" IS 'Bob''s seq';"))
    }

    func testSequenceQueryAnchorsCommentOnQualifiedOid() {
        let sql = PostgresNodeDDL.sequenceQuery(schema: "a'b", name: "S")
        XCTAssertTrue(sql.contains("obj_description(to_regclass('\"a''b\".\"S\"'), 'pg_class')"))
    }

    func testCommentDDLSkipsBlankAndMapsTyptype() {
        XCTAssertNil(PostgresNodeDDL.commentDDL(on: "TYPE", schema: "s", name: "t", comment: "  "))
        XCTAssertNil(PostgresNodeDDL.commentDDL(on: "TYPE", schema: "s", name: "t", comment: nil))
        XCTAssertEqual(PostgresNodeDDL.objectTypeKind(typtype: "e"), .enum)
        XCTAssertEqual(PostgresNodeDDL.objectTypeKind(typtype: "d"), .domain)
        XCTAssertNil(PostgresNodeDDL.objectTypeKind(typtype: "b"))
    }
}
