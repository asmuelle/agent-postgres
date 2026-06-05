import SwiftUI

// =============================================================================
// PgAIErrorExplainView — the "Explain this error" sheet.
//
// Three states map to the store's phase: a thinking state, a structured
// diagnosis, and a failure. The diagnosis is laid out as labelled sections
// with clear scale contrast rather than a uniform card stack, and the
// corrected-SQL block is treated as a first-class, monospaced surface with a
// one-tap "Apply fix" action that writes back into the originating tab.
// =============================================================================

struct PgAIErrorExplainView: View {
    @ObservedObject var store: PgAIErrorExplainStore
    /// Injects a corrected query into the originating tab's editor.
    let onApplyFix: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(20)
            }
        }
        .frame(width: 520, height: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Explain Error")
                    .font(.headline)
                Text("On-device · private")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .thinking:
            thinkingState
        case .result(let diagnosis):
            diagnosisState(diagnosis)
        case .failed(let message):
            failureState(message)
        }
    }

    private var thinkingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Reading your query and schema…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func diagnosisState(_ d: PgErrorDiagnosisResult) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            section(
                icon: "exclamationmark.bubble",
                title: "What happened",
                body: d.diagnosis,
                emphasize: true
            )
            section(icon: "magnifyingglass", title: "Likely cause", body: d.likelyCause)
            section(icon: "wrench.and.screwdriver", title: "Suggested fix", body: d.suggestedFix)

            if let fixed = d.correctedSql {
                correctedSqlBlock(fixed)
            }
        }
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // MARK: - Pieces

    private func section(
        icon: String,
        title: String,
        body: String,
        emphasize: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(body)
                .font(emphasize ? .title3.weight(.medium) : .body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func correctedSqlBlock(_ sql: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Corrected SQL", systemImage: "checkmark.seal")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(sql)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.tint.opacity(0.25), lineWidth: 1)
                )
            HStack {
                Spacer()
                Button {
                    onApplyFix(sql)
                    store.dismiss()
                } label: {
                    Label("Apply fix to editor", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }
}
