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
    @State private var tls: PostgresTlsMode = .prefer
    @State private var applicationName: String = "mc-ssh"
    @State private var color: String? = nil

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
                    Picker("Environment Highlight", selection: $color) {
                        Text("None / Default").tag(String?.none)
                        Text("Production (Red)").tag(Optional("production"))
                        Text("Development (Green)").tag(Optional("development"))
                        Text("Testing / Staging (Yellow)").tag(Optional("testing"))
                    }
                    .pickerStyle(.menu)
                }

                Section("Authentication") {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Save password to Keychain", isOn: $savePasswordToKeychain)
                        .help("Stores the password under \(derivedKeychainAccount). Unchecked means password is held in memory only and lost on quit.")
                }

                Section("Encryption") {
                    Picker("TLS mode", selection: $tls) {
                        ForEach(PostgresTlsMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(tlsHint)
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
                        Text("The Postgres server hostname/port reachable from the SSH host. Sprint 2 wires the actual forwarding.")
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
        .onAppear { populateFromExisting() }
        .sheet(isPresented: $showNewSsh) {
            ConnectionEditView(storeManager: sshStore, existingProfile: nil, initialKind: .ssh)
        }
    }

    // MARK: - Derived

    private var derivedKeychainAccount: String {
        let portValue = UInt16(port) ?? 5432
        return "\(user)@\(host):\(portValue)/\(database)"
    }

    private var tlsHint: String {
        switch tls {
        case .disable:
            return "No encryption. Only safe over a private network."
        case .prefer:
            return "Try TLS, fall back to plaintext."
        case .require:
            return "Require TLS but skip certificate verification (encrypts the wire, not authenticates the server)."
        case .verifyFull:
            return "Require TLS and validate the server certificate against the system trust store. Recommended for production."
        }
    }

    private var canSave: Bool {
        !trimmedName.isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && UInt16(port) != nil
            && !database.trimmingCharacters(in: .whitespaces).isEmpty
            && !user.trimmingCharacters(in: .whitespaces).isEmpty
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
            notes: notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes
        )

        if savePasswordToKeychain && !password.isEmpty {
            KeychainManager.shared.savePassword(
                kind: .postgresPassword,
                account: profile.keychainAccount,
                secret: password
            )
        } else if !savePasswordToKeychain {
            // Drop any prior keychain entry so we don't keep stale secrets.
            KeychainManager.shared.deletePassword(
                kind: .postgresPassword,
                account: profile.keychainAccount
            )
        }

        store.saveOrUpdate(profile)
        logger.log("Saved Postgres profile \(profile.id, privacy: .public)")
        dismiss()
    }
}
