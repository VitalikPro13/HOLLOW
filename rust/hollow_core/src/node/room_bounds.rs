//! The device bound of each server room the node holds, for the relay pacer
//! (`relay_pace`, `WsCommand::RoomBound`): presence alone undercounts a room, because
//! hidden, held and fetch receivers are never listed (decision 6), and a door room's
//! every receiver is a member device.

use std::collections::HashMap;

use tokio::sync::mpsc::UnboundedSender;

use super::resolver;
use super::ws_client::WsCommand;
use crate::crdt::server_state::ServerState;

/// How many devices the resolver links to each master, from one read of the link map: a
/// pass looks members up here, never scanning the map per member (HIGH 2 of the G2 review).
fn device_counts() -> HashMap<String, usize> {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for (device, master) in resolver::all_links() {
        if device != master {
            *counts.entry(master).or_default() += 1;
        }
    }
    counts
}

/// An upper bound on the devices in `state`'s room: each member's devices (at least one),
/// and ours.
fn server_bound(state: &ServerState, own_master: &str, counts: &HashMap<String, usize>) -> u32 {
    let devices = |m: &str| counts.get(m).copied().unwrap_or(0).max(1);
    let members: usize = state.members.keys().map(|m| devices(m)).sum();
    u32::try_from(members + devices(own_master)).unwrap_or(u32::MAX)
}

/// Tells ws_client every server room's bound that changed since the last call (`all`:
/// every one, as a fresh session's joins are about to be priced).
pub(crate) fn send(
    ws_cmd_tx: &UnboundedSender<WsCommand>,
    server_states: &HashMap<String, ServerState>,
    own_master: &str,
    sent: &mut HashMap<String, u32>,
    all: bool,
) {
    sent.retain(|room, _| server_states.contains_key(room));
    if server_states.is_empty() {
        return;
    }
    let counts = device_counts();
    for (room, state) in server_states {
        let devices = server_bound(state, own_master, &counts);
        if !all && sent.get(room) == Some(&devices) {
            continue;
        }
        sent.insert(room.clone(), devices);
        let _ = ws_cmd_tx.send(WsCommand::RoomBound { room_code: room.clone(), devices });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::server_state::MemberInfo;
    use std::time::{Duration, Instant};

    fn id(n: usize, tag: u8) -> String {
        format!("12D3KooW{tag:02x}{n:044x}")
    }

    /// The design's reference user R (10 servers of 512 identities and 40 of 200, three
    /// devices each, 39,360 links): a pass reads the link map once, never once per member
    /// (HIGH 2 of the G2 code review: per-member scans took 1.6 s on an M4).
    #[test]
    fn room_bounds_pass_is_linear() {
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        let identities = 10 * 512 + 40 * 200;
        for i in 0..identities {
            let devices: Vec<String> = (0..3).map(|k| id(i * 3 + k, 0xd0)).collect();
            resolver::update_many(&id(i, 0x4d), devices.iter().map(String::as_str));
        }
        let mut states = HashMap::new();
        let mut next = 0;
        for (count, size) in [(10, 512), (40, 200)] {
            for _ in 0..count {
                let sid = format!("{:040x}", next + 1);
                let mut st = ServerState::new(sid.clone(), "s".into(), id(next % identities, 0x4d));
                for j in 0..size {
                    let m = id((next + j) % identities, 0x4d);
                    st.members.insert(m.clone(), MemberInfo { peer_id: m, display_name: String::new() });
                }
                states.insert(sid, st);
                next += size;
            }
        }
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let mut sent = HashMap::new();
        let started = Instant::now();
        send(&tx, &states, &id(0, 0x4d), &mut sent, true);
        let took = started.elapsed();
        resolver::clear_for_test();
        let mut rooms = 0;
        while let Ok(WsCommand::RoomBound { room_code, devices }) = rx.try_recv() {
            let members = states[&room_code].members.len() as u32;
            assert_eq!(devices, members * 3 + 3, "three devices a member, and ours");
            rooms += 1;
        }
        assert_eq!(rooms, 50);
        // A quadratic pass takes tens of seconds here; CI's coverage build runs about 1 s.
        assert!(took < Duration::from_secs(3), "one pass over 13,120 members took {took:?}");
    }
}
