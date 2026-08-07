//! Minimal STUN binding client (RFC 5389) for embedded peer forwarders
//! (media forwarding step 3 phase 2).
//!
//! The VPS forwarder advertises its fixed public IP and never needs this. An
//! in-app peer forwarder sits behind the member's NAT: each leg discovers the
//! socket's public mapping with ONE binding request to the relay's STUN
//! server, and `leg.rs` advertises it beside the LAN host candidate. Client
//! legs stay zero-ICE-config (the iron rule from the D6 field test) — the
//! forwarder side carrying a reflexive candidate is what makes the pair
//! connect: the viewer's outbound checks to it punch the viewer's own NAT and
//! the forwarder replies to the peer-reflexive source.
//!
//! Deliberately tiny: binding request + XOR-MAPPED-ADDRESS parse, IPv4 only
//! (the D6 bug #2 lesson — IPv6-first resolution with no routable IPv6 is
//! exactly the failure mode we refuse to reintroduce). No dependency; the
//! whole exchange is ~30 bytes each way.

use std::net::SocketAddr;
use std::time::Duration;

use tokio::net::UdpSocket;

use crate::hollow_log;

const MAGIC_COOKIE: u32 = 0x2112_A442;
const BINDING_REQUEST: u16 = 0x0001;
const BINDING_SUCCESS: u16 = 0x0101;
const ATTR_MAPPED_ADDRESS: u16 = 0x0001;
const ATTR_XOR_MAPPED_ADDRESS: u16 = 0x0020;

/// Discover this socket's server-reflexive (NAT-mapped) address. Up to 3
/// attempts, 400 ms each — worst case ~1.2 s, typical one relay RTT. `None`
/// (no response / parse failure) is non-fatal: the leg advertises its host
/// candidate only, which still serves same-LAN viewers (including the peer
/// forwarder's own display leg).
pub(crate) async fn discover_mapped_addr(
    socket: &UdpSocket,
    stun: SocketAddr,
) -> Option<SocketAddr> {
    let mut txid = [0u8; 12];
    if getrandom::fill(&mut txid).is_err() {
        return None;
    }
    let mut req = Vec::with_capacity(20);
    req.extend_from_slice(&BINDING_REQUEST.to_be_bytes());
    req.extend_from_slice(&0u16.to_be_bytes()); // no attributes
    req.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
    req.extend_from_slice(&txid);

    let mut buf = [0u8; 256];
    for attempt in 0..3u8 {
        if socket.send_to(&req, stun).await.is_err() {
            return None;
        }
        loop {
            match tokio::time::timeout(Duration::from_millis(400), socket.recv_from(&mut buf))
                .await
            {
                Ok(Ok((n, source))) => {
                    // Anything not from the STUN server (or not our txn) is
                    // unexpected this early — keep waiting within the window.
                    if source != stun {
                        continue;
                    }
                    if let Some(addr) = parse_binding_response(&buf[..n], &txid) {
                        return Some(addr);
                    }
                    continue;
                }
                Ok(Err(e)) if e.kind() == std::io::ErrorKind::ConnectionReset => {
                    // Windows UDP quirk (same as the leg pump): a bounced
                    // datagram surfaces as WSAECONNRESET on the next recv.
                    continue;
                }
                _ => break, // timeout or hard recv error → next attempt
            }
        }
        if attempt == 2 {
            hollow_log!("[HOLLOW-FWD] STUN discovery got no response from {stun}");
        }
    }
    None
}

/// Parse a binding success response; returns the mapped IPv4 address.
fn parse_binding_response(msg: &[u8], txid: &[u8; 12]) -> Option<SocketAddr> {
    if msg.len() < 20 {
        return None;
    }
    let msg_type = u16::from_be_bytes([msg[0], msg[1]]);
    let msg_len = u16::from_be_bytes([msg[2], msg[3]]) as usize;
    let cookie = u32::from_be_bytes([msg[4], msg[5], msg[6], msg[7]]);
    if msg_type != BINDING_SUCCESS || cookie != MAGIC_COOKIE || &msg[8..20] != txid {
        return None;
    }
    let attrs = msg.get(20..20 + msg_len)?;
    let mut fallback: Option<SocketAddr> = None;
    let mut i = 0usize;
    while i + 4 <= attrs.len() {
        let attr_type = u16::from_be_bytes([attrs[i], attrs[i + 1]]);
        let attr_len = u16::from_be_bytes([attrs[i + 2], attrs[i + 3]]) as usize;
        let val = attrs.get(i + 4..i + 4 + attr_len)?;
        // Address attribute layout: 0x00, family, port(2), addr(4 for IPv4).
        if attr_len >= 8 && val[1] == 0x01 {
            let port = u16::from_be_bytes([val[2], val[3]]);
            let ip = [val[4], val[5], val[6], val[7]];
            match attr_type {
                ATTR_XOR_MAPPED_ADDRESS => {
                    let cookie = MAGIC_COOKIE.to_be_bytes();
                    let port = port ^ ((MAGIC_COOKIE >> 16) as u16);
                    let ip = std::net::Ipv4Addr::new(
                        ip[0] ^ cookie[0],
                        ip[1] ^ cookie[1],
                        ip[2] ^ cookie[2],
                        ip[3] ^ cookie[3],
                    );
                    return Some(SocketAddr::from((ip, port)));
                }
                ATTR_MAPPED_ADDRESS => {
                    fallback = Some(SocketAddr::from((
                        std::net::Ipv4Addr::new(ip[0], ip[1], ip[2], ip[3]),
                        port,
                    )));
                }
                _ => {}
            }
        }
        // Attributes are padded to 4-byte boundaries.
        i += 4 + attr_len.div_ceil(4) * 4;
    }
    fallback
}

#[cfg(test)]
mod tests {
    use super::*;

    fn response(txid: &[u8; 12], attrs: &[u8]) -> Vec<u8> {
        let mut msg = Vec::new();
        msg.extend_from_slice(&BINDING_SUCCESS.to_be_bytes());
        msg.extend_from_slice(&(attrs.len() as u16).to_be_bytes());
        msg.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
        msg.extend_from_slice(txid);
        msg.extend_from_slice(attrs);
        msg
    }

    #[test]
    fn parses_xor_mapped_address() {
        let txid = [7u8; 12];
        // XOR-MAPPED-ADDRESS for 203.0.113.9:50000.
        let port = 50000u16 ^ ((MAGIC_COOKIE >> 16) as u16);
        let cookie = MAGIC_COOKIE.to_be_bytes();
        let ip = [203 ^ cookie[0], 0 ^ cookie[1], 113 ^ cookie[2], 9 ^ cookie[3]];
        let mut attrs = Vec::new();
        attrs.extend_from_slice(&ATTR_XOR_MAPPED_ADDRESS.to_be_bytes());
        attrs.extend_from_slice(&8u16.to_be_bytes());
        attrs.extend_from_slice(&[0, 0x01]);
        attrs.extend_from_slice(&port.to_be_bytes());
        attrs.extend_from_slice(&ip);
        let msg = response(&txid, &attrs);
        assert_eq!(
            parse_binding_response(&msg, &txid),
            Some("203.0.113.9:50000".parse().unwrap())
        );
    }

    #[test]
    fn falls_back_to_plain_mapped_address() {
        let txid = [3u8; 12];
        let mut attrs = Vec::new();
        attrs.extend_from_slice(&ATTR_MAPPED_ADDRESS.to_be_bytes());
        attrs.extend_from_slice(&8u16.to_be_bytes());
        attrs.extend_from_slice(&[0, 0x01]);
        attrs.extend_from_slice(&51000u16.to_be_bytes());
        attrs.extend_from_slice(&[192, 0, 2, 44]);
        let msg = response(&txid, &attrs);
        assert_eq!(
            parse_binding_response(&msg, &txid),
            Some("192.0.2.44:51000".parse().unwrap())
        );
    }

    #[test]
    fn rejects_wrong_txid_and_short_messages() {
        let txid = [1u8; 12];
        let other = [2u8; 12];
        let msg = response(&txid, &[]);
        assert_eq!(parse_binding_response(&msg, &other), None);
        assert_eq!(parse_binding_response(&msg[..10], &txid), None);
    }
}
