import AppKit
import OSLog
import PgAgentMacOS
import SwiftUI

/// Add or edit a Postgres connection profile. Mirrors the layout of
/// `ConnectionEditView` (Form-based, single sheet) so muscle memory carries
/// across protocols. Distinct in three ways: no SSH key flows (we use
/// password / keychain only), an SSL-mode picker, and an optional SSH-tunnel
/// section that lists existing SSH connection profiles as the tunnel source.
struct PostgresConnectionEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PostgresProfileStore
    @ObservedObject var sshStore: ConnectionStoreManager

    let existingProfile: PostgresProfile?

    @State private var name: String = ""
    @State private var host: String = "127.0.0.1"
    @State private var port: String = "5432"
    @State private var database: String = ""
    @State private var user: String = ""
    @State private var password: String = ""
    @State private var savePasswordToKeychain: Bool = true
    @State private var syncPasswordViaICloud: Bool = false
    @State private var tls: PostgresTlsMode = .prefer
    @State private var applicationName: String = "mc-ssh"
    @State private var color: String? = nil
    @State private var environment: PostgresEnvironment = .unspecified
    @State private var isReadOnly: Bool = false

    @State private var useTunnel: Bool = false
    @State private var tunnelSshProfileId: String? = nil
    @State private var tunnelRemoteHost: String = ""
    @State private var tunnelRemotePort: String = "5432"

    @State private var connectTimeoutSecs: String = "10"
    @State private var maxPoolSize: String = ""
    @State private var idleTimeoutSecs: String = ""
    @State private var minIdleConnections: String = ""
    @State private var notes: String = ""
    @State private var saveError: String?
    @State private var showNewSsh = false

    // Paste-to-connect (roadmap 2.1): a URL/DSN pasted here fills the form;
    // the extracted password is staged in `password` and lands in the
    // keychain on Save via the normal path — never in the profile.
    @State private var pasteInput: String = ""
    @State private var pasteError: String?
    @State private var clipboardCandidate: PostgresConnectionURL?

    private let logger = Logger(subsystem: "com.mc-ssh", category: "postgres-edit")

    init(
        store: PostgresProfileStore,
        sshStore: ConnectionStoreManager,
        existingProfile: PostgresProfile?
    ) {
        self._store = ObservedObject(wrappedValue: store)
        self._sshStore = ObservedObject(wrappedValue: sshStore)
        self.existingProfile = existingProfile
    }

    private var isEditing: Bool { existingProfile != nil }
    private var title: String { isEditing ? "Edit Postgres Connection" : "New Postgres Connection" }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sidebar listing of SSH profiles eligible to host the tunnel. We only
    /// list profiles whose `kind == .ssh` because SFTP-only profiles can't
    /// open a TCP forward (no shell channel).
    private var sshTunnelCandidates: [ConnectionProfile] {
        sshStore.connections.filter { $0.kind == .ssh }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.top, 16)

            Form {
                Section("Quick fill") {
                    if let candidate = clipboardCandidate {
                        Button {
                            apply(parsed: candidate)
                            clipboardCandidate = nil
                        } label: {
                            Label(
                                "Use connection from clipboard (\(candidate.user.isEmpty ? candidate.host : "\(candidate.user)@\(candidate.host)"))",
                                systemImage: "doc.on.clipboard"
                            )
                        }
                        .help("Your clipboard holds a Postgres connection string — click to fill the form.")
                    }
                    HStack(spacing: 8) {
                        TextField(
                            "Paste URL or DSN (postgres://… or host=… dbname=…)",
                            text: $pasteInput
                        )
                        .textFieldStyle(.roundedBorder)
                        Button("Fill Form") { applyPasteInput() }
                            .disabled(pasteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let pasteError {
                        Text(pasteError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Passwords in the string are placed in the field below and saved to your keychain — never stored in the profile.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Identity") {
                    TextField("Display name", text: $name)
                        .textFieldStyle(.roundedBorder)
                    TextField("Host", text: $host)
                        .textFieldStyle(.roundedBorder)
                    TextField("Port", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                    TextField("Database", text: $database)
                        .textFieldStyle(.roundedBorder)
                    TextField("User", text: $user)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Safety") {
                    Picker("Environment", selection: $environment) {
                        ForEach(PostgresEnvironment.allCases, id: \.self) { env in
                            Text(env.displayName).tag(env)
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Production connections get an unmissable red badge in the sidebar and query tabs.")
                    Toggle("Read-only connection", isOn: $isReadOnly)
                        .help("Blocks INSERT/UPDATE/DELETE/DDL from this app; SELECT/EXPLAIN only")
                    Text("Blocks INSERT/UPDATE/DELETE/DDL from this app; SELECT/EXPLAIN only. Enforced at the engine bridge, not just the UI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Authentication") {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Save password to Keychain", isOn: $savePasswordToKeychain)
                        .help("Stores the password under \(derivedKeychainAccount). Unchecked means password is held in memory only and lost on quit.")
                    if savePasswordToKeychain {
                        Toggle("Sync password via iCloud Keychain", isOn: $syncPasswordViaICloud)
                            .help("Stores the password as a synchronizable keychain item so your other devices can use it. The synced profile itself never contains the password.")
                        Text("Synced via iCloud Keychain to your devices. Synchronizable items can't be locked to this device only — they use the when-unlocked protection class instead of the device-only default.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Encryption") {
                    Picker("TLS mode", selection: $tls) {
                        ForEach(PostgresTlsMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(tls.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("SSH tunnel (optional)") {
                    Toggle("Connect through an SSH tunnel", isOn: $useTunnel)
                    if useTunnel {
                        HStack {
                            if sshTunnelCandidates.isEmpty {
                                Text("No SSH connections saved yet.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("SSH connection", selection: $tunnelSshProfileId) {
                                    Text("Select…").tag(String?.none)
                                    ForEach(sshTunnelCandidates, id: \.id) { p in
                                        Text("\(p.name) (\(p.username)@\(p.host):\(p.port))")
                                            .tag(Optional(p.id))
                                    }
                                }
                            }
                            Button("Add Profile…") {
                                showNewSsh = true
                            }
                            .buttonStyle(.borderless)
                        }

                        TextField("Remote host (as seen from SSH server)", text: $tunnelRemoteHost)
                            .textFieldStyle(.roundedBorder)
                        TextField("Remote port", text: $tunnelRemotePort)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 100)
                        Text("The Postgres server hostname/port as reachable from the SSH host (often 127.0.0.1:5432). The SSH connection opens automatically using its stored credentials when you connect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Advanced") {
                    TextField("application_name", text: $applicationName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Connect timeout (seconds)", text: $connectTimeoutSecs)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("Connection pool") {
                    Text("Leave blank to use the defaults: 5 max, 5-minute idle timeout, 1 minimum kept warm. Tighten on managed-DB providers with strict connection quotas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Max pool size (default 5)", text: $maxPoolSize)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                    TextField("Idle timeout, seconds (default 300)", text: $idleTimeoutSecs)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                    TextField("Min idle connections (default 1)", text: $minIdleConnections)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isEditing {
                    Button("Delete", role: .destructive) {
                        if let profile = existingProfile {
                            store.delete(profile)
                            dismiss()
                        }
                    }
                }
                Button(isEditing ? "Save" : "Create") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(minWidth: 540, minHeight: 620)
        .onAppear {
            populateFromExisting()
            probeClipboardForConnectionString()
        }
        .sheet(isPresented: $showNewSsh) {
            ConnectionEditView(storeManager: sshStore, existingProfile: nil, initialKind: .ssh)
        }
    }

    // MARK: - Derived

    private var derivedKeychainAccount: String {
        let portValue = UInt16(port) ?? 5432
        return "\(user)@\(host):\(portValue)/\(database)"
    }


    private var canSave: Bool {
        !trimmedName.isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && UInt16(port) != nil
            && !database.trimmingCharacters(in: .whitespaces).isEmpty
            && !user.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Paste-to-connect

    /// macOS only offers the clipboard hint when creating a new connection
    /// (an existing profile's fields shouldn't be one accidental click from
    /// being overwritten). Reading NSPasteboard has no permission toast on
    /// macOS, so probing on appear is fine here (unlike iOS).
    private func probeClipboardForConnectionString() {
        guard !isEditing else { return }
        guard let text = NSPasteboard.general.string(forType: .string),
              let parsed = try? PostgresConnectionURL.parse(text)
        else { return }
        clipboardCandidate = parsed
    }

    private func applyPasteInput() {
        pasteError = nil
        do {
            apply(parsed: try PostgresConnectionURL.parse(pasteInput))
        } catch {
            pasteError = error.localizedDescription
        }
    }

    private func apply(parsed: PostgresConnectionURL) {
        pasteError = nil
        host = parsed.host
        port = String(parsed.port)
        database = parsed.database
        user = parsed.user
        if let tlsMode = parsed.tls { tls = tlsMode }
        if let appName = parsed.applicationName, !appName.isEmpty {
            applicationName = appName
        }
        if let timeout = parsed.connectTimeoutSecs {
            connectTimeoutSecs = String(timeout)
        }
        if let pw = parsed.password {
            // Staged only: written to the keychain by save(), never to disk.
            password = pw
            savePasswordToKeychain = true
        }
        if trimmedName.isEmpty {
            name = parsed.suggestedName
        }
        pasteInput = ""
    }

    // MARK: - Actions

    private func populateFromExisting() {
        guard let p = existingProfile else { return }
        name = p.name
        host = p.host
        port = String(p.port)
        database = p.database
        user = p.user
        tls = p.tls
        color = p.color
        // `effectiveEnvironment` folds in the legacy color-based highlight,
        // so profiles tagged before the enum existed show their real value.
        environment = p.effectiveEnvironment
        isReadOnly = p.isReadOnly
        applicationName = p.applicationName ?? ""
        connectTimeoutSecs = p.connectTimeoutSecs.map(String.init) ?? "10"
        maxPoolSize = p.maxPoolSize.map(String.init) ?? ""
        idleTimeoutSecs = p.idleTimeoutSecs.map(String.init) ?? ""
        minIdleConnections = p.minIdleConnections.map(String.init) ?? ""
        notes = p.notes ?? ""
        if let t = p.tunnel {
            useTunnel = true
            tunnelSshProfileId = t.sshConnectionId
            tunnelRemoteHost = t.remoteHost
            tunnelRemotePort = String(t.remotePort)
        }
        syncPasswordViaICloud = p.syncPassword
        switch p.auth {
        case .keychain:
            savePasswordToKeychain = true
            password = KeychainManager.shared.loadPassword(
                kind: .postgresPassword,
                account: p.keychainAccount
            ) ?? ""
        case .ephemeralPassword(let pw):
            savePasswordToKeychain = false
            password = pw
        }
    }

    private func save() {
        saveError = nil
        guard let portValue = UInt16(port) else {
            saveError = "Port must be 0–65535."
            return
        }
        let timeoutValue = UInt64(connectTimeoutSecs)
        // Pool overrides — empty string means "inherit defaults".
        // Whitespace-only is also treated as empty.
        let trimmedMax = maxPoolSize.trimmingCharacters(in: .whitespaces)
        let trimmedIdle = idleTimeoutSecs.trimmingCharacters(in: .whitespaces)
        let trimmedMinIdle = minIdleConnections.trimmingCharacters(in: .whitespaces)
        let maxPool = trimmedMax.isEmpty ? nil : UInt32(trimmedMax)
        let idleTimeout = trimmedIdle.isEmpty ? nil : UInt64(trimmedIdle)
        let minIdle = trimmedMinIdle.isEmpty ? nil : UInt32(trimmedMinIdle)
        let tunnel: PostgresTunnel? = {
            guard useTunnel,
                  let sshId = tunnelSshProfileId,
                  let remotePort = UInt16(tunnelRemotePort)
            else { return nil }
            return PostgresTunnel(
                sshConnectionId: sshId,
                remoteHost: tunnelRemoteHost.trimmingCharacters(in: .whitespaces),
                remotePort: remotePort
            )
        }()

        if useTunnel && tunnel == nil {
            saveError = "Tunnel is enabled but the SSH connection or remote port is missing."
            return
        }

        let auth: PostgresAuthMethod =
            savePasswordToKeychain ? .keychain : .ephemeralPassword(password)

        let profile = PostgresProfile(
            id: existingProfile?.id ?? UUID().uuidString,
            name: trimmedName,
            host: host.trimmingCharacters(in: .whitespaces),
            port: portValue,
            database: database.trimmingCharacters(in: .whitespaces),
            user: user.trimmingCharacters(in: .whitespaces),
            auth: auth,
            tls: tls,
            applicationName: applicationName.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : applicationName,
            tunnel: tunnel,
            connectTimeoutSecs: timeoutValue,
            maxPoolSize: maxPool,
            idleTimeoutSecs: idleTimeout,
            minIdleConnections: minIdle,
            folderPath: existingProfile?.folderPath,
            createdAt: existingProfile?.createdAt ?? Date(),
            lastConnected: existingProfile?.lastConnected,
            color: color,
            notes: notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes,
            environment: environment,
            isReadOnly: isReadOnly,
            syncPassword: savePasswordToKeychain && syncPasswordViaICloud
        )

        KeychainManager.shared.persistPostgresPassword(
            account: profile.keychainAccount,
            password: password,
            saveToKeychain: savePasswordToKeychain,
            synchronizable: profile.syncPassword
        )

        store.saveOrUpdate(profile)
        logger.log("Saved Postgres profile \(profile.id, privacy: .public)")
        dismiss()
    }
}
