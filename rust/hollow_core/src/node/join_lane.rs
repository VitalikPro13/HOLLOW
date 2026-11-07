//! The join lane (claim C-24): what a joiner and a server's members say to each
//! other before the joiner is a member, when neither an Olm session nor the MLS group
//! can carry it.
//!
//! A request is sealed to the server's current door key (`join_lock`) and its invite
//! key together: only an invite holder can write it, and only someone holding the
//! current door, a member, can read it. It carries the joiner's own reply key, and
//! every answer is sealed to that from the door, so the joiner reads each answer and
//! knows it came from a holder of the door it names. Both kinds of box ride
//! [`HavenMessage::JoinSealed`] in the server's own room, bound to it, to the device
//! that sealed the frame and to the door's number.

use zeroize::Zeroizing;

use super::sealed_box;
use super::types::{HavenMessage, PendingJoin};
use super::ws_client::WsCommand;

type WsCmdTx = tokio::sync::mpsc::UnboundedSender<WsCommand>;

const JOIN_DOMAIN: &[u8] = b"hollow-join-box2";
const REPLY_DOMAIN: &[u8] = b"hollow-join-reply2";

/// The secret half of a joiner's reply key.
#[derive(Clone)]
pub(crate) struct ReplySecret(Zeroizing<[u8; 32]>);

impl std::fmt::Debug for ReplySecret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ReplySecret(..)")
    }
}

impl ReplySecret {
    pub(crate) fn new() -> Option<Self> {
        sealed_box::new_secret().map(Self)
    }

    /// The form the pending-join row stores.
    pub(crate) fn to_stored(&self) -> String {
        hex::encode(self.0.as_slice())
    }

    pub(crate) fn from_stored(text: &str) -> Option<Self> {
        let bytes = Zeroizing::new(hex::decode(text).ok()?);
        Some(Self(Zeroizing::new(bytes.as_slice().try_into().ok()?)))
    }

    /// The public half, as the request carries it.
    pub(crate) fn public_text(&self) -> String {
        sealed_box::key_to_text(&sealed_box::public_of(&self.0))
    }

    pub(crate) fn bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

fn join_aad(server_id: &str, sender_device: &str, n: u64) -> Vec<u8> {
    [server_id.as_bytes(), b"\0", sender_device.as_bytes(), b"\0", &n.to_le_bytes()].concat()
}

fn reply_aad(server_id: &str, sender_device: &str, joiner_device: &str, n: u64) -> Vec<u8> {
    [server_id.as_bytes(), b"\0", sender_device.as_bytes(), b"\0", joiner_device.as_bytes(), b"\0", &n.to_le_bytes()].concat()
}

fn frame(sealed: sealed_box::Sealed, n: u64, door: String) -> Option<Vec<u8>> {
    serde_json::to_vec(&HavenMessage::JoinSealed { eph: sealed.eph, ct: sealed.ct, n, door }).ok()
}

/// The sizes every box to the members pads to (DEVICE_PROOF_DESIGN 8.7, R31-7), so the
/// relay cannot tell a recovering joiner by its size; past the last, the next power of two.
pub(crate) const BOX_BUCKETS: [usize; 3] = [2 << 10, 8 << 10, 32 << 10];

/// The size a plaintext of `len` bytes pads to.
pub(crate) fn bucket_for(len: usize) -> usize {
    BOX_BUCKETS.iter().copied().find(|b| len <= *b).unwrap_or_else(|| len.next_power_of_two())
}

/// Trailing spaces up to the bucket: JSON readers skip them, so an old member reads the
/// box as before.
fn pad_to_bucket(plain: &mut Vec<u8>) {
    let to = bucket_for(plain.len());
    plain.resize(to, b' ');
}

/// The frame bytes of `msg` sealed to door `n` and the invite key, sent by `sender_device`.
pub(crate) fn seal_to_members(
    door: &[u8; 32],
    invite: &[u8; 32],
    n: u64,
    server_id: &str,
    sender_device: &str,
    msg: &HavenMessage,
) -> Option<Vec<u8>> {
    let mut plain = serde_json::to_vec(msg).ok()?;
    pad_to_bucket(&mut plain);
    frame(sealed_box::seal_to_both(door, invite, JOIN_DOMAIN, &join_aad(server_id, sender_device, n), &plain)?, n, String::new())
}

/// The frame bytes of `msg` sealed to a joiner's reply key from door `n`, sent by
/// `sender_device`.
pub(crate) fn seal_to_joiner(
    reply_key: &[u8; 32],
    door_secret: &[u8; 32],
    n: u64,
    server_id: &str,
    sender_device: &str,
    joiner_device: &str,
    msg: &HavenMessage,
) -> Option<Vec<u8>> {
    let plain = serde_json::to_vec(msg).ok()?;
    let aad = reply_aad(server_id, sender_device, joiner_device, n);
    let door = sealed_box::key_to_text(&sealed_box::public_of(door_secret));
    frame(sealed_box::seal_from(reply_key, door_secret, REPLY_DOMAIN, &aad, &plain)?, n, door)
}

/// Our own join request, sealed to the door our verified lock names and to the
/// invite's key. `None` without both, or without a reply key: nothing else may carry it.
pub(crate) fn request_frame(server_id: &str, our_device: &str, pending: &PendingJoin, parked: bool) -> Option<Vec<u8>> {
    let invite = sealed_box::key_from_text(pending.join_key.as_deref()?)?;
    let door = pending.lock.as_ref()?.newest()?;
    let mut request = HavenMessage::ServerJoinRequest {
        server_id: server_id.to_string(),
        twitch_proof_json: pending.twitch_proof_json.clone(),
        nsfw_confirmed: pending.nsfw_confirmed,
        requested_at: pending.requested_at,
        device_list: pending.device_list.clone(),
        parked,
        // Only the ring copy seats a leaf; a live ask bootstraps on its SyncResponse.
        key_package: pending.key_package.clone().filter(|_| parked),
        reply_key: pending.reply_secret.as_ref()?.public_text(),
        card: pending.card.clone(),
        // The avatar is for the member deciding right now; a ring copy stays small.
        avatar_b64: if parked { String::new() } else { pending.avatar_b64.clone() },
        ask: pending.ask.clone(),
        follows_leave: pending.follows_leave.clone(),
    };
    omit_roster_past_the_box(&mut request);
    seal_to_members(&door.door_key()?, &invite, door.n, server_id, our_device, &request)
}

/// A roster that would take the box past its largest bucket rides nothing: the box is
/// never refused for it, and the members ask for it (`roster_needed`) or hear our room
/// notice (R31-7). The avatar is the person's card, measured apart.
fn omit_roster_past_the_box(request: &mut HavenMessage) {
    let HavenMessage::ServerJoinRequest { device_list, avatar_b64, .. } = request else { return };
    if device_list.is_none() {
        return;
    }
    let avatar = std::mem::take(avatar_b64);
    let len = serde_json::to_vec(&*request).map_or(usize::MAX, |v| v.len());
    let HavenMessage::ServerJoinRequest { device_list, avatar_b64, .. } = request else { return };
    if len > BOX_BUCKETS[BOX_BUCKETS.len() - 1] {
        hollow_log!("[HOLLOW-CRDT] Our roster does not fit a join box ({len} B): the members ask for it");
        *device_list = None;
    }
    *avatar_b64 = avatar;
}

/// Send our join request to one member device in the server's room. `false` when it
/// cannot be sealed yet: no verified lock, or no invite key.
pub(crate) fn send_request(ws_cmd_tx: &WsCmdTx, server_id: &str, our_device: &str, pending: &mut PendingJoin, target: &str) -> bool {
    let Some(data) = request_frame(server_id, our_device, pending, false) else {
        hollow_log!("[HOLLOW-CRDT] No verified join lock for {server_id} yet: the request cannot be sealed, not sent");
        return false;
    };
    let _ = ws_cmd_tx.send(WsCommand::SendDirect {
        room_code: server_id.to_string(),
        target_peer: target.to_string(),
        data,
    });
    went_out(pending)
}

/// Send our join request to every member who sees the server's room: a joiner the
/// relay hides there sees none of them. `false` when it cannot be sealed yet.
pub(crate) fn send_request_to_room(ws_cmd_tx: &WsCmdTx, server_id: &str, our_device: &str, pending: &mut PendingJoin) -> bool {
    let Some(data) = request_frame(server_id, our_device, pending, false) else { return false };
    let _ = ws_cmd_tx.send(WsCommand::SendToRoom { room_code: server_id.to_string(), data });
    went_out(pending)
}

/// A copy of the ask went out: the first one starts its coordinator window.
fn went_out(pending: &mut PendingJoin) -> bool {
    pending.first_sent_at.get_or_insert_with(std::time::Instant::now);
    true
}

/// What a join box from `from` in `room` holds, opened with the invite key and a door
/// secret of number `n`: a request with its reply key, or a members' resolution, for
/// this server. `None` otherwise.
pub(crate) fn open_for_members(
    invite: &[u8; 32],
    doors: &[Zeroizing<[u8; 32]>],
    room: &str,
    from: &str,
    n: u64,
    eph: &str,
    ct: &str,
) -> Option<HavenMessage> {
    let aad = join_aad(room, from, n);
    let plain = doors.iter().find_map(|door| sealed_box::open_with_both(door, invite, JOIN_DOMAIN, &aad, eph, ct))?;
    let msg = serde_json::from_slice::<HavenMessage>(&plain).ok()?;
    let fits = match &msg {
        // An ask naming its invite key names the one it was sealed to.
        HavenMessage::ServerJoinRequest { server_id, reply_key, ask, .. } => {
            server_id == room
                && sealed_box::key_from_text(reply_key).is_some()
                && ask.as_ref().and_then(|a| a.key.as_deref()).is_none_or(|key| {
                    sealed_box::key_from_text(key) == Some(sealed_box::public_of(invite))
                })
        }
        HavenMessage::ServerJoinResolved { server_id, .. } => server_id == room,
        _ => false,
    };
    fits.then_some(msg)
}

/// What a join box holds for a member of `state`'s server, and whether a key an invite
/// reset retired opened it: then only a request, which earns nothing but that refusal
/// (`join_verdict::link_refusal`).
pub(crate) fn open_as_member(
    state: &crate::crdt::server_state::ServerState,
    room: &str,
    from: &str,
    n: u64,
    eph: &str,
    ct: &str,
) -> Option<(HavenMessage, bool)> {
    let doors = state.join_lock.door_secrets(n);
    if let Some(invite) = state.join_secret()
        && let Some(msg) = open_for_members(&invite, &doors, room, from, n, eph, ct)
    {
        return Some((msg, false));
    }
    state
        .retired_join_secrets()
        .iter()
        .find_map(|old| open_for_members(old, &doors, room, from, n, eph, ct))
        .filter(|msg| matches!(msg, HavenMessage::ServerJoinRequest { .. }))
        .map(|msg| (msg, true))
}

/// What a reply box sealed to us from door `n` holds, when `door` is that door's
/// public half: an answer to our join of this server, and nothing else.
#[allow(clippy::too_many_arguments)]
pub(crate) fn open_for_joiner(
    reply: &ReplySecret,
    door: &[u8; 32],
    room: &str,
    from: &str,
    our_device: &str,
    n: u64,
    eph: &str,
    ct: &str,
) -> Option<HavenMessage> {
    let plain = sealed_box::open_from(reply.bytes(), door, REPLY_DOMAIN, &reply_aad(room, from, our_device, n), eph, ct)?;
    let msg = serde_json::from_slice::<HavenMessage>(&plain).ok()?;
    let fits = match &msg {
        HavenMessage::SyncResponse { server_id, .. }
        | HavenMessage::ServerStateSnapshot { server_id, .. }
        | HavenMessage::ServerJoinRejected { server_id, .. }
        | HavenMessage::ServerJoinResolved { server_id, .. } => server_id == room,
        _ => false,
    };
    fits.then_some(msg)
}

/// One join ask a member is answering, and where every answer to it goes.
pub(crate) struct Answer<'a> {
    pub server_id: &'a str,
    /// Our own device: every box binds the device that sealed its frame.
    pub our_device: &'a str,
    /// The newest door we hold: every answer is sealed from it, so the joiner can
    /// tell it from one a removed member sends.
    pub door: Option<(u64, [u8; 32], Zeroizing<[u8; 32]>)>,
    /// The server's invite key, public half, for the copy the other members read.
    pub invite: Option<[u8; 32]>,
    pub joiner_device: &'a str,
    pub joiner_master: &'a str,
    pub reply_key: &'a str,
    pub requested_at: i64,
    /// The relay topic of the server's join ring (`ring_auth::topic`).
    pub join_ring: String,
}

impl Answer<'_> {
    /// Send `msg` to the joiner, sealed to its reply key, into the server's room,
    /// where the relay keeps it for a joiner who is not there.
    pub(crate) fn reply(&self, ws_cmd_tx: &WsCmdTx, msg: &HavenMessage) {
        let Some(data) = self.sealed_to_joiner(msg) else {
            hollow_log!("[HOLLOW-SECURITY] Answer to {} for {} not sent: no door of ours, or its reply key does not seal", self.joiner_device, self.server_id);
            return;
        };
        let _ = ws_cmd_tx.send(WsCommand::SendDirect {
            room_code: self.server_id.to_string(),
            target_peer: self.joiner_device.to_string(),
            data,
        });
    }

    pub(crate) fn sealed_to_joiner(&self, msg: &HavenMessage) -> Option<Vec<u8>> {
        let key = sealed_box::key_from_text(self.reply_key)?;
        let (n, _, secret) = self.door.as_ref()?;
        seal_to_joiner(&key, secret, *n, self.server_id, self.our_device, self.joiner_device, msg)
    }

    /// `msg` sealed for the other members, to our newest door and the invite key.
    pub(crate) fn sealed_to_members(&self, msg: &HavenMessage) -> Option<Vec<u8>> {
        let (n, door, _) = self.door.as_ref()?;
        seal_to_members(door, self.invite.as_ref()?, *n, self.server_id, self.our_device, msg)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(server_id: &str, reply_key: &str) -> HavenMessage {
        HavenMessage::ServerJoinRequest {
            server_id: server_id.into(),
            twitch_proof_json: None,
            nsfw_confirmed: false,
            requested_at: 5,
            device_list: None,
            parked: false,
            key_package: None,
            reply_key: reply_key.into(),
            card: None,
            avatar_b64: String::new(),
            ask: None,
            follows_leave: None,
        }
    }

    fn sync(server_id: &str) -> HavenMessage {
        HavenMessage::SyncResponse { server_id: server_id.into(), ops_json: "[]".into(), nonce: None, page: None, digest: None, x: None }
    }

    fn resolved(server_id: &str) -> HavenMessage {
        HavenMessage::ServerJoinResolved {
            server_id: server_id.into(),
            joiner_master: "j".into(),
            requested_at: 5,
            admitted: false,
            reason: "banned".into(),
            op_json: None,
        }
    }

    fn parts(frame: &[u8]) -> (String, String, u64) {
        let HavenMessage::JoinSealed { eph, ct, n, .. } = serde_json::from_slice(frame).unwrap() else {
            panic!("a join-lane frame");
        };
        (eph, ct, n)
    }

    fn key() -> (Zeroizing<[u8; 32]>, [u8; 32]) {
        let secret = sealed_box::new_secret().unwrap();
        let public = sealed_box::public_of(&secret);
        (secret, public)
    }

    fn as_member(frame: &[u8], invite: &[u8; 32], door: &Zeroizing<[u8; 32]>, room: &str, from: &str) -> Option<HavenMessage> {
        let (eph, ct, n) = parts(frame);
        open_for_members(invite, std::slice::from_ref(door), room, from, n, &eph, &ct)
    }

    fn roster_of(devices: u8) -> crate::identity::roster::Roster {
        let master = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[3; 32]);
        let mut r = crate::identity::roster::Roster::new(&master.peer_id());
        for i in 0..devices {
            let d = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[i.wrapping_add(10); 32]);
            r.consents.push(crate::identity::roster::sign_consent(&d, &master.peer_id()));
        }
        r
    }

    fn with_roster(reply: &str, roster: crate::identity::roster::Roster, avatar: usize) -> HavenMessage {
        let mut msg = request("srv", reply);
        if let HavenMessage::ServerJoinRequest { device_list, avatar_b64, .. } = &mut msg {
            *device_list = Some(roster);
            *avatar_b64 = "A".repeat(avatar);
        }
        msg
    }

    #[test]
    fn join_boxes_pad_to_fixed_sizes() {
        let (invite_s, invite) = key();
        let (door_s, door) = key();
        let reply = ReplySecret::new().unwrap().public_text();
        let ct_len = |msg: &HavenMessage| parts(&seal_to_members(&door, &invite, 1, "srv", "dev", msg).unwrap()).1.len();
        let small = ct_len(&request("srv", &reply));
        assert_eq!(small, ct_len(&with_roster(&reply, roster_of(2), 0)), "a roster in the box shows in its size");
        assert_ne!(small, ct_len(&with_roster(&reply, roster_of(30), 0)), "a 2 KiB box held an 8 KiB request");
        assert_eq!(bucket_for(1), 2048);
        assert_eq!(bucket_for(2049), 8192);
        assert_eq!(bucket_for(20_000), 32 << 10);
        assert_eq!(bucket_for(40_000), 64 << 10);
        let padded = with_roster(&reply, roster_of(2), 0);
        assert!(
            matches!(as_member(&seal_to_members(&door, &invite, 1, "srv", "dev", &padded).unwrap(), &invite_s, &door_s, "srv", "dev"),
                Some(HavenMessage::ServerJoinRequest { device_list: Some(_), .. })),
            "a padded box does not read",
        );
    }

    #[test]
    fn a_joiner_with_a_flooded_roster_still_joins() {
        let reply = ReplySecret::new().unwrap().public_text();
        let mut fits = with_roster(&reply, roster_of(4), 100_000);
        omit_roster_past_the_box(&mut fits);
        assert!(
            matches!(&fits, HavenMessage::ServerJoinRequest { device_list: Some(_), avatar_b64, .. } if avatar_b64.len() == 100_000),
            "the avatar pushed the roster out, or was lost",
        );
        let mut flooded = with_roster(&reply, roster_of(200), 0);
        omit_roster_past_the_box(&mut flooded);
        assert!(matches!(flooded, HavenMessage::ServerJoinRequest { device_list: None, .. }), "a roster past the box rode it");
        let (invite_s, invite) = key();
        let (door_s, door) = key();
        assert!(
            as_member(&seal_to_members(&door, &invite, 1, "srv", "dev", &flooded).unwrap(), &invite_s, &door_s, "srv", "dev").is_some(),
            "the box was refused for its roster",
        );
    }

    #[test]
    fn a_join_box_opens_only_with_the_door_and_the_invite_key() {
        let (invite_s, invite) = key();
        let (door_s, door) = key();
        let (old_door, _) = key();
        let reply = ReplySecret::new().unwrap();
        let frame = seal_to_members(&door, &invite, 4, "srv", "joiner", &request("srv", &reply.public_text())).unwrap();
        assert_eq!(parts(&frame).2, 4, "the frame names its door");
        assert!(matches!(as_member(&frame, &invite_s, &door_s, "srv", "joiner"), Some(HavenMessage::ServerJoinRequest { .. })));
        assert!(as_member(&frame, &invite_s, &old_door, "srv", "joiner").is_none(), "a door that is not the one it names");
        let (other_invite, _) = key();
        assert!(as_member(&frame, &other_invite, &door_s, "srv", "joiner").is_none(), "another server's invite key");
        assert!(as_member(&frame, &invite_s, &door_s, "other", "joiner").is_none(), "another room");
        assert!(as_member(&frame, &invite_s, &door_s, "srv", "copier").is_none(), "sent on by another device");
        let (eph, ct, _) = parts(&frame);
        assert!(open_for_members(&invite_s, std::slice::from_ref(&door_s), "srv", "joiner", 5, &eph, &ct).is_none(), "the number is bound");
        // The door is public on the relay: a box sealed to it alone is anyone's.
        let plain = serde_json::to_vec(&request("srv", &reply.public_text())).unwrap();
        let door_only = sealed_box::seal(&door, JOIN_DOMAIN, &join_aad("srv", "joiner", 4), &plain).unwrap();
        assert!(
            open_for_members(&invite_s, std::slice::from_ref(&door_s), "srv", "joiner", 4, &door_only.eph, &door_only.ct).is_none(),
            "a box without the invite key",
        );
    }

    #[test]
    fn a_join_box_carries_only_a_request_with_its_reply_key_or_a_resolution() {
        let (invite_s, invite) = key();
        let (door_s, door) = key();
        let reply = ReplySecret::new().unwrap().public_text();
        let open_as_member = |msg: &HavenMessage| {
            as_member(&seal_to_members(&door, &invite, 1, "srv", "dev", msg).unwrap(), &invite_s, &door_s, "srv", "dev")
        };
        assert!(open_as_member(&resolved("srv")).is_some());
        assert!(open_as_member(&request("srv", "")).is_none(), "a request with nowhere to send the answer");
        assert!(open_as_member(&request("srv", "not a key")).is_none());
        assert!(open_as_member(&request("elsewhere", &reply)).is_none(), "a request naming another server");
        assert!(open_as_member(&resolved("elsewhere")).is_none());
        assert!(open_as_member(&sync("srv")).is_none(), "an answer to a joiner is not for the members");
    }

    #[test]
    fn a_reply_box_opens_only_from_the_door_it_names() {
        let reply = ReplySecret::new().unwrap();
        let reply_pub = sealed_box::key_from_text(&reply.public_text()).unwrap();
        let (door_s, door) = key();
        let (old_door_s, old_door) = key();
        let answer = |msg: &HavenMessage| seal_to_joiner(&reply_pub, &door_s, 7, "srv", "member", "joiner", msg).unwrap();
        let open = |frame: &[u8], door: &[u8; 32], room: &str, from: &str, ours: &str| {
            let (eph, ct, n) = parts(frame);
            open_for_joiner(&reply, door, room, from, ours, n, &eph, &ct)
        };
        let frame = answer(&sync("srv"));
        assert!(matches!(open(&frame, &door, "srv", "member", "joiner"), Some(HavenMessage::SyncResponse { .. })));
        assert!(open(&frame, &old_door, "srv", "member", "joiner").is_none(), "claimed from another door");
        assert!(open(&frame, &door, "srv", "member", "other-joiner").is_none(), "another joiner device");
        assert!(open(&frame, &door, "srv", "other-member", "joiner").is_none(), "sent on by another device");
        assert!(open(&frame, &door, "other", "member", "joiner").is_none(), "another room");

        let stale = seal_to_joiner(&reply_pub, &old_door_s, 7, "srv", "member", "joiner", &sync("srv")).unwrap();
        assert!(open(&stale, &door, "srv", "member", "joiner").is_none(), "an answer from someone holding only an old door");

        let snapshot = HavenMessage::ServerStateSnapshot { server_id: "srv".into(), state_json: "{}".into() };
        let rejected = HavenMessage::ServerJoinRejected { server_id: "srv".into(), reason: "banned".into(), requested_at: 5 };
        for fits in [snapshot, rejected, resolved("srv")] {
            assert!(open(&answer(&fits), &door, "srv", "member", "joiner").is_some());
        }
        let planted = request("srv", &reply.public_text());
        assert!(open(&answer(&planted), &door, "srv", "member", "joiner").is_none(), "no request rides a reply");
        assert!(open(&answer(&sync("elsewhere")), &door, "srv", "member", "joiner").is_none());
    }

    /// Invite reset: a member reads a box sealed to a retired invite key only as a
    /// request, so it can refuse it with the reason; a resolution sealed to it opens
    /// nothing, and an ask naming a key other than the one it was sealed to opens nothing.
    #[test]
    fn open_as_member_reads_an_old_link_only_to_refuse_it() {
        use crate::crdt::operations::{CrdtPayload, JoinAsk, JoinSecret};
        let (owner_kp, owner, _) = crate::crdt::testkeys::keys(1);
        let dev = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[42; 32]);
        let server = "0123456789abcdef0123456789abcdef";
        let mut s = crate::crdt::server_state::ServerState::new(server.into(), "S".into(), owner);
        let (kp, _, pk) = crate::crdt::testkeys::keys(1);
        s.set_signer(kp, pk);
        let lock = crate::node::join_lock::mint_owner_base(server, 1, &owner_kp, None, &dev).unwrap();
        let door = JoinSecret(hex::encode(lock.door.as_slice()));
        let op = s.create_op(CrdtPayload::JoinLock { link: lock.link.clone(), door: Some(door), grants: Default::default() });
        let _ = s.apply_op(&op);
        let (old_s, old) = key();
        let (_, new) = key();
        for secret in [&old_s, &sealed_box::new_secret().unwrap()] {
            let op = s.create_op(CrdtPayload::JoinKeySet { secret: JoinSecret(hex::encode(secret.as_slice())) });
            let _ = s.apply_op(&op);
        }
        let current = sealed_box::public_of(&s.join_secret().unwrap());
        let joiner = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[43; 32]);
        let ask_with = |key: &[u8; 32]| {
            let mut msg = request(server, &ReplySecret::new().unwrap().public_text());
            if let HavenMessage::ServerJoinRequest { ask, .. } = &mut msg {
                *ask = JoinAsk::sign_for_invite(server, 5, &sealed_box::key_to_text(key), &joiner);
            }
            msg
        };
        let door_key = lock.link.door_key().unwrap();
        let open = |invite: &[u8; 32], msg: &HavenMessage| {
            let frame = seal_to_members(&door_key, invite, 1, server, "joiner", msg).unwrap();
            let (eph, ct, n) = parts(&frame);
            open_as_member(&s, server, "joiner", n, &eph, &ct)
        };
        assert!(matches!(open(&current, &ask_with(&current)), Some((HavenMessage::ServerJoinRequest { .. }, false))), "the current link");
        assert!(
            matches!(open(&old, &ask_with(&old)), Some((HavenMessage::ServerJoinRequest { .. }, true))),
            "an old link's ask is read, to be refused",
        );
        let without_ask = request(server, &ReplySecret::new().unwrap().public_text());
        assert!(
            matches!(open(&old, &without_ask), Some((HavenMessage::ServerJoinRequest { ask: None, .. }, true))),
            "a request naming no key says a retired key opened it",
        );
        assert!(open(&old, &resolved(server)).is_none(), "a resolution sealed to a retired key");
        assert!(open(&old, &ask_with(&current)).is_none(), "an ask naming a key it was not sealed to");
        assert!(open(&new, &ask_with(&new)).is_none(), "a key the server never held");
    }

    #[test]
    fn a_reply_secret_survives_its_row_and_never_prints() {
        let reply = ReplySecret::new().unwrap();
        let stored = reply.to_stored();
        let back = ReplySecret::from_stored(&stored).unwrap();
        assert_eq!(back.public_text(), reply.public_text());
        assert!(!format!("{reply:?}").contains(&stored));
        assert!(ReplySecret::from_stored("abcd").is_none());
    }
}
