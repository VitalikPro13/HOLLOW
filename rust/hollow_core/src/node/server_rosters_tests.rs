use super::*;
use crate::crdt::testkeys::keys;
use crate::identity::native_identity::NativeKeypair;
use crate::crdt::authority::KeyRule;
use crate::identity::roster::{sign_consent, sign_vouch};

fn kp(tag: u8) -> NativeKeypair {
    NativeKeypair::from_secret_bytes(&[tag; 32])
}

struct Node {
    db: String,
    pass: String,
    _tmp: crate::test_tmp::TestDir,
}

impl Node {
    fn new() -> Self {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("sr.db").to_str().unwrap().to_string();
        let pass = "ab".repeat(32);
        MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        Node { db, pass, _tmp: tmp }
    }

    fn store(&self) -> MessageStore {
        MessageStore::open(&self.db, &self.pass).unwrap()
    }
}

/// A server owned by `keys(1)` and that owner's roster with one device.
fn owned() -> (ServerState, Roster, NativeKeypair) {
    let (okp, owner, pk) = keys(1);
    let (state, _) = ServerState::found("S".into(), owner, okp.clone(), pk);
    let device = kp(40);
    let roster = Roster::genesis(&okp, &kp(41), &device, now());
    (state, roster, device)
}

fn now() -> i64 {
    super::super::types::now_ms()
}

#[test]
fn co_member_rosters_never_reach_the_book_and_age_out() {
    let node = Node::new();
    let store = node.store();
    let (state, roster, device) = owned();
    let master = roster.master.clone();
    assert_eq!(keep(&store, &node.db, &state, &roster, now()), Kept::Changed);
    assert!(super::super::roster_book::load(&store, &master).is_none(), "a delivered roster reached the book");
    assert!(counts(&store, &node.db, &master, &device.peer_id()), "the view does not read the row");
    assert_eq!(keep(&store, &node.db, &state, &roster, now()), Kept::Same);

    age_out(&store, [&state], now() + AGE_OUT_MS * 2);
    assert!(view(&store, &node.db, &master).is_some(), "a row a held server needs aged out");
    let stale = now() + AGE_OUT_MS * 2;
    age_out(&store, std::iter::empty::<&ServerState>(), stale + AGE_OUT_MS + 1);
    assert!(view(&store, &node.db, &master).is_none(), "a row no server needs outlived 30 days");
}

#[test]
fn a_roster_no_held_server_names_stores_nothing() {
    let node = Node::new();
    let store = node.store();
    let (state, _, _) = owned();
    let stranger = Roster::genesis(&kp(9), &kp(10), &kp(11), now());
    assert_eq!(keep(&store, &node.db, &state, &stranger, now()), Kept::Refused);
    assert!(store.load_server_rosters(&stranger.master).unwrap().is_empty());
}

#[test]
fn statements_that_do_not_verify_are_dropped_before_the_row() {
    let node = Node::new();
    let store = node.store();
    let (state, mut roster, _) = owned();
    let forged = kp(77);
    // A vouch signed by a device that is no member of the roster, and a consent of a
    // foreign master: neither makes the device counted.
    roster.add_consent(sign_consent(&forged, &keys(5).1));
    roster.add_vouch(sign_vouch(&forged, &roster.master.clone(), &roster.base(), &forged.peer_id()));
    assert_eq!(keep(&store, &node.db, &state, &roster, now()), Kept::Changed);
    assert!(!counts(&store, &node.db, &roster.master, &forged.peer_id()), "an unverified statement counted a device");
    let rows = store.load_server_rosters(&roster.master).unwrap();
    assert!(
        rows.iter().all(|(_, r)| !r.consents.iter().any(|c| c.device == forged.peer_id())),
        "a statement that does not verify for this master was stored",
    );
}

#[test]
fn the_view_merges_the_book_with_the_row_under_the_books_key() {
    let node = Node::new();
    let store = node.store();
    let (state, roster, device) = owned();
    let (okp, _, _) = keys(1);
    // The book holds the same identity under another recovery key (AR-15): its key wins.
    let other_key = Roster::genesis(&okp, &kp(42), &kp(43), now());
    let json = serde_json::to_string(&other_key).unwrap();
    store.save_device_list(&other_key.master, &json, 0, &[kp(43).peer_id()], now()).unwrap();
    touched();
    assert_eq!(keep(&store, &node.db, &state, &roster, now()), Kept::Changed);
    assert!(!counts(&store, &node.db, &roster.master, &device.peer_id()), "the row's key beat the book's");
    assert!(counts(&store, &node.db, &roster.master, &kp(43).peer_id()));
    let entry = entry(&store, &node.db, &state, &roster.master);
    assert_eq!(entry.key.as_deref(), Some(other_key.r_pub.as_str()), "the server verdict did not take the book's key");
    assert!(server_counts(&store, &node.db, &state, &roster.master, &kp(43).peer_id()));
    assert!(!server_counts(&store, &node.db, &state, &roster.master, &device.peer_id()), "the row's key counted in the server verdict");
}

#[test]
fn roster_buckets_name_exactly_the_masters_that_differ() {
    let a: Vec<(String, String, String)> =
        (0..40).map(|i| (format!("m{i:02}"), "k".to_string(), format!("d{i}"))).collect();
    let mut b = a.clone();
    b[7].2 = "changed".into();
    let salt = "salt";
    let theirs = prints(&b, salt);
    assert_eq!(theirs.len(), BUCKETS);
    assert!(theirs.iter().all(|p| p.len() == 8));
    assert!(differing(&a, &prints(&a, salt), salt).is_empty(), "equal sets differ");
    let rd = differing(&a, &theirs, salt);
    assert!(rd.iter().any(|(m, _)| m == "m07"));
    assert!(rd.len() < a.len(), "a differing bucket sent every master");
    assert_eq!(wanted(&b, &rd), vec!["m07".to_string()]);
    assert!(differing(&a, &theirs[..3], salt).is_empty(), "a malformed print list was answered");
    assert_ne!(prints(&a, "other")[0], prints(&a, salt)[0], "the salt does not key the prints");
}

#[test]
fn rows_past_the_byte_budget_go_needed_longest_ago_first() {
    let node = Node::new();
    let store = node.store();
    let big = "x".repeat(1 << 20);
    for i in 0..70i64 {
        store.save_server_roster(&format!("m{i:03}"), "k", &big, i).unwrap();
    }
    trim(&store, 100);
    let rows = store.server_roster_rows().unwrap();
    let total: i64 = rows.iter().map(|r| r.2).sum();
    assert!(total <= TOTAL_BYTES);
    assert!(!rows.iter().any(|r| r.0 == "m000"), "the row needed longest ago stayed");
    assert!(rows.iter().any(|r| r.0 == "m069"));
}

/// A server owned by `keys(1)` whose founding nonce commits to `r_pub` (section 5).
fn committed_to(r_pub: &str) -> ServerState {
    let (okp, owner, pk) = keys(1);
    let nonce = crate::crdt::authority::committing_nonce(&owner, r_pub);
    let mut s = ServerState::skeleton(crate::crdt::anchor::derive_server_id(&owner, &nonce));
    s.set_hlc(crate::crdt::hlc::Hlc::for_device(owner.clone(), &owner));
    s.set_signer(okp, pk);
    let op = s.create_op(crate::crdt::operations::CrdtPayload::ServerCreated { name: "S".into(), owner_peer_id: owner.clone(), nonce });
    s.apply_op(&op).unwrap();
    assert!(matches!(crate::crdt::authority::key_rule(&s, &owner), KeyRule::Commit(_)), "precondition: a committing founding");
    s
}

/// REVIEW probe: a master-key holder (the thief of a stolen device) delivers rosters
/// under recovery keys it minted before the honest roster reaches this replica; the
/// honest roster, whose key the founding commits to, must still be kept and counted.
#[test]
fn review_minted_recovery_keys_never_lock_out_the_honest_roster() {
    let node = Node::new();
    let store = node.store();
    let (okp, _, _) = keys(1);
    let device = kp(40);
    let honest = Roster::genesis(&okp, &kp(41), &device, now());
    let state = committed_to(&honest.r_pub);
    let junk1 = Roster::genesis(&okp, &kp(50), &kp(51), now());
    let junk2 = Roster::genesis(&okp, &kp(52), &kp(53), now());
    assert_eq!(keep(&store, &node.db, &state, &junk1, now()), Kept::Changed);
    assert_eq!(keep(&store, &node.db, &state, &junk2, now()), Kept::Refused, "a second minted key took the honest key's slot");
    let kept = keep(&store, &node.db, &state, &honest, now());
    let counted = server_counts(&store, &node.db, &state, &honest.master, &device.peer_id());
    assert!(kept == Kept::Changed && counted, "the honest roster was {kept:?} and its device counted: {counted}");
}

/// Rows of other keys held from before still give way to the committed key, down to one.
#[test]
fn the_committed_key_evicts_other_keys_down_to_one() {
    let node = Node::new();
    let store = node.store();
    let (okp, _, _) = keys(1);
    let honest = Roster::genesis(&okp, &kp(41), &kp(40), now());
    let state = committed_to(&honest.r_pub);
    for (r, d) in [(50u8, 51u8), (52, 53)] {
        let junk = Roster::genesis(&okp, &kp(r), &kp(d), now());
        store.save_server_roster(&junk.master, &junk.r_pub, &serde_json::to_string(&junk).unwrap(), now()).unwrap();
    }
    assert_eq!(keep(&store, &node.db, &state, &honest, now()), Kept::Changed);
    let rows = store.load_server_rosters(&honest.master).unwrap();
    assert_eq!(rows.len(), MAX_KEYS_PER_MASTER, "the rows outgrew their slots");
    assert!(rows.iter().any(|(k, _)| *k == honest.r_pub), "the committed key has no row");
}

/// Under the book's key (FirstHeld), a co-member's copy of the book's key is kept next to
/// a key seen first, and any further key is refused.
#[test]
fn under_first_held_the_books_key_always_has_a_slot() {
    let node = Node::new();
    let store = node.store();
    let (state, _, _) = owned();
    let (okp, _, _) = keys(1);
    let junk = Roster::genesis(&okp, &kp(50), &kp(51), now());
    assert_eq!(keep(&store, &node.db, &state, &junk, now()), Kept::Changed);
    let honest = Roster::genesis(&okp, &kp(41), &kp(40), now());
    store.save_device_list(&honest.master, &serde_json::to_string(&honest).unwrap(), 0, &[kp(40).peer_id()], now()).unwrap();
    touched_master(&honest.master);
    let mut grown = honest.clone();
    grown.add_vouch(sign_vouch(&kp(40), &honest.master, &honest.base(), &kp(44).peer_id()));
    grown.add_consent(sign_consent(&kp(44), &honest.master));
    assert_eq!(keep(&store, &node.db, &state, &grown, now()), Kept::Changed, "the book's key found no slot");
    let third = Roster::genesis(&okp, &kp(52), &kp(53), now());
    assert_eq!(keep(&store, &node.db, &state, &third, now()), Kept::Refused);
    assert!(server_counts(&store, &node.db, &state, &honest.master, &kp(44).peer_id()), "the book's key row did not reach the view");
}

/// Every kept row tells track C1's views to judge that master again.
#[test]
fn a_kept_roster_tells_the_views_holding_its_master() {
    let node = Node::new();
    let store = node.store();
    let (state, roster, _) = owned();
    SAVED_FOR_TEST.with(|s| s.borrow_mut().clear());
    assert_eq!(keep(&store, &node.db, &state, &roster, now()), Kept::Changed);
    assert_eq!(SAVED_FOR_TEST.with(|s| s.borrow().clone()), vec![roster.master.clone()]);
    assert_eq!(keep(&store, &node.db, &state, &roster, now()), Kept::Same);
    assert_eq!(SAVED_FOR_TEST.with(|s| s.borrow().len()), 1, "a roster that said nothing new was noted");
}

/// REVIEW probe (finding 6): a member that alternates a roster write and a roster-print
/// ask makes this replica judge again only the master it wrote, never the whole
/// authority set, and a write that says nothing new is judged by no one.
#[test]
fn review_alternating_roster_writes_and_roster_asks_cost_one_judgment_each() {
    let node = Node::new();
    let store = node.store();
    let (state, _, _) = owned();
    let rosters: Vec<Roster> = (0..40u8).map(|i| Roster::genesis(&kp(100 + i), &kp(150 + i), &kp(200 + i % 50), now())).collect();
    for r in &rosters {
        store.save_device_list(&r.master, &serde_json::to_string(r).unwrap(), 0, &[], now()).unwrap();
    }
    touched();
    let judged = || JUDGED_FOR_TEST.with(std::cell::Cell::get);
    let loaded = || LOADED_FOR_TEST.with(std::cell::Cell::get);
    let sharing = |m: &str| rosters.iter().filter(|r| gen_slot(&r.master) == gen_slot(m)).count();
    let ask = || {
        for r in &rosters {
            let _ = entry(&store, &node.db, &state, &r.master);
        }
    };
    // Other tests in this process may make every entry stale at once (`touched`): a round
    // they overlap proves nothing and is not judged.
    let epoch = || EPOCH.load(Ordering::Relaxed);
    ask();
    let mut writer = rosters[0].clone();
    let mut judged_rounds = 0;
    for i in 0..10u8 {
        writer.add_consent(sign_consent(&kp(230 + i), &writer.master));
        store.save_device_list(&writer.master, &serde_json::to_string(&writer).unwrap(), 0, &[], now()).unwrap();
        touched_master(&writer.master);
        let (j, l, e) = (judged(), loaded(), epoch());
        ask();
        if epoch() != e {
            continue;
        }
        judged_rounds += 1;
        assert!(loaded() - l <= sharing(&writer.master), "one roster write made {} masters read again", loaded() - l);
        assert!(judged() - j <= 1, "one roster write re-judged {} masters", judged() - j);
    }
    assert!(judged_rounds > 0, "every round overlapped another test's reset");
    loop {
        touched_master(&rosters[1].master);
        let (j, l, e) = (judged(), loaded(), epoch());
        ask();
        if epoch() != e {
            continue;
        }
        assert!(loaded() > l, "precondition: the write was seen");
        assert_eq!(judged(), j, "a write that changed nothing stored was judged again");
        break;
    }
}

#[test]
fn past_the_byte_budget_the_heaviest_master_gives_way_first() {
    let node = Node::new();
    let store = node.store();
    let big = "x".repeat(1 << 20);
    for i in 0..63i64 {
        store.save_server_roster(&format!("m{i:03}"), "k", &big, i).unwrap();
    }
    store.save_server_roster("zz-heavy", "k1", &big, 1000).unwrap();
    store.save_server_roster("zz-heavy", "k2", &big, 1001).unwrap();
    assert!(trim(&store, 2000));
    let rows = store.server_roster_rows().unwrap();
    assert!(rows.iter().map(|r| r.2).sum::<i64>() <= TOTAL_BYTES);
    assert!(rows.iter().any(|r| r.0 == "m000"), "a light master's row went before the heaviest's");
    assert_eq!(rows.iter().filter(|r| r.0 == "zz-heavy").count(), 1, "the heaviest master kept both rows");
    assert!(rows.iter().any(|r| r.0 == "zz-heavy" && r.1 == "k2"), "the heaviest lost its row needed last");
}

#[test]
fn a_round_counts_for_the_identity_the_view_places_never_our_own() {
    let node = Node::new();
    let store = node.store();
    let (state, roster, device) = owned();
    let master = roster.master.clone();
    assert_eq!(keep(&store, &node.db, &state, &roster, now()), Kept::Changed);
    let minted = kp(45);
    super::super::resolver::update_many(&master, [device.peer_id().as_str(), minted.peer_id().as_str()]);
    assert_eq!(round_identity(&store, &node.db, &state, &device.peer_id(), "someone-else"), Some(master.clone()));
    assert_eq!(round_identity(&store, &node.db, &state, &device.peer_id(), &master), None, "our own identity counted as a second one");
    assert_eq!(round_identity(&store, &node.db, &state, &minted.peer_id(), "someone-else"), None, "a device the view does not count named an identity");
}

/// Review part B: a held checkpoint's `cp_roster` that removes a device (a settling's)
/// reaches the cached entry at once, with no roster written here.
#[test]
fn review_b_a_new_cp_roster_reaches_the_cached_entry_at_once() {
    let node = Node::new();
    let store = node.store();
    let (mut state, mut roster, d1) = owned();
    let master = roster.master.clone();
    let d2 = kp(42);
    roster.add_consent(sign_consent(&d2, &master));
    roster.add_vouch(sign_vouch(&d1, &master, &roster.base(), &d2.peer_id()));
    assert_eq!(keep(&store, &node.db, &state, &roster, now()), Kept::Changed);
    let counted = |state: &ServerState| server_counts(&store, &node.db, state, &master, &d2.peer_id());
    assert!(counted(&state), "precondition: the vouched device counts");
    let mut removed = roster.clone();
    removed.add_removal(crate::identity::roster::sign_removal(&d1, &master, &roster.base(), &d2.peer_id(), &[]));
    state.cp_rosters = std::sync::Arc::new(vec![removed]);
    assert!(!counted(&state), "a removal a held checkpoint carries waited for the cache to lapse");
}

/// A roster with `n` devices, past [`ROSTER_MIN_CHARGE`] in bytes.
fn big_roster(master: &NativeKeypair, n: u8) -> Roster {
    let first = kp(120);
    let mut roster = Roster::genesis(master, &kp(121), &first, now());
    for t in 0..n {
        let d = kp(122 + t);
        roster.add_vouch(sign_vouch(&first, &master.peer_id(), &roster.base(), &d.peer_id()));
        roster.add_consent(sign_consent(&d, &master.peer_id()));
    }
    roster
}

/// An answer stops before a roster whose bytes pass its limit, even when the minimum
/// charge still fits (B's m28 survivor).
#[test]
fn lead_c_an_answer_stops_at_its_limit_past_the_minimum_charge() {
    let node = Node::new();
    let store = node.store();
    let (state, _, _) = owned();
    let owner = keys(1).0;
    let roster = big_roster(&owner, 24);
    let size = serde_json::to_vec(&roster.verified(now())).unwrap().len();
    assert!(size > ROSTER_MIN_CHARGE + 1, "precondition: the roster weighs {size} bytes");
    assert_eq!(keep(&store, &node.db, &state, &roster, now()), Kept::Changed);
    let wanted = [roster.master.clone()];
    let (all, charged) = answer(&store, &node.db, &state, &wanted, usize::MAX);
    assert_eq!(all.len(), 1, "control: an open limit answers the roster");
    assert!(charged >= size.min(super::super::sync_ext::MAX_ROSTER_ANSWER_BYTES) - 64, "charged {charged} for {size} bytes");
    let (out, charged) = answer(&store, &node.db, &state, &wanted, ROSTER_MIN_CHARGE + 1);
    assert!(out.is_empty(), "a roster of {size} bytes went out under a limit of {}", ROSTER_MIN_CHARGE + 1);
    assert!(charged <= ROSTER_MIN_CHARGE + 1);
}

/// Lead decision 1: the answer of the device we asked after a refused post keeps a
/// current member's roster outside the authority set; any other delivery does not, and
/// a non-member's never. An answerer hands over a member's roster, never a stranger's.
#[test]
fn lead_c_an_asked_roster_of_a_member_outside_the_set_is_kept_and_served() {
    let node = Node::new();
    let store = node.store();
    let (mut state, _, _) = owned();
    let member = big_roster(&kp(130), 1);
    let stranger = Roster::genesis(&kp(140), &kp(141), &kp(142), now());
    state.members.insert(member.master.clone(), crate::crdt::server_state::MemberInfo { peer_id: member.master.clone(), display_name: "m".into() });
    assert!(!authority_set(&state).contains(&member.master), "precondition: the member wrote no op");
    assert_eq!(keep(&store, &node.db, &state, &member, now()), Kept::Refused, "an unasked delivery of a member outside the set");
    assert_eq!(keep_asked(&store, &node.db, &state, &stranger, now()), Kept::Refused, "a non-member's roster, asked or not");
    assert_eq!(keep_asked(&store, &node.db, &state, &member, now()), Kept::Changed);
    // A stranger we know from elsewhere (a friend): its roster is ours, never the asker's.
    store.save_device_list(&stranger.master, &serde_json::to_string(&stranger).unwrap(), 0, &[], now()).unwrap();
    assert!(view(&store, &node.db, &stranger.master).is_some(), "precondition: we hold the stranger's roster");
    let (out, _) = answer(&store, &node.db, &state, &[member.master.clone(), stranger.master.clone()], usize::MAX);
    assert_eq!(out.iter().map(|r| r.master.clone()).collect::<Vec<_>>(), vec![member.master.clone()], "only the member's roster is served");
}
