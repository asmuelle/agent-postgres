import SwiftUI
import OSLog
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// Postgres DDL Object Wizard View (Pillar 1)
// Offers a premium visual schema designer with multi-tab wizard forms:
// 1. Table & Column Designer
// 2. Index Builder
// 3. Foreign Key Constraint Builder
// Includes a real-time side-by-side Live SQL Preview for developers.
// =============================================================================

struct WizardColumn: Identifiable, Hashable {
    let id = UUID()
    var name: String = ""
    var type: String = "integer"
    var length: String = ""
    var isNullable: Bool = true
    var isPrimaryKey: Bool = false
    var defaultValue: String = ""
}

struct WizardIndex: Identifiable, Hashable {
    let id = UUID()
    var name: String = ""
    var columns: [String] = []
    var type: String = "btree" // btree, hash, gist, gin
    var condition: String = ""
}

struct WizardConstraint: Identifiable, Hashable {
    let id = UUID()
    var name: String = ""
    var localColumn: String = ""
    var foreignSchema: String = "public"
    var foreignTable: String = ""
    var foreignColumn: String = ""
    var onDelete: String = "NO ACTION" // CASCADE, SET NULL, RESTRICT, NO ACTION
}

struct PostgresObjectWizardView: View {
    let connectionId: String?
    let defaultSchema: String
    let onCompleted: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var activePillar: String = "Table" // Table, Index, Constraint
    @State private var tableName: String = ""
    @State private var schemaName: String = ""
    
    // Pillar 1: Columns
    @State private var columns: [WizardColumn] = [
        WizardColumn(name: "id", type: "integer", isNullable: false, isPrimaryKey: true, defaultValue: ""),
        WizardColumn(name: "created_at", type: "timestamp with time zone", isNullable: false, isPrimaryKey: false, defaultValue: "NOW()")
    ]
    
    // Pillar 1: Indexes
    @State private var indexes: [WizardIndex] = []
    
    // Pillar 1: Constraints (Foreign Keys)
    @State private var constraints: [WizardConstraint] = []
    
    @State private var isExecuting = false
    @State private var executionError: String? = nil
    
    // SQL Types list
    private let pgTypes = [
        "integer", "bigint", "character varying", "text", "boolean",
        "timestamp with time zone", "jsonb", "uuid", "numeric", "double precision"
    ]
    
    private let indexTypes = ["btree", "hash", "gist", "gin"]
    private let fkActions = ["NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"]
    
    var body: some View {
        HStack(spacing: 0) {
            // Main Form Area
            VStack(alignment: .leading, spacing: 0) {
                headerBar
                Divider()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        baseConfigSection
                        
                        switch activePillar {
                        case "Table":
                            tableDesignerSection
                        case "Index":
                            indexDesignerSection
                        case "Constraint":
                            constraintDesignerSection
                        default:
                            EmptyView()
                        }
                    }
                    .padding(20)
                }
                
                Divider()
                actionFooter
            }
            .frame(minWidth: 480, maxWidth: .infinity)
            
            Divider()
            
            // Side-by-side SQL Preview Panel (Live SQL Preview)
            sqlPreviewPanel
                .frame(width: 320)
        }
        .background(MidnightMacDesign.ColorToken.windowBackground)
        .frame(minWidth: 800, minHeight: 520)
        .onAppear {
            schemaName = defaultSchema.isEmpty ? "public" : defaultSchema
        }
    }
    
    // MARK: - Header Bar
    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Postgres Design Wizard")
                    .font(MidnightMacDesign.FontToken.title)
                Text("Visually configure tables, indexes, and relations.")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
            }
            
            Spacer()
            
            Picker("", selection: $activePillar) {
                Text("Table & Columns").tag("Table")
                Text("Indexes").tag("Index")
                Text("Foreign Keys").tag("Constraint")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
    
    // MARK: - Base Config Section
    @ViewBuilder
    private var baseConfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TARGET LOCATION")
                .font(MidnightMacDesign.FontToken.label)
                .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
            
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Schema")
                        .font(MidnightMacDesign.FontToken.caption)
                    TextField("Schema", text: $schemaName)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(width: 140)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Table Name")
                        .font(MidnightMacDesign.FontToken.caption)
                    TextField("e.g. users, orders", text: $tableName)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .midnightMacCard()
    }
    
    // MARK: - Table Column Designer
    @ViewBuilder
    private var tableDesignerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("COLUMNS DEFINITION")
                    .font(MidnightMacDesign.FontToken.label)
                    .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
                Spacer()
                Button(action: addColumn) {
                    Label("Add Column", systemImage: "plus")
                        .font(MidnightMacDesign.FontToken.caption)
                }
                .buttonStyle(.borderedProminent)
            }
            
            VStack(spacing: 0) {
                // Table header
                HStack(spacing: 10) {
                    Text("PK").font(MidnightMacDesign.FontToken.caption).bold().frame(width: 24, alignment: .center)
                    Text("Column Name").font(MidnightMacDesign.FontToken.caption).bold().frame(width: 120, alignment: .leading)
                    Text("Datatype").font(MidnightMacDesign.FontToken.caption).bold().frame(width: 130, alignment: .leading)
                    Text("Null").font(MidnightMacDesign.FontToken.caption).bold().frame(width: 32, alignment: .center)
                    Text("Default Value").font(MidnightMacDesign.FontToken.caption).bold().frame(maxWidth: .infinity, alignment: .leading)
                    Spacer().frame(width: 24)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(MidnightMacDesign.ColorToken.controlBackground)
                
                Divider()
                
                if columns.isEmpty {
                    VStack(spacing: 8) {
                        Text("No columns defined.")
                            .font(MidnightMacDesign.FontToken.callout)
                            .foregroundStyle(MidnightMacDesign.ColorToken.tertiaryText)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, col in
                        HStack(spacing: 10) {
                            // Primary Key
                            Toggle("", isOn: Binding(
                                get: { columns[index].isPrimaryKey },
                                set: { val in
                                    columns[index].isPrimaryKey = val
                                    if val { columns[index].isNullable = false }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .frame(width: 24, alignment: .center)
                            
                            // Name
                            TextField("name", text: $columns[index].name)
                                .textFieldStyle(.plain)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 120)
                            
                            // Type
                            Picker("", selection: $columns[index].type) {
                                ForEach(pgTypes, id: \.self) { t in
                                    Text(t).tag(t)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 130)
                            
                            // Nullable
                            Toggle("", isOn: Binding(
                                get: { columns[index].isNullable },
                                set: { val in
                                    if !columns[index].isPrimaryKey {
                                        columns[index].isNullable = val
                                    }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .disabled(columns[index].isPrimaryKey)
                            .frame(width: 32, alignment: .center)
                            
                            // Default Value
                            TextField("NULL / DEFAULT", text: $columns[index].defaultValue)
                                .textFieldStyle(.plain)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity)
                            
                            // Delete row
                            Button {
                                columns.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 24, alignment: .center)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        
                        Divider()
                    }
                }
            }
            .midnightMacCard()
            .border(MidnightMacDesign.ColorToken.separator, width: 1)
        }
    }
    
    // MARK: - Index Designer
    @ViewBuilder
    private var indexDesignerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("INDEXES")
                    .font(MidnightMacDesign.FontToken.label)
                    .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
                Spacer()
                Button(action: addIndex) {
                    Label("Add Index", systemImage: "plus")
                        .font(MidnightMacDesign.FontToken.caption)
                }
                .buttonStyle(.bordered)
            }
            
            if indexes.isEmpty {
                VStack(spacing: 8) {
                    Text("No indexes configured for this table.")
                        .font(MidnightMacDesign.FontToken.callout)
                        .foregroundStyle(MidnightMacDesign.ColorToken.tertiaryText)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .midnightMacCard()
            } else {
                ForEach(Array(indexes.enumerated()), id: \.element.id) { index, idx in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Index Name", text: Binding(
                                get: { indexes[index].name },
                                set: { val in indexes[index].name = val }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            
                            Picker("Type", selection: $indexes[index].type) {
                                ForEach(indexTypes, id: \.self) { t in
                                    Text(t.uppercased()).tag(t)
                                }
                            }
                            .frame(width: 100)
                            
                            Button {
                                indexes.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        // Select target columns
                        HStack {
                            Text("Columns:")
                                .font(MidnightMacDesign.FontToken.caption)
                                .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
                            
                            FlowLayout(spacing: 6) {
                                ForEach(columns.filter { !$0.name.isEmpty }, id: \.id) { col in
                                    let isSelected = indexes[index].columns.contains(col.name)
                                    Button {
                                        if isSelected {
                                            indexes[index].columns.removeAll { $0 == col.name }
                                        } else {
                                            indexes[index].columns.append(col.name)
                                        }
                                        // Auto name index
                                        if indexes[index].name.isEmpty || indexes[index].name.starts(with: "idx_") {
                                            let colsStr = indexes[index].columns.joined(separator: "_")
                                            indexes[index].name = "idx_\(tableName.isEmpty ? "table" : tableName)_\(colsStr)"
                                        }
                                    } label: {
                                        Text(col.name)
                                            .font(MidnightMacDesign.FontToken.caption)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(isSelected ? Color.accentColor : MidnightMacDesign.ColorToken.controlBackground)
                                            .foregroundStyle(isSelected ? .white : .primary)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        
                        TextField("Optional Filter Condition (WHERE clause, e.g. active = true)", text: $indexes[index].condition)
                            .textFieldStyle(.roundedBorder)
                            .font(MidnightMacDesign.FontToken.caption)
                    }
                    .padding(12)
                    .midnightMacCard()
                    .border(MidnightMacDesign.ColorToken.separator, width: 1)
                }
            }
        }
    }
    
    // MARK: - Constraint Designer (Foreign Keys)
    @ViewBuilder
    private var constraintDesignerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("FOREIGN KEYS")
                    .font(MidnightMacDesign.FontToken.label)
                    .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
                Spacer()
                Button(action: addConstraint) {
                    Label("Add Foreign Key", systemImage: "plus")
                        .font(MidnightMacDesign.FontToken.caption)
                }
                .buttonStyle(.bordered)
            }
            
            if constraints.isEmpty {
                VStack(spacing: 8) {
                    Text("No foreign keys configured.")
                        .font(MidnightMacDesign.FontToken.callout)
                        .foregroundStyle(MidnightMacDesign.ColorToken.tertiaryText)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .midnightMacCard()
            } else {
                ForEach(Array(constraints.enumerated()), id: \.element.id) { index, fk in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("Constraint Name", text: $constraints[index].name)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            
                            Button {
                                constraints.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        // Select local column
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Local Column").font(MidnightMacDesign.FontToken.caption)
                                Picker("", selection: $constraints[index].localColumn) {
                                    Text("Select Column").tag("")
                                    ForEach(columns.filter { !$0.name.isEmpty }, id: \.id) { col in
                                        Text(col.name).tag(col.name)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                            }
                            
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                                .padding(.top, 14)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ref Schema").font(MidnightMacDesign.FontToken.caption)
                                TextField("Ref Schema", text: $constraints[index].foreignSchema)
                                    .textFieldStyle(.roundedBorder)
                            }
                            .frame(width: 80)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ref Table").font(MidnightMacDesign.FontToken.caption)
                                TextField("Ref Table", text: Binding(
                                    get: { constraints[index].foreignTable },
                                    set: { val in
                                        constraints[index].foreignTable = val
                                        // Auto constraint name
                                        if constraints[index].name.isEmpty || constraints[index].name.starts(with: "fk_") {
                                            constraints[index].name = "fk_\(tableName.isEmpty ? "table" : tableName)_\(val)"
                                        }
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ref Column").font(MidnightMacDesign.FontToken.caption)
                                TextField("Ref Column", text: $constraints[index].foreignColumn)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        
                        Picker("ON DELETE Rule", selection: $constraints[index].onDelete) {
                            ForEach(fkActions, id: \.self) { act in
                                Text(act).tag(act)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    .padding(12)
                    .midnightMacCard()
                    .border(MidnightMacDesign.ColorToken.separator, width: 1)
                }
            }
        }
    }
    
    // MARK: - SQL Preview Panel
    @ViewBuilder
    private var sqlPreviewPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "terminal")
                Text("LIVE SQL PREVIEW")
                    .font(MidnightMacDesign.FontToken.label)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(generateDDL(), forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy SQL DDL")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(MidnightMacDesign.ColorToken.controlBackground)
            
            Divider()
            
            ScrollView {
                Text(generateDDL())
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(MidnightMacDesign.ColorToken.textBackground)
        }
    }
    
    // MARK: - Action Footer
    @ViewBuilder
    private var actionFooter: some View {
        HStack {
            if let error = executionError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(MidnightMacDesign.FontToken.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }
            
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(.trailing, 8)
            
            Button(action: executeDesign) {
                HStack {
                    if isExecuting {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                    }
                    Text("Execute DDL")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(tableName.isEmpty || columns.isEmpty || isExecuting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(MidnightMacDesign.ColorToken.controlBackground)
    }
    
    // MARK: - Helper Actions
    private func addColumn() {
        columns.append(WizardColumn())
    }
    
    private func addIndex() {
        indexes.append(WizardIndex(name: "idx_\(tableName.isEmpty ? "table" : tableName)_col"))
    }
    
    private func addConstraint() {
        constraints.append(WizardConstraint(name: "fk_\(tableName.isEmpty ? "table" : tableName)_ref"))
    }
    
    private func generateDDL() -> String {
        let sc = schemaName.isEmpty ? "public" : schemaName
        let tb = tableName.isEmpty ? "[table_name]" : tableName
        
        var ddl = "-- PostgreSQL Visual Design Generated DDL\n"
        ddl += "CREATE TABLE IF NOT EXISTS \(sc).\(tb) (\n"
        
        let colLines = columns.map { col -> String in
            let colName = col.name.isEmpty ? "[column_name]" : col.name
            var line = "    \(colName) \(col.type)"
            
            if !col.length.isEmpty, let _ = Int(col.length) {
                line += "(\(col.length))"
            }
            
            if !col.isNullable {
                line += " NOT NULL"
            }
            
            if col.isPrimaryKey {
                line += " PRIMARY KEY"
            }
            
            if !col.defaultValue.isEmpty {
                line += " DEFAULT \(col.defaultValue)"
            }
            return line
        }
        
        ddl += colLines.joined(separator: ",\n")
        ddl += "\n);\n"
        
        // Append Indexes
        for idx in indexes {
            let idxName = idx.name.isEmpty ? "idx_\(tb)_idx" : idx.name
            if !idx.columns.isEmpty {
                let colStr = idx.columns.joined(separator: ", ")
                var idxDdl = "\nCREATE INDEX IF NOT EXISTS \(idxName) ON \(sc).\(tb) USING \(idx.type) (\(colStr))"
                if !idx.condition.isEmpty {
                    idxDdl += " WHERE \(idx.condition)"
                }
                ddl += idxDdl + ";\n"
            }
        }
        
        // Append Constraints
        for fk in constraints {
            let fkName = fk.name.isEmpty ? "fk_\(tb)_fk" : fk.name
            if !fk.localColumn.isEmpty && !fk.foreignTable.isEmpty && !fk.foreignColumn.isEmpty {
                ddl += "\nALTER TABLE \(sc).\(tb) ADD CONSTRAINT \(fkName)\n"
                ddl += "    FOREIGN KEY (\(fk.localColumn)) \n"
                ddl += "    REFERENCES \(fk.foreignSchema).\(fk.foreignTable) (\(fk.foreignColumn))\n"
                ddl += "    ON DELETE \(fk.onDelete);\n"
            }
        }
        
        return ddl
    }
    
    private func executeDesign() {
        guard let connectionId else {
            executionError = "Database connection is not available."
            return
        }
        
        let sql = generateDDL()
        isExecuting = true
        executionError = nil
        let session = UUID().uuidString
        
        Task {
            defer {
                Task {
                    await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: session)
                }
            }
            do {
                _ = try await BridgeManager.shared.pgExecute(
                    connectionId: connectionId,
                    sessionId: session,
                    sql: sql,
                    pageSize: 10
                )
                
                await MainActor.run {
                    isExecuting = false
                    onCompleted()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isExecuting = false
                    executionError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - FlowLayout Utility
struct FlowLayout: Layout {
    var spacing: CGFloat
    
    init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var height: CGFloat = 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var maxHeightInRow: CGFloat = 0
        
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            currentX += size.width + spacing
            maxHeightInRow = max(maxHeightInRow, size.height)
        }
        
        height = currentY + maxHeightInRow
        return CGSize(width: width, height: height)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var maxHeightInRow: CGFloat = 0
        
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            view.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            maxHeightInRow = max(maxHeightInRow, size.height)
        }
    }
}
