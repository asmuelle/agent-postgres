import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobileTableDetailView — one table, view or materialized view in Browse:
// its columns, keys, constraints and triggers, its definition, and "Open
// Data", which jumps to Query with the rows already loaded. Every part pushes
// the property inspector for details and edits.
// =============================================================================
struct MobileTableDetailView: View {
    let profile: PostgresProfile
    @ObservedObject var schemaStore: PgSchemaStore
    let node: PgSchemaNode
    let schema: String

    @Environment(MobileAppModel.self) private var app

    private var key: String {
        PgCompositeKey.table(database: profile.database, schema: schema, table: node.name)
    }

    private var metaNodes: [PgSchemaNode] {
        if case .loaded(let nodes) = schemaStore.metaState[key] { return nodes }
        return []
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Schema", value: schema)
                if let rows = node.estimatedRows, rows >= 0 {
                    LabeledContent("Rows (estimate)") {
                        Text(Int(rows), format: .number)
                    }
                }
                NavigationLink(value: node) {
                    Label("Definition", systemImage: "doc.text")
                }
            }

            columnsSection
            switch schemaStore.metaState[key] {
            case .loaded?:
                metaSection("Keys", systemImage: "key") { if case .key = $0.kind { return true }; return false }
                // NOT NULL is already on each column; PostgreSQL 18 also
                // records it as a constraint (contype 'n') — don't repeat it.
                metaSection("Constraints", systemImage: "checkmark.shield") {
                    if case .constraint(let type, _) = $0.kind { return type != "n" }
                    return false
                }
                metaSection("Triggers", systemImage: "bolt") { if case .trigger = $0.kind { return true }; return false }
            case .failed(let message)?:
                Section("Keys & Constraints") {
                    Text(message).foregroundStyle(.secondary)
                }
            case .idle?, .loading?, nil:
                Section("Keys & Constraints") {
                    ProgressView()
                }
            }
        }
        .navigationTitle(node.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Text, not an icon: a grid glyph alone doesn't say "show
                // me the rows" (toolbars render Labels icon-only).
                Button("Open Data", action: openData)
            }
        }
        .task(id: key) {
            if schemaStore.columnsState[key]?.isLoaded != true {
                await schemaStore.loadColumns(database: profile.database, schema: schema, table: node.name)
            }
            if schemaStore.metaState[key]?.isLoaded != true {
                await schemaStore.loadMeta(database: profile.database, schema: schema, table: node.name)
            }
        }
    }

    @ViewBuilder
    private var columnsSection: some View {
        Section("Columns") {
            switch schemaStore.columnsState[key] {
            case .loaded(let columns)?:
                ForEach(columns) { column in
                    NavigationLink(value: column) {
                        columnRow(column)
                    }
                }
            case .failed(let message)?:
                Text(message).foregroundStyle(.secondary)
            case .idle?, .loading?, nil:
                ProgressView()
            }
        }
    }

    private func columnRow(_ column: PgSchemaNode) -> some View {
        HStack {
            Text(column.name)
            Spacer()
            if case .column(let typeName, let notNull) = column.kind {
                Text(notNull ? "\(typeName) not null" : typeName)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func metaSection(
        _ title: String,
        systemImage: String,
        where include: (PgSchemaNode) -> Bool
    ) -> some View {
        let nodes = metaNodes.filter(include)
        if !nodes.isEmpty {
            Section(title) {
                ForEach(nodes) { meta in
                    NavigationLink(value: meta) {
                        Label(meta.label, systemImage: systemImage)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    /// Open a browse tab for this relation in Query, already running.
    private func openData() {
        MobileQueryStores.store(for: profile.id).openRelationTab(
            schema: schema,
            name: node.name,
            autoRun: true,
            relationKind: schemaStore.relationDisplayKind(schema: schema, name: node.name)
        )
        app.open(profileId: profile.id, in: .query)
    }
}
