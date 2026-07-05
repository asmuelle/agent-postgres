import AppKit
import SwiftUI

// =============================================================================
// PostgresCellInspectorView — viewer/editor for a single cell's full value,
// opened from the results grid's "Show value…".
//
// For JSON/JSONB values it offers two modes (remembered across cells):
//   - Tree: expandable nodes with type-tinted values; every node's context
//     menu copies a Postgres extraction expression (`col->'a'->0->>'b'`) and
//     a jsonpath variant (`$.a[0].b`).
//   - Raw: monospaced text. When the host supplies an edit context (json/
//     jsonb column on an editable, non-read-only relation tab), the raw text
//     becomes editable with live validation; Save routes through the same
//     cell-update pipeline as grid edits (read-only enforcement + audit
//     included). Pretty-print / Minify rewrite the buffer in place.
//
// Non-JSON values keep the plain read-only text view.
// =============================================================================

/// Host-supplied editing hook. Present only when the inspected cell is a
/// writable json/jsonb column; `onSave` runs the same commit pipeline as a
/// grid cell edit and reports the outcome back.
struct PostgresCellInspectorEditContext {
    let onSave: (
        _ newValue: String?,
        _ complete: @escaping (PostgresCellEditOutcome) -> Void
    ) -> Void
}

struct PostgresCellInspectorView: View {
    let inspection: PostgresCellInspection
    var editContext: PostgresCellInspectorEditContext? = nil

    @Environment(\.dismiss) private var dismiss
    /// Last-used display mode for JSON values; persists across cells.
    @AppStorage("pgCellInspectorPreferTree") private var preferTree: Bool = true

    /// Editable buffer (raw mode). Seeded from the cell value.
    @State private var text: String = ""
    @State private var isSaving: Bool = false
    /// Save-pipeline error (conflict / server failure), shown inline.
    @State private var saveError: String? = nil

    // MARK: - Derived

    private var isJSONColumn: Bool {
        PostgresColumnAffinity.from(typeOid: inspection.typeOid) == .json
            || inspection.typeName == "json" || inspection.typeName == "jsonb"
    }

    /// Whether the *current buffer* parses as JSON (fragments allowed —
    /// jsonb can hold bare scalars). `nil` error means valid or empty.
    private var validationError: PostgresJSONValidation.Issue? {
        PostgresJSONValidation.validate(text)
    }

    private var isValidJSON: Bool { validationError == nil && !trimmedText.isEmpty }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDirty: Bool { text != (inspection.value ?? "") }

    /// Tree is offered whenever the original value parses as a JSON
    /// container or scalar; tree renders the *saved* value, not the draft.
    private var treeRoot: PostgresJSONTreeNode? {
        guard isJSONColumn || looksLikeJSONContainer(inspection.value) else { return nil }
        guard let value = inspection.value else { return nil }
        return PostgresJSONTree.build(fromJSONText: value)
    }

    private var showsTreeToggle: Bool { treeRoot != nil }
    private var treeActive: Bool { showsTreeToggle && preferTree }
    private var canEdit: Bool { editContext != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if treeActive, let root = treeRoot {
                treeView(root: root)
            } else {
                rawView
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 680, minHeight: 360, idealHeight: 500)
        .onAppear { text = inspection.value ?? "" }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(inspection.columnName).font(.headline)
                if !inspection.typeName.isEmpty {
                    Text(inspection.typeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if showsTreeToggle {
                Picker("", selection: $preferTree) {
                    Text("Tree").tag(true)
                    Text("Raw").tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Tree shows the saved value; edit in Raw mode.")
            }
        }
        .padding(12)
    }

    // MARK: - Tree mode

    @ViewBuilder
    private func treeView(root: PostgresJSONTreeNode) -> some View {
        List([root], children: \.children) { node in
            treeRow(node)
        }
        .listStyle(.inset)
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder
    private func treeRow(_ node: PostgresJSONTreeNode) -> some View {
        HStack(spacing: 6) {
            Text(node.label)
                .font(.system(.body, design: .monospaced).weight(.medium))
            Text(node.valueDisplay)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(valueColor(for: node.kind))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Path (Postgres)") {
                copyToPasteboard(PostgresJSONTree.postgresExpression(
                    column: inspection.columnName,
                    path: node.path,
                    leafIsScalar: !node.isContainer
                ))
            }
            Button("Copy Path (jsonpath)") {
                copyToPasteboard(PostgresJSONTree.jsonpathExpression(path: node.path))
            }
            Divider()
            Button("Copy Value") {
                copyToPasteboard(node.valueDisplay)
            }
        }
        .help("Right-click to copy this node's extraction path")
    }

    private func valueColor(for kind: PostgresJSONTreeNode.Kind) -> Color {
        switch kind {
        case .object, .array: return .secondary
        case .string: return .green
        case .number: return .blue
        case .bool: return .orange
        case .null: return Color(NSColor.tertiaryLabelColor)
        }
    }

    // MARK: - Raw mode

    @ViewBuilder
    private var rawView: some View {
        VStack(spacing: 0) {
            if canEdit {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                validationBar
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(displayOnlyText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color(NSColor.textBackgroundColor))
            }
        }
    }

    /// Read-only display: pretty-print JSON containers like the old
    /// inspector did; otherwise the raw value (or NULL).
    private var displayOnlyText: String {
        guard let value = inspection.value else { return "NULL" }
        if isJSONColumn || looksLikeJSONContainer(value) {
            return PostgresJSONValidation.prettyPrinted(value) ?? value
        }
        return value
    }

    @ViewBuilder
    private var validationBar: some View {
        HStack(spacing: 8) {
            if trimmedText.isEmpty {
                Label("Empty — type a JSON value (or cancel)", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let issue = validationError {
                Label(issue.message, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(issue.message)
                if let position = issue.characterIndex {
                    Text("at character \(position)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Valid JSON", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let saveError {
                Divider().frame(height: 12)
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(saveError)
            }
            Spacer()
            Button("Pretty-print") { reformat(pretty: true) }
                .controlSize(.small)
                .disabled(!isValidJSON)
            Button("Minify") { reformat(pretty: false) }
                .controlSize(.small)
                .disabled(!isValidJSON)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
    }

    private func reformat(pretty: Bool) {
        let formatted = pretty
            ? PostgresJSONValidation.prettyPrinted(text)
            : PostgresJSONValidation.minified(text)
        if let formatted { text = formatted }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(inspection.value.map { "\($0.count) characters" } ?? "SQL NULL")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if isSaving {
                ProgressView().controlSize(.small)
            }
            Button("Copy") {
                copyToPasteboard(treeActive ? displayOnlyText : text)
            }
            if canEdit {
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    // Save needs a valid draft, an actual change, and raw
                    // mode (tree renders the saved value, not the draft).
                    .disabled(treeActive || !isValidJSON || !isDirty || isSaving)
                    .help("Write the edited JSON back to the row (⌘S)")
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func save() {
        guard let editContext, isValidJSON, !isSaving else { return }
        isSaving = true
        saveError = nil
        editContext.onSave(text) { outcome in
            isSaving = false
            switch outcome {
            case .applied:
                dismiss()
            case .conflict:
                saveError = "Row was modified or deleted by another session."
            case .failed(let message):
                saveError = message
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Heuristic used for non-json-typed columns (e.g. text holding JSON):
    /// only object/array shapes count, so a plain `123` in a text column
    /// isn't mistaken for JSON — same rule as the old inspector.
    private func looksLikeJSONContainer(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }
        guard let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}

// =============================================================================
// PostgresJSONValidation — parse/format helpers for the raw editor.
// =============================================================================

enum PostgresJSONValidation {
    struct Issue {
        let message: String
        /// 0-based character index extracted from NSJSONSerialization's
        /// error description, when it reports one.
        let characterIndex: Int?
    }

    /// `nil` when `text` is valid JSON (fragments allowed) or blank.
    static func validate(_ text: String) -> Issue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = text.data(using: .utf8) else {
            return Issue(message: "Text is not valid UTF-8", characterIndex: nil)
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return nil
        } catch {
            let ns = error as NSError
            let description = (ns.userInfo[NSDebugDescriptionErrorKey] as? String)
                ?? ns.localizedDescription
            return Issue(
                message: description,
                characterIndex: characterIndex(fromJSONErrorDescription: description)
            )
        }
    }

    /// NSJSONSerialization reports positions like "… around character 42."
    /// (or "around line 2, column 7" on newer OSes — in that case we skip
    /// the index and let the message speak).
    static func characterIndex(fromJSONErrorDescription description: String) -> Int? {
        guard let range = description.range(of: "character ") else { return nil }
        let digits = description[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    static func prettyPrinted(_ text: String) -> String? {
        reserialize(text, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func minified(_ text: String) -> String? {
        reserialize(text, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func reserialize(
        _ text: String,
        options: JSONSerialization.WritingOptions
    ) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                  with: data, options: [.fragmentsAllowed]
              ),
              let output = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: options.union([.fragmentsAllowed])
              )
        else { return nil }
        return String(data: output, encoding: .utf8)
    }
}
