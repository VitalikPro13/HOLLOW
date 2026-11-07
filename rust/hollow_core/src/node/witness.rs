//! Witnesses for a recovery with no device that holds the server (DEVICE_PROOF_DESIGN
//! section 8.4): the answering side (a member names the checkpoint it folded before T)
//! and the asking side (a fresh install judges what members name).
#![allow(dead_code)] // the asking side's judgment and screen land with step 5's second half

use std::collections::HashMap;

use crate::crdt::authority::{AuthorityView, CpWitness, WitnessAsk};
use crate::crdt::operations::CrdtOp;
use crate::crdt::server_state::ServerState;
use crate::identity::native_identity::NativeKeypair;
use crate::storage::messages::MessageStore;

/// Where a fresh install learned that an identity is a member of a server it owns
/// (section 8.7's union list), in the order witness asks go out.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) enum MemberSource {
    /// A contact of ours that shares the server.
    Contact,
    /// A friend's `SharedServers` entry named it.
    FriendEntry,
    /// A join answerer's state named it.
    JoinAnswer,
    /// A witnessed checkpoint's content named it.
    NamedInContent,
}

/// One answer per (server, asker device) in this long.
pub(crate) const ANSWER_EVERY_MS: i64 = 10 * 60 * 1000;
const ANSWERED_MAX: usize = 4096;
/// The oldest T an ask may name: past it no witness holds a record anyway.
const MAX_T_AGE_MS: i64 = 400 * 24 * 3600 * 1000;
const NONCE_MAX: usize = 128;
const WITNESS_TAG: &str = "hollow-cp-witness2\n";
/// Counted witnesses kept per server and servers tracked, on a fresh install.
const TAKEN_PER_SERVER: usize = 256;
const TAKEN_SERVERS: usize = 64;

/// A peer id as the relay's `is_peer_id_shape` reads one.
pub(crate) fn peer_id_shape(id: &str) -> bool {
    (40..=64).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric() && !matches!(b, b'0' | b'O' | b'I' | b'l'))
}

fn nonce_shape(nonce: &str) -> bool {
    !nonce.is_empty() && nonce.len() <= NONCE_MAX && nonce.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// Every newline-joined field of a witness is shape-checked by signer and verifier alike,
/// so no field can carry a separator into the next (HOL-SEC-143).
fn well_formed(w: &CpWitness) -> bool {
    peer_id_shape(&w.asker)
        && peer_id_shape(&w.by)
        && nonce_shape(&w.nonce)
        && !w.server.is_empty()
        && w.server.len() <= 128
        && w.server.bytes().all(|b| b.is_ascii_graphic())
        && (0..=MAX_T_AGE_MS).contains(&w.t_age_ms)
        && (w.cp.is_empty() || w.cp.len() == 64 && w.cp.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()))
        && w.folded_age_ms >= -1
}

fn signed_text(w: &CpWitness) -> String {
    format!(
        "{WITNESS_TAG}{}\n{}\n{}\n{}\n{}\n{}\n{}",
        w.server, w.asker, w.nonce, w.t_age_ms, w.cp, w.folded_age_ms, w.by
    )
}

impl CpWitness {
    /// A witness for `asker`'s ask, signed by our `device` key; `None` when a field is out
    /// of shape.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn sign(server: &str, asker: &str, ask: &WitnessAsk, cp: String, folded_age_ms: i64, device: &NativeKeypair) -> Option<Self> {
        use base64::Engine as _;
        let mut w = CpWitness {
            server: server.to_string(),
            asker: asker.to_string(),
            nonce: ask.nonce.clone(),
            t_age_ms: ask.t_age_ms,
            cp,
            folded_age_ms,
            by: device.peer_id(),
            sig: String::new(),
        };
        if !well_formed(&w) {
            return None;
        }
        w.sig = base64::engine::general_purpose::STANDARD.encode(device.sign(signed_text(&w).as_bytes()));
        Some(w)
    }

    /// The signature checks under the key `by` derives, over well-formed fields.
    pub(crate) fn verifies(&self) -> bool {
        use base64::Engine as _;
        if !well_formed(self) {
            return false;
        }
        let Some(key) = crate::crypto::safety_number::pubkey_from_peer_id(&self.by) else { return false };
        let Ok(sig) = base64::engine::general_purpose::STANDARD.decode(&self.sig) else { return false };
        let Ok(sig) = <[u8; 64]>::try_from(sig.as_slice()) else { return false };
        let Ok(vk) = ed25519_dalek::VerifyingKey::from_bytes(&key) else { return false };
        vk.verify_strict(signed_text(self).as_bytes(), &ed25519_dalek::Signature::from_bytes(&sig)).is_ok()
    }
}

/// The checkpoint we name for an ask whose T is `t_w` on our clock: the newest one whose
/// content we hold (base, parent, restore rows) first folded before it, with its first
/// fold time (0 = the upgrade's seed).
fn named_before(state: &ServerState, t_w: u64) -> Option<(CrdtOp, u64)> {
    let op = state.restore_for(t_w)?;
    let first = *state.first_folds.get(&hex::encode(state.content_of(&op)))?;
    Some((op, first))
}

/// An ask we sent for a server we are recovering: the nonce and T's age it named, per
/// asked device.
#[derive(Debug, Clone)]
struct Asked {
    server: String,
    t_age_ms: i64,
    device: String,
    at_ms: i64,
}

/// Nonces kept at once; one older than [`NONCE_KEEP_MS`] gives way when the book is full.
const NONCES_MAX: usize = TAKEN_SERVERS * 64;
/// An ask is sent again after [`ANSWER_EVERY_MS`]; an answer to the one before still counts.
const NONCE_KEEP_MS: i64 = 2 * ANSWER_EVERY_MS;

/// One node's witness bookkeeping: answers given (once per (server, asker device) per
/// 10 minutes) and, on a fresh install, the asks out and the witnesses that passed the
/// receipt checks (signature, our ask's nonce and age, our device).
#[derive(Debug, Default)]
pub(crate) struct WitnessDesk {
    answered: HashMap<(String, String), i64>,
    asked: HashMap<String, Asked>,
    taken: HashMap<String, Vec<(CpWitness, Option<CrdtOp>, i64)>>,
    us: String,
    members: HashMap<String, Vec<(String, MemberSource)>>,
    recovering: HashMap<String, Recovery>,
    registered_at: i64,
}

/// A server this fresh install restores from witnesses (section 8.4).
#[derive(Debug, Clone, Default)]
struct Recovery {
    t_ms: i64,
    /// Identity -> when we last asked it.
    asked: HashMap<String, i64>,
    first_ask_ms: Option<i64>,
    pick_since: Option<i64>,
    /// When a new identity's witness last counted.
    grew_at: Option<i64>,
    judged: Judged,
    /// The person's choice (`None` = "I don't know"), and when its round started.
    chosen: Option<(Option<String>, i64)>,
    round_at: Option<std::time::Instant>,
    /// The checked contents, by content id, for the chosen point's settling.
    contents: HashMap<String, CrdtOp>,
    done: bool,
}

/// Where a server's restore stands, as the chooser shows it (appendix A).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Stage {
    Checking,
    Waiting,
    Pick,
    Points,
    OnlyOne,
    NobodyReachable,
    Done,
}

/// W: the wait after a pick first exists, restarted by each newly counted identity.
pub(crate) const WAIT_MS: i64 = 30_000;
/// The longest a restore waits for answers after its first ask.
pub(crate) const WAIT_MAX_MS: i64 = 120_000;

fn fresh_nonce() -> Option<String> {
    let mut b = [0u8; 16];
    getrandom::fill(&mut b).ok()?;
    Some(hex::encode(b))
}

impl WitnessDesk {
    /// Our witness for `ask` from `asker` (a device the view counts for the server's
    /// OWNER), signed by our `device` key, with the named checkpoint op; `None` when we
    /// answer nothing.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn answer(
        &mut self,
        store: &MessageStore,
        state: &ServerState,
        view: &AuthorityView,
        ask: &WitnessAsk,
        asker: &str,
        device: &NativeKeypair,
        now_ms: i64,
    ) -> Option<(CpWitness, Option<CrdtOp>)> {
        let _ = store;
        let owner = state.current_owner()?;
        if !view.counts(&owner, asker) || !(0..=MAX_T_AGE_MS).contains(&ask.t_age_ms) || !nonce_shape(&ask.nonce) {
            return None;
        }
        let key = (state.server_id.clone(), asker.to_string());
        if self.answered.get(&key).is_some_and(|at| now_ms.saturating_sub(*at) < ANSWER_EVERY_MS) {
            return None;
        }
        if self.answered.len() >= ANSWERED_MAX {
            self.answered.retain(|_, at| now_ms.saturating_sub(*at) < ANSWER_EVERY_MS);
            if self.answered.len() >= ANSWERED_MAX {
                return None;
            }
        }
        let t_w = u64::try_from(now_ms.saturating_sub(ask.t_age_ms)).unwrap_or(0);
        let named = named_before(state, t_w);
        let (cp, folded_age_ms) = match &named {
            Some((op, 0)) => (hex::encode(state.content_of(op)), -1),
            Some((op, first)) => (hex::encode(state.content_of(op)), now_ms.saturating_sub(*first as i64).max(0)),
            None => (String::new(), 0),
        };
        let witness = CpWitness::sign(&state.server_id, asker, ask, cp, folded_age_ms, device)?;
        self.answered.insert(key, now_ms);
        Some((witness, named.map(|(op, _)| op)))
    }

    /// Note a witness ask we send to `device` for `server` (a fresh install's recovery);
    /// false when the book is full, and then the ask must not go.
    pub(crate) fn asked(&mut self, us: &str, device: &str, server: &str, nonce: &str, t_age_ms: i64, now_ms: i64) -> bool {
        self.us = us.to_string();
        if self.asked.len() >= NONCES_MAX && !self.asked.contains_key(nonce) {
            self.asked.retain(|_, a| now_ms.saturating_sub(a.at_ms) < NONCE_KEEP_MS);
            if self.asked.len() >= NONCES_MAX {
                return false;
            }
        }
        self.asked.insert(nonce.to_string(), Asked { server: server.to_string(), t_age_ms, device: device.to_string(), at_ms: now_ms });
        true
    }

    /// A witness answer arrived from `from` for a server we are recovering. Kept only when
    /// it answers an ask of ours (nonce, age, server, our device), comes from the device it
    /// names and its signature verifies; one per witness device, the newest.
    pub(crate) fn receive(&mut self, from: &str, witness: CpWitness, content: Option<CrdtOp>, now_ms: i64) {
        let Some(asked) = self.asked.get(&witness.nonce) else { return };
        if witness.by != from
            || witness.by != asked.device
            || witness.server != asked.server
            || witness.t_age_ms != asked.t_age_ms
            || witness.asker != self.us
            || !witness.verifies()
            || content.as_ref().is_some_and(|op| hex::encode(op.content_hash()) != witness.cp)
        {
            return;
        }
        if self.taken.len() >= TAKEN_SERVERS && !self.taken.contains_key(&witness.server) {
            return;
        }
        let list = self.taken.entry(witness.server.clone()).or_default();
        list.retain(|(w, _, _)| w.by != witness.by);
        if list.len() < TAKEN_PER_SERVER {
            list.push((witness, content, now_ms));
        }
    }

    /// The witnesses kept for `server_id` (receipt checks passed), with the content each
    /// carried and when it arrived.
    pub(crate) fn taken(&self, server_id: &str) -> &[(CpWitness, Option<CrdtOp>, i64)] {
        self.taken.get(server_id).map(Vec::as_slice).unwrap_or_default()
    }

    /// Identities the union list names as members of `server_id` (section 8.7), each with
    /// where we learned it.
    pub(crate) fn note_members(&mut self, server_id: &str, members: Vec<(String, MemberSource)>) {
        if !self.members.contains_key(server_id) && self.members.len() >= TAKEN_SERVERS {
            return;
        }
        let mut members = members;
        members.truncate(super::union_list::MAX_ASKED);
        self.members.insert(server_id.to_string(), members);
    }

    /// Restore `server_id` from witnesses for a recovery whose T is `t_ms` (0 = not sure:
    /// nothing to ask, only "I don't know").
    pub(crate) fn recover(&mut self, server_id: &str, t_ms: i64) {
        if self.recovering.contains_key(server_id) || self.recovering.len() >= TAKEN_SERVERS {
            return;
        }
        self.recovering.insert(server_id.to_string(), Recovery { t_ms: t_ms.max(0), ..Default::default() });
    }

    /// Servers still being restored here.
    pub(crate) fn restoring(&self) -> Vec<String> {
        self.recovering.iter().filter(|(_, r)| !r.done).map(|(s, _)| s.clone()).collect()
    }

    pub(crate) fn t_ms(&self, server_id: &str) -> Option<i64> {
        self.recovering.get(server_id).map(|r| r.t_ms)
    }

    /// The witness asks due for `server_id` now: the union list's identities in its order,
    /// then those `named` in checked contents, at most [`super::union_list::MAX_ASKED`]
    /// identities ever, each again only after [`ANSWER_EVERY_MS`] without an answer.
    /// `devices_of` gives an identity's reachable devices; `us` is our own identity.
    pub(crate) fn due_asks(
        &mut self,
        server_id: &str,
        named: &[String],
        devices_of: &dyn Fn(&str) -> Vec<String>,
        us: &str,
        device: &str,
        now_ms: i64,
    ) -> Vec<(String, WitnessAsk)> {
        let order: Vec<String> = {
            let listed = self.members.get(server_id).into_iter().flatten().map(|(m, _)| m.clone());
            let mut seen = std::collections::HashSet::new();
            listed.chain(named.iter().cloned()).filter(|m| m != us && seen.insert(m.clone())).collect()
        };
        let Some(rec) = self.recovering.get_mut(server_id) else { return Vec::new() };
        if rec.done || rec.chosen.is_some() || rec.t_ms <= 0 {
            return Vec::new();
        }
        let t_age_ms = now_ms.saturating_sub(rec.t_ms).clamp(0, MAX_T_AGE_MS);
        let mut out = Vec::new();
        for m in order {
            if rec.judged.counted.contains(&m) || rec.asked.get(&m).is_some_and(|at| now_ms.saturating_sub(*at) < ANSWER_EVERY_MS) {
                continue;
            }
            if !rec.asked.contains_key(&m) && rec.asked.len() >= super::union_list::MAX_ASKED {
                break;
            }
            let devices = devices_of(&m);
            if devices.is_empty() {
                continue;
            }
            rec.asked.insert(m, now_ms);
            rec.first_ask_ms.get_or_insert(now_ms);
            for d in devices.into_iter().take(retire_round_asked()) {
                if let Some(nonce) = fresh_nonce() {
                    out.push((d, WitnessAsk { nonce, t_age_ms }));
                }
            }
        }
        out.retain(|(d, ask)| self.asked(us, d, server_id, &ask.nonce, ask.t_age_ms, now_ms));
        self.us = device.to_string();
        out
    }

    /// The latest judgment of `server_id`, noted for the wait (step 7).
    pub(crate) fn update(&mut self, server_id: &str, judged: Judged, now_ms: i64) {
        let Some(rec) = self.recovering.get_mut(server_id) else { return };
        if judged.counted.iter().any(|m| !rec.judged.counted.contains(m)) {
            rec.grew_at = Some(now_ms);
        }
        match (&judged.pick, rec.pick_since) {
            (Some(_), None) => rec.pick_since = Some(now_ms),
            (None, _) => rec.pick_since = None,
            _ => {}
        }
        rec.judged = judged;
    }

    pub(crate) fn judged(&self, server_id: &str) -> Option<&Judged> {
        self.recovering.get(server_id).map(|r| &r.judged)
    }

    /// Where the restore of `server_id` stands at `now_ms`.
    pub(crate) fn stage(&self, server_id: &str, now_ms: i64) -> Option<Stage> {
        let rec = self.recovering.get(server_id)?;
        if rec.done {
            return Some(Stage::Done);
        }
        if rec.t_ms <= 0 {
            return Some(Stage::Points);
        }
        let Some(first) = rec.first_ask_ms else { return Some(Stage::Checking) };
        let counted = &rec.judged.counted;
        let all_answered = rec.asked.keys().all(|m| counted.contains(m));
        let settled = rec.pick_since.is_some_and(|p| now_ms.saturating_sub(p.max(rec.grew_at.unwrap_or(p))) >= WAIT_MS);
        if !(all_answered || settled || now_ms.saturating_sub(first) >= WAIT_MAX_MS) {
            return Some(if counted.is_empty() { Stage::Checking } else { Stage::Waiting });
        }
        Some(if counted.is_empty() {
            Stage::NobodyReachable
        } else if rec.judged.pick.is_some() {
            Stage::Pick
        } else if counted.len() == 1 {
            Stage::OnlyOne
        } else {
            Stage::Points
        })
    }

    /// The person chose `cp` (`None` = "I don't know") for `server_id`: only once the wait
    /// is over, and only a point a counted witness named.
    pub(crate) fn choose(&mut self, server_id: &str, cp: Option<String>, now_ms: i64) -> Result<(), String> {
        let stage = self.stage(server_id, now_ms).ok_or("This server is not being restored.")?;
        if !matches!(stage, Stage::Pick | Stage::Points | Stage::OnlyOne | Stage::NobodyReachable) {
            return Err("Members are still answering. Try again in a moment.".into());
        }
        let rec = self.recovering.get_mut(server_id).ok_or("This server is not being restored.")?;
        if rec.chosen.is_some() {
            return Err("This server is already being restored.".into());
        }
        if let Some(cp) = &cp
            && !rec.judged.points.iter().any(|p| &p.cp == cp)
        {
            return Err("No member named that point.".into());
        }
        rec.chosen = Some((cp, now_ms));
        rec.round_at = Some(std::time::Instant::now());
        Ok(())
    }

    /// [`Self::chosen`] with the instant its round started.
    pub(crate) fn chosen_round(&self, server_id: &str) -> Option<(Option<String>, i64, std::time::Instant)> {
        let r = self.recovering.get(server_id).filter(|r| !r.done)?;
        let (cp, at) = r.chosen.clone()?;
        Some((cp, at, r.round_at?))
    }

    /// Whether the server list is due for another look (every `every_ms`).
    pub(crate) fn register_due(&mut self, now_ms: i64, every_ms: i64) -> bool {
        if self.registered_at != 0 && now_ms.saturating_sub(self.registered_at) < every_ms {
            return false;
        }
        self.registered_at = now_ms;
        true
    }

    /// Keep the contents that checked for `server_id` (bounded by the check).
    pub(crate) fn keep_contents(&mut self, server_id: &str, contents: HashMap<String, CrdtOp>) {
        if let Some(r) = self.recovering.get_mut(server_id) {
            r.contents = contents;
        }
    }

    /// The checked content `cp` of `server_id`.
    pub(crate) fn content(&self, server_id: &str, cp: &str) -> Option<CrdtOp> {
        self.recovering.get(server_id)?.contents.get(cp).cloned()
    }

    /// Every server registered for a restore, done ones too (the chooser shows Done).
    pub(crate) fn all(&self) -> Vec<String> {
        self.recovering.keys().cloned().collect()
    }

    /// The choice for `server_id` and when its round started.
    pub(crate) fn chosen(&self, server_id: &str) -> Option<(Option<String>, i64)> {
        self.recovering.get(server_id).filter(|r| !r.done).and_then(|r| r.chosen.clone())
    }

    /// A choice whose settling could not be written: the person may choose again.
    pub(crate) fn unchoose(&mut self, server_id: &str) {
        if let Some(r) = self.recovering.get_mut(server_id) {
            r.chosen = None;
            r.round_at = None;
        }
    }

    /// The settling of `server_id` is written.
    pub(crate) fn finish(&mut self, server_id: &str) {
        if let Some(r) = self.recovering.get_mut(server_id) {
            r.done = true;
        }
        self.taken.remove(server_id);
        self.asked.retain(|_, a| a.server != server_id);
    }

    /// The witness devices whose witness counted for `server_id`, one per identity, for
    /// the restore round.
    pub(crate) fn round_devices(&self, server_id: &str, place: &dyn Fn(&str) -> Option<String>) -> Vec<String> {
        let counted = self.judged(server_id).map(|j| j.counted.clone()).unwrap_or_default();
        let mut identities = std::collections::HashSet::new();
        self.taken(server_id)
            .iter()
            .filter_map(|(w, _, _)| place(&w.by).filter(|m| counted.contains(m) && identities.insert(m.clone())).map(|_| w.by.clone()))
            .take(retire_round_asked())
            .collect()
    }
}

fn retire_round_asked() -> usize {
    super::retire_round::ASKED
}

/// What the judgment needs of a checked checkpoint content (section 8.4 step 2).
#[derive(Debug, Clone)]
pub(crate) struct CpFacts {
    pub(crate) generation: u64,
    pub(crate) hlc: crate::crdt::hlc::HlcTimestamp,
    /// Ancestors by content id, newest first (`cp_lineage`).
    pub(crate) lineage: Vec<String>,
    /// Member identities of its state.
    pub(crate) members: std::collections::BTreeSet<String>,
}

impl CpFacts {
    pub(crate) fn of(base: &crate::crdt::fold::Base) -> Self {
        CpFacts {
            generation: base.generation,
            hlc: base.hlc.clone(),
            lineage: base.state.cp_lineage.clone(),
            members: base.state.members.keys().cloned().collect(),
        }
    }
}

/// One counted witness as the judgment reads it: the identity our view counts its device
/// for, the content it names ("" = none held before T) and when it says it first folded it.
#[derive(Debug, Clone)]
pub(crate) struct Seen {
    pub(crate) identity: String,
    pub(crate) cp: String,
    /// -1 = before the 0.14 update.
    pub(crate) folded_age_ms: i64,
    pub(crate) received_ms: i64,
}

impl Seen {
    fn date_ms(&self) -> Option<i64> {
        (self.folded_age_ms >= 0).then(|| self.received_ms.saturating_sub(self.folded_age_ms))
    }
}

/// A witnessed restore point: dated by its namers' first folds (`None` = before the 0.14
/// update), with the identities that named it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Point {
    pub(crate) cp: String,
    pub(crate) date_ms: Option<i64>,
    pub(crate) named_by: Vec<String>,
}

/// Steps 1 to 6 of section 8.4 over what arrived so far.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Judged {
    pub(crate) pick: Option<String>,
    /// Every counted restore point, newest first.
    pub(crate) points: Vec<Point>,
    /// Identities whose witness counted, naming a point or none.
    pub(crate) counted: std::collections::BTreeSet<String>,
}

/// Two named ages further apart than this on one identity's devices make it a doubt.
const LINE_AGE_MS: i64 = 10 * 60 * 1000;
/// Distinct contents checked per server, and their bytes.
pub(crate) const CONTENTS_MAX: usize = 16;
pub(crate) const CONTENT_BYTES_MAX: usize = 64 * 1024 * 1024;

fn order_key<'a>(facts: &'a std::collections::HashMap<String, CpFacts>, id: &'a str) -> (u64, &'a crate::crdt::hlc::HlcTimestamp, &'a str) {
    let f = &facts[id];
    (f.generation, &f.hlc, id)
}

/// The contents to check, in the order step 2 keeps them: named by a contact first, then
/// by how many identities name them, then the newest named.
pub(crate) fn content_order(seen: &[Seen], contact: &dyn Fn(&str) -> bool) -> Vec<String> {
    type Rank<'a> = (bool, std::collections::BTreeSet<&'a str>, i64);
    let mut by: std::collections::HashMap<&str, Rank<'_>> = std::collections::HashMap::new();
    for s in seen.iter().filter(|s| !s.cp.is_empty()) {
        let e = by.entry(s.cp.as_str()).or_insert((false, Default::default(), i64::MIN));
        e.0 |= contact(&s.identity);
        e.1.insert(s.identity.as_str());
        e.2 = e.2.max(s.date_ms().unwrap_or(i64::MIN));
    }
    let mut all: Vec<(&str, Rank<'_>)> = by.into_iter().collect();
    all.sort_by(|(a, x), (b, y)| y.0.cmp(&x.0).then(y.1.len().cmp(&x.1.len())).then(y.2.cmp(&x.2)).then(a.cmp(b)));
    all.into_iter().map(|(cp, _)| cp.to_string()).collect()
}

/// Section 8.4 steps 1 to 6 over `seen` (witnesses that passed the receipt checks, each
/// attributed to the identity our view counts its device for) and `facts`, the contents
/// that checked as bases of the server. A witness naming a content not in `facts`, or
/// one whose state does not list its identity, does not count.
pub(crate) fn judge(seen: &[Seen], facts: &std::collections::HashMap<String, CpFacts>) -> Judged {
    use std::collections::{BTreeMap, BTreeSet};
    let on_line = |a: &str, b: &str| a == b || facts[a].lineage.iter().any(|x| x == b) || facts[b].lineage.iter().any(|x| x == a);
    let mut out = Judged::default();
    let mut per: BTreeMap<&str, Vec<&Seen>> = BTreeMap::new();
    for s in seen {
        if s.cp.is_empty() {
            out.counted.insert(s.identity.clone());
        } else if facts.get(&s.cp).is_some_and(|f| f.members.contains(&s.identity)) {
            out.counted.insert(s.identity.clone());
            per.entry(s.identity.as_str()).or_default().push(s);
        }
    }
    // Step 1: one witness per identity.
    let mut named: BTreeMap<&str, &Seen> = BTreeMap::new();
    for (m, ws) in per {
        let one_line = ws.iter().all(|a| ws.iter().all(|b| on_line(&a.cp, &b.cp)));
        let ages: Vec<i64> = ws.iter().map(|w| w.folded_age_ms).collect();
        let close = ages.iter().max().zip(ages.iter().min()).is_none_or(|(hi, lo)| hi - lo <= LINE_AGE_MS);
        let cmp = |a: &&&Seen, b: &&&Seen| order_key(facts, &a.cp).cmp(&order_key(facts, &b.cp));
        let pick = if one_line && close { ws.iter().max_by(cmp) } else { ws.iter().min_by(cmp) };
        if let Some(w) = pick {
            named.insert(m, w);
        }
    }
    let mut cps: Vec<&str> = named.values().map(|w| w.cp.as_str()).collect();
    cps.sort_by(|a, b| order_key(facts, b).cmp(&order_key(facts, a)));
    cps.dedup();
    for cp in &cps {
        let namers: Vec<&&Seen> = named.values().filter(|w| w.cp == *cp).collect();
        let date_ms = namers.iter().map(|w| w.date_ms()).try_fold(i64::MAX, |acc, d| d.map(|d| acc.min(d)));
        out.points.push(Point { cp: cp.to_string(), date_ms, named_by: namers.iter().map(|w| w.identity.clone()).collect() });
    }
    // Steps 3 to 6.
    let supporters = |x: &str| -> BTreeSet<&str> {
        named
            .iter()
            .filter(|(m, w)| facts[x].members.contains(**m) && (w.cp == x || facts[&w.cp].lineage.iter().any(|l| l == x)))
            .map(|(m, _)| *m)
            .collect()
    };
    let continuous = |x: &str| {
        let sup = supporters(x);
        cps.iter().all(|y| on_line(x, y))
            && cps
                .iter()
                .filter(|p| **p != x && facts[x].lineage.iter().any(|l| l == **p))
                .all(|p| sup.iter().filter(|m| facts[*p].members.contains(**m)).count() >= 2)
    };
    let picks: Vec<&str> = cps.iter().copied().filter(|x| supporters(x).len() >= 2 && continuous(x)).collect();
    if picks.iter().all(|a| picks.iter().all(|b| on_line(a, b))) {
        out.pick = picks.into_iter().max_by(|a, b| order_key(facts, a).cmp(&order_key(facts, b))).map(str::to_string);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::testkeys::keys;

    const NOW: i64 = 10_000;

    fn ask(nonce: &str, t_ms: i64) -> WitnessAsk {
        WitnessAsk { nonce: nonce.into(), t_age_ms: NOW - t_ms }
    }

    fn store() -> MessageStore {
        MessageStore::open(":memory:", &"ab".repeat(32)).expect("store")
    }

    /// Section 8.4: a witness names the newest checkpoint whose content it holds that it
    /// first folded before T on its own clock, dated by an age, signed by its device.
    #[test]
    fn a_witness_names_the_newest_checkpoint_first_folded_before_t() {
        let (state, view, cp1, thief_cp, phone, _) = crate::crdt::settle::tests::witness_world();
        let asker = phone.peer_id();
        let me = keys(30).0;
        let mut desk = WitnessDesk::default();
        let (w, op) = desk.answer(&store(), &state, &view, &ask("n1", 3_000), &asker, &me, NOW).expect("a counted asker is answered");
        assert_eq!(w.cp, hex::encode(cp1.content_hash()), "before T the phone's checkpoint, never the laptop's");
        assert_eq!(op.map(|o| o.hlc), Some(cp1.hlc.clone()), "and its op rides along");
        assert_eq!(w.folded_age_ms, NOW - 1_000);
        assert_eq!((w.asker.as_str(), w.by.as_str(), w.nonce.as_str()), (asker.as_str(), me.peer_id().as_str(), "n1"));
        assert!(w.verifies());

        let other = keys(31).0;
        let (w, _) = WitnessDesk::default().answer(&store(), &state, &view, &ask("n2", 6_000), &asker, &other, NOW).expect("answered");
        assert_eq!(w.cp, hex::encode(thief_cp.content_hash()), "a later T names the later checkpoint");

        let (w, op) = WitnessDesk::default().answer(&store(), &state, &view, &ask("n3", 500), &asker, &other, NOW).expect("answered");
        assert!(w.cp.is_empty() && op.is_none(), "nothing folded before T names nothing");

        let mut seeded = state.clone();
        std::sync::Arc::make_mut(&mut seeded.first_folds).insert(hex::encode(cp1.content_hash()), 0);
        let (w, _) = WitnessDesk::default().answer(&store(), &seeded, &view, &ask("n4", 3_000), &asker, &other, NOW).expect("answered");
        assert_eq!(w.folded_age_ms, -1, "the upgrade's seed is 'before the 0.14 update'");
    }

    /// C18: witness asks are refused to a device the view does not count for the owner,
    /// answered once per asker device per 10 minutes, and malformed asks get nothing.
    #[test]
    fn witness_asks_are_bounded_and_refused_to_an_uncounted_asker() {
        let (state, view, _, _, phone, _) = crate::crdt::settle::tests::witness_world();
        let asker = phone.peer_id();
        let me = keys(30).0;
        let mut desk = WitnessDesk::default();
        assert!(desk.answer(&store(), &state, &view, &ask("n1", 3_000), &keys(32).1, &me, NOW).is_none(), "an uncounted asker");
        assert!(desk.answer(&store(), &state, &view, &ask("bad\nnonce", 3_000), &asker, &me, NOW).is_none(), "a nonce out of shape");
        assert!(desk.answer(&store(), &state, &view, &WitnessAsk { nonce: "n".into(), t_age_ms: -1 }, &asker, &me, NOW).is_none(), "a T in the future");
        assert!(desk.answer(&store(), &state, &view, &ask("n1", 3_000), &asker, &me, NOW).is_some());
        assert!(desk.answer(&store(), &state, &view, &ask("n2", 3_000), &asker, &me, NOW + 1_000).is_none(), "once per 10 minutes");
        assert!(desk.answer(&store(), &state, &view, &ask("n3", 3_000), &asker, &me, NOW + ANSWER_EVERY_MS).is_some(), "then again");
    }

    /// A fresh install keeps only a witness that answers its own ask, from the device it
    /// names, whose signature and named content check.
    #[test]
    fn only_a_witness_answering_our_ask_from_its_signer_is_kept() {
        let (state, view, cp1, thief_cp, phone, _) = crate::crdt::settle::tests::witness_world();
        let us = phone.peer_id();
        let me = keys(30).0;
        let (w, op) = WitnessDesk::default().answer(&store(), &state, &view, &ask("n1", 3_000), &us, &me, NOW).unwrap();
        let mut desk = WitnessDesk::default();
        desk.receive(&me.peer_id(), w.clone(), op.clone(), NOW);
        assert!(desk.taken(&state.server_id).is_empty(), "an answer to no ask of ours");
        desk.asked(&us, &me.peer_id(), &state.server_id, "n1", w.t_age_ms, NOW);
        desk.receive(&keys(33).1, w.clone(), op.clone(), NOW);
        assert!(desk.taken(&state.server_id).is_empty(), "relayed by a device it does not name");
        let mut forged = w.clone();
        forged.cp = hex::encode(thief_cp.content_hash());
        desk.receive(&me.peer_id(), forged, Some(thief_cp.clone()), NOW);
        assert!(desk.taken(&state.server_id).is_empty(), "a changed field breaks the signature");
        desk.receive(&me.peer_id(), w.clone(), Some(thief_cp.clone()), NOW);
        assert!(desk.taken(&state.server_id).is_empty(), "content that is not the named checkpoint");
        let mut aged = w.clone();
        aged.t_age_ms += 1;
        desk.receive(&me.peer_id(), aged, op.clone(), NOW);
        assert!(desk.taken(&state.server_id).is_empty(), "an age our ask did not name");
        let (signed_other_age, other_op) = WitnessDesk::default().answer(&store(), &state, &view, &ask("n1", 2_000), &us, &me, NOW).unwrap();
        assert!(signed_other_age.verifies());
        desk.receive(&me.peer_id(), signed_other_age, other_op, NOW);
        assert!(desk.taken(&state.server_id).is_empty(), "a well-signed witness to an age our ask did not name");
        let other = keys(34).0;
        let (unasked, unasked_op) = WitnessDesk::default().answer(&store(), &state, &view, &ask("n1", 3_000), &us, &other, NOW).unwrap();
        desk.receive(&other.peer_id(), unasked, unasked_op, NOW);
        assert!(desk.taken(&state.server_id).is_empty(), "a well-signed witness from a device the nonce never went to");
        desk.receive(&me.peer_id(), w.clone(), op, NOW);
        assert_eq!(desk.taken(&state.server_id).len(), 1, "the witness is kept");
        assert_eq!(desk.taken(&state.server_id)[0].1.as_ref().map(|o| o.hlc.clone()), Some(cp1.hlc));
    }

    fn facts(entries: &[(&str, u64, &[&str], &[&str])]) -> HashMap<String, CpFacts> {
        entries
            .iter()
            .map(|(id, generation, lineage, members)| {
                let hlc = crate::crdt::hlc::HlcTimestamp { physical_ms: *generation * 1_000, counter: 0, actor: "o".into() };
                let f = CpFacts { generation: *generation, hlc, lineage: lineage.iter().map(|l| l.to_string()).collect(), members: members.iter().map(|m| m.to_string()).collect() };
                (id.to_string(), f)
            })
            .collect()
    }

    fn seen(identity: &str, cp: &str, age: i64) -> Seen {
        Seen { identity: identity.into(), cp: cp.into(), folded_age_ms: age, received_ms: 1_000_000 }
    }

    /// Steps 3 to 6: honest members on one line pick the newest point two of them support.
    #[test]
    fn honest_witnesses_on_one_line_pick_the_newest_supported_point() {
        let f = facts(&[("a", 1, &[], &["h1", "h2", "h3"]), ("b", 2, &["a"], &["h1", "h2", "h3"])]);
        let j = judge(&[seen("h1", "b", 10), seen("h2", "b", 10), seen("h3", "a", 50)], &f);
        assert_eq!(j.pick.as_deref(), Some("b"));
        assert_eq!(j.points.iter().map(|p| p.cp.as_str()).collect::<Vec<_>>(), ["b", "a"], "newest first");
        assert_eq!(j.points[0].named_by, ["h1", "h2"]);
        assert_eq!(j.points[1].date_ms, Some(1_000_000 - 50));
        let j = judge(&[seen("h1", "b", 10), seen("h3", "a", 50)], &f);
        assert_eq!(j.pick.as_deref(), Some("a"), "one supporter of b is no candidate; a has two");
        assert!(judge(&[seen("h1", "b", 10)], &f).pick.is_none(), "a lone witness is never a pick, continuous or not");
    }

    /// R31-1: puppets naming a thief line on top of an honest checkpoint never make it the
    /// pick past two honest witnesses, also through an intermediate puppet checkpoint.
    #[test]
    fn a_puppet_line_on_top_of_the_honest_point_is_never_the_pick() {
        let f = facts(&[
            ("ch", 1, &[], &["h1", "h2"]),
            ("y", 2, &["ch"], &["h1", "h2", "p1", "p2"]),
            ("xt", 3, &["y", "ch"], &["p1", "p2", "p3"]),
        ]);
        let w = [seen("h1", "ch", 9), seen("h2", "ch", 9), seen("p1", "y", 1), seen("p2", "xt", 1), seen("p3", "xt", 1)];
        assert_eq!(judge(&w, &f).pick.as_deref(), Some("ch"));
        // Without the honest witnesses the puppets pick their own line (section 17); p3,
        // never a member of y, cannot carry xt past it.
        assert_eq!(judge(&w[2..], &f).pick.as_deref(), Some("y"));
    }

    /// R3-8: two continuous candidates off one line make the choice ambiguous: no pick,
    /// every point listed.
    #[test]
    fn two_lines_are_ambiguous_and_list_every_point() {
        let f = facts(&[("a", 1, &[], &["m1", "m2", "m3", "m4"]), ("b", 2, &["a"], &["m1", "m2", "m3", "m4"]), ("c", 2, &["a"], &["m1", "m2", "m3", "m4"])]);
        let j = judge(&[seen("m1", "b", 1), seen("m2", "b", 1), seen("m3", "c", 1), seen("m4", "c", 1)], &f);
        assert_eq!(j.pick, None);
        assert_eq!(j.points.len(), 2);
        assert_eq!(j.counted.len(), 4);
    }

    /// Continuity (step 5): a point named off the candidate's line leaves no pick, even
    /// with a single candidate that two members support.
    #[test]
    fn a_point_named_off_the_line_leaves_no_pick() {
        let f = facts(&[("a", 1, &[], &["m1", "m2", "m3"]), ("b", 2, &["a"], &["m1", "m2", "m3"]), ("c", 2, &["a"], &["m1", "m2", "m3"])]);
        let j = judge(&[seen("m1", "b", 1), seen("m2", "b", 1), seen("m3", "c", 1)], &f);
        assert_eq!(j.pick, None, "{j:?}");
        assert_eq!(j.points.len(), 2);
    }

    /// Step 1: one witness per identity (the greatest on one line, else the oldest), and a
    /// witness counts only for a member of the state it names; -1 dates nothing.
    #[test]
    fn one_witness_per_identity_from_members_only() {
        let f = facts(&[("a", 1, &[], &["m1", "m2"]), ("b", 2, &["a"], &["m1", "m2"]), ("c", 2, &["a"], &["m1", "m2"])]);
        let j = judge(&[seen("m1", "a", 5), seen("m1", "b", 5), seen("m2", "b", 5)], &f);
        assert_eq!(j.pick.as_deref(), Some("b"), "m1's devices agree on a line: its greatest counts");
        let j = judge(&[seen("m1", "b", 5), seen("m1", "c", 5), seen("m2", "b", 5)], &f);
        assert!(j.points.iter().any(|p| p.cp == "a" || p.named_by.contains(&"m1".to_string()) && p.cp != "c"), "{j:?}");
        assert!(!j.points.iter().any(|p| p.cp == "c"), "m1's devices off one line: its oldest counts");
        let j = judge(&[seen("m1", "a", 1), seen("m1", "b", 1 + LINE_AGE_MS + 1), seen("m2", "b", 5)], &f);
        assert!(j.points.iter().find(|p| p.cp == "a").is_some_and(|p| p.named_by == ["m1"]), "ages far apart: the oldest");
        let j = judge(&[seen("stranger", "a", 1), seen("m1", "a", -1), seen("m2", "", 0)], &f);
        assert!(!j.counted.contains("stranger") && j.counted.contains("m2"), "a non-member counts nothing, a none-held witness counts");
        assert_eq!(j.points[0].date_ms, None, "a seeded record is undated");
        assert!(judge(&[seen("m1", "zz", 1)], &f).counted.is_empty(), "a content that did not check");
    }

    /// Step 7 and the chooser: progress until every asked identity answered or the wait
    /// ran out, choices only among named points after it, asks bounded and paced.
    #[test]
    fn the_restore_waits_then_offers_only_named_points() {
        let mut desk = WitnessDesk::default();
        desk.recover("s", 5_000);
        assert_eq!(desk.stage("s", 0), Some(Stage::Checking));
        let devices = |m: &str| vec![format!("{m}-dev")];
        desk.note_members("s", vec![("h1".into(), MemberSource::Contact), ("h2".into(), MemberSource::FriendEntry), ("me".into(), MemberSource::Contact)]);
        let asks = desk.due_asks("s", &["h3".into()], &devices, "me", "my-dev", 10_000);
        assert_eq!(asks.iter().map(|(d, _)| d.as_str()).collect::<Vec<_>>(), ["h1-dev", "h2-dev", "h3-dev"], "never ourselves");
        assert!(asks.iter().all(|(_, a)| a.t_age_ms == 5_000));
        assert!(desk.due_asks("s", &[], &devices, "me", "my-dev", 20_000).is_empty(), "asked once per 10 minutes");
        assert_eq!(desk.stage("s", 20_000), Some(Stage::Checking));
        assert!(desk.choose("s", None, 20_000).is_err(), "no choice before the wait ends");
        let f = facts(&[("a", 1, &[], &["h1", "h2", "h3"])]);
        desk.update("s", judge(&[seen("h1", "a", 1), seen("h2", "a", 1)], &f), 30_000);
        assert_eq!(desk.stage("s", 30_000), Some(Stage::Waiting), "a pick waits W for more");
        assert_eq!(desk.stage("s", 30_000 + WAIT_MS), Some(Stage::Pick));
        assert!(desk.choose("s", Some("zz".into()), 70_000).is_err(), "only a named point");
        desk.choose("s", Some("a".into()), 70_000).expect("a named point");
        assert!(desk.choose("s", None, 70_001).is_err(), "one choice at a time");
        assert!(desk.due_asks("s", &[], &devices, "me", "my-dev", 10_000 + ANSWER_EVERY_MS).is_empty(), "no asks once chosen");
        desk.finish("s");
        assert_eq!(desk.stage("s", 80_000), Some(Stage::Done));

        let mut lone = WitnessDesk::default();
        lone.recover("t", 5_000);
        lone.note_members("t", vec![("h1".into(), MemberSource::Contact)]);
        lone.due_asks("t", &[], &devices, "me", "my-dev", 10_000);
        assert_eq!(lone.stage("t", 10_000 + WAIT_MAX_MS), Some(Stage::NobodyReachable), "nobody answered in two minutes");
        let mut cap = WitnessDesk::default();
        cap.recover("u", 5_000);
        cap.note_members("u", (0..200).map(|i| (format!("m{i}"), MemberSource::JoinAnswer)).collect());
        let named: Vec<String> = (0..200).map(|i| format!("n{i}")).collect();
        assert_eq!(cap.due_asks("u", &named, &devices, "me", "my-dev", 10_000).len(), super::super::union_list::MAX_ASKED);
        assert!(cap.due_asks("u", &named, &devices, "me", "my-dev", 10_000 + ANSWER_EVERY_MS).len() <= super::super::union_list::MAX_ASKED);
        let mut unsure = WitnessDesk::default();
        unsure.recover("v", 0);
        assert_eq!(unsure.stage("v", 1), Some(Stage::Points), "T unknown: only \"I don't know\"");
        assert!(unsure.due_asks("v", &named, &devices, "me", "my-dev", 1).is_empty());
    }
}

#[cfg(test)]
#[path = "witness_review_b_tests.rs"]
mod review_b_tests;
