//! HOL-SEC-230 part B (PHRASE_RESTORE_F5_OWNER_REENTRY 2.4): a witness that names no
//! checkpoint before T names a RECORD instead, the owner ops a recovery dropped that it
//! first stored before T; a fresh install judges records as restore points and settles
//! on the chosen one. One scope rule decides which ops a record may hold, on both sides.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use super::operations::{CrdtOp, CrdtPayload};
use super::server_state::ServerState;
use super::settle::SeenAt;

/// A record holds at most this many ops and JSON bytes; a larger one is not sent.
pub(crate) const RECORD_OPS_MAX: usize = 4096;
pub(crate) const RECORD_BYTES_MAX: usize = 8 << 20;
const RECORD_TAG: &str = "hollow-witness-rec1\n";

/// Payloads no record carries: the founding op (the id proves it), checkpoints and their
/// marks, pins, and the join lock and key, so a restore revives no join secret or door
/// from before the recovery.
fn out_of_record(p: &CrdtPayload) -> bool {
    matches!(
        p,
        CrdtPayload::ServerCreated { .. }
            | CrdtPayload::ServerCheckpoint { .. }
            | CrdtPayload::SettleSign { .. }
            | CrdtPayload::FloorMark { .. }
            | CrdtPayload::MessagePinned { .. }
            | CrdtPayload::MessageUnpinned { .. }
            | CrdtPayload::JoinLock { .. }
            | CrdtPayload::JoinKeySet { .. }
    )
}

/// A record's id: SHA-256 over the server and its ops' content ids, which must be sorted
/// and distinct (`ids_shape`).
pub(crate) fn record_id(server: &str, ids: &[String]) -> String {
    use sha2::Digest as _;
    let mut h = sha2::Sha256::new();
    h.update(RECORD_TAG.as_bytes());
    h.update(server.as_bytes());
    for id in ids {
        h.update(b"\n");
        h.update(id.as_bytes());
    }
    hex::encode(h.finalize())
}

pub(crate) fn hex64(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

/// Content ids as a record lists them: 1 to [`RECORD_OPS_MAX`] lowercase hex ids, strictly
/// ascending.
pub(crate) fn ids_shape(ids: &[String]) -> bool {
    !ids.is_empty() && ids.len() <= RECORD_OPS_MAX && ids.iter().all(|i| hex64(i)) && ids.windows(2).all(|w| w[0] < w[1])
}

/// Each record's line (`CpFacts::lineage`): the other records whose every op it holds,
/// largest first. Equal sets are one record (one id), so only proper subsets count.
pub(crate) fn record_lineage(sets: &[(String, BTreeSet<[u8; 32]>)]) -> BTreeMap<String, Vec<String>> {
    sets.iter()
        .map(|(x, ids)| {
            let mut below: Vec<&(String, BTreeSet<[u8; 32]>)> = sets.iter().filter(|(y, sub)| y != x && sub.len() < ids.len() && sub.is_subset(ids)).collect();
            below.sort_by(|a, b| b.1.len().cmp(&a.1.len()).then_with(|| a.0.cmp(&b.0)));
            (x.clone(), below.into_iter().map(|(y, _)| y.clone()).collect())
        })
        .collect()
}

/// Why a record's ops do not check here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RecordCheck {
    /// An op it lists is not held here yet: the record waits for the sync.
    NotHeld,
    /// An op is out of scope, fails its signature or the bounds: the witness names none.
    Void,
}

impl ServerState {
    /// The devices a held settle stamp of `owner` names: a settling decided their ops.
    fn settled_devices(&self, owner: &str) -> HashSet<String> {
        let marks = self.stored.iter().filter(|(o, k)| *k == super::fold::RowKind::SettleSign && o.author == owner).map(|(o, _)| o);
        let stamps = marks.filter_map(|o| match &o.payload {
            CrdtPayload::SettleSign { stamp } => Some(stamp.devices.clone()),
            _ => None,
        });
        let base = self.base.as_ref().and_then(|b| b.state.cp_settles.as_ref()).map(|s| s.devices.clone());
        stamps.chain(base).flatten().collect()
    }

    /// THE record scope (review item 7), read by the witness's build, the asker's receipt
    /// check, its trial fold and the settling alike: an op of the server's owner, of a kind
    /// a record carries, proven by a device the view does not count now, that `was_counted`
    /// (the witness: a device its part A hold recorded as counted before the recovery;
    /// a fresh install cannot know the base before its own and passes every device), and
    /// that no held settle stamp names.
    pub(crate) fn record_scope<'a>(&'a self, was_counted: &'a dyn Fn(&str) -> bool) -> Option<impl Fn(&CrdtOp) -> bool + 'a> {
        let owner = self.anchor_owner()?;
        let settled = self.settled_devices(&owner);
        Some(move |op: &CrdtOp| {
            op.author == owner
                && op.server_id == self.server_id
                && !out_of_record(&op.payload)
                && op.proven_device().is_some_and(|d| !self.authority.counts(&owner, d) && was_counted(d) && !settled.contains(d))
        })
    }

    pub(super) fn held_ops(&self) -> impl Iterator<Item = &CrdtOp> {
        self.op_log.iter().chain(self.stored.iter().map(|(o, _)| o)).chain(self.held.iter().map(|(o, _)| o))
    }

    /// A witness's record for an ask whose T is `t_w` on our clock: the content ids of the
    /// ops in scope we first stored before it (`seen`), sorted, and the newest such store
    /// time. Only on a genesis server under part A's hold (no base held to name); `None`
    /// when nothing is in scope or the record would pass its bounds (fail closed to an
    /// answer naming none).
    pub(crate) fn witness_record(&self, t_w: u64, seen: &SeenAt) -> Option<(Vec<String>, u64)> {
        if !super::anchor::is_genesis_id(&self.server_id) {
            return None;
        }
        let r = self.recovery.as_ref().filter(|r| r.keeps_fold())?;
        let owner = self.anchor_owner()?;
        let was = |d: &str| r.dropped.iter().any(|(m, x)| *m == owner && x == d);
        let scope = self.record_scope(&was)?;
        let mut ids: BTreeMap<String, u64> = BTreeMap::new();
        let mut bytes = 0usize;
        for o in self.held_ops() {
            let Some(at) = seen.get(&(o.author.clone(), o.hlc.physical_ms, o.hlc.counter)).copied().filter(|at| *at < t_w) else { continue };
            if !scope(o) {
                continue;
            }
            let id = hex::encode(o.content_hash());
            if ids.contains_key(&id) {
                continue;
            }
            bytes = bytes.saturating_add(serde_json::to_string(o).map_or(usize::MAX, |j| j.len()));
            ids.insert(id, at);
            if ids.len() > RECORD_OPS_MAX || bytes > RECORD_BYTES_MAX {
                return None;
            }
        }
        let newest = ids.values().copied().max()?;
        Some((ids.into_keys().collect(), newest))
    }

    /// The asker's receipt check of a record (section 2.4): every op it lists is held here,
    /// verifies as this server's, and is in scope, within the bounds.
    pub(crate) fn record_ops(&self, ids: &[String]) -> Result<Vec<CrdtOp>, RecordCheck> {
        if !ids_shape(ids) || !super::anchor::is_genesis_id(&self.server_id) {
            return Err(RecordCheck::Void);
        }
        let any = |_: &str| true;
        let scope = self.record_scope(&any).ok_or(RecordCheck::Void)?;
        let want: HashSet<&str> = ids.iter().map(String::as_str).collect();
        let mut found: BTreeMap<String, CrdtOp> = BTreeMap::new();
        for o in self.held_ops() {
            let id = hex::encode(o.content_hash());
            if want.contains(id.as_str()) && !found.contains_key(&id) {
                found.insert(id, o.clone());
            }
        }
        if found.len() != ids.len() {
            return Err(RecordCheck::NotHeld);
        }
        let mut bytes = 0usize;
        for o in found.values() {
            bytes = bytes.saturating_add(serde_json::to_string(o).map_or(usize::MAX, |j| j.len()));
            if o.verify_author().is_err() || !scope(o) || bytes > RECORD_BYTES_MAX {
                return Err(RecordCheck::Void);
            }
        }
        Ok(found.into_values().collect())
    }

    /// The members a settling on record `ids` would list: the trial fold the chooser
    /// judges a record's witnesses by (`CpFacts::members`).
    pub(crate) fn record_members(&mut self, ids: &BTreeSet<[u8; 32]>) -> BTreeSet<String> {
        let mut scratch = ServerState::skeleton(self.server_id.clone());
        scratch.owner_pin = self.owner_pin.clone();
        let input = self.record_input(ids);
        scratch.ingest_remote(&input);
        scratch.members.keys().cloned().collect()
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::crdt::hold::tests::{baseless_replica, baseless_world, view_after, LAPTOP, LATE, MEMBER, MEMBER_PHONE, MOD, OWNER, PHONE};
    use crate::crdt::operations::{CrdtPayload as P, JoinSecret};
    use crate::crdt::testkeys::keys;

    /// T on every replica's clock; the world's ops were first stored at `BEFORE`.
    pub(crate) const T: u64 = 1_000;
    const BEFORE: u64 = 100;

    /// The baseless world (no checkpoint, the phone wrote every admission) plus, by the
    /// phone, a rename and a join key before T and a rename stored only after it.
    pub(crate) struct Recorded {
        pub(crate) owner: ServerState,
        pub(crate) log: Vec<CrdtOp>,
        pub(crate) rename: CrdtOp,
        pub(crate) key: CrdtOp,
        pub(crate) late: CrdtOp,
    }

    pub(crate) fn recorded_world() -> Recorded {
        let (mut owner, mut log) = baseless_world();
        let rename = owner.author_checked(P::ServerRenamed { new_name: "before T".into() }).unwrap();
        let key = owner.author_checked(P::JoinKeySet { secret: JoinSecret(hex::encode([5u8; 32])) }).unwrap();
        let late = owner.author_checked(P::ServerRenamed { new_name: "after T".into() }).unwrap();
        log.extend([rename.clone(), key.clone(), late.clone()]);
        Recorded { owner, log, rename, key, late }
    }

    pub(crate) fn seen_of(s: &ServerState, late: &CrdtOp) -> SeenAt {
        s.held_ops().map(|o| ((o.author.clone(), o.hlc.physical_ms, o.hlc.counter), if o.hlc == late.hlc { T + 1 } else { BEFORE })).collect()
    }

    fn ids_of<'a>(ops: impl Iterator<Item = &'a CrdtOp>) -> Vec<String> {
        let mut v: Vec<String> = ops.map(|o| hex::encode(o.content_hash())).collect();
        v.sort();
        v.dedup();
        v
    }

    /// Part B: a member holding no checkpoint from before T records exactly the owner ops
    /// of the dropped device it first stored before T: no founding op, no join key, no
    /// other identity's op, nothing stored at or after T.
    #[test]
    fn a_witness_with_no_checkpoint_before_t_records_the_dropped_devices_ops_it_stored_before_t() {
        let w = recorded_world();
        let mut m = baseless_replica(&w.log, MEMBER, MEMBER_PHONE, true);
        let seen = seen_of(&m, &w.late);
        assert!(m.witness_record(T, &seen).is_none(), "no record while the view still counts the phone");
        m.authority = view_after(false);
        let _ = m.rebuild_now();
        assert!(m.recovery.as_ref().is_some_and(|r| r.keeps_fold()), "precondition: part A holds");
        let (ids, newest) = m.witness_record(T, &seen).expect("the record");
        let owner = keys(OWNER).1;
        let want = ids_of(w.log.iter().filter(|o| {
            o.author == owner && !matches!(o.payload, P::ServerCreated { .. } | P::JoinKeySet { .. }) && o.hlc != w.late.hlc
        }));
        assert_eq!(ids, want, "the record holds the phone's admissions, role and early rename only");
        assert!(ids.contains(&hex::encode(w.rename.content_hash())) && !ids.contains(&hex::encode(w.key.content_hash())));
        assert_eq!(newest, BEFORE);
        assert!(m.witness_record(BEFORE, &seen).is_none(), "nothing stored before an earlier T: no record");
        let mut all_late = seen.clone();
        all_late.values_mut().for_each(|v| *v = T);
        assert!(m.witness_record(T, &all_late).is_none(), "an op first stored at T is not before it");
    }

    /// Item 7: the one scope refuses every kind a record never carries, another
    /// identity's op, a counted device's op, and a device the witness never counted.
    #[test]
    fn the_record_scope_takes_only_the_owners_dropped_device_ops_of_the_kinds_a_record_carries() {
        let w = recorded_world();
        let mut m = baseless_replica(&w.log, MEMBER, MEMBER_PHONE, true);
        m.authority = view_after(false);
        let _ = m.rebuild_now();
        let phone = keys(PHONE).1;
        let was = |d: &str| d == phone;
        let scope = m.record_scope(&was).expect("an anchored server");
        assert!(scope(&w.rename), "the dropped phone's rename");
        let mut by_phone = w.owner.clone();
        for p in [
            P::JoinKeySet { secret: JoinSecret(hex::encode([6u8; 32])) },
            P::MessagePinned { channel_id: "c".into(), message_id: "m".into() },
            P::MessageUnpinned { channel_id: "c".into(), message_id: "m".into() },
            P::ServerCreated { name: "x".into(), owner_peer_id: keys(OWNER).1, nonce: "00".into() },
            P::JoinLock {
                link: crate::node::join_lock::LockLink { n: 2, door: "d".repeat(43), change: "c".into(), sig: "s".into(), owner: None, nonce: None, dev: None },
                door: None,
                grants: Default::default(),
            },
        ] {
            let op = by_phone.create_op(p.clone());
            assert!(!scope(&op), "out of every record: {p:?}");
        }
        let checkpoint = w.log.iter().find(|o| matches!(o.payload, P::ServerCreated { .. })).unwrap();
        assert!(!scope(checkpoint), "the founding op");
        let ban = w.log.iter().find(|o| matches!(o.payload, P::MemberBanned { .. })).unwrap();
        assert!(!scope(ban), "another identity's op");
        let mut laptop = baseless_replica(&w.log, OWNER, LAPTOP, true);
        let counted = laptop.author_checked(P::ServerRenamed { new_name: "laptop".into() }).expect("the laptop writes");
        let all = |_: &str| true;
        assert!(!m.record_scope(&all).unwrap()(&counted), "a counted device's op");
        let never = |_: &str| false;
        let narrow = m.record_scope(&never).unwrap();
        assert!(!narrow(&w.rename), "a device the witness never counted");
        by_phone.server_id = "another".into();
        assert!(!scope(&by_phone.create_op(P::ServerRenamed { new_name: "y".into() })), "another server's op");
    }

    /// The receipt check at the fresh install: every listed op held, verified and in
    /// scope; one not yet held waits; anything else voids the witness.
    #[test]
    fn a_record_with_a_counted_devices_op_or_a_wrong_id_voids_the_witness() {
        let w = recorded_world();
        let mut m = baseless_replica(&w.log, MEMBER, MEMBER_PHONE, true);
        m.authority = view_after(false);
        let _ = m.rebuild_now();
        let (ids, _) = m.witness_record(T, &seen_of(&m, &w.late)).unwrap();
        let mut f = baseless_replica(&w.log, OWNER, LAPTOP, true);
        f.authority = view_after(false);
        let _ = f.rebuild_now();
        let ops = f.record_ops(&ids).expect("the owner's replica holds and checks every op");
        assert_eq!(ids_of(ops.iter()), ids);
        let mut unknown = ids.clone();
        unknown.push("f".repeat(64));
        assert_eq!(f.record_ops(&unknown).err(), Some(RecordCheck::NotHeld), "an op still syncing");
        let mut with_key = ids.clone();
        with_key.push(hex::encode(w.key.content_hash()));
        with_key.sort();
        assert_eq!(f.record_ops(&with_key).err(), Some(RecordCheck::Void), "a join key in a record");
        let ban = w.log.iter().find(|o| matches!(o.payload, P::MemberBanned { .. })).unwrap();
        let mut with_ban = ids.clone();
        with_ban.push(hex::encode(ban.content_hash()));
        with_ban.sort();
        assert_eq!(f.record_ops(&with_ban).err(), Some(RecordCheck::Void), "another identity's op");
        let mut unsorted = ids.clone();
        unsorted.reverse();
        assert_eq!(f.record_ops(&unsorted).err(), Some(RecordCheck::Void), "ids out of order");
        let held = baseless_replica(&w.log, OWNER, LAPTOP, true);
        assert_eq!(held.record_ops(&ids).err(), Some(RecordCheck::Void), "the phone still counted: nothing to restore");
    }

    /// Lineage: a record's line is the records it strictly contains, never itself, an
    /// equal set or a superset.
    #[test]
    fn a_records_line_is_the_records_it_strictly_contains() {
        let set = |v: &[u8]| v.iter().map(|b| [*b; 32]).collect::<BTreeSet<[u8; 32]>>();
        let sets = vec![("s".to_string(), set(&[1])), ("h".to_string(), set(&[1, 2])), ("p".to_string(), set(&[1, 2, 3])), ("o".to_string(), set(&[1, 4]))];
        let l = record_lineage(&sets);
        assert_eq!(l["p"], vec!["h".to_string(), "s".to_string()]);
        assert_eq!(l["h"], vec!["s".to_string()]);
        assert!(l["s"].is_empty());
        assert_eq!(l["o"], vec!["s".to_string()]);
    }

    /// The settling on a record keeps the dropped device's ops the record lists and
    /// no other: here MEMBER and MOD's admissions, never LATE's or the rename.
    #[test]
    fn a_record_settling_keeps_only_the_records_ops_of_the_dropped_device() {
        let w = recorded_world();
        let mut f = baseless_replica(&w.log, OWNER, LAPTOP, true);
        f.authority = view_after(false);
        let _ = f.rebuild_now();
        let admits_of = |tag: u8| w.log.iter().find(|o| matches!(&o.payload, P::MemberAdded { peer_id, .. } if *peer_id == keys(tag).1)).unwrap().content_hash();
        let role = w.log.iter().find(|o| matches!(o.payload, P::RoleChanged { .. })).unwrap().content_hash();
        let ids: BTreeSet<[u8; 32]> = [admits_of(MEMBER), admits_of(MOD), role].into_iter().collect();
        let trial = f.record_members(&ids);
        let (_, after) = crate::crdt::hold::tests::owner_rosters();
        let seen = SeenAt::new();
        let dropped = [keys(PHONE).1];
        let s = super::super::settle::Settling { before: f.authority.clone(), dropped: &dropped, t_ms: T, seen: &seen, roster: after, home: None, keys_after_ms: None };
        let (ops, _) = f.author_settling_on(&keys(OWNER).1, &s, &keys(LAPTOP).0, &super::super::settle::SettleOn::Record(ids.clone())).expect("the settling is written");
        let P::ServerCheckpoint { state, .. } = &ops.last().unwrap().payload else { panic!("a checkpoint") };
        let st = crate::crdt::server_state::parse_state(state).expect("a state");
        for (tag, want) in [(MEMBER, true), (MOD, true), (LATE, false)] {
            assert_eq!(st.members.contains_key(&keys(tag).1), want, "member {tag}");
        }
        assert_eq!(st.get_role(&keys(MOD).1), crate::crdt::operations::MemberRole::Moderator, "the record's role grant");
        assert!(!["before T", "after T"].contains(&st.name.read().as_str()), "a rename the record does not list");
        assert_eq!(trial, st.members.keys().cloned().collect::<BTreeSet<String>>(), "the trial fold lists what the settling does");
    }

    /// A master-key holder that founds a genesis server with a device it minted gets a
    /// junk server of its own: its id hashes that founding, and none of its ops (founding
    /// op included) enters a record of the real server.
    #[test]
    fn a_master_key_holders_genesis_server_is_a_junk_server_only() {
        let w = recorded_world();
        let (master, m_id, pk) = keys(OWNER);
        let (junk, junk_id, _) = keys(200);
        let (mut theirs, founding) = ServerState::found_on("junk".into(), m_id, crate::crdt::server_state::Founder { device_peer_id: &junk_id, device: Some(&junk), r_pub: None }, master, pk);
        assert_ne!(theirs.server_id, w.owner.server_id, "a founding hashes to its own id");
        let rename = theirs.create_op(P::ServerRenamed { new_name: "junk".into() });
        let mut f = baseless_replica(&w.log, OWNER, LAPTOP, true);
        f.authority = view_after(false);
        let _ = f.rebuild_now();
        let all = |_: &str| true;
        let scope = f.record_scope(&all).unwrap();
        assert!(!scope(&founding) && !scope(&rename), "the junk server's ops never enter the real server's record");
        let mut forged = rename.clone();
        forged.server_id = f.server_id.clone();
        assert!(forged.verify_author().is_err() || !f.held_ops().any(|o| o.content_hash() == forged.content_hash()), "a re-addressed op is not the one signed, nor held");
    }

    /// The key rule (F5 note 4): a settling of a server we own leaves in force a key our
    /// master set from a counted device after every dropped device's cut-off, inside the
    /// settled state. A key that already passes stands, so a second owner device that
    /// settles after the first rotates nothing.
    #[test]
    fn a_settling_of_an_owned_server_sets_a_fresh_key_unless_ours_stands() {
        let w = recorded_world();
        let mut f = baseless_replica(&w.log, OWNER, LAPTOP, true);
        f.authority = view_after(false);
        let _ = f.rebuild_now();
        let P::JoinKeySet { secret: old } = &w.key.payload else { unreachable!() };
        let old = old.clone();
        let (_, after) = crate::crdt::hold::tests::owner_rosters();
        let seen = SeenAt::new();
        let dropped = [keys(PHONE).1];
        let ids: BTreeSet<[u8; 32]> = BTreeSet::new();
        let settle = |f: &mut ServerState, keys_after_ms: Option<u64>| {
            let s = super::super::settle::Settling { before: f.authority.clone(), dropped: &dropped, t_ms: T, seen: &seen, roster: after.clone(), home: None, keys_after_ms };
            f.author_settling_on(&keys(OWNER).1, &s, &keys(LAPTOP).0, &super::super::settle::SettleOn::Record(ids.clone())).expect("the settling is written")
        };
        let (ops, _) = settle(&mut f, Some(T));
        let key = ops.iter().find(|o| matches!(o.payload, P::JoinKeySet { .. })).expect("a fresh key rides the settling");
        assert_eq!((key.author.as_str(), key.proven_device()), (keys(OWNER).1.as_str(), Some(keys(LAPTOP).1.as_str())), "ours, from the counted laptop");
        let P::ServerCheckpoint { state, .. } = &ops.last().unwrap().payload else { panic!("the settling last") };
        let st = crate::crdt::server_state::parse_state(state).unwrap();
        let P::JoinKeySet { secret } = &key.payload else { unreachable!() };
        assert!(st.join_secret.as_ref().is_some_and(|r| r.read() == secret), "the settled state holds the fresh key itself");
        assert!(st.join_secret.as_ref().is_some_and(|r| *r.read() != old));
        let fresh = secret.clone();
        // A settling again (another owner device, or a rival merge): our key stands.
        let (again, _) = settle(&mut f, Some(T));
        assert!(!again.iter().any(|o| matches!(o.payload, P::JoinKeySet { .. })), "a key we set after the cut-off stands");
        assert!(f.join_secret.as_ref().is_some_and(|r| *r.read() == fresh));
        let (late, _) = settle(&mut f, Some(u64::MAX - 1));
        assert!(late.iter().any(|o| matches!(o.payload, P::JoinKeySet { .. })), "a key set before a dropped device's cut-off is replaced");
        let (unknown, _) = settle(&mut f, None);
        assert!(unknown.iter().any(|o| matches!(o.payload, P::JoinKeySet { .. })), "an unknown cut-off never lets a key stand");
    }

    /// The key rule's other clauses: a key the dropped phone set never stands, nor one a
    /// member's view does not count as ours; a member's own settling writes no key.
    #[test]
    fn a_key_the_dropped_device_set_never_stands() {
        let w = recorded_world();
        let mut f = baseless_replica(&w.log, OWNER, LAPTOP, true);
        f.authority = view_after(false);
        let _ = f.rebuild_now();
        let phone_key = w.key.clone();
        let counted = baseless_replica(&w.log, OWNER, LAPTOP, true);
        let settled = counted.clone();
        assert!(settled.join_secret.as_ref().is_some_and(|r| *r.hlc() == phone_key.hlc), "precondition: the phone's key in force");
        assert!(!f.key_stands_for_test(&settled, &keys(OWNER).1, Some(0)), "the dropped phone's key");
        assert!(counted.key_stands_for_test(&settled, &keys(OWNER).1, Some(0)), "control: the same key while the phone counts");
        assert!(!counted.key_stands_for_test(&settled, &keys(MEMBER).1, Some(0)), "never another identity's");
        assert!(!counted.key_stands_for_test(&settled, &keys(OWNER).1, Some(phone_key.hlc.physical_ms)), "stamped at the cut-off is not after it");
    }
    /// The record's bounds: a witness whose in-scope ops pass 4,096, or 8 MiB of JSON,
    /// names no record at all (fail closed to an answer naming none); at the bound it does.
    /// The extra ops sit as parked rows: a test build's fold quota holds far fewer, a real
    /// one (128 MiB) holds this many.
    #[test]
    fn a_record_past_its_op_or_byte_bound_is_never_built() {
        let w = recorded_world();
        let mut m = baseless_replica(&w.log, MEMBER, MEMBER_PHONE, true);
        m.authority = view_after(false);
        let _ = m.rebuild_now();
        assert!(m.recovery.as_ref().is_some_and(|r| r.keeps_fold()), "precondition: part A holds");
        let base = m.witness_record(T, &seen_of(&m, &w.late)).expect("the plain record").0.len();
        // Each at its own clock in the phone's lane: one device minted them over time.
        let (master, _, pk) = keys(OWNER);
        let parked = |extra: usize, name_bytes: usize| {
            let mut r = m.clone();
            for i in 0..extra {
                let mut op = w.late.clone();
                op.payload = P::ChannelAdded { channel_id: format!("bound-{i}"), name: "x".repeat(name_bytes.max(1)), category: None, channel_type: String::new() };
                op.hlc.physical_ms += 1 + i as u64;
                op.auth = None;
                op.dev = None;
                op.sign(&master, &pk);
                op.sign_device(&keys(PHONE).0);
                r.stored.push((op, super::super::fold::RowKind::Parked(u64::MAX)));
            }
            let seen = seen_of(&r, &w.late);
            r.witness_record(T, &seen).map(|(ids, _)| ids.len())
        };
        assert_eq!(parked(RECORD_OPS_MAX - base, 0), Some(RECORD_OPS_MAX), "control: a record of exactly the bound");
        assert_eq!(parked(RECORD_OPS_MAX - base + 1, 0), None, "one op past the bound");
        let big = super::super::fold::MAX_OP_BYTES - 64 * 1024;
        assert!(parked(7, big).is_some(), "control: about 7 MiB");
        assert_eq!(parked(9, big), None, "past 8 MiB");
    }

    /// The settling's own scope (item 7): a record id naming an op the scope refuses (the
    /// dropped phone's join key) never enters the settling's input, whatever the id list says.
    #[test]
    fn a_record_id_out_of_scope_never_enters_the_settling() {
        let w = recorded_world();
        let mut f = baseless_replica(&w.log, OWNER, LAPTOP, true);
        f.authority = view_after(false);
        let _ = f.rebuild_now();
        let admit = w.log.iter().find(|o| matches!(&o.payload, P::MemberAdded { peer_id, .. } if *peer_id == keys(MEMBER).1)).unwrap().clone();
        let ids: BTreeSet<[u8; 32]> = [admit.content_hash(), w.key.content_hash()].into_iter().collect();
        let input = f.record_input(&ids);
        assert!(input.iter().any(|o| o.content_hash() == admit.content_hash()), "control: the admission the record lists");
        assert!(!input.iter().any(|o| o.content_hash() == w.key.content_hash()), "the phone's join key rode a record id into the settling");
    }
}
