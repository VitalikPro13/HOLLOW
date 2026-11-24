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

/// Our own master in these units.
const US: &str = "uuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu";

/// A legacy server id, which does not self-certify its founder (an owner pin names it).
fn uuid_sid(i: usize) -> String {
    format!("{i:032x}")
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
    let named = entries([&bobs, &alices], &alice, "relay.x", &|_| false);
    assert_eq!(named.iter().map(|e| e.server_id.clone()).collect::<Vec<_>>(), vec![alices.server_id.clone()], "a server alice is not in was named");
    assert_eq!(named[0].members, vec![alice.clone()]);
    assert_eq!(named[0].relay, "relay.x");
    assert!(named[0].owner.is_empty() == crate::crdt::anchor::is_genesis_id(&alices.server_id));
    assert!(entries([&bobs], &alice, "r", &|_| false).is_empty());
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
    list[0].server_id = uuid_sid(0);
    list[1].server_id = "../x".into();
    let got = accepted(&store, &node.db, &device.peer_id(), &list);
    assert!(got.len() <= PER_FRAME);
    assert!(got.iter().all(|e| !e.join_key.is_empty() && e.members.len() <= MAX_MEMBERS), "a keyless entry for a server someone else owns was taken");
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
    assert!(asks.may_ask("d", t0, false));
    assert!(!asks.may_ask("d", t0, false), "asked twice at once");
    assert!(asks.may_ask("d", t0 + ASK_AGAIN, false), "a device that has not answered is not asked again on its next arrival");
    assert!(asks.take_frame("d"));
    assert!(!asks.may_ask("d", t0 + ASK_AGAIN * 10, false), "a device that answered was asked again");
}

/// F1: a friend's accept answers the request that carried our roster, so it re-asks
/// inside the floor, once; an answered device is never asked again.
#[test]
fn an_accept_asks_again_once_inside_the_floor() {
    let mut asks = Asks::default();
    let t0 = Instant::now();
    let s = Duration::from_secs(1);
    assert!(asks.may_ask("d", t0, false));
    assert!(!asks.may_ask("d", t0 + s, false), "an arrival asked again inside the floor");
    assert!(asks.may_ask("d", t0 + s, true), "the accept did not ask again");
    assert!(!asks.may_ask("d", t0 + 2 * s, true), "a second accept asked again inside the floor");
    assert!(!asks.may_ask("d", t0 + 2 * s, false), "an arrival asked again inside the floor");
    assert!(asks.may_ask("d", t0 + s + ASK_AGAIN, false), "the floor never ran out");
    assert!(asks.may_ask("d", t0 + s + ASK_AGAIN + s, true), "the floor's next accept did not ask again");
    assert!(asks.take_frame("d"));
    assert!(!asks.may_ask("d", t0 + ASK_AGAIN * 3, true), "an accept asked a device that answered");
}

#[test]
fn one_ask_takes_at_most_four_frames() {
    let mut asks = Asks::default();
    assert!(asks.may_ask("d", Instant::now(), false));
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
        joins.offer(&db, queued_entry(i, "ours"), "f", "fd", "ours");
    }
    joins.offer(&db, queued_entry(3, "ours"), "f", "fd", "ours");
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
    joins.offer(&db, queued_entry(500, "elsewhere"), "f", "fd", "ours");
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
    joins.offer(&db, queued_entry(1, ""), "f", "fd", "ours");
    joins.offer(&db, queued_entry(2, ""), "f", "fd", "ours");
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

/// R2: a roster where the phrase admitted F (and D, which stands to remove it) and a
/// Welcome mark naming F, saved in `n`.
fn fresh_admission(n: &Node, empty: bool, branch: super::super::phrase_restore::Branch) -> (String, String, i64) {
    use crate::identity::roster::{r_pub_of, sign_phrase_admit};
    let (master, recovery, f, d) = (kp(0x61), kp(0x62), kp(0x63), kp(0x64));
    let own = master.peer_id();
    let at = super::super::types::now_ms() - 60_000;
    let mut r = Roster::new(&own);
    for dev in [&d, &f] {
        r.add_consent(sign_consent(dev, &own));
        r.add_phrase_statement(&r_pub_of(&recovery), None, Some(sign_phrase_admit(&master, &recovery, at, &dev.peer_id()))).unwrap();
    }
    let store = n.store();
    super::super::roster_book::merge_for_test(&store, &r, &own, &f.peer_id());
    let mark = super::super::phrase_restore::Mark { at_ms: at, branch, empty, device: f.peer_id() };
    super::super::phrase_restore::write(&store, &mark).unwrap();
    (own, f.peer_id(), at)
}

#[test]
fn recovering_counts_a_fresh_phrase_restore_for_thirty_days() {
    use super::super::phrase_restore::Branch;
    let _g = super::super::resolver::test_lock();
    let n = Node::new();
    let (own, f, at) = fresh_admission(&n, true, Branch::Admit);
    let store = n.store();
    assert!(recovering_in(&store, &own, &f, at + 1), "a fresh admission asks");
    assert!(recovering_in(&store, &own, &f, at + RECOVERY_WINDOW_MS - 1));
    assert!(!recovering_in(&store, &own, &f, at + RECOVERY_WINDOW_MS), "day 31");
    assert!(!recovering_in(&store, &own, &kp(0x64).peer_id(), at + 1), "another device of ours");

    let n = Node::new();
    let (own, f, at) = fresh_admission(&n, false, Branch::Admit);
    assert!(!recovering_in(&n.store(), &own, &f, at + 1), "a restore beside a held roster");
    let n = Node::new();
    let (own, f, at) = fresh_admission(&n, true, Branch::Recover);
    assert!(!recovering_in(&n.store(), &own, &f, at + 1), "a recovery asks by its own branch, with its T");
}

/// D3: a removal never drops the admission statement, so the gate reads membership.
#[test]
fn recovering_stops_once_the_restored_device_is_removed() {
    use crate::identity::roster::sign_removal;
    let _g = super::super::resolver::test_lock();
    let n = Node::new();
    let (own, f, at) = fresh_admission(&n, true, super::super::phrase_restore::Branch::Admit);
    let store = n.store();
    let mut r = super::super::roster_book::load(&store, &own).unwrap();
    r.add_removal(sign_removal(&kp(0x64), &own, &r.base(), &f, &[]));
    super::super::roster_book::merge_for_test(&store, &r, &own, &f);
    let r = super::super::roster_book::load(&store, &own).unwrap();
    assert!(!super::super::roster_book::fold(&store, &r).is_member(&f), "precondition: F is removed");
    assert!(r.phrase_admits.iter().any(|p| p.device == f), "precondition: the admission stays");
    assert!(!recovering_in(&store, &own, &f, at + 1));
}

/// A counted friend device that names what part A's hold keeps on a server it lists us
/// in, and that holds no key we could use, gets no key named (F5).
#[test]
fn entries_under_part_as_hold_list_the_members_and_name_no_key() {
    use crate::crdt::hold::tests::{baseless_replica, baseless_world, view_after, MEMBER, MEMBER_PHONE, MOD, OWNER};
    let (mut owner, mut log) = baseless_world();
    let key = owner.author_checked(crate::crdt::operations::CrdtPayload::JoinKeySet { secret: crate::crdt::operations::JoinSecret(hex::encode([5u8; 32])) }).unwrap();
    log.push(key);
    let mut m = baseless_replica(&log, MEMBER, MEMBER_PHONE, true);
    let before = entries([&m], &keys(OWNER).1, "relay", &|s| s.join_key_dropped(&s.authority));
    assert!(entries([&m], &keys(OWNER).1, "relay", &|s| s.join_key_dropped(&view_after(false)))[0].join_key.is_empty(), "a fold that has not rebuilt under the roster we hold named the cut-off key");
    assert!(!before[0].join_key.is_empty(), "precondition: the key is named while the phone counts");
    m.authority = view_after(false);
    let _ = m.rebuild_now();
    assert!(m.in_recovery(), "precondition: part A holds");
    let after = entries([&m], &keys(OWNER).1, "relay", &|s| s.join_key_dropped(&s.authority));
    assert_eq!(after.len(), 1, "the owner is still listed");
    assert!(after[0].join_key.is_empty(), "the dropped phone's key is never named");
    assert!(after[0].members.contains(&keys(MOD).1) && after[0].members.contains(&keys(MEMBER).1), "the hold keeps the members");
}

/// F5 (note 3.2): a keyless entry from a counted friend starts a SYNC re-entry: no lock
/// read and no join box, only the friend device that named it as its source. A pinned
/// owner must be us; a self-certifying id waits for the first answer; a malformed key
/// still drops the entry.
#[test]
fn a_keyless_entry_from_a_counted_friend_is_a_sync_reentry() {
    let node = Node::new();
    let store = node.store();
    let (fkp, friend, _) = keys(45);
    let device = kp(168);
    let roster = Roster::genesis(&fkp, &kp(169), &device, super::super::types::now_ms());
    store.save_device_list(&friend, &serde_json::to_string(&roster).unwrap(), 0, &[], 0).unwrap();
    store.save_friend(&friend, "accepted", "", 2).unwrap();
    super::super::server_rosters::touched();
    super::super::resolver::update_many(&friend, [device.peer_id().as_str()]);
    let keyless = |sid: String, owner: &str| SharedServer { server_id: sid, owner: owner.into(), join_key: String::new(), ..entry(7) };
    let took = |e: SharedServer| !accepted(&store, &node.db, &device.peer_id(), &[e]).is_empty();
    assert!(took(keyless(format!("{:040x}", 7), "")), "a keyless self-certifying id was dropped");
    // Finding 5 (review F5c): a pinned id syncs by state vector, which never shows a
    // caught-up fold, so its keyless entry is dropped, ours included.
    assert!(!took(keyless(uuid_sid(7), US)), "a keyless pinned server was taken: its re-entry could never complete");
    assert!(!took(keyless(uuid_sid(8), &"o".repeat(52))), "a keyless entry for a server another identity owns was taken");
    assert!(!took(SharedServer { join_key: "not a key".into(), ..keyless(uuid_sid(9), US) }), "a malformed key was taken");
    assert!(!accepted(&store, &node.db, &kp(170).peer_id(), &[keyless(format!("{:040x}", 7), "")]).iter().any(|_| true), "a device we do not count was heard");

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let mut pending = HashMap::new();
    let q = Queued { entry: keyless(format!("{:040x}", 7), ""), friend: friend.clone(), devices: vec![device.peer_id()] };
    start_reentry(&mut pending, &tx, q, US, "dddddddddddddddddddddddddddddddddddddddddddddddddddd", &node.db, &node.pass);
    let p = pending.get(&format!("{:040x}", 7)).expect("the re-entry starts");
    assert!(p.sync_reentry() && p.join_key.is_none() && p.sync_from == vec![device.peer_id()], "not a keyless sync re-entry: {p:?}");
    let mut sent = Vec::new();
    while let Ok(c) = rx.try_recv() {
        sent.push(c);
    }
    assert!(!sent.iter().any(|c| matches!(c, super::super::ws_client::WsCommand::LockGet { .. })), "a sync re-entry read the join lock");
    assert!(sent.iter().any(|c| matches!(c, super::super::ws_client::WsCommand::JoinRoom { .. })), "the room is joined for notices");
    let mut p = p.clone();
    super::super::sync_handler::request_join_lock(&tx, "x", &mut p);
    assert!(rx.try_recv().is_err(), "a later lock ask went out for a sync re-entry");
}

/// Finding 6: a second friend's keyless entry for a queued re-entry adds its device as a
/// source, distinct, at most eight; finding 7: a sync re-entry that lapses is never held.
#[test]
fn a_second_friends_entry_adds_its_device_to_the_reentry_and_a_lapsed_one_is_not_held() {
    let db = format!("sync-joins-{}", std::process::id());
    let mut joins = Joins::default();
    let keyless = SharedServer { join_key: String::new(), ..queued_entry(11, "") };
    joins.offer(&db, keyless.clone(), "f1", "d1", "ours");
    joins.offer(&db, keyless.clone(), "f2", "d2", "ours");
    joins.offer(&db, keyless.clone(), "f2", "d2", "ours");
    for i in 0..20 {
        joins.offer(&db, keyless.clone(), "f3", &format!("x{i}"), "ours");
    }
    let t0 = Instant::now();
    let due = joins.due(t0);
    assert_eq!(due.len(), 1, "one re-entry per server");
    assert_eq!(&due[0].devices[..2], &["d1".to_string(), "d2".to_string()], "the second friend's device was not added");
    assert_eq!(due[0].devices.len(), SYNC_FROM_MAX, "sources are distinct and bounded");
    assert!(joins.lapsed(&db, t0 + REENTRY_WAIT * 2, &|_| false).is_empty(), "a sync re-entry got only a keyed one's wait");
    let lapsed = joins.lapsed(&db, t0 + SYNC_REENTRY_WAIT, &|_| false);
    assert_eq!(lapsed, vec![keyless.server_id.clone()]);
    assert!(!held_shares(&db).iter().any(|h| h.server_id == keyless.server_id), "a keyless re-entry was held for the person");
}

/// Review F5c item 2: an answer to the open round starts a sync re-entry's wait again
/// (a keyed one's never), and a lapsed one's sources are asked again on their next
/// arrival, once per arrival.
#[test]
fn a_sync_reentry_waits_from_its_last_answer_and_a_lapsed_ones_sources_are_asked_again() {
    let db = format!("sync-progress-{}", std::process::id());
    let mut joins = Joins::default();
    let keyless = SharedServer { join_key: String::new(), ..queued_entry(12, "") };
    let keyed = queued_entry(13, "");
    joins.offer(&db, keyless.clone(), "f1", "d1", "ours");
    joins.offer(&db, keyed.clone(), "f1", "d1", "ours");
    let t0 = Instant::now();
    assert_eq!(joins.due(t0).len(), 2);
    let half = t0 + SYNC_REENTRY_WAIT / 2;
    joins.progressed(&keyless.server_id, half);
    // Late enough that a keyed one's own wait would not have run out yet, had it moved.
    joins.progressed(&keyed.server_id, t0 + SYNC_REENTRY_WAIT - REENTRY_WAIT / 2);
    let lapsed = joins.lapsed(&db, t0 + SYNC_REENTRY_WAIT, &|_| false);
    assert_eq!(lapsed, vec![keyed.server_id.clone()], "an answered round did not restart the sync re-entry's wait, or a keyed one's moved");
    assert_eq!(joins.lapsed(&db, half + SYNC_REENTRY_WAIT, &|_| false), vec![keyless.server_id.clone()], "the wait is bounded from the last answer");

    let mut asks = Asks::default();
    assert!(asks.may_ask("d1", t0, false));
    assert!(asks.take_frame("d1"));
    let later = t0 + ASK_AGAIN * 3;
    assert!(!asks.may_ask("d1", later, false), "precondition: an answered device is not asked again");
    asks.forget_answered(&["d1".to_string()]);
    assert!(asks.may_ask("d1", later, false), "a lapsed re-entry's source was never asked again on its arrival");
    assert!(!asks.may_ask("d1", later, false), "one ask per arrival");
}

/// Review F5c item 3: a completed sync re-entry holds the lock keeper only until its
/// restore registers or a settling is held, whatever the fold seats.
#[test]
fn a_reentered_server_waits_only_until_its_restore_or_settling() {
    let mut joins = Joins::default();
    joins.note_reentered("s1");
    joins.note_reentered("s2");
    assert_eq!(joins.reentered(&|_| true), vec!["s1".to_string(), "s2".to_string()]);
    assert_eq!(joins.reentered(&|sid| sid != "s1"), vec!["s2".to_string()]);
    assert_eq!(joins.reentered(&|_| true), vec!["s2".to_string()], "a forgotten re-entry came back");
}

/// Finding 8: a keyless entry skips a held state only with our own span or our own
/// signed leave in it; a keyed entry skips any held state.
#[test]
fn a_held_state_with_our_span_or_leave_skips_the_entry() {
    let (akp, alice, apk) = keys(46);
    let (ours, _) = ServerState::found("A".into(), alice.clone(), akp, apk);
    let keyless = SharedServer { server_id: ours.server_id.clone(), join_key: String::new(), ..entry(1) };
    let keyed = SharedServer { server_id: ours.server_id.clone(), ..entry(1) };
    assert!(held_skips(Some(&ours), &keyless, &alice), "our own span did not skip");
    assert!(!held_skips(None, &keyless, &alice));
    let shell = ServerState::skeleton(ours.server_id.clone());
    assert!(!held_skips(Some(&shell), &keyless, &alice), "a state with neither our span nor our leave skipped");
    assert!(held_skips(Some(&shell), &keyed, &alice), "a keyed entry re-entered a held state");
}
