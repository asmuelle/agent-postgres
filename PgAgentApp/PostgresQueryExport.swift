import AppKit
import OSLog
import PgAgentMacOS
import SwiftUI

// =============================================================================
// PostgresQueryTabView export pipeline — full-result export via cursor
// drain (CSV / JSONL line writer + the stateful Parquet writer path),
// plus the small helper types that glue the pipeline to its progress
// sheet and summary alert.
//
// Extracted from PostgresQueryTabView.swift; behavior-preserving.
// =============================================================================

extension PostgresQueryTabView {
    enum FullExportFormat {
        case csv
        case jsonl
        case parquet
    }

    /// Drains the tab's full result to a user-chosen file. Writes
    /// the currently-loaded rows first, then loops `pgFetchPage` to
    /// stream the rest of the cursor — bounded only by the disk and
    /// the user's patience (no in-memory accumulation past one page).
    /// Cancellable via the progress sheet.
    ///
    /// Format-specific bits (header line, per-row encoding) live in
    /// `format`; the streaming + cancel + cursor-drain orchestration
    /// is shared.
    func runFullExport(tab: PostgresQueryTab, format: FullExportFormat) {
        guard let result = tab.lastResult, let connectionId else {
            exportSummary = ExportSummary(
                title: "Nothing to export",
                message: "Run a query that returns rows, then try again."
            )
            return
        }

        let panel = NSSavePanel()
        switch format {
        case .csv:
            panel.title = "Export full result as CSV"
            panel.nameFieldStringValue = "results.csv"
            panel.allowedContentTypes = [.commaSeparatedText]
        case .jsonl:
            panel.title = "Export full result as JSONL"
            panel.nameFieldStringValue = "results.jsonl"
            // No standard UTType for JSONL; .json is close enough.
            panel.allowedContentTypes = [.json]
        case .parquet:
            panel.title = "Export full result as Parquet"
            panel.nameFieldStringValue = "results.parquet"
            // No system UTType for Parquet; allow any extension.
            panel.allowedContentTypes = [.data]
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Parquet has a different IO model — opaque writer handle,
        // batch append, close-flushes-footer — so it gets its own
        // path. CSV/JSONL share the file-handle line writer below.
        if case .parquet = format {
            runParquetExport(
                tab: tab,
                result: result,
                url: url,
                connectionId: connectionId
            )
            return
        }

        // Plan: visible columns in display order, mapped back to
        // result-column indices (so hidden `__pg_*` columns are
        // skipped consistently).
        let visibleColumns: [(name: String, idx: Int)] = result.columns
            .enumerated()
            .compactMap { (idx, col) -> (String, Int)? in
                if col.name.hasPrefix("__pg_") { return nil }
                return (col.name, idx)
            }
        guard !visibleColumns.isEmpty else {
            exportSummary = ExportSummary(
                title: "Nothing to export",
                message: "No visible columns in the current result."
            )
            return
        }

        // Fresh cancellation token per export. Replace the @State
        // value so a previous export's lingering token can't
        // accidentally pre-cancel this one.
        let token = ExportCancelToken()
        exportCancel = token
        exportProgress = PostgresExportProgressState(path: url, rowsWritten: 0)

        let sessionId = tab.id.uuidString
        let pageSize = store.pageSize
        let initialCursorId = result.cursorId
        let storeRef = store
        let tabId = tab.id
        let preloadedRows = result.rows

        Task { @MainActor in
            var rowsWritten = 0
            // Open / truncate the file. Couldn't do this before the
            // Task because FileHandle init wants the file to exist.
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let writer = try? FileHandle(forWritingTo: url) else {
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Couldn't open file",
                    message: "Failed to create \(url.path) for writing."
                )
                return
            }
            defer { try? writer.close() }

            do {
                // Header. CSV gets one; JSONL doesn't (each row is
                // self-describing because keys ride alongside).
                if case .csv = format {
                    let header = visibleColumns
                        .map { csvEscape($0.name) }
                        .joined(separator: ",") + "\n"
                    try writer.write(contentsOf: Data(header.utf8))
                }

                // Currently-loaded rows.
                for row in preloadedRows {
                    if token.isCancelled { throw ExportCancelled() }
                    let line = renderRow(row, visibleColumns: visibleColumns, format: format)
                    try writer.write(contentsOf: Data(line.utf8))
                    rowsWritten += 1
                    if rowsWritten % 200 == 0 {
                        exportProgress?.rowsWritten = rowsWritten
                        await Task.yield()
                    }
                }

                // Cursor drain.
                var cursorId = initialCursorId
                while let cid = cursorId {
                    if token.isCancelled { throw ExportCancelled() }
                    let page: FfiPgPageResult
                    do {
                        page = try await BridgeManager.shared.pgFetchPage(
                            connectionId: connectionId,
                            sessionId: sessionId,
                            cursorId: cid,
                            count: pageSize
                        )
                    } catch let err as PostgresBridgeError where err.isCursorExpired {
                        // Another tab superseded the cursor mid-drain.
                        // Surface what we got; don't treat as failure.
                        throw ExportCursorSuperseded(rowsWritten: rowsWritten)
                    }
                    // Task cancellation routes through the same cleanup as
                    // the user-facing cancel token.
                    if Task.isCancelled { throw ExportCancelled() }
                    for row in page.rows {
                        if token.isCancelled { throw ExportCancelled() }
                        let line = renderRow(row, visibleColumns: visibleColumns, format: format)
                        try writer.write(contentsOf: Data(line.utf8))
                        rowsWritten += 1
                    }
                    exportProgress?.rowsWritten = rowsWritten
                    if !page.hasMore { break }
                    await Task.yield()
                }

                // Close the cursor server-side; mirror that in the
                // tab so "Load more" hides.
                if let cid = initialCursorId {
                    _ = await BridgeManager.shared.pgCloseQuery(
                        connectionId: connectionId,
                        sessionId: sessionId,
                        cursorId: cid
                    )
                    storeRef.clearCursor(forTab: tabId)
                }

                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Export complete",
                    message: "Wrote \(rowsWritten) row\(rowsWritten == 1 ? "" : "s") to \(url.path)."
                )
            } catch is ExportCancelled {
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Export cancelled",
                    message: "Stopped after \(rowsWritten) row\(rowsWritten == 1 ? "" : "s"). The partial file is at \(url.path)."
                )
            } catch let err as ExportCursorSuperseded {
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Cursor superseded",
                    message: "Another query took over the connection mid-export. \(err.rowsWritten) row\(err.rowsWritten == 1 ? "" : "s") written."
                )
                storeRef.clearCursor(forTab: tabId)
            } catch let err as PostgresBridgeError {
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Export failed",
                    message: err.errorDescription ?? "Unknown error after \(rowsWritten) row\(rowsWritten == 1 ? "" : "s")."
                )
            } catch {
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Export failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    /// Parquet-specific export. Different from CSV/JSONL because
    /// the writer is stateful in Rust (the FFI returns an opaque
    /// id) and rows are appended in batches rather than line by
    /// line. Uses the same progress sheet + cursor-drain shape so
    /// the UX is consistent.
    private func runParquetExport(
        tab: PostgresQueryTab,
        result: FfiPgExecutionResult,
        url: URL,
        connectionId: String
    ) {
        let visibleColumns: [(name: String, idx: Int)] = result.columns
            .enumerated()
            .compactMap { (idx, col) -> (String, Int)? in
                if col.name.hasPrefix("__pg_") { return nil }
                return (col.name, idx)
            }
        guard !visibleColumns.isEmpty else {
            exportSummary = ExportSummary(
                title: "Nothing to export",
                message: "No visible columns in the current result."
            )
            return
        }

        let token = ExportCancelToken()
        exportCancel = token
        exportProgress = PostgresExportProgressState(path: url, rowsWritten: 0)

        let sessionId = tab.id.uuidString
        let pageSize = store.pageSize
        let initialCursorId = result.cursorId
        let storeRef = store
        let tabId = tab.id
        let preloadedRows = result.rows
        let columnNames = visibleColumns.map(\.name)
        let columnIndices = visibleColumns.map(\.idx)

        Task { @MainActor in
            var rowsWritten = 0
            let writerId: UInt64
            do {
                writerId = try await BridgeManager.shared.pgParquetOpen(
                    path: url.path,
                    columns: columnNames
                )
            } catch {
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Couldn't open Parquet file",
                    message: error.localizedDescription
                )
                return
            }

            // Helper: project a row's cells to the visible-columns
            // subset, in display order.
            func projected(_ row: FfiPgRow) -> FfiPgRow {
                let cells = columnIndices.map { idx -> String? in
                    idx < row.cells.count ? row.cells[idx] : nil
                }
                return FfiPgRow(cells: cells)
            }

            // Append in chunks so cancel checks fire between batches.
            // 500-row batches keep the writer-side memory bounded.
            let batchSize = 500

            do {
                // Preloaded rows.
                var i = 0
                while i < preloadedRows.count {
                    if token.isCancelled { throw ExportCancelled() }
                    let end = min(i + batchSize, preloadedRows.count)
                    let batch = preloadedRows[i..<end].map(projected)
                    try await BridgeManager.shared.pgParquetAppend(
                        writerId: writerId, rows: batch
                    )
                    rowsWritten += batch.count
                    exportProgress?.rowsWritten = rowsWritten
                    i = end
                    await Task.yield()
                }

                // Cursor drain.
                var cursorId = initialCursorId
                while let cid = cursorId {
                    if token.isCancelled { throw ExportCancelled() }
                    let page: FfiPgPageResult
                    do {
                        page = try await BridgeManager.shared.pgFetchPage(
                            connectionId: connectionId,
                            sessionId: sessionId,
                            cursorId: cid,
                            count: pageSize
                        )
                    } catch let err as PostgresBridgeError where err.isCursorExpired {
                        throw ExportCursorSuperseded(rowsWritten: rowsWritten)
                    }
                    // Task cancellation routes through the same cleanup as
                    // the user-facing cancel token.
                    if Task.isCancelled { throw ExportCancelled() }
                    let batch = page.rows.map(projected)
                    if !batch.isEmpty {
                        try await BridgeManager.shared.pgParquetAppend(
                            writerId: writerId, rows: batch
                        )
                        rowsWritten += batch.count
                        exportProgress?.rowsWritten = rowsWritten
                    }
                    if !page.hasMore { break }
                    await Task.yield()
                }

                // Close + clear cursor.
                try await BridgeManager.shared.pgParquetClose(writerId: writerId)
                if let cid = initialCursorId {
                    _ = await BridgeManager.shared.pgCloseQuery(
                        connectionId: connectionId,
                        sessionId: sessionId,
                        cursorId: cid
                    )
                    storeRef.clearCursor(forTab: tabId)
                }
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Export complete",
                    message: "Wrote \(rowsWritten) row\(rowsWritten == 1 ? "" : "s") to \(url.path)."
                )
            } catch is ExportCancelled {
                _ = try? await BridgeManager.shared.pgParquetClose(writerId: writerId)
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Export cancelled",
                    message: "Stopped after \(rowsWritten) row\(rowsWritten == 1 ? "" : "s"). Partial Parquet file at \(url.path)."
                )
            } catch let err as ExportCursorSuperseded {
                _ = try? await BridgeManager.shared.pgParquetClose(writerId: writerId)
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Cursor superseded",
                    message: "Another query took over the connection mid-export. \(err.rowsWritten) row(s) written."
                )
                storeRef.clearCursor(forTab: tabId)
            } catch let err as PostgresBridgeError {
                _ = try? await BridgeManager.shared.pgParquetClose(writerId: writerId)
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Export failed",
                    message: err.errorDescription ?? "Unknown error after \(rowsWritten) row(s)."
                )
            } catch {
                _ = try? await BridgeManager.shared.pgParquetClose(writerId: writerId)
                exportProgress = nil
                exportSummary = ExportSummary(
                    title: "Export failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    /// Format-aware row rendering for the streaming export.
    private func renderRow(
        _ row: FfiPgRow,
        visibleColumns: [(name: String, idx: Int)],
        format: FullExportFormat
    ) -> String {
        switch format {
        case .parquet:
            // Parquet doesn't go through the line-renderer; this
            // branch shouldn't run because `runFullExport` routes
            // Parquet to its own pipeline. Returning empty avoids
            // a compiler exhaustiveness gap without being a real
            // code path.
            return ""
        case .csv:
            let parts = visibleColumns.map { plan -> String in
                guard plan.idx < row.cells.count else { return "" }
                // NULL → empty field (CSV convention).
                return row.cells[plan.idx].map(csvEscape) ?? ""
            }
            return parts.joined(separator: ",") + "\n"
        case .jsonl:
            // One JSON object per line, key-ordered by visible
            // column. Values: string for text representations, null
            // for SQL NULL. We don't try to coerce text back to
            // typed JSON values (number / bool) because that would
            // need per-column type inspection plus careful parsing
            // — a meaningful slice on its own. Strings round-trip
            // every type the server can serialize.
            var obj: [String: Any?] = [:]
            for plan in visibleColumns {
                guard plan.idx < row.cells.count else { continue }
                if let value = row.cells[plan.idx] {
                    obj[plan.name] = value
                } else {
                    obj[plan.name] = nil
                }
            }
            // JSONSerialization handles nil → null when wrapped
            // through NSNull; transform once.
            let nsObj = obj.mapValues { $0 as Any? ?? NSNull() }
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: nsObj,
                    options: [.sortedKeys]
                )
                if var line = String(data: data, encoding: .utf8) {
                    line.append("\n")
                    return line
                }
                return "{}\n"
            } catch {
                return "{}\n"
            }
        }
    }

    /// RFC 4180 quoting. Identical to the coordinator's helper but
    /// duplicated here so the export path stays self-contained.
    private func csvEscape(_ s: String) -> String {
        let needs = s.contains(",") || s.contains("\"")
            || s.contains("\n") || s.contains("\r")
        if !needs { return s }
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

// =============================================================================
// Export helpers — glue between `runFullExport`, its progress sheet,
// and the result alert.
// =============================================================================

/// Reference-typed cancel flag observed by the export task between
/// page fetches. Reference type so `@State` value-copy semantics
/// don't silently drop signals when the parent view re-renders.
final class ExportCancelToken {
    private(set) var isCancelled: Bool = false
    func cancel() { isCancelled = true }
}

/// Sentinel thrown to break out of the export loop on user cancel.
private struct ExportCancelled: Error {}

/// Sentinel thrown when another session supersedes the cursor
/// mid-drain. Carries the row count so the alert can include it.
private struct ExportCursorSuperseded: Error {
    let rowsWritten: Int
}

/// One-shot summary alert presented after an export ends. Identifiable
/// so SwiftUI's `.alert(presenting:)` modifier can drive it.
struct ExportSummary: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
