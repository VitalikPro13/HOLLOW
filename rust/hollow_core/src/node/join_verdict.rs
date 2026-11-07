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

/// The refusal an ask made with a link the owner reset gets.
pub(crate) const INVITE_RESET: &str = "invite_reset";

tokio::task_local! {
    /// Set while a join box that a key an invite reset retired opened is handled.
    pub(crate) static OLD_LINK: bool;
}

/// Whether the join request being handled came in a box a retired invite key opened.
pub(crate) fn old_link() -> bool {
    OLD_LINK.try_with(|old| *old).unwrap_or(false)
}

/// Why a newcomer's ask was not made with the server's current invite link, if it was
/// not: a retired key opened its box or its signed key names one, or it names no key
/// (an older client).
pub(crate) fn link_refusal(state: &ServerState, ask: Option<&JoinAsk>, old_link: bool) -> Option<&'static str> {
    if old_link {
        return Some(INVITE_RESET);
    }
    match ask.and_then(|a| a.key.as_ref()) {
        None => Some(super::sync_handler::INVITE_OUTDATED),
        Some(key) if state.join_public_text().as_ref() != Some(key) => Some(INVITE_RESET),
        Some(_) => None,
    }
}

/// The gates a joiner meets, in the order the joiner is told: a reset link, ban,
/// private, full, Twitch, owner-verify, adult-content consent. Our own devices skip
/// them; a reset link, private, full and consent never refuse a returning member.
#[allow(clippy::too_many_arguments)]
pub(crate) fn verdict(
    state: &ServerState,
    member_master: &str,
    is_sibling: bool,
    already_member: bool,
    ask: Option<&JoinAsk>,
    old_link: bool,
    twitch_proof_json: Option<&str>,
    nsfw_confirmed: bool,
    local_master: &str,
    reachable: impl Fn(&str) -> bool,
) -> Verdict {
    let refuse = |reason: String, settles: bool| Verdict::Refuse { reason, settles };
    if is_sibling {
        return Verdict::Admit;
    }
    // First, so an old link learns nothing else of the server (its name, its gates).
    if !already_member && let Some(reason) = link_refusal(state, ask, old_link) {
        return refuse(reason.into(), true);
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Invite reset: a newcomer's request is refused for its link before any gate that
    /// names the server, whatever the box held: one a retired key opened as reset, one
    /// naming no key as outdated.
    #[test]
    fn the_link_gate_comes_first_whatever_the_box_held() {
        let (mut s, _) = crate::crdt::testkeys::owned_state("s1", "Secret name", 1);
        let set = |s: &mut ServerState, b: u8| {
            let op = s.create_op(crate::crdt::operations::CrdtPayload::JoinKeySet {
                secret: crate::crdt::operations::JoinSecret(hex::encode([b; 32])),
            });
            let _ = s.apply_op(&op);
        };
        set(&mut s, 1);
        set(&mut s, 2);
        let op = s.create_op(crate::crdt::operations::CrdtPayload::ServerSettingChanged { key: "is_private".into(), value: "true".into() });
        let _ = s.apply_op(&op);
        let joiner = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[50; 32]);
        let key = |b: u8| super::super::sealed_box::key_to_text(&super::super::sealed_box::public_of(&[b; 32]));
        let judge = |ask: Option<&JoinAsk>, old: bool| verdict(&s, &joiner.peer_id(), false, false, ask, old, None, false, "owner", |_| false);
        let refused = |reason: &str| Verdict::Refuse { reason: reason.into(), settles: true };

        assert_eq!(judge(None, true), refused(INVITE_RESET), "no ask, in a box a retired key opened");
        let keyless = JoinAsk::sign("s1", 1, &joiner);
        assert_eq!(judge(Some(&keyless), true), refused(INVITE_RESET), "a keyless ask a retired key opened");
        assert_eq!(judge(None, false), refused(super::super::sync_handler::INVITE_OUTDATED), "no ask names no key");
        assert_eq!(judge(Some(&keyless), false), refused(super::super::sync_handler::INVITE_OUTDATED));
        let old = JoinAsk::sign_for_invite("s1", 1, &key(1), &joiner).unwrap();
        assert_eq!(judge(Some(&old), false), refused(INVITE_RESET));
        let current = JoinAsk::sign_for_invite("s1", 1, &key(2), &joiner).unwrap();
        assert_eq!(judge(Some(&current), false), refused("server_private:Secret name"), "the current link meets the gates");
        assert_eq!(
            verdict(&s, &joiner.peer_id(), false, true, None, true, None, false, "owner", |_| false),
            Verdict::Admit,
            "a returning member is no newcomer",
        );
    }
}
