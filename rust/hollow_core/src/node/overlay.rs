//! The stream overlay's network side (#97): the `stream_overlay` field others learn
//! without asking, and the gated ask and answer that move a look.
//!
//! The field carries its OWN master signature over (master, `at`, value), outside
//! `hollow-profile2` and `hollow-card1`. It is REQUIRED: an unsigned or forged field
//! counts as absent and what we stored is kept; the newest `at` wins and an older one
//! never replaces it, so a replayed `share` cannot undo an `off`.
//!
//! A look moves only on request, only from its owner, and only to a roster-counted
//! device of our own identity, an accepted friend, or someone seated in a voice room
//! with us now. A failed gate is silence. Look images live in their own table
//! (`overlay_blobs`), never on the generic asset rail, and an answer serves only OUR
//! OWN look: another person's consent covers their own answer only.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use base64::Engine;
use tokio::sync::mpsc;

use super::assets::MAX_BUNDLE_REPLY_BYTES;
use super::overlay_look;
use super::types::{HavenMessage, NetworkEvent, OverlayField};
use crate::identity::native_identity::NativeKeypair;
use crate::storage::MessageStore;

/// `app_settings` key of our own look (canonical JSON). Identity-wide: siblings pull
/// it through the same ask.
pub(crate) const OWN_LOOK_SETTING: &str = "overlay_own_look";

/// Images a `held` list may name: one per look state.
const MAX_HELD: usize = 6;

/// How long an asked device has to answer before another (or it again) is asked.
const ASK_RETRY: Duration = if cfg!(test) { Duration::from_millis(1500) } else { Duration::from_secs(30) };

/// Answers one look may take to arrive whole: six 2 MB images over an 8 MiB answer
/// budget need two, so this only stops a responder that never finishes.
const MAX_ROUNDS: u8 = 6;

/// How long a look that could not be completed waits before it is asked for again.
const REST: Duration = if cfg!(test) { Duration::from_secs(3) } else { Duration::from_secs(300) };

/// How long changes to our field gather before one announce carries them all, so a
/// toggle flipped five times in a row costs one announce.
const ANNOUNCE_WINDOW: Duration = if cfg!(test) { Duration::from_millis(500) } else { Duration::from_secs(1) };

/// How long an image no saved look names is kept: the look editor's unsaved draft.
const DRAFT_GRACE_MS: i64 = 60 * 60 * 1000;

// -- The field --------------------------------------------------------------

/// What a `stream_overlay` field says.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FieldValue {
    /// "Let others show me" is off.
    Off,
    /// May be shown; shares nothing.
    Show,
    /// May be shown and shares the look last changed at this stamp (ms).
    Share(i64),
}

impl FieldValue {
    /// The one wire grammar: `off`, `show` or `share:<stamp>`, the stamp canonical
    /// decimal (no sign, no leading zero), so one value has one spelling.
    pub(crate) fn parse(s: &str) -> Option<Self> {
        match s {
            "off" => Some(Self::Off),
            "show" => Some(Self::Show),
            _ => {
                let digits = s.strip_prefix("share:")?;
                let canonical = !digits.is_empty()
                    && digits.len() <= 18
                    && digits.bytes().all(|b| b.is_ascii_digit())
                    && (digits == "0" || !digits.starts_with('0'));
                canonical.then(|| digits.parse().ok().map(Self::Share)).flatten()
            }
        }
    }

    pub(crate) fn wire(self) -> String {
        match self {
            Self::Off => "off".into(),
            Self::Show => "show".into(),
            Self::Share(stamp) => format!("share:{stamp}"),
        }
    }

    /// `off`, `show` or `share`, as Dart and the answer's `status` name it.
    pub(crate) fn kind(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Show => "show",
            Self::Share(_) => "share",
        }
    }
}

/// The bytes a field signature covers: length-prefixed, since a joined payload would
/// let one segment impersonate the next boundary.
fn field_payload(master: &str, at: i64, value: &str) -> Vec<u8> {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(at.to_le_bytes());
    for part in [master, value] {
        h.update((part.len() as u64).to_le_bytes());
        h.update(part.as_bytes());
    }
    format!("hollow-overlay1:{}", hex::encode(h.finalize())).into_bytes()
}

/// Our field, signed with the MASTER key every device of ours holds.
pub(crate) fn sign_field(master_keypair: &NativeKeypair, value: FieldValue, at: i64) -> OverlayField {
    let b64 = base64::engine::general_purpose::STANDARD;
    let value = value.wire();
    let sig = master_keypair.sign(&field_payload(&master_keypair.peer_id(), at, &value));
    OverlayField { value, at, sig: b64.encode(sig), pk: b64.encode(master_keypair.public_key_protobuf()) }
}

/// TEST-ONLY: a field for `master` signed by `keypair`, whoever it belongs to: what an
/// impostor holding only its own key can make.
#[cfg(test)]
pub(crate) fn sign_field_for(keypair: &NativeKeypair, master: &str, value: FieldValue, at: i64) -> OverlayField {
    let b64 = base64::engine::general_purpose::STANDARD;
    let value = value.wire();
    let sig = keypair.sign(&field_payload(master, at, &value));
    OverlayField { value, at, sig: b64.encode(sig), pk: b64.encode(keypair.public_key_protobuf()) }
}

/// What `field` says for `master`, or `None` when it is not `master`'s own signed
/// statement in the one grammar. REJECTS, never logs and continues: the caller treats
/// `None` as an absent field.
pub(crate) fn verify_field(master: &str, field: &OverlayField) -> Option<FieldValue> {
    let value = FieldValue::parse(&field.value)?;
    if field.at <= 0 {
        return None;
    }
    let b64 = base64::engine::general_purpose::STANDARD;
    let (Ok(pk), Ok(sig)) = (b64.decode(&field.pk), b64.decode(&field.sig)) else {
        return None;
    };
    // A real signature by somebody else is not this identity's.
    if NativeKeypair::peer_id_from_pubkey_protobuf(&pk).as_deref() != Some(master) {
        return None;
    }
    NativeKeypair::verify_peer_signature(&pk, &sig, &field_payload(master, field.at, &field.value))
        .unwrap_or(false)
        .then_some(value)
}

/// The field we hold for `master`, as stored (verified when it arrived).
pub(crate) fn stored_field(store: &MessageStore, master: &str) -> Option<OverlayField> {
    let (json, _) = store.load_stream_overlay(master).ok().flatten()?;
    serde_json::from_str(&json).ok()
}

/// What the field we hold for `master` says; absent (a client from before the
/// feature) is `show`.
pub(crate) fn field_of(store: &MessageStore, master: &str) -> FieldValue {
    stored_field(store, master)
        .and_then(|f| FieldValue::parse(&f.value))
        .unwrap_or(FieldValue::Show)
}

/// Masters we have already complained about once, so a reconnect storm is one line.
fn field_complaints() -> &'static std::sync::Mutex<HashSet<String>> {
    static SEEN: std::sync::OnceLock<std::sync::Mutex<HashSet<String>>> = std::sync::OnceLock::new();
    SEEN.get_or_init(|| std::sync::Mutex::new(HashSet::new()))
}

/// The ONE ingest gate for a `stream_overlay` field, on a profile or a card of
/// `master` (wiki `security_write_gates.md`). `ceiling` is the frame's
/// `frame_auth::stamp_ceiling`; `from_device` the device that sent it, when known.
///
/// Absent, unsigned, forged, malformed, stamped past the frame or not newer than what
/// we hold: nothing changes. Otherwise the field is kept and the people list reacts:
/// `off` removes `master` with every look we held for them, `show` deletes a look
/// fetched earlier. Returns whether the field was written.
pub(crate) fn ingest_field(
    store: &MessageStore,
    master: &str,
    field: Option<&OverlayField>,
    ceiling: i64,
    from_device: Option<&str>,
) -> bool {
    let Some(field) = field else { return false };
    let Some(value) = verify_field(master, field) else {
        if let Ok(mut seen) = field_complaints().lock()
            && seen.insert(master.to_string())
        {
            hollow_log!("[HOLLOW-SECURITY] REFUSED the stream overlay field of {master}: no valid signature over it; keeping what we stored");
        }
        return false;
    };
    if field.at > ceiling {
        hollow_log!("[HOLLOW-SECURITY] REFUSED the stream overlay field of {master}: stamped past its frame");
        return false;
    }
    let before = stored_field(store, master).and_then(|f| FieldValue::parse(&f.value));
    let Ok(json) = serde_json::to_string(field) else { return false };
    if !store.save_stream_overlay(master, &json, field.at, false).unwrap_or(false) {
        return false;
    }
    let mut removed = false;
    match value {
        FieldValue::Off => removed = remove_person(store, master).unwrap_or(false),
        FieldValue::Show => {
            if let Ok(Some(row)) = store.overlay_person(master)
                && row.their_look.is_some()
            {
                let _ = store.overlay_set_their_look(master, None, 0);
                forget_images(store, row.their_look.iter());
            }
        }
        FieldValue::Share(_) => {}
    }
    push_notice(store, FieldNotice {
        master: master.to_string(),
        from_device: from_device.map(str::to_string),
        value_changed: before.map(FieldValue::kind) != Some(value.kind()),
        removed,
    });
    true
}

// -- Notices from ingest to the event loop ----------------------------------

/// A field that changed, or a person taken off our overlay, for the event loop to
/// emit and to act on.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct FieldNotice {
    pub master: String,
    pub from_device: Option<String>,
    pub value_changed: bool,
    pub removed: bool,
}

/// One profile's notices, and whether any were dropped since the loop last drained.
#[derive(Debug, Default)]
struct NoticeQueue {
    notices: Vec<FieldNotice>,
    /// Sticky until drained: the loop then tells Dart to re-read everyone.
    lost: bool,
}

/// Notices per database file. Ingest also runs outside the event loop's task (push
/// fetch, spawned work, a block from the FFI), so the queue is keyed by the store it
/// wrote, which the loop of the same profile drains on its next tick.
fn notice_queues() -> &'static std::sync::Mutex<HashMap<String, NoticeQueue>> {
    static QUEUES: std::sync::OnceLock<std::sync::Mutex<HashMap<String, NoticeQueue>>> = std::sync::OnceLock::new();
    QUEUES.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

/// Notices a queue holds. Past it a removal still displaces a plain field change
/// (strangers can each make one, a removal needs a person we added), and whatever
/// is dropped marks the queue `lost`.
const MAX_QUEUED_NOTICES: usize = 256;

/// One name per database file, however its path was spelled.
pub(crate) fn notice_key(db_path: &str) -> String {
    std::fs::canonicalize(db_path).map_or_else(|_| db_path.to_string(), |p| p.to_string_lossy().into_owned())
}

fn push_notice(store: &MessageStore, notice: FieldNotice) {
    let key = notice_key(&store.db_file());
    let Ok(mut queues) = notice_queues().lock() else { return };
    let queue = queues.entry(key).or_default();
    if queue.notices.len() < MAX_QUEUED_NOTICES {
        queue.notices.push(notice);
        return;
    }
    queue.lost = true;
    if notice.removed
        && let Some(plain) = queue.notices.iter().position(|n| !n.removed)
    {
        queue.notices.remove(plain);
        queue.notices.push(notice);
    }
}

/// Whether ingest left anything for the loop of the database named by `key`.
pub(crate) fn has_notices(key: &str) -> bool {
    notice_queues().lock().is_ok_and(|q| q.get(key).is_some_and(|v| !v.notices.is_empty()))
}

fn drain_notices(key: &str) -> NoticeQueue {
    notice_queues().lock().ok().and_then(|mut q| q.remove(key)).unwrap_or_default()
}

#[cfg(test)]
fn take_notices(key: &str) -> Vec<FieldNotice> {
    drain_notices(key).notices
}

// -- Our own look and field ---------------------------------------------------

/// Our own look (canonical JSON), if we ever saved one.
pub(crate) fn own_look(store: &MessageStore) -> Option<String> {
    store.load_setting(OWN_LOOK_SETTING).ok().flatten().filter(|l| overlay_look::normalize(l).is_ok())
}

/// The two toggles as our own field says them. Before any field (a fresh identity),
/// both are on, the defaults Settings shows.
pub(crate) fn own_flags(store: &MessageStore, local_master: &str) -> (bool, bool) {
    match stored_field(store, local_master).and_then(|f| FieldValue::parse(&f.value)) {
        None | Some(FieldValue::Share(_)) => (true, true),
        Some(FieldValue::Show) => (true, false),
        Some(FieldValue::Off) => (false, false),
    }
}

/// Sign and keep a new field of ours; its stamp is newer than any we held, so every
/// device and every peer takes it over the last one.
fn publish_field(store: &MessageStore, master_keypair: &NativeKeypair, value: FieldValue, now_ms: i64) -> Result<(), String> {
    let local_master = master_keypair.peer_id();
    let held_at = store.load_stream_overlay(&local_master)?.map_or(0, |(_, at)| at);
    let field = sign_field(master_keypair, value, now_ms.max(held_at + 1));
    let json = serde_json::to_string(&field).map_err(|e| e.to_string())?;
    store.save_stream_overlay(&local_master, &json, field.at, true)?;
    Ok(())
}

/// Our own look, made if there is none yet (the default look, stamped now).
fn ensure_own_look(store: &MessageStore, now_ms: i64) -> Result<String, String> {
    if let Some(look) = own_look(store) {
        return Ok(look);
    }
    let look = overlay_look::with_stamp(&overlay_look::normalize("{}")?, now_ms)?;
    store.save_setting(OWN_LOOK_SETTING, &look)?;
    Ok(look)
}

/// The two toggles: "Let others show me" off forces sharing off.
pub(crate) fn set_flags(store: &MessageStore, master_keypair: &NativeKeypair, allow: bool, share: bool, now_ms: i64) -> Result<(), String> {
    let value = match (allow, share) {
        (false, _) => FieldValue::Off,
        (true, false) => FieldValue::Show,
        (true, true) => FieldValue::Share(overlay_look::stamp(&ensure_own_look(store, now_ms)?)),
    };
    publish_field(store, master_keypair, value, now_ms)
}

/// Save our own look with a newer stamp and re-sign the field, so siblings (and, when
/// sharing, everyone who added us) see a newer stamp and pull it. Returns the
/// canonical look.
pub(crate) fn set_own_look(store: &MessageStore, master_keypair: &NativeKeypair, look_json: &str, now_ms: i64) -> Result<String, String> {
    let look = overlay_look::normalize(look_json)?;
    let previous = own_look(store).map_or(0, |l| overlay_look::stamp(&l));
    let look = overlay_look::with_stamp(&look, now_ms.max(previous + 1))?;
    store.save_setting(OWN_LOOK_SETTING, &look)?;
    let value = match own_flags(store, &master_keypair.peer_id()) {
        (false, _) => FieldValue::Off,
        (true, false) => FieldValue::Show,
        (true, true) => FieldValue::Share(overlay_look::stamp(&look)),
    };
    publish_field(store, master_keypair, value, now_ms)?;
    Ok(look)
}

/// A change this device makes to our own toggles or look.
pub(crate) enum OwnChange {
    Flags { allow: bool, share: bool },
    Look(String),
}

/// Save `change` off the event loop; returns the canonical look for a look, else "".
async fn save_own_inner(master_keypair: &NativeKeypair, change: OwnChange, db_path: &str, db_passphrase: &str) -> Result<String, String> {
    let (db, pass, kp, now) = (db_path.to_string(), db_passphrase.to_string(), master_keypair.clone(), super::frame_auth::now_ms());
    tokio::task::spawn_blocking(move || {
        let store = MessageStore::open(&db, &pass)?;
        match change {
            OwnChange::Flags { allow, share } => set_flags(&store, &kp, allow, share, now).map(|()| String::new()),
            OwnChange::Look(look_json) => set_own_look(&store, &kp, &look_json, now),
        }
    })
    .await
    .unwrap_or_else(|e| Err(e.to_string()))
}

/// How a Settings change replies: nothing for the toggles, the look for a look.
enum OwnReply {
    Flags(tokio::sync::oneshot::Sender<Result<(), String>>),
    Look(tokio::sync::oneshot::Sender<Result<String, String>>),
}

/// The overlay's node commands: a Settings change to our own toggles or look (saved
/// off the loop and answered; the announce waits for the overlay tick), or a refresh
/// of whom to ask.
pub(crate) async fn handle_command(
    cmd: Box<super::types::NodeCommand>,
    book: &mut OverlayBook,
    master_keypair: &NativeKeypair,
    db_path: &str,
    db_passphrase: &str,
) {
    // Boxed: the event loop's poll frame sits near the worker stack in debug builds.
    Box::pin(async move {
        use super::types::NodeCommand;
        let (change, reply) = match *cmd {
            NodeCommand::OverlaySetFlags { allow, share, reply } => (OwnChange::Flags { allow, share }, OwnReply::Flags(reply)),
            NodeCommand::OverlaySetOwnLook { look_json, reply } => (OwnChange::Look(look_json), OwnReply::Look(reply)),
            NodeCommand::OverlayRefresh => return book.mark_dirty(),
            _ => return,
        };
        let done = save_own_inner(master_keypair, change, db_path, db_passphrase).await;
        if done.is_ok() {
            book.want_announce(Instant::now());
        }
        match reply {
            OwnReply::Flags(reply) => drop(reply.send(done.map(|_| ()))),
            OwnReply::Look(reply) => drop(reply.send(done)),
        }
    })
    .await
}

/// What the overlay's timer turn reads of the event loop's state.
pub(crate) struct TimerCtx<'a> {
    pub event_tx: &'a mpsc::Sender<NetworkEvent>,
    pub ws_cmd_tx: &'a mpsc::UnboundedSender<super::ws_client::WsCommand>,
    pub ws_room_peers: &'a HashMap<String, HashSet<String>>,
    pub voice_channel_participants: &'a HashMap<String, HashSet<String>>,
    pub server_states: &'a HashMap<String, crate::crdt::server_state::ServerState>,
    pub crypto_store: &'a crate::crypto::CryptoStore,
    pub master_keypair: &'a NativeKeypair,
    pub local_master: &'a str,
    pub device_peer_id: &'a str,
    pub is_invisible: bool,
    pub db_path: &'a str,
    pub db_passphrase: &'a str,
}

/// The overlay's turn on its timer: emit what ingest noticed, announce our field once
/// its window closed, look again at whom to ask when something changed, and ask.
pub(crate) async fn on_timer(book: &mut OverlayBook, mls: Option<&mut crate::crypto::MlsManager>, cx: TimerCtx<'_>) {
    // Boxed: the event loop's poll frame sits near the worker stack in debug builds.
    Box::pin(async move {
        let key = book.notice_key.get_or_insert_with(|| notice_key(cx.db_path)).clone();
        if has_notices(&key) {
            react_to_notices_inner(book, &key, cx.event_tx, cx.local_master, cx.db_path, cx.db_passphrase).await;
        }
        if book.take_due_announce(Instant::now()) {
            announce_own_field(mls, &cx).await;
        }
        tick_inner(
            book, cx.ws_cmd_tx, cx.ws_room_peers, cx.voice_channel_participants, cx.local_master, cx.device_peer_id,
            cx.db_path, cx.db_passphrase,
        )
        .await;
    })
    .await
}

/// The field our announces and cards carry, as stored.
pub(crate) fn own_field(store: &MessageStore, local_master: &str) -> Option<OverlayField> {
    stored_field(store, local_master)
}

// -- Images we keep -----------------------------------------------------------

/// Every overlay image a look we keep names: our own, and for each person we show,
/// the look they shared and our picks for them. [`sweep_images`] keeps these.
pub(crate) fn referenced_hashes(store: &MessageStore) -> HashSet<String> {
    let mut keep: HashSet<String> = HashSet::new();
    if let Some(look) = own_look(store) {
        keep.extend(overlay_look::hashes(&look));
    }
    for row in store.overlay_people().unwrap_or_default() {
        for look in row.their_look.iter().chain(row.local_look.iter()) {
            keep.extend(overlay_look::hashes(look));
        }
    }
    keep
}

/// Delete the overlay images `looks` name that no look we still keep names.
pub(crate) fn forget_images<'a>(store: &MessageStore, looks: impl Iterator<Item = &'a String>) {
    let keep = referenced_hashes(store);
    for look in looks {
        for hash in overlay_look::hashes(look) {
            if !keep.contains(&hash) {
                let _ = store.delete_overlay_blob(&hash);
            }
        }
    }
}

/// Delete the overlay images no kept look names and no draft could still be waiting
/// for (older than [`DRAFT_GRACE_MS`]). Returns how many went.
pub(crate) fn sweep_images(store: &MessageStore, now_ms: i64) -> usize {
    let keep = referenced_hashes(store);
    store
        .overlay_blob_stamps()
        .unwrap_or_default()
        .into_iter()
        .filter(|(hash, added_at)| !keep.contains(hash) && *added_at < now_ms - DRAFT_GRACE_MS)
        .filter(|(hash, _)| store.delete_overlay_blob(hash).unwrap_or(false))
        .count()
}

/// Whether `hash` is held as a stream overlay image: what an answer serves, the
/// overlay page shows, or an asker says it holds. Nothing the rail holds counts.
pub(crate) fn is_overlay_image(store: &MessageStore, hash: &str) -> bool {
    store.has_overlay_blob(hash).unwrap_or(false)
}

/// Store one image of ours (`overlay_process_image`).
pub(crate) fn store_own_image(store: &MessageStore, webp: &[u8], animated: bool) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    let hash = hex::encode(Sha256::digest(webp));
    store.save_overlay_blob(&hash, webp, animated)?;
    Ok(hash)
}

// -- The answering side -------------------------------------------------------

/// The master of `device` when the roster we hold for it counts it: never a bare
/// master (G1), never a revoked device, never one whose roster we do not hold.
pub(crate) fn roster_counted(device: &str) -> Option<String> {
    if super::resolver::is_bare_master(device) || super::resolver::is_revoked(device) {
        return None;
    }
    let master = super::resolver::resolve(device);
    super::resolver::is_device_of(device, &master).then_some(master)
}

/// Whether `device` sits in a voice room with THIS device now: a server voice channel
/// or a meeting, each seat keyed by its routable device id (ours too).
fn seated_with_us(voice_channel_participants: &HashMap<String, HashSet<String>>, device: &str, device_peer_id: &str) -> bool {
    voice_channel_participants
        .values()
        .any(|seats| seats.contains(device) && seats.contains(device_peer_id))
}

/// Whether this device is in a connected DM call with `master` now; a call still
/// ringing entitles nobody.
fn in_call_with(call_book: &super::call_book::CallBook, master: &str) -> bool {
    call_book
        .own()
        .is_some_and(|p| p.kind == "call" && p.started_ms > 0 && super::resolver::resolve(&p.with) == master)
}

/// What the in-memory state says about an ask from `asker`.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum AskStanding {
    Silence,
    Sibling,
    Seated,
    /// Only the friend row can tell: an accepted friend of this master may ask.
    IfFriend(String),
}

/// The answering gate's in-memory half: a roster-counted device that is not blocked,
/// and our own sibling, or seated in a voice room with us now (a server voice seat,
/// our DM call, our meeting). Narrower than `data_channel_peer_allowed`, which admits
/// every co-member of every shared server.
pub(crate) fn ask_standing(
    asker: &str,
    local_master: &str,
    device_peer_id: &str,
    voice_channel_participants: &HashMap<String, HashSet<String>>,
    call_book: &super::call_book::CallBook,
) -> AskStanding {
    let Some(master) = roster_counted(asker) else { return AskStanding::Silence };
    if asker == device_peer_id || super::blocklist::is_blocked(&master) {
        return AskStanding::Silence;
    }
    if master == local_master {
        return AskStanding::Sibling;
    }
    if seated_with_us(voice_channel_participants, asker, device_peer_id) || in_call_with(call_book, &master) {
        return AskStanding::Seated;
    }
    AskStanding::IfFriend(master)
}

/// The answering gate, `None` = SILENCE (no reply, nothing to probe); `Some(true)`
/// for our own sibling. The friend row is read off the event loop.
pub(crate) async fn overlay_ask_allowed(
    asker: &str,
    local_master: &str,
    device_peer_id: &str,
    voice_channel_participants: &HashMap<String, HashSet<String>>,
    call_book: &super::call_book::CallBook,
    db_path: &str,
    db_passphrase: &str,
) -> Option<bool> {
    match ask_standing(asker, local_master, device_peer_id, voice_channel_participants, call_book) {
        AskStanding::Silence => None,
        AskStanding::Sibling => Some(true),
        AskStanding::Seated => Some(false),
        AskStanding::IfFriend(master) => {
            let (db, pass) = (db_path.to_string(), db_passphrase.to_string());
            let friend = tokio::task::spawn_blocking(move || super::social::holds_accepted_friend(&db, &pass, &master))
                .await
                .unwrap_or(false);
            friend.then_some(false)
        }
    }
}

/// Our answer: the status our field says (a sibling always gets the look), and for
/// `share` the look plus the images of it not in `held`, as many as one answer holds.
fn build_answer(store: &MessageStore, local_master: &str, sibling: bool, held: &HashSet<String>) -> HavenMessage {
    let value = if sibling { FieldValue::Share(0) } else { field_of(store, local_master) };
    let FieldValue::Share(_) = value else {
        return HavenMessage::OverlayLookAnswer { status: value.kind().into(), look_json: String::new(), bundle_json: String::new() };
    };
    let look = own_look(store).unwrap_or_else(|| overlay_look::normalize("{}").unwrap_or_default());
    let mut assets: Vec<(String, Vec<u8>)> = Vec::new();
    let mut budget = 0usize;
    for hash in overlay_look::hashes(&look) {
        if held.contains(&hash) {
            continue;
        }
        // Only an overlay image: a look naming an emote or sticker we hold never serves it.
        let Ok(Some(bytes)) = store.load_overlay_blob(&hash) else { continue };
        if budget + bytes.len() > MAX_BUNDLE_REPLY_BYTES {
            continue;
        }
        budget += bytes.len();
        assets.push((hash, bytes));
    }
    let bundle_json = String::from_utf8(crate::api::showcase::encode_asset_bundle(&assets)).unwrap_or_default();
    HavenMessage::OverlayLookAnswer { status: "share".into(), look_json: look, bundle_json }
}

/// Boxed: the swarm event loop awaits this inline, and its future sits near the worker stack.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_overlay_look_ask(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    asker: &str,
    held: Vec<String>,
    local_master: &str,
    device_peer_id: &str,
    voice_channel_participants: &HashMap<String, HashSet<String>>,
    call_book: &super::call_book::CallBook,
    db_path: &str,
    db_passphrase: &str,
)  {
    Box::pin(handle_envelope_overlay_look_ask_inner(ws_cmd_tx, asker, held, local_master, device_peer_id, voice_channel_participants, call_book, db_path, db_passphrase)).await
}

/// Inbound [`HavenMessage::OverlayLookAsk`]: the gate first, then our answer.
#[allow(clippy::too_many_arguments)]
async fn handle_envelope_overlay_look_ask_inner(
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    asker: &str,
    held: Vec<String>,
    local_master: &str,
    device_peer_id: &str,
    voice_channel_participants: &HashMap<String, HashSet<String>>,
    call_book: &super::call_book::CallBook,
    db_path: &str,
    db_passphrase: &str,
) {
    let Some(sibling) = overlay_ask_allowed(
        asker, local_master, device_peer_id, voice_channel_participants, call_book, db_path, db_passphrase,
    )
    .await
    else {
        hollow_log!("[HOLLOW-SECURITY] Ignored an overlay look ask from {asker}: not entitled");
        return;
    };
    let held: HashSet<String> = held
        .into_iter()
        .filter(|h| crate::crdt::valid_emote_hash(h))
        .take(MAX_HELD)
        .collect();
    let (db, pass, master) = (db_path.to_string(), db_passphrase.to_string(), local_master.to_string());
    let answer = tokio::task::spawn_blocking(move || {
        MessageStore::open(&db, &pass).ok().map(|store| build_answer(&store, &master, sibling, &held))
    })
    .await
    .ok()
    .flatten();
    if let Some(answer) = answer {
        super::olm_lane::carry(ws_cmd_tx, asker, None, &answer, super::olm_lane::NoSession::Queue);
    }
}

/// Inbound overlay ask or answer, dispatched here so the swarm keeps one small arm.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope(
    msg: Box<HavenMessage>,
    book: &mut OverlayBook,
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender: &str,
    local_master: &str,
    device_peer_id: &str,
    voice_channel_participants: &HashMap<String, HashSet<String>>,
    call_book: &super::call_book::CallBook,
    db_path: &str,
    db_passphrase: &str,
) {
    match *msg {
        HavenMessage::OverlayLookAsk { held } => {
            handle_envelope_overlay_look_ask(
                ws_cmd_tx, sender, held, local_master, device_peer_id, voice_channel_participants, call_book, db_path, db_passphrase,
            )
            .await
        }
        HavenMessage::OverlayLookAnswer { status, look_json, bundle_json } => {
            handle_envelope_overlay_look_answer(
                book, ws_cmd_tx, event_tx, sender, status, look_json, bundle_json, local_master, db_path, db_passphrase,
            )
            .await
        }
        _ => {}
    }
}

// -- The asking side ----------------------------------------------------------

/// One look we are pulling, keyed by its owner's master in [`OverlayBook`].
#[derive(Debug)]
pub(crate) struct Want {
    /// The field stamp we want a look for; 0 for a pull from our own sibling.
    stamp: i64,
    /// A device to ask first: the sibling whose newer field we just saw.
    hint: Option<String>,
    /// Images of this look we already hold.
    held: Vec<String>,
    /// Devices asked for this look, and when. Only these may answer it.
    asked: HashMap<String, Instant>,
    /// The device whose answer we are waiting for.
    in_flight: Option<(String, Instant)>,
    /// Asks sent and not answered yet: an answer finishes the pull only when it is the
    /// last one coming, since a later ask may have been sent for a newer look.
    unanswered: u32,
    rounds: u8,
    rest_until: Option<Instant>,
}

impl Want {
    fn new(stamp: i64, hint: Option<String>, held: Vec<String>) -> Self {
        Want { stamp, hint, held, asked: HashMap::new(), in_flight: None, unanswered: 0, rounds: 0, rest_until: None }
    }

    /// Something newer to fetch: every device may be asked at once, and the answers of
    /// those already asked still count.
    fn ask_again_now(&mut self) {
        let long_ago = Instant::now().checked_sub(ASK_RETRY).unwrap_or_else(Instant::now);
        for at in self.asked.values_mut() {
            *at = (*at).min(long_ago);
        }
        self.in_flight = None;
        self.rounds = 0;
        self.rest_until = None;
    }
}

/// The asking side's state, owned by the event loop: whom we want a look from, and
/// which of their devices we asked.
#[derive(Debug, Default)]
pub(crate) struct OverlayBook {
    wants: HashMap<String, Want>,
    /// Reload the wants from the store on the next tick.
    dirty: bool,
    /// Devices seated in a voice room with us at the last tick.
    co_seated: HashSet<String>,
    /// When our changed field goes out; every change before then rides along.
    announce_at: Option<Instant>,
    /// This profile's notice queue ([`notice_key`] of the database).
    notice_key: Option<String>,
}

impl OverlayBook {
    pub(crate) fn new() -> Self {
        OverlayBook { dirty: true, ..Default::default() }
    }

    /// Look again at whom to ask (the people list or a field changed).
    pub(crate) fn mark_dirty(&mut self) {
        self.dirty = true;
    }

    /// Our field changed: announce it when the window opened by the first change of a
    /// burst closes.
    fn want_announce(&mut self, now: Instant) {
        self.announce_at.get_or_insert(now + ANNOUNCE_WINDOW);
    }

    /// Whether the announce is due now; it is due once per window.
    fn take_due_announce(&mut self, now: Instant) -> bool {
        let due = self.announce_at.is_some_and(|at| now >= at);
        if due {
            self.announce_at = None;
        }
        due
    }

    /// A new socket means a fresh set of devices: forget who was asked over the old one.
    pub(crate) fn reset_on_disconnect(&mut self) {
        for want in self.wants.values_mut() {
            want.asked.clear();
            want.in_flight = None;
            want.unanswered = 0;
        }
    }
}

/// The looks of people we show that their field says are newer than the one we
/// hold: (master, field stamp, images we hold of it). Nobody we block is asked.
fn wanted_from_store(store: &MessageStore) -> Vec<(String, i64, Vec<String>)> {
    let mut out = Vec::new();
    for row in store.overlay_people().unwrap_or_default() {
        if super::blocklist::is_blocked(&row.master) {
            continue;
        }
        let FieldValue::Share(stamp) = field_of(store, &row.master) else { continue };
        if stamp <= row.held_stamp {
            continue;
        }
        let held: Vec<String> = row
            .their_look
            .as_deref()
            .map(overlay_look::hashes)
            .unwrap_or_default()
            .into_iter()
            .filter(|h| is_overlay_image(store, h))
            .take(MAX_HELD)
            .collect();
        out.push((row.master, stamp, held));
    }
    out
}

/// Images of our own look we hold.
fn own_held(store: &MessageStore) -> Vec<String> {
    own_look(store)
        .map(|l| overlay_look::hashes(&l))
        .unwrap_or_default()
        .into_iter()
        .filter(|h| is_overlay_image(store, h))
        .take(MAX_HELD)
        .collect()
}

/// Emit what ingest noticed and turn our own field's change into a pull from the
/// sibling that sent it.
async fn react_to_notices_inner(
    book: &mut OverlayBook,
    key: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_master: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    let NoticeQueue { notices, lost } = drain_notices(key);
    if notices.is_empty() && !lost {
        return;
    }
    book.dirty = true;
    // The page drops whoever is no longer drawable before Dart publishes anew.
    let _ = tokio::task::spawn_blocking(super::overlay_server::reproject).await;
    // Whose notice was dropped is unknown: Dart re-reads everyone (an empty master).
    if lost {
        let _ = event_tx.send(NetworkEvent::OverlayFieldChanged { master: String::new() }).await;
    }
    let mut own_pull: Option<Option<String>> = lost.then_some(None);
    for notice in notices {
        if notice.removed {
            let _ = event_tx.send(NetworkEvent::OverlayPersonRemoved { master: notice.master.clone() }).await;
        }
        if notice.value_changed {
            let _ = event_tx.send(NetworkEvent::OverlayFieldChanged { master: notice.master.clone() }).await;
        }
        if notice.master == local_master
            && let Some(device) = notice.from_device
        {
            own_pull = Some(Some(device));
        }
    }
    // Our own field changed on a sibling (or its notice may have been dropped): pull
    // our look from that sibling first, else from any.
    if let Some(hint) = own_pull {
        let (db, pass) = (db_path.to_string(), db_passphrase.to_string());
        let held = tokio::task::spawn_blocking(move || MessageStore::open(&db, &pass).map(|s| own_held(&s)).unwrap_or_default())
            .await
            .unwrap_or_default();
        // A pull already under way keeps whom it asked: their answers still count.
        let want = book.wants.entry(local_master.to_string()).or_insert_with(|| Want::new(0, None, Vec::new()));
        if hint.is_some() {
            want.hint = hint;
        }
        want.held = held;
        want.ask_again_now();
    }
}

/// The overlay tick: reload whom to ask when something changed, let anyone newly
/// seated with us be asked again at once, and ask.
#[allow(clippy::too_many_arguments)]
async fn tick_inner(
    book: &mut OverlayBook,
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    voice_channel_participants: &HashMap<String, HashSet<String>>,
    local_master: &str,
    device_peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    if book.dirty {
        book.dirty = false;
        let (db, pass) = (db_path.to_string(), db_passphrase.to_string());
        let wanted = tokio::task::spawn_blocking(move || MessageStore::open(&db, &pass).map(|s| wanted_from_store(&s)).unwrap_or_default())
            .await
            .unwrap_or_default();
        let listed: HashSet<String> = wanted.iter().map(|(m, ..)| m.clone()).collect();
        book.wants.retain(|master, _| master == local_master || listed.contains(master));
        for (master, stamp, held) in wanted {
            let want = book.wants.entry(master).or_insert_with(|| Want::new(stamp, None, Vec::new()));
            if want.stamp != stamp {
                // A newer look: ask again at once, but answers already asked for still count.
                want.stamp = stamp;
                want.ask_again_now();
            }
            want.held = held;
        }
    }
    if book.wants.is_empty() {
        book.co_seated.clear();
        return;
    }
    let co_seated: HashSet<String> = voice_channel_participants
        .values()
        .filter(|seats| seats.contains(device_peer_id))
        .flat_map(|seats| seats.iter().cloned())
        .filter(|d| d != device_peer_id)
        .collect();
    for device in co_seated.difference(&book.co_seated) {
        let master = super::resolver::resolve(device);
        if let Some(want) = book.wants.get_mut(&master) {
            want.asked.remove(device);
            if want.in_flight.as_ref().is_some_and(|(d, _)| d == device) {
                want.in_flight = None;
            }
        }
    }
    book.co_seated = co_seated;
    dispatch(book, ws_cmd_tx, ws_room_peers, device_peer_id);
}

/// Ask one device for each look we want and are not already waiting on.
fn dispatch(
    book: &mut OverlayBook,
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    device_peer_id: &str,
) {
    let now = Instant::now();
    for (master, want) in book.wants.iter_mut() {
        // A block lands between two reloads of the wants: nothing more is asked of them.
        if want.rest_until.is_some_and(|t| now < t) || super::blocklist::is_blocked(master) {
            continue;
        }
        match &want.in_flight {
            Some((_, at)) if now.duration_since(*at) < ASK_RETRY => continue,
            // Waited out: what was asked is not coming.
            Some(_) => want.unanswered = 0,
            None => {}
        }
        let mut devices: Vec<String> = super::crypto_handler::online_devices_for(ws_room_peers, master)
            .into_iter()
            .filter(|d| d != device_peer_id && roster_counted(d).as_deref() == Some(master.as_str()))
            .filter(|d| want.asked.get(d).is_none_or(|at| now.duration_since(*at) >= ASK_RETRY))
            .collect();
        devices.sort();
        if let Some(hint) = &want.hint
            && let Some(pos) = devices.iter().position(|d| d == hint)
        {
            devices.swap(0, pos);
        }
        let Some(device) = devices.into_iter().next() else {
            want.in_flight = None;
            continue;
        };
        send_ask(ws_cmd_tx, &device, &want.held);
        want.asked.insert(device.clone(), now);
        want.in_flight = Some((device, now));
        want.unanswered += 1;
        want.rest_until = None;
    }
}

fn send_ask(ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>, device: &str, held: &[String]) {
    super::olm_lane::carry(
        ws_cmd_tx,
        device,
        None,
        &HavenMessage::OverlayLookAsk { held: held.iter().take(MAX_HELD).cloned().collect() },
        super::olm_lane::NoSession::Queue,
    );
}

/// What one answer did to our store.
#[derive(Debug, Default, PartialEq)]
pub(crate) struct Applied {
    /// A look or an image was written: Dart reloads.
    pub stored: bool,
    /// Every image the look names is held now.
    pub complete: bool,
    /// The images of the look we hold now.
    pub held: Vec<String>,
    /// The stamp of the look the answer carried; 0 for `off` / `show`.
    pub look_stamp: i64,
}

/// The images of `bundle_json` an answer carrying `look` may give us: named in the
/// look and within what we author (`received_overlay_image_fits`: size, canvas,
/// frames), never anything the sender says. The bundle codec already dropped every
/// image whose bytes do not hash to its name.
fn answered_images(look: &str, bundle_json: &str) -> Vec<(String, Vec<u8>)> {
    if bundle_json.is_empty() || bundle_json.len() > MAX_BUNDLE_REPLY_BYTES * 4 / 3 + 4096 {
        return Vec::new();
    }
    let named: HashSet<String> = overlay_look::hashes(look).into_iter().collect();
    crate::api::showcase::decode_asset_bundle(bundle_json.as_bytes())
        .into_iter()
        .filter(|(hash, bytes)| named.contains(hash) && super::image_convert::received_overlay_image_fits(bytes))
        .collect()
}

/// Take an answer from `master` (whose device we asked) into the store: our own look
/// from a sibling when it is newer, otherwise the look of a person we still show.
/// A look that does not parse refuses the whole answer.
pub(crate) fn apply_answer(
    store: &MessageStore,
    local_master: &str,
    master: &str,
    status: &str,
    look_json: &str,
    bundle_json: &str,
) -> Option<Applied> {
    let own = master == local_master;
    if !own && store.overlay_person(master).ok().flatten().is_none() {
        return None;
    }
    if status != "share" {
        if own {
            return None;
        }
        let row = store.overlay_person(master).ok().flatten()?;
        let wanted = match field_of(store, master) {
            FieldValue::Share(stamp) => stamp,
            _ => 0,
        };
        let had = row.their_look.is_some();
        let _ = store.overlay_set_their_look(master, None, wanted.max(row.held_stamp));
        forget_images(store, row.their_look.iter());
        return Some(Applied { stored: had, complete: true, held: Vec::new(), look_stamp: 0 });
    }
    // Their consent is the field we hold NOW, not the one we asked under: an answer
    // still on its way after they stopped sharing stores nothing.
    if !own && !matches!(field_of(store, master), FieldValue::Share(_)) {
        return None;
    }
    let look = overlay_look::normalize(look_json).ok()?;
    let look_stamp = overlay_look::stamp(&look);
    let current = if own {
        own_look(store)
    } else {
        store.overlay_person(master).ok().flatten().and_then(|r| r.their_look)
    };
    // Ours: a sibling's look replaces ours only when it is newer.
    if own && current.as_deref().is_some_and(|c| overlay_look::stamp(c) >= look_stamp) {
        return Some(Applied { stored: false, complete: true, held: Vec::new(), look_stamp });
    }
    let mut stored = false;
    for (hash, bytes) in answered_images(&look, bundle_json) {
        let animated = super::emotes::webp_is_animated(&bytes);
        if store.save_overlay_blob(&hash, &bytes, animated).unwrap_or(false) {
            stored = true;
        }
    }
    // Held = in the overlay table only: whether we ask again never depends on what
    // the rail holds, so the owner learns nothing about our emotes or stickers.
    let names = overlay_look::hashes(&look);
    let held: Vec<String> = names.iter().filter(|h| is_overlay_image(store, h)).cloned().collect();
    let complete = held.len() == names.len();
    if current.as_deref() != Some(look.as_str()) {
        let written = if own {
            store.save_setting(OWN_LOOK_SETTING, &look).is_ok()
        } else {
            let row = store.overlay_person(master).ok().flatten()?;
            let held_stamp = if complete { look_stamp } else { row.held_stamp };
            let ok = store.overlay_set_their_look(master, Some(&look), held_stamp).unwrap_or(false);
            if let Some(old) = row.their_look.as_ref() {
                forget_images(store, std::iter::once(old));
            }
            ok
        };
        stored |= written;
    } else if complete && !own {
        let _ = store.overlay_set_their_look(master, Some(&look), look_stamp);
    }
    Some(Applied { stored, complete, held, look_stamp })
}

/// Boxed: the swarm event loop awaits this inline, and its future sits near the worker stack.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_overlay_look_answer(
    book: &mut OverlayBook,
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender: &str,
    status: String,
    look_json: String,
    bundle_json: String,
    local_master: &str,
    db_path: &str,
    db_passphrase: &str,
)  {
    Box::pin(handle_envelope_overlay_look_answer_inner(book, ws_cmd_tx, event_tx, sender, status, look_json, bundle_json, local_master, db_path, db_passphrase)).await
}

/// Inbound [`HavenMessage::OverlayLookAnswer`]: only for a look we asked this very
/// device for, and only from a roster-counted device of the identity we asked;
/// anything else is dropped whole before a byte is read.
#[allow(clippy::too_many_arguments)]
async fn handle_envelope_overlay_look_answer_inner(
    book: &mut OverlayBook,
    ws_cmd_tx: &mpsc::UnboundedSender<super::ws_client::WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sender: &str,
    status: String,
    look_json: String,
    bundle_json: String,
    local_master: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    let master = super::resolver::resolve(sender);
    if super::blocklist::is_blocked(sender) {
        return;
    }
    let asked = book.wants.get(&master).is_some_and(|w| w.asked.contains_key(sender));
    if !asked || roster_counted(sender).as_deref() != Some(master.as_str()) {
        hollow_log!("[HOLLOW-SECURITY] Dropped an overlay look answer from {sender}: we did not ask it");
        return;
    }
    let more_coming = book.wants.get_mut(&master).is_some_and(|w| {
        w.unanswered = w.unanswered.saturating_sub(1);
        w.unanswered > 0
    });
    let (db, pass, me, who) = (db_path.to_string(), db_passphrase.to_string(), local_master.to_string(), master.clone());
    let applied = tokio::task::spawn_blocking(move || {
        MessageStore::open(&db, &pass).ok().and_then(|store| apply_answer(&store, &me, &who, &status, &look_json, &bundle_json))
    })
    .await
    .ok()
    .flatten();
    let Some(applied) = applied else {
        hollow_log!("[HOLLOW-OVERLAY] Refused an overlay look answer from {sender}");
        if let Some(want) = book.wants.get_mut(&master)
            && !more_coming
        {
            want.in_flight = None;
        }
        return;
    };
    if applied.stored {
        let _ = event_tx.send(NetworkEvent::OverlayLookReceived { master: master.clone() }).await;
    }
    let Some(want) = book.wants.get_mut(&master) else { return };
    if more_coming {
        // A later ask's answer is on its way and may carry a newer look or more images.
        want.held = applied.held;
        return;
    }
    if applied.complete {
        if master != local_master && applied.look_stamp > 0 && applied.look_stamp < want.stamp {
            // The device answered with an older look than its field names: ask later.
            want.in_flight = None;
            want.rest_until = Some(Instant::now() + REST);
        } else {
            book.wants.remove(&master);
        }
        return;
    }
    want.held = applied.held;
    want.rounds += 1;
    if want.rounds >= MAX_ROUNDS {
        want.rounds = 0;
        want.in_flight = None;
        want.rest_until = Some(Instant::now() + REST);
        return;
    }
    // More images than one answer holds: ask the same device for the rest.
    send_ask(ws_cmd_tx, sender, &want.held);
    want.asked.insert(sender.to_string(), Instant::now());
    want.in_flight = Some((sender.to_string(), Instant::now()));
    want.unanswered += 1;
}

/// One field announce, read from the store once for every peer it goes to.
#[derive(Default)]
struct BuiltAnnounce {
    /// Our light profile (hashes, no blobs), for those who see all of it.
    profile: Option<HavenMessage>,
    /// Our card, for a pending friend and for each meeting we are in.
    card: Option<super::types::SignedCard>,
    card_avatar_b64: String,
    roster: Option<crate::identity::roster::Roster>,
    /// Our removed devices: they hear our roster and nothing else.
    removed: HashSet<String>,
    /// The friend status of each master the in-memory state could not place.
    friend_status: HashMap<String, Option<String>>,
}

#[allow(clippy::too_many_arguments)]
fn build_announce(
    master_keypair: &NativeKeypair,
    local_master: &str,
    is_invisible: bool,
    unplaced: &[String],
    meetings: bool,
    db_path: &str,
    db_passphrase: &str,
) -> BuiltAnnounce {
    let card = super::profile_card::own_card(master_keypair, db_path, db_passphrase);
    let card_avatar_b64 = card
        .as_ref()
        .filter(|_| meetings)
        .and_then(|c| super::profile_card::own_avatar(&c.master, db_path, db_passphrase))
        .map(|b| base64::engine::general_purpose::STANDARD.encode(b))
        .unwrap_or_default();
    let (roster, removed) = match super::roster_book::own(local_master, db_path, db_passphrase) {
        Some((roster, state)) => (Some(roster), state.removed.into_keys().collect()),
        None => (None, HashSet::new()),
    };
    let friend_status = MessageStore::open(db_path, db_passphrase)
        .map(|st| unplaced.iter().map(|m| (m.clone(), st.get_friend_status(m).ok().flatten())).collect())
        .unwrap_or_default();
    BuiltAnnounce {
        profile: super::social::own_profile_update(master_keypair, local_master, is_invisible, false, None, db_path, db_passphrase),
        card,
        card_avatar_b64,
        roster,
        removed,
        friend_status,
    }
}

/// Who hears a field announce, and what: our own removed devices our roster, the rest
/// what `social::profile_audience` lets them see. `None` for nothing.
fn announce_for(peer: &str, known: Option<super::social::Audience>, built: &BuiltAnnounce) -> Option<HavenMessage> {
    use super::social::Audience;
    if built.removed.contains(peer) {
        return built.roster.clone().map(|roster| HavenMessage::RosterNotice { roster });
    }
    let audience = known.unwrap_or_else(|| {
        let status = built.friend_status.get(&super::resolver::resolve(peer)).cloned().flatten();
        super::social::audience_by_friend_status(status.as_deref())
    });
    match audience {
        Audience::Full => built.profile.clone(),
        Audience::Card => built.card.clone().map(|card| HavenMessage::ProfileCard {
            card,
            avatar_b64: String::new(),
            device_list: built.roster.clone(),
        }),
        Audience::None => None,
    }
}

/// Tell everyone who may hear our profile that our field changed, the way
/// `social::handle_update_profile` fans a profile out: the message built once off the
/// loop, a light profile carried (Olm) to each room peer that may see it all, our card
/// to a pending friend, and our card again to each meeting we are in, since a meeting
/// peer sees only the card.
async fn announce_own_field(mls: Option<&mut crate::crypto::MlsManager>, cx: &TimerCtx<'_>) {
    let mut seen = HashSet::new();
    let plan: Vec<(String, Option<super::social::Audience>)> = cx
        .ws_room_peers
        .values()
        .flatten()
        .filter(|p| p.as_str() != cx.device_peer_id && p.as_str() != cx.local_master && seen.insert(p.to_string()))
        .map(|p| (p.clone(), super::social::profile_audience_known(cx.server_states, cx.local_master, p)))
        .collect();
    let unplaced: Vec<String> = plan.iter().filter(|(_, a)| a.is_none()).map(|(p, _)| super::resolver::resolve(p)).collect();
    let meetings: Vec<String> = mls
        .as_ref()
        .map(|m| m.group_ids().iter().filter_map(|sid| super::conference::conf_id_from_sid(sid).map(str::to_string)).collect())
        .unwrap_or_default();
    let (kp, me, invisible, db, pass, any_meeting) = (
        cx.master_keypair.clone(),
        cx.local_master.to_string(),
        cx.is_invisible,
        cx.db_path.to_string(),
        cx.db_passphrase.to_string(),
        !meetings.is_empty(),
    );
    let built = tokio::task::spawn_blocking(move || build_announce(&kp, &me, invisible, &unplaced, any_meeting, &db, &pass))
        .await
        .unwrap_or_default();
    for (peer, known) in plan {
        match announce_for(&peer, known, &built) {
            Some(msg @ HavenMessage::RosterNotice { .. }) => {
                super::crypto_handler::send_message_to_peer(cx.ws_cmd_tx, cx.ws_room_peers, &peer, msg)
            }
            Some(msg) => super::olm_lane::carry(cx.ws_cmd_tx, &peer, None, &msg, super::olm_lane::NoSession::Queue),
            None => {}
        }
    }
    if let (Some(mls), Some(card)) = (mls, built.card.as_ref()) {
        for conf_id in &meetings {
            super::conference::broadcast_built_card(mls, cx.crypto_store, cx.ws_cmd_tx, conf_id, card, &built.card_avatar_b64);
        }
    }
}

// -- What Dart reads ------------------------------------------------------------

/// One person on our overlay as the FFI shows them.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct PersonView {
    pub master: String,
    pub slot: i64,
    /// `off` | `show` | `share`.
    pub field: String,
    pub their_look: Option<String>,
    pub local_look: Option<String>,
    pub effective_look: String,
}

pub(crate) fn people(store: &MessageStore) -> Vec<PersonView> {
    store
        .overlay_people()
        .unwrap_or_default()
        .into_iter()
        .map(|row| PersonView {
            field: field_of(store, &row.master).kind().to_string(),
            effective_look: overlay_look::effective(row.their_look.as_deref(), row.local_look.as_deref()),
            master: row.master,
            slot: row.slot,
            their_look: row.their_look,
            local_look: row.local_look,
        })
        .collect()
}

/// The overlay images someone on our overlay may be drawn with: our picks for them,
/// and their shared look only while their field says `share`.
pub(crate) fn drawable_images(store: &MessageStore, master: &str) -> HashSet<String> {
    let Ok(Some(row)) = store.overlay_person(master) else { return HashSet::new() };
    let mut out: HashSet<String> = row.local_look.as_deref().map(overlay_look::hashes).unwrap_or_default().into_iter().collect();
    if matches!(field_of(store, master), FieldValue::Share(_)) {
        out.extend(row.their_look.as_deref().map(overlay_look::hashes).unwrap_or_default());
    }
    out
}

/// Add `master` to our overlay. Refused for ourselves, for a blocked identity, and for
/// anyone whose field says `off`.
pub(crate) fn add_person(store: &MessageStore, local_master: &str, master: &str, now_ms: i64) -> Result<i64, String> {
    if master.is_empty() || master == local_master {
        return Err("You can't add yourself".into());
    }
    if super::blocklist::is_blocked(master) {
        return Err("This person is blocked".into());
    }
    if field_of(store, master) == FieldValue::Off {
        return Err("This person doesn't allow being shown on stream overlays".into());
    }
    store.overlay_add_person(master, now_ms)
}

/// Take `master` off our overlay with everything we kept for them.
pub(crate) fn remove_person(store: &MessageStore, master: &str) -> Result<bool, String> {
    let Some(row) = store.overlay_remove_person(master)? else { return Ok(false) };
    forget_images(store, row.their_look.iter().chain(row.local_look.iter()));
    Ok(true)
}

/// We blocked `master` (here, or a sibling did): they leave our overlay as an `off`
/// takes them, with their fetched look and our picks, and the loop tells Dart. The
/// notice goes even for someone never added: the loop re-projects the OBS page,
/// where they may stand in the room.
pub(crate) fn forget_blocked(store: &MessageStore, master: &str) {
    let removed = remove_person(store, master).unwrap_or(false);
    push_notice(store, FieldNotice { master: master.to_string(), from_device: None, value_changed: false, removed });
}

/// Our picks for `master` (`None` clears them).
pub(crate) fn set_local_look(store: &MessageStore, master: &str, look_json: Option<&str>) -> Result<(), String> {
    let look = look_json.map(overlay_look::normalize_local).transpose()?;
    let old = store.overlay_person(master)?.ok_or("This person is not on your overlay")?;
    store.overlay_set_local_look(master, look.as_deref())?;
    if let Some(previous) = old.local_look.as_ref() {
        forget_images(store, std::iter::once(previous));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keypair(seed: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[seed; 32])
    }

    fn mem_store() -> MessageStore {
        MessageStore::open(":memory:", &"ab".repeat(32)).unwrap()
    }

    #[test]
    fn the_field_grammar_is_closed() {
        assert_eq!(FieldValue::parse("off"), Some(FieldValue::Off));
        assert_eq!(FieldValue::parse("show"), Some(FieldValue::Show));
        assert_eq!(FieldValue::parse("share:0"), Some(FieldValue::Share(0)));
        assert_eq!(FieldValue::parse("share:1760000000000"), Some(FieldValue::Share(1_760_000_000_000)));
        for bad in ["", "Off", "share", "share:", "share:-1", "share:01", "share:1x", "share: 1", "share:1234567890123456789", "hide"] {
            assert_eq!(FieldValue::parse(bad), None, "{bad:?}");
        }
        for v in [FieldValue::Off, FieldValue::Show, FieldValue::Share(42)] {
            assert_eq!(FieldValue::parse(&v.wire()), Some(v));
        }
    }

    #[test]
    fn a_field_verifies_only_under_its_own_masters_signature() {
        let (owner, other) = (keypair(61), keypair(62));
        let field = sign_field(&owner, FieldValue::Share(7), 1000);
        assert_eq!(verify_field(&owner.peer_id(), &field), Some(FieldValue::Share(7)));
        assert_eq!(verify_field(&other.peer_id(), &field), None, "another identity's field");
        let unsigned = OverlayField { sig: String::new(), ..field.clone() };
        assert_eq!(verify_field(&owner.peer_id(), &unsigned), None, "no signature");
        let flipped = OverlayField { value: "off".into(), ..field.clone() };
        assert_eq!(verify_field(&owner.peer_id(), &flipped), None, "a value the signature does not cover");
        let restamped = OverlayField { at: 1001, ..field.clone() };
        assert_eq!(verify_field(&owner.peer_id(), &restamped), None, "a stamp the signature does not cover");
        let by_other = OverlayField { pk: sign_field(&other, FieldValue::Share(7), 1000).pk, ..field.clone() };
        assert_eq!(verify_field(&owner.peer_id(), &by_other), None, "a key that is not the master's");
        let in_his_name = sign_field(&other, FieldValue::Off, 1000);
        assert_eq!(verify_field(&owner.peer_id(), &in_his_name), None);
        let impostor = sign_field_for(&other, &owner.peer_id(), FieldValue::Off, 1000);
        let b64 = base64::engine::general_purpose::STANDARD;
        let (pk, sig) = (b64.decode(&impostor.pk).unwrap(), b64.decode(&impostor.sig).unwrap());
        assert!(
            NativeKeypair::verify_peer_signature(&pk, &sig, &field_payload(&owner.peer_id(), 1000, "off")).unwrap_or(false),
            "precondition: the impostor's signature is valid under its own key",
        );
        assert_eq!(verify_field(&owner.peer_id(), &impostor), None, "a valid signature by a key that is not the master's");
        let malformed = sign_field(&owner, FieldValue::Show, 1000);
        let malformed = OverlayField { value: "share:01".into(), ..malformed };
        assert_eq!(verify_field(&owner.peer_id(), &malformed), None);
    }

    #[test]
    fn ingest_keeps_only_a_signed_newer_field_and_off_removes_the_person() {
        let store = mem_store();
        let owner = keypair(63);
        let m = owner.peer_id();
        store.save_profile_card(&m, "Owen", 1, "", None).unwrap();
        store.overlay_add_person(&m, 1).unwrap();
        let share = sign_field(&owner, FieldValue::Share(5), 100);
        assert!(ingest_field(&store, &m, Some(&share), i64::MAX, None));
        assert_eq!(field_of(&store, &m), FieldValue::Share(5));
        let forged = OverlayField { value: "off".into(), ..sign_field(&owner, FieldValue::Share(5), 200) };
        assert!(!ingest_field(&store, &m, Some(&forged), i64::MAX, None), "forged = absent");
        assert!(!ingest_field(&store, &m, None, i64::MAX, None), "absent changes nothing");
        assert_eq!(field_of(&store, &m), FieldValue::Share(5));
        let future = sign_field(&owner, FieldValue::Off, 900);
        assert!(!ingest_field(&store, &m, Some(&future), 800, None), "stamped past its frame");
        store.overlay_set_their_look(&m, Some(&overlay_look::normalize("{}").unwrap()), 5).unwrap();
        let off = sign_field(&owner, FieldValue::Off, 300);
        assert!(ingest_field(&store, &m, Some(&off), i64::MAX, None));
        assert!(store.overlay_person(&m).unwrap().is_none(), "off takes them off our overlay");
        let replayed = sign_field(&owner, FieldValue::Share(5), 250);
        assert!(!ingest_field(&store, &m, Some(&replayed), i64::MAX, None), "an older share never undoes off");
        assert_eq!(field_of(&store, &m), FieldValue::Off);
        assert_eq!(field_of(&store, "never-seen"), FieldValue::Show, "absent = show");
    }

    #[test]
    fn show_deletes_a_fetched_look_and_its_images() {
        let store = mem_store();
        let owner = keypair(64);
        let m = owner.peer_id();
        store.save_profile_card(&m, "Owen", 1, "", None).unwrap();
        store.overlay_add_person(&m, 1).unwrap();
        let hash = "c".repeat(64);
        store.save_overlay_blob(&hash, b"RIFF....WEBP", false).unwrap();
        let look = overlay_look::normalize(&format!(r#"{{"states":{{"idle":"{hash}"}}}}"#)).unwrap();
        store.overlay_set_their_look(&m, Some(&look), 5).unwrap();
        assert!(ingest_field(&store, &m, Some(&sign_field(&owner, FieldValue::Show, 10)), i64::MAX, None));
        let row = store.overlay_person(&m).unwrap().unwrap();
        assert_eq!((row.their_look, row.held_stamp), (None, 0), "show keeps the person, drops their look");
        assert!(!store.has_overlay_blob(&hash).unwrap(), "and the images only that look named");
    }

    #[test]
    fn the_gate_admits_siblings_seats_and_calls_and_nobody_else() {
        let _g = super::super::resolver::test_lock();
        let me = keypair(65).peer_id();
        let (my_dev, sib) = ("me-dev".to_string(), "sib-dev".to_string());
        let pal = keypair(66).peer_id();
        let pal_dev = "pal-dev".to_string();
        super::super::resolver::update(&my_dev, &me);
        super::super::resolver::update(&sib, &me);
        super::super::resolver::update(&pal_dev, &pal);
        let book = super::super::call_book::CallBook::default();
        let mut seats: HashMap<String, HashSet<String>> = HashMap::new();
        assert_eq!(ask_standing(&sib, &me, &my_dev, &seats, &book), AskStanding::Sibling);
        assert_eq!(ask_standing(&pal_dev, &me, &my_dev, &seats, &book), AskStanding::IfFriend(pal.clone()));
        assert_eq!(ask_standing("unknown-dev", &me, &my_dev, &seats, &book), AskStanding::Silence, "no roster, no answer");
        seats.insert("s:vc".into(), [my_dev.clone(), pal_dev.clone()].into());
        assert_eq!(ask_standing(&pal_dev, &me, &my_dev, &seats, &book), AskStanding::Seated);
        seats.insert("s:vc".into(), [pal_dev.clone()].into());
        assert_eq!(ask_standing(&pal_dev, &me, &my_dev, &seats, &book), AskStanding::IfFriend(pal.clone()), "a seat in a room we are not in");
        seats.insert("s:vc".into(), [pal_dev.clone(), sib.clone(), me.clone()].into());
        assert_eq!(ask_standing(&pal_dev, &me, &my_dev, &seats, &book), AskStanding::IfFriend(pal.clone()), "a room only our sibling sits in");
        let mut calls = super::super::call_book::CallBook::default();
        let call = |started_ms| super::super::types::CallPresence { kind: "call".into(), with: pal.clone(), channel: String::new(), started_ms };
        calls.set_own(Some(call(0)));
        assert_eq!(ask_standing(&pal_dev, &me, &my_dev, &seats, &calls), AskStanding::IfFriend(pal.clone()), "a call still ringing");
        calls.set_own(Some(call(5)));
        assert_eq!(ask_standing(&pal_dev, &me, &my_dev, &seats, &calls), AskStanding::Seated, "our connected DM call");
        super::super::resolver::note_roster(&pal);
        assert_eq!(ask_standing(&pal, &me, &my_dev, &seats, &calls), AskStanding::Silence, "a bare master (G1)");
        super::super::resolver::forget_for_test(&pal);
        super::super::resolver::mark_revoked(std::slice::from_ref(&pal_dev));
        assert_eq!(ask_standing(&pal_dev, &me, &my_dev, &seats, &book), AskStanding::Silence, "revoked");
        super::super::resolver::update(&pal_dev, &pal);
        assert_eq!(ask_standing(&pal_dev, &me, &my_dev, &seats, &book), AskStanding::Silence, "revoked, linked again");
        super::super::resolver::unmark_revoked(std::slice::from_ref(&pal_dev));
        assert_eq!(ask_standing(&pal_dev, &me, &my_dev, &seats, &book), AskStanding::IfFriend(pal.clone()), "control: recovered");
        super::super::blocklist::block(&pal);
        assert_eq!(ask_standing(&pal_dev, &me, &my_dev, &seats, &book), AskStanding::Silence, "blocked");
        super::super::blocklist::unblock(&pal);
        for d in [&my_dev, &sib, &pal_dev] {
            super::super::resolver::forget(d);
        }
    }

    fn webp(w: u32, h: u32, shade: u8) -> Vec<u8> {
        let img = image::RgbaImage::from_pixel(w, h, image::Rgba([shade, 20, 200, 255]));
        let mut png = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        super::super::image_convert::process_overlay_image(&png).unwrap().0
    }

    #[test]
    fn an_answer_takes_only_the_images_its_look_names_within_our_caps() {
        let store = mem_store();
        let owner = keypair(67);
        let m = owner.peer_id();
        store.save_profile_card(&m, "Owen", 1, "", None).unwrap();
        store.overlay_add_person(&m, 1).unwrap();
        assert!(ingest_field(&store, &m, Some(&sign_field(&owner, FieldValue::Share(9), 1)), i64::MAX, None), "precondition: they share");
        let (idle, stray) = (webp(64, 64, 1), webp(40, 24, 250));
        assert_ne!(idle, stray, "precondition: two different images");
        let hash = |b: &[u8]| {
            use sha2::{Digest, Sha256};
            hex::encode(Sha256::digest(b))
        };
        let look = format!(r#"{{"stamp":9,"states":{{"idle":"{}","talking":"{}"}}}}"#, hash(&idle), "d".repeat(64));
        let bundle = String::from_utf8(crate::api::showcase::encode_asset_bundle(&[
            (hash(&idle), idle.clone()),
            (hash(&stray), stray.clone()),
        ]))
        .unwrap();
        let applied = apply_answer(&store, "me", &m, "share", &look, &bundle).unwrap();
        assert!(applied.stored && !applied.complete, "{applied:?}");
        assert!(store.has_overlay_blob(&hash(&idle)).unwrap());
        assert!(!store.has_overlay_blob(&hash(&stray)).unwrap(), "an image the look does not name");
        assert!(!store.has_emote_blob(&hash(&idle)).unwrap(), "an answer never writes the rail");
        assert_eq!(store.overlay_person(&m).unwrap().unwrap().held_stamp, 0, "incomplete: still wanted");
        assert!(apply_answer(&store, "me", &m, "share", "not a look", &bundle).is_none(), "a bad look refuses the answer");
        let unshown = webp(20, 20, 120);
        let unshown_look = format!(r#"{{"stamp":9,"states":{{"idle":"{}"}}}}"#, hash(&unshown));
        let unshown_bundle = String::from_utf8(crate::api::showcase::encode_asset_bundle(&[(hash(&unshown), unshown.clone())])).unwrap();
        assert!(apply_answer(&store, "me", "not-added", "share", &unshown_look, &unshown_bundle).is_none(), "someone we do not show");
        assert!(!store.has_overlay_blob(&hash(&unshown)).unwrap(), "an image of someone we do not show was stored");

        // A container header naming the canvas, padded to any size.
        let padded = |len: usize, side: u32, fill: u8| {
            let s1 = side - 1;
            let mut b = b"RIFF".to_vec();
            b.extend_from_slice(&((len - 8) as u32).to_le_bytes());
            b.extend_from_slice(b"WEBPVP8X");
            b.extend_from_slice(&10u32.to_le_bytes());
            b.extend_from_slice(&[0, 0, 0, 0, s1 as u8, (s1 >> 8) as u8, 0, s1 as u8, (s1 >> 8) as u8, 0]);
            b.resize(len, fill);
            b
        };
        let cap = super::super::image_convert::MAX_OVERLAY_IMAGE_BYTES;
        let (fits, oversized, too_wide) = (padded(cap, 300, 1), padded(cap + 1, 300, 2), padded(4096, 600, 3));
        let look2 = format!(
            r#"{{"stamp":10,"states":{{"idle":"{}","talking":"{}","muted":"{}"}}}}"#,
            hash(&fits),
            hash(&oversized),
            hash(&too_wide)
        );
        let bundle2 = String::from_utf8(crate::api::showcase::encode_asset_bundle(&[
            (hash(&fits), fits.clone()),
            (hash(&oversized), oversized.clone()),
            (hash(&too_wide), too_wide.clone()),
        ]))
        .unwrap();
        let applied = apply_answer(&store, "me", &m, "share", &look2, &bundle2).unwrap();
        assert!(store.has_overlay_blob(&hash(&fits)).unwrap(), "CONTROL: an image at the cap lands");
        assert!(!store.has_overlay_blob(&hash(&oversized)).unwrap(), "over the overlay cap");
        assert!(!store.has_overlay_blob(&hash(&too_wide)).unwrap(), "a canvas over the overlay ceiling");
        assert!(!applied.complete);
    }

    #[test]
    fn a_sibling_look_replaces_ours_only_when_newer() {
        let store = mem_store();
        let kp = keypair(68);
        let ours = set_own_look(&store, &kp, r#"{"effects":{"talking":"pop"}}"#, 5_000).unwrap();
        assert_eq!(overlay_look::stamp(&ours), 5_000);
        let older = overlay_look::normalize(r#"{"stamp":4000,"effects":{"talking":"glow"}}"#).unwrap();
        let applied = apply_answer(&store, &kp.peer_id(), &kp.peer_id(), "share", &older, "").unwrap();
        assert!(!applied.stored && applied.complete);
        assert_eq!(own_look(&store).unwrap(), ours);
        let newer = overlay_look::normalize(r#"{"stamp":6000,"effects":{"talking":"glow"}}"#).unwrap();
        assert!(apply_answer(&store, &kp.peer_id(), &kp.peer_id(), "share", &newer, "").unwrap().stored);
        assert_eq!(own_look(&store).unwrap(), newer);
    }

    #[test]
    fn flags_and_look_re_sign_our_field_with_a_newer_stamp() {
        let store = mem_store();
        let kp = keypair(69);
        let me = kp.peer_id();
        assert_eq!(own_flags(&store, &me), (true, true), "both on before anything is set");
        set_flags(&store, &kp, true, false, 1_000).unwrap();
        assert_eq!(field_of(&store, &me), FieldValue::Show);
        let first = stored_field(&store, &me).unwrap();
        assert_eq!(verify_field(&me, &first), Some(FieldValue::Show));
        // Same wall clock: the stamp still moves forward.
        let look = set_own_look(&store, &kp, "{}", 1_000).unwrap();
        let second = stored_field(&store, &me).unwrap();
        assert!(second.at > first.at && second.value == "show", "a look edit re-signs the field: {second:?}");
        set_flags(&store, &kp, true, true, 1_000).unwrap();
        assert_eq!(field_of(&store, &me), FieldValue::Share(overlay_look::stamp(&look)));
        set_flags(&store, &kp, false, true, 1_000).unwrap();
        assert_eq!(own_flags(&store, &me), (false, false), "off forces sharing off");
    }

    #[test]
    fn an_answer_shares_only_what_our_field_allows_and_only_missing_images() {
        let store = mem_store();
        let kp = keypair(70);
        let me = kp.peer_id();
        let img = webp(32, 32, 9);
        let hash = store_own_image(&store, &img, false).unwrap();
        set_own_look(&store, &kp, &format!(r#"{{"states":{{"idle":"{hash}"}}}}"#), 2_000).unwrap();
        let status = |m: &HavenMessage| match m {
            HavenMessage::OverlayLookAnswer { status, look_json, bundle_json } => (status.clone(), look_json.clone(), bundle_json.clone()),
            _ => panic!("an answer"),
        };
        for (allow, share, want) in [(false, false, "off"), (true, false, "show")] {
            set_flags(&store, &kp, allow, share, 3_000).unwrap();
            let (s, look, bundle) = status(&build_answer(&store, &me, false, &HashSet::new()));
            assert_eq!((s.as_str(), look.as_str(), bundle.as_str()), (want, "", ""), "{want} carries nothing");
        }
        let (s, look, bundle) = status(&build_answer(&store, &me, true, &HashSet::new()));
        assert_eq!(s, "share", "a sibling always gets our look");
        assert!(look.contains(&hash) && bundle.contains(&hash));
        set_flags(&store, &kp, true, true, 4_000).unwrap();
        let (_, _, bundle) = status(&build_answer(&store, &me, false, &[hash.clone()].into()));
        assert_eq!(bundle, "{}", "an image the asker holds is left out");
    }

    /// The answer handler's own gate, judged alone: the device must be one we asked,
    /// and one the roster still counts for the identity we asked.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[allow(clippy::await_holding_lock)] // the resolver is process-global
    async fn an_answer_counts_only_from_a_device_we_asked_that_the_roster_still_counts() {
        let _g = super::super::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("answers.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        let owner = keypair(71);
        let m = owner.peer_id();
        let (asked, unasked) = ("answer-dev-asked".to_string(), "answer-dev-unasked".to_string());
        super::super::resolver::update(&asked, &m);
        super::super::resolver::update(&unasked, &m);
        {
            let store = MessageStore::open(&db, &pass).unwrap();
            store.save_profile_card(&m, "Owen", 1, "", None).unwrap();
            store.overlay_add_person(&m, 1).unwrap();
            assert!(ingest_field(&store, &m, Some(&sign_field(&owner, FieldValue::Share(9), 1)), i64::MAX, None));
        }
        let img = webp(16, 16, 3);
        let hash = {
            use sha2::{Digest, Sha256};
            hex::encode(Sha256::digest(&img))
        };
        let look = overlay_look::normalize(&format!(r#"{{"stamp":9,"states":{{"idle":"{hash}"}}}}"#)).unwrap();
        let bundle = String::from_utf8(crate::api::showcase::encode_asset_bundle(&[(hash.clone(), img)])).unwrap();
        let mut book = OverlayBook::new();
        let mut want = Want::new(9, None, Vec::new());
        want.asked.insert(asked.clone(), Instant::now());
        book.wants.insert(m.clone(), want);
        let (ws_tx, _ws_rx) = mpsc::unbounded_channel();
        let (ev_tx, mut ev_rx) = mpsc::channel(8);
        let held = || MessageStore::open(&db, &pass).unwrap().has_overlay_blob(&hash).unwrap();

        handle_envelope_overlay_look_answer(&mut book, &ws_tx, &ev_tx, &unasked, "share".into(), look.clone(), bundle.clone(), "me", &db, &pass).await;
        assert!(ev_rx.try_recv().is_err() && !held(), "a device of that identity we did not ask");
        super::super::resolver::mark_revoked(std::slice::from_ref(&asked));
        handle_envelope_overlay_look_answer(&mut book, &ws_tx, &ev_tx, &asked, "share".into(), look.clone(), bundle.clone(), "me", &db, &pass).await;
        assert!(ev_rx.try_recv().is_err() && !held(), "the device we asked, removed since");
        // The revocation mark judged alone: a link that comes back does not count it.
        super::super::resolver::update(&asked, &m);
        handle_envelope_overlay_look_answer(&mut book, &ws_tx, &ev_tx, &asked, "share".into(), look.clone(), bundle.clone(), "me", &db, &pass).await;
        assert!(ev_rx.try_recv().is_err() && !held(), "the device we asked, removed but linked again");
        // A recovery: the roster save links the member again, then lifts its mark.
        super::super::resolver::unmark_revoked(std::slice::from_ref(&asked));
        handle_envelope_overlay_look_answer(&mut book, &ws_tx, &ev_tx, &asked, "share".into(), look, bundle, "me", &db, &pass).await;
        assert!(matches!(ev_rx.try_recv(), Ok(NetworkEvent::OverlayLookReceived { master }) if master == m));
        assert!(held(), "the device we asked, still counted");
        for d in [&asked, &unasked] {
            super::super::resolver::forget(d);
        }
    }

    /// Two asks out (the look changed while the first was on its way): the first
    /// answer, with the older look, does not end the pull; the second does.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[allow(clippy::await_holding_lock)] // the resolver is process-global
    async fn an_older_answer_never_ends_a_pull_a_later_ask_is_still_answering() {
        let _g = super::super::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("pull.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        let owner = keypair(72);
        let m = owner.peer_id();
        let dev = "pull-dev".to_string();
        super::super::resolver::update(&dev, &m);
        {
            let store = MessageStore::open(&db, &pass).unwrap();
            store.save_profile_card(&m, "Owen", 1, "", None).unwrap();
            store.overlay_add_person(&m, 1).unwrap();
            assert!(ingest_field(&store, &m, Some(&sign_field(&owner, FieldValue::Share(10), 1)), i64::MAX, None));
        }
        let mut book = OverlayBook::new();
        let mut want = Want::new(10, None, Vec::new());
        want.asked.insert(dev.clone(), Instant::now());
        want.unanswered = 2;
        book.wants.insert(m.clone(), want);
        let (ws_tx, _ws_rx) = mpsc::unbounded_channel();
        let (ev_tx, _ev_rx) = mpsc::channel(8);
        let look = |stamp: i64| overlay_look::normalize(&format!(r#"{{"stamp":{stamp}}}"#)).unwrap();

        handle_envelope_overlay_look_answer(&mut book, &ws_tx, &ev_tx, &dev, "share".into(), look(5), String::new(), "me", &db, &pass).await;
        let want = book.wants.get(&m).expect("the pull goes on while an answer is still coming");
        assert!(want.rest_until.is_none(), "and does not rest");
        handle_envelope_overlay_look_answer(&mut book, &ws_tx, &ev_tx, &dev, "share".into(), look(10), String::new(), "me", &db, &pass).await;
        assert!(!book.wants.contains_key(&m), "the last answer, with the look the field names, ends it");
        let row = MessageStore::open(&db, &pass).unwrap().overlay_person(&m).unwrap().unwrap();
        assert_eq!((overlay_look::stamp(row.their_look.as_deref().unwrap()), row.held_stamp), (10, 10));
        super::super::resolver::forget(&dev);
    }

    /// Bytes the rail holds (an emote of a private server, say) and an overlay image
    /// with the same bytes are two rows: our own image, look and picks may use any
    /// image, an answer serves only what the overlay table holds, an ask never says
    /// we hold a rail blob, and storing or forgetting an overlay image leaves the rail
    /// row as it was.
    #[test]
    fn an_overlay_image_never_touches_what_the_rail_holds() {
        let store = mem_store();
        let kp = keypair(73);
        let me = kp.peer_id();
        let emote = webp(24, 24, 77);
        let emote_hash = {
            use sha2::{Digest, Sha256};
            hex::encode(Sha256::digest(&emote))
        };
        store.save_asset_blob(&emote_hash, &emote, false, "emote").unwrap();
        let rail = || (store.asset_blob_kind(&emote_hash).unwrap(), store.load_emote_blob(&emote_hash).unwrap().is_some());
        let untouched = (Some("emote".to_string()), true);

        // A look of ours naming the emote's hash, its bytes not yet an overlay image.
        let ours = store_own_image(&store, &webp(24, 24, 78), false).unwrap();
        let naming = format!(r#"{{"states":{{"idle":"{emote_hash}","talking":"{ours}"}}}}"#);
        set_own_look(&store, &kp, &naming, 1_000).unwrap();
        let HavenMessage::OverlayLookAnswer { bundle_json, .. } = build_answer(&store, &me, true, &HashSet::new()) else {
            panic!("an answer");
        };
        assert!(bundle_json.contains(&ours) && !bundle_json.contains(&emote_hash), "an answer served a rail blob");
        assert_eq!(own_held(&store), vec![ours.clone()], "an ask named a rail blob as held");

        // The same bytes picked as an overlay image: a second row, the emote unchanged.
        assert_eq!(store_own_image(&store, &emote, false).unwrap(), emote_hash);
        assert!(is_overlay_image(&store, &emote_hash));
        assert_eq!(rail(), untouched, "our own image relabelled the emote");

        // Someone we show names it; a fetched copy and its removal leave the rail row.
        let owner = keypair(74);
        let m = owner.peer_id();
        store.save_profile_card(&m, "Owen", 1, "", None).unwrap();
        store.overlay_add_person(&m, 1).unwrap();
        set_local_look(&store, &m, Some(&naming)).unwrap();
        assert!(ingest_field(&store, &m, Some(&sign_field(&owner, FieldValue::Share(9), 100)), i64::MAX, None));
        let theirs = overlay_look::normalize(&format!(r#"{{"stamp":9,"states":{{"idle":"{emote_hash}"}}}}"#)).unwrap();
        let bundle = String::from_utf8(crate::api::showcase::encode_asset_bundle(&[(emote_hash.clone(), emote.clone())])).unwrap();
        assert!(apply_answer(&store, &me, &m, "share", &theirs, &bundle).unwrap().complete);
        assert!(remove_person(&store, &m).unwrap());
        store.save_setting(OWN_LOOK_SETTING, &overlay_look::normalize("{}").unwrap()).unwrap();
        forget_images(&store, std::iter::once(&naming));
        assert!(!is_overlay_image(&store, &emote_hash), "CONTROL: the overlay copy is gone");
        assert_eq!(rail(), untouched, "forgetting an overlay image took the emote with it");
    }

    /// Images no kept look names go after the draft grace; named ones and fresh
    /// drafts stay.
    #[test]
    fn the_sweep_keeps_named_images_and_fresh_drafts() {
        let store = mem_store();
        let kp = keypair(75);
        let named = store_own_image(&store, &webp(16, 16, 1), false).unwrap();
        let draft = store_own_image(&store, &webp(16, 16, 200), false).unwrap();
        assert_ne!(named, draft, "precondition: two images");
        set_own_look(&store, &kp, &format!(r#"{{"states":{{"idle":"{named}"}}}}"#), 1_000).unwrap();
        let now = super::super::frame_auth::now_ms();
        assert_eq!(sweep_images(&store, now), 0, "a fresh draft waits for the editor");
        assert_eq!(sweep_images(&store, now + DRAFT_GRACE_MS + 1_000), 1);
        assert!(is_overlay_image(&store, &named) && !is_overlay_image(&store, &draft));
    }

    /// Changes to our field inside one window ride one announce; the next change
    /// opens a new window.
    #[test]
    fn field_announces_coalesce_per_window() {
        let mut book = OverlayBook::new();
        let t0 = Instant::now();
        assert!(!book.take_due_announce(t0), "nothing changed");
        for i in 0..5 {
            book.want_announce(t0 + Duration::from_millis(i * 10));
        }
        assert!(!book.take_due_announce(t0 + ANNOUNCE_WINDOW / 2), "the window is still open");
        assert!(book.take_due_announce(t0 + ANNOUNCE_WINDOW), "one announce for the burst");
        assert!(!book.take_due_announce(t0 + ANNOUNCE_WINDOW * 3), "and only one");
        let t1 = t0 + ANNOUNCE_WINDOW * 4;
        book.want_announce(t1);
        assert!(!book.take_due_announce(t1), "a later change waits for its own window");
        assert!(book.take_due_announce(t1 + ANNOUNCE_WINDOW));
    }
}

// so-review
#[cfg(test)]
mod so_review_tests {
    use super::*;

    fn keypair(seed: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[seed; 32])
    }

    fn mem_store() -> MessageStore {
        MessageStore::open(":memory:", &"ab".repeat(32)).unwrap()
    }

    fn webp(shade: u8) -> Vec<u8> {
        let img = image::RgbaImage::from_pixel(40, 40, image::Rgba([shade, 40, 180, 255]));
        let mut png = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        crate::node::image_convert::process_overlay_image(&png).unwrap().0
    }

    fn sha(bytes: &[u8]) -> String {
        use sha2::{Digest, Sha256};
        hex::encode(Sha256::digest(bytes))
    }

    fn look_naming(hash: &str) -> String {
        overlay_look::normalize(&format!(r#"{{"stamp":5,"states":{{"idle":"{hash}"}}}}"#)).unwrap()
    }

    /// A look naming a hash we hold as a sticker, answered without its bytes, must
    /// leave the asker exactly where a hash it does not hold leaves it; otherwise
    /// whether we re-ask tells the look's owner which stickers or emotes we hold.
    #[test]
    fn so_review_an_answer_never_tells_the_owner_which_other_kinds_we_hold() {
        let owner = keypair(81);
        let m = owner.peer_id();
        let sticker = webp(1);
        let h = sha(&sticker);
        let look = look_naming(&h);
        let holds = mem_store();
        let lacks = mem_store();
        for st in [&holds, &lacks] {
            st.save_profile_card(&m, "Mal", 1, "", None).unwrap();
            st.overlay_add_person(&m, 1).unwrap();
            assert!(ingest_field(st, &m, Some(&sign_field(&owner, FieldValue::Share(5), 1)), i64::MAX, None));
        }
        holds.save_asset_blob(&h, &sticker, false, "sticker").unwrap();
        let a = apply_answer(&holds, "me", &m, "share", &look, "").unwrap();
        let b = apply_answer(&lacks, "me", &m, "share", &look, "").unwrap();
        assert_eq!(
            (a.complete, a.held.clone()),
            (b.complete, b.held.clone()),
            "the asker's next move (end the pull, or ask again) differs by whether it holds a sticker"
        );
    }

    /// Overlay bytes we fetched first must not keep a hash off the rail that serves it:
    /// when the same bytes later arrive as a server emote, the blob is an emote.
    #[test]
    fn so_review_a_fetched_look_never_squats_a_hash_the_rail_serves() {
        let store = mem_store();
        let owner = keypair(82);
        let m = owner.peer_id();
        store.save_profile_card(&m, "Mal", 1, "", None).unwrap();
        store.overlay_add_person(&m, 1).unwrap();
        assert!(ingest_field(&store, &m, Some(&sign_field(&owner, FieldValue::Share(5), 1)), i64::MAX, None));
        let bytes = webp(2);
        let h = sha(&bytes);
        let bundle = String::from_utf8(crate::api::showcase::encode_asset_bundle(&[(h.clone(), bytes.clone())])).unwrap();
        let applied = apply_answer(&store, "me", &m, "share", &look_naming(&h), &bundle).unwrap();
        assert!(applied.complete, "precondition: the image landed");
        // Later the same bytes arrive on the generic rail as an emote of a server we join.
        store.save_asset_blob(&h, &bytes, false, "emote").unwrap();
        assert_eq!(
            store.asset_blob_kind(&h).unwrap().as_deref(),
            Some("emote"),
            "a look fetched from a friend made a server emote unservable (the generic rail answers it missing)"
        );
        // so-core-fix: the intent restated for the own table: taking the person off
        // (which forgets the fetched look) leaves the emote stored and servable.
        assert!(remove_person(&store, &m).unwrap());
        assert!(!is_overlay_image(&store, &h), "CONTROL: the fetched overlay image is forgotten");
        assert!(store.load_emote_blob(&h).unwrap().is_some(), "forgetting a fetched look removed a server emote");
    }

    /// A blocked identity stays on the people list, but nothing of theirs is asked for.
    #[test]
    fn so_review_a_blocked_person_is_not_asked_for_a_look() {
        let _g = crate::node::resolver::test_lock();
        let owner = keypair(83);
        let m = owner.peer_id();
        let store = mem_store();
        store.save_profile_card(&m, "Mal", 1, "", None).unwrap();
        store.overlay_add_person(&m, 1).unwrap();
        assert!(ingest_field(&store, &m, Some(&sign_field(&owner, FieldValue::Share(9), 100)), i64::MAX, None));
        assert!(wanted_from_store(&store).iter().any(|(w, ..)| *w == m), "precondition: a share is wanted");
        crate::node::blocklist::block(&m);
        let wanted = wanted_from_store(&store).iter().any(|(w, ..)| *w == m);
        crate::node::blocklist::unblock(&m);
        assert!(!wanted, "we keep asking a blocked identity for its look");
    }

    /// An answer from a blocked identity is dropped before it touches the store, like
    /// every other surface a block covers.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn so_review_a_blocked_persons_answer_is_dropped() {
        let _g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("so_review.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        let m = keypair(84).peer_id();
        let d = keypair(85).peer_id();
        crate::node::resolver::update(&d, &m);
        assert_eq!(roster_counted(&d).as_deref(), Some(m.as_str()), "precondition: the device counts");
        {
            let st = MessageStore::open(&db, &pass).unwrap();
            st.save_profile_card(&m, "Mal", 1, "", None).unwrap();
            st.overlay_add_person(&m, 1).unwrap();
        }
        let bytes = webp(3);
        let h = sha(&bytes);
        let bundle = String::from_utf8(crate::api::showcase::encode_asset_bundle(&[(h.clone(), bytes)])).unwrap();
        let mut book = OverlayBook::new();
        let mut want = Want::new(5, None, Vec::new());
        want.asked.insert(d.clone(), Instant::now());
        want.unanswered = 1;
        book.wants.insert(m.clone(), want);
        let (ws_tx, _ws_rx) = mpsc::unbounded_channel();
        let (ev_tx, mut ev_rx) = mpsc::channel(8);
        crate::node::blocklist::block(&m);
        handle_envelope_overlay_look_answer(
            &mut book, &ws_tx, &ev_tx, &d, "share".into(), look_naming(&h), bundle, "me", &db, &pass,
        )
        .await;
        crate::node::blocklist::unblock(&m);
        crate::node::resolver::forget(&d);
        // so-core-fix: answers store in the overlay table, so that is where to look.
        let stored = MessageStore::open(&db, &pass).unwrap().has_overlay_blob(&h).unwrap();
        let heard = ev_rx.try_recv().is_ok();
        assert!(!stored && !heard, "a blocked identity's answer was stored ({stored}) and emitted ({heard})");
    }

    /// The G1 check in `roster_counted` is load-bearing: a master id we hold a roster
    /// for that another identity's roster lists as a device (its key holder consented)
    /// would count as that identity's device without it.
    #[test]
    fn so_review_roster_counted_needs_its_bare_master_check() {
        let _g = crate::node::resolver::test_lock();
        let m = keypair(86).peer_id();
        let x = keypair(87).peer_id();
        crate::node::resolver::note_roster(&m);
        crate::node::resolver::update(&m, &x);
        let bare = crate::node::resolver::is_bare_master(&m);
        let mutant = !crate::node::resolver::is_revoked(&m)
            && crate::node::resolver::is_device_of(&m, &crate::node::resolver::resolve(&m));
        let counted = roster_counted(&m);
        crate::node::resolver::forget_for_test(&m);
        assert!(bare, "precondition: M is a bare master here");
        assert!(mutant, "without the G1 check the bare master would count as X's device");
        assert_eq!(counted, None, "a bare master counted");
    }
}

// so-core-fix
#[cfg(test)]
mod so_core_fix_tests {
    use super::*;

    fn keypair(seed: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[seed; 32])
    }

    fn file_store(name: &str) -> (crate::test_tmp::TestDir, String, String) {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join(name).to_string_lossy().into_owned();
        (tmp, db, "ab".repeat(32))
    }

    fn look_naming(hash: &str) -> String {
        overlay_look::normalize(&format!(r#"{{"stamp":5,"states":{{"idle":"{hash}"}}}}"#)).unwrap()
    }

    /// `m` on the overlay of the store at `db`, with a fetched look and a pick, each
    /// naming an image of its own; returns the two image hashes.
    fn listed_with_images(db: &str, pass: &str, m: &str) -> (String, String) {
        let st = MessageStore::open(db, pass).unwrap();
        st.save_profile_card(m, "Mal", 1, "", None).unwrap();
        st.overlay_add_person(m, 1).unwrap();
        let (theirs, pick) = ("e".repeat(64), "f".repeat(64));
        st.save_overlay_blob(&theirs, b"RIFF....WEBP", false).unwrap();
        st.save_overlay_blob(&pick, b"RIFF....WEBQ", false).unwrap();
        st.overlay_set_their_look(m, Some(&look_naming(&theirs)), 5).unwrap();
        st.overlay_set_local_look(m, Some(&look_naming(&pick))).unwrap();
        (theirs, pick)
    }

    /// Blocking someone takes them off our overlay as `off` does, with the look we
    /// fetched and our picks, even when the block lands outside the event loop (the
    /// FFI, a sibling's block on the blocking pool): the loop still emits the removal.
    #[tokio::test]
    async fn a_block_takes_the_person_off_and_the_loop_hears_it() {
        let (_tmp, db, pass) = file_store("block.db");
        let m = keypair(91).peer_id();
        let (theirs, pick) = listed_with_images(&db, &pass, &m);
        let (d, p, who) = (db.clone(), pass.clone(), m.clone());
        std::thread::spawn(move || {
            let st = MessageStore::open(&d, &p).unwrap();
            forget_blocked(&st, &who);
            forget_blocked(&st, "never-listed");
        })
        .join()
        .unwrap();
        let st = MessageStore::open(&db, &pass).unwrap();
        assert!(st.overlay_person(&m).unwrap().is_none(), "a blocked person stayed on our overlay");
        assert!(!st.has_overlay_blob(&theirs).unwrap() && !st.has_overlay_blob(&pick).unwrap(), "their images stayed");

        let key = notice_key(&db);
        assert!(has_notices(&key), "a block outside the loop left the loop nothing");
        let (ev_tx, mut ev_rx) = mpsc::channel(8);
        let mut book = OverlayBook::new();
        react_to_notices_inner(&mut book, &key, &ev_tx, "me", &db, &pass).await;
        assert!(matches!(ev_rx.try_recv(), Ok(NetworkEvent::OverlayPersonRemoved { master }) if master == m));
        assert!(ev_rx.try_recv().is_err(), "someone never listed was announced as removed");
    }

    /// A field written outside the event loop's task (a push fetch, spawned work)
    /// reaches the loop of the same profile, and only that one.
    #[tokio::test]
    async fn a_field_ingested_off_the_loop_reaches_its_loop() {
        let (_tmp, db, pass) = file_store("field.db");
        let (_other_tmp, other_db, _) = file_store("other.db");
        let owner = keypair(92);
        let m = owner.peer_id();
        listed_with_images(&db, &pass, &m);
        let (d, p, who) = (db.clone(), pass.clone(), m.clone());
        let field = sign_field(&owner, FieldValue::Off, 100);
        std::thread::spawn(move || {
            let st = MessageStore::open(&d, &p).unwrap();
            assert!(ingest_field(&st, &who, Some(&field), i64::MAX, None));
        })
        .join()
        .unwrap();
        assert!(!has_notices(&notice_key(&other_db)), "another profile's loop heard it");
        let (ev_tx, mut ev_rx) = mpsc::channel(8);
        let key = notice_key(&db);
        react_to_notices_inner(&mut OverlayBook::new(), &key, &ev_tx, "me", &db, &pass).await;
        let mut heard = Vec::new();
        while let Ok(ev) = ev_rx.try_recv() {
            heard.push(ev);
        }
        assert!(heard.iter().any(|e| matches!(e, NetworkEvent::OverlayPersonRemoved { master } if *master == m)), "{} events", heard.len());
        assert!(heard.iter().any(|e| matches!(e, NetworkEvent::OverlayFieldChanged { master } if *master == m)), "{} events", heard.len());
        assert!(!has_notices(&key), "drained");
    }

    /// The block FFI and a block our own device shares both take the person off.
    #[test]
    fn the_block_ffi_and_a_siblings_block_take_the_person_off() {
        let _g = crate::node::resolver::test_lock();
        let _st = crate::api::storage::store_test_lock();
        let (by_ffi, by_sibling) = (keypair(93).peer_id(), keypair(94).peer_id());
        let (_tmp, db, pass) = file_store("blocks.db");
        listed_with_images(&db, &pass, &by_ffi);
        listed_with_images(&db, &pass, &by_sibling);

        crate::api::storage::set_test_store(MessageStore::open(&db, &pass).unwrap());
        let ffi = crate::api::storage::block_peer(by_ffi.clone());
        crate::api::storage::set_test_store(MessageStore::open(":memory:", &pass).unwrap());
        crate::node::blocklist::unblock(&by_ffi);
        ffi.unwrap();

        let entry = super::super::types::BlockEntry { peer_id: by_sibling.clone(), blocked: true, at: 1_000 };
        let changed = super::super::social::take_sibling_blocks(&[entry], i64::MAX, "me", &db, &pass);
        assert_eq!(changed, vec![(by_sibling.clone(), true)], "precondition: the sibling's block landed");

        let st = MessageStore::open(&db, &pass).unwrap();
        assert!(st.overlay_person(&by_ffi).unwrap().is_none(), "the block FFI left them on our overlay");
        assert!(st.overlay_person(&by_sibling).unwrap().is_none(), "a sibling's block left them on our overlay");
    }

    /// A want already in the book asks nobody once its person is blocked, before the
    /// next reload of the wants drops it.
    #[test]
    fn a_want_for_someone_blocked_asks_nobody() {
        let _g = crate::node::resolver::test_lock();
        let m = keypair(95).peer_id();
        let dev = keypair(96).peer_id();
        crate::node::resolver::update(&dev, &m);
        let rooms: HashMap<String, HashSet<String>> = [("dm".to_string(), [dev.clone()].into())].into();
        let asks = |blocked: bool| {
            let mut book = OverlayBook::new();
            book.wants.insert(m.clone(), Want::new(5, None, Vec::new()));
            let (tx, mut rx) = mpsc::unbounded_channel();
            if blocked {
                crate::node::blocklist::block(&m);
            }
            dispatch(&mut book, &tx, &rooms, "me-dev");
            crate::node::blocklist::unblock(&m);
            let mut n = 0;
            while rx.try_recv().is_ok() {
                n += 1;
            }
            n
        };
        let (open, blocked) = (asks(false), asks(true));
        crate::node::resolver::forget(&dev);
        assert_eq!(open, 1, "CONTROL: the device is asked");
        assert_eq!(blocked, 0, "a blocked person was asked for a look");
    }

    /// One built announce, each peer given what our profile audience lets it see.
    #[test]
    fn an_announce_gives_each_peer_what_it_may_see() {
        use super::super::social::Audience;
        let _g = crate::node::resolver::test_lock();
        let profile = HavenMessage::OverlayLookAsk { held: vec!["profile".into()] };
        let is_profile = |m: Option<HavenMessage>| matches!(m, Some(HavenMessage::OverlayLookAsk { held }) if held == ["profile"]);
        let built = BuiltAnnounce {
            profile: Some(profile),
            card: Some(super::super::types::SignedCard { master: "me".into(), ..Default::default() }),
            roster: Some(crate::identity::roster::Roster::default()),
            removed: ["gone-dev".to_string()].into(),
            friend_status: [
                ("pal".to_string(), Some("accepted".to_string())),
                ("asking".to_string(), Some("pending".to_string())),
            ]
            .into(),
            ..Default::default()
        };
        assert!(
            matches!(announce_for("gone-dev", Some(Audience::Full), &built), Some(HavenMessage::RosterNotice { .. })),
            "a removed device hears only our roster"
        );
        assert!(is_profile(announce_for("co-member", Some(Audience::Full), &built)));
        assert!(announce_for("stranger", Some(Audience::None), &built).is_none());
        assert!(is_profile(announce_for("pal", None, &built)), "an accepted friend the state could not place");
        assert!(
            matches!(announce_for("asking", None, &built), Some(HavenMessage::ProfileCard { .. })),
            "a pending friend gets the card"
        );
        assert!(announce_for("unknown", None, &built).is_none(), "no friend row, nothing");
    }
}

// so-final-review
#[cfg(test)]
mod so_final_review_tests {
    use super::*;

    fn keypair(seed: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[seed; 32])
    }

    fn file_store(name: &str) -> (crate::test_tmp::TestDir, String, String) {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join(name).to_string_lossy().into_owned();
        (tmp, db, "ab".repeat(32))
    }

    fn webp_still(shade: u8) -> Vec<u8> {
        let img = image::RgbaImage::from_pixel(64, 64, image::Rgba([shade, 40, 90, 255]));
        let mut png = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        super::super::image_convert::process_overlay_image(&png).unwrap().0
    }

    /// A person turns "Share my overlay images" off (their field now says `show`)
    /// while an answer to our earlier ask is still on its way (another of their
    /// devices had not heard yet, or the ask was in flight). That answer must not
    /// put the look back: `show` means their images are no longer ours to draw.
    #[test]
    fn so_final_an_answer_after_sharing_turned_off_keeps_no_look() {
        let (_tmp, db, pass) = file_store("share_off_race.db");
        let store = MessageStore::open(&db, &pass).unwrap();
        let owner = keypair(201);
        let m = owner.peer_id();
        store.save_profile_card(&m, "Owen", 1, "", None).unwrap();
        store.overlay_add_person(&m, 1).unwrap();
        assert!(ingest_field(&store, &m, Some(&sign_field(&owner, FieldValue::Share(5), 10)), i64::MAX, None));
        // Sharing turned off: the field now says `show`.
        assert!(ingest_field(&store, &m, Some(&sign_field(&owner, FieldValue::Show, 20)), i64::MAX, None));
        assert_eq!(field_of(&store, &m), FieldValue::Show, "precondition: their field says show");

        let image = webp_still(7);
        use sha2::{Digest, Sha256};
        let hash = hex::encode(Sha256::digest(&image));
        let look = overlay_look::normalize(&format!(r#"{{"stamp":5,"states":{{"idle":"{hash}"}}}}"#)).unwrap();
        let bundle = String::from_utf8(crate::api::showcase::encode_asset_bundle(&[(hash.clone(), image)])).unwrap();
        // The late answer from a device we asked while the field still said share.
        let _ = apply_answer(&store, "me-master", &m, "share", &look, &bundle);

        let row = store.overlay_person(&m).unwrap().unwrap();
        assert_eq!(row.their_look, None, "a look the owner stopped sharing was stored and will be drawn on stream");
        assert!(!store.has_overlay_blob(&hash).unwrap(), "the image of a look the owner stopped sharing was stored");
    }

    /// Notices are dropped past 256 per profile. Strangers can each make one (a
    /// friend request card with its own signed field), so a burst crowds out the
    /// one notice that says a person ON our overlay turned "Let others show me"
    /// off, and Dart never hears to publish a new snapshot.
    #[test]
    fn so_final_a_strangers_burst_never_hides_an_off_from_dart() {
        let (_tmp, db, pass) = file_store("notice_flood.db");
        let store = MessageStore::open(&db, &pass).unwrap();
        let key = notice_key(&store.db_file());
        let _ = take_notices(&key);
        let pal = keypair(202);
        store.save_profile_card(&pal.peer_id(), "Pal", 1, "", None).unwrap();
        store.overlay_add_person(&pal.peer_id(), 1).unwrap();
        for i in 0..MAX_QUEUED_NOTICES {
            let mut seed = [0u8; 32];
            seed[..8].copy_from_slice(&(i as u64 + 10_000).to_le_bytes());
            let stranger = NativeKeypair::from_secret_bytes(&seed);
            store.save_profile_card(&stranger.peer_id(), "S", 1, "", None).unwrap();
            assert!(ingest_field(&store, &stranger.peer_id(), Some(&sign_field(&stranger, FieldValue::Show, 5)), i64::MAX, None));
        }
        assert!(ingest_field(&store, &pal.peer_id(), Some(&sign_field(&pal, FieldValue::Off, 30)), i64::MAX, None));
        assert!(store.overlay_person(&pal.peer_id()).unwrap().is_none(), "precondition: the store took them off");
        let notices = take_notices(&key);
        assert!(
            notices.iter().any(|n| n.master == pal.peer_id() && n.removed),
            "the removal of a person on our overlay never reaches Dart ({} notices queued)",
            notices.len()
        );
    }
}

// so-review-fix
#[cfg(test)]
mod so_review_fix_tests {
    use super::*;

    fn keypair(seed: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[seed; 32])
    }

    fn file_store(name: &str) -> (crate::test_tmp::TestDir, String, String) {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join(name).to_string_lossy().into_owned();
        (tmp, db, "ab".repeat(32))
    }

    fn look_naming(hash: &str) -> String {
        overlay_look::normalize(&format!(r#"{{"stamp":5,"states":{{"idle":"{hash}"}}}}"#)).unwrap()
    }

    /// What the OBS page may draw for someone: our picks always, their own look
    /// only while their field says `share`, nothing for someone not on our overlay.
    #[test]
    fn drawable_images_follow_the_field_and_our_picks() {
        let (_tmp, db, pass) = file_store("drawable.db");
        let st = MessageStore::open(&db, &pass).unwrap();
        let owner = keypair(211);
        let m = owner.peer_id();
        assert!(drawable_images(&st, &m).is_empty(), "not on our overlay");
        st.save_profile_card(&m, "Dee", 1, "", None).unwrap();
        st.overlay_add_person(&m, 1).unwrap();
        assert!(ingest_field(&st, &m, Some(&sign_field(&owner, FieldValue::Share(5), 10)), i64::MAX, None));
        let (theirs, pick) = ("c".repeat(64), "d".repeat(64));
        st.overlay_set_their_look(&m, Some(&look_naming(&theirs)), 5).unwrap();
        st.overlay_set_local_look(&m, Some(&look_naming(&pick))).unwrap();
        assert_eq!(drawable_images(&st, &m), HashSet::from([theirs.clone(), pick.clone()]));
        assert!(ingest_field(&st, &m, Some(&sign_field(&owner, FieldValue::Show, 20)), i64::MAX, None));
        // Their look held anyway (written before this check existed, say): still not drawn.
        st.overlay_set_their_look(&m, Some(&look_naming(&theirs)), 5).unwrap();
        assert_eq!(drawable_images(&st, &m), HashSet::from([pick]), "a look shared no longer is drawn");
    }

    /// Past the cap, a plain notice is dropped and marks the queue lost: the loop then
    /// tells Dart to re-read everyone (an empty master) and pulls our own look again,
    /// since the dropped notice may have been our own field from a sibling.
    #[tokio::test]
    async fn a_dropped_notice_makes_the_loop_tell_dart_to_reread_everyone() {
        let (_tmp, db, pass) = file_store("lost.db");
        let st = MessageStore::open(&db, &pass).unwrap();
        let key = notice_key(&st.db_file());
        let _ = drain_notices(&key);
        for i in 0..=MAX_QUEUED_NOTICES {
            push_notice(&st, FieldNotice { master: format!("s{i}"), from_device: None, value_changed: false, removed: false });
        }
        assert!(notice_queues().lock().unwrap().get(&key).is_some_and(|q| q.lost), "the overflow left no mark");
        let (ev_tx, mut ev_rx) = mpsc::channel(4);
        let mut book = OverlayBook::new();
        react_to_notices_inner(&mut book, &key, &ev_tx, "me", &db, &pass).await;
        assert!(
            matches!(ev_rx.try_recv(), Ok(NetworkEvent::OverlayFieldChanged { master }) if master.is_empty()),
            "Dart never heard to re-read"
        );
        assert!(book.wants.contains_key("me"), "our own look is not pulled again");
        assert!(!has_notices(&key), "the mark outlived the drain");
    }

    /// A block of someone never added still wakes the loop, which re-projects the OBS
    /// page (they may stand in the room), and tells Dart nothing.
    #[tokio::test]
    async fn a_block_of_someone_never_added_still_wakes_the_loop() {
        let (_tmp, db, pass) = file_store("block_wake.db");
        let st = MessageStore::open(&db, &pass).unwrap();
        let key = notice_key(&st.db_file());
        let _ = drain_notices(&key);
        forget_blocked(&st, "neveradded1");
        assert!(has_notices(&key), "the loop was not woken");
        let (ev_tx, mut ev_rx) = mpsc::channel(4);
        react_to_notices_inner(&mut OverlayBook::new(), &key, &ev_tx, "me", &db, &pass).await;
        assert!(ev_rx.try_recv().is_err(), "a person never added was announced");
    }

    /// The loop re-projects the OBS page when a field changes: a friend whose field
    /// turns `off` leaves the page before Dart publishes again.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the server and the store are process-global
    async fn a_field_turned_off_leaves_the_page_before_dart_publishes() {
        let _s = super::super::overlay_server::test_serial();
        let _st = crate::api::storage::store_test_lock();
        let (_tmp, db, pass) = file_store("reproject.db");
        let owner = keypair(212);
        let m = owner.peer_id();
        {
            let st = MessageStore::open(&db, &pass).unwrap();
            st.save_profile_card(&m, "Ola", 1, "", None).unwrap();
            st.overlay_add_person(&m, 1).unwrap();
        }
        crate::api::storage::set_test_store(MessageStore::open(&db, &pass).unwrap());
        super::super::overlay_server::use_db_backend_for_test();
        let snapshot = serde_json::json!({ "people": [
            { "slot": 0, "is_self": true, "in_room": true, "name": "me" },
            { "slot": 3, "master": m, "in_room": true, "added": true, "name": "Ola" }
        ] })
        .to_string();
        super::super::overlay_server::publish(&snapshot).unwrap();
        let before = super::super::overlay_server::snapshot_slots_for_test();
        let key = notice_key(&db);
        let _ = drain_notices(&key);
        {
            let st = MessageStore::open(&db, &pass).unwrap();
            assert!(ingest_field(&st, &m, Some(&sign_field(&owner, FieldValue::Off, 30)), i64::MAX, None));
        }
        let (ev_tx, _ev_rx) = mpsc::channel(8);
        react_to_notices_inner(&mut OverlayBook::new(), &key, &ev_tx, "me", &db, &pass).await;
        let after = super::super::overlay_server::snapshot_slots_for_test();
        super::super::overlay_server::stop_for_wipe();
        crate::api::storage::set_test_store(MessageStore::open(":memory:", &pass).unwrap());
        assert_eq!(before, Some(vec![0, 3]), "CONTROL: the friend was on the page");
        assert_eq!(after, Some(vec![0]), "a person whose field turned off stayed on the page");
    }
}
