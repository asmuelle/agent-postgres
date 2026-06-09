import SwiftUI

// =============================================================================
// PostgresTransactionBar — compact transaction control + status strip shown
// directly above the SQL editor.
//
// Honest about provenance: Postgres exposes no transaction status over this
// path, so the state is tracked client-side (these controls + leading-keyword
// and SQLSTATE-25 detection on execution). When idle it offers a "Begin Tx"
// affordance; when a transaction is open or aborted it shows a colored banner
// with Commit / Rollback.
// =============================================================================

struct PostgresTransactionBar: View {
    let state: PgTransactionState
    let isConnected: Bool
    let onBegin: () -> Void
    let onCommit: () -> Void
    let onRollback: () -> Void

    var body: some View {
        switch state {
        case .none:
            idleControls
        case .open:
            banner(
                failed: false,
                text: "Transaction open — changes are uncommitted",
                accent: .orange
            )
        case .failed:
            banner(
                failed: true,
                text: "Transaction aborted — roll back to continue",
                accent: .red
            )
        }
    }

    private var idleControls: some View {
        HStack(spacing: 6) {
            Button(action: onBegin) {
                Label("Begin Tx", systemImage: "arrow.triangle.branch")
            }
            .controlSize(.small)
            .disabled(!isConnected)
            .help("Start an explicit transaction on this tab's session")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func banner(failed: Bool, text: String, accent: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "circle.fill")
                .font(.caption2)
                .foregroundStyle(accent)
            Text(text)
                .font(.caption)
            Spacer()
            if !failed {
                Button("Commit", action: onCommit)
                    .controlSize(.small)
            }
            Button("Rollback", role: .destructive, action: onRollback)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(accent.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
