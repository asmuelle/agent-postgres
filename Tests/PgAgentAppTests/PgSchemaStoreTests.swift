// Unit and Integration tests for PgSchemaStore and its associated types.
//
// These tests exercise the conversion and child-node construction logic
// inside PgSchemaStore to ensure it accurately handles and represents database structure.

import XCTest
@testable import PgAgentApp

final class PgSchemaStoreTests: XCTestCase {

    @MainActor
    func testInitialStateIsIdle() {
        let store = PgSchemaStore(connectionId: "test-connection")
        
        XCTAssertEqual(store.connectionId, "test-connection")
        
        if case .idle = store.databasesState {
            XCTAssertTrue(true)
        } else {
            XCTFail("expected databasesState to be .idle, got \(store.databasesState)")
        }
        
        XCTAssertTrue(store.schemasState.isEmpty)
        XCTAssertTrue(store.schemaContentsState.isEmpty)
        XCTAssertTrue(store.columnsState.isEmpty)
        XCTAssertTrue(store.metaState.isEmpty)
        XCTAssertFalse(store.showSystemSchemas)
    }

    func testRelationDisplayKindInit() {
        // Verify mapping from FfiPgRelationKind to PgRelationDisplayKind
        XCTAssertEqual(PgRelationDisplayKind(.table), .table)
        XCTAssertEqual(PgRelationDisplayKind(.view), .view)
        XCTAssertEqual(PgRelationDisplayKind(.materializedView), .materializedView)
        XCTAssertEqual(PgRelationDisplayKind(.partitionedTable), .partitionedTable)
        XCTAssertEqual(PgRelationDisplayKind(.foreignTable), .foreignTable)
    }

    func testRelationDisplayKindSFSymbols() {
        XCTAssertEqual(PgRelationDisplayKind.table.sfSymbol, "tablecells")
        XCTAssertEqual(PgRelationDisplayKind.view.sfSymbol, "rectangle.stack")
        XCTAssertEqual(PgRelationDisplayKind.materializedView.sfSymbol, "rectangle.stack.fill")
        XCTAssertEqual(PgRelationDisplayKind.partitionedTable.sfSymbol, "square.split.bottomrightquarter")
        XCTAssertEqual(PgRelationDisplayKind.foreignTable.sfSymbol, "rectangle.connected.to.line.below")
    }

    func testPgCategoryKindDisplayNames() {
        XCTAssertEqual(PgCategoryKind.tables.displayName, "Tables")
        XCTAssertEqual(PgCategoryKind.views.displayName, "Views")
        XCTAssertEqual(PgCategoryKind.materializedViews.displayName, "Materialized Views")
        XCTAssertEqual(PgCategoryKind.sequences.displayName, "Sequences")
        XCTAssertEqual(PgCategoryKind.routines.displayName, "Routines")
        XCTAssertEqual(PgCategoryKind.objectTypes.displayName, "Object Types")
    }

    func testSchemaContentsBundleNodesMapping() {
        // Construct a mock FfiPgSchemaContents object
        let mockContents = FfiPgSchemaContents(
            tables: [
                FfiPgRelation(schema: "public", name: "users", kind: .table, owner: "postgres", estimatedRows: 42.0),
                FfiPgRelation(schema: "public", name: "logs", kind: .partitionedTable, owner: "postgres", estimatedRows: -1.0)
            ],
            views: [
                FfiPgRelation(schema: "public", name: "active_users", kind: .view, owner: "postgres", estimatedRows: -1.0)
            ],
            materializedViews: [],
            sequences: [
                FfiPgSequence(schema: "public", name: "users_id_seq", owner: "postgres")
            ],
            routines: [
                FfiPgRoutine(schema: "public", name: "calculate_revenue", kind: .function, owner: "postgres", argumentSignature: "(date, date)", returnType: "numeric")
            ],
            objectTypes: [
                FfiPgObjectType(schema: "public", name: "user_status", kind: .enum, owner: "postgres")
            ]
        )

        let bundle = PgSchemaContentsBundle(
            database: "prod_db",
            schema: "public",
            contents: mockContents
        )

        // Verify count calculations
        XCTAssertEqual(bundle.count(for: .tables), 2)
        XCTAssertEqual(bundle.count(for: .views), 1)
        XCTAssertEqual(bundle.count(for: .materializedViews), 0)
        XCTAssertEqual(bundle.count(for: .sequences), 1)
        XCTAssertEqual(bundle.count(for: .routines), 1)
        XCTAssertEqual(bundle.count(for: .objectTypes), 1)

        // Verify nodes for Tables
        let tableNodes = bundle.nodes(for: .tables)
        XCTAssertEqual(tableNodes.count, 2)
        XCTAssertEqual(tableNodes[0].id, "rel:prod_db.public.users")
        XCTAssertEqual(tableNodes[0].name, "users")
        XCTAssertEqual(tableNodes[0].owner, "postgres")
        XCTAssertEqual(tableNodes[0].estimatedRows, 42.0)
        if case .relation(let kind) = tableNodes[0].kind {
            XCTAssertEqual(kind, .table)
        } else {
            XCTFail("expected .relation kind for first table")
        }

        XCTAssertEqual(tableNodes[1].id, "rel:prod_db.public.logs")
        XCTAssertEqual(tableNodes[1].name, "logs")
        XCTAssertEqual(tableNodes[1].owner, "postgres")
        XCTAssertEqual(tableNodes[1].estimatedRows, -1.0)
        if case .relation(let kind) = tableNodes[1].kind {
            XCTAssertEqual(kind, .partitionedTable)
        } else {
            XCTFail("expected .relation kind for second table")
        }

        // Verify nodes for Views
        let viewNodes = bundle.nodes(for: .views)
        XCTAssertEqual(viewNodes.count, 1)
        XCTAssertEqual(viewNodes[0].id, "rel:prod_db.public.active_users")
        XCTAssertEqual(viewNodes[0].name, "active_users")
        XCTAssertEqual(viewNodes[0].owner, "postgres")
        XCTAssertEqual(viewNodes[0].estimatedRows, -1.0)
        if case .relation(let kind) = viewNodes[0].kind {
            XCTAssertEqual(kind, .view)
        } else {
            XCTFail("expected .relation kind for view")
        }

        // Verify nodes for Sequences
        let seqNodes = bundle.nodes(for: .sequences)
        XCTAssertEqual(seqNodes.count, 1)
        XCTAssertEqual(seqNodes[0].id, "seq:prod_db.public.users_id_seq")
        XCTAssertEqual(seqNodes[0].name, "users_id_seq")
        XCTAssertEqual(seqNodes[0].owner, "postgres")
        XCTAssertNil(seqNodes[0].estimatedRows)
        if case .sequence = seqNodes[0].kind {
            XCTAssertTrue(true)
        } else {
            XCTFail("expected .sequence kind")
        }

        // Verify nodes for Routines
        let routineNodes = bundle.nodes(for: .routines)
        XCTAssertEqual(routineNodes.count, 1)
        XCTAssertEqual(routineNodes[0].id, "fn:prod_db.public.calculate_revenue(date, date)")
        XCTAssertEqual(routineNodes[0].name, "calculate_revenue")
        XCTAssertEqual(routineNodes[0].owner, "postgres")
        if case .routine(let kind, let sig, let ret) = routineNodes[0].kind {
            XCTAssertEqual(kind, .function)
            XCTAssertEqual(sig, "(date, date)")
            XCTAssertEqual(ret, "numeric")
        } else {
            XCTFail("expected .routine kind")
        }

        // Verify nodes for Object Types
        let typeNodes = bundle.nodes(for: .objectTypes)
        XCTAssertEqual(typeNodes.count, 1)
        XCTAssertEqual(typeNodes[0].id, "type:prod_db.public.user_status")
        XCTAssertEqual(typeNodes[0].name, "user_status")
        XCTAssertEqual(typeNodes[0].owner, "postgres")
        if case .objectType(let kind) = typeNodes[0].kind {
            XCTAssertEqual(kind, .enum)
        } else {
            XCTFail("expected .objectType kind")
        }
    }
}
