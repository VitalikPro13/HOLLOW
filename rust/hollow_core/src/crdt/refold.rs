//! The owner re-fold (DEVICE_PROOF_DESIGN section 8.3, decisions 20 and 21): what a
//! member's lost-or-stolen device wrote after T that an owner checkpoint already folded.
//! Only that device's own HLC lane is ever reverted; what the member could write again
//! itself reverts at once (AUTO), a channel the lane made public after T goes back to
//! not public (UNPUBLISH), and everything else waits for the owner's answer (REVIEW).

use std::collections::{BTreeSet, HashMap};

use base64::Engine as _;
use serde::{Deserialize, Serialize};

use super::hlc::{lane_of, HlcTimestamp, LANES};
use super::members::MemberEvent;
use super::operations::{CrdtOp, CrdtPayload, OpRef};
use super::server_state::{ChannelInfo, ServerState};
use crate::identity::native_identity::NativeKeypair;

/// Settings a member may have the re-fold put back without the owner (decision 20).
pub const AUTO_SETTINGS: [&str; 7] =
    ["server_avatar", "server_banner", "description", "is_nsfw", "max_file_size_mb", "relay_catchup_secs", "voice_text_chat"];
/// REVIEW items one entry lists; the rest open as continuation entries.
pub const MAX_REVIEW: usize = 256;
/// Unpublish records one entry carries.
pub const MAX_UNPUBLISHED: usize = 64;
/// Entries listed at once per server, one per DR author.
pub const MAX_LISTED: usize = 8;
/// Unanswered entries one server keeps.
pub const MAX_UNANSWERED: usize = 256;
/// Entries one checkpoint carries.
pub const MAX_ENTRIES: usize = 1024;
/// A listed entry closes as kept this long after it opened (owner clocks).
pub const LISTED_TIMEOUT_MS: u64 = 30 * 24 * 3600 * 1000;
/// R is never older than what this owner device first folded within this window.
pub const R_REACH_MS: u64 = 30 * 24 * 3600 * 1000;

/// A field of a channel the re-fold can revert alone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChannelField {
    Name,
    Posting,
    Visibility,
    VisLabels,
    PostLabels,
    Slow,
    Media,
    Voice,
}

/// One unit of server state one write lands on. Its JSON is an item's `key`.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ElementKey {
    Name,
    Setting(String),
    Role(String),
    RolePerms(String),
    Nickname(String),
    Twitch(String),
    Pledge(String),
    /// A ban: its register and the `Remove` event it wrote at the same stamp.
    Ban(String),
    Mute(String),
    /// (channel, member).
    Grant(String, String),
    JoinSecret,
    /// A channel's existence with its sub-stamps.
    ChannelExist(String),
    ChannelField(String, ChannelField),
    /// `public`, `set`, `set_vis`, `set_labels`: what one `ChannelPublicChanged` writes.
    ChannelPublic(String),
    /// (channel, message).
    Pin(String, String),
    LabelExist(String),
    LabelFields(String),
    /// (member, label).
    Assigned(String, String),
    Emote(String),
    Sticker(String),
    Layout,
    /// A membership event of a member; the item's stamp is the event's `at`.
    Admit(String),
    Leave(String),
    Remove(String),
}

impl ElementKey {
    pub fn to_key(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }

    pub fn from_key(key: &str) -> Option<Self> {
        serde_json::from_str(key).ok()
    }

    /// The member a membership or per-member element names.
    pub fn target(&self) -> Option<&str> {
        match self {
            Self::Role(m) | Self::Nickname(m) | Self::Twitch(m) | Self::Pledge(m) | Self::Ban(m) | Self::Mute(m) => Some(m),
            Self::Grant(_, m) | Self::Assigned(m, _) | Self::Admit(m) | Self::Leave(m) | Self::Remove(m) => Some(m),
            _ => None,
        }
    }
}

/// How one dropped-lane write is undone (decision 20, option (c); decision 21).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefoldClass {
    Auto,
    Unpublish,
    Review,
}

/// Whether a payload writes anything a re-fold could revert. Exhaustive on purpose: a new
/// variant fails to compile until it is classed here and in [`refold_class`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PayloadKind {
    Excluded,
    Writes,
}

pub fn payload_kind(p: &CrdtPayload) -> PayloadKind {
    use CrdtPayload as P;
    match p {
        P::ServerCreated { .. }
        | P::ServerCheckpoint { .. }
        | P::JoinKeySet { .. }
        | P::ServerDeleted { .. }
        | P::JoinLock { .. }
        | P::DeviceRetired { .. }
        | P::FloorMark { .. }
        | P::SettleSign { .. } => PayloadKind::Excluded,
        P::ServerRenamed { .. }
        | P::ServerSettingChanged { .. }
        | P::ChannelAdded { .. }
        | P::ChannelRemoved { .. }
        | P::ChannelRenamed { .. }
        | P::MemberAdded { .. }
        | P::MemberRemoved { .. }
        | P::RoleChanged { .. }
        | P::NicknameChanged { .. }
        | P::TwitchUsernameChanged { .. }
        | P::ChannelLayoutUpdated { .. }
        | P::MessagePinned { .. }
        | P::MessageUnpinned { .. }
        | P::StoragePledgeChanged { .. }
        | P::RolePermissionsChanged { .. }
        | P::LabelCreated { .. }
        | P::LabelDeleted { .. }
        | P::LabelUpdated { .. }
        | P::LabelAssigned { .. }
        | P::LabelUnassigned { .. }
        | P::ChannelVisibilityChanged { .. }
        | P::ChannelPostingChanged { .. }
        | P::ChannelPublicChanged { .. }
        | P::ChannelVisibilityLabelsChanged { .. }
        | P::ChannelPostingLabelsChanged { .. }
        | P::ChannelGrantSet { .. }
        | P::ChannelGrantRevoked { .. }
        | P::MemberBanned { .. }
        | P::MemberUnbanned { .. }
        | P::MemberMuted { .. }
        | P::MemberUnmuted { .. }
        | P::ChannelSlowModeChanged { .. }
        | P::ChannelMediaOnlyChanged { .. }
        | P::ChannelVoiceChatChanged { .. }
        | P::EmojiAdded { .. }
        | P::EmojiRemoved { .. }
        | P::StickerAdded { .. }
        | P::StickerRemoved { .. } => PayloadKind::Writes,
    }
}

/// One write of the dropped lane the base still carries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaneWrite {
    pub key: ElementKey,
    pub stamp: HlcTimestamp,
}

/// The dropped lane: the member's own stamps in `device`'s counter lane, minus the
/// ops its DR names (those it vouches for).
pub struct Lane<'a> {
    pub member: &'a str,
    lane: u32,
    named: BTreeSet<(u64, u32)>,
}

impl<'a> Lane<'a> {
    pub fn new(member: &'a str, device: &str, named: &[OpRef]) -> Self {
        Self { member, lane: lane_of(device), named: named.iter().map(|r| (r.ms, r.c)).collect() }
    }

    pub fn holds(&self, s: &HlcTimestamp) -> bool {
        s.actor == self.member && s.counter % LANES == self.lane && !self.named.contains(&(s.physical_ms, s.counter))
    }
}

/// R's stamp for a `Stamps` element R holds: its own, or `covers` for a 0.13-shaped R.
fn r_stamp(r: &ServerState, r_covers: &HlcTimestamp, own: Option<&HlcTimestamp>, held: bool) -> Option<HlcTimestamp> {
    if r.cp_stamped {
        own.cloned()
    } else {
        held.then(|| r_covers.clone())
    }
}

/// Every write of `lane` that wins its element in `base` and is newer than R's stamp for
/// it (or R lacks the element), newest first (section 8.3, "The dropped lane's writes").
pub fn lane_writes(base: &ServerState, r: &ServerState, r_covers: &HlcTimestamp, lane: &Lane<'_>) -> Vec<LaneWrite> {
    let mut out: Vec<LaneWrite> = Vec::new();
    let mut take = |key: ElementKey, s: Option<&HlcTimestamp>, r_s: Option<HlcTimestamp>| {
        if let Some(s) = s
            && lane.holds(s)
            && r_s.as_ref().is_none_or(|rs| s > rs)
        {
            out.push(LaneWrite { key, stamp: s.clone() });
        }
    };
    take(ElementKey::Name, Some(base.name.hlc()), Some(r.name.hlc().clone()));
    macro_rules! regs {
        ($field:ident, $key:expr) => {
            for (k, reg) in &base.$field {
                take($key(k.clone()), Some(reg.hlc()), r.$field.get(k).map(|x| x.hlc().clone()));
            }
        };
    }
    regs!(settings, ElementKey::Setting);
    regs!(roles, ElementKey::Role);
    regs!(role_permissions, ElementKey::RolePerms);
    regs!(nicknames, ElementKey::Nickname);
    regs!(twitch_usernames, ElementKey::Twitch);
    regs!(storage_pledges, ElementKey::Pledge);
    regs!(banned_members, ElementKey::Ban);
    regs!(muted_members, ElementKey::Mute);
    for (c, per) in &base.channel_grants {
        for (m, reg) in per {
            take(ElementKey::Grant(c.clone(), m.clone()), Some(reg.hlc()), r.channel_grants.get(c).and_then(|p| p.get(m)).map(|x| x.hlc().clone()));
        }
    }
    if let Some(js) = &base.join_secret {
        take(ElementKey::JoinSecret, Some(js.hlc()), r.join_secret.as_ref().map(|x| x.hlc().clone()));
    }
    let (bs, rs) = (&base.stamps, &r.stamps);
    for (c, st) in &bs.channels {
        let rc = rs.channels.get(c);
        let held = r.channels.contains_key(c);
        let rst = |f: fn(&super::dominance::ChannelStamps) -> &Option<HlcTimestamp>| r_stamp(r, r_covers, rc.and_then(|x| f(x).as_ref()), held);
        take(ElementKey::ChannelExist(c.clone()), st.exist.as_ref(), rst(|x| &x.exist));
        take(ElementKey::ChannelPublic(c.clone()), st.public.as_ref(), rst(|x| &x.public));
        for (f, s, rf) in [
            (ChannelField::Name, &st.name, (|x: &super::dominance::ChannelStamps| &x.name) as fn(&super::dominance::ChannelStamps) -> &Option<HlcTimestamp>),
            (ChannelField::Posting, &st.posting, |x| &x.posting),
            (ChannelField::Visibility, &st.visibility, |x| &x.visibility),
            (ChannelField::VisLabels, &st.vis_labels, |x| &x.vis_labels),
            (ChannelField::PostLabels, &st.post_labels, |x| &x.post_labels),
            (ChannelField::Slow, &st.slow, |x| &x.slow),
            (ChannelField::Media, &st.media, |x| &x.media),
            (ChannelField::Voice, &st.voice, |x| &x.voice),
        ] {
            take(ElementKey::ChannelField(c.clone(), f), s.as_ref(), rst(rf));
        }
    }
    for (c, msgs) in &bs.pins {
        for (msg, s) in msgs {
            let held = r.pinned_messages.get(c).is_some_and(|v| v.contains(msg));
            take(ElementKey::Pin(c.clone(), msg.clone()), Some(s), r_stamp(r, r_covers, rs.pins.get(c).and_then(|x| x.get(msg)), held));
        }
    }
    for (l, st) in &bs.labels {
        let rl = rs.labels.get(l);
        let held = r.labels.contains_key(l);
        take(ElementKey::LabelExist(l.clone()), st.exist.as_ref(), r_stamp(r, r_covers, rl.and_then(|x| x.exist.as_ref()), held));
        take(ElementKey::LabelFields(l.clone()), st.fields.as_ref(), r_stamp(r, r_covers, rl.and_then(|x| x.fields.as_ref()), held));
    }
    for (m, per) in &bs.assigned {
        for (l, s) in per {
            let held = r.label_assignments.get(m).is_some_and(|v| v.contains(l));
            take(ElementKey::Assigned(m.clone(), l.clone()), Some(s), r_stamp(r, r_covers, rs.assigned.get(m).and_then(|x| x.get(l)), held));
        }
    }
    for (e, s) in &bs.emotes {
        take(ElementKey::Emote(e.clone()), Some(s), r_stamp(r, r_covers, rs.emotes.get(e), r.emotes.contains_key(e)));
    }
    for (h, s) in &bs.stickers {
        take(ElementKey::Sticker(h.clone()), Some(s), r_stamp(r, r_covers, rs.stickers.get(h), r.stickers.contains_key(h)));
    }
    take(ElementKey::Layout, bs.layout.as_ref(), r_stamp(r, r_covers, rs.layout.as_ref(), !r.channel_layout.is_empty()));
    // Membership events R's record does not hold (R33-3); a ban's `Remove` rides its ban.
    let empty = Vec::new();
    for (m, events) in &base.member_events {
        let r_events = r.member_events.get(m).unwrap_or(&empty);
        for e in events.iter().filter(|e| lane.holds(e.at()) && !super::members::holds(r_events, e)) {
            let key = match e {
                MemberEvent::Admit { .. } => ElementKey::Admit(m.clone()),
                MemberEvent::Leave { .. } => ElementKey::Leave(m.clone()),
                MemberEvent::Remove { at } => {
                    if base.banned_members.get(m).is_some_and(|b| b.hlc() == at) {
                        continue;
                    }
                    ElementKey::Remove(m.clone())
                }
            };
            out.push(LaneWrite { key, stamp: e.at().clone() });
        }
    }
    out.sort_by(|a, b| b.stamp.cmp(&a.stamp).then_with(|| a.key.cmp(&b.key)));
    out
}

/// What the re-fold judges a write against: the base, R, the DR's T and the re-fold clock.
pub struct Judge<'a> {
    pub base: &'a ServerState,
    pub r: &'a ServerState,
    /// The DR's `posts_until_ms` (T on the member's clock).
    pub t_ms: Option<i64>,
    /// The re-fold checkpoint's clock.
    pub at: HlcTimestamp,
    /// Held ops this replica would fold onto a reverted unit.
    pub held: &'a [CrdtOp],
    pub lane: &'a Lane<'a>,
}

impl Judge<'_> {
    /// The one pure class of one dropped-lane write (section 8.3, "Classes").
    pub fn class(&self, w: &LaneWrite) -> RefoldClass {
        use ElementKey as K;
        let author = self.lane.member;
        let auto = || if self.may_write_now(&w.key) { RefoldClass::Auto } else { RefoldClass::Review };
        match &w.key {
            K::Admit(_) | K::Leave(_) | K::Remove(_) | K::Ban(_) | K::Mute(_) | K::Role(_) | K::RolePerms(_) => RefoldClass::Review,
            K::Grant(..) | K::LabelFields(_) | K::JoinSecret => RefoldClass::Review,
            K::ChannelExist(_) | K::LabelExist(_) | K::Emote(_) | K::Sticker(_) => RefoldClass::Review,
            K::ChannelField(_, ChannelField::Posting | ChannelField::Visibility | ChannelField::VisLabels | ChannelField::PostLabels) => {
                RefoldClass::Review
            }
            K::ChannelPublic(c) => {
                if self.unpublishes(c, &w.stamp) {
                    RefoldClass::Unpublish
                } else {
                    RefoldClass::Review
                }
            }
            K::Nickname(m) | K::Twitch(m) | K::Pledge(m) => {
                if m == author {
                    auto()
                } else {
                    RefoldClass::Review
                }
            }
            K::Assigned(m, l) => {
                let access = [self.base, self.r].iter().any(|s| s.labels.get(l).is_some_and(|x| x.access));
                if m != author || access {
                    RefoldClass::Review
                } else {
                    auto()
                }
            }
            K::Setting(k) => {
                if AUTO_SETTINGS.contains(&k.as_str()) {
                    auto()
                } else {
                    RefoldClass::Review
                }
            }
            K::Name | K::ChannelField(_, ChannelField::Name | ChannelField::Slow | ChannelField::Media | ChannelField::Voice) | K::Pin(..) | K::Layout => {
                auto()
            }
        }
    }

    /// Decision 21: the base shows the channel effectively public, the lane's winning
    /// `public` stamp is after T, and reverting the unit leaves it not effectively public.
    fn unpublishes(&self, channel: &str, stamp: &HlcTimestamp) -> bool {
        let Some(now) = self.base.channels.get(channel).filter(|c| c.effective_public()) else { return false };
        if !self.t_ms.is_some_and(|t| t >= 0 && stamp.physical_ms > t as u64) {
            return false;
        }
        !self.reverted_public(channel, now).effective_public()
    }

    /// The channel with its `public` unit at R's value, then every held op on that unit
    /// folded on top except the lane's own.
    fn reverted_public(&self, channel: &str, now: &ChannelInfo) -> ChannelInfo {
        let mut c = now.clone();
        let r_public = self.r.channels.get(channel).is_some_and(|x| x.is_public);
        c.is_public = r_public;
        let mut stamp = self.r.stamps.channels.get(channel).and_then(|s| s.public.clone());
        let mut ops: Vec<&CrdtOp> = self
            .held
            .iter()
            .filter(|o| !self.lane.holds(&o.hlc))
            .filter(|o| matches!(&o.payload, CrdtPayload::ChannelPublicChanged { channel_id, .. } if channel_id == channel))
            .collect();
        ops.sort_by(|a, b| a.hlc.cmp(&b.hlc));
        for o in ops {
            if let CrdtPayload::ChannelPublicChanged { is_public, .. } = &o.payload
                && stamp.as_ref().is_none_or(|s| o.hlc > *s)
            {
                c.is_public = *is_public;
                stamp = Some(o.hlc.clone());
            }
        }
        c
    }

    /// `op_allowed` on the base for a synthetic op by the author, at the re-fold clock,
    /// writing R's value of the element: a revert gives the author nothing it could not
    /// write again itself.
    pub fn may_write_now(&self, key: &ElementKey) -> bool {
        let Some(payload) = self.synthetic(key) else { return false };
        let op = CrdtOp {
            server_id: self.base.server_id.clone(),
            hlc: self.at.clone(),
            author: self.lane.member.to_string(),
            payload,
            auth: None,
            dev: None,
        };
        self.base.op_allowed_by_rules(&op)
    }

    fn synthetic(&self, key: &ElementKey) -> Option<CrdtPayload> {
        use CrdtPayload as P;
        use ElementKey as K;
        let (r, base) = (self.r, self.base);
        let chan = |c: &str| r.channels.get(c).or_else(|| base.channels.get(c)).cloned();
        Some(match key {
            K::Name => P::ServerRenamed { new_name: r.name.read().clone() },
            K::Setting(k) => P::ServerSettingChanged { key: k.clone(), value: r.settings.get(k).map(|x| x.read().clone()).unwrap_or_default() },
            K::Nickname(m) => P::NicknameChanged { peer_id: m.clone(), nickname: r.nicknames.get(m).map(|x| x.read().clone()).unwrap_or_default() },
            K::Twitch(m) => P::TwitchUsernameChanged { peer_id: m.clone(), twitch_username: r.twitch_usernames.get(m).map(|x| x.read().clone()).unwrap_or_default() },
            K::Pledge(m) => P::StoragePledgeChanged { peer_id: m.clone(), pledge_bytes: r.storage_pledges.get(m).map_or(0, |x| *x.read()) },
            K::Assigned(m, l) => {
                if r.label_assignments.get(m).is_some_and(|v| v.contains(l)) {
                    P::LabelAssigned { label_id: l.clone(), peer_id: m.clone() }
                } else {
                    P::LabelUnassigned { label_id: l.clone(), peer_id: m.clone() }
                }
            }
            K::ChannelField(c, ChannelField::Name) => P::ChannelRenamed { channel_id: c.clone(), new_name: chan(c)?.name },
            K::ChannelField(c, ChannelField::Slow) => P::ChannelSlowModeChanged { channel_id: c.clone(), seconds: chan(c)?.slow_mode },
            K::ChannelField(c, ChannelField::Media) => P::ChannelMediaOnlyChanged { channel_id: c.clone(), media_only: chan(c)?.media_only },
            K::ChannelField(c, ChannelField::Voice) => P::ChannelVoiceChatChanged { channel_id: c.clone(), mode: chan(c)?.voice_chat },
            K::Pin(c, msg) => {
                if r.pinned_messages.get(c).is_some_and(|v| v.contains(msg)) {
                    P::MessagePinned { channel_id: c.clone(), message_id: msg.clone() }
                } else {
                    P::MessageUnpinned { channel_id: c.clone(), message_id: msg.clone() }
                }
            }
            K::Layout => P::ChannelLayoutUpdated { layout_json: serde_json::to_string(&r.channel_layout).ok()? },
            _ => return None,
        })
    }
}

/// One REVIEW item of an entry: the element and the dropped lane's stamp on it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RefoldItem {
    pub key: String,
    pub stamp: HlcTimestamp,
}

/// One Unpublish revert: the channel and the lane's `public` stamp it reverted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Unpublished {
    pub channel: String,
    pub stamp: HlcTimestamp,
}

/// A person's answer, or the 30-day close (`timeout`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RefoldAnswer {
    pub by: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub undone: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub kept: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub put_back: Vec<String>,
    #[serde(default)]
    pub timeout: bool,
    pub sig: String,
}

/// One `cp_refolded` entry (section 8.3, "Shape").
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Refolded {
    pub member: String,
    pub device: String,
    /// The DR's content id (hex).
    pub dr: String,
    /// R's content id (hex).
    pub r: String,
    pub at: HlcTimestamp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opened: Option<HlcTimestamp>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub below: Option<HlcTimestamp>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub review: Vec<RefoldItem>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub unpublished: Vec<Unpublished>,
    pub by: String,
    pub sig: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub answered: Option<RefoldAnswer>,
}

fn device_sig(device: &NativeKeypair, msg: &str) -> String {
    base64::engine::general_purpose::STANDARD.encode(device.sign(msg.as_bytes()))
}

fn sig_ok(device: &str, msg: &str, sig: &str) -> bool {
    let Some(key) = crate::crypto::safety_number::pubkey_from_peer_id(device) else { return false };
    let Ok(raw) = base64::engine::general_purpose::STANDARD.decode(sig) else { return false };
    let Ok(raw) = <[u8; 64]>::try_from(raw.as_slice()) else { return false };
    let Ok(vk) = ed25519_dalek::VerifyingKey::from_bytes(&key) else { return false };
    vk.verify_strict(msg.as_bytes(), &ed25519_dalek::Signature::from_bytes(&raw)).is_ok()
}

impl Refolded {
    fn signed(&self, server: &str) -> String {
        let fields = serde_json::to_string(&(
            server, &self.member, &self.device, &self.dr, &self.r, &self.at, &self.opened, &self.below, &self.review, &self.unpublished,
        ))
        .unwrap_or_default();
        format!("hollow-refold1\n{fields}")
    }

    fn answer_signed(&self, server: &str, a: &RefoldAnswer) -> String {
        let fields =
            serde_json::to_string(&(server, &self.member, &self.device, &self.dr, &self.below, &a.undone, &a.kept, &a.put_back, a.timeout))
                .unwrap_or_default();
        format!("hollow-refold-answer1\n{fields}")
    }

    /// Sign the entry as `device` (its `by`).
    pub fn sign(&mut self, server: &str, device: &NativeKeypair) {
        self.by = device.peer_id();
        self.sig = device_sig(device, &self.signed(server));
    }

    pub fn sig_verifies(&self, server: &str) -> bool {
        sig_ok(&self.by, &self.signed(server), &self.sig)
    }

    /// Set the answer, signed by `device`.
    pub fn answer(&mut self, server: &str, device: &NativeKeypair, undone: Vec<String>, kept: Vec<String>, put_back: Vec<String>, timeout: bool) {
        let mut a = RefoldAnswer { by: device.peer_id(), undone, kept, put_back, timeout, sig: String::new() };
        a.sig = device_sig(device, &self.answer_signed(server, &a));
        self.answered = Some(a);
    }

    /// The answer, when its signature holds; a void answer reads as none.
    pub fn valid_answer(&self, server: &str) -> Option<&RefoldAnswer> {
        self.answered.as_ref().filter(|a| sig_ok(&a.by, &self.answer_signed(server, a), &a.sig))
    }

    pub fn pair(&self) -> (&str, &str) {
        (&self.member, &self.device)
    }
}

/// The REVIEW items and Unpublish records a lane walk gives an entry, newest first and
/// capped; AUTO writes are reverted by the caller and listed nowhere.
pub fn classify(judge: &Judge<'_>, writes: &[LaneWrite]) -> (Vec<(LaneWrite, RefoldClass)>, Vec<RefoldItem>, Vec<Unpublished>) {
    let mut classed = Vec::with_capacity(writes.len());
    let mut review = Vec::new();
    let mut unpublished = Vec::new();
    for w in writes {
        let class = judge.class(w);
        match class {
            RefoldClass::Review if review.len() < MAX_REVIEW => review.push(RefoldItem { key: w.key.to_key(), stamp: w.stamp.clone() }),
            RefoldClass::Unpublish if unpublished.len() < MAX_UNPUBLISHED => {
                if let ElementKey::ChannelPublic(c) = &w.key {
                    unpublished.push(Unpublished { channel: c.clone(), stamp: w.stamp.clone() });
                }
            }
            _ => {}
        }
        classed.push((w.clone(), class));
    }
    (classed, review, unpublished)
}

/// The stamp an element carries in `state` now: what an item's re-check compares.
pub fn winning_stamp(state: &ServerState, key: &ElementKey) -> Option<HlcTimestamp> {
    use ElementKey as K;
    let st = &state.stamps;
    let ch = |c: &str| st.channels.get(c);
    let event = |m: &str, f: fn(&MemberEvent) -> bool| state.member_events.get(m).and_then(|v| v.iter().filter(|e| f(e)).map(|e| e.at().clone()).max());
    match key {
        K::Name => Some(state.name.hlc().clone()),
        K::Setting(k) => state.settings.get(k).map(|x| x.hlc().clone()),
        K::Role(m) => state.roles.get(m).map(|x| x.hlc().clone()),
        K::RolePerms(r) => state.role_permissions.get(r).map(|x| x.hlc().clone()),
        K::Nickname(m) => state.nicknames.get(m).map(|x| x.hlc().clone()),
        K::Twitch(m) => state.twitch_usernames.get(m).map(|x| x.hlc().clone()),
        K::Pledge(m) => state.storage_pledges.get(m).map(|x| x.hlc().clone()),
        K::Ban(m) => state.banned_members.get(m).map(|x| x.hlc().clone()),
        K::Mute(m) => state.muted_members.get(m).map(|x| x.hlc().clone()),
        K::Grant(c, m) => state.channel_grants.get(c).and_then(|p| p.get(m)).map(|x| x.hlc().clone()),
        K::JoinSecret => state.join_secret.as_ref().map(|x| x.hlc().clone()),
        K::ChannelExist(c) => ch(c).and_then(|x| x.exist.clone()),
        K::ChannelPublic(c) => ch(c).and_then(|x| x.public.clone()),
        K::ChannelField(c, f) => ch(c).and_then(|x| {
            match f {
                ChannelField::Name => &x.name,
                ChannelField::Posting => &x.posting,
                ChannelField::Visibility => &x.visibility,
                ChannelField::VisLabels => &x.vis_labels,
                ChannelField::PostLabels => &x.post_labels,
                ChannelField::Slow => &x.slow,
                ChannelField::Media => &x.media,
                ChannelField::Voice => &x.voice,
            }
            .clone()
        }),
        K::Pin(c, msg) => st.pins.get(c).and_then(|x| x.get(msg)).cloned(),
        K::LabelExist(l) => st.labels.get(l).and_then(|x| x.exist.clone()),
        K::LabelFields(l) => st.labels.get(l).and_then(|x| x.fields.clone()),
        K::Assigned(m, l) => st.assigned.get(m).and_then(|x| x.get(l)).cloned(),
        K::Emote(e) => st.emotes.get(e).cloned(),
        K::Sticker(h) => st.stickers.get(h).cloned(),
        K::Layout => st.layout.clone(),
        K::Admit(m) => event(m, |e| matches!(e, MemberEvent::Admit { .. })),
        K::Leave(m) => event(m, |e| matches!(e, MemberEvent::Leave { .. })),
        K::Remove(m) => event(m, |e| matches!(e, MemberEvent::Remove { .. })),
    }
}

/// Whether a membership item still stands: the member's record holds no event newer
/// than the listed one, so an undone kick never re-opens a span over an honest rejoin.
pub fn membership_item_current(state: &ServerState, key: &ElementKey, stamp: &HlcTimestamp) -> bool {
    let Some(m) = key.target() else { return false };
    state.member_events.get(m).is_some_and(|v| v.iter().any(|e| e.at() == stamp) && v.iter().all(|e| e.at() <= stamp))
}

/// Whether an item still carries the lane's stamp it was listed with: an item someone
/// changed since is skipped and stays (R34-1, R34-8).
pub fn item_current(state: &ServerState, key: &ElementKey, stamp: &HlcTimestamp) -> bool {
    match key {
        ElementKey::Admit(_) | ElementKey::Leave(_) | ElementKey::Remove(_) => membership_item_current(state, key, stamp),
        ElementKey::Ban(m) => {
            winning_stamp(state, key).as_ref() == Some(stamp)
                && state.member_events.get(m).is_some_and(|v| v.iter().any(|e| matches!(e, MemberEvent::Remove { at } if at == stamp)))
                && membership_item_current(state, &ElementKey::Remove(m.clone()), stamp)
        }
        _ => winning_stamp(state, key).as_ref() == Some(stamp),
    }
}

fn revert_reg<V: Clone>(now: &mut HashMap<String, super::admin_lww::AdminLwwReg<V>>, r: &HashMap<String, super::admin_lww::AdminLwwReg<V>>, k: &str) {
    match r.get(k) {
        Some(v) => {
            now.insert(k.to_string(), v.clone());
        }
        None => {
            now.remove(k);
        }
    }
}

/// Drop the event at `stamp` from `master`'s record and fold the spans again.
fn revert_event(state: &mut ServerState, master: &str, stamp: &HlcTimestamp) -> bool {
    let mut events = state.events_of(master).into_owned();
    let before = events.len();
    events.retain(|e| e.at() != stamp);
    if events.len() == before {
        return false;
    }
    state.rederive(master, events, stamp);
    true
}

/// Put one element back to R's value and stamp (absent where R lacks it), once its item
/// still stands. False when the element is not one this revert handles or changed since.
/// Held ops on the element are folded on top by the caller.
pub fn apply_revert(state: &mut ServerState, r: &ServerState, key: &ElementKey, stamp: &HlcTimestamp) -> bool {
    use ElementKey as K;
    if !item_current(state, key, stamp) {
        return false;
    }
    match key {
        K::Name => state.name = r.name.clone(),
        K::Setting(k) => revert_reg(&mut state.settings, &r.settings, k),
        K::Role(m) => revert_reg(&mut state.roles, &r.roles, m),
        K::RolePerms(k) => revert_reg(&mut state.role_permissions, &r.role_permissions, k),
        K::Nickname(m) => revert_reg(&mut state.nicknames, &r.nicknames, m),
        K::Twitch(m) => revert_reg(&mut state.twitch_usernames, &r.twitch_usernames, m),
        K::Pledge(m) => revert_reg(&mut state.storage_pledges, &r.storage_pledges, m),
        K::Mute(m) => revert_reg(&mut state.muted_members, &r.muted_members, m),
        K::Ban(m) => {
            revert_reg(&mut state.banned_members, &r.banned_members, m);
            revert_event(state, m, stamp);
        }
        K::Grant(c, m) => {
            let back = r.channel_grants.get(c).and_then(|p| p.get(m)).cloned();
            let per = state.channel_grants.entry(c.clone()).or_default();
            match back {
                Some(v) => {
                    per.insert(m.clone(), v);
                }
                None => {
                    per.remove(m);
                }
            }
        }
        K::Admit(m) | K::Leave(m) | K::Remove(m) => return revert_event(state, m, stamp),
        K::ChannelField(c, f) => {
            let (Some(now), Some(was)) = (state.channels.get_mut(c), r.channels.get(c)) else { return false };
            match f {
                ChannelField::Name => now.name = was.name.clone(),
                ChannelField::Posting => now.posting = was.posting.clone(),
                ChannelField::Visibility => now.visibility = was.visibility.clone(),
                ChannelField::VisLabels => now.visibility_labels = was.visibility_labels.clone(),
                ChannelField::PostLabels => now.posting_labels = was.posting_labels.clone(),
                ChannelField::Slow => now.slow_mode = was.slow_mode,
                ChannelField::Media => now.media_only = was.media_only,
                ChannelField::Voice => now.voice_chat = was.voice_chat,
            }
            let back = r.stamps.channels.get(c).cloned().unwrap_or_default();
            let st = state.stamps.channels.entry(c.clone()).or_default();
            match f {
                ChannelField::Name => st.name = back.name,
                ChannelField::Posting => st.posting = back.posting,
                ChannelField::Visibility => st.visibility = back.visibility,
                ChannelField::VisLabels => st.vis_labels = back.vis_labels,
                ChannelField::PostLabels => st.post_labels = back.post_labels,
                ChannelField::Slow => st.slow = back.slow,
                ChannelField::Media => st.media = back.media,
                ChannelField::Voice => st.voice = back.voice,
            }
        }
        K::ChannelPublic(c) => {
            let Some(now) = state.channels.get_mut(c) else { return false };
            now.is_public = r.channels.get(c).is_some_and(|x| x.is_public);
            let back = r.stamps.channels.get(c).cloned().unwrap_or_default();
            let st = state.stamps.channels.entry(c.clone()).or_default();
            (st.public, st.set, st.set_vis, st.set_labels) = (back.public, back.set, back.set_vis, back.set_labels);
        }
        K::Pin(c, msg) => {
            let pinned = r.pinned_messages.get(c).is_some_and(|v| v.contains(msg));
            let list = state.pinned_messages.entry(c.clone()).or_default();
            list.retain(|x| x != msg);
            if pinned {
                list.push(msg.clone());
            }
            let back = r.stamps.pins.get(c).and_then(|x| x.get(msg)).cloned();
            let per = state.stamps.pins.entry(c.clone()).or_default();
            match back {
                Some(s) => {
                    per.insert(msg.clone(), s);
                }
                None => {
                    per.remove(msg);
                }
            }
        }
        K::Layout => {
            state.channel_layout = r.channel_layout.clone();
            state.stamps.layout = r.stamps.layout.clone();
        }
        K::Assigned(m, l) => {
            let had = r.label_assignments.get(m).is_some_and(|v| v.contains(l));
            let list = state.label_assignments.entry(m.clone()).or_default();
            list.retain(|x| x != l);
            if had {
                list.push(l.clone());
            }
            let back = r.stamps.assigned.get(m).and_then(|x| x.get(l)).cloned();
            let per = state.stamps.assigned.entry(m.clone()).or_default();
            match back {
                Some(s) => {
                    per.insert(l.clone(), s);
                }
                None => {
                    per.remove(l);
                }
            }
        }
        // Existence and label fields bring sub-stamps and access rules with them
        // (R33-10, R34-7): the re-fold writer reverts those as one unit.
        K::JoinSecret | K::ChannelExist(_) | K::LabelExist(_) | K::LabelFields(_) | K::Emote(_) | K::Sticker(_) => return false,
    }
    true
}


impl ServerState {
    /// What a new checkpoint carries as `cp_refolded` (section 8.3, "Shape"; section 8.2
    /// rule 3): the base's entries whose signature holds and whose writer this view counts
    /// for the owner; an answer stays only while the same holds for it (a dropped answer
    /// re-opens its entry). Past `MAX_ENTRIES`, answered entries go first, oldest first.
    pub(crate) fn carried_refolded(&self) -> Vec<Refolded> {
        let Some(owner) = self.anchor_owner() else { return Vec::new() };
        let sid = self.server_id.as_str();
        let counts = |d: &str| self.authority.counts(&owner, d);
        let mut out: Vec<Refolded> = Vec::new();
        for e in self.base.iter().flat_map(|b| b.state.cp_refolded.iter()) {
            if !e.sig_verifies(sid) || !counts(&e.by) || out.iter().any(|x| x.pair() == e.pair()) {
                continue;
            }
            let mut e = e.clone();
            if e.valid_answer(sid).is_none_or(|a| !counts(&a.by)) {
                e.answered = None;
            }
            out.push(e);
        }
        if out.len() > MAX_ENTRIES {
            out.sort_by(|a, b| b.answered.is_none().cmp(&a.answered.is_none()).then_with(|| b.at.cmp(&a.at)));
            out.truncate(MAX_ENTRIES);
        }
        out.sort_by(|a, b| a.pair().cmp(&b.pair()));
        out
    }

    /// Whether the base's `cp_refolded` stops a re-fold of (member, device) (R33-7, R34-1):
    /// an entry for the pair that verifies, written by an owner device this view counts,
    /// and naming a DR that `dr_fits` accepts (a DR this replica holds must be a counted
    /// DR for the same pair).
    pub(crate) fn refold_suppressed(&self, member: &str, device: &str, dr_fits: &dyn Fn(&Refolded) -> bool) -> bool {
        self.base.iter().flat_map(|b| b.state.cp_refolded.iter()).any(|e| e.pair() == (member, device) && self.entry_suppresses(e, dr_fits))
    }

    /// One entry's half of `refold_suppressed`, which the writer asks of the entries it
    /// carries too, so a pair it re-folds is exactly a pair the trigger names.
    pub(crate) fn entry_suppresses(&self, e: &Refolded, dr_fits: &dyn Fn(&Refolded) -> bool) -> bool {
        let Some(owner) = self.anchor_owner() else { return false };
        e.sig_verifies(&self.server_id) && self.authority.counts(&owner, &e.by) && dr_fits(e)
    }
}

#[cfg(test)]
#[path = "refold_tests.rs"]
mod tests;
