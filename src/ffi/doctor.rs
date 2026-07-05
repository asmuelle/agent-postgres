// ---------------------------------------------------------------------------
// Server Doctor — bounded, read-only diagnostic collection. The model layer
// stays in Swift; Rust owns the SSH collection allowlist and output caps.
// ---------------------------------------------------------------------------

#[derive(uniffi::Enum, Debug, Clone, Copy)]
pub enum FfiDoctorCollectorProfile {
    Host,
    Systemd,
    Nginx,
    Disk,
}

impl From<FfiDoctorCollectorProfile> for doctor::DoctorCollectorProfile {
    fn from(value: FfiDoctorCollectorProfile) -> Self {
        match value {
            FfiDoctorCollectorProfile::Host => doctor::DoctorCollectorProfile::Host,
            FfiDoctorCollectorProfile::Systemd => doctor::DoctorCollectorProfile::Systemd,
            FfiDoctorCollectorProfile::Nginx => doctor::DoctorCollectorProfile::Nginx,
            FfiDoctorCollectorProfile::Disk => doctor::DoctorCollectorProfile::Disk,
        }
    }
}

impl From<doctor::DoctorCollectorProfile> for FfiDoctorCollectorProfile {
    fn from(value: doctor::DoctorCollectorProfile) -> Self {
        match value {
            doctor::DoctorCollectorProfile::Host => FfiDoctorCollectorProfile::Host,
            doctor::DoctorCollectorProfile::Systemd => FfiDoctorCollectorProfile::Systemd,
            doctor::DoctorCollectorProfile::Nginx => FfiDoctorCollectorProfile::Nginx,
            doctor::DoctorCollectorProfile::Disk => FfiDoctorCollectorProfile::Disk,
        }
    }
}

#[derive(uniffi::Enum, Debug, Clone, Copy)]
pub enum FfiDoctorEvidenceKind {
    CommandOutput,
    LogExcerpt,
    ServiceStatus,
    MetricSample,
}

impl From<doctor::DoctorEvidenceKind> for FfiDoctorEvidenceKind {
    fn from(value: doctor::DoctorEvidenceKind) -> Self {
        match value {
            doctor::DoctorEvidenceKind::CommandOutput => FfiDoctorEvidenceKind::CommandOutput,
            doctor::DoctorEvidenceKind::LogExcerpt => FfiDoctorEvidenceKind::LogExcerpt,
            doctor::DoctorEvidenceKind::ServiceStatus => FfiDoctorEvidenceKind::ServiceStatus,
            doctor::DoctorEvidenceKind::MetricSample => FfiDoctorEvidenceKind::MetricSample,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiDoctorCollectRequest {
    pub connection_id: String,
    pub profiles: Vec<FfiDoctorCollectorProfile>,
    pub service_name: Option<String>,
    pub max_total_bytes: u32,
    pub per_command_timeout_ms: u32,
    pub log_line_limit: u32,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiDoctorPlannedCommand {
    pub id: String,
    pub profile: FfiDoctorCollectorProfile,
    pub display_name: String,
    pub command: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiDoctorCollectionPreview {
    pub planned_commands: Vec<FfiDoctorPlannedCommand>,
    pub possible_file_sources: Vec<String>,
    pub notes: Vec<String>,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiDoctorCommandAudit {
    pub id: String,
    pub collector_id: String,
    pub profile: FfiDoctorCollectorProfile,
    pub display_name: String,
    pub command: String,
    pub started_at_epoch_ms: u64,
    pub duration_ms: u32,
    pub exit_status: Option<i32>,
    pub stdout_bytes: u32,
    pub stderr_bytes: u32,
    pub truncated: bool,
    pub permission_limited: bool,
    pub read_only_risk: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiDoctorEvidence {
    pub id: String,
    pub kind: FfiDoctorEvidenceKind,
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
pub struct FfiDoctorWarning {
    pub id: String,
    pub message: String,
}

#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiDoctorCollectionBundle {
    pub id: String,
    pub collected_at_epoch_ms: u64,
    pub profiles: Vec<FfiDoctorCollectorProfile>,
    pub command_audits: Vec<FfiDoctorCommandAudit>,
    pub evidence: Vec<FfiDoctorEvidence>,
    pub warnings: Vec<FfiDoctorWarning>,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiDoctorError {
    #[error("connection not found: {id}")]
    ConnectionNotFound { id: String },
    #[error("invalid request: {message}")]
    InvalidRequest { message: String },
    #[error("collector failed: {message}")]
    CollectorFailed { message: String },
}

#[uniffi::export]
pub fn rshell_doctor_preview(
    request: FfiDoctorCollectRequest,
) -> Result<FfiDoctorCollectionPreview, FfiDoctorError> {
    let profiles = doctor_profiles_or_default(&request.profiles);
    let planned_commands = doctor::commands_for_profiles(&profiles)
        .into_iter()
        .map(|command| FfiDoctorPlannedCommand {
            id: command.id.to_string(),
            profile: command.profile.into(),
            display_name: command.display_name.to_string(),
            command: command.command.to_string(),
        })
        .collect();
    Ok(FfiDoctorCollectionPreview {
        planned_commands,
        possible_file_sources: doctor::possible_file_sources(&profiles),
        notes: doctor::preview_notes(),
    })
}

#[uniffi::export]
pub fn rshell_doctor_collect(
    request: FfiDoctorCollectRequest,
) -> Result<FfiDoctorCollectionBundle, FfiDoctorError> {
    let profiles = doctor_profiles_or_default(&request.profiles);
    let commands = doctor::commands_for_profiles(&profiles);
    if commands.is_empty() {
        return Err(FfiDoctorError::InvalidRequest {
            message: "no collector profiles selected".to_string(),
        });
    }
    for command in &commands {
        if !doctor::command_is_read_only(command.command) {
            return Err(FfiDoctorError::InvalidRequest {
                message: format!("collector command is not read-only: {}", command.id),
            });
        }
    }

    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let connection_id = request.connection_id.clone();
    bridge.runtime.block_on(async move {
        let client = cm.get_connection(&connection_id).await.ok_or_else(|| {
            FfiDoctorError::ConnectionNotFound {
                id: connection_id.clone(),
            }
        })?;
        let bundle_id = format!("doctor-{}", doctor_now_ms());
        let collected_at = doctor_now_ms();
        let max_total_bytes = request.max_total_bytes.max(16 * 1024) as usize;
        let per_command_cap = (max_total_bytes / commands.len().max(1)).clamp(8 * 1024, 256 * 1024);
        let line_limit = request.log_line_limit.max(40) as usize;
        let timeout = std::time::Duration::from_millis(u64::from(
            request.per_command_timeout_ms.clamp(500, 30_000),
        ));

        let mut command_audits = Vec::with_capacity(commands.len());
        let mut evidence = Vec::with_capacity(commands.len());
        let mut warnings = Vec::new();

        for (index, command) in commands.iter().enumerate() {
            let started_at = doctor_now_ms();
            let started = std::time::Instant::now();
            // Re-acquire the read lock per command instead of holding one
            // guard across the whole loop, so a long collection run
            // (up to ~12 commands x 30s timeout) doesn't block
            // disconnect/reconnect on this connection the entire time.
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
                        doctor::cap_text(&combined, per_command_cap, line_limit);
                    let permission_limited = doctor::permission_limited(&combined);
                    let exit_status = output
                        .exit_code
                        .map(|code| code.min(i32::MAX as u32) as i32);

                    command_audits.push(FfiDoctorCommandAudit {
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
                        read_only_risk: "read_only".to_string(),
                    });

                    evidence.push(FfiDoctorEvidence {
                        id: evidence_id.clone(),
                        kind: command.evidence_kind.into(),
                        title: command.display_name.to_string(),
                        source: command.command.to_string(),
                        collected_at_epoch_ms: started_at,
                        risk: "read_only".to_string(),
                        exit_status,
                        excerpt: capped.clone(),
                        raw_output: capped,
                        raw_ref: format!("doctor://{}/evidence/{}", bundle_id, evidence_id),
                        byte_count,
                        line_count,
                        truncated,
                        permission_limited,
                    });
                }
                Ok(Err(error)) => {
                    let message = error.to_string();
                    let permission_limited = doctor::permission_limited(&message);
                    command_audits.push(FfiDoctorCommandAudit {
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
                        read_only_risk: "read_only".to_string(),
                    });
                    warnings.push(FfiDoctorWarning {
                        id: format!("warning-{}-{}", command.id, index),
                        message: format!("{} failed: {}", command.display_name, message),
                    });
                    evidence.push(FfiDoctorEvidence {
                        id: evidence_id.clone(),
                        kind: command.evidence_kind.into(),
                        title: command.display_name.to_string(),
                        source: command.command.to_string(),
                        collected_at_epoch_ms: started_at,
                        risk: "read_only".to_string(),
                        exit_status: None,
                        excerpt: message.clone(),
                        raw_output: message.clone(),
                        raw_ref: format!("doctor://{}/evidence/{}", bundle_id, evidence_id),
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
                    command_audits.push(FfiDoctorCommandAudit {
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
                        read_only_risk: "read_only".to_string(),
                    });
                    warnings.push(FfiDoctorWarning {
                        id: format!("warning-{}-{}", command.id, index),
                        message: message.clone(),
                    });
                    evidence.push(FfiDoctorEvidence {
                        id: evidence_id.clone(),
                        kind: command.evidence_kind.into(),
                        title: command.display_name.to_string(),
                        source: command.command.to_string(),
                        collected_at_epoch_ms: started_at,
                        risk: "read_only".to_string(),
                        exit_status: None,
                        excerpt: message.clone(),
                        raw_output: message.clone(),
                        raw_ref: format!("doctor://{}/evidence/{}", bundle_id, evidence_id),
                        byte_count: message.len().min(u32::MAX as usize) as u32,
                        line_count: 1,
                        truncated: false,
                        permission_limited: false,
                    });
                }
            }
        }

        Ok(FfiDoctorCollectionBundle {
            id: bundle_id,
            collected_at_epoch_ms: collected_at,
            profiles: profiles.into_iter().map(Into::into).collect(),
            command_audits,
            evidence,
            warnings,
        })
    })
}

fn doctor_profiles_or_default(
    profiles: &[FfiDoctorCollectorProfile],
) -> Vec<doctor::DoctorCollectorProfile> {
    if profiles.is_empty() {
        vec![
            doctor::DoctorCollectorProfile::Host,
            doctor::DoctorCollectorProfile::Systemd,
            doctor::DoctorCollectorProfile::Nginx,
            doctor::DoctorCollectorProfile::Disk,
        ]
    } else {
        profiles.iter().copied().map(Into::into).collect()
    }
}

fn doctor_now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(u128::from(u64::MAX)) as u64)
        .unwrap_or(0)
}
