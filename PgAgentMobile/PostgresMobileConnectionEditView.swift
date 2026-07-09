import SwiftUI
import UIKit

struct PostgresMobileConnectionEditView: View {
    @Environment(\.dismiss) private var dismiss

    let profile: PostgresProfile?
    var onSave: (PostgresProfile) -> Void

    @State private var name = ""
    @State private var host = "127.0.0.1"
    @State private var port = "5432"
    @State private var database = ""
    @State private var user = ""
    @State private var password = ""
    @State private var savePasswordToKeychain = true
    @State private var syncPasswordViaICloud = false
    @State private var tls: PostgresTlsMode = .require
    @State private var notes = ""
    @State private var folderPath = ""
    @State private var errorText: String?
    @State private var color: String? = nil
    @State private var environment: PostgresEnvironment = .unspecified
    @State private var isReadOnly = false

    // SSH tunnel (inline config — iOS has no separate SSH profile store).
    @State private var useTunnel = false
    @State private var sshHost = ""
    @State private var sshPort = "22"
    @State private var sshUser = ""
    @State private var sshAuth: PostgresTunnelAuth = .password
    @State private var sshPassword = ""
    @State private var sshPrivateKey = ""
    @State private var sshKeyPassphrase = ""
    @State private var tunnelRemoteHost = "127.0.0.1"
    @State private var tunnelRemotePort = ""
    // Stable across edits so the Keychain account / live-connection cache key
    // survives re-saves; generated once when the tunnel is first configured.
    @State private var tunnelId = UUID().uuidString
    // A key already lives in the Keychain (editing) — so the form needn't
    // force a re-paste just to re-save unrelated fields.
    @State private var hasStoredKey = false
    // The tunnel's SSH keychain account when the sheet opened, so changing the
    // SSH host/user/port on save can evict the now-orphaned secrets.
    @State private var originalSshAccount: String?

    // Advanced (parity with macOS): previously never set on iOS, so iOS-created
    // profiles silently inherited defaults. Empty numeric fields inherit the
    // shared PostgresProfile defaults.
    @State private var applicationName = "mc-ssh"
    @State private var connectTimeoutSecs = "10"
    @State private var maxPoolSize = ""

    // Paste-to-connect (roadmap 2.1). The clipboard is only read when the
    // user taps the paste button — probing on appear would fire iOS's
    // paste-permission toast every time the sheet opens.
    @State private var pasteFeedback: String?
    @State private var pasteFeedbackIsError = false

    private var isEditing: Bool { profile != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let errorText {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text("Validation Error")
                                    .font(MidnightMobileDesign.FontToken.label)
                                    .foregroundStyle(.red)
                            }
                            Text(errorText)
                                .font(MidnightMobileDesign.FontToken.caption)
                                .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.red.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal)
                    }

                    // Section 0: Paste-to-connect quick fill
                    VStack(alignment: .leading, spacing: 10) {
                        Text("QUICK FILL")
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                            .padding(.leading, 4)

                        VStack(alignment: .leading, spacing: 10) {
                            Button(action: applyClipboardConnectionString) {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.on.clipboard")
                                    Text("Paste URL or DSN from clipboard")
                                        .font(MidnightMobileDesign.FontToken.label)
                                    Spacer()
                                }
                                .foregroundStyle(Color(red: 0.15, green: 0.75, blue: 0.85)) // Cyan accent
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .midnightMobileMinimumTapTarget()

                            Text(pasteFeedback ?? "Fills the form from a postgres:// URL or a host=… dbname=… string. Passwords go to the field below and are saved to your keychain.")
                                .font(MidnightMobileDesign.FontToken.caption)
                                .foregroundStyle(
                                    pasteFeedback == nil
                                        ? MidnightMobileDesign.ColorToken.secondaryText
                                        : (pasteFeedbackIsError ? Color.red : Color.green)
                                )
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding()
                        .midnightMobileCard()
                    }
                    .padding(.horizontal)

                    // Section 1: Connection Details
                    VStack(alignment: .leading, spacing: 10) {
                        Text("CONNECTION DETAILS")
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                            .padding(.leading, 4)

                        VStack(spacing: 14) {
                            EditFormRow("Display Name") {
                                TextField("My Database", text: $name)
                                    .textInputAutocapitalization(.words)
                            }

                            Divider().background(MidnightMobileDesign.ColorToken.separator)

                            EditFormRow("Host") {
                                TextField("localhost or IP", text: $host)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }

                            Divider().background(MidnightMobileDesign.ColorToken.separator)

                            HStack(spacing: 16) {
                                EditFormRow("Port") {
                                    TextField("5432", text: $port)
                                        .keyboardType(.numberPad)
                                }
                                .frame(maxWidth: 100)

                                EditFormRow("Database") {
                                    TextField("postgres", text: $database)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                }
                            }

                            Divider().background(MidnightMobileDesign.ColorToken.separator)

                            EditFormRow("Username") {
                                TextField("postgres", text: $user)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }

                            Divider().background(MidnightMobileDesign.ColorToken.separator)

                            EditFormRow("Folder (Optional)") {
                                TextField("e.g. Production, Development", text: $folderPath)
                                    .textInputAutocapitalization(.words)
                            }
                        }
                        .padding()
                        .midnightMobileCard()
                    }
                    .padding(.horizontal)

                    // Section 1.5: Safety (environment tag + read-only mode)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SAFETY")
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                            .padding(.leading, 4)

                        VStack(spacing: 14) {
                            HStack {
                                Text("Environment")
                                    .font(MidnightMobileDesign.FontToken.label)
                                Spacer()
                                Picker("Environment", selection: $environment) {
                                    ForEach(PostgresEnvironment.allCases, id: \.self) { env in
                                        Text(env.displayName).tag(env)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(Color(red: 0.15, green: 0.75, blue: 0.85)) // Cyan accent
                            }

                            Divider().background(MidnightMobileDesign.ColorToken.separator)

                            Toggle(isOn: $isReadOnly) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Read-only connection")
                                        .font(MidnightMobileDesign.FontToken.label)
                                    Text("Blocks INSERT/UPDATE/DELETE/DDL from this app; SELECT/EXPLAIN only")
                                        .font(MidnightMobileDesign.FontToken.caption)
                                        .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                                }
                            }
                            .tint(Color(red: 0.15, green: 0.75, blue: 0.85)) // Cyan accent
                        }
                        .padding()
                        .midnightMobileCard()
                    }
                    .padding(.horizontal)

                    // Section 2: Security & Credentials
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SECURITY & CREDENTIALS")
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                            .padding(.leading, 4)

                        VStack(spacing: 14) {
                            EditFormRow("Password") {
                                SecureField("Required", text: $password)
                            }

                            Divider().background(MidnightMobileDesign.ColorToken.separator)

                            Toggle(isOn: $savePasswordToKeychain) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Save to Keychain")
                                        .font(MidnightMobileDesign.FontToken.label)
                                    Text("Secure OS-level storage")
                                        .font(MidnightMobileDesign.FontToken.caption)
                                        .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                                }
                            }
                            .tint(Color(red: 0.15, green: 0.75, blue: 0.85)) // Cyan accent

                            if savePasswordToKeychain {
                                Divider().background(MidnightMobileDesign.ColorToken.separator)

                                Toggle(isOn: $syncPasswordViaICloud) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Sync password via iCloud Keychain")
                                            .font(MidnightMobileDesign.FontToken.label)
                                        Text("Synced via iCloud Keychain to your devices. Synchronizable items can't be locked to this device only. The synced profile never contains the password.")
                                            .font(MidnightMobileDesign.FontToken.caption)
                                            .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                                    }
                                }
                                .tint(Color(red: 0.15, green: 0.75, blue: 0.85)) // Cyan accent
                            }
                        }
                        .padding()
                        .midnightMobileCard()
                    }
                    .padding(.horizontal)

                    // Section 3: Encryption
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ENCRYPTION")
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                            .padding(.leading, 4)

                        VStack(spacing: 14) {
                            HStack {
                                Text("TLS Mode")
                                    .font(MidnightMobileDesign.FontToken.label)
                                Spacer()
                                Picker("TLS Mode", selection: $tls) {
                                    ForEach(PostgresTlsMode.allCases, id: \.self) { mode in
                                        Text(mode.displayName).tag(mode)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(Color(red: 0.15, green: 0.75, blue: 0.85)) // Cyan accent
                            }

                            Divider().background(MidnightMobileDesign.ColorToken.separator)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("TLS Mode Hint")
                                    .font(MidnightMobileDesign.FontToken.captionStrong)
                                    .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                                Text(tls.hint)
                                    .font(MidnightMobileDesign.FontToken.caption)
                                    .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding()
                        .midnightMobileCard()
                    }
                    .padding(.horizontal)

                    // Section 3.5: SSH Tunnel
                    sshTunnelSection
                        .padding(.horizontal)

                    // Section 3.6: Advanced
                    advancedSection
                        .padding(.horizontal)

                    // Section 4: Notes
                    VStack(alignment: .leading, spacing: 10) {
                        Text("NOTES")
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                            .padding(.leading, 4)

                        VStack {
                            TextField("Enter any notes about this connection...", text: $notes, axis: .vertical)
                                .lineLimit(3...6)
                                .font(MidnightMobileDesign.FontToken.body)
                        }
                        .padding()
                        .midnightMobileCard()
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                .padding(.vertical)
            }
            .background(MidnightMobileDesign.ColorToken.groupedBackground.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isEditing ? "Edit Profile" : "New Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(MidnightMobileDesign.FontToken.body)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .font(MidnightMobileDesign.FontToken.label)
                    .disabled(name.isEmpty || host.isEmpty || database.isEmpty || user.isEmpty)
                }
            }
            .onAppear {
                populate()
            }
        }
    }

    private var accent: Color { Color(red: 0.15, green: 0.75, blue: 0.85) }

    // MARK: - SSH Tunnel

    private var keyStatusText: String {
        if !sshPrivateKey.isEmpty { return "Private key ready (will be saved to Keychain)." }
        if hasStoredKey { return "A private key is saved in your Keychain. Paste again to replace it." }
        return "No private key yet. Paste a PEM/OpenSSH private key from the clipboard."
    }

    @ViewBuilder
    private var sshTunnelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SSH TUNNEL")
                .font(MidnightMobileDesign.FontToken.captionStrong)
                .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                .padding(.leading, 4)

            VStack(spacing: 14) {
                Toggle(isOn: $useTunnel) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect through an SSH tunnel")
                            .font(MidnightMobileDesign.FontToken.label)
                        Text("Reach a database that's only accessible from an SSH host (bastion/jump box).")
                            .font(MidnightMobileDesign.FontToken.caption)
                            .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                    }
                }
                .tint(accent)

                if useTunnel {
                    Divider().background(MidnightMobileDesign.ColorToken.separator)

                    EditFormRow("SSH Host") {
                        TextField("bastion.example.com", text: $sshHost)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    HStack(spacing: 16) {
                        EditFormRow("SSH Port") {
                            TextField("22", text: $sshPort)
                                .keyboardType(.numberPad)
                        }
                        .frame(maxWidth: 100)

                        EditFormRow("SSH Username") {
                            TextField("deploy", text: $sshUser)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }

                    Divider().background(MidnightMobileDesign.ColorToken.separator)

                    HStack {
                        Text("Authentication")
                            .font(MidnightMobileDesign.FontToken.label)
                        Spacer()
                        Picker("Authentication", selection: $sshAuth) {
                            ForEach(PostgresTunnelAuth.allCases, id: \.self) { method in
                                Text(method.displayName).tag(method)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(accent)
                    }

                    if sshAuth == .password {
                        EditFormRow("SSH Password") {
                            SecureField("Required", text: $sshPassword)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Button(action: applyClipboardPrivateKey) {
                                HStack(spacing: 8) {
                                    Image(systemName: "key.horizontal")
                                    Text("Paste private key from clipboard")
                                        .font(MidnightMobileDesign.FontToken.label)
                                    Spacer()
                                }
                                .foregroundStyle(accent)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .midnightMobileMinimumTapTarget()

                            if !sshPrivateKey.isEmpty || hasStoredKey {
                                Button(role: .destructive, action: clearPrivateKey) {
                                    Text("Remove private key")
                                        .font(MidnightMobileDesign.FontToken.caption)
                                }
                                .buttonStyle(.plain)
                            }

                            Text(keyStatusText)
                                .font(MidnightMobileDesign.FontToken.caption)
                                .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            EditFormRow("Key Passphrase (Optional)") {
                                SecureField("Only if the key is encrypted", text: $sshKeyPassphrase)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider().background(MidnightMobileDesign.ColorToken.separator)

                    EditFormRow("Remote host (as seen from SSH host)") {
                        TextField("127.0.0.1", text: $tunnelRemoteHost)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    EditFormRow("Remote port") {
                        TextField(port.isEmpty ? "5432" : port, text: $tunnelRemotePort)
                            .keyboardType(.numberPad)
                    }
                    .frame(maxWidth: 160)

                    Text("The Postgres server as reachable from the SSH host — usually 127.0.0.1 and the database port. The SSH connection opens automatically using the credentials above when you connect.")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
            .midnightMobileCard()
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ADVANCED")
                .font(MidnightMobileDesign.FontToken.captionStrong)
                .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                .padding(.leading, 4)

            VStack(spacing: 14) {
                EditFormRow("Application name") {
                    TextField("mc-ssh", text: $applicationName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Divider().background(MidnightMobileDesign.ColorToken.separator)

                HStack(spacing: 16) {
                    EditFormRow("Connect timeout (s)") {
                        TextField("10", text: $connectTimeoutSecs)
                            .keyboardType(.numberPad)
                    }
                    EditFormRow("Max pool size") {
                        TextField("Default", text: $maxPoolSize)
                            .keyboardType(.numberPad)
                    }
                }

                Text("Max pool size caps concurrent server connections for this profile. Leave blank to use the app default; lower it on quota-strict managed providers.")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .midnightMobileCard()
        }
    }

    private func applyClipboardPrivateKey() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            pasteFeedback = "Clipboard is empty."
            pasteFeedbackIsError = true
            return
        }
        sshPrivateKey = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clearPrivateKey() {
        sshPrivateKey = ""
        hasStoredKey = false
    }


    // MARK: - Paste-to-connect

    private func applyClipboardConnectionString() {
        // UIPasteboard.general.string triggers the system paste toast —
        // acceptable here because the user explicitly tapped "Paste".
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            pasteFeedback = "Clipboard is empty."
            pasteFeedbackIsError = true
            return
        }
        do {
            let parsed = try PostgresConnectionURL.parse(text)
            host = parsed.host
            port = String(parsed.port)
            database = parsed.database
            user = parsed.user
            if let tlsMode = parsed.tls { tls = tlsMode }
            if let pw = parsed.password {
                // Staged only: save() writes it to the keychain.
                password = pw
                savePasswordToKeychain = true
            }
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = parsed.suggestedName
            }
            pasteFeedback = "Form filled from clipboard."
            pasteFeedbackIsError = false
        } catch {
            pasteFeedback = error.localizedDescription
            pasteFeedbackIsError = true
        }
    }

    private func populate() {
        guard let p = profile else { return }
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
        notes = p.notes ?? ""
        folderPath = p.folderPath ?? ""
        syncPasswordViaICloud = p.syncPassword

        applicationName = p.applicationName ?? ""
        connectTimeoutSecs = p.connectTimeoutSecs.map(String.init) ?? ""
        maxPoolSize = p.maxPoolSize.map(String.init) ?? ""

        if let t = p.tunnel, t.isInline {
            useTunnel = true
            tunnelId = t.sshConnectionId
            sshHost = t.sshHost ?? ""
            sshPort = String(t.sshPort ?? 22)
            sshUser = t.sshUser ?? ""
            sshAuth = t.sshAuth ?? .password
            tunnelRemoteHost = t.remoteHost
            tunnelRemotePort = String(t.remotePort)

            let account = t.sshKeychainAccount
            originalSshAccount = account
            if let account {
                switch sshAuth {
                case .password:
                    sshPassword = KeychainManager.shared.loadPassword(kind: .sshPassword, account: account) ?? ""
                case .privateKey:
                    hasStoredKey = MobileSSHKeyStore.has(account: account)
                    sshKeyPassphrase = KeychainManager.shared.loadPassword(kind: .sshKeyPassphrase, account: account) ?? ""
                }
            }
        }

        switch p.auth {
        case .keychain:
            savePasswordToKeychain = true
            password = KeychainManager.shared.loadPassword(kind: .postgresPassword, account: p.keychainAccount) ?? ""
        case .ephemeralPassword(let pw):
            savePasswordToKeychain = false
            password = pw
        }
    }

    private func save() {
        guard let portValue = UInt16(port) else {
            errorText = "Port must be a valid number (0-65535)."
            return
        }

        let built = buildTunnel()
        if let message = built.error {
            errorText = message
            return
        }
        let tunnel = built.tunnel

        let trimmedAppName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let auth: PostgresAuthMethod = savePasswordToKeychain ? .keychain : .ephemeralPassword(password)
        let updatedProfile = PostgresProfile(
            id: profile?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: portValue,
            database: database.trimmingCharacters(in: .whitespacesAndNewlines),
            user: user.trimmingCharacters(in: .whitespacesAndNewlines),
            auth: auth,
            tls: tls,
            applicationName: trimmedAppName.isEmpty ? nil : trimmedAppName,
            tunnel: tunnel,
            connectTimeoutSecs: UInt64(connectTimeoutSecs.trimmingCharacters(in: .whitespaces)),
            maxPoolSize: UInt32(maxPoolSize.trimmingCharacters(in: .whitespaces)),
            folderPath: folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : folderPath.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: profile?.createdAt ?? Date(),
            lastConnected: profile?.lastConnected,
            color: color,
            notes: notes.isEmpty ? nil : notes,
            environment: environment,
            isReadOnly: isReadOnly,
            syncPassword: savePasswordToKeychain && syncPasswordViaICloud
        )

        guard KeychainManager.shared.persistPostgresPassword(
            account: updatedProfile.keychainAccount,
            password: password,
            saveToKeychain: savePasswordToKeychain,
            synchronizable: updatedProfile.syncPassword
        ) else {
            errorText = "Couldn't save the password to the Keychain. The profile was not saved."
            return
        }

        guard persistTunnelSecrets(tunnel) else {
            errorText = "Couldn't save the SSH tunnel secret to the Keychain. The profile was not saved."
            return
        }

        onSave(updatedProfile)
        dismiss()
    }

    /// Build and validate the inline SSH tunnel from the form, or `nil` when
    /// the tunnel is disabled. Returns a user-facing message on invalid input.
    private func buildTunnel() -> (tunnel: PostgresTunnel?, error: String?) {
        guard useTunnel else { return (nil, nil) }

        let trimmedHost = sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = sshUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteHost = tunnelRemoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let remotePortText = tunnelRemotePort.trimmingCharacters(in: .whitespaces)

        guard !trimmedHost.isEmpty, !trimmedUser.isEmpty, !remoteHost.isEmpty else {
            return (nil, "SSH tunnel needs an SSH host, SSH username, and remote host.")
        }
        guard let sshPortValue = UInt16(sshPort.trimmingCharacters(in: .whitespaces)) else {
            return (nil, "SSH port must be a valid number (0-65535).")
        }
        // Blank remote port defaults to the database port.
        guard let remotePortValue = UInt16(remotePortText.isEmpty ? port : remotePortText) else {
            return (nil, "Remote port must be a valid number (0-65535).")
        }
        if sshAuth == .password && sshPassword.isEmpty {
            return (nil, "Enter the SSH password, or switch the tunnel to private-key auth.")
        }
        if sshAuth == .privateKey && sshPrivateKey.isEmpty && !hasStoredKey {
            return (nil, "Paste an SSH private key, or switch the tunnel to password auth.")
        }

        return (PostgresTunnel(
            sshConnectionId: tunnelId,
            remoteHost: remoteHost,
            remotePort: remotePortValue,
            sshHost: trimmedHost,
            sshPort: sshPortValue,
            sshUser: trimmedUser,
            sshAuth: sshAuth
        ), nil)
    }

    /// Persist the tunnel's SSH secrets to the Keychain and evict any that the
    /// user orphaned by disabling the tunnel, switching auth, or changing the
    /// SSH endpoint (which moves the Keychain account).
    private func persistTunnelSecrets(_ tunnel: PostgresTunnel?) -> Bool {
        var success = true
        let newAccount = tunnel?.sshKeychainAccount

        if let old = originalSshAccount, old != newAccount {
            // Migrate a stored private key the user didn't re-paste before the
            // old account's secrets are evicted, so an endpoint edit never
            // silently drops the key.
            if let newAccount,
               (tunnel?.sshAuth ?? .password) == .privateKey,
               sshPrivateKey.isEmpty, hasStoredKey,
               let existingPem = MobileSSHKeyStore.load(account: old)
            {
                guard MobileSSHKeyStore.save(pem: existingPem, account: newAccount) else {
                    return false
                }
            }
            guard KeychainManager.shared.deletePassword(kind: .sshPassword, account: old),
                  KeychainManager.shared.deletePassword(kind: .sshKeyPassphrase, account: old),
                  MobileSSHKeyStore.delete(account: old)
            else {
                return false
            }
        }

        guard let tunnel, let account = tunnel.sshKeychainAccount else { return success }

        switch tunnel.sshAuth ?? .password {
        case .password:
            if !sshPassword.isEmpty {
                success = KeychainManager.shared.savePassword(kind: .sshPassword, account: account, secret: sshPassword) && success
            }
            // Drop any key material left from a prior private-key config.
            success = KeychainManager.shared.deletePassword(kind: .sshKeyPassphrase, account: account) && success
            success = MobileSSHKeyStore.delete(account: account) && success
        case .privateKey:
            if !sshPrivateKey.isEmpty {
                success = MobileSSHKeyStore.save(pem: sshPrivateKey, account: account) && success
            }
            if sshKeyPassphrase.isEmpty {
                success = KeychainManager.shared.deletePassword(kind: .sshKeyPassphrase, account: account) && success
            } else {
                success = KeychainManager.shared.savePassword(kind: .sshKeyPassphrase, account: account, secret: sshKeyPassphrase) && success
            }
            // Drop any password left from a prior password config.
            success = KeychainManager.shared.deletePassword(kind: .sshPassword, account: account) && success
        }
        return success
    }
}

struct EditFormRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(MidnightMobileDesign.FontToken.captionStrong)
                .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
            content
                .font(MidnightMobileDesign.FontToken.body)
                .foregroundStyle(.primary)
                .midnightMobileMinimumTapTarget()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
