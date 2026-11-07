//! Co-members' rosters for server authority (DEVICE_PROOF_DESIGN section 9, H3).
//!
//! A roster one member delivers about another (a sync answer, a checkpoint's `cp_roster`)
//! never enters the global book, the resolver or DMs: it lands in `server_rosters`, kept
//! only for a master in the AUTHORITY SET of a server we hold (the owner plus the authors
//! of the ops it keeps), each statement verifying alone, and goes 30 days after no held
//! server needs it. Server authority reads the VIEW: the book's roster merged with these
//! rows under the same recovery key.

use std::collections::{BTreeSet, HashMap};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use sha2::{Digest, Sha256};

use crate::crdt::authority::{KeyRule, ViewEntry};
use crate::crdt::server_state::ServerState;
use crate::identity::roster::{MAX_ROSTER_BYTES, Roster};
use crate::storage::MessageStore;

/// Recovery keys kept per master: the one the server's key rule names (the founding
/// commitment, else the book's) and at most one other (AR-15).
const MAX_KEYS_PER_MASTER: usize = 2;
/// Bytes of every row together; past it the heaviest master gives way first.
pub(crate) const TOTAL_BYTES: i64 = 64 << 20;
/// A row no held server has needed for this long goes.
pub(crate) const AGE_OUT_MS: i64 = 30 * 24 * 60 * 60 * 1000;
/// How long a cached verdict stands without a roster write in this process.
const CACHE_TTL_MS: i64 = 60_000;
/// Roster fingerprint buckets per server (`OpDigest.rs`).
pub(crate) const BUCKETS: usize = 16;
/// The digest of a master we hold no roster for.
pub(crate) const NONE: &str = "none";

/// Every cached entry is stale ([`touched`]).
static EPOCH: AtomicU64 = AtomicU64::new(0);
/// Per-master write counters, by a hash slot: a write makes stale only the entries of
/// masters sharing its slot.
const GEN_SLOTS: usize = 1024;
static GENS: [AtomicU64; GEN_SLOTS] = [const { AtomicU64::new(0) }; GEN_SLOTS];

fn gen_slot(master: &str) -> usize {
    let d = Sha256::digest(master.as_bytes());
    (usize::from(d[0]) << 8 | usize::from(d[1])) % GEN_SLOTS
}

fn generation(master: &str) -> (u64, u64) {
    (EPOCH.load(Ordering::Relaxed), GENS[gen_slot(master)].load(Ordering::Relaxed))
}

/// Tests that write rosters behind the node's back: every cached entry is stale.
#[cfg(test)]
pub(crate) fn touched() {
    EPOCH.fetch_add(1, Ordering::Relaxed);
}

/// A roster of `master` was written in this process (book or `server_rosters`).
pub(crate) fn touched_master(master: &str) {
    GENS[gen_slot(master)].fetch_add(1, Ordering::Relaxed);
}

/// A row of `master` changed here: our caches and every view that holds it (track C1's
/// `note_saved`, INTERFACE item 1) judge it again.
fn saved(store: &MessageStore, master: &str) {
    touched_master(master);
    super::authority_view::note_saved(store, master);
    #[cfg(test)]
    SAVED_FOR_TEST.with(|s| s.borrow_mut().push(master.to_string()));
}

#[cfg(test)]
thread_local! {
    static SAVED_FOR_TEST: std::cell::RefCell<Vec<String>> = const { std::cell::RefCell::new(Vec::new()) };
    /// Store reads and judgments this thread ran (the cost the caches bound).
    static LOADED_FOR_TEST: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    static JUDGED_FOR_TEST: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// A bounded map that drops its least recently used sixteenth when full.
struct Lru<K, V> {
    map: HashMap<K, (V, u64)>,
    tick: u64,
    max: usize,
}

impl<K: std::hash::Hash + Eq + Clone, V: Clone> Lru<K, V> {
    fn new(max: usize) -> Self {
        Lru { map: HashMap::new(), tick: 0, max }
    }

    fn get(&mut self, key: &K) -> Option<V> {
        self.tick += 1;
        let tick = self.tick;
        self.map.get_mut(key).map(|(v, used)| {
            *used = tick;
            v.clone()
        })
    }

    fn put(&mut self, key: K, value: V) {
        self.tick += 1;
        if self.map.len() >= self.max && !self.map.contains_key(&key) {
            let mut ages: Vec<(u64, K)> = self.map.iter().map(|(k, (_, used))| (*used, k.clone())).collect();
            ages.sort_by_key(|(used, _)| *used);
            for (_, k) in ages.into_iter().take((self.max / 16).max(1)) {
                self.map.remove(&k);
            }
        }
        self.map.insert(key, (value, self.tick));
    }
}

#[derive(Clone)]
struct Cached {
    generation: (u64, u64),
    /// [`cp_print`] when judged: a new held `cp_roster` (a settling's removal) is no write
    /// here, yet it changes the entry.
    cp: [u8; 32],
    at_ms: i64,
    entry: ViewEntry,
}

/// A fingerprint of the `cp_roster`s of `master` that `state`'s held checkpoints carry.
fn cp_print(state: &ServerState, master: &str) -> [u8; 32] {
    let mut h = Sha256::new();
    for r in state.cp_rosters.iter().filter(|r| r.master == master) {
        h.update(b"\0");
        h.update(serde_json::to_vec(r).unwrap_or_default());
    }
    h.finalize().into()
}

/// (db path, server, master) -> the judged entry, until a write of that master or the TTL.
type CacheKey = (String, String, String);
static CACHE: Mutex<Option<Lru<CacheKey, Cached>>> = Mutex::new(None);
/// (master, key rule, fingerprint of the stored candidates) -> the judged entry: rosters
/// that say the same thing are never verified again.
type JudgedKey = (String, String, [u8; 32]);
static JUDGED: Mutex<Option<Lru<JudgedKey, ViewEntry>>> = Mutex::new(None);
const CACHE_MAX: usize = 8192;

fn ignored(db_path: &str, master: &str) -> bool {
    super::authority_view::ignored_for_test(db_path, master)
}

/// The server's authority set (track C1's, INTERFACE item 2).
pub(crate) fn authority_set(state: &ServerState) -> BTreeSet<String> {
    crate::crdt::authority::authority_set(state)
}

/// Whether some server we hold has `master` in its authority set.
pub(crate) fn needed_by<'a>(states: impl IntoIterator<Item = &'a ServerState>, master: &str) -> bool {
    states.into_iter().any(|s| authority_set(s).contains(master))
}

/// What [`keep`] did with a delivered roster.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kept {
    /// Stored, and it said something new.
    Changed,
    /// Nothing new: everything it says was held.
    Same,
    /// Not for a master the server needs, empty after verification, or over a bound.
    Refused,
}

/// The book's recovery key for `master`, as stored.
fn book_key(store: &MessageStore, master: &str) -> Option<String> {
    store.load_roster(master).ok().flatten().filter(|r| r.master == master).map(|r| r.r_pub).filter(|k| !k.is_empty())
}

/// Whether `key` is the one `state`'s key rule names for `master`: the founding nonce's
/// commitment for a 0.14 owner, else the book's key.
fn named_by_rule(rule: &KeyRule, book: Option<&str>, master: &str, key: &str) -> bool {
    match rule {
        KeyRule::Commit(_) => {
            let probe = Roster { r_pub: key.to_string(), ..Roster::new(master) };
            crate::crdt::authority::judge(master, rule, &[&probe]).key.is_some()
        }
        KeyRule::FirstHeld => book == Some(key),
    }
}

/// Keep a roster a member of `state`'s server delivered about `roster.master`.
pub(crate) fn keep(store: &MessageStore, db_path: &str, state: &ServerState, roster: &Roster, now_ms: i64) -> Kept {
    keep_with(store, db_path, state, roster, now_ms, false)
}

/// [`keep`] for the answer of the device we asked for a member's roster after the post
/// gate refused that member's post (`roster_round::post_refused`): a current member
/// outside the authority set is kept too.
pub(crate) fn keep_asked(store: &MessageStore, db_path: &str, state: &ServerState, roster: &Roster, now_ms: i64) -> Kept {
    keep_with(store, db_path, state, roster, now_ms, true)
}

fn keep_with(store: &MessageStore, db_path: &str, state: &ServerState, roster: &Roster, now_ms: i64, asked: bool) -> Kept {
    let master = roster.master.as_str();
    let needed = authority_set(state).contains(master) || asked && state.is_member(master);
    if ignored(db_path, master) || !needed {
        return Kept::Refused;
    }
    let checked = roster.verified(now_ms);
    if checked.master != master || checked.r_pub.is_empty() && checked.legacy.is_empty() {
        return Kept::Refused;
    }
    let rows = store.load_server_rosters(master).unwrap_or_default();
    let held = rows.iter().find(|(key, _)| *key == checked.r_pub).map(|(_, r)| r.reverified());
    let mut evict: Vec<String> = Vec::new();
    if held.is_none() {
        let rule = crate::crdt::authority::key_rule(state, master);
        let book = book_key(store, master);
        let named = |k: &str| named_by_rule(&rule, book.as_deref(), master, k);
        let others: Vec<&String> = rows.iter().map(|(k, _)| k).filter(|k| !named(k)).collect();
        if named(&checked.r_pub) {
            // The rule's key always has a slot: keys seen first (a master-key holder can
            // mint any number) give way to it, the first-seen other one stays.
            evict = others.iter().skip(MAX_KEYS_PER_MASTER - 1).map(|k| (*k).clone()).collect();
        } else if !others.is_empty() || rows.len() >= MAX_KEYS_PER_MASTER {
            return Kept::Refused;
        }
    }
    let merged = match &held {
        Some(h) => h.merged(&checked),
        None => checked.merged(&Roster::new(master)),
    };
    if held.as_ref().is_some_and(|h| h.digest() == merged.digest()) {
        let _ = store.note_server_roster_needed(master, now_ms);
        return Kept::Same;
    }
    let Ok(json) = serde_json::to_string(&merged) else { return Kept::Refused };
    if json.len() > MAX_ROSTER_BYTES || !merged.within_caps() {
        return Kept::Refused;
    }
    for key in &evict {
        let _ = store.delete_server_roster(master, key);
    }
    if store.save_server_roster(master, &merged.r_pub, &json, now_ms).is_err() {
        return Kept::Refused;
    }
    saved(store, master);
    trim(store, now_ms);
    Kept::Changed
}

/// Every row of `master`, statements checked again: what `authority_view::view_for` reads
/// as the co-member rosters (track C1, INTERFACE item 1). One table for every server: a
/// row is kept only while some held server's authority set names its master.
pub(crate) fn co_member_rosters(store: &MessageStore, _server_id: &str, master: &str) -> Vec<Roster> {
    store.load_server_rosters(master).unwrap_or_default().into_iter().map(|(_, r)| r.reverified()).collect()
}

/// The roster server authority reads for `master` outside any server's key rule: the
/// book's merged with our row under the same key, the book's key first. Only for gates
/// that are no server verdict.
pub(crate) fn view(store: &MessageStore, db_path: &str, master: &str) -> Option<Roster> {
    if ignored(db_path, master) {
        return None;
    }
    let book = super::roster_book::load(store, master);
    let rows = store.load_server_rosters(master).unwrap_or_default();
    let key = book.as_ref().map(|b| b.r_pub.clone()).or_else(|| rows.first().map(|(k, _)| k.clone()))?;
    let row = rows.into_iter().find(|(k, _)| *k == key).map(|(_, r)| r.reverified());
    match (book.filter(|b| b.r_pub == key), row) {
        (Some(b), Some(r)) => Some(b.merged(&r)),
        (Some(b), None) => Some(b),
        (None, r) => r,
    }
}

/// Whether [`view`] counts `device` for `master`.
#[cfg(test)]
pub(crate) fn counts(store: &MessageStore, db_path: &str, master: &str, device: &str) -> bool {
    view(store, db_path, master).is_some_and(|r| r.authority().counts(device))
}

/// The view's entry for `master` in `state`: track C1's judge over the book, our rows and
/// every held `cp_roster`, under the server's key rule (section 5). Judged again only
/// when a roster of that master was written here (or after the TTL), and then only when
/// what is stored says something new.
pub(crate) fn entry(store: &MessageStore, db_path: &str, state: &ServerState, master: &str) -> ViewEntry {
    let generation = generation(master);
    let cp = cp_print(state, master);
    let now = super::types::now_ms();
    let key = (db_path.to_string(), state.server_id.clone(), master.to_string());
    {
        let mut guard = CACHE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(c) = guard.get_or_insert_with(|| Lru::new(CACHE_MAX)).get(&key)
            && c.generation == generation
            && c.cp == cp
            && now.saturating_sub(c.at_ms) < CACHE_TTL_MS
        {
            return c.entry;
        }
    }
    #[cfg(test)]
    LOADED_FOR_TEST.with(|c| c.set(c.get() + 1));
    let rule = crate::crdt::authority::key_rule(state, master);
    let mut stored: Vec<Roster> = Vec::new();
    if !ignored(db_path, master) {
        stored.extend(store.load_roster(master).ok().flatten().filter(|r| r.master == master));
        let book_len = stored.len();
        stored.extend(store.load_server_rosters(master).unwrap_or_default().into_iter().map(|(_, r)| r));
        let recheck = stored.len();
        stored.extend(crate::crdt::authority::held_cp_rosters(state).into_iter().filter(|r| r.master == master));
        let mut h = Sha256::new();
        h.update(format!("{rule:?}\0{book_len}\0{recheck}").as_bytes());
        for r in &stored {
            h.update(b"\0");
            h.update(serde_json::to_vec(r).unwrap_or_default());
        }
        let print: [u8; 32] = h.finalize().into();
        let memo_key = (master.to_string(), format!("{rule:?}"), print);
        let memo = JUDGED.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(|| Lru::new(CACHE_MAX)).get(&memo_key);
        let entry = memo.unwrap_or_else(|| {
            let judged = judge(master, &rule, stored, recheck);
            JUDGED.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(|| Lru::new(CACHE_MAX)).put(memo_key, judged.clone());
            judged
        });
        return remember(key, (generation, cp), now, entry);
    }
    let entry = judge(master, &rule, Vec::new(), 0);
    remember(key, (generation, cp), now, entry)
}

/// The stored candidates, book first, the first `recheck` of them (the book and our rows)
/// with their statements checked again as `roster_book::load` reads them, judged by
/// track C1.
fn judge(master: &str, rule: &KeyRule, stored: Vec<Roster>, recheck: usize) -> ViewEntry {
    #[cfg(test)]
    JUDGED_FOR_TEST.with(|c| c.set(c.get() + 1));
    let candidates: Vec<Roster> =
        stored.into_iter().enumerate().map(|(i, r)| if i < recheck { r.reverified() } else { r }).collect();
    let refs: Vec<&Roster> = candidates.iter().collect();
    crate::crdt::authority::judge_held(master, rule, &refs[..recheck.min(refs.len())], &refs[recheck.min(refs.len())..])
}

fn remember(key: CacheKey, (generation, cp): ((u64, u64), [u8; 32]), now: i64, entry: ViewEntry) -> ViewEntry {
    let mut guard = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    guard.get_or_insert_with(|| Lru::new(CACHE_MAX)).put(key, Cached { generation, cp, at_ms: now, entry: entry.clone() });
    entry
}

/// Whether `state`'s view counts `device` for `master` (INTERFACE item 1's question).
pub(crate) fn server_counts(store: &MessageStore, db_path: &str, state: &ServerState, master: &str, device: &str) -> bool {
    let mut view = crate::crdt::authority::AuthorityView::judging();
    view.insert(master.to_string(), entry(store, db_path, state, master));
    view.counts(master, device)
}

/// The master `device` speaks for in `state`, when the view counts it there. The
/// transport's attribution names the claim, the view judges it.
pub(crate) fn place(store: &MessageStore, db_path: &str, state: &ServerState, device: &str) -> Option<String> {
    let master = super::resolver::resolve(device);
    server_counts(store, db_path, state, &master, device).then_some(master)
}

/// The identity a finished sync round with `device` counts for in the two-identities wait
/// (H4): the master our view places it under, never our own (our siblings agree with us
/// by construction).
pub(crate) fn round_identity(store: &MessageStore, db_path: &str, state: &ServerState, device: &str, local_master: &str) -> Option<String> {
    place(store, db_path, state, device).filter(|m| m != local_master)
}

/// `(master, key, digest)` for every master of the server's authority set, sorted; an
/// empty digest for a master we hold no roster of.
pub(crate) fn entries(store: &MessageStore, db_path: &str, state: &ServerState) -> Vec<(String, String, String)> {
    authority_set(state)
        .into_iter()
        .map(|m| {
            let e = entry(store, db_path, state, &m);
            let key = e.key.clone().unwrap_or_default();
            let digest = e.auth.map(|a| a.digest).unwrap_or_else(|| NONE.to_string());
            (m, key, digest)
        })
        .collect()
}

fn bucket_of(master: &str) -> usize {
    Sha256::digest(master.as_bytes())[0] as usize % BUCKETS
}

/// One salted fingerprint per bucket, 8 hex each.
pub(crate) fn prints(entries: &[(String, String, String)], salt: &str) -> Vec<String> {
    let mut hashers: Vec<Sha256> = (0..BUCKETS)
        .map(|_| {
            let mut h = Sha256::new();
            h.update(b"hollow-roster-bucket1\n");
            h.update(salt.as_bytes());
            h
        })
        .collect();
    for (m, k, d) in entries {
        let h = &mut hashers[bucket_of(m)];
        for part in [m, k, d] {
            h.update(b"\0");
            h.update(part.as_bytes());
        }
    }
    hashers.into_iter().map(|h| hex::encode(&h.finalize()[..4])).collect()
}

/// Our (master, digest) pairs in the buckets where `theirs` differs, at most
/// `sync_ext::MAX_RD`. A malformed `theirs` gets nothing.
pub(crate) fn differing(entries: &[(String, String, String)], theirs: &[String], salt: &str) -> Vec<(String, String)> {
    if theirs.len() != BUCKETS {
        return Vec::new();
    }
    let ours = prints(entries, salt);
    let differ: BTreeSet<usize> = (0..BUCKETS).filter(|&b| ours[b] != theirs[b]).collect();
    entries
        .iter()
        .filter(|(m, _, _)| differ.contains(&bucket_of(m)))
        .map(|(m, _, d)| (m.clone(), d.clone()))
        .take(super::sync_ext::MAX_RD)
        .collect()
}

/// Masters of our authority set whose digest in `rd` differs from ours: the rosters to
/// ask for, at most `sync_ext::MAX_ROSTERS_WANTED`.
pub(crate) fn wanted(entries: &[(String, String, String)], rd: &[(String, String)]) -> Vec<String> {
    let ours: HashMap<&str, &str> = entries.iter().map(|(m, _, d)| (m.as_str(), d.as_str())).collect();
    let mut out: Vec<String> = rd
        .iter()
        .filter(|(m, d)| d != NONE && ours.get(m.as_str()).is_some_and(|o| o != d))
        .map(|(m, _)| m.clone())
        .collect();
    out.sort();
    out.dedup();
    out.truncate(super::sync_ext::MAX_ROSTERS_WANTED);
    out
}

/// Each roster handed over costs at least this much of an answer's budget: its view is
/// verified again before it goes.
pub(crate) const ROSTER_MIN_CHARGE: usize = 4096;

/// The rosters an ask wants that we may hand over: members and masters of this server's
/// authority set we hold statements for, within `limit` bytes (at most the answer's bound), each
/// charged at least [`ROSTER_MIN_CHARGE`]. Returns them and what they were charged.
pub(crate) fn answer(store: &MessageStore, db_path: &str, state: &ServerState, wanted: &[String], limit: usize) -> (Vec<Roster>, usize) {
    let limit = limit.min(super::sync_ext::MAX_ROSTER_ANSWER_BYTES);
    let set = authority_set(state);
    let mut out = Vec::new();
    let mut charged = 0usize;
    for m in wanted.iter().take(super::sync_ext::MAX_ROSTERS_WANTED) {
        if !set.contains(m) && !state.is_member(m) {
            continue;
        }
        if charged.saturating_add(ROSTER_MIN_CHARGE) > limit {
            break;
        }
        charged += ROSTER_MIN_CHARGE;
        let Some(r) = view(store, db_path, m) else { continue };
        let size = serde_json::to_vec(&r).map(|v| v.len()).unwrap_or(usize::MAX);
        let extra = size.saturating_sub(ROSTER_MIN_CHARGE);
        if charged.saturating_add(extra) > limit {
            break;
        }
        charged += extra;
        out.push(r);
    }
    (out, charged)
}

/// Stamp the rows every held server still needs, drop the ones none has needed for 30
/// days, then trim to the byte budget.
pub(crate) fn age_out<'a>(store: &MessageStore, states: impl IntoIterator<Item = &'a ServerState> + Clone, now_ms: i64) {
    let Ok(rows) = store.server_roster_rows() else { return };
    for (master, key, _, last) in rows {
        if needed_by(states.clone(), &master) {
            let _ = store.note_server_roster_needed(&master, now_ms);
        } else if now_ms.saturating_sub(last) > AGE_OUT_MS {
            let _ = store.delete_server_roster(&master, &key);
            saved(store, &master);
        }
    }
    trim(store, now_ms);
}

/// Past [`TOTAL_BYTES`], rows go from the master whose rows weigh most together (each
/// row is charged to the identity it is about, the author of that master's ops), its row
/// needed longest ago first: one identity's flood never pushes out another's.
fn trim(store: &MessageStore, _now_ms: i64) -> bool {
    let Ok(rows) = store.server_roster_rows() else { return false };
    let mut total: i64 = rows.iter().map(|r| r.2).sum();
    if total <= TOTAL_BYTES {
        return false;
    }
    // master -> (bytes, its rows as (last needed, key, bytes))
    type Weights = HashMap<String, (i64, Vec<(i64, String, i64)>)>;
    let mut by_master: Weights = HashMap::new();
    for (master, key, bytes, last) in rows {
        let e = by_master.entry(master).or_default();
        e.0 += bytes;
        e.1.push((last, key, bytes));
    }
    while total > TOTAL_BYTES {
        let Some(heaviest) = by_master.iter().max_by(|a, b| a.1.0.cmp(&b.1.0).then_with(|| b.0.cmp(a.0))).map(|(m, _)| m.clone()) else {
            break;
        };
        let Some((weight, keys)) = by_master.get_mut(&heaviest) else { break };
        keys.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
        let (_, key, bytes) = keys.remove(0);
        let _ = store.delete_server_roster(&heaviest, &key);
        *weight -= bytes;
        total -= bytes;
        if keys.is_empty() {
            by_master.remove(&heaviest);
        }
        saved(store, &heaviest);
    }
    true
}

#[cfg(test)]
#[path = "server_rosters_tests.rs"]
mod tests;
