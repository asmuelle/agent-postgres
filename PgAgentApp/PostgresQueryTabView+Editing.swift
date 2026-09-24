import AppKit
import OSLog
import PgAgentMacOS
import SwiftUI

// =============================================================================
// PostgresQueryTabView editing orchestration — cell update (direct +
// batch/staged), bulk delete, and the insert-row pipeline.
//
// Extracted from PostgresQueryTabView.swift; behavior-preserving.
// =============================================================================

extension PostgresQueryTabView {
    /// Confirm + run a bulk DELETE for the selected rows. Removes
    /// the rows from the in-memory result on success so the grid
    /// reflects the change without a re-query.
    func runDeleteRows(rowIndices: [Int], tab: PostgresQueryTab) {
        guard !rowIndices.isEmpty,
              let connectionId,
              let target = tab.editTarget,
              let result = tab.lastResult,
              let rowIdColIdx = result.columns.firstIndex(where: { $0.name == POSTGRES_ROWID_COLUMN })
        else { return }

        // Confirm. Bulk DELETE is destructive enough that even
        // power-user surfaces should require an explicit "yes".
        let alert = NSAlert()
        alert.messageText = rowIndices.count == 1
            ? "Delete 1 row from \"\(target.schema)\".\"\(target.table)\"?"
            : "Delete \(rowIndices.count) rows from \"\(target.schema)\".\"\(target.table)\"?"
        alert.informativeText = "This can't be undone from mc-ssh."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Build the ctid list from the in-memory rows; the write-back
        // removes rows by these ctids after success.
        var ctids: [String] = []
        for idx in rowIndices where idx >= 0 && idx < result.rows.count {
            let cells = result.rows[idx].cells
            guard rowIdColIdx < cells.count, let ctid = cells[rowIdColIdx] else { continue }
            ctids.append(ctid)
        }
        guard !ctids.isEmpty else { return }

        let sessionId = tab.id.uuidString
        let storeRef = store
        let tabId = tab.id
        // Identity of the result the ctids were read from. The write-back
        // removes rows by ctid (not position) and only from this result, so
        // a re-run, page switch, or concurrent delete can't make it drop the
        // wrong rows.
        let resultGeneration = tab.resultGeneration
        Task { @MainActor in
            do {
                let outcome = try await BridgeManager.shared.pgDeleteRows(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    schema: target.schema,
                    table: target.table,
                    rowIds: ctids
                )
                // Drop the rows we asked to delete from the in-memory
                // result regardless of the actual count — any "missing"
                // rows are gone server-side too. The partial-success
                // message tells the user when ctids had moved.
                storeRef.removeRows(
                    withRowIds: Set(ctids),
                    rowIdColumn: rowIdColIdx,
                    expectedResultGeneration: resultGeneration,
                    forTab: tabId
                )
                if outcome.rowsAffected != UInt64(ctids.count) {
                    let alert = NSAlert()
                    alert.messageText = "Some rows were already gone"
                    alert.informativeText = "Deleted \(outcome.rowsAffected) of \(ctids.count) rows. The others had been removed by another session."
                    alert.runModal()
                }
            } catch let err as PostgresBridgeError {
                logger.error("delete_rows failed: \(err.localizedDescription, privacy: .public)")
                let alert = NSAlert()
                alert.messageText = "Delete failed"
                alert.informativeText = err.errorDescription ?? "Unknown error."
                alert.alertStyle = .warning
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Delete failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// Bridge between the table's commit callback and the FFI. The
    /// `complete` closure is invoked on the main queue with the
    /// outcome the table uses to apply or revert the cell display.
    func runCellUpdate(
        edit: PostgresCellEdit,
        tab: PostgresQueryTab,
        complete: @escaping (PostgresCellEditOutcome) -> Void
    ) {
        guard let connectionId, let target = tab.editTarget else {
            complete(.failed(message: "Not connected, or this tab isn't tied to a table."))
            return
        }
        // The row layout `edit.rowIndex` was resolved against. If the rows
        // were replaced/shifted before we even start, the index is
        // meaningless — refuse rather than stage/paint the wrong row.
        let currentLayout = liveTab(tab.id)?.rowLayoutGeneration ?? tab.rowLayoutGeneration
        let expectedLayout = edit.rowLayout ?? currentLayout
        guard expectedLayout == currentLayout else {
            complete(.failed(message: "The results changed before the edit was applied. Re-run the query and try again."))
            return
        }

        // Batch mode: stage the edit instead of writing through.
        // The visual update still flows (`.applied` → coordinator
        // mutates its in-memory copy + reloads). Discard later
        // restores from `originalValue`.
        if liveTab(tab.id)?.batchMode ?? tab.batchMode {
            let original: String? = (liveTab(tab.id)?.lastResult ?? tab.lastResult).flatMap { result -> String? in
                guard edit.rowIndex < result.rows.count,
                      edit.columnIndex < result.rows[edit.rowIndex].cells.count
                else { return nil }
                return result.rows[edit.rowIndex].cells[edit.columnIndex]
            }
            store.addPendingEdit(
                PostgresPendingEdit(
                    columnName: edit.columnName,
                    columnType: edit.columnType,
                    originalValue: original,
                    newValue: edit.newValue,
                    rowId: edit.rowId
                ),
                key: PostgresPendingEditKey(
                    rowIndex: edit.rowIndex,
                    columnIndex: edit.columnIndex
                ),
                forTab: tab.id
            )
            store.setCellValue(
                edit.newValue,
                rowIndex: edit.rowIndex,
                columnIndex: edit.columnIndex,
                forTab: tab.id
            )
            complete(.applied)
            return
        }

        let sessionId = tab.id.uuidString
        let storeRef = store
        let tabId = tab.id
        Task { @MainActor in
            do {
                let res = try await BridgeManager.shared.pgUpdateCell(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    schema: target.schema,
                    table: target.table,
                    column: edit.columnName,
                    columnType: edit.columnType,
                    newValue: edit.newValue,
                    rowId: edit.rowId
                )
                guard !Task.isCancelled else { return }
                if res.rowsAffected == 0 {
                    complete(.conflict)
                    return
                }
                // The UPDATE hit the right row server-side (by ctid); only
                // the in-memory write-back is index-addressed, so it is
                // dropped when a re-run/delete moved the rows meanwhile.
                storeRef.setCellValue(
                    edit.newValue,
                    rowIndex: edit.rowIndex,
                    columnIndex: edit.columnIndex,
                    forTab: tabId,
                    expectedRowLayout: expectedLayout
                )
                complete(.applied)
            } catch let err as PostgresBridgeError {
                logger.error("update_cell failed: \(err.localizedDescription, privacy: .public)")
                complete(.failed(message: err.errorDescription ?? "Update failed"))
            } catch {
                complete(.failed(message: error.localizedDescription))
            }
        }
    }

    /// Apply all staged edits atomically. The batch is wrapped in its own
    /// transaction (BEGIN … COMMIT, ROLLBACK on the first hard failure) so it is
    /// all-or-nothing — unless the user already has an explicit transaction
    /// open, in which case the edits join it and they control the outcome.
    /// Conflicts (zero rows affected because the ctid moved) revert that one
    /// cell and continue; the staged edits survive a rollback so the user can
    /// fix the offending value and retry.
    func commitPendingEdits(tab: PostgresQueryTab) {
        guard let connectionId, let target = tab.editTarget,
              let live = liveTab(tab.id), !live.isApplyingEdits
        else { return }
        // Snapshot from the store, not the render-time `tab`: exactly these
        // edits are applied, and exactly these are cleared afterwards.
        let pending = live.pendingEdits
        guard !pending.isEmpty else { return }
        let sessionId = tab.id.uuidString
        let storeRef = store
        let tabId = tab.id
        let rowLayout = live.rowLayoutGeneration
        storeRef.setApplyingEdits(true, forTab: tabId)
        // Deterministic order — the server applies edits top-to-bottom.
        let edits = pending.sorted {
            ($0.key.rowIndex, $0.key.columnIndex) < ($1.key.rowIndex, $1.key.columnIndex)
        }
        let ownTransaction = (live.transactionState == .none)

        Task { @MainActor in
            defer { storeRef.setApplyingEdits(false, forTab: tabId) }
            if ownTransaction {
                do {
                    try await BridgeManager.shared.pgBegin(connectionId: connectionId, sessionId: sessionId)
                } catch {
                    presentBatchAlert(title: "Apply failed", message: Self.batchMessage(for: error))
                    return
                }
            }
            var succeeded = 0
            // Defer reverting conflicted cells until the batch actually commits,
            // so a later rollback leaves the grid showing all staged values
            // (consistent with the still-pending edits we keep for retry).
            var conflictKeys: [PostgresPendingEditKey] = []
            for (key, edit) in edits {
                do {
                    let res = try await BridgeManager.shared.pgUpdateCell(
                        connectionId: connectionId,
                        sessionId: sessionId,
                        schema: target.schema,
                        table: target.table,
                        column: edit.columnName,
                        columnType: edit.columnType,
                        newValue: edit.newValue,
                        rowId: edit.rowId
                    )
                    if res.rowsAffected == 0 {
                        conflictKeys.append(key)  // ctid moved/deleted — skip
                    } else {
                        succeeded += 1
                    }
                } catch {
                    // All-or-nothing: roll back so nothing is half-applied. The
                    // staged edits (and their grid values) are kept untouched so
                    // the user can fix the offending value and retry.
                    if ownTransaction {
                        try? await BridgeManager.shared.pgRollback(connectionId: connectionId, sessionId: sessionId)
                    } else {
                        // The user's explicit transaction is now aborted.
                        storeRef.setTransactionState(.failed, forTab: tabId)
                    }
                    presentBatchAlert(
                        title: "Apply rolled back",
                        message: "No changes were applied; your staged edits were kept.\n\n\(Self.batchMessage(for: error))"
                    )
                    return
                }
            }
            if ownTransaction {
                do {
                    try await BridgeManager.shared.pgCommit(connectionId: connectionId, sessionId: sessionId)
                } catch {
                    presentBatchAlert(
                        title: "Commit failed",
                        message: "The outcome is uncertain — re-run the query to check, then retry if needed.\n\n\(Self.batchMessage(for: error))"
                    )
                    return
                }
            }
            // Committed. Revert the cells whose rows had moved/been deleted
            // (their edits didn't apply) — unless the user re-staged that
            // cell while the Apply ran, or the rows moved under us — then
            // clear exactly the edits this Apply submitted.
            let restaged = liveTab(tabId)?.pendingEdits ?? [:]
            for key in conflictKeys {
                guard let edit = pending[key],
                      restaged[key]?.newValue == edit.newValue
                else { continue }
                storeRef.setCellValue(
                    edit.originalValue,
                    rowIndex: key.rowIndex,
                    columnIndex: key.columnIndex,
                    forTab: tabId,
                    expectedRowLayout: rowLayout
                )
            }
            storeRef.removeAppliedPendingEdits(pending, forTab: tabId)
            if !conflictKeys.isEmpty {
                presentBatchAlert(
                    title: "Applied \(succeeded), skipped \(conflictKeys.count)",
                    message: "Some rows had moved or been deleted by another session; their pending edits were reverted."
                )
            }
        }
    }

    /// The tab's current state in the store. Closures built at render time
    /// capture a `PostgresQueryTab` snapshot; async paths need the live one.
    func liveTab(_ id: UUID) -> PostgresQueryTab? {
        store.tabs.first { $0.id == id }
    }

    private func presentBatchAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func batchMessage(for error: Error) -> String {
        (error as? PostgresBridgeError)?.errorDescription ?? error.localizedDescription
    }

    /// Throw away all staged edits, restoring original values.
    func discardPendingEdits(tab: PostgresQueryTab) {
        // Discarding mid-Apply would revert values the batch may be about
        // to commit; the toolbar disables Discard meanwhile too.
        guard let live = liveTab(tab.id), !live.isApplyingEdits else { return }
        let pending = live.pendingEdits
        guard !pending.isEmpty else { return }
        for (key, edit) in pending {
            store.setCellValue(
                edit.originalValue,
                rowIndex: key.rowIndex,
                columnIndex: key.columnIndex,
                forTab: tab.id
            )
        }
        store.clearPendingEdits(forTab: tab.id)
    }

    // MARK: - INSERT row

    /// Build the sheet's input shape from the tab's current result
    /// and present it. Visible columns drive both the form rows and
    /// the RETURNING list (so the new row matches the grid shape).
    /// Also kicks off a background `describe_columns` lookup so
    /// the form can pre-set toggles based on schema metadata once
    /// it lands.
    func presentInsertSheet(tab: PostgresQueryTab) {
        guard let target = tab.editTarget,
              let result = tab.lastResult,
              let connectionId
        else { return }
        let visibleColumns = result.columns.filter { !$0.name.hasPrefix("__pg_") }
        var returnNames = result.columns.map(\.name)
        if !returnNames.contains(POSTGRES_ROWID_COLUMN) {
            returnNames.append(POSTGRES_ROWID_COLUMN)
        }
        // Show the sheet immediately so the user doesn't wait for
        // metadata. The metadata fetch updates the context once it
        // resolves; the sheet's `.onAppear` primes from the
        // (initially nil) metadata, so we re-prime when it lands.
        let ctx = InsertSheetContext(
            tab: tab,
            target: target,
            columns: visibleColumns,
            returnColumnNames: returnNames,
            columnDetails: nil
        )
        insertSheet = ctx
        let ctxId = ctx.id
        Task { @MainActor in
            do {
                let details = try await BridgeManager.shared.pgDescribeColumns(
                    connectionId: connectionId,
                    schema: target.schema,
                    table: target.table
                )
                // Only update if the user hasn't switched to a
                // different sheet in the meantime.
                if insertSheet?.id == ctxId {
                    insertSheet?.columnDetails = details
                }
            } catch {
                // Non-fatal — the sheet falls back to the
                // metadata-less behavior. Log for diagnostics.
                logger.warning("describe_columns failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Build the FFI input list from the sheet's filled-in forms
    /// (skipping `useDefault` columns), call the bridge, and on
    /// success append the new row to the in-memory result.
    func runInsertRow(
        tab: PostgresQueryTab,
        forms: [PostgresInsertColumnForm],
        returnNames: [String],
        complete: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let connectionId, let target = tab.editTarget else {
            complete(.failure(NSError(
                domain: "mc-ssh",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Not connected."]
            )))
            return
        }
        // Walk the forms; columns with `useDefault = true` are
        // omitted entirely so the server provides the default.
        var inputs: [FfiPgInsertColumn] = []
        for form in forms {
            if form.useDefault { continue }
            inputs.append(FfiPgInsertColumn(
                name: form.columnName,
                typeName: form.typeName,
                value: form.useNull ? nil : form.textValue
            ))
        }

        let sessionId = tab.id.uuidString
        let storeRef = store
        let tabId = tab.id
        // The new row is appended only to the result the sheet was opened
        // for — its cells follow that result's column order.
        let resultGeneration = tab.resultGeneration
        Task { @MainActor in
            do {
                let inserted = try await BridgeManager.shared.pgInsertRow(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    schema: target.schema,
                    table: target.table,
                    inputs: inputs,
                    returnColumns: returnNames
                )
                guard !Task.isCancelled else { return }
                // Reorder cells to match the existing result's
                // column order. The RETURNING shape was driven by
                // `returnNames` which we constructed from
                // `result.columns.map(\.name)` — so the ordering
                // already matches. Just append.
                let newRow = FfiPgRow(cells: inserted.cells)
                storeRef.appendRow(
                    newRow, forTab: tabId, expectedResultGeneration: resultGeneration
                )
                complete(.success(()))
            } catch let err as PostgresBridgeError {
                logger.error("insert_row failed: \(err.localizedDescription, privacy: .public)")
                complete(.failure(NSError(
                    domain: "mc-ssh",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: err.errorDescription ?? "Insert failed."]
                )))
            } catch {
                complete(.failure(error))
            }
        }
    }
}

/// Context passed into the insert-row sheet. Identifiable so
/// `.sheet(item:)` can drive presentation. `columnDetails` is
/// initially nil and filled in asynchronously by a `describe_columns`
/// lookup; the sheet falls back to the metadata-less behavior while
/// the lookup is in flight.
struct InsertSheetContext: Identifiable {
    let id = UUID()
    let tab: PostgresQueryTab
    let target: PostgresEditTarget
    let columns: [FfiPgColumn]
    let returnColumnNames: [String]
    var columnDetails: [FfiPgColumnDetail]?
}
