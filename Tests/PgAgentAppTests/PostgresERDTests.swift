// Tests for the ERD catalog-row parser and the deterministic
// force-directed layout engine.

import XCTest
@testable import PgAgentApp

final class PostgresERDTests: XCTestCase {

    // Row layout: [table, column, type, not_null, is_pk]

    func testParsesTablesGroupingColumnsInOrder() {
        let rows: [[String?]] = [
            ["orders", "id", "integer", "t", "t"],
            ["orders", "user_id", "integer", "t", "f"],
            ["users", "id", "integer", "t", "t"],
            ["users", "email", "text", "f", "f"],
        ]
        let tables = PgERDTablesParser.parse(rows: rows, schema: "public")

        XCTAssertEqual(tables.map(\.name), ["orders", "users"])
        XCTAssertEqual(tables[0].columns.map(\.name), ["id", "user_id"])
        XCTAssertTrue(tables[0].columns[0].isPrimaryKey)
        XCTAssertFalse(tables[0].columns[1].isPrimaryKey)
        XCTAssertTrue(tables[0].columns[1].isNotNull)
        XCTAssertFalse(tables[1].columns[1].isNotNull)
        XCTAssertEqual(tables[0].id, "public.orders")
    }

    func testParserSkipsMalformedRowsAndHandlesEmpty() {
        XCTAssertTrue(PgERDTablesParser.parse(rows: [], schema: "s").isEmpty)
        let tables = PgERDTablesParser.parse(
            rows: [["only_table"], [nil, "col", "t", "t", "f"]],
            schema: "s"
        )
        XCTAssertTrue(tables.isEmpty)
    }

    // MARK: - Layout engine

    private func nodes(_ n: Int) -> [PgERDLayoutEngine.Node] {
        (0..<n).map {
            PgERDLayoutEngine.Node(
                id: "t\($0)",
                size: CGSize(width: 220, height: 120)
            )
        }
    }

    func testLayoutIsDeterministic() {
        let edges = [PgERDLayoutEngine.Edge(from: "t0", to: "t1")]
        let a = PgERDLayoutEngine.layout(nodes: nodes(5), edges: edges)
        let b = PgERDLayoutEngine.layout(nodes: nodes(5), edges: edges)
        XCTAssertEqual(a, b, "same input must produce identical positions")
    }

    func testLayoutSeparatesNodes() {
        let positions = PgERDLayoutEngine.layout(nodes: nodes(6), edges: [])
        let points = Array(positions.values)
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let d = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
                XCTAssertGreaterThan(
                    d, 100,
                    "cards should not stack — distance \(d) between node \(i) and \(j)"
                )
            }
        }
    }

    func testLayoutPullsConnectedNodesCloserThanDisconnected() {
        // In a 10-node graph where only t0–t1 share an edge, the
        // spring should hold that pair tighter than the average
        // unlinked pair, which repulsion spreads freely. (At very
        // small node counts the equilibrium can sit below the spring
        // rest length, where the edge pushes apart instead — so test
        // at a scale where attraction dominates.)
        let edges = [PgERDLayoutEngine.Edge(from: "t0", to: "t1")]
        let positions = PgERDLayoutEngine.layout(nodes: nodes(10), edges: edges)
        let linked = distance(positions["t0"]!, positions["t1"]!)
        var unlinked: [CGFloat] = []
        for i in 0..<10 {
            for j in (i + 1)..<10 where !(i == 0 && j == 1) {
                unlinked.append(distance(positions["t\(i)"]!, positions["t\(j)"]!))
            }
        }
        let average = unlinked.reduce(0, +) / CGFloat(unlinked.count)
        XCTAssertLessThan(linked, average)
    }

    func testLayoutHandlesDegenerateInputs() {
        XCTAssertTrue(PgERDLayoutEngine.layout(nodes: [], edges: []).isEmpty)
        let single = PgERDLayoutEngine.layout(nodes: nodes(1), edges: [])
        XCTAssertEqual(single["t0"], .zero)
        // Self-edges and edges to unknown nodes must not crash.
        let weird = [
            PgERDLayoutEngine.Edge(from: "t0", to: "t0"),
            PgERDLayoutEngine.Edge(from: "t0", to: "ghost"),
        ]
        XCTAssertEqual(PgERDLayoutEngine.layout(nodes: nodes(2), edges: weird).count, 2)
    }

    func testLayoutIsCentered() {
        let positions = PgERDLayoutEngine.layout(nodes: nodes(8), edges: [])
        let xs = positions.values.map(\.x)
        let ys = positions.values.map(\.y)
        let cx = (xs.min()! + xs.max()!) / 2
        let cy = (ys.min()! + ys.max()!) / 2
        XCTAssertEqual(cx, 0, accuracy: 1)
        XCTAssertEqual(cy, 0, accuracy: 1)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
