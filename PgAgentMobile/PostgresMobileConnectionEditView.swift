import SwiftUI

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
    @State private var tls: PostgresTlsMode = .prefer
    @State private var notes = ""
    @State private var folderPath = ""
    @State private var errorText: String?
    @State private var color: String? = nil

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

                    // Section 1.5: Environment Highlight
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ENVIRONMENT HIGHLIGHT")
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                            .padding(.leading, 4)

                        VStack(spacing: 14) {
                            HStack {
                                Text("Highlight Style")
                                    .font(MidnightMobileDesign.FontToken.label)
                                Spacer()
                                Picker("Environment", selection: $color) {
                                    Text("None / Default").tag(String?.none)
                                    Text("Production (Red)").tag(Optional("production"))
                                    Text("Development (Green)").tag(Optional("development"))
                                    Text("Testing / Staging (Yellow)").tag(Optional("testing"))
                                }
                                .pickerStyle(.menu)
                                .tint(Color(red: 0.15, green: 0.75, blue: 0.85)) // Cyan accent
                            }
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
                                Text(tlsHint)
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

    private func populate() {
        guard let p = profile else { return }
        name = p.name
        host = p.host
        port = String(p.port)
        database = p.database
        user = p.user
        tls = p.tls
        color = p.color
        notes = p.notes ?? ""
        folderPath = p.folderPath ?? ""

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
            folderPath: folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : folderPath.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: profile?.createdAt ?? Date(),
            lastConnected: profile?.lastConnected,
            color: color,
            notes: notes.isEmpty ? nil : notes
        )

        // Save password if checking keychain
        if savePasswordToKeychain && !password.isEmpty {
            KeychainManager.shared.savePassword(
                kind: .postgresPassword,
                account: updatedProfile.keychainAccount,
                secret: password
            )
        } else if !savePasswordToKeychain {
            KeychainManager.shared.deletePassword(
                kind: .postgresPassword,
                account: updatedProfile.keychainAccount
            )
        }

        onSave(updatedProfile)
        dismiss()
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
