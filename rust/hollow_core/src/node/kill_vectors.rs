//! The vectors the relay's kill list judges a parked destruction order by (D5).
//!
//! An order the target identity's phrase stands behind gets a slot at the relay that
//! junk can never evict. Each case is one deposit: the roster the relay holds for the
//! order's master, the order as parked, the device it waits for, and whether the relay
//! may hold it as proven. `relay-uws/test/test_kill_order.cpp` runs every case through
//! `relay-uws/src/kill_order.h` and must agree. Seeded, so the file only changes when the
//! rules do: regenerate with `HOLLOW_WRITE_KILL_VECTORS=1 cargo test --lib kill_vectors`.

use std::collections::BTreeMap;

use serde::Serialize;

use crate::identity::native_identity::NativeKeypair;
use crate::identity::roster::*;
use super::crypto_handler::{
    build_delegated_destroy, build_destroy_identity, destroy_order_authorised, sign_destroy_delegation,
    verify_destroy_identity,
};
use super::destroy::encode_kill_blob;
use super::types::DestroyIdentity;

const NOW: i64 = 1_800_000_000_000;
const DAY: i64 = 24 * 60 * 60 * 1000;
const AT: i64 = NOW - 1000;

fn kp(tag: u8) -> NativeKeypair {
    NativeKeypair::from_secret_bytes(&[tag; 32])
}

#[derive(Serialize)]
struct Case {
    name: String,
    now_ms: i64,
    held: Option<Roster>,
    seen: BTreeMap<String, i64>,
    target: String,
    issued_at_ms: i64,
    blob: String,
    proven: bool,
}

/// The relay's question, answered with the client's own checks: the master signed it,
/// the phrase pinned in the held roster stands behind it, it names `target`, and
/// `target` itself consented to belong to that identity.
fn proven(order: &DestroyIdentity, issued_at_ms: i64, target: &str, held: Option<&Roster>, seen: &BTreeMap<String, i64>) -> bool {
    let Some(h) = held else { return false };
    let base = h.base();
    let state = h.fold(|d| seen.get(&format!("{base}|{d}")).copied(), NOW);
    order.master_peer_id == h.master
        && order.issued_at_ms == issued_at_ms
        && !h.r_pub.is_empty()
        && (order.targets.is_empty() || order.targets.iter().any(|t| t == target))
        && h.has_consent(target)
        && verify_destroy_identity(order)
        && destroy_order_authorised(order, &h.r_pub, &state)
}

fn case(name: &str, held: Option<&Roster>, seen: &BTreeMap<String, i64>, target: &NativeKeypair, order: &DestroyIdentity, issued_at_ms: i64) -> Case {
    let target = target.peer_id();
    Case {
        name: name.to_string(),
        now_ms: NOW,
        held: held.cloned(),
        seen: seen.clone(),
        proven: proven(order, issued_at_ms, &target, held, seen),
        target,
        issued_at_ms,
        blob: encode_kill_blob(order).unwrap(),
    }
}

fn flip(sig: &str) -> String {
    let mut s = sig.as_bytes().to_vec();
    s[3] = if s[3] == b'A' { b'B' } else { b'A' };
    String::from_utf8(s).unwrap()
}

fn cases() -> Vec<Case> {
    let (m, r, fake_r) = (kp(1), kp(2), kp(3));
    let d: Vec<NativeKeypair> = (0..6).map(|i| kp(10 + i)).collect();
    let (sm, sr, sd) = (kp(40), kp(41), kp(42));
    let mid = m.peer_id();

    // d0 roots the phrase, d1..d3 are vouched, d3 then removed, d4 waits, d5 never consented.
    let mut held = Roster::genesis(&m, &r, &d[0], NOW - 2 * DAY);
    let base = held.base();
    for dev in &d[1..5] {
        held.add_consent(sign_consent(dev, &mid));
    }
    for dev in &d[1..4] {
        held.add_vouch(sign_vouch(&d[0], &mid, &base, &dev.peer_id()));
    }
    held.add_pending(sign_pending(&m, &base, &d[4].peer_id()));
    held.add_removal(sign_removal(&d[0], &mid, &base, &d[3].peer_id(), &[]));
    let held = held.verified(NOW);
    let legacy = Roster::legacy_for_test(&m, &[&d[0], &d[1]]).verified(NOW);
    let stranger = Roster::genesis(&sm, &sr, &sd, NOW - DAY).verified(NOW);
    let none = BTreeMap::new();
    let matured = BTreeMap::from([(format!("{base}|{}", d[4].peer_id()), NOW - 8 * DAY)]);
    let h = Some(&held);

    let every = build_destroy_identity(&m, Some(&r), AT, vec![], false);
    let named = build_destroy_identity(&m, Some(&r), AT, vec![d[2].peer_id(), d[1].peer_id()], false);
    let mut out = vec![
        case("phrase-every-device-member", h, &none, &d[1], &every, AT),
        case("phrase-every-device-root", h, &none, &d[0], &every, AT),
        case("phrase-reaches-a-removed-device", h, &none, &d[3], &every, AT),
        case("phrase-reaches-a-pending-device", h, &none, &d[4], &every, AT),
        case("target-never-consented", h, &none, &d[5], &every, AT),
        case("named-among-several", h, &none, &d[2], &named, AT),
        case("target-not-named", h, &none, &d[3], &named, AT),
        case("stamp-differs-from-the-deposit", h, &none, &d[1], &every, AT + 1),
        case("no-roster-held", None, &none, &d[1], &every, AT),
        case("legacy-roster-pins-no-phrase", Some(&legacy), &none, &d[1], &every, AT),
        case("another-identity-holds-the-target", Some(&stranger), &none, &d[1], &every, AT),
        case("notify-friends", h, &none, &d[1], &build_destroy_identity(&m, Some(&r), AT, vec![], true), AT),
        case("master-key-alone", h, &none, &d[1], &build_destroy_identity(&m, None, AT, vec![], false), AT),
        case("a-foreign-recovery-key", h, &none, &d[1], &build_destroy_identity(&m, Some(&fake_r), AT, vec![], false), AT),
    ];

    let mut reordered = named.clone();
    reordered.targets.reverse();
    out.push(case("targets-reordered-after-signing", h, &none, &d[1], &reordered, AT));
    let mut added = named.clone();
    added.targets.push(d[3].peer_id());
    out.push(case("target-added-after-signing", h, &none, &d[3], &added, AT));
    let mut x = every.clone();
    x.sig_r = flip(&x.sig_r);
    out.push(case("tampered-phrase-signature", h, &none, &d[1], &x, AT));
    let mut x = every.clone();
    x.sig_b64 = flip(&x.sig_b64);
    out.push(case("tampered-master-signature", h, &none, &d[1], &x, AT));
    let mut x = every.clone();
    x.master_pubkey_b64 = build_destroy_identity(&sm, None, AT, vec![], false).master_pubkey_b64;
    out.push(case("master-key-of-another-identity", h, &none, &d[1], &x, AT));
    let mut x = every.clone();
    x.notify_friends = true;
    out.push(case("edited-after-signing", h, &none, &d[1], &x, AT));
    let mut x = every.clone();
    x.issued_at_ms += 5;
    out.push(case("restamped-after-signing", h, &none, &d[1], &x, AT + 5));
    out.push(case(
        "another-identitys-phrase",
        Some(&stranger),
        &none,
        &sd,
        &build_destroy_identity(&sm, Some(&sr), AT, vec![d[1].peer_id()], false),
        AT,
    ));

    let delegated = |by: &NativeKeypair, signer: &NativeKeypair, key: &NativeKeypair| {
        let permission = sign_destroy_delegation(&m, key, &by.peer_id(), NOW - DAY);
        build_delegated_destroy(&m, signer, permission, AT, false)
    };
    out.push(case("delegated-by-a-member", h, &none, &d[2], &delegated(&d[1], &d[1], &r), AT));
    out.push(case("delegated-to-the-target-itself", h, &none, &d[1], &delegated(&d[1], &d[1], &r), AT));
    out.push(case("delegated-by-a-removed-device", h, &none, &d[1], &delegated(&d[3], &d[3], &r), AT));
    out.push(case("delegated-by-a-pending-device", h, &none, &d[1], &delegated(&d[4], &d[4], &r), AT));
    out.push(case("delegated-by-a-matured-device", h, &matured, &d[1], &delegated(&d[4], &d[4], &r), AT));
    out.push(case("delegation-under-a-foreign-key", h, &none, &d[2], &delegated(&d[1], &d[1], &fake_r), AT));
    out.push(case("delegation-signed-by-another-device", h, &none, &d[2], &delegated(&d[1], &d[2], &r), AT));
    let mut x = delegated(&d[1], &d[1], &r);
    x.delegation.as_mut().unwrap().at_ms += 1;
    out.push(case("delegation-redated", h, &none, &d[2], &x, AT));
    out
}

#[test]
fn kill_vectors_are_current() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../relay-uws/test/kill_vectors.json");
    let cases = cases();
    let mut text = String::from("{\"cases\":[\n");
    for (i, c) in cases.iter().enumerate() {
        text.push_str(&serde_json::to_string(c).unwrap());
        text.push_str(if i + 1 < cases.len() { ",\n" } else { "\n" });
    }
    text.push_str("]}\n");
    if std::env::var_os("HOLLOW_WRITE_KILL_VECTORS").is_some() {
        std::fs::write(&path, &text).unwrap();
    }
    let held = std::fs::read_to_string(&path).unwrap_or_default().replace("\r\n", "\n");
    assert!(held == text, "relay-uws/test/kill_vectors.json is stale: rerun with HOLLOW_WRITE_KILL_VECTORS=1");
    let expect = |name: &str, want: bool| {
        let c = cases.iter().find(|c| c.name == name).unwrap();
        assert_eq!(c.proven, want, "{name}");
    };
    for name in [
        "phrase-every-device-member", "phrase-every-device-root", "phrase-reaches-a-removed-device",
        "phrase-reaches-a-pending-device", "named-among-several", "notify-friends", "targets-reordered-after-signing",
        "delegated-by-a-member", "delegated-to-the-target-itself", "delegated-by-a-matured-device",
    ] {
        expect(name, true);
    }
    assert_eq!(cases.iter().filter(|c| c.proven).count(), 10, "every other case is a refusal");
}
