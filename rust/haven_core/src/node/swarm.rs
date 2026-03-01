use std::collections::HashMap;
use std::io;
use std::time::Duration;

use libp2p::futures::StreamExt;
use libp2p::request_response::{self, ProtocolSupport};
use libp2p::{autonat, dcutr, identify, identity, kad, mdns, noise, ping, relay, swarm::SwarmEvent, tcp, tls, yamux, Multiaddr, PeerId, SwarmBuilder};
use base64::Engine;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

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
    MessageSent { to_peer: String },
    MessageSendFailed { to_peer: String, error: String },
    SessionEstablished { peer_id: String },
    Error { message: String },
}

/// Commands the FFI layer can send into the swarm event loop.
pub(crate) enum NodeCommand {
    SendMessage { peer_id: PeerId, text: String },
    JoinRoom { room_code: String },
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

            let ping = ping::Behaviour::default();

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

    // Re-bootstrap timer (30 seconds) for mutual peer discovery.
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
                        // If switching rooms, notify Dart to clear the peer list.
                        if active_room.is_some() && active_room.as_ref() != Some(&room_code) {
                            let _ = event_tx.send(NetworkEvent::RoomCleared).await;
                            connected_peers.clear();
                            expected_peers.clear();
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
                                &text,
                                &event_tx,
                            ).await;
                        } else {
                            // No session — queue the message and try DHT prekey fetch first.
                            pending_messages
                                .entry(peer_id_str.clone())
                                .or_default()
                                .push(text);

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

                            // When a relay circuit address appears, re-bootstrap
                            // to discover peers that registered before us.
                            if is_circuit {
                                if let Some(room) = &active_room {
                                    let _ = event_tx
                                        .send(NetworkEvent::Error {
                                            message: "[DEBUG] Relay circuit up — re-bootstrapping...".to_string(),
                                        })
                                        .await;
                                    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                                        room_code: room.clone(),
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

                                        // Also remove stale session — if the connection failed,
                                        // the session state may be out of sync.
                                        if olm.has_session(&to_peer) {
                                            olm.remove_session(&to_peer);
                                            persist_crypto_state(&olm, &crypto_store, &to_peer);
                                            haven_log!("[HAVEN-SWARM] Removed stale session for {to_peer}");
                                        }
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
                                // Re-emit SessionEstablished if we have an Olm session
                                // so the lock icon appears on reconnect.
                                if olm.has_session(&peer_id_str) {
                                    let _ = event_tx
                                        .send(NetworkEvent::SessionEstablished {
                                            peer_id: peer_id_str,
                                        })
                                        .await;
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

                            // Register any addresses from signaling.
                            for addr_str in &bp.addresses {
                                if let Ok(addr) = addr_str.parse::<Multiaddr>() {
                                    swarm.add_peer_address(peer_id, addr.clone());
                                    // Only add non-circuit addresses to Kademlia.
                                    if !addr_str.contains("p2p-circuit") {
                                        swarm.behaviour_mut().kademlia.add_address(&peer_id, addr);
                                    }
                                }
                            }

                            // Always add relay circuit addresses for the peer so libp2p
                            // can reach them through the relay even if their direct
                            // addresses are unreachable (NAT, firewall, etc.).
                            // Add both TCP and WSS circuits for censorship resilience.
                            if let Some(relay_pid) = relay_peer_id() {
                                for base in [RELAY_ADDR_TCP, RELAY_ADDR_WSS] {
                                    if let Ok(circuit_addr) = format!(
                                        "{}/p2p/{}/p2p-circuit/p2p/{}",
                                        base, relay_pid, peer_id
                                    ).parse::<Multiaddr>() {
                                        swarm.add_peer_address(peer_id, circuit_addr);
                                    }
                                }
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

                            // Attempt to dial the peer (libp2p tries all known
                            // addresses including the relay circuit).
                            let _ = swarm.dial(peer_id);
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
                if let Some(room) = &active_room {
                    let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                        room_code: room.clone(),
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
) {
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
        }
        Err(e) => {
            let _ = event_tx
                .send(NetworkEvent::MessageSendFailed {
                    to_peer: peer_id_str.to_string(),
                    error: format!("Encryption failed: {e}"),
                })
                .await;
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

                // Race condition: if we already have an outbound session and receive a
                // PreKeyMessage, the sender "wins" — replace our session.
                if olm.has_session(&peer_str) {
                    olm.remove_session(&peer_str);
                }

                match olm.create_inbound_session(&peer_str, their_identity, &ciphertext) {
                    Ok(pt) => {
                        let _ = event_tx
                            .send(NetworkEvent::SessionEstablished {
                                peer_id: peer_str.clone(),
                            })
                            .await;

                        // Flush any pending messages we were waiting to send.
                        key_request_in_flight.remove(&peer_str);
                        if let Some(queued) = pending_messages.remove(&peer_str) {
                            for text in queued {
                                send_encrypted_message(
                                    swarm, olm, crypto_store, pending_requests,
                                    outbound_message_text, &peer, &peer_str, &text, event_tx,
                                ).await;
                            }
                        }

                        pt
                    }
                    Err(e) => {
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!("Failed to create inbound session with {peer_str}: {e}"),
                            })
                            .await;
                        let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
                        return;
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

            // Emit the decrypted message to Dart.
            let text = String::from_utf8_lossy(&plaintext).to_string();
            let _ = event_tx
                .send(NetworkEvent::MessageReceived {
                    from_peer: peer_str,
                    text,
                })
                .await;

            // Ack.
            let _ = swarm.behaviour_mut().messaging.send_response(channel, HavenMessage::Ack);
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
            if let Some(queued) = pending_messages.remove(&to_peer) {
                let peer_id: PeerId = match to_peer.parse() {
                    Ok(p) => p,
                    Err(_) => return,
                };
                for text in queued {
                    send_encrypted_message(
                        swarm, olm, crypto_store, pending_requests,
                        outbound_message_text, &peer_id, &to_peer, &text, event_tx,
                    ).await;
                }
            }
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

/// Persist both account and session state to DB (fire-and-forget).
fn persist_crypto_state(olm: &OlmManager, crypto_store: &CryptoStore, peer_id: &str) {
    if let Ok(account_json) = olm.account_pickle_json() {
        crypto_store.save_account(account_json);
    }
    if let Ok(Some(session_json)) = olm.session_pickle_json(peer_id) {
        crypto_store.save_session(peer_id.to_string(), session_json);
    }
}
