import AppKit
import PgAgentMacOS
import SwiftUI

// =============================================================================
// PostgresResultsTable.Coordinator — the NSTableView data source /
// delegate core: state, display-order (filter + local sort), column
// building, cell rendering, and header-sort handling.
//
// Companion extensions:
//   - PostgresResultsTable+CopyExport.swift — copy / CSV export actions
//   - PostgresResultsTable+Editing.swift    — inline + bulk cell editing
//   - PostgresResultsTable+Menu.swift       — menu validation + FK items
//
// Extracted from PostgresResultsTable.swift; behavior-preserving.
// =============================================================================

extension PostgresResultsTable {
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                             NSMenuDelegate, NSTextFieldDelegate {
        var result: FfiPgExecutionResult
        var editable: Bool
        var onCellEdit: ((PostgresCellEdit, @escaping (PostgresCellEditOutcome) -> Void) -> Void)?
        var onExportFull: (() -> Void)?
        var onExportFullJsonl: (() -> Void)?
        var onExportFullParquet: (() -> Void)?
        var onDeleteRows: (([Int]) -> Void)?
        var onInsertRow: (() -> Void)?
        var onInspectCell: ((PostgresCellInspection) -> Void)?
        var widthPersistKey: PostgresColumnWidthKey?
        var pendingEdits: [PostgresPendingEditKey: PostgresPendingEdit] = [:]
        var foreignKeys: PgTableForeignKeys?
        var onNavigateFK: ((PostgresFKNavigation) -> Void)?
        /// Host-supplied rows-change token seen by the last
        /// `updateNSView` pass. Compared against the incoming value
        /// to decide whether same-shaped rows need a reload without
        /// deep-equating the row arrays.
        var lastRevision: PostgresResultsRevision?
        /// Menu items added by the last `rebuildFKItems` pass, so the
        /// next pass can strip them before rebuilding for the newly
        /// clicked cell.
        var fkMenuItems: [NSMenuItem] = []
        /// Navigation payloads behind `fkMenuItems`; each item's
        /// `tag` indexes into this array.
        var fkNavigationTargets: [PostgresFKNavigation] = []
        /// When true, NULLs render as empty strings in the clipboard
        /// (still shown as "NULL" italic in the UI). Useful for
        /// pasting into spreadsheets that treat the literal "NULL" as
        /// text. Persisted only for the lifetime of the view.
        var nullAsEmptyInCopy: Bool = false

        /// Result-row indices the user has touched (successful
        /// commit) since the result was last replaced. The grid
        /// renders a thin accent stripe on these rows so the user
        /// can see at a glance what they've changed in this view.
        /// Cleared on `update(result:)` since a fresh result drops
        /// any meaningful row identity.
        var editedRows: Set<Int> = []

        // MARK: - Sort + filter (display order)

        /// Result-column index the grid is sorted by, or `nil` for none.
        private var sortColumnIndex: Int?
        private var sortAscending: Bool = true
        /// Offset added to the 1-based "#" gutter values (browse
        /// paging passes `page * pageSize`).
        var rowNumberBase: Int = 0
        /// Server-side sort the host applied (browse mode). Display
        /// only — drives header indicators, never `displayOrder`.
        var serverSort: PostgresServerSort?
        /// Set by browse-mode hosts: header clicks delegate here
        /// (the host re-runs the SELECT with ORDER BY) instead of
        /// sorting the fetched page locally.
        var onHeaderSort: ((String) -> Void)?
        /// Case-insensitive substring filter across visible columns. Set by the
        /// host's filter field through `PostgresResultsTable`.
        var filterText: String = ""
        /// Data-row indices in display order (after filter + sort). Identity
        /// (`0..<rows.count`) when not reordered, so the read paths stay uniform.
        private(set) var displayOrder: [Int] = []

        /// `true` when a *local* sort or filter is active. Cell editing is
        /// disabled while reordered: the destructive ctid edit/delete paths
        /// assume table row == data row, so a wrong display mapping there
        /// could corrupt the wrong row. With editing gated, a mapping bug can
        /// only mis-render/mis-copy.
        ///
        /// Server-side sort (`serverSort`/`onHeaderSort`, browse mode) is
        /// deliberately NOT included: the host re-runs the SELECT with ORDER
        /// BY, so the rows arrive already ordered, `displayOrder` stays
        /// identity, and the table-row == data-row invariant holds. That is
        /// what keeps editing available on sorted browse tabs. Any future
        /// edit path doing positional arithmetic (rather than ctid lookup)
        /// must preserve that invariant or extend this gate.
        var isReordered: Bool {
            sortColumnIndex != nil
                || !filterText.trimmingCharacters(in: .whitespaces).isEmpty
        }

        /// Map a table (display) row to its data-row index, or `nil` if invalid.
        func dataRow(_ displayRow: Int) -> Int? {
            guard displayRow >= 0, displayRow < displayOrder.count else { return nil }
            return displayOrder[displayRow]
        }

        /// Rebuild `displayOrder` from the current rows, applying the active
        /// filter (case-insensitive substring across visible columns) then sort.
        func recomputeDisplayOrder() {
            let needle = filterText.trimmingCharacters(in: .whitespaces).lowercased()
            let visibleCols = (0..<result.columns.count).filter { !isHiddenColumn($0) }
            var indices: [Int]
            if needle.isEmpty {
                indices = Array(0..<result.rows.count)
            } else {
                indices = (0..<result.rows.count).filter { r in
                    let cells = result.rows[r].cells
                    return visibleCols.contains { ci in
                        ci < cells.count && (cells[ci]?.lowercased().contains(needle) ?? false)
                    }
                }
            }
            if let sortColumn = sortColumnIndex, sortColumn < result.columns.count {
                indices.sort { a, b in
                    let va = sortColumn < result.rows[a].cells.count ? result.rows[a].cells[sortColumn] : nil
                    let vb = sortColumn < result.rows[b].cells.count ? result.rows[b].cells[sortColumn] : nil
                    let order = Self.compareCells(va, vb)
                    return sortAscending ? (order == .orderedAscending) : (order == .orderedDescending)
                }
            }
            displayOrder = indices
        }

        /// NULLs sort as largest (Postgres default); non-nulls use a locale- and
        /// numeric-aware comparison so `img9` precedes `img10`.
        static func compareCells(_ a: String?, _ b: String?) -> ComparisonResult {
            switch (a, b) {
            case (nil, nil): return .orderedSame
            case (nil, _): return .orderedDescending
            case (_, nil): return .orderedAscending
            case let (.some(x), .some(y)): return x.localizedStandardCompare(y)
            }
        }

        /// Edit context captured before the field editor opens.
        /// Consumed in `controlTextDidEndEditing`.
        struct PendingEdit {
            let rowIndex: Int
            let columnIndex: Int
            let columnName: String
            let columnType: String
            let original: String
            let rowId: String
        }
        var pendingEdit: PendingEdit?

        init(
            result: FfiPgExecutionResult,
            editable: Bool,
            onCellEdit: ((PostgresCellEdit, @escaping (PostgresCellEditOutcome) -> Void) -> Void)?,
            onExportFull: (() -> Void)?,
            onExportFullJsonl: (() -> Void)?,
            onExportFullParquet: (() -> Void)?,
            onDeleteRows: (([Int]) -> Void)?,
            onInsertRow: (() -> Void)?,
            widthPersistKey: PostgresColumnWidthKey?
        ) {
            self.result = result
            self.editable = editable
            self.onCellEdit = onCellEdit
            self.onExportFull = onExportFull
            self.onExportFullJsonl = onExportFullJsonl
            self.onExportFullParquet = onExportFullParquet
            self.onDeleteRows = onDeleteRows
            self.onInsertRow = onInsertRow
            self.widthPersistKey = widthPersistKey
            super.init()
            recomputeDisplayOrder()
        }

        func update(result: FfiPgExecutionResult) {
            // A fresh result invalidates the edited-rows set —
            // indices no longer refer to the same logical rows.
            // Pagination append keeps existing indices valid (rows
            // only grow at the end), so we only reset on column
            // changes.
            let columnsChanged = result.columns.count != self.result.columns.count
                || zip(result.columns, self.result.columns).contains { $0.name != $1.name }
            if columnsChanged {
                editedRows.removeAll()
                // A new shape invalidates the sort column index; drop the sort.
                sortColumnIndex = nil
            }
            self.result = result
            recomputeDisplayOrder()
        }

        // MARK: - Hidden columns

        /// `true` when the column at `index` in `result.columns` is
        /// internal (e.g. the `__pg_rowid__` column carrying ctid).
        /// Internal columns are kept in the model but never shown.
        func isHiddenColumn(_ index: Int) -> Bool {
            guard index < result.columns.count else { return true }
            return result.columns[index].name.hasPrefix("__pg_")
        }

        /// Locate the `__pg_rowid__` column in the result, if present.
        /// Returns its index in `result.columns`. The grid uses this
        /// to extract the ctid for cell-level UPDATE.
        private func rowidColumnIndex() -> Int? {
            result.columns.firstIndex { $0.name == "__pg_rowid__" }
        }

        /// Read the rowid (ctid) for `rowIndex`, or `nil` if the
        /// result lacks a rowid column.
        func rowId(forRow rowIndex: Int) -> String? {
            guard let colIdx = rowidColumnIndex(),
                  rowIndex < result.rows.count,
                  colIdx < result.rows[rowIndex].cells.count
            else { return nil }
            return result.rows[rowIndex].cells[colIdx]
        }

        // MARK: - Columns

        /// Identifier of the synthetic row-number gutter column. It
        /// deliberately fails `columnIndex(from:)` (no numeric
        /// suffix), so every data-mapping path — copy, export, edit,
        /// sort, width persistence — skips it without special cases.
        static let rowNumberColumnId = NSUserInterfaceItemIdentifier("rownum")

        func rebuildColumns(in table: NSTableView, from columns: [FfiPgColumn]) {
            for col in table.tableColumns {
                table.removeTableColumn(col)
            }
            let rowNum = NSTableColumn(identifier: Self.rowNumberColumnId)
            rowNum.title = "#"
            rowNum.headerCell.alignment = .right
            rowNum.width = 52
            rowNum.minWidth = 36
            rowNum.maxWidth = 90
            rowNum.resizingMask = [.userResizingMask]
            table.addTableColumn(rowNum)
            for (idx, c) in columns.enumerated() {
                // Skip internal columns (e.g. `__pg_rowid__` that
                // carries ctid for cell-level UPDATEs). They stay in
                // the result model but never show in the grid; the
                // identifier preserves the result-side index so
                // selection / click handlers map back correctly.
                if c.name.hasPrefix("__pg_") { continue }
                let affinity = PostgresColumnAffinity.from(column: c)
                let col = NSTableColumn(
                    identifier: NSUserInterfaceItemIdentifier(rawValue: "col-\(idx)")
                )
                col.title = c.name
                col.headerCell.alignment = affinity.headerAlignment
                col.headerToolTip = c.typeName.isEmpty
                    ? nil
                    : "type: \(c.typeName)"
                // Restore the user's saved width if we have a key
                // for this column; otherwise fall back to the
                // affinity-driven default.
                if let key = widthPersistKey,
                   let saved = PostgresColumnWidthStore.shared.width(
                    forProfile: key.profileId,
                    schema: key.schema,
                    table: key.table,
                    column: c.name
                   )
                {
                    col.width = CGFloat(saved)
                } else {
                    col.width = affinity.defaultWidth
                }
                col.minWidth = 40
                col.maxWidth = 1200
                col.resizingMask = [.userResizingMask]
                table.addTableColumn(col)
            }
            updateSortIndicators(in: table)
        }

        // Triggered after the user drags a column edge. Persist when
        // we have a key.
        @objc func columnDidResize(_ notification: Notification) {
            guard let key = widthPersistKey,
                  let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  let resultIdx = columnIndex(from: column.identifier),
                  resultIdx < result.columns.count
            else { return }
            let columnName = result.columns[resultIdx].name
            PostgresColumnWidthStore.shared.setWidth(
                Double(column.width),
                forProfile: key.profileId,
                schema: key.schema,
                table: key.table,
                column: columnName
            )
        }

        // MARK: - NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            displayOrder.count
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier(rawValue: "pg-row")
            let view: PostgresEditedRowView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? PostgresEditedRowView {
                view = reused
            } else {
                view = PostgresEditedRowView()
                view.identifier = id
            }
            let dr = dataRow(row)
            let hasStaged = dr.map { d in pendingEdits.keys.contains { $0.rowIndex == d } } ?? false
            view.isEdited = dr.map { editedRows.contains($0) } ?? false
            view.isStaged = hasStaged
            return view
        }

        // MARK: - NSTableViewDelegate

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            if tableColumn?.identifier == Self.rowNumberColumnId {
                return rowNumberCell(in: tableView, row: row)
            }
            guard let column = tableColumn,
                  let colIdx = columnIndex(from: column.identifier),
                  let dataRow = dataRow(row),
                  colIdx < result.columns.count
            else { return nil }

            let cells = result.rows[dataRow].cells
            let value = colIdx < cells.count ? cells[colIdx] : nil
            let affinity = PostgresColumnAffinity.from(column: result.columns[colIdx])

            let cellId = NSUserInterfaceItemIdentifier(rawValue: "pg-cell")
            let view: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView {
                view = reused
            } else {
                view = NSTableCellView()
                view.identifier = cellId
                // `wantsLayer` lets us paint a per-cell background
                // tint for NULL values without subclassing. The
                // alternating row color is drawn one layer below by
                // NSTableView so a translucent fill on top reads
                // correctly on both stripes.
                view.wantsLayer = true
                let textField = NSTextField()
                textField.isBordered = false
                textField.isEditable = false
                textField.isSelectable = false
                textField.drawsBackground = false
                textField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                textField.lineBreakMode = .byTruncatingTail
                textField.cell?.usesSingleLineMode = true
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.delegate = self
                view.addSubview(textField)
                view.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
                    textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
                    textField.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])
            }
            // Stash the result-column index on the textField so the
            // editing-delegate methods can locate the cell without
            // walking views.
            view.textField?.tag = colIdx

            // Alignment is per-column and stays consistent across rows
            // — set it every time since the cell view is recycled
            // across columns of different affinities.
            view.textField?.alignment = affinity.textAlignment

            let cellKey = PostgresPendingEditKey(rowIndex: dataRow, columnIndex: colIdx)
            let isStaged = pendingEdits[cellKey] != nil

            if isStaged {
                let displayVal = value ?? "NULL"
                view.textField?.stringValue = displayString(affinity.displayValue(displayVal))
                view.textField?.textColor = .labelColor
                view.layer?.backgroundColor = NSColor.systemBlue
                    .withAlphaComponent(0.18)
                    .cgColor
                view.toolTip = "Modified value: \(displayVal) (Staged)"
            } else if let value {
                view.textField?.stringValue = displayString(affinity.displayValue(value))
                view.textField?.textColor = affinity.foregroundTint ?? .labelColor
                // Clear any leftover NULL/staged tint from a recycled view.
                view.layer?.backgroundColor = nil
                // Tooltip surfaces the original value plus the type
                // name. Trim huge payloads so long JSON blobs don't
                // build massive tooltip windows.
                let preview = value.count > 200 ? String(value.prefix(200)) + "…" : value
                let typeName = result.columns[colIdx].typeName
                view.toolTip = typeName.isEmpty ? preview : "\(preview)\n— \(typeName)"
            } else {
                view.textField?.stringValue = "NULL"
                view.textField?.textColor = .tertiaryLabelColor
                // Subtle warning tint distinguishes NULL from empty
                // string at a glance — empty strings render as a
                // blank cell on the alternating row background, NULL
                // gets a faint amber wash. Low alpha keeps it from
                // dominating the row.
                view.layer?.backgroundColor = NSColor.systemOrange
                    .withAlphaComponent(0.10)
                    .cgColor
                view.toolTip = nil
            }
            return view
        }

        /// Gutter cell: 1-based display position offset by the host's
        /// page base. Distinct reuse id keeps these out of the
        /// editable-cell pool (no delegate, no result-column tag).
        private func rowNumberCell(in tableView: NSTableView, row: Int) -> NSView {
            let id = NSUserInterfaceItemIdentifier(rawValue: "pg-rownum")
            let view: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
                view = reused
            } else {
                view = NSTableCellView()
                view.identifier = id
                let textField = NSTextField()
                textField.isBordered = false
                textField.isEditable = false
                textField.isSelectable = false
                textField.drawsBackground = false
                textField.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
                textField.alignment = .right
                textField.textColor = .tertiaryLabelColor
                textField.lineBreakMode = .byClipping
                textField.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(textField)
                view.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
                    textField.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])
            }
            view.textField?.stringValue = String(rowNumberBase + row + 1)
            return view
        }

        // MARK: - Sort

        /// Header click → cycle the sort on that column: ascending →
        /// descending → none. Browse-mode hosts take over via
        /// `onHeaderSort` (server-side ORDER BY); otherwise this is a
        /// client-side sort of the loaded rows (a note in the UI
        /// explains it sorts what's fetched, not the full result).
        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let colIdx = columnIndex(from: tableColumn.identifier),
                  colIdx < result.columns.count
            else { return }
            if let onHeaderSort {
                // Sorting one fetched page locally would lie about
                // the relation's order — delegate to the host, which
                // re-runs the SELECT with ORDER BY.
                onHeaderSort(result.columns[colIdx].name)
                return
            }
            if sortColumnIndex == colIdx {
                if sortAscending { sortAscending = false } else { sortColumnIndex = nil }
            } else {
                sortColumnIndex = colIdx
                sortAscending = true
            }
            updateSortIndicators(in: tableView)
            recomputeDisplayOrder()
            tableView.reloadData()
        }

        func updateSortIndicators(in tableView: NSTableView) {
            // Server-side sort (browse mode) matches by column name;
            // local sort by result-column index. Exactly one of the
            // two is in play — `onHeaderSort` short-circuits the
            // local path in `didClick`.
            let isSorted: (NSTableColumn) -> Bool = { [self] col in
                guard let idx = columnIndex(from: col.identifier),
                      idx < result.columns.count
                else { return false }
                if onHeaderSort != nil {
                    return serverSort?.columnName == result.columns[idx].name
                }
                return sortColumnIndex == idx
            }
            let ascending = onHeaderSort != nil
                ? (serverSort?.ascending ?? true)
                : sortAscending
            for col in tableView.tableColumns {
                let image = isSorted(col)
                    ? NSImage(named: ascending
                        ? "NSAscendingSortIndicator"
                        : "NSDescendingSortIndicator")
                    : nil
                tableView.setIndicatorImage(image, in: col)
            }
            tableView.highlightedTableColumn = tableView.tableColumns.first(where: isSorted)
        }

        // MARK: - State for copy actions

        /// Set by the table itself before invoking copy actions, so
        /// the coordinator (which doesn't otherwise know which table
        /// it serves) can read selection state. Only one table per
        /// coordinator in practice.
        weak var lastTable: NSTableView?

        // MARK: - Helpers

        func columnIndex(from id: NSUserInterfaceItemIdentifier) -> Int? {
            guard let raw = id.rawValue.split(separator: "-").last else { return nil }
            return Int(raw)
        }

        private func displayString(_ value: String) -> String {
            // Single-line cells: collapse newlines so the row keeps a
            // uniform height. Full value remains in the tooltip and
            // the clipboard.
            value.replacingOccurrences(of: "\r\n", with: " ⏎ ")
                .replacingOccurrences(of: "\n", with: " ⏎ ")
        }

        func presentAlert(title: String, message: String) {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
