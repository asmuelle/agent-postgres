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
    /// Identity of the job that owns the UI. A job's task only touches view
    /// state while this still equals its id, so a stale task can never
    /// clobber a newer job.
    @State private var currentJobId: String?
    @State private var isCancelling = false
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
                            Button(isCancelling ? "Cancelling…" : "Cancel Job", role: .destructive) {
                                cancelCurrentJob()
                            }
                            .disabled(isCancelling)
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
        isCancelling = false
        executionSuccess = nil
        consoleLogs = ""
        let jobId = UUID().uuidString
        currentJobId = jobId
        let startedAt = Date()
        // Capture the whole job up front: later edits to the form (or the
        // tab) must not change what this job records or runs.
        let (kind, path, preflight, command) = makeCommands()
        let plan = PostgresBackupJobPlan(
            kind: kind, path: path, preflight: preflight, command: command,
            token: UUID().uuidString.lowercased())

        jobTask = Task {
            let outcome = await PostgresBackupJobRunner.run(
                plan: plan,
                resolveHost: {
                    try await SSHTunnelResolver.liveConnectionId(forSSHProfileReference: sshId)
                },
                execute: { hostId, command in
                    try await BridgeManager.shared.executeCommand(connectionId: hostId, command: command)
                },
                onEvent: { event in
                    await handle(event, jobId: jobId, plan: plan, startedAt: startedAt)
                }
            )
            await finish(jobId: jobId, plan: plan, startedAt: startedAt, outcome: outcome)
        }
    }

    private func handle(
        _ event: PostgresBackupJobEvent, jobId: String,
        plan: PostgresBackupJobPlan, startedAt: Date
    ) async {
        switch event {
        case .launching:
            // Persist before the launch command is sent so a crash mid-job
            // still leaves a record carrying the remote token.
            let running = jobRecord(
                id: jobId, kind: plan.kind, path: plan.path, startedAt: startedAt,
                state: .running, evidence: nil, message: "Remote token \(plan.token)")
            try? await jobStore.append(running)
        case .phase(let text):
            guard currentJobId == jobId, !isCancelling else { return }
            phase = text
        case .console(let text):
            guard currentJobId == jobId else { return }
            consoleLogs = text
        }
    }

    /// Record the terminal state (always — records are keyed by job id) and,
    /// only if this job still owns the UI, update and release it.
    private func finish(
        jobId: String, plan: PostgresBackupJobPlan, startedAt: Date,
        outcome: PostgresBackupJobOutcome
    ) async {
        let state: PostgresBackupJobState
        let message: String
        var evidence: PostgresBackupEvidence?
        var console: String?
        switch outcome {
        case .finished(0, let output, let preflightOutput):
            console = preflightOutput + "\n" + output
            do {
                evidence = plan.kind == .backup ? try PostgresBackupEvidenceParser.parse(output) : nil
                state = .succeeded
                message = "Verified"
            } catch {
                state = .failed
                message = error.localizedDescription
            }
        case .finished(let exitCode, let output, let preflightOutput):
            console = preflightOutput + "\n" + output
            state = .failed
            message = BackupExecutionError.remoteExit(exitCode).localizedDescription
        case .failed(let detail, let launched):
            state = .failed
            message = launched
                ? "\(detail) The remote job (token \(plan.token)) may still be running."
                : detail
        case .cancelled(false, _):
            state = .cancelled
            message = "Cancelled by operator before launch — nothing ran on the server"
        case .cancelled(true, nil):
            state = .cancelled
            message = "Cancelled by operator; remote job signalled"
        case .cancelled(true, let remoteError?):
            // Couldn't confirm the stop: don't claim a clean cancel.
            state = .failed
            message = "Cancel requested but the remote cancel failed (\(remoteError)); job \(plan.token) may still be running"
        }

        let record = jobRecord(
            id: jobId, kind: plan.kind, path: plan.path, startedAt: startedAt,
            state: state, evidence: evidence, message: message)
        try? await jobStore.append(record)
        if state != .cancelled { audit(job: record) }

        guard currentJobId == jobId else { return }
        if let console { consoleLogs = console }
        switch state {
        case .succeeded:
            executionSuccess = true
            phase = plan.kind == .backup ? "Backup verified" : "Restore completed"
        case .cancelled:
            executionSuccess = false
            phase = "Cancelled"
            consoleLogs += "\n\(message)"
        case .failed, .running:
            executionSuccess = false
            phase = "Failed"
            consoleLogs += "\nERROR: \(message)"
        }
        isExecuting = false
        isCancelling = false
        currentJobId = nil
        jobTask = nil
        await loadHistory()
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

    /// Request cancellation. The job task itself decides what that means —
    /// before launch nothing runs remotely; after launch it sends the remote
    /// cancel — and records the terminal state, so the UI stays busy
    /// ("Cancelling…") until the outcome is known.
    private func cancelCurrentJob() {
        guard isExecuting, !isCancelling else { return }
        isCancelling = true
        phase = "Cancelling"
        jobTask?.cancel()
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
