use std::process::Command;

use anyhow::{bail, Context, Result};

pub const KEYCHAIN_SERVICE: &str = "corplink-rs-otp";
pub const KEYCHAIN_ACCOUNT: &str = "corplink";

pub fn load_secret() -> Result<String> {
    let account = keychain_account();
    let output = Command::new("security")
        .args([
            "find-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            &account,
            "-w",
        ])
        .output()
        .context("failed to run security find-generic-password")?;

    if output.status.success() {
        let secret = String::from_utf8(output.stdout)
            .context("keychain returned non-utf8 secret")?
            .trim()
            .to_string();
        if secret.is_empty() {
            bail!("keychain entry is empty");
        }
        return Ok(secret);
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    if stderr.contains("could not be found") {
        bail!(
            "no TOTP secret in Keychain (service: {KEYCHAIN_SERVICE}, account: {account}); \
             run: corplink-otp import <otp_secret.json>"
        );
    }
    bail!("failed to read keychain secret: {stderr}");
}

pub fn import_secret(secret: &str, label: Option<&str>) -> Result<()> {
    let account = keychain_account();
    let mut cmd = Command::new("security");
    cmd.args([
        "add-generic-password",
        "-U",
        "-a",
        &account,
        "-s",
        KEYCHAIN_SERVICE,
        "-w",
        secret,
    ]);
    if let Some(label) = label {
        cmd.args(["-j", label]);
    }

    let output = cmd
        .output()
        .context("failed to run security add-generic-password")?;
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    bail!("failed to store secret in keychain: {stderr}");
}

fn keychain_account() -> String {
    std::env::var("CORPLINK_OTP_ACCOUNT").unwrap_or_else(|_| KEYCHAIN_ACCOUNT.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_account_is_corplink() {
        std::env::remove_var("CORPLINK_OTP_ACCOUNT");
        assert_eq!(keychain_account(), "corplink");
    }
}
