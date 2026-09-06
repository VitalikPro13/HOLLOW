//! Headless Hollow media forwarder (`--features forwarder --bin hollow-forwarder`),
//! run as a systemd unit on the VPS: `relay-uws/deploy/hollow-forwarder.service`.
//!
//! No signal handling on purpose: legs die with their sockets and viewers recover
//! through the receiver-initiates ladder, because the forwarder is an availability
//! helper, never authority.
//!
//! The cfg gates exist because cargokit passes `--features forwarder` to EVERY
//! platform build while the lib's `forwarder` module is desktop-only, so without
//! them an unresolved import here fails the whole mobile build.

#[cfg(not(any(target_os = "android", target_os = "ios")))]
use hollow_core::forwarder::{run, ForwarderConfig};

/// Mobile builds inherit `--features forwarder` with no forwarder module to drive,
/// so the bin stubs out. Never shipped or run.
#[cfg(any(target_os = "android", target_os = "ios"))]
fn main() {}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
#[tokio::main]
async fn main() {
    let mut config_path = "/etc/hollow-forwarder.toml".to_string();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--config" => match args.next() {
                Some(p) => config_path = p,
                None => {
                    eprintln!("--config needs a value");
                    std::process::exit(2);
                }
            },
            "--help" | "-h" => {
                println!("hollow-forwarder --config <path>   (default /etc/hollow-forwarder.toml)");
                return;
            }
            other => {
                eprintln!("unknown arg {other}");
                std::process::exit(2);
            }
        }
    }

    let cfg = match ForwarderConfig::load(&config_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("hollow-forwarder: {e}");
            std::process::exit(1);
        }
    };

    if let Err(e) = run(cfg).await {
        eprintln!("hollow-forwarder: fatal: {e}");
        std::process::exit(1);
    }
}
