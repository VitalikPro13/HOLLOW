//! Who counts for server authority (DEVICE_PROOF_DESIGN sections 4, 5, 9 and 10): the
//! view a replica builds from its own store, the verdict it gives each device, and the
//! seams track C's two builders share (`.team/INTERFACE.md`).
#![allow(dead_code)] // seams track C2 calls until the merge (`.team/INTERFACE.md`)

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use sha2::Digest as _;

use super::operations::{CrdtOp, CrdtPayload};
use super::server_state::ServerState;
use crate::identity::roster::{Authority, Roster};

/// An op's device verdict (section 3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Verdict {
    /// The proof verifies and the author's view counts the device, or a counted
    /// endorsement names the op.
    Counted,
    /// The proof verifies; the view holds the author's statements and does not count it.
    Uncounted,
    /// The proof verifies; the view holds no statements under the key that judges the author.
    Missing,
    /// No proof, or one that fails: treated as absent.
    ProofLess,
}

impl Verdict {
    /// "The best proof wins" (section 6): `Uncounted` and `Missing` rank alike.
    pub fn rank(self) -> u8 {
        match self {
            Self::Counted => 2,
            Self::Uncounted | Self::Missing => 1,
            Self::ProofLess => 0,
        }
    }
}

impl From<DeviceVerdict> for Verdict {
    fn from(v: DeviceVerdict) -> Self {
        match v {
            DeviceVerdict::Counted => Self::Counted,
            DeviceVerdict::Uncounted => Self::Uncounted,
            DeviceVerdict::Missing => Self::Missing,
        }
    }
}

/// What a replica's view says about one device of one member identity.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DeviceVerdict {
    Counted,
    Uncounted,
    /// No statements for that identity under the key that judges it.
    Missing,
}

/// One identity in a view: the recovery key that judges it (`None` when none is known;
/// empty for a legacy roster) and the walk over its statements under that key (`None`
/// is `Missing`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ViewEntry {
    pub key: Option<String>,
    pub auth: Option<Authority>,
}

/// A replica's view of every identity in one server's authority set, built from its
/// own store before each ingest (`ServerState.authority`). Never persisted, never sent.
/// An UNSET view (the seam before the node sets it) counts every device, so every rule
/// that reads it is a no-op until then.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AuthorityView {
    set: bool,
    entries: BTreeMap<String, ViewEntry>,
}

impl AuthorityView {
    /// A view that judges: every identity it has no entry for reads `Missing`.
    pub fn judging() -> Self {
        Self { set: true, entries: BTreeMap::new() }
    }

    pub fn is_set(&self) -> bool {
        self.set
    }

    pub fn insert(&mut self, master: String, entry: ViewEntry) {
        self.set = true;
        self.entries.insert(master, entry);
    }

    /// Does this view count `device` for `member`? (section 4).
    pub fn device_verdict(&self, member: &str, device: &str) -> DeviceVerdict {
        if !self.set {
            return DeviceVerdict::Counted;
        }
        match self.entries.get(member).and_then(|e| e.auth.as_ref()) {
            None => DeviceVerdict::Missing,
            Some(a) if a.counts(device) => DeviceVerdict::Counted,
            Some(_) => DeviceVerdict::Uncounted,
        }
    }

    pub fn counts(&self, member: &str, device: &str) -> bool {
        self.device_verdict(member, device) == DeviceVerdict::Counted
    }

    pub fn entry(&self, master: &str) -> Option<&ViewEntry> {
        self.entries.get(master)
    }

    pub fn masters(&self) -> impl Iterator<Item = &String> {
        self.entries.keys()
    }

    /// `master`'s `OpDigest.rs` entry (section 9): (required key, roster digest), each
    /// empty when unknown or `Missing`.
    pub fn digest_entry(&self, master: &str) -> (String, String) {
        let e = self.entries.get(master);
        let key = e.and_then(|e| e.key.clone()).unwrap_or_default();
        let digest = e.and_then(|e| e.auth.as_ref()).map(|a| a.digest.clone()).unwrap_or_default();
        (key, digest)
    }

    /// A fingerprint of what this view says about `authors` (joins `retained_print`), so
    /// a restore whose view changed folds once more.
    pub fn digest_for<'a>(&self, authors: impl IntoIterator<Item = &'a str>) -> String {
        let mut authors: Vec<&str> = authors.into_iter().collect();
        authors.sort_unstable();
        authors.dedup();
        let mut h = sha2::Sha256::new();
        h.update(if self.set { b"set\n".as_slice() } else { b"unset\n".as_slice() });
        for a in authors {
            let (key, digest) = self.digest_entry(a);
            h.update(format!("{a}\0{key}\0{digest}\n").as_bytes());
        }
        hex::encode(&h.finalize()[..16])
    }
}

/// Which recovery key judges an author (section 5).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyRule {
    /// The owner of a server founded on 0.14: the key whose hash the founding nonce
    /// carries (32 hex).
    Commit(String),
    /// Everyone else: the first key held, in the order the candidates come (book first).
    FirstHeld,
}

/// The founding nonce of an owner with recovery key `r_pub`: 32 random hex, then 32 hex
/// committing to the key. At most 64 hex, which the relay and 0.13 accept.
pub fn committing_nonce(owner: &str, r_pub: &str) -> String {
    format!("{}{}", super::anchor::new_nonce(), key_commitment(owner, r_pub))
}

fn key_commitment(owner: &str, r_pub: &str) -> String {
    let d = sha2::Sha256::digest(format!("hollow-server-rk1:{owner}:{r_pub}").as_bytes());
    hex::encode(&d[..16])
}

/// The key commitment a founding nonce carries, when it carries one.
pub fn nonce_commitment(nonce: &str) -> Option<&str> {
    (nonce.len() == 64 && nonce.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))).then(|| &nonce[32..])
}

/// The founding op of a self-certifying server, when this replica holds it.
pub fn founding_op(state: &ServerState) -> Option<&CrdtOp> {
    if !super::anchor::is_genesis_id(&state.server_id) {
        return None;
    }
    state.op_log.iter().find(|op| match &op.payload {
        CrdtPayload::ServerCreated { owner_peer_id, nonce, .. } => {
            op.author == *owner_peer_id && super::anchor::derive_server_id(owner_peer_id, nonce) == state.server_id
        }
        _ => false,
    })
}

/// The rule that picks `master`'s key in `state`.
pub fn key_rule(state: &ServerState, master: &str) -> KeyRule {
    let committed = founding_op(state).and_then(|op| match &op.payload {
        CrdtPayload::ServerCreated { owner_peer_id, nonce, .. } if owner_peer_id == master => {
            nonce_commitment(nonce).map(str::to_string)
        }
        _ => None,
    });
    committed.map_or(KeyRule::FirstHeld, KeyRule::Commit)
}

/// `master`'s entry from every roster this replica holds for it (book first, then
/// `server_rosters`, then held `cp_roster`s): the key the rule picks, the candidates
/// under it merged, and the walk over them. No candidate under that key: `Missing`.
pub fn judge(master: &str, rule: &KeyRule, candidates: &[&Roster]) -> ViewEntry {
    let ours: Vec<&&Roster> = candidates.iter().filter(|r| r.master == master).collect();
    let key = match rule {
        KeyRule::Commit(c) => ours.iter().map(|r| r.r_pub.as_str()).find(|k| !k.is_empty() && key_commitment(master, k) == *c),
        KeyRule::FirstHeld => ours.first().map(|r| r.r_pub.as_str()),
    };
    let Some(key) = key.map(str::to_string) else {
        return ViewEntry { key: None, auth: None };
    };
    let mut merged: Option<Roster> = None;
    for r in ours.iter().filter(|r| r.r_pub == key) {
        merged = Some(match merged {
            None => (**r).clone(),
            Some(m) => m.merged(r),
        });
    }
    let auth = merged.map(|m| m.reverified().authority());
    ViewEntry { key: Some(key), auth }
}

/// `master`'s entry from what this replica holds: `pinned` (the book first, then the
/// `server_rosters` rows) and `carried` (held `cp_roster`s). Under `FirstHeld` only a
/// pinned roster picks the key and a carried one merges under it, so a checkpoint's
/// roster, which any holder of the owner key can write, never chooses who judges an
/// identity (section 5); under `Commit` the founding nonce picks it from either.
pub fn judge_held(master: &str, rule: &KeyRule, pinned: &[&Roster], carried: &[&Roster]) -> ViewEntry {
    let all: Vec<&Roster> = pinned.iter().chain(carried).copied().collect();
    match rule {
        KeyRule::Commit(_) => judge(master, rule, &all),
        KeyRule::FirstHeld => match pinned.iter().find(|r| r.master == master) {
            Some(first) => {
                let under: Vec<&Roster> = all.into_iter().filter(|r| r.r_pub == first.r_pub).collect();
                judge(master, rule, &under)
            }
            None => ViewEntry::default(),
        },
    }
}

/// The server's AUTHORITY SET (section 9): the owner and the authors of every retained,
/// parked, held and kept-unfolded op (own-kept, floor marks, re-fold pins), never the
/// rows only the base decides.
pub fn authority_set(state: &ServerState) -> BTreeSet<String> {
    use super::fold::RowKind;
    let mut out: BTreeSet<String> = state.anchor_owner().into_iter().collect();
    out.extend(state.op_log.iter().map(|o| o.author.clone()));
    out.extend(
        state.stored.iter().filter(|(_, k)| !matches!(k, RowKind::Parent | RowKind::Dormant)).map(|(o, _)| o.author.clone()),
    );
    out.extend(state.held.iter().map(|(o, _)| o.author.clone()));
    out
}

/// The checkpoint op a sync answerer offers as `SyncResponse.floor_base` (section 9):
/// for a server in recovery here, the pre-trigger base of its `floor_pending` row (never
/// `floor_b`); otherwise, to an ask that is a floor round, the current base.
pub fn floor_base_offer(state: &ServerState, floor_round: bool) -> Option<CrdtOp> {
    if let Some(r) = state.recovery.as_deref() {
        return r.base_op.clone();
    }
    if !floor_round {
        return None;
    }
    base_op(state).cloned()
}

/// The op of the checkpoint this state folds on.
pub fn base_op(state: &ServerState) -> Option<&CrdtOp> {
    let base = state.base.as_ref()?;
    state.op_log.iter().find(|op| matches!(op.payload, CrdtPayload::ServerCheckpoint { .. }) && state.content_of(op) == base.hash)
}

/// The checkpoint op an asker sends as `base_content` after `base_unknown` (section 9):
/// the base reference its ask named, when it still holds it (base, parent, restore
/// points, witnessed contents).
pub fn base_content_for(state: &ServerState, bref: &str) -> Option<CrdtOp> {
    state
        .op_log
        .iter()
        .chain(state.stored.iter().map(|(o, _)| o))
        .find(|op| matches!(op.payload, CrdtPayload::ServerCheckpoint { .. }) && hex::encode(state.content_of(op)) == bref)
        .cloned()
}

/// The `cp_roster` of every held settling checkpoint (section 8.3): statements are
/// facts once held, whatever the checkpoint's eligibility.
pub fn held_cp_rosters(state: &ServerState) -> Vec<Roster> {
    state.cp_rosters.to_vec()
}

/// A witness ask (section 8.4), riding `SyncRequest.witness`. `t_age_ms` is an AGE
/// (the asker's now minus T), never a date.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WitnessAsk {
    pub nonce: String,
    pub t_age_ms: i64,
}

/// A witness answer (section 8.4), riding `SyncResponse.witness` with the named
/// checkpoint op beside it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CpWitness {
    pub server: String,
    /// The asking device: an answer is never replayed to another.
    pub asker: String,
    pub nonce: String,
    pub t_age_ms: i64,
    /// Content id (hex), empty when none was held before T.
    pub cp: String,
    /// The witness's now minus its first fold of `cp`; -1 = before the 0.14 update.
    pub folded_age_ms: i64,
    /// The witness device.
    pub by: String,
    /// `by`'s device key over `hollow-cp-witness2\n` + the fields above, or with a
    /// record over `hollow-cp-witness3\n` + them + `rec`.
    pub sig: String,
    /// A record's id (`crdt::record::record_id`) when no checkpoint was held before T and
    /// the recovery's dropped ops were (HOL-SEC-230 part B); empty = none.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub rec: String,
}
