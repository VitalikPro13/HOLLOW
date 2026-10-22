//! Past epochs, kept outside OpenMLS. The relay's rings and resumed sessions replay
//! ciphertext after the receiver merged newer commits, so a frame from up to
//! [`MAX_PAST_EPOCHS`] epochs back must still open. OpenMLS's own window keeps each
//! past epoch's member list inside the message secrets it rewrites on every message,
//! which made every message O(N) (63 ms at 1k members, G1 scale probe fix 4).
//!
//! Instead, each merge keeps the group's rows as they stood, compressed into one row
//! (`PACKED`), and a late frame opens in a store unpacked from it against that
//! epoch's tree. The live group carries no past epochs; a past store is written once,
//! and after that only the rows a late frame changes, beside the packed one.

use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::sync::Mutex;

use openmls::prelude::*;
use openmls_traits::OpenMlsProvider;

use super::mls_storage::{label, past_scope, row_key, rows_from_blob, MlsProvider, MlsSave, PastRows, Rows};

/// Past epochs kept per group: the window OpenMLS's `max_past_epochs(3)` gave before.
pub(crate) const MAX_PAST_EPOCHS: usize = 3;

/// What opening a frame needs of a group, by row. Never the epoch key pairs (the
/// private keys that open commits) nor queued proposals.
const GROUP_ROWS: [&[u8]; 11] = [
    label::TREE,
    label::GROUP_CONTEXT,
    label::INTERIM_TRANSCRIPT_HASH,
    label::CONFIRMATION_TAG,
    label::JOIN_CONFIG,
    label::OWN_LEAF_NODES,
    label::GROUP_STATE,
    label::OWN_LEAF_NODE_INDEX,
    label::EPOCH_SECRETS,
    label::RESUMPTION_PSK,
    label::MESSAGE_SECRETS,
];

/// The epoch secrets a past store has no use for: it opens application messages
/// only, never exports a key, derives the next epoch or resumes. The epoch
/// authenticator stays.
const UNUSED_EPOCH_SECRETS: [&str; 4] = ["init_secret", "exporter_secret", "external_secret", "resumption_psk"];

/// The key of a past scope's packed row. No OpenMLS row key starts with a zero byte.
const PACKED: &[u8] = b"\0packed";

/// A group's rows taken before a merge, packed, kept once the merge went through.
pub(crate) struct Capture {
    epoch: u64,
    packed: Vec<u8>,
    /// The message secrets, kept apart from the packed rows: a late frame rewrites
    /// them, and the keys it consumed must not stay derivable in the packed copy.
    secrets: Rows,
}

impl Capture {
    #[cfg(test)]
    pub fn packed_len(&self) -> usize {
        self.packed.len()
    }
}

struct PastEpoch {
    epoch: u64,
    packed: Vec<u8>,
    /// The packed row is not on disk yet.
    packed_unsaved: std::sync::atomic::AtomicBool,
    /// Rows changed since the packing, laid over it; an empty value is a deleted row.
    /// Small: the message secrets a late frame moves.
    overrides: Mutex<HashMap<Vec<u8>, Vec<u8>>>,
    /// Unpacked on the first late frame, and let go once idle for [`OPEN_IDLE`].
    open: Mutex<Option<OpenPast>>,
}

struct OpenPast {
    provider: MlsProvider,
    group: Option<MlsGroup>,
    used: std::time::Instant,
}

/// How long an unpacked past epoch stays in RAM after its last late frame: a crafted
/// frame naming a past epoch must not pin a whole tree for good.
const OPEN_IDLE: std::time::Duration = std::time::Duration::from_secs(600);

impl PastEpoch {
    fn new(epoch: u64, packed: Vec<u8>, overrides: HashMap<Vec<u8>, Vec<u8>>, unsaved: bool) -> Self {
        PastEpoch {
            epoch,
            packed,
            packed_unsaved: std::sync::atomic::AtomicBool::new(unsaved),
            overrides: Mutex::new(overrides),
            open: Mutex::new(None),
        }
    }

    fn open_slot(&self) -> std::sync::MutexGuard<'_, Option<OpenPast>> {
        self.open.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn overrides(&self) -> std::sync::MutexGuard<'_, HashMap<Vec<u8>, Vec<u8>>> {
        self.overrides.lock().unwrap_or_else(|e| e.into_inner())
    }
}

fn pack(rows: &Rows) -> Option<Vec<u8>> {
    let mut blob = Vec::new();
    blob.extend_from_slice(&(rows.len() as u64).to_be_bytes());
    for (k, v) in rows {
        blob.extend_from_slice(&(k.len() as u64).to_be_bytes());
        blob.extend_from_slice(&(v.len() as u64).to_be_bytes());
        blob.extend_from_slice(k);
        blob.extend_from_slice(v);
    }
    let mut out = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::fast());
    out.write_all(&blob).ok()?;
    out.finish().ok()
}

pub(crate) fn unpack(packed: &[u8]) -> Result<Rows, String> {
    let mut blob = Vec::new();
    flate2::read::DeflateDecoder::new(packed).read_to_end(&mut blob).map_err(|e| format!("unpack: {e}"))?;
    rows_from_blob(&blob)
}

#[derive(Default)]
pub(crate) struct PastEpochs {
    /// Per group key, oldest first.
    held: HashMap<String, VecDeque<PastEpoch>>,
    /// Stored past epochs of groups this process did not load (a push fetch loads
    /// one server): left on disk as they are, erased with their group.
    dormant: HashMap<String, Vec<u64>>,
    /// Scopes the next save empties.
    cleared: Mutex<Vec<String>>,
}

/// Zero every byte string under `value`.
fn zero_bytes(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Array(items) => {
            for item in items {
                if item.is_number() {
                    *item = 0.into();
                } else {
                    zero_bytes(item);
                }
            }
        }
        serde_json::Value::Object(fields) => fields.values_mut().for_each(zero_bytes),
        _ => {}
    }
}

/// `row` without the secrets a past store never uses; `None` when its shape is not
/// the one this was written for, so nothing unscrubbed is kept.
fn scrubbed(key: &[u8], row: Vec<u8>, gid: &GroupId) -> Option<Vec<u8>> {
    let is = |l: &[u8]| key == row_key(l, gid).as_slice();
    // Mid-merge the state is our staged commit, which holds the NEXT epoch's secrets
    // and path keys; a past store only ever opens frames.
    if is(label::GROUP_STATE) {
        return serde_json::to_vec(&MlsGroupState::Operational).ok();
    }
    if !is(label::EPOCH_SECRETS) && !is(label::RESUMPTION_PSK) {
        return Some(row);
    }
    let mut value: serde_json::Value = serde_json::from_slice(&row).ok()?;
    let fields = value.as_object_mut()?;
    if is(label::EPOCH_SECRETS) {
        for name in UNUSED_EPOCH_SECRETS {
            zero_bytes(fields.get_mut(name)?);
        }
    } else {
        *fields.get_mut("resumption_psk")? = serde_json::Value::Array(Vec::new());
    }
    serde_json::to_vec(&value).ok()
}

impl PastEpochs {
    /// `group`'s rows as they stand, to keep if the merge about to happen goes through.
    pub fn capture(live: &MlsProvider, group: &MlsGroup) -> Option<Capture> {
        let gid = group.group_id();
        let keys: Vec<Vec<u8>> = GROUP_ROWS.iter().map(|l| row_key(l, gid)).collect();
        let mut rows = Vec::with_capacity(keys.len());
        for (key, row) in live.storage().rows(&keys) {
            let Some(row) = scrubbed(&key, row, gid) else {
                hollow_log!("[HOLLOW-MLS] Kept no past epoch: a stored row is not in the shape it was written for");
                return None;
            };
            rows.push((key, row));
        }
        let secrets_key = row_key(label::MESSAGE_SECRETS, gid);
        let (secrets, rows): (Rows, Rows) = rows.into_iter().partition(|(k, _)| *k == secrets_key);
        Some(Capture { epoch: group.epoch().as_u64(), packed: pack(&rows)?, secrets })
    }

    fn clear(&self, scope: String) {
        self.cleared.lock().unwrap_or_else(|e| e.into_inner()).push(scope);
    }

    /// Keep `capture` as a past epoch of `group_key`, now at `current`; the oldest
    /// beyond the window goes. A merge that moved nothing keeps nothing.
    pub fn keep(&mut self, group_key: &str, capture: Option<Capture>, current: u64) {
        let Some(Capture { epoch, packed, secrets }) = capture.filter(|c| c.epoch < current) else { return };
        let mut gone = Vec::new();
        let ring = self.held.entry(group_key.to_string()).or_default();
        if let Some(pos) = ring.iter().position(|p| p.epoch == epoch) {
            ring.remove(pos);
            gone.push(epoch);
        }
        ring.push_back(PastEpoch::new(epoch, packed, secrets.into_iter().collect(), true));
        ring.make_contiguous().sort_by_key(|p| p.epoch);
        while ring.len() > MAX_PAST_EPOCHS {
            gone.extend(ring.pop_front().map(|p| p.epoch));
        }
        for epoch in gone {
            self.clear(past_scope(group_key, epoch));
        }
    }

    /// Forget every past epoch of `group_key`, held or dormant.
    pub fn drop_group(&mut self, group_key: &str) {
        let held = self.held.remove(group_key).into_iter().flatten().map(|p| p.epoch);
        let dormant = self.dormant.remove(group_key).into_iter().flatten();
        for epoch in held.chain(dormant).collect::<Vec<_>>() {
            self.clear(past_scope(group_key, epoch));
        }
    }

    /// Erase the dormant past epochs of groups `keep` does not name; their keys.
    pub fn drop_dormant_unless(&mut self, keep: impl Fn(&str) -> bool) -> Vec<String> {
        let gone: Vec<String> = self.dormant.keys().filter(|k| !keep(k)).cloned().collect();
        for key in &gone {
            self.drop_group(key);
        }
        gone
    }

    /// TEST-ONLY: how many past epochs are unpacked in RAM now.
    #[cfg(test)]
    pub fn open_count(&self) -> usize {
        self.held.values().flatten().filter(|p| p.open_slot().is_some()).count()
    }

    /// TEST-ONLY: make every unpacked past epoch look unused for `by`.
    #[cfg(test)]
    pub fn age_open(&self, by: std::time::Duration) {
        for past in self.held.values().flatten() {
            if let Some(o) = past.open_slot().as_mut() {
                o.used -= by;
            }
        }
    }

    /// Every past scope this manager knows of, held or dormant.
    pub fn scopes(&self) -> Vec<String> {
        let held = self.held.iter().flat_map(|(g, ring)| ring.iter().map(move |p| past_scope(g, p.epoch)));
        let dormant = self.dormant.iter().flat_map(|(g, epochs)| epochs.iter().map(move |e| past_scope(g, *e)));
        held.chain(dormant).collect()
    }

    /// Run `open` on `group_key` as it stood at `epoch`, when that epoch is kept.
    pub fn open<R>(
        &mut self,
        group_key: &str,
        epoch: u64,
        open: impl FnOnce(&mut MlsGroup, &MlsProvider) -> R,
    ) -> Option<R> {
        let past = self.held.get_mut(group_key)?.iter_mut().find(|p| p.epoch == epoch)?;
        let mut slot = past.open_slot();
        if slot.is_none() {
            let provider = MlsProvider::default();
            match unpack(&past.packed) {
                Ok(rows) => provider.storage().load_rows(rows),
                Err(e) => hollow_log!("[HOLLOW-MLS] Past epoch {epoch} of {group_key} did not unpack: {e}"),
            }
            provider.storage().lay_over(past.overrides().iter().map(|(k, v)| (k.clone(), v.clone())));
            let gid = GroupId::from_slice(group_key.as_bytes());
            let group = match MlsGroup::load(provider.storage(), &gid) {
                Ok(group) => group,
                Err(e) => {
                    hollow_log!("[HOLLOW-MLS] Past epoch {epoch} of {group_key} did not load: {e:?}");
                    None
                }
            };
            *slot = Some(OpenPast { provider, group, used: std::time::Instant::now() });
        }
        let opened = slot.as_mut()?;
        opened.used = std::time::Instant::now();
        let OpenPast { provider, group, .. } = opened;
        Some(open(group.as_mut()?, provider))
    }

    /// The past epochs held for `group_key`, oldest first.
    #[cfg(test)]
    pub fn epochs(&self, group_key: &str) -> Vec<u64> {
        self.held.get(group_key).map(|r| r.iter().map(|p| p.epoch).collect()).unwrap_or_default()
    }

    /// Past epochs left on disk unread, `(group key, epoch)`: erased with their group.
    pub fn note_dormant(&mut self, scopes: impl Iterator<Item = (String, u64)>) {
        for (group_key, epoch) in scopes {
            self.dormant.entry(group_key).or_default().push(epoch);
        }
    }

    /// Take back the stored past epochs: those of `loaded` groups (key -> current
    /// epoch) still inside the window are held, the rest of theirs erased; other
    /// groups' stay dormant.
    pub fn restore(&mut self, scopes: PastRows, loaded: &HashMap<String, u64>) {
        let mut by_group: HashMap<String, Vec<(u64, Rows)>> = HashMap::new();
        for ((group_key, epoch), rows) in scopes {
            by_group.entry(group_key).or_default().push((epoch, rows));
        }
        for (group_key, mut epochs) in by_group {
            let Some(&current) = loaded.get(&group_key) else {
                self.dormant.insert(group_key, epochs.into_iter().map(|(e, _)| e).collect());
                continue;
            };
            epochs.sort_by_key(|(e, _)| std::cmp::Reverse(*e));
            let mut ring = VecDeque::new();
            for (epoch, rows) in epochs {
                let mut overrides: HashMap<Vec<u8>, Vec<u8>> = rows.into_iter().collect();
                let packed = overrides.remove(PACKED);
                if let (true, true, Some(packed)) = (epoch < current, ring.len() < MAX_PAST_EPOCHS, packed) {
                    ring.push_front(PastEpoch::new(epoch, packed, overrides, false));
                } else {
                    self.clear(past_scope(&group_key, epoch));
                }
            }
            if !ring.is_empty() {
                self.held.insert(group_key, ring);
            }
        }
    }

    /// Add what changed in the past stores to `save`: each held store whole (its
    /// packed row and overrides) when `whole`, otherwise a new packed row and the rows
    /// late frames changed.
    pub fn take_into(&self, save: &mut MlsSave, whole: bool) {
        use std::sync::atomic::Ordering;
        save.cleared.append(&mut self.cleared.lock().unwrap_or_else(|e| e.into_inner()));
        for (group_key, ring) in &self.held {
            for past in ring {
                let scope = past_scope(group_key, past.epoch);
                let mut overrides = past.overrides();
                let mut slot = past.open_slot();
                let changed = slot.as_ref().map(|o| o.provider.storage().take_changes()).unwrap_or_default();
                let changed: Vec<(Vec<u8>, Vec<u8>)> = changed.into_iter().map(|(k, v)| (k, v.unwrap_or_default())).collect();
                overrides.extend(changed.iter().cloned());
                // Every change is in `overrides` now, so an idle copy goes without loss.
                if slot.as_ref().is_some_and(|o| o.used.elapsed() >= OPEN_IDLE) {
                    *slot = None;
                }
                let unsaved = past.packed_unsaved.swap(false, Ordering::Relaxed);
                if whole {
                    save.cleared.push(scope.clone());
                }
                if whole || unsaved {
                    save.rows.push((scope.clone(), PACKED.to_vec(), Some(past.packed.clone())));
                }
                let rows: Vec<(Vec<u8>, Vec<u8>)> = if whole || unsaved {
                    overrides.iter().map(|(k, v)| (k.clone(), v.clone())).collect()
                } else {
                    changed
                };
                save.rows.extend(rows.into_iter().map(|(k, v)| (scope.clone(), k, Some(v))));
            }
        }
    }
}
