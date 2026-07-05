import XCTest
@testable import PgAgentApp

// Tests for the JSON tree model behind the cell inspector: tree building
// (kinds, children, sorted keys) and the two path-expression generators
// ("Copy Path" → Postgres `col->'a'->0->>'b'` and jsonpath `$.a[0].b`).
final class PostgresJSONTreeModelTests: XCTestCase {

    // MARK: - Tree building

    func testBuildsObjectTreeWithSortedKeys() throws {
        let root = try XCTUnwrap(PostgresJSONTree.build(
            fromJSONText: #"{"b": 1, "a": {"x": true}}"#
        ))
        guard case .object(let count) = root.kind else {
            return XCTFail("root should be an object")
        }
        XCTAssertEqual(count, 2)
        let children = try XCTUnwrap(root.children)
        XCTAssertEqual(children.map(\.label), ["a", "b"]) // sorted
        guard case .object = children[0].kind else {
            return XCTFail("'a' should be an object node")
        }
        guard case .number(let display) = children[1].kind else {
            return XCTFail("'b' should be a number leaf")
        }
        XCTAssertEqual(display, "1")
    }

    func testBuildsArrayTreePreservingOrder() throws {
        let root = try XCTUnwrap(PostgresJSONTree.build(
            fromJSONText: #"["z", null, false]"#
        ))
        let children = try XCTUnwrap(root.children)
        XCTAssertEqual(children.map(\.label), ["[0]", "[1]", "[2]"])
        guard case .string(let s) = children[0].kind else {
            return XCTFail("[0] should be a string")
        }
        XCTAssertEqual(s, "z")
        guard case .null = children[1].kind else {
            return XCTFail("[1] should be null")
        }
        guard case .bool(let b) = children[2].kind else {
            return XCTFail("[2] should be a bool")
        }
        XCTAssertFalse(b)
    }

    func testBoolAndNumberAreDistinguished() throws {
        let root = try XCTUnwrap(PostgresJSONTree.build(
            fromJSONText: #"{"flag": true, "count": 0}"#
        ))
        let children = try XCTUnwrap(root.children)
        guard case .number = children[0].kind else { // "count"
            return XCTFail("0 must classify as a number, not a bool")
        }
        guard case .bool = children[1].kind else { // "flag"
            return XCTFail("true must classify as a bool, not a number")
        }
    }

    func testScalarFragmentBuildsLeafRoot() throws {
        // jsonb columns can hold bare scalars.
        let root = try XCTUnwrap(PostgresJSONTree.build(fromJSONText: "42"))
        XCTAssertNil(root.children)
        guard case .number = root.kind else {
            return XCTFail("root should be a number leaf")
        }
    }

    func testInvalidJSONReturnsNil() {
        XCTAssertNil(PostgresJSONTree.build(fromJSONText: "{not json"))
    }

    // MARK: - Postgres path expressions

    func testPostgresExpressionScalarLeafUsesTextArrowOnLastHop() {
        let expr = PostgresJSONTree.postgresExpression(
            column: "payload",
            path: [.key("a"), .index(0), .key("b")],
            leafIsScalar: true
        )
        XCTAssertEqual(expr, "payload->'a'->0->>'b'")
    }

    func testPostgresExpressionContainerLeafUsesJsonArrowThroughout() {
        let expr = PostgresJSONTree.postgresExpression(
            column: "payload",
            path: [.key("a"), .index(0)],
            leafIsScalar: false
        )
        XCTAssertEqual(expr, "payload->'a'->0")
    }

    func testPostgresExpressionRootIsBareColumn() {
        XCTAssertEqual(
            PostgresJSONTree.postgresExpression(
                column: "payload", path: [], leafIsScalar: false
            ),
            "payload"
        )
    }

    func testPostgresExpressionQuotesNonPlainColumnAndEscapesKeys() {
        let expr = PostgresJSONTree.postgresExpression(
            column: "Weird Column",
            path: [.key("it's")],
            leafIsScalar: true
        )
        XCTAssertEqual(expr, "\"Weird Column\"->>'it''s'")
    }

    // MARK: - jsonpath expressions

    func testJsonpathPlainKeysAndIndices() {
        let expr = PostgresJSONTree.jsonpathExpression(
            path: [.key("a"), .index(0), .key("b")]
        )
        XCTAssertEqual(expr, "$.a[0].b")
    }

    func testJsonpathRootIsDollar() {
        XCTAssertEqual(PostgresJSONTree.jsonpathExpression(path: []), "$")
    }

    func testJsonpathQuotesNonIdentifierKeys() {
        let expr = PostgresJSONTree.jsonpathExpression(
            path: [.key("weird key"), .key(#"q"uote"#)]
        )
        XCTAssertEqual(expr, #"$."weird key"."q\"uote""#)
    }

    // MARK: - Value display

    func testValueDisplaySummaries() throws {
        let root = try XCTUnwrap(PostgresJSONTree.build(
            fromJSONText: #"{"arr": [1, 2], "obj": {"k": 1}, "s": "x"}"#
        ))
        let children = try XCTUnwrap(root.children)
        XCTAssertEqual(children[0].valueDisplay, "[2 items]")
        XCTAssertEqual(children[1].valueDisplay, "{1 key}")
        XCTAssertEqual(children[2].valueDisplay, "\"x\"")
    }
}
