//! Fetching back the CRDT ops this replica skipped.
//!
//! A sync delta holds each author's ops newer than the newest we hold from them, so an
//! op an older build could not read is never sent again once a later op by the same
//! author arrived. Such an op is KEPT as its author signed it (bounded, fair per author)
//! and read again when a newer build starts. A server is MARKED due where that cannot
//! cover it: the first start of a sweeping build, or a kept op lost to the bound. A due
//! mark asks ONE member device for its whole log, a page at a time, and clears once the
//! last page of that ask was folded in, from a responder not marked itself, or from two
//! identities that are (the union of two logs). Only an anchored replica asks: the fold
//! makes a full log safe to take in any order, a legacy replica applies in arrival order
//! (AR-10) and waits for its owner's checkpoint.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use super::crdt_store::CrdtStore;
use super::types::{HavenMessage, ServerStates};
use crate::crdt::hlc::HlcTimestamp;
use crate::crdt::operations::{CrdtOp, MemberRole, ReadOp, UnreadOp};
use crate::crdt::server_state::{Anchor, ServerState};

/// The server blob a mark lives in.
pub(crate) const MARK_KEY: &str = "crdt_resync";
/// The server blob holding the skipped ops we keep.
pub(crate) const KEPT_KEY: &str = "crdt_resync_kept";
/// The app setting naming the newest sweep this database ran.
pub(crate) const SWEEP_KEY: &str = "crdt_resync_sweep";
/// Bumped when a release knows older builds dropped ops before any mark recorded it:
/// every server is marked once on the first start of that release.
const SWEEP_GENERATION: u32 = 1;

/// Skipped ops kept per server, by count and by bytes; a larger op is not kept at all.
const KEPT_OPS: usize = 128;
const KEPT_BYTES: usize = 512 * 1024;
const KEPT_OP_BYTES: usize = 64 * 1024;

const PAGE_OPS: usize = if cfg!(test) { 8 } else { 200 };
const PAGE_BYTES: usize = 512 * 1024;
/// A responder that never ends its log is given up on.
const MAX_PAGES: u32 = 10_000;
const ASK_TIMEOUT: Duration = Duration::from_secs(if cfg!(test) { 8 } else { 30 });
/// A device that declined, timed out, cannot page or handed a marked log is not asked
/// again for this long.
const TRIED_FOR: Duration = Duration::from_secs(30 * 60);
/// A device over its serving budget is asked again this soon.
const BUSY_SKIP: Duration = Duration::from_secs(if cfg!(test) { 2 } else { 120 });
/// Mid-log, a busy device is asked for the same page again after this, this many times.
const BUSY_RETRY: Duration = Duration::from_millis(if cfg!(test) { 300 } else { 20_000 });
const MAX_BUSY: u32 = 6;
/// Our page asks to one device go at most this often, inside its per-asker budget.
const PAGE_GAP: Duration = Duration::from_millis(if cfg!(test) { 0 } else { 2_500 });
/// Servers fetched at once, so an upgrade does not pull every log in one burst.
const IN_FLIGHT: usize = 2;
const TICK_GAP: Duration = Duration::from_millis(if cfg!(test) { 300 } else { 1000 });
/// Asks start at a random point this long after a start, so a release does not have
/// every member ask at once.
const START_JITTER_MS: u64 = if cfg!(test) { 200 } else { 120_000 };

/// Pages we serve, as (burst, per second): to one asking device, and to all of them.
const SERVE_ASKER: (f64, f64) = (6.0, if cfg!(test) { 20.0 } else { 0.5 });
const SERVE_ALL: (f64, f64) = if cfg!(test) {
    (40.0, 40.0)
} else if cfg!(any(target_os = "android", target_os = "ios")) {
    (10.0, 0.5)
} else {
    (20.0, 1.5)
};

/// A server's resync state, persisted per server (`MARK_KEY`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Mark {
    /// Fetch the whole log from a member: we may lack ops this build reads.
    #[serde(default)]
    pub due: bool,
    /// The build that skipped a signed op it could not read: our log may lack ops a
    /// newer build reads.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lacks: Option<String>,
    /// A skipped op of that build was not kept: the next build fetches the log.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub lost: bool,
    /// The identities (masters) whose marked whole log we folded in while due.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub partial_from: Vec<String>,
}

impl Mark {
    /// Our log may lack an op someone reads: what we serve is partial.
    fn partial(&self) -> bool {
        self.due || self.lacks.is_some()
    }
}

/// A skipped op as its author signed it (`KEPT_KEY`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Kept {
    pub author: String,
    pub hlc: HlcTimestamp,
    /// The newest build that could not read it.
    pub build: String,
    pub raw: String,
}

/// Where a page starts: after the op at this fold position (`fold_key`).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct PageCursor {
    pub at: HlcTimestamp,
    #[serde(default)]
    pub checkpoint: bool,
}

impl PageCursor {
    fn of(op: &CrdtOp) -> Self {
        let (at, checkpoint) = crate::crdt::server_state::fold_key(op);
        Self { at: at.clone(), checkpoint }
    }
}

/// `SyncRequest.full`: an ask for the responder's whole log, one page at a time. An
/// older client ignores it and answers the state vector, a page-less answer.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct FullAsk {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<PageCursor>,
}

/// `SyncResponse.page`: the answer to a `FullAsk`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct FullPage {
    /// Where the next page starts; none on the last.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next: Option<PageCursor>,
    /// The responder will not hand its log as whole: it is legacy and capped, or gone.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub declined: bool,
    /// The responder is marked itself: its log may lack an op, so alone it clears no mark.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub partial: bool,
    /// The responder is over its serving budget: no page now.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub busy: bool,
}

struct Ask {
    device: String,
    nonce: u64,
    /// When the page ask last left, or last waited in the device's paced queue.
    sent_at: Instant,
    /// A page ask not sent yet: paced, or waiting out a busy answer.
    send_at: Option<Instant>,
    pages: u32,
    after: Option<PageCursor>,
    /// A page of this ask came from a marked responder.
    partial: bool,
    busy: u32,
}

/// What an answer from a peer is to our asks.
#[derive(Debug, PartialEq)]
pub(crate) enum Claim {
    /// Not the answer to the page we asked: an ordinary sync answer.
    Unrelated,
    /// The asked page; the next one starts at the cursor.
    Page(Option<PageCursor>),
    /// The asked device answered without a page (an older client) or declined.
    Released,
    /// The asked device is over its serving budget.
    Busy,
}

struct Tokens {
    left: f64,
    at: Instant,
}

impl Tokens {
    fn refill(&mut self, (burst, per_sec): (f64, f64), now: Instant) {
        self.left = (self.left + now.saturating_duration_since(self.at).as_secs_f64() * per_sec).min(burst);
        self.at = now;
    }
}

/// The pages we may serve: per asking device and in all.
#[derive(Default)]
struct ServeBudget {
    askers: HashMap<String, Tokens>,
    all: Option<Tokens>,
}

impl ServeBudget {
    fn take(&mut self, asker: &str, now: Instant) -> bool {
        let all = self.all.get_or_insert(Tokens { left: SERVE_ALL.0, at: now });
        all.refill(SERVE_ALL, now);
        for t in self.askers.values_mut() {
            t.refill(SERVE_ASKER, now);
        }
        self.askers.retain(|_, t| t.left < SERVE_ASKER.0);
        let mine = self.askers.entry(asker.to_string()).or_insert(Tokens { left: SERVE_ASKER.0, at: now });
        if all.left < 1.0 || mine.left < 1.0 {
            return false;
        }
        all.left -= 1.0;
        mine.left -= 1.0;
        true
    }
}

pub(crate) struct CrdtResync {
    store: Option<CrdtStore>,
    build: String,
    marks: HashMap<String, Mark>,
    kept: HashMap<String, Vec<Kept>>,
    asks: HashMap<String, Ask>,
    /// (server, device) -> when it may be asked again.
    tried: HashMap<(String, String), Instant>,
    /// (server, device) that handed us a marked log since we started.
    partial_seen: HashSet<(String, String)>,
    serving: ServeBudget,
    next_tick: Option<Instant>,
    /// Digest asks and what each peer device reads (`op_sync`).
    pub(crate) op_sync: super::op_sync::OpSync,
}

impl CrdtResync {
    /// The marks and kept ops of the servers we hold, before the event loop starts. A
    /// newer build reads the kept ops again and folds in the ones it reads. On the
    /// first start of a build with a newer sweep every server is marked due, and so is
    /// one whose skipped ops were not all kept.
    pub(crate) fn load(db: &crate::storage::MessageStore, states: &mut ServerStates, store: CrdtStore, build: &str) -> Self {
        let sweep = match db.load_setting(SWEEP_KEY) {
            Ok(v) => v.and_then(|g| g.parse::<u32>().ok()).unwrap_or(0) < SWEEP_GENERATION,
            Err(_) => false,
        };
        let mut saved = true;
        let (mut turned, mut read_again) = (0usize, 0usize);
        let mut book = Self::with_marks(Some(store), build, HashMap::new());
        let mut ids: Vec<String> = states.keys().cloned().collect();
        ids.sort();
        for sid in ids {
            let stored: Mark = load_blob(db, &sid, MARK_KEY).unwrap_or_default();
            let stored_kept: Vec<Kept> = load_blob(db, &sid, KEPT_KEY).unwrap_or_default();
            let mut mark = stored.clone();
            let mut kept = stored_kept.clone();
            let older = mark.lacks.as_deref().is_some_and(|b| b != build);
            if older {
                // What we did not keep only a member's log brings back.
                mark.due |= mark.lost || kept.is_empty();
                mark.lost = false;
            }
            let ops = read_kept_again(&mut kept, build);
            let _ = db.begin_transaction();
            if !ops.is_empty()
                && let Some(state) = states.get_mut(&sid)
            {
                read_again += ops.len();
                let ingested = state.ingest_remote(&ops);
                if !ingested.admitted.is_empty() || ingested.rebuilt {
                    db.persist_admitted_ops(&ingested.admitted, state.checkpoint_hlc.as_ref());
                    saved &= serde_json::to_string(&state.lean_snapshot())
                        .map_err(|e| e.to_string())
                        .and_then(|json| db.save_server_state(&sid, &json))
                        .is_ok();
                }
            }
            if older || kept != stored_kept {
                mark.lacks = (!kept.is_empty() || mark.lost).then(|| build.to_string());
            }
            mark.due |= sweep;
            turned += usize::from(mark.due && !stored.due);
            if kept != stored_kept {
                saved &= save_blob(db, &sid, KEPT_KEY, (!kept.is_empty()).then_some(&kept));
            }
            if mark != stored {
                saved &= save_blob(db, &sid, MARK_KEY, (mark != Mark::default()).then_some(&mark));
            }
            saved &= db.commit_transaction().is_ok();
            if mark != Mark::default() {
                book.marks.insert(sid.clone(), mark);
            }
            if !kept.is_empty() {
                book.kept.insert(sid, kept);
            }
        }
        // A sweep whose marks did not all land runs again on the next start.
        if sweep && saved {
            let _ = db.save_setting(SWEEP_KEY, &SWEEP_GENERATION.to_string());
        }
        if read_again > 0 {
            hollow_log!("[HOLLOW-CRDT] Read {read_again} kept op(s) an older build skipped again");
        }
        if turned > 0 {
            hollow_log!("[HOLLOW-CRDT] {turned} server(s) marked to fetch their whole op log again");
        }
        if book.marks.values().any(|m| m.due) {
            book.next_tick = Some(Instant::now() + Duration::from_millis(fresh_nonce() % (START_JITTER_MS + 1)));
        }
        book
    }

    /// No mark could be read: none is acted on until the next start reads them.
    pub(crate) fn load_none(store: CrdtStore, build: &str) -> Self {
        Self::with_marks(Some(store), build, HashMap::new())
    }

    fn with_marks(store: Option<CrdtStore>, build: &str, marks: HashMap<String, Mark>) -> Self {
        Self {
            store,
            build: build.to_string(),
            marks,
            kept: HashMap::new(),
            asks: HashMap::new(),
            tried: HashMap::new(),
            partial_seen: HashSet::new(),
            serving: ServeBudget::default(),
            next_tick: None,
            op_sync: Default::default(),
        }
    }

    /// The signed ops of `server_id` we keep unread: part of what a digest compares.
    fn kept_refs<'k>(kept: &'k HashMap<String, Vec<Kept>>, server_id: &str) -> Vec<crate::crdt::digest::KeptRef<'k>> {
        kept
            .get(server_id)
            .map(|kept| {
                kept.iter().map(|k| crate::crdt::digest::KeptRef { author: &k.author, hlc: &k.hlc, raw: &k.raw }).collect()
            })
            .unwrap_or_default()
    }

    /// The CRDT sync ask for `state` to `device`, in the form that device reads.
    pub(crate) fn sync_ask(&mut self, state: &ServerState, device: &str, nonce: Option<u64>, mls_epoch: Option<u64>) -> HavenMessage {
        let kept = Self::kept_refs(&self.kept, &state.server_id);
        self.op_sync.ask(state, &kept, device, nonce, mls_epoch)
    }

    /// The next step after a digest answer from `device`.
    pub(crate) fn digest_answered(
        &mut self,
        state: &ServerState,
        device: &str,
        reply: &crate::crdt::digest::DigestReply,
    ) -> super::op_sync::Step {
        let kept = Self::kept_refs(&self.kept, &state.server_id);
        self.op_sync.answered(state, &kept, device, reply)
    }

    /// A member's digest answered from our log and kept ops: the ops JSON and the reply.
    /// `None` for an ask no honest member sends.
    pub(crate) fn answer_digest(
        &self,
        state: &ServerState,
        ask: &crate::crdt::digest::OpDigest,
    ) -> Option<(String, crate::crdt::digest::DigestReply)> {
        let kept = Self::kept_refs(&self.kept, &state.server_id);
        let entries = crate::crdt::digest::entries(state, &kept, ask.base.as_ref());
        let (items, reply) = crate::crdt::digest::answer(&entries, ask)?;
        Some((crate::crdt::digest::items_json(&items), reply))
    }

    /// Signed ops of `server_id` this build cannot read were skipped (vouched by the
    /// caller): keep them for a newer build, within the bound.
    pub(crate) fn note_skipped(&mut self, server_id: &str, unread: Vec<UnreadOp>) {
        if unread.is_empty() {
            return;
        }
        let kept = self.kept.entry(server_id.to_string()).or_default();
        let (mut changed, mut lost) = (false, false);
        for op in unread {
            if kept.iter().any(|k| k.author == op.author && k.hlc == op.hlc) {
                continue;
            }
            if op.raw.len() > KEPT_OP_BYTES {
                lost = true;
                continue;
            }
            kept.push(Kept { author: op.author, hlc: op.hlc, build: self.build.clone(), raw: op.raw });
            changed = true;
            lost |= trim_kept(kept);
        }
        let mark = self.marks.entry(server_id.to_string()).or_default();
        let before = mark.clone();
        mark.lacks = Some(self.build.clone());
        mark.lost |= lost;
        if before.lacks != mark.lacks {
            hollow_log!("[HOLLOW-CRDT] Skipped a signed op of {server_id} this build cannot read; kept for a newer build");
        }
        if *mark != before {
            self.persist(server_id);
        }
        if changed {
            self.persist_kept(server_id);
        }
    }

    /// Our answer to a member's full ask: one page of our log, flagged partial while we
    /// may lack ops ourselves; none when the log is not one to hand as whole, or the
    /// asker or all askers are over the budget.
    pub(crate) fn serve(&mut self, state: &ServerState, ask: &FullAsk, asker: &str, now: Instant) -> (String, FullPage) {
        if state.anchor() == Anchor::Legacy || state.is_deleted() {
            return ("[]".to_string(), FullPage { declined: true, ..FullPage::default() });
        }
        if !self.serving.take(asker, now) {
            return ("[]".to_string(), FullPage { busy: true, ..FullPage::default() });
        }
        let (ops_json, next) = page(&state.op_log, ask.after.as_ref());
        let partial = self.marks.get(&state.server_id).is_some_and(Mark::partial);
        (ops_json, FullPage { next, partial, ..FullPage::default() })
    }

    /// Send the page asks that are due, and ask for every due server one member device
    /// holds, a few servers at a time. `queued` tells whether our paced queue to a
    /// device still holds anything: an ask's clock runs only once it left.
    pub(crate) fn tick(
        &mut self,
        now: Instant,
        states: &ServerStates,
        room_peers: &HashMap<String, HashSet<String>>,
        us: &str,
        our_device: &str,
        queued: &dyn Fn(&str) -> bool,
    ) -> Vec<(String, HavenMessage)> {
        if self.marks.is_empty() || self.next_tick.is_some_and(|t| now < t) {
            return Vec::new();
        }
        self.next_tick = Some(now + TICK_GAP);
        let gone: Vec<String> = self
            .marks
            .keys()
            .chain(self.kept.keys())
            .filter(|sid| states.get(*sid).is_none_or(ServerState::is_deleted))
            .cloned()
            .collect();
        for sid in gone {
            self.forget(&sid);
        }
        let mut out = Vec::new();
        let mut expired = Vec::new();
        for (sid, ask) in &mut self.asks {
            match ask.send_at {
                Some(at) if now >= at => {
                    ask.send_at = None;
                    ask.sent_at = now;
                    out.push((ask.device.clone(), request(sid, "{}".to_string(), ask.nonce, ask.after.clone())));
                }
                Some(_) => {}
                None if queued(&ask.device) => ask.sent_at = now,
                None if now.duration_since(ask.sent_at) >= ASK_TIMEOUT => expired.push(sid.clone()),
                None => {}
            }
        }
        for sid in expired {
            hollow_log!("[HOLLOW-CRDT] No page of {sid}'s op log came back in time; another member is asked");
            self.release(&sid, now, TRIED_FOR);
        }
        self.tried.retain(|_, until| now < *until);

        let mut due: Vec<&String> = self.marks.iter().filter(|(_, m)| m.due).map(|(sid, _)| sid).collect();
        due.sort();
        let mut asks = Vec::new();
        for sid in due {
            if self.asks.len() + asks.len() >= IN_FLIGHT {
                break;
            }
            if self.asks.contains_key(sid) {
                continue;
            }
            let Some(state) = states.get(sid) else { continue };
            // A legacy replica applies in arrival order: a whole log would replay drained
            // ops over newer state. It waits for its owner's checkpoint (AR-10).
            if state.anchor() == Anchor::Legacy || state.is_deleted() || !state.is_member(us) {
                continue;
            }
            let Some(device) = room_peers.get(sid).and_then(|peers| self.pick(sid, state, peers, our_device, now)) else {
                continue;
            };
            let vector = serde_json::to_string(&crate::crdt::sync::StateVector::from_server_state(state)).unwrap_or_default();
            let nonce = fresh_nonce();
            hollow_log!("[HOLLOW-CRDT] Asking {device} for the whole op log of {sid}");
            out.push((device.clone(), request(sid, vector, nonce, None)));
            asks.push((
                sid.clone(),
                Ask { device, nonce, sent_at: now, send_at: None, pages: 0, after: None, partial: false, busy: 0 },
            ));
        }
        self.asks.extend(asks);
        out
    }

    /// The device to ask: one not known to hand a marked log, of an identity whose
    /// marked log we have not folded in yet; the owner's first, then an admin's, then
    /// any member's, each tier spread over its devices by who asks.
    fn pick(&self, sid: &str, state: &ServerState, peers: &HashSet<String>, our_device: &str, now: Instant) -> Option<String> {
        let owner = state.current_owner();
        let counted = self.marks.get(sid).map(|m| m.partial_from.as_slice()).unwrap_or_default();
        peers
            .iter()
            .filter(|d| d.as_str() != our_device && !super::resolver::is_bare_master(d) && state.is_member(d))
            .filter(|d| self.tried.get(&(sid.to_string(), (*d).clone())).is_none_or(|until| now >= *until))
            .filter(|d| !counted.contains(&super::resolver::resolve(d)))
            .min_by_key(|d| {
                let master = super::resolver::resolve(d);
                let rank = if owner.as_deref() == Some(master.as_str()) {
                    0
                } else if state.get_role(&master) == MemberRole::Admin {
                    1
                } else {
                    2
                };
                let marked = self.partial_seen.contains(&(sid.to_string(), (*d).clone()));
                (marked, rank, spread(our_device, d))
            })
            .cloned()
    }

    /// Whether `from`'s sync answer is the answer to the page we asked it for.
    pub(crate) fn claim(&mut self, server_id: &str, from: &str, nonce: Option<u64>, page: Option<&FullPage>, now: Instant) -> Claim {
        let Some(ask) = self.asks.get_mut(server_id) else { return Claim::Unrelated };
        if ask.device != from || nonce != Some(ask.nonce) {
            return Claim::Unrelated;
        }
        let (skip, claim) = match page {
            Some(p) if p.busy => {
                // Mid-log the cursor is worth waiting for; on the first page another
                // device may serve at once.
                if ask.pages > 0 && ask.busy < MAX_BUSY {
                    ask.busy += 1;
                    ask.nonce = fresh_nonce();
                    ask.send_at = Some(now + BUSY_RETRY);
                    return Claim::Busy;
                }
                hollow_log!("[HOLLOW-CRDT] {from} is too busy to hand {server_id}'s whole op log now");
                (BUSY_SKIP, Claim::Busy)
            }
            Some(p) if p.declined => {
                hollow_log!("[HOLLOW-CRDT] {from} declined to hand {server_id}'s whole op log");
                (TRIED_FOR, Claim::Released)
            }
            Some(p) => {
                ask.partial |= p.partial;
                ask.busy = 0;
                if p.partial {
                    self.partial_seen.insert((server_id.to_string(), from.to_string()));
                }
                return Claim::Page(p.next.clone());
            }
            None => {
                hollow_log!("[HOLLOW-CRDT] {from} cannot page {server_id}'s op log (an older client)");
                (TRIED_FOR, Claim::Released)
            }
        };
        self.release(server_id, now, skip);
        claim
    }

    /// The claimed page was folded in (`ok`), or could not be: ask for the next page,
    /// or end the ask. The mark clears only when the last page was folded in.
    pub(crate) fn paged(
        &mut self,
        server_id: &str,
        ok: bool,
        next: Option<PageCursor>,
        states: &ServerStates,
        us: &str,
        now: Instant,
    ) -> Option<(String, HavenMessage)> {
        if !self.asks.contains_key(server_id) {
            return None;
        }
        if !states.get(server_id).is_some_and(|s| s.is_member(us) && !s.is_deleted()) {
            self.forget(server_id);
            return None;
        }
        if !ok {
            hollow_log!("[HOLLOW-CRDT] A page of {server_id}'s op log did not fold in; the server stays marked");
            self.release(server_id, now, TRIED_FOR);
            return None;
        }
        let Some(cursor) = next else {
            let ask = self.asks.remove(server_id)?;
            self.finish(server_id, &ask.device, ask.partial, us, now);
            return None;
        };
        let ask = self.asks.get_mut(server_id)?;
        if ask.after.as_ref().is_some_and(|after| cursor <= *after) || ask.pages + 1 >= MAX_PAGES {
            hollow_log!("[HOLLOW-CRDT] {} handed a page of {server_id}'s op log that does not move on; giving up on it", ask.device);
            self.release(server_id, now, TRIED_FOR);
            return None;
        }
        ask.pages += 1;
        ask.after = Some(cursor.clone());
        ask.nonce = fresh_nonce();
        let at = ask.sent_at + PAGE_GAP;
        if now < at {
            ask.send_at = Some(at);
            return None;
        }
        ask.sent_at = now;
        // A page ask only a client that pages reads: an older one finds no vector.
        Some((ask.device.clone(), request(server_id, "{}".to_string(), ask.nonce, Some(cursor))))
    }

    /// The server left our hands (left, kicked, deleted): its mark and kept ops go too.
    pub(crate) fn forget(&mut self, server_id: &str) {
        self.asks.remove(server_id);
        self.tried.retain(|(sid, _), _| sid != server_id);
        self.partial_seen.retain(|(sid, _)| sid != server_id);
        if self.marks.remove(server_id).is_some() {
            self.persist(server_id);
        }
        if self.kept.remove(server_id).is_some() {
            self.persist_kept(server_id);
        }
    }

    /// The last page of an ask to `device` folded in. A marked responder's log counts
    /// once per identity, and two of them clear the mark.
    fn finish(&mut self, server_id: &str, device: &str, partial: bool, us: &str, now: Instant) {
        let Some(mark) = self.marks.get_mut(server_id) else { return };
        if partial {
            let master = super::resolver::resolve(device);
            if !super::resolver::same_identity(&master, us) && !mark.partial_from.contains(&master) {
                mark.partial_from.push(master);
            }
            if mark.partial_from.len() < 2 {
                hollow_log!(
                    "[HOLLOW-CRDT] Fetched {server_id}'s whole op log from {device}, which may lack ops itself; {} of 2 identities",
                    mark.partial_from.len(),
                );
                self.tried.insert((server_id.to_string(), device.to_string()), now + TRIED_FOR);
                self.persist(server_id);
                return;
            }
        }
        mark.due = false;
        mark.partial_from.clear();
        hollow_log!("[HOLLOW-CRDT] Fetched {server_id}'s whole op log again");
        self.persist(server_id);
    }

    fn release(&mut self, server_id: &str, now: Instant, skip: Duration) {
        if let Some(ask) = self.asks.remove(server_id) {
            self.tried.insert((server_id.to_string(), ask.device), now + skip);
        }
    }

    fn persist(&mut self, server_id: &str) {
        let mark = self.marks.get(server_id).filter(|m| **m != Mark::default()).cloned();
        if mark.is_none() {
            self.marks.remove(server_id);
        }
        let Some(store) = &self.store else { return };
        match mark.and_then(|m| serde_json::to_string(&m).ok()) {
            Some(json) => store.save_blob(server_id.to_string(), MARK_KEY.to_string(), json),
            None => store.delete_blob(server_id.to_string(), MARK_KEY.to_string()),
        }
    }

    fn persist_kept(&mut self, server_id: &str) {
        let kept = self.kept.get(server_id).filter(|k| !k.is_empty()).cloned();
        if kept.is_none() {
            self.kept.remove(server_id);
        }
        let Some(store) = &self.store else { return };
        match kept.and_then(|k| serde_json::to_string(&k).ok()) {
            Some(json) => store.save_blob(server_id.to_string(), KEPT_KEY.to_string(), json),
            None => store.delete_blob(server_id.to_string(), KEPT_KEY.to_string()),
        }
    }

    /// (marks, server -> asked device), for the harness.
    #[cfg(test)]
    pub(crate) fn debug(&self) -> (HashMap<String, Mark>, HashMap<String, String>) {
        (self.marks.clone(), self.asks.iter().map(|(sid, a)| (sid.clone(), a.device.clone())).collect())
    }
}

fn load_blob<T: serde::de::DeserializeOwned>(db: &crate::storage::MessageStore, server_id: &str, key: &str) -> Option<T> {
    db.load_server_blob(server_id, key).ok().flatten().and_then(|j| serde_json::from_str(&j).ok())
}

/// Store `value`, or delete the blob for none; whether it landed.
fn save_blob<T: Serialize>(db: &crate::storage::MessageStore, server_id: &str, key: &str, value: Option<&T>) -> bool {
    match value {
        Some(v) => serde_json::to_string(v).is_ok_and(|json| db.save_server_blob(server_id, key, &json).is_ok()),
        None => db.delete_server_blob(server_id, key).is_ok(),
    }
}

/// The kept ops an older build skipped that `build` reads now, taken out of `kept`;
/// what it still cannot read stays, now as `build`'s.
fn read_kept_again(kept: &mut Vec<Kept>, build: &str) -> Vec<CrdtOp> {
    let mut ops = Vec::new();
    kept.retain_mut(|k| {
        if k.build == build {
            return true;
        }
        match crate::crdt::operations::read_op(&k.raw) {
            ReadOp::Op(op) => {
                ops.push(op);
                false
            }
            ReadOp::Unread(_) => {
                k.build = build.to_string();
                true
            }
            ReadOp::Junk => false,
        }
    });
    ops
}

/// Bring `kept` within its bound: the author holding the most of what is over (ops or
/// bytes) gives up its oldest op first, so one author's flood pushes out only its own.
/// Whether anything was given up.
fn trim_kept(kept: &mut Vec<Kept>) -> bool {
    let mut trimmed = false;
    loop {
        let by_count = kept.len() > KEPT_OPS;
        if !by_count && kept.iter().map(|k| k.raw.len()).sum::<usize>() <= KEPT_BYTES {
            return trimmed;
        }
        let mut shares: HashMap<&str, (usize, usize)> = HashMap::new();
        for k in kept.iter() {
            let share = shares.entry(k.author.as_str()).or_default();
            share.0 += 1;
            share.1 += k.raw.len();
        }
        let weight = |&(n, bytes): &(usize, usize)| if by_count { (n, bytes) } else { (bytes, n) };
        let Some(heaviest) = shares.into_iter().max_by(|a, b| weight(&a.1).cmp(&weight(&b.1)).then(a.0.cmp(b.0))).map(|(a, _)| a.to_string())
        else {
            return trimmed;
        };
        let oldest = kept.iter().enumerate().filter(|(_, k)| k.author == heaviest).min_by(|a, b| a.1.hlc.cmp(&b.1.hlc)).map(|(i, _)| i);
        let Some(oldest) = oldest else { return trimmed };
        kept.remove(oldest);
        trimmed = true;
    }
}

/// Where `asker`'s ask lands among a tier's devices: the same for every ask it makes,
/// spread over askers.
fn spread(asker: &str, responder: &str) -> [u8; 8] {
    use sha2::Digest as _;
    let digest = sha2::Sha256::new().chain_update(b"hollow-resync-spread\0").chain_update(asker).chain_update(b"\0").chain_update(responder).finalize();
    let mut out = [0u8; 8];
    out.copy_from_slice(&digest[..8]);
    out
}

/// Whether a skipped op counts as one we lack: signed by a current member of the server
/// it names. Anyone else's junk marks nothing.
pub(crate) fn vouched(unread: &UnreadOp, state: &ServerState) -> bool {
    unread.server_id == state.server_id && state.is_member(&unread.author)
}

/// `op_json`, one op from a live path, as this build reads it. A member's signed op it
/// cannot read is kept for a newer build.
pub(crate) fn read_live_op(resync: &mut CrdtResync, state: Option<&ServerState>, server_id: &str, op_json: &str) -> Option<CrdtOp> {
    match crate::crdt::operations::read_op(op_json) {
        ReadOp::Op(op) => Some(op),
        ReadOp::Unread(op) => {
            if state.is_some_and(|s| vouched(&op, s)) {
                resync.note_skipped(server_id, vec![op]);
            }
            None
        }
        ReadOp::Junk => None,
    }
}

fn request(server_id: &str, state_vector_json: String, nonce: u64, after: Option<PageCursor>) -> HavenMessage {
    HavenMessage::SyncRequest {
        server_id: server_id.to_string(),
        state_vector_json,
        mls_epoch: None,
        nonce: Some(nonce),
        full: Some(FullAsk { after }),
        digest: None,
        dg: Some(super::op_sync::DG),
    }
}

fn fresh_nonce() -> u64 {
    let mut b = [0u8; 8];
    let _ = getrandom::fill(&mut b);
    u64::from_le_bytes(b)
}

/// One page of `log` (in fold order) after `after`: at most `PAGE_OPS` ops or about
/// `PAGE_BYTES`, never splitting ops that share a fold position. `next` is none on the
/// last page.
pub(crate) fn page(log: &[CrdtOp], after: Option<&PageCursor>) -> (String, Option<PageCursor>) {
    let start = after.map_or(0, |c| log.partition_point(|op| PageCursor::of(op) <= *c));
    let mut parts: Vec<String> = Vec::new();
    let mut bytes = 0usize;
    let mut end = start;
    while let Some(op) = log.get(end) {
        let full = parts.len() >= PAGE_OPS || bytes >= PAGE_BYTES;
        if full && PageCursor::of(op) != PageCursor::of(&log[end - 1]) {
            break;
        }
        if let Ok(json) = serde_json::to_string(op) {
            bytes += json.len();
            parts.push(json);
        }
        end += 1;
    }
    let next = (end < log.len()).then(|| PageCursor::of(&log[end - 1]));
    (format!("[{}]", parts.join(",")), next)
}

/// What folding one page did.
#[derive(Debug, Default)]
pub(crate) struct PageIngest {
    /// The page parsed and every op in it was judged.
    pub ok: bool,
    pub admitted: Vec<CrdtOp>,
    pub rebuilt: bool,
    /// The signed ops of members it skipped, unreadable to this build.
    pub unread: Vec<UnreadOp>,
    pub was_member: bool,
}

/// Fold one page into `server_id`'s state on a blocking thread: the parse, every op's
/// signature and the fold. The event loop awaits it, so nothing else reads the states
/// meanwhile. A panic in the fold unwinds the loop as one in any other ingest does; the
/// page's ops persist only after it returns, so disk keeps the state from before it.
pub(crate) async fn ingest_page(server_states: &mut ServerStates, server_id: &str, ops_json: String, us: &str) -> PageIngest {
    let Some(state) = server_states.remove(server_id) else { return PageIngest::default() };
    let us = us.to_string();
    let job = tokio::task::spawn_blocking(move || {
        let mut state = state;
        let parsed = crate::crdt::operations::parse_ops_tolerant(&ops_json);
        if parsed.malformed {
            return (state, None);
        }
        let was_member = state.is_member(&us);
        let ingested = state.ingest_remote(&parsed.ops);
        let unread = parsed.unread.into_iter().filter(|u| vouched(u, &state)).collect();
        (state, Some(PageIngest { ok: true, admitted: ingested.admitted, rebuilt: ingested.rebuilt, unread, was_member }))
    });
    match job.await {
        Ok((state, out)) => {
            server_states.insert(server_id.to_string(), state);
            out.unwrap_or_default()
        }
        Err(e) if e.is_panic() => std::panic::resume_unwind(e.into_panic()),
        Err(e) => {
            hollow_log!("[HOLLOW-CRDT] Lost {server_id}'s state folding a page of its op log: {e}");
            PageIngest::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::operations::CrdtPayload;
    use crate::crdt::server_state::MemberInfo;
    use crate::crdt::testkeys::keys;

    const BUILD: &str = "9.9.9";

    fn book(marks: &[(&str, Mark)]) -> CrdtResync {
        CrdtResync::with_marks(None, BUILD, marks.iter().map(|(s, m)| (s.to_string(), m.clone())).collect())
    }

    fn due() -> Mark {
        Mark { due: true, ..Mark::default() }
    }

    fn idle(_: &str) -> bool {
        false
    }

    /// A self-certifying server owned by tag 1 with `extra` channel ops after its
    /// founding, holding `members` as plain members.
    fn server_with(extra: usize, members: &[&str]) -> (ServerState, String) {
        let (kp, owner, pk) = keys(1);
        let (mut state, _) = ServerState::found("Test".into(), owner.clone(), kp, pk);
        for i in 0..extra {
            let op = state.create_op(CrdtPayload::ChannelAdded {
                channel_id: format!("c{i}"),
                name: format!("c{i}"),
                category: None,
                channel_type: "text".into(),
            });
            state.apply_op(&op).unwrap();
        }
        for m in members {
            state.members.insert(m.to_string(), MemberInfo { peer_id: m.to_string(), display_name: "m".into() });
        }
        assert_ne!(state.anchor(), Anchor::Legacy);
        (state, owner)
    }

    fn ask_of(out: &[(String, HavenMessage)]) -> (String, u64, Option<PageCursor>) {
        match &out[0].1 {
            HavenMessage::SyncRequest { nonce: Some(n), full: Some(f), .. } => (out[0].0.clone(), *n, f.after.clone()),
            other => panic!("not a full ask: {other:?}"),
        }
    }

    #[test]
    fn pages_cover_the_log_in_order_and_stay_bounded() {
        let (state, _) = server_with(3 * PAGE_OPS + 2, &[]);
        assert_eq!(state.op_log.len(), 3 * PAGE_OPS + 3);
        let mut after = None;
        let mut seen = Vec::new();
        let mut pages = 0;
        loop {
            let (json, next) = page(&state.op_log, after.as_ref());
            let ops: Vec<CrdtOp> = serde_json::from_str(&json).unwrap();
            assert!(!ops.is_empty() && ops.len() <= PAGE_OPS, "a page holds 1..=PAGE_OPS ops");
            seen.extend(ops.into_iter().map(|o| o.hlc));
            pages += 1;
            match next {
                Some(c) => after = Some(c),
                None => break,
            }
        }
        assert_eq!(pages, 4);
        let all: Vec<_> = state.op_log.iter().map(|o| o.hlc.clone()).collect();
        assert_eq!(seen, all, "every op once, in fold order");
        let (json, next) = page(&state.op_log, Some(&PageCursor::of(state.op_log.last().unwrap())));
        assert_eq!((json.as_str(), next), ("[]", None), "a cursor at the tail is the end");
    }

    /// A legacy replica declines; a marked one serves, its pages flagged partial.
    #[test]
    fn a_legacy_replica_declines_and_a_marked_one_serves_partial_pages() {
        let (state, _) = server_with(2, &[]);
        let sid = state.server_id.clone();
        let served = |b: &mut CrdtResync, s: &ServerState| b.serve(s, &FullAsk::default(), "asker", Instant::now()).1;
        let clean = served(&mut book(&[]), &state);
        assert!(!clean.declined && !clean.partial, "control: an unmarked anchored replica serves whole pages");
        let lacking = served(&mut book(&[(sid.as_str(), Mark { lacks: Some(BUILD.into()), ..Mark::default() })]), &state);
        assert!(!lacking.declined && lacking.partial, "a replica that skipped ops serves, flagged partial");
        let swept = served(&mut book(&[(sid.as_str(), due())]), &state);
        assert!(!swept.declined && swept.partial, "a swept replica serves, flagged partial");
        let legacy = ServerState::new("ab".repeat(16), "Old".into(), keys(1).1);
        assert_eq!(legacy.anchor(), Anchor::Legacy);
        assert!(served(&mut book(&[]), &legacy).declined, "a legacy replica served its capped log as whole");
    }

    /// M3: a responder serves a burst of pages to one asker, then that asker is busy
    /// while another still gets pages, until the shared budget runs out too; both come
    /// back as the budget refills.
    #[test]
    fn serving_is_budgeted_per_asker_and_in_all() {
        let (state, _) = server_with(2, &[]);
        let mut b = book(&[]);
        let now = Instant::now();
        let mut serve = |asker: &str, at: Instant| b.serve(&state, &FullAsk::default(), asker, at).1.busy;
        let burst = SERVE_ASKER.0 as usize;
        assert!((0..burst).all(|_| !serve("a", now)), "one asker's burst is served");
        assert!(serve("a", now), "an asker past its burst was served");
        assert!(!serve("b", now), "another asker waits on nobody's burst but its own");
        let all = SERVE_ALL.0 as usize;
        let mut askers = (0..).map(|n| format!("x{n}"));
        let mut served = burst + 1;
        while served < all {
            let asker = askers.next().unwrap();
            for _ in 0..burst.min(all - served) {
                assert!(!serve(&asker, now));
                served += 1;
            }
        }
        assert!(serve("fresh", now), "a fresh asker was served past the budget of all askers");
        let later = now + Duration::from_secs_f64(2.0 / SERVE_ALL.1.min(SERVE_ASKER.1));
        assert!(!serve("a", later) && !serve("fresh", later), "the budget refills");
    }

    #[test]
    fn a_legacy_replica_never_asks() {
        let me = keys(2).1;
        let legacy_id = "ab".repeat(16);
        let mut legacy = ServerState::new(legacy_id.clone(), "Old".into(), keys(1).1);
        legacy.members.insert(me.clone(), MemberInfo { peer_id: me.clone(), display_name: "m".into() });
        let peers = HashMap::from([(legacy_id.clone(), HashSet::from([keys(1).1]))]);
        let states = HashMap::from([(legacy_id.clone(), legacy)]);
        let mut b = book(&[(legacy_id.as_str(), due())]);
        assert!(b.tick(Instant::now(), &states, &peers, &me, &me, &idle).is_empty(), "a legacy replica asked for a whole log");
        assert!(b.marks[&legacy_id].due, "its mark waits for the owner's checkpoint");
    }

    /// The owner's device first, and only an answer naming the asked page from the asked
    /// device moves the ask; the mark clears after the LAST page only.
    #[test]
    fn only_the_asked_devices_answer_with_the_asks_nonce_clears_the_mark() {
        let (member, admin, me) = (keys(3).1, keys(4).1, keys(5).1);
        let (mut state, owner) = server_with(PAGE_OPS + 2, &[&member, &admin, &me]);
        state.roles.insert(admin.clone(), crate::crdt::admin_lww::AdminLwwReg::new(MemberRole::Admin, HlcTimestamp::zero(""), 0));
        let sid = state.server_id.clone();
        let s = sid.as_str();
        let states = HashMap::from([(sid.clone(), state)]);
        let peers = HashMap::from([(sid.clone(), HashSet::from([owner.clone(), member.clone(), admin.clone()]))]);
        let mut b = book(&[(s, due())]);
        let now = Instant::now();
        let out = b.tick(now, &states, &peers, &me, &me, &idle);
        let (device, nonce, after) = ask_of(&out);
        assert_eq!((device.as_str(), after), (owner.as_str(), None), "the owner's device is asked first");
        assert!(b.tick(now + TICK_GAP, &states, &peers, &me, &me, &idle).is_empty(), "one ask per server");

        let last = FullPage { next: None, declined: false, ..FullPage::default() };
        assert_eq!(b.claim(s, &admin, Some(nonce), Some(&last), now), Claim::Unrelated, "an unasked device's answer counted");
        assert_eq!(b.claim(s, &owner, Some(nonce ^ 1), Some(&last), now), Claim::Unrelated, "an answer to another ask counted");
        assert_eq!(b.claim(s, &owner, None, Some(&last), now), Claim::Unrelated);
        assert!(b.marks[s].due && b.asks.contains_key(s));

        let cursor = PageCursor::of(&states[s].op_log[PAGE_OPS - 1]);
        let more = FullPage { next: Some(cursor.clone()), declined: false, ..FullPage::default() };
        assert_eq!(b.claim(s, &owner, Some(nonce), Some(&more), now), Claim::Page(Some(cursor.clone())));
        let next = b.paged(s, true, Some(cursor.clone()), &states, &me, now).expect("the next page is asked");
        let (_, nonce2, after2) = ask_of(&[next]);
        assert_eq!(after2, Some(cursor.clone()));
        assert!(b.marks[s].due, "a middle page cleared the mark");
        assert_eq!(b.claim(s, &owner, Some(nonce), Some(&last), now), Claim::Unrelated, "the first page's nonce ended the ask");

        assert_eq!(b.claim(s, &owner, Some(nonce2), Some(&last), now), Claim::Page(None));
        assert!(b.paged(s, false, None, &states, &me, now).is_none());
        assert!(b.marks[s].due, "a last page that did not fold in cleared the mark");
        assert!(!b.asks.contains_key(s));

        // The owner is tried now: the admin is next, and its last page clears the mark.
        let out = b.tick(now + 2 * TICK_GAP, &states, &peers, &me, &me, &idle);
        let (device, nonce3, _) = ask_of(&out);
        assert_eq!(device, admin, "the admin's device is asked once the owner's was tried");
        assert_eq!(b.claim(s, &admin, Some(nonce3), Some(&last), now), Claim::Page(None));
        assert!(b.paged(s, true, None, &states, &me, now).is_none());
        assert!(!b.marks.contains_key(s), "the folded last page of the asked device clears the mark");
    }

    #[test]
    fn a_page_less_or_declined_answer_moves_on_and_a_page_must_advance() {
        let me = keys(5).1;
        let (state, owner) = server_with(2, &[&me]);
        let sid = state.server_id.clone();
        let s = sid.as_str();
        let states = HashMap::from([(sid.clone(), state)]);
        let peers = HashMap::from([(sid.clone(), HashSet::from([owner.clone()]))]);
        let mut b = book(&[(s, due())]);
        let now = Instant::now();
        let (_, nonce, _) = ask_of(&b.tick(now, &states, &peers, &me, &me, &idle));
        assert_eq!(b.claim(s, &owner, Some(nonce), None, now), Claim::Released, "an older client's plain answer");
        assert!(b.marks[s].due);
        assert!(b.tick(now + TICK_GAP, &states, &peers, &me, &me, &idle).is_empty(), "a tried device is not asked again at once");
        let later = now + TRIED_FOR + TICK_GAP;
        let (_, nonce, _) = ask_of(&b.tick(later, &states, &peers, &me, &me, &idle));
        let declined = FullPage { next: None, declined: true, ..FullPage::default() };
        assert_eq!(b.claim(s, &owner, Some(nonce), Some(&declined), later), Claim::Released, "a refusal");
        assert!(b.marks[s].due, "a refusal cleared the mark");
        let later = later + TRIED_FOR + TICK_GAP;
        let (_, nonce, _) = ask_of(&b.tick(later, &states, &peers, &me, &me, &idle));
        let c = PageCursor::of(&states[s].op_log[0]);
        let more = FullPage { next: Some(c.clone()), declined: false, ..FullPage::default() };
        assert_eq!(b.claim(s, &owner, Some(nonce), Some(&more), later), Claim::Page(Some(c.clone())));
        let (_, n2, _) = ask_of(&[b.paged(s, true, Some(c.clone()), &states, &me, later).unwrap()]);
        assert_eq!(b.claim(s, &owner, Some(n2), Some(&more), later), Claim::Page(Some(c.clone())));
        assert!(b.paged(s, true, Some(c), &states, &me, later).is_none(), "a page that does not move on ends the ask");
        assert!(b.marks[s].due);
    }

    #[test]
    fn a_timed_out_ask_frees_its_slot_and_keeps_the_mark() {
        let me = keys(5).1;
        let (state, owner) = server_with(1, &[&me]);
        let sid = state.server_id.clone();
        let states = HashMap::from([(sid.clone(), state)]);
        let peers = HashMap::from([(sid.clone(), HashSet::from([owner]))]);
        let mut b = book(&[(sid.as_str(), due())]);
        let now = Instant::now();
        assert_eq!(b.tick(now, &states, &peers, &me, &me, &idle).len(), 1);
        assert!(b.tick(now + ASK_TIMEOUT, &states, &peers, &me, &me, &idle).is_empty());
        assert!(!b.asks.contains_key(&sid) && b.marks[&sid].due);
    }

    /// The unknown-variant op `tag`'s identity signs for `state`'s server at `ms`.
    fn unread_by(tag: u8, state: &ServerState, ms: u64, variant: &str) -> UnreadOp {
        let (kp, author, pk) = keys(tag);
        let mut op = CrdtOp {
            server_id: state.server_id.clone(),
            hlc: HlcTimestamp { physical_ms: ms, counter: 0, actor: author.clone() },
            author,
            payload: CrdtPayload::ServerRenamed { new_name: "n".into() },
            auth: None,
        };
        op.sign(&kp, &pk);
        let mut v = serde_json::to_value(&op).unwrap();
        v["payload"] = serde_json::json!({ variant: { "x": "y".repeat(ms as usize % 7) } });
        let payload_json = serde_json::to_string(&v["payload"]).unwrap();
        let signed = crate::crdt::operations::signing_payload(&op.server_id, &op.hlc, &op.author, &payload_json);
        v["auth"]["sig"] = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, kp.sign(signed.as_bytes())).into();
        match crate::crdt::operations::read_op(&serde_json::to_string(&v).unwrap()) {
            ReadOp::Unread(u) => u,
            other => panic!("not unread: {other:?}"),
        }
    }

    /// This build's skip stays through a whole fetch: those ops are unreadable here
    /// whoever holds them, and keep our pages partial.
    #[test]
    fn a_skip_by_this_build_outlives_a_whole_fetch() {
        let (state, _) = server_with(0, &[]);
        let sid = state.server_id.clone();
        let mut b = book(&[(sid.as_str(), due())]);
        b.note_skipped(&sid, vec![unread_by(1, &state, 10, "Later")]);
        assert_eq!(b.marks[&sid].lacks.as_deref(), Some(BUILD));
        b.note_skipped("s3", vec![unread_by(1, &state, 11, "Later")]);
        assert_eq!(b.marks["s3"], Mark { lacks: Some(BUILD.into()), ..Mark::default() }, "a skip alone waits for a newer build");
        b.finish(&sid, "responder", false, "us", Instant::now());
        assert_eq!(b.marks[&sid], Mark { lacks: Some(BUILD.into()), ..Mark::default() }, "a fetch keeps this build's own skip");
        assert!(b.kept[&sid].len() == 1, "and its kept op");
    }

    /// M2: what is kept is bounded per server and fair per author: one author's flood
    /// pushes out only its own oldest ops, an op past the size bound is never kept, and
    /// anything not kept marks the server `lost`.
    #[test]
    fn kept_ops_are_bounded_and_a_flood_pushes_out_only_its_own() {
        let (state, _) = server_with(0, &[]);
        let sid = state.server_id.clone();
        let mut b = book(&[]);
        let honest: Vec<UnreadOp> = (0..3).map(|i| unread_by(2, &state, 100 + i, "Later")).collect();
        b.note_skipped(&sid, honest.clone());
        b.note_skipped(&sid, honest.clone());
        assert_eq!(b.kept[&sid].len(), 3, "an op heard twice is kept once");
        assert!(!b.marks[&sid].lost);
        let flood: Vec<UnreadOp> = (0..KEPT_OPS as u64 + 40).map(|i| unread_by(3, &state, 1_000 + i, "Junk")).collect();
        b.note_skipped(&sid, flood);
        let kept = &b.kept[&sid];
        assert_eq!(kept.len(), KEPT_OPS, "the count bound holds");
        assert!(honest.iter().all(|h| kept.iter().any(|k| k.hlc == h.hlc)), "a flood pushed out another author's ops");
        let flooder_oldest = kept.iter().filter(|k| k.author == keys(3).1).map(|k| k.hlc.physical_ms).min().unwrap();
        assert!(flooder_oldest > 1_000, "the flooder's oldest go first");
        assert!(b.marks[&sid].lost, "an op not kept marks the server lost");

        let mut b = book(&[]);
        let mut big = unread_by(2, &state, 7, "Later");
        big.raw = format!("{}{}", big.raw, " ".repeat(KEPT_OP_BYTES));
        b.note_skipped(&sid, vec![big]);
        assert!(b.kept.get(&sid).is_none_or(Vec::is_empty) && b.marks[&sid].lost, "an op past the size bound was kept");
        let mut b = book(&[]);
        let wide: Vec<UnreadOp> = (0..12u64)
            .map(|i| {
                let mut u = unread_by(if i == 0 { 2 } else { 3 }, &state, 50 + i, "Later");
                u.raw = format!("{}{}", u.raw, " ".repeat(KEPT_OP_BYTES - u.raw.len()));
                u
            })
            .collect();
        b.note_skipped(&sid, wide);
        let kept = &b.kept[&sid];
        assert!(kept.iter().map(|k| k.raw.len()).sum::<usize>() <= KEPT_BYTES, "the byte bound holds");
        assert!(kept.iter().any(|k| k.author == keys(2).1), "the byte bound pushed out the lighter author");

        // Over the byte bound, bytes decide: many small ops outweigh no large ones.
        let mut b = book(&[]);
        let small: Vec<UnreadOp> = (0..20u64).map(|i| unread_by(4, &state, 300 + i, "Later")).collect();
        b.note_skipped(&sid, small);
        let large: Vec<UnreadOp> = (0..9u64)
            .map(|i| {
                let mut u = unread_by(2, &state, 400 + i, "Later");
                u.raw = format!("{}{}", u.raw, " ".repeat(KEPT_OP_BYTES - u.raw.len()));
                u
            })
            .collect();
        b.note_skipped(&sid, large);
        let kept = &b.kept[&sid];
        assert_eq!(kept.iter().filter(|k| k.author == keys(4).1).count(), 20, "the byte bound pushed out an author of small ops");
    }

    fn store_in(dir: &crate::test_tmp::TestDir) -> (crate::storage::MessageStore, String, String) {
        let path = dir.path().join("marks.db").to_string_lossy().to_string();
        let pass = "ef".repeat(32);
        (crate::storage::MessageStore::open(&path, &pass).unwrap(), path, pass)
    }

    #[test]
    fn load_marks_every_server_once_and_turns_an_older_lost_skip_due() {
        let dir = crate::test_tmp::tempdir().unwrap();
        let (db, path, pass) = store_in(&dir);
        let rt = tokio::runtime::Runtime::new().unwrap();
        let _rt = rt.enter();
        let store = CrdtStore::open(path.clone(), pass.clone()).unwrap();
        // The shape the first cut of this build stored, without `lost`: it loads.
        db.save_server_blob("old", MARK_KEY, r#"{"due":false,"lacks":"0.12.0"}"#).unwrap();
        let lost = serde_json::to_string(&Mark { lacks: Some("0.12.0".into()), lost: true, ..Mark::default() }).unwrap();
        db.save_server_blob("lost", MARK_KEY, &lost).unwrap();
        let (probe, _) = server_with(0, &[]);
        let still = unread_by(1, &probe, 9, "StillLater");
        let kept = vec![Kept { author: still.author, hlc: still.hlc, build: "0.12.0".into(), raw: still.raw }];
        db.save_server_blob("lost", KEPT_KEY, &serde_json::to_string(&kept).unwrap()).unwrap();
        let ours = serde_json::to_string(&Mark { lacks: Some(BUILD.into()), ..Mark::default() }).unwrap();
        db.save_server_blob("same", MARK_KEY, &ours).unwrap();
        db.save_setting(SWEEP_KEY, &SWEEP_GENERATION.to_string()).unwrap();
        let ids = ["old", "lost", "same", "clean"];
        let mut states: ServerStates = ids.iter().map(|s| (s.to_string(), ServerState::new(s.to_string(), "S".into(), keys(1).1))).collect();
        let b = CrdtResync::load(&db, &mut states, store.clone(), BUILD);
        assert!(b.marks["old"].due, "an older build's skip with nothing kept turns due");
        assert_eq!(
            b.marks["lost"],
            Mark { due: true, lacks: Some(BUILD.into()), ..Mark::default() },
            "an older build's lost skip turns due though ops were kept, and the loss is handed to the mark",
        );
        assert!(!b.marks["same"].due, "this build's own skip stays dormant");
        assert!(!b.marks.contains_key("clean"));
        let stored: Mark = serde_json::from_str(&db.load_server_blob("old", MARK_KEY).unwrap().unwrap()).unwrap();
        assert!(stored.due, "the turn is stored");

        db.delete_setting(SWEEP_KEY).unwrap();
        let b = CrdtResync::load(&db, &mut states, store.clone(), BUILD);
        assert!(ids.iter().all(|s| b.marks[*s].due), "the first start of a sweeping build marks every server");
        assert_eq!(db.load_setting(SWEEP_KEY).unwrap().as_deref(), Some(SWEEP_GENERATION.to_string().as_str()));
        assert!(db.load_server_blob("clean", MARK_KEY).unwrap().is_some(), "a swept mark is stored before anyone answers");
        assert!(b.next_tick.is_some_and(|t| t <= Instant::now() + Duration::from_millis(START_JITTER_MS)), "asks start after a jitter");
        let b = CrdtResync::load(&db, &mut states, store, BUILD);
        assert!(b.marks["clean"].due, "the swept mark loads back after a restart");
    }

    /// M2: a newer build reads the ops an older one kept and folds them in at start, with
    /// no fetch: the kept row goes, the op is stored, the mark clears. What it still
    /// cannot read stays kept as its own skip; junk is dropped.
    #[test]
    fn a_newer_build_folds_in_what_an_older_one_kept() {
        let dir = crate::test_tmp::tempdir().unwrap();
        let (db, path, pass) = store_in(&dir);
        let rt = tokio::runtime::Runtime::new().unwrap();
        let _rt = rt.enter();
        let store = CrdtStore::open(path.clone(), pass.clone()).unwrap();
        let (mut source, _) = server_with(1, &[]);
        let sid = source.server_id.clone();
        let mine = source.clone();
        let rename = source.create_op(CrdtPayload::ServerRenamed { new_name: "Read at last".into() });
        let unreadable = unread_by(1, &source, rename.hlc.physical_ms + 1, "StillLater");
        let kept = vec![
            Kept { author: rename.author.clone(), hlc: rename.hlc.clone(), build: "0.12.0".into(), raw: serde_json::to_string(&rename).unwrap() },
            Kept { author: unreadable.author.clone(), hlc: unreadable.hlc.clone(), build: "0.12.0".into(), raw: unreadable.raw.clone() },
            Kept { author: "x".into(), hlc: rename.hlc.clone(), build: "0.12.0".into(), raw: "{\"not\":\"an op\"}".into() },
        ];
        db.save_server_blob(&sid, KEPT_KEY, &serde_json::to_string(&kept).unwrap()).unwrap();
        db.save_server_blob(&sid, MARK_KEY, &serde_json::to_string(&Mark { lacks: Some("0.12.0".into()), ..Mark::default() }).unwrap()).unwrap();
        db.save_setting(SWEEP_KEY, &SWEEP_GENERATION.to_string()).unwrap();
        let mut states: ServerStates = HashMap::from([(sid.clone(), mine)]);
        let b = CrdtResync::load(&db, &mut states, store, BUILD);
        assert_eq!(states[&sid].name(), "Read at last", "the kept op folded in");
        assert!(db.load_ops_for_server(&sid, None).unwrap().iter().any(|o| o.hlc == rename.hlc), "the kept op is stored");
        assert_eq!(b.marks[&sid], Mark { lacks: Some(BUILD.into()), ..Mark::default() }, "no fetch; the op still unread is this build's skip");
        let left: Vec<Kept> = serde_json::from_str(&db.load_server_blob(&sid, KEPT_KEY).unwrap().unwrap()).unwrap();
        assert_eq!(left.len(), 1, "the read op and the junk left the kept rows");
        assert_eq!((left[0].hlc.clone(), left[0].build.as_str()), (unreadable.hlc, BUILD));
    }

    /// A page folds in off the loop and the state comes back; a page that is not a batch
    /// at all is no ingest, and the state still comes back.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_page_folds_in_off_the_loop_and_reports_what_it_skipped() {
        let me = keys(5).1;
        let (source, owner) = server_with(3, &[&me]);
        let sid = source.server_id.clone();
        let mut mine = source.clone();
        mine.op_log.truncate(1);
        mine.restore_op_log(mine.op_log.clone());
        let mut states: ServerStates = HashMap::from([(sid.clone(), mine)]);
        let mut v = serde_json::to_value(&source.op_log[1]).unwrap();
        v["payload"] = serde_json::json!({ "LaterVariant": { "x": 1 } });
        let payload_json = serde_json::to_string(&v["payload"]).unwrap();
        let op = &source.op_log[1];
        let signed = crate::crdt::operations::signing_payload(&op.server_id, &op.hlc, &op.author, &payload_json);
        v["auth"]["sig"] = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, keys(1).0.sign(signed.as_bytes())).into();
        let mut page_ops: Vec<serde_json::Value> = source.op_log.iter().map(|o| serde_json::to_value(o).unwrap()).collect();
        page_ops.push(v);
        let took = ingest_page(&mut states, &sid, serde_json::to_string(&page_ops).unwrap(), &me).await;
        assert!(took.ok && !took.unread.is_empty() && took.was_member);
        assert_eq!(took.admitted.len(), 3, "the ops we lacked are admitted");
        assert_eq!(states[&sid].op_log.len(), 4);
        let _ = owner;
        let took = ingest_page(&mut states, &sid, "not a batch".into(), &me).await;
        assert!(!took.ok, "a malformed page counts as folded in");
        assert!(states.contains_key(&sid), "the state came back");
    }

    /// An op of a payload this build does not know counts only when its author signed
    /// it and is a member: junk from anyone else marks nothing.
    #[test]
    fn only_a_members_signed_unknown_op_counts_as_skipped() {
        let me = keys(5).1;
        let (mut state, owner) = server_with(0, &[&me]);
        let op = state.create_op(CrdtPayload::ServerRenamed { new_name: "n".into() });
        let mut v = serde_json::to_value(&op).unwrap();
        let rename = v["payload"]["ServerRenamed"].clone();
        let sig_of = |payload_json: &str| {
            let signed = crate::crdt::operations::signing_payload(&op.server_id, &op.hlc, &op.author, payload_json);
            base64::Engine::encode(&base64::engine::general_purpose::STANDARD, keys(1).0.sign(signed.as_bytes()))
        };
        v["payload"] = serde_json::json!({ "FutureVariant": rename });
        let payload_json = serde_json::to_string(&v["payload"]).unwrap();
        v["auth"]["sig"] = serde_json::Value::String(sig_of(&payload_json));
        let unknown = serde_json::to_string(&v).unwrap();
        let batch = format!("[{},{unknown}]", serde_json::to_string(&op).unwrap());
        let parsed = crate::crdt::operations::parse_ops_tolerant(&batch);
        assert_eq!(parsed.ops.len(), 1);
        let who: Vec<_> = parsed.unread.iter().map(|u| (u.server_id.clone(), u.author.clone(), u.raw.clone())).collect();
        assert_eq!(who, vec![(state.server_id.clone(), owner.clone(), unknown.clone())]);
        assert!(vouched(&parsed.unread[0], &state));

        let mut forged = v.clone();
        forged["payload"]["FutureVariant"]["new_name"] = "x".into();
        let batch = format!("[{}]", serde_json::to_string(&forged).unwrap());
        assert!(crate::crdt::operations::parse_ops_tolerant(&batch).unread.is_empty(), "a payload its signature does not cover counted");
        let stranger = UnreadOp { author: keys(9).1, ..parsed.unread[0].clone() };
        assert!(!vouched(&stranger, &state), "a non-member's op counted");
        let elsewhere = UnreadOp { server_id: "other".into(), ..parsed.unread[0].clone() };
        assert!(!vouched(&elsewhere, &state), "another server's op counted");
        assert!(crate::crdt::operations::parse_ops_tolerant("{}").malformed);
    }

    // b1-fix

    /// The last page of a full ask to `device`, answered and folded in.
    fn fetch_from(b: &mut CrdtResync, s: &str, device: &str, partial: bool, states: &ServerStates, me: &str, now: Instant) {
        let nonce = b.asks.get(s).map(|a| a.nonce).expect("an ask is out");
        assert_eq!(b.asks[s].device, device, "the device asked");
        let last = FullPage { partial, ..FullPage::default() };
        assert_eq!(b.claim(s, device, Some(nonce), Some(&last), now), Claim::Page(None));
        assert!(b.paged(s, true, None, states, me, now).is_none());
    }

    /// H1: a marked responder's log counts once per identity: one never clears the mark,
    /// that identity is not asked again, and a second identity's clears it. Our own
    /// identity's never counts.
    #[test]
    fn two_identities_marked_logs_clear_the_mark_and_one_never_does() {
        let (a, x, me) = (keys(3).1, keys(4).1, keys(5).1);
        let (state, owner) = server_with(2, &[&a, &x, &me]);
        let sid = state.server_id.clone();
        let s = sid.as_str();
        let states = HashMap::from([(sid.clone(), state)]);
        let peers = HashMap::from([(sid.clone(), HashSet::from([owner.clone(), a.clone(), x.clone()]))]);
        let mut b = book(&[(s, due())]);
        let now = Instant::now();
        b.tick(now, &states, &peers, &me, &me, &idle);
        fetch_from(&mut b, s, &owner, true, &states, &me, now);
        assert!(b.marks[s].due, "one marked log cleared the mark");
        assert_eq!(b.marks[s].partial_from, vec![owner.clone()]);
        b.finish(s, &owner, true, &me, now);
        assert!(b.marks[s].due, "one identity's marked log counted twice");
        b.finish(s, &me, true, &me, now);
        assert_eq!(b.marks[s].partial_from, vec![owner.clone()], "our own identity's log counted");
        let out = b.tick(now + TICK_GAP, &states, &peers, &me, &me, &idle);
        let (second, _, _) = ask_of(&out);
        assert_ne!(second, owner, "an identity whose marked log we hold was asked again");
        fetch_from(&mut b, s, &second, true, &states, &me, now);
        assert!(!b.marks.contains_key(s), "two identities' marked logs did not clear the mark");
    }

    /// H1: once an identity's marked log is folded in, none of its devices is asked
    /// again; a sibling of ours that hands a marked log is not asked again at once either.
    #[test]
    fn a_counted_identitys_other_devices_and_a_marked_sibling_are_not_asked_again() {
        let _lock = super::super::resolver::test_lock();
        crate::crdt::set_identity_resolver(super::super::resolver::resolve);
        let (a, me) = (keys(3).1, keys(5).1);
        let (state, owner) = server_with(2, &[&a, &me]);
        let (owner_phone, my_phone) = ("b1-fix-owner-phone".to_string(), "b1-fix-my-phone".to_string());
        super::super::resolver::update(&owner_phone, &owner);
        super::super::resolver::update(&my_phone, &me);
        let sid = state.server_id.clone();
        let s = sid.as_str();
        let states = HashMap::from([(sid.clone(), state)]);
        let now = Instant::now();
        let peers = HashMap::from([(sid.clone(), HashSet::from([owner.clone(), owner_phone.clone(), a.clone()]))]);
        let mut b = book(&[(s, due())]);
        let (first, _, _) = ask_of(&b.tick(now, &states, &peers, &me, &me, &idle));
        assert!(first == owner || first == owner_phone, "control: an owner's device is asked first");
        fetch_from(&mut b, s, &first, true, &states, &me, now);
        let (second, _, _) = ask_of(&b.tick(now + TICK_GAP, &states, &peers, &me, &me, &idle));
        assert_eq!(second, a, "another device of an identity already counted was asked");

        let peers = HashMap::from([(sid.clone(), HashSet::from([my_phone.clone()]))]);
        let mut b = book(&[(s, due())]);
        b.tick(now, &states, &peers, &me, &me, &idle);
        fetch_from(&mut b, s, &my_phone, true, &states, &me, now);
        assert!(b.marks[s].due && b.marks[s].partial_from.is_empty(), "our own identity's marked log counted");
        assert!(b.tick(now + TICK_GAP, &states, &peers, &me, &me, &idle).is_empty(), "a marked sibling was asked again at once");
        super::super::resolver::forget_for_test(&owner_phone);
        super::super::resolver::forget_for_test(&my_phone);
    }

    /// H1: a device that handed a marked page is remembered and, once it may be asked
    /// again, comes after an unknown device of a lower rank.
    #[test]
    fn a_marked_page_is_remembered_against_its_device() {
        let (a, me) = (keys(3).1, keys(5).1);
        let (state, owner) = server_with(PAGE_OPS + 2, &[&a, &me]);
        let sid = state.server_id.clone();
        let s = sid.as_str();
        let states = HashMap::from([(sid.clone(), state)]);
        let peers = HashMap::from([(sid.clone(), HashSet::from([owner.clone(), a.clone()]))]);
        let mut b = book(&[(s, due())]);
        let now = Instant::now();
        let (device, nonce, _) = ask_of(&b.tick(now, &states, &peers, &me, &me, &idle));
        assert_eq!(device, owner);
        let cursor = PageCursor::of(&states[s].op_log[PAGE_OPS - 1]);
        let marked = FullPage { next: Some(cursor.clone()), partial: true, ..FullPage::default() };
        assert_eq!(b.claim(s, &owner, Some(nonce), Some(&marked), now), Claim::Page(Some(cursor.clone())));
        b.paged(s, true, Some(cursor), &states, &me, now).unwrap();
        // Both devices time out, so both wait out the same skip.
        let t1 = now + ASK_TIMEOUT + TICK_GAP;
        let (device, _, _) = ask_of(&b.tick(t1, &states, &peers, &me, &me, &idle));
        assert_eq!(device, a, "control: the owner timed out");
        let t2 = t1 + ASK_TIMEOUT + TICK_GAP;
        assert!(b.tick(t2, &states, &peers, &me, &me, &idle).is_empty(), "control: both were tried");
        let later = t2 + TRIED_FOR + TICK_GAP;
        let (device, _, _) = ask_of(&b.tick(later, &states, &peers, &me, &me, &idle));
        assert_eq!(device, a, "the owner's device that handed a marked page was asked first again");
    }

    /// H1: a device known to hand a marked log is asked last, below any rank.
    #[test]
    fn a_device_known_to_be_marked_is_asked_last() {
        let (a, me) = (keys(3).1, keys(5).1);
        let (state, owner) = server_with(2, &[&a, &me]);
        let sid = state.server_id.clone();
        let states = HashMap::from([(sid.clone(), state)]);
        let peers = HashMap::from([(sid.clone(), HashSet::from([owner.clone(), a.clone()]))]);
        let mut b = book(&[(sid.as_str(), due())]);
        b.partial_seen.insert((sid.clone(), owner.clone()));
        let (device, _, _) = ask_of(&b.tick(Instant::now(), &states, &peers, &me, &me, &idle));
        assert_eq!(device, a, "a device known to be marked was asked before an unknown one");
    }

    /// M3: askers spread over the devices of the best tier, each asker steady on its own.
    #[test]
    fn askers_spread_over_a_tier() {
        let members: Vec<String> = (10..16).map(|t| keys(t).1).collect();
        let refs: Vec<&str> = members.iter().map(String::as_str).collect();
        let (state, _) = server_with(1, &refs);
        let sid = state.server_id.clone();
        let states = HashMap::from([(sid.clone(), state)]);
        let peers = HashMap::from([(sid.clone(), members[..4].iter().cloned().collect::<HashSet<_>>())]);
        let mut picked = HashSet::new();
        for asker in &members[4..] {
            for round in 0..2 {
                let mut b = book(&[(sid.as_str(), due())]);
                let (device, _, _) = ask_of(&b.tick(Instant::now(), &states, &peers, asker, asker, &idle));
                assert!(round == 0 || picked.contains(&(asker.clone(), device.clone())), "one asker's pick moved");
                picked.insert((asker.clone(), device));
            }
        }
        let devices: HashSet<_> = picked.iter().map(|(_, d)| d.clone()).collect();
        assert!(devices.len() > 1, "every asker picked the same device");
    }

    /// M3: a busy answer to the first page moves on at once and asks that device again
    /// after a short skip; mid-log the same page is asked again later, a few times.
    #[test]
    fn a_busy_responder_is_skipped_briefly_and_waited_for_mid_log() {
        let (a, me) = (keys(3).1, keys(5).1);
        let (state, owner) = server_with(PAGE_OPS + 2, &[&a, &me]);
        let sid = state.server_id.clone();
        let s = sid.as_str();
        let states = HashMap::from([(sid.clone(), state)]);
        let peers = HashMap::from([(sid.clone(), HashSet::from([owner.clone(), a.clone()]))]);
        let busy = FullPage { busy: true, ..FullPage::default() };
        let mut b = book(&[(s, due())]);
        let now = Instant::now();
        let (device, nonce, _) = ask_of(&b.tick(now, &states, &peers, &me, &me, &idle));
        assert_eq!(device, owner);
        assert_eq!(b.claim(s, &owner, Some(nonce), Some(&busy), now), Claim::Busy);
        let (device, nonce, _) = ask_of(&b.tick(now + TICK_GAP, &states, &peers, &me, &me, &idle));
        assert_eq!(device, a, "a busy first page did not move on");
        assert_eq!(b.claim(s, &a, Some(nonce), Some(&busy), now + TICK_GAP), Claim::Busy);
        assert!(b.tick(now + 2 * TICK_GAP, &states, &peers, &me, &me, &idle).is_empty());
        let back = now + BUSY_SKIP + TICK_GAP;
        let (device, nonce, _) = ask_of(&b.tick(back, &states, &peers, &me, &me, &idle));
        assert_eq!(device, owner, "a busy device stayed skipped for the long wait");

        let cursor = PageCursor::of(&states[s].op_log[PAGE_OPS - 1]);
        let more = FullPage { next: Some(cursor.clone()), ..FullPage::default() };
        assert_eq!(b.claim(s, &owner, Some(nonce), Some(&more), back), Claim::Page(Some(cursor.clone())));
        let (_, nonce, _) = ask_of(&[b.paged(s, true, Some(cursor.clone()), &states, &me, back).unwrap()]);
        for n in 0..MAX_BUSY {
            let at = back + (BUSY_RETRY + TICK_GAP) * n;
            let nonce = if n == 0 { nonce } else {
                let out = b.tick(at, &states, &peers, &me, &me, &idle);
                let (device, nonce, after) = ask_of(&out);
                assert_eq!((device.as_str(), after.as_ref()), (owner.as_str(), Some(&cursor)), "mid-log, the same page is asked again");
                nonce
            };
            assert_eq!(b.claim(s, &owner, Some(nonce), Some(&busy), at), Claim::Busy);
            assert!(b.asks.contains_key(s), "a busy page mid-log ended the ask");
            assert_eq!(b.claim(s, &owner, Some(nonce), Some(&more), at), Claim::Unrelated, "a busy answer's nonce still counts");
        }
        let at = back + (BUSY_RETRY + TICK_GAP) * MAX_BUSY;
        let (_, nonce, _) = ask_of(&b.tick(at, &states, &peers, &me, &me, &idle));
        assert_eq!(b.claim(s, &owner, Some(nonce), Some(&busy), at), Claim::Busy);
        assert!(!b.asks.contains_key(s) && b.marks[s].due, "a responder busy for good is given up on");
    }

    /// L3: an ask's clock starts only once our paced queue to the device is empty.
    #[test]
    fn an_ask_still_queued_does_not_time_out() {
        let me = keys(5).1;
        let (state, owner) = server_with(1, &[&me]);
        let sid = state.server_id.clone();
        let states = HashMap::from([(sid.clone(), state)]);
        let peers = HashMap::from([(sid.clone(), HashSet::from([owner.clone()]))]);
        let mut b = book(&[(sid.as_str(), due())]);
        let now = Instant::now();
        assert_eq!(b.tick(now, &states, &peers, &me, &me, &idle).len(), 1);
        let held = |_: &str| true;
        let later = now + ASK_TIMEOUT + TICK_GAP;
        b.tick(later, &states, &peers, &me, &me, &held);
        assert!(b.asks.contains_key(&sid), "an ask still in our paced queue timed out");
        b.tick(later + ASK_TIMEOUT - TICK_GAP, &states, &peers, &me, &me, &idle);
        assert!(b.asks.contains_key(&sid), "the clock ran while the ask was queued");
        b.tick(later + ASK_TIMEOUT + TICK_GAP, &states, &peers, &me, &me, &idle);
        assert!(!b.asks.contains_key(&sid), "an ask that left never timed out");
    }

    /// L4: the mark and kept ops of a server deleted or gone are dropped, stored copies too.
    #[test]
    fn a_deleted_servers_mark_and_kept_ops_go() {
        let me = keys(5).1;
        let (mut state, _) = server_with(1, &[&me]);
        let sid = state.server_id.clone();
        let mut b = book(&[(sid.as_str(), due())]);
        b.note_skipped(&sid, vec![unread_by(1, &state, 10, "Later")]);
        let del = state.create_op(CrdtPayload::ServerDeleted { deleted_at: 1 });
        state.apply_op(&del).unwrap();
        assert!(state.is_deleted());
        let states = HashMap::from([(sid.clone(), state)]);
        b.tick(Instant::now(), &states, &HashMap::new(), &me, &me, &idle);
        assert!(!b.marks.contains_key(&sid) && !b.kept.contains_key(&sid), "a deleted server kept its mark");
    }

    // b1-review

    fn review_sign_raw(op: &CrdtOp, v: &mut serde_json::Value) {
        let payload_json = serde_json::to_string(&v["payload"]).unwrap();
        let signed = crate::crdt::operations::signing_payload(&op.server_id, &op.hlc, &op.author, &payload_json);
        v["auth"]["sig"] = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, keys(1).0.sign(signed.as_bytes())).into();
    }

    /// After a restart the log is in `load_ops_for_server` order (HLC), where a retained
    /// checkpoint sits at its OWN clock, not at what it covers: paging that log must still
    /// hand every op.
    #[test]
    fn review_a_restarted_log_with_a_checkpoint_pages_every_op() {
        let (mut state, _) = server_with(9, &[]);
        let covers = state.op_log[2].hlc.clone();
        let cp = state.create_op(CrdtPayload::ServerCheckpoint { state: "{}".into(), covers: covers.clone() });
        let mut log: Vec<CrdtOp> = state
            .op_log
            .iter()
            .filter(|o| matches!(o.payload, CrdtPayload::ServerCreated { .. }) || o.hlc > covers)
            .cloned()
            .collect();
        log.push(cp);
        for i in 0..4 {
            log.push(state.create_op(CrdtPayload::ChannelAdded {
                channel_id: format!("d{i}"), name: format!("d{i}"), category: None, channel_type: "text".into(),
            }));
        }
        // What `load_ops_for_server` returns: ORDER BY hlc_ms, hlc_counter, author.
        log.sort_by(|a, b| (a.hlc.physical_ms, a.hlc.counter, &a.author).cmp(&(b.hlc.physical_ms, b.hlc.counter, &b.author)));
        // M1 fix: the restart restores the log through `restore_op_log`, which pages see.
        state.restore_op_log(log);
        let log = state.op_log.clone();
        let mut after = None;
        let mut seen = Vec::new();
        for _ in 0..20 {
            let (json, next) = page(&log, after.as_ref());
            let ops: Vec<CrdtOp> = serde_json::from_str(&json).unwrap();
            seen.extend(ops.into_iter().map(|o| (o.author, o.hlc)));
            match next {
                Some(c) => after = Some(c),
                None => break,
            }
        }
        let missing: Vec<_> = log.iter().filter(|o| !seen.contains(&(o.author.clone(), o.hlc.clone()))).map(|o| format!("{:?}", o.payload).chars().take(40).collect::<String>()).collect();
        assert!(missing.is_empty(), "a restarted responder's pages skipped {missing:?}");
    }

    /// A newer build adds a `#[serde(default)]` field to a KNOWN variant: this build
    /// parses the op, drops the field, and its re-serialized signing payload no longer
    /// matches, so the fold refuses it as a bad signature. That op is just as lost as an
    /// unknown variant, and must mark the server the same way.
    #[test]
    fn review_a_known_variant_with_a_newer_field_counts_as_unread() {
        let me = keys(5).1;
        let (mut state, owner) = server_with(0, &[&me]);
        let op = state.create_op(CrdtPayload::ServerRenamed { new_name: "n".into() });
        let mut v = serde_json::to_value(&op).unwrap();
        v["payload"]["ServerRenamed"]["later_field"] = "x".into();
        review_sign_raw(&op, &mut v);
        let batch = format!("[{}]", serde_json::to_string(&v).unwrap());
        // H2 fix: the op leaves `ops` for `unread`, so the controls read it directly.
        let as_op: CrdtOp = serde_json::from_str(&serde_json::to_string(&v).unwrap()).unwrap();
        assert!(as_op.verify_author().is_err(), "control: this build parses the op and refuses its signature");
        assert!(state.clone().ingest_remote(std::slice::from_ref(&as_op)).admitted.is_empty(), "control: the fold refuses it");
        let parsed = crate::crdt::operations::parse_ops_tolerant(&batch);
        assert_eq!(
            parsed.unread.iter().map(|u| (u.server_id.clone(), u.author.clone())).collect::<Vec<_>>(),
            vec![(state.server_id.clone(), owner)],
            "a member-signed op this build refused for a field it drops marked nothing",
        );
    }

    /// The sweep marks EVERY replica of this build due, the owner's too, and a swept
    /// replica still serves. A member that asks a swept owner (rank 0) and gets its whole
    /// log clears its mark, though that owner may lack the very op both skipped.
    #[test]
    fn review_a_whole_log_from_a_swept_responder_does_not_clear_the_mark() {
        let me = keys(5).1;
        let (state, owner) = server_with(2, &[&me]);
        let sid = state.server_id.clone();
        let s = sid.as_str();
        let mut responder = book(&[(s, due())]);
        let (_, page) = responder.serve(&state, &FullAsk::default(), "asker", Instant::now());
        let states = HashMap::from([(sid.clone(), state)]);
        let peers = HashMap::from([(sid.clone(), HashSet::from([owner.clone()]))]);
        let mut asker = book(&[(s, due())]);
        let now = Instant::now();
        let (_, nonce, _) = ask_of(&asker.tick(now, &states, &peers, &me, &me, &idle));
        assert_eq!(asker.claim(s, &owner, Some(nonce), Some(&page), now), Claim::Page(None));
        asker.paged(s, true, None, &states, &me, now);
        assert!(
            asker.marks.get(s).is_some_and(|m| m.due),
            "a whole log from a responder that was itself still due cleared the mark",
        );
    }

    /// Any member can sign a payload no build will ever read. Every member that hears it
    /// stops serving; after the next upgrade the skip turns due but `lacks` stays, so
    /// every one of them still declines and nobody is left to answer.
    #[test]
    fn review_one_members_junk_op_leaves_nobody_to_serve() {
        let (me, other) = (keys(5).1, keys(6).1);
        let (mut state, _) = server_with(1, &[&me, &other]);
        let op = state.create_op(CrdtPayload::ServerRenamed { new_name: "n".into() });
        let mut v = serde_json::to_value(&op).unwrap();
        v["payload"] = serde_json::json!({ "NoSuchVariantEver": {} });
        review_sign_raw(&op, &mut v);
        let parsed = crate::crdt::operations::parse_ops_tolerant(&format!("[{}]", serde_json::to_string(&v).unwrap()));
        assert!(parsed.unread.iter().all(|u| vouched(u, &state)) && !parsed.unread.is_empty(), "control: junk counts");
        let sid = state.server_id.clone();
        let mut now_build = book(&[]);
        now_build.note_skipped(&sid, parsed.unread);
        // M2 fix: a skip no longer refuses to serve, it flags the pages partial.
        assert!(now_build.serve(&state, &FullAsk::default(), "asker", Instant::now()).1.partial, "control: this build's pages are partial");
        // What `load` makes of that mark on the next build.
        let mut upgraded = book(&[(sid.as_str(), Mark { due: true, lacks: Some("0.12.1".into()), ..Mark::default() })]);
        assert!(
            !upgraded.serve(&state, &FullAsk::default(), "asker", Instant::now()).1.declined,
            "one member's junk op left every replica that heard it refusing to serve, across an upgrade",
        );
    }
}
