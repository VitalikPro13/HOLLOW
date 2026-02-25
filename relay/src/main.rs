mod config;
mod relay_node;
mod signaling_http;

use std::collections::HashMap;
use std::sync::Arc;

use clap::Parser;
use tokio::sync::RwLock;

use config::{Config, load_or_create_keypair};
use signaling_http::RoomMap;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize structured logging.
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let config = Config::parse();

    // Load or create the relay node's persistent identity.
    let keypair = load_or_create_keypair(&config.keypair_file)
        .map_err(|e| format!("Keypair error: {e}"))?;
    let peer_id = keypair.public().to_peer_id();

    tracing::info!("========================================");
    tracing::info!("Haven Relay + Signaling Server");
    tracing::info!("PeerId: {peer_id}");
    tracing::info!("libp2p port: {}", config.libp2p_port);
    tracing::info!("HTTP port: {}", config.http_port);
    tracing::info!("========================================");

    // Shared state for the signaling HTTP server.
    let rooms: RoomMap = Arc::new(RwLock::new(HashMap::new()));

    // Run both services concurrently. If either exits, we shut down.
    tokio::select! {
        result = relay_node::run_relay_node(keypair, &config) => {
            tracing::error!("Relay node exited: {result:?}");
        }
        result = signaling_http::run_signaling_http(rooms, config.http_port) => {
            tracing::error!("HTTP server exited: {result:?}");
        }
        _ = tokio::signal::ctrl_c() => {
            tracing::info!("Received Ctrl+C, shutting down...");
        }
    }

    Ok(())
}
