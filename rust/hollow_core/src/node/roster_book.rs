//! Every identity's roster as this node holds it (design ID-1): storage, the fold on
//! this node's own clock, our own roster's upkeep and changes, ingest, and showing our
//! roster to the relay, which folds it to decide who reads our inbox (ID-1R).
//!
//! The resolver holds members only. A device that holds the master key but is pending,
//! removed or unknown to the roster resolves to itself, so it is never "one of us".

use std::collections::BTreeSet;

use tokio::sync::mpsc;

use crate::identity::native_identity::NativeKeypair;
use crate::identity::roster::{self, Removal, Roster, RosterState};
use crate::storage::MessageStore;

use super::types::NetworkEvent;

pub(crate) use crate::identity::roster::MAX_ROSTER_BYTES;
/// Statements the node imports at its next start, written where the database is not
/// open yet (a new identity, a phrase typed before the node runs).
pub(crate) const BOOTSTRAP_FILE: &str = "roster_bootstrap.json";

const OWN_REMOVED_BY: &str = "own_removed_by";
const OWN_REMOVED_AT: &str = "own_removed_at_ms";

pub(crate) fn now_ms() -> i64 {
    super::types::now_ms()
}

/// The stored roster for `master`, checked again but never against the clock: its
/// times were judged on arrival. `None` for no row, a 0.11 row, or one that does not read.
pub(crate) fn load(store: &MessageStore, master: &str) -> Option<Roster> {
    load_strict(store, master).ok().flatten()
}

/// [`load`], telling a roster that does not read apart from no roster.
pub(crate) fn load_strict(store: &MessageStore, master: &str) -> Result<Option<Roster>, String> {
    let Some(roster) = store.load_roster(master)?.map(|r| r.reverified()) else { return Ok(None) };
    if roster.master != master {
        return Err(format!("The roster stored for {master} names another identity"));
    }
    Ok(Some(roster))
}

/// Fold `roster` on this node's own first-sight clock.
pub(crate) fn fold(store: &MessageStore, roster: &Roster) -> RosterState {
    let seen = store.load_roster_seen(&roster.master, &roster.base()).unwrap_or_default();
    roster.fold(|d| seen.get(d).copied(), now_ms())
}

/// The removals of `roster` that count on this node's first-sight clock, sorted.
pub(crate) fn counting_removals(store: &MessageStore, roster: &Roster) -> Vec<Removal> {
    let seen = store.load_roster_seen(&roster.master, &roster.base()).unwrap_or_default();
    let mut out = roster.counting_removals(|d| seen.get(d).copied(), now_ms());
    out.sort();
    out
}

/// Stamp when this node first saw each pending join in `roster`'s current base.
fn stamp_pending(store: &MessageStore, roster: &Roster) {
    let now = now_ms();
    let base = roster.base();
    for p in roster.pendings.iter().filter(|p| p.base == base) {
        let _ = store.stamp_roster_seen(&roster.master, &base, &p.device, now);
    }
}

/// `incoming` merged into `held` as this node keeps rosters: asks past their ceiling
/// give way by this node's first sight of them (C-IDENTITY-16).
fn merged_here(store: &MessageStore, held: Option<&Roster>, incoming: &Roster) -> Roster {
    let master = incoming.master.as_str();
    held.cloned().unwrap_or_else(|| Roster::new(master)).merged_by_first_sight(incoming, |base, device| {
        store.load_roster_seen(master, base).ok().and_then(|seen| seen.get(device).copied())
    })
}

/// Persist `roster` and point its master's links at the members. The resolver
/// follows: a device that stopped being a member stops resolving to the master, the
/// master's own id included.
fn save(
    store: &MessageStore,
    roster: &Roster,
    state: &RosterState,
    local_master: &str,
    local_device: &str,
) -> Result<(), String> {
    save_rows(store, roster, state, local_master, local_device)?;
    point_resolver(&roster.master, state, local_master, local_device);
    Ok(())
}

/// [`save`] without the resolver: inside a transaction the process-global resolver
/// moves only once the rows committed ([`follow`]).
fn save_rows(
    store: &MessageStore,
    roster: &Roster,
    state: &RosterState,
    local_master: &str,
    local_device: &str,
) -> Result<(), String> {
    if super::authority_view::book_refused_for_test(local_device, &roster.master) {
        return Ok(());
    }
    let json = serde_json::to_string(roster).map_err(|e| format!("roster json: {e}"))?;
    let members: Vec<String> = state.members.iter().cloned().collect();
    if roster.master == local_master {
        date_held_before_upgrade(store, local_master)?;
    }
    store.save_device_list(&roster.master, &json, 0, &members, now_ms())?;
    super::server_rosters::touched_master(&roster.master);
    super::authority_view::note_saved(store, &roster.master);
    super::security_alerts::resolve_departed(store, &roster.master, &state.members, |device| {
        roster.removals.iter().any(|r| r.device == device && r.by == local_device)
    });
    // When we learned each of our own removals: our DMs carry it from then (F2).
    if roster.master == local_master {
        note_statements(store, roster, state);
        let mut devices: Vec<String> = counting_removals(store, roster).into_iter().map(|r| r.device).collect();
        devices.dedup();
        let _ = store.removal_carried_since(local_master, &state.base, &devices, now_ms());
    }
    revoked_rows(store, &roster.master, state, local_device);
    Ok(())
}

/// `state`'s removed devices, never ourselves.
fn removed_ids(state: &RosterState, local_device: &str) -> Vec<String> {
    state.removed.keys().filter(|d| d.as_str() != local_device).cloned().collect()
}

/// Members `master`'s own removal still refuses: its recovery brought them back.
fn back_ids(master: &str, state: &RosterState) -> Vec<String> {
    state.members.iter().filter(|d| super::resolver::is_revoked_by(master, d)).cloned().collect()
}

/// Record `state`'s removed devices as refused (the refusal survives a restart) and
/// refuse no longer the members a recovery brought back.
fn revoked_rows(store: &MessageStore, master: &str, state: &RosterState, local_device: &str) {
    let removed = removed_ids(state, local_device);
    if !removed.is_empty() {
        let _ = store.record_revoked_devices(master, &removed);
    }
    let back = back_ids(master, state);
    if !back.is_empty() {
        let _ = store.clear_revoked_devices(master, &back);
    }
}

/// Per identity, how often its stored roster changed in this process (each commit
/// this process saved or followed from another's): what a cache of the roster keys on.
fn revisions() -> &'static std::sync::Mutex<std::collections::HashMap<String, u64>> {
    static REVISIONS: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<String, u64>>> = std::sync::OnceLock::new();
    REVISIONS.get_or_init(Default::default)
}

/// The revision of `master`'s stored roster, 0 before any change here.
pub(crate) fn revision(master: &str) -> u64 {
    revisions().lock().map_or(0, |r| r.get(master).copied().unwrap_or(0))
}

fn bump_revision(master: &str) {
    if let Ok(mut r) = revisions().lock() {
        *r.entry(master.to_string()).or_insert(0) += 1;
    }
}

/// Point `master`'s links at the members of `state` and refuse its removed devices.
fn point_resolver(master: &str, state: &RosterState, local_master: &str, local_device: &str) {
    bump_revision(master);
    let members: Vec<String> = state.members.iter().cloned().collect();
    let held = super::resolver::devices_for(master).into_iter().chain([master.to_string()]);
    for d in held {
        if !state.members.contains(&d) {
            super::resolver::forget(&d);
        }
    }
    super::resolver::note_roster(master);
    if master == local_master {
        super::resolver::seed_self(local_master, &members);
    } else {
        super::resolver::update_many(master, members.iter().map(String::as_str));
    }
    let removed = removed_ids(state, local_device);
    if !removed.is_empty() {
        super::resolver::mark_revoked_by(master, &removed);
    }
    let back = back_ids(master, state);
    if !back.is_empty() {
        super::resolver::unmark_revoked_by(master, &back);
    }
}

/// Point the resolver at a fold that just committed: in full when it changed the
/// roster, else only its members (a roster now held).
fn follow(master: &str, state: &RosterState, changed: bool, local_master: &str, local_device: &str) {
    if changed {
        point_resolver(master, state, local_master, local_device);
        return;
    }
    super::resolver::note_roster(master);
    if master == local_master {
        super::resolver::seed_self(local_master, &state.members.iter().cloned().collect::<Vec<_>>());
    } else {
        super::resolver::update_many(master, state.members.iter().map(String::as_str));
    }
}

/// What following the stored rosters did, for the caller to act on.
#[derive(Default, Debug)]
pub(crate) struct Reconciled {
    /// Identities whose stored roster the resolver now follows: tell the app.
    pub masters: Vec<String>,
    /// Every device those rosters removed: drop their sessions and leaves (idempotent,
    /// so a device another path already dropped costs nothing).
    pub removed: Vec<String>,
    /// Per identity, the devices a recovery the other process stored dropped.
    pub dropped: Vec<(String, Vec<String>)>,
}

impl Reconciled {
    /// The join locks of the identities a stored recovery dropped devices of move.
    pub(crate) fn note_drops(&self) {
        for (master, devices) in &self.dropped {
            super::lock_keeper::note_dropped_devices(master, devices);
        }
    }
}

/// Follow the contact rosters another process (the push fetch, the iOS NSE) changed
/// in `store`: `master`'s only, or every marked one. The marks are taken.
pub(crate) fn reconcile_dirty(
    store: &MessageStore,
    master: Option<&str>,
    local_master: &str,
    local_device: &str,
) -> Reconciled {
    let mut out = Reconciled::default();
    for m in store.take_roster_dirty(master).iter().filter(|m| m.as_str() != local_master) {
        let Some(roster) = load(store, m) else { continue };
        let state = fold(store, &roster);
        revoked_rows(store, m, &state, local_device);
        point_resolver(m, &state, local_master, local_device);
        out.removed.extend(removed_ids(&state, local_device));
        let dropped: Vec<String> = store.take_roster_dropped(m).into_iter().filter(|d| d != local_device).collect();
        if !dropped.is_empty() {
            out.dropped.push((m.clone(), dropped));
        }
        out.masters.push(m.clone());
    }
    out
}

/// Merge `roster` into what `store` holds for its master and save it, the way an
/// ingest would. Tests only: it stages state a scenario starts from.
#[cfg(test)]
pub(crate) fn merge_for_test(store: &MessageStore, roster: &Roster, local_master: &str, local_device: &str) {
    let merged = merged_here(store, load(store, &roster.master).as_ref(), &roster.verified(now_ms()));
    stamp_pending(store, &merged);
    let state = fold(store, &merged);
    save(store, &merged, &state, local_master, local_device).expect("save roster");
}

/// Show the relay our roster: it folds every roster shown for our master into one and
/// lets a device into our inbox only while that fold counts it, so what we show
/// teaches it our removals and recoveries at once. A waiting device shows it too,
/// which starts the relay's seven days.
pub(crate) fn show_relay(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_master: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    if let Some(roster) = own_roster(local_master, db_path, db_passphrase) {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinInbox {
            room_code: format!("inbox:{local_master}"),
            roster,
        });
    }
}

// -- Our own roster --

/// Where the bootstrap file of the node whose database is `db_path` lives.
fn bootstrap_path(db_path: &str) -> Option<std::path::PathBuf> {
    std::path::Path::new(db_path).parent().map(|d| d.join(BOOTSTRAP_FILE))
}

/// Write statements for the node to import at its next start.
pub(crate) fn write_bootstrap(data_dir: &std::path::Path, roster: &Roster) -> Result<(), String> {
    let json = serde_json::to_string(roster).map_err(|e| format!("roster json: {e}"))?;
    std::fs::write(data_dir.join(BOOTSTRAP_FILE), json)
        .map_err(|e| format!("Failed to write the roster bootstrap: {e}"))
}

/// Bring our own roster up to date at start, and return it with its fold.
///
/// A bootstrap file is merged first. Without a roster, a device its own 0.11 list
/// names (or the only device, with no list) takes its seat: by signing the identity's
/// first recovery with the phrase 0.11 stored here, else by a legacy claim, and either
/// way removes what that list had revoked. A device the list does not name asks to
/// join. With a roster, a device that is nothing in it asks to join.
pub(crate) fn ensure_own(
    store: &MessageStore,
    master: &NativeKeypair,
    device: &NativeKeypair,
    db_path: &str,
) -> (Roster, RosterState) {
    let me = device.peer_id();
    let own = master.peer_id();
    let mut roster = load(store, &own);

    if let Some(path) = bootstrap_path(db_path).filter(|p| p.exists()) {
        let boot = std::fs::read_to_string(&path)
            .ok()
            .and_then(|j| serde_json::from_str::<Roster>(&j).ok())
            .map(|r| r.verified(now_ms()))
            .filter(|r| r.master == own);
        if let Some(boot) = boot {
            roster = Some(roster.unwrap_or_else(|| Roster::new(&own)).merged(&boot));
            hollow_log!("[HOLLOW-ROSTER] Imported the roster bootstrap");
        }
        let _ = std::fs::remove_file(&path);
    }

    // A key taken before this device knew better goes the way one arriving now would.
    let roster = roster.map(|r| heard_for_own(store, &own, &r));

    let mut roster = match roster {
        Some(r) => r,
        None => {
            let mut r = Roster::new(&own);
            let old = store.load_device_list(&own).ok().flatten();
            let seat = match &old {
                Some(old) if old.devices.iter().any(|d| d == &me) => {
                    Some((old.devices.clone(), old.revoked.iter().filter(|g| **g != me).cloned().collect::<Vec<_>>()))
                }
                Some(_) => None,
                None => Some((vec![me.clone()], Vec::new())),
            };
            if let Some((kept, revoked)) = seat {
                let base = match stored_phrase_recovery(store, &own) {
                    Some(recovery) => {
                        sign_upgrade(&mut r, master, &recovery, device, &kept);
                        hollow_log!("[HOLLOW-ROSTER] The phrase 0.11 stored signed this identity's first recovery");
                        r.base()
                    }
                    None => {
                        r.add_legacy(roster::sign_legacy(master, &me));
                        roster::LEGACY_BASE.to_string()
                    }
                };
                for gone in &revoked {
                    r.add_removal(roster::sign_removal(device, &own, &base, gone, &[]));
                }
                if old.is_some() {
                    hollow_log!("[HOLLOW-ROSTER] Claimed this device's seat from the 0.11 list");
                }
            }
            r
        }
    };
    if !roster.has_consent(&me) {
        roster.add_consent(roster::sign_consent(device, &own));
    }
    let mut state = fold(store, &roster);
    if !state.is_member(&me) && !state.removed.contains_key(&me) && !state.pending.contains(&me) {
        roster.add_pending(roster::sign_pending(master, &roster.base(), &me));
        stamp_pending(store, &roster);
        state = fold(store, &roster);
        hollow_log!("[HOLLOW-ROSTER] This device is not one of the identity's: asking to join");
    }
    let roster = roster.reverified();
    let _ = save(store, &roster, &state, &own, &me);
    (roster, state)
}

/// Our roster as a phrase restore finds it (PHRASE_RESTORE_DESIGN 1.2 step 7): the
/// stored one merged with a bootstrap of `master` no start has imported yet. `None`
/// when neither is here: a fresh install.
pub(crate) fn held_for_restore(store: &MessageStore, master: &str, db_path: &str) -> Option<Roster> {
    let stored = load(store, master);
    let boot = bootstrap_path(db_path)
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|j| serde_json::from_str::<Roster>(&j).ok())
        .map(|r| r.verified(now_ms()))
        .filter(|r| r.master == master);
    match (stored, boot) {
        (Some(s), Some(b)) => Some(s.merged(&b).reverified()),
        (s, b) => s.or(b.map(|b| b.reverified())),
    }
}

/// Store `held` before a phrase restore signs into it, so what it signs is dated past
/// the bootstrap's statements too; the bootstrap is consumed.
pub(crate) fn keep_held_for_restore(store: &MessageStore, held: &Roster, device: &str, db_path: &str) -> Result<(), String> {
    let state = fold(store, held);
    save(store, held, &state, &held.master, device)?;
    if let Some(path) = bootstrap_path(db_path) {
        let _ = std::fs::remove_file(path);
    }
    Ok(())
}

/// The upgrade, signed by the phrase 0.11 stored: the same recovery on every device of
/// the identity, an admission for each device the 0.11 list kept and this one, and this
/// device's consent first so that what it signs next has standing. Never the master id:
/// anyone holding the master key could consent as it (G1).
fn sign_upgrade(r: &mut Roster, master: &NativeKeypair, recovery: &NativeKeypair, device: &NativeKeypair, kept: &[String]) {
    let me = device.peer_id();
    let own = master.peer_id();
    r.add_consent(roster::sign_consent(device, &own));
    let r_pub = roster::r_pub_of(recovery);
    let _ = r.add_phrase_statement(&r_pub, Some(roster::sign_upgrade_recovery(master, recovery)), None);
    let devices: BTreeSet<&String> = kept.iter().chain(std::iter::once(&me)).filter(|d| **d != own).collect();
    for d in devices {
        let _ = r.add_phrase_statement(&r_pub, None, Some(roster::sign_upgrade_admit(master, recovery, d)));
    }
}

/// Where 0.11 kept the recovery phrase. It stays until the person confirms it on this
/// device or types the phrase here: a key being pinned never erases it.
pub(crate) const STORED_PHRASE: &str = "recovery_mnemonic";

/// The recovery key of the phrase an identity from before 0.12 stored, when that
/// phrase is still here and belongs to `master`.
fn stored_phrase_recovery(store: &MessageStore, master: &str) -> Option<NativeKeypair> {
    let phrase = zeroize::Zeroizing::new(store.load_setting(STORED_PHRASE).ok().flatten()?);
    crate::identity::recovery::recovery_key_for(master, &phrase).ok().map(|(_, recovery)| recovery)
}

fn stored_phrase_key(store: &MessageStore, master: &str) -> Option<String> {
    stored_phrase_recovery(store, master).map(|r| roster::r_pub_of(&r))
}

/// Whether `recovery` already roots our roster. A roster start-up has not built yet is
/// built first, so a confirmation never races the upgrade.
pub(crate) fn rooted_by(
    master: &NativeKeypair,
    device: &NativeKeypair,
    recovery: &NativeKeypair,
    db_path: &str,
    db_passphrase: &str,
) -> Result<bool, String> {
    let store = MessageStore::lease(db_path, db_passphrase)?;
    let roster = match load_strict(&store, &master.peer_id())? {
        Some(r) => r,
        None => ensure_own(&store, master, device, db_path).0,
    };
    Ok(!roster.recoveries.is_empty() && roster.r_pub == roster::r_pub_of(recovery))
}

/// What a roster for our own master may teach us. While the phrase an identity from
/// before 0.12 kept is stored here, a recovery key it does not derive is a master-key
/// holder's, so its statements are dropped and the real phrase is never locked out.
fn heard_for_own(store: &MessageStore, master: &str, incoming: &Roster) -> Roster {
    let mut heard = incoming.clone();
    if !heard.r_pub.is_empty() && stored_phrase_key(store, master).is_some_and(|key| key != heard.r_pub) {
        hollow_log!("[HOLLOW-SECURITY] Dropped a recovery key our own stored phrase does not derive");
        heard.r_pub.clear();
        heard.recoveries.clear();
        heard.phrase_admits.clear();
    }
    heard
}

/// Our own roster and its fold, as stored.
pub(crate) fn own(master: &str, db_path: &str, db_passphrase: &str) -> Option<(Roster, RosterState)> {
    let store = MessageStore::lease(db_path, db_passphrase).ok()?;
    let roster = load(&store, master)?;
    let state = fold(&store, &roster);
    Some((roster, state))
}

/// Our own roster as every carrier sends it. `None` only when the database is
/// unavailable; the carrier then goes without one.
pub(crate) fn own_roster(master: &str, db_path: &str, db_passphrase: &str) -> Option<Roster> {
    own(master, db_path, db_passphrase).map(|(r, _)| r)
}

/// Roster bytes a join box carries whole; past it only the placing subset.
const JOIN_ROSTER_WHOLE_BYTES: usize = 16 * 1024;

/// The roster a join box carries (DEVICE_PROOF_DESIGN 8.7, R31-7): the whole one while it
/// fits, so members learn every device of ours (our siblings' joins rely on it), else only
/// what makes this device counted. `None` when nothing counts it yet; a member then asks
/// for the rest (`roster_needed`) or hears our room notice.
pub(crate) fn join_roster(master: &str, device: &str, db_path: &str, db_passphrase: &str) -> Option<Roster> {
    let roster = own_roster(master, db_path, db_passphrase)?;
    let whole = serde_json::to_vec(&roster).is_ok_and(|v| v.len() <= JOIN_ROSTER_WHOLE_BYTES);
    if whole {
        return Some(roster);
    }
    roster.placing_subset(device)
}

/// The room only holders of our master key can name. Every device of the identity
/// joins it, a waiting or removed one too: an identity with no contacts and no
/// servers shares no other room with a restored backup, and its answer was lost.
pub(crate) fn own_room(local_master: &str) -> String {
    super::dm_room::dm_room_code(local_master, local_master)
}

/// Own-room hand-offs to devices our roster does not count, per minute of this node:
/// any master-key holder can mint device ids and join our own room, each arrival
/// drawing our whole roster.
pub(crate) const HAND_OFF_BUDGET: usize = 8;
const HAND_OFF_WINDOW: std::time::Duration = std::time::Duration::from_secs(60);
/// A device told our roster is told again only once the roster moves, our relay
/// session is lost, or this much later (its notice may have died with its socket).
const HAND_OFF_AGAIN: std::time::Duration = std::time::Duration::from_secs(600);

/// One node's own-room hand-offs. `told` holds at most BUDGET per WINDOW over AGAIN
/// entries: each is admitted by the budget and pruned once AGAIN has passed.
#[derive(Default)]
struct HandOffs {
    spent: std::collections::VecDeque<std::time::Instant>,
    told: std::collections::HashMap<String, (u64, std::time::Instant)>,
}

/// Per local device id (harness nodes share the process).
fn hand_offs() -> std::sync::MutexGuard<'static, std::collections::HashMap<String, HandOffs>> {
    static BOOK: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<String, HandOffs>>> = std::sync::OnceLock::new();
    BOOK.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner())
}

/// Whether we may hand `peer` our roster at `revision` now; a yes is charged.
fn may_hand_off(local_device: &str, peer: &str, revision: u64, now: std::time::Instant) -> bool {
    let mut book = hand_offs();
    let h = book.entry(local_device.to_string()).or_default();
    h.told.retain(|_, (_, at)| now.duration_since(*at) < HAND_OFF_AGAIN);
    if h.told.get(peer).is_some_and(|(rev, _)| *rev == revision) {
        return false;
    }
    h.spent.retain(|t| now.duration_since(*t) < HAND_OFF_WINDOW);
    if h.spent.len() >= HAND_OFF_BUDGET {
        return false;
    }
    h.spent.push_back(now);
    h.told.insert(peer.to_string(), (revision, now));
    true
}

/// Our relay session was lost: every device we told may have missed it.
pub(crate) fn on_session_lost(local_device: &str) {
    if let Some(h) = hand_offs().get_mut(local_device) {
        h.told.clear();
    }
}

/// Forget every node's hand-offs.
#[cfg(test)]
pub(crate) fn clear_hand_offs_for_test() {
    hand_offs().clear();
}

/// Another identity's device, or its single-device master id.
fn placed_elsewhere(peer: &str, local_master: &str) -> bool {
    let theirs = super::resolver::resolve(peer);
    (theirs != peer && theirs != local_master) || super::resolver::holds_roster_of(peer)
}

/// `peer` just appeared to us in `room`: if our own roster removed it, or it is in our
/// own room and our roster does not count it (a recovery left it out, it waits to join,
/// or it is newer than what we hold), hand it that roster there. The notice of a removal
/// or a recovery is lost when the device was away, left before we saw it in a room, or
/// went into our inbox just as the relay took it away, and the mailbox replays only to
/// members. Only holders of our master key can name our own room, and a device we place
/// with another identity, or another identity removed, hears nothing there; one our
/// roster does not count is told within [`may_hand_off`]'s bound.
pub(crate) fn tell_removed_device_in_room(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_master: &str,
    local_device: &str,
    peer: &str,
    room: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    let in_own_room = room == own_room(local_master);
    if peer == local_device || super::resolver::is_bare_master(peer) || !(in_own_room || super::resolver::is_revoked(peer)) {
        return;
    }
    // Not removed anywhere: only the own-room branch can send, judged before the store.
    if !super::resolver::is_revoked(peer)
        && (super::resolver::is_device_of(peer, local_master)
            || placed_elsewhere(peer, local_master)
            || !may_hand_off(local_device, peer, revision(local_master), std::time::Instant::now()))
    {
        return;
    }
    let Some((roster, state)) = own(local_master, db_path, db_passphrase) else { return };
    // Another identity's removal is its own to tell.
    let left_out = in_own_room && !state.is_member(peer) && !super::resolver::is_revoked(peer);
    if !state.removed.contains_key(peer) && !left_out {
        return;
    }
    hollow_log!("[HOLLOW-ROSTER] Device {peer} our roster does not count appeared in {room}: handing it our roster");
    super::crypto_handler::send_message_to_peer_in_room(
        ws_cmd_tx, room, peer, super::types::HavenMessage::RosterNotice { roster },
    );
}

/// Apply a change to our own roster, persist it, and return the result. `None` when
/// the database is unavailable or `change` refuses.
fn change_own(
    master: &NativeKeypair,
    device: &NativeKeypair,
    db_path: &str,
    db_passphrase: &str,
    change: impl FnOnce(&mut Roster, &RosterState) -> Result<(), String>,
) -> Result<(Roster, RosterState), String> {
    let store = MessageStore::lease(db_path, db_passphrase)?;
    let own = master.peer_id();
    let mut roster = load(&store, &own).unwrap_or_else(|| Roster::new(&own));
    let before = fold(&store, &roster);
    change(&mut roster, &before)?;
    let roster = roster.reverified();
    let state = fold(&store, &roster);
    save(&store, &roster, &state, &own, &device.peer_id())?;
    Ok((roster, state))
}

/// This device vouches for `target` (linking, or approving a pending join).
pub(crate) fn vouch(
    master: &NativeKeypair,
    device: &NativeKeypair,
    target: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Result<(Roster, RosterState), String> {
    change_own(master, device, db_path, db_passphrase, |r, s| {
        if !s.is_member(&device.peer_id()) {
            return Err("Only a device that belongs to your identity can add one.".into());
        }
        r.add_vouch(roster::sign_vouch(device, &r.master.clone(), &s.base, target));
        Ok(())
    })
}

/// How long a first sight of our own statement outlives the statement (8.5, LOW).
const SEEN_KEEP_MS: i64 = 30 * 24 * 60 * 60 * 1000;
/// First-sight rows kept per identity, the longest dropped going first.
const SEEN_CAP: usize = 4096;

/// First-sight keys of `roster`'s removals and vouches and of the devices `state` counts.
fn statement_keys(roster: &Roster, state: &RosterState) -> Vec<String> {
    roster
        .removals
        .iter()
        .map(roster::removal_seen_key)
        .chain(roster.vouches.iter().map(roster::vouch_seen_key))
        .chain(state.members.iter().map(|d| roster::device_seen_key(d)))
        .collect()
}

/// Record when this node first saw each removal and vouch of our own roster, and each
/// device it counts.
fn note_statements(store: &MessageStore, roster: &Roster, state: &RosterState) {
    if let Err(e) = store.note_roster_statements(&roster.master, &statement_keys(roster, state), now_ms(), SEEN_KEEP_MS, SEEN_CAP) {
        crate::hollow_log!("[ROSTER] first sights not noted: {e}");
    }
}

/// On a database from before first sights, date at 0 what our roster held before the
/// first save after the upgrade, never what that save brings (a push fetch may save first).
fn date_held_before_upgrade(store: &MessageStore, local_master: &str) -> Result<(), String> {
    if !store.roster_statements_marked()? {
        return Ok(());
    }
    let held = load(store, local_master).map(|held| statement_keys(&held, &fold(store, &held))).unwrap_or_default();
    store.seed_roster_statements_once(local_master, &held).map(|_| ())
}

/// The other devices a phrase recovery keeps unless the person unticks them (8.6):
/// those this node counted strictly before `t_ms`, when the person may no longer have
/// had the dropped ones. A fresh install counted nothing before, so it keeps none.
pub(crate) fn recovery_kept_by_default(store: &MessageStore, master: &str, state: &RosterState, me: &str, t_ms: i64) -> Vec<String> {
    state
        .members
        .iter()
        .filter(|d| d.as_str() != me && seen_before(store, master, &roster::device_seen_key(d), t_ms))
        .cloned()
        .collect()
}

fn recovery_lost_since_key(base: &str) -> String {
    format!("recovery_lost_since:{base}")
}

/// Remember, for the base a phrase recovery made, when the person last had the devices
/// it dropped: the settling of their servers reads it (track C).
pub(crate) fn note_recovery_lost_since(store: &MessageStore, base: &str, t_ms: i64) -> Result<(), String> {
    store.save_setting(&recovery_lost_since_key(base), &t_ms.max(0).to_string())
}

/// [`note_recovery_lost_since`] for `base`, if a recovery recorded one.
#[allow(dead_code)] // read by the settling, track C (DEVICE_PROOF_DESIGN 8.1)
pub(crate) fn recovery_lost_since(store: &MessageStore, base: &str) -> Option<i64> {
    store.load_setting(&recovery_lost_since_key(base)).ok().flatten().and_then(|v| v.parse().ok())
}

fn recovery_cut_off_key(base: &str) -> String {
    format!("recovery_cut_off:{base}")
}

/// The most devices one base's record names: only the phrase holder makes bases, and a
/// base cuts off at most the consents a roster keeps, so this is room, not a limit. Past
/// it the newest cuts are kept, and a device left out still reads as maybe cut off.
const MAX_CUT_OFF: usize = 512;

/// Which devices the recovery that made a base cut off, as this device knows it
/// (HOL-SEC-229): device -> when it was cut off, and `unknown_at`, the newest recovery
/// that cut any device: the master key signs a join ask for any key, and this device
/// cannot tell an old device it never held from a new one, so every other asker in that
/// base may be one of the old ones. Local to this device, never sent.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub(crate) struct CutOff {
    #[serde(default)]
    devices: std::collections::BTreeMap<String, i64>,
    #[serde(default)]
    unknown_at: Option<i64>,
}

impl CutOff {
    fn is_empty(&self) -> bool {
        self.devices.is_empty() && self.unknown_at.is_none()
    }

    /// `Some((when, one of ours))` for `device`.
    fn of(&self, device: &str) -> Option<(i64, bool)> {
        self.devices.get(device).map(|at| (*at, true)).or_else(|| self.unknown_at.map(|at| (at, false)))
    }
}

/// `base`'s record; an unreadable one is an error, never an empty record.
fn read_cut_off(store: &MessageStore, base: &str) -> Result<CutOff, String> {
    match store.load_setting(&recovery_cut_off_key(base))? {
        Some(v) => serde_json::from_str(&v).map_err(|e| format!("recovery cut-off record: {e}")),
        None => Ok(CutOff::default()),
    }
}

/// What a move from `prev` to a new base signed at `at` cut off: `prev`'s members the new
/// base does not count, and whatever `prev`'s own base cut off that it does not take back.
/// A move that cuts a member marks every other asker as maybe one of the old ones; one
/// that cuts none keeps the earlier mark, since the master key it guards against is
/// still out there.
fn cut_by(store: &MessageStore, prev: &RosterState, at: i64, kept: impl Fn(&str) -> bool) -> Result<CutOff, String> {
    let earlier = read_cut_off(store, &prev.base)?;
    let mut devices: std::collections::BTreeMap<String, i64> =
        earlier.devices.into_iter().filter(|(d, _)| !kept(d)).collect();
    let mut cut_here = false;
    for d in prev.members.iter().filter(|d| !kept(d)) {
        devices.entry(d.clone()).or_insert(at);
        cut_here = true;
    }
    Ok(CutOff { devices, unknown_at: if cut_here { Some(at) } else { earlier.unknown_at } })
}

/// Add `cut` to what `base`'s record holds: a device's earliest cut and the newest mark
/// win, the newest cuts first while there is room.
fn note_cut_off(store: &MessageStore, base: &str, cut: CutOff) -> Result<(), String> {
    let mut held = read_cut_off(store, base)?;
    let mut devices: Vec<(String, i64)> = cut.devices.into_iter().collect();
    devices.sort_by_key(|(_, at)| std::cmp::Reverse(*at));
    let mut left_out = None;
    for (d, at) in devices {
        if held.devices.len() >= MAX_CUT_OFF && !held.devices.contains_key(&d) {
            left_out = left_out.max(Some(at));
            continue;
        }
        let e = held.devices.entry(d).or_insert(at);
        *e = (*e).min(at);
    }
    held.unknown_at = held.unknown_at.max(cut.unknown_at).max(left_out);
    if held.is_empty() {
        return Ok(());
    }
    store.save_setting(&recovery_cut_off_key(base), &serde_json::to_string(&held).map_err(|e| e.to_string())?)
}

/// `device`, waiting in our own `state`, as a recovery cut it off: when, and whether this
/// device knows it was one of ours (else it may be). An unreadable record reads as maybe.
pub(crate) fn cut_off_by_recovery(store: &MessageStore, roster: &Roster, state: &RosterState, device: &str) -> Option<(i64, bool)> {
    if !state.pending.contains(device) {
        return None;
    }
    match read_cut_off(store, &state.base) {
        Ok(cut) => cut.of(device),
        Err(_) => Some((roster.base_at().unwrap_or(0), false)),
    }
}

/// Whether the person is asked about `device`, waiting in our own `state`: a device a
/// recovery cut off, or may have, gets no pop-up where waiting cannot let it in
/// (HOL-SEC-229), only its row in the device list; where it can, the pop-up warns and
/// never offers Approve. An unreadable record asks nothing.
fn asks_the_person(store: &MessageStore, state: &RosterState, device: &str) -> bool {
    !state.no_wait || read_cut_off(store, &state.base).is_ok_and(|cut| cut.of(device).is_none())
}

/// How a device leaves (DEVICE_PROOF_DESIGN 8.1): retiring keeps what it did, lost or
/// stolen keeps only what this device saw from it before `t_ms`, the earliest moment
/// the person may no longer have had it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RemoveMode {
    Retire,
    Lost { t_ms: i64 },
}

impl RemoveMode {
    /// Retiring without a time, else lost or stolen since `t_ms` (never before 0).
    pub(crate) fn from_lost_since(lost_since_ms: Option<i64>) -> Self {
        match lost_since_ms {
            Some(t_ms) => RemoveMode::Lost { t_ms: t_ms.max(0) },
            None => RemoveMode::Retire,
        }
    }
}

/// What removing a device takes with it (8.6): only devices that the target alone
/// places in our roster; a device another device also vouches is never touched.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct RemovalPlan {
    /// Linked from the target after T (lost or stolen): removed with it, no choice.
    pub forced: Vec<String>,
    /// The others: removed too when the person leaves "Remove them too" on.
    pub optional: Vec<String>,
    /// Where that toggle starts: on for lost or stolen, off for retiring.
    pub optional_on: bool,
}

/// Whether this node first saw the statement under `key` strictly before `t_ms`.
fn seen_before(store: &MessageStore, master: &str, key: &str, t_ms: i64) -> bool {
    store.roster_statement_first_seen(master, key).is_some_and(|at| at < t_ms)
}

/// [`RemovalPlan`] for removing `target` from `roster` (ours, verified) from device `me`.
/// A dependent counts as linked after T unless a vouch placing it, by the target or by
/// another dependent, was here before T.
pub(crate) fn removal_plan(store: &MessageStore, roster: &Roster, me: &str, target: &str, mode: RemoveMode) -> RemovalPlan {
    let dropped = std::collections::BTreeSet::from([target.to_string()]);
    let deps: std::collections::BTreeSet<String> =
        roster.dependents_of(&dropped).into_iter().filter(|d| d != me).collect();
    let mut plan = RemovalPlan { optional_on: matches!(mode, RemoveMode::Lost { .. }), ..Default::default() };
    for d in &deps {
        let after_t = match mode {
            RemoveMode::Retire => false,
            RemoveMode::Lost { t_ms } => !roster.vouches.iter().any(|v| {
                &v.device == d
                    && (v.by == target || deps.contains(&v.by))
                    && seen_before(store, &roster.master, &roster::vouch_seen_key(v), t_ms)
            }),
        };
        if after_t { plan.forced.push(d.clone()) } else { plan.optional.push(d.clone()) }
    }
    plan
}

/// Adds `new`, this device's removals, to `r`, then re-signs as this device's own, with
/// the same keep, what keeps every device the walk removed before still removed (8.5):
/// each counted removal a dropped device signed, then, until nothing more comes back, a
/// counted removal of each device that would (a dropped device's removal of an earlier
/// remover moves that remover's death before its turn). `lapses` names the removals by a
/// dropped device that are let go: lost or stolen, those first seen from T on.
fn add_removals(r: &mut Roster, device: &NativeKeypair, new: Vec<Removal>, lapses: &dyn Fn(&Removal) -> bool) {
    let before = r.authority();
    let (me, master) = (device.peer_id(), r.master.clone());
    let dropped: BTreeSet<String> = new.iter().map(|x| x.device.clone()).collect();
    let lets_go = |x: &Removal| dropped.contains(&x.by) && lapses(x);
    let re_sign = |r: &mut Roster, x: &Removal| {
        r.add_removal(roster::sign_removal(device, &master, &x.base, &x.device, &x.keep_vouched));
    };
    for x in new {
        r.add_removal(x);
    }
    for x in before.counted_removals.iter().filter(|x| dropped.contains(&x.by)) {
        if !dropped.contains(&x.device) && x.device != me && !lets_go(x) {
            re_sign(r, x);
        }
    }
    let mut kept_out: BTreeSet<&str> = BTreeSet::new();
    loop {
        let after = r.authority();
        let mut changed = false;
        for (d, first_by) in &before.removed {
            if after.removed.contains_key(d) || dropped.contains(d) || *d == me || !kept_out.insert(d.as_str()) {
                continue;
            }
            let of_d = || before.counted_removals.iter().filter(|x| &x.device == d && !lets_go(x));
            if let Some(x) = of_d().find(|x| &x.by == first_by).or_else(|| of_d().next()) {
                re_sign(r, x);
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
}

/// Whether `target` is out of server authority once `device` removes it: not when a
/// device closer to the phrase removed `device` first (the walk, section 4).
pub(crate) fn removal_takes_effect(roster: &Roster, device: &NativeKeypair, target: &str) -> bool {
    let mut after = roster.clone();
    after.add_removal(roster::sign_removal(device, &roster.master, &roster.base(), target, &[]));
    !after.reverified().authority().counts(target)
}

/// This device removes `target`, re-signing what the target removed (8.5) and taking
/// with it the devices only the target placed: those linked after T always, the others
/// when `with_dependents`. Returns every device removed, the target first.
pub(crate) fn remove(
    master: &NativeKeypair,
    device: &NativeKeypair,
    target: &str,
    mode: RemoveMode,
    with_dependents: bool,
    db_path: &str,
    db_passphrase: &str,
) -> Result<(Roster, RosterState, Vec<String>), String> {
    let store = MessageStore::lease(db_path, db_passphrase)?;
    let mut gone: Vec<String> = Vec::new();
    let (roster, state) = change_own(master, device, db_path, db_passphrase, |r, s| {
        let me = device.peer_id();
        if target == me {
            return Err("You can't remove the device you are using.".into());
        }
        if !s.is_member(&me) {
            return Err("Only a device that belongs to your identity can remove one.".into());
        }
        if !s.is_member(target) && !s.pending.contains(target) {
            return Err("That device is not one of yours.".into());
        }
        let plan = removal_plan(&store, r, &me, target, mode);
        gone.push(target.to_string());
        gone.extend(plan.forced);
        if with_dependents {
            gone.extend(plan.optional);
        }
        let new = gone
            .iter()
            .map(|d| {
                let keep: Vec<String> = r.vouched_members_of(d, s).into_iter().filter(|k| !gone.contains(k)).collect();
                roster::sign_removal(device, &r.master, &s.base, d, &keep)
            })
            .collect();
        let master_id = r.master.clone();
        let lapses = |x: &Removal| match mode {
            RemoveMode::Retire => false,
            RemoveMode::Lost { t_ms } => !seen_before(&store, &master_id, &roster::removal_seen_key(x), t_ms),
        };
        add_removals(r, device, new, &lapses);
        Ok(())
    })?;
    Ok((roster, state, gone))
}

/// This device removes every other member and every pending join.
pub(crate) fn remove_all_others(
    master: &NativeKeypair,
    device: &NativeKeypair,
    db_path: &str,
    db_passphrase: &str,
) -> Result<(Roster, RosterState, Vec<String>), String> {
    let mut gone = Vec::new();
    let (roster, state) = change_own(master, device, db_path, db_passphrase, |r, s| {
        let me = device.peer_id();
        if !s.is_member(&me) {
            return Err("Only a device that belongs to your identity can remove one.".into());
        }
        gone.extend(s.members.iter().chain(s.pending.iter()).filter(|d| **d != me).cloned());
        if gone.is_empty() {
            return Err("This is already your only device.".into());
        }
        let new = gone.iter().map(|d| roster::sign_removal(device, &r.master, &s.base, d, std::slice::from_ref(&me))).collect();
        add_removals(r, device, new, &|_| false);
        Ok(())
    })?;
    Ok((roster, state, gone))
}

/// This device removes itself (destruction scope (b)). Not persisted: the database is
/// about to be destroyed.
pub(crate) fn remove_self(
    master: &NativeKeypair,
    device: &NativeKeypair,
    db_path: &str,
    db_passphrase: &str,
) -> Option<Roster> {
    let store = MessageStore::lease(db_path, db_passphrase).ok()?;
    let own = master.peer_id();
    let mut roster = load(&store, &own)?;
    let state = fold(&store, &roster);
    let me = device.peer_id();
    let keep = roster.vouched_members_of(&me, &state);
    roster.add_removal(roster::sign_removal(device, &own, &state.base, &me, &keep));
    Some(roster.reverified())
}

/// When a phrase statement signed now is dated: our clock, or just past the newest
/// phrase statement we hold when the clock reads earlier, so the phrase keeps the last
/// word on a device whose clock stepped back.
fn phrase_time(r: &Roster) -> i64 {
    let newest = r
        .recoveries
        .iter()
        .map(|x| x.at_ms)
        .chain(r.phrase_admits.iter().map(|p| p.at_ms))
        .max();
    newest.map_or_else(now_ms, |at| now_ms().max(at.saturating_add(1)))
}

/// The phrase starts a new base keeping `keep` and this device. `no_wait` decides
/// whether a restored backup may still join the new base by seven quiet days.
/// `lost_since_ms`, when the person said when they last had the dropped devices, is
/// stored for the new base before the roster is: a crash between never leaves a
/// recovery whose T is unknown.
#[allow(clippy::too_many_arguments)]
pub(crate) fn recover(
    master: &NativeKeypair,
    recovery: &NativeKeypair,
    device: &NativeKeypair,
    keep: &[String],
    no_wait: bool,
    lost_since_ms: Option<i64>,
    db_path: &str,
    db_passphrase: &str,
) -> Result<(Roster, RosterState), String> {
    let mut at = 0;
    let (roster, state) = change_own(master, device, db_path, db_passphrase, |r, s| {
        let mut keep: Vec<String> = keep.to_vec();
        keep.push(device.peer_id());
        keep.sort();
        keep.dedup();
        if keep.len() > roster::MAX_KEEP {
            return Err(format!("A recovery can keep at most {} devices.", roster::MAX_KEEP));
        }
        if !r.has_consent(&device.peer_id()) {
            r.add_consent(roster::sign_consent(device, &r.master.clone()));
        }
        at = phrase_time(r);
        let rec = roster::sign_recovery(master, recovery, at, &keep, no_wait);
        let base = roster::base_id(&r.master, &roster::r_pub_of(recovery), &rec);
        let store = MessageStore::lease(db_path, db_passphrase)?;
        if let Some(t) = lost_since_ms {
            note_recovery_lost_since(&store, &base, t)?;
        }
        // A recovery dropping devices as lost cut off whatever its held roster missed
        // too (an empty install's, a stale one), and any key the master signs an ask for.
        let mut cut = cut_by(&store, s, at, |d| keep.iter().any(|k| k == d))?;
        if lost_since_ms.is_some() {
            cut.unknown_at = Some(at);
        }
        note_cut_off(&store, &base, cut)?;
        r.add_phrase_statement(&roster::r_pub_of(recovery), Some(rec), None)
    })?;
    note_own_phrase(db_path, db_passphrase, OwnPhrase { kind: PhraseKind::Recover, at_ms: at, base: state.base.clone(), no_wait });
    Ok((roster, state))
}

/// The phrase admits this device into whatever base is current.
pub(crate) fn admit_by_phrase(
    master: &NativeKeypair,
    recovery: &NativeKeypair,
    device: &NativeKeypair,
    db_path: &str,
    db_passphrase: &str,
) -> Result<(Roster, RosterState), String> {
    let mut at = 0;
    let (roster, state) = change_own(master, device, db_path, db_passphrase, |r, _| {
        if !r.has_consent(&device.peer_id()) {
            r.add_consent(roster::sign_consent(device, &r.master.clone()));
        }
        at = phrase_time(r);
        let pa = roster::sign_phrase_admit(master, recovery, at, &device.peer_id());
        r.add_phrase_statement(&roster::r_pub_of(recovery), None, Some(pa))
    })?;
    note_own_phrase(db_path, db_passphrase, OwnPhrase { kind: PhraseKind::Admit, at_ms: at, base: state.base.clone(), no_wait: state.no_wait });
    Ok((roster, state))
}

/// This device's newest phrase statement about itself, kept here: a base compacts
/// older statements away, so only this device can tell that a later base outdated
/// its admission or recovery (HOL-SEC-218). This device's own row, never in a copy.
pub(crate) const OWN_PHRASE: &str = "own_phrase_statement";

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum PhraseKind {
    Admit,
    Recover,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub(crate) struct OwnPhrase {
    pub(crate) kind: PhraseKind,
    pub(crate) at_ms: i64,
    /// The base current once it was signed (a recovery's own).
    pub(crate) base: String,
    /// A recovery's "backups need approval": a later base must never quietly undo it.
    #[serde(default)]
    pub(crate) no_wait: bool,
}

fn note_own_phrase(db_path: &str, db_passphrase: &str, own: OwnPhrase) {
    let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return };
    if let Ok(json) = serde_json::to_string(&own) {
        let _ = store.save_setting(OWN_PHRASE, &json);
    }
}

/// This device's own phrase statement that the current base outdated: this device is
/// neither a member nor removed, and the base's recovery is dated at or after it, within
/// the skew a clock may have. A base dated any later is a change made elsewhere on
/// purpose, which [`dropped_by_recovery_at`] reports: typing the phrase again here would
/// sign a recovery dropping the device that made it.
pub(crate) fn own_phrase_outdated(store: &MessageStore, roster: &Roster, state: &RosterState, me: &str) -> Option<OwnPhrase> {
    if state.is_member(me) || state.removed.contains_key(me) {
        return None;
    }
    let own: OwnPhrase = serde_json::from_str(&store.load_setting(OWN_PHRASE).ok()??).ok()?;
    let after = roster.base_at()?.checked_sub(own.at_ms)?;
    (0..=roster::MAX_FUTURE_SKEW_MS).contains(&after).then_some(own)
}

/// When the recovery that left this device out was signed: this device counted for the
/// identity once (its own first sight of itself), and now is neither a member, nor
/// removed, nor outdated by its own phrase statement.
pub(crate) fn dropped_by_recovery_at(store: &MessageStore, roster: &Roster, state: &RosterState, me: &str) -> Option<i64> {
    if state.is_member(me) || state.removed.contains_key(me) || own_phrase_outdated(store, roster, state, me).is_some() {
        return None;
    }
    seen_before(store, &roster.master, &roster::device_seen_key(me), i64::MAX).then(|| roster.base_at()).flatten()
}

/// When this device learned it was removed and who removed it, if it was.
pub(crate) fn own_removal(store: &MessageStore) -> Option<(String, i64)> {
    let by = store.load_setting(OWN_REMOVED_BY).ok().flatten().filter(|b| !b.is_empty())?;
    let at = store.load_setting(OWN_REMOVED_AT).ok().flatten()?.parse::<i64>().ok()?;
    Some((by, at))
}

/// Mark (or clear) this device's own removal with nobody else revoking it. Tests only:
/// the harness resolver is process-global, so a real removal reaches every node.
#[cfg(test)]
pub(crate) fn note_own_removal_for_test(store: &MessageStore, by: Option<&str>) {
    note_own_removal(store, by);
}

fn note_own_removal(store: &MessageStore, by: Option<&str>) {
    match by {
        Some(by) => {
            if own_removal(store).is_none() {
                let _ = store.save_setting(OWN_REMOVED_BY, by);
                let _ = store.save_setting(OWN_REMOVED_AT, &now_ms().to_string());
            }
        }
        None => {
            let _ = store.save_setting(OWN_REMOVED_BY, "");
            let _ = store.save_setting(OWN_REMOVED_AT, "");
        }
    }
}

/// Tell the UI what our own roster says about this device at start.
pub(crate) async fn announce_own_state(
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_device: &str,
    state: &RosterState,
    db_path: &str,
    db_passphrase: &str,
) {
    Box::pin(announce_own_state_inner(event_tx, local_device, state, db_path, db_passphrase)).await
}

async fn announce_own_state_inner(
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_device: &str,
    state: &RosterState,
    db_path: &str,
    db_passphrase: &str,
) {
    let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return };
    match state.removed.get(local_device) {
        Some(by) => {
            note_own_removal(&store, Some(by));
            if let Some((by, at)) = own_removal(&store) {
                let _ = event_tx
                    .send(NetworkEvent::DeviceRemoved {
                        by,
                        wipe_at_ms: at.saturating_add(roster::REMOVAL_GRACE_MS),
                    })
                    .await;
            }
        }
        None => note_own_removal(&store, None),
    }
    let asking: Vec<String> =
        state.pending.iter().filter(|d| d.as_str() != local_device && asks_the_person(&store, state, d)).cloned().collect();
    drop(store);
    for device in asking {
        let _ = event_tx.send(NetworkEvent::PendingDeviceAsking { device_peer_id: device }).await;
    }
}

/// A device waiting to join tells whoever can start its seven days: its identity's own
/// mailbox (our other devices, online or not) and the devices of the contacts and
/// servers its database knows. A member has nothing to say.
pub(crate) fn announce_pending<'a>(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_master: &str,
    local_device: &str,
    server_ids: impl Iterator<Item = &'a String>,
    db_path: &str,
    db_passphrase: &str,
) {
    let Some((roster, state)) = own(local_master, db_path, db_passphrase) else { return };
    if !state.pending.contains(local_device) {
        return;
    }
    fan_out(ws_cmd_tx, local_master, roster, server_ids, db_path, db_passphrase);
    hollow_log!("[HOLLOW-ROSTER] Asked to join the identity (mailbox, contacts, servers)");
}

/// A new base left this device out while it was not a member: it asks again in that
/// base at once, not at its next start.
pub(crate) async fn ask_again<'a>(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    master: &NativeKeypair,
    device: &NativeKeypair,
    server_ids: impl Iterator<Item = &'a String>,
    db_path: &str,
    db_passphrase: &str,
) {
    let me = device.peer_id();
    let asked = change_own(master, device, db_path, db_passphrase, |r, s| {
        if s.is_member(&me) || s.removed.contains_key(&me) || s.pending.contains(&me) {
            return Err("settled".into());
        }
        r.add_pending(roster::sign_pending(master, &r.base(), &me));
        Ok(())
    });
    let Ok((roster, _)) = asked else { return };
    if let Ok(store) = MessageStore::lease(db_path, db_passphrase) {
        stamp_pending(&store, &roster);
    }
    hollow_log!("[HOLLOW-ROSTER] A new base left this device out: asking to join again");
    show_relay(ws_cmd_tx, &master.peer_id(), db_path, db_passphrase);
    fan_out(ws_cmd_tx, &master.peer_id(), roster, server_ids, db_path, db_passphrase);
    let _ = event_tx.send(NetworkEvent::DeviceListUpdated { master_peer_id: master.peer_id() }).await;
}

/// The phrase changed our roster: everyone hears it the way a pending device asks,
/// with no session needed, since a contact may still hold this device as removed and
/// refuse its sessions until the recovery reaches it.
pub(crate) fn announce_phrase_change<'a>(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_master: &str,
    server_ids: impl Iterator<Item = &'a String>,
    db_path: &str,
    db_passphrase: &str,
) {
    let Some(roster) = own_roster(local_master, db_path, db_passphrase) else { return };
    fan_out(ws_cmd_tx, local_master, roster, server_ids, db_path, db_passphrase);
}

fn fan_out<'a>(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_master: &str,
    roster: Roster,
    server_ids: impl Iterator<Item = &'a String>,
    db_path: &str,
    db_passphrase: &str,
) {
    let notice = super::types::HavenMessage::RosterNotice { roster };
    super::social::deposit_friend_request_to_inbox(ws_cmd_tx, local_master, &notice);
    let Ok(data) = serde_json::to_vec(&notice) else { return };
    // Live to every device of ours, a waiting or removed one too: the mailbox
    // replays only to members.
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom { room_code: own_room(local_master), data: data.clone() });
    // Each friend's whole DM room: we may know none of its devices yet, and a
    // single-device friend's device is its master id, which no link names.
    let friends = MessageStore::lease(db_path, db_passphrase)
        .and_then(|s| s.load_friends(Some("accepted")))
        .unwrap_or_default();
    // A blocked friend's room stays left (`social::holds_dm_room`).
    let dm_rooms = friends.into_iter().filter(|(peer, ..)| !super::blocklist::is_blocked(peer)).map(|(peer, ..)| {
        super::dm_room::dm_room_code(local_master, &super::resolver::resolve(&peer))
    });
    for room in dm_rooms {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom { room_code: room.clone() });
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom { room_code: room, data: data.clone() });
    }
    notice_into_server_rooms(ws_cmd_tx, &data, server_ids);
}

/// A `RosterNotice` (its frame bytes) into each server room, live only (DEVICE_PROOF_DESIGN
/// section 9): a socket the room hides still reaches its provers. A meeting's room is
/// no server's.
pub(crate) fn notice_into_server_rooms<'a>(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    data: &[u8],
    server_ids: impl Iterator<Item = &'a String>,
) {
    for sid in server_ids.filter(|s| !super::conference::is_conference_sid(s)) {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom { room_code: sid.clone(), data: data.to_vec() });
    }
}

// -- Ingest --

/// What an ingest changed, for the caller to act on.
#[derive(Default)]
pub(crate) struct Ingested {
    /// Our own roster changed, so re-announce it.
    pub our_devices_grew: bool,
    /// Were members, now removed: drop their Olm sessions and MLS leaves.
    pub newly_revoked: Vec<String>,
    /// Members this ingest admitted, for our own master: siblings to converge with.
    pub added: Vec<String>,
    /// Our own roster moved to a base that leaves this device out and not yet
    /// asking: the caller asks again ([`ask_again`]), as only it holds the keys.
    pub asks_again: bool,
    /// The held roster of this master changed.
    pub changed: bool,
}

/// Fold a roster someone delivered into ours for that master.
///
/// Every statement verifies on its own, so who delivered it binds nothing: a sender
/// becomes a master's device only by being a member of the merged roster. A roster for
/// a master we hold nothing about is kept only when its deliverer is one of its members.
///
/// Boxed: it is awaited inline in many event-loop arms, and its state would otherwise
/// grow every one of them (a worker stack overflow).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn ingest(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_master: &str,
    local_device: &str,
    sender: &str,
    incoming: Option<Roster>,
    db_path: &str,
    db_passphrase: &str,
) -> Ingested {
    Box::pin(ingest_inner(
        event_tx, ws_cmd_tx, local_master, local_device, sender, incoming, db_path, db_passphrase, Source::Delivered,
    ))
    .await
}

/// Whether a `RosterNotice` or `RosterSync` for `master` may be kept (R31-8): our own,
/// a master we already hold a roster for, one with a friend row of any state (keyed by
/// its master or by the device delivering it), or one `co_member` names. Anyone can mint
/// identities, so a first sight on any other terms is a book row a stranger chose.
pub(crate) fn notice_may_be_kept(
    store: &MessageStore,
    master: &str,
    sender: &str,
    local_master: &str,
    co_member: impl Fn(&str) -> bool,
) -> bool {
    sight(store, master, sender, local_master, co_member) != Sight::Stranger
}

/// On what terms a roster for `master` may be kept here.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Sight {
    /// Ours, held already, or a friend row of any state.
    Known,
    /// A first sight only a server we hold names: held for the relay's copy first.
    CoMember,
    Stranger,
}

fn sight(store: &MessageStore, master: &str, sender: &str, local_master: &str, co_member: impl Fn(&str) -> bool) -> Sight {
    let known = master == local_master
        || load(store, master).is_some()
        || store.load_device_list(master).ok().flatten().is_some()
        || store.get_friend_row(master).ok().flatten().is_some()
        // A friend added by nickname, keyed by its device until its roster lands: a first
        // sight needs the deliverer as a member, and that landing re-keys the row to the
        // master (`fold_in_store`), so the row admits one identity at most.
        || store.get_friend_row(sender).ok().flatten().is_some();
    if known {
        Sight::Known
    } else if co_member(master) {
        Sight::CoMember
    } else {
        Sight::Stranger
    }
}

/// Whether `state` names `master`: its owner, a member, or the author of an op it keeps
/// (DEVICE_PROOF_DESIGN section 9's authority set: retained, parked and held ops).
pub(crate) fn server_names_master(state: &crate::crdt::server_state::ServerState, master: &str) -> bool {
    state.current_owner().as_deref() == Some(master)
        || state.anchor_owner().as_deref() == Some(master)
        || state.members.contains_key(master)
        || state.has_op_author(master)
}

/// [`sight`] against our store, a co-member being a master some server we hold names.
fn named_here(
    master: &str,
    sender: &str,
    local_master: &str,
    server_states: &std::collections::HashMap<String, crate::crdt::server_state::ServerState>,
    db_path: &str,
    db_passphrase: &str,
) -> Sight {
    let co_member = |m: &str| server_states.values().any(|s| server_names_master(s, m));
    MessageStore::lease(db_path, db_passphrase)
        .map_or(Sight::Stranger, |store| sight(&store, master, sender, local_master, co_member))
}

/// The servers we hold that name `master`, where the relay is asked about it.
fn naming_servers(
    master: &str,
    server_states: &std::collections::HashMap<String, crate::crdt::server_state::ServerState>,
) -> Vec<String> {
    let mut out: Vec<String> =
        server_states.iter().filter(|(_, s)| server_names_master(s, master)).map(|(id, _)| id.clone()).collect();
    out.sort();
    out
}

/// A first sight a server names, on a relay that answers checks: held until the relay's
/// copy lands with it (MED-2), so a stale roster places nobody meanwhile. A held foreign
/// master is checked again in the background.
fn defer_for_relay(
    sight: Sight,
    roster: &Roster,
    sender: &str,
    rider: super::roster_check::Rider,
    server_states: &std::collections::HashMap<String, crate::crdt::server_state::ServerState>,
) -> Option<super::roster_check::Rider> {
    let servers = naming_servers(&roster.master, server_states);
    match sight {
        Sight::CoMember if super::roster_check::applies(&roster.master) => {
            // One that does not count its deliverer goes on to the ingest, which drops it.
            super::roster_check::stage(roster.clone(), sender, rider, &servers)
        }
        Sight::Known if !servers.is_empty() => {
            super::roster_check::background(&roster.master, &servers);
            Some(rider)
        }
        _ => Some(rider),
    }
}

/// [`ingest`] for a `RosterNotice` or `RosterSync`, kept only when [`named_here`].
#[allow(clippy::too_many_arguments)]
pub(crate) async fn ingest_notice(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_master: &str,
    local_device: &str,
    sender: &str,
    roster: Roster,
    server_states: &std::collections::HashMap<String, crate::crdt::server_state::ServerState>,
    db_path: &str,
    db_passphrase: &str,
) -> Ingested {
    let master = roster.master.clone();
    let sight = named_here(&master, sender, local_master, server_states, db_path, db_passphrase);
    if sight == Sight::Stranger {
        hollow_log!("[HOLLOW-SECURITY] Dropped a roster notice for {master} from {sender}: nothing here names it");
        return Ingested::default();
    }
    if defer_for_relay(sight, &roster, sender, super::roster_check::Rider::Nothing, server_states).is_none() {
        return Ingested::default();
    }
    ingest(event_tx, ws_cmd_tx, local_master, local_device, sender, Some(roster), db_path, db_passphrase).await
}

/// A roster a carrier with its own gate (a landed join ask) is about to ingest: held for
/// the relay's copy instead when it is a first sight only a server names (MED-2), its card
/// with it. `None` when held; else the card back, to land now.
pub(crate) fn held_for_relay(
    sender: &str,
    roster: &Roster,
    card: Option<super::join_stash::HeldCard>,
    local_master: &str,
    server_states: &std::collections::HashMap<String, crate::crdt::server_state::ServerState>,
    db_path: &str,
    db_passphrase: &str,
) -> Option<Option<super::join_stash::HeldCard>> {
    use super::roster_check::Rider;
    let sight = named_here(&roster.master, sender, local_master, server_states, db_path, db_passphrase);
    match defer_for_relay(sight, roster, sender, Rider::Card(card), server_states)? {
        Rider::Card(card) => Some(card),
        Rider::Nothing | Rider::Profile(_) => Some(None),
    }
}

/// Whether the roster a `ProfileCard` or `ProfileUpdate` carries may reach [`ingest`]:
/// none, or one [`named_here`] (HOL-SEC-193). A device consents to any identity its owner
/// mints, and an MLS leaf's certificate proves only that some group seated it (a
/// meeting's host seats any leaf), so neither names a master here. On `false` the caller
/// drops the card or profile it rode with; a first sight held for the relay's copy keeps
/// `replay()`'s frame (and its stamp) and hands it back once the roster lands. Sync and
/// borrowing: the swarm handler's debug frame sits within a few KB of a Windows worker's
/// 2 MB stack.
#[allow(clippy::too_many_arguments)]
pub(crate) fn admit_profile_roster(
    sender: &str,
    roster: Option<&Roster>,
    local_master: &str,
    server_states: &std::collections::HashMap<String, crate::crdt::server_state::ServerState>,
    db_path: &str,
    db_passphrase: &str,
    replay: impl FnOnce() -> super::types::HavenMessage,
    frame_ts: i64,
) -> bool {
    let Some(roster) = roster else { return true };
    let sight = named_here(&roster.master, sender, local_master, server_states, db_path, db_passphrase);
    if sight == Sight::Stranger {
        hollow_log!("[HOLLOW-SECURITY] Dropped a profile from {sender} carrying a roster for {}: nothing here names it", roster.master);
        return false;
    }
    let held = || super::roster_check::Rider::Profile(Box::new((replay(), frame_ts)));
    let rider = if sight == Sight::CoMember && super::roster_check::applies(&roster.master) { held() } else { super::roster_check::Rider::Nothing };
    defer_for_relay(sight, roster, sender, rider, server_states).is_some()
}

/// Whether we hold a roster for `master`.
pub(crate) fn holds(master: &str, db_path: &str, db_passphrase: &str) -> bool {
    MessageStore::lease(db_path, db_passphrase).is_ok_and(|store| load(&store, master).is_some())
}

/// `roster` without its recovery key and phrase statements: the relay's copy merged into
/// a roster we hold keyless (or a keyless first sight) never picks the key.
pub(crate) fn keyless(roster: &Roster) -> Roster {
    Roster { r_pub: String::new(), recoveries: Vec::new(), phrase_admits: Vec::new(), ..roster.clone() }
}

/// Removals a DM carried (F2): `rm` from `sender`, a member of `master` (the DM's
/// authenticated identity), judged exactly as any removal is once merged into the
/// roster we hold for `master`. Never our own roster and never a first sight.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn ingest_carried(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_master: &str,
    local_device: &str,
    sender: &str,
    master: &str,
    rm: &[Removal],
    db_path: &str,
    db_passphrase: &str,
) -> Ingested {
    let Some(incoming) = carried_roster(local_master, sender, master, rm) else { return Ingested::default() };
    Box::pin(ingest_inner(
        event_tx, ws_cmd_tx, local_master, local_device, sender, Some(incoming), db_path, db_passphrase, Source::Carried,
    ))
    .await
}

/// The relay's copy of `roster.master`'s statements merged into the roster we hold
/// (`Source::Relay`): a removal it shows counts as from any carrier, nothing else.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn ingest_relay(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_master: &str,
    local_device: &str,
    roster: Roster,
    db_path: &str,
    db_passphrase: &str,
) -> Ingested {
    if roster.master == local_master {
        return Ingested::default();
    }
    Box::pin(ingest_inner(event_tx, ws_cmd_tx, local_master, local_device, "", Some(roster), db_path, db_passphrase, Source::Relay))
        .await
}

/// [`ingest_carried`] for the push fetch: the store half only, and the running app is
/// told to re-read `master` (`roster_dirty`).
pub(crate) fn ingest_carried_stored(
    db_path: &str,
    db_passphrase: &str,
    local_master: &str,
    local_device: &str,
    sender: &str,
    master: &str,
    rm: &[Removal],
) -> bool {
    let Some(incoming) = carried_roster(local_master, sender, master, rm) else { return false };
    stored_ingest(db_path, db_passphrase, local_master, local_device, sender, incoming, Source::Carried)
}

/// The partial roster a DM's carried removals stand for, each statement verified alone;
/// `None` when nothing may be heard from it.
fn carried_roster(local_master: &str, sender: &str, master: &str, rm: &[Removal]) -> Option<Roster> {
    if rm.is_empty()
        || master == local_master
        || !super::resolver::is_device_of(sender, master)
        || super::resolver::is_revoked(sender)
    {
        return None;
    }
    if !roster::carried_fits(rm) {
        hollow_log!("[HOLLOW-SECURITY] Ignored {} carried removal(s) from {sender}: over the bound", rm.len());
        return None;
    }
    let removals: Vec<Removal> = rm.iter().filter(|r| roster::removal_verifies(master, r)).cloned().collect();
    hollow_log!("[HOLLOW-ROSTER] A DM from {sender} carried {} of {master}'s removal(s), {} verified", rm.len(), removals.len());
    (!removals.is_empty()).then(|| Roster { removals, ..Roster::new(master) })
}

/// Where an ingested roster came from.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Source {
    /// A whole roster a device delivered.
    Delivered,
    /// A friend's roster our own sibling shared.
    Sibling,
    /// Removals a DM carried: a part of a roster, never all of it.
    Carried,
    /// The statements the relay holds (design ROSTER-CHECK): merged into a roster we
    /// hold, never a first sight, never our own, and no device of the identity showed it.
    Relay,
}

/// [`ingest`] for a friend's roster one of our own devices shared with its friend list,
/// so a device that lost its database places the friend's devices before their first
/// frame. The statements still verify alone; what the sibling buys is only the first
/// sight of a roster for a master we hold nothing about, and only for an accepted friend.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn ingest_friend_roster_from_sibling(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_master: &str,
    local_device: &str,
    sibling: &str,
    roster: Roster,
    db_path: &str,
    db_passphrase: &str,
) -> Ingested {
    // A bare master id is never a sibling (G1), and `same_identity(M, M)` holds.
    let ours = sibling != local_master
        && sibling != local_device
        && super::resolver::same_identity(sibling, local_master)
        && !super::resolver::is_revoked(sibling);
    if !ours {
        hollow_log!("[HOLLOW-SECURITY] Dropped a friend roster from {sibling}: not our own other device");
        return Ingested::default();
    }
    Box::pin(ingest_inner(
        event_tx, ws_cmd_tx, local_master, local_device, sibling, Some(roster), db_path, db_passphrase, Source::Sibling,
    ))
    .await
}

#[allow(clippy::too_many_arguments)]
async fn ingest_inner(
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_master: &str,
    local_device: &str,
    sender: &str,
    incoming: Option<Roster>,
    db_path: &str,
    db_passphrase: &str,
    source: Source,
) -> Ingested {
    let Some(incoming) = incoming else { return Ingested::default() };
    if serde_json::to_vec(&incoming).map(|b| b.len()).unwrap_or(usize::MAX) > MAX_ROSTER_BYTES {
        hollow_log!("[HOLLOW-SECURITY] Dropped an oversized roster from {sender}");
        return Ingested::default();
    }
    // A carried part was verified statement by statement: verifying it as a roster
    // would judge standing against the part alone and drop everything.
    let incoming = if source == Source::Carried { incoming } else { incoming.verified(now_ms()) };
    let master = incoming.master.clone();
    if master.is_empty() {
        return Ingested::default();
    }
    let folded = {
        let (db, pass) = (db_path.to_string(), db_passphrase.to_string());
        let (from, our_master, our_device) = (sender.to_string(), local_master.to_string(), local_device.to_string());
        tokio::task::spawn_blocking(move || fold_in(&db, &pass, &incoming, &from, &our_master, &our_device, source))
            .await
            .ok()
            .flatten()
    };
    let Some(Folded { prev, now, changed, upgrade_admitted, own_news, dropped }) = folded else {
        return Ingested::default();
    };
    if !dropped.is_empty() {
        super::lock_keeper::note_dropped_devices(&master, &dropped);
    }

    let newly_revoked: Vec<String> = prev
        .members
        .iter()
        .filter(|d| now.removed.contains_key(*d) && d.as_str() != local_device)
        .cloned()
        .collect();
    let added: Vec<String> = now.members.difference(&prev.members).cloned().collect();

    if master == local_master {
        own_changes(event_tx, local_device, &prev, &now, db_path, db_passphrase).await;
        for (device, voucher, created_at) in own_news {
            let _ = event_tx
                .send(NetworkEvent::SecurityAlert {
                    peer_id: master.clone(),
                    kind: super::security_alerts::KIND_OWN_DEVICE_ADDED.to_string(),
                    detail: super::security_alerts::own_device_detail(&device, &voucher),
                    created_at,
                })
                .await;
        }
        if sender != local_device && now.is_member(sender) && !super::resolver::is_revoked(sender) {
            super::crypto_handler::share_state_with_sibling(ws_cmd_tx, sender, db_path, db_passphrase);
        }
    } else {
        if !added.is_empty() {
            super::destroy::note_identity_reappeared(event_tx, db_path, db_passphrase, &master).await;
        }
        // A 0.11 identity's devices each upgrade on their own, so a device the upgrade
        // admitted before its consent reached us was known already.
        let before: Vec<String> = if prev.members.is_empty() {
            Vec::new()
        } else {
            prev.members.iter().chain(&upgrade_admitted).cloned().collect()
        };
        let after: Vec<String> = now.members.iter().cloned().collect();
        super::security_alerts::note_new_devices(
            event_tx, db_path, db_passphrase, local_master, &master, &before, &after,
        )
        .await;
    }
    if changed {
        hollow_log!(
            "[HOLLOW-ROSTER] {master}: {} member(s), {} removed, {} pending{}",
            now.members.len(),
            now.removed.len(),
            now.pending.len(),
            if now.protected { ", protected" } else { "" }
        );
    }
    let _ = event_tx.send(NetworkEvent::DeviceListUpdated { master_peer_id: master.clone() }).await;
    let asks_again = master == local_master
        && changed
        && !now.is_member(local_device)
        && !now.removed.contains_key(local_device)
        && !now.pending.contains(local_device);
    Ingested {
        our_devices_grew: master == local_master && changed,
        newly_revoked,
        added: if master == local_master { added } else { Vec::new() },
        asks_again,
        changed,
    }
}

/// [`ingest`] for a process with no node (the push fetch): what verifies is kept, a
/// removal included, and the new-device alerts are stored for the app to show. Never our
/// own roster, whose changes only the node acts on. Returns whether it was kept.
pub(crate) fn ingest_stored(
    db_path: &str,
    db_passphrase: &str,
    local_master: &str,
    local_device: &str,
    sender: &str,
    incoming: Roster,
) -> bool {
    if serde_json::to_vec(&incoming).map(|b| b.len()).unwrap_or(usize::MAX) > MAX_ROSTER_BYTES {
        hollow_log!("[HOLLOW-SECURITY] Dropped an oversized roster from {sender}");
        return false;
    }
    let incoming = incoming.verified(now_ms());
    stored_ingest(db_path, db_passphrase, local_master, local_device, sender, incoming, Source::Delivered)
}

fn stored_ingest(
    db_path: &str,
    db_passphrase: &str,
    local_master: &str,
    local_device: &str,
    sender: &str,
    incoming: Roster,
    source: Source,
) -> bool {
    let master = incoming.master.clone();
    if master.is_empty() || master == local_master {
        return false;
    }
    let Some(Folded { prev, now, upgrade_admitted, changed, dropped, .. }) =
        fold_in(db_path, db_passphrase, &incoming, sender, local_master, local_device, source)
    else {
        return false;
    };
    let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return true };
    // The running app holds the resolver this process just moved: it re-reads.
    if changed {
        if !dropped.is_empty() {
            let _ = store.add_roster_dropped(&master, &dropped);
        }
        let _ = store.mark_roster_dirty(&master, now_ms());
    }
    if now.members.difference(&prev.members).next().is_some() {
        super::destroy::note_identity_reappeared_stored(&store, &master);
    }
    if !prev.members.is_empty() {
        let before: Vec<String> = prev.members.iter().chain(&upgrade_admitted).cloned().collect();
        let after: Vec<String> = now.members.iter().cloned().collect();
        super::security_alerts::store_new_devices(&store, local_master, &master, &before, &after);
    }
    true
}

/// What [`fold_in`] did, for the async half to report.
struct Folded {
    /// Members as last saved, with the stored roster's fold.
    prev: RosterState,
    now: RosterState,
    changed: bool,
    /// Devices the saved roster's upgrade admitted.
    upgrade_admitted: BTreeSet<String>,
    /// Own-device alerts this ingest recorded: (device, voucher, recorded at).
    own_news: Vec<(String, String, i64)>,
    /// Devices the stored roster counted that a recovery in this one dropped.
    dropped: Vec<String>,
}

/// Devices `before` counted, in the fold or in server authority, that `after` counts in
/// neither, where `after` starts a new base: a recovery drops them without a removal,
/// so the join lock moves for them as for one (DEVICE_PROOF section 12 item 9).
fn dropped_by_recovery(before: &Roster, prev: &RosterState, after: &Roster, now: &RosterState, local_device: &str) -> Vec<String> {
    if prev.base == now.base {
        return Vec::new();
    }
    let still = after.authority().counted;
    before
        .authority()
        .counted
        .into_iter()
        .chain(prev.members.iter().cloned())
        .filter(|d| d != local_device && !now.members.contains(d) && !still.contains(d))
        .collect::<BTreeSet<String>>()
        .into_iter()
        .collect()
}

/// Devices our own roster change stopped counting: fold members it removed, and on a
/// recovery every device the fold or server authority counted before that it counts in
/// neither now (a device only authority still counted can win the lock walk).
pub(crate) fn lost_by_own_change(
    before: Option<&(Roster, RosterState)>,
    after: Option<&(Roster, RosterState)>,
    local_device: &str,
) -> Vec<String> {
    let empty = RosterState::default();
    let after_members = after.map_or(&empty.members, |(_, s)| &s.members);
    let mut lost: BTreeSet<String> = before.map_or(&empty.members, |(_, s)| &s.members).difference(after_members).cloned().collect();
    if let (Some((b, prev)), Some((a, now))) = (before, after) {
        lost.extend(dropped_by_recovery(b, prev, a, now, local_device));
    }
    lost.into_iter().collect()
}

/// Members another of our devices or the phrase added to our identity since `prev`,
/// each with its voucher (`phrase` for an admission or a recovery's keep, HOL-SEC-215):
/// what the rest of our devices are told (C-IDENTITY-09). Never a device this one
/// vouched (the person was here), this device itself, one the 0.11 upgrade admitted, or
/// anything before this device was a member itself, its own admission included.
fn added_by_another(
    roster: &Roster,
    prev: &RosterState,
    now: &RosterState,
    local_device: &str,
    upgrade_admitted: &BTreeSet<String>,
) -> Vec<(String, String)> {
    if !prev.is_member(local_device) {
        return Vec::new();
    }
    // The first base a phrase-admitted device learns, dated before its own admission, is
    // the identity as it was before this device joined (a Welcome restore into an empty
    // store): only a phrase admission after ours is news there.
    let joined_at = roster.phrase_admits.iter().filter(|p| p.device == local_device).map(|p| p.at_ms).max();
    if let (Some(joined), Some(base_at)) = (joined_at, roster.base_at())
        && prev.base != now.base
        && base_at < joined
    {
        return now
            .members
            .difference(&prev.members)
            .filter(|d| !upgrade_admitted.contains(*d))
            .filter(|d| roster.phrase_admits.iter().any(|p| p.device == **d && p.at_ms > joined))
            .map(|d| (d.clone(), super::security_alerts::BY_PHRASE.to_string()))
            .collect();
    }
    now.members
        .difference(&prev.members)
        .filter(|d| !upgrade_admitted.contains(*d))
        .filter_map(|d| {
            let vouchers: Vec<&str> = roster
                .vouches
                .iter()
                .filter(|v| v.base == now.base && v.device == *d)
                .map(|v| v.by.as_str())
                .collect();
            if vouchers.contains(&local_device) {
                return None;
            }
            if let Some(by) = vouchers.iter().find(|b| now.is_member(b)).or(vouchers.first()) {
                return Some((d.clone(), by.to_string()));
            }
            roster.phrase_rooted(d).then(|| (d.clone(), super::security_alerts::BY_PHRASE.to_string()))
        })
        .collect()
}

/// The store half of [`ingest`], on the blocking pool: merge, fold, save, re-key the
/// friend row, and record what our own devices must be told.
fn fold_in(
    db_path: &str,
    db_passphrase: &str,
    incoming: &Roster,
    sender: &str,
    local_master: &str,
    local_device: &str,
    source: Source,
) -> Option<Folded> {
    let store = MessageStore::lease(db_path, db_passphrase).ok()?;
    // One writer from load to save: two processes (the app, the push fetch) folding at
    // once would each save over the other, and a lost removal comes back unrevoked.
    if let Err(e) = store.begin_transaction() {
        hollow_log!("[HOLLOW-ROSTER] Dropped {}'s roster from {sender}: the store is busy ({e})", incoming.master);
        return None;
    }
    let folded = fold_in_store(&store, incoming, sender, local_master, local_device, source);
    if folded.is_some() {
        if let Err(e) = commit(&store, db_path) {
            hollow_log!("[HOLLOW-ROSTER] Failed to commit a roster fold: {e}");
            let _ = store.rollback_transaction();
            return None;
        }
    } else {
        let _ = store.rollback_transaction();
    }
    // The process-global resolver follows only what is on disk.
    if let Some(f) = &folded {
        follow(&incoming.master, &f.now, f.changed, local_master, local_device);
    }
    folded
}

fn commit(store: &MessageStore, db_path: &str) -> Result<(), String> {
    #[cfg(test)]
    if FAIL_COMMIT.lock().unwrap_or_else(|e| e.into_inner()).take_if(|p| p == db_path).is_some() {
        return Err("COMMIT failed: injected".to_string());
    }
    let _ = db_path;
    store.commit_transaction()
}

/// The store whose next roster fold fails to commit. Tests only.
#[cfg(test)]
static FAIL_COMMIT: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

fn fold_in_store(
    store: &MessageStore,
    incoming: &Roster,
    sender: &str,
    local_master: &str,
    local_device: &str,
    source: Source,
) -> Option<Folded> {
    let master = incoming.master.as_str();
    let stored = load(store, master);
    let known = stored.is_some() || store.load_device_list(master).ok().flatten().is_some();
    if matches!(source, Source::Carried | Source::Relay) && stored.is_none() {
        return None;
    }
    let stripped;
    let incoming = if source == Source::Relay && stored.as_ref().is_some_and(|r| r.r_pub.is_empty()) {
        stripped = keyless(incoming);
        &stripped
    } else {
        incoming
    };
    if source == Source::Sibling {
        let friend = store.get_friend_row(master).ok().flatten().is_some_and(|(status, ..)| status == "accepted");
        if !friend {
            hollow_log!("[HOLLOW-SECURITY] Dropped a roster for {master} from sibling {sender}: not an accepted friend");
            return None;
        }
    } else if !known {
        let alone = incoming.fold(|_| None, now_ms());
        if !alone.is_member(sender) {
            hollow_log!(
                "[HOLLOW-SECURITY] Dropped a roster for {master}: its deliverer {sender} is not one of its members"
            );
            return None;
        }
    }
    let merged = if master == local_master {
        merged_here(store, stored.as_ref(), &heard_for_own(store, master, incoming))
    } else {
        merged_here(store, stored.as_ref(), incoming)
    };
    stamp_pending(store, &merged);
    // Members as last saved, not re-folded now: a pending join that matured since
    // then is a member this ingest adds, and contacts are told.
    let prev = stored
        .as_ref()
        .map(|r| RosterState {
            members: store.device_links_for(master).unwrap_or_default(),
            ..fold(store, r)
        })
        .unwrap_or_default();
    let now = fold(store, &merged);
    let changed = stored.as_ref() != Some(&merged) || prev != now;

    if changed && let Err(e) = save_rows(store, &merged, &now, local_master, local_device) {
        hollow_log!("[HOLLOW-ROSTER] Failed to save the roster for {master}: {e}");
        return None;
    }
    // A recovery typed on another device of ours: what it cut off, as we held it, in this
    // fold's own transaction, since a later fold sees no base move to record (HOL-SEC-229).
    if master == local_master && prev.base != now.base && !prev.members.is_empty() {
        let at = merged.base_at().unwrap_or_else(now_ms);
        if let Err(e) = cut_by(store, &prev, at, |d| now.is_member(d)).and_then(|cut| note_cut_off(store, &now.base, cut)) {
            hollow_log!("[HOLLOW-ROSTER] Dropped our roster from {sender}: what its recovery cut off was not recorded ({e})");
            return None;
        }
    }

    // One of the identity's own devices showed us its roster and we now hold all of it
    // (AR-29): that confirms its own slot, never another device's. A sibling sharing a
    // friend's roster is not one of the friend's devices.
    // The same holds for our own sibling's view of a contact's roster (B3 (a)). A
    // carried part is never all of a roster: the DM's digest judges it after.
    let sibling = sender != local_device
        && sender != local_master
        && super::resolver::is_device_of(sender, local_master);
    // The resolver has not followed this fold yet: a member is never refused once it has.
    if !matches!(source, Source::Carried | Source::Relay)
        && master != local_master
        && (now.is_member(sender) || (sibling && !super::resolver::is_revoked(sender)))
    {
        super::roster_reach::stamp(store, master, sender);
    }
    for dev in now.members.iter().map(String::as_str).chain(std::iter::once(sender)) {
        if now.is_member(dev)
            && let Ok(true) = store.migrate_friend_to_master(dev, master)
        {
            hollow_log!("[HOLLOW-FRIENDS] Re-keyed friend {dev} -> master {master}");
        }
    }
    let upgrade_admitted = stored.as_ref().map(Roster::upgrade_admitted).unwrap_or_default();
    let own_news = if master == local_master && changed {
        let upgrade: BTreeSet<String> = upgrade_admitted.union(&merged.upgrade_admitted()).cloned().collect();
        added_by_another(&merged, &prev, &now, local_device, &upgrade)
            .into_iter()
            .filter_map(|(device, voucher)| {
                let at = super::security_alerts::record_own_device_added(store, master, &device, &voucher)?;
                Some((device, voucher, at))
            })
            .collect()
    } else {
        Vec::new()
    };
    let dropped = match stored.as_ref() {
        Some(before) if changed => dropped_by_recovery(before, &prev, &merged, &now, local_device),
        _ => Vec::new(),
    };
    Some(Folded { prev, now, changed, upgrade_admitted, own_news, dropped })
}

/// What a change to our own roster means for this device: removed, back, or asked.
async fn own_changes(
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_device: &str,
    prev: &RosterState,
    now: &RosterState,
    db_path: &str,
    db_passphrase: &str,
) {
    let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return };
    if let Some(by) = now.removed.get(local_device) {
        if !prev.removed.contains_key(local_device) {
            note_own_removal(&store, Some(by));
            let (by, at) = own_removal(&store).unwrap_or((by.clone(), now_ms()));
            hollow_log!("[HOLLOW-ROSTER] This device was removed from the identity by {by}");
            let _ = event_tx
                .send(NetworkEvent::DeviceRemoved {
                    by,
                    wipe_at_ms: at.saturating_add(roster::REMOVAL_GRACE_MS),
                })
                .await;
        }
    } else if now.is_member(local_device) && !prev.is_member(local_device) {
        note_own_removal(&store, None);
        let _ = event_tx.send(NetworkEvent::DeviceRestored).await;
    }
    let asking: Vec<String> = now
        .pending
        .difference(&prev.pending)
        .filter(|d| d.as_str() != local_device && asks_the_person(&store, now, d))
        .cloned()
        .collect();
    drop(store);
    for device in asking {
        let _ = event_tx.send(NetworkEvent::PendingDeviceAsking { device_peer_id: device }).await;
    }
}

/// The master a carried roster attributes `sender` to, read after [`ingest`]: its
/// master when the sender is a member of what we now hold for it. The master's own id
/// is no exception: it resolves to itself whether or not the roster counts it.
pub(crate) fn carried_master(roster: &Roster, sender: &str) -> Option<String> {
    let bound = super::resolver::is_device_of(sender, &roster.master);
    (bound && !super::resolver::is_revoked(sender)).then(|| roster.master.clone())
}

/// Whether a frame from `from` may be read at all (G1). A master id its own roster does
/// not count is someone holding the master key and nothing more; only the roster
/// statements it carries are heard, since each verifies alone.
pub(crate) fn heard_from(from: &str, msg: &super::types::HavenMessage) -> bool {
    !super::resolver::is_bare_master(from) || matches!(msg, super::types::HavenMessage::RosterNotice { .. })
}

/// Room presence never lists a master id its roster does not count (G1): sends would
/// pick it as the identity's device, and the identity would show online. The ids left
/// out are remembered so that one admitted later is let back in.
#[derive(Default)]
pub(crate) struct BarePresence {
    held: std::collections::HashSet<String>,
    epoch: u64,
}

impl BarePresence {
    /// False for a peer room presence must leave out.
    pub(crate) fn admits(&mut self, peer: &str) -> bool {
        if super::resolver::is_bare_master(peer) {
            self.held.insert(peer.to_string());
            return false;
        }
        true
    }

    /// One holding `ids` out, last settled at a resolver epoch that never was.
    #[cfg(test)]
    pub(crate) fn holding_for_test(ids: &[&str]) -> Self {
        Self { held: ids.iter().map(|s| s.to_string()).collect(), epoch: u64::MAX }
    }

    /// The resolver moved since the last [`Self::settle`].
    pub(crate) fn stale(&self) -> bool {
        super::resolver::epoch() != self.epoch
    }

    /// Follow the resolver once it moved: take out every id that turned bare, and say
    /// whether one left out is a device now, so the caller asks each room again.
    /// Returns the ids taken out.
    pub(crate) fn settle(
        &mut self,
        ws_room_peers: &mut std::collections::HashMap<String, std::collections::HashSet<String>>,
    ) -> (Vec<String>, bool) {
        let epoch = super::resolver::epoch();
        if epoch == self.epoch {
            return (Vec::new(), false);
        }
        self.epoch = epoch;
        let mut out = std::collections::HashSet::new();
        for peers in ws_room_peers.values_mut() {
            peers.retain(|p| {
                let bare = super::resolver::is_bare_master(p);
                if bare {
                    out.insert(p.clone());
                }
                !bare
            });
        }
        self.held.extend(out.iter().cloned());
        let before = self.held.len();
        self.held.retain(|p| super::resolver::is_bare_master(p));
        (out.into_iter().collect(), self.held.len() < before)
    }
}

/// Whether `device` is a member of `carried`, judged against our own roster for that
/// master when we hold one (so a forged recovery key changes nothing).
pub(crate) fn carried_member(
    carried: &Roster,
    device: &str,
    db_path: &str,
    db_passphrase: &str,
) -> bool {
    let carried = carried.verified(now_ms());
    let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return false };
    let view = match load(&store, &carried.master) {
        Some(stored) => merged_here(&store, Some(&stored), &carried),
        None => carried,
    };
    fold(&store, &view).is_member(device)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::roster::{
        r_pub_of, sign_consent, sign_legacy, sign_pending, sign_removal, sign_vouch, LEGACY_BASE,
        PENDING_MATURITY_MS,
    };

    fn kp(tag: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[tag; 32])
    }

    /// One observer: its own identity, a throwaway DB, and what an ingest emits.
    struct Observer {
        master: NativeKeypair,
        device: NativeKeypair,
        db: String,
        pass: String,
        events: mpsc::Sender<NetworkEvent>,
        event_rx: mpsc::Receiver<NetworkEvent>,
        ws: tokio::sync::mpsc::UnboundedSender<super::super::ws_client::WsCommand>,
        _ws_rx: tokio::sync::mpsc::UnboundedReceiver<super::super::ws_client::WsCommand>,
        _tmp: crate::test_tmp::TestDir,
    }

    impl Observer {
        fn new(master: u8, device: u8) -> Self {
            Self::with_master(kp(master), device)
        }

        fn with_master(master: NativeKeypair, device: u8) -> Self {
            let tmp = crate::test_tmp::tempdir().unwrap();
            let db = tmp.path().join("roster.db").to_str().unwrap().to_string();
            let pass = "cd".repeat(32);
            MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
            let (events, event_rx) = mpsc::channel(256);
            let (ws, _ws_rx) = tokio::sync::mpsc::unbounded_channel();
            Observer { master, device: kp(device), db, pass, events, event_rx, ws, _ws_rx, _tmp: tmp }
        }

        fn store(&self) -> MessageStore {
            MessageStore::open(&self.db, &self.pass).unwrap()
        }

        fn dir(&self) -> std::path::PathBuf {
            std::path::Path::new(&self.db).parent().unwrap().to_path_buf()
        }

        fn own(&self) -> (Roster, RosterState) {
            ensure_own(&self.store(), &self.master, &self.device, &self.db)
        }

        async fn ingest(&self, sender: &str, roster: &Roster) -> Ingested {
            ingest(
                &self.events, &self.ws, &self.master.peer_id(), &self.device.peer_id(),
                sender, Some(roster.clone()), &self.db, &self.pass,
            )
            .await
        }

        fn state_of(&self, master: &str) -> RosterState {
            let store = self.store();
            load(&store, master).map(|r| fold(&store, &r)).unwrap_or_default()
        }

        fn drain(&mut self) -> Vec<NetworkEvent> {
            let mut out = Vec::new();
            while let Ok(e) = self.event_rx.try_recv() {
                out.push(e);
            }
            out
        }
    }

    /// Design ROSTER-CHECK LOW-1: the relay's copy merges only into a roster we hold,
    /// never our own, confirms nobody's freshness, and a removal it carries counts.
    #[tokio::test]
    async fn the_relays_copy_lands_only_on_a_held_roster_and_confirms_nobody() {
        let me = Observer::new(201, 202);
        let _ = me.own();
        let (bob, bob_dev, bob_phone) = (kp(203), kp(204), kp(205));
        let bob_id = bob.peer_id();
        let held = Roster::legacy_for_test(&bob, &[&bob_dev, &bob_phone]);
        let mut removing = held.clone();
        removing.add_removal(sign_removal(&bob_dev, &bob_id, LEGACY_BASE, &bob_phone.peer_id(), &[]));

        let first = ingest_relay(&me.events, &me.ws, &me.master.peer_id(), &me.device.peer_id(), removing.clone(), &me.db, &me.pass).await;
        assert!(!first.changed && load(&me.store(), &bob_id).is_none(), "a relay copy is never a first sight");

        // Nor of an identity whose only row is a 0.11 device list, which a deliverer check
        // would wave through as known.
        let (carol, carol_dev) = (kp(206), kp(207));
        let carol_id = carol.peer_id();
        let legacy = super::super::types::SignedDeviceList {
            master_peer_id: carol_id.clone(),
            devices: vec![carol_dev.peer_id()],
            ..Default::default()
        };
        me.store().save_device_list(&carol_id, &serde_json::to_string(&legacy).unwrap(), 0, &[carol_dev.peer_id()], 1).unwrap();
        let carol_roster = Roster::legacy_for_test(&carol, &[&carol_dev]);
        let listed = ingest_relay(&me.events, &me.ws, &me.master.peer_id(), &me.device.peer_id(), carol_roster, &me.db, &me.pass).await;
        assert!(!listed.changed && load(&me.store(), &carol_id).is_none(), "a relay copy is never a first sight of a listed identity");

        me.ingest(&bob_dev.peer_id(), &held).await;
        assert!(me.state_of(&bob_id).is_member(&bob_phone.peer_id()));
        let stamped = me.store().roster_confirmed_at(&bob_id, &bob_dev.peer_id());
        let landed = ingest_relay(&me.events, &me.ws, &me.master.peer_id(), &me.device.peer_id(), removing, &me.db, &me.pass).await;
        assert!(landed.newly_revoked.contains(&bob_phone.peer_id()), "the relay's removal counts");
        assert!(!me.state_of(&bob_id).is_member(&bob_phone.peer_id()));
        assert_eq!(me.store().roster_confirmed_at(&bob_id, &bob_dev.peer_id()), stamped, "the relay confirms nobody's roster");

        let (ours, _) = me.own();
        let mut ours_removing = ours.clone();
        ours_removing.add_removal(sign_removal(&me.device, &me.master.peer_id(), &ours.base(), &me.device.peer_id(), &[]));
        let own = ingest_relay(&me.events, &me.ws, &me.master.peer_id(), &me.device.peer_id(), ours_removing, &me.db, &me.pass).await;
        assert!(!own.changed, "our own roster never takes a relay copy");
    }

    fn guard() -> std::sync::MutexGuard<'static, ()> {
        let g = super::super::resolver::test_lock();
        super::super::resolver::clear_all();
        g
    }

    /// HOL-SEC-001, HOL-SEC-006, F6. Another identity's statements speak for its own
    /// devices only: every device needs its own key's consent to that exact master, so
    /// a roster cannot claim our device, a friend's device or a friend's master, and
    /// removals signed in it touch nobody outside it.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn authz_a_foreign_roster_cannot_claim_or_remove_anyone_elses_devices() {
        let _g = guard();
        let mut me = Observer::new(0x01, 0x02);
        me.own();
        let (bob, bob_dev) = (kp(0x60), kp(0x61));
        me.ingest(&bob_dev.peer_id(), &Roster::legacy_for_test(&bob, &[&bob_dev])).await;
        assert_eq!(super::super::resolver::resolve(&bob_dev.peer_id()), bob.peer_id());

        let (mallory, mal_dev) = (kp(0x50), kp(0x51));
        let mut hostile = Roster::legacy_for_test(&mallory, &[&mal_dev]);
        for victim in [bob_dev.peer_id(), bob.peer_id(), me.device.peer_id()] {
            hostile.add_legacy(sign_legacy(&mallory, &victim));
            hostile.add_removal(sign_removal(&mal_dev, &mallory.peer_id(), LEGACY_BASE, &victim, &[]));
        }
        let out = me.ingest(&mal_dev.peer_id(), &hostile).await;

        assert_eq!(super::super::resolver::resolve(&bob_dev.peer_id()), bob.peer_id(), "HOL-SEC-001: claimed a friend's device");
        assert_eq!(super::super::resolver::resolve(&bob.peer_id()), bob.peer_id(), "HOL-SEC-006: claimed a friend's master");
        assert_eq!(super::super::resolver::resolve(&me.device.peer_id()), me.master.peer_id(), "claimed our own device");
        assert!(!super::super::resolver::is_revoked(&bob_dev.peer_id()));
        assert!(!super::super::resolver::is_revoked(&me.device.peer_id()));
        assert!(out.newly_revoked.is_empty());
        assert!(
            !me.drain().iter().any(|e| matches!(e, NetworkEvent::DeviceRemoved { .. })),
            "a foreign roster removed this device",
        );
        assert_eq!(super::super::resolver::resolve(&mal_dev.peer_id()), mallory.peer_id(), "its own device binds normally");
    }

    /// Design ID-1. Holding the master key admits nothing once the phrase is the root:
    /// a restored backup (legacy claim, pending join, its own vouch) is not a member,
    /// is not bound to the master, and our device is asked about it.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn authz_the_master_key_alone_makes_no_device_ours() {
        let _g = guard();
        let mut me = Observer::new(0x01, 0x02);
        let recovery = kp(0x03);
        write_bootstrap(&me.dir(), &Roster::genesis(&me.master, &recovery, &me.device, now_ms())).unwrap();
        let (roster, state) = me.own();
        assert!(state.protected && state.is_member(&me.device.peer_id()));

        let thief = kp(0x66);
        let mut stolen = roster.clone();
        stolen.add_consent(sign_consent(&thief, &me.master.peer_id()));
        stolen.add_legacy(sign_legacy(&me.master, &thief.peer_id()));
        stolen.add_pending(sign_pending(&me.master, &roster.base(), &thief.peer_id()));
        stolen.add_vouch(sign_vouch(&thief, &me.master.peer_id(), &roster.base(), &thief.peer_id()));
        me.drain();
        me.ingest(&thief.peer_id(), &stolen).await;

        let now = me.state_of(&me.master.peer_id());
        assert!(!now.is_member(&thief.peer_id()), "the master key alone admitted a device");
        assert!(now.pending.contains(&thief.peer_id()));
        assert_ne!(super::super::resolver::resolve(&thief.peer_id()), me.master.peer_id());
        assert!(
            super::super::resolver::disowns(&me.master.peer_id(), &thief.peer_id()),
            "an MLS leaf the master key certifies for it must hold no seat",
        );
        assert!(me.drain().iter().any(|e| matches!(
            e, NetworkEvent::PendingDeviceAsking { device_peer_id } if *device_peer_id == thief.peer_id()
        )));
    }

    /// A pending join nobody answers counts after seven days on THIS observer's clock,
    /// and a refusal keeps it out.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_pending_join_matures_on_the_observers_clock_unless_refused() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (bob, bob_dev, restored) = (kp(0x60), kp(0x61), kp(0x62));
        let mut r = Roster::legacy_for_test(&bob, &[&bob_dev]);
        me.ingest(&bob_dev.peer_id(), &r).await;
        r.add_consent(sign_consent(&restored, &bob.peer_id()));
        r.add_pending(sign_pending(&bob, LEGACY_BASE, &restored.peer_id()));
        me.ingest(&restored.peer_id(), &r).await;
        assert!(me.state_of(&bob.peer_id()).pending.contains(&restored.peer_id()));

        me.store().set_roster_seen(&bob.peer_id(), LEGACY_BASE, &restored.peer_id(), now_ms() - PENDING_MATURITY_MS).unwrap();
        assert!(me.state_of(&bob.peer_id()).is_member(&restored.peer_id()), "seven quiet days admit it");

        r.add_removal(sign_removal(&bob_dev, &bob.peer_id(), LEGACY_BASE, &restored.peer_id(), &[]));
        me.ingest(&bob_dev.peer_id(), &r).await;
        assert!(!me.state_of(&bob.peer_id()).is_member(&restored.peer_id()), "a refusal keeps it out");
    }

    /// A recovery that leaves out a backup which joined by waiting is not undone by the
    /// backup asking again: its seven days start over in the new base.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn authz_a_backup_left_out_by_a_recovery_waits_again_in_the_new_base() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (bob, recovery, bob_dev, restored) = (kp(0x60), kp(0x64), kp(0x61), kp(0x62));
        let mut r = Roster::genesis(&bob, &recovery, &bob_dev, now_ms() - 60_000);
        me.ingest(&bob_dev.peer_id(), &r).await;
        r.add_consent(sign_consent(&restored, &bob.peer_id()));
        r.add_pending(sign_pending(&bob, &r.base(), &restored.peer_id()));
        me.ingest(&restored.peer_id(), &r).await;
        me.store().set_roster_seen(&bob.peer_id(), &r.base(), &restored.peer_id(), now_ms() - PENDING_MATURITY_MS).unwrap();
        assert!(me.state_of(&bob.peer_id()).is_member(&restored.peer_id()), "seven quiet days admit it");

        let keep = [bob_dev.peer_id()];
        let rec = crate::identity::roster::sign_recovery(&bob, &recovery, now_ms(), &keep, false);
        r.add_phrase_statement(&r_pub_of(&recovery), Some(rec), None).unwrap();
        me.ingest(&bob_dev.peer_id(), &r).await;
        assert!(!me.state_of(&bob.peer_id()).is_member(&restored.peer_id()), "the recovery left it out");

        r.add_pending(sign_pending(&bob, &r.base(), &restored.peer_id()));
        me.ingest(&restored.peer_id(), &r).await;
        let now = me.state_of(&bob.peer_id());
        assert!(!now.is_member(&restored.peer_id()), "its old seven days carried into the new base");
        assert!(now.pending.contains(&restored.peer_id()));
    }

    /// HOL-SEC-032. A removed device is refused by key exchange, and the refusal is
    /// recorded, so a restart remembers it.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn authz_a_removed_device_stays_refused_after_a_restart() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (bob, kept, gone) = (kp(0x60), kp(0x61), kp(0x62));
        let mut r = Roster::legacy_for_test(&bob, &[&kept, &gone]);
        me.ingest(&kept.peer_id(), &r).await;
        r.add_removal(sign_removal(&kept, &bob.peer_id(), LEGACY_BASE, &gone.peer_id(), &[]));
        let out = me.ingest(&kept.peer_id(), &r).await;
        assert_eq!(out.newly_revoked, vec![gone.peer_id()]);
        assert!(super::super::crypto_handler::key_exchange_device_unauthorized(&gone.peer_id()));

        super::super::resolver::clear_all();
        super::super::resolver::warm_from_store(&me.store());
        assert!(
            super::super::crypto_handler::key_exchange_device_unauthorized(&gone.peer_id()),
            "HOL-SEC-032: a removed device passed key exchange after a restart",
        );
        assert!(!super::super::crypto_handler::key_exchange_device_unauthorized(&kept.peer_id()));
    }

    /// G1. A master id is a device only while its roster counts it. A legacy install
    /// (device id = master id) is one; our own protected master is not; a recovery that
    /// leaves the legacy seat out makes it nobody at once and after a restart: refused by
    /// key exchange, its MLS leaf disowned, no carried roster attributes it, and of its
    /// frames only the roster statements are heard.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn authz_a_master_id_is_a_device_only_while_its_roster_counts_it() {
        use super::super::crypto_handler::key_exchange_device_unauthorized;
        use super::super::resolver::{disowns, is_bare_master};
        use super::super::types::HavenMessage;
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        write_bootstrap(&me.dir(), &Roster::genesis(&me.master, &kp(0x03), &me.device, now_ms())).unwrap();
        me.own();
        let own = me.master.peer_id();
        assert!(is_bare_master(&own), "our own master key is not one of our devices");
        assert!(key_exchange_device_unauthorized(&own));

        let (bob, bob_r, bob_dev) = (kp(0x60), kp(0x64), kp(0x61));
        let b = bob.peer_id();
        let mut r = Roster::legacy_for_test(&bob, &[&bob, &bob_dev]);
        me.ingest(&b, &r).await;
        assert!(!is_bare_master(&b), "a legacy seat speaks as the master id");
        assert_eq!(carried_master(&r, &b), Some(b.clone()));
        assert!(!key_exchange_device_unauthorized(&b));
        assert!(!disowns(&b, &b));

        let rec = crate::identity::roster::sign_recovery(&bob, &bob_r, now_ms(), &[bob_dev.peer_id()], false);
        r.add_phrase_statement(&r_pub_of(&bob_r), Some(rec), None).unwrap();
        me.ingest(&bob_dev.peer_id(), &r).await;
        assert!(is_bare_master(&b), "the recovery left the legacy seat out");
        assert_eq!(carried_master(&r, &b), None, "a carried roster attributed the bare master id");
        assert!(key_exchange_device_unauthorized(&b), "the bare master id passed key exchange");
        assert!(disowns(&b, &b), "an MLS leaf of the bare master id holds a seat");
        assert!(heard_from(&b, &HavenMessage::RosterNotice { roster: r.clone() }), "its roster statements still count");
        assert!(!heard_from(&b, &HavenMessage::SiblingStateSyncRequest), "a frame from the bare master id was read");
        assert!(heard_from(&bob_dev.peer_id(), &HavenMessage::SiblingStateSyncRequest));

        super::super::resolver::clear_all();
        super::super::resolver::warm_from_store(&me.store());
        assert!(is_bare_master(&b) && is_bare_master(&own), "a restart forgot which master ids are bare");
        assert!(!is_bare_master(&bob_dev.peer_id()));
    }

    /// G1. Room presence leaves a bare master id out, takes out one that turned bare,
    /// and lets one back in once the phrase admits it again.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn room_presence_follows_whether_a_master_id_is_a_device() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (bob, bob_r, bob_dev) = (kp(0x60), kp(0x64), kp(0x61));
        let (b, d) = (bob.peer_id(), bob_dev.peer_id());
        let mut r = Roster::legacy_for_test(&bob, &[&bob, &bob_dev]);
        me.ingest(&b, &r).await;
        let mut presence = BarePresence::default();
        let mut rooms = std::collections::HashMap::from([(
            "room".to_string(),
            std::collections::HashSet::from([b.clone(), d.clone()]),
        )]);
        assert!(presence.admits(&b));
        assert_eq!(presence.settle(&mut rooms), (Vec::new(), false));

        let rec = crate::identity::roster::sign_recovery(&bob, &bob_r, now_ms(), std::slice::from_ref(&d), false);
        r.add_phrase_statement(&r_pub_of(&bob_r), Some(rec), None).unwrap();
        me.ingest(&d, &r).await;
        assert_eq!(presence.settle(&mut rooms), (vec![b.clone()], false), "the bare master id stayed present");
        assert_eq!(rooms["room"], std::collections::HashSet::from([d.clone()]));
        assert!(!presence.admits(&b), "a bare master id joined room presence");

        let admit = crate::identity::roster::sign_phrase_admit(&bob, &bob_r, now_ms() + 1, &b);
        r.add_phrase_statement(&r_pub_of(&bob_r), None, Some(admit)).unwrap();
        me.ingest(&d, &r).await;
        assert_eq!(presence.settle(&mut rooms), (Vec::new(), true), "an admitted master id is never asked for again");
        assert!(presence.admits(&b));
    }

    /// G1: the bare master refusal is only as good as the doors that ask it: relay
    /// frames, stream chunks, room presence (presence events, discovery and the loop's
    /// settle) and the push fetch node.
    #[test]
    fn bare_master_gates_stay_wired() {
        let node = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src").join("node");
        let read = |f: &str| std::fs::read_to_string(node.join(f)).expect("read node source").replace("\r\n", "\n");
        let (swarm, fetch) = (read("swarm.rs"), read("fetch.rs"));
        let between = |src: &str, from: &str, to: &str| -> String {
            let start = src.find(from).unwrap_or_else(|| panic!("missing {from}"));
            let end = src[start..].find(to).unwrap_or_else(|| panic!("missing {to} after {from}"));
            src[start..start + end].to_string()
        };
        for (from, to, gate) in [
            ("if let Ok(msg) = parsed {", "if msg.live_only()", "roster_book::heard_from(&from, &msg)"),
            ("let rate_ok", "if !rate_ok", "resolver::is_bare_master(&from)"),
            ("WsEvent::BinaryDirect { room, from, data } => {", "ws_stream_receive(", "resolver::is_bare_master(&from)"),
            ("WsEvent::PeerJoined { room, peer_id } => {", "ws_room_peers.entry(", "bare_presence.admits(&peer_id)"),
            ("WsEvent::RoomMembers { room, peers } => {", "ws_room_peers.insert(", "bare_presence.admits(p)"),
            ("loop_stall.check(arm, name, t0);", "tokio::select! {", "settle_bare_presence(&mut bare_presence"),
            ("async fn settle_bare_presence(", "\n}\n", "bare_presence.settle(ws_room_peers)"),
        ] {
            assert!(between(&swarm, from, to).contains(gate), "swarm.rs: {from} no longer asks {gate}");
        }
        assert!(
            between(&fetch, "let payload = parsed.and_then(", "frame_auth::open(").contains("resolver::is_bare_master(&from)"),
            "fetch.rs: a push wake reads frames from a bare master id",
        );
        // The push processes seed only their own device: the store says whether the
        // master id is one too.
        let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        for file in ["api/network.rs", "push_enrich.rs"] {
            let text = std::fs::read_to_string(src.join(file)).expect("read source");
            let seeds: Vec<&str> = text.lines().filter(|l| l.contains("resolver::seed_self(")).collect();
            assert!(
                !seeds.is_empty() && seeds.iter().all(|l| l.contains("seed_self(&local_master, std::slice::from_ref(&peer_id))")),
                "{file}: a push process seeds the master id as one of its devices: {seeds:?}",
            );
        }
    }

    /// HOL-SEC-033. A carried roster attributes its sender to its master only when the
    /// sender is a member of what we now hold, never a removed device replaying it.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn authz_a_carried_roster_attributes_only_a_member() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (bob, kept, gone) = (kp(0x60), kp(0x61), kp(0x62));
        let before = Roster::legacy_for_test(&bob, &[&kept, &gone]);
        let mut after = before.clone();
        after.add_removal(sign_removal(&kept, &bob.peer_id(), LEGACY_BASE, &gone.peer_id(), &[]));
        me.ingest(&kept.peer_id(), &after).await;
        me.ingest(&gone.peer_id(), &before).await;
        assert_eq!(carried_master(&before, &gone.peer_id()), None, "HOL-SEC-033: a removed device replaying an older roster");
        assert_eq!(carried_master(&after, &kept.peer_id()), Some(bob.peer_id()));
    }

    /// HOL-SEC-033. Every arm that carries a roster ingests it, enforces the removals it
    /// brought, and attributes its sender only through `carried_master`.
    #[test]
    fn carried_roster_arms_stay_wired() {
        let swarm = std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/node/swarm.rs"))
            .expect("read swarm.rs")
            .replace("\r\n", "\n");
        for arm in [
            "        HavenMessage::ServerJoinRequest {",
            "        HavenMessage::FriendRequest {",
            "        HavenMessage::FriendAccept {",
            "        HavenMessage::FriendReject {",
        ] {
            let start = swarm.find(arm).unwrap_or_else(|| panic!("missing {arm}"));
            let rest = &swarm[start + arm.len()..];
            let body = &rest[..rest.find("\n        HavenMessage::").unwrap_or(rest.len())];
            for step in ["roster_book::ingest(", "enforce_device_revocations(", "roster_book::carried_master("] {
                assert!(body.contains(step), "{}: the carried roster skips {step}", arm.trim());
            }
        }
    }

    /// HOL-SEC-034. Only a device we had never seen for an identity reported destroyed
    /// means it came back; a replayed roster we already held does not.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn authz_only_a_new_member_means_a_destroyed_identity_returned() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (bob, old, new) = (kp(0x60), kp(0x61), kp(0x63));
        let first = Roster::legacy_for_test(&bob, &[&old]);
        me.ingest(&old.peer_id(), &first).await;
        me.store().save_setting(&format!("identity_destroyed:{}", bob.peer_id()), "7000").unwrap();
        me.ingest(&old.peer_id(), &first).await;
        assert_eq!(
            super::super::destroy::identity_destroyed_at(&me.store(), &bob.peer_id()),
            Some(7_000),
            "HOL-SEC-034: a replayed roster cleared the destroyed banner",
        );
        let mut back = first.clone();
        back.add_consent(sign_consent(&new, &bob.peer_id()));
        back.add_legacy(sign_legacy(&bob, &new.peer_id()));
        me.ingest(&new.peer_id(), &back).await;
        assert_eq!(super::super::destroy::identity_destroyed_at(&me.store(), &bob.peer_id()), None);
    }

    /// A roster for a master we hold nothing about is kept only from one of its members.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_roster_for_a_stranger_needs_its_deliverer_as_a_member() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (bob, bob_dev, carrier) = (kp(0x60), kp(0x61), kp(0x70));
        let r = Roster::legacy_for_test(&bob, &[&bob_dev]);
        me.ingest(&carrier.peer_id(), &r).await;
        assert!(load(&me.store(), &bob.peer_id()).is_none(), "stored a stranger's roster from a non-member");
        me.ingest(&bob_dev.peer_id(), &r).await;
        assert!(load(&me.store(), &bob.peer_id()).is_some());
    }

    /// Design ID-1. A stolen member device removes the owner's device; the owner's
    /// device learns it, the phrase recovers keeping it, and the thief, with everything
    /// it signed in the old base, counts for nothing after.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn authz_the_phrase_takes_the_identity_back_from_a_stolen_device() {
        let _g = guard();
        let mut me = Observer::new(0x01, 0x02);
        let recovery = kp(0x03);
        let thief = kp(0x66);
        write_bootstrap(&me.dir(), &Roster::genesis(&me.master, &recovery, &me.device, now_ms() - 10)).unwrap();
        me.own();
        vouch(&me.master, &me.device, &thief.peer_id(), &me.db, &me.pass).unwrap();
        let (mut roster, _) = own(&me.master.peer_id(), &me.db, &me.pass).unwrap();
        roster.add_consent(sign_consent(&thief, &me.master.peer_id()));
        let base = roster.base();
        roster.add_removal(sign_removal(&thief, &me.master.peer_id(), &base, &me.device.peer_id(), &[]));
        me.drain();
        me.ingest(&thief.peer_id(), &roster).await;
        assert!(
            me.drain().iter().any(|e| matches!(e, NetworkEvent::DeviceRemoved { by, .. } if *by == thief.peer_id())),
            "the owner's device must learn it was removed",
        );

        let (_, state) = recover(&me.master, &recovery, &me.device, &[], false, None, &me.db, &me.pass).unwrap();
        assert!(state.is_member(&me.device.peer_id()));
        assert!(!state.is_member(&thief.peer_id()), "the thief survived the recovery");
        let mut late = roster.clone();
        late.add_vouch(sign_vouch(&thief, &me.master.peer_id(), &base, &kp(0x67).peer_id()));
        me.ingest(&thief.peer_id(), &late).await;
        assert_eq!(
            me.state_of(&me.master.peer_id()).members,
            BTreeSet::from([me.device.peer_id()]),
            "old-base statements came back",
        );
    }

    /// The upgrade: a device its own 0.11 list names claims its legacy seat and removes
    /// what that list had revoked; one the list does not name asks to join.
    #[test]
    fn a_legacy_device_claims_its_seat_and_a_restored_one_asks() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let gone = kp(0x05).peer_id();
        let old = super::super::crypto_handler::build_signed_device_list(
            &me.master, 7, vec![me.device.peer_id()], vec![gone.clone()],
        );
        let json = serde_json::to_string(&old).unwrap();
        me.store().save_device_list(&me.master.peer_id(), &json, 7, &old.devices, 0).unwrap();
        let (roster, state) = me.own();
        assert!(state.is_member(&me.device.peer_id()) && !state.protected);
        assert!(roster.removals.iter().any(|r| r.device == gone), "the old revocation became a removal");

        let restored = Observer::new(0x01, 0x09);
        restored.store().save_device_list(&restored.master.peer_id(), &json, 7, &old.devices, 0).unwrap();
        let (_, state) = restored.own();
        assert!(state.pending.contains(&restored.device.peer_id()), "a device the old list never named must ask");
    }

    /// The bootstrap a phrase wrote is imported once. A stored 0.11 phrase outlives
    /// the recovery key being pinned: only the person confirming it erases it.
    #[test]
    fn the_bootstrap_is_imported_and_a_pinned_key_keeps_the_stored_phrase() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        me.store().save_setting(STORED_PHRASE, "abandon abandon").unwrap();
        write_bootstrap(&me.dir(), &Roster::genesis(&me.master, &kp(0x03), &me.device, now_ms())).unwrap();
        let (roster, state) = me.own();
        assert!(state.protected && roster.r_pub == r_pub_of(&kp(0x03)));
        assert!(!me.dir().join(BOOTSTRAP_FILE).exists(), "the bootstrap is consumed");
        assert_eq!(
            me.store().load_setting(STORED_PHRASE).unwrap().as_deref(),
            Some("abandon abandon"),
            "a pinned key erased the stored phrase",
        );
    }

    const PHRASE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    /// One device of the identity `PHRASE` derives, holding `list` as its 0.11 device
    /// list and, when `stored`, the phrase 0.11 kept.
    fn legacy_device(device: u8, list: &[&str], revoked: &[&str], stored: bool) -> Observer {
        let (master, _) = crate::identity::recovery::keys_from_phrase(PHRASE).unwrap();
        let me = Observer::with_master(master, device);
        let ids = |v: &[&str]| v.iter().map(|d| d.to_string()).collect::<Vec<_>>();
        let old = super::super::crypto_handler::build_signed_device_list(&me.master, 4, ids(list), ids(revoked));
        let json = serde_json::to_string(&old).unwrap();
        me.store().save_device_list(&me.master.peer_id(), &json, old.version, &old.devices, 0).unwrap();
        if stored {
            me.store().save_setting(STORED_PHRASE, PHRASE).unwrap();
        }
        me
    }

    /// Decision C (C-IDENTITY-06). The first 0.12 start of a device its 0.11 list seats
    /// signs the identity's first recovery with the stored phrase, before anything is
    /// heard: the same base whichever device does it, the list's devices admitted (never
    /// the master id, which anyone holding the master key can consent as), what it
    /// revoked removed, and the stored phrase kept for the person to confirm. A device
    /// the list does not name still asks to join.
    #[test]
    fn authz_the_first_start_roots_a_legacy_identity_in_its_stored_phrase() {
        let _g = guard();
        let (master, recovery) = crate::identity::recovery::keys_from_phrase(PHRASE).unwrap();
        let own = master.peer_id();
        let (sibling, gone) = (kp(0x03), kp(0x05));
        let me = legacy_device(0x02, &[&kp(0x02).peer_id(), &sibling.peer_id(), &own], &[&gone.peer_id()], true);
        let (roster, state) = me.own();
        let upgrade_base = roster::base_id(&own, &r_pub_of(&recovery), &roster::sign_upgrade_recovery(&master, &recovery));
        assert!(state.protected && roster.r_pub == r_pub_of(&recovery), "not rooted in the stored phrase: {state:?}");
        assert_eq!(state.base, upgrade_base);
        assert_eq!(state.members, BTreeSet::from([me.device.peer_id()]));
        assert_eq!(me.store().load_setting(STORED_PHRASE).unwrap().as_deref(), Some(PHRASE), "the upgrade erased the stored phrase");
        assert_eq!(me.own().0, roster, "a second start signed again");

        // The sibling counts once it consents; the revoked device and the master id never do.
        let mut later = roster.clone();
        for d in [&sibling, &gone, &master] {
            later.add_consent(sign_consent(d, &own));
        }
        merge_for_test(&me.store(), &later, &own, &me.device.peer_id());
        let s = me.state_of(&own);
        assert!(s.is_member(&sibling.peer_id()), "the list's sibling was left out: {s:?}");
        assert!(!s.is_member(&gone.peer_id()));
        assert!(roster.removals.iter().any(|r| r.device == gone.peer_id() && r.base == upgrade_base), "the 0.11 revocation was dropped");
        assert!(!s.is_member(&own), "G1: the master id was admitted");

        let unnamed = legacy_device(0x09, &[&kp(0x02).peer_id()], &[], true);
        let (_, state) = unnamed.own();
        assert!(!state.protected && state.pending.contains(&unnamed.device.peer_id()), "an unnamed device signed: {state:?}");
    }

    /// Decision C, the multi-device trap. Two devices of one identity upgrade apart,
    /// their 0.11 lists out of step (the older still names a device the newer revoked),
    /// and a device is linked on 0.12 in between: both meet in one base, both stay,
    /// the linked device survives the second upgrade and the revoked one stays out.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn authz_two_legacy_devices_upgrading_apart_meet_in_one_base() {
        let _g = guard();
        let (a_id, b_id, x, linked) = (kp(0x02).peer_id(), kp(0x03).peer_id(), kp(0x05), kp(0x07));
        let a = legacy_device(0x02, &[&a_id, &b_id, &x.peer_id()], &[], true);
        let b = legacy_device(0x03, &[&a_id, &b_id], &[&x.peer_id()], true);
        let own = a.master.peer_id();

        a.own();
        vouch(&a.master, &a.device, &linked.peer_id(), &a.db, &a.pass).unwrap();
        let (mut ra, _) = own_of(&a);
        ra.add_consent(sign_consent(&linked, &own));
        ra.add_consent(sign_consent(&x, &own));
        merge_for_test(&a.store(), &ra, &own, &a.device.peer_id());
        assert!(a.state_of(&own).is_member(&linked.peer_id()));

        b.own();
        let ((ra, _), (rb, _)) = (own_of(&a), own_of(&b));
        a.ingest(&b_id, &rb).await;
        b.ingest(&a_id, &ra).await;
        let (sa, sb) = (a.state_of(&own), b.state_of(&own));
        assert!(sa.protected, "{sa:?}");
        assert_eq!(sa.base, sb.base, "the two upgrades started two bases");
        assert_eq!(sa.members, BTreeSet::from([a_id.clone(), b_id.clone(), linked.peer_id()]), "{sa:?}");
        assert_eq!(sb.members, sa.members);
        assert!(sa.removed.contains_key(&x.peer_id()), "the newer list's revocation was lost: {sa:?}");
    }

    fn own_of(o: &Observer) -> (Roster, RosterState) {
        own(&o.master.peer_id(), &o.db, &o.pass).unwrap()
    }

    /// Design ID-1.5. Once the phrase is the root, a destroy order signed by the master
    /// alone wipes nothing; the phrase's signature does, and so does a member device
    /// holding the phrase's permission. A legacy identity keeps the master's word.
    #[test]
    fn authz_a_destroy_order_needs_the_phrase_once_protected() {
        use super::super::crypto_handler::{build_delegated_destroy, build_destroy_identity, sign_destroy_delegation};
        use super::super::destroy::{judge_own_order, Verdict};
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let recovery = kp(0x03);
        let judge = |order: &crate::node::DestroyIdentity| {
            matches!(
                judge_own_order(order, &me.master.peer_id(), &me.device.peer_id(), &me.db, &me.pass),
                Verdict::Apply,
            )
        };
        me.own();
        assert!(judge(&build_destroy_identity(&me.master, None, now_ms() + 1, Vec::new(), false)), "legacy: the master speaks");

        write_bootstrap(&me.dir(), &Roster::genesis(&me.master, &recovery, &me.device, now_ms())).unwrap();
        me.own();
        assert!(
            !judge(&build_destroy_identity(&me.master, None, now_ms() + 2, Vec::new(), false)),
            "the master key alone wiped a protected identity",
        );
        assert!(judge(&build_destroy_identity(&me.master, Some(&recovery), now_ms() + 3, Vec::new(), false)));
        let delegation = sign_destroy_delegation(&me.master, &recovery, &me.device.peer_id(), now_ms());
        assert!(judge(&build_delegated_destroy(&me.master, &me.device, delegation, now_ms() + 4, false)));
        let stranger = kp(0x44);
        let foreign = sign_destroy_delegation(&me.master, &recovery, &stranger.peer_id(), now_ms());
        assert!(
            !judge(&build_delegated_destroy(&me.master, &stranger, foreign, now_ms() + 5, false)),
            "a permission for a device that is no member",
        );
        let forged = sign_destroy_delegation(&me.master, &kp(0x04), &me.device.peer_id(), now_ms());
        assert!(
            !judge(&build_delegated_destroy(&me.master, &me.device, forged, now_ms() + 6, false)),
            "a permission under another recovery key",
        );
        let mine = sign_destroy_delegation(&me.master, &recovery, &me.device.peer_id(), now_ms());
        assert!(
            !judge(&build_delegated_destroy(&me.master, &stranger, mine, now_ms() + 7, false)),
            "this device's permission, carried by another device",
        );
    }

    /// The relay sees our whole roster, the waiting device's own ask included, so it
    /// folds the same answer every contact does.
    #[test]
    fn the_relay_is_shown_the_whole_roster() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (roster, _) = me.own();
        let (ws, mut rx) = tokio::sync::mpsc::unbounded_channel();
        show_relay(&ws, &me.master.peer_id(), &me.db, &me.pass);
        match rx.try_recv() {
            Ok(super::super::ws_client::WsCommand::JoinInbox { room_code, roster: shown }) => {
                assert_eq!(room_code, format!("inbox:{}", me.master.peer_id()));
                assert_eq!(shown, roster);
            }
            _ => panic!("no inbox join with the roster"),
        }
    }

    /// Destroying this device (scope (b)) keeps the devices it linked: the phone a
    /// laptop was linked from takes nothing with it.
    #[test]
    fn removing_itself_keeps_the_devices_it_linked() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        write_bootstrap(&me.dir(), &Roster::genesis(&me.master, &kp(0x03), &me.device, now_ms())).unwrap();
        me.own();
        let laptop = kp(0x07);
        vouch(&me.master, &me.device, &laptop.peer_id(), &me.db, &me.pass).unwrap();
        let (mut roster, _) = own(&me.master.peer_id(), &me.db, &me.pass).unwrap();
        roster.add_consent(sign_consent(&laptop, &me.master.peer_id()));
        merge_for_test(&me.store(), &roster, &me.master.peer_id(), &me.device.peer_id());
        let signed = remove_self(&me.master, &me.device, &me.db, &me.pass).unwrap();
        let s = signed.fold(|_| None, now_ms());
        assert!(!s.is_member(&me.device.peer_id()));
        assert!(s.is_member(&laptop.peer_id()), "the laptop left with the phone it was linked from");
    }

    /// Our own genesis, dated eleven minutes past this node's clock and saved as held:
    /// as if the clock stepped back after the recovery arrived.
    fn held_from_ahead(me: &Observer, recovery: &NativeKeypair) -> Roster {
        let ahead = now_ms() + 11 * 60 * 1000;
        let genesis = Roster::genesis(&me.master, recovery, &me.device, ahead);
        let state = genesis.fold(|_| None, ahead);
        save(&me.store(), &genesis, &state, &me.master.peer_id(), &me.device.peer_id()).unwrap();
        genesis
    }

    /// C-IDENTITY-02. A clock that steps back behind the newest recovery forgets
    /// nothing: what this node holds was judged for freshness when it arrived. A load,
    /// a start and a change at that clock keep the recovery and its pinned key, so the
    /// master key alone still orders no wipe and a forged recovery key is not adopted.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn authz_a_clock_behind_the_newest_recovery_keeps_the_phrase_pinned() {
        use super::super::crypto_handler::build_destroy_identity;
        use super::super::destroy::{judge_own_order, Verdict};
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let recovery = kp(0x03);
        let own_master = me.master.peer_id();
        held_from_ahead(&me, &recovery);
        let pinned = r_pub_of(&recovery);
        let stored = |what: &str| {
            let raw = me.store().load_roster(&own_master).unwrap().expect("a stored roster");
            assert_eq!(raw.r_pub, pinned, "{what} cleared the pinned recovery key");
            assert_eq!(raw.recoveries.len(), 1, "{what} dropped the recovery");
        };

        let held = load(&me.store(), &own_master).expect("held");
        assert_eq!(held.r_pub, pinned, "a load cleared the pinned recovery key");
        assert_eq!(held.recoveries.len(), 1, "a load dropped the recovery");
        let (_, state) = me.own();
        assert!(state.protected && state.is_member(&me.device.peer_id()), "start-up lost the phrase's base: {state:?}");
        stored("start-up");
        vouch(&me.master, &me.device, &kp(0x07).peer_id(), &me.db, &me.pass).unwrap();
        stored("a change");
        let leaving = remove_self(&me.master, &me.device, &me.db, &me.pass).expect("a self-removal");
        assert_eq!((leaving.r_pub.as_str(), leaving.recoveries.len()), (pinned.as_str(), 1), "a self-removal dropped the recovery");

        let order = build_destroy_identity(&me.master, None, now_ms() + 1, Vec::new(), false);
        assert!(
            !matches!(judge_own_order(&order, &own_master, &me.device.peer_id(), &me.db, &me.pass), Verdict::Apply),
            "the master key alone wiped a protected identity",
        );

        let thief = kp(0x66);
        me.ingest(&thief.peer_id(), &Roster::genesis(&me.master, &kp(0x04), &thief, now_ms())).await;
        stored("a forged recovery key");
        assert!(!me.state_of(&own_master).is_member(&thief.peer_id()), "a forged recovery key admitted its device");
    }

    /// The phrase typed on a device whose clock stepped back behind the newest recovery
    /// keeps the last word: its recovery starts the newest base, and an admission
    /// counts in the base it was typed in.
    #[test]
    fn the_phrase_keeps_the_last_word_behind_a_stepped_back_clock() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let recovery = kp(0x03);
        let genesis = held_from_ahead(&me, &recovery);
        let (_, state) = recover(&me.master, &recovery, &me.device, &[], false, None, &me.db, &me.pass).unwrap();
        assert_ne!(state.base, genesis.base(), "the recovery was dated before the base it meant to replace");

        let other = Observer::new(0x01, 0x09);
        let held = genesis.fold(|_| None, genesis.recoveries[0].at_ms);
        save(&other.store(), &genesis, &held, &other.master.peer_id(), &other.device.peer_id()).unwrap();
        let (_, state) = admit_by_phrase(&other.master, &recovery, &other.device, &other.db, &other.pass).unwrap();
        assert!(state.is_member(&other.device.peer_id()), "the admission was dated before its base");
    }

    /// C-IDENTITY-06. While an identity from before 0.12 keeps its phrase here, a
    /// recovery key a master-key holder publishes is never taken for our own master,
    /// nor kept from before: the forged key's device is nobody, the stored phrase stays,
    /// and the real phrase still recovers. The legacy roster below (a build from before
    /// the upgrade signed anything) has no pinned key, so the stored phrase alone refuses.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn authz_a_recovery_key_from_the_network_never_locks_out_our_own_phrase() {
        let _g = guard();
        let (master, recovery) = crate::identity::recovery::keys_from_phrase(PHRASE).unwrap();
        let me = Observer::with_master(master, 0x02);
        let own_master = me.master.peer_id();
        let thief = kp(0x66);
        let forged = Roster::genesis(&me.master, &kp(0x04), &thief, now_ms());
        let stored_phrase = |me: &Observer| me.store().load_setting(STORED_PHRASE).unwrap();

        me.store().save_setting(STORED_PHRASE, PHRASE).unwrap();
        let (_, state) = me.own();
        assert!(state.protected && state.is_member(&me.device.peer_id()));
        me.ingest(&thief.peer_id(), &forged).await;
        assert!(!me.state_of(&own_master).is_member(&thief.peer_id()), "a forged recovery key admitted its device");
        me.own();
        assert_eq!(stored_phrase(&me).as_deref(), Some(PHRASE), "the stored phrase was erased for a forged key");
        let (_, state) = recover(&me.master, &recovery, &me.device, &[], false, None, &me.db, &me.pass)
            .expect("the real phrase was locked out");
        assert!(state.protected && state.is_member(&me.device.peer_id()));

        // A forged key a legacy roster took from before this device knew better goes
        // at start, and one arriving now is never taken.
        let (master, _) = crate::identity::recovery::keys_from_phrase(PHRASE).unwrap();
        let held = Observer::with_master(master, 0x09);
        held.store().save_setting(STORED_PHRASE, PHRASE).unwrap();
        let legacy = Roster::legacy_for_test(&held.master, &[&held.device]).verified(now_ms());
        let merged = legacy.merged(&forged.verified(now_ms()));
        assert_eq!(merged.r_pub, r_pub_of(&kp(0x04)), "control: a legacy roster takes the first key it sees");
        let state = fold(&held.store(), &merged);
        save(&held.store(), &merged, &state, &own_master, &held.device.peer_id()).unwrap();
        let (roster, state) = held.own();
        assert!(roster.r_pub.is_empty() && !state.is_member(&thief.peer_id()), "a forged key stayed pinned: {state:?}");
        held.ingest(&thief.peer_id(), &forged).await;
        let (roster, state) = own_of(&held);
        assert!(roster.r_pub.is_empty() && !state.is_member(&thief.peer_id()), "a forged key was taken: {state:?}");
        assert_eq!(stored_phrase(&held).as_deref(), Some(PHRASE));
    }

    /// The first recovery key an identity shows is the one it keeps.
    #[test]
    fn a_recovery_keeps_the_phrase_key_pinned() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        me.own();
        recover(&me.master, &kp(0x03), &me.device, &[], false, None, &me.db, &me.pass).unwrap();
        assert!(
            recover(&me.master, &kp(0x04), &me.device, &[], false, None, &me.db, &me.pass).is_err(),
            "a second recovery key replaced the pinned one",
        );
    }

    /// C-OLM-02: a roster notice reaches a friend through its DM room, but never puts
    /// us back into the room of a friend we blocked.
    #[test]
    fn a_roster_notice_never_rejoins_a_blocked_friends_dm_room() {
        use super::super::ws_client::WsCommand;
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (friend, blocked) = (kp(0x05).peer_id(), kp(0x06).peer_id());
        me.store().save_friend(&friend, "accepted", "", 1).unwrap();
        me.store().save_friend(&blocked, "accepted", "", 1).unwrap();
        let (ws, mut ws_rx) = tokio::sync::mpsc::unbounded_channel();
        let local = me.master.peer_id();
        super::super::blocklist::block(&blocked);
        fan_out(&ws, &local, Roster::new(&local), std::iter::empty(), &me.db, &me.pass);
        super::super::blocklist::unblock(&blocked);
        let mut joined = Vec::new();
        while let Ok(cmd) = ws_rx.try_recv() {
            if let WsCommand::JoinRoom { room_code } = cmd {
                joined.push(room_code);
            }
        }
        assert!(joined.contains(&super::super::dm_room::dm_room_code(&local, &friend)), "control: a friend's room");
        assert!(!joined.contains(&super::super::dm_room::dm_room_code(&local, &blocked)), "a blocked friend's room");
    }

    /// C-IDENTITY-09, each rule alone. A member another device of ours vouched is news,
    /// named with its voucher; a device this one vouched, one the upgrade admitted (even
    /// with a vouch), one no vouch admitted, and anything while this device was not a
    /// member yet are not.
    #[test]
    fn only_a_siblings_vouch_is_news_to_our_other_devices() {
        let (master, me, p) = (kp(0x01).peer_id(), kp(0x02), kp(0x03));
        let [n, q, u, x] = [0x04, 0x05, 0x06, 0x07].map(|t| kp(t).peer_id());
        let mut r = Roster::new(&master);
        r.add_vouch(sign_vouch(&p, &master, LEGACY_BASE, &n));
        r.add_vouch(sign_vouch(&me, &master, LEGACY_BASE, &q));
        r.add_vouch(sign_vouch(&p, &master, LEGACY_BASE, &u));
        let state = |members: &[&str]| RosterState {
            base: LEGACY_BASE.into(),
            members: members.iter().map(|d| d.to_string()).collect(),
            ..Default::default()
        };
        let (me_id, p_id) = (me.peer_id(), p.peer_id());
        let prev = state(&[&me_id, &p_id]);
        let now = state(&[&me_id, &p_id, &n, &q, &u, &x]);
        let upgrade = BTreeSet::from([u.clone()]);
        assert_eq!(added_by_another(&r, &prev, &now, &me_id, &upgrade), vec![(n.clone(), p_id.clone())]);
        assert_eq!(
            added_by_another(&r, &prev, &now, &me_id, &BTreeSet::new()).into_iter().collect::<BTreeSet<_>>(),
            BTreeSet::from([(n.clone(), p_id.clone()), (u.clone(), p_id.clone())]),
            "control: without the upgrade the vouched device is news",
        );
        let joining = state(&[&p_id]);
        assert!(
            added_by_another(&r, &joining, &now, &me_id, &upgrade).is_empty(),
            "a device that just joined was told about itself or what came before it",
        );
        let other_base = RosterState { base: "f".repeat(32), ..now.clone() };
        assert!(added_by_another(&r, &prev, &other_base, &me_id, &upgrade).is_empty(), "a vouch from another base");
    }

    /// HOL-SEC-215 (R-ID-14): a roster `me` holds rooted by the phrase, and the same
    /// with `then` added, as this device folds them.
    fn phrase_case(then: impl FnOnce(&mut Roster, &NativeKeypair, &NativeKeypair)) -> (Roster, RosterState, RosterState, String) {
        let (master, recovery, me) = (kp(0x11), kp(0x12), kp(0x13));
        let at = now_ms() - 60_000;
        let mut r = Roster::genesis(&master, &recovery, &me, at);
        let prev = r.verified(now_ms()).fold(|_| None, now_ms());
        then(&mut r, &master, &recovery);
        let now = r.verified(now_ms()).fold(|_| None, now_ms());
        (r, prev, now, me.peer_id())
    }

    #[test]
    fn a_device_the_phrase_admits_alerts_our_other_devices() {
        let f = kp(0x14);
        let (r, prev, now, me) = phrase_case(|r, master, recovery| {
            r.add_consent(sign_consent(&f, &master.peer_id()));
            let pa = roster::sign_phrase_admit(master, recovery, now_ms() - 1_000, &f.peer_id());
            r.add_phrase_statement(&roster::r_pub_of(recovery), None, Some(pa)).unwrap();
        });
        assert!(now.is_member(&f.peer_id()), "precondition: the phrase admits F");
        assert_eq!(added_by_another(&r, &prev, &now, &me, &BTreeSet::new()), vec![(f.peer_id(), "phrase".to_string())]);
    }

    #[test]
    fn a_device_a_recovery_keeps_alerts_our_other_devices() {
        let f = kp(0x14);
        let me_id = kp(0x13).peer_id();
        let (r, prev, now, me) = phrase_case(|r, master, recovery| {
            r.add_consent(sign_consent(&f, &master.peer_id()));
            let rec = roster::sign_recovery(master, recovery, now_ms() - 1_000, &[me_id.clone(), f.peer_id()], false);
            r.add_phrase_statement(&roster::r_pub_of(recovery), Some(rec), None).unwrap();
        });
        assert!(now.is_member(&f.peer_id()) && now.is_member(&me), "precondition: the recovery keeps both");
        assert_eq!(added_by_another(&r, &prev, &now, &me, &BTreeSet::new()), vec![(f.peer_id(), "phrase".to_string())]);
    }

    /// The admitted device learns of its own admission as a new member: it was not one
    /// before, so it alerts nothing (the prev rule covers "not this device").
    #[test]
    fn the_device_the_phrase_admitted_alerts_nothing_about_itself() {
        let f = kp(0x14);
        let (r, _, now, _) = phrase_case(|r, master, recovery| {
            r.add_consent(sign_consent(&f, &master.peer_id()));
            let pa = roster::sign_phrase_admit(master, recovery, now_ms() - 1_000, &f.peer_id());
            r.add_phrase_statement(&roster::r_pub_of(recovery), None, Some(pa)).unwrap();
        });
        let before_f = RosterState { members: now.members.iter().filter(|d| **d != f.peer_id()).cloned().collect(), ..now.clone() };
        assert!(added_by_another(&r, &before_f, &now, &f.peer_id(), &BTreeSet::new()).is_empty());
    }

    /// A Welcome admission into an empty store (phrase restore, No branch): the first
    /// roster it learns from its siblings brings an older base. The devices that base
    /// keeps or vouched for were the identity before this device joined, never news; a
    /// phrase admission after ours still is.
    #[test]
    fn a_base_older_than_our_own_admission_is_no_news() {
        let (master, recovery, old, me) = (kp(0x11), kp(0x12), kp(0x13), kp(0x14));
        let (linked, later) = (kp(0x15), kp(0x16));
        let mut theirs = Roster::genesis(&master, &recovery, &old, now_ms() - 60_000);
        let base = theirs.verified(now_ms()).fold(|_| None, now_ms()).base;
        theirs.add_consent(sign_consent(&linked, &master.peer_id()));
        theirs.add_vouch(sign_vouch(&old, &master.peer_id(), &base, &linked.peer_id()));
        let mut ours = Roster::new(&master.peer_id());
        ours.add_consent(sign_consent(&me, &master.peer_id()));
        let pa = roster::sign_phrase_admit(&master, &recovery, now_ms() - 10_000, &me.peer_id());
        ours.add_phrase_statement(&roster::r_pub_of(&recovery), None, Some(pa)).unwrap();
        let prev = ours.verified(now_ms()).fold(|_| None, now_ms());
        assert!(prev.is_member(&me.peer_id()), "precondition: the phrase admits this install");
        let mut merged = ours.merged(&theirs);
        let now = merged.verified(now_ms()).fold(|_| None, now_ms());
        assert!(now.is_member(&old.peer_id()) && now.is_member(&linked.peer_id()) && now.is_member(&me.peer_id()), "precondition");
        assert!(added_by_another(&merged, &prev, &now, &me.peer_id(), &BTreeSet::new()).is_empty());

        merged.add_consent(sign_consent(&later, &master.peer_id()));
        let pa = roster::sign_phrase_admit(&master, &recovery, now_ms() - 1_000, &later.peer_id());
        merged.add_phrase_statement(&roster::r_pub_of(&recovery), None, Some(pa)).unwrap();
        let after = merged.verified(now_ms()).fold(|_| None, now_ms());
        assert!(after.is_member(&later.peer_id()), "precondition: a later admission");
        assert_eq!(
            added_by_another(&merged, &prev, &after, &me.peer_id(), &BTreeSet::new()),
            vec![(later.peer_id(), "phrase".to_string())],
            "a phrase admission after ours is news even in the base we first learn",
        );

        let fresh = kp(0x17);
        merged.add_consent(sign_consent(&fresh, &master.peer_id()));
        merged.add_vouch(sign_vouch(&old, &master.peer_id(), &base, &fresh.peer_id()));
        let vouched = merged.verified(now_ms()).fold(|_| None, now_ms());
        assert_eq!(
            added_by_another(&merged, &after, &vouched, &me.peer_id(), &BTreeSet::new()),
            vec![(fresh.peer_id(), old.peer_id())],
            "once the base is known, a sibling's vouch is news again",
        );

        let kept = kp(0x18);
        merged.add_consent(sign_consent(&kept, &master.peer_id()));
        let rec = roster::sign_recovery(&master, &recovery, now_ms() - 500, &[me.peer_id(), kept.peer_id()], false);
        merged.add_phrase_statement(&roster::r_pub_of(&recovery), Some(rec), None).unwrap();
        let recovered = merged.verified(now_ms()).fold(|_| None, now_ms());
        assert!(recovered.is_member(&kept.peer_id()) && recovered.base != vouched.base, "precondition: a newer base keeps it");
        assert_eq!(
            added_by_another(&merged, &vouched, &recovered, &me.peer_id(), &BTreeSet::new()),
            vec![(kept.peer_id(), "phrase".to_string())],
            "a recovery after our admission is news",
        );
    }

    #[test]
    fn an_upgrade_admission_still_alerts_nothing() {
        let f = kp(0x14);
        let (r, prev, now, me) = phrase_case(|r, master, recovery| {
            r.add_consent(sign_consent(&f, &master.peer_id()));
            let pa = roster::sign_phrase_admit(master, recovery, now_ms() - 1_000, &f.peer_id());
            r.add_phrase_statement(&roster::r_pub_of(recovery), None, Some(pa)).unwrap();
        });
        assert!(added_by_another(&r, &prev, &now, &me, &BTreeSet::from([f.peer_id()])).is_empty());
    }

    /// C-IDENTITY-09. The ingest records the alert once with who added the device, tells
    /// the UI, and a re-ingest of the same roster records nothing more.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_siblings_vouch_is_recorded_once_on_ingest() {
        let _g = guard();
        let mut me = Observer::new(0x01, 0x02);
        let recovery = kp(0x03);
        write_bootstrap(&me.dir(), &Roster::genesis(&me.master, &recovery, &me.device, now_ms())).unwrap();
        me.own();
        let (sibling, added) = (kp(0x04), kp(0x05));
        let own = me.master.peer_id();
        // The sibling joined through this device; then it linked a device of its own.
        vouch(&me.master, &me.device, &sibling.peer_id(), &me.db, &me.pass).unwrap();
        let mut roster = own_of(&me).0;
        roster.add_consent(sign_consent(&sibling, &own));
        me.ingest(&sibling.peer_id(), &roster).await;
        let none = |me: &Observer| {
            me.store().get_security_alerts().unwrap().into_iter().filter(|a| a.kind == super::super::security_alerts::KIND_OWN_DEVICE_ADDED).count()
        };
        assert_eq!(none(&me), 0, "this device's own link was news to it");
        roster.add_vouch(sign_vouch(&sibling, &own, &roster.base(), &added.peer_id()));
        roster.add_consent(sign_consent(&added, &own));
        me.drain();
        me.ingest(&sibling.peer_id(), &roster).await;
        let detail = format!("{}:{}", added.peer_id(), sibling.peer_id());
        let alerts = me.store().get_security_alerts().unwrap();
        assert!(alerts.iter().any(|a| a.peer_id == own && a.kind == super::super::security_alerts::KIND_OWN_DEVICE_ADDED && a.detail == detail));
        assert!(me.drain().iter().any(|e| matches!(e, NetworkEvent::SecurityAlert { detail: d, .. } if *d == detail)));
        me.ingest(&sibling.peer_id(), &roster).await;
        assert_eq!(none(&me), 1, "a re-ingest recorded it again");
        assert!(!me.drain().iter().any(|e| matches!(e, NetworkEvent::SecurityAlert { .. })), "a re-ingest told the UI again");
    }

    /// C-IDENTITY-09. A device the 0.11 upgrade admitted is no news even when another
    /// device of ours also vouched for it: the upgrade's admissions are fed to the rule
    /// at the ingest, not only checked by it.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn an_upgrade_admission_is_no_news_even_with_a_vouch() {
        let _g = guard();
        let (s, t) = (kp(0x03), kp(0x04));
        let me = legacy_device(0x02, &[&kp(0x02).peer_id(), &s.peer_id(), &t.peer_id()], &[], true);
        let own = me.master.peer_id();
        let (mut roster, state) = me.own();
        assert!(state.protected && state.is_member(&me.device.peer_id()), "{state:?}");
        roster.add_consent(sign_consent(&t, &own));
        roster.add_consent(sign_consent(&s, &own));
        roster.add_vouch(sign_vouch(&t, &own, &roster.base(), &s.peer_id()));
        me.ingest(&t.peer_id(), &roster).await;
        assert!(me.state_of(&own).is_member(&s.peer_id()), "control: the upgrade admitted s");
        let news: Vec<_> = me
            .store()
            .get_security_alerts()
            .unwrap()
            .into_iter()
            .filter(|a| a.kind == super::super::security_alerts::KIND_OWN_DEVICE_ADDED)
            .collect();
        assert!(news.is_empty(), "an upgrade admission with a vouch was news: {news:?}");
    }

    /// C-IDENTITY-16 at the ingest: an ask this node saw first keeps its slot when a
    /// flood of asks under lower ids arrives, and keeps maturing on its clock.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn an_ingested_flood_keeps_the_ask_this_node_saw_first() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (bob, bob_r, bob_dev, real) = (kp(0x60), kp(0x64), kp(0x61), kp(0x62));
        let mut r = Roster::genesis(&bob, &bob_r, &bob_dev, now_ms() - 60_000);
        me.ingest(&bob_dev.peer_id(), &r).await;
        r.add_consent(sign_consent(&real, &bob.peer_id()));
        r.add_pending(sign_pending(&bob, &r.base(), &real.peer_id()));
        me.ingest(&real.peer_id(), &r).await;
        let mut flood = r.clone();
        flood.pendings.clear();
        for i in 0u32.. {
            if flood.pendings.len() == roster::MAX_PENDING {
                break;
            }
            let mut seed = [0x6bu8; 32];
            seed[..4].copy_from_slice(&i.to_le_bytes());
            let j = NativeKeypair::from_secret_bytes(&seed);
            if j.peer_id() < real.peer_id() {
                flood.add_consent(sign_consent(&j, &bob.peer_id()));
                flood.add_pending(sign_pending(&bob, &r.base(), &j.peer_id()));
            }
        }
        me.ingest(&bob_dev.peer_id(), &flood).await;
        let held = load(&me.store(), &bob.peer_id()).unwrap();
        assert!(held.pendings.iter().any(|p| p.device == real.peer_id()), "a later flood pushed out the ask seen first");
        assert_eq!(held.pendings.len(), roster::MAX_PENDING);
        me.store().set_roster_seen(&bob.peer_id(), &r.base(), &real.peer_id(), now_ms() - PENDING_MATURITY_MS).unwrap();
        assert!(me.state_of(&bob.peer_id()).is_member(&real.peer_id()), "the ask seen first never matured");
    }

    /// A friend's roster one of our own devices shares counts on first sight only from
    /// that device, only for an accepted friend, and only for the statements that
    /// verify: the sibling picks no member and plants no stranger.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn authz_a_sibling_shares_only_a_friends_roster_and_only_what_verifies() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let sibling = kp(0x03);
        super::super::resolver::seed_self(&me.master.peer_id(), &[me.device.peer_id(), sibling.peer_id()]);
        let (bob, bob_dev, mallory, carrier) = (kp(0x60), kp(0x61), kp(0x62), kp(0x70));
        let bob_id = bob.peer_id();
        let real = Roster::legacy_for_test(&bob, &[&bob_dev]);
        let shared = async |from: &str, roster: &Roster| {
            ingest_friend_roster_from_sibling(
                &me.events, &me.ws, &me.master.peer_id(), &me.device.peer_id(), from, roster.clone(), &me.db, &me.pass,
            )
            .await
        };

        shared(&sibling.peer_id(), &real).await;
        assert!(load(&me.store(), &bob_id).is_none(), "a sibling planted a roster for someone who is not our friend");

        me.store().save_friend(&bob_id, "accepted", "", 1).unwrap();
        let removed = kp(0x04);
        super::super::resolver::seed_self(&me.master.peer_id(), &[me.device.peer_id(), sibling.peer_id(), removed.peer_id()]);
        super::super::resolver::mark_revoked(&[removed.peer_id()]);
        for not_ours in [carrier.peer_id(), me.master.peer_id(), me.device.peer_id(), removed.peer_id()] {
            shared(&not_ours, &real).await;
            assert!(load(&me.store(), &bob_id).is_none(), "{not_ours}, not one of our other devices, planted a friend's roster");
        }

        // Mallory's statements under Bob's name: none verifies, so nobody joins Bob.
        let mut forged = Roster::legacy_for_test(&mallory, &[&kp(0x63)]);
        forged.master = bob_id.clone();
        shared(&sibling.peer_id(), &forged).await;
        assert!(me.state_of(&bob_id).members.is_empty(), "a forged roster made a member");

        shared(&sibling.peer_id(), &real).await;
        assert!(me.state_of(&bob_id).is_member(&bob_dev.peer_id()), "our sibling's copy of a friend's roster never counted");
        assert_eq!(super::super::resolver::resolve(&bob_dev.peer_id()), bob_id, "the friend's device is still not placed");
        shared(&sibling.peer_id(), &forged).await;
        assert_eq!(me.state_of(&bob_id).members.len(), 1, "a forged roster added to the held one");
    }

    /// F1 (wave md), through real ingests: an MLS add of a device Bob's roster here does
    /// not list waits, a forged roster naming it changes nothing, Bob's own vouch lets it
    /// pass, and once his roster removes it the add is refused for good.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn an_mls_add_waits_for_a_genuine_roster_and_a_removal_refuses_it() {
        use super::super::mls_authority::{commit_verdict, GroupRules};
        use crate::crypto::{CommitFacts, LeafIdentity, LeafView, Verdict};
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (bob, bob_dev, linked, mallory) = (kp(0x60), kp(0x61), kp(0x62), kp(0x50));
        let bob_id = bob.peer_id();
        let mut r = Roster::legacy_for_test(&bob, &[&bob_dev]);
        me.ingest(&bob_dev.peer_id(), &r).await;

        let mut state = crate::crdt::server_state::ServerState::new("s1".into(), "s".into(), "owner".into());
        for m in ["owner", bob_id.as_str()] {
            state.members.insert(m.into(), crate::crdt::server_state::MemberInfo { peer_id: m.into(), display_name: m.into() });
        }
        let leaf = |d: &str, m: &str| LeafView::Bound(LeafIdentity { device: d.into(), master: m.into() });
        let add = CommitFacts {
            committer: Some(leaf("owner-d", "owner")),
            adds: vec![leaf(&linked.peer_id(), &bob_id)],
            ..Default::default()
        };
        let verdict = || commit_verdict(&add, &GroupRules::Server { state: &state, channel: None });
        assert!(matches!(verdict(), Verdict::Hold(_)), "{:?}", verdict());

        let mut forged = Roster::legacy_for_test(&mallory, &[&linked]);
        forged.master = bob_id.clone();
        me.ingest(&linked.peer_id(), &forged).await;
        assert!(matches!(verdict(), Verdict::Hold(_)), "a forged roster unlocked the add: {:?}", verdict());

        r.add_consent(sign_consent(&linked, &bob_id));
        r.add_vouch(sign_vouch(&bob_dev, &bob_id, LEGACY_BASE, &linked.peer_id()));
        me.ingest(&linked.peer_id(), &r).await;
        assert_eq!(verdict(), Verdict::Accept, "Bob's own roster places it");

        r.add_removal(sign_removal(&bob_dev, &bob_id, LEGACY_BASE, &linked.peer_id(), &[]));
        me.ingest(&bob_dev.peer_id(), &r).await;
        assert!(matches!(verdict(), Verdict::Refuse(_)), "the add of a removed device: {:?}", verdict());
    }

    /// (detail, read, resolved) of every alert of `kind` about `peer`.
    fn alert_details(me: &Observer, peer: &str, kind: &str) -> BTreeSet<(String, bool, bool)> {
        me.store()
            .get_security_alerts()
            .unwrap()
            .into_iter()
            .filter(|a| a.peer_id == peer && a.kind == kind)
            .map(|a| (a.detail, a.acknowledged_at.is_some(), a.resolved_at.is_some()))
            .collect()
    }

    /// B3 (d). A contact's "added a new device" warning is marked removed once that
    /// device leaves, live and through the push fetch's store-only ingest, and stays until
    /// the person reads it; one already read keeps its read mark; a member's warning is
    /// untouched; a device a recovery brings back warns again.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn g13c_a_contacts_new_device_alert_is_marked_removed_and_stays() {
        use super::super::security_alerts::KIND_NEW_DEVICE;
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (bob, bob_dev, bob_rec) = (kp(0x60), kp(0x61), kp(0x66));
        let [gone, dismissed, stays, fetched] = [kp(0x62), kp(0x63), kp(0x64), kp(0x65)];
        let bob_id = bob.peer_id();
        let mut r = Roster::legacy_for_test(&bob, &[&bob_dev]);
        me.ingest(&bob_dev.peer_id(), &r).await;
        for d in [&gone, &dismissed, &stays, &fetched] {
            r.add_consent(sign_consent(d, &bob_id));
            r.add_vouch(sign_vouch(&bob_dev, &bob_id, LEGACY_BASE, &d.peer_id()));
        }
        me.ingest(&bob_dev.peer_id(), &r).await;
        let ids = [&gone, &dismissed, &stays, &fetched].map(|d| d.peer_id());
        assert_eq!(
            alert_details(&me, &bob_id, KIND_NEW_DEVICE),
            ids.iter().map(|d| (d.clone(), false, false)).collect(),
            "precondition: each new device warned once",
        );
        me.store().acknowledge_security_alert(&format!("{KIND_NEW_DEVICE}:{bob_id}:{}", ids[1])).unwrap();

        for d in [&gone, &dismissed] {
            r.add_removal(sign_removal(&bob_dev, &bob_id, LEGACY_BASE, &d.peer_id(), &[]));
        }
        me.ingest(&bob_dev.peer_id(), &r).await;
        assert_eq!(
            alert_details(&me, &bob_id, KIND_NEW_DEVICE),
            BTreeSet::from([
                (ids[0].clone(), false, true),
                (ids[1].clone(), true, true),
                (ids[2].clone(), false, false),
                (ids[3].clone(), false, false),
            ]),
            "a removed device's warning was not marked, went away, or was read for the person",
        );

        r.add_removal(sign_removal(&bob_dev, &bob_id, LEGACY_BASE, &ids[3], &[]));
        assert!(ingest_stored(&me.db, &me.pass, &me.master.peer_id(), &me.device.peer_id(), &bob_dev.peer_id(), r.clone()));
        assert!(
            alert_details(&me, &bob_id, KIND_NEW_DEVICE).contains(&(ids[3].clone(), false, true)),
            "the push fetch left a removed device's warning unmarked",
        );

        // Bob's phrase starts a base that keeps the device he removed: it warns again.
        r.add_phrase_statement(
            &crate::identity::roster::r_pub_of(&bob_rec),
            Some(crate::identity::roster::sign_recovery(&bob, &bob_rec, now_ms(), &[bob_dev.peer_id(), ids[0].clone()], false)),
            None,
        )
        .unwrap();
        me.ingest(&bob_dev.peer_id(), &r).await;
        assert!(me.state_of(&bob_id).is_member(&ids[0]), "precondition: the recovery brought it back");
        assert!(
            alert_details(&me, &bob_id, KIND_NEW_DEVICE).contains(&(ids[0].clone(), false, false)),
            "a device back after its removal did not warn again",
        );
    }

    /// B3 (d). "A sibling added a device": once a SIBLING removes that device the alert
    /// is marked removed and stays unread (a stolen device may add one and remove it
    /// again); once THIS device removes it, the person acted here and it is read.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn g13c_an_own_device_alert_is_marked_removed_and_read_only_here() {
        use super::super::security_alerts::KIND_OWN_DEVICE_ADDED;
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let recovery = kp(0x03);
        write_bootstrap(&me.dir(), &Roster::genesis(&me.master, &recovery, &me.device, now_ms())).unwrap();
        me.own();
        let (sibling, by_sibling, by_me) = (kp(0x04), kp(0x05), kp(0x06));
        let own = me.master.peer_id();
        vouch(&me.master, &me.device, &sibling.peer_id(), &me.db, &me.pass).unwrap();
        let mut roster = own_of(&me).0;
        roster.add_consent(sign_consent(&sibling, &own));
        for d in [&by_sibling, &by_me] {
            roster.add_vouch(sign_vouch(&sibling, &own, &roster.base(), &d.peer_id()));
            roster.add_consent(sign_consent(d, &own));
        }
        me.ingest(&sibling.peer_id(), &roster).await;
        let detail = |d: &NativeKeypair| format!("{}:{}", d.peer_id(), sibling.peer_id());
        assert_eq!(
            alert_details(&me, &own, KIND_OWN_DEVICE_ADDED),
            BTreeSet::from([(detail(&by_sibling), false, false), (detail(&by_me), false, false)]),
            "precondition: both added devices were news",
        );

        roster = own_of(&me).0;
        roster.add_removal(sign_removal(&sibling, &own, &roster.base(), &by_sibling.peer_id(), &[]));
        me.ingest(&sibling.peer_id(), &roster).await;
        assert_eq!(
            alert_details(&me, &own, KIND_OWN_DEVICE_ADDED),
            BTreeSet::from([(detail(&by_sibling), false, true), (detail(&by_me), false, false)]),
            "a sibling's removal erased, read or left unmarked the alert about the device it removed",
        );

        remove(&me.master, &me.device, &by_me.peer_id(), RemoveMode::Retire, false, &me.db, &me.pass).unwrap();
        assert_eq!(
            alert_details(&me, &own, KIND_OWN_DEVICE_ADDED),
            BTreeSet::from([(detail(&by_sibling), false, true), (detail(&by_me), true, true)]),
            "this device's own removal left the alert about the device it removed unread",
        );
    }

    impl Observer {
        async fn carry(&self, sender: &NativeKeypair, master: &str, rm: &[Removal]) -> Ingested {
            ingest_carried(
                &self.events, &self.ws, &self.master.peer_id(), &self.device.peer_id(),
                &sender.peer_id(), master, rm, &self.db, &self.pass,
            )
            .await
        }
    }

    /// F2. Removals a DM carried are judged as any removal: each verifies alone for the
    /// DM's identity, only from a current member of a roster we already hold, never our
    /// own, never over the bound; the signer must stand in the merged roster; a part
    /// never confirms its sender's view of the roster.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn g13c_a_carried_removal_is_judged_as_any_removal() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        me.own();
        let (bob, bob_dev, dev2, linked, junk) = (kp(0x60), kp(0x61), kp(0x62), kp(0x63), kp(0x64));
        let bob_id = bob.peer_id();
        let mut r = Roster::legacy_for_test(&bob, &[&bob_dev, &dev2]);
        r.add_consent(sign_consent(&linked, &bob_id));
        r.add_vouch(sign_vouch(&bob_dev, &bob_id, LEGACY_BASE, &linked.peer_id()));
        me.ingest(&bob_dev.peer_id(), &r).await;
        assert!(me.state_of(&bob_id).is_member(&linked.peer_id()), "precondition");
        let _ = me.store().unconfirm_roster(&bob_id, &bob_dev.peer_id(), 1);
        let of_linked = |by: &NativeKeypair, master: &str| sign_removal(by, master, LEGACY_BASE, &linked.peer_id(), &[]);
        let me_id = me.master.peer_id();

        // Refused before any fold.
        let nine: Vec<Removal> = (0..9).map(|i| sign_removal(&bob_dev, &bob_id, LEGACY_BASE, &kp(0x70 + i).peer_id(), &[])).collect();
        assert!(carried_roster(&me_id, &bob_dev.peer_id(), &bob_id, &nine).is_none(), "a carry over the bound");
        assert!(carried_roster(&me_id, &junk.peer_id(), &bob_id, &[of_linked(&bob_dev, &bob_id)]).is_none(), "a sender not of the identity");
        let own_dev = me.device.peer_id();
        assert!(super::super::resolver::is_device_of(&own_dev, &me_id), "precondition: our own device is ours");
        assert!(carried_roster(&me_id, &own_dev, &me_id, &[of_linked(&bob_dev, &me_id)]).is_none(), "our own roster");
        assert!(carried_roster(&me_id, &bob_dev.peer_id(), &bob_id, &[of_linked(&bob_dev, &kp(0x65).peer_id())]).is_none(), "a statement for another identity");

        // Verifies alone, but its signer stands nowhere in Bob's roster.
        me.carry(&bob_dev, &bob_id, &[of_linked(&junk, &bob_id)]).await;
        assert!(me.state_of(&bob_id).is_member(&linked.peer_id()), "a removal from a signer without standing counted");

        // The real one.
        let out = me.carry(&bob_dev, &bob_id, &[of_linked(&bob_dev, &bob_id)]).await;
        assert_eq!(out.newly_revoked, vec![linked.peer_id()], "a counting carried removal did not revoke");
        assert!(super::super::resolver::is_revoked(&linked.peer_id()));
        assert_eq!(
            me.store().roster_confirmed_at(&bob_id, &bob_dev.peer_id()),
            Some(0),
            "a part of a roster confirmed its sender's view of all of it",
        );

        // A revoked sender is heard no more.
        assert!(carried_roster(&me_id, &linked.peer_id(), &bob_id, &[of_linked(&bob_dev, &bob_id)]).is_none(), "a removed sender");

        // Nothing gives first sight, not even of an identity whose only row is one a
        // roster cannot read (a 0.11 device list): its devices are not ours to drop.
        let (carol, carol_dev) = (kp(0x66), kp(0x67));
        let carol_id = carol.peer_id();
        let legacy = super::super::types::SignedDeviceList {
            master_peer_id: carol_id.clone(),
            devices: vec![carol_dev.peer_id()],
            ..Default::default()
        };
        me.store().save_device_list(&carol_id, &serde_json::to_string(&legacy).unwrap(), 0, &[carol_dev.peer_id()], 1).unwrap();
        super::super::resolver::update_many(&carol_id, [carol_dev.peer_id().as_str()]);
        assert!(load(&me.store(), &carol_id).is_none() && me.store().load_device_list(&carol_id).unwrap().is_some(), "precondition");
        me.carry(&carol_dev, &carol_id, &[sign_removal(&carol_dev, &carol_id, LEGACY_BASE, &kp(0x68).peer_id(), &[])]).await;
        assert!(load(&me.store(), &carol_id).is_none(), "a carried part gave first sight of an identity");
        assert!(super::super::resolver::is_device_of(&carol_dev.peer_id(), &carol_id), "a carried part dropped a known device");
    }

    /// F2, HOL-SEC-080 through a carry: a removed voucher keeps only the devices EVERY
    /// removal of it keeps, so a carried removal keeping fewer narrows what one we held kept.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn g13c_a_carried_removal_keeps_only_what_every_removal_keeps() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        me.own();
        let (bob, d1, d2, v, w) = (kp(0x60), kp(0x61), kp(0x62), kp(0x63), kp(0x64));
        let bob_id = bob.peer_id();
        let mut r = Roster::legacy_for_test(&bob, &[&d1, &d2]);
        for d in [&v, &w] {
            r.add_consent(sign_consent(d, &bob_id));
        }
        r.add_vouch(sign_vouch(&d2, &bob_id, LEGACY_BASE, &v.peer_id()));
        r.add_vouch(sign_vouch(&v, &bob_id, LEGACY_BASE, &w.peer_id()));
        r.add_removal(sign_removal(&d1, &bob_id, LEGACY_BASE, &v.peer_id(), &[w.peer_id()]));
        me.ingest(&d1.peer_id(), &r).await;
        assert!(me.state_of(&bob_id).is_member(&w.peer_id()), "precondition: the one removal we hold keeps w");
        me.carry(&d2, &bob_id, &[sign_removal(&d2, &bob_id, LEGACY_BASE, &v.peer_id(), &[])]).await;
        assert!(!me.state_of(&bob_id).is_member(&w.peer_id()), "HOL-SEC-080: w kept by one removal of v only");
    }

    /// F2, the push fetch twin: the store half keeps the removal and tells the running
    /// app to re-read that identity.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn g13c_the_push_fetch_keeps_a_carried_removal_and_marks_it_for_the_app() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        me.own();
        let (bob, bob_dev, linked) = (kp(0x60), kp(0x61), kp(0x63));
        let bob_id = bob.peer_id();
        let mut r = Roster::legacy_for_test(&bob, &[&bob_dev]);
        r.add_consent(sign_consent(&linked, &bob_id));
        r.add_vouch(sign_vouch(&bob_dev, &bob_id, LEGACY_BASE, &linked.peer_id()));
        me.ingest(&bob_dev.peer_id(), &r).await;
        let rm = [sign_removal(&bob_dev, &bob_id, LEGACY_BASE, &linked.peer_id(), &[])];
        assert!(ingest_carried_stored(&me.db, &me.pass, &me.master.peer_id(), &me.device.peer_id(), &bob_dev.peer_id(), &bob_id, &rm));
        assert!(me.store().get_all_revoked_devices().unwrap().contains(&linked.peer_id()), "the fetch lost the removal");
        assert_eq!(me.store().take_roster_dirty(None), vec![bob_id.clone()], "the running app was not told to re-read");
    }

    /// Review LOW-4. A fold whose COMMIT fails leaves the process-global resolver as it
    /// was: memory never runs ahead of what is on disk.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn g13c_a_fold_that_fails_to_commit_moves_no_resolver() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        me.own();
        let (bob, bob_dev, linked) = (kp(0x60), kp(0x61), kp(0x63));
        let bob_id = bob.peer_id();
        let mut r = Roster::legacy_for_test(&bob, &[&bob_dev]);
        r.add_consent(sign_consent(&linked, &bob_id));
        r.add_vouch(sign_vouch(&bob_dev, &bob_id, LEGACY_BASE, &linked.peer_id()));
        me.ingest(&bob_dev.peer_id(), &r).await;
        assert!(super::super::resolver::is_device_of(&linked.peer_id(), &bob_id), "precondition");
        let rm = [sign_removal(&bob_dev, &bob_id, LEGACY_BASE, &linked.peer_id(), &[])];

        *FAIL_COMMIT.lock().unwrap() = Some(me.db.clone());
        let (me_master, me_dev) = (me.master.peer_id(), me.device.peer_id());
        assert!(!ingest_carried_stored(&me.db, &me.pass, &me_master, &me_dev, &bob_dev.peer_id(), &bob_id, &rm));
        assert!(
            super::super::resolver::is_device_of(&linked.peer_id(), &bob_id) && !super::super::resolver::is_revoked(&linked.peer_id()),
            "a fold that never reached the disk moved the resolver",
        );
        assert!(!me.store().get_all_revoked_devices().unwrap().contains(&linked.peer_id()), "precondition: rolled back");

        assert!(ingest_carried_stored(&me.db, &me.pass, &me_master, &me_dev, &bob_dev.peer_id(), &bob_id, &rm));
        assert!(super::super::resolver::is_revoked(&linked.peer_id()), "control: the same fold lands once it commits");
    }

    /// F2. Our own removal is dated when this device learns it, not at its next DM, so
    /// a contact that confirmed our roster in between is judged against the right time.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn g13c_our_removal_is_dated_when_we_learn_it() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let recovery = kp(0x03);
        write_bootstrap(&me.dir(), &Roster::genesis(&me.master, &recovery, &me.device, now_ms())).unwrap();
        me.own();
        let other = kp(0x04);
        vouch(&me.master, &me.device, &other.peer_id(), &me.db, &me.pass).unwrap();
        let mut roster = own_of(&me).0;
        roster.add_consent(sign_consent(&other, &me.master.peer_id()));
        me.ingest(&other.peer_id(), &roster).await;
        let before = now_ms();
        let (_, state, _) = remove(&me.master, &me.device, &other.peer_id(), RemoveMode::Retire, false, &me.db, &me.pass).unwrap();
        let later = before + 60_000;
        let since = me
            .store()
            .removal_carried_since(&me.master.peer_id(), &state.base, &[other.peer_id()], later)
            .unwrap();
        assert!(
            since.get(&other.peer_id()).is_some_and(|at| *at >= before && *at < later),
            "our removal was not dated when we made it: {since:?}",
        );
    }

    /// A device key removed from one identity that consents into another stays refused
    /// for the first: each identity lifts only the refusals its own roster made, so the
    /// order rosters save in never decides, in memory or on disk.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn g13c_a_removed_device_joining_another_identity_stays_refused_for_its_old_one() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        me.own();
        let (bob, bob_dev, bob_rec, linked) = (kp(0x60), kp(0x61), kp(0x62), kp(0x63));
        let (carol, carol_dev) = (kp(0x70), kp(0x71));
        let (bob_id, carol_id, gone) = (bob.peer_id(), carol.peer_id(), linked.peer_id());
        let revoked_here = |me: &Observer| me.store().get_all_revoked_devices().unwrap().contains(&gone);
        let mut b = Roster::legacy_for_test(&bob, &[&bob_dev, &linked]);
        b.add_removal(sign_removal(&bob_dev, &bob_id, LEGACY_BASE, &gone, &[]));
        me.ingest(&bob_dev.peer_id(), &b).await;
        assert!(super::super::resolver::is_revoked(&gone) && revoked_here(&me), "precondition: Bob removed it");

        let mut c = Roster::legacy_for_test(&carol, &[&carol_dev, &linked]);
        me.ingest(&carol_dev.peer_id(), &c).await;
        assert!(me.state_of(&carol_id).is_member(&gone), "precondition: it stands in Carol's roster");
        assert!(super::super::resolver::is_revoked(&gone), "another identity's roster lifted Bob's refusal");
        assert!(revoked_here(&me), "another identity's roster erased Bob's refusal from the disk");
        super::super::resolver::clear_all();
        super::super::resolver::warm_from_store(&me.store());
        assert!(super::super::resolver::is_revoked(&gone), "Bob's refusal did not survive a restart");
        assert!(!super::super::resolver::is_device_of(&gone, &bob_id), "the removed device is Bob's again");

        // Both refuse it; Bob's phrase brings it back: Carol's refusal stands.
        c.add_removal(sign_removal(&carol_dev, &carol_id, LEGACY_BASE, &gone, &[]));
        me.ingest(&carol_dev.peer_id(), &c).await;
        b.add_phrase_statement(
            &crate::identity::roster::r_pub_of(&bob_rec),
            Some(crate::identity::roster::sign_recovery(&bob, &bob_rec, now_ms(), &[bob_dev.peer_id(), gone.clone()], false)),
            None,
        )
        .unwrap();
        me.ingest(&bob_dev.peer_id(), &b).await;
        assert!(me.state_of(&bob_id).is_member(&gone), "precondition: Bob's recovery brought it back");
        assert!(super::super::resolver::is_revoked(&gone), "Bob's recovery lifted Carol's refusal");
        assert!(revoked_here(&me), "Bob's recovery erased Carol's refusal from the disk");
        assert!(
            !super::super::resolver::is_revoked_by(&bob_id, &gone) && super::super::resolver::is_revoked_by(&carol_id, &gone),
            "Bob's recovery did not lift exactly Bob's own removal",
        );
        assert_eq!(me.store().revoked_marks().unwrap(), vec![(gone.clone(), carol_id.clone())], "the disk holds the wrong removals");
        super::super::resolver::clear_all();
        super::super::resolver::warm_from_store(&me.store());
        assert!(super::super::resolver::is_revoked(&gone), "Carol's refusal did not survive a restart");
    }

    // t14-ident removal modes

    /// Our phone links a laptop; the laptop removes x (seen long ago) and y (seen at T),
    /// and links tablet (just now) and pad (long ago), which linked watch (long ago);
    /// phone2 is linked by both and removed z, which our phone linked. T is ten minutes ago.
    struct Theft {
        me: Observer,
        laptop: NativeKeypair,
        x: NativeKeypair,
        y: NativeKeypair,
        tablet: NativeKeypair,
        pad: NativeKeypair,
        phone2: NativeKeypair,
        z: NativeKeypair,
        watch: NativeKeypair,
        t_ms: i64,
    }

    fn theft() -> Theft {
        let me = Observer::new(0x01, 0x02);
        write_bootstrap(&me.dir(), &Roster::genesis(&me.master, &kp(0x03), &me.device, now_ms() - 60_000)).unwrap();
        let (mut r, _) = me.own();
        let m = me.master.peer_id();
        let base = r.base();
        let (laptop, x, y, tablet, pad, phone2) = (kp(0x07), kp(0x08), kp(0x09), kp(0x0a), kp(0x0b), kp(0x0c));
        let (z, watch) = (kp(0x0d), kp(0x0e));
        for d in [&laptop, &x, &y, &tablet, &pad, &phone2, &z, &watch] {
            r.add_consent(sign_consent(d, &m));
        }
        for d in [&laptop, &x, &y, &phone2, &z] {
            r.add_vouch(roster::sign_vouch(&me.device, &m, &base, &d.peer_id()));
        }
        for d in [&tablet, &pad, &phone2] {
            r.add_vouch(roster::sign_vouch(&laptop, &m, &base, &d.peer_id()));
        }
        r.add_vouch(roster::sign_vouch(&pad, &m, &base, &watch.peer_id()));
        r.add_removal(roster::sign_removal(&phone2, &m, &base, &z.peer_id(), &[]));
        let rx = roster::sign_removal(&laptop, &m, &base, &x.peer_id(), &[]);
        r.add_removal(rx.clone());
        r.add_removal(roster::sign_removal(&laptop, &m, &base, &y.peer_id(), &[]));
        merge_for_test(&me.store(), &r, &m, &me.device.peer_id());
        let t_ms = now_ms() - 10 * 60_000;
        let long_ago = t_ms - 60 * 60_000;
        let store = me.store();
        store.set_roster_statement_first_seen(&m, &roster::removal_seen_key(&rx), long_ago).unwrap();
        let ry = r.removals.iter().find(|x| x.device == y.peer_id()).unwrap();
        // Seen exactly at T: not before it.
        store.set_roster_statement_first_seen(&m, &roster::removal_seen_key(ry), t_ms).unwrap();
        for (d, by) in [(&pad, &laptop), (&watch, &pad)] {
            let v = r.vouches.iter().find(|v| v.device == d.peer_id() && v.by == by.peer_id()).unwrap();
            store.set_roster_statement_first_seen(&m, &roster::vouch_seen_key(v), long_ago).unwrap();
        }
        Theft { me, laptop, x, y, tablet, pad, phone2, z, watch, t_ms }
    }

    fn re_signed_by(roster: &Roster, by: &NativeKeypair, target: &NativeKeypair) -> bool {
        roster.removals.iter().any(|r| r.by == by.peer_id() && r.device == target.peer_id())
    }

    /// I10 (N3): lost or stolen re-signs the laptop's removals seen before T only.
    #[test]
    fn lost_or_stolen_re_signs_only_removals_first_seen_before_t() {
        let _g = guard();
        let t = theft();
        let mode = RemoveMode::Lost { t_ms: t.t_ms };
        let (roster, _, _) = remove(&t.me.master, &t.me.device, &t.laptop.peer_id(), mode, false, &t.me.db, &t.me.pass).unwrap();
        assert!(re_signed_by(&roster, &t.me.device, &t.x), "x's removal from before T was not re-signed");
        assert!(!re_signed_by(&roster, &t.me.device, &t.y), "the thief's removal after T was re-signed");
        let auth = roster.authority();
        assert!(!auth.counts(&t.x.peer_id()) && auth.counts(&t.y.peer_id()), "x stays out, y comes back");
    }

    /// I10 (R3-5, R31-3): devices the thief linked after T go with it, named; older ones
    /// are offered with the toggle on; a device another device also holds is untouched.
    #[test]
    fn lost_or_stolen_drops_devices_the_thief_linked_after_t() {
        let _g = guard();
        let t = theft();
        let mode = RemoveMode::Lost { t_ms: t.t_ms };
        let (held, _) = t.me.own();
        let plan = removal_plan(&t.me.store(), &held, &t.me.device.peer_id(), &t.laptop.peer_id(), mode);
        assert_eq!(plan.forced, vec![t.tablet.peer_id()]);
        assert!(plan.optional_on);
        assert_eq!(
            plan.optional.iter().cloned().collect::<BTreeSet<_>>(),
            BTreeSet::from([t.pad.peer_id(), t.watch.peer_id()]),
            "watch, linked before T by pad, which the laptop linked before T, is offered, not forced",
        );
        let (roster, _, gone) = remove(&t.me.master, &t.me.device, &t.laptop.peer_id(), mode, false, &t.me.db, &t.me.pass).unwrap();
        assert_eq!(gone, vec![t.laptop.peer_id(), t.tablet.peer_id()]);
        let laptops = roster.removals.iter().find(|r| r.device == t.laptop.peer_id() && r.by == t.me.device.peer_id()).unwrap();
        assert!(laptops.keep_vouched.contains(&t.pad.peer_id()) && !laptops.keep_vouched.contains(&t.tablet.peer_id()));
        let auth = roster.authority();
        assert!(!auth.counts(&t.tablet.peer_id()) && auth.counts(&t.pad.peer_id()) && auth.counts(&t.phone2.peer_id()));
    }

    /// I10 (R31-3): phone2, which our phone also vouches, is never a vouchee here, even
    /// when the thief vouched it after T.
    #[test]
    fn lost_or_stolen_never_removes_a_device_the_thief_vouched_after_t_that_another_device_holds() {
        let _g = guard();
        let t = theft();
        let (held, _) = t.me.own();
        let plan = removal_plan(&t.me.store(), &held, &t.me.device.peer_id(), &t.laptop.peer_id(), RemoveMode::Lost { t_ms: t.t_ms });
        assert!(!plan.forced.contains(&t.phone2.peer_id()) && !plan.optional.contains(&t.phone2.peer_id()));
        let (roster, _, gone) =
            remove(&t.me.master, &t.me.device, &t.laptop.peer_id(), RemoveMode::Lost { t_ms: t.t_ms }, true, &t.me.db, &t.me.pass).unwrap();
        assert_eq!(
            gone.iter().cloned().collect::<BTreeSet<_>>(),
            BTreeSet::from([t.laptop.peer_id(), t.tablet.peer_id(), t.pad.peer_id(), t.watch.peer_id()]),
            "\"Remove them too\" takes the older ones",
        );
        assert_eq!(gone[0], t.laptop.peer_id());
        assert!(roster.authority().counts(&t.phone2.peer_id()));
    }

    /// The plan never names the device making it, even one only the target placed.
    #[test]
    fn a_removal_plan_never_takes_the_device_making_it() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let m = me.master.peer_id();
        let (first, laptop) = (kp(0x05), kp(0x07));
        let mut r = Roster::genesis(&me.master, &kp(0x03), &first, now_ms() - 60_000);
        let base = r.base();
        for d in [&laptop, &me.device] {
            r.add_consent(sign_consent(d, &m));
        }
        r.add_vouch(roster::sign_vouch(&first, &m, &base, &laptop.peer_id()));
        r.add_vouch(roster::sign_vouch(&laptop, &m, &base, &me.device.peer_id()));
        let r = r.reverified();
        assert!(r.authority().counts(&me.device.peer_id()), "setup: we count");
        for mode in [RemoveMode::Retire, RemoveMode::Lost { t_ms: now_ms() }] {
            let plan = removal_plan(&me.store(), &r, &me.device.peer_id(), &laptop.peer_id(), mode);
            assert!(plan.forced.is_empty() && plan.optional.is_empty(), "the plan names the device making it");
        }
    }

    /// The dialog's "not removed for servers yet": a removal by a device that a device
    /// closer to the phrase removed counts for nothing until the phrase is used.
    #[test]
    fn a_removal_by_a_removed_device_does_not_take_effect_for_servers() {
        let (master, first, me, target) = (kp(0x01), kp(0x05), kp(0x02), kp(0x07));
        let m = master.peer_id();
        let mut r = Roster::genesis(&master, &kp(0x03), &first, now_ms() - 60_000);
        let base = r.base();
        for d in [&me, &target] {
            r.add_consent(sign_consent(d, &m));
            r.add_vouch(roster::sign_vouch(&first, &m, &base, &d.peer_id()));
        }
        assert!(removal_takes_effect(&r.reverified(), &me, &target.peer_id()));
        r.add_removal(roster::sign_removal(&first, &m, &base, &me.peer_id(), &[]));
        assert!(!removal_takes_effect(&r.reverified(), &me, &target.peer_id()));
        r.add_removal(roster::sign_removal(&first, &m, &base, &target.peer_id(), &[]));
        assert!(removal_takes_effect(&r.reverified(), &me, &target.peer_id()), "already out: nothing waits for the phrase");
    }

    /// Both FFI calls read the person's answer the same way.
    #[test]
    fn the_lost_since_answer_picks_the_mode() {
        assert_eq!(RemoveMode::from_lost_since(None), RemoveMode::Retire);
        assert_eq!(RemoveMode::from_lost_since(Some(5)), RemoveMode::Lost { t_ms: 5 });
        assert_eq!(RemoveMode::from_lost_since(Some(-5)), RemoveMode::Lost { t_ms: 0 });
    }

    /// I11 (C3): retiring re-signs every removal of the retired device and removes none of
    /// its vouchees unless asked.
    #[test]
    fn retiring_re_signs_every_removal_of_the_retired_device() {
        let _g = guard();
        let t = theft();
        let (held, _) = t.me.own();
        let plan = removal_plan(&t.me.store(), &held, &t.me.device.peer_id(), &t.laptop.peer_id(), RemoveMode::Retire);
        assert!(plan.forced.is_empty() && !plan.optional_on && plan.optional.len() == 3);
        let (roster, _, gone) = remove(&t.me.master, &t.me.device, &t.laptop.peer_id(), RemoveMode::Retire, false, &t.me.db, &t.me.pass).unwrap();
        assert_eq!(gone, vec![t.laptop.peer_id()]);
        assert!(re_signed_by(&roster, &t.me.device, &t.x) && re_signed_by(&roster, &t.me.device, &t.y));
        assert!(!re_signed_by(&roster, &t.me.device, &t.z), "phone2's removal is phone2's, never re-signed here");
        let auth = roster.authority();
        assert!(!auth.counts(&t.x.peer_id()) && !auth.counts(&t.y.peer_id()) && auth.counts(&t.tablet.peer_id()));
    }

    /// I10 (LOW): a first sight outlives its statement for 30 days.
    #[test]
    fn a_roster_seen_row_outlives_its_statement_for_30_days() {
        let me = Observer::new(0x01, 0x02);
        let store = me.store();
        let m = me.master.peer_id();
        let (a, b) = ("aa".to_string(), "bb".to_string());
        let now = 1_800_000_000_000i64;
        store.note_roster_statements(&m, std::slice::from_ref(&a), now, SEEN_KEEP_MS, SEEN_CAP).unwrap();
        assert_eq!(store.roster_statement_first_seen(&m, &a), Some(now));
        store.note_roster_statements(&m, &[a.clone(), b.clone()], now + 5, SEEN_KEEP_MS, SEEN_CAP).unwrap();
        assert_eq!(store.roster_statement_first_seen(&m, &b), Some(now + 5));
        store.note_roster_statements(&m, std::slice::from_ref(&b), now + 10, SEEN_KEEP_MS, SEEN_CAP).unwrap();
        store.note_roster_statements(&m, std::slice::from_ref(&b), now + 10 + SEEN_KEEP_MS - 1, SEEN_KEEP_MS, SEEN_CAP).unwrap();
        assert_eq!(store.roster_statement_first_seen(&m, &a), Some(now), "dropped, kept for 30 days");
        store.note_roster_statements(&m, &[a.clone(), b.clone()], now + 20, SEEN_KEEP_MS, SEEN_CAP).unwrap();
        assert_eq!(store.roster_statement_first_seen(&m, &a), Some(now), "back in the roster keeps its first sight");
        store.note_roster_statements(&m, &[a.clone(), b.clone()], now + 20 + SEEN_KEEP_MS, SEEN_KEEP_MS, SEEN_CAP).unwrap();
        assert_eq!(store.roster_statement_first_seen(&m, &a), Some(now), "a statement back in the roster is no longer dropped");
        store.note_roster_statements(&m, std::slice::from_ref(&b), now + 30, SEEN_KEEP_MS, SEEN_CAP).unwrap();
        store.note_roster_statements(&m, std::slice::from_ref(&b), now + 31 + SEEN_KEEP_MS, SEEN_KEEP_MS, SEEN_CAP).unwrap();
        assert_eq!(store.roster_statement_first_seen(&m, &a), None, "gone 30 days after it dropped");
    }

    /// First sights per identity stay under the cap, the longest dropped going first.
    #[test]
    fn first_sights_stay_under_the_cap_longest_dropped_first() {
        let me = Observer::new(0x01, 0x02);
        let store = me.store();
        let m = me.master.peer_id();
        let keys: Vec<String> = (0..4).map(|i| format!("k{i}")).collect();
        store.note_roster_statements(&m, &keys, 100, SEEN_KEEP_MS, 10).unwrap();
        store.note_roster_statements(&m, &keys[1..], 200, SEEN_KEEP_MS, 10).unwrap();
        store.note_roster_statements(&m, &keys[2..], 300, SEEN_KEEP_MS, 3).unwrap();
        assert_eq!(store.roster_statement_first_seen(&m, &keys[0]), None, "the longest dropped goes first");
        assert_eq!(store.roster_statement_first_seen(&m, &keys[1]), Some(100));
        assert_eq!(store.roster_statement_first_seen(&m, &keys[3]), Some(100));
    }

    /// I10 (LOW): a database from before first sights dates at 0 what our roster held
    /// before the upgrade, and never what the first save after it brings, whatever path
    /// saves first (a push fetch can).
    #[test]
    fn an_upgrade_dates_at_0_only_what_our_roster_held_before_it() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (mut r, _) = me.own();
        let m = me.master.peer_id();
        let (old, new) = (kp(0x07), kp(0x08));
        r.add_consent(sign_consent(&old, &m));
        r.add_vouch(roster::sign_vouch(&me.device, &m, &r.base(), &old.peer_id()));
        merge_for_test(&me.store(), &r, &m, &me.device.peer_id());
        me.store().upgrade_from_before_first_sights_for_test();
        let before = now_ms();
        r.add_consent(sign_consent(&new, &m));
        r.add_vouch(roster::sign_vouch(&me.device, &m, &r.base(), &new.peer_id()));
        merge_for_test(&me.store(), &r, &m, &me.device.peer_id());
        let store = me.store();
        let seen = |d: &NativeKeypair| {
            let v = r.vouches.iter().find(|v| v.device == d.peer_id()).unwrap();
            store.roster_statement_first_seen(&m, &roster::vouch_seen_key(v))
        };
        assert_eq!(seen(&old), Some(0), "held before the upgrade");
        assert_eq!(
            store.roster_statement_first_seen(&m, &roster::device_seen_key(&old.peer_id())),
            Some(0),
            "a device counted before the upgrade",
        );
        assert!(store
            .roster_statement_first_seen(&m, &roster::device_seen_key(&new.peer_id()))
            .is_some_and(|at| at >= before));
        assert!(seen(&new).is_some_and(|at| at >= before), "the first save's own statement dated 0");
        merge_for_test(&store, &r, &m, &me.device.peer_id());
        assert_eq!(seen(&old), Some(0), "the mark is taken once");
    }

    /// I10 (8.6): the recovery keep list starts with only the devices counted here before
    /// T ticked; a fresh install keeps none.
    #[test]
    fn a_recovery_keeps_by_default_only_devices_counted_before_t() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (mut r, _) = me.own();
        let m = me.master.peer_id();
        let (old, new) = (kp(0x07), kp(0x08));
        for d in [&old, &new] {
            r.add_consent(sign_consent(d, &m));
            r.add_vouch(roster::sign_vouch(&me.device, &m, &r.base(), &d.peer_id()));
        }
        merge_for_test(&me.store(), &r, &m, &me.device.peer_id());
        let store = me.store();
        let t = now_ms() - 60_000;
        let (_, state) = me.own();
        assert!(recovery_kept_by_default(&store, &m, &state, &me.device.peer_id(), t).is_empty(), "a fresh install keeps none");
        store.set_roster_statement_first_seen(&m, &roster::device_seen_key(&old.peer_id()), t - 1).unwrap();
        store.set_roster_statement_first_seen(&m, &roster::device_seen_key(&new.peer_id()), t).unwrap();
        store.set_roster_statement_first_seen(&m, &roster::device_seen_key(&me.device.peer_id()), t - 1).unwrap();
        assert_eq!(recovery_kept_by_default(&store, &m, &state, &me.device.peer_id(), t), vec![old.peer_id()]);
        assert!(recovery_kept_by_default(&store, &m, &state, &me.device.peer_id(), 0).is_empty(), "\"not sure\" keeps none");
    }

    /// The moment a recovery's dropped devices were last had stays with its base.
    #[test]
    fn a_recovery_remembers_when_the_dropped_devices_were_last_had() {
        let me = Observer::new(0x01, 0x02);
        let store = me.store();
        assert_eq!(recovery_lost_since(&store, "b1"), None);
        note_recovery_lost_since(&store, "b1", 1234).unwrap();
        note_recovery_lost_since(&store, "b2", -5).unwrap();
        assert_eq!(recovery_lost_since(&store, "b1"), Some(1234));
        assert_eq!(recovery_lost_since(&store, "b2"), Some(0));
    }

    /// A fresh install has no mark: its first roster is dated when it was seen.
    #[test]
    fn a_fresh_install_dates_its_first_roster_now() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let before = now_ms();
        let (r, _) = me.own();
        assert!(!me.store().roster_statements_marked().unwrap(), "a fresh database is marked as upgraded");
        for v in &r.vouches {
            let at = me.store().roster_statement_first_seen(&me.master.peer_id(), &roster::vouch_seen_key(v));
            assert!(at.is_some_and(|at| at >= before));
        }
    }

    // R31-8: who may fill the book.
    async fn notice(
        me: &Observer,
        sender: &str,
        roster: &Roster,
        servers: &std::collections::HashMap<String, crate::crdt::server_state::ServerState>,
    ) -> Ingested {
        ingest_notice(
            &me.events, &me.ws, &me.master.peer_id(), &me.device.peer_id(), sender, roster.clone(), servers,
            &me.db, &me.pass,
        )
        .await
    }

    fn server_of(owner: &NativeKeypair) -> std::collections::HashMap<String, crate::crdt::server_state::ServerState> {
        let state = crate::crdt::server_state::ServerState::new("s1".into(), "S".into(), owner.peer_id());
        std::collections::HashMap::from([("s1".to_string(), state)])
    }

    /// I18. A stranger's notice in a server room it is not part of keeps nothing, though
    /// its deliverer is one of its members (the ungated ingest keeps it).
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_strangers_roster_notice_in_a_server_room_stores_nothing() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (owner, stranger, sdev) = (kp(0x70), kp(0x71), kp(0x72));
        let r = Roster::legacy_for_test(&stranger, &[&sdev]);
        notice(&me, &sdev.peer_id(), &r, &server_of(&owner)).await;
        assert!(load(&me.store(), &stranger.peer_id()).is_none(), "a stranger filled the book");
        me.ingest(&sdev.peer_id(), &r).await;
        assert!(load(&me.store(), &stranger.peer_id()).is_some(), "control: the ungated ingest keeps it");
    }

    /// I18. With no server, friend or roster naming it, a notice keeps nothing, in the
    /// node and in the push fetch.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_roster_notice_from_a_master_we_know_nothing_of_stores_nothing() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (stranger, sdev) = (kp(0x71), kp(0x72));
        let r = Roster::legacy_for_test(&stranger, &[&sdev]);
        notice(&me, &sdev.peer_id(), &r, &Default::default()).await;
        crate::node::roster_reach::fetch_roster(
            &me.db, &me.pass, &me.master.peer_id(), &me.device.peer_id(), &sdev.peer_id(), r.clone(), true,
        );
        assert!(load(&me.store(), &stranger.peer_id()).is_none(), "a stranger filled the book");
        assert!(me.store().load_device_list(&stranger.peer_id()).unwrap().is_none());
    }

    /// I18. The owner of a server we hold is in its authority set: its notice is kept.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn the_owners_roster_notice_in_its_room_is_kept() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (owner, odev) = (kp(0x70), kp(0x73));
        let r = Roster::legacy_for_test(&owner, &[&odev]);
        notice(&me, &odev.peer_id(), &r, &server_of(&owner)).await;
        assert!(me.state_of(&owner.peer_id()).is_member(&odev.peer_id()));
    }

    /// A pending friend's notice is kept in the node and in the push fetch, and so is
    /// one for a master we already hold.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_pending_friends_and_a_held_masters_notice_is_kept() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (friend, fdev, fetched, xdev) = (kp(0x74), kp(0x75), kp(0x76), kp(0x77));
        me.store().save_friend(&friend.peer_id(), "pending", "incoming", 1).unwrap();
        me.store().save_friend(&fetched.peer_id(), "pending", "outgoing", 1).unwrap();
        notice(&me, &fdev.peer_id(), &Roster::legacy_for_test(&friend, &[&fdev]), &Default::default()).await;
        assert!(me.state_of(&friend.peer_id()).is_member(&fdev.peer_id()));
        crate::node::roster_reach::fetch_roster(
            &me.db, &me.pass, &me.master.peer_id(), &me.device.peer_id(), &xdev.peer_id(),
            Roster::legacy_for_test(&fetched, &[&xdev]), false,
        );
        assert!(load(&me.store(), &fetched.peer_id()).is_some(), "the push fetch dropped a friend's roster");
        let (held, hdev, newer) = (kp(0x78), kp(0x79), kp(0x7a));
        me.ingest(&hdev.peer_id(), &Roster::legacy_for_test(&held, &[&hdev])).await;
        notice(&me, &newer.peer_id(), &Roster::legacy_for_test(&held, &[&hdev, &newer]), &Default::default()).await;
        assert!(me.state_of(&held.peer_id()).is_member(&newer.peer_id()), "a held master's news was dropped");
    }

    /// A member that is not the owner, and the author of an op the server keeps, are in
    /// its authority set: their notices are kept.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_co_members_and_an_op_authors_notice_is_kept() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (owner, member, mdev, author, adev) = (kp(0x70), kp(0x7b), kp(0x7c), kp(0x7d), kp(0x7e));
        let mut servers = server_of(&owner);
        let state = servers.get_mut("s1").unwrap();
        state.members.insert(
            member.peer_id(),
            crate::crdt::server_state::MemberInfo { peer_id: member.peer_id(), display_name: "m".into() },
        );
        let (signer, _, pk) = crate::crdt::testkeys::keys(9);
        state.set_signer(signer, pk);
        let mut op = state.create_op(crate::crdt::operations::CrdtPayload::ServerRenamed { new_name: "x".into() });
        op.author = author.peer_id();
        state.op_log.push(op);
        notice(&me, &mdev.peer_id(), &Roster::legacy_for_test(&member, &[&mdev]), &servers).await;
        notice(&me, &adev.peer_id(), &Roster::legacy_for_test(&author, &[&adev]), &servers).await;
        assert!(me.state_of(&member.peer_id()).is_member(&mdev.peer_id()), "a co-member's notice was dropped");
        assert!(me.state_of(&author.peer_id()).is_member(&adev.peer_id()), "an op author's notice was dropped");
    }

    /// Our own identity's roster is always ours to hear, even before this device saved
    /// its own.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn our_own_roster_notice_is_kept_before_we_hold_ours() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let sib = kp(0x7f);
        assert!(load(&me.store(), &me.master.peer_id()).is_none(), "setup: nothing saved yet");
        let r = Roster::legacy_for_test(&me.master, &[&sib, &me.device]);
        notice(&me, &sib.peer_id(), &r, &Default::default()).await;
        assert!(load(&me.store(), &me.master.peer_id()).is_some(), "our own roster was dropped");
    }

    /// The notice arm reaches the book only through the gate.
    #[test]
    fn the_roster_notice_arm_goes_through_the_gate() {
        let swarm = std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/node/swarm.rs"))
            .expect("read swarm.rs")
            .replace("\r\n", "\n");
        let arm = "        HavenMessage::RosterNotice { roster } | HavenMessage::RosterSync { roster, .. } => {";
        let start = swarm.find(arm).expect("the notice arm");
        let rest = &swarm[start + arm.len()..];
        let body = &rest[..rest.find("\n        HavenMessage::").unwrap_or(rest.len())];
        assert!(body.contains("roster_book::ingest_notice("), "the notice arm skips the book gate");
        assert!(!body.contains("roster_book::ingest("), "the notice arm ingests around the gate");
    }

    // HOL-SEC-193: the roster a profile card or update carries.
    async fn profile_roster(
        me: &Observer,
        sender: &str,
        roster: &Roster,
        servers: &std::collections::HashMap<String, crate::crdt::server_state::ServerState>,
    ) -> Option<Ingested> {
        if !admit_profile_roster(sender, Some(roster), &me.master.peer_id(), servers, &me.db, &me.pass, || super::super::types::HavenMessage::ProfileRequest, 0) {
            return None;
        }
        Some(ingest(&me.events, &me.ws, &me.master.peer_id(), &me.device.peer_id(), sender, Some(roster.clone()), &me.db, &me.pass).await)
    }

    /// A co-member's device consents to an identity its owner minted: the roster its
    /// profile carries keeps nothing and refuses the profile.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_profile_roster_for_a_minted_master_is_refused() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (owner, member, mdev, minted) = (kp(0x70), kp(0x7b), kp(0x7c), kp(0x80));
        let mut servers = server_of(&owner);
        servers.get_mut("s1").unwrap().members.insert(
            member.peer_id(),
            crate::crdt::server_state::MemberInfo { peer_id: member.peer_id(), display_name: "m".into() },
        );
        let r = Roster::legacy_for_test(&minted, &[&mdev]);
        let m = mdev.peer_id();
        assert!(profile_roster(&me, &m, &r, &servers).await.is_none(), "a member's minted roster");
        assert!(load(&me.store(), &minted.peer_id()).is_none(), "a minted identity filled the book");
        let own = Roster::legacy_for_test(&mdev, &[&mdev]);
        assert!(profile_roster(&me, &m, &own, &servers).await.is_none(), "a device named itself its master");
        assert!(load(&me.store(), &m).is_none());
        me.ingest(&m, &r).await;
        assert!(load(&me.store(), &minted.peer_id()).is_some(), "control: the ungated ingest keeps it");
    }

    /// A stranger's own identity is refused too: an MLS leaf certifying it says only that
    /// some group seated it, and a meeting's host seats any leaf.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_strangers_own_profile_roster_is_refused() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (peer, pdev) = (kp(0x81), kp(0x82));
        let r = Roster::legacy_for_test(&peer, &[&pdev]);
        assert!(profile_roster(&me, &pdev.peer_id(), &r, &Default::default()).await.is_none());
        assert!(load(&me.store(), &peer.peer_id()).is_none(), "a stranger's identity filled the book");
    }

    /// Our own siblings, friends of any state (by master or, for a nickname friend, by
    /// device), co-members and a profile with no roster all pass.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_profile_roster_from_siblings_friends_and_co_members_is_kept() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let none = std::collections::HashMap::new();
        let sib = kp(0x83);
        let own = Roster::legacy_for_test(&me.master, &[&sib, &me.device]);
        assert!(profile_roster(&me, &sib.peer_id(), &own, &none).await.is_some(), "a sibling");
        let (friend, fdev, nick, ndev) = (kp(0x84), kp(0x85), kp(0x86), kp(0x87));
        me.store().save_friend(&friend.peer_id(), "pending", "outgoing", 1).unwrap();
        me.store().save_friend(&ndev.peer_id(), "pending", "outgoing", 1).unwrap();
        let fr = Roster::legacy_for_test(&friend, &[&fdev]);
        assert!(profile_roster(&me, &fdev.peer_id(), &fr, &none).await.is_some(), "a friend");
        let nr = Roster::legacy_for_test(&nick, &[&ndev]);
        assert!(profile_roster(&me, &ndev.peer_id(), &nr, &none).await.is_some(), "a nickname friend");
        let (owner, odev) = (kp(0x70), kp(0x73));
        let or = Roster::legacy_for_test(&owner, &[&odev]);
        assert!(profile_roster(&me, &odev.peer_id(), &or, &server_of(&owner)).await.is_some(), "a co-member");
        for (master, dev) in [(&me.master, &sib), (&friend, &fdev), (&nick, &ndev), (&owner, &odev)] {
            assert!(me.state_of(&master.peer_id()).is_member(&dev.peer_id()), "{} was dropped", master.peer_id());
        }
        let no_roster = admit_profile_roster(&fdev.peer_id(), None, &me.master.peer_id(), &none, &me.db, &me.pass, || super::super::types::HavenMessage::ProfileRequest, 0);
        assert!(no_roster, "a profile with no roster was refused");
    }

    /// Every arm that hears a profile's roster reaches the book only through its gate.
    #[test]
    fn the_profile_roster_arms_go_through_the_gate() {
        let read = |f: &str| {
            std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(f))
                .expect("read source")
                .replace("\r\n", "\n")
        };
        // The gate runs once, before the one ingest, and the ingest takes what it passed.
        let gated = |body: &str, what: &str| {
            let gate = body.find("if !super::roster_book::admit_profile_roster(").unwrap_or_else(|| panic!("{what}: skips the gate"));
            let ingest = body.find("roster_book::ingest(").unwrap_or_else(|| panic!("{what}: never ingests"));
            assert!(gate < ingest, "{what}: ingests before the gate");
            assert_eq!(body.matches("roster_book::ingest(").count(), 1, "{what}: ingests around the gate");
        };
        let swarm = read("src/node/swarm.rs");
        for arm in ["        HavenMessage::ProfileCard {", "        HavenMessage::ProfileUpdate {"] {
            let start = swarm.find(arm).unwrap_or_else(|| panic!("missing {arm}"));
            let rest = &swarm[start + arm.len()..];
            let body = &rest[..rest.find("\n        HavenMessage::").unwrap_or(rest.len())];
            gated(body, arm.trim());
        }
        let social = read("src/node/social.rs");
        let start = social.find("pub(crate) async fn handle_envelope_profile_update(").expect("the MLS profile handler");
        let body = &social[start..start + social[start..].find("\n}\n").expect("its end")];
        gated(body, "the MLS profile");
        let arm = "                            MessageEnvelope::ProfileUpdate {";
        let start = swarm.find(arm).expect("the MLS profile arm");
        let rest = &swarm[start + arm.len()..];
        let body = &rest[..rest.find("\n                            MessageEnvelope::").expect("the next arm")];
        let drop = body.find("conference::refuses_profile_update(&server_id,").expect("the MLS profile arm hears a meeting's group");
        assert!(drop < body.find("handle_envelope_profile_update(").expect("the handler"), "a meeting's profile reaches the handler first");
    }

    // t14-ident review_ab fixes

    fn ordered(a: NativeKeypair, b: NativeKeypair) -> (NativeKeypair, NativeKeypair) {
        if a.peer_id() < b.peer_id() { (a, b) } else { (b, a) }
    }

    /// Our phone (root) linked d, a and e at one depth, d ranking before a. Long ago d
    /// removed e (a stolen phone), then a removed d. Returns the roster held, the one after
    /// our phone removes a in `mode`, e and d.
    fn earlier_removal_chain(mode: RemoveMode) -> (Roster, Roster, String, String) {
        earlier_removal_chain_seen(mode, now_ms() - 3_600_000)
    }

    /// [`earlier_removal_chain`] with d's removal of e first seen at `d_rm_e_seen`.
    fn earlier_removal_chain_seen(mode: RemoveMode, d_rm_e_seen: i64) -> (Roster, Roster, String, String) {
        let me = Observer::new(0x01, 0x02);
        write_bootstrap(&me.dir(), &Roster::genesis(&me.master, &kp(0x03), &me.device, now_ms() - 60_000)).unwrap();
        let (mut r, _) = me.own();
        let m = me.master.peer_id();
        let base = r.base();
        let (d, a) = ordered(kp(0x21), kp(0x22));
        let e = kp(0x23);
        for x in [&d, &a, &e] {
            r.add_consent(sign_consent(x, &m));
            r.add_vouch(sign_vouch(&me.device, &m, &base, &x.peer_id()));
        }
        let d_rm_e = sign_removal(&d, &m, &base, &e.peer_id(), &[]);
        let a_rm_d = sign_removal(&a, &m, &base, &d.peer_id(), &[]);
        r.add_removal(d_rm_e.clone());
        r.add_removal(a_rm_d.clone());
        merge_for_test(&me.store(), &r, &m, &me.device.peer_id());
        let store = me.store();
        store.set_roster_statement_first_seen(&m, &roster::removal_seen_key(&a_rm_d), now_ms() - 3_600_000).unwrap();
        store.set_roster_statement_first_seen(&m, &roster::removal_seen_key(&d_rm_e), d_rm_e_seen).unwrap();
        let (held, _) = me.own();
        let before = held.authority();
        assert!(!before.counts(&e.peer_id()) && !before.counts(&d.peer_id()) && before.counts(&a.peer_id()), "setup {before:?}");
        let (after, _, _) = remove(&me.master, &me.device, &a.peer_id(), mode, false, &me.db, &me.pass).unwrap();
        (held, after, e.peer_id(), d.peer_id())
    }

    /// F1 (8.5): removing a moves d's death before d's turn; what d removed stays removed.
    #[test]
    fn review_ab_retiring_a_device_never_brings_back_what_an_earlier_device_removed() {
        let _g = guard();
        let (_, after, e, _) = earlier_removal_chain(RemoveMode::Retire);
        assert!(!after.reverified().fold(|_| None, 0).is_member(&e), "ID-1's fold keeps e out");
        let auth = after.reverified().authority();
        assert!(!auth.counts(&e), "retiring a brought e back for servers: {:?}", auth.counted);
    }

    /// F1: lost or stolen keeps out what a's removals, seen before T, kept out, all the way down.
    #[test]
    fn review_ab_lost_or_stolen_never_brings_back_what_an_earlier_device_removed_before_t() {
        let _g = guard();
        let (_, after, e, d) = earlier_removal_chain(RemoveMode::Lost { t_ms: now_ms() - 60_000 });
        let auth = after.reverified().authority();
        assert!(!auth.counts(&e) && !auth.counts(&d), "lost or stolen brought a device back for servers: {:?}", auth.counted);
    }

    /// F1: T judges only what a dropped device signed: d's removal of e, first seen after
    /// T, is d's and stays.
    #[test]
    fn review_ab_lost_or_stolen_keeps_out_what_another_device_removed_after_t() {
        let _g = guard();
        let t_ms = now_ms() - 60_000;
        let (_, after, e, _) = earlier_removal_chain_seen(RemoveMode::Lost { t_ms }, now_ms());
        assert!(!after.reverified().authority().counts(&e), "a removal by a device we kept lapsed at T");
    }

    /// 8.5: retiring re-signs every counting removal the device signed, even of a device
    /// an earlier device also removed.
    #[test]
    fn retiring_re_signs_a_removal_an_earlier_device_also_made() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        write_bootstrap(&me.dir(), &Roster::genesis(&me.master, &kp(0x03), &me.device, now_ms() - 60_000)).unwrap();
        let (mut r, _) = me.own();
        let m = me.master.peer_id();
        let base = r.base();
        let (b, a) = ordered(kp(0x24), kp(0x25));
        let z = kp(0x26);
        for x in [&b, &a, &z] {
            r.add_consent(sign_consent(x, &m));
            r.add_vouch(sign_vouch(&me.device, &m, &base, &x.peer_id()));
        }
        r.add_removal(sign_removal(&b, &m, &base, &z.peer_id(), &[]));
        r.add_removal(sign_removal(&a, &m, &base, &z.peer_id(), &[]));
        merge_for_test(&me.store(), &r, &m, &me.device.peer_id());
        let (roster, _, _) = remove(&me.master, &me.device, &a.peer_id(), RemoveMode::Retire, false, &me.db, &me.pass).unwrap();
        assert!(re_signed_by(&roster, &me.device, &z), "a's removal of z was not re-signed");
    }

    /// A device that removed us is removed without our re-signing its removal of us.
    #[test]
    fn removing_a_device_never_re_signs_its_removal_of_us() {
        let (master, me, a) = (kp(0x01), kp(0x02), kp(0x27));
        let m = master.peer_id();
        let mut r = Roster::genesis(&master, &kp(0x03), &me, now_ms() - 60_000);
        let base = r.base();
        r.add_consent(sign_consent(&a, &m));
        r.add_vouch(sign_vouch(&me, &m, &base, &a.peer_id()));
        r.add_removal(sign_removal(&a, &m, &base, &me.peer_id(), &[]));
        let mut r = r.reverified();
        assert!(r.authority().removed.contains_key(&me.peer_id()), "setup: a removed us");
        add_removals(&mut r, &me, vec![sign_removal(&me, &m, &base, &a.peer_id(), &[])], &|_| false);
        assert!(!re_signed_by(&r, &me, &me), "we re-signed a's removal of us");
    }

    /// Control: a removal of a with nothing re-signed leaves e out (d's removal of e
    /// still counts at d's turn); only re-signing a's removal of d moves d's death.
    #[test]
    fn review_ab_control_a_plain_removal_keeps_e_out() {
        let _g = guard();
        let (held, _, e, d) = earlier_removal_chain(RemoveMode::Retire);
        let mut plain = held.clone();
        let a = held.authority().removed.get(&d).cloned().unwrap();
        plain.add_removal(sign_removal(&kp(0x02), &held.master, &held.base(), &a, &[]));
        assert!(!plain.reverified().authority().counts(&e), "control: a plain removal of a keeps e out");
    }

    /// F1: our phone linked s and x; s removed x. Removing every other device keeps x out.
    #[test]
    fn review_ab_removing_all_other_devices_never_brings_back_a_device_a_sibling_removed() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        write_bootstrap(&me.dir(), &Roster::genesis(&me.master, &kp(0x03), &me.device, now_ms() - 60_000)).unwrap();
        let (mut r, _) = me.own();
        let m = me.master.peer_id();
        let base = r.base();
        let (s, x) = (kp(0x31), kp(0x32));
        for d in [&s, &x] {
            r.add_consent(sign_consent(d, &m));
            r.add_vouch(sign_vouch(&me.device, &m, &base, &d.peer_id()));
        }
        r.add_removal(sign_removal(&s, &m, &base, &x.peer_id(), &[]));
        merge_for_test(&me.store(), &r, &m, &me.device.peer_id());
        let (held, _) = me.own();
        assert!(!held.authority().counts(&x.peer_id()), "setup: x is out");
        let (after, _, gone) = remove_all_others(&me.master, &me.device, &me.db, &me.pass).unwrap();
        assert!(gone.contains(&s.peer_id()));
        assert!(!after.reverified().fold(|_| None, 0).is_member(&x.peer_id()), "ID-1's fold keeps x out");
        let auth = after.reverified().authority();
        assert!(!auth.counts(&x.peer_id()), "removing every other device brought x back for servers: {:?}", auth.counted);
    }

    fn splitmix(state: &mut u64) -> u64 {
        *state = state.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = *state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    fn keyed(case: u64, i: u8) -> NativeKeypair {
        let mut s = [i; 32];
        s[..8].copy_from_slice(&case.to_le_bytes());
        NativeKeypair::from_secret_bytes(&s)
    }

    /// F1 property: across random rosters, a removal by a counted device never takes a
    /// device out of the walk's `removed`, except one every counted removal of which a
    /// dropped device signed and lost or stolen lets lapse.
    #[test]
    fn removing_a_device_never_brings_back_a_device_the_walk_kept_out() {
        let (master, recovery) = (kp(0x01), kp(0x03));
        let m = master.peer_id();
        let mut checked = 0;
        for case in 0..400u64 {
            let mut rng = case.wrapping_mul(0x5851_f42d_4c95_7f2d) ^ 0x1405;
            let root = keyed(case, 0x40);
            let mut r = Roster::genesis(&master, &recovery, &root, 1_000);
            let base = r.base();
            let n = 4 + (splitmix(&mut rng) % 5) as usize;
            let mut devs = vec![root];
            for i in 0..n {
                let d = keyed(case, 0x41 + i as u8);
                r.add_consent(sign_consent(&d, &m));
                let by = (splitmix(&mut rng) as usize) % devs.len();
                r.add_vouch(sign_vouch(&devs[by], &m, &base, &d.peer_id()));
                devs.push(d);
            }
            for _ in 0..(splitmix(&mut rng) % 3) {
                let (by, to) = ((splitmix(&mut rng) as usize) % devs.len(), (splitmix(&mut rng) as usize) % devs.len());
                r.add_vouch(sign_vouch(&devs[by], &m, &base, &devs[to].peer_id()));
            }
            for _ in 0..(1 + splitmix(&mut rng) % 6) {
                let (by, to) = (1 + (splitmix(&mut rng) as usize) % n, (splitmix(&mut rng) as usize) % devs.len());
                r.add_removal(sign_removal(&devs[by], &m, &base, &devs[to].peer_id(), &[]));
            }
            let r = r.reverified();
            let before = r.authority();
            let me = &devs[(splitmix(&mut rng) as usize) % devs.len()];
            if !before.counts(&me.peer_id()) {
                continue;
            }
            let target = devs[1 + (splitmix(&mut rng) as usize) % n].peer_id();
            if target == me.peer_id() {
                continue;
            }
            let all_others = splitmix(&mut rng).is_multiple_of(4);
            let dropped: Vec<String> = if all_others {
                devs.iter().map(|d| d.peer_id()).filter(|d| *d != me.peer_id()).collect()
            } else {
                vec![target]
            };
            let lost = !all_others && splitmix(&mut rng).is_multiple_of(2);
            let lapsing: BTreeSet<Removal> =
                r.removals.iter().filter(|_| lost && splitmix(&mut rng).is_multiple_of(2)).cloned().collect();
            let new = dropped.iter().map(|d| sign_removal(me, &m, &base, d, &[])).collect();
            let mut after = r.clone();
            let gone: BTreeSet<String> = dropped.iter().cloned().collect();
            add_removals(&mut after, me, new, &|x: &Removal| gone.contains(&x.by) && lapsing.contains(x));
            let auth = after.reverified().authority();
            for d in before.removed.keys().filter(|d| !auth.removed.contains_key(*d)) {
                let may_lapse = before
                    .counted_removals
                    .iter()
                    .filter(|x| &x.device == d)
                    .all(|x| gone.contains(&x.by) && lapsing.contains(x));
                assert!(may_lapse, "case {case}: removing {dropped:?} brought {d} back: before {before:?} after {auth:?}");
            }
            checked += 1;
        }
        assert!(checked > 120, "too few cases ran: {checked}");
    }

    /// L1: the upgrade mark leaves only together with the first sights it dates.
    #[test]
    fn an_upgrade_mark_leaves_only_with_its_seeds() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (mut r, _) = me.own();
        let m = me.master.peer_id();
        let old = kp(0x07);
        r.add_consent(sign_consent(&old, &m));
        r.add_vouch(sign_vouch(&me.device, &m, &r.base(), &old.peer_id()));
        merge_for_test(&me.store(), &r, &m, &me.device.peer_id());
        let store = me.store();
        store.upgrade_from_before_first_sights_for_test();
        let marked = |s: &MessageStore| {
            s.conn_for_test()
                .query_row("SELECT COUNT(*) FROM roster_statement_seen WHERE master_peer_id = '*' AND digest = '*'", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap()
                == 1
        };
        assert!(marked(&store), "setup: marked");
        store.conn_execute_for_test(
            "CREATE TEMP TRIGGER seed_crash BEFORE INSERT ON main.roster_statement_seen
             WHEN NEW.first_seen_ms = 0 AND NEW.digest <> '*' BEGIN SELECT RAISE(ABORT, 'crash'); END;",
        );
        assert!(date_held_before_upgrade(&store, &m).is_err(), "setup: the seeding fails");
        assert!(marked(&store), "the mark left without its seeds");
        let v = r.vouches.iter().find(|v| v.device == old.peer_id()).unwrap();
        store.conn_execute_for_test("DROP TRIGGER seed_crash;");
        date_held_before_upgrade(&store, &m).unwrap();
        assert!(!marked(&store));
        assert_eq!(store.roster_statement_first_seen(&m, &roster::vouch_seen_key(v)), Some(0), "the retry dates what was held");
        assert!(!store.seed_roster_statements_once(&m, &["late".to_string()]).unwrap(), "a taken mark seeds again");
        assert_eq!(store.roster_statement_first_seen(&m, "late"), None, "a seed without the mark was kept");
    }

    /// L3: a friend row under the delivering device (added by nickname) lets in the one
    /// identity that names that device a member, then moves to its master.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_device_keyed_friend_row_admits_one_identity_at_most() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (first, second, dev) = (kp(0x81), kp(0x82), kp(0x83));
        me.store().save_friend(&dev.peer_id(), "pending", "outgoing", 1).unwrap();
        notice(&me, &dev.peer_id(), &Roster::legacy_for_test(&first, &[&dev]), &Default::default()).await;
        assert!(me.state_of(&first.peer_id()).is_member(&dev.peer_id()), "the nickname friend's roster was dropped");
        assert!(me.store().get_friend_row(&dev.peer_id()).unwrap().is_none(), "the row stayed under the device");
        notice(&me, &dev.peer_id(), &Roster::legacy_for_test(&second, &[&dev]), &Default::default()).await;
        assert!(load(&me.store(), &second.peer_id()).is_none(), "one device row let in a second identity");
    }

    /// F1: when the first removal of d is the thief's (after T) but a device we keep also
    /// removed d, d stays out even once our removal of the thief's vouchee f kills that
    /// device before its turn.
    #[test]
    fn lost_or_stolen_keeps_out_what_a_kept_device_also_removed() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        write_bootstrap(&me.dir(), &Roster::genesis(&me.master, &kp(0x03), &me.device, now_ms() - 60_000)).unwrap();
        let (mut r, _) = me.own();
        let m = me.master.peer_id();
        let base = r.base();
        let (a, c) = ordered(kp(0x28), kp(0x29));
        let (d, f) = (kp(0x2a), kp(0x2b));
        for x in [&a, &c, &d] {
            r.add_consent(sign_consent(x, &m));
            r.add_vouch(sign_vouch(&me.device, &m, &base, &x.peer_id()));
        }
        r.add_consent(sign_consent(&f, &m));
        let a_vouch_f = sign_vouch(&a, &m, &base, &f.peer_id());
        r.add_vouch(a_vouch_f.clone());
        let a_rm_d = sign_removal(&a, &m, &base, &d.peer_id(), &[]);
        let f_rm_c = sign_removal(&f, &m, &base, &c.peer_id(), &[]);
        r.add_removal(a_rm_d.clone());
        r.add_removal(sign_removal(&c, &m, &base, &d.peer_id(), &[]));
        r.add_removal(f_rm_c.clone());
        merge_for_test(&me.store(), &r, &m, &me.device.peer_id());
        let t_ms = now_ms() - 60_000;
        let store = me.store();
        store.set_roster_statement_first_seen(&m, &roster::removal_seen_key(&a_rm_d), now_ms()).unwrap();
        store.set_roster_statement_first_seen(&m, &roster::removal_seen_key(&f_rm_c), t_ms - 3_600_000).unwrap();
        store.set_roster_statement_first_seen(&m, &roster::vouch_seen_key(&a_vouch_f), t_ms - 3_600_000).unwrap();
        let (held, _) = me.own();
        let before = held.authority();
        assert_eq!(before.removed.get(&d.peer_id()), Some(&a.peer_id()), "setup: the thief removed d first {before:?}");
        assert!(before.counted_removals.iter().any(|x| x.by == c.peer_id() && x.device == d.peer_id()), "setup: c's removal of d counts");
        let (after, _, gone) =
            remove(&me.master, &me.device, &a.peer_id(), RemoveMode::Lost { t_ms }, true, &me.db, &me.pass).unwrap();
        assert!(gone.contains(&f.peer_id()), "setup: f goes with a");
        let auth = after.reverified().authority();
        assert!(!auth.counts(&c.peer_id()), "setup: f's removal of c, seen before T, stays");
        assert!(!auth.counts(&d.peer_id()), "c's removal of d lapsed with the thief's: {:?}", auth.counted);
    }

    /// A device this change removes keeps exactly the keep this change gives it, never a
    /// narrower one re-signed from an earlier removal of it.
    #[test]
    fn a_dropped_device_keeps_the_keep_this_removal_gives_it() {
        let (master, me) = (kp(0x01), kp(0x02));
        let m = master.peer_id();
        let mut r = Roster::genesis(&master, &kp(0x03), &me, now_ms() - 60_000);
        let base = r.base();
        let (a, b) = ordered(kp(0x2c), kp(0x2d));
        let w = kp(0x2e);
        for x in [&a, &b, &w] {
            r.add_consent(sign_consent(x, &m));
        }
        for x in [&a, &b] {
            r.add_vouch(sign_vouch(&me, &m, &base, &x.peer_id()));
        }
        r.add_vouch(sign_vouch(&b, &m, &base, &w.peer_id()));
        r.add_removal(sign_removal(&a, &m, &base, &b.peer_id(), &[]));
        let mut r = r.reverified();
        assert!(!r.authority().counts(&w.peer_id()), "setup: a's removal of b voids b's vouch for w");
        let new = vec![
            sign_removal(&me, &m, &base, &a.peer_id(), &[]),
            sign_removal(&me, &m, &base, &b.peer_id(), &[w.peer_id()]),
        ];
        add_removals(&mut r, &me, new, &|_| false);
        assert!(r.reverified().authority().counts(&w.peer_id()), "the keep we gave b was narrowed by a's");
    }

    /// DEVICE_PROOF section 12 item 9: a contact's recovery that keeps one device drops
    /// the other without removing it; the join lock moves for it as for a removal.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_recovery_that_drops_a_device_moves_the_join_lock() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        me.own();
        let (bob, kept, dropped) = (kp(0x70), kp(0x71), kp(0x72));
        me.ingest(&kept.peer_id(), &Roster::legacy_for_test(&bob, &[&kept, &dropped])).await;
        let mut recovered = Roster::legacy_for_test(&bob, &[&kept, &dropped]);
        let recovery = kp(0x73);
        let rec = crate::identity::roster::sign_recovery(&bob, &recovery, now_ms(), &[kept.peer_id()], false);
        recovered.add_phrase_statement(&crate::identity::roster::r_pub_of(&recovery), Some(rec), None).unwrap();
        let (out, noted) = super::super::lock_keeper::noted_while(me.ingest(&kept.peer_id(), &recovered)).await;
        assert!(out.newly_revoked.is_empty(), "setup: a recovery removes nobody");
        assert_eq!(noted, vec![(Some(bob.peer_id()), dropped.peer_id())]);

        // A roster that keeps its base drops nothing.
        let (_, again) = super::super::lock_keeper::noted_while(me.ingest(&kept.peer_id(), &recovered)).await;
        assert!(again.is_empty());
    }

    /// R2 review (3): our own recovery after a mutual removal of two other devices: the
    /// fold had dropped both, but authority still counted the walk's first one, which
    /// the recovery must drop like any device it leaves out.
    #[test]
    fn our_own_recovery_drops_the_device_only_authority_still_counted() {
        use crate::identity::roster::{sign_recovery, r_pub_of};
        let (master, me, a, b, recovery) = (kp(0x80), kp(0x81), kp(0x82), kp(0x83), kp(0x84));
        let m = master.peer_id();
        let mut r = Roster::legacy_for_test(&master, &[&me, &a, &b]);
        r.add_removal(sign_removal(&a, &m, LEGACY_BASE, &b.peer_id(), &[]));
        r.add_removal(sign_removal(&b, &m, LEGACY_BASE, &a.peer_id(), &[]));
        let prev = r.fold(|_| None, now_ms());
        let walk: Vec<String> = r.authority().counted.into_iter().filter(|d| *d != me.peer_id()).collect();
        assert!(!prev.is_member(&a.peer_id()) && !prev.is_member(&b.peer_id()), "setup: the fold removes both");
        assert_eq!(walk.len(), 1, "setup: authority still counts the walk's first one");
        let mut recovered = r.clone();
        let rec = sign_recovery(&master, &recovery, now_ms(), &[me.peer_id()], false);
        recovered.add_phrase_statement(&r_pub_of(&recovery), Some(rec), None).unwrap();
        let now = recovered.fold(|_| None, now_ms());
        assert!(now.is_member(&me.peer_id()) && now.base != prev.base, "setup: a recovery keeping this device");
        let lost = lost_by_own_change(Some(&(r, prev)), Some(&(recovered, now)), &me.peer_id());
        assert_eq!(lost, walk, "the device the walk took first is dropped");
    }

    /// R2 review (1): a recovery the push fetch stored moves the join lock once the
    /// node reads the store's mark, though the base difference is gone by then.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_recovery_the_push_fetch_stored_moves_the_join_lock() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        me.own();
        let (bob, kept, dropped) = (kp(0x74), kp(0x75), kp(0x76));
        me.ingest(&kept.peer_id(), &Roster::legacy_for_test(&bob, &[&kept, &dropped])).await;
        let mut recovered = Roster::legacy_for_test(&bob, &[&kept, &dropped]);
        let rec = crate::identity::roster::sign_recovery(&bob, &kp(0x77), now_ms(), &[kept.peer_id()], false);
        recovered.add_phrase_statement(&crate::identity::roster::r_pub_of(&kp(0x77)), Some(rec), None).unwrap();
        assert!(ingest_stored(&me.db, &me.pass, &me.master.peer_id(), &me.device.peer_id(), &kept.peer_id(), recovered));

        let (out, noted) = super::super::lock_keeper::noted_while(async {
            let out = reconcile_dirty(&me.store(), None, &me.master.peer_id(), &me.device.peer_id());
            out.note_drops();
            out
        })
        .await;
        assert_eq!(out.masters, vec![bob.peer_id()], "setup: the node follows the stored roster");
        assert_eq!(noted, vec![(Some(bob.peer_id()), dropped.peer_id())], "the dropped device moves the lock");
        assert!(reconcile_dirty(&me.store(), None, &me.master.peer_id(), &me.device.peer_id()).dropped.is_empty(), "once");
    }

    // rv-rostercheck (reviewer): a first-sight roster staged for the relay's copy is
    // displaced by any co-member's notice for the same master, unverified, and the
    // displacing roster then lands as delivered by a device it does not count.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn rv_a_non_members_notice_never_displaces_a_staged_first_roster() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (owner, odev, cdev) = (kp(0x73), kp(0x74), kp(0x75));
        let servers = server_of(&owner);
        super::super::roster_check::clear_for_test();
        super::super::roster_check::set_relay(true, &me.master.peer_id());
        let honest = Roster::legacy_for_test(&owner, &[&odev]);
        notice(&me, &odev.peer_id(), &honest, &servers).await;
        assert!(super::super::roster_check::is_staged(&owner.peer_id()), "setup: the owner's first roster is staged");
        // A co-member's device sends a roster for the owner that counts nobody.
        notice(&me, &cdev.peer_id(), &Roster::new(&owner.peer_id()), &servers).await;
        let staged = super::super::roster_check::take_staged(&owner.peer_id()).expect("a staged roster");
        super::super::roster_check::clear_for_test();
        assert_eq!(
            staged.sender,
            odev.peer_id(),
            "a roster whose own fold does not count its deliverer replaced the owner's staged roster"
        );
    }

    // rv-rostercheck (reviewer): R-ID-03's draft says the relay's copy never picks the
    // recovery key; for a roster we hold keyless, ingest_relay adopts the copy's key.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn rv_the_relays_copy_never_picks_the_key_of_a_roster_we_hold_keyless() {
        let _g = guard();
        let me = Observer::new(211, 212);
        let _ = me.own();
        let (bob, bob_dev, rec) = (kp(213), kp(214), kp(215));
        let held = Roster::legacy_for_test(&bob, &[&bob_dev]);
        me.ingest(&bob_dev.peer_id(), &held).await;
        assert!(load(&me.store(), &bob.peer_id()).is_some_and(|r| r.r_pub.is_empty()), "setup: held keyless");
        let mut keyed = Roster::new(&bob.peer_id());
        keyed.add_consent(crate::identity::roster::sign_consent(&bob_dev, &bob.peer_id()));
        keyed
            .add_phrase_statement(
                &crate::identity::roster::r_pub_of(&rec),
                Some(crate::identity::roster::sign_recovery(&bob, &rec, 1_000, &[bob_dev.peer_id()], false)),
                None,
            )
            .expect("a fresh roster takes any key");
        let _ = ingest_relay(&me.events, &me.ws, &me.master.peer_id(), &me.device.peer_id(), keyed, &me.db, &me.pass).await;
        assert!(
            load(&me.store(), &bob.peer_id()).is_some_and(|r| r.r_pub.is_empty()),
            "the relay's copy picked the recovery key of a roster we hold keyless"
        );
    }

    /// The hand-off budget alone: once per peer and revision, again after the roster
    /// moves, our session is lost or AGAIN passes, and at most BUDGET per WINDOW.
    #[test]
    fn the_hand_off_budget_tells_once_per_revision_and_refills_by_the_minute() {
        let _g = super::super::resolver::test_lock();
        let me = "hand-off-unit-device";
        hand_offs().remove(me);
        let t0 = std::time::Instant::now();
        assert!(may_hand_off(me, "p", 1, t0), "control: a first hand-off runs");
        assert!(!may_hand_off(me, "p", 1, t0), "the same revision was handed twice");
        assert!(may_hand_off(me, "p", 2, t0), "a moved roster was not handed");
        on_session_lost(me);
        assert!(may_hand_off(me, "p", 2, t0), "a lost session kept the old hand-off");
        assert!(may_hand_off(me, "p", 2, t0 + HAND_OFF_AGAIN), "a hand-off AGAIN ago still counted");
        // The three at t0 left the window: one spent so far.
        for i in 1..HAND_OFF_BUDGET {
            assert!(may_hand_off(me, &format!("q{i}"), 1, t0 + HAND_OFF_AGAIN), "within the budget");
        }
        assert!(!may_hand_off(me, "over", 1, t0 + HAND_OFF_AGAIN), "past the budget");
        assert!(may_hand_off(me, "over", 1, t0 + HAND_OFF_AGAIN + HAND_OFF_WINDOW), "the window never refilled");
        hand_offs().remove(me);
    }

    /// Identity `me` with `others` counted besides it, phrase-rooted with `recovery`.
    fn rooted_with(me: &Observer, recovery: &NativeKeypair, others: &[&NativeKeypair]) -> Roster {
        let m = me.master.peer_id();
        let mut r = Roster::new(&m);
        r.r_pub = r_pub_of(recovery);
        let mut keep = vec![me.device.peer_id()];
        r.add_consent(sign_consent(&me.device, &m));
        for d in others {
            r.add_consent(sign_consent(d, &m));
            keep.push(d.peer_id());
        }
        keep.sort();
        r.recoveries.push(roster::sign_recovery(&me.master, recovery, now_ms() - 60_000, &keep, false));
        write_bootstrap(&me.dir(), &r).unwrap();
        me.own();
        r
    }

    /// `device` asks to join our identity's current base.
    async fn asks(me: &mut Observer, device: &NativeKeypair) -> Vec<NetworkEvent> {
        let (mut r, s) = own(&me.master.peer_id(), &me.db, &me.pass).unwrap();
        r.add_consent(sign_consent(device, &me.master.peer_id()));
        r.add_pending(sign_pending(&me.master, &s.base, &device.peer_id()));
        me.drain();
        me.ingest(&device.peer_id(), &r).await;
        assert!(me.state_of(&me.master.peer_id()).pending.contains(&device.peer_id()), "precondition: the ask landed");
        me.drain()
    }

    fn prompted(events: &[NetworkEvent], device: &NativeKeypair) -> bool {
        events.iter().any(|e| matches!(e, NetworkEvent::PendingDeviceAsking { device_peer_id } if *device_peer_id == device.peer_id()))
    }

    fn cut_off_here(me: &Observer, device: &NativeKeypair) -> Option<(i64, bool)> {
        let store = me.store();
        let r = load(&store, &me.master.peer_id()).unwrap();
        cut_off_by_recovery(&store, &r, &fold(&store, &r), &device.peer_id())
    }

    /// HOL-SEC-229: a recovery records the members it cut off. One that asks again is
    /// named as ours and raises no pop-up where backups need approval; any other asker
    /// may be one of the old ones (the master key signs an ask for any key), so it is
    /// named as maybe cut off, never as a restored backup. A recovery into an empty
    /// install knew no device, so every asker is a maybe.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_recovery_records_the_devices_it_cut_off() {
        let _g = guard();
        let mut me = Observer::new(0x31, 0x32);
        let (recovery, old, backup) = (kp(0x33), kp(0x34), kp(0x35));
        rooted_with(&me, &recovery, &[&old]);
        let (r, _) = recover(&me.master, &recovery, &me.device, &[], true, Some(now_ms() - 1_000), &me.db, &me.pass).unwrap();
        let at = r.base_at().unwrap();
        let events = asks(&mut me, &old).await;
        assert!(!prompted(&events, &old), "the cut-off device raised the approval pop-up");
        assert_eq!(cut_off_here(&me, &old), Some((at, true)));
        let events = asks(&mut me, &backup).await;
        assert!(!prompted(&events, &backup), "a device no record names was offered as a restored backup");
        assert_eq!(cut_off_here(&me, &backup), Some((at, false)), "a device no record names is not a maybe");

        let mut fresh = Observer::new(0x31, 0x36);
        let (r, _) = recover(&fresh.master, &recovery, &fresh.device, &[], true, Some(now_ms() - 1_000), &fresh.db, &fresh.pass).unwrap();
        let events = asks(&mut fresh, &old).await;
        assert!(!prompted(&events, &old), "an empty install's recovery raised the approval pop-up");
        assert_eq!(cut_off_here(&fresh, &old), Some((r.base_at().unwrap(), false)));
        assert_eq!(cut_off_here(&fresh, &fresh.device), None, "only a device asking to join is named");
    }

    /// HOL-SEC-229 on a device the recovery kept: the new base reaches it from the device
    /// that typed the phrase, and it records the member that base cut off.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_kept_device_records_what_a_recovery_elsewhere_cut_off() {
        let _g = guard();
        let mut me = Observer::new(0x41, 0x42);
        let (recovery, typist, old) = (kp(0x43), kp(0x44), kp(0x45));
        let mut r = rooted_with(&me, &recovery, &[&typist, &old]);
        let mut keep = vec![me.device.peer_id(), typist.peer_id()];
        keep.sort();
        let at = now_ms() - 1_000;
        r.recoveries.push(roster::sign_recovery(&me.master, &recovery, at, &keep, true));
        me.ingest(&typist.peer_id(), &r).await;
        assert!(!me.state_of(&me.master.peer_id()).is_member(&old.peer_id()), "precondition: the new base cut it off");
        let events = asks(&mut me, &old).await;
        assert!(!prompted(&events, &old), "the kept device raised the approval pop-up for the cut-off device");
        assert_eq!(cut_off_here(&me, &old), Some((at, true)));
    }

    /// Where backups may still join by seven quiet days, a cut-off device that asks
    /// again is put to the person (as cut off, never as a backup): silence would let it in.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_cut_off_device_still_warns_where_it_can_join_by_waiting() {
        let _g = guard();
        let mut me = Observer::new(0x51, 0x52);
        let (recovery, old) = (kp(0x53), kp(0x54));
        rooted_with(&me, &recovery, &[&old]);
        let (r, _) = recover(&me.master, &recovery, &me.device, &[], false, Some(now_ms() - 1_000), &me.db, &me.pass).unwrap();
        let events = asks(&mut me, &old).await;
        assert!(prompted(&events, &old), "a cut-off device that can join by waiting went unannounced");
        assert_eq!(cut_off_here(&me, &old), Some((r.base_at().unwrap(), true)));
    }

    /// HOL-SEC-229 review: the master key signs a join ask for any key, so a recovery that
    /// drops devices as lost marks every asker its record does not name as maybe one of
    /// the old ones: a fresh key is never offered as a restored backup.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn rev229_a_fresh_key_after_a_lost_recovery_is_not_offered_as_a_backup() {
        let _g = guard();
        let mut me = Observer::new(0x91, 0x92);
        let (recovery, old, fresh) = (kp(0x93), kp(0x94), kp(0x95));
        rooted_with(&me, &recovery, &[&old]);
        let (r, _) = recover(&me.master, &recovery, &me.device, &[], true, Some(now_ms() - 1_000), &me.db, &me.pass).unwrap();
        let events = asks(&mut me, &fresh).await;
        assert!(cut_off_here(&me, &fresh).is_some(), "a fresh key after a lost recovery is named as a restored backup");
        assert_eq!(cut_off_here(&me, &fresh), Some((r.base_at().unwrap(), false)));
        assert!(!prompted(&events, &fresh), "a fresh key after a lost recovery raised the approval pop-up");
    }

    /// HOL-SEC-229 review: a kept device records the cut in the fold that takes the new
    /// base, not after it: a fold that committed while the after-step never ran (a kill,
    /// a failed lease) still leaves the record, and nothing pops for the cut-off device,
    /// at once or at the next start. A fresh key reads as maybe one of the old ones.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn rev229_b_a_kept_device_that_missed_the_after_step_still_never_prompts() {
        let _g = guard();
        let mut me = Observer::new(0xa1, 0xa2);
        let (recovery, typist, old, fresh) = (kp(0xa3), kp(0xa4), kp(0xa5), kp(0xa6));
        let (m, d) = (me.master.peer_id(), me.device.peer_id());
        let mut r = rooted_with(&me, &recovery, &[&typist, &old]);
        let mut keep = vec![d.clone(), typist.peer_id()];
        keep.sort();
        let at = now_ms() - 1_000;
        r.recoveries.push(roster::sign_recovery(&me.master, &recovery, at, &keep, true));
        // The fold's store half commits; the async half after it never runs.
        let folded = fold_in(&me.db, &me.pass, &r.verified(now_ms()), &typist.peer_id(), &m, &d, Source::Delivered);
        assert!(folded.is_some_and(|f| f.prev.base != f.now.base), "precondition: the fold took the new base");
        assert!(!me.state_of(&m).is_member(&old.peer_id()), "precondition: the new base cut it off");

        let events = asks(&mut me, &old).await;
        assert!(!prompted(&events, &old), "the kept device raised the approval pop-up for the cut-off device");
        assert_eq!(cut_off_here(&me, &old), Some((at, true)));
        let events = asks(&mut me, &fresh).await;
        assert!(!prompted(&events, &fresh), "the kept device raised the approval pop-up for a fresh key");
        assert_eq!(cut_off_here(&me, &fresh), Some((at, false)));
        announce_own_state(&me.events, &d, &me.state_of(&m), &me.db, &me.pass).await;
        let events = me.drain();
        assert!(!prompted(&events, &old) && !prompted(&events, &fresh), "the next start raised the approval pop-up");
    }

    /// HOL-SEC-229 review: a kept device that cannot record what a recovery cut off takes
    /// none of that base: the fold fails, the roster stays as it was.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn rev229_c_a_kept_device_that_cannot_record_the_cut_refuses_the_base() {
        let _g = guard();
        let me = Observer::new(0xb1, 0xb2);
        let (recovery, typist, old) = (kp(0xb3), kp(0xb4), kp(0xb5));
        let (m, d) = (me.master.peer_id(), me.device.peer_id());
        let mut r = rooted_with(&me, &recovery, &[&typist, &old]);
        let before = me.state_of(&m).base;
        let mut keep = vec![d.clone(), typist.peer_id()];
        keep.sort();
        r.recoveries.push(roster::sign_recovery(&me.master, &recovery, now_ms() - 1_000, &keep, true));
        let new_base = r.reverified().base();
        me.store().save_setting(&recovery_cut_off_key(&new_base), "not json").unwrap();
        let folded = fold_in(&me.db, &me.pass, &r.verified(now_ms()), &typist.peer_id(), &m, &d, Source::Delivered);
        assert!(folded.is_none(), "the fold took a base whose cut it could not record");
        assert_eq!(me.state_of(&m).base, before, "the roster moved without the record");
    }

    /// HOL-SEC-229 review, item 5: a recovery that keeps every member (choosing whether
    /// backups wait, confirming the stored phrase) marks nothing, so a backup asking after
    /// it is still put to the person; after a lost recovery the mark stays through such a
    /// base (the master key is still out there) and moves to the date of the newest
    /// recovery that cut a device; a device stays named by its own first cut.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn rev229_d_the_maybe_mark_names_the_newest_recovery_that_cut_a_device() {
        let _g = guard();
        let mut me = Observer::new(0xc1, 0xc2);
        let (recovery, old, other) = (kp(0xc3), kp(0xc4), kp(0xc5));
        let (backup, fresh, later) = (kp(0xc6), kp(0xc7), kp(0xc8));
        let m = me.master.peer_id();
        rooted_with(&me, &recovery, &[&old, &other]);
        let all = |me: &Observer| me.state_of(&m).members.into_iter().collect::<Vec<_>>();
        recover(&me.master, &recovery, &me.device, &all(&me), true, None, &me.db, &me.pass).unwrap();
        let events = asks(&mut me, &backup).await;
        assert!(prompted(&events, &backup), "a recovery that kept every member hid a restored backup");
        assert_eq!(cut_off_here(&me, &backup), None, "a recovery that cut nothing marked an asker");

        let (r1, _) = recover(&me.master, &recovery, &me.device, &[other.peer_id()], true, Some(now_ms() - 1_000), &me.db, &me.pass).unwrap();
        let t1 = r1.base_at().unwrap();
        recover(&me.master, &recovery, &me.device, &all(&me), false, None, &me.db, &me.pass).unwrap();
        asks(&mut me, &old).await;
        asks(&mut me, &fresh).await;
        assert_eq!(cut_off_here(&me, &old), Some((t1, true)), "the cut-off device lost its record through a base keeping every member");
        assert_eq!(cut_off_here(&me, &fresh), Some((t1, false)), "the mark did not stay with the recovery that cut");

        let (r3, _) = recover(&me.master, &recovery, &me.device, &[], true, None, &me.db, &me.pass).unwrap();
        let t3 = r3.base_at().unwrap();
        asks(&mut me, &old).await;
        asks(&mut me, &later).await;
        assert_eq!(cut_off_here(&me, &later), Some((t3, false)), "the mark names an older recovery than the newest one that cut");
        assert_eq!(cut_off_here(&me, &old), Some((t1, true)), "a device is named by its first cut");
        assert_eq!(cut_off_here(&me, &other), None, "a device not asking is named nowhere");
    }

    /// HOL-SEC-229 review, item 6: past the cap the record keeps the newest cuts, and a
    /// device left out still reads as maybe cut off, never as a restored backup.
    #[test]
    fn rev229_e_a_device_past_the_cut_off_cap_still_reads_as_maybe() {
        let me = Observer::new(0xd1, 0xd2);
        let store = me.store();
        let name = |i: usize| format!("dev{i:04}");
        let devices = (0..=MAX_CUT_OFF).map(|i| (name(i), 1_000 + i as i64)).collect();
        note_cut_off(&store, "base", CutOff { devices, unknown_at: None }).unwrap();
        let held = read_cut_off(&store, "base").unwrap();
        assert_eq!(held.devices.len(), MAX_CUT_OFF);
        assert_eq!(held.of(&name(MAX_CUT_OFF)), Some((1_000 + MAX_CUT_OFF as i64, true)), "the newest cut was left out");
        assert_eq!(held.of(&name(0)), Some((1_000, false)), "a device past the cap reads as a restored backup");
    }

    /// HOL-SEC-229 review: a record that cannot be read never makes an asker a restored
    /// backup: no pop-up, and the device list names it as maybe cut off.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn rev229_f_an_unreadable_record_offers_no_asker_as_a_backup() {
        let _g = guard();
        let mut me = Observer::new(0xe1, 0xe2);
        let (recovery, old, fresh) = (kp(0xe3), kp(0xe4), kp(0xe5));
        rooted_with(&me, &recovery, &[&old]);
        let (r, s) = recover(&me.master, &recovery, &me.device, &[], true, Some(now_ms() - 1_000), &me.db, &me.pass).unwrap();
        me.store().save_setting(&recovery_cut_off_key(&s.base), "not json").unwrap();
        let events = asks(&mut me, &fresh).await;
        assert!(!prompted(&events, &fresh), "an unreadable record raised the approval pop-up");
        assert_eq!(cut_off_here(&me, &fresh), Some((r.base_at().unwrap(), false)), "an unreadable record named an asker as a backup");
    }
}
