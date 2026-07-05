// ---------------------------------------------------------------------------
// Keychain FFI — wraps ssh-commander-core keychain for Swift access.
// ---------------------------------------------------------------------------

#[derive(uniffi::Enum)]
pub enum FfiCredentialKind {
    SshPassword,
    SshKeyPassphrase,
    SftpPassword,
    SftpKeyPassphrase,
    FtpPassword,
    PostgresPassword,
}

impl From<FfiCredentialKind> for ssh_commander_core::keychain::CredentialKind {
    fn from(k: FfiCredentialKind) -> Self {
        match k {
            FfiCredentialKind::SshPassword => Self::SshPassword,
            FfiCredentialKind::SshKeyPassphrase => Self::SshKeyPassphrase,
            FfiCredentialKind::SftpPassword => Self::SftpPassword,
            FfiCredentialKind::SftpKeyPassphrase => Self::SftpKeyPassphrase,
            FfiCredentialKind::FtpPassword => Self::FtpPassword,
            FfiCredentialKind::PostgresPassword => Self::PostgresPassword,
        }
    }
}

#[uniffi::export]
pub fn rshell_keychain_is_supported() -> bool {
    ssh_commander_core::keychain::is_supported()
}

#[uniffi::export]
pub fn rshell_keychain_save(kind: FfiCredentialKind, account: String, secret: String) -> FfiResult {
    let core_kind: ssh_commander_core::keychain::CredentialKind = kind.into();
    match ssh_commander_core::keychain::save_password(core_kind, &account, &secret) {
        Ok(_) => FfiResult {
            success: true,
            error: None,
            value: None,
        },
        Err(e) => FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        },
    }
}

#[uniffi::export]
pub fn rshell_keychain_load(kind: FfiCredentialKind, account: String) -> FfiResult {
    let core_kind: ssh_commander_core::keychain::CredentialKind = kind.into();
    match ssh_commander_core::keychain::load_password(core_kind, &account) {
        Ok(Some(secret)) => FfiResult {
            success: true,
            error: None,
            value: Some(secret),
        },
        Ok(None) => FfiResult {
            success: true,
            error: None,
            value: None,
        },
        Err(e) => FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        },
    }
}

#[uniffi::export]
pub fn rshell_keychain_delete(kind: FfiCredentialKind, account: String) -> FfiResult {
    let core_kind: ssh_commander_core::keychain::CredentialKind = kind.into();
    match ssh_commander_core::keychain::delete_password(core_kind, &account) {
        Ok(_) => FfiResult {
            success: true,
            error: None,
            value: None,
        },
        Err(e) => FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        },
    }
}

#[uniffi::export]
pub fn rshell_keychain_list(kind: FfiCredentialKind) -> Vec<String> {
    let core_kind: ssh_commander_core::keychain::CredentialKind = kind.into();
    ssh_commander_core::keychain::list_accounts(core_kind).unwrap_or_default()
}
