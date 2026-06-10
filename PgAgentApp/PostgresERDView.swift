import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresERDView — interactive schema diagram (ERD) for one schema.
//
// Tables render as cards (name + columns, PK/FK markers), FK constraints
// as curved edges with arrowheads pointing at the referenced table.
// Layout comes from the deterministic force engine in PostgresERDModels;
// nodes are draggable afterwards. Double-click opens the table's data tab
// through the same notification bus the sidebar uses.
// =============================================================================

struct PostgresERDView: View {
    let connectionId: String?
    let profileId: String
    let schema: String

    private enum LoadPhase {
        case loading
        case loaded(PgSchemaERD)
        case failed(String)
    }

    @State private var phase: LoadPhase = .loading
    /// Node positions keyed by `PgERDTable.id`, in diagram space
    /// (origin at the content center). Seeded by the layout engine,
    /// then user-draggable.
    @State private var positions: [String: CGPoint] = [:]
    @State private var zoom: CGFloat = 0.8
    @State private var panOffset: CGSize = .zero
    /// Live drag state: (table id, translation so far). Rendered as an
    /// offset on top of `positions` and committed on drag end.
    @State private var nodeDrag: (id: String, translation: CGSize)? = nil
    @State private var panDrag: CGSize = .zero
    @State private var selectedTableId: String? = nil

    private static let minZoom: CGFloat = 0.2
    private static let maxZoom: CGFloat = 2.0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task(id: "\(connectionId ?? "-").\(schema)") {
            await load()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label("\(schema)", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            if case .loaded(let erd) = phase {
                Text("\(erd.tables.count) tables · \(visibleEdges(erd).count) relations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { zoom = clampZoom(zoom / 1.25) }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { zoom = clampZoom(zoom * 1.25) }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    zoom = 0.8
                    panOffset = .zero
                }
            } label: {
                Image(systemName: "arrow.counterclockwise.circle")
            }
            .help("Reset view")
            Button {
                if case .loaded(let erd) = phase {
                    relayout(erd)
                }
            } label: {
                Image(systemName: "wand.and.rays")
            }
            .help("Re-run automatic layout")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading schema topology…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Retry") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let erd) where erd.isEmpty:
            VStack(spacing: 8) {
                Image(systemName: "square.dashed")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("No tables in \(schema)")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let erd):
            diagram(erd)
        }
    }

    private func diagram(_ erd: PgSchemaERD) -> some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                // Background stays fixed — only the content pans/zooms.
                Color(NSColor.textBackgroundColor)
                ZStack {
                    edgeLayer(erd, center: center)
                    ForEach(erd.tables) { table in
                        nodeCard(table, foreignKeys: erd.foreignKeys)
                            .position(
                                x: diagramPosition(table.id).x + center.x,
                                y: diagramPosition(table.id).y + center.y
                            )
                            .gesture(nodeDragGesture(table.id))
                            .onTapGesture(count: 2) { openTable(table) }
                            .simultaneousGesture(
                                TapGesture().onEnded { selectedTableId = table.id }
                            )
                    }
                }
                // Scale around the viewport center, then pan in
                // screen points — order matters; pan must not scale.
                .scaleEffect(zoom)
                .offset(
                    x: panOffset.width + panDrag.width,
                    y: panOffset.height + panDrag.height
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .clipped()
            .gesture(panGesture)
        }
    }

    /// Diagram-space position (origin = content center) including any
    /// in-flight drag translation, which arrives in screen points and
    /// must be unscaled.
    private func diagramPosition(_ id: String) -> CGPoint {
        var p = positions[id] ?? .zero
        if let drag = nodeDrag, drag.id == id {
            p.x += drag.translation.width / zoom
            p.y += drag.translation.height / zoom
        }
        return p
    }

    // MARK: - Edges

    /// Edge drawings live on an oversized Canvas (a Canvas clips at
    /// its own bounds, and dragged nodes routinely leave the visible
    /// viewport before the user pans after them).
    private static let edgeCanvasExtent: CGFloat = 12_000

    private func visibleEdges(_ erd: PgSchemaERD) -> [PgForeignKey] {
        let present = Set(erd.tables.map(\.id))
        return erd.foreignKeys.filter {
            present.contains("\($0.fromSchema).\($0.fromTable)")
                && present.contains("\($0.toSchema).\($0.toTable)")
        }
    }

    private func edgeLayer(_ erd: PgSchemaERD, center: CGPoint) -> some View {
        let mid = Self.edgeCanvasExtent / 2
        return Canvas { context, _ in
            for fk in visibleEdges(erd) {
                let fromId = "\(fk.fromSchema).\(fk.fromTable)"
                let toId = "\(fk.toSchema).\(fk.toTable)"
                let fromDiagram = diagramPosition(fromId)
                guard fromId != toId else {
                    drawSelfLoop(
                        context: &context,
                        at: CGPoint(x: fromDiagram.x + mid, y: fromDiagram.y + mid)
                    )
                    continue
                }
                let toDiagram = diagramPosition(toId)
                let from = CGPoint(x: fromDiagram.x + mid, y: fromDiagram.y + mid)
                let to = CGPoint(x: toDiagram.x + mid, y: toDiagram.y + mid)
                let isHighlighted = selectedTableId == fromId || selectedTableId == toId

                var path = Path()
                path.move(to: from)
                let midpoint = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                // Slight perpendicular bow so opposing edges between
                // the same pair don't overlap exactly.
                let dx = to.x - from.x
                let dy = to.y - from.y
                let len = max(sqrt(dx * dx + dy * dy), 1)
                let bow = CGPoint(
                    x: midpoint.x - dy / len * 24,
                    y: midpoint.y + dx / len * 24
                )
                path.addQuadCurve(to: to, control: bow)

                let color: Color = isHighlighted ? .accentColor : Color.secondary.opacity(0.45)
                context.stroke(path, with: .color(color), lineWidth: isHighlighted ? 2 : 1.2)
                drawArrowhead(context: &context, from: bow, to: to, color: color)
            }
        }
        .frame(width: Self.edgeCanvasExtent, height: Self.edgeCanvasExtent)
        // Canvas center sits on the viewport center, so a diagram
        // point p draws at canvas coordinate p + mid.
        .position(x: center.x, y: center.y)
        .allowsHitTesting(false)
    }

    private func drawArrowhead(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint, color: Color
    ) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let length: CGFloat = 10
        let spread: CGFloat = .pi / 7
        var head = Path()
        head.move(to: to)
        head.addLine(
            to: CGPoint(
                x: to.x - cos(angle - spread) * length,
                y: to.y - sin(angle - spread) * length
            ))
        head.move(to: to)
        head.addLine(
            to: CGPoint(
                x: to.x - cos(angle + spread) * length,
                y: to.y - sin(angle + spread) * length
            ))
        context.stroke(head, with: .color(color), lineWidth: 1.6)
    }

    private func drawSelfLoop(context: inout GraphicsContext, at p: CGPoint) {
        let r: CGFloat = 26
        let rect = CGRect(x: p.x + 90, y: p.y - r, width: r * 2, height: r * 2)
        let path = Path(ellipseIn: rect)
        context.stroke(path, with: .color(Color.secondary.opacity(0.45)), lineWidth: 1.2)
    }

    // MARK: - Node card

    private func nodeCard(_ table: PgERDTable, foreignKeys: [PgForeignKey]) -> some View {
        let fkColumns = Set(
            foreignKeys
                .filter { $0.fromSchema == table.schema && $0.fromTable == table.name }
                .flatMap(\.fromColumns)
        )
        let isSelected = selectedTableId == table.id
        let shown = table.columns.prefix(Self.maxColumnsShown)

        return VStack(alignment: .leading, spacing: 0) {
            Text(table.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                ForEach(shown, id: \.name) { col in
                    HStack(spacing: 5) {
                        if col.isPrimaryKey {
                            Image(systemName: "key.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.yellow)
                        } else if fkColumns.contains(col.name) {
                            Image(systemName: "link")
                                .font(.system(size: 8))
                                .foregroundStyle(.blue)
                        } else {
                            Spacer().frame(width: 12)
                        }
                        Text(col.name)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(col.typeName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if table.columns.count > Self.maxColumnsShown {
                    Text("+ \(table.columns.count - Self.maxColumnsShown) more…")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 17)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: Self.cardWidth)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.35),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(0.18), radius: isSelected ? 8 : 4, y: 2)
        .help("Double-click to browse \(table.schema).\(table.name)")
    }

    static let cardWidth: CGFloat = 220
    static let maxColumnsShown = 12

    /// Card size estimate used by the layout engine — must mirror the
    /// real rendering closely enough that repulsion spacing looks right.
    static func cardSize(for table: PgERDTable) -> CGSize {
        let headerHeight: CGFloat = 27
        let rowHeight: CGFloat = 17
        let shown = min(table.columns.count, maxColumnsShown)
        let moreRow: CGFloat = table.columns.count > maxColumnsShown ? rowHeight : 0
        return CGSize(
            width: cardWidth,
            height: headerHeight + CGFloat(shown) * rowHeight + moreRow + 14
        )
    }

    // MARK: - Gestures

    private func nodeDragGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                nodeDrag = (id, value.translation)
            }
            .onEnded { value in
                var p = positions[id] ?? .zero
                p.x += value.translation.width / zoom
                p.y += value.translation.height / zoom
                positions[id] = p
                nodeDrag = nil
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                panDrag = value.translation
            }
            .onEnded { value in
                panOffset.width += value.translation.width
                panOffset.height += value.translation.height
                panDrag = .zero
            }
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat {
        min(max(z, Self.minZoom), Self.maxZoom)
    }

    // MARK: - Actions

    private func openTable(_ table: PgERDTable) {
        NotificationCenter.default.post(
            name: .openPostgresObjectTab,
            object: nil,
            userInfo: [
                "profileId": profileId,
                "kind": "relation",
                "schema": table.schema,
                "name": table.name,
            ]
        )
    }

    private func relayout(_ erd: PgSchemaERD) {
        let nodes = erd.tables.map {
            PgERDLayoutEngine.Node(id: $0.id, size: Self.cardSize(for: $0))
        }
        let edges = visibleEdges(erd).map {
            PgERDLayoutEngine.Edge(
                from: "\($0.fromSchema).\($0.fromTable)",
                to: "\($0.toSchema).\($0.toTable)"
            )
        }
        withAnimation(.easeInOut(duration: 0.35)) {
            positions = PgERDLayoutEngine.layout(nodes: nodes, edges: edges)
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let connectionId else {
            phase = .failed("Not connected.")
            return
        }
        phase = .loading
        let sessionId = "erd-loader-\(UUID().uuidString)"
        let schemaLit = pgQuoteLiteral(schema)

        // 1. Tables + columns + PK membership, one row per column.
        let tablesSql = """
        SELECT c.relname,
               a.attname,
               format_type(a.atttypid, a.atttypmod),
               a.attnotnull,
               COALESCE((
                 SELECT true FROM pg_constraint pc
                 WHERE pc.conrelid = c.oid AND pc.contype = 'p'
                   AND a.attnum = ANY (pc.conkey)
               ), false)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
        WHERE n.nspname = \(schemaLit)
          AND c.relkind IN ('r', 'p')
        ORDER BY c.relname, a.attnum
        LIMIT 5000;
        """

        // 2. Every FK touching a table in this schema, one row per key
        //    column — same shape `PgForeignKeyParser` folds. The two
        //    flag cells are constants: parse() buckets rows it sees as
        //    flagged-outgoing into `outgoing`, which here means simply
        //    "all constraints, deduplicated".
        let fksSql = """
        SELECT c.conname,
               fn.nspname, fc.relname, fa.attname,
               tn.nspname, tc.relname, ta.attname,
               true, false
        FROM pg_constraint c
        CROSS JOIN LATERAL unnest(c.conkey, c.confkey)
          WITH ORDINALITY AS k(con_attnum, conf_attnum, ord)
        JOIN pg_class fc      ON fc.oid = c.conrelid
        JOIN pg_namespace fn  ON fn.oid = fc.relnamespace
        JOIN pg_attribute fa  ON fa.attrelid = c.conrelid  AND fa.attnum = k.con_attnum
        JOIN pg_class tc      ON tc.oid = c.confrelid
        JOIN pg_namespace tn  ON tn.oid = tc.relnamespace
        JOIN pg_attribute ta  ON ta.attrelid = c.confrelid AND ta.attnum = k.conf_attnum
        WHERE c.contype = 'f'
          AND (fn.nspname = \(schemaLit) OR tn.nspname = \(schemaLit))
        ORDER BY c.oid, k.ord
        LIMIT 5000;
        """

        do {
            let tablesRes = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: tablesSql,
                pageSize: 5000
            )
            let fksRes = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: fksSql,
                pageSize: 5000
            )
            let tables = PgERDTablesParser.parse(
                rows: tablesRes.rows.map(\.cells),
                schema: schema
            )
            let fks = PgForeignKeyParser.parse(rows: fksRes.rows.map(\.cells)).outgoing
            let erd = PgSchemaERD(tables: tables, foreignKeys: fks)
            phase = .loaded(erd)
            relayout(erd)
        } catch {
            phase = .failed(error.localizedDescription)
        }
        await BridgeManager.shared.pgReleaseSession(
            connectionId: connectionId, sessionId: sessionId)
    }
}
