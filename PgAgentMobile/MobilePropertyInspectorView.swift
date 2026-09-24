import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

struct MobilePropertyInspectorView: View {
    let node: PgSchemaNode
    let connectionId: String?
    @ObservedObject var schemaStore: PgSchemaStore
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

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
        ZStack {
            MidnightColors.primaryBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                if let onClose = onClose {
                    HStack {
                        HStack(spacing: 8) {
                            Image(systemName: iconName)
                                .foregroundStyle(MidnightColors.accentCyan)
                            Text(node.name)
                                .font(MidnightMobileDesign.FontToken.headline)
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding()
                    .background(Color.black.opacity(0.3))
                }

                Picker("", selection: $activeTab) {
                        ForEach(InspectorTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    Divider()

                    if activeTab == .properties, isRole {
                        // Roles get the pgAdmin-style editor: privilege
                        // attributes, connection limit / expiry, comment,
                        // and memberships.
                        MobileRoleEditorView(
                            roleName: node.name,
                            connectionId: connectionId,
                            onApplied: { _ in
                                Task { await schemaStore.loadRoles() }
                            }
                        )
                    } else if activeTab == .properties {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                        // Leaf Details Card
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: iconName)
                                    .foregroundStyle(MidnightColors.accentCyan)
                                    .font(.headline)
                                Text(inspectorTitle)
                                    .font(MidnightMobileDesign.FontToken.captionStrong)
                                    .foregroundStyle(.primary)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 4) {
                                Text("LOCATION").font(.caption2).foregroundStyle(.secondary)
                                Text(pathLabel)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.02))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)

                        // Editable Attributes
                        VStack(alignment: .leading, spacing: 16) {
                            Text("PROPERTIES")
                                .font(MidnightMobileDesign.FontToken.captionStrong)
                                .foregroundStyle(MidnightColors.accentCyan)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Name").font(.caption).foregroundStyle(.secondary)
                                TextField("Name", text: $editName)
                                    .textFieldStyle(.plain)
                                    .padding(10)
                                    .background(Color.white.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }

                            if hasTypeProperty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Data Type").font(.caption).foregroundStyle(.secondary)
                                    if isColumn {
                                        TextField("Type", text: $editType)
                                            .textFieldStyle(.plain)
                                            .padding(10)
                                            .background(Color.white.opacity(0.05))
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    } else {
                                        Text(editType)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(.primary)
                                            .padding(.vertical, 4)
                                    }
                                }
                            }

                            if isColumn {
                                Toggle(isOn: $editNotNull) {
                                    Text("Not Null")
                                        .font(MidnightMobileDesign.FontToken.caption)
                                }
                                .toggleStyle(SwitchToggleStyle(tint: MidnightColors.accentCyan))
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.02))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)

                        // Real-Time DDL preview
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("GENERATED DDL SQL")
                                    .font(MidnightMobileDesign.FontToken.captionStrong)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = generatedDDL
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .foregroundStyle(MidnightColors.accentCyan)
                                }
                                .buttonStyle(.plain)
                            }

                            Text(generatedDDL)
                                .font(.system(.caption2, design: .monospaced))
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.black.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .padding()
                        .background(Color.white.opacity(0.02))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)

                        if let err = executionError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal)
                        }

                        // Execute changes action
                        HStack {
                            Spacer()
                            if showSuccessAnimation {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("DDL Executed Successfully!")
                                        .foregroundStyle(.green)
                                        .font(.headline)
                                }
                                .transition(.scale.combined(with: .opacity))
                            } else {
                                Button {
                                    Task { await executeDDL() }
                                } label: {
                                    HStack {
                                        if isExecuting {
                                            ProgressView().tint(.black)
                                        } else {
                                            Text("Execute Changes")
                                                .font(.headline)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(canExecute ? MidnightColors.accentCyan : Color.gray.opacity(0.2))
                                    .foregroundStyle(.black)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .disabled(!canExecute)
                            }
                            Spacer()
                        }
                        .padding()
                            }
                        }
                    } else {
                        // Reconstructed DDL Source
                        VStack(spacing: 0) {
                            HStack {
                                Text("Reconstructed DDL Source").font(.subheadline.bold())
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = reconstructedDDL
                                } label: {
                                    Label("Copy DDL", systemImage: "doc.on.doc")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding()

                            Divider()

                            ScrollView {
                                HighlightedSQLText(sql: reconstructedDDL)
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
            }
            .onAppear {
                resetFields()
            }
            .onChange(of: node) { _, _ in
                resetFields()
                if activeTab == .ddl {
                    Task {
                        await loadReconstructedDDL()
                    }
                }
            }
            .onChange(of: activeTab) { _, newValue in
                if newValue == .ddl {
                    Task {
                        await loadReconstructedDDL()
                    }
                }
            }
        }

    // MARK: - DDL logic

    private var isDirty: Bool {
        switch node.kind {
        case .column(let typeName, let notNull):
            return editName != node.name || editType != typeName || editNotNull != notNull
        default:
            return editName != node.name
        }
    }

    /// Shared, fully quoted statement builder (same as macOS).
    private var generatedDDL: String {
        PostgresNodeAlterDDL.statements(
            for: node,
            edit: .init(name: editName, type: editType, notNull: editNotNull)
        )
    }

    private var canExecute: Bool {
        !editName.isEmpty && isDirty && connectionId != nil && !generatedDDL.hasPrefix("--")
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
            if let parsed = PgNodeID.target(for: node) {
                switch node.kind {
                case .column, .key, .constraint, .trigger:
                    if let table = parsed.table {
                        await schemaStore.loadColumns(database: parsed.database, schema: parsed.schema, table: table)
                        await schemaStore.loadMeta(database: parsed.database, schema: parsed.schema, table: table)
                    }
                case .sequence, .routine, .objectType:
                    await schemaStore.loadSchemaContents(database: parsed.database, schema: parsed.schema)
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
                    dismiss()
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
        case .key(let type, _):
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

    private var isRole: Bool {
        if case .role = node.kind { return true }
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
        case .language:     return "Language Inspector"
        case .role:         return "Role Inspector"
        case .tablespace:   return "Tablespace Inspector"
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
        case .language:     return "globe"
        case .role:         return "person.2.fill"
        case .tablespace:   return "shippingbox.fill"
        default:            return "info.circle"
        }
    }

    private var pathLabel: String {
        guard let parsed = PgNodeID.target(for: node) else { return "" }
        if let table = parsed.table {
            return "\(parsed.database) / \(parsed.schema) / \(table)"
        }
        return "\(parsed.database) / \(parsed.schema)"
    }

    // MARK: - Reconstructive DDL Source Methods

    /// Roles use the role editor's reconstruction; every other kind goes
    /// through the shared, kind-aware `PostgresNodeDDL` engine (the same
    /// one macOS uses), so identifiers and literals are quoted properly.
    private func loadReconstructedDDL() async {
        guard let connectionId else {
            reconstructedDDL = "-- Not connected — DDL source needs a live connection."
            return
        }
        if case .role = node.kind {
            reconstructedDDL = await PostgresRoleEditorStore.reconstructCreateDDL(
                name: node.name, connectionId: connectionId
            )
            return
        }
        reconstructedDDL = "Loading DDL…"
        reconstructedDDL = await PostgresNodeDDL.reconstruct(node: node, connectionId: connectionId)
    }
}
