use std::path::Path;

use anyhow::Context;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct OtpSecretStore {
    pub secret: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    pub saved_at: String,
}

pub async fn load(path: &Path) -> anyhow::Result<OtpSecretStore> {
    let data = tokio::fs::read_to_string(path)
        .await
        .with_context(|| format!("failed to read otp secret file {}", path.display()))?;
    serde_json::from_str(&data).context("failed to parse otp secret file")
}
