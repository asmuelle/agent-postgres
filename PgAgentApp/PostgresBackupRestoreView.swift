import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// A durable PostgreSQL 14+ backup executor. Work runs remotely through the
// profile's SSH host, credentials come from that host's ~/.pgpass, archive
// output is atomic + verified, and every finished job records evidence.
struct PostgresBackupRestoreView: View {
    let profile: PostgresProfile
    @Environment(\.dismiss) private var dismiss

    @State private var activeTab = "Backup"
    @State private var backupPath = "/var/backups/postgresql/db_backup.dump"
    @State private var backupFormat = PostgresBackupFormat.custom
    @State private var backupDataOnly = false
    @State private var backupSchemaOnly = false
    @State private var backupClean = false
    @State private var restorePath = "/var/backups/postgresql/db_backup.dump"
    @State private var restoreFormat = PostgresBackupFormat.custom
    @State private var restoreClean = false
    @State private var restoreSingleTransaction = true

    @State private var consoleLogs = ""
    @State private var phase = "Ready"
    @State private var isExecuting = false
    @State private var executionSuccess: Bool?
    @State private var currentToken: String?
    @State private var currentLiveSshId: String?
    @State private var currentJobId: String?
    @State private var jobTask: Task<Void, Never>?
    @State private var history: [PostgresBackupJobRecord] = []
    @State private var showingRestoreConfirmation = false
    @State private var restorePhrase = ""

    private let jobStore = PostgresBackupJobStore()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if let sshId = profile.tunnel?.sshConnectionId, !sshId.isEmpty {
                mainContent(sshId: sshId)
            } else {
                sshMissingState
            }
        }
        .background(MidnightMacDesign.ColorToken.windowBackground)
        .frame(minWidth: 760, minHeight: 560)
        .task { await loadHistory() }
        .sheet(isPresented: $showingRestoreConfirmation) {
            restoreConfirmation
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Backup Executor").font(MidnightMacDesign.FontToken.title)
                Text("\(profile.database) on \(profile.host) · PostgreSQL 14+")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
            }
            Spacer()
            Picker("", selection: $activeTab) {
                Text("Backup").tag("Backup")
                Text("Restore").tag("Restore")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            .disabled(isExecuting)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var sshMissingState: some View {
        VStack(spacing: 16) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 48)).foregroundStyle(.orange)
            Text("SSH execution host required").font(.title3)
            Text("Assign an SSH execution host to this PostgreSQL profile. pgAgent runs pg_dump, pg_restore, and psql there. For a directly managed cloud database, use a small runner or jump host that can reach its endpoint.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            Button("Dismiss") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func mainContent(sshId: String) -> some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    credentialNotice
                    if activeTab == "Backup" { backupForm } else { restoreForm }
                    Divider()
                    HStack {
                        Button("Close") { dismiss() }.disabled(isExecuting)
                        if isExecuting {
                            Button("Cancel Job", role: .destructive) { cancelCurrentJob() }
                        }
                        Spacer()
                        Button(activeTab == "Backup" ? "Start Verified Backup" : "Start Restore") {
                            requestExecution(sshId: sshId)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(activeTab == "Restore" ? .orange : .blue)
                        .disabled(isExecuting || selectedPath.isEmpty || invalidBackupOptions)
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 360)

            VStack(spacing: 0) {
                consolePanel
                Divider()
                historyPanel.frame(height: 190)
            }
            .frame(minWidth: 360)
        }
    }

    private var credentialNotice: some View {
        Label {
            Text("The SSH host must have a mode-0600 ~/.pgpass entry for this database. pgAgent never sends database passwords in shell commands.")
        } icon: {
            Image(systemName: "key.fill")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(10).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var backupForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BACKUP DESTINATION").font(MidnightMacDesign.FontToken.label)
            TextField("Remote destination", text: $backupPath)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            formatPicker("Format", selection: $backupFormat)
            Toggle("Data only", isOn: $backupDataOnly).toggleStyle(.checkbox)
            Toggle("Schema only", isOn: $backupSchemaOnly).toggleStyle(.checkbox)
            Toggle("Include clean/drop statements", isOn: $backupClean).toggleStyle(.checkbox)
            if invalidBackupOptions {
                Text("Data-only and schema-only cannot both be enabled.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var restoreForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RESTORE SOURCE").font(MidnightMacDesign.FontToken.label)
            TextField("Remote source", text: $restorePath)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            formatPicker("Archive format", selection: $restoreFormat)
            Toggle("Clean before restore", isOn: $restoreClean).toggleStyle(.checkbox)
            Toggle("Single transaction", isOn: $restoreSingleTransaction).toggleStyle(.checkbox)
            Label("The archive is preflighted before any restore SQL runs. Plain SQL uses ON_ERROR_STOP and ignores remote psqlrc files.", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func formatPicker(
        _ title: String, selection: Binding<PostgresBackupFormat>
    ) -> some View {
        Picker(title, selection: selection) {
            Text("Custom (compressed)").tag(PostgresBackupFormat.custom)
            Text("Tar archive").tag(PostgresBackupFormat.tar)
            Text("Plain SQL").tag(PostgresBackupFormat.plain)
        }.pickerStyle(.menu)
    }

    private var consolePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "terminal.fill")
                Text(phase.uppercased()).font(MidnightMacDesign.FontToken.label)
                Spacer()
                if isExecuting { ProgressView().controlSize(.small) }
                if let executionSuccess {
                    Label(executionSuccess ? "VERIFIED" : "FAILED",
                          systemImage: executionSuccess ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .font(.caption.bold()).foregroundStyle(executionSuccess ? .green : .red)
                }
            }
            .padding(10).background(MidnightMacDesign.ColorToken.controlBackground)
            ScrollView {
                Text(consoleLogs.isEmpty ? "Preflight and job output will appear here." : consoleLogs)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).padding()
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .background(MidnightMacDesign.ColorToken.textBackground)
        }
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECENT JOB EVIDENCE").font(MidnightMacDesign.FontToken.label).padding(.horizontal, 10)
            if history.isEmpty {
                Text("No completed jobs for this profile.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            } else {
                List(history.prefix(5)) { job in
                    HStack {
                        Image(systemName: job.state == .succeeded ? "checkmark.seal.fill" : "xmark.circle.fill")
                            .foregroundStyle(job.state == .succeeded ? .green : .red)
                        VStack(alignment: .leading) {
                            Text("\(job.kind.rawValue.capitalized) · \(job.path)").lineLimit(1)
                            if let evidence = job.evidence {
                                Text("\(ByteCountFormatter.string(fromByteCount: evidence.sizeBytes, countStyle: .file)) · SHA-256 \(evidence.sha256.prefix(12))…")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(job.message ?? job.state.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    private var restoreConfirmation: some View {
        let challenge = PostgresRestorePolicy.challenge(
            database: profile.database,
            isProduction: profile.effectiveEnvironment == .production)
        return VStack(alignment: .leading, spacing: 14) {
            Label("Restore can overwrite database objects", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text("Target: \(profile.name) · \(profile.database)")
            if let required = challenge.requiredPhrase {
                Text("Type \(required) to continue.").font(.caption)
                TextField(required, text: $restorePhrase).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { showingRestoreConfirmation = false }
                Button("Run Restore", role: .destructive) {
                    showingRestoreConfirmation = false
                    if let sshId = profile.tunnel?.sshConnectionId { startExecution(sshId: sshId) }
                }
                .disabled(!challenge.accepts(restorePhrase))
            }
        }
        .padding(22).frame(width: 470)
    }

    private var selectedPath: String { activeTab == "Backup" ? backupPath : restorePath }
    private var invalidBackupOptions: Bool {
        activeTab == "Backup" && backupDataOnly && backupSchemaOnly
    }

    private func requestExecution(sshId: String) {
        if activeTab == "Restore" {
            restorePhrase = ""
            showingRestoreConfirmation = true
        } else {
            startExecution(sshId: sshId)
        }
    }

    private func startExecution(sshId: String) {
        guard !isExecuting else { return }
        isExecuting = true
        executionSuccess = nil
        phase = "Resolving SSH host"
        consoleLogs = ""
        let token = UUID().uuidString.lowercased()
        let jobId = UUID().uuidString
        currentToken = token
        currentJobId = jobId
        let startedAt = Date()

        jobTask = Task {
            do {
                let liveSshId = try await SSHTunnelResolver.liveConnectionId(
                    forSSHProfileReference: sshId)
                currentLiveSshId = liveSshId
                let (kind, path, preflight, command) = makeCommands()
                phase = "Preflight"
                let preflightOutput = try await BridgeManager.shared.executeCommand(
                    connectionId: liveSshId, command: preflight)
                consoleLogs = preflightOutput

                let running = jobRecord(
                    id: jobId, kind: kind, path: path, startedAt: startedAt,
                    state: .running, evidence: nil, message: "Remote token \(token)")
                try? await jobStore.append(running)

                phase = kind == .backup ? "Backup running" : "Restore running"
                _ = try await BridgeManager.shared.executeCommand(
                    connectionId: liveSshId,
                    command: PostgresRemoteJobProtocol.launch(token: token, command: command))
                let result = try await pollJob(
                    liveSshId: liveSshId, token: token, preflightOutput: preflightOutput)
                guard !Task.isCancelled else { return }

                if result.exitCode == 0 {
                    let evidence = kind == .backup
                        ? try PostgresBackupEvidenceParser.parse(result.output) : nil
                    let final = jobRecord(
                        id: jobId, kind: kind, path: path, startedAt: startedAt,
                        state: .succeeded, evidence: evidence, message: "Verified")
                    try await jobStore.append(final)
                    executionSuccess = true
                    phase = kind == .backup ? "Backup verified" : "Restore completed"
                    consoleLogs = preflightOutput + "\n" + result.output
                    audit(job: final)
                } else {
                    throw BackupExecutionError.remoteExit(result.exitCode)
                }
                _ = try? await BridgeManager.shared.executeCommand(
                    connectionId: liveSshId,
                    command: PostgresRemoteJobProtocol.cleanup(token: token))
            } catch is CancellationError {
                // cancelCurrentJob records the terminal state.
            } catch {
                let kind: PostgresBackupJobKind = activeTab == "Backup" ? .backup : .restore
                let failed = jobRecord(
                    id: jobId, kind: kind, path: selectedPath, startedAt: startedAt,
                    state: .failed, evidence: nil, message: error.localizedDescription)
                try? await jobStore.append(failed)
                executionSuccess = false
                phase = "Failed"
                consoleLogs += "\nERROR: \(error.localizedDescription)"
                audit(job: failed)
            }
            isExecuting = false
            currentToken = nil
            currentLiveSshId = nil
            currentJobId = nil
            await loadHistory()
        }
    }

    private func makeCommands() -> (
        PostgresBackupJobKind, String, String, String
    ) {
        if activeTab == "Backup" {
            let request = PostgresBackupRequest(
                profileId: profile.id, profileName: profile.name,
                host: profile.host, port: profile.port, user: profile.user,
                database: profile.database, destinationPath: backupPath,
                format: backupFormat, dataOnly: backupDataOnly,
                schemaOnly: backupSchemaOnly, clean: backupClean)
            return (.backup, backupPath,
                    PostgresBackupCommandBuilder.preflight(for: request),
                    PostgresBackupCommandBuilder.backup(for: request))
        }
        let request = PostgresRestoreRequest(
            profileId: profile.id, profileName: profile.name,
            host: profile.host, port: profile.port, user: profile.user,
            database: profile.database, sourcePath: restorePath,
            format: restoreFormat, clean: restoreClean,
            singleTransaction: restoreSingleTransaction)
        return (.restore, restorePath,
                PostgresBackupCommandBuilder.preflight(for: request),
                PostgresBackupCommandBuilder.restore(for: request))
    }

    private func pollJob(
        liveSshId: String, token: String, preflightOutput: String
    ) async throws -> (exitCode: Int, output: String) {
        while !Task.isCancelled {
            let output = try await BridgeManager.shared.executeCommand(
                connectionId: liveSshId,
                command: PostgresRemoteJobProtocol.poll(token: token))
            consoleLogs = preflightOutput + "\n" + output
            if output.hasPrefix("PGAGENT_DONE\t") {
                let first = output.split(separator: "\n", maxSplits: 1).first ?? ""
                let code = Int(first.split(separator: "\t").last ?? "1") ?? 1
                return (code, output)
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw CancellationError()
    }

    private func cancelCurrentJob() {
        guard let token = currentToken, let liveSshId = currentLiveSshId else {
            jobTask?.cancel()
            return
        }
        jobTask?.cancel()
        let jobId = currentJobId ?? UUID().uuidString
        let kind: PostgresBackupJobKind = activeTab == "Backup" ? .backup : .restore
        let path = selectedPath
        Task {
            _ = try? await BridgeManager.shared.executeCommand(
                connectionId: liveSshId,
                command: PostgresRemoteJobProtocol.cancel(token: token))
            let cancelled = jobRecord(
                id: jobId, kind: kind, path: path, startedAt: Date(),
                state: .cancelled, evidence: nil, message: "Cancelled by operator")
            try? await jobStore.append(cancelled)
            phase = "Cancelled"
            executionSuccess = false
            isExecuting = false
            await loadHistory()
        }
    }

    private func jobRecord(
        id: String, kind: PostgresBackupJobKind, path: String, startedAt: Date,
        state: PostgresBackupJobState, evidence: PostgresBackupEvidence?, message: String?
    ) -> PostgresBackupJobRecord {
        PostgresBackupJobRecord(
            id: id, profileId: profile.id, profileName: profile.name,
            database: profile.database, kind: kind, path: path,
            startedAt: startedAt, finishedAt: state == .running ? nil : Date(),
            state: state, evidence: evidence, message: message)
    }

    private func loadHistory() async {
        history = (try? await jobStore.recent(profileId: profile.id, limit: 20)) ?? []
    }

    private func audit(job: PostgresBackupJobRecord) {
        let auditedProfile = profile
        Task.detached(priority: .utility) {
            await PostgresAuditLog.shared.record(
                profileName: auditedProfile.name, host: auditedProfile.host,
                database: auditedProfile.database, user: auditedProfile.user,
                action: job.kind == .backup ? .backup : .restore,
                statement: "\(job.path); sha256=\(job.evidence?.sha256 ?? "n/a")",
                error: job.state == .failed ? job.message : nil,
                rowsAffected: nil)
        }
    }
}

private enum BackupExecutionError: LocalizedError {
    case remoteExit(Int)
    var errorDescription: String? {
        switch self { case .remoteExit(let code): return "Remote backup job exited with status \(code)." }
    }
}
