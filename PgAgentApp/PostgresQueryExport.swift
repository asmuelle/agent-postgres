import AppKit
import OSLog
import PgAgentMacOS
import SwiftUI

// =============================================================================
// PostgresQueryTabView export pipeline — full-result export via cursor
// drain (CSV / JSONL line writer + the stateful Parquet writer), run by a
// background worker, plus the small helper types that glue the pipeline
// to its progress sheet and summary alert.
// =============================================================================

extension PostgresQueryTabView {
    enum FullExportFormat: Sendable, Equatable {
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
    /// Format-specific bits (header line, per-row encoding, Parquet
    /// writer) live in the sink; the streaming + cancel + cursor-drain
    /// orchestration in `PostgresExportWorker` is shared.
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

        let plan = PostgresExportColumnPlan(resultColumnNames: result.columns.map(\.name))
        guard !plan.isEmpty else {
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

        let job = PostgresExportJob(
            url: url,
            format: format,
            plan: plan,
            preloadedRows: result.rows,
            connectionId: connectionId,
            sessionId: tab.id.uuidString,
            pageSize: store.pageSize,
            cursorId: result.cursorId
        )
        let storeRef = store
        let tabId = tab.id

        // Only the throttled progress ticks and the final summary touch
        // the main actor; row rendering, file writes and FFI calls all
        // run in the worker off-main.
        Task { @MainActor in
            let report = await PostgresExportWorker.run(job: job, token: token) { rows in
                exportProgress?.rowsWritten = rows
            }
            // The cursor was closed by the export (or expired under
            // it) — mirror that in the tab so "Load more" hides.
            if report.cursorReleased {
                storeRef.clearCursor(forTab: tabId)
            }
            exportProgress = nil
            exportSummary = report.outcome.summary(path: url.path, format: format)
        }
    }
}

// =============================================================================
// Background export worker — drains the preloaded rows + the cursor into
// a sink (line file for CSV/JSONL, the Rust Parquet writer for Parquet).
// Touches the main actor only through the throttled progress callback.
// =============================================================================

/// Everything the background export needs, captured on the main actor.
struct PostgresExportJob: Sendable {
    let url: URL
    let format: PostgresQueryTabView.FullExportFormat
    let plan: PostgresExportColumnPlan
    let preloadedRows: [FfiPgRow]
    let connectionId: String
    let sessionId: String
    let pageSize: UInt32
    let cursorId: String?
}

enum PostgresExportOutcome: Sendable, Equatable {
    case completed(rows: Int)
    case cancelled(rows: Int)
    case superseded(rows: Int)
    case openFailed(message: String)
    case failed(rows: Int, message: String?)

    func summary(path: String, format: PostgresQueryTabView.FullExportFormat) -> ExportSummary {
        switch self {
        case .completed(let n):
            return ExportSummary(title: "Export complete", message: "Wrote \(Self.rows(n)) to \(path).")
        case .cancelled(let n):
            let partial = format == .parquet
                ? "Partial Parquet file at \(path)."
                : "The partial file is at \(path)."
            return ExportSummary(title: "Export cancelled", message: "Stopped after \(Self.rows(n)). \(partial)")
        case .superseded(let n):
            return ExportSummary(
                title: "Cursor superseded",
                message: "Another query took over the connection mid-export. \(Self.rows(n)) written."
            )
        case .openFailed(let message):
            return ExportSummary(
                title: format == .parquet ? "Couldn't open Parquet file" : "Couldn't open file",
                message: message
            )
        case .failed(let n, let message):
            return ExportSummary(title: "Export failed", message: message ?? "Unknown error after \(Self.rows(n)).")
        }
    }

    private static func rows(_ n: Int) -> String {
        "\(n) row\(n == 1 ? "" : "s")"
    }
}

struct PostgresExportReport: Sendable {
    let outcome: PostgresExportOutcome
    /// The tab's server-side cursor is gone (closed here, or expired).
    let cursorReleased: Bool
}

enum PostgresExportWorker {
    /// Preloaded rows are appended in chunks so cancel checks and
    /// progress ticks fire between them; also bounds the Parquet
    /// writer's per-call memory.
    static let batchSize = 500
    /// Minimum spacing between progress hops to the main actor.
    static let progressInterval: Duration = .milliseconds(100)

    /// Runs the export on the global concurrent executor. Never throws:
    /// every exit path closes the sink (file handle / Parquet writer)
    /// and maps to an outcome.
    @concurrent
    static func run(
        job: PostgresExportJob,
        token: ExportCancelToken,
        onProgress: @escaping @MainActor (Int) -> Void
    ) async -> PostgresExportReport {
        let sink: any PostgresExportSink
        do {
            sink = try await openSink(for: job)
        } catch {
            let message = job.format == .parquet
                ? error.localizedDescription
                : "Failed to create \(job.url.path) for writing."
            return PostgresExportReport(outcome: .openFailed(message: message), cursorReleased: false)
        }

        var rowsWritten = 0
        // Whether this export consumed cursor rows. A cancel / failure
        // before the first fetch leaves the tab's cursor usable.
        var fetchedFromCursor = false
        let clock = ContinuousClock()
        var lastProgress = clock.now

        func tick() async {
            let now = clock.now
            guard now - lastProgress >= progressInterval else { return }
            lastProgress = now
            await onProgress(rowsWritten)
        }

        do {
            var start = 0
            while start < job.preloadedRows.count {
                try checkCancelled(token)
                let end = min(start + batchSize, job.preloadedRows.count)
                try await sink.append(job.preloadedRows[start..<end])
                rowsWritten += end - start
                start = end
                await tick()
            }

            var cursorId = job.cursorId
            while let cid = cursorId {
                try checkCancelled(token)
                let page: FfiPgPageResult
                do {
                    page = try await BridgeManager.shared.pgFetchPage(
                        connectionId: job.connectionId,
                        sessionId: job.sessionId,
                        cursorId: cid,
                        count: job.pageSize
                    )
                } catch let err as PostgresBridgeError where err.isCursorExpired {
                    // Another tab superseded the cursor mid-drain.
                    // Surface what we got; don't treat as failure.
                    throw ExportCursorSuperseded()
                }
                fetchedFromCursor = true
                try checkCancelled(token)
                if !page.rows.isEmpty {
                    try await sink.append(page.rows[...])
                    rowsWritten += page.rows.count
                    await tick()
                }
                cursorId = page.hasMore ? cid : nil
            }

            try await sink.finish()
            let released = await closeCursor(job, when: job.cursorId != nil)
            return PostgresExportReport(outcome: .completed(rows: rowsWritten), cursorReleased: released)
        } catch is ExportCancelled {
            await sink.abort()
            let released = await closeCursor(job, when: fetchedFromCursor)
            return PostgresExportReport(outcome: .cancelled(rows: rowsWritten), cursorReleased: released)
        } catch is ExportCursorSuperseded {
            await sink.abort()
            return PostgresExportReport(outcome: .superseded(rows: rowsWritten), cursorReleased: true)
        } catch {
            await sink.abort()
            let released = await closeCursor(job, when: fetchedFromCursor)
            // nil → the summary's "Unknown error after N rows" fallback.
            let message: String? = if let bridgeError = error as? PostgresBridgeError {
                bridgeError.errorDescription
            } else {
                error.localizedDescription
            }
            return PostgresExportReport(
                outcome: .failed(rows: rowsWritten, message: message),
                cursorReleased: released
            )
        }
    }

    /// User cancel (sheet button) and Task cancellation share one path.
    private static func checkCancelled(_ token: ExportCancelToken) throws {
        if token.isCancelled || Task.isCancelled { throw ExportCancelled() }
    }

    /// Best-effort server-side cursor close. Returns whether the tab
    /// should drop its cursor.
    private static func closeCursor(_ job: PostgresExportJob, when condition: Bool) async -> Bool {
        guard condition, let cid = job.cursorId else { return false }
        _ = await BridgeManager.shared.pgCloseQuery(
            connectionId: job.connectionId,
            sessionId: job.sessionId,
            cursorId: cid
        )
        return true
    }

    private static func openSink(for job: PostgresExportJob) async throws -> any PostgresExportSink {
        switch job.format {
        case .csv, .jsonl:
            return try PostgresLineFileSink(url: job.url, format: job.format, plan: job.plan)
        case .parquet:
            return try await PostgresParquetSink.open(url: job.url, plan: job.plan)
        }
    }
}

/// Destination of a streaming export. Driven by a single task only.
protocol PostgresExportSink: AnyObject {
    func append(_ rows: ArraySlice<FfiPgRow>) async throws
    /// Flush + close; an error here fails the export.
    func finish() async throws
    /// Close after cancel / error, leaving the partial output in place.
    func abort() async
}

/// CSV / JSONL: renders each batch into one string and writes it with a
/// single `FileHandle.write`.
final class PostgresLineFileSink: PostgresExportSink {
    private let handle: FileHandle
    private let plan: PostgresExportColumnPlan
    private let isCSV: Bool
    private var isClosed = false

    init(url: URL, format: PostgresQueryTabView.FullExportFormat, plan: PostgresExportColumnPlan) throws {
        // Open / truncate. FileHandle(forWritingTo:) needs the file to exist.
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
        self.plan = plan
        isCSV = format == .csv
        // Header. CSV gets one; JSONL doesn't (each row is
        // self-describing because keys ride alongside).
        if isCSV {
            do {
                try handle.write(contentsOf: Data(plan.csvHeaderLine.utf8))
            } catch {
                try? handle.close()
                isClosed = true
                throw error
            }
        }
    }

    deinit {
        if !isClosed { try? handle.close() }
    }

    func append(_ rows: ArraySlice<FfiPgRow>) throws {
        var chunk = String()
        for row in rows {
            chunk += isCSV ? plan.csvLine(row.cells) : plan.jsonlLine(row.cells)
        }
        try handle.write(contentsOf: Data(chunk.utf8))
    }

    func finish() throws {
        isClosed = true
        try handle.close()
    }

    func abort() {
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }
}

/// Parquet: the writer is stateful in Rust (opaque id); rows are
/// projected to the visible columns and appended in batches, and
/// closing flushes the footer.
final class PostgresParquetSink: PostgresExportSink {
    private let writerId: UInt64
    private let plan: PostgresExportColumnPlan
    private var isClosed = false

    private init(writerId: UInt64, plan: PostgresExportColumnPlan) {
        self.writerId = writerId
        self.plan = plan
    }

    static func open(url: URL, plan: PostgresExportColumnPlan) async throws -> PostgresParquetSink {
        let id = try await BridgeManager.shared.pgParquetOpen(path: url.path, columns: plan.names)
        return PostgresParquetSink(writerId: id, plan: plan)
    }

    func append(_ rows: ArraySlice<FfiPgRow>) async throws {
        let batch = rows.map { FfiPgRow(cells: plan.project($0.cells)) }
        try await BridgeManager.shared.pgParquetAppend(writerId: writerId, rows: batch)
    }

    func finish() async throws {
        isClosed = true
        try await BridgeManager.shared.pgParquetClose(writerId: writerId)
    }

    func abort() async {
        guard !isClosed else { return }
        isClosed = true
        _ = try? await BridgeManager.shared.pgParquetClose(writerId: writerId)
    }
}

// =============================================================================
// Export helpers — glue between `runFullExport`, its progress sheet,
// and the result alert.
// =============================================================================

/// Reference-typed cancel flag observed by the export worker between
/// batches. Reference type so `@State` value-copy semantics don't
/// silently drop signals when the parent view re-renders. Set on the
/// main actor, read by the background worker — hence the lock.
final class ExportCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Sentinel thrown to break out of the export loop on user cancel.
private struct ExportCancelled: Error {}

/// Sentinel thrown when another session supersedes the cursor mid-drain.
private struct ExportCursorSuperseded: Error {}

/// One-shot summary alert presented after an export ends. Identifiable
/// so SwiftUI's `.alert(presenting:)` modifier can drive it.
struct ExportSummary: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}
