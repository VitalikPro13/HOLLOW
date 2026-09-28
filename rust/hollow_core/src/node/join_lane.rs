//! The join lane (claim C-24): what a joiner and a server's members say to each
//! other before the joiner is a member, when neither an Olm session nor the MLS group
//! can carry it.
//!
//! The Owner puts an X25519 join secret in the CRDT (`JoinKeySet`) and invite links
//! carry its public half, so only an invite holder can write to the members and only
//! members read it. Each request carries the joiner's own reply key, and every answer
//! is sealed to that. Both kinds of box ride [`HavenMessage::JoinSealed`] in the
//! server's own room, bound to it and to the device that sealed the frame.

use zeroize::Zeroizing;

use super::sealed_box;
use super::types::{HavenMessage, PendingJoin};
use super::ws_client::WsCommand;

type WsCmdTx = tokio::sync::mpsc::UnboundedSender<WsCommand>;

const JOIN_DOMAIN: &[u8] = b"hollow-join-box1";
const REPLY_DOMAIN: &[u8] = b"hollow-join-reply1";

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

fn join_aad(server_id: &str, sender_device: &str) -> Vec<u8> {
    [server_id.as_bytes(), b"\0", sender_device.as_bytes()].concat()
}

fn reply_aad(server_id: &str, sender_device: &str, joiner_device: &str) -> Vec<u8> {
    [server_id.as_bytes(), b"\0", sender_device.as_bytes(), b"\0", joiner_device.as_bytes()].concat()
}

fn frame(sealed: sealed_box::Sealed) -> Option<Vec<u8>> {
    serde_json::to_vec(&HavenMessage::JoinSealed { eph: sealed.eph, ct: sealed.ct }).ok()
}

/// The frame bytes of `msg` sealed to a server's join key, sent by `sender_device`.
pub(crate) fn seal_to_members(join_key: &[u8; 32], server_id: &str, sender_device: &str, msg: &HavenMessage) -> Option<Vec<u8>> {
    let plain = serde_json::to_vec(msg).ok()?;
    frame(sealed_box::seal(join_key, JOIN_DOMAIN, &join_aad(server_id, sender_device), &plain)?)
}

/// The frame bytes of `msg` sealed to a joiner's reply key, sent by `sender_device`.
pub(crate) fn seal_to_joiner(
    reply_key: &[u8; 32],
    server_id: &str,
    sender_device: &str,
    joiner_device: &str,
    msg: &HavenMessage,
) -> Option<Vec<u8>> {
    let plain = serde_json::to_vec(msg).ok()?;
    frame(sealed_box::seal(reply_key, REPLY_DOMAIN, &reply_aad(server_id, sender_device, joiner_device), &plain)?)
}

/// Our own join request, sealed to the server's join key from the invite. `None`
/// without a join key or a reply key, since nothing else may carry it.
pub(crate) fn request_frame(server_id: &str, our_device: &str, pending: &PendingJoin, parked: bool) -> Option<Vec<u8>> {
    let join_key = sealed_box::key_from_text(pending.join_key.as_deref()?)?;
    let request = HavenMessage::ServerJoinRequest {
        server_id: server_id.to_string(),
        twitch_proof_json: pending.twitch_proof_json.clone(),
        nsfw_confirmed: pending.nsfw_confirmed,
        requested_at: pending.requested_at,
        device_list: pending.device_list.clone(),
        parked,
        // Only the ring copy seats a leaf; a live ask bootstraps on its SyncResponse.
        key_package: pending.key_package.clone().filter(|_| parked),
        reply_key: pending.reply_secret.as_ref()?.public_text(),
    };
    seal_to_members(&join_key, server_id, our_device, &request)
}

/// Send our join request to one member device in the server's room.
pub(crate) fn send_request(ws_cmd_tx: &WsCmdTx, server_id: &str, our_device: &str, pending: &PendingJoin, target: &str) -> bool {
    let Some(data) = request_frame(server_id, our_device, pending, false) else {
        hollow_log!("[HOLLOW-CRDT] No join key for {server_id}: the request cannot be sealed, not sent");
        return false;
    };
    let _ = ws_cmd_tx.send(WsCommand::SendDirect {
        room_code: server_id.to_string(),
        target_peer: target.to_string(),
        data,
    });
    true
}

/// What a `JoinSealed` that arrived in `room` from `from` holds: `None` unless one of
/// our keys opens it and it holds a message that box may carry, for this server.
///
/// `join_secret` opens what joiners and members write to the members; `reply_secret`
/// opens what members write to us while our own join to `room` is pending.
pub(crate) fn open(
    join_secret: Option<&[u8; 32]>,
    reply_secret: Option<&ReplySecret>,
    room: &str,
    from: &str,
    our_device: &str,
    eph: &str,
    ct: &str,
) -> Option<HavenMessage> {
    if let Some(msg) = join_secret
        .and_then(|secret| sealed_box::open(secret, JOIN_DOMAIN, &join_aad(room, from), eph, ct))
        .and_then(|plain| serde_json::from_slice::<HavenMessage>(&plain).ok())
    {
        let fits = match &msg {
            HavenMessage::ServerJoinRequest { server_id, reply_key, .. } => {
                server_id == room && sealed_box::key_from_text(reply_key).is_some()
            }
            HavenMessage::ServerJoinResolved { server_id, .. } => server_id == room,
            _ => false,
        };
        return fits.then_some(msg);
    }
    let plain = sealed_box::open(reply_secret?.bytes(), REPLY_DOMAIN, &reply_aad(room, from, our_device), eph, ct)?;
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
    /// The server's join key, public half, for the copy the other members read.
    pub join_key: Option<[u8; 32]>,
    pub joiner_device: &'a str,
    pub joiner_master: &'a str,
    pub reply_key: &'a str,
    pub requested_at: i64,
}

impl Answer<'_> {
    /// Send `msg` to the joiner, sealed to its reply key, into the server's room,
    /// where the relay keeps it for a joiner who is not there.
    pub(crate) fn reply(&self, ws_cmd_tx: &WsCmdTx, msg: &HavenMessage) {
        let Some(data) = self.sealed_to_joiner(msg) else {
            hollow_log!("[HOLLOW-SECURITY] Answer to {} for {} not sent: its reply key does not seal", self.joiner_device, self.server_id);
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
        seal_to_joiner(&key, self.server_id, self.our_device, self.joiner_device, msg)
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
        }
    }

    fn sync(server_id: &str) -> HavenMessage {
        HavenMessage::SyncResponse { server_id: server_id.into(), ops_json: "[]".into() }
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

    fn opened(frame: &[u8], join: Option<&[u8; 32]>, reply: Option<&ReplySecret>, room: &str, from: &str, ours: &str) -> Option<HavenMessage> {
        let HavenMessage::JoinSealed { eph, ct } = serde_json::from_slice(frame).unwrap() else {
            panic!("a join-lane frame");
        };
        open(join, reply, room, from, ours, &eph, &ct)
    }

    fn join_key() -> (Zeroizing<[u8; 32]>, [u8; 32]) {
        let secret = sealed_box::new_secret().unwrap();
        let public = sealed_box::public_of(&secret);
        (secret, public)
    }

    #[test]
    fn a_join_box_opens_only_for_that_server_from_the_device_that_sealed_it() {
        let (secret, public) = join_key();
        let (other, _) = join_key();
        let reply = ReplySecret::new().unwrap();
        let frame = seal_to_members(&public, "srv", "joiner", &request("srv", &reply.public_text())).unwrap();
        assert!(matches!(
            opened(&frame, Some(&secret), None, "srv", "joiner", "member"),
            Some(HavenMessage::ServerJoinRequest { .. })
        ));
        assert!(opened(&frame, Some(&other), None, "srv", "joiner", "member").is_none(), "another server's key");
        assert!(opened(&frame, Some(&secret), None, "other", "joiner", "member").is_none(), "another room");
        assert!(opened(&frame, Some(&secret), None, "srv", "copier", "member").is_none(), "sent on by another device");
        assert!(opened(&frame, None, Some(&reply), "srv", "joiner", "member").is_none(), "a reply key opens no join box");
    }

    #[test]
    fn a_join_box_carries_only_a_request_with_its_reply_key_or_a_resolution() {
        let (secret, public) = join_key();
        let reply = ReplySecret::new().unwrap().public_text();
        let open_as_member = |msg: &HavenMessage| {
            opened(&seal_to_members(&public, "srv", "dev", msg).unwrap(), Some(&secret), None, "srv", "dev", "me")
        };
        assert!(open_as_member(&resolved("srv")).is_some());
        assert!(open_as_member(&request("srv", "")).is_none(), "a request with nowhere to send the answer");
        assert!(open_as_member(&request("srv", "not a key")).is_none());
        assert!(open_as_member(&request("elsewhere", &reply)).is_none(), "a request naming another server");
        assert!(open_as_member(&resolved("elsewhere")).is_none());
        assert!(open_as_member(&sync("srv")).is_none(), "an answer to a joiner is not for the members");
    }

    #[test]
    fn a_reply_box_opens_for_its_joiner_and_carries_only_answers() {
        let reply = ReplySecret::new().unwrap();
        let key = sealed_box::key_from_text(&reply.public_text()).unwrap();
        let (secret, _) = join_key();
        let answer = |msg: &HavenMessage| seal_to_joiner(&key, "srv", "member", "joiner", msg).unwrap();
        let frame = answer(&sync("srv"));
        assert!(matches!(
            opened(&frame, None, Some(&reply), "srv", "member", "joiner"),
            Some(HavenMessage::SyncResponse { .. })
        ));
        assert!(opened(&frame, None, Some(&reply), "srv", "member", "other-joiner").is_none(), "another joiner device");
        assert!(opened(&frame, None, Some(&reply), "srv", "other-member", "joiner").is_none(), "sent on by another device");
        assert!(opened(&frame, None, Some(&reply), "other", "member", "joiner").is_none(), "another room");
        assert!(opened(&frame, Some(&secret), None, "srv", "member", "joiner").is_none(), "a join key opens no reply");

        let snapshot = HavenMessage::ServerStateSnapshot { server_id: "srv".into(), state_json: "{}".into() };
        let rejected = HavenMessage::ServerJoinRejected { server_id: "srv".into(), reason: "banned".into(), requested_at: 5 };
        for fits in [snapshot, rejected, resolved("srv")] {
            assert!(opened(&answer(&fits), None, Some(&reply), "srv", "member", "joiner").is_some());
        }
        let planted = request("srv", &reply.public_text());
        assert!(opened(&answer(&planted), None, Some(&reply), "srv", "member", "joiner").is_none(), "no request rides a reply");
        assert!(opened(&answer(&sync("elsewhere")), None, Some(&reply), "srv", "member", "joiner").is_none());
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
