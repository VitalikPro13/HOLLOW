//! Per-peer frame budgets. Every node takes a sender device's frames through one
//! bucket; what the bucket drops is asked for again from that sender once the bucket
//! has refilled. Our own catch-up bulk to one device goes paced against the same
//! numbers, so a well-behaved sender stays inside the receiver's bucket.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use super::types::{HavenMessage, MessageEnvelope};

/// Frames one sender device may put in at once, and per second after: the same on
/// both ends.
const BURST: u32 = 100;
const REFILL_PER_SEC: u32 = 20;
/// A sender is repaired at most this often, however long it floods.
const REPAIR_COOLDOWN: Duration = Duration::from_secs(30);
/// Senders waiting for a repair; past it the oldest wait is forgotten.
const MAX_PENDING_REPAIRS: usize = 1024;
/// A device back from away gets our DM copies only once its bucket has refilled
/// (BURST / REFILL_PER_SEC = 5 s) from the relay replaying those same copies.
const HOLD: Duration = Duration::from_secs(6);
/// Our bulk to one device: a fifth of its bucket at once, then half its refill, which
/// leaves room for its live traffic and the answers to its asks.
const PACE_BURST: f64 = (BURST / 5) as f64;
const PACE_PER_SEC: f64 = (REFILL_PER_SEC / 2) as f64;

/// What the bucket did with one frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Admission {
    Admitted,
    /// `first`: the first drop since the sender's last repair.
    Dropped { first: bool },
}

/// Senders whose buckets refill nothing, in every node of this process.
#[cfg(test)]
static PAUSED: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// TEST-ONLY: stop or restart the refill of `sender`'s buckets, so a node takes exactly
/// what a bucket holds, however slowly the machine runs it.
#[cfg(test)]
pub(crate) fn pause_refill(sender: &str, paused: bool) {
    let mut held = PAUSED.lock().unwrap_or_else(|e| e.into_inner());
    held.retain(|s| s != sender);
    if paused {
        held.push(sender.to_string());
    }
}

fn refill_paused(sender: &str) -> bool {
    #[cfg(test)]
    {
        PAUSED.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|s| s == sender)
    }
    #[cfg(not(test))]
    {
        let _ = sender;
        false
    }
}

struct Bucket {
    tokens: u32,
    last: Instant,
}

impl Bucket {
    fn whole_refill(&self, sender: &str, now: Instant) -> u32 {
        if refill_paused(sender) {
            return 0;
        }
        (now.saturating_duration_since(self.last).as_secs_f64() * f64::from(REFILL_PER_SEC)) as u32
    }

    fn refill(&mut self, sender: &str, now: Instant) {
        let refill = self.whole_refill(sender, now);
        if refill > 0 {
            self.tokens = self.tokens.saturating_add(refill).min(BURST);
            self.last = now;
        }
    }
}

/// The inbound token bucket per sender device, and the senders it dropped frames from.
#[derive(Default)]
pub(crate) struct Limiter {
    buckets: HashMap<String, Bucket>,
    /// Sender -> (first drop, frames dropped) since its last repair.
    dropped: HashMap<String, (Instant, u32)>,
    repaired_at: HashMap<String, Instant>,
    #[cfg(test)]
    dropped_total: HashMap<String, u64>,
}

impl Limiter {
    /// Take one frame from `from`, or drop it and remember that it was dropped.
    pub(crate) fn admit(&mut self, from: &str, now: Instant) -> Admission {
        let bucket = self.buckets.entry(from.to_string()).or_insert(Bucket { tokens: BURST, last: now });
        bucket.refill(from, now);
        if bucket.tokens > 0 {
            bucket.tokens -= 1;
            return Admission::Admitted;
        }
        #[cfg(test)]
        {
            *self.dropped_total.entry(from.to_string()).or_default() += 1;
        }
        if let Some((_, n)) = self.dropped.get_mut(from) {
            *n = n.saturating_add(1);
            return Admission::Dropped { first: false };
        }
        if self.dropped.len() >= MAX_PENDING_REPAIRS
            && let Some(oldest) = self.dropped.iter().min_by_key(|(_, (at, _))| *at).map(|(p, _)| p.clone())
        {
            self.dropped.remove(&oldest);
        }
        self.dropped.insert(from.to_string(), (now, 1));
        Admission::Dropped { first: true }
    }

    /// Senders to ask again now, with how many frames each lost: one entry per sender
    /// however much it sent, only once its bucket is full again (it stopped flooding),
    /// and never within [`REPAIR_COOLDOWN`] of its last repair.
    pub(crate) fn due_repairs(&mut self, now: Instant) -> Vec<(String, u32)> {
        let due: Vec<String> = self
            .dropped
            .keys()
            .filter(|peer| {
                let refilled =
                    self.buckets.get(*peer).is_none_or(|b| b.tokens.saturating_add(b.whole_refill(peer, now)) >= BURST);
                let cooled = self
                    .repaired_at
                    .get(*peer)
                    .is_none_or(|at| now.saturating_duration_since(*at) >= REPAIR_COOLDOWN);
                refilled && cooled
            })
            .cloned()
            .collect();
        due.into_iter()
            .filter_map(|peer| {
                let (_, lost) = self.dropped.remove(&peer)?;
                self.repaired_at.insert(peer.clone(), now);
                Some((peer, lost))
            })
            .collect()
    }

    /// TEST-ONLY: every frame dropped so far, per sender.
    #[cfg(test)]
    pub(crate) fn dropped_totals(&self) -> HashMap<String, u64> {
        self.dropped_total.clone()
    }

    /// Forget senders silent for `idle`.
    pub(crate) fn forget_idle(&mut self, idle: Duration, now: Instant) {
        self.buckets.retain(|_, b| now.saturating_duration_since(b.last) < idle);
        let buckets = &self.buckets;
        self.dropped.retain(|peer, _| buckets.contains_key(peer));
        self.repaired_at.retain(|_, at| now.saturating_duration_since(*at) < idle.max(REPAIR_COOLDOWN));
    }
}

/// A DM copy the fan-out queued for a device after handing it to the relay: the relay
/// replays it on the device's return, and the device's DM sync re-serves its row.
fn is_dm_copy(json: &str) -> bool {
    matches!(
        serde_json::from_str::<MessageEnvelope>(json),
        Ok(MessageEnvelope::DirectMessage { .. }
            | MessageEnvelope::EditMessage { .. }
            | MessageEnvelope::DeleteMessage { .. }
            | MessageEnvelope::AddReaction { .. }
            | MessageEnvelope::RemoveReaction { .. }
            | MessageEnvelope::LinkPreviewSet { .. })
    )
}

/// One frame of our bulk to a device, in the order it was paced.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Paced {
    /// An Olm envelope that waits for the device's next return when it cannot go.
    Kept(String),
    /// An Olm envelope answering the device's own ask: lost when it cannot go, since
    /// the device asks again when it is back.
    Answer(String),
    /// A frame the lane rule lets the relay read: lost when we share no room with the
    /// device, the way a direct send to it is.
    Plain(Vec<u8>),
}

impl Paced {
    /// `msg` inside the device's Olm session, as the Olm lane carries it.
    pub(crate) fn carried(msg: &HavenMessage) -> Option<Self> {
        super::olm_lane::carried_json(msg).map(Self::Kept)
    }

    pub(crate) fn answer(envelope: &MessageEnvelope) -> Option<Self> {
        serde_json::to_string(envelope).ok().map(Self::Answer)
    }

    pub(crate) fn plain(msg: &HavenMessage) -> Option<Self> {
        serde_json::to_vec(msg).ok().map(Self::Plain)
    }

    fn needs_session(&self) -> bool {
        !matches!(self, Self::Plain(_))
    }
}

struct Lane {
    items: VecDeque<Paced>,
    tokens: f64,
    last: Instant,
}

/// Our queued bulk per device and the pace each device's goes out at.
#[derive(Default)]
struct Outbox {
    lanes: HashMap<String, Lane>,
}

impl Outbox {
    fn push(&mut self, device: &str, items: impl IntoIterator<Item = Paced>, now: Instant) {
        let mut items = items.into_iter().peekable();
        if items.peek().is_none() {
            return;
        }
        let lane = self
            .lanes
            .entry(device.to_string())
            .or_insert_with(|| Lane { items: VecDeque::new(), tokens: PACE_BURST, last: now });
        lane.items.extend(items);
    }

    /// What each device may be sent now. A lane outlives its queue until its budget is
    /// whole again, so a second drain right after the first gets no second burst.
    fn ready(&mut self, now: Instant) -> Vec<(String, Vec<Paced>)> {
        let mut out = Vec::new();
        self.lanes.retain(|device, lane| {
            let elapsed = now.saturating_duration_since(lane.last).as_secs_f64();
            lane.tokens = (lane.tokens + elapsed * PACE_PER_SEC).min(PACE_BURST);
            lane.last = now;
            let n = (lane.tokens as usize).min(lane.items.len());
            if n > 0 {
                lane.tokens -= n as f64;
                out.push((device.clone(), lane.items.drain(..n).collect()));
            }
            !lane.items.is_empty() || lane.tokens < PACE_BURST
        });
        out
    }

    /// What waits for `device`; with `sealed_only`, plain frames keep their place.
    fn take(&mut self, device: &str, sealed_only: bool) -> Vec<Paced> {
        let Some(lane) = self.lanes.get_mut(device) else { return Vec::new() };
        let (taken, kept): (VecDeque<Paced>, VecDeque<Paced>) =
            lane.items.drain(..).partition(|item| !sealed_only || item.needs_session());
        lane.items = kept;
        taken.into()
    }
}

/// What a node owes the devices it sends bulk to, and the inbound limiter that stands
/// for theirs.
#[derive(Default)]
pub(crate) struct FrameBudget {
    pub(crate) limiter: Limiter,
    outbox: Outbox,
    /// Device -> (when its DM copies go, the copies).
    held: HashMap<String, (Instant, Vec<String>)>,
    /// Every Olm-lane message aimed at a device, carried or paced, in order.
    #[cfg(test)]
    carried: Vec<(String, String)>,
}

impl FrameBudget {
    /// What waited for `device`, which just came back: its DM copies wait out [`HOLD`]
    /// while the relay replays them, everything else goes paced from now.
    pub(crate) fn welcome_back(&mut self, device: &str, queued: Vec<String>, now: Instant) {
        let (copies, rest): (Vec<String>, Vec<String>) = queued.into_iter().partition(|json| is_dm_copy(json));
        if !copies.is_empty() {
            // Every return is a fresh replay: the hold starts again.
            let slot = self.held.entry(device.to_string()).or_insert_with(|| (now, Vec::new()));
            slot.0 = now + HOLD;
            slot.1.extend(copies);
        }
        self.outbox.push(device, rest.into_iter().map(Paced::Kept), now);
    }

    /// Everything waiting for `device`, paced from now, held copies first.
    pub(crate) fn send_now(&mut self, device: &str, queued: Vec<String>, now: Instant) {
        let mut items = self.held.remove(device).map(|(_, copies)| copies).unwrap_or_default();
        items.extend(queued);
        self.outbox.push(device, items.into_iter().map(Paced::Kept), now);
    }

    /// One more frame of our bulk to `device`, behind whatever already waits for it.
    /// Held copies keep waiting out their hold.
    pub(crate) fn pace(&mut self, device: &str, item: Paced, now: Instant) {
        #[cfg(test)]
        if let Paced::Kept(json) = &item {
            self.note_carried(device, json);
        }
        self.outbox.push(device, [item], now);
    }

    /// What may go out now, per device.
    pub(crate) fn ready(&mut self, now: Instant) -> Vec<(String, Vec<Paced>)> {
        let due: Vec<String> = self.held.iter().filter(|(_, (at, _))| *at <= now).map(|(d, _)| d.clone()).collect();
        for device in due {
            if let Some((_, copies)) = self.held.remove(&device) {
                self.outbox.push(&device, copies.into_iter().map(Paced::Kept), now);
            }
        }
        self.outbox.ready(now)
    }

    /// Everything not yet sent to `device`, held copies first; with `sealed_only`, what
    /// needs its Olm session, and plain frames keep their place and pace.
    pub(crate) fn take_back(&mut self, device: &str, sealed_only: bool) -> Vec<Paced> {
        let mut items: Vec<Paced> =
            self.held.remove(device).map(|(_, copies)| copies).unwrap_or_default().into_iter().map(Paced::Kept).collect();
        items.extend(self.outbox.take(device, sealed_only));
        items
    }

    /// Every DM envelope not yet sent, so an edit or a late card rewrites them in place.
    pub(crate) fn entries_mut(&mut self) -> impl Iterator<Item = &mut String> {
        self.held.values_mut().flat_map(|(_, copies)| copies.iter_mut()).chain(
            self.outbox.lanes.values_mut().flat_map(|lane| {
                lane.items.iter_mut().filter_map(|item| match item {
                    Paced::Kept(json) => Some(json),
                    _ => None,
                })
            }),
        )
    }

    /// TEST-ONLY: record a message the Olm lane aimed at `device`.
    #[cfg(test)]
    pub(crate) fn note_carried(&mut self, device: &str, json: &str) {
        self.carried.push((device.to_string(), json.to_string()));
    }

    /// TEST-ONLY: every message the Olm lane aimed at a device, in order.
    #[cfg(test)]
    pub(crate) fn carried(&self) -> Vec<(String, String)> {
        self.carried.clone()
    }
}

/// An ask of ours that rides `device`'s Olm session: paced to fit its bucket, or
/// carried at once to one of our own devices, which never limit us. `us` is any id
/// of ours.
pub(crate) fn pace_carried(
    budget: &mut FrameBudget,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    us: &str,
    device: &str,
    msg: &HavenMessage,
) {
    if super::resolver::same_identity(device, us) {
        super::olm_lane::carry(ws_cmd_tx, device, None, msg, super::olm_lane::NoSession::Queue);
    } else if let Some(item) = Paced::carried(msg) {
        budget.pace(device, item, Instant::now());
    }
}

/// [`pace_carried`] for a frame the relay may read.
pub(crate) fn pace_plain(
    budget: &mut FrameBudget,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    us: &str,
    device: &str,
    msg: &HavenMessage,
) {
    if super::resolver::same_identity(device, us) {
        super::crypto_handler::send_message_to_peer(ws_cmd_tx, ws_room_peers, device, msg.clone());
    } else if let Some(item) = Paced::plain(msg) {
        budget.pace(device, item, Instant::now());
    }
}

/// [`pace_plain`] to `peer` and every other online device of its identity, whom
/// `crypto_handler::send_key_package_to_identity_of` sends a KeyPackage.
pub(crate) fn pace_plain_to_identity_of(
    budget: &mut FrameBudget,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    us: &str,
    peer: &str,
    msg: &HavenMessage,
) {
    for device in super::crypto_handler::online_devices_for(ws_room_peers, peer) {
        if device != peer {
            pace_plain(budget, ws_cmd_tx, ws_room_peers, us, &device, msg);
        }
    }
    pace_plain(budget, ws_cmd_tx, ws_room_peers, us, peer, msg);
}

/// Put `items` back at the front of `device`'s pending queue, ahead of anything queued
/// since they left it.
pub(crate) fn requeue(pending_messages: &mut HashMap<String, Vec<String>>, device: &str, mut items: Vec<String>) {
    if items.is_empty() {
        return;
    }
    items.extend(pending_messages.remove(device).unwrap_or_default());
    pending_messages.insert(device.to_string(), items);
}

/// Send what the budget allows now. A device we can no longer reach (it left, or our
/// session with the relay did), or hold no Olm session with, gets its kept envelopes
/// back in its pending queue for its next return and loses its answers; its plain
/// frames go on at their pace while we share a room. A blocked device loses all.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn pump(
    budget: &mut FrameBudget,
    olm: &mut crate::crypto::OlmManager,
    crypto_store: &crate::crypto::CryptoStore,
    event_tx: &tokio::sync::mpsc::Sender<super::types::NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
) {
    // Boxed: awaited from the swarm's event loop, whose future is near the worker stack.
    Box::pin(pump_inner(budget, olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers, pending_messages)).await
}

#[allow(clippy::too_many_arguments)]
async fn pump_inner(
    budget: &mut FrameBudget,
    olm: &mut crate::crypto::OlmManager,
    crypto_store: &crate::crypto::CryptoStore,
    event_tx: &tokio::sync::mpsc::Sender<super::types::NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    pending_messages: &mut HashMap<String, Vec<String>>,
) {
    for (device, items) in budget.ready(Instant::now()) {
        if super::blocklist::is_blocked(&device) {
            let dropped = items.len() + budget.take_back(&device, false).len();
            hollow_log!("[HOLLOW-FRIENDS] Dropped {dropped} queued message(s) for blocked {device}");
            continue;
        }
        let room = super::crypto_handler::send_room_for_peer(ws_room_peers, &device);
        if room.is_some() && olm.has_session(&device) {
            for item in items {
                match item {
                    Paced::Kept(text) | Paced::Answer(text) => {
                        super::crypto_handler::send_encrypted_message(
                            olm, crypto_store, &device, &text, event_tx, ws_cmd_tx, ws_room_peers,
                        )
                        .await;
                    }
                    Paced::Plain(data) => send_plain(ws_cmd_tx, room.as_deref(), &device, data),
                }
            }
            continue;
        }
        let rest = budget.take_back(&device, room.is_some());
        let (mut back, mut lost) = (Vec::new(), 0usize);
        for item in items.into_iter().chain(rest) {
            match item {
                Paced::Kept(text) => back.push(text),
                Paced::Plain(data) if room.is_some() => send_plain(ws_cmd_tx, room.as_deref(), &device, data),
                Paced::Answer(_) | Paced::Plain(_) => lost += 1,
            }
        }
        if lost > 0 {
            hollow_log!("[HOLLOW-SYNC] {device} is out of reach: {lost} paced answer(s) or plain frame(s) lost, asked again on its return");
        }
        requeue(pending_messages, &device, back);
    }
}

fn send_plain(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    room: Option<&str>,
    device: &str,
    data: Vec<u8>,
) {
    if let Some(room) = room {
        let _ = ws_cmd_tx.send(super::ws_client::WsCommand::SendDirect {
            room_code: room.to_string(),
            target_peer: device.to_string(),
            data,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(base: Instant, ms: u64) -> Instant {
        base + Duration::from_millis(ms)
    }

    fn dm(mid: &str) -> String {
        serde_json::to_string(&MessageEnvelope::DirectMessage {
            inner: Box::new(super::super::types::DirectMessagePayload {
                text: "hi".into(),
                ts: 1,
                sig: None,
                pk: None,
                mid: Some(mid.into()),
                reply_to: None,
                file_id: None,
                link_preview: None,
                convo: None,
                order_us: None,
                album: None,
            }),
        })
        .unwrap()
    }

    fn other(n: u32) -> String {
        serde_json::to_string(&MessageEnvelope::SessionAck).unwrap() + &" ".repeat(n as usize)
    }

    fn texts(items: impl IntoIterator<Item = Paced>) -> Vec<String> {
        items
            .into_iter()
            .map(|item| match item {
                Paced::Kept(text) | Paced::Answer(text) => text,
                Paced::Plain(_) => panic!("a plain frame"),
            })
            .collect()
    }

    #[test]
    fn the_bucket_admits_its_burst_then_its_refill() {
        let t0 = Instant::now();
        let mut l = Limiter::default();
        let admitted = (0..300).filter(|_| l.admit("p", t0) == Admission::Admitted).count();
        assert_eq!(admitted, BURST as usize, "a burst at one instant gets the bucket");
        let later = (0..300).filter(|_| l.admit("p", at(t0, 1000)) == Admission::Admitted).count();
        assert_eq!(later, REFILL_PER_SEC as usize, "a second later, one second of refill");
        assert_eq!(l.admit("q", t0), Admission::Admitted, "each sender has its own bucket");
    }

    #[test]
    fn a_flood_is_one_repair_and_only_once_it_stops() {
        let t0 = Instant::now();
        let mut l = Limiter::default();
        let mut firsts = 0;
        // 40 frames a second for ten seconds: twice the refill.
        for ms in (0..10_000).step_by(25) {
            if l.admit("p", at(t0, ms)) == (Admission::Dropped { first: true }) {
                firsts += 1;
            }
            assert!(l.due_repairs(at(t0, ms)).is_empty(), "a repair while the flood goes on, at {ms} ms");
        }
        assert_eq!(firsts, 1, "one drop episode, however many frames");
        assert!(l.due_repairs(at(t0, 12_000)).is_empty(), "two seconds of quiet refill 40 of 100");
        let due = l.due_repairs(at(t0, 15_100));
        assert_eq!(due.len(), 1, "a full bucket asks once");
        assert!(due[0].1 >= 50, "the count names every dropped frame: {}", due[0].1);
        assert!(l.due_repairs(at(t0, 16_000)).is_empty(), "the repair is not repeated");
        assert!(l.due_repairs(at(t0, 50_000)).is_empty(), "nothing dropped since, nothing asked past the cooldown");
    }

    #[test]
    fn a_second_flood_inside_the_cooldown_waits_for_it() {
        let t0 = Instant::now();
        let mut l = Limiter::default();
        for _ in 0..150 {
            l.admit("p", t0);
        }
        assert_eq!(l.due_repairs(at(t0, 6_000)).len(), 1, "the first episode is repaired");
        for _ in 0..150 {
            l.admit("p", at(t0, 7_000));
        }
        assert!(l.due_repairs(at(t0, 13_000)).is_empty(), "a refilled bucket inside the cooldown waits");
        assert_eq!(l.due_repairs(at(t0, 36_000)).len(), 1, "after the cooldown the second episode is repaired");
    }

    #[test]
    fn forgetting_an_idle_sender_forgets_its_repair() {
        let t0 = Instant::now();
        let mut l = Limiter::default();
        for _ in 0..150 {
            l.admit("p", t0);
        }
        l.forget_idle(Duration::from_secs(300), at(t0, 301_000));
        assert!(l.due_repairs(at(t0, 302_000)).is_empty());
    }

    #[test]
    fn the_outbox_sends_a_fifth_of_the_bucket_then_half_its_refill() {
        let t0 = Instant::now();
        let mut b = FrameBudget::default();
        b.send_now("d", (0..200).map(other).collect(), t0);
        let first: usize = b.ready(t0).iter().map(|(_, items)| items.len()).sum();
        assert_eq!(first, PACE_BURST as usize);
        let second: usize = b.ready(at(t0, 1000)).iter().map(|(_, items)| items.len()).sum();
        assert_eq!(second, PACE_PER_SEC as usize);
        // A second drain right after the first gets no second burst.
        b.send_now("d", (0..50).map(other).collect(), at(t0, 1000));
        assert!(b.ready(at(t0, 1000)).is_empty());
        let mut sent = first + second;
        for s in 2..30 {
            let n: usize = b.ready(at(t0, s * 1000)).iter().map(|(_, items)| items.len()).sum();
            assert!(n <= PACE_PER_SEC as usize, "{n} in one second");
            sent += n;
        }
        assert_eq!(sent, 250, "everything goes in the end");
    }

    #[test]
    fn dm_copies_wait_out_the_hold_and_the_rest_goes_at_once() {
        let t0 = Instant::now();
        let mut b = FrameBudget::default();
        b.welcome_back("d", vec![dm("m1"), other(1), dm("m2")], t0);
        let now = texts(b.ready(t0).into_iter().flat_map(|(_, items)| items));
        assert_eq!(now, vec![other(1)], "only what the relay does not replay goes now");
        assert!(b.ready(at(t0, 5_900)).is_empty(), "the copies wait while the receiver's bucket refills");
        let later = texts(b.ready(at(t0, 6_000)).into_iter().flat_map(|(_, items)| items));
        assert_eq!(later, vec![dm("m1"), dm("m2")]);
    }

    #[test]
    fn a_second_return_starts_the_hold_again() {
        let t0 = Instant::now();
        let mut b = FrameBudget::default();
        b.welcome_back("d", vec![dm("m1")], t0);
        b.welcome_back("d", vec![dm("m2")], at(t0, 4_000));
        assert!(b.ready(at(t0, 6_000)).is_empty(), "the second return's replay is still under way");
        let later = texts(b.ready(at(t0, 10_000)).into_iter().flat_map(|(_, items)| items));
        assert_eq!(later, vec![dm("m1"), dm("m2")]);
    }

    #[test]
    fn take_back_returns_held_and_queued_in_order_ahead_of_newer_entries() {
        let t0 = Instant::now();
        let mut b = FrameBudget::default();
        let mut queued = vec![dm("m1")];
        queued.extend((0..30).map(other));
        b.welcome_back("d", queued, t0);
        assert_eq!(b.ready(t0).iter().map(|(_, items)| items.len()).sum::<usize>(), PACE_BURST as usize);
        let mut pending = HashMap::from([("d".to_string(), vec![dm("m9")])]);
        let back = texts(b.take_back("d", false));
        requeue(&mut pending, "d", back);
        let mut want = vec![dm("m1")];
        want.extend((20..30).map(other));
        want.push(dm("m9"));
        assert_eq!(pending["d"], want, "held, then unsent, then what was queued since");
        assert!(b.take_back("d", false).is_empty());
    }

    #[tokio::test]
    async fn a_device_out_of_reach_gets_its_envelopes_back_in_its_queue() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("budget.db").to_string_lossy().into_owned();
        let crypto_store = crate::crypto::CryptoStore::open(path, "ab".repeat(32)).unwrap();
        let mut olm = crate::crypto::OlmManager::new();
        let (event_tx, _event_rx) = tokio::sync::mpsc::channel(8);
        let (ws_cmd_tx, mut ws_cmd_rx) = tokio::sync::mpsc::unbounded_channel();
        let t0 = Instant::now();
        let mut b = FrameBudget::default();
        let mut queued = vec![dm("m1")];
        queued.extend((0..30).map(other));
        b.welcome_back("d", queued, t0);
        let mut pending = HashMap::from([("d".to_string(), vec![dm("m9")])]);
        // Neither in a room with us nor holding a session: nothing can go.
        pump(&mut b, &mut olm, &crypto_store, &event_tx, &ws_cmd_tx, &HashMap::new(), &mut pending).await;
        let mut want: Vec<String> = (0..20).map(other).collect();
        want.push(dm("m1"));
        want.extend((20..30).map(other));
        want.push(dm("m9"));
        assert_eq!(pending["d"], want, "every envelope back, ahead of what was queued since");
        assert!(b.take_back("d", false).is_empty());
        assert!(ws_cmd_rx.try_recv().is_err(), "nothing went out");
    }

    #[test]
    fn entries_mut_reaches_held_and_queued_envelopes() {
        let t0 = Instant::now();
        let mut b = FrameBudget::default();
        b.welcome_back("d", vec![dm("m1")], t0);
        let mut queued: Vec<String> = (0..20).map(other).collect();
        queued.push(dm("m2"));
        b.send_now("e", queued, t0);
        let sent: usize = b.ready(t0).iter().map(|(_, items)| items.len()).sum();
        assert_eq!(sent, PACE_BURST as usize, "m2 is left in the outbox");
        let mut left: Vec<String> = b.entries_mut().map(|e| e.clone()).collect();
        left.sort();
        assert_eq!(left, vec![dm("m1"), dm("m2")]);
    }

    fn ask(n: u32) -> Paced {
        Paced::Kept(format!("ask {n}"))
    }

    #[test]
    fn paced_asks_wait_their_turn_and_leave_the_hold_alone() {
        let t0 = Instant::now();
        let mut b = FrameBudget::default();
        b.welcome_back("d", vec![dm("m1"), other(1)], t0);
        for n in 0..30 {
            b.pace("d", ask(n), t0);
        }
        let first = texts(b.ready(t0).into_iter().flat_map(|(_, items)| items));
        let mut want = vec![other(1)];
        want.extend((0..19).map(|n| format!("ask {n}")));
        assert_eq!(first, want, "a fifth of the bucket, in the order it was paced, the held copy still held");
        let mut sent = first.len();
        for s in 1..=5 {
            sent += b.ready(at(t0, s * 1000)).iter().map(|(_, items)| items.len()).sum::<usize>();
        }
        assert_eq!(sent, 31, "the asks go at the lane's pace while the copy waits out its hold");
        let later = texts(b.ready(at(t0, 6_000)).into_iter().flat_map(|(_, items)| items));
        assert_eq!(later, vec![dm("m1")]);
    }

    #[tokio::test]
    async fn a_device_out_of_reach_keeps_its_asks_and_loses_its_answers_and_plain_frames() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("budget.db").to_string_lossy().into_owned();
        let crypto_store = crate::crypto::CryptoStore::open(path, "ab".repeat(32)).unwrap();
        let mut olm = crate::crypto::OlmManager::new();
        let (event_tx, _event_rx) = tokio::sync::mpsc::channel(8);
        let (ws_cmd_tx, mut ws_cmd_rx) = tokio::sync::mpsc::unbounded_channel();
        let t0 = Instant::now();
        let mut b = FrameBudget::default();
        for n in 0..25 {
            b.pace("d", ask(n), t0);
            b.pace("d", Paced::Answer(format!("answer {n}")), t0);
            b.pace("d", Paced::Plain(vec![n as u8]), t0);
        }
        let mut pending = HashMap::new();
        pump(&mut b, &mut olm, &crypto_store, &event_tx, &ws_cmd_tx, &HashMap::new(), &mut pending).await;
        let want: Vec<String> = (0..25).map(|n| format!("ask {n}")).collect();
        assert_eq!(pending["d"], want, "every ask back in its queue, in order");
        assert!(b.take_back("d", false).is_empty(), "the answers and plain frames are gone");
        assert!(ws_cmd_rx.try_recv().is_err(), "nothing went out");
    }

    #[tokio::test]
    async fn a_device_without_a_session_still_gets_its_plain_frames_at_their_pace() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("budget.db").to_string_lossy().into_owned();
        let crypto_store = crate::crypto::CryptoStore::open(path, "ab".repeat(32)).unwrap();
        let mut olm = crate::crypto::OlmManager::new();
        let (event_tx, _event_rx) = tokio::sync::mpsc::channel(8);
        let (ws_cmd_tx, mut ws_cmd_rx) = tokio::sync::mpsc::unbounded_channel();
        let rooms = HashMap::from([("room".to_string(), std::collections::HashSet::from(["d".to_string()]))]);
        let t0 = Instant::now();
        let mut b = FrameBudget::default();
        b.pace("d", ask(0), t0);
        b.pace("d", Paced::Answer("answer".into()), t0);
        for n in 0..40u8 {
            b.pace("d", Paced::Plain(vec![n]), t0);
        }
        let mut pending = HashMap::new();
        pump(&mut b, &mut olm, &crypto_store, &event_tx, &ws_cmd_tx, &rooms, &mut pending).await;
        let mut sent = Vec::new();
        while let Ok(cmd) = ws_cmd_rx.try_recv() {
            if let super::super::ws_client::WsCommand::SendDirect { room_code, target_peer, data } = cmd {
                assert_eq!((room_code.as_str(), target_peer.as_str()), ("room", "d"));
                sent.push(data[0]);
            }
        }
        assert_eq!(sent, (0..18).collect::<Vec<u8>>(), "the plain frames of the first burst, nothing past it");
        assert_eq!(pending["d"], vec!["ask 0".to_string()], "the ask waits for a session");
        let rest: Vec<Paced> = b.take_back("d", false);
        assert_eq!(rest, (18..40).map(|n| Paced::Plain(vec![n])).collect::<Vec<_>>(), "the rest keep their place");
    }

    #[test]
    fn our_own_devices_skip_the_pace_and_a_friends_devices_wait_in_their_lanes() {
        use super::super::ws_client::WsCommand;
        let _lock = super::super::resolver::test_lock();
        super::super::resolver::update("pace-sibling", "pace-me");
        super::super::resolver::update("pace-friend-a", "pace-friend");
        super::super::resolver::update("pace-friend-b", "pace-friend");
        let in_room = ["pace-sibling", "pace-friend-a", "pace-friend-b"].map(String::from);
        let rooms = HashMap::from([("room".to_string(), std::collections::HashSet::from(in_room))]);
        let (ws_cmd_tx, mut ws_cmd_rx) = tokio::sync::mpsc::unbounded_channel();
        let mut b = FrameBudget::default();
        let ask = HavenMessage::SyncRequest { server_id: "s".into(), state_vector_json: "{}".into(), mls_epoch: None, nonce: None };
        let key_ask = HavenMessage::MlsKeyPackageRequest { server_id: "s".into(), channel_id: None };
        pace_carried(&mut b, &ws_cmd_tx, "pace-me", "pace-friend-a", &ask);
        pace_carried(&mut b, &ws_cmd_tx, "pace-me", "pace-sibling", &ask);
        pace_plain(&mut b, &ws_cmd_tx, &rooms, "pace-me", "pace-sibling", &key_ask);
        pace_plain_to_identity_of(&mut b, &ws_cmd_tx, &rooms, "pace-me", "pace-friend-a", &key_ask);

        let mut at_once = Vec::new();
        while let Ok(cmd) = ws_cmd_rx.try_recv() {
            at_once.push(match cmd {
                WsCommand::Carry { device, .. } => format!("carry {device}"),
                WsCommand::SendDirect { target_peer, .. } => format!("direct {target_peer}"),
                other => panic!("unexpected {other:?}"),
            });
        }
        assert_eq!(at_once, ["carry pace-sibling", "direct pace-sibling"], "only our own device skips the pace");
        let mut lanes: Vec<(String, Vec<&'static str>)> = b
            .ready(Instant::now())
            .into_iter()
            .map(|(device, items)| {
                let kinds = items.iter().map(|item| if matches!(item, Paced::Plain(_)) { "plain" } else { "olm" }).collect();
                (device, kinds)
            })
            .collect();
        lanes.sort();
        assert_eq!(
            lanes,
            vec![("pace-friend-a".to_string(), vec!["olm", "plain"]), ("pace-friend-b".to_string(), vec!["plain"])],
            "the friend's asks wait in its lanes, a KeyPackage ask in every device's",
        );
    }

    #[test]
    fn entries_mut_reaches_only_what_may_be_rewritten() {
        let t0 = Instant::now();
        let mut b = FrameBudget::default();
        b.pace("d", Paced::Kept(dm("m1")), t0);
        b.pace("d", Paced::Answer(dm("m2")), t0);
        b.pace("d", Paced::Plain(b"plain".to_vec()), t0);
        let left: Vec<String> = b.entries_mut().map(|e| e.clone()).collect();
        assert_eq!(left, vec![dm("m1")]);
    }
}
