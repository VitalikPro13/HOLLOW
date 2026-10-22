//! Range digest for CRDT catch-up sync: which ops a peer holds, in about log2(ops) ranges.
//!
//! The set compared is a replica's retained ops plus the signed ops it keeps unread for a
//! newer build, in fold position by MILLISECOND (so equal-ms ops always share a range).
//! A range's fingerprint is its count and the wrapping sum of one AES block per op id,
//! keyed by a salt the asker picks, so no author can mint ops whose ids cancel. A range that
//! differs is sent whole when the answerer holds few ops in it, or split into sub-ranges the
//! asker compares again; the last round always sends. Design: `.team/DESIGN.md` of g13-s1a,
//! `reports/planned/relay-and-sync/SCALE_PROBE_2026_10.md` section 2.1.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use aes_gcm::aes::Aes128;
use aes_gcm::aes::cipher::{BlockEncrypt, KeyInit};
use base64::Engine;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::hlc::HlcTimestamp;
use super::operations::CrdtOp;
use super::server_state::{fold_key, retained_under, ServerState};

/// A differing range holding at most this many of the answerer's ops is sent whole.
pub const SEND_WHOLE: usize = 32;
/// The round that always sends.
pub const MAX_ROUNDS: u8 = 6;
/// Sub-ranges one answer may hold, and so ranges one follow-up may ask.
pub const SPLIT_BUDGET: usize = 256;

/// `(lo_ms, hi_ms, count, fingerprint)`, both bounds inclusive. An empty fingerprint asks
/// for every op in the range.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Range(pub u64, pub u64, pub u32, pub String);

/// `SyncRequest.digest`: what the asker holds.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpDigest {
    /// Echoed by the answer: ties a split to the ask it continues.
    pub ask: u64,
    pub salt: String,
    /// The asker's checkpoint: nothing it would prune is compared or sent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<HlcTimestamp>,
    /// Every op at or after this millisecond goes unconditionally: the asker holds none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<u64>,
    #[serde(default)]
    pub ranges: Vec<Range>,
    #[serde(default)]
    pub round: u8,
}

/// `SyncResponse.digest`: the answer to a digest ask.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DigestReply {
    pub ask: u64,
    #[serde(default)]
    pub round: u8,
    /// Per range too large to send: the answerer's own sub-range fingerprints, covering it.
    /// Empty = this answer ends the ask.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub groups: Vec<Vec<Range>>,
    /// The answerer cannot compare digests for this server: ask it with the state vector.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub vector: bool,
}

/// A signed op this build keeps unread, as its author signed it.
#[derive(Debug, Clone, Copy)]
pub struct KeptRef<'a> {
    pub author: &'a str,
    pub hlc: &'a HlcTimestamp,
    pub raw: &'a str,
}

/// What a differing range hands over.
#[derive(Debug, Clone, Copy)]
pub enum Item<'a> {
    Op(&'a CrdtOp),
    Raw(&'a str),
}

/// One op of the compared set.
#[derive(Debug, Clone, Copy)]
pub struct Entry<'a> {
    pub ms: u64,
    id: u128,
    pub item: Item<'a>,
}

/// Unsalted op-id hashes of one state, so a digest costs one AES block per op. Keyed by a
/// randomly keyed 64-bit hash of the id, so a lookup allocates nothing and no author can
/// aim two ops at one slot.
#[derive(Default)]
pub struct IdMemo(Mutex<Memo>);

#[derive(Default)]
struct Memo {
    keys: std::collections::hash_map::RandomState,
    ids: HashMap<u64, u128>,
    /// The last compared set, for the burst of asks a reconnect makes: (what it was built
    /// from, (ms, id, index into the log, or into the kept ops when `kept`)).
    last: Option<(SetStamp, Vec<Row>)>,
}

/// One op of a cached set: (ms, id, index into the log, or into the kept ops when true).
type Row = (u64, u128, usize, bool);

#[derive(Clone, PartialEq, Eq)]
struct SetStamp {
    log_len: usize,
    log_sum: u64,
    kept: u128,
    base: Option<HlcTimestamp>,
}

impl Clone for IdMemo {
    fn clone(&self) -> Self {
        Self::default()
    }
}

impl std::fmt::Debug for IdMemo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("IdMemo")
    }
}

/// An op's identity, the dedup key `(author, hlc)`, hashed.
pub fn id_hash(author: &str, hlc: &HlcTimestamp) -> u128 {
    let mut h = Sha256::new();
    h.update(b"hollow-opid1\0");
    h.update(author.as_bytes());
    h.update([0]);
    h.update(hlc.physical_ms.to_be_bytes());
    h.update(hlc.counter.to_be_bytes());
    h.update(hlc.actor.as_bytes());
    let out = h.finalize();
    u128::from_be_bytes(out[..16].try_into().expect("16 bytes"))
}

/// A fresh salt, base64.
pub fn new_salt() -> String {
    let mut salt = [0u8; 16];
    if getrandom::fill(&mut salt).is_err() {
        // Never a constant: the salt is what keeps ids from being minted to cancel.
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
        salt.copy_from_slice(&Sha256::digest(now.as_nanos().to_be_bytes())[..16]);
    }
    base64::engine::general_purpose::STANDARD_NO_PAD.encode(salt)
}

/// The keyed fingerprint function of one salt.
pub struct Keyed(Aes128);

impl Keyed {
    pub fn new(salt: &str) -> Option<Self> {
        let bytes = base64::engine::general_purpose::STANDARD_NO_PAD.decode(salt).ok()?;
        let key: [u8; 16] = bytes.try_into().ok()?;
        Some(Self(Aes128::new(&key.into())))
    }

    fn of(&self, id: u128) -> u128 {
        let mut block = id.to_be_bytes().into();
        self.0.encrypt_block(&mut block);
        u128::from_be_bytes(block.into())
    }

    /// `(count, fingerprint)` of `entries`.
    fn print(&self, entries: &[Entry<'_>]) -> (u32, String) {
        let sum = entries.iter().fold(0u128, |acc, e| acc.wrapping_add(self.of(e.id)));
        let n = u32::try_from(entries.len()).unwrap_or(u32::MAX);
        (n, base64::engine::general_purpose::STANDARD_NO_PAD.encode(sum.to_be_bytes()))
    }
}

/// The compared set of `state` as an asker whose checkpoint is `base` sees it, sorted by
/// fold millisecond.
pub fn entries<'a>(state: &'a ServerState, kept: &[KeptRef<'a>], base: Option<&HlcTimestamp>) -> Vec<Entry<'a>> {
    use std::hash::BuildHasher;
    let genesis = super::anchor::is_genesis_id(&state.server_id);
    let mut guard = state.id_memo.0.lock().unwrap_or_else(|e| e.into_inner());
    let memo = &mut *guard;
    let slot = |op: &CrdtOp| memo.keys.hash_one((op.author.as_str(), &op.hlc));
    let slots: Vec<u64> = state.op_log.iter().map(slot).collect();
    // Order-sensitive: cached rows index into both lists, so a reorder of the same set is a miss.
    let stamp = SetStamp {
        log_len: slots.len(),
        log_sum: slots.iter().fold(0u64, |a, s| a.wrapping_mul(0x100_0000_01b3).wrapping_add(*s)),
        kept: kept.iter().fold(0u128, |a, k| a.wrapping_mul(0x100_0000_01b3).wrapping_add(id_hash(k.author, k.hlc))),
        base: base.cloned(),
    };
    let rebuild = |rows: &[Row]| -> Vec<Entry<'a>> {
        rows.iter()
            .map(|&(ms, id, at, is_kept)| Entry {
                ms,
                id,
                item: if is_kept { Item::Raw(kept[at].raw) } else { Item::Op(&state.op_log[at]) },
            })
            .collect()
    };
    if let Some((was, rows)) = &memo.last
        && *was == stamp
    {
        return rebuild(rows);
    }
    if memo.ids.len() > slots.len() * 2 + 256 {
        let live: HashSet<u64> = slots.iter().copied().collect();
        memo.ids.retain(|k, _| live.contains(k));
    }
    let mut rows: Vec<Row> = Vec::with_capacity(slots.len() + kept.len());
    for (at, (op, key)) in state.op_log.iter().zip(&slots).enumerate() {
        if base.is_none_or(|b| retained_under(op, b, genesis)) {
            let id = *memo.ids.entry(*key).or_insert_with(|| id_hash(&op.author, &op.hlc));
            rows.push((fold_key(op).0.physical_ms, id, at, false));
        }
    }
    let held: HashSet<u128> = rows.iter().map(|r| r.1).collect();
    for (at, k) in kept.iter().enumerate() {
        let id = id_hash(k.author, k.hlc);
        if held.contains(&id) {
            continue;
        }
        let covers = kept_checkpoint_covers(k.raw);
        let retained = match (&covers, base) {
            (_, None) => true,
            (Some(c), Some(b)) => c >= b,
            (None, Some(b)) => k.hlc > b,
        };
        if retained {
            rows.push((covers.as_ref().unwrap_or(k.hlc).physical_ms, id, at, true));
        }
    }
    rows.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
    let out = rebuild(&rows);
    memo.last = Some((stamp, rows));
    out
}

/// What a kept raw checkpoint covers: where the fold places it.
fn kept_checkpoint_covers(raw: &str) -> Option<HlcTimestamp> {
    let v: serde_json::Value = serde_json::from_str(raw).ok()?;
    serde_json::from_value(v.get("payload")?.get("ServerCheckpoint")?.get("covers")?.clone()).ok()
}

/// The entries with `lo <= ms <= hi`.
fn within<'s, 'a>(entries: &'s [Entry<'a>], lo: u64, hi: u64) -> &'s [Entry<'a>] {
    let start = entries.partition_point(|e| e.ms < lo);
    let end = entries.partition_point(|e| e.ms <= hi);
    if start >= end { &[] } else { &entries[start..end] }
}

/// The first ask: ranges doubling in size back from our newest op, and everything after it.
pub fn first_ask(entries: &[Entry<'_>], ask: u64, salt: String, base: Option<HlcTimestamp>) -> OpDigest {
    let Some(keyed) = Keyed::new(&salt) else {
        return OpDigest { ask, salt, base, from: Some(0), ranges: Vec::new(), round: 0 };
    };
    let Some(top) = entries.last().map(|e| e.ms) else {
        return OpDigest { ask, salt, base, from: Some(0), ranges: Vec::new(), round: 0 };
    };
    let mut bounds: Vec<u64> = vec![0];
    let mut back = 1usize;
    while back <= entries.len() {
        bounds.push(entries[entries.len() - back].ms);
        back = back.saturating_mul(2);
    }
    bounds.sort_unstable();
    bounds.dedup();
    let ranges = bounds
        .iter()
        .enumerate()
        .map(|(i, &lo)| {
            let hi = bounds.get(i + 1).map_or(top, |next| next - 1);
            let (n, fp) = keyed.print(within(entries, lo, hi));
            Range(lo, hi, n, fp)
        })
        .collect();
    OpDigest { ask, salt, base, from: top.checked_add(1), ranges, round: 0 }
}

/// The answer to a digest: what to hand over and the sub-ranges to compare again. `None`
/// for an ask no honest asker sends.
pub fn answer<'s, 'a>(entries: &'s [Entry<'a>], d: &OpDigest) -> Option<(Vec<Item<'a>>, DigestReply)> {
    if d.ranges.len() > SPLIT_BUDGET || d.round > MAX_ROUNDS || !disjoint(&d.ranges) {
        return None;
    }
    let keyed = Keyed::new(&d.salt)?;
    let mut send: Vec<Item<'a>> = Vec::new();
    let mut to_split: Vec<&'s [Entry<'a>]> = Vec::new();
    let mut sent_ids: HashSet<u128> = HashSet::new();
    let mut take = |es: &[Entry<'a>], send: &mut Vec<Item<'a>>| {
        for e in es {
            if sent_ids.insert(e.id) {
                send.push(e.item);
            }
        }
    };
    for Range(lo, hi, n, fp) in &d.ranges {
        let ours = within(entries, *lo, *hi);
        let forced = fp.is_empty();
        if !forced && keyed.print(ours) == (*n, fp.clone()) {
            continue;
        }
        let one_ms = ours.first().map(|e| e.ms) == ours.last().map(|e| e.ms);
        if forced || ours.len() <= SEND_WHOLE || one_ms || d.round >= MAX_ROUNDS {
            take(ours, &mut send);
        } else {
            to_split.push(ours);
        }
    }
    let mut groups = Vec::new();
    let mut budget = SPLIT_BUDGET;
    let fanout = (SPLIT_BUDGET / to_split.len().max(1)).max(2);
    for ours in to_split {
        let parts = fanout.min(ours.len().div_ceil(SEND_WHOLE)).max(2).min(budget);
        let group = (parts >= 2).then(|| split(&keyed, ours, parts)).filter(|g| g.len() >= 2);
        match group {
            Some(group) => {
                budget -= group.len();
                groups.push(group);
            }
            None => take(ours, &mut send),
        }
    }
    if let Some(from) = d.from {
        take(&entries[entries.partition_point(|e| e.ms < from)..], &mut send);
    }
    Some((send, DigestReply { ask: d.ask, round: d.round, groups, vector: false }))
}

/// `ours` cut into at most `parts` sub-ranges of about equal count at distinct
/// milliseconds, together covering exactly the range they came from.
fn split(keyed: &Keyed, ours: &[Entry<'_>], parts: usize) -> Vec<Range> {
    let (Some(first), Some(last)) = (ours.first(), ours.last()) else { return Vec::new() };
    let mut cuts: Vec<u64> = (1..parts).map(|k| ours[k * ours.len() / parts].ms).filter(|ms| *ms > first.ms).collect();
    cuts.dedup();
    let mut lows = vec![first.ms];
    lows.extend(cuts);
    lows.iter()
        .enumerate()
        .map(|(i, &lo)| {
            let hi = lows.get(i + 1).map_or(last.ms, |next| next - 1);
            let (n, fp) = keyed.print(within(ours, lo, hi));
            Range(lo, hi, n, fp)
        })
        .collect()
}

/// Whether `ranges` is a well-formed range list: each `lo <= hi`, strictly increasing and
/// disjoint. Anything else costs the reader ranges x log for nothing an honest peer sends.
fn disjoint(ranges: &[Range]) -> bool {
    ranges.iter().all(|r| r.0 <= r.1) && ranges.windows(2).all(|w| w[0].1 < w[1].0)
}

/// The ranges to ask again after `reply`: per group the sub-ranges we differ on, or its
/// whole span once more than half of them differ. `None` when the reply is not one an
/// honest answerer of `asked` sends: groups unsorted, overlapping, outside an asked range,
/// or more sub-ranges than one answer may hold.
pub fn follow_up(entries: &[Entry<'_>], salt: &str, asked: &[(u64, u64)], reply: &DigestReply) -> Option<Vec<Range>> {
    let keyed = Keyed::new(salt)?;
    let all: Vec<Range> = reply.groups.iter().flatten().cloned().collect();
    let inside = |g: &Vec<Range>| match (g.first(), g.last()) {
        (Some(first), Some(last)) => asked.iter().any(|(lo, hi)| *lo <= first.0 && last.1 <= *hi),
        _ => false,
    };
    if all.len() > SPLIT_BUDGET || !disjoint(&all) || !reply.groups.iter().all(inside) {
        return None;
    }
    let mut out = Vec::new();
    for group in &reply.groups {
        let differing: Vec<Range> = group
            .iter()
            .filter_map(|Range(lo, hi, n, fp)| {
                let ours = keyed.print(within(entries, *lo, *hi));
                (ours != (*n, fp.clone())).then_some(Range(*lo, *hi, ours.0, ours.1))
            })
            .collect();
        if differing.len() * 2 > group.len() {
            if let (Some(first), Some(last)) = (group.first(), group.last()) {
                out.push(Range(first.0, last.1, 0, String::new()));
            }
        } else {
            out.extend(differing);
        }
    }
    Some(out)
}

/// The JSON array a sync answer carries: ops serialized, kept ops exactly as signed.
pub fn items_json(items: &[Item<'_>]) -> String {
    let mut out = String::from("[");
    let mut first = true;
    for item in items {
        let part = match item {
            Item::Op(op) => match serde_json::to_string(op) {
                Ok(s) => s,
                Err(_) => continue,
            },
            Item::Raw(raw) => (*raw).to_string(),
        };
        if !first {
            out.push(',');
        }
        out.push_str(&part);
        first = false;
    }
    out.push(']');
    out
}

#[cfg(test)]
mod tests;
