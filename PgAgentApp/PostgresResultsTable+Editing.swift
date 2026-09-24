import AppKit
import PgAgentMacOS

// =============================================================================
// PostgresResultsTable.Coordinator — cell editing: double-click inline
// edits (NSTextFieldDelegate), Set-to-NULL, and the bulk
// paste/NULL-to-selection pipelines with their sequential drain loops.
//
// Extracted from PostgresResultsTable.swift; behavior-preserving.
// =============================================================================

extension PostgresResultsTable.Coordinator {
    // MARK: - Editing entry points

    /// `doubleAction` handler. Enters the field editor for the
    /// clicked cell when the table is editable AND the row has
    /// a recoverable identity (a `__pg_rowid__` value).
    @objc func handleDoubleClick(_ sender: NSTableView) {
        // Editing assumes table row == data row; disabled while sorted /
        // filtered (clear the sort/filter to edit). See `isReordered`.
        guard editable, !isReordered else { return }
        let row = sender.clickedRow
        let col = sender.clickedColumn
        guard row >= 0, col >= 0, col < sender.tableColumns.count else { return }
        let column = sender.tableColumns[col]
        guard let resultColIdx = columnIndex(from: column.identifier),
              resultColIdx < result.columns.count
        else { return }
        // Block edits on hidden columns (defensive — they're not
        // in tableColumns, so this branch shouldn't fire).
        if isHiddenColumn(resultColIdx) { return }
        // Block edits when the column has no type info — the
        // server-side cast can't synthesize the right type.
        if result.columns[resultColIdx].typeName.isEmpty { return }
        // Block edits when the row has no rowid (multi-statement
        // result, or the user edited away the auto-generated SQL).
        if rowId(forRow: row) == nil { return }

        // Make the cell editable + activate the field editor.
        // `editColumn(_:row:with:select:)` opens the editor and
        // selects the existing text so typing replaces.
        if let cellView = sender.view(
            atColumn: col, row: row, makeIfNecessary: false
        ) as? NSTableCellView {
            cellView.textField?.isEditable = true
            cellView.textField?.isSelectable = true
        }
        sender.editColumn(col, row: row, with: nil, select: true)
    }

    /// Right-click → "Set to NULL". Bypasses the inline editor and
    /// commits a NULL write directly. Only enabled when the table
    /// is editable and the clicked cell is on a real column.
    @objc func setClickedCellToNull(_ sender: Any?) {
        guard editable, !isReordered, let table = lastTable,
              table.clickedRow >= 0, table.clickedColumn >= 0,
              table.clickedRow < result.rows.count
        else { return }
        let column = table.tableColumns[table.clickedColumn]
        guard let resultColIdx = columnIndex(from: column.identifier),
              resultColIdx < result.columns.count,
              !isHiddenColumn(resultColIdx),
              !result.columns[resultColIdx].typeName.isEmpty,
              let rowId = rowId(forRow: table.clickedRow)
        else { return }
        commitEdit(
            rowIndex: table.clickedRow,
            columnIndex: resultColIdx,
            newValue: nil,
            original: cellValue(row: table.clickedRow, column: resultColIdx),
            rowId: rowId
        )
    }

    /// Right-click → "Set selected rows in this column to NULL".
    /// Applies NULL to every selected row at the clicked column.
    @objc func setSelectionInColumnToNull(_ sender: Any?) {
        applyToSelection(in: clickedColumnDescriptor(), value: nil)
    }

    /// Right-click → "Paste into selected rows in this column".
    ///
    /// Two shapes:
    ///   - Single value (no embedded newlines) → broadcast to
    ///     every selected row.
    ///   - Multi-row (newline-separated) → distribute one value
    ///     per selected row, in order. Counts must match (or
    ///     differ by exactly 1 from a trailing newline).
    ///
    /// Tab-separated multi-column pastes aren't handled in v1
    /// — single-column distribution covers the dominant
    /// "fill from a copied column" use case without ambiguity.
    @objc func pasteIntoSelectionInColumn(_ sender: Any?) {
        guard let raw = NSPasteboard.general.string(forType: .string) else {
            presentAlert(title: "Clipboard is empty", message: "Copy a value before pasting.")
            return
        }
        guard let descriptor = clickedColumnDescriptor(),
              let table = lastTable
        else { return }
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else {
            presentAlert(
                title: "No rows selected",
                message: "Select one or more rows, then try again."
            )
            return
        }

        // Strip a single trailing newline (terminal copy, file
        // tail, etc.) but keep internal newlines as separators.
        var trimmed = raw
        if trimmed.hasSuffix("\r\n") {
            trimmed.removeLast(2)
        } else if trimmed.hasSuffix("\n") || trimmed.hasSuffix("\r") {
            trimmed.removeLast()
        }

        // Detect shape. Lines split on \n or \r\n; we don't
        // collapse blanks because empty cells are meaningful.
        let lines = trimmed.components(separatedBy: .newlines)
        // Also reject tab-shaped multi-column pastes — shape
        // ambiguity isn't worth guessing on.
        if lines.contains(where: { $0.contains("\t") }) {
            presentAlert(
                title: "Multi-column paste not supported",
                message: "Tab-separated clipboards aren't handled yet. Copy a single column or single value, then try again."
            )
            return
        }

        if lines.count <= 1 {
            // Single value — broadcast.
            applyToSelection(in: descriptor, value: trimmed)
            return
        }

        // Multi-row → 1:1 distribute. Selected rows come back
        // sorted ascending; pair line[i] → row[i]. Count
        // mismatches confuse more than they help, so reject.
        let selectedRows = Array(rows)
        if lines.count != selectedRows.count {
            presentAlert(
                title: "Shape mismatch",
                message: "Clipboard has \(lines.count) rows but \(selectedRows.count) row\(selectedRows.count == 1 ? " is" : "s are") selected."
            )
            return
        }
        applyDistributedToSelection(
            descriptor: descriptor,
            values: lines,
            rows: selectedRows
        )
    }

    // MARK: - Bulk apply loops

    /// Multi-row paste: each line goes to one selected row. The
    /// loop drains sequentially with the same conflict semantics
    /// as `applyToSelectionLoop`.
    private func applyDistributedToSelection(
        descriptor: (resultIdx: Int, name: String, type: String),
        values: [String],
        rows: [Int]
    ) {
        guard values.count == rows.count, let table = lastTable, let onCellEdit else { return }
        let layout = rowLayoutKey
        var work: [(rowIndex: Int, rowId: String, value: String)] = []
        for (idx, row) in rows.enumerated() {
            guard row < result.rows.count, let rid = rowId(forRow: row) else { continue }
            work.append((row, rid, values[idx]))
        }
        guard !work.isEmpty else { return }
        distributedLoop(
            descriptor: descriptor,
            work: work,
            index: 0,
            successCount: 0,
            conflictCount: 0,
            onCellEdit: onCellEdit,
            table: table,
            layout: layout
        )
    }

    private func distributedLoop(
        descriptor: (resultIdx: Int, name: String, type: String),
        work: [(rowIndex: Int, rowId: String, value: String)],
        index: Int,
        successCount: Int,
        conflictCount: Int,
        onCellEdit: @escaping (PostgresCellEdit, @escaping (PostgresCellEditOutcome) -> Void) -> Void,
        table: NSTableView,
        layout: RowLayoutKey
    ) {
        guard index < work.count else {
            if conflictCount > 0 {
                presentAlert(
                    title: "\(successCount) row(s) updated, \(conflictCount) skipped",
                    message: "Some rows had moved or been deleted by another session."
                )
            }
            return
        }
        // Each step is async: the result may have been re-run, paged, or
        // had rows deleted since the work list was built. Stop rather than
        // index into rows that no longer mean what they did.
        let item = work[index]
        guard stillAddressable(layout: layout, row: item.rowIndex, column: descriptor.resultIdx) else {
            presentLayoutChangedAlert(updated: successCount, remaining: work.count - index)
            return
        }
        let edit = PostgresCellEdit(
            rowIndex: item.rowIndex,
            columnIndex: descriptor.resultIdx,
            columnName: descriptor.name,
            columnType: descriptor.type,
            newValue: item.value,
            rowId: item.rowId,
            rowLayout: layout.rowLayout
        )
        let original = result.rows[item.rowIndex].cells[descriptor.resultIdx]
        onCellEdit(edit) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .applied:
                    self.applyEditOutcome(
                        edit: edit,
                        outcome: .applied,
                        previousValue: original,
                        layout: layout
                    )
                    self.distributedLoop(
                        descriptor: descriptor,
                        work: work,
                        index: index + 1,
                        successCount: successCount + 1,
                        conflictCount: conflictCount,
                        onCellEdit: onCellEdit,
                        table: table,
                        layout: layout
                    )
                case .conflict:
                    self.reloadRow(item.rowIndex, layout: layout)
                    self.distributedLoop(
                        descriptor: descriptor,
                        work: work,
                        index: index + 1,
                        successCount: successCount,
                        conflictCount: conflictCount + 1,
                        onCellEdit: onCellEdit,
                        table: table,
                        layout: layout
                    )
                case .failed(let message):
                    self.presentAlert(
                        title: "Update failed after \(successCount) row(s)",
                        message: message
                    )
                    self.reloadRow(item.rowIndex, layout: layout)
                }
            }
        }
    }

    /// Resolve the currently-clicked column to a `(name, type, idx)`
    /// triple — or `nil` if no editable column was clicked.
    private func clickedColumnDescriptor() -> (resultIdx: Int, name: String, type: String)? {
        guard editable, !isReordered,
              let table = lastTable,
              table.clickedColumn >= 0,
              table.clickedColumn < table.tableColumns.count
        else { return nil }
        let column = table.tableColumns[table.clickedColumn]
        guard let resultColIdx = columnIndex(from: column.identifier),
              resultColIdx < result.columns.count,
              !isHiddenColumn(resultColIdx),
              !result.columns[resultColIdx].typeName.isEmpty
        else { return nil }
        return (
            resultColIdx,
            result.columns[resultColIdx].name,
            result.columns[resultColIdx].typeName
        )
    }

    /// Run the same UPDATE on every currently-selected row at the
    /// given column. Errors and conflicts surface once per row;
    /// rather than batch-alert, the first failure stops the rest
    /// — saves the user from clicking through 50 dialogs.
    private func applyToSelection(
        in descriptor: (resultIdx: Int, name: String, type: String)?,
        value: String?
    ) {
        guard let descriptor, let table = lastTable, let onCellEdit else { return }
        let layout = rowLayoutKey
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else {
            presentAlert(
                title: "No rows selected",
                message: "Select one or more rows, then try again."
            )
            return
        }

        // Build the work list up front so changing selection
        // mid-update can't trip us up.
        var work: [(rowIndex: Int, rowId: String)] = []
        for row in rows {
            guard let rid = rowId(forRow: row) else { continue }
            work.append((row, rid))
        }
        guard !work.isEmpty else {
            presentAlert(
                title: "Nothing editable",
                message: "Selected rows don't carry a row identifier."
            )
            return
        }
        applyToSelectionLoop(
            descriptor: descriptor,
            value: value,
            work: work,
            index: 0,
            successCount: 0,
            conflictCount: 0,
            onCellEdit: onCellEdit,
            layout: layout
        )
    }

    /// Recursive helper that drains the work list one row at a
    /// time. Loop is async via the `onCellEdit` callback so we
    /// don't block the main queue; first error halts the rest.
    private func applyToSelectionLoop(
        descriptor: (resultIdx: Int, name: String, type: String),
        value: String?,
        work: [(rowIndex: Int, rowId: String)],
        index: Int,
        successCount: Int,
        conflictCount: Int,
        onCellEdit: @escaping (PostgresCellEdit, @escaping (PostgresCellEditOutcome) -> Void) -> Void,
        layout: RowLayoutKey
    ) {
        guard index < work.count else {
            if conflictCount > 0 {
                presentAlert(
                    title: "\(successCount) row(s) updated, \(conflictCount) skipped",
                    message: "Some rows had moved or been deleted by another session. Re-run the query for fresh data."
                )
            }
            return
        }
        let item = work[index]
        // See `distributedLoop`: stop if the rows moved under the loop.
        guard stillAddressable(layout: layout, row: item.rowIndex, column: descriptor.resultIdx) else {
            presentLayoutChangedAlert(updated: successCount, remaining: work.count - index)
            return
        }
        let edit = PostgresCellEdit(
            rowIndex: item.rowIndex,
            columnIndex: descriptor.resultIdx,
            columnName: descriptor.name,
            columnType: descriptor.type,
            newValue: value,
            rowId: item.rowId,
            rowLayout: layout.rowLayout
        )
        let original = result.rows[item.rowIndex].cells[descriptor.resultIdx]
        onCellEdit(edit) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .applied:
                    self.applyEditOutcome(
                        edit: edit,
                        outcome: .applied,
                        previousValue: original,
                        layout: layout
                    )
                    self.applyToSelectionLoop(
                        descriptor: descriptor,
                        value: value,
                        work: work,
                        index: index + 1,
                        successCount: successCount + 1,
                        conflictCount: conflictCount,
                        onCellEdit: onCellEdit,
                        layout: layout
                    )
                case .conflict:
                    // Swallow per-row conflicts; we'll summarize
                    // at the end. Reload that row to revert
                    // visually.
                    self.reloadRow(item.rowIndex, layout: layout)
                    self.applyToSelectionLoop(
                        descriptor: descriptor,
                        value: value,
                        work: work,
                        index: index + 1,
                        successCount: successCount,
                        conflictCount: conflictCount + 1,
                        onCellEdit: onCellEdit,
                        layout: layout
                    )
                case .failed(let message):
                    // First hard failure stops the run — show
                    // the partial summary alongside the error.
                    self.presentAlert(
                        title: "Update failed after \(successCount) row(s)",
                        message: message
                    )
                    self.reloadRow(item.rowIndex, layout: layout)
                }
            }
        }
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
        guard editable, !isReordered,
              let textField = control as? NSTextField,
              let cellView = textField.superview as? NSTableCellView,
              let table = lastTable
        else { return false }
        let row = table.row(for: cellView)
        let resultColIdx = textField.tag
        guard row >= 0,
              resultColIdx >= 0, resultColIdx < result.columns.count,
              !isHiddenColumn(resultColIdx),
              !result.columns[resultColIdx].typeName.isEmpty,
              let rid = rowId(forRow: row)
        else { return false }

        pendingEdit = PendingEdit(
            rowIndex: row,
            columnIndex: resultColIdx,
            columnName: result.columns[resultColIdx].name,
            columnType: result.columns[resultColIdx].typeName,
            original: textField.stringValue,
            rowId: rid,
            layout: rowLayoutKey
        )
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let pending = pendingEdit else { return }
        pendingEdit = nil
        guard let textField = obj.object as? NSTextField else { return }
        // Always disable editability after the editor closes so a
        // single click on the same cell next time only selects.
        textField.isEditable = false
        textField.isSelectable = false
        // Defensive: if a sort/filter became active while the editor was
        // open, `pending.rowIndex` (a display index captured at open time)
        // no longer maps to its data row — abandon the commit rather than
        // risk writing the wrong row.
        if isReordered {
            textField.stringValue = pending.original
            return
        }
        // Same for a re-run / page change / row delete while the editor was
        // open: the captured row index now names a different row.
        guard pending.layout == rowLayoutKey else {
            textField.stringValue = pending.original
            return
        }

        let movement = (obj.userInfo?["NSTextMovement"] as? Int)
            .flatMap(NSTextMovement.init(rawValue:))
        let cancelled = movement == .cancel
        if cancelled {
            // Esc — restore the original. Next viewFor call will
            // overwrite from result anyway, but keeping the field
            // text consistent for the brief gap is nicer.
            textField.stringValue = pending.original
            return
        }

        let newValue = textField.stringValue
        if newValue == pending.original {
            return // No-op commit.
        }
        commitEdit(
            rowIndex: pending.rowIndex,
            columnIndex: pending.columnIndex,
            newValue: newValue,
            original: pending.original,
            rowId: pending.rowId,
            layout: pending.layout
        )
    }

    // MARK: - Commit + outcome

    /// Build the FFI request, hand it to the host's `onCellEdit`
    /// closure, and apply / revert the table's display based on
    /// the outcome.
    private func commitEdit(
        rowIndex: Int,
        columnIndex: Int,
        newValue: String?,
        original: String?,
        rowId: String,
        layout capturedLayout: RowLayoutKey? = nil
    ) {
        guard let onCellEdit, columnIndex < result.columns.count else { return }
        let layout = capturedLayout ?? rowLayoutKey
        let edit = PostgresCellEdit(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            columnName: result.columns[columnIndex].name,
            columnType: result.columns[columnIndex].typeName,
            newValue: newValue,
            rowId: rowId,
            rowLayout: layout.rowLayout
        )
        onCellEdit(edit) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyEditOutcome(
                    edit: edit,
                    outcome: outcome,
                    previousValue: original,
                    layout: layout
                )
            }
        }
    }

    // MARK: - Row-layout guards

    /// The host's current row-position token plus the result's row count
    /// (a fallback discriminator for hosts that don't supply revisions).
    /// Async edit paths capture it up front and re-check it before every
    /// index-addressed read or write.
    struct RowLayoutKey: Equatable {
        let tabId: UUID?
        let rowLayout: UInt64?
    }

    var rowLayoutKey: RowLayoutKey {
        RowLayoutKey(tabId: lastRevision?.tabId, rowLayout: lastRevision?.rowLayout)
    }

    /// `true` when `layout` is still current and (`row`, `column`) is in
    /// bounds of the current result — i.e. an index captured under
    /// `layout` still addresses the same cell.
    func stillAddressable(layout: RowLayoutKey, row: Int, column: Int) -> Bool {
        guard layout == rowLayoutKey,
              row >= 0, row < result.rows.count,
              column >= 0, column < result.rows[row].cells.count
        else { return false }
        return true
    }

    private func cellValue(row: Int, column: Int) -> String? {
        guard row >= 0, row < result.rows.count,
              column >= 0, column < result.rows[row].cells.count
        else { return nil }
        return result.rows[row].cells[column]
    }

    private func presentLayoutChangedAlert(updated: Int, remaining: Int) {
        presentAlert(
            title: "Stopped after \(updated) row(s)",
            message: "The results changed while the update was running (re-run, page change, or deleted rows), so the remaining \(remaining) row(s) were not written. Re-select the rows and try again."
        )
    }

    private func applyEditOutcome(
        edit: PostgresCellEdit,
        outcome: PostgresCellEditOutcome,
        previousValue: String?,
        layout: RowLayoutKey
    ) {
        // The rows were replaced/shifted while the write was in flight: the
        // table already shows the newer result, and `edit.rowIndex` no
        // longer names the edited row. Only surface failures.
        guard layout == rowLayoutKey else {
            if case .failed(let message) = outcome {
                presentAlert(title: "Update failed", message: message)
            }
            return
        }
        // Update the in-memory result so the next viewFor call
        // shows the right cell. Then trigger a row reload — the
        // host-side store mutation goes through SwiftUI which is
        // eventually consistent, but the immediate reload keeps
        // the table snappy.
        switch outcome {
        case .applied:
            if edit.rowIndex < result.rows.count,
               edit.columnIndex < result.rows[edit.rowIndex].cells.count
            {
                var row = result.rows[edit.rowIndex]
                row.cells[edit.columnIndex] = edit.newValue
                result.rows[edit.rowIndex] = row
            }
            editedRows.insert(edit.rowIndex)
            reloadRow(edit.rowIndex)
        case .conflict:
            presentAlert(
                title: "Row no longer exists",
                message: "Another session updated or deleted this row. Re-run the query to see fresh data."
            )
            reloadRow(edit.rowIndex)
            _ = previousValue // kept the original value; nothing to revert
        case .failed(let message):
            presentAlert(title: "Update failed", message: message)
            reloadRow(edit.rowIndex)
            _ = previousValue
        }
    }

    /// Reload one row, unless the rows moved since `layout` was captured
    /// (then the table was already reloaded wholesale for the new result).
    private func reloadRow(_ rowIndex: Int, layout: RowLayoutKey) {
        guard layout == rowLayoutKey else { return }
        reloadRow(rowIndex)
    }

    private func reloadRow(_ rowIndex: Int) {
        guard let table = lastTable, rowIndex >= 0,
              rowIndex < table.numberOfRows
        else { return }
        let cols = IndexSet(integersIn: 0..<table.tableColumns.count)
        table.reloadData(forRowIndexes: IndexSet(integer: rowIndex), columnIndexes: cols)
    }
}
