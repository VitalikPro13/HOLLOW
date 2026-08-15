//! Headless Hollow media forwarder (`cargo build --release --features
//! forwarder --bin hollow-forwarder`). Runs as a systemd unit on the VPS —
//! see `relay-uws/deploy/hollow-forwarder.service`.
//!
//! No signal handling on purpose: systemd's SIGTERM kills the process, legs
//! die with their sockets, and viewers recover via the receiver-initiates
//! fallback ladder (the forwarder is an availability helper, never
//! authority).
//!
//! **Why the cfg gates below.** Cargo builds every `[[bin]]` whose
//! `required-features` are satisfied, and cargokit.yaml passes
//! `--features forwarder` to EVERY platform build (there is no per-platform
//! key). On Android/iOS the lib's `forwarder` module is cfg'd out
//! (`lib.rs`: str0m/aws-lc are desktop-only deps), so this bin has nothing to
//! import — and an unresolved import here failed the whole mobile build
//! ("could not compile `hollow_core` (bin \"hollow-forwarder\")", hit on an
//! iOS Archive 2026-08-15). The bin must therefore compile away to an empty
//! main on mobile rather than break the app it isn't part of.

#[cfg(not(any(target_os = "android", target_os = "ios")))]
use hollow_core::forwarder::{run, ForwarderConfig};

/// Mobile app builds inherit `--features forwarder`; there is no forwarder
/// module to drive there, so the bin is a no-op stub. Never shipped or run —
/// only the desktop/VPS build below is real.
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
