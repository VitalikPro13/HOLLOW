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
pub(crate) const MAX_REMOVAL_KEEP: usize = 16;
pub(crate) const MAX_KEEP: usize = 64;
const MAX_RECOVERY_TIES: usize = 4;
const MAX_PHRASE_ADMITS: usize = 64;
const MAX_LEGACY: usize = 64;
pub(crate) const MAX_PENDING: usize = 16;
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
        out.removals = self
            .removals
            .iter()
            .filter(|r| {
                let keep = sorted(&r.keep_vouched);
                is_base_shape(&r.base)
                    && id_ok(&r.device)
                    && keep == r.keep_vouched
                    && keep.len() <= MAX_REMOVAL_KEEP
                    && keep.iter().all(|d| id_ok(d))
                    && verify_by(&r.by, &removal_payload(m, &r.base, &r.device, &keep), &r.sig)
            })
            .cloned()
            .collect();
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
            && self.removals.len() <= MAX_REMOVALS
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
        let consented: BTreeSet<&str> = self.consents.iter().map(|c| c.device.as_str()).collect();
        let (_, roots) = self.base_roots();
        let mut vouchees: BTreeMap<&str, BTreeSet<&str>> = BTreeMap::new();
        for v in self.vouches.iter().filter(|v| consented.contains(v.device.as_str())) {
            vouchees.entry(v.by.as_str()).or_default().insert(v.device.as_str());
        }
        let seeds: [(u8, BTreeSet<&str>); 2] = [
            (0, roots.iter().map(String::as_str).filter(|d| consented.contains(d)).collect()),
            (1, self.pendings.iter().map(|p| p.device.as_str()).filter(|d| consented.contains(d)).collect()),
        ];
        let mut rank: BTreeMap<&str, (u8, u32)> = BTreeMap::new();
        for (tier, seed) in seeds {
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
        let mut ranked: Vec<Rank> = rank.into_iter().map(|(d, (tier, depth))| (tier, depth, d.to_string())).collect();
        ranked.sort();
        ranked.into_iter().map(|r| (r.2.clone(), r)).collect()
    }

    /// Everything superseded by the current base dropped, statements sorted, and the
    /// ceilings applied. A vouch or removal stays only when its signer stands, ordered
    /// by its signer's rank, whatever it names: a vouch may precede its device's
    /// consent, and a removal may precede the device's claim. Each standing device's
    /// best vouch stays first, so a compacted roster ranks the same when compacted again.
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

        let standing = self.standing();
        let rank = |d: &str| standing.get(d).cloned();

        let mut vouches: Vec<Vouch> = std::mem::take(&mut self.vouches)
            .into_iter()
            .filter(|v| standing.contains_key(&v.by))
            .collect();
        vouches.sort();
        vouches.dedup();
        vouches.sort_by_cached_key(|v| (rank(&v.by), v.clone()));
        let mut best: BTreeSet<&str> = BTreeSet::new();
        let (tree, rest): (Vec<&Vouch>, Vec<&Vouch>) = vouches
            .iter()
            .partition(|v| standing.contains_key(&v.device) && best.insert(v.device.as_str()));
        let mut kept: Vec<Vouch> = tree.into_iter().chain(rest).take(MAX_VOUCHES).cloned().collect();
        kept.sort();
        self.vouches = kept;

        let mut removals: Vec<Removal> = std::mem::take(&mut self.removals)
            .into_iter()
            .filter(|r| standing.contains_key(&r.by))
            .collect();
        removals.sort();
        removals.dedup();
        removals.sort_by_cached_key(|r| (rank(&r.by), r.clone()));
        removals.truncate(MAX_REMOVALS);
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

        // A removed device keeps only the vouchees EVERY removal of it keeps: a device
        // it vouched cannot keep itself by removing it too.
        let asked: BTreeSet<&str> = pendings.iter().map(|p| p.device.as_str()).collect();
        let mut removed: BTreeMap<String, String> = BTreeMap::new();
        let mut kept_by: BTreeMap<&str, BTreeSet<&str>> = BTreeMap::new();
        for r in self.removals.iter().filter(|r| r.base == base && rooted.contains(&r.by)) {
            if !rooted.contains(&r.device) && !asked.contains(r.device.as_str()) {
                continue;
            }
            removed.entry(r.device.clone()).or_insert_with(|| r.by.clone());
            let keep: BTreeSet<&str> = r.keep_vouched.iter().map(String::as_str).collect();
            kept_by
                .entry(r.device.as_str())
                .and_modify(|k| k.retain(|d| keep.contains(d)))
                .or_insert(keep);
        }

        // A removed voucher's vouches count only where its removers kept them.
        let mut valid: BTreeSet<String> = roots.union(&matured).cloned().collect();
        loop {
            let before = valid.len();
            for v in &vouches {
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
        RosterState { base, protected: current.is_some(), no_wait, members, removed, pending }
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
mod tests {
    use super::*;

    fn kp(tag: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[tag; 32])
    }

    const NOW: i64 = 1_800_000_000_000;

    struct Id {
        m: NativeKeypair,
        r: NativeKeypair,
    }

    impl Id {
        fn new() -> Self {
            Id { m: kp(1), r: kp(2) }
        }
        fn master(&self) -> String {
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
        assert!(v.vouches.len() <= MAX_VOUCHES && v.removals.len() <= MAX_REMOVALS);
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
        assert_eq!(v.removals.len(), MAX_REMOVALS);
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
}
