import SwiftUI
import AppKit
import OSLog
import PgAgentMacOS

/// Host-key verification dialog. Shown when a server's host key is unknown
/// or has changed.
struct HostKeyAlert: NSViewRepresentable {
    let host: String
    let fingerprint: String
    let isMismatch: Bool
    let onResponse: (HostKeyVerdict) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        // Present once
        guard context.coordinator.presented == false else { return }
        context.coordinator.presented = true
        presentAlert()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator {
        let parent: HostKeyAlert
        var presented = false
        init(_ parent: HostKeyAlert) { self.parent = parent }
    }

    private func presentAlert() {
        let alert = NSAlert()
        if isMismatch {
            alert.messageText = "Host Key Mismatch"
            alert.informativeText = "The host key for \(host) has changed!\n\n" +
                "New fingerprint: \(fingerprint)\n\n" +
                "This could mean someone is intercepting your connection."
            alert.alertStyle = .critical
        } else {
            alert.messageText = "Unknown Host Key"
            alert.informativeText = "The authenticity of host \(host) can't be established.\n\n" +
                "Fingerprint: \(fingerprint)\n\n" +
                "This host key is not known. Proceed with caution."
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "Trust and Continue")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        onResponse(response == .alertFirstButtonReturn ? .trusted : .rejected)
    }
}

enum HostKeyVerdict {
    case trusted
    case rejected
}

private struct ResizableSheetWindow: NSViewRepresentable {
    let minSize: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = ResizableSheetProbeView()
        view.minSheetSize = minSize
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ResizableSheetProbeView else { return }
        view.minSheetSize = minSize
        view.configureWindow()
    }

    private final class ResizableSheetProbeView: NSView {
        var minSheetSize: NSSize = .zero

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            window.styleMask.insert(.resizable)
            window.minSize = minSheetSize
        }
    }
}

// MARK: - Connection edit dialog

struct ConnectionEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var storeManager: ConnectionStoreManager
    @StateObject private var advancedAuthStore = AdvancedAuthenticationStore.shared

    let existingProfile: ConnectionProfile?
    let initialKind: ConnectionKind
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""
    @State private var kind: ConnectionKind = .ssh
    @State private var authMethod: AuthMethod = .password
    @State private var password: String = ""
    @State private var sshKeyReference: SSHKeyReference?
    @State private var privateKeyPath: String = ""
    @State private var passphrase: String = ""
    @State private var agentIdentityHint: String = ""
    @State private var keyStatusMessage: String?
    @State private var generatedPublicKey: String?
    @State private var folderPath: String = ""
    @State private var favorite: Bool = false
    @State private var tags: String = ""
    @State private var notes: String = ""
    @State private var tailscaleResolutionMode: TailscaleResolutionMode = .system
    @State private var tailscaleHostOverride: String = ""
    @State private var multipathTCPMode: MultipathTCPMode = .system
    @State private var monitoredSystemdServices: String = ""

    private let logger = Logger(subsystem: "com.mc-ssh", category: "connection-edit")

    init(
        storeManager: ConnectionStoreManager,
        existingProfile: ConnectionProfile?,
        initialKind: ConnectionKind = .ssh
    ) {
        self._storeManager = ObservedObject(wrappedValue: storeManager)
        self.existingProfile = existingProfile
        self.initialKind = initialKind
    }

    var isEditing: Bool { existingProfile != nil }
    var title: String { isEditing ? "Edit Connection" : "New Connection" }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPort: String {
        port.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedPort: UInt16? {
        guard let value = UInt16(trimmedPort), value > 0 else { return nil }
        return value
    }

    private var portValidationMessage: String? {
        guard !trimmedPort.isEmpty else { return "Port is required." }
        guard parsedPort != nil else { return "Enter a port from 1 to 65535." }
        return nil
    }

    private var canSave: Bool {
        !trimmedName.isEmpty
            && !trimmedHost.isEmpty
            && !trimmedUsername.isEmpty
            && portValidationMessage == nil
    }

    private var kindCaption: String {
        switch kind {
        case .ssh:
            return "Full SSH session: terminal, file browser, and host monitor."
        case .sftp:
            return "File transfer only — for hosts that allow SFTP but not a login shell (chroot, scponly, hosting accounts)."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title2)
                .padding(.horizontal)
                .padding(.top)
                .padding(.bottom, 12)

            ScrollView {
                connectionForm
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.visible)
            .frame(minHeight: 0, maxHeight: .infinity)

            Divider()
            actionBar
        }
        .frame(
            minWidth: 560,
            idealWidth: 680,
            maxWidth: .infinity,
            minHeight: 480,
            idealHeight: 620,
            maxHeight: .infinity
        )
        .background(
            ResizableSheetWindow(minSize: NSSize(width: 560, height: 480))
                .frame(width: 0, height: 0)
        )
        .onAppear {
            advancedAuthStore.reload()
            if let p = existingProfile {
                name = p.name
                host = p.host
                port = String(p.port)
                username = p.username
                kind = p.kind
                authMethod = p.authMethod
                sshKeyReference = p.sshKeyReference
                privateKeyPath = p.privateKeyPath ?? ""
                if case .agent(let hint) = p.sshKeyReference {
                    agentIdentityHint = hint ?? ""
                }
                folderPath = p.folderPath ?? ""
                favorite = p.favorite
                tags = p.tags.joined(separator: ", ")
                notes = p.notes ?? ""
                tailscaleResolutionMode = p.networkOptions.tailscaleResolutionMode
                tailscaleHostOverride = p.networkOptions.tailscaleHostOverride ?? ""
                multipathTCPMode = p.networkOptions.multipathTCPMode
                monitoredSystemdServices = p.monitoredSystemdServices.joined(separator: ", ")
            } else {
                kind = initialKind
            }
        }
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Connection") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Name:").frame(width: 80, alignment: .trailing)
                        TextField("My Server", text: $name)
                    }
                    HStack(alignment: .top) {
                        Text("Type:").frame(width: 80, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Picker("", selection: $kind) {
                                ForEach(ConnectionKind.allCases, id: \.self) { k in
                                    Text(k.displayName).tag(k)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            Text(kindCaption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack {
                        Text("Host:").frame(width: 80, alignment: .trailing)
                        TextField("example.com", text: $host)
                    }
                    HStack {
                        Text("Port:").frame(width: 80, alignment: .trailing)
                        TextField("22", text: $port)
                            .frame(width: 80)
                        Spacer()
                    }
                    if let portValidationMessage {
                        HStack(spacing: 4) {
                            Text("").frame(width: 80)
                            Label(portValidationMessage, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    HStack {
                        Text("User:").frame(width: 80, alignment: .trailing)
                        TextField("root", text: $username)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox("Authentication") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Method:", selection: $authMethod) {
                        Text("Password").tag(AuthMethod.password)
                        Text("Public Key").tag(AuthMethod.publicKey)
                    }
                    .pickerStyle(.radioGroup)
                    .frame(height: 50)

                    if authMethod == .password {
                        HStack {
                            Text("Password:").frame(width: 80, alignment: .trailing)
                            SecureField("Password", text: $password)
                        }
                    } else {
                        sshKeyControls
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox("Organization") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Folder:").frame(width: 80, alignment: .trailing)
                        Picker("", selection: $folderPath) {
                            Text("(Root)").tag("")
                            // List every existing folder path so the
                            // user can drop the profile in directly
                            // without having to type. Folder creation
                            // still happens from the sidebar — the
                            // editor only assigns into existing ones
                            // to keep this dialog simple.
                            ForEach(storeManager.allFolderPaths(), id: \.self) { path in
                                Text(path).tag(path)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        Spacer()
                    }
                    HStack {
                        Toggle("Favorite", isOn: $favorite)
                        Spacer()
                    }
                    HStack {
                        Text("Tags:").frame(width: 80, alignment: .trailing)
                        TextField("comma, separated", text: $tags)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox("Monitoring") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("systemd:").frame(width: 80, alignment: .trailing)
                        TextField("nginx.service, postgresql.service", text: $monitoredSystemdServices)
                    }
                    Text("Services checked in the systemd panel are saved here and shown in the monitor pane.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if FeatureFlags.networkPolish.isEnabled {
                networkOptionsSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var networkOptionsSection: some View {
        GroupBox("Network") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Tailnet:").frame(width: 80, alignment: .trailing)
                    Picker("", selection: $tailscaleResolutionMode) {
                        ForEach(TailscaleResolutionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                HStack {
                    Text("Host:").frame(width: 80, alignment: .trailing)
                    TextField("optional tailnet host", text: $tailscaleHostOverride)
                        .disabled(tailscaleResolutionMode == .system)
                }

                HStack {
                    Text("MPTCP:").frame(width: 80, alignment: .trailing)
                    Picker("", selection: $multipathTCPMode) {
                        ForEach(MultipathTCPMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(!NetworkPolishAuditReport.current.sshMultipathTCP.isSupported)
                    Label("SSH transport: standard TCP", systemImage: "network.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("KEX:").frame(width: 80, alignment: .trailing)
                    Label("Post-quantum algorithms unavailable in current Rust SSH stack", systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionBar: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button(isEditing ? "Save" : "Add") {
                if save() {
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding()
    }

    private var sshKeyControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            keySummary

            HStack {
                Button {
                    importKeyIntoVault()
                } label: {
                    Label("Import Key", systemImage: "tray.and.arrow.down")
                }

                Button {
                    useExistingKey()
                } label: {
                    Label("Use Existing Key", systemImage: "folder")
                }

                Button {
                    grantSSHFolderAccess()
                } label: {
                    Label("Grant ~/.ssh Access", systemImage: "folder.badge.gearshape")
                }

                Button {
                    generateNewKey()
                } label: {
                    Label("Generate Key", systemImage: "key")
                }

                if !advancedAuthStore.identities.isEmpty {
                    Menu {
                        ForEach(advancedAuthStore.identities) { identity in
                            Button {
                                useAdvancedIdentity(identity)
                            } label: {
                                Text(identity.displayName)
                            }
                        }
                    } label: {
                        Label("Advanced", systemImage: "lock.shield")
                    }
                }
            }
            .buttonStyle(.bordered)

            if shouldShowPassphraseField {
                HStack {
                    Text("Passphrase:").frame(width: 80, alignment: .trailing)
                    SecureField("Passphrase", text: $passphrase)
                }
            }

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Plain path:").frame(width: 80, alignment: .trailing)
                        TextField("~/.ssh/id_ed25519", text: $privateKeyPath)
                        Button("Use Path") {
                            let trimmed = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                sshKeyReference = .plainPath(trimmed)
                                keyStatusMessage = "Using plain path. This is best for direct builds; sandboxed builds should use a chosen key or vault key."
                            }
                        }
                    }

                    HStack {
                        Text("Agent hint:").frame(width: 80, alignment: .trailing)
                        TextField("optional public-key base64 substring", text: $agentIdentityHint)
                        Button("Use SSH Agent") {
                            let hint = agentIdentityHint.trimmingCharacters(in: .whitespacesAndNewlines)
                            sshKeyReference = .agent(identityHint: hint.isEmpty ? nil : hint)
                            generatedPublicKey = nil
                            keyStatusMessage = "Using SSH_AUTH_SOCK. If a hint is set, pgAgent selects the matching agent identity."
                        }
                    }
                }
                .padding(.top, 6)
            }

            if let generatedPublicKey {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Public key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(generatedPublicKey, forType: .string)
                        }
                    }
                    Text(generatedPublicKey)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }

            if let keyStatusMessage {
                Text(keyStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var keySummary: some View {
        let metadata = SSHKeyVault.shared.metadata(for: sshKeyReference)
        return VStack(alignment: .leading, spacing: 4) {
            if let metadata {
                Label(metadata.label, systemImage: keySummaryIcon(source: metadata.source))
                    .font(.caption)
                    .foregroundStyle(.primary)
                HStack(spacing: 12) {
                    Text(metadata.source)
                    Text(metadata.fingerprint ?? "Fingerprint unavailable")
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            } else {
                Label("No SSH key selected.", systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func save() -> Bool {
        guard let validatedPort = parsedPort, canSave else { return false }

        var referenceToSave = sshKeyReference
        if authMethod == .publicKey,
           referenceToSave == nil {
            let trimmed = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                referenceToSave = .plainPath(trimmed)
            }
        }

        let p = ConnectionProfile(
            id: existingProfile?.id ?? UUID().uuidString,
            name: trimmedName,
            host: trimmedHost,
            port: validatedPort,
            username: trimmedUsername,
            authMethod: authMethod,
            kind: kind,
            folderPath: folderPath.trimmingCharacters(in: .whitespaces).isEmpty ? nil : folderPath,
            sshKeyReference: authMethod == .publicKey ? referenceToSave : nil,
            lastConnected: existingProfile?.lastConnected,
            favorite: favorite,
            tags: tags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            notes: notes,
            networkOptions: NetworkConnectionOptions(
                tailscaleResolutionMode: tailscaleResolutionMode,
                tailscaleHostOverride: tailscaleHostOverride,
                multipathTCPMode: multipathTCPMode
            ),
            monitoredSystemdServices: parseMonitoredSystemdServices()
        )

        storeManager.saveOrUpdate(p)

        // Save password/passphrase to Keychain
        if authMethod == .password && !password.isEmpty {
            KeychainManager.shared.savePassword(
                kind: .sshPassword,
                account: p.keychainAccount,
                secret: password
            )
        }
        if authMethod == .publicKey && shouldPersistPassphrase(for: p.sshKeyReference) && !passphrase.isEmpty {
            KeychainManager.shared.savePassword(
                kind: .sshKeyPassphrase,
                account: p.keychainAccount,
                secret: passphrase
            )
        }
        return true
    }

    private func importKeyIntoVault() {
        guard let url = chooseKeyFile(title: "Import SSH Private Key") else { return }
        do {
            sshKeyReference = try SSHKeyVault.shared.importKey(from: url)
            privateKeyPath = ""
            generatedPublicKey = nil
            keyStatusMessage = "Imported into the encrypted app key vault."
        } catch {
            keyStatusMessage = error.localizedDescription
        }
    }

    private func useExistingKey() {
        guard let url = chooseKeyFile(title: "Use Existing SSH Private Key") else { return }
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            sshKeyReference = .securityScopedBookmark(bookmark)
            privateKeyPath = url.path
            generatedPublicKey = nil
            keyStatusMessage = "Access saved with a security-scoped bookmark."
        } catch {
            keyStatusMessage = "Could not save access to this key: \(error.localizedDescription)"
        }
    }

    private func grantSSHFolderAccess() {
        let panel = NSOpenPanel()
        panel.title = "Grant Access to ~/.ssh"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        let didStartAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        let candidates = ["id_ed25519", "id_ecdsa", "id_rsa"]
            .map { folderURL.appendingPathComponent($0, isDirectory: false) }
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
        guard let keyURL = candidates.first else {
            keyStatusMessage = "No readable default key was found in \(folderURL.path). Use Existing Key to choose a specific file."
            return
        }

        do {
            let bookmark = try keyURL.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            sshKeyReference = .securityScopedBookmark(bookmark)
            privateKeyPath = keyURL.path
            generatedPublicKey = nil
            keyStatusMessage = "Access saved for \(keyURL.lastPathComponent)."
        } catch {
            keyStatusMessage = "Could not save access to \(keyURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func generateNewKey() {
        let hostPart = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let userPart = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let comment = "\(userPart.isEmpty ? "user" : userPart)@\(hostPart.isEmpty ? "server" : hostPart)-pgAgent"

        do {
            let generated = try SSHKeyVault.shared.generateEd25519Key(comment: comment)
            sshKeyReference = generated.reference
            privateKeyPath = ""
            passphrase = ""
            generatedPublicKey = generated.publicKey
            keyStatusMessage = "Generated Ed25519 key in the encrypted app key vault. Install the public key on the server."
        } catch {
            keyStatusMessage = error.localizedDescription
        }
    }

    private func useAdvancedIdentity(_ identity: AdvancedAuthIdentityRecord) {
        sshKeyReference = .advancedAuthIdentity(id: identity.id)
        privateKeyPath = ""
        passphrase = ""
        generatedPublicKey = identity.publicKey
        keyStatusMessage = "Using \(identity.displayName)."
    }

    private func chooseKeyFile(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func keySummaryIcon(source: String) -> String {
        switch source {
        case "Imported": return "tray.and.arrow.down.fill"
        case "Generated": return "key.fill"
        case "External": return "folder.fill"
        case "SSH agent": return "person.crop.circle.badge.checkmark"
        case "Secure Enclave": return "lock.shield.fill"
        case "Security key": return "key.radiowaves.forward.fill"
        case "SSH certificate": return "doc.badge.gearshape.fill"
        case "Certificate authority": return "building.columns.fill"
        default: return "key"
        }
    }

    private var shouldShowPassphraseField: Bool {
        shouldPersistPassphrase(for: sshKeyReference)
    }

    private func shouldPersistPassphrase(for reference: SSHKeyReference?) -> Bool {
        reference?.needsStoredPassphrase ?? true
    }

    private func parseMonitoredSystemdServices() -> [String] {
        Array(Set(monitoredSystemdServices.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }))
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
