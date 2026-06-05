import SwiftUI

// =============================================================================
// PostgresExportProgressSheet — small modal shown while a full-result
// CSV export is in flight.
//
// Indeterminate progress (we don't know the total row count up front),
// live row counter, and a Cancel button. The cancel signal is a
// plain `() -> Void` callback wired by the host to a cancellation
// token that the export task observes between page fetches.
//
// The sheet stays open until the host clears its `exportProgress`
// state; the host shows a one-shot summary alert after dismissal.
// =============================================================================

/// Live state for the progress sheet. Mutated on the main actor as
/// rows stream to disk; the parent view's `@State` of this struct
/// drives re-renders.
struct PostgresExportProgressState: Equatable {
    var path: URL
    var rowsWritten: Int = 0
    var isCancelling: Bool = false
}

struct PostgresExportProgressSheet: View {
    let state: PostgresExportProgressState
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tint)

            VStack(spacing: 4) {
                Text(state.isCancelling ? "Stopping export…" : "Exporting full result…")
                    .font(.headline)
                Text(state.path.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            ProgressView()
                .progressViewStyle(.linear)
                .frame(width: 220)

            Text(rowSummary)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Button(state.isCancelling ? "Cancelling…" : "Cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(state.isCancelling)
        }
        .padding(24)
        .frame(width: 320)
    }

    private var rowSummary: String {
        let n = state.rowsWritten
        if n == 0 { return "Starting…" }
        if n == 1 { return "1 row written" }
        return "\(n) rows written"
    }
}
