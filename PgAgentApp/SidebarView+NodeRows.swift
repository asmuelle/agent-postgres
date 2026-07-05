import PgAgentMacOS
import SwiftUI

// =============================================================================
// SidebarView leaf node rows — sequences, routines, custom types,
// relations (with their lazy Columns / Keys / Constraints / Triggers
// children).
//
// Extracted from SidebarView.swift; behavior-preserving.
// =============================================================================

extension SidebarView {
    @ViewBuilder
    func contentNodeRow(
        profile: PostgresProfile,
        store: PgSchemaStore,
        database: String,
        schema: String,
        node: PgSchemaNode
    ) -> some View {
        switch node.kind {
        case .relation:
            relationRow(profile: profile, store: store, database: database, schema: schema, rel: node)
        case .sequence:
            let parsed = parseSequenceId(node.id)
            let isConnectedDb = parsed?.database == profile.database
            HStack {
                Label(node.name, systemImage: "number")
                    .foregroundStyle(isConnectedDb ? .primary : .secondary)
                Spacer()
            }
            .tag(node.id)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedPostgresProfileId = profile.id
                selectedNodeId = node.id
                postOpenTabNotification(profile: profile, node: node, details: ["kind": "properties"])
            }
            .onTapGesture(count: 2) {
                guard let parsed = parsed else { return }
                if isConnectedDb {
                    postOpenTabNotification(
                        profile: profile,
                        node: node,
                        details: ["kind": "sequence", "schema": parsed.schema, "name": parsed.name]
                    )
                } else {
                    presentForeignDatabaseAlert(profile: profile, database: parsed.database)
                }
            }
            .help(isConnectedDb ? "Double-click to view sequence properties" : "Database '\(parsed?.database ?? "?")' isn't connected through this profile.")
            .contextMenu {
                PostgresNodeContextMenu(
                    node: node,
                    database: parsed?.database,
                    schema: parsed?.schema,
                    isConnectedDb: isConnectedDb,
                    post: { postOpenTabNotification(profile: profile, node: node, details: $0) }
                )
            }
        case .routine(let rkind, let signature, let returnType):
            let parsed = parseRoutineId(node.id)
            let isConnectedDb = parsed?.database == profile.database
            HStack(spacing: 6) {
                Label(node.name, systemImage: rkind.sfSymbol)
                    .foregroundStyle(isConnectedDb ? .primary : .secondary)
                Text(signature)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if let ret = returnType, !ret.isEmpty {
                    Text("→ \(ret)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .tag(node.id)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedPostgresProfileId = profile.id
                selectedNodeId = node.id
                postOpenTabNotification(profile: profile, node: node, details: ["kind": "properties"])
            }
            .onTapGesture(count: 2) {
                guard let parsed = parsed else { return }
                if isConnectedDb {
                    postOpenTabNotification(
                        profile: profile,
                        node: node,
                        details: ["kind": "routine", "schema": parsed.schema, "name": parsed.name, "signature": signature]
                    )
                } else {
                    presentForeignDatabaseAlert(profile: profile, database: parsed.database)
                }
            }
            .help(isConnectedDb ? "Double-click to view function definition" : "Database '\(parsed?.database ?? "?")' isn't connected through this profile.")
            .contextMenu {
                PostgresNodeContextMenu(
                    node: node,
                    database: parsed?.database,
                    schema: parsed?.schema,
                    isConnectedDb: isConnectedDb,
                    post: { postOpenTabNotification(profile: profile, node: node, details: $0) }
                )
            }
        case .objectType(let kind):
            let parsed = parseObjectTypeId(node.id)
            let isConnectedDb = parsed?.database == profile.database
            HStack(spacing: 6) {
                Label(node.name, systemImage: kind.sfSymbol)
                    .foregroundStyle(isConnectedDb ? .primary : .secondary)
                Text(kind.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .tag(node.id)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedPostgresProfileId = profile.id
                selectedNodeId = node.id
                postOpenTabNotification(profile: profile, node: node, details: ["kind": "properties"])
            }
            .onTapGesture(count: 2) {
                guard let parsed = parsed else { return }
                if isConnectedDb {
                    postOpenTabNotification(
                        profile: profile,
                        node: node,
                        details: ["kind": "objectType", "schema": parsed.schema, "name": parsed.name, "typeKind": kind.rawValue]
                    )
                } else {
                    presentForeignDatabaseAlert(profile: profile, database: parsed.database)
                }
            }
            .help(isConnectedDb ? "Double-click to view custom type details" : "Database '\(parsed?.database ?? "?")' isn't connected through this profile.")
            .contextMenu {
                PostgresNodeContextMenu(
                    node: node,
                    database: parsed?.database,
                    schema: parsed?.schema,
                    isConnectedDb: isConnectedDb,
                    post: { postOpenTabNotification(profile: profile, node: node, details: $0) }
                )
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func relationRow(
        profile: PostgresProfile,
        store: PgSchemaStore,
        database: String,
        schema: String,
        rel: PgSchemaNode
    ) -> some View {
        let key = "\(database).\(schema).\(rel.name)"
        let fullKey = "\(profile.id).\(database).\(schema).\(rel.name)"
        let isExpanded = expandedRelations.contains(fullKey)
        let symbol: String = {
            if case .relation(let kind) = rel.kind { return kind.sfSymbol }
            return "tablecells"
        }()
        let parsed = parseRelationId(rel.id)
        let isConnectedDb = parsed?.database == profile.database

        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { expanded in
                    if expanded {
                        expandedRelations.insert(fullKey)
                        Task {
                            if store.columnsState[key] == nil || store.columnsState[key]?.isLoaded == false {
                                await store.loadColumns(database: database, schema: schema, table: rel.name)
                            }
                            if store.metaState[key] == nil || store.metaState[key]?.isLoaded == false {
                                await store.loadMeta(database: database, schema: schema, table: rel.name)
                            }
                        }
                    } else {
                        expandedRelations.remove(fullKey)
                    }
                }
            )
        ) {
            relationChildrenView(profile: profile, store: store, database: database, schema: schema, table: rel.name)
                .padding(.leading, 12)
        } label: {
            // Interaction modifiers on the label only — see serverNodeRow.
            HStack {
                Label(rel.name, systemImage: symbol)
                    .foregroundStyle(isConnectedDb ? .primary : .secondary)
                Spacer()
                if let rows = rel.estimatedRows, rows >= 0 {
                    Text(formatRowCount(rows))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectedPostgresProfileId = profile.id
                selectedNodeId = rel.id
                guard let parsed = parsed else { return }
                if isConnectedDb {
                    postOpenTabNotification(
                        profile: profile,
                        node: rel,
                        details: ["kind": "relation", "schema": parsed.schema, "name": parsed.name]
                    )
                } else {
                    presentForeignDatabaseAlert(profile: profile, database: parsed.database)
                }
            }
            .onTapGesture(count: 2) {
                // Double-click = "show me the data now": the single-tap
                // already opened (or reactivated) the browse tab; this
                // re-posts with `autoRun` so the generated SELECT
                // executes immediately. The store dedupes on
                // (schema, table), so no duplicate tab appears.
                guard let parsed = parsed, isConnectedDb else { return }
                postOpenTabNotification(
                    profile: profile,
                    node: rel,
                    details: [
                        "kind": "relation",
                        "schema": parsed.schema,
                        "name": parsed.name,
                        "autoRun": true,
                    ]
                )
            }
            .help(isConnectedDb
                  ? "Click to open a query tab; double-click to run the SELECT immediately"
                  : "Database '\(parsed?.database ?? "?")' isn't connected through this profile.")
            .contextMenu {
                PostgresNodeContextMenu(
                    node: rel,
                    database: database,
                    schema: schema,
                    isConnectedDb: isConnectedDb,
                    post: { postOpenTabNotification(profile: profile, node: rel, details: $0) },
                    refresh: {
                        Task {
                            await store.loadColumns(database: database, schema: schema, table: rel.name)
                            await store.loadMeta(database: database, schema: schema, table: rel.name)
                        }
                    }
                )
            }
            .tag(rel.id)
        }
    }

    @ViewBuilder
    private func relationChildrenView(
        profile: PostgresProfile,
        store: PgSchemaStore,
        database: String,
        schema: String,
        table: String
    ) -> some View {
        let key = "\(database).\(schema).\(table)"

        DisclosureGroup("Columns") {
            switch store.columnsState[key] ?? .idle {
            case .idle, .loading:
                ProgressView().controlSize(.small).padding(.leading, 8)
            case .failed(let err):
                Text("Error: \(err)").foregroundStyle(.red).font(.caption2).padding(.leading, 8)
            case .loaded(let cols):
                if cols.isEmpty {
                    Text("(no columns)").font(.caption2).foregroundStyle(.secondary).padding(.leading, 8)
                } else {
                    ForEach(cols) { col in
                        let isSelected = selectedNode?.id == col.id
                        HStack {
                            Label(col.name, systemImage: "list.bullet")
                            if case .column(let typeName, let notNull) = col.kind {
                                Text(typeName)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                if notNull {
                                    Text("not null")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedNodeId = col.id
                            selectedPostgresProfileId = profile.id
                            postOpenTabNotification(profile: profile, node: col, details: ["kind": "properties"])
                        }
                        .contextMenu {
                            PostgresNodeContextMenu(
                                node: col,
                                database: database,
                                schema: schema,
                                table: table,
                                isConnectedDb: database == profile.database,
                                post: { postOpenTabNotification(profile: profile, node: col, details: $0) }
                            )
                        }
                    }
                }
            }
        }
        .font(.caption)

        switch store.metaState[key] ?? .idle {
        case .idle, .loading:
            ProgressView().controlSize(.small).padding(.leading, 8)
        case .failed(let err):
            Text("Error: \(err)").foregroundStyle(.red).font(.caption2).padding(.leading, 8)
        case .loaded(let metaNodes):
            let keys = metaNodes.filter { if case .key = $0.kind { return true }; return false }
            let constraints = metaNodes.filter { if case .constraint = $0.kind { return true }; return false }
            let triggers = metaNodes.filter { if case .trigger = $0.kind { return true }; return false }

            if !keys.isEmpty {
                DisclosureGroup("Keys (\(keys.count))") {
                    ForEach(keys) { keyNode in
                        let isSelected = selectedNode?.id == keyNode.id
                        HStack {
                            Label(keyNode.name, systemImage: "key.fill")
                                .foregroundStyle(.yellow)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedNodeId = keyNode.id
                            selectedPostgresProfileId = profile.id
                            postOpenTabNotification(profile: profile, node: keyNode, details: ["kind": "properties"])
                        }
                        .contextMenu {
                            PostgresNodeContextMenu(
                                node: keyNode,
                                objectName: bareMetaName(id: keyNode.id, prefix: "key:\(database).\(schema).\(table).") ?? keyNode.name,
                                database: database,
                                schema: schema,
                                table: table,
                                isConnectedDb: database == profile.database,
                                post: { postOpenTabNotification(profile: profile, node: keyNode, details: $0) }
                            )
                        }
                    }
                }
                .font(.caption)
            }

            if !constraints.isEmpty {
                DisclosureGroup("Constraints (\(constraints.count))") {
                    ForEach(constraints) { constNode in
                        let isSelected = selectedNode?.id == constNode.id
                        HStack {
                            Label(constNode.name, systemImage: "lock.shield")
                                .foregroundStyle(.orange)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedNodeId = constNode.id
                            selectedPostgresProfileId = profile.id
                            postOpenTabNotification(profile: profile, node: constNode, details: ["kind": "properties"])
                        }
                        .contextMenu {
                            PostgresNodeContextMenu(
                                node: constNode,
                                objectName: bareMetaName(id: constNode.id, prefix: "const:\(database).\(schema).\(table).") ?? constNode.name,
                                database: database,
                                schema: schema,
                                table: table,
                                isConnectedDb: database == profile.database,
                                post: { postOpenTabNotification(profile: profile, node: constNode, details: $0) }
                            )
                        }
                    }
                }
                .font(.caption)
            }

            if !triggers.isEmpty {
                DisclosureGroup("Triggers (\(triggers.count))") {
                    ForEach(triggers) { trigNode in
                        let isSelected = selectedNode?.id == trigNode.id
                        HStack {
                            Label(trigNode.name, systemImage: "bolt.fill")
                                .foregroundStyle(.cyan)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedNodeId = trigNode.id
                            selectedPostgresProfileId = profile.id
                            postOpenTabNotification(profile: profile, node: trigNode, details: ["kind": "properties"])
                        }
                        .contextMenu {
                            PostgresNodeContextMenu(
                                node: trigNode,
                                database: database,
                                schema: schema,
                                table: table,
                                isConnectedDb: database == profile.database,
                                post: { postOpenTabNotification(profile: profile, node: trigNode, details: $0) }
                            )
                        }
                    }
                }
                .font(.caption)
            }
        }
    }
}
