mod secret;
mod totp;

use std::env;
use std::path::PathBuf;
use std::process::exit;

use anyhow::{bail, Context, Result};

fn print_usage(name: &str) {
    eprintln!(
        "usage:\n\
         \t{name} <otp_secret.json>\n\
         \t{name} --secret <base32_secret>\n\
         \t{name} --json <otp_secret.json>\n\
         \n\
         Reads the secret file exported by: corplink-rs otp fetch <config.json>\n\
         Default file: $CORPLINK_OTP_SECRET_FILE or ./corplink_otp_secret.json"
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
    let name = env::args().next().unwrap_or_else(|| "corplink-otp".to_string());
    let mut args: Vec<String> = env::args().skip(1).collect();

    if args.is_empty() || matches!(args[0].as_str(), "-h" | "--help") {
        print_usage(&name);
        return Ok(());
    }

    let mut json_output = false;
    let mut secret_inline: Option<String> = None;
    let mut secret_file = env::var("CORPLINK_OTP_SECRET_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("corplink_otp_secret.json"));

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
            "-h" | "--help" => {
                print_usage(&name);
                return Ok(());
            }
            other if other.starts_with('-') => {
                bail!("unknown flag: {other}");
            }
            path => {
                secret_file = PathBuf::from(path);
                args.remove(0);
            }
        }
    }

    let secret_b32 = match secret_inline {
        Some(secret) => secret,
        None => {
            let store = secret::load(&secret_file).await?;
            store.secret
        }
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
