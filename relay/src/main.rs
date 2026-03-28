mod config;
mod signaling_http;
mod ws_router;

use std::collections::HashMap;
use std::sync::Arc;

use clap::Parser;
use tokio::sync::RwLock;

use config::Config;
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

    tracing::info!("========================================");
    tracing::info!("Hollow Signaling + WebSocket Relay");
    tracing::info!("HTTP port: {}", config.http_port);
    tracing::info!("========================================");

    // Shared state for the signaling HTTP server.
    let rooms: RoomMap = Arc::new(RwLock::new(HashMap::new()));

    // Shared state for the WebSocket room router.
    let ws_state = Arc::new(ws_router::WsState::new());

    // Run the HTTP/WS server. Ctrl+C shuts down.
    tokio::select! {
        result = signaling_http::run_signaling_http(rooms, ws_state, config.http_port) => {
            tracing::error!("HTTP/WS server exited: {result:?}");
        }
        _ = tokio::signal::ctrl_c() => {
            tracing::info!("Received Ctrl+C, shutting down...");
        }
    }

    Ok(())
}
