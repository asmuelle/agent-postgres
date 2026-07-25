import SwiftUI
import UIKit

// =============================================================================
// SSH identity UI (iOS) — create, inspect, and manage the shared keypairs that
// `MobileSSHIdentityStore` owns.
//
// Presented as a sheet from the SSH tunnel section of
// `PostgresMobileConnectionEditView`. The create flow reports the new identity
// back through `onCreated` so the editor can select it immediately, which is
// the whole point: make one key, point many connections at it.
// =============================================================================

private let identityAccent = Color(red: 0.15, green: 0.75, blue: 0.85)

// MARK: - List

struct MobileSSHIdentityListView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = MobileSSHIdentityStore.shared

    /// Called when an identity is created or tapped for selection. Nil when the
    /// list is opened purely to manage keys.
    var onSelect: ((MobileSSHIdentity) -> Void)?

    @State private var creating = false
    @State private var pendingDelete: MobileSSHIdentity?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    explainerCard

                    if store.identities.isEmpty {
                        emptyState
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("YOUR IDENTITIES")
                                .font(MidnightMobileDesign.FontToken.captionStrong)
                                .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                                .padding(.leading, 4)

                            VStack(spacing: 0) {
                                ForEach(Array(store.identities.enumerated()), id: \.element.id) { index, identity in
                                    if index > 0 {
                                        Divider()
                                            .background(MidnightMobileDesign.ColorToken.separator)
                                            .padding(.leading, 56)
                                    }
                                    NavigationLink {
                                        MobileSSHIdentityDetailView(identityId: identity.id)
                                    } label: {
                                        MobileSSHIdentityRow(
                                            identity: identity,
                                            usageCount: store.profilesUsing(id: identity.id).count
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        if let onSelect {
                                            Button {
                                                onSelect(identity)
                                                dismiss()
                                            } label: {
                                                Label("Use for this connection", systemImage: "checkmark.circle")
                                            }
                                        }
                                        Button {
                                            copyPublicKey(identity)
                                        } label: {
                                            Label("Copy public key", systemImage: "doc.on.doc")
                                        }
                                        .disabled(identity.publicKey == nil)
                                        Button(role: .destructive) {
                                            pendingDelete = identity
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .midnightMobileCard()
                        }
                    }
                }
                .padding()
            }
            .background(MidnightMobileDesign.ColorToken.groupedBackground.ignoresSafeArea())
            .navigationTitle("SSH Identities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(identityAccent)
                }
            }
            .sheet(isPresented: $creating) {
                // Select the new identity for the caller, but stay put: the
                // create sheet is showing the public key the user still has to
                // install on the server, and dismissing here would yank it away.
                MobileCreateSSHIdentityView { identity in
                    onSelect?(identity)
                }
            }
            .alert(item: $pendingDelete) { identity in
                deleteAlert(for: identity)
            }
        }
    }

    private var explainerCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 20))
                .foregroundStyle(identityAccent)
                .frame(width: 32, height: 32)
                .background(identityAccent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("One key, many connections")
                    .font(MidnightMobileDesign.FontToken.label)
                Text("An identity is an SSH keypair created on this device. Add its public key to a server once, then point any connection's SSH tunnel at it — no more pasting a key per connection.")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .midnightMobileCard()
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)

            Text("No identities yet")
                .font(MidnightMobileDesign.FontToken.headline)

            Text("Create one and this device generates an Ed25519 keypair. The private key stays in the Keychain; you only ever copy out the public half.")
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                creating = true
            } label: {
                Text("Create Identity")
                    .font(MidnightMobileDesign.FontToken.label)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(identityAccent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .midnightMobileCard()
    }

    private func deleteAlert(for identity: MobileSSHIdentity) -> Alert {
        let inUse = store.profilesUsing(id: identity.id)
        // Be explicit that this is a local delete, not revocation: the server
        // keeps trusting the public key until it's removed from
        // authorized_keys, and an already-open tunnel stays up until it drops.
        var message = "The private key is removed from this device's Keychain and can't be recovered. To revoke access, also delete its line from ~/.ssh/authorized_keys on the server."
        if !inUse.isEmpty {
            message += "\n\n\(inUse.count) connection\(inUse.count == 1 ? "" : "s") still use\(inUse.count == 1 ? "s" : "") it (\(inUse.map(\.name).joined(separator: ", "))) and will fail to connect until you pick another identity."
        }
        return Alert(
            title: Text("Delete \"\(identity.name)\"?"),
            message: Text(message),
            primaryButton: .destructive(Text("Delete")) {
                store.delete(id: identity.id)
            },
            secondaryButton: .cancel()
        )
    }

    private func copyPublicKey(_ identity: MobileSSHIdentity) {
        guard let publicKey = identity.publicKey else { return }
        UIPasteboard.general.string = publicKey
    }
}

// MARK: - Row

struct MobileSSHIdentityRow: View {
    let identity: MobileSSHIdentity
    let usageCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 15))
                .foregroundStyle(identityAccent)
                .frame(width: 32, height: 32)
                .background(identityAccent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(identity.name)
                    .font(MidnightMobileDesign.FontToken.label)
                    .foregroundStyle(.primary)

                Text(identity.fingerprint ?? "Fingerprint unavailable")
                    .font(MidnightMobileDesign.FontToken.metadataMono)
                    .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(usageCount == 0
                     ? "Not used by any connection"
                     : "Used by \(usageCount) connection\(usageCount == 1 ? "" : "s")")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
        }
        .padding()
        .contentShape(Rectangle())
    }
}

// MARK: - Detail

struct MobileSSHIdentityDetailView: View {
    let identityId: String

    @ObservedObject private var store = MobileSSHIdentityStore.shared
    @State private var name = ""
    @State private var errorText: String?

    private var identity: MobileSSHIdentity? { store.identity(id: identityId) }

    var body: some View {
        ScrollView {
            if let identity {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("NAME")
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                            .padding(.leading, 4)

                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Identity name", text: $name)
                                .font(MidnightMobileDesign.FontToken.body)
                                .midnightMobileMinimumTapTarget()
                                .onSubmit(commitRename)

                            if let errorText {
                                Text(errorText)
                                    .font(MidnightMobileDesign.FontToken.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding()
                        .midnightMobileCard()
                    }

                    MobileSSHPublicKeyCard(identity: identity)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("DETAILS")
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                            .padding(.leading, 4)

                        VStack(spacing: 12) {
                            detailRow("Source", identity.source.displayName)
                            Divider().background(MidnightMobileDesign.ColorToken.separator)
                            detailRow("Created", identity.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Divider().background(MidnightMobileDesign.ColorToken.separator)
                            detailRow("In use by", usageDescription(identity))
                        }
                        .padding()
                        .midnightMobileCard()
                    }
                }
                .padding()
            } else {
                Text("This identity was deleted.")
                    .font(MidnightMobileDesign.FontToken.body)
                    .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                    .padding(40)
            }
        }
        .background(MidnightMobileDesign.ColorToken.groupedBackground.ignoresSafeArea())
        .navigationTitle(identity?.name ?? "Identity")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = identity?.name ?? "" }
        .onDisappear(perform: commitRename)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(MidnightMobileDesign.FontToken.subheadline)
                .multilineTextAlignment(.trailing)
        }
    }

    private func usageDescription(_ identity: MobileSSHIdentity) -> String {
        let profiles = store.profilesUsing(id: identity.id)
        return profiles.isEmpty ? "No connections" : profiles.map(\.name).joined(separator: ", ")
    }

    private func commitRename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identity, trimmed != identity.name else { return }
        do {
            try store.rename(id: identity.id, to: trimmed)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
            name = identity.name
        }
    }
}

// MARK: - Public key card

struct MobileSSHPublicKeyCard: View {
    let identity: MobileSSHIdentity

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PUBLIC KEY")
                .font(MidnightMobileDesign.FontToken.captionStrong)
                .foregroundStyle(MidnightMobileDesign.ColorToken.tertiaryText)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 12) {
                if let publicKey = identity.publicKey {
                    Text(publicKey)
                        .font(MidnightMobileDesign.FontToken.metadataMono)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            MidnightMobileDesign.ColorToken.tertiaryGroupedBackground,
                            in: RoundedRectangle(cornerRadius: MidnightMobileDesign.Radius.small)
                        )

                    HStack(spacing: 16) {
                        Button {
                            UIPasteboard.general.string = publicKey
                            withAnimation { copied = true }
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(MidnightMobileDesign.FontToken.label)
                                .foregroundStyle(copied ? .green : identityAccent)
                        }
                        .buttonStyle(.plain)

                        ShareLink(item: publicKey) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(MidnightMobileDesign.FontToken.label)
                                .foregroundStyle(identityAccent)
                        }

                        Spacer()
                    }
                    .midnightMobileMinimumTapTarget()

                    Text("Append this line to ~/.ssh/authorized_keys on the SSH host, then set the connection's tunnel to use this identity.")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("This imported key is in a legacy format, so its public half can't be read back here. Use the matching .pub file from wherever you created the key.")
                        .font(MidnightMobileDesign.FontToken.caption)
                        .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
            .midnightMobileCard()
        }
    }
}

// MARK: - Create

struct MobileCreateSSHIdentityView: View {
    @Environment(\.dismiss) private var dismiss

    var onCreated: (MobileSSHIdentity) -> Void

    private enum Mode: String, CaseIterable {
        case generate
        case importKey

        var displayName: String {
            switch self {
            case .generate:  return "Generate"
            case .importKey: return "Import"
            }
        }
    }

    @State private var mode: Mode = .generate
    @State private var name = ""
    @State private var pastedKey = ""
    @State private var passphrase = ""
    @State private var errorText: String?
    @State private var created: MobileSSHIdentity?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let created {
                        successSection(created)
                    } else {
                        formSection
                    }
                }
                .padding()
            }
            .background(MidnightMobileDesign.ColorToken.groupedBackground.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(created == nil ? "New Identity" : "Identity Created")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if created == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(mode == .generate ? "Generate" : "Import", action: submit)
                            .font(MidnightMobileDesign.FontToken.label)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                      || (mode == .importKey && pastedKey.isEmpty))
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .font(MidnightMobileDesign.FontToken.label)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var formSection: some View {
        Picker("Mode", selection: $mode) {
            ForEach(Mode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        if let errorText {
            Text(errorText)
                .font(MidnightMobileDesign.FontToken.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }

        VStack(spacing: 14) {
            EditFormRow("Name") {
                TextField("e.g. iPad — production bastion", text: $name)
                    .textInputAutocapitalization(.words)
            }

            if mode == .importKey {
                Divider().background(MidnightMobileDesign.ColorToken.separator)

                Button {
                    pasteKeyFromClipboard()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.clipboard")
                        Text(pastedKey.isEmpty ? "Paste private key from clipboard" : "Private key pasted — tap to replace")
                            .font(MidnightMobileDesign.FontToken.label)
                        Spacer()
                    }
                    .foregroundStyle(identityAccent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .midnightMobileMinimumTapTarget()

                EditFormRow("Key Passphrase (Optional)") {
                    SecureField("Only if the key is encrypted", text: $passphrase)
                }
            }
        }
        .padding()
        .midnightMobileCard()

        Text(mode == .generate
             ? "A new Ed25519 keypair is generated on this device. The private key goes straight into the Keychain and never leaves — you install the public half on your servers."
             : "The key is stored in this device's Keychain and shared by every connection you point at this identity.")
            .font(MidnightMobileDesign.FontToken.caption)
            .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func successSection(_ identity: MobileSSHIdentity) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 4) {
                Text(identity.name)
                    .font(MidnightMobileDesign.FontToken.label)
                Text("Next: copy the public key below and add it to ~/.ssh/authorized_keys on the SSH host.")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(MidnightMobileDesign.ColorToken.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .midnightMobileCard()

        MobileSSHPublicKeyCard(identity: identity)
    }

    private func pasteKeyFromClipboard() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            errorText = "Clipboard is empty."
            return
        }
        pastedKey = text.trimmingCharacters(in: .whitespacesAndNewlines)
        errorText = nil
    }

    private func submit() {
        do {
            let identity: MobileSSHIdentity
            switch mode {
            case .generate:
                identity = try MobileSSHIdentityStore.shared.create(name: name)
            case .importKey:
                identity = try MobileSSHIdentityStore.shared.importKey(
                    name: name,
                    pem: pastedKey,
                    passphrase: passphrase
                )
            }
            errorText = nil
            created = identity
            onCreated(identity)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
