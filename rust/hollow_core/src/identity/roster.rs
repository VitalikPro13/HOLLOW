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
/// Per-kind ceilings on what one roster carries. Only a member can mint vouches and
/// removals, and a flood ends with the next recovery, which drops them all.
const MAX_DEVICE_STATEMENTS: usize = 256;
const MAX_PENDING: usize = 16;
const MAX_KEEP: usize = 64;
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
#[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub(crate) struct Recovery {
    #[serde(default)]
    pub at_ms: i64,
    #[serde(default)]
    pub keep: Vec<String>,
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

pub(crate) fn recovery_payload(master: &str, r_pub: &str, at_ms: i64, keep: &[String]) -> String {
    format!("hollow-id1-recovery:{master}:{r_pub}:{at_ms}:{}", sorted(keep).join(","))
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
    let payload = recovery_payload(master, r_pub, rec.at_ms, &rec.keep);
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
) -> Recovery {
    let payload = recovery_payload(&master.peer_id(), &r_pub_of(recovery), at_ms, keep);
    Recovery {
        at_ms,
        keep: sorted(keep),
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

fn push_unique<T: Ord + Clone>(into: &mut Vec<T>, from: &[T]) {
    into.extend_from_slice(from);
    into.sort();
    into.dedup();
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
        r.recoveries.push(sign_recovery(master, recovery, now_ms, &[device.peer_id()]));
        r
    }

    fn master_key(&self) -> Option<[u8; 32]> {
        key_of(&self.master)
    }

    fn r_key(&self) -> Option<[u8; 32]> {
        let bytes = B64.decode(&self.r_pub).ok()?;
        <[u8; 32]>::try_from(bytes.as_slice()).ok()
    }

    /// Only the statements that verify for this master. Phrase statements verify
    /// against `r_pub`, which is cleared when none does; anything dated more than
    /// the skew past `now_ms` is dropped.
    pub(crate) fn verified(&self, now_ms: i64) -> Roster {
        let Some(mk) = self.master_key() else { return Roster::default() };
        let m = self.master.as_str();
        let mut out = Roster::new(m);
        let fresh = |at: i64| at <= now_ms.saturating_add(MAX_FUTURE_SKEW_MS);
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
                            let p = recovery_payload(m, r_pub, rec.at_ms, &keep);
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
                    && keep.len() <= MAX_KEEP
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

    /// The newest recovery (ties: the lowest base id) with the union of the keep sets
    /// that share its time, and its base id.
    fn current_recovery(&self) -> Option<(String, i64, BTreeSet<String>)> {
        let newest = self.recoveries.iter().map(|r| r.at_ms).max()?;
        let ties: Vec<&Recovery> = self.recoveries.iter().filter(|r| r.at_ms == newest).collect();
        let base = ties
            .iter()
            .map(|r| base_id(&self.master, &self.r_pub, r))
            .min()?;
        let keep = ties.iter().flat_map(|r| r.keep.iter().cloned()).collect();
        Some((base, newest, keep))
    }

    /// The base every new device statement must name.
    pub(crate) fn base(&self) -> String {
        self.current_recovery()
            .map(|(b, _, _)| b)
            .unwrap_or_else(|| LEGACY_BASE.to_string())
    }

    /// Everything superseded by the current base dropped, statements sorted, and the
    /// per-kind ceilings applied.
    fn compacted(mut self) -> Roster {
        let current = self.current_recovery();
        match &current {
            Some((base, at, _)) => {
                self.recoveries.retain(|r| r.at_ms == *at);
                self.phrase_admits.retain(|p| p.at_ms > *at);
                self.legacy.clear();
                self.vouches.retain(|v| &v.base == base);
                self.pendings.retain(|p| &p.base == base);
                self.removals.retain(|r| &r.base == base);
            }
            None => {
                self.vouches.retain(|v| v.base == LEGACY_BASE);
                self.pendings.retain(|p| p.base == LEGACY_BASE);
                self.removals.retain(|r| r.base == LEGACY_BASE);
            }
        }
        self.vouches.sort();
        self.vouches.dedup();
        self.vouches.truncate(MAX_DEVICE_STATEMENTS);
        self.removals.sort();
        self.removals.dedup();
        self.removals.truncate(MAX_DEVICE_STATEMENTS);
        self.pendings.sort();
        self.pendings.dedup();
        self.pendings.truncate(MAX_PENDING);
        self.legacy.sort();
        self.legacy.dedup();
        self.legacy.truncate(MAX_DEVICE_STATEMENTS);
        self.phrase_admits.sort();
        self.phrase_admits.dedup();
        self.phrase_admits.truncate(MAX_DEVICE_STATEMENTS);
        self.recoveries.sort();
        self.recoveries.dedup();

        let mentioned: BTreeSet<&str> = self
            .recoveries
            .iter()
            .flat_map(|r| r.keep.iter().map(String::as_str))
            .chain(self.phrase_admits.iter().map(|p| p.device.as_str()))
            .chain(self.vouches.iter().flat_map(|v| [v.device.as_str(), v.by.as_str()]))
            .chain(self.pendings.iter().map(|p| p.device.as_str()))
            .chain(self.legacy.iter().map(|l| l.device.as_str()))
            .chain(self.removals.iter().flat_map(|r| [r.device.as_str(), r.by.as_str()]))
            .collect();
        let mentioned: BTreeSet<String> = mentioned.into_iter().map(str::to_string).collect();
        // A consent may arrive ahead of the statement that names its device, so a few
        // unnamed ones stay; anyone can mint them, so only a few.
        self.consents.sort();
        self.consents.dedup_by(|a, b| a.device == b.device);
        let (named, unnamed): (Vec<Consent>, Vec<Consent>) =
            std::mem::take(&mut self.consents).into_iter().partition(|c| mentioned.contains(&c.device));
        self.consents = named;
        self.consents.extend(unnamed.into_iter().take(MAX_UNNAMED_CONSENTS));
        self.consents.sort();
        self
    }

    /// Who belongs to this identity now, for one observer. `first_seen` is when this
    /// observer first saw a device's pending join, the clock its seven days run on.
    /// The roster must already be `verified`.
    pub(crate) fn fold(&self, first_seen: impl Fn(&str) -> Option<i64>, now_ms: i64) -> RosterState {
        let consented: BTreeSet<&str> = self.consents.iter().map(|c| c.device.as_str()).collect();
        let (base, protected, mut roots): (String, bool, BTreeSet<String>) =
            match self.current_recovery() {
                Some((base, at, keep)) => {
                    let mut roots = keep;
                    roots.extend(self.phrase_admits.iter().filter(|p| p.at_ms > at).map(|p| p.device.clone()));
                    (base, true, roots)
                }
                None => {
                    let mut roots: BTreeSet<String> =
                        self.legacy.iter().map(|l| l.device.clone()).collect();
                    roots.extend(self.phrase_admits.iter().map(|p| p.device.clone()));
                    (LEGACY_BASE.to_string(), false, roots)
                }
            };
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
        let matured: BTreeSet<String> = pendings
            .iter()
            .filter(|p| {
                first_seen(&p.device)
                    .is_some_and(|seen| seen.saturating_add(PENDING_MATURITY_MS) <= now_ms)
            })
            .map(|p| p.device.clone())
            .collect();

        // Everyone with any admission path, removals ignored: who may sign a removal.
        let mut rooted: BTreeSet<String> = roots.union(&matured).cloned().collect();
        loop {
            let before = rooted.len();
            for v in &vouches {
                if rooted.contains(&v.by) {
                    rooted.insert(v.device.clone());
                }
            }
            if rooted.len() == before {
                break;
            }
        }

        let asked: BTreeSet<&str> = pendings.iter().map(|p| p.device.as_str()).collect();
        let mut removed: BTreeMap<String, String> = BTreeMap::new();
        let mut kept_by: BTreeMap<&str, BTreeSet<&str>> = BTreeMap::new();
        for r in self.removals.iter().filter(|r| r.base == base && rooted.contains(&r.by)) {
            if !rooted.contains(&r.device) && !asked.contains(r.device.as_str()) {
                continue;
            }
            removed.entry(r.device.clone()).or_insert_with(|| r.by.clone());
            kept_by
                .entry(r.device.as_str())
                .or_default()
                .extend(r.keep_vouched.iter().map(String::as_str));
        }

        // A removed voucher's vouches count only where its remover kept them.
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
        RosterState { base, protected, members, removed, pending }
    }

    /// Current members that `device` vouched for, the set an honest remover keeps.
    pub(crate) fn vouched_members_of(&self, device: &str, state: &RosterState) -> Vec<String> {
        let base = &state.base;
        self.vouches
            .iter()
            .filter(|v| &v.base == base && v.by == device && state.members.contains(&v.device))
            .map(|v| v.device.clone())
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

        let rec = sign_recovery(&id.m, &id.r, NOW, &[owner.peer_id()]);
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

        let rec = sign_recovery(&id.m, &id.r, NOW, &[d1.peer_id()]);
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

    #[test]
    fn a_far_future_phrase_statement_is_dropped() {
        let id = Id::new();
        let d = kp(10);
        let r = Roster::genesis(&id.m, &id.r, &d, NOW + MAX_FUTURE_SKEW_MS + 1);
        assert!(r.verified(NOW).recoveries.is_empty());
    }
}
