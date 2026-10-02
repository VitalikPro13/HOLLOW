//! Device-signed relay frames.
//!
//! The relay stamps `from` on everything it forwards, and a malicious relay can stamp
//! any id. So every peer payload travels sealed: the sending DEVICE signs the room, the
//! route, the time and a nonce over the body, and the receiver checks that signature
//! against the key inlined in `from` before anything reads the frame. A seal proves
//! which device sent a frame, never what that device may do: handlers still judge that.

use std::collections::HashMap;

use ed25519_dalek::{Signature, VerifyingKey};
use sha2::{Digest, Sha256};
use tokio::sync::mpsc::UnboundedSender;

use super::ws_client::WsCommand;
use crate::identity::native_identity::NativeKeypair;

/// Leads every sealed frame. A NUL can never start a JSON `HavenMessage`, so an
/// unsealed frame from an older client is told apart without parsing it.
pub(crate) const MAGIC: [u8; 4] = *b"\0HF1";

const DOMAIN: &[u8] = b"hollow-frame1\0";

/// The route of a frame fanned out to a whole room or topic.
pub(crate) const ROUTE_ROOM: &str = "*";

/// How far a live-only frame's clock may sit from ours, either way. Relay auth holds
/// every connected client within 60 s of the relay, so honest peers differ by two
/// minutes at most.
pub(crate) const LIVE_SKEW_MS: i64 = 300_000;

pub(crate) const NONCE_LEN: usize = 16;
const SIG_LEN: usize = 64;

/// More live frames than the per-sender rate limit admits in a replay window: an
/// honest sender never reaches it.
const MAX_SEEN_PER_SENDER: usize = 16_384;

/// How a frame reached us.
#[derive(Clone, Copy)]
pub(crate) enum Delivery<'a> {
    /// Fanned out to a room or topic (relay 0x05, 0x08).
    Room,
    /// Sent to this device (relay 0x06), or to its master's inbox.
    Direct { device: &'a str, master: &'a str },
}

/// A frame whose seal checked out.
#[derive(Debug)]
pub(crate) struct Opened<'a> {
    pub ts_ms: i64,
    pub nonce: [u8; NONCE_LEN],
    pub body: &'a [u8],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Refusal {
    /// No seal: a client older than 0.12, or not a Hollow frame at all.
    Unsealed,
    Malformed,
    /// `from` does not inline an Ed25519 key.
    NotAPeerId,
    BadSignature,
    /// Signed for another room or device, or for a room when it arrived direct.
    Misrouted,
    /// Stamped more than [`LIVE_SKEW_MS`] ahead of our clock.
    FromTheFuture,
}

pub(crate) fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn signed_bytes(room: &str, route: &[u8], ts_ms: i64, nonce: &[u8; NONCE_LEN], body: &[u8]) -> Vec<u8> {
    let mut msg = Vec::with_capacity(DOMAIN.len() + 8 + room.len() + route.len() + 8 + NONCE_LEN + 32);
    msg.extend_from_slice(DOMAIN);
    msg.extend_from_slice(&(room.len() as u32).to_be_bytes());
    msg.extend_from_slice(room.as_bytes());
    msg.extend_from_slice(&(route.len() as u32).to_be_bytes());
    msg.extend_from_slice(route);
    msg.extend_from_slice(&ts_ms.to_be_bytes());
    msg.extend_from_slice(nonce);
    msg.extend_from_slice(&Sha256::digest(body));
    msg
}

/// Seal `body` for `room`, addressed to `route` ([`ROUTE_ROOM`] or a device or master id).
pub(crate) fn seal(keypair: &NativeKeypair, room: &str, route: &str, body: &[u8]) -> Vec<u8> {
    let mut nonce = [0u8; NONCE_LEN];
    if getrandom::fill(&mut nonce).is_err() {
        // A repeated nonce only makes the receiver's replay guard drop a live frame.
        use std::sync::atomic::{AtomicU64, Ordering};
        static FALLBACK: AtomicU64 = AtomicU64::new(0);
        nonce[..8].copy_from_slice(&FALLBACK.fetch_add(1, Ordering::Relaxed).to_be_bytes());
        nonce[8..].copy_from_slice(&now_ms().to_be_bytes());
    }
    seal_at(keypair, room, route, now_ms(), nonce, body)
}

pub(crate) fn seal_at(
    keypair: &NativeKeypair,
    room: &str,
    route: &str,
    ts_ms: i64,
    nonce: [u8; NONCE_LEN],
    body: &[u8],
) -> Vec<u8> {
    // Peer ids fit a byte of length; anything longer is cut, and cut identically in
    // what is signed, so it simply never matches a real device.
    let route = &route.as_bytes()[..route.len().min(u8::MAX as usize)];
    let sig = keypair.sign(&signed_bytes(room, route, ts_ms, &nonce, body));
    let mut frame = Vec::with_capacity(MAGIC.len() + 8 + NONCE_LEN + 1 + route.len() + SIG_LEN + body.len());
    frame.extend_from_slice(&MAGIC);
    frame.extend_from_slice(&ts_ms.to_be_bytes());
    frame.extend_from_slice(&nonce);
    frame.push(route.len() as u8);
    frame.extend_from_slice(route);
    frame.extend_from_slice(&sig);
    frame.extend_from_slice(body);
    frame
}

/// Check a frame's seal against the relay's `from` and `room` and how it arrived.
pub(crate) fn open<'a>(
    frame: &'a [u8],
    from: &str,
    room: &str,
    delivery: Delivery<'_>,
    now_ms: i64,
) -> Result<Opened<'a>, Refusal> {
    let Some(rest) = frame.strip_prefix(&MAGIC[..]) else {
        return Err(Refusal::Unsealed);
    };
    let (ts, rest) = split(rest, 8)?;
    let ts_ms = i64::from_be_bytes(ts.try_into().map_err(|_| Refusal::Malformed)?);
    let (nonce, rest) = split(rest, NONCE_LEN)?;
    let nonce: [u8; NONCE_LEN] = nonce.try_into().map_err(|_| Refusal::Malformed)?;
    let (route_len, rest) = split(rest, 1)?;
    let (route, rest) = split(rest, route_len[0] as usize)?;
    let route = std::str::from_utf8(route).map_err(|_| Refusal::Malformed)?;
    let (sig, body) = split(rest, SIG_LEN)?;

    let routed_here = match delivery {
        Delivery::Room => route == ROUTE_ROOM,
        Delivery::Direct { device, master } => route == device || route == master,
    };
    if !routed_here {
        return Err(Refusal::Misrouted);
    }

    let key = crate::crypto::safety_number::pubkey_from_peer_id(from)
        .and_then(|k| VerifyingKey::from_bytes(&k).ok())
        .ok_or(Refusal::NotAPeerId)?;
    let sig = Signature::from_slice(sig).map_err(|_| Refusal::Malformed)?;
    key.verify_strict(&signed_bytes(room, route.as_bytes(), ts_ms, &nonce, body), &sig)
        .map_err(|_| Refusal::BadSignature)?;

    if ts_ms > now_ms + LIVE_SKEW_MS {
        return Err(Refusal::FromTheFuture);
    }
    Ok(Opened { ts_ms, nonce, body })
}

fn split(bytes: &[u8], n: usize) -> Result<(&[u8], &[u8]), Refusal> {
    if bytes.len() < n {
        return Err(Refusal::Malformed);
    }
    Ok(bytes.split_at(n))
}

/// Seal the payload of one relay command, addressed as the relay will deliver it.
pub(crate) fn seal_command(keypair: &NativeKeypair, cmd: WsCommand) -> WsCommand {
    match cmd {
        WsCommand::SendToRoom { room_code, data } => {
            let data = seal(keypair, &room_code, ROUTE_ROOM, &data);
            WsCommand::SendToRoom { room_code, data }
        }
        WsCommand::SendPublic { room_code, data } => {
            let data = seal(keypair, &room_code, ROUTE_ROOM, &data);
            WsCommand::SendPublic { room_code, data }
        }
        WsCommand::SendToRoomTopic { room_code, topic, data } => {
            let data = seal(keypair, &room_code, ROUTE_ROOM, &data);
            WsCommand::SendToRoomTopic { room_code, topic, data }
        }
        WsCommand::SendDirect { room_code, target_peer, data } => {
            let data = seal(keypair, &room_code, &target_peer, &data);
            WsCommand::SendDirect { room_code, target_peer, data }
        }
        WsCommand::SendDirectImage { room_code, target_peer, data } => {
            let data = seal(keypair, &room_code, &target_peer, &data);
            WsCommand::SendDirectImage { room_code, target_peer, data }
        }
        WsCommand::SendBinaryDirect { room_code, target_peer, data } => {
            let data = seal(keypair, &room_code, &target_peer, &data);
            WsCommand::SendBinaryDirect { room_code, target_peer, data }
        }
        // Empty = a push trigger only, which the relay buffers nothing for.
        WsCommand::SendChannelDirect { room_code, target_peer, channel_id, mention, data } if !data.is_empty() => {
            let data = seal(keypair, &room_code, &target_peer, &data);
            WsCommand::SendChannelDirect { room_code, target_peer, channel_id, mention, data }
        }
        other => other,
    }
}

/// A [`WsCommand::Carry`] on its way to the node, and where the node answers with
/// the frames it became.
pub(crate) type CarryRequest = (WsCommand, tokio::sync::oneshot::Sender<Vec<WsCommand>>);

/// Put a sealing stage in front of the relay: whoever holds the returned sender can
/// only send sealed frames, so the node hands it to everything that sends. A
/// [`WsCommand::Carry`] comes back out of the returned receiver for the node to put
/// inside Olm, and nothing queued after it leaves before the frames it became: wire
/// order stays program order, so a plaintext frame never overtakes the carried state
/// it depends on.
pub(crate) fn spawn_sealer(
    keypair: NativeKeypair,
    relay: UnboundedSender<WsCommand>,
) -> (UnboundedSender<WsCommand>, tokio::sync::mpsc::UnboundedReceiver<CarryRequest>) {
    const CARRY_WAIT: std::time::Duration = std::time::Duration::from_secs(10);
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let (carry_tx, carry_rx) = tokio::sync::mpsc::unbounded_channel::<CarryRequest>();
    tokio::spawn(async move {
        while let Some(cmd) = rx.recv().await {
            let out = match cmd {
                WsCommand::Carry { .. } => {
                    let (done_tx, done_rx) = tokio::sync::oneshot::channel();
                    if carry_tx.send((cmd, done_tx)).is_err() {
                        break;
                    }
                    match tokio::time::timeout(CARRY_WAIT, done_rx).await {
                        Ok(Ok(frames)) => frames,
                        _ => {
                            hollow_log!("[HOLLOW-SECURITY] A carried frame was not encrypted in time and was dropped");
                            Vec::new()
                        }
                    }
                }
                cmd => vec![cmd],
            };
            if out.into_iter().any(|cmd| relay.send(seal_command(&keypair, cmd)).is_err()) {
                break;
            }
        }
    });
    (tx, carry_rx)
}

/// The body of a sealed frame, unchecked. For code that reads frames it already
/// trusts (its own sends in tests, recorded wire traffic), never for inbound ones.
#[cfg(test)]
pub(crate) fn unchecked_body(frame: &[u8]) -> &[u8] {
    let Some(rest) = frame.strip_prefix(&MAGIC[..]) else { return frame };
    let skip = 8 + NONCE_LEN;
    let Some(&route_len) = rest.get(skip) else { return frame };
    rest.get(skip + 1 + route_len as usize + SIG_LEN..).unwrap_or(frame)
}

/// Refuses a repeated live-only frame inside the window its clock stamp is still
/// accepted in, so a relay cannot replay one.
#[derive(Default)]
pub(crate) struct ReplayGuard {
    seen: HashMap<String, HashMap<[u8; NONCE_LEN], i64>>,
}

impl ReplayGuard {
    /// Whether this is the first time `sender` shows us `nonce`. A frame this old or
    /// older must already have been refused as stale.
    pub(crate) fn first_sight(&mut self, sender: &str, nonce: [u8; NONCE_LEN], ts_ms: i64, now_ms: i64) -> bool {
        let seen = self.seen.entry(sender.to_string()).or_default();
        if seen.len() >= MAX_SEEN_PER_SENDER {
            seen.retain(|_, expires| *expires > now_ms);
            if seen.len() >= MAX_SEEN_PER_SENDER {
                return false;
            }
        }
        seen.insert(nonce, ts_ms + LIVE_SKEW_MS).is_none()
    }

    /// Forget nonces whose frames would now be refused as stale anyway.
    pub(crate) fn prune(&mut self, now_ms: i64) {
        self.seen.retain(|_, seen| {
            seen.retain(|_, expires| *expires > now_ms);
            !seen.is_empty()
        });
    }
}

/// Whether a live-only frame stamped `ts_ms` is too old to act on.
pub(crate) fn is_stale(ts_ms: i64, now_ms: i64) -> bool {
    now_ms - ts_ms > LIVE_SKEW_MS
}

/// The latest stamp an honest sender can have put on a row it sent at `sent_ms`: a
/// later one would outrank every write that follows it.
pub(crate) fn stamp_ceiling(sent_ms: i64) -> i64 {
    sent_ms.saturating_add(LIVE_SKEW_MS)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keypair(tag: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[tag; 32])
    }

    const ROOM: &str = "0123456789abcdef0123456789abcdef";
    const NOW: i64 = 1_790_000_000_000;

    fn sealed(kp: &NativeKeypair, route: &str, body: &[u8]) -> Vec<u8> {
        seal_at(kp, ROOM, route, NOW, [7; NONCE_LEN], body)
    }

    #[test]
    fn a_sealed_frame_opens_for_its_sender_room_and_route() {
        let alice = keypair(1);
        let frame = sealed(&alice, ROUTE_ROOM, br#"{"type":"ack"}"#);
        let opened = open(&frame, &alice.peer_id(), ROOM, Delivery::Room, NOW).unwrap();
        assert_eq!(opened.body, br#"{"type":"ack"}"#);
        assert_eq!(opened.ts_ms, NOW);

        let bob = keypair(2);
        let direct = sealed(&alice, &bob.peer_id(), b"x");
        let to_bob = Delivery::Direct { device: &bob.peer_id(), master: "master" };
        assert!(open(&direct, &alice.peer_id(), ROOM, to_bob, NOW).is_ok());
        let to_bobs_inbox = sealed(&alice, "master", b"x");
        assert!(open(&to_bobs_inbox, &alice.peer_id(), ROOM, to_bob, NOW).is_ok());
    }

    #[test]
    fn a_frame_stamped_with_another_devices_id_is_refused() {
        let (alice, mallory) = (keypair(1), keypair(3));
        let frame = sealed(&mallory, ROUTE_ROOM, b"x");
        assert_eq!(open(&frame, &alice.peer_id(), ROOM, Delivery::Room, NOW).unwrap_err(), Refusal::BadSignature);
        assert_eq!(open(&frame, "not-a-peer-id", ROOM, Delivery::Room, NOW).unwrap_err(), Refusal::NotAPeerId);
    }

    #[test]
    fn a_frame_moved_to_another_room_device_or_delivery_is_refused() {
        let (alice, bob, carol) = (keypair(1), keypair(2), keypair(4));
        let from = alice.peer_id();

        let broadcast = sealed(&alice, ROUTE_ROOM, b"x");
        let other_room = "fedcba9876543210fedcba9876543210";
        assert_eq!(open(&broadcast, &from, other_room, Delivery::Room, NOW).unwrap_err(), Refusal::BadSignature);
        let to_bob = Delivery::Direct { device: &bob.peer_id(), master: "bob-master" };
        assert_eq!(open(&broadcast, &from, ROOM, to_bob, NOW).unwrap_err(), Refusal::Misrouted);

        let for_bob = sealed(&alice, &bob.peer_id(), b"x");
        let to_carol = Delivery::Direct { device: &carol.peer_id(), master: "carol-master" };
        assert_eq!(open(&for_bob, &from, ROOM, to_carol, NOW).unwrap_err(), Refusal::Misrouted);
        assert_eq!(open(&for_bob, &from, ROOM, Delivery::Room, NOW).unwrap_err(), Refusal::Misrouted);
    }

    #[test]
    fn any_change_to_a_sealed_frame_breaks_it() {
        let alice = keypair(1);
        let frame = sealed(&alice, ROUTE_ROOM, br#"{"type":"member_kick_broadcast"}"#);
        for i in MAGIC.len()..frame.len() {
            let mut tampered = frame.clone();
            tampered[i] ^= 0x01;
            assert!(
                open(&tampered, &alice.peer_id(), ROOM, Delivery::Room, NOW).is_err(),
                "byte {i} changed and the frame still opened"
            );
        }
        assert!(open(&frame[..frame.len() - 1], &alice.peer_id(), ROOM, Delivery::Room, NOW).is_err());
    }

    #[test]
    fn unsealed_future_and_truncated_frames_are_refused() {
        let alice = keypair(1);
        let from = alice.peer_id();
        assert_eq!(open(br#"{"type":"ack"}"#, &from, ROOM, Delivery::Room, NOW).unwrap_err(), Refusal::Unsealed);

        let ahead = seal_at(&alice, ROOM, ROUTE_ROOM, NOW + LIVE_SKEW_MS + 1, [7; NONCE_LEN], b"x");
        assert_eq!(open(&ahead, &from, ROOM, Delivery::Room, NOW).unwrap_err(), Refusal::FromTheFuture);
        let at_edge = seal_at(&alice, ROOM, ROUTE_ROOM, NOW + LIVE_SKEW_MS, [7; NONCE_LEN], b"x");
        assert!(open(&at_edge, &from, ROOM, Delivery::Room, NOW).is_ok());

        let frame = sealed(&alice, ROUTE_ROOM, b"");
        for len in MAGIC.len()..frame.len() {
            assert!(open(&frame[..len], &from, ROOM, Delivery::Room, NOW).is_err());
        }
    }

    #[test]
    fn a_live_frame_is_taken_once_per_nonce_while_fresh() {
        let mut guard = ReplayGuard::default();
        assert!(guard.first_sight("alice", [1; NONCE_LEN], NOW, NOW));
        assert!(!guard.first_sight("alice", [1; NONCE_LEN], NOW, NOW + 1_000));
        assert!(guard.first_sight("bob", [1; NONCE_LEN], NOW, NOW));
        assert!(guard.first_sight("alice", [2; NONCE_LEN], NOW, NOW));

        assert!(!is_stale(NOW, NOW + LIVE_SKEW_MS));
        assert!(is_stale(NOW, NOW + LIVE_SKEW_MS + 1));
        guard.prune(NOW + LIVE_SKEW_MS + 1);
        assert!(guard.seen.is_empty());
    }

    #[test]
    fn every_payload_command_leaves_sealed_for_the_way_it_is_delivered() {
        let (alice, bob) = (keypair(1), keypair(2));
        let (from, bob_id) = (alice.peer_id(), bob.peer_id());
        let to_bob = Delivery::Direct { device: &bob_id, master: "bob-master" };
        let body = b"payload".to_vec();
        let opens = |data: &[u8], delivery| open(data, &from, ROOM, delivery, now_ms()).map(|o| o.body.to_vec());

        let room = seal_command(&alice, WsCommand::SendToRoom { room_code: ROOM.into(), data: body.clone() });
        let WsCommand::SendToRoom { data, .. } = room else { panic!() };
        assert_eq!(opens(&data, Delivery::Room).unwrap(), body);

        let topic = WsCommand::SendToRoomTopic { room_code: ROOM.into(), topic: "c".into(), data: body.clone() };
        let WsCommand::SendToRoomTopic { data, .. } = seal_command(&alice, topic) else { panic!() };
        assert_eq!(opens(&data, Delivery::Room).unwrap(), body);

        for cmd in [
            WsCommand::SendDirect { room_code: ROOM.into(), target_peer: bob_id.clone(), data: body.clone() },
            WsCommand::SendDirectImage { room_code: ROOM.into(), target_peer: bob_id.clone(), data: body.clone() },
            WsCommand::SendChannelDirect {
                room_code: ROOM.into(), target_peer: bob_id.clone(), channel_id: "c".into(), mention: false, data: body.clone(),
            },
        ] {
            let data = match seal_command(&alice, cmd) {
                WsCommand::SendDirect { data, .. }
                | WsCommand::SendDirectImage { data, .. }
                | WsCommand::SendChannelDirect { data, .. } => data,
                _ => panic!(),
            };
            assert_eq!(opens(&data, to_bob).unwrap(), body);
            assert_eq!(opens(&data, Delivery::Room).unwrap_err(), Refusal::Misrouted);
        }

        let trigger = WsCommand::SendChannelDirect {
            room_code: ROOM.into(), target_peer: bob_id, channel_id: "c".into(), mention: true, data: vec![],
        };
        let WsCommand::SendChannelDirect { data, .. } = seal_command(&alice, trigger) else { panic!() };
        assert!(data.is_empty());
    }

    #[test]
    fn unchecked_body_strips_a_seal_and_passes_anything_else_through() {
        let alice = keypair(1);
        assert_eq!(unchecked_body(&sealed(&alice, "some-device", b"body")), b"body");
        assert_eq!(unchecked_body(b"{}"), b"{}");
    }
}
