import AppKit
import PgAgentMacOS

// =============================================================================
// PostgresResultsTable.Coordinator — context-menu validation and the
// per-click foreign-key navigation items ("Go to …" / "Show
// referencing rows …").
//
// Extracted from PostgresResultsTable.swift; behavior-preserving.
// =============================================================================

extension PostgresResultsTable.Coordinator {
    // MARK: - Menu validation

    func menuNeedsUpdate(_ menu: NSMenu) {
        // FK navigation items are rebuilt per right-click — they
        // depend on the clicked cell's value, unlike the static
        // copy/export items below.
        rebuildFKItems(in: menu)
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

    // MARK: - FK navigation menu

    /// Strip the previous right-click's FK items, then add fresh
    /// ones for the currently clicked cell: "Go to <target>" for
    /// each outgoing FK on the clicked column, and "Show
    /// referencing rows in <source>" for each incoming FK on the
    /// clicked row. Items whose key values are NULL (or whose
    /// columns aren't in the result) are omitted — a NULL key
    /// references nothing, and a missing column can't be filtered.
    private func rebuildFKItems(in menu: NSMenu) {
        for item in fkMenuItems where menu.items.contains(item) {
            menu.removeItem(item)
        }
        fkMenuItems.removeAll()
        fkNavigationTargets.removeAll()

        guard onNavigateFK != nil,
              let fks = foreignKeys, !fks.isEmpty,
              let table = lastTable,
              // Clicked row is a *display* row — map through the
              // active sort/filter order to the data row.
              let clickedDataRow = dataRow(table.clickedRow),
              clickedDataRow < result.rows.count
        else { return }

        let rowCells = result.rows[clickedDataRow].cells
        var columnIndexByName: [String: Int] = [:]
        for (idx, col) in result.columns.enumerated() {
            columnIndexByName[col.name] = idx
        }

        /// Resolve `sourceColumns`' values from the clicked row,
        /// pairing them with `targetColumns` for the destination
        /// filter. `nil` when any value is NULL or unavailable.
        func filters(
            sourceColumns: [String],
            targetColumns: [String]
        ) -> [(column: String, value: String)]? {
            var pairs: [(column: String, value: String)] = []
            for (source, target) in zip(sourceColumns, targetColumns) {
                guard let idx = columnIndexByName[source],
                      idx < rowCells.count,
                      let value = rowCells[idx]
                else { return nil }
                pairs.append((target, value))
            }
            return pairs.isEmpty ? nil : pairs
        }

        func preview(_ pairs: [(column: String, value: String)]) -> String {
            pairs.map { pair in
                let v = pair.value.count > 20
                    ? String(pair.value.prefix(20)) + "…"
                    : pair.value
                return "\(pair.column) = \(v)"
            }.joined(separator: ", ")
        }

        var newItems: [NSMenuItem] = []

        func addItem(title: String, nav: PostgresFKNavigation) {
            let item = NSMenuItem(
                title: title,
                action: #selector(navigateToFK(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = fkNavigationTargets.count
            fkNavigationTargets.append(nav)
            newItems.append(item)
        }

        // Outgoing FKs: offered when the clicked column is part
        // of the key, so "Go to" reads as acting on that cell.
        let clickedColumnName: String? = {
            guard table.clickedColumn >= 0,
                  table.clickedColumn < table.tableColumns.count,
                  let idx = columnIndex(from: table.tableColumns[table.clickedColumn].identifier),
                  idx < result.columns.count
            else { return nil }
            return result.columns[idx].name
        }()
        if let clickedColumnName {
            for fk in fks.outgoing where fk.fromColumns.contains(clickedColumnName) {
                guard let pairs = filters(
                    sourceColumns: fk.fromColumns,
                    targetColumns: fk.toColumns
                ) else { continue }
                addItem(
                    title: "Go to \(fk.toSchema).\(fk.toTable) (\(preview(pairs)))",
                    nav: PostgresFKNavigation(
                        schema: fk.toSchema,
                        table: fk.toTable,
                        filters: pairs
                    )
                )
            }
        }

        // Incoming FKs: row-level — any cell in the row offers
        // the reverse hop to the tables that point here.
        for fk in fks.incoming {
            guard let pairs = filters(
                sourceColumns: fk.toColumns,
                targetColumns: fk.fromColumns
            ) else { continue }
            addItem(
                title: "Show referencing rows in \(fk.fromSchema).\(fk.fromTable) (\(preview(pairs)))",
                nav: PostgresFKNavigation(
                    schema: fk.fromSchema,
                    table: fk.fromTable,
                    filters: pairs
                )
            )
        }

        guard !newItems.isEmpty else { return }
        let separator = NSMenuItem.separator()
        // Sentinel: never a valid index into fkNavigationTargets,
        // so `navigateToFK`'s tag guard rejects it even if the
        // separator somehow acquires an action.
        separator.tag = -1
        newItems.append(separator)
        for (offset, item) in newItems.enumerated() {
            menu.insertItem(item, at: offset)
        }
        fkMenuItems = newItems
    }

    @objc func navigateToFK(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < fkNavigationTargets.count else { return }
        onNavigateFK?(fkNavigationTargets[sender.tag])
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
}
