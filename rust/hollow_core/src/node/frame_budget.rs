//! Per-peer frame budgets. Every node takes a sender device's frames through one
//! bucket; what the bucket drops is asked for again from that sender once the bucket
//! has refilled. Our own catch-up bulk to one device goes paced against the same
//! numbers, so a well-behaved sender stays inside the receiver's bucket.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use super::types::MessageEnvelope;

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

struct Lane {
    items: VecDeque<String>,
    tokens: f64,
    last: Instant,
}

/// Queued Olm envelopes per device and the pace each device's go out at.
#[derive(Default)]
struct Outbox {
    lanes: HashMap<String, Lane>,
}

impl Outbox {
    fn push(&mut self, device: &str, items: Vec<String>, now: Instant) {
        if items.is_empty() {
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
    fn ready(&mut self, now: Instant) -> Vec<(String, Vec<String>)> {
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

    fn take(&mut self, device: &str) -> Vec<String> {
        self.lanes.get_mut(device).map(|lane| lane.items.drain(..).collect()).unwrap_or_default()
    }
}

/// What a node owes the devices it sends Olm envelopes to in bulk, and the inbound
/// limiter that stands for theirs.
#[derive(Default)]
pub(crate) struct FrameBudget {
    pub(crate) limiter: Limiter,
    outbox: Outbox,
    /// Device -> (when its DM copies go, the copies).
    held: HashMap<String, (Instant, Vec<String>)>,
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
        self.outbox.push(device, rest, now);
    }

    /// Everything waiting for `device`, paced from now, held copies first.
    pub(crate) fn send_now(&mut self, device: &str, queued: Vec<String>, now: Instant) {
        let mut items = self.held.remove(device).map(|(_, copies)| copies).unwrap_or_default();
        items.extend(queued);
        self.outbox.push(device, items, now);
    }

    /// What may go out now, per device.
    pub(crate) fn ready(&mut self, now: Instant) -> Vec<(String, Vec<String>)> {
        let due: Vec<String> = self.held.iter().filter(|(_, (at, _))| *at <= now).map(|(d, _)| d.clone()).collect();
        for device in due {
            if let Some((_, copies)) = self.held.remove(&device) {
                self.outbox.push(&device, copies, now);
            }
        }
        self.outbox.ready(now)
    }

    /// Everything not yet sent to `device`, held copies first.
    pub(crate) fn take_back(&mut self, device: &str) -> Vec<String> {
        let mut items = self.held.remove(device).map(|(_, copies)| copies).unwrap_or_default();
        items.extend(self.outbox.take(device));
        items
    }

    /// Every envelope not yet sent, so an edit or a late card rewrites them in place.
    pub(crate) fn entries_mut(&mut self) -> impl Iterator<Item = &mut String> {
        self.held
            .values_mut()
            .flat_map(|(_, copies)| copies.iter_mut())
            .chain(self.outbox.lanes.values_mut().flat_map(|lane| lane.items.iter_mut()))
    }
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
/// session with the relay did), or hold no Olm session with, gets its envelopes back in
/// its pending queue for its next return; a blocked one loses them.
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
            let dropped = items.len() + budget.take_back(&device).len();
            hollow_log!("[HOLLOW-FRIENDS] Dropped {dropped} queued message(s) for blocked {device}");
            continue;
        }
        if super::crypto_handler::send_room_for_peer(ws_room_peers, &device).is_none() || !olm.has_session(&device) {
            let mut back = items;
            back.extend(budget.take_back(&device));
            requeue(pending_messages, &device, back);
            continue;
        }
        for text in items {
            super::crypto_handler::send_encrypted_message(
                olm, crypto_store, &device, &text, event_tx, ws_cmd_tx, ws_room_peers,
            )
            .await;
        }
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
        let now: Vec<String> = b.ready(t0).into_iter().flat_map(|(_, items)| items).collect();
        assert_eq!(now, vec![other(1)], "only what the relay does not replay goes now");
        assert!(b.ready(at(t0, 5_900)).is_empty(), "the copies wait while the receiver's bucket refills");
        let later: Vec<String> = b.ready(at(t0, 6_000)).into_iter().flat_map(|(_, items)| items).collect();
        assert_eq!(later, vec![dm("m1"), dm("m2")]);
    }

    #[test]
    fn a_second_return_starts_the_hold_again() {
        let t0 = Instant::now();
        let mut b = FrameBudget::default();
        b.welcome_back("d", vec![dm("m1")], t0);
        b.welcome_back("d", vec![dm("m2")], at(t0, 4_000));
        assert!(b.ready(at(t0, 6_000)).is_empty(), "the second return's replay is still under way");
        let later: Vec<String> = b.ready(at(t0, 10_000)).into_iter().flat_map(|(_, items)| items).collect();
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
        let back = b.take_back("d");
        requeue(&mut pending, "d", back);
        let mut want = vec![dm("m1")];
        want.extend((20..30).map(other));
        want.push(dm("m9"));
        assert_eq!(pending["d"], want, "held, then unsent, then what was queued since");
        assert!(b.take_back("d").is_empty());
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
        assert!(b.take_back("d").is_empty());
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
}
