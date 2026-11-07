//! The roster half of a CRDT sync round (DEVICE_PROOF_DESIGN section 9): who an answer
//! is served to, what rosters and floor candidate it carries, and what the asker does
//! with them. Rosters travel before ops: an answerer that cannot place the asking device
//! serves nothing and says `roster_needed`; the asker asks again with its roster.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::crdt::digest::OpDigest;
use crate::crdt::operations::CrdtOp;
use crate::crdt::server_state::ServerState;
use crate::storage::MessageStore;

use super::sync_ext::{AskExt, ReplyExt};
use super::types::HavenMessage;

/// How often one (server, device) is asked again with our roster or our base.
const AGAIN_EVERY: Duration = Duration::from_secs(if cfg!(test) { 2 } else { 60 });
const AGAIN_MAX: usize = 4096;

/// Roster bytes we hand over, as (burst, per second): to one asking device, and to all of
/// them. A roster ask is a few KB; its answer up to [`super::sync_ext::MAX_ROSTER_ANSWER_BYTES`].
const ROSTERS_ASKER: (f64, f64) = (super::sync_ext::MAX_ROSTER_ANSWER_BYTES as f64, 2.0 * 1024.0);
const ROSTERS_ALL: (f64, f64) = if cfg!(any(target_os = "android", target_os = "ios")) {
    (2.0 * super::sync_ext::MAX_ROSTER_ANSWER_BYTES as f64, 8.0 * 1024.0)
} else {
    (4.0 * super::sync_ext::MAX_ROSTER_ANSWER_BYTES as f64, 16.0 * 1024.0)
};
/// Asking devices whose budget is not full yet; a new one past this gets nothing.
const ROSTER_ASKERS_MAX: usize = 4096;

/// What roster answers may still cost (`server_rosters::answer` charges each roster at
/// least its verification): per asking device and in all.
#[derive(Default)]
pub(crate) struct RosterServe {
    askers: HashMap<String, (f64, Instant)>,
    all: Option<(f64, Instant)>,
}

fn refill((left, at): &mut (f64, Instant), (burst, per_sec): (f64, f64), now: Instant) {
    *left = (*left + now.saturating_duration_since(*at).as_secs_f64() * per_sec).min(burst);
    *at = now;
}

impl RosterServe {
    fn refill_all(&mut self, now: Instant) {
        refill(self.all.get_or_insert((ROSTERS_ALL.0, now)), ROSTERS_ALL, now);
        for b in self.askers.values_mut() {
            refill(b, ROSTERS_ASKER, now);
        }
        self.askers.retain(|_, (left, _)| *left < ROSTERS_ASKER.0);
    }

    /// The bytes `asker` may be handed now.
    pub(crate) fn allowance(&mut self, asker: &str, now: Instant) -> usize {
        self.refill_all(now);
        let mine = match self.askers.get(asker) {
            Some((left, _)) => *left,
            None if self.askers.len() >= ROSTER_ASKERS_MAX => 0.0,
            None => ROSTERS_ASKER.0,
        };
        let all = self.all.map_or(0.0, |(left, _)| left);
        mine.min(all).max(0.0) as usize
    }

    /// `asker` was handed `bytes`.
    pub(crate) fn spend(&mut self, asker: &str, bytes: usize, now: Instant) {
        if bytes == 0 {
            return;
        }
        self.refill_all(now);
        if let Some((left, _)) = self.all.as_mut() {
            *left -= bytes as f64;
        }
        if !self.askers.contains_key(asker) && self.askers.len() >= ROSTER_ASKERS_MAX {
            return;
        }
        self.askers.entry(asker.to_string()).or_insert((ROSTERS_ASKER.0, now)).0 -= bytes as f64;
    }
}

/// Whether our view counts `device` for an identity `state` keeps (a member, or one a
/// recovery's hold keeps, section 8.8). A device no roster we hold places, a removed one,
/// a pending join and the bare master are all refused.
pub(crate) fn asker_counted(db_path: &str, db_passphrase: &str, state: &ServerState, device: &str) -> bool {
    let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return false };
    super::server_rosters::place(&store, db_path, state, device).is_some_and(|master| state.keeps_peer(&master))
}

/// What a sync ask gets before anything is served (section 9, responders).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AskerVerdict {
    /// The ordinary path: a counted device of a kept identity, or a known non-member.
    Serve,
    /// `roster_needed` and nothing else.
    RosterNeeded,
    /// No answer at all: a stranger never learns which servers we hold.
    Silent,
}

/// The verdict on a sync ask from `device` for `state`. A device of an identity the
/// server keeps but our view does not count gets `roster_needed`; so does a device no
/// roster we hold places, but only when its ask carried a roster of its own for a master
/// the server names that counts it (`own_roster`, a member's device linked since, N10).
pub(crate) fn asker_verdict(db_path: &str, db_passphrase: &str, state: &ServerState, device: &str, own_roster: bool) -> AskerVerdict {
    if state.keeps_peer(device) {
        return if asker_counted(db_path, db_passphrase, state, device) { AskerVerdict::Serve } else { AskerVerdict::RosterNeeded };
    }
    let unplaced = super::resolver::resolve(device) == device
        && MessageStore::lease(db_path, db_passphrase).is_ok_and(|s| super::roster_book::load(&s, device).is_none());
    match (unplaced, own_roster) {
        (false, _) => AskerVerdict::Serve,
        (true, true) => AskerVerdict::RosterNeeded,
        (true, false) => AskerVerdict::Silent,
    }
}

/// Our (master, digest) pairs in the buckets where the ask's roster prints differ.
pub(crate) fn rd_for(db_path: &str, db_passphrase: &str, state: &ServerState, ask: &OpDigest) -> Vec<(String, String)> {
    let Some(theirs) = ask.rs.as_deref() else { return Vec::new() };
    let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return Vec::new() };
    super::server_rosters::differing(&super::server_rosters::entries(&store, db_path, state), theirs, &ask.salt)
}

/// [`reply_ext_within`] with no budget but the answer's own bound.
#[cfg(test)]
pub(crate) fn reply_ext(
    db_path: &str,
    db_passphrase: &str,
    state: &ServerState,
    ask: Option<&AskExt>,
    digest: Option<&OpDigest>,
    given: Option<&crate::crdt::fold::Base>,
) -> ReplyExt {
    reply_ext_within(db_path, db_passphrase, state, ask, digest, given, None)
}

/// What an answer to a counted member's ask carries besides ops. `given` is the base the
/// asker sent after we said we lacked it ([`BaseTold::given`]); the rosters it hands over
/// are paid from `serve`'s budget for the asking device.
pub(crate) fn reply_ext_within(
    db_path: &str,
    db_passphrase: &str,
    state: &ServerState,
    ask: Option<&AskExt>,
    digest: Option<&OpDigest>,
    given: Option<&crate::crdt::fold::Base>,
    serve: Option<(&mut RosterServe, &str)>,
) -> ReplyExt {
    let mut out = ReplyExt::default();
    let wanted = ask.map(|a| a.rosters_wanted.as_slice()).unwrap_or_default();
    if !wanted.is_empty()
        && let Ok(store) = MessageStore::lease(db_path, db_passphrase)
    {
        let now = Instant::now();
        let mut serve = serve;
        let limit = serve.as_mut().map_or(usize::MAX, |(s, asker)| s.allowance(asker, now));
        let (handed, charged) = super::server_rosters::answer(&store, db_path, state, wanted, limit);
        if let Some((s, asker)) = serve {
            s.spend(asker, charged, now);
        }
        out.rosters = handed;
    }
    out.base_unknown = ask.is_some_and(|a| a.named_base) && given.is_none() && digest.is_some_and(|d| base_unknown(state, d));
    out.floor_base = floor_base(state, ask.is_some_and(|a| a.floor));
    out
}

/// The asker's base by content id, when we do not hold it.
fn base_unknown(state: &ServerState, d: &OpDigest) -> bool {
    let Some(bref) = d.bref.as_deref() else { return false };
    let ours = state.base.as_ref().map(|b| b.hash_hex());
    ours.as_deref() != Some(bref) && state.base_by_hash(bref).is_none()
}

/// The base refs we told each (server, asking device) we lack: a `base_content` is read
/// only in answer to one of them, and only once per ask.
#[derive(Default)]
pub(crate) struct BaseTold(HashMap<(String, String), (String, Instant)>);

/// How long a `base_unknown` we sent waits for the asker's `base_content`.
const BASE_TOLD_FOR: Duration = Duration::from_secs(10 * 60);

impl BaseTold {
    /// We answered `device`'s ask for `server` with `base_unknown` for `bref`.
    pub(crate) fn told(&mut self, server: &str, device: &str, bref: &str, now: Instant) {
        if self.0.len() >= AGAIN_MAX {
            self.0.retain(|_, (_, at)| now.saturating_duration_since(*at) < BASE_TOLD_FOR);
            if self.0.len() >= AGAIN_MAX {
                return;
            }
        }
        self.0.insert((server.to_string(), device.to_string()), (bref.to_string(), now));
    }

    /// The base `device`'s ask carries, read and checked once, when we asked it for that
    /// base; `None` for any other ask, however much it carries.
    pub(crate) fn given(
        &self,
        state: &ServerState,
        device: &str,
        d: Option<&OpDigest>,
        ask: Option<&AskExt>,
        now: Instant,
    ) -> Option<crate::crdt::fold::Base> {
        let d = d?;
        ask?.base_content.as_ref()?;
        let (bref, at) = self.0.get(&(state.server_id.clone(), device.to_string()))?;
        if d.bref.as_deref() != Some(bref.as_str()) || now.saturating_duration_since(*at) >= BASE_TOLD_FOR {
            return None;
        }
        given_base(state, d, ask)
    }
}

/// The base an asker sent after we said we lacked it, checked as a base and naming the
/// checkpoint its digest names.
pub(crate) fn given_base(state: &ServerState, d: &OpDigest, ask: Option<&AskExt>) -> Option<crate::crdt::fold::Base> {
    let bref = d.bref.as_deref()?;
    let op = super::sync_ext::read_base_op(ask?.base_content.as_deref()?)?;
    // The base only narrows what we send back to the asker, but a forged one is still
    // refused: signed by the owner and within its bound.
    op.verify_author().ok()?;
    state.base_of_content(&op).filter(|b| b.hash_hex() == bref)
}

/// Our floor candidate (section 8.8): the pre-trigger base of a recovery in progress
/// here, else our current base.
fn floor_base(state: &ServerState, floor_round: bool) -> Option<String> {
    let op = crate::crdt::authority::floor_base_offer(state, floor_round)?;
    let json = serde_json::to_string(&op).ok()?;
    (json.len() <= super::sync_ext::MAX_BASE_OP_BYTES).then_some(json)
}

/// The most roster bytes a join answer carries beside its ops.
pub(crate) const JOIN_ROSTER_BYTES: usize = 256 * 1024;

/// The rosters a join answer carries: the owner's and each author's of the ops it sends,
/// as our view holds them, so a joiner that knows none of them can count the ops that
/// admit it (section 9; it has no Olm session to ask with yet).
pub(crate) fn join_answer_rosters<'a>(
    db_path: &str,
    db_passphrase: &str,
    state: &ServerState,
    ops: impl IntoIterator<Item = &'a CrdtOp>,
) -> Vec<crate::identity::roster::Roster> {
    let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return Vec::new() };
    let mut wanted: Vec<String> = state.anchor_owner().into_iter().collect();
    for op in ops {
        if !wanted.contains(&op.author) {
            wanted.push(op.author.clone());
        }
    }
    super::server_rosters::answer(&store, db_path, state, &wanted, JOIN_ROSTER_BYTES).0
}

/// The answer's extension when it is an answer to a join of ours with rosters to keep:
/// only while the join is pending and from a sender our state does not yet hold as a
/// member (a member's rosters went through [`on_reply`]).
pub(crate) fn join_reply(x: Option<&ReplyExt>, joining: bool, from_member: bool) -> Option<&ReplyExt> {
    x.filter(|x| joining && !from_member && !x.rosters.is_empty())
}

/// Keep the rosters an answer to our pending join carries, for masters of the joining
/// state's authority set (the anchor owner before the fold, the authors it parked
/// after), and judge them again: the masters whose view changed.
pub(crate) fn keep_join_rosters(db_path: &str, db_passphrase: &str, state: &mut ServerState, x: &ReplyExt) -> Vec<String> {
    let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return Vec::new() };
    let now = super::types::now_ms();
    let mut changed = Vec::new();
    for roster in x.rosters.iter().take(super::sync_ext::MAX_ROSTERS_WANTED) {
        if super::server_rosters::keep(&store, db_path, state, roster, now) == super::server_rosters::Kept::Changed {
            changed.push(roster.master.clone());
        }
    }
    changed.retain(|m| state.refresh_view_of(m) || state.authority.entry(m).is_none());
    changed
}

/// What the asker does with an answer's extra fields.
#[derive(Default)]
pub(crate) struct OnReply {
    /// Asks to send back to the answering device.
    pub again: Vec<HavenMessage>,
    /// A delivered roster changed the view of these masters (section 10's rebuild).
    pub changed: Vec<String>,
    /// The floor candidate the answerer returned, unchecked (track C1 judges it).
    pub floor_base: Option<CrdtOp>,
}

/// When each (server, device) was last asked again with our roster or base, and how
/// often in a row: each retry waits twice as long, up to an hour.
#[derive(Default)]
pub(crate) struct Again(HashMap<(String, String), (Instant, u32)>);

const AGAIN_CAP: Duration = Duration::from_secs(3600);

impl Again {
    fn wait(tries: u32) -> Duration {
        AGAIN_EVERY.saturating_mul(1u32 << tries.min(16)).min(AGAIN_CAP)
    }

    fn may(&mut self, server: &str, device: &str, now: Instant) -> bool {
        let key = (server.to_string(), device.to_string());
        let tries = match self.0.get(&key) {
            Some((at, tries)) if now.saturating_duration_since(*at) < Self::wait(*tries) => return false,
            // A quiet hour starts the ladder again.
            Some((at, _)) if now.saturating_duration_since(*at) >= AGAIN_CAP + Self::wait(0) => 0,
            Some((_, tries)) => tries + 1,
            None => 0,
        };
        if self.0.len() >= AGAIN_MAX {
            self.0.retain(|_, (at, tries)| now.saturating_duration_since(*at) < Self::wait(*tries));
        }
        self.0.insert(key, (now, tries));
        true
    }
}

/// Take an answer's rosters into `server_rosters`, and ask again with our roster or the
/// base we named when the answerer could not use the ask.
#[allow(clippy::too_many_arguments)]
pub(crate) fn on_reply(
    db_path: &str,
    db_passphrase: &str,
    crdt_resync: &mut super::crdt_resync::CrdtResync,
    again: &mut Again,
    state: Option<&ServerState>,
    peer: &str,
    nonce: Option<u64>,
    mls_epoch: Option<u64>,
    x: &ReplyExt,
) -> OnReply {
    let mut out = OnReply::default();
    let Some(state) = state else { return out };
    if !x.rosters.is_empty()
        && let Ok(store) = MessageStore::lease(db_path, db_passphrase)
    {
        let (now, at) = (super::types::now_ms(), Instant::now());
        for roster in x.rosters.iter().take(super::sync_ext::MAX_ROSTERS_WANTED) {
            let asked = crdt_resync.roster_round.post_asked_of(&state.server_id, &roster.master, peer, at);
            let kept = if asked {
                super::server_rosters::keep_asked(&store, db_path, state, roster, now)
            } else {
                super::server_rosters::keep(&store, db_path, state, roster, now)
            };
            if kept == super::server_rosters::Kept::Changed {
                out.changed.push(roster.master.clone());
            }
            if asked && kept != super::server_rosters::Kept::Refused {
                crdt_resync.roster_round.post_roster_landed(&state.server_id, &roster.master, at);
            }
        }
    }
    let now = Instant::now();
    if x.roster_needed {
        crdt_resync.op_sync.close(&state.server_id, peer);
    }
    if x.roster_needed && again.may(&state.server_id, peer, now) {
        crdt_resync.op_sync.resend_roster_to(peer);
        out.again.push(crdt_resync.sync_ask(state, peer, nonce, mls_epoch));
    }
    if x.base_unknown
        && again.may(&format!("{}\0base", state.server_id), peer, now)
        && let Some(mut ask) = crdt_resync.op_sync.last_ask(&state.server_id, peer)
        && let HavenMessage::SyncRequest { digest: Some(d), x: ask_x, .. } = &mut ask
        && let Some(op) = d.bref.as_deref().and_then(|r| crate::crdt::authority::base_content_for(state, r))
        && let Ok(json) = serde_json::to_string(&op)
        && json.len() <= super::sync_ext::MAX_BASE_OP_BYTES
    {
        ask_x.get_or_insert_with(Default::default).base_content = Some(json);
        out.again.push(ask);
    }
    out.floor_base = x.floor_base.as_deref().and_then(super::sync_ext::read_base_op);
    out
}

#[cfg(test)]
#[path = "sync_rosters_tests.rs"]
mod tests;
