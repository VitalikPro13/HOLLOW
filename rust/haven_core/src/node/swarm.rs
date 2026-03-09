use std::collections::HashMap;
use std::io;
use std::time::Duration;

use libp2p::futures::StreamExt;
use libp2p::request_response::{self, ProtocolSupport};
use libp2p::{autonat, dcutr, identify, identity, kad, mdns, noise, ping, relay, swarm::SwarmEvent, tcp, tls, yamux, Multiaddr, PeerId, SwarmBuilder};
use base64::Engine;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

use crate::crdt::hlc::Hlc;
use crate::crdt::operations::{CrdtPayload, Permission};
use crate::crdt::server_state::ServerState;
use crate::crdt::sync::{self as crdt_sync, StateVector};
use crate::crypto::{CryptoStore, OlmManager};
use super::signaling::{self, SignalingCmd, SignalingEvent};

// -- Relay node constants (OVH VPS, Belgium) --
const RELAY_ADDR_TCP: &str = "/ip4/141.227.186.209/tcp/4001";
const RELAY_ADDR_QUIC: &str = "/ip4/141.227.186.209/udp/4001/quic-v1";
const RELAY_ADDR_WSS: &str = "/dns4/relay.anonlisten.com/tcp/443/tls/ws";
const RELAY_PEER_ID: &str = "12D3KooWSN4XSvAZdyKULvTgnsxYqcfr4LEmqCkAcQoTzaotDX8s";

/// Parse the relay PeerId from the hardcoded constant.
/// Returns None if the relay hasn't been configured yet (empty string).
fn relay_peer_id() -> Option<PeerId> {
    if RELAY_PEER_ID.is_empty() {
        return None;
    }
    RELAY_PEER_ID.parse().ok()
}

/// Build the relay multiaddrs including the peer ID suffix.
fn relay_addrs() -> Vec<Multiaddr> {
    if RELAY_PEER_ID.is_empty() {
        return vec![];
    }
    [RELAY_ADDR_TCP, RELAY_ADDR_QUIC, RELAY_ADDR_WSS]
        .iter()
        .filter_map(|base| {
            format!("{base}/p2p/{RELAY_PEER_ID}").parse().ok()
        })
        .collect()
}

/// Filter addresses for signaling registration.
/// Removes loopback, link-local, and private LAN addresses.
/// Keeps relay circuit addresses and public IPs.
fn is_registerable_address(addr: &str) -> bool {
    // Always keep relay circuit addresses — they're routable from anywhere.
    if addr.contains("p2p-circuit") {
        return true;
    }
    // Exclude loopback.
    if addr.contains("/ip4/127.") || addr.contains("/ip6/::1/") {
        return false;
    }
    // Exclude link-local.
    if addr.contains("/ip4/169.254.") || addr.contains("/ip6/fe80") {
        return false;
    }
    // Exclude private LAN ranges (unreachable from other networks).
    if addr.contains("/ip4/192.168.") || addr.contains("/ip4/10.") {
        return false;
    }
    // 172.16.0.0 - 172.31.255.255
    if let Some(pos) = addr.find("/ip4/172.") {
        let after = &addr[pos + 9..];
        if let Some(dot_pos) = after.find('.') {
            if let Ok(second_octet) = after[..dot_pos].parse::<u8>() {
                if (16..=31).contains(&second_octet) {
                    return false;
                }
            }
        }
    }
    true
}

/// A discovered peer on the local network.
pub(crate) struct DiscoveredPeer {
    pub peer_id: String,
    pub addresses: Vec<String>,
}

/// Events emitted by the network node.
pub(crate) enum NetworkEvent {
    PeerDiscovered { peer: DiscoveredPeer },
    PeerExpired { peer_id: String },
    PeerDisconnected { peer_id: String },
    RoomCleared,
    Listening { address: String },
    MessageReceived { from_peer: String, text: String },
    ChannelMessageReceived { server_id: String, channel_id: String, from_peer: String, text: String, timestamp: i64 },
    MessageSent { to_peer: String },
    MessageSendFailed { to_peer: String, error: String },
    SessionEstablished { peer_id: String },
    Error { message: String },
    // -- CRDT events (Phase 3) --
    ServerCreated { server_id: String, name: String },
    ServerUpdated { server_id: String },
    ChannelAdded { server_id: String, channel_id: String, name: String },
    ChannelRemoved { server_id: String, channel_id: String },
    ChannelRenamed { server_id: String, channel_id: String, new_name: String },
    ServerDeleted { server_id: String },
    MemberJoined { server_id: String, peer_id: String },
    MemberLeft { server_id: String, peer_id: String },
    SyncCompleted { server_id: String, ops_applied: u32 },
    ServerJoined { server_id: String, name: String },
    MessageSyncStarted { server_id: String, peer_id: String },
    MessageSyncCompleted { server_id: String, new_message_count: u32 },
    MessageSyncFailed { server_id: String, error: String },
    MessageSyncProgress { server_id: String, channel_id: String, received_count: u32, total_count: u32 },
    RoleChanged { server_id: String, peer_id: String, new_role: String },
}

/// Commands the FFI layer can send into the swarm event loop.
pub(crate) enum NodeCommand {
    SendMessage { peer_id: PeerId, text: String },
    SendChannelMessage { server_id: String, channel_id: String, text: String },
    JoinRoom { room_code: String },
    // -- CRDT commands (Phase 3) --
    CreateServer { name: String },
    CreateChannel { server_id: String, name: String, category: Option<String> },
    RemoveChannel { server_id: String, channel_id: String },
    RenameServer { server_id: String, new_name: String },
    RenameChannel { server_id: String, channel_id: String, new_name: String },
    UpdateServerSetting { server_id: String, key: String, value: String },
    DeleteServer { server_id: String },
    JoinServer { server_id: String },
    RequestChannelSync { server_id: String, channel_id: String },
    ChangeRole { server_id: String, peer_id: String, new_role: String },
    KickMember { server_id: String, peer_id: String },
    NotifyShutdown,
}

// -- Wire protocol types (v2: encrypted) --

/// Unified message type for the Haven protocol.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
enum HavenMessage {
    #[serde(rename = "key_request")]
    KeyRequest,

    #[serde(rename = "key_bundle")]
    KeyBundle {
        identity_key: String,
        one_time_key: String,
    },

    #[serde(rename = "encrypted")]
    Encrypted {
        message_type: usize,
        body: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        identity_key: Option<String>,
    },

    #[serde(rename = "ack")]
    Ack,

    // -- CRDT sync messages (Phase 3) --

    #[serde(rename = "sync_request")]
    SyncRequest {
        server_id: String,
        state_vector_json: String,
    },

    #[serde(rename = "sync_response")]
    SyncResponse {
        server_id: String,
        ops_json: String,
    },

    #[serde(rename = "crdt_op")]
    CrdtOpBroadcast {
        server_id: String,
        op_json: String,
    },

    #[serde(rename = "join_request")]
    ServerJoinRequest {
        server_id: String,
    },

    #[serde(rename = "server_delete")]
    ServerDeleteBroadcast {
        server_id: String,
    },

    /// Sent to the kicked member so they remove themselves from the server.
    #[serde(rename = "member_kick")]
    MemberKickBroadcast {
        server_id: String,
    },

    #[serde(rename = "ch_sync_req")]
    ChannelSyncRequest {
        server_id: String,
        channel_id: String,
        since_timestamp: i64,
    },

    /// Sent to all connected peers when the app is shutting down.
    #[serde(rename = "disconnecting")]
    PeerDisconnecting,
}

/// Envelope for the plaintext body inside an Encrypted message.
/// Legacy DMs are raw text (no JSON). New messages use this envelope.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t")]
enum MessageEnvelope {
    #[serde(rename = "dm")]
    DirectMessage {
        text: String,
        /// Sender-generated timestamp (millis since epoch).
        #[serde(default)]
        ts: i64,
        /// Ed25519 signature (base64) over canonical payload.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        /// Sender's Ed25519 public key (base64 protobuf).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
    },
    #[serde(rename = "ch")]
    ChannelMessage {
        sid: String,
        cid: String,
        text: String,
        /// Sender-generated timestamp (millis since epoch).
        ts: i64,
        /// Ed25519 signature (base64) over canonical payload.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sig: Option<String>,
        /// Sender's Ed25519 public key (base64 protobuf).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pk: Option<String>,
    },
    #[serde(rename = "ch_sync")]
    ChannelSyncBatch {
        sid: String,
        cid: String,
        messages: Vec<SyncMessageItem>,
        /// Total messages available since requested timestamp (for progress indication).
        #[serde(default)]
        total: u32,
    },
}

/// A single message in a sync batch.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct SyncMessageItem {
    /// sender peer ID
    s: String,
    /// message text
    t: String,
    /// timestamp (millis since epoch)
    ts: i64,
    /// Ed25519 signature (base64) over canonical payload.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sig: Option<String>,
    /// Sender's Ed25519 public key (base64 protobuf).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pk: Option<String>,
}

/// JSON codec for the Haven v2 protocol.
#[derive(Debug, Clone, Default)]
struct HavenCodec;

impl request_response::Codec for HavenCodec {
    type Protocol = &'static str;
    type Request = HavenMessage;
    type Response = HavenMessage;

    fn read_request<'life0, 'life1, 'life2, 'async_trait, T>(
        &'life0 mut self,
        _protocol: &'life1 Self::Protocol,
        io: &'life2 mut T,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<Self::Request>> + Send + 'async_trait>>
    where
        T: libp2p::futures::AsyncRead + Unpin + Send + 'async_trait,
        'life0: 'async_trait,
        'life1: 'async_trait,
        'life2: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            let mut buf = Vec::new();
            libp2p::futures::AsyncReadExt::read_to_end(io, &mut buf).await?;
            serde_json::from_slice(&buf)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
        })
    }

    fn read_response<'life0, 'life1, 'life2, 'async_trait, T>(
        &'life0 mut self,
        _protocol: &'life1 Self::Protocol,
        io: &'life2 mut T,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<Self::Response>> + Send + 'async_trait>>
    where
        T: libp2p::futures::AsyncRead + Unpin + Send + 'async_trait,
        'life0: 'async_trait,
        'life1: 'async_trait,
        'life2: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            let mut buf = Vec::new();
            libp2p::futures::AsyncReadExt::read_to_end(io, &mut buf).await?;
            serde_json::from_slice(&buf)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
        })
    }

    fn write_request<'life0, 'life1, 'life2, 'async_trait, T>(
        &'life0 mut self,
        _protocol: &'life1 Self::Protocol,
        io: &'life2 mut T,
        req: Self::Request,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<()>> + Send + 'async_trait>>
    where
        T: libp2p::futures::AsyncWrite + Unpin + Send + 'async_trait,
        'life0: 'async_trait,
        'life1: 'async_trait,
        'life2: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            let bytes = serde_json::to_vec(&req)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
            libp2p::futures::AsyncWriteExt::write_all(io, &bytes).await?;
            libp2p::futures::AsyncWriteExt::close(io).await?;
            Ok(())
        })
    }

    fn write_response<'life0, 'life1, 'life2, 'async_trait, T>(
        &'life0 mut self,
        _protocol: &'life1 Self::Protocol,
        io: &'life2 mut T,
        res: Self::Response,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<()>> + Send + 'async_trait>>
    where
        T: libp2p::futures::AsyncWrite + Unpin + Send + 'async_trait,
        'life0: 'async_trait,
        'life1: 'async_trait,
        'life2: 'async_trait,
        Self: 'async_trait,
    {
        Box::pin(async move {
            let bytes = serde_json::to_vec(&res)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
            libp2p::futures::AsyncWriteExt::write_all(io, &bytes).await?;
            libp2p::futures::AsyncWriteExt::close(io).await?;
            Ok(())
        })
    }
}

// -- Prekey bundle types for async key exchange via DHT --

const PREKEY_BATCH_SIZE: usize = 10;
const PREKEY_REPUBLISH_SECS: u64 = 240; // 4 minutes

/// A prekey bundle published to the Kademlia DHT for async key exchange.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct PrekeyBundle {
    peer_id: String,
    identity_key: String,
    one_time_keys: Vec<String>,
    timestamp: u64,
    public_key: String,  // Ed25519 public key as base64 protobuf
    signature: String,
}

/// Build the canonical string that gets signed/verified for a prekey bundle.
fn prekey_signing_payload(
    peer_id: &str,
    identity_key: &str,
    otks: &[String],
    timestamp: u64,
) -> String {
    let otks_joined = otks.join(",");
    format!("haven-prekeys:{peer_id}:{identity_key}:{otks_joined}:{timestamp}")
}

/// Verify a prekey bundle's authenticity: signature, PeerId match, freshness, non-empty OTKs.
fn verify_prekey_bundle(bundle: &PrekeyBundle) -> Result<bool, String> {
    // Decode the Ed25519 public key from base64 protobuf.
    let pub_key_bytes = base64::engine::general_purpose::STANDARD
        .decode(&bundle.public_key)
        .map_err(|e| format!("Invalid public key base64: {e}"))?;

    let public_key = identity::PublicKey::try_decode_protobuf(&pub_key_bytes)
        .map_err(|e| format!("Invalid public key protobuf: {e}"))?;

    // Verify the PeerId matches the public key.
    let expected_peer_id = PeerId::from_public_key(&public_key);
    let claimed_peer_id: PeerId = bundle.peer_id.parse()
        .map_err(|e| format!("Invalid peer_id: {e}"))?;
    if expected_peer_id != claimed_peer_id {
        return Ok(false);
    }

    // Verify the Ed25519 signature over the canonical payload.
    let payload = prekey_signing_payload(
        &bundle.peer_id, &bundle.identity_key, &bundle.one_time_keys, bundle.timestamp,
    );
    let sig_bytes = base64::engine::general_purpose::STANDARD
        .decode(&bundle.signature)
        .map_err(|e| format!("Invalid signature base64: {e}"))?;

    if !public_key.verify(payload.as_bytes(), &sig_bytes) {
        return Ok(false);
    }

    // Check freshness (< 10 minutes).
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    if now.saturating_sub(bundle.timestamp) > 600 {
        return Ok(false);
    }

    if bundle.one_time_keys.is_empty() {
        return Ok(false);
    }

    Ok(true)
}

// -- Per-message Ed25519 signing helpers --

/// Build canonical payload for message signing.
/// Format: "haven-msg:{type}:{context}:{sender}:{ts}:{text}"
/// - Channel: type="ch", context="{sid}:{cid}"
/// - DM:      type="dm", context="{recipient_peer_id}"
fn message_signing_payload(
    msg_type: &str,
    context: &str,
    sender: &str,
    ts: i64,
    text: &str,
) -> String {
    format!("haven-msg:{msg_type}:{context}:{sender}:{ts}:{text}")
}

/// Sign a message payload with the local keypair.
/// Returns (signature_base64, public_key_base64).
fn sign_message(
    keypair: &identity::Keypair,
    pub_key_b64: &str,
    payload: &str,
) -> (Option<String>, Option<String>) {
    match keypair.sign(payload.as_bytes()) {
        Ok(sig) => {
            let sig_b64 = base64::engine::general_purpose::STANDARD.encode(&sig);
            (Some(sig_b64), Some(pub_key_b64.to_string()))
        }
        Err(e) => {
            haven_log!("[HAVEN-CRYPTO] Failed to sign message: {e}");
            (None, None)
        }
    }
}

/// Verify an Ed25519 signature on a message.
/// Checks: public key decodes, PeerId matches sender, signature is valid.
fn verify_message_signature(
    sender_peer_str: &str,
    sig_b64: Option<&str>,
    pk_b64: Option<&str>,
    payload: &str,
) -> bool {
    let (sig, pk) = match (sig_b64, pk_b64) {
        (Some(s), Some(p)) => (s, p),
        _ => return false,
    };

    let Ok(pk_bytes) = base64::engine::general_purpose::STANDARD.decode(pk) else {
        return false;
    };
    let Ok(public_key) = identity::PublicKey::try_decode_protobuf(&pk_bytes) else {
        return false;
    };

    // Verify PeerId matches the public key.
    let expected_pid = PeerId::from_public_key(&public_key);
    let Ok(claimed_pid) = sender_peer_str.parse::<PeerId>() else {
        return false;
    };
    if expected_pid != claimed_pid {
        return false;
    }

    // Verify the signature.
    let Ok(sig_bytes) = base64::engine::general_purpose::STANDARD.decode(sig) else {
        return false;
    };
    public_key.verify(payload.as_bytes(), &sig_bytes)
}

/// Publish our prekey bundle to the Kademlia DHT.
fn publish_prekey_bundle(
    swarm: &mut libp2p::Swarm<HavenBehaviour>,
    keypair: &identity::Keypair,
    peer_id_str: &str,
    pub_key_b64: &str,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
) -> Result<(), String> {
    let identity_key = olm.identity_key_base64();
    let one_time_keys = olm.generate_one_time_keys_batch(PREKEY_BATCH_SIZE);
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| format!("Clock error: {e}"))?
        .as_secs();

    let payload_str = prekey_signing_payload(peer_id_str, &identity_key, &one_time_keys, timestamp);
    let signature = keypair
        .sign(payload_str.as_bytes())
        .map_err(|e| format!("Signing failed: {e}"))?;
    let sig_b64 = base64::engine::general_purpose::STANDARD.encode(&signature);

    let bundle = PrekeyBundle {
        peer_id: peer_id_str.to_string(),
        identity_key,
        one_time_keys,
        timestamp,
        public_key: pub_key_b64.to_string(),
        signature: sig_b64,
    };

    let value = serde_json::to_vec(&bundle)
        .map_err(|e| format!("Failed to serialize bundle: {e}"))?;

    let record_key = kad::RecordKey::new(&format!("/haven/prekeys/{}", peer_id_str));
    let record = kad::Record {
        key: record_key,
        value,
        publisher: None,
        expires: None,
    };

    swarm.behaviour_mut().kademlia
        .put_record(record, kad::Quorum::One)
        .map_err(|e| format!("DHT put_record failed: {e}"))?;

    // Persist account state (OTKs were consumed).
    if let Ok(account_json) = olm.account_pickle_json() {
        crypto_store.save_account(account_json);
    }

    Ok(())
}

/// Our libp2p network behaviour — mDNS discovery + encrypted messaging + DHT + NAT traversal.
#[derive(libp2p::swarm::NetworkBehaviour)]
struct HavenBehaviour {
    relay_client: relay::client::Behaviour,
    identify: identify::Behaviour,
    ping: ping::Behaviour,
    kademlia: kad::Behaviour<kad::store::MemoryStore>,
    autonat: autonat::Behaviour,
    dcutr: dcutr::Behaviour,
    mdns: mdns::tokio::Behaviour,
    messaging: request_response::Behaviour<HavenCodec>,
}

/// Build and spawn the libp2p swarm. Returns the local peer ID and a join handle.
pub(crate) async fn spawn_node(
    keypair: identity::Keypair,
    event_tx: mpsc::Sender<NetworkEvent>,
    cmd_rx: mpsc::Receiver<NodeCommand>,
    olm: OlmManager,
    crypto_store: CryptoStore,
) -> Result<(String, tokio::task::JoinHandle<()>), String> {
    // Clone keypair for signaling task (it needs to sign register requests).
    let sig_keypair = keypair.clone();
    // Clone keypair for prekey bundle signing in the swarm task.
    let bundle_keypair = keypair.clone();

    let swarm = SwarmBuilder::with_existing_identity(keypair)
        .with_tokio()
        .with_tcp(
            tcp::Config::default(),
            noise::Config::new,
            yamux::Config::default,
        )
        .map_err(|e| format!("TCP setup failed: {e}"))?
        .with_quic_config(|mut config| {
            config.handshake_timeout = Duration::from_secs(10);
            config
        })
        .with_dns()
        .map_err(|e| format!("DNS setup failed: {e}"))?
        .with_websocket(
            (tls::Config::new, noise::Config::new),
            yamux::Config::default,
        )
        .await
        .map_err(|e| format!("WebSocket setup failed: {e}"))?
        .with_relay_client(
            (tls::Config::new, noise::Config::new),
            yamux::Config::default,
        )
        .map_err(|e| format!("Relay client setup failed: {e}"))?
        .with_behaviour(|key, relay_client| {
            let local_peer_id = key.public().to_peer_id();

            let mdns_config = mdns::Config {
                ttl: Duration::from_secs(300),
                query_interval: Duration::from_secs(5),
                enable_ipv6: false,
            };
            let mdns = mdns::tokio::Behaviour::new(mdns_config, local_peer_id)
                .expect("Failed to create mDNS behaviour");

            let messaging = request_response::Behaviour::<HavenCodec>::new(
                [("/haven/msg/2.0.0", ProtocolSupport::Full)],
                request_response::Config::default(),
            );

            // Kademlia DHT (MemoryStore — records lost on restart, fine for Phase 2)
            let mut kademlia = kad::Behaviour::new(
                local_peer_id,
                kad::store::MemoryStore::new(local_peer_id),
            );
            kademlia.set_mode(Some(kad::Mode::Server));

            // AutoNAT — probes other peers to discover our public address
            let autonat = autonat::Behaviour::new(
                local_peer_id,
                autonat::Config::default(),
            );

            // DCUtR — hole punching via relay-assisted coordination
            let dcutr = dcutr::Behaviour::new(local_peer_id);

            // Identify — required for relay protocol to work.
            let identify = identify::Behaviour::new(identify::Config::new(
                "/haven/1.0.0".to_string(),
                key.public(),
            ));

            let ping = ping::Behaviour::new(
                ping::Config::new()
                    .with_interval(Duration::from_secs(5))
                    .with_timeout(Duration::from_secs(5)),
            );

            Ok(HavenBehaviour {
                relay_client,
                identify,
                ping,
                kademlia,
                autonat,
                dcutr,
                mdns,
                messaging,
            })
        })
        .map_err(|e| format!("Behaviour setup failed: {e}"))?
        .with_swarm_config(|cfg| {
            cfg.with_idle_connection_timeout(Duration::from_secs(u64::MAX))
        })
        .build();

    let peer_id_str = swarm.local_peer_id().to_string();

    // Spawn the signaling background task.
    let (sig_cmd_tx, sig_event_rx) =
        signaling::spawn_signaling_task(sig_keypair, peer_id_str.clone());

    let handle = tokio::spawn(run_swarm(
        swarm, event_tx, cmd_rx, olm, crypto_store, sig_cmd_tx, sig_event_rx,
        bundle_keypair,
    ));

    Ok((peer_id_str, handle))
}

/// The main swarm event loop. Runs until the task is aborted.
async fn run_swarm(
    mut swarm: libp2p::Swarm<HavenBehaviour>,
    event_tx: mpsc::Sender<NetworkEvent>,
    mut cmd_rx: mpsc::Receiver<NodeCommand>,
    mut olm: OlmManager,
    crypto_store: CryptoStore,
    sig_cmd_tx: mpsc::Sender<SignalingCmd>,
    mut sig_event_rx: mpsc::Receiver<SignalingEvent>,
    bundle_keypair: identity::Keypair,
) {
    // Precompute public key base64 for prekey bundle signing.
    let pub_key_proto = bundle_keypair.public().encode_protobuf();
    let pub_key_b64 = base64::engine::general_purpose::STANDARD.encode(&pub_key_proto);

    // Listen on all interfaces — TCP and QUIC, random ports.
    let tcp_addr: Multiaddr = "/ip4/0.0.0.0/tcp/0".parse().unwrap();
    if let Err(e) = swarm.listen_on(tcp_addr) {
        let _ = event_tx
            .send(NetworkEvent::Error {
                message: format!("Failed to listen (TCP): {e}"),
            })
            .await;
        return;
    }

    let quic_addr: Multiaddr = "/ip4/0.0.0.0/udp/0/quic-v1".parse().unwrap();
    if let Err(e) = swarm.listen_on(quic_addr) {
        let _ = event_tx
            .send(NetworkEvent::Error {
                message: format!("Failed to listen (QUIC): {e}"),
            })
            .await;
        // QUIC failure is non-fatal — TCP still works as fallback.
    }

    // Dial the relay node and request a reservation (for NAT traversal).
    if let Some(relay_pid) = relay_peer_id() {
        let _ = event_tx
            .send(NetworkEvent::Error {
                message: format!("[DEBUG] Dialing relay {relay_pid}..."),
            })
            .await;
        for addr in relay_addrs() {
            let _ = event_tx
                .send(NetworkEvent::Error {
                    message: format!("[DEBUG] Relay addr: {addr}"),
                })
                .await;
            swarm.add_peer_address(relay_pid, addr.clone());
            swarm.behaviour_mut().kademlia.add_address(&relay_pid, addr);
        }
        if let Err(e) = swarm.dial(relay_pid) {
            let _ = event_tx
                .send(NetworkEvent::Error {
                    message: format!("Failed to dial relay: {e}"),
                })
                .await;
        }
        // NOTE: listen_on for the relay circuit is deferred to
        // ConnectionEstablished — calling it before the relay is
        // connected causes libp2p to immediately close the listener.
    } else {
        let _ = event_tx
            .send(NetworkEvent::Error {
                message: "[DEBUG] No relay configured!".to_string(),
            })
            .await;
    }

    // Track outbound request IDs → peer for delivery confirmation.
    let mut pending_requests = HashMap::<request_response::OutboundRequestId, String>::new();

    // Buffer messages while key exchange is in progress.
    let mut pending_messages: HashMap<String, Vec<String>> = HashMap::new();

    // Track which peers have an active key request in flight (avoid duplicate requests).
    let mut key_request_in_flight: std::collections::HashSet<String> = std::collections::HashSet::new();

    // Track our own listen addresses for signaling registration.
    let mut known_addresses: Vec<String> = Vec::new();

    // Track the active room code so we can re-bootstrap after getting a relay circuit address.
    let mut active_room: Option<String> = None;

    // Prekey bundle republish timer (4 min interval).
    let mut prekey_timer = tokio::time::interval(Duration::from_secs(PREKEY_REPUBLISH_SECS));
    prekey_timer.tick().await; // consume immediate first tick
    let mut prekey_published = false;

    // Track pending DHT prekey fetches: query_id → target peer_id string.
    let mut pending_prekey_fetches: HashMap<kad::QueryId, String> = HashMap::new();
    // Peers for whom a DHT prekey fetch is in flight.
    let mut dht_fetch_in_flight: std::collections::HashSet<String> = std::collections::HashSet::new();

    // Track the original message text for outbound encrypted messages so we can
    // re-queue on delivery failure. Maps request_id → (peer_id_str, text).
    let mut outbound_message_text: HashMap<request_response::OutboundRequestId, (String, String)> = HashMap::new();

    // Track which peers have active connections (excludes relay node).
    let mut connected_peers: std::collections::HashSet<PeerId> = std::collections::HashSet::new();

    // Track peers we expect (discovered via signaling, mDNS, or relay inbound circuit).
    // ConnectionEstablished only emits PeerDiscovered for peers in this set,
    // preventing Kademlia routing connections from polluting the peer list.
    let mut expected_peers: std::collections::HashSet<PeerId> = std::collections::HashSet::new();

    // Track peers that disconnected. Prevents ghost peers: if signaling
    // returns a stale peer we already tried and failed, skip it.
    // Cleared on room switch, removed on successful ConnectionEstablished.
    // Track disconnected peers with the time they disconnected.
    // Peers stay here for at least DISCONNECT_COOLDOWN to prevent ghost
    // re-discovery from stale signaling entries.
    let mut disconnected_peers: HashMap<PeerId, std::time::Instant> = HashMap::new();
    const DISCONNECT_COOLDOWN: Duration = Duration::from_secs(180); // 3 min = signaling stale threshold

    // -- CRDT state (Phase 3) --
    // Server states keyed by server_id. Reload from DB so servers survive restarts.
    let mut server_states: HashMap<String, ServerState> = HashMap::new();
    {
        let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
            match store.load_all_servers() {
                Ok(rows) => {
                    for (server_id, json) in rows {
                        match serde_json::from_str::<ServerState>(&json) {
                            Ok(mut state) => {
                                state.set_hlc(Hlc::new(swarm.local_peer_id().to_string()));
                                server_states.insert(server_id, state);
                            }
                            Err(e) => {
                                haven_log!("Failed to deserialize server {}: {}", server_id, e);
                            }
                        }
                    }
                    if !server_states.is_empty() {
                        haven_log!("Loaded {} server(s) from DB", server_states.len());
                    }
                }
                Err(e) => {
                    haven_log!("Failed to load servers from DB: {}", e);
                }
            }
        }
    }

    // Track server_ids we're trying to join (waiting for SyncResponse from existing members).
    let mut pending_server_joins: std::collections::HashSet<String> = std::collections::HashSet::new();

    // Track failed sync requests per peer — retried after session re-establishment.
    // Maps peer_id_str → Vec<(server_id, channel_id, since_timestamp)>
    let mut pending_sync_requests: HashMap<String, Vec<(String, String, i64)>> = HashMap::new();

    // Re-bootstrap timer (30 seconds) for mutual peer discovery.
    // Fires unconditionally — BootstrapPeers handler skips connected
    // and disconnected peers, so only genuinely new peers get processed.
    let mut rebootstrap_timer = tokio::time::interval(Duration::from_secs(30));
    rebootstrap_timer.tick().await; // consume immediate first tick

    // Relay health check timer (60 seconds). Detects dropped relay connections
    // and re-dials to restore circuit-based reachability.
    let mut relay_health_timer = tokio::time::interval(Duration::from_secs(60));
    relay_health_timer.tick().await; // consume immediate first tick

    loop {
        tokio::select! {
            // Handle commands from the FFI layer.
            Some(cmd) = cmd_rx.recv() => {
                match cmd {
                    NodeCommand::JoinRoom { room_code } => {
                        // If switching rooms, unregister from the old room and clear state.
                        if let Some(old_room) = active_room.as_ref().filter(|r| *r != &room_code) {
                            let _ = sig_cmd_tx.send(SignalingCmd::Unregister {
                                room_code: old_room.clone(),
                            }).await;
                            let _ = event_tx.send(NetworkEvent::RoomCleared).await;
                            connected_peers.clear();
                            expected_peers.clear();
                            disconnected_peers.clear();
                        }
                        active_room = Some(room_code.clone());
                        // Register ourselves and bootstrap from the signaling service.
                        // Filter out loopback/link-local/private — only send routable addresses.
                        let addrs: Vec<String> = known_addresses.iter()
                            .filter(|a| is_registerable_address(a))
                            .cloned()
                            .collect();
                        // Only register if we have routable addresses.
                        // If empty (relay circuit not yet established), the
                        // UpdateAddresses flow will register us once it is.
                        if !addrs.is_empty() {
                            let _ = sig_cmd_tx.send(SignalingCmd::Register {
                                room_code: room_code.clone(),
                                addresses: addrs,
                            }).await;
                        }
                        // Always store the room code so UpdateAddresses can
                        // register later, and always bootstrap to find peers.
                        let _ = sig_cmd_tx.send(SignalingCmd::SetRoom {
                            room_code: room_code.clone(),
                        }).await;
                        let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                            room_code,
                        }).await;
                    }
                    NodeCommand::SendMessage { peer_id, text } => {
                        let peer_id_str = peer_id.to_string();
                        haven_log!("[HAVEN-SWARM] SendMessage received for {peer_id_str}");

                        // Wrap DM in signed envelope.
                        let local_peer = swarm.local_peer_id().to_string();
                        let dm_timestamp = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;
                        let signing_payload = message_signing_payload(
                            "dm", &peer_id_str, &local_peer, dm_timestamp, &text,
                        );
                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload);
                        let envelope = MessageEnvelope::DirectMessage {
                            text: text.clone(),
                            ts: dm_timestamp,
                            sig,
                            pk,
                        };
                        let envelope_json = serde_json::to_string(&envelope)
                            .unwrap_or_else(|_| text.clone());

                        if olm.has_session(&peer_id_str) {
                            // Session exists — encrypt and send.
                            send_encrypted_message(
                                &mut swarm,
                                &mut olm,
                                &crypto_store,
                                &mut pending_requests,
                                &mut outbound_message_text,
                                &peer_id,
                                &peer_id_str,
                                &envelope_json,
                                &event_tx,
                            ).await;
                        } else {
                            // No session — queue the signed envelope and try DHT prekey fetch first.
                            pending_messages
                                .entry(peer_id_str.clone())
                                .or_default()
                                .push(envelope_json);

                            if !key_request_in_flight.contains(&peer_id_str)
                                && !dht_fetch_in_flight.contains(&peer_id_str)
                            {
                                // Try DHT prekey fetch before falling back to KeyRequest.
                                haven_log!("[HAVEN-SWARM] No session for {peer_id_str}, starting DHT prekey fetch");
                                let record_key = kad::RecordKey::new(
                                    &format!("/haven/prekeys/{}", peer_id_str),
                                );
                                let query_id = swarm.behaviour_mut().kademlia
                                    .get_record(record_key);
                                pending_prekey_fetches.insert(query_id, peer_id_str.clone());
                                dht_fetch_in_flight.insert(peer_id_str.clone());

                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: format!("[DHT] Fetching prekeys for {peer_id_str}"),
                                }).await;
                            }
                        }
                    }

                    NodeCommand::SendChannelMessage { server_id, channel_id, text } => {
                        haven_log!("[HAVEN-SWARM] SendChannelMessage for channel {channel_id} in server {server_id}");

                        let server = match server_states.get(&server_id) {
                            Some(s) => s,
                            None => {
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: format!("Unknown server {server_id}"),
                                }).await;
                                continue;
                            }
                        };

                        let local_peer = swarm.local_peer_id().to_string();
                        let timestamp = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as i64;

                        // Sign the message before encryption.
                        let signing_payload = message_signing_payload(
                            "ch", &format!("{}:{}", server_id, channel_id),
                            &local_peer, timestamp, &text,
                        );
                        let (sig, pk) = sign_message(&bundle_keypair, &pub_key_b64, &signing_payload);

                        let envelope = MessageEnvelope::ChannelMessage {
                            sid: server_id.clone(),
                            cid: channel_id.clone(),
                            text: text.clone(),
                            ts: timestamp,
                            sig: sig.clone(),
                            pk: pk.clone(),
                        };
                        let envelope_json = serde_json::to_string(&envelope)
                            .unwrap_or_else(|_| text.clone());

                        // Send to each connected server member (except self).
                        for member_peer_str in server.members.keys() {
                            if member_peer_str == &local_peer {
                                continue;
                            }
                            if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                if connected_peers.contains(&member_pid) {
                                    send_encrypted_message(
                                        &mut swarm, &mut olm, &crypto_store,
                                        &mut pending_requests, &mut outbound_message_text,
                                        &member_pid, member_peer_str, &envelope_json,
                                        &event_tx,
                                    ).await;
                                }
                            }
                        }

                        // Persist locally with same timestamp as sent.
                        let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            let _ = store.insert_channel_message(
                                &server_id, &channel_id, &local_peer, &text, true, timestamp,
                                sig.as_deref(), pk.as_deref(),
                            );
                        }
                    }

                    // -- CRDT commands (Phase 3) --

                    NodeCommand::CreateServer { name } => {
                        let local_peer = swarm.local_peer_id().to_string();
                        let server_id = hex::encode(&{
                            let mut buf = [0u8; 16];
                            getrandom::fill(&mut buf).unwrap();
                            buf
                        });
                        haven_log!("[HAVEN-CRDT] Creating server '{name}' id={server_id}");

                        let mut state = ServerState::new(
                            server_id.clone(),
                            name.clone(),
                            local_peer.clone(),
                        );

                        // Create the initial ServerCreated op and apply it
                        let op = state.create_op(CrdtPayload::ServerCreated {
                            name: name.clone(),
                            owner_peer_id: local_peer,
                        });
                        let _ = state.apply_op(&op);

                        // Persist
                        if let Ok(json) = serde_json::to_string(&state) {
                            // Save via direct DB call (initial creation)
                            let _ = event_tx.send(NetworkEvent::Error {
                                message: format!("[CRDT] Server state saved: {server_id}"),
                            }).await;
                            // We'll persist through the storage API
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.save_server_state(&server_id, &json);
                                let _ = store.insert_crdt_op(&op);
                            }
                        }

                        server_states.insert(server_id.clone(), state);

                        let _ = event_tx.send(NetworkEvent::ServerCreated {
                            server_id: server_id.clone(),
                            name,
                        }).await;

                        // Register in signaling room for this server so joiners can discover us.
                        let reg_addrs: Vec<String> = known_addresses.iter()
                            .filter(|a| is_registerable_address(a))
                            .cloned()
                            .collect();
                        if !reg_addrs.is_empty() {
                            let _ = sig_cmd_tx.send(SignalingCmd::Register {
                                room_code: server_id.clone(),
                                addresses: reg_addrs,
                            }).await;
                        }

                        // No broadcast needed for CreateServer — the server only has
                        // one member (the creator) at this point. New members will
                        // receive full state via SyncResponse when they join.
                    }

                    NodeCommand::CreateChannel { server_id, name, category } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            if !state.has_permission(&local_peer, Permission::MANAGE_CHANNELS) {
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot create channel in {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: cannot manage channels".to_string(),
                                }).await;
                                continue;
                            }
                            let channel_id = format!("{}-{}", &server_id[..8.min(server_id.len())], hex::encode(&{
                                let mut buf = [0u8; 4];
                                getrandom::fill(&mut buf).unwrap();
                                buf
                            }));
                            haven_log!("[HAVEN-CRDT] Creating channel '{name}' id={channel_id} in server {server_id}");

                            let op = state.create_op(CrdtPayload::ChannelAdded {
                                channel_id: channel_id.clone(),
                                name: name.clone(),
                                category: category.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::ChannelAdded {
                                server_id: server_id.clone(),
                                channel_id,
                                name,
                            }).await;

                            // Broadcast to connected server members only.
                            if let Ok(op_json) = serde_json::to_string(&op) {
                                let local_peer = swarm.local_peer_id().to_string();
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        } else {
                            let _ = event_tx.send(NetworkEvent::Error {
                                message: format!("[CRDT] Server {server_id} not found"),
                            }).await;
                        }
                    }

                    NodeCommand::RemoveChannel { server_id, channel_id } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            if !state.has_permission(&local_peer, Permission::MANAGE_CHANNELS) {
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot remove channel in {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: cannot manage channels".to_string(),
                                }).await;
                                continue;
                            }
                            haven_log!("[HAVEN-CRDT] Removing channel {channel_id} from server {server_id}");

                            let op = state.create_op(CrdtPayload::ChannelRemoved {
                                channel_id: channel_id.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::ChannelRemoved {
                                server_id: server_id.clone(),
                                channel_id,
                            }).await;

                            // Broadcast to connected server members only.
                            if let Ok(op_json) = serde_json::to_string(&op) {
                                let local_peer = swarm.local_peer_id().to_string();
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }

                    NodeCommand::RenameServer { server_id, new_name } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            if !state.has_permission(&local_peer, Permission::MANAGE_SERVER) {
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot rename server {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: cannot manage server".to_string(),
                                }).await;
                                continue;
                            }
                            haven_log!("[HAVEN-CRDT] Renaming server {server_id} to '{new_name}'");

                            let op = state.create_op(CrdtPayload::ServerRenamed {
                                new_name: new_name.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::ServerUpdated {
                                server_id: server_id.clone(),
                            }).await;

                            // Broadcast to connected server members only.
                            if let Ok(op_json) = serde_json::to_string(&op) {
                                let local_peer = swarm.local_peer_id().to_string();
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }

                    NodeCommand::RenameChannel { server_id, channel_id, new_name } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            if !state.has_permission(&local_peer, Permission::MANAGE_CHANNELS) {
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot rename channel in {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: cannot manage channels".to_string(),
                                }).await;
                                continue;
                            }
                            haven_log!("[HAVEN-CRDT] Renaming channel {channel_id} to '{new_name}' in server {server_id}");

                            let op = state.create_op(CrdtPayload::ChannelRenamed {
                                channel_id: channel_id.clone(),
                                new_name: new_name.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::ChannelRenamed {
                                server_id: server_id.clone(),
                                channel_id,
                                new_name,
                            }).await;

                            // Broadcast to connected server members only.
                            if let Ok(op_json) = serde_json::to_string(&op) {
                                let local_peer = swarm.local_peer_id().to_string();
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }

                    NodeCommand::UpdateServerSetting { server_id, key, value } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            haven_log!("[HAVEN-CRDT] Updating setting '{key}'='{value}' in server {server_id}");

                            let op = state.create_op(CrdtPayload::ServerSettingChanged {
                                key: key.clone(),
                                value: value.clone(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::ServerUpdated {
                                server_id: server_id.clone(),
                            }).await;

                            // Broadcast to connected server members only.
                            if let Ok(op_json) = serde_json::to_string(&op) {
                                let local_peer = swarm.local_peer_id().to_string();
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }

                    NodeCommand::DeleteServer { server_id } => {
                        // Only owner can delete a server.
                        if let Some(state) = server_states.get(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            if !state.has_permission(&local_peer, Permission::MANAGE_SERVER) {
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot delete server {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: only the owner can delete the server".to_string(),
                                }).await;
                                continue;
                            }
                        }

                        haven_log!("[HAVEN-CRDT] Deleting server {server_id}");

                        // Broadcast deletion to all connected server members.
                        if let Some(state) = server_states.get(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            for member_peer_str in state.members.keys() {
                                if member_peer_str == &local_peer { continue; }
                                if let Ok(member_pid) = member_peer_str.parse::<PeerId>() {
                                    if connected_peers.contains(&member_pid) {
                                        swarm.behaviour_mut().messaging.send_request(
                                            &member_pid,
                                            HavenMessage::ServerDeleteBroadcast {
                                                server_id: server_id.clone(),
                                            },
                                        );
                                    }
                                }
                            }
                        }

                        server_states.remove(&server_id);

                        // Unregister from signaling room for this server.
                        let _ = sig_cmd_tx.send(SignalingCmd::Unregister {
                            room_code: server_id.clone(),
                        }).await;

                        // Remove from DB
                        let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            let _ = store.delete_server_state(&server_id);
                        }

                        let _ = event_tx.send(NetworkEvent::ServerDeleted {
                            server_id,
                        }).await;
                    }

                    NodeCommand::JoinServer { server_id } => {
                        haven_log!("[HAVEN-CRDT] Joining server {server_id}");
                        pending_server_joins.insert(server_id.clone());

                        // Join the signaling room with room_code = server_id.
                        let addrs: Vec<String> = known_addresses.iter()
                            .filter(|a| is_registerable_address(a))
                            .cloned()
                            .collect();
                        if !addrs.is_empty() {
                            let _ = sig_cmd_tx.send(SignalingCmd::Register {
                                room_code: server_id.clone(),
                                addresses: addrs,
                            }).await;
                        }
                        let _ = sig_cmd_tx.send(SignalingCmd::SetRoom {
                            room_code: server_id.clone(),
                        }).await;
                        let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                            room_code: server_id.clone(),
                        }).await;

                        // Send join requests to any peers we're already connected to.
                        for &peer_id in &connected_peers {
                            swarm.behaviour_mut().messaging.send_request(
                                &peer_id,
                                HavenMessage::ServerJoinRequest {
                                    server_id: server_id.clone(),
                                },
                            );
                        }
                    }

                    NodeCommand::ChangeRole { server_id, peer_id, new_role } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();
                            let new_member_role = crate::crdt::operations::MemberRole::from_str(&new_role);

                            // Permission check: can the local user change this peer's role?
                            if !state.can_change_role(&local_peer, &peer_id, &new_member_role) {
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot change {peer_id} to {new_role} in {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: format!("Permission denied: cannot change role to {new_role}"),
                                }).await;
                                continue;
                            }

                            haven_log!("[HAVEN-CRDT] Changing role of {peer_id} to {new_role} in {server_id}");
                            // Use the author's (local user's) role priority, not the target role's.
                            // This ensures demotions work: an Owner(3) demoting Admin(2)→Member
                            // sends priority 3, which beats the existing priority 2 in AdminLwwReg.
                            let author_role = state.get_role(&local_peer);
                            let op = state.create_op(CrdtPayload::RoleChanged {
                                peer_id: peer_id.clone(),
                                role: new_member_role.clone(),
                                priority: author_role.priority(),
                            });
                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::RoleChanged {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
                                new_role: new_role.clone(),
                            }).await;

                            // Broadcast to connected server members only.
                            if let Ok(op_json) = serde_json::to_string(&op) {
                                for member_peer_str in state.members.keys() {
                                    if member_peer_str == &local_peer { continue; }
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }
                        }
                    }

                    NodeCommand::KickMember { server_id, peer_id } => {
                        if let Some(state) = server_states.get_mut(&server_id) {
                            let local_peer = swarm.local_peer_id().to_string();

                            // Permission check
                            if !state.can_kick(&local_peer, &peer_id) {
                                haven_log!("[HAVEN-CRDT] Permission denied: cannot kick {peer_id} from {server_id}");
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: "Permission denied: cannot kick this member".to_string(),
                                }).await;
                                continue;
                            }

                            haven_log!("[HAVEN-CRDT] Kicking member {peer_id} from {server_id}");
                            let op = state.create_op(CrdtPayload::MemberRemoved {
                                peer_id: peer_id.clone(),
                            });

                            // Collect broadcast targets BEFORE apply_op removes the member.
                            let broadcast_targets: Vec<String> = state.members.keys()
                                .filter(|m| *m != &local_peer)
                                .cloned()
                                .collect();

                            let _ = state.apply_op(&op);

                            // Persist
                            if let Ok(json) = serde_json::to_string(&state) {
                                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let _ = store.save_server_state(&server_id, &json);
                                    let _ = store.insert_crdt_op(&op);
                                }
                            }

                            let _ = event_tx.send(NetworkEvent::MemberLeft {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
                            }).await;

                            // Broadcast CRDT op to remaining members (collected before removal).
                            if let Ok(op_json) = serde_json::to_string(&op) {
                                for member_peer_str in &broadcast_targets {
                                    if member_peer_str == &peer_id { continue; } // Kicked peer gets MemberKickBroadcast instead
                                    if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                        if connected_peers.contains(&pid) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &pid,
                                                HavenMessage::CrdtOpBroadcast {
                                                    server_id: server_id.clone(),
                                                    op_json: op_json.clone(),
                                                },
                                            );
                                        }
                                    }
                                }
                            }

                            // Send kick notification directly to the kicked peer
                            // so they remove themselves from the server.
                            if let Ok(pid) = peer_id.parse::<PeerId>() {
                                if connected_peers.contains(&pid) {
                                    swarm.behaviour_mut().messaging.send_request(
                                        &pid,
                                        HavenMessage::MemberKickBroadcast {
                                            server_id: server_id.clone(),
                                        },
                                    );
                                }
                            }
                        }
                    }

                    NodeCommand::RequestChannelSync { server_id, channel_id } => {
                        // On-demand sync when user opens a channel.
                        if let Some(state) = server_states.get(&server_id) {
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                    let since = store
                                        .get_latest_channel_timestamp(&server_id, &channel_id)
                                        .unwrap_or(None)
                                        .unwrap_or(0);
                                    let local_peer = swarm.local_peer_id().to_string();
                                    for member_peer_str in state.members.keys() {
                                        if member_peer_str == &local_peer { continue; }
                                        if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                                            if connected_peers.contains(&pid) {
                                                swarm.behaviour_mut().messaging.send_request(
                                                    &pid,
                                                    HavenMessage::ChannelSyncRequest {
                                                        server_id: server_id.clone(),
                                                        channel_id: channel_id.clone(),
                                                        since_timestamp: since,
                                                    },
                                                );
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    NodeCommand::NotifyShutdown => {
                        // Broadcast graceful disconnect to all connected peers.
                        haven_log!("[HAVEN-SWARM] Notifying {} peers of shutdown", connected_peers.len());
                        for pid in connected_peers.iter() {
                            if relay_peer_id() == Some(*pid) { continue; }
                            swarm.behaviour_mut().messaging.send_request(
                                pid,
                                HavenMessage::PeerDisconnecting,
                            );
                        }
                    }
                }
            }
            // Handle swarm events.
            event = swarm.select_next_some() => {
                match event {
                    SwarmEvent::NewListenAddr { address, .. } => {
                        let addr_str = address.to_string();
                        let is_new = !known_addresses.contains(&addr_str);
                        let is_circuit = addr_str.contains("p2p-circuit");
                        if is_new {
                            known_addresses.push(addr_str.clone());

                            // Push updated addresses to signaling so relay circuit
                            // addresses get registered for other peers to find us.
                            let registerable: Vec<String> = known_addresses.iter()
                                .filter(|a| is_registerable_address(a))
                                .cloned()
                                .collect();
                            let _ = sig_cmd_tx.send(SignalingCmd::UpdateAddresses {
                                addresses: registerable,
                            }).await;

                            // When a relay circuit address appears, bootstrap to
                            // discover peers that registered before us.
                            if is_circuit {
                                if let Some(room) = &active_room {
                                    let _ = event_tx
                                        .send(NetworkEvent::Error {
                                            message: "[DEBUG] Relay circuit up — bootstrapping...".to_string(),
                                        })
                                        .await;
                                    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                                        room_code: room.clone(),
                                    }).await;
                                }

                                // Register + bootstrap in all server signaling rooms.
                                let reg_addrs: Vec<String> = known_addresses.iter()
                                    .filter(|a| is_registerable_address(a))
                                    .cloned()
                                    .collect();
                                for sid in server_states.keys() {
                                    let _ = sig_cmd_tx.send(SignalingCmd::Register {
                                        room_code: sid.clone(),
                                        addresses: reg_addrs.clone(),
                                    }).await;
                                    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                                        room_code: sid.clone(),
                                    }).await;
                                }

                                // Publish prekey bundle to DHT now that we're routable.
                                let peer_id_str = swarm.local_peer_id().to_string();
                                match publish_prekey_bundle(
                                    &mut swarm, &bundle_keypair, &peer_id_str, &pub_key_b64,
                                    &mut olm, &crypto_store,
                                ) {
                                    Ok(()) => {
                                        prekey_published = true;
                                        let _ = event_tx.send(NetworkEvent::Error {
                                            message: "[DHT] Prekey bundle published".to_string(),
                                        }).await;
                                    }
                                    Err(e) => {
                                        let _ = event_tx.send(NetworkEvent::Error {
                                            message: format!("[DHT] Prekey publish failed: {e}"),
                                        }).await;
                                    }
                                }
                            }
                        }
                        let _ = event_tx
                            .send(NetworkEvent::Listening {
                                address: addr_str,
                            })
                            .await;
                    }
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Mdns(mdns::Event::Discovered(peers))) => {
                        for (peer_id, addr) in peers {
                            swarm.add_peer_address(peer_id, addr.clone());
                            // Seed Kademlia DHT from LAN peers discovered via mDNS.
                            swarm.behaviour_mut().kademlia.add_address(&peer_id, addr.clone());
                            expected_peers.insert(peer_id);
                            let peer_id_str = peer_id.to_string();
                            let _ = event_tx
                                .send(NetworkEvent::PeerDiscovered {
                                    peer: DiscoveredPeer {
                                        peer_id: peer_id_str.clone(),
                                        addresses: vec![addr.to_string()],
                                    },
                                })
                                .await;
                            // If we already have an Olm session from a previous run,
                            // notify Dart so the encrypted indicator shows up immediately.
                            if olm.has_session(&peer_id_str) {
                                let _ = event_tx
                                    .send(NetworkEvent::SessionEstablished {
                                        peer_id: peer_id_str,
                                    })
                                    .await;
                            }
                        }
                    }
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Mdns(mdns::Event::Expired(peers))) => {
                        for (peer_id, _addr) in peers {
                            let _ = event_tx
                                .send(NetworkEvent::PeerExpired {
                                    peer_id: peer_id.to_string(),
                                })
                                .await;
                        }
                    }
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Messaging(event)) => {
                        match event {
                            request_response::Event::Message { peer, message, .. } => {
                                match message {
                                    request_response::Message::Request { request, channel, .. } => {
                                        handle_incoming_request(
                                            &mut swarm,
                                            &mut olm,
                                            &crypto_store,
                                            &event_tx,
                                            &mut pending_requests,
                                            &mut outbound_message_text,
                                            &mut pending_messages,
                                            &mut key_request_in_flight,
                                            &mut server_states,
                                            &bundle_keypair,
                                            &connected_peers,
                                            &mut pending_server_joins,
                                            &mut pending_sync_requests,
                                            peer,
                                            request,
                                            channel,
                                        ).await;
                                    }
                                    request_response::Message::Response { request_id, response, .. } => {
                                        handle_incoming_response(
                                            &mut swarm,
                                            &mut olm,
                                            &crypto_store,
                                            &event_tx,
                                            &mut pending_requests,
                                            &mut outbound_message_text,
                                            &mut pending_messages,
                                            &mut key_request_in_flight,
                                            &mut pending_sync_requests,
                                            &bundle_keypair,
                                            request_id,
                                            response,
                                        ).await;
                                    }
                                }
                            }
                            request_response::Event::OutboundFailure { request_id, error, .. } => {
                                if let Some(to_peer) = pending_requests.remove(&request_id) {
                                    key_request_in_flight.remove(&to_peer);

                                    // If this was an encrypted message, re-queue the original
                                    // text so it can be retried when the connection is established.
                                    if let Some((_peer_str, original_text)) = outbound_message_text.remove(&request_id) {
                                        haven_log!("[HAVEN-SWARM] OutboundFailure for {to_peer}, re-queuing message for retry");
                                        pending_messages
                                            .entry(to_peer.clone())
                                            .or_default()
                                            .push(original_text);
                                        // Don't remove the Olm session here — transport failures
                                        // (relay timeout, connection drop) don't mean the crypto
                                        // session is broken. Removing it causes a dual-outbound
                                        // race on reconnect where both peers create new sessions
                                        // from DHT prekeys and neither can decrypt the other's.
                                    } else {
                                        // Not a message send (was a KeyRequest or similar) — report failure.
                                        let _ = event_tx
                                            .send(NetworkEvent::MessageSendFailed {
                                                to_peer,
                                                error: format!("{error:?}"),
                                            })
                                            .await;
                                    }
                                }
                            }
                            _ => {}
                        }
                    }

                    // -- Kademlia DHT events --
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Kademlia(event)) => {
                        match event {
                            kad::Event::RoutingUpdated { peer, addresses, .. } => {
                                // A peer was added/updated in the routing table.
                                for addr in addresses.iter() {
                                    swarm.add_peer_address(peer, addr.clone());
                                }
                            }
                            kad::Event::OutboundQueryProgressed { id, result, .. } => {
                                match result {
                                    kad::QueryResult::Bootstrap(Ok(_)) => {
                                        // Bootstrap completed — DHT routing table populated.
                                    }
                                    kad::QueryResult::Bootstrap(Err(e)) => {
                                        let _ = event_tx
                                            .send(NetworkEvent::Error {
                                                message: format!("Kademlia bootstrap failed: {e:?}"),
                                            })
                                            .await;
                                    }
                                    kad::QueryResult::PutRecord(Ok(_)) => {
                                        let _ = event_tx.send(NetworkEvent::Error {
                                            message: "[DHT] put_record succeeded".to_string(),
                                        }).await;
                                    }
                                    kad::QueryResult::PutRecord(Err(e)) => {
                                        let _ = event_tx.send(NetworkEvent::Error {
                                            message: format!("[DHT] put_record failed: {e:?}"),
                                        }).await;
                                    }
                                    kad::QueryResult::GetRecord(Ok(
                                        kad::GetRecordOk::FoundRecord(kad::PeerRecord { record, .. })
                                    )) => {
                                        // Check if this is a prekey fetch we initiated.
                                        haven_log!("[HAVEN-SWARM] GetRecord FoundRecord for query {:?}", id);
                                        if let Some(target_peer) = pending_prekey_fetches.remove(&id) {
                                            haven_log!("[HAVEN-SWARM] Found prekey record for {target_peer}");
                                            dht_fetch_in_flight.remove(&target_peer);

                                            let mut used = false;
                                            if let Ok(bundle) = serde_json::from_slice::<PrekeyBundle>(&record.value)
                                                && bundle.peer_id == target_peer
                                            {
                                                match verify_prekey_bundle(&bundle) {
                                                    Ok(true) => {
                                                        // Pick a random OTK to reduce collisions.
                                                        let idx = (std::time::SystemTime::now()
                                                            .duration_since(std::time::UNIX_EPOCH)
                                                            .unwrap_or_default()
                                                            .subsec_nanos() as usize)
                                                            % bundle.one_time_keys.len();
                                                        let otk = &bundle.one_time_keys[idx];

                                                        match olm.create_outbound_session(
                                                            &target_peer,
                                                            &bundle.identity_key,
                                                            otk,
                                                        ) {
                                                            Ok(()) => {
                                                                persist_crypto_state(&olm, &crypto_store, &target_peer);
                                                                let _ = event_tx.send(NetworkEvent::SessionEstablished {
                                                                    peer_id: target_peer.clone(),
                                                                }).await;
                                                                let _ = event_tx.send(NetworkEvent::Error {
                                                                    message: format!("[DHT] Session established from prekey for {target_peer}"),
                                                                }).await;

                                                                // Flush pending messages.
                                                                if let Some(queued) = pending_messages.remove(&target_peer)
                                                                    && let Ok(pid) = target_peer.parse::<PeerId>()
                                                                {
                                                                    for text in queued {
                                                                        send_encrypted_message(
                                                                            &mut swarm, &mut olm, &crypto_store,
                                                                            &mut pending_requests, &mut outbound_message_text,
                                                                            &pid, &target_peer, &text, &event_tx,
                                                                        ).await;
                                                                    }
                                                                }
                                                                // Retry failed sync batches after re-key.
                                                                if let Ok(pid) = target_peer.parse::<PeerId>() {
                                                                    flush_pending_sync_requests(
                                                                        &mut pending_sync_requests, &target_peer, &pid,
                                                                        &mut swarm, &mut olm, &crypto_store,
                                                                        &mut pending_requests, &mut outbound_message_text,
                                                                        &bundle_keypair, &event_tx,
                                                                    ).await;
                                                                }
                                                                used = true;
                                                            }
                                                            Err(e) => {
                                                                let _ = event_tx.send(NetworkEvent::Error {
                                                                    message: format!("[DHT] Prekey session creation failed: {e}"),
                                                                }).await;
                                                            }
                                                        }
                                                    }
                                                    Ok(false) => {
                                                        let _ = event_tx.send(NetworkEvent::Error {
                                                            message: format!("[DHT] Prekey bundle invalid/expired for {target_peer}"),
                                                        }).await;
                                                    }
                                                    Err(e) => {
                                                        let _ = event_tx.send(NetworkEvent::Error {
                                                            message: format!("[DHT] Prekey verification error: {e}"),
                                                        }).await;
                                                    }
                                                }
                                            }

                                            // If DHT bundle wasn't used, fall back to KeyRequest.
                                            if !used && !olm.has_session(&target_peer)
                                                && let Ok(pid) = target_peer.parse::<PeerId>()
                                                && !key_request_in_flight.contains(&target_peer)
                                            {
                                                key_request_in_flight.insert(target_peer.clone());
                                                let req_id = swarm.behaviour_mut().messaging.send_request(
                                                    &pid,
                                                    HavenMessage::KeyRequest,
                                                );
                                                pending_requests.insert(req_id, target_peer);
                                            }
                                        }
                                    }
                                    kad::QueryResult::GetRecord(Ok(
                                        kad::GetRecordOk::FinishedWithNoAdditionalRecord { .. }
                                    )) => {
                                        // If this query is still pending (no FoundRecord came), fall back.
                                        haven_log!("[HAVEN-SWARM] GetRecord FinishedWithNoAdditionalRecord for query {:?}", id);
                                        if let Some(target_peer) = pending_prekey_fetches.remove(&id) {
                                            haven_log!("[HAVEN-SWARM] No prekey record found for {target_peer}, falling back");
                                            dht_fetch_in_flight.remove(&target_peer);
                                            let _ = event_tx.send(NetworkEvent::Error {
                                                message: format!("[DHT] No prekey found for {target_peer}, falling back to KeyRequest"),
                                            }).await;

                                            if !olm.has_session(&target_peer)
                                                && let Ok(pid) = target_peer.parse::<PeerId>()
                                                && !key_request_in_flight.contains(&target_peer)
                                            {
                                                key_request_in_flight.insert(target_peer.clone());
                                                let req_id = swarm.behaviour_mut().messaging.send_request(
                                                    &pid,
                                                    HavenMessage::KeyRequest,
                                                );
                                                pending_requests.insert(req_id, target_peer);
                                            }
                                        }
                                    }
                                    kad::QueryResult::GetRecord(Err(e)) => {
                                        // DHT fetch failed — fall back to KeyRequest.
                                        haven_log!("[HAVEN-SWARM] GetRecord Error for query {:?}: {e:?}", id);
                                        if let Some(target_peer) = pending_prekey_fetches.remove(&id) {
                                            haven_log!("[HAVEN-SWARM] GetRecord failed for {target_peer}, falling back");
                                            dht_fetch_in_flight.remove(&target_peer);
                                            let _ = event_tx.send(NetworkEvent::Error {
                                                message: format!("[DHT] Prekey fetch failed for {target_peer}: {e:?}"),
                                            }).await;

                                            if !olm.has_session(&target_peer)
                                                && let Ok(pid) = target_peer.parse::<PeerId>()
                                                && !key_request_in_flight.contains(&target_peer)
                                            {
                                                key_request_in_flight.insert(target_peer.clone());
                                                let req_id = swarm.behaviour_mut().messaging.send_request(
                                                    &pid,
                                                    HavenMessage::KeyRequest,
                                                );
                                                pending_requests.insert(req_id, target_peer);
                                            }
                                        }
                                    }
                                    _ => {}
                                }
                            }
                            _ => {}
                        }
                    }

                    // -- AutoNAT events --
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Autonat(
                        autonat::Event::StatusChanged { new, .. }
                    )) => {
                        match new {
                            autonat::NatStatus::Public(addr) => {
                                // We're publicly reachable — advertise our address.
                                let addr_str = addr.to_string();
                                if !known_addresses.contains(&addr_str) {
                                    known_addresses.push(addr_str);
                                }
                                swarm.add_external_address(addr);
                            }
                            autonat::NatStatus::Private => {
                                // Behind NAT — rely on relay + hole punching.
                            }
                            autonat::NatStatus::Unknown => {}
                        }
                    }
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Autonat(_)) => {}

                    // -- DCUtR (hole punching) events --
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Dcutr(event)) => {
                        match event.result {
                            Ok(_connection_id) => {
                                let _ = event_tx
                                    .send(NetworkEvent::Listening {
                                        address: format!("hole-punch-ok:{}", event.remote_peer_id),
                                    })
                                    .await;
                            }
                            Err(error) => {
                                let _ = event_tx
                                    .send(NetworkEvent::Error {
                                        message: format!("Hole punch failed to {}: {error}", event.remote_peer_id),
                                    })
                                    .await;
                            }
                        }
                    }

                    // -- Relay client events --
                    SwarmEvent::Behaviour(HavenBehaviourEvent::RelayClient(event)) => {
                        match event {
                            relay::client::Event::ReservationReqAccepted { relay_peer_id, renewal, .. } => {
                                if !renewal {
                                    let _ = event_tx
                                        .send(NetworkEvent::Listening {
                                            address: format!("relay-reserved:{relay_peer_id}"),
                                        })
                                        .await;
                                }
                            }
                            relay::client::Event::OutboundCircuitEstablished { relay_peer_id, .. } => {
                                let _ = event_tx
                                    .send(NetworkEvent::Listening {
                                        address: format!("relay-circuit-out:{relay_peer_id}"),
                                    })
                                    .await;
                            }
                            relay::client::Event::InboundCircuitEstablished { src_peer_id, .. } => {
                                let _ = event_tx
                                    .send(NetworkEvent::Listening {
                                        address: format!("relay-circuit-in:{src_peer_id}"),
                                    })
                                    .await;
                                // Peer is genuinely connecting to us — clear from
                                // disconnected set so they can be re-discovered.
                                disconnected_peers.remove(&src_peer_id);
                                expected_peers.insert(src_peer_id);
                                // Emit PeerDiscovered so the Dart UI shows this peer.
                                let _ = event_tx
                                    .send(NetworkEvent::PeerDiscovered {
                                        peer: DiscoveredPeer {
                                            peer_id: src_peer_id.to_string(),
                                            addresses: vec![format!(
                                                "{}/p2p/{}/p2p-circuit/p2p/{}",
                                                RELAY_ADDR_QUIC, RELAY_PEER_ID, src_peer_id
                                            )],
                                        },
                                    })
                                    .await;
                            }
                        }
                    }

                    // -- Identify events --
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Identify(
                        identify::Event::Received { peer_id, info, .. },
                    )) => {
                        // Add identified peer's addresses to Kademlia.
                        for addr in info.listen_addrs {
                            swarm.behaviour_mut().kademlia.add_address(&peer_id, addr);
                        }
                    }
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Identify(_)) => {}

                    // -- Ping events --
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Ping(_)) => {}

                    // -- Debug: connection lifecycle --
                    SwarmEvent::ConnectionEstablished { peer_id, num_established, endpoint, .. } => {
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!("[DEBUG] Connected to {peer_id} via {endpoint:?}"),
                            })
                            .await;

                        // Track connected peers (skip relay node).
                        if relay_peer_id() != Some(peer_id) {
                            connected_peers.insert(peer_id);
                            // Peer genuinely reconnected — allow future bootstraps to re-add them.
                            disconnected_peers.remove(&peer_id);

                            // Send join requests for any pending server joins.
                            for sid in pending_server_joins.iter() {
                                swarm.behaviour_mut().messaging.send_request(
                                    &peer_id,
                                    HavenMessage::ServerJoinRequest {
                                        server_id: sid.clone(),
                                    },
                                );
                            }

                            // Only emit PeerDiscovered for peers we expect (from
                            // signaling bootstrap, mDNS, or relay inbound circuit).
                            // This prevents Kademlia routing connections from
                            // polluting the peer list.
                            if num_established.get() == 1 && expected_peers.contains(&peer_id) {
                                let peer_id_str = peer_id.to_string();
                                let _ = event_tx
                                    .send(NetworkEvent::PeerDiscovered {
                                        peer: DiscoveredPeer {
                                            peer_id: peer_id_str.clone(),
                                            addresses: vec![format!("{endpoint:?}")],
                                        },
                                    })
                                    .await;
                                if olm.has_session(&peer_id_str) {
                                    // Re-emit SessionEstablished so the lock icon appears.
                                    let _ = event_tx
                                        .send(NetworkEvent::SessionEstablished {
                                            peer_id: peer_id_str.clone(),
                                        })
                                        .await;
                                    // Retry any failed sync batches on reconnect.
                                    flush_pending_sync_requests(
                                        &mut pending_sync_requests, &peer_id_str, &peer_id,
                                        &mut swarm, &mut olm, &crypto_store,
                                        &mut pending_requests, &mut outbound_message_text,
                                        &bundle_keypair, &event_tx,
                                    ).await;
                                } else if !key_request_in_flight.contains(&peer_id_str)
                                    && !dht_fetch_in_flight.contains(&peer_id_str)
                                {
                                    // No Olm session — proactively start key exchange
                                    // so encryption is ready before the first message.
                                    haven_log!("[HAVEN-SWARM] Proactive key exchange for {peer_id_str}");
                                    let record_key = kad::RecordKey::new(
                                        &format!("/haven/prekeys/{}", peer_id_str),
                                    );
                                    let query_id = swarm.behaviour_mut().kademlia
                                        .get_record(record_key);
                                    pending_prekey_fetches.insert(query_id, peer_id_str.clone());
                                    dht_fetch_in_flight.insert(peer_id_str);
                                }
                            }

                            // -- Trigger CRDT sync + message sync for shared servers --
                            // Only on FIRST connection to this peer (not duplicate TCP/QUIC/relay).
                            if num_established.get() == 1 {
                                let reconnected_peer_str = peer_id.to_string();
                                let mut is_server_member = false;
                                for (sid, state) in server_states.iter() {
                                    if state.members.contains_key(&reconnected_peer_str) {
                                        is_server_member = true;
                                        // CRDT state sync (channels, members, roles).
                                        let our_vector = StateVector::from_server_state(state);
                                        if let Ok(sv_json) = serde_json::to_string(&our_vector) {
                                            swarm.behaviour_mut().messaging.send_request(
                                                &peer_id,
                                                HavenMessage::SyncRequest {
                                                    server_id: sid.clone(),
                                                    state_vector_json: sv_json,
                                                },
                                            );
                                        }

                                        // Channel message sync — request missed messages.
                                        let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                                        if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                                for (cid, _) in state.channels.iter() {
                                                    let since = store
                                                        .get_latest_channel_timestamp(sid, cid)
                                                        .unwrap_or(None)
                                                        .unwrap_or(0);
                                                    swarm.behaviour_mut().messaging.send_request(
                                                        &peer_id,
                                                        HavenMessage::ChannelSyncRequest {
                                                            server_id: sid.clone(),
                                                            channel_id: cid.clone(),
                                                            since_timestamp: since,
                                                        },
                                                    );
                                                }
                                            }
                                        }

                                        let _ = event_tx.send(NetworkEvent::MessageSyncStarted {
                                            server_id: sid.clone(),
                                            peer_id: reconnected_peer_str.clone(),
                                        }).await;
                                    }
                                }

                                // Ensure server members show as online in UI even if
                                // they weren't in expected_peers (e.g., discovered via
                                // CRDT membership, not signaling bootstrap).
                                if is_server_member && !expected_peers.contains(&peer_id) {
                                    let _ = event_tx
                                        .send(NetworkEvent::PeerDiscovered {
                                            peer: DiscoveredPeer {
                                                peer_id: reconnected_peer_str.clone(),
                                                addresses: vec![format!("{endpoint:?}")],
                                            },
                                        })
                                        .await;
                                    if olm.has_session(&reconnected_peer_str) {
                                        let _ = event_tx
                                            .send(NetworkEvent::SessionEstablished {
                                                peer_id: reconnected_peer_str,
                                            })
                                            .await;
                                    }
                                }
                            }
                        }

                        // Once connected to the relay, request a circuit reservation.
                        // Use the transport that actually connected (check endpoint).
                        if relay_peer_id() == Some(peer_id) {
                            let ep_str = format!("{endpoint:?}");
                            let base = if ep_str.contains("quic") {
                                RELAY_ADDR_QUIC
                            } else if ep_str.contains("ws") || ep_str.contains("443") {
                                RELAY_ADDR_WSS
                            } else {
                                RELAY_ADDR_TCP
                            };
                            let relay_circuit: Multiaddr = format!(
                                "{base}/p2p/{RELAY_PEER_ID}/p2p-circuit"
                            )
                            .parse()
                            .unwrap();
                            let _ = event_tx
                                .send(NetworkEvent::Error {
                                    message: format!("[DEBUG] Connected to relay! Requesting circuit via: {relay_circuit}"),
                                })
                                .await;
                            if let Err(e) = swarm.listen_on(relay_circuit) {
                                let _ = event_tx
                                    .send(NetworkEvent::Error {
                                        message: format!("Failed to listen on relay circuit: {e}"),
                                    })
                                    .await;
                            }
                        } else {
                            // Connected to a non-relay peer. If we have pending messages
                            // for them (re-queued after a failed send), initiate key
                            // exchange or send them now.
                            let peer_str = peer_id.to_string();
                            if pending_messages.contains_key(&peer_str) {
                                haven_log!("[HAVEN-SWARM] Connection established to {peer_str}, flushing pending messages");
                                if olm.has_session(&peer_str) {
                                    // Session exists — flush immediately.
                                    if let Some(queued) = pending_messages.remove(&peer_str) {
                                        for text in queued {
                                            send_encrypted_message(
                                                &mut swarm, &mut olm, &crypto_store,
                                                &mut pending_requests, &mut outbound_message_text,
                                                &peer_id, &peer_str, &text, &event_tx,
                                            ).await;
                                        }
                                    }
                                } else if !key_request_in_flight.contains(&peer_str)
                                    && !dht_fetch_in_flight.contains(&peer_str)
                                {
                                    // No session — try DHT prekey fetch first.
                                    let record_key = kad::RecordKey::new(
                                        &format!("/haven/prekeys/{}", peer_str),
                                    );
                                    let query_id = swarm.behaviour_mut().kademlia
                                        .get_record(record_key);
                                    pending_prekey_fetches.insert(query_id, peer_str.clone());
                                    dht_fetch_in_flight.insert(peer_str.clone());
                                    haven_log!("[HAVEN-SWARM] Starting DHT prekey fetch for {peer_str}");
                                }
                            }
                        }
                    }
                    SwarmEvent::OutgoingConnectionError { peer_id, error, .. } => {
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!("[DEBUG] Dial failed to {peer_id:?}: {error}"),
                            })
                            .await;
                    }
                    SwarmEvent::ListenerError { listener_id, error } => {
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!("[DEBUG] Listener error ({listener_id:?}): {error}"),
                            })
                            .await;
                    }
                    SwarmEvent::ListenerClosed { listener_id, reason, .. } => {
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!("[DEBUG] Listener closed ({listener_id:?}): {reason:?}"),
                            })
                            .await;
                    }

                    SwarmEvent::ConnectionClosed { peer_id, num_established, cause, .. } => {
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!(
                                    "[DEBUG] Connection to {peer_id} closed (remaining: {num_established}, cause: {cause:?})"
                                ),
                            })
                            .await;

                        // Only emit PeerDisconnected when ALL connections to this peer are gone.
                        if num_established == 0 && relay_peer_id() != Some(peer_id) {
                            connected_peers.remove(&peer_id);
                            disconnected_peers.insert(peer_id, std::time::Instant::now());
                            let _ = event_tx
                                .send(NetworkEvent::PeerDisconnected {
                                    peer_id: peer_id.to_string(),
                                })
                                .await;
                        }

                        // Relay connection lost — immediately re-dial to restore circuit.
                        if num_established == 0 && relay_peer_id() == Some(peer_id) {
                            let _ = event_tx.send(NetworkEvent::Error {
                                message: "[RELAY] Relay connection lost! Re-dialing in 5s...".to_string(),
                            }).await;
                            // Remove stale relay circuit addresses.
                            known_addresses.retain(|a| !a.contains("p2p-circuit"));
                            // Brief delay before re-dial to avoid tight reconnect loops.
                            let relay_pid = peer_id;
                            tokio::time::sleep(Duration::from_secs(5)).await;
                            for addr in relay_addrs() {
                                swarm.add_peer_address(relay_pid, addr.clone());
                                swarm.behaviour_mut().kademlia.add_address(&relay_pid, addr);
                            }
                            if let Err(e) = swarm.dial(relay_pid) {
                                let _ = event_tx.send(NetworkEvent::Error {
                                    message: format!("[RELAY] Re-dial failed: {e}"),
                                }).await;
                            }
                        }
                    }

                    _ => {}
                }
            }
            // Handle signaling service events (bootstrap peer discovery).
            Some(sig_event) = sig_event_rx.recv() => {
                match sig_event {
                    SignalingEvent::BootstrapPeers { peers } => {
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!("[DEBUG] Bootstrap returned {} peers", peers.len()),
                            })
                            .await;
                        for bp in peers {
                            // Skip ourselves.
                            let Ok(peer_id) = bp.peer_id.parse::<PeerId>() else {
                                continue;
                            };
                            if peer_id == *swarm.local_peer_id() {
                                continue;
                            }
                            // Skip peers we already tried and disconnected from.
                            // Prevents ghost peers from stale signaling entries.
                            if disconnected_peers.contains_key(&peer_id) {
                                continue;
                            }
                            // Skip peers we're already connected to.
                            if connected_peers.contains(&peer_id) {
                                continue;
                            }

                            // Register addresses from signaling + add relay circuits.
                            // Strategy: dial relay circuit FIRST for instant connectivity,
                            // then add direct addresses so libp2p can upgrade later.
                            // This avoids 10s+ timeouts on stale direct addresses.

                            let mut relay_circuit_addrs = Vec::new();

                            // Build relay circuit addresses (fast, reliable path).
                            if let Some(relay_pid) = relay_peer_id() {
                                for base in [RELAY_ADDR_TCP, RELAY_ADDR_WSS] {
                                    if let Ok(circuit_addr) = format!(
                                        "{}/p2p/{}/p2p-circuit/p2p/{}",
                                        base, relay_pid, peer_id
                                    ).parse::<Multiaddr>() {
                                        relay_circuit_addrs.push(circuit_addr);
                                    }
                                }
                            }

                            // Add relay circuit addresses and dial them first.
                            // This gives us a connection within ~1s via relay.
                            for addr in &relay_circuit_addrs {
                                swarm.add_peer_address(peer_id, addr.clone());
                            }

                            // Mark as expected so ConnectionEstablished can emit PeerDiscovered.
                            expected_peers.insert(peer_id);

                            // Notify Dart of the discovered peer.
                            let _ = event_tx
                                .send(NetworkEvent::PeerDiscovered {
                                    peer: DiscoveredPeer {
                                        peer_id: bp.peer_id.clone(),
                                        addresses: bp.addresses.clone(),
                                    },
                                })
                                .await;

                            // Dial relay circuit first for fast connection.
                            let _ = swarm.dial(peer_id);

                            // NOW add direct addresses from signaling (for potential
                            // direct upgrade via DCUtR/hole-punching later).
                            for addr_str in &bp.addresses {
                                if let Ok(addr) = addr_str.parse::<Multiaddr>() {
                                    swarm.add_peer_address(peer_id, addr.clone());
                                    if !addr_str.contains("p2p-circuit") {
                                        swarm.behaviour_mut().kademlia.add_address(&peer_id, addr);
                                    }
                                }
                            }
                        }

                        // Trigger Kademlia bootstrap to populate routing table.
                        let _ = swarm.behaviour_mut().kademlia.bootstrap();
                    }
                    SignalingEvent::Error { message } => {
                        let _ = event_tx
                            .send(NetworkEvent::Error { message })
                            .await;
                    }
                }
            }

            // Republish prekey bundle periodically to keep DHT records fresh.
            _ = prekey_timer.tick() => {
                if prekey_published {
                    let peer_id_str = swarm.local_peer_id().to_string();
                    match publish_prekey_bundle(
                        &mut swarm, &bundle_keypair, &peer_id_str, &pub_key_b64,
                        &mut olm, &crypto_store,
                    ) {
                        Ok(()) => {
                            let _ = event_tx.send(NetworkEvent::Error {
                                message: "[DHT] Prekey bundle republished".to_string(),
                            }).await;
                        }
                        Err(e) => {
                            let _ = event_tx.send(NetworkEvent::Error {
                                message: format!("[DHT] Prekey republish failed: {e}"),
                            }).await;
                        }
                    }
                }
            }

            // Periodic re-bootstrap for mutual peer discovery.
            _ = rebootstrap_timer.tick() => {
                // Clear disconnected peers that have cooled down past the stale threshold.
                // This prevents ghost re-discovery from signaling entries that haven't
                // been cleaned up yet. Only peers disconnected > 3 min ago are cleared.
                if !disconnected_peers.is_empty() {
                    let now = std::time::Instant::now();
                    let before = disconnected_peers.len();
                    disconnected_peers.retain(|_, disconnected_at| {
                        now.duration_since(*disconnected_at) < DISCONNECT_COOLDOWN
                    });
                    let cleared = before - disconnected_peers.len();
                    if cleared > 0 {
                        haven_log!("[HAVEN-SWARM] Cleared {cleared} cooled-down disconnected peers ({} still cooling)", disconnected_peers.len());
                    }
                }
                if let Some(room) = &active_room {
                    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                        room_code: room.clone(),
                    }).await;
                }
                // Also re-bootstrap all server signaling rooms.
                for sid in server_states.keys() {
                    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                        room_code: sid.clone(),
                    }).await;
                }
            }

            // Relay health check — re-dial relay if connection dropped.
            _ = relay_health_timer.tick() => {
                if let Some(relay_pid) = relay_peer_id() {
                    if !swarm.is_connected(&relay_pid) {
                        let _ = event_tx.send(NetworkEvent::Error {
                            message: "[RELAY] Not connected to relay, re-dialing...".to_string(),
                        }).await;
                        // Remove stale relay circuit addresses.
                        known_addresses.retain(|a| !a.contains("p2p-circuit"));
                        // Re-add relay addresses and dial.
                        for addr in relay_addrs() {
                            swarm.add_peer_address(relay_pid, addr.clone());
                            swarm.behaviour_mut().kademlia.add_address(&relay_pid, addr);
                        }
                        let _ = swarm.dial(relay_pid);
                    } else {
                        // Connected to relay but check if we have a circuit address.
                        let has_circuit = known_addresses.iter().any(|a| a.contains("p2p-circuit"));
                        if !has_circuit {
                            let _ = event_tx.send(NetworkEvent::Error {
                                message: "[RELAY] Connected but no circuit address, re-requesting...".to_string(),
                            }).await;
                            // Re-request circuit reservation.
                            let relay_circuit: Multiaddr = format!(
                                "{}/p2p/{}/p2p-circuit",
                                RELAY_ADDR_QUIC, RELAY_PEER_ID
                            ).parse().unwrap();
                            let _ = swarm.listen_on(relay_circuit);
                        }
                    }
                }
            }
        }
    }
}

/// Encrypt and send a message to a peer with an established session.
/// Returns `true` on success, `false` if encryption failed.
async fn send_encrypted_message(
    swarm: &mut libp2p::Swarm<HavenBehaviour>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    pending_requests: &mut HashMap<request_response::OutboundRequestId, String>,
    outbound_message_text: &mut HashMap<request_response::OutboundRequestId, (String, String)>,
    peer_id: &PeerId,
    peer_id_str: &str,
    text: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
) -> bool {
    match olm.encrypt(peer_id_str, text.as_bytes()) {
        Ok((msg_type, ciphertext)) => {
            // Persist crypto state.
            persist_crypto_state(olm, crypto_store, peer_id_str);

            let identity_key = if msg_type == 0 {
                Some(olm.identity_key_base64())
            } else {
                None
            };

            let req_id = swarm.behaviour_mut().messaging.send_request(
                peer_id,
                HavenMessage::Encrypted {
                    message_type: msg_type,
                    body: OlmManager::encode_base64(&ciphertext),
                    identity_key,
                },
            );
            pending_requests.insert(req_id, peer_id_str.to_string());
            // Track original text so we can re-queue on delivery failure.
            outbound_message_text.insert(req_id, (peer_id_str.to_string(), text.to_string()));
            true
        }
        Err(e) => {
            let _ = event_tx
                .send(NetworkEvent::MessageSendFailed {
                    to_peer: peer_id_str.to_string(),
                    error: format!("Encryption failed: {e}"),
                })
                .await;
            false
        }
    }
}

/// Handle an incoming request from a peer.
async fn handle_incoming_request(
    swarm: &mut libp2p::Swarm<HavenBehaviour>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    pending_requests: &mut HashMap<request_response::OutboundRequestId, String>,
    outbound_message_text: &mut HashMap<request_response::OutboundRequestId, (String, String)>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut std::collections::HashSet<String>,
    server_states: &mut HashMap<String, ServerState>,
    bundle_keypair: &identity::Keypair,
    connected_peers: &std::collections::HashSet<PeerId>,
    pending_server_joins: &mut std::collections::HashSet<String>,
    pending_sync_requests: &mut HashMap<String, Vec<(String, String, i64)>>,
    peer: PeerId,
    request: HavenMessage,
    channel: request_response::ResponseChannel<HavenMessage>,
) {
    let peer_str = peer.to_string();

    match request {
        HavenMessage::KeyRequest => {
            // Peer wants our key bundle — generate a one-time key and respond.
            let otk = olm.generate_one_time_key();
            let identity_key = olm.identity_key_base64();

            // Persist account (one-time key was consumed).
            if let Ok(pickle) = olm.account_pickle_json() {
                crypto_store.save_account(pickle);
            }

            let _ = swarm.behaviour_mut().messaging.send_response(
                channel,
                HavenMessage::KeyBundle {
                    identity_key,
                    one_time_key: otk,
                },
            );
        }

        HavenMessage::Encrypted { message_type, body, identity_key } => {
            let ciphertext = match OlmManager::decode_base64(&body) {
                Ok(b) => b,
                Err(e) => {
                    let _ = event_tx
                        .send(NetworkEvent::Error {
                            message: format!("Failed to decode message from {peer_str}: {e}"),
                        })
                        .await;
                    let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
                    return;
                }
            };

            let plaintext = if message_type == 0 {
                // PreKeyMessage — create inbound session.
                let their_identity = match &identity_key {
                    Some(k) => k,
                    None => {
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!("PreKeyMessage from {peer_str} missing identity_key"),
                            })
                            .await;
                        let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
                        return;
                    }
                };

                let had_existing_session = olm.has_session(&peer_str);

                if had_existing_session {
                    // We already have a session with this peer. Try to decrypt the
                    // PreKey message using the existing session first. This handles
                    // the race where two encrypted messages arrive as PreKeys
                    // (e.g. sync batch response + regular channel message overlap).
                    // The first creates a new session, the second should decrypt
                    // with it rather than trying (and failing) to create another.
                    match olm.try_decrypt_prekey_with_existing(&peer_str, &ciphertext) {
                        Ok(pt) => {
                            haven_log!("[HAVEN-CRYPTO] Decrypted PreKey with existing session for {peer_str}");
                            pt
                        }
                        Err(_) => {
                            // Existing session can't handle this PreKey — it's a
                            // genuinely new session from the peer (e.g. they re-keyed).
                            // Replace our session with the new inbound one.
                            olm.remove_session(&peer_str);
                            match olm.create_inbound_session(&peer_str, their_identity, &ciphertext) {
                                Ok(pt) => {
                                    let _ = event_tx
                                        .send(NetworkEvent::SessionEstablished {
                                            peer_id: peer_str.clone(),
                                        })
                                        .await;
                                    key_request_in_flight.remove(&peer_str);
                                    if let Some(queued) = pending_messages.remove(&peer_str) {
                                        for text in queued {
                                            send_encrypted_message(
                                                swarm, olm, crypto_store, pending_requests,
                                                outbound_message_text, &peer, &peer_str, &text, event_tx,
                                            ).await;
                                        }
                                    }
                                    flush_pending_sync_requests(
                                        pending_sync_requests, &peer_str, &peer,
                                        swarm, olm, crypto_store,
                                        pending_requests, outbound_message_text,
                                        bundle_keypair, event_tx,
                                    ).await;
                                    pt
                                }
                                Err(e2) => {
                                    haven_log!("[HAVEN-CRYPTO] PreKey session creation also failed for {peer_str}: {e2} — initiating re-key");
                                    // Both paths failed. Initiate a clean re-key.
                                    if !key_request_in_flight.contains(&peer_str) {
                                        key_request_in_flight.insert(peer_str.clone());
                                        let req_id = swarm.behaviour_mut().messaging.send_request(
                                            &peer,
                                            HavenMessage::KeyRequest,
                                        );
                                        pending_requests.insert(req_id, peer_str.clone());
                                    }
                                    persist_crypto_state(olm, crypto_store, &peer_str);
                                    let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
                                    return;
                                }
                            }
                        }
                    }
                } else {
                    // No existing session — standard path: create inbound session.
                    match olm.create_inbound_session(&peer_str, their_identity, &ciphertext) {
                        Ok(pt) => {
                            let _ = event_tx
                                .send(NetworkEvent::SessionEstablished {
                                    peer_id: peer_str.clone(),
                                })
                                .await;
                            key_request_in_flight.remove(&peer_str);
                            if let Some(queued) = pending_messages.remove(&peer_str) {
                                for text in queued {
                                    send_encrypted_message(
                                        swarm, olm, crypto_store, pending_requests,
                                        outbound_message_text, &peer, &peer_str, &text, event_tx,
                                    ).await;
                                }
                            }
                            flush_pending_sync_requests(
                                pending_sync_requests, &peer_str, &peer,
                                swarm, olm, crypto_store,
                                pending_requests, outbound_message_text,
                                bundle_keypair, event_tx,
                            ).await;
                            pt
                        }
                        Err(e) => {
                            haven_log!("[HAVEN-CRYPTO] PreKey session creation failed for {peer_str}: {e} — initiating re-key");
                            if !key_request_in_flight.contains(&peer_str) {
                                key_request_in_flight.insert(peer_str.clone());
                                let req_id = swarm.behaviour_mut().messaging.send_request(
                                    &peer,
                                    HavenMessage::KeyRequest,
                                );
                                pending_requests.insert(req_id, peer_str.clone());
                            }
                            persist_crypto_state(olm, crypto_store, &peer_str);
                            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
                            return;
                        }
                    }
                }
            } else {
                // Normal encrypted message — decrypt with existing session.
                match olm.decrypt(&peer_str, message_type, &ciphertext) {
                    Ok(pt) => pt,
                    Err(e) => {
                        // Stale session — remove it and initiate fresh key exchange.
                        haven_log!("[HAVEN-SWARM] Decrypt failed for {peer_str}: {e} — removing stale session");
                        olm.remove_session(&peer_str);
                        persist_crypto_state(olm, crypto_store, &peer_str);

                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!("Stale session with {peer_str}, re-keying..."),
                            })
                            .await;

                        // Emit MessageSyncFailed for any servers where this peer is a member
                        // so the UI doesn't stay stuck on "Syncing...".
                        for (sid, state) in server_states.iter() {
                            if state.members.contains_key(&peer_str) {
                                let _ = event_tx.send(NetworkEvent::MessageSyncFailed {
                                    server_id: sid.clone(),
                                    error: format!("Decrypt failed with {peer_str}, re-keying"),
                                }).await;
                            }
                        }

                        // Send a KeyRequest to re-establish the session.
                        if !key_request_in_flight.contains(&peer_str) {
                            key_request_in_flight.insert(peer_str.clone());
                            let req_id = swarm.behaviour_mut().messaging.send_request(
                                &peer,
                                HavenMessage::KeyRequest,
                            );
                            pending_requests.insert(req_id, peer_str.clone());
                        }

                        let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
                        return;
                    }
                }
            };

            // Persist crypto state after decrypt.
            persist_crypto_state(olm, crypto_store, &peer_str);

            // Detect message envelope and route accordingly.
            let text = String::from_utf8_lossy(&plaintext).to_string();
            match serde_json::from_str::<MessageEnvelope>(&text) {
                Ok(MessageEnvelope::ChannelMessage { sid, cid, text: msg_text, ts, sig, pk }) => {
                    // Verify Ed25519 signature if present.
                    if sig.is_some() {
                        let payload = message_signing_payload(
                            "ch", &format!("{sid}:{cid}"), &peer_str, ts, &msg_text,
                        );
                        if !verify_message_signature(&peer_str, sig.as_deref(), pk.as_deref(), &payload) {
                            haven_log!("[HAVEN-CRYPTO] Signature verification FAILED for channel message from {peer_str}");
                        }
                    }

                    // Persist channel message using sender's timestamp.
                    // INSERT OR IGNORE deduplicates via UNIQUE(server_id, channel_id, sender_id, timestamp, text).
                    let mut is_new = true;
                    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            match store.insert_channel_message(
                                &sid, &cid, &peer_str, &msg_text, false, ts,
                                sig.as_deref(), pk.as_deref(),
                            ) {
                                Ok(0) => { is_new = false; } // INSERT OR IGNORE skipped — duplicate
                                Ok(_) => {}
                                Err(_) => { is_new = false; }
                            }
                        }
                    }

                    // Only emit event if this is a genuinely new message.
                    if is_new {
                        let _ = event_tx
                            .send(NetworkEvent::ChannelMessageReceived {
                                server_id: sid,
                                channel_id: cid,
                                from_peer: peer_str,
                                text: msg_text,
                                timestamp: ts,
                            })
                            .await;
                    }
                }
                Ok(MessageEnvelope::ChannelSyncBatch { sid, cid, messages, total }) => {
                    haven_log!("[HAVEN-SYNC] Received {} sync messages for {cid} in {sid} (total: {total})", messages.len());
                    let local_peer = swarm.local_peer_id().to_string();
                    let mut new_count = 0u32;
                    let received_count = messages.len() as u32;

                    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                    if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            for msg in &messages {
                                // Verify signature on each synced message.
                                if msg.sig.is_some() {
                                    let payload = message_signing_payload(
                                        "ch", &format!("{sid}:{cid}"), &msg.s, msg.ts, &msg.t,
                                    );
                                    if !verify_message_signature(&msg.s, msg.sig.as_deref(), msg.pk.as_deref(), &payload) {
                                        haven_log!("[HAVEN-CRYPTO] Signature verification FAILED for synced message from {}", msg.s);
                                    }
                                }

                                let is_mine = msg.s == local_peer;
                                match store.insert_channel_message(
                                    &sid, &cid, &msg.s, &msg.t, is_mine, msg.ts,
                                    msg.sig.as_deref(), msg.pk.as_deref(),
                                ) {
                                    Ok(1) => { new_count += 1; }
                                    _ => {} // Duplicate or error — skip.
                                }
                            }
                        }
                    }

                    // Emit progress so the UI can show "Syncing 47/120..."
                    if total > 0 {
                        let _ = event_tx.send(NetworkEvent::MessageSyncProgress {
                            server_id: sid.clone(),
                            channel_id: cid.clone(),
                            received_count,
                            total_count: total,
                        }).await;
                    }

                    // Always emit so the UI clears the "Syncing..." state.
                    let _ = event_tx.send(NetworkEvent::MessageSyncCompleted {
                        server_id: sid,
                        new_message_count: new_count,
                    }).await;
                }
                Ok(MessageEnvelope::DirectMessage { text: msg_text, ts: _ts, sig, pk }) => {
                    // Verify DM signature if present.
                    if sig.is_some() {
                        let local_peer = swarm.local_peer_id().to_string();
                        let payload = message_signing_payload(
                            "dm", &local_peer, &peer_str, _ts, &msg_text,
                        );
                        if !verify_message_signature(&peer_str, sig.as_deref(), pk.as_deref(), &payload) {
                            haven_log!("[HAVEN-CRYPTO] Signature verification FAILED for DM from {peer_str}");
                        }
                    }
                    let _ = event_tx
                        .send(NetworkEvent::MessageReceived {
                            from_peer: peer_str,
                            text: msg_text,
                        })
                        .await;
                }
                Err(_) => {
                    // Legacy raw-text DM (backward compatible).
                    let _ = event_tx
                        .send(NetworkEvent::MessageReceived {
                            from_peer: peer_str,
                            text,
                        })
                        .await;
                }
            }

            // Ack.
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
        }

        // -- CRDT sync message handlers --

        HavenMessage::SyncRequest { server_id, state_vector_json } => {
            haven_log!("[HAVEN-CRDT] SyncRequest from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            if let Some(state) = server_states.get(&server_id) {
                // Compute what they're missing
                if let Ok(their_vector) = serde_json::from_str::<StateVector>(&state_vector_json) {
                    let delta = crdt_sync::compute_delta(&state.op_log, &their_vector);
                    if !delta.is_empty() {
                        if let Ok(ops_json) = serde_json::to_string(&delta) {
                            haven_log!("[HAVEN-CRDT] Sending {} delta ops to {peer_str}", delta.len());
                            swarm.behaviour_mut().messaging.send_request(
                                &peer,
                                HavenMessage::SyncResponse {
                                    server_id: server_id.clone(),
                                    ops_json,
                                },
                            );
                        }
                    }
                }

                // No bidirectional SyncRequest here — both peers trigger
                // sync in ConnectionEstablished, so both sides already initiate.
            }
        }

        HavenMessage::SyncResponse { server_id, ops_json } => {
            haven_log!("[HAVEN-CRDT] SyncResponse from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // Room gating: only accept sync for servers we already know about
            // or are actively trying to join.
            let is_known = server_states.contains_key(&server_id);
            let is_pending_join = pending_server_joins.contains(&server_id);
            if !is_known && !is_pending_join {
                haven_log!("[HAVEN-CRDT] Ignoring SyncResponse for unknown server {server_id} (not joined)");
                return;
            }

            if let Ok(incoming_ops) = serde_json::from_str::<Vec<crate::crdt::operations::CrdtOp>>(&ops_json) {
                let state = server_states.entry(server_id.clone()).or_insert_with(|| {
                    let mut s = ServerState::new(server_id.clone(), "".into(), peer_str.clone());
                    s.set_hlc(Hlc::new(swarm.local_peer_id().to_string()));
                    s
                });

                match crdt_sync::merge_ops(state, incoming_ops) {
                    Ok(applied) if applied > 0 => {
                        haven_log!("[HAVEN-CRDT] Applied {applied} ops for server {server_id}");

                        // Persist
                        if let Ok(json) = serde_json::to_string(&state) {
                            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                            let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                            let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                            if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                                let _ = store.save_server_state(&server_id, &json);
                            }
                        }

                        // Check if this completes a pending server join
                        if pending_server_joins.remove(&server_id) {
                            let server_name = state.name().to_string();
                            haven_log!("[HAVEN-CRDT] Server join completed: {server_id} ({server_name})");
                            let _ = event_tx.send(NetworkEvent::ServerJoined {
                                server_id: server_id.clone(),
                                name: server_name,
                            }).await;

                            // Establish Olm session with all server members we're
                            // connected to but don't have sessions with yet.
                            // Also emit PeerDiscovered so they show as online.
                            for member in state.members_list() {
                                let local_id = swarm.local_peer_id().to_string();
                                if member.peer_id != local_id {
                                    if let Ok(member_pid) = member.peer_id.parse::<PeerId>() {
                                        if connected_peers.contains(&member_pid) {
                                            // Ensure member shows as online in UI.
                                            let _ = event_tx.send(NetworkEvent::PeerDiscovered {
                                                peer: DiscoveredPeer {
                                                    peer_id: member.peer_id.clone(),
                                                    addresses: vec![],
                                                },
                                            }).await;

                                            if !olm.has_session(&member.peer_id)
                                                && !key_request_in_flight.contains(&member.peer_id)
                                            {
                                                haven_log!("[HAVEN-SWARM] No Olm session with server member {}, sending KeyRequest", member.peer_id);
                                                let req_id = swarm.behaviour_mut().messaging.send_request(
                                                    &member_pid,
                                                    HavenMessage::KeyRequest,
                                                );
                                                pending_requests.insert(req_id, member.peer_id.clone());
                                                key_request_in_flight.insert(member.peer_id.clone());
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        let _ = event_tx.send(NetworkEvent::SyncCompleted {
                            server_id,
                            ops_applied: applied as u32,
                        }).await;
                    }
                    _ => {}
                }
            }
        }

        HavenMessage::CrdtOpBroadcast { server_id, op_json } => {
            haven_log!("[HAVEN-CRDT] CrdtOpBroadcast from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // Room gating: only accept ops for servers we're a member of.
            if !server_states.contains_key(&server_id) {
                haven_log!("[HAVEN-CRDT] Ignoring CrdtOpBroadcast for unknown server {server_id}");
                return;
            }

            if let Ok(op) = serde_json::from_str::<crate::crdt::operations::CrdtOp>(&op_json) {
                let state = server_states.get_mut(&server_id).unwrap();

                let was_len = state.op_log.len();
                let _ = state.apply_op(&op);

                if state.op_log.len() > was_len {
                    // New op — persist and forward to other connected peers
                    if let Ok(json) = serde_json::to_string(&state) {
                        let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            let _ = store.save_server_state(&server_id, &json);
                            let _ = store.insert_crdt_op(&op);
                        }
                    }

                    // Forward to other connected server members (simple gossip).
                    let local_peer = swarm.local_peer_id().to_string();
                    for member_peer_str in state.members.keys() {
                        if member_peer_str == &local_peer { continue; }
                        if let Ok(pid) = member_peer_str.parse::<PeerId>() {
                            if pid != peer && connected_peers.contains(&pid) {
                                swarm.behaviour_mut().messaging.send_request(
                                    &pid,
                                    HavenMessage::CrdtOpBroadcast {
                                        server_id: server_id.clone(),
                                        op_json: op_json.clone(),
                                    },
                                );
                            }
                        }
                    }

                    // Emit specific events based on op payload so Dart UI updates correctly.
                    match &op.payload {
                        CrdtPayload::ChannelAdded { channel_id, name, .. } => {
                            let _ = event_tx.send(NetworkEvent::ChannelAdded {
                                server_id: server_id.clone(),
                                channel_id: channel_id.clone(),
                                name: name.clone(),
                            }).await;
                        }
                        CrdtPayload::ChannelRemoved { channel_id } => {
                            let _ = event_tx.send(NetworkEvent::ChannelRemoved {
                                server_id: server_id.clone(),
                                channel_id: channel_id.clone(),
                            }).await;
                        }
                        CrdtPayload::ChannelRenamed { channel_id, new_name } => {
                            let _ = event_tx.send(NetworkEvent::ChannelRenamed {
                                server_id: server_id.clone(),
                                channel_id: channel_id.clone(),
                                new_name: new_name.clone(),
                            }).await;
                        }
                        CrdtPayload::MemberAdded { peer_id, .. } => {
                            let _ = event_tx.send(NetworkEvent::MemberJoined {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
                            }).await;
                        }
                        CrdtPayload::MemberRemoved { peer_id } => {
                            let _ = event_tx.send(NetworkEvent::MemberLeft {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
                            }).await;
                        }
                        CrdtPayload::RoleChanged { peer_id, role, .. } => {
                            let _ = event_tx.send(NetworkEvent::RoleChanged {
                                server_id: server_id.clone(),
                                peer_id: peer_id.clone(),
                                new_role: role.as_str().to_string(),
                            }).await;
                        }
                        _ => {
                            // ServerRenamed, ServerSettingChanged, etc.
                            let _ = event_tx.send(NetworkEvent::ServerUpdated {
                                server_id: server_id.clone(),
                            }).await;
                        }
                    }
                }
            }
        }

        HavenMessage::ServerJoinRequest { server_id } => {
            haven_log!("[HAVEN-CRDT] ServerJoinRequest from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            if let Some(state) = server_states.get_mut(&server_id) {
                // Check if peer is already a member
                let already_member = state.members_list().iter().any(|m| m.peer_id == peer_str);

                if !already_member {
                    // Add the new member via CRDT op
                    let display_name = format!("{}...{}", &peer_str[..4.min(peer_str.len())], &peer_str[peer_str.len().saturating_sub(4)..]);
                    let op = state.create_op(CrdtPayload::MemberAdded {
                        peer_id: peer_str.clone(),
                        display_name,
                    });
                    let _ = state.apply_op(&op);

                    // Persist
                    if let Ok(json) = serde_json::to_string(&state) {
                        let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                        let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                        let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                        let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                            let _ = store.save_server_state(&server_id, &json);
                            let _ = store.insert_crdt_op(&op);
                        }
                    }

                    // Broadcast MemberAdded to other peers
                    if let Ok(op_json) = serde_json::to_string(&op) {
                        for &other_peer in connected_peers.iter() {
                            swarm.behaviour_mut().messaging.send_request(
                                &other_peer,
                                HavenMessage::CrdtOpBroadcast {
                                    server_id: server_id.clone(),
                                    op_json: op_json.clone(),
                                },
                            );
                        }
                    }

                    let _ = event_tx.send(NetworkEvent::MemberJoined {
                        server_id: server_id.clone(),
                        peer_id: peer_str.clone(),
                    }).await;

                    // Emit PeerDiscovered so the new member shows as online
                    // in the member panel (they may have connected via mDNS
                    // before being a server member, skipping the normal path).
                    if connected_peers.contains(&peer) {
                        let _ = event_tx.send(NetworkEvent::PeerDiscovered {
                            peer: DiscoveredPeer {
                                peer_id: peer_str.clone(),
                                addresses: vec![],
                            },
                        }).await;
                    }
                }

                // Send full server state to the joiner (all ops so they can reconstruct)
                let all_ops: Vec<&crate::crdt::operations::CrdtOp> = state.op_log.iter().collect();
                if let Ok(ops_json) = serde_json::to_string(&all_ops) {
                    haven_log!("[HAVEN-CRDT] Sending {} ops to joiner {peer_str}", all_ops.len());
                    swarm.behaviour_mut().messaging.send_request(
                        &peer,
                        HavenMessage::SyncResponse {
                            server_id,
                            ops_json,
                        },
                    );
                }

                // Proactively establish Olm session with the new member so
                // encrypted channel sync batches can be sent immediately.
                if !olm.has_session(&peer_str) && !key_request_in_flight.contains(&peer_str) {
                    haven_log!("[HAVEN-SWARM] No Olm session with new member {peer_str}, sending KeyRequest");
                    let req_id = swarm.behaviour_mut().messaging.send_request(
                        &peer,
                        HavenMessage::KeyRequest,
                    );
                    pending_requests.insert(req_id, peer_str.clone());
                    key_request_in_flight.insert(peer_str.clone());
                }
            } else {
                haven_log!("[HAVEN-CRDT] ServerJoinRequest for unknown server {server_id}");
            }
        }

        HavenMessage::ServerDeleteBroadcast { server_id } => {
            haven_log!("[HAVEN-CRDT] ServerDeleteBroadcast from {peer_str} for server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            if server_states.remove(&server_id).is_some() {
                // Remove from DB.
                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                    let _ = store.delete_server_state(&server_id);
                }

                let _ = event_tx.send(NetworkEvent::ServerDeleted {
                    server_id,
                }).await;
            }
        }

        HavenMessage::MemberKickBroadcast { server_id } => {
            haven_log!("[HAVEN-CRDT] MemberKickBroadcast from {peer_str} — kicked from server {server_id}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // Same cleanup as ServerDeleteBroadcast — remove ourselves from this server.
            if server_states.remove(&server_id).is_some() {
                let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
                let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
                let proto = bundle_keypair.to_protobuf_encoding().unwrap_or_default();
                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                    let _ = store.delete_server_state(&server_id);
                }

                let _ = event_tx.send(NetworkEvent::ServerDeleted {
                    server_id,
                }).await;
            }
        }

        HavenMessage::ChannelSyncRequest { server_id, channel_id, since_timestamp } => {
            haven_log!("[HAVEN-SYNC] ChannelSyncRequest from {peer_str} for {channel_id} in {server_id} since {since_timestamp}");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);

            // Room gating: only respond for servers we're a member of.
            if !server_states.contains_key(&server_id) {
                return;
            }

            let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
            let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
            if let Ok(proto) = bundle_keypair.to_protobuf_encoding() {
                let passphrase = hex::encode(&proto[..32.min(proto.len())]);
                if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
                    if let Ok(messages) = store.get_channel_messages_since(
                        &server_id, &channel_id, since_timestamp, 200,
                    ) {
                        haven_log!("[HAVEN-SYNC] Sending {} sync messages for {channel_id}", messages.len());
                        let items: Vec<SyncMessageItem> = messages.iter().map(|m| {
                            SyncMessageItem {
                                s: m.sender_id.clone(),
                                t: m.text.clone(),
                                ts: m.timestamp,
                                sig: m.signature.clone(),
                                pk: m.public_key.clone(),
                            }
                        }).collect();

                        let total = store.count_channel_messages_since(
                            &server_id, &channel_id, since_timestamp,
                        ).unwrap_or(items.len() as u32);

                        let server_id_for_err = server_id.clone();
                        let channel_id_for_err = channel_id.clone();
                        let envelope = MessageEnvelope::ChannelSyncBatch {
                            sid: server_id,
                            cid: channel_id,
                            messages: items,
                            total,
                        };
                        let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

                        // Send encrypted (E2EE).
                        let ok = send_encrypted_message(
                            swarm, olm, crypto_store,
                            pending_requests, outbound_message_text,
                            &peer, &peer_str, &envelope_json, event_tx,
                        ).await;

                        if !ok {
                            haven_log!("[HAVEN-SYNC] Encryption failed for sync batch to {peer_str}, queuing retry");
                            pending_sync_requests
                                .entry(peer_str.clone())
                                .or_default()
                                .push((server_id_for_err.clone(), channel_id_for_err, since_timestamp));
                            let _ = event_tx.send(NetworkEvent::MessageSyncFailed {
                                server_id: server_id_for_err,
                                error: "Sync batch encryption failed".to_string(),
                            }).await;
                        }
                    }
                }
            }
        }

        HavenMessage::PeerDisconnecting => {
            haven_log!("[HAVEN-SWARM] Peer {peer_str} is disconnecting gracefully");
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
            // Emit PeerDisconnected immediately so the UI updates right away.
            let _ = event_tx.send(NetworkEvent::PeerDisconnected {
                peer_id: peer_str,
            }).await;
        }

        // KeyBundle and Ack shouldn't arrive as requests, but handle gracefully.
        _ => {
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
        }
    }
}

/// Handle an incoming response to one of our outbound requests.
async fn handle_incoming_response(
    swarm: &mut libp2p::Swarm<HavenBehaviour>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    pending_requests: &mut HashMap<request_response::OutboundRequestId, String>,
    outbound_message_text: &mut HashMap<request_response::OutboundRequestId, (String, String)>,
    pending_messages: &mut HashMap<String, Vec<String>>,
    key_request_in_flight: &mut std::collections::HashSet<String>,
    pending_sync_requests: &mut HashMap<String, Vec<(String, String, i64)>>,
    bundle_keypair: &identity::Keypair,
    request_id: request_response::OutboundRequestId,
    response: HavenMessage,
) {
    let Some(to_peer) = pending_requests.remove(&request_id) else {
        return;
    };

    match response {
        HavenMessage::KeyBundle { identity_key, one_time_key } => {
            // We got the peer's key bundle — create outbound session.
            key_request_in_flight.remove(&to_peer);

            if let Err(e) = olm.create_outbound_session(&to_peer, &identity_key, &one_time_key) {
                let _ = event_tx
                    .send(NetworkEvent::Error {
                        message: format!("Failed to create outbound session with {to_peer}: {e}"),
                    })
                    .await;
                return;
            }

            // Persist crypto state.
            persist_crypto_state(olm, crypto_store, &to_peer);

            let _ = event_tx
                .send(NetworkEvent::SessionEstablished {
                    peer_id: to_peer.clone(),
                })
                .await;

            // Flush all pending messages for this peer.
            let peer_id: PeerId = match to_peer.parse() {
                Ok(p) => p,
                Err(_) => return,
            };
            if let Some(queued) = pending_messages.remove(&to_peer) {
                for text in queued {
                    send_encrypted_message(
                        swarm, olm, crypto_store, pending_requests,
                        outbound_message_text, &peer_id, &to_peer, &text, event_tx,
                    ).await;
                }
            }

            // Retry any sync batches that failed due to encryption before re-key.
            flush_pending_sync_requests(
                pending_sync_requests, &to_peer, &peer_id,
                swarm, olm, crypto_store,
                pending_requests, outbound_message_text,
                bundle_keypair, event_tx,
            ).await;
        }

        HavenMessage::Ack => {
            // Delivery confirmation for an encrypted message.
            outbound_message_text.remove(&request_id);
            let _ = event_tx
                .send(NetworkEvent::MessageSent { to_peer })
                .await;
        }

        _ => {
            // Unexpected response type — ignore.
        }
    }
}

/// Retry failed sync-batch sends after a session is (re-)established with a peer.
/// Drains all queued (server_id, channel_id, since_timestamp) entries for the peer,
/// re-queries the DB, and re-sends encrypted ChannelSyncBatch responses.
async fn flush_pending_sync_requests(
    pending_sync_requests: &mut HashMap<String, Vec<(String, String, i64)>>,
    peer_str: &str,
    peer: &PeerId,
    swarm: &mut libp2p::Swarm<HavenBehaviour>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    pending_requests: &mut HashMap<request_response::OutboundRequestId, String>,
    outbound_message_text: &mut HashMap<request_response::OutboundRequestId, (String, String)>,
    bundle_keypair: &identity::Keypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
) {
    let Some(entries) = pending_sync_requests.remove(peer_str) else {
        return;
    };
    if entries.is_empty() {
        return;
    }

    haven_log!("[HAVEN-SYNC] Flushing {} pending sync requests for {peer_str}", entries.len());

    let data_dir = dirs::data_dir().unwrap_or_default().join("haven");
    let db_path = data_dir.join("messages.db").to_string_lossy().to_string();
    let Ok(proto) = bundle_keypair.to_protobuf_encoding() else { return };
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
    let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) else { return };

    for (server_id, channel_id, since_timestamp) in entries {
        let _ = event_tx.send(NetworkEvent::MessageSyncStarted {
            server_id: server_id.clone(),
            peer_id: peer_str.to_string(),
        }).await;

        match store.get_channel_messages_since(&server_id, &channel_id, since_timestamp, 200) {
            Ok(messages) => {
                haven_log!("[HAVEN-SYNC] Retry: sending {} messages for {channel_id} to {peer_str}", messages.len());
                let items: Vec<SyncMessageItem> = messages.iter().map(|m| {
                    SyncMessageItem {
                        s: m.sender_id.clone(),
                        t: m.text.clone(),
                        ts: m.timestamp,
                        sig: m.signature.clone(),
                        pk: m.public_key.clone(),
                    }
                }).collect();

                let total = store.count_channel_messages_since(
                    &server_id, &channel_id, since_timestamp,
                ).unwrap_or(items.len() as u32);

                let envelope = MessageEnvelope::ChannelSyncBatch {
                    sid: server_id.clone(),
                    cid: channel_id,
                    messages: items,
                    total,
                };
                let envelope_json = serde_json::to_string(&envelope).unwrap_or_default();

                let ok = send_encrypted_message(
                    swarm, olm, crypto_store,
                    pending_requests, outbound_message_text,
                    peer, peer_str, &envelope_json, event_tx,
                ).await;

                if !ok {
                    haven_log!("[HAVEN-SYNC] Retry also failed for {server_id} — giving up");
                    let _ = event_tx.send(NetworkEvent::MessageSyncFailed {
                        server_id,
                        error: "Retry after re-key also failed".to_string(),
                    }).await;
                }
            }
            Err(e) => {
                haven_log!("[HAVEN-SYNC] DB query failed during retry for {server_id}: {e}");
            }
        }
    }
}

/// Persist both account and session state to DB (fire-and-forget).
fn persist_crypto_state(olm: &OlmManager, crypto_store: &CryptoStore, peer_id: &str) {
    if let Ok(account_json) = olm.account_pickle_json() {
        crypto_store.save_account(account_json);
    }
    if let Ok(Some(session_json)) = olm.session_pickle_json(peer_id) {
        crypto_store.save_session(peer_id.to_string(), session_json);
    }
}
