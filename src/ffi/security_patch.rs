// ---------------------------------------------------------------------------
// Security Patch Monitor — bounded, read-only package/update and sshd checks.
// Rust owns command allowlisting; Swift owns parsing, scoring, and UI.
// ---------------------------------------------------------------------------

#[derive(uniffi::Enum, Debug, Clone, Copy)]
pub enum FfiSecurityPatchCollectorProfile {
    Os,
    PackageManager,
    Reboot,
    Sshd,
    NetworkExposure,
}

impl From<FfiSecurityPatchCollectorProfile> for security_patch::SecurityPatchCollectorProfile {
    fn from(value: FfiSecurityPatchCollectorProfile) -> Self {
        match value {
            FfiSecurityPatchCollectorProfile::Os => {
                security_patch::SecurityPatchCollectorProfile::Os
            }
            FfiSecurityPatchCollectorProfile::PackageManager => {
                security_patch::SecurityPatchCollectorProfile::PackageManager
            }
            FfiSecurityPatchCollectorProfile::Reboot => {
                security_patch::SecurityPatchCollectorProfile::Reboot
            }
            FfiSecurityPatchCollectorProfile::Sshd => {
                security_patch::SecurityPatchCollectorProfile::Sshd
            }
            FfiSecurityPatchCollectorProfile::NetworkExposure => {
                security_patch::SecurityPatchCollectorProfile::NetworkExposure
            }
        }
    }
}

impl From<security_patch::SecurityPatchCollectorProfile> for FfiSecurityPatchCollectorProfile {
    fn from(value: security_patch::SecurityPatchCollectorProfile) -> Self {
        match value {
            security_patch::SecurityPatchCollectorProfile::Os => {
                FfiSecurityPatchCollectorProfile::Os
            }
            security_patch::SecurityPatchCollectorProfile::PackageManager => {
                FfiSecurityPatchCollectorProfile::PackageManager
            }
            security_patch::SecurityPatchCollectorProfile::Reboot => {
                FfiSecurityPatchCollectorProfile::Reboot
            }
            security_patch::SecurityPatchCollectorProfile::Sshd => {
                FfiSecurityPatchCollectorProfile::Sshd
            }
            security_patch::SecurityPatchCollectorProfile::NetworkExposure => {
                FfiSecurityPatchCollectorProfile::NetworkExposure
            }
        }
    }
}

#[derive(uniffi::Enum, Debug, Clone, Copy)]
pub enum FfiSecurityPatchEvidenceKind {
    CommandOutput,
    OsRelease,
    PackageStatus,
    RebootStatus,
    SshdConfig,
    NetworkExposure,
}

impl From<security_patch::SecurityPatchEvidenceKind> for FfiSecurityPatchEvidenceKind {
    fn from(value: security_patch::SecurityPatchEvidenceKind) -> Self {
        match value {
            security_patch::SecurityPatchEvidenceKind::CommandOutput => {
                FfiSecurityPatchEvidenceKind::CommandOutput
            }
            security_patch::SecurityPatchEvidenceKind::OsRelease => {
                FfiSecurityPatchEvidenceKind::OsRelease
            }
            security_patch::SecurityPatchEvidenceKind::PackageStatus => {
                FfiSecurityPatchEvidenceKind::PackageStatus
            }
            security_patch::SecurityPatchEvidenceKind::RebootStatus => {
                FfiSecurityPatchEvidenceKind::RebootStatus
            }
            security_patch::SecurityPatchEvidenceKind::SshdConfig => {
                FfiSecurityPatchEvidenceKind::SshdConfig
            }
            security_patch::SecurityPatchEvidenceKind::NetworkExposure => {
                FfiSecurityPatchEvidenceKind::NetworkExposure
            }
        }
    }
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiSecurityPatchScanRequest {
    pub connection_id: String,
    pub profiles: Vec<FfiSecurityPatchCollectorProfile>,
    pub max_total_bytes: u32,
    pub per_command_timeout_ms: u32,
    pub line_limit: u32,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiSecurityPatchPlannedCommand {
    pub id: String,
    pub profile: FfiSecurityPatchCollectorProfile,
    pub display_name: String,
    pub command: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiSecurityPatchScanPreview {
    pub planned_commands: Vec<FfiSecurityPatchPlannedCommand>,
    pub notes: Vec<String>,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiSecurityPatchCommandAudit {
    pub id: String,
    pub collector_id: String,
    pub profile: FfiSecurityPatchCollectorProfile,
    pub display_name: String,
    pub command: String,
    pub started_at_epoch_ms: u64,
    pub duration_ms: u32,
    pub exit_status: Option<i32>,
    pub stdout_bytes: u32,
    pub stderr_bytes: u32,
    pub truncated: bool,
    pub permission_limited: bool,
    pub risk: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiSecurityPatchEvidence {
    pub id: String,
    pub collector_id: String,
    pub profile: FfiSecurityPatchCollectorProfile,
    pub kind: FfiSecurityPatchEvidenceKind,
    pub title: String,
    pub source: String,
    pub collected_at_epoch_ms: u64,
    pub risk: String,
    pub exit_status: Option<i32>,
    pub excerpt: String,
    pub raw_output: String,
    pub raw_ref: String,
    pub byte_count: u32,
    pub line_count: u32,
    pub truncated: bool,
    pub permission_limited: bool,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiSecurityPatchWarning {
    pub id: String,
    pub message: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiSecurityPatchScanBundle {
    pub id: String,
    pub scanned_at_epoch_ms: u64,
    pub profiles: Vec<FfiSecurityPatchCollectorProfile>,
    pub command_audits: Vec<FfiSecurityPatchCommandAudit>,
    pub evidence: Vec<FfiSecurityPatchEvidence>,
    pub warnings: Vec<FfiSecurityPatchWarning>,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiSecurityPatchError {
    #[error("connection not found: {id}")]
    ConnectionNotFound { id: String },
    #[error("invalid request: {message}")]
    InvalidRequest { message: String },
    #[error("collector failed: {message}")]
    CollectorFailed { message: String },
}

#[uniffi::export]
pub fn rshell_security_patch_preview(
    request: FfiSecurityPatchScanRequest,
) -> Result<FfiSecurityPatchScanPreview, FfiSecurityPatchError> {
    let profiles = security_patch_profiles_or_default(&request.profiles);
    let planned_commands = security_patch::commands_for_profiles(&profiles)
        .into_iter()
        .map(|command| FfiSecurityPatchPlannedCommand {
            id: command.id.to_string(),
            profile: command.profile.into(),
            display_name: command.display_name.to_string(),
            command: command.command.to_string(),
        })
        .collect();
    Ok(FfiSecurityPatchScanPreview {
        planned_commands,
        notes: security_patch::preview_notes(),
    })
}

#[uniffi::export]
pub fn rshell_security_patch_scan(
    request: FfiSecurityPatchScanRequest,
) -> Result<FfiSecurityPatchScanBundle, FfiSecurityPatchError> {
    let profiles = security_patch_profiles_or_default(&request.profiles);
    let commands = security_patch::commands_for_profiles(&profiles);
    if commands.is_empty() {
        return Err(FfiSecurityPatchError::InvalidRequest {
            message: "no security patch collector profiles selected".to_string(),
        });
    }
    for command in &commands {
        if !security_patch::command_is_read_only(command.command) {
            return Err(FfiSecurityPatchError::InvalidRequest {
                message: format!("collector command is not read-only: {}", command.id),
            });
        }
    }

    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let connection_id = request.connection_id.clone();
    bridge.runtime.block_on(async move {
        let client = cm.get_connection(&connection_id).await.ok_or_else(|| {
            FfiSecurityPatchError::ConnectionNotFound {
                id: connection_id.clone(),
            }
        })?;
        let bundle_id = format!("security-patch-{}", doctor_now_ms());
        let scanned_at = doctor_now_ms();
        let max_total_bytes = request.max_total_bytes.max(16 * 1024) as usize;
        let per_command_cap = (max_total_bytes / commands.len().max(1)).clamp(8 * 1024, 256 * 1024);
        let line_limit = request.line_limit.max(40) as usize;
        let timeout = std::time::Duration::from_millis(u64::from(
            request.per_command_timeout_ms.clamp(500, 45_000),
        ));

        let mut command_audits = Vec::with_capacity(commands.len());
        let mut evidence = Vec::with_capacity(commands.len());
        let mut warnings = Vec::new();

        for (index, command) in commands.iter().enumerate() {
            let started_at = doctor_now_ms();
            let started = std::time::Instant::now();
            // Re-acquire the read lock per command instead of holding one
            // guard across the whole loop, so a long scan run doesn't
            // block disconnect/reconnect on this connection the entire
            // time.
            let result = {
                let guard = client.read().await;
                tokio::time::timeout(timeout, guard.execute_command_full(command.command)).await
            };
            let duration_ms = started.elapsed().as_millis().min(u128::from(u32::MAX)) as u32;
            let evidence_id = format!("evidence-{}-{}", command.id, index);
            let audit_id = format!("audit-{}-{}", command.id, index);

            match result {
                Ok(Ok(output)) => {
                    let stdout = output.stdout;
                    let stderr = output.stderr;
                    let mut combined = stdout.clone();
                    if !stderr.is_empty() {
                        if !combined.is_empty() {
                            combined.push('\n');
                        }
                        combined.push_str(&stderr);
                    }
                    let (capped, truncated, byte_count, line_count) =
                        security_patch::cap_text(&combined, per_command_cap, line_limit);
                    let permission_limited = security_patch::permission_limited(&combined);
                    let exit_status = output
                        .exit_code
                        .map(|code| code.min(i32::MAX as u32) as i32);

                    command_audits.push(FfiSecurityPatchCommandAudit {
                        id: audit_id,
                        collector_id: command.id.to_string(),
                        profile: command.profile.into(),
                        display_name: command.display_name.to_string(),
                        command: command.command.to_string(),
                        started_at_epoch_ms: started_at,
                        duration_ms,
                        exit_status,
                        stdout_bytes: stdout.len().min(u32::MAX as usize) as u32,
                        stderr_bytes: stderr.len().min(u32::MAX as usize) as u32,
                        truncated,
                        permission_limited,
                        risk: "read_only".to_string(),
                    });

                    evidence.push(FfiSecurityPatchEvidence {
                        id: evidence_id.clone(),
                        collector_id: command.id.to_string(),
                        profile: command.profile.into(),
                        kind: command.evidence_kind.into(),
                        title: command.display_name.to_string(),
                        source: command.command.to_string(),
                        collected_at_epoch_ms: started_at,
                        risk: "read_only".to_string(),
                        exit_status,
                        excerpt: capped.clone(),
                        raw_output: capped,
                        raw_ref: format!("security-patch://{}/evidence/{}", bundle_id, evidence_id),
                        byte_count,
                        line_count,
                        truncated,
                        permission_limited,
                    });
                }
                Ok(Err(error)) => {
                    let message = error.to_string();
                    let permission_limited = security_patch::permission_limited(&message);
                    command_audits.push(FfiSecurityPatchCommandAudit {
                        id: audit_id,
                        collector_id: command.id.to_string(),
                        profile: command.profile.into(),
                        display_name: command.display_name.to_string(),
                        command: command.command.to_string(),
                        started_at_epoch_ms: started_at,
                        duration_ms,
                        exit_status: None,
                        stdout_bytes: 0,
                        stderr_bytes: message.len().min(u32::MAX as usize) as u32,
                        truncated: false,
                        permission_limited,
                        risk: "read_only".to_string(),
                    });
                    warnings.push(FfiSecurityPatchWarning {
                        id: format!("warning-{}-{}", command.id, index),
                        message: format!("{} failed: {}", command.display_name, message),
                    });
                    evidence.push(FfiSecurityPatchEvidence {
                        id: evidence_id.clone(),
                        collector_id: command.id.to_string(),
                        profile: command.profile.into(),
                        kind: command.evidence_kind.into(),
                        title: command.display_name.to_string(),
                        source: command.command.to_string(),
                        collected_at_epoch_ms: started_at,
                        risk: "read_only".to_string(),
                        exit_status: None,
                        excerpt: message.clone(),
                        raw_output: message.clone(),
                        raw_ref: format!("security-patch://{}/evidence/{}", bundle_id, evidence_id),
                        byte_count: message.len().min(u32::MAX as usize) as u32,
                        line_count: message.lines().count().min(u32::MAX as usize) as u32,
                        truncated: false,
                        permission_limited,
                    });
                }
                Err(_) => {
                    let message = format!(
                        "{} timed out after {} ms",
                        command.display_name,
                        timeout.as_millis()
                    );
                    command_audits.push(FfiSecurityPatchCommandAudit {
                        id: audit_id,
                        collector_id: command.id.to_string(),
                        profile: command.profile.into(),
                        display_name: command.display_name.to_string(),
                        command: command.command.to_string(),
                        started_at_epoch_ms: started_at,
                        duration_ms,
                        exit_status: None,
                        stdout_bytes: 0,
                        stderr_bytes: 0,
                        truncated: false,
                        permission_limited: false,
                        risk: "read_only".to_string(),
                    });
                    warnings.push(FfiSecurityPatchWarning {
                        id: format!("warning-{}-{}", command.id, index),
                        message: message.clone(),
                    });
                    evidence.push(FfiSecurityPatchEvidence {
                        id: evidence_id.clone(),
                        collector_id: command.id.to_string(),
                        profile: command.profile.into(),
                        kind: command.evidence_kind.into(),
                        title: command.display_name.to_string(),
                        source: command.command.to_string(),
                        collected_at_epoch_ms: started_at,
                        risk: "read_only".to_string(),
                        exit_status: None,
                        excerpt: message.clone(),
                        raw_output: message.clone(),
                        raw_ref: format!("security-patch://{}/evidence/{}", bundle_id, evidence_id),
                        byte_count: message.len().min(u32::MAX as usize) as u32,
                        line_count: 1,
                        truncated: false,
                        permission_limited: false,
                    });
                }
            }
        }

        Ok(FfiSecurityPatchScanBundle {
            id: bundle_id,
            scanned_at_epoch_ms: scanned_at,
            profiles: profiles.into_iter().map(Into::into).collect(),
            command_audits,
            evidence,
            warnings,
        })
    })
}

fn security_patch_profiles_or_default(
    profiles: &[FfiSecurityPatchCollectorProfile],
) -> Vec<security_patch::SecurityPatchCollectorProfile> {
    if profiles.is_empty() {
        vec![
            security_patch::SecurityPatchCollectorProfile::Os,
            security_patch::SecurityPatchCollectorProfile::PackageManager,
            security_patch::SecurityPatchCollectorProfile::Reboot,
            security_patch::SecurityPatchCollectorProfile::Sshd,
            security_patch::SecurityPatchCollectorProfile::NetworkExposure,
        ]
    } else {
        profiles.iter().copied().map(Into::into).collect()
    }
}
