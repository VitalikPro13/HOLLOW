use super::*;
use crate::crdt::testkeys::keys;
use crate::identity::native_identity::NativeKeypair;
use crate::identity::roster::{Roster, sign_consent};

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
        let db = tmp.path().join("ss.db").to_str().unwrap().to_string();
        let pass = "12".repeat(32);
        MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        Node { db, pass, _tmp: tmp }
    }

    fn store(&self) -> MessageStore {
        MessageStore::open(&self.db, &self.pass).unwrap()
    }
}

/// A peer id of the relay's shape for `n` (no `0`), distinct per `n`.
fn pid(n: usize) -> String {
    let s: String = n.to_string().chars().map(|c| if c == '0' { 'z' } else { c }).collect();
    format!("{s:a>52}")
}

fn entry(i: usize) -> SharedServer {
    SharedServer {
        server_id: format!("{i:040x}"),
        owner: "o".repeat(52),
        join_key: super::super::sealed_box::key_to_text(&[i as u8; 32]),
        relay: "relay.example".into(),
        members: (0..(i % 70)).map(pid).collect(),
    }
}

#[test]
fn every_answer_is_four_frames_of_one_size() {
    let size = frame_bytes();
    for n in [0usize, 1, 3, 16, 17, 40, 64] {
        let out = frames((0..n).map(entry).map(|mut e| { e.members.truncate(MAX_MEMBERS); e }).collect());
        assert_eq!(out.len(), FRAMES, "{n} entries");
        for (i, f) in out.iter().enumerate() {
            assert_eq!(serde_json::to_vec(f).unwrap().len(), size, "{n} entries, frame {i}: the size tells the relay something");
            assert!(matches!(f, HavenMessage::SharedServers { ask: false, part, .. } if *part as usize == i));
        }
    }
}

#[test]
fn only_servers_listing_the_identity_are_named_owned_first() {
    let (akp, alice, apk) = keys(40);
    let (bkp, bob, bpk) = keys(41);
    let (alices, _) = ServerState::found("A".into(), alice.clone(), akp, apk);
    let (bobs, _) = ServerState::found("B".into(), bob.clone(), bkp, bpk);
    let named = entries([&bobs, &alices], &alice, "relay.x");
    assert_eq!(named.iter().map(|e| e.server_id.clone()).collect::<Vec<_>>(), vec![alices.server_id.clone()], "a server alice is not in was named");
    assert_eq!(named[0].members, vec![alice.clone()]);
    assert_eq!(named[0].relay, "relay.x");
    assert!(named[0].owner.is_empty() == crate::crdt::anchor::is_genesis_id(&alices.server_id));
    assert!(entries([&bobs], &alice, "r").is_empty());
}

#[test]
fn only_a_counted_device_of_an_accepted_friend_is_answered() {
    let node = Node::new();
    let store = node.store();
    let (fkp, friend, _) = keys(42);
    let device = kp(160);
    let roster = Roster::genesis(&fkp, &kp(161), &device, super::super::types::now_ms());
    store.save_device_list(&friend, &serde_json::to_string(&roster).unwrap(), 0, &[], 0).unwrap();
    super::super::server_rosters::touched();
    let minted = kp(162);
    super::super::resolver::update_many(&friend, [device.peer_id().as_str(), minted.peer_id().as_str()]);
    assert!(asker_ok(&store, &node.db, &device.peer_id()).is_none(), "a device of no friend was answered");
    store.save_friend(&friend, "pending", "outgoing", 1).unwrap();
    assert!(asker_ok(&store, &node.db, &device.peer_id()).is_none(), "a pending friend was answered");
    store.save_friend(&friend, "accepted", "", 2).unwrap();
    assert_eq!(asker_ok(&store, &node.db, &device.peer_id()), Some(friend.clone()));
    // A key the master key holder minted: it consents, nothing vouches it.
    let mut with_minted = roster.clone();
    with_minted.add_consent(sign_consent(&minted, &friend));
    store.save_device_list(&friend, &serde_json::to_string(&with_minted).unwrap(), 0, &[], 0).unwrap();
    super::super::server_rosters::touched();
    assert!(asker_ok(&store, &node.db, &minted.peer_id()).is_none(), "a minted key was answered");
}

#[test]
fn a_device_is_answered_once_per_ten_minutes() {
    let t0 = Instant::now();
    assert!(may_answer("me", "a", t0));
    assert!(!may_answer("me", "a", t0 + ANSWER_EVERY / 2));
    assert!(may_answer("me", "b", t0), "one asker's answer held another's");
    assert!(may_answer("other-node", "a", t0), "one node's answer held another's");
    assert!(may_answer("me", "a", t0 + ANSWER_EVERY));
}

#[test]
fn an_answer_is_taken_only_from_a_counted_friend_and_within_bounds() {
    let node = Node::new();
    let store = node.store();
    let (fkp, friend, _) = keys(43);
    let device = kp(163);
    let roster = Roster::genesis(&fkp, &kp(164), &device, super::super::types::now_ms());
    store.save_device_list(&friend, &serde_json::to_string(&roster).unwrap(), 0, &[], 0).unwrap();
    store.save_friend(&friend, "accepted", "", 2).unwrap();
    super::super::server_rosters::touched();
    super::super::resolver::update_many(&friend, [device.peer_id().as_str()]);
    let mut list: Vec<SharedServer> = (0..20).map(entry).collect();
    list[0].join_key.clear();
    list[1].server_id = "../x".into();
    let got = accepted(&store, &node.db, &device.peer_id(), &list);
    assert!(got.len() <= PER_FRAME);
    assert!(got.iter().all(|e| !e.join_key.is_empty() && e.members.len() <= MAX_MEMBERS));
    assert!(!got.iter().any(|e| e.server_id == "../x"), "an id that is no server id was taken");
    assert!(accepted(&store, &node.db, &kp(165).peer_id(), &list).is_empty(), "a stranger's answer was taken");
    assert!(!got.is_empty(), "control: well-formed entries are taken");
}

/// Review part B: one friend's frame naming one server in every entry counts it once;
/// malformed pins, keys, relays and member ids are refused, members once each.
#[test]
fn review_b_an_answer_names_each_server_once_with_well_formed_fields() {
    let node = Node::new();
    let store = node.store();
    let (fkp, friend, _) = keys(44);
    let device = kp(166);
    let roster = Roster::genesis(&fkp, &kp(167), &device, super::super::types::now_ms());
    store.save_device_list(&friend, &serde_json::to_string(&roster).unwrap(), 0, &[], 0).unwrap();
    store.save_friend(&friend, "accepted", "", 2).unwrap();
    super::super::server_rosters::touched();
    super::super::resolver::update_many(&friend, [device.peer_id().as_str()]);
    let mut same = entry(5);
    same.members = vec![pid(1), pid(1), "0".repeat(52), "x".repeat(500), pid(2)];
    let list = vec![same.clone(); PER_FRAME];
    let got = accepted(&store, &node.db, &device.peer_id(), &list);
    assert_eq!(got.len(), 1, "one server repeated in every entry was taken more than once");
    assert_eq!(got[0].members, vec![pid(1), pid(2)], "member ids are taken once each and only of a peer id's shape");
    let bad = |f: &dyn Fn(&mut SharedServer)| {
        let mut e = entry(6);
        f(&mut e);
        accepted(&store, &node.db, &device.peer_id(), &[e]).is_empty()
    };
    assert!(!bad(&|_| {}), "control: the entry is taken");
    assert!(bad(&|e| e.owner = "x".repeat(5000)), "an owner pin of no peer id's shape was taken");
    assert!(bad(&|e| e.join_key = "k".repeat(5000)), "a join key that is no key was taken");
    assert!(bad(&|e| e.relay = "r".repeat(254)), "a relay longer than a domain was taken");
    assert!(bad(&|e| e.relay = "relay example".into()), "a relay with a space was taken");
}

/// Review part B: a frame larger than every honest frame is dropped whole.
#[test]
fn review_b_a_frame_larger_than_an_honest_one_is_refused() {
    for msg in frames((0..PER_FRAME).map(entry).collect()) {
        let HavenMessage::SharedServers { servers, pad, .. } = msg else { unreachable!() };
        assert!(frame_fits(&servers, &pad), "an honest frame was refused");
    }
    assert!(!frame_fits(&[], &" ".repeat(frame_bytes() + 1)), "an oversized pad was taken");
    let mut big = entry(1);
    big.members = vec!["m".repeat(64); 4 * MAX_MEMBERS];
    assert!(!frame_fits(&vec![big; PER_FRAME], ""), "oversized entries were taken");
    assert!(!frame_fits(&vec![entry(1); PER_FRAME + 1], ""), "more entries than a frame holds were taken");
}

#[test]
fn only_an_asked_device_is_heard_and_an_answered_one_is_not_asked_again() {
    let mut asks = Asks::default();
    let t0 = Instant::now();
    assert!(!asks.take_frame("d"), "an unasked device's answer would be taken");
    assert!(asks.may_ask("d", t0));
    assert!(!asks.may_ask("d", t0), "asked twice at once");
    assert!(asks.may_ask("d", t0 + ASK_AGAIN), "a device that has not answered is not asked again on its next arrival");
    assert!(asks.take_frame("d"));
    assert!(!asks.may_ask("d", t0 + ASK_AGAIN * 10), "a device that answered was asked again");
}

#[test]
fn one_ask_takes_at_most_four_frames() {
    let mut asks = Asks::default();
    assert!(asks.may_ask("d", Instant::now()));
    for i in 0..FRAMES {
        assert!(asks.take_frame("d"), "frame {i} of the answer was dropped");
    }
    assert!(!asks.take_frame("d"), "a fifth frame was taken: one ask joins without bound");
}

fn queued_entry(i: usize, relay: &str) -> SharedServer {
    SharedServer { relay: relay.into(), ..entry(i) }
}

#[test]
fn shared_joins_are_bounded_and_another_relay_waits_for_the_person() {
    let db = format!("joins-{}", std::process::id());
    let mut joins = Joins::default();
    for i in 0..MAX_SERVERS + 10 {
        joins.offer(&db, queued_entry(i, "ours"), "f", "ours");
    }
    joins.offer(&db, queued_entry(3, "ours"), "f", "ours");
    let now = Instant::now();
    let mut started = 0;
    loop {
        let due = joins.due(now);
        assert!(due.len() <= JOINS_PER_TICK);
        if due.is_empty() {
            break;
        }
        started += due.len();
    }
    assert_eq!(started, MAX_SERVERS, "the queue outgrew its bound or lost an entry");
    joins.offer(&db, queued_entry(500, "elsewhere"), "f", "ours");
    assert!(joins.due(now).is_empty(), "a server on another relay was joined");
    let held = held_shares(&db);
    assert_eq!(held.len(), 1);
    assert_eq!((held[0].why, held[0].friend.as_str()), (HeldWhy::OtherRelay, "f"));
    assert_eq!(take_held_share(&db, &held[0].server_id).map(|h| h.server_id), Some(queued_entry(500, "").server_id));
    assert!(held_shares(&db).is_empty());
}

#[test]
fn a_re_entry_no_member_answers_waits_for_the_person() {
    let db = format!("lapsed-{}", std::process::id());
    let mut joins = Joins::default();
    joins.offer(&db, queued_entry(1, ""), "f", "ours");
    joins.offer(&db, queued_entry(2, ""), "f", "ours");
    let t0 = Instant::now();
    assert_eq!(joins.due(t0).len(), 2);
    assert!(joins.lapsed(&db, t0 + REENTRY_WAIT / 2, &|_| false).is_empty());
    let joined = queued_entry(1, "").server_id;
    let lapsed = joins.lapsed(&db, t0 + REENTRY_WAIT, &|sid| sid == joined);
    assert_eq!(lapsed, vec![queued_entry(2, "").server_id], "a re-entry that completed was held, or one that lapsed was not");
    assert_eq!(held_shares(&db).iter().map(|h| (h.server_id.clone(), h.why)).collect::<Vec<_>>(), vec![(queued_entry(2, "").server_id, HeldWhy::NotAMember)]);
}

#[test]
fn the_answer_gate_reads_the_book_never_a_co_members_roster() {
    let node = Node::new();
    let store = node.store();
    let (fkp, friend, _) = keys(44);
    let device = kp(166);
    let extra = kp(167);
    let roster = Roster::genesis(&fkp, &kp(168), &device, super::super::types::now_ms());
    store.save_device_list(&friend, &serde_json::to_string(&roster).unwrap(), 0, &[], 0).unwrap();
    store.save_friend(&friend, "accepted", "", 2).unwrap();
    let mut grown = roster.clone();
    grown.add_vouch(crate::identity::roster::sign_vouch(&device, &friend, &roster.base(), &extra.peer_id()));
    grown.add_consent(sign_consent(&extra, &friend));
    store.save_server_roster(&friend, &roster.r_pub, &serde_json::to_string(&grown).unwrap(), 1).unwrap();
    super::super::server_rosters::touched();
    super::super::resolver::update_many(&friend, [device.peer_id().as_str(), extra.peer_id().as_str()]);
    assert!(super::super::server_rosters::counts(&store, &node.db, &friend, &extra.peer_id()), "precondition: the co-member's row counts the device");
    assert!(asker_ok(&store, &node.db, &extra.peer_id()).is_none(), "a device only a co-member's roster counts was told our servers");
    assert_eq!(asker_ok(&store, &node.db, &device.peer_id()), Some(friend));
}

#[test]
fn a_recovering_join_sends_its_room_notice_three_times_apart() {
    let mut n = RoomNotices::default();
    let t0 = Instant::now();
    n.start("s", t0);
    assert_eq!(n.due(t0), vec!["s".to_string()], "the first notice did not go at once");
    assert!(n.due(t0 + NOTICE_EVERY / 2).is_empty(), "notices closer than the gap");
    n.start("s", t0 + NOTICE_EVERY / 2);
    assert_eq!(n.due(t0 + NOTICE_EVERY).len(), 1);
    assert_eq!(n.due(t0 + NOTICE_EVERY * 2).len(), 1);
    assert!(n.due(t0 + NOTICE_EVERY * 9).is_empty(), "more than three notices");
    for i in 0..MAX_SERVERS + 5 {
        n.start(&format!("x{i}"), t0);
    }
    assert!(n.0.len() <= MAX_SERVERS);
}
