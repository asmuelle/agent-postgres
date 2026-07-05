import AppKit
import SwiftUI
import UniformTypeIdentifiers

// =============================================================================
// AuditLogSettingsView — the "Audit" tab in Settings. Lists the most
// recent write-audit records (see PostgresAuditLog) and offers a JSONL
// export via NSSavePanel. Read-only viewer: the log itself is append-only
// and never edited from the UI.
// =============================================================================

struct AuditLogSettingsView: View {
    @State private var records: [PostgresAuditRecord] = []
    @State private var isLoading = true
    @State private var exportError: String?

    private static let displayLimit = 200

    var body: some View {
        Form {
            Section {
                Text("Every write executed through pgAgent — SQL writes, grid edits, and transaction control — is recorded locally. Reads are not logged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recent writes (newest first, last \(Self.displayLimit))") {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if records.isEmpty {
                    Text("No writes recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                            recordRow(record)
                        }
                    }
                    .frame(minHeight: 260)
                }
            }

            Section {
                HStack {
                    Button("Export…") { exportLog() }
                        .disabled(records.isEmpty)
                    Button("Refresh") { Task { await reload() } }
                    Spacer()
                    Text(PostgresAuditLog.fileURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(PostgresAuditLog.fileURL.path)
                }
                if let exportError {
                    Text(exportError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
    }

    @ViewBuilder
    private func recordRow(_ record: PostgresAuditRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(record.action.rawValue)
                    .font(.caption.weight(.semibold).monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                Text("\(record.profileName) — \(record.user)@\(record.host)/\(record.database)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if record.outcome == "ok" {
                    if let rows = record.rowsAffected {
                        Text("\(rows) row(s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(record.outcome)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(record.outcome)
                }
                Text(record.ts.formatted(date: .abbreviated, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(record.statement)
                .font(.caption.monospaced())
                .lineLimit(2)
                .truncationMode(.tail)
                .help(record.statement)
        }
        .padding(.vertical, 2)
    }

    private func reload() async {
        isLoading = true
        records = await PostgresAuditLog.shared.recentRecords(limit: Self.displayLimit)
        isLoading = false
    }

    private func exportLog() {
        exportError = nil
        let panel = NSSavePanel()
        panel.title = "Export Audit Log"
        panel.nameFieldStringValue = "pgagent-audit.jsonl"
        panel.allowedContentTypes = [UTType.json, UTType.plainText].compactMap { $0 }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: PostgresAuditLog.fileURL, to: destination)
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }
}
