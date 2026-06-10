import CoreGraphics
import Foundation

// =============================================================================
// PostgresERDModels — data model, catalog-row parsing, and the deterministic
// force-directed layout behind the schema diagram (ERD) tab.
//
// Everything in this file is pure (no FFI, no UI) so the geometry and the
// parsing are unit-testable. `PostgresERDView` owns loading and rendering.
// =============================================================================

/// One column row in an ERD table card.
struct PgERDColumn: Hashable, Sendable {
    let name: String
    let typeName: String
    let isPrimaryKey: Bool
    let isNotNull: Bool
}

/// One table node in the diagram.
struct PgERDTable: Identifiable, Hashable, Sendable {
    let schema: String
    let name: String
    let columns: [PgERDColumn]
    var id: String { "\(schema).\(name)" }
}

/// The full diagram model for one schema.
struct PgSchemaERD: Sendable {
    let tables: [PgERDTable]
    /// FK constraints between tables of this schema (and to tables in
    /// other schemas; those targets render as plain edges to nowhere
    /// only if the target table is absent — the view filters them).
    let foreignKeys: [PgForeignKey]

    var isEmpty: Bool { tables.isEmpty }
}

/// Parser for the one-row-per-column tables query in
/// `PostgresERDView.load`. Cell layout per row:
/// `[table_name, column_name, type, not_null("t"/"f"), is_pk("t"/"f")]`
/// ordered by table then attnum.
enum PgERDTablesParser {
    static func parse(rows: [[String?]], schema: String) -> [PgERDTable] {
        var tables: [PgERDTable] = []
        var currentName: String?
        var currentColumns: [PgERDColumn] = []

        func flush() {
            guard let name = currentName else { return }
            tables.append(PgERDTable(schema: schema, name: name, columns: currentColumns))
            currentColumns = []
        }

        for cells in rows {
            guard cells.count >= 5,
                  let table = cells[0],
                  let column = cells[1],
                  let type = cells[2]
            else { continue }
            if table != currentName {
                flush()
                currentName = table
            }
            currentColumns.append(
                PgERDColumn(
                    name: column,
                    typeName: type,
                    isPrimaryKey: cells[4] == "t",
                    isNotNull: cells[3] == "t"
                )
            )
        }
        flush()
        return tables
    }
}

// =============================================================================
// Layout
// =============================================================================

/// Deterministic force-directed layout. No randomness: nodes seed on a
/// circle in input order, then a fixed number of repulsion + spring +
/// centering iterations run. Same input → same positions, which keeps
/// the diagram stable across reloads and makes the engine testable.
enum PgERDLayoutEngine {
    struct Node {
        let id: String
        let size: CGSize
    }

    struct Edge {
        let from: String
        let to: String
    }

    /// Tuning constants. Spring length scales with the joined nodes'
    /// sizes so big cards sit further apart than small ones.
    private static let iterations = 320
    private static let repulsion: CGFloat = 32_000
    private static let springStiffness: CGFloat = 0.015
    private static let centerPull: CGFloat = 0.004
    private static let maxStep: CGFloat = 28

    static func layout(nodes: [Node], edges: [Edge]) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        if nodes.count == 1 {
            return [nodes[0].id: .zero]
        }

        let indexOf = Dictionary(
            uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) }
        )
        // Edges resolved to index pairs; unknown endpoints dropped.
        let links: [(Int, Int)] = edges.compactMap { e in
            guard let a = indexOf[e.from], let b = indexOf[e.to], a != b else { return nil }
            return (a, b)
        }

        // Seed on a circle sized to the node count — enough room that
        // the first repulsion steps don't explode.
        let radius = CGFloat(nodes.count) * 60 + 200
        var pos: [CGPoint] = nodes.enumerated().map { idx, _ in
            let angle = (CGFloat(idx) / CGFloat(nodes.count)) * 2 * .pi
            return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }

        // Effective radius per node — approximates the card with a
        // circle for the repulsion math.
        let nodeRadius: [CGFloat] = nodes.map { max($0.size.width, $0.size.height) / 2 }

        for _ in 0..<iterations {
            var force = [CGVector](repeating: .zero, count: nodes.count)

            // Pairwise repulsion.
            for a in 0..<nodes.count {
                for b in (a + 1)..<nodes.count {
                    var dx = pos[a].x - pos[b].x
                    var dy = pos[a].y - pos[b].y
                    var d2 = dx * dx + dy * dy
                    if d2 < 0.01 {
                        // Coincident nodes: nudge apart along a
                        // deterministic axis derived from the index.
                        dx = CGFloat(a - b)
                        dy = 1
                        d2 = dx * dx + dy * dy
                    }
                    let d = sqrt(d2)
                    // Stronger push while cards overlap.
                    let minD = nodeRadius[a] + nodeRadius[b] + 30
                    let strength = repulsion / d2 * (d < minD ? 3 : 1)
                    let fx = dx / d * strength
                    let fy = dy / d * strength
                    force[a].dx += fx
                    force[a].dy += fy
                    force[b].dx -= fx
                    force[b].dy -= fy
                }
            }

            // Springs along FK edges.
            for (a, b) in links {
                let dx = pos[b].x - pos[a].x
                let dy = pos[b].y - pos[a].y
                let d = max(sqrt(dx * dx + dy * dy), 0.1)
                let rest = nodeRadius[a] + nodeRadius[b] + 120
                let f = (d - rest) * springStiffness
                let fx = dx / d * f
                let fy = dy / d * f
                force[a].dx += fx
                force[a].dy += fy
                force[b].dx -= fx
                force[b].dy -= fy
            }

            // Gentle pull to the origin keeps disconnected clusters
            // from drifting apart forever.
            for i in 0..<nodes.count {
                force[i].dx -= pos[i].x * centerPull
                force[i].dy -= pos[i].y * centerPull
            }

            for i in 0..<nodes.count {
                let stepX = min(max(force[i].dx, -maxStep), maxStep)
                let stepY = min(max(force[i].dy, -maxStep), maxStep)
                pos[i].x += stepX
                pos[i].y += stepY
            }
        }

        // Normalize so the bounding box's center sits at the origin —
        // the view centers the content from there.
        let minX = pos.map(\.x).min() ?? 0
        let maxX = pos.map(\.x).max() ?? 0
        let minY = pos.map(\.y).min() ?? 0
        let maxY = pos.map(\.y).max() ?? 0
        let cx = (minX + maxX) / 2
        let cy = (minY + maxY) / 2

        var result: [String: CGPoint] = [:]
        for (idx, node) in nodes.enumerated() {
            result[node.id] = CGPoint(x: pos[idx].x - cx, y: pos[idx].y - cy)
        }
        return result
    }
}
