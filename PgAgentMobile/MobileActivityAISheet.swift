import SwiftUI

// =============================================================================
// MobileActivityAISheet — renders one finished (or in-flight) AI analysis from
// MobileActivityAIStore. Action buttons never act directly: they hand the pid
// back to the activity pane, which routes through its existing confirmation
// alert and biometric gate.
// =============================================================================
struct MobileActivityAISheet: View {
    @ObservedObject var store: MobileActivityAIStore
    /// Route a "cancel this query" recommendation back to the pane's confirm flow.
    let onCancelBackend: (Int32) -> Void
    /// Route a "terminate this backend" recommendation back to the pane's confirm flow.
    let onTerminateBackend: (Int32) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                MidnightColors.primaryBackground.ignoresSafeArea()
                content
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { store.dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var navigationTitle: String {
        if case .done(let insight) = store.phase { return insight.title }
        return "AI Analysis"
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle:
            EmptyView()
        case .running(let label):
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(MidnightColors.accentCyan)
                Text(label)
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                Text("Analyzed on-device — nothing leaves this iPad.")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(32)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        case .done(let insight):
            ScrollView {
                insightBody(insight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
    }

    @ViewBuilder
    private func insightBody(_ insight: MobileActivityInsight) -> some View {
        switch insight {
        case .session(let result, let pid, _):
            VStack(alignment: .leading, spacing: 16) {
                Text(result.summary)
                    .font(MidnightMobileDesign.FontToken.label)
                bulletList(result.points)
                adviceBox(result.advice)
                actionButton(for: result.saferAction, pid: pid)
                advisoryFootnote
            }
        case .blocking(let result):
            VStack(alignment: .leading, spacing: 16) {
                Text(result.explanation)
                    .font(MidnightMobileDesign.FontToken.label)
                adviceBox(result.recommendation)
                if let rootPid = result.rootBlockerPid {
                    Button {
                        store.dismiss()
                        onTerminateBackend(rootPid)
                    } label: {
                        Label("Terminate root blocker · PID \(rootPid)", systemImage: "xmark.octagon.fill")
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                advisoryFootnote
            }
        case .digest(let result), .trend(let result):
            VStack(alignment: .leading, spacing: 16) {
                Text(result.headline)
                    .font(MidnightMobileDesign.FontToken.headline)
                bulletList(result.points)
                advisoryFootnote
            }
        }
    }

    @ViewBuilder
    private func actionButton(for action: PgSessionActionAdvice, pid: Int32) -> some View {
        switch action {
        case .cancel:
            Button {
                store.dismiss()
                onCancelBackend(pid)
            } label: {
                Label("Cancel query · PID \(pid)", systemImage: "stop.circle")
                    .font(MidnightMobileDesign.FontToken.captionStrong)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        case .terminate:
            Button {
                store.dismiss()
                onTerminateBackend(pid)
            } label: {
                Label("Terminate · PID \(pid)", systemImage: "xmark.octagon.fill")
                    .font(MidnightMobileDesign.FontToken.captionStrong)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func bulletList(_ points: [String]) -> some View {
        if !points.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(points, id: \.self) { point in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(MidnightColors.accentCyan)
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(point)
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func adviceBox(_ advice: String) -> some View {
        Text(advice)
            .font(MidnightMobileDesign.FontToken.caption)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MidnightColors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(MidnightColors.borderGray, lineWidth: 1))
    }

    private var advisoryFootnote: some View {
        Text("Generated on-device. Verify before acting — actions always require confirmation.")
            .font(MidnightMobileDesign.FontToken.caption)
            .foregroundStyle(.tertiary)
    }
}
