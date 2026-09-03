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

/// What a sync-batch merge did.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MergeReport {
    /// Ops that were new to this replica and changed the op log.
    pub applied: usize,
    /// Ops refused by `admit_remote_op` (forged author, no signature, a
    /// timestamp past the drift bound, or a payload the author may not write).
    pub rejected: usize,
}

/// Apply incoming ops to a server state. Skips duplicates (idempotent).
///
/// SECURITY: every op passes `ServerState::admit_remote_op` first. This is the
/// gate for ALL THREE SyncResponse ingest paths (plaintext, Olm fallback, MLS
/// envelope) — a sync batch is the easiest place to smuggle a forged op in,
/// because the batch's sender is not its author and never had to be.
///
/// An op that fails to apply (e.g. wrong server_id) is skipped rather than
/// aborting the merge — one foreign op must not block the rest of a sync.
pub fn merge_ops(state: &mut ServerState, incoming_ops: &[CrdtOp]) -> Result<MergeReport, String> {
    merge_ops_with(state, incoming_ops, |_| {})
}

/// `merge_ops` with a hook that fires for every ADMITTED op, in batch order,
/// before it is applied. Callers persist from here so the `crdt_ops` table
/// only ever receives ops that passed the gate.
pub fn merge_ops_with(
    state: &mut ServerState,
    incoming_ops: &[CrdtOp],
    mut on_admitted: impl FnMut(&CrdtOp),
) -> Result<MergeReport, String> {
    let mut report = MergeReport::default();
    for op in incoming_ops {
        if let Err(reason) = state.admit_remote_op(op) {
            report.rejected += 1;
            hollow_log!(
                "[HOLLOW-SECURITY] REJECTED synced CrdtOp {} for {} from {}: {reason}",
                payload_name(&op.payload),
                op.server_id,
                op.author,
            );
            continue;
        }
        on_admitted(op);
        let was_len = state.op_log.len();
        if state.apply_op(op).is_err() {
            continue;
        }
        if state.op_log.len() > was_len {
            report.applied += 1;
        }
    }
    Ok(report)
}

/// Variant name for a rejection log line. Never the payload itself: an op's
/// contents can carry a nickname or a channel name, and a security log is not
/// the place to spill them.
pub fn payload_name(payload: &super::operations::CrdtPayload) -> &'static str {
    use super::operations::CrdtPayload as P;
    match payload {
        P::ServerCreated { .. } => "ServerCreated",
        P::ServerRenamed { .. } => "ServerRenamed",
        P::ServerSettingChanged { .. } => "ServerSettingChanged",
        P::ServerDeleted { .. } => "ServerDeleted",
        P::ChannelAdded { .. } => "ChannelAdded",
        P::ChannelRemoved { .. } => "ChannelRemoved",
        P::ChannelRenamed { .. } => "ChannelRenamed",
        P::MemberAdded { .. } => "MemberAdded",
        P::MemberRemoved { .. } => "MemberRemoved",
        P::RoleChanged { .. } => "RoleChanged",
        P::NicknameChanged { .. } => "NicknameChanged",
        P::TwitchUsernameChanged { .. } => "TwitchUsernameChanged",
        P::ChannelLayoutUpdated { .. } => "ChannelLayoutUpdated",
        P::MessagePinned { .. } => "MessagePinned",
        P::MessageUnpinned { .. } => "MessageUnpinned",
        P::StoragePledgeChanged { .. } => "StoragePledgeChanged",
        P::RolePermissionsChanged { .. } => "RolePermissionsChanged",
        P::LabelCreated { .. } => "LabelCreated",
        P::LabelDeleted { .. } => "LabelDeleted",
        P::LabelUpdated { .. } => "LabelUpdated",
        P::LabelAssigned { .. } => "LabelAssigned",
        P::LabelUnassigned { .. } => "LabelUnassigned",
        P::ChannelVisibilityChanged { .. } => "ChannelVisibilityChanged",
        P::ChannelPostingChanged { .. } => "ChannelPostingChanged",
        P::ChannelPublicChanged { .. } => "ChannelPublicChanged",
        P::ChannelVisibilityLabelsChanged { .. } => "ChannelVisibilityLabelsChanged",
        P::ChannelPostingLabelsChanged { .. } => "ChannelPostingLabelsChanged",
        P::ChannelGrantSet { .. } => "ChannelGrantSet",
        P::ChannelGrantRevoked { .. } => "ChannelGrantRevoked",
        P::MemberBanned { .. } => "MemberBanned",
        P::MemberUnbanned { .. } => "MemberUnbanned",
        P::MemberMuted { .. } => "MemberMuted",
        P::MemberUnmuted { .. } => "MemberUnmuted",
        P::ChannelSlowModeChanged { .. } => "ChannelSlowModeChanged",
        P::ChannelMediaOnlyChanged { .. } => "ChannelMediaOnlyChanged",
        P::EmojiAdded { .. } => "EmojiAdded",
        P::EmojiRemoved { .. } => "EmojiRemoved",
        P::StickerAdded { .. } => "StickerAdded",
        P::StickerRemoved { .. } => "StickerRemoved",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::hlc::Hlc;
    use crate::crdt::operations::CrdtPayload;
    use crate::crdt::testkeys::{keys, owned_state};

    /// Owner A's server with member B added, plus B's own replica of it.
    /// Both replicas can author signed ops as their own identity.
    fn two_member_server() -> (ServerState, String, ServerState, String) {
        let (mut state_a, a_id) = owned_state("s1", "Test", 1);
        let (b_kp, b_id, b_pk) = keys(2);

        let add_b = state_a.create_op(CrdtPayload::MemberAdded {
            peer_id: b_id.clone(),
            display_name: "Bob".into(),
        });
        state_a.apply_op(&add_b).unwrap();

        let mut state_b = state_a.clone();
        state_b.set_hlc(Hlc::new(b_id.clone()));
        state_b.set_signer(b_kp, b_pk);

        (state_a, a_id, state_b, b_id)
    }

    #[test]
    fn state_vector_captures_latest_per_actor() {
        let (mut state, a_id) = owned_state("s1", "Test", 1);

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
        assert_eq!(sv.entries.len(), 1); // Only the owner has authored
        assert_eq!(sv.entries[&a_id], op2.hlc); // Latest op
    }

    #[test]
    fn delta_returns_missing_ops() {
        let (mut state_a, _a_id, mut state_b, _b_id) = two_member_server();

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

        // B has seen nothing NEW from A
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
        // Two peers of one server, each making a change it is allowed to make.
        let (mut state_a, _a_id, mut state_b, b_id) = two_member_server();

        // A (owner) adds a channel
        let op_a = state_a.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-a".into(),
            name: "from-a".into(),
            category: None,
            channel_type: "text".into(),
        });
        state_a.apply_op(&op_a).unwrap();

        // B (member) sets its OWN nickname — self-writes need no privilege
        let op_b = state_b.create_op(CrdtPayload::NicknameChanged {
            peer_id: b_id.clone(),
            nickname: "Bobby".into(),
        });
        state_b.apply_op(&op_b).unwrap();

        // Sync: A → B
        let sv_b = StateVector::from_server_state(&state_b);
        let delta_a_to_b = compute_delta(&state_a.op_log, &sv_b);
        let report_b = merge_ops(&mut state_b, &delta_a_to_b.into_iter().cloned().collect::<Vec<_>>()).unwrap();
        assert_eq!(report_b, MergeReport { applied: 1, rejected: 0 });

        // Sync: B → A
        let sv_a = StateVector::from_server_state(&state_a);
        let delta_b_to_a = compute_delta(&state_b.op_log, &sv_a);
        let report_a = merge_ops(&mut state_a, &delta_b_to_a.into_iter().cloned().collect::<Vec<_>>()).unwrap();
        assert_eq!(report_a, MergeReport { applied: 1, rejected: 0 });

        // Both have the same state
        assert_eq!(state_a.channels.len(), state_b.channels.len());
        assert_eq!(state_a.members.len(), state_b.members.len());
        assert!(state_a.channels.contains_key("ch-a"));
        assert!(state_b.channels.contains_key("ch-a"));
        assert_eq!(state_a.get_nickname(&b_id), "Bobby");
        assert_eq!(state_b.get_nickname(&b_id), "Bobby");
    }

    #[test]
    fn merge_ops_skips_duplicates() {
        let (mut state, _a_id) = owned_state("s1", "Test", 1);
        let op = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch1".into(),
            name: "one".into(),
            category: None,
            channel_type: "text".into(),
        });
        state.apply_op(&op).unwrap();

        // Try to merge the same op again
        let report = merge_ops(&mut state, &[op]).unwrap();
        assert_eq!(report, MergeReport { applied: 0, rejected: 0 });
    }

    /// The sync batch is where a forged op is easiest to smuggle in: its
    /// sender is not its author and never had to be. `merge_ops` refuses it
    /// and says so in the report.
    #[test]
    fn merge_ops_rejects_a_forged_op_in_the_batch() {
        let (mut state_a, a_id, mut state_b, _b_id) = two_member_server();

        // B forges an op that CLAIMS to come from the owner.
        let mut forged = state_b.create_op(CrdtPayload::ServerRenamed {
            new_name: "PWNED".into(),
        });
        forged.author = a_id.clone();

        let report = merge_ops(&mut state_a, &[forged]).unwrap();
        assert_eq!(report, MergeReport { applied: 0, rejected: 1 });
        assert_eq!(state_a.name(), "Test", "a forged rename must not land");
    }
}
