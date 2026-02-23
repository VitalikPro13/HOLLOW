use std::io;
use std::time::Duration;

use libp2p::futures::StreamExt;
use libp2p::request_response::{self, ProtocolSupport};
use libp2p::{identity, mdns, noise, swarm::SwarmEvent, tcp, yamux, Multiaddr, PeerId, SwarmBuilder};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

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
    Error { message: String },
}

/// Commands the FFI layer can send into the swarm event loop.
pub(crate) enum NodeCommand {
    SendMessage { peer_id: PeerId, text: String },
}

// -- Request-response protocol types --

/// The text message request.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct TextRequest {
    text: String,
}

/// Simple ack response.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct TextResponse {
    ack: bool,
}

/// JSON codec for our text messaging protocol.
#[derive(Debug, Clone, Default)]
struct TextCodec;

impl request_response::Codec for TextCodec {
    type Protocol = &'static str;
    type Request = TextRequest;
    type Response = TextResponse;

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

/// Our libp2p network behaviour — mDNS discovery + text messaging.
#[derive(libp2p::swarm::NetworkBehaviour)]
struct HavenBehaviour {
    mdns: mdns::tokio::Behaviour,
    messaging: request_response::Behaviour<TextCodec>,
}

/// Build and spawn the libp2p swarm. Returns the local peer ID and a join handle.
/// Also takes a command receiver so the FFI layer can send instructions.
pub(crate) async fn spawn_node(
    keypair: identity::Keypair,
    event_tx: mpsc::Sender<NetworkEvent>,
    cmd_rx: mpsc::Receiver<NodeCommand>,
) -> Result<(String, tokio::task::JoinHandle<()>), String> {
    let swarm = SwarmBuilder::with_existing_identity(keypair)
        .with_tokio()
        .with_tcp(
            tcp::Config::default(),
            noise::Config::new,
            yamux::Config::default,
        )
        .map_err(|e| format!("TCP setup failed: {e}"))?
        .with_behaviour(|key| {
            let mdns_config = mdns::Config {
                ttl: Duration::from_secs(300),
                query_interval: Duration::from_secs(5),
                enable_ipv6: false,
            };
            let mdns = mdns::tokio::Behaviour::new(mdns_config, key.public().to_peer_id())
                .expect("Failed to create mDNS behaviour");

            let messaging = request_response::Behaviour::<TextCodec>::new(
                [("/haven/msg/1.0.0", ProtocolSupport::Full)],
                request_response::Config::default(),
            );

            Ok(HavenBehaviour { mdns, messaging })
        })
        .map_err(|e| format!("Behaviour setup failed: {e}"))?
        .with_swarm_config(|cfg| {
            cfg.with_idle_connection_timeout(Duration::from_secs(u64::MAX))
        })
        .build();

    let peer_id_str = swarm.local_peer_id().to_string();
    let handle = tokio::spawn(run_swarm(swarm, event_tx, cmd_rx));

    Ok((peer_id_str, handle))
}

/// The main swarm event loop. Runs until the task is aborted.
async fn run_swarm(
    mut swarm: libp2p::Swarm<HavenBehaviour>,
    event_tx: mpsc::Sender<NetworkEvent>,
    mut cmd_rx: mpsc::Receiver<NodeCommand>,
) {
    // Listen on all interfaces, random port.
    let listen_addr: Multiaddr = "/ip4/0.0.0.0/tcp/0".parse().unwrap();
    if let Err(e) = swarm.listen_on(listen_addr) {
        let _ = event_tx
            .send(NetworkEvent::Error {
                message: format!("Failed to listen: {e}"),
            })
            .await;
        return;
    }

    // Track outbound request IDs → peer for delivery confirmation.
    let mut pending_requests = std::collections::HashMap::<
        request_response::OutboundRequestId,
        String,
    >::new();

    loop {
        tokio::select! {
            // Handle commands from the FFI layer.
            Some(cmd) = cmd_rx.recv() => {
                match cmd {
                    NodeCommand::SendMessage { peer_id, text } => {
                        let req_id = swarm.behaviour_mut().messaging.send_request(
                            &peer_id,
                            TextRequest { text },
                        );
                        pending_requests.insert(req_id, peer_id.to_string());
                    }
                }
            }
            // Handle swarm events.
            event = swarm.select_next_some() => {
                match event {
                    SwarmEvent::NewListenAddr { address, .. } => {
                        let _ = event_tx
                            .send(NetworkEvent::Listening {
                                address: address.to_string(),
                            })
                            .await;
                    }
                    SwarmEvent::Behaviour(HavenBehaviourEvent::Mdns(mdns::Event::Discovered(peers))) => {
                        for (peer_id, addr) in peers {
                            // Register the address so request-response can dial this peer.
                            swarm.add_peer_address(peer_id, addr.clone());
                            let _ = event_tx
                                .send(NetworkEvent::PeerDiscovered {
                                    peer: DiscoveredPeer {
                                        peer_id: peer_id.to_string(),
                                        addresses: vec![addr.to_string()],
                                    },
                                })
                                .await;
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
                                        // Got a text message from a peer — emit event.
                                        let _ = event_tx
                                            .send(NetworkEvent::MessageReceived {
                                                from_peer: peer.to_string(),
                                                text: request.text,
                                            })
                                            .await;
                                        // Send ack response.
                                        let _ = swarm.behaviour_mut().messaging.send_response(
                                            channel,
                                            TextResponse { ack: true },
                                        );
                                    }
                                    request_response::Message::Response { request_id, .. } => {
                                        // Got ack — message was delivered.
                                        if let Some(to_peer) = pending_requests.remove(&request_id) {
                                            let _ = event_tx
                                                .send(NetworkEvent::MessageSent { to_peer })
                                                .await;
                                        }
                                    }
                                }
                            }
                            request_response::Event::OutboundFailure { request_id, error, .. } => {
                                if let Some(to_peer) = pending_requests.remove(&request_id) {
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
                    _ => {}
                }
            }
        }
    }
}
