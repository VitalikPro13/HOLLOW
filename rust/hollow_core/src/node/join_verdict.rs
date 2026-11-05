//! A member's verdict on a join ask, and what an ask may leave behind (HOL-SEC-192).
//!
//! Anyone holding an invite link can seal an ask, and identities are free, so an ask
//! keeps its asker's roster and card only when the server would admit it. Both the answer
//! and that bound read [`verdict`], so they never part.

use crate::crdt::operations::{JoinAsk, MemberRole};
use crate::crdt::server_state::ServerState;

use super::twitch::{self, TwitchServerSettings};

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Verdict {
    Admit,
    /// `settles` records the ask as answered; an interactive refusal (a Twitch
    /// credential or adult-content consent still to come) leaves it open.
    Refuse { reason: String, settles: bool },
    /// Only the owner admits on this server, and it is online to.
    OwnersCall,
}

/// The gates a joiner meets, in the order the joiner is told: ban, private, full,
/// Twitch, owner-verify, adult-content consent. Our own devices skip them; private,
/// full and consent never refuse a returning member.
#[allow(clippy::too_many_arguments)]
pub(crate) fn verdict(
    state: &ServerState,
    member_master: &str,
    is_sibling: bool,
    already_member: bool,
    twitch_proof_json: Option<&str>,
    nsfw_confirmed: bool,
    local_master: &str,
    reachable: impl Fn(&str) -> bool,
) -> Verdict {
    let refuse = |reason: String, settles: bool| Verdict::Refuse { reason, settles };
    if is_sibling {
        return Verdict::Admit;
    }
    if state.is_banned(member_master) {
        return refuse("banned".into(), true);
    }
    if !already_member && state.is_private() {
        return refuse(format!("server_private:{}", state.name()), true);
    }
    if !already_member && super::member_cap::is_full(state) {
        return refuse(format!("server_full:{}:{}", state.name(), super::member_cap::effective_cap(state)), true);
    }
    if let Some(tw) = TwitchServerSettings::from_server_state(state) {
        let failed = match twitch_proof_json {
            None => Some("twitch_required".to_string()),
            Some(entry) => twitch::validate_follow_credential(entry, member_master, &tw).err(),
        };
        if let Some(reason) = failed {
            // The joiner's client shows the requirements and retries with a credential.
            return if reason == "twitch_required" {
                refuse(
                    format!(
                        "twitch_required:{}:{}:{}:{}:{}",
                        tw.channel_id, tw.channel_name, state.name(), tw.min_follow_days, tw.require_sub,
                    ),
                    false,
                )
            } else {
                refuse(format!("twitch_failed:{}:{}:{}", tw.channel_name, state.name(), reason), true)
            };
        }
        let owner = state.roles.iter().find(|(_, reg)| *reg.read() == MemberRole::Owner).map(|(id, _)| id.as_str());
        if tw.owner_verify && let Some(owner) = owner && owner != local_master {
            return if reachable(owner) {
                Verdict::OwnersCall
            } else {
                refuse(format!("twitch_owner_offline:{}", state.name()), true)
            };
        }
    }
    if !already_member && state.is_nsfw() && !nsfw_confirmed {
        return refuse(format!("nsfw_confirm:{}", state.name()), false);
    }
    Verdict::Admit
}

/// Whether an ask may keep its asker's roster and card: only one the server would admit,
/// which the member cap bounds, and for a newcomer only on its own signed ask, as the
/// admission itself needs. A banned asker's own signed ask keeps too, so the members see
/// who was refused: the ban list, never the asker, bounds those.
pub(crate) fn may_keep(
    verdict: &Verdict,
    server_id: &str,
    member_master: &str,
    already_member: bool,
    banned: bool,
    ask: Option<&JoinAsk>,
) -> bool {
    let signed = ask.is_some_and(|a| a.verifies(server_id, member_master));
    (!matches!(verdict, Verdict::Refuse { .. }) && (already_member || signed)) || (banned && signed)
}
