//! Who may change an MLS group, judged by every receiver: design D in
//! `reports/planned/security/audit/design_D_mls_authority.md`. The committer plans its
//! own commits with the same rules, so an honest coordinator never builds a commit
//! that honest members refuse.

use crate::crdt::server_state::ServerState;
use crate::crypto::{CommitFacts, LeafIdentity, LeafView, MlsManager, Verdict, WelcomeFacts};

/// Whose rules a group follows.
pub(crate) enum GroupRules<'a> {
    /// A server group, or one of its channel subgroups, judged by our CRDT view.
    Server { state: &'a ServerState, channel: Option<&'a str> },
    /// A meeting has no CRDT: the identity that admitted us is its only committer.
    Meeting { host: Option<&'a str> },
}

impl GroupRules<'_> {
    /// Hold unless `master` is a current, unbanned member who can see a subgroup's
    /// channel: our view may simply not have caught up with a join or a role change.
    fn membership(&self, master: &str, what: &str) -> Verdict {
        match self {
            GroupRules::Meeting { .. } => Verdict::Accept,
            GroupRules::Server { state, channel } => {
                if !state.members.contains_key(master) || state.is_banned(master) {
                    Verdict::Hold(format!("{what} {master} is not a member here"))
                } else if channel.is_some_and(|c| !state.can_see_channel(master, c)) {
                    Verdict::Hold(format!("{what} {master} cannot see this channel"))
                } else {
                    Verdict::Accept
                }
            }
        }
    }
}

fn revoked(device: &str) -> bool {
    super::resolver::is_revoked(device)
}

/// A commit may remove a leaf of the committer's own identity, an unbound leaf, a
/// non-member's, a revoked device's, or one whose device the same commit re-adds.
fn removable(leaf: &LeafView, committer: &LeafIdentity, adds: &[LeafView], rules: &GroupRules) -> bool {
    let Some(target) = leaf.bound() else { return true };
    target.master == committer.master
        || revoked(&target.device)
        || rules.membership(&target.master, "") != Verdict::Accept
        || adds.iter().any(|a| a.bound().is_some_and(|b| b.device == target.device))
}

/// The ruling on a received commit, before it is merged.
pub(crate) fn commit_verdict(facts: &CommitFacts, rules: &GroupRules) -> Verdict {
    let Some(committer) = &facts.committer else {
        return Verdict::Refuse("not committed by a member leaf".into());
    };
    if facts.other_proposals {
        return Verdict::Refuse("carries a proposal other than add or remove".into());
    }
    if let Some(leaf) = facts.adds.iter().find(|l| l.bound().is_none()) {
        return Verdict::Refuse(format!("adds unbound leaf {}", leaf.id()));
    }
    let committer = match (committer, &facts.path_leaf) {
        (_, Some(LeafView::Unbound(raw))) => {
            return Verdict::Refuse(format!("replaces the committer's leaf with unbound {raw}"));
        }
        (LeafView::Bound(before), Some(LeafView::Bound(after))) if before != after => {
            return Verdict::Refuse(format!("committer {} turns into {}", before.device, after.device));
        }
        (LeafView::Unbound(raw), Some(LeafView::Bound(after))) => {
            if raw != &after.device && raw != &after.master {
                return Verdict::Refuse(format!("legacy leaf {raw} rebinds as {}", after.device));
            }
            if !facts.adds.is_empty() || !facts.removes.is_empty() {
                return Verdict::Refuse("a rebind carries membership changes".into());
            }
            return match rules {
                GroupRules::Meeting { host } if *host != Some(after.master.as_str()) => {
                    Verdict::Refuse("committer is not the meeting's host".into())
                }
                _ => rules.membership(&after.master, "rebinding committer"),
            };
        }
        (LeafView::Unbound(raw), None) => {
            return Verdict::Refuse(format!("committed by unbound leaf {raw}"));
        }
        (LeafView::Bound(identity), _) => identity,
    };
    if let Some(add) = facts.adds.iter().filter_map(LeafView::bound).find(|a| revoked(&a.device)) {
        return Verdict::Refuse(format!("adds revoked device {}", add.device));
    }
    if let GroupRules::Meeting { host } = rules {
        return if *host == Some(committer.master.as_str()) {
            Verdict::Accept
        } else {
            Verdict::Refuse("committer is not the meeting's host".into())
        };
    }
    if let hold @ Verdict::Hold(_) = rules.membership(&committer.master, "committer") {
        return hold;
    }
    for add in facts.adds.iter().filter_map(LeafView::bound) {
        if let hold @ Verdict::Hold(_) = rules.membership(&add.master, "added leaf") {
            return hold;
        }
    }
    if let Some(leaf) = facts.removes.iter().find(|l| !removable(l, committer, &facts.adds, rules)) {
        return Verdict::Hold(format!("removes {} while still a member", leaf.id()));
    }
    Verdict::Accept
}

/// The ruling on a received Welcome, before it replaces anything. `asked` says we
/// requested a leaf in this group recently (for a meeting: a knock is pending).
pub(crate) fn welcome_verdict(facts: &WelcomeFacts, rules: &GroupRules, asked: bool) -> Verdict {
    if !facts.group_id_matches {
        return Verdict::Refuse("names another group".into());
    }
    if !facts.own_leaf_is_ours {
        return Verdict::Refuse("our leaf in it is not this device".into());
    }
    if let Some(leaf) = facts.leaves.iter().find(|l| l.bound().is_none()) {
        return Verdict::Refuse(format!("holds unbound leaf {}", leaf.id()));
    }
    if let Some(leaf) = facts.leaves.iter().filter_map(LeafView::bound).find(|l| revoked(&l.device)) {
        return Verdict::Refuse(format!("holds revoked device {}", leaf.device));
    }
    if facts.replaces && !asked {
        return Verdict::Refuse("would replace our group, and we asked for nothing".into());
    }
    let Some(sender) = facts.sender.bound() else {
        return Verdict::Refuse("sent by an unbound leaf".into());
    };
    match rules {
        GroupRules::Meeting { .. } if !asked => Verdict::Refuse("no knock of ours is pending".into()),
        GroupRules::Meeting { .. } => Verdict::Accept,
        GroupRules::Server { state, .. } => {
            if let hold @ Verdict::Hold(_) = rules.membership(&sender.master, "sender") {
                return hold;
            }
            match facts.leaves.iter().filter_map(LeafView::bound).find(|l| state.is_banned(&l.master)) {
                Some(leaf) => Verdict::Hold(format!("holds a leaf of banned {}", leaf.master)),
                None => Verdict::Accept,
            }
        }
    }
}

/// The committer's side: which queued removals and adds go into one commit. An add
/// needs a bound KeyPackage for the device it was queued under, from a current
/// member; a current member's leaf is removed only alongside a re-add of its device.
pub(crate) fn plan_membership(
    leaves: &[LeafView],
    queued_removals: &[String],
    queued_adds: Vec<(String, Vec<u8>)>,
    ourselves: &LeafIdentity,
    rules: &GroupRules,
) -> (Vec<String>, Vec<(String, Vec<u8>)>) {
    let mut adds = Vec::new();
    let mut add_views = Vec::new();
    for (device, kp) in queued_adds {
        let Ok(view) = MlsManager::key_package_identity(&kp) else { continue };
        let Some(identity) = view.bound() else { continue };
        if identity.device != device
            || revoked(&identity.device)
            || rules.membership(&identity.master, "") != Verdict::Accept
        {
            continue;
        }
        add_views.push(view.clone());
        adds.push((device, kp));
    }
    let removals = queued_removals
        .iter()
        .filter(|id| {
            leaves
                .iter()
                .find(|l| l.id() == id.as_str())
                .is_some_and(|l| removable(l, ourselves, &add_views, rules))
        })
        .cloned()
        .collect();
    (removals, adds)
}

/// How long a leaf request of ours makes a Welcome for that group "asked for".
pub(crate) const ASKED_WINDOW: std::time::Duration = std::time::Duration::from_secs(120);

/// What we have done that makes a Welcome for a group one we asked for.
pub(crate) struct LeafRequests<'a> {
    pub bootstrap_requested: &'a std::collections::HashMap<String, std::time::Instant>,
    pub welcome_grace: &'a std::collections::HashMap<String, std::time::Instant>,
    pub awaiting_parked_join: &'a std::collections::HashSet<String>,
    pub join_pending: bool,
    /// The master whose KeyPackage request we last answered for this group.
    pub answered: Option<(String, std::time::Instant)>,
}

/// Whether a Welcome for `group_key` from `sender_master` answers a request of ours:
/// a KeyPackage we pushed, an eviction whose re-add we are waiting for, our own join
/// in flight, or a KeyPackage request we answered FOR THAT SENDER. Anyone can ask us
/// for a KeyPackage, so an answer vouches for its requester and nobody else.
pub(crate) fn asked_for_leaf(
    group_key: &str,
    server_id: &str,
    sender_master: Option<&str>,
    requests: &LeafRequests,
) -> bool {
    if super::conference::is_conference_sid(server_id) {
        return super::conference::conf_id_from_sid(server_id).is_some_and(super::conference::has_pending_knock);
    }
    let recent = |t: &std::time::Instant| t.elapsed() < ASKED_WINDOW;
    requests.join_pending
        || requests.awaiting_parked_join.contains(server_id)
        || requests.bootstrap_requested.get(group_key).is_some_and(recent)
        || requests.welcome_grace.get(group_key).is_some_and(recent)
        || requests
            .answered
            .as_ref()
            .is_some_and(|(requester, t)| recent(t) && sender_master == Some(requester.as_str()))
}

/// [`welcome_verdict`] for a group key, with the rules its server or meeting follows.
pub(crate) fn judge_welcome(
    server_states: &std::collections::HashMap<String, ServerState>,
    server_id: &str,
    channel: Option<&str>,
    asked: bool,
    facts: &WelcomeFacts,
) -> Verdict {
    if super::conference::is_conference_sid(server_id) {
        return welcome_verdict(facts, &GroupRules::Meeting { host: None }, asked);
    }
    match server_states.get(server_id) {
        Some(state) => welcome_verdict(facts, &GroupRules::Server { state, channel }, asked),
        None => Verdict::Hold("no state for this server yet".into()),
    }
}

/// [`commit_verdict`] for a group key, with the rules its server or meeting follows;
/// `meeting_host` is the meeting's pinned committer.
pub(crate) fn judge_commit(
    server_states: &std::collections::HashMap<String, ServerState>,
    server_id: &str,
    channel: Option<&str>,
    meeting_host: Option<&str>,
    facts: &CommitFacts,
) -> Verdict {
    if super::conference::is_conference_sid(server_id) {
        return commit_verdict(facts, &GroupRules::Meeting { host: meeting_host });
    }
    match server_states.get(server_id) {
        Some(state) => commit_verdict(facts, &GroupRules::Server { state, channel }),
        None => Verdict::Hold("no state for this server yet".into()),
    }
}

/// Leaves a coordinator sweeps before it adds anyone: unbound leaves, revoked
/// devices, and leaves of masters who are no longer members or cannot see the
/// subgroup's channel. Never our own.
pub(crate) fn stale_leaves(leaves: &[LeafView], ourselves: &str, rules: &GroupRules) -> Vec<String> {
    leaves
        .iter()
        .filter(|leaf| leaf.id() != ourselves)
        .filter(|leaf| match leaf.bound() {
            None => true,
            Some(identity) => {
                revoked(&identity.device) || rules.membership(&identity.master, "") != Verdict::Accept
            }
        })
        .map(|leaf| leaf.id().to_string())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::server_state::MemberInfo;

    fn leaf(device: &str, master: &str) -> LeafView {
        LeafView::Bound(LeafIdentity { device: device.into(), master: master.into() })
    }

    fn server(members: &[&str]) -> ServerState {
        let mut state = ServerState::new("s1".into(), "s".into(), members[0].into());
        for m in members {
            state.members.insert((*m).into(), MemberInfo { peer_id: (*m).into(), display_name: (*m).into() });
        }
        state
    }

    fn facts(committer: LeafView) -> CommitFacts {
        CommitFacts { committer: Some(committer), ..Default::default() }
    }

    /// Every hard rule refuses, whatever our CRDT view says.
    #[test]
    fn commit_hard_rules_refuse() {
        let state = server(&["owner", "alice"]);
        let rules = GroupRules::Server { state: &state, channel: None };
        let owner = leaf("owner-d", "owner");
        let refused = |f: &CommitFacts| matches!(commit_verdict(f, &rules), Verdict::Refuse(_));

        assert!(refused(&CommitFacts::default()), "external commit");
        assert!(refused(&CommitFacts { other_proposals: true, ..facts(owner.clone()) }));
        assert!(refused(&CommitFacts { adds: vec![LeafView::Unbound("x".into())], ..facts(owner.clone()) }));
        assert!(refused(&CommitFacts { path_leaf: Some(LeafView::Unbound("x".into())), ..facts(owner.clone()) }));
        assert!(refused(&CommitFacts { path_leaf: Some(leaf("alice-d", "alice")), ..facts(owner.clone()) }),
            "a committer may not turn into someone else");
        assert!(refused(&facts(LeafView::Unbound("owner".into()))), "unbound committer without a rebind");
        assert!(refused(&CommitFacts {
            path_leaf: Some(leaf("owner-d", "owner")),
            ..facts(LeafView::Unbound("alice".into()))
        }), "a legacy leaf may rebind only as itself");
        assert!(refused(&CommitFacts {
            path_leaf: Some(leaf("owner-d", "owner")),
            adds: vec![leaf("bob-d", "alice")],
            ..facts(LeafView::Unbound("owner".into()))
        }), "a rebind carries nothing else");
    }

    #[test]
    fn a_legacy_leaf_rebinds_as_its_own_device_or_master() {
        let state = server(&["owner", "alice"]);
        let rules = GroupRules::Server { state: &state, channel: None };
        let rebind = |legacy: &str| CommitFacts {
            path_leaf: Some(leaf("alice-d", "alice")),
            ..facts(LeafView::Unbound(legacy.into()))
        };
        assert_eq!(commit_verdict(&rebind("alice"), &rules), Verdict::Accept);
        assert_eq!(commit_verdict(&rebind("alice-d"), &rules), Verdict::Accept);
    }

    /// Rules our view may lag on hold instead of refusing.
    #[test]
    fn commit_membership_rules_hold() {
        let state = server(&["owner", "alice"]);
        let rules = GroupRules::Server { state: &state, channel: None };
        let owner = leaf("owner-d", "owner");
        let held = |f: &CommitFacts| matches!(commit_verdict(f, &rules), Verdict::Hold(_));

        assert!(held(&facts(leaf("eve-d", "eve"))), "a committer we do not know as a member");
        assert!(held(&CommitFacts { adds: vec![leaf("eve-d", "eve")], ..facts(owner.clone()) }),
            "adds someone we do not know as a member");
        assert!(held(&CommitFacts { removes: vec![leaf("alice-d", "alice")], ..facts(owner.clone()) }),
            "evicts a current member");
    }

    #[test]
    fn commit_removals_that_are_allowed() {
        let state = server(&["owner", "alice"]);
        let rules = GroupRules::Server { state: &state, channel: None };
        let owner = leaf("owner-d", "owner");
        let alice = leaf("alice-d", "alice");
        let accepted = |f: CommitFacts| commit_verdict(&f, &rules) == Verdict::Accept;

        assert!(accepted(CommitFacts { removes: vec![LeafView::Unbound("old".into())], ..facts(owner.clone()) }));
        assert!(accepted(CommitFacts { removes: vec![leaf("gone-d", "gone")], ..facts(owner.clone()) }),
            "a non-member");
        assert!(accepted(CommitFacts { removes: vec![leaf("alice-d2", "alice")], ..facts(alice.clone()) }),
            "the committer's own sibling");
        assert!(accepted(CommitFacts {
            removes: vec![alice.clone()],
            adds: vec![alice.clone()],
            ..facts(owner.clone())
        }), "a repair re-adds the device it removes");
        assert!(accepted(CommitFacts { adds: vec![alice.clone()], ..facts(owner.clone()) }));
    }

    #[test]
    fn revoked_devices_are_never_added_and_always_removable() {
        let _g = crate::node::resolver::test_lock();
        crate::node::resolver::clear_all();
        crate::node::resolver::mark_revoked(&["alice-stolen".into()]);
        let state = server(&["owner", "alice"]);
        let rules = GroupRules::Server { state: &state, channel: None };
        let owner = leaf("owner-d", "owner");
        let stolen = leaf("alice-stolen", "alice");
        assert!(matches!(
            commit_verdict(&CommitFacts { adds: vec![stolen.clone()], ..facts(owner.clone()) }, &rules),
            Verdict::Refuse(_)
        ));
        assert_eq!(
            commit_verdict(&CommitFacts { removes: vec![stolen], ..facts(owner) }, &rules),
            Verdict::Accept
        );
        crate::node::resolver::clear_all();
    }

    #[test]
    fn a_subgroup_admits_only_who_can_see_its_channel() {
        let mut state = server(&["owner", "alice"]);
        let cid = state.channels.keys().next().unwrap().clone();
        state.channels.get_mut(&cid).unwrap().visibility =
            crate::crdt::server_state::ChannelVisibility::AdminPlus;
        let rules = GroupRules::Server { state: &state, channel: Some(&cid) };
        let owner = leaf("owner-d", "owner");
        assert!(matches!(
            commit_verdict(&CommitFacts { adds: vec![leaf("alice-d", "alice")], ..facts(owner.clone()) }, &rules),
            Verdict::Hold(_)
        ));
        assert_eq!(
            commit_verdict(&CommitFacts { removes: vec![leaf("alice-d", "alice")], ..facts(owner) }, &rules),
            Verdict::Accept,
            "a member who cannot see the channel may be removed from its subgroup"
        );
    }

    #[test]
    fn only_the_host_commits_in_a_meeting() {
        let rules = GroupRules::Meeting { host: Some("host") };
        let host = leaf("host-d", "host");
        let guest = leaf("guest-d", "guest");
        assert_eq!(commit_verdict(&CommitFacts { removes: vec![guest.clone()], ..facts(host) }, &rules), Verdict::Accept);
        assert!(matches!(commit_verdict(&facts(guest), &GroupRules::Meeting { host: Some("host") }), Verdict::Refuse(_)));
        assert!(matches!(commit_verdict(&facts(leaf("x", "y")), &GroupRules::Meeting { host: None }), Verdict::Refuse(_)));
    }

    fn welcome(sender: LeafView, leaves: Vec<LeafView>, replaces: bool) -> WelcomeFacts {
        WelcomeFacts { group_id_matches: true, sender, leaves, own_leaf_is_ours: true, replaces }
    }

    #[test]
    fn welcome_rules() {
        let state = server(&["owner", "alice"]);
        let rules = GroupRules::Server { state: &state, channel: None };
        let owner = leaf("owner-d", "owner");
        let us = leaf("alice-d", "alice");
        let good = welcome(owner.clone(), vec![owner.clone(), us.clone()], false);

        assert_eq!(welcome_verdict(&good, &rules, false), Verdict::Accept, "no group held: asking is not needed");
        assert!(matches!(welcome_verdict(&WelcomeFacts { replaces: true, ..good.clone() }, &rules, false), Verdict::Refuse(_)),
            "never replaces our group unasked");
        assert_eq!(welcome_verdict(&WelcomeFacts { replaces: true, ..good.clone() }, &rules, true), Verdict::Accept);
        assert!(matches!(welcome_verdict(&WelcomeFacts { group_id_matches: false, ..good.clone() }, &rules, true), Verdict::Refuse(_)));
        assert!(matches!(welcome_verdict(&WelcomeFacts { own_leaf_is_ours: false, ..good.clone() }, &rules, true), Verdict::Refuse(_)));
        assert!(matches!(
            welcome_verdict(&welcome(owner.clone(), vec![owner.clone(), us.clone(), LeafView::Unbound("x".into())], false), &rules, true),
            Verdict::Refuse(_)
        ));
        assert!(matches!(
            welcome_verdict(&welcome(leaf("eve-d", "eve"), vec![leaf("eve-d", "eve"), us.clone()], false), &rules, true),
            Verdict::Hold(_)
        ), "a sender we do not know as a member");

        let meeting = GroupRules::Meeting { host: None };
        assert_eq!(welcome_verdict(&good, &meeting, true), Verdict::Accept);
        assert!(matches!(welcome_verdict(&good, &meeting, false), Verdict::Refuse(_)), "no knock pending");
    }

    #[test]
    fn the_planner_keeps_only_what_receivers_accept() {
        let state = server(&["owner", "alice", "bob"]);
        let rules = GroupRules::Server { state: &state, channel: None };
        let ourselves = LeafIdentity { device: "owner-d".into(), master: "owner".into() };
        let leaves = vec![
            leaf("owner-d", "owner"),
            leaf("alice-d", "alice"),
            leaf("bob-d", "bob"),
            leaf("gone-d", "gone"),
            LeafView::Unbound("legacy".into()),
        ];
        // Bob's KeyPackage is missing from the queue, so his removal cannot ride along.
        let (removals, adds) = plan_membership(
            &leaves,
            &["alice-d".into(), "bob-d".into(), "gone-d".into(), "legacy".into()],
            vec![("alice-d".into(), b"not a key package".to_vec())],
            &ourselves,
            &rules,
        );
        assert!(adds.is_empty(), "an unparseable KeyPackage is never added");
        assert_eq!(removals, vec!["gone-d".to_string(), "legacy".to_string()]);
        assert_eq!(stale_leaves(&leaves, "owner-d", &rules), vec!["gone-d".to_string(), "legacy".to_string()]);
    }
}
