//! A device removal reaches contacts that missed it (AR-29). Every DM carries its
//! sender's roster digests inside the Olm plaintext; a receiver whose view differs
//! trades views with the sender over Olm. Each device of a contact confirms our view of
//! its roster on its own; once one has not for [`ROSTER_REFRESH_AFTER_MS`], the next DM
//! to the contact waits up to [`DM_HOLD_MAX_MS`] while that device is asked.
//!
//! Fan-out always follows the newest roster that verified: a removal applies the moment
//! it arrives (`roster_book::save`). Two contacts holding different rosters for one
//! identity is not detected here; that needs contacts to gossip.

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use crate::identity::roster::{self, Removal, Roster};
use crate::storage::MessageStore;

use super::olm_lane::{self, NoSession};
use super::roster_book::Reconciled;
use super::social::Audience;
use super::types::{HavenMessage, NodeCommand, RosterDigests, WsCmdTx, WsRoomPeers};

/// A contact device that has not confirmed our view of its roster this long is asked
/// for it again before the next DM to its identity, once per this long.
pub(crate) const ROSTER_REFRESH_AFTER_MS: i64 = 35 * 24 * 60 * 60 * 1000;
/// Longest a DM waits for the devices a stale roster asked. It always goes out after.
pub(crate) const DM_HOLD_MAX_MS: i64 = 10_000;
/// At most one mismatch ask about one roster to one device this often.
pub(crate) const ROSTER_ASK_GAP_MS: i64 = 10 * 60 * 1000;
/// At most one answer about one roster to one device this often.
pub(crate) const ROSTER_ANSWER_GAP_MS: i64 = 60 * 1000;
/// How long a mismatch ask or its answer waits, so its size and time do not pin it to
/// the DM that caused it. An ask a DM waits for never waits.
pub(crate) const MISMATCH_JITTER_MS: (u64, u64) = (1_000, 30_000);
/// A removal rides our DMs at most this long after we learned it, whoever confirmed it.
pub(crate) const CARRY_MAX_AGE_MS: i64 = 90 * 24 * 60 * 60 * 1000;
/// Roster asks the push fetch notes for the node at most.
pub(crate) const ASKS_DUE_CAP: usize = 256;
/// A refresh asks at most this many of the identity's devices at once.
const MAX_REFRESH_ASKS: usize = 8;
/// Most gate entries kept; past it the oldest go first.
const GATES_CAP: usize = 4096;
const HOLD_POLL: Duration = Duration::from_millis(50);

/// Last pass per gate key, in Unix ms.
#[derive(Default)]
struct GateBook(HashMap<String, i64>);

impl GateBook {
    fn pass(&mut self, key: String, gap_ms: i64, now: i64) -> bool {
        let gates = &mut self.0;
        if gates.get(&key).is_some_and(|at| now.saturating_sub(*at) < gap_ms && *at <= now) {
            return false;
        }
        if !gates.contains_key(&key) && gates.len() >= GATES_CAP {
            gates.retain(|_, at| now.saturating_sub(*at) < ROSTER_ASK_GAP_MS && *at <= now);
            while gates.len() >= GATES_CAP {
                let Some(oldest) = gates.iter().min_by_key(|(_, at)| **at).map(|(k, _)| k.clone()) else { break };
                gates.remove(&oldest);
            }
        }
        gates.insert(key, now);
        true
    }
}

/// Keys start with OUR device id, so nodes sharing one process (the harness) never
/// share a gate.
static GATES: OnceLock<Mutex<GateBook>> = OnceLock::new();

fn pass_gate(key: String, gap_ms: i64, now: i64) -> bool {
    GATES.get_or_init(Default::default).lock().is_ok_and(|mut gates| gates.pass(key, gap_ms, now))
}

#[cfg(not(test))]
fn jitter_range() -> (u64, u64) {
    MISMATCH_JITTER_MS
}

/// The harness waits for these, so they stay short there unless a test sets them.
#[cfg(test)]
static TEST_JITTER: Mutex<Option<(u64, u64)>> = Mutex::new(None);

#[cfg(test)]
fn jitter_range() -> (u64, u64) {
    TEST_JITTER.lock().ok().and_then(|j| *j).unwrap_or((20, 200))
}

/// A test that needs the trade's real delay sets it; `clear_for_test` resets it.
#[cfg(test)]
pub(crate) fn set_jitter_for_test(range: (u64, u64)) {
    if let Ok(mut j) = TEST_JITTER.lock() {
        *j = Some(range);
    }
}

fn pick_jitter((lo, hi): (u64, u64), random: u64) -> Duration {
    Duration::from_millis(lo + random % (hi - lo + 1))
}

fn jitter() -> Duration {
    let mut buf = [0u8; 8];
    let _ = getrandom::fill(&mut buf);
    pick_jitter(jitter_range(), u64::from_le_bytes(buf))
}

/// Carry `msg` to `to` after `delay`, off the caller's turn.
fn carry_later(ws_cmd_tx: &WsCmdTx, to: &str, msg: HavenMessage, delay: Duration) {
    let Ok(rt) = tokio::runtime::Handle::try_current() else {
        olm_lane::carry(ws_cmd_tx, to, None, &msg, NoSession::Queue);
        return;
    };
    let (tx, to) = (ws_cmd_tx.clone(), to.to_string());
    rt.spawn(async move {
        tokio::time::sleep(delay).await;
        olm_lane::carry(&tx, &to, None, &msg, NoSession::Queue);
    });
}

/// The digest of the roster `store` holds for `master`. Read as stored, not verified
/// again: every DM computes two of these, and only verified statements are ever saved.
fn held_digest(store: &MessageStore, master: &str) -> Option<String> {
    store.load_roster(master).ok().flatten().filter(|r| r.master == master).map(|r| r.digest())
}

/// What a received digest says against ours.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Seen {
    /// No digest, or not one in shape: a 0.12.1 sender. Never a mismatch.
    Unknown,
    Same,
    Differs,
}

pub(crate) fn judge(held: Option<&str>, wire: Option<&str>) -> Seen {
    match wire {
        Some(w) if roster::is_digest_shape(w) => {
            if held == Some(w) { Seen::Same } else { Seen::Differs }
        }
        _ => Seen::Unknown,
    }
}

/// The digests a DM to `recipient_master` carries, and our recent removals when our
/// profile audience for the recipient may hear our roster at all (as `may_answer`).
/// `audience` is asked only when there is something to carry.
pub(crate) fn for_dm(
    local_master: &str,
    recipient_master: &str,
    audience: impl FnOnce(&MessageStore) -> Audience,
    db_path: &str,
    db_passphrase: &str,
) -> Option<RosterDigests> {
    let store = MessageStore::lease(db_path, db_passphrase).ok()?;
    let own_roster = store.load_roster(local_master).ok().flatten().filter(|r| r.master == local_master);
    let own = own_roster.as_ref().map(Roster::digest);
    let peer = (recipient_master != local_master).then(|| held_digest(&store, recipient_master)).flatten();
    let rm = match (&own_roster, &own) {
        (Some(r), Some(d)) if recipient_master != local_master => {
            let rm = carried_for(&store, r, d, recipient_master);
            if rm.is_empty() || audience(&store) == Audience::None { Vec::new() } else { rm }
        }
        _ => Vec::new(),
    };
    (own.is_some() || peer.is_some()).then_some(RosterDigests { own, peer, rm })
}

/// Our counting removals a DM to `contact` carries (F2): those we learned after the
/// newest DM of EACH of its devices showed it held our roster (one device that caught up
/// says nothing of a sibling asleep), newest first, none older than
/// [`CARRY_MAX_AGE_MS`], as many as [`roster::carried_fits`] allows. Every counting
/// removal of one device travels together, so the HOL-SEC-080 intersection sees them.
/// Reads only, but for a removal no `save` dated (stored before 0.13).
fn carried_for(store: &MessageStore, own: &Roster, own_digest: &str, contact: &str) -> Vec<Removal> {
    let confirms = store.carry_confirms(contact);
    let mut devices: Vec<String> = store.device_links_for(contact).unwrap_or_default().into_iter().collect();
    if devices.is_empty() {
        devices = confirms.keys().cloned().collect();
    }
    let held: Vec<Option<&(String, i64)>> = devices.iter().map(|d| confirms.get(d)).collect();
    if !held.is_empty() && held.iter().all(|c| c.is_some_and(|(digest, _)| digest == own_digest)) {
        return Vec::new();
    }
    let groups = counting_groups(store, own, own_digest);
    if groups.is_empty() {
        return Vec::new();
    }
    let confirmed_at = held.iter().map(|c| c.map_or(i64::MIN, |(_, at)| *at)).min().unwrap_or(i64::MIN);
    let now = super::roster_book::now_ms();
    let base = own.base();
    let mut since = store.removal_carried_at(&own.master, &base).unwrap_or_default();
    let undated: Vec<String> = groups.iter().map(|(d, _)| d).filter(|d| !since.contains_key(*d)).cloned().collect();
    if !undated.is_empty() && store.stamp_removal_carried(&own.master, &base, &undated, now).is_ok() {
        since.extend(undated.into_iter().map(|d| (d, now)));
    }
    let mut picked: Vec<(i64, &String, &Vec<Removal>)> = groups
        .iter()
        .filter_map(|(device, removals)| {
            let at = *since.get(device)?;
            (at > confirmed_at && now.saturating_sub(at) < CARRY_MAX_AGE_MS).then_some((at, device, removals))
        })
        .collect();
    picked.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(b.1)));
    let mut out = Vec::new();
    'fill: for (_, _, removals) in picked {
        for r in removals {
            out.push(r.clone());
            if !roster::carried_fits(&out) {
                out.pop();
                break 'fill;
            }
        }
    }
    out
}

type Groups = Vec<(String, Vec<Removal>)>;

/// Counting removals by removed device, per (master, raw digest, hour): the fold
/// behind them runs once per roster change, not once per DM.
type GroupCache = HashMap<String, (String, i64, Groups)>;
static GROUPS: OnceLock<Mutex<GroupCache>> = OnceLock::new();

fn counting_groups(store: &MessageStore, own: &Roster, own_digest: &str) -> Groups {
    let hour = super::roster_book::now_ms() / 3_600_000;
    let cache = || GROUPS.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner());
    if let Some((_, _, groups)) = cache().get(&own.master).filter(|(d, h, _)| d == own_digest && *h == hour) {
        return groups.clone();
    }
    let mut groups: Groups = Vec::new();
    for r in super::roster_book::counting_removals(store, own) {
        match groups.iter_mut().find(|(device, _)| *device == r.device) {
            Some((_, removals)) => removals.push(r),
            None => groups.push((r.device.clone(), vec![r])),
        }
    }
    cache().insert(own.master.clone(), (own_digest.to_string(), hour, groups.clone()));
    groups
}

/// Whether a DM's carried removals hold any statement the roster stored for `master`
/// lacks. Read raw (saved rosters were verified): nothing to fold, nothing re-verified.
/// A master we hold no roster for is never news (no first sight from a part).
pub(crate) fn carried_news(store: &MessageStore, master: &str, rm: &[Removal]) -> bool {
    // Over the count bound the field is ignored whole, before any scan.
    if rm.len() > roster::MAX_CARRIED_REMOVALS {
        hollow_log!("[HOLLOW-SECURITY] Ignored {} carried removal(s) for {master}: over the bound", rm.len());
        return false;
    }
    !rm.is_empty()
        && store
            .load_roster(master)
            .ok()
            .flatten()
            .filter(|held| held.master == master)
            .is_some_and(|held| rm.iter().any(|r| !held.removals.contains(r)))
}

/// Whether the DM `mid` is one we have not read before, judged before it is stored. A
/// copy sent again (a resend, a replay) says nothing new about anyone's roster. A row
/// an image header stored first carries no signature until its DM arrives.
pub(crate) fn first_signed_copy(store: &MessageStore, mid: Option<&str>) -> bool {
    mid.is_some_and(|m| store.get_dm_message_sig_row(m).is_none_or(|row| row.signature.is_none()))
}

/// `device` showed us `master`'s roster and we now hold all of it.
pub(crate) fn stamp(store: &MessageStore, master: &str, device: &str) {
    let _ = store.stamp_roster_confirmed(master, device, super::roster_book::now_ms());
}

/// A DM `device` sent at `sent_ms` showed us `master`'s roster and we hold all of it.
/// A DM sent before one that showed a difference confirms nothing.
fn stamp_from_dm(store: &MessageStore, master: &str, device: &str, sent_ms: i64) {
    let _ = store.stamp_roster_confirmed_by_dm(master, device, super::roster_book::now_ms(), sent_ms);
}

/// A DM `device` of `master` sent at `sent_ms` showed a roster we do not hold: until
/// it answers, the next DM to `master` waits for it (`hold_for_stale_roster`), else
/// that DM could reach a device the roster it showed has removed.
fn unconfirm(store: &MessageStore, master: &str, device: &str, sent_ms: i64) {
    let _ = store.unconfirm_roster(master, device, sent_ms);
}

/// How one device's confirmation of our view of its roster stands.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Slot {
    /// Never stamped: a device new to us, or one held before this check existed.
    New,
    Fresh,
    /// Unconfirmed too long; `ask_due` unless we asked it within the same span.
    Stale { ask_due: bool },
}

/// A stamp ahead of our clock by more than the skew counts as none.
pub(crate) fn slot(stamps: Option<(i64, Option<i64>)>, now: i64) -> Slot {
    let Some((confirmed, asked)) = stamps else { return Slot::New };
    let recent = |at: i64| at <= now.saturating_add(super::frame_auth::LIVE_SKEW_MS)
        && now.saturating_sub(at) < ROSTER_REFRESH_AFTER_MS;
    if recent(confirmed) {
        return Slot::Fresh;
    }
    Slot::Stale { ask_due: !asked.is_some_and(recent) }
}

/// Whether `to` may hear our view of `subject`'s roster: our own device hears any we
/// hold, a device of `subject` hears its own, and anyone our profile audience reaches
/// hears ours. Never an oracle for third parties.
pub(crate) fn may_answer(
    local_master: &str,
    local_device: &str,
    to: &str,
    subject: &str,
    audience: impl FnOnce() -> Audience,
) -> bool {
    if super::resolver::is_revoked(to) || super::blocklist::is_blocked(to) || to == local_device {
        return false;
    }
    super::resolver::is_device_of(to, local_master)
        || super::resolver::is_device_of(to, subject)
        || (subject == local_master && audience() != Audience::None)
}

/// A verified DM from `sender` (never a removed device: the DM arm drops those) that
/// we had not read before, signed as sent at `sent_ms`, carried `rd`. `own` is about the identity the sender belongs
/// to, `peer` about ours (on an echo from our own sibling, about the friend
/// `convo_peer`). A match on `own` confirms the sender's own slot; a mismatch either
/// way asks the sender for its view.
#[allow(clippy::too_many_arguments)]
pub(crate) fn on_dm(
    ws_cmd_tx: &WsCmdTx,
    store: &MessageStore,
    local_master: &str,
    local_device: &str,
    sender: &str,
    is_own_device: bool,
    convo_peer: &str,
    sent_ms: i64,
    rd: Option<&RosterDigests>,
    audience: &dyn Fn(&str) -> Audience,
) {
    let Some(rd) = rd else { return };
    // A device no roster counts speaks for no identity, not even its own id.
    if !super::resolver::is_device_of(sender, &super::resolver::resolve(sender)) {
        return;
    }
    let (own_subject, peer_subject) = if is_own_device { (local_master, convo_peer) } else { (convo_peer, local_master) };
    let now = super::roster_book::now_ms();
    match judge(held_digest(store, own_subject).as_deref(), rd.own.as_deref()) {
        Seen::Same if !is_own_device => stamp_from_dm(store, own_subject, sender, sent_ms),
        Seen::Differs => {
            if !is_own_device {
                unconfirm(store, own_subject, sender, sent_ms);
            }
            mismatch_ask(ws_cmd_tx, store, local_master, local_device, own_subject, sender, now, audience);
        }
        _ => {}
    }
    if peer_subject == own_subject {
        return;
    }
    // On an echo, `peer` is our sibling's view of the friend's roster: a sibling that
    // holds one we lack holds the next DM to the friend like a friend device would (B3 (a)).
    let held_peer = held_digest(store, peer_subject);
    match judge(held_peer.as_deref(), rd.peer.as_deref()) {
        Seen::Same if is_own_device => stamp_from_dm(store, peer_subject, sender, sent_ms),
        // The contact holds our roster as we do now: our DMs to it carry nothing older.
        Seen::Same => {
            if let Some(digest) = held_peer {
                let _ = store.set_carry_confirm(own_subject, sender, &digest, now);
            }
        }
        Seen::Differs => {
            if is_own_device {
                unconfirm(store, peer_subject, sender, sent_ms);
            }
            mismatch_ask(ws_cmd_tx, store, local_master, local_device, peer_subject, sender, now, audience);
        }
        _ => {}
    }
}

/// Send `to` our view of `subject`'s roster and ask for its view back, a moment later,
/// gated per (subject, `to`). Returns whether it was sent.
#[allow(clippy::too_many_arguments)]
fn mismatch_ask(
    ws_cmd_tx: &WsCmdTx,
    store: &MessageStore,
    local_master: &str,
    local_device: &str,
    subject: &str,
    to: &str,
    now: i64,
    audience: &dyn Fn(&str) -> Audience,
) -> bool {
    if !may_answer(local_master, local_device, to, subject, || audience(to)) {
        return false;
    }
    if !pass_gate(format!("{local_device}|ask|{subject}|{to}"), ROSTER_ASK_GAP_MS, now) {
        return false;
    }
    let roster = super::roster_book::load(store, subject).unwrap_or_else(|| Roster::new(subject));
    hollow_log!("[HOLLOW-ROSTER] Asking {to} for its view of {subject}'s roster");
    carry_later(ws_cmd_tx, to, HavenMessage::RosterSync { roster, reply: true, waiting: false }, jitter());
    true
}

/// `asker` sent us its view of `subject`'s roster and asked for ours (already merged
/// into what we hold): answer it, gated per (asker, subject); at once when a DM of its
/// waits for the answer, else a moment later.
#[allow(clippy::too_many_arguments)]
pub(crate) fn answer(
    ws_cmd_tx: &WsCmdTx,
    local_master: &str,
    local_device: &str,
    asker: &str,
    subject: &str,
    waiting: bool,
    audience: impl FnOnce() -> Audience,
    db_path: &str,
    db_passphrase: &str,
) {
    if !may_answer(local_master, local_device, asker, subject, audience) {
        hollow_log!("[HOLLOW-SECURITY] Left a roster ask from {asker} about {subject} unanswered");
        return;
    }
    let now = super::roster_book::now_ms();
    // A waiting ask has its own gate: an answer still sitting out its jitter must not
    // leave a held DM to run out first.
    let kind = if waiting { "answer-waiting" } else { "answer" };
    if !pass_gate(format!("{local_device}|{kind}|{asker}|{subject}"), ROSTER_ANSWER_GAP_MS, now) {
        return;
    }
    let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return };
    let Some(roster) = super::roster_book::load(&store, subject) else { return };
    let msg = HavenMessage::RosterSync { roster, reply: false, waiting: false };
    if waiting {
        olm_lane::carry(ws_cmd_tx, asker, None, &msg, NoSession::Queue);
    } else {
        carry_later(ws_cmd_tx, asker, msg, jitter());
    }
}

// -- The push fetch: it never talks back, so what it cannot do waits for the node --

/// A DM the push fetch read, signed as sent at `sent_ms`, carried `rd`: stamp the
/// sender's slot on a match, and note an ask for the node to send on a mismatch. The
/// fetch never reads our own echoes.
pub(crate) fn fetch_on_dm(
    store: &MessageStore,
    local_master: &str,
    sender: &str,
    convo: &str,
    sent_ms: i64,
    rd: Option<&RosterDigests>,
) {
    let Some(rd) = rd else { return };
    if !super::resolver::is_device_of(sender, convo) {
        return;
    }
    let now = super::roster_book::now_ms();
    match judge(held_digest(store, convo).as_deref(), rd.own.as_deref()) {
        Seen::Same => stamp_from_dm(store, convo, sender, sent_ms),
        Seen::Differs => {
            unconfirm(store, convo, sender, sent_ms);
            let _ = store.add_roster_ask_due(convo, sender, now, ASKS_DUE_CAP);
        }
        Seen::Unknown => {}
    }
    let held_own = held_digest(store, local_master);
    match judge(held_own.as_deref(), rd.peer.as_deref()) {
        Seen::Differs => {
            let _ = store.add_roster_ask_due(local_master, sender, now, ASKS_DUE_CAP);
        }
        Seen::Same => {
            if let Some(digest) = held_own {
                let _ = store.set_carry_confirm(convo, sender, &digest, now);
            }
        }
        Seen::Unknown => {}
    }
}

/// The removals a DM the push fetch read carried (F2): kept as a live DM's are, store
/// half only, before the DM's digests are judged.
#[allow(clippy::too_many_arguments)]
pub(crate) fn fetch_carried(
    store: &MessageStore,
    db_path: &str,
    db_passphrase: &str,
    local_master: &str,
    local_device: &str,
    sender: &str,
    convo: &str,
    rd: Option<&RosterDigests>,
) {
    let Some(rd) = rd else { return };
    if carried_news(store, convo, &rd.rm) {
        super::roster_book::ingest_carried_stored(db_path, db_passphrase, local_master, local_device, sender, convo, &rd.rm);
    }
}

/// A roster the push fetch decrypted (`RosterSync`) or heard (`RosterNotice`): keep
/// what verifies of a contact's, and note an ask for the node when the sender wants
/// our view or the roster is our own (only the node acts on our own).
pub(crate) fn fetch_roster(
    db_path: &str,
    db_passphrase: &str,
    local_master: &str,
    local_device: &str,
    sender: &str,
    roster: Roster,
    reply: bool,
) {
    let subject = roster.master.clone();
    let own = subject == local_master;
    super::roster_book::ingest_stored(db_path, db_passphrase, local_master, local_device, sender, roster);
    if (own || reply)
        && let Ok(store) = MessageStore::lease(db_path, db_passphrase)
    {
        let _ = store.add_roster_ask_due(&subject, sender, super::roster_book::now_ms(), ASKS_DUE_CAP);
    }
}

/// On every relay session (fresh or resumed): follow the contact rosters another
/// process changed in the store, then send the asks the push fetch noted, under the
/// same rules as any mismatch ask. Returns what was followed, for the caller to drop
/// the removed devices' sessions and leaves and to tell the app.
pub(crate) fn send_due_asks(
    ws_cmd_tx: &WsCmdTx,
    local_master: &str,
    local_device: &str,
    db_path: &str,
    db_passphrase: &str,
    audience: &dyn Fn(&str) -> Audience,
) -> Reconciled {
    let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return Reconciled::default() };
    let revoked = super::roster_book::reconcile_dirty(&store, None, local_master, local_device);
    let now = super::roster_book::now_ms();
    for (subject, device) in store.take_roster_asks_due() {
        mismatch_ask(ws_cmd_tx, &store, local_master, local_device, &subject, &device, now, audience);
    }
    revoked
}

// -- The hold: a DM to a roster gone stale waits for the devices asked --

/// A DM fan-out kept back while a stale roster is asked for, in send order.
pub(crate) enum HeldDm {
    Envelope { envelope_json: String, sibling_json: Option<String> },
    File(Box<super::file_handler::HeldFileDm>),
}

struct Hold {
    /// Devices asked that are online, so may answer within the hold.
    waiting: HashSet<String>,
    queue: Vec<HeldDm>,
    /// Set while the relay has not listed the DM room this session: the asks wait for
    /// the listing, and the hold's clock with them.
    unplaced: Option<Unplaced>,
    /// What following the store did before the hold, for the release to act on.
    reconciled: Reconciled,
}

struct Unplaced {
    /// Tells this wait from a later one under the same key.
    id: u64,
    dm_room: String,
    asks: Vec<String>,
}

/// Holds by `"{our device}|{master}"`.
static HOLDS: OnceLock<Mutex<HashMap<String, Hold>>> = OnceLock::new();

fn holds() -> std::sync::MutexGuard<'static, HashMap<String, Hold>> {
    HOLDS.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner())
}

/// Our relay session as the hold sees it.
#[derive(Default)]
struct Session {
    up: bool,
    /// Moves with every session that comes up, so a backstop armed for an earlier one
    /// leaves the wait to the backstop the new one arms.
    epoch: u64,
    /// Rooms the relay listed (RoomMembers) this session. A room whose last peer left
    /// stays: `ws_room_peers` drops it, but its presence is still known.
    listed: HashSet<String>,
}

/// Sessions by our device id.
static SESSIONS: OnceLock<Mutex<HashMap<String, Session>>> = OnceLock::new();

fn sessions() -> std::sync::MutexGuard<'static, HashMap<String, Session>> {
    SESSIONS.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner())
}

fn listed(local_device: &str, room: &str) -> bool {
    sessions().get(local_device).is_some_and(|s| s.listed.contains(room))
}

fn next_wait_id() -> u64 {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
}

/// Whether the fan-out goes now or was kept back.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Gate {
    Go,
    Held,
}

/// Every DM fan-out to `master` asks this first. A DM already held for `master` queues
/// behind it. Else each target device of `master` whose slot ran out, and each sibling
/// of ours whose echo showed a roster of `master` we lack, is asked for the roster (once
/// per [`ROSTER_REFRESH_AFTER_MS`]); while one of those is online the DM waits for its
/// answer, at most [`DM_HOLD_MAX_MS`], and `NodeCommand::ReleaseHeldDms` sends it. A
/// device never stamped starts its clock and is not asked.
#[allow(clippy::too_many_arguments)]
pub(crate) fn hold_for_stale_roster(
    ws_cmd_tx: &WsCmdTx,
    cmd_tx: &tokio::sync::mpsc::Sender<NodeCommand>,
    ws_room_peers: &WsRoomPeers,
    local_device: &str,
    master: &str,
    targets: &[String],
    dm_room: &str,
    db_path: &str,
    db_passphrase: &str,
    dm: impl FnOnce() -> HeldDm,
) -> Gate {
    let key = format!("{local_device}|{master}");
    if let Some(hold) = holds().get_mut(&key) {
        hold.queue.push(dm());
        return Gate::Held;
    }
    let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return Gate::Go };
    let own_master = super::resolver::resolve(local_device);
    // Another process (the push fetch, the iOS NSE) stored a roster change this
    // process's resolver has not seen: follow it, and the release sends the DM again on
    // fresh targets once the removed devices' sessions are gone.
    if store.roster_dirty(master) {
        let reconciled = super::roster_book::reconcile_dirty(&store, Some(master), &own_master, local_device);
        hollow_log!("[HOLLOW-ROSTER] {master}'s stored roster moved under us: the DM goes to its members as stored");
        holds().insert(key.clone(), Hold { waiting: HashSet::new(), queue: vec![dm()], unplaced: None, reconciled });
        run_hold(key, master, &own_master, cmd_tx);
        return Gate::Held;
    }
    let now = super::roster_book::now_ms();
    let (asks, new) = stale_asks(&store.roster_confirm_slots(master), targets, master, &own_master, local_device, now);
    for device in &new {
        stamp(&store, master, device);
    }
    if asks.is_empty() {
        return Gate::Go;
    }
    // Before the relay lists the DM room this session, a DM would go out the moment
    // the socket opens, ahead of any answer: it waits for the listing
    // (`on_room_listed`), or DM_HOLD_MAX_MS of a session that never lists it.
    if !listed(local_device, dm_room) {
        hollow_log!("[HOLLOW-ROSTER] {master}'s roster is unconfirmed and the DM room is not listed yet: holding the DM");
        let id = next_wait_id();
        let unplaced = Unplaced { id, dm_room: dm_room.to_string(), asks };
        holds().insert(key.clone(), Hold { waiting: HashSet::new(), queue: vec![dm()], unplaced: Some(unplaced), reconciled: Reconciled::default() });
        let epoch = sessions().get(local_device).filter(|s| s.up).map(|s| s.epoch);
        if let Some(epoch) = epoch {
            arm_backstop(ws_cmd_tx, cmd_tx, local_device, key, id, epoch, db_path, db_passphrase);
        }
        return Gate::Held;
    }
    hollow_log!("[HOLLOW-ROSTER] {master}'s roster is unconfirmed: asking {} device(s) before the DM", asks.len());
    send_asks(ws_cmd_tx, &store, master, &asks, dm_room, now);
    let waiting = online(ws_room_peers, &asks);
    if waiting.is_empty() {
        return Gate::Go;
    }
    holds().insert(key.clone(), Hold { waiting, queue: vec![dm()], unplaced: None, reconciled: Reconciled::default() });
    run_hold(key, master, &own_master, cmd_tx);
    Gate::Held
}

/// Which devices a DM to `master` waits on, from `slots` (our confirmation rows for
/// `master`, keyed by device): each target of `master` whose slot ran out, then each
/// sibling of ours whose echo voided its view of `master`. Also the targets never
/// stamped, whose clock starts now. A row is a sibling's only while the device is ours.
fn stale_asks(
    slots: &HashMap<String, (i64, Option<i64>)>,
    targets: &[String],
    master: &str,
    own_master: &str,
    local_device: &str,
    now: i64,
) -> (Vec<String>, Vec<String>) {
    let (mut asks, mut new) = (Vec::new(), Vec::new());
    for device in targets {
        if !super::resolver::is_device_of(device, master) || super::resolver::is_revoked(device) {
            continue;
        }
        match slot(slots.get(device).copied(), now) {
            Slot::New => new.push(device.clone()),
            Slot::Stale { ask_due: true } if asks.len() < MAX_REFRESH_ASKS => asks.push(device.clone()),
            _ => {}
        }
    }
    // A sibling's slot only ever holds once its echo voided it: one aged out says nothing.
    let mut siblings: Vec<&String> = slots
        .iter()
        .filter(|(device, stamps)| {
            device.as_str() != local_device
                && is_sibling(device, own_master)
                && stamps.0 == 0
                && slot(Some(**stamps), now) == Slot::Stale { ask_due: true }
        })
        .map(|(device, _)| device)
        .collect();
    siblings.sort();
    for device in siblings {
        if asks.len() < MAX_REFRESH_ASKS && !asks.contains(device) {
            asks.push(device.clone());
        }
    }
    (asks, new)
}

/// Whether `device` is another device of ours. Never a bare master id (G1).
fn is_sibling(device: &str, own_master: &str) -> bool {
    super::resolver::is_device_of(device, own_master) && !super::resolver::is_revoked(device)
}

/// Ask each of `asks` for `master`'s roster for a waiting DM. Each is marked asked
/// even when the roster no longer loads, so a released DM never waits again.
fn send_asks(ws_cmd_tx: &WsCmdTx, store: &MessageStore, master: &str, asks: &[String], dm_room: &str, now: i64) {
    for device in asks {
        let _ = store.mark_roster_expiry_asked(master, device, now);
    }
    // Loaded only now: a load verifies every statement again.
    let Some(roster) = super::roster_book::load(store, master) else { return };
    let msg = HavenMessage::RosterSync { roster, reply: true, waiting: true };
    for device in asks {
        // Our own sibling routes like any sibling send, not by the friend's DM room.
        let room = super::resolver::is_device_of(device, master).then_some(dm_room);
        olm_lane::carry(ws_cmd_tx, device, room, &msg, NoSession::Queue);
    }
}

/// The ones of `asks` that are online, so may answer within the hold.
fn online(ws_room_peers: &WsRoomPeers, asks: &[String]) -> HashSet<String> {
    asks.iter()
        .filter(|d| super::crypto_handler::ws_room_for_peer(ws_room_peers, d).is_some())
        .cloned()
        .collect()
}

/// Release the hold `key` once every device it waits on answered, or after
/// [`DM_HOLD_MAX_MS`].
fn run_hold(key: String, master: &str, own_master: &str, cmd_tx: &tokio::sync::mpsc::Sender<NodeCommand>) {
    let (cmd_tx, master, own_master) = (cmd_tx.clone(), master.to_string(), own_master.to_string());
    tokio::spawn(async move {
        let deadline = tokio::time::Instant::now() + Duration::from_millis(DM_HOLD_MAX_MS as u64);
        loop {
            let answered = holds().get_mut(&key).is_none_or(|hold| {
                hold.waiting.retain(|d| {
                    (super::resolver::is_device_of(d, &master) || super::resolver::is_device_of(d, &own_master))
                        && !super::resolver::is_revoked(d)
                });
                hold.waiting.is_empty()
            });
            if answered || tokio::time::Instant::now() >= deadline {
                break;
            }
            tokio::time::sleep(HOLD_POLL).await;
        }
        let _ = cmd_tx.send(NodeCommand::ReleaseHeldDms { master }).await;
    });
}

/// A session up for [`DM_HOLD_MAX_MS`] that never listed the DM room the wait `id`
/// is for: send its asks and the DM, which then waits no more.
#[allow(clippy::too_many_arguments)]
fn arm_backstop(
    ws_cmd_tx: &WsCmdTx,
    cmd_tx: &tokio::sync::mpsc::Sender<NodeCommand>,
    local_device: &str,
    key: String,
    id: u64,
    epoch: u64,
    db_path: &str,
    db_passphrase: &str,
) {
    let Ok(rt) = tokio::runtime::Handle::try_current() else { return };
    let (ws_cmd_tx, cmd_tx) = (ws_cmd_tx.clone(), cmd_tx.clone());
    let (local_device, db_path, db_passphrase) = (local_device.to_string(), db_path.to_string(), db_passphrase.to_string());
    rt.spawn(async move {
        tokio::time::sleep(Duration::from_millis(DM_HOLD_MAX_MS as u64)).await;
        if !sessions().get(&local_device).is_some_and(|s| s.up && s.epoch == epoch) {
            return;
        }
        let taken = holds()
            .get_mut(&key)
            .filter(|hold| hold.unplaced.as_ref().is_some_and(|u| u.id == id))
            .and_then(|hold| hold.unplaced.take());
        let Some(unplaced) = taken else { return };
        let master = key[local_device.len() + 1..].to_string();
        hollow_log!("[HOLLOW-ROSTER] DM room for {master} never listed this session: the held DM goes out");
        if let Ok(store) = MessageStore::lease(&db_path, &db_passphrase) {
            send_asks(&ws_cmd_tx, &store, &master, &unplaced.asks, &unplaced.dm_room, super::roster_book::now_ms());
        }
        let _ = cmd_tx.send(NodeCommand::ReleaseHeldDms { master }).await;
    });
}

/// A relay session came up: `fresh` when nothing of an earlier one carried over
/// (`WsEvent::Connected`), else a resume. Every wait for a listing starts its backstop.
pub(crate) fn on_session_up(
    ws_cmd_tx: &WsCmdTx,
    cmd_tx: &tokio::sync::mpsc::Sender<NodeCommand>,
    local_device: &str,
    fresh: bool,
    db_path: &str,
    db_passphrase: &str,
) {
    let epoch = {
        let mut sessions = sessions();
        let session = sessions.entry(local_device.to_string()).or_default();
        session.up = true;
        session.epoch += 1;
        if fresh {
            session.listed.clear();
        }
        session.epoch
    };
    let prefix = format!("{local_device}|");
    let waits: Vec<(String, u64)> = holds()
        .iter()
        .filter(|(key, _)| key.starts_with(&prefix))
        .filter_map(|(key, hold)| hold.unplaced.as_ref().map(|u| (key.clone(), u.id)))
        .collect();
    for (key, id) in waits {
        arm_backstop(ws_cmd_tx, cmd_tx, local_device, key, id, epoch, db_path, db_passphrase);
    }
}

/// The relay socket went away: `lost` when the session went with it
/// (`WsEvent::SessionLost`), so every listing is void.
pub(crate) fn on_session_down(local_device: &str, lost: bool) {
    let mut sessions = sessions();
    let session = sessions.entry(local_device.to_string()).or_default();
    session.up = false;
    if lost {
        session.listed.clear();
    }
}

/// We left `room`: the relay lists it again only on a rejoin.
pub(crate) fn on_room_left(local_device: &str, room: &str) {
    if let Some(session) = sessions().get_mut(local_device) {
        session.listed.remove(room);
    }
}

/// The relay listed `room`: a hold that waited for it sends its asks now and runs.
pub(crate) fn on_room_listed(
    ws_cmd_tx: &WsCmdTx,
    cmd_tx: &tokio::sync::mpsc::Sender<NodeCommand>,
    ws_room_peers: &WsRoomPeers,
    local_device: &str,
    room: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    sessions().entry(local_device.to_string()).or_default().listed.insert(room.to_string());
    let prefix = format!("{local_device}|");
    let placed: Vec<(String, Vec<String>)> = holds()
        .iter_mut()
        .filter(|(key, hold)| key.starts_with(&prefix) && hold.unplaced.as_ref().is_some_and(|u| u.dm_room == room))
        .filter_map(|(key, hold)| hold.unplaced.take().map(|u| (key.clone(), u.asks)))
        .collect();
    if placed.is_empty() {
        return;
    }
    let store = MessageStore::lease(db_path, db_passphrase).ok();
    let now = super::roster_book::now_ms();
    for (key, asks) in placed {
        let master = key[prefix.len()..].to_string();
        if let Some(store) = store.as_ref() {
            send_asks(ws_cmd_tx, store, &master, &asks, room, now);
        }
        let waiting = online(ws_room_peers, &asks);
        hollow_log!("[HOLLOW-ROSTER] DM room for {master} listed: the held DM waits on {} device(s)", waiting.len());
        if let Some(hold) = holds().get_mut(&key) {
            hold.waiting = waiting;
        }
        run_hold(key, &master, &super::resolver::resolve(local_device), cmd_tx);
    }
}

/// `device` showed us its view of `master`'s roster, now merged: a DM held for its
/// answer no longer waits on it.
pub(crate) fn note_answer(local_device: &str, device: &str, master: &str) {
    if let Some(hold) = holds().get_mut(&format!("{local_device}|{master}")) {
        hold.waiting.remove(device);
    }
}

/// The DMs held for `master`, in send order, and what following the store did before
/// them; the hold ends.
pub(crate) fn release(local_device: &str, master: &str) -> (Vec<HeldDm>, Reconciled) {
    holds()
        .remove(&format!("{local_device}|{master}"))
        .map(|hold| (hold.queue, hold.reconciled))
        .unwrap_or_default()
}

/// Whether the relay listed `room` to `local_device` this session. Tests only.
#[cfg(test)]
pub(crate) fn listed_for_test(local_device: &str, room: &str) -> bool {
    listed(local_device, room)
}

/// DMs held for `master` on `local_device`. Tests only: live state a test can poll.
#[cfg(test)]
pub(crate) fn held_for_test(local_device: &str, master: &str) -> usize {
    holds().get(&format!("{local_device}|{master}")).map_or(0, |hold| hold.queue.len())
}

/// Forget every gate and hold. Tests only: harness nodes reuse device ids.
#[cfg(test)]
pub(crate) fn clear_for_test() {
    if let Ok(mut gates) = GATES.get_or_init(Default::default).lock() {
        gates.0.clear();
    }
    holds().clear();
    sessions().clear();
    if let Ok(mut groups) = GROUPS.get_or_init(Default::default).lock() {
        groups.clear();
    }
    if let Ok(mut j) = TEST_JITTER.lock() {
        *j = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: i64 = 24 * 60 * 60 * 1000;

    #[test]
    fn b3_ar29_no_digest_or_a_misshapen_one_is_unknown_never_a_mismatch() {
        let d = "0a".repeat(16);
        assert_eq!(judge(Some(&d), None), Seen::Unknown, "a 0.12.1 sender sends none");
        assert_eq!(judge(None, None), Seen::Unknown);
        assert_eq!(judge(Some(&d), Some("not-a-digest")), Seen::Unknown);
        assert_eq!(judge(Some(&d), Some(&d)), Seen::Same);
        assert_eq!(judge(Some(&d), Some(&"0b".repeat(16))), Seen::Differs);
        assert_eq!(judge(None, Some(&d)), Seen::Differs, "holding nothing differs from something");
    }

    #[test]
    fn b3_ar29_a_0_12_1_dm_parses_and_an_old_parser_ignores_the_digests() {
        use super::super::types::MessageEnvelope;
        let old = r#"{"t":"dm","text":"hi","ts":1,"mid":"m1"}"#;
        match serde_json::from_str::<MessageEnvelope>(old) {
            Ok(MessageEnvelope::DirectMessage { inner }) => assert_eq!(inner.rd, None),
            other => panic!("a 0.12.1 DM must parse, got {other:?}"),
        }
        // What 0.12.1 declares: the same payload with no `rd`.
        #[derive(serde::Deserialize)]
        #[allow(dead_code)]
        struct OldPayload {
            text: String,
            #[serde(default)]
            ts: i64,
        }
        #[derive(serde::Deserialize)]
        #[serde(tag = "t")]
        #[allow(dead_code)]
        enum OldEnvelope {
            #[serde(rename = "dm")]
            DirectMessage {
                #[serde(flatten)]
                inner: Box<OldPayload>,
            },
        }
        let new = serde_json::json!({"t": "dm", "text": "hi", "ts": 1, "rd": {"own": "0a".repeat(16)}}).to_string();
        assert!(serde_json::from_str::<OldEnvelope>(&new).is_ok(), "an old parser ignores `rd`");
    }

    #[test]
    fn b3_ar29_a_roster_is_told_only_to_its_identity_ours_or_our_siblings() {
        use super::super::resolver;
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        let (me, me_dev, sib) = ("b3-me", "b3-me-dev", "b3-me-sib");
        let (o, o_dev, x, x_dev) = ("b3-o", "b3-o-dev", "b3-x", "b3-x-dev");
        resolver::seed_self(me, &[me_dev.to_string(), sib.to_string()]);
        resolver::update_many(o, [o_dev]);
        resolver::update_many(x, [x_dev]);
        let full = || Audience::Full;
        assert!(may_answer(me, me_dev, o_dev, o, full), "a device hears its own identity's roster");
        assert!(may_answer(me, me_dev, x_dev, me, full), "anyone our profile reaches hears ours");
        assert!(may_answer(me, me_dev, sib, o, || Audience::None), "our sibling hears any we hold");
        assert!(!may_answer(me, me_dev, x_dev, o, full), "never a third party's");
        assert!(!may_answer(me, me_dev, me_dev, o, full), "never ourselves");
        resolver::mark_revoked(&[o_dev.to_string()]);
        assert!(!may_answer(me, me_dev, o_dev, me, full), "never a removed device");
        resolver::clear_for_test();
    }

    // b3-fix L2: our roster is our profile's: a stranger hears none of it.
    #[test]
    fn b3_fix_our_roster_is_told_only_to_our_profile_audience() {
        use super::super::resolver;
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        let (me, me_dev, x, x_dev) = ("b3a-me", "b3a-me-dev", "b3a-x", "b3a-x-dev");
        resolver::seed_self(me, &[me_dev.to_string()]);
        resolver::update_many(x, [x_dev]);
        assert!(!may_answer(me, me_dev, x_dev, me, || Audience::None), "a stranger asked about us");
        assert!(may_answer(me, me_dev, x_dev, me, || Audience::Card), "a pending friend sees our card");
        assert!(may_answer(me, me_dev, x_dev, x, || Audience::None), "its own roster needs no audience");
        resolver::clear_for_test();
    }

    #[test]
    fn b3_ar29_the_ask_gate_passes_once_per_gap() {
        let mut book = GateBook::default();
        let key = || "b3-gate-test|ask|m|m".to_string();
        let t0 = 1_900_000_000_000;
        assert!(book.pass(key(), ROSTER_ASK_GAP_MS, t0));
        assert!(!book.pass(key(), ROSTER_ASK_GAP_MS, t0 + 1));
        assert!(!book.pass(key(), ROSTER_ASK_GAP_MS, t0 + ROSTER_ASK_GAP_MS - 1));
        assert!(book.pass(key(), ROSTER_ASK_GAP_MS, t0 + ROSTER_ASK_GAP_MS));
    }

    // b3-fix L4: device ids are free to mint, so the gate book stays bounded and a
    // flood pushes out the oldest entries first.
    #[test]
    fn b3_fix_the_gate_book_is_bounded_and_drops_the_oldest() {
        let mut book = GateBook::default();
        let t0 = 1_950_000_000_000;
        let key = |i: usize| format!("dev|ask|m|{i}");
        for i in 0..=GATES_CAP {
            assert!(book.pass(key(i), ROSTER_ASK_GAP_MS, t0 + i as i64));
        }
        assert!(book.0.len() <= GATES_CAP, "the gate book grew to {}", book.0.len());
        assert!(!book.0.contains_key(&key(0)), "the oldest entry goes first");
        assert!(!book.pass(key(GATES_CAP), ROSTER_ASK_GAP_MS, t0 + GATES_CAP as i64 + 1), "the newest stays");
    }

    // b3-fix L5/M1: a device's slot runs out after 35 days and is asked once per span;
    // a stamp from ahead of our clock counts as none.
    #[test]
    fn b3_fix_a_slot_runs_out_and_is_asked_once_per_span() {
        let now = 1_900_000_000_000;
        assert_eq!(slot(None, now), Slot::New);
        assert_eq!(slot(Some((now - 34 * DAY, None)), now), Slot::Fresh);
        assert_eq!(slot(Some((now - 36 * DAY, None)), now), Slot::Stale { ask_due: true });
        assert_eq!(slot(Some((now - 36 * DAY, Some(now - DAY))), now), Slot::Stale { ask_due: false });
        assert_eq!(slot(Some((now - 80 * DAY, Some(now - 36 * DAY))), now), Slot::Stale { ask_due: true });
        let ahead = now + super::super::frame_auth::LIVE_SKEW_MS + 1;
        assert_eq!(slot(Some((ahead, None)), now), Slot::Stale { ask_due: true }, "a stamp from the future");
        assert_eq!(slot(Some((now - 36 * DAY, Some(ahead))), now), Slot::Stale { ask_due: true });
        assert_eq!(slot(Some((now + 1_000, None)), now), Slot::Fresh, "within the skew");
    }

    // b3-fix M1: a DM counts for roster freshness only the first time its signed copy
    // arrives; a header's unsigned placeholder row does not count as one.
    #[test]
    fn b3_fix_only_a_first_signed_copy_counts() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("b3.db").to_string_lossy().into_owned();
        let store = MessageStore::open(&path, &"cd".repeat(32)).unwrap();
        assert!(first_signed_copy(&store, Some("m1")), "never seen");
        assert!(!first_signed_copy(&store, None), "a DM with no id says nothing");
        store.insert("peer", "[file:f1]", false, 1, None, None, Some("m1"), None, Some("f1"), Some(1_000), None).unwrap();
        assert!(first_signed_copy(&store, Some("m1")), "a header's placeholder carries no signature");
        store.insert("peer", "hi", false, 2, Some("sig"), Some("pk"), Some("m2"), None, None, Some(2_000), None).unwrap();
        assert!(!first_signed_copy(&store, Some("m2")), "read before");
    }

    // b3-fix L3/L2: a DM asks only when its sender is a device of some identity, and
    // pushes our own roster only to someone our profile reaches.
    #[test]
    fn b3_fix_a_dm_asks_only_from_a_counted_device_and_tells_ours_only_to_our_audience() {
        use super::super::resolver;
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        clear_for_test();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("b3.db").to_string_lossy().into_owned();
        let store = MessageStore::open(&path, &"cd".repeat(32)).unwrap();
        let (me, me_dev, o, o_dev, lone) = ("b3d-me", "b3d-me-dev", "b3d-o", "b3d-o-dev", "b3d-lone");
        resolver::seed_self(me, &[me_dev.to_string()]);
        resolver::update_many(o, [o_dev]);
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let differs = |own: bool| RosterDigests {
            own: own.then(|| "ab".repeat(16)),
            peer: (!own).then(|| "ab".repeat(16)),
            rm: Vec::new(),
        };
        let none = |_: &str| Audience::None;
        let asked = |rx: &mut tokio::sync::mpsc::UnboundedReceiver<super::super::ws_client::WsCommand>| {
            std::iter::from_fn(|| rx.try_recv().ok()).count()
        };

        on_dm(&tx, &store, me, me_dev, lone, false, lone, 1, Some(&differs(true)), &none);
        assert_eq!(asked(&mut rx), 0, "a device no roster counts asks nothing");
        on_dm(&tx, &store, me, me_dev, lone, false, lone, 1, Some(&differs(false)), &|_| Audience::Full);
        assert_eq!(asked(&mut rx), 0, "a device no roster counts is not told our roster, even in our audience");
        on_dm(&tx, &store, me, me_dev, o_dev, false, o, 1, Some(&differs(false)), &none);
        assert_eq!(asked(&mut rx), 0, "our roster goes to no one outside our audience");
        on_dm(&tx, &store, me, me_dev, o_dev, false, o, 1, Some(&differs(false)), &|_| Audience::Full);
        assert_eq!(asked(&mut rx), 1, "control: a friend's view of us that differs asks it");
        on_dm(&tx, &store, me, me_dev, o_dev, false, o, 1, Some(&differs(true)), &none);
        assert_eq!(asked(&mut rx), 1, "control: its own roster needs no audience");
        clear_for_test();
        resolver::clear_for_test();
    }

    // b3-fix L6: a mismatch ask and its answer leave a moment after what caused them;
    // an answer a DM waits for leaves at once.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn b3_fix_mismatch_asks_and_answers_wait_their_moment() {
        use super::super::resolver;
        use crate::identity::native_identity::NativeKeypair;
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        clear_for_test();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("b3.db").to_string_lossy().into_owned();
        let pass = "cd".repeat(32);
        let store = MessageStore::open(&path, &pass).unwrap();
        let kp = |t: u8| NativeKeypair::from_secret_bytes(&[t; 32]);
        let (m, rec, dev) = (kp(231), kp(232), kp(233));
        let (me, me_dev) = ("b3j-me", "b3j-me-dev");
        resolver::seed_self(me, &[me_dev.to_string()]);
        let now = super::super::roster_book::now_ms();
        let o = Roster::genesis(&m, &rec, &dev, now - 60_000);
        super::super::roster_book::merge_for_test(&store, &o, me, me_dev);
        let (o_master, o_dev) = (m.peer_id(), dev.peer_id());
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let later = || tokio::time::sleep(Duration::from_millis(jitter_range().1 + 300));

        let rd = RosterDigests { own: Some("ab".repeat(16)), peer: None, rm: Vec::new() };
        on_dm(&tx, &store, me, me_dev, &o_dev, false, &o_master, 1, Some(&rd), &|_| Audience::Full);
        assert!(rx.try_recv().is_err(), "a mismatch ask left with the DM that caused it");
        later().await;
        assert!(rx.try_recv().is_ok(), "control: the ask leaves");

        answer(&tx, me, me_dev, &o_dev, &o_master, false, || Audience::Full, &path, &pass);
        assert!(rx.try_recv().is_err(), "an answer left with the ask that caused it");
        later().await;
        assert!(rx.try_recv().is_ok(), "control: the answer leaves");

        clear_for_test();
        answer(&tx, me, me_dev, &o_dev, &o_master, true, || Audience::Full, &path, &pass);
        assert!(rx.try_recv().is_ok(), "an answer a DM waits for leaves at once");
        clear_for_test();
        resolver::clear_for_test();
    }

    // f-b3-phone: a differing digest voids the device's stamp AND an expiry ask made
    // this span, so the next DM asks it again.
    #[test]
    fn b3_phone_a_differing_digest_makes_the_device_due_an_ask() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("b3u.db").to_string_lossy().into_owned();
        let store = MessageStore::open(&path, &"ef".repeat(32)).unwrap();
        let now = super::super::roster_book::now_ms();
        store.stamp_roster_confirmed("m", "d", now).unwrap();
        store.mark_roster_expiry_asked("m", "d", now).unwrap();
        assert_eq!(slot(store.roster_confirm_slots("m").get("d").copied(), now), Slot::Fresh, "precondition");
        unconfirm(&store, "m", "d", 1);
        assert_eq!(slot(store.roster_confirm_slots("m").get("d").copied(), now), Slot::Stale { ask_due: true });
        unconfirm(&store, "m", "e", 1);
        assert_eq!(slot(store.roster_confirm_slots("m").get("e").copied(), now), Slot::Stale { ask_due: true }, "a device never stamped too");
    }

    // f-b3-phone: a DM to a roster a contact device showed differs waits while no DM
    // room is listed (no relay session yet): no ask, no clock; the listing sends the ask
    // and the answer releases it.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn b3_phone_a_dm_before_the_room_is_listed_waits_for_the_listing_and_the_answer() {
        use super::super::resolver;
        use crate::identity::native_identity::NativeKeypair;
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        clear_for_test();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("b3p.db").to_string_lossy().into_owned();
        let pass = "cd".repeat(32);
        let store = MessageStore::open(&path, &pass).unwrap();
        let kp = |t: u8| NativeKeypair::from_secret_bytes(&[t; 32]);
        let (m, rec, dev) = (kp(241), kp(242), kp(243));
        let (me, me_dev) = ("b3p-me", "b3p-me-dev");
        resolver::seed_self(me, &[me_dev.to_string()]);
        let now = super::super::roster_book::now_ms();
        let o = Roster::genesis(&m, &rec, &dev, now - 60_000);
        super::super::roster_book::merge_for_test(&store, &o, me, me_dev);
        let (o_master, o_dev) = (m.peer_id(), dev.peer_id());
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let (cmd_tx, mut cmd_rx) = tokio::sync::mpsc::channel(8);
        let room = "b3p-dm-room";
        let held = || HeldDm::Envelope { envelope_json: "{}".into(), sibling_json: None };

        fetch_on_dm(&store, me, &o_dev, &o_master, 1, Some(&RosterDigests { own: Some("ab".repeat(16)), peer: None, rm: Vec::new() }));
        let _ = store.take_roster_asks_due();
        let mut peers = WsRoomPeers::new();
        let targets = [o_dev.clone()];
        let gate = hold_for_stale_roster(&tx, &cmd_tx, &peers, me_dev, &o_master, &targets, room, &path, &pass, held);
        assert_eq!(gate, Gate::Held, "a DM before the room is listed went out on a roster its sender showed differs");
        assert!(rx.try_recv().is_err(), "an ask left before anyone could answer it");
        let gate = hold_for_stale_roster(&tx, &cmd_tx, &peers, me_dev, &o_master, &targets, room, &path, &pass, held);
        assert_eq!(gate, Gate::Held, "a second DM overtook the held one");
        tokio::time::sleep(Duration::from_millis(DM_HOLD_MAX_MS as u64 / 20)).await;
        assert!(cmd_rx.try_recv().is_err(), "the hold ran while nothing was listed");

        peers.insert(room.to_string(), std::iter::once(o_dev.clone()).collect());
        on_room_listed(&tx, &cmd_tx, &peers, me_dev, room, &path, &pass);
        assert!(rx.try_recv().is_ok(), "the listing sends the ask the DM waits for");
        tokio::time::sleep(HOLD_POLL * 4).await;
        assert!(cmd_rx.try_recv().is_err(), "released before the answer");
        note_answer(me_dev, &o_dev, &o_master);
        let released = tokio::time::timeout(Duration::from_secs(2), cmd_rx.recv()).await;
        assert!(matches!(released, Ok(Some(NodeCommand::ReleaseHeldDms { .. }))), "the answer releases the DM");
        assert_eq!(release(me_dev, &o_master).0.len(), 2, "both DMs go out, in order");
        clear_for_test();
        resolver::clear_for_test();
    }

    /// A roster test cast: our identity `me` and a contact O with one device whose
    /// slot a differing digest voided.
    struct VoidedCast {
        _tmp: crate::test_tmp::TestDir,
        path: String,
        pass: String,
        o_master: String,
        o_dev: String,
    }

    fn voided_cast(tags: [u8; 3], me: &str, me_dev: &str) -> VoidedCast {
        use crate::identity::native_identity::NativeKeypair;
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("b3v.db").to_string_lossy().into_owned();
        let pass = "cd".repeat(32);
        let store = MessageStore::open(&path, &pass).unwrap();
        let kp = |t: u8| NativeKeypair::from_secret_bytes(&[t; 32]);
        let (m, rec, dev) = (kp(tags[0]), kp(tags[1]), kp(tags[2]));
        super::super::resolver::seed_self(me, &[me_dev.to_string()]);
        let now = super::super::roster_book::now_ms();
        super::super::roster_book::merge_for_test(&store, &Roster::genesis(&m, &rec, &dev, now - 60_000), me, me_dev);
        let (o_master, o_dev) = (m.peer_id(), dev.peer_id());
        fetch_on_dm(&store, me, &o_dev, &o_master, 1, Some(&RosterDigests { own: Some("ab".repeat(16)), peer: None, rm: Vec::new() }));
        let _ = store.take_roster_asks_due();
        VoidedCast { _tmp: tmp, path, pass, o_master, o_dev }
    }

    // f-b3-phone F1: a room the relay listed this session stays placed after its last
    // peer left, so a DM to a contact gone offline asks at once and goes, never waits
    // for a PeerJoined that may not come.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn b3_phone_a_room_listed_this_session_stays_placed_after_its_peers_left() {
        use super::super::resolver;
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        clear_for_test();
        let me_dev = "b3l-me-dev";
        let c = voided_cast([244, 245, 246], "b3l-me", me_dev);
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let (cmd_tx, _cmd_rx) = tokio::sync::mpsc::channel(8);
        let room = "b3l-dm-room";
        let held = || HeldDm::Envelope { envelope_json: "{}".into(), sibling_json: None };
        let mut peers = WsRoomPeers::new();
        peers.insert(room.to_string(), std::iter::once(c.o_dev.clone()).collect());
        on_session_up(&tx, &cmd_tx, me_dev, true, &c.path, &c.pass);
        on_room_listed(&tx, &cmd_tx, &peers, me_dev, room, &c.path, &c.pass);
        // PeerLeft for O's last device: `ws_room_peers` drops the room.
        peers.remove(room);
        let targets = [c.o_dev.clone()];
        let gate = hold_for_stale_roster(&tx, &cmd_tx, &peers, me_dev, &c.o_master, &targets, room, &c.path, &c.pass, held);
        assert_eq!(gate, Gate::Go, "a DM to a contact whose devices left waits for a listing that already came");
        assert!(rx.try_recv().is_ok(), "the ask still goes out, for the device's return");

        // Each way a listing ends, alone: the next DM waits for a new one.
        let store = MessageStore::open(&c.path, &c.pass).unwrap();
        let gate_after = |end: &dyn Fn(), why: &str| {
            on_room_listed(&tx, &cmd_tx, &peers, me_dev, room, &c.path, &c.pass);
            let _ = release(me_dev, &c.o_master);
            unconfirm(&store, &c.o_master, &c.o_dev, 2);
            end();
            let gate = hold_for_stale_roster(&tx, &cmd_tx, &peers, me_dev, &c.o_master, &targets, room, &c.path, &c.pass, held);
            assert_eq!(gate, Gate::Held, "{why}");
        };
        gate_after(&|| on_session_down(me_dev, true), "a listing outlived its lost session");
        gate_after(&|| on_session_up(&tx, &cmd_tx, me_dev, true, &c.path, &c.pass), "a listing outlived a fresh session");
        gate_after(&|| on_room_left(me_dev, room), "a listing outlived our leaving the room");
        on_room_listed(&tx, &cmd_tx, &peers, me_dev, room, &c.path, &c.pass);
        let _ = release(me_dev, &c.o_master);
        unconfirm(&store, &c.o_master, &c.o_dev, 2);
        on_session_down(me_dev, false);
        on_session_up(&tx, &cmd_tx, me_dev, false, &c.path, &c.pass);
        let gate = hold_for_stale_roster(&tx, &cmd_tx, &peers, me_dev, &c.o_master, &targets, room, &c.path, &c.pass, held);
        assert_eq!(gate, Gate::Go, "a resumed session lost the listing it kept");
        clear_for_test();
        resolver::clear_for_test();
    }

    // f-b3-phone F1 backstop: a session up DM_HOLD_MAX_MS that never lists the DM room
    // sends the asks and the DM, and the released DM never waits again.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn b3_phone_a_dm_waiting_for_a_listing_goes_out_after_the_session_is_up() {
        use super::super::resolver;
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        clear_for_test();
        let me_dev = "b3b-me-dev";
        let c = voided_cast([247, 248, 249], "b3b-me", me_dev);
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let (cmd_tx, mut cmd_rx) = tokio::sync::mpsc::channel(8);
        let room = "b3b-dm-room";
        let held = || HeldDm::Envelope { envelope_json: "{}".into(), sibling_json: None };
        let peers = WsRoomPeers::new();
        let targets = [c.o_dev.clone()];
        let hold_max = Duration::from_millis(DM_HOLD_MAX_MS as u64);

        let gate = hold_for_stale_roster(&tx, &cmd_tx, &peers, me_dev, &c.o_master, &targets, room, &c.path, &c.pass, held);
        assert_eq!(gate, Gate::Held, "precondition: no session, no listing");
        // A suspended session's socket is down too: its backstop waits for the resume.
        on_session_up(&tx, &cmd_tx, me_dev, true, &c.path, &c.pass);
        tokio::time::sleep(hold_max / 2).await;
        assert!(cmd_rx.try_recv().is_err(), "released before the backstop");
        on_session_down(me_dev, false);
        tokio::time::sleep(hold_max * 7 / 10).await;
        assert!(cmd_rx.try_recv().is_err(), "a backstop of a session that went away released the DM");
        on_session_up(&tx, &cmd_tx, me_dev, false, &c.path, &c.pass);
        let released = tokio::time::timeout(hold_max * 2, cmd_rx.recv()).await;
        assert!(matches!(released, Ok(Some(NodeCommand::ReleaseHeldDms { .. }))), "a DM waiting for a listing never went out");
        assert!(rx.try_recv().is_ok(), "the backstop sends the asks too");
        assert_eq!(release(me_dev, &c.o_master).0.len(), 1);
        let gate = hold_for_stale_roster(&tx, &cmd_tx, &peers, me_dev, &c.o_master, &targets, room, &c.path, &c.pass, held);
        assert_eq!(gate, Gate::Go, "the released DM waited again, forever");

        // Held while the session is already up: the backstop starts with the hold.
        let store = MessageStore::open(&c.path, &c.pass).unwrap();
        unconfirm(&store, &c.o_master, &c.o_dev, 2);
        let gate = hold_for_stale_roster(&tx, &cmd_tx, &peers, me_dev, &c.o_master, &targets, room, &c.path, &c.pass, held);
        assert_eq!(gate, Gate::Held, "precondition: the room is still not listed");
        let released = tokio::time::timeout(hold_max * 2, cmd_rx.recv()).await;
        assert!(matches!(released, Ok(Some(NodeCommand::ReleaseHeldDms { .. }))), "a DM held on a live session that never lists the room never went out");
        clear_for_test();
        resolver::clear_for_test();
    }

    // f-b3-phone F3: a DM a device sent before the one whose digest differed never
    // stamps its voided slot, however late it arrives; one sent after does.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn b3_phone_an_older_matching_dm_does_not_restamp_a_voided_slot() {
        use super::super::resolver;
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        clear_for_test();
        let (me, me_dev) = ("b3o-me", "b3o-me-dev");
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("b3o.db").to_string_lossy().into_owned();
        let store = MessageStore::open(&path, &"ef".repeat(32)).unwrap();
        let kp = |t: u8| crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[t; 32]);
        let (m, rec, dev) = (kp(250), kp(251), kp(252));
        resolver::seed_self(me, &[me_dev.to_string()]);
        let now = super::super::roster_book::now_ms();
        let o = Roster::genesis(&m, &rec, &dev, now - 60_000);
        super::super::roster_book::merge_for_test(&store, &o, me, me_dev);
        let (o_master, o_dev) = (m.peer_id(), dev.peer_id());
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let held = held_digest(&store, &o_master);
        let differs = RosterDigests { own: Some("ab".repeat(16)), peer: None, rm: Vec::new() };
        let matches = RosterDigests { own: held, peer: None, rm: Vec::new() };
        let full = |_: &str| Audience::Full;

        on_dm(&tx, &store, me, me_dev, &o_dev, false, &o_master, 2_000, Some(&differs), &full);
        assert_eq!(store.roster_confirmed_at(&o_master, &o_dev), Some(0), "precondition: the slot is void");
        on_dm(&tx, &store, me, me_dev, &o_dev, false, &o_master, 1_000, Some(&matches), &full);
        assert_eq!(store.roster_confirmed_at(&o_master, &o_dev), Some(0), "an older DM that matches stamped a voided slot");
        on_dm(&tx, &store, me, me_dev, &o_dev, false, &o_master, 2_000, Some(&matches), &full);
        assert_eq!(store.roster_confirmed_at(&o_master, &o_dev), Some(0), "one sent the same moment proves no order");
        on_dm(&tx, &store, me, me_dev, &o_dev, false, &o_master, 3_000, Some(&matches), &full);
        assert!(store.roster_confirmed_at(&o_master, &o_dev).is_some_and(|at| at > 0), "a later DM that matches stamps it");
        // A late copy of an older mismatch voids again without moving the mark back: a
        // match older than the newest mismatch still confirms nothing.
        on_dm(&tx, &store, me, me_dev, &o_dev, false, &o_master, 1_500, Some(&differs), &full);
        on_dm(&tx, &store, me, me_dev, &o_dev, false, &o_master, 1_800, Some(&matches), &full);
        assert_eq!(store.roster_confirmed_at(&o_master, &o_dev), Some(0), "a late old mismatch moved the mark back");
        clear_for_test();
        resolver::clear_for_test();
    }

    // b3-fix L6: mismatch asks and answers wait 1 to 30 s.
    #[test]
    fn b3_fix_mismatch_traffic_waits_a_random_moment() {
        assert_eq!(MISMATCH_JITTER_MS, (1_000, 30_000));
        for r in [0, 1, 28_999, 29_000, 29_001, u64::MAX] {
            let d = pick_jitter(MISMATCH_JITTER_MS, r).as_millis() as u64;
            assert!((1_000..=30_000).contains(&d), "{d}");
        }
        assert_eq!(pick_jitter(MISMATCH_JITTER_MS, 0).as_millis(), 1_000);
        assert_eq!(pick_jitter(MISMATCH_JITTER_MS, 29_000).as_millis(), 30_000);
    }

    /// F2 compat. A 0.12.2 receiver (its payload as shipped, copied here) reads a 0.13
    /// DM whose `rd` carries removals: the digests survive and the new field is dropped.
    #[test]
    fn g13c_a_0122_receiver_reads_an_rd_carrying_removals() {
        use super::super::types::{DirectMessagePayload, MessageEnvelope};
        #[derive(serde::Deserialize)]
        struct Shipped0122Rd {
            #[serde(default)]
            own: Option<String>,
            #[serde(default)]
            peer: Option<String>,
        }
        #[derive(serde::Deserialize)]
        struct Shipped0122Payload {
            text: String,
            #[serde(default)]
            rd: Option<Shipped0122Rd>,
        }
        #[derive(serde::Deserialize)]
        #[serde(tag = "t")]
        enum Shipped0122Envelope {
            #[serde(rename = "dm")]
            DirectMessage {
                #[serde(flatten)]
                inner: Box<Shipped0122Payload>,
            },
        }
        let by = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[0x31; 32]);
        let removed = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[0x32; 32]).peer_id();
        let rm = vec![roster::sign_removal(&by, "m", roster::LEGACY_BASE, &removed, &[])];
        let rd = RosterDigests { own: Some("ab".repeat(16)), peer: Some("cd".repeat(16)), rm };
        let dm = MessageEnvelope::DirectMessage {
            inner: Box::new(DirectMessagePayload {
                text: "hi".into(), ts: 1, sig: None, pk: None, mid: Some("m1".into()), reply_to: None,
                file_id: None, link_preview: None, convo: None, order_us: None, album: None, rd: Some(rd),
            }),
        };
        let wire = serde_json::to_string(&dm).unwrap();
        assert!(wire.contains("\"rm\""), "precondition: the removals ride the wire");
        let Shipped0122Envelope::DirectMessage { inner } = serde_json::from_str(&wire).expect("0.12.2 refused a 0.13 DM");
        let rd = inner.rd.expect("0.12.2 lost the digests");
        assert_eq!((inner.text.as_str(), rd.own, rd.peer), ("hi", Some("ab".repeat(16)), Some("cd".repeat(16))));
    }

    /// F2 bound: the one size test sender and receiver share, at its edges.
    #[test]
    fn g13c_the_carry_bound_holds_at_its_edges() {
        let by = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[0x33; 32]);
        let one = |i: u8, keep: usize| {
            let device = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[i; 32]).peer_id();
            let keep: Vec<String> = (0..keep)
                .map(|k| crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[i, k as u8 + 1, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7]).peer_id())
                .collect();
            roster::sign_removal(&by, "m", roster::LEGACY_BASE, &device, &keep)
        };
        let eight: Vec<Removal> = (1..=8).map(|i| one(i, 0)).collect();
        assert!(roster::carried_fits(&eight), "eight plain removals fit");
        let nine: Vec<Removal> = (1..=9).map(|i| one(i, 0)).collect();
        assert!(!roster::carried_fits(&nine), "a ninth statement is over the bound");
        // Grow one statement's keep list until the set crosses the byte bound.
        let mut set: Vec<Removal> = vec![one(1, 0)];
        let size = |rm: &[Removal]| serde_json::to_vec(rm).unwrap().len();
        let mut k = 0;
        while size(&set) <= roster::MAX_CARRIED_REMOVAL_BYTES && k < roster::MAX_REMOVAL_KEEP {
            k += 1;
            let wide = one(2, k);
            set = vec![one(1, 0), wide.clone(), one(3, k), one(4, k), one(5, k)];
        }
        assert!(size(&set) > roster::MAX_CARRIED_REMOVAL_BYTES, "precondition: the set crossed the byte bound");
        assert!(!roster::carried_fits(&set), "a set over 4096 bytes fit");
        set.pop();
        if size(&set) <= roster::MAX_CARRIED_REMOVAL_BYTES {
            assert!(roster::carried_fits(&set), "a set under 4096 bytes did not fit");
        }
    }

    struct Own {
        _tmp: crate::test_tmp::TestDir,
        store: MessageStore,
        roster: Roster,
        real: Removal,
        digest: String,
    }

    /// Our own identity: the phrase keeps `owner` and `s`, then `owner` removed `s`; a
    /// device holding the master key later flooded the roster with joins whose own keys
    /// sign removals of ids nobody holds (stored, never counted).
    fn own_with_flood() -> Own {
        use crate::identity::native_identity::NativeKeypair;
        use crate::identity::roster::{sign_consent, sign_pending};
        let key = |t: u8| NativeKeypair::from_secret_bytes(&[t; 32]);
        let (m, r, owner, s) = (key(0x41), key(0x42), key(0x43), key(0x44));
        let master = m.peer_id();
        let now = super::super::roster_book::now_ms();
        let mut roster = Roster::genesis(&m, &r, &owner, now - 60_000);
        roster.add_consent(sign_consent(&s, &master));
        let base = roster.base();
        roster.add_vouch(roster::sign_vouch(&owner, &master, &base, &s.peer_id()));
        let real = roster::sign_removal(&owner, &master, &base, &s.peer_id(), &[]);
        roster.add_removal(real.clone());
        for i in 0..4u8 {
            let p = key(0x50 + i);
            roster.add_consent(sign_consent(&p, &master));
            roster.add_pending(sign_pending(&m, &base, &p.peer_id()));
            for j in 0..3u8 {
                roster.add_removal(roster::sign_removal(&p, &master, &base, &key(0x60 + i * 3 + j).peer_id(), &[]));
            }
        }
        let roster = roster.verified(now);
        assert!(roster.removals.len() > 1, "precondition: the flood is stored");
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("own.db").to_string_lossy().into_owned();
        let store = MessageStore::open(&path, &"cd".repeat(32)).unwrap();
        let json = serde_json::to_string(&roster).unwrap();
        store.save_device_list(&master, &json, 0, &[owner.peer_id()], now).unwrap();
        let digest = roster.digest();
        Own { _tmp: tmp, store, roster, real, digest }
    }

    /// F2 (review H1). Only removals that count ride a DM: a flood of statements the
    /// stored roster keeps but the fold ignores never pushes out the real one.
    #[test]
    fn g13c_a_dm_carries_only_removals_that_count() {
        let _g = super::super::resolver::test_lock();
        clear_for_test();
        let own = own_with_flood();
        let rm = carried_for(&own.store, &own.roster, &own.digest, "contact");
        assert_eq!(rm, vec![own.real.clone()], "the carry held something other than the one counting removal");
    }

    /// F2 (review M5, M1). A contact every device of which showed our roster as we hold
    /// it now gets nothing; one that confirmed before we learned the removal still gets it,
    /// and nothing rides past CARRY_MAX_AGE_MS.
    #[test]
    fn g13c_a_carry_stops_once_the_contact_showed_it_holds_it() {
        let _g = super::super::resolver::test_lock();
        clear_for_test();
        let own = own_with_flood();
        let now = super::super::roster_book::now_ms();
        own.store.set_carry_confirm("caught-up", "caught-up-1", &own.digest, now).unwrap();
        assert!(carried_for(&own.store, &own.roster, &own.digest, "caught-up").is_empty(), "a contact that holds it got it again");

        assert_eq!(carried_for(&own.store, &own.roster, &own.digest, "silent"), vec![own.real.clone()], "precondition");
        own.store.set_carry_confirm("behind", "behind-1", &"ee".repeat(16), now - 40 * DAY).unwrap();
        assert_eq!(
            carried_for(&own.store, &own.roster, &own.digest, "behind"),
            vec![own.real.clone()],
            "a contact silent since before the removal (past 35 days) got nothing",
        );

        // A contact that confirmed a later digest, after we learned it, holds it.
        own.store.set_carry_confirm("later", "later-1", &"ff".repeat(16), now + 1_000).unwrap();
        assert!(carried_for(&own.store, &own.roster, &own.digest, "later").is_empty(), "a later confirmation still got it");

        // Learned past the age cap: it rides no more, whoever confirmed nothing.
        let base = own.roster.base();
        let device = own.real.device.clone();
        let _ = own.store.removal_carried_since(&own.roster.master, &base, &[], now);
        let old = now - CARRY_MAX_AGE_MS - DAY;
        let _ = own.store.removal_carried_since(&own.roster.master, &base, std::slice::from_ref(&device), old);
        assert!(carried_for(&own.store, &own.roster, &own.digest, "silent").is_empty(), "a removal past the age cap rode");
    }

    /// F2 (review M1). One contact device showing it holds our removal stops nothing for
    /// its siblings: the removal rides until every device the contact's roster counts
    /// showed it, whatever the order.
    #[test]
    fn g13c_the_carry_goes_on_until_every_contact_device_showed_it() {
        let _g = super::super::resolver::test_lock();
        clear_for_test();
        let own = own_with_flood();
        let now = super::super::roster_book::now_ms();
        let (p, p1, p2) = ("g13c-p", "g13c-p-1", "g13c-p-2");
        let held = serde_json::to_string(&Roster::new(p)).unwrap();
        own.store.save_device_list(p, &held, 0, &[p1.to_string(), p2.to_string()], now).unwrap();

        own.store.set_carry_confirm(p, p1, &own.digest, now).unwrap();
        assert_eq!(
            carried_for(&own.store, &own.roster, &own.digest, p),
            vec![own.real.clone()],
            "one device of the contact showing our roster stopped the carry to the other",
        );
        // A device the contact's roster no longer counts holds nothing back.
        own.store.set_carry_confirm(p, "g13c-p-gone", &"ee".repeat(16), now - 40 * DAY).unwrap();
        own.store.set_carry_confirm(p, p2, &own.digest, now).unwrap();
        assert!(carried_for(&own.store, &own.roster, &own.digest, p).is_empty(), "every device showed it and it still rode");
    }

    /// F2 (review L9). Our removals ride only to whom our roster may go.
    #[test]
    fn g13c_no_carry_outside_our_profile_audience() {
        let _g = super::super::resolver::test_lock();
        clear_for_test();
        let own = own_with_flood();
        let dir = own._tmp.path().join("own.db").to_string_lossy().into_owned();
        let pass = "cd".repeat(32);
        let full = for_dm(&own.roster.master, "contact", |_| Audience::Full, &dir, &pass).unwrap();
        assert_eq!(full.rm, vec![own.real.clone()], "precondition");
        let none = for_dm(&own.roster.master, "contact", |_| Audience::None, &dir, &pass).unwrap();
        assert!(none.rm.is_empty(), "our removals rode to someone our roster may not reach");
        assert_eq!(none.own, full.own, "the digests still ride");
    }

    /// F2 (review LOW-2). A DM with nothing to carry costs no audience lookup, and the
    /// carry itself writes nothing once `save` dated our removals.
    #[test]
    fn g13c_a_dm_with_nothing_to_carry_asks_no_audience_and_writes_nothing() {
        let _g = super::super::resolver::test_lock();
        clear_for_test();
        let own = own_with_flood();
        let dir = own._tmp.path().join("own.db").to_string_lossy().into_owned();
        let pass = "cd".repeat(32);
        let now = super::super::roster_book::now_ms();
        own.store.set_carry_confirm("caught-up", "caught-up-1", &own.digest, now).unwrap();
        let rd = for_dm(&own.roster.master, "caught-up", |_| panic!("asked the audience with nothing to carry"), &dir, &pass);
        assert!(rd.is_some_and(|rd| rd.rm.is_empty()));

        // Another process (the push fetch) holds the write lock: a carry that reads only
        // never waits for it.
        let device = own.real.device.clone();
        let _ = own.store.removal_carried_since(&own.roster.master, &own.roster.base(), std::slice::from_ref(&device), now);
        let writer = MessageStore::open(&dir, &pass).unwrap();
        writer.conn_execute_for_test("BEGIN IMMEDIATE");
        let started = std::time::Instant::now();
        assert_eq!(
            carried_for(&own.store, &own.roster, &own.digest, "silent"),
            vec![own.real.clone()],
            "a DM's carry wrote to the store and lost to the lock",
        );
        assert!(started.elapsed() < std::time::Duration::from_secs(2), "a DM's carry waited on the write lock");
        writer.conn_execute_for_test("ROLLBACK");
    }

    /// Review LOW-3. A carry over the statement bound is no news, scanned or not.
    #[test]
    fn g13c_an_oversized_carry_is_not_news() {
        let _g = super::super::resolver::test_lock();
        clear_for_test();
        let own = own_with_flood();
        let master = own.roster.master.clone();
        let by = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[0x43; 32]);
        let rm: Vec<Removal> = (0..=roster::MAX_CARRIED_REMOVALS as u8)
            .map(|i| {
                let device = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[0x70 + i; 32]).peer_id();
                roster::sign_removal(&by, &master, &own.roster.base(), &device, &[])
            })
            .collect();
        assert!(carried_news(&own.store, &master, &rm[..roster::MAX_CARRIED_REMOVALS]), "precondition: the statements are news");
        assert!(!carried_news(&own.store, &master, &rm), "a carry over the bound was read as news");
    }

    /// B3 (a). A sibling's row in a friend's slots holds a DM only while it is void and
    /// the device is ours: it is never taken for one of the friend's devices, and a
    /// friend device's row is never taken for a sibling's.
    #[test]
    fn g13c_a_sibling_row_is_never_a_friends_device() {
        use super::super::resolver;
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        let (me, me_dev, sib, stranger) = ("g13c-me", "g13c-me-dev", "g13c-me-sib", "g13c-x-dev");
        let (f, f1, f2) = ("g13c-f", "g13c-f-1", "g13c-f-2");
        resolver::seed_self(me, &[me_dev.to_string(), sib.to_string()]);
        resolver::update_many(f, [f1, f2]);
        let now = super::super::roster_book::now_ms();
        let void = (0, None);
        let slots: HashMap<String, (i64, Option<i64>)> =
            [(sib, void), (f1, void), (stranger, void), (me_dev, void)].into_iter().map(|(d, s)| (d.to_string(), s)).collect();

        let (asks, new) = stale_asks(&slots, &[f1.to_string(), f2.to_string(), sib.to_string()], f, me, me_dev, now);
        assert_eq!(asks, vec![f1.to_string(), sib.to_string()], "f1 as F's, the sibling as ours, nothing else");
        assert_eq!(new, vec![f2.to_string()], "a sibling passed as a target was taken for F's device");

        let fresh: HashMap<String, (i64, Option<i64>)> = [(sib.to_string(), (now, None))].into_iter().collect();
        assert!(stale_asks(&fresh, &[], f, me, me_dev, now).0.is_empty(), "a confirmed sibling row held a DM");
        let aged: HashMap<String, (i64, Option<i64>)> =
            [(sib.to_string(), (now - ROSTER_REFRESH_AFTER_MS - 1, None))].into_iter().collect();
        assert!(stale_asks(&aged, &[], f, me, me_dev, now).0.is_empty(), "a sibling row that only aged held a DM");
        resolver::clear_for_test();
    }

    /// F2 (review M5). A contact's DM whose `peer` digest is our own roster as we hold
    /// it records that it holds every removal we do, live and in the push fetch; one
    /// that differs records nothing.
    #[test]
    fn g13c_a_dm_showing_our_roster_stops_the_carry_to_its_sender() {
        use super::super::resolver;
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        clear_for_test();
        let own = own_with_flood();
        let me = own.roster.master.clone();
        let (c, c_dev, d, d_dev) = ("g13c-c", "g13c-c-dev", "g13c-d", "g13c-d-dev");
        resolver::update_many(c, [c_dev]);
        resolver::update_many(d, [d_dev]);
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let showing = |peer: &str| RosterDigests { own: None, peer: Some(peer.to_string()), rm: Vec::new() };
        let none = |_: &str| Audience::None;

        on_dm(&tx, &own.store, &me, "g13c-me-dev", c_dev, false, c, 1, Some(&showing(&"ab".repeat(16))), &none);
        assert!(own.store.carry_confirms(c).is_empty(), "a differing view confirmed the carry");
        on_dm(&tx, &own.store, &me, "g13c-me-dev", c_dev, false, c, 1, Some(&showing(&own.digest)), &none);
        assert_eq!(own.store.carry_confirms(c).get(c_dev).map(|(digest, _)| digest), Some(&own.digest), "live");
        assert!(carried_for(&own.store, &own.roster, &own.digest, c).is_empty());

        fetch_on_dm(&own.store, &me, d_dev, d, 1, Some(&showing(&own.digest)));
        assert_eq!(own.store.carry_confirms(d).get(d_dev).map(|(digest, _)| digest), Some(&own.digest), "push fetch");
        clear_for_test();
        resolver::clear_for_test();
    }

    /// B3 (a). An echo of our sibling's DM whose friend digest differs voids that
    /// sibling's slot for the friend; a later echo that matches clears it, and an echo
    /// the sibling sent before the one that differed does not.
    #[test]
    fn g13c_an_echo_voids_and_clears_its_siblings_slot() {
        use super::super::resolver;
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        clear_for_test();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("echo.db").to_string_lossy().into_owned();
        let store = MessageStore::open(&path, &"cd".repeat(32)).unwrap();
        let (me, me_dev, sib, f, f1) = ("g13c-me", "g13c-me-dev", "g13c-me-sib", "g13c-f", "g13c-f-1");
        resolver::seed_self(me, &[me_dev.to_string(), sib.to_string()]);
        resolver::update_many(f, [f1]);
        let held = Roster::new(f);
        store.save_device_list(f, &serde_json::to_string(&held).unwrap(), 0, &[f1.to_string()], 1).unwrap();
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let echo = |peer: String| RosterDigests { own: None, peer: Some(peer), rm: Vec::new() };
        let none = |_: &str| Audience::None;

        on_dm(&tx, &store, me, me_dev, sib, true, f, 10, Some(&echo("ab".repeat(16))), &none);
        assert_eq!(store.roster_confirmed_at(f, sib), Some(0), "a differing echo left no void");
        on_dm(&tx, &store, me, me_dev, sib, true, f, 5, Some(&echo(held.digest())), &none);
        assert_eq!(store.roster_confirmed_at(f, sib), Some(0), "an echo sent before the differing one cleared the void");
        on_dm(&tx, &store, me, me_dev, sib, true, f, 20, Some(&echo(held.digest())), &none);
        assert!(store.roster_confirmed_at(f, sib).is_some_and(|at| at > 0), "a later matching echo left the void");
        assert_eq!(store.roster_confirmed_at(f, f1), None, "an echo touched a friend device's slot");
        clear_for_test();
        resolver::clear_for_test();
    }
}
