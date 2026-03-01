use std::time::Duration;

use libp2p::futures::StreamExt;
use libp2p::{identify, identity, kad, noise, ping, relay, swarm::SwarmEvent, tcp, tls, yamux, Multiaddr, SwarmBuilder};

use crate::config::Config;

/// Our relay server network behaviour.
#[derive(libp2p::swarm::NetworkBehaviour)]
struct RelayServerBehaviour {
    relay: relay::Behaviour,
    kademlia: kad::Behaviour<kad::store::MemoryStore>,
    identify: identify::Behaviour,
    ping: ping::Behaviour,
}

/// Run the libp2p relay node. This future runs forever until the process exits.
pub async fn run_relay_node(
    keypair: identity::Keypair,
    config: &Config,
) -> Result<(), Box<dyn std::error::Error>> {
    let local_peer_id = keypair.public().to_peer_id();

    let mut swarm = SwarmBuilder::with_existing_identity(keypair.clone())
        .with_tokio()
        .with_tcp(
            tcp::Config::default(),
            noise::Config::new,
            yamux::Config::default,
        )?
        .with_quic()
        .with_dns()?
        .with_websocket(
            (tls::Config::new, noise::Config::new),
            yamux::Config::default,
        )
        .await?
        .with_behaviour(|key| {
            let peer_id = key.public().to_peer_id();

            // Relay server behaviour — accepts reservation requests and relays traffic.
            // Defaults are designed for short-lived hole-punch coordination (2 min circuits,
            // 128 KiB data cap, 16 total circuits). Haven uses the relay as a persistent
            // fallback transport, so we need much more generous limits.
            let mut relay_config = relay::Config::default();
            relay_config.max_reservations = 1024;
            relay_config.max_reservations_per_peer = 8;
            relay_config.max_circuits = 512;
            relay_config.max_circuits_per_peer = 32;
            relay_config.max_circuit_duration = Duration::from_secs(3600); // 1 hour
            relay_config.max_circuit_bytes = 0; // unlimited (E2EE traffic, small messages)
            relay_config.reservation_duration = Duration::from_secs(7200); // 2 hours
            let relay = relay::Behaviour::new(peer_id, relay_config);

            // Kademlia DHT — acts as a stable bootstrap node.
            let mut kademlia = kad::Behaviour::new(
                peer_id,
                kad::store::MemoryStore::new(peer_id),
            );
            kademlia.set_mode(Some(kad::Mode::Server));

            // Identify — required for relay protocol to exchange peer info.
            let identify = identify::Behaviour::new(identify::Config::new(
                "/haven/relay/1.0.0".to_string(),
                key.public(),
            ));

            let ping = ping::Behaviour::default();

            Ok(RelayServerBehaviour {
                relay,
                kademlia,
                identify,
                ping,
            })
        })?
        .with_swarm_config(|cfg| {
            cfg.with_idle_connection_timeout(Duration::from_secs(1800)) // 30 min
        })
        .build();

    // Listen on fixed TCP port.
    let tcp_addr: Multiaddr = format!("/ip4/0.0.0.0/tcp/{}", config.libp2p_port)
        .parse()
        .unwrap();
    swarm.listen_on(tcp_addr)?;

    // Listen on fixed QUIC port (same port number, different protocol).
    let quic_addr: Multiaddr = format!("/ip4/0.0.0.0/udp/{}/quic-v1", config.libp2p_port)
        .parse()
        .unwrap();
    swarm.listen_on(quic_addr)?;

    // Listen on plain WebSocket port (Nginx terminates TLS on 443, proxies to this).
    // libp2p's with_websocket() doesn't support TLS server mode, so we use a reverse proxy.
    let ws_addr: Multiaddr = format!("/ip4/127.0.0.1/tcp/{}/ws", config.ws_port)
        .parse()
        .unwrap();
    match swarm.listen_on(ws_addr) {
        Ok(_) => tracing::info!("WebSocket listener started on 127.0.0.1:{}", config.ws_port),
        Err(e) => tracing::warn!("Failed to start WebSocket listener (port {}): {e:?}", config.ws_port),
    }

    // Advertise our public IP so relay reservations include routable addresses.
    let pub_tcp: Multiaddr = format!("/ip4/{}/tcp/{}", config.public_ip, config.libp2p_port)
        .parse()
        .unwrap();
    let pub_quic: Multiaddr = format!("/ip4/{}/udp/{}/quic-v1", config.public_ip, config.libp2p_port)
        .parse()
        .unwrap();
    let pub_wss: Multiaddr = format!("/dns4/{}/tcp/443/tls/ws", config.domain)
        .parse()
        .unwrap();
    swarm.add_external_address(pub_tcp.clone());
    swarm.add_external_address(pub_quic.clone());
    swarm.add_external_address(pub_wss.clone());
    tracing::info!("External addresses:");
    tracing::info!("  TCP:  {pub_tcp}/p2p/{local_peer_id}");
    tracing::info!("  QUIC: {pub_quic}/p2p/{local_peer_id}");
    tracing::info!("  WSS:  {pub_wss}/p2p/{local_peer_id}");

    tracing::info!("Relay node started. PeerId: {local_peer_id}");

    // Main event loop.
    loop {
        let event = swarm.select_next_some().await;
        match event {
            SwarmEvent::NewListenAddr { address, .. } => {
                tracing::info!("Listening on {address}/p2p/{local_peer_id}");
            }

            // -- Relay events --
            SwarmEvent::Behaviour(RelayServerBehaviourEvent::Relay(
                relay::Event::ReservationReqAccepted { src_peer_id, renewed },
            )) => {
                if renewed {
                    tracing::debug!("Relay reservation renewed by {src_peer_id}");
                } else {
                    tracing::info!("Relay reservation accepted from {src_peer_id}");
                }
            }
            SwarmEvent::Behaviour(RelayServerBehaviourEvent::Relay(
                relay::Event::CircuitReqAccepted { src_peer_id, dst_peer_id, .. },
            )) => {
                tracing::info!("Relay circuit: {src_peer_id} -> {dst_peer_id}");
            }
            SwarmEvent::Behaviour(RelayServerBehaviourEvent::Relay(
                relay::Event::CircuitClosed { src_peer_id, dst_peer_id, .. },
            )) => {
                tracing::debug!("Relay circuit closed: {src_peer_id} -> {dst_peer_id}");
            }
            SwarmEvent::Behaviour(RelayServerBehaviourEvent::Relay(event)) => {
                tracing::debug!("Relay event: {event:?}");
            }

            // -- Kademlia events --
            SwarmEvent::Behaviour(RelayServerBehaviourEvent::Kademlia(
                kad::Event::RoutingUpdated { peer, .. },
            )) => {
                tracing::debug!("Kademlia routing updated: {peer}");
            }
            SwarmEvent::Behaviour(RelayServerBehaviourEvent::Kademlia(_)) => {}

            // -- Identify events --
            SwarmEvent::Behaviour(RelayServerBehaviourEvent::Identify(
                identify::Event::Received { peer_id, info, .. },
            )) => {
                tracing::debug!(
                    "Identified peer {peer_id}: {} ({})",
                    info.protocol_version,
                    info.agent_version
                );
                // Add identified peer's addresses to Kademlia.
                for addr in info.listen_addrs {
                    swarm
                        .behaviour_mut()
                        .kademlia
                        .add_address(&peer_id, addr);
                }
            }
            SwarmEvent::Behaviour(RelayServerBehaviourEvent::Identify(_)) => {}

            // -- Ping events --
            SwarmEvent::Behaviour(RelayServerBehaviourEvent::Ping(_)) => {}

            // -- Connection events --
            SwarmEvent::ConnectionEstablished { peer_id, .. } => {
                tracing::debug!("Connection established with {peer_id}");
            }
            SwarmEvent::ConnectionClosed { peer_id, .. } => {
                tracing::debug!("Connection closed with {peer_id}");
            }

            _ => {}
        }
    }
}
