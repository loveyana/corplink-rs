use std::env;
use std::process::exit;

use anyhow::{Context, Result};

use corplink_rs::client::Client;
use corplink_rs::config::Config;

#[cfg(windows)]
use is_elevated;

#[cfg(any(target_os = "macos", target_os = "linux"))]
use corplink_rs::dns::DNSManager;

use corplink_rs::config::WgConf;
use corplink_rs::wg;

enum Command {
    Connect(String),
    OtpFetch(String),
}

fn print_usage_and_exit(name: &str) -> ! {
    eprintln!(
        "usage:\n\
         \t{name} <config.json>              connect vpn (default config: config.json)\n\
         \t{name} otp fetch <config.json>     login and export TOTP secret only\n\
         \t{name} -h | --help"
    );
    exit(1)
}

fn parse_args() -> Command {
    let mut args: Vec<String> = env::args().collect();
    let name = args.first().cloned().unwrap_or_else(|| "corplink-rs".to_string());
    args.remove(0);

    match args.len() {
        0 => Command::Connect("config.json".to_string()),
        1 => match args[0].as_str() {
            "-h" | "--help" => print_usage_and_exit(&name),
            path => Command::Connect(path.to_string()),
        },
        2 if args[0] == "otp" && args[1] == "fetch" => print_usage_and_exit(&name),
        3 if args[0] == "otp" && args[1] == "fetch" => match args[2].as_str() {
            "-h" | "--help" => print_usage_and_exit(&name),
            path => Command::OtpFetch(path.to_string()),
        },
        _ => print_usage_and_exit(&name),
    }
}

pub const EPERM: i32 = 1;
pub const ENOENT: i32 = 2;
pub const ETIMEDOUT: i32 = 110;

#[tokio::main]
async fn main() {
    if let Err(err) = run().await {
        log::error!("{:#}", err);
        exit(EPERM);
    }
}

async fn run() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    print_version();

    match parse_args() {
        Command::OtpFetch(conf_file) => run_otp_fetch(conf_file).await,
        Command::Connect(conf_file) => run_connect(conf_file).await,
    }
}

async fn run_otp_fetch(conf_file: String) -> Result<()> {
    let mut conf = Config::from_file(&conf_file)
        .await
        .context("failed to load config")?;

    if conf.server.is_none() {
        let resp = corplink_rs::client::get_company_url(conf.company_name.as_str())
            .await
            .with_context(|| {
                format!(
                    "failed to fetch company server from company name {}",
                    conf.company_name
                )
            })?;
        log::info!(
            "company name is {}(zh)/{}(en) server is {}",
            resp.zh_name,
            resp.en_name,
            resp.domain
        );
        conf.server = Some(resp.domain);
        conf.save()
            .await
            .context("failed to persist company server")?;
    }

    let secret_path = conf.otp_secret_path()?;
    let mut client = Client::new(conf).context("failed to initialize client")?;
    log::info!("fetching TOTP secret");
    let secret = client
        .fetch_otp_secret()
        .await
        .context("failed to fetch TOTP secret")?;

    match secret {
        Some(_) => {
            log::info!("TOTP secret exported to {}", secret_path.display());
            println!("{}", secret_path.display());
        }
        None => {
            log::warn!("no TOTP secret was returned by the server");
            log::warn!("this can happen with lark/OIDC login (empty otp at connect time)");
        }
    }
    Ok(())
}

async fn run_connect(conf_file: String) -> Result<()> {
    let mut conf = Config::from_file(&conf_file)
        .await
        .context("failed to load config")?;
    let name = conf
        .interface_name
        .clone()
        .context("interface name missing in config")?;
    let socks5_listen = conf.socks5_listen.clone();
    let socks5_username = conf.socks5_username.clone().unwrap_or_default();
    let socks5_password = conf.socks5_password.clone().unwrap_or_default();
    let netstack_mode = socks5_listen.is_some();

    if !netstack_mode {
        check_privilege();
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    let use_vpn_dns = conf.use_vpn_dns.unwrap_or(false);
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    let dns_backup_filename = conf.dns_backup_filename.clone();

    if conf.server.is_none() {
        let resp = corplink_rs::client::get_company_url(conf.company_name.as_str())
            .await
            .with_context(|| {
                format!(
                    "failed to fetch company server from company name {}",
                    conf.company_name
                )
            })?;
        log::info!(
            "company name is {}(zh)/{}(en) server is {}",
            resp.zh_name,
            resp.en_name,
            resp.domain
        );
        conf.server = Some(resp.domain);
        conf.save()
            .await
            .context("failed to persist company server")?;
    }

    let with_wg_log = conf.debug_wg.unwrap_or_default();
    let platform = conf.platform.clone();
    let mut c = Client::new(conf).context("failed to initialize client")?;
    let mut logout_retry = true;
    let wg_conf: Option<WgConf>;

    loop {
        if c.need_login() {
            log::info!("not login yet, try to login");
            c.login().await.context("login failed")?;
            log::info!("login success");
        }
        log::info!("try to connect");
        match c.connect_vpn().await {
            Ok(conf) => {
                wg_conf = Some(conf);
                break;
            }
            Err(e) => {
                if logout_retry && e.to_string().contains("logout") {
                    log::warn!("{}", e);
                    logout_retry = false;
                    continue;
                } else {
                    return Err(e);
                }
            }
        };
    }
    let wg_conf = wg_conf.ok_or_else(|| anyhow::anyhow!("wg conf missing after connect loop"))?;
    let protocol = wg_conf.protocol;
    let mut uapi = wg::UAPIClient { name: name.clone() };
    if let Some(listen) = &socks5_listen {
        log::info!("start wg-corplink (netstack/socks5) on {}", listen);
        wg::start_wg_go_netstack(&wg_conf, listen, &socks5_username, &socks5_password, with_wg_log)
            .context("failed to start wg-corplink in netstack mode")?;
        uapi.config_wg_netstack(&wg_conf)
            .await
            .context("failed to config netstack interface with uapi")?;
        if socks5_username.is_empty() {
            log::info!("socks5 proxy ready at {} (no auth)", listen);
        } else {
            log::info!(
                "socks5 proxy ready at {} (username/password auth required)",
                listen
            );
        }
    } else {
        log::info!("start wg-corplink for {}", &name);
        wg::start_wg_go(&name, protocol, with_wg_log)
            .with_context(|| format!("failed to start wg-corplink for {}", name))?;
        uapi.config_wg(&wg_conf)
            .await
            .with_context(|| format!("failed to config interface with uapi for {name}"))?;
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    let mut dns_manager = DNSManager::new(dns_backup_filename);

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    if use_vpn_dns && !netstack_mode {
        match dns_manager.set_dns(vec![&wg_conf.dns], vec![]) {
            Ok(_) => {}
            Err(err) => {
                log::warn!("failed to set dns: {}", err);
            }
        }
    }

    let mut exit_code = 0;
    tokio::select! {
        _ = wait_for_shutdown_signal() => {},

        _ = async {
            uapi.check_wg_connection().await;
            log::warn!("last handshake timeout");
        } => {
            exit_code = ETIMEDOUT;
        },
    }

    log::info!("disconnecting vpn...");
    if let Err(e) = c.disconnect_vpn(&wg_conf).await {
        log::warn!("failed to disconnect vpn: {}", e)
    };

    if platform.as_deref() == Some(corplink_rs::config::PLATFORM_CORPLINK_V1) {
        log::info!("logging out current terminal...");
        if let Err(e) = c.logout().await {
            log::warn!("failed to logout: {}", e)
        };
    }

    wg::stop_wg_go();

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    if use_vpn_dns && !netstack_mode {
        match dns_manager.restore_dns() {
            Ok(_) => {}
            Err(err) => {
                log::warn!("failed to delete dns: {}", err);
            }
        }
    }

    log::info!("reach exit");
    exit(exit_code)
}

async fn wait_for_shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        let mut term = match signal(SignalKind::terminate()) {
            Ok(s) => Some(s),
            Err(e) => {
                log::warn!("failed to install SIGTERM handler: {}", e);
                None
            }
        };
        tokio::select! {
            r = tokio::signal::ctrl_c() => {
                if let Err(e) = r {
                    log::warn!("failed to receive signal: {}", e);
                }
                log::info!("ctrl+c received");
            }
            _ = async {
                match term.as_mut() {
                    Some(t) => { t.recv().await; }
                    None => std::future::pending::<()>().await,
                }
            } => {
                log::info!("SIGTERM received");
            }
        }
    }
    #[cfg(not(unix))]
    {
        if let Err(e) = tokio::signal::ctrl_c().await {
            log::warn!("failed to receive signal: {}", e);
        }
        log::info!("ctrl+c received");
    }
}

fn check_privilege() {
    #[cfg(unix)]
    match sudo::escalate_if_needed() {
        Ok(_) => {}
        Err(_) => {
            log::error!("please run as root");
            exit(EPERM);
        }
    }

    #[cfg(windows)]
    if !is_elevated::is_elevated() {
        log::error!("please run as administrator");
        exit(EPERM);
    }
}

fn print_version() {
    let pkg_name = env!("CARGO_PKG_NAME");
    let pkg_version = env!("CARGO_PKG_VERSION");
    log::info!("running {}@{}", pkg_name, pkg_version);
}
