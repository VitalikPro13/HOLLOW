//! A member's side of the join lock (`join_lock`): the owner makes the first lock,
//! an owner, admin or mod moves it when someone who held a key lost the right to (a
//! member left or lost its rank, or one device of a member identity was removed),
//! every member puts the chain back on a relay that forgot it, the owner compacts
//! it and resets a fork, and whoever holds the change key hands it to every counted
//! device of every owner, admin and mod that lacks it. Every link we make carries
//! our device's proof, so the relay judges it by server authority over our rosters.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::time::{Duration, Instant};

use crate::crdt::operations::{CrdtOp, CrdtPayload, JoinSecret};
use crate::crdt::server_state::ServerState;
use crate::identity::native_identity::NativeKeypair;
use super::join_lock::{self, LockLink, NewLock};
use super::types::{ServerStates, WsCmdTx, WsRoomPeers};
use super::ws_client::WsCommand;

/// How long the relay's chain as we last read it is good enough to build on.
const VIEW_FRESH: Duration = Duration::from_secs(30);
/// How often we read it again anyway: a fork someone else put there shows up.
const VIEW_REFRESH: Duration = Duration::from_secs(600);
/// Between two asks for one server's chain.
const ASK_GAP: Duration = Duration::from_secs(10);
/// An offer the relay has not answered by then is given up on.
const PUT_TIMEOUT: Duration = Duration::from_secs(30);
/// Before the owner resets a lock nobody here can move, or a mod extends the one
/// before it: an op for a lock the relay took reaches us far sooner.
#[cfg(not(test))]
const RESET_GRACE: Duration = Duration::from_secs(60);
#[cfg(test)]
const RESET_GRACE: Duration = Duration::from_secs(5);
/// Each online owner, admin or mod waits its place times this before moving a due
/// lock, so one of them does it rather than all at once.
const STAGGER: Duration = Duration::from_secs(3);
/// Between two grant ops for one server.
const GRANT_GAP: Duration = Duration::from_secs(60);
/// After the relay refused a new lock, and after it refused our chain.
const RETRY_LOCK: Duration = Duration::from_secs(5);
const RETRY_CHAIN: Duration = Duration::from_secs(60);
/// After the relay refused our extension of an older lock: its newest is alive.
#[cfg(not(test))]
const RETRY_FORK: Duration = Duration::from_secs(600);
#[cfg(test)]
const RETRY_FORK: Duration = Duration::from_secs(3);
/// The longest wait between offers the relay keeps not holding: each miss in a row
/// doubles the wait, so a relay that never keeps our lock (a 0.13 relay drops the
/// device proof) hears one offer per this, not one per answer.
const RETRY_MAX: Duration = Duration::from_secs(600);
/// Between two lock moves one identity's device removals cause in one server, so a
/// member linking and removing its own devices cannot churn the lock. A mod's move
/// ahead of removing its own device never waits for it (N12b).
#[cfg(not(test))]
pub(crate) const REMOVAL_GAP: Duration = Duration::from_secs(600);
#[cfg(test)]
pub(crate) const REMOVAL_GAP: Duration = Duration::from_secs(8);
/// Between two owner re-signings of a base the relay holds without a counted proof.
const RESIGN_GAP: Duration = Duration::from_secs(600);
/// Device removals noted in one loop turn before the keeper reads them.
const NOTED_MAX: usize = 4096;

/// The keys a member moves the lock with: the master signs owner bases and stands
/// for the identity, the device proves which device made a link and opens its grants.
#[derive(Clone, Copy)]
pub(crate) struct LockKeys<'a> {
    pub master: &'a NativeKeypair,
    pub device: &'a NativeKeypair,
}

/// A removed device, and the identity it left when the roster path knows it (a
/// recovery drops devices without a removal, so no resolver mark names their identity).
type Noted = (Option<String>, String);

/// Per node loop: our device key for signing outside the keeper, and the device
/// removals the roster paths noted since the last tick.
struct LoopLocal {
    device: NativeKeypair,
    noted: RefCell<Vec<Noted>>,
}

tokio::task_local! {
    static LOOP_LOCAL: LoopLocal;
}

/// Run a node's event loop with its device key and removal notes in scope.
pub(crate) fn with_loop_device<F: std::future::Future>(device: NativeKeypair, loop_: F) -> impl std::future::Future<Output = F::Output> {
    LOOP_LOCAL.scope(LoopLocal { device, noted: RefCell::new(Vec::new()) }, loop_)
}

/// Devices a roster fold just removed: each member identity's servers move their lock.
pub(crate) fn note_removed_devices(devices: &[String]) {
    note(devices.iter().map(|d| (None, d.clone())));
}

/// Devices a recovery of `master` stopped counting (DEVICE_PROOF section 12 item 9):
/// they move the lock as a removal does.
pub(crate) fn note_dropped_devices(master: &str, devices: &[String]) {
    note(devices.iter().map(|d| (Some(master.to_string()), d.clone())));
}

fn note(devices: impl Iterator<Item = Noted>) {
    let _ = LOOP_LOCAL.try_with(|l| {
        let mut noted = l.noted.borrow_mut();
        let room = NOTED_MAX.saturating_sub(noted.len());
        noted.extend(devices.take(room));
    });
}

/// Run `f` with a loop scope of its own and hand back what it noted. Tests only.
#[cfg(test)]
pub(crate) async fn noted_while<F: std::future::Future>(f: F) -> (F::Output, Vec<(Option<String>, String)>) {
    let device = NativeKeypair::from_secret_bytes(&[0xee; 32]);
    LOOP_LOCAL.scope(LoopLocal { device, noted: RefCell::new(Vec::new()) }, async { (f.await, take_noted()) }).await
}

fn take_noted() -> Vec<Noted> {
    LOOP_LOCAL.try_with(|l| std::mem::take(&mut *l.noted.borrow_mut())).unwrap_or_default()
}

fn loop_device() -> Option<NativeKeypair> {
    LOOP_LOCAL.try_with(|l| l.device.clone()).ok()
}

/// What we offered the relay and wait to hear about.
enum Offer {
    /// A new lock: its secrets become the op once the relay takes it.
    Lock(NewLock),
    /// A new lock extending an older one past a dead newest lock (`join_lock::relay_put`).
    Fork(NewLock),
    /// The chain our state holds: nothing to write after.
    Chain,
    /// The owner's signature on the newest lock: written as an op once taken, so
    /// every member republishes the short chain.
    Compact(LockLink),
}

struct InFlight {
    offer: Offer,
    at: Instant,
}

/// Device removals of member identities a server's lock has not moved past yet. A
/// door minted while the device's MLS leaf was still in a group of the server reached
/// it, so only a door newer than the one we held once no group listed its leaf counts.
struct RemovalDue {
    /// Per removed device: that newest door, `None` while a group still lists its leaf.
    devices: BTreeMap<String, Option<u64>>,
    /// The same for every device past `DUE_DEVICES_MAX`, judged by any leaf a due
    /// identity's roster removed; `Some(None)` again on each one noted.
    overflow: Option<Option<u64>>,
    masters: BTreeSet<String>,
    /// No move for them before this (`REMOVAL_GAP` per identity).
    not_before: Instant,
}

/// Removed devices one server's entry names; more fall into its overflow.
const DUE_DEVICES_MAX: usize = 256;

/// Whether a lock moved past `door_n` after the removed leaf was out.
fn door_settled(door_n: &Option<u64>, newest: u64) -> bool {
    door_n.is_some_and(|n| newest > n)
}

impl RemovalDue {
    fn new(now: Instant) -> Self {
        Self { devices: BTreeMap::new(), overflow: None, masters: BTreeSet::new(), not_before: now }
    }

    /// A removed device joins the due, waiting for its leaf to leave again if noted before.
    fn note(&mut self, device: &str) {
        if self.devices.len() < DUE_DEVICES_MAX || self.devices.contains_key(device) {
            self.devices.insert(device.to_string(), None);
        } else {
            self.overflow = Some(None);
        }
    }

    /// Against the newest door we hold and the server's MLS leaves (`removed_leaf` = a leaf
    /// a due identity's roster removed): whether every removal is settled, and whether
    /// one waits on a move now that its leaf is out.
    fn judge(&mut self, newest: u64, listed: &[String], removed_leaf: impl Fn(&str) -> bool) -> (bool, bool) {
        for (device, door_n) in self.devices.iter_mut() {
            if door_n.is_none() && !listed.contains(device) {
                *door_n = Some(newest);
            }
        }
        if self.overflow == Some(None) && !listed.iter().any(|leaf| removed_leaf(leaf)) {
            self.overflow = Some(Some(newest));
        }
        let moved = self.devices.values().chain(self.overflow.as_ref()).all(|n| door_settled(n, newest));
        let ready = self.devices.values().chain(self.overflow.as_ref()).any(|n| n.is_some() && !door_settled(n, newest));
        (moved, ready)
    }
}

#[derive(Default)]
pub(crate) struct LockKeeper {
    /// The relay's chain per server as we last verified it (empty = none), and when.
    views: HashMap<String, (Vec<LockLink>, Instant)>,
    asked: HashMap<String, Instant>,
    in_flight: HashMap<String, InFlight>,
    due_since: HashMap<String, Instant>,
    stuck_since: HashMap<String, Instant>,
    granted_at: HashMap<String, Instant>,
    /// No offer to the relay for a server before this.
    quiet_until: HashMap<String, Instant>,
    removal_due: HashMap<String, RemovalDue>,
    /// (server, identity) -> when a lock move for that identity's device removals landed.
    removal_moved: HashMap<(String, String), Instant>,
    /// Servers where our move ahead of removing a device of ours waits on the relay.
    pre_removal: BTreeSet<String>,
    resigned_at: HashMap<String, Instant>,
    /// Whether this build's fold takes grants filed by device; only a yes is kept.
    fold_takes_devices: bool,
    /// Offers in a row the relay did not end up holding, the relay's newest lock number
    /// at the first of them, and when the last one's wait ends.
    misses: HashMap<String, (u32, u64, Instant)>,
    authorities: Authorities,
}

/// Server authority per identity over its stored roster (`Roster::authority`): who the
/// relay lets write lock links, and so who gets a change key. Read again only once that
/// identity's stored roster changed (`roster_book::revision`), so a busy resolver costs
/// no store reads.
#[derive(Default)]
struct Authorities {
    store: Option<(String, String)>,
    /// master -> (roster revision, last use, counted devices best rank first);
    /// `None` = no roster held.
    held: HashMap<String, (u64, u64, Option<Vec<String>>)>,
    uses: u64,
    /// Store reads so far.
    loads: u64,
}

/// Identities [`Authorities`] keeps at once; past it the least recently used goes.
const AUTHORITIES_HELD: usize = 1024;

impl Authorities {
    fn counted(&mut self, master: &str) -> Option<&[String]> {
        let revision = super::roster_book::revision(master);
        self.uses += 1;
        let uses = self.uses;
        match self.held.get_mut(master) {
            Some((at, used, _)) if *at == revision => *used = uses,
            _ => {
                self.loads += 1;
                let stored = self.store.as_ref().and_then(|(db, pass)| {
                    crate::storage::MessageStore::lease(db, pass).ok()?.load_roster(master).ok().flatten()
                });
                let counted = stored.filter(|r| r.master == master).map(|r| r.reverified().counted_by_rank());
                if self.held.len() >= AUTHORITIES_HELD
                    && !self.held.contains_key(master)
                    && let Some(oldest) = self.held.iter().min_by_key(|(_, (_, used, _))| *used).map(|(m, _)| m.clone())
                {
                    self.held.remove(&oldest);
                }
                self.held.insert(master.to_string(), (revision, uses, counted));
            }
        }
        self.held.get(master).and_then(|(_, _, c)| c.as_deref())
    }

    /// Whether a lock link `device` made for `master` stopped counting: by the stored
    /// roster's authority, else by the resolver's removals.
    fn uncounted(&mut self, master: &str, device: &str) -> bool {
        match self.counted(master) {
            Some(counted) => !counted.iter().any(|d| d == device),
            None => super::resolver::is_revoked_by(master, device),
        }
    }

    /// The devices of `master` a change key is sealed to, at most `GRANT_DEVICES`, best
    /// rank first: those authority counts, else (no roster held) those our resolver
    /// places, the master's own id only when its roster counts it a device (G1), never a
    /// removed device.
    fn grant_devices(&mut self, master: &str) -> Vec<String> {
        if let Some(counted) = self.counted(master) {
            return counted.iter().take(join_lock::GRANT_DEVICES).cloned().collect();
        }
        grant_devices(master)
    }
}

/// The owner id the relay keys a server's chain by.
fn lookup_owner(state: &ServerState) -> Option<String> {
    state.anchor_owner()
}

impl LockKeeper {
    /// Judge devices by the rosters stored here (a keeper without a store judges by the
    /// resolver alone).
    pub(crate) fn read_rosters(&mut self, db_path: &str, db_passphrase: &str) {
        self.authorities.store = Some((db_path.to_string(), db_passphrase.to_string()));
    }

    /// The relay did not end up holding what we offered `server_id`: no offer before a
    /// wait that doubles with each miss in a row, from `base` up to `RETRY_MAX`. A streak
    /// with no miss for `RETRY_MAX` after its wait ended is forgotten.
    fn missed(&mut self, server_id: &str, base: Duration) {
        let now = Instant::now();
        if self.misses.get(server_id).is_some_and(|(_, _, until)| now >= *until + RETRY_MAX) {
            self.misses.remove(server_id);
        }
        let tip_n = self.relay_tip(server_id).map_or(0, |t| t.n);
        let (count, _, until) = self.misses.entry(server_id.to_string()).or_insert((0, tip_n, now));
        let wait = base.saturating_mul(1u32 << (*count).min(16)).min(RETRY_MAX.max(base));
        *count = count.saturating_add(1);
        *until = now + wait;
        self.quiet_until.insert(server_id.to_string(), now + wait);
    }

    /// A new relay connection: it may hold nothing we saw before, so read it afresh.
    pub(crate) fn on_connected(&mut self, server_states: &ServerStates, local_master: &str, ws_cmd_tx: &WsCmdTx) {
        self.views.clear();
        self.in_flight.clear();
        self.asked.clear();
        // Another relay, or this one restarted: what it refused before says nothing now.
        self.misses.clear();
        self.quiet_until.clear();
        let locks: Vec<(String, String)> = server_states
            .iter()
            .filter(|(_, s)| !s.is_deleted() && s.is_member(local_master))
            .filter_map(|(id, s)| Some((id.clone(), lookup_owner(s)?)))
            .collect();
        let now = Instant::now();
        for (id, _) in &locks {
            self.asked.insert(id.clone(), now);
        }
        for chunk in locks.chunks(64) {
            let _ = ws_cmd_tx.send(WsCommand::LockGet { locks: chunk.to_vec() });
        }
    }

    /// A server we just made or joined: read its chain now rather than on the next
    /// connection.
    pub(crate) fn watch(&mut self, server_id: &str, owner: &str, ws_cmd_tx: &WsCmdTx) {
        self.asked.remove(server_id);
        self.ask(ws_cmd_tx, server_id, owner);
    }

    /// The newest lock of the relay's chain for a server, as we last verified it.
    pub(crate) fn relay_tip(&self, server_id: &str) -> Option<&LockLink> {
        self.views.get(server_id).and_then(|(links, _)| links.last())
    }

    /// Someone who held a key was just removed by us: move the lock on the next tick.
    pub(crate) fn nudge(&mut self, server_id: &str) {
        self.due_since.insert(server_id.to_string(), Instant::now().checked_sub(Duration::from_secs(3600)).unwrap_or_else(Instant::now));
    }

    /// Devices a roster fold removed or a recovery dropped: every server of each identity
    /// that lost one moves its lock, so no such device keeps the door or a change key.
    fn note_removals(&mut self, server_states: &ServerStates, devices: &[Noted]) {
        let now = Instant::now();
        for (named, device) in devices {
            let mut masters = super::resolver::revokers_of(device);
            masters.extend(named.iter().filter(|m| !masters.contains(m)).cloned().collect::<Vec<_>>());
            for master in masters {
                for (server_id, state) in server_states {
                    if state.is_deleted() || !state.is_member(&master) {
                        continue;
                    }
                    let gap_ends = self.removal_moved.get(&(server_id.clone(), master.clone())).map(|t| *t + REMOVAL_GAP);
                    let due = self.removal_due.entry(server_id.clone()).or_insert_with(|| RemovalDue::new(now));
                    due.note(device);
                    due.masters.insert(master.clone());
                    if let Some(t) = gap_ends {
                        due.not_before = due.not_before.max(t);
                    }
                }
            }
        }
    }

    /// We are about to remove a device of ours: wherever we hold the newest lock's
    /// change key, the next lock goes to the relay first, ahead of the removal on the
    /// same socket, so the removed device never extends the lock it held. Its door still
    /// reaches the device's leaf; the removal's own due moves the lock again after that.
    pub(crate) fn move_before_removal(&mut self, server_states: &ServerStates, keys: LockKeys, ws_cmd_tx: &WsCmdTx) -> usize {
        let local = keys.master.peer_id();
        let mut moved = 0;
        for (server_id, state) in server_states {
            if state.is_deleted() || !state.is_member(&local) || !state.holds_moderation(&local) || self.in_flight.contains_key(server_id) {
                continue;
            }
            let Some(owner) = lookup_owner(state) else { continue };
            let Some(tip) = self.relay_tip(server_id).cloned() else { continue };
            let Some(held) = state.join_lock.find(&tip) else { continue };
            let Some(change) = open_change(server_id, state, held, keys) else { continue };
            let Some(next) = join_lock::mint_successor(server_id, &tip, &change, &local, keys.device) else { continue };
            hollow_log!("[HOLLOW-CRDT] Moving the join lock of {server_id} to {} before removing a device of ours", next.link.n);
            self.pre_removal.insert(server_id.clone());
            self.put(ws_cmd_tx, server_id, &owner, vec![next.link.clone()], Offer::Lock(next));
            moved += 1;
        }
        moved
    }

    fn ask(&mut self, ws_cmd_tx: &WsCmdTx, server_id: &str, owner: &str) {
        if self.asked.get(server_id).is_some_and(|t| t.elapsed() < ASK_GAP) {
            return;
        }
        self.asked.insert(server_id.to_string(), Instant::now());
        let _ = ws_cmd_tx.send(WsCommand::LockGet { locks: vec![(server_id.to_string(), owner.to_string())] });
    }

    fn put(&mut self, ws_cmd_tx: &WsCmdTx, server_id: &str, owner: &str, links: Vec<LockLink>, offer: Offer) {
        self.in_flight.insert(server_id.to_string(), InFlight { offer, at: Instant::now() });
        let _ = ws_cmd_tx.send(WsCommand::LockPut { server: server_id.to_string(), owner: owner.to_string(), links });
    }

    /// The relay's chain for a server we are a member of. Returns the op to write
    /// when the relay just took a lock of ours.
    pub(crate) fn on_chain(&mut self, server_id: &str, links: Vec<LockLink>, put: Option<bool>, state: &ServerState) -> Option<CrdtPayload> {
        let owner = lookup_owner(state)?;
        if !links.is_empty() && join_lock::verify_chain(server_id, &links, Some(&owner)).is_none() {
            hollow_log!("[HOLLOW-SECURITY] The relay's join lock for {server_id} does not verify back to its owner");
            return None;
        }
        if let Some((master, device)) = links.iter().rev().find(|l| l.is_base()).and_then(|b| join_lock::link_device(server_id, b))
            && self.authorities.uncounted(&master, &device)
        {
            hollow_log!("[HOLLOW-SECURITY] The relay's join lock for {server_id} starts at a base a removed owner device made");
        }
        let tip = links.last().cloned();
        // Someone's newer lock our state holds as the relay does: the relay keeps locks.
        if let Some(t) = tip.as_ref()
            && self.misses.get(server_id).is_some_and(|(_, at_n, _)| t.n > *at_n)
            && state.join_lock.find(t).is_some_and(|held| held == t)
        {
            self.misses.remove(server_id);
        }
        self.views.insert(server_id.to_string(), (links, Instant::now()));
        let flight = self.in_flight.remove(server_id)?;
        let Some(accepted) = put else {
            // An answer to an ask, not to what we offered.
            self.in_flight.insert(server_id.to_string(), flight);
            return None;
        };
        let pre_removal = self.pre_removal.remove(server_id);
        // Our view of the relay was stale. A newest lock a removed device made gives way
        // on the next tick, not after the grace; any other holder's grant is on its way.
        let removed_tip = !accepted
            && pre_removal
            && tip.as_ref().and_then(|t| join_lock::link_device(server_id, t)).is_some_and(|(m, d)| self.authorities.uncounted(&m, &d));
        let wait = match flight.offer {
            Offer::Chain => RETRY_CHAIN,
            Offer::Fork(_) => RETRY_FORK,
            _ => RETRY_LOCK,
        };
        if removed_tip {
            self.stuck_since.insert(server_id.to_string(), Instant::now().checked_sub(RESET_GRACE).unwrap_or_else(Instant::now));
        } else if !accepted {
            self.missed(server_id, wait);
        }
        match flight.offer {
            Offer::Lock(new) | Offer::Fork(new) if accepted && tip.as_ref().is_some_and(|t| t == &new.link) => {
                hollow_log!("[HOLLOW-CRDT] The relay took join lock {} of {server_id}", new.link.n);
                self.misses.remove(server_id);
                self.due_since.remove(server_id);
                self.stuck_since.remove(server_id);
                let by_device = self.fold_takes_device_grants(server_id, state, &new.link);
                Some(lock_op(server_id, &new, state, by_device, &mut self.authorities))
            }
            Offer::Compact(base) if accepted && tip.as_ref() == Some(&base) => {
                self.misses.remove(server_id);
                Some(CrdtPayload::JoinLock { link: base, door: None, grants: BTreeMap::new() })
            }
            Offer::Chain if accepted => None,
            _ => {
                if accepted {
                    // Taken, yet not what we offered: a relay that drops the device proof.
                    hollow_log!("[HOLLOW-CRDT] The relay answered our join lock of {server_id} with another");
                    self.missed(server_id, wait);
                } else {
                    hollow_log!("[HOLLOW-CRDT] The relay kept its own join lock of {server_id} over ours");
                }
                None
            }
        }
    }

    /// One batch tick: what is due for each server we are in. Returns the ops to write.
    pub(crate) fn tick(
        &mut self,
        server_states: &ServerStates,
        keys: LockKeys,
        ws_room_peers: &WsRoomPeers,
        ws_cmd_tx: &WsCmdTx,
        leaves: &dyn Fn(&str) -> Vec<String>,
    ) -> Vec<(String, CrdtPayload)> {
        let noted = take_noted();
        if !noted.is_empty() {
            self.note_removals(server_states, &noted);
        }
        self.removal_moved.retain(|_, t| t.elapsed() < REMOVAL_GAP);
        let local = keys.master.peer_id();
        let unanswered: Vec<String> =
            self.in_flight.iter().filter(|(_, f)| f.at.elapsed() >= PUT_TIMEOUT).map(|(s, _)| s.clone()).collect();
        for server_id in unanswered {
            self.in_flight.remove(&server_id);
            self.missed(&server_id, RETRY_LOCK);
        }
        self.pre_removal.retain(|s| self.in_flight.contains_key(s));
        let mut ops = Vec::new();
        for (server_id, state) in server_states {
            if state.is_deleted() || !state.is_member(&local) {
                continue;
            }
            if let Some(op) = self.tick_server(server_id, state, keys, &local, ws_room_peers, ws_cmd_tx, leaves) {
                ops.push((server_id.clone(), op));
            }
        }
        ops
    }

    /// What is due for one server, right after the relay answered for it.
    pub(crate) fn tick_one(
        &mut self,
        server_id: &str,
        state: &ServerState,
        keys: LockKeys,
        ws_room_peers: &WsRoomPeers,
        ws_cmd_tx: &WsCmdTx,
        leaves: &dyn Fn(&str) -> Vec<String>,
    ) -> Option<CrdtPayload> {
        let local = keys.master.peer_id();
        if state.is_deleted() || !state.is_member(&local) {
            return None;
        }
        self.tick_server(server_id, state, keys, &local, ws_room_peers, ws_cmd_tx, leaves)
    }

    /// Whether a device removal waits on this server's lock now (`leaves` = every MLS
    /// leaf of the server's groups). A lock moved past the door we held once no group
    /// listed the device's leaf, holding no change key for any device a due identity
    /// removed, settles it; none moves while every removed leaf is still listed.
    fn removal_due_now(&mut self, server_id: &str, state: &ServerState, leaves: &dyn Fn(&str) -> Vec<String>) -> bool {
        let Some(due) = self.removal_due.get_mut(server_id) else { return false };
        let newest = state.join_lock.newest_door_id().map_or(0, |(n, _)| n);
        let masters = due.masters.clone();
        let (moved, ready) = due.judge(newest, &leaves(server_id), |leaf| {
            super::resolver::revokers_of(leaf).iter().any(|m| masters.contains(m))
        });
        let clean = state.join_lock.chain().last().is_none_or(|tip| {
            due.masters.iter().all(|m| {
                state.join_lock.grants_for(&tip.change, m).is_empty()
                    && super::resolver::revoked_by(m)
                        .iter()
                        .all(|d| state.join_lock.grants_for(&tip.change, &join_lock::grant_key(m, d)).is_empty())
            })
        });
        if moved && (clean || !self.fold_takes_devices) {
            let now = Instant::now();
            if let Some(due) = self.removal_due.remove(server_id) {
                for master in due.masters {
                    self.removal_moved.entry((server_id.to_string(), master)).or_insert(now);
                }
            }
            return false;
        }
        (ready || moved) && Instant::now() >= due.not_before
    }

    #[allow(clippy::too_many_arguments)]
    fn tick_server(
        &mut self,
        server_id: &str,
        state: &ServerState,
        keys: LockKeys,
        local: &str,
        ws_room_peers: &WsRoomPeers,
        ws_cmd_tx: &WsCmdTx,
        leaves: &dyn Fn(&str) -> Vec<String>,
    ) -> Option<CrdtPayload> {
        let removal_due = self.removal_due_now(server_id, state, leaves);
        if self.in_flight.contains_key(server_id) || self.quiet_until.get(server_id).is_some_and(|t| Instant::now() < *t) {
            return None;
        }
        let owner = lookup_owner(state)?;
        let is_owner = owner == local;
        let nonce = state.founding_nonce();
        let lock = &state.join_lock;
        let Some((view, seen)) = self.views.get(server_id).cloned() else {
            self.ask(ws_cmd_tx, server_id, &owner);
            return None;
        };
        if seen.elapsed() > VIEW_REFRESH {
            self.ask(ws_cmd_tx, server_id, &owner);
        }
        if !lock.has_lock() {
            // The first lock, or a new start past a chain whose keys never reached us.
            if is_owner {
                let n = view.last().map_or(1, |tip| tip.n + 1);
                let first = join_lock::mint_owner_base(server_id, n, keys.master, nonce.as_deref(), keys.device)?;
                hollow_log!("[HOLLOW-CRDT] Making join lock {n} of {server_id}, the first one we hold");
                self.put(ws_cmd_tx, server_id, &owner, vec![first.link.clone()], Offer::Lock(first));
            }
            return None;
        }

        // The relay forgot the chain, or holds an older one: any member puts ours back,
        // the owner as its own device's signature on our newest lock.
        let ours = lock.chain();
        if ours.last().is_some_and(|t| t.n > join_lock::FROZEN_FROM) {
            // Only the fold can let a chain go below it (REQUESTS R2).
            return None;
        }
        let behind = match (view.last(), ours.last()) {
            (None, Some(_)) => true,
            (Some(tip), Some(our_tip)) => our_tip.n > tip.n,
            _ => false,
        };
        if behind {
            let our_tip = ours.last()?.clone();
            if is_owner && let Some(held) = lock.find(&our_tip) && open_change(server_id, state, held, keys).is_some() {
                hollow_log!("[HOLLOW-CRDT] Signing the join lock of {server_id} back onto the relay");
                let base = join_lock::owner_signed(server_id, &our_tip, keys.master, nonce.as_deref(), keys.device);
                self.put(ws_cmd_tx, server_id, &owner, vec![base.clone()], Offer::Compact(base));
            } else {
                hollow_log!("[HOLLOW-CRDT] Putting the join lock of {server_id} back on the relay");
                self.put(ws_cmd_tx, server_id, &owner, ours, Offer::Chain);
            }
            return None;
        }
        let tip = view.last()?.clone();
        let tip_held = lock.find(&tip).is_some();
        let tip_change = tip_held.then(|| open_change(server_id, state, &tip, keys)).flatten();

        if let Some(change) = tip_change.as_ref() {
            let by_device = self.fold_takes_device_grants(server_id, state, &tip);
            if let Some(grants) = self.missing_grants(server_id, state, &tip, change, by_device) {
                return Some(CrdtPayload::JoinLock { link: lock.find(&tip)?.clone(), door: None, grants });
            }
        }

        if (lock.rotation_due() || removal_due) && state.holds_moderation(local) {
            let since = *self.due_since.entry(server_id.to_string()).or_insert_with(Instant::now);
            if since.elapsed() < self.stagger(server_id, state, local, ws_room_peers) {
                return None;
            }
            if seen.elapsed() > VIEW_FRESH {
                self.ask(ws_cmd_tx, server_id, &owner);
                return None;
            }
            if let Some(change) = tip_change.as_ref() {
                let next = join_lock::mint_successor(server_id, &tip, change, local, keys.device)?;
                hollow_log!("[HOLLOW-CRDT] Moving the join lock of {server_id} to {}", next.link.n);
                self.put(ws_cmd_tx, server_id, &owner, vec![next.link.clone()], Offer::Lock(next));
                return None;
            }
        } else {
            self.due_since.remove(server_id);
        }

        if tip_change.is_none() && state.holds_moderation(local) {
            // A newest lock whose change key never reached us is a fork, or one we are
            // about to hear of. Past the grace the owner starts over past it, and an admin
            // or mod extends the newest lock it holds, which the relay takes only once the
            // device that made every later link stopped counting.
            let stuck = *self.stuck_since.entry(server_id.to_string()).or_insert_with(Instant::now);
            if stuck.elapsed() >= RESET_GRACE && seen.elapsed() <= VIEW_FRESH {
                if is_owner {
                    let reset = join_lock::mint_owner_base(server_id, tip.n + 1, keys.master, nonce.as_deref(), keys.device)?;
                    hollow_log!("[HOLLOW-SECURITY] Resetting the join lock of {server_id}: its newest lock is not one we can move");
                    self.put(ws_cmd_tx, server_id, &owner, vec![reset.link.clone()], Offer::Lock(reset));
                } else if let Some(fork) = fork_point(server_id, state, &view, keys) {
                    hollow_log!("[HOLLOW-SECURITY] Extending the join lock of {server_id} at {}: its newest lock is not one we can move", fork.link.n);
                    self.put(ws_cmd_tx, server_id, &owner, vec![fork.link.clone()], Offer::Fork(fork));
                }
            } else if seen.elapsed() > VIEW_FRESH {
                self.ask(ws_cmd_tx, server_id, &owner);
            }
            return None;
        }
        self.stuck_since.remove(server_id);

        if is_owner && tip_change.is_some() {
            let base_unproved = view.first().is_some_and(|b| {
                join_lock::link_device(server_id, b).is_none_or(|(m, d)| self.authorities.uncounted(&m, &d))
            });
            let resign = base_unproved && self.resigned_at.get(server_id).is_none_or(|t| t.elapsed() >= RESIGN_GAP);
            if view.len() > 1 || resign {
                self.resigned_at.insert(server_id.to_string(), Instant::now());
                let base = join_lock::owner_signed(server_id, &tip, keys.master, nonce.as_deref(), keys.device);
                self.put(ws_cmd_tx, server_id, &owner, vec![base.clone()], Offer::Compact(base));
            }
        }
        None
    }

    /// Our place among the owners, admins and mods online in the server's room.
    fn stagger(&self, server_id: &str, state: &ServerState, local: &str, ws_room_peers: &WsRoomPeers) -> Duration {
        let online: Vec<String> = ws_room_peers
            .get(server_id)
            .map(|devices| devices.iter().map(|d| super::resolver::resolve(d)).collect())
            .unwrap_or_default();
        let rank = state
            .moderation_masters()
            .into_iter()
            .filter(|m| m == local || online.contains(m))
            .position(|m| m == local)
            .unwrap_or(0);
        STAGGER * rank as u32
    }

    /// Grants of the newest lock's change key for every counted device of every owner,
    /// admin and mod that has none, at most once a minute per server.
    fn missing_grants(&mut self, server_id: &str, state: &ServerState, tip: &LockLink, change: &[u8; 32], by_device: bool) -> Option<BTreeMap<String, String>> {
        if self.granted_at.get(server_id).is_some_and(|t| t.elapsed() < GRANT_GAP) {
            return None;
        }
        let grants = lock_grants(server_id, state, &tip.change, change, by_device, &mut self.authorities, |key| {
            !state.join_lock.grants_for(&tip.change, key).is_empty()
        });
        if grants.is_empty() {
            return None;
        }
        self.granted_at.insert(server_id.to_string(), Instant::now());
        hollow_log!("[HOLLOW-CRDT] Granting the join lock's change key of {server_id} to {} more", grants.len());
        Some(grants)
    }

    /// Whether the fold takes grants filed by device (`join_lock::grant_key`). Until it
    /// does (REQUESTS R1), a grant filed that way would refuse the whole op, so grants go
    /// to masters the 0.13 way.
    fn fold_takes_device_grants(&mut self, server_id: &str, state: &ServerState, link: &LockLink) -> bool {
        if !self.fold_takes_devices {
            self.fold_takes_devices = device_grant_probe(server_id, state, link);
        }
        self.fold_takes_devices
    }
}

/// The fold's verdict on a grant filed by device for a held link, authored by a holder
/// of moderation: the seam until the fold's own rule names device grants.
fn device_grant_probe(server_id: &str, state: &ServerState, link: &LockLink) -> bool {
    let Some(author) = state.moderation_masters().into_iter().next() else { return false };
    let device = join_lock::grant_key(&author, &author);
    let grant = format!("{}.{}", "A".repeat(44), "A".repeat(64));
    let payload = CrdtPayload::JoinLock { link: link.clone(), door: None, grants: BTreeMap::from([(device, grant)]) };
    let op = serde_json::json!({
        "server_id": server_id,
        "hlc": crate::crdt::hlc::HlcTimestamp { physical_ms: 0, counter: 0, actor: author.clone() },
        "author": author,
        "payload": payload,
    });
    serde_json::from_value::<CrdtOp>(op).is_ok_and(|op| state.op_allowed(&op))
}

/// The devices of `master` our resolver places, for an identity whose roster we do not
/// hold: the master's own id only when its roster counts it a device (G1), never a
/// removed device, at most `GRANT_DEVICES`.
fn grant_devices(master: &str) -> Vec<String> {
    let mut devices: Vec<String> = super::resolver::devices_for(master)
        .into_iter()
        .chain(super::resolver::is_device_of(master, master).then(|| master.to_string()))
        .filter(|d| !super::resolver::is_revoked(d))
        .collect();
    devices.sort();
    devices.truncate(join_lock::GRANT_DEVICES);
    devices
}

/// Grants of one change key the fold takes in one op (`join_lock_allowed`).
const GRANTS_PER_OP: usize = 64;

/// Grants of `change` for every owner, admin and mod not yet `held`: one per counted
/// device, or one per master while the fold refuses device keys. The owner comes first.
fn lock_grants(
    server_id: &str,
    state: &ServerState,
    change: &str,
    secret: &[u8; 32],
    by_device: bool,
    authorities: &mut Authorities,
    held: impl Fn(&str) -> bool,
) -> BTreeMap<String, String> {
    let owner = lookup_owner(state);
    let mut masters = state.moderation_masters();
    masters.sort_by_key(|m| Some(m) != owner.as_ref());
    let mut grants = BTreeMap::new();
    for master in masters {
        let wanted: Vec<(String, Option<String>)> = if by_device {
            authorities.grant_devices(&master).into_iter().map(|d| (join_lock::grant_key(&master, &d), Some(d))).collect()
        } else {
            vec![(master.clone(), None)]
        };
        for (key, device) in wanted {
            if grants.len() >= GRANTS_PER_OP {
                return grants;
            }
            if held(&key) {
                continue;
            }
            let grant = match device {
                Some(d) => join_lock::seal_grant(server_id, change, &master, &d, secret).map(|(_, g)| g),
                None => join_lock::seal_master_grant(server_id, change, &master, secret),
            };
            if let Some(grant) = grant {
                grants.insert(key, grant);
            }
        }
    }
    grants
}

/// Our signature on a ring control (`ring_auth`) for the relay this node dials, when
/// we hold the change key of the newest lock our state has. The relay checks it against
/// the newest lock it holds; the two differ only while a move is on its way.
pub(crate) fn sign_ring_control(
    server_id: &str,
    state: &ServerState,
    master: &NativeKeypair,
    retention_secs: i64,
    clear: bool,
    channels: &[String],
) -> Option<super::ring_auth::RingAuth> {
    let Some(domain) = super::ws_client::relay_domain() else {
        // Outside the event loop's scope the control would leave unsigned, so rings stop
        // being made with no other sign.
        hollow_log!("[HOLLOW-CRDT] Ring control of {server_id} unsigned: no relay domain in this task");
        return None;
    };
    let device = loop_device().unwrap_or_else(|| master.clone());
    let tip = state.join_lock.chain().last()?.clone();
    let change = open_change(server_id, state, &tip, LockKeys { master, device: &device })?;
    super::ring_auth::sign(&domain, server_id, &lookup_owner(state)?, retention_secs, clear, channels, &tip, &change)
}

/// The change key of `link` from a grant sealed to our device, or a 0.13 grant sealed
/// to our master.
fn open_change(server_id: &str, state: &ServerState, link: &LockLink, keys: LockKeys) -> Option<zeroize::Zeroizing<[u8; 32]>> {
    let master = keys.master.peer_id();
    let ours = join_lock::grant_key(&master, &keys.device.peer_id());
    let by_device = state.join_lock.grants_for(&link.change, &ours).iter().find_map(|g| join_lock::open_grant(server_id, &link.change, &ours, keys.device, g));
    by_device.or_else(|| {
        state.join_lock.grants_for(&link.change, &master).iter().find_map(|g| join_lock::open_grant(server_id, &link.change, &master, keys.master, g))
    })
}

/// The next lock after the newest link of the relay's chain, short of its tip, whose
/// change key we hold.
fn fork_point(server_id: &str, state: &ServerState, view: &[LockLink], keys: LockKeys) -> Option<NewLock> {
    let master = keys.master.peer_id();
    view.iter().rev().skip(1).find_map(|link| {
        let held = state.join_lock.find(link)?;
        let change = open_change(server_id, state, held, keys)?;
        join_lock::mint_successor(server_id, link, &change, &master, keys.device)
    })
}

/// Every leaf of a server's MLS groups (its own and each channel subgroup) as we hold
/// them: where a removed device's leaf still reads what the server's group sends.
pub(crate) fn server_leaves(mls: Option<&crate::crypto::MlsManager>, server_id: &str) -> Vec<String> {
    let Some(mls) = mls else { return Vec::new() };
    mls.group_ids()
        .into_iter()
        .filter(|g| crate::crypto::split_group_key(g).0 == server_id)
        .flat_map(|g| mls.group_members(&g))
        .collect()
}

/// Each door a join lock op carried into a server's MLS group, with the group's leaves
/// at the epoch it was sealed under: what the harness checks a removed device against.
#[cfg(test)]
type DoorSend = (String, String, Vec<String>);

#[cfg(test)]
static DOOR_SENDS: std::sync::LazyLock<std::sync::Mutex<Vec<DoorSend>>> = std::sync::LazyLock::new(Default::default);

#[cfg(test)]
pub(crate) fn note_door_send(server_id: &str, payload: &CrdtPayload, leaves: Vec<String>) {
    if let CrdtPayload::JoinLock { link, door: Some(_), .. } = payload {
        DOOR_SENDS.lock().unwrap_or_else(|p| p.into_inner()).push((server_id.to_string(), link.door.clone(), leaves));
    }
}

/// The leaves of every MLS send of `door` in `server_id`.
#[cfg(test)]
pub(crate) fn door_sends(server_id: &str, door: &str) -> Vec<Vec<String>> {
    DOOR_SENDS
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .iter()
        .filter(|(s, d, _)| s == server_id && d == door)
        .map(|(_, _, leaves)| leaves.clone())
        .collect()
}

/// The op for a lock the relay took: its door for every member, its change key for
/// every counted device of every owner, admin and mod.
fn lock_op(server_id: &str, new: &NewLock, state: &ServerState, by_device: bool, authorities: &mut Authorities) -> CrdtPayload {
    CrdtPayload::JoinLock {
        link: new.link.clone(),
        door: Some(JoinSecret(hex::encode(new.door.as_slice()))),
        grants: lock_grants(server_id, state, &new.link.change, &new.change, by_device, authorities, |_| false),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::node::resolver;

    fn id(tag: u8) -> String {
        NativeKeypair::from_secret_bytes(&[tag; 32]).peer_id()
    }

    fn kp(tag: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[tag; 32])
    }

    /// An owner device's move of its server's lock in flight, and the relay's chain
    /// answering it: the owner's base, then a newer link `dev` of `by` made first.
    fn our_move_meets(by: &NativeKeypair, dev: &NativeKeypair) -> (LockKeeper, ServerState, Vec<LockLink>) {
        let (owner, owner_dev) = (kp(70), kp(71));
        let nonce = "00112233445566778899aabbccddeeff";
        let server = crate::crdt::anchor::derive_server_id(&owner.peer_id(), nonce);
        let state = ServerState::new(server.clone(), "S".into(), owner.peer_id());
        let base = join_lock::mint_owner_base(&server, 1, &owner, Some(nonce), &owner_dev).unwrap();
        let newer = join_lock::mint_successor(&server, &base.link, &base.change, &by.peer_id(), dev).unwrap();
        let ours = join_lock::mint_successor(&server, &base.link, &base.change, &owner.peer_id(), &owner_dev).unwrap();
        let mut keeper = LockKeeper::default();
        keeper.in_flight.insert(server, InFlight { offer: Offer::Lock(ours), at: Instant::now() });
        (keeper, state, vec![base.link, newer.link])
    }

    /// The relay refuses our offer over `chain`, with `removed` revoked by `by` meanwhile.
    fn refused(keeper: &mut LockKeeper, state: &ServerState, chain: Vec<LockLink>, by: &NativeKeypair, removed: Option<&NativeKeypair>) {
        let removed: Vec<String> = removed.map(|d| d.peer_id()).into_iter().collect();
        resolver::mark_revoked_by(&by.peer_id(), &removed);
        let op = keeper.on_chain(&state.server_id, chain, Some(false), state);
        resolver::unmark_revoked_by(&by.peer_id(), &removed);
        for d in &removed {
            resolver::forget_for_test(d);
        }
        assert!(op.is_none());
    }

    /// Whether the keeper acts on the relay's newest lock at the next tick (grace
    /// spent, no quiet) rather than waiting first.
    fn acts_at_once(keeper: &LockKeeper, server: &str) -> bool {
        let grace_spent = keeper.stuck_since.get(server).is_some_and(|t| t.elapsed() >= RESET_GRACE);
        let quiet = keeper.quiet_until.get(server).is_some_and(|t| Instant::now() < *t);
        grace_spent && !quiet
    }

    #[test]
    fn a_refused_move_before_a_removal_overrides_only_a_removed_device() {
        let _l = resolver::test_lock();
        let (moderator, mod_dev) = (kp(72), kp(73));

        // An honest mod moved first and its grant is on its way: we wait for it.
        let (mut keeper, state, chain) = our_move_meets(&moderator, &mod_dev);
        let server = state.server_id.clone();
        keeper.pre_removal.insert(server.clone());
        refused(&mut keeper, &state, chain, &moderator, None);
        assert!(!acts_at_once(&keeper, &server), "an honest mod's newer lock is no reason to reset over it");
        assert!(keeper.pre_removal.is_empty());

        // The newest lock is a removed device's: the next tick acts on it.
        let (mut keeper, state, chain) = our_move_meets(&moderator, &mod_dev);
        keeper.pre_removal.insert(server.clone());
        refused(&mut keeper, &state, chain, &moderator, Some(&mod_dev));
        assert!(acts_at_once(&keeper, &server), "a removed device's newest lock gives way at once");

        // Revoked by another identity's roster only: the link's own identity still counts it.
        let (mut keeper, state, chain) = our_move_meets(&moderator, &mod_dev);
        keeper.pre_removal.insert(server.clone());
        refused(&mut keeper, &state, chain, &kp(78), Some(&mod_dev));
        assert!(!acts_at_once(&keeper, &server), "only the link's own identity removes its device");

        // The same refusal of an offer made for no removal waits.
        let (mut keeper, state, chain) = our_move_meets(&moderator, &mod_dev);
        refused(&mut keeper, &state, chain, &moderator, Some(&mod_dev));
        assert!(!acts_at_once(&keeper, &server));
    }

    #[test]
    fn a_timed_out_move_before_a_removal_marks_no_later_refusal() {
        let _l = resolver::test_lock();
        let (moderator, mod_dev) = (kp(74), kp(75));
        let (mut keeper, state, chain) = our_move_meets(&moderator, &mod_dev);
        let server = state.server_id.clone();
        keeper.pre_removal.insert(server.clone());
        let stale = Instant::now().checked_sub(PUT_TIMEOUT + Duration::from_secs(1)).unwrap();
        keeper.in_flight.get_mut(&server).unwrap().at = stale;
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let (master, device) = (kp(76), kp(77));
        let keys = LockKeys { master: &master, device: &device };
        assert!(keeper.tick(&ServerStates::new(), keys, &WsRoomPeers::new(), &tx, &|_| Vec::new()).is_empty());
        assert!(keeper.in_flight.is_empty());

        // A later offer of ours, refused over the removed device's lock, waits its turn.
        keeper.in_flight.insert(server.clone(), InFlight { offer: Offer::Chain, at: Instant::now() });
        refused(&mut keeper, &state, chain, &moderator, Some(&mod_dev));
        assert!(!acts_at_once(&keeper, &server), "a stale mark retags nothing");
    }

    #[test]
    fn a_removal_settles_only_on_a_door_newer_than_its_leaf() {
        let now = Instant::now();
        let mut due = RemovalDue::new(now);
        due.note("d1");
        let none = |_: &str| false;
        assert_eq!(due.judge(5, &["d1".into()], none), (false, false), "no move while a group lists the leaf");
        assert_eq!(due.judge(6, &["d1".into()], none), (false, false), "and a move made meanwhile settles nothing");
        assert_eq!(due.judge(6, &[], none), (false, true), "the leaf is out: a move is due");
        assert_eq!(due.judge(7, &[], none), (true, false), "a door after that settles it");

        // Per device: a device noted later is not settled by a move before its leaf left.
        due.note("d2");
        assert_eq!(due.judge(7, &["d2".into()], none), (false, false));
        assert_eq!(due.judge(8, &["d2".into()], none), (false, false), "d1's move is no move for d2");
        assert_eq!(due.judge(8, &[], none), (false, true));
        assert_eq!(due.judge(9, &[], none), (true, false));

        // Noted again after it settled (a second removal by another identity): wait anew.
        due.note("d1");
        assert_eq!(due.judge(9, &["d1".into()], none), (false, false));
    }

    #[test]
    fn devices_past_the_cap_still_hold_the_due_open() {
        let mut due = RemovalDue::new(Instant::now());
        for i in 0..DUE_DEVICES_MAX {
            due.note(&format!("d{i}"));
        }
        due.note("late");
        assert_eq!(due.devices.len(), DUE_DEVICES_MAX);
        let removed = |leaf: &str| leaf == "late";
        assert_eq!(due.judge(3, &["late".into()], removed), (false, true), "the named leaves are out");
        assert_eq!(due.judge(4, &["late".into()], removed), (false, false), "an unnamed removed leaf still listed is not settled");
        assert_eq!(due.judge(4, &[], removed), (false, true));
        assert_eq!(due.judge(5, &[], removed), (true, false));
        due.note("later");
        assert_eq!(due.judge(5, &[], removed), (false, true), "another one past the cap waits for a newer door");
    }

    #[test]
    fn grants_skip_a_removed_device_a_stale_link_still_names() {
        let _l = resolver::test_lock();
        let (master, kept, gone) = (id(41), id(42), id(43));
        resolver::update(&kept, &master);
        resolver::mark_revoked_by(&master, std::slice::from_ref(&gone));
        resolver::update(&gone, &master);
        let devices = grant_devices(&master);
        resolver::unmark_revoked_by(&master, std::slice::from_ref(&gone));
        for d in [&kept, &gone] {
            resolver::forget_for_test(d);
        }
        assert_eq!(devices, vec![kept]);
    }

    #[test]
    fn grants_reach_at_most_eight_devices_and_the_master_only_as_a_device() {
        let _l = resolver::test_lock();
        let master = id(50);
        let devices: Vec<String> = (51..61).map(id).collect();
        for d in &devices {
            resolver::update(d, &master);
        }
        let capped = grant_devices(&master);
        for d in &devices {
            resolver::forget_for_test(d);
        }
        assert_eq!(capped.len(), join_lock::GRANT_DEVICES);

        let (other, device) = (id(62), id(63));
        resolver::update(&device, &other);
        let bare = grant_devices(&other);
        resolver::update(&other, &other);
        let counted = grant_devices(&other);
        for d in [&device, &other] {
            resolver::forget_for_test(d);
        }
        assert_eq!(bare, vec![device.clone()], "the bare master is no device");
        assert!(counted.contains(&other) && counted.contains(&device), "a master its roster counts is one");
    }

    /// An owner's first lock in flight on a fresh server, and the relay's answers to it.
    fn first_lock_in_flight() -> (LockKeeper, ServerState, NewLock) {
        let (owner, owner_dev) = (kp(80), kp(81));
        let nonce = "00112233445566778899aabbccddeef0";
        let server = crate::crdt::anchor::derive_server_id(&owner.peer_id(), nonce);
        let state = ServerState::new(server.clone(), "S".into(), owner.peer_id());
        let first = join_lock::mint_owner_base(&server, 1, &owner, Some(nonce), &owner_dev).unwrap();
        (LockKeeper::default(), state, first)
    }

    /// How long the keeper keeps quiet about `server` from now.
    fn quiet_for(keeper: &LockKeeper, server: &str) -> Duration {
        keeper.quiet_until.get(server).map_or(Duration::ZERO, |t| t.saturating_duration_since(Instant::now()))
    }

    fn copy(new: &NewLock) -> NewLock {
        NewLock { link: new.link.clone(), door: zeroize::Zeroizing::new(*new.door), change: zeroize::Zeroizing::new(*new.change) }
    }

    fn offer(keeper: &mut LockKeeper, server: &str, new: &NewLock) {
        keeper.in_flight.insert(server.to_string(), InFlight { offer: Offer::Lock(copy(new)), at: Instant::now() });
    }

    #[test]
    fn a_relay_that_drops_the_device_proof_hears_fewer_and_fewer_offers() {
        let (mut keeper, state, first) = first_lock_in_flight();
        let server = state.server_id.clone();
        // A 0.13 relay takes the lock and answers it without the proof it cannot read.
        let mut stripped = first.link.clone();
        stripped.dev = None;
        let mut waits = Vec::new();
        for _ in 0..10 {
            offer(&mut keeper, &server, &first);
            assert!(keeper.on_chain(&server, vec![stripped.clone()], Some(true), &state).is_none());
            waits.push(quiet_for(&keeper, &server));
        }
        assert!(waits[0] + Duration::from_secs(1) >= RETRY_LOCK, "a lock the relay holds otherwise is a miss: {waits:?}");
        assert!(waits.windows(2).all(|w| w[1] + Duration::from_millis(50) >= w[0]), "the wait never shrinks: {waits:?}");
        assert!(waits[2] + Duration::from_secs(1) >= RETRY_LOCK * 4, "it doubles: {waits:?}");
        assert!(waits[9] <= RETRY_MAX && waits[9] + Duration::from_secs(1) >= RETRY_MAX, "up to its bound: {waits:?}");

        // The relay keeps our lock: the next miss starts over.
        offer(&mut keeper, &server, &first);
        assert!(keeper.on_chain(&server, vec![first.link.clone()], Some(true), &state).is_some(), "the lock op");
        offer(&mut keeper, &server, &first);
        keeper.on_chain(&server, vec![stripped], Some(true), &state);
        assert!(quiet_for(&keeper, &server) <= RETRY_LOCK, "a held lock resets the wait");
    }

    #[test]
    fn a_relay_that_refuses_or_never_answers_hears_fewer_and_fewer_offers() {
        let (mut keeper, state, first) = first_lock_in_flight();
        let server = state.server_id.clone();
        offer(&mut keeper, &server, &first);
        keeper.on_chain(&server, Vec::new(), Some(false), &state);
        let once = quiet_for(&keeper, &server);
        offer(&mut keeper, &server, &first);
        keeper.on_chain(&server, Vec::new(), Some(false), &state);
        assert!(quiet_for(&keeper, &server) >= once + RETRY_LOCK / 2, "a refusal in a row waits longer");

        // An offer nobody answers is a miss too.
        let (mut keeper, state, first) = first_lock_in_flight();
        offer(&mut keeper, &server, &first);
        keeper.in_flight.get_mut(&server).unwrap().at = Instant::now().checked_sub(PUT_TIMEOUT + Duration::from_secs(1)).unwrap();
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let (master, device) = (kp(82), kp(83));
        keeper.tick(&ServerStates::new(), LockKeys { master: &master, device: &device }, &WsRoomPeers::new(), &tx, &|_| Vec::new());
        assert!(quiet_for(&keeper, &server) + Duration::from_secs(1) >= RETRY_LOCK, "an unanswered offer waits");
        drop(state);
    }

    #[test]
    fn a_new_relay_connection_forgets_the_misses() {
        let (mut keeper, state, first) = first_lock_in_flight();
        let server = state.server_id.clone();
        for _ in 0..4 {
            offer(&mut keeper, &server, &first);
            keeper.on_chain(&server, Vec::new(), Some(false), &state);
        }
        assert!(quiet_for(&keeper, &server) > RETRY_LOCK, "setup: a streak");
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        keeper.on_connected(&ServerStates::new(), &kp(84).peer_id(), &tx);
        assert_eq!(quiet_for(&keeper, &server), Duration::ZERO, "no wait left over");
        offer(&mut keeper, &server, &first);
        keeper.on_chain(&server, Vec::new(), Some(false), &state);
        assert!(quiet_for(&keeper, &server) <= RETRY_LOCK, "the next miss starts over");
    }

    #[test]
    fn a_miss_streak_quiet_for_its_bound_is_forgotten() {
        let (mut keeper, state, first) = first_lock_in_flight();
        let server = state.server_id.clone();
        for _ in 0..6 {
            offer(&mut keeper, &server, &first);
            keeper.on_chain(&server, Vec::new(), Some(false), &state);
        }
        let streak = quiet_for(&keeper, &server);
        assert!(streak > RETRY_LOCK * 8, "setup: a long streak {streak:?}");
        // Its wait ended, and no offer missed for RETRY_MAX after that.
        let past = Instant::now().checked_sub(RETRY_MAX + Duration::from_secs(1)).unwrap();
        keeper.misses.get_mut(&server).unwrap().2 = past;
        offer(&mut keeper, &server, &first);
        keeper.on_chain(&server, Vec::new(), Some(false), &state);
        assert!(quiet_for(&keeper, &server) <= RETRY_LOCK, "the streak decayed: {:?}", quiet_for(&keeper, &server));

        // A streak whose last wait only just ended keeps doubling.
        let (mut keeper, state, first) = first_lock_in_flight();
        for _ in 0..6 {
            offer(&mut keeper, &server, &first);
            keeper.on_chain(&server, Vec::new(), Some(false), &state);
        }
        keeper.misses.get_mut(&server).unwrap().2 = Instant::now();
        offer(&mut keeper, &server, &first);
        keeper.on_chain(&server, Vec::new(), Some(false), &state);
        assert!(quiet_for(&keeper, &server) > streak, "no decay inside the bound");
    }

    /// A store holding `roster` for its master, the way a contact's roster is kept.
    fn store_with(roster: &crate::identity::roster::Roster) -> (crate::test_tmp::TestDir, String, String) {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("keeper.db").to_str().unwrap().to_string();
        let pass = "ab".repeat(32);
        let store = crate::storage::MessageStore::open(&db, &pass).unwrap();
        store.save_device_list(&roster.master, &serde_json::to_string(roster).unwrap(), 0, &[], 0).unwrap();
        (tmp, db, pass)
    }

    #[test]
    fn grants_follow_server_authority_after_a_mutual_removal() {
        use crate::identity::roster;
        let _l = resolver::test_lock();
        let master = kp(90);
        let (a, b) = (kp(91), kp(92));
        let (first, second) = if a.peer_id() < b.peer_id() { (&a, &b) } else { (&b, &a) };
        let m = master.peer_id();
        let mut r = roster::Roster::legacy_for_test(&master, &[first, second]);
        r.add_removal(roster::sign_removal(second, &m, roster::LEGACY_BASE, &first.peer_id(), &[]));
        r.add_removal(roster::sign_removal(first, &m, roster::LEGACY_BASE, &second.peer_id(), &[]));
        assert!(r.fold(|_| None, 0).members.is_empty(), "setup: the fold removes both");
        let (_tmp, db, pass) = store_with(&r);
        // The resolver follows the fold: both devices removed.
        resolver::mark_revoked_by(&m, &[first.peer_id(), second.peer_id()]);
        let mut auth = Authorities { store: Some((db, pass)), ..Default::default() };
        let devices = auth.grant_devices(&m);
        let first_out = auth.uncounted(&m, &first.peer_id());
        let second_out = auth.uncounted(&m, &second.peer_id());
        let resolver_view = grant_devices(&m);
        resolver::unmark_revoked_by(&m, &[first.peer_id(), second.peer_id()]);
        for d in [first.peer_id(), second.peer_id()] {
            resolver::forget_for_test(&d);
        }
        assert_eq!(devices, vec![first.peer_id()], "the device the walk keeps gets the change key");
        assert!(!first_out && second_out, "and only its links still count");
        assert!(resolver_view.is_empty(), "control: the fold's view grants nobody");
    }

    /// A keypair per index past the `u8` tags.
    fn wide_kp(i: u16) -> NativeKeypair {
        let mut seed = [0x5au8; 32];
        seed[..2].copy_from_slice(&i.to_be_bytes());
        NativeKeypair::from_secret_bytes(&seed)
    }

    /// R2 review (2): 300 identities' rosters past the old cap of 256, read again after
    /// the resolver moved (it moves on every ingest): the second pass reads no store.
    #[test]
    fn review_probe_authorities_past_the_cap() {
        use crate::identity::roster;
        let _l = resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("keeper.db").to_str().unwrap().to_string();
        let pass = "ab".repeat(32);
        let store = crate::storage::MessageStore::open(&db, &pass).unwrap();
        let masters: Vec<String> = (0..300u16)
            .map(|i| {
                let (master, device) = (wide_kp(i), wide_kp(1000 + i));
                let r = roster::Roster::legacy_for_test(&master, &[&device]);
                store.save_device_list(&r.master, &serde_json::to_string(&r).unwrap(), 0, &[], 0).unwrap();
                r.master
            })
            .collect();
        let mut auth = Authorities { store: Some((db, pass)), ..Default::default() };
        for m in &masters {
            assert!(auth.counted(m).is_some_and(|c| c.len() == 1), "setup: each roster counts its device");
        }
        let stranger = wide_kp(2000).peer_id();
        resolver::update_many(&wide_kp(2001).peer_id(), [stranger.as_str()]);
        for m in &masters {
            auth.counted(m);
        }
        resolver::forget_for_test(&stranger);
        assert_eq!(auth.loads, 300, "the second pass reads the cache");
    }

    #[test]
    fn authorities_past_the_cap_let_only_the_least_recently_used_go() {
        let mut auth = Authorities::default();
        for i in 0..AUTHORITIES_HELD {
            auth.counted(&format!("m{i}"));
        }
        auth.counted("m0");
        auth.counted("one more");
        assert_eq!(auth.held.len(), AUTHORITIES_HELD);
        assert!(auth.held.contains_key("m0") && auth.held.contains_key("one more"), "a recent one stays");
        assert!(!auth.held.contains_key("m1"), "the least recently used goes");
        assert_eq!(auth.loads, AUTHORITIES_HELD as u64 + 1, "and nothing else was read again");
    }

    #[test]
    fn authorities_read_a_roster_again_once_it_is_saved() {
        use crate::identity::roster;
        let _l = resolver::test_lock();
        let (master, a, b) = (kp(95), kp(96), kp(97));
        let (_tmp, db, pass) = store_with(&roster::Roster::legacy_for_test(&master, &[&a]));
        let mut auth = Authorities { store: Some((db.clone(), pass.clone())), ..Default::default() };
        let m = master.peer_id();
        assert_eq!(auth.counted(&m).map(<[String]>::to_vec), Some(vec![a.peer_id()]));
        let store = crate::storage::MessageStore::open(&db, &pass).unwrap();
        super::super::roster_book::merge_for_test(&store, &roster::Roster::legacy_for_test(&master, &[&a, &b]), &kp(98).peer_id(), &kp(99).peer_id());
        let after = auth.counted(&m).map(<[String]>::to_vec).unwrap_or_default();
        for d in [a.peer_id(), b.peer_id()] {
            resolver::forget_for_test(&d);
        }
        assert!(after.contains(&b.peer_id()), "the saved roster is read again: {after:?}");
        assert_eq!(auth.loads, 2);
    }

    #[test]
    fn grants_go_to_the_devices_closest_to_the_phrase() {
        use crate::identity::roster;
        let master = kp(93);
        let m = master.peer_id();
        let root = kp(94);
        let mut r = roster::Roster::legacy_for_test(&master, &[&root]);
        // A counted device vouches a chain, then many devices hang off its far end.
        let mut voucher = root.clone();
        let mut chain = Vec::new();
        for tag in 100..103u8 {
            let d = kp(tag);
            r.add_consent(roster::sign_consent(&d, &m));
            r.add_vouch(roster::sign_vouch(&voucher, &m, roster::LEGACY_BASE, &d.peer_id()));
            chain.push(d.peer_id());
            voucher = d;
        }
        for tag in 110..122u8 {
            let d = kp(tag);
            r.add_consent(roster::sign_consent(&d, &m));
            r.add_vouch(roster::sign_vouch(&voucher, &m, roster::LEGACY_BASE, &d.peer_id()));
        }
        let (_tmp, db, pass) = store_with(&r);
        let mut auth = Authorities { store: Some((db, pass)), ..Default::default() };
        let devices = auth.grant_devices(&m);
        assert_eq!(devices.len(), join_lock::GRANT_DEVICES);
        assert_eq!(devices[0], root.peer_id(), "the root first");
        assert_eq!(&devices[1..4], chain.as_slice(), "then by depth");
    }
}
