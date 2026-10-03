use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};

use super::hlc::HlcTimestamp;
use super::operations::CrdtOp;
use super::server_state::ServerState;

/// Compact summary of what a peer has seen for a given server.
///
/// Maps each actor to the latest HLC timestamp we have seen from them, which is what
/// computes a sync delta.
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

/// What a former member asking to sync is told: the op that ended its membership and,
/// of the ops before it that `their_vector` lacks, those deciding who belongs and at
/// what rank for the identities that op rests on. Never an op stamped after it, and
/// nothing for an identity the log never shows as a member.
pub fn removal_notice<'a>(state: &'a ServerState, master: &str, their_vector: &StateVector) -> Vec<&'a CrdtOp> {
    let Some(removal) = membership_end(state, master) else { return Vec::new() };
    let mut earlier: Vec<&CrdtOp> = compute_delta(&state.op_log, their_vector)
        .into_iter()
        .filter(|op| op.hlc < removal.hlc)
        .collect();
    earlier.push(removal);
    // Grown by the author of every op picked for one of its identities until stable.
    let mut chain: HashSet<&str> = HashSet::from([master, removal.author.as_str()]);
    let mut picked = vec![false; earlier.len()];
    loop {
        let known = chain.len();
        for (op, pick) in earlier.iter().zip(picked.iter_mut()) {
            if !*pick && decides_rank(op, &chain) {
                *pick = true;
                chain.insert(op.author.as_str());
            }
        }
        if chain.len() == known {
            break;
        }
    }
    earlier.into_iter().zip(picked).filter_map(|(op, keep)| keep.then_some(op)).collect()
}

/// The op that last ended `master`'s membership, when the log shows it a member just
/// before that op and nothing after it admitted it again.
fn membership_end<'a>(state: &'a ServerState, master: &str) -> Option<&'a CrdtOp> {
    use super::operations::CrdtPayload as P;
    let mut member = false;
    let mut end = None;
    for op in &state.op_log {
        match &op.payload {
            P::ServerCreated { owner_peer_id, .. } => member = owner_peer_id == master,
            P::ServerCheckpoint { state: base, .. } => member = lists_member(base, master),
            P::MemberAdded { peer_id, .. } if peer_id == master => member = true,
            P::MemberRemoved { peer_id } | P::MemberBanned { peer_id } if peer_id == master && member => {
                member = false;
                end = Some(op);
            }
            _ => {}
        }
    }
    end.filter(|_| !member)
}

/// Whether a checkpoint's state lists `master` as a member.
fn lists_member(base: &str, master: &str) -> bool {
    #[derive(Deserialize)]
    struct Members {
        members: HashMap<String, serde::de::IgnoredAny>,
    }
    serde_json::from_str::<Members>(base).is_ok_and(|s| s.members.contains_key(master))
}

/// Whether `op` decides who belongs or at what rank for one of `chain`, or for
/// everyone: role permissions, the settings an admission reads, the anchor.
fn decides_rank(op: &CrdtOp, chain: &HashSet<&str>) -> bool {
    use super::operations::CrdtPayload as P;
    match &op.payload {
        P::MemberAdded { peer_id, .. }
        | P::MemberRemoved { peer_id }
        | P::MemberBanned { peer_id }
        | P::MemberUnbanned { peer_id }
        | P::RoleChanged { peer_id, .. } => chain.contains(peer_id.as_str()),
        P::RolePermissionsChanged { .. } | P::ServerCreated { .. } | P::ServerCheckpoint { .. } => true,
        P::ServerSettingChanged { key, .. } => {
            matches!(key.as_str(), "is_private" | "max_members") || key.starts_with("twitch_")
        }
        _ => false,
    }
}

/// What a sync-batch merge did.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MergeReport {
    /// Ops that were new to this replica and entered the op log.
    pub applied: usize,
    /// Ops refused (forged author, no signature, a timestamp past the drift bound, or
    /// a payload the author may not write at its point in the fold).
    pub rejected: usize,
    /// The state was rebuilt from its anchor.
    pub rebuilt: bool,
}

/// Apply incoming ops to a server state through the fold (`ServerState::ingest_remote`).
///
/// SECURITY: a sync batch is the easiest place to smuggle a forged op in, because its
/// sender is not its author and never had to be; every op is judged on its own.
pub fn merge_ops(state: &mut ServerState, incoming_ops: &[CrdtOp]) -> Result<MergeReport, String> {
    merge_ops_with(state, incoming_ops, |_| {})
}

/// `merge_ops` with a hook that fires for every op that entered the log, in log order,
/// so callers persist exactly those.
pub fn merge_ops_with(
    state: &mut ServerState,
    incoming_ops: &[CrdtOp],
    mut on_admitted: impl FnMut(&CrdtOp),
) -> Result<MergeReport, String> {
    let ingested = state.ingest_remote(incoming_ops);
    for op in &ingested.admitted {
        on_admitted(op);
    }
    Ok(MergeReport {
        applied: ingested.admitted.len(),
        rejected: ingested.rejected,
        rebuilt: ingested.rebuilt,
    })
}

/// Variant name for a rejection log line, never the payload: an op's contents can carry
/// a nickname or a channel name, and a security log is not the place to spill them.
pub fn payload_name(payload: &super::operations::CrdtPayload) -> &'static str {
    use super::operations::CrdtPayload as P;
    match payload {
        P::ServerCreated { .. } => "ServerCreated",
        P::ServerCheckpoint { .. } => "ServerCheckpoint",
        P::ServerRenamed { .. } => "ServerRenamed",
        P::ServerSettingChanged { .. } => "ServerSettingChanged",
        P::JoinKeySet { .. } => "JoinKeySet",
        P::JoinLock { .. } => "JoinLock",
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
            follow: None,
            ask: None,
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
        assert_eq!(report_b, MergeReport { applied: 1, rejected: 0, rebuilt: false });

        // Sync: B → A
        let sv_a = StateVector::from_server_state(&state_a);
        let delta_b_to_a = compute_delta(&state_b.op_log, &sv_a);
        let report_a = merge_ops(&mut state_a, &delta_b_to_a.into_iter().cloned().collect::<Vec<_>>()).unwrap();
        assert_eq!(report_a, MergeReport { applied: 1, rejected: 0, rebuilt: false });

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
        assert_eq!(report, MergeReport { applied: 0, rejected: 0, rebuilt: false });
    }

    /// The sync batch is where a forged op is easiest to smuggle in, since its sender is
    /// not its author. `merge_ops` refuses it and says so in the report.
    #[test]
    fn merge_ops_rejects_a_forged_op_in_the_batch() {
        let (mut state_a, a_id, mut state_b, _b_id) = two_member_server();

        // B forges an op that CLAIMS to come from the owner.
        let mut forged = state_b.create_op(CrdtPayload::ServerRenamed {
            new_name: "PWNED".into(),
        });
        forged.author = a_id.clone();

        let report = merge_ops(&mut state_a, &[forged]).unwrap();
        assert_eq!(report, MergeReport { applied: 0, rejected: 1, rebuilt: false });
        assert_eq!(state_a.name(), "Test", "a forged rename must not land");
    }

    /// Every restart restores the op log at its 1000-op cap, where each insert drains
    /// one op, so a replica there must still see a new op as new: callers persist,
    /// emit and re-flood only what the merge counts.
    #[test]
    fn a_full_op_log_still_counts_new_ops() {
        let (mut state_a, _a_id, mut state_b, _b_id) = two_member_server();
        for i in 0..1000 {
            let op = state_a.create_op(CrdtPayload::ServerSettingChanged {
                key: format!("k{i}"),
                value: "v".into(),
            });
            state_a.apply_op(&op).unwrap();
            state_b.apply_op(&op).unwrap();
        }
        assert_eq!(state_b.op_log.len(), 1000, "the replica sits at the cap");

        let fresh = state_a.create_op(CrdtPayload::ServerRenamed { new_name: "Fresh".into() });
        let report = merge_ops(&mut state_b, std::slice::from_ref(&fresh)).unwrap();
        assert_eq!(report, MergeReport { applied: 1, rejected: 0, rebuilt: false });
        assert_eq!(state_b.name(), "Fresh");
        let again = merge_ops(&mut state_b, &[fresh]).unwrap();
        assert_eq!(again, MergeReport { applied: 0, rejected: 0, rebuilt: false }, "a second copy is not new");
    }

    // HOL-SEC-114: what a former member asking to sync is told.

    /// An op by `tag`'s identity at an exact clock, signed like any real one.
    fn op_at(tag: u8, sid: &str, ms: u64, payload: CrdtPayload) -> CrdtOp {
        let (kp, id, pk) = keys(tag);
        let mut op = CrdtOp {
            server_id: sid.into(),
            hlc: HlcTimestamp { physical_ms: ms, counter: 0, actor: id.clone() },
            author: id,
            payload,
            auth: None,
        };
        op.sign(&kp, &pk);
        op
    }

    fn id(tag: u8) -> String {
        keys(tag).1
    }

    /// `tag` admitted to `sid` on its own ask made at `at`.
    fn add(sid: &str, tag: u8, at: i64) -> CrdtPayload {
        let ask = crate::crdt::operations::JoinAsk::sign(sid, at, &keys(tag).0);
        CrdtPayload::MemberAdded { peer_id: id(tag), display_name: "m".into(), follow: None, ask: Some(ask) }
    }

    fn folded(sid: &str, ops: &[CrdtOp]) -> ServerState {
        let mut s = ServerState::skeleton(sid.into());
        s.ingest_remote(ops);
        s
    }

    fn nothing_held(sid: &str) -> StateVector {
        StateVector { server_id: sid.into(), entries: HashMap::new() }
    }

    /// B left while X was a plain member; X was made a moderator and kicked B, then was
    /// demoted, and B was banned for good measure. B is told the kick and the promotion
    /// its own fold needs to admit it: not the rename before it, nothing after it.
    #[test]
    fn authz_a_former_member_is_told_its_removal_and_the_rank_behind_it_only() {
        use crate::crdt::operations::MemberRole;
        let (kp, owner, pk) = keys(1);
        let (_, founding) = ServerState::found("S".into(), owner, kp, pk);
        let sid = founding.server_id.clone();
        let t = founding.hlc.physical_ms;
        let (b, x) = (2u8, 3u8);
        let before = vec![founding, op_at(1, &sid, t + 1, add(&sid, b, 1)), op_at(1, &sid, t + 2, add(&sid, x, 1))];
        let kick = op_at(x, &sid, t + 5, CrdtPayload::MemberRemoved { peer_id: id(b) });
        let after = vec![
            op_at(1, &sid, t + 3, CrdtPayload::RoleChanged { peer_id: id(x), role: MemberRole::Moderator, priority: 3 }),
            op_at(1, &sid, t + 4, CrdtPayload::ServerRenamed { new_name: "while away".into() }),
            kick.clone(),
            op_at(1, &sid, t + 6, CrdtPayload::RoleChanged { peer_id: id(x), role: MemberRole::Member, priority: 3 }),
            op_at(1, &sid, t + 7, CrdtPayload::MemberBanned { peer_id: id(b) }),
            op_at(1, &sid, t + 8, CrdtPayload::RolePermissionsChanged { role: "member".into(), permissions: 0 }),
        ];
        let mut away = folded(&sid, &before);
        let members = folded(&sid, &[before.clone(), after].concat());
        assert!(!members.is_member(&id(b)) && members.is_banned(&id(b)));

        let notice = removal_notice(&members, &id(b), &StateVector::from_server_state(&away));
        let kinds: Vec<&str> = notice.iter().map(|op| payload_name(&op.payload)).collect();
        assert_eq!(kinds, ["RoleChanged", "MemberRemoved"], "only the kick and the promotion behind it");
        assert!(notice.iter().all(|op| op.hlc <= kick.hlc), "an op from after the removal was handed over");

        let told: Vec<CrdtOp> = notice.into_iter().cloned().collect();
        let mut kick_alone = away.clone();
        kick_alone.ingest_remote(&told[1..]);
        assert!(kick_alone.is_member(&id(b)), "without the promotion B's fold refuses the kick");
        away.ingest_remote(&told);
        assert!(!away.is_member(&id(b)), "B's own fold drops it");
    }

    /// Nothing for someone the log never shows as a member, a pre-emptive ban included,
    /// nor for a current member, a removed one admitted again among them. A ban of a
    /// member is a removal like a kick.
    #[test]
    fn authz_no_removal_notice_for_a_stranger_or_a_member() {
        let (kp, owner, pk) = keys(1);
        let (_, founding) = ServerState::found("S".into(), owner, kp, pk);
        let sid = founding.server_id.clone();
        let t = founding.hlc.physical_ms;
        let s = folded(&sid, &[
            founding,
            op_at(1, &sid, t + 1, add(&sid, 2, 1)),
            op_at(1, &sid, t + 2, CrdtPayload::MemberBanned { peer_id: id(5) }),
            op_at(1, &sid, t + 3, add(&sid, 3, 1)),
            op_at(1, &sid, t + 4, CrdtPayload::MemberRemoved { peer_id: id(3) }),
            op_at(1, &sid, t + 5, add(&sid, 3, 2)),
            op_at(1, &sid, t + 6, add(&sid, 4, 1)),
            op_at(1, &sid, t + 7, CrdtPayload::MemberBanned { peer_id: id(4) }),
        ]);
        assert!(s.is_member(&id(3)) && s.is_banned(&id(5)) && !s.is_member(&id(4)));
        let none = nothing_held(&sid);
        assert!(removal_notice(&s, &id(9), &none).is_empty(), "a stranger was told something");
        assert!(removal_notice(&s, &id(5), &none).is_empty(), "a stranger banned before it ever joined was told its ban");
        assert!(removal_notice(&s, &id(2), &none).is_empty(), "a member got a removal notice");
        assert!(removal_notice(&s, &id(3), &none).is_empty(), "a member admitted again got its old removal");
        let banned = removal_notice(&s, &id(4), &none);
        assert_eq!(banned.last().map(|op| payload_name(&op.payload)), Some("MemberBanned"), "a ban is a removal too");
    }

    /// A checkpoint prunes the admission, so the log shows the membership only through
    /// the checkpoint's state: a kick after it is still told.
    #[test]
    fn a_removal_after_a_checkpoint_is_still_told() {
        let (kp, owner, pk) = keys(1);
        let (mut s, _) = ServerState::found("S".into(), owner.clone(), kp, pk);
        let sid = s.server_id.clone();
        let join = s.author_checked(add(&sid, 3, 1)).expect("the owner admits 3");
        let covers = s.horizon();
        let base = s.checkpoint_json(&owner, &[], crate::crdt::hlc::wall_clock_ms()).expect("a checkpoint");
        s.author_checked(CrdtPayload::ServerCheckpoint { state: base, covers }).expect("the owner checkpoints");
        assert!(!s.op_log.iter().any(|op| op.hlc == join.hlc), "the checkpoint pruned the admission");
        let kick = s.author_checked(CrdtPayload::MemberRemoved { peer_id: id(3) }).expect("the owner kicks 3");
        let notice = removal_notice(&s, &id(3), &nothing_held(&sid));
        assert!(notice.iter().any(|op| op.hlc == kick.hlc), "a member the checkpoint lists was not told of its kick");
    }
}
