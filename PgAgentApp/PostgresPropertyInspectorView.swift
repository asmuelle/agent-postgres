#if os(macOS)
import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

struct PostgresPropertyInspectorView: View {
    let node: PgSchemaNode
    let connectionId: String?
    @ObservedObject var store: PgSchemaStore
    var onClose: () -> Void

    @State private var editName: String = ""
    @State private var editType: String = ""
    @State private var editNotNull: Bool = false
    @State private var executionError: String? = nil
    @State private var isExecuting: Bool = false
    @State private var showSuccessAnimation: Bool = false

    @State private var activeTab: InspectorTab = .properties
    @State private var reconstructedDDL: String = "Loading DDL..."

    enum InspectorTab: String, CaseIterable, Identifiable {
        case properties = "Properties"
        case ddl = "DDL Source"
        var id: String { self.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label(inspectorTitle, systemImage: iconName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor).opacity(0.8))

            Divider()

            Picker("", selection: $activeTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if activeTab == .properties {
                ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Parent Path Info
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Location").font(.caption).foregroundStyle(.tertiary)
                        Text(pathLabel)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.horizontal)
                    .padding(.top)

                    Divider().padding(.horizontal)

                    // Property Fields (Editable)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Properties").font(.subheadline.bold())
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Name").font(.caption).foregroundStyle(.secondary)
                            TextField("Name", text: $editName)
                                .textFieldStyle(.roundedBorder)
                        }

                        if hasTypeProperty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Data Type").font(.caption).foregroundStyle(.secondary)
                                if isColumn {
                                    TextField("Type", text: $editType)
                                        .textFieldStyle(.roundedBorder)
                                } else {
                                    Text(editType)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .padding(.vertical, 4)
                                }
                            }
                        }

                        if isColumn {
                            Toggle("Not Null", isOn: $editNotNull)
                                .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.horizontal)

                    Divider().padding(.horizontal)

                    // Real-Time Generated DDL Preview
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Real-Time DDL SQL").font(.subheadline.bold())
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(generatedDDL, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help("Copy SQL")
                        }
                        
                        Text(generatedDDL)
                            .font(.system(.caption, design: .monospaced))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
                            )
                    }
                    .padding(.horizontal)

                    // Error display
                    if let err = executionError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }

                    // Execution Controls
                    HStack {
                        Spacer()
                        if showSuccessAnimation {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("DDL Executed Successfully!")
                                    .foregroundStyle(.green)
                                    .font(.subheadline.bold())
                            }
                            .transition(.scale.combined(with: .opacity))
                        } else {
                            Button {
                                Task { await executeDDL() }
                            } label: {
                                if isExecuting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Execute Changes")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(editName.isEmpty || !isDirty || connectionId == nil)
                        }
                        Spacer()
                    }
                    .padding(.vertical)
                }
            } } else {
                // Reconstructed DDL Source Tab
                VStack(spacing: 0) {
                    HStack {
                        Text("Reconstructed DDL Source").font(.subheadline.bold())
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(reconstructedDDL, forType: .string)
                        } label: {
                            Label("Copy DDL", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding()
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.5))

                    Divider()

                    ScrollView {
                        Text(reconstructedDDL)
                            .font(.system(.caption, design: .monospaced))
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.2))
                    }
                }
                .onAppear {
                    Task {
                        await loadReconstructedDDL()
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
        .onAppear {
            resetFields()
        }
        .onChange(of: node) { _ in
            resetFields()
            if activeTab == .ddl {
                Task {
                    await loadReconstructedDDL()
                }
            }
        }
        .onChange(of: activeTab) { newValue in
            if newValue == .ddl {
                Task {
                    await loadReconstructedDDL()
                }
            }
        }
    }

    // MARK: - DDL Logic

    private var isDirty: Bool {
        switch node.kind {
        case .column(let typeName, let notNull):
            return editName != node.name || editType != typeName || editNotNull != notNull
        default:
            return editName != node.name
        }
    }

    private var generatedDDL: String {
        guard let parsed = PostgresNodeDDL.target(for: node) else { return "-- Unknown ID format" }
        let sEsc = "\"\(parsed.schema)\""
        let tEsc = parsed.table != nil ? "\"\(parsed.table!)\"" : ""
        // The bare object name from the node id — `node.name` is a
        // DISPLAY string that for keys/constraints carries the
        // definition suffix ("users_pkey (PRIMARY KEY (id))"), which
        // would render an invalid identifier in RENAME statements.
        let nEsc = "\"\(parsed.name)\""
        let newEsc = "\"\(editName)\""

        switch node.kind {
        case .column(let typeName, let notNull):
            var sqls: [String] = []
            if editName != node.name {
                sqls.append("ALTER TABLE \(sEsc).\(tEsc) RENAME COLUMN \(nEsc) TO \(newEsc);")
            }
            if editType != typeName {
                sqls.append("ALTER TABLE \(sEsc).\(tEsc) ALTER COLUMN \(newEsc) TYPE \(editType);")
            }
            if editNotNull != notNull {
                if editNotNull {
                    sqls.append("ALTER TABLE \(sEsc).\(tEsc) ALTER COLUMN \(newEsc) SET NOT NULL;")
                } else {
                    sqls.append("ALTER TABLE \(sEsc).\(tEsc) ALTER COLUMN \(newEsc) DROP NOT NULL;")
                }
            }
            return sqls.isEmpty ? "-- No changes" : sqls.joined(separator: "\n")
        case .key:
            return "ALTER TABLE \(sEsc).\(tEsc) RENAME CONSTRAINT \(nEsc) TO \(newEsc);"
        case .constraint:
            return "ALTER TABLE \(sEsc).\(tEsc) RENAME CONSTRAINT \(nEsc) TO \(newEsc);"
        case .trigger:
            return "ALTER TABLE \(sEsc).\(tEsc) RENAME TRIGGER \(nEsc) TO \(newEsc);"
        case .sequence:
            return "ALTER SEQUENCE \(sEsc).\(nEsc) RENAME TO \(newEsc);"
        case .routine(let rkind, let signature, _):
            let typeKeyword = rkind == .procedure ? "PROCEDURE" : "FUNCTION"
            // The identity-argument signature pins the exact overload
            // (it carries no parentheses of its own).
            return "ALTER \(typeKeyword) \(sEsc).\"\(parsed.name)\"(\(signature)) RENAME TO \(newEsc);"
        case .objectType:
            return "ALTER TYPE \(sEsc).\(nEsc) RENAME TO \(newEsc);"
        default:
            return "-- Editing not supported for this element"
        }
    }

    private func executeDDL() async {
        guard let connId = connectionId else { return }
        isExecuting = true
        executionError = nil
        
        let sessionId = "inspector-\(UUID().uuidString)"
        defer {
            Task {
                await BridgeManager.shared.pgReleaseSession(connectionId: connId, sessionId: sessionId)
            }
        }
        do {
            _ = try await BridgeManager.shared.pgExecute(
                connectionId: connId,
                sessionId: sessionId,
                sql: generatedDDL,
                pageSize: 10
            )
            
            // Success! Refresh tree section
            if let parsed = PostgresNodeDDL.target(for: node) {
                switch node.kind {
                case .column, .key, .constraint, .trigger:
                    if let table = parsed.table {
                        await store.loadColumns(database: parsed.database, schema: parsed.schema, table: table)
                        await store.loadMeta(database: parsed.database, schema: parsed.schema, table: table)
                    }
                case .sequence, .routine, .objectType:
                    await store.loadSchemaContents(database: parsed.database, schema: parsed.schema)
                default:
                    break
                }
            }
            
            withAnimation {
                showSuccessAnimation = true
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation {
                    showSuccessAnimation = false
                    resetFields()
                }
            }
        } catch {
            executionError = error.localizedDescription
        }
        isExecuting = false
    }

    // MARK: - Helpers

    private func resetFields() {
        editName = node.name
        executionError = nil
        showSuccessAnimation = false
        
        switch node.kind {
        case .column(let typeName, let notNull):
            editType = typeName
            editNotNull = notNull
        case .key(let type):
            editType = "Key Type: \(type)"
        case .constraint(let type, _):
            editType = "Constraint Type: \(type)"
        case .routine(let rkind, _, _):
            editType = rkind.rawValue
        case .objectType(let kind):
            editType = kind.rawValue
        default:
            editType = ""
        }
    }

    private var isColumn: Bool {
        if case .column = node.kind { return true }
        return false
    }

    private var hasTypeProperty: Bool {
        switch node.kind {
        case .column, .key, .constraint, .routine, .objectType:
            return true
        default:
            return false
        }
    }

    private var inspectorTitle: String {
        switch node.kind {
        case .column:       return "Column Editor"
        case .key:          return "Key Editor"
        case .constraint:   return "Constraint Editor"
        case .trigger:      return "Trigger Editor"
        case .sequence:     return "Sequence Editor"
        case .routine:      return "Routine Editor"
        case .objectType:   return "Type Editor"
        default:            return "Property Editor"
        }
    }

    private var iconName: String {
        switch node.kind {
        case .column:       return "list.bullet"
        case .key:          return "key.fill"
        case .constraint:   return "lock.shield"
        case .trigger:      return "bolt.fill"
        case .sequence:     return "number"
        case .routine(let k, _, _): return k.sfSymbol
        case .objectType(let k):    return k.sfSymbol
        default:            return "info.circle"
        }
    }

    private var pathLabel: String {
        guard let parsed = PostgresNodeDDL.target(for: node) else { return "" }
        if let table = parsed.table {
            return "\(parsed.database) / \(parsed.schema) / \(table)"
        }
        return "\(parsed.database) / \(parsed.schema)"
    }

    // MARK: - Reconstructive DDL Source Methods
    /// Delegate to the kind-aware DDL engine. Every node kind the
    /// tree can produce is covered there; failures come back as SQL
    /// comments so this pane never shows a bare error state.
    private func loadReconstructedDDL() async {
        guard let connectionId else {
            reconstructedDDL = "-- Not connected — DDL source needs a live connection."
            return
        }
        reconstructedDDL = "Loading DDL…"
        reconstructedDDL = await PostgresNodeDDL.reconstruct(node: node, connectionId: connectionId)
    }
}
#endif
