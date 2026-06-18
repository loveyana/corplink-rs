use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use chrono::Utc;
use serde::{Deserialize, Serialize};

use crate::totp::{totp_offset, TIME_STEP};
use crate::utils;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct OtpSecretStore {
    pub secret: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    pub saved_at: String,
}

impl OtpSecretStore {
    pub fn new(secret: impl Into<String>, username: Option<String>) -> Self {
        Self {
            secret: secret.into(),
            username,
            saved_at: Utc::now().to_rfc3339(),
        }
    }
}

pub fn default_secret_path(config_file: &Path, interface_name: &str) -> PathBuf {
    let dir = config_file.parent().unwrap_or_else(|| Path::new("."));
    dir.join(format!("{interface_name}_otp_secret.json"))
}

pub async fn save(path: &Path, store: &OtpSecretStore) -> Result<()> {
    let data = serde_json::to_string_pretty(store)?;
    tokio::fs::write(path, data)
        .await
        .with_context(|| format!("failed to write otp secret file {}", path.display()))?;
    Ok(())
}

pub async fn load(path: &Path) -> Result<OtpSecretStore> {
    let data = tokio::fs::read_to_string(path)
        .await
        .with_context(|| format!("failed to read otp secret file {}", path.display()))?;
    serde_json::from_str(&data).context("failed to parse otp secret file")
}

pub fn generate_code(secret_b32: &str, time_offset_sec: i32) -> Result<OtpCode> {
    let key = utils::b32_decode(secret_b32)?;
    let offset = time_offset_sec / TIME_STEP as i32;
    let slot = totp_offset(key.as_slice(), offset);
    Ok(OtpCode {
        code: format!("{:06}", slot.code),
        secs_left: slot.secs_left,
    })
}

#[derive(Debug, Clone)]
pub struct OtpCode {
    pub code: String,
    pub secs_left: u32,
}
