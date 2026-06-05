import AppKit
import SwiftUI
import PgAgentMacOS
import UniformTypeIdentifiers

struct AdvancedAuthenticationView: View {
    @StateObject private var store = AdvancedAuthenticationStore.shared
    @State private var secureEnclaveName = ""
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section("Secure Enclave") {
                HStack {
                    TextField("Identity name", text: $secureEnclaveName)
                    Button {
                        generateSecureEnclaveIdentity()
                    } label: {
                        Label("Generate", systemImage: "key.viewfinder")
                    }
                    .disabled(!canCreateSecureEnclaveIdentity)
                }
            }

            Section("Agent-backed identities") {
                HStack {
                    Button {
                        importSSHCertificate()
                    } label: {
                        Label("Import Certificate", systemImage: "doc.badge.gearshape")
                    }

                    Button {
                        importSecurityKey()
                    } label: {
                        Label("Import Security Key", systemImage: "key.radiowaves.forward")
                    }

                    Spacer()
                }
            }

            Section("Identities") {
                if store.identities.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "key.slash")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text("No advanced identities")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 16)
                        Spacer()
                    }
                } else {
                    ForEach(store.identities) { identity in
                        identityRow(identity)
                    }
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = store.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var canCreateSecureEnclaveIdentity: Bool {
        !secureEnclaveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func identityRow(_ identity: AdvancedAuthIdentityRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName(for: identity.kind))
                .foregroundStyle(color(for: identity.kind))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(identity.displayName)
                    .font(.headline)
                Text(identity.kind.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let fingerprint = identity.publicKeyFingerprint {
                    Text(fingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(identity.statusSummary)
                    .font(.caption)
                    .foregroundStyle(identity.isExpired() ? .red : .secondary)
            }

            Spacer()

            Menu {
                if identity.kind == .secureEnclaveKey {
                    Button("Test Signing") {
                        testSecureEnclaveSigning(identity)
                    }
                }
                if let publicKey = identity.publicKey {
                    Button("Copy Public Key") {
                        copy(publicKey)
                    }
                }
                Button("Delete", role: .destructive) {
                    store.delete(identity)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 4)
    }

    private func generateSecureEnclaveIdentity() {
        do {
            let identity = try SecureEnclaveSSHIdentityStore.shared.generateIdentity(label: secureEnclaveName)
            store.upsert(identity)
            secureEnclaveName = ""
            statusMessage = "Generated \(identity.displayName)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func importSSHCertificate() {
        guard let url = choosePublicKeyFile(title: "Import OpenSSH User Certificate") else { return }
        do {
            let identity = try SecureEnclaveSSHIdentityStore.shared.importSSHCertificate(from: url)
            store.upsert(identity)
            statusMessage = "Imported \(identity.displayName)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func importSecurityKey() {
        guard let url = choosePublicKeyFile(title: "Import Security Key Public Key") else { return }
        do {
            let identity = try SecureEnclaveSSHIdentityStore.shared.importSecurityKeyPublicKey(from: url)
            store.upsert(identity)
            statusMessage = "Imported \(identity.displayName)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func testSecureEnclaveSigning(_ identity: AdvancedAuthIdentityRecord) {
        do {
            let signature = try SecureEnclaveSSHIdentityStore.shared.signProbe(identity: identity)
            statusMessage = "Signing approved. Signature \(String(signature.prefix(16)))..."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func choosePublicKeyFile(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .data]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        statusMessage = "Copied public key."
    }

    private func symbolName(for kind: AdvancedAuthIdentityKind) -> String {
        switch kind {
        case .secureEnclaveKey: return "lock.shield.fill"
        case .securityKey: return "key.radiowaves.forward.fill"
        case .sshCertificate: return "doc.badge.gearshape.fill"
        case .certificateAuthority: return "building.columns.fill"
        }
    }

    private func color(for kind: AdvancedAuthIdentityKind) -> Color {
        switch kind {
        case .secureEnclaveKey: return .green
        case .securityKey: return .blue
        case .sshCertificate: return .orange
        case .certificateAuthority: return .secondary
        }
    }
}
