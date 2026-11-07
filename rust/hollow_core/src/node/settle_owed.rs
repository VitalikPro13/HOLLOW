//! A settling our own roster change owes (DEVICE_PROOF_DESIGN 8.1, 8.3), kept until the
//! settling is persisted. A lost-or-stolen removal or a phrase recovery changes the
//! roster first and settles after; a crash or a stopped node in between would leave the
//! dropped devices' history uncounted for good. Each change notes our roster from before
//! it, and the next start judges every held server by that roster again until the
//! settling is written.

use serde::{Deserialize, Serialize};

use crate::identity::roster::Roster;
use crate::storage::MessageStore;

/// `app_settings` prefix of an owed settling; this device's own, never in a link snapshot.
pub(crate) const PREFIX: &str = "settle_owed:";
/// Owed settlings read at a start: each is the person's own change on this device.
const ROWS_MAX: usize = 16;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Row {
    before: Roster,
    /// Lost or stolen since this time (a removal); `None` for a change whose T the
    /// recovery records (`restore_flow::held_before_recovery`).
    #[serde(default)]
    lost_t_ms: Option<i64>,
    #[serde(default)]
    at_ms: i64,
}

/// One owed settling as read back.
#[derive(Debug, Clone)]
pub(crate) struct Owed {
    pub(crate) key: String,
    pub(crate) before: Roster,
    pub(crate) lost_t_ms: Option<i64>,
    at_ms: i64,
}

/// The key of a lost-or-stolen removal of `device`.
pub(crate) fn lost_key(device: &str) -> String {
    format!("lost:{device}")
}

/// A roster change typed on this device (`api::roster`): what it owes is noted before
/// it lands, and forgotten when it dropped nothing.
pub(crate) struct TypedChange {
    key: String,
    before: Option<(Roster, crate::identity::roster::RosterState)>,
}

impl TypedChange {
    pub(crate) fn begin(store: &MessageStore, master: &str, db_path: &str, db_passphrase: &str) -> Self {
        static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let seq = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let key = format!("change:{}:{seq}", super::types::now_ms());
        let before = super::roster_book::own(master, db_path, db_passphrase);
        if let Some((roster, _)) = &before {
            note(store, &key, roster, None);
        }
        TypedChange { key, before }
    }

    /// The change was refused: nothing is owed.
    pub(crate) fn abort(self, store: &MessageStore) {
        forget(store, &self.key);
    }

    /// The change landed: the devices it dropped (`roster_book::lost_by_own_change`).
    pub(crate) fn landed(self, store: &MessageStore, master: &str, device: &str, db_path: &str, db_passphrase: &str) -> Vec<String> {
        let after = super::roster_book::own(master, db_path, db_passphrase);
        let lost = super::roster_book::lost_by_own_change(self.before.as_ref(), after.as_ref(), device);
        if lost.is_empty() {
            forget(store, &self.key);
        }
        lost
    }
}

/// Note, before our roster changes, that what the change drops owes a settling judged
/// by `before`. A row already under `key` stays: it holds the older roster, the one the
/// node's servers were judged by.
pub(crate) fn note(store: &MessageStore, key: &str, before: &Roster, lost_t_ms: Option<i64>) {
    let full = format!("{PREFIX}{key}");
    if store.load_setting(&full).ok().flatten().is_some() {
        return;
    }
    let row = Row { before: before.clone(), lost_t_ms, at_ms: super::types::now_ms() };
    if let Ok(json) = serde_json::to_string(&row) {
        let _ = store.save_setting(&full, &json);
    }
}

/// The settling owed under `key` is persisted, or nothing was owed.
pub(crate) fn forget(store: &MessageStore, key: &str) {
    let _ = store.delete_setting(&format!("{PREFIX}{key}"));
}

/// Every owed settling, oldest first.
pub(crate) fn load(store: &MessageStore) -> Vec<Owed> {
    let mut out: Vec<Owed> = store
        .load_settings_with_prefix(PREFIX)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|(k, v)| {
            let key = k.strip_prefix(PREFIX).filter(|k| !k.is_empty())?.to_string();
            let row: Row = serde_json::from_str(&v).ok()?;
            Some(Owed { key, before: row.before.reverified(), lost_t_ms: row.lost_t_ms, at_ms: row.at_ms })
        })
        .collect();
    out.sort_by(|a, b| a.at_ms.cmp(&b.at_ms).then_with(|| a.key.cmp(&b.key)));
    out.truncate(ROWS_MAX);
    out
}

/// The devices `owed`'s change dropped, judged against our roster as stored now: none
/// when the change never landed.
pub(crate) fn dropped(store: &MessageStore, owed: &Owed, local_master: &str, local_device: &str) -> Vec<String> {
    if owed.before.master != local_master {
        return Vec::new();
    }
    let before = (owed.before.clone(), super::roster_book::fold(store, &owed.before));
    let now = super::roster_book::load(store, local_master).map(|r| {
        let s = super::roster_book::fold(store, &r);
        (r, s)
    });
    super::roster_book::lost_by_own_change(Some(&before), now.as_ref(), local_device)
}

/// Forget every owed change (not a removal) whose drop `settled` covers. One that dropped
/// nothing yet may still be landing: the change itself forgets it.
pub(crate) fn forget_changes_settled(store: &MessageStore, settled: &[String], local_master: &str, local_device: &str) {
    for owed in load(store).into_iter().filter(|o| o.key.starts_with("change:")) {
        let gone = dropped(store, &owed, local_master, local_device);
        if !gone.is_empty() && gone.iter().all(|d| settled.contains(d)) {
            forget(store, &owed.key);
        }
    }
}

/// Forget the row under `key` when its change dropped nothing (it never landed, or the
/// removal was refused); a landed one waits for its settling.
pub(crate) fn forget_if_nothing_dropped(store: &MessageStore, key: &str, local_master: &str, local_device: &str) {
    if let Some(owed) = load(store).into_iter().find(|o| o.key == key)
        && dropped(store, &owed, local_master, local_device).is_empty()
    {
        forget(store, key);
    }
}

/// At a start, before the servers load: the owed settlings, and our own roster held at
/// the oldest one's `before`, so no fold judges a held server by the change first.
pub(crate) fn hold_at_start(db_path: &str, db_passphrase: &str, local_master: &str) -> Vec<Owed> {
    let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return Vec::new() };
    let owed = load(&store);
    if let Some(oldest) = owed.first() {
        super::authority_view::hold_own_as(&store, local_master, Some(oldest.before.clone()));
    }
    owed
}

/// At a start, before the event loop: write every owed settling as its change's own
/// path would have (the views from before it, its T), then judge by our roster again.
/// Each row goes once what it wrote is on disk.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn settle_at_start(
    owed: Vec<Owed>,
    server_states: &mut super::types::ServerStates,
    crdt_resync: &mut super::crdt_resync::CrdtResync,
    mls: &mut Option<crate::crypto::MlsManager>,
    ws_cmd_tx: &super::types::WsCmdTx,
    ws_room_peers: &super::types::WsRoomPeers,
    gossip_overlays: &mut super::types::GossipOverlays,
    event_tx: &super::types::EventTx,
    local_master: &str,
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    crypto_store: &crate::crypto::CryptoStore,
    crdt_store: &super::crdt_store::CrdtStore,
    db_path: &str,
    db_passphrase: &str,
) {
    if owed.is_empty() {
        return;
    }
    let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return };
    let device = device_keypair.peer_id();
    type Views = std::collections::HashMap<String, std::sync::Arc<crate::crdt::authority::AuthorityView>>;
    let mut covered: Vec<String> = Vec::new();
    let mut work: Vec<(Vec<String>, Views, u64)> = Vec::new();
    for o in &owed {
        let gone: Vec<String> = dropped(&store, o, local_master, &device).into_iter().filter(|d| !covered.contains(d)).collect();
        if gone.is_empty() {
            continue;
        }
        covered.extend(gone.iter().cloned());
        let views = match o.lost_t_ms {
            Some(t) => Some((server_states.iter().map(|(sid, s)| (sid.clone(), s.authority.clone())).collect(), t.max(0) as u64)),
            None => {
                super::lock_keeper::note_dropped_devices(local_master, &gone);
                super::restore_flow::held_before_recovery(server_states, &store, local_master, &gone)
            }
        };
        if let Some((views, t_ms)) = views {
            work.push((gone, views, t_ms));
        }
    }
    super::authority_view::release_own(&store, local_master);
    for (gone, views, t_ms) in work {
        crate::hollow_log!("[HOLLOW-CRDT] Settling for {} device(s) our roster dropped before the last stop", gone.len());
        let settled = super::sync_handler::settle_lost_devices(
            server_states, &views, mls, ws_cmd_tx, ws_room_peers, gossip_overlays, event_tx, local_master, device_keypair, &gone, t_ms,
            crypto_store, crdt_store, db_path, db_passphrase,
        );
        for (sid, masters, ops) in settled {
            crdt_resync.floor.note_settled(&sid, masters, ops, std::time::Instant::now());
        }
    }
    crdt_store.committed().await;
    for o in &owed {
        forget(&store, &o.key);
    }
}

#[cfg(test)]
static STALL: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// Harness: the node at `db_path` stops dead once, right after its next removal saved
/// our roster and before anything it owes is written, as a crash there would.
#[cfg(test)]
pub(crate) fn stall_after_roster_save_for_test(db_path: &str) {
    STALL.lock().unwrap_or_else(|e| e.into_inner()).push(db_path.to_string());
}

#[cfg(test)]
pub(crate) fn stalls_for_test(db_path: &str) -> bool {
    let mut stall = STALL.lock().unwrap_or_else(|e| e.into_inner());
    let before = stall.len();
    stall.retain(|p| p != db_path);
    stall.len() != before
}
