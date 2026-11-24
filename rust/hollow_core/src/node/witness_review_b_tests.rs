//! Review part B (track C): the witness desk's ask book over a long restore.
use super::*;
use crate::crdt::testkeys::keys;

/// A restore whose person has not chosen yet re-asks every member that did not answer,
/// every 10 minutes, each time with fresh nonces; the nonce book is never pruned, so once
/// it is full the answer of a member that comes online later is dropped.
#[test]
fn review_b_a_long_restore_still_takes_a_late_members_witness() {
    let mut desk = WitnessDesk::default();
    desk.recover("s", 1);
    let (late_kp, late_dev, _) = keys(30);
    let me_dev = keys(31).1;
    let mut members: Vec<(String, MemberSource)> = (0..63).map(|i| (format!("silent{i}"), MemberSource::JoinAnswer)).collect();
    members.push(("late".into(), MemberSource::JoinAnswer));
    desk.note_members("s", members);
    let online = std::cell::Cell::new(false);
    let devices = |m: &str| -> Vec<String> {
        if m == "late" {
            if online.get() { vec![late_dev.clone()] } else { Vec::new() }
        } else {
            (0..3).map(|d| format!("{m}-d{d}")).collect()
        }
    };
    let mut now = 10_000i64;
    for _ in 0..25 {
        let _ = desk.due_asks("s", &[], &devices, "me", &me_dev, now);
        now += ANSWER_EVERY_MS;
    }
    online.set(true);
    let asks = desk.due_asks("s", &[], &devices, "me", &me_dev, now);
    let (to, ask) = asks.into_iter().find(|(d, _)| *d == late_dev).expect("the late member is asked");
    let w = CpWitness::sign("s", &me_dev, &ask, String::new(), 0, &late_kp).expect("a well-formed witness");
    desk.receive(&to, w, None, vec![], now);
    assert_eq!(desk.taken("s").len(), 1, "the answer to an ask we sent was dropped: the nonce book filled up and was never pruned");
}

#[test]
fn review_b_control_a_short_restore_takes_the_late_witness() {
    let mut desk = WitnessDesk::default();
    desk.recover("s", 1);
    let (late_kp, late_dev, _) = keys(30);
    let me_dev = keys(31).1;
    let mut members: Vec<(String, MemberSource)> = (0..63).map(|i| (format!("silent{i}"), MemberSource::JoinAnswer)).collect();
    members.push(("late".into(), MemberSource::JoinAnswer));
    desk.note_members("s", members);
    let online = std::cell::Cell::new(false);
    let devices = |m: &str| -> Vec<String> {
        if m == "late" {
            if online.get() { vec![late_dev.clone()] } else { Vec::new() }
        } else {
            (0..3).map(|d| format!("{m}-d{d}")).collect()
        }
    };
    let mut now = 10_000i64;
    for _ in 0..2 {
        let _ = desk.due_asks("s", &[], &devices, "me", &me_dev, now);
        now += ANSWER_EVERY_MS;
    }
    online.set(true);
    let asks = desk.due_asks("s", &[], &devices, "me", &me_dev, now);
    let (to, ask) = asks.into_iter().find(|(d, _)| *d == late_dev).expect("the late member is asked");
    let w = CpWitness::sign("s", &me_dev, &ask, String::new(), 0, &late_kp).expect("a well-formed witness");
    desk.receive(&to, w, None, vec![], now);
    assert_eq!(desk.taken("s").len(), 1, "the answer to an ask we sent was dropped: the nonce book filled up and was never pruned");
}

/// A full nonce book with every nonce still fresh takes no new ask, and no ask goes out
/// whose answer the book could not take.
#[test]
fn a_full_nonce_book_sends_no_ask_whose_answer_it_could_not_take() {
    let mut desk = WitnessDesk::default();
    desk.recover("s", 1);
    desk.note_members("s", vec![("m".into(), MemberSource::JoinAnswer)]);
    let now = 10_000i64;
    for i in 0..NONCES_MAX {
        assert!(desk.asked("me", "d", "other", &format!("n{i}"), 0, now));
    }
    let devices = |_: &str| vec!["m-d0".to_string()];
    assert!(desk.due_asks("s", &[], &devices, "me", "my-dev", now).is_empty(), "an ask went out with no room for its nonce");
    assert!(!desk.due_asks("s", &[], &devices, "me", "my-dev", now + NONCE_KEEP_MS + ANSWER_EVERY_MS).is_empty(), "stale nonces give way");
}

/// A finished restore forgets its nonces; other servers' stay.
#[test]
fn a_finished_restore_forgets_its_nonces() {
    let mut desk = WitnessDesk::default();
    assert!(desk.asked("me", "d", "s", "n1", 0, 0));
    assert!(desk.asked("me", "d", "t", "n2", 0, 0));
    desk.finish("s");
    assert!(!desk.asked.contains_key("n1") && desk.asked.contains_key("n2"));
}
