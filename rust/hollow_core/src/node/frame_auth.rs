//! Device-signed relay frames.
//!
//! The relay stamps `from` on everything it forwards, and a malicious relay can stamp
//! any id. So every peer payload travels sealed: the sending DEVICE signs the room, the
//! route, the time and a nonce over the body, and the receiver checks that signature
//! against the key inlined in `from` before anything reads the frame. A seal proves
//! which device sent a frame, never what that device may do: handlers still judge that.

use std::collections::{HashMap, HashSet};

use ed25519_dalek::{Signature, VerifyingKey};
use sha2::{Digest, Sha256};
use tokio::sync::mpsc::UnboundedSender;

use super::ws_client::WsCommand;
use crate::identity::native_identity::NativeKeypair;

/// Leads every sealed frame. A NUL can never start a JSON `HavenMessage`, so an
/// unsealed frame from an older client is told apart without parsing it.
pub(crate) const MAGIC: [u8; 4] = *b"\0HF1";

const DOMAIN: &[u8] = b"hollow-frame1\0";

/// The route of a frame fanned out to a whole room or topic.
pub(crate) const ROUTE_ROOM: &str = "*";

/// How far a live-only frame's clock may sit from ours, either way. Relay auth no
/// longer bounds clocks (issue #72); the app warns a device past 240 s off the relay,
/// before this refuses it.
pub(crate) const LIVE_SKEW_MS: i64 = 300_000;

pub(crate) const NONCE_LEN: usize = 16;
const SIG_LEN: usize = 64;

/// Room for a replay window of live frames at the rate limit's ceiling (two routes,
/// 40 a second): an honest sender whose clock runs at most about 110 s fast never
/// reaches it.
const MAX_SEEN_PER_SENDER: usize = 16_384;

/// How a frame reached us.
#[derive(Clone, Copy)]
pub(crate) enum Delivery<'a> {
    /// Fanned out to a room or topic (relay 0x05, 0x08).
    Room,
    /// Sent to this device (relay 0x06), or to its master's inbox.
    Direct { device: &'a str, master: &'a str },
}

/// A frame whose seal checked out.
#[derive(Debug)]
pub(crate) struct Opened<'a> {
    pub ts_ms: i64,
    pub nonce: [u8; NONCE_LEN],
    pub body: &'a [u8],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Refusal {
    /// No seal: a client older than 0.12, or not a Hollow frame at all.
    Unsealed,
    Malformed,
    /// `from` does not inline an Ed25519 key.
    NotAPeerId,
    BadSignature,
    /// Signed for another room or device, or for a room when it arrived direct.
    Misrouted,
    /// Stamped more than [`LIVE_SKEW_MS`] ahead of our clock.
    FromTheFuture,
}

pub(crate) fn now_ms() -> i64 {
    with_test_clock(wall_ms())
}

fn wall_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn with_test_clock(wall: i64) -> i64 {
    #[cfg(test)]
    let wall = wall.saturating_add(test_clock_ahead_ms());
    wall
}

/// How far ahead of the wall clock [`seal_stamp_ms`] may run to keep a burst of seals apart.
pub(crate) const SEAL_LEAD_MS: i64 = 500;

/// The stamp for the next frame this process seals: strictly after the last one, unless a
/// burst already ran it [`SEAL_LEAD_MS`] ahead of the wall clock, then equal. Receivers
/// order changes to one row by seal time ("sealed after the card it replaces"), so two
/// changes sealed in one millisecond would make the newer look like a replay of the older.
/// The last stamp lives in memory only, so a restart right after a burst can seal up to
/// [`SEAL_LEAD_MS`] earlier than the frame before it, which an Olm read mark (AR-19) or a
/// removal stamp then counts as that much older: kept small rather than a write per seal.
pub(crate) fn seal_stamp_ms() -> i64 {
    use std::sync::atomic::{AtomicI64, Ordering};
    static LAST: AtomicI64 = AtomicI64::new(0);
    let wall = wall_ms();
    let last = LAST
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |last| Some(stamp_after(last, wall)))
        .unwrap_or(wall);
    with_test_clock(stamp_after(last, wall))
}

/// The stamp for a change this process makes that receivers weigh against the seal time
/// of our earlier frames (a friend request or accept): taken from the seal sequence,
/// because during a burst the wall clock sorts before frames we already sent.
pub(crate) fn change_stamp_ms() -> i64 {
    seal_stamp_ms()
}

fn stamp_after(last: i64, wall: i64) -> i64 {
    last.saturating_add(1).clamp(wall, wall.saturating_add(SEAL_LEAD_MS))
}

/// How far tests have moved the frame clock, per tokio runtime: seals, carried stamps
/// and the staleness judgement all read it, so a whole harness lives through a long
/// absence while unit tests on other threads keep the wall clock.
#[cfg(test)]
static TEST_CLOCK_AHEAD: std::sync::Mutex<Vec<(tokio::runtime::Id, i64)>> = std::sync::Mutex::new(Vec::new());

#[cfg(test)]
fn test_clock_ahead_ms() -> i64 {
    let Ok(runtime) = tokio::runtime::Handle::try_current() else { return 0 };
    let id = runtime.id();
    TEST_CLOCK_AHEAD
        .lock()
        .map(|moved| moved.iter().filter(|(rt, _)| *rt == id).map(|(_, ms)| ms).sum())
        .unwrap_or(0)
}

/// Moves the frame clock ahead for every node on the calling test's runtime until the
/// guard drops. Call it from inside that runtime.
#[cfg(test)]
#[must_use]
pub(crate) fn clock_ahead_for_test(ms: i64) -> TestClockAhead {
    let id = tokio::runtime::Handle::current().id();
    if let Ok(mut moved) = TEST_CLOCK_AHEAD.lock() {
        moved.push((id, ms));
    }
    TestClockAhead(id, ms)
}

#[cfg(test)]
pub(crate) struct TestClockAhead(tokio::runtime::Id, i64);

#[cfg(test)]
impl Drop for TestClockAhead {
    fn drop(&mut self) {
        if let Ok(mut moved) = TEST_CLOCK_AHEAD.lock()
            && let Some(at) = moved.iter().position(|entry| *entry == (self.0, self.1))
        {
            moved.remove(at);
        }
    }
}

fn signed_bytes(room: &str, route: &[u8], ts_ms: i64, nonce: &[u8; NONCE_LEN], body: &[u8]) -> Vec<u8> {
    let mut msg = Vec::with_capacity(DOMAIN.len() + 8 + room.len() + route.len() + 8 + NONCE_LEN + 32);
    msg.extend_from_slice(DOMAIN);
    msg.extend_from_slice(&(room.len() as u32).to_be_bytes());
    msg.extend_from_slice(room.as_bytes());
    msg.extend_from_slice(&(route.len() as u32).to_be_bytes());
    msg.extend_from_slice(route);
    msg.extend_from_slice(&ts_ms.to_be_bytes());
    msg.extend_from_slice(nonce);
    msg.extend_from_slice(&Sha256::digest(body));
    msg
}

/// Seal `body` for `room`, addressed to `route` ([`ROUTE_ROOM`] or a device or master id).
pub(crate) fn seal(keypair: &NativeKeypair, room: &str, route: &str, body: &[u8]) -> Vec<u8> {
    let mut nonce = [0u8; NONCE_LEN];
    if getrandom::fill(&mut nonce).is_err() {
        // A repeated nonce only makes the receiver's replay guard drop a live frame.
        use std::sync::atomic::{AtomicU64, Ordering};
        static FALLBACK: AtomicU64 = AtomicU64::new(0);
        nonce[..8].copy_from_slice(&FALLBACK.fetch_add(1, Ordering::Relaxed).to_be_bytes());
        nonce[8..].copy_from_slice(&now_ms().to_be_bytes());
    }
    seal_at(keypair, room, route, seal_stamp_ms(), nonce, body)
}

pub(crate) fn seal_at(
    keypair: &NativeKeypair,
    room: &str,
    route: &str,
    ts_ms: i64,
    nonce: [u8; NONCE_LEN],
    body: &[u8],
) -> Vec<u8> {
    // Peer ids fit a byte of length; anything longer is cut, and cut identically in
    // what is signed, so it simply never matches a real device.
    let route = &route.as_bytes()[..route.len().min(u8::MAX as usize)];
    let sig = keypair.sign(&signed_bytes(room, route, ts_ms, &nonce, body));
    let mut frame = Vec::with_capacity(MAGIC.len() + 8 + NONCE_LEN + 1 + route.len() + SIG_LEN + body.len());
    frame.extend_from_slice(&MAGIC);
    frame.extend_from_slice(&ts_ms.to_be_bytes());
    frame.extend_from_slice(&nonce);
    frame.push(route.len() as u8);
    frame.extend_from_slice(route);
    frame.extend_from_slice(&sig);
    frame.extend_from_slice(body);
    frame
}

/// Check a frame's seal against the relay's `from` and `room` and how it arrived.
pub(crate) fn open<'a>(
    frame: &'a [u8],
    from: &str,
    room: &str,
    delivery: Delivery<'_>,
    now_ms: i64,
) -> Result<Opened<'a>, Refusal> {
    let Some(rest) = frame.strip_prefix(&MAGIC[..]) else {
        return Err(Refusal::Unsealed);
    };
    let (ts, rest) = split(rest, 8)?;
    let ts_ms = i64::from_be_bytes(ts.try_into().map_err(|_| Refusal::Malformed)?);
    let (nonce, rest) = split(rest, NONCE_LEN)?;
    let nonce: [u8; NONCE_LEN] = nonce.try_into().map_err(|_| Refusal::Malformed)?;
    let (route_len, rest) = split(rest, 1)?;
    let (route, rest) = split(rest, route_len[0] as usize)?;
    let route = std::str::from_utf8(route).map_err(|_| Refusal::Malformed)?;
    let (sig, body) = split(rest, SIG_LEN)?;

    let routed_here = match delivery {
        Delivery::Room => route == ROUTE_ROOM,
        Delivery::Direct { device, master } => route == device || route == master,
    };
    if !routed_here {
        return Err(Refusal::Misrouted);
    }

    let key = crate::crypto::safety_number::pubkey_from_peer_id(from)
        .and_then(|k| VerifyingKey::from_bytes(&k).ok())
        .ok_or(Refusal::NotAPeerId)?;
    let sig = Signature::from_slice(sig).map_err(|_| Refusal::Malformed)?;
    key.verify_strict(&signed_bytes(room, route.as_bytes(), ts_ms, &nonce, body), &sig)
        .map_err(|_| Refusal::BadSignature)?;

    if ts_ms > now_ms + LIVE_SKEW_MS {
        return Err(Refusal::FromTheFuture);
    }
    Ok(Opened { ts_ms, nonce, body })
}

fn split(bytes: &[u8], n: usize) -> Result<(&[u8], &[u8]), Refusal> {
    if bytes.len() < n {
        return Err(Refusal::Malformed);
    }
    Ok(bytes.split_at(n))
}

/// Seal the payload of one relay command, addressed as the relay will deliver it.
pub(crate) fn seal_command(keypair: &NativeKeypair, cmd: WsCommand) -> WsCommand {
    match cmd {
        WsCommand::SendToRoom { room_code, data } => {
            let data = seal(keypair, &room_code, ROUTE_ROOM, &data);
            WsCommand::SendToRoom { room_code, data }
        }
        WsCommand::SendPublic { room_code, data } => {
            let data = seal(keypair, &room_code, ROUTE_ROOM, &data);
            WsCommand::SendPublic { room_code, data }
        }
        WsCommand::SendToRoomTopic { room_code, topic, data } => {
            let data = seal(keypair, &room_code, ROUTE_ROOM, &data);
            WsCommand::SendToRoomTopic { room_code, topic, data }
        }
        WsCommand::SendDirect { room_code, target_peer, data } => {
            let data = seal(keypair, &room_code, &target_peer, &data);
            WsCommand::SendDirect { room_code, target_peer, data }
        }
        WsCommand::SendDirectImage { room_code, target_peer, data } => {
            let data = seal(keypair, &room_code, &target_peer, &data);
            WsCommand::SendDirectImage { room_code, target_peer, data }
        }
        WsCommand::SendBinaryDirect { room_code, target_peer, data, credit } => {
            let data = seal(keypair, &room_code, &target_peer, &data);
            WsCommand::SendBinaryDirect { room_code, target_peer, data, credit }
        }
        // Empty = a push trigger only, which the relay buffers nothing for.
        WsCommand::SendChannelDirect { room_code, target_peer, channel_id, mention, data } if !data.is_empty() => {
            let data = seal(keypair, &room_code, &target_peer, &data);
            WsCommand::SendChannelDirect { room_code, target_peer, channel_id, mention, data }
        }
        other => other,
    }
}

/// A [`WsCommand::Carry`] on its way to the node, and where the node answers with
/// the frames it became.
pub(crate) type CarryRequest = (WsCommand, tokio::sync::oneshot::Sender<Vec<WsCommand>>);

/// Where the sealing stage hands the node what only the node can encrypt or keep.
pub(crate) type CarryTx = UnboundedSender<CarryRequest>;

/// Put a sealing stage in front of the relay: whoever holds the returned sender can
/// only send sealed frames, so the node hands it to everything that sends. A
/// [`WsCommand::Carry`] comes back out of the returned receiver for the node to put
/// inside Olm, and nothing queued after it leaves before the frames it became: wire
/// order stays program order, so a plaintext frame never overtakes the carried state
/// it depends on.
pub(crate) fn spawn_sealer(
    keypair: NativeKeypair,
    relay: UnboundedSender<WsCommand>,
) -> (UnboundedSender<WsCommand>, tokio::sync::mpsc::UnboundedReceiver<CarryRequest>) {
    const CARRY_WAIT: std::time::Duration = std::time::Duration::from_secs(10);
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let (carry_tx, carry_rx) = tokio::sync::mpsc::unbounded_channel::<CarryRequest>();
    tokio::spawn(async move {
        let mut mls_releases = super::olm_lane::MlsReleases::default();
        while let Some(cmd) = rx.recv().await {
            let out = match cmd {
                WsCommand::Carry { .. } => {
                    let (done_tx, done_rx) = tokio::sync::oneshot::channel();
                    if carry_tx.send((cmd, done_tx)).is_err() {
                        break;
                    }
                    match tokio::time::timeout(CARRY_WAIT, done_rx).await {
                        Ok(Ok(frames)) => frames,
                        _ => {
                            hollow_log!("[HOLLOW-SECURITY] A carried frame was not encrypted in time and was dropped");
                            Vec::new()
                        }
                    }
                }
                cmd => vec![cmd],
            };
            // An Olm frame waits here for its session save, and so does all that follows it.
            let mut relay_gone = false;
            for cmd in out {
                #[cfg(test)]
                super::test_harness::g1_probe::note_olm(&cmd);
                if let Some(cmd) = super::olm_lane::released(cmd, &carry_tx, &mut mls_releases).await
                    && relay.send(seal_command(&keypair, cmd)).is_err()
                {
                    relay_gone = true;
                    break;
                }
            }
            if relay_gone {
                break;
            }
        }
    });
    (tx, carry_rx)
}

/// The body of a sealed frame, unchecked. For code that reads frames it already
/// trusts (its own sends in tests, recorded wire traffic), never for inbound ones.
#[cfg(test)]
pub(crate) fn unchecked_body(frame: &[u8]) -> &[u8] {
    let Some(rest) = frame.strip_prefix(&MAGIC[..]) else { return frame };
    let skip = 8 + NONCE_LEN;
    let Some(&route_len) = rest.get(skip) else { return frame };
    rest.get(skip + 1 + route_len as usize + SIG_LEN..).unwrap_or(frame)
}

/// Stored first sights: (sender, nonce, expires_ms).
pub(crate) type StoredNonces = Vec<(String, Vec<u8>, i64)>;

/// Refuses a repeated live-only frame inside the window its clock stamp is still
/// accepted in, so a relay cannot replay one.
#[derive(Default)]
pub(crate) struct ReplayGuard {
    seen: HashMap<String, HashMap<[u8; NONCE_LEN], i64>>,
    /// Where first sights are kept, so a frame seen before a restart stays seen
    /// after it (AR-35). The forwarder keeps none: it may write nothing to disk.
    sink: Option<crate::crypto::LiveNonceSink>,
    /// Set while the stored sights have not arrived.
    loading: Option<Loading>,
    /// Accepted friends' masters, whose devices' sights go to the stored pool no
    /// stranger can fill.
    friends: HashSet<String>,
}

/// Rows the store has not answered with yet. Until it does, any frame stamped before
/// this process started may be one acted on before the restart, so it is refused.
struct Loading {
    boot_ms: i64,
    rows: Option<tokio::sync::oneshot::Receiver<StoredNonces>>,
}

impl ReplayGuard {
    /// The node's guard, started from what `store` kept. When the rows do not come
    /// `within`, it starts anyway and refuses frames stamped before now until they do.
    pub(crate) async fn load(store: &crate::crypto::CryptoStore, within: std::time::Duration) -> Self {
        let now = now_ms();
        let mut answer = store.ask_live_nonces(now);
        match tokio::time::timeout(within, &mut answer).await {
            Ok(Ok(rows)) => Self::persisted(store.live_nonce_sink(), rows, now),
            Ok(Err(_)) => {
                hollow_log!("[HOLLOW-SECURITY] The stored replay guard could not be read: refusing live frames stamped before this start");
                Self::loading(store.live_nonce_sink(), None, now)
            }
            Err(_) => {
                hollow_log!("[HOLLOW-SECURITY] The stored replay guard did not load in {within:?}: refusing live frames stamped before this start until it does");
                Self::loading(store.live_nonce_sink(), Some(answer), now)
            }
        }
    }

    /// A guard that starts from the stored `rows` (sender, nonce, expires_ms) and
    /// writes every first sight to `sink`.
    pub(crate) fn persisted(
        sink: crate::crypto::LiveNonceSink,
        rows: StoredNonces,
        now_ms: i64,
    ) -> Self {
        let mut guard = Self { sink: Some(sink), ..Self::default() };
        guard.merge(rows, now_ms);
        guard
    }

    /// A guard whose stored rows are still to come on `rows` (never, when `None`).
    pub(crate) fn loading(
        sink: crate::crypto::LiveNonceSink,
        rows: Option<tokio::sync::oneshot::Receiver<StoredNonces>>,
        boot_ms: i64,
    ) -> Self {
        Self { sink: Some(sink), loading: Some(Loading { boot_ms, rows }), ..Self::default() }
    }

    fn merge(&mut self, rows: StoredNonces, now_ms: i64) {
        let latest = now_ms.saturating_add(2 * LIVE_SKEW_MS);
        for (sender, nonce, expires) in rows {
            let Ok(nonce) = <[u8; NONCE_LEN]>::try_from(nonce.as_slice()) else { continue };
            if expires < now_ms || expires > latest {
                continue;
            }
            let seen = self.seen.entry(sender).or_default();
            if seen.len() < MAX_SEEN_PER_SENDER {
                seen.entry(nonce).or_insert(expires);
            }
        }
    }

    /// Take the stored rows if they arrived meanwhile.
    fn settle(&mut self, now_ms: i64) {
        let Some(Loading { rows: Some(rx), .. }) = &mut self.loading else { return };
        match rx.try_recv() {
            Ok(rows) => {
                hollow_log!("[HOLLOW-SWARM] The stored replay guard arrived late ({} rows)", rows.len());
                self.loading = None;
                self.merge(rows, now_ms);
            }
            Err(tokio::sync::oneshot::error::TryRecvError::Empty) => {}
            Err(tokio::sync::oneshot::error::TryRecvError::Closed) => {
                hollow_log!("[HOLLOW-SECURITY] The stored replay guard could not be read: refusing live frames stamped before this start");
                if let Some(loading) = &mut self.loading {
                    loading.rows = None;
                }
            }
        }
    }

    /// The accepted friends whose devices count as known senders.
    pub(crate) fn know_friends(&mut self, masters: HashSet<String>) {
        self.friends = masters;
    }

    /// The master of `sender` when the roster we hold counts it as a device of our own
    /// identity, of an accepted friend or of a co-member. Anyone else, a stranger with
    /// a roster it delivered itself included, is placed nowhere.
    pub(crate) fn placement(
        &self,
        sender: &str,
        local_master: &str,
        server_states: &HashMap<String, crate::crdt::server_state::ServerState>,
    ) -> Option<String> {
        let master = super::resolver::resolve(sender);
        if !super::resolver::is_device_of(sender, &master)
            || super::resolver::is_revoked(sender)
            || super::blocklist::is_blocked(&master)
        {
            return None;
        }
        let known = master == local_master
            || self.friends.contains(&master)
            || server_states.values().any(|s| !s.is_deleted() && s.is_member(&master) && s.is_member(local_master));
        known.then_some(master)
    }

    /// Whether this is the first time `sender` shows us `nonce`. A frame this old or
    /// older must already have been refused as stale. `placed` as [`Self::placement`].
    pub(crate) fn first_sight(
        &mut self,
        sender: &str,
        nonce: [u8; NONCE_LEN],
        ts_ms: i64,
        now_ms: i64,
        placed: Option<&str>,
    ) -> bool {
        self.settle(now_ms);
        if self.loading.as_ref().is_some_and(|l| ts_ms < l.boot_ms) {
            return false;
        }
        let seen = self.seen.entry(sender.to_string()).or_default();
        if seen.len() >= MAX_SEEN_PER_SENDER {
            seen.retain(|_, expires| *expires >= now_ms);
            if seen.len() >= MAX_SEEN_PER_SENDER {
                return false;
            }
        }
        let expires = ts_ms.saturating_add(LIVE_SKEW_MS);
        let first = seen.insert(nonce, expires).is_none();
        if first && let Some(sink) = &self.sink {
            sink.note(sender, nonce, expires, placed);
        }
        first
    }

    /// Forget nonces whose frames would now be refused as stale anyway.
    pub(crate) fn prune(&mut self, now_ms: i64) {
        self.settle(now_ms);
        if let Some(sink) = &self.sink {
            sink.prune(now_ms);
        }
        self.seen.retain(|_, seen| {
            seen.retain(|_, expires| *expires >= now_ms);
            !seen.is_empty()
        });
    }
}

/// Whether a live-only frame stamped `ts_ms` is too old to act on. The sealer picks
/// the stamp, so the arithmetic saturates.
pub(crate) fn is_stale(ts_ms: i64, now_ms: i64) -> bool {
    now_ms.saturating_sub(ts_ms) > LIVE_SKEW_MS
}

/// The latest stamp an honest sender can have put on a row it sent at `sent_ms`: a
/// later one would outrank every write that follows it.
pub(crate) fn stamp_ceiling(sent_ms: i64) -> i64 {
    sent_ms.saturating_add(LIVE_SKEW_MS)
}

/// The latest stamp a row we stored can honestly carry at `now_ms`: every ingest holds
/// a stamp to its frame's [`stamp_ceiling`], and a frame is refused past ours by
/// [`LIVE_SKEW_MS`]. A stored row past it was planted, and any genuine write replaces it.
pub(crate) fn stored_stamp_limit(now_ms: i64) -> i64 {
    stamp_ceiling(stamp_ceiling(now_ms))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keypair(tag: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[tag; 32])
    }

    const ROOM: &str = "0123456789abcdef0123456789abcdef";
    const NOW: i64 = 1_790_000_000_000;

    fn sealed(kp: &NativeKeypair, route: &str, body: &[u8]) -> Vec<u8> {
        seal_at(kp, ROOM, route, NOW, [7; NONCE_LEN], body)
    }

    #[test]
    fn a_sealed_frame_opens_for_its_sender_room_and_route() {
        let alice = keypair(1);
        let frame = sealed(&alice, ROUTE_ROOM, br#"{"type":"ack"}"#);
        let opened = open(&frame, &alice.peer_id(), ROOM, Delivery::Room, NOW).unwrap();
        assert_eq!(opened.body, br#"{"type":"ack"}"#);
        assert_eq!(opened.ts_ms, NOW);

        let bob = keypair(2);
        let direct = sealed(&alice, &bob.peer_id(), b"x");
        let to_bob = Delivery::Direct { device: &bob.peer_id(), master: "master" };
        assert!(open(&direct, &alice.peer_id(), ROOM, to_bob, NOW).is_ok());
        let to_bobs_inbox = sealed(&alice, "master", b"x");
        assert!(open(&to_bobs_inbox, &alice.peer_id(), ROOM, to_bob, NOW).is_ok());
    }

    #[test]
    fn a_frame_stamped_with_another_devices_id_is_refused() {
        let (alice, mallory) = (keypair(1), keypair(3));
        let frame = sealed(&mallory, ROUTE_ROOM, b"x");
        assert_eq!(open(&frame, &alice.peer_id(), ROOM, Delivery::Room, NOW).unwrap_err(), Refusal::BadSignature);
        assert_eq!(open(&frame, "not-a-peer-id", ROOM, Delivery::Room, NOW).unwrap_err(), Refusal::NotAPeerId);
    }

    #[test]
    fn a_frame_moved_to_another_room_device_or_delivery_is_refused() {
        let (alice, bob, carol) = (keypair(1), keypair(2), keypair(4));
        let from = alice.peer_id();

        let broadcast = sealed(&alice, ROUTE_ROOM, b"x");
        let other_room = "fedcba9876543210fedcba9876543210";
        assert_eq!(open(&broadcast, &from, other_room, Delivery::Room, NOW).unwrap_err(), Refusal::BadSignature);
        let to_bob = Delivery::Direct { device: &bob.peer_id(), master: "bob-master" };
        assert_eq!(open(&broadcast, &from, ROOM, to_bob, NOW).unwrap_err(), Refusal::Misrouted);

        let for_bob = sealed(&alice, &bob.peer_id(), b"x");
        let to_carol = Delivery::Direct { device: &carol.peer_id(), master: "carol-master" };
        assert_eq!(open(&for_bob, &from, ROOM, to_carol, NOW).unwrap_err(), Refusal::Misrouted);
        assert_eq!(open(&for_bob, &from, ROOM, Delivery::Room, NOW).unwrap_err(), Refusal::Misrouted);
    }

    #[test]
    fn any_change_to_a_sealed_frame_breaks_it() {
        let alice = keypair(1);
        let frame = sealed(&alice, ROUTE_ROOM, br#"{"type":"member_kick_broadcast"}"#);
        for i in MAGIC.len()..frame.len() {
            let mut tampered = frame.clone();
            tampered[i] ^= 0x01;
            assert!(
                open(&tampered, &alice.peer_id(), ROOM, Delivery::Room, NOW).is_err(),
                "byte {i} changed and the frame still opened"
            );
        }
        assert!(open(&frame[..frame.len() - 1], &alice.peer_id(), ROOM, Delivery::Room, NOW).is_err());
    }

    #[test]
    fn unsealed_future_and_truncated_frames_are_refused() {
        let alice = keypair(1);
        let from = alice.peer_id();
        assert_eq!(open(br#"{"type":"ack"}"#, &from, ROOM, Delivery::Room, NOW).unwrap_err(), Refusal::Unsealed);

        let ahead = seal_at(&alice, ROOM, ROUTE_ROOM, NOW + LIVE_SKEW_MS + 1, [7; NONCE_LEN], b"x");
        assert_eq!(open(&ahead, &from, ROOM, Delivery::Room, NOW).unwrap_err(), Refusal::FromTheFuture);
        let at_edge = seal_at(&alice, ROOM, ROUTE_ROOM, NOW + LIVE_SKEW_MS, [7; NONCE_LEN], b"x");
        assert!(open(&at_edge, &from, ROOM, Delivery::Room, NOW).is_ok());

        let frame = sealed(&alice, ROUTE_ROOM, b"");
        for len in MAGIC.len()..frame.len() {
            assert!(open(&frame[..len], &from, ROOM, Delivery::Room, NOW).is_err());
        }
    }

    /// AR-35 review LOW 3: until the stored rows arrive, a frame stamped before the start
    /// may be one acted on before the restart; rows that come late are merged.
    #[test]
    fn a_guard_whose_stored_rows_come_late_refuses_frames_from_before_its_start() {
        let (sink, _queue) = crate::crypto::LiveNonceSink::detached_for_test();
        let (rows, answer) = tokio::sync::oneshot::channel();
        let mut guard = ReplayGuard::loading(sink, Some(answer), NOW);
        assert!(!guard.first_sight("alice", [1; NONCE_LEN], NOW - 1, NOW, None), "took a frame from before the start without its rows");
        assert!(guard.first_sight("alice", [2; NONCE_LEN], NOW, NOW, None), "refused a frame stamped after the start");
        rows.send(vec![("alice".to_string(), vec![1; NONCE_LEN], NOW - 1 + LIVE_SKEW_MS)]).unwrap();
        assert!(!guard.first_sight("alice", [1; NONCE_LEN], NOW - 1, NOW + 5, None), "a stored row that came late was not merged");
        assert!(guard.first_sight("alice", [3; NONCE_LEN], NOW - 1, NOW + 5, None), "still refusing once the rows came");
        assert!(!guard.first_sight("alice", [2; NONCE_LEN], NOW, NOW + 5, None), "the merge lost a sight made while loading");
    }

    /// AR-35 review LOW 6: a frame is fresh through the millisecond its nonce expires,
    /// so the guard keeps the nonce through it.
    #[test]
    fn a_nonce_is_kept_through_the_last_millisecond_its_frame_is_fresh() {
        let mut guard = ReplayGuard::default();
        let ts = NOW - LIVE_SKEW_MS;
        assert!(!is_stale(ts, NOW));
        assert!(guard.first_sight("alice", [1; NONCE_LEN], ts, NOW - 1, None));
        guard.prune(NOW);
        assert!(!guard.first_sight("alice", [1; NONCE_LEN], ts, NOW, None), "a fresh frame replayed at its last millisecond");
    }

    /// AR-35 review MED 1: only a device the held roster places under our own identity,
    /// a friend's or a co-member's earns the stored pool no stranger can fill; a stranger
    /// whose roster it delivered itself does not.
    #[test]
    fn only_our_friends_and_co_members_devices_are_placed() {
        use super::super::resolver;
        let _g = resolver::test_lock();
        resolver::clear_for_test();
        let me = "ar35-me";
        resolver::seed_self(me, &["ar35-me-dev".to_string()]);
        resolver::update_many("ar35-friend", ["ar35-friend-dev"]);
        resolver::update_many("ar35-member", ["ar35-member-dev"]);
        resolver::update_many("ar35-stranger", ["ar35-stranger-dev"]);
        // Revoked, then linked again by a roster that still lists it: the revocation holds.
        resolver::mark_revoked(&["ar35-friend-gone".to_string()]);
        resolver::update_many("ar35-friend", ["ar35-friend-gone"]);
        resolver::update_many("ar35-blocked", ["ar35-blocked-dev"]);
        super::super::blocklist::block("ar35-blocked");
        resolver::note_roster(me);

        let mut state = crate::crdt::server_state::ServerState::new("srv".into(), "s".into(), me.into());
        for id in ["ar35-member", "ar35-blocked"] {
            state.members.insert(id.into(), crate::crdt::server_state::MemberInfo { peer_id: id.into(), display_name: id.into() });
        }
        let states = HashMap::from([("srv".to_string(), state)]);
        let mut guard = ReplayGuard::default();
        guard.know_friends(HashSet::from(["ar35-friend".to_string()]));
        let placed = |p: &str| guard.placement(p, me, &states);

        assert_eq!(placed("ar35-me-dev").as_deref(), Some(me), "our own device");
        assert_eq!(placed("ar35-friend-dev").as_deref(), Some("ar35-friend"), "a friend's device");
        assert_eq!(placed("ar35-member-dev").as_deref(), Some("ar35-member"), "a co-member's device");
        assert_eq!(placed("ar35-stranger-dev"), None, "a stranger with a roster of its own");
        assert_eq!(placed("ar35-unknown"), None, "an id no roster places");
        assert_eq!(placed("ar35-friend-gone"), None, "a removed device of a friend");
        assert_eq!(placed("ar35-blocked-dev"), None, "a blocked co-member");
        assert_eq!(placed(me), None, "our bare master id, which our roster does not count");
        super::super::blocklist::unblock("ar35-blocked");
        resolver::clear_for_test();
    }

    #[test]
    fn a_live_frame_is_taken_once_per_nonce_while_fresh() {
        let mut guard = ReplayGuard::default();
        assert!(guard.first_sight("alice", [1; NONCE_LEN], NOW, NOW, None));
        assert!(!guard.first_sight("alice", [1; NONCE_LEN], NOW, NOW + 1_000, None));
        assert!(guard.first_sight("bob", [1; NONCE_LEN], NOW, NOW, None));
        assert!(guard.first_sight("alice", [2; NONCE_LEN], NOW, NOW, None));

        assert!(!is_stale(NOW, NOW + LIVE_SKEW_MS));
        assert!(is_stale(NOW, NOW + LIVE_SKEW_MS + 1));
        guard.prune(NOW + LIVE_SKEW_MS + 1);
        assert!(guard.seen.is_empty());
    }

    /// C-OLM-04: the sealer picks its own stamp, so the extremes are judged rather
    /// than overflowing the clock arithmetic.
    #[test]
    fn a_frame_stamped_at_the_i64_extremes_is_judged_without_overflow() {
        assert!(is_stale(i64::MIN, NOW));
        assert!(is_stale(i64::MIN + 1, NOW));
        assert!(!is_stale(i64::MAX, NOW));
        let mut guard = ReplayGuard::default();
        assert!(guard.first_sight("alice", [3; NONCE_LEN], i64::MAX, NOW, None));
        assert!(!guard.first_sight("alice", [3; NONCE_LEN], i64::MAX, NOW, None));
    }

    #[test]
    fn every_payload_command_leaves_sealed_for_the_way_it_is_delivered() {
        let (alice, bob) = (keypair(1), keypair(2));
        let (from, bob_id) = (alice.peer_id(), bob.peer_id());
        let to_bob = Delivery::Direct { device: &bob_id, master: "bob-master" };
        let body = b"payload".to_vec();
        let opens = |data: &[u8], delivery| open(data, &from, ROOM, delivery, now_ms()).map(|o| o.body.to_vec());

        let room = seal_command(&alice, WsCommand::SendToRoom { room_code: ROOM.into(), data: body.clone() });
        let WsCommand::SendToRoom { data, .. } = room else { panic!() };
        assert_eq!(opens(&data, Delivery::Room).unwrap(), body);

        let topic = WsCommand::SendToRoomTopic { room_code: ROOM.into(), topic: "c".into(), data: body.clone() };
        let WsCommand::SendToRoomTopic { data, .. } = seal_command(&alice, topic) else { panic!() };
        assert_eq!(opens(&data, Delivery::Room).unwrap(), body);

        for cmd in [
            WsCommand::SendDirect { room_code: ROOM.into(), target_peer: bob_id.clone(), data: body.clone() },
            WsCommand::SendDirectImage { room_code: ROOM.into(), target_peer: bob_id.clone(), data: body.clone() },
            WsCommand::SendChannelDirect {
                room_code: ROOM.into(), target_peer: bob_id.clone(), channel_id: "c".into(), mention: false, data: body.clone(),
            },
        ] {
            let data = match seal_command(&alice, cmd) {
                WsCommand::SendDirect { data, .. }
                | WsCommand::SendDirectImage { data, .. }
                | WsCommand::SendChannelDirect { data, .. } => data,
                _ => panic!(),
            };
            assert_eq!(opens(&data, to_bob).unwrap(), body);
            assert_eq!(opens(&data, Delivery::Room).unwrap_err(), Refusal::Misrouted);
        }

        let trigger = WsCommand::SendChannelDirect {
            room_code: ROOM.into(), target_peer: bob_id, channel_id: "c".into(), mention: true, data: vec![],
        };
        let WsCommand::SendChannelDirect { data, .. } = seal_command(&alice, trigger) else { panic!() };
        assert!(data.is_empty());
    }

    #[test]
    fn frames_sealed_within_one_millisecond_carry_increasing_stamps() {
        let alice = keypair(1);
        let stamps: Vec<i64> = (0..200)
            .map(|_| open(&seal(&alice, ROOM, ROUTE_ROOM, b"x"), &alice.peer_id(), ROOM, Delivery::Room, now_ms()).unwrap().ts_ms)
            .collect();
        assert!(stamps.windows(2).all(|w| w[1] > w[0]), "two frames shared a seal stamp: {stamps:?}");
    }

    #[test]
    fn a_seal_stamp_runs_at_most_the_lead_ahead_and_never_back() {
        assert_eq!(stamp_after(NOW - 10, NOW), NOW, "an idle clock seals at the wall time");
        assert_eq!(stamp_after(NOW + 3, NOW), NOW + 4);
        assert_eq!(stamp_after(NOW + SEAL_LEAD_MS, NOW), NOW + SEAL_LEAD_MS, "a burst stops at the lead");
        assert_eq!(stamp_after(i64::MAX, i64::MAX), i64::MAX);
    }

    #[test]
    fn a_change_stamp_never_sorts_before_a_frame_already_sealed() {
        let last = (0..SEAL_LEAD_MS).map(|_| seal_stamp_ms()).max().unwrap();
        assert!(last > now_ms(), "precondition: the burst ran the seals ahead of the wall clock");
        assert!(change_stamp_ms() >= last, "a change made after a frame sorts before it");
    }

    #[test]
    fn unchecked_body_strips_a_seal_and_passes_anything_else_through() {
        let alice = keypair(1);
        assert_eq!(unchecked_body(&sealed(&alice, "some-device", b"body")), b"body");
        assert_eq!(unchecked_body(b"{}"), b"{}");
    }
}
