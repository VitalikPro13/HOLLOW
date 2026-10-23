//! Self-update turns (AR-25, design `g13-s3`): every leaf refreshes itself with a
//! path-only commit on a cadence, but only when the group's committer hands it a
//! turn, and the committer broadcasts that commit itself. One broadcaster per group,
//! so a member's refresh never races the authority's own commit.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use base64::Engine;
use tokio::sync::mpsc;

use super::types::{HavenMessage, NetworkEvent};
use super::ws_client::WsCommand;
use crate::crypto::mls_tally::{self, capped, LeafRecord, MasterTally, Tally, CAP_COMMITS, CAP_EPOCHS};
use crate::crypto::{CryptoStore, LeafView, MlsManager, Verdict};
use crate::hollow_log;

type Peers = HashMap<String, HashSet<String>>;
type ServerStates = HashMap<String, crate::crdt::server_state::ServerState>;

/// How long a handed-out turn keeps the committer from committing in that group.
pub(crate) const LEASE: Duration = Duration::from_secs(10);

/// Past its lease, how much longer our own staged self-update may still be relayed.
const LEASE_SLACK: Duration = Duration::from_secs(5);

/// A turn older than this when our batch tick reaches it is declined.
const TURN_MAX_AGE: Duration = Duration::from_secs(4);


/// Cadence multiplier in thousandths; 0 = unset (1.0, or the debug-build override).
static SCALE_MILLI: AtomicU64 = AtomicU64::new(0);

fn scale() -> f64 {
    match SCALE_MILLI.load(Ordering::Relaxed) {
        0 => debug_scale(),
        m => m as f64 / 1000.0,
    }
}

#[cfg(debug_assertions)]
fn debug_scale() -> f64 {
    static FROM_ENV: std::sync::OnceLock<f64> = std::sync::OnceLock::new();
    *FROM_ENV.get_or_init(|| {
        std::env::var("HOLLOW_MLS_CADENCE_SCALE").ok().and_then(|v| v.parse::<f64>().ok()).filter(|v| *v > 0.0).unwrap_or(1.0)
    })
}

#[cfg(not(debug_assertions))]
fn debug_scale() -> f64 {
    1.0
}

#[cfg(test)]
pub(crate) fn set_cadence_scale_for_test(scale: f64) {
    SCALE_MILLI.store((scale * 1000.0).max(1.0) as u64, Ordering::Relaxed);
}

#[cfg(test)]
pub(crate) fn reset_cadence_scale_for_test() {
    SCALE_MILLI.store(0, Ordering::Relaxed);
}

/// Self-update commits a group of `leaves` takes per day: 48 up to 512 leaves, then
/// fewer, since every member processes every commit at a cost linear in the group.
pub(crate) fn self_updates_per_day(leaves: usize) -> u64 {
    (24_576 / leaves.max(1) as u64).clamp(4, 48)
}

/// Least time between two turns in one group.
pub(crate) fn turn_spacing(leaves: usize) -> Duration {
    Duration::from_secs_f64(86_400.0 / self_updates_per_day(leaves) as f64 * scale())
}

/// How often each leaf is refreshed: at most daily, slower as the group grows.
pub(crate) fn leaf_period(leaves: usize) -> Duration {
    Duration::from_secs_f64(86_400.0 * scale()).max(turn_spacing(leaves) * leaves.max(1) as u32)
}


/// Counted commits of a tally still inside the cap's window at `epoch`.
fn recent(tally: &MasterTally, epoch: u64) -> usize {
    match tally {
        MasterTally::Unreadable => CAP_COMMITS,
        MasterTally::List(list) => list.iter().filter(|e| e.saturating_add(CAP_EPOCHS) > epoch).count(),
    }
}

/// The leaf whose turn it is: among `candidate` leaves due for a refresh, a capable
/// one before a pre-0.13 one, the stalest first, then by device id. A turn never
/// takes a non-owner master closer to its cap than one counted commit short.
pub(crate) fn pick_turn(
    leaves: &[LeafRecord],
    epoch: u64,
    today: u32,
    period: Duration,
    candidate: impl Fn(&LeafRecord) -> bool,
    is_owner: impl Fn(&str) -> bool,
) -> Option<&LeafRecord> {
    leaves
        .iter()
        .filter(|l| l.identity.is_some() && candidate(l))
        .filter(|l| {
            let age = (u64::from(today.saturating_sub(l.fresh_day)) + 1).saturating_mul(86_400);
            age >= period.as_secs()
        })
        .filter(|l| {
            let master = l.master().unwrap_or_default();
            is_owner(master) || recent(&mls_tally::master_tally(leaves, master, epoch), epoch) <= 1
        })
        .min_by(|a, b| {
            let key = |l: &LeafRecord| (!l.capable(), l.fresh_day, l.identity.as_ref().map(|i| i.device.clone()));
            key(a).cmp(&key(b))
        })
}

/// The tally our next self-update states: exactly what the receiver rule expects of
/// a path-only commit at `epoch`.
fn next_own_tally(mls: &MlsManager, group_key: &str, master: &str, local_device: &str, epoch: u64) -> Option<Tally> {
    let records = mls.leaf_records(group_key);
    let me = crate::crypto::LeafIdentity { device: local_device.to_string(), master: master.to_string() };
    let input = crate::crypto::mls_rate::RateInput { epoch, leaves: &records, committer: &me, adds: &[], removes: &[], no_proposals: true };
    let charges = crate::crypto::mls_rate::charges(&input);
    crate::crypto::mls_rate::expected_tally(&input, &charges, mls_tally::today()).ok()
}

struct Lease {
    device: String,
    epoch: u64,
    nonce: u64,
    until: Instant,
}

struct Stashed {
    from: String,
    epoch: u64,
    nonce: u64,
    at: Instant,
}

/// Turn state, committer and member side. RAM only.
#[derive(Default)]
pub(crate) struct TurnBook {
    leases: HashMap<String, Lease>,
    last_turn: HashMap<String, Instant>,
    /// `(group, device)` that was handed a turn, or refreshed by one, and when.
    granted: HashMap<(String, String), Instant>,
    /// `(group, device)` that declined or let a turn lapse, and when.
    skipped: HashMap<(String, String), Instant>,
    /// Per group, the identity that was its committer at the last tick.
    last_committer: HashMap<String, String>,
    /// Per group, no commit of ours before this: we just took over from a committer
    /// that may still relay a turn it handed out.
    hold_until: HashMap<String, Instant>,
    stashed: HashMap<String, Stashed>,
    /// Per group, when our own staged self-update was handed over.
    pending_since: HashMap<String, Instant>,
    started: Option<Instant>,
}

impl TurnBook {
    /// Ends the turn a commit answers, when it is the open lease's own (holder, epoch,
    /// nonce) and the lease has not run out: a commit relayed past it could share its
    /// epoch with the holder's next own commit.
    fn close_turn(&mut self, group_key: &str, from: &str, epoch: u64, nonce: u64, now: Instant) -> bool {
        let open = self
            .leases
            .get(group_key)
            .is_some_and(|l| l.device == from && l.nonce == nonce && l.epoch == epoch && l.until > now);
        if open {
            self.leases.remove(group_key);
        }
        open
    }

    /// Any session change: a turn handed to the old session is not ours to act on.
    pub(crate) fn on_session(&mut self) {
        self.stashed.clear();
    }

    /// Whether our own commit in `group_key` must wait this tick: a turn of ours is
    /// out, we just took over, or our own self-update may still be relayed. A
    /// self-update past that window is dropped so we can commit.
    pub(crate) fn blocks_commit(&mut self, mls: &mut MlsManager, group_key: &str) -> bool {
        let now = Instant::now();
        if self.leases.get(group_key).is_some_and(|l| l.until > now) || self.hold_until.get(group_key).is_some_and(|t| *t > now) {
            return true;
        }
        if mls.groups_with_pending_commit().iter().any(|g| g == group_key) {
            let since = self.pending_since.get(group_key).copied().or(self.started).unwrap_or(now);
            if since.elapsed() < LEASE + LEASE_SLACK {
                return true;
            }
            mls.clear_pending_commit(group_key);
            self.pending_since.remove(group_key);
            hollow_log!("[HOLLOW-MLS] Dropped our unrelayed self-update for {group_key}: we must commit");
        }
        false
    }
}

/// The identity that commits for the group as we see it.
fn committer_identity(state: &crate::crdt::server_state::ServerState, mls: &MlsManager, group_key: &str, local_master: &str, peers: &Peers) -> Option<String> {
    let (_, channel) = crate::crypto::split_group_key(group_key);
    let unfit = super::crypto_handler::unfit_committers(mls, state, group_key);
    let members = mls.group_members(group_key);
    let rule = super::standing::rule(mls, state, group_key);
    let elected = match channel {
        Some(cid) => super::crypto_handler::elect_subgroup_coordinator(state, &cid, local_master, peers, &rule),
        None => super::crypto_handler::elect_server_coordinator(state, &members, local_master, peers, &rule),
    };
    // A subgroup we hold falls back among its own leaves.
    super::crypto_handler::fit_coordinator(elected, &members, local_master, peers, &unfit, state, &rule)
        .filter(|c| rule.may_lead() || c != local_master)
}

/// The device of `identity` that commits for it in the group: its lowest online,
/// unrevoked device holding a bound leaf there.
fn committing_device(mls: &MlsManager, group_key: &str, identity: &str, peers: &Peers) -> Option<String> {
    mls.group_leaves(group_key)
        .iter()
        .filter_map(LeafView::bound)
        .filter(|l| super::resolver::same_identity(&l.master, identity))
        .filter(|l| !super::resolver::is_revoked(&l.device) && peers.values().any(|p| p.contains(&l.device)))
        .map(|l| l.device.clone())
        .min()
}

fn we_commit(mls: &MlsManager, state: &crate::crdt::server_state::ServerState, group_key: &str, local_master: &str, local_device: &str, peers: &Peers) -> bool {
    committer_identity(state, mls, group_key, local_master, peers).is_some_and(|c| super::resolver::same_identity(&c, local_master))
        && super::crypto_handler::we_commit_for_our_identity(mls, group_key, local_master, local_device, peers, &[])
}


fn random_nonce() -> u64 {
    let mut b = [0u8; 8];
    let _ = getrandom::fill(&mut b);
    u64::from_le_bytes(b)
}

fn wire_ids(group_key: &str) -> (String, Option<String>) {
    crate::crypto::split_group_key(group_key)
}

fn decline(ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>, peers: &Peers, to: &str, group_key: &str, epoch: u64, nonce: u64) {
    let (server_id, channel_id) = wire_ids(group_key);
    super::crypto_handler::send_message_to_peer(ws_cmd_tx, peers, to, HavenMessage::MlsUpdateTurnDeclined { server_id, channel_id, epoch, nonce });
}

/// A turn handed to us (member side): kept for our next batch tick only if it comes
/// from the device our own election names as the group's committer.
#[allow(clippy::too_many_arguments)]
pub(crate) fn handle_turn(
    book: &mut TurnBook,
    mls: &MlsManager,
    server_states: &ServerStates,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    peers: &Peers,
    local_master: &str,
    local_device: &str,
    from: &str,
    group_key: &str,
    epoch: u64,
    nonce: u64,
) {
    let (server_id, _) = wire_ids(group_key);
    // Our own identity commits through its lowest online device; a sibling of ours
    // holding that role hands us turns like anyone else's committer.
    let expected = server_states
        .get(&server_id)
        .and_then(|state| committer_identity(state, mls, group_key, local_master, peers))
        .filter(|c| {
            !super::resolver::same_identity(c, local_master)
                || !super::crypto_handler::we_commit_for_our_identity(mls, group_key, local_master, local_device, peers, &[])
        })
        .and_then(|c| committing_device(mls, group_key, &c, peers))
        .filter(|d| d != local_device);
    if expected.as_deref() != Some(from) || !mls.has_group(group_key) {
        hollow_log!("[HOLLOW-MLS] Declined a self-update turn for {group_key} from {from}: not the committer we see ({expected:?})");
        decline(ws_cmd_tx, peers, from, group_key, epoch, nonce);
        return;
    }
    book.stashed.insert(group_key.to_string(), Stashed { from: from.to_string(), epoch, nonce, at: Instant::now() });
}

/// The turn holder's staged commit reaching us (committer side): judged, then
/// broadcast, then merged, only for the open turn it answers.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_turn_commit(
    book: &mut TurnBook,
    mls: &mut MlsManager,
    crypto_store: &CryptoStore,
    server_states: &ServerStates,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    peers: &Peers,
    event_tx: &mpsc::Sender<NetworkEvent>,
    mls_bootstrap_requested: &mut HashMap<String, Instant>,
    local_master: &str,
    local_device: &str,
    live: bool,
    from: &str,
    group_key: &str,
    epoch: u64,
    nonce: u64,
    commit_b64: &str,
) {
    let (server_id, channel_id) = wire_ids(group_key);
    if !book.close_turn(group_key, from, epoch, nonce, Instant::now()) {
        hollow_log!("[HOLLOW-MLS] Dropped a self-update for {group_key} from {from}: no open turn of ours matches");
        return;
    }
    let Some(state) = server_states.get(&server_id) else { return };
    if !live
        || mls.epoch(group_key).ok() != Some(epoch)
        || mls.holds_commit(group_key)
        || !we_commit(mls, state, group_key, local_master, local_device, peers)
    {
        hollow_log!("[HOLLOW-MLS] Dropped a self-update for {group_key} from {from}: we no longer commit at epoch {epoch}");
        return;
    }
    let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(commit_b64) else { return };
    let host = mls.pinned_committer(group_key).map(str::to_string);
    let relay = ws_cmd_tx.clone();
    let frame = commit_b64.to_string();
    let wire_channel = channel_id.clone();
    let wire_server = server_id.clone();
    let judged = mls.process_commit_judged_then(
        group_key,
        &bytes,
        |facts| {
            let pure_self_update = facts.committer.as_ref().and_then(LeafView::bound).is_some_and(|c| c.device == from)
                && facts.adds.is_empty()
                && facts.removes.is_empty()
                && facts.path_leaf.is_some();
            if !pure_self_update {
                return Verdict::Refuse("a turn commit is a self-update of the turn holder's own leaf".into());
            }
            match super::mls_authority::judge_commit(server_states, &server_id, channel_id.as_deref(), host.as_deref(), facts) {
                Verdict::Hold(why) => Verdict::Refuse(why),
                v => v,
            }
        },
        // Out before it merges here: a committer that dies between the two must not sit
        // alone at the new epoch.
        || super::crypto_handler::send_commit_frame(&relay, &wire_server, wire_channel, frame, Some(epoch + 1)),
    );
    match judged {
        Ok(Verdict::Accept) => {
            mls.cache_commit(group_key, epoch + 1, commit_b64.to_string());
            book.granted.insert((group_key.to_string(), from.to_string()), Instant::now());
            hollow_log!("[HOLLOW-MLS] Relayed {from}'s self-update for {group_key} (epoch {epoch} -> {})", epoch + 1);
            super::crypto_handler::after_commit_merged(
                mls, crypto_store, server_states, mls_bootstrap_requested, event_tx, local_master, &server_id, group_key, &channel_id,
            )
            .await;
        }
        Ok(v) => {
            super::crypto_handler::persist_mls_state(mls, crypto_store);
            book.skipped.insert((group_key.to_string(), from.to_string()), Instant::now());
            hollow_log!("[HOLLOW-SECURITY] Did not relay {from}'s self-update for {group_key}: {v:?}");
        }
        Err(e) => {
            book.skipped.insert((group_key.to_string(), from.to_string()), Instant::now());
            hollow_log!("[HOLLOW-MLS] Could not process {from}'s self-update for {group_key}: {e:?}");
        }
    }
}

/// The turn holder declines (committer side): the turn ends now.
pub(crate) fn handle_turn_declined(book: &mut TurnBook, from: &str, group_key: &str, epoch: u64, nonce: u64) {
    if book.leases.get(group_key).is_some_and(|l| l.device == from && l.nonce == nonce && l.epoch == epoch) {
        book.leases.remove(group_key);
        book.skipped.insert((group_key.to_string(), from.to_string()), Instant::now());
    }
}

/// Once per batch tick, after phase 2: act on a turn handed to us, then, where we
/// commit for a group and committed nothing this tick, hand out the next turn (or
/// refresh our own leaf when it is the stalest).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn tick(
    book: &mut TurnBook,
    mls: &mut MlsManager,
    crypto_store: &CryptoStore,
    server_states: &ServerStates,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    peers: &Peers,
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_master: &str,
    local_device: &str,
    our_turn: bool,
    committed: &HashSet<String>,
) {
    let now = Instant::now();
    let started = *book.started.get_or_insert(now);
    let pending: HashSet<String> = mls.groups_with_pending_commit().into_iter().collect();
    book.pending_since.retain(|g, _| pending.contains(g));
    for g in &pending {
        book.pending_since.entry(g.clone()).or_insert(started);
    }

    let stashed: Vec<(String, Stashed)> = book.stashed.drain().collect();
    for (group_key, turn) in stashed {
        act_on_turn(book, mls, crypto_store, server_states, ws_cmd_tx, peers, local_master, local_device, our_turn, &group_key, turn);
    }

    for group_key in mls.group_ids() {
        let (server_id, _) = wire_ids(&group_key);
        if super::conference::is_conference_sid(&server_id) {
            continue;
        }
        let Some(state) = server_states.get(&server_id) else { continue };
        if state.is_deleted() {
            continue;
        }
        let Ok(epoch) = mls.epoch(&group_key) else { continue };
        if book.leases.get(&group_key).is_some_and(|l| l.until <= now || epoch > l.epoch)
            && let Some(lapsed) = book.leases.remove(&group_key)
            && epoch == lapsed.epoch
        {
            book.skipped.insert((group_key.clone(), lapsed.device), now);
        }

        let committer = committer_identity(state, mls, &group_key, local_master, peers);
        let previous = match &committer {
            Some(c) => book.last_committer.insert(group_key.clone(), c.clone()),
            None => book.last_committer.remove(&group_key),
        };
        let ours = committer.as_deref().is_some_and(|c| super::resolver::same_identity(c, local_master));
        if ours
            && previous.as_deref().is_some_and(|p| {
                !super::resolver::same_identity(p, local_master) && super::crypto_handler::peer_is_reachable(peers, p)
            })
        {
            book.hold_until.insert(group_key.clone(), now + LEASE);
        }
        if !ours
            || !our_turn
            || committed.contains(&group_key)
            || book.leases.contains_key(&group_key)
            || book.hold_until.get(&group_key).is_some_and(|t| *t > now)
            || pending.contains(&group_key)
            || mls.holds_commit(&group_key)
            || !super::crypto_handler::we_commit_for_our_identity(mls, &group_key, local_master, local_device, peers, &[])
        {
            continue;
        }
        let records = mls.leaf_records(&group_key);
        let leaves = records.len();
        let last = *book.last_turn.entry(group_key.clone()).or_insert(started);
        if last.elapsed() < turn_spacing(leaves) {
            continue;
        }
        let period = leaf_period(leaves);
        let quarter = period / 4;
        let pick = pick_turn(
            &records,
            epoch,
            mls_tally::today(),
            period,
            |l| {
                let device = l.identity.as_ref().map(|i| i.device.as_str()).unwrap_or_default();
                let key = (group_key.clone(), device.to_string());
                (device == local_device || super::crypto_handler::peer_is_reachable(peers, device))
                    && !super::resolver::is_revoked(device)
                    && book.granted.get(&key).is_none_or(|t| t.elapsed() >= period)
                    && book.skipped.get(&key).is_none_or(|t| t.elapsed() >= quarter)
            },
            |m| super::crypto_handler::is_anchor_owner(state, m),
        )
        .and_then(|l| l.identity.clone());
        let Some(pick) = pick else { continue };
        book.last_turn.insert(group_key.clone(), now);
        book.granted.insert((group_key.clone(), pick.device.clone()), now);
        if pick.device == local_device {
            refresh_own_leaf(mls, crypto_store, ws_cmd_tx, event_tx, local_master, local_device, &group_key, epoch).await;
            continue;
        }
        let nonce = random_nonce();
        let (server_id, channel_id) = wire_ids(&group_key);
        super::crypto_handler::send_message_to_peer(
            ws_cmd_tx,
            peers,
            &pick.device,
            HavenMessage::MlsUpdateTurn { server_id, channel_id, epoch, nonce },
        );
        book.leases.insert(group_key.clone(), Lease { device: pick.device.clone(), epoch, nonce, until: now + LEASE });
        hollow_log!("[HOLLOW-MLS] Handed {} a self-update turn in {group_key} at epoch {epoch}", pick.device);
    }
}

/// Per local device, the KeyPackages it already passed on or was passed, by digest:
/// each is forwarded at most once there, so two members whose elections disagree
/// hand it back at most once.
type Forwarded = std::collections::BTreeMap<String, std::collections::VecDeque<[u8; 16]>>;
static FORWARDED: std::sync::Mutex<Forwarded> = std::sync::Mutex::new(std::collections::BTreeMap::new());

fn first_forward(local_device: &str, key_package_b64: &str) -> bool {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(key_package_b64.as_bytes());
    let mut tag = [0u8; 16];
    tag.copy_from_slice(&digest[..16]);
    let Ok(mut all) = FORWARDED.lock() else { return false };
    if !all.contains_key(local_device) && all.len() >= 64 {
        all.clear();
    }
    let seen = all.entry(local_device.to_string()).or_default();
    if seen.contains(&tag) {
        return false;
    }
    seen.push_back(tag);
    while seen.len() > 256 {
        seen.pop_front();
    }
    true
}

/// Pass a KeyPackage we will not commit on to `coordinator`'s devices, once. True when
/// it is on its way (now or by an earlier forward).
pub(crate) fn forward_key_package(
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    peers: &Peers,
    local_device: &str,
    coordinator: &str,
    server_id: &str,
    channel_id: Option<String>,
    key_package_b64: &str,
) -> bool {
    if !first_forward(local_device, key_package_b64) {
        return true;
    }
    super::crypto_handler::send_key_package_to_identity_of(
        ws_cmd_tx,
        peers,
        coordinator,
        &HavenMessage::MlsKeyPackageForward { server_id: server_id.to_string(), key_package: key_package_b64.to_string(), channel_id },
    );
    hollow_log!("[HOLLOW-MLS] Passed a KeyPackage for {server_id} on to the committer {coordinator}");
    true
}

/// A forwarded KeyPackage as the KeyPackage its own device would have sent: the
/// forwarder must be a member's device, the package bound to a device of a member.
/// `None` drops the frame.
pub(crate) fn unwrap_forwarded_key_package(
    msg: &HavenMessage,
    forwarder: &str,
    local_device: &str,
    server_states: &ServerStates,
) -> Option<(HavenMessage, String)> {
    let HavenMessage::MlsKeyPackageForward { server_id, key_package, channel_id } = msg else { return None };
    let state = server_states.get(server_id)?;
    if super::resolver::is_bare_master(forwarder)
        || !state.members.keys().any(|m| super::resolver::same_identity(m, forwarder))
    {
        hollow_log!("[HOLLOW-SECURITY] Dropped a forwarded KeyPackage for {server_id} from {forwarder}: not a member's device");
        return None;
    }
    let bytes = base64::engine::general_purpose::STANDARD.decode(key_package).ok()?;
    let device = MlsManager::key_package_identity(&bytes).ok()?.bound()?.device.clone();
    let _ = first_forward(local_device, key_package);
    Some((HavenMessage::MlsKeyPackage { server_id: server_id.clone(), key_package: key_package.clone(), channel_id: channel_id.clone() }, device))
}

/// Whether a frame belongs to the turn exchange, handled by [`dispatch`].
pub(crate) fn is_turn_frame(msg: &HavenMessage) -> bool {
    matches!(msg, HavenMessage::MlsUpdateTurn { .. } | HavenMessage::MlsUpdateTurnCommit { .. } | HavenMessage::MlsUpdateTurnDeclined { .. })
}

fn group_key_of(server_id: &str, channel_id: &Option<String>) -> String {
    match channel_id {
        Some(cid) => crate::crypto::subgroup_id(server_id, cid),
        None => server_id.to_string(),
    }
}

/// One turn frame from device `from`.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn dispatch(
    book: &mut TurnBook,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    server_states: &ServerStates,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    peers: &Peers,
    event_tx: &mpsc::Sender<NetworkEvent>,
    mls_bootstrap_requested: &mut HashMap<String, Instant>,
    local_master: &str,
    local_device: &str,
    live: bool,
    from: &str,
    msg: &HavenMessage,
) {
    let Some(mls) = mls.as_mut() else { return };
    match msg {
        HavenMessage::MlsUpdateTurn { server_id, channel_id, epoch, nonce } => {
            let group_key = group_key_of(server_id, channel_id);
            handle_turn(book, mls, server_states, ws_cmd_tx, peers, local_master, local_device, from, &group_key, *epoch, *nonce);
        }
        HavenMessage::MlsUpdateTurnCommit { server_id, channel_id, epoch, nonce, commit } => {
            let group_key = group_key_of(server_id, channel_id);
            handle_turn_commit(
                book, mls, crypto_store, server_states, ws_cmd_tx, peers, event_tx, mls_bootstrap_requested,
                local_master, local_device, live, from, &group_key, *epoch, *nonce, commit,
            )
            .await;
        }
        HavenMessage::MlsUpdateTurnDeclined { server_id, channel_id, epoch, nonce } => {
            handle_turn_declined(book, from, &group_key_of(server_id, channel_id), *epoch, *nonce);
        }
        _ => {}
    }
}

/// The committer refreshing its own leaf: staged, broadcast, then merged.
#[allow(clippy::too_many_arguments)]
async fn refresh_own_leaf(
    mls: &mut MlsManager,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_master: &str,
    local_device: &str,
    group_key: &str,
    epoch: u64,
) {
    let Some(tally) = next_own_tally(mls, group_key, local_master, local_device, epoch) else { return };
    let commit = match mls.stage_self_update(group_key, &tally) {
        Ok(c) => c,
        Err(e) => {
            hollow_log!("[HOLLOW-MLS] Could not refresh our leaf in {group_key}: {e}");
            return;
        }
    };
    let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&commit);
    let (server_id, channel_id) = wire_ids(group_key);
    super::crypto_handler::send_commit_frame(ws_cmd_tx, &server_id, channel_id.clone(), commit_b64.clone(), Some(epoch + 1));
    if let Err(e) = mls.merge_own_self_update(group_key) {
        hollow_log!("[HOLLOW-MLS] Could not merge our own self-update in {group_key}: {e}");
        return;
    }
    mls.cache_commit(group_key, epoch + 1, commit_b64);
    super::crypto_handler::persist_mls_state(mls, crypto_store);
    hollow_log!("[HOLLOW-MLS] Refreshed our own leaf in {group_key} (epoch {epoch} -> {})", epoch + 1);
    if let Ok(sframe_key) = mls.export_secret(group_key, "sframe", b"", 32) {
        let _ = event_tx.send(NetworkEvent::MlsEpochChanged { server_id, epoch: epoch + 1, sframe_key, channel_id }).await;
    }
}

/// TEST-ONLY: a self-update committed on our own, outside every rule.
#[cfg(test)]
#[allow(clippy::too_many_arguments)]
pub(crate) async fn debug_commit_self_update(
    mls: &mut MlsManager,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_master: &str,
    local_device: &str,
    group_key: &str,
    epochs: Option<Vec<u64>>,
) {
    let Ok(epoch) = mls.epoch(group_key) else { return };
    let Some(mut tally) = next_own_tally(mls, group_key, local_master, local_device, epoch).or_else(|| {
        Some(Tally { refreshed_day: mls_tally::today(), epochs: vec![epoch], carried: vec![] })
    }) else {
        return;
    };
    if let Some(epochs) = epochs {
        tally.epochs = epochs;
    }
    let Ok(commit) = mls.stage_self_update(group_key, &tally) else { return };
    let commit_b64 = base64::engine::general_purpose::STANDARD.encode(&commit);
    let (server_id, channel_id) = wire_ids(group_key);
    super::crypto_handler::send_commit_frame(ws_cmd_tx, &server_id, channel_id.clone(), commit_b64.clone(), Some(epoch + 1));
    if mls.merge_own_self_update(group_key).is_ok() {
        mls.cache_commit(group_key, epoch + 1, commit_b64);
        super::crypto_handler::persist_mls_state(mls, crypto_store);
        if let Ok(sframe_key) = mls.export_secret(group_key, "sframe", b"", 32) {
            let _ = event_tx.send(NetworkEvent::MlsEpochChanged { server_id, epoch: epoch + 1, sframe_key, channel_id }).await;
        }
    }
}

/// Member side: commit for a turn we were handed, or decline it.
#[allow(clippy::too_many_arguments)]
fn act_on_turn(
    book: &mut TurnBook,
    mls: &mut MlsManager,
    crypto_store: &CryptoStore,
    server_states: &ServerStates,
    ws_cmd_tx: &mpsc::UnboundedSender<WsCommand>,
    peers: &Peers,
    local_master: &str,
    local_device: &str,
    our_turn: bool,
    group_key: &str,
    turn: Stashed,
) {
    let (server_id, _) = wire_ids(group_key);
    let state = server_states.get(&server_id);
    let tally = next_own_tally(mls, group_key, local_master, local_device, turn.epoch);
    let at_cap = tally.is_none()
        || state.is_some_and(|s| {
            !super::crypto_handler::is_anchor_owner(s, local_master)
                && capped(&mls_tally::master_tally(&mls.leaf_records(group_key), local_master, turn.epoch), turn.epoch)
        });
    let ready = our_turn
        && turn.at.elapsed() < TURN_MAX_AGE
        && !at_cap
        && mls.epoch(group_key).ok() == Some(turn.epoch)
        && !mls.holds_commit(group_key)
        && !book.pending_since.contains_key(group_key);
    let staged = match (ready, tally) {
        (true, Some(tally)) => mls.stage_self_update(group_key, &tally).ok(),
        _ => None,
    };
    let Some(commit) = staged else {
        decline(ws_cmd_tx, peers, &turn.from, group_key, turn.epoch, turn.nonce);
        return;
    };
    // Staging spent a handshake-ratchet key: saved before the frame leaves.
    super::crypto_handler::persist_mls_state(mls, crypto_store);
    let (server_id, channel_id) = wire_ids(group_key);
    super::crypto_handler::send_message_to_peer(
        ws_cmd_tx,
        peers,
        &turn.from,
        HavenMessage::MlsUpdateTurnCommit {
            server_id,
            channel_id,
            epoch: turn.epoch,
            nonce: turn.nonce,
            commit: base64::engine::general_purpose::STANDARD.encode(&commit),
        },
    );
    book.pending_since.insert(group_key.to_string(), Instant::now());
    hollow_log!("[HOLLOW-MLS] Sent our self-update for {group_key} at epoch {} to its committer {}", turn.epoch, turn.from);
}

/// KeyPackage-driven leaf changes (adds or repairs of a master's devices) an honest
/// committer makes freely per master ...
const FREE_LEAF_CHANGES: usize = 3;
/// ... in this long; then one per backoff, doubling from a minute to half an hour,
/// reset after half an hour without one. A member that keeps sending KeyPackages
/// would otherwise re-key the whole group through us every tick (AR-27).
const FREE_WINDOW: Duration = Duration::from_secs(600);
const BACKOFF_START: Duration = Duration::from_secs(60);
const BACKOFF_MAX: Duration = Duration::from_secs(1800);
const QUIET_RESET: Duration = Duration::from_secs(1800);

struct Spend {
    recent: std::collections::VecDeque<Instant>,
    strikes: u32,
    last: Instant,
}

/// Per `(group, master)`, the leaf changes we committed at that master's request.
#[derive(Default)]
pub(crate) struct RepairBudget {
    spent: HashMap<(String, String), Spend>,
}

impl RepairBudget {
    /// Whether we may commit a change to `master`'s leaves in `group_key` now.
    pub(crate) fn may(&self, group_key: &str, master: &str, now: Instant) -> bool {
        let Some(s) = self.spent.get(&(group_key.to_string(), master.to_string())) else { return true };
        if now.duration_since(s.last) >= QUIET_RESET {
            return true;
        }
        if s.recent.iter().filter(|t| now.duration_since(**t) < FREE_WINDOW).count() < FREE_LEAF_CHANGES {
            return true;
        }
        now.duration_since(s.last) >= Self::backoff(s.strikes)
    }

    fn backoff(strikes: u32) -> Duration {
        BACKOFF_START.saturating_mul(1u32 << strikes.min(5)).min(BACKOFF_MAX)
    }

    /// One committed change to `master`'s leaves.
    pub(crate) fn spend(&mut self, group_key: &str, master: &str, now: Instant) {
        let s = self.spent.entry((group_key.to_string(), master.to_string())).or_insert_with(|| Spend {
            recent: Default::default(),
            strikes: 0,
            last: now,
        });
        if now.duration_since(s.last) >= QUIET_RESET {
            s.recent.clear();
            s.strikes = 0;
        }
        s.recent.retain(|t| now.duration_since(*t) < FREE_WINDOW);
        if s.recent.len() >= FREE_LEAF_CHANGES {
            s.strikes += 1;
        }
        s.recent.push_back(now);
        s.last = now;
    }

    /// Drop what no longer limits anything.
    pub(crate) fn prune(&mut self, now: Instant) {
        self.spent.retain(|_, s| now.duration_since(s.last) < QUIET_RESET);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::LeafIdentity;

    fn leaf(index: u32, device: &str, master: &str, fresh_day: u32, epochs: Vec<u64>, commit_written: bool) -> LeafRecord {
        LeafRecord {
            index,
            identity: Some(LeafIdentity { device: device.into(), master: master.into() }),
            declares: true,
            tally: Some(Tally { refreshed_day: fresh_day, epochs, carried: vec![] }),
            commit_written,
            fresh_day,
        }
    }

    #[test]
    fn the_cadence_slows_with_the_group_and_never_exceeds_48_a_day() {
        reset_cadence_scale_for_test();
        assert_eq!(self_updates_per_day(10), 48);
        assert_eq!(self_updates_per_day(512), 48);
        assert_eq!(self_updates_per_day(2048), 12);
        assert_eq!(self_updates_per_day(100_000), 4);
        assert_eq!(turn_spacing(512), Duration::from_secs(1800));
        assert_eq!(leaf_period(10), Duration::from_secs(86_400));
        assert_eq!(leaf_period(512), Duration::from_secs(1800 * 512));
    }

    #[test]
    fn three_counted_commits_inside_twelve_epochs_cap_a_master() {
        assert!(!capped(&MasterTally::List(vec![]), 5));
        assert!(!capped(&MasterTally::List(vec![9, 8]), 10));
        assert!(capped(&MasterTally::List(vec![9, 8, 7]), 10));
        assert!(capped(&MasterTally::List(vec![9, 8, 7]), 18), "the oldest is 11 epochs back");
        assert!(!capped(&MasterTally::List(vec![9, 8, 7]), 19), "the oldest is 12 epochs back");
        assert!(capped(&MasterTally::Unreadable, 100));
    }

    #[test]
    fn the_stalest_capable_leaf_gets_the_turn_and_a_master_near_its_cap_waits() {
        let leaves = vec![
            leaf(0, "d0", "a", 100, vec![], true),
            leaf(1, "d1", "b", 90, vec![], true),
            leaf(2, "d2", "c", 80, vec![40, 39], true),
            {
                let mut old = leaf(3, "d3", "e", 10, vec![], false);
                old.tally = None;
                old.declares = false;
                old
            },
        ];
        let pick = |cand: &dyn Fn(&LeafRecord) -> bool, owner: &str| {
            pick_turn(&leaves, 41, 101, Duration::from_secs(86_400), cand, |m| m == owner).map(|l| l.identity.clone().unwrap().device)
        };
        assert_eq!(pick(&|_| true, "x"), Some("d1".into()), "c has two counted commits in its window, e is pre-0.13");
        assert_eq!(pick(&|_| true, "c"), Some("d2".into()), "the owner needs no headroom");
        assert_eq!(pick(&|l| l.index != 1, "x"), Some("d0".into()));
        assert_eq!(pick(&|l| l.index == 3, "x"), Some("d3".into()), "a pre-0.13 leaf when nothing else is due");
        assert_eq!(
            pick_turn(&leaves, 41, 101, Duration::from_secs(86_400 * 30), |_| true, |_| false).map(|l| l.index),
            Some(3),
            "only the leaf a month stale is due on a 30 day period",
        );
    }

    #[test]
    fn a_turn_commit_counts_only_for_its_own_lease_before_it_runs_out() {
        let t0 = Instant::now();
        let mut book = TurnBook::default();
        let open = |book: &mut TurnBook| {
            book.leases.insert("g".into(), Lease { device: "d".into(), epoch: 5, nonce: 9, until: t0 + LEASE });
        };
        open(&mut book);
        assert!(!book.close_turn("g", "x", 5, 9, t0), "another device");
        assert!(!book.close_turn("g", "d", 6, 9, t0), "another epoch");
        assert!(!book.close_turn("g", "d", 5, 8, t0), "another nonce");
        assert!(!book.close_turn("g", "d", 5, 9, t0 + LEASE), "the lease ran out");
        assert!(book.close_turn("g", "d", 5, 9, t0 + LEASE - Duration::from_millis(1)));
        assert!(!book.close_turn("g", "d", 5, 9, t0), "once");
    }

    #[test]
    fn a_master_sending_key_packages_in_a_loop_gets_three_then_a_doubling_wait() {
        let mut b = RepairBudget::default();
        let t0 = Instant::now();
        let at = |s: u64| t0 + Duration::from_secs(s);
        for s in 0..3 {
            assert!(b.may("g", "m", at(s)));
            b.spend("g", "m", at(s));
        }
        assert!(!b.may("g", "m", at(3)), "a fourth within ten minutes waits");
        assert!(b.may("g", "other", at(3)), "per master");
        assert!(b.may("h", "m", at(3)), "per group");
        assert!(b.may("g", "m", at(2 + 60)), "a minute after the last");
        b.spend("g", "m", at(62));
        assert!(!b.may("g", "m", at(62 + 60)), "then two minutes");
        assert!(b.may("g", "m", at(62 + 120)));
        b.spend("g", "m", at(182));
        assert!(!b.may("g", "m", at(182 + 120)), "then four");
        assert!(b.may("g", "m", at(182 + 240)));
        assert!(b.may("g", "m", at(182 + 1800)), "half an hour quiet resets it");
        b.spend("g", "m", at(182 + 1800));
        assert!(b.may("g", "m", at(182 + 1801)), "a fresh budget after the reset");
    }
}
