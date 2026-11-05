//! The roster: which devices are one identity's (design ID-1).
//!
//! A set of signed statements, each verifiable on its own, that every observer folds
//! into the same answer. Holding the master key admits nothing: a device joins by its
//! own consent plus a vouch from a current device, the recovery phrase, or seven days
//! with nobody objecting. Removals are a plain union, so the fold needs no order; the
//! recovery phrase, whose statements alone carry a trustworthy time, starts a new base
//! that supersedes everything signed before it.

use std::collections::{BTreeMap, BTreeSet};

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::native_identity::NativeKeypair;

/// The base of an identity that has never had its phrase typed on 0.12.
pub(crate) const LEGACY_BASE: &str = "legacy";
/// A pending join nobody answered counts after this long, on each observer's clock.
pub(crate) const PENDING_MATURITY_MS: i64 = 7 * 24 * 60 * 60 * 1000;
/// A removed device erases itself this long after it learns of the removal.
pub(crate) const REMOVAL_GRACE_MS: i64 = 3 * 24 * 60 * 60 * 1000;
/// How far past our clock a phrase statement may be dated.
const MAX_FUTURE_SKEW_MS: i64 = 10 * 60 * 1000;
/// When the recovery an identity from before 0.12 signs at its first 0.12 start is
/// dated (2020-01-01): fixed, so each of its devices signs the very same statement,
/// and older than any phrase typed on 0.12, so a typed recovery supersedes it.
pub(crate) const UPGRADE_RECOVERY_AT_MS: i64 = 1_577_836_800_000;
/// A roster bigger than this on the wire is dropped whole.
pub(crate) const MAX_ROSTER_BYTES: usize = 256 * 1024;
/// Ceilings that keep the largest roster under `MAX_ROSTER_BYTES`. Vouches and removals
/// count only from a signer with standing and give way by the signer's distance from
/// the phrase, so a flood pushes out only what sits as deep as its signer or deeper.
/// The relay mirrors every one of these (`relay-uws/src/roster.h`).
pub(crate) const MAX_VOUCHES: usize = 128;
pub(crate) const MAX_REMOVALS: usize = 96;
/// Removals kept outside `MAX_REMOVALS`: per standing target, the removal the walk
/// counted first, the shallowest targets first, so no flood pushes one out (N1).
pub(crate) const MAX_RESERVED: usize = 32;
pub(crate) const MAX_REMOVAL_KEEP: usize = 16;
pub(crate) const MAX_KEEP: usize = 64;
const MAX_RECOVERY_TIES: usize = 4;
const MAX_PHRASE_ADMITS: usize = 64;
const MAX_LEGACY: usize = 64;
pub(crate) const MAX_PENDING: usize = 16;
/// Removals one DM carries at most (F2), and their size on the wire. A receiver
/// ignores a carry over either whole.
pub(crate) const MAX_CARRIED_REMOVALS: usize = 8;
pub(crate) const MAX_CARRIED_REMOVAL_BYTES: usize = 4096;
const MAX_CONSENTS: usize = 96;
const MAX_UNNAMED_CONSENTS: usize = 8;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Roster {
    #[serde(default)]
    pub master: String,
    /// Base64 of the recovery public key; empty until a phrase statement is known.
    /// Once set, statements under any other key are dropped (first seen, pinned).
    #[serde(default)]
    pub r_pub: String,
    #[serde(default)]
    pub recoveries: Vec<Recovery>,
    #[serde(default)]
    pub phrase_admits: Vec<PhraseAdmit>,
    #[serde(default)]
    pub consents: Vec<Consent>,
    #[serde(default)]
    pub vouches: Vec<Vouch>,
    #[serde(default)]
    pub pendings: Vec<Pending>,
    #[serde(default)]
    pub legacy: Vec<LegacyClaim>,
    #[serde(default)]
    pub removals: Vec<Removal>,
}

/// The device's own key agrees to belong to this master.
#[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub(crate) struct Consent {
    #[serde(default)]
    pub device: String,
    #[serde(default)]
    pub sig: String,
}

/// The phrase starts a new base keeping exactly `keep`. Signed by R and by M.
/// `no_wait`: in this base a restored backup never joins by waiting seven days.
#[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub(crate) struct Recovery {
    #[serde(default)]
    pub at_ms: i64,
    #[serde(default)]
    pub keep: Vec<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub no_wait: bool,
    #[serde(default)]
    pub sig_r: String,
    #[serde(default)]
    pub sig_m: String,
}

/// The phrase was typed on `device`. Signed by R and by M.
#[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub(crate) struct PhraseAdmit {
    #[serde(default)]
    pub at_ms: i64,
    #[serde(default)]
    pub device: String,
    #[serde(default)]
    pub sig_r: String,
    #[serde(default)]
    pub sig_m: String,
}

/// Device `by` admits `device` into `base`.
#[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub(crate) struct Vouch {
    #[serde(default)]
    pub base: String,
    #[serde(default)]
    pub device: String,
    #[serde(default)]
    pub by: String,
    #[serde(default)]
    pub sig: String,
}

/// `device` asks to join `base` with nobody vouching. Signed by M.
#[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub(crate) struct Pending {
    #[serde(default)]
    pub base: String,
    #[serde(default)]
    pub device: String,
    #[serde(default)]
    pub sig_m: String,
}

/// A device that was already this identity's before 0.12. Signed by M; counts only in
/// the legacy base.
#[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub(crate) struct LegacyClaim {
    #[serde(default)]
    pub device: String,
    #[serde(default)]
    pub sig_m: String,
}

/// Device `by` removes `device` from `base`, keeping the listed devices that `device`
/// had vouched for.
#[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub(crate) struct Removal {
    #[serde(default)]
    pub base: String,
    #[serde(default)]
    pub device: String,
    #[serde(default)]
    pub by: String,
    #[serde(default)]
    pub keep_vouched: Vec<String>,
    #[serde(default)]
    pub sig: String,
}

/// What a roster says at one moment, for one observer.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct RosterState {
    pub base: String,
    /// A recovery exists: the phrase, not the master key, is the root.
    pub protected: bool,
    /// The phrase turned off joining by seven quiet days in this base.
    pub no_wait: bool,
    pub members: BTreeSet<String>,
    /// Removed device -> the device that removed it.
    pub removed: BTreeMap<String, String>,
    /// Asked to join, not yet answered or matured.
    pub pending: BTreeSet<String>,
}

impl RosterState {
    pub(crate) fn is_member(&self, device: &str) -> bool {
        self.members.contains(device)
    }
}

/// [`Roster::authority`] with what it was computed from.
struct AuthorityParts<'a> {
    auth: Authority,
    paths: BTreeMap<String, Option<Vouch>>,
    roots: BTreeSet<String>,
    vouches: Vec<&'a Vouch>,
    voids: Voids,
}

/// Which devices write for an identity in server authority (DEVICE_PROOF_DESIGN
/// section 4): a function of the statements alone, with no clock, no maturity and no
/// first sight. `key` is the recovery key that judged it, `digest` the roster's.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Authority {
    pub key: String,
    pub base: String,
    pub counted: BTreeSet<String>,
    /// Removed device -> the device whose removal the walk counted first.
    pub removed: BTreeMap<String, String>,
    /// Every removal the walk counted, sorted.
    pub counted_removals: Vec<Removal>,
    pub digest: String,
}

impl Authority {
    pub(crate) fn counts(&self, device: &str) -> bool {
        self.counted.contains(device)
    }
}

// -- Payloads --

fn sorted(v: &[String]) -> Vec<String> {
    let mut s = v.to_vec();
    s.sort();
    s.dedup();
    s
}

pub(crate) fn consent_payload(master: &str, device: &str) -> String {
    format!("hollow-id1-join:{master}:{device}")
}

pub(crate) fn recovery_payload(master: &str, r_pub: &str, at_ms: i64, keep: &[String], no_wait: bool) -> String {
    let flag = if no_wait { ":nowait" } else { "" };
    format!("hollow-id1-recovery:{master}:{r_pub}:{at_ms}:{}{flag}", sorted(keep).join(","))
}

pub(crate) fn phrase_admit_payload(master: &str, r_pub: &str, at_ms: i64, device: &str) -> String {
    format!("hollow-id1-radmit:{master}:{r_pub}:{at_ms}:{device}")
}

pub(crate) fn vouch_payload(master: &str, base: &str, device: &str) -> String {
    format!("hollow-id1-admit:{master}:{base}:{device}")
}

pub(crate) fn pending_payload(master: &str, base: &str, device: &str) -> String {
    format!("hollow-id1-pending:{master}:{base}:{device}")
}

pub(crate) fn legacy_payload(master: &str, device: &str) -> String {
    format!("hollow-id1-legacy:{master}:{device}")
}

pub(crate) fn removal_payload(master: &str, base: &str, device: &str, keep_vouched: &[String]) -> String {
    format!(
        "hollow-id1-remove:{master}:{base}:{device}:{}",
        sorted(keep_vouched).join(",")
    )
}

/// The id device statements use to name a recovery's base.
pub(crate) fn base_id(master: &str, r_pub: &str, rec: &Recovery) -> String {
    let payload = recovery_payload(master, r_pub, rec.at_ms, &rec.keep, rec.no_wait);
    hex::encode(&Sha256::digest(payload.as_bytes())[..16])
}

fn is_base_shape(base: &str) -> bool {
    base == LEGACY_BASE || (base.len() == 32 && base.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()))
}

/// An id is usable in a roster only if it is an Ed25519 peer id, which also rules out
/// the `:` and `,` the payloads use as separators.
fn key_of(id: &str) -> Option<[u8; 32]> {
    crate::crypto::safety_number::pubkey_from_peer_id(id)
}

fn verify(pubkey: &[u8; 32], payload: &str, sig_b64: &str) -> bool {
    let Ok(sig) = B64.decode(sig_b64) else { return false };
    let Ok(sig) = <[u8; 64]>::try_from(sig.as_slice()) else { return false };
    let Ok(vk) = ed25519_dalek::VerifyingKey::from_bytes(pubkey) else { return false };
    vk.verify_strict(payload.as_bytes(), &ed25519_dalek::Signature::from_bytes(&sig))
        .is_ok()
}

fn verify_by(id: &str, payload: &str, sig_b64: &str) -> bool {
    key_of(id).is_some_and(|k| verify(&k, payload, sig_b64))
}

fn sign(kp: &NativeKeypair, payload: &str) -> String {
    B64.encode(kp.sign(payload.as_bytes()))
}

// -- Signing --

pub(crate) fn r_pub_of(recovery: &NativeKeypair) -> String {
    B64.encode(recovery.public_key_bytes())
}

pub(crate) fn sign_consent(device: &NativeKeypair, master: &str) -> Consent {
    let id = device.peer_id();
    Consent { sig: sign(device, &consent_payload(master, &id)), device: id }
}

pub(crate) fn sign_recovery(
    master: &NativeKeypair,
    recovery: &NativeKeypair,
    at_ms: i64,
    keep: &[String],
    no_wait: bool,
) -> Recovery {
    let payload = recovery_payload(&master.peer_id(), &r_pub_of(recovery), at_ms, keep, no_wait);
    Recovery {
        at_ms,
        keep: sorted(keep),
        no_wait,
        sig_r: sign(recovery, &payload),
        sig_m: sign(master, &payload),
    }
}

pub(crate) fn sign_phrase_admit(
    master: &NativeKeypair,
    recovery: &NativeKeypair,
    at_ms: i64,
    device: &str,
) -> PhraseAdmit {
    let payload = phrase_admit_payload(&master.peer_id(), &r_pub_of(recovery), at_ms, device);
    PhraseAdmit {
        at_ms,
        device: device.to_string(),
        sig_r: sign(recovery, &payload),
        sig_m: sign(master, &payload),
    }
}

/// The upgrade's recovery. It keeps only the recovery key's own id, which no device
/// can consent as without the phrase, so the base is the same whichever device signs
/// first and nothing vouched or removed in it is lost when another device upgrades;
/// the devices themselves come in by [`sign_upgrade_admit`].
pub(crate) fn sign_upgrade_recovery(master: &NativeKeypair, recovery: &NativeKeypair) -> Recovery {
    sign_recovery(master, recovery, UPGRADE_RECOVERY_AT_MS, &[recovery.peer_id()], false)
}

/// The phrase admits `device` into the upgrade's base, and into no base typed later.
pub(crate) fn sign_upgrade_admit(master: &NativeKeypair, recovery: &NativeKeypair, device: &str) -> PhraseAdmit {
    sign_phrase_admit(master, recovery, UPGRADE_RECOVERY_AT_MS + 1, device)
}

pub(crate) fn sign_vouch(by: &NativeKeypair, master: &str, base: &str, device: &str) -> Vouch {
    Vouch {
        base: base.to_string(),
        device: device.to_string(),
        by: by.peer_id(),
        sig: sign(by, &vouch_payload(master, base, device)),
    }
}

pub(crate) fn sign_pending(master: &NativeKeypair, base: &str, device: &str) -> Pending {
    Pending {
        base: base.to_string(),
        device: device.to_string(),
        sig_m: sign(master, &pending_payload(&master.peer_id(), base, device)),
    }
}

pub(crate) fn sign_legacy(master: &NativeKeypair, device: &str) -> LegacyClaim {
    LegacyClaim {
        device: device.to_string(),
        sig_m: sign(master, &legacy_payload(&master.peer_id(), device)),
    }
}

pub(crate) fn sign_removal(
    by: &NativeKeypair,
    master: &str,
    base: &str,
    device: &str,
    keep_vouched: &[String],
) -> Removal {
    Removal {
        base: base.to_string(),
        device: device.to_string(),
        by: by.peer_id(),
        keep_vouched: sorted(keep_vouched),
        sig: sign(by, &removal_payload(master, base, device, keep_vouched)),
    }
}

/// Whether `r` verifies alone for `master`: well formed and signed by `r.by`. Standing
/// is judged where removals are compacted and folded, never here.
pub(crate) fn removal_verifies(master: &str, r: &Removal) -> bool {
    let id_ok = |d: &str| key_of(d).is_some();
    let keep = sorted(&r.keep_vouched);
    is_base_shape(&r.base)
        && id_ok(&r.device)
        && keep == r.keep_vouched
        && keep.len() <= MAX_REMOVAL_KEEP
        && keep.iter().all(|d| id_ok(d))
        && verify_by(&r.by, &removal_payload(master, &r.base, &r.device, &keep), &r.sig)
}

/// Whether `rm` fits what one DM may carry: the ONE test sender and receiver share.
pub(crate) fn carried_fits(rm: &[Removal]) -> bool {
    rm.len() <= MAX_CARRIED_REMOVALS
        && serde_json::to_vec(rm).is_ok_and(|b| b.len() <= MAX_CARRIED_REMOVAL_BYTES)
}

// -- The roster --

/// `seed` and every device a member of the result vouched for, removals ignored.
fn vouch_closure(mut seed: BTreeSet<String>, vouches: &[&Vouch]) -> BTreeSet<String> {
    loop {
        let before = seed.len();
        for v in vouches {
            if seed.contains(&v.by) {
                seed.insert(v.device.clone());
            }
        }
        if seed.len() == before {
            return seed;
        }
    }
}

/// What counted removals void: a removed voucher's vouches count only for the vouchees
/// EVERY counted removal of it keeps (HOL-SEC-080).
#[derive(Default)]
struct Voids {
    kept_by: BTreeMap<String, BTreeSet<String>>,
}

impl Voids {
    fn of<'a>(counted: impl IntoIterator<Item = &'a Removal>) -> Self {
        let mut kept_by: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
        for r in counted {
            let keep: BTreeSet<String> = r.keep_vouched.iter().cloned().collect();
            kept_by
                .entry(r.device.clone())
                .and_modify(|k| k.retain(|d| keep.contains(d)))
                .or_insert(keep);
        }
        Voids { kept_by }
    }

    fn allows(&self, v: &Vouch) -> bool {
        self.kept_by.get(&v.by).is_none_or(|k| k.contains(&v.device))
    }
}

/// Rank by (tier, depth, id) over `edges` (voucher, vouchee): tier 0 grows from the
/// first seed set, tier 1 from the second among what tier 0 did not reach.
fn rank_over<'a>(seeds: [BTreeSet<&'a str>; 2], edges: impl Iterator<Item = (&'a str, &'a str)>) -> BTreeMap<String, Rank> {
    let mut vouchees: BTreeMap<&str, BTreeSet<&str>> = BTreeMap::new();
    for (by, device) in edges {
        vouchees.entry(by).or_default().insert(device);
    }
    let mut rank: BTreeMap<&str, (u8, u32)> = BTreeMap::new();
    for (tier, seed) in (0u8..).zip(seeds) {
        let mut frontier: BTreeSet<&str> = seed.into_iter().filter(|d| !rank.contains_key(d)).collect();
        let mut depth = 0u32;
        while !frontier.is_empty() {
            for d in &frontier {
                rank.insert(*d, (tier, depth));
            }
            let next: BTreeSet<&str> = frontier
                .iter()
                .filter_map(|by| vouchees.get(by))
                .flatten()
                .copied()
                .filter(|d| !rank.contains_key(d))
                .collect();
            frontier = next;
            depth += 1;
        }
    }
    rank.into_iter().map(|(d, (tier, depth))| (d.to_string(), (tier, depth, d.to_string()))).collect()
}

/// What the removal walk counted, and its support: for each alive signer, the vouches
/// of the path that made it valid at its turn.
struct Walk<'a> {
    counted: Vec<&'a Removal>,
    support: BTreeSet<Vouch>,
}

impl<'a> Walk<'a> {
    /// Per removed device, the counted removal that removed it first.
    fn first(&self) -> BTreeMap<&'a str, &'a Removal> {
        let mut first = BTreeMap::new();
        for r in &self.counted {
            first.entry(r.device.as_str()).or_insert(*r);
        }
        first
    }
}

/// The removal walk (DEVICE_PROOF_DESIGN section 4): signers in rank order, and a
/// signer is alive at its turn unless a removal counted for an earlier signer removed
/// it, or it is outside its tier's valid closure as it stands then (a tier-0 signer's
/// grows from `roots` alone). Every removal by an alive signer of a device `target_ok`
/// takes counts, its own included. Ranks never tie, so the result is the same everywhere.
fn removal_walk<'a>(
    removals: &[&'a Removal],
    rank: &BTreeMap<String, Rank>,
    target_ok: &dyn Fn(&str) -> bool,
    roots: &BTreeSet<String>,
    pending: &BTreeSet<String>,
    vouches: &[&Vouch],
) -> Walk<'a> {
    let mut cands: Vec<(&Rank, &'a Removal)> = removals
        .iter()
        .filter(|r| target_ok(&r.device))
        .filter_map(|r| rank.get(&r.by).map(|k| (k, *r)))
        .collect();
    cands.sort();
    cands.dedup();
    let seeds = [roots.clone(), roots.union(pending).cloned().collect::<BTreeSet<String>>()];
    let mut walk = Walk { counted: Vec::new(), support: BTreeSet::new() };
    let mut closure: Option<(usize, u8, BTreeMap<String, Option<Vouch>>)> = None;
    let mut i = 0;
    while i < cands.len() {
        let (signer_rank, first) = cands[i];
        let by = first.by.as_str();
        let j = i + cands[i..].iter().take_while(|(_, r)| r.by == by).count();
        let tier = signer_rank.0.min(1);
        let removed_earlier = walk.counted.iter().any(|r| r.device == by && r.by != by);
        let n = walk.counted.len();
        if closure.as_ref().is_none_or(|(m, t, _)| *m != n || *t != tier) {
            let voids = Voids::of(walk.counted.iter().copied());
            closure = Some((n, tier, valid_closure(&seeds[tier as usize], vouches, &voids)));
        }
        let parents = closure.as_ref().map(|(_, _, p)| p);
        if !removed_earlier && parents.is_some_and(|p| p.contains_key(by)) {
            let mut at = by;
            while let Some(Some(v)) = parents.and_then(|p| p.get(at)) {
                walk.support.insert(v.clone());
                at = v.by.as_str();
            }
            walk.counted.extend(cands[i..j].iter().map(|(_, r)| *r));
        }
        i = j;
    }
    walk
}

/// `seed` and every device a member of the result vouched for where `voids` allows it,
/// each mapped to the vouch that reached it first in a breadth-first pass (seeds: None).
fn valid_closure(seed: &BTreeSet<String>, vouches: &[&Vouch], voids: &Voids) -> BTreeMap<String, Option<Vouch>> {
    let mut next: BTreeMap<&str, Vec<&Vouch>> = BTreeMap::new();
    for v in vouches.iter().filter(|v| voids.allows(v)) {
        next.entry(v.by.as_str()).or_default().push(v);
    }
    for list in next.values_mut() {
        list.sort();
    }
    let mut reached: BTreeMap<String, Option<Vouch>> = seed.iter().map(|d| (d.clone(), None)).collect();
    let mut queue: std::collections::VecDeque<String> = seed.iter().cloned().collect();
    while let Some(d) = queue.pop_front() {
        for v in next.get(d.as_str()).into_iter().flatten() {
            if !reached.contains_key(&v.device) {
                reached.insert(v.device.clone(), Some((*v).clone()));
                queue.push_back(v.device.clone());
            }
        }
    }
    reached
}

/// What the ceilings keep first, from the walk over every held statement. A vouch is
/// VALID when its signer is in the valid closure the walk leaves and no counted removal
/// of the signer voids it (HOL-SEC-189); `valid_rank` ranks the valid devices through
/// valid vouches only; `support` holds what the walk needs to come out the same once
/// compacted (RC32-10); `reserved` is each removed device's first counted removal (N1).
struct CapJudge {
    valid_rank: BTreeMap<String, Rank>,
    voids: Voids,
    support: BTreeSet<Vouch>,
    reserved: Vec<Removal>,
}

impl CapJudge {
    fn counts(&self, v: &Vouch) -> bool {
        self.valid_rank.contains_key(&v.by) && self.voids.allows(v)
    }
}

/// Each standing device's first vouch by (`key` of its signer, the vouch).
fn first_per_device<'v>(
    mut order: Vec<&'v Vouch>,
    standing: &BTreeMap<String, Rank>,
    key: impl Fn(&Vouch) -> Option<Rank>,
) -> BTreeSet<&'v Vouch> {
    order.sort_by_cached_key(|v| (key(v), (*v).clone()));
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    order
        .into_iter()
        .filter(|v| standing.contains_key(&v.device) && seen.insert(v.device.as_str()))
        .collect()
}

fn push_unique<T: Ord + Clone>(into: &mut Vec<T>, from: &[T]) {
    into.extend_from_slice(from);
    into.sort();
    into.dedup();
}

fn sort_cap<T: Ord>(v: &mut Vec<T>, cap: usize) {
    v.sort();
    v.dedup();
    v.truncate(cap);
}

/// A standing device's place: tier, depth, then its id.
type Rank = (u8, u32, String);

struct Current {
    base: String,
    at: i64,
    keep: BTreeSet<String>,
    no_wait: bool,
}

struct Scope<'a> {
    base: String,
    no_wait: bool,
    roots: BTreeSet<String>,
    matured: BTreeSet<String>,
    vouches: Vec<&'a Vouch>,
    pendings: Vec<&'a Pending>,
    rooted: BTreeSet<String>,
}

impl Roster {
    pub(crate) fn new(master: &str) -> Self {
        Roster { master: master.to_string(), ..Default::default() }
    }

    /// A brand-new identity: this device's consent and a recovery keeping only it.
    pub(crate) fn genesis(
        master: &NativeKeypair,
        recovery: &NativeKeypair,
        device: &NativeKeypair,
        now_ms: i64,
    ) -> Self {
        let mut r = Roster::new(&master.peer_id());
        r.r_pub = r_pub_of(recovery);
        r.consents.push(sign_consent(device, &r.master));
        r.recoveries.push(sign_recovery(master, recovery, now_ms, &[device.peer_id()], false));
        r
    }

    fn master_key(&self) -> Option<[u8; 32]> {
        key_of(&self.master)
    }

    fn r_key(&self) -> Option<[u8; 32]> {
        let bytes = B64.decode(&self.r_pub).ok()?;
        <[u8; 32]>::try_from(bytes.as_slice()).ok()
    }

    /// Only the statements that verify for this master, as they arrive. Phrase
    /// statements verify against `r_pub`, which is cleared when none does; anything
    /// dated more than the skew past `now_ms` is dropped.
    pub(crate) fn verified(&self, now_ms: i64) -> Roster {
        self.checked(Some(now_ms))
    }

    /// A roster this node already holds, checked again. Its times were judged when
    /// each statement arrived, so a clock that has stepped back since drops nothing,
    /// and its pinned recovery key stays.
    pub(crate) fn reverified(&self) -> Roster {
        self.checked(None)
    }

    fn checked(&self, now_ms: Option<i64>) -> Roster {
        let Some(mk) = self.master_key() else { return Roster::default() };
        let m = self.master.as_str();
        let mut out = Roster::new(m);
        let fresh = |at: i64| now_ms.is_none_or(|now| at <= now.saturating_add(MAX_FUTURE_SKEW_MS));
        let id_ok = |d: &str| key_of(d).is_some();

        if let Some(rk) = self.r_key() {
            let r_pub = self.r_pub.as_str();
            out.recoveries = self
                .recoveries
                .iter()
                .filter(|rec| {
                    let keep = sorted(&rec.keep);
                    fresh(rec.at_ms)
                        && keep == rec.keep
                        && !keep.is_empty()
                        && keep.len() <= MAX_KEEP
                        && keep.iter().all(|d| id_ok(d))
                        && {
                            let p = recovery_payload(m, r_pub, rec.at_ms, &keep, rec.no_wait);
                            verify(&rk, &p, &rec.sig_r) && verify(&mk, &p, &rec.sig_m)
                        }
                })
                .cloned()
                .collect();
            out.phrase_admits = self
                .phrase_admits
                .iter()
                .filter(|pa| {
                    fresh(pa.at_ms) && id_ok(&pa.device) && {
                        let p = phrase_admit_payload(m, r_pub, pa.at_ms, &pa.device);
                        verify(&rk, &p, &pa.sig_r) && verify(&mk, &p, &pa.sig_m)
                    }
                })
                .cloned()
                .collect();
            if !out.recoveries.is_empty() || !out.phrase_admits.is_empty() {
                out.r_pub = self.r_pub.clone();
            }
        }
        if now_ms.is_none() {
            out.r_pub = self.r_pub.clone();
        }
        out.consents = self
            .consents
            .iter()
            .filter(|c| verify_by(&c.device, &consent_payload(m, &c.device), &c.sig))
            .cloned()
            .collect();
        out.vouches = self
            .vouches
            .iter()
            .filter(|v| {
                is_base_shape(&v.base)
                    && id_ok(&v.device)
                    && v.device != v.by
                    && verify_by(&v.by, &vouch_payload(m, &v.base, &v.device), &v.sig)
            })
            .cloned()
            .collect();
        out.pendings = self
            .pendings
            .iter()
            .filter(|p| {
                is_base_shape(&p.base)
                    && id_ok(&p.device)
                    && verify(&mk, &pending_payload(m, &p.base, &p.device), &p.sig_m)
            })
            .cloned()
            .collect();
        out.legacy = self
            .legacy
            .iter()
            .filter(|l| id_ok(&l.device) && verify(&mk, &legacy_payload(m, &l.device), &l.sig_m))
            .cloned()
            .collect();
        out.removals = self.removals.iter().filter(|r| removal_verifies(m, r)).cloned().collect();
        out.compacted()
    }

    /// Fold `incoming` (verified) into `self` (verified). Our recovery key is pinned:
    /// phrase statements under any other key are dropped, and the first key we ever
    /// see for this master is the one we keep.
    pub(crate) fn merged(&self, incoming: &Roster) -> Roster {
        if !self.master.is_empty() && incoming.master != self.master {
            return self.clone();
        }
        let mut out = self.clone();
        out.master = incoming.master.clone();
        let same_key = out.r_pub.is_empty() || out.r_pub == incoming.r_pub;
        if same_key && !incoming.r_pub.is_empty() {
            out.r_pub = incoming.r_pub.clone();
            push_unique(&mut out.recoveries, &incoming.recoveries);
            push_unique(&mut out.phrase_admits, &incoming.phrase_admits);
        }
        push_unique(&mut out.consents, &incoming.consents);
        push_unique(&mut out.vouches, &incoming.vouches);
        push_unique(&mut out.pendings, &incoming.pendings);
        push_unique(&mut out.legacy, &incoming.legacy);
        push_unique(&mut out.removals, &incoming.removals);
        out.compacted()
    }

    /// [`Self::merged`] for a holder that keeps a clock of pending joins. Past their
    /// ceiling, asks give way by when this holder first saw them, `first_seen(base,
    /// device)`, an unseen one after every seen one: anyone holding the master key can
    /// sign asks under ids it picks, so a later flood must push out no earlier ask. Per
    /// holder by design: the fold stays the same everywhere, only what each holder keeps
    /// of a flood differs. The relay mirrors it (`roster.h`, `RosterBook::show`).
    pub(crate) fn merged_by_first_sight(&self, incoming: &Roster, first_seen: impl Fn(&str, &str) -> Option<i64>) -> Roster {
        let merged = self.merged(incoming);
        if !self.master.is_empty() && incoming.master != self.master {
            return merged;
        }
        let base = merged.base();
        let mut asks: Vec<&Pending> = self.pendings.iter().chain(&incoming.pendings).filter(|p| p.base == base).collect();
        asks.sort();
        asks.dedup();
        if asks.len() <= MAX_PENDING {
            return merged;
        }
        asks.sort_by_cached_key(|p| (first_seen(&p.base, &p.device).unwrap_or(i64::MAX), (*p).clone()));
        let kept: BTreeSet<&Pending> = asks.into_iter().take(MAX_PENDING).collect();
        let trim = |r: &Roster| {
            let mut r = r.clone();
            r.pendings.retain(|p| p.base != base || kept.contains(p));
            r
        };
        trim(self).merged(&trim(incoming))
    }

    /// The newest recovery: its base id (ties: the lowest), its time, the union of the
    /// keep sets that share it, and whether any of them turned off joining by waiting.
    fn current_recovery(&self) -> Option<Current> {
        let at = self.recoveries.iter().map(|r| r.at_ms).max()?;
        let ties: Vec<&Recovery> = self.recoveries.iter().filter(|r| r.at_ms == at).collect();
        let base = ties.iter().map(|r| base_id(&self.master, &self.r_pub, r)).min()?;
        let keep = ties.iter().flat_map(|r| r.keep.iter().cloned()).collect();
        let no_wait = ties.iter().any(|r| r.no_wait);
        Some(Current { base, at, keep, no_wait })
    }

    /// Whether every kind fits its ceiling, as any compacted roster does. The relay
    /// verifies nothing from a roster that does not.
    pub(crate) fn within_caps(&self) -> bool {
        self.recoveries.len() <= MAX_RECOVERY_TIES
            && self.phrase_admits.len() <= MAX_PHRASE_ADMITS
            && self.consents.len() <= MAX_CONSENTS
            && self.vouches.len() <= MAX_VOUCHES
            && self.pendings.len() <= MAX_PENDING
            && self.legacy.len() <= MAX_LEGACY
            && self.removals.len() <= MAX_REMOVALS + MAX_RESERVED
    }

    /// The devices the upgrade's phrase admitted, while the current base is still the
    /// upgrade's: a recovery typed later admits by its own statements.
    pub(crate) fn upgrade_admitted(&self) -> BTreeSet<String> {
        match self.current_recovery() {
            Some(c) if c.at == UPGRADE_RECOVERY_AT_MS => self
                .phrase_admits
                .iter()
                .filter(|p| p.at_ms == UPGRADE_RECOVERY_AT_MS + 1)
                .map(|p| p.device.clone())
                .collect(),
            _ => BTreeSet::new(),
        }
    }

    /// The base every new device statement must name.
    pub(crate) fn base(&self) -> String {
        self.current_recovery()
            .map(|c| c.base)
            .unwrap_or_else(|| LEGACY_BASE.to_string())
    }

    /// The current base, and the devices the phrase (or, in a legacy base, the master)
    /// roots in it, consent not yet checked.
    fn base_roots(&self) -> (Option<Current>, BTreeSet<String>) {
        match self.current_recovery() {
            Some(c) => {
                let mut roots = c.keep.clone();
                roots.extend(self.phrase_admits.iter().filter(|p| p.at_ms > c.at).map(|p| p.device.clone()));
                (Some(c), roots)
            }
            None => {
                let mut roots: BTreeSet<String> = self.legacy.iter().map(|l| l.device.clone()).collect();
                roots.extend(self.phrase_admits.iter().map(|p| p.device.clone()));
                (None, roots)
            }
        }
    }

    /// Every device with an admission path in the current base, removals ignored and
    /// every pending join counted, ranked by (tier, depth, id): tier 0 grows from the
    /// roots, tier 1 from pending joins, depth counts vouches from a root. A device
    /// always ranks below its best voucher.
    fn standing(&self) -> BTreeMap<String, Rank> {
        self.ranked(true)
    }

    /// [`Self::standing`] over the consents the cap keeps: past `MAX_CONSENTS` standing
    /// devices only the best ranked keep theirs, and the rest rank again without the
    /// others, so a merge of two shows judges what its compacted self judges.
    fn capped_standing(&self) -> BTreeMap<String, Rank> {
        let all = self.standing();
        if all.len() <= MAX_CONSENTS {
            return all;
        }
        let mut best: Vec<(&Rank, &String)> = all.iter().map(|(d, k)| (k, d)).collect();
        best.sort();
        let kept: BTreeSet<&str> = best.into_iter().take(MAX_CONSENTS).map(|(_, d)| d.as_str()).collect();
        let mut view = self.clone();
        view.consents.retain(|c| kept.contains(c.device.as_str()) || !all.contains_key(&c.device));
        view.standing()
    }

    /// [`Self::standing`]; without `with_pending`, nothing a pending join seeds ranks.
    fn ranked(&self, with_pending: bool) -> BTreeMap<String, Rank> {
        let consented: BTreeSet<&str> = self.consents.iter().map(|c| c.device.as_str()).collect();
        let (_, roots) = self.base_roots();
        let seeds = [
            roots.iter().map(String::as_str).filter(|d| consented.contains(d)).collect(),
            self.pendings.iter().map(|p| p.device.as_str()).filter(|d| with_pending && consented.contains(d)).collect(),
        ];
        let edges = self
            .vouches
            .iter()
            .filter(|v| consented.contains(v.device.as_str()))
            .map(|v| (v.by.as_str(), v.device.as_str()));
        rank_over(seeds, edges)
    }

    /// [`Self::authority`], and how each valid device was reached from a root.
    fn authority_with_paths(&self) -> (Authority, BTreeMap<String, Option<Vouch>>) {
        let parts = self.authority_parts();
        (parts.auth, parts.paths)
    }

    fn authority_parts(&self) -> AuthorityParts<'_> {
        let consented: BTreeSet<&str> = self.consents.iter().map(|c| c.device.as_str()).collect();
        let (current, roots) = self.base_roots();
        let base = current.map_or_else(|| LEGACY_BASE.to_string(), |c| c.base);
        let roots: BTreeSet<String> = roots.into_iter().filter(|d| consented.contains(d.as_str())).collect();
        let asked: BTreeSet<&str> = self
            .pendings
            .iter()
            .filter(|p| p.base == base && consented.contains(p.device.as_str()))
            .map(|p| p.device.as_str())
            .collect();
        let vouches: Vec<&Vouch> = self
            .vouches
            .iter()
            .filter(|v| v.base == base && consented.contains(v.device.as_str()))
            .collect();
        let founded = self.ranked(false);
        let removals: Vec<&Removal> = self.removals.iter().filter(|r| r.base == base).collect();
        let target_ok = |t: &str| founded.contains_key(t) || asked.contains(t);
        let walk = removal_walk(&removals, &founded, &target_ok, &roots, &BTreeSet::new(), &vouches);
        let removed: BTreeMap<String, String> =
            walk.first().into_iter().map(|(d, r)| (d.to_string(), r.by.clone())).collect();
        let mut counted_removals: Vec<Removal> = walk.counted.iter().map(|r| (*r).clone()).collect();
        counted_removals.sort();
        let voids = Voids::of(walk.counted);
        let paths = valid_closure(&roots, &vouches, &voids);
        let counted = paths.keys().filter(|d| !removed.contains_key(*d)).cloned().collect();
        let auth = Authority { key: self.r_pub.clone(), base, counted, removed, counted_removals, digest: self.digest() };
        AuthorityParts { auth, paths, roots, vouches, voids }
    }

    /// Counted devices that only `dropped` place (R31-3): outside the valid closure grown
    /// from the other roots through every other device's vouches. A device the dropped
    /// ones vouched that another device also holds is not one of them.
    pub(crate) fn dependents_of(&self, dropped: &BTreeSet<String>) -> BTreeSet<String> {
        let parts = self.authority_parts();
        let roots: BTreeSet<String> = parts.roots.difference(dropped).cloned().collect();
        let vouches: Vec<&Vouch> = parts.vouches.iter().copied().filter(|v| !dropped.contains(&v.by)).collect();
        let still = valid_closure(&roots, &vouches, &parts.voids);
        parts.auth.counted.into_iter().filter(|d| !still.contains_key(d) && !dropped.contains(d)).collect()
    }

    /// Server authority's verdict over these statements, which must be `reverified`.
    /// Signers are the devices the roots vouch, removals ignored (tier 0); the removal
    /// walk decides which removals count, so a mutual removal goes to the device closer
    /// to the phrase, never to both as in [`Self::fold`]. Pending joins never count, but
    /// a removal of one does.
    pub(crate) fn authority(&self) -> Authority {
        self.authority_with_paths().0
    }

    /// [`Self::authority`]'s counted devices, closest to the phrase first: a device a
    /// thief vouched ranks below the device that vouched the thief.
    pub(crate) fn counted_by_rank(&self) -> Vec<String> {
        let rank = self.ranked(false);
        let mut counted: Vec<String> = self.authority().counted.into_iter().collect();
        counted.sort_by_key(|d| (!rank.contains_key(d), rank.get(d).cloned(), d.clone()));
        counted
    }

    /// The statements that make `device` counted under [`Self::authority`], when it is:
    /// the current recovery, the root's own admission, and the vouch chain from that root
    /// with the consents along it. Each verifies alone; it rides a join ask (R31-7),
    /// where a member judges it merged with what it holds, so a removal it omits still
    /// counts there.
    #[allow(dead_code)] // the join box's asker roster, built by track C (section 8.7)
    pub(crate) fn placing_subset(&self, device: &str) -> Option<Roster> {
        let (auth, paths) = self.authority_with_paths();
        if !auth.counts(device) {
            return None;
        }
        let mut chain: Vec<&Vouch> = Vec::new();
        let mut at = device;
        while let Some(Some(v)) = paths.get(at) {
            chain.push(v);
            at = v.by.as_str();
        }
        let on_chain: BTreeSet<&str> = chain.iter().map(|v| v.device.as_str()).chain([at]).collect();
        let mut out = Roster::new(&self.master);
        out.r_pub = self.r_pub.clone();
        out.recoveries = self.recoveries.clone();
        out.phrase_admits = self.phrase_admits.iter().filter(|p| p.device == at).cloned().collect();
        out.legacy = self.legacy.iter().filter(|l| l.device == at).cloned().collect();
        out.consents = self.consents.iter().filter(|c| on_chain.contains(c.device.as_str())).cloned().collect();
        out.vouches = chain.into_iter().cloned().collect();
        out.vouches.sort();
        Some(out)
    }

    /// The ceilings' judge over every held statement of the current base: the walk over
    /// removals of standing targets (tier-0 signers for the vouches, every standing
    /// signer for the reserved slots), then the valid closure of the roots plus the
    /// consented pending joins, so nothing standing is judged from a narrower seed than
    /// its own tier.
    fn cap_judge(&self, standing: &BTreeMap<String, Rank>) -> CapJudge {
        let consented: BTreeSet<&str> = self.consents.iter().map(|c| c.device.as_str()).collect();
        let (current, roots) = self.base_roots();
        let base = current.map_or_else(|| LEGACY_BASE.to_string(), |c| c.base);
        let roots: BTreeSet<String> = roots.into_iter().filter(|d| consented.contains(d.as_str())).collect();
        let pending: BTreeSet<String> = self
            .pendings
            .iter()
            .filter(|p| p.base == base && consented.contains(p.device.as_str()))
            .map(|p| p.device.clone())
            .collect();
        let vouches: Vec<&Vouch> = self
            .vouches
            .iter()
            .filter(|v| v.base == base && consented.contains(v.device.as_str()))
            .collect();
        let removals: Vec<&Removal> = self.removals.iter().filter(|r| r.base == base).collect();
        let target_ok = |t: &str| standing.contains_key(t);
        // Every standing signer may hold a reserved slot, which only keeps more; only the
        // removals every view counts (tier-0 signers) void a vouch, since a pending join
        // may be one the master key alone made.
        let wide = removal_walk(&removals, standing, &target_ok, &roots, &pending, &vouches);
        let reserved = wide.first().into_values().cloned().collect();
        let tier0: Vec<&Removal> =
            removals.iter().copied().filter(|r| standing.get(&r.by).is_some_and(|k| k.0 == 0)).collect();
        let walk = removal_walk(&tier0, standing, &target_ok, &roots, &pending, &vouches);
        let mut support = walk.support;
        support.extend(wide.support);
        let voids = Voids::of(walk.counted);
        let seeds = [
            roots.iter().map(String::as_str).collect(),
            pending.iter().map(String::as_str).collect(),
        ];
        let edges = vouches.iter().filter(|v| voids.allows(v)).map(|v| (v.by.as_str(), v.device.as_str()));
        let valid_rank = rank_over(seeds, edges);
        CapJudge { valid_rank, voids, support, reserved }
    }

    /// Everything superseded by the current base dropped, statements sorted, and the
    /// ceilings applied. A vouch or removal stays only when its signer stands, ordered
    /// by its signer's rank, whatever it names: a vouch may precede its device's
    /// consent, and a removal may precede the device's claim. A vouch the removal walk
    /// leaves valid outranks every other (HOL-SEC-189), and each standing device's tree
    /// vouch stays first, so compacting a compacted roster keeps the same statements.
    fn compacted(mut self) -> Roster {
        if let Some(at) = self.recoveries.iter().map(|r| r.at_ms).max() {
            self.recoveries.retain(|r| r.at_ms == at);
        }
        sort_cap(&mut self.recoveries, MAX_RECOVERY_TIES);
        match self.current_recovery() {
            Some(c) => {
                self.phrase_admits.retain(|p| p.at_ms > c.at);
                self.legacy.clear();
                self.vouches.retain(|v| v.base == c.base);
                self.pendings.retain(|p| p.base == c.base);
                self.removals.retain(|r| r.base == c.base);
            }
            None => {
                self.vouches.retain(|v| v.base == LEGACY_BASE);
                self.pendings.retain(|p| p.base == LEGACY_BASE);
                self.removals.retain(|r| r.base == LEGACY_BASE);
            }
        }
        sort_cap(&mut self.phrase_admits, MAX_PHRASE_ADMITS);
        sort_cap(&mut self.legacy, MAX_LEGACY);
        sort_cap(&mut self.pendings, MAX_PENDING);
        self.consents.sort();
        self.consents.dedup_by(|a, b| a.device == b.device);

        let standing = self.capped_standing();
        let rank = |d: &str| standing.get(d).cloned();
        let judge = self.cap_judge(&standing);
        let ok = |v: &Vouch| judge.counts(v);

        let mut vouches: Vec<Vouch> = std::mem::take(&mut self.vouches)
            .into_iter()
            .filter(|v| standing.contains_key(&v.by))
            .collect();
        vouches.sort();
        vouches.dedup();
        // Kept first, so a compacted roster folds, ranks and walks as the whole set did:
        // each standing device's vouch from its nearest VALID voucher (a tree rooted in
        // the phrase, HOL-SEC-189), the walk's support, and each standing device's vouch
        // from its best-ranked voucher. The rest give way by validity, then signer rank.
        let valid_tree = first_per_device(vouches.iter().filter(|v| ok(v)).collect(), &standing, |v| judge.valid_rank.get(&v.by).cloned());
        let rank_tree = first_per_device(vouches.iter().collect(), &standing, |v| rank(&v.by));
        let class = |v: &Vouch| {
            if valid_tree.contains(v) {
                0u8
            } else if judge.support.contains(v) {
                1
            } else if rank_tree.contains(v) {
                2
            } else {
                3
            }
        };
        let mut order: Vec<&Vouch> = vouches.iter().collect();
        order.sort_by_cached_key(|v| (class(v), !ok(v), rank(&v.by), (*v).clone()));
        let mut kept: Vec<Vouch> = order.into_iter().take(MAX_VOUCHES).cloned().collect();
        kept.sort();
        self.vouches = kept;

        let mut removals: Vec<Removal> = std::mem::take(&mut self.removals)
            .into_iter()
            .filter(|r| standing.contains_key(&r.by))
            .collect();
        removals.sort();
        removals.dedup();
        let mut reserved: Vec<Removal> = judge.reserved.clone();
        reserved.sort_by_cached_key(|r| (rank(&r.device), r.clone()));
        reserved.truncate(MAX_RESERVED);
        let held: BTreeSet<&Removal> = reserved.iter().collect();
        let mut general: Vec<Removal> = removals.into_iter().filter(|r| !held.contains(r)).collect();
        general.sort_by_cached_key(|r| (rank(&r.by), r.clone()));
        general.truncate(MAX_REMOVALS);
        let mut removals: Vec<Removal> = reserved.iter().cloned().chain(general).collect();
        removals.sort();
        self.removals = removals;

        // Standing devices first by rank, then devices a statement names, then a few
        // that nothing names yet (a consent can arrive ahead of its statement, and
        // anyone can mint one).
        let mentioned: BTreeSet<&str> = self
            .recoveries
            .iter()
            .flat_map(|r| r.keep.iter().map(String::as_str))
            .chain(self.phrase_admits.iter().map(|p| p.device.as_str()))
            .chain(self.pendings.iter().map(|p| p.device.as_str()))
            .chain(self.legacy.iter().map(|l| l.device.as_str()))
            .chain(self.vouches.iter().map(|v| v.device.as_str()))
            .chain(self.removals.iter().map(|r| r.device.as_str()))
            .collect();
        let class = |c: &Consent| match rank(&c.device) {
            Some(r) => (0u8, Some(r)),
            None if mentioned.contains(c.device.as_str()) => (1, None),
            None => (2, None),
        };
        let mut consents = std::mem::take(&mut self.consents);
        consents.sort_by_cached_key(|c| (class(c), c.clone()));
        let mut unnamed = 0;
        consents.retain(|c| {
            if class(c).0 < 2 {
                return true;
            }
            unnamed += 1;
            unnamed <= MAX_UNNAMED_CONSENTS
        });
        consents.truncate(MAX_CONSENTS);
        consents.sort();
        self.consents = consents;
        self
    }

    /// Who belongs to this identity now, for one observer. `first_seen` is when this
    /// observer first saw a device's pending join, the clock its seven days run on.
    /// The roster must already be `verified`.
    pub(crate) fn fold(&self, first_seen: impl Fn(&str) -> Option<i64>, now_ms: i64) -> RosterState {
        let scope = self.scope(&first_seen, now_ms);
        let asked: BTreeSet<&str> = scope.pendings.iter().map(|p| p.device.as_str()).collect();

        // A removed device keeps only the vouchees EVERY removal of it keeps: a device
        // it vouched cannot keep itself by removing it too.
        let mut removed: BTreeMap<String, String> = BTreeMap::new();
        let mut kept_by: BTreeMap<&str, BTreeSet<&str>> = BTreeMap::new();
        for r in self.counting_removals_in(&scope) {
            removed.entry(r.device.clone()).or_insert_with(|| r.by.clone());
            let keep: BTreeSet<&str> = r.keep_vouched.iter().map(String::as_str).collect();
            kept_by
                .entry(r.device.as_str())
                .and_modify(|k| k.retain(|d| keep.contains(d)))
                .or_insert(keep);
        }

        // A removed voucher's vouches count only where its removers kept them.
        let mut valid: BTreeSet<String> = scope.roots.union(&scope.matured).cloned().collect();
        loop {
            let before = valid.len();
            for v in &scope.vouches {
                if !valid.contains(&v.by) {
                    continue;
                }
                let voucher_ok = !removed.contains_key(&v.by)
                    || kept_by
                        .get(v.by.as_str())
                        .is_some_and(|k| k.contains(v.device.as_str()));
                if voucher_ok {
                    valid.insert(v.device.clone());
                }
            }
            if valid.len() == before {
                break;
            }
        }

        let members: BTreeSet<String> =
            valid.iter().filter(|d| !removed.contains_key(*d)).cloned().collect();
        let pending: BTreeSet<String> = asked
            .iter()
            .filter(|d| !valid.contains(**d) && !removed.contains_key(**d))
            .map(|d| d.to_string())
            .collect();
        let protected = self.current_recovery().is_some();
        RosterState { base: scope.base.clone(), protected, no_wait: scope.no_wait, members, removed, pending }
    }

    /// What one fold works from: the current base, its roots and matured joins, the
    /// vouches and joins it reads, and who may sign a removal.
    fn scope<'a>(&'a self, first_seen: &impl Fn(&str) -> Option<i64>, now_ms: i64) -> Scope<'a> {
        let consented: BTreeSet<&str> = self.consents.iter().map(|c| c.device.as_str()).collect();
        let (current, mut roots) = self.base_roots();
        let base = current.as_ref().map_or_else(|| LEGACY_BASE.to_string(), |c| c.base.clone());
        let no_wait = current.as_ref().is_some_and(|c| c.no_wait);
        roots.retain(|d| consented.contains(d.as_str()));

        let vouches: Vec<&Vouch> = self
            .vouches
            .iter()
            .filter(|v| v.base == base && consented.contains(v.device.as_str()))
            .collect();
        let pendings: Vec<&Pending> = self
            .pendings
            .iter()
            .filter(|p| p.base == base && consented.contains(p.device.as_str()))
            .collect();
        // A join refused by a device that belongs without anyone waiting never matures:
        // waiting must not hand its removals to whoever holds the master key.
        let founded = vouch_closure(roots.clone(), &vouches);
        let refused: BTreeSet<&str> = self
            .removals
            .iter()
            .filter(|r| r.base == base && founded.contains(&r.by))
            .map(|r| r.device.as_str())
            .collect();
        let matured: BTreeSet<String> = pendings
            .iter()
            .filter(|p| {
                !no_wait
                    && !refused.contains(p.device.as_str())
                    && first_seen(&p.device)
                        .is_some_and(|seen| seen.saturating_add(PENDING_MATURITY_MS) <= now_ms)
            })
            .map(|p| p.device.clone())
            .collect();

        // Everyone with any admission path, removals ignored: who may sign a removal.
        let rooted = vouch_closure(roots.union(&matured).cloned().collect(), &vouches);
        Scope { base, no_wait, roots, matured, vouches, pendings, rooted }
    }

    /// The removals that count in `scope`: in its base, signed by a rooted device, of a
    /// rooted device or one asking to join.
    fn counting_removals_in<'a>(&'a self, scope: &Scope<'_>) -> impl Iterator<Item = &'a Removal> {
        let asked: BTreeSet<String> = scope.pendings.iter().map(|p| p.device.clone()).collect();
        let (base, rooted) = (scope.base.clone(), scope.rooted.clone());
        self.removals.iter().filter(move |r| {
            r.base == base && rooted.contains(&r.by) && (rooted.contains(&r.device) || asked.contains(&r.device))
        })
    }

    /// The removals that count for this observer: what [`Self::fold`] reads, never a
    /// statement compaction keeps from a signer that stands only through a pending join.
    pub(crate) fn counting_removals(&self, first_seen: impl Fn(&str) -> Option<i64>, now_ms: i64) -> Vec<Removal> {
        self.counting_removals_in(&self.scope(&first_seen, now_ms)).cloned().collect()
    }

    /// Current members that `device` vouched for, the set an honest remover keeps.
    pub(crate) fn vouched_members_of(&self, device: &str, state: &RosterState) -> Vec<String> {
        let base = &state.base;
        self.vouches
            .iter()
            .filter(|v| &v.base == base && v.by == device && state.members.contains(&v.device))
            .map(|v| v.device.clone())
            .take(MAX_REMOVAL_KEEP)
            .collect()
    }

    /// What the removal walk leaves removed (device -> the vouchees every counted removal
    /// of it keeps), over the statements as held, compacted or not.
    #[cfg(test)]
    pub(crate) fn walk_view(&self) -> BTreeMap<String, BTreeSet<String>> {
        self.cap_judge(&self.capped_standing()).voids.kept_by
    }

    pub(crate) fn has_consent(&self, device: &str) -> bool {
        self.consents.iter().any(|c| c.device == device)
    }

    pub(crate) fn add_consent(&mut self, c: Consent) {
        push_unique(&mut self.consents, &[c]);
    }

    pub(crate) fn add_vouch(&mut self, v: Vouch) {
        push_unique(&mut self.vouches, &[v]);
    }

    pub(crate) fn add_pending(&mut self, p: Pending) {
        push_unique(&mut self.pendings, &[p]);
    }

    pub(crate) fn add_legacy(&mut self, l: LegacyClaim) {
        push_unique(&mut self.legacy, &[l]);
    }

    pub(crate) fn add_removal(&mut self, r: Removal) {
        push_unique(&mut self.removals, &[r]);
    }

    /// Add a phrase statement signed under `r_pub`. Refused under a key other than
    /// the pinned one.
    pub(crate) fn add_phrase_statement(
        &mut self,
        r_pub: &str,
        recovery: Option<Recovery>,
        admit: Option<PhraseAdmit>,
    ) -> Result<(), String> {
        if !self.r_pub.is_empty() && self.r_pub != r_pub {
            return Err("This identity already has a different recovery phrase.".into());
        }
        self.r_pub = r_pub.to_string();
        if let Some(r) = recovery {
            push_unique(&mut self.recoveries, &[r]);
        }
        if let Some(a) = admit {
            push_unique(&mut self.phrase_admits, &[a]);
        }
        let compact = std::mem::take(self).compacted();
        *self = compact;
        Ok(())
    }
}

/// The key under which a node records when it first saw a removal or a vouch (8.5):
/// its signature, which covers every field, under the statement's kind.
pub(crate) fn removal_seen_key(r: &Removal) -> String {
    seen_key("removal", &r.sig)
}

pub(crate) fn vouch_seen_key(v: &Vouch) -> String {
    seen_key("vouch", &v.sig)
}

/// The key under which a node records when a device first counted for our identity.
pub(crate) fn device_seen_key(device: &str) -> String {
    seen_key("device", device)
}

fn seen_key(kind: &str, sig: &str) -> String {
    let mut h = Sha256::new();
    h.update(kind.as_bytes());
    h.update(b":");
    h.update(sig.as_bytes());
    hex::encode(&h.finalize()[..16])
}

/// Length of a [`Roster::digest`] in hex characters.
pub(crate) const DIGEST_HEX_LEN: usize = 32;

impl Roster {
    /// A short fingerprint of what this roster says, the same for every holder of the
    /// same statements whatever order they arrived in. Pending joins are left out: each
    /// holder keeps its own few of a flood by first sight, so they would keep two holders
    /// apart forever, and a missed one costs reach, never a removal. So are the vouches
    /// and removals of a signer that stands only through a pending join, for the same
    /// reason, and a consent no other statement names, which anyone can mint.
    pub(crate) fn digest(&self) -> String {
        fn sorted_all<T: Ord + Clone>(v: &[T]) -> Vec<T> {
            let mut s = v.to_vec();
            s.sort();
            s.dedup();
            s
        }
        let rooted = self.ranked(false);
        let vouches: Vec<Vouch> = sorted_all(&self.vouches).into_iter().filter(|v| rooted.contains_key(&v.by)).collect();
        let removals: Vec<Removal> =
            sorted_all(&self.removals).into_iter().filter(|r| rooted.contains_key(&r.by)).collect();
        let named: BTreeSet<&str> = self
            .recoveries
            .iter()
            .flat_map(|r| r.keep.iter().map(String::as_str))
            .chain(self.phrase_admits.iter().map(|p| p.device.as_str()))
            .chain(vouches.iter().flat_map(|v| [v.device.as_str(), v.by.as_str()]))
            .chain(self.legacy.iter().map(|l| l.device.as_str()))
            .chain(removals.iter().flat_map(|r| [r.device.as_str(), r.by.as_str()]))
            .collect();
        let consents: Vec<Consent> =
            sorted_all(&self.consents).into_iter().filter(|c| named.contains(c.device.as_str())).collect();
        let canonical = serde_json::json!([
            "hollow-roster-digest1",
            self.master,
            self.r_pub,
            sorted_all(&self.recoveries),
            sorted_all(&self.phrase_admits),
            consents,
            vouches,
            sorted_all(&self.legacy),
            removals,
        ]);
        let hash = Sha256::digest(canonical.to_string().as_bytes());
        hex::encode(&hash[..DIGEST_HEX_LEN / 2])
    }
}

/// Whether `s` has the shape of a [`Roster::digest`].
pub(crate) fn is_digest_shape(s: &str) -> bool {
    s.len() == DIGEST_HEX_LEN && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[cfg(test)]
impl Roster {
    /// A legacy roster whose master claims each device, every device consenting.
    pub(crate) fn legacy_for_test(master: &NativeKeypair, devices: &[&NativeKeypair]) -> Roster {
        let mut r = Roster::new(&master.peer_id());
        for d in devices {
            r.add_consent(sign_consent(d, &master.peer_id()));
            r.add_legacy(sign_legacy(master, &d.peer_id()));
        }
        r
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    fn kp(tag: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[tag; 32])
    }

    const NOW: i64 = 1_800_000_000_000;

    pub(crate) struct Id {
        m: NativeKeypair,
        r: NativeKeypair,
    }

    impl Id {
        pub(crate) fn new() -> Self {
            Id { m: kp(1), r: kp(2) }
        }
        pub(crate) fn master(&self) -> String {
            self.m.peer_id()
        }
    }

    fn fold_now(r: &Roster) -> RosterState {
        r.verified(NOW).fold(|_| None, NOW)
    }

    fn with_consent(r: &mut Roster, d: &NativeKeypair) {
        r.add_consent(sign_consent(d, &r.master.clone()));
    }

    #[test]
    fn genesis_makes_its_device_the_only_member() {
        let id = Id::new();
        let d = kp(10);
        let r = Roster::genesis(&id.m, &id.r, &d, NOW);
        let s = fold_now(&r);
        assert!(s.protected);
        assert_eq!(s.members, BTreeSet::from([d.peer_id()]));
        assert_eq!(s.base, r.verified(NOW).base());
    }

    #[test]
    fn only_the_upgrades_own_base_counts_its_admissions() {
        let id = Id::new();
        let (d1, d2, d3) = (kp(10), kp(11), kp(12));
        let r_pub = r_pub_of(&id.r);
        let mut r = Roster::new(&id.master());
        r.add_phrase_statement(&r_pub, Some(sign_upgrade_recovery(&id.m, &id.r)), None).unwrap();
        for d in [&d1, &d2] {
            r.add_phrase_statement(&r_pub, None, Some(sign_upgrade_admit(&id.m, &id.r, &d.peer_id()))).unwrap();
        }
        r.add_phrase_statement(&r_pub, None, Some(sign_phrase_admit(&id.m, &id.r, NOW - 1_000, &d3.peer_id()))).unwrap();
        let r = r.verified(NOW);
        assert_eq!(r.upgrade_admitted(), BTreeSet::from([d1.peer_id(), d2.peer_id()]), "a later admission is not the upgrade's");

        let mut typed = r.clone();
        typed
            .add_phrase_statement(&r_pub, Some(sign_recovery(&id.m, &id.r, NOW - 500, &[d1.peer_id()], false)), None)
            .unwrap();
        assert!(typed.verified(NOW).upgrade_admitted().is_empty(), "a typed recovery's base owes the upgrade nothing");
    }

    #[test]
    fn a_vouch_admits_only_with_the_devices_consent() {
        let id = Id::new();
        let (d1, d2) = (kp(10), kp(11));
        let mut r = Roster::genesis(&id.m, &id.r, &d1, NOW);
        let base = r.base();
        r.add_vouch(sign_vouch(&d1, &id.master(), &base, &d2.peer_id()));
        assert!(!fold_now(&r).is_member(&d2.peer_id()), "no consent, no membership");
        with_consent(&mut r, &d2);
        assert!(fold_now(&r).is_member(&d2.peer_id()));
    }

    #[test]
    fn the_master_key_alone_admits_nobody_once_protected() {
        let id = Id::new();
        let (d1, thief) = (kp(10), kp(66));
        let mut r = Roster::genesis(&id.m, &id.r, &d1, NOW);
        let base = r.base();
        with_consent(&mut r, &thief);
        // Everything a master-key holder can sign on its own.
        r.add_legacy(sign_legacy(&id.m, &thief.peer_id()));
        r.add_pending(sign_pending(&id.m, &base, &thief.peer_id()));
        r.add_vouch(sign_vouch(&thief, &id.master(), &base, &thief.peer_id()));
        let s = fold_now(&r);
        assert!(!s.is_member(&thief.peer_id()));
        assert!(s.pending.contains(&thief.peer_id()));
    }

    #[test]
    fn a_pending_join_matures_on_the_observers_clock_unless_refused() {
        let id = Id::new();
        let (d1, b) = (kp(10), kp(12));
        let mut r = Roster::genesis(&id.m, &id.r, &d1, NOW);
        let base = r.base();
        with_consent(&mut r, &b);
        r.add_pending(sign_pending(&id.m, &base, &b.peer_id()));
        let v = r.verified(NOW);
        let seen = NOW - PENDING_MATURITY_MS;
        assert!(v.fold(|_| Some(seen + 1), NOW).pending.contains(&b.peer_id()));
        assert!(v.fold(|_| Some(seen), NOW).is_member(&b.peer_id()));
        assert!(!v.fold(|_| None, NOW).is_member(&b.peer_id()), "never seen, never matured");

        r.add_removal(sign_removal(&d1, &id.master(), &base, &b.peer_id(), &[]));
        let refused = r.verified(NOW).fold(|_| Some(seen), NOW);
        assert!(!refused.is_member(&b.peer_id()));
        assert_eq!(refused.removed.get(&b.peer_id()), Some(&d1.peer_id()));
    }

    /// C-IDENTITY-04. A pending join a device of the phrase refused never matures, so
    /// whoever holds the master key gains no removals by waiting: the owner stays, the
    /// refused device and what it vouched stay out, and neither removes anyone.
    #[test]
    fn authz_a_refused_join_never_gains_removals_by_waiting() {
        let id = Id::new();
        let (owner, laptop, b, c) = (kp(10), kp(11), kp(12), kp(13));
        let mut r = Roster::genesis(&id.m, &id.r, &owner, NOW - 10);
        let base = r.base();
        for d in [&laptop, &b, &c] {
            with_consent(&mut r, d);
        }
        r.add_vouch(sign_vouch(&owner, &id.master(), &base, &laptop.peer_id()));
        r.add_pending(sign_pending(&id.m, &base, &b.peer_id()));
        r.add_vouch(sign_vouch(&b, &id.master(), &base, &c.peer_id()));
        for target in [&owner, &laptop] {
            r.add_removal(sign_removal(&b, &id.master(), &base, &target.peer_id(), &[]));
            r.add_removal(sign_removal(&c, &id.master(), &base, &target.peer_id(), &[]));
        }
        r.add_removal(sign_removal(&laptop, &id.master(), &base, &b.peer_id(), &[]));
        let waited = r.verified(NOW).fold(|_| Some(NOW - PENDING_MATURITY_MS), NOW);
        assert_eq!(
            waited.members,
            BTreeSet::from([owner.peer_id(), laptop.peer_id()]),
            "a refused join gained removals by waiting: {waited:?}",
        );
        assert_eq!(waited.removed.get(&b.peer_id()), Some(&laptop.peer_id()));
    }

    /// Only a device with an admission path signs a removal that counts: a stranger,
    /// a device that only consented and one still asking to join remove nobody.
    #[test]
    fn a_removal_counts_only_from_a_rooted_device() {
        let id = Id::new();
        let (owner, stranger, consented, asking) = (kp(10), kp(70), kp(71), kp(72));
        let mut r = Roster::genesis(&id.m, &id.r, &owner, NOW);
        let base = r.base();
        with_consent(&mut r, &consented);
        with_consent(&mut r, &asking);
        r.add_pending(sign_pending(&id.m, &base, &asking.peer_id()));
        for by in [&stranger, &consented, &asking] {
            r.add_removal(sign_removal(by, &id.master(), &base, &owner.peer_id(), &[]));
        }
        let s = fold_now(&r);
        assert!(s.is_member(&owner.peer_id()), "removed by someone who is nobody: {s:?}");
        assert!(s.removed.is_empty());
    }

    #[test]
    fn a_removed_devices_later_vouches_are_void_unless_its_remover_kept_them() {
        let id = Id::new();
        let (old, new, desk, thief_new) = (kp(10), kp(11), kp(12), kp(13));
        let mut r = Roster::genesis(&id.m, &id.r, &old, NOW);
        let base = r.base();
        for d in [&new, &desk, &thief_new] {
            with_consent(&mut r, d);
        }
        r.add_vouch(sign_vouch(&old, &id.master(), &base, &new.peer_id()));
        r.add_vouch(sign_vouch(&old, &id.master(), &base, &desk.peer_id()));
        r.add_vouch(sign_vouch(&old, &id.master(), &base, &thief_new.peer_id()));
        // The new phone retires the old one and keeps what it knows of.
        r.add_removal(sign_removal(
            &new, &id.master(), &base, &old.peer_id(),
            &[new.peer_id(), desk.peer_id()],
        ));
        let s = fold_now(&r);
        assert!(!s.is_member(&old.peer_id()));
        assert!(s.is_member(&new.peer_id()));
        assert!(s.is_member(&desk.peer_id()));
        assert!(!s.is_member(&thief_new.peer_id()), "a vouch its remover did not keep");
    }

    #[test]
    fn mutual_removal_removes_both_and_a_recovery_settles_it() {
        let id = Id::new();
        let (owner, thief) = (kp(10), kp(66));
        let mut r = Roster::genesis(&id.m, &id.r, &owner, NOW - 10);
        let base = r.base();
        with_consent(&mut r, &thief);
        r.add_vouch(sign_vouch(&owner, &id.master(), &base, &thief.peer_id()));
        r.add_removal(sign_removal(&thief, &id.master(), &base, &owner.peer_id(), &[]));
        r.add_removal(sign_removal(&owner, &id.master(), &base, &thief.peer_id(), &[]));
        let s = fold_now(&r);
        assert!(s.members.is_empty());

        let rec = sign_recovery(&id.m, &id.r, NOW, &[owner.peer_id()], false);
        r.add_phrase_statement(&r_pub_of(&id.r), Some(rec), None).unwrap();
        let s = fold_now(&r);
        assert_eq!(s.members, BTreeSet::from([owner.peer_id()]));
        // Nothing from the old base follows it over, the thief's statements included.
        let new_base = r.base();
        assert_ne!(new_base, base);
        r.add_removal(sign_removal(&thief, &id.master(), &base, &owner.peer_id(), &[]));
        r.add_vouch(sign_vouch(&thief, &id.master(), &new_base, &thief.peer_id()));
        assert_eq!(fold_now(&r).members, BTreeSet::from([owner.peer_id()]));
    }

    #[test]
    fn a_phrase_admission_counts_only_after_the_base_it_postdates() {
        let id = Id::new();
        let (d1, d2) = (kp(10), kp(11));
        let mut r = Roster::genesis(&id.m, &id.r, &d1, NOW - 100);
        with_consent(&mut r, &d2);
        let early = sign_phrase_admit(&id.m, &id.r, NOW - 200, &d2.peer_id());
        r.add_phrase_statement(&r_pub_of(&id.r), None, Some(early)).unwrap();
        assert!(!fold_now(&r).is_member(&d2.peer_id()));
        let late = sign_phrase_admit(&id.m, &id.r, NOW - 50, &d2.peer_id());
        r.add_phrase_statement(&r_pub_of(&id.r), None, Some(late)).unwrap();
        assert!(fold_now(&r).is_member(&d2.peer_id()));
    }

    #[test]
    fn the_first_recovery_key_seen_is_pinned() {
        let id = Id::new();
        let fake_r = kp(3);
        let d1 = kp(10);
        let thief = kp(66);
        let genuine = Roster::genesis(&id.m, &id.r, &d1, NOW - 10).verified(NOW);
        // A master-key holder mints its own recovery key and a newer base.
        let forged = Roster::genesis(&id.m, &fake_r, &thief, NOW).verified(NOW);
        let merged = genuine.merged(&forged);
        assert_eq!(merged.r_pub, genuine.r_pub);
        assert_eq!(fold_now(&merged).members, BTreeSet::from([d1.peer_id()]));
    }

    #[test]
    fn legacy_claims_count_only_until_the_first_recovery() {
        let id = Id::new();
        let (d1, d2) = (kp(10), kp(11));
        let mut r = Roster::new(&id.master());
        with_consent(&mut r, &d1);
        with_consent(&mut r, &d2);
        r.add_legacy(sign_legacy(&id.m, &d1.peer_id()));
        r.add_legacy(sign_legacy(&id.m, &d2.peer_id()));
        let s = fold_now(&r);
        assert!(!s.protected);
        assert_eq!(s.members.len(), 2);

        let rec = sign_recovery(&id.m, &id.r, NOW, &[d1.peer_id()], false);
        r.add_phrase_statement(&r_pub_of(&id.r), Some(rec), None).unwrap();
        r.add_legacy(sign_legacy(&id.m, &d2.peer_id()));
        let s = fold_now(&r);
        assert!(s.protected);
        assert_eq!(s.members, BTreeSet::from([d1.peer_id()]));
    }

    #[test]
    fn no_statement_verifies_as_another() {
        let id = Id::new();
        let d = kp(10);
        let m = id.master();
        let base = "0123456789abcdef0123456789abcdef";
        // A vouch signature replayed as a removal, a pending signature as a legacy claim.
        let v = sign_vouch(&d, &m, base, &kp(11).peer_id());
        let as_removal = Removal {
            base: base.into(),
            device: v.device.clone(),
            by: v.by.clone(),
            keep_vouched: vec![],
            sig: v.sig.clone(),
        };
        let p = sign_pending(&id.m, LEGACY_BASE, &d.peer_id());
        let as_legacy = LegacyClaim { device: d.peer_id(), sig_m: p.sig_m.clone() };
        let mut r = Roster::new(&m);
        r.removals.push(as_removal);
        r.legacy.push(as_legacy);
        let v = r.verified(NOW);
        assert!(v.removals.is_empty());
        assert!(v.legacy.is_empty());
    }

    #[test]
    fn statements_for_another_master_do_not_verify() {
        let id = Id::new();
        let other = kp(9);
        let d = kp(10);
        let mut r = Roster::genesis(&id.m, &id.r, &d, NOW);
        r.master = other.peer_id();
        let v = r.verified(NOW);
        assert!(v.recoveries.is_empty());
        assert!(v.consents.is_empty());
    }

    fn junk_kp(i: u32) -> NativeKeypair {
        let mut seed = [0x5au8; 32];
        seed[..4].copy_from_slice(&i.to_le_bytes());
        NativeKeypair::from_secret_bytes(&seed)
    }

    /// HOL-SEC-078. A statement whose signer has no standing in the roster is dropped,
    /// so a stranger who copies a roster and floods it pushes no removal and no
    /// member's vouch out of the ceilings.
    #[test]
    fn authz_a_strangers_flood_pushes_no_statement_out() {
        let id = Id::new();
        let (owner, laptop, thief, stranger) = (kp(10), kp(11), kp(66), kp(70));
        let mut r = Roster::genesis(&id.m, &id.r, &owner, NOW);
        let base = r.base();
        for d in [&laptop, &thief] {
            with_consent(&mut r, d);
            r.add_vouch(sign_vouch(&owner, &id.master(), &base, &d.peer_id()));
        }
        r.add_removal(sign_removal(&owner, &id.master(), &base, &thief.peer_id(), &[]));
        let mut flood = r.clone();
        for i in 0..400 {
            let j = junk_kp(i);
            flood.consents.push(sign_consent(&j, &id.master()));
            flood.vouches.push(sign_vouch(&stranger, &id.master(), &base, &j.peer_id()));
            flood.removals.push(sign_removal(&stranger, &id.master(), &base, &j.peer_id(), &[]));
        }
        let merged = r.verified(NOW).merged(&flood.verified(NOW));
        let s = fold_now(&merged);
        assert!(!s.is_member(&thief.peer_id()), "a stranger's flood took a removal back");
        assert!(s.is_member(&laptop.peer_id()), "a stranger's flood pushed a linked device out");
        assert!(merged.vouches.iter().chain(flood.verified(NOW).vouches.iter()).all(|v| v.by != stranger.peer_id()));
        assert!(merged.removals.iter().all(|r| r.by != stranger.peer_id()));
    }

    /// HOL-SEC-078. A device with standing that floods gives way to every signer closer
    /// to the phrase: the owner's removal of it stays, and the owner's linked device too.
    #[test]
    fn authz_a_members_flood_never_displaces_a_signer_closer_to_the_phrase() {
        let id = Id::new();
        let (owner, laptop, thief) = (kp(10), kp(11), kp(66));
        let r = members_flood(&id, &owner, &laptop, &thief);
        let v = r.verified(NOW);
        let owners_removal = sign_removal(&owner, &id.master(), &v.base(), &thief.peer_id(), &[]);
        assert!(v.removals.contains(&owners_removal), "the owner's removal was pushed out");
        let s = fold_now(&v);
        assert_eq!(s.members, BTreeSet::from([owner.peer_id(), laptop.peer_id()]));
        assert!(v.vouches.len() <= MAX_VOUCHES && v.removals.len() <= MAX_REMOVALS + MAX_RESERVED);
    }

    /// The owner links a laptop and the thief's phone; the thief signs a deep tree of
    /// its own devices that vouch and remove, then the owner removes the thief.
    fn members_flood(id: &Id, owner: &NativeKeypair, laptop: &NativeKeypair, thief: &NativeKeypair) -> Roster {
        let mut r = Roster::genesis(&id.m, &id.r, owner, NOW);
        let base = r.base();
        for d in [laptop, thief] {
            with_consent(&mut r, d);
            r.add_vouch(sign_vouch(owner, &id.master(), &base, &d.peer_id()));
        }
        for i in 0..150 {
            let (j, k) = (junk_kp(i), junk_kp(10_000 + i));
            r.consents.push(sign_consent(&j, &id.master()));
            r.consents.push(sign_consent(&k, &id.master()));
            r.vouches.push(sign_vouch(thief, &id.master(), &base, &j.peer_id()));
            r.removals.push(sign_removal(thief, &id.master(), &base, &j.peer_id(), &[]));
            r.vouches.push(sign_vouch(&j, &id.master(), &base, &k.peer_id()));
            r.removals.push(sign_removal(&j, &id.master(), &base, &thief.peer_id(), &[k.peer_id()]));
        }
        r.add_removal(sign_removal(owner, &id.master(), &base, &thief.peer_id(), &[]));
        r
    }

    /// Keys ordered by peer id, so a test can make statement order disagree with rank.
    fn by_id() -> Vec<NativeKeypair> {
        let mut ks: Vec<NativeKeypair> = (10..250u8).map(kp).collect();
        ks.sort_by_key(|k| k.peer_id());
        ks
    }

    /// HOL-SEC-079. A full roster keeps statements by their signer's rank, never by
    /// their own order: the owner's removal of a flooding device and the owner's vouch
    /// for the laptop survive, though both would sort after the flood.
    #[test]
    fn authz_signer_rank_decides_what_a_full_roster_keeps() {
        let id = Id::new();
        let ks = by_id();
        let n = ks.len();
        let (laptop, thief, owner) = (&ks[n - 3], &ks[n - 2], &ks[n - 1]);
        let mut r = Roster::genesis(&id.m, &id.r, owner, NOW);
        let base = r.base();
        for d in [laptop, thief] {
            with_consent(&mut r, d);
            r.add_vouch(sign_vouch(owner, &id.master(), &base, &d.peer_id()));
        }
        r.add_vouch(sign_vouch(thief, &id.master(), &base, &laptop.peer_id()));
        for i in 0..150 {
            let j = junk_kp(i);
            r.consents.push(sign_consent(&j, &id.master()));
            r.vouches.push(sign_vouch(thief, &id.master(), &base, &j.peer_id()));
            r.removals.push(sign_removal(thief, &id.master(), &base, &j.peer_id(), &[]));
        }
        let owners_removal = sign_removal(owner, &id.master(), &base, &thief.peer_id(), &[]);
        r.add_removal(owners_removal.clone());
        let v = r.verified(NOW);
        assert!(v.removals.contains(&owners_removal), "the owner's removal was pushed out");
        let s = fold_now(&v);
        assert!(!s.is_member(&thief.peer_id()));
        assert!(s.is_member(&laptop.peer_id()), "the owner's vouch for the laptop was pushed out");
    }

    /// Each standing device's best vouch is kept before any other, so a sibling that
    /// repeats vouches the owner already made cannot push out a deeper device's only one.
    #[test]
    fn a_deep_device_keeps_its_only_vouch_in_a_full_roster() {
        let id = Id::new();
        let ks = by_id();
        let (busy, owner, desk, tablet) = (&ks[0], &ks[1], &ks[ks.len() - 1], &ks[2]);
        let mut r = Roster::genesis(&id.m, &id.r, owner, NOW);
        let base = r.base();
        for d in [busy, desk, tablet] {
            with_consent(&mut r, d);
        }
        r.add_vouch(sign_vouch(owner, &id.master(), &base, &busy.peer_id()));
        r.add_vouch(sign_vouch(owner, &id.master(), &base, &desk.peer_id()));
        r.add_vouch(sign_vouch(desk, &id.master(), &base, &tablet.peer_id()));
        for i in 0..70 {
            let j = junk_kp(i);
            r.consents.push(sign_consent(&j, &id.master()));
            if i < 60 {
                r.vouches.push(sign_vouch(owner, &id.master(), &base, &j.peer_id()));
            }
            r.vouches.push(sign_vouch(busy, &id.master(), &base, &j.peer_id()));
        }
        let v = r.verified(NOW);
        assert!(fold_now(&v).is_member(&tablet.peer_id()), "the tablet's only vouch was pushed out");
        assert_eq!(v.verified(NOW), v);
    }

    /// Pending joins (anyone holding the master key signs one) and what grows from them
    /// rank after every device the phrase roots, so they push none of those out.
    #[test]
    fn authz_pending_joins_never_displace_the_phrases_devices() {
        let id = Id::new();
        let legit: Vec<NativeKeypair> = (0..6u8).map(|t| kp(20 + t)).collect();
        let mut r = Roster::genesis(&id.m, &id.r, &legit[0], NOW);
        let base = r.base();
        for w in legit.windows(2) {
            with_consent(&mut r, &w[1]);
            r.add_vouch(sign_vouch(&w[0], &id.master(), &base, &w[1].peer_id()));
        }
        for i in 0..40u32 {
            let p = junk_kp(i);
            r.consents.push(sign_consent(&p, &id.master()));
            r.pendings.push(sign_pending(&id.m, &base, &p.peer_id()));
            for k in 0..8u32 {
                let q = junk_kp(1_000 + i * 100 + k);
                r.consents.push(sign_consent(&q, &id.master()));
                r.vouches.push(sign_vouch(&p, &id.master(), &base, &q.peer_id()));
            }
        }
        let v = r.verified(NOW);
        let everyone_waited = v.fold(|_| Some(NOW - PENDING_MATURITY_MS), NOW);
        for d in &legit {
            assert!(everyone_waited.is_member(&d.peer_id()), "pending joins pushed out {}", d.peer_id());
        }
        assert!(v.pendings.len() <= MAX_PENDING);
    }

    /// The same flood, each pending join also removing every phrase device: what only
    /// the master key made never demotes a vouch of the phrase's devices.
    #[test]
    fn authz_pending_joins_removing_the_phrases_devices_never_displace_them() {
        let id = Id::new();
        let legit: Vec<NativeKeypair> = (0..6u8).map(|t| kp(20 + t)).collect();
        let mut r = Roster::genesis(&id.m, &id.r, &legit[0], NOW);
        let base = r.base();
        for w in legit.windows(2) {
            with_consent(&mut r, &w[1]);
            r.add_vouch(sign_vouch(&w[0], &id.master(), &base, &w[1].peer_id()));
        }
        for i in 0..40u32 {
            let p = junk_kp(i);
            r.consents.push(sign_consent(&p, &id.master()));
            r.pendings.push(sign_pending(&id.m, &base, &p.peer_id()));
            for d in &legit {
                r.removals.push(sign_removal(&p, &id.master(), &base, &d.peer_id(), &[]));
            }
            for k in 0..8u32 {
                let q = junk_kp(1_000 + i * 100 + k);
                r.consents.push(sign_consent(&q, &id.master()));
                r.vouches.push(sign_vouch(&p, &id.master(), &base, &q.peer_id()));
            }
        }
        let v = r.verified(NOW);
        let state = v.fold(|_| None, NOW);
        for d in &legit {
            assert!(state.is_member(&d.peer_id()), "pending joins pushed out {}", d.peer_id());
        }
        for w in legit.windows(2) {
            assert!(v.vouches.iter().any(|x| x.by == w[0].peer_id() && x.device == w[1].peer_id()), "a phrase vouch fell out");
        }
    }

    /// A master-key pending join that removes the root and floods vouched junk in two
    /// shows (review of HOL-SEC-189, F1). `with_removal` false is the control.
    fn master_key_pending_flood(with_removal: bool) -> (Roster, Roster, String, Vouch) {
        let id = Id::new();
        let master = id.master();
        let (root, h, p) = (kp(10), kp(11), kp(200));
        let mut held = Roster::genesis(&id.m, &id.r, &root, NOW - 10);
        let base = held.base();
        with_consent(&mut held, &h);
        let tree = sign_vouch(&root, &master, &base, &h.peer_id());
        held.add_vouch(tree.clone());
        let held = held.verified(NOW);
        let show = |from: u32| {
            let mut f = held.clone();
            f.add_consent(sign_consent(&p, &master));
            f.add_pending(sign_pending(&id.m, &base, &p.peer_id()));
            if with_removal {
                f.add_removal(sign_removal(&p, &master, &base, &root.peer_id(), &[]));
            }
            for i in from..from + 95 {
                let j = junk_kp(70_000 + i);
                f.add_consent(sign_consent(&j, &master));
                f.add_vouch(sign_vouch(&p, &master, &base, &j.peer_id()));
            }
            f.verified(NOW)
        };
        let after = held.merged(&show(0)).merged(&show(1000));
        (held, after, h.peer_id(), tree)
    }

    /// [`master_key_pending_flood`] with its removal for the relay's vectors: (the
    /// roster held after the first show, the second show, the linked device).
    pub(crate) fn master_key_pending_flood_vector() -> (Roster, Roster, String) {
        let id = Id::new();
        let master = id.master();
        let (root, h, p) = (kp(10), kp(11), kp(200));
        let mut held = Roster::genesis(&id.m, &id.r, &root, NOW - 10);
        let base = held.base();
        with_consent(&mut held, &h);
        held.add_vouch(sign_vouch(&root, &master, &base, &h.peer_id()));
        let held = held.verified(NOW);
        let show = |from: u32| {
            let mut f = held.clone();
            f.add_consent(sign_consent(&p, &master));
            f.add_pending(sign_pending(&id.m, &base, &p.peer_id()));
            f.add_removal(sign_removal(&p, &master, &base, &root.peer_id(), &[]));
            for i in from..from + 95 {
                let j = junk_kp(70_000 + i);
                f.add_consent(sign_consent(&j, &master));
                f.add_vouch(sign_vouch(&p, &master, &base, &j.peer_id()));
            }
            f.verified(NOW)
        };
        (held.merged(&show(0)), show(1000), h.peer_id())
    }

    /// A master-key pending join removes the root and floods junk vouches inside the
    /// consent cap, valid junk-to-junk ones past the vouch cap: the honest backup vouch
    /// a -> b (b's tree vouch is the root's) stays, valid, ahead of every junk one.
    /// (held after the first show, the second show, the backup vouch.)
    pub(crate) fn pending_backup_flood() -> (Roster, Roster, Vouch) {
        let id = Id::new();
        let master = id.master();
        let (root, a, b, p) = (kp(10), kp(11), kp(12), kp(200));
        let mut held = Roster::genesis(&id.m, &id.r, &root, NOW - 10);
        let base = held.base();
        for d in [&a, &b] {
            with_consent(&mut held, d);
            held.add_vouch(sign_vouch(&root, &master, &base, &d.peer_id()));
        }
        let backup = sign_vouch(&a, &master, &base, &b.peer_id());
        held.add_vouch(backup.clone());
        let held = held.verified(NOW);
        let junk: Vec<NativeKeypair> = (0..88u32).map(|i| junk_kp(50_000 + i)).collect();
        let show = |half: usize| {
            let mut f = held.clone();
            f.add_consent(sign_consent(&p, &master));
            f.add_pending(sign_pending(&id.m, &base, &p.peer_id()));
            f.add_removal(sign_removal(&p, &master, &base, &root.peer_id(), &[]));
            for j in &junk {
                f.add_consent(sign_consent(j, &master));
            }
            let part = if half == 0 { &junk[..44] } else { &junk[44..] };
            for j in part {
                f.add_vouch(sign_vouch(&p, &master, &base, &j.peer_id()));
            }
            for w in part.windows(2) {
                f.add_vouch(sign_vouch(&w[0], &master, &base, &w[1].peer_id()));
            }
            f.verified(NOW)
        };
        (held.merged(&show(0)), show(1), backup)
    }

    /// The first vouch-cap case, then a pending join shows vouched junk twice, past the
    /// consent cap (F2): (held after the first show, the second show, the case's device).
    pub(crate) fn pending_junk_over_the_consent_cap() -> (Roster, Roster, String) {
        let id = Id::new();
        let m = id.master();
        let c = vouch_cap_cases().remove(0);
        let held = c.held.verified(NOW).merged(&c.flood.verified(NOW));
        let base = held.base();
        let p = kp(201);
        let show = |from: u32| {
            let mut f = held.clone();
            f.add_consent(sign_consent(&p, &m));
            f.add_pending(sign_pending(&id.m, &base, &p.peer_id()));
            for i in from..from + 95 {
                let j = junk_kp(60_000 + i);
                f.add_consent(sign_consent(&j, &m));
                f.add_vouch(sign_vouch(&p, &m, &base, &j.peer_id()));
            }
            f.verified(NOW)
        };
        (held.merged(&show(0)), show(1000), c.device)
    }

    /// F1 on its own: only removals every view counts demote a vouch.
    #[test]
    fn review189_a_master_key_pending_join_never_demotes_a_backup_vouch() {
        let (held, shown, backup) = pending_backup_flood();
        let after = held.merged(&shown);
        assert!(after.vouches.len() == MAX_VOUCHES, "setup: the flood fills the vouch cap");
        assert!(after.vouches.contains(&backup), "the honest backup vouch fell out");
    }

    #[test]
    fn review189_without_a_pending_removal_the_tree_vouch_stays() {
        let (held, after, h, tree) = master_key_pending_flood(false);
        assert!(held.fold(|_| None, NOW).is_member(&h));
        assert!(after.vouches.contains(&tree), "the root's vouch fell out without any removal");
        assert!(after.fold(|_| None, NOW).is_member(&h));
        assert_eq!(after.clone().compacted(), after, "compacting a merge twice changed it");
    }

    #[test]
    fn review189_a_master_key_pending_join_uncounts_a_linked_device() {
        let (held, after, h, tree) = master_key_pending_flood(true);
        assert!(held.fold(|_| None, NOW).is_member(&h), "h counts before the flood");
        assert!(after.fold(|_| None, NOW).is_member(&kp(10).peer_id()), "the root still counts");
        assert!(after.vouches.contains(&tree), "the root's vouch of h fell out of the cap");
        assert!(after.fold(|_| None, NOW).is_member(&h), "h stopped counting");
        assert_eq!(after.clone().compacted(), after, "compacting a merge twice changed it");
    }

    /// Every HOL-SEC-189 case, then a master-key pending join (no removal) shows vouched
    /// junk twice: the union holds more standing devices than the consent cap (F2).
    #[test]
    fn review189_b_a_pending_junk_flood_keeps_every_case() {
        let id = Id::new();
        let m = id.master();
        let mut bad = Vec::new();
        for c in vouch_cap_cases() {
            let held = c.held.verified(NOW).merged(&c.flood.verified(NOW));
            let base = held.base();
            let p = kp(201);
            let show = |from: u32| {
                let mut f = held.clone();
                f.add_consent(sign_consent(&p, &m));
                f.add_pending(sign_pending(&id.m, &base, &p.peer_id()));
                for i in from..from + 95 {
                    let j = junk_kp(60_000 + i);
                    f.add_consent(sign_consent(&j, &m));
                    f.add_vouch(sign_vouch(&p, &m, &base, &j.peer_id()));
                }
                f.verified(NOW)
            };
            let (s1, s2) = (show(0), show(1000));
            let after = held.merged(&s1).merged(&s2);
            if !after.vouches.contains(&c.kept) {
                bad.push(format!("{}: kept vouch fell out", c.name));
            }
            let mut all = c.held.clone();
            for r in [&c.flood, &s1, &s2] {
                all.vouches.extend(r.vouches.iter().cloned());
                all.removals.extend(r.removals.iter().cloned());
                all.consents.extend(r.consents.iter().cloned());
                all.pendings.extend(r.pendings.iter().cloned());
            }
            if after.walk_view() != all.walk_view() {
                bad.push(format!("{}: walk differs from every statement", c.name));
            }
            if after.clone().compacted() != after {
                bad.push(format!("{}: not idempotent", c.name));
            }
        }
        assert!(bad.is_empty(), "{bad:?}");
    }

    /// HOL-SEC-079. A device the removed one vouched cannot keep itself by removing it
    /// too: a removed device keeps only the vouchees that every removal of it keeps.
    #[test]
    fn authz_a_removed_device_cannot_bring_a_device_back_through_its_own_removal() {
        let id = Id::new();
        let (owner, thief, j) = (kp(10), kp(66), kp(67));
        let mut r = Roster::genesis(&id.m, &id.r, &owner, NOW);
        let base = r.base();
        with_consent(&mut r, &thief);
        with_consent(&mut r, &j);
        r.add_vouch(sign_vouch(&owner, &id.master(), &base, &thief.peer_id()));
        r.add_removal(sign_removal(&owner, &id.master(), &base, &thief.peer_id(), &[]));
        r.add_vouch(sign_vouch(&thief, &id.master(), &base, &j.peer_id()));
        r.add_removal(sign_removal(&j, &id.master(), &base, &thief.peer_id(), &[j.peer_id()]));
        let s = fold_now(&r);
        assert!(!s.is_member(&j.peer_id()), "HOL-SEC-079: the removed device's vouchee kept itself");
        assert!(!s.is_member(&thief.peer_id()));
    }

    #[test]
    fn a_removed_device_keeps_only_what_every_removal_keeps() {
        let id = Id::new();
        let (owner, desk, old, a, b) = (kp(10), kp(11), kp(12), kp(13), kp(14));
        let mut r = Roster::genesis(&id.m, &id.r, &owner, NOW);
        let base = r.base();
        for d in [&desk, &old, &a, &b] {
            with_consent(&mut r, d);
        }
        r.add_vouch(sign_vouch(&owner, &id.master(), &base, &desk.peer_id()));
        r.add_vouch(sign_vouch(&owner, &id.master(), &base, &old.peer_id()));
        r.add_vouch(sign_vouch(&old, &id.master(), &base, &a.peer_id()));
        r.add_vouch(sign_vouch(&old, &id.master(), &base, &b.peer_id()));
        r.add_removal(sign_removal(&owner, &id.master(), &base, &old.peer_id(), &[a.peer_id(), b.peer_id()]));
        assert!(fold_now(&r).members.is_superset(&BTreeSet::from([a.peer_id(), b.peer_id()])));
        r.add_removal(sign_removal(&desk, &id.master(), &base, &old.peer_id(), &[a.peer_id()]));
        let s = fold_now(&r);
        assert!(s.is_member(&a.peer_id()));
        assert!(!s.is_member(&b.peer_id()), "one removal kept a device another one did not");
    }

    /// The phrase can turn joining by seven quiet days off for its base. The flag sits
    /// inside the phrase's signature, so nobody else can strip it, and a later recovery
    /// without it turns waiting back on.
    #[test]
    fn the_phrase_can_turn_off_joining_by_waiting() {
        let id = Id::new();
        let (d1, b) = (kp(10), kp(12));
        let mut r = Roster::new(&id.master());
        with_consent(&mut r, &d1);
        with_consent(&mut r, &b);
        let strict = sign_recovery(&id.m, &id.r, NOW - 5, &[d1.peer_id()], true);
        r.add_phrase_statement(&r_pub_of(&id.r), Some(strict), None).unwrap();
        let base = r.base();
        r.add_pending(sign_pending(&id.m, &base, &b.peer_id()));
        let waited = |r: &Roster| r.verified(NOW).fold(|_| Some(NOW - PENDING_MATURITY_MS), NOW);
        let s = waited(&r);
        assert!(s.no_wait && !s.is_member(&b.peer_id()) && s.pending.contains(&b.peer_id()));

        let mut stripped = r.clone();
        stripped.recoveries[0].no_wait = false;
        assert!(stripped.verified(NOW).recoveries.is_empty(), "the flag came off without the phrase");

        let open = sign_recovery(&id.m, &id.r, NOW, &[d1.peer_id()], false);
        r.add_phrase_statement(&r_pub_of(&id.r), Some(open), None).unwrap();
        let base = r.base();
        r.add_pending(sign_pending(&id.m, &base, &b.peer_id()));
        let s = waited(&r);
        assert!(!s.no_wait && s.is_member(&b.peer_id()));
    }

    /// Compacting a compacted roster changes nothing, flood or not, so every observer
    /// that holds the same statements holds the same roster.
    #[test]
    fn compaction_is_stable() {
        let id = Id::new();
        let v = members_flood(&id, &kp(10), &kp(11), &kp(66)).verified(NOW);
        assert_eq!(v.verified(NOW), v);
        assert_eq!(v.merged(&v), v);
        let mut legacy = Roster::legacy_for_test(&id.m, &[&kp(10), &kp(11)]);
        legacy.add_removal(sign_removal(&kp(10), &id.master(), LEGACY_BASE, &kp(12).peer_id(), &[]));
        let v = legacy.verified(NOW);
        assert_eq!(v.verified(NOW), v);
    }

    /// Every ceiling filled with the longest statements still fits the wire limit, so a
    /// roster that compacts is never dropped whole for its size.
    #[test]
    fn the_largest_roster_fits_on_the_wire() {
        let id = Id::new();
        let devs: Vec<NativeKeypair> = (0..140).map(junk_kp).collect();
        let ids: Vec<String> = devs.iter().map(|d| d.peer_id()).collect();
        let mut r = Roster::new(&id.master());
        for d in &devs {
            r.consents.push(sign_consent(d, &id.master()));
        }
        r.r_pub = r_pub_of(&id.r);
        for t in 0..6 {
            let keep: Vec<String> = ids.iter().skip(t * 10).take(MAX_KEEP).cloned().collect();
            r.recoveries.push(sign_recovery(&id.m, &id.r, NOW - 100, &keep, t % 2 == 0));
        }
        let base = r.verified(NOW).base();
        for (i, d) in devs.iter().enumerate().take(80) {
            r.phrase_admits.push(sign_phrase_admit(&id.m, &id.r, NOW - 50 + i as i64, &d.peer_id()));
            r.pendings.push(sign_pending(&id.m, &base, &ids[139 - i]));
        }
        for (i, by) in devs.iter().enumerate() {
            for k in 0..3 {
                let target = &ids[(i + k + 1) % ids.len()];
                r.vouches.push(sign_vouch(by, &id.master(), &base, target));
                let keep: Vec<String> = ids.iter().skip(i + k).take(MAX_REMOVAL_KEEP).cloned().collect();
                r.removals.push(sign_removal(by, &id.master(), &base, target, &keep));
            }
        }
        let v = r.verified(NOW);
        assert_eq!(v.vouches.len(), MAX_VOUCHES);
        assert_eq!(v.removals.len(), MAX_REMOVALS + MAX_RESERVED);
        let bytes = serde_json::to_vec(&v).unwrap().len();
        assert!(bytes <= MAX_ROSTER_BYTES, "the largest roster is {bytes} bytes");
    }

    #[test]
    fn a_far_future_phrase_statement_is_dropped() {
        let id = Id::new();
        let d = kp(10);
        let r = Roster::genesis(&id.m, &id.r, &d, NOW + MAX_FUTURE_SKEW_MS + 1);
        assert!(r.verified(NOW).recoveries.is_empty());
    }

    /// C-IDENTITY-02. A roster this node holds was judged for its times when each
    /// statement arrived: checked again, it keeps every phrase statement whatever the
    /// clock reads now, and its pinned recovery key outlives even its statements.
    #[test]
    fn a_held_roster_is_never_judged_by_the_clock_again() {
        let id = Id::new();
        let d = kp(10);
        let ahead = Roster::genesis(&id.m, &id.r, &d, NOW + MAX_FUTURE_SKEW_MS + 1);
        let held = ahead.reverified();
        assert_eq!(held.recoveries.len(), 1, "a held recovery was judged by the clock");
        assert_eq!(held.r_pub, r_pub_of(&id.r));
        assert!(held.fold(|_| None, NOW).protected);
        let mut bare = held.clone();
        bare.recoveries.clear();
        assert_eq!(bare.reverified().r_pub, r_pub_of(&id.r), "a held pin was cleared");
        assert!(bare.verified(NOW).r_pub.is_empty(), "an arriving key with nothing behind it is no pin");
    }

    /// `n` asking devices of `id` in `held`'s base whose ids sort before `than`, as a
    /// flood picks them.
    fn low_asks(id: &Id, held: &Roster, than: &str, n: usize) -> Roster {
        let base = held.base();
        let mut flood = Roster { r_pub: held.r_pub.clone(), recoveries: held.recoveries.clone(), ..Roster::new(&id.master()) };
        for p in (0u32..).map(junk_kp).filter(|p| p.peer_id().as_str() < than).take(n) {
            flood.consents.push(sign_consent(&p, &id.master()));
            flood.pendings.push(sign_pending(&id.m, &base, &p.peer_id()));
        }
        flood
    }

    /// C-IDENTITY-16. Sixteen asks under ids that sort first, arriving after a real
    /// restored device asked, never push that ask out: a holder ranks asks by when it
    /// first saw them, so the real one still matures after its seven days.
    #[test]
    fn authz_a_flood_of_pending_joins_never_hides_a_real_ask() {
        let id = Id::new();
        let owner = kp(10);
        let real = kp(77);
        let mut held = Roster::genesis(&id.m, &id.r, &owner, NOW - 30 * 24 * 3_600_000);
        let base = held.base();
        with_consent(&mut held, &real);
        held.add_pending(sign_pending(&id.m, &base, &real.peer_id()));
        let held = held.verified(NOW);
        let flood = low_asks(&id, &held, &real.peer_id(), MAX_PENDING).verified(NOW);
        assert_eq!(flood.pendings.len(), MAX_PENDING);

        let seen = |_: &str, d: &str| (d == real.peer_id()).then_some(NOW - PENDING_MATURITY_MS);
        let kept = held.merged_by_first_sight(&flood, seen);
        assert!(kept.pendings.iter().any(|p| p.device == real.peer_id()), "a later flood pushed out the real ask");
        assert_eq!(kept.pendings.len(), MAX_PENDING);
        assert!(kept.fold(|d| seen("", d), NOW).is_member(&real.peer_id()), "the real ask never matured");
        assert!(
            !held.merged(&flood).pendings.iter().any(|p| p.device == real.peer_id()),
            "control: by id alone the flood wins",
        );

        // Asks seen first keep their slots even against an unseen one whose id sorts
        // before theirs: the clock decides, never the id.
        let mut early = Roster::genesis(&id.m, &id.r, &owner, NOW - 30 * 24 * 3_600_000);
        for p in (0u32..).map(junk_kp).filter(|p| p.peer_id() > real.peer_id()).take(MAX_PENDING) {
            early.consents.push(sign_consent(&p, &id.master()));
            early.pendings.push(sign_pending(&id.m, &base, &p.peer_id()));
        }
        let early = early.verified(NOW);
        assert_eq!(early.pendings.len(), MAX_PENDING);
        let early_seen = |_: &str, d: &str| (d != real.peer_id()).then_some(NOW - 1_000);
        assert!(
            !early.merged_by_first_sight(&held, early_seen).pendings.iter().any(|p| p.device == real.peer_id()),
            "an ask seen after the slots filled took one",
        );

        // Under the ceiling nothing changes.
        let few = low_asks(&id, &held, &real.peer_id(), 3).verified(NOW);
        assert_eq!(held.merged_by_first_sight(&few, |_, _| None), held.merged(&few));
    }

    // b3-ar29: the roster digest DMs carry.

    #[test]
    fn b3_ar29_digest_ignores_order_and_unnamed_consents_but_not_a_removal() {
        let id = Id::new();
        let (d1, d2, stranger) = (kp(10), kp(11), kp(12));
        let mut r = Roster::genesis(&id.m, &id.r, &d1, NOW);
        let base = r.verified(NOW).base();
        with_consent(&mut r, &d2);
        r.add_vouch(sign_vouch(&d1, &id.master(), &base, &d2.peer_id()));
        let r = r.verified(NOW);
        let d = r.digest();
        assert!(is_digest_shape(&d), "{d}");

        let mut shuffled = r.clone();
        shuffled.consents.reverse();
        assert_eq!(shuffled.digest(), d, "the order statements arrived in changes nothing");

        let mut junk = r.clone();
        junk.add_consent(sign_consent(&stranger, &id.master()));
        assert_eq!(junk.verified(NOW).digest(), d, "an unnamed consent anyone can mint changes nothing");

        let mut removed = r.clone();
        removed.add_removal(sign_removal(&d1, &id.master(), &base, &d2.peer_id(), &[]));
        assert_ne!(removed.verified(NOW).digest(), d, "a removal moves the digest");
        assert_ne!(Roster::new(&id.master()).digest(), d);
    }

    #[test]
    fn b3_ar29_digest_shape_is_strict() {
        assert!(is_digest_shape(&"0a".repeat(16)));
        for bad in ["", "0A0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a", "zz0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a", &"0a".repeat(17)] {
            assert!(!is_digest_shape(bad), "{bad}");
        }
    }

    // b3-review: two holders that kept different asks of one flood must still agree
    // once they traded views, or every DM between their owners asks forever.
    #[test]
    fn b3_review_holders_of_one_pending_flood_converge_on_one_digest() {
        let id = Id::new();
        let owner = kp(10);
        let held = Roster::genesis(&id.m, &id.r, &owner, NOW - 30 * 24 * 3_600_000).verified(NOW);
        let base = held.base();
        let flood = |from: u32| {
            let mut r = held.clone();
            let devices: Vec<String> = (from..from + MAX_PENDING as u32).map(junk_kp).map(|p| {
                r.consents.push(sign_consent(&p, &id.master()));
                r.pendings.push(sign_pending(&id.m, &base, &p.peer_id()));
                // f-b3-phone F4: what a pending device signs stands only through its join.
                r.vouches.push(sign_vouch(&p, &id.master(), &base, &owner.peer_id()));
                r.removals.push(sign_removal(&p, &id.master(), &base, &owner.peer_id(), &[]));
                p.peer_id()
            }).collect();
            (r.verified(NOW), devices)
        };
        let ((fa, seen_by_a), (fb, seen_by_b)) = (flood(0), flood(1000));
        let first_sight = |seen: Vec<String>| move |_: &str, d: &str| seen.contains(&d.to_string()).then_some(NOW - 1_000);
        let (sa, sb) = (first_sight(seen_by_a), first_sight(seen_by_b));
        let a = held.merged_by_first_sight(&fa, &sa);
        let b = held.merged_by_first_sight(&fb, &sb);
        let a2 = a.merged_by_first_sight(&b, &sa);
        let b2 = b.merged_by_first_sight(&a, &sb);
        assert_eq!(a2.merged_by_first_sight(&b2, &sa), a2, "precondition: A's view is settled");
        assert_eq!(a2.digest(), b2.digest(), "two holders of one identity's roster never agree on its digest");
    }

    // t14-ident HOL-SEC-189

    /// One vouch-cap case: `held` is the honest roster, `flood` what a removed (or busy)
    /// device shows, `kept` the vouch the merge must keep, `member` whether `device`
    /// belongs in ID-1's fold afterwards (None: the fold decides it on other grounds).
    pub(crate) struct VouchCapCase {
        pub name: &'static str,
        pub held: Roster,
        pub flood: Roster,
        pub device: String,
        pub kept: Vouch,
        pub member: Option<bool>,
    }

    /// The honest roster with its removals left out, plus `extra` and a flood of vouches
    /// for keys nobody consented under: what a device that never saw its removal shows.
    fn shown_flood(held: &Roster, by: &NativeKeypair, extra: Vec<Vouch>, extra_rm: Vec<Removal>, extra_consent: &[&NativeKeypair]) -> Roster {
        let mut f = held.clone();
        f.removals.clear();
        f.vouches.extend(extra);
        f.removals.extend(extra_rm);
        for d in extra_consent {
            with_consent(&mut f, d);
        }
        let base = held.base();
        for i in 0..(MAX_VOUCHES as u32 + 4) {
            f.vouches.push(sign_vouch(by, &f.master.clone(), &base, &junk_kp(70_000 + i).peer_id()));
        }
        f
    }

    pub(crate) fn vouch_cap_cases() -> Vec<VouchCapCase> {
        let id = Id::new();
        let m = id.master();
        let ks = by_id();
        let (root, k1, k2, k3, k4, k5) = (&ks[0], &ks[1], &ks[2], &ks[3], &ks[4], &ks[5]);
        let linked = |devs: &[&NativeKeypair]| {
            let mut r = Roster::genesis(&id.m, &id.r, root, NOW - 10);
            let base = r.base();
            for d in devs {
                with_consent(&mut r, d);
                r.add_vouch(sign_vouch(root, &m, &base, &d.peer_id()));
            }
            r
        };
        let vouch = |by: &NativeKeypair, d: &NativeKeypair, base: &str| sign_vouch(by, &m, base, &d.peer_id());
        let removal = |by: &NativeKeypair, d: &NativeKeypair, base: &str, keep: &[&NativeKeypair]| {
            let keep: Vec<String> = keep.iter().map(|k| k.peer_id()).collect();
            sign_removal(by, &m, base, &d.peer_id(), &keep)
        };
        let mut out = Vec::new();

        // The root removes t; t, ranked before the honest voucher a, vouches a's vouchee h
        // and floods. The cap must keep a's vouch, or h is valid only through void t.
        let (t, a, h) = (k1, k2, k3);
        let mut held = linked(&[t, a]);
        let base = held.base();
        with_consent(&mut held, h);
        held.add_vouch(vouch(a, h, &base));
        held.add_removal(removal(root, t, &base, &[]));
        let flood = shown_flood(&held, t, vec![vouch(t, h, &base)], vec![], &[]);
        out.push(VouchCapCase { name: "removed-voucher-floods", held: held.clone(), flood, device: h.peer_id(), kept: vouch(a, h, &base), member: Some(true) });
        let s1 = held;

        // A removed voucher's vouch that its removal KEEPS stays valid: q (removed, keeps
        // nothing) vouches h and floods; t's vouch of h, kept by t's removal, must stay.
        let (q, t, h) = (k1, k2, k3);
        let mut held = linked(&[q, t]);
        let base = held.base();
        with_consent(&mut held, h);
        held.add_vouch(vouch(t, h, &base));
        held.add_removal(removal(root, t, &base, &[h]));
        held.add_removal(removal(root, q, &base, &[]));
        let flood = shown_flood(&held, q, vec![vouch(q, h, &base)], vec![], &[]);
        out.push(VouchCapCase { name: "a-kept-vouchee-keeps-its-vouch", held, flood, device: h.peer_id(), kept: vouch(t, h, &base), member: Some(true) });

        // Walk clause 1: removed t's own removal of a counts for nothing.
        let (t, a, h) = (k1, k2, k3);
        let base = s1.base();
        let flood = shown_flood(&s1, t, vec![vouch(t, h, &base)], vec![removal(t, a, &base, &[])], &[]);
        out.push(VouchCapCase { name: "a-removed-signers-removal-is-void", held: s1.clone(), flood, device: h.peer_id(), kept: vouch(a, h, &base), member: None });

        // Walk clause 2: t's puppet p, which nobody removed, removes a.
        let p = k4;
        let flood = shown_flood(&s1, t, vec![vouch(t, h, &base), vouch(t, p, &base)], vec![removal(p, a, &base, &[])], &[p]);
        out.push(VouchCapCase { name: "a-removed-devices-puppet-removes-nothing", held: s1.clone(), flood, device: h.peer_id(), kept: vouch(a, h, &base), member: None });

        // Clause 2 per tier: s ranks in tier 0 (through t), so it is judged from the roots
        // alone, though the pending join j vouches it too.
        let (s, j) = (k4, k5);
        let mut held = s1.clone();
        for d in [j, s] {
            with_consent(&mut held, d);
        }
        held.add_pending(sign_pending(&id.m, &base, &j.peer_id()));
        held.add_vouch(vouch(j, s, &base));
        let flood = shown_flood(&held, t, vec![vouch(t, h, &base), vouch(t, s, &base)], vec![removal(s, a, &base, &[])], &[]);
        out.push(VouchCapCase { name: "a-root-tier-signer-is-judged-from-the-roots", held, flood, device: h.peer_id(), kept: vouch(a, h, &base), member: None });

        // A pending join's vouch is valid (it seeds the pending tier), so a removed
        // device's flood never outranks it.
        let (t, h, j) = (k1, k3, k5);
        let mut held = linked(&[t]);
        let base = held.base();
        for d in [h, j] {
            with_consent(&mut held, d);
        }
        held.add_pending(sign_pending(&id.m, &base, &j.peer_id()));
        held.add_vouch(vouch(j, h, &base));
        held.add_removal(removal(root, t, &base, &[]));
        let flood = shown_flood(&held, t, vec![vouch(t, h, &base)], vec![], &[]);
        out.push(VouchCapCase { name: "a-pending-joins-vouch-outranks-a-removed-device", held, flood, device: h.peer_id(), kept: vouch(j, h, &base), member: Some(false) });

        // Each tree vouch comes from the NEAREST valid voucher. u (under removed t) and v
        // vouch each other and w2 vouches v; picking v's tree vouch by plain rank takes u's
        // (u sorts before w2), the tree loops u <-> v, and a busy w1's flood leaves both
        // with no path to the phrase.
        let (t, w1, u, w2, v) = (k1, k2, k3, k4, k5);
        let mut held = linked(&[t, w1]);
        let base = held.base();
        for d in [u, w2, v] {
            with_consent(&mut held, d);
        }
        for (by, d) in [(t, u), (w1, w2), (w2, v), (u, v), (v, u)] {
            held.add_vouch(vouch(by, d, &base));
        }
        held.add_removal(removal(root, t, &base, &[]));
        let flood = shown_flood(&held, w1, vec![], vec![], &[]);
        out.push(VouchCapCase { name: "the-vouch-tree-stays-rooted", held, flood, device: u.peer_id(), kept: vouch(w2, v, &base), member: Some(true) });

        // Past the tree, valid vouches still outrank a removed device's: b's second vouch
        // of h stays though removed t ranks before b.
        let (t, a, b, h) = (k1, k2, k3, k4);
        let mut held = linked(&[t, a, b]);
        let base = held.base();
        with_consent(&mut held, h);
        held.add_vouch(vouch(a, h, &base));
        held.add_vouch(vouch(b, h, &base));
        held.add_removal(removal(root, t, &base, &[]));
        let flood = shown_flood(&held, t, vec![], vec![], &[]);
        out.push(VouchCapCase { name: "a-second-valid-vouch-outranks-a-removed-device", held, flood, device: h.peer_id(), kept: vouch(b, h, &base), member: Some(true) });

        // A puppet of removed t that nobody removed is still not valid: p ranks before the
        // honest voucher a (both at depth 2), vouches h and floods.
        let (t, x, p, a, h) = (k1, k2, k3, k4, k5);
        let mut held = linked(&[t, x]);
        let base = held.base();
        for d in [a, h] {
            with_consent(&mut held, d);
        }
        held.add_vouch(vouch(x, a, &base));
        held.add_vouch(vouch(a, h, &base));
        held.add_removal(removal(root, t, &base, &[]));
        let flood = shown_flood(&held, p, vec![vouch(t, p, &base), vouch(p, h, &base)], vec![], &[p]);
        out.push(VouchCapCase { name: "a-removed-devices-puppet-is-never-a-valid-voucher", held, flood, device: h.peer_id(), kept: vouch(a, h, &base), member: Some(true) });

        // RC32-10: v's vouch made s valid at s's turn (s then removes x); w, ranked after
        // s, removes v keeping nothing, so the vouch ends invalid. Removed t floods. The
        // cap must keep v's vouch, or a compacted roster walks s dead and x stays.
        let (t, v, x, y, s, w) = (k1, k2, k3, k4, k5, &ks[6]);
        let mut held = linked(&[t, v, x, y]);
        let base = held.base();
        for d in [s, w] {
            with_consent(&mut held, d);
        }
        for (by, d) in [(v, s), (t, s), (y, w)] {
            held.add_vouch(vouch(by, d, &base));
        }
        held.add_removal(removal(root, t, &base, &[]));
        held.add_removal(removal(s, x, &base, &[]));
        held.add_removal(removal(w, v, &base, &[]));
        let flood = shown_flood(&held, t, vec![], vec![], &[]);
        out.push(VouchCapCase { name: "the-walks-support-stays", held, flood, device: x.peer_id(), kept: vouch(v, s, &base), member: None });

        // A removed device's vouch that sets a device's RANK stays too: through removed t,
        // s ranks before w, so s's removal of w counts first. Cut t's vouch and s sinks to
        // w's depth, w (lower id) walks first and removes s.
        let (q, t, a, b, c, w, s) = (k1, k2, k3, k4, k5, &ks[6], &ks[7]);
        let mut held = linked(&[q, t, a]);
        let base = held.base();
        for d in [b, c, w, s] {
            with_consent(&mut held, d);
        }
        for (by, d) in [(a, b), (b, s), (t, s), (a, c), (c, w)] {
            held.add_vouch(vouch(by, d, &base));
        }
        held.add_removal(removal(root, q, &base, &[]));
        held.add_removal(removal(root, t, &base, &[]));
        held.add_removal(removal(s, w, &base, &[]));
        held.add_removal(removal(w, s, &base, &[]));
        let flood = shown_flood(&held, q, vec![], vec![], &[]);
        out.push(VouchCapCase { name: "the-rank-tree-stays", held, flood, device: s.peer_id(), kept: vouch(t, s, &base), member: None });

        // The support is the WHOLE path: s is valid at its turn through x -> v -> s, w
        // (after s) removes x keeping nothing, and v's best-ranked voucher is removed q.
        // Keep only v's vouch of s and x's vouch of v falls to q's flood.
        let (q, x, y, z, v, z2, s, w) = (k1, k2, k3, k4, k5, &ks[6], &ks[7], &ks[8]);
        let mut held = linked(&[q, x, y, z]);
        let base = held.base();
        for d in [v, z2, s, w] {
            with_consent(&mut held, d);
        }
        for (by, d) in [(x, v), (q, v), (v, s), (z, z2), (z2, w)] {
            held.add_vouch(vouch(by, d, &base));
        }
        held.add_removal(removal(root, q, &base, &[]));
        held.add_removal(removal(s, y, &base, &[]));
        held.add_removal(removal(w, x, &base, &[]));
        let flood = shown_flood(&held, q, vec![], vec![], &[]);
        out.push(VouchCapCase { name: "the-whole-support-path-stays", held, flood, device: y.peer_id(), kept: vouch(x, v, &base), member: None });
        out
    }

    fn run_vouch_cap_case(name: &str) {
        let c = vouch_cap_cases().into_iter().find(|c| c.name == name).unwrap();
        let held = c.held.verified(NOW);
        let merged = held.merged(&c.flood.verified(NOW));
        assert!(merged.vouches.contains(&c.kept), "{name}: the vouch {} -> {} fell out of the cap", c.kept.by, c.kept.device);
        assert_eq!(merged.verified(NOW), merged, "{name}: compaction is not stable");
        if let Some(member) = c.member {
            assert_eq!(fold_now(&merged).is_member(&c.device), member, "{name}: membership in ID-1's fold");
        }
        let uncapped = { let mut u = c.held.clone(); u.vouches.extend(c.flood.vouches.iter().cloned()); u.removals.extend(c.flood.removals.iter().cloned()); u.consents.extend(c.flood.consents.iter().cloned()); u };
        assert!(uncapped.verified(NOW).vouches.contains(&c.kept), "{name}: one roster holding every statement drops the vouch");
        assert_eq!(merged.walk_view(), uncapped.walk_view(), "{name}: the compacted roster walks differently");
        assert!(same_authority(&merged) == same_authority(&uncapped), "{name}: authority differs from the uncapped roster's");
        if c.member == Some(true) {
            assert!(merged.authority().counts(&c.device), "{name}: authority uncounts the device");
        }
    }

    /// The verdict of `authority()`: not the digest or the redundant removals, which name
    /// the statements held.
    fn same_authority(r: &Roster) -> (String, BTreeSet<String>, BTreeMap<String, String>) {
        let a = r.authority();
        (a.base, a.counted, a.removed)
    }

    /// HOL-SEC-189. A removed device that ranks before an honest voucher vouches the
    /// honest vouchee and floods: the vouch cap must rank by validity, or the vouchee is
    /// valid only through the removed device.
    #[test]
    fn hol_sec_189_a_removed_devices_vouch_flood_never_uncounts_a_device_another_voucher_holds() {
        run_vouch_cap_case("removed-voucher-floods");
    }

    #[test]
    fn hol_sec_189_a_vouch_the_removal_keeps_outranks_a_removed_devices_flood() {
        run_vouch_cap_case("a-kept-vouchee-keeps-its-vouch");
    }

    #[test]
    fn hol_sec_189_a_removed_signers_own_removals_never_void_a_voucher() {
        run_vouch_cap_case("a-removed-signers-removal-is-void");
    }

    #[test]
    fn hol_sec_189_a_removed_devices_puppet_never_voids_a_voucher() {
        run_vouch_cap_case("a-removed-devices-puppet-removes-nothing");
    }

    #[test]
    fn hol_sec_189_a_root_tier_signer_is_judged_from_the_roots_alone() {
        run_vouch_cap_case("a-root-tier-signer-is-judged-from-the-roots");
    }

    #[test]
    fn hol_sec_189_a_pending_joins_vouch_outranks_a_removed_devices_flood() {
        run_vouch_cap_case("a-pending-joins-vouch-outranks-a-removed-device");
    }

    #[test]
    fn hol_sec_189_each_tree_vouch_comes_from_the_nearest_valid_voucher() {
        run_vouch_cap_case("the-vouch-tree-stays-rooted");
    }

    #[test]
    fn hol_sec_189_a_second_valid_vouch_outranks_a_removed_devices_flood() {
        run_vouch_cap_case("a-second-valid-vouch-outranks-a-removed-device");
    }

    #[test]
    fn hol_sec_189_a_removed_devices_puppet_is_never_a_valid_voucher() {
        run_vouch_cap_case("a-removed-devices-puppet-is-never-a-valid-voucher");
    }

    #[test]
    fn hol_sec_189_the_cap_keeps_what_made_a_walk_signer_valid() {
        run_vouch_cap_case("the-walks-support-stays");
    }

    #[test]
    fn hol_sec_189_the_cap_keeps_the_whole_path_that_made_a_walk_signer_valid() {
        run_vouch_cap_case("the-whole-support-path-stays");
    }

    #[test]
    fn hol_sec_189_the_cap_keeps_each_devices_best_ranked_vouch() {
        run_vouch_cap_case("the-rank-tree-stays");
    }

    /// RC32-10 as a property: random identities with vouch loops, removals and pending
    /// joins, flooded past the vouch cap by a random device. Compacting twice changes
    /// nothing, and the compacted roster walks as every statement did.
    #[test]
    fn compaction_is_idempotent_under_a_vouch_flood() {
        let id = Id::new();
        let m = id.master();
        let mut seed = 0x0189_2026_1104u64;
        let mut next = |n: u64| {
            seed = seed.wrapping_add(0x9e37_79b9_7f4a_7c15);
            let mut z = seed;
            z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
            (z ^ (z >> 31)) % n
        };
        let pool: Vec<NativeKeypair> = (0..14u8).map(|i| kp(20 + i)).collect();
        let junk: Vec<String> = (0..(MAX_VOUCHES as u32 + 4)).map(|i| junk_kp(80_000 + i).peer_id()).collect();
        let mut floods: BTreeMap<(String, String), Vec<Vouch>> = BTreeMap::new();
        for round in 0..300 {
            let n = 3 + next(10) as usize;
            let devs = &pool[..n];
            let mut r = Roster::genesis(&id.m, &id.r, &devs[0], NOW - 10);
            let base = r.base();
            for d in &devs[1..] {
                if next(10) < 9 {
                    with_consent(&mut r, d);
                }
            }
            for i in 1..n {
                r.add_vouch(sign_vouch(&devs[next(i as u64) as usize], &m, &base, &devs[i].peer_id()));
                if next(10) < 4 {
                    let by = next(n as u64) as usize;
                    if by != i {
                        r.add_vouch(sign_vouch(&devs[by], &m, &base, &devs[i].peer_id()));
                    }
                }
            }
            for _ in 0..next(3) {
                r.add_pending(sign_pending(&id.m, &base, &devs[1 + next(n as u64 - 1) as usize].peer_id()));
            }
            for _ in 0..next(8) {
                let (by, d) = (next(n as u64) as usize, next(n as u64) as usize);
                let keep: Vec<String> = (0..next(3)).map(|_| devs[next(n as u64) as usize].peer_id()).collect();
                let mut keep = keep;
                keep.sort();
                keep.dedup();
                r.add_removal(sign_removal(&devs[by], &m, &base, &devs[d].peer_id(), &keep));
            }
            let flooder = &devs[next(n as u64) as usize];
            let mut flood = r.clone();
            for _ in 0..next(4) {
                let d = &devs[next(n as u64) as usize];
                if d.peer_id() != flooder.peer_id() {
                    flood.vouches.push(sign_vouch(flooder, &m, &base, &d.peer_id()));
                }
            }
            // Signatures are checked elsewhere; compaction alone keeps this fast.
            let junk_vouches = floods
                .entry((flooder.peer_id(), base.clone()))
                .or_insert_with(|| junk.iter().map(|j| sign_vouch(flooder, &m, &base, j)).collect());
            flood.vouches.extend(junk_vouches.iter().cloned());
            let once = flood.clone().compacted();
            assert_eq!(once.clone().compacted(), once, "round {round}: compacting twice changed the roster");
            assert_eq!(once.walk_view(), flood.walk_view(), "round {round}: the compacted roster walks differently");
            assert!(same_authority(&once) == same_authority(&flood), "round {round}: authority differs from the uncapped roster's");
            let merged = r.clone().compacted().merged(&once);
            assert_eq!(merged.clone().compacted(), merged, "round {round}: a merge is not stable");
            if round % 30 == 0 {
                // Past the consent cap: a pending join shows vouched junk twice (F2).
                let p = &devs[1 + next(n as u64 - 1) as usize];
                let show = |from: u32| {
                    let mut f = once.clone();
                    f.add_pending(sign_pending(&id.m, &base, &p.peer_id()));
                    for i in from..from + 95 {
                        let j = junk_kp(90_000 + i);
                        f.consents.push(sign_consent(&j, &m));
                        f.vouches.push(sign_vouch(p, &m, &base, &j.peer_id()));
                    }
                    f
                };
                let (s1, s2) = (show(0), show(1000));
                let over = once.merged(&s1.clone().compacted()).merged(&s2.clone().compacted());
                assert_eq!(over.clone().compacted(), over, "round {round}: a merge past the consent cap is not stable");
                let mut all = flood.clone();
                for x in [&s1, &s2] {
                    all.vouches.extend(x.vouches.iter().cloned());
                    all.consents.extend(x.consents.iter().cloned());
                    all.pendings.extend(x.pendings.iter().cloned());
                }
                assert_eq!(over.walk_view(), all.walk_view(), "round {round}: past the consent cap the walk differs");
            }
        }
    }

    // t14-ident authority

    fn pair_by_id(a: NativeKeypair, b: NativeKeypair) -> (NativeKeypair, NativeKeypair) {
        if a.peer_id() < b.peer_id() { (a, b) } else { (b, a) }
    }

    fn linked_to(id: &Id, root: &NativeKeypair, devs: &[&NativeKeypair]) -> Roster {
        let mut r = Roster::genesis(&id.m, &id.r, root, NOW - 10);
        let base = r.base();
        for d in devs {
            with_consent(&mut r, d);
            r.add_vouch(sign_vouch(root, &id.master(), &base, &d.peer_id()));
        }
        r
    }

    /// I1: a pending join that matured for ID-1's fold writes nothing for servers.
    #[test]
    fn authority_ignores_first_sight_and_maturity() {
        let id = Id::new();
        let (owner, backup) = (kp(10), kp(40));
        let mut r = linked_to(&id, &owner, &[]);
        let base = r.base();
        with_consent(&mut r, &backup);
        r.add_pending(sign_pending(&id.m, &base, &backup.peer_id()));
        let v = r.verified(NOW);
        assert!(v.fold(|_| Some(NOW - PENDING_MATURITY_MS - 1), NOW).is_member(&backup.peer_id()), "precondition: matured");
        let a = v.authority();
        assert!(!a.counts(&backup.peer_id()) && a.counts(&owner.peer_id()), "{a:?}");
        assert_eq!(a.base, base);
        assert_eq!(a.digest, v.digest());
        let mut contested = r.clone();
        contested.add_removal(sign_removal(&backup, &id.master(), &base, &owner.peer_id(), &[]));
        let a = contested.verified(NOW).authority();
        assert!(a.counts(&owner.peer_id()) && a.removed.is_empty(), "a pending join removed the owner: {a:?}");
        contested.add_removal(sign_removal(&owner, &id.master(), &base, &backup.peer_id(), &[]));
        let a = contested.verified(NOW).authority();
        assert_eq!(a.removed.get(&backup.peer_id()), Some(&owner.peer_id()), "a removal of a pending join counts");
    }

    /// I2: a key a master-key holder minted (consent + pending ask) and a thief a recovery
    /// left out never count; the predicate is `counted`, never "named removed".
    #[test]
    fn a_minted_key_and_a_recovered_away_thief_never_count() {
        let id = Id::new();
        let (owner, thief, minted) = (kp(10), kp(66), kp(67));
        let mut r = linked_to(&id, &owner, &[&thief]);
        let base = r.base();
        r.add_removal(sign_removal(&owner, &id.master(), &base, &thief.peer_id(), &[]));
        with_consent(&mut r, &minted);
        r.add_pending(sign_pending(&id.m, &base, &minted.peer_id()));
        assert!(!r.verified(NOW).authority().counts(&minted.peer_id()));
        let rec = sign_recovery(&id.m, &id.r, NOW, &[owner.peer_id()], false);
        r.add_phrase_statement(&r_pub_of(&id.r), Some(rec), None).unwrap();
        let a = r.reverified().authority();
        assert!(!a.counts(&thief.peer_id()) && !a.counts(&minted.peer_id()) && a.counts(&owner.peer_id()), "{a:?}");
    }

    /// I3: the device that removed first wins for authority; ID-1's fold still removes both.
    #[test]
    fn a_removed_device_cannot_uncount_the_device_that_removed_it() {
        let id = Id::new();
        let (phone, laptop) = (kp(10), kp(66));
        let mut r = linked_to(&id, &phone, &[&laptop]);
        let base = r.base();
        r.add_removal(sign_removal(&phone, &id.master(), &base, &laptop.peer_id(), &[]));
        r.add_removal(sign_removal(&laptop, &id.master(), &base, &phone.peer_id(), &[]));
        let a = r.reverified().authority();
        assert!(a.counts(&phone.peer_id()) && !a.counts(&laptop.peer_id()), "{a:?}");
        assert_eq!(a.removed.get(&laptop.peer_id()), Some(&phone.peer_id()));
        let f = r.reverified().fold(|_| None, 0);
        assert!(!f.is_member(&phone.peer_id()) && !f.is_member(&laptop.peer_id()), "ID-1's fold removes both");
    }

    /// I3 (N4): equal-rank siblings that remove each other: the lower id wins.
    #[test]
    fn an_equal_rank_mutual_removal_goes_to_the_lower_id() {
        let id = Id::new();
        let root = kp(10);
        let (lo, hi) = pair_by_id(kp(20), kp(21));
        let mut r = linked_to(&id, &root, &[&lo, &hi]);
        let base = r.base();
        r.add_removal(sign_removal(&hi, &id.master(), &base, &lo.peer_id(), &[]));
        r.add_removal(sign_removal(&lo, &id.master(), &base, &hi.peer_id(), &[]));
        let a = r.reverified().authority();
        assert!(a.counts(&lo.peer_id()) && !a.counts(&hi.peer_id()), "{a:?}");
    }

    /// I3 (R3-1): a removed thief's puppet, which nobody removed, removes nobody.
    #[test]
    fn a_removed_thiefs_puppet_cannot_uncount_the_device_that_removed_the_thief() {
        let id = Id::new();
        let (phone, laptop, puppet) = (kp(10), kp(66), junk_kp(90_001));
        let mut r = linked_to(&id, &phone, &[&laptop]);
        let base = r.base();
        r.add_removal(sign_removal(&phone, &id.master(), &base, &laptop.peer_id(), &[]));
        with_consent(&mut r, &puppet);
        r.add_vouch(sign_vouch(&laptop, &id.master(), &base, &puppet.peer_id()));
        r.add_removal(sign_removal(&puppet, &id.master(), &base, &phone.peer_id(), &[]));
        let a = r.reverified().authority();
        assert!(!a.counts(&puppet.peer_id()) && a.counts(&phone.peer_id()), "{a:?}");
    }

    /// I3 (R3-1b): two levels under the removed thief.
    #[test]
    fn a_puppet_two_levels_under_a_removed_thief_cannot_remove_the_root() {
        let id = Id::new();
        let (root, thief, p1, p2) = (kp(10), kp(66), junk_kp(90_011), junk_kp(90_012));
        let mut r = linked_to(&id, &root, &[&thief]);
        let base = r.base();
        r.add_removal(sign_removal(&root, &id.master(), &base, &thief.peer_id(), &[]));
        for p in [&p1, &p2] {
            with_consent(&mut r, p);
        }
        r.add_vouch(sign_vouch(&thief, &id.master(), &base, &p1.peer_id()));
        r.add_vouch(sign_vouch(&p1, &id.master(), &base, &p2.peer_id()));
        r.add_removal(sign_removal(&p2, &id.master(), &base, &root.peer_id(), &[]));
        let a = r.reverified().authority();
        assert!(a.counts(&root.peer_id()), "{a:?}");
    }

    /// I4: a stolen ROOT that floods junk removals keeps the phone's removal of it, in
    /// ID-1's fold and for authority (its reserved slot).
    #[test]
    fn a_device_never_floods_out_a_removal_of_itself() {
        let id = Id::new();
        let (laptop, phone) = (kp(10), kp(11));
        let mut r = linked_to(&id, &laptop, &[&phone]);
        let base = r.base();
        let phones = sign_removal(&phone, &id.master(), &base, &laptop.peer_id(), &[]);
        r.add_removal(phones.clone());
        let mut flood = r.clone();
        flood.removals.clear();
        for i in 0..(MAX_REMOVALS as u32 + MAX_RESERVED as u32 + 4) {
            flood.removals.push(sign_removal(&laptop, &id.master(), &base, &junk_kp(i).peer_id(), &[]));
        }
        let merged = r.reverified().merged(&flood.verified(NOW));
        assert!(merged.removals.contains(&phones), "the phone's removal fell out");
        assert!(!merged.reverified().fold(|_| None, 0).is_member(&laptop.peer_id()));
        assert!(!merged.reverified().authority().counts(&laptop.peer_id()));
    }

    /// I5 (N1): the thief floods removals OF the root, alone or through its puppets; the
    /// root's removal of the thief keeps its slot.
    #[test]
    fn a_thief_flood_never_pushes_out_the_roots_removal_of_it() {
        let id = Id::new();
        let (root, thief) = (kp(10), kp(66));
        let mut r = linked_to(&id, &root, &[&thief]);
        let base = r.base();
        let roots_removal = sign_removal(&root, &id.master(), &base, &thief.peer_id(), &[]);
        r.add_removal(roots_removal.clone());
        let mut alone = r.clone();
        let mut puppets = r.clone();
        for i in 0..(MAX_REMOVALS as u32 + MAX_RESERVED as u32 + 4) {
            let keep = [junk_kp(20_000 + i).peer_id()];
            alone.removals.push(sign_removal(&thief, &id.master(), &base, &root.peer_id(), &keep));
            let p = junk_kp(30_000 + i);
            puppets.consents.push(sign_consent(&p, &id.master()));
            puppets.vouches.push(sign_vouch(&thief, &id.master(), &base, &p.peer_id()));
            puppets.removals.push(sign_removal(&p, &id.master(), &base, &root.peer_id(), &[]));
        }
        for flood in [alone, puppets] {
            let merged = r.reverified().merged(&flood);
            assert!(merged.removals.contains(&roots_removal), "the root's removal of the thief was pushed out");
            let a = merged.reverified().authority();
            assert!(a.counts(&root.peer_id()) && !a.counts(&thief.peer_id()), "{a:?}");
        }
    }

    /// I6 (N1): the literal "best-ranked signer" would hold the slot with a removal the
    /// walk voids: removed x signs a removal of c and floods; h's removal of c stays.
    #[test]
    fn a_voided_best_signer_does_not_hold_the_reserved_slot() {
        let id = Id::new();
        let root = kp(10);
        let (x, h) = pair_by_id(kp(20), kp(21));
        let c = kp(22);
        let mut r = linked_to(&id, &root, &[&x, &h, &c]);
        let base = r.base();
        r.add_removal(sign_removal(&root, &id.master(), &base, &x.peer_id(), &[]));
        let hs = sign_removal(&h, &id.master(), &base, &c.peer_id(), &[]);
        r.add_removal(hs.clone());
        let mut flood = Roster::new(&id.master());
        flood.removals.push(sign_removal(&x, &id.master(), &base, &c.peer_id(), &[]));
        for i in 0..(MAX_REMOVALS as u32 + MAX_RESERVED as u32 + 4) {
            flood.removals.push(sign_removal(&x, &id.master(), &base, &junk_kp(40_000 + i).peer_id(), &[]));
        }
        let merged = r.reverified().merged(&flood);
        assert!(merged.removals.contains(&hs), "h's removal of c fell out");
        assert!(!merged.reverified().authority().counts(&c.peer_id()));
    }

    /// I7 (N1): with reserved slots in use, compaction is idempotent and keeps the walk.
    #[test]
    fn compaction_is_idempotent_and_keeps_the_walk() {
        let id = Id::new();
        let root = kp(10);
        let devs: Vec<NativeKeypair> = (0..24).map(|i| junk_kp(50_000 + i)).collect();
        let refs: Vec<&NativeKeypair> = devs.iter().collect();
        let mut full = linked_to(&id, &root, &refs);
        let base = full.base();
        for (i, d) in devs.iter().enumerate() {
            for k in 1..8 {
                full.removals.push(sign_removal(d, &id.master(), &base, &devs[(i + k) % devs.len()].peer_id(), &[]));
            }
            for k in 0..4u32 {
                full.removals.push(sign_removal(d, &id.master(), &base, &junk_kp(60_000 + i as u32 * 10 + k).peer_id(), &[]));
            }
        }
        let once = full.reverified();
        assert_eq!(once.reverified(), once, "compaction is not idempotent");
        assert!(once.removals.len() > MAX_REMOVALS, "reserved slots in use: {}", once.removals.len());
        assert!(same_authority(&once) == same_authority(&full), "compaction changed the walk");
    }

    /// I8: every reserved slot and the general pool full, 16-entry keeps, still fits.
    #[test]
    fn the_largest_roster_with_reserved_slots_fits_on_the_wire() {
        let id = Id::new();
        let devs: Vec<NativeKeypair> = (0..140).map(junk_kp).collect();
        let ids: Vec<String> = devs.iter().map(|d| d.peer_id()).collect();
        let mut r = Roster::new(&id.master());
        for d in &devs {
            r.consents.push(sign_consent(d, &id.master()));
        }
        r.r_pub = r_pub_of(&id.r);
        for t in 0..6 {
            let keep: Vec<String> = ids.iter().skip(t * 10).take(MAX_KEEP).cloned().collect();
            r.recoveries.push(sign_recovery(&id.m, &id.r, NOW - 100, &keep, t % 2 == 0));
        }
        let base = r.verified(NOW).base();
        for (i, d) in devs.iter().enumerate().take(80) {
            r.phrase_admits.push(sign_phrase_admit(&id.m, &id.r, NOW - 50 + i as i64, &d.peer_id()));
            r.pendings.push(sign_pending(&id.m, &base, &ids[139 - i]));
        }
        for (i, by) in devs.iter().enumerate() {
            for k in 0..3 {
                let target = &ids[(i + k + 1) % ids.len()];
                r.vouches.push(sign_vouch(by, &id.master(), &base, target));
                let keep: Vec<String> = ids.iter().skip(i + k).take(MAX_REMOVAL_KEEP).cloned().collect();
                r.removals.push(sign_removal(by, &id.master(), &base, target, &keep));
            }
        }
        let top = r.verified(NOW).ranked(true).into_values().min().unwrap().2;
        let top_kp = devs.iter().find(|d| d.peer_id() == top).unwrap();
        for (j, t) in ids.iter().enumerate().filter(|(_, t)| **t != top) {
            let keep: Vec<String> = ids.iter().skip(j).take(MAX_REMOVAL_KEEP).cloned().collect();
            r.removals.push(sign_removal(top_kp, &id.master(), &base, t, &keep));
        }
        let v = r.verified(NOW);
        assert_eq!(v.removals.len(), MAX_REMOVALS + MAX_RESERVED);
        assert!(v.within_caps());
        let bytes = serde_json::to_vec(&v).unwrap().len();
        assert!(bytes <= MAX_ROSTER_BYTES, "the largest roster is {bytes} bytes");
    }

    /// I12 (G1): the bare master id counts only where the statements count it.
    #[test]
    fn the_bare_master_counts_only_where_its_statements_do() {
        let id = Id::new();
        let owner = kp(10);
        let r = linked_to(&id, &owner, &[]);
        assert!(!r.verified(NOW).authority().counts(&id.master()));
        let mut claimed = r.clone();
        with_consent(&mut claimed, &id.m);
        claimed.add_vouch(sign_vouch(&owner, &id.master(), &r.base(), &id.master()));
        assert!(claimed.verified(NOW).authority().counts(&id.master()), "a vouched master device counts");
    }

    /// I13 (N2): a deep thief that removes everything above it and itself empties the
    /// walk; one removal by the root undoes it.
    #[test]
    fn a_deep_thief_that_empties_the_walk_is_undone_by_the_root() {
        let id = Id::new();
        let (root, mid, thief) = (kp(10), kp(30), kp(31));
        let mut r = linked_to(&id, &root, &[&mid]);
        let base = r.base();
        with_consent(&mut r, &thief);
        r.add_vouch(sign_vouch(&mid, &id.master(), &base, &thief.peer_id()));
        for t in [&root, &mid, &thief] {
            r.add_removal(sign_removal(&thief, &id.master(), &base, &t.peer_id(), &[]));
        }
        assert!(r.reverified().authority().counted.is_empty());
        r.add_removal(sign_removal(&root, &id.master(), &base, &thief.peer_id(), &[]));
        let a = r.reverified().authority();
        assert!(a.counts(&root.peer_id()) && a.counts(&mid.peer_id()), "{a:?}");
    }

    /// I15 (R3-1, compaction layer): a removed thief's puppet that walks before honest h
    /// removes h and floods; h's removal of c keeps its reserved slot.
    #[test]
    fn the_compaction_walk_ignores_a_removed_thiefs_puppet() {
        let id = Id::new();
        let root = kp(10);
        let (thief, a, c) = (kp(66), kp(30), kp(31));
        let (p, h) = pair_by_id(junk_kp(91_001), kp(32));
        let mut r = linked_to(&id, &root, &[&thief, &a, &c]);
        let base = r.base();
        with_consent(&mut r, &h);
        r.add_vouch(sign_vouch(&a, &id.master(), &base, &h.peer_id()));
        r.add_removal(sign_removal(&root, &id.master(), &base, &thief.peer_id(), &[]));
        let hs = sign_removal(&h, &id.master(), &base, &c.peer_id(), &[]);
        r.add_removal(hs.clone());
        let mut flood = Roster::new(&id.master());
        with_consent(&mut flood, &p);
        flood.vouches.push(sign_vouch(&thief, &id.master(), &base, &p.peer_id()));
        flood.removals.push(sign_removal(&p, &id.master(), &base, &h.peer_id(), &[]));
        for i in 0..(MAX_REMOVALS as u32 + MAX_RESERVED as u32 + 4) {
            flood.removals.push(sign_removal(&p, &id.master(), &base, &junk_kp(50_000 + i).peer_id(), &[]));
        }
        let full = {
            let mut u = r.clone();
            u.consents.extend(flood.consents.clone());
            u.vouches.extend(flood.vouches.clone());
            u.removals.extend(flood.removals.clone());
            u
        };
        let uncapped = full.authority();
        assert!(!uncapped.counts(&c.peer_id()) && uncapped.counts(&h.peer_id()), "uncapped: {uncapped:?}");
        let merged = r.reverified().merged(&flood);
        assert!(merged.removals.contains(&hs), "h's removal of c fell out");
        assert!(!merged.reverified().authority().counts(&c.peer_id()), "c counts again after compaction");
    }

    /// I19 (R31-7): the subset alone places the device and fits a join box, and a member
    /// holding a removal the subset leaves out still refuses the device.
    #[test]
    fn the_placing_subset_places_the_device_and_fits_the_box() {
        let id = Id::new();
        let (root, laptop, tablet, phone) = (kp(10), kp(11), kp(12), kp(13));
        let mut r = linked_to(&id, &root, &[&laptop]);
        let base = r.base();
        for (by, d) in [(&laptop, &tablet), (&tablet, &phone)] {
            with_consent(&mut r, d);
            r.add_vouch(sign_vouch(by, &id.master(), &base, &d.peer_id()));
        }
        for i in 0..40 {
            let j = junk_kp(95_000 + i);
            with_consent(&mut r, &j);
            r.add_vouch(sign_vouch(&root, &id.master(), &base, &j.peer_id()));
        }
        let held = r.verified(NOW);
        let subset = held.placing_subset(&phone.peer_id()).expect("the phone is counted");
        let alone = subset.verified(NOW);
        assert_eq!(alone, subset, "every statement of the subset verifies alone");
        assert!(alone.authority().counts(&phone.peer_id()), "the subset alone places the phone");
        assert_eq!(subset.vouches.len(), 3, "only the chain root -> laptop -> tablet -> phone");
        let bytes = serde_json::to_vec(&subset).unwrap().len();
        assert!(bytes <= 8 * 1024, "the subset is {bytes} bytes");
        let mut member_view = held.clone();
        member_view.add_removal(sign_removal(&root, &id.master(), &base, &phone.peer_id(), &[]));
        let judged = member_view.reverified().merged(&subset);
        assert!(!judged.authority().counts(&phone.peer_id()), "the subset hid a removal the member holds");
        let mut removed = held.clone();
        removed.add_removal(sign_removal(&root, &id.master(), &base, &phone.peer_id(), &[]));
        assert!(removed.reverified().placing_subset(&phone.peer_id()).is_none(), "an uncounted device has no subset");
    }

    /// N1 item 3: past 32 walk-first removals the SHALLOWEST targets keep their slots. The
    /// root removes 40 depth-2 devices; deep d removes depth-1 x; busy a floods the general
    /// pool ahead of d. Slots by signer rank would go to the root's removals and x would
    /// count again.
    pub(crate) fn shallowest_targets_case(id: &Id) -> (Roster, Roster, String) {
        let (root, a, x, b, d) = (kp(10), kp(11), kp(12), kp(13), kp(14));
        let mut held = linked_to(id, &root, &[&a, &x]);
        let base = held.base();
        for (by, dev) in [(&a, &b), (&b, &d)] {
            with_consent(&mut held, dev);
            held.add_vouch(sign_vouch(by, &id.master(), &base, &dev.peer_id()));
        }
        for i in 0..40 {
            let v = junk_kp(96_000 + i);
            with_consent(&mut held, &v);
            held.add_vouch(sign_vouch(&a, &id.master(), &base, &v.peer_id()));
            held.add_removal(sign_removal(&root, &id.master(), &base, &v.peer_id(), &[]));
        }
        held.add_removal(sign_removal(&d, &id.master(), &base, &x.peer_id(), &[]));
        let mut shown = held.clone();
        for i in 0..(MAX_REMOVALS as u32 + 8) {
            held.removals.push(sign_removal(&a, &id.master(), &base, &junk_kp(97_000 + i).peer_id(), &[]));
            shown.removals.push(sign_removal(&a, &id.master(), &base, &junk_kp(98_000 + i).peer_id(), &[]));
        }
        (held, shown, x.peer_id())
    }

    #[test]
    fn the_reserved_slots_go_to_the_shallowest_targets() {
        let id = Id::new();
        let (held, shown, x) = shallowest_targets_case(&id);
        let uncapped = { let mut u = held.clone(); u.removals.extend(shown.removals.iter().cloned()); u };
        assert!(!uncapped.authority().counts(&x), "precondition: d's removal of x counts");
        let merged = held.verified(NOW).merged(&shown.verified(NOW));
        assert!(merged.removals.len() > MAX_REMOVALS, "reserved slots in use");
        assert!(!merged.authority().counts(&x), "x counts again after compaction");
        assert!(same_authority(&merged) == same_authority(&uncapped), "compaction changed the walk");
    }

    /// A waiting device's removal of q, then a counted device's flood of removals all
    /// ranked ahead of it: (held, the flood, q's removal).
    pub(crate) fn pending_reserved_case() -> (Roster, Roster, Removal) {
        let id = Id::new();
        let m = id.master();
        let (root, d, q, p) = (kp(10), kp(11), kp(12), kp(13));
        let mut r = Roster::genesis(&id.m, &id.r, &root, NOW - 10);
        let base = r.base();
        for x in [&d, &q, &p] {
            with_consent(&mut r, x);
        }
        for x in [&d, &q] {
            r.add_vouch(sign_vouch(&root, &m, &base, &x.peer_id()));
        }
        r.add_pending(sign_pending(&id.m, &base, &p.peer_id()));
        let kept = sign_removal(&p, &m, &base, &q.peer_id(), &[]);
        r.add_removal(kept.clone());
        let held = r.verified(NOW);
        let mut flood = held.clone();
        for i in 0..(MAX_REMOVALS as u32 + 8) {
            flood.removals.push(sign_removal(&d, &m, &base, &junk_kp(40_000 + i).peer_id(), &[]));
        }
        (held, flood.verified(NOW), kept)
    }

    /// A waiting device's removal holds a reserved slot: the flood never pushes it out
    /// (the wide walk keeps more).
    #[test]
    fn a_pending_joins_removal_keeps_its_reserved_slot() {
        let (held, flood, kept) = pending_reserved_case();
        let merged = held.merged(&flood);
        assert!(merged.removals.len() >= MAX_REMOVALS, "setup: the general pool is full");
        assert!(merged.removals.contains(&kept), "the waiting device's removal was flooded out");
    }

    /// A waiting device's vouchee s removes q. s ranks through a (p2 -> a -> s), but
    /// another waiting device removed a first, so in the wide walk s is alive only
    /// through z (p1 -> y -> z -> s), a vouch no tree keeps. Vouch and removal floods
    /// from counted devices fill both pools: (held = the flood compacted once, a second
    /// flood shown, z's vouch of s, s's removal of q).
    pub(crate) fn wide_support_case() -> (Roster, Roster, Vouch, Removal) {
        let id = Id::new();
        let m = id.master();
        let (root, d, q, p1, p2, pk, y, z, a, s) = (kp(10), kp(11), kp(12), kp(13), kp(14), kp(15), kp(16), kp(17), kp(18), kp(19));
        let mut r = Roster::genesis(&id.m, &id.r, &root, NOW - 10);
        let base = r.base();
        for x in [&d, &q, &p1, &p2, &pk, &y, &z, &a, &s] {
            with_consent(&mut r, x);
        }
        for x in [&d, &q] {
            r.add_vouch(sign_vouch(&root, &m, &base, &x.peer_id()));
        }
        for x in [&p1, &p2, &pk] {
            r.add_pending(sign_pending(&id.m, &base, &x.peer_id()));
        }
        for (by, to) in [(&p1, &y), (&y, &z), (&p2, &a), (&a, &s)] {
            r.add_vouch(sign_vouch(by, &m, &base, &to.peer_id()));
        }
        let zs = sign_vouch(&z, &m, &base, &s.peer_id());
        r.add_vouch(zs.clone());
        r.add_removal(sign_removal(&pk, &m, &base, &a.peer_id(), &[]));
        let kept = sign_removal(&s, &m, &base, &q.peer_id(), &[]);
        r.add_removal(kept.clone());
        let flood = |r: &Roster, from: u32| {
            let mut f = r.clone();
            for i in 0..(MAX_VOUCHES as u32 + 8) {
                f.vouches.push(sign_vouch(&root, &m, &base, &junk_kp(from + i).peer_id()));
            }
            for i in 0..(MAX_REMOVALS as u32 + 8) {
                f.removals.push(sign_removal(&d, &m, &base, &junk_kp(from + 1000 + i).peer_id(), &[]));
            }
            f.verified(NOW)
        };
        (flood(&r, 50_000), flood(&r, 60_000), zs, kept)
    }

    /// The root removes x, which only a pending join vouched: (the roster, x).
    pub(crate) fn pending_vouchee_removal_case() -> (Roster, String) {
        let id = Id::new();
        let m = id.master();
        let (root, p, x) = (kp(10), kp(13), kp(16));
        let mut r = Roster::genesis(&id.m, &id.r, &root, NOW - 10);
        let base = r.base();
        for d in [&p, &x] {
            with_consent(&mut r, d);
        }
        r.add_pending(sign_pending(&id.m, &base, &p.peer_id()));
        r.add_vouch(sign_vouch(&p, &m, &base, &x.peer_id()));
        r.add_removal(sign_removal(&root, &m, &base, &x.peer_id(), &[]));
        (r.verified(NOW), x.peer_id())
    }

    /// Section 4: the walk's targets are founded devices and consented pending joins, so
    /// a device only a pending join vouched is not removed yet; the removal is held and
    /// counts once that device is founded.
    #[test]
    fn a_device_only_a_pending_join_vouched_is_no_removal_target_yet() {
        let (r, x) = pending_vouchee_removal_case();
        assert!(r.removals.iter().any(|rm| rm.device == x), "setup: the removal is held");
        let auth = r.reverified().authority();
        assert!(!auth.removed.contains_key(&x), "a device nothing founded was removed");
        assert!(auth.counted_removals.is_empty());
    }

    /// The wide walk's support stays: without it the first compaction keeps s's removal
    /// in a reserved slot but drops the only vouch that keeps s alive in the walk, and
    /// the next compaction loses the removal.
    #[test]
    fn the_wide_walks_support_keeps_a_waiting_signers_path() {
        let (held, shown, zs, kept) = wide_support_case();
        assert_eq!(held.vouches.len(), MAX_VOUCHES, "setup: the vouch pool is full");
        assert_eq!(held.clone().compacted(), held, "compacting a compacted roster changed it");
        let merged = held.merged(&shown);
        assert!(merged.vouches.contains(&zs), "the only live path of a waiting signer was flooded out");
        assert!(merged.removals.contains(&kept), "the waiting signer's removal lost its reserved slot");
        assert_eq!(merged.clone().compacted(), merged);
    }
}
