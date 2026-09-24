import AppKit
import PgAgentMacOS

// =============================================================================
// PostgresResultsTable.Coordinator — inspect, copy-to-clipboard, and
// CSV-export actions (visible rows, selected rows, and the delegation
// hooks for the host's full-result export pipeline).
//
// Extracted from PostgresResultsTable.swift; behavior-preserving.
// =============================================================================

extension PostgresResultsTable.Coordinator {
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
        // Row identity for the JSON edit path: the ctid from the hidden
        // rowid column, when this result carries one.
        let rowId: String? = result.columns
            .firstIndex(where: { $0.name == POSTGRES_ROWID_COLUMN })
            .flatMap { idx in idx < cells.count ? cells[idx] : nil }
        onInspectCell(PostgresCellInspection(
            columnName: result.columns[colIdx].name,
            typeName: result.columns[colIdx].typeName,
            value: value,
            typeOid: result.columns[colIdx].typeOid,
            rowIndex: dataRow,
            columnIndex: colIdx,
            rowId: rowId
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
    /// hidden `__pg_*` columns. NULL renders as an unquoted empty
    /// field and the empty string as `""` (PostgreSQL `COPY … CSV`
    /// convention).
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
    /// pipeline. The host runs the confirm + DELETE pipeline.
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
        output.append(columnPlan.map { PostgresExportEncoding.csvField($0.displayName) }.joined(separator: ","))
        output.append("\n")
        // Already ordered by the caller (display order or selection).
        // NULL → unquoted empty field, "" → `""` (see `csvField`).
        for r in dataRowIndices where r < result.rows.count {
            let cells = result.rows[r].cells
            let fields = columnPlan.map { plan -> String? in
                plan.resultIdx < cells.count ? cells[plan.resultIdx] : nil
            }
            output.append(PostgresExportEncoding.csvRow(fields))
            output.append("\n")
        }

        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentAlert(title: "Export failed", message: error.localizedDescription)
        }
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

    /// Tabs / line breaks in cell values would corrupt TSV — see
    /// `PostgresExportEncoding.tsvField` (handles LF, CR and CRLF).
    private func escapeForClipboard(_ s: String) -> String {
        PostgresExportEncoding.tsvField(s)
    }

    private func writeToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func currentTable(from sender: Any?) -> NSTableView? {
        // For menu items, the menu's representedObject doesn't
        // reliably carry the table reference. Fall back to the
        // tracked last-used table.
        return lastTable
    }
}
