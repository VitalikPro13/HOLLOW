//! A fresh install finds its servers through a re-added friend (DEVICE_PROOF_DESIGN 8.7,
//! step 2): after a phrase recovery it asks each friend device which servers they share,
//! and joins each the ordinary way, as from an invite. A friend answers only a device its
//! own view counts for our identity, only with servers whose state lists our identity as a
//! member, once per asking device per 10 minutes, and always in four frames of one size,
//! so neither a minted key nor the relay learns anything from it.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::crdt::server_state::ServerState;
use crate::storage::MessageStore;

use super::types::HavenMessage;

/// Servers one answer lists.
pub(crate) const MAX_SERVERS: usize = 64;
/// Member identities one entry names.
pub(crate) const MAX_MEMBERS: usize = 64;
/// Frames every answer is, each holding at most [`PER_FRAME`] entries.
pub(crate) const FRAMES: usize = 4;
pub(crate) const PER_FRAME: usize = MAX_SERVERS / FRAMES;
/// One answer per asking device in this long.
pub(crate) const ANSWER_EVERY: Duration = Duration::from_secs(10 * 60);
const ANSWERED_MAX: usize = 4096;
/// How long after a phrase recovery this device asks its friends.
pub(crate) const RECOVERY_WINDOW_MS: i64 = 30 * 24 * 60 * 60 * 1000;

/// One shared server: what joining it the ordinary way needs, and who else is there.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct SharedServer {
    pub server_id: String,
    /// The invite's `owner=` pin; empty for a self-certifying id.
    #[serde(default)]
    pub owner: String,
    /// The invite's `key=`.
    #[serde(default)]
    pub join_key: String,
    /// The relay the friend reaches it on.
    #[serde(default)]
    pub relay: String,
    /// Member identities the friend's state holds there, by standing (R31-9).
    #[serde(default)]
    pub members: Vec<String>,
}

/// The size every frame pads to: 16 entries at their largest.
pub(crate) fn frame_bytes() -> usize {
    let full = SharedServer {
        server_id: "f".repeat(64),
        owner: "1".repeat(64),
        join_key: "k".repeat(64),
        relay: "r".repeat(253),
        members: vec!["m".repeat(64); MAX_MEMBERS],
    };
    let msg = HavenMessage::SharedServers { ask: false, servers: vec![full; PER_FRAME], part: 0, pad: String::new() };
    serde_json::to_vec(&msg).map_or(0, |v| v.len())
}

/// When each (our device, asking device) was last answered: the event loops of the
/// harness share this process.
static ANSWERED: Mutex<Option<HashMap<(String, String), Instant>>> = Mutex::new(None);

fn may_answer(local_device: &str, asker: &str, now: Instant) -> bool {
    let mut guard = ANSWERED.lock().unwrap_or_else(|e| e.into_inner());
    let map = guard.get_or_insert_with(HashMap::new);
    let key = (local_device.to_string(), asker.to_string());
    if map.get(&key).is_some_and(|at| now.saturating_duration_since(*at) < ANSWER_EVERY) {
        return false;
    }
    if map.len() >= ANSWERED_MAX {
        map.retain(|_, at| now.saturating_duration_since(*at) < ANSWER_EVERY);
        if map.len() >= ANSWERED_MAX {
            return false;
        }
    }
    map.insert(key, now);
    true
}

#[cfg(test)]
static REFUSED: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new());

/// Harness: `local_device` left `asker`'s ask unanswered.
#[cfg(test)]
pub(crate) fn note_refused(local_device: &str, asker: &str) {
    REFUSED.lock().unwrap_or_else(|e| e.into_inner()).push((local_device.to_string(), asker.to_string()));
}

#[cfg(not(test))]
#[inline(always)]
pub(crate) fn note_refused(_local_device: &str, _asker: &str) {}

/// Harness: how many of `asker`'s asks `local_device` left unanswered.
#[cfg(test)]
pub(crate) fn refused_for_test(local_device: &str, asker: &str) -> usize {
    REFUSED.lock().unwrap_or_else(|e| e.into_inner()).iter().filter(|(d, a)| d == local_device && a == asker).count()
}

/// Whether we answer `asker`: an accepted friend's device our BOOK counts for that
/// friend's identity (first-party statements only, never a roster a co-member delivered).
/// A minted key or a removed device of the friend gets nothing.
pub(crate) fn asker_ok(store: &MessageStore, db_path: &str, asker: &str) -> Option<String> {
    let master = super::resolver::resolve(asker);
    let accepted = store.get_friend_row(&master).ok().flatten().is_some_and(|(status, ..)| status == "accepted");
    let counted = !super::authority_view::ignored_for_test(db_path, &master)
        && super::roster_book::load(store, &master).is_some_and(|r| r.authority().counts(asker));
    (accepted && !super::blocklist::is_blocked(&master) && counted).then_some(master)
}

/// The entries for `master`: servers whose state lists it as a member, owned ones first.
pub(crate) fn entries<'a>(states: impl IntoIterator<Item = &'a ServerState>, master: &str, relay: &str) -> Vec<SharedServer> {
    let mut shared: Vec<&ServerState> = states
        .into_iter()
        .filter(|s| !super::conference::is_conference_sid(&s.server_id) && !s.is_deleted() && s.members.contains_key(master))
        .collect();
    shared.sort_by(|a, b| {
        let owns = |s: &ServerState| s.current_owner().as_deref() != Some(master);
        owns(a).cmp(&owns(b)).then_with(|| a.server_id.cmp(&b.server_id))
    });
    shared
        .into_iter()
        .take(MAX_SERVERS)
        .map(|s| SharedServer {
            server_id: s.server_id.clone(),
            owner: (!crate::crdt::anchor::is_genesis_id(&s.server_id)).then(|| s.anchor_owner()).flatten().unwrap_or_default(),
            join_key: s.join_public_text().unwrap_or_default(),
            // Where the server lives, which a friend's join must reach (`home_relay`).
            relay: s.home_relay().unwrap_or_else(|| relay.to_string()),
            members: super::standing::rank_masters(s, s.members.keys().cloned()).into_iter().take(MAX_MEMBERS).collect(),
        })
        .collect()
}

/// `entries` as the four frames of one size every answer is.
pub(crate) fn frames(entries: Vec<SharedServer>) -> Vec<HavenMessage> {
    let size = frame_bytes();
    let mut chunks: Vec<Vec<SharedServer>> = entries.chunks(PER_FRAME).map(<[SharedServer]>::to_vec).collect();
    chunks.resize(FRAMES, Vec::new());
    chunks
        .into_iter()
        .enumerate()
        .map(|(part, servers)| {
            let mut msg = HavenMessage::SharedServers { ask: false, servers, part: part as u8, pad: String::new() };
            let len = serde_json::to_vec(&msg).map_or(size, |v| v.len());
            // `,"pad":""` is what an empty pad adds once it is written.
            let pad_len = size.saturating_sub(len + 9);
            if let HavenMessage::SharedServers { pad, .. } = &mut msg {
                *pad = " ".repeat(pad_len);
            }
            msg
        })
        .collect()
}

/// Our answer to `asker`'s ask, when it may have one now.
pub(crate) fn answer<'a>(
    db_path: &str,
    db_passphrase: &str,
    local_device: &str,
    asker: &str,
    states: impl IntoIterator<Item = &'a ServerState>,
) -> Option<Vec<HavenMessage>> {
    let store = MessageStore::lease(db_path, db_passphrase).ok()?;
    let master = asker_ok(&store, db_path, asker)?;
    if !may_answer(local_device, asker, Instant::now()) {
        return None;
    }
    let relay = super::ws_client::relay_home().unwrap_or_default();
    Some(frames(entries(states, &master, &relay)))
}

/// Whether this device asks friends for the servers we share: it typed our identity's
/// newest phrase recovery within the window (its T is recorded here; a device that held
/// servers before the recovery qualifies too), or a Welcome phrase admission put it into
/// an empty database within the window and our roster still counts it (PHRASE_RESTORE
/// 3, R2). A removal never drops the admission statement, so membership decides.
pub(crate) fn recovering(local_master: &str, local_device: &str, db_path: &str, db_passphrase: &str) -> bool {
    MessageStore::lease(db_path, db_passphrase).is_ok_and(|s| recovering_in(&s, local_master, local_device, super::types::now_ms()))
}

pub(crate) fn recovering_in(store: &MessageStore, local_master: &str, local_device: &str, now_ms: i64) -> bool {
    let Some(roster) = super::roster_book::load(store, local_master) else { return false };
    let recovered = roster.recoveries.iter().map(|r| r.at_ms).max().is_some_and(|at| {
        now_ms.saturating_sub(at) < RECOVERY_WINDOW_MS && super::roster_book::recovery_lost_since(store, &roster.base()).is_some()
    });
    recovered
        || super::phrase_restore::current(store, local_device, now_ms).is_some_and(|m| {
            m.branch == super::phrase_restore::Branch::Admit
                && m.empty
                && super::roster_book::fold(store, &roster).is_member(local_device)
        })
}

/// The longest relay domain an entry may name.
const RELAY_MAX: usize = 253;

/// Whether a received frame is no larger than every honest frame is: anything bigger is
/// dropped whole, before an entry is read.
pub(crate) fn frame_fits(servers: &[SharedServer], pad: &str) -> bool {
    servers.len() <= PER_FRAME && serde_json::to_vec(servers).map_or(usize::MAX, |v| v.len()).saturating_add(pad.len()) <= frame_bytes()
}

/// The entries of an answer from `from` we act on: only from a friend device we count,
/// only joinable ids with a well-formed key, pin and relay, each server once, at most
/// [`PER_FRAME`]; member ids only of a peer id's shape, each once, at most [`MAX_MEMBERS`].
pub(crate) fn accepted(store: &MessageStore, db_path: &str, from: &str, servers: &[SharedServer]) -> Vec<SharedServer> {
    if asker_ok(store, db_path, from).is_none() {
        return Vec::new();
    }
    let mut seen = std::collections::HashSet::new();
    servers
        .iter()
        .filter(|s| {
            super::sync_handler::joinable_server_id(&s.server_id)
                && super::sealed_box::key_from_text(&s.join_key).is_some()
                && (s.owner.is_empty() || super::witness::peer_id_shape(&s.owner))
                && s.relay.len() <= RELAY_MAX
                && s.relay.bytes().all(|b| b.is_ascii_graphic())
        })
        .filter(|s| seen.insert(s.server_id.clone()))
        .take(PER_FRAME)
        .map(|s| {
            let mut ids = std::collections::HashSet::new();
            let members = s.members.iter().filter(|m| super::witness::peer_id_shape(m) && ids.insert(m.as_str())).take(MAX_MEMBERS).cloned().collect();
            SharedServer { members, ..s.clone() }
        })
        .collect()
}

/// Which friend devices this recovering device asked, and which answered.
#[derive(Default)]
pub(crate) struct Asks {
    /// When we asked, how many answer frames we took since, and whether a friend's
    /// accept already asked again inside [`ASK_AGAIN`].
    asked: HashMap<String, (Instant, usize, bool)>,
    answered: std::collections::HashSet<String>,
}

/// A device re-asks a friend device no sooner than this after its last ask.
const ASK_AGAIN: Duration = Duration::from_secs(60);

impl Asks {
    /// Take one answer frame from `device`: only from a device we asked, and at most
    /// [`FRAMES`] per ask. An answer nobody asked for joins nothing.
    pub(crate) fn take_frame(&mut self, device: &str) -> bool {
        let Some((_, taken, _)) = self.asked.get_mut(device) else { return false };
        *taken += 1;
        if *taken >= FRAMES {
            self.asked.remove(device);
        }
        if self.answered.len() < ANSWERED_MAX {
            self.answered.insert(device.to_string());
        }
        true
    }

    /// `accepted`: the device's accept of our friend request just landed. It answers the
    /// request that carried our roster, so an ask it left unanswered for want of that
    /// roster is sent again at once, once per [`ASK_AGAIN`].
    fn may_ask(&mut self, device: &str, now: Instant, accepted: bool) -> bool {
        if self.answered.contains(device) {
            return false;
        }
        if let Some((at, _, reasked)) = self.asked.get(device)
            && now.saturating_duration_since(*at) < ASK_AGAIN
            && !(accepted && !*reasked)
        {
            return false;
        }
        if self.asked.len() >= ANSWERED_MAX {
            self.asked.retain(|_, (at, ..)| now.saturating_duration_since(*at) < ASK_AGAIN);
            if self.asked.len() >= ANSWERED_MAX {
                return false;
            }
        }
        let reasked = self.asked.get(device).is_some_and(|(at, ..)| now.saturating_duration_since(*at) < ASK_AGAIN);
        self.asked.insert(device.to_string(), (now, 0, reasked));
        true
    }
}

/// A shared server waiting for the event loop, and the friend who named it.
#[derive(Debug, Clone)]
pub(crate) struct Queued {
    pub entry: SharedServer,
    pub friend: String,
}

/// Why a shared server waits for the person instead of being joined.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum HeldWhy {
    /// No member let this device back in as a member it already is: joining would be a
    /// new admission, which only the person may ask for.
    NotAMember,
    /// It lives on another relay (`relay_switch_dialog`).
    OtherRelay,
}

/// A server a friend says we share that this device did not re-enter on its own: the
/// person confirms it (an ordinary join with `join_key` and `owner`) or dismisses it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct HeldShare {
    pub server_id: String,
    /// The invite's `owner=` pin; empty for a self-certifying id.
    pub owner: String,
    pub join_key: String,
    pub relay: String,
    /// The friend's master id.
    pub friend: String,
    pub why: HeldWhy,
}

/// Held shares per node (database path), at most [`MAX_SERVERS`] each.
static HELD: Mutex<Option<HashMap<String, Vec<HeldShare>>>> = Mutex::new(None);

fn hold(db_path: &str, queued: &Queued, why: HeldWhy) {
    let mut guard = HELD.lock().unwrap_or_else(|e| e.into_inner());
    let list = guard.get_or_insert_with(HashMap::new).entry(db_path.to_string()).or_default();
    if list.iter().any(|h| h.server_id == queued.entry.server_id) || list.len() >= MAX_SERVERS {
        return;
    }
    hollow_log!("[HOLLOW-SERVER] Holding {} a friend says we share for the person to confirm ({why:?})", queued.entry.server_id);
    list.push(HeldShare {
        server_id: queued.entry.server_id.clone(),
        owner: queued.entry.owner.clone(),
        join_key: queued.entry.join_key.clone(),
        relay: queued.entry.relay.clone(),
        friend: queued.friend.clone(),
        why,
    });
}

/// The shared servers waiting for the person on the node at `db_path` (for the UI).
#[allow(dead_code)] // read by the recovery screen's FFI (track C2 UI)
pub(crate) fn held_shares(db_path: &str) -> Vec<HeldShare> {
    HELD.lock().unwrap_or_else(|e| e.into_inner()).as_ref().and_then(|m| m.get(db_path).cloned()).unwrap_or_default()
}

/// The person answered `server_id` (joined or dismissed it): it leaves the list.
#[allow(dead_code)] // read by the recovery screen's FFI (track C2 UI)
pub(crate) fn take_held_share(db_path: &str, server_id: &str) -> Option<HeldShare> {
    let mut guard = HELD.lock().unwrap_or_else(|e| e.into_inner());
    let list = guard.as_mut()?.get_mut(db_path)?;
    let at = list.iter().position(|h| h.server_id == server_id)?;
    Some(list.remove(at))
}

/// How long a re-entry may wait for a member's answer before the person decides.
pub(crate) const REENTRY_WAIT: Duration = Duration::from_secs(if cfg!(test) { 8 } else { 90 });
/// Shared servers joined at once per event-loop tick.
const JOINS_PER_TICK: usize = 4;

/// Shared servers on their way: queued for the tick, then re-entries in flight.
#[derive(Default)]
pub(crate) struct Joins {
    queue: std::collections::VecDeque<Queued>,
    started: HashMap<String, (Queued, Instant)>,
}

impl Joins {
    /// Queue `entry` from `friend`, unless it is already on its way or held; at most
    /// [`MAX_SERVERS`] in all. An entry on another relay waits for the person.
    pub(crate) fn offer(&mut self, db_path: &str, entry: SharedServer, friend: &str, our_relay: &str) {
        let queued = Queued { entry, friend: friend.to_string() };
        let sid = &queued.entry.server_id;
        if self.started.contains_key(sid) || self.queue.iter().any(|q| q.entry.server_id == *sid) {
            return;
        }
        if !queued.entry.relay.is_empty() && queued.entry.relay != our_relay {
            hold(db_path, &queued, HeldWhy::OtherRelay);
            return;
        }
        if self.queue.len() + self.started.len() >= MAX_SERVERS {
            hollow_log!("[HOLLOW-SERVER] Dropped a shared server past the {MAX_SERVERS} on their way");
            return;
        }
        self.queue.push_back(queued);
    }

    /// The entries to start now, at most [`JOINS_PER_TICK`]; each counts as started.
    pub(crate) fn due(&mut self, now: Instant) -> Vec<SharedServer> {
        let n = self.queue.len().min(JOINS_PER_TICK);
        self.queue
            .drain(..n)
            .map(|q| {
                let entry = q.entry.clone();
                self.started.insert(entry.server_id.clone(), (q, now));
                entry
            })
            .collect()
    }

    /// Re-entries no member answered within [`REENTRY_WAIT`]: they wait for the person.
    /// `joined` tells a server we now hold; `reentry` one whose re-entry is still pending.
    pub(crate) fn lapsed(&mut self, db_path: &str, now: Instant, joined: &dyn Fn(&str) -> bool) -> Vec<String> {
        let mut out = Vec::new();
        self.started.retain(|sid, (q, at)| {
            if joined(sid) {
                return false;
            }
            if now.saturating_duration_since(*at) < REENTRY_WAIT {
                return true;
            }
            hold(db_path, q, HeldWhy::NotAMember);
            out.push(sid.clone());
            false
        });
        out
    }
}

/// Start the join of `entry` as a RE-ENTRY: no ask is signed, so a member can only send
/// back a state that already lists our identity (the `already_member` arm); no member
/// can admit us anew on a friend's word. Nothing is persisted: after a restart the
/// friends are asked again.
#[allow(clippy::too_many_arguments)]
pub(crate) fn start_reentry(
    pending_server_joins: &mut HashMap<String, super::types::PendingJoin>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    entry: SharedServer,
    local_master: &str,
    device_peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    if pending_server_joins.contains_key(&entry.server_id) || !super::sync_handler::joinable_server_id(&entry.server_id) {
        return;
    }
    hollow_log!("[HOLLOW-SERVER] Re-entering {} a friend says we share", entry.server_id);
    let mut pending = super::types::PendingJoin {
        owner_pin: (!entry.owner.is_empty() && !crate::crdt::anchor::is_genesis_id(&entry.server_id)).then_some(entry.owner),
        device_list: super::roster_book::join_roster(local_master, device_peer_id, db_path, db_passphrase),
        join_key: Some(entry.join_key),
        reply_secret: super::join_lane::ReplySecret::new(),
        reentry: true,
        ..Default::default()
    };
    super::age_gate::unsettle_at(db_path, db_passphrase, &entry.server_id);
    super::sync_handler::request_join_lock(ws_cmd_tx, &entry.server_id, &mut pending);
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom { room_code: entry.server_id.clone() });
    pending_server_joins.insert(entry.server_id, pending);
}

/// Ask friend device `peer` which servers we share, when we are a recovering fresh start,
/// it is an accepted friend's device in our DM room with it, and it has not answered yet.
/// `live_only`, so this runs again each time the device arrives (LOW), and on its
/// accept (`after_accept`): our first ask can reach it before the roster that counts us.
#[allow(clippy::too_many_arguments)]
pub(crate) fn ask_if_recovering(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    asks: &mut Asks,
    room: Option<&str>,
    after_accept: bool,
    peer: &str,
    local_master: &str,
    local_device: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    let master = super::resolver::resolve(peer);
    if room.is_some_and(|r| r != super::dm_room::dm_room_code(local_master, &master)) {
        return;
    }
    let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return };
    let accepted = store.get_friend_row(&master).ok().flatten().is_some_and(|(status, ..)| status == "accepted");
    if !accepted || !recovering(local_master, local_device, db_path, db_passphrase) || !asks.may_ask(peer, Instant::now(), after_accept) {
        return;
    }
    hollow_log!("[HOLLOW-SERVER] Asking {peer} which servers we share");
    let ask = HavenMessage::SharedServers { ask: true, servers: Vec::new(), part: 0, pad: String::new() };
    super::olm_lane::carry(ws_cmd_tx, peer, None, &ask, super::olm_lane::NoSession::Queue);
}

/// Times a recovering device sends its `RosterNotice` into a server room it starts
/// joining, and how far apart (DEVICE_PROOF_DESIGN 8.7 step 3): a hidden sender's frame
/// reaches only a few provers, picked afresh per frame.
pub(crate) const NOTICE_TIMES: u8 = 3;
pub(crate) const NOTICE_EVERY: Duration = Duration::from_secs(if cfg!(test) { 2 } else { 10 });

/// The server rooms owed a recovering device's notice: (when next, how many left).
#[derive(Default)]
pub(crate) struct RoomNotices(HashMap<String, (Instant, u8)>);

impl RoomNotices {
    /// A join of `server` started while recovering: the first notice goes at once.
    pub(crate) fn start(&mut self, server: &str, now: Instant) {
        if self.0.len() >= MAX_SERVERS && !self.0.contains_key(server) {
            return;
        }
        self.0.entry(server.to_string()).or_insert((now, NOTICE_TIMES));
    }

    /// The rooms whose notice is due now.
    pub(crate) fn due(&mut self, now: Instant) -> Vec<String> {
        let mut out = Vec::new();
        self.0.retain(|server, (next, left)| {
            if now < *next {
                return true;
            }
            out.push(server.clone());
            *left -= 1;
            *next = now + NOTICE_EVERY;
            *left > 0
        });
        out.sort();
        out
    }
}

/// Our roster's notice into each of `servers`' rooms.
pub(crate) fn send_room_notices(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    servers: &[String],
    local_master: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    if servers.is_empty() {
        return;
    }
    let Some(roster) = super::roster_book::own_roster(local_master, db_path, db_passphrase) else { return };
    let Ok(data) = serde_json::to_vec(&HavenMessage::RosterNotice { roster }) else { return };
    super::roster_book::notice_into_server_rooms(ws_cmd_tx, &data, servers.iter());
}

#[cfg(test)]
#[path = "shared_servers_tests.rs"]
mod tests;
