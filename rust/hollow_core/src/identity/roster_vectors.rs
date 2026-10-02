//! The vectors the relay's roster mirror is checked against (design ID-1R).
//!
//! Each case is one roster shown on an `inbox:` join, run through the relay's flow on
//! the Rust code: verify, merge into the held roster, stamp first sights, fold, judge
//! one device. `relay-uws/test/test_roster.cpp` runs every case through
//! `relay-uws/src/roster_book.h` and must land on the same bytes. The cases are seeded,
//! so the file only changes when the rules do: regenerate with
//! `HOLLOW_WRITE_ROSTER_VECTORS=1 cargo test --lib roster_vectors`.

use std::collections::BTreeMap;

use serde::Serialize;
use sha2::{Digest, Sha256};

use super::native_identity::NativeKeypair;
use super::roster::*;

const NOW: i64 = 1_800_000_000_000;
const DAY: i64 = 24 * 60 * 60 * 1000;

fn kp(tag: u8) -> NativeKeypair {
    NativeKeypair::from_secret_bytes(&[tag; 32])
}

fn junk_kp(i: u32) -> NativeKeypair {
    let mut seed = [0x5au8; 32];
    seed[..4].copy_from_slice(&i.to_le_bytes());
    NativeKeypair::from_secret_bytes(&seed)
}

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
    fn chance(&mut self, percent: u64) -> bool {
        self.below(100) < percent
    }
    fn pick<'a, T>(&mut self, v: &'a [T]) -> &'a T {
        &v[self.below(v.len() as u64) as usize]
    }
}

struct Keys {
    m: NativeKeypair,
    r: NativeKeypair,
    fake_r: NativeKeypair,
    devices: Vec<NativeKeypair>,
    stranger: NativeKeypair,
}

impl Keys {
    fn new() -> Self {
        Keys { m: kp(1), r: kp(2), fake_r: kp(3), devices: (0..10).map(|i| kp(10 + i)).collect(), stranger: kp(90) }
    }
    fn master(&self) -> String {
        self.m.peer_id()
    }
    /// Mostly the first few devices, which the random rosters tend to root, so the
    /// cases reach the rules that need standing.
    fn device<'a>(&'a self, rng: &mut Rng) -> &'a NativeKeypair {
        if rng.chance(65) { rng.pick(&self.devices[..4]) } else { rng.pick(&self.devices) }
    }
    fn signer<'a>(&'a self, rng: &mut Rng) -> &'a NativeKeypair {
        if rng.chance(10) { &self.stranger } else { self.device(rng) }
    }
    fn ids(&self, rng: &mut Rng, max: u64) -> Vec<String> {
        let n = rng.below(max + 1);
        (0..n).map(|_| self.device(rng).peer_id()).collect()
    }
}

/// A base a statement may name: mostly the current one, sometimes legacy, another
/// base or no base at all.
fn some_base(rng: &mut Rng, current: &str) -> String {
    match rng.below(10) {
        0 => LEGACY_BASE.to_string(),
        1 => format!("{:032x}", rng.next() as u128 * 7),
        2 => "Not-A-Base".to_string(),
        _ => current.to_string(),
    }
}

/// Sometimes the right signature, sometimes another key's, sometimes a tampered one.
fn sig_or_wrong(rng: &mut Rng, right: String, wrong: String) -> String {
    match rng.below(12) {
        0 => wrong,
        1 => {
            let mut s = right.into_bytes();
            s[3] = if s[3] == b'A' { b'B' } else { b'A' };
            String::from_utf8(s).unwrap()
        }
        _ => right,
    }
}

fn random_roster(rng: &mut Rng, k: &Keys) -> Roster {
    let m = k.master();
    let mut r = Roster::new(&m);
    if rng.chance(65) {
        let rk = if rng.chance(85) { &k.r } else { &k.fake_r };
        r.r_pub = r_pub_of(rk);
        for _ in 0..rng.below(3) {
            let at = NOW - DAY + rng.below(3) as i64 * 1000;
            let mut keep = k.ids(rng, 4);
            if keep.is_empty() {
                keep.push(k.devices[0].peer_id());
            }
            let mut rec = sign_recovery(&k.m, rk, at, &keep, rng.chance(25));
            match rng.below(14) {
                0 => rec.at_ms = NOW + 60 * 60 * 1000,
                1 => rec.keep.reverse(),
                2 => rec.sig_r = sign_recovery(&k.m, &k.fake_r, at, &keep, rec.no_wait).sig_r,
                3 => rec.no_wait = !rec.no_wait,
                _ => {}
            }
            r.recoveries.push(rec);
        }
        for _ in 0..rng.below(3) {
            let at = NOW - DAY + rng.below(5) as i64 * 1000 - 2000;
            let d = rng.pick(&k.devices).peer_id();
            r.phrase_admits.push(sign_phrase_admit(&k.m, rk, at, &d));
        }
    }
    let base = r.clone().verified(NOW).base();
    for d in &k.devices {
        if rng.chance(70) {
            let mut c = sign_consent(d, &m);
            c.sig = sig_or_wrong(rng, c.sig, sign_consent(&k.stranger, &m).sig);
            r.consents.push(c);
        }
    }
    if rng.chance(30) {
        r.consents.push(sign_consent(&k.stranger, &m));
    }
    for _ in 0..rng.below(7) {
        let by = k.signer(rng);
        let d = rng.pick(&k.devices).peer_id();
        let b = some_base(rng, &base);
        let mut v = sign_vouch(by, &m, &b, &d);
        v.sig = sig_or_wrong(rng, v.sig, sign_vouch(&k.stranger, &m, &b, &d).sig);
        r.vouches.push(v);
    }
    for _ in 0..rng.below(3) {
        let d = rng.pick(&k.devices).peer_id();
        let b = some_base(rng, &base);
        let mut p = sign_pending(&k.m, &b, &d);
        if rng.chance(15) {
            p.sig_m = sign_pending(&k.stranger, &b, &d).sig_m;
        }
        r.pendings.push(p);
    }
    for _ in 0..rng.below(3) {
        let d = rng.pick(&k.devices).peer_id();
        let mut l = sign_legacy(&k.m, &d);
        l.sig_m = sig_or_wrong(rng, l.sig_m, sign_legacy(&k.stranger, &d).sig_m);
        r.legacy.push(l);
    }
    for _ in 0..rng.below(6) {
        let by = k.signer(rng);
        let d = k.device(rng).peer_id();
        let b = some_base(rng, &base);
        let keep = k.ids(rng, 3);
        let mut x = sign_removal(by, &m, &b, &d, &keep);
        if rng.chance(8) {
            x.keep_vouched.reverse();
        }
        x.sig = sig_or_wrong(rng, x.sig, sign_removal(&k.stranger, &m, &b, &d, &keep).sig);
        r.removals.push(x);
    }
    r
}

/// A real identity: roots from the phrase (or legacy claims), devices each linked by
/// an earlier one, removals by members, pending joins, sometimes a forged statement.
fn structured(rng: &mut Rng, k: &Keys) -> Roster {
    let m = k.master();
    let d = &k.devices;
    let mut r = Roster::new(&m);
    for dev in d.iter().take(9) {
        if rng.chance(90) {
            r.add_consent(sign_consent(dev, &m));
        }
    }
    let roots: Vec<String> = d.iter().take(1 + rng.below(2) as usize).map(|x| x.peer_id()).collect();
    if rng.chance(70) {
        let rec = sign_recovery(&k.m, &k.r, NOW - 2 * DAY, &roots, rng.chance(20));
        r.add_phrase_statement(&r_pub_of(&k.r), Some(rec), None).unwrap();
    } else {
        for id in &roots {
            r.add_legacy(sign_legacy(&k.m, id));
        }
    }
    let base = r.base();
    for (i, dev) in d.iter().enumerate().take(6).skip(2) {
        let by = &d[rng.below(i as u64) as usize];
        r.add_vouch(sign_vouch(by, &m, &base, &dev.peer_id()));
    }
    for dev in d.iter().take(8).skip(6) {
        if rng.chance(60) {
            r.add_pending(sign_pending(&k.m, &base, &dev.peer_id()));
        }
    }
    for _ in 0..1 + rng.below(3) {
        let by = &d[rng.below(6) as usize];
        let target = d[rng.below(8) as usize].peer_id();
        let keep = k.ids(rng, 2);
        if target != by.peer_id() {
            r.add_removal(sign_removal(by, &m, &base, &target, &keep));
        }
    }
    if rng.chance(30) {
        let thief = &d[8];
        r.add_vouch(sign_vouch(thief, &m, &base, &d[9].peer_id()));
        r.add_removal(sign_removal(thief, &m, &base, &d[0].peer_id(), &[]));
    }
    r
}

/// The owner links a laptop and a thief's phone; the thief grows a tree of its own
/// devices that vouch and remove; the owner removes the thief. Past every ceiling.
fn flood(k: &Keys, n: u32) -> Roster {
    let m = k.master();
    let (owner, laptop, thief) = (&k.devices[0], &k.devices[1], &k.devices[2]);
    let mut r = Roster::genesis(&k.m, &k.r, owner, NOW - DAY);
    let base = r.base();
    for d in [laptop, thief] {
        r.add_consent(sign_consent(d, &m));
        r.add_vouch(sign_vouch(owner, &m, &base, &d.peer_id()));
    }
    for i in 0..n {
        let (j, q) = (junk_kp(i), junk_kp(10_000 + i));
        r.consents.push(sign_consent(&j, &m));
        r.consents.push(sign_consent(&q, &m));
        r.vouches.push(sign_vouch(thief, &m, &base, &j.peer_id()));
        r.removals.push(sign_removal(thief, &m, &base, &j.peer_id(), &[]));
        r.vouches.push(sign_vouch(&j, &m, &base, &q.peer_id()));
        r.removals.push(sign_removal(&j, &m, &base, &thief.peer_id(), &[q.peer_id()]));
    }
    r.removals.push(sign_removal(owner, &m, &base, &thief.peer_id(), &[]));
    r
}

#[derive(Serialize)]
struct Case {
    name: String,
    now_ms: i64,
    master: String,
    device: String,
    held: Option<Roster>,
    held_seen: BTreeMap<String, i64>,
    shown: Roster,
    accepted: bool,
    merged_sha256: String,
    merged_counts: [usize; 7],
    merged_r_pub: String,
    seen: BTreeMap<String, i64>,
    base: String,
    protected: bool,
    no_wait: bool,
    members: Vec<String>,
    removed: BTreeMap<String, String>,
    pending: Vec<String>,
    member: bool,
}

/// The relay's flow on one shown roster (`RosterBook::show`), in Rust.
fn relay_case(name: &str, now: i64, master: &str, device: &str, held: Option<(Roster, BTreeMap<String, i64>)>, shown: Roster) -> Case {
    let (base_roster, base_seen) = held.clone().unwrap_or_else(|| (Roster::new(master), BTreeMap::new()));
    let accepted = shown.master == master && shown.within_caps();
    let (merged, seen) = if accepted {
        let merged = base_roster.merged(&shown.verified(now));
        let seen: BTreeMap<String, i64> = merged
            .pendings
            .iter()
            .map(|p| (p.device.clone(), base_seen.get(&p.device).copied().unwrap_or(now)))
            .collect();
        (merged, seen)
    } else {
        (base_roster, base_seen.clone())
    };
    let state = merged.fold(|d| seen.get(d).copied(), now);
    let member = accepted && state.is_member(device);
    let json = serde_json::to_string(&merged).unwrap();
    Case {
        name: name.to_string(),
        now_ms: now,
        master: master.to_string(),
        device: device.to_string(),
        held: held.as_ref().map(|h| h.0.clone()),
        held_seen: held.map(|h| h.1).unwrap_or_default(),
        shown,
        accepted,
        merged_sha256: hex::encode(Sha256::digest(json.as_bytes())),
        merged_counts: [
            merged.recoveries.len(),
            merged.phrase_admits.len(),
            merged.consents.len(),
            merged.vouches.len(),
            merged.pendings.len(),
            merged.legacy.len(),
            merged.removals.len(),
        ],
        merged_r_pub: merged.r_pub.clone(),
        seen,
        base: state.base,
        protected: state.protected,
        no_wait: state.no_wait,
        members: state.members.into_iter().collect(),
        removed: state.removed,
        pending: state.pending.into_iter().collect(),
        member,
    }
}

fn cases() -> Vec<Case> {
    let k = Keys::new();
    let m = k.master();
    let mut rng = Rng(0x1d1_2026_1002);
    let mut out = Vec::new();
    for i in 0..70 {
        let device = k.signer(&mut rng).peer_id();
        let shown = random_roster(&mut rng, &k);
        let held = if rng.chance(50) {
            let prior = random_roster(&mut rng, &k).verified(NOW - DAY);
            let mut seen = BTreeMap::new();
            for p in &prior.pendings {
                if rng.chance(70) {
                    seen.insert(p.device.clone(), NOW - rng.below(10) as i64 * DAY);
                }
            }
            Some((prior, seen))
        } else {
            None
        };
        out.push(relay_case(&format!("random-{i}"), NOW, &m, &device, held, shown));
    }
    for i in 0..40 {
        let device = k.device(&mut rng).peer_id();
        let shown = structured(&mut rng, &k);
        let held = rng.chance(50).then(|| {
            let mut prior = shown.clone();
            prior.removals.clear();
            prior.vouches.truncate(rng.below(3) as usize);
            (prior.verified(NOW), BTreeMap::new())
        });
        out.push(relay_case(&format!("structured-{i}"), NOW, &m, &device, held, shown));
    }
    // Ceilings: a held roster at its caps, shown more of the same.
    let big = flood(&k, 70).verified(NOW);
    let more = flood(&k, 110);
    let mut more_small = Roster::new(&m);
    more_small.r_pub = more.r_pub.clone();
    more_small.recoveries = more.recoveries.clone();
    more_small.vouches = more.vouches[140..200].to_vec();
    more_small.removals = more.removals[140..200].to_vec();
    more_small.consents = more.consents[140..200].to_vec();
    for d in [&k.devices[1], &k.devices[2]] {
        out.push(relay_case("flood-held-grows", NOW, &m, &d.peer_id(), Some((big.clone(), BTreeMap::new())), more_small.clone()));
    }
    let mut over = Roster::new(&m);
    for i in 0..(MAX_PENDING as u32 + 1) {
        over.pendings.push(sign_pending(&k.m, LEGACY_BASE, &junk_kp(i).peer_id()));
    }
    out.push(relay_case("shown-past-a-ceiling", NOW, &m, &k.devices[0].peer_id(), None, over));
    out.push(relay_case("another-master", NOW, &kp(4).peer_id(), &k.devices[0].peer_id(), None, flood(&k, 1)));
    // Seven quiet days at the relay, and the phrase turning them off.
    let mut asking = Roster::genesis(&k.m, &k.r, &k.devices[0], NOW - 9 * DAY);
    let base = asking.base();
    asking.add_consent(sign_consent(&k.devices[5], &m));
    asking.add_pending(sign_pending(&k.m, &base, &k.devices[5].peer_id()));
    let waited = BTreeMap::from([(k.devices[5].peer_id(), NOW - 8 * DAY)]);
    let held = Some((asking.clone().verified(NOW), waited.clone()));
    out.push(relay_case("matured-at-the-relay", NOW, &m, &k.devices[5].peer_id(), held.clone(), asking.clone()));
    out.push(relay_case("first-sight-now", NOW, &m, &k.devices[5].peer_id(), None, asking.clone()));
    let mut strict = Roster::new(&m);
    strict.add_consent(sign_consent(&k.devices[0], &m));
    strict.add_consent(sign_consent(&k.devices[5], &m));
    strict.add_phrase_statement(&r_pub_of(&k.r), Some(sign_recovery(&k.m, &k.r, NOW - 9 * DAY, &[k.devices[0].peer_id()], true)), None).unwrap();
    let sbase = strict.base();
    strict.add_pending(sign_pending(&k.m, &sbase, &k.devices[5].peer_id()));
    out.push(relay_case("no-wait", NOW, &m, &k.devices[5].peer_id(), Some((strict.clone().verified(NOW), waited)), strict));
    out
}

#[test]
fn roster_vectors_are_current() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../relay-uws/test/roster_vectors.json");
    let cases = cases();
    let mut text = String::from("{\"cases\":[\n");
    for (i, c) in cases.iter().enumerate() {
        text.push_str(&serde_json::to_string(c).unwrap());
        text.push_str(if i + 1 < cases.len() { ",\n" } else { "\n" });
    }
    text.push_str("]}\n");
    if std::env::var_os("HOLLOW_WRITE_ROSTER_VECTORS").is_some() {
        std::fs::write(&path, &text).unwrap();
    }
    let held = std::fs::read_to_string(&path).unwrap_or_default().replace("\r\n", "\n");
    assert!(held == text, "relay-uws/test/roster_vectors.json is stale: rerun with HOLLOW_WRITE_ROSTER_VECTORS=1");
    // The vectors must exercise every rule, or the mirror proves little.
    let n = |f: &dyn Fn(&Case) -> bool| cases.iter().filter(|c| f(c)).count();
    assert!(n(&|c| c.member) >= 10, "too few members");
    assert!(n(&|c| c.accepted && !c.member) >= 20, "too few refusals");
    assert!(n(&|c| !c.removed.is_empty()) >= 10, "too few removals");
    assert!(n(&|c| c.protected) >= 20 && n(&|c| !c.protected) >= 20, "too few of either base");
    assert!(n(&|c| !c.pending.is_empty()) >= 5, "too few pending joins");
    assert!(n(&|c| c.merged_counts[3] == MAX_VOUCHES) >= 1 && n(&|c| c.merged_counts[6] == MAX_REMOVALS) >= 1);
    assert!(n(&|c| !c.accepted) >= 2);
}
