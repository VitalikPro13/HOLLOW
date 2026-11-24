//! What a CRDT sync ask and answer carry beyond ops (DEVICE_PROOF_DESIGN sections 8.4,
//! 8.8 and 9): rosters before ops, the asker's own roster, a base the answerer dropped,
//! the floor round, and the witness ask. Every field is `#[serde(default)]`, so a 0.13
//! peer ignores the whole box; checkpoint ops ride as JSON text and are read with
//! `read_op`, so one op of a newer build never wedges the message.

use serde::{Deserialize, Serialize};

use crate::crdt::authority::{CpWitness, WitnessAsk};
use crate::identity::roster::Roster;

/// Masters one ask may want rosters for.
pub(crate) const MAX_ROSTERS_WANTED: usize = 64;
/// (master, digest) pairs one digest answer may carry.
pub(crate) const MAX_RD: usize = 512;
/// Roster bytes one answer may carry.
pub(crate) const MAX_ROSTER_ANSWER_BYTES: usize = 1024 * 1024;
/// Bytes of one checkpoint op riding an ask or an answer, the core's checkpoint bound.
pub(crate) const MAX_BASE_OP_BYTES: usize = crate::crdt::fold::MAX_CHECKPOINT_BYTES;

/// `SyncRequest.x`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct AskExt {
    /// Masters whose rosters the asker wants, at most [`MAX_ROSTERS_WANTED`].
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rosters_wanted: Vec<String>,
    /// The asking identity's own roster (N10), when the answerer may not place this device.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub asker_roster: Option<Roster>,
    /// The checkpoint op the digest's `bref` names, sent only after the answerer said it
    /// did not hold it (R3-8).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_content: Option<String>,
    /// The digest's `bref` names a restore point or a witnessed checkpoint (sections 8.3,
    /// 8.4), not the asker's base: an answerer lacking it says so instead of answering.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub named_base: bool,
    /// A floor round (section 8.8): the asker's server is in recovery, so the answer
    /// carries the answerer's base as a candidate.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub floor: bool,
    /// A fresh install's witness ask (section 8.4, track C1).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub witness: Option<WitnessAsk>,
}

/// `SyncResponse.x`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ReplyExt {
    /// Rosters the ask wanted that the answerer may hand over, at most
    /// [`MAX_ROSTER_ANSWER_BYTES`] in all.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rosters: Vec<Roster>,
    /// The answerer cannot place the asking device: ask again with its roster.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub roster_needed: bool,
    /// The answerer does not hold the checkpoint the ask's `bref` names.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub base_unknown: bool,
    /// The answerer's floor candidate: its pre-trigger base, or its base on a floor round.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub floor_base: Option<String>,
    /// A member's witness (section 8.4, track C1) and the checkpoint op it names, as JSON.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub witness: Option<CpWitness>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub witness_cp: Option<String>,
    /// The content ids of the record the witness names (HOL-SEC-230 part B); the ops
    /// themselves ride the digest sync.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub witness_rec: Vec<String>,
}

impl AskExt {
    pub(crate) fn is_empty(&self) -> bool {
        *self == AskExt::default()
    }

    /// `None` for an empty box, so a plain ask carries no field at all.
    pub(crate) fn boxed(self) -> Option<Box<AskExt>> {
        (!self.is_empty()).then(|| Box::new(self))
    }
}

impl ReplyExt {
    pub(crate) fn is_empty(&self) -> bool {
        *self == ReplyExt::default()
    }

    pub(crate) fn boxed(self) -> Option<Box<ReplyExt>> {
        (!self.is_empty()).then(|| Box::new(self))
    }
}

/// The checkpoint op riding as `text`, when it reads as one op within the bound.
pub(crate) fn read_base_op(text: &str) -> Option<crate::crdt::operations::CrdtOp> {
    if text.len() > MAX_BASE_OP_BYTES {
        return None;
    }
    match crate::crdt::operations::read_op(text) {
        crate::crdt::operations::ReadOp::Op(op) => Some(op),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_box_rides_as_nothing_and_an_old_peer_reads_past_a_full_one() {
        assert!(AskExt::default().boxed().is_none());
        assert!(ReplyExt::default().boxed().is_none());
        let ask = AskExt { rosters_wanted: vec!["m".into()], floor: true, ..Default::default() };
        let json = serde_json::to_string(&ask).unwrap();
        assert_eq!(serde_json::from_str::<AskExt>(&json).unwrap(), ask);
        let reply: ReplyExt = serde_json::from_str(r#"{"roster_needed":true,"unknown_newer":[1,2]}"#).unwrap();
        assert!(reply.roster_needed, "a newer field broke the box");
    }
}
