import SwiftUI
import OSLog
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// Postgres Visual EXPLAIN Plan Analyzer (Pillar 2)
// Executes EXPLAIN (ANALYZE, COSTS, VERBOSE, BUFFERS, FORMAT JSON)
// parses the JSON tree, and draws an interactive, color-coded node graph.
// =============================================================================

struct PgExplainResult: Decodable, Sendable {
    let plan: PgPlanNode
    
    enum CodingKeys: String, CodingKey {
        case plan = "Plan"
    }
}

struct PgPlanNode: Decodable, Identifiable, Sendable, Hashable {
    let id: UUID
    let nodeType: String
    let relationName: String?
    let schema: String?
    let alias: String?
    let startupCost: Double?
    let totalCost: Double?
    let planRows: Int?
    let planWidth: Int?
    let actualStartupTime: Double?
    let actualTotalTime: Double?
    let actualRows: Int?
    let actualLoops: Int?
    let sharedHitBlocks: Int?
    let sharedReadBlocks: Int?
    let plans: [PgPlanNode]?
    
    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    static func == (lhs: PgPlanNode, rhs: PgPlanNode) -> Bool {
        lhs.id == rhs.id
    }
    
    init(from decoder: Decoder) throws {
        self.id = UUID()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.nodeType = try container.decode(String.self, forKey: .nodeType)
        self.relationName = try container.decodeIfPresent(String.self, forKey: .relationName)
        self.schema = try container.decodeIfPresent(String.self, forKey: .schema)
        self.alias = try container.decodeIfPresent(String.self, forKey: .alias)
        self.startupCost = try container.decodeIfPresent(Double.self, forKey: .startupCost)
        self.totalCost = try container.decodeIfPresent(Double.self, forKey: .totalCost)
        self.planRows = try container.decodeIfPresent(Int.self, forKey: .planRows)
        self.planWidth = try container.decodeIfPresent(Int.self, forKey: .planWidth)
        self.actualStartupTime = try container.decodeIfPresent(Double.self, forKey: .actualStartupTime)
        self.actualTotalTime = try container.decodeIfPresent(Double.self, forKey: .actualTotalTime)
        self.actualRows = try container.decodeIfPresent(Int.self, forKey: .actualRows)
        self.actualLoops = try container.decodeIfPresent(Int.self, forKey: .actualLoops)
        self.sharedHitBlocks = try container.decodeIfPresent(Int.self, forKey: .sharedHitBlocks)
        self.sharedReadBlocks = try container.decodeIfPresent(Int.self, forKey: .sharedReadBlocks)
        self.plans = try container.decodeIfPresent([PgPlanNode].self, forKey: .plans)
    }
    
    enum CodingKeys: String, CodingKey {
        case nodeType = "Node Type"
        case relationName = "Relation Name"
        case schema = "Schema"
        case alias = "Alias"
        case startupCost = "Startup Cost"
        case totalCost = "Total Cost"
        case planRows = "Plan Rows"
        case planWidth = "Plan Width"
        case actualStartupTime = "Actual Startup Time"
        case actualTotalTime = "Actual Total Time"
        case actualRows = "Actual Rows"
        case actualLoops = "Actual Loops"
        case sharedHitBlocks = "Shared Hit Blocks"
        case sharedReadBlocks = "Shared Read Blocks"
        case plans = "Plans"
    }
}

struct PostgresExplainVisualizerView: View {
    let connectionId: String?
    let query: String
    
    @State private var state: VisualizerState<PgPlanNode> = .loading
    @State private var selectedNode: PgPlanNode? = nil
    @State private var zoomScale: CGFloat = 1.0
    
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                headerBar
                Divider()
                
                switch state {
                case .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Analyzing query performance plan…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                case .error(let msg):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.red)
                        Text("Explain Plan Failed")
                            .font(.headline)
                        Text(msg)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .frame(maxWidth: 400)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                case .loaded(let rootNode):
                    ZStack(alignment: .bottomTrailing) {
                        ScrollView([.horizontal, .vertical]) {
                            VStack {
                                PgExplainTreeNodeView(node: rootNode, selectedNode: $selectedNode)
                                    .padding(40)
                                    .scaleEffect(zoomScale)
                                    .animation(.interactiveSpring, value: zoomScale)
                            }
                            .frame(minWidth: 1000, minHeight: 600)
                        }
                        
                        zoomControls
                    }
                    .background(MidnightMacDesign.ColorToken.textBackground)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            if let node = selectedNode {
                Divider()
                nodeInspectorPanel(node)
                    .frame(width: 300)
            }
        }
        .background(MidnightMacDesign.ColorToken.windowBackground)
        .task(id: query) {
            await loadExplainPlan()
        }
    }
    
    // MARK: - Header Bar
    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal.fill")
                .font(.title2)
                .foregroundStyle(.green)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Visual Query Optimizer")
                    .font(MidnightMacDesign.FontToken.title)
                Text("Explain Tree and Execution diagnostics")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
    
    // MARK: - Zoom Controls
    @ViewBuilder
    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { zoomScale = max(0.5, zoomScale - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { zoomScale = 1.0 } label: { Text("\(Int(zoomScale * 100))%") }
                .font(.system(size: 9, weight: .bold))
            Button { zoomScale = min(2.0, zoomScale + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
        }
        .padding(6)
        .background(MidnightMacDesign.ColorToken.controlBackground.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(16)
    }
    
    // MARK: - Node Details Inspector
    @ViewBuilder
    private func nodeInspectorPanel(_ node: PgPlanNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "info.circle.fill")
                Text("STEP PROPERTIES")
                    .font(MidnightMacDesign.FontToken.label)
                Spacer()
                Button {
                    selectedNode = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(MidnightMacDesign.ColorToken.controlBackground)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Group {
                        inspectorRow(label: "Node Type", value: node.nodeType)
                        if let rel = node.relationName {
                            inspectorRow(label: "Relation Name", value: rel)
                        }
                        if let sch = node.schema {
                            inspectorRow(label: "Schema", value: sch)
                        }
                        if let al = node.alias {
                            inspectorRow(label: "Alias", value: al)
                        }
                    }
                    
                    Divider()
                    
                    Group {
                        Text("ESTIMATIONS")
                            .font(MidnightMacDesign.FontToken.label)
                            .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
                            .padding(.top, 4)
                        
                        if let rows = node.planRows {
                            inspectorRow(label: "Planned Rows", value: "\(rows)")
                        }
                        if let width = node.planWidth {
                            inspectorRow(label: "Planned Width", value: "\(width) bytes")
                        }
                        if let startCost = node.startupCost, let totalCost = node.totalCost {
                            inspectorRow(label: "Startup Cost", value: String(format: "%.2f", startCost))
                            inspectorRow(label: "Total Cost", value: String(format: "%.2f", totalCost))
                        }
                    }
                    
                    Divider()
                    
                    Group {
                        Text("ACTUAL METRICS (ANALYZE)")
                            .font(MidnightMacDesign.FontToken.label)
                            .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
                            .padding(.top, 4)
                        
                        if let rows = node.actualRows {
                            inspectorRow(label: "Actual Rows", value: "\(rows)")
                        }
                        if let loops = node.actualLoops {
                            inspectorRow(label: "Actual Loops", value: "\(loops)")
                        }
                        if let start = node.actualStartupTime {
                            inspectorRow(label: "Actual Startup", value: String(format: "%.3f ms", start))
                        }
                        if let total = node.actualTotalTime {
                            inspectorRow(label: "Actual Total Time", value: String(format: "%.3f ms", total))
                        }
                    }
                    
                    if node.sharedHitBlocks != nil || node.sharedReadBlocks != nil {
                        Divider()
                        
                        Group {
                            Text("I/O BUFFERS")
                                .font(MidnightMacDesign.FontToken.label)
                                .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
                                .padding(.top, 4)
                            
                            if let hit = node.sharedHitBlocks {
                                inspectorRow(label: "Shared Cache Hits", value: "\(hit) blocks")
                            }
                            if let read = node.sharedReadBlocks {
                                inspectorRow(label: "Shared Read Hits", value: "\(read) blocks")
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }
    
    @ViewBuilder
    private func inspectorRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
            Text(value)
                .font(MidnightMacDesign.FontToken.body)
                .textSelection(.enabled)
        }
    }
    
    // MARK: - loadExplainPlan
    private func loadExplainPlan() async {
        guard let connectionId else {
            state = .error("No connection available")
            return
        }
        
        state = .loading
        let sessionId = UUID().uuidString
        let explainSql = "EXPLAIN (ANALYZE, COSTS, VERBOSE, BUFFERS, FORMAT JSON) \(query)"
        
        defer {
            Task {
                await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
            }
        }
        
        do {
            let result = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: explainSql,
                pageSize: 10
            )
            
            // Explain Plan returns a single cell containing a huge JSON array string
            guard let firstRow = result.rows.first,
                  let jsonCell = firstRow.cells.first,
                  let jsonString = jsonCell,
                  let jsonData = jsonString.data(using: .utf8) else {
                state = .error("Database returned an empty explain plan.")
                return
            }
            
            let decoder = JSONDecoder()
            let explainResults = try decoder.decode([PgExplainResult].self, from: jsonData)
            
            guard let firstResult = explainResults.first else {
                state = .error("No execution plan returned in JSON payload.")
                return
            }
            
            await MainActor.run {
                state = .loaded(firstResult.plan)
                selectedNode = firstResult.plan
            }
            
        } catch {
            await MainActor.run {
                state = .error(error.localizedDescription)
            }
        }
    }
}

// =============================================================================
// PgExplainTreeNodeView - Separated custom View struct to break the
// recursive opaque type inference loop in the compiler.
// =============================================================================
struct PgExplainTreeNodeView: View {
    let node: PgPlanNode
    @Binding var selectedNode: PgPlanNode?
    
    private func nodeIcon(_ type: String) -> String {
        let t = type.lowercased()
        if t.contains("scan") {
            if t.contains("index") { return "magnifyingglass" }
            return "tablecells"
        }
        if t.contains("join") { return "circle.grid.2x1.fill" }
        if t.contains("sort") { return "arrow.up.arrow.down" }
        if t.contains("limit") { return "arrow.down.to.line" }
        if t.contains("aggregate") { return "sum" }
        return "square.fill.and.line.vertical.and.square"
    }
    
    private func nodeColor(_ node: PgPlanNode) -> Color {
        let planRows = Double(node.planRows ?? 0)
        let actualRows = Double(node.actualRows ?? 0)
        let ratio = planRows > 0 ? (actualRows / planRows) : 1.0
        
        if ratio > 10.0 || ratio < 0.1 {
            return .red
        }
        
        if node.nodeType.contains("Seq Scan") && actualRows > 10000 {
            return .orange
        }
        
        return .green
    }
    
    private func costText(_ node: PgPlanNode) -> String {
        guard let cost = node.totalCost else { return "" }
        return String(format: "Cost: %.1f", cost)
    }
    
    private func timeText(_ node: PgPlanNode) -> String {
        guard let time = node.actualTotalTime else { return "" }
        return String(format: "Time: %.2f ms", time)
    }
    
    var body: some View {
        VStack(spacing: 24) {
            // Self Node
            Button {
                selectedNode = node
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: nodeIcon(node.nodeType))
                            .font(.title3)
                            .foregroundStyle(nodeColor(node))
                        
                        VStack(alignment: .leading, spacing: 1) {
                            Text(node.nodeType.uppercased())
                                .font(MidnightMacDesign.FontToken.label)
                            
                            if let relName = node.relationName {
                                Text("on \(relName)")
                                    .font(MidnightMacDesign.FontToken.caption)
                                    .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
                            }
                        }
                        
                        Spacer()
                        
                        if nodeColor(node) == .red {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        } else if nodeColor(node) == .orange {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    
                    Divider()
                    
                    HStack {
                        Text(costText(node))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(timeText(node))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(width: 220)
                .midnightMacCard()
                .overlay(
                    RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.medium)
                        .stroke(selectedNode?.id == node.id ? Color.accentColor : MidnightMacDesign.ColorToken.separator, lineWidth: selectedNode?.id == node.id ? 2 : 1)
                )
            }
            .buttonStyle(.plain)
            
            // Connective Line & Children
            if let children = node.plans, !children.isEmpty {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(children, id: \.id) { child in
                        VStack(spacing: 0) {
                            Rectangle()
                                .fill(MidnightMacDesign.ColorToken.separator)
                                .frame(width: 2, height: 16)
                            
                            PgExplainTreeNodeView(node: child, selectedNode: $selectedNode)
                        }
                    }
                }
            }
        }
    }
}
