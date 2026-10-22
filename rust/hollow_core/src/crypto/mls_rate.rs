//! The receiver epoch-rate rule (AR-27, design `g13-s3` sections 2 and 7): judged
//! on the ratchet tree before the commit and the commit alone, so every member on a
//! chain rules the same way, whenever and wherever it processes the commit.

use super::mls_tally::{self, capped, LeafRecord, MasterTally, Tally, CAP_EPOCHS, MAX_CARRIED};
use super::{LeafIdentity, LeafView};
use std::collections::HashSet;

/// What the rule reads from one commit.
pub(crate) struct RateInput<'a> {
    /// The group epoch the commit was built at.
    pub epoch: u64,
    /// The tree before the commit.
    pub leaves: &'a [LeafRecord],
    pub committer: &'a LeafIdentity,
    pub adds: &'a [LeafIdentity],
    pub removes: &'a [LeafView],
    /// The commit carries no proposal at all (a path-only self-update).
    pub no_proposals: bool,
}

/// Who a commit charges: its committer's master when it touches the committer's own
/// leaves or carries no proposal, and each other master whose seated device it
/// repairs (removed and re-added in one commit).
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Charges {
    pub committer: bool,
    pub repaired: Vec<String>,
}

impl Charges {
    pub(crate) fn any(&self) -> bool {
        self.committer || !self.repaired.is_empty()
    }
}

pub(crate) fn charges(input: &RateInput) -> Charges {
    let m = input.committer.master.as_str();
    let seated = |device: &str| input.leaves.iter().any(|l| l.identity.as_ref().is_some_and(|i| i.device == device));
    let committer = input.no_proposals
        || input.adds.iter().any(|a| a.master == m)
        || input.removes.iter().filter_map(LeafView::bound).any(|r| r.master == m);
    let mut repaired: Vec<String> = input
        .adds
        .iter()
        .filter(|a| a.master != m && seated(&a.device))
        .filter(|a| input.removes.iter().filter_map(LeafView::bound).any(|r| r.device == a.device))
        .map(|a| a.master.clone())
        .collect();
    repaired.sort();
    repaired.dedup();
    Charges { committer, repaired }
}

/// G(M): every bound leaf of every other master is capable, so every member outside
/// M's identity judges by these rules. An unbound leaf counts as not capable.
pub(crate) fn others_all_capable(leaves: &[LeafRecord], master: &str) -> bool {
    leaves.iter().all(|l| match &l.identity {
        None => false,
        Some(i) => i.master == master || l.capable(),
    })
}

/// Masters the tree shows unfit to act for the group (design `g13-s3` 2.5, 7 B), in
/// one pass: at the cap by their OWN history ([`mls_tally::own_tallies`]; what others
/// carried for them only caps repairs), or (`as_committer` false) holding a leaf
/// without a tally while every other master's leaves carry one. As committer only a
/// master whose every leaf carries a tally can be unfit, so a pre-0.13 device never
/// sees a second committer elected.
pub(crate) fn unfit_masters(leaves: &[LeafRecord], epoch: u64, as_committer: bool, is_owner: impl Fn(&str) -> bool) -> HashSet<String> {
    if leaves.iter().any(|l| l.identity.is_none()) {
        return HashSet::new();
    }
    let incapable: HashSet<&str> = leaves.iter().filter(|l| !l.capable()).filter_map(LeafRecord::master).collect();
    mls_tally::own_tallies(leaves, epoch)
        .into_iter()
        .filter(|(master, tally)| {
            // G(M): no other master keeps a leaf without a tally.
            let others_capable = incapable.iter().all(|m| *m == master.as_str());
            if is_owner(master) || !others_capable {
                return false;
            }
            let all_capable = !incapable.contains(master.as_str());
            let at_cap = capped(tally, epoch);
            if as_committer { all_capable && at_cap } else { at_cap || !all_capable }
        })
        .map(|(master, _)| master)
        .collect()
}

/// Whether [`unfit_masters`] names `master`.
#[cfg(test)]
pub(crate) fn unfit(leaves: &[LeafRecord], epoch: u64, master: &str, as_committer: bool, is_owner: impl Fn(&str) -> bool) -> bool {
    unfit_masters(leaves, epoch, as_committer, is_owner).contains(master)
}

/// The histories the committer's leaf already carries for other masters that its
/// next leaf keeps: only from a leaf a commit wrote (a KeyPackage's list is the
/// minter's word alone), never one naming the committer's own master, each well
/// ordered and still inside the cap's window.
fn prior_carried(input: &RateInput) -> Vec<(String, Vec<u64>)> {
    let (m, e) = (input.committer.master.as_str(), input.epoch);
    input
        .leaves
        .iter()
        .find(|l| l.commit_written && l.identity.as_ref() == Some(input.committer))
        .and_then(|l| l.tally.as_ref())
        .map(|t| t.carried.clone())
        .unwrap_or_default()
        .into_iter()
        .filter(|(master, list)| {
            master != m && mls_tally::well_ordered(list, e) && list.first().is_some_and(|h| h.saturating_add(CAP_EPOCHS) > e)
        })
        .collect()
}

/// Repaired masters a commit must leave for later so its leaf's carried list stays
/// within [`MAX_CARRIED`]: the first ones by id fit, the rest wait.
pub(crate) fn carried_overflow(input: &RateInput, charges: &Charges) -> Vec<String> {
    let kept = prior_carried(input).into_iter().filter(|(n, _)| !charges.repaired.contains(n)).count();
    charges.repaired.iter().skip(MAX_CARRIED.saturating_sub(kept)).cloned().collect()
}

/// The tally the committer's new leaf must state, or why no tally can be honest:
/// its own list one counted commit on (when charged) or unchanged, a fresh history
/// for each master it repairs, and [`prior_carried`] for the others. Never a tally
/// that does not decode. `refreshed_day` is the committer's to state.
pub(crate) fn expected_tally(input: &RateInput, charges: &Charges, refreshed_day: u32) -> Result<Tally, String> {
    let (m, e) = (input.committer.master.as_str(), input.epoch);
    let read = |master: &str| match mls_tally::master_tally(input.leaves, master, e) {
        MasterTally::List(l) => Ok(l),
        MasterTally::Unreadable => Err(format!("the tree's history of {master} is unreadable")),
    };
    let own = read(m)?;
    let epochs = if charges.committer { Tally::after_counted(&own, e) } else { own };
    let mut carried: Vec<(String, Vec<u64>)> = Vec::new();
    for n in &charges.repaired {
        carried.push((n.clone(), Tally::after_counted(&read(n)?, e)));
    }
    carried.extend(prior_carried(input).into_iter().filter(|(n, _)| !charges.repaired.contains(n)));
    carried.sort();
    Tally { refreshed_day, epochs, carried }.checked()
}

/// The tally an exempt committer (the anchored owner, a meeting host) states when no
/// honest one can be derived: its own list restarted, readable repaired histories one
/// on, and nothing it cannot encode. No receiver judges it.
pub(crate) fn fresh_tally(input: &RateInput, charges: &Charges, refreshed_day: u32) -> Tally {
    let e = input.epoch;
    let epochs = if charges.committer { vec![e] } else { Vec::new() };
    let mut carried: Vec<(String, Vec<u64>)> = charges
        .repaired
        .iter()
        .filter_map(|n| match mls_tally::master_tally(input.leaves, n, e) {
            MasterTally::List(l) => Some((n.clone(), Tally::after_counted(&l, e))),
            MasterTally::Unreadable => None,
        })
        .collect();
    carried.extend(prior_carried(input).into_iter().filter(|(n, _)| !charges.repaired.contains(n)));
    carried.sort();
    Tally { refreshed_day, epochs: epochs.clone(), carried }
        .checked()
        .unwrap_or(Tally { refreshed_day, epochs, carried: Vec::new() })
}

/// Whether the cap refuses the commit's charges: the committer's, or any repaired
/// master's.
pub(crate) fn over_cap(input: &RateInput, charges: &Charges) -> Option<String> {
    let e = input.epoch;
    if charges.committer && capped(&mls_tally::master_tally(input.leaves, &input.committer.master, e), e) {
        return Some(format!("{} is at its cap of counted commits", input.committer.master));
    }
    charges
        .repaired
        .iter()
        .find(|n| capped(&mls_tally::master_tally(input.leaves, n, e), e))
        .map(|n| format!("a repair of {n}'s device while {n} is at its cap"))
}

/// The ruling. `path` is the committer's new leaf: `None` without an update path,
/// `Some(None)` for a leaf that does not carry a tally. `is_owner` names the
/// server's owner, exempt from every rule here (it can delete the server anyway).
pub(crate) fn rate_refusal(input: &RateInput, path: Option<Option<&Tally>>, is_owner: impl Fn(&str) -> bool) -> Option<String> {
    let m = input.committer.master.as_str();
    if is_owner(m) || !others_all_capable(input.leaves, m) {
        return None;
    }
    let charges = charges(input);
    let stated = match path {
        Some(Some(t)) => t,
        Some(None) if !charges.any() => return None,
        None if !charges.any() => return None,
        _ => return Some("a commit that counts against a master must carry a leaf with its tally".into()),
    };
    let expected = match expected_tally(input, &charges, stated.refreshed_day) {
        Ok(t) => t,
        Err(why) => return Some(why),
    };
    let mut carried = stated.carried.clone();
    carried.sort();
    if stated.epochs != expected.epochs || carried != expected.carried {
        return Some(format!("its leaf states the tally {stated:?}, the tree says {expected:?}"));
    }
    over_cap(input, &charges)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(device: &str, master: &str) -> LeafIdentity {
        LeafIdentity { device: device.into(), master: master.into() }
    }

    fn leaf(index: u32, device: &str, master: &str, epochs: Vec<u64>, carried: Vec<(String, Vec<u64>)>) -> LeafRecord {
        LeafRecord {
            index,
            identity: Some(id(device, master)),
            declares: true,
            tally: Some(Tally { refreshed_day: 1, epochs, carried }),
            commit_written: true,
            fresh_day: 1,
        }
    }

    fn tree() -> Vec<LeafRecord> {
        vec![leaf(0, "o1", "owner", vec![], vec![]), leaf(1, "m1", "m", vec![], vec![]), leaf(2, "n1", "n", vec![], vec![])]
    }

    fn t(epochs: Vec<u64>, carried: Vec<(&str, Vec<u64>)>) -> Tally {
        Tally { refreshed_day: 9, epochs, carried: carried.into_iter().map(|(m, l)| (m.to_string(), l)).collect() }
    }

    fn owner(m: &str) -> bool {
        m == "owner"
    }

    #[test]
    fn an_honest_self_update_passes_and_a_lying_tally_is_refused() {
        let leaves = tree();
        let committer = id("m1", "m");
        let input = RateInput { epoch: 10, leaves: &leaves, committer: &committer, adds: &[], removes: &[], no_proposals: true };
        assert_eq!(rate_refusal(&input, Some(Some(&t(vec![10], vec![]))), owner), None);
        assert!(rate_refusal(&input, Some(Some(&t(vec![], vec![]))), owner).is_some(), "an unchanged list");
        assert!(rate_refusal(&input, Some(Some(&t(vec![10, 3], vec![]))), owner).is_some(), "an invented entry");
        assert!(rate_refusal(&input, Some(None), owner).is_some(), "a counted commit from a leaf with no tally");
        assert!(rate_refusal(&input, None, owner).is_some());
    }

    #[test]
    fn three_counted_commits_in_twelve_epochs_then_refused_but_never_the_owner() {
        let mut leaves = tree();
        leaves[1] = leaf(1, "m1", "m", vec![9, 8, 7], vec![]);
        leaves[0] = leaf(0, "o1", "owner", vec![9, 8, 7], vec![]);
        let m = id("m1", "m");
        let input = RateInput { epoch: 10, leaves: &leaves, committer: &m, adds: &[], removes: &[], no_proposals: true };
        assert!(rate_refusal(&input, Some(Some(&t(vec![10, 9, 8], vec![]))), owner).is_some_and(|w| w.contains("cap")));
        let later = RateInput { epoch: 19, ..input };
        assert_eq!(rate_refusal(&later, Some(Some(&t(vec![19, 9, 8], vec![]))), owner), None, "the oldest is twelve epochs back");
        let o = id("o1", "owner");
        let by_owner = RateInput { epoch: 10, leaves: &leaves, committer: &o, adds: &[], removes: &[], no_proposals: true };
        assert_eq!(rate_refusal(&by_owner, Some(Some(&t(vec![10, 9, 8], vec![]))), owner), None);
        assert_eq!(rate_refusal(&by_owner, None, owner), None, "the owner is exempt from every rule");
    }

    #[test]
    fn a_repair_of_another_masters_device_is_charged_to_that_master() {
        let mut leaves = tree();
        leaves[2] = leaf(2, "n1", "n", vec![9, 8, 7], vec![]);
        let m = id("m1", "m");
        let adds = [id("n1", "n")];
        let removes = [LeafView::Bound(id("n1", "n"))];
        let input = RateInput { epoch: 10, leaves: &leaves, committer: &m, adds: &adds, removes: &removes, no_proposals: false };
        let c = charges(&input);
        assert_eq!(c, Charges { committer: false, repaired: vec!["n".into()] });
        assert!(rate_refusal(&input, Some(Some(&t(vec![], vec![("n", vec![10, 9, 8])]))), owner).is_some_and(|w| w.contains("cap")));
        let mut fresher = leaves.clone();
        fresher[2] = leaf(2, "n1", "n", vec![4], vec![]);
        let input = RateInput { epoch: 10, leaves: &fresher, committer: &m, adds: &adds, removes: &removes, no_proposals: false };
        assert_eq!(rate_refusal(&input, Some(Some(&t(vec![], vec![("n", vec![10, 4])]))), owner), None);
        assert!(rate_refusal(&input, Some(Some(&t(vec![], vec![]))), owner).is_some(), "the repair must be carried");
        assert!(rate_refusal(&input, Some(Some(&t(vec![10], vec![("n", vec![10, 4])]))), owner).is_some(), "nor charged to the committer");
    }

    #[test]
    fn a_carried_history_follows_its_master_and_lapses_after_the_window() {
        // n's freshest history is what m's leaf carries for it.
        let leaves = vec![
            leaf(0, "o1", "owner", vec![], vec![]),
            leaf(1, "m1", "m", vec![], vec![("n".into(), vec![9, 8, 7])]),
            leaf(2, "n1", "n", vec![3], vec![]),
        ];
        let n = id("n1", "n");
        let input = RateInput { epoch: 10, leaves: &leaves, committer: &n, adds: &[], removes: &[], no_proposals: true };
        assert!(rate_refusal(&input, Some(Some(&t(vec![10, 9, 8], vec![]))), owner).is_some_and(|w| w.contains("cap")), "a repaired flooder keeps its history");
        // m's next commit keeps the entry while it can still cap, and drops it after.
        let m = id("m1", "m");
        let keep = RateInput { epoch: 15, leaves: &leaves, committer: &m, adds: &[], removes: &[], no_proposals: true };
        assert_eq!(rate_refusal(&keep, Some(Some(&t(vec![15], vec![("n", vec![9, 8, 7])]))), owner), None);
        assert!(rate_refusal(&keep, Some(Some(&t(vec![15], vec![]))), owner).is_some(), "dropped too early");
        let lapse = RateInput { epoch: 21, ..keep };
        assert_eq!(rate_refusal(&lapse, Some(Some(&t(vec![21], vec![]))), owner), None);
        assert!(rate_refusal(&lapse, Some(Some(&t(vec![21], vec![("n", vec![9, 8, 7])]))), owner).is_some(), "kept too long");
    }

    #[test]
    fn uncounted_commits_keep_the_tally_and_may_come_from_a_leaf_without_one() {
        let mut leaves = tree();
        leaves[1] = leaf(1, "m1", "m", vec![5], vec![]);
        let m = id("m1", "m");
        let joiner = [id("j1", "j")];
        let input = RateInput { epoch: 10, leaves: &leaves, committer: &m, adds: &joiner, removes: &[], no_proposals: false };
        assert!(!charges(&input).any(), "a join charges nobody");
        assert_eq!(rate_refusal(&input, None, owner), None);
        let kicked = [LeafView::Bound(id("n1", "n"))];
        let kick = RateInput { adds: &[], removes: &kicked, ..input };
        assert_eq!(rate_refusal(&kick, Some(Some(&t(vec![5], vec![]))), owner), None);
        assert_eq!(rate_refusal(&kick, Some(None), owner), None, "a 0.12.2 device's kick");
        assert!(rate_refusal(&kick, Some(Some(&t(vec![], vec![]))), owner).is_some(), "an uncounted commit cannot reset the tally");
        // Anything that touches the committer's own leaves counts.
        let own_dev = [id("m2", "m")];
        let own = RateInput { adds: &own_dev, removes: &[], ..input };
        assert!(charges(&own).committer);
    }

    #[test]
    fn nothing_new_is_refused_while_another_masters_leaf_is_pre_0_13() {
        let mut leaves = tree();
        leaves[2].tally = None;
        leaves[2].declares = false;
        let m = id("m1", "m");
        let input = RateInput { epoch: 10, leaves: &leaves, committer: &m, adds: &[], removes: &[], no_proposals: true };
        assert_eq!(rate_refusal(&input, None, owner), None);
        let mut with_unbound = tree();
        with_unbound[2].identity = None;
        let input = RateInput { leaves: &with_unbound, ..input };
        assert_eq!(rate_refusal(&input, None, owner), None, "an unbound leaf is not capable");
        // Only other masters' leaves matter: m's own old leaf does not turn the rule off.
        let mut own_old = tree();
        own_old.push(LeafRecord { index: 3, identity: Some(id("m2", "m")), declares: false, tally: None, commit_written: false, fresh_day: 0 });
        let input = RateInput { leaves: &own_old, ..input };
        assert!(rate_refusal(&input, None, owner).is_some());
    }

    #[test]
    fn an_unreadable_history_fails_closed_for_its_own_master_only() {
        let mut leaves = tree();
        leaves[1] = leaf(1, "m1", "m", vec![12], vec![]);
        let m = id("m1", "m");
        let input = RateInput { epoch: 10, leaves: &leaves, committer: &m, adds: &[], removes: &[], no_proposals: true };
        assert!(rate_refusal(&input, Some(Some(&t(vec![10, 12], vec![]))), owner).is_some(), "a future entry");
        let n = id("n1", "n");
        let by_n = RateInput { committer: &n, ..input };
        assert_eq!(rate_refusal(&by_n, Some(Some(&t(vec![10], vec![]))), owner), None);
    }

    fn record(index: u32, device: &str, master: &str, tally: Tally, commit_written: bool) -> LeafRecord {
        LeafRecord { index, identity: Some(id(device, master)), declares: true, tally: Some(tally), commit_written, fresh_day: 1 }
    }

    /// Review H2: a KeyPackage-seated leaf's carried list is the minter's word; the
    /// committer's next leaf keeps nothing of it, so it never becomes another
    /// master's history.
    #[test]
    fn a_key_package_cannot_plant_a_history_for_another_master() {
        let e = 40u64;
        let forged = vec![("victim".to_string(), vec![e - 1, e - 2, e - 3]), ("attacker".to_string(), vec![e - 1])];
        let leaves = vec![
            record(0, "o1", "owner", Tally::default(), true),
            record(1, "v1", "victim", Tally { refreshed_day: 1, epochs: vec![10], carried: vec![] }, true),
            record(2, "a1", "attacker", Tally { refreshed_day: 1, epochs: vec![], carried: forged.clone() }, false),
        ];
        let a = id("a1", "attacker");
        let input = RateInput { epoch: e, leaves: &leaves, committer: &a, adds: &[], removes: &[], no_proposals: true };
        let honest = Tally { refreshed_day: 1, epochs: vec![e], carried: vec![] };
        let planted = Tally { refreshed_day: 1, epochs: vec![e], carried: forged };
        assert_eq!(rate_refusal(&input, Some(Some(&honest)), owner), None);
        assert!(rate_refusal(&input, Some(Some(&planted)), owner).is_some(), "the KeyPackage's list is restated");
        let mut after = leaves.clone();
        after[2] = record(2, "a1", "attacker", honest, true);
        assert!(!capped(&mls_tally::master_tally(&after, "victim", e + 1), e + 1));
    }

    /// Review H2: what a commit-written leaf carries for its own master, or out of
    /// order, is dropped by its next commit, never restated.
    #[test]
    fn a_carried_entry_for_the_committer_itself_or_out_of_order_is_dropped() {
        let e = 40u64;
        let carried = vec![("m".to_string(), vec![e - 1]), ("n".to_string(), vec![e - 2, e - 1]), ("x".to_string(), vec![e - 3])];
        let leaves = vec![
            record(0, "o1", "owner", Tally::default(), true),
            record(1, "m1", "m", Tally { refreshed_day: 1, epochs: vec![], carried }, true),
        ];
        let m = id("m1", "m");
        let input = RateInput { epoch: e, leaves: &leaves, committer: &m, adds: &[], removes: &[], no_proposals: true };
        let expected = expected_tally(&input, &charges(&input), 1).unwrap();
        assert_eq!(expected.carried, vec![("x".to_string(), vec![e - 3])]);
    }

    fn batch_repair(committer: (&str, &str), masters: usize) -> (Vec<LeafRecord>, Vec<LeafIdentity>, Vec<LeafView>) {
        let mut leaves = vec![record(0, "o1", "owner", Tally::default(), true)];
        if committer.1 != "owner" {
            leaves.push(record(1, committer.0, committer.1, Tally::default(), true));
        }
        let (mut adds, mut removes) = (Vec::new(), Vec::new());
        for i in 0..masters {
            let (d, m) = (format!("d{i:04}"), format!("12D3KooWmaster{i:04}"));
            leaves.push(record(leaves.len() as u32, &d, &m, Tally::default(), true));
            adds.push(id(&d, &m));
            removes.push(LeafView::Bound(id(&d, &m)));
        }
        (leaves, adds, removes)
    }

    /// Review H1: an honest committer repairing more masters than the old bound of
    /// 32 at once writes a tally every receiver reads and accepts.
    #[test]
    fn an_honest_batch_repair_of_many_masters_stays_parseable() {
        let (leaves, adds, removes) = batch_repair(("c1", "coord"), 33);
        let c = id("c1", "coord");
        let input = RateInput { epoch: 50, leaves: &leaves, committer: &c, adds: &adds, removes: &removes, no_proposals: false };
        let written = expected_tally(&input, &charges(&input), 1).expect("an expected tally");
        let read_back = Tally::decode(&written.encode());
        assert!(read_back.is_some());
        assert_eq!(rate_refusal(&input, Some(read_back.as_ref()), owner), None);
        assert!(carried_overflow(&input, &charges(&input)).is_empty());
    }

    /// Review H1 for the owner (exempt, so never refused): its leaf must still parse,
    /// or the rule turns off for every other master.
    #[test]
    fn the_owners_batch_repair_keeps_the_rule_on() {
        let (leaves, adds, removes) = batch_repair(("o1", "owner"), 33);
        let o = id("o1", "owner");
        let input = RateInput { epoch: 50, leaves: &leaves, committer: &o, adds: &adds, removes: &removes, no_proposals: false };
        let written = expected_tally(&input, &charges(&input), 1).unwrap();
        let mut after = leaves.clone();
        after[0].tally = Tally::decode(&written.encode());
        assert!(others_all_capable(&after, "12D3KooWmaster0000"), "the owner's leaf still carries a tally");
    }

    /// Review H1: past the carried bound the extra repairs wait; no committer ever
    /// derives a tally that does not decode.
    #[test]
    fn repairs_past_the_carried_bound_wait() {
        let (leaves, adds, removes) = batch_repair(("o1", "owner"), MAX_CARRIED + 1);
        let o = id("o1", "owner");
        let input = RateInput { epoch: 50, leaves: &leaves, committer: &o, adds: &adds, removes: &removes, no_proposals: false };
        let all = charges(&input);
        assert!(expected_tally(&input, &all, 1).is_err(), "a tally past the bound is never derived");
        let waiting = carried_overflow(&input, &all);
        assert_eq!(waiting, vec![format!("12D3KooWmaster{:04}", MAX_CARRIED)]);
        let fits = Charges { committer: all.committer, repaired: all.repaired.iter().filter(|m| !waiting.contains(m)).cloned().collect() };
        let written = expected_tally(&input, &fits, 1).unwrap();
        assert_eq!(Tally::decode(&written.encode()), Some(written));
    }

    /// Review 2, M2: a carried list written while not every member judged tallies may
    /// name epochs still ahead; it arms later at an epoch its writer chose. It may cap
    /// repairs then (residual, option B), but it never makes its victim unfit to answer
    /// or commit for the group.
    #[test]
    fn a_dormant_future_carried_list_never_makes_its_victim_unfit() {
        let w = 20u64;
        let leaves = vec![
            leaf(0, "o1", "owner", vec![], vec![]),
            leaf(1, "v1", "victim", vec![], vec![]),
            leaf(2, "a1", "attacker", vec![w], vec![("victim".into(), vec![w + 100, w + 99, w + 98])]),
        ];
        assert!(others_all_capable(&leaves, "victim"));
        for epoch in [w + 10, w + 101] {
            for as_committer in [false, true] {
                assert!(!unfit(&leaves, epoch, "victim", as_committer, owner), "unfit at {epoch} (committer {as_committer})");
            }
        }
    }

    /// The fitness rules, all masters in one pass (review 2, L2).
    #[test]
    fn unfit_masters_follow_each_masters_own_history() {
        let mut leaves = tree();
        leaves[1] = leaf(1, "m1", "m", vec![9, 8, 7], vec![]);
        leaves[0] = leaf(0, "o1", "owner", vec![9, 8, 7], vec![]);
        for as_committer in [false, true] {
            assert_eq!(unfit_masters(&leaves, 10, as_committer, owner), HashSet::from(["m".to_string()]), "committer {as_committer}");
        }
        assert!(unfit_masters(&leaves, 19, false, owner).is_empty(), "the window passed");
        let mut legacy = leaves.clone();
        legacy.push(LeafRecord { tally: None, declares: false, commit_written: false, ..leaf(3, "n2", "n", vec![], vec![]) });
        assert_eq!(unfit_masters(&legacy, 19, false, owner), HashSet::from(["n".to_string()]), "a pre-0.13 leaf, as responder");
        assert!(unfit_masters(&legacy, 19, true, owner).is_empty(), "never as committer");
        assert!(!unfit_masters(&legacy, 10, false, owner).contains("m"), "G(m) is false while another master keeps a pre-0.13 leaf");
        let mut unbound = leaves.clone();
        unbound.push(LeafRecord { identity: None, ..leaf(4, "x", "x", vec![], vec![]) });
        assert!(unfit_masters(&unbound, 10, false, owner).is_empty(), "nobody while an unbound leaf sits in the tree");
    }

    /// Review 2, L1: an exempt committer whose history no tally can restate still states
    /// one that decodes.
    #[test]
    fn an_exempt_committers_fresh_tally_always_decodes() {
        let mut leaves = tree();
        leaves[0].tally = None;
        leaves[0].declares = true;
        leaves[2] = leaf(2, "n1", "n", vec![4], vec![]);
        let o = id("o1", "owner");
        let adds = [id("n1", "n")];
        let removes = [LeafView::Bound(id("n1", "n"))];
        let input = RateInput { epoch: 10, leaves: &leaves, committer: &o, adds: &adds, removes: &removes, no_proposals: false };
        let c = charges(&input);
        assert!(expected_tally(&input, &c, 1).is_err());
        let fresh = fresh_tally(&input, &c, 1);
        assert_eq!(fresh.carried, vec![("n".to_string(), vec![10, 4])]);
        assert_eq!(Tally::decode(&fresh.encode()), Some(fresh));
    }
}
