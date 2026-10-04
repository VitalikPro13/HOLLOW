//! Conferences: Zoom-style ad-hoc rooms with an MLS-gated waiting room.
//! Design doc: `reports/shipped/voice-and-media/CONFERENCES_PLAN.md`.
//!
//! A conference is a "virtual server": its id `conf:{conf_id}` is at once the
//! relay WS room code, the MLS group key and the `server_id` fed to the existing
//! voice-channel machinery (the channel is always [`CONF_CHANNEL`]).
//! `server_states` never contains a `conf:` id, so every CRDT-coupled path skips
//! naturally.
//!
//! **Admission IS the cryptography:** the waiting room gates an MLS `add`, so
//! until the host commits it a joiner sitting in the WS room holds only
//! ciphertext, and kick or deny never needs UI enforcement. Each `Start meeting`
//! mints a FRESH group, so past attendees cannot decrypt the next one. Live-only:
//! nothing rides topic rings or the offline buffer, and chat is never persisted.
//!
//! **The id names its host** (design A-D3): it hashes from the host's master and a
//! founding nonce, so every host frame and the admitting Welcome prove their host and
//! nobody else in the room can run the lobby. A knock proves the access code for the
//! knocking device only, so it is worth nothing to anyone who sees it.
//!
//! **The link carries a key** (`key=`, like a server invite): the knock and every host
//! frame ride the meeting lane sealed under it, since they hold names, avatar hashes,
//! KeyPackages and the host's master. The relay sees a room and the devices in it.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use base64::Engine;
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;

use crate::crypto::{CryptoStore, LeafView, MlsManager};

use super::crypto_handler::{broadcast_mls_commit, persist_mls_state};
use super::mls_authority::refused;
use super::types::{ConfHost, HavenMessage, Lane, NetworkEvent};
use super::ws_client::WsCommand;

/// Virtual server-id / WS room-code / MLS group-key prefix.
pub(crate) const CONF_SID_PREFIX: &str = "conf:";

/// The single synthetic channel id conferences feed the VC machinery.
pub(crate) const CONF_CHANNEL: &str = "main";

pub(crate) fn conf_server_id(conf_id: &str) -> String {
    format!("{CONF_SID_PREFIX}{conf_id}")
}

pub(crate) fn is_conference_sid(sid: &str) -> bool {
    sid.starts_with(CONF_SID_PREFIX)
}

pub(crate) fn conf_id_from_sid(sid: &str) -> Option<&str> {
    sid.strip_prefix(CONF_SID_PREFIX)
}

/// Hex length of a meeting id that names its host.
const PINNED_CONF_ID_LEN: usize = 40;

/// The id a meeting its host founds with `nonce` must carry, the same shape as a
/// self-certifying server id (`crdt::anchor`).
pub(crate) fn derive_conf_id(host_master: &str, nonce: &str) -> String {
    let digest = Sha256::digest(format!("hollow-conf1:{host_master}:{nonce}").as_bytes());
    hex::encode(digest)[..PINNED_CONF_ID_LEN].to_string()
}

/// Whether `conf_id` names its host. Rooms made before 0.12 have 32 random hex
/// characters, which prove nobody, and are neither hosted nor joined.
pub(crate) fn is_pinned_conf_id(conf_id: &str) -> bool {
    conf_id.len() == PINNED_CONF_ID_LEN
        && conf_id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// A fresh founding nonce (16 random bytes, hex).
pub(crate) fn new_conf_nonce() -> Result<String, String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|e| format!("RNG error: {e}"))?;
    Ok(hex::encode(bytes))
}

/// The host master a host frame proves, `None` when it proves nothing: the meeting
/// id must hash from the named master and nonce, the certificate must bind the
/// device that sealed the frame to that master, and the master's roster, where we
/// hold it, must count that device (the master key alone certifies anything).
pub(crate) fn verified_host(conf_id: &str, sender_device: &str, host: &ConfHost) -> Option<String> {
    if !hosts_meeting(conf_id, &host.master, Some(&host.nonce)) {
        return None;
    }
    let identity = crate::crypto::certified_device(&host.cert)?;
    (identity.device == sender_device && identity.master == host.master && !refused(&identity))
        .then(|| host.master.clone())
}

/// Whether `device` holds a seat among a meeting group's `leaves`: a leaf bound to it
/// that its master's roster does not refuse.
pub(crate) fn seated(leaves: &[LeafView], device: &str) -> bool {
    leaves.iter().filter_map(LeafView::bound).any(|leaf| leaf.device == device && !refused(leaf))
}

/// Whether `master` founded the meeting `conf_id` with `nonce`.
pub(crate) fn hosts_meeting(conf_id: &str, master: &str, nonce: Option<&str>) -> bool {
    nonce.is_some_and(|n| is_pinned_conf_id(conf_id) && derive_conf_id(master, n) == conf_id)
}

/// The key a room's access code stands for, hex. Argon2id, salted with the meeting id,
/// so a knock seen on the wire costs a slow guess per candidate code. The host stores
/// it; the code itself never travels.
pub(crate) fn derive_code_key(conf_id: &str, code: &str) -> Result<String, String> {
    let params = argon2::Params::new(19 * 1024, 2, 1, Some(32))
        .map_err(|e| format!("argon2 params: {e}"))?;
    let argon = argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params);
    let mut key = [0u8; 32];
    argon
        .hash_password_into(code.as_bytes(), format!("hollow-conf-code1:{conf_id}").as_bytes(), &mut key)
        .map_err(|e| format!("argon2: {e}"))?;
    Ok(hex::encode(key))
}

fn knock_mac(code_key: &str, conf_id: &str, device: &str) -> Option<hmac::Hmac<Sha256>> {
    use hmac::Mac;
    let key = hex::decode(code_key).ok()?;
    let mut mac = hmac::Hmac::<Sha256>::new_from_slice(&key).ok()?;
    mac.update(b"hollow-knock1\0");
    for field in [conf_id, device] {
        mac.update(&(field.len() as u32).to_be_bytes());
        mac.update(field.as_bytes());
    }
    Some(mac)
}

/// A knock's proof of the access code, bound to the knocking device: the relay or a
/// room member who sees it cannot knock with it as anyone else.
pub(crate) fn knock_proof(code_key: &str, conf_id: &str, device: &str) -> String {
    use hmac::Mac;
    knock_mac(code_key, conf_id, device)
        .map(|mac| hex::encode(mac.finalize().into_bytes()))
        .unwrap_or_default()
}

/// Whether `proof` shows `device` holds the code behind `code_key` (constant time).
pub(crate) fn knock_proof_holds(code_key: &str, conf_id: &str, device: &str, proof: &str) -> bool {
    use hmac::Mac;
    match (knock_mac(code_key, conf_id, device), hex::decode(proof)) {
        (Some(mac), Ok(proof)) => mac.verify_slice(&proof).is_ok(),
        _ => false,
    }
}

// ── The meeting lane ─────────────────────────────────────────────────

const MEETING_DOMAIN: &[u8] = b"hollow-meeting1";

/// A fresh meeting link key: 32 random bytes as unpadded URL-safe base64, the shape
/// of a server invite's `key=`.
pub(crate) fn new_link_key() -> Result<String, String> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|e| format!("RNG error: {e}"))?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}

pub(crate) fn is_link_key(key: &str) -> bool {
    key.len() == 43 && base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(key).is_ok_and(|k| k.len() == 32)
}

fn framed(parts: &[&[u8]]) -> Vec<u8> {
    let mut out = Vec::new();
    for part in parts {
        out.extend_from_slice(&(part.len() as u32).to_be_bytes());
        out.extend_from_slice(part);
    }
    out
}

fn meeting_cipher(link_key: &str, conf_id: &str) -> Option<aes_gcm::Aes256Gcm> {
    use hmac::Mac;
    let key = zeroize::Zeroizing::new(
        base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(link_key).ok().filter(|k| k.len() == 32)?,
    );
    let mut mac = <hmac::Hmac<Sha256> as Mac>::new_from_slice(&key).ok()?;
    mac.update(&framed(&[MEETING_DOMAIN, conf_id.as_bytes()]));
    let key = zeroize::Zeroizing::new(mac.finalize().into_bytes());
    <aes_gcm::Aes256Gcm as aes_gcm::KeyInit>::new_from_slice(key.as_slice()).ok()
}

/// A sealed frame opens only in its meeting's room and only as the device that sealed it.
fn meeting_aad(room: &str, sender: &str) -> Vec<u8> {
    framed(&[MEETING_DOMAIN, room.as_bytes(), sender.as_bytes()])
}

/// The meeting a meeting-lane message speaks for.
fn meeting_named(msg: &HavenMessage) -> Option<&str> {
    match msg {
        HavenMessage::ConferenceJoinRequest { conf_id, .. }
        | HavenMessage::ConferenceJoinDenied { conf_id, .. }
        | HavenMessage::ConferenceLobbyInfo { conf_id, .. }
        | HavenMessage::ConferenceEnded { conf_id, .. }
        | HavenMessage::ConferenceKicked { conf_id, .. } => Some(conf_id),
        HavenMessage::MlsWelcome { server_id, .. } => conf_id_from_sid(server_id),
        _ => None,
    }
}

/// The wire bytes of a meeting-lane message from our device `sender`.
pub(crate) fn seal_meeting(link_key: &str, conf_id: &str, sender: &str, msg: &HavenMessage) -> Option<Vec<u8>> {
    use aes_gcm::aead::{Aead, Payload};
    debug_assert_eq!(msg.lane(), Lane::Meeting, "only meeting traffic rides the meeting lane");
    let plain = serde_json::to_vec(msg).ok()?;
    let mut nonce = [0u8; 12];
    getrandom::fill(&mut nonce).ok()?;
    let aad = meeting_aad(&conf_server_id(conf_id), sender);
    let ct = meeting_cipher(link_key, conf_id)?
        .encrypt(aes_gcm::Nonce::from_slice(&nonce), Payload { msg: &plain, aad: &aad })
        .ok()?;
    let engine = base64::engine::general_purpose::STANDARD;
    serde_json::to_vec(&HavenMessage::MeetingSealed { nonce: engine.encode(nonce), ct: engine.encode(ct) }).ok()
}

/// The meeting message inside a `MeetingSealed` that `sender` put into `room`. `None`
/// unless the link key opens it for that room and sender, and what it holds is meeting
/// traffic for that same meeting.
pub(crate) fn open_meeting(link_key: &str, room: &str, sender: &str, nonce: &str, ct: &str) -> Option<HavenMessage> {
    use aes_gcm::aead::{Aead, Payload};
    let conf_id = conf_id_from_sid(room)?;
    let engine = base64::engine::general_purpose::STANDARD;
    let nonce: [u8; 12] = engine.decode(nonce).ok()?.try_into().ok()?;
    let ct = engine.decode(ct).ok()?;
    let plain = meeting_cipher(link_key, conf_id)?
        .decrypt(aes_gcm::Nonce::from_slice(&nonce), Payload { msg: &ct, aad: &meeting_aad(room, sender) })
        .ok()?;
    let msg: HavenMessage = serde_json::from_slice(&plain).ok()?;
    (msg.lane() == Lane::Meeting && meeting_named(&msg) == Some(conf_id)).then_some(msg)
}

/// A meeting-lane message to one device in the meeting's room.
fn send_sealed_to(ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>, seal: &MeetingSeal, conf_id: &str, peer: &str, msg: &HavenMessage) {
    if let Some(data) = seal_meeting(&seal.link_key, conf_id, &seal.device, msg) {
        let _ = ws_cmd_tx.send(WsCommand::SendDirect {
            room_code: conf_server_id(conf_id),
            target_peer: peer.to_string(),
            data,
        });
    }
}

/// What we seal our meeting frames with: the link key, as our device.
#[derive(Clone)]
pub(crate) struct MeetingSeal {
    pub link_key: String,
    pub device: String,
}

/// The link keys of meetings we joined or knock on (host side: `ConferenceHostState`).
/// Process-global like `PENDING_KNOCKS`, since the arms that end a meeting do not
/// thread conference state.
static MEETING_KEYS: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

fn remember_meeting_key(conf_id: &str, link_key: &str) {
    if let Ok(mut g) = MEETING_KEYS.lock() {
        g.get_or_insert_with(HashMap::new).insert(conf_id.to_string(), link_key.to_string());
    }
}

pub(crate) fn forget_meeting_key(conf_id: &str) {
    if let Ok(mut g) = MEETING_KEYS.lock()
        && let Some(map) = g.as_mut()
    {
        map.remove(conf_id);
    }
}

/// The link key a frame in `room` opens under: the meeting we host, or one we joined.
pub(crate) fn meeting_key_for_room(conference_host: &HashMap<String, ConferenceHostState>, room: &str) -> Option<String> {
    let conf_id = conf_id_from_sid(room)?;
    conference_host
        .get(conf_id)
        .map(|h| h.seal.link_key.clone())
        .or_else(|| MEETING_KEYS.lock().ok()?.as_ref()?.get(conf_id).cloned())
}

/// A joiner parked in the waiting room (host side). Only the KeyPackage is
/// held — admission commits the MLS add without a second round-trip; the
/// name/avatar shown in the host panel live in Dart (from the request event).
pub(crate) struct ConfPendingJoin {
    pub key_package_b64: String,
}

/// (Joiner side) an outbound knock not yet admitted or denied. Kept so it can be
/// RE-SENT when the host appears: a joiner who opens the link before the meeting
/// starts broadcasts into an empty room and would otherwise wait forever.
struct PendingKnock {
    display_name: String,
    avatar_hash: String,
    /// Already-derived proof (re-derivation would need the raw code).
    code_proof: String,
    seal: MeetingSeal,
    last_sent: std::time::Instant,
}

/// Process-global like `blocklist` (the deep `handle_incoming_request` arms
/// that must CLEAR entries don't thread conference state). Harness caveat:
/// shared across in-process test nodes — tests use distinct conf ids.
static PENDING_KNOCKS: Mutex<Option<HashMap<String, PendingKnock>>> = Mutex::new(None);

fn note_pending_knock(conf_id: &str, display_name: String, avatar_hash: String, code_proof: String, seal: MeetingSeal) {
    if let Ok(mut g) = PENDING_KNOCKS.lock() {
        g.get_or_insert_with(HashMap::new).insert(conf_id.to_string(), PendingKnock {
            display_name, avatar_hash, code_proof, seal,
            last_sent: std::time::Instant::now(),
        });
    }
}

/// Whether we are knocking on this meeting, so its Welcome was asked for.
pub(crate) fn has_pending_knock(conf_id: &str) -> bool {
    PENDING_KNOCKS
        .lock()
        .ok()
        .is_some_and(|g| g.as_ref().is_some_and(|map| map.contains_key(conf_id)))
}

/// Clear a knock once it resolved (admitted / denied / left / meeting ended).
pub(crate) fn clear_pending_knock(conf_id: &str) {
    if let Ok(mut g) = PENDING_KNOCKS.lock() {
        if let Some(map) = g.as_mut() {
            map.remove(conf_id);
        }
    }
}

/// A peer appeared in a conf room we are still knocking on: re-broadcast the join
/// request with a FRESH KeyPackage, since the arrival may be the host starting the
/// meeting. Throttled, and the host side dedups by peer anyway.
pub(crate) fn reknock_if_pending(
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    room_code: &str,
) {
    if let Some(mls_mgr) = mls.as_mut() {
        reknock(mls_mgr, crypto_store, ws_cmd_tx, room_code, std::time::Duration::from_secs(2));
    }
}

/// A Welcome for a meeting we knock on was refused or unreadable. Staging it spent
/// the KeyPackage the host holds for us, so knock again at once with a fresh one, or
/// a room member's bogus Welcome would leave the real host's admission unreadable.
pub(crate) fn reknock_after_bad_welcome(
    mls_mgr: &mut MlsManager,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    room_code: &str,
) {
    reknock(mls_mgr, crypto_store, ws_cmd_tx, room_code, std::time::Duration::ZERO);
}

fn reknock(
    mls_mgr: &mut MlsManager,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    room_code: &str,
    min_gap: std::time::Duration,
) {
    let Some(conf_id) = conf_id_from_sid(room_code) else { return; };
    let (display_name, avatar_hash, code_proof, seal) = {
        let Ok(mut g) = PENDING_KNOCKS.lock() else { return; };
        let Some(map) = g.as_mut() else { return; };
        let Some(knock) = map.get_mut(conf_id) else { return; };
        if knock.last_sent.elapsed() < min_gap {
            return;
        }
        knock.last_sent = std::time::Instant::now();
        (knock.display_name.clone(), knock.avatar_hash.clone(), knock.code_proof.clone(), knock.seal.clone())
    };
    let kp = match super::crypto_handler::mint_key_package(mls_mgr, crypto_store) {
        Ok(kp) => base64::engine::general_purpose::STANDARD.encode(kp),
        Err(e) => {
            hollow_log!("[HOLLOW-CONF] Re-knock KeyPackage generation failed for {conf_id}: {e}");
            return;
        }
    };
    let knock = HavenMessage::ConferenceJoinRequest {
        conf_id: conf_id.to_string(),
        display_name,
        avatar_hash,
        key_package: kp,
        code_proof,
    };
    let Some(data) = seal_meeting(&seal.link_key, conf_id, &seal.device, &knock) else { return; };
    let _ = ws_cmd_tx.send(WsCommand::SendToRoom { room_code: room_code.to_string(), data });
    hollow_log!("[HOLLOW-CONF] Re-knocked on conference {conf_id} with a fresh KeyPackage");
}

/// Host-side state for one ACTIVE meeting (exists only between Start/End).
pub(crate) struct ConferenceHostState {
    pub waiting_room: bool,
    /// `derive_code_key` of the room's access code.
    pub code_key: Option<String>,
    /// What every frame we send as host carries.
    pub host: ConfHost,
    pub seal: MeetingSeal,
    pub host_display_name: String,
    pub host_avatar_hash: String,
    pub pending: HashMap<String, ConfPendingJoin>,
}

// ── Host: start / end ────────────────────────────────────────────────

/// Start a meeting: mint a FRESH MLS group under the conf sid (dropping any
/// previous meeting's group — past attendees must be re-admitted) and join the
/// relay room. The caller (Dart) follows up with `voice_channel_join(sid, "main")`.
#[allow(clippy::too_many_arguments)]
pub(crate) fn handle_conference_start(
    conference_host: &mut HashMap<String, ConferenceHostState>,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    voice_channel_participants: &mut HashMap<String, HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    local_peer_str: &str,
    device_peer_id: &str,
    conf_id: String,
    nonce: String,
    link_key: String,
    waiting_room: bool,
    code_key: Option<String>,
    host_display_name: String,
    host_avatar_hash: String,
) {
    if !is_link_key(&link_key) {
        hollow_log!("[HOLLOW-CONF] Cannot start {conf_id}: the room has no link key");
        return;
    }
    if derive_conf_id(local_peer_str, &nonce) != conf_id {
        hollow_log!("[HOLLOW-CONF] Cannot start {conf_id}: its id does not name us as host");
        return;
    }
    clear_conf_voice_state(voice_channel_participants, voice_channel_gossip_mode, &conf_id);
    let sid = conf_server_id(&conf_id);
    let Some(mls_mgr) = mls.as_mut() else {
        hollow_log!("[HOLLOW-CONF] Cannot start {conf_id}: MLS not initialized");
        return;
    };
    let Some(cert) = mls_mgr.own_certificate() else {
        hollow_log!("[HOLLOW-CONF] Cannot start {conf_id}: this device has no bound MLS credential yet");
        return;
    };
    if mls_mgr.has_group(&sid) {
        mls_mgr.remove_group(&sid);
    }
    if let Err(e) = mls_mgr.create_group(&sid) {
        hollow_log!("[HOLLOW-CONF] create_group failed for {conf_id}: {e}");
        return;
    }
    persist_mls_state(mls_mgr, crypto_store);
    let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: sid });
    conference_host.insert(conf_id.clone(), ConferenceHostState {
        waiting_room,
        code_key,
        host: ConfHost { master: local_peer_str.to_string(), nonce, cert },
        seal: MeetingSeal { link_key, device: device_peer_id.to_string() },
        host_display_name,
        host_avatar_hash,
        pending: HashMap::new(),
    });
    hollow_log!("[HOLLOW-CONF] Meeting started for conference {conf_id} (waiting_room={waiting_room})");
}

/// End a meeting: tell the room, leave it, forget host state. The MLS group is
/// dropped so the next Start mints fresh keys.
pub(crate) fn handle_conference_end(
    conference_host: &mut HashMap<String, ConferenceHostState>,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    voice_channel_participants: &mut HashMap<String, HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    conf_id: &str,
) {
    clear_conf_voice_state(voice_channel_participants, voice_channel_gossip_mode, conf_id);
    clear_card_audience(conf_id);
    let sid = conf_server_id(conf_id);
    let Some(ended) = conference_host.remove(conf_id) else {
        hollow_log!("[HOLLOW-CONF] End for {conf_id} we aren't hosting — ignoring");
        return;
    };
    let end = HavenMessage::ConferenceEnded { conf_id: conf_id.to_string(), host: ended.host };
    if let Some(data) = seal_meeting(&ended.seal.link_key, conf_id, &ended.seal.device, &end) {
        let _ = ws_cmd_tx.send(WsCommand::SendToRoom { room_code: sid.clone(), data });
    }
    let _ = ws_cmd_tx.send(WsCommand::LeaveRoom { room_code: sid.clone() });
    if let Some(mls_mgr) = mls.as_mut() {
        if mls_mgr.has_group(&sid) {
            mls_mgr.remove_group(&sid);
            persist_mls_state(mls_mgr, crypto_store);
        }
    }
    hollow_log!("[HOLLOW-CONF] Meeting ended for conference {conf_id}");
}

// ── Joiner: request / leave ──────────────────────────────────────────

/// Ask to join: enter the relay room and broadcast a join request carrying our
/// fresh KeyPackage (light-announce rule: avatar HASH only, never blob bytes).
#[allow(clippy::too_many_arguments)]
pub(crate) fn handle_conference_request_join(
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    device_peer_id: &str,
    conf_id: String,
    link_key: String,
    display_name: String,
    avatar_hash: String,
    code_key: Option<String>,
) {
    if !is_pinned_conf_id(&conf_id) || !is_link_key(&link_key) {
        hollow_log!("[HOLLOW-CONF] Not knocking on {conf_id}: its link names no host or carries no key");
        return;
    }
    let sid = conf_server_id(&conf_id);
    let Some(mls_mgr) = mls.as_mut() else {
        hollow_log!("[HOLLOW-CONF] Cannot request join {conf_id}: MLS not initialized");
        return;
    };
    let kp = match super::crypto_handler::mint_key_package(mls_mgr, crypto_store) {
        Ok(kp) => base64::engine::general_purpose::STANDARD.encode(kp),
        Err(e) => {
            hollow_log!("[HOLLOW-CONF] KeyPackage generation failed for {conf_id}: {e}");
            return;
        }
    };
    let code_proof = code_key
        .map(|key| knock_proof(&key, &conf_id, device_peer_id))
        .unwrap_or_default();
    let seal = MeetingSeal { link_key, device: device_peer_id.to_string() };
    remember_meeting_key(&conf_id, &seal.link_key);
    // Remember the knock so PeerJoined/RoomMembers arms can RE-SEND it when
    // the host appears (knocking into an empty room otherwise waits forever).
    note_pending_knock(&conf_id, display_name.clone(), avatar_hash.clone(), code_proof.clone(), seal.clone());
    let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: sid.clone() });
    let knock = HavenMessage::ConferenceJoinRequest {
        conf_id: conf_id.clone(),
        display_name,
        avatar_hash,
        key_package: kp,
        code_proof,
    };
    if let Some(data) = seal_meeting(&seal.link_key, &conf_id, &seal.device, &knock) {
        let _ = ws_cmd_tx.send(WsCommand::SendToRoom { room_code: sid, data });
    }
}

/// Leave a conference (joiner side, or a host tile closing without ending the
/// meeting is not supported in v1 — hosts end). Group state is left in place;
/// a re-admission's Welcome replaces it (the Welcome arm drops stale groups).
pub(crate) fn handle_conference_leave(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    voice_channel_participants: &mut HashMap<String, HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    conf_id: &str,
) {
    clear_pending_knock(conf_id);
    forget_meeting_key(conf_id);
    clear_card_audience(conf_id);
    clear_conf_voice_state(voice_channel_participants, voice_channel_gossip_mode, conf_id);
    let _ = ws_cmd_tx.send(WsCommand::LeaveRoom { room_code: conf_server_id(conf_id) });
    hollow_log!("[HOLLOW-CONF] Left conference {conf_id}");
}

// ── Host: inbound join requests + admit/deny ─────────────────────────

/// Host-side gate for an inbound `ConferenceJoinRequest`. Order matters: blocklist
/// FIRST (the standard inbound stranger-surface rule), then the access code, then
/// waiting room versus auto-admit.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_inbound_join_request(
    conference_host: &mut HashMap<String, ConferenceHostState>,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender_peer: &str,
    local_peer_str: &str,
    conf_id: String,
    display_name: String,
    avatar_hash: String,
    key_package_b64: String,
    code_proof: String,
) {
    // Only the host of an ACTIVE meeting reacts; other members ignore.
    let Some(host_state) = conference_host.get_mut(&conf_id) else { return; };
    if sender_peer == local_peer_str { return; }

    if super::blocklist::is_blocked(sender_peer) {
        hollow_log!("[HOLLOW-CONF] Dropped join request from blocked peer for {conf_id}");
        return;
    }
    // Chat is attributed by the leaf, so the knocker is seated only under a leaf
    // bound to its own device: never as the host or another participant, and the
    // relay cannot swap in a KeyPackage of its own (D7).
    let Some(knocker) = seat_of(&key_package_b64, sender_peer) else {
        hollow_log!("[HOLLOW-SECURITY] Dropped a join request for {conf_id} from {sender_peer}: its KeyPackage is not bound to that device");
        return;
    };
    if refused(&knocker) {
        hollow_log!("[HOLLOW-SECURITY] Dropped a join request for {conf_id} from {sender_peer}: its master's roster does not count it");
        return;
    }

    if let Some(key) = &host_state.code_key
        && !knock_proof_holds(key, &conf_id, sender_peer, &code_proof)
    {
        send_sealed_to(ws_cmd_tx, &host_state.seal, &conf_id, sender_peer,
            &HavenMessage::ConferenceJoinDenied {
                conf_id: conf_id.clone(), reason: "wrong_code".to_string(), host: host_state.host.clone(),
            });
        return;
    }

    // Lobby banner: who they're waiting for. Sent even on auto-admit — the
    // joiner's UI shows it during the Welcome round-trip.
    send_sealed_to(ws_cmd_tx, &host_state.seal, &conf_id, sender_peer,
        &HavenMessage::ConferenceLobbyInfo {
            conf_id: conf_id.clone(),
            host_name: host_state.host_display_name.clone(),
            host_avatar_hash: host_state.host_avatar_hash.clone(),
            host: host_state.host.clone(),
        });

    if !host_state.waiting_room {
        let nonce = host_state.host.nonce.clone();
        let seal = host_state.seal.clone();
        admit_peer(mls, crypto_store, ws_cmd_tx, event_tx,
            &conf_id, &nonce, &seal, sender_peer, &key_package_b64).await;
        return;
    }

    host_state.pending.insert(sender_peer.to_string(), ConfPendingJoin {
        key_package_b64,
    });
    let _ = event_tx.send(NetworkEvent::ConferenceJoinRequestReceived {
        conf_id, peer_id: sender_peer.to_string(), display_name, avatar_hash,
    }).await;
}

/// The leaf a knock's KeyPackage would seat, when it is bound to the knocking device.
fn seat_of(key_package_b64: &str, device: &str) -> Option<crate::crypto::LeafIdentity> {
    let kp = base64::engine::general_purpose::STANDARD.decode(key_package_b64).ok()?;
    MlsManager::key_package_identity(&kp).ok()?.bound().filter(|id| id.device == device).cloned()
}

/// Host accepted a waiting joiner (or the waiting room is off): commit the MLS
/// add, Welcome the joiner directly (with the nonce that proves us its host),
/// broadcast the commit to the room with the Tier-1 epoch guard, and rotate our
/// own SFrame key.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn admit_peer(
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    conf_id: &str,
    nonce: &str,
    seal: &MeetingSeal,
    peer_id: &str,
    key_package_b64: &str,
) {
    let sid = conf_server_id(conf_id);
    // The roster may have dropped the device since it knocked.
    if seat_of(key_package_b64, peer_id).is_none_or(|leaf| refused(&leaf)) {
        hollow_log!("[HOLLOW-SECURITY] Not admitting {peer_id} to {conf_id}: its master's roster does not count it");
        return;
    }
    let Some(mls_mgr) = mls.as_mut() else { return; };
    let kp_bytes = match base64::engine::general_purpose::STANDARD.decode(key_package_b64) {
        Ok(b) => b,
        Err(e) => {
            hollow_log!("[HOLLOW-CONF] KeyPackage b64 decode failed for {conf_id}: {e}");
            return;
        }
    };
    let (commit, welcome) = match mls_mgr.add_member(&sid, &kp_bytes) {
        Ok(cw) => cw,
        Err(e) => {
            hollow_log!("[HOLLOW-CONF] add_member failed for {conf_id}: {e}");
            return;
        }
    };
    if let Err(e) = mls_mgr.merge_pending_commit(&sid) {
        hollow_log!("[HOLLOW-CONF] merge_pending_commit failed for {conf_id}: {e}");
        return;
    }
    persist_mls_state(mls_mgr, crypto_store);

    let welcome_b64 = base64::engine::general_purpose::STANDARD.encode(welcome);
    send_sealed_to(ws_cmd_tx, seal, conf_id, peer_id,
        &HavenMessage::MlsWelcome {
            server_id: sid.clone(), welcome: welcome_b64, channel_id: None,
            conf_nonce: Some(nonce.to_string()),
        });
    let epoch = mls_mgr.epoch(&sid).ok();
    broadcast_mls_commit(mls_mgr, ws_cmd_tx, &sid, None,
        base64::engine::general_purpose::STANDARD.encode(commit), epoch);

    // Our own cryptors rotate too — mirror the batch-flush emission.
    if let Ok(sframe_key) = mls_mgr.export_secret(&sid, "sframe", b"", 32) {
        let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
            server_id: sid.clone(), epoch: epoch.unwrap_or(0), sframe_key,
            channel_id: None,
        }).await;
    }
    hollow_log!("[HOLLOW-CONF] Admitted {peer_id} to conference {conf_id}");
}

/// Host explicitly admits a waiting-room entry (FFI `conference_admit`).
pub(crate) async fn handle_conference_admit(
    conference_host: &mut HashMap<String, ConferenceHostState>,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    conf_id: &str,
    peer_id: &str,
) {
    let Some(host_state) = conference_host.get_mut(conf_id) else { return; };
    let Some(pending) = host_state.pending.remove(peer_id) else {
        hollow_log!("[HOLLOW-CONF] Admit for {peer_id} with no pending request in {conf_id}");
        return;
    };
    let nonce = host_state.host.nonce.clone();
    let seal = host_state.seal.clone();
    admit_peer(mls, crypto_store, ws_cmd_tx, event_tx,
        conf_id, &nonce, &seal, peer_id, &pending.key_package_b64).await;
}

/// Host declines a waiting-room entry (FFI `conference_deny`).
pub(crate) fn handle_conference_deny(
    conference_host: &mut HashMap<String, ConferenceHostState>,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    conf_id: &str,
    peer_id: &str,
    reason: String,
) {
    let Some(host_state) = conference_host.get_mut(conf_id) else { return; };
    if host_state.pending.remove(peer_id).is_none() { return; }
    send_sealed_to(ws_cmd_tx, &host_state.seal, conf_id, peer_id,
        &HavenMessage::ConferenceJoinDenied {
            conf_id: conf_id.to_string(), reason, host: host_state.host.clone(),
        });
    hollow_log!("[HOLLOW-CONF] Denied {peer_id} for conference {conf_id}");
}

/// (Host) kick a CURRENT member: MLS remove commit (cryptographic cutoff —
/// the next SFrame rotation locks them out of media too), room-broadcast the
/// commit, then the courtesy teardown signal so their UI leaves cleanly.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_conference_kick(
    conference_host: &mut HashMap<String, ConferenceHostState>,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    voice_channel_participants: &mut HashMap<String, HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    device_peer_id: &str,
    conf_id: &str,
    peer_id: &str,
) {
    let Some((host, seal)) = conference_host.get(conf_id).map(|h| (h.host.clone(), h.seal.clone())) else {
        hollow_log!("[HOLLOW-CONF] Kick for {conf_id} we aren't hosting — ignoring");
        return;
    };
    let sid = conf_server_id(conf_id);
    let Some(mls_mgr) = mls.as_mut() else { return; };
    let commit = match mls_mgr.remove_identity_leaves(&sid, &[peer_id]) {
        Ok(c) => c,
        Err(e) => {
            hollow_log!("[HOLLOW-CONF] Kick remove_identity_leaves failed for {conf_id}: {e}");
            return;
        }
    };
    if let Err(e) = mls_mgr.merge_pending_commit(&sid) {
        hollow_log!("[HOLLOW-CONF] Kick merge_pending_commit failed for {conf_id}: {e}");
        return;
    }
    persist_mls_state(mls_mgr, crypto_store);
    let epoch = mls_mgr.epoch(&sid).ok();
    broadcast_mls_commit(mls_mgr, ws_cmd_tx, &sid, None,
        base64::engine::general_purpose::STANDARD.encode(commit), epoch);
    send_sealed_to(ws_cmd_tx, &seal, conf_id, peer_id,
        &HavenMessage::ConferenceKicked { conf_id: conf_id.to_string(), host });
    // Rotate our own cryptors to the post-remove epoch.
    if let Ok(sframe_key) = mls_mgr.export_secret(&sid, "sframe", b"", 32) {
        let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
            server_id: sid.clone(), epoch: epoch.unwrap_or(0), sframe_key,
            channel_id: None,
        }).await;
    }
    drop_leafless_from_call(mls_mgr, voice_channel_participants, voice_channel_gossip_mode, event_tx, &sid, device_peer_id).await;
    hollow_log!("[HOLLOW-CONF] Kicked {peer_id} from conference {conf_id}");
}

/// Devices in a meeting's call that hold no leaf in its group any more leave the call as
/// if they had left the room, so Dart closes their peer: their old SFrame key stays in
/// every key ring. With no group left (we were evicted), that is everyone but us.
pub(crate) async fn drop_leafless_from_call(
    mls_mgr: &MlsManager,
    voice_channel_participants: &mut HashMap<String, HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sid: &str,
    device_peer_id: &str,
) {
    Box::pin(drop_leafless_from_call_inner(
        mls_mgr, voice_channel_participants, voice_channel_gossip_mode, event_tx, sid, device_peer_id,
    ))
    .await
}

async fn drop_leafless_from_call_inner(
    mls_mgr: &MlsManager,
    voice_channel_participants: &mut HashMap<String, HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sid: &str,
    device_peer_id: &str,
) {
    let leaves = mls_mgr.group_members(sid);
    let gone: Vec<String> = voice_channel_participants
        .get(&format!("{sid}:{CONF_CHANNEL}"))
        .map(|call| call.iter().filter(|d| d.as_str() != device_peer_id && !leaves.contains(d)).cloned().collect())
        .unwrap_or_default();
    for device in gone {
        hollow_log!("[HOLLOW-CONF] {device} holds no leaf in {sid} any more: out of its call");
        handle_conf_room_peer_gone(voice_channel_participants, voice_channel_gossip_mode, event_tx, sid, &device).await;
    }
}

/// Notices each move of the resolver, after which the seats of the meetings we host
/// are judged again.
#[derive(Default)]
pub(crate) struct SeatWatch(u64);

impl SeatWatch {
    /// True once for each move of the resolver since the last call.
    pub(crate) fn moved(&mut self) -> bool {
        let now = super::resolver::epoch();
        std::mem::replace(&mut self.0, now) != now
    }
}

/// (Host) take every leaf that holds no seat out of each meeting we host, in one commit
/// per meeting: a device its master's roster stopped counting must not read the next
/// epoch. Idempotent, so the event loop's head and the batch tick both run it; boxed, as
/// the loop head's future sits at the edge of the worker stack.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn unseat_refused(
    conference_host: &HashMap<String, ConferenceHostState>,
    mls_mgr: &mut MlsManager,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    voice_channel_participants: &mut HashMap<String, HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    device_peer_id: &str,
) {
    Box::pin(unseat_refused_inner(
        conference_host, mls_mgr, crypto_store, ws_cmd_tx, event_tx,
        voice_channel_participants, voice_channel_gossip_mode, device_peer_id,
    ))
    .await
}

#[allow(clippy::too_many_arguments)]
async fn unseat_refused_inner(
    conference_host: &HashMap<String, ConferenceHostState>,
    mls_mgr: &mut MlsManager,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    voice_channel_participants: &mut HashMap<String, HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    device_peer_id: &str,
) {
    for sid in mls_mgr.group_ids() {
        let Some(conf_id) = conf_id_from_sid(&sid) else { continue };
        // Participants accept the host's commits only.
        if !conference_host.contains_key(conf_id) {
            continue;
        }
        let gone: Vec<String> = mls_mgr
            .group_leaves(&sid)
            .into_iter()
            .filter(|leaf| leaf.id() != device_peer_id && leaf.bound().is_none_or(refused))
            .map(|leaf| leaf.id().to_string())
            .collect();
        if gone.is_empty() {
            continue;
        }
        let done = match mls_mgr.commit_membership(&sid, &gone, &[]) {
            Ok(done) => done,
            Err(e) => {
                hollow_log!("[HOLLOW-CONF] Could not unseat {gone:?} from {conf_id}: {e}");
                continue;
            }
        };
        if let Err(e) = mls_mgr.merge_pending_commit(&sid) {
            hollow_log!("[HOLLOW-CONF] Unseat merge failed for {conf_id}: {e}");
            continue;
        }
        persist_mls_state(mls_mgr, crypto_store);
        let epoch = mls_mgr.epoch(&sid).ok();
        broadcast_mls_commit(mls_mgr, ws_cmd_tx, &sid, None,
            base64::engine::general_purpose::STANDARD.encode(&done.commit), epoch);
        if let Ok(sframe_key) = mls_mgr.export_secret(&sid, "sframe", b"", 32) {
            let _ = event_tx.send(NetworkEvent::MlsEpochChanged {
                server_id: sid.clone(), epoch: epoch.unwrap_or(0), sframe_key,
                channel_id: None,
            }).await;
        }
        drop_leafless_from_call(mls_mgr, voice_channel_participants, voice_channel_gossip_mode, event_tx, &sid, device_peer_id).await;
        hollow_log!("[HOLLOW-SECURITY] Unseated {:?} from conference {conf_id}: their masters' rosters no longer count them", done.removed);
    }
}

// ── Chat and cards (RAM-only, MLS application messages) ──────────────

/// One line of the meeting's group channel: MLS-encrypted under the conf group and
/// broadcast. Never persisted anywhere, never rides topic rings.
pub(crate) fn send_group_line(
    mls_mgr: &mut MlsManager,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    conf_id: &str,
    plaintext: &str,
) -> bool {
    let sid = conf_server_id(conf_id);
    let ciphertext = match mls_mgr.encrypt(&sid, plaintext.as_bytes()) {
        Ok(c) => c,
        Err(e) => {
            hollow_log!("[HOLLOW-CONF] Group line encrypt failed for {conf_id}: {e}");
            return false;
        }
    };
    // MLS rule: persist on encrypt (send ratchet must never be debounced).
    persist_mls_state(mls_mgr, crypto_store);
    let data = serde_json::to_vec(&HavenMessage::ConferenceChat {
        conf_id: conf_id.to_string(),
        body: base64::engine::general_purpose::STANDARD.encode(ciphertext),
    }).unwrap_or_default();
    let _ = ws_cmd_tx.send(WsCommand::SendToRoom { room_code: sid, data });
    true
}

/// Send a chat line.
pub(crate) fn handle_conference_send_chat(
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    conf_id: &str,
    text: String,
    timestamp: i64,
) {
    let Some(mls_mgr) = mls.as_mut() else { return; };
    let plaintext = serde_json::json!({ "text": text, "ts": timestamp }).to_string();
    send_group_line(mls_mgr, crypto_store, ws_cmd_tx, conf_id, &plaintext);
}

/// Per (our master, meeting), the devices in the group when we last sent our card:
/// anyone else who shows theirs has not seen ours yet.
type CardAudience = HashMap<(String, String), HashSet<String>>;
static CARD_AUDIENCE: Mutex<Option<CardAudience>> = Mutex::new(None);

/// Forget whom a meeting has shown our card to.
pub(crate) fn clear_card_audience(conf_id: &str) {
    if let Ok(mut guard) = CARD_AUDIENCE.lock()
        && let Some(map) = guard.as_mut()
    {
        map.retain(|(_, conf), _| conf != conf_id);
    }
}

fn card_seen_by(local_master: &str, conf_id: &str, device: &str) -> bool {
    CARD_AUDIENCE
        .lock()
        .ok()
        .and_then(|guard| {
            guard.as_ref().and_then(|map| {
                map.get(&(local_master.to_string(), conf_id.to_string())).map(|set| set.contains(device))
            })
        })
        .unwrap_or(false)
}

/// Our card, with its avatar, to everyone admitted to the meeting (A28): the others
/// are strangers as often as friends, and none of them can pull anything from us.
pub(crate) fn broadcast_card(
    mls_mgr: &mut MlsManager,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    conf_id: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    let Some(card) = super::profile_card::own_card(master_keypair, db_path, db_passphrase) else { return; };
    let avatar = super::profile_card::own_avatar(&card.master, db_path, db_passphrase)
        .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
        .unwrap_or_default();
    let members: HashSet<String> = mls_mgr.group_members(&conf_server_id(conf_id)).into_iter().collect();
    let line = serde_json::json!({ "card": &card, "avatar": avatar }).to_string();
    if send_group_line(mls_mgr, crypto_store, ws_cmd_tx, conf_id, &line)
        && let Ok(mut guard) = CARD_AUDIENCE.lock()
    {
        guard.get_or_insert_with(HashMap::new).insert((card.master.clone(), conf_id.to_string()), members);
    }
}

/// Inbound group line: decrypt under the conf group (decrypt success IS the
/// membership proof), then a chat line is emitted and a card stored.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_inbound_chat(
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    master_keypair: &crate::identity::native_identity::NativeKeypair,
    conf_id: String,
    body_b64: String,
    db_path: &str,
    db_passphrase: &str,
) {
    let sid = conf_server_id(&conf_id);
    let Some(mls_mgr) = mls.as_mut() else { return; };
    if !mls_mgr.has_group(&sid) { return; }
    let ciphertext = match base64::engine::general_purpose::STANDARD.decode(&body_b64) {
        Ok(b) => b,
        Err(_) => return,
    };
    // Attributed by the sending leaf, which proves its device and certifies its master,
    // so one participant cannot speak or show a card for another.
    let (plaintext, sender) = match mls_mgr.decrypt(&sid, &ciphertext) {
        Ok(p) => p,
        Err(e) => {
            hollow_log!("[HOLLOW-CONF] Group line decrypt failed for {conf_id}: {e}");
            return;
        }
    };
    // Receive ratchet advanced — same persist rule as every MLS decrypt site.
    persist_mls_state(mls_mgr, crypto_store);
    if refused(&sender) {
        hollow_log!("[HOLLOW-SECURITY] Dropped a group line in {conf_id} from leaf {}: its master's roster does not count it", sender.device);
        return;
    }
    let Ok(parsed) = serde_json::from_slice::<serde_json::Value>(&plaintext) else { return; };

    if let Some(card) = parsed.get("card").and_then(|c| serde_json::from_value::<super::types::SignedCard>(c.clone()).ok()) {
        if card.master != sender.master || !super::profile_card::card_holds(&card) {
            hollow_log!("[HOLLOW-SECURITY] Dropped a meeting card from {} in {conf_id}: not its own, or not signed by it", sender.device);
            return;
        }
        let avatar = parsed
            .get("avatar")
            .and_then(|a| a.as_str())
            .and_then(|a| base64::engine::general_purpose::STANDARD.decode(a).ok())
            .filter(|b| b.len() <= super::image_convert::PROFILE_AVATAR_RECV_MAX_BYTES);
        if super::profile_card::store_card(&card, avatar.as_deref(), db_path, db_passphrase) {
            let _ = event_tx.send(NetworkEvent::ProfileUpdated { peer_id: card.master.clone() }).await;
        }
        if !card_seen_by(&master_keypair.peer_id(), &conf_id, &sender.device) {
            broadcast_card(mls_mgr, crypto_store, ws_cmd_tx, master_keypair, &conf_id, db_path, db_passphrase);
        }
        return;
    }

    let text = parsed.get("text").and_then(|v| v.as_str()).unwrap_or_default().to_string();
    let timestamp = parsed.get("ts").and_then(|v| v.as_i64()).unwrap_or(0);
    if text.is_empty() || !super::crypto_handler::message_body_fits(&text) { return; }
    let _ = event_tx.send(NetworkEvent::ConferenceChatMessage {
        conf_id, sender_peer_id: sender.device, text, timestamp,
    }).await;
}

// ── Voice-roster hygiene ─────────────────────────────────────────────


/// Drop every voice-participant entry belonging to a conference. Called on start,
/// end and leave: a previous meeting's members otherwise linger, because their
/// VoiceChannelLeave races the host's room-leave and a restart reuses the key.
pub(crate) fn clear_conf_voice_state(
    voice_channel_participants: &mut HashMap<String, HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    conf_id: &str,
) {
    let prefix = format!("{}:", conf_server_id(conf_id));
    voice_channel_participants.retain(|k, _| !k.starts_with(&prefix));
    voice_channel_gossip_mode.retain(|k, _| !k.starts_with(&prefix));
}

/// A device vanished from a conference ROOM (PeerLeft, or missing from the
/// authoritative RoomMembers snapshot): being in the room is a prerequisite for
/// being in the call, so drop them from the voice roster and tell Dart. This is
/// what removes the tile LIVE when a VoiceChannelLeave never arrived.
pub(crate) async fn handle_conf_room_peer_gone(
    voice_channel_participants: &mut HashMap<String, HashSet<String>>,
    voice_channel_gossip_mode: &mut HashMap<String, bool>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    room_code: &str,
    peer_id: &str,
) {
    if !is_conference_sid(room_code) { return; }
    let vc_key = format!("{room_code}:{CONF_CHANNEL}");
    let mut removed = false;
    if let Some(p) = voice_channel_participants.get_mut(&vc_key) {
        removed = p.remove(peer_id);
        if p.is_empty() {
            voice_channel_participants.remove(&vc_key);
            voice_channel_gossip_mode.remove(&vc_key);
        }
    }
    if removed {
        let _ = event_tx.send(NetworkEvent::VoiceChannelLeft {
            server_id: room_code.to_string(),
            channel_id: CONF_CHANNEL.to_string(),
            peer_id: peer_id.to_string(),
            is_self: false,
        }).await;
    }
}

// ── Room-presence bookkeeping ────────────────────────────────────────

/// A device left the conf room (or vanished from RoomMembers): drop any
/// waiting-room entry so the host panel doesn't offer admitting a ghost.
pub(crate) fn handle_peer_left_room(
    conference_host: &mut HashMap<String, ConferenceHostState>,
    room_code: &str,
    peer_id: &str,
) {
    let Some(conf_id) = conf_id_from_sid(room_code) else { return; };
    if let Some(host_state) = conference_host.get_mut(conf_id) {
        host_state.pending.remove(peer_id);
    }
}

/// Sweep host pending lists against an authoritative RoomMembers snapshot.
pub(crate) fn retain_pending_in_room(
    conference_host: &mut HashMap<String, ConferenceHostState>,
    room_code: &str,
    members: &HashSet<String>,
) {
    let Some(conf_id) = conf_id_from_sid(room_code) else { return; };
    if let Some(host_state) = conference_host.get_mut(conf_id) {
        host_state.pending.retain(|peer, _| members.contains(peer));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::native_identity::NativeKeypair;

    fn kp(seed: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[seed; 32])
    }

    #[test]
    fn a_meeting_id_names_its_host() {
        let id = derive_conf_id("host", "n1");
        assert!(is_pinned_conf_id(&id));
        assert!(hosts_meeting(&id, "host", Some("n1")));
        assert!(!hosts_meeting(&id, "rogue", Some("n1")), "another master");
        assert!(!hosts_meeting(&id, "host", Some("n2")), "another nonce");
        assert!(!hosts_meeting(&id, "host", None));
        let legacy = "ab".repeat(16);
        assert!(!is_pinned_conf_id(&legacy), "a pre-0.12 room names nobody");
        assert!(!hosts_meeting(&legacy, "host", Some("n1")));
    }

    /// A-D3: a host frame names its host only when the id hashes from the named master
    /// and the certificate binds the device that sealed the frame to that master.
    #[test]
    fn a_host_frame_proves_its_host_only_from_the_hosts_device() {
        let _g = crate::node::resolver::test_lock();
        crate::node::resolver::clear_for_test();
        let (host_master, host_device, rogue) = (kp(1), kp(2), kp(3));
        let conf_id = derive_conf_id(&host_master.peer_id(), "n1");
        let proof = ConfHost {
            master: host_master.peer_id(),
            nonce: "n1".into(),
            cert: crate::crypto::certificate_for_test(&host_device, &host_master),
        };
        assert_eq!(verified_host(&conf_id, &host_device.peer_id(), &proof), Some(host_master.peer_id()));
        assert_eq!(verified_host(&conf_id, &rogue.peer_id(), &proof), None, "the host's proof sealed by someone else");
        assert_eq!(verified_host(&conf_id, &host_device.peer_id(), &ConfHost { nonce: "n2".into(), ..proof.clone() }), None);
        let own = ConfHost {
            master: rogue.peer_id(),
            nonce: "n1".into(),
            cert: crate::crypto::certificate_for_test(&rogue, &rogue),
        };
        assert_eq!(verified_host(&conf_id, &rogue.peer_id(), &own), None, "a rogue's own proof names another meeting");
        let forged = ConfHost { cert: crate::crypto::certificate_for_test(&rogue, &rogue), ..proof.clone() };
        assert_eq!(verified_host(&conf_id, &rogue.peer_id(), &forged), None, "a certificate for another master");
    }

    /// G1 (design ID-1): the host's master key certifies any device, so where we hold
    /// the host's roster a device it does not count, or a removed one, proves no host.
    /// Holding none (a stranger's meeting, AR-15), the certificate is all there is.
    #[test]
    fn a_host_frame_counts_only_from_a_device_the_hosts_roster_counts() {
        use crate::node::resolver;
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        let (host_master, host_device, minted) = (kp(11), kp(12), kp(13));
        let conf_id = derive_conf_id(&host_master.peer_id(), "n1");
        let proof = |device: &NativeKeypair| ConfHost {
            master: host_master.peer_id(),
            nonce: "n1".into(),
            cert: crate::crypto::certificate_for_test(device, &host_master),
        };
        let host = Some(host_master.peer_id());
        assert_eq!(verified_host(&conf_id, &minted.peer_id(), &proof(&minted)), host, "first contact: the certificate decides");

        resolver::note_roster(&host_master.peer_id());
        resolver::update_many(&host_master.peer_id(), [host_device.peer_id().as_str()]);
        assert_eq!(verified_host(&conf_id, &minted.peer_id(), &proof(&minted)), None, "a device the host's roster leaves out");
        assert_eq!(verified_host(&conf_id, &host_device.peer_id(), &proof(&host_device)), host);

        resolver::mark_revoked(&[host_device.peer_id()]);
        assert_eq!(verified_host(&conf_id, &host_device.peer_id(), &proof(&host_device)), None, "a removed device");
        resolver::clear_for_test();
    }

    /// A meeting seat (the voice arm's membership check) is a leaf bound to the device
    /// that its master's roster, where we hold it, counts.
    #[test]
    fn a_meeting_seat_needs_a_leaf_its_masters_roster_counts() {
        use crate::crypto::LeafIdentity;
        use crate::node::resolver;
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        let leaves = [
            LeafView::Bound(LeafIdentity { device: "dev-a".into(), master: "m-a".into() }),
            LeafView::Unbound("dev-u".into()),
        ];
        assert!(seated(&leaves, "dev-a"), "a stranger's leaf, judged by its certificate");
        assert!(!seated(&leaves, "dev-u"), "an unbound leaf");
        assert!(!seated(&leaves, "dev-x"), "no leaf");
        resolver::note_roster("m-a");
        assert!(!seated(&leaves, "dev-a"), "a leaf the roster does not count");
        resolver::update_many("m-a", ["dev-a"]);
        assert!(seated(&leaves, "dev-a"));
        resolver::mark_revoked(&["dev-a".to_string()]);
        assert!(!seated(&leaves, "dev-a"), "a removed device");
        resolver::clear_for_test();
    }

    #[test]
    fn a_seat_watch_fires_once_per_move_of_the_resolver() {
        use crate::node::resolver;
        let _g = resolver::test_lock();
        let mut watch = SeatWatch::default();
        watch.moved();
        assert!(!watch.moved(), "nothing moved since the last look");
        resolver::update("seat-watch-device", "seat-watch-master");
        assert!(watch.moved(), "a roster change moves the resolver");
        assert!(!watch.moved(), "one sweep per move");
        resolver::clear_for_test();
    }

    /// HOL-SEC-123: the meetings we host are swept at the event loop's head once the
    /// resolver moved (where a roster change lands), and again on every MLS batch tick.
    #[test]
    fn meeting_seats_follow_the_roster_stay_wired() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src").join("node").join("swarm.rs");
        let swarm = std::fs::read_to_string(path).expect("read swarm.rs").replace("\r\n", "\n");
        let between = |from: &str, to: &str| -> String {
            let start = swarm.find(from).unwrap_or_else(|| panic!("missing {from}"));
            let end = swarm[start..].find(to).unwrap_or_else(|| panic!("missing {to} after {from}"));
            swarm[start..start + end].to_string()
        };
        let head = between("loop_stall.check(arm, name, t0);", "tokio::select! {");
        assert!(
            head.contains("if seat_watch.moved()") && head.contains("conference::unseat_refused("),
            "the loop head no longer sweeps hosted meetings when the resolver moves",
        );
        assert!(
            between("_ = mls_batch_timer.tick() => {", "// Phase 3:").contains("conference::unseat_refused("),
            "the MLS batch tick no longer sweeps hosted meetings",
        );
    }

    /// S-26: the knock proves the code for its own device and meeting, so a proof
    /// seen on the wire opens nothing for anyone else.
    #[test]
    fn a_knock_proof_holds_only_for_its_device_meeting_and_code() {
        let conf_id = derive_conf_id("host", "n1");
        let key = derive_code_key(&conf_id, "tiger").unwrap();
        assert_eq!(key, derive_code_key(&conf_id, "tiger").unwrap(), "deterministic");
        let proof = knock_proof(&key, &conf_id, "dev-k");
        assert!(knock_proof_holds(&key, &conf_id, "dev-k", &proof));
        assert!(!knock_proof_holds(&key, &conf_id, "dev-r", &proof), "another device");
        let other_room = derive_conf_id("host", "n2");
        assert!(!knock_proof_holds(&key, &other_room, "dev-k", &proof), "another meeting");
        let wrong = derive_code_key(&conf_id, "tigers").unwrap();
        assert!(!knock_proof_holds(&key, &conf_id, "dev-k", &knock_proof(&wrong, &conf_id, "dev-k")), "another code");
        assert!(!knock_proof_holds(&key, &conf_id, "dev-k", ""), "no proof");
        assert_ne!(derive_code_key(&other_room, "tiger").unwrap(), key, "the key is salted by the meeting");
    }

    fn sealed_parts(sealed: &[u8]) -> (String, String) {
        match serde_json::from_slice::<HavenMessage>(sealed).expect("sealed frame parses") {
            HavenMessage::MeetingSealed { nonce, ct } => (nonce, ct),
            other => panic!("expected meeting_sealed, got {}", other.wire_kind()),
        }
    }

    /// A meeting frame opens only under its link key, in its meeting's room, for the
    /// device that sealed it, and only as meeting traffic for that same meeting.
    #[test]
    fn a_meeting_frame_opens_only_under_its_key_in_its_room_for_its_sender() {
        let key = new_link_key().unwrap();
        assert!(is_link_key(&key) && !is_link_key("") && !is_link_key(&key[..42]));
        let (conf_a, conf_b) = (derive_conf_id("host", "n1"), derive_conf_id("host", "n2"));
        let (room_a, room_b) = (conf_server_id(&conf_a), conf_server_id(&conf_b));
        let end = |conf_id: &str| HavenMessage::ConferenceEnded {
            conf_id: conf_id.to_string(),
            host: ConfHost { master: "m".into(), nonce: "n1".into(), cert: "c".into() },
        };

        let (n, c) = sealed_parts(&seal_meeting(&key, &conf_a, "dev", &end(&conf_a)).unwrap());
        assert!(matches!(open_meeting(&key, &room_a, "dev", &n, &c), Some(HavenMessage::ConferenceEnded { .. })));
        assert!(open_meeting(&key, &room_a, "other", &n, &c).is_none(), "it speaks only for its sealer");
        assert!(open_meeting(&key, &room_b, "dev", &n, &c).is_none(), "only in its own meeting's room");
        assert!(open_meeting(&new_link_key().unwrap(), &room_a, "dev", &n, &c).is_none(), "another key opens nothing");

        let (n, c) = sealed_parts(&seal_meeting(&key, &conf_a, "dev", &end(&conf_b)).unwrap());
        assert!(open_meeting(&key, &room_a, "dev", &n, &c).is_none(), "a frame sealed in A never speaks for B");

        let welcome = |sid: &str| HavenMessage::MlsWelcome {
            server_id: sid.to_string(), welcome: String::new(), channel_id: None, conf_nonce: Some("n1".into()),
        };
        let (n, c) = sealed_parts(&seal_meeting(&key, &conf_a, "dev", &welcome(&room_a)).unwrap());
        assert!(open_meeting(&key, &room_a, "dev", &n, &c).is_some(), "a meeting's Welcome rides its lane");
        assert_eq!(welcome("server-id").lane(), Lane::Relay, "a server's Welcome does not");
        assert_eq!(welcome(&room_a).lane(), Lane::Meeting, "and a meeting's is never read in the clear");
    }
}
