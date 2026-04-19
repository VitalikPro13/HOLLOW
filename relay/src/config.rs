use clap::Parser;

#[derive(Parser)]
#[command(name = "hollow-relay", about = "Hollow signaling + WebSocket relay server")]
pub struct Config {
    /// HTTP port for signaling API and WebSocket relay
    #[arg(long, default_value = "8080")]
    pub http_port: u16,

    /// Public IP address of this server
    #[arg(long)]
    pub public_ip: String,

    /// Domain name for WSS (used in external address advertisement)
    #[arg(long, default_value = "relay.anonlisten.com")]
    pub domain: String,

    /// Path to license keys JSON file (optional, keys disabled if missing)
    #[arg(long, default_value = "keys.json")]
    pub keys_file: String,
}
