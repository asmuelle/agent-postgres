import AppKit
import PgAgentMacOS
import SwiftUI

// =============================================================================
// PostgresResultsTable — `NSViewRepresentable` wrapping `NSScrollView +
// NSTableView` for the query result grid.
//
// Why drop SwiftUI's `LazyVGrid`: column resize, multi-row selection,
// and ⌘C-to-clipboard need either NSViewRepresentable plumbing or
// macOS 14+ APIs. NSTableView is the right primitive; SwiftUI's
// `Table` (macOS 12+) doesn't support fully dynamic columns.
//
// Update strategy:
// - Column set changed → rebuild columns + reload data.
// - Same columns, more rows → `insertRows(at:)` so existing user
//   scroll position is preserved during pagination.
// - Same columns, fewer/different rows (rare) → reload.
//
// The wrapper is intentionally read-only. Inline cell editing would
// require write-back logic against `pg_attribute` keys — a future
// slice. Selection + copy are the v1 power-user affordances.
// =============================================================================

/// Compact column identity for the rebuild-vs-append decision.
/// Two columns that share name + OID are treated as the same column
/// across `updateNSView` calls, which lets pagination append rows
/// without rebuilding (and without losing user-resized widths).
private struct ColumnSignature: Equatable {
    let name: String
    let typeOid: UInt32
}

/// Edit request bubbled from the table's commit handler up to the
/// host (the query tab view), which runs the actual UPDATE and
/// reports an outcome back via the completion closure.
struct PostgresCellEdit {
    let rowIndex: Int
    /// Index in the underlying `result.columns`, *not* the visible
    /// table-column index. Hidden `__pg_*` columns sit between
    /// visible ones, so the indices diverge.
    let columnIndex: Int
    let columnName: String
    /// The column's `pg_type.typname`. Used by the UPDATE to cast
    /// `$1::<type>` server-side. Empty for multi-statement results
    /// where types aren't surfaced; the UI gates editing on this
    /// being non-empty.
    let columnType: String
    /// `nil` = SET NULL. Empty string = the literal empty string
    /// (for text-like columns) — the UI distinguishes via the
    /// "Set to NULL" menu item rather than typing a magic word.
    let newValue: String?
    /// Row identifier extracted from the hidden `__pg_rowid__`
    /// column (the relation's ctid). Empty would mean the result
    /// has no rowid; the UI gates editing on this being non-empty
    /// before invoking the closure.
    let rowId: String
}

enum PostgresCellEditOutcome {
    /// The UPDATE applied; display the new value.
    case applied
    /// The UPDATE matched zero rows. ctid moved or the row was
    /// deleted by another session.
    case conflict
    /// Server-side or driver error; revert.
    case failed(message: String)
}

/// Tuple describing the (profile, table) the table view should
/// persist column widths against. Composite key built from these
/// is shared across query reruns of the same table.
struct PostgresColumnWidthKey: Equatable {
    let profileId: String
    let schema: String
    let table: String
}

/// A cell the user asked to inspect (right-click → "Show value…"). The host
/// presents a viewer; `typeName` lets it pretty-print JSON/JSONB.
struct PostgresCellInspection: Identifiable {
    let id = UUID()
    let columnName: String
    let typeName: String
    let value: String?
}

struct PostgresResultsTable: NSViewRepresentable {
    let result: FfiPgExecutionResult
    /// Case-insensitive substring filter across visible columns. Empty = no
    /// filter. Driven by the host's filter field.
    var filterText: String = ""
    /// Invoked when the user picks "Show value…" — the host presents a viewer.
    var onInspectCell: ((PostgresCellInspection) -> Void)? = nil
    /// `true` when the host knows how to UPDATE rows (tab opened
    /// from the schema browser AND the result carries a `__pg_rowid__`
    /// column). When `false`, the grid is fully read-only — no
    /// double-click-to-edit, no "Set to NULL" menu item.
    var editable: Bool = false
    var pendingEdits: [PostgresPendingEditKey: PostgresPendingEdit] = [:]
    /// Invoked when the user commits a cell edit. Receives the edit
    /// description plus a completion callback to be invoked on the
    /// main queue with the UPDATE outcome.
    var onCellEdit: ((PostgresCellEdit, @escaping (PostgresCellEditOutcome) -> Void) -> Void)? = nil
    /// Invoked when the user picks "Export full result as CSV…".
    /// The host runs the file dialog + cursor-drain pipeline; the
    /// table just exposes the menu item. `nil` hides the item.
    var onExportFull: (() -> Void)? = nil
    /// Invoked when the user picks "Export full result as JSONL…".
    /// Same pattern as `onExportFull`.
    var onExportFullJsonl: (() -> Void)? = nil
    /// Invoked when the user picks "Export full result as Parquet…".
    /// Same pattern as `onExportFull`.
    var onExportFullParquet: (() -> Void)? = nil
    /// Invoked when the user picks "Delete selected row(s)". Receives
    /// the *result* row indices (translated from selection) — the
    /// host runs the confirm + DELETE pipeline.
    var onDeleteRows: (([Int]) -> Void)? = nil
    /// Invoked when the user picks "Insert row…". Host presents the
    /// modal sheet + runs the INSERT pipeline. `nil` hides the
    /// menu item.
    var onInsertRow: (() -> Void)? = nil
    /// Persistence key for column widths. When all three are
    /// non-nil, the coordinator restores user-saved widths on
    /// rebuild and persists changes after each manual resize.
    /// Generic SQL tabs leave these `nil` and use defaults.
    var widthPersistKey: PostgresColumnWidthKey? = nil

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator(
            result: result,
            editable: editable,
            onCellEdit: onCellEdit,
            onExportFull: onExportFull,
            onExportFullJsonl: onExportFullJsonl,
            onExportFullParquet: onExportFullParquet,
            onDeleteRows: onDeleteRows,
            onInsertRow: onInsertRow,
            widthPersistKey: widthPersistKey
        )
        coord.pendingEdits = pendingEdits
        coord.onInspectCell = onInspectCell
        coord.filterText = filterText
        coord.recomputeDisplayOrder()
        return coord
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        // Overlay scrollbars avoid reserving an empty strip below
        // the final visible table row.
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let table = CopyableTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnSelection = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.rowHeight = 22
        table.headerView = NSTableHeaderView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.copySource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        // Initial column set.
        context.coordinator.rebuildColumns(in: table, from: result.columns)

        // Right-click menu — gives discoverability that ⌘C alone
        // doesn't. Items look up the table's selection at runtime.
        let menu = NSMenu()
        menu.delegate = context.coordinator
        var items: [NSMenuItem] = [
            NSMenuItem(
                title: "Copy",
                action: #selector(Coordinator.copySelectedRows(_:)),
                keyEquivalent: "c"
            ),
            NSMenuItem(
                title: "Copy with header",
                action: #selector(Coordinator.copySelectedRowsWithHeader(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem.separator(),
            NSMenuItem(
                title: "Copy cell",
                action: #selector(Coordinator.copyClickedCell(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Show value…",
                action: #selector(Coordinator.showClickedValue(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Copy NULL as empty (toggle)",
                action: #selector(Coordinator.toggleNullAsEmpty(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem.separator(),
            NSMenuItem(
                title: "Export visible rows as CSV…",
                action: #selector(Coordinator.exportCsv(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Export selected rows as CSV…",
                action: #selector(Coordinator.exportSelectedCsv(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Export full result as CSV…",
                action: #selector(Coordinator.exportFullCsv(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Export full result as JSONL…",
                action: #selector(Coordinator.exportFullJsonl(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Export full result as Parquet…",
                action: #selector(Coordinator.exportFullParquet(_:)),
                keyEquivalent: ""
            ),
        ]
        if editable {
            // Edit affordances live in the same menu so users
            // discover them next to copy. `Set to NULL` is the only
            // way to write NULL — typing a "NULL" string would be
            // taken as the literal text, ambiguous in a database
            // tool.
            items.append(.separator())
            items.append(NSMenuItem(
                title: "Set to NULL",
                action: #selector(Coordinator.setClickedCellToNull(_:)),
                keyEquivalent: ""
            ))
            items.append(NSMenuItem(
                title: "Set selected rows in this column to NULL",
                action: #selector(Coordinator.setSelectionInColumnToNull(_:)),
                keyEquivalent: ""
            ))
            items.append(NSMenuItem(
                title: "Paste into selected rows in this column",
                action: #selector(Coordinator.pasteIntoSelectionInColumn(_:)),
                keyEquivalent: ""
            ))
            items.append(.separator())
            items.append(NSMenuItem(
                title: "Insert row…",
                action: #selector(Coordinator.insertRow(_:)),
                keyEquivalent: ""
            ))
            items.append(NSMenuItem(
                title: "Delete selected row(s)",
                action: #selector(Coordinator.deleteSelectedRows(_:)),
                keyEquivalent: ""
            ))
        }
        menu.items = items
        for item in menu.items {
            item.target = context.coordinator
        }
        table.menu = menu

        // One coordinator per representable; record the backing
        // table here so the menu actions can resolve it without
        // walking responders or hit-testing the mouse location.
        context.coordinator.lastTable = table

        // Persist column widths when the user drags a divider.
        // `NSTableViewColumnDidResize` fires synchronously per
        // resize step; the store's per-key dedupe guard keeps
        // disk writes infrequent.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.columnDidResize(_:)),
            name: NSTableView.columnDidResizeNotification,
            object: table
        )

        scrollView.documentView = table
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let table = nsView.documentView as? CopyableTableView else { return }
        let coord = context.coordinator
        // Identity = (name, typeOid). Two queries that happen to use
        // the same column names but different types should still
        // rebuild — the affinity-driven alignment / formatting
        // depends on the OID.
        let prevColumnIdentities = coord.result.columns.map { ColumnSignature(name: $0.name, typeOid: $0.typeOid) }
        let prevDisplayOrder = coord.displayOrder

        coord.editable = editable
        coord.pendingEdits = pendingEdits
        coord.onCellEdit = onCellEdit
        coord.onExportFull = onExportFull
        coord.onExportFullJsonl = onExportFullJsonl
        coord.onExportFullParquet = onExportFullParquet
        coord.onDeleteRows = onDeleteRows
        coord.onInsertRow = onInsertRow
        coord.onInspectCell = onInspectCell
        coord.widthPersistKey = widthPersistKey
        // Set the filter before `update` so the recompute reflects it.
        coord.filterText = filterText
        coord.update(result: result)

        let newIdentities = result.columns.map { ColumnSignature(name: $0.name, typeOid: $0.typeOid) }
        let columnsChanged = newIdentities != prevColumnIdentities
        if columnsChanged {
            coord.rebuildColumns(in: table, from: result.columns)
            table.reloadData()
            return
        }

        // Reconcile against the recomputed display order. A pure suffix-append
        // (pagination, no sort/filter) keeps scroll position via insertRows;
        // any other change (sort, filter, re-run) reloads.
        let newDisplayOrder = coord.displayOrder
        if newDisplayOrder == prevDisplayOrder {
            return
        }
        if newDisplayOrder.count > prevDisplayOrder.count,
           Array(newDisplayOrder.prefix(prevDisplayOrder.count)) == prevDisplayOrder {
            let appended = IndexSet(integersIn: prevDisplayOrder.count..<newDisplayOrder.count)
            table.insertRows(at: appended, withAnimation: [])
        } else {
            table.reloadData()
        }
    }

    // ------------------------------------------------------------------
    // Coordinator
    // ------------------------------------------------------------------

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
        private(set) var editedRows: Set<Int> = []

        // MARK: - Sort + filter (display order)

        /// Result-column index the grid is sorted by, or `nil` for none.
        private var sortColumnIndex: Int?
        private var sortAscending: Bool = true
        /// Case-insensitive substring filter across visible columns. Set by the
        /// host's filter field through `PostgresResultsTable`.
        var filterText: String = ""
        /// Data-row indices in display order (after filter + sort). Identity
        /// (`0..<rows.count`) when not reordered, so the read paths stay uniform.
        private(set) var displayOrder: [Int] = []

        /// `true` when a sort or filter is active. Cell editing is disabled while
        /// reordered: the destructive ctid edit/delete paths assume table row ==
        /// data row, so a wrong display mapping there could corrupt the wrong
        /// row. With editing gated, a mapping bug can only mis-render/mis-copy.
        var isReordered: Bool {
            sortColumnIndex != nil
                || !filterText.trimmingCharacters(in: .whitespaces).isEmpty
        }

        /// Map a table (display) row to its data-row index, or `nil` if invalid.
        private func dataRow(_ displayRow: Int) -> Int? {
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
        private struct PendingEdit {
            let rowIndex: Int
            let columnIndex: Int
            let columnName: String
            let columnType: String
            let original: String
            let rowId: String
        }
        private var pendingEdit: PendingEdit?

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
        private func isHiddenColumn(_ index: Int) -> Bool {
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
        private func rowId(forRow rowIndex: Int) -> String? {
            guard let colIdx = rowidColumnIndex(),
                  rowIndex < result.rows.count,
                  colIdx < result.rows[rowIndex].cells.count
            else { return nil }
            return result.rows[rowIndex].cells[colIdx]
        }

        // MARK: - Columns

        func rebuildColumns(in table: NSTableView, from columns: [FfiPgColumn]) {
            for col in table.tableColumns {
                table.removeTableColumn(col)
            }
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

        // MARK: - Sort

        /// Header click → cycle the sort on that column: ascending →
        /// descending → none. Client-side sort of the loaded rows (a note in
        /// the UI explains it sorts what's fetched, not the full result).
        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let colIdx = columnIndex(from: tableColumn.identifier),
                  colIdx < result.columns.count
            else { return }
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

        private func updateSortIndicators(in tableView: NSTableView) {
            for col in tableView.tableColumns {
                let sorted = sortColumnIndex != nil
                    && columnIndex(from: col.identifier) == sortColumnIndex
                let image = sorted
                    ? NSImage(named: sortAscending
                        ? "NSAscendingSortIndicator"
                        : "NSDescendingSortIndicator")
                    : nil
                tableView.setIndicatorImage(image, in: col)
            }
            tableView.highlightedTableColumn = tableView.tableColumns.first {
                sortColumnIndex != nil && columnIndex(from: $0.identifier) == sortColumnIndex
            }
        }

        // MARK: - Inspect

        /// Right-click → "Show value…". Bubbles the clicked cell up to the host,
        /// which presents a value viewer (pretty-printed for JSON/JSONB).
        @objc func showClickedValue(_ sender: Any?) {
            guard let onInspectCell, let table = lastTable,
                  table.clickedRow >= 0, table.clickedColumn >= 0,
                  table.clickedColumn < table.tableColumns.count,
                  let dataRow = dataRow(table.clickedRow)
            else { return }
            let column = table.tableColumns[table.clickedColumn]
            guard let colIdx = columnIndex(from: column.identifier),
                  colIdx < result.columns.count
            else { return }
            let cells = result.rows[dataRow].cells
            let value = colIdx < cells.count ? cells[colIdx] : nil
            onInspectCell(PostgresCellInspection(
                columnName: result.columns[colIdx].name,
                typeName: result.columns[colIdx].typeName,
                value: value
            ))
        }

        // MARK: - Copy

        @objc func copySelectedRows(_ sender: Any?) {
            copyToClipboard(includeHeader: false)
        }

        @objc func copySelectedRowsWithHeader(_ sender: Any?) {
            copyToClipboard(includeHeader: true)
        }

        @objc func copyClickedCell(_ sender: Any?) {
            guard let table = currentTable(from: sender),
                  table.clickedRow >= 0,
                  table.clickedColumn >= 0,
                  let dataRow = dataRow(table.clickedRow)
            else { return }
            // The clicked column index is the visible (display)
            // index. Map it through the column identifier so we
            // index `result.rows[row].cells` correctly even after
            // user reordering (NSTableView allows column drag).
            let column = table.tableColumns[table.clickedColumn]
            guard let colIdx = columnIndex(from: column.identifier) else { return }
            let cells = result.rows[dataRow].cells
            let value = colIdx < cells.count ? cells[colIdx] : nil
            let text = value.map(escapeForClipboard) ?? (nullAsEmptyInCopy ? "" : "NULL")
            writeToPasteboard(text)
        }

        @objc func toggleNullAsEmpty(_ sender: Any?) {
            nullAsEmptyInCopy.toggle()
            if let item = sender as? NSMenuItem {
                item.state = nullAsEmptyInCopy ? .on : .off
            }
        }

        // MARK: - CSV export

        /// Save the currently-loaded result as RFC 4180 CSV. Skips
        /// hidden `__pg_*` columns. NULL renders as an empty field
        /// (the standard CSV convention; spreadsheets distinguish
        /// empty from "NULL"-the-string by parsing).
        ///
        /// "Visible rows" means whatever's been fetched so far —
        /// users wanting the full result hit "Load more" until the
        /// cursor exhausts, then export. Streaming the cursor
        /// directly to disk would let big tables export without
        /// hitting the 50K accumulated-rows cap, but is a v2
        /// optimization.
        @objc func exportCsv(_ sender: Any?) {
            // Visible-rows export = the current display order (filtered + sorted).
            exportCsvWithRows(displayOrder, suggestedName: "results.csv")
        }

        /// Delegate to the host's full-export pipeline. Coordinator
        /// stays out of the file IO + cursor draining business —
        /// the host has the BridgeManager + tab session id + store
        /// references it needs.
        @objc func exportFullCsv(_ sender: Any?) {
            onExportFull?()
        }

        @objc func exportFullJsonl(_ sender: Any?) {
            onExportFullJsonl?()
        }

        @objc func exportFullParquet(_ sender: Any?) {
            onExportFullParquet?()
        }

        /// Export only the rows the user has selected. Reuses the
        /// visible-export writer with a filtered work list.
        @objc func exportSelectedCsv(_ sender: Any?) {
            guard let table = lastTable else { return }
            let selected = table.selectedRowIndexes
            guard !selected.isEmpty else {
                presentAlert(
                    title: "No rows selected",
                    message: "Select one or more rows, then try again."
                )
                return
            }
            // Map the selected display rows back to data-row indices.
            exportCsvWithRows(selected.compactMap { dataRow($0) }, suggestedName: "results-selected.csv")
        }

        /// Right-click → "Insert row…". Pure delegation: host
        /// presents the modal sheet and runs the INSERT pipeline.
        @objc func insertRow(_ sender: Any?) {
            onInsertRow?()
        }

        /// Hand the selected result-row indices to the host's DELETE
        /// pipeline. The host runs the confirm + UPDATE-style flow.
        @objc func deleteSelectedRows(_ sender: Any?) {
            guard let table = lastTable, let onDeleteRows else { return }
            let selected = table.selectedRowIndexes
            guard !selected.isEmpty else {
                presentAlert(
                    title: "No rows selected",
                    message: "Select one or more rows, then try again."
                )
                return
            }
            // ctid-based delete is order-independent; map display → data.
            onDeleteRows(selected.compactMap { dataRow($0) })
        }

        /// Shared CSV writer. `dataRowIndices` are result-row indices already in
        /// the desired output order (display order, or the selection).
        private func exportCsvWithRows(_ dataRowIndices: [Int], suggestedName: String) {
            guard let table = lastTable, !result.rows.isEmpty else {
                presentAlert(title: "No rows to export", message: "")
                return
            }
            let panel = NSSavePanel()
            panel.title = "Export rows as CSV"
            panel.nameFieldStringValue = suggestedName
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }

            let columnPlan: [(displayName: String, resultIdx: Int)] =
                table.tableColumns.compactMap { col in
                    guard let idx = columnIndex(from: col.identifier),
                          idx < result.columns.count
                    else { return nil }
                    return (col.title, idx)
                }
            guard !columnPlan.isEmpty else {
                presentAlert(title: "Nothing to export", message: "No visible columns.")
                return
            }

            var output = String()
            output.append(columnPlan.map { csvEscape($0.displayName) }.joined(separator: ","))
            output.append("\n")
            // Already ordered by the caller (display order or selection).
            for r in dataRowIndices where r < result.rows.count {
                let row = result.rows[r]
                let line = columnPlan.map { plan -> String in
                    guard plan.resultIdx < row.cells.count else { return "" }
                    if let value = row.cells[plan.resultIdx] {
                        return csvEscape(value)
                    }
                    return ""
                }
                .joined(separator: ",")
                output.append(line)
                output.append("\n")
            }

            do {
                try output.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                presentAlert(title: "Export failed", message: error.localizedDescription)
            }
        }

        /// RFC 4180 quoting: a field gets wrapped in double-quotes if
        /// it contains comma, double-quote, or newline. Internal
        /// double-quotes are doubled. Other strings pass through
        /// verbatim.
        fileprivate func csvEscape(_ s: String) -> String {
            let needsQuoting = s.contains(",") || s.contains("\"")
                || s.contains("\n") || s.contains("\r")
            if !needsQuoting { return s }
            let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }

        private func copyToClipboard(includeHeader: Bool) {
            // Resolve the table from any active responder. The menu
            // items can be invoked via right-click or via ⌘C from the
            // CopyableTableView; both paths land here.
            let table = lastTable
            guard let table else { return }
            let selected = table.selectedRowIndexes
            // Display rows → data rows (in display order). Empty selection =
            // the whole visible result.
            let dataRowIdxs: [Int] = (selected.isEmpty ? Array(0..<displayOrder.count) : Array(selected))
                .compactMap { dataRow($0) }

            var lines: [String] = []
            lines.reserveCapacity(dataRowIdxs.count + 1)

            // Use the visible column order (after any user reorder)
            // so the clipboard matches what the user sees.
            let orderedColumns = table.tableColumns
                .compactMap { col -> Int? in columnIndex(from: col.identifier) }

            if includeHeader {
                let header = orderedColumns
                    .map { result.columns[$0].name }
                    .map(escapeForClipboard)
                    .joined(separator: "\t")
                lines.append(header)
            }

            for r in dataRowIdxs {
                guard r < result.rows.count else { continue }
                let cells = result.rows[r].cells
                let parts = orderedColumns.map { idx -> String in
                    let v = idx < cells.count ? cells[idx] : nil
                    if let v {
                        return escapeForClipboard(v)
                    }
                    return nullAsEmptyInCopy ? "" : "NULL"
                }
                lines.append(parts.joined(separator: "\t"))
            }
            writeToPasteboard(lines.joined(separator: "\n"))
        }

        /// Tabs / newlines in cell values would corrupt TSV. Tabs
        /// become a single space (lossy but the common convention);
        /// newlines become the literal `\n`. Quoting CSV-style would
        /// be more rigorous but most spreadsheets treat `\t`-pasted
        /// data without quote handling.
        private func escapeForClipboard(_ s: String) -> String {
            s.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: "\\n")
        }

        private func writeToPasteboard(_ text: String) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }

        // MARK: - Editing

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
                original: result.rows[table.clickedRow].cells[resultColIdx],
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

        /// Multi-row paste: each line goes to one selected row. The
        /// loop drains sequentially with the same conflict semantics
        /// as `applyToSelectionLoop`.
        private func applyDistributedToSelection(
            descriptor: (resultIdx: Int, name: String, type: String),
            values: [String],
            rows: [Int]
        ) {
            guard values.count == rows.count, let table = lastTable, let onCellEdit else { return }
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
                table: table
            )
        }

        private func distributedLoop(
            descriptor: (resultIdx: Int, name: String, type: String),
            work: [(rowIndex: Int, rowId: String, value: String)],
            index: Int,
            successCount: Int,
            conflictCount: Int,
            onCellEdit: @escaping (PostgresCellEdit, @escaping (PostgresCellEditOutcome) -> Void) -> Void,
            table: NSTableView
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
            let item = work[index]
            let edit = PostgresCellEdit(
                rowIndex: item.rowIndex,
                columnIndex: descriptor.resultIdx,
                columnName: descriptor.name,
                columnType: descriptor.type,
                newValue: item.value,
                rowId: item.rowId
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
                            previousValue: original
                        )
                        self.distributedLoop(
                            descriptor: descriptor,
                            work: work,
                            index: index + 1,
                            successCount: successCount + 1,
                            conflictCount: conflictCount,
                            onCellEdit: onCellEdit,
                            table: table
                        )
                    case .conflict:
                        self.reloadRow(item.rowIndex)
                        self.distributedLoop(
                            descriptor: descriptor,
                            work: work,
                            index: index + 1,
                            successCount: successCount,
                            conflictCount: conflictCount + 1,
                            onCellEdit: onCellEdit,
                            table: table
                        )
                    case .failed(let message):
                        self.presentAlert(
                            title: "Update failed after \(successCount) row(s)",
                            message: message
                        )
                        self.reloadRow(item.rowIndex)
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
                conflictCount: 0
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
            conflictCount: Int
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
            let edit = PostgresCellEdit(
                rowIndex: item.rowIndex,
                columnIndex: descriptor.resultIdx,
                columnName: descriptor.name,
                columnType: descriptor.type,
                newValue: value,
                rowId: item.rowId
            )
            let original = result.rows[item.rowIndex].cells[descriptor.resultIdx]
            onCellEdit!(edit) { [weak self] outcome in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch outcome {
                    case .applied:
                        self.applyEditOutcome(
                            edit: edit,
                            outcome: .applied,
                            previousValue: original
                        )
                        self.applyToSelectionLoop(
                            descriptor: descriptor,
                            value: value,
                            work: work,
                            index: index + 1,
                            successCount: successCount + 1,
                            conflictCount: conflictCount
                        )
                    case .conflict:
                        // Swallow per-row conflicts; we'll summarize
                        // at the end. Reload that row to revert
                        // visually.
                        self.reloadRow(item.rowIndex)
                        self.applyToSelectionLoop(
                            descriptor: descriptor,
                            value: value,
                            work: work,
                            index: index + 1,
                            successCount: successCount,
                            conflictCount: conflictCount + 1
                        )
                    case .failed(let message):
                        // First hard failure stops the run — show
                        // the partial summary alongside the error.
                        self.presentAlert(
                            title: "Update failed after \(successCount) row(s)",
                            message: message
                        )
                        self.reloadRow(item.rowIndex)
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
                rowId: rid
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
                rowId: pending.rowId
            )
        }

        /// Build the FFI request, hand it to the host's `onCellEdit`
        /// closure, and apply / revert the table's display based on
        /// the outcome.
        private func commitEdit(
            rowIndex: Int,
            columnIndex: Int,
            newValue: String?,
            original: String?,
            rowId: String
        ) {
            guard let onCellEdit, columnIndex < result.columns.count else { return }
            let edit = PostgresCellEdit(
                rowIndex: rowIndex,
                columnIndex: columnIndex,
                columnName: result.columns[columnIndex].name,
                columnType: result.columns[columnIndex].typeName,
                newValue: newValue,
                rowId: rowId
            )
            onCellEdit(edit) { [weak self] outcome in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.applyEditOutcome(
                        edit: edit,
                        outcome: outcome,
                        previousValue: original
                    )
                }
            }
        }

        private func applyEditOutcome(
            edit: PostgresCellEdit,
            outcome: PostgresCellEditOutcome,
            previousValue: String?
        ) {
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

        private func reloadRow(_ rowIndex: Int) {
            guard let table = lastTable, rowIndex >= 0,
                  rowIndex < table.numberOfRows
            else { return }
            let cols = IndexSet(integersIn: 0..<table.tableColumns.count)
            table.reloadData(forRowIndexes: IndexSet(integer: rowIndex), columnIndexes: cols)
        }

        private func presentAlert(title: String, message: String) {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        // MARK: - Menu validation

        func menuNeedsUpdate(_ menu: NSMenu) {
            // `lastTable` is set in `makeNSView`; menu items consult
            // it for selection/clicked-cell state.
            let hasSelection = (lastTable?.selectedRowIndexes.isEmpty == false)
            let clickedCellEditable = canEditClickedCell()
            for item in menu.items {
                guard let action = item.action else { continue }
                switch action {
                case #selector(copyClickedCell(_:)),
                     #selector(showClickedValue(_:)):
                    item.isEnabled = (lastTable?.clickedRow ?? -1) >= 0
                case #selector(copySelectedRows(_:)),
                     #selector(copySelectedRowsWithHeader(_:)):
                    item.isEnabled = hasSelection || !result.rows.isEmpty
                case #selector(toggleNullAsEmpty(_:)):
                    item.state = nullAsEmptyInCopy ? .on : .off
                    item.isEnabled = true
                case #selector(setClickedCellToNull(_:)):
                    item.isEnabled = clickedCellEditable
                case #selector(setSelectionInColumnToNull(_:)),
                     #selector(pasteIntoSelectionInColumn(_:)):
                    // Selection-bulk operations need an editable
                    // column AND at least one selected row.
                    item.isEnabled = clickedCellEditable
                        && !(lastTable?.selectedRowIndexes.isEmpty ?? true)
                case #selector(exportCsv(_:)):
                    item.isEnabled = !result.rows.isEmpty
                case #selector(exportSelectedCsv(_:)):
                    item.isEnabled = hasSelection
                case #selector(exportFullCsv(_:)):
                    // The full-export item is only useful when the
                    // host wired a callback. Hidden when not editable
                    // / no callback so users on bare-result tabs
                    // aren't tempted by a non-functional menu item.
                    item.isHidden = (onExportFull == nil)
                    item.isEnabled = (onExportFull != nil)
                case #selector(exportFullJsonl(_:)):
                    item.isHidden = (onExportFullJsonl == nil)
                    item.isEnabled = (onExportFullJsonl != nil)
                case #selector(exportFullParquet(_:)):
                    item.isHidden = (onExportFullParquet == nil)
                    item.isEnabled = (onExportFullParquet != nil)
                case #selector(deleteSelectedRows(_:)):
                    item.isEnabled = (onDeleteRows != nil) && hasSelection
                case #selector(insertRow(_:)):
                    item.isEnabled = (onInsertRow != nil)
                default:
                    item.isEnabled = true
                }
            }
        }

        /// Whether the cell under the right-click cursor can be
        /// written. Used by `Set to NULL`'s validate path.
        private func canEditClickedCell() -> Bool {
            guard editable, !isReordered,
                  let table = lastTable,
                  table.clickedRow >= 0, table.clickedColumn >= 0,
                  table.clickedRow < result.rows.count,
                  table.clickedColumn < table.tableColumns.count
            else { return false }
            let column = table.tableColumns[table.clickedColumn]
            guard let resultColIdx = columnIndex(from: column.identifier),
                  resultColIdx < result.columns.count,
                  !isHiddenColumn(resultColIdx),
                  !result.columns[resultColIdx].typeName.isEmpty,
                  rowId(forRow: table.clickedRow) != nil
            else { return false }
            return true
        }

        // MARK: - State for copy actions

        /// Set by the table itself before invoking copy actions, so
        /// the coordinator (which doesn't otherwise know which table
        /// it serves) can read selection state. Only one table per
        /// coordinator in practice.
        weak var lastTable: NSTableView?

        // MARK: - Helpers

        private func columnIndex(from id: NSUserInterfaceItemIdentifier) -> Int? {
            guard let raw = id.rawValue.split(separator: "-").last else { return nil }
            return Int(raw)
        }

        private func currentTable(from sender: Any?) -> NSTableView? {
            // For menu items, the menu's representedObject doesn't
            // reliably carry the table reference. Fall back to the
            // tracked last-used table.
            return lastTable
        }

        private func displayString(_ value: String) -> String {
            // Single-line cells: collapse newlines so the row keeps a
            // uniform height. Full value remains in the tooltip and
            // the clipboard.
            value.replacingOccurrences(of: "\r\n", with: " ⏎ ")
                .replacingOccurrences(of: "\n", with: " ⏎ ")
        }
    }
}

// =============================================================================
// CopyableTableView — NSTableView subclass that accepts ⌘C and routes it
// to a designated copy source. Without this, ⌘C lands on the responder
// chain's default no-op for read-only NSTableViews.
// =============================================================================

final class CopyableTableView: NSTableView {
    weak var copySource: PostgresResultsTable.Coordinator?

    /// Action target for the standard `copy:` selector. NSTableView
    /// inherits this from NSResponder; without the override, ⌘C
    /// silently no-ops on a read-only table.
    @objc func copy(_ sender: Any?) {
        copySource?.lastTable = self
        copySource?.copySelectedRows(sender)
    }

    /// AppKit menu item validation lives on `NSMenuItemValidation`,
    /// not `NSResponder`. Conforming explicitly is the right shape.
    override func becomeFirstResponder() -> Bool {
        copySource?.lastTable = self
        return super.becomeFirstResponder()
    }
}

/// Row view that draws a thin accent-colored stripe on the leading
/// edge for rows the user has edited in the current session. Stripe
/// is purely cosmetic — the underlying data is already committed
/// server-side; the indicator is "you touched this row, in case you
/// forget".
final class PostgresEditedRowView: NSTableRowView {
    var isEdited: Bool = false {
        didSet {
            if isEdited != oldValue { needsDisplay = true }
        }
    }
    var isStaged: Bool = false {
        didSet {
            if isStaged != oldValue { needsDisplay = true }
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isStaged {
            let stripeRect = NSRect(x: 0, y: 0, width: 3, height: bounds.height)
            NSColor.systemBlue.withAlphaComponent(0.85).setFill()
            stripeRect.fill()
        } else if isEdited {
            let stripeRect = NSRect(x: 0, y: 0, width: 3, height: bounds.height)
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            stripeRect.fill()
        }
    }
}

extension CopyableTableView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return !selectedRowIndexes.isEmpty || numberOfRows > 0
        }
        return true
    }
}
