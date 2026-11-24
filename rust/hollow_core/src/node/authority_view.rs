//! The authority view a node builds for one server from its OWN store (DEVICE_PROOF_DESIGN
//! section 10): the book, the co-member rosters (`server_rosters`) and every held
//! `cp_roster`. The process-global resolver is never read here.
#![allow(dead_code)] // seams track C2 calls until the merge (`.team/INTERFACE.md`)

use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, Mutex};

use crate::crdt::authority::{self, AuthorityView, ViewEntry};
use crate::crdt::server_state::ServerState;
use crate::crdt::verdict::ViewSource;
use crate::identity::roster::Roster;
use crate::storage::messages::MessageStore;

/// Rosters a co-member delivered for `master` in this server (`server_rosters`, track C2).
pub(crate) type CoMemberRosters<'a> = &'a dyn Fn(&str) -> Vec<Roster>;

/// The view of `state`'s authority set as this replica holds it.
pub(crate) fn view_for(store: &MessageStore, db_path: &str, state: &ServerState, co_members: CoMemberRosters<'_>) -> AuthorityView {
    let mut view = AuthorityView::judging();
    for master in authority::authority_set(state) {
        let entry = entry_for(store, db_path, state, &master, co_members);
        view.insert(master, entry);
    }
    view
}

fn entry_for(store: &MessageStore, db_path: &str, state: &ServerState, master: &str, co_members: CoMemberRosters<'_>) -> ViewEntry {
    let (pinned, carried) = candidates(store, db_path, state, master, co_members);
    let (pinned, carried): (Vec<&Roster>, Vec<&Roster>) = (pinned.iter().collect(), carried.iter().collect());
    authority::judge_held(master, &authority::key_rule(state, master), &pinned, &carried)
}

/// The rosters a view judges `master` by: pinned (book, then co-member rosters) and
/// carried (held `cp_roster`s).
fn candidates(
    store: &MessageStore,
    db_path: &str,
    state: &ServerState,
    master: &str,
    co_members: CoMemberRosters<'_>,
) -> (Vec<Roster>, Vec<Roster>) {
    let (mut pinned, mut carried): (Vec<Roster>, Vec<Roster>) = (Vec::new(), Vec::new());
    if !ignored_for_test(db_path, master) {
        // Read raw: `judge` verifies every statement it keeps, once.
        let book = match held_own(store, master) {
            Some(held) => held,
            None => store.load_roster(master).ok().flatten(),
        };
        pinned.extend(book.filter(|r| r.master == master));
        pinned.extend(co_members(master));
        carried.extend(authority::held_cp_rosters(state).into_iter().filter(|r| r.master == master));
    }
    (pinned, carried)
}

/// `master`'s devices in `state` judged with the relay's copy merged under OUR key
/// (design ROSTER-CHECK): the copy is carried, so it merges only under the key our own
/// rosters chose and never picks it. A copy under another key is a conflict; ours
/// legacy and the copy keyed counts a device only where both count it. With no roster
/// of ours the copy alone judges; no copy places nothing.
pub(crate) fn relay_placement(
    store: &MessageStore,
    db_path: &str,
    state: &ServerState,
    master: &str,
    relay: Option<&Roster>,
) -> super::roster_check::Placement {
    let co = |m: &str| co_member_rosters(store, &state.server_id, m);
    let (pinned, carried) = candidates(store, db_path, state, master, &co);
    placement_from(master, &authority::key_rule(state, master), &pinned, &carried, relay)
}

/// [`relay_placement`] over the rosters already gathered.
pub(crate) fn placement_from(
    master: &str,
    rule: &authority::KeyRule,
    pinned: &[Roster],
    carried: &[Roster],
    relay: Option<&Roster>,
) -> super::roster_check::Placement {
    use super::roster_check::Placement;
    let Some(relay) = relay else { return Placement::default() };
    let pinned: Vec<&Roster> = pinned.iter().collect();
    let mut carried: Vec<&Roster> = carried.iter().collect();
    // No roster of ours: the relay's copy alone. The gate only narrows what the caller
    // already places, so the copy can take a device away but never add one.
    let Some(key) = authority::judge_held(master, rule, &pinned, &carried).key else {
        let alone = authority::judge(master, &authority::KeyRule::FirstHeld, &[relay]).auth.unwrap_or_default();
        let removed: std::collections::BTreeSet<String> = alone.removed.into_keys().collect();
        let counted = alone.counted.into_iter().filter(|d| !removed.contains(d)).collect();
        return Placement { counted, removed, conflict: false };
    };
    if !key.is_empty() && relay.r_pub != key {
        return Placement { conflict: true, ..Placement::default() };
    }
    carried.push(relay);
    let Some(merged) = authority::judge_held(master, rule, &pinned, &carried).auth else { return Placement::default() };
    let mut out = Placement { counted: merged.counted, removed: merged.removed.into_keys().collect(), conflict: false };
    if key.is_empty() && !relay.r_pub.is_empty() {
        let alone = authority::judge(master, &authority::KeyRule::FirstHeld, &[relay]).auth.unwrap_or_default();
        out.counted.retain(|d| alone.counts(d));
        out.removed.extend(alone.removed.into_keys());
    }
    let removed = out.removed.clone();
    out.counted.retain(|d| !removed.contains(d));
    out
}

/// The co-member rosters of `master` held for `server_id` (section 9's keep rules).
fn co_member_rosters(store: &MessageStore, server_id: &str, master: &str) -> Vec<Roster> {
    super::server_rosters::co_member_rosters(store, server_id, master)
}

/// Make `state` judge by this node's store from now on.
pub(crate) fn install(state: &mut ServerState, db_path: &str, db_passphrase: &str) {
    let (path, pass) = (db_path.to_string(), db_passphrase.to_string());
    state.set_view_source(ViewSource(Arc::new(move |state: &ServerState, master: &str| {
        let store = MessageStore::lease(&path, &pass).ok()?;
        let co = |m: &str| co_member_rosters(&store, &state.server_id, m);
        Some(entry_for(&store, &path, state, master, &co))
    })));
}

/// Masters whose roster a node saved since its last tick, by database path: a cache
/// signal for the views, never a source of statements.
static SAVED: Mutex<Option<HashMap<String, BTreeSet<String>>>> = Mutex::new(None);

/// A roster of `master` was written to `store` (`roster_book`'s one write path).
pub(crate) fn note_saved(store: &MessageStore, master: &str) {
    let Some(path) = store.db_path() else { return };
    let mut saved = SAVED.lock().unwrap_or_else(|e| e.into_inner());
    saved.get_or_insert_with(HashMap::new).entry(path).or_default().insert(master.to_string());
}

/// Our own roster from before a change typed in this process, by database path: the
/// views judge our identity by it until the node takes the change (`release_own`), so no
/// rebuild in between steps a server back before its settling reads what it held
/// (section 8.1).
static OWN_HELD: Mutex<Vec<OwnHeld>> = Mutex::new(Vec::new());

struct OwnHeld {
    db: String,
    master: String,
    roster: Option<Roster>,
    at: std::time::Instant,
}

/// A node that never takes the change (stopped, wedged) lets the hold go after this.
const OWN_HOLD_MAX: std::time::Duration = std::time::Duration::from_secs(60);

/// Hold our own stored roster before a change to it; false when one is held already
/// (the oldest stays: it is the one the node's servers were judged by).
pub(crate) fn hold_own(store: &MessageStore, master: &str) -> bool {
    hold_own_as(store, master, store.load_roster(master).ok().flatten())
}

/// [`hold_own`] with the roster to judge by given: an owed settling's at a start
/// (`settle_owed`), the change it was noted before having landed already.
pub(crate) fn hold_own_as(store: &MessageStore, master: &str, roster: Option<Roster>) -> bool {
    let Some(db) = store.db_path() else { return false };
    let mut held = OWN_HELD.lock().unwrap_or_else(|e| e.into_inner());
    held.retain(|h| h.at.elapsed() < OWN_HOLD_MAX);
    if held.iter().any(|h| h.db == db && h.master == master) {
        return false;
    }
    held.push(OwnHeld { db, master: master.to_string(), roster, at: std::time::Instant::now() });
    true
}

/// The node took the change: judge by the stored roster again, in every view on the
/// next tick.
pub(crate) fn release_own(store: &MessageStore, master: &str) {
    let Some(db) = store.db_path() else { return };
    let released = {
        let mut held = OWN_HELD.lock().unwrap_or_else(|e| e.into_inner());
        let before = held.len();
        held.retain(|h| !(h.db == db && h.master == master));
        held.len() != before
    };
    if released {
        note_saved(store, master);
    }
}

fn held_own(store: &MessageStore, master: &str) -> Option<Option<Roster>> {
    let db = store.db_path()?;
    let held = OWN_HELD.lock().unwrap_or_else(|e| e.into_inner());
    held.iter().find(|h| h.db == db && h.master == master && h.at.elapsed() < OWN_HOLD_MAX).map(|h| h.roster.clone())
}

fn take_saved(key: &str) -> BTreeSet<String> {
    let mut saved = SAVED.lock().unwrap_or_else(|e| e.into_inner());
    saved.as_mut().and_then(|m| m.remove(key)).unwrap_or_default()
}

/// Servers whose view changed and wait for the coalesced rebuild (section 10): the
/// event loop owns one and drains it on its tick.
#[derive(Debug, Default)]
pub(crate) struct ViewDirty {
    servers: BTreeSet<String>,
    /// The store's own path, the key `note_saved` files under (resolved once).
    key: Option<String>,
    last_rebuild: HashMap<String, std::time::Instant>,
}

/// At most one view-triggered rebuild per server per this long (section 14).
const REBUILD_GAP: std::time::Duration = std::time::Duration::from_secs(10);
/// Rebuilds one batch tick runs on the event loop; the rest stay marked for the next.
const REBUILDS_PER_TICK: usize = 4;

impl ViewDirty {
    pub(crate) fn mark(&mut self, server: &str) {
        self.servers.insert(server.to_string());
    }

    pub(crate) fn take(&mut self) -> BTreeSet<String> {
        std::mem::take(&mut self.servers)
    }

    /// Judge again every master whose roster was saved, in every state whose view holds
    /// it, and return the servers to rebuild now (each at most once per `REBUILD_GAP`, at
    /// most `REBUILDS_PER_TICK` of them).
    pub(crate) fn due(&mut self, states: &mut HashMap<String, ServerState>, db_path: &str, db_passphrase: &str) -> Vec<String> {
        if rebuilds_held_for_test(db_path) {
            return Vec::new();
        }
        if self.key.is_none() {
            self.key = MessageStore::lease(db_path, db_passphrase).ok().and_then(|s| s.db_path());
        }
        let saved = self.key.as_deref().map(take_saved).unwrap_or_default();
        for (server, state) in states.iter_mut() {
            let mut changed = false;
            for master in &saved {
                changed |= state.refresh_view_of(master);
            }
            // A retire past its author's rebuild budget waits for this rebuild (section 14).
            if changed || state.retire_rebuild_due() {
                self.servers.insert(server.clone());
            }
        }
        let now = std::time::Instant::now();
        let due: Vec<String> = self
            .servers
            .iter()
            .filter(|s| self.last_rebuild.get(*s).is_none_or(|at| now.duration_since(*at) >= REBUILD_GAP))
            .take(REBUILDS_PER_TICK)
            .cloned()
            .collect();
        for s in &due {
            self.servers.remove(s);
            self.last_rebuild.insert(s.clone(), now);
        }
        self.last_rebuild.retain(|_, at| now.duration_since(*at) < REBUILD_GAP);
        due
    }
}

#[cfg(test)]
static REBUILDS_HELD: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// Harness: the node at `db_path` takes no saved roster into its views and rebuilds
/// nothing for one (a busy event loop's `REBUILD_GAP`, stretched) until released.
#[cfg(test)]
pub(crate) fn hold_rebuilds_for_test(db_path: &str, held: bool) {
    let mut h = REBUILDS_HELD.lock().unwrap_or_else(|e| e.into_inner());
    h.retain(|p| p != db_path);
    if held {
        h.push(db_path.to_string());
    }
}

#[cfg(test)]
fn rebuilds_held_for_test(db_path: &str) -> bool {
    REBUILDS_HELD.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|p| p == db_path)
}

#[cfg(not(test))]
fn rebuilds_held_for_test(_db_path: &str) -> bool {
    false
}

#[cfg(test)]
static IGNORED: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new());

/// Harness: the node at `db_path` refuses every roster of `master` (book and
/// `server_rosters` alike), so its view reads `master` as `Missing`.
#[cfg(test)]
pub(crate) fn ignore_for_test(db_path: &str, master: &str) {
    IGNORED.lock().unwrap_or_else(|e| e.into_inner()).push((db_path.to_string(), master.to_string()));
}

/// Harness: undo `ignore_for_test`, as if the roster had just arrived.
#[cfg(test)]
pub(crate) fn unignore_for_test(db_path: &str, master: &str) {
    IGNORED.lock().unwrap_or_else(|e| e.into_inner()).retain(|(p, m)| !(p == db_path && m == master));
}

#[cfg(test)]
pub(crate) fn ignored_for_test(db_path: &str, master: &str) -> bool {
    IGNORED.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|(p, m)| p == db_path && m == master)
}

#[cfg(not(test))]
pub(crate) fn ignored_for_test(_db_path: &str, _master: &str) -> bool {
    false
}

#[cfg(test)]
static BOOK_REFUSED: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new());

/// Harness: the node of `device` writes no book roster of `master`, as a member that
/// never met it (no notice, card or friendship reaches it); `server_rosters` still keeps.
#[cfg(test)]
pub(crate) fn refuse_book_for_test(device: &str, master: &str) {
    BOOK_REFUSED.lock().unwrap_or_else(|e| e.into_inner()).push((device.to_string(), master.to_string()));
}

#[cfg(test)]
pub(crate) fn unrefuse_book_for_test(device: &str) {
    BOOK_REFUSED.lock().unwrap_or_else(|e| e.into_inner()).retain(|(d, _)| d != device);
}

#[cfg(test)]
pub(crate) fn book_refused_for_test(device: &str, master: &str) -> bool {
    BOOK_REFUSED.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|(d, m)| d == device && m == master)
}

#[cfg(not(test))]
pub(crate) fn book_refused_for_test(_device: &str, _master: &str) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::authority::DeviceVerdict;
    use crate::crdt::testkeys::keys;

    /// A phrase-rooted roster of `master` keeping `devices`, each consenting.
    fn rooted(master: &crate::identity::native_identity::NativeKeypair, recovery: &crate::identity::native_identity::NativeKeypair, devices: &[&crate::identity::native_identity::NativeKeypair]) -> Roster {
        use crate::identity::roster;
        let mut r = Roster::new(&master.peer_id());
        for d in devices {
            r.add_consent(roster::sign_consent(d, &master.peer_id()));
        }
        let keep: Vec<String> = devices.iter().map(|d| d.peer_id()).collect();
        r.add_phrase_statement(&roster::r_pub_of(recovery), Some(roster::sign_recovery(master, recovery, 1_000, &keep, false)), None)
            .expect("a fresh roster takes any key");
        r
    }

    /// Design ROSTER-CHECK MED-4: the relay's copy merges under OUR key and never picks
    /// it; a removal anywhere in the merge wins; another key is a conflict, never a
    /// refusal; ours legacy and the copy keyed counts only what both count.
    #[test]
    fn the_relays_copy_is_judged_under_our_key() {
        use crate::crdt::authority::KeyRule;
        use crate::node::roster_check::Placed;
        let (m, m_id, _) = keys(51);
        let (rec, _, _) = keys(52);
        let (rec2, _, _) = keys(55);
        let (phone, phone_id, _) = keys(53);
        let (laptop, laptop_id, _) = keys(54);
        let ours = rooted(&m, &rec, &[&phone, &laptop]);
        let rule = KeyRule::FirstHeld;
        let at = |relay: Option<&Roster>, pinned: &[Roster]| placement_from(&m_id, &rule, pinned, &[], relay);

        let none = at(None, std::slice::from_ref(&ours));
        assert_eq!(none.of(&phone_id), Placed::Skip, "no answer places nothing");
        let same = at(Some(&ours), std::slice::from_ref(&ours));
        assert_eq!((same.of(&phone_id), same.of(&laptop_id)), (Placed::Ask, Placed::Ask));

        let mut removing = ours.clone();
        let base = removing.base();
        removing.add_removal(crate::identity::roster::sign_removal(&phone, &m_id, &base, &laptop_id, &[]));
        let removed = at(Some(&removing.verified(1_000)), std::slice::from_ref(&ours));
        assert_eq!(removed.of(&laptop_id), Placed::Removed, "the relay's removal counts");
        assert_eq!(removed.of(&phone_id), Placed::Ask);

        let forged = rooted(&m, &rec2, &[&phone, &laptop]);
        let conflict = at(Some(&forged), std::slice::from_ref(&ours));
        assert_eq!(conflict.of(&phone_id), Placed::Conflict, "another key is a conflict");
        let mut forged_removal = forged.clone();
        let fbase = forged_removal.base();
        forged_removal.add_removal(crate::identity::roster::sign_removal(&phone, &m_id, &fbase, &laptop_id, &[]));
        assert_eq!(at(Some(&forged_removal), std::slice::from_ref(&ours)).of(&laptop_id), Placed::Conflict, "and never a refusal");

        let legacy = Roster::legacy_for_test(&m, &[&phone, &laptop]);
        let keyed_phone_only = rooted(&m, &rec, &[&phone]);
        let both = at(Some(&keyed_phone_only), std::slice::from_ref(&legacy));
        assert_eq!(both.of(&phone_id), Placed::Ask, "counted in both");
        assert_eq!(both.of(&laptop_id), Placed::Skip, "ours legacy counts it, the keyed copy does not");
        let legacy_phone_only = Roster::legacy_for_test(&m, &[&phone]);
        let keyed_both = rooted(&m, &rec, &[&phone, &laptop]);
        let only_relay = at(Some(&keyed_both), std::slice::from_ref(&legacy_phone_only));
        assert_eq!(only_relay.of(&laptop_id), Placed::Skip, "the keyed copy counts it, ours legacy does not: the copy never picks");
        assert_eq!(only_relay.of(&phone_id), Placed::Ask);

        assert_eq!(at(Some(&ours), &[]).of(&phone_id), Placed::Ask, "no roster of ours: the copy alone narrows");
        assert_eq!(at(Some(&removing.verified(1_000)), &[]).of(&laptop_id), Placed::Removed, "and its removal counts");
    }

    /// A saved roster re-judges its master in EVERY held server whose view holds it,
    /// whichever server the save came through (C2's `server_rosters::keep` included).
    #[test]
    fn a_saved_roster_marks_every_server_whose_view_holds_its_master() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("view.db").to_str().unwrap().to_string();
        let pass = "ab".repeat(32);
        MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        let store = MessageStore::open(&db, &pass).unwrap();
        let (member, m_id, _) = keys(31);
        let (phone, phone_id, _) = keys(32);
        let state_with = |sid: &str, holds: bool| {
            let mut s = ServerState::skeleton(sid.into());
            let mut v = AuthorityView::judging();
            if holds {
                v.insert(m_id.clone(), ViewEntry::default());
            }
            s.authority = Arc::new(v);
            install(&mut s, &db, &pass);
            s
        };
        let mut states: HashMap<String, ServerState> =
            [("a", true), ("b", true), ("c", false)].into_iter().map(|(sid, holds)| (sid.to_string(), state_with(sid, holds))).collect();
        let mut dirty = ViewDirty::default();
        assert!(dirty.due(&mut states, &db, &pass).is_empty(), "nothing saved yet");

        let roster = Roster::genesis(&member, &keys(33).0, &phone, super::super::roster_book::now_ms());
        super::super::roster_book::merge_for_test(&store, &roster, &keys(34).1, &keys(35).1);
        let mut due = dirty.due(&mut states, &db, &pass);
        due.sort();
        assert_eq!(due, vec!["a".to_string(), "b".to_string()], "both servers holding the master re-judge, the other does not");
        for sid in ["a", "b"] {
            assert_eq!(states[sid].authority.device_verdict(&m_id, &phone_id), DeviceVerdict::Counted, "{sid} counts the saved device");
        }
    }

    /// Section 8.1: a change typed here is judged by the roster from before it until
    /// the node takes the change; then every view holding the master judges again.
    #[test]
    fn a_held_own_roster_judges_until_released_then_every_view_rejudges() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("view.db").to_str().unwrap().to_string();
        let pass = "ab".repeat(32);
        MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        let store = MessageStore::open(&db, &pass).unwrap();
        let (member, m_id, _) = keys(41);
        let (phone, phone_id, _) = keys(42);
        let mut s = ServerState::skeleton("a".into());
        let mut v = AuthorityView::judging();
        v.insert(m_id.clone(), ViewEntry::default());
        s.authority = Arc::new(v);
        install(&mut s, &db, &pass);
        let mut states: HashMap<String, ServerState> = [("a".to_string(), s)].into_iter().collect();
        let mut dirty = ViewDirty::default();

        assert!(hold_own(&store, &m_id), "nothing held yet");
        assert!(!hold_own(&store, &m_id), "the oldest hold stays");
        let roster = Roster::genesis(&member, &keys(43).0, &phone, super::super::roster_book::now_ms());
        super::super::roster_book::merge_for_test(&store, &roster, &keys(44).1, &keys(45).1);
        assert!(dirty.due(&mut states, &db, &pass).is_empty(), "the held roster still judges");
        assert_ne!(states["a"].authority.device_verdict(&m_id, &phone_id), DeviceVerdict::Counted);

        release_own(&store, &m_id);
        assert_eq!(dirty.due(&mut states, &db, &pass), vec!["a".to_string()], "released: the view judges again");
        assert_eq!(states["a"].authority.device_verdict(&m_id, &phone_id), DeviceVerdict::Counted);
    }

    /// Section 14: a retire held past its author's rebuild budget marks its server for
    /// the tick's coalesced rebuild, at most once per gap.
    #[test]
    fn a_held_retire_marks_its_server_for_the_coalesced_rebuild() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("view.db").to_str().unwrap().to_string();
        let pass = "ab".repeat(32);
        MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        let mut states: HashMap<String, ServerState> =
            ["a", "b"].into_iter().map(|sid| (sid.to_string(), ServerState::skeleton(sid.into()))).collect();
        let mut dirty = ViewDirty::default();
        assert!(dirty.due(&mut states, &db, &pass).is_empty(), "nothing held");
        states.get_mut("a").unwrap().hold_retire_for_test();
        assert_eq!(dirty.due(&mut states, &db, &pass), vec!["a".to_string()], "the held retire's server rebuilds");
        assert!(dirty.due(&mut states, &db, &pass).is_empty(), "once per gap, however often it is marked");
    }

    #[test]
    fn one_tick_rebuilds_a_bounded_number_of_servers_and_keeps_the_rest_marked() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("view.db").to_str().unwrap().to_string();
        let pass = "ab".repeat(32);
        MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        let mut states: HashMap<String, ServerState> = HashMap::new();
        let mut dirty = ViewDirty::default();
        for i in 0..(REBUILDS_PER_TICK + 3) {
            dirty.mark(&format!("s{i}"));
        }
        let first = dirty.due(&mut states, &db, &pass);
        assert_eq!(first.len(), REBUILDS_PER_TICK);
        let second = dirty.due(&mut states, &db, &pass);
        assert_eq!(second.len(), 3, "the rest rebuild on the next tick");
        assert!(first.iter().all(|s| !second.contains(s)));
    }
    /// REVIEW (part A): section 5 judges a non-committing owner by the key the BOOK pinned;
    /// `entry_for` also takes the first held `cp_roster` under `FirstHeld`, and `plan`
    /// keeps the `cp_roster` of every checkpoint that verifies as a base, eligible or not.
    /// A thief holding the owner master key mints a roster under a fresh recovery key and
    /// ships it in a backdated checkpoint: a replica with no book or co-member row for the
    /// owner then counts the thief's device and not the honest one.
    #[test]
    fn review_an_ineligible_checkpoints_forged_roster_never_picks_the_owners_key() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("view.db").to_str().unwrap().to_string();
        let pass = "ab".repeat(32);
        MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        let store = MessageStore::open(&db, &pass).unwrap();
        let (owner, o_id, _) = keys(51);
        let (phone, phone_id, _) = keys(52);
        let (thief_dev, thief_id, _) = keys(53);
        let honest = Roster::genesis(&owner, &keys(54).0, &phone, 1_000);
        let forged = Roster::genesis(&owner, &keys(55).0, &thief_dev, 900);
        let mut s = ServerState::skeleton("legacy".into());
        // Held order: the backdated thief checkpoint's roster first, the honest settling's after.
        s.cp_rosters = Arc::new(vec![forged.clone(), honest.clone()]);
        let counts = |e: &ViewEntry, d: &str| e.auth.as_ref().is_some_and(|a| a.counts(d));
        let e = entry_for(&store, &db, &s, &o_id, &|_| Vec::new());
        assert!(!counts(&e, &thief_id) && e.key.is_none(), "with nothing pinned, no carried roster picks the key: {e:?}");
        // A co-member row pins the honest key; the forged roster never merges under it.
        let pinned = honest.clone();
        let e = entry_for(&store, &db, &s, &o_id, &|_| vec![pinned.clone()]);
        assert!(
            counts(&e, &phone_id) && !counts(&e, &thief_id),
            "the owner is judged by the forged key: phone counted {}, thief counted {}",
            counts(&e, &phone_id),
            counts(&e, &thief_id)
        );
        // Under the founding nonce's commitment a carried roster may pick its key.
        let rule = authority::KeyRule::Commit(authority::nonce_commitment(&authority::committing_nonce(&o_id, &honest.r_pub)).unwrap().to_string());
        let e = authority::judge_held(&o_id, &rule, &[], &[&forged, &honest]);
        assert!(counts(&e, &phone_id) && !counts(&e, &thief_id), "the committed key judges: {e:?}");
    }

    /// The same rule where `server_rosters` judges (asker places, digest prints): a
    /// carried roster never picks the key over a store with nothing pinned.
    #[test]
    fn server_rosters_never_lets_a_carried_roster_pick_the_owners_key() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("rows.db").to_str().unwrap().to_string();
        let pass = "ab".repeat(32);
        MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
        let store = MessageStore::open(&db, &pass).unwrap();
        let (owner, o_id, _) = keys(61);
        let (thief_dev, thief_id, _) = keys(63);
        let forged = Roster::genesis(&owner, &keys(65).0, &thief_dev, 900);
        let mut s = ServerState::skeleton("legacy-rows".into());
        s.cp_rosters = Arc::new(vec![forged]);
        let e = super::super::server_rosters::entry(&store, &db, &s, &o_id);
        assert!(e.auth.as_ref().is_none_or(|a| !a.counts(&thief_id)) && e.key.is_none(), "a carried roster picked the key: {e:?}");
    }
}
