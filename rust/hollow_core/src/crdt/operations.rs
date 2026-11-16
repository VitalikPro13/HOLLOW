use base64::Engine as _;
use serde::{Deserialize, Serialize};

use super::hlc::HlcTimestamp;
use crate::identity::native_identity::NativeKeypair;

/// The author's proof that it really wrote this op.
///
/// `sig` is the base64 Ed25519 signature over [`CrdtOp::signing_payload`] and `pk` the
/// base64 protobuf public key it verifies against, whose derived peer_id must equal
/// the op's `author`. Boxed because a `CrdtOp` rides async frames with a tight stack.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CrdtAuth {
    pub sig: String,
    pub pk: String,
}

/// Why an op was refused at ingest. Log text only; never shown to a user.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpReject {
    /// No `auth` block at all (an unsigned op, or one stripped in transit).
    MissingSignature,
    /// The signing key does not derive the claimed `author` peer_id.
    AuthorMismatch,
    /// The op's clock names someone other than its author.
    ActorMismatch,
    /// The signature does not verify over the op's signing payload.
    BadSignature,
    /// The op's HLC sits further ahead of our wall clock than the drift bound.
    FutureHlc,
    /// The op is for a different server than the state it was handed to.
    WrongServer,
    /// The author lacks the permission this payload requires (`op_allowed`).
    NotAllowed,
    /// The signed op is larger than any honest one (`crdt::fold::MAX_OP_BYTES`).
    TooLarge,
}

impl std::fmt::Display for OpReject {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            Self::MissingSignature => "no author signature",
            Self::AuthorMismatch => "signing key does not match the author",
            Self::ActorMismatch => "clock names someone other than the author",
            Self::BadSignature => "signature does not verify",
            Self::FutureHlc => "timestamp too far ahead of the wall clock",
            Self::WrongServer => "op belongs to another server",
            Self::NotAllowed => "author lacks permission for this operation",
            Self::TooLarge => "op larger than the bound",
        };
        f.write_str(s)
    }
}

/// A single CRDT operation — the unit of replication.
///
/// Each op is self-contained and both idempotent and commutative.
///
/// SECURITY: `author` is a claim until `auth` proves it. Every remote ingest path runs
/// `ServerState::ingest_remote`, which rejects an op with no `auth`, an `auth` whose
/// key derives a different peer_id, or a signature that does not verify. There is no
/// tolerance branch: an `if auth.is_some()` gate would be the bypass.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CrdtOp {
    pub server_id: String,
    pub hlc: HlcTimestamp,
    pub author: String,
    pub payload: CrdtPayload,
    /// Author proof. `Option` for wire tolerance only: an op arriving without it parses
    /// and is then rejected with `MissingSignature`, where a parse failure would be
    /// indistinguishable from the unknown payload variants the tolerant parse skips.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auth: Option<Box<CrdtAuth>>,
    /// Which device of the author wrote it (DEVICE_PROOF_DESIGN section 6). Outside the
    /// master-signed bytes, so the content id ignores it; a proof that fails reads as none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dev: Option<Box<DevProof>>,
}

/// A device's proof over an op: its key over `hollow-crdt-dev1:` + the op's master-signed
/// payload. It proves which device wrote the op, never that the device may.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DevProof {
    pub device: String,
    pub sig: String,
}

impl CrdtOp {
    /// Canonical signing payload:
    ///   `hollow-crdt1:{server_id}:{physical_ms}:{counter}:{actor}:{author}:{payload_json}`
    ///
    /// Every field before the payload is colon-free, so the free-form JSON stays LAST and
    /// the layout is unambiguous, the same rule as `hollow-msg2`. Deterministic because
    /// no `CrdtPayload` variant carries a map or a set.
    pub fn signing_payload(&self) -> String {
        let payload_json = serde_json::to_string(&self.payload).unwrap_or_default();
        signing_payload(&self.server_id, &self.hlc, &self.author, &payload_json)
    }

    /// The op's identity beyond its dedup key: SHA-256 of the bytes its master signed, so
    /// two ops at one (author, clock) are told apart and every replica keeps the lower.
    pub fn content_hash(&self) -> [u8; 32] {
        use sha2::Digest;
        sha2::Sha256::digest(self.signing_payload().as_bytes()).into()
    }

    /// Sign this op with the MASTER keypair: `author` and the state's maps are
    /// master-keyed, so a device key would never derive the author id.
    pub fn sign(&mut self, keypair: &NativeKeypair, pk_b64: &str) {
        let sig = keypair.sign(self.signing_payload().as_bytes());
        self.auth = Some(Box::new(CrdtAuth {
            sig: base64::engine::general_purpose::STANDARD.encode(sig),
            pk: pk_b64.to_string(),
        }));
    }

    /// Add the device proof of `device`, the keypair of the device whose lane minted the clock.
    pub fn sign_device(&mut self, device: &NativeKeypair) {
        let sig = device.sign(dev_payload(&self.signing_payload()).as_bytes());
        self.dev = Some(Box::new(DevProof {
            device: device.peer_id(),
            sig: base64::engine::general_purpose::STANDARD.encode(sig),
        }));
    }

    /// The device this op's proof names, when the proof verifies: the signature checks
    /// under the key the id derives, and the clock sits in that device's lane.
    pub fn proven_device(&self) -> Option<&str> {
        let dev = self.dev.as_deref()?;
        (dev_proof_verifies(dev, &self.hlc, &self.signing_payload())).then_some(dev.device.as_str())
    }

    /// Drop a proof that does not verify, so a stored copy only ever carries a good one.
    pub fn strip_bad_proof(&mut self) {
        if self.dev.is_some() && self.proven_device().is_none() {
            self.dev = None;
        }
    }

    /// Bind this op to its claimed `author`: the key must derive that peer_id, the clock
    /// must name it, and the signature must verify over the signing payload. REJECTS,
    /// never logs and continues.
    pub fn verify_author(&self) -> Result<(), OpReject> {
        verify_signed(&self.author, &self.hlc, self.auth.as_deref(), &self.signing_payload())
    }
}

/// `CrdtOp::signing_payload` over a payload's exact JSON, which an op this build cannot
/// parse still carries.
pub(crate) fn signing_payload(server_id: &str, hlc: &HlcTimestamp, author: &str, payload_json: &str) -> String {
    format!(
        "hollow-crdt1:{}:{}:{}:{}:{}:{}",
        server_id, hlc.physical_ms, hlc.counter, hlc.actor, author, payload_json,
    )
}

fn dev_payload(signing_payload: &str) -> String {
    format!("hollow-crdt-dev1:{signing_payload}")
}

pub(crate) fn dev_proof_verifies(dev: &DevProof, hlc: &HlcTimestamp, signing_payload: &str) -> bool {
    use base64::Engine as _;
    if hlc.counter % super::hlc::LANES != super::hlc::lane_of(&dev.device) {
        return false;
    }
    let Some(key) = crate::crypto::safety_number::pubkey_from_peer_id(&dev.device) else { return false };
    let Ok(sig) = base64::engine::general_purpose::STANDARD.decode(&dev.sig) else { return false };
    let Ok(sig) = <[u8; 64]>::try_from(sig.as_slice()) else { return false };
    let Ok(vk) = ed25519_dalek::VerifyingKey::from_bytes(&key) else { return false };
    vk.verify_strict(dev_payload(signing_payload).as_bytes(), &ed25519_dalek::Signature::from_bytes(&sig)).is_ok()
}

fn verify_signed(author: &str, hlc: &HlcTimestamp, auth: Option<&CrdtAuth>, signed: &str) -> Result<(), OpReject> {
    let auth = auth.ok_or(OpReject::MissingSignature)?;
    let b64 = base64::engine::general_purpose::STANDARD;
    let pk_bytes = b64.decode(&auth.pk).map_err(|_| OpReject::AuthorMismatch)?;
    let derived = NativeKeypair::peer_id_from_pubkey_protobuf(&pk_bytes)
        .ok_or(OpReject::AuthorMismatch)?;
    if derived != author {
        return Err(OpReject::AuthorMismatch);
    }
    // Every honest op is stamped by its author's own clock (`create_op`), and the
    // actor breaks LWW ties and keys the dedup set.
    if hlc.actor != author {
        return Err(OpReject::ActorMismatch);
    }
    let sig_bytes = b64.decode(&auth.sig).map_err(|_| OpReject::BadSignature)?;
    match NativeKeypair::verify_peer_signature(&pk_bytes, &sig_bytes, signed.as_bytes()) {
        Ok(true) => Ok(()),
        _ => Err(OpReject::BadSignature),
    }
}

/// A signed op this build cannot read whole: a newer client's variant, or a field of a
/// known variant this build drops (the re-serialized payload would fail its signature).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnreadOp {
    pub server_id: String,
    pub author: String,
    pub hlc: HlcTimestamp,
    /// The op's exact JSON, which a later build may read.
    pub raw: String,
}

/// One op's JSON as this build reads it.
#[derive(Debug)]
pub enum ReadOp {
    Op(CrdtOp),
    /// Its author signed these exact bytes, and this build cannot read them whole.
    Unread(UnreadOp),
    /// Not an op, or an unknown payload nobody signed.
    Junk,
}

/// Read one op. An op whose payload re-serializes to other bytes than it came with lost
/// something in the parse: when the author's signature covers the bytes it came with,
/// it is unread, never handed to the fold as a forgery.
pub fn read_op(item: &str) -> ReadOp {
    #[derive(Deserialize)]
    struct Shape<'a> {
        server_id: String,
        hlc: HlcTimestamp,
        author: String,
        #[serde(borrow)]
        payload: &'a serde_json::value::RawValue,
        #[serde(default)]
        auth: Option<Box<CrdtAuth>>,
        #[serde(default)]
        dev: Option<Box<DevProof>>,
    }
    let Ok(shape) = serde_json::from_str::<Shape>(item) else { return ReadOp::Junk };
    let raw = shape.payload.get();
    let parsed = serde_json::from_str::<CrdtPayload>(raw).ok();
    let whole = parsed.as_ref().is_some_and(|p| serde_json::to_string(p).is_ok_and(|again| again == raw));
    if !whole {
        let signed = signing_payload(&shape.server_id, &shape.hlc, &shape.author, raw);
        if verify_signed(&shape.author, &shape.hlc, shape.auth.as_deref(), &signed).is_ok() {
            return ReadOp::Unread(UnreadOp { server_id: shape.server_id, author: shape.author, hlc: shape.hlc, raw: item.to_string() });
        }
    }
    match parsed {
        Some(payload) => {
            ReadOp::Op(CrdtOp { server_id: shape.server_id, hlc: shape.hlc, author: shape.author, payload, auth: shape.auth, dev: shape.dev })
        }
        None => ReadOp::Junk,
    }
}

/// A server's join secret as the CRDT carries it: 64 hex on the wire, never in a
/// log line.
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(transparent)]
pub struct JoinSecret(pub String);

impl std::fmt::Debug for JoinSecret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("JoinSecret(..)")
    }
}

/// A joiner's own signed ask to join one server (D3): a `MemberAdded` lists only
/// someone who asked, and each ask admits once.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JoinAsk {
    /// The request's `requested_at`, in the joiner's own clock.
    pub at: i64,
    pub sig: String,
    pub pk: String,
    /// The invite key (public half, `key=`) the ask was made with. Signed when present,
    /// so an admission after an invite reset tells the old link from the new one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    /// The joiner's own leave this ask follows, signed (`hollow-join-ask3`): an ask made
    /// before a later leave of ours never re-admits us, in the fold as well as live.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub follows: Option<AskFollows>,
}

/// What a rejoin's ask names of the leave before it (w2-d follow-up, HOL-SEC-207).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AskFollows {
    /// The leave that ended our membership as members fold it (`LeaveBook::ask_floor`).
    pub leave: super::hlc::HlcTimestamp,
    /// Our wall clock when the ask was signed: `at` may sit past the wall by a clock
    /// lead, so an ask whose named leave was followed by another counts by this instead.
    pub made: i64,
}

impl JoinAsk {
    fn signing_payload(server_id: &str, joiner: &str, at: i64, key: Option<&str>) -> Vec<u8> {
        Self::signing_payload_full(server_id, joiner, at, key, None)
    }

    fn signing_payload_full(server_id: &str, joiner: &str, at: i64, key: Option<&str>, follows: Option<&AskFollows>) -> Vec<u8> {
        let head: &[u8] = match (follows, key) {
            (Some(_), _) => b"hollow-join-ask3\0",
            (None, Some(_)) => b"hollow-join-ask2\0",
            (None, None) => b"hollow-join-ask1\0",
        };
        let mut out = [head, server_id.as_bytes(), b"\0", joiner.as_bytes(), b"\0", at.to_string().as_bytes()].concat();
        if let Some(key) = key {
            out.push(0);
            out.extend_from_slice(key.as_bytes());
        }
        if let Some(f) = follows {
            // ask3 always carries the key slot, empty for none, so no field can shift.
            if key.is_none() {
                out.push(0);
            }
            for field in [f.leave.physical_ms.to_string(), f.leave.counter.to_string(), f.leave.actor.clone(), f.made.to_string()] {
                out.push(0);
                out.extend_from_slice(field.as_bytes());
            }
        }
        out
    }

    /// `keypair`'s ask to join `server_id`, made at `at`, naming no invite key.
    pub fn sign(server_id: &str, at: i64, keypair: &NativeKeypair) -> Self {
        Self::sign_with(server_id, at, None, keypair)
    }

    /// `keypair`'s ask to join `server_id`, made at `at` with the invite key `key=`,
    /// named in its canonical text form; `None` when `key` is no key.
    pub fn sign_for_invite(server_id: &str, at: i64, key: &str, keypair: &NativeKeypair) -> Option<Self> {
        let key = crate::node::sealed_box::key_from_text(key).map(|k| crate::node::sealed_box::key_to_text(&k))?;
        Some(Self::sign_with(server_id, at, Some(key), keypair))
    }

    /// A key named in the one text form an honest signer writes (HOL-SEC-143).
    fn canonical_key(key: &str) -> bool {
        crate::node::sealed_box::key_from_text(key).is_some_and(|k| crate::node::sealed_box::key_to_text(&k) == key)
    }

    fn sign_with(server_id: &str, at: i64, key: Option<String>, keypair: &NativeKeypair) -> Self {
        Self::sign_full(server_id, at, key, None, keypair)
    }

    /// `keypair`'s ask to join `server_id` at `at`, with the invite key `key` (none when
    /// `None`; `None` back when `key` is no key) and, for a rejoin, the leave of ours it
    /// follows, signed at our wall clock `made`. The leave is named only when `at` leads
    /// `made`: an ask stamped at or before the wall clock signs the exact 0.14.0 bytes.
    pub fn sign_rejoin(
        server_id: &str,
        at: i64,
        key: Option<&str>,
        follows: Option<&super::hlc::HlcTimestamp>,
        made: i64,
        keypair: &NativeKeypair,
    ) -> Option<Self> {
        let key = match key {
            Some(key) => Some(crate::node::sealed_box::key_from_text(key).map(|k| crate::node::sealed_box::key_to_text(&k))?),
            None => None,
        };
        // A 0.14.0 replica keeps an ask3 admission unread and never counts the joiner, so
        // ask3 only where the old rule cannot judge: a stamp past our own wall clock (an
        // ask stamped at or before its signing is judged by that stamp, HOL-SEC-207). A
        // leave clock whose actor is no peer id is no leave of ours: the ask names none.
        let follows = follows
            .filter(|_| at > made)
            .filter(|leave| crate::node::witness::peer_id_shape(&leave.actor))
            .map(|leave| AskFollows { leave: leave.clone(), made });
        Some(Self::sign_full(server_id, at, key, follows, keypair))
    }

    fn sign_full(server_id: &str, at: i64, key: Option<String>, follows: Option<AskFollows>, keypair: &NativeKeypair) -> Self {
        let b64 = base64::engine::general_purpose::STANDARD;
        let payload = Self::signing_payload_full(server_id, &keypair.peer_id(), at, key.as_deref(), follows.as_ref());
        let sig = keypair.sign(&payload);
        Self { at, sig: b64.encode(sig), pk: b64.encode(keypair.public_key_protobuf()), key, follows }
    }

    /// Whether `joiner`'s own key signed this ask for `server_id`.
    pub fn verifies(&self, server_id: &str, joiner: &str) -> bool {
        let b64 = base64::engine::general_purpose::STANDARD;
        let (Ok(pk), Ok(sig)) = (b64.decode(&self.pk), b64.decode(&self.sig)) else { return false };
        if self.key.as_deref().is_some_and(|key| !Self::canonical_key(key)) {
            return false;
        }
        // HOL-SEC-143: the one free-text field the payload joins is a peer id, never a
        // separator.
        if self.follows.as_ref().is_some_and(|f| !crate::node::witness::peer_id_shape(&f.leave.actor)) {
            return false;
        }
        let payload = Self::signing_payload_full(server_id, joiner, self.at, self.key.as_deref(), self.follows.as_ref());
        NativeKeypair::peer_id_from_pubkey_protobuf(&pk).is_some_and(|id| id == joiner)
            && matches!(
                NativeKeypair::verify_peer_signature(&pk, &sig, &payload),
                Ok(true)
            )
    }

    /// Whether a 0.14.0 replica reads this ask whole and verifies it: its `JoinAsk` (the
    /// struct below, as 0.14.0 declared it) must re-serialize to the same bytes, else its
    /// `read_op` keeps the admission unread, and only the ask1/ask2 payload verifies there.
    #[cfg(test)]
    pub(crate) fn reads_as_0140(&self, server_id: &str, joiner: &str) -> bool {
        #[derive(Serialize, Deserialize)]
        struct JoinAsk0140 {
            at: i64,
            sig: String,
            pk: String,
            #[serde(default, skip_serializing_if = "Option::is_none")]
            key: Option<String>,
        }
        let Ok(json) = serde_json::to_string(self) else { return false };
        let whole = serde_json::from_str::<JoinAsk0140>(&json).is_ok_and(|old| serde_json::to_string(&old).is_ok_and(|again| again == json));
        whole && JoinAsk { follows: None, ..self.clone() }.verifies(server_id, joiner)
    }
}

/// What a kick or ban of a member names of the grants that member made in the span it
/// closes (AR-11): every target op of a power-granting kind dated inside that span and
/// not named here, nor decided by the remover's base, is void (`crdt::voids`). A
/// kicked member therefore cannot backdate an admission, promotion or grant to just
/// before its removal.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SeenGrants {
    /// The remover's base: (generation, content hash in hex). What it decides counts as
    /// seen; a replica that cannot tell holds the removal.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<(u64, String)>,
    /// The first 16 bytes, in hex, of each seen op's content hash, at most
    /// `crdt::voids::SEEN_CAP` (about 36 KB), the newest first.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ops: Vec<String>,
    /// Set when `ops` was cut at its bound: a target op dated before it counts as seen.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<HlcTimestamp>,
}

/// The payload of a CRDT operation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum CrdtPayload {
    // Server-level
    /// The founding op. A non-empty `nonce` makes the server id self-certifying
    /// (`anchor::derive_server_id`); empty on every server founded before 0.12, and
    /// skipped when empty so those ops keep the bytes their signature covers.
    ServerCreated {
        name: String,
        owner_peer_id: String,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        nonce: String,
    },
    /// The owner's full materialized state, which REPLACES everything folded before it:
    /// the anchor an existing server rebuilds on, and the compaction point of any
    /// server. JSON of a `ServerState` without its op log, clock or signer.
    ///
    /// It sits in the fold at `covers`, the newest clock the state reflects, never at
    /// its own: ops newer than that, including ones the owner had not seen, fold on
    /// top of it rather than vanishing under it.
    ServerCheckpoint {
        state: String,
        covers: HlcTimestamp,
    },
    ServerRenamed {
        new_name: String,
    },
    ServerSettingChanged {
        key: String,
        value: String,
    },
    /// The server's X25519 join secret, 64 hex, set by the Owner only. Members hold
    /// it and invite links carry its public half, so what a joiner and the members
    /// say before the joiner is in stays sealed from the relay (claim C-24).
    JoinKeySet {
        secret: JoinSecret,
    },
    /// A join lock (`node/join_lock.rs`): its link, the door's secret half for every
    /// member, and its change key sealed to each owner, admin and mod by master. The
    /// relay took the link before the op was written. A later op for the same link
    /// adds grants or the owner's compacting signature.
    JoinLock {
        link: crate::node::join_lock::LockLink,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        door: Option<JoinSecret>,
        #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
        grants: std::collections::BTreeMap<String, String>,
    },
    /// Server deletion tombstone, owner-authored only (validated at ingest). Marks the
    /// state `deleted` and drains membership, but survives in the op_log so reconnecting
    /// members reconcile through ordinary grow-only sync.
    ServerDeleted {
        deleted_at: i64,
    },

    // Channel operations
    ChannelAdded {
        channel_id: String,
        name: String,
        category: Option<String>,
        #[serde(default)]
        channel_type: String,
    },
    ChannelRemoved {
        channel_id: String,
    },
    ChannelRenamed {
        channel_id: String,
        new_name: String,
    },

    // Member operations
    /// `follow` is the joiner's Twitch follow credential, copied in by the admitter
    /// so every member re-checks the gate; absent (and not serialized) otherwise.
    /// `ask` is the joiner's own, copied in the same way; none is refused.
    MemberAdded {
        peer_id: String,
        display_name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        follow: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ask: Option<JoinAsk>,
    },
    /// A removal of someone else (a kick) carries what the remover had seen of the
    /// target's grants; a member's own leave carries none.
    MemberRemoved {
        peer_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seen: Option<Box<SeenGrants>>,
    },

    // Role operations
    RoleChanged {
        peer_id: String,
        role: MemberRole,
        priority: u8,
    },

    // Nickname operations
    NicknameChanged {
        peer_id: String,
        nickname: String,
    },

    // Twitch username (set on Twitch-verified join)
    TwitchUsernameChanged {
        peer_id: String,
        twitch_username: String,
    },

    // Channel layout (ordering/categories)
    ChannelLayoutUpdated {
        layout_json: String,
    },

    // Pin operations
    MessagePinned {
        channel_id: String,
        message_id: String,
    },
    MessageUnpinned {
        channel_id: String,
        message_id: String,
    },

    // Storage pledge (Phase 4)
    StoragePledgeChanged {
        peer_id: String,
        pledge_bytes: u64,
    },

    // Role permissions customization (Phase 6.75)
    RolePermissionsChanged {
        role: String,
        permissions: u32,
    },

    // Labels — cosmetic roles (Phase 6.75); `access` labels additionally gate
    // channels (issue #32) and are never self-assignable.
    LabelCreated {
        label_id: String,
        name: String,
        color: String,
        #[serde(default)]
        access: bool,
    },
    LabelDeleted {
        label_id: String,
    },
    /// `access: None` = preserve the stored flag — a client that predates the
    /// field must not silently strip access-status off a label (that would
    /// re-open self-assignment on a security boundary).
    LabelUpdated {
        label_id: String,
        name: String,
        color: String,
        #[serde(default)]
        access: Option<bool>,
    },
    LabelAssigned {
        label_id: String,
        peer_id: String,
    },
    LabelUnassigned {
        label_id: String,
        peer_id: String,
    },

    // Channel access control (Phase 6.75)
    ChannelVisibilityChanged {
        channel_id: String,
        visibility: String,
    },
    ChannelPostingChanged {
        channel_id: String,
        posting: String,
    },
    ChannelPublicChanged {
        channel_id: String,
        is_public: bool,
    },
    /// Label-gated visibility (issue #32): non-empty means only holders of a listed
    /// label (plus Admin+/Owner) see the channel, empty is back to the tier ladder.
    /// Authored paired with an admin visibility stamp so older clients still hide it.
    ChannelVisibilityLabelsChanged {
        channel_id: String,
        labels: Vec<String>,
    },
    /// Label-gated posting; same semantics as the visibility twin.
    ChannelPostingLabelsChanged {
        channel_id: String,
        labels: Vec<String>,
    },
    /// Time-boxed per-member channel access (visibility + posting).
    /// `expires_at` = epoch ms; `u64::MAX` = until revoked. LWW per
    /// (channel, member), mirroring MemberMuted.
    ChannelGrantSet {
        channel_id: String,
        peer_id: String,
        expires_at: u64,
    },
    ChannelGrantRevoked {
        channel_id: String,
        peer_id: String,
    },

    // Ban system (Phase 6.75)
    MemberBanned {
        peer_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seen: Option<Box<SeenGrants>>,
    },
    MemberUnbanned {
        peer_id: String,
    },

    // Moderation trio (mute / slow mode / media-only)
    /// Server-wide mute (read-only member). `expires_at` = epoch ms;
    /// `u64::MAX` = permanent.
    MemberMuted {
        peer_id: String,
        expires_at: u64,
    },
    MemberUnmuted {
        peer_id: String,
    },
    /// Per-channel slow mode: min seconds between posts per member (0 = off).
    ChannelSlowModeChanged {
        channel_id: String,
        seconds: u32,
    },
    /// Per-channel media-only: only image/video/GIF attachments allowed.
    ChannelMediaOnlyChanged {
        channel_id: String,
        media_only: bool,
    },
    /// A voice channel's text chat: follow the server's `voice_text_chat`, or
    /// override it on or off (#107).
    ChannelVoiceChatChanged {
        channel_id: String,
        mode: super::server_state::VoiceChat,
    },

    // Custom emotes (server emote set)
    /// Add (or replace, same name) a custom emote. The CRDT carries METADATA ONLY:
    /// `hash` addresses the processed WebP and the bytes replicate on demand,
    /// content-addressed and receiver-verified.
    EmojiAdded {
        name: String,
        hash: String,
        animated: bool,
    },
    EmojiRemoved {
        name: String,
    },

    // Sticker packs (server sticker set)
    /// Add (or replace, same hash) a sticker in the server's set, METADATA ONLY like
    /// emotes.
    ///
    /// Keyed by HASH, not name: a sticker is picked visually, so its name is a label two
    /// stickers may share. `pack` groups them in the picker and `w`/`h` let it reserve
    /// the right cell before any bytes arrive.
    StickerAdded {
        hash: String,
        name: String,
        pack: String,
        animated: bool,
        w: u32,
        h: u32,
    },
    StickerRemoved {
        hash: String,
    },

    // Device proof (DEVICE_PROOF_DESIGN section 8.2)
    /// `device` stops counting: the author's ops it names (by clock and content id) stay
    /// counted as that device wrote them. Folds nothing; it is read by the verdict.
    DeviceRetired {
        device: String,
        /// At most `MAX_RETIRED_REFS`, strictly sorted by (ms, c, h).
        ops: Vec<OpRef>,
        /// The newest post window of `device` (section 13).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        posts_until_ms: Option<i64>,
        /// A member's lost-or-stolen retire only: its restore checkpoint (section 8.3). It
        /// endorses nothing.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        restore: Option<String>,
    },
    /// One device's signature of a settling (section 7, RC32-4): owner-authored, its
    /// stamp carries exactly that device's signature. Never folded; stored with the
    /// stamp's parent checkpoint as the settling's mark.
    SettleSign {
        stamp: SettleStamp,
    },
    /// A member's record of the server as it held it when it heard of a recovery that
    /// dropped the only checkpoint writer (section 8.8): names checkpoint `cp` (content id
    /// hex), which rides along as a pin. Never folded; the oldest of the counted marks on
    /// one line is the floor.
    FloorMark {
        cp: String,
    },
}

/// A settling's stamp (section 7): the settling id covers every field before `sigs`, and
/// each signature is a device key over that id, so a stamp verifies without the
/// checkpoint's state and another device can co-sign the same settling.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettleStamp {
    pub server: String,
    /// The settling's parent checkpoint, content id hex.
    pub parent: String,
    pub generation: u64,
    /// The dropped devices, sorted.
    pub devices: Vec<String>,
    pub t_ms: i64,
    #[serde(default)]
    pub sigs: Vec<SettleSig>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettleSig {
    pub device: String,
    pub sig: String,
}

/// Devices one settling may drop: the device and the vouchees removed with it (8.6).
pub const MAX_SETTLE_DEVICES: usize = 64;

impl SettleStamp {
    /// The settling id: SHA-256 of `hollow-settle-id1\n` and the fields before `sigs`, as
    /// one JSON array (no field can shift into another).
    pub fn id(&self) -> String {
        use sha2::Digest;
        let fields = serde_json::to_string(&(&self.server, &self.parent, self.generation, &self.devices, self.t_ms)).unwrap_or_default();
        hex::encode(sha2::Sha256::digest(format!("hollow-settle-id1\n{fields}").as_bytes()))
    }

    fn signed(id: &str) -> String {
        format!("hollow-settle1\n{id}")
    }

    /// Add `device`'s signature over the settling id.
    pub fn sign(&mut self, device: &NativeKeypair) {
        let sig = device.sign(Self::signed(&self.id()).as_bytes());
        self.sigs.push(SettleSig { device: device.peer_id(), sig: base64::engine::general_purpose::STANDARD.encode(sig) });
    }

    /// The stamp with only `device`'s signature, as one `SettleSign` carries it.
    pub fn signed_by(&self, device: &NativeKeypair) -> Self {
        let mut one = Self { sigs: Vec::new(), ..self.clone() };
        one.sign(device);
        one
    }

    /// Whether `sig` verifies under the key its device id derives.
    pub fn sig_verifies(&self, sig: &SettleSig) -> bool {
        let Some(key) = crate::crypto::safety_number::pubkey_from_peer_id(&sig.device) else { return false };
        let Ok(raw) = base64::engine::general_purpose::STANDARD.decode(&sig.sig) else { return false };
        let Ok(raw) = <[u8; 64]>::try_from(raw.as_slice()) else { return false };
        let Ok(vk) = ed25519_dalek::VerifyingKey::from_bytes(&key) else { return false };
        vk.verify_strict(Self::signed(&self.id()).as_bytes(), &ed25519_dalek::Signature::from_bytes(&raw)).is_ok()
    }

    /// The shape every replica requires: a 64-hex parent, 1 to `MAX_SETTLE_DEVICES`
    /// strictly sorted devices, a time not before 0.
    pub fn well_formed(&self) -> bool {
        self.parent.len() == 64
            && self.parent.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
            && !self.devices.is_empty()
            && self.devices.len() <= MAX_SETTLE_DEVICES
            && self.devices.windows(2).all(|w| w[0] < w[1])
            && self.t_ms >= 0
    }
}

/// One op a `DeviceRetired` names: its clock and content id (hex).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct OpRef {
    pub ms: u64,
    pub c: u32,
    pub h: String,
}

impl OpRef {
    #[cfg(test)]
    pub fn of(op: &CrdtOp) -> Self {
        Self { ms: op.hlc.physical_ms, c: op.hlc.counter, h: hex::encode(op.content_hash()) }
    }

    /// Whether `op` (content id `hash`) is the op this names.
    pub fn names(&self, op: &CrdtOp, hash: &[u8; 32]) -> bool {
        self.ms == op.hlc.physical_ms && self.c == op.hlc.counter && self.h == hex::encode(hash)
    }
}

/// Refs one `DeviceRetired` carries (section 8.2).
pub const MAX_RETIRED_REFS: usize = 256;

/// Refs a checkpoint's `cp_endorsed` carries in all (section 14).
pub const MAX_ENDORSED_REFS: usize = 4_096;

/// One retire's endorsement a checkpoint carries (section 8.2): the retire's content id,
/// its author identity (whose ops it names), the device that signed it, the retired
/// device, and the named ops the carrying checkpoint does not decide.
/// A device's post window (DEVICE_PROOF_DESIGN 8.2, section 13): its posts dated at or
/// before `until_ms` keep counting after the removal. Set by the retire (or settling)
/// `dr` that device `by` of `author` signed; `author` is a build note, as on
/// [`Endorsement`].
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PostsUntil {
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub device: String,
    #[serde(default)]
    pub until_ms: i64,
    #[serde(default)]
    pub dr: String,
    #[serde(default)]
    pub by: String,
}

/// Post windows a checkpoint carries per author identity and in all (section 14).
pub const MAX_POSTS_UNTIL_PER_AUTHOR: usize = 16;
pub const MAX_POSTS_UNTIL: usize = 4_096;

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Endorsement {
    #[serde(default)]
    pub dr: String,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub by: String,
    #[serde(default)]
    pub device: String,
    #[serde(default)]
    pub refs: Vec<OpRef>,
}

/// What a tolerant parse kept and what it skipped.
#[derive(Debug, Default)]
pub struct TolerantParse {
    pub ops: Vec<CrdtOp>,
    /// Skipped ops their author signed: the ones a later build may read (`read_op`).
    pub unread: Vec<UnreadOp>,
    /// The batch is not a JSON array at all.
    pub malformed: bool,
}

/// Tolerant sync-batch parse: each op deserializes INDIVIDUALLY, so a batch carrying a
/// NEWER client's payload variant skips just that op instead of poisoning the whole
/// Vec, which permanently wedged older clients' server sync. The signed ops it skipped
/// are reported, so the server is fetched again whole once a build that reads them
/// runs (`node::crdt_resync`).
pub fn parse_ops_tolerant(json: &str) -> TolerantParse {
    let Ok(items) = serde_json::from_str::<Vec<&serde_json::value::RawValue>>(json) else {
        return TolerantParse { malformed: true, ..TolerantParse::default() };
    };
    let mut out = TolerantParse::default();
    for item in items {
        match read_op(item.get()) {
            ReadOp::Op(op) => out.ops.push(op),
            ReadOp::Unread(op) => out.unread.push(op),
            ReadOp::Junk => {}
        }
    }
    out
}

/// Member roles with hierarchical priority.
/// Owner > Admin > Moderator > Member.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum MemberRole {
    Owner,
    Admin,
    Moderator,
    Member,
}

impl MemberRole {
    /// Numeric role rank, higher = more authority. Used for outranking checks and
    /// carried on RoleChanged as wire-compat metadata the merge no longer consults.
    pub fn priority(&self) -> u8 {
        match self {
            Self::Owner => 3,
            Self::Admin => 2,
            Self::Moderator => 1,
            Self::Member => 0,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Owner => "owner",
            Self::Admin => "admin",
            Self::Moderator => "moderator",
            Self::Member => "member",
        }
    }

    /// Parse a role from a string. Returns Member if unrecognized.
    pub fn from_str(s: &str) -> Self {
        match s {
            "owner" => Self::Owner,
            "admin" => Self::Admin,
            "moderator" => Self::Moderator,
            _ => Self::Member,
        }
    }

    /// Default permissions bitmask for this role.
    pub fn default_permissions(&self) -> u32 {
        match self {
            Self::Owner => Permission::ALL,
            Self::Admin => Permission::MANAGE_SERVER
                | Permission::MANAGE_CHANNELS
                | Permission::MANAGE_ROLES
                | Permission::KICK_MEMBERS
                | Permission::SEND_MESSAGES
                | Permission::READ_MESSAGES
                | Permission::MANAGE_EMOTES,
            Self::Moderator => Permission::KICK_MEMBERS
                | Permission::SEND_MESSAGES
                | Permission::READ_MESSAGES,
            Self::Member => Permission::SEND_MESSAGES | Permission::READ_MESSAGES,
        }
    }

    /// Whether this role outranks another.
    pub fn outranks(&self, other: &Self) -> bool {
        self.priority() > other.priority()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// D3: an ask stands only for the key that signed it, over the server and time it
    /// names; text naming someone else, signed by any other key, stands for nobody.
    #[test]
    fn authz_a_join_ask_stands_only_for_its_own_signer() {
        let (carol, mallory) = (crate::crdt::testkeys::keys(30), crate::crdt::testkeys::keys(31));
        let ask = JoinAsk::sign("srv", 5, &carol.0);
        assert!(ask.verifies("srv", &carol.1));
        assert!(!ask.verifies("other", &carol.1), "another server");
        assert!(!JoinAsk { at: 6, ..ask.clone() }.verifies("srv", &carol.1), "another time");
        assert!(!ask.verifies("srv", &mallory.1), "another identity");
        let b64 = base64::engine::general_purpose::STANDARD;
        let in_her_name = JoinAsk {
            at: 5,
            sig: b64.encode(mallory.0.sign(&JoinAsk::signing_payload("srv", &carol.1, 5, None))),
            pk: mallory.2.clone(),
            key: None,
            follows: None,
        };
        assert!(!in_her_name.verifies("srv", &carol.1), "an ask in someone else's name");
    }

    /// Invite reset: the invite key an ask names is the joiner's own signed word, so a
    /// member cannot move an old-link ask onto the new key, nor strip the key away.
    #[test]
    fn a_join_ask_binds_the_invite_key_it_names() {
        let carol = crate::crdt::testkeys::keys(30);
        let (old, new) = (crate::node::sealed_box::key_to_text(&[1; 32]), crate::node::sealed_box::key_to_text(&[2; 32]));
        let ask = JoinAsk::sign_for_invite("srv", 5, &old, &carol.0).unwrap();
        assert_eq!(ask.key.as_deref(), Some(old.as_str()));
        assert!(ask.verifies("srv", &carol.1));
        assert!(!JoinAsk { key: Some(new), ..ask.clone() }.verifies("srv", &carol.1), "moved to another key");
        assert!(!JoinAsk { key: None, ..ask.clone() }.verifies("srv", &carol.1), "the key stripped");
        let keyless = JoinAsk::sign("srv", 5, &carol.0);
        assert!(!JoinAsk { key: Some(old), ..keyless }.verifies("srv", &carol.1), "a key added to a keyless ask");
        let json = serde_json::to_string(&JoinAsk::sign("srv", 5, &carol.0)).unwrap();
        assert!(!json.contains("\"key\""), "a keyless ask keeps the bytes it always had");
    }

    /// The ask3 payload, pinned: its own head (never an ask1 or ask2 one with more bytes),
    /// an empty key slot when no key is named, then the leave's three parts and `made`.
    #[test]
    fn a_rejoin_ask_payload_is_pinned() {
        let follows = AskFollows { leave: super::super::hlc::HlcTimestamp { physical_ms: 9, counter: 1, actor: "A".into() }, made: 4 };
        assert_eq!(JoinAsk::signing_payload_full("s", "j", 5, None, Some(&follows)), b"hollow-join-ask3\x00s\x00j\x005\x00\x009\x001\x00A\x004".to_vec());
        assert_eq!(JoinAsk::signing_payload_full("s", "j", 5, Some("K"), Some(&follows)), b"hollow-join-ask3\x00s\x00j\x005\x00K\x009\x001\x00A\x004".to_vec());
        assert_eq!(JoinAsk::signing_payload_full("s", "j", 5, Some("K"), None), b"hollow-join-ask2\x00s\x00j\x005\x00K".to_vec());
        assert_eq!(JoinAsk::signing_payload_full("s", "j", 5, None, None), b"hollow-join-ask1\x00s\x00j\x005".to_vec());
    }

    /// HOL-SEC-207 compatibility: a rejoin whose stamp does not lead the wall clock signs
    /// the exact ask 0.14.0 signed, which a 0.14.0 replica reads whole and counts; only a
    /// stamp past the wall clock names the leave (ask3), which that replica cannot read.
    #[test]
    fn a_rejoin_without_a_clock_lead_signs_the_0140_ask() {
        let carol = crate::crdt::testkeys::keys(31);
        let key = crate::node::sealed_box::key_to_text(&[7; 32]);
        let leave = super::super::hlc::HlcTimestamp { physical_ms: 9, counter: 1, actor: carol.1.clone() };
        for made in [5, 6, 1_700_000_000_000] {
            let keyed = JoinAsk::sign_rejoin("srv", 5, Some(&key), Some(&leave), made, &carol.0).unwrap();
            assert_eq!(keyed, JoinAsk::sign_for_invite("srv", 5, &key, &carol.0).unwrap(), "made {made}: not the 0.14.0 ask2");
            assert!(keyed.reads_as_0140("srv", &carol.1), "made {made}: a 0.14.0 replica cannot read it");
            let keyless = JoinAsk::sign_rejoin("srv", 5, None, Some(&leave), made, &carol.0).unwrap();
            assert_eq!(keyless, JoinAsk::sign("srv", 5, &carol.0), "made {made}: not the 0.14.0 ask1");
            assert!(keyless.reads_as_0140("srv", &carol.1));
        }
        let json = serde_json::to_string(&JoinAsk::sign_rejoin("srv", 5, Some(&key), Some(&leave), 5, &carol.0).unwrap()).unwrap();
        let mut fields: Vec<String> = serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(&json).unwrap().keys().cloned().collect();
        fields.sort();
        assert_eq!(fields, ["at", "key", "pk", "sig"], "the 0.14.0 ask2 fields, no more");
        assert!(json.starts_with("{\"at\":5,\"sig\":\""), "the 0.14.0 field order");
        let led = JoinAsk::sign_rejoin("srv", 5, Some(&key), Some(&leave), 4, &carol.0).unwrap();
        assert_eq!(led.follows.as_ref().map(|f| (&f.leave, f.made)), Some((&leave, 4)), "a lead names the leave");
        assert!(led.verifies("srv", &carol.1));
        assert!(!led.reads_as_0140("srv", &carol.1), "control: a 0.14.0 replica reads no ask3");
    }

    /// HOL-SEC-143 for the leave a rejoin names: its actor is a peer id, so no field of the
    /// signed payload can carry a separator into the next, even under a valid signature.
    #[test]
    fn a_rejoin_ask_names_a_leave_by_a_peer_id() {
        use base64::Engine as _;
        let carol = crate::crdt::testkeys::keys(31);
        let hand_signed = |actor: &str| {
            let follows = AskFollows { leave: super::super::hlc::HlcTimestamp { physical_ms: 9, counter: 1, actor: actor.into() }, made: 4 };
            let sig = carol.0.sign(&JoinAsk::signing_payload_full("srv", &carol.1, 5, None, Some(&follows)));
            JoinAsk { at: 5, sig: base64::engine::general_purpose::STANDARD.encode(sig), pk: carol.2.clone(), key: None, follows: Some(follows) }
        };
        assert!(hand_signed(&carol.1).verifies("srv", &carol.1), "control: a peer id");
        for junk in [format!("{}\0123", carol.1), String::new(), "x".into()] {
            assert!(!hand_signed(&junk).verifies("srv", &carol.1), "{junk:?} verified");
        }
        let signed = JoinAsk::sign_rejoin(
            "srv", 5, None, Some(&super::super::hlc::HlcTimestamp { physical_ms: 9, counter: 1, actor: "x\0y".into() }), 4, &carol.0,
        )
        .unwrap();
        assert!(signed.follows.is_none(), "the signer names no leave whose actor is no peer id");
    }

    /// HOL-SEC-143/154 for the ask's key: the signer names only a key, and the verifier
    /// takes a key only in the text form an honest signer writes, so a key field never
    /// carries a separator or anything else the signing payload could be split on.
    #[test]
    fn a_join_ask_key_is_a_key_in_its_one_text_form() {
        use base64::Engine as _;
        let carol = crate::crdt::testkeys::keys(31);
        assert!(JoinAsk::sign_for_invite("srv", 5, "not a key", &carol.0).is_none(), "the signer never downgrades to keyless");
        let good = crate::node::sealed_box::key_to_text(&[7; 32]);
        let hand_signed = |key: &str| {
            let sig = carol.0.sign(&JoinAsk::signing_payload("srv", &carol.1, 5, Some(key)));
            JoinAsk { at: 5, sig: base64::engine::general_purpose::STANDARD.encode(sig), pk: carol.2.clone(), key: Some(key.to_string()), follows: None }
        };
        assert!(hand_signed(&good).verifies("srv", &carol.1), "control: a canonical key");
        for junk in ["not a key\0with nul", "", &format!("{good}=")] {
            assert!(!hand_signed(junk).verifies("srv", &carol.1), "{junk:?} verified");
        }
    }

    #[test]
    fn role_priority_order() {
        assert_eq!(MemberRole::Owner.priority(), 3);
        assert_eq!(MemberRole::Admin.priority(), 2);
        assert_eq!(MemberRole::Moderator.priority(), 1);
        assert_eq!(MemberRole::Member.priority(), 0);
    }

    #[test]
    fn role_as_str_round_trip() {
        for role in [MemberRole::Owner, MemberRole::Admin, MemberRole::Moderator, MemberRole::Member] {
            let s = role.as_str();
            let parsed = MemberRole::from_str(s);
            assert_eq!(parsed, role);
        }
    }

    #[test]
    fn from_str_unknown_defaults_to_member() {
        assert_eq!(MemberRole::from_str("superadmin"), MemberRole::Member);
        assert_eq!(MemberRole::from_str(""), MemberRole::Member);
        assert_eq!(MemberRole::from_str("Owner"), MemberRole::Member); // case-sensitive
    }

    #[test]
    fn outranks_full_hierarchy() {
        assert!(MemberRole::Owner.outranks(&MemberRole::Admin));
        assert!(MemberRole::Owner.outranks(&MemberRole::Moderator));
        assert!(MemberRole::Owner.outranks(&MemberRole::Member));
        assert!(MemberRole::Admin.outranks(&MemberRole::Moderator));
        assert!(MemberRole::Admin.outranks(&MemberRole::Member));
        assert!(MemberRole::Moderator.outranks(&MemberRole::Member));

        // No role outranks itself
        assert!(!MemberRole::Owner.outranks(&MemberRole::Owner));
        assert!(!MemberRole::Member.outranks(&MemberRole::Member));

        // Lower can't outrank higher
        assert!(!MemberRole::Member.outranks(&MemberRole::Moderator));
        assert!(!MemberRole::Moderator.outranks(&MemberRole::Admin));
        assert!(!MemberRole::Admin.outranks(&MemberRole::Owner));
    }

    #[test]
    fn default_permissions_owner_has_all() {
        assert_eq!(MemberRole::Owner.default_permissions(), Permission::ALL);
    }

    #[test]
    fn default_permissions_member_read_send_only() {
        let perms = MemberRole::Member.default_permissions();
        assert_ne!(perms & Permission::SEND_MESSAGES, 0);
        assert_ne!(perms & Permission::READ_MESSAGES, 0);
        assert_eq!(perms & Permission::MANAGE_SERVER, 0);
        assert_eq!(perms & Permission::MANAGE_CHANNELS, 0);
        assert_eq!(perms & Permission::MANAGE_ROLES, 0);
        assert_eq!(perms & Permission::KICK_MEMBERS, 0);
    }

    #[test]
    fn default_permissions_escalation_by_rank() {
        let member = MemberRole::Member.default_permissions();
        let moderator = MemberRole::Moderator.default_permissions();
        let admin = MemberRole::Admin.default_permissions();
        let owner = MemberRole::Owner.default_permissions();

        // Each higher rank has at least the permissions of lower ranks
        assert_eq!(member & moderator, member);
        assert_eq!(moderator & admin, moderator);
        assert_eq!(admin & owner, admin);
    }

    #[test]
    fn permission_bits_are_distinct() {
        let bits = [
            Permission::MANAGE_SERVER,
            Permission::MANAGE_CHANNELS,
            Permission::MANAGE_ROLES,
            Permission::KICK_MEMBERS,
            Permission::SEND_MESSAGES,
            Permission::READ_MESSAGES,
        ];
        for (i, a) in bits.iter().enumerate() {
            for (j, b) in bits.iter().enumerate() {
                if i != j {
                    assert_eq!(a & b, 0, "bits {i} and {j} overlap");
                }
            }
        }
    }

    #[test]
    fn permission_all_includes_every_bit() {
        assert_ne!(Permission::ALL & Permission::MANAGE_SERVER, 0);
        assert_ne!(Permission::ALL & Permission::MANAGE_CHANNELS, 0);
        assert_ne!(Permission::ALL & Permission::MANAGE_ROLES, 0);
        assert_ne!(Permission::ALL & Permission::KICK_MEMBERS, 0);
        assert_ne!(Permission::ALL & Permission::SEND_MESSAGES, 0);
        assert_ne!(Permission::ALL & Permission::READ_MESSAGES, 0);
    }

    #[test]
    fn crdt_op_serde_round_trip() {
        let op = CrdtOp {
            server_id: "srv-1".into(),
            hlc: super::super::hlc::HlcTimestamp { physical_ms: 1000, counter: 0, actor: "peer_a".into() },
            author: "peer_a".into(),
            payload: CrdtPayload::LabelCreated {
                label_id: "lbl-1".into(),
                name: "VIP".into(),
                color: "#ff0000".into(),
                access: true,
            },
            auth: None,
            dev: None,
        };
        let json = serde_json::to_string(&op).unwrap();
        let deserialized: CrdtOp = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.server_id, "srv-1");
        assert_eq!(deserialized.author, "peer_a");
        match &deserialized.payload {
            CrdtPayload::LabelCreated { label_id, name, color, access } => {
                assert_eq!(label_id, "lbl-1");
                assert_eq!(name, "VIP");
                assert_eq!(color, "#ff0000");
                assert!(access);
            }
            _ => panic!("Wrong payload variant after deserialization"),
        }
    }

    fn signed_op(tag: u8, payload: CrdtPayload) -> CrdtOp {
        let (kp, id, pk) = crate::crdt::testkeys::keys(tag);
        let mut op = CrdtOp {
            server_id: "srv-1".into(),
            hlc: HlcTimestamp { physical_ms: 1000, counter: 0, actor: id.clone() },
            author: id,
            payload,
            auth: None,
            dev: None,
        };
        op.sign(&kp, &pk);
        op
    }

    #[test]
    fn signed_op_verifies_and_survives_the_wire() {
        let op = signed_op(1, CrdtPayload::ServerRenamed { new_name: "Fine".into() });
        assert!(op.verify_author().is_ok());
        let json = serde_json::to_string(&op).unwrap();
        let back: CrdtOp = serde_json::from_str(&json).unwrap();
        assert!(back.verify_author().is_ok(), "the signature must survive a serde round trip");
    }

    /// Every field in the signing payload is covered: changing any one of
    /// them gets the op refused.
    #[test]
    fn signature_covers_every_field_of_the_op() {
        let base = signed_op(1, CrdtPayload::ServerRenamed { new_name: "Fine".into() });

        let mut renamed = base.clone();
        renamed.payload = CrdtPayload::ServerRenamed { new_name: "PWNED".into() };
        assert_eq!(renamed.verify_author(), Err(OpReject::BadSignature));

        let mut moved = base.clone();
        moved.server_id = "srv-2".into();
        assert_eq!(moved.verify_author(), Err(OpReject::BadSignature));

        let mut future = base.clone();
        future.hlc.physical_ms = u64::MAX;
        assert_eq!(future.verify_author(), Err(OpReject::BadSignature));

        let mut counted = base.clone();
        counted.hlc.counter += 1;
        assert_eq!(counted.verify_author(), Err(OpReject::BadSignature));

        let mut reactored = base.clone();
        reactored.hlc.actor = "someone-else".into();
        assert_eq!(reactored.verify_author(), Err(OpReject::ActorMismatch));

        // A different author string no longer matches the key at all.
        let mut reauthored = base.clone();
        reauthored.author = "someone-else".into();
        assert_eq!(reauthored.verify_author(), Err(OpReject::AuthorMismatch));
    }

    /// Swapping in another peer's key does not launder the op: the key must
    /// derive the author, and the signature must be over THIS payload.
    #[test]
    fn a_foreign_key_cannot_stand_in_for_the_author() {
        let mine = signed_op(1, CrdtPayload::ServerRenamed { new_name: "Fine".into() });
        let (_, _, other_pk) = crate::crdt::testkeys::keys(2);
        let mut swapped = mine.clone();
        swapped.auth = Some(Box::new(CrdtAuth {
            sig: mine.auth.as_ref().unwrap().sig.clone(),
            pk: other_pk,
        }));
        assert_eq!(swapped.verify_author(), Err(OpReject::AuthorMismatch));
    }

    #[test]
    fn unsigned_op_is_missing_signature() {
        let op = CrdtOp {
            server_id: "srv-1".into(),
            hlc: HlcTimestamp { physical_ms: 1000, counter: 0, actor: "a".into() },
            author: "a".into(),
            payload: CrdtPayload::ServerRenamed { new_name: "x".into() },
            auth: None,
            dev: None,
        };
        assert_eq!(op.verify_author(), Err(OpReject::MissingSignature));
        // …and an op serialized before signatures existed parses into exactly
        // that shape, rather than failing the tolerant batch parse.
        let legacy = r#"[{"server_id":"srv-1","hlc":{"physical_ms":1,"counter":0,"actor":"a"},"author":"a","payload":{"ServerRenamed":{"new_name":"x"}}}]"#;
        let ops = parse_ops_tolerant(legacy).ops;
        assert_eq!(ops.len(), 1);
        assert_eq!(ops[0].verify_author(), Err(OpReject::MissingSignature));
    }

    /// Old-client wire compat: label ops WITHOUT the `access` field parse
    /// with the safe defaults (Created → false, Updated → None = preserve).
    #[test]
    fn label_ops_missing_access_field_default() {
        let created: CrdtPayload = serde_json::from_str(
            r##"{"LabelCreated":{"label_id":"l1","name":"VIP","color":"#fff"}}"##,
        ).unwrap();
        match created {
            CrdtPayload::LabelCreated { access, .. } => assert!(!access),
            _ => panic!("wrong variant"),
        }
        let updated: CrdtPayload = serde_json::from_str(
            r##"{"LabelUpdated":{"label_id":"l1","name":"VIP","color":"#fff"}}"##,
        ).unwrap();
        match updated {
            CrdtPayload::LabelUpdated { access, .. } => assert_eq!(access, None),
            _ => panic!("wrong variant"),
        }
    }
}

/// Permission bitmask constants.
pub struct Permission;

impl Permission {
    pub const MANAGE_SERVER: u32 = 1 << 0;
    pub const MANAGE_CHANNELS: u32 = 1 << 1;
    pub const MANAGE_ROLES: u32 = 1 << 2;
    pub const KICK_MEMBERS: u32 = 1 << 4;
    pub const SEND_MESSAGES: u32 = 1 << 5;
    pub const READ_MESSAGES: u32 = 1 << 6;
    /// Add/remove custom server emotes. Admin+ by default.
    pub const MANAGE_EMOTES: u32 = 1 << 7;

    /// Owner gets all permissions.
    pub const ALL: u32 = Self::MANAGE_SERVER
        | Self::MANAGE_CHANNELS
        | Self::MANAGE_ROLES
        | Self::KICK_MEMBERS
        | Self::SEND_MESSAGES
        | Self::READ_MESSAGES
        | Self::MANAGE_EMOTES;
}
