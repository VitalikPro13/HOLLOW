//! Our ops the relay never carried (t14-denyproof). While the relay refuses one of our
//! servers the sealer drops everything scoped to it, so an op of our identity made then
//! went to nobody and sits in no ring. Each such server keeps a mark below every op made
//! since, saved, so a restart during the refusal loses nothing; once the relay carries
//! the server again, our ops from the mark on go to every device of ours and to the
//! member devices the room lists, and the mark goes once a member device was handed
//! them. Marks, never op copies: the ops stay in `op_log`, so nothing is capped.

use std::collections::{BTreeMap, HashSet};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use crate::crdt::server_state::ServerState;

use super::types::HavenMessage;

const SETTING: &str = "unsent_ops";

/// How far below the refusal the mark sits: a frame the relay dropped just before it
/// told us goes again, and a copy a member already holds is a duplicate it drops.
const MARGIN_MS: u64 = 60_000;

/// TEST-ONLY: marks sit at the refusal itself, so a test can tell a kept mark from a
/// new one a few seconds later.
#[cfg(test)]
pub(crate) static NO_MARGIN: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn margin_ms() -> u64 {
    #[cfg(test)]
    if NO_MARGIN.load(std::sync::atomic::Ordering::Relaxed) {
        return 0;
    }
    MARGIN_MS
}

#[derive(Default, Serialize, Deserialize)]
struct Stored {
    /// Server -> the HLC milliseconds from which our ops may not have left.
    #[serde(default)]
    marks: BTreeMap<String, u64>,
}

#[derive(Default)]
pub(crate) struct UnsentOps {
    stored: Stored,
    /// Servers whose ops every device of ours was handed since this process began.
    own_told: HashSet<String>,
    db: Option<(String, String)>,
    saves: u64,
    written: Arc<Mutex<u64>>,
}

impl UnsentOps {
    pub(crate) fn load(db_path: &str, db_passphrase: &str) -> Self {
        let stored = crate::storage::MessageStore::lease(db_path, db_passphrase)
            .ok()
            .and_then(|store| store.load_setting(SETTING).ok().flatten())
            .and_then(|json| serde_json::from_str(&json).ok())
            .unwrap_or_default();
        Self { stored, db: Some((db_path.to_string(), db_passphrase.to_string())), ..Default::default() }
    }

    fn save(&mut self) {
        let Some((path, pass)) = self.db.clone() else { return };
        let Ok(json) = serde_json::to_string(&self.stored) else { return };
        self.saves += 1;
        let (n, written) = (self.saves, self.written.clone());
        let write = move || {
            let mut last = written.lock().unwrap_or_else(|e| e.into_inner());
            if *last > n {
                return;
            }
            match crate::storage::MessageStore::lease(&path, &pass).and_then(|store| store.save_setting(SETTING, &json)) {
                Ok(()) => *last = n,
                Err(e) => hollow_log!("[HOLLOW-CRDT] Could not keep the mark of our unsent ops: {e}"),
            }
        };
        match tokio::runtime::Handle::try_current() {
            Ok(rt) => drop(rt.spawn_blocking(write)),
            Err(_) => write(),
        }
    }

    /// The relay refused `state`'s server: our ops from about now on go nowhere. An
    /// earlier mark stays, so a refusal seen again after a restart keeps its start.
    pub(crate) fn refused(&mut self, state: &ServerState) {
        let sid = &state.server_id;
        self.own_told.remove(sid);
        if self.stored.marks.contains_key(sid) {
            return;
        }
        // The server's clock, not the wall's: every op minted later stamps above it.
        let now = state.hlc.as_ref().map(|h| h.latest().physical_ms).unwrap_or_else(crate::crdt::hlc::wall_clock_ms);
        self.stored.marks.insert(sid.clone(), now.saturating_sub(margin_ms()));
        self.save();
    }

    pub(crate) fn marked(&self, server: &str) -> bool {
        self.stored.marks.contains_key(server)
    }

    /// Our identity's ops on `state` from its mark on, in fold order.
    pub(crate) fn ours(&self, state: &ServerState, us: &str) -> Vec<HavenMessage> {
        let Some(&mark) = self.stored.marks.get(&state.server_id) else { return Vec::new() };
        state
            .op_log
            .iter()
            .filter(|op| op.hlc.physical_ms >= mark && super::resolver::same_identity(&op.author, us))
            .filter_map(|op| serde_json::to_string(op).ok())
            .map(|op_json| HavenMessage::CrdtOpBroadcast { server_id: state.server_id.clone(), op_json })
            .collect()
    }

    /// Whether every device of ours was handed `server`'s ops since we began.
    pub(crate) fn own_told(&self, server: &str) -> bool {
        self.own_told.contains(server)
    }

    /// `server`'s ops went to every device of ours and, when `member` is true, to a
    /// member device: that ends the mark.
    pub(crate) fn handed(&mut self, server: &str, member: bool) {
        self.own_told.insert(server.to_string());
        if member && self.stored.marks.remove(server).is_some() {
            hollow_log!("[HOLLOW-CRDT] Handed out our ops on {server} the relay had refused to carry");
            self.save();
        }
    }

    /// We no longer hold `server`.
    pub(crate) fn forget(&mut self, server: &str) {
        self.own_told.remove(server);
        if self.stored.marks.remove(server).is_some() {
            self.save();
        }
    }

    /// Marks of servers `held` no longer names go.
    pub(crate) fn retain(&mut self, held: impl Fn(&str) -> bool) {
        let before = self.stored.marks.len();
        self.stored.marks.retain(|sid, _| held(sid));
        if self.stored.marks.len() != before {
            self.save();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::operations::CrdtPayload;
    use crate::crdt::testkeys::keys;

    fn server() -> ServerState {
        let (kp, owner, pk) = keys(1);
        let (mut s, _) = ServerState::found("S".into(), owner, kp, pk);
        s.author_checked(CrdtPayload::ServerSettingChanged { key: "before".into(), value: "v".into() });
        s
    }

    fn op_json(msg: &HavenMessage) -> String {
        match msg {
            HavenMessage::CrdtOpBroadcast { op_json, .. } => op_json.clone(),
            other => panic!("not an op: {other:?}"),
        }
    }

    /// A refusal marks below every later op of ours, keeps its first mark when seen
    /// again, hands out only our identity's ops, and ends only once a member got them.
    #[test]
    fn a_mark_covers_every_op_made_while_refused_and_ends_at_a_member() {
        let mut s = server();
        let us = s.current_owner().expect("the founder owns it");
        let sid = s.server_id.clone();
        let mut unsent = UnsentOps::default();
        unsent.refused(&s);
        let first = unsent.stored.marks[&sid];
        for i in 0..100 {
            s.author_checked(CrdtPayload::ServerSettingChanged { key: format!("w{i}"), value: "v".into() });
        }
        unsent.refused(&s);
        assert_eq!(unsent.stored.marks[&sid], first, "a refusal seen again keeps the first mark");

        assert!(unsent.ours(&s, "someone_else").is_empty(), "another identity's ops are not ours to hand out");
        let carried: Vec<String> = unsent.ours(&s, &us).iter().map(op_json).collect();
        let made: Vec<String> = s.op_log[s.op_log.len() - 100..].iter().map(|op| serde_json::to_string(op).unwrap()).collect();
        assert!(carried.ends_with(&made), "every op made while refused, in fold order, uncapped");

        unsent.handed(&sid, false);
        assert!(unsent.own_told(&sid));
        assert!(unsent.marked(&sid), "our own devices alone do not end the mark");
        unsent.handed(&sid, true);
        assert!(!unsent.marked(&sid), "a member device handed the ops ends it");
    }

    /// The mark reads the server's clock: a wall clock stepped back during the refusal
    /// cannot put a later op below it.
    #[test]
    fn the_mark_follows_the_servers_clock_not_the_wall() {
        let mut s = server();
        let ahead = crate::crdt::hlc::wall_clock_ms() + 120_000;
        s.set_hlc(crate::crdt::hlc::Hlc::for_device_at(s.current_owner().unwrap(), "dev", ahead));
        let mut unsent = UnsentOps::default();
        unsent.refused(&s);
        assert!(unsent.stored.marks[&s.server_id] >= ahead - MARGIN_MS);
        s.author_checked(CrdtPayload::ServerSettingChanged { key: "later".into(), value: "v".into() });
        let us = s.current_owner().unwrap();
        assert!(!unsent.ours(&s, &us).is_empty(), "an op minted after the mark is above it");
    }
}
