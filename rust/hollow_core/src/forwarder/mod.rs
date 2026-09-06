//! Hollow media forwarder: a blind packet relay for SFrame-encrypted screen-share
//! RTP, one ingest leg fanning ciphertext to N egress legs (`B + B·k` instead of
//! TURN's `2·B·k`). It terminates only the hop-by-hop DTLS-SRTP layer, holds no
//! group keys and is not a Hollow node, so it can never read or tamper with media:
//! availability helper, never authority. Control plane is Olm-encrypted `fwd_*`
//! envelopes in the `fwd:{peer_id}` room, media plane str0m in rtp mode. Identity
//! is ONE keypair (`forwarder.key`); rotation mints a NEW identity and updates the
//! relay's `--forwarder-peer-id`, because re-keying the same peer_id trips clients'
//! pinned Olm identity key and raises SecurityAlerts.

pub(crate) mod budget;
pub(crate) mod dispatch;
pub(crate) mod engine;
pub(crate) mod leg;
pub(crate) mod signaling;
pub(crate) mod simulcast;
pub(crate) mod stream;
pub(crate) mod stun;

use std::sync::Arc;

use tokio::sync::mpsc;

use crate::hollow_log;
use crate::identity::native_identity::NativeKeypair;

fn default_port_min() -> u16 { 40000 }
fn default_port_max() -> u16 { 40199 }
fn default_streams_global() -> u32 { 16 }
fn default_streams_per_sender() -> u32 { 4 }
fn default_legs_per_stream() -> u32 { 32 }
/// Default egress budget: 400 Mbps, headroom under the VPS's 1 Gbps port with room
/// left for the relay's own traffic.
fn default_egress_bps() -> u64 { 400_000_000 }

/// Forwarder configuration (TOML file + env overrides — see
/// `relay-uws/deploy/hollow-forwarder.service`).
#[derive(Debug, Clone, serde::Deserialize)]
pub struct ForwarderConfig {
    /// Relay domain (WSS signaling), e.g. "relay.anonlisten.com".
    pub relay_domain: String,
    /// Relay license key, `None` on the open public relay. Env override:
    /// `HOLLOW_FWD_LICENSE_KEY`.
    #[serde(default)]
    pub license_key: Option<String>,
    /// Data directory (identity keypair, Olm DB, debug log).
    pub data_dir: String,
    /// The public IP advertised in ICE host candidates; sockets bind 0.0.0.0. EMPTY
    /// means an embedded peer forwarder (LAN IP + per-leg STUN mapping instead).
    pub public_ip: String,
    /// STUN server ("host:port") for embedded auto-advertise mode. The VPS
    /// never sets this — its public host candidate is sufficient.
    #[serde(default)]
    pub stun_server: Option<String>,
    #[serde(default = "default_port_min")]
    pub udp_port_min: u16,
    #[serde(default = "default_port_max")]
    pub udp_port_max: u16,
    #[serde(default = "default_streams_global")]
    pub max_streams_global: u32,
    #[serde(default = "default_streams_per_sender")]
    pub max_streams_per_sender: u32,
    #[serde(default = "default_legs_per_stream")]
    pub max_legs_per_stream: u32,
    /// Global egress budget in bits/sec (0 = unlimited). Refuse-new-only:
    /// existing legs are never degraded or evicted.
    #[serde(default = "default_egress_bps")]
    pub max_egress_bps: u64,
}

impl ForwarderConfig {
    /// Load from a TOML file, then apply env overrides so secrets stay out of the
    /// world-readable config.
    pub fn load(path: &str) -> Result<Self, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read config {path}: {e}"))?;
        let mut cfg: ForwarderConfig =
            toml::from_str(&text).map_err(|e| format!("config parse error: {e}"))?;
        if let Ok(key) = std::env::var("HOLLOW_FWD_LICENSE_KEY") {
            if !key.is_empty() {
                cfg.license_key = Some(key);
            }
        }
        if cfg.udp_port_min > cfg.udp_port_max {
            return Err("udp_port_min > udp_port_max".into());
        }
        Ok(cfg)
    }
}

/// Embedded peer-forwarder engine: spawns ONLY `engine::run`, with no identity, DB,
/// Olm or signaling loop, because the swarm bridges the fwd_* lane in
/// (`node/embedded_forwarder.rs`).
///
/// Caps are deliberately small: this is a member's desktop, not the VPS, and with
/// one stream copy per leg the leg count IS the budget.
pub(crate) fn spawn_embedded_engine(
    stun_server: Option<String>,
) -> (
    mpsc::UnboundedSender<engine::EngineCmd>,
    mpsc::UnboundedReceiver<engine::OutSignal>,
) {
    let cfg = Arc::new(ForwarderConfig {
        relay_domain: String::new(), // unused by the engine
        license_key: None,           // unused by the engine
        data_dir: String::new(),     // unused by the engine
        public_ip: String::new(),    // auto-advertise
        stun_server,
        udp_port_min: 0, // ephemeral
        udp_port_max: 0,
        max_streams_global: 2,
        max_streams_per_sender: 2,
        max_legs_per_stream: 4,
        max_egress_bps: 0,
    });
    let (engine_tx, engine_rx) = mpsc::unbounded_channel::<engine::EngineCmd>();
    let (out_tx, out_rx) = mpsc::unbounded_channel::<engine::OutSignal>();
    tokio::spawn(engine::run(cfg, engine_rx, out_tx));
    (engine_tx, out_rx)
}

/// Load `forwarder.key` or mint a fresh identity on first run.
fn load_or_mint_identity(data_dir: &std::path::Path) -> Result<NativeKeypair, String> {
    let path = data_dir.join("forwarder.key");
    if path.exists() {
        let bytes =
            std::fs::read(&path).map_err(|e| format!("cannot read forwarder.key: {e}"))?;
        return NativeKeypair::from_protobuf_encoding(&bytes);
    }
    let mut secret = [0u8; 32];
    getrandom::fill(&mut secret).map_err(|e| format!("entropy failure: {e}"))?;
    let keypair = NativeKeypair::from_secret_bytes(&secret);
    let proto = keypair.to_protobuf_encoding()?;
    std::fs::write(&path, &proto).map_err(|e| format!("cannot write forwarder.key: {e}"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    hollow_log!("[HOLLOW-FWD] minted new forwarder identity");
    Ok(keypair)
}

/// Run the forwarder. Returns only on a fatal error (bad config, license refused,
/// storage failure); the signaling loop reconnects forever otherwise.
pub async fn run(cfg: ForwarderConfig) -> Result<(), String> {
    crate::identity::set_data_dir(cfg.data_dir.clone())?;
    crate::log::init();
    let data_dir = crate::identity::data_dir()?;
    let keypair = load_or_mint_identity(&data_dir)?;
    let peer_id = keypair.peer_id();
    // The operator pastes this peer_id into the relay's --forwarder-peer-id.
    hollow_log!("[HOLLOW-FWD] forwarder peer_id: {peer_id}");

    // The key file IS the secret; the DB passphrase just follows it.
    let proto = keypair.to_protobuf_encoding()?;
    let passphrase = hex::encode(&proto[..32]);
    let db_path = data_dir
        .join("forwarder.db")
        .to_str()
        .ok_or("invalid data dir encoding")?
        .to_string();

    let olm = {
        let store = crate::storage::MessageStore::open(&db_path, &passphrase)?;
        match store.load_olm_account()? {
            Some(account_json) => {
                let sessions = store.load_all_olm_sessions()?;
                crate::crypto::OlmManager::from_pickles(&account_json, sessions)?
            }
            None => crate::crypto::OlmManager::new(),
        }
    };
    let crypto_store = crate::crypto::CryptoStore::open(db_path.clone(), passphrase.clone())?;
    if let Ok(pickle) = olm.account_pickle_json() {
        crypto_store.save_account(pickle);
    }
    // master == device: seed the resolver so shared id-resolving paths behave.
    crate::node::resolver::seed_self(&peer_id, &[peer_id.clone()]);

    let cfg = Arc::new(cfg);
    let (engine_tx, engine_rx) = mpsc::unbounded_channel::<engine::EngineCmd>();
    let (out_tx, out_rx) = mpsc::unbounded_channel::<engine::OutSignal>();
    tokio::spawn(engine::run(cfg.clone(), engine_rx, out_tx));
    signaling::run(cfg, keypair, olm, crypto_store, engine_tx, out_rx).await
}
