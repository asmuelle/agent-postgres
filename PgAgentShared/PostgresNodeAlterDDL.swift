import Foundation

// =============================================================================
// PostgresNodeAlterDDL — the ALTER / RENAME statements behind the Property
// Inspector's editable fields (macOS and iOS share it).
//
// Every identifier goes through `pgQuoteIdent`, and the *old* name always
// comes from `PgNodeID.target(for:)` / `node.name` (the real object name),
// never from a display label — keys and constraints show
// `users_pkey (PRIMARY KEY (id))` in the tree, which must not end up as the
// constraint's new name.
// =============================================================================

enum PostgresNodeAlterDDL {
    /// The editable state of the inspector form.
    struct Edit: Equatable, Sendable {
        var name: String
        /// Column data type (a type expression, emitted verbatim — it may
        /// legitimately contain spaces, parentheses and modifiers).
        var type: String
        var notNull: Bool
    }

    /// Statements that turn `node` into `edit`, `"-- No changes"` when
    /// nothing differs, or a comment for kinds that can't be edited.
    static func statements(for node: PgSchemaNode, edit: Edit) -> String {
        guard let target = PgNodeID.target(for: node) else { return "-- Unknown ID format" }
        let schema = pgQuoteIdent(target.schema)
        let oldName = pgQuoteIdent(target.name)
        let newName = pgQuoteIdent(edit.name)
        let renamed = edit.name != target.name
        let qualifiedTable = target.table.map { "\(schema).\(pgQuoteIdent($0))" }

        func rename(_ sql: String) -> String {
            renamed ? sql : "-- No changes"
        }

        switch node.kind {
        case .column(let typeName, let notNull):
            guard let qualifiedTable else { return "-- Unknown ID format" }
            var sqls: [String] = []
            if renamed {
                sqls.append("ALTER TABLE \(qualifiedTable) RENAME COLUMN \(oldName) TO \(newName);")
            }
            // Later statements address the column by its *new* name.
            if edit.type != typeName {
                sqls.append("ALTER TABLE \(qualifiedTable) ALTER COLUMN \(newName) TYPE \(edit.type);")
            }
            if edit.notNull != notNull {
                let action = edit.notNull ? "SET NOT NULL" : "DROP NOT NULL"
                sqls.append("ALTER TABLE \(qualifiedTable) ALTER COLUMN \(newName) \(action);")
            }
            return sqls.isEmpty ? "-- No changes" : sqls.joined(separator: "\n")
        case .key, .constraint:
            guard let qualifiedTable else { return "-- Unknown ID format" }
            return rename("ALTER TABLE \(qualifiedTable) RENAME CONSTRAINT \(oldName) TO \(newName);")
        case .trigger:
            guard let qualifiedTable else { return "-- Unknown ID format" }
            return rename("ALTER TRIGGER \(oldName) ON \(qualifiedTable) RENAME TO \(newName);")
        case .sequence:
            return rename("ALTER SEQUENCE \(schema).\(oldName) RENAME TO \(newName);")
        case .routine(let kind, let signature, _):
            let keyword: String
            switch kind {
            case .procedure: keyword = "PROCEDURE"
            case .aggregate: keyword = "AGGREGATE"
            case .function, .window: keyword = "FUNCTION"
            }
            // The identity-argument signature pins the exact overload.
            // It normally carries no parentheses of its own; tolerate one
            // that does rather than emitting `f((int))`.
            let trimmed = signature.trimmingCharacters(in: .whitespaces)
            let args = trimmed.hasPrefix("(") && trimmed.hasSuffix(")") ? trimmed : "(\(trimmed))"
            return rename("ALTER \(keyword) \(schema).\(oldName)\(args) RENAME TO \(newName);")
        case .objectType(let kind):
            let keyword = kind == .domain ? "DOMAIN" : "TYPE"
            return rename("ALTER \(keyword) \(schema).\(oldName) RENAME TO \(newName);")
        default:
            return "-- Editing not supported for this element"
        }
    }

    /// The form's starting state for `node`.
    static func initialEdit(for node: PgSchemaNode) -> Edit {
        if case .column(let typeName, let notNull) = node.kind {
            return Edit(name: node.name, type: typeName, notNull: notNull)
        }
        return Edit(name: node.name, type: "", notNull: false)
    }
}
