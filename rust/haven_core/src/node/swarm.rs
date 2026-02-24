use std::collections::HashMap;
use std::io;
use std::time::Duration;

use libp2p::futures::StreamExt;
use libp2p::request_response::{self, ProtocolSupport};
use libp2p::{autonat, dcutr, identity, kad, mdns, noise, relay, swarm::SwarmEvent, tcp, yamux, Multiaddr, PeerId, SwarmBuilder};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

use crate::crypto::{CryptoStore, OlmManager};
use super::signaling::{self, SignalingCmd, SignalingEvent};

/// A discovered peer on the local network.
pub(crate) struct DiscoveredPeer {
    pub peer_id: String,
    pub addresses: Vec<String>,
}

/// Events emitted by the network node.
pub(crate) enum NetworkEvent {
    PeerDiscovered { peer: DiscoveredPeer },
    PeerExpired { peer_id: String },
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

/// Our libp2p network behaviour — mDNS discovery + encrypted messaging + DHT + NAT traversal.
#[derive(libp2p::swarm::NetworkBehaviour)]
struct HavenBehaviour {
    relay_client: relay::client::Behaviour,
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
        .with_relay_client(noise::Config::new, yamux::Config::default)
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

            Ok(HavenBehaviour {
                relay_client,
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
) {
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

    // Listen on relay circuit — allows NATted peers to reach us through a relay.
    // This may fail if no relay is available yet — that's OK.
    let relay_addr: Multiaddr = "/ip4/0.0.0.0/tcp/0/p2p-circuit".parse().unwrap();
    let _ = swarm.listen_on(relay_addr);

    // Track outbound request IDs → peer for delivery confirmation.
    let mut pending_requests = HashMap::<request_response::OutboundRequestId, String>::new();

    // Buffer messages while key exchange is in progress.
    let mut pending_messages: HashMap<String, Vec<String>> = HashMap::new();

    // Track which peers have an active key request in flight (avoid duplicate requests).
    let mut key_request_in_flight: std::collections::HashSet<String> = std::collections::HashSet::new();

    // Track our own listen addresses for signaling registration.
    let mut known_addresses: Vec<String> = Vec::new();

    loop {
        tokio::select! {
            // Handle commands from the FFI layer.
            Some(cmd) = cmd_rx.recv() => {
                match cmd {
                    NodeCommand::JoinRoom { room_code } => {
                        // Register ourselves and bootstrap from the signaling service.
                        let addrs = known_addresses.clone();
                        let _ = sig_cmd_tx.send(SignalingCmd::Register {
                            room_code: room_code.clone(),
                            addresses: addrs,
                        }).await;
                        let _ = sig_cmd_tx.send(SignalingCmd::Bootstrap {
                            room_code,
                        }).await;
                    }
                    NodeCommand::SendMessage { peer_id, text } => {
                        let peer_id_str = peer_id.to_string();

                        if olm.has_session(&peer_id_str) {
                            // Session exists — encrypt and send.
                            send_encrypted_message(
                                &mut swarm,
                                &mut olm,
                                &crypto_store,
                                &mut pending_requests,
                                &peer_id,
                                &peer_id_str,
                                &text,
                                &event_tx,
                            ).await;
                        } else {
                            // No session — queue the message and initiate key exchange.
                            pending_messages
                                .entry(peer_id_str.clone())
                                .or_default()
                                .push(text);

                            if !key_request_in_flight.contains(&peer_id_str) {
                                key_request_in_flight.insert(peer_id_str.clone());
                                let req_id = swarm.behaviour_mut().messaging.send_request(
                                    &peer_id,
                                    HavenMessage::KeyRequest,
                                );
                                pending_requests.insert(req_id, peer_id_str);
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
                        if !known_addresses.contains(&addr_str) {
                            known_addresses.push(addr_str.clone());
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
                                    let _ = event_tx
                                        .send(NetworkEvent::MessageSendFailed {
                                            to_peer,
                                            error: format!("{error:?}"),
                                        })
                                        .await;
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
                            kad::Event::OutboundQueryProgressed { result, .. } => {
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
                        // Relay events (reservation established, etc.) — log via catch-all for now.
                        let _ = event;
                    }

                    _ => {}
                }
            }
            // Handle signaling service events (bootstrap peer discovery).
            Some(sig_event) = sig_event_rx.recv() => {
                match sig_event {
                    SignalingEvent::BootstrapPeers { peers } => {
                        for bp in peers {
                            // Skip ourselves.
                            let Ok(peer_id) = bp.peer_id.parse::<PeerId>() else {
                                continue;
                            };
                            if peer_id == *swarm.local_peer_id() {
                                continue;
                            }

                            // Register addresses and dial.
                            for addr_str in &bp.addresses {
                                if let Ok(addr) = addr_str.parse::<Multiaddr>() {
                                    swarm.add_peer_address(peer_id, addr.clone());
                                    swarm.behaviour_mut().kademlia.add_address(&peer_id, addr);
                                }
                            }

                            // Notify Dart of the discovered peer.
                            let _ = event_tx
                                .send(NetworkEvent::PeerDiscovered {
                                    peer: DiscoveredPeer {
                                        peer_id: bp.peer_id.clone(),
                                        addresses: bp.addresses.clone(),
                                    },
                                })
                                .await;

                            // Attempt to dial the peer.
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
        }
    }
}

/// Encrypt and send a message to a peer with an established session.
async fn send_encrypted_message(
    swarm: &mut libp2p::Swarm<HavenBehaviour>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    pending_requests: &mut HashMap<request_response::OutboundRequestId, String>,
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
                                    &peer, &peer_str, &text, event_tx,
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
                        let _ = event_tx
                            .send(NetworkEvent::Error {
                                message: format!("Decryption failed from {peer_str}: {e}"),
                            })
                            .await;
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
                        &peer_id, &to_peer, &text, event_tx,
                    ).await;
                }
            }
        }

        HavenMessage::Ack => {
            // Delivery confirmation for an encrypted message.
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
