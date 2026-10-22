use super::*;
use crate::crdt::hlc::HlcTimestamp;
use crate::crdt::operations::{parse_ops_tolerant, CrdtOp, CrdtPayload, MemberRole};
use crate::crdt::server_state::ServerState;
use crate::crdt::sync::{compute_delta, StateVector};
use crate::crdt::testkeys::keys;

/// An op by `tag`'s identity at an exact clock, signed like any real one.
fn op_at(tag: u8, sid: &str, ms: u64, counter: u32, payload: CrdtPayload) -> CrdtOp {
    let (kp, id, pk) = keys(tag);
    let mut op = CrdtOp {
        server_id: sid.into(),
        hlc: HlcTimestamp { physical_ms: ms, counter, actor: id.clone() },
        author: id,
        payload,
        auth: None,
    };
    op.sign(&kp, &pk);
    op
}

fn id(tag: u8) -> String {
    keys(tag).1
}

fn add(sid: &str, tag: u8) -> CrdtPayload {
    let ask = crate::crdt::operations::JoinAsk::sign(sid, 1, &keys(tag).0);
    CrdtPayload::MemberAdded { peer_id: id(tag), display_name: "m".into(), follow: None, ask: Some(ask) }
}

fn nick(tag: u8, n: &str) -> CrdtPayload {
    CrdtPayload::NicknameChanged { peer_id: id(tag), nickname: n.into() }
}

fn setting(i: usize) -> CrdtPayload {
    CrdtPayload::ServerSettingChanged { key: format!("k{i}"), value: "v".into() }
}

fn folded(sid: &str, ops: &[CrdtOp]) -> ServerState {
    let mut s = ServerState::skeleton(sid.into());
    s.ingest_remote(ops);
    s
}

/// The founding op of a server owned by tag 1, its id and clock.
fn founded() -> (CrdtOp, String, u64) {
    let (kp, owner, pk) = keys(1);
    let (_, founding) = ServerState::found("S".into(), owner, kp, pk);
    let sid = founding.server_id.clone();
    let t = founding.hlc.physical_ms;
    (founding, sid, t)
}

/// A signed op of `tag` this build cannot read, exactly as a newer build would send it.
fn unread_raw(tag: u8, sid: &str, ms: u64) -> (String, HlcTimestamp, String) {
    use base64::Engine as _;
    let (kp, author, _) = keys(tag);
    let op = op_at(tag, sid, ms, 7, nick(tag, "x"));
    let mut v = serde_json::to_value(&op).unwrap();
    v["payload"] = serde_json::json!({ "VoiceStageQueue": { "channel_id": "x", "mode": 7 } });
    let payload_json = serde_json::to_string(&v["payload"]).unwrap();
    let signed = crate::crdt::operations::signing_payload(&op.server_id, &op.hlc, &op.author, &payload_json);
    v["auth"]["sig"] = base64::engine::general_purpose::STANDARD.encode(kp.sign(signed.as_bytes())).into();
    (author, op.hlc, serde_json::to_string(&v).unwrap())
}

type Kept = Vec<(String, HlcTimestamp, String)>;

fn refs(kept: &Kept) -> Vec<KeptRef<'_>> {
    kept.iter().map(|(a, h, r)| KeptRef { author: a, hlc: h, raw: r }).collect()
}

#[derive(Debug, Default)]
struct Stats {
    rounds: usize,
    /// Items handed over, per answer.
    sent: Vec<usize>,
    /// Serialized ask sizes, per round.
    ask_bytes: Vec<usize>,
    /// How many answers split something.
    splits: usize,
}

/// One whole digest reconciliation: `r` asks `p` until an answer ends the ask. Unread ops
/// are kept when `keep_unread`.
fn reconcile(r: &mut ServerState, r_kept: &mut Kept, p: &ServerState, p_kept: &Kept, keep_unread: bool) -> Stats {
    let mut stats = Stats::default();
    let salt = new_salt();
    let base = r.checkpoint_hlc.clone();
    let mut ask = {
        let kept = refs(r_kept);
        first_ask(&entries(r, &kept, base.as_ref()), 7, salt.clone(), base.clone())
    };
    loop {
        stats.rounds += 1;
        assert!(stats.rounds <= MAX_ROUNDS as usize + 2, "the ask never ended");
        stats.ask_bytes.push(serde_json::to_string(&ask).unwrap().len());
        let p_refs = refs(p_kept);
        let p_entries = entries(p, &p_refs, ask.base.as_ref());
        let asked: Vec<(u64, u64)> = ask.ranges.iter().map(|r| (r.0, r.1)).collect();
        let (items, reply) = answer(&p_entries, &ask).expect("an honest ask is answered");
        stats.sent.push(items.len());
        let parsed = parse_ops_tolerant(&items_json(&items));
        r.ingest_remote(&parsed.ops);
        if keep_unread {
            for u in parsed.unread {
                if !r_kept.iter().any(|(a, h, _)| *a == u.author && *h == u.hlc) {
                    r_kept.push((u.author, u.hlc, u.raw));
                }
            }
        }
        if reply.groups.is_empty() {
            return stats;
        }
        stats.splits += 1;
        let kept = refs(r_kept);
        let ranges = follow_up(&entries(r, &kept, base.as_ref()), &salt, &asked, &reply).expect("an honest reply");
        ask = OpDigest { ask: 7, salt: salt.clone(), base: base.clone(), from: None, ranges, round: reply.round + 1 };
    }
}

fn ids(s: &ServerState) -> std::collections::HashSet<(String, HlcTimestamp)> {
    s.op_log.iter().map(|o| (o.author.clone(), o.hlc.clone())).collect()
}

fn holds_all_of(r: &ServerState, p: &ServerState) -> bool {
    ids(p).is_subset(&ids(r))
}

/// Siblings write under one master: a replica holding sibling A's op at t+10 still gets
/// sibling B's op stamped t+5. The per-author vector never sends it.
#[test]
fn sibling_op_older_than_the_vector_tip_still_syncs() {
    let (founding, sid, t) = founded();
    let base = vec![founding, op_at(1, &sid, t + 1, 0, add(&sid, 2))];
    let tip = op_at(2, &sid, t + 10, 0, nick(2, "from sibling A"));
    let older = op_at(2, &sid, t + 5, 0, CrdtPayload::StoragePledgeChanged { peer_id: id(2), pledge_bytes: 5 });
    let p = folded(&sid, &[base.clone(), vec![tip.clone(), older.clone()]].concat());
    let mut r = folded(&sid, &[base, vec![tip]].concat());

    let vector_sends = compute_delta(&p.op_log, &StateVector::from_server_state(&r));
    assert!(vector_sends.is_empty(), "the vector path was expected to miss the older sibling op");

    reconcile(&mut r, &mut Vec::new(), &p, &Vec::new(), true);
    assert!(holds_all_of(&r, &p), "the digest left the older sibling op behind");
}

/// An op refused while its author lacked a grant waits in `held`; once held expires and a
/// later op by the same author has landed, the vector never sends it again.
#[test]
fn held_op_expired_after_a_later_op_still_syncs() {
    let (founding, sid, t) = founded();
    let base = vec![founding, op_at(1, &sid, t + 1, 0, add(&sid, 3))];
    let grant = op_at(1, &sid, t + 2, 0, CrdtPayload::RoleChanged { peer_id: id(3), role: MemberRole::Admin, priority: 3 });
    let rename = op_at(3, &sid, t + 3, 0, CrdtPayload::ServerRenamed { new_name: "by the admin".into() });
    let later = op_at(3, &sid, t + 4, 0, nick(3, "admin"));
    let p = folded(&sid, &[base.clone(), vec![grant.clone(), rename.clone(), later.clone()]].concat());
    assert_eq!(p.name(), "by the admin", "the setup: an admin may rename");
    // R refused the rename before the grant reached it, and the held copy expired.
    let mut r = folded(&sid, &[base, vec![later]].concat());

    let vector_sends = compute_delta(&p.op_log, &StateVector::from_server_state(&r));
    assert!(!vector_sends.iter().any(|o| o.hlc == rename.hlc), "the vector path was expected to skip the rename");

    reconcile(&mut r, &mut Vec::new(), &p, &Vec::new(), true);
    assert!(holds_all_of(&r, &p));
    assert_eq!(r.name(), "by the admin");
}

/// One op missing near the start of a 2,000-op log is found within the round cap, and the
/// answers hand over a few dozen ops, not the log.
#[test]
fn digest_finds_an_old_hole_in_a_long_log() {
    let (founding, sid, t) = founded();
    let mut ops = vec![founding];
    ops.extend((0..2000).map(|i| op_at(1, &sid, t + 1 + i as u64, 0, setting(i))));
    let p = folded(&sid, &ops);
    let mut r = folded(&sid, &[&ops[..11], &ops[12..]].concat());
    let stats = reconcile(&mut r, &mut Vec::new(), &p, &Vec::new(), true);
    assert!(holds_all_of(&r, &p));
    assert!(stats.rounds <= MAX_ROUNDS as usize + 1, "{stats:?}");
    assert!(stats.sent.iter().sum::<usize>() <= 3 * SEND_WHOLE, "too much handed over: {stats:?}");
}

/// An asker ahead of the answerer by a few ops gets back at most a handful, in one round.
#[test]
fn digest_ahead_requester_gets_at_most_a_few_ops_back() {
    let (founding, sid, t) = founded();
    let mut ops = vec![founding];
    ops.extend((0..1000).map(|i| op_at(1, &sid, t + 1 + i as u64, 0, setting(i))));
    let p = folded(&sid, &ops);
    ops.extend((0..5).map(|i| op_at(1, &sid, t + 2000 + i as u64, 0, setting(5000 + i))));
    let mut r = folded(&sid, &ops);
    let stats = reconcile(&mut r, &mut Vec::new(), &p, &Vec::new(), true);
    assert_eq!(stats.rounds, 1, "{stats:?}");
    assert!(stats.sent[0] <= 10, "{stats:?}");
}

/// A tiny xorshift, so the random trials replay.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

/// Random overlaps both ways, sibling-style clocks included: after one reconciliation the
/// asker holds every op of the answerer, within the round cap.
#[test]
fn digest_random_sets_converge() {
    let (founding, sid, t) = founded();
    let base = [founding, op_at(1, &sid, t + 1, 0, add(&sid, 2)), op_at(1, &sid, t + 2, 0, add(&sid, 3))];
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15);
    for trial in 0..60 {
        let size = 20 + rng.below(400) as usize;
        let span = 1 + rng.below(3000);
        let pool: Vec<CrdtOp> = (0..size)
            .map(|i| {
                let tag = [1u8, 2, 3][rng.below(3) as usize];
                // Large counters too: per-device counter lanes do not step by one.
                let counter = if rng.below(4) == 0 { (rng.next() as u32) | 1 << 24 } else { 0 };
                op_at(tag, &sid, t + 10 + rng.below(span), counter, nick(tag, &format!("n{trial}-{i}")))
            })
            .collect();
        let pick = |rng: &mut Rng, keep: u64| -> Vec<CrdtOp> {
            base.iter().cloned().chain(pool.iter().filter(|_| rng.below(100) < keep).cloned()).collect()
        };
        let (pk, rk) = (30 + rng.below(70), rng.below(100));
        let p = folded(&sid, &pick(&mut rng, pk));
        let mut r = folded(&sid, &pick(&mut rng, rk));
        let stats = reconcile(&mut r, &mut Vec::new(), &p, &Vec::new(), true);
        assert!(holds_all_of(&r, &p), "trial {trial}: an op was lost ({stats:?})");
    }
}

/// An answerer never hands over what the asker's checkpoint already pruned.
#[test]
fn digest_never_sends_what_the_requesters_checkpoint_pruned() {
    let (kp, owner, pk) = keys(1);
    let (mut s, _) = ServerState::found("S".into(), owner.clone(), kp, pk);
    for i in 0..50 {
        s.author_checked(setting(i)).expect("the owner writes");
    }
    let before_checkpoint = s.clone();
    let covers = s.horizon();
    let cp = s.checkpoint_json(&owner, &[], crate::crdt::hlc::wall_clock_ms()).unwrap();
    s.author_checked(CrdtPayload::ServerCheckpoint { state: cp, covers }).expect("the owner checkpoints");
    let base = s.checkpoint_hlc.clone().expect("rebased");
    let ask = first_ask(&entries(&s, &[], Some(&base)), 1, new_salt(), Some(base.clone()));
    let p_entries = entries(&before_checkpoint, &[], Some(&base));
    let (items, _) = answer(&p_entries, &ask).unwrap();
    for item in items {
        if let Item::Op(op) = item {
            assert!(
                crate::crdt::server_state::retained_under(op, &base, true),
                "an op the asker's checkpoint pruned was handed over",
            );
        }
    }
}

/// An op both sides keep unread compares equal: nothing moves.
#[test]
fn digest_counts_kept_unread_ops_as_held() {
    let (founding, sid, t) = founded();
    let ops = vec![founding, op_at(1, &sid, t + 1, 0, add(&sid, 2))];
    let kept: Kept = vec![unread_raw(2, &sid, t + 5)];
    let p = folded(&sid, &ops);
    let mut r = folded(&sid, &ops);
    let stats = reconcile(&mut r, &mut kept.clone(), &p, &kept, true);
    assert_eq!(stats.sent, vec![0], "a kept op both hold was handed over");

    // Held only by the answerer: it goes over as signed and is kept.
    let mut r_kept = Vec::new();
    reconcile(&mut r, &mut r_kept, &p, &kept, true);
    assert_eq!(r_kept, kept, "the kept op did not arrive byte for byte");
}

/// A kept op the asker can never hold (its own bound pushes it out) costs one leaf a sync,
/// never a split chasing it again.
#[test]
fn digest_kept_asymmetry_costs_one_leaf_per_sync() {
    let (founding, sid, t) = founded();
    let mut ops = vec![founding];
    ops.extend((0..300).map(|i| op_at(1, &sid, t + 1 + i as u64, 0, setting(i))));
    let kept: Kept = vec![unread_raw(1, &sid, t + 100)];
    let p = folded(&sid, &ops);
    let mut r = folded(&sid, &ops);
    for sync in 0..3 {
        let stats = reconcile(&mut r, &mut Vec::new(), &p, &kept, false);
        let sends = stats.sent.iter().filter(|n| **n > 0).count();
        assert_eq!(sends, 1, "sync {sync}: {stats:?}");
        assert!(stats.sent.iter().sum::<usize>() <= SEND_WHOLE + 1, "sync {sync}: {stats:?}");
        assert!(stats.rounds <= MAX_ROUNDS as usize + 1, "sync {sync}: {stats:?}");
    }
}

/// The last round sends whatever differs, however large.
#[test]
fn digest_round_cap_forces_a_send() {
    let (founding, sid, t) = founded();
    let mut ops = vec![founding];
    ops.extend((0..200).map(|i| op_at(1, &sid, t + 1 + i as u64, 0, setting(i))));
    let p = folded(&sid, &ops);
    let salt = new_salt();
    let mut ask = first_ask(&[], 1, salt, None);
    ask.from = None;
    ask.ranges = vec![Range(0, u64::MAX - 1, 0, "AAAAAAAAAAAAAAAAAAAAAA".into())];
    ask.round = MAX_ROUNDS;
    let (items, reply) = answer(&entries(&p, &[], None), &ask).unwrap();
    assert!(reply.groups.is_empty());
    assert_eq!(items.len(), p.op_log.len());
    ask.round = MAX_ROUNDS + 1;
    assert!(answer(&entries(&p, &[], None), &ask).is_none(), "an ask past the cap was answered");
}

/// An empty fingerprint forces the whole range, never a split.
#[test]
fn digest_forced_range_never_splits() {
    let (founding, sid, t) = founded();
    let mut ops = vec![founding];
    ops.extend((0..200).map(|i| op_at(1, &sid, t + 1 + i as u64, 0, setting(i))));
    let p = folded(&sid, &ops);
    let mut ask = first_ask(&[], 1, new_salt(), None);
    ask.from = None;
    ask.ranges = vec![Range(0, u64::MAX - 1, 0, String::new())];
    let (items, reply) = answer(&entries(&p, &[], None), &ask).unwrap();
    assert!(reply.groups.is_empty());
    assert_eq!(items.len(), p.op_log.len());
}

/// One answer splits into at most `SPLIT_BUDGET` sub-ranges, and the follow-up asks no
/// more than that.
#[test]
fn digest_split_budget_bounds_both_sides() {
    let (founding, sid, t) = founded();
    let mut ops = vec![founding];
    ops.extend((0..4000).map(|i| op_at(1, &sid, t + 1 + i as u64, 0, setting(i))));
    let p = folded(&sid, &ops);
    let ranges: Vec<Range> =
        (0..40u64).map(|k| Range(t + 1 + k * 100, t + 100 + k * 100, 0, "AAAAAAAAAAAAAAAAAAAAAA".into())).collect();
    let salt = new_salt();
    let ask = OpDigest { ask: 1, salt: salt.clone(), base: None, from: None, ranges, round: 0 };
    let (_, reply) = answer(&entries(&p, &[], None), &ask).unwrap();
    let subs: usize = reply.groups.iter().map(Vec::len).sum();
    assert!(subs <= SPLIT_BUDGET && !reply.groups.is_empty(), "{subs} sub-ranges");
    let empty = folded(&sid, &ops[..1]);
    let asked: Vec<(u64, u64)> = ask.ranges.iter().map(|r| (r.0, r.1)).collect();
    let next = follow_up(&entries(&empty, &[], None), &salt, &asked, &reply).expect("an honest reply");
    assert!(next.len() <= SPLIT_BUDGET);
    let too_many = OpDigest { ranges: vec![Range(0, 1, 0, String::new()); SPLIT_BUDGET + 1], ..ask };
    assert!(answer(&entries(&p, &[], None), &too_many).is_none());
}

/// The first ask grows with the log's logarithm, never with its authors.
#[test]
fn digest_request_size_is_log_of_the_log() {
    let (founding, sid, t) = founded();
    let mut sizes = Vec::new();
    for n in [10usize, 1000, 10_000] {
        let mut ops = vec![founding.clone()];
        // A different author per op: the vector's worst case.
        ops.extend((0..n).map(|i| op_at(1, &sid, t + 1 + i as u64, 0, setting(i))));
        let s = folded(&sid, &ops);
        let ask = first_ask(&entries(&s, &[], None), 1, new_salt(), None);
        sizes.push((ask.ranges.len(), serde_json::to_string(&ask).unwrap().len()));
    }
    assert!(sizes.iter().all(|(ranges, bytes)| *ranges <= 16 && *bytes <= 1200), "{sizes:?}");
}

/// Equal sets print equal under one salt; a different salt prints differently.
#[test]
fn digest_fingerprint_is_keyed_by_the_salt() {
    let (founding, sid, t) = founded();
    let s = folded(&sid, &[founding, op_at(1, &sid, t + 1, 0, setting(1))]);
    let salt = new_salt();
    let a = first_ask(&entries(&s, &[], None), 1, salt.clone(), None);
    let b = first_ask(&entries(&s.clone(), &[], None), 1, salt, None);
    let c = first_ask(&entries(&s, &[], None), 1, new_salt(), None);
    assert_eq!(a.ranges, b.ranges);
    assert_ne!(a.ranges, c.ranges);
}

// g13-s1a review: malformed digests cost nothing.

fn big_log(n: usize) -> (ServerState, String, u64) {
    let (founding, sid, t) = founded();
    let mut ops = vec![founding];
    ops.extend((0..n).map(|i| op_at(1, &sid, t + 1 + i as u64, 0, setting(i))));
    (folded(&sid, &ops), sid, t)
}

/// An ask of 256 copies of one whole-log range is refused: ranges must be sorted and
/// disjoint, so an answer costs O(log size).
#[test]
fn review_answer_refuses_overlapping_whole_log_ranges() {
    let (p, _, _) = big_log(10_000);
    let es = entries(&p, &[], None);
    let ranges = vec![Range(0, u64::MAX - 1, 1, "AAAAAAAAAAAAAAAAAAAAAA".into()); SPLIT_BUDGET];
    let ask = OpDigest { ask: 1, salt: new_salt(), base: None, from: None, ranges, round: 0 };
    assert!(answer(&es, &ask).is_none(), "overlapping ranges were answered");
    let reversed = OpDigest { ranges: vec![Range(10, 5, 0, String::new())], ..ask.clone() };
    assert!(answer(&es, &reversed).is_none(), "a range with lo > hi was answered");
}

/// A reply of 5,000 whole-log sub-ranges is dropped whole, at once.
#[test]
fn review_follow_up_bounds_the_sub_ranges_it_compares() {
    let (r, _, _) = big_log(10_000);
    let es = entries(&r, &[], None);
    let salt = new_salt();
    let asked = [(0, u64::MAX - 1)];
    let group = vec![Range(0, u64::MAX - 1, 1, "AAAAAAAAAAAAAAAAAAAAAA".into()); 5_000];
    let reply = DigestReply { ask: 1, round: 0, groups: vec![group], vector: false };
    let t0 = std::time::Instant::now();
    assert!(follow_up(&es, &salt, &asked, &reply).is_none(), "a hostile reply was followed");
    assert!(t0.elapsed() < std::time::Duration::from_millis(50), "follow_up spent {:?} on one hostile reply", t0.elapsed());
    // Sorted and disjoint but outside what we asked, or one sub-range past the budget.
    let outside = DigestReply { groups: vec![vec![Range(5, 6, 1, "x".into()), Range(7, 8, 1, "y".into())]], ..reply.clone() };
    assert!(follow_up(&es, &salt, &[(10, 20)], &outside).is_none());
    let over: Vec<Range> = (0..=SPLIT_BUDGET as u64).map(|k| Range(2 * k, 2 * k, 1, "z".into())).collect();
    let over = DigestReply { groups: vec![over], ..reply.clone() };
    assert!(follow_up(&es, &salt, &asked, &over).is_none());
    // Inside what we asked and under the budget, but two groups covering the same span.
    let twice = vec![Range(0, 10, 1, "a".into()), Range(11, 20, 1, "b".into())];
    let overlapping = DigestReply { groups: vec![twice.clone(), twice], ..reply };
    assert!(follow_up(&es, &salt, &asked, &overlapping).is_none(), "overlapping groups were followed");
}

/// A reconnect's burst of first asks builds the compared set once: later asks on an
/// unchanged log reuse it, and any change to the log or the kept ops builds it again.
#[test]
fn review_entries_cost() {
    let (mut r, sid, t) = big_log(10_000);
    let t0 = std::time::Instant::now();
    let cold = entries(&r, &[], None).len();
    let cold_cost = t0.elapsed();
    let t1 = std::time::Instant::now();
    for _ in 0..10 {
        assert_eq!(entries(&r, &[], None).len(), cold);
    }
    let warm_cost = t1.elapsed() / 10;
    assert!(warm_cost * 2 < cold_cost, "a burst rebuilds the set: cold {cold_cost:?}, warm {warm_cost:?}");
    r.ingest_remote(&[op_at(1, &sid, t + 50_000, 0, setting(99_999))]);
    assert_eq!(entries(&r, &[], None).len(), cold + 1, "a changed log reused the old set");
    let kept: Kept = vec![unread_raw(1, &sid, t + 60_000)];
    assert_eq!(entries(&r, &refs(&kept), None).len(), cold + 2, "new kept ops reused the old set");
}

/// The cached set indexes into the log: the same ops in another order must not reuse it.
#[test]
fn a_reordered_log_never_reuses_the_cached_set() {
    let (mut r, _, _) = big_log(8);
    let _ = entries(&r, &[], None);
    let last = r.op_log.len() - 1;
    r.op_log.swap(1, last);
    for e in entries(&r, &[], None) {
        let Item::Op(op) = e.item else { panic!("no kept ops here") };
        assert_eq!(e.id, id_hash(&op.author, &op.hlc), "an entry points at another op");
    }
}
