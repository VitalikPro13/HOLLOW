//! FFI for the device-proof recovery screens (DEVICE_PROOF_DESIGN sections 8.3, 8.4 and
//! 8.8): the owner's review of a member's lost device, the restore chooser after a
//! phrase recovery, and a member's view of a server being restored.

use flutter_rust_bridge::frb;

/// The group a review item shows under (appendix A).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefoldGroup {
    Removed,
    LetIn,
    Roles,
    Mutes,
    SeeOrPost,
    Joining,
    Things,
    Other,
}

/// What a review item undoes, one per sentence of appendix A.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefoldItemKind {
    Banned,
    Removed,
    Muted,
    Joined,
    Left,
    RoleChanged,
    RolePermissions,
    Nickname,
    StoppedPublic,
    MadePublic,
    AccessRules,
    AccessLost,
    AccessGiven,
    JoinRules,
    ChannelDeleted,
    ChannelCreated,
    LabelChanged,
    LabelDeleted,
    Other,
}

/// One change the owner decides on. `key` goes back in `answer_refold_review`'s `chosen`.
/// `target` is the master id the item is about; `role` the role an undo brings a member
/// back as (above member only) or the role a member became, `old_role` the one before;
/// `opens` = undoing it lets more people see, post or join. The `*_name` fields are the
/// names as the op held them when the item was listed (a deleted channel or label keeps
/// its name here; `target_name` = the member's nickname or master-signed card name).
#[derive(Debug, Clone)]
pub struct RefoldItem {
    pub key: String,
    pub group: RefoldGroup,
    pub kind: RefoldItemKind,
    pub target: Option<String>,
    pub channel_id: Option<String>,
    pub label_id: Option<String>,
    pub role: Option<String>,
    pub old_role: Option<String>,
    pub opens: bool,
    pub channel_name: Option<String>,
    pub label_name: Option<String>,
    pub role_name: Option<String>,
    pub target_name: Option<String>,
}

/// How a review was answered, as every owner device shows it.
#[derive(Debug, Clone)]
pub struct RefoldAnswered {
    /// The answering owner device.
    pub by_device: String,
    /// Closed after 30 days with no answer.
    pub timeout: bool,
    /// Item keys (put-back channels as their channel ids) the owner's next checkpoint
    /// undid, and the ones it kept; filled once that checkpoint applied the answer.
    pub undone: Vec<String>,
    pub kept: Vec<String>,
}

/// What happened to one chosen item or put-back channel (`key` = item key or channel id).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefoldOutcome {
    Applied,
    /// "Someone changed this since, so it stays".
    ChangedSince,
}

#[derive(Debug, Clone)]
pub struct RefoldItemOutcome {
    pub key: String,
    pub outcome: RefoldOutcome,
}

/// `answer_refold_review`'s result: one entry per chosen item and per put-back channel, in
/// the order given; "Keep all" returns both empty.
#[derive(Debug, Clone)]
pub struct RefoldApplied {
    pub items: Vec<RefoldItemOutcome>,
    pub put_back: Vec<RefoldItemOutcome>,
}

/// One member's lost device whose changes need the owner (section 8.3). `listed` false =
/// waiting for a slot (no items yet). `unpublished` = channels already made not public
/// ("Already undone", each with Put back). `more_items` = items that come up after these
/// are answered (`below` names this part of the list).
#[derive(Debug, Clone)]
pub struct RefoldReview {
    pub member: String,
    pub device: String,
    pub dr: String,
    pub below: Option<String>,
    pub listed: bool,
    pub opened_ms: Option<i64>,
    pub unpublished: Vec<String>,
    pub items: Vec<RefoldItem>,
    pub more_items: u32,
    pub answered: Option<RefoldAnswered>,
}

/// Every review of one server for the owner, and how many more reports wait.
#[derive(Debug, Clone)]
pub struct RefoldReviews {
    pub reviews: Vec<RefoldReview>,
    pub more_reports: u32,
}

/// The owner's reviews in `server_id` (empty for anyone else).
#[frb]
pub fn refold_reviews(server_id: String) -> Result<RefoldReviews, String> {
    let (reply, rx) = tokio::sync::oneshot::channel();
    send_command(crate::node::NodeCommand::RefoldReviews { server_id, reply })?;
    super::network::get_runtime().block_on(rx).map_err(|_| "Hollow stopped.".to_string())?
}

#[frb]
pub fn answer_refold_review(
    server_id: String,
    member: String,
    device: String,
    below: Option<String>,
    chosen: Vec<String>,
    put_back: Vec<String>,
) -> Result<RefoldApplied, String> {
    let below = match below {
        Some(b) => Some(serde_json::from_str(&b).map_err(|_| "This report is no longer open.".to_string())?),
        None => None,
    };
    let (reply, rx) = tokio::sync::oneshot::channel();
    send_command(crate::node::NodeCommand::AnswerRefold { server_id, member, device, below, chosen, put_back, reply })?;
    let (items, backs) = super::network::get_runtime().block_on(rx).map_err(|_| "Hollow stopped.".to_string())??;
    let outcome = |(key, ok): (String, bool)| RefoldItemOutcome { key, outcome: if ok { RefoldOutcome::Applied } else { RefoldOutcome::ChangedSince } };
    Ok(RefoldApplied { items: items.into_iter().map(outcome).collect(), put_back: backs.into_iter().map(outcome).collect() })
}

fn send_command(cmd: crate::node::NodeCommand) -> Result<(), String> {
    let node = super::network::get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Hollow is not connected yet.")?.cmd_tx.clone();
    drop(guard);
    super::network::get_runtime().block_on(cmd_tx.send(cmd)).map_err(|_| "Hollow is not connected yet.".to_string())
}

/// The owner's review lists of one server as its screens show them (appendix A): the
/// listed entries and the answered ones; waiting entries are counted in `more_reports`.
pub(crate) fn reviews_of(state: &crate::crdt::server_state::ServerState, me: &str) -> RefoldReviews {
    let sid = state.server_id.as_str();
    let mut reviews = Vec::new();
    let mut more_reports = 0u32;
    for s in state.refold_shown(me) {
        let e = &s.entry;
        let answer = e.valid_answer(sid);
        if e.opened.is_none() && answer.is_none() {
            more_reports += 1;
            continue;
        }
        reviews.push(RefoldReview {
            member: e.member.clone(),
            device: e.device.clone(),
            dr: e.dr.clone(),
            below: e.below.as_ref().and_then(|b| serde_json::to_string(b).ok()),
            listed: e.opened.is_some(),
            opened_ms: e.opened.as_ref().and_then(|o| i64::try_from(o.physical_ms).ok()),
            unpublished: s.unpublished.clone(),
            items: s.items.iter().map(|i| item_of(state, i)).collect(),
            more_items: 0,
            answered: answer.map(|a| RefoldAnswered { by_device: a.by.clone(), timeout: a.timeout, undone: a.undone.clone(), kept: a.kept.clone() }),
        });
    }
    RefoldReviews { reviews, more_reports }
}

fn item_of(state: &crate::crdt::server_state::ServerState, i: &crate::crdt::refold_write::ShownItem) -> RefoldItem {
    use crate::crdt::refold::{ChannelField as F, ElementKey as K};
    use RefoldGroup as G;
    use RefoldItemKind as T;
    let target = i.key.target().map(str::to_string);
    let (mut channel_id, mut label_id, mut role) = (None, None, None);
    let (group, kind) = match &i.key {
        K::Ban(_) => (G::Removed, T::Banned),
        K::Remove(_) => (G::Removed, T::Removed),
        K::Leave(_) => (G::Removed, T::Left),
        K::Admit(_) => (G::LetIn, T::Joined),
        K::Mute(_) => (G::Mutes, T::Muted),
        K::Role(_) => {
            role = i.r_role.as_ref().map(|r| r.as_str().to_string());
            (G::Roles, T::RoleChanged)
        }
        K::RolePerms(r) => {
            role = Some(r.clone());
            (G::Roles, T::RolePermissions)
        }
        K::Nickname(_) => (G::Other, T::Nickname),
        K::Grant(c, _) => {
            channel_id = Some(c.clone());
            (G::SeeOrPost, if i.opens { T::AccessLost } else { T::AccessGiven })
        }
        K::Assigned(_, l) => {
            label_id = Some(l.clone());
            (G::SeeOrPost, if i.opens { T::AccessLost } else { T::AccessGiven })
        }
        K::ChannelPublic(c) => {
            channel_id = Some(c.clone());
            (G::SeeOrPost, if i.opens { T::StoppedPublic } else { T::MadePublic })
        }
        K::ChannelField(c, F::Visibility | F::VisLabels | F::Posting | F::PostLabels) => {
            channel_id = Some(c.clone());
            (G::SeeOrPost, T::AccessRules)
        }
        K::LabelFields(l) => {
            label_id = Some(l.clone());
            (G::SeeOrPost, T::LabelChanged)
        }
        K::ChannelExist(c) => {
            channel_id = Some(c.clone());
            (G::Things, if state.channels.contains_key(c) { T::ChannelCreated } else { T::ChannelDeleted })
        }
        K::LabelExist(l) => {
            label_id = Some(l.clone());
            (G::Things, if state.labels.contains_key(l) { T::Other } else { T::LabelDeleted })
        }
        K::Setting(k) if k == "is_private" || k == "max_members" || k.starts_with("twitch_") => (G::Joining, T::JoinRules),
        K::JoinSecret => (G::Joining, T::JoinRules),
        K::Emote(_) | K::Sticker(_) => (G::Things, T::Other),
        K::ChannelField(c, _) => {
            channel_id = Some(c.clone());
            (G::Other, T::Other)
        }
        _ => (G::Other, T::Other),
    };
    let old_role = match &i.key {
        K::Role(m) => Some(state.get_role(m).as_str().to_string()),
        _ => None,
    };
    let target_name = target.as_deref().and_then(|m| {
        state.nicknames.get(m).map(|n| n.read().clone()).filter(|n| !n.is_empty()).or_else(|| state.members.get(m).map(|x| x.display_name.clone()))
    });
    RefoldItem {
        key: i.raw.clone(),
        group,
        kind,
        target,
        channel_id,
        label_id,
        role_name: role.clone(),
        role,
        old_role,
        opens: i.opens,
        channel_name: i.channel_name.clone(),
        label_name: i.label_name.clone(),
        target_name,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RestoreStage {
    /// Checking with members.
    Checking,
    /// Still waiting for more answers (the wait).
    Waiting,
    /// One clear answer: `pick`.
    Pick,
    /// No single clear answer: choose among `points`.
    Points,
    /// Too few members answered: `points` has the one named point.
    OnlyOne,
    /// No member reachable; Hollow asks again when they are online.
    NobodyReachable,
    /// Restored, or this device holds the server and settles it itself.
    Done,
}

/// A point a server can be restored to. `date_ms` None = before the 0.14 update.
/// `named_by` = master ids of the members who named it (the screen names the first two
/// and counts the rest); `named_by_names` = each one's master-signed card name where one
/// is held, same length and order.
#[derive(Debug, Clone)]
pub struct RestorePoint {
    pub cp: String,
    pub date_ms: Option<i64>,
    pub named_by: Vec<String>,
    pub named_by_names: Vec<Option<String>>,
}

#[derive(Debug, Clone)]
pub struct RestoreChoices {
    pub server_id: String,
    pub stage: RestoreStage,
    pub pick: Option<RestorePoint>,
    pub points: Vec<RestorePoint>,
}

/// Every server this device is restoring after a phrase recovery. Empty with
/// `servers_known` false = "Hollow doesn't know your servers yet".
#[derive(Debug, Clone)]
pub struct Restores {
    pub servers_known: bool,
    pub servers: Vec<RestoreChoices>,
}

/// The restore chooser's state. Poll it every 2 s while the screen is open.
#[frb]
pub fn restore_choices() -> Result<Restores, String> {
    use crate::node::witness::Stage;
    let point = |p: crate::node::restore_flow::PointSnap| RestorePoint {
        cp: p.cp,
        date_ms: p.date_ms,
        named_by: p.named_by,
        named_by_names: p.named_by_names,
    };
    let servers: Vec<RestoreChoices> = crate::node::restore_flow::snapshot()
        .into_iter()
        .map(|s| RestoreChoices {
            server_id: s.server_id,
            stage: match s.stage {
                Stage::Checking => RestoreStage::Checking,
                Stage::Waiting => RestoreStage::Waiting,
                Stage::Pick => RestoreStage::Pick,
                Stage::Points => RestoreStage::Points,
                Stage::OnlyOne => RestoreStage::OnlyOne,
                Stage::NobodyReachable => RestoreStage::NobodyReachable,
                Stage::Done => RestoreStage::Done,
            },
            pick: s.pick.map(point),
            points: s.points.into_iter().map(point).collect(),
        })
        .collect();
    Ok(Restores { servers_known: !servers.is_empty(), servers })
}

/// Restore `server_id` to the checkpoint `cp`; `None` = "I don't know".
#[frb]
pub fn choose_restore(server_id: String, cp: Option<String>) -> Result<(), String> {
    let node = super::network::get_node();
    let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let cmd_tx = guard.as_ref().ok_or("Hollow is not connected yet.")?.cmd_tx.clone();
    drop(guard);
    let (reply, rx) = tokio::sync::oneshot::channel();
    super::network::get_runtime().block_on(async move {
        cmd_tx
            .send(crate::node::NodeCommand::ChooseRestore { server_id, cp, reply })
            .await
            .map_err(|_| "Hollow is not connected yet.".to_string())?;
        rx.await.map_err(|_| "Hollow stopped before the restore began.".to_string())?
    })
}

/// A member's view of a server whose owner is restoring it (section 8.8).
/// `stepped_back` = the banner "The owner of {server} is restoring it" (never while a
/// floor holds it); `removed_by` = this member was kicked meanwhile (the shell banner).
#[derive(Debug, Clone)]
pub struct ServerRecovery {
    pub stepped_back: bool,
    pub removed_by: Option<String>,
}

/// Refresh on `ServerUpdated` for the server.
#[frb]
pub fn server_recovery(server_id: String) -> Result<ServerRecovery, String> {
    let snap = crate::node::floor::snapshot(&server_id);
    Ok(ServerRecovery { stepped_back: snap.stepped_back, removed_by: snap.removed_by })
}
