use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use super::hlc::HlcTimestamp;
use super::operations::CrdtOp;
use super::server_state::ServerState;

/// Compact summary of what a peer has seen for a given server.
///
/// Maps each actor (originator peer ID) to the latest HLC timestamp
/// we've seen from them. Used to compute deltas during sync.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StateVector {
    pub server_id: String,
    pub entries: HashMap<String, HlcTimestamp>,
}

impl StateVector {
    /// Build a state vector from an operation log.
    pub fn from_op_log(server_id: &str, ops: &[CrdtOp]) -> Self {
        let mut entries = HashMap::new();
        for op in ops {
            let current = entries.get(&op.author);
            if current.is_none() || op.hlc > *current.unwrap() {
                entries.insert(op.author.clone(), op.hlc.clone());
            }
        }
        Self {
            server_id: server_id.to_string(),
            entries,
        }
    }

    /// Build from a ServerState's op_log.
    pub fn from_server_state(state: &ServerState) -> Self {
        Self::from_op_log(&state.server_id, &state.op_log)
    }
}

/// Compute the ops that `our_ops` has but `their_vector` is missing.
///
/// An op is "missing" if:
/// - The actor isn't in their state vector at all, or
/// - The op's HLC is strictly greater than their latest for that actor
pub fn compute_delta<'a>(our_ops: &'a [CrdtOp], their_vector: &StateVector) -> Vec<&'a CrdtOp> {
    our_ops
        .iter()
        .filter(|op| {
            match their_vector.entries.get(&op.author) {
                None => true, // They've never seen this author
                Some(their_latest) => op.hlc > *their_latest,
            }
        })
        .collect()
}

/// Apply incoming ops to a server state. Skips duplicates (idempotent).
/// Returns the number of new ops actually applied.
pub fn merge_ops(state: &mut ServerState, incoming_ops: Vec<CrdtOp>) -> Result<usize, String> {
    let mut applied = 0;
    for op in &incoming_ops {
        let was_len = state.op_log.len();
        state.apply_op(op)?;
        if state.op_log.len() > was_len {
            applied += 1;
        }
    }
    Ok(applied)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::hlc::Hlc;
    use crate::crdt::operations::CrdtPayload;

    #[test]
    fn state_vector_captures_latest_per_actor() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "peer_a".into());

        let op1 = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch1".into(),
            name: "one".into(),
            category: None,
            channel_type: "text".into(),
        });
        state.apply_op(&op1).unwrap();

        let op2 = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch2".into(),
            name: "two".into(),
            category: None,
            channel_type: "text".into(),
        });
        state.apply_op(&op2).unwrap();

        let sv = StateVector::from_server_state(&state);
        assert_eq!(sv.entries.len(), 1); // Only peer_a
        assert_eq!(sv.entries["peer_a"], op2.hlc); // Latest op
    }

    #[test]
    fn delta_returns_missing_ops() {
        let mut state_a = ServerState::new("s1".into(), "Test".into(), "peer_a".into());
        let mut state_b = state_a.clone();
        state_b.set_hlc(Hlc::new("peer_b".into()));

        // A makes two ops
        let op_a1 = state_a.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch1".into(),
            name: "one".into(),
            category: None,
            channel_type: "text".into(),
        });
        state_a.apply_op(&op_a1).unwrap();

        let op_a2 = state_a.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch2".into(),
            name: "two".into(),
            category: None,
            channel_type: "text".into(),
        });
        state_a.apply_op(&op_a2).unwrap();

        // B has seen nothing from A
        let sv_b = StateVector::from_server_state(&state_b);
        let delta = compute_delta(&state_a.op_log, &sv_b);
        assert_eq!(delta.len(), 2);

        // B applies first op, then asks for delta again
        state_b.apply_op(&op_a1).unwrap();
        let sv_b2 = StateVector::from_server_state(&state_b);
        let delta2 = compute_delta(&state_a.op_log, &sv_b2);
        assert_eq!(delta2.len(), 1);
        assert_eq!(delta2[0].hlc, op_a2.hlc);
    }

    #[test]
    fn full_sync_protocol_simulation() {
        // Two peers, each makes changes independently
        let mut state_a = ServerState::new("s1".into(), "Test".into(), "peer_a".into());
        let mut state_b = state_a.clone();
        state_b.set_hlc(Hlc::new("peer_b".into()));

        // A adds channel
        let op_a = state_a.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-a".into(),
            name: "from-a".into(),
            category: None,
            channel_type: "text".into(),
        });
        state_a.apply_op(&op_a).unwrap();

        // B adds member
        let op_b = state_b.create_op(CrdtPayload::MemberAdded {
            peer_id: "peer_b".into(),
            display_name: "Bob".into(),
        });
        state_b.apply_op(&op_b).unwrap();

        // Sync: A → B
        let sv_b = StateVector::from_server_state(&state_b);
        let delta_a_to_b = compute_delta(&state_a.op_log, &sv_b);
        let applied_b = merge_ops(&mut state_b, delta_a_to_b.into_iter().cloned().collect()).unwrap();
        assert_eq!(applied_b, 1);

        // Sync: B → A
        let sv_a = StateVector::from_server_state(&state_a);
        let delta_b_to_a = compute_delta(&state_b.op_log, &sv_a);
        let applied_a = merge_ops(&mut state_a, delta_b_to_a.into_iter().cloned().collect()).unwrap();
        assert_eq!(applied_a, 1);

        // Both have the same state
        assert_eq!(state_a.channels.len(), state_b.channels.len());
        assert_eq!(state_a.members.len(), state_b.members.len());
        assert!(state_a.channels.contains_key("ch-a"));
        assert!(state_b.channels.contains_key("ch-a"));
        assert!(state_a.members.contains_key("peer_b"));
        assert!(state_b.members.contains_key("peer_b"));
    }

    #[test]
    fn merge_ops_skips_duplicates() {
        let mut state = ServerState::new("s1".into(), "Test".into(), "peer_a".into());
        let op = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch1".into(),
            name: "one".into(),
            category: None,
            channel_type: "text".into(),
        });
        state.apply_op(&op).unwrap();

        // Try to merge the same op again
        let applied = merge_ops(&mut state, vec![op]).unwrap();
        assert_eq!(applied, 0);
    }
}
