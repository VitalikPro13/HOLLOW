use super::*;
use crate::crdt::testkeys::keys;
use crate::identity::native_identity::NativeKeypair;
use crate::identity::roster::{Roster, sign_consent, sign_removal, sign_vouch};

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
        let db = tmp.path().join("gate.db").to_str().unwrap().to_string();
        let pass = "ef".repeat(32);
        MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        Node { db, pass, _tmp: tmp }
    }

    fn store(&self) -> MessageStore {
        MessageStore::open(&self.db, &self.pass).unwrap()
    }

    fn book(&self, roster: &Roster) {
        let json = serde_json::to_string(roster).unwrap();
        self.store().save_device_list(&roster.master, &json, 0, &[], 0).unwrap();
        super::super::server_rosters::touched();
    }
}

/// A server owned by keys(`tag`), the owner's roster with `d1` and a vouched `d2` that
/// `d1` then removed, every device placed by the resolver.
fn owner_with_removed_sibling(tag: u8, d1: &NativeKeypair, d2: &NativeKeypair) -> (ServerState, Roster) {
    let (okp, owner, pk) = keys(tag);
    let (state, _) = ServerState::found("S".into(), owner.clone(), okp.clone(), pk);
    let now = super::super::types::now_ms();
    let mut r = Roster::genesis(&okp, &kp(tag.wrapping_add(200)), d1, now);
    r.add_consent(sign_consent(d2, &owner));
    r.add_vouch(sign_vouch(d1, &owner, &r.base(), &d2.peer_id()));
    assert!(r.authority().counts(&d2.peer_id()), "precondition: the vouched sibling counts");
    let mut removed = r.clone();
    removed.add_removal(sign_removal(d1, &owner, &r.base(), &d2.peer_id(), &[]));
    super::super::resolver::update_many(&owner, [d1.peer_id().as_str(), d2.peer_id().as_str()]);
    crate::crdt::set_identity_resolver(super::super::resolver::resolve);
    (state, removed)
}

#[test]
fn a_responder_serves_no_uncounted_asker_device() {
    let node = Node::new();
    let (d1, d2) = (kp(141), kp(142));
    let (state, removed) = owner_with_removed_sibling(31, &d1, &d2);
    node.book(&removed);
    assert!(state.is_member(&d2.peer_id()), "precondition: the transport still places the removed device");
    assert_eq!(verdict(&node, &state, &d1.peer_id(), false), AskerVerdict::Serve, "a counted member device was refused");
    assert_eq!(verdict(&node, &state, &d2.peer_id(), false), AskerVerdict::RosterNeeded, "a removed device was served");
    // A device no roster places is told what is needed only when it carried its own
    // roster, and never served.
    assert_eq!(verdict(&node, &state, &kp(143).peer_id(), true), AskerVerdict::RosterNeeded);
}

fn verdict(node: &Node, state: &ServerState, device: &str, own_roster: bool) -> AskerVerdict {
    asker_verdict(&node.db, &node.pass, state, device, own_roster)
}

/// Review part B: a stranger's device asking about a server we hold hears nothing, so it
/// never learns which servers we hold; with a roster of its own it is asked for the rest.
#[test]
fn review_b_an_unplaced_stranger_hears_nothing() {
    let node = Node::new();
    let (d1, d2) = (kp(156), kp(157));
    let (state, _) = owner_with_removed_sibling(36, &d1, &d2);
    let stranger = kp(158).peer_id();
    assert_eq!(verdict(&node, &state, &stranger, false), AskerVerdict::Silent, "an unplaced device was told we hold the server");
    assert_eq!(verdict(&node, &state, &stranger, true), AskerVerdict::RosterNeeded, "a device that carried its roster heard nothing");
}

/// Review part B: a device of an identity a recovery's hold keeps (KEEP, never a member
/// of the fold) is served only when the view counts it, as a member's device is.
#[test]
fn review_b_a_keep_only_asker_is_served_only_when_the_view_counts_it() {
    let node = Node::new();
    let (okp, owner, pk) = keys(37);
    let (mut state, _) = ServerState::found("S".into(), owner.clone(), okp.clone(), pk);
    let (mkp, member, _) = keys(38);
    let (counted, uncounted) = (kp(159), kp(160));
    let mut pre = state.clone();
    pre.members.insert(member.clone(), pre.members[&owner].clone());
    state.recovery = Some(std::sync::Arc::new(crate::crdt::hold::Recovery {
        trigger_ms: 0, base: None, base_op: None, pre: std::sync::Arc::new(pre), removals: Default::default(),
        leaves: None, shell: None, round: None, floor_b: None, dropped: Vec::new(), kept: Default::default(),
    }));
    let mut r = Roster::genesis(&mkp, &kp(161), &counted, super::super::types::now_ms());
    r.add_consent(sign_consent(&uncounted, &member));
    super::super::resolver::update_many(&member, [counted.peer_id().as_str(), uncounted.peer_id().as_str()]);
    crate::crdt::set_identity_resolver(super::super::resolver::resolve);
    node.book(&r);
    assert!(!state.is_member(&member) && state.keeps_peer(&uncounted.peer_id()), "precondition: KEEP, not a member");
    assert_eq!(verdict(&node, &state, &counted.peer_id(), false), AskerVerdict::Serve, "a counted KEEP device was refused");
    assert_eq!(verdict(&node, &state, &uncounted.peer_id(), false), AskerVerdict::RosterNeeded, "a KEEP device the view does not count was served");
}

#[test]
fn a_member_whose_roster_we_lack_is_asked_for_it() {
    let node = Node::new();
    let (d1, d2) = (kp(144), kp(145));
    let (state, _) = owner_with_removed_sibling(32, &d1, &d2);
    assert_eq!(verdict(&node, &state, &d1.peer_id(), false), AskerVerdict::RosterNeeded, "a device no roster here counts was served");
}

#[test]
fn a_known_non_member_takes_the_ordinary_path() {
    let node = Node::new();
    let (d1, d2) = (kp(146), kp(147));
    let (state, _) = owner_with_removed_sibling(33, &d1, &d2);
    let stranger = Roster::genesis(&kp(148), &kp(149), &kp(150), 0);
    node.book(&stranger);
    let dev = stranger.consents[0].device.clone();
    super::super::resolver::update_many(&stranger.master, [dev.as_str()]);
    assert_eq!(verdict(&node, &state, &dev, false), AskerVerdict::Serve, "a former member lost the op that removed it");
}

#[test]
fn an_answer_hands_over_only_rosters_of_the_servers_authority_set() {
    let node = Node::new();
    let (d1, d2) = (kp(151), kp(152));
    let (state, removed) = owner_with_removed_sibling(34, &d1, &d2);
    node.book(&removed);
    let stranger = Roster::genesis(&kp(153), &kp(154), &kp(155), 0);
    node.book(&stranger);
    let ask = AskExt { rosters_wanted: vec![removed.master.clone(), stranger.master.clone()], ..Default::default() };
    let reply = reply_ext(&node.db, &node.pass, &state, Some(&ask), None, None);
    assert_eq!(reply.rosters.iter().map(|r| r.master.clone()).collect::<Vec<_>>(), vec![removed.master.clone()]);
    assert!(!reply.base_unknown && reply.floor_base.is_none());
}

#[test]
fn a_named_base_we_lack_is_asked_for_and_a_sent_one_judged() {
    let node = Node::new();
    let (okp, owner, pk) = keys(35);
    let (mut state, _) = ServerState::found("S".into(), owner.clone(), okp, pk);
    let now = super::super::types::now_ms() as u64;
    let mut twin = state.clone();
    let (cp, _) = state.author_due_checkpoint(&owner, &[], now).expect("the owner checkpoints");
    let _ = twin.author_checked(crate::crdt::operations::CrdtPayload::ServerRenamed { new_name: "Other".into() });
    let (cp2, _) = twin.author_due_checkpoint(&owner, &[], now).expect("the owner checkpoints another state");
    assert_ne!(cp2.content_hash(), cp.content_hash(), "precondition: two different checkpoints");
    let d = OpDigest {
        ask: 1, salt: "s".into(), base: None, bref: Some(hex::encode(cp.content_hash())), from: None,
        ranges: Vec::new(), round: 0, rs: None,
    };
    let mut fresh = ServerState::skeleton(state.server_id.clone());
    fresh.owner_pin = state.anchor_owner();
    let named = AskExt { named_base: true, ..Default::default() };
    assert!(reply_ext(&node.db, &node.pass, &fresh, Some(&named), Some(&d), None).base_unknown, "a lacked named base was not reported");
    assert!(!reply_ext(&node.db, &node.pass, &fresh, None, Some(&d), None).base_unknown, "an ordinary ask was refused for its base");
    let sent = AskExt { named_base: true, base_content: Some(serde_json::to_string(&cp).unwrap()), ..Default::default() };
    assert!(given_base(&fresh, &d, Some(&sent)).is_some(), "the sent base was not taken");
    // Read only in answer to a `base_unknown` we sent that device for that base.
    let t0 = Instant::now();
    let mut told = BaseTold::default();
    assert!(told.given(&fresh, "dev", Some(&d), Some(&sent), t0).is_none(), "a base nobody asked for was read");
    told.told(&fresh.server_id, "dev", d.bref.as_deref().unwrap(), t0);
    assert!(told.given(&fresh, "other", Some(&d), Some(&sent), t0).is_none(), "another device's base was read");
    assert!(told.given(&fresh, "dev", Some(&OpDigest { bref: Some("00".repeat(32)), ..d.clone() }), Some(&sent), t0).is_none());
    // Another valid checkpoint, named by its own digest: we never said we lack that one.
    let d2 = OpDigest { bref: Some(hex::encode(cp2.content_hash())), ..d.clone() };
    let sent2 = AskExt { base_content: Some(serde_json::to_string(&cp2).unwrap()), ..sent.clone() };
    assert!(given_base(&fresh, &d2, Some(&sent2)).is_some(), "precondition: the other checkpoint is a base");
    assert!(told.given(&fresh, "dev", Some(&d2), Some(&sent2), t0).is_none(), "a base we never asked that device for was read");
    let given = told.given(&fresh, "dev", Some(&d), Some(&sent), t0);
    assert!(given.is_some(), "the base we asked for was not read");
    assert!(!reply_ext(&node.db, &node.pass, &fresh, Some(&sent), Some(&d), given.as_ref()).base_unknown, "a base we were given was asked for again");
    let other = OpDigest { bref: Some("00".repeat(32)), ..d.clone() };
    assert!(given_base(&fresh, &other, Some(&sent)).is_none(), "a base the digest does not name was taken");
    let mut forged = cp.clone();
    forged.author = keys(36).1;
    let forged_ask = AskExt { base_content: Some(serde_json::to_string(&forged).unwrap()), ..sent.clone() };
    assert!(given_base(&fresh, &d, Some(&forged_ask)).is_none(), "a base by another author was taken");
    // Same signed bytes, so the same content id, under a signature that does not verify.
    let mut bad_sig = cp.clone();
    if let Some(auth) = bad_sig.auth.as_mut() {
        auth.sig = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, [0u8; 64]);
    }
    let bad_ask = AskExt { base_content: Some(serde_json::to_string(&bad_sig).unwrap()), ..sent.clone() };
    assert!(given_base(&fresh, &d, Some(&bad_ask)).is_none(), "a base whose signature fails was taken");
    let floor = AskExt { floor: true, ..Default::default() };
    let reply = reply_ext(&node.db, &node.pass, &state, Some(&floor), None, None);
    assert!(reply.floor_base.as_deref().and_then(super::super::sync_ext::read_base_op).is_some(), "a floor round got no base");
    // Section 8.8: a server in recovery here offers its pre-trigger base to every ask.
    let mut held = fresh.clone();
    held.recovery = Some(std::sync::Arc::new(crate::crdt::hold::Recovery {
        trigger_ms: 1,
        base: Some(hex::encode(cp.content_hash())),
        base_op: Some(cp.clone()),
        pre: std::sync::Arc::new(fresh.clone()),
        removals: Default::default(),
        leaves: None,
        shell: None,
        round: None,
        floor_b: None,
        dropped: Vec::new(),
        kept: Default::default(),
    }));
    let reply = reply_ext(&node.db, &node.pass, &held, None, None, None);
    let offered = reply.floor_base.as_deref().and_then(super::super::sync_ext::read_base_op).map(|o| o.content_hash());
    assert_eq!(offered, Some(cp.content_hash()), "an ordinary ask to a member in recovery got no pre-trigger base");
}

#[test]
fn the_roster_retry_waits_twice_as_long_each_time() {
    let mut again = Again::default();
    let t0 = Instant::now();
    assert!(again.may("s", "d", t0));
    assert!(!again.may("s", "d", t0 + AGAIN_EVERY / 2));
    assert!(again.may("s", "d", t0 + AGAIN_EVERY));
    assert!(!again.may("s", "d", t0 + AGAIN_EVERY * 2), "the second wait did not double");
    assert!(again.may("s", "d", t0 + AGAIN_EVERY * 3));
    assert!(!again.may("s", "d", t0 + AGAIN_EVERY * 6), "the third wait did not double");
    assert!(again.may("s", "d", t0 + AGAIN_EVERY * 7));
    assert!(again.may("s", "other", t0), "one device's ladder held another's");
}

#[test]
fn an_answer_that_needs_our_roster_is_asked_again_with_it() {
    let node = Node::new();
    let (d1, d2) = (kp(156), kp(157));
    let (state, removed) = owner_with_removed_sibling(37, &d1, &d2);
    node.book(&removed);
    let member = Roster::genesis(&kp(158), &kp(159), &kp(160), 0);
    let answerer = member.consents[0].device.clone();
    super::super::resolver::update_many(&member.master, [answerer.as_str()]);
    let mut resync = super::super::crdt_resync::CrdtResync::for_test();
    resync.op_sync.set_store(&node.db, &node.pass, &removed.master);
    let roster_of = |m: &HavenMessage| match m {
        HavenMessage::SyncRequest { x, .. } => x.as_ref().and_then(|x| x.asker_roster.clone()),
        _ => None,
    };
    assert!(roster_of(&resync.sync_ask(&state, &answerer, Some(1), None)).is_some(), "precondition: the first ask carries our roster");
    assert!(roster_of(&resync.sync_ask(&state, &answerer, Some(2), None)).is_none(), "precondition: it rides once per version");
    let mut again = Again::default();
    let needed = ReplyExt { roster_needed: true, ..Default::default() };
    let out = on_reply(&node.db, &node.pass, &mut resync, &mut again, Some(&state), &answerer, Some(3), None, &needed);
    assert_eq!(out.again.len(), 1, "a refused ask was not asked again");
    assert_eq!(roster_of(&out.again[0]).map(|r| r.master), Some(removed.master.clone()), "the re-ask lacks our roster");
    let out = on_reply(&node.db, &node.pass, &mut resync, &mut again, Some(&state), &answerer, Some(4), None, &needed);
    assert!(out.again.is_empty(), "a second refusal re-asked at once");
}

/// A join answer's rosters are kept only while that join is pending and only from a
/// sender not yet a member of our state (a member's went through `on_reply`).
#[test]
fn join_answer_rosters_are_taken_only_for_a_pending_join() {
    let x = ReplyExt { rosters: vec![Roster::genesis(&kp(60), &kp(61), &kp(62), 1_000)], ..Default::default() };
    assert!(join_reply(Some(&x), true, false).is_some(), "the answer to our pending join");
    assert!(join_reply(Some(&x), false, false).is_none(), "no join of ours pending");
    assert!(join_reply(Some(&x), true, true).is_none(), "a member's answer takes the ordinary path");
    assert!(join_reply(Some(&ReplyExt::default()), true, false).is_none(), "nothing to keep");
    assert!(join_reply(None, true, false).is_none());
}

/// Review part B: a counted member looping roster asks is handed at most its budget (each
/// roster charged at least its verification), while another asker is still answered.
#[test]
fn review_b_a_looping_roster_asker_gets_bounded_answers() {
    let node = Node::new();
    let (d1, d2) = (kp(162), kp(163));
    let (state, removed) = owner_with_removed_sibling(39, &d1, &d2);
    node.book(&removed);
    let ask = AskExt { rosters_wanted: vec![removed.master.clone()], ..Default::default() };
    let mut serve = RosterServe::default();
    let mut answered = 0usize;
    let started = std::time::Instant::now();
    for _ in 0..2_000 {
        let reply = reply_ext_within(&node.db, &node.pass, &state, Some(&ask), None, None, Some((&mut serve, "looper")));
        answered += reply.rosters.len();
    }
    // The budget refills by wall clock, so a slow machine earns what the loop's own time refilled.
    let refilled = started.elapsed().as_secs_f64() * ROSTERS_ASKER.1;
    let cap = ((ROSTERS_ASKER.0 + refilled) as usize) / super::super::server_rosters::ROSTER_MIN_CHARGE;
    assert!(answered > 0, "control: the asker is answered at first");
    assert!(answered <= cap + 2, "a looping asker was handed {answered} rosters, past its budget of about {cap}");
    let other = reply_ext_within(&node.db, &node.pass, &state, Some(&ask), None, None, Some((&mut serve, "other")));
    assert_eq!(other.rosters.len(), 1, "one asker's loop starved another");
}

/// The roster budget per asker and in all, and its refill.
#[test]
fn review_b_the_roster_budget_is_per_asker_and_in_all_and_refills() {
    let mut serve = RosterServe::default();
    let t0 = Instant::now();
    let burst = ROSTERS_ASKER.0 as usize;
    assert_eq!(serve.allowance("a", t0), burst);
    serve.spend("a", burst, t0);
    assert_eq!(serve.allowance("a", t0), 0, "a spent asker still had budget");
    assert_eq!(serve.allowance("b", t0), burst, "one asker's spending held another");
    let all = ROSTERS_ALL.0 as usize;
    let mut spent = burst;
    let mut n = 0;
    while spent < all {
        serve.spend(&format!("x{n}"), burst, t0);
        spent += burst;
        n += 1;
    }
    assert_eq!(serve.allowance("fresh", t0), 0, "a fresh asker was handed past the budget of all askers");
    let later = t0 + Duration::from_secs_f64(64.0 * 1024.0 / ROSTERS_ALL.1.min(ROSTERS_ASKER.1));
    assert!(serve.allowance("fresh", later) >= 64 * 1024, "the budget never refills");
    assert!(serve.allowance("a", later) >= 64 * 1024 && serve.allowance("a", later) < burst);
}
