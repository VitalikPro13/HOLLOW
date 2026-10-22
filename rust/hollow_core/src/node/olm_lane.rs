//! The send half of [`Lane::Carried`]: a message the relay must never read (claim
//! C-24) rides inside one device's Olm session as `MessageEnvelope::Carried`.

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::time::Instant;

use crate::crypto::{CryptoStore, OlmManager};
use crate::identity::native_identity::NativeKeypair;

use super::types::*;
use super::ws_client::WsCommand;

/// What happens to a message for a device we hold no Olm session with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NoSession {
    /// Park it until a session exists (drained with every other queued envelope)
    /// and start a key exchange.
    Queue,
    /// Lose it: a live signal that means nothing once late.
    Drop,
    /// Park it without encrypting it now: an Olm frame held back because the save of
    /// the session that encrypted it did not land. A live signal is lost instead.
    Park,
}

/// How long the sealing stage waits for the session save an Olm frame needs before it
/// keeps the frame back.
pub(crate) const SAVE_WAIT: std::time::Duration = std::time::Duration::from_secs(10);

/// Saves asked of the node for one MLS frame before the frame is given up.
const MLS_SAVE_TRIES: usize = 3;

/// How long one MLS frame waits for its group state to land, every save and ask
/// together: a disk that never answers holds the sealing stage no longer than this.
const MLS_SAVE_PATIENCE: std::time::Duration = std::time::Duration::from_secs(60);

/// What the sealing stage knows of the MLS saves, so the copies of one ciphertext (the
/// room frame, its offline pushes) and every frame a landed save covers wait once.
pub(crate) struct MlsReleases {
    /// The newest take a landed save holds: the state of every frame encrypted before
    /// it is on disk, as group state only ever moves forward.
    landed: u64,
    /// The take of the last frame given up, so its copies follow it at once.
    given_up: Option<u64>,
    patience: std::time::Duration,
}

impl Default for MlsReleases {
    fn default() -> Self {
        Self { landed: 0, given_up: None, patience: MLS_SAVE_PATIENCE }
    }
}

/// The take of a landed save that holds `saved`'s frame: `saved` itself, or a whole
/// save the node makes after it failed. A save still pending is waited on, never
/// replaced.
async fn mls_save_lands(mut saved: crate::crypto::MlsSaved, node: &super::frame_auth::CarryTx, patience: std::time::Duration) -> Option<u64> {
    let deadline = Instant::now() + patience;
    let mut asks = 0;
    loop {
        match saved.settled(deadline.saturating_duration_since(Instant::now())).await {
            crate::crypto::Saved::Stored => return Some(saved.take()),
            crate::crypto::Saved::Pending => {
                hollow_log!("[HOLLOW-MLS] The save an MLS frame waits on is still not on disk after {patience:?}");
                return None;
            }
            outcome => hollow_log!("[HOLLOW-MLS] The save an MLS frame waits on did not land ({outcome:?}); asking for a whole one"),
        }
        let after = saved.take();
        saved = loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if asks == MLS_SAVE_TRIES || left.is_zero() {
                return None;
            }
            asks += 1;
            let (done_tx, done_rx) = tokio::sync::oneshot::channel();
            if node.send((WsCommand::MlsSaveAgain { after }, done_tx)).is_err() {
                return None;
            }
            match tokio::time::timeout(SAVE_WAIT.min(left), done_rx).await {
                Ok(Ok(answer)) => match answer.into_iter().next() {
                    Some(WsCommand::AfterMlsSave { saved: again, .. }) => break again,
                    _ => return None,
                },
                Ok(Err(_)) => return None,
                // A late answer costs one try; its save, if made, is what the next ask gets.
                Err(_) => hollow_log!("[HOLLOW-MLS] The node did not answer an MLS save ask in time"),
            }
        };
    }
}

/// What the sealing stage sends for `cmd`: a [`WsCommand::AfterSave`] frame once its
/// session save is on disk, nothing when the save failed, was refused or did not land
/// within [`SAVE_WAIT`], in which case its plaintext goes back to the node through
/// `node`, to wait in the resend queue. A [`WsCommand::AfterMlsSave`] frame goes once
/// its save, or a later one, landed; it is lost only when [`MLS_SAVE_TRIES`] whole
/// saves asked after it did not land either, or nothing landed within
/// [`MLS_SAVE_PATIENCE`], and then the channel's sync serves its message. Anything else
/// passes unchanged.
pub(crate) async fn released(cmd: WsCommand, node: &super::frame_auth::CarryTx, mls: &mut MlsReleases) -> Option<WsCommand> {
    if let WsCommand::AfterMlsSave { saved, frame } = cmd {
        let take = saved.take();
        let landed = if take <= mls.landed {
            true
        } else if mls.given_up == Some(take) {
            false
        } else if let Some(landed) = mls_save_lands(saved, node, mls.patience).await {
            mls.landed = mls.landed.max(landed);
            true
        } else {
            mls.given_up = Some(take);
            false
        };
        if !landed {
            hollow_log!("[HOLLOW-SECURITY] Kept back an MLS frame: no save of its group state landed");
        }
        return landed.then_some(*frame);
    }
    let WsCommand::AfterSave { saved, frame, device, plaintext } = cmd else {
        return Some(cmd);
    };
    match saved.settled(SAVE_WAIT).await {
        crate::crypto::Saved::Stored => Some(*frame),
        outcome => {
            hollow_log!("[HOLLOW-SECURITY] Kept back an Olm frame to {device}: its session save did not land ({outcome:?})");
            let park = WsCommand::Carry { device, room: None, json: plaintext, no_session: NoSession::Park, ticket: None };
            let (done_tx, done_rx) = tokio::sync::oneshot::channel();
            if node.send((park, done_tx)).is_ok() {
                let _ = tokio::time::timeout(SAVE_WAIT, done_rx).await;
            }
            None
        }
    }
}

/// Carry `msg` to one DEVICE from anywhere that holds the relay sender; the node
/// encrypts it on its next turn (see [`OlmLane::deliver`]). `room` pins the relay
/// room, so a device that is offline gets the frame from the relay's buffer when it
/// next joins it; `None` takes the first room we share with the device.
pub(crate) fn carry(ws_cmd_tx: &WsCmdTx, device: &str, room: Option<&str>, msg: &HavenMessage, no_session: NoSession) {
    if let Some(json) = carried_json(msg) {
        carry_json(ws_cmd_tx, device, room, json, no_session);
    }
}

/// [`carry`] for an envelope already built with [`carried_json`].
pub(crate) fn carry_json(ws_cmd_tx: &WsCmdTx, device: &str, room: Option<&str>, json: String, no_session: NoSession) {
    let ticket = WAITING.try_with(|waiting| waiting.borrow_mut().enter(device, &json)).ok();
    let _ = ws_cmd_tx.send(WsCommand::Carry {
        device: device.to_string(),
        room: room.map(str::to_string),
        json,
        no_session,
        ticket,
    });
}

/// Carry `msg` to every online device of our own identity except this one.
/// Returns how many there were.
pub(crate) fn carry_to_own_siblings(
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    local_master: &str,
    local_device: &str,
    msg: &HavenMessage,
    no_session: NoSession,
) -> usize {
    let Some(json) = carried_json(msg) else { return 0 };
    let siblings: Vec<String> = super::crypto_handler::online_devices_for(ws_room_peers, local_master)
        .into_iter()
        .filter(|d| d != local_device && super::resolver::is_own_unrevoked_device(d, local_master))
        .collect();
    for device in &siblings {
        carry_json(ws_cmd_tx, device, None, json.clone(), no_session);
    }
    siblings.len()
}

/// [`carry_to_own_siblings`], plus every other device our roster counts through our own
/// inbox: one the relay hides (a phone put away) is in no presence list but still takes
/// frames, and an offline one gets it from the relay's buffer. One copy per device.
pub(crate) fn carry_to_every_own_device(
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    local_master: &str,
    local_device: &str,
    msg: &HavenMessage,
) -> usize {
    let Some(json) = carried_json(msg) else { return 0 };
    let present = super::crypto_handler::online_devices_for(ws_room_peers, local_master);
    let own_inbox = format!("inbox:{local_master}");
    let mut sent = 0;
    for device in &present {
        if device != local_device && super::resolver::is_own_unrevoked_device(device, local_master) {
            carry_json(ws_cmd_tx, device, None, json.clone(), NoSession::Queue);
            sent += 1;
        }
    }
    for device in super::resolver::devices_for(local_master) {
        if device != local_device && !present.contains(&device) && !super::resolver::is_revoked(&device) {
            carry_json(ws_cmd_tx, &device, Some(&own_inbox), json.clone(), NoSession::Queue);
            sent += 1;
        }
    }
    sent
}

/// Carry an envelope to every online device of one identity (a master or a device
/// id), the Olm counterpart of `send_raw_to_identity`. Returns how many there were.
pub(crate) fn carry_to_identity(
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    identity: &str,
    json: &str,
    no_session: NoSession,
) -> usize {
    let mut devices = super::crypto_handler::online_devices_for(ws_room_peers, identity);
    if devices.is_empty() && super::crypto_handler::ws_room_for_peer(ws_room_peers, identity).is_some() {
        devices.push(identity.to_string());
    }
    for device in &devices {
        carry_json(ws_cmd_tx, device, None, json.to_string(), no_session);
    }
    devices.len()
}

/// [`carry_to_identity`] for each of `identities` except our own.
pub(crate) fn carry_to_identities<'i>(
    ws_cmd_tx: &WsCmdTx,
    ws_room_peers: &WsRoomPeers,
    identities: impl IntoIterator<Item = &'i String>,
    local_master: &str,
    json: &str,
    no_session: NoSession,
) {
    for identity in identities {
        if !super::resolver::same_identity(identity, local_master) {
            carry_to_identity(ws_cmd_tx, ws_room_peers, identity, json, no_session);
        }
    }
}

/// `msg` wrapped for the Olm lane, serialized once for a fan-out.
pub(crate) fn carried_json(msg: &HavenMessage) -> Option<String> {
    debug_assert_eq!(msg.lane(), Lane::Carried, "only a Carried-lane message rides the Olm lane");
    serde_json::to_string(&MessageEnvelope::Carried {
        msg: Box::new(msg.clone()),
        at_ms: super::frame_auth::now_ms(),
    })
    .ok()
}

/// Most envelopes parked for one device: a device that never answers a key exchange
/// must not grow the queue forever.
const QUEUE_CAP: usize = 256;

tokio::task_local! {
    /// The node's carried frames that hold a wire slot and have not been delivered.
    static WAITING: RefCell<Waiting>;
}

/// Most waiting carried frames a node tracks; past it the oldest is encrypted when
/// it is reached, unordered against direct sends.
const WAITING_CAP: usize = 4096;

#[derive(Default)]
struct Waiting {
    next_ticket: u64,
    carries: VecDeque<WaitingCarry>,
}

/// A carried frame between its queueing and its delivery, with its ciphertext once a
/// direct send to the same device had to encrypt it first.
struct WaitingCarry {
    ticket: u64,
    device: String,
    json: String,
    sealed: Option<(usize, Vec<u8>)>,
}

impl Waiting {
    fn enter(&mut self, device: &str, json: &str) -> u64 {
        if self.carries.len() >= WAITING_CAP {
            self.carries.pop_front();
        }
        let ticket = self.next_ticket;
        self.next_ticket += 1;
        self.carries.push_back(WaitingCarry { ticket, device: device.to_string(), json: json.to_string(), sealed: None });
        ticket
    }

    fn take(&mut self, ticket: u64) -> Option<WaitingCarry> {
        let at = self.carries.iter().position(|c| c.ticket == ticket)?;
        self.carries.remove(at)
    }
}

/// Run a node loop with its own book of waiting carried frames ([`encrypt_in_turn`]).
pub(crate) fn with_carry_book<F: std::future::Future>(loop_: F) -> impl std::future::Future<Output = F::Output> {
    WAITING.scope(RefCell::new(Waiting::default()), loop_)
}

/// Olm-encrypt a direct frame to `device` after the carried frames queued for it
/// before it. Those go out first, and a receiver keeps only 40 message keys for
/// frames that arrive behind later ones, so the ratchet must follow the wire.
pub(crate) fn encrypt_in_turn(olm: &mut OlmManager, device: &str, plaintext: &[u8]) -> Result<(usize, Vec<u8>), String> {
    let _ = WAITING.try_with(|waiting| {
        for carry in waiting.borrow_mut().carries.iter_mut().filter(|c| c.device == device && c.sealed.is_none()) {
            match olm.encrypt(device, carry.json.as_bytes()) {
                Ok(sealed) => carry.sealed = Some(sealed),
                Err(_) => break,
            }
        }
    });
    olm.encrypt(device, plaintext)
}

/// Devices whose node leaves its waiting carried frames alone, as a busy event loop does.
#[cfg(test)]
static HELD_LANES: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// TEST-ONLY: stop or restart the node of `device` taking carried frames.
#[cfg(test)]
pub(crate) fn hold_carry_lane(device: &str, held: bool) {
    let mut lanes = HELD_LANES.lock().unwrap_or_else(|e| e.into_inner());
    lanes.retain(|d| d != device);
    if held {
        lanes.push(device.to_string());
    }
}

/// Whether the node of `device` takes its next carried frame now; always, outside tests.
pub(crate) fn carry_lane_open(device: &str) -> bool {
    #[cfg(test)]
    {
        !HELD_LANES.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|d| d == device)
    }
    #[cfg(not(test))]
    {
        let _ = device;
        true
    }
}

/// The event loop's half: the state one [`WsCommand::Carry`](super::ws_client::WsCommand::Carry)
/// needs, borrowed for one delivery.
pub(crate) struct OlmLane<'a> {
    olm: &'a mut OlmManager,
    crypto_store: &'a CryptoStore,
    ws_room_peers: &'a WsRoomPeers,
    pending_messages: &'a mut HashMap<String, Vec<String>>,
    key_request_in_flight: &'a mut HashMap<String, Instant>,
    device_keypair: &'a NativeKeypair,
    device_peer_id: &'a str,
}

impl<'a> OlmLane<'a> {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        olm: &'a mut OlmManager,
        crypto_store: &'a CryptoStore,
        ws_room_peers: &'a WsRoomPeers,
        pending_messages: &'a mut HashMap<String, Vec<String>>,
        key_request_in_flight: &'a mut HashMap<String, Instant>,
        device_keypair: &'a NativeKeypair,
        device_peer_id: &'a str,
    ) -> Self {
        Self { olm, crypto_store, ws_room_peers, pending_messages, key_request_in_flight, device_keypair, device_peer_id }
    }

    /// Encrypt one carried envelope to `device` and return the frames to send in its
    /// place. A device in no room we share, with no `room` pinned, is treated like one
    /// without a session.
    pub(crate) fn deliver(&mut self, device: &str, room: Option<&str>, json: &str, no_session: NoSession, ticket: Option<u64>) -> Vec<WsCommand> {
        if no_session == NoSession::Park {
            let live = serde_json::from_str::<MessageEnvelope>(json).is_ok_and(|env| env.live_only());
            if !live && !self.pending_messages.get(device).is_some_and(|queue| queue.iter().any(|q| q == json)) {
                self.park(device, json);
            }
            return Vec::new();
        }
        // A direct send queued behind this carry may have encrypted it already.
        let sealed = ticket
            .and_then(|ticket| WAITING.try_with(|waiting| waiting.borrow_mut().take(ticket)).ok().flatten())
            .and_then(|carry| carry.sealed);
        let online = super::crypto_handler::send_room_for_peer(self.ws_room_peers, device);
        let room = room.map(str::to_string).or(online.clone());
        if self.olm.has_session(device)
            && let Some(room) = room
        {
            match sealed.map_or_else(|| self.olm.encrypt(device, json.as_bytes()), Ok) {
                Ok((msg_type, ciphertext)) => {
                    let frame = super::crypto_handler::olm_frame(self.olm, self.crypto_store, device, msg_type, &ciphertext, json);
                    return vec![frame.direct(room)];
                }
                Err(e) => hollow_log!("[HOLLOW-CRYPTO] Olm lane encrypt to {device} failed: {e}"),
            }
        }
        if no_session == NoSession::Drop {
            return Vec::new();
        }
        self.park(device, json);
        let fresh = self
            .key_request_in_flight
            .get(device)
            .is_some_and(|t| t.elapsed() < std::time::Duration::from_secs(10));
        match online {
            Some(room) if !fresh && !self.olm.has_session(device) => {
                self.key_request_in_flight.insert(device.to_string(), Instant::now());
                let request = super::crypto_handler::signed_key_request(self.device_keypair, self.device_peer_id, device);
                vec![WsCommand::SendDirect {
                    room_code: room,
                    target_peer: device.to_string(),
                    data: serde_json::to_vec(&request).unwrap_or_default(),
                }]
            }
            _ => Vec::new(),
        }
    }

    fn park(&mut self, device: &str, json: &str) {
        let queue = self.pending_messages.entry(device.to_string()).or_default();
        queue.push(json.to_string());
        if queue.len() > QUEUE_CAP {
            queue.remove(0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Alice and Bob with a session both have read on.
    fn established() -> (OlmManager, OlmManager) {
        let (mut alice, mut bob) = (OlmManager::new(), OlmManager::new());
        let key = bob.generate_one_time_key();
        alice.create_outbound_session("bob", &bob.identity_key_base64(), &key).unwrap();
        let (_, hello) = alice.encrypt("bob", b"hello").unwrap();
        bob.open_prekey("alice", &alice.identity_key_base64(), &hello, "bob").unwrap();
        let (kind, reply) = bob.encrypt("alice", b"reply").unwrap();
        alice.decrypt("bob", kind, &reply).unwrap();
        (alice, bob)
    }

    #[tokio::test]
    async fn a_direct_burst_encrypts_the_carries_queued_before_it_first() {
        with_carry_book(async {
            let (mut alice, mut bob) = established();
            let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
            carry_json(&tx, "bob", None, "carried".to_string(), NoSession::Queue);
            carry_json(&tx, "carol", None, "for carol".to_string(), NoSession::Queue);
            let Ok(WsCommand::Carry { ticket: Some(ticket), .. }) = rx.try_recv() else {
                panic!("a carry queued in the node loop holds a ticket");
            };

            let burst: Vec<_> = (0..60).map(|i| encrypt_in_turn(&mut alice, "bob", format!("d{i}").as_bytes()).unwrap()).collect();
            let carried = WAITING.with(|waiting| waiting.borrow_mut().take(ticket)).and_then(|carry| carry.sealed);
            let carried = carried.expect("the carried frame was encrypted before the burst");
            assert!(
                WAITING.with(|waiting| waiting.borrow().carries.iter().all(|carry| carry.sealed.is_none())),
                "another device's carry waits for its own turn"
            );

            // Bob reads them in wire order: the carried frame, then the burst.
            for (i, (kind, ciphertext)) in std::iter::once(carried).chain(burst).enumerate() {
                assert!(bob.decrypt("alice", kind, &ciphertext).is_ok(), "frame {i} on the wire did not decrypt");
            }
        })
        .await;
    }

    /// Devices a sibling carry went to, in order.
    fn carried_devices(rx: &mut tokio::sync::mpsc::UnboundedReceiver<WsCommand>) -> Vec<String> {
        let mut out = Vec::new();
        while let Ok(cmd) = rx.try_recv() {
            if let WsCommand::Carry { device, .. } = cmd {
                out.push(device);
            }
        }
        out.sort();
        out
    }

    /// A device the roster removed hears nothing meant for our own devices, even with
    /// its link kept, and neither does the bare master in a room. Each fan-out alone.
    #[test]
    fn a_removed_device_hears_no_sibling_share() {
        let _g = crate::node::resolver::test_lock();
        crate::node::resolver::clear_for_test();
        let (master, us, sib, gone) = ("m-master", "m-us", "m-sib", "m-gone");
        crate::node::resolver::seed_self(master, &[us.into(), sib.into(), gone.into()]);
        crate::node::resolver::mark_revoked(&[gone.to_string()]);
        crate::node::resolver::seed_self(master, &[gone.into()]);
        crate::node::resolver::note_roster(master);
        let peers: WsRoomPeers = [("inbox:m-master".to_string(), [us, sib, gone, master].iter().map(|s| s.to_string()).collect())].into();
        let msg = HavenMessage::FriendListRequest;
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        carry_to_own_siblings(&tx, &peers, master, us, &msg, NoSession::Queue);
        assert_eq!(carried_devices(&mut rx), vec![sib.to_string()], "carry_to_own_siblings reached a device that is not ours");
        carry_to_every_own_device(&tx, &peers, master, us, &msg);
        assert_eq!(carried_devices(&mut rx), vec![sib.to_string()], "carry_to_every_own_device reached a device that is not ours");
        crate::node::resolver::clear_for_test();
    }

    fn after_mls_save(saved: crate::crypto::MlsSaved) -> WsCommand {
        WsCommand::AfterMlsSave { saved, frame: Box::new(WsCommand::SendToRoom { room_code: "r".into(), data: b"mls".to_vec() }) }
    }

    /// The node side of an MLS save ask: answers each with `outcome` of the ask's
    /// `after`, counts the asks.
    pub(super) fn answer_save_asks(
        mut asks: tokio::sync::mpsc::UnboundedReceiver<super::super::frame_auth::CarryRequest>,
        outcome: impl Fn(u64) -> crate::crypto::MlsSaved + Send + 'static,
    ) -> std::sync::Arc<std::sync::atomic::AtomicUsize> {
        let count = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let seen = count.clone();
        tokio::spawn(async move {
            while let Some((ask, done)) = asks.recv().await {
                let WsCommand::MlsSaveAgain { after } = ask else { panic!("{ask:?}") };
                seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let _ = done.send(vec![after_mls_save(outcome(after))]);
            }
        });
        count
    }

    /// An MLS frame whose save did not land is never dropped while a later save can
    /// land: the node saves again and the frame goes once that one is on disk. Copies of
    /// one ciphertext wait on its save once.
    #[tokio::test]
    async fn an_mls_frame_goes_once_a_save_lands_and_its_copies_follow() {
        let (node, asks) = tokio::sync::mpsc::unbounded_channel();
        let count = answer_save_asks(asks, |after| crate::crypto::MlsSaved::stored_for_test(after + 1));
        let mut memo = MlsReleases::default();
        let failed = crate::crypto::MlsSaved::failed(1);
        let sent = released(after_mls_save(failed.clone()), &node, &mut memo).await;
        assert!(matches!(sent, Some(WsCommand::SendToRoom { .. })), "a frame whose first save failed was dropped: {sent:?}");
        assert_eq!(count.load(std::sync::atomic::Ordering::SeqCst), 1);
        let copy = released(after_mls_save(failed), &node, &mut memo).await;
        assert!(copy.is_some(), "a copy of a released frame was kept back");
        assert_eq!(count.load(std::sync::atomic::Ordering::SeqCst), 1, "a copy asked for its own save");
    }

    /// When no save lands at all, the frame and every copy of it stay back.
    #[tokio::test]
    async fn an_mls_frame_no_save_covers_stays_back_with_its_copies() {
        let (node, asks) = tokio::sync::mpsc::unbounded_channel();
        let count = answer_save_asks(asks, |after| crate::crypto::MlsSaved::failed(after + 1));
        let mut memo = MlsReleases::default();
        let failed = crate::crypto::MlsSaved::failed(1);
        assert!(released(after_mls_save(failed.clone()), &node, &mut memo).await.is_none());
        assert_eq!(count.load(std::sync::atomic::Ordering::SeqCst), MLS_SAVE_TRIES);
        assert!(released(after_mls_save(failed), &node, &mut memo).await.is_none(), "a copy left without its save");
        assert_eq!(count.load(std::sync::atomic::Ordering::SeqCst), MLS_SAVE_TRIES);
        let fresh = released(after_mls_save(crate::crypto::MlsSaved::stored_for_test(10)), &node, &mut memo).await;
        assert!(fresh.is_some(), "a later frame with its own landed save stayed back");
    }

    fn after_save(saved: crate::crypto::SessionSaved, plaintext: &str) -> WsCommand {
        WsCommand::AfterSave {
            saved,
            frame: Box::new(WsCommand::SendDirect { room_code: "r".into(), target_peer: "bob".into(), data: b"olm".to_vec() }),
            device: "bob".into(),
            plaintext: plaintext.into(),
        }
    }

    /// AR-30: the sealing stage sends an Olm frame only once its session save landed,
    /// and hands one whose save did not land back to the node, never to the relay.
    #[tokio::test]
    async fn a_frame_goes_out_only_on_a_landed_save_and_is_handed_back_otherwise() {
        let (node, mut asks) = tokio::sync::mpsc::unbounded_channel();
        let sent = released(after_save(crate::crypto::SessionSaved::stored_for_test(), "{}"), &node, &mut MlsReleases::default()).await;
        assert!(matches!(sent, Some(WsCommand::SendDirect { .. })), "a saved frame must go: {sent:?}");
        let plain = WsCommand::JoinRoom { room_code: "r".into() };
        assert!(matches!(released(plain, &node, &mut MlsReleases::default()).await, Some(WsCommand::JoinRoom { .. })));
        assert!(asks.try_recv().is_err());

        let kept = tokio::spawn(async move { released(after_save(crate::crypto::SessionSaved::failed(), "the plaintext"), &node, &mut MlsReleases::default()).await });
        let (park, done) = asks.recv().await.expect("the node is asked to keep it");
        assert!(
            matches!(&park, WsCommand::Carry { device, json, no_session: NoSession::Park, ticket: None, .. } if device == "bob" && json == "the plaintext"),
            "{park:?}"
        );
        done.send(Vec::new()).unwrap();
        assert!(kept.await.unwrap().is_none(), "a frame whose save failed went to the relay");
    }

    /// What the node keeps of a frame held back: a durable message waits in the resend
    /// queue, once; a live signal, meaningless when late, is lost.
    #[tokio::test]
    async fn a_held_back_frame_waits_in_the_resend_queue_unless_it_is_live() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("lane.db").to_string_lossy().into_owned();
        let store = CryptoStore::open(path, "6c".repeat(32)).unwrap();
        let (mut alice, _bob) = established();
        let keypair = NativeKeypair::from_secret_bytes(&[9; 32]);
        let (rooms, mut pending, mut asked) = (WsRoomPeers::new(), HashMap::new(), HashMap::new());
        let durable = serde_json::to_string(&MessageEnvelope::SessionAck).unwrap();
        let live = serde_json::to_string(&MessageEnvelope::Typing { sid: "s".into(), cid: "c".into() }).unwrap();
        let mut lane = OlmLane::new(&mut alice, &store, &rooms, &mut pending, &mut asked, &keypair, "alice");
        for json in [&durable, &durable, &live] {
            assert!(lane.deliver("bob", None, json, NoSession::Park, None).is_empty(), "a held-back frame is never re-sent at once");
        }
        assert_eq!(pending.get("bob"), Some(&vec![durable]), "kept once, the live signal dropped");
    }

    /// Node code reaches Olm only through [`encrypt_in_turn`], so no direct frame takes
    /// a ratchet step ahead of a carry queued before it.
    #[test]
    fn node_code_encrypts_olm_only_in_turn() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/node");
        let mut offenders = Vec::new();
        for entry in std::fs::read_dir(&dir).expect("read src/node") {
            let path = entry.expect("dir entry").path();
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
            if !name.ends_with(".rs") || name == "olm_lane.rs" || name == "test_harness.rs" {
                continue;
            }
            let source = std::fs::read_to_string(&path).expect("read source").replace("\r\n", "\n");
            let code = source.split("\n#[cfg(test)]\nmod tests").next().unwrap_or_default();
            let code: String = code
                .lines()
                .filter(|line| !line.trim_start().starts_with("//"))
                .flat_map(|line| line.chars().filter(|c| !c.is_whitespace()))
                .collect();
            if code.contains("olm.encrypt(") {
                offenders.push(name);
            }
        }
        assert!(offenders.is_empty(), "Olm encrypt outside olm_lane::encrypt_in_turn in {offenders:?}");
    }

    /// AR-30: node code builds an Olm frame only through `crypto_handler::olm_frame`,
    /// which binds it to its session save, so no frame reaches the sealing stage
    /// without one to wait for.
    #[test]
    fn node_code_builds_olm_frames_only_bound_to_their_save() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/node");
        let mut uses = Vec::new();
        for entry in std::fs::read_dir(&dir).expect("read src/node") {
            let path = entry.expect("dir entry").path();
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
            if !name.ends_with(".rs") || name == "test_harness.rs" {
                continue;
            }
            let source = std::fs::read_to_string(&path).expect("read source").replace("\r\n", "\n");
            let code = source.split("\n#[cfg(test)]\nmod tests").next().unwrap_or_default();
            for line in code.lines().filter(|l| !l.trim_start().starts_with("//")) {
                if line.contains("encrypted_frame(") {
                    uses.push(format!("{name}: {}", line.trim()));
                }
            }
            // A frame built by hand skips the save; the receive arms only match one.
            let built = code.matches("HavenMessage::Encrypted {").count();
            let receive_arms = ["swarm.rs", "fetch.rs"].contains(&name.as_str()) as usize;
            let own = (name == "crypto_handler.rs") as usize;
            assert_eq!(built, receive_arms + own, "{name} builds an Olm frame of its own");
        }
        let expected = [
            "crypto_handler.rs: pub(crate) fn encrypted_frame(olm: &OlmManager, message_type: usize, ciphertext: &[u8]) -> HavenMessage {",
            "crypto_handler.rs: data: serde_json::to_vec(&encrypted_frame(olm, message_type, ciphertext)).unwrap_or_default(),",
        ];
        assert_eq!(uses, expected, "an Olm frame built outside crypto_handler::olm_frame");
    }
}

/// The sealer's MLS save retries: one failure, one whole save.
#[cfg(test)]
mod g13_mls_save_retry {
    use super::*;
    use crate::crypto::{MlsSaved, Saved};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};

    const SOON: std::time::Duration = std::time::Duration::from_secs(10);

    struct Disk {
        _tmp: crate::test_tmp::TestDir,
        path: String,
        pass: String,
    }

    impl Disk {
        fn new() -> Self {
            let tmp = crate::test_tmp::tempdir().unwrap();
            let path = tmp.path().join("m.db").to_string_lossy().into_owned();
            let pass = "ab".repeat(32);
            crate::storage::MessageStore::open(&path, &pass).unwrap();
            Disk { _tmp: tmp, path, pass }
        }

        fn sql(&self, sql: &str) {
            crate::storage::MessageStore::open(&self.path, &self.pass).unwrap().conn_execute_for_test(sql);
        }

        /// Every MLS save from now on fails at the disk.
        fn refuse_mls(&self) {
            self.sql("CREATE TRIGGER mls_down BEFORE INSERT ON mls_identity BEGIN SELECT RAISE(ABORT, 'down'); END;");
        }

        fn accept_mls(&self) {
            self.sql("DROP TRIGGER IF EXISTS mls_down;");
        }

        /// The MLS rows a restart would load.
        fn stored_state(&self) -> Vec<(String, Vec<u8>, Vec<u8>)> {
            let mut rows = crate::storage::MessageStore::open(&self.path, &self.pass).unwrap().load_mls_rows().unwrap();
            rows.sort();
            rows
        }

        /// Accepts MLS saves again when called, from anywhere.
        fn healer(&self) -> impl Fn() + Send + 'static {
            let (path, pass) = (self.path.clone(), self.pass.clone());
            move || crate::storage::MessageStore::open(&path, &pass).unwrap().conn_execute_for_test("DROP TRIGGER IF EXISTS mls_down;")
        }
    }

    /// Every row of the live group state, as a whole save would write it.
    fn live_state(mls: &Shared) -> Vec<(String, Vec<u8>, Vec<u8>)> {
        let save = mls.lock().unwrap().take_whole_save().unwrap();
        let mut rows: Vec<_> = save.rows.into_iter().filter_map(|(scope, k, v)| Some((scope, k, v?))).collect();
        rows.sort();
        rows
    }

    type Shared = Arc<Mutex<crate::crypto::MlsManager>>;

    /// The node's half of a save ask, as swarm.rs answers it; counts the asks. `before`
    /// runs ahead of each answer with the ask's number, from 1.
    fn node_answers(
        mut asks: tokio::sync::mpsc::UnboundedReceiver<super::super::frame_auth::CarryRequest>,
        mls: Shared,
        store: Arc<CryptoStore>,
        before: impl Fn(usize) + Send + 'static,
    ) -> Arc<AtomicUsize> {
        let count = Arc::new(AtomicUsize::new(0));
        let seen = count.clone();
        tokio::spawn(async move {
            while let Some((ask, done)) = asks.recv().await {
                let WsCommand::MlsSaveAgain { after } = ask else { panic!("{ask:?}") };
                before(seen.fetch_add(1, Ordering::SeqCst) + 1);
                let saved = super::super::crypto_handler::mls_save_again(&mls.lock().unwrap(), &store, after);
                let _ = done.send(vec![WsCommand::AfterMlsSave { saved, frame: Box::new(WsCommand::MlsSaveAgain { after }) }]);
            }
        });
        count
    }

    fn frame(saved: MlsSaved, i: usize) -> WsCommand {
        WsCommand::AfterMlsSave { saved, frame: Box::new(WsCommand::SendToRoom { room_code: "srv".into(), data: vec![i as u8] }) }
    }

    /// An encrypt and the save the frame it made waits on.
    fn encrypt(mls: &Shared, store: &CryptoStore) -> MlsSaved {
        let mut mgr = mls.lock().unwrap();
        mgr.encrypt("srv", b"post").unwrap();
        super::super::crypto_handler::persist_mls_state_awaited(&mgr, store)
    }

    async fn setup() -> (Disk, Shared, Arc<CryptoStore>) {
        let disk = Disk::new();
        let store = Arc::new(CryptoStore::open(disk.path.clone(), disk.pass.clone()).unwrap());
        let (mut mls, _) = crate::crypto::mls_manager_test_keys::bound(1, 2);
        mls.create_group("srv").unwrap();
        let mls = Arc::new(Mutex::new(mls));
        assert_eq!(super::super::crypto_handler::persist_mls_state_awaited(&mls.lock().unwrap(), &store).settled(SOON).await, Saved::Stored);
        (disk, mls, store)
    }

    /// Five frames whose saves all failed at the disk.
    async fn failed_burst(disk: &Disk, mls: &Shared, store: &CryptoStore) -> Vec<MlsSaved> {
        disk.refuse_mls();
        let saves: Vec<_> = (0..5).map(|_| encrypt(mls, store)).collect();
        for saved in &saves {
            assert_eq!(saved.settled(SOON).await, Saved::Failed);
        }
        saves
    }

    fn sent(out: &Option<WsCommand>, i: usize) -> bool {
        matches!(out, Some(WsCommand::SendToRoom { data, .. }) if data == &[i as u8])
    }

    /// A burst of frames after one failed save costs one whole save, every frame goes
    /// in order, and what went is what a restart loads.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_burst_after_one_failed_save_asks_for_one_whole_save() {
        let (disk, mls, store) = setup().await;
        let saves = failed_burst(&disk, &mls, &store).await;
        disk.accept_mls();
        let wholes = store.whole_saves_for_test();
        let live = live_state(&mls);
        let (node, asks) = tokio::sync::mpsc::unbounded_channel();
        let count = node_answers(asks, mls.clone(), store.clone(), |_| {});
        let mut memo = MlsReleases::default();
        for (i, saved) in saves.into_iter().enumerate() {
            let out = released(frame(saved, i), &node, &mut memo).await;
            assert!(sent(&out, i), "frame {i}: {out:?}");
        }
        assert_eq!(count.load(Ordering::SeqCst), 1, "a burst behind one failed save asked for a whole save per frame");
        assert_eq!(store.whole_saves_for_test() - wholes, 1);
        assert_eq!(disk.stored_state(), live, "a frame went before the state that encrypted it was on disk");
    }

    /// Each further failure costs one more whole save, never one per frame.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_failed_whole_save_costs_one_more() {
        let (disk, mls, store) = setup().await;
        let saves = failed_burst(&disk, &mls, &store).await;
        let wholes = store.whole_saves_for_test();
        let live = live_state(&mls);
        let (node, asks) = tokio::sync::mpsc::unbounded_channel();
        let heal = disk.healer();
        let count = node_answers(asks, mls.clone(), store.clone(), move |n| if n == 2 { heal() });
        let mut memo = MlsReleases::default();
        for (i, saved) in saves.into_iter().enumerate() {
            let out = released(frame(saved, i), &node, &mut memo).await;
            assert!(sent(&out, i), "frame {i}: {out:?}");
        }
        assert_eq!(count.load(Ordering::SeqCst), 2);
        assert_eq!(store.whole_saves_for_test() - wholes, 2, "one whole save per failure");
        assert_eq!(disk.stored_state(), live);
    }

    /// A whole save the node already queued after the failure is the one waited on.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_whole_save_queued_since_the_failure_is_reused() {
        let (disk, mls, store) = setup().await;
        let saves = failed_burst(&disk, &mls, &store).await;
        disk.accept_mls();
        // The next encrypt after a failure takes a whole save on its own.
        let wholes = store.whole_saves_for_test();
        let later = encrypt(&mls, &store);
        assert_eq!(store.whole_saves_for_test() - wholes, 1);
        let (node, asks) = tokio::sync::mpsc::unbounded_channel();
        let count = node_answers(asks, mls.clone(), store.clone(), |_| {});
        let mut memo = MlsReleases::default();
        for (i, saved) in saves.into_iter().chain([later]).enumerate() {
            let out = released(frame(saved, i), &node, &mut memo).await;
            assert!(sent(&out, i), "frame {i}: {out:?}");
        }
        assert_eq!(count.load(Ordering::SeqCst), 1);
        assert_eq!(store.whole_saves_for_test() - wholes, 1, "a second whole save was taken behind the first");
    }

    /// A disk that keeps failing gives a frame up after its tries, and its copies with it.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_disk_that_keeps_failing_gives_the_frame_up() {
        let (disk, mls, store) = setup().await;
        let mut saves = failed_burst(&disk, &mls, &store).await;
        let wholes = store.whole_saves_for_test();
        let (node, asks) = tokio::sync::mpsc::unbounded_channel();
        let count = node_answers(asks, mls.clone(), store.clone(), |_| {});
        let mut memo = MlsReleases::default();
        let first = saves.remove(0);
        assert!(released(frame(first.clone(), 0), &node, &mut memo).await.is_none(), "a frame went with no save of it on disk");
        assert_eq!(count.load(Ordering::SeqCst), MLS_SAVE_TRIES);
        assert_eq!(store.whole_saves_for_test() - wholes, MLS_SAVE_TRIES);
        assert!(released(frame(first, 0), &node, &mut memo).await.is_none(), "a copy went without its save");
        assert_eq!(count.load(Ordering::SeqCst), MLS_SAVE_TRIES, "a copy asked again");
        // The next frame tries again on its own, and never waits on a whole save that failed.
        assert!(released(frame(saves.remove(0), 1), &node, &mut memo).await.is_none());
        assert_eq!(store.whole_saves_for_test() - wholes, 2 * MLS_SAVE_TRIES, "a failed whole save was waited on again");
    }

    /// A save that is only slow is waited on, never answered with a whole save.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_slow_save_is_waited_on_without_asking_again() {
        let (disk, mls, store) = setup().await;
        crate::crypto::held_saves::hold_mls(&disk.path);
        let saved = encrypt(&mls, &store);
        let (node, asks) = tokio::sync::mpsc::unbounded_channel();
        let count = node_answers(asks, mls.clone(), store.clone(), |_| {});
        let sealer = tokio::spawn(async move { released(frame(saved, 0), &node, &mut MlsReleases::default()).await });
        tokio::time::sleep(SAVE_WAIT + std::time::Duration::from_secs(1)).await;
        assert!(!sealer.is_finished(), "a frame went before its save landed");
        assert_eq!(count.load(Ordering::SeqCst), 0, "a slow save was answered with a whole save");
        crate::crypto::held_saves::release(&disk.path, &disk.pass);
        assert!(sealer.await.unwrap().is_some(), "the frame stayed back once its save landed");
        assert_eq!(count.load(Ordering::SeqCst), 0);
    }

    /// A disk that never answers holds the sealer only for its patience.
    #[tokio::test]
    async fn a_save_that_never_settles_holds_the_sealer_for_its_patience() {
        let (node, asks) = tokio::sync::mpsc::unbounded_channel();
        let count = super::tests::answer_save_asks(asks, |after| MlsSaved::stored_for_test(after + 1));
        let (_hung, saved) = MlsSaved::pending_for_test(1);
        let mut memo = MlsReleases { patience: std::time::Duration::from_millis(300), ..Default::default() };
        let out = tokio::time::timeout(SOON, released(frame(saved, 0), &node, &mut memo)).await.expect("the sealer stayed held");
        assert!(out.is_none(), "a frame went with its save still pending");
        assert_eq!(count.load(Ordering::SeqCst), 0);
    }

    /// A landed save covers only the frames encrypted before it was taken.
    #[tokio::test]
    async fn a_landed_save_covers_only_frames_taken_before_it() {
        let (node, asks) = tokio::sync::mpsc::unbounded_channel();
        let count = super::tests::answer_save_asks(asks, |after| if after < 5 { MlsSaved::stored_for_test(5) } else { MlsSaved::failed(after + 1) });
        let mut memo = MlsReleases::default();
        assert!(sent(&released(frame(MlsSaved::failed(1), 1), &node, &mut memo).await, 1));
        assert!(sent(&released(frame(MlsSaved::failed(3), 3), &node, &mut memo).await, 3), "a frame the landed save covers stayed back");
        assert_eq!(count.load(Ordering::SeqCst), 1, "a covered frame asked again");
        assert!(released(frame(MlsSaved::failed(7), 7), &node, &mut memo).await.is_none(), "a save taken before a frame released it");
        assert_eq!(count.load(Ordering::SeqCst), 1 + MLS_SAVE_TRIES);
    }

    /// An ask the node answers late counts as one try; the next ask still saves the frame.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_late_answer_to_a_save_ask_costs_one_try() {
        let (node, mut asks) = tokio::sync::mpsc::unbounded_channel::<super::super::frame_auth::CarryRequest>();
        let count = Arc::new(AtomicUsize::new(0));
        let seen = count.clone();
        tokio::spawn(async move {
            let mut late = Vec::new();
            while let Some((_, done)) = asks.recv().await {
                if seen.fetch_add(1, Ordering::SeqCst) == 0 {
                    late.push(done);
                } else {
                    let stored = MlsSaved::stored_for_test(2);
                    let _ = done.send(vec![WsCommand::AfterMlsSave { saved: stored, frame: Box::new(WsCommand::MlsSaveAgain { after: 1 }) }]);
                }
            }
        });
        let out = released(frame(MlsSaved::failed(1), 0), &node, &mut MlsReleases::default()).await;
        assert!(out.is_some(), "a late answer gave the frame up with tries left");
        assert_eq!(count.load(Ordering::SeqCst), 2);
    }

    /// Wire order is program order: the offline copy and the Olm twin of an MLS frame,
    /// and whatever follows, wait behind the frame's save and then go in order.
    #[tokio::test]
    async fn frames_behind_an_mls_save_keep_their_order() {
        let keypair = NativeKeypair::from_secret_bytes(&[9; 32]);
        let (relay, mut wire) = tokio::sync::mpsc::unbounded_channel();
        let (sealer, _carry) = super::super::frame_auth::spawn_sealer(keypair, relay);
        let (settle, saved) = MlsSaved::pending_for_test(1);
        sealer.send(frame(saved.clone(), 0)).unwrap();
        let copy = WsCommand::SendChannelDirect { room_code: "srv".into(), target_peer: "x".into(), channel_id: "c".into(), mention: false, data: vec![1] };
        sealer.send(WsCommand::AfterMlsSave { saved, frame: Box::new(copy) }).unwrap();
        sealer.send(WsCommand::AfterSave {
            saved: crate::crypto::SessionSaved::stored_for_test(),
            frame: Box::new(WsCommand::SendDirect { room_code: "dm".into(), target_peer: "x".into(), data: vec![2] }),
            device: "x".into(),
            plaintext: "twin".into(),
        })
        .unwrap();
        sealer.send(WsCommand::SendToRoom { room_code: "srv".into(), data: vec![3] }).unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(wire.try_recv().is_err(), "a frame overtook an MLS frame waiting on its save");
        settle.send(Saved::Stored).unwrap();
        let mut order = Vec::new();
        for _ in 0..4 {
            order.push(match tokio::time::timeout(SOON, wire.recv()).await.unwrap().unwrap() {
                WsCommand::SendToRoom { .. } => "room",
                WsCommand::SendChannelDirect { .. } => "copy",
                WsCommand::SendDirect { .. } => "twin",
                other => panic!("{other:?}"),
            });
        }
        assert_eq!(order, ["room", "copy", "twin", "room"]);
    }
}
