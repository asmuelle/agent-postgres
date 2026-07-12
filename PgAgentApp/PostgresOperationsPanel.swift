import AppKit
import SwiftUI

struct PostgresOperationsPanel: View {
    let connectionId: String?

    @State private var operations: [PostgresProgressOperationRecord] = []
    @State private var progressError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            activeOperations
            runbooks
        }
        .task(id: connectionId) {
            while !Task.isCancelled {
                await loadProgress()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var activeOperations: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Active maintenance", systemImage: "gauge.with.dots.needle.50percent")
                .font(.headline)
            if let progressError {
                Text(progressError).font(.caption).foregroundStyle(.secondary)
            } else if operations.isEmpty {
                Text("No VACUUM, ANALYZE, CREATE INDEX, or CLUSTER operation is reporting progress.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(operations) { operation in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(operation.operation.rawValue).font(.caption.bold())
                            Text(operation.target).font(.system(.caption, design: .monospaced))
                            Spacer()
                            if let percent = operation.percentComplete {
                                Text("\(percent, specifier: "%.0f")%")
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                        if let percent = operation.percentComplete {
                            ProgressView(value: percent, total: 100)
                        }
                        Text("PID \(operation.pid) · \(operation.phase)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var runbooks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("DBA runbooks", systemImage: "checklist")
                .font(.headline)
            Text("Evidence first: copy or run the read-only checks, interpret the result, then choose an action deliberately.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(PostgresDBARunbook.catalog) { runbook in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(runbook.steps) { step in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(step.title).font(.caption.bold())
                                    Spacer()
                                    Button("Copy SQL") { copy(step.sql) }
                                        .controlSize(.small)
                                }
                                Text(step.sql)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled).lineLimit(5)
                                Text(step.interpretation)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }.padding(.top, 6)
                } label: {
                    VStack(alignment: .leading) {
                        Text(runbook.title)
                        Text(runbook.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func loadProgress() async {
        guard let connectionId else { return }
        let sessionId = "operations-progress"
        defer {
            Task {
                await BridgeManager.shared.pgReleaseSession(
                    connectionId: connectionId, sessionId: sessionId)
            }
        }
        do {
            let result = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: PostgresProgressSQL.activeOperations,
                pageSize: 100)
            operations = result.rows.compactMap { try? PostgresProgressParser.parse($0.cells) }
            progressError = nil
        } catch {
            progressError = error.localizedDescription
        }
    }

    private func copy(_ sql: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sql, forType: .string)
    }
}
