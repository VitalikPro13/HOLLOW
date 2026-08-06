//! Headless Hollow media forwarder (`cargo build --release --features
//! forwarder --bin hollow-forwarder`). Runs as a systemd unit on the VPS —
//! see `relay-uws/deploy/hollow-forwarder.service`.
//!
//! No signal handling on purpose: systemd's SIGTERM kills the process, legs
//! die with their sockets, and viewers recover via the receiver-initiates
//! fallback ladder (the forwarder is an availability helper, never
//! authority).

use hollow_core::forwarder::{run, ForwarderConfig};

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
