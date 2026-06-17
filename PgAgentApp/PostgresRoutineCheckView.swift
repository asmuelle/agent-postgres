#if os(macOS)
import AppKit
import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresRoutineCheckView — inline plpgsql_check diagnostics panel (Slice 4).
// Sits below the Source editor. Probes for the extension, runs the check for
// the exact overload, and lists findings; clicking one jumps the editor to the
// offending body line via `onJump`. Re-runs on load and whenever `refreshToken`
// changes (the editor bumps it after a successful Apply).
//
// Degrades gracefully: a clear note when the extension isn't installed (common
// on managed Postgres without it), and a tidy "no problems" when clean.
// =============================================================================

struct PostgresRoutineCheckView: View {
    let connectionId: String?
    let schema: String
    let name: String
    let signature: String
    /// Changing this re-runs the check (the editor bumps it after Apply).
    var refreshToken: Int = 0
    /// Called with a 1-based body line number when a finding is clicked.
    var onJump: (Int) -> Void = { _ in }

    private enum Phase: Equatable {
        case loading
        case notInstalled
        case done
        case error(String)
    }

    @State private var phase: Phase = .loading
    @State private var findings: [RoutineCheckFinding] = []
    @State private var generation = 0

    private var errorCount: Int { findings.filter { $0.level == .error }.count }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            header
            if case .done = phase, !findings.isEmpty {
                Divider()
                findingsList
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .task(id: "\(connectionId ?? "-")|\(schema).\(name)(\(signature))|\(refreshToken)") {
            await run()
        }
    }

    // MARK: - Header / summary

    private var header: some View {
        HStack(spacing: 8) {
            summary
            Spacer()
            Button {
                Task { await run() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .help("Re-run plpgsql_check")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var summary: some View {
        switch phase {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            }
        case .notInstalled:
            Label(
                "plpgsql_check not installed — install it to catch errors CREATE FUNCTION accepts.",
                systemImage: "stethoscope"
            )
            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case .error(let msg):
            Label("Check failed: \(msg)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).lineLimit(2)
        case .done:
            if findings.isEmpty {
                Label("No problems found", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                let warnings = findings.count - errorCount
                Label(summaryText(errors: errorCount, warnings: warnings),
                      systemImage: errorCount > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(errorCount > 0 ? .red : .orange)
            }
        }
    }

    private func summaryText(errors: Int, warnings: Int) -> String {
        var parts: [String] = []
        if errors > 0 { parts.append("\(errors) error\(errors == 1 ? "" : "s")") }
        if warnings > 0 { parts.append("\(warnings) warning\(warnings == 1 ? "" : "s")") }
        return "plpgsql_check: " + parts.joined(separator: ", ")
    }

    // MARK: - Findings

    private var findingsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(findings) { finding in
                    findingRow(finding)
                    Divider().padding(.leading, 12)
                }
            }
        }
        .frame(maxHeight: 180)
    }

    private func findingRow(_ finding: RoutineCheckFinding) -> some View {
        let (icon, tint) = style(for: finding.level)
        return Button {
            if let line = finding.lineno { onJump(line) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint).font(.caption)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let line = finding.lineno {
                            Text("Line \(line)")
                                .font(.caption2.monospaced().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        if let sqlstate = finding.sqlstate {
                            Text(sqlstate)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(finding.message)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = finding.detail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let hint = finding.hint {
                        Text(hint).font(.caption2).foregroundStyle(.blue)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(finding.lineno != nil ? "Jump to line \(finding.lineno!)" : "")
    }

    private func style(for level: RoutineCheckFinding.Level) -> (String, Color) {
        switch level {
        case .error:       return ("xmark.octagon.fill", .red)
        case .warning:     return ("exclamationmark.triangle.fill", .orange)
        case .performance: return ("speedometer", .blue)
        case .other:       return ("info.circle.fill", .secondary)
        }
    }

    // MARK: - Run

    private func run() async {
        guard let connectionId else { phase = .error("Not connected."); return }
        generation += 1
        let gen = generation
        phase = .loading
        let sessionId = "routine-check-\(UUID().uuidString)"

        let result: Result<[RoutineCheckFinding], Error>
        var installed = false
        do {
            let probeRows = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId, sessionId: sessionId,
                sql: PostgresRoutineCheck.probeQuery(schema: schema, name: name, signature: signature),
                pageSize: 1)
            let probe = PostgresRoutineCheck.parseProbe(row: probeRows.rows.first?.cells)
            installed = probe?.hasExtension ?? false
            if installed {
                let checkRows = try await BridgeManager.shared.pgExecute(
                    connectionId: connectionId, sessionId: sessionId,
                    sql: PostgresRoutineCheck.checkQuery(schema: schema, name: name, signature: signature),
                    pageSize: 500)
                result = .success(PostgresRoutineCheck.parseFindings(rows: checkRows.rows.map(\.cells)))
            } else {
                result = .success([])
            }
        } catch {
            result = .failure(error)
        }
        await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
        guard gen == generation else { return }

        switch result {
        case .success(let f):
            findings = f
            phase = installed ? .done : .notInstalled
        case .failure(let error):
            findings = []
            phase = .error((error as? PostgresBridgeError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
#endif
