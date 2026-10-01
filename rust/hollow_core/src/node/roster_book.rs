//! Every identity's roster as this node holds it (design ID-1): storage, the fold on
//! this node's own clock, our own roster's upkeep and changes, ingest, and the inbox
//! proof the relay still reads.
//!
//! The resolver holds members only. A device that holds the master key but is pending,
//! removed or unknown to the roster resolves to itself, so it is never "one of us".

use std::collections::BTreeSet;

use tokio::sync::mpsc;

use crate::identity::native_identity::NativeKeypair;
use crate::identity::roster::{self, Roster, RosterState};
use crate::storage::MessageStore;

use super::types::{NetworkEvent, SignedDeviceList};

/// A roster bigger than this on the wire is dropped whole.
pub(crate) const MAX_ROSTER_BYTES: usize = 256 * 1024;
/// Statements the node imports at its next start, written where the database is not
/// open yet (a new identity, a phrase typed before the node runs).
pub(crate) const BOOTSTRAP_FILE: &str = "roster_bootstrap.json";

const OWN_REMOVED_BY: &str = "own_removed_by";
const OWN_REMOVED_AT: &str = "own_removed_at_ms";

pub(crate) fn now_ms() -> i64 {
    super::types::now_ms()
}

/// The stored roster for `master`, verified. `None` for no row, or a 0.11 row.
pub(crate) fn load(store: &MessageStore, master: &str) -> Option<Roster> {
    store
        .load_roster(master)
        .ok()
        .flatten()
        .map(|r| r.verified(now_ms()))
        .filter(|r| r.master == master)
}

/// Fold `roster` on this node's own first-sight clock.
pub(crate) fn fold(store: &MessageStore, roster: &Roster) -> RosterState {
    let seen = store.load_roster_seen(&roster.master).unwrap_or_default();
    roster.fold(|d| seen.get(d).copied(), now_ms())
}

/// Stamp when this node first saw each pending join in `roster`.
fn stamp_pending(store: &MessageStore, roster: &Roster) {
    let now = now_ms();
    for p in &roster.pendings {
        let _ = store.stamp_roster_seen(&roster.master, &p.device, now);
    }
}

/// Persist `roster` and point its master's links at the members. The resolver
/// follows: a device that stopped being a member stops resolving to the master.
fn save(
    store: &MessageStore,
    roster: &Roster,
    state: &RosterState,
    local_master: &str,
    local_device: &str,
) -> Result<(), String> {
    let json = serde_json::to_string(roster).map_err(|e| format!("roster json: {e}"))?;
    let members: Vec<String> = state.members.iter().cloned().collect();
    store.save_device_list(&roster.master, &json, inbox_version(roster, state), &members, now_ms())?;
    for d in super::resolver::devices_for(&roster.master) {
        if !state.members.contains(&d) {
            super::resolver::forget(&d);
        }
    }
    if roster.master == local_master {
        super::resolver::seed_self(local_master, &members);
    } else {
        super::resolver::update_many(&roster.master, members.iter().map(String::as_str));
    }
    // Removed devices are refused everywhere and the refusal survives a restart; a
    // member that a recovery brought back is refused no longer. Never ourselves.
    let removed: Vec<String> = state
        .removed
        .keys()
        .filter(|d| d.as_str() != local_device)
        .cloned()
        .collect();
    if !removed.is_empty() {
        super::resolver::mark_revoked(&removed);
        let _ = store.record_revoked_devices(&roster.master, &removed);
    }
    let back: Vec<String> = members
        .iter()
        .filter(|d| super::resolver::is_revoked(d))
        .cloned()
        .collect();
    if !back.is_empty() {
        super::resolver::unmark_revoked(&back);
        let _ = store.clear_revoked_devices(&back);
    }
    Ok(())
}

/// Merge `roster` into what `store` holds for its master and save it, the way an
/// ingest would. Tests only: it stages state a scenario starts from.
#[cfg(test)]
pub(crate) fn merge_for_test(store: &MessageStore, roster: &Roster, local_master: &str, local_device: &str) {
    let merged = load(store, &roster.master)
        .unwrap_or_else(|| Roster::new(&roster.master))
        .merged(&roster.verified(now_ms()));
    stamp_pending(store, &merged);
    let state = fold(store, &merged);
    save(store, &merged, &state, local_master, local_device).expect("save roster");
}

/// A version the relay's inbox marks accept from every device of one identity alike:
/// it grows with the roster (a newer base, or more statements in the same base) and
/// two devices holding the same roster produce the same number.
fn inbox_version(roster: &Roster, state: &RosterState) -> u64 {
    let count = (roster.consents.len()
        + roster.vouches.len()
        + roster.pendings.len()
        + roster.legacy.len()
        + roster.removals.len()
        + roster.phrase_admits.len())
    .min(999) as u64;
    let base_at = if state.protected {
        roster.recoveries.iter().map(|r| r.at_ms).max().unwrap_or(0).max(0) as u64
    } else {
        0
    };
    if base_at > 0 {
        base_at.saturating_mul(1000).saturating_add(count)
    } else {
        1_000_000_000 + count
    }
}

/// The master-signed list of our members the relay reads to let this device into our
/// own inbox (until ID-1R teaches the relay rosters).
pub(crate) fn inbox_proof(
    master: &NativeKeypair,
    db_path: &str,
    db_passphrase: &str,
) -> Option<SignedDeviceList> {
    let store = MessageStore::open(db_path, db_passphrase).ok()?;
    let roster = load(&store, &master.peer_id())?;
    let state = fold(&store, &roster);
    if state.members.is_empty() {
        return None;
    }
    Some(super::crypto_handler::build_signed_device_list(
        master,
        inbox_version(&roster, &state),
        state.members.iter().cloned().collect(),
        state.removed.keys().cloned().collect(),
    ))
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
/// names claims its legacy seat (and removes what that list had revoked), a device
/// the list does not name asks to join, and a brand-new database claims a legacy seat
/// for a fresh identity. With a roster, a device that is nothing in it asks to join.
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

    let mut roster = match roster {
        Some(r) => r,
        None => {
            let mut r = Roster::new(&own);
            match store.load_device_list(&own).ok().flatten() {
                Some(old) if old.devices.iter().any(|d| d == &me) => {
                    r.add_legacy(roster::sign_legacy(master, &me));
                    for gone in old.revoked.iter().filter(|g| **g != me) {
                        r.add_removal(roster::sign_removal(device, &own, roster::LEGACY_BASE, gone, &[]));
                    }
                    hollow_log!("[HOLLOW-ROSTER] Claimed this device's seat from the 0.11 list");
                }
                Some(_) => {}
                None => r.add_legacy(roster::sign_legacy(master, &me)),
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
    let roster = roster.verified(now_ms());
    let _ = save(store, &roster, &state, &own, &me);
    // The phrase has been typed on 0.12 somewhere, so no copy of it stays here.
    if !roster.r_pub.is_empty() {
        let _ = store.delete_setting(STORED_PHRASE);
    }
    (roster, state)
}

/// Where 0.11 kept the recovery phrase, read once for the upgrade and then erased.
pub(crate) const STORED_PHRASE: &str = "recovery_mnemonic";

/// Our own roster and its fold, as stored.
pub(crate) fn own(master: &str, db_path: &str, db_passphrase: &str) -> Option<(Roster, RosterState)> {
    let store = MessageStore::open(db_path, db_passphrase).ok()?;
    let roster = load(&store, master)?;
    let state = fold(&store, &roster);
    Some((roster, state))
}

/// Our own roster as every carrier sends it. `None` only when the database is
/// unavailable; the carrier then goes without one.
pub(crate) fn own_roster(master: &str, db_path: &str, db_passphrase: &str) -> Option<Roster> {
    own(master, db_path, db_passphrase).map(|(r, _)| r)
}

/// The room only holders of our master key can name. Every device of the identity
/// joins it, a waiting or removed one too: an identity with no contacts and no
/// servers shares no other room with a restored backup, and its answer was lost.
pub(crate) fn own_room(local_master: &str) -> String {
    super::dm_room::dm_room_code(local_master, local_master)
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
    let store = MessageStore::open(db_path, db_passphrase)?;
    let own = master.peer_id();
    let mut roster = load(&store, &own).unwrap_or_else(|| Roster::new(&own));
    let before = fold(&store, &roster);
    change(&mut roster, &before)?;
    let roster = roster.verified(now_ms());
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

/// This device removes `target`, keeping the members it had vouched for.
pub(crate) fn remove(
    master: &NativeKeypair,
    device: &NativeKeypair,
    target: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Result<(Roster, RosterState), String> {
    change_own(master, device, db_path, db_passphrase, |r, s| {
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
        let keep = r.vouched_members_of(target, s);
        r.add_removal(roster::sign_removal(device, &r.master.clone(), &s.base, target, &keep));
        Ok(())
    })
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
        let master_id = r.master.clone();
        for target in s.members.iter().chain(s.pending.iter()).filter(|d| **d != me) {
            r.add_removal(roster::sign_removal(device, &master_id, &s.base, target, std::slice::from_ref(&me)));
            gone.push(target.clone());
        }
        if gone.is_empty() {
            return Err("This is already your only device.".into());
        }
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
    let store = MessageStore::open(db_path, db_passphrase).ok()?;
    let own = master.peer_id();
    let mut roster = load(&store, &own)?;
    let state = fold(&store, &roster);
    let me = device.peer_id();
    roster.add_removal(roster::sign_removal(device, &own, &state.base, &me, &[]));
    Some(roster.verified(now_ms()))
}

/// The phrase starts a new base keeping `keep` and this device.
pub(crate) fn recover(
    master: &NativeKeypair,
    recovery: &NativeKeypair,
    device: &NativeKeypair,
    keep: &[String],
    db_path: &str,
    db_passphrase: &str,
) -> Result<(Roster, RosterState), String> {
    change_own(master, device, db_path, db_passphrase, |r, _| {
        let mut keep: Vec<String> = keep.to_vec();
        keep.push(device.peer_id());
        keep.sort();
        keep.dedup();
        if !r.has_consent(&device.peer_id()) {
            r.add_consent(roster::sign_consent(device, &r.master.clone()));
        }
        let rec = roster::sign_recovery(master, recovery, now_ms(), &keep);
        r.add_phrase_statement(&roster::r_pub_of(recovery), Some(rec), None)
    })
}

/// The phrase admits this device into whatever base is current.
pub(crate) fn admit_by_phrase(
    master: &NativeKeypair,
    recovery: &NativeKeypair,
    device: &NativeKeypair,
    db_path: &str,
    db_passphrase: &str,
) -> Result<(Roster, RosterState), String> {
    change_own(master, device, db_path, db_passphrase, |r, _| {
        if !r.has_consent(&device.peer_id()) {
            r.add_consent(roster::sign_consent(device, &r.master.clone()));
        }
        let pa = roster::sign_phrase_admit(master, recovery, now_ms(), &device.peer_id());
        r.add_phrase_statement(&roster::r_pub_of(recovery), None, Some(pa))
    })
}

/// When this device learned it was removed and who removed it, if it was.
pub(crate) fn own_removal(store: &MessageStore) -> Option<(String, i64)> {
    let by = store.load_setting(OWN_REMOVED_BY).ok().flatten().filter(|b| !b.is_empty())?;
    let at = store.load_setting(OWN_REMOVED_AT).ok().flatten()?.parse::<i64>().ok()?;
    Some((by, at))
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
    let Ok(store) = MessageStore::open(db_path, db_passphrase) else { return };
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
    for device in state.pending.iter().filter(|d| d.as_str() != local_device) {
        let _ = event_tx
            .send(NetworkEvent::PendingDeviceAsking { device_peer_id: device.clone() })
            .await;
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
    // Each friend's whole DM room: we may know none of its devices yet, and a
    // single-device friend's device is its master id, which no link names.
    let friends = MessageStore::open(db_path, db_passphrase)
        .and_then(|s| s.load_friends(Some("accepted")))
        .unwrap_or_default();
    let dm_rooms = friends.into_iter().map(|(peer, ..)| {
        super::dm_room::dm_room_code(local_master, &super::resolver::resolve(&peer))
    });
    for room in dm_rooms {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::JoinRoom { room_code: room.clone() });
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom { room_code: room, data: data.clone() });
    }
    for sid in server_ids {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendToRoom {
            room_code: sid.clone(),
            data: data.clone(),
        });
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
        event_tx, ws_cmd_tx, local_master, local_device, sender, incoming, db_path, db_passphrase,
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
) -> Ingested {
    let Some(incoming) = incoming else { return Ingested::default() };
    if serde_json::to_vec(&incoming).map(|b| b.len()).unwrap_or(usize::MAX) > MAX_ROSTER_BYTES {
        hollow_log!("[HOLLOW-SECURITY] Dropped an oversized roster from {sender}");
        return Ingested::default();
    }
    let incoming = incoming.verified(now_ms());
    let master = incoming.master.clone();
    if master.is_empty() {
        return Ingested::default();
    }
    let Ok(store) = MessageStore::open(db_path, db_passphrase) else {
        return Ingested::default();
    };
    let stored = load(&store, &master);
    let known = stored.is_some() || store.load_device_list(&master).ok().flatten().is_some();
    if !known {
        let alone = incoming.fold(|_| None, now_ms());
        if !alone.is_member(sender) {
            hollow_log!(
                "[HOLLOW-SECURITY] Dropped a roster for {master}: its deliverer {sender} is not one of its members"
            );
            return Ingested::default();
        }
    }
    let base = stored.clone().unwrap_or_else(|| Roster::new(&master));
    let merged = base.merged(&incoming);
    stamp_pending(&store, &merged);
    // Members as last saved, not re-folded now: a pending join that matured since
    // then is a member this ingest adds, and contacts are told.
    let prev = stored
        .as_ref()
        .map(|r| RosterState {
            members: store.device_links_for(&master).unwrap_or_default(),
            ..fold(&store, r)
        })
        .unwrap_or_default();
    let now = fold(&store, &merged);
    let changed = stored.as_ref() != Some(&merged) || prev != now;

    if changed {
        if let Err(e) = save(&store, &merged, &now, local_master, local_device) {
            hollow_log!("[HOLLOW-ROSTER] Failed to save the roster for {master}: {e}");
            return Ingested::default();
        }
    } else if master == local_master {
        super::resolver::seed_self(local_master, &now.members.iter().cloned().collect::<Vec<_>>());
    } else {
        super::resolver::update_many(&master, now.members.iter().map(String::as_str));
    }

    for dev in now.members.iter().map(String::as_str).chain(std::iter::once(sender)) {
        if super::resolver::resolve(dev) == master
            && let Ok(true) = store.migrate_friend_to_master(dev, &master)
        {
            hollow_log!("[HOLLOW-FRIENDS] Re-keyed friend {dev} -> master {master}");
        }
    }

    let newly_revoked: Vec<String> = prev
        .members
        .iter()
        .filter(|d| now.removed.contains_key(*d) && d.as_str() != local_device)
        .cloned()
        .collect();
    let added: Vec<String> = now.members.difference(&prev.members).cloned().collect();

    if master == local_master {
        drop(store);
        own_changes(event_tx, local_device, &prev, &now, db_path, db_passphrase).await;
        if sender != local_device && now.is_member(sender) {
            super::crypto_handler::share_state_with_sibling(ws_cmd_tx, sender, db_path, db_passphrase);
        }
    } else {
        drop(store);
        if !added.is_empty() {
            super::destroy::note_identity_reappeared(event_tx, db_path, db_passphrase, &master).await;
        }
        let before: Vec<String> = prev.members.iter().cloned().collect();
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
    Ingested {
        our_devices_grew: master == local_master && changed,
        newly_revoked,
        added: if master == local_master { added } else { Vec::new() },
    }
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
    let Ok(store) = MessageStore::open(db_path, db_passphrase) else { return };
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
    let asking: BTreeSet<&String> = now.pending.difference(&prev.pending).collect();
    for device in asking.into_iter().filter(|d| d.as_str() != local_device) {
        let _ = event_tx
            .send(NetworkEvent::PendingDeviceAsking { device_peer_id: device.clone() })
            .await;
    }
}

/// The master a carried roster attributes `sender` to, read after [`ingest`]: its
/// master when the sender is a member of what we now hold for it.
pub(crate) fn carried_master(roster: &Roster, sender: &str) -> Option<String> {
    let bound = super::resolver::resolve(sender) == roster.master;
    (bound && !super::resolver::is_revoked(sender)).then(|| roster.master.clone())
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
    let Ok(store) = MessageStore::open(db_path, db_passphrase) else { return false };
    let view = match load(&store, &carried.master) {
        Some(stored) => stored.merged(&carried),
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
        _tmp: tempfile::TempDir,
    }

    impl Observer {
        fn new(master: u8, device: u8) -> Self {
            let tmp = tempfile::tempdir().unwrap();
            let db = tmp.path().join("roster.db").to_str().unwrap().to_string();
            let pass = "cd".repeat(32);
            MessageStore::migrate_auto_vacuum_once(&db, &pass).unwrap();
            let (events, event_rx) = mpsc::channel(256);
            let (ws, _ws_rx) = tokio::sync::mpsc::unbounded_channel();
            Observer { master: kp(master), device: kp(device), db, pass, events, event_rx, ws, _ws_rx, _tmp: tmp }
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

        me.store().set_roster_seen(&bob.peer_id(), &restored.peer_id(), now_ms() - PENDING_MATURITY_MS).unwrap();
        assert!(me.state_of(&bob.peer_id()).is_member(&restored.peer_id()), "seven quiet days admit it");

        r.add_removal(sign_removal(&bob_dev, &bob.peer_id(), LEGACY_BASE, &restored.peer_id(), &[]));
        me.ingest(&bob_dev.peer_id(), &r).await;
        assert!(!me.state_of(&bob.peer_id()).is_member(&restored.peer_id()), "a refusal keeps it out");
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

        let (_, state) = recover(&me.master, &recovery, &me.device, &[], &me.db, &me.pass).unwrap();
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

    /// The bootstrap a phrase wrote is imported once, and a stored 0.11 phrase is gone
    /// the moment the identity has a recovery key.
    #[test]
    fn the_bootstrap_is_imported_and_the_stored_phrase_erased() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        me.store().save_setting(STORED_PHRASE, "abandon abandon").unwrap();
        write_bootstrap(&me.dir(), &Roster::genesis(&me.master, &kp(0x03), &me.device, now_ms())).unwrap();
        let (roster, state) = me.own();
        assert!(state.protected && roster.r_pub == r_pub_of(&kp(0x03)));
        assert!(!me.dir().join(BOOTSTRAP_FILE).exists(), "the bootstrap is consumed");
        assert_eq!(me.store().load_setting(STORED_PHRASE).unwrap(), None, "the stored phrase outlived the recovery key");
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

    /// The relay's inbox proof names our members only, at a version every device of
    /// ours computes alike from the same roster, and a recovery outranks legacy.
    #[test]
    fn the_inbox_proof_names_members_at_a_shared_version() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        let (roster, _) = me.own();
        let sibling = Observer::new(0x01, 0x07);
        let mut theirs = roster.clone();
        theirs.add_consent(sign_consent(&sibling.device, &me.master.peer_id()));
        theirs.add_legacy(sign_legacy(&me.master, &sibling.device.peer_id()));
        merge_for_test(&me.store(), &theirs, &me.master.peer_id(), &me.device.peer_id());
        merge_for_test(&sibling.store(), &theirs, &me.master.peer_id(), &sibling.device.peer_id());
        let asking = kp(0x08);
        let mut with_pending = theirs.clone();
        with_pending.add_consent(sign_consent(&asking, &me.master.peer_id()));
        with_pending.add_pending(sign_pending(&me.master, LEGACY_BASE, &asking.peer_id()));
        merge_for_test(&me.store(), &with_pending, &me.master.peer_id(), &me.device.peer_id());
        merge_for_test(&sibling.store(), &with_pending, &me.master.peer_id(), &sibling.device.peer_id());
        let a = inbox_proof(&me.master, &me.db, &me.pass).unwrap();
        let b = inbox_proof(&me.master, &sibling.db, &sibling.pass).unwrap();
        assert!(super::super::crypto_handler::verify_device_list(&a));
        assert_eq!(a.version, b.version);
        assert_eq!(a.devices.len(), 2);
        assert!(!a.devices.contains(&asking.peer_id()), "a device that only asks is no owner of the inbox");
        let (_, state) = recover(&me.master, &kp(0x03), &me.device, &[], &me.db, &me.pass).unwrap();
        assert!(state.protected);
        let c = inbox_proof(&me.master, &me.db, &me.pass).unwrap();
        assert!(c.version > a.version, "a recovery must outrank every legacy proof at the relay");
    }

    /// The first recovery key an identity shows is the one it keeps.
    #[test]
    fn a_recovery_keeps_the_phrase_key_pinned() {
        let _g = guard();
        let me = Observer::new(0x01, 0x02);
        me.own();
        recover(&me.master, &kp(0x03), &me.device, &[], &me.db, &me.pass).unwrap();
        assert!(
            recover(&me.master, &kp(0x04), &me.device, &[], &me.db, &me.pass).is_err(),
            "a second recovery key replaced the pinned one",
        );
    }
}
