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
    @State private var tls: PostgresTlsMode = .prefer
    @State private var notes = ""
    @State private var folderPath = ""
    @State private var errorText: String?
    @State private var color: String? = nil
    @State private var environment: PostgresEnvironment = .unspecified
    @State private var isReadOnly = false

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
            notes: notes.isEmpty ? nil : notes,
            environment: environment,
            isReadOnly: isReadOnly
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
