use std::fs;
use std::path::Path;

use clap::Parser;
use libp2p::identity;

#[derive(Parser)]
#[command(name = "haven-relay", about = "Haven combined relay + signaling server")]
pub struct Config {
    /// TCP port for libp2p relay
    #[arg(long, default_value = "4001")]
    pub libp2p_port: u16,

    /// HTTP port for signaling API
    #[arg(long, default_value = "8080")]
    pub http_port: u16,

    /// Path to the persistent keypair file
    #[arg(long, default_value = "./relay_keypair.bin")]
    pub keypair_file: String,

    /// Public IP address of this server (required for relay reservations)
    #[arg(long)]
    pub public_ip: String,
}

/// Load an existing keypair from disk, or generate a new one and save it.
pub fn load_or_create_keypair(path: &str) -> Result<identity::Keypair, String> {
    let file_path = Path::new(path);

    if file_path.exists() {
        let bytes =
            fs::read(file_path).map_err(|e| format!("Failed to read keypair file: {e}"))?;
        let keypair = identity::Keypair::from_protobuf_encoding(&bytes)
            .map_err(|e| format!("Failed to decode keypair: {e}"))?;
        tracing::info!("Loaded existing keypair from {path}");
        Ok(keypair)
    } else {
        let keypair = identity::Keypair::generate_ed25519();
        let bytes = keypair
            .to_protobuf_encoding()
            .map_err(|e| format!("Failed to encode keypair: {e}"))?;

        // Create parent directories if needed.
        if let Some(parent) = file_path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("Failed to create keypair directory: {e}"))?;
        }

        fs::write(file_path, bytes)
            .map_err(|e| format!("Failed to write keypair file: {e}"))?;
        tracing::info!("Generated new keypair, saved to {path}");
        Ok(keypair)
    }
}
