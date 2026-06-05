import SwiftUI

// =============================================================================
// PgAIExplainView — streaming "Explain query & results" sheet.
//
// Renders the store's snapshot stream: the summary and bullet points fill in
// progressively while `.streaming`, with a live indicator that disappears on
// `.done`. Empty partial fields are simply not shown yet, so the panel grows
// rather than flickering.
// =============================================================================

struct PgAIExplainView: View {
    @ObservedObject var store: PgAIExplainStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .frame(width: 540, height: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.title)
                    .font(.headline)
                Text("On-device · private")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isStreaming {
                ProgressView().controlSize(.small)
            }
            Button { store.dismiss() } label: {
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

    private var isStreaming: Bool {
        if case .streaming = store.phase { return true }
        return false
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle:
            EmptyView()
        case .streaming(let partial), .done(let partial):
            explanation(partial)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func explanation(_ result: PgExplanationResult) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if result.summary.isEmpty && result.points.isEmpty && isStreaming {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading your query…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !result.summary.isEmpty {
                Text(result.summary)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !result.points.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(result.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundStyle(.tint)
                                .padding(.top, 6)
                            Text(point)
                                .font(.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
