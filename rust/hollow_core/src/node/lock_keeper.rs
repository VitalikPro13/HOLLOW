//! A member's side of the join lock (`join_lock`): the owner makes the first lock,
//! an owner, admin or mod moves it when someone who held a key lost the right to,
//! every member puts the chain back on a relay that forgot it, the owner compacts
//! it and resets a fork, and whoever holds the change key hands it to every owner,
//! admin and mod that lacks it.

use std::collections::{BTreeMap, HashMap};
use std::time::{Duration, Instant};

use crate::crdt::operations::{CrdtPayload, JoinSecret};
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
/// Before the owner resets a lock nobody here can move: an op for a lock the relay
/// took reaches us far sooner.
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

/// What we offered the relay and wait to hear about.
enum Offer {
    /// A new lock: its secrets become the op once the relay takes it.
    Lock(NewLock),
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
}

/// The owner id the relay keys a server's chain by.
fn lookup_owner(state: &ServerState) -> Option<String> {
    state.anchor_owner()
}

impl LockKeeper {
    /// A new relay connection: it may hold nothing we saw before, so read it afresh.
    pub(crate) fn on_connected(&mut self, server_states: &ServerStates, local_master: &str, ws_cmd_tx: &WsCmdTx) {
        self.views.clear();
        self.in_flight.clear();
        self.asked.clear();
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

    /// Someone who held a key was just removed by us: move the lock on the next tick.
    pub(crate) fn nudge(&mut self, server_id: &str) {
        self.due_since.insert(server_id.to_string(), Instant::now().checked_sub(Duration::from_secs(3600)).unwrap_or_else(Instant::now));
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
        let tip = links.last().cloned();
        self.views.insert(server_id.to_string(), (links, Instant::now()));
        let flight = self.in_flight.remove(server_id)?;
        let Some(accepted) = put else {
            // An answer to an ask, not to what we offered.
            self.in_flight.insert(server_id.to_string(), flight);
            return None;
        };
        if !accepted {
            let wait = if matches!(flight.offer, Offer::Chain) { RETRY_CHAIN } else { RETRY_LOCK };
            self.quiet_until.insert(server_id.to_string(), Instant::now() + wait);
        }
        match flight.offer {
            Offer::Lock(new) if accepted && tip.as_ref().is_some_and(|t| t == &new.link) => {
                hollow_log!("[HOLLOW-CRDT] The relay took join lock {} of {server_id}", new.link.n);
                self.due_since.remove(server_id);
                self.stuck_since.remove(server_id);
                Some(lock_op(server_id, &new, state))
            }
            Offer::Compact(base) if accepted && tip.as_ref() == Some(&base) => {
                Some(CrdtPayload::JoinLock { link: base, door: None, grants: BTreeMap::new() })
            }
            _ => {
                if !accepted {
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
        master: &NativeKeypair,
        ws_room_peers: &WsRoomPeers,
        ws_cmd_tx: &WsCmdTx,
    ) -> Vec<(String, CrdtPayload)> {
        let local = master.peer_id();
        self.in_flight.retain(|_, f| f.at.elapsed() < PUT_TIMEOUT);
        let mut ops = Vec::new();
        for (server_id, state) in server_states {
            if state.is_deleted() || !state.is_member(&local) {
                continue;
            }
            if let Some(op) = self.tick_server(server_id, state, master, &local, ws_room_peers, ws_cmd_tx) {
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
        master: &NativeKeypair,
        ws_room_peers: &WsRoomPeers,
        ws_cmd_tx: &WsCmdTx,
    ) -> Option<CrdtPayload> {
        let local = master.peer_id();
        if state.is_deleted() || !state.is_member(&local) {
            return None;
        }
        self.tick_server(server_id, state, master, &local, ws_room_peers, ws_cmd_tx)
    }

    fn tick_server(
        &mut self,
        server_id: &str,
        state: &ServerState,
        master: &NativeKeypair,
        local: &str,
        ws_room_peers: &WsRoomPeers,
        ws_cmd_tx: &WsCmdTx,
    ) -> Option<CrdtPayload> {
        if self.in_flight.contains_key(server_id) || self.quiet_until.get(server_id).is_some_and(|t| Instant::now() < *t) {
            return None;
        }
        let owner = lookup_owner(state)?;
        let is_owner = owner == local;
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
                let first = join_lock::mint_base(server_id, n, master, state.founding_nonce().as_deref())?;
                hollow_log!("[HOLLOW-CRDT] Making join lock {n} of {server_id}, the first one we hold");
                self.put(ws_cmd_tx, server_id, &owner, vec![first.link.clone()], Offer::Lock(first));
            }
            return None;
        }

        // The relay forgot the chain, or holds an older one: any member puts ours back.
        let ours = lock.chain();
        let behind = match (view.last(), ours.last()) {
            (None, Some(_)) => true,
            (Some(tip), Some(our_tip)) => our_tip.n > tip.n,
            _ => false,
        };
        if behind {
            hollow_log!("[HOLLOW-CRDT] Putting the join lock of {server_id} back on the relay");
            self.put(ws_cmd_tx, server_id, &owner, ours, Offer::Chain);
            return None;
        }
        let tip = view.last()?.clone();
        let tip_held = lock.find(&tip).is_some();
        let tip_change = tip_held.then(|| open_change(server_id, state, &tip, master)).flatten();

        if let Some(grants) = tip_change.as_ref().and_then(|change| self.missing_grants(server_id, state, &tip, change)) {
            return Some(CrdtPayload::JoinLock { link: lock.find(&tip)?.clone(), door: None, grants });
        }

        if lock.rotation_due() && state.holds_moderation(local) {
            let since = *self.due_since.entry(server_id.to_string()).or_insert_with(Instant::now);
            if since.elapsed() < self.stagger(server_id, state, local, ws_room_peers) {
                return None;
            }
            if seen.elapsed() > VIEW_FRESH {
                self.ask(ws_cmd_tx, server_id, &owner);
                return None;
            }
            if let Some(change) = tip_change.as_ref() {
                let next = join_lock::mint_next(server_id, &tip, change)?;
                hollow_log!("[HOLLOW-CRDT] Moving the join lock of {server_id} to {}", next.link.n);
                self.put(ws_cmd_tx, server_id, &owner, vec![next.link.clone()], Offer::Lock(next));
                return None;
            }
        } else {
            self.due_since.remove(server_id);
        }

        if is_owner {
            // A newest lock whose change key never reached us is a fork, or one we
            // are about to hear of: past the grace, the owner starts over past it.
            if tip_change.is_none() {
                let stuck = *self.stuck_since.entry(server_id.to_string()).or_insert_with(Instant::now);
                if stuck.elapsed() >= RESET_GRACE && seen.elapsed() <= VIEW_FRESH {
                    let reset = join_lock::mint_base(server_id, tip.n + 1, master, state.founding_nonce().as_deref())?;
                    hollow_log!("[HOLLOW-SECURITY] Resetting the join lock of {server_id}: its newest lock is not one we can move");
                    self.put(ws_cmd_tx, server_id, &owner, vec![reset.link.clone()], Offer::Lock(reset));
                } else if seen.elapsed() > VIEW_FRESH {
                    self.ask(ws_cmd_tx, server_id, &owner);
                }
                return None;
            }
            self.stuck_since.remove(server_id);
            if view.len() > 1 {
                let base = join_lock::owner_signed(server_id, &tip, master, state.founding_nonce().as_deref());
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

    /// Grants of the newest lock's change key for every owner, admin and mod that
    /// has none, at most once a minute per server.
    fn missing_grants(&mut self, server_id: &str, state: &ServerState, tip: &LockLink, change: &[u8; 32]) -> Option<BTreeMap<String, String>> {
        if self.granted_at.get(server_id).is_some_and(|t| t.elapsed() < GRANT_GAP) {
            return None;
        }
        let grants: BTreeMap<String, String> = state
            .moderation_masters()
            .into_iter()
            .filter(|m| state.join_lock.grants_for(&tip.change, m).is_empty())
            .filter_map(|m| Some((m.clone(), join_lock::seal_grant(server_id, &tip.change, &m, change)?)))
            .collect();
        if grants.is_empty() {
            return None;
        }
        self.granted_at.insert(server_id.to_string(), Instant::now());
        hollow_log!("[HOLLOW-CRDT] Granting the join lock's change key of {server_id} to {} more", grants.len());
        Some(grants)
    }
}

/// The change key of `link` from a grant sealed to us.
fn open_change(server_id: &str, state: &ServerState, link: &LockLink, master: &NativeKeypair) -> Option<zeroize::Zeroizing<[u8; 32]>> {
    state
        .join_lock
        .grants_for(&link.change, &master.peer_id())
        .iter()
        .find_map(|grant| join_lock::open_grant(server_id, &link.change, master, grant))
}

/// The op for a lock the relay took: its door for every member, its change key for
/// every owner, admin and mod.
fn lock_op(server_id: &str, new: &NewLock, state: &ServerState) -> CrdtPayload {
    let grants = state
        .moderation_masters()
        .into_iter()
        .filter_map(|m| Some((m.clone(), join_lock::seal_grant(server_id, &new.link.change, &m, &new.change)?)))
        .collect();
    CrdtPayload::JoinLock {
        link: new.link.clone(),
        door: Some(JoinSecret(hex::encode(new.door.as_slice()))),
        grants,
    }
}
