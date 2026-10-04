//! Join asks a member back from away holds until it knows what it missed (HOL-SEC-121).
//!
//! The join ring replays oldest first, so a parked ask comes before the verdict that
//! answered it, and a member's own state can predate the joiner's removal until its
//! first sync with another member lands. An ask that arrives in that gap waits, then
//! goes through the ordinary handler.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use super::types::{HavenMessage, ServerStates};

/// Longest an ask waits, from our first roster of the server's room on this
/// connection; short of a live joiner's window, so a held answer still reaches it.
pub(crate) const HOLD_WAIT: Duration = Duration::from_secs(10);
/// Asks held per server: the relay keeps 200 frames per ring.
const MAX_HELD: usize = 200;

/// An ask waiting to be judged, with what judging it needs.
pub(crate) struct HeldAsk {
    pub from: String,
    pub frame_ts: i64,
    pub msg: HavenMessage,
    /// Whom the ask speaks for: their own sync never vouches for it.
    asker: [String; 2],
    parked: bool,
}

/// This connection's first look at one server we hold.
struct Fresh {
    since: Instant,
    /// Held while no socket was up, so it may have missed a removal.
    stale: bool,
    /// The join ring topic whose replay has not ended.
    ring: Option<String>,
    held: Vec<HeldAsk>,
}

#[derive(Default)]
pub(crate) struct JoinHold {
    known: HashSet<String>,
    fresh: HashMap<String, Fresh>,
    /// Server -> members whose answer to an ask of this connection we merged.
    synced: HashMap<String, HashSet<String>>,
    /// The nonce this connection's sync asks carry; an answer the relay kept from an
    /// earlier ask carries an older one.
    ask: u64,
}

impl JoinHold {
    /// No socket is up (at start, or it died): every server held now may change
    /// without us. What waits is dropped; the next socket reads the ring again.
    pub(crate) fn went_away(&mut self, server_states: &ServerStates) {
        self.known = server_states.keys().cloned().collect();
        let dropped: usize = self.fresh.values().map(|f| f.held.len()).sum();
        if dropped > 0 {
            hollow_log!("[HOLLOW-CRDT] Dropped {dropped} held join ask(s) with the socket; the next ring read brings them back");
        }
        self.fresh.clear();
        self.synced.clear();
        self.ask = (super::types::now_ms().max(0) as u64).max(self.ask + 1);
    }

    pub(crate) fn ask(&self) -> u64 {
        self.ask
    }

    /// Our first roster of a server's room on this connection in which the relay shows
    /// us the room: a hidden socket reads no ring and sees no member to sync with.
    pub(crate) fn joined(&mut self, server: &str, hidden: bool) {
        if hidden {
            return;
        }
        let stale = self.known.contains(server);
        self.fresh
            .entry(server.to_string())
            .or_insert_with(|| Fresh { since: Instant::now(), stale, ring: None, held: Vec::new() });
    }

    /// The relay stopped showing us a server's room: its lock moved and our state may
    /// not hold why. Until it shows us the room again, we answer no ask for it.
    pub(crate) fn hidden(&mut self, server: &str) {
        let dropped = self.fresh.remove(server).map_or(0, |f| f.held.len());
        if dropped > 0 {
            hollow_log!("[HOLLOW-CRDT] Dropped {dropped} held join ask(s) for {server}: the relay hides us there now");
        }
        self.known.insert(server.to_string());
    }

    /// The server's join ring replay was asked for: parked asks wait for its end.
    pub(crate) fn ring_asked(&mut self, server: &str, topic: &str) {
        if let Some(fresh) = self.fresh.get_mut(server) {
            fresh.ring = Some(topic.to_string());
        }
    }

    /// The relay's mark after a replay.
    pub(crate) fn ring_ended(&mut self, room: &str, channel: &str) {
        if let Some(fresh) = self.fresh.get_mut(room).filter(|f| f.ring.as_deref() == Some(channel)) {
            fresh.ring = None;
        }
    }

    /// The (server, member) a message from `from` vouches for once handled: a member's
    /// answer to a sync ask of this connection.
    pub(crate) fn sync_mark(&self, msg: &HavenMessage, from: &str, server_states: &ServerStates) -> Option<(String, String)> {
        let HavenMessage::SyncResponse { server_id, nonce: Some(nonce), .. } = msg else { return None };
        (*nonce == self.ask && self.known.contains(server_id) && server_states.get(server_id)?.is_member(from))
            .then(|| (server_id.clone(), super::resolver::resolve(from)))
    }

    pub(crate) fn synced(&mut self, mark: Option<(String, String)>) {
        if let Some((server, member)) = mark {
            self.synced.entry(server).or_default().insert(member);
        }
    }

    /// `msg` back when it may be judged now; `None` when it waits or is dropped.
    /// `visible` names the member devices the relay shows us in a server's room.
    pub(crate) fn hold(
        &mut self,
        from: &str,
        frame_ts: i64,
        msg: HavenMessage,
        visible: &dyn Fn(&str) -> Vec<String>,
    ) -> Option<HavenMessage> {
        let (server, parked, asker) = match &msg {
            HavenMessage::ServerJoinRequest { server_id, parked, device_list, .. } => (
                server_id.clone(),
                *parked,
                [super::resolver::resolve(from), device_list.as_ref().map(|l| l.master.clone()).unwrap_or_default()],
            ),
            _ => return Some(msg),
        };
        // A server we may have missed a removal on, whose room the relay does not show us:
        // only a direct reaches us there, which no honest joiner sends to a hidden member.
        let Some(fresh) = self.fresh.get(&server) else {
            if self.known.contains(&server) {
                hollow_log!("[HOLLOW-SECURITY] Dropped a join ask from {from} for {server}: the relay does not show us its room");
                return None;
            }
            return Some(msg);
        };
        let waits = fresh.since.elapsed() < HOLD_WAIT
            && ((parked && fresh.ring.is_some())
                || (fresh.stale && !informed(&asker, self.synced.get(&server), &visible(&server))));
        if !waits {
            return Some(msg);
        }
        let fresh = self.fresh.get_mut(&server)?;
        if fresh.held.len() >= MAX_HELD {
            hollow_log!("[HOLLOW-SECURITY] Dropped a join ask from {from} for {server}: {MAX_HELD} already wait");
            return None;
        }
        hollow_log!("[HOLLOW-CRDT] Holding a join ask from {from} for {server} (parked {parked}) until we know what we missed");
        fresh.held.push(HeldAsk { from: from.to_string(), frame_ts, msg, asker, parked });
        None
    }

    pub(crate) fn holds_any(&self) -> bool {
        self.fresh.values().any(|f| !f.held.is_empty())
    }

    /// The held asks that may be judged now, in arrival order per server.
    pub(crate) fn due(&mut self, visible: &dyn Fn(&str) -> Vec<String>) -> Vec<HeldAsk> {
        let mut out = Vec::new();
        for (server, fresh) in &mut self.fresh {
            if fresh.held.is_empty() {
                continue;
            }
            let expired = fresh.since.elapsed() >= HOLD_WAIT;
            let room = visible(server);
            let synced = self.synced.get(server);
            let mut forced = 0usize;
            let (ready, wait): (Vec<HeldAsk>, Vec<HeldAsk>) = std::mem::take(&mut fresh.held).into_iter().partition(|ask| {
                let known = (!ask.parked || fresh.ring.is_none()) && (!fresh.stale || informed(&ask.asker, synced, &room));
                forced += usize::from(expired && !known);
                expired || known
            });
            if forced > 0 {
                hollow_log!("[HOLLOW-CRDT] Judging {forced} held join ask(s) for {server} without the ring's end or a member's sync: neither came in time");
            }
            fresh.held = wait;
            out.extend(ready);
        }
        out
    }

    #[cfg(test)]
    fn age(&mut self, server: &str, by: Duration) {
        if let Some(fresh) = self.fresh.get_mut(server) {
            fresh.since = fresh.since.checked_sub(by).unwrap_or(fresh.since);
        }
    }
}

/// Whether we know what the members who could tell us more know: one besides the
/// asker synced with us, or none besides the asker is here to ask.
fn informed(asker: &[String; 2], synced: Option<&HashSet<String>>, visible: &[String]) -> bool {
    let other = |id: &str| !asker.iter().any(|a| super::resolver::same_identity(id, a));
    synced.is_some_and(|s| s.iter().any(|m| other(m))) || !visible.iter().any(|d| other(d))
}

/// The member devices the relay shows us in `server`'s room.
pub(crate) fn visible_members(
    server: &str,
    server_states: &ServerStates,
    ws_room_peers: &super::types::WsRoomPeers,
) -> Vec<String> {
    let (Some(state), Some(peers)) = (server_states.get(server), ws_room_peers.get(server)) else {
        return Vec::new();
    };
    peers.iter().filter(|d| state.is_member(d)).cloned().collect()
}

#[cfg(test)]
mod tests {
    use super::*;
        use crate::crdt::server_state::{MemberInfo, ServerState};

    fn ask(server: &str, parked: bool) -> HavenMessage {
        HavenMessage::ServerJoinRequest {
            server_id: server.into(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
            requested_at: 1,
            device_list: None,
            parked,
            key_package: None,
            reply_key: String::new(),
            card: None,
            avatar_b64: String::new(),
            ask: None,
        }
    }

    fn states(members: &[&str]) -> ServerStates {
        let mut state = ServerState::new("srv".into(), "s".into(), "owner".into());
        for m in members {
            state.members.insert((*m).into(), MemberInfo { peer_id: (*m).into(), display_name: (*m).into() });
        }
        HashMap::from([("srv".to_string(), state)])
    }

    /// Back on a server held before the socket: the ring is replaying and `x` is here.
    fn back(stale: bool) -> JoinHold {
        let mut hold = JoinHold::default();
        if stale {
            hold.went_away(&states(&[]));
        }
        hold.joined("srv", false);
        hold.ring_asked("srv", "~join");
        hold
    }

    fn answer(nonce: u64) -> HavenMessage {
        HavenMessage::SyncResponse { server_id: "srv".into(), ops_json: "[]".into(), nonce: Some(nonce) }
    }

    #[test]
    fn a_parked_ask_waits_for_the_end_of_the_ring_replay() {
        let nobody = |_: &str| Vec::new();
        let mut hold = back(false);
        assert!(hold.hold("j", 5, ask("srv", true), &nobody).is_none(), "read during the replay");
        assert!(hold.hold("k", 5, ask("srv", false), &nobody).is_some(), "a live ask on a server we just made is judged");
        assert!(hold.hold("j", 5, ask("other", true), &nobody).is_some(), "a server with no ring read");
        assert!(hold.due(&nobody).is_empty());
        hold.ring_ended("srv", "~other");
        assert!(hold.due(&nobody).is_empty(), "another ring's end");
        hold.ring_ended("srv", "~join");
        let due = hold.due(&nobody);
        assert_eq!(due.iter().map(|a| (a.from.as_str(), a.frame_ts)).collect::<Vec<_>>(), [("j", 5)]);
        assert!(hold.hold("j", 6, ask("srv", true), &nobody).is_some(), "after the end, judged at once");
    }

    #[test]
    fn a_hidden_room_answers_nothing_and_starts_no_wait() {
        let nobody = |_: &str| Vec::new();
        let mut hold = JoinHold::default();
        assert!(hold.hold("j", 5, ask("srv", false), &nobody).is_some(), "a server made on this socket");
        hold.went_away(&states(&[]));
        assert!(hold.hold("j", 5, ask("srv", false), &nobody).is_none(), "held while away, its room not shown yet");
        hold.joined("srv", true);
        hold.ring_asked("srv", "~join");
        assert!(hold.hold("j", 5, ask("srv", true), &nobody).is_none(), "the relay hides us there");
        assert!(!hold.holds_any(), "dropped, never held");
        hold.joined("srv", false);
        assert!(hold.hold("j", 5, ask("srv", false), &nobody).is_some(), "shown, with nobody else to ask");
        hold.ring_asked("srv", "~join");
        assert!(hold.hold("j", 5, ask("srv", true), &nobody).is_none());
        assert!(hold.holds_any(), "the wait began when the room showed");
    }

    #[test]
    fn losing_the_room_drops_what_waits_and_makes_the_server_stale() {
        let nobody = |_: &str| Vec::new();
        let x_here = |_: &str| vec!["x".to_string()];
        let mut hold = JoinHold::default();
        hold.joined("srv", false);
        hold.ring_asked("srv", "~join");
        assert!(hold.hold("j", 5, ask("srv", true), &nobody).is_none());
        assert!(hold.holds_any());
        hold.hidden("srv");
        assert!(!hold.holds_any(), "what waited is dropped");
        assert!(hold.hold("j", 5, ask("srv", false), &x_here).is_none(), "a member the relay hides answers nothing");
        assert!(!hold.holds_any());
        hold.joined("srv", false);
        assert!(hold.hold("j", 5, ask("srv", false), &x_here).is_none(), "shown again, it waits for a sync");
        assert!(hold.holds_any());
    }

    #[test]
    fn a_stale_member_waits_for_a_sync_from_someone_but_the_asker() {
        let x_here = |_: &str| vec!["x".to_string(), "j".to_string()];
        let mut hold = back(true);
        hold.ring_ended("srv", "~join");
        assert!(hold.hold("j", 5, ask("srv", false), &x_here).is_none(), "x could tell us what we missed");
        assert!(hold.hold("j", 5, ask("srv", true), &x_here).is_none());
        let asker_only = |_: &str| vec!["j".to_string()];
        assert!(hold.hold("j", 5, ask("srv", false), &asker_only).is_some(), "nobody but the asker to ask");
        hold.synced(Some(("srv".into(), "j".into())));
        assert!(hold.due(&x_here).is_empty(), "the asker's own sync vouches for nothing");
        hold.synced(Some(("srv".into(), "x".into())));
        assert_eq!(hold.due(&x_here).len(), 2);
        assert!(hold.hold("k", 5, ask("srv", false), &x_here).is_some(), "x synced: judged at once");
    }

    #[test]
    fn nothing_waits_past_the_hold() {
        let x_here = |_: &str| vec!["x".to_string()];
        let mut hold = back(true);
        assert!(hold.hold("j", 5, ask("srv", true), &x_here).is_none());
        assert!(hold.due(&x_here).is_empty());
        hold.age("srv", HOLD_WAIT);
        assert_eq!(hold.due(&x_here).len(), 1, "neither the ring's end nor a sync came");
        assert!(hold.hold("j", 5, ask("srv", true), &x_here).is_some());
    }

    #[test]
    fn held_asks_are_bounded_and_die_with_the_socket() {
        let x_here = |_: &str| vec!["x".to_string()];
        let mut hold = back(true);
        for _ in 0..MAX_HELD + 5 {
            assert!(hold.hold("j", 5, ask("srv", true), &x_here).is_none());
        }
        assert_eq!(hold.fresh["srv"].held.len(), MAX_HELD);
        hold.went_away(&states(&[]));
        assert!(!hold.holds_any());
        hold.joined("srv", false);
        assert!(hold.hold("j", 5, ask("srv", true), &x_here).is_none());
        assert_eq!(hold.fresh["srv"].held.len(), 1, "a new socket starts over");
    }

    #[test]
    fn only_a_members_answer_to_an_ask_of_this_connection_counts() {
        let states = states(&["x"]);
        let mut hold = JoinHold::default();
        hold.went_away(&HashMap::new());
        assert_eq!(hold.sync_mark(&answer(hold.ask()), "x", &states), None, "a server made on this socket");
        hold.went_away(&states);
        let now = hold.ask();
        assert_eq!(hold.sync_mark(&answer(now), "x", &states), Some(("srv".into(), "x".into())));
        assert_eq!(hold.sync_mark(&answer(now), "stranger", &states), None, "not a member");
        let before = now;
        hold.went_away(&states);
        assert!(hold.ask() > before, "every connection asks with a new nonce");
        assert_eq!(hold.sync_mark(&answer(before), "x", &states), None, "an answer to an earlier ask");
        let unasked = HavenMessage::SyncResponse { server_id: "srv".into(), ops_json: "[]".into(), nonce: None };
        assert_eq!(hold.sync_mark(&unasked, "x", &states), None, "an answer to no ask");
        let ask = HavenMessage::SyncRequest { server_id: "srv".into(), state_vector_json: "{}".into(), mls_epoch: None, nonce: None };
        assert_eq!(hold.sync_mark(&ask, "x", &states), None, "an ask proves nothing");
    }
}
