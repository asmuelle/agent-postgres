import SwiftUI
import OSLog
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// Postgres Visual Backup & Restore Utility View (Pillar 4)
// GUI-driven wrapper that triggers pg_dump, pg_restore, and psql remotely
// over the active SSH tunnel connection, displaying streaming outputs.
// Integrates with the built-in SFTP Dual-Pane explorer via server directories.
// =============================================================================

struct PostgresBackupRestoreView: View {
    let profile: PostgresProfile
    @Environment(\.dismiss) private var dismiss
    
    @State private var activeTab: String = "Backup" // Backup, Restore
    
    // Backup Options
    @State private var backupPath: String = "/tmp/db_backup.dump"
    @State private var backupFormat: String = "custom" // custom, tar, plain
    @State private var backupDataOnly = false
    @State private var backupSchemaOnly = false
    @State private var backupClean = false
    
    // Restore Options
    @State private var restorePath: String = "/tmp/db_backup.dump"
    @State private var restoreClean = false
    @State private var restoreSingleTransaction = false
    
    // Console Logs
    @State private var consoleLogs: String = ""
    @State private var isExecuting = false
    @State private var executionSuccess: Bool? = nil
    
    private let formats = [
        ("Custom format (compressed, -Fc)", "custom"),
        ("Tar archive (-Ft)", "tar"),
        ("Plain SQL script (-Fp)", "plain")
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            
            // Check if SSH Tunnel is configured
            if let sshId = profile.tunnel?.sshConnectionId, !sshId.isEmpty {
                mainContent(sshId: sshId)
            } else {
                sshMissingState
            }
        }
        .background(MidnightMacDesign.ColorToken.windowBackground)
        .frame(minWidth: 640, minHeight: 480)
    }
    
    // MARK: - Header Bar
    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Backup & Restore Utility")
                    .font(MidnightMacDesign.FontToken.title)
                Text("Database: \(profile.database) on \(profile.host)")
                    .font(MidnightMacDesign.FontToken.caption)
                    .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
            }
            
            Spacer()
            
            Picker("", selection: $activeTab) {
                Text("Backup").tag("Backup")
                Text("Restore").tag("Restore")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .disabled(isExecuting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
    
    // MARK: - SSH Missing Warning State
    @ViewBuilder
    private var sshMissingState: some View {
        VStack(spacing: 16) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            
            Text("SSH Tunnel Configuration Required")
                .font(MidnightMacDesign.FontToken.title)
            
            Text("Server-side dump utilities must be executed on a remote server over SSH. This profile does not have an active SSH Tunnel configuration.\n\nPlease edit your Postgres Connection Profile to assign a parent SSH host first.")
                .font(MidnightMacDesign.FontToken.body)
                .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            
            Button("Dismiss") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Main Interactive Content
    @ViewBuilder
    private func mainContent(sshId: String) -> some View {
        HSplitView {
            // Options Panel
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if activeTab == "Backup" {
                        backupForm
                    } else {
                        restoreForm
                    }
                    
                    Divider()
                    
                    HStack {
                        Button("Cancel") {
                            dismiss()
                        }
                        .buttonStyle(.plain)
                        .disabled(isExecuting)
                        
                        Spacer()
                        
                        Button(action: { runUtility(sshId: sshId) }) {
                            HStack {
                                if isExecuting {
                                    ProgressView()
                                        .controlSize(.small)
                                        .padding(.trailing, 4)
                                }
                                Text(activeTab == "Backup" ? "Start Backup" : "Start Restore")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isExecuting || (activeTab == "Backup" ? backupPath.isEmpty : restorePath.isEmpty))
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 280, maxWidth: .infinity)
            
            // Console Console Logs
            consolePanel
                .frame(width: 320)
        }
    }
    
    // MARK: - Backup Form
    @ViewBuilder
    private var backupForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("BACKUP LOCATION")
                .font(MidnightMacDesign.FontToken.label)
                .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Remote Destination Filepath")
                    .font(MidnightMacDesign.FontToken.caption)
                TextField("e.g. /tmp/backup.dump", text: $backupPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            
            Picker("Format", selection: $backupFormat) {
                ForEach(formats, id: \.1) { item in
                    Text(item.0).tag(item.1)
                }
            }
            .pickerStyle(.menu)
            
            Divider()
            
            Text("ADVANCED DUMP PARAMETERS")
                .font(MidnightMacDesign.FontToken.label)
                .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
            
            Toggle("Data Only (-a)", isOn: $backupDataOnly)
                .toggleStyle(.checkbox)
            Toggle("Schema Only (-s)", isOn: $backupSchemaOnly)
                .toggleStyle(.checkbox)
            Toggle("Clean / Drop before create (-c)", isOn: $backupClean)
                .toggleStyle(.checkbox)
        }
    }
    
    // MARK: - Restore Form
    @ViewBuilder
    private var restoreForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("RESTORE SOURCE")
                .font(MidnightMacDesign.FontToken.label)
                .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Remote Source Filepath")
                    .font(MidnightMacDesign.FontToken.caption)
                TextField("e.g. /tmp/backup.dump", text: $restorePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            
            Divider()
            
            Text("RESTORE OPTIONS")
                .font(MidnightMacDesign.FontToken.label)
                .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
            
            Toggle("Clean before restore (--clean)", isOn: $restoreClean)
                .toggleStyle(.checkbox)
            
            Toggle("Single Transaction (--single-transaction)", isOn: $restoreSingleTransaction)
                .toggleStyle(.checkbox)
                .help("Runs restore inside a single SQL transaction block. Fails whole restore if any statement crashes.")
            
            Text("Note: If the selected restore file is a plain SQL script (.sql), it will be executed via 'psql'. Binary and custom formats will be processed via 'pg_restore'.")
                .font(MidnightMacDesign.FontToken.caption)
                .foregroundStyle(MidnightMacDesign.ColorToken.secondaryText)
                .padding(.top, 4)
        }
    }
    
    // MARK: - Console Output Log View
    @ViewBuilder
    private var consolePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "terminal.fill")
                Text("EXECUTION PROGRESS")
                    .font(MidnightMacDesign.FontToken.label)
                Spacer()
                
                if let success = executionSuccess {
                    HStack(spacing: 4) {
                        Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        Text(success ? "SUCCESS" : "FAILED")
                    }
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(success ? .green : .red)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(MidnightMacDesign.ColorToken.controlBackground)
            
            Divider()
            
            ScrollView {
                if consoleLogs.isEmpty {
                    Text("No logs yet. Configure parameters and click Start.")
                        .font(MidnightMacDesign.FontToken.caption)
                        .foregroundStyle(MidnightMacDesign.ColorToken.tertiaryText)
                        .padding()
                } else {
                    Text(consoleLogs)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .background(MidnightMacDesign.ColorToken.textBackground)
        }
    }
    
    // MARK: - Pipeline Executor
    private func runUtility(sshId: String) {
        isExecuting = true
        executionSuccess = nil
        consoleLogs = "[PROCESS INITIALIZED] Connecting to remote host...\n"
        
        let isBackup = activeTab == "Backup"
        let path = isBackup ? backupPath : restorePath
        
        // Resolve postgres credentials
        let password = KeychainManager.shared.loadPassword(kind: .postgresPassword, account: profile.keychainAccount) ?? ""
        // POSIX-safe single quoting so host / user / database / path / password
        // values cannot break out of their quotes into the remote shell — a
        // field like `'; rm -rf ~ #` is rendered inert. Applied to *every*
        // interpolated field (the port is a typed UInt16 and needs no quoting).
        func shellSingleQuoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let quotedPassword = shellSingleQuoted(password)
        let quotedHost = shellSingleQuoted(profile.host)
        let quotedUser = shellSingleQuoted(profile.user)
        let quotedDatabase = shellSingleQuoted(profile.database)
        let quotedPath = shellSingleQuoted(path)
        
        // Dynamically build cmd
        var cmd = ""
        if isBackup {
            cmd = "PGPASSWORD=\(quotedPassword) pg_dump -h \(quotedHost) -p \(profile.port) -U \(quotedUser)"
            if backupDataOnly { cmd += " -a" }
            if backupSchemaOnly { cmd += " -s" }
            if backupClean { cmd += " -c" }
            
            switch backupFormat {
            case "custom": cmd += " -F c"
            case "tar": cmd += " -F t"
            case "plain": cmd += " -F p"
            default: break
            }
            
            cmd += " -f \(quotedPath)"
            cmd += " \(quotedDatabase)"
        } else {
            // Is Restore. Check if plain SQL
            let isSql = path.lowercased().hasSuffix(".sql")
            if isSql {
                cmd = "PGPASSWORD=\(quotedPassword) psql -h \(quotedHost) -p \(profile.port) -U \(quotedUser) -d \(quotedDatabase) -f \(quotedPath)"
            } else {
                cmd = "PGPASSWORD=\(quotedPassword) pg_restore -h \(quotedHost) -p \(profile.port) -U \(quotedUser) -d \(quotedDatabase)"
                if restoreClean { cmd += " -c" }
                if restoreSingleTransaction { cmd += " -1" }
                cmd += " \(quotedPath)"
            }
        }
        
        // Append stdout/stderr mapping redirect
        cmd += " 2>&1"
        
        consoleLogs += "[EXECUTION INITIATED] Running command on SSH host:\n"
        // Mask the quoted password substring so the secret never reaches the log.
        var printableCmd = cmd
        if !password.isEmpty {
            printableCmd = printableCmd.replacingOccurrences(of: quotedPassword, with: "'********'")
        }
        consoleLogs += "$ \(printableCmd)\n\n"
        
        Task {
            do {
                // `sshId` is the saved SSH *profile* id — resolve it to a
                // live connection (opening one with stored credentials if
                // needed) before running anything on it.
                let liveSshId = try await SSHTunnelResolver.liveConnectionId(
                    forSSHProfileReference: sshId
                )
                let output = try await BridgeManager.shared.executeCommand(connectionId: liveSshId, command: cmd)

                await MainActor.run {
                    isExecuting = false
                    executionSuccess = true
                    consoleLogs += output
                    consoleLogs += "\n\n[SUCCESS] Operation completed successfully."
                }
            } catch {
                await MainActor.run {
                    isExecuting = false
                    executionSuccess = false
                    consoleLogs += "\n[ERROR] Command failed:\n"
                    consoleLogs += error.localizedDescription
                }
            }
        }
    }
}
