use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};

use super::admin_lww::AdminLwwReg;
use super::hlc::{Hlc, HlcTimestamp};
use super::operations::{CrdtOp, CrdtPayload, MemberRole, Permission};
#[cfg(test)]
use super::operations::OpReject;
use crate::identity::native_identity::NativeKeypair;

/// The MASTER keypair this replica authors ops with, plus its base64 protobuf public
/// key: `create_op` needs both to produce an op any peer will accept. Debug is
/// hand-written because a secret key has no business in a log line.
#[derive(Clone)]
pub(crate) struct OpSigner {
    keypair: NativeKeypair,
    pk_b64: String,
}

impl std::fmt::Debug for OpSigner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("OpSigner(<redacted>)")
    }
}

/// Type of channel within a server.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ChannelType {
    #[serde(rename = "text")]
    Text,
    #[serde(rename = "voice")]
    Voice,
}

impl Default for ChannelType {
    fn default() -> Self {
        Self::Text
    }
}

/// An item in the channel layout — category header, channel reference, or separator.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ChannelLayoutItem {
    #[serde(rename = "category")]
    Category { name: String },
    #[serde(rename = "channel")]
    Channel { channel_id: String },
    #[serde(rename = "separator")]
    Separator,
}

/// A label (tag) that can be assigned to members. Cosmetic by default;
/// `access: true` makes it a security boundary: it can gate channels
/// (`ChannelInfo::visibility_labels`/`posting_labels`) and is therefore
/// never self-assignable — only MANAGE_ROLES holders assign it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct LabelInfo {
    pub label_id: String,
    pub name: String,
    pub color: String,
    #[serde(default)]
    pub access: bool,
}

/// A custom server emote. METADATA ONLY — the image bytes are content-
/// addressed by `hash` (SHA-256 hex of the processed WebP) and replicate
/// on demand via EmoteRequest/EmoteResponse, never through the CRDT.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct EmoteInfo {
    pub name: String,
    pub hash: String,
    #[serde(default)]
    pub animated: bool,
}

/// Hard cap on custom emotes per server (enforced at authoring AND apply so
/// replicas converge on the same refusal).
pub const MAX_SERVER_EMOTES: usize = 50;

/// A sticker of a server's set. METADATA ONLY, like [EmoteInfo]: the bytes are
/// content-addressed by `hash` and replicate on demand over the asset rail. `w`/`h`
/// ride along so the picker and the `[a:s:hash:w:h]` token can reserve the exact cell
/// before any bytes land.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct StickerInfo {
    pub hash: String,
    #[serde(default)]
    pub name: String,
    /// Group label inside the server's set (`""` = the default pack).
    #[serde(default)]
    pub pack: String,
    #[serde(default)]
    pub animated: bool,
    #[serde(default)]
    pub w: u32,
    #[serde(default)]
    pub h: u32,
}

/// Hard cap on stickers per server (authoring AND apply, like emotes). Deliberately
/// the same number even though the blobs are ~20x bigger: a member opening the picker
/// pulls whatever scrolls into view, so the ceiling is a bandwidth decision too.
pub const MAX_SERVER_STICKERS: usize = 50;

/// Max characters in a sticker's label or pack name. Stickers are picked visually and
/// never typed, so unlike emote names these are free-form, bounded, and rejected
/// outright if they carry control characters.
pub const MAX_STICKER_LABEL: usize = 32;

/// Grammar for a sticker label / pack name: short, no control characters.
/// Empty is legal (an unnamed sticker in the default pack).
pub fn valid_sticker_label(s: &str) -> bool {
    s.chars().count() <= MAX_STICKER_LABEL && !s.chars().any(|c| c.is_control())
}

/// Who can see a channel.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ChannelVisibility {
    #[serde(rename = "everyone")]
    Everyone,
    #[serde(rename = "moderator")]
    ModeratorPlus,
    #[serde(rename = "admin")]
    AdminPlus,
}

impl Default for ChannelVisibility {
    fn default() -> Self {
        Self::Everyone
    }
}

/// Who can post in a channel.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ChannelPosting {
    #[serde(rename = "everyone")]
    Everyone,
    #[serde(rename = "moderator")]
    ModeratorPlus,
    #[serde(rename = "admin")]
    AdminPlus,
}

impl Default for ChannelPosting {
    fn default() -> Self {
        Self::Everyone
    }
}

/// Metadata for a channel within a server.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ChannelInfo {
    pub channel_id: String,
    pub name: String,
    pub category: Option<String>,
    #[serde(default)]
    pub channel_type: ChannelType,
    #[serde(default)]
    pub visibility: ChannelVisibility,
    #[serde(default)]
    pub posting: ChannelPosting,
    #[serde(default)]
    pub is_public: bool,
    /// Slow mode: minimum seconds between messages per member (0 = off).
    /// Moderator+ are exempt.
    #[serde(default)]
    pub slow_mode: u32,
    /// Media-only: only image/video/GIF attachments (with optional captions)
    /// may be posted; standalone text and other file types are rejected.
    #[serde(default)]
    pub media_only: bool,
    /// Label gate for visibility. Non-empty REPLACES the tier ladder: holders of ANY
    /// listed label (plus Admin+/Owner) see the channel. Always authored alongside an
    /// `AdminPlus` stamp so clients that predate this field fail closed.
    #[serde(default)]
    pub visibility_labels: Vec<String>,
    /// Label gate for posting; same semantics as `visibility_labels`.
    #[serde(default)]
    pub posting_labels: Vec<String>,
}

impl ChannelInfo {
    /// Whether this channel is EFFECTIVELY public. Voice channels can never be public:
    /// only their text chat would be browsable, and a public voice channel silently
    /// changes the SFrame key domain. Nor can a restricted channel, whatever order its
    /// flags were set in (D6). A stale or malicious `is_public` is neutralized HERE, so
    /// every read must go through this, never the raw flag.
    pub fn effective_public(&self) -> bool {
        self.is_public && self.channel_type == ChannelType::Text && !self.restricted()
    }

    /// Whether only some members may see it: a tier above everyone, or a label gate.
    pub fn restricted(&self) -> bool {
        self.visibility != ChannelVisibility::Everyone || !self.visibility_labels.is_empty()
    }
}

/// Metadata for a member within a server.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MemberInfo {
    pub peer_id: String,
    pub display_name: String,
}

/// One stretch of time an identity was a member, in epoch ms from its admitting op's
/// clock to its removal's (`u64::MAX` while still a member).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MemberSpan {
    pub from_ms: u64,
    pub until_ms: u64,
    /// The `at` of the ask that opened it; 0 for the founder and spans a checkpoint seeded.
    #[serde(default)]
    pub asked_at: i64,
}

/// Slack either side of a membership span when judging a post's time: post clocks
/// are the author's own, span ends are the admitter's or remover's.
pub const MEMBER_SPAN_SLACK_MS: u64 = 10 * 60 * 1000;

/// What a replica's state is rebuilt from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Anchor {
    /// An existing (32-hex) server no checkpoint has reached yet: ops apply
    /// incrementally in arrival order, and there is nothing to rebuild from.
    Legacy,
    /// A self-certifying id: rebuilt from its founding op.
    Genesis,
    /// Rebuilt from the owner's latest checkpoint.
    Checkpoint,
}

/// The full CRDT state of a Hollow server: operation-based, so every mutation goes
/// through `apply_op()`, which is commutative and idempotent.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerState {
    pub server_id: String,
    pub name: AdminLwwReg<String>,
    pub channels: HashMap<String, ChannelInfo>,
    pub members: HashMap<String, MemberInfo>,
    pub roles: HashMap<String, AdminLwwReg<MemberRole>>,
    #[serde(default)]
    pub nicknames: HashMap<String, AdminLwwReg<String>>,
    #[serde(default)]
    pub twitch_usernames: HashMap<String, AdminLwwReg<String>>,
    #[serde(default)]
    pub pinned_messages: HashMap<String, Vec<String>>,
    #[serde(default)]
    pub channel_layout: Vec<ChannelLayoutItem>,
    #[serde(default)]
    pub storage_pledges: HashMap<String, AdminLwwReg<u64>>,
    pub settings: HashMap<String, AdminLwwReg<String>>,
    #[serde(default)]
    pub role_permissions: HashMap<String, AdminLwwReg<u32>>,
    #[serde(default)]
    pub banned_members: HashMap<String, AdminLwwReg<bool>>,
    /// Muted members (server-wide read-only): master peer_id -> mute expiry in
    /// epoch ms. `u64::MAX` = permanent, `0` = unmuted (pruned on unmute).
    #[serde(default)]
    pub muted_members: HashMap<String, AdminLwwReg<u64>>,
    /// Temporary channel access grants: channel_id -> master peer_id -> expiry epoch ms.
    /// `u64::MAX` = until revoked, `0` = revoked. Modeled on `muted_members`: LWW per
    /// entry, lazy expiry at read time, no background pruning.
    #[serde(default)]
    pub channel_grants: HashMap<String, HashMap<String, AdminLwwReg<u64>>>,
    #[serde(default)]
    pub labels: HashMap<String, LabelInfo>,
    #[serde(default)]
    pub label_assignments: HashMap<String, Vec<String>>,
    /// Custom emote set, keyed by emote name. `#[serde(default)]` so every
    /// pre-existing persisted ServerState loads with an empty set.
    #[serde(default)]
    pub emotes: HashMap<String, EmoteInfo>,
    /// Sticker set, keyed by content HASH (a sticker is picked, never typed,
    /// so its name is not an identity). `#[serde(default)]` so every
    /// pre-existing persisted ServerState loads with an empty set.
    #[serde(default)]
    pub stickers: HashMap<String, StickerInfo>,
    /// Tombstone latch, set by a `ServerDeleted` op. The state shell and op_log are
    /// RETAINED so this node keeps serving the deletion op to reconnecting peers.
    /// Monotonic delete-wins: there is no un-delete op.
    #[serde(default)]
    pub deleted: bool,
    /// Every stretch each identity (master) was a member: the provable record channel
    /// backfill judges a post's author against. Carried by checkpoints.
    #[serde(default)]
    pub member_record: HashMap<String, Vec<MemberSpan>>,
    /// The Owner's join secret (`JoinKeySet`), 64 hex. Carried by checkpoints.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub join_secret: Option<AdminLwwReg<super::operations::JoinSecret>>,
    /// The join lock (`JoinLock`): chain, door secrets, sealed change keys. Carried by
    /// checkpoints.
    #[serde(default, skip_serializing_if = "super::lock_state::JoinLockState::is_empty")]
    pub join_lock: super::lock_state::JoinLockState,
    /// The owner this replica is anchored to: the founder of a self-certifying id,
    /// the pin an invite carried, or the owner of the first checkpoint or snapshot we
    /// accepted. The owner never changes, so neither does this once set.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_pin: Option<String>,
    /// Clock of the checkpoint this state was last rebased on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checkpoint_hlc: Option<HlcTimestamp>,
    /// Admitted ops since the anchor, HLC-sorted. Persisted in `crdt_ops`, never in
    /// the state JSON. Capped at `LEGACY_OP_LOG_CAP` only while `Anchor::Legacy`.
    #[serde(default, skip_serializing)]
    pub op_log: Vec<CrdtOp>,
    #[serde(skip)]
    pub hlc: Option<Hlc>,
    #[serde(skip)]
    pub(super) op_log_dedup: HashSet<(String, HlcTimestamp)>,
    /// Signed ops refused only for authority, re-judged at the next rebuild: an op
    /// can race ahead of the role grant or admission it depends on.
    #[serde(skip)]
    pub(super) held: Vec<(CrdtOp, std::time::Instant)>,
    /// Set by the node right after `set_hlc` on any state that authors ops.
    /// Never persisted and never sent: it is our own secret.
    #[serde(skip)]
    signer: Option<OpSigner>,
}

/// The op-log cap of a legacy-anchored server, which has no base to rebuild from.
pub(super) const LEGACY_OP_LOG_CAP: usize = 1000;

impl ServerState {
    /// A serialization-only clone: everything the persisted JSON contains, with the
    /// heavy in-memory-only fields left empty, so JSON from this snapshot is identical
    /// to serializing `self` while skipping up to 1000 op-log entries. It moves the
    /// serialization off the event loop, so a burst of N ops serializes ONCE per drain.
    /// Exhaustive destructuring on purpose: adding a ServerState field breaks this at
    /// compile time, forcing a decision on whether it persists.
    pub fn lean_snapshot(&self) -> ServerState {
        let ServerState {
            server_id, name, channels, members, roles, nicknames,
            twitch_usernames, pinned_messages, channel_layout, storage_pledges,
            settings, role_permissions, banned_members, muted_members,
            channel_grants, labels, label_assignments, emotes, stickers, deleted,
            member_record, join_secret, join_lock, owner_pin, checkpoint_hlc,
            op_log: _, hlc: _, op_log_dedup: _, held: _, signer: _,
        } = self;
        ServerState {
            server_id: server_id.clone(),
            name: name.clone(),
            channels: channels.clone(),
            members: members.clone(),
            roles: roles.clone(),
            nicknames: nicknames.clone(),
            twitch_usernames: twitch_usernames.clone(),
            pinned_messages: pinned_messages.clone(),
            channel_layout: channel_layout.clone(),
            storage_pledges: storage_pledges.clone(),
            settings: settings.clone(),
            role_permissions: role_permissions.clone(),
            banned_members: banned_members.clone(),
            muted_members: muted_members.clone(),
            channel_grants: channel_grants.clone(),
            labels: labels.clone(),
            label_assignments: label_assignments.clone(),
            emotes: emotes.clone(),
            stickers: stickers.clone(),
            deleted: *deleted,
            member_record: member_record.clone(),
            join_secret: join_secret.clone(),
            join_lock: join_lock.clone(),
            owner_pin: owner_pin.clone(),
            checkpoint_hlc: checkpoint_hlc.clone(),
            op_log: Vec::new(),
            hlc: None,
            op_log_dedup: HashSet::new(),
            held: Vec::new(),
            signer: None,
        }
    }

    /// An ownerless, empty state for `server_id`: what a fold starts from, and what a
    /// joiner holds before the first op lands.
    pub fn skeleton(server_id: String) -> Self {
        Self {
            server_id,
            name: AdminLwwReg::new(String::new(), HlcTimestamp::zero(""), 0),
            channels: HashMap::new(),
            members: HashMap::new(),
            roles: HashMap::new(),
            nicknames: HashMap::new(),
            twitch_usernames: HashMap::new(),
            pinned_messages: HashMap::new(),
            channel_layout: Vec::new(),
            storage_pledges: HashMap::new(),
            settings: HashMap::new(),
            role_permissions: HashMap::new(),
            banned_members: HashMap::new(),
            muted_members: HashMap::new(),
            channel_grants: HashMap::new(),
            labels: HashMap::new(),
            label_assignments: HashMap::new(),
            emotes: HashMap::new(),
            stickers: HashMap::new(),
            deleted: false,
            member_record: HashMap::new(),
            join_secret: None,
            join_lock: Default::default(),
            owner_pin: None,
            checkpoint_hlc: None,
            op_log: Vec::new(),
            hlc: None,
            op_log_dedup: HashSet::new(),
            held: Vec::new(),
            signer: None,
        }
    }

    /// A state seeded with its creator as Owner and #general, WITHOUT a founding op:
    /// the shape of every server founded before 0.12, kept for tests of that shape.
    /// New servers are founded with [`ServerState::found`].
    #[cfg(test)]
    pub fn new(server_id: String, name: String, creator_peer_id: String) -> Self {
        let mut hlc = Hlc::new(creator_peer_id.clone());
        let ts = hlc.now();
        let mut s = Self::skeleton(server_id);
        s.seed_founder(&name, &creator_peer_id, &ts);
        s.hlc = Some(hlc);
        s
    }

    /// Found a new server with a self-certifying id: the founder's signed
    /// `ServerCreated`, already applied, is the first op of its log.
    pub(crate) fn found(name: String, owner_peer_id: String, keypair: NativeKeypair, pk_b64: String) -> (Self, CrdtOp) {
        let nonce = super::anchor::new_nonce();
        let server_id = super::anchor::derive_server_id(&owner_peer_id, &nonce);
        let mut s = Self::skeleton(server_id);
        s.set_hlc(Hlc::new(owner_peer_id.clone()));
        s.set_signer(keypair, pk_b64);
        let op = s.create_op(CrdtPayload::ServerCreated { name, owner_peer_id, nonce });
        debug_assert!(s.op_allowed(&op), "a fresh founding op must pass its own rule");
        let _ = s.apply_op(&op);
        (s, op)
    }

    /// The founder's seat: name, Owner role, membership span, #general, and the anchor.
    fn seed_founder(&mut self, name: &str, owner: &str, at: &HlcTimestamp) {
        self.name = AdminLwwReg::new(name.to_string(), at.clone(), MemberRole::Owner.priority());
        self.members.insert(owner.to_string(), MemberInfo {
            peer_id: owner.to_string(),
            display_name: short_name(owner),
        });
        self.roles.insert(
            owner.to_string(),
            AdminLwwReg::new(MemberRole::Owner, at.clone(), MemberRole::Owner.priority()),
        );
        self.open_span(owner, at.physical_ms, 0);
        let general_id = format!("{}-general", &self.server_id[..8.min(self.server_id.len())]);
        self.channels.entry(general_id.clone()).or_insert_with(|| ChannelInfo {
            channel_id: general_id,
            name: "general".to_string(),
            category: None,
            channel_type: ChannelType::Text,
            visibility: ChannelVisibility::Everyone,
            posting: ChannelPosting::Everyone,
            is_public: false,
            slow_mode: 0,
            media_only: false,
            visibility_labels: Vec::new(),
            posting_labels: Vec::new(),
        });
        if self.owner_pin.is_none() {
            self.owner_pin = Some(owner.to_string());
        }
    }

    /// What this replica rebuilds from.
    pub fn anchor(&self) -> Anchor {
        if self.checkpoint_hlc.is_some() {
            Anchor::Checkpoint
        } else if super::anchor::is_genesis_id(&self.server_id) {
            Anchor::Genesis
        } else {
            Anchor::Legacy
        }
    }

    /// The owner every founding op, checkpoint and snapshot must name.
    pub fn anchor_owner(&self) -> Option<String> {
        self.owner_pin.clone().or_else(|| self.current_owner())
    }

    fn open_span(&mut self, master: &str, at_ms: u64, asked_at: i64) {
        let spans = self.member_record.entry(master.to_string()).or_default();
        if spans.last().is_none_or(|s| s.until_ms != u64::MAX) {
            spans.push(MemberSpan { from_ms: at_ms, until_ms: u64::MAX, asked_at });
        }
    }

    fn close_span(&mut self, master: &str, at_ms: u64) {
        if let Some(open) = self.member_record.get_mut(master)
            .and_then(|spans| spans.last_mut())
            .filter(|s| s.until_ms == u64::MAX)
        {
            open.until_ms = at_ms.max(open.from_ms);
        }
    }

    /// Was `master` a member at `at_ms` (the author's own clock), give or take
    /// `MEMBER_SPAN_SLACK_MS`?
    pub fn was_member_at(&self, master: &str, at_ms: u64) -> bool {
        self.member_record.get(master).is_some_and(|spans| spans.iter().any(|s| {
            s.from_ms.saturating_sub(MEMBER_SPAN_SLACK_MS) <= at_ms
                && at_ms < s.until_ms.saturating_add(MEMBER_SPAN_SLACK_MS)
        }))
    }

    /// When `master` last left, if the record shows it gone now.
    pub fn left_at(&self, master: &str) -> Option<u64> {
        self.member_record.get(master)?.last().filter(|s| s.until_ms != u64::MAX).map(|s| s.until_ms)
    }

    /// When `master`'s current membership began, if the record holds an open span.
    pub fn member_since(&self, master: &str) -> Option<u64> {
        self.member_record.get(master)?.last().filter(|s| s.until_ms == u64::MAX).map(|s| s.from_ms)
    }

    /// Restore from persistence (HLC set separately via `set_hlc`).
    pub fn set_hlc(&mut self, hlc: Hlc) {
        self.hlc = Some(hlc);
    }

    /// Install the MASTER keypair this replica signs its own ops with. Goes hand in hand
    /// with `set_hlc`: a state that can author an op must be able to sign it, or every
    /// peer rejects what it produces.
    pub(crate) fn set_signer(&mut self, keypair: NativeKeypair, pk_b64: String) {
        self.signer = Some(OpSigner { keypair, pk_b64 });
    }

    /// Fold any per-member entry keyed by a DEVICE id into its MASTER identity, so one
    /// human appears once. A LOCAL cleanup that emits no CRDT op: legacy servers recorded
    /// joiners under their device id before membership was canonicalized, and future ops
    /// are already master-keyed at the source. Returns true if anything was re-keyed.
    ///
    /// LWW registers fold via `AdminLwwReg::merge` (pure HLC), while plain entries keep
    /// an existing master entry and otherwise adopt the device entry's value.
    ///
    /// SECURITY (E8): a device-keyed role, ban or mute register was judged against
    /// whatever rank the device id read as when it arrived (Member, if it could not be
    /// resolved yet), so it may only be ADOPTED by a master that has no register of its
    /// own, never lands on the Owner, never carries Owner, and a ban or mute never lands
    /// on a Moderator or above. Anchored servers never run this at all.
    pub fn canonicalize_members(&mut self, resolve: impl Fn(&str) -> String) -> bool {
        let mut changed = false;

        // Helper: re-key an AdminLwwReg map device→master, merging on collision.
        fn fold_lww<V: Clone>(
            map: &mut HashMap<String, AdminLwwReg<V>>,
            resolve: &impl Fn(&str) -> String,
        ) -> bool {
            let mut changed = false;
            let keys: Vec<String> = map.keys().cloned().collect();
            for k in keys {
                let master = resolve(&k);
                if master == k {
                    continue; // already canonical (or unknown → self)
                }
                if let Some(dev_reg) = map.remove(&k) {
                    match map.get_mut(&master) {
                        Some(existing) => existing.merge(&dev_reg),
                        None => {
                            map.insert(master, dev_reg);
                        }
                    }
                    changed = true;
                }
            }
            changed
        }

        // members: keep existing master entry; else adopt device entry under master.
        {
            let keys: Vec<String> = self.members.keys().cloned().collect();
            for k in keys {
                let master = resolve(&k);
                if master == k {
                    continue;
                }
                if let Some(mut info) = self.members.remove(&k) {
                    info.peer_id = master.clone();
                    self.members.entry(master).or_insert(info);
                    changed = true;
                }
            }
        }

        // Adopt-only fold for the registers that carry authority over the master.
        fn adopt_lww<V: Clone>(
            map: &mut HashMap<String, AdminLwwReg<V>>,
            resolve: &impl Fn(&str) -> String,
            may_land: impl Fn(&str, &V) -> bool,
        ) -> bool {
            let mut changed = false;
            let keys: Vec<String> = map.keys().cloned().collect();
            for k in keys {
                let master = resolve(&k);
                if master == k || map.contains_key(&master) {
                    continue;
                }
                if map.get(&k).is_some_and(|reg| may_land(&master, reg.read()))
                    && let Some(reg) = map.remove(&k)
                {
                    map.insert(master, reg);
                    changed = true;
                }
            }
            changed
        }

        let owner = self.current_owner();
        let is_owner = |m: &str| owner.as_deref() == Some(m);
        let ranks: HashMap<String, MemberRole> = self
            .roles
            .iter()
            .map(|(k, reg)| (k.clone(), reg.read().clone()))
            .collect();
        let below_moderator = |m: &str| {
            ranks.get(m).is_none_or(|r| r.priority() < MemberRole::Moderator.priority())
        };
        changed |= adopt_lww(&mut self.roles, &resolve, |m, role| {
            !is_owner(m) && *role != MemberRole::Owner
        });
        changed |= fold_lww(&mut self.nicknames, &resolve);
        changed |= fold_lww(&mut self.twitch_usernames, &resolve);
        changed |= fold_lww(&mut self.storage_pledges, &resolve);
        changed |= adopt_lww(&mut self.banned_members, &resolve, |m, _| below_moderator(m));
        changed |= adopt_lww(&mut self.muted_members, &resolve, |m, _| below_moderator(m));
        // channel_grants: per-channel inner maps are master-keyed like mutes.
        for regs in self.channel_grants.values_mut() {
            changed |= fold_lww(regs, &resolve);
        }

        // label_assignments: Vec<label_id> per member — union under master.
        {
            let keys: Vec<String> = self.label_assignments.keys().cloned().collect();
            for k in keys {
                let master = resolve(&k);
                if master == k {
                    continue;
                }
                if let Some(labels) = self.label_assignments.remove(&k) {
                    let entry = self.label_assignments.entry(master).or_default();
                    for l in labels {
                        if !entry.contains(&l) {
                            entry.push(l);
                        }
                    }
                    changed = true;
                }
            }
        }

        changed
    }

    /// Restore op_log from DB-persisted ops, at startup.
    pub fn restore_op_log(&mut self, ops: Vec<CrdtOp>) {
        self.op_log = ops;
        self.op_log_dedup.clear();
        for op in &self.op_log {
            self.op_log_dedup.insert((op.author.clone(), op.hlc.clone()));
        }
    }

    /// Generate a new CrdtOp with our HLC, signed with our master key, but do NOT apply
    /// it: the caller applies after broadcasting.
    ///
    /// The signer is `expect`ed exactly the way the HLC is: an unsigned op is refused by
    /// every peer, so a missing signer must fail loudly rather than emit ops that
    /// silently vanish on the network.
    pub fn create_op(&mut self, payload: CrdtPayload) -> CrdtOp {
        let hlc = self
            .hlc
            .as_mut()
            .expect("HLC must be set before creating ops");
        let ts = hlc.now();
        let mut op = CrdtOp {
            server_id: self.server_id.clone(),
            hlc: ts,
            author: hlc.actor().to_string(),
            payload,
            auth: None,
        };
        let signer = self
            .signer
            .as_ref()
            .expect("signer must be set before creating ops");
        op.sign(&signer.keypair, &signer.pk_b64);
        op
    }

    /// The peer_id currently holding the Owner role, if any. A state with no
    /// Owner is either a fresh join skeleton or a server whose founding op has
    /// not arrived yet, and is the ONLY state a `ServerCreated` may act on.
    pub fn current_owner(&self) -> Option<String> {
        self.roles
            .iter()
            .find(|(_, reg)| *reg.read() == MemberRole::Owner)
            .map(|(pid, _)| pid.clone())
    }

    /// One op's whole judgment against the current state (signature, clock bound,
    /// permission matrix), as `ingest_remote` makes it op by op. Test-only: remote ops
    /// enter through `ingest_remote`, which judges each at its own point in the fold.
    #[cfg(test)]
    pub fn admit_remote_op(&self, op: &CrdtOp) -> Result<(), OpReject> {
        if op.server_id != self.server_id {
            return Err(OpReject::WrongServer);
        }
        op.verify_author()?;
        if op.hlc.physical_ms > super::hlc::wall_clock_ms() + super::hlc::MAX_DRIFT_MS {
            return Err(OpReject::FutureHlc);
        }
        if !self.op_allowed(op) {
            return Err(OpReject::NotAllowed);
        }
        Ok(())
    }

    /// Pull every LWW register in this state back inside the clock bound.
    ///
    /// A `ServerStateSnapshot` is adopted wholesale from one responder during a join, so
    /// its registers are only as honest as that peer, and a register stamped in the far
    /// future would outrank every later honest write forever. Clamping bounds the damage
    /// to "the value is wrong" instead of "the field is locked". Returns how many were
    /// pulled back. Exhaustive destructuring, like `lean_snapshot`, so a new field breaks
    /// this at compile time.
    pub fn clamp_future_hlcs(&mut self, now_ms: u64) -> usize {
        let max_ms = now_ms.saturating_add(super::hlc::MAX_DRIFT_MS);
        let mut clamped = 0usize;

        fn clamp_map<V: Clone>(map: &mut HashMap<String, AdminLwwReg<V>>, max_ms: u64) -> usize {
            let mut n = 0;
            for reg in map.values_mut() {
                if reg.clamp_hlc(max_ms) {
                    n += 1;
                }
            }
            n
        }

        let ServerState {
            name, roles, nicknames, twitch_usernames, storage_pledges, settings,
            role_permissions, banned_members, muted_members, channel_grants, join_secret, join_lock,
            // No timestamp of their own — these converge through the ops that
            // write them, never through an LWW register.
            server_id: _, channels: _, members: _, pinned_messages: _,
            channel_layout: _, labels: _, label_assignments: _, emotes: _,
            stickers: _, deleted: _, member_record: _, owner_pin: _,
            checkpoint_hlc: _, op_log: _, hlc: _, op_log_dedup: _, held: _,
            signer: _,
        } = self;

        if name.clamp_hlc(max_ms) {
            clamped += 1;
        }
        if join_secret.as_mut().is_some_and(|reg| reg.clamp_hlc(max_ms)) {
            clamped += 1;
        }
        clamped += join_lock.clamp_hlcs(max_ms);
        clamped += clamp_map(roles, max_ms);
        clamped += clamp_map(nicknames, max_ms);
        clamped += clamp_map(twitch_usernames, max_ms);
        clamped += clamp_map(storage_pledges, max_ms);
        clamped += clamp_map(settings, max_ms);
        clamped += clamp_map(role_permissions, max_ms);
        clamped += clamp_map(banned_members, max_ms);
        clamped += clamp_map(muted_members, max_ms);
        for regs in channel_grants.values_mut() {
            clamped += clamp_map(regs, max_ms);
        }
        clamped
    }

    /// Apply an op at the tail of the log, WITHOUT judging it: callers run
    /// `op_allowed` first (remote ingest goes through `ingest_remote`). Idempotent.
    ///
    /// `Ok(true)` when the op was new here and entered the op log: the ONE signal
    /// callers persist, emit and re-flood on. The log's length cannot say it, since at
    /// the legacy cap each insert drains an op. An op older than the whole retained
    /// legacy window drains straight back out and reports `false`, or two nodes would
    /// re-flood it to each other forever.
    pub fn apply_op(&mut self, op: &CrdtOp) -> Result<bool, String> {
        if op.server_id != self.server_id {
            return Err(format!(
                "Op server_id {} doesn't match {}",
                op.server_id, self.server_id
            ));
        }
        self.ensure_dedup();
        let dedup_key = (op.author.clone(), op.hlc.clone());
        if self.op_log_dedup.contains(&dedup_key) {
            return Ok(false);
        }
        if let Some(hlc) = &mut self.hlc {
            hlc.witness(&op.hlc);
        }
        self.apply_payload(op);
        self.log_admitted(op.clone());
        Ok(self.op_log_dedup.contains(&dedup_key))
    }

    /// The dedup set is not persisted: rebuild it from the log on first use.
    pub(super) fn ensure_dedup(&mut self) {
        if self.op_log_dedup.is_empty() && !self.op_log.is_empty() {
            self.op_log_dedup = self.op_log.iter().map(|o| (o.author.clone(), o.hlc.clone())).collect();
        }
    }

    /// Enter an applied op into the log in fold order. A legacy log is capped; an
    /// anchored one drops everything a checkpoint has overwritten instead.
    pub(super) fn log_admitted(&mut self, op: CrdtOp) {
        let pos = self
            .op_log
            .binary_search_by(|existing| fold_order(existing, &op))
            .unwrap_or_else(|pos| pos);
        self.op_log_dedup.insert((op.author.clone(), op.hlc.clone()));
        let is_checkpoint = matches!(op.payload, CrdtPayload::ServerCheckpoint { .. });
        self.op_log.insert(pos, op);
        if is_checkpoint {
            self.prune_before_checkpoint();
        } else if self.anchor() == Anchor::Legacy && self.op_log.len() > LEGACY_OP_LOG_CAP {
            let drain = self.op_log.len() - LEGACY_OP_LOG_CAP;
            self.op_log.drain(..drain);
            self.op_log_dedup = self.op_log.iter().map(|o| (o.author.clone(), o.hlc.clone())).collect();
        }
    }

    /// Drop every logged op the current checkpoint overwrote, except the founding op
    /// of a self-certifying id: a joiner needs it to prove who the owner is.
    pub(super) fn prune_before_checkpoint(&mut self) {
        let Some(base) = self.checkpoint_hlc.clone() else { return };
        let genesis = super::anchor::is_genesis_id(&self.server_id);
        self.op_log.retain(|o| match &o.payload {
            CrdtPayload::ServerCheckpoint { covers, .. } => *covers >= base,
            CrdtPayload::ServerCreated { .. } if genesis => true,
            _ => o.hlc > base,
        });
        self.op_log_dedup = self.op_log.iter().map(|o| (o.author.clone(), o.hlc.clone())).collect();
    }

    /// The state change an op makes, and nothing else: no dedup, no log, no judgment.
    /// The fold replays admitted ops through this in HLC order.
    pub(super) fn apply_payload(&mut self, op: &CrdtOp) {
        match &op.payload {
            CrdtPayload::ServerCreated { name, owner_peer_id, .. } => {
                // `op_allowed` admits a founding op only on an ownerless state; the
                // guard keeps a local replay path from re-seating anyone.
                if self.current_owner().is_none() {
                    self.seed_founder(name, owner_peer_id, &op.hlc);
                }
            }

            CrdtPayload::ServerCheckpoint { state, covers } => {
                if let Ok(base) = serde_json::from_str::<ServerState>(state) {
                    self.rebase_on(base, &op.author, covers);
                }
            }

            CrdtPayload::ServerRenamed { new_name } => {
                let priority = self.author_priority(&op.author);
                let remote = AdminLwwReg::new(new_name.clone(), op.hlc.clone(), priority);
                self.name.merge(&remote);
            }

            CrdtPayload::ServerSettingChanged { key, value } => {
                let priority = self.author_priority(&op.author);
                let entry = self
                    .settings
                    .entry(key.clone())
                    .or_insert_with(|| {
                        AdminLwwReg::new(value.clone(), op.hlc.clone(), priority)
                    });
                let remote = AdminLwwReg::new(value.clone(), op.hlc.clone(), priority);
                entry.merge(&remote);
            }

            CrdtPayload::JoinKeySet { secret } => {
                let remote = AdminLwwReg::new(secret.clone(), op.hlc.clone(), MemberRole::Owner.priority());
                match self.join_secret.as_mut() {
                    Some(reg) => reg.merge(&remote),
                    None => self.join_secret = Some(remote),
                }
            }

            CrdtPayload::JoinLock { link, door, grants } => {
                self.join_lock.apply(link, door.as_ref(), grants, &op.hlc);
            }

            CrdtPayload::ServerDeleted { .. } => {
                // Tombstone: latch `deleted` and drain membership so the server can no
                // longer be acted upon, but KEEP `server_id` and `op_log` so this node
                // keeps serving the deletion op to reconnecting peers. Owner-authorship
                // is validated at the INGEST sites: the CRDT layer has no transport
                // context.
                self.deleted = true;
                self.members.clear();
                self.roles.clear();
                self.channels.clear();
                self.nicknames.clear();
                self.twitch_usernames.clear();
                self.storage_pledges.clear();
                self.label_assignments.clear();
            }

            CrdtPayload::ChannelAdded {
                channel_id,
                name,
                category,
                channel_type,
            } => {
                let ct = match channel_type.as_str() {
                    "voice" => ChannelType::Voice,
                    _ => ChannelType::Text,
                };
                self.channels.entry(channel_id.clone()).or_insert_with(|| {
                    ChannelInfo {
                        channel_id: channel_id.clone(),
                        name: name.clone(),
                        category: category.clone(),
                        channel_type: ct,
                        visibility: ChannelVisibility::Everyone,
                        posting: ChannelPosting::Everyone,
                        is_public: false,
                        slow_mode: 0,
                        media_only: false,
                        visibility_labels: Vec::new(),
                        posting_labels: Vec::new(),
                    }
                });
            }

            CrdtPayload::ChannelRemoved { channel_id } => {
                self.channels.remove(channel_id);
            }

            CrdtPayload::ChannelRenamed {
                channel_id,
                new_name,
            } => {
                if let Some(ch) = self.channels.get_mut(channel_id) {
                    ch.name = new_name.clone();
                }
            }

            CrdtPayload::MemberAdded {
                peer_id,
                display_name,
                ask, ..
            } => {
                if !self.members.contains_key(peer_id) {
                    self.open_span(peer_id, op.hlc.physical_ms, ask.as_ref().map_or(0, |a| a.at));
                }
                self.members.entry(peer_id.clone()).or_insert_with(|| {
                    MemberInfo {
                        peer_id: peer_id.clone(),
                        display_name: display_name.clone(),
                    }
                });
                self.roles.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(
                        MemberRole::Member,
                        op.hlc.clone(),
                        MemberRole::Member.priority(),
                    )
                });
            }

            CrdtPayload::MemberRemoved { peer_id } => {
                if self.members.contains_key(peer_id) {
                    self.join_lock.note_removal(&op.hlc);
                }
                self.close_span(peer_id, op.hlc.physical_ms);
                self.members.remove(peer_id);
                self.roles.remove(peer_id);
                self.nicknames.remove(peer_id);
                self.twitch_usernames.remove(peer_id);
                self.storage_pledges.remove(peer_id);
            }

            // Closing a channel also takes it off the public list for good, so lifting
            // the restriction later never reopens it to guests.
            CrdtPayload::ChannelVisibilityChanged { channel_id, visibility } => {
                if let Some(ch) = self.channels.get_mut(channel_id) {
                    ch.visibility = match visibility.as_str() {
                        "moderator" => ChannelVisibility::ModeratorPlus,
                        "admin" => ChannelVisibility::AdminPlus,
                        _ => ChannelVisibility::Everyone,
                    };
                    ch.is_public &= !ch.restricted();
                }
            }

            CrdtPayload::ChannelPostingChanged { channel_id, posting } => {
                if let Some(ch) = self.channels.get_mut(channel_id) {
                    ch.posting = match posting.as_str() {
                        "moderator" => ChannelPosting::ModeratorPlus,
                        "admin" => ChannelPosting::AdminPlus,
                        _ => ChannelPosting::Everyone,
                    };
                }
            }

            CrdtPayload::ChannelPublicChanged { channel_id, is_public } => {
                if let Some(ch) = self.channels.get_mut(channel_id) {
                    // Voice channels can never be public (#44) — drop the flag
                    // at apply so a pre-guard client's op can't wedge one in.
                    if ch.channel_type == ChannelType::Text {
                        ch.is_public = *is_public;
                    }
                }
            }

            CrdtPayload::ChannelSlowModeChanged { channel_id, seconds } => {
                if let Some(ch) = self.channels.get_mut(channel_id) {
                    ch.slow_mode = *seconds;
                }
            }

            CrdtPayload::ChannelMediaOnlyChanged { channel_id, media_only } => {
                if let Some(ch) = self.channels.get_mut(channel_id) {
                    ch.media_only = *media_only;
                }
            }

            CrdtPayload::ChannelVisibilityLabelsChanged { channel_id, labels } => {
                if let Some(ch) = self.channels.get_mut(channel_id) {
                    ch.visibility_labels = labels.clone();
                    ch.is_public &= !ch.restricted();
                }
            }

            CrdtPayload::ChannelPostingLabelsChanged { channel_id, labels } => {
                if let Some(ch) = self.channels.get_mut(channel_id) {
                    ch.posting_labels = labels.clone();
                }
            }

            CrdtPayload::ChannelGrantSet { channel_id, peer_id, expires_at } => {
                let priority = self.author_priority(&op.author);
                let per_chan = self.channel_grants.entry(channel_id.clone()).or_default();
                let entry = per_chan.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(*expires_at, op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(*expires_at, op.hlc.clone(), priority);
                entry.merge(&remote);
            }

            CrdtPayload::ChannelGrantRevoked { channel_id, peer_id } => {
                let priority = self.author_priority(&op.author);
                let per_chan = self.channel_grants.entry(channel_id.clone()).or_default();
                let entry = per_chan.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(0u64, op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(0u64, op.hlc.clone(), priority);
                entry.merge(&remote);
                // Prune (mirrors MemberUnmuted): only this arm can flip a
                // register to 0, so the sweep lives only here. A newer grant
                // wins the merge above and survives the retain.
                per_chan.retain(|_, reg| *reg.read() != 0);
                if per_chan.is_empty() {
                    self.channel_grants.remove(channel_id);
                }
            }

            CrdtPayload::RoleChanged {
                peer_id,
                role,
                priority,
            } => {
                // The payload's `priority` is inert wire-compat metadata: merge is pure
                // HLC LWW and authority is enforced by can_change_role at author and
                // ingest. Old clients still merge priority-first, so keep sending it.
                // Old clients still merge priority-first, so keep sending it.
                let was_moderation = self.roles.get(peer_id).is_some_and(|r| r.read().priority() >= MemberRole::Moderator.priority());
                let entry = self.roles.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(role.clone(), op.hlc.clone(), *priority)
                });
                let remote = AdminLwwReg::new(role.clone(), op.hlc.clone(), *priority);
                entry.merge(&remote);
                // A demoted mod still holds the change key the lock must now leave behind.
                if was_moderation && entry.read().priority() < MemberRole::Moderator.priority() {
                    self.join_lock.note_removal(&op.hlc);
                }
            }

            CrdtPayload::NicknameChanged { peer_id, nickname } => {
                // Any member can set their own nickname. Use author's priority
                // so admins can also change others' nicknames.
                let priority = self.author_priority(&op.author);
                let entry = self.nicknames.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(nickname.clone(), op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(nickname.clone(), op.hlc.clone(), priority);
                entry.merge(&remote);
            }

            CrdtPayload::TwitchUsernameChanged { peer_id, twitch_username } => {
                let priority = self.author_priority(&op.author);
                let entry = self.twitch_usernames.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(twitch_username.clone(), op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(twitch_username.clone(), op.hlc.clone(), priority);
                entry.merge(&remote);
            }

            CrdtPayload::ChannelLayoutUpdated { layout_json } => {
                if let Ok(layout) = serde_json::from_str::<Vec<ChannelLayoutItem>>(layout_json) {
                    self.channel_layout = layout;
                }
            }

            CrdtPayload::MessagePinned { channel_id, message_id } => {
                let pins = self.pinned_messages.entry(channel_id.clone()).or_default();
                if !pins.contains(message_id) {
                    pins.push(message_id.clone());
                }
            }

            CrdtPayload::MessageUnpinned { channel_id, message_id } => {
                if let Some(pins) = self.pinned_messages.get_mut(channel_id) {
                    pins.retain(|id| id != message_id);
                    if pins.is_empty() {
                        self.pinned_messages.remove(channel_id);
                    }
                }
            }

            CrdtPayload::StoragePledgeChanged { peer_id, pledge_bytes } => {
                let priority = self.author_priority(&op.author);
                let entry = self.storage_pledges.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(*pledge_bytes, op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(*pledge_bytes, op.hlc.clone(), priority);
                entry.merge(&remote);
            }

            CrdtPayload::RolePermissionsChanged { role, permissions } => {
                let priority = self.author_priority(&op.author);
                let entry = self.role_permissions.entry(role.clone()).or_insert_with(|| {
                    AdminLwwReg::new(*permissions, op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(*permissions, op.hlc.clone(), priority);
                entry.merge(&remote);
            }

            CrdtPayload::MemberBanned { peer_id } => {
                let priority = self.author_priority(&op.author);
                let entry = self.banned_members.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(true, op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(true, op.hlc.clone(), priority);
                entry.merge(&remote);
                // Also remove from server (ban = kick + prevent rejoin)
                if self.members.contains_key(peer_id) {
                    self.join_lock.note_removal(&op.hlc);
                }
                self.close_span(peer_id, op.hlc.physical_ms);
                self.members.remove(peer_id);
                self.roles.remove(peer_id);
                self.nicknames.remove(peer_id);
                self.twitch_usernames.remove(peer_id);
                self.storage_pledges.remove(peer_id);
            }

            CrdtPayload::MemberUnbanned { peer_id } => {
                let priority = self.author_priority(&op.author);
                let entry = self.banned_members.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(false, op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(false, op.hlc.clone(), priority);
                entry.merge(&remote);
                // Prune unbanned members to prevent unbounded growth. Only this
                // arm can flip a register to false, so the sweep lives here
                // instead of running on every op. LWW-aware: a newer ban wins
                // the merge above and survives the retain.
                self.banned_members.retain(|_, reg| *reg.read());
            }

            CrdtPayload::MemberMuted { peer_id, expires_at } => {
                let priority = self.author_priority(&op.author);
                let entry = self.muted_members.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(*expires_at, op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(*expires_at, op.hlc.clone(), priority);
                entry.merge(&remote);
            }

            CrdtPayload::MemberUnmuted { peer_id } => {
                let priority = self.author_priority(&op.author);
                let entry = self.muted_members.entry(peer_id.clone()).or_insert_with(|| {
                    AdminLwwReg::new(0u64, op.hlc.clone(), priority)
                });
                let remote = AdminLwwReg::new(0u64, op.hlc.clone(), priority);
                entry.merge(&remote);
                // Prune unmuted entries to prevent unbounded growth. Mirrors the
                // MemberUnbanned sweep: only this arm can flip a register to 0,
                // and a newer mute wins the merge above and survives the retain.
                self.muted_members.retain(|_, reg| *reg.read() != 0);
            }

            CrdtPayload::LabelCreated { label_id, name, color, access } => {
                self.labels.entry(label_id.clone()).or_insert_with(|| {
                    LabelInfo {
                        label_id: label_id.clone(),
                        name: name.clone(),
                        color: color.clone(),
                        access: *access,
                    }
                });
            }

            CrdtPayload::LabelDeleted { label_id } => {
                self.labels.remove(label_id);
                for assignments in self.label_assignments.values_mut() {
                    assignments.retain(|id| id != label_id);
                }
            }

            CrdtPayload::LabelUpdated { label_id, name, color, access } => {
                if let Some(label) = self.labels.get_mut(label_id) {
                    label.name = name.clone();
                    label.color = color.clone();
                    // None = the author predates the flag — PRESERVE it. An
                    // old client recoloring an access label must not silently
                    // demote it to cosmetic (that re-opens self-assignment).
                    if let Some(a) = access {
                        label.access = *a;
                    }
                }
            }

            CrdtPayload::LabelAssigned { label_id, peer_id } => {
                let assignments = self.label_assignments.entry(peer_id.clone()).or_default();
                if !assignments.contains(label_id) {
                    assignments.push(label_id.clone());
                }
            }

            CrdtPayload::LabelUnassigned { label_id, peer_id } => {
                if let Some(assignments) = self.label_assignments.get_mut(peer_id) {
                    assignments.retain(|id| id != label_id);
                    if assignments.is_empty() {
                        self.label_assignments.remove(peer_id);
                    }
                }
            }

            CrdtPayload::EmojiAdded { name, hash, animated } => {
                // Replace-on-same-name (re-adding a name swaps the image);
                // refuse NEW names past the cap so replicas converge on the
                // same refusal regardless of op arrival order relative to
                // other adds already in the log.
                let is_new = !self.emotes.contains_key(name);
                if !is_new || self.emotes.len() < MAX_SERVER_EMOTES {
                    self.emotes.insert(
                        name.clone(),
                        EmoteInfo {
                            name: name.clone(),
                            hash: hash.clone(),
                            animated: *animated,
                        },
                    );
                }
            }

            CrdtPayload::EmojiRemoved { name } => {
                self.emotes.remove(name);
            }

            CrdtPayload::StickerAdded { hash, name, pack, animated, w, h } => {
                // Same convergence rule as emotes: replacing an existing
                // entry always applies, a NEW one only under the cap, so
                // replicas refuse identically regardless of arrival order.
                let is_new = !self.stickers.contains_key(hash);
                if !is_new || self.stickers.len() < MAX_SERVER_STICKERS {
                    self.stickers.insert(
                        hash.clone(),
                        StickerInfo {
                            hash: hash.clone(),
                            name: name.clone(),
                            pack: pack.clone(),
                            animated: *animated,
                            w: *w,
                            h: *h,
                        },
                    );
                }
            }

            CrdtPayload::StickerRemoved { hash } => {
                self.stickers.remove(hash);
            }
        }
    }

    /// Replace everything materialized with a checkpoint's state. The anchor owner is
    /// the checkpoint's author; the log, clock, signer and held ops are ours.
    fn rebase_on(&mut self, base: ServerState, owner: &str, covers: &HlcTimestamp) {
        let ServerState {
            server_id: _, name, channels, members, roles, nicknames,
            twitch_usernames, pinned_messages, channel_layout, storage_pledges,
            settings, role_permissions, banned_members, muted_members,
            channel_grants, labels, label_assignments, emotes, stickers, deleted,
            member_record, join_secret, join_lock,
            owner_pin: _, checkpoint_hlc: _, op_log: _, hlc: _, op_log_dedup: _,
            held: _, signer: _,
        } = base;
        self.name = name;
        self.channels = channels;
        self.members = members;
        self.roles = roles;
        self.nicknames = nicknames;
        self.twitch_usernames = twitch_usernames;
        self.pinned_messages = pinned_messages;
        self.channel_layout = channel_layout;
        self.storage_pledges = storage_pledges;
        self.settings = settings;
        self.role_permissions = role_permissions;
        self.banned_members = banned_members;
        self.muted_members = muted_members;
        self.channel_grants = channel_grants;
        self.labels = labels;
        self.label_assignments = label_assignments;
        self.emotes = emotes;
        self.stickers = stickers;
        self.deleted = deleted;
        self.member_record = member_record;
        self.join_secret = join_secret;
        self.join_lock = join_lock;
        self.owner_pin = Some(owner.to_string());
        self.checkpoint_hlc = Some(covers.clone());
        // The owner is trusted with the values, never with timestamps that would
        // outrank every later honest write.
        self.clamp_future_hlcs(covers.physical_ms);
    }

    /// Everything materialized back to the ownerless skeleton, keeping the anchor
    /// owner, the log, the clock and the signer: where a rebuild starts.
    pub(super) fn reset_materialized(&mut self) {
        let fresh = Self::skeleton(self.server_id.clone());
        let ServerState {
            server_id: _, name, channels, members, roles, nicknames,
            twitch_usernames, pinned_messages, channel_layout, storage_pledges,
            settings, role_permissions, banned_members, muted_members,
            channel_grants, labels, label_assignments, emotes, stickers, deleted,
            member_record, join_secret, join_lock, checkpoint_hlc,
            owner_pin: _, op_log: _, hlc: _, op_log_dedup: _, held: _, signer: _,
        } = fresh;
        self.name = name;
        self.channels = channels;
        self.members = members;
        self.roles = roles;
        self.nicknames = nicknames;
        self.twitch_usernames = twitch_usernames;
        self.pinned_messages = pinned_messages;
        self.channel_layout = channel_layout;
        self.storage_pledges = storage_pledges;
        self.settings = settings;
        self.role_permissions = role_permissions;
        self.banned_members = banned_members;
        self.muted_members = muted_members;
        self.channel_grants = channel_grants;
        self.labels = labels;
        self.label_assignments = label_assignments;
        self.emotes = emotes;
        self.stickers = stickers;
        self.deleted = deleted;
        self.member_record = member_record;
        self.join_secret = join_secret;
        self.join_lock = join_lock;
        self.checkpoint_hlc = checkpoint_hlc;
    }

    /// List all channels, sorted by name.
    pub fn channels_list(&self) -> Vec<&ChannelInfo> {
        let mut list: Vec<_> = self.channels.values().collect();
        list.sort_by(|a, b| a.name.cmp(&b.name));
        list
    }

    /// List all members, sorted by display name.
    pub fn members_list(&self) -> Vec<&MemberInfo> {
        let mut list: Vec<_> = self.members.values().collect();
        list.sort_by(|a, b| a.display_name.cmp(&b.display_name));
        list
    }

    /// Get a member's role.
    pub fn get_role(&self, peer_id: &str) -> MemberRole {
        // Multi-device: collapse a device id to its master before the keyed lookup
        // (roles are master-keyed). Identity-passthrough for unknowns / single-device.
        let key = super::resolve_identity(peer_id);
        self.roles
            .get(&key)
            .map(|reg| reg.read().clone())
            .unwrap_or(MemberRole::Member)
    }

    /// Get the server name.
    pub fn name(&self) -> &str {
        self.name.read()
    }

    /// Get a member's server nickname (empty string = no nickname set).
    pub fn get_nickname(&self, peer_id: &str) -> String {
        self.nicknames
            .get(peer_id)
            .map(|reg| reg.read().clone())
            .unwrap_or_default()
    }

    pub fn get_twitch_username(&self, peer_id: &str) -> String {
        self.twitch_usernames
            .get(peer_id)
            .map(|reg| reg.read().clone())
            .unwrap_or_default()
    }

    /// Get pinned message IDs for a channel.
    pub fn get_pinned_messages(&self, channel_id: &str) -> Vec<String> {
        self.pinned_messages
            .get(channel_id)
            .cloned()
            .unwrap_or_default()
    }

    /// Get a member's storage pledge in bytes. Returns 0 if not set.
    pub fn get_storage_pledge(&self, peer_id: &str) -> u64 {
        self.storage_pledges
            .get(peer_id)
            .map(|reg| *reg.read())
            .unwrap_or(0)
    }

    /// Get the total storage pledged by all members (bytes).
    pub fn total_pledged_bytes(&self) -> u64 {
        self.storage_pledges.values().map(|reg| *reg.read()).sum()
    }

    /// Get the minimum pledge setting (MB). Returns 512 if not configured.
    pub fn min_pledge_mb(&self) -> u64 {
        self.settings
            .get("min_pledge_mb")
            .and_then(|reg| reg.read().parse::<u64>().ok())
            .unwrap_or(512)
    }

    /// Relay offline catch-up retention in seconds, DEFAULT ON at 3 days when the setting
    /// is absent (users will not find the toggle and would assume offline delivery is
    /// broken); an explicit "0" means the owner turned it OFF. When >0, member clients
    /// register the server's text channels with the relay's ring buffer, which stays an
    /// availability helper (same signed bytes, receiver verifies and dedups), never a
    /// source of truth.
    pub fn relay_catchup_secs(&self) -> i64 {
        self.settings
            .get("relay_catchup_secs")
            .and_then(|reg| reg.read().parse::<i64>().ok())
            .unwrap_or(3 * 86400)
            .max(0)
    }

    /// Whether the server is private (invite-only). Defaults to public.
    /// Stored in `settings["is_private"]` as "true"/"false".
    pub fn is_private(&self) -> bool {
        self.settings
            .get("is_private")
            .map(|reg| reg.read() == "true")
            .unwrap_or(false)
    }

    /// Whether the server is flagged NSFW (adult/sensitive content). Defaults to
    /// false. Stored in `settings["is_nsfw"]` as "true"/"false". Used to gate
    /// joining with a "proceed at your own risk" consent prompt.
    pub fn is_nsfw(&self) -> bool {
        self.settings
            .get("is_nsfw")
            .map(|reg| reg.read() == "true")
            .unwrap_or(false)
    }

    /// Owner-configured max member count. `None` = unlimited (default).
    /// Stored in `settings["max_members"]`; 0 or unparseable = unlimited.
    pub fn max_members(&self) -> Option<u32> {
        self.settings
            .get("max_members")
            .and_then(|reg| reg.read().parse::<u32>().ok())
            .filter(|&n| n > 0)
    }

    /// Look up an author's priority from their role, resolving a DEVICE-id author to its
    /// master first so LWW priority works for replayed legacy ops. Unknown authors stay
    /// at 0, deliberately BELOW plain members, so do not route this via `get_role`, which
    /// defaults unknowns to `Member`. Ban and mute registers keep it: lifting one needs
    /// at least the rank that set it.
    /// The join secret the Owner set, if any.
    pub fn join_secret(&self) -> Option<zeroize::Zeroizing<[u8; 32]>> {
        join_secret_shape(&self.join_secret.as_ref()?.read().0)
    }

    /// The public half of the join secret, as invite links carry it.
    pub fn join_public_text(&self) -> Option<String> {
        let secret = self.join_secret()?;
        Some(crate::node::sealed_box::key_to_text(&crate::node::sealed_box::public_of(&secret)))
    }

    /// The founding nonce of a self-certifying id: its founding op is never pruned.
    pub fn founding_nonce(&self) -> Option<String> {
        self.op_log.iter().find_map(|op| match &op.payload {
            CrdtPayload::ServerCreated { nonce, .. } if !nonce.is_empty() => Some(nonce.clone()),
            _ => None,
        })
    }

    /// Whether `master` is the owner, an admin or a mod: who holds the change key.
    pub fn holds_moderation(&self, master: &str) -> bool {
        self.members.contains_key(master)
            && self.roles.get(master).is_some_and(|r| r.read().priority() >= MemberRole::Moderator.priority())
    }

    /// Every owner, admin and mod, by master.
    pub fn moderation_masters(&self) -> Vec<String> {
        let mut masters: Vec<String> = self.members.keys().filter(|m| self.holds_moderation(m)).cloned().collect();
        masters.sort();
        masters
    }

    /// A join lock op: from an owner, admin or mod; an owner-signed link only from
    /// the owner; any other link a successor of one we hold; a door only its own
    /// secret; grants only to owners, admins and mods.
    fn join_lock_allowed(
        &self,
        op: &CrdtOp,
        role: &MemberRole,
        link: &crate::node::join_lock::LockLink,
        door: Option<&super::operations::JoinSecret>,
        grants: &std::collections::BTreeMap<String, String>,
    ) -> bool {
        let Some(owner) = self.anchor_owner() else { return false };
        role.priority() >= MemberRole::Moderator.priority()
            && (!link.is_base() || (*role == MemberRole::Owner && op.author == owner))
            && self.join_lock.link_allowed(&self.server_id, link, &owner)
            && door.is_none_or(|d| super::lock_state::door_matches(d, link))
            && grants.len() <= 64
            && grants.iter().all(|(master, grant)| {
                crate::node::join_lock::grant_shape(grant) && self.holds_moderation(master)
            })
    }

    fn author_priority(&self, author: &str) -> u8 {
        let key = super::resolve_identity(author);
        self.roles
            .get(&key)
            .map(|reg| reg.read().priority())
            .unwrap_or(0)
    }

    /// Effective permissions bitmask for a peer: Owner gets all, otherwise custom
    /// `role_permissions` first and the role defaults after.
    pub fn get_permissions(&self, peer_id: &str) -> u32 {
        self.permissions_of(&self.get_role(peer_id))
    }

    fn permissions_of(&self, role: &MemberRole) -> u32 {
        if *role == MemberRole::Owner {
            return Permission::ALL;
        }
        self.role_permissions
            .get(role.as_str())
            .map(|reg| *reg.read())
            .unwrap_or_else(|| role.default_permissions())
    }

    /// Get the permissions bitmask for a role (custom or default).
    pub fn get_role_permissions(&self, role: &str) -> u32 {
        if role == "owner" {
            return Permission::ALL;
        }
        if let Some(reg) = self.role_permissions.get(role) {
            return *reg.read();
        }
        MemberRole::from_str(role).default_permissions()
    }

    /// Check if a peer has a specific permission.
    pub fn has_permission(&self, peer_id: &str, permission: u32) -> bool {
        self.get_permissions(peer_id) & permission != 0
    }

    /// The role an op's author acts with, read by its OWN id and never through the
    /// resolver: every client signs ops with its master key, so a device key has no
    /// role (E9). `None` for anyone who is not a current member (E6).
    fn author_role(&self, author: &str) -> Option<MemberRole> {
        self.members.contains_key(author).then(|| {
            self.roles
                .get(author)
                .map(|reg| reg.read().clone())
                .unwrap_or(MemberRole::Member)
        })
    }

    /// Check if `actor` can change `target`'s role to `new_role`: never to or from
    /// Owner, only for a current member, and below the actor's own rank on both ends
    /// unless the actor is the Owner.
    pub fn can_change_role(&self, actor: &str, target: &str, new_role: &MemberRole) -> bool {
        let role = self.get_role(actor);
        self.role_change_allowed(&role, self.permissions_of(&role), target, new_role)
    }

    fn role_change_allowed(&self, actor: &MemberRole, perms: u32, target: &str, new_role: &MemberRole) -> bool {
        let target_role = self.get_role(target);
        // The owner is fixed for the life of the server (E12).
        if *new_role == MemberRole::Owner || target_role == MemberRole::Owner || !self.is_member(target) {
            return false;
        }
        *actor == MemberRole::Owner
            || (perms & Permission::MANAGE_ROLES != 0
                && actor.outranks(&target_role)
                && actor.outranks(new_role))
    }

    /// Check if `actor` can kick `target`: never the Owner, and otherwise KICK_MEMBERS
    /// plus outranking the target.
    pub fn can_kick(&self, actor: &str, target: &str) -> bool {
        let role = self.get_role(actor);
        self.kick_allowed(&role, self.permissions_of(&role), target)
    }

    fn kick_allowed(&self, actor: &MemberRole, perms: u32, target: &str) -> bool {
        let target_role = self.get_role(target);
        target_role != MemberRole::Owner
            && (*actor == MemberRole::Owner
                || (perms & Permission::KICK_MEMBERS != 0 && actor.outranks(&target_role)))
    }

    /// Check if a peer is currently banned.
    pub fn is_banned(&self, peer_id: &str) -> bool {
        // Multi-device: bans are master-keyed; collapse a device id first.
        let key = super::resolve_identity(peer_id);
        self.banned_members
            .get(&key)
            .map(|reg| *reg.read())
            .unwrap_or(false)
    }

    /// Whether this server has been tombstoned (a `ServerDeleted` op applied). The
    /// UI must hide tombstoned servers; the node still retains the shell to serve
    /// the deletion op to reconnecting peers.
    pub fn is_deleted(&self) -> bool {
        self.deleted
    }

    /// Multi-device-safe membership check: is `peer_id` (device OR master) a member?
    /// Collapses to master before the keyed lookup. Use this instead of
    /// `members.contains_key(...)` anywhere the arg may be a device id.
    pub fn is_member(&self, peer_id: &str) -> bool {
        let key = super::resolve_identity(peer_id);
        self.members.contains_key(&key)
    }

    /// Check if `actor` can ban `target`. Same hierarchy as kick.
    pub fn can_ban(&self, actor: &str, target: &str) -> bool {
        self.can_kick(actor, target)
    }

    /// May `author` set `key` to `value`? The ONE rule for authoring and ingest alike.
    ///
    /// Retention decides what every member's sweep deletes, so only the Owner writes it,
    /// and a policy only with a value the app offers (decision 2c). Every other key is
    /// MANAGE_SERVER, override-aware.
    pub fn setting_change_allowed(&self, author: &str, key: &str, value: &str) -> bool {
        let role = self.get_role(author);
        self.setting_allowed_for(&role, self.permissions_of(&role), key, value)
    }

    fn setting_allowed_for(&self, role: &MemberRole, perms: u32, key: &str, value: &str) -> bool {
        match key {
            "retention_files" | "retention_messages" => {
                *role == MemberRole::Owner
                    && crate::vault::adaptive::RETENTION_CHOICES.contains(&value)
            }
            "retention_files_since" | "retention_messages_since" => {
                *role == MemberRole::Owner && value.parse::<u64>().is_ok()
            }
            _ => perms & Permission::MANAGE_SERVER != 0,
        }
    }

    /// The ingest permission matrix: may `op.author` apply this op to this server? Shared
    /// by every remote ingest path, the fold, and our own authoring (`author_checked`),
    /// so an honest client never authors what honest peers refuse.
    ///
    /// Validates the AUTHOR, never the transport sender: ops are legitimately relayed by
    /// other peers during join and sync fan-out. Override-aware (`permissions_of`, not
    /// `default_permissions()`).
    pub fn op_allowed(&self, op: &CrdtOp) -> bool {
        match &op.payload {
            CrdtPayload::ServerCreated { owner_peer_id, nonce, .. } => {
                return self.founding_allowed(op, owner_peer_id, nonce);
            }
            CrdtPayload::ServerCheckpoint { state, covers } => {
                return self.checkpoint_allowed(op, state, covers);
            }
            _ => {}
        }
        let Some(role) = self.author_role(&op.author) else { return false };
        let perms = self.permissions_of(&role);
        let has = |bits: u32| perms & bits != 0;
        match &op.payload {
            CrdtPayload::ServerCreated { .. } | CrdtPayload::ServerCheckpoint { .. } => false,
            CrdtPayload::ChannelAdded { .. }
            | CrdtPayload::ChannelRemoved { .. }
            | CrdtPayload::ChannelRenamed { .. }
            | CrdtPayload::ChannelLayoutUpdated { .. }
            | CrdtPayload::MessagePinned { .. }
            | CrdtPayload::MessageUnpinned { .. }
            | CrdtPayload::ChannelVisibilityChanged { .. }
            | CrdtPayload::ChannelPostingChanged { .. }
            | CrdtPayload::ChannelSlowModeChanged { .. }
            | CrdtPayload::ChannelMediaOnlyChanged { .. }
            | CrdtPayload::ChannelVisibilityLabelsChanged { .. }
            | CrdtPayload::ChannelPostingLabelsChanged { .. }
            | CrdtPayload::ChannelGrantSet { .. }
            | CrdtPayload::ChannelGrantRevoked { .. } => has(Permission::MANAGE_CHANNELS),
            CrdtPayload::RoleChanged { peer_id, role: new_role, .. } => {
                self.role_change_allowed(&role, perms, peer_id, new_role)
            }
            CrdtPayload::ServerRenamed { .. } => has(Permission::MANAGE_SERVER),
            CrdtPayload::JoinKeySet { secret } => role == MemberRole::Owner && join_secret_shape(&secret.0).is_some(),
            CrdtPayload::JoinLock { link, door, grants } => self.join_lock_allowed(op, &role, link, door.as_ref(), grants),
            CrdtPayload::ServerSettingChanged { key, value } => {
                self.setting_allowed_for(&role, perms, key, value)
            }
            // Voluntary leave for everyone but the Owner, who deletes instead.
            CrdtPayload::MemberRemoved { peer_id } if *peer_id == op.author => {
                role != MemberRole::Owner
            }
            CrdtPayload::MemberRemoved { peer_id }
            | CrdtPayload::MemberBanned { peer_id }
            | CrdtPayload::MemberMuted { peer_id, .. } => self.kick_allowed(&role, perms, peer_id),
            CrdtPayload::MemberUnbanned { peer_id } => {
                has(Permission::KICK_MEMBERS)
                    && self.lifts_register(&role, self.banned_members.get(&super::resolve_identity(peer_id)))
            }
            CrdtPayload::MemberUnmuted { peer_id } => {
                self.kick_allowed(&role, perms, peer_id)
                    && self.lifts_register(&role, self.muted_members.get(&super::resolve_identity(peer_id)))
            }
            CrdtPayload::MemberAdded { peer_id, follow, ask, .. } => {
                self.admission_allowed(&role, op, peer_id, follow.as_deref(), ask.as_ref())
            }
            // Self, or Owner/Admin over a member ranked below them (never the Owner).
            CrdtPayload::NicknameChanged { peer_id, .. }
            | CrdtPayload::TwitchUsernameChanged { peer_id, .. }
            | CrdtPayload::StoragePledgeChanged { peer_id, .. } => {
                *peer_id == op.author
                    || (matches!(role, MemberRole::Owner | MemberRole::Admin)
                        && self.is_member(peer_id)
                        && role.outranks(&self.get_role(peer_id)))
            }
            // A named role below the author's own, granting only bits the author holds.
            CrdtPayload::RolePermissionsChanged { role: target, permissions } => {
                let target = match target.as_str() {
                    "admin" => MemberRole::Admin,
                    "moderator" => MemberRole::Moderator,
                    "member" => MemberRole::Member,
                    _ => return false,
                };
                has(Permission::MANAGE_ROLES)
                    && role.outranks(&target)
                    && permissions & !perms == 0
            }
            CrdtPayload::ChannelPublicChanged { channel_id, is_public } => {
                // Voice channels can never be public (#44), nor restricted ones (D6).
                // Unknown channel id passes (apply is a no-op there).
                has(Permission::MANAGE_CHANNELS)
                    && self
                        .channels
                        .get(channel_id)
                        .is_none_or(|ch| ch.channel_type == ChannelType::Text && !(*is_public && ch.restricted()))
            }
            CrdtPayload::LabelCreated { .. }
            | CrdtPayload::LabelDeleted { .. }
            | CrdtPayload::LabelUpdated { .. } => has(Permission::MANAGE_ROLES),
            // Self-toggle only for existing COSMETIC labels; access labels and unknown
            // ids need MANAGE_ROLES. An assignment lands only on a current member.
            CrdtPayload::LabelAssigned { label_id, peer_id } => {
                self.is_member(peer_id)
                    && (self.self_toggles(&op.author, peer_id, label_id) || has(Permission::MANAGE_ROLES))
            }
            CrdtPayload::LabelUnassigned { label_id, peer_id } => {
                self.self_toggles(&op.author, peer_id, label_id) || has(Permission::MANAGE_ROLES)
            }
            CrdtPayload::EmojiAdded { name, hash, .. } => {
                has(Permission::MANAGE_EMOTES)
                    && super::valid_emote_name(name)
                    && super::valid_emote_hash(hash)
            }
            // Stickers reuse MANAGE_EMOTES rather than adding a permission bit.
            CrdtPayload::StickerAdded { hash, name, pack, w, h, .. } => {
                has(Permission::MANAGE_EMOTES)
                    && super::valid_emote_hash(hash)
                    && valid_sticker_label(name)
                    && valid_sticker_label(pack)
                    // Dimensions ride the `[a:s:hash:w:h]` token, whose grammar tops
                    // out at 4 digits, so a row we could not render has no business
                    // replicating.
                    && (1..=4096).contains(w)
                    && (1..=4096).contains(h)
            }
            CrdtPayload::EmojiRemoved { .. } | CrdtPayload::StickerRemoved { .. } => {
                has(Permission::MANAGE_EMOTES)
            }
            CrdtPayload::ServerDeleted { .. } => role == MemberRole::Owner,
        }
    }

    /// Lifting a ban or mute needs at least the rank that set it.
    fn lifts_register<V: Clone>(&self, role: &MemberRole, reg: Option<&AdminLwwReg<V>>) -> bool {
        reg.is_none_or(|r| role.priority() >= r.priority())
    }

    fn self_toggles(&self, author: &str, target: &str, label_id: &str) -> bool {
        author == target && self.labels.get(label_id).is_some_and(|l| !l.access)
    }

    /// E7: the join gates the admitter ran, re-checked by every member against the
    /// state at the op's own point in the fold. Any member may admit (owner-offline
    /// joins keep working); nobody admits past a ban, a private server, the member
    /// cap, owner-verify or the Twitch follow gate. D3: nor anyone but the identity
    /// that signed the ask, with an ask newer than every one that admitted it before.
    fn admission_allowed(
        &self,
        author: &MemberRole,
        op: &CrdtOp,
        target: &str,
        follow: Option<&str>,
        ask: Option<&super::operations::JoinAsk>,
    ) -> bool {
        let Some(ask) = ask.filter(|a| a.verifies(&self.server_id, target)) else {
            return false;
        };
        if self.is_banned(target) {
            return false;
        }
        if self.is_member(target) {
            return true;
        }
        if self.member_record.get(target).is_some_and(|spans| spans.iter().any(|s| ask.at <= s.asked_at)) {
            return false;
        }
        if self.is_private() || self.max_members().is_some_and(|max| self.members.len() as u32 >= max) {
            return false;
        }
        match crate::node::twitch::TwitchServerSettings::from_server_state(self) {
            None => true,
            Some(tw) => {
                (!tw.owner_verify || *author == MemberRole::Owner)
                    && follow.is_some_and(|entry| {
                        crate::node::twitch::follow_credential_admits_at(entry, target, &tw, op.hlc.physical_ms)
                    })
            }
        }
    }

    /// The founding op: only on an ownerless state, only from the owner it names, and
    /// only for the anchor, which for a self-certifying id is the key that hashes to it
    /// and otherwise the pinned owner, when there is one.
    fn founding_allowed(&self, op: &CrdtOp, owner: &str, nonce: &str) -> bool {
        op.author == owner
            && self.current_owner().is_none()
            && if super::anchor::is_genesis_id(&self.server_id) {
                super::anchor::derive_server_id(owner, nonce) == self.server_id
            } else {
                self.owner_pin.as_deref().is_none_or(|pin| pin == owner)
            }
    }

    /// A checkpoint: only from the anchor owner (first use, on a 32-hex id with nothing
    /// known, is trust on first use), covering no later than its own clock and more
    /// than the one we stand on, and a state of THIS server whose one Owner is its author.
    fn checkpoint_allowed(&self, op: &CrdtOp, state: &str, covers: &HlcTimestamp) -> bool {
        match self.anchor_owner() {
            Some(owner) if owner != op.author => return false,
            None if super::anchor::is_genesis_id(&self.server_id) => return false,
            _ => {}
        }
        if *covers > op.hlc || self.checkpoint_hlc.as_ref().is_some_and(|base| covers <= base) {
            return false;
        }
        let Ok(base) = serde_json::from_str::<ServerState>(state) else { return false };
        let owners: Vec<&String> = base
            .roles
            .iter()
            .filter(|(_, reg)| *reg.read() == MemberRole::Owner)
            .map(|(id, _)| id)
            .collect();
        base.server_id == self.server_id && !base.deleted && owners == [&op.author]
    }

    /// Check if a peer is muted at `now_ms` (epoch ms). Expired mutes read as
    /// unmuted; `u64::MAX` = permanent.
    pub fn is_muted(&self, peer_id: &str, now_ms: u64) -> bool {
        // Multi-device: mutes are master-keyed; collapse a device id first.
        let key = super::resolve_identity(peer_id);
        self.muted_members
            .get(&key)
            .map(|reg| *reg.read() > now_ms)
            .unwrap_or(false)
    }

    /// Check if `actor` can mute `target`. Same hierarchy as kick/ban.
    pub fn can_mute(&self, actor: &str, target: &str) -> bool {
        self.can_kick(actor, target)
    }

    /// List active mutes at `now_ms` as (master peer_id, expiry ms) pairs.
    /// Expired entries are skipped (they linger in the map until unmute).
    pub fn muted_list(&self, now_ms: u64) -> Vec<(String, u64)> {
        self.muted_members
            .iter()
            .filter(|(_, reg)| *reg.read() > now_ms)
            .map(|(pid, reg)| (pid.clone(), *reg.read()))
            .collect()
    }

    /// List all currently banned peer IDs.
    pub fn banned_list(&self) -> Vec<String> {
        self.banned_members
            .iter()
            .filter(|(_, reg)| *reg.read())
            .map(|(pid, _)| pid.clone())
            .collect()
    }

    /// Get all label definitions, sorted by name for stable ordering.
    pub fn labels_list(&self) -> Vec<&LabelInfo> {
        let mut list: Vec<_> = self.labels.values().collect();
        list.sort_by(|a, b| a.name.cmp(&b.name));
        list
    }

    /// Get all custom emotes, sorted by name for stable ordering.
    pub fn emotes_list(&self) -> Vec<&EmoteInfo> {
        let mut list: Vec<_> = self.emotes.values().collect();
        list.sort_by(|a, b| a.name.cmp(&b.name));
        list
    }

    /// All stickers, pack-major then name then hash, so the order is total and identical
    /// on every replica: two stickers can share a name.
    pub fn stickers_list(&self) -> Vec<&StickerInfo> {
        let mut list: Vec<_> = self.stickers.values().collect();
        list.sort_by(|a, b| {
            a.pack
                .cmp(&b.pack)
                .then_with(|| a.name.cmp(&b.name))
                .then_with(|| a.hash.cmp(&b.hash))
        });
        list
    }

    /// Get the labels assigned to a member.
    pub fn get_member_labels(&self, peer_id: &str) -> Vec<&LabelInfo> {
        self.label_assignments
            .get(peer_id)
            .map(|ids| {
                ids.iter()
                    .filter_map(|id| self.labels.get(id))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Unexpired temporary grant for (channel, member)? Grants are
    /// master-keyed; collapse a device id first (like `is_muted`).
    pub fn has_channel_grant(&self, peer_id: &str, channel_id: &str, now_ms: u64) -> bool {
        let key = super::resolve_identity(peer_id);
        self.channel_grants
            .get(channel_id)
            .and_then(|m| m.get(&key))
            .map(|reg| *reg.read() > now_ms)
            .unwrap_or(false)
    }

    /// Active grants for a channel at `now_ms` as (master peer_id, expiry ms)
    /// pairs. Expired entries are skipped (they linger until revoke,
    /// mirroring `muted_list`).
    pub fn channel_grants_list(&self, channel_id: &str, now_ms: u64) -> Vec<(String, u64)> {
        self.channel_grants
            .get(channel_id)
            .map(|m| {
                m.iter()
                    .filter(|(_, reg)| *reg.read() > now_ms)
                    .map(|(pid, reg)| (pid.clone(), *reg.read()))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Does the member (already master-collapsed) hold ANY of the listed label ids? A raw
    /// lookup, so callers must resolve device to master first. `LabelDeleted` strips
    /// assignments, so a deleted label can never satisfy a gate.
    fn holds_any_label(&self, master: &str, wanted: &[String]) -> bool {
        self.label_assignments
            .get(master)
            .is_some_and(|held| wanted.iter().any(|w| held.contains(w)))
    }

    /// Shared self-toggle rule for LabelAssigned/Unassigned, used by BOTH the authoring
    /// gate and `op_allowed` so the two can never drift. Only an EXISTING, non-access
    /// label may be self-toggled; unknown ids are refused, since an assignment racing
    /// ahead of its LabelCreated cannot be classified and would let anyone pre-claim a
    /// future access label.
    pub fn can_self_toggle_label(&self, actor: &str, target_peer: &str, label_id: &str) -> bool {
        super::resolve_identity(actor) == super::resolve_identity(target_peer)
            && self.labels.get(label_id).is_some_and(|l| !l.access)
    }

    /// Check if a peer can see a channel (at the current wall clock).
    pub fn can_see_channel(&self, peer_id: &str, channel_id: &str) -> bool {
        self.can_see_channel_at(peer_id, channel_id, epoch_ms_now())
    }

    /// Visibility predicate at an explicit `now_ms` (tests control time).
    /// Owner always sees. An unexpired grant sees. A non-empty label gate
    /// REPLACES the tier ladder: Admin+ implicit, else any listed label.
    pub fn can_see_channel_at(&self, peer_id: &str, channel_id: &str, now_ms: u64) -> bool {
        let master = super::resolve_identity(peer_id);
        let role = self.get_role(&master);
        if role == MemberRole::Owner { return true; }
        let Some(ch) = self.channels.get(channel_id) else { return false; };
        if self.has_channel_grant(&master, channel_id, now_ms) { return true; }
        if !ch.visibility_labels.is_empty() {
            return role.priority() >= MemberRole::Admin.priority()
                || self.holds_any_label(&master, &ch.visibility_labels);
        }
        match ch.visibility {
            ChannelVisibility::Everyone => true,
            ChannelVisibility::ModeratorPlus => role.priority() >= MemberRole::Moderator.priority(),
            ChannelVisibility::AdminPlus => role.priority() >= MemberRole::Admin.priority(),
        }
    }

    /// Effective public flag — voice channels are never public (#44), even if
    /// a stale CRDT still carries `is_public = true` for one.
    pub fn is_channel_public(&self, channel_id: &str) -> bool {
        self.channels.get(channel_id).map_or(false, |ch| ch.effective_public())
    }

    /// Check if a peer can post in a channel (at the current wall clock).
    pub fn can_post_in_channel(&self, peer_id: &str, channel_id: &str) -> bool {
        self.can_post_in_channel_at(peer_id, channel_id, epoch_ms_now())
    }

    /// Posting predicate at an explicit `now_ms`. Same shape as visibility; the Everyone
    /// tier keeps the SEND_MESSAGES check and a grant confers posting too. Mute stays a
    /// SEPARATE check at the send and ingest sites, never folded in here.
    pub fn can_post_in_channel_at(&self, peer_id: &str, channel_id: &str, now_ms: u64) -> bool {
        let master = super::resolve_identity(peer_id);
        let role = self.get_role(&master);
        if role == MemberRole::Owner { return true; }
        let Some(ch) = self.channels.get(channel_id) else { return false; };
        if self.has_channel_grant(&master, channel_id, now_ms) { return true; }
        if !ch.posting_labels.is_empty() {
            return role.priority() >= MemberRole::Admin.priority()
                || self.holds_any_label(&master, &ch.posting_labels);
        }
        match ch.posting {
            ChannelPosting::Everyone => self.has_permission(&master, Permission::SEND_MESSAGES),
            ChannelPosting::ModeratorPlus => role.priority() >= MemberRole::Moderator.priority(),
            ChannelPosting::AdminPlus => role.priority() >= MemberRole::Admin.priority(),
        }
    }

    /// Slow-mode interval for a channel in seconds (0 = off).
    pub fn channel_slow_mode(&self, channel_id: &str) -> u32 {
        self.channels.get(channel_id).map_or(0, |ch| ch.slow_mode)
    }

    /// Whether a channel only accepts image/video/GIF attachments.
    pub fn is_channel_media_only(&self, channel_id: &str) -> bool {
        self.channels.get(channel_id).map_or(false, |ch| ch.media_only)
    }

    /// Moderator+ (and Owner) bypass slow mode, matching the Discord behavior.
    pub fn bypasses_slow_mode(&self, peer_id: &str) -> bool {
        self.get_role(peer_id).priority() >= MemberRole::Moderator.priority()
    }

    /// Whether a channel is cryptographically isolated in its own MLS subgroup: true iff
    /// it is restricted (and so never public). Such a channel is encrypted under
    /// `subgroup_id(server_id, channel_id)`, so only members who may see it hold the key.
    pub fn channel_uses_subgroup(&self, channel_id: &str) -> bool {
        self.channels.get(channel_id).is_some_and(ChannelInfo::restricted)
    }

    /// All channel ids that currently use a dedicated MLS subgroup (the restricted
    /// ones). Used to enumerate subgroup ids for MLS persistence reload and
    /// to reconcile membership on role/visibility changes.
    pub fn subgroup_channel_ids(&self) -> Vec<String> {
        self.channels
            .values()
            .filter(|ch| ch.restricted())
            .map(|ch| ch.channel_id.clone())
            .collect()
    }
}

/// Where an op sits in the fold: its clock, except a checkpoint, which sits at what it
/// covers and after any op at that same clock (the op it covered).
pub(super) fn fold_order(a: &CrdtOp, b: &CrdtOp) -> std::cmp::Ordering {
    fn key(op: &CrdtOp) -> (&HlcTimestamp, bool) {
        match &op.payload {
            CrdtPayload::ServerCheckpoint { covers, .. } => (covers, true),
            _ => (&op.hlc, false),
        }
    }
    key(a).cmp(&key(b))
}

/// Current wall clock in epoch ms (the time base for mute + grant expiry).
fn epoch_ms_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

/// A join secret's bytes, when it has the one shape `JoinKeySet` may carry.
fn join_secret_shape(secret: &str) -> Option<zeroize::Zeroizing<[u8; 32]>> {
    if secret.len() != 64 {
        return None;
    }
    let bytes = zeroize::Zeroizing::new(hex::decode(secret).ok()?);
    Some(zeroize::Zeroizing::new(bytes.as_slice().try_into().ok()?))
}

/// Truncate a peer ID to a short display name.
fn short_name(peer_id: &str) -> String {
    if peer_id.len() > 12 {
        format!("{}...", &peer_id[..12])
    } else {
        peer_id.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::testkeys::{keys, owned_state};
    use crate::crdt::operations::JoinSecret;

    /// A state with a signer installed, so `create_op` works. The owner id stays the
    /// caller's readable string: these tests drive `op_allowed` and `apply_op`, neither
    /// of which verifies a signature. Anything going through `admit_remote_op` uses
    /// `owned_state`, where the owner id is DERIVED from the key.
    fn test_state(server_id: String, name: String, owner: String) -> ServerState {
        let mut s = ServerState::new(server_id, name, owner);
        let (kp, _, pk) = keys(9);
        s.set_signer(kp, pk);
        s
    }

    /// Build an op authored by `author` (create_op stamps the local actor;
    /// ingest validation only reads `op.author`, so overriding it simulates a
    /// remote peer's op).
    fn op_by(state: &mut ServerState, author: &str, payload: CrdtPayload) -> CrdtOp {
        let mut op = state.create_op(payload);
        op.author = author.to_string();
        op
    }

    /// The shared ingest permission matrix (`op_allowed`), one allowed and one denied
    /// probe per payload arm, driven as a pure function. The regression guard for BOTH
    /// remote-op ingest paths, which call this exact method.
    #[test]
    fn op_allowed_ingest_matrix() {
        let mut s = test_state("s1".into(), "S".into(), "owner".into());
        for id in ["admin", "moder", "alice", "bob"] {
            let op = s.create_op(CrdtPayload::MemberAdded {
                peer_id: id.into(),
                display_name: id.into(),
                follow: None,
                ask: None,
            });
            let _ = s.apply_op(&op);
        }
        for (id, role) in [("admin", MemberRole::Admin), ("moder", MemberRole::Moderator)] {
            let op = s.create_op(CrdtPayload::RoleChanged {
                peer_id: id.into(),
                role,
                priority: 3,
            });
            let _ = s.apply_op(&op);
        }
        // Labels for the assign/unassign rows: one cosmetic, one access-bearing
        // (self-toggle is only legal for EXISTING cosmetic labels).
        for (lid, access) in [("l1", false), ("lacc", true)] {
            let op = s.create_op(CrdtPayload::LabelCreated {
                label_id: lid.into(),
                name: lid.into(),
                color: "#fff".into(),
                access,
            });
            let _ = s.apply_op(&op);
        }

        let ch = |cid: &str| CrdtPayload::ChannelRenamed {
            channel_id: cid.into(),
            new_name: "n".into(),
        };
        let cases: Vec<(&str, CrdtPayload, bool)> = vec![
            // Channel management (MANAGE_CHANNELS): admin yes, moderator/member no.
            ("admin", ch("c1"), true),
            ("moder", ch("c1"), false),
            ("alice", CrdtPayload::ChannelLayoutUpdated { layout_json: "[]".into() }, false),
            // RoleChanged goes through can_change_role (tier-gated).
            ("owner", CrdtPayload::RoleChanged { peer_id: "alice".into(), role: MemberRole::Moderator, priority: 3 }, true),
            ("alice", CrdtPayload::RoleChanged { peer_id: "bob".into(), role: MemberRole::Admin, priority: 0 }, false),
            // Server rename/settings: Owner or Admin only.
            ("admin", CrdtPayload::ServerRenamed { new_name: "X".into() }, true),
            ("moder", CrdtPayload::ServerSettingChanged { key: "k".into(), value: "v".into() }, false),
            // The join key: the Owner only, and only a well-formed secret.
            ("owner", CrdtPayload::JoinKeySet { secret: JoinSecret("ab".repeat(32)) }, true),
            ("admin", CrdtPayload::JoinKeySet { secret: JoinSecret("ab".repeat(32)) }, false),
            ("owner", CrdtPayload::JoinKeySet { secret: JoinSecret("ab".repeat(31)) }, false),
            ("owner", CrdtPayload::JoinKeySet { secret: JoinSecret("zz".repeat(32)) }, false),
            // MemberRemoved: voluntary self-leave always; kicks need KICK_MEMBERS + outrank.
            ("alice", CrdtPayload::MemberRemoved { peer_id: "alice".into() }, true),
            ("alice", CrdtPayload::MemberRemoved { peer_id: "bob".into() }, false),
            ("moder", CrdtPayload::MemberRemoved { peer_id: "bob".into() }, true),
            ("moder", CrdtPayload::MemberRemoved { peer_id: "admin".into() }, false),
            // MemberAdded: any current member, on the joiner's own ask; a stranger no.
            ("alice", add_on_ask(30, 1, None), true),
            ("stranger", add_on_ask(31, 1, None), false),
            // Nickname / Twitch / pledge: self or Owner/Admin.
            ("alice", CrdtPayload::NicknameChanged { peer_id: "alice".into(), nickname: "a".into() }, true),
            ("alice", CrdtPayload::NicknameChanged { peer_id: "bob".into(), nickname: "x".into() }, false),
            ("alice", CrdtPayload::TwitchUsernameChanged { peer_id: "alice".into(), twitch_username: "tv".into() }, true),
            ("alice", CrdtPayload::TwitchUsernameChanged { peer_id: "bob".into(), twitch_username: "tv".into() }, false),
            ("admin", CrdtPayload::StoragePledgeChanged { peer_id: "bob".into(), pledge_bytes: 1 }, true),
            ("alice", CrdtPayload::StoragePledgeChanged { peer_id: "bob".into(), pledge_bytes: 1 }, false),
            // Pins need MANAGE_CHANNELS (moderator lacks it).
            ("admin", CrdtPayload::MessagePinned { channel_id: "c".into(), message_id: "m".into() }, true),
            ("moder", CrdtPayload::MessageUnpinned { channel_id: "c".into(), message_id: "m".into() }, false),
            // Role-permission edits: MANAGE_ROLES + must OUTRANK the target role.
            ("admin", CrdtPayload::RolePermissionsChanged { role: "moderator".into(), permissions: 0 }, true),
            ("admin", CrdtPayload::RolePermissionsChanged { role: "admin".into(), permissions: 0 }, false),
            ("moder", CrdtPayload::RolePermissionsChanged { role: "member".into(), permissions: 0 }, false),
            // Ban / unban / mute / unmute: KICK_MEMBERS (+outrank for targeted ones).
            ("moder", CrdtPayload::MemberBanned { peer_id: "bob".into() }, true),
            ("moder", CrdtPayload::MemberBanned { peer_id: "admin".into() }, false),
            ("alice", CrdtPayload::MemberBanned { peer_id: "bob".into() }, false),
            ("moder", CrdtPayload::MemberUnbanned { peer_id: "bob".into() }, true),
            ("alice", CrdtPayload::MemberUnbanned { peer_id: "bob".into() }, false),
            ("moder", CrdtPayload::MemberMuted { peer_id: "bob".into(), expires_at: u64::MAX }, true),
            ("alice", CrdtPayload::MemberMuted { peer_id: "bob".into(), expires_at: u64::MAX }, false),
            ("moder", CrdtPayload::MemberUnmuted { peer_id: "bob".into() }, true),
            // Channel access / moderation settings: MANAGE_CHANNELS.
            ("admin", CrdtPayload::ChannelVisibilityChanged { channel_id: "c".into(), visibility: "everyone".into() }, true),
            ("alice", CrdtPayload::ChannelPostingChanged { channel_id: "c".into(), posting: "everyone".into() }, false),
            ("admin", CrdtPayload::ChannelPublicChanged { channel_id: "c".into(), is_public: true }, true),
            ("alice", CrdtPayload::ChannelSlowModeChanged { channel_id: "c".into(), seconds: 5 }, false),
            ("admin", CrdtPayload::ChannelMediaOnlyChanged { channel_id: "c".into(), media_only: true }, true),
            // Labels: create/delete/update need MANAGE_ROLES; assign is
            // self-or-MANAGE_ROLES, and self ONLY for existing cosmetic labels, since
            // access labels gate channels and unknown ids fail closed.
            ("admin", CrdtPayload::LabelCreated { label_id: "l9".into(), name: "L".into(), color: "#fff".into(), access: false }, true),
            ("alice", CrdtPayload::LabelUpdated { label_id: "l1".into(), name: "L".into(), color: "#fff".into(), access: None }, false),
            ("alice", CrdtPayload::LabelDeleted { label_id: "l1".into() }, false),
            ("alice", CrdtPayload::LabelAssigned { label_id: "l1".into(), peer_id: "alice".into() }, true),
            ("alice", CrdtPayload::LabelAssigned { label_id: "l1".into(), peer_id: "bob".into() }, false),
            ("alice", CrdtPayload::LabelAssigned { label_id: "lacc".into(), peer_id: "alice".into() }, false),
            ("alice", CrdtPayload::LabelUnassigned { label_id: "lacc".into(), peer_id: "alice".into() }, false),
            ("alice", CrdtPayload::LabelAssigned { label_id: "ghost".into(), peer_id: "alice".into() }, false),
            ("admin", CrdtPayload::LabelAssigned { label_id: "lacc".into(), peer_id: "bob".into() }, true),
            ("admin", CrdtPayload::LabelUnassigned { label_id: "l1".into(), peer_id: "bob".into() }, true),
            // Label gates + grants: MANAGE_CHANNELS.
            ("admin", CrdtPayload::ChannelVisibilityLabelsChanged { channel_id: "c".into(), labels: vec!["lacc".into()] }, true),
            ("alice", CrdtPayload::ChannelVisibilityLabelsChanged { channel_id: "c".into(), labels: vec!["lacc".into()] }, false),
            ("admin", CrdtPayload::ChannelPostingLabelsChanged { channel_id: "c".into(), labels: vec![] }, true),
            ("moder", CrdtPayload::ChannelPostingLabelsChanged { channel_id: "c".into(), labels: vec![] }, false),
            ("admin", CrdtPayload::ChannelGrantSet { channel_id: "c".into(), peer_id: "bob".into(), expires_at: u64::MAX }, true),
            ("alice", CrdtPayload::ChannelGrantSet { channel_id: "c".into(), peer_id: "bob".into(), expires_at: u64::MAX }, false),
            ("admin", CrdtPayload::ChannelGrantRevoked { channel_id: "c".into(), peer_id: "bob".into() }, true),
            ("moder", CrdtPayload::ChannelGrantRevoked { channel_id: "c".into(), peer_id: "bob".into() }, false),
            // Emotes: MANAGE_EMOTES + grammar validation at ingest.
            ("admin", CrdtPayload::EmojiAdded { name: "pog".into(), hash: "a".repeat(64), animated: false }, true),
            ("admin", CrdtPayload::EmojiAdded { name: "Bad Name".into(), hash: "a".repeat(64), animated: false }, false),
            ("admin", CrdtPayload::EmojiAdded { name: "pog".into(), hash: "zz".into(), animated: false }, false),
            ("alice", CrdtPayload::EmojiAdded { name: "pog".into(), hash: "a".repeat(64), animated: false }, false),
            ("admin", CrdtPayload::EmojiRemoved { name: "pog".into() }, true),
            ("alice", CrdtPayload::EmojiRemoved { name: "pog".into() }, false),
            // Tombstone: Owner only.
            ("owner", CrdtPayload::ServerDeleted { deleted_at: 1 }, true),
            ("admin", CrdtPayload::ServerDeleted { deleted_at: 1 }, false),
            // ServerCreated on a server that ALREADY has an Owner is refused for
            // everyone, the Owner included: a replayed founding op used to reset the
            // name (E15). Naming the REAL owner does not help a stranger either.
            ("stranger", CrdtPayload::ServerCreated { name: "S".into(), owner_peer_id: "stranger".into(), nonce: String::new(), }, false),
            ("admin", CrdtPayload::ServerCreated { name: "S".into(), owner_peer_id: "admin".into(), nonce: String::new(), }, false),
            ("stranger", CrdtPayload::ServerCreated { name: "S".into(), owner_peer_id: "owner".into(), nonce: String::new(), }, false),
            ("owner", CrdtPayload::ServerCreated { name: "S".into(), owner_peer_id: "owner".into(), nonce: String::new(), }, false),
        ];
        for (author, payload, expect) in cases {
            let op = op_by(&mut s, author, payload);
            assert_eq!(
                s.op_allowed(&op),
                expect,
                "author={author} payload={:?}",
                op.payload
            );
        }

        // Override-awareness: granting MANAGE_CHANNELS to Member via
        // RolePermissionsChanged must open channel ops at ingest too
        // (get_permissions, not default_permissions).
        let grant = s.create_op(CrdtPayload::RolePermissionsChanged {
            role: "member".into(),
            permissions: MemberRole::Member.default_permissions() | Permission::MANAGE_CHANNELS,
        });
        let _ = s.apply_op(&grant);
        let op = op_by(&mut s, "alice", CrdtPayload::ChannelRenamed {
            channel_id: "c1".into(),
            new_name: "renamed".into(),
        });
        assert!(s.op_allowed(&op), "override-granted MANAGE_CHANNELS must pass ingest");

        // ServerCreated on an OWNERLESS state (the join skeleton replaying an
        // op log) is the one shape that founds a server: the author must be
        // the peer it names as owner, and the pin when the invite carried one.
        let mut skeleton = ServerState::skeleton("s2".into());
        let (kp, _, pk) = keys(9);
        skeleton.set_hlc(Hlc::new("seed".into()));
        skeleton.set_signer(kp, pk);
        assert!(skeleton.current_owner().is_none(), "skeleton starts ownerless");
        let founding = op_by(&mut skeleton, "founder", CrdtPayload::ServerCreated {
            name: "S2".into(),
            owner_peer_id: "founder".into(),
            nonce: String::new(),
        });
        assert!(
            skeleton.op_allowed(&founding),
            "an ownerless state must accept a founding op from the peer it names"
        );
        let hijack = op_by(&mut skeleton, "thief", CrdtPayload::ServerCreated {
            name: "S2".into(),
            owner_peer_id: "founder".into(),
            nonce: String::new(),
        });
        assert!(
            !skeleton.op_allowed(&hijack),
            "a founding op must be authored by the owner it names"
        );
        skeleton.owner_pin = Some("founder".into());
        let other = op_by(&mut skeleton, "other", CrdtPayload::ServerCreated {
            name: "S2".into(),
            owner_peer_id: "other".into(),
            nonce: String::new(),
        });
        assert!(!skeleton.op_allowed(&other), "a pinned joiner takes only the pinned owner");
        assert!(skeleton.op_allowed(&founding));
    }

    /// The join lock op: an owner-signed link only from the owner, any other only a
    /// successor its predecessor's change key signed and only from an owner, admin or
    /// mod, a door only its own secret, grants only to owners, admins and mods. A
    /// removal or a demotion makes it due to move; a newer door settles that.
    #[test]
    fn a_join_lock_op_is_judged_by_who_may_move_the_lock() {
        use crate::node::join_lock::{mint_base, mint_next};
        let (owner_kp, owner, _) = keys(1);
        let server = "0123456789abcdef0123456789abcdef".to_string();
        let mut s = test_state(server.clone(), "S".into(), owner.clone());
        for id in ["moder", "alice", "bob"] {
            let op = s.create_op(CrdtPayload::MemberAdded { peer_id: id.into(), display_name: id.into(), follow: None, ask: None });
            let _ = s.apply_op(&op);
        }
        let op = s.create_op(CrdtPayload::RoleChanged { peer_id: "moder".into(), role: MemberRole::Moderator, priority: 3 });
        let _ = s.apply_op(&op);
        let door_of = |lock: &crate::node::join_lock::NewLock| Some(JoinSecret(hex::encode(lock.door.as_slice())));
        let grant = format!("{}={}", "A".repeat(43), format_args!(".{}", "B".repeat(64)));
        let grants = |to: &str| std::collections::BTreeMap::from([(to.to_string(), grant.clone())]);
        let lock_op = |s: &mut ServerState, author: &str, link: &crate::node::join_lock::LockLink, door, grants| {
            op_by(s, author, CrdtPayload::JoinLock { link: link.clone(), door, grants })
        };

        let first = mint_base(&server, 1, &owner_kp, None).unwrap();
        let by_mod = lock_op(&mut s, "moder", &first.link, door_of(&first), grants("moder"));
        assert!(!s.op_allowed(&by_mod), "an owner-signed link comes from the owner only");
        let base = lock_op(&mut s, &owner, &first.link, door_of(&first), grants("moder"));
        assert!(s.op_allowed(&base));
        let _ = s.apply_op(&base);
        assert!(s.join_lock.has_lock());
        assert_eq!(s.join_lock.newest_door().map(|(n, _, _)| n), Some(1));
        assert!(!s.join_lock.rotation_due());

        let next = mint_next(&server, &first.link, &first.change).unwrap();
        let by_member = lock_op(&mut s, "alice", &next.link, door_of(&next), Default::default());
        assert!(!s.op_allowed(&by_member), "a plain member moves nothing");
        let stray = mint_next(&server, &first.link, &crate::node::sealed_box::new_secret().unwrap());
        assert!(stray.is_none(), "only the change key signs a successor");
        let wrong_door = lock_op(&mut s, "moder", &next.link, door_of(&first), Default::default());
        assert!(!s.op_allowed(&wrong_door), "a door is only its own secret");
        let to_member = lock_op(&mut s, "moder", &next.link, door_of(&next), grants("alice"));
        assert!(!s.op_allowed(&to_member), "the change key goes to owners, admins and mods only");
        let skipped = mint_next(&server, &next.link, &next.change).unwrap();
        let ahead = lock_op(&mut s, "moder", &skipped.link, door_of(&skipped), Default::default());
        assert!(!s.op_allowed(&ahead), "no successor of a lock we do not hold");

        let leave = op_by(&mut s, "bob", CrdtPayload::MemberRemoved { peer_id: "bob".into() });
        let _ = s.apply_op(&leave);
        assert!(s.join_lock.rotation_due(), "a leave makes the lock due to move");
        let moved = lock_op(&mut s, "moder", &next.link, door_of(&next), grants("moder"));
        assert!(s.op_allowed(&moved));
        let _ = s.apply_op(&moved);
        assert!(!s.join_lock.rotation_due(), "the newer door settles it");
        assert_eq!(s.join_lock.door_secrets(1).len(), 1, "the older door still opens a request sealed to it");
        assert_eq!(s.join_lock.chain().len(), 2);

        let ban = op_by(&mut s, &owner, CrdtPayload::MemberBanned { peer_id: "alice".into() });
        let _ = s.apply_op(&ban);
        assert!(s.join_lock.rotation_due(), "a ban makes it due to move");
        let third = mint_next(&server, &next.link, &next.change).unwrap();
        let settled = lock_op(&mut s, "moder", &third.link, door_of(&third), grants("moder"));
        let _ = s.apply_op(&settled);
        assert!(!s.join_lock.rotation_due());

        let demote = s.create_op(CrdtPayload::RoleChanged { peer_id: "moder".into(), role: MemberRole::Member, priority: 3 });
        let _ = s.apply_op(&demote);
        assert!(s.join_lock.rotation_due(), "a demoted mod still holds the change key");
        assert!(!format!("{s:?}").contains(&hex::encode(next.door.as_slice())), "no door ever prints");

        let mut rebuilt = ServerState::skeleton(server.clone());
        rebuilt.rebase_on(s.lean_snapshot(), &owner, &demote.hlc);
        assert_eq!(rebuilt.join_lock.chain(), s.join_lock.chain(), "a checkpoint carries the lock");
        assert!(rebuilt.join_lock.rotation_due(), "and that it is due to move");
    }

    #[test]
    fn the_join_key_lands_converges_and_rides_a_checkpoint() {
        let mut s = test_state("s1".into(), "S".into(), "owner".into());
        assert!(s.join_public_text().is_none(), "a server starts with no join key");
        let first = s.create_op(CrdtPayload::JoinKeySet { secret: JoinSecret("01".repeat(32)) });
        let second = s.create_op(CrdtPayload::JoinKeySet { secret: JoinSecret("02".repeat(32)) });
        let mut replica = s.clone();
        let _ = s.apply_op(&first);
        let _ = s.apply_op(&second);
        let _ = replica.apply_op(&second);
        let _ = replica.apply_op(&first);
        assert_eq!(s.join_secret().map(|k| *k), Some([2u8; 32]));
        assert_eq!(s.join_public_text(), replica.join_public_text(), "the later key wins in any order");
        assert!(!format!("{s:?}").contains(&"02".repeat(32)), "the secret never prints");

        let mut rebuilt = ServerState::skeleton("s1".into());
        rebuilt.rebase_on(s.lean_snapshot(), "owner", &second.hlc);
        assert_eq!(rebuilt.join_public_text(), s.join_public_text(), "a checkpoint carries the join key");
    }

    #[test]
    fn canonicalize_folds_device_keyed_member_to_master() {
        // Owner is master-keyed; a joiner was recorded under a DEVICE id (legacy).
        let mut state = test_state("s1".into(), "S".into(), "owner_master".into());

        // Simulate a legacy joiner added under a device id with a Member role.
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "joiner_device".into(),
            display_name: "joiner".into(),
            follow: None,
            ask: None,
        });
        let _ = state.apply_op(&op);
        assert!(state.members.contains_key("joiner_device"));
        assert_eq!(state.members.len(), 2);

        // Resolver: joiner_device → joiner_master; everything else maps to self.
        let resolve = |id: &str| -> String {
            if id == "joiner_device" { "joiner_master".to_string() } else { id.to_string() }
        };
        let changed = state.canonicalize_members(resolve);
        assert!(changed);

        // Device key gone, master key present, owner untouched.
        assert!(!state.members.contains_key("joiner_device"));
        assert!(state.members.contains_key("joiner_master"));
        assert!(state.members.contains_key("owner_master"));
        assert_eq!(state.members.len(), 2);
        assert_eq!(state.get_role("joiner_master"), MemberRole::Member);
        assert_eq!(state.get_role("owner_master"), MemberRole::Owner);

        // Idempotent: a second pass changes nothing.
        assert!(!state.canonicalize_members(|id| id.to_string()));
    }

    #[test]
    fn canonicalize_single_device_is_noop() {
        // Identity resolver (single-device) → no change at all.
        let mut state = test_state("s1".into(), "S".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "bob".into(),
            display_name: "bob".into(),
            follow: None,
            ask: None,
        });
        let _ = state.apply_op(&op);
        assert!(!state.canonicalize_members(|id| id.to_string()));
        assert!(state.members.contains_key("bob"));
        assert!(state.members.contains_key("owner"));
    }

    #[test]
    fn canonicalize_never_overwrites_a_masters_role() {
        // A device-keyed role register was judged against whatever the device id read
        // as when it arrived, so it may only be ADOPTED by a master without a register
        // of its own, never overwrite one (E8), however late it was written.
        let mut state = test_state("s1".into(), "S".into(), "owner".into());

        // master entry as Member.
        let op1 = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "x_master".into(),
            display_name: "x".into(),
            follow: None,
            ask: None,
        });
        let _ = state.apply_op(&op1);

        // device entry, then promote it to Admin.
        let op2 = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "x_device".into(),
            display_name: "x".into(),
            follow: None,
            ask: None,
        });
        let _ = state.apply_op(&op2);
        let op3 = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "x_device".into(),
            role: MemberRole::Admin,
            priority: MemberRole::Owner.priority(),
        });
        let _ = state.apply_op(&op3);

        let resolve = |id: &str| -> String {
            if id == "x_device" { "x_master".to_string() } else { id.to_string() }
        };
        assert!(state.canonicalize_members(resolve));
        assert!(!state.members.contains_key("x_device"));
        assert_eq!(state.get_role("x_master"), MemberRole::Member);
    }

    #[test]
    fn accessors_resolve_device_to_master_via_hook() {
        // The chokepoint: ServerState accessors must collapse a DEVICE id to its master
        // before the keyed lookup. Driven through the real process-global resolver under
        // the shared test lock, since parallel tests mutate the same map.
        let _lock = crate::node::resolver::test_lock();
        crate::node::resolver::clear_all();
        crate::node::resolver::update("dev_owner", "owner_master");
        crate::node::resolver::update("dev_bob", "bob_master");
        crate::crdt::set_identity_resolver(crate::node::resolver::resolve);

        let mut state = test_state("s1".into(), "S".into(), "owner_master".into());
        // Add Bob (master-keyed) + promote him to Admin, and ban a third identity.
        let add = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "bob_master".into(), display_name: "bob".into(),
            follow: None,
            ask: None,
        });
        let _ = state.apply_op(&add);
        let role = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "bob_master".into(), role: MemberRole::Admin,
            priority: MemberRole::Owner.priority(),
        });
        let _ = state.apply_op(&role);

        // Lookups by DEVICE id resolve to the master entry.
        assert!(state.is_member("dev_bob"), "device id should resolve to member master");
        assert_eq!(state.get_role("dev_bob"), MemberRole::Admin, "role via device id");
        assert!(state.has_permission("dev_owner", Permission::MANAGE_SERVER), "owner perms via device id");
        // Unknown device (no link) resolves to itself → not a member.
        assert!(!state.is_member("dev_stranger"));

        crate::node::resolver::clear_all();
    }

    #[test]
    fn create_server_has_general_channel_and_owner() {
        let state = test_state(
            "server1".into(),
            "My Server".into(),
            "peer_creator".into(),
        );
        assert_eq!(state.name(), "My Server");
        assert_eq!(state.members.len(), 1);
        assert_eq!(state.channels.len(), 1);
        assert_eq!(state.get_role("peer_creator"), MemberRole::Owner);

        let channels = state.channels_list();
        assert_eq!(channels[0].name, "general");
    }

    #[test]
    fn add_channel_and_member() {
        let mut state = test_state(
            "server1".into(),
            "Test".into(),
            "peer_a".into(),
        );

        let op1 = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-dev".into(),
            name: "dev".into(),
            category: Some("Engineering".into()),
            channel_type: "text".into(),
        });
        state.apply_op(&op1).unwrap();

        let op2 = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "peer_b".into(),
            display_name: "Bob".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&op2).unwrap();

        assert_eq!(state.channels.len(), 2); // general + dev
        assert_eq!(state.members.len(), 2); // creator + Bob
        assert_eq!(state.get_role("peer_b"), MemberRole::Member);
    }

    #[test]
    fn duplicate_ops_are_idempotent() {
        let mut state = test_state(
            "server1".into(),
            "Test".into(),
            "peer_a".into(),
        );

        let op = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-1".into(),
            name: "channel-1".into(),
            category: None,
            channel_type: "text".into(),
        });

        state.apply_op(&op).unwrap();
        state.apply_op(&op).unwrap(); // Duplicate
        state.apply_op(&op).unwrap(); // Triple

        assert_eq!(state.channels.len(), 2); // general + channel-1
        assert_eq!(state.op_log.len(), 1); // Only one op stored
    }

    #[test]
    fn concurrent_ops_converge() {
        // Simulate two peers making concurrent changes
        let mut state_a = test_state(
            "server1".into(),
            "Test".into(),
            "peer_a".into(),
        );
        let mut state_b = state_a.clone();
        state_b.set_hlc(Hlc::new("peer_b".into()));

        // A adds member
        let op_a = state_a.create_op(CrdtPayload::MemberAdded {
            peer_id: "peer_b".into(),
            display_name: "Bob".into(),
            follow: None,
            ask: None,
        });

        // B adds channel (concurrently, doesn't know about op_a yet)
        let op_b = state_b.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-random".into(),
            name: "random".into(),
            category: None,
            channel_type: "text".into(),
        });

        // Both apply both ops (in different order)
        state_a.apply_op(&op_a).unwrap();
        state_a.apply_op(&op_b).unwrap();

        state_b.apply_op(&op_b).unwrap();
        state_b.apply_op(&op_a).unwrap();

        // Both converge to the same state
        assert_eq!(state_a.channels.len(), state_b.channels.len());
        assert_eq!(state_a.members.len(), state_b.members.len());
    }

    /// Seed a server whose "admin_peer" holds the Admin role, plus an
    /// owner-authored `twitch_verification_enabled=true` op that is NOT yet
    /// applied (tests choose when/where to apply it).
    fn owner_state_with_admin_and_setting() -> (ServerState, CrdtOp) {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let add = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "admin_peer".into(),
            display_name: "A".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&add).unwrap();
        let promote = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "admin_peer".into(),
            role: MemberRole::Admin,
            priority: MemberRole::Owner.priority(),
        });
        state.apply_op(&promote).unwrap();
        let owner_set = state.create_op(CrdtPayload::ServerSettingChanged {
            key: "twitch_verification_enabled".into(),
            value: "true".into(),
        });
        (state, owner_set)
    }

    /// Give a cloned replica its own HLC that has witnessed `seen`, so its
    /// next op is strictly HLC-later (deterministic even when every op in the
    /// test lands in the same millisecond).
    fn rekey_replica(state: &mut ServerState, actor: &str, seen: &HlcTimestamp) {
        let mut hlc = Hlc::new(actor.into());
        hlc.witness(seen);
        state.set_hlc(hlc);
    }

    #[test]
    fn admin_setting_overwrite_lands_after_owner_write() {
        // The live 2026-07-16 bug: the Owner enables a server setting, an
        // Admin holding MANAGE_SERVER flips it OFF, and the flip silently
        // lost the priority-first merge on every replica (including the
        // admin's own) — the toggle "reverted". Pure HLC LWW must land it.
        let (mut owner_state, owner_set) = owner_state_with_admin_and_setting();
        owner_state.apply_op(&owner_set).unwrap();

        let mut admin_state = owner_state.clone();
        rekey_replica(&mut admin_state, "admin_peer", &owner_set.hlc);
        let admin_op = admin_state.create_op(CrdtPayload::ServerSettingChanged {
            key: "twitch_verification_enabled".into(),
            value: "false".into(),
        });

        // Authority: stock Admin now holds MANAGE_SERVER by default, so every
        // ingest accepts the op.
        assert!(owner_state.op_allowed(&admin_op));

        admin_state.apply_op(&admin_op).unwrap();
        assert_eq!(
            admin_state.settings.get("twitch_verification_enabled").unwrap().read(),
            "false",
            "the admin's own replica must reflect the admin's write"
        );

        owner_state.apply_op(&admin_op).unwrap();
        assert_eq!(
            owner_state.settings.get("twitch_verification_enabled").unwrap().read(),
            "false",
            "the owner's replica must accept the admin's later write"
        );
    }

    /// E10 (decision 2c): retention decides what every member's sweep deletes, so only
    /// the Owner writes it, a policy only with a value the app offers, and a reader
    /// treats any other value as "keep".
    #[test]
    fn authz_retention_is_owner_only_and_takes_only_app_values() {
        let (mut state, _) = owner_state_with_admin_and_setting();
        let cases = [
            ("owner", "retention_files", "30d", true),
            ("admin_peer", "retention_files", "30d", false),
            ("owner", "retention_files", "0d", false),
            ("owner", "retention_files", "60d", false),
            ("owner", "retention_messages", "permanent", true),
            ("admin_peer", "retention_messages", "365d", false),
            ("owner", "retention_messages_since", "1790000000", true),
            ("admin_peer", "retention_messages_since", "0", false),
            ("owner", "retention_files_since", "soon", false),
            ("admin_peer", "twitch_verification_enabled", "false", true),
        ];
        for (author, key, value, allowed) in cases {
            let op = op_by(&mut state, author, CrdtPayload::ServerSettingChanged {
                key: key.into(),
                value: value.into(),
            });
            assert_eq!(state.op_allowed(&op), allowed, "{author} sets {key}={value}");
            assert_eq!(state.setting_change_allowed(author, key, value), allowed, "authoring {key}={value}");
        }
        for (policy, days) in [("30d", Some(30)), ("365d", Some(365)), ("permanent", None), ("0d", None), ("1d", None)] {
            assert_eq!(crate::vault::adaptive::parse_retention_days(policy), days, "{policy}");
        }
    }

    #[test]
    fn setting_overwrite_converges_regardless_of_apply_order() {
        let (base, owner_set) = owner_state_with_admin_and_setting();

        let mut admin_replica = base.clone();
        rekey_replica(&mut admin_replica, "admin_peer", &owner_set.hlc);
        let admin_op = admin_replica.create_op(CrdtPayload::ServerSettingChanged {
            key: "twitch_verification_enabled".into(),
            value: "false".into(),
        });

        // Neither op is applied in `base` — replay the pair in both orders
        // on fresh clones.
        let mut forward = base.clone();
        forward.apply_op(&owner_set).unwrap();
        forward.apply_op(&admin_op).unwrap();

        let mut reverse = base.clone();
        reverse.apply_op(&admin_op).unwrap();
        reverse.apply_op(&owner_set).unwrap();

        let f = forward.settings.get("twitch_verification_enabled").unwrap().read();
        let r = reverse.settings.get("twitch_verification_enabled").unwrap().read();
        assert_eq!(f, r, "apply order must not change the converged value");
        assert_eq!(f, "false", "the HLC-later (admin) write wins in both orders");
    }

    #[test]
    fn owner_has_all_permissions() {
        let state = test_state("s1".into(), "Test".into(), "owner".into());
        assert!(state.has_permission("owner", Permission::MANAGE_SERVER));
        assert!(state.has_permission("owner", Permission::MANAGE_CHANNELS));
        assert!(state.has_permission("owner", Permission::MANAGE_ROLES));
        assert!(state.has_permission("owner", Permission::KICK_MEMBERS));
    }

    #[test]
    fn member_has_limited_permissions() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "member".into(),
            display_name: "M".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&op).unwrap();

        assert!(!state.has_permission("member", Permission::MANAGE_SERVER));
        assert!(!state.has_permission("member", Permission::MANAGE_CHANNELS));
        assert!(!state.has_permission("member", Permission::MANAGE_ROLES));
        assert!(!state.has_permission("member", Permission::KICK_MEMBERS));
        assert!(state.has_permission("member", Permission::SEND_MESSAGES));
        assert!(state.has_permission("member", Permission::READ_MESSAGES));
    }

    #[test]
    fn role_change_permissions() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "admin".into(),
            display_name: "A".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&op).unwrap();
        // Owner (priority 3) promotes admin — uses author's priority
        let op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "admin".into(),
            role: MemberRole::Admin,
            priority: MemberRole::Owner.priority(), // Author is owner
        });
        state.apply_op(&op).unwrap();

        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "member".into(),
            display_name: "M".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&op).unwrap();

        // Owner can change anyone
        assert!(state.can_change_role("owner", "admin", &MemberRole::Member));
        assert!(state.can_change_role("owner", "member", &MemberRole::Admin));

        // Admin can change member to moderator
        assert!(state.can_change_role("admin", "member", &MemberRole::Moderator));
        // Admin cannot promote to admin (same rank)
        assert!(!state.can_change_role("admin", "member", &MemberRole::Admin));
        // Admin cannot change owner
        assert!(!state.can_change_role("admin", "owner", &MemberRole::Member));
        // Member cannot change anyone
        assert!(!state.can_change_role("member", "admin", &MemberRole::Member));
    }

    #[test]
    fn kick_permissions() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "mod".into(),
            display_name: "Mod".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&op).unwrap();
        // Owner (priority 3) promotes moderator — uses author's priority
        let op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "mod".into(),
            role: MemberRole::Moderator,
            priority: MemberRole::Owner.priority(), // Author is owner
        });
        state.apply_op(&op).unwrap();

        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "member".into(),
            display_name: "M".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&op).unwrap();

        // Owner can kick anyone
        assert!(state.can_kick("owner", "mod"));
        assert!(state.can_kick("owner", "member"));

        // Moderator can kick members (lower rank)
        assert!(state.can_kick("mod", "member"));
        // Moderator cannot kick owner (higher rank)
        assert!(!state.can_kick("mod", "owner"));
        // Member cannot kick anyone
        assert!(!state.can_kick("member", "mod"));
    }

    #[test]
    fn role_demotion_works() {
        // Regression test: Owner promotes member→admin, then demotes admin→member.
        // The demotion must succeed because the demotion op is HLC-later than
        // the promotion (merge is pure LWW; authority lives in can_change_role).
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "peer_b".into(),
            display_name: "B".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_role("peer_b"), MemberRole::Member);

        // Promote to Admin (author=owner, priority=3)
        let op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "peer_b".into(),
            role: MemberRole::Admin,
            priority: MemberRole::Owner.priority(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_role("peer_b"), MemberRole::Admin);

        // Demote back to Member (author=owner, priority=3)
        let op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "peer_b".into(),
            role: MemberRole::Member,
            priority: MemberRole::Owner.priority(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_role("peer_b"), MemberRole::Member);

        // Promote to Moderator, then demote to Member again
        let op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "peer_b".into(),
            role: MemberRole::Moderator,
            priority: MemberRole::Owner.priority(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_role("peer_b"), MemberRole::Moderator);

        let op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "peer_b".into(),
            role: MemberRole::Member,
            priority: MemberRole::Owner.priority(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_role("peer_b"), MemberRole::Member);
    }

    #[test]
    fn moderator_role_hierarchy() {
        assert!(MemberRole::Owner.outranks(&MemberRole::Admin));
        assert!(MemberRole::Admin.outranks(&MemberRole::Moderator));
        assert!(MemberRole::Moderator.outranks(&MemberRole::Member));
        assert!(!MemberRole::Member.outranks(&MemberRole::Moderator));
        assert!(!MemberRole::Moderator.outranks(&MemberRole::Admin));
    }

    #[test]
    fn storage_pledge_set_and_read() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        assert_eq!(state.get_storage_pledge("owner"), 0);
        assert_eq!(state.total_pledged_bytes(), 0);

        let op = state.create_op(CrdtPayload::StoragePledgeChanged {
            peer_id: "owner".into(),
            pledge_bytes: 512 * 1024 * 1024,
        });
        state.apply_op(&op).unwrap();

        assert_eq!(state.get_storage_pledge("owner"), 512 * 1024 * 1024);
        assert_eq!(state.total_pledged_bytes(), 512 * 1024 * 1024);
    }

    #[test]
    fn storage_pledge_removed_with_member() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "peer_b".into(),
            display_name: "B".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&op).unwrap();

        let op = state.create_op(CrdtPayload::StoragePledgeChanged {
            peer_id: "peer_b".into(),
            pledge_bytes: 1024 * 1024 * 1024,
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_storage_pledge("peer_b"), 1024 * 1024 * 1024);

        let op = state.create_op(CrdtPayload::MemberRemoved {
            peer_id: "peer_b".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_storage_pledge("peer_b"), 0);
        assert_eq!(state.total_pledged_bytes(), 0);
    }

    #[test]
    fn storage_pledge_serde_default() {
        // Simulate old JSON without storage_pledges field
        let json = r#"{
            "server_id": "s1",
            "name": {"value": "Test", "priority": 3, "hlc": {"physical_ms": 1000, "counter": 0, "actor": "owner"}},
            "channels": {},
            "members": {},
            "roles": {},
            "settings": {},
            "op_log": []
        }"#;
        let state: ServerState = serde_json::from_str(json).unwrap();
        assert!(state.storage_pledges.is_empty());
        assert_eq!(state.get_storage_pledge("anyone"), 0);
        assert_eq!(state.total_pledged_bytes(), 0);
    }

    // --- Labels ---

    #[test]
    fn label_lifecycle_create_update_delete() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());

        let op = state.create_op(CrdtPayload::LabelCreated {
            label_id: "lbl-1".into(),
            name: "VIP".into(),
            color: "#ff0000".into(),
            access: true,
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.labels.len(), 1);
        assert_eq!(state.labels["lbl-1"].name, "VIP");
        assert!(state.labels["lbl-1"].access);

        // access: None (an old client's update) preserves the stored flag.
        let op = state.create_op(CrdtPayload::LabelUpdated {
            label_id: "lbl-1".into(),
            name: "MVP".into(),
            color: "#00ff00".into(),
            access: None,
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.labels["lbl-1"].name, "MVP");
        assert_eq!(state.labels["lbl-1"].color, "#00ff00");
        assert!(state.labels["lbl-1"].access, "access: None must PRESERVE the flag");

        // access: Some(false) explicitly demotes to cosmetic.
        let op = state.create_op(CrdtPayload::LabelUpdated {
            label_id: "lbl-1".into(),
            name: "MVP".into(),
            color: "#00ff00".into(),
            access: Some(false),
        });
        state.apply_op(&op).unwrap();
        assert!(!state.labels["lbl-1"].access);

        let op = state.create_op(CrdtPayload::LabelDeleted {
            label_id: "lbl-1".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(state.labels.is_empty());
    }

    #[test]
    fn label_assignment_and_unassignment() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());

        let op = state.create_op(CrdtPayload::LabelCreated {
            label_id: "lbl-1".into(),
            name: "VIP".into(),
            color: "#ff0000".into(),
            access: false,
        });
        state.apply_op(&op).unwrap();

        let op = state.create_op(CrdtPayload::LabelAssigned {
            label_id: "lbl-1".into(),
            peer_id: "owner".into(),
        });
        state.apply_op(&op).unwrap();
        let labels = state.get_member_labels("owner");
        assert_eq!(labels.len(), 1);
        assert_eq!(labels[0].name, "VIP");

        // Duplicate assignment is idempotent
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_member_labels("owner").len(), 1);

        let op = state.create_op(CrdtPayload::LabelUnassigned {
            label_id: "lbl-1".into(),
            peer_id: "owner".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(state.get_member_labels("owner").is_empty());
        // label_assignments entry cleaned up
        assert!(!state.label_assignments.contains_key("owner"));
    }

    #[test]
    fn label_delete_cleans_up_assignments() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());

        let op = state.create_op(CrdtPayload::LabelCreated {
            label_id: "lbl-1".into(),
            name: "VIP".into(),
            color: "#ff0000".into(),
            access: false,
        });
        state.apply_op(&op).unwrap();
        let op = state.create_op(CrdtPayload::LabelAssigned {
            label_id: "lbl-1".into(),
            peer_id: "owner".into(),
        });
        state.apply_op(&op).unwrap();

        // Delete the label — assignment should be pruned
        let op = state.create_op(CrdtPayload::LabelDeleted {
            label_id: "lbl-1".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(state.get_member_labels("owner").is_empty());
    }

    // --- Label-gated channel access + temporary grants (issue #32) ---

    /// owner + admin + mod + member + vipper (a plain member holding the
    /// access label "vip"), one text channel "ch".
    fn label_gate_fixture() -> ServerState {
        let mut s = test_state("s1".into(), "Test".into(), "owner".into());
        for (id, role) in [
            ("admin", Some(MemberRole::Admin)),
            ("mod", Some(MemberRole::Moderator)),
            ("member", None),
            ("vipper", None),
        ] {
            let op = s.create_op(CrdtPayload::MemberAdded {
                peer_id: id.into(),
                display_name: id.into(),
                follow: None,
                ask: None,
            });
            s.apply_op(&op).unwrap();
            if let Some(r) = role {
                let op = s.create_op(CrdtPayload::RoleChanged {
                    peer_id: id.into(),
                    role: r,
                    priority: MemberRole::Owner.priority(),
                });
                s.apply_op(&op).unwrap();
            }
        }
        let op = s.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch".into(),
            name: "ch".into(),
            category: None,
            channel_type: "text".into(),
        });
        s.apply_op(&op).unwrap();
        let op = s.create_op(CrdtPayload::LabelCreated {
            label_id: "vip".into(),
            name: "VIP".into(),
            color: "#fff".into(),
            access: true,
        });
        s.apply_op(&op).unwrap();
        let op = s.create_op(CrdtPayload::LabelAssigned {
            label_id: "vip".into(),
            peer_id: "vipper".into(),
        });
        s.apply_op(&op).unwrap();
        s
    }

    /// Channel backfill is written into OUR history, so it comes only from a
    /// current member who can read that channel (audit decision 2, candidate C3).
    #[test]
    fn authz_channel_backfill_only_from_a_member_who_can_read_it() {
        let _g = crate::node::resolver::test_lock();
        let allowed = crate::node::crypto_handler::channel_backfill_allowed_from;
        let mut s = label_gate_fixture();
        assert!(allowed(Some(&s), "member", "ch"));
        assert!(!allowed(Some(&s), "stranger", "ch"));
        assert!(!allowed(None, "member", "ch"), "a server we do not hold");
        let op = s.create_op(CrdtPayload::ChannelVisibilityLabelsChanged {
            channel_id: "ch".into(),
            labels: vec!["vip".into()],
        });
        s.apply_op(&op).unwrap();
        assert!(!allowed(Some(&s), "member", "ch"), "a member who cannot see the channel");
        assert!(allowed(Some(&s), "vipper", "ch"));
    }

    /// Stored channel content is served only to a current member who can see the
    /// channel, or to anyone for a public one; an unknown peer's role resolves to
    /// plain Member, so membership is the first rung.
    #[test]
    fn authz_channel_served_only_to_a_member_who_can_read_it() {
        let _g = crate::node::resolver::test_lock();
        let readable = crate::node::crypto_handler::channel_readable_by;
        let mut s = label_gate_fixture();
        assert!(readable(&s, "member", "ch"));
        assert!(!readable(&s, "stranger", "ch"), "an Everyone channel that is not public");
        let op = s.create_op(CrdtPayload::ChannelPublicChanged { channel_id: "ch".into(), is_public: true });
        s.apply_op(&op).unwrap();
        assert!(readable(&s, "stranger", "ch"), "a public channel");
        let op = s.create_op(CrdtPayload::ChannelVisibilityLabelsChanged {
            channel_id: "ch".into(),
            labels: vec!["vip".into()],
        });
        s.apply_op(&op).unwrap();
        assert!(!readable(&s, "member", "ch"), "a member who cannot see the channel");
        assert!(readable(&s, "vipper", "ch"));
    }

    /// C10: typing and unread hints come only from someone who may post in the
    /// channel, about a channel we can see ourselves.
    #[test]
    fn authz_channel_signals_only_from_a_poster_about_a_channel_we_see() {
        let _g = crate::node::resolver::test_lock();
        let ok = |s: &ServerState, sender: &str, local: &str| {
            crate::node::message_ops::channel_signal_accepted(s, sender, local, "ch", 1_000)
        };
        let mut s = label_gate_fixture();
        assert!(ok(&s, "member", "admin"));
        assert!(!ok(&s, "stranger", "admin"), "a non-member");
        let op = s.create_op(CrdtPayload::ChannelVisibilityLabelsChanged {
            channel_id: "ch".into(),
            labels: vec!["vip".into()],
        });
        s.apply_op(&op).unwrap();
        assert!(!ok(&s, "member", "admin"), "a sender who cannot see the channel");
        assert!(ok(&s, "vipper", "admin"));
        assert!(!ok(&s, "vipper", "member"), "a channel we cannot see");
    }

    /// C12: a seat in a voice channel, and with it the dial, only for a member who
    /// can see that channel.
    #[test]
    fn authz_voice_seat_only_for_a_member_who_can_see_the_channel() {
        let _g = crate::node::resolver::test_lock();
        let refusal = crate::node::voice_handler::voice_join_refusal;
        let mut s = label_gate_fixture();
        let op = s.create_op(CrdtPayload::ChannelAdded {
            channel_id: "vc".into(),
            name: "vc".into(),
            category: None,
            channel_type: "voice".into(),
        });
        s.apply_op(&op).unwrap();
        let op = s.create_op(CrdtPayload::ChannelVisibilityLabelsChanged {
            channel_id: "vc".into(),
            labels: vec!["vip".into()],
        });
        s.apply_op(&op).unwrap();
        assert_eq!(refusal(Some(&s), "vipper", "vc"), None);
        assert_eq!(refusal(Some(&s), "member", "vc"), Some("cannot see the channel"));
        assert_eq!(refusal(Some(&s), "stranger", "vc"), Some("not a member"));
        assert_eq!(refusal(Some(&s), "vipper", "ch"), Some("not a voice channel"));
        assert!(refusal(None, "vipper", "vc").is_some());
    }

    #[test]
    fn label_gate_replaces_visibility_tier() {
        let mut s = label_gate_fixture();
        // Gate on VIP while the tier stays Everyone — the gate must REPLACE
        // the ladder, not AND with it.
        let op = s.create_op(CrdtPayload::ChannelVisibilityLabelsChanged {
            channel_id: "ch".into(),
            labels: vec!["vip".into()],
        });
        s.apply_op(&op).unwrap();
        let now = 1_000u64;
        assert!(!s.can_see_channel_at("member", "ch", now));
        assert!(
            !s.can_see_channel_at("mod", "ch", now),
            "moderators have NO implicit access to label-gated channels"
        );
        assert!(s.can_see_channel_at("admin", "ch", now), "Admin+ implicit");
        assert!(s.can_see_channel_at("owner", "ch", now));
        assert!(s.can_see_channel_at("vipper", "ch", now), "label holder sees");
        // A label-gated channel is cryptographically isolated.
        assert!(s.channel_uses_subgroup("ch"));
        assert!(s.subgroup_channel_ids().contains(&"ch".to_string()));
        // Clearing the gate reverts to the tier ladder.
        let op = s.create_op(CrdtPayload::ChannelVisibilityLabelsChanged {
            channel_id: "ch".into(),
            labels: vec![],
        });
        s.apply_op(&op).unwrap();
        assert!(s.can_see_channel_at("member", "ch", now));
        assert!(!s.channel_uses_subgroup("ch"));
    }

    #[test]
    fn label_gate_posting() {
        let mut s = label_gate_fixture();
        let op = s.create_op(CrdtPayload::ChannelPostingLabelsChanged {
            channel_id: "ch".into(),
            labels: vec!["vip".into()],
        });
        s.apply_op(&op).unwrap();
        let now = 1_000u64;
        assert!(!s.can_post_in_channel_at("member", "ch", now));
        assert!(!s.can_post_in_channel_at("mod", "ch", now));
        assert!(s.can_post_in_channel_at("admin", "ch", now));
        assert!(s.can_post_in_channel_at("vipper", "ch", now));
        // Posting gate does not affect visibility or subgrouping.
        assert!(s.can_see_channel_at("member", "ch", now));
        assert!(!s.channel_uses_subgroup("ch"));
        // Ungated Everyone posting still requires the SEND_MESSAGES bit.
        let op = s.create_op(CrdtPayload::ChannelPostingLabelsChanged {
            channel_id: "ch".into(),
            labels: vec![],
        });
        s.apply_op(&op).unwrap();
        assert!(s.can_post_in_channel_at("member", "ch", now));
        let op = s.create_op(CrdtPayload::RolePermissionsChanged {
            role: "member".into(),
            permissions: 0,
        });
        s.apply_op(&op).unwrap();
        assert!(!s.can_post_in_channel_at("member", "ch", now));
    }

    #[test]
    fn label_deleted_while_gating_fails_closed() {
        let mut s = label_gate_fixture();
        let op = s.create_op(CrdtPayload::ChannelVisibilityLabelsChanged {
            channel_id: "ch".into(),
            labels: vec!["vip".into()],
        });
        s.apply_op(&op).unwrap();
        assert!(s.can_see_channel_at("vipper", "ch", 1_000));
        // Deleting the label strips assignments → the dangling gate id can
        // never match again: LOCKOUT (fail-closed), not fail-open.
        let op = s.create_op(CrdtPayload::LabelDeleted { label_id: "vip".into() });
        s.apply_op(&op).unwrap();
        assert!(!s.can_see_channel_at("vipper", "ch", 1_000));
        assert!(s.can_see_channel_at("admin", "ch", 1_000));
        assert!(
            s.channels["ch"].visibility_labels.contains(&"vip".to_string()),
            "dangling gate id stays until an admin rewrites the list"
        );
        assert!(s.channel_uses_subgroup("ch"));
    }

    #[test]
    fn channel_grant_lifecycle() {
        let mut s = label_gate_fixture();
        // Restrict the channel to Admin+ so only the grant can admit "member".
        let op = s.create_op(CrdtPayload::ChannelVisibilityChanged {
            channel_id: "ch".into(),
            visibility: "admin".into(),
        });
        s.apply_op(&op).unwrap();
        assert!(!s.can_see_channel_at("member", "ch", 1_000));

        // Timed grant: visible (and postable) before expiry, denied after —
        // with NO revoke op (lazy expiry, mirroring mutes).
        let op = s.create_op(CrdtPayload::ChannelGrantSet {
            channel_id: "ch".into(),
            peer_id: "member".into(),
            expires_at: 5_000,
        });
        s.apply_op(&op).unwrap();
        assert!(s.can_see_channel_at("member", "ch", 4_999));
        assert!(s.can_post_in_channel_at("member", "ch", 4_999));
        assert!(s.has_channel_grant("member", "ch", 4_999));
        assert!(!s.can_see_channel_at("member", "ch", 5_000));
        assert!(!s.has_channel_grant("member", "ch", 5_000));
        // Expired rows linger but the list reader filters them.
        assert!(s.channel_grants_list("ch", 5_000).is_empty());
        assert_eq!(s.channel_grants_list("ch", 4_999).len(), 1);

        // A newer grant wins LWW regardless of apply order.
        let mut b = s.clone();
        let set_short = s.create_op(CrdtPayload::ChannelGrantSet {
            channel_id: "ch".into(),
            peer_id: "member".into(),
            expires_at: 6_000,
        });
        let set_long = s.create_op(CrdtPayload::ChannelGrantSet {
            channel_id: "ch".into(),
            peer_id: "member".into(),
            expires_at: u64::MAX,
        });
        s.apply_op(&set_short).unwrap();
        s.apply_op(&set_long).unwrap();
        b.apply_op(&set_long).unwrap();
        b.apply_op(&set_short).unwrap();
        assert!(s.can_see_channel_at("member", "ch", u64::MAX - 1), "permanent grant");
        assert!(b.can_see_channel_at("member", "ch", u64::MAX - 1), "same result in reverse order");

        // Revoke prunes the row (and the empty per-channel map).
        let op = s.create_op(CrdtPayload::ChannelGrantRevoked {
            channel_id: "ch".into(),
            peer_id: "member".into(),
        });
        s.apply_op(&op).unwrap();
        assert!(!s.can_see_channel_at("member", "ch", 1_000));
        assert!(!s.channel_grants.contains_key("ch"));
    }

    // --- Bans ---

    #[test]
    fn ban_removes_member_and_associated_data() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "bad_peer".into(),
            display_name: "Bad".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&op).unwrap();

        // Give them a nickname and storage pledge first
        let op = state.create_op(CrdtPayload::NicknameChanged {
            peer_id: "bad_peer".into(),
            nickname: "Trouble".into(),
        });
        state.apply_op(&op).unwrap();
        let op = state.create_op(CrdtPayload::StoragePledgeChanged {
            peer_id: "bad_peer".into(),
            pledge_bytes: 1024,
        });
        state.apply_op(&op).unwrap();

        // Ban them
        let op = state.create_op(CrdtPayload::MemberBanned {
            peer_id: "bad_peer".into(),
        });
        state.apply_op(&op).unwrap();

        assert!(state.is_banned("bad_peer"));
        assert!(!state.members.contains_key("bad_peer"));
        assert!(!state.roles.contains_key("bad_peer"));
        assert!(!state.nicknames.contains_key("bad_peer"));
        assert!(!state.storage_pledges.contains_key("bad_peer"));
        assert!(state.banned_list().contains(&"bad_peer".to_string()));
    }

    #[test]
    fn unban_allows_rejoin() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "peer_b".into(),
            display_name: "B".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&op).unwrap();

        let op = state.create_op(CrdtPayload::MemberBanned {
            peer_id: "peer_b".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(state.is_banned("peer_b"));

        let op = state.create_op(CrdtPayload::MemberUnbanned {
            peer_id: "peer_b".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(!state.is_banned("peer_b"));
        // Unbanned members are pruned from banned_members map
        assert!(state.banned_list().is_empty());
    }

    #[test]
    fn is_banned_defaults_false() {
        let state = test_state("s1".into(), "Test".into(), "owner".into());
        assert!(!state.is_banned("nonexistent"));
    }

    // --- Channel visibility / posting ---

    #[test]
    fn channel_visibility_restricts_access() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-secret".into(),
            name: "secret".into(),
            category: None,
            channel_type: "text".into(),
        });
        state.apply_op(&op).unwrap();

        // Add a regular member and a moderator
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "member".into(),
            display_name: "M".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&op).unwrap();
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "mod".into(),
            display_name: "Mod".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&op).unwrap();
        let op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: "mod".into(),
            role: MemberRole::Moderator,
            priority: MemberRole::Owner.priority(),
        });
        state.apply_op(&op).unwrap();

        // Everyone can see it by default
        assert!(state.can_see_channel("member", "ch-secret"));

        // Restrict to moderator+
        let op = state.create_op(CrdtPayload::ChannelVisibilityChanged {
            channel_id: "ch-secret".into(),
            visibility: "moderator".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(!state.can_see_channel("member", "ch-secret"));
        assert!(state.can_see_channel("mod", "ch-secret"));
        assert!(state.can_see_channel("owner", "ch-secret"));

        // Restrict to admin+
        let op = state.create_op(CrdtPayload::ChannelVisibilityChanged {
            channel_id: "ch-secret".into(),
            visibility: "admin".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(!state.can_see_channel("member", "ch-secret"));
        assert!(!state.can_see_channel("mod", "ch-secret"));
        assert!(state.can_see_channel("owner", "ch-secret")); // owner always sees
    }

    #[test]
    fn channel_posting_restricts_sending() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-announce".into(),
            name: "announcements".into(),
            category: None,
            channel_type: "text".into(),
        });
        state.apply_op(&op).unwrap();
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "member".into(),
            display_name: "M".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&op).unwrap();

        // Everyone can post by default
        assert!(state.can_post_in_channel("member", "ch-announce"));

        // Restrict to admin+
        let op = state.create_op(CrdtPayload::ChannelPostingChanged {
            channel_id: "ch-announce".into(),
            posting: "admin".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(!state.can_post_in_channel("member", "ch-announce"));
        assert!(state.can_post_in_channel("owner", "ch-announce"));
    }

    #[test]
    fn channel_public_flag() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let general_id = state.channels.keys().next().unwrap().clone();

        assert!(!state.is_channel_public(&general_id));

        let op = state.create_op(CrdtPayload::ChannelPublicChanged {
            channel_id: general_id.clone(),
            is_public: true,
        });
        state.apply_op(&op).unwrap();
        assert!(state.is_channel_public(&general_id));

        let op = state.create_op(CrdtPayload::ChannelPublicChanged {
            channel_id: general_id.clone(),
            is_public: false,
        });
        state.apply_op(&op).unwrap();
        assert!(!state.is_channel_public(&general_id));
    }

    /// Voice channels can never be public (#44): the op is refused at
    /// op_allowed, dropped at apply, and even a stale persisted flag is
    /// neutralized by the effective read.
    #[test]
    fn voice_channel_never_public() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-vc".into(),
            name: "Voice".into(),
            category: None,
            channel_type: "voice".into(),
        });
        state.apply_op(&op).unwrap();

        // op_allowed refuses it even for the owner.
        let public_op = state.create_op(CrdtPayload::ChannelPublicChanged {
            channel_id: "ch-vc".into(),
            is_public: true,
        });
        assert!(!state.op_allowed(&public_op));

        // Apply (a pre-guard client's op) leaves the raw flag untouched.
        state.apply_op(&public_op).unwrap();
        assert!(!state.channels["ch-vc"].is_public);
        assert!(!state.is_channel_public("ch-vc"));

        // A stale persisted flag (pre-0.9.1 state snapshot) is neutralized by
        // the effective read — and the channel still counts as a subgroup
        // candidate when restricted (SFrame key domain must not flip).
        state.channels.get_mut("ch-vc").unwrap().is_public = true;
        assert!(!state.is_channel_public("ch-vc"));
        assert!(!state.channels["ch-vc"].effective_public());
    }

    #[test]
    fn can_see_nonexistent_channel_returns_false() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "member".into(),
            display_name: "M".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&op).unwrap();
        // Non-owner gets false for a channel that doesn't exist
        assert!(!state.can_see_channel("member", "does-not-exist"));
    }

    // --- Nicknames ---

    #[test]
    fn nickname_set_and_read() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        assert_eq!(state.get_nickname("owner"), "");

        let op = state.create_op(CrdtPayload::NicknameChanged {
            peer_id: "owner".into(),
            nickname: "Boss".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_nickname("owner"), "Boss");
    }

    // --- Twitch usernames ---

    #[test]
    fn twitch_username_set_and_read() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        assert_eq!(state.get_twitch_username("owner"), "");

        let op = state.create_op(CrdtPayload::TwitchUsernameChanged {
            peer_id: "owner".into(),
            twitch_username: "cool_streamer".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_twitch_username("owner"), "cool_streamer");
    }

    // --- Pins ---

    #[test]
    fn pin_and_unpin_messages() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let ch_id = state.channels.keys().next().unwrap().clone();

        assert!(state.get_pinned_messages(&ch_id).is_empty());

        let op = state.create_op(CrdtPayload::MessagePinned {
            channel_id: ch_id.clone(),
            message_id: "msg-1".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_pinned_messages(&ch_id), vec!["msg-1"]);

        // Duplicate pin is idempotent
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_pinned_messages(&ch_id).len(), 1);

        let op = state.create_op(CrdtPayload::MessagePinned {
            channel_id: ch_id.clone(),
            message_id: "msg-2".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_pinned_messages(&ch_id).len(), 2);

        let op = state.create_op(CrdtPayload::MessageUnpinned {
            channel_id: ch_id.clone(),
            message_id: "msg-1".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_pinned_messages(&ch_id), vec!["msg-2"]);

        // Unpin last message cleans up the map entry
        let op = state.create_op(CrdtPayload::MessageUnpinned {
            channel_id: ch_id.clone(),
            message_id: "msg-2".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(!state.pinned_messages.contains_key(&ch_id));
    }

    // --- Channel layout ---

    #[test]
    fn channel_layout_update() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        assert!(state.channel_layout.is_empty());

        let layout = vec![
            ChannelLayoutItem::Category { name: "General".into() },
            ChannelLayoutItem::Channel { channel_id: "ch-1".into() },
            ChannelLayoutItem::Separator,
            ChannelLayoutItem::Channel { channel_id: "ch-2".into() },
        ];
        let layout_json = serde_json::to_string(&layout).unwrap();

        let op = state.create_op(CrdtPayload::ChannelLayoutUpdated { layout_json });
        state.apply_op(&op).unwrap();
        assert_eq!(state.channel_layout.len(), 4);
        assert_eq!(
            state.channel_layout[0],
            ChannelLayoutItem::Category { name: "General".into() }
        );
        assert_eq!(state.channel_layout[2], ChannelLayoutItem::Separator);
    }

    #[test]
    fn channel_layout_invalid_json_ignored() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::ChannelLayoutUpdated {
            layout_json: "not valid json".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(state.channel_layout.is_empty());
    }

    // --- Custom role permissions ---

    #[test]
    fn custom_role_permissions_override_defaults() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "member".into(),
            display_name: "M".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&op).unwrap();

        // Default: member can't manage channels
        assert!(!state.has_permission("member", Permission::MANAGE_CHANNELS));

        // Grant MANAGE_CHANNELS to the Member role
        let custom = Permission::SEND_MESSAGES | Permission::READ_MESSAGES | Permission::MANAGE_CHANNELS;
        let op = state.create_op(CrdtPayload::RolePermissionsChanged {
            role: "member".into(),
            permissions: custom,
        });
        state.apply_op(&op).unwrap();

        assert!(state.has_permission("member", Permission::MANAGE_CHANNELS));
        assert_eq!(state.get_role_permissions("member"), custom);
        // Owner role still returns ALL regardless of customization
        assert_eq!(state.get_role_permissions("owner"), Permission::ALL);
    }

    // --- Server settings ---

    #[test]
    fn server_setting_and_min_pledge() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());

        // Default min_pledge_mb is 512
        assert_eq!(state.min_pledge_mb(), 512);

        let op = state.create_op(CrdtPayload::ServerSettingChanged {
            key: "min_pledge_mb".into(),
            value: "1024".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.min_pledge_mb(), 1024);
    }

    // --- Server rename ---

    #[test]
    fn server_rename() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        assert_eq!(state.name(), "Test");

        let op = state.create_op(CrdtPayload::ServerRenamed {
            new_name: "Renamed Server".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.name(), "Renamed Server");
    }

    // --- Channel rename and remove ---

    #[test]
    fn channel_rename_and_remove() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-dev".into(),
            name: "dev".into(),
            category: None,
            channel_type: "text".into(),
        });
        state.apply_op(&op).unwrap();

        let op = state.create_op(CrdtPayload::ChannelRenamed {
            channel_id: "ch-dev".into(),
            new_name: "development".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.channels["ch-dev"].name, "development");

        let op = state.create_op(CrdtPayload::ChannelRemoved {
            channel_id: "ch-dev".into(),
        });
        state.apply_op(&op).unwrap();
        assert!(!state.channels.contains_key("ch-dev"));
    }

    // --- Voice channel type ---

    #[test]
    fn voice_channel_type() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::ChannelAdded {
            channel_id: "ch-vc".into(),
            name: "Voice".into(),
            category: None,
            channel_type: "voice".into(),
        });
        state.apply_op(&op).unwrap();
        assert_eq!(state.channels["ch-vc"].channel_type, ChannelType::Voice);
    }

    // --- Member removal cleans up associated data ---

    #[test]
    fn member_removal_cleans_up_all_state() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let op = state.create_op(CrdtPayload::MemberAdded {
            peer_id: "peer_b".into(),
            display_name: "B".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&op).unwrap();
        let op = state.create_op(CrdtPayload::NicknameChanged {
            peer_id: "peer_b".into(),
            nickname: "Bee".into(),
        });
        state.apply_op(&op).unwrap();
        let op = state.create_op(CrdtPayload::TwitchUsernameChanged {
            peer_id: "peer_b".into(),
            twitch_username: "bee_tv".into(),
        });
        state.apply_op(&op).unwrap();
        let op = state.create_op(CrdtPayload::StoragePledgeChanged {
            peer_id: "peer_b".into(),
            pledge_bytes: 1024,
        });
        state.apply_op(&op).unwrap();

        let op = state.create_op(CrdtPayload::MemberRemoved {
            peer_id: "peer_b".into(),
        });
        state.apply_op(&op).unwrap();

        assert!(!state.members.contains_key("peer_b"));
        assert!(!state.roles.contains_key("peer_b"));
        assert!(!state.nicknames.contains_key("peer_b"));
        assert!(!state.twitch_usernames.contains_key("peer_b"));
        assert!(!state.storage_pledges.contains_key("peer_b"));
    }

    // --- Op log compaction ---

    #[test]
    fn op_log_compacts_at_limit() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());

        // Apply 1010 ops (well past the 1000-op limit)
        for i in 0..1010 {
            let op = state.create_op(CrdtPayload::ServerSettingChanged {
                key: format!("key_{i}"),
                value: format!("val_{i}"),
            });
            state.apply_op(&op).unwrap();
        }

        // Op log should be capped at 1000
        assert!(state.op_log.len() <= 1000);

        // State should still be correct — settings from early ops are still applied
        assert_eq!(*state.settings["key_0"].read(), "val_0");
        assert_eq!(*state.settings["key_1009"].read(), "val_1009");
    }

    #[test]
    fn op_log_dedup_survives_compaction() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());

        // Fill past compaction threshold
        for i in 0..1005 {
            let op = state.create_op(CrdtPayload::ServerSettingChanged {
                key: format!("k{i}"),
                value: format!("v{i}"),
            });
            state.apply_op(&op).unwrap();
        }

        // Create a fresh op and replay it — should be accepted then deduped
        let op = state.create_op(CrdtPayload::ServerRenamed {
            new_name: "Compacted".into(),
        });
        state.apply_op(&op).unwrap();
        let before = state.op_log.len();
        state.apply_op(&op).unwrap(); // duplicate
        assert_eq!(state.op_log.len(), before);
    }

    // --- Serde backward compat ---

    #[test]
    fn serde_missing_fields_use_defaults() {
        // Simulates loading state JSON from an older version that doesn't have
        // newer fields (labels, banned_members, etc.)
        let json = r#"{
            "server_id": "s1",
            "name": {"value": "Old Server", "priority": 3, "hlc": {"physical_ms": 1000, "counter": 0, "actor": "owner"}},
            "channels": {},
            "members": {},
            "roles": {},
            "settings": {},
            "op_log": []
        }"#;
        let state: ServerState = serde_json::from_str(json).unwrap();
        assert!(state.labels.is_empty());
        assert!(state.label_assignments.is_empty());
        assert!(state.banned_members.is_empty());
        assert!(state.role_permissions.is_empty());
        assert!(state.nicknames.is_empty());
        assert!(state.twitch_usernames.is_empty());
        assert!(state.pinned_messages.is_empty());
        assert!(state.channel_layout.is_empty());
        assert!(state.channel_grants.is_empty());

        // A channel and a label serialized by a pre-issue-#32 build parse
        // with the safe defaults (no gates, cosmetic).
        let ch: ChannelInfo = serde_json::from_str(
            r#"{"channel_id":"c1","name":"general","category":null}"#,
        ).unwrap();
        assert!(ch.visibility_labels.is_empty());
        assert!(ch.posting_labels.is_empty());
        let label: LabelInfo = serde_json::from_str(
            r##"{"label_id":"l1","name":"VIP","color":"#fff"}"##,
        ).unwrap();
        assert!(!label.access);
    }

    // --- Wrong server_id rejected ---

    #[test]
    fn op_for_wrong_server_rejected() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        let mut other = test_state("s2".into(), "Other".into(), "owner".into());
        let op = other.create_op(CrdtPayload::ServerRenamed {
            new_name: "Hacked".into(),
        });
        assert!(state.apply_op(&op).is_err());
    }

    // --- labels_list sort ---

    #[test]
    fn labels_list_sorted_by_name() {
        let mut state = test_state("s1".into(), "Test".into(), "owner".into());
        for (id, name) in [("lbl-z", "Zebra"), ("lbl-a", "Alpha"), ("lbl-m", "Middle")] {
            let op = state.create_op(CrdtPayload::LabelCreated {
                label_id: id.into(),
                name: name.into(),
                color: "#000".into(),
                access: false,
            });
            state.apply_op(&op).unwrap();
        }
        let names: Vec<_> = state.labels_list().iter().map(|l| l.name.as_str()).collect();
        assert_eq!(names, vec!["Alpha", "Middle", "Zebra"]);
    }

    // --- ServerCreated op ---

    #[test]
    fn server_created_op_sets_owner() {
        // The join skeleton: a placeholder state with its seeded creator
        // stripped, so no Owner exists yet. That is the only shape a founding
        // op may act on.
        let mut state = test_state("s1".into(), "Placeholder".into(), "temp".into());
        state.members.remove("temp");
        state.roles.remove("temp");
        let op = CrdtOp {
            server_id: "s1".into(),
            hlc: HlcTimestamp { physical_ms: 1, counter: 0, actor: "new_owner".into() },
            author: "new_owner".into(),
            payload: CrdtPayload::ServerCreated {
                name: "Real Name".into(),
                owner_peer_id: "new_owner".into(),
                nonce: String::new(),
            },
            auth: None,
        };
        state.apply_op(&op).unwrap();
        assert_eq!(state.name(), "Real Name");
        assert_eq!(state.get_role("new_owner"), MemberRole::Owner);
        assert!(state.members.contains_key("new_owner"));
    }

    // --- Remote-op admission (CRDT-1 / CRDT-2) ---------------------------
    //
    // These are the inverted regression tests for the 2026-09 audit's Critical
    // CRDT findings. Each one describes an op a hostile member could put on
    // the wire before the fix; `admit_remote_op` is the single gate that now
    // refuses it, and every remote ingest path calls it.

    /// One server, owner = tag 1, member = tag 2, both able to sign as
    /// themselves. Returns (state, owner id, member keys).
    fn admitting_server() -> (ServerState, String, (NativeKeypair, String, String)) {
        let (mut state, owner_id) = owned_state("s1", "Real Server", 1);
        let member = keys(2);
        let add = state.create_op(CrdtPayload::MemberAdded {
            peer_id: member.1.clone(),
            display_name: "M".into(),
            follow: None,
            ask: None,
        });
        state.apply_op(&add).unwrap();
        (state, owner_id, member)
    }

    /// An op the owner would have authored, minus the proof. Every op on the
    /// wire before this fix looked exactly like this.
    #[test]
    fn admit_remote_rejects_unsigned_op() {
        let (state, owner_id, member) = admitting_server();
        let op = CrdtOp {
            server_id: "s1".into(),
            hlc: HlcTimestamp { physical_ms: hlc_now(), counter: 0, actor: owner_id.clone() },
            author: owner_id.clone(),
            payload: CrdtPayload::RoleChanged {
                peer_id: member.1.clone(),
                role: MemberRole::Admin,
                priority: MemberRole::Admin.priority(),
            },
            auth: None,
        };
        assert_eq!(state.admit_remote_op(&op), Err(OpReject::MissingSignature));
    }

    /// E14: the member signs its own op correctly but stamps the owner's name into
    /// the clock, which breaks LWW ties and the dedup key in the owner's name.
    #[test]
    fn admit_remote_rejects_a_clock_naming_another_author() {
        let (state, owner_id, member) = admitting_server();
        let mut op = CrdtOp {
            server_id: "s1".into(),
            hlc: HlcTimestamp { physical_ms: hlc_now(), counter: 0, actor: owner_id.clone() },
            author: member.1.clone(),
            payload: CrdtPayload::NicknameChanged {
                peer_id: member.1.clone(),
                nickname: "M".into(),
            },
            auth: None,
        };
        op.sign(&member.0, &member.2);
        assert_eq!(state.admit_remote_op(&op), Err(OpReject::ActorMismatch));
    }

    /// The member signs with its OWN key but writes the owner's id into
    /// `author` — the author-spoof that promoted anyone to Admin.
    #[test]
    fn admit_remote_rejects_author_mismatch() {
        let (state, owner_id, member) = admitting_server();
        let mut op = CrdtOp {
            server_id: "s1".into(),
            hlc: HlcTimestamp { physical_ms: hlc_now(), counter: 0, actor: member.1.clone() },
            author: owner_id.clone(),
            payload: CrdtPayload::RoleChanged {
                peer_id: member.1.clone(),
                role: MemberRole::Admin,
                priority: MemberRole::Admin.priority(),
            },
            auth: None,
        };
        op.sign(&member.0, &member.2);
        assert_eq!(state.admit_remote_op(&op), Err(OpReject::AuthorMismatch));
    }

    /// A real owner-authored op whose PAYLOAD was rewritten in flight. The
    /// key still derives the author, so only the signature catches it.
    #[test]
    fn admit_remote_rejects_bad_signature() {
        let (mut state, _owner_id, member) = admitting_server();
        let mut op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: member.1.clone(),
            role: MemberRole::Moderator,
            priority: MemberRole::Moderator.priority(),
        });
        op.payload = CrdtPayload::RoleChanged {
            peer_id: member.1.clone(),
            role: MemberRole::Admin,
            priority: MemberRole::Admin.priority(),
        };
        assert_eq!(state.admit_remote_op(&op), Err(OpReject::BadSignature));
    }

    /// CRDT-2: a validly signed op stamped at the end of time. It would win
    /// every future LWW comparison and lock the field against its real owner.
    #[test]
    fn admit_remote_rejects_future_hlc() {
        let (mut state, owner_id, _member) = admitting_server();
        let mut op = state.create_op(CrdtPayload::ServerRenamed { new_name: "PWNED".into() });
        op.hlc.physical_ms = u64::MAX;
        // Re-sign so the ONLY thing wrong with the op is its timestamp.
        let (kp, _, pk) = keys(1);
        op.sign(&kp, &pk);
        assert_eq!(op.author, owner_id, "authored by the real owner");
        assert!(op.verify_author().is_ok(), "signature itself is valid");
        assert_eq!(state.admit_remote_op(&op), Err(OpReject::FutureHlc));
    }

    /// The honest case still passes all three checks.
    #[test]
    fn admit_remote_accepts_valid_signed_op() {
        let (mut state, _owner_id, member) = admitting_server();
        let op = state.create_op(CrdtPayload::RoleChanged {
            peer_id: member.1.clone(),
            role: MemberRole::Admin,
            priority: MemberRole::Admin.priority(),
        });
        assert_eq!(state.admit_remote_op(&op), Ok(()));

        // And a member's own self-write is admitted too (no privilege needed).
        let mut replica = state.clone();
        replica.set_signer(member.0.clone(), member.2.clone());
        replica.set_hlc(Hlc::new(member.1.clone()));
        let self_op = replica.create_op(CrdtPayload::NicknameChanged {
            peer_id: member.1.clone(),
            nickname: "Em".into(),
        });
        assert_eq!(state.admit_remote_op(&self_op), Ok(()));
    }

    /// CRDT-1: the takeover. A plain member signs a perfectly valid
    /// `ServerCreated` naming ITSELF as owner of a server that already has
    /// one. The signature is real; the op is refused on the merits, and even
    /// if it reached `apply_op` it changes nothing.
    #[test]
    fn server_created_on_owned_server_is_rejected() {
        let (mut state, owner_id, member) = admitting_server();

        let mut hostile = state.clone();
        hostile.set_signer(member.0.clone(), member.2.clone());
        hostile.set_hlc(Hlc::new(member.1.clone()));
        let op = hostile.create_op(CrdtPayload::ServerCreated {
            name: "Real Server".into(),
            owner_peer_id: member.1.clone(),
            nonce: String::new(),
        });
        assert!(op.verify_author().is_ok(), "the attacker really does hold this key");
        assert_eq!(state.admit_remote_op(&op), Err(OpReject::NotAllowed));

        // Belt and braces: apply_op is a no-op even without the gate.
        state.apply_op(&op).unwrap();
        assert_eq!(state.get_role(&member.1), MemberRole::Member, "still a plain member");
        assert_eq!(state.get_role(&owner_id), MemberRole::Owner, "owner unchanged");
        assert_eq!(state.name(), "Real Server");
        assert_eq!(state.current_owner().as_deref(), Some(owner_id.as_str()));
    }

    /// The snapshot clamp: a hostile join responder stamps EVERY register in
    /// the state it hands us at the end of time. After adoption every one of
    /// them sits inside the drift bound, so honest writes can still win.
    #[test]
    fn snapshot_clamp_future_hlcs_bounds_every_register() {
        let (mut state, owner_id) = owned_state("s1", "Server", 1);
        let (_, member_id, _) = keys(2);
        for payload in [
            CrdtPayload::MemberAdded { peer_id: member_id.clone(), display_name: "M".into(), follow: None, ask: None, },
            CrdtPayload::RoleChanged {
                peer_id: member_id.clone(),
                role: MemberRole::Moderator,
                priority: MemberRole::Moderator.priority(),
            },
            CrdtPayload::NicknameChanged { peer_id: member_id.clone(), nickname: "Em".into() },
            CrdtPayload::TwitchUsernameChanged { peer_id: member_id.clone(), twitch_username: "em".into() },
            CrdtPayload::StoragePledgeChanged { peer_id: member_id.clone(), pledge_bytes: 1 },
            CrdtPayload::ServerSettingChanged { key: "k".into(), value: "v".into() },
            CrdtPayload::RolePermissionsChanged { role: "member".into(), permissions: 1 },
            CrdtPayload::MemberBanned { peer_id: "banned".into() },
            CrdtPayload::MemberMuted { peer_id: member_id.clone(), expires_at: u64::MAX },
            CrdtPayload::ChannelGrantSet {
                channel_id: "c".into(),
                peer_id: member_id.clone(),
                expires_at: u64::MAX,
            },
        ] {
            let op = state.create_op(payload);
            state.apply_op(&op).unwrap();
        }

        // Every register in the state, stamped at the end of time.
        fn poison<V: Clone>(reg: &mut AdminLwwReg<V>) {
            let far_future =
                HlcTimestamp { physical_ms: u64::MAX, counter: 0, actor: "evil".into() };
            let value = reg.read().clone();
            let priority = reg.priority();
            *reg = AdminLwwReg::new(value, far_future, priority);
        }
        poison(&mut state.name);
        for reg in state.roles.values_mut() { poison(reg); }
        for reg in state.nicknames.values_mut() { poison(reg); }
        for reg in state.twitch_usernames.values_mut() { poison(reg); }
        for reg in state.storage_pledges.values_mut() { poison(reg); }
        for reg in state.settings.values_mut() { poison(reg); }
        for reg in state.role_permissions.values_mut() { poison(reg); }
        for reg in state.banned_members.values_mut() { poison(reg); }
        for reg in state.muted_members.values_mut() { poison(reg); }
        for m in state.channel_grants.values_mut() {
            for reg in m.values_mut() { poison(reg); }
        }

        let now = hlc_now();
        let clamped = state.clamp_future_hlcs(now);
        assert!(clamped >= 11, "every poisoned register is pulled back, got {clamped}");

        let bound = now + crate::crdt::hlc::MAX_DRIFT_MS;
        fn check<V: Clone>(reg: &AdminLwwReg<V>, bound: u64) -> usize {
            assert!(
                reg.hlc().physical_ms <= bound,
                "register left beyond the drift bound: {}",
                reg.hlc().physical_ms
            );
            1
        }
        let mut checked = check(&state.name, bound);
        for reg in state.roles.values() { checked += check(reg, bound); }
        for reg in state.nicknames.values() { checked += check(reg, bound); }
        for reg in state.twitch_usernames.values() { checked += check(reg, bound); }
        for reg in state.storage_pledges.values() { checked += check(reg, bound); }
        for reg in state.settings.values() { checked += check(reg, bound); }
        for reg in state.role_permissions.values() { checked += check(reg, bound); }
        for reg in state.banned_members.values() { checked += check(reg, bound); }
        for reg in state.muted_members.values() { checked += check(reg, bound); }
        for m in state.channel_grants.values() {
            for reg in m.values() { checked += check(reg, bound); }
        }
        assert!(checked >= 11, "the walk must actually visit every register, saw {checked}");

        // The point of clamping: the field is bounded, not locked. A write at
        // the bound still outranks the clamped register and is still inside
        // the drift window, so it is admitted and it lands. Against
        // `u64::MAX` no write ever could.
        state.set_hlc(Hlc::from_saved(bound, 0, owner_id.clone()));
        let rename = state.create_op(CrdtPayload::ServerRenamed { new_name: "Fine".into() });
        assert_eq!(state.admit_remote_op(&rename), Ok(()));
        state.apply_op(&rename).unwrap();
        assert_eq!(state.name(), "Fine", "an honest write must be able to win again");
        assert_eq!(state.current_owner().as_deref(), Some(owner_id.as_str()));
    }

    fn hlc_now() -> u64 {
        crate::crdt::hlc::wall_clock_ms()
    }

    /// C1, C4, C5: every transport judges a LIVE post by OUR state: a current member
    /// who can see and post in the channel, and is not muted.
    #[test]
    fn authz_live_post_needs_a_member_who_can_see_and_post() {
        let _g = crate::node::resolver::test_lock();
        let refusal = crate::node::message_ops::live_channel_post_refusal;
        let mut s = label_gate_fixture();
        let now = epoch_ms_now();
        assert_eq!(refusal(&s, "member", "ch", false, now), None);
        assert!(refusal(&s, "stranger", "ch", false, now).is_some());

        let op = s.create_op(CrdtPayload::ChannelAdded {
            channel_id: "news".into(), name: "news".into(), category: None, channel_type: "text".into(),
        });
        s.apply_op(&op).unwrap();
        let op = s.create_op(CrdtPayload::ChannelPostingChanged {
            channel_id: "news".into(), posting: "admin".into(),
        });
        s.apply_op(&op).unwrap();
        assert!(refusal(&s, "member", "news", false, now).is_some(), "an admin-only channel");
        assert_eq!(refusal(&s, "admin", "news", false, now), None);

        let op = s.create_op(CrdtPayload::ChannelVisibilityLabelsChanged {
            channel_id: "ch".into(), labels: vec!["vip".into()],
        });
        s.apply_op(&op).unwrap();
        assert!(refusal(&s, "member", "ch", false, now).is_some(), "a channel it cannot see");
        assert_eq!(refusal(&s, "vipper", "ch", false, now), None);
    }

    /// C1: a plaintext public-channel frame is unencrypted, so anyone in the room can
    /// send one; it is taken in only for a channel that is public in our own state.
    #[test]
    fn authz_public_frame_only_for_a_channel_public_here() {
        let accepted = crate::node::message_ops::public_frame_accepted;
        let mut s = label_gate_fixture();
        assert!(!accepted(Some(&s), false, "s1", "ch"), "a private channel");
        let op = s.create_op(CrdtPayload::ChannelPublicChanged {
            channel_id: "ch".into(), is_public: true,
        });
        s.apply_op(&op).unwrap();
        assert!(accepted(Some(&s), false, "s1", "ch"));
        assert!(!accepted(Some(&s), true, "s1", "missing"), "a channel we do not have");
        assert!(!accepted(None, false, "s1", "ch"), "a server we neither hold nor view");
        assert!(accepted(None, true, "s1", "ch"), "the guest preview");
    }

    /// A legacy-shaped server: owner, an admin, a moderator and two members, with the
    /// signer installed so tests can author as the owner and override `op.author`.
    fn ranked_fixture() -> ServerState {
        let mut s = test_state("s1".into(), "S".into(), "owner".into());
        for id in ["admin", "moder", "alice", "bob"] {
            let op = s.create_op(CrdtPayload::MemberAdded {
                peer_id: id.into(), display_name: id.into(), follow: None,
                ask: None,
            });
            s.apply_op(&op).unwrap();
        }
        for (id, role) in [("admin", MemberRole::Admin), ("moder", MemberRole::Moderator)] {
            let op = s.create_op(CrdtPayload::RoleChanged { peer_id: id.into(), role, priority: 3 });
            s.apply_op(&op).unwrap();
        }
        s
    }

    /// A `MemberAdded` for `tag`'s identity on its own ask to "s1", the fixtures' server.
    fn add_on_ask(tag: u8, at: i64, follow: Option<String>) -> CrdtPayload {
        let (kp, id, _) = keys(tag);
        CrdtPayload::MemberAdded {
            peer_id: id,
            display_name: "m".into(),
            follow,
            ask: Some(crate::crdt::operations::JoinAsk::sign("s1", at, &kp)),
        }
    }

    fn allowed(s: &mut ServerState, author: &str, payload: CrdtPayload) -> bool {
        let op = op_by(s, author, payload);
        s.op_allowed(&op)
    }

    fn apply_as(s: &mut ServerState, author: &str, payload: CrdtPayload) {
        let op = op_by(s, author, payload);
        assert!(s.op_allowed(&op), "setup op refused: {:?}", op.payload);
        s.apply_op(&op).unwrap();
    }

    /// E6 + E9: only a current member authors anything, and it acts by its OWN id. A
    /// stranger, a kicked member and a device key standing in for its master get
    /// nothing, where each used to read as a Member (or as the master).
    #[test]
    fn authz_ops_need_a_member_author_acting_by_its_own_id() {
        let _lock = crate::node::resolver::test_lock();
        crate::node::resolver::clear_all();
        crate::node::resolver::update("owner_dev", "owner");
        crate::crdt::set_identity_resolver(crate::node::resolver::resolve);

        let mut s = ranked_fixture();
        let nick = |id: &str| CrdtPayload::NicknameChanged { peer_id: id.into(), nickname: "x".into() };
        assert!(allowed(&mut s, "alice", nick("alice")));
        assert!(!allowed(&mut s, "stranger", nick("stranger")), "a stranger's self op");
        assert!(!allowed(&mut s, "stranger", CrdtPayload::MemberRemoved { peer_id: "stranger".into() }));
        assert!(!allowed(&mut s, "stranger", CrdtPayload::LabelUnassigned {
            label_id: "l".into(), peer_id: "stranger".into(),
        }));

        apply_as(&mut s, "moder", CrdtPayload::MemberRemoved { peer_id: "bob".into() });
        assert!(!allowed(&mut s, "bob", nick("bob")), "a kicked member's self op");

        let rename = CrdtPayload::ServerRenamed { new_name: "Mine".into() };
        assert!(allowed(&mut s, "owner", rename.clone()));
        assert!(!allowed(&mut s, "owner_dev", rename), "a device key has no role of its own");

        crate::node::resolver::clear_all();
    }

    /// E7: every member re-checks the join gates on `MemberAdded`. Any member may admit,
    /// never past a ban, a private server, the cap, owner-verify or the Twitch gate.
    #[test]
    fn authz_member_added_rechecks_the_join_gates() {
        const CAROL: u8 = 30;
        const MALLORY: u8 = 31;
        const DAVE: u8 = 32;
        let add = |tag: u8, follow: Option<String>| add_on_ask(tag, 1, follow);
        let setting = |k: &str, v: &str| CrdtPayload::ServerSettingChanged { key: k.into(), value: v.into() };

        let mut s = ranked_fixture();
        assert!(allowed(&mut s, "alice", add(CAROL, None)), "any member admits");
        apply_as(&mut s, "alice", add(DAVE, None));
        assert!(allowed(&mut s, "alice", add(DAVE, None)), "re-adding a member is a no-op");
        apply_as(&mut s, "moder", CrdtPayload::MemberBanned { peer_id: keys(MALLORY).1 });
        assert!(!allowed(&mut s, "alice", add(MALLORY, None)), "a banned identity");

        apply_as(&mut s, "owner", setting("max_members", "6"));
        assert!(!allowed(&mut s, "alice", add(CAROL, None)), "the cap is reached");
        apply_as(&mut s, "owner", setting("max_members", "0"));
        apply_as(&mut s, "owner", setting("is_private", "true"));
        assert!(!allowed(&mut s, "owner", add(CAROL, None)), "a private server");
        apply_as(&mut s, "owner", setting("is_private", "false"));

        apply_as(&mut s, "owner", setting("twitch_verification_enabled", "true"));
        apply_as(&mut s, "owner", setting("twitch_channel_id", "12345"));
        assert!(!allowed(&mut s, "alice", add(CAROL, None)), "no follow credential");
        let at_ms = s.hlc.as_mut().unwrap().now().physical_ms;
        let period = crate::node::support_creds::period_of(at_ms / 1000);
        let mint = |tag: u8, channel: &str| {
            let entry = crate::node::support_creds::testing::mint_follow_for(&keys(tag).1, channel, 30, "0", period);
            Some(serde_json::to_string(&entry).unwrap())
        };
        assert!(allowed(&mut s, "alice", add(CAROL, mint(CAROL, "12345"))));
        assert!(!allowed(&mut s, "alice", add(CAROL, mint(MALLORY, "12345"))), "someone else's credential");
        assert!(!allowed(&mut s, "alice", add(CAROL, mint(CAROL, "999"))), "another channel's");

        apply_as(&mut s, "owner", setting("twitch_owner_verify", "true"));
        assert!(!allowed(&mut s, "admin", add(CAROL, mint(CAROL, "12345"))), "owner-verify");
        assert!(allowed(&mut s, "owner", add(CAROL, mint(CAROL, "12345"))));
    }

    /// D3: `MemberAdded` lists only an identity that signed its own ask to this
    /// server, and each ask admits once: after a leave only a newer one brings it back.
    #[test]
    fn authz_member_added_names_only_someone_who_asked() {
        use crate::crdt::operations::JoinAsk;
        let mut s = ranked_fixture();
        let (carol_kp, carol, _) = keys(30);
        let dave_kp = keys(31).0;
        let add = |ask: Option<JoinAsk>| CrdtPayload::MemberAdded {
            peer_id: carol.clone(), display_name: "c".into(), follow: None, ask,
        };
        let ask = |server: &str, at: i64, kp: &NativeKeypair| Some(JoinAsk::sign(server, at, kp));

        assert!(!allowed(&mut s, "alice", add(None)), "nobody asked");
        assert!(!allowed(&mut s, "alice", add(ask("s1", 5, &dave_kp))), "someone else's ask");
        assert!(!allowed(&mut s, "alice", add(ask("s2", 5, &carol_kp))), "an ask to another server");
        let moved = ask("s1", 5, &carol_kp).map(|a| JoinAsk { at: 6, ..a });
        assert!(!allowed(&mut s, "alice", add(moved)), "an ask whose time was changed");

        apply_as(&mut s, "alice", add(ask("s1", 5, &carol_kp)));
        apply_as(&mut s, &carol, CrdtPayload::MemberRemoved { peer_id: carol.clone() });
        assert!(!allowed(&mut s, "alice", add(ask("s1", 5, &carol_kp))), "the ask that admitted her once");
        assert!(!allowed(&mut s, "alice", add(ask("s1", 4, &carol_kp))), "an older one");
        assert!(allowed(&mut s, "alice", add(ask("s1", 9, &carol_kp))), "a newer ask");
    }

    /// D6: a restricted channel is never public: it cannot be flagged public, restricting
    /// it clears the flag for good, and a state holding both reads it as restricted.
    #[test]
    fn authz_a_restricted_channel_is_never_public() {
        let mut s = ranked_fixture();
        let ch = "s1-general".to_string();
        let public = |on: bool| CrdtPayload::ChannelPublicChanged { channel_id: ch.clone(), is_public: on };
        let tier = |v: &str| CrdtPayload::ChannelVisibilityChanged { channel_id: ch.clone(), visibility: v.into() };
        let labels = |l: &[&str]| CrdtPayload::ChannelVisibilityLabelsChanged {
            channel_id: ch.clone(), labels: l.iter().map(|x| x.to_string()).collect(),
        };

        apply_as(&mut s, "admin", public(true));
        assert!(s.is_channel_public(&ch));
        apply_as(&mut s, "admin", tier("admin"));
        assert!(!s.is_channel_public(&ch), "restricting closes it");
        assert!(s.subgroup_channel_ids().contains(&ch), "and its posts ride its own group");
        assert!(!allowed(&mut s, "admin", public(true)), "a restricted channel is flagged public");
        assert!(allowed(&mut s, "admin", public(false)));
        apply_as(&mut s, "admin", tier("everyone"));
        assert!(!s.is_channel_public(&ch), "lifting the restriction reopens it to guests");

        apply_as(&mut s, "admin", public(true));
        apply_as(&mut s, "admin", labels(&["vip"]));
        assert!(!s.is_channel_public(&ch), "a label gate closes it");
        assert!(!allowed(&mut s, "admin", public(true)), "a label-gated channel is flagged public");
        apply_as(&mut s, "admin", labels(&[]));
        assert!(!s.is_channel_public(&ch));

        apply_as(&mut s, "admin", public(true));
        let both = s.channels.get_mut(&ch).unwrap();
        both.visibility = ChannelVisibility::ModeratorPlus;
        assert!(!s.is_channel_public(&ch), "a state holding both flags reads as restricted");
    }

    /// E11: lifting a ban or mute needs the rank that set it, nickname-class edits of
    /// others reach only lower ranks, and role permissions grant only what the author
    /// holds, for a role that exists.
    #[test]
    fn authz_moderation_edges_respect_rank() {
        let mut s = ranked_fixture();
        apply_as(&mut s, "admin", CrdtPayload::MemberBanned { peer_id: "mallory".into() });
        assert!(!allowed(&mut s, "moder", CrdtPayload::MemberUnbanned { peer_id: "mallory".into() }));
        assert!(allowed(&mut s, "admin", CrdtPayload::MemberUnbanned { peer_id: "mallory".into() }));
        apply_as(&mut s, "admin", CrdtPayload::MemberMuted { peer_id: "alice".into(), expires_at: u64::MAX });
        assert!(!allowed(&mut s, "moder", CrdtPayload::MemberUnmuted { peer_id: "alice".into() }));
        assert!(allowed(&mut s, "admin", CrdtPayload::MemberUnmuted { peer_id: "alice".into() }));

        let op = s.create_op(CrdtPayload::MemberAdded {
            peer_id: "admin2".into(), display_name: "a2".into(), follow: None,
            ask: None,
        });
        s.apply_op(&op).unwrap();
        apply_as(&mut s, "owner", CrdtPayload::RoleChanged {
            peer_id: "admin2".into(), role: MemberRole::Admin, priority: 3,
        });
        let nick = |id: &str| CrdtPayload::NicknameChanged { peer_id: id.into(), nickname: "x".into() };
        let pledge = |id: &str| CrdtPayload::StoragePledgeChanged { peer_id: id.into(), pledge_bytes: 1 };
        assert!(allowed(&mut s, "admin", nick("alice")));
        assert!(!allowed(&mut s, "admin", nick("admin2")), "an equal rank");
        assert!(!allowed(&mut s, "admin", pledge("admin2")));
        assert!(!allowed(&mut s, "admin", nick("stranger")), "not a member");

        let perms = |role: &str, bits: u32| CrdtPayload::RolePermissionsChanged { role: role.into(), permissions: bits };
        apply_as(&mut s, "owner", perms("admin", Permission::MANAGE_ROLES | Permission::SEND_MESSAGES));
        assert!(allowed(&mut s, "admin", perms("moderator", Permission::SEND_MESSAGES)));
        assert!(!allowed(&mut s, "admin", perms("moderator", Permission::KICK_MEMBERS)), "a bit it lacks");
        assert!(!allowed(&mut s, "owner", perms("moderator", 1 << 20)), "a bit that does not exist");
        assert!(!allowed(&mut s, "owner", perms("owner", 0)));
        assert!(!allowed(&mut s, "owner", perms("superadmin", 0)), "a role that does not exist");
    }

    /// E12: the owner is fixed for the life of the server.
    #[test]
    fn authz_the_owner_is_fixed() {
        let mut s = ranked_fixture();
        let role = |id: &str, r: MemberRole| CrdtPayload::RoleChanged { peer_id: id.into(), role: r, priority: 3 };
        assert!(!allowed(&mut s, "owner", role("admin", MemberRole::Owner)), "no co-owners");
        assert!(!allowed(&mut s, "owner", role("owner", MemberRole::Admin)), "no self-demotion");
        assert!(!allowed(&mut s, "owner", CrdtPayload::MemberRemoved { peer_id: "owner".into() }));
        assert!(!allowed(&mut s, "admin", CrdtPayload::MemberBanned { peer_id: "owner".into() }));
        assert!(!allowed(&mut s, "admin", CrdtPayload::MemberMuted { peer_id: "owner".into(), expires_at: 1 }));
        assert!(!allowed(&mut s, "owner", CrdtPayload::MemberBanned { peer_id: "owner".into() }), "nor itself");
        assert!(!allowed(&mut s, "owner", CrdtPayload::MemberMuted { peer_id: "owner".into(), expires_at: 1 }));
        assert!(!allowed(&mut s, "admin", CrdtPayload::NicknameChanged { peer_id: "owner".into(), nickname: "x".into() }));
        assert!(!allowed(&mut s, "owner", CrdtPayload::ServerCreated {
            name: "S".into(), owner_peer_id: "owner".into(), nonce: String::new(),
        }), "a founding op on a state that has its owner");
        assert!(!allowed(&mut s, "owner", role("stranger", MemberRole::Admin)), "a role for a non-member");
    }

    /// E8: on a legacy server, a device-keyed role, ban or mute register never demotes,
    /// bans or mutes the Owner or a Moderator+ when its device is later resolved. A
    /// plain member's device-keyed ban is still adopted.
    #[test]
    fn authz_device_registers_never_demote_ban_or_mute_the_owner_or_a_moderator() {
        let mut s = ranked_fixture();
        let hlc = s.hlc.as_mut().unwrap().now();
        s.roles.insert("owner_dev".into(), AdminLwwReg::new(MemberRole::Member, hlc.clone(), 2));
        s.muted_members.insert("owner_dev".into(), AdminLwwReg::new(u64::MAX, hlc.clone(), 2));
        s.banned_members.insert("moder_dev".into(), AdminLwwReg::new(true, hlc.clone(), 2));
        s.banned_members.insert("alice_dev".into(), AdminLwwReg::new(true, hlc, 2));
        s.canonicalize_members(|id| id.strip_suffix("_dev").unwrap_or(id).to_string());
        assert_eq!(s.get_role("owner"), MemberRole::Owner);
        assert!(!s.is_muted("owner", 0));
        assert!(!s.is_banned("moder"));
        assert!(s.is_banned("alice"), "a plain member's device-keyed ban is adopted");
    }
}
