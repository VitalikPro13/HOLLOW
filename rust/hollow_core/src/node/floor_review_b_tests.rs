//! Review part B (track C): the floor round's two-identities wait (H4).
use super::*;
use crate::crdt::testkeys::keys;

/// H4: a floor round ends once two OTHER member identities answered. A floor candidate
/// our own sibling carries (its answers carry `floor_base` whenever its server is in
/// recovery, `authority::floor_base_offer`) must never count as one of them.
#[test]
fn review_b_our_own_sibling_never_counts_for_the_floor_rounds_two_identities() {
    let (kp, owner, pk) = keys(1);
    let (_, op) = ServerState::found("S".into(), owner.clone(), kp, pk);
    let us = keys(2).1;
    let other = keys(3).1;
    let third = keys(4).1;
    let mut desk = FloorDesk::default();
    let asked: BTreeSet<String> = ["review-b-our-sibling", "review-b-other-device", "review-b-unplaced"].map(String::from).into();
    desk.rounds.insert(
        "s".into(),
        RoundAsk { started: Instant::now(), asked: true, devices: asked, identities: BTreeSet::new(), answers: Vec::new() },
    );
    // Our own sibling (the view places it under our identity), a device the view does not
    // place, and a device the round never asked: none of them counts.
    desk.candidate("s", "review-b-our-sibling", Some(us.clone()), &us, op.clone());
    desk.candidate("s", "review-b-unplaced", None, &us, op.clone());
    desk.candidate("s", "review-b-unasked", Some(third), &us, op.clone());
    desk.candidate("s", "review-b-other-device", Some(other.clone()), &us, op);
    let ids = desk.rounds["s"].identities.clone();
    assert_eq!(ids, BTreeSet::from([other]), "only the other identity's asked device counts for the H4 wait (us = {us})");
    assert!(ids.len() < ROUND_IDENTITIES);
}
