//! When the base already decided an op: every element it writes carries a base stamp at or
//! after the op's clock, or the op falls outside its target's window, or the base's member
//! record holds the very event. Such an op drops at the door; any other one folds on top
//! of the base at its own clock (`crdt::fold`). One exhaustive match, so a new payload
//! does not compile until it is classified.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use super::hlc::HlcTimestamp;
use super::members::{self, MemberEvent};
use super::operations::{CrdtOp, CrdtPayload as P};
use super::server_state::{parse_visibility, ChannelVisibility, ServerState};

type Stamp = Option<HlcTimestamp>;

/// The clock of the newest write to every element the LWW registers do not already date,
/// tombstones included. Carried by checkpoints; never shrinks.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stamps {
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub channels: HashMap<String, ChannelStamps>,
    /// channel -> message -> newest pin or unpin.
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub pins: HashMap<String, HashMap<String, HlcTimestamp>>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub labels: HashMap<String, LabelStamps>,
    /// member -> label -> newest assignment or unassignment.
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub assigned: HashMap<String, HashMap<String, HlcTimestamp>>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub emotes: HashMap<String, HlcTimestamp>,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub stickers: HashMap<String, HlcTimestamp>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout: Stamp,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChannelStamps {
    /// The add that made the channel as it stands: a field write before it is moot.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created: Stamp,
    /// Newest add or remove.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exist: Stamp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Stamp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub posting: Stamp,
    /// `is_public`, which both visibility arms write too (HOL-SEC-094).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub public: Stamp,
    /// The newest `ChannelPublicChanged` that landed, and each visibility field's
    /// newest write before it: whether a late restriction spanned that write.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub set: Stamp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub set_vis: Stamp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub set_labels: Stamp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub visibility: Stamp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vis_labels: Stamp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub post_labels: Stamp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub slow: Stamp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub media: Stamp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub voice: Stamp,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LabelStamps {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created: Stamp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exist: Stamp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fields: Stamp,
}

impl Stamps {
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }

    pub(crate) fn clamp(&mut self, max_ms: u64) -> usize {
        let mut n = 0;
        let mut one = |s: &mut HlcTimestamp| {
            if s.physical_ms > max_ms {
                s.physical_ms = max_ms;
                n += 1;
            }
        };
        for c in self.channels.values_mut() {
            for s in [
                &mut c.created, &mut c.exist, &mut c.name, &mut c.posting, &mut c.public, &mut c.set, &mut c.set_vis,
                &mut c.set_labels, &mut c.visibility, &mut c.vis_labels, &mut c.post_labels, &mut c.slow, &mut c.media,
                &mut c.voice,
            ]
            .into_iter()
            .flatten()
            {
                one(s);
            }
        }
        for l in self.labels.values_mut() {
            for s in [&mut l.created, &mut l.exist, &mut l.fields].into_iter().flatten() {
                one(s);
            }
        }
        for m in self.pins.values_mut().chain(self.assigned.values_mut()) {
            m.values_mut().for_each(&mut one);
        }
        self.emotes.values_mut().chain(self.stickers.values_mut()).for_each(&mut one);
        if let Some(s) = self.layout.as_mut() {
            one(s);
        }
        n
    }
}

/// Whether `at` is newer than `stamp` (a write there still changes something).
pub(crate) fn newer(stamp: &Stamp, at: &HlcTimestamp) -> bool {
    stamp.as_ref().is_none_or(|s| at > s)
}

/// Raise `stamp` to `at`.
pub(crate) fn raise(stamp: &mut Stamp, at: &HlcTimestamp) {
    if newer(stamp, at) {
        *stamp = Some(at.clone());
    }
}

fn covered(stamp: &Stamp, at: &HlcTimestamp) -> bool {
    !newer(stamp, at)
}

/// A checkpoint's state as the base of a fold: what it decided, and how it dates it.
pub(crate) struct Judge<'a> {
    pub state: &'a ServerState,
    /// A checkpoint from before 0.14 carries no stamps: everything at or below its
    /// `covers` is decided, exactly 0.13's rule, applied once.
    pub covers: Option<&'a HlcTimestamp>,
    /// What an unstamped ancestor decided (`ServerState::cp_floor`): every op at or
    /// below it, as `covers` above.
    pub floor: Option<&'a HlcTimestamp>,
    /// The base's parent's `cp_retired`: a retire either lists is decided (section 8.2).
    pub parent_retired: &'a [String],
}

/// Whether a floor decides `payload` once it is dated at or below it: anything but the
/// founding op, a checkpoint and a deletion, which have rules of their own.
pub(crate) fn below_floor_counts(payload: &P) -> bool {
    !matches!(payload, P::ServerCreated { .. } | P::ServerCheckpoint { .. } | P::ServerDeleted { .. })
}

impl Judge<'_> {
    /// Whether the base decides `op`. The founding op of a self-certifying id and a
    /// deletion are never decided; checkpoints are ordered by `crdt::fold`, not here.
    pub fn dominates(&self, op: &CrdtOp, genesis: bool) -> bool {
        let at = &op.hlc;
        if let Some(covers) = self.covers {
            return match &op.payload {
                P::ServerCreated { .. } => !genesis,
                P::ServerDeleted { .. } | P::ServerCheckpoint { .. } => false,
                _ => at <= covers,
            };
        }
        if self.floor.is_some_and(|f| at <= f) && below_floor_counts(&op.payload) {
            return true;
        }
        let s = self.state;
        let reg_at = |r: Option<&HlcTimestamp>| r.is_some_and(|h| h >= at);
        match &op.payload {
            P::ServerCreated { .. } => !genesis,
            P::ServerCheckpoint { .. } | P::ServerDeleted { .. } => false,
            P::ServerRenamed { .. } => s.name.hlc() >= at,
            P::ServerSettingChanged { key, .. } => reg_at(s.settings.get(key).map(|r| r.hlc())),
            P::JoinKeySet { .. } => reg_at(s.join_secret.as_ref().map(|r| r.hlc())),
            P::RolePermissionsChanged { role, .. } => reg_at(s.role_permissions.get(role).map(|r| r.hlc())),
            P::MemberMuted { peer_id, .. } | P::MemberUnmuted { peer_id } => {
                reg_at(s.muted_members.get(peer_id).map(|r| r.hlc()))
            }
            P::ChannelGrantSet { channel_id, peer_id, .. } | P::ChannelGrantRevoked { channel_id, peer_id } => {
                reg_at(s.channel_grants.get(channel_id).and_then(|m| m.get(peer_id)).map(|r| r.hlc()))
            }
            P::MemberUnbanned { peer_id } => reg_at(s.banned_members.get(peer_id).map(|r| r.hlc())),
            P::MemberBanned { peer_id, .. } => {
                reg_at(s.banned_members.get(peer_id).map(|r| r.hlc()))
                    && self.holds_event(peer_id, &MemberEvent::Remove { at: at.clone() })
            }
            P::MemberAdded { peer_id, display_name, ask, .. } => {
                let ask = ask.as_ref().map_or(members::LEGACY_ASK, |a| a.at);
                let e = MemberEvent::Admit { at: at.clone(), by: op.author.clone(), ask, name: display_name.clone() };
                self.holds_event(peer_id, &e)
            }
            P::MemberRemoved { peer_id, .. } => {
                let e = if *peer_id == op.author {
                    MemberEvent::Leave { at: at.clone() }
                } else {
                    MemberEvent::Remove { at: at.clone() }
                };
                self.holds_event(peer_id, &e)
            }
            P::RoleChanged { peer_id, .. } => {
                reg_at(s.roles.get(peer_id).map(|r| r.hlc())) || self.before_window(peer_id, at)
            }
            P::NicknameChanged { peer_id, .. } => {
                reg_at(s.nicknames.get(peer_id).map(|r| r.hlc())) || self.before_window(peer_id, at)
            }
            P::TwitchUsernameChanged { peer_id, .. } => {
                reg_at(s.twitch_usernames.get(peer_id).map(|r| r.hlc())) || self.before_window(peer_id, at)
            }
            P::StoragePledgeChanged { peer_id, .. } => {
                reg_at(s.storage_pledges.get(peer_id).map(|r| r.hlc())) || self.before_window(peer_id, at)
            }
            P::ChannelAdded { channel_id, .. } | P::ChannelRemoved { channel_id } => {
                covered(&self.channel(channel_id, |c| &c.exist), at)
            }
            P::ChannelRenamed { channel_id, .. } => self.channel_field(channel_id, at, |c| &c.name),
            P::ChannelPostingChanged { channel_id, .. } => self.channel_field(channel_id, at, |c| &c.posting),
            P::ChannelSlowModeChanged { channel_id, .. } => self.channel_field(channel_id, at, |c| &c.slow),
            P::ChannelMediaOnlyChanged { channel_id, .. } => self.channel_field(channel_id, at, |c| &c.media),
            P::ChannelVoiceChatChanged { channel_id, .. } => self.channel_field(channel_id, at, |c| &c.voice),
            P::ChannelPostingLabelsChanged { channel_id, .. } => self.channel_field(channel_id, at, |c| &c.post_labels),
            P::ChannelPublicChanged { channel_id, .. } => self.channel_field(channel_id, at, |c| &c.public),
            P::ChannelVisibilityChanged { channel_id, visibility } => {
                self.channel_field(channel_id, at, |c| &c.visibility)
                    && self.channel_field(channel_id, at, |c| &c.public)
                    && !s.late_restriction_closes(channel_id, parse_visibility(visibility) != ChannelVisibility::Everyone, false, at)
            }
            P::ChannelVisibilityLabelsChanged { channel_id, labels } => {
                self.channel_field(channel_id, at, |c| &c.vis_labels)
                    && self.channel_field(channel_id, at, |c| &c.public)
                    && !s.late_restriction_closes(channel_id, !labels.is_empty(), true, at)
            }
            P::ChannelLayoutUpdated { .. } => covered(&s.stamps.layout, at),
            P::MessagePinned { channel_id, message_id } | P::MessageUnpinned { channel_id, message_id } => {
                reg_at(s.stamps.pins.get(channel_id).and_then(|m| m.get(message_id)))
            }
            P::LabelCreated { label_id, .. } | P::LabelDeleted { label_id } => {
                covered(&self.label(label_id, |l| &l.exist), at)
            }
            P::LabelUpdated { label_id, .. } => s.stamps.labels.get(label_id).is_some_and(|l| {
                covered(&l.fields, at)
                    || l.created.as_ref().is_some_and(|c| c > at)
                    || covered(&l.exist, at) && !s.labels.contains_key(label_id)
            }),
            P::LabelAssigned { label_id, peer_id } | P::LabelUnassigned { label_id, peer_id } => {
                reg_at(s.stamps.assigned.get(peer_id).and_then(|m| m.get(label_id)))
                    || covered(&self.label(label_id, |l| &l.exist), at)
            }
            P::EmojiAdded { name, .. } | P::EmojiRemoved { name } => reg_at(s.stamps.emotes.get(name)),
            P::StickerAdded { hash, .. } | P::StickerRemoved { hash } => reg_at(s.stamps.stickers.get(hash)),
            P::JoinLock { link, door, grants } => s.join_lock.decides(link, door.as_ref(), grants, at),
            P::SettleSign { .. } => false,
            P::FloorMark { .. } => false,
            P::DeviceRetired { .. } => {
                let id = hex::encode(op.content_hash());
                s.cp_retired.contains(&id) || self.parent_retired.contains(&id)
            }
        }
    }

    fn holds_event(&self, master: &str, e: &MemberEvent) -> bool {
        members::holds(&self.state.events_of(master), e)
    }

    /// A per-member register write dated before the member's current span, or while it
    /// is out after a span that ended later: a removal or re-admission voided it.
    fn before_window(&self, master: &str, at: &HlcTimestamp) -> bool {
        let Some(last) = self.state.member_record.get(master).and_then(|s| s.last()) else { return false };
        let from = last.from_hlc.clone().unwrap_or(HlcTimestamp { physical_ms: last.from_ms, counter: 0, actor: String::new() });
        if last.until_ms == u64::MAX {
            return *at < from;
        }
        let until = last.until_hlc.clone().unwrap_or(HlcTimestamp { physical_ms: last.until_ms, counter: 0, actor: String::new() });
        *at < until
    }

    fn channel(&self, id: &str, f: impl Fn(&ChannelStamps) -> &Stamp) -> Stamp {
        self.state.stamps.channels.get(id).and_then(|c| f(c).clone())
    }

    /// A channel field: its own stamp, or the channel was made again or removed after.
    fn channel_field(&self, id: &str, at: &HlcTimestamp, f: impl Fn(&ChannelStamps) -> &Stamp) -> bool {
        let Some(c) = self.state.stamps.channels.get(id) else { return false };
        covered(f(c), at) || c.created.as_ref().is_some_and(|m| m > at) || covered(&c.exist, at) && !self.state.channels.contains_key(id)
    }

    fn label(&self, id: &str, f: impl Fn(&LabelStamps) -> &Stamp) -> Stamp {
        self.state.stamps.labels.get(id).and_then(|l| f(l).clone())
    }
}
