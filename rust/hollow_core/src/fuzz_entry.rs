//! What the cargo-fuzz targets in `rust/hollow_core/fuzz` run: each entry takes bytes a
//! remote peer, the relay, a push or another person's file controls and puts them
//! through the code that reads them before anything is trusted. Built only for
//! cargo-fuzz (`--cfg fuzzing`) and for the tests that replay the kept inputs
//! (`fuzz/regressions`). Asserts here are the properties a target checks; a panic
//! anywhere is a finding.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use base64::Engine as _;

use crate::crdt::hlc::HlcTimestamp;
use crate::crdt::operations::{CrdtOp, CrdtPayload, JoinAsk};
use crate::crdt::server_state::ServerState;
use crate::identity::native_identity::NativeKeypair;
use crate::identity::roster::Roster;
use crate::node::frame_auth::{self, Delivery};
use crate::node::types::{HavenMessage, MessageEnvelope};

/// Once per fuzz process, before the first input.
#[cfg(fuzzing)]
pub fn init() {
    crate::log::quiet_stderr();
}

const B64: base64::engine::GeneralPurpose = base64::engine::general_purpose::STANDARD;

/// Reads a fuzz input front to back; past the end every read is empty or zero.
struct Cursor<'a>(&'a [u8]);

impl<'a> Cursor<'a> {
    fn u8(&mut self) -> u8 {
        let Some((&b, rest)) = self.0.split_first() else { return 0 };
        self.0 = rest;
        b
    }

    fn u16(&mut self) -> u16 {
        u16::from_be_bytes([self.u8(), self.u8()])
    }

    fn bytes(&mut self, n: usize) -> &'a [u8] {
        let (head, rest) = self.0.split_at(n.min(self.0.len()));
        self.0 = rest;
        head
    }

    /// A length-prefixed chunk (one byte of length).
    fn short(&mut self) -> &'a [u8] {
        let n = self.u8() as usize;
        self.bytes(n)
    }

    /// A length-prefixed chunk (two bytes of length).
    fn chunk(&mut self) -> &'a [u8] {
        let n = self.u16() as usize;
        self.bytes(n)
    }

    fn rest(&mut self) -> &'a [u8] {
        self.bytes(self.0.len())
    }

    fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// A fixed identity per tag, as the CRDT unit tests derive them.
struct Key {
    kp: NativeKeypair,
    id: String,
    pk: String,
}

fn key(tag: u8) -> &'static Key {
    static KEYS: OnceLock<Vec<Key>> = OnceLock::new();
    let keys = KEYS.get_or_init(|| {
        (0..8u8)
            .map(|t| {
                let kp = NativeKeypair::from_secret_bytes(&[t.wrapping_add(1); 32]);
                let id = kp.peer_id();
                let pk = B64.encode(kp.public_key_protobuf());
                Key { kp, id, pk }
            })
            .collect()
    });
    &keys[(tag % 8) as usize]
}

fn now_ms() -> i64 {
    frame_auth::now_ms()
}

// -- Relay frames --

/// Frames as the relay writes them: `[kind][len u16][bytes]`, kind odd = text.
pub fn relay_frames(data: &[u8]) {
    let mut c = Cursor(data);
    let mut frames = Vec::new();
    while !c.is_empty() && frames.len() < 16 {
        let kind = c.u8();
        frames.push((kind & 1 == 1, c.chunk()));
    }
    for (text, bytes) in &frames {
        if !text {
            crate::node::fetch::fuzz_frames(bytes.get(1..).unwrap_or_default());
        }
    }
    let me = key(0);
    for event in crate::node::ws_client::fuzz_hooks::relay_frames(&frames) {
        use crate::node::ws_client::WsEvent;
        match event {
            WsEvent::Message { room, from, data } => {
                for delivery in [Delivery::Room, Delivery::Direct { device: &me.id, master: &me.id }] {
                    if let Ok(opened) = frame_auth::open(&data, &from, &room, delivery, now_ms()) {
                        haven_body(opened.body);
                    }
                }
            }
            WsEvent::DirectMessage { room, from, data } | WsEvent::BinaryDirect { room, from, data } => {
                let _ = frame_auth::open(&data, &from, &room, Delivery::Direct { device: &me.id, master: &me.id }, now_ms());
            }
            WsEvent::KillSignal { blob, .. } => {
                if let Some(order) = crate::node::destroy::decode_kill_blob(&blob) {
                    let _ = crate::node::crypto_handler::verify_destroy_identity(&order);
                }
            }
            WsEvent::LockChain { server, links, .. } => {
                let _ = crate::node::join_lock::verify_chain(&server, &links, None);
            }
            _ => {}
        }
    }
}

/// A sealed frame from a fixed device: `[flags][room][route][at u16][byte to flip][xor][body]`.
/// What `seal` writes `open` accepts, and no change to a sealed frame opens to other contents.
pub fn frame_seal(data: &[u8]) {
    let mut c = Cursor(data);
    let flags = c.u8();
    let room = text(c.short());
    let route_in = text(c.short());
    let skew = i64::from(c.u16()) * 1000;
    let flip_at = c.u16() as usize;
    let xor = c.u8();
    let body = c.rest();
    let from = key(1);
    let me = key(0);
    let (route, delivery) = if flags & 1 == 0 {
        (frame_auth::ROUTE_ROOM.to_string(), Delivery::Room)
    } else if flags & 2 == 0 {
        (me.id.clone(), Delivery::Direct { device: &me.id, master: &me.id })
    } else {
        (route_in, Delivery::Direct { device: &me.id, master: &me.id })
    };
    let now = now_ms();
    let ts = now - skew;
    let nonce = [flags; frame_auth::NONCE_LEN];
    let frame = frame_auth::seal_at(&from.kp, &room, &route, ts, nonce, body);
    let opened = frame_auth::open(&frame, &from.id, &room, delivery, now);
    let routed = match delivery {
        Delivery::Room => route == frame_auth::ROUTE_ROOM,
        Delivery::Direct { .. } => route == me.id,
    };
    match &opened {
        Ok(o) => assert!(routed && o.body == body && o.ts_ms == ts && o.nonce == nonce, "a seal opened to other contents"),
        Err(e) => assert!(!routed, "our own seal did not open: {e:?}"),
    }
    assert!(frame_auth::open(&frame, &key(2).id, &room, delivery, now).is_err(), "a seal opened as another device");
    let other_room = format!("{room}x");
    assert!(frame_auth::open(&frame, &from.id, &other_room, delivery, now).is_err(), "a seal opened in another room");
    if xor != 0 && !frame.is_empty() {
        let mut bent = frame.clone();
        let at = flip_at % bent.len();
        bent[at] ^= xor;
        if let Ok(o) = frame_auth::open(&bent, &from.id, &room, delivery, now) {
            assert!(o.body == body && o.ts_ms == ts && o.nonce == nonce, "a changed seal opened to other contents");
        }
    }
}

// -- Peer messages --

fn haven_body(body: &[u8]) {
    let Ok(msg) = serde_json::from_slice::<HavenMessage>(body) else { return };
    let _ = msg.lane();
    let _ = msg.live_only();
    let _ = msg.wire_kind();
    let _ = crate::node::mls_authority::frame_names_a_group(&msg, &key(1).id);
    let again = serde_json::to_vec(&msg).expect("a parsed frame serializes");
    assert!(serde_json::from_slice::<HavenMessage>(&again).is_ok(), "a parsed frame does not parse again once written");
}

/// A `HavenMessage` body, as a sealed frame or a carried copy delivers it.
pub fn haven_message(data: &[u8]) {
    haven_body(data);
}

/// A `MessageEnvelope`, as Olm or MLS hands one over once it decrypts.
pub fn message_envelope(data: &[u8]) {
    let Ok(env) = serde_json::from_slice::<MessageEnvelope>(data) else { return };
    let _ = env.live_only();
    let _ = env.is_channel_content();
    let again = serde_json::to_vec(&env).expect("a parsed envelope serializes");
    assert!(serde_json::from_slice::<MessageEnvelope>(&again).is_ok(), "a parsed envelope does not parse again once written");
}

// -- CRDT --

/// A sync batch or live op as JSON text: the tolerant parse, then every op's own checks.
pub fn crdt_ops(data: &[u8]) {
    let Ok(json) = std::str::from_utf8(data) else { return };
    let _ = crate::crdt::operations::read_op(json);
    let parsed = crate::crdt::operations::parse_ops_tolerant(json);
    for op in &parsed.ops {
        let _ = op.verify_author();
        let _ = op.content_hash();
        let _ = op.proven_device();
    }
}

/// The founding op of a self-certifying server owned by `key(0)`, at a fixed nonce.
fn founding(at_ms: u64) -> (String, CrdtOp) {
    let owner = key(0);
    let nonce = "00112233445566778899aabbccddeeff".to_string();
    let server_id = crate::crdt::anchor::derive_server_id(&owner.id, &nonce);
    let mut op = CrdtOp {
        server_id: server_id.clone(),
        hlc: HlcTimestamp { physical_ms: at_ms, counter: 0, actor: owner.id.clone() },
        author: owner.id.clone(),
        payload: CrdtPayload::ServerCreated { name: "S".into(), owner_peer_id: owner.id.clone(), nonce },
        auth: None,
        dev: None,
    };
    op.sign(&owner.kp, &owner.pk);
    (server_id, op)
}

/// Signed ops from up to five fixed identities, as an op script:
/// `[flags]` then per op `[author][seconds after founding u16][counter][len u16][payload JSON]`,
/// where `$0`..`$4` stand for the identities' ids and `$S` for the server's. A joiner's
/// ask is signed again by the joiner. Any order of the same ops, followed by one
/// catch-up round of all of them, must fold to the same state, and that state must
/// survive a save and load.
pub fn crdt_fold(data: &[u8]) {
    let mut c = Cursor(data);
    let flags = c.u8();
    let start = (crate::crdt::hlc::wall_clock_ms()).saturating_sub(48 * 3_600_000) / 1000 * 1000;
    let (server_id, founder) = founding(start);
    let ids: Vec<String> = (0..5).map(|t| key(t).id.clone()).collect();
    let mut ops = vec![founder];
    while !c.is_empty() && ops.len() < 48 {
        let author = key(c.u8() % 5);
        // Never at the founding op's clock: an owner forking its own founding op only
        // changes what that owner's replicas pin.
        let at = start + (u64::from(c.u16()) + 1) * 1000;
        let counter = u32::from(c.u8());
        let mut json = text(c.chunk()).replace("$S", &server_id);
        for (t, id) in ids.iter().enumerate() {
            json = json.replace(&format!("${t}"), id);
        }
        let Ok(mut payload) = serde_json::from_str::<CrdtPayload>(&json) else { continue };
        if let CrdtPayload::MemberAdded { peer_id, ask: Some(ask), .. } = &mut payload
            && let Some(t) = ids.iter().position(|id| id == peer_id)
        {
            let joiner = &key(t as u8).kp;
            *ask = ask
                .key
                .as_deref()
                .and_then(|k| JoinAsk::sign_for_invite(&server_id, ask.at, k, joiner))
                .unwrap_or_else(|| JoinAsk::sign(&server_id, ask.at, joiner));
        }
        let mut op = CrdtOp {
            server_id: server_id.clone(),
            hlc: HlcTimestamp { physical_ms: at, counter, actor: author.id.clone() },
            author: author.id.clone(),
            payload,
            auth: None,
            dev: None,
        };
        op.sign(&author.kp, &author.pk);
        ops.push(op);
    }

    let mut one = ServerState::skeleton(server_id.clone());
    if flags & 1 == 0 {
        let _ = one.ingest_remote(&ops);
    } else {
        for op in &ops {
            let _ = one.ingest_remote(std::slice::from_ref(op));
        }
    }
    let mut other = ServerState::skeleton(server_id.clone());
    let mut shuffled = ops.clone();
    shuffled[1..].reverse();
    let (first, second) = shuffled.split_at(shuffled.len() / 2 + 1);
    let _ = other.ingest_remote(first);
    let _ = other.ingest_remote(second);
    // An op refused before its author's admission arrived comes back with the next
    // catch-up, which sends what the other replica holds: after that round, both agree.
    let _ = other.ingest_remote(&ops);
    let _ = one.ingest_remote(&ops);
    assert_eq!(fold_view(&one), fold_view(&other), "two orders of the same ops folded to different states");

    let saved = serde_json::to_string(&one).expect("a folded state serializes");
    let loaded: ServerState = serde_json::from_str(&saved).expect("a saved state loads");
    let _ = loaded.anchor();
}

/// What two replicas of one op set must agree on.
fn fold_view(s: &ServerState) -> String {
    let mut members: Vec<&String> = s.members.keys().collect();
    members.sort();
    let mut roles: Vec<(String, String)> = s.roles.iter().map(|(k, v)| (k.clone(), format!("{:?}", v.read()))).collect();
    roles.sort();
    let mut channels: Vec<&String> = s.channels.keys().collect();
    channels.sort();
    format!("{}|{members:?}|{roles:?}|{channels:?}|{:?}", s.current_print(), s.anchor_owner())
}

/// A sync ask or digest answer against a fixed small server: the answer side and the
/// follow-up side of the range digest.
pub fn crdt_digest(data: &[u8]) {
    static STATE: OnceLock<ServerState> = OnceLock::new();
    let state = STATE.get_or_init(|| {
        let start = crate::crdt::hlc::wall_clock_ms().saturating_sub(3_600_000);
        let (server_id, founder) = founding(start);
        let mut ops = vec![founder];
        let owner = key(0);
        for i in 0..24u64 {
            let mut op = CrdtOp {
                server_id: server_id.clone(),
                hlc: HlcTimestamp { physical_ms: start + 1000 * (i + 1), counter: 0, actor: owner.id.clone() },
                author: owner.id.clone(),
                payload: CrdtPayload::ChannelAdded {
                    channel_id: format!("c{i}"),
                    name: format!("c{i}"),
                    category: None,
                    channel_type: "text".into(),
                },
                auth: None,
                dev: None,
            };
            op.sign(&owner.kp, &owner.pk);
            ops.push(op);
        }
        let mut s = ServerState::skeleton(server_id);
        let _ = s.ingest_remote(&ops);
        s
    });
    let mut c = Cursor(data);
    let ask = c.chunk();
    let reply = c.rest();
    let entries = crate::crdt::digest::entries(state, &[], None);
    if let Ok(d) = serde_json::from_slice::<crate::crdt::digest::OpDigest>(ask) {
        let asked = crate::crdt::digest::entries(state, &[], Some(crate::crdt::digest::Asker::of(&d)));
        if let Some((items, _)) = crate::crdt::digest::answer(&asked, &d) {
            let _ = crate::crdt::digest::items_json(&items);
        }
        let _ = crate::crdt::digest::answer(&entries, &d);
    }
    if let Ok(r) = serde_json::from_slice::<crate::crdt::digest::DigestReply>(reply) {
        let salt = crate::crdt::digest::new_salt();
        let asked: Vec<(u64, u64)> = r.groups.iter().flatten().map(|g| (g.0, g.1)).collect();
        let _ = crate::crdt::digest::follow_up(&entries, &salt, &asked, &r);
        let _ = crate::crdt::digest::follow_up(&entries, "", &[(0, u64::MAX)], &r);
    }
}

// -- Identity --

/// A roster case as `roster_vectors.json` holds them: `{now_ms, master, device, held,
/// held_seen, shown}`. Every judgement the client makes of a roster it is shown.
pub fn roster(data: &[u8]) {
    #[derive(serde::Deserialize)]
    struct Case {
        #[serde(default)]
        now_ms: i64,
        #[serde(default)]
        device: String,
        #[serde(default)]
        held: Option<Roster>,
        #[serde(default)]
        held_seen: BTreeMap<String, i64>,
        #[serde(default)]
        shown: Option<Roster>,
    }
    let Ok(case) = serde_json::from_slice::<Case>(data) else { return };
    let now = case.now_ms;
    let held = case.held.unwrap_or_default();
    let shown = case.shown.unwrap_or_default();
    let seen = |d: &str| case.held_seen.get(d).copied();
    let held_v = held.reverified();
    let shown_v = shown.verified(now);
    for r in [&held_v, &shown_v, &held_v.merged(&shown_v), &held_v.merged_by_first_sight(&shown_v, |a, b| seen(&format!("{a}|{b}")))] {
        let base = r.base();
        let state = r.fold(|d| seen(&format!("{base}|{d}")), now);
        let _ = state.is_member(&case.device);
        let _ = r.authority().counts(&case.device);
        let _ = r.counted_by_rank();
        let _ = r.placing_subset(&case.device);
        let _ = r.within_caps();
        let _ = r.upgrade_admitted();
        let _ = r.counting_removals(|d| seen(&format!("{base}|{d}")), now);
        let _ = r.vouched_members_of(&case.device, &state);
        let _ = r.digest();
        let _ = r.dependents_of(&state.members.iter().cloned().collect());
    }
    for rm in &shown.removals {
        let _ = crate::identity::roster::removal_verifies(&shown.master, rm);
    }
    let _ = crate::identity::roster::carried_fits(&shown.removals);
}

/// A destroy order as the relay hands it over, judged as the relay and the client do:
/// `{now_ms, held, seen, target, issued_at_ms, blob}` (`kill_vectors.json`).
pub fn kill_order(data: &[u8]) {
    #[derive(serde::Deserialize)]
    struct Case {
        #[serde(default)]
        now_ms: i64,
        #[serde(default)]
        held: Option<Roster>,
        #[serde(default)]
        seen: BTreeMap<String, i64>,
        #[serde(default)]
        target: String,
        #[serde(default)]
        blob: String,
    }
    let Ok(case) = serde_json::from_slice::<Case>(data) else { return };
    let Some(order) = crate::node::destroy::decode_kill_blob(&case.blob) else { return };
    let _ = crate::node::crypto_handler::verify_destroy_identity(&order);
    if let Some(h) = case.held {
        let h = h.verified(case.now_ms);
        let base = h.base();
        let state = h.fold(|d| case.seen.get(&format!("{base}|{d}")).copied(), case.now_ms);
        let _ = h.has_consent(&case.target);
        let _ = crate::node::crypto_handler::destroy_order_authorised(&order, &h.r_pub, &state);
    }
    let again = crate::node::destroy::encode_kill_blob(&order).expect("a decoded order encodes");
    assert!(crate::node::destroy::decode_kill_blob(&again).is_some(), "an encoded order does not decode");
}

/// A server's lock chain as the relay serves it, and a join ask as a `MemberAdded`
/// carries it: `{server, owner, links, ask, joiner, grants}`.
pub fn join_lock(data: &[u8]) {
    #[derive(serde::Deserialize)]
    struct Case {
        #[serde(default)]
        server: String,
        #[serde(default)]
        owner: Option<String>,
        #[serde(default)]
        links: Vec<crate::node::join_lock::LockLink>,
        #[serde(default)]
        ask: Option<JoinAsk>,
        #[serde(default)]
        joiner: String,
        #[serde(default)]
        grants: BTreeMap<String, String>,
    }
    let Ok(case) = serde_json::from_slice::<Case>(data) else { return };
    use crate::node::join_lock as jl;
    let _ = jl::verify_chain(&case.server, &case.links, case.owner.as_deref());
    let _ = jl::verify_chain(&case.server, &case.links, None);
    for pair in case.links.windows(2) {
        let _ = jl::extends(&case.server, &pair[0], &pair[1]);
    }
    for link in &case.links {
        let _ = link.is_base();
        let _ = link.door_key();
        let _ = jl::link_device(&case.server, link);
        let _ = jl::base_owner(&case.server, link);
        for (k, grant) in &case.grants {
            let _ = jl::grant_holder(k);
            let _ = jl::grant_device(k);
            if jl::grant_shape(grant) {
                let _ = jl::open_grant(&case.server, &link.change, k, &key(0).kp, grant);
            }
        }
    }
    if let Some(ask) = case.ask {
        let _ = ask.verifies(&case.server, &case.joiner);
    }
}

// -- Files and names --

/// Peer-chosen file names, stream ids and file ids: `[selector][rest]`.
pub fn file_names(data: &[u8]) {
    let mut c = Cursor(data);
    let pick = c.u8();
    let raw = c.rest();
    let s = text(raw);
    let name = crate::node::share_handler::safe_file_name(&s);
    assert!(crate::node::share_handler::is_inert_file_name(&name), "safe_file_name kept an unsafe name: {name:?}");
    let base = std::path::Path::new("/hollow/files");
    let joined = base.join(&name);
    assert_eq!(joined.parent(), Some(base), "a safe name left its folder: {name:?}");
    assert_eq!(crate::node::share_handler::safe_file_name(&name), name, "safe_file_name is not stable: {name:?}");
    // An inert name is one safe_file_name keeps, below the length it cuts to.
    if crate::node::share_handler::is_inert_file_name(&s) && s.len() <= 200 {
        assert_eq!(name, s, "an inert name was changed");
    }

    let mut padded = [0u8; 64];
    let n = raw.len().min(64);
    padded[..n].copy_from_slice(&raw[..n]);
    if let Some(id) = crate::node::ws_stream_transfer::parse_id(&padded) {
        assert!(!id.contains(['/', '\\', '.']) && !id.is_empty(), "a stream id that names a path: {id:?}");
    }
    let _ = crate::node::ws_stream_transfer::is_stream_id(&s);

    use crate::node::file_commit as fc;
    let mut parts = s.split('\u{1f}');
    let fid = parts.next().unwrap_or_default();
    let (author, mid, sha, fname, ext) =
        (parts.next(), parts.next(), parts.next(), parts.next().unwrap_or_default(), parts.next().unwrap_or_default());
    let size = u64::from(pick) << 20;
    let _ = fc::header_claim_refused(fid, author, mid, size, sha, fname, ext, None, &key(1).id, pick & 1 == 1);
    if let (Some(author), Some(mid), Some(sha256)) = (author, mid, sha) {
        let commit = fc::FileCommit { author, mid, size, sha256, name: fname, ext, vthumb: None };
        let id = fc::file_id_for(&commit);
        if sha256.len() == 64 && sha256.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
            assert_eq!(fc::claim_refused(&id, Some(&commit)), None, "a file id refused its own commitment");
        }
    }
}

/// A share link someone pastes, the manifest its publisher serves and the chunk
/// bitmaps peers announce: `[count u16][bitmap len u8][bitmap][link or manifest]`.
pub fn share_wire(data: &[u8]) {
    use crate::node::share_handler as sh;
    let mut c = Cursor(data);
    let count = u32::from(c.u16()) * 17;
    let bits = c.short().to_vec();
    let rest = c.rest();
    let mut bitmap = sh::ChunkBitmap::from_bytes(bits, count);
    for i in [0, count / 2, count.saturating_sub(1), count, u32::MAX] {
        let _ = bitmap.has(i);
        bitmap.set(i);
    }
    assert!(bitmap.count_set() <= count, "a bitmap counts more chunks than it has");
    let _ = bitmap.is_complete();
    let text = text(rest);
    let _ = sh::decode_link(&text);
    if let Ok(m) = serde_json::from_slice::<crate::node::types::ShareManifest>(rest) {
        let _ = m.well_formed();
    }
    let _ = sh::manifest_root_hash(rest);
}

/// Message signature payloads: two field sets that differ (with absent and empty the
/// same, as documented) never sign the same bytes, and `well_formed` holds both ends.
pub fn message_sig(data: &[u8]) {
    use crate::node::crypto_handler::{message_signing_payload_v2, SignedExtras};
    let mut c = Cursor(data);
    let mut fields: [Vec<String>; 2] = [Vec::new(), Vec::new()];
    let mut orders = [None, None];
    for (i, f) in fields.iter_mut().enumerate() {
        for _ in 0..6 {
            f.push(text(c.short()));
        }
        let o = c.u16();
        orders[i] = (o != 0).then_some(i64::from(o) - 1000);
    }
    let texts = [text(c.chunk()), text(c.chunk())];
    fn opt(s: &str) -> Option<&str> {
        (!s.is_empty()).then_some(s)
    }
    let extras = |i: usize| {
        let f = &fields[i];
        SignedExtras {
            mid: opt(&f[0]),
            reply_to: opt(&f[1]),
            file_id: opt(&f[2]),
            order_us: orders[i],
            lp_digest: opt(&f[3]),
            album: opt(&f[4]),
        }
    };
    let (a, b) = (extras(0), extras(1));
    if !(a.well_formed() && b.well_formed()) {
        return;
    }
    let sender = key(1).id.clone();
    let pa = message_signing_payload_v2("dm", "ctx", &sender, 7, &a, &texts[0]);
    let pb = message_signing_payload_v2("dm", "ctx", &sender, 7, &b, &texts[1]);
    let same = format!("{:?}", (a.mid, a.reply_to, a.file_id, a.order_us, a.lp_digest, a.album, &texts[0]))
        == format!("{:?}", (b.mid, b.reply_to, b.file_id, b.order_us, b.lp_digest, b.album, &texts[1]));
    assert!(same || pa != pb, "two different messages sign the same bytes: {pa:?}");
}

/// A link card a peer attached, and the page metadata our own fetch reads from any site.
pub fn link_preview(data: &[u8]) {
    let mut c = Cursor(data);
    let card = c.chunk();
    let html = c.rest();
    if let Ok(lp) = serde_json::from_slice::<crate::node::types::LinkPreviewRef>(card) {
        let _ = crate::node::link_preview::card_within_bounds(&lp);
        let _ = crate::node::crypto_handler::link_preview_digest(&lp);
    }
    crate::node::link_preview::fuzz_hooks::page(&text(html));
}

/// A `.hollowpack` from the artist shop or a friend: the one verification the importer runs.
pub fn hollowpack(data: &[u8]) {
    let _ = crate::hollowpack::verify_pack(data);
}

/// A link snapshot or backup zip (someone else's device made it): every entry judged
/// and measured, unpacked into nothing.
pub fn snapshot_zip(data: &[u8]) {
    let _ = crate::api::storage::fuzz_check_snapshot(data);
}

/// A message archive someone exported.
pub fn archive_zip(data: &[u8]) {
    let _ = crate::archive::loader::fuzz_hooks::load(data);
}

/// A push wake: the sealed block, opened with the fixture's receiver keys, the
/// plaintext reader behind it, and the iOS extension's reader.
pub fn push_wake(data: &[u8]) {
    crate::crypto::push_seal::fuzz_hooks::open(data);
}

/// A profile card a peer seals to us (the plaintext is theirs to choose).
pub fn profile_card(data: &[u8]) {
    crate::node::profile_card::fuzz_hooks::open(data);
}

/// MLS bytes from a peer: KeyPackages, application frames, commits and Welcomes, into
/// a one-member group of ours.
pub fn mls_message(data: &[u8]) {
    use crate::crypto::{MlsManager, Verdict};
    use std::sync::Mutex;
    static MLS: OnceLock<Mutex<MlsManager>> = OnceLock::new();
    let mls = MLS.get_or_init(|| {
        let mut m = MlsManager::new(&key(0).kp, &key(1).kp).expect("an MLS manager");
        m.create_group("fuzz").expect("a group");
        Mutex::new(m)
    });
    let mut m = mls.lock().unwrap_or_else(|p| p.into_inner());
    let mut c = Cursor(data);
    let pick = c.u8();
    let bytes = c.rest();
    let _ = MlsManager::key_package_identity(bytes);
    let _ = crate::crypto::classify_leaf(bytes, bytes.get(..32).unwrap_or_default());
    match pick % 4 {
        0 => {
            let _ = m.decrypt("fuzz", bytes);
        }
        1 => {
            let _ = m.decrypt_fresh("fuzz", bytes);
        }
        2 => {
            let _ = m.process_commit_judged("fuzz", bytes, |_| Verdict::Refuse("fuzz".into()));
        }
        _ => {
            let _ = m.names_our_key_package(bytes);
            let _ = m.join_from_welcome_judged("fuzz2", bytes, |_| Verdict::Refuse("fuzz".into()));
        }
    }
}

/// Image bytes a peer controls on the paths that read them in Rust before Dart:
/// header thumbs, card thumbs, stickers, overlays and the header checks.
pub fn peer_images(data: &[u8]) {
    use crate::node::image_convert as ic;
    let mut c = Cursor(data);
    let pick = c.u8();
    let bytes = c.rest();
    let b64 = B64.encode(bytes);
    let _ = ic::webp_header_dimensions(bytes);
    let _ = ic::validate_remote_image_header(bytes);
    let _ = ic::is_animated_webp(bytes);
    match pick % 5 {
        0 => {
            let _ = ic::peer_thumb_for_display(&b64);
        }
        1 => {
            let _ = ic::card_thumb_for_display(&b64);
        }
        2 => {
            let _ = ic::validate_sticker_blob(bytes);
        }
        3 => {
            let _ = ic::received_overlay_image_fits(bytes);
        }
        _ => {
            let _ = ic::reencode_peer_thumb(bytes, 64, 70.0);
        }
    }
}

/// Small parsers every frame's ids pass: peer ids, server and meeting ids, nickname
/// claims and sealed-box keys.
pub fn peer_ids(data: &[u8]) {
    let s = text(data);
    let _ = crate::crypto::safety_number::pubkey_from_peer_id(&s);
    let _ = crate::crdt::anchor::valid_server_id(&s);
    let _ = crate::crdt::anchor::is_genesis_id(&s);
    let _ = crate::node::conference::conf_id_from_sid(&s);
    let _ = crate::node::conference::is_conference_sid(&s);
    let _ = crate::node::conference::is_pinned_conf_id(&s);
    if let Some(k) = crate::node::sealed_box::key_from_text(&s) {
        assert_eq!(crate::node::sealed_box::key_to_text(&k).len(), 43);
    }
    let _ = crate::node::join_lock::peer_x25519(&s);
    let mut parts = s.splitn(4, '\u{1f}');
    let (nick, device, master, claim) = (parts.next().unwrap_or_default(), parts.next().unwrap_or_default(), parts.next().unwrap_or_default(), parts.next().unwrap_or_default());
    let (master_key, sig) = claim.split_once('\u{1f}').unwrap_or((claim, ""));
    let nick_claim = crate::node::nick_claim::NickClaim { master_key: master_key.into(), ts_ms: now_ms(), sig: sig.into() };
    let _ = crate::node::nick_claim::verified_master(nick, device, master, &nick_claim, now_ms());
    if let Ok(host) = serde_json::from_str::<crate::node::types::ConfHost>(claim) {
        let _ = crate::node::conference::verified_host(nick, device, &host);
        let _ = crate::node::conference::welcome_host(nick, device, Some(&host));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every input a fuzz run kept as a crash, hang or OOM goes in
    /// `fuzz/regressions/<target>/` and runs here on every suite.
    #[test]
    fn fuzz_regressions_stay_fixed() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("fuzz/regressions");
        let Ok(targets) = std::fs::read_dir(&dir) else { return };
        for target in targets.flatten() {
            let name = target.file_name().to_string_lossy().into_owned();
            let run = by_name(&name).unwrap_or_else(|| panic!("no fuzz entry named {name}"));
            for input in std::fs::read_dir(target.path()).unwrap().flatten() {
                run(&std::fs::read(input.path()).unwrap());
            }
        }
    }
}

/// Writes the seed corpora (`cargo test --lib write_fuzz_seeds -- --ignored` with
/// `HOLLOW_FUZZ_SEEDS=<dir>`): the test vectors both languages pin, frames this build
/// makes, and the JSON literals the unit tests feed the parsers.
#[cfg(test)]
mod seeds {
    use super::*;
    use std::io::Write as _;
    use std::path::{Path, PathBuf};

    struct Out(PathBuf);

    impl Out {
        fn put(&self, target: &str, bytes: &[u8]) {
            use sha2::Digest as _;
            let dir = self.0.join(target);
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join(hex::encode(&sha2::Sha256::digest(bytes)[..8])), bytes).unwrap();
        }
    }

    fn repo(path: &str) -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").join(path)
    }

    fn vectors(path: &str) -> serde_json::Value {
        serde_json::from_str(&std::fs::read_to_string(repo(path)).unwrap()).unwrap()
    }

    fn framed(frames: &[(u8, &[u8])]) -> Vec<u8> {
        let mut out = Vec::new();
        for (kind, bytes) in frames {
            out.push(*kind);
            out.extend_from_slice(&(bytes.len() as u16).to_be_bytes());
            out.extend_from_slice(bytes);
        }
        out
    }

    fn zip_of(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut out = std::io::Cursor::new(Vec::new());
        let mut z = zip::ZipWriter::new(&mut out);
        for (name, bytes) in entries {
            z.start_file(*name, zip::write::SimpleFileOptions::default()).unwrap();
            z.write_all(bytes).unwrap();
        }
        z.finish().unwrap();
        out.into_inner()
    }

    /// Every `r#"..."#` literal in the crate's sources that starts as a JSON object.
    fn json_literals() -> Vec<String> {
        let mut out = Vec::new();
        let mut stack = vec![Path::new(env!("CARGO_MANIFEST_DIR")).join("src")];
        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(dir).unwrap().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    stack.push(path);
                } else if path.extension().is_some_and(|e| e == "rs") {
                    let src = std::fs::read_to_string(&path).unwrap();
                    let mut rest = src.as_str();
                    while let Some(at) = rest.find("r#\"{") {
                        rest = &rest[at + 3..];
                        let Some(end) = rest.find("\"#") else { break };
                        out.push(rest[..end].to_string());
                        rest = &rest[end..];
                    }
                }
            }
        }
        out
    }

    fn signed_ops(server_id: &str, start: u64) -> Vec<CrdtOp> {
        let owner = key(0);
        let payloads = vec![
            CrdtPayload::ChannelAdded { channel_id: "c1".into(), name: "c1".into(), category: None, channel_type: "text".into() },
            CrdtPayload::ServerRenamed { new_name: "T".into() },
            CrdtPayload::MemberAdded {
                peer_id: key(1).id.clone(),
                display_name: "one".into(),
                follow: None,
                ask: Some(JoinAsk::sign(server_id, start as i64, &key(1).kp)),
            },
        ];
        payloads
            .into_iter()
            .enumerate()
            .map(|(i, payload)| {
                let mut op = CrdtOp {
                    server_id: server_id.into(),
                    hlc: HlcTimestamp { physical_ms: start + 1000 * (i as u64 + 1), counter: 0, actor: owner.id.clone() },
                    author: owner.id.clone(),
                    payload,
                    auth: None,
                    dev: None,
                };
                op.sign(&owner.kp, &owner.pk);
                op
            })
            .collect()
    }

    /// One op of a `crdt_fold` script.
    fn script_op(author: u8, secs: u16, counter: u8, payload: &str) -> Vec<u8> {
        let mut out = vec![author];
        out.extend_from_slice(&secs.to_be_bytes());
        out.push(counter);
        out.extend_from_slice(&(payload.len() as u16).to_be_bytes());
        out.extend_from_slice(payload.as_bytes());
        out
    }

    #[test]
    #[ignore = "writes the fuzz seed corpora; run by hand"]
    fn write_fuzz_seeds() {
        let Ok(dir) = std::env::var("HOLLOW_FUZZ_SEEDS") else { return };
        let out = Out(PathBuf::from(dir));
        let now = now_ms();

        // Relay frames: what the relay's own vectors say it sends, and sealed frames.
        let session = vectors("relay-uws/test/session_vectors.json");
        let mut texts: Vec<String> = session["counted"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|c| c["dir"] == "relay")
            .map(|c| c["text"].as_str().unwrap().to_string())
            .collect();
        let kills = vectors("relay-uws/test/kill_vectors.json");
        let blob = kills["cases"][0]["blob"].as_str().unwrap();
        texts.push(serde_json::json!({"type": "kill_signal", "blob": blob, "issued_at_ms": 1, "issuer": key(1).id}).to_string());
        texts.push(serde_json::json!({"type": "members", "room": "r", "peers": [key(1).id, key(0).id], "proved": true}).to_string());
        texts.push(serde_json::json!({"type": "peer_joined", "room": "r", "peer_id": key(1).id}).to_string());
        texts.push(serde_json::json!({"type": "auth_ok", "peer_id": key(0).id}).to_string());
        let owner = &key(0).kp;
        let lock = crate::node::join_lock::mint_owner_base("00112233445566778899aabbccddeeff", 1, owner, None, owner).unwrap();
        let lock_json = serde_json::to_string(&lock.link).unwrap();
        texts.push(format!(r#"{{"type":"lock_chain","server":"00112233445566778899aabbccddeeff","links":[{lock_json}]}}"#));
        let body = serde_json::json!({"type": "Ping"}).to_string();
        let sealed = frame_auth::seal(&key(1).kp, "room", frame_auth::ROUTE_ROOM, body.as_bytes());
        let mut binary = vec![0x05];
        binary.extend_from_slice(format!("room\0{}\0", key(1).id).as_bytes());
        binary.extend_from_slice(&sealed);
        for t in &texts {
            out.put("relay_frames", &framed(&[(1, t.as_bytes())]));
        }
        out.put("relay_frames", &framed(&[(0, &binary)]));
        let all: Vec<(u8, &[u8])> = texts.iter().map(|t| (1u8, t.as_bytes())).chain([(0u8, binary.as_slice())]).collect();
        out.put("relay_frames", &framed(&all));

        out.put("frame_seal", b"\x00\x04room\x00\x00\x01\x00\x05\x01{\"type\":\"Ping\"}");
        out.put("frame_seal", b"\x03\x04room\x05route\x00\x09\x00\x30\x80body");

        // Peer messages and envelopes: every JSON literal the unit tests hand them.
        for lit in json_literals() {
            if serde_json::from_str::<HavenMessage>(&lit).is_ok() {
                out.put("haven_message", lit.as_bytes());
            }
            if serde_json::from_str::<MessageEnvelope>(&lit).is_ok() {
                out.put("message_envelope", lit.as_bytes());
            }
            if serde_json::from_str::<crate::node::types::LinkPreviewRef>(&lit).is_ok() {
                let mut seed = (lit.len() as u16).to_be_bytes().to_vec();
                seed.extend_from_slice(lit.as_bytes());
                out.put("link_preview", &seed);
            }
        }

        // CRDT: signed batches, scripts, digests.
        let start = crate::crdt::hlc::wall_clock_ms() - 3_600_000;
        let (server_id, founder) = founding(start);
        let ops: Vec<CrdtOp> = std::iter::once(founder).chain(signed_ops(&server_id, start)).collect();
        out.put("crdt_ops", serde_json::to_string(&ops).unwrap().as_bytes());
        out.put("crdt_ops", serde_json::to_string(&ops[1]).unwrap().as_bytes());
        let payloads = [
            r#"{"ChannelAdded":{"channel_id":"c1","name":"c1","category":null,"channel_type":"text"}}"#.to_string(),
            r#"{"MemberAdded":{"peer_id":"$1","display_name":"one","ask":{"at":5,"sig":"","pk":""}}}"#.to_string(),
            r#"{"MemberAdded":{"peer_id":"$2","display_name":"two","ask":{"at":6,"sig":"","pk":""}}}"#.to_string(),
            r#"{"RoleChanged":{"peer_id":"$1","role":"Admin","priority":2}}"#.to_string(),
            r#"{"MemberBanned":{"peer_id":"$2"}}"#.to_string(),
            r#"{"NicknameChanged":{"peer_id":"$1","nickname":"n"}}"#.to_string(),
            r#"{"ChannelVisibilityChanged":{"channel_id":"c1","visibility":"restricted"}}"#.to_string(),
            r#"{"LabelCreated":{"label_id":"l1","name":"L","color":"fff","access":true}}"#.to_string(),
            r#"{"LabelAssigned":{"label_id":"l1","peer_id":"$1"}}"#.to_string(),
            r#"{"ChannelGrantSet":{"channel_id":"c1","peer_id":"$2","expires_at":0}}"#.to_string(),
            r#"{"MemberMuted":{"peer_id":"$1","expires_at":0}}"#.to_string(),
            r#"{"MemberRemoved":{"peer_id":"$1"}}"#.to_string(),
            r#"{"ServerSettingChanged":{"key":"nsfw","value":"true"}}"#.to_string(),
            r#"{"ServerDeleted":{"deleted_at":5}}"#.to_string(),
        ];
        let authors = [0u8, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0];
        let mut script = vec![0u8];
        for (i, (p, a)) in payloads.iter().zip(authors).enumerate() {
            let op = script_op(a, 10 + i as u16, 0, p);
            out.put("crdt_fold", &[&[0u8][..], &op].concat());
            script.extend_from_slice(&op);
        }
        out.put("crdt_fold", &script);
        script[0] = 1;
        out.put("crdt_fold", &script);
        for op in &ops[1..] {
            let p = serde_json::to_string(&op.payload).unwrap();
            out.put("crdt_fold", &[&[0u8][..], &script_op(0, 5, 0, &p)].concat());
        }

        let mut s = ServerState::skeleton(server_id.clone());
        let _ = s.ingest_remote(&ops);
        let entries = crate::crdt::digest::entries(&s, &[], None);
        let d = crate::crdt::digest::first_ask(&entries, 7, crate::crdt::digest::new_salt(), None, None);
        let dj = serde_json::to_vec(&d).unwrap();
        let mut seed = (dj.len() as u16).to_be_bytes().to_vec();
        seed.extend_from_slice(&dj);
        if let Some((_, reply)) = crate::crdt::digest::answer(&entries, &d) {
            seed.extend_from_slice(&serde_json::to_vec(&reply).unwrap());
        }
        out.put("crdt_digest", &seed);

        // Identity: the roster and kill vectors as they stand.
        for case in vectors("relay-uws/test/roster_vectors.json")["cases"].as_array().unwrap() {
            out.put("roster", case.to_string().as_bytes());
        }
        for case in kills["cases"].as_array().unwrap() {
            out.put("kill_order", case.to_string().as_bytes());
        }
        let base = crate::node::join_lock::mint_owner_base(&server_id, 1, owner, None, owner).unwrap();
        let next = crate::node::join_lock::mint_successor(&server_id, &base.link, &base.change, &key(0).id, owner);
        let mut links = vec![base.link.clone()];
        links.extend(next.map(|n| n.link));
        let ask = JoinAsk::sign(&server_id, 5, &key(1).kp);
        out.put(
            "join_lock",
            serde_json::json!({"server": server_id, "owner": key(0).id, "links": links, "ask": ask, "joiner": key(1).id})
                .to_string()
                .as_bytes(),
        );

        // Names, ids, signatures.
        for name in ["photo.jpg", "../../etc/passwd", "CON.txt", "a\\b:c", "\u{202E}gpj.exe", "..", "x".repeat(300).as_str()] {
            out.put("file_names", &[&[0u8][..], name.as_bytes()].concat());
        }
        let fid_seed = format!("{}\u{1f}{}\u{1f}mid\u{1f}{}\u{1f}a.png\u{1f}png", "0".repeat(64), key(1).id, "a".repeat(64));
        out.put("file_names", &[&[1u8][..], fid_seed.as_bytes()].concat());
        out.put("message_sig", &[0u8; 64]);
        let link = crate::node::share_handler::encode_link(&[1; 32], &[2; 32]);
        out.put("share_wire", &[&[0u8, 3, 1, 0xff][..], link.as_bytes()].concat());
        let manifest = serde_json::json!({"version": 1, "file_name": "a.bin", "mime": "application/octet-stream",
            "total_size": 300_000, "chunk_size": 262_144, "chunk_count": 2, "chunk_hashes": (vec![[0u8; 32], [1u8; 32]]),
            "created_at": 5});
        out.put("share_wire", &[&[0u8, 2, 1, 0xc0][..], manifest.to_string().as_bytes()].concat());
        for id in [key(1).id.clone(), server_id.clone(), "conf:abc".into(), crate::node::sealed_box::key_to_text(&[9; 32])] {
            out.put("peer_ids", id.as_bytes());
        }

        // Pages, packs, zips.
        let page = r#"<html><head><meta property="og:title" content="T"><meta property="og:image" content="/i.png"><meta name="twitter:card" content="summary_large_image"><meta property="og:image:width" content="1200"></head></html>"#;
        out.put("link_preview", &[&[0u8, 0][..], page.as_bytes()].concat());
        out.put("link_preview", &[&[0u8, 0][..], b"https://x.com/a/status/123\n{\"tweet\":{\"text\":\"hi\",\"author\":{\"name\":\"a\"}}}"].concat());

        let mut img = image::RgbaImage::new(64, 64);
        for (x, y, px) in img.enumerate_pixels_mut() {
            *px = image::Rgba([x as u8 * 4, y as u8 * 4, 140, 255]);
        }
        let mut png = Vec::new();
        image::DynamicImage::ImageRgba8(img.clone()).write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
        let files = crate::hollowpack::process_source(crate::hollowpack::RoleHint::Avatar, &png).unwrap();
        let webp = files[0].bytes.clone();
        let (pack, _) = crate::hollowpack::build_pack(&crate::hollowpack::PackInput {
            title: "t".into(),
            artist_name: "a".into(),
            artist_slug: "a".into(),
            artist_url: "https://example.invalid/a".into(),
            license: "l".into(),
            item_id: None,
            kinds: vec!["avatar".into()],
            files,
        })
        .unwrap();
        out.put("hollowpack", &pack);
        for pick in 0..5u8 {
            out.put("peer_images", &[&[pick][..], &webp].concat());
            out.put("peer_images", &[&[pick][..], &png].concat());
        }
        out.put("snapshot_zip", &zip_of(&[("identity.key", b"k"), ("messages.db", b"db"), ("files/a.bin", b"f"), ("vault/b", b"v")]));
        out.put("snapshot_zip", &zip_of(&[("../identity.key", b"k")]));
        for fv in 1..=3u32 {
            let manifest = serde_json::json!({
                "format_version": fv, "archive_type": "dm", "exporter_peer_id": key(0).id, "export_timestamp": 1,
                "message_count": 1, "file_mode": "full", "peer_id": key(1).id, "participants": [key(0).id, key(1).id],
            })
            .to_string();
            let msg = serde_json::json!([{"message_id": "m1", "sender_id": key(1).id, "text": "hi", "timestamp": 5}]).to_string();
            let meta = serde_json::json!({"file_id": "ab12", "file_name": "x", "file_ext": "png", "mime_type": "image/png",
                "size_bytes": 5, "is_image": true, "included": true}).to_string();
            out.put("archive_zip", &zip_of(&[
                ("manifest.json", manifest.as_bytes()),
                ("pubkeys.json", b"[]"),
                ("messages/0.json", msg.as_bytes()),
                ("files/ab12.png", b"image"),
                ("files/ab12.meta.json", meta.as_bytes()),
            ]));
        }

        // Push wakes: the sidecar's sealed vectors, their plaintext and their fields.
        let wakes = vectors("push-sidecar/test/sealed_wake_vectors.json");
        for case in wakes["cases"].as_array().unwrap() {
            let fields: BTreeMap<String, String> = case["data"]
                .as_object()
                .unwrap()
                .iter()
                .filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_string())))
                .collect();
            if let Some(sealed) = fields.get("sealed") {
                let body = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(sealed.trim_end_matches('=')).unwrap();
                out.put("push_wake", &[&[0u8][..], &body].concat());
            }
            out.put("push_wake", &[&[2u8][..], serde_json::to_string(&fields).unwrap().as_bytes()].concat());
            out.put("push_wake", &[&[1u8][..], case["wake"].to_string().as_bytes()].concat());
        }

        // Cards: what an honest peer seals, with and without a thumb.
        let card = serde_json::json!({"master": key(1).id, "display_name": "n", "avatar_hash": "", "updated_at": 5,
            "sig": "", "pk": key(1).pk, "thumb": B64.encode(&webp)});
        out.put("profile_card", card.to_string().as_bytes());

        // MLS: a KeyPackage another device minted.
        let other = crate::crypto::MlsManager::new(&key(2).kp, &key(3).kp).unwrap();
        let kp = other.generate_key_package().unwrap();
        for pick in 0..4u8 {
            out.put("mls_message", &[&[pick][..], &kp].concat());
        }
        let _ = now;
    }
}

/// The entry a target of this name runs.
pub fn by_name(name: &str) -> Option<fn(&[u8])> {
    Some(match name {
        "relay_frames" => relay_frames,
        "frame_seal" => frame_seal,
        "haven_message" => haven_message,
        "message_envelope" => message_envelope,
        "crdt_ops" => crdt_ops,
        "crdt_fold" => crdt_fold,
        "crdt_digest" => crdt_digest,
        "roster" => roster,
        "kill_order" => kill_order,
        "join_lock" => join_lock,
        "file_names" => file_names,
        "message_sig" => message_sig,
        "share_wire" => share_wire,
        "link_preview" => link_preview,
        "hollowpack" => hollowpack,
        "snapshot_zip" => snapshot_zip,
        "archive_zip" => archive_zip,
        "push_wake" => push_wake,
        "profile_card" => profile_card,
        "mls_message" => mls_message,
        "peer_images" => peer_images,
        "peer_ids" => peer_ids,
        _ => return None,
    })
}
