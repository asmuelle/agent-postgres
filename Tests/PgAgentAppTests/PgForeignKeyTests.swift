// Tests for PgForeignKeyParser (the FK catalog-query row folder) and
// the filtered relation tab SQL used by FK navigation.

import XCTest
@testable import PgAgentApp

final class PgForeignKeyTests: XCTestCase {

    // Row layout: [conname, from_schema, from_table, from_column,
    //              to_schema, to_table, to_column, is_outgoing, is_incoming]

    func testParsesSingleColumnOutgoingFK() {
        let rows: [[String?]] = [
            ["orders_user_id_fkey", "public", "orders", "user_id",
             "public", "users", "id", "t", "f"],
        ]
        let fks = PgForeignKeyParser.parse(rows: rows)

        XCTAssertEqual(fks.outgoing.count, 1)
        XCTAssertTrue(fks.incoming.isEmpty)
        let fk = fks.outgoing[0]
        XCTAssertEqual(fk.constraintName, "orders_user_id_fkey")
        XCTAssertEqual(fk.fromSchema, "public")
        XCTAssertEqual(fk.fromTable, "orders")
        XCTAssertEqual(fk.fromColumns, ["user_id"])
        XCTAssertEqual(fk.toSchema, "public")
        XCTAssertEqual(fk.toTable, "users")
        XCTAssertEqual(fk.toColumns, ["id"])
    }

    func testFoldsMultiColumnFKPreservingOrder() {
        let rows: [[String?]] = [
            ["t_comp_fkey", "public", "t", "a", "public", "parent", "x", "t", "f"],
            ["t_comp_fkey", "public", "t", "b", "public", "parent", "y", "t", "f"],
        ]
        let fks = PgForeignKeyParser.parse(rows: rows)

        XCTAssertEqual(fks.outgoing.count, 1)
        XCTAssertEqual(fks.outgoing[0].fromColumns, ["a", "b"])
        XCTAssertEqual(fks.outgoing[0].toColumns, ["x", "y"])
    }

    func testSeparatesOutgoingAndIncoming() {
        let rows: [[String?]] = [
            ["orders_user_id_fkey", "public", "orders", "user_id",
             "public", "users", "id", "t", "f"],
            ["sessions_user_id_fkey", "public", "sessions", "user_id",
             "public", "users", "id", "f", "t"],
        ]
        let fks = PgForeignKeyParser.parse(rows: rows)

        XCTAssertEqual(fks.outgoing.map(\.constraintName), ["orders_user_id_fkey"])
        XCTAssertEqual(fks.incoming.map(\.constraintName), ["sessions_user_id_fkey"])
    }

    func testSelfReferencingFKAppearsInBothDirections() {
        let rows: [[String?]] = [
            ["emp_manager_fkey", "public", "employees", "manager_id",
             "public", "employees", "id", "t", "t"],
        ]
        let fks = PgForeignKeyParser.parse(rows: rows)

        XCTAssertEqual(fks.outgoing.count, 1)
        XCTAssertEqual(fks.incoming.count, 1)
        XCTAssertEqual(fks.outgoing[0], fks.incoming[0])
        XCTAssertFalse(fks.isEmpty)
    }

    func testSameConstraintNameOnDifferentTablesNotMerged() {
        // Constraint names are only unique per declaring table.
        let rows: [[String?]] = [
            ["fk", "public", "a", "ref_id", "public", "users", "id", "f", "t"],
            ["fk", "public", "b", "ref_id", "public", "users", "id", "f", "t"],
        ]
        let fks = PgForeignKeyParser.parse(rows: rows)

        XCTAssertEqual(fks.incoming.count, 2)
        XCTAssertEqual(fks.incoming.map(\.fromTable), ["a", "b"])
    }

    func testSkipsMalformedRows() {
        let rows: [[String?]] = [
            ["short_row"],
            [nil, "public", "orders", "user_id", "public", "users", "id", "t", "f"],
            ["good_fkey", "public", "orders", "user_id",
             "public", "users", "id", "t", "f"],
        ]
        let fks = PgForeignKeyParser.parse(rows: rows)

        XCTAssertEqual(fks.outgoing.map(\.constraintName), ["good_fkey"])
    }

    func testEmptyInputYieldsEmptyResult() {
        let fks = PgForeignKeyParser.parse(rows: [])
        XCTAssertTrue(fks.isEmpty)
    }

    // MARK: - Filtered relation tab SQL

    @MainActor
    func testOpenRelationTabWithoutFilterKeepsOriginalShape() {
        let store = PostgresQueryTabsStore()
        let id = store.openRelationTab(schema: "public", name: "users")
        let tab = store.tabs.first { $0.id == id }

        XCTAssertEqual(
            tab?.sql,
            "SELECT *, ctid AS \(POSTGRES_ROWID_COLUMN) FROM \"public\".\"users\" LIMIT 500;"
        )
        XCTAssertEqual(tab?.editTarget?.table, "users")
    }

    @MainActor
    func testOpenRelationTabInjectsWhereClauseBeforeLimit() {
        let store = PostgresQueryTabsStore()
        let id = store.openRelationTab(
            schema: "public",
            name: "users",
            whereClause: "\"id\" = '42'"
        )
        let tab = store.tabs.first { $0.id == id }

        XCTAssertEqual(
            tab?.sql,
            "SELECT *, ctid AS \(POSTGRES_ROWID_COLUMN) FROM \"public\".\"users\" WHERE \"id\" = '42' LIMIT 500;"
        )
        // Filtered tabs stay editable — the rowid column is present
        // and the edit target is the same table.
        XCTAssertEqual(tab?.editTarget?.schema, "public")
        XCTAssertEqual(tab?.editTarget?.table, "users")
    }
}
