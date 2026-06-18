mod keychain;
mod secret;
mod totp;

use std::env;
use std::path::PathBuf;
use std::process::exit;

use anyhow::{bail, Context, Result};

fn print_usage(name: &str) {
    eprintln!(
        "usage:\n\
         \t{name}                         print current OTP (from macOS Keychain)\n\
         \t{name} --json                  JSON output: {{\"code\":\"...\",\"expires_in\":N}}\n\
         \t{name} import <otp_secret.json> store secret in macOS Keychain\n\
         \t{name} --file <otp_secret.json> read secret from file instead of Keychain\n\
         \t{name} --secret <base32_secret> use inline secret (debug only)\n\
         \n\
         Keychain: service=corplink-rs-otp, account=corplink \
         (override account via $CORPLINK_OTP_ACCOUNT)"
    );
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    if let Err(err) = run().await {
        eprintln!("{:#}", err);
        exit(1);
    }
}

async fn run() -> Result<()> {
    use keychain::{KEYCHAIN_ACCOUNT, KEYCHAIN_SERVICE};

    let name = env::args().next().unwrap_or_else(|| "corplink-otp".to_string());
    let mut args: Vec<String> = env::args().skip(1).collect();

    if args.is_empty() {
        return print_otp(false, None, None).await;
    }

    match args[0].as_str() {
        "-h" | "--help" => {
            print_usage(&name);
            return Ok(());
        }
        "import" => {
            args.remove(0);
            let path = args
                .first()
                .context("usage: corplink-otp import <otp_secret.json>")?;
            let path = PathBuf::from(path);
            let store = secret::load(&path).await?;
            let label = store
                .username
                .as_deref()
                .map(|u| format!("CorpLink OTP ({u})"));
            keychain::import_secret(&store.secret, label.as_deref())?;
            eprintln!(
                "stored TOTP secret in Keychain (service: {KEYCHAIN_SERVICE}, account: {KEYCHAIN_ACCOUNT})"
            );
            return Ok(());
        }
        _ => {}
    }

    let mut json_output = false;
    let mut secret_inline: Option<String> = None;
    let mut secret_file: Option<PathBuf> = None;

    while let Some(arg) = args.first().cloned() {
        match arg.as_str() {
            "--json" => {
                json_output = true;
                args.remove(0);
            }
            "--secret" => {
                args.remove(0);
                secret_inline = Some(
                    args.first()
                        .context("missing value for --secret")?
                        .clone(),
                );
                args.remove(0);
            }
            "--file" => {
                args.remove(0);
                secret_file = Some(
                    args.first()
                        .context("missing value for --file")?
                        .into(),
                );
                args.remove(0);
            }
            "-h" | "--help" => {
                print_usage(&name);
                return Ok(());
            }
            other if other.starts_with('-') => {
                bail!("unknown flag: {other}");
            }
            path => {
                secret_file = Some(PathBuf::from(path));
                args.remove(0);
            }
        }
    }

    print_otp(json_output, secret_inline, secret_file).await
}

async fn print_otp(
    json_output: bool,
    secret_inline: Option<String>,
    secret_file: Option<PathBuf>,
) -> Result<()> {
    let secret_b32 = if let Some(secret) = secret_inline {
        secret
    } else if let Some(path) = secret_file {
        secret::load(&path).await?.secret
    } else if let Ok(path) = env::var("CORPLINK_OTP_SECRET_FILE") {
        secret::load(PathBuf::from(path).as_path())
            .await?
            .secret
    } else {
        keychain::load_secret()?
    };

    let (code, secs_left) = totp::generate_code(&secret_b32)?;
    if json_output {
        let payload = serde_json::json!({
            "code": code,
            "expires_in": secs_left,
        });
        println!("{}", serde_json::to_string(&payload)?);
    } else {
        println!("{code}");
        eprintln!("expires in {secs_left} seconds");
    }
    Ok(())
}
