//! The tally a 0.13 leaf carries in its own MLS leaf node: when its owner last
//! refreshed it, and the epochs of its master's last counted commits. It lives in the
//! tree so every member, a Welcome joiner included, reads the same history (design
//! `g13-s3`, AR-25/AR-27).

use openmls::prelude::*;
use openmls::treesync::LeafNodeSource;

/// Private-use leaf-node extension type of the tally.
pub(crate) const TALLY_EXTENSION: u16 = 0xF5A1;

/// How many counted-commit epochs a tally keeps.
pub(crate) const TALLY_DEPTH: usize = 3;

/// 2: carried masters counted in a u16.
const TALLY_VERSION: u8 = 2;

/// Most foreign masters' histories one leaf carries: room for a whole group's
/// repair at once (a fork the authority lost), still a bounded leaf (~80 KB).
pub(crate) const MAX_CARRIED: usize = 1024;

/// Longest master id a carried entry may name.
const MAX_MASTER_LEN: usize = 64;

/// A leaf's tally: the day (since the Unix epoch) its owner last refreshed it, its
/// master's last counted-commit epochs (newest first), and for each master whose
/// device this leaf's commits repaired, that master's history as charged then.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Tally {
    pub refreshed_day: u32,
    pub epochs: Vec<u64>,
    pub carried: Vec<(String, Vec<u64>)>,
}

fn put_epochs(out: &mut Vec<u8>, epochs: &[u64]) {
    out.push(epochs.len() as u8);
    for epoch in epochs {
        out.extend_from_slice(&epoch.to_be_bytes());
    }
}

/// Reads `n u8 | n x u64`, returning the epochs and the rest.
fn take_epochs(bytes: &[u8]) -> Option<(Vec<u64>, &[u8])> {
    let (&n, rest) = bytes.split_first()?;
    let n = n as usize;
    if n > TALLY_DEPTH {
        return None;
    }
    let body = rest.get(..n * 8)?;
    let epochs = body.as_chunks::<8>().0.iter().map(|c| u64::from_be_bytes(*c)).collect();
    Some((epochs, &rest[n * 8..]))
}

impl Tally {
    pub(crate) fn encode(&self) -> Vec<u8> {
        let mut out = vec![TALLY_VERSION];
        out.extend_from_slice(&self.refreshed_day.to_be_bytes());
        put_epochs(&mut out, &self.epochs);
        out.extend_from_slice(&(self.carried.len() as u16).to_be_bytes());
        for (master, epochs) in &self.carried {
            out.push(master.len() as u8);
            out.extend_from_slice(master.as_bytes());
            put_epochs(&mut out, epochs);
        }
        out
    }

    /// `None` for anything but the exact layout: a known version, at most
    /// [`TALLY_DEPTH`] entries per list, at most [`MAX_CARRIED`] carried masters,
    /// each named once, no trailing bytes.
    pub(crate) fn decode(bytes: &[u8]) -> Option<Tally> {
        let (&version, rest) = bytes.split_first()?;
        if version != TALLY_VERSION {
            return None;
        }
        let refreshed_day = u32::from_be_bytes(rest.get(..4)?.try_into().ok()?);
        let (epochs, rest) = take_epochs(rest.get(4..)?)?;
        let m = u16::from_be_bytes(rest.get(..2)?.try_into().ok()?) as usize;
        let mut rest = &rest[2..];
        if m > MAX_CARRIED {
            return None;
        }
        let mut carried: Vec<(String, Vec<u64>)> = Vec::with_capacity(m);
        let mut named = std::collections::HashSet::with_capacity(m);
        for _ in 0..m {
            let (&len, after) = rest.split_first()?;
            if len == 0 || len as usize > MAX_MASTER_LEN {
                return None;
            }
            let master = std::str::from_utf8(after.get(..len as usize)?).ok()?.to_string();
            if !named.insert(master.clone()) {
                return None;
            }
            let (list, after) = take_epochs(&after[len as usize..])?;
            carried.push((master, list));
            rest = after;
        }
        if !rest.is_empty() {
            return None;
        }
        Some(Tally { refreshed_day, epochs, carried })
    }

    /// `self` when its bytes decode back to it, else why not: no leaf may carry a
    /// tally the rules read as broken.
    pub(crate) fn checked(self) -> Result<Tally, String> {
        if Tally::decode(&self.encode()).as_ref() == Some(&self) {
            Ok(self)
        } else {
            Err(format!("a tally carrying {} masters does not encode", self.carried.len()))
        }
    }

    /// The list a counted commit at `epoch` must carry after `prior`.
    pub(crate) fn after_counted(prior: &[u64], epoch: u64) -> Vec<u64> {
        std::iter::once(epoch).chain(prior.iter().copied()).take(TALLY_DEPTH).collect()
    }
}

/// Strictly decreasing epochs, all before `epoch`.
pub(crate) fn well_ordered(epochs: &[u64], epoch: u64) -> bool {
    epochs.windows(2).all(|w| w[0] > w[1]) && epochs.first().is_none_or(|&e| e < epoch)
}

/// Days since the Unix epoch, the only time a tally states (a coarse refresh time
/// tells co-members no more than that the device was around that day).
pub(crate) fn today() -> u32 {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    (secs / 86_400) as u32
}

pub(crate) fn tally_extension_type() -> ExtensionType {
    ExtensionType::Unknown(TALLY_EXTENSION)
}

/// Capabilities every leaf this build mints declares: the defaults plus the tally.
pub(crate) fn tally_capabilities() -> Capabilities {
    Capabilities::builder().extensions(vec![tally_extension_type()]).build()
}

/// `extensions` with the tally set to `tally`, every other extension kept.
pub(crate) fn with_tally(extensions: &Extensions<LeafNode>, tally: &Tally) -> Extensions<LeafNode> {
    let mut out: Vec<Extension> = extensions
        .iter()
        .filter(|e| e.extension_type() != tally_extension_type())
        .cloned()
        .collect();
    out.push(Extension::Unknown(TALLY_EXTENSION, UnknownExtension(tally.encode())));
    Extensions::from_vec(out).unwrap_or_else(|_| extensions.clone())
}

/// Whether a leaf node lists the tally capability (what the standing gate and ratchet read).
pub(crate) fn declares(leaf: &LeafNode) -> bool {
    leaf.capabilities().extensions().contains(&tally_extension_type())
}

/// The tally a leaf node carries, if it declares the capability and the bytes parse.
pub(crate) fn leaf_tally(leaf: &LeafNode) -> Option<Tally> {
    if !leaf.capabilities().extensions().contains(&tally_extension_type()) {
        return None;
    }
    leaf.extensions().iter().find_map(|e| match e {
        Extension::Unknown(t, UnknownExtension(bytes)) if *t == TALLY_EXTENSION => Tally::decode(bytes),
        _ => None,
    })
}

/// Whether a leaf in the tree was last written by a commit's update path (the only
/// leaves whose tally counts; a KeyPackage's list is the minter's word alone).
pub(crate) fn written_by_commit(leaf: &LeafNode) -> bool {
    matches!(leaf.leaf_node_source(), LeafNodeSource::Commit(_))
}

/// What the tree holds for one leaf, read once so the rules over it stay pure.
#[derive(Clone, Debug)]
pub(crate) struct LeafRecord {
    pub index: u32,
    /// Certified `(device, master)`, `None` for an unbound leaf.
    pub identity: Option<super::LeafIdentity>,
    /// Declares the tally capability.
    pub declares: bool,
    /// The tally it carries, when it declares the capability and the bytes parse.
    pub tally: Option<Tally>,
    /// Last written by a commit's update path (not a KeyPackage).
    pub commit_written: bool,
    /// The day its owner last refreshed it: the tally's, else the KeyPackage mint day.
    pub fresh_day: u32,
}

impl LeafRecord {
    pub(crate) fn capable(&self) -> bool {
        self.tally.is_some()
    }

    pub(crate) fn master(&self) -> Option<&str> {
        self.identity.as_ref().map(|i| i.master.as_str())
    }
}

/// The receiver cap: at most this many counted commits per master ...
pub(crate) const CAP_COMMITS: usize = TALLY_DEPTH;
/// ... in any this many epochs.
pub(crate) const CAP_EPOCHS: u64 = 12;

/// Whether `tally` puts its master at the cap for a counted commit at `epoch`.
pub(crate) fn capped(tally: &MasterTally, epoch: u64) -> bool {
    match tally {
        MasterTally::Unreadable => true,
        MasterTally::List(list) => {
            list.len() >= CAP_COMMITS && list[CAP_COMMITS - 1].saturating_add(CAP_EPOCHS) > epoch
        }
    }
}

/// A master's counted-commit history as the tree states it at `epoch`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum MasterTally {
    List(Vec<u64>),
    /// Its history is unreadable or names an epoch not yet past: judged as at its cap.
    Unreadable,
}

/// T(M), from leaves written by a commit: M's own lists and what other leaves carry
/// for M; the list with the greatest head wins (ties: lowest leaf index, own before
/// carried). A tally of M's own that does not parse, or an own list chosen that is
/// not strictly decreasing before `epoch`, fails closed for M (only M writes those).
/// A carried list that is not well ordered is ignored: a commit judged before every
/// member ran these rules may have written it.
pub(crate) fn master_tally(leaves: &[LeafRecord], master: &str, epoch: u64) -> MasterTally {
    // (head, leaf index, carried, list)
    let mut candidates: Vec<(Option<u64>, u32, bool, &[u64])> = Vec::new();
    for leaf in leaves.iter().filter(|l| l.commit_written && l.declares) {
        let own = leaf.master() == Some(master);
        let Some(tally) = &leaf.tally else {
            if own {
                return MasterTally::Unreadable;
            }
            continue;
        };
        if own {
            candidates.push((tally.epochs.first().copied(), leaf.index, false, &tally.epochs));
        }
        for (_, list) in tally.carried.iter().filter(|(m, l)| m == master && well_ordered(l, epoch)) {
            candidates.push((list.first().copied(), leaf.index, true, list));
        }
    }
    let best = candidates.into_iter().max_by_key(|(head, index, carried, _)| (*head, std::cmp::Reverse(*index), !*carried));
    match best {
        None => MasterTally::List(Vec::new()),
        Some((_, _, false, list)) if !well_ordered(list, epoch) => MasterTally::Unreadable,
        Some((_, _, _, list)) => MasterTally::List(list.to_vec()),
    }
}

/// Each master's history as only its OWN commit-written leaves state it (what
/// [`master_tally`] reads, carried lists left out), for every master in one pass. A
/// carried list is another master's word about this one: it feeds the cap on repairs,
/// never who may answer or commit for the group, so one written while not every
/// member judged tallies (with epochs still ahead) cannot later mark a master unfit.
pub(crate) fn own_tallies(leaves: &[LeafRecord], epoch: u64) -> std::collections::HashMap<String, MasterTally> {
    // (head, leaf index, list), or None once a leaf of the master is unreadable
    type Best<'a> = Option<(Option<u64>, u32, &'a [u64])>;
    let mut best: std::collections::HashMap<&str, Best> = std::collections::HashMap::new();
    for leaf in leaves {
        let Some(master) = leaf.master() else { continue };
        let slot = best.entry(master).or_insert(Some((None, u32::MAX, &[])));
        if !(leaf.commit_written && leaf.declares) {
            continue;
        }
        let (Some(tally), Some(current)) = (&leaf.tally, slot.as_ref()) else {
            *slot = None;
            continue;
        };
        let candidate = (tally.epochs.first().copied(), leaf.index, tally.epochs.as_slice());
        if (candidate.0, std::cmp::Reverse(candidate.1)) > (current.0, std::cmp::Reverse(current.1)) {
            *slot = Some(candidate);
        }
    }
    best.into_iter()
        .map(|(master, slot)| {
            let tally = match slot {
                Some((_, _, list)) if well_ordered(list, epoch) => MasterTally::List(list.to_vec()),
                _ => MasterTally::Unreadable,
            };
            (master.to_string(), tally)
        })
        .collect()
}

/// TEST-ONLY: a KeyPackage of `device` (certified by `master`) for `group_key` that
/// no running node holds: what a modified client sends.
#[cfg(test)]
pub(crate) fn stray_key_package(device: &crate::identity::native_identity::NativeKeypair, master: &crate::identity::native_identity::NativeKeypair, group_key: &str) -> Vec<u8> {
    crate::crypto::MlsManager::new(device, master).unwrap().generate_key_package_for(group_key, false).unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tally_round_trips() {
        for t in [
            Tally::default(),
            Tally { refreshed_day: 20_383, epochs: vec![9], carried: vec![] },
            Tally { refreshed_day: u32::MAX, epochs: vec![u64::MAX, 7, 0], carried: vec![("12D3KooWa".into(), vec![4, 1])] },
        ] {
            assert_eq!(Tally::decode(&t.encode()), Some(t));
        }
    }

    #[test]
    fn every_malformed_tally_reads_as_none() {
        let good = Tally { refreshed_day: 1, epochs: vec![3, 2], carried: vec![] }.encode();
        assert!(Tally::decode(&[]).is_none());
        for version in [1u8, 3] {
            let mut other = good.clone();
            other[0] = version;
            assert!(Tally::decode(&other).is_none(), "version {version}");
        }
        assert!(Tally::decode(&good[..good.len() - 1]).is_none(), "truncated");
        let mut long = good.clone();
        long.push(0);
        assert!(Tally::decode(&long).is_none(), "trailing byte");
        let mut deep = vec![TALLY_VERSION, 0, 0, 0, 1, 4];
        deep.extend_from_slice(&[0u8; 32]);
        deep.extend_from_slice(&[0, 0]);
        assert!(Tally::decode(&deep).is_none(), "more entries than the depth");
        let twice = Tally { refreshed_day: 1, epochs: vec![], carried: vec![("a".into(), vec![1]), ("a".into(), vec![2])] };
        assert!(Tally::decode(&twice.encode()).is_none(), "a master carried twice");
        let empty_name = Tally { refreshed_day: 1, epochs: vec![], carried: vec![(String::new(), vec![])] };
        assert!(Tally::decode(&empty_name.encode()).is_none(), "an empty master id");
    }

    #[test]
    fn a_tally_up_to_the_carried_bound_encodes_and_one_past_it_does_not() {
        let carried = |n: usize| (0..n).map(|i| (format!("12D3KooWmaster{i:04}"), vec![9u64, 8, 7])).collect::<Vec<_>>();
        let full = Tally { refreshed_day: 1, epochs: vec![9], carried: carried(MAX_CARRIED) };
        assert_eq!(full.clone().checked(), Ok(full));
        assert!(Tally { refreshed_day: 1, epochs: vec![], carried: carried(MAX_CARRIED + 1) }.checked().is_err());
        assert!(Tally { refreshed_day: 1, epochs: vec![], carried: vec![("m".repeat(300), vec![])] }.checked().is_err(), "a name too long");
    }

    fn record(index: u32, master: &str, tally: Option<Tally>, commit_written: bool) -> LeafRecord {
        LeafRecord {
            index,
            identity: Some(crate::crypto::LeafIdentity { device: format!("d{index}"), master: master.into() }),
            declares: true,
            tally,
            commit_written,
            fresh_day: 0,
        }
    }

    fn list(epochs: Vec<u64>) -> Option<Tally> {
        Some(Tally { refreshed_day: 0, epochs, carried: vec![] })
    }

    #[test]
    fn a_masters_tally_is_the_freshest_list_written_by_a_commit() {
        let leaves = vec![
            record(0, "m", list(vec![4, 2]), true),
            record(1, "m", list(vec![7]), true),
            record(2, "m", list(vec![9, 8, 7]), false),
            record(3, "x", Some(Tally { refreshed_day: 0, epochs: vec![], carried: vec![("m".into(), vec![8, 4])] }), true),
        ];
        assert_eq!(master_tally(&leaves, "m", 10), MasterTally::List(vec![8, 4]), "a carried list can be the freshest");
        assert_eq!(master_tally(&leaves[..2], "m", 10), MasterTally::List(vec![7]));
        assert_eq!(master_tally(&leaves[2..3], "m", 10), MasterTally::List(vec![]), "a KeyPackage's list is ignored");
        assert_eq!(master_tally(&leaves, "nobody", 10), MasterTally::List(vec![]));
    }

    #[test]
    fn an_unreadable_own_tally_fails_closed_and_a_bad_carried_one_is_ignored() {
        let mut broken = record(0, "m", None, true);
        broken.declares = true;
        assert_eq!(master_tally(&[broken], "m", 10), MasterTally::Unreadable);
        assert_eq!(master_tally(&[record(0, "m", list(vec![10]), true)], "m", 10), MasterTally::Unreadable, "an entry at the judged epoch");
        let bad_carry = record(1, "x", Some(Tally { refreshed_day: 0, epochs: vec![], carried: vec![("m".into(), vec![12])] }), true);
        assert_eq!(master_tally(&[record(0, "m", list(vec![3]), true), bad_carry], "m", 10), MasterTally::List(vec![3]));
    }

    /// What `own_tallies` states for each master is `master_tally` with every carried
    /// list left out.
    #[test]
    fn own_tallies_read_only_each_masters_own_leaves() {
        let carrier = record(4, "x", Some(Tally { refreshed_day: 0, epochs: vec![2], carried: vec![("m".into(), vec![9, 8, 7])] }), true);
        let leaves = vec![
            record(5, "m", list(vec![6, 1]), true),
            record(2, "m", list(vec![6, 2]), true),
            record(3, "m", list(vec![8]), false),
            carrier,
            record(6, "k", list(vec![4, 4]), true),
            record(7, "u", None, false),
        ];
        let own = own_tallies(&leaves, 10);
        assert_eq!(own["m"], MasterTally::List(vec![6, 2]), "greatest head, lowest index, KeyPackage and carried lists left out");
        assert_eq!(master_tally(&leaves, "m", 10), MasterTally::List(vec![9, 8, 7]), "the cap still reads the carried list");
        assert_eq!(own["x"], MasterTally::List(vec![2]));
        assert_eq!(own["k"], MasterTally::Unreadable, "an own list that is not decreasing");
        assert_eq!(own["u"], MasterTally::List(vec![]), "no commit-written leaf yet");
        let mut broken = record(8, "x", None, true);
        broken.declares = true;
        let mut with_broken = leaves.clone();
        with_broken.push(broken);
        assert_eq!(own_tallies(&with_broken, 10)["x"], MasterTally::Unreadable);
    }

    #[test]
    fn equal_heads_break_by_lowest_leaf_index() {
        let leaves = vec![record(5, "m", list(vec![6, 1]), true), record(2, "m", list(vec![6, 2]), true)];
        assert_eq!(master_tally(&leaves, "m", 10), MasterTally::List(vec![6, 2]));
    }

    #[test]
    fn a_counted_commit_pushes_its_epoch_and_keeps_the_depth() {
        assert_eq!(Tally::after_counted(&[], 5), vec![5]);
        assert_eq!(Tally::after_counted(&[4, 2, 1], 5), vec![5, 4, 2]);
    }

    #[test]
    fn only_a_decreasing_list_of_past_epochs_is_well_ordered() {
        assert!(well_ordered(&[], 0));
        assert!(well_ordered(&[4, 2], 5));
        assert!(!well_ordered(&[5], 5), "an entry at the judged epoch");
        assert!(!well_ordered(&[2, 4], 5), "increasing");
        assert!(!well_ordered(&[3, 3], 5), "repeated");
    }
}

#[cfg(test)]
mod openmls_tests {
    use super::*;
    use crate::crypto::mls_manager::test_keys::bound;
    use crate::crypto::{LeafView, MlsManager, Verdict};

    /// Owner, then two members joined from KeyPackages this build mints.
    fn group_of_three() -> (MlsManager, MlsManager, MlsManager) {
        let (mut owner, _) = bound(1, 2);
        owner.create_group("s").unwrap();
        let (mut a, a_id) = bound(3, 4);
        let (mut b, b_id) = bound(5, 6);
        let kps = vec![
            (a_id, a.generate_key_package_for("s", false).unwrap()),
            (b_id, b.generate_key_package_for("s", false).unwrap()),
        ];
        let (_, welcome, _) = owner.add_members_batch("s", &kps).unwrap();
        owner.merge_pending_commit("s").unwrap();
        a.join_from_welcome("s", &welcome).unwrap();
        b.join_from_welcome("s", &welcome).unwrap();
        (owner, a, b)
    }

    #[test]
    fn new_leaves_declare_the_tally_and_carry_an_empty_one() {
        let (owner, _, _) = group_of_three();
        let records = owner.leaf_records("s");
        assert_eq!(records.len(), 3);
        assert!(records.iter().all(|r| r.capable() && r.tally.as_ref().is_some_and(|t| t.epochs.is_empty())));
        assert!(records.iter().all(|r| !r.commit_written), "no leaf has been through a commit yet");
    }

    #[test]
    fn a_self_update_is_what_a_0_12_2_judge_accepts_and_merges_on_its_echo() {
        let (mut owner, mut a, mut b) = group_of_three();
        let epoch = a.epoch("s").unwrap();
        let tally = Tally { refreshed_day: today(), epochs: vec![epoch], carried: vec![] };
        let commit = a.stage_self_update("s", &tally).unwrap();
        assert_eq!(a.epoch("s").unwrap(), epoch, "staged, not merged");

        // Everything 0.12.2's `commit_verdict` reads: a bound committer keeping its
        // identity, no membership change, no other proposal.
        let mut seen = None;
        let verdict = owner
            .process_commit_judged("s", &commit, |facts| {
                seen = Some(facts.clone());
                Verdict::Accept
            })
            .unwrap();
        assert_eq!(verdict, Verdict::Accept);
        let facts = seen.unwrap();
        let committer = facts.committer.as_ref().and_then(LeafView::bound).cloned().unwrap();
        assert_eq!(facts.path_leaf.as_ref().and_then(LeafView::bound), Some(&committer));
        assert!(facts.adds.is_empty() && facts.removes.is_empty() && !facts.other_proposals);

        b.process_commit_judged("s", &commit, |_| Verdict::Accept).unwrap();
        // The committer broadcasts it; the echo merges our pending commit.
        assert_eq!(a.process_commit_judged("s", &commit, |_| Verdict::Refuse("the judge is not asked".into())).unwrap(), Verdict::Accept);
        for m in [&owner, &a, &b] {
            assert_eq!(m.epoch("s").unwrap(), epoch + 1);
            assert_eq!(m.epoch_auth_digest("s"), owner.epoch_auth_digest("s"));
        }
        let leaf = b.leaf_records("s").into_iter().find(|r| r.identity.as_ref() == Some(&committer)).unwrap();
        assert!(leaf.commit_written);
        assert_eq!(leaf.tally.map(|t| t.epochs), Some(vec![epoch]));
        assert!(a.groups_with_pending_commit().is_empty());
    }

    #[test]
    fn another_commit_at_the_epoch_clears_our_pending_self_update() {
        let (mut owner, mut a, _) = group_of_three();
        let epoch = a.epoch("s").unwrap();
        let ours = a.stage_self_update("s", &Tally { refreshed_day: today(), epochs: vec![epoch], carried: vec![] }).unwrap();
        let theirs = owner.self_update_commit("s");
        assert_eq!(a.process_commit_judged("s", &theirs, |_| Verdict::Accept).unwrap(), Verdict::Accept);
        assert!(a.groups_with_pending_commit().is_empty());
        assert_eq!(a.epoch("s").unwrap(), epoch + 1);
        assert!(a.process_commit_judged("s", &ours, |_| Verdict::Accept).is_err(), "our stale commit never takes an epoch");
        assert_eq!(a.epoch_auth_digest("s"), owner.epoch_auth_digest("s"));
    }

    #[test]
    fn a_member_with_a_pending_self_update_still_reads_and_sends_at_its_epoch() {
        let (mut owner, mut a, _) = group_of_three();
        let epoch = a.epoch("s").unwrap();
        a.stage_self_update("s", &Tally { refreshed_day: today(), epochs: vec![epoch], carried: vec![] }).unwrap();
        let from_a = a.encrypt("s", b"still here").unwrap();
        assert!(owner.decrypt("s", &from_a).is_ok());
        let from_owner = owner.encrypt("s", b"hello").unwrap();
        assert!(a.decrypt("s", &from_owner).is_ok());
    }

    /// AR-25: a one-time copy of a member's MLS state keeps reading through commits
    /// that carry no path, and reads nothing once that member refreshed its leaf.
    #[test]
    fn a_leaf_copy_stops_reading_after_its_owners_self_update() {
        let (mut owner, mut a, _) = group_of_three();
        let mut copy = MlsManager::from_persisted(
            &a.signer_bytes().unwrap(),
            &a.credential_bytes().unwrap(),
            Some(&a.serialize_storage().unwrap()),
            &["s".to_string()],
        )
        .unwrap();

        // Today's hole: an add carries no path, so the copy follows it and reads on.
        let (mut c, c_id) = bound(7, 8);
        let (add, welcome) = owner.add_member("s", &c.generate_key_package_for("s", false).unwrap()).unwrap();
        owner.merge_pending_commit("s").unwrap();
        c.join_from_welcome("s", &welcome).unwrap();
        a.process_commit_judged("s", &add, |_| Verdict::Accept).unwrap();
        copy.process_commit_judged("s", &add, |_| Verdict::Accept).unwrap();
        let before = owner.encrypt("s", b"read by the copy").unwrap();
        assert_eq!(copy.decrypt("s", &before).map(|(p, _)| p).ok(), Some(b"read by the copy".to_vec()));
        let _ = c_id;

        // The owner of the leaf refreshes it; the committer relays it.
        let epoch = a.epoch("s").unwrap();
        let refresh = a.stage_self_update("s", &Tally { refreshed_day: today(), epochs: vec![epoch], carried: vec![] }).unwrap();
        owner.process_commit_judged("s", &refresh, |_| Verdict::Accept).unwrap();
        a.process_commit_judged("s", &refresh, |_| Verdict::Accept).unwrap();
        c.process_commit_judged("s", &refresh, |_| Verdict::Accept).unwrap();
        assert!(copy.process_commit_judged("s", &refresh, |_| Verdict::Accept).is_err(), "the copy cannot follow its own leaf's refresh");

        let after = owner.encrypt("s", b"not for the copy").unwrap();
        assert!(copy.decrypt("s", &after).is_err());
        assert_eq!(a.decrypt("s", &after).map(|(p, _)| p).ok(), Some(b"not for the copy".to_vec()));
        let (add2, _) = owner.add_member("s", &bound(9, 10).0.generate_key_package_for("s", false).unwrap()).unwrap();
        owner.merge_pending_commit("s").unwrap();
        assert!(copy.process_commit_judged("s", &add2, |_| Verdict::Accept).is_err(), "and nothing after it");
    }

    /// `committer` states `tally` in a self-update every other manager merges unjudged:
    /// what a modified client, or a commit judged before G held, leaves in the tree.
    fn plant(committer: &mut MlsManager, others: &mut [&mut MlsManager], tally: &Tally) {
        let commit = committer.stage_self_update("s", tally).unwrap();
        committer.merge_own_self_update("s").unwrap();
        for m in others.iter_mut() {
            m.process_commit_judged("s", &commit, |_| Verdict::Accept).unwrap();
        }
    }

    /// Review H1: a committer whose leaf already carries the bound leaves a further
    /// repair waiting, and never writes a tally receivers cannot read.
    #[test]
    fn a_committer_at_the_carried_bound_leaves_further_repairs_waiting() {
        let (mut owner, mut a, mut b) = group_of_three();
        let owner_master = crate::crypto::mls_manager::test_keys::keypair(1).peer_id();
        let epoch = b.epoch("s").unwrap();
        let carried = (0..MAX_CARRIED).map(|i| (format!("12D3KooWfar{i:04}"), vec![epoch - 1])).collect();
        plant(&mut b, &mut [&mut owner, &mut a], &Tally { refreshed_day: today(), epochs: vec![epoch], carried });
        let a_device = crate::crypto::mls_manager::test_keys::keypair(4).peer_id();
        let kp = a.generate_key_package_for("s", false).unwrap();
        let (removals, adds) = (vec![a_device.clone()], vec![(a_device.clone(), kp)]);
        let is_owner = |m: &str| m == owner_master;
        assert_eq!(b.over_cap_devices("s", &removals, &adds, is_owner), vec![a_device.clone(), a_device.clone()]);
        assert!(b.commit_membership("s", &removals, &adds).is_err(), "no commit with a tally past the bound");
        assert!(b.groups_with_pending_commit().is_empty());
    }

    /// Review L5: a repair whose history no tally can restate waits, the owner's too,
    /// and a committer never sends such a commit with its old tally.
    #[test]
    fn a_repair_no_tally_can_state_waits_even_for_the_owner() {
        let (mut owner, mut a, mut b) = group_of_three();
        let owner_master = crate::crypto::mls_manager::test_keys::keypair(1).peer_id();
        let epoch = a.epoch("s").unwrap();
        plant(&mut a, &mut [&mut owner, &mut b], &Tally { refreshed_day: today(), epochs: vec![epoch + 5], carried: vec![] });
        let a_device = crate::crypto::mls_manager::test_keys::keypair(4).peer_id();
        let kp = a.generate_key_package_for("s", false).unwrap();
        let (removals, adds) = (vec![a_device.clone()], vec![(a_device.clone(), kp)]);
        let is_owner = |m: &str| m == owner_master;
        assert!(!owner.over_cap_devices("s", &removals, &adds, is_owner).is_empty(), "the owner's repair waits");
        assert!(!b.over_cap_devices("s", &removals, &adds, is_owner).is_empty());
        assert!(b.commit_membership("s", &removals, &adds).is_err(), "no commit restating an old tally");
    }

    /// Review 2, L1: no receiver reads the owner's tally, so an owner whose own leaf
    /// states a history no tally can restate (here more entries than the depth) still
    /// removes a member; a non-exempt committer in its place commits nothing.
    #[test]
    fn an_owner_with_an_unreadable_tally_can_still_remove_a_member() {
        let (mut owner, _a, _b) = group_of_three();
        let epoch = owner.epoch("s").unwrap();
        owner.stage_self_update("s", &Tally { refreshed_day: today(), epochs: vec![epoch, 3, 2, 1], carried: vec![] }).unwrap();
        owner.merge_own_self_update("s").unwrap();
        let records = owner.leaf_records("s");
        assert!(records.iter().any(|r| r.index == 0 && r.commit_written && r.tally.is_none()), "the owner's leaf reads as unreadable");
        let b_dev = records.iter().find(|r| r.index == 2).and_then(|r| r.identity.clone()).unwrap().device;
        assert!(owner.remove_identity_leaves("s", &[&b_dev]).is_err(), "a committer receivers judge commits nothing");
        let commit = owner.remove_identity_leaves_as("s", &[&b_dev], true).expect("the exempt owner removes the member");
        assert!(!commit.is_empty());
        owner.merge_pending_commit("s").unwrap();
        assert!(!owner.group_members("s").contains(&b_dev));
        let after = owner.leaf_records("s");
        assert!(after.iter().any(|r| r.index == 0 && r.tally.is_some()), "the owner's next leaf states a tally that decodes");
    }
}
