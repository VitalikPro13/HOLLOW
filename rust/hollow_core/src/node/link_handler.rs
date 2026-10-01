//! Device linking: a device that already belongs to the identity (the presenter)
//! shows a code, a new device (the joiner) types it, and the presenter sends the
//! joiner a full snapshot of its database after the person approves the device.
//!
//! The code's rendezvous part brings both devices into `link:{rendezvous}`; its
//! secret part keys the channel of `link_pake`, so nothing the relay sees opens the
//! snapshot (HOL-SEC-002). The snapshot is the `export_backup` zip under a one-time
//! key that travels inside the channel, streamed as `StreamKind::LinkSnapshot` and
//! imported on the joiner's next launch, which installs the device key the joiner
//! minted for it: the presenter's vouch in that snapshot names exactly that device.

use std::collections::{HashMap, HashSet};

use base64::Engine;
use spake2::{Ed25519Group, Spake2};
use tokio::sync::mpsc;
use zeroize::Zeroizing;

use crate::hollow_log;
use crate::identity::native_identity::NativeKeypair;
use super::crypto_handler::send_message_to_peer_in_room;
use super::file_handler::LinkSnapshotState;
use super::link_pake::{self, Direction, LinkInner, LinkKeys};
use super::types::{HavenMessage, NetworkEvent};
use super::ws_client::WsCommand;
use super::ws_stream_transfer::{ws_stream_send_bytes, StreamKind};

const B64: base64::engine::GeneralPurpose = base64::engine::general_purpose::STANDARD;
/// The longest device name a confirm prompt shows.
const MAX_LABEL_BYTES: usize = 48;

/// The link in flight on this node, at most one per side. Owned by the event loop:
/// harness nodes share a process, so none of it may be a static.
#[derive(Default)]
pub(crate) struct LinkState {
    presenter: Option<Presenter>,
    joiner: Option<Joiner>,
}

/// What the joiner told us about itself.
struct Hello {
    device: String,
    label: String,
}

struct Presenter {
    rendezvous: String,
    secret: Zeroizing<String>,
    /// The one device the code answered. Nobody gets a second handshake.
    peer: Option<String>,
    keys: Option<LinkKeys>,
    hello: Option<Hello>,
}

struct Joiner {
    rendezvous: String,
    secret: Zeroizing<String>,
    presenter: Option<String>,
    spake: Option<Spake2<Ed25519Group>>,
    opening: Vec<u8>,
    keys: Option<LinkKeys>,
    /// The device key this install runs as once the snapshot is imported.
    device: NativeKeypair,
    label: String,
    platform: String,
}

/// Deterministic rendezvous room for a code's rendezvous part.
pub(crate) fn link_room(rendezvous: &str) -> String {
    format!("link:{}", rendezvous.to_uppercase())
}

/// A shown name, as the confirm prompt may print it.
fn clean_label(label: &str) -> String {
    let printable: String = label.chars().filter(|c| !c.is_control()).collect();
    super::crypto_handler::clip_bytes(printable.trim(), MAX_LABEL_BYTES).to_string()
}

/// (Presenter) Claim the code's rendezvous part on the relay and wait in its room.
pub(crate) fn claim(
    link: &mut LinkState,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    rendezvous: &str,
    secret: &str,
) {
    if !link_pake::is_part(rendezvous, link_pake::RENDEZVOUS_LEN) || !link_pake::is_part(secret, link_pake::SECRET_LEN) {
        hollow_log!("[HOLLOW-LINK] Refused to claim a malformed link code");
        return;
    }
    release(link, ws_cmd_tx);
    link.presenter = Some(Presenter {
        rendezvous: rendezvous.to_string(),
        secret: Zeroizing::new(secret.to_string()),
        peer: None,
        keys: None,
        hello: None,
    });
    let _ = ws_cmd_tx.send(WsCommand::ClaimLinkCode { code: rendezvous.to_string() });
    let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: link_room(rendezvous) });
    hollow_log!("[HOLLOW-LINK] Claimed a link code, waiting in its room");
}

/// (Presenter) Give the code and its room up: cancelled, failed or finished.
pub(crate) fn release(link: &mut LinkState, ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>) {
    if let Some(p) = link.presenter.take() {
        let _ = ws_cmd_tx.send(WsCommand::ReleaseLinkCode);
        let _ = ws_cmd_tx.send(WsCommand::LeaveRoom { room_code: link_room(&p.rendezvous) });
    }
}

/// (Joiner) Mint the device key this install will run as and ask the relay who
/// shows the code. Only the rendezvous part leaves this device.
pub(crate) fn resolve(
    link: &mut LinkState,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    code: &str,
    label: &str,
    platform: &str,
) -> Result<(), String> {
    let (rendezvous, secret) = link_pake::split_code(code)
        .ok_or_else(|| "That code is not complete. Check it and try again.".to_string())?;
    let mut seed = Zeroizing::new([0u8; 32]);
    getrandom::fill(&mut seed[..]).map_err(|e| format!("RNG failed: {e}"))?;
    if let Some(old) = link.joiner.take() {
        let _ = ws_cmd_tx.send(WsCommand::LeaveRoom { room_code: link_room(&old.rendezvous) });
    }
    let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: link_room(&rendezvous) });
    let _ = ws_cmd_tx.send(WsCommand::ResolveLinkCode { code: rendezvous.clone() });
    link.joiner = Some(Joiner {
        rendezvous,
        secret: Zeroizing::new(secret),
        presenter: None,
        spake: None,
        opening: Vec::new(),
        keys: None,
        device: NativeKeypair::from_secret_bytes(&seed),
        label: clean_label(label),
        platform: clean_label(platform),
    });
    hollow_log!("[HOLLOW-LINK] Resolving a link code");
    Ok(())
}

/// The relay could not resolve or claim `code`: a joiner waiting on it stops.
pub(crate) fn on_code_error(link: &mut LinkState, code: &str) {
    if link.joiner.as_ref().is_some_and(|j| j.rendezvous.eq_ignore_ascii_case(code)) {
        link.joiner = None;
    }
}

/// (Joiner) The relay named the device that shows the code: open the handshake.
pub(crate) fn on_resolved(
    link: &mut LinkState,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    code: &str,
    presenter: &str,
) {
    let Some(j) = link.joiner.as_mut().filter(|j| j.rendezvous.eq_ignore_ascii_case(code) && j.presenter.is_none()) else {
        return;
    };
    let (spake, opening) = link_pake::joiner_start(&j.rendezvous, &j.secret);
    j.spake = Some(spake);
    j.opening = opening.clone();
    j.presenter = Some(presenter.to_string());
    send_message_to_peer_in_room(
        ws_cmd_tx, &link_room(&j.rendezvous), presenter,
        HavenMessage::LinkPake { msg: B64.encode(opening) },
    );
    hollow_log!("[HOLLOW-LINK] Opened the link handshake with {presenter}");
}

async fn fail(event_tx: &mpsc::Sender<NetworkEvent>, error: &str) {
    let _ = event_tx
        .send(NetworkEvent::LinkFailed { link_id: String::new(), error: error.to_string() })
        .await;
}

/// (Presenter) A device in the code's room opened the handshake. The code answers
/// once: whoever comes second, the person's own device included, gets nothing.
pub(crate) async fn on_pake(
    link: &mut LinkState,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    sender: &str,
    msg: &str,
) {
    let Some(p) = link.presenter.as_mut() else { return };
    let room = link_room(&p.rendezvous);
    if p.peer.is_some() || !ws_room_peers.get(&room).is_some_and(|r| r.contains(sender)) {
        hollow_log!("[HOLLOW-SECURITY] Ignored a link handshake from {sender}: the code is used or it is not in the code's room");
        return;
    }
    p.peer = Some(sender.to_string());
    let answer = B64
        .decode(msg)
        .map_err(|_| "a malformed link handshake".to_string())
        .and_then(|opening| link_pake::presenter_answer(&p.rendezvous, &p.secret, &opening));
    match answer {
        Ok((keys, reply, confirm)) => {
            p.keys = Some(keys);
            send_message_to_peer_in_room(
                ws_cmd_tx, &room, sender,
                HavenMessage::LinkPakeReply { msg: B64.encode(reply), confirm: B64.encode(confirm) },
            );
        }
        Err(e) => {
            hollow_log!("[HOLLOW-LINK] Link handshake from {sender} failed: {e}");
            release(link, ws_cmd_tx);
            fail(event_tx, "The link failed. Show a new code and try again.").await;
        }
    }
}

/// (Joiner) The presenter answered: check that it holds the same secret, then say
/// which device we will be. A wrong code ends here, before anything is sealed.
pub(crate) async fn on_pake_reply(
    link: &mut LinkState,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender: &str,
    msg: &str,
    confirm: &str,
) {
    let Some(j) = link.joiner.as_mut().filter(|j| j.presenter.as_deref() == Some(sender)) else { return };
    let Some(spake) = j.spake.take() else { return };
    let keys = match (B64.decode(msg), B64.decode(confirm)) {
        (Ok(reply), Ok(confirm)) => link_pake::joiner_finish(spake, &j.rendezvous, &j.opening, &reply, &confirm),
        _ => Err("a malformed link handshake".to_string()),
    };
    let keys = match keys {
        Ok(k) => k,
        Err(e) => {
            hollow_log!("[HOLLOW-LINK] The link handshake with {sender} failed: {e}");
            if let Some(j) = link.joiner.take() {
                let _ = ws_cmd_tx.send(WsCommand::LeaveRoom { room_code: link_room(&j.rendezvous) });
            }
            fail(event_tx, "The code didn't match. Check it on your other device and try again.").await;
            return;
        }
    };
    let (msg_count, friend_count, _, has_profile) = crate::api::storage::snapshot_state_summary();
    let hello = LinkInner::Hello {
        device: j.device.peer_id(),
        label: j.label.clone(),
        platform: j.platform.clone(),
        msg_count,
        friend_count,
        has_profile,
    };
    match keys.seal(Direction::ToPresenter, &hello) {
        Ok(ct) => send_message_to_peer_in_room(
            ws_cmd_tx, &link_room(&j.rendezvous), sender, HavenMessage::LinkSealed { ct: B64.encode(ct) },
        ),
        Err(e) => hollow_log!("[HOLLOW-LINK] Could not seal our hello: {e}"),
    }
    j.keys = Some(keys);
}

/// A sealed link message from the other device: the joiner's hello, or the
/// presenter's offer. One that does not open under the handshake's keys ends the
/// link on the presenter's side and burns the code.
pub(crate) async fn on_sealed(
    link: &mut LinkState,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    pending_link_snapshots: &mut HashMap<String, LinkSnapshotState>,
    sender: &str,
    ct: &str,
) {
    let sealed = B64.decode(ct).unwrap_or_default();
    let from_our_joiner = link
        .presenter
        .as_ref()
        .is_some_and(|p| p.peer.as_deref() == Some(sender) && p.hello.is_none());
    if from_our_joiner {
        let opened = link
            .presenter
            .as_ref()
            .and_then(|p| p.keys.as_ref())
            .map(|k| k.open(Direction::ToPresenter, &sealed));
        let hello = match opened {
            Some(Ok(LinkInner::Hello { device, label, platform, msg_count, friend_count, has_profile }))
                if crate::crypto::safety_number::pubkey_from_peer_id(&device).is_some() =>
            {
                Some((device, clean_label(&label), clean_label(&platform), msg_count, friend_count, has_profile))
            }
            _ => None,
        };
        let Some((device, label, platform, msg_count, friend_count, has_profile)) = hello else {
            hollow_log!("[HOLLOW-SECURITY] A link hello from {sender} did not open: the code was wrong or guessed");
            release(link, ws_cmd_tx);
            fail(event_tx, "The code didn't match on the other device. Show a new code and try again.").await;
            return;
        };
        if let Some(p) = link.presenter.as_mut() {
            p.hello = Some(Hello { device, label: label.clone() });
        }
        hollow_log!("[HOLLOW-LINK] {sender} asks to be linked");
        let _ = event_tx
            .send(NetworkEvent::SiblingLinkAvailable {
                peer_id: sender.to_string(),
                their_msg_count: msg_count,
                their_friend_count: friend_count,
                their_has_profile: has_profile,
                label,
                platform,
            })
            .await;
        return;
    }
    let Some(j) = link.joiner.as_ref().filter(|j| j.presenter.as_deref() == Some(sender)) else {
        hollow_log!("[HOLLOW-SECURITY] Dropped a sealed link message from {sender}: no link of ours with it");
        return;
    };
    let Some(keys) = j.keys.as_ref() else { return };
    match keys.open(Direction::ToJoiner, &sealed) {
        Ok(LinkInner::Offer { link_id, key_hex }) if is_link_id(&link_id) && is_key_hex(&key_hex) => {
            let device = match j.device.to_protobuf_encoding() {
                Ok(d) => d,
                Err(e) => {
                    hollow_log!("[HOLLOW-LINK] Could not encode our new device key: {e}");
                    return;
                }
            };
            hollow_log!("[HOLLOW-LINK] Registered pending link snapshot {link_id}");
            pending_link_snapshots.insert(
                link_id,
                LinkSnapshotState { passphrase: Zeroizing::new(key_hex), sender: sender.to_string(), device: Zeroizing::new(device) },
            );
        }
        _ => {
            hollow_log!("[HOLLOW-SECURITY] A link offer from {sender} did not open");
            fail(event_tx, "The link failed. Try again with a new code.").await;
        }
    }
}

fn is_link_id(id: &str) -> bool {
    id.starts_with("link_") && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

fn is_key_hex(key: &str) -> bool {
    key.len() == 64 && key.chars().all(|c| c.is_ascii_hexdigit())
}

/// (Presenter) The person approved the device: vouch for the id it will run as,
/// then send the snapshot under a fresh key that travels inside the channel. The
/// snapshot already holds the vouch.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn accept(
    link: &mut LinkState,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    master_keypair: &NativeKeypair,
    device_keypair: &NativeKeypair,
    target_peer: &str,
    include_vault: bool,
    include_files: bool,
    db_path: &str,
    db_passphrase: &str,
) {
    let mut key = Zeroizing::new([0u8; 32]);
    let key_ok = getrandom::fill(&mut key[..]).is_ok();
    let key_hex = Zeroizing::new(hex::encode(&key[..]));
    let tail = |s: &str| s.char_indices().rev().nth(7).map_or(s, |(i, _)| &s[i..]).to_string();
    let link_id = format!("link_{}_{}", tail(&device_keypair.peer_id()), tail(target_peer));
    let offer = LinkInner::Offer { link_id: link_id.clone(), key_hex: key_hex.to_string() };
    let ready = link.presenter.as_ref().and_then(|p| {
        let (keys, hello) = (p.keys.as_ref()?, p.hello.as_ref()?);
        (p.peer.as_deref() == Some(target_peer) && key_ok).then(|| {
            (link_room(&p.rendezvous), hello.device.clone(), hello.label.clone(), keys.seal(Direction::ToJoiner, &offer))
        })
    });
    let Some((room, device, label, Ok(sealed))) = ready else {
        hollow_log!("[HOLLOW-SECURITY] Refused to send a snapshot to {target_peer}: no finished handshake with it");
        release(link, ws_cmd_tx);
        fail(event_tx, "The link expired. Show a new code and try again.").await;
        return;
    };

    if let Err(e) = super::roster_book::vouch(master_keypair, device_keypair, &device, db_path, db_passphrase) {
        hollow_log!("[HOLLOW-LINK] Could not add the new device: {e}");
        release(link, ws_cmd_tx);
        fail(event_tx, &e).await;
        return;
    }
    if !label.is_empty()
        && let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase)
    {
        let _ = store.set_device_label(&device, &label);
    }
    let blob = match crate::api::storage::export_backup_bytes(&key_hex, include_vault, include_files) {
        Ok(b) => b,
        Err(e) => {
            hollow_log!("[HOLLOW-LINK] Backup build failed: {e}");
            release(link, ws_cmd_tx);
            fail(event_tx, "Could not get your data ready to send. Show a new code and try again.").await;
            return;
        }
    };
    send_message_to_peer_in_room(ws_cmd_tx, &room, target_peer, HavenMessage::LinkSealed { ct: B64.encode(sealed) });
    hollow_log!("[HOLLOW-LINK] Pushing snapshot {link_id} ({} bytes) to {target_peer}", blob.len());
    ws_stream_send_bytes(ws_cmd_tx, &room, target_peer, &StreamKind::LinkSnapshot, &link_id, &blob).await;
    // The code is spent; the room stays until the joiner's ack arrives in it.
    let _ = ws_cmd_tx.send(WsCommand::ReleaseLinkCode);
}

/// (Presenter) The person refused the device.
pub(crate) fn decline(link: &mut LinkState, ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>, target_peer: &str) {
    if let Some(p) = link.presenter.as_ref().filter(|p| p.peer.as_deref() == Some(target_peer)) {
        send_message_to_peer_in_room(ws_cmd_tx, &link_room(&p.rendezvous), target_peer, HavenMessage::LinkDeclined);
    }
    release(link, ws_cmd_tx);
}

/// (Presenter) The joiner has the whole snapshot: the link is over.
pub(crate) fn on_ack(link: &mut LinkState, ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>, sender: &str) -> bool {
    let ours = link.presenter.as_ref().is_some_and(|p| p.peer.as_deref() == Some(sender));
    if ours {
        release(link, ws_cmd_tx);
    }
    ours
}

/// (Joiner) The presenter refused us.
pub(crate) fn on_declined(link: &mut LinkState, ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>, sender: &str) -> bool {
    let ours = link.joiner.as_ref().is_some_and(|j| j.presenter.as_deref() == Some(sender));
    if ours && let Some(j) = link.joiner.take() {
        let _ = ws_cmd_tx.send(WsCommand::LeaveRoom { room_code: link_room(&j.rendezvous) });
    }
    ours
}
