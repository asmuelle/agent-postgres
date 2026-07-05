import PgAgentMacOS
import SwiftUI

// =============================================================================
// PostgresQueryTabView transposed view — flips wide rows into a
// vertical column/value details panel with per-field inline editing.
//
// Extracted from PostgresQueryTabView.swift; behavior-preserving.
// =============================================================================

extension PostgresQueryTabView {
    @ViewBuilder
    func transposedView(result: FfiPgExecutionResult, tab: PostgresQueryTab) -> some View {
        let visibleColumns = result.columns.enumerated().filter { !$0.element.name.hasPrefix("__pg_") }
        let totalRows = result.rows.count

        VStack(spacing: 0) {
            // Record Selector / Navigation bar
            HStack {
                Button {
                    if selectedTransposedRowIndex > 0 {
                        selectedTransposedRowIndex -= 1
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(selectedTransposedRowIndex <= 0)

                Text("Record \(selectedTransposedRowIndex + 1) of \(totalRows)")
                    .font(.headline)
                    .padding(.horizontal, 8)

                Button {
                    if selectedTransposedRowIndex < totalRows - 1 {
                        selectedTransposedRowIndex += 1
                    }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(selectedTransposedRowIndex >= totalRows - 1)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if totalRows == 0 {
                VStack(spacing: 8) {
                    Image(systemName: "table")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No records to display")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let rowIndex = min(selectedTransposedRowIndex, totalRows - 1)
                let row = result.rows[rowIndex]
                let canEdit = tab.editTarget != nil
                    && result.columns.contains(where: { $0.name == POSTGRES_ROWID_COLUMN })
                let rowIdVal = result.columns.firstIndex(where: { $0.name == POSTGRES_ROWID_COLUMN })
                    .flatMap { colIdx -> String? in
                        guard colIdx < row.cells.count else { return nil }
                        return row.cells[colIdx]
                    }

                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleColumns, id: \.offset) { colIdx, column in
                            let cellKey = PostgresPendingEditKey(rowIndex: rowIndex, columnIndex: colIdx)
                            let isStaged = tab.pendingEdits[cellKey] != nil
                            let originalValue = row.cells[colIdx]
                            let currentValue = isStaged ? tab.pendingEdits[cellKey]?.newValue : originalValue

                            TransposedRowField(
                                columnName: column.name,
                                columnType: column.typeName,
                                originalValue: originalValue,
                                currentValue: currentValue,
                                isStaged: isStaged,
                                editable: canEdit,
                                onSave: { newValue in
                                    guard canEdit, let rowId = rowIdVal else { return }
                                    let edit = PostgresCellEdit(
                                        rowIndex: rowIndex,
                                        columnIndex: colIdx,
                                        columnName: column.name,
                                        columnType: column.typeName,
                                        newValue: newValue,
                                        rowId: rowId
                                    )
                                    runCellUpdate(edit: edit, tab: tab) { outcome in
                                        // Cell updates will automatically be reflected in the tab's pending edits & cell value!
                                    }
                                }
                            )
                        }
                    }
                    .padding(16)
                }
                .background(Color(NSColor.textBackgroundColor))
            }
        }
    }
}

struct TransposedRowField: View {
    let columnName: String
    let columnType: String
    let originalValue: String?
    let currentValue: String?
    let isStaged: Bool
    let editable: Bool
    let onSave: (String?) -> Void

    @State private var isEditing: Bool = false
    @State private var editValue: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Column Name & Type
            VStack(alignment: .leading, spacing: 2) {
                Text(columnName)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                Text(columnType)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(width: 180, alignment: .leading)
            .padding(.vertical, 4)

            // Cell Value / Editor
            Group {
                if isEditing {
                    HStack(spacing: 8) {
                        TextField("", text: $editValue, onCommit: {
                            isEditing = false
                            if editValue == "NULL" {
                                onSave(nil)
                            } else {
                                onSave(editValue)
                            }
                        })
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(6)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.blue, lineWidth: 1)
                        )

                        Button("Set NULL") {
                            isEditing = false
                            onSave(nil)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)

                        Button("Cancel") {
                            isEditing = false
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                } else {
                    HStack {
                        if let currentValue {
                            Text(currentValue)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(isStaged ? .blue : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    if editable {
                                        editValue = currentValue
                                        isEditing = true
                                    }
                                }
                        } else {
                            Text("NULL")
                                .font(.system(.body, design: .monospaced).italic())
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    if editable {
                                        editValue = ""
                                        isEditing = true
                                    }
                                }
                        }

                        if editable {
                            Image(systemName: "pencil")
                                .foregroundColor(.secondary.opacity(0.5))
                                .font(.caption)
                                .padding(.trailing, 4)
                        }
                    }
                    .padding(6)
                    .background(
                        isStaged ? Color.blue.opacity(0.08) :
                        (currentValue == nil ? Color.orange.opacity(0.05) : Color.clear)
                    )
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(
                                isStaged ? Color.blue.opacity(0.3) :
                                (currentValue == nil ? Color.orange.opacity(0.2) : Color.gray.opacity(0.15)),
                                lineWidth: 1
                            )
                    )
                }
            }
        }
        .padding(.vertical, 4)
        .overlay(
            Rectangle()
                .fill(Color(NSColor.gridColor).opacity(0.5))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}
