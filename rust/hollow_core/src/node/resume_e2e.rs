//! The real `ws_client` against the real relay, with B's path through the zombie
//! proxy (`tools/zombie_proxy`) frozen for a window and then thawed or dropped,
//! counting every frame A and B send each other across it, per frame kind
//! (RESUMABLE_SESSIONS_PLAN.md section 6). `scripts/resume_e2e.sh` starts the relay
//! and the proxy and runs the ignored test with:
//!
//! | variable | |
//! |---|---|
//! | `HOLLOW_E2E_URL_A`, `HOLLOW_E2E_URL_B` | the proxy routes A and B dial (`ws://`) |
//! | `HOLLOW_E2E_PROXY_CTL`, `HOLLOW_E2E_ROUTE_B` | the proxy's control address, B's route |
//! | `HOLLOW_E2E_WINDOW_SECS` | how long B's path stays frozen |
//! | `HOLLOW_E2E_END` | `thaw` or `drop` when the window ends |
//! | `HOLLOW_E2E_RATE` | frames per second of each kind, each way |
//! | `HOLLOW_E2E_KINDS` | `direct,broadcast,topic,chunk` (the default) or a subset |
//! | `HOLLOW_E2E_KEEP_SESSION` | `1`: the window is inside the relay's grace, so B must not lose its session |
//! | `HOLLOW_E2E_OPTIN` | `1`: B opts in to offline delivery (the relay keeps 500 DMs for it, not 100) |
//! | `HOLLOW_E2E_MID_WINDOW_CMD`, `HOLLOW_E2E_MID_WINDOW_SECS` | a shell command run that far into the window (a relay restart) |
//! | `HOLLOW_E2E_SETTLE_SECS` | how long stragglers may take |
//! | `HOLLOW_E2E_REPORT` | where the JSON result goes |
//! | `HOLLOW_DATA_DIR` | a scratch directory (required) |
//!
//! While B keeps its session (the socket survives, or it resumes) nothing may be lost
//! in either direction. Once the relay gives the session up, B's own frames still
//! all arrive (its outbound queue outlives the session), but toward B only the direct
//! kind has a transport fallback, `offline_buffer`, which keeps the newest frames up
//! to its cap; the other kinds are the node's gap repair's (`Kind::past_grace`). Every
//! kind sent once B is back (`Phase::Back`) arrives either way.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

use super::ws_client::{spawn_ws_client, WsCommand, WsEvent};
use crate::identity::native_identity::NativeKeypair;

/// The topic the topic kind rides; B subscribes to nothing, so it hears every topic.
const TOPIC: &str = "e2e";
/// How long nothing may arrive, once B is back, before the stragglers are given up.
const QUIET: Duration = Duration::from_secs(20);
/// `offline_buffer`'s DM text caps (relay `state.h`).
const OFFLINE_CAP: usize = 100;
const OFFLINE_CAP_OPTED_IN: usize = 500;

/// When a frame was sent: before the window, during it, after it while B is still
/// away, or once B is back (`Back`, which every kind must reach whatever the session).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Before = 0,
    During = 1,
    After = 2,
    Back = 3,
}

impl Phase {
    const ALL: [Phase; 4] = [Phase::Before, Phase::During, Phase::After, Phase::Back];

    fn name(self) -> &'static str {
        match self {
            Phase::Before => "before",
            Phase::During => "during",
            Phase::After => "after",
            Phase::Back => "back",
        }
    }

    fn from_u8(value: u8) -> Phase {
        match value {
            0 => Phase::Before,
            1 => Phase::During,
            2 => Phase::After,
            _ => Phase::Back,
        }
    }
}

/// How long after B is back its rooms are surely joined again: frames sent from then on
/// are `Phase::Back`.
const REJOINED: Duration = Duration::from_secs(1);

/// The frame kinds that cross the relay, each sent the way the app sends it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Kind {
    /// 0x04 up, 0x06 down: every DM, sync answer and Olm carry (`olm_lane`).
    Direct,
    /// 0x03 up, 0x05 down: a room broadcast (CRDT ops, server traffic).
    Broadcast,
    /// 0x07 up, 0x08 down: a channel topic frame.
    Topic,
    /// 0x02 both ways: a file or shard chunk.
    Chunk,
}

impl Kind {
    const ALL: [Kind; 4] = [Kind::Direct, Kind::Broadcast, Kind::Topic, Kind::Chunk];

    fn name(self) -> &'static str {
        match self {
            Kind::Direct => "direct",
            Kind::Broadcast => "broadcast",
            Kind::Topic => "topic",
            Kind::Chunk => "chunk",
        }
    }

    fn parse(name: &str) -> Option<Kind> {
        Kind::ALL.into_iter().find(|k| k.name() == name)
    }

    fn command(self, room: &str, target: &str, data: Vec<u8>) -> WsCommand {
        let room_code = room.to_string();
        let target_peer = target.to_string();
        match self {
            Kind::Direct => WsCommand::SendDirect { room_code, target_peer, data },
            Kind::Broadcast => WsCommand::SendToRoom { room_code, data },
            Kind::Topic => WsCommand::SendToRoomTopic { room_code, topic: TOPIC.into(), data },
            Kind::Chunk => WsCommand::SendBinaryDirect { room_code, target_peer, data },
        }
    }

    fn arrives_as(self, event: &WsEvent) -> bool {
        matches!(
            (self, event),
            (Kind::Direct, WsEvent::DirectMessage { .. })
                | (Kind::Broadcast | Kind::Topic, WsEvent::Message { .. })
                | (Kind::Chunk, WsEvent::BinaryDirect { .. })
        )
    }

    /// What brings a frame of this kind to a device whose session the relay gave up:
    /// on expiry only the 0x06 frames move to `offline_buffer` (section 9.7).
    fn past_grace(self) -> &'static str {
        match self {
            Kind::Direct => "offline_buffer (its newest 100, 500 opted in), replayed on the room join; then DM sync",
            Kind::Broadcast => "nothing at the transport: the node's server and channel sync",
            Kind::Topic => "the server's topic ring where its owner registered one, else the node's channel sync",
            Kind::Chunk => "nothing at the transport: file_asks pulls the file again",
        }
    }
}

/// One kind's frames in one direction, by sequence number: when each was sent, when
/// it first arrived.
#[derive(Default)]
struct Ledger {
    sent: BTreeMap<u64, Phase>,
    arrived: BTreeMap<u64, u64>,
    duplicates: u64,
    out_of_order: u64,
    /// Arrived as another event than its kind's.
    wrong_event: u64,
    highest: u64,
}

impl Ledger {
    fn record_sent(&mut self, seq: u64, phase: Phase) {
        self.sent.insert(seq, phase);
    }

    fn record_arrival(&mut self, seq: u64, at_ms: u64) {
        if self.arrived.contains_key(&seq) {
            self.duplicates += 1;
            return;
        }
        if seq < self.highest {
            self.out_of_order += 1;
        }
        self.highest = self.highest.max(seq);
        self.arrived.insert(seq, at_ms);
    }

    /// Sent and never arrived. A duplicate never hides a gap, and an arrival
    /// nobody recorded sending is not a loss.
    fn lost(&self) -> Vec<u64> {
        self.sent.keys().filter(|seq| !self.arrived.contains_key(seq)).copied().collect()
    }

    fn lost_in(&self, phase: Phase) -> usize {
        self.lost().iter().filter(|seq| self.sent.get(seq) == Some(&phase)).count()
    }

    /// The loss a full offline buffer explains: one run, and at least `kept` frames
    /// after it arrived, because the buffer drops its oldest frames and only those.
    fn lost_only_oldest(&self, kept: usize) -> Result<(), String> {
        let lost = self.lost();
        let (Some(&first), Some(&last)) = (lost.first(), lost.last()) else { return Ok(()) };
        if last - first + 1 != lost.len() as u64 {
            return Err(format!("lost {} is more than one run", ranges(&lost)));
        }
        let after = self.arrived.keys().filter(|seq| **seq > last).count();
        if after < kept {
            return Err(format!("only {after} frames after the lost run {first}-{last} arrived, the buffer keeps {kept}"));
        }
        Ok(())
    }

    fn report(&self, window_end_ms: u64) -> serde_json::Value {
        let lost = self.lost();
        let by_phase: serde_json::Map<String, serde_json::Value> = Phase::ALL
            .iter()
            .map(|p| {
                let sent = self.sent.values().filter(|s| *s == p).count();
                (p.name().to_string(), serde_json::json!({ "sent": sent, "lost": self.lost_in(*p) }))
            })
            .collect();
        let first_after = self.arrived.values().filter(|ms| **ms >= window_end_ms).min().copied();
        serde_json::json!({
            "sent": self.sent.len(),
            "received": self.arrived.len(),
            "lost": lost.len(),
            "missing": ranges(&lost),
            "duplicates": self.duplicates,
            "out_of_order": self.out_of_order,
            "wrong_event": self.wrong_event,
            "by_phase": by_phase,
            "first_arrival_after_window_ms": first_after.map(|ms| ms - window_end_ms),
            "last_arrival_ms": self.arrived.values().max().copied(),
        })
    }
}

type Ledgers = Arc<Mutex<BTreeMap<Kind, Ledger>>>;

fn ledgers(kinds: &[Kind]) -> Ledgers {
    Arc::new(Mutex::new(kinds.iter().map(|k| (*k, Ledger::default())).collect()))
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// `1,2,3,7` as `1-3,7`.
fn ranges(values: &[u64]) -> String {
    let mut parts = Vec::new();
    let mut iter = values.iter().copied().peekable();
    while let Some(start) = iter.next() {
        let mut end = start;
        while iter.peek() == Some(&(end + 1)) {
            end = iter.next().unwrap_or(end);
        }
        parts.push(if start == end { start.to_string() } else { format!("{start}-{end}") });
    }
    parts.join(",")
}

/// The kind and sequence number of one of this run's frames in direction `dir`.
fn parse_frame(data: &[u8], run: &str, dir: &str) -> Option<(Kind, u64)> {
    let text = std::str::from_utf8(data).ok()?;
    let (kind, seq) = text.strip_prefix(&format!("e2e:{run}:{dir}:"))?.split_once(':')?;
    Some((Kind::parse(kind)?, seq.parse().ok()?))
}

fn frame(run: &str, dir: &str, kind: Kind, seq: u64) -> Vec<u8> {
    format!("e2e:{run}:{dir}:{}:{seq}", kind.name()).into_bytes()
}

/// What happened to B's session after its path froze.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Outcome {
    /// The socket outlived the window.
    Kept,
    Resumed,
    /// The relay gave the session up; B started a fresh one.
    Lost,
}

impl Outcome {
    fn name(self) -> &'static str {
        match self {
            Outcome::Kept => "kept",
            Outcome::Resumed => "resumed",
            Outcome::Lost => "lost",
        }
    }
}

const LIFECYCLE: [&str; 5] = ["Connecting", "Connected", "Suspended", "Resumed", "SessionLost"];

/// B's session events from the window on, its outcome, and when it was back after the
/// window: the first `Resumed` or `Connected` at or after `window_end`.
fn session_of(timeline: &[serde_json::Value], window_start: u64, window_end: u64) -> (Outcome, Option<u64>, Vec<String>) {
    let mut outcome = Outcome::Kept;
    let mut back = None;
    let mut seen = Vec::new();
    for e in timeline {
        let (Some(side), Some(event), Some(ms)) = (e["side"].as_str(), e["event"].as_str(), e["ms"].as_u64()) else {
            continue;
        };
        if side != "b" || ms < window_start || !LIFECYCLE.contains(&event) {
            continue;
        }
        seen.push(format!("{event}@{ms}"));
        match event {
            "SessionLost" => outcome = Outcome::Lost,
            "Resumed" if outcome == Outcome::Kept => outcome = Outcome::Resumed,
            _ => {}
        }
        if back.is_none() && ms >= window_end && (event == "Resumed" || event == "Connected") {
            back = Some(ms - window_end);
        }
    }
    (outcome, back, seen)
}

/// When B could take frames again: the window's end if its socket outlived it, else
/// its first `Resumed` or `Connected` after it.
fn back_at(timeline: &[serde_json::Value], window_start: u64, window_end: u64) -> Option<u64> {
    let (_, back, events) = session_of(timeline, window_start, window_end);
    if !events.iter().any(|e| e.starts_with("Suspended@")) {
        return Some(window_end);
    }
    back.map(|ms| window_end + ms)
}

/// Every rule the outcome puts on the counts; empty when the run passed.
fn judge(
    outcome: Outcome,
    keep_session: bool,
    offline_cap: usize,
    a_to_b: &BTreeMap<Kind, Ledger>,
    b_to_a: &BTreeMap<Kind, Ledger>,
) -> Vec<String> {
    let mut failures = Vec::new();
    for (dir, ledgers) in [("A->B", a_to_b), ("B->A", b_to_a)] {
        for (kind, ledger) in ledgers {
            if ledger.wrong_event > 0 {
                failures.push(format!("{dir} {}: {} frames arrived as another event", kind.name(), ledger.wrong_event));
            }
        }
    }
    if outcome == Outcome::Lost && keep_session {
        failures.push("B lost its session inside the relay's grace window".into());
    }
    for (dir, ledgers) in [("A->B", a_to_b), ("B->A", b_to_a)] {
        for (kind, ledger) in ledgers {
            let lost = ledger.lost();
            if lost.is_empty() {
                continue;
            }
            let past_grace = outcome == Outcome::Lost && dir == "A->B";
            if !past_grace {
                failures.push(format!("{dir} {}: lost {} ({})", kind.name(), lost.len(), ranges(&lost)));
                continue;
            }
            let after_back = ledger.lost_in(Phase::Back);
            if after_back > 0 {
                failures.push(format!("{dir} {}: lost {after_back} sent after B was back", kind.name()));
            }
            if *kind == Kind::Direct
                && let Err(why) = ledger.lost_only_oldest(offline_cap)
            {
                failures.push(format!("{dir} direct past grace: {why}"));
            }
        }
    }
    failures
}

struct Config {
    url_a: String,
    url_b: String,
    proxy_ctl: String,
    route_b: String,
    window: Duration,
    end: String,
    rate: f64,
    kinds: Vec<Kind>,
    keep_session: bool,
    optin: bool,
    mid_window: Option<(Duration, String)>,
    before: Duration,
    after: Duration,
    settle: Duration,
    report: Option<String>,
}

impl Config {
    fn from_env() -> Config {
        let var = |name: &str| std::env::var(name).ok().filter(|v| !v.is_empty());
        let secs = |name: &str, default: f64| {
            Duration::from_secs_f64(var(name).and_then(|v| v.parse().ok()).unwrap_or(default))
        };
        let url_a = var("HOLLOW_E2E_URL_A").expect("HOLLOW_E2E_URL_A: run this through scripts/resume_e2e.sh");
        let url_b = var("HOLLOW_E2E_URL_B").expect("HOLLOW_E2E_URL_B: run this through scripts/resume_e2e.sh");
        let end = var("HOLLOW_E2E_END").unwrap_or_else(|| "thaw".into());
        assert!(end == "thaw" || end == "drop", "HOLLOW_E2E_END is thaw or drop, not {end}");
        let kinds: Vec<Kind> = match var("HOLLOW_E2E_KINDS") {
            Some(list) => list
                .split(',')
                .map(|k| Kind::parse(k.trim()).unwrap_or_else(|| panic!("HOLLOW_E2E_KINDS: no kind {k}")))
                .collect(),
            None => Kind::ALL.to_vec(),
        };
        Config {
            url_a,
            url_b,
            proxy_ctl: var("HOLLOW_E2E_PROXY_CTL").expect("HOLLOW_E2E_PROXY_CTL"),
            route_b: var("HOLLOW_E2E_ROUTE_B").unwrap_or_else(|| "b".into()),
            window: secs("HOLLOW_E2E_WINDOW_SECS", 5.0),
            end,
            rate: var("HOLLOW_E2E_RATE").and_then(|v| v.parse().ok()).unwrap_or(2.0),
            kinds,
            keep_session: var("HOLLOW_E2E_KEEP_SESSION").as_deref() == Some("1"),
            optin: var("HOLLOW_E2E_OPTIN").as_deref() == Some("1"),
            mid_window: var("HOLLOW_E2E_MID_WINDOW_CMD").map(|cmd| (secs("HOLLOW_E2E_MID_WINDOW_SECS", 0.0), cmd)),
            before: secs("HOLLOW_E2E_BEFORE_SECS", 3.0),
            after: secs("HOLLOW_E2E_AFTER_SECS", 5.0),
            settle: secs("HOLLOW_E2E_SETTLE_SECS", 120.0),
            report: var("HOLLOW_E2E_REPORT"),
        }
    }
}

struct Client {
    peer: String,
    cmd: mpsc::UnboundedSender<WsCommand>,
    events: mpsc::UnboundedReceiver<WsEvent>,
}

fn spawn_client(url: &str) -> Client {
    let mut secret = [0u8; 32];
    getrandom::fill(&mut secret).expect("random key");
    let keypair = NativeKeypair::from_secret_bytes(&secret);
    let proto = keypair.to_protobuf_encoding().expect("keypair encoding");
    let public = base64::engine::general_purpose::STANDARD.encode(keypair.public_key_protobuf());
    let (cmd, cmd_rx) = mpsc::unbounded_channel();
    let (event_tx, events) = mpsc::unbounded_channel();
    let peer = keypair.peer_id();
    spawn_ws_client(url.to_string(), peer.clone(), proto, public, None, false, cmd_rx, event_tx);
    Client { peer, cmd, events }
}

/// Reads events until one satisfies `want`; everything before it is dropped.
async fn wait_for_event(
    events: &mut mpsc::UnboundedReceiver<WsEvent>,
    within: Duration,
    what: &str,
    mut want: impl FnMut(&WsEvent) -> bool,
) {
    let found = tokio::time::timeout(within, async {
        while let Some(event) = events.recv().await {
            if want(&event) {
                return true;
            }
        }
        false
    })
    .await;
    assert!(matches!(found, Ok(true)), "waited {within:?} for {what}");
}

fn sees(event: &WsEvent, room: &str, peer: &str) -> bool {
    match event {
        WsEvent::RoomMembers { room: r, peers } => r == room && peers.iter().any(|p| p == peer),
        WsEvent::PeerJoined { room: r, peer_id } => r == room && peer_id == peer,
        _ => false,
    }
}

/// One proxy control command, its JSON answer.
async fn proxy(ctl: &str, line: &str) -> serde_json::Value {
    let stream = tokio::net::TcpStream::connect(ctl).await.expect("proxy control");
    let (read, mut write) = stream.into_split();
    write.write_all(format!("{line}\n").as_bytes()).await.expect("proxy write");
    let mut answer = String::new();
    BufReader::new(read).read_line(&mut answer).await.expect("proxy read");
    let value: serde_json::Value = serde_json::from_str(&answer).expect("proxy answer");
    assert_eq!(value["ok"], true, "the proxy refused {line}: {answer}");
    value
}

type Timeline = Arc<Mutex<Vec<serde_json::Value>>>;

/// Counts this run's frames into `ledgers` and every other event into the timeline.
fn spawn_receiver(
    mut events: mpsc::UnboundedReceiver<WsEvent>,
    side: &'static str,
    run: String,
    dir: &'static str,
    ledgers: Ledgers,
    timeline: Timeline,
    t0: Instant,
) {
    tokio::spawn(async move {
        while let Some(event) = events.recv().await {
            let ms = t0.elapsed().as_millis() as u64;
            match &event {
                WsEvent::DirectMessage { data, .. } | WsEvent::Message { data, .. } | WsEvent::BinaryDirect { data, .. } => {
                    if let Some((kind, seq)) = parse_frame(data, &run, dir) {
                        let mut all = lock(&ledgers);
                        if let Some(ledger) = all.get_mut(&kind) {
                            if !kind.arrives_as(&event) {
                                ledger.wrong_event += 1;
                            }
                            ledger.record_arrival(seq, ms);
                        }
                    }
                }
                WsEvent::RoomBudgetUpdate { .. } => {}
                other => {
                    let mut entry = serde_json::json!({ "ms": ms, "side": side, "event": other.kind() });
                    if let WsEvent::Resumed { gap } = other {
                        entry["gap"] = serde_json::Value::Bool(*gap);
                    }
                    lock(&timeline).push(entry);
                }
            }
        }
    });
}

#[allow(clippy::too_many_arguments)]
fn spawn_sender(
    cmd: mpsc::UnboundedSender<WsCommand>,
    kind: Kind,
    room: String,
    target: String,
    run: String,
    dir: &'static str,
    rate: f64,
    phase: Arc<AtomicU8>,
    stop: Arc<AtomicBool>,
    ledgers: Ledgers,
) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs_f64(1.0 / rate));
        // A stalled runtime (a loaded VM's clock) catches up, so every window carries
        // rate x duration frames and runs compare.
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Burst);
        let mut seq = 0u64;
        loop {
            tick.tick().await;
            if stop.load(Ordering::SeqCst) {
                break;
            }
            seq += 1;
            let now = Phase::from_u8(phase.load(Ordering::SeqCst));
            if let Some(ledger) = lock(&ledgers).get_mut(&kind) {
                ledger.record_sent(seq, now);
            }
            if cmd.send(kind.command(&room, &target, frame(&run, dir, kind, seq))).is_err() {
                break;
            }
        }
    });
}

fn reports(ledgers: &BTreeMap<Kind, Ledger>, window_end: u64) -> serde_json::Value {
    ledgers.iter().map(|(k, l)| (k.name().to_string(), l.report(window_end))).collect::<serde_json::Map<_, _>>().into()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "needs a relay and the zombie proxy: run scripts/resume_e2e.sh"]
async fn no_frame_is_lost_across_a_dead_path() {
    let data_dir = std::env::var("HOLLOW_DATA_DIR").unwrap_or_default();
    assert!(!data_dir.is_empty(), "HOLLOW_DATA_DIR must name a scratch directory");
    let cfg = Config::from_env();
    let run = format!("{:x}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis());
    let room = format!("e2e-{run}");

    let mut a = spawn_client(&cfg.url_a);
    let mut b = spawn_client(&cfg.url_b);
    wait_for_event(&mut a.events, Duration::from_secs(30), "A to connect", |e| matches!(e, WsEvent::Connected)).await;
    wait_for_event(&mut b.events, Duration::from_secs(30), "B to connect", |e| matches!(e, WsEvent::Connected)).await;
    a.cmd.send(WsCommand::JoinRoom { room_code: room.clone() }).expect("A join");
    wait_for_event(&mut a.events, Duration::from_secs(15), "A in the room", |e| {
        matches!(e, WsEvent::RoomMembers { room: r, .. } if *r == room)
    })
    .await;
    b.cmd.send(WsCommand::JoinRoom { room_code: room.clone() }).expect("B join");
    if cfg.optin {
        b.cmd.send(WsCommand::SetOfflineBuffer { enabled: true, retention_secs: 86_400 }).expect("B opt-in");
    }
    let b_peer = b.peer.clone();
    wait_for_event(&mut a.events, Duration::from_secs(15), "A to see B", |e| sees(e, &room, &b_peer)).await;
    let a_peer = a.peer.clone();
    wait_for_event(&mut b.events, Duration::from_secs(15), "B to see A", |e| sees(e, &room, &a_peer)).await;

    let t0 = Instant::now();
    let phase = Arc::new(AtomicU8::new(Phase::Before as u8));
    let stop = Arc::new(AtomicBool::new(false));
    let ab = ledgers(&cfg.kinds);
    let ba = ledgers(&cfg.kinds);
    let timeline: Timeline = Arc::new(Mutex::new(Vec::new()));
    spawn_receiver(b.events, "b", run.clone(), "ab", ab.clone(), timeline.clone(), t0);
    spawn_receiver(a.events, "a", run.clone(), "ba", ba.clone(), timeline.clone(), t0);
    for kind in &cfg.kinds {
        let (p, s) = (phase.clone(), stop.clone());
        spawn_sender(a.cmd.clone(), *kind, room.clone(), b.peer.clone(), run.clone(), "ab", cfg.rate, p, s, ab.clone());
        let (p, s) = (phase.clone(), stop.clone());
        spawn_sender(b.cmd.clone(), *kind, room.clone(), a.peer.clone(), run.clone(), "ba", cfg.rate, p, s, ba.clone());
    }

    tokio::time::sleep(cfg.before).await;
    proxy(&cfg.proxy_ctl, &format!("freeze route:{}", cfg.route_b)).await;
    let window_start = t0.elapsed().as_millis() as u64;
    phase.store(Phase::During as u8, Ordering::SeqCst);
    let mut mid_window = serde_json::Value::Null;
    match &cfg.mid_window {
        Some((at, cmd)) if *at < cfg.window => {
            tokio::time::sleep(*at).await;
            let started = t0.elapsed().as_millis() as u64;
            let line = cmd.clone();
            let status = tokio::task::spawn_blocking(move || std::process::Command::new("sh").arg("-c").arg(line).status())
                .await
                .map_err(std::io::Error::other)
                .and_then(|s| s);
            let ok = status.as_ref().is_ok_and(|s| s.success());
            mid_window = serde_json::json!({ "cmd": cmd, "at_ms": started, "done_ms": t0.elapsed().as_millis() as u64, "ok": ok });
            assert!(ok, "the mid-window command failed: {cmd} ({status:?})");
            let end_ms = window_start + cfg.window.as_millis() as u64;
            tokio::time::sleep(Duration::from_millis(end_ms.saturating_sub(t0.elapsed().as_millis() as u64))).await;
        }
        _ => tokio::time::sleep(cfg.window).await,
    }
    proxy(&cfg.proxy_ctl, &format!("{} route:{}", cfg.end, cfg.route_b)).await;
    let window_end = t0.elapsed().as_millis() as u64;
    phase.store(Phase::After as u8, Ordering::SeqCst);
    // The streams run on until B has been back for `after`, so every kind is shown to
    // reach B again, whatever became of its session.
    let back_deadline = Instant::now() + cfg.settle;
    while back_at(&lock(&timeline), window_start, window_end).is_none() && Instant::now() < back_deadline {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    tokio::time::sleep(REJOINED).await;
    phase.store(Phase::Back as u8, Ordering::SeqCst);
    tokio::time::sleep(cfg.after).await;
    stop.store(true, Ordering::SeqCst);

    // Everything in, or B back and nothing more arriving for QUIET: a session the
    // relay gave up leaves holes toward B that no wait fills.
    let all_in = || {
        lock(&ab).values().all(|l| l.lost().is_empty()) && lock(&ba).values().all(|l| l.lost().is_empty())
    };
    let last_arrival = || {
        let newest = |m: &Ledgers| lock(m).values().filter_map(|l| l.arrived.values().max().copied()).max();
        newest(&ab).max(newest(&ba)).unwrap_or(0)
    };
    let settle_deadline = Instant::now() + cfg.settle;
    while !all_in() && Instant::now() < settle_deadline {
        let now = t0.elapsed().as_millis() as u64;
        let back = back_at(&lock(&timeline), window_start, window_end).is_some();
        if back && now.saturating_sub(last_arrival().max(window_end)) >= QUIET.as_millis() as u64 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }

    let events = lock(&timeline).clone();
    let (outcome, back_ms, b_events) = session_of(&events, window_start, window_end);
    let offline_cap = if cfg.optin { OFFLINE_CAP_OPTED_IN } else { OFFLINE_CAP };
    let failures = judge(outcome, cfg.keep_session, offline_cap, &lock(&ab), &lock(&ba));
    let past_grace: serde_json::Map<String, serde_json::Value> = if outcome == Outcome::Lost {
        cfg.kinds.iter().map(|k| (k.name().to_string(), k.past_grace().into())).collect()
    } else {
        serde_json::Map::new()
    };
    let report = serde_json::json!({
        "window_s": cfg.window.as_secs_f64(),
        "end": cfg.end,
        "rate_per_s": cfg.rate,
        "kinds": cfg.kinds.iter().map(|k| k.name()).collect::<Vec<_>>(),
        "optin": cfg.optin,
        "keep_session": cfg.keep_session,
        "mid_window": mid_window,
        "window_start_ms": window_start,
        "window_end_ms": window_end,
        "settled_ms": t0.elapsed().as_millis() as u64,
        "b_session": { "outcome": outcome.name(), "back_ms": back_ms, "events": b_events },
        "a_to_b": reports(&lock(&ab), window_end),
        "b_to_a": reports(&lock(&ba), window_end),
        "past_grace": past_grace,
        "failures": failures,
        "events": events,
    });
    let text = serde_json::to_string_pretty(&report).unwrap_or_default();
    if let Some(path) = &cfg.report {
        std::fs::write(path, &text).expect("report");
    }
    crate::hollow_log!("[E2E] {text}");
    assert!(
        failures.is_empty(),
        "a {}s window ended by {} (B's session {}): {}",
        cfg.window.as_secs_f64(),
        cfg.end,
        outcome.name(),
        failures.join("; ")
    );
}

#[test]
fn a_lost_frame_is_counted_and_named() {
    let mut ledger = Ledger::default();
    for seq in 1..=10 {
        ledger.record_sent(seq, Phase::During);
    }
    for seq in (1..=10).filter(|s| *s != 7) {
        ledger.record_arrival(seq, seq * 10);
    }
    assert_eq!(ledger.lost(), vec![7]);
    assert_eq!(ledger.report(0)["lost"], 1);
    assert_eq!(ledger.report(0)["missing"], "7");
}

#[test]
fn a_duplicate_never_hides_a_gap() {
    let mut ledger = Ledger::default();
    for seq in 1..=3 {
        ledger.record_sent(seq, Phase::Before);
    }
    ledger.record_arrival(1, 1);
    ledger.record_arrival(1, 2);
    ledger.record_arrival(2, 3);
    assert_eq!(ledger.lost(), vec![3]);
    assert_eq!(ledger.duplicates, 1);
}

#[test]
fn an_arrival_nobody_sent_is_not_a_loss() {
    let mut ledger = Ledger::default();
    ledger.record_sent(1, Phase::After);
    ledger.record_arrival(1, 5);
    ledger.record_arrival(99, 6);
    assert!(ledger.lost().is_empty());
}

#[test]
fn losses_are_split_by_the_phase_they_were_sent_in() {
    let mut ledger = Ledger::default();
    ledger.record_sent(1, Phase::Before);
    ledger.record_sent(2, Phase::During);
    ledger.record_sent(3, Phase::During);
    ledger.record_sent(4, Phase::After);
    ledger.record_arrival(1, 10);
    ledger.record_arrival(4, 900);
    assert_eq!(ledger.lost_in(Phase::Before), 0);
    assert_eq!(ledger.lost_in(Phase::During), 2);
    assert_eq!(ledger.lost_in(Phase::After), 0);
    let report = ledger.report(500);
    assert_eq!(report["missing"], "2-3");
    assert_eq!(report["first_arrival_after_window_ms"], 400);
}

#[test]
fn out_of_order_arrivals_are_counted() {
    let mut ledger = Ledger::default();
    for seq in 1..=3 {
        ledger.record_sent(seq, Phase::During);
    }
    ledger.record_arrival(2, 1);
    ledger.record_arrival(1, 2);
    ledger.record_arrival(3, 3);
    assert_eq!(ledger.out_of_order, 1);
    assert!(ledger.lost().is_empty());
}

#[test]
fn only_this_runs_frames_in_this_direction_count() {
    assert_eq!(parse_frame(&frame("r1", "ab", Kind::Direct, 42), "r1", "ab"), Some((Kind::Direct, 42)));
    assert_eq!(parse_frame(&frame("r1", "ab", Kind::Chunk, 7), "r1", "ab"), Some((Kind::Chunk, 7)));
    assert_eq!(parse_frame(&frame("r0", "ab", Kind::Direct, 42), "r1", "ab"), None);
    assert_eq!(parse_frame(&frame("r1", "ba", Kind::Direct, 42), "r1", "ab"), None);
    assert_eq!(parse_frame(b"e2e:r1:ab:direct:x", "r1", "ab"), None);
    assert_eq!(parse_frame(b"e2e:r1:ab:shard:1", "r1", "ab"), None);
    assert_eq!(ranges(&[1, 2, 3, 7, 9, 10]), "1-3,7,9-10");
}

#[test]
fn each_kind_is_sent_and_heard_as_the_app_does() {
    let wire = |cmd: &WsCommand| match cmd {
        WsCommand::SendDirect { .. } => 0x04,
        WsCommand::SendToRoom { .. } => 0x03,
        WsCommand::SendToRoomTopic { .. } => 0x07,
        WsCommand::SendBinaryDirect { .. } => 0x02,
        _ => 0,
    };
    let ops: Vec<u8> = Kind::ALL.iter().map(|k| wire(&k.command("r", "p", vec![1]))).collect();
    assert_eq!(ops, vec![0x04, 0x03, 0x07, 0x02]);
    let direct = WsEvent::DirectMessage { room: "r".into(), from: "p".into(), data: vec![] };
    let message = WsEvent::Message { room: "r".into(), from: "p".into(), data: vec![] };
    let chunk = WsEvent::BinaryDirect { room: "r".into(), from: "p".into(), data: vec![] };
    assert!(Kind::Direct.arrives_as(&direct) && !Kind::Direct.arrives_as(&message));
    assert!(Kind::Broadcast.arrives_as(&message) && Kind::Topic.arrives_as(&message));
    assert!(Kind::Chunk.arrives_as(&chunk) && !Kind::Chunk.arrives_as(&direct));
}

fn timeline(entries: &[(&str, &str, u64)]) -> Vec<serde_json::Value> {
    entries.iter().map(|(side, event, ms)| serde_json::json!({ "side": side, "event": event, "ms": ms })).collect()
}

#[test]
fn the_session_outcome_reads_bs_events_from_the_window_on() {
    let kept = timeline(&[("b", "Connected", 10), ("a", "PeerLeft", 2000)]);
    assert_eq!(session_of(&kept, 1000, 5000), (Outcome::Kept, None, vec![]));
    let resumed = timeline(&[("b", "Suspended", 2000), ("b", "Connecting", 2001), ("b", "Resumed", 5100)]);
    let (outcome, back, events) = session_of(&resumed, 1000, 5000);
    assert_eq!((outcome, back), (Outcome::Resumed, Some(100)));
    assert_eq!(events, vec!["Suspended@2000", "Connecting@2001", "Resumed@5100"]);
    // A socket that came and went inside the window is not B being back.
    let flapped = timeline(&[("b", "Suspended", 2000), ("b", "Resumed", 3000), ("b", "Suspended", 4000), ("b", "Resumed", 5300)]);
    assert_eq!(session_of(&flapped, 1000, 5000).1, Some(300));
    let lost = timeline(&[("b", "Suspended", 2000), ("b", "SessionLost", 5200), ("b", "Connected", 5200)]);
    assert_eq!(session_of(&lost, 1000, 5000).0, Outcome::Lost);
    assert_eq!(session_of(&lost, 1000, 5000).1, Some(200));
}

#[test]
fn b_is_back_when_its_socket_outlived_the_window_or_once_it_returned() {
    let kept = timeline(&[("b", "Connected", 10)]);
    assert_eq!(back_at(&kept, 1000, 5000), Some(5000));
    let away = timeline(&[("b", "Suspended", 2000), ("b", "Connecting", 2001)]);
    assert_eq!(back_at(&away, 1000, 5000), None);
    let returned = timeline(&[("b", "Suspended", 2000), ("b", "SessionLost", 5300), ("b", "Connected", 5300)]);
    assert_eq!(back_at(&returned, 1000, 5000), Some(5300));
}

#[test]
fn past_grace_every_kind_still_reaches_b_once_it_is_back() {
    let mut late = ledger_with(300, &(10..=290).collect::<Vec<_>>());
    for seq in 301..=310 {
        late.record_sent(seq, Phase::Back);
        if seq != 305 {
            late.record_arrival(seq, seq);
        }
    }
    let toward_b: BTreeMap<Kind, Ledger> = [(Kind::Topic, late)].into_iter().collect();
    let from_b: BTreeMap<Kind, Ledger> = [(Kind::Topic, ledger_with(10, &[]))].into_iter().collect();
    let failures = judge(Outcome::Lost, false, 100, &toward_b, &from_b);
    assert_eq!(failures.len(), 1, "{failures:?}");
    assert!(failures[0].contains("after B was back"));
}

fn ledger_with(sent: u64, lost: &[u64]) -> Ledger {
    let mut ledger = Ledger::default();
    for seq in 1..=sent {
        ledger.record_sent(seq, Phase::During);
        if !lost.contains(&seq) {
            ledger.record_arrival(seq, seq);
        }
    }
    ledger
}

#[test]
fn past_grace_only_the_oldest_direct_frames_may_go() {
    let oldest: Vec<u64> = (5..=20).collect();
    assert!(ledger_with(130, &oldest).lost_only_oldest(100).is_ok());
    assert!(ledger_with(110, &oldest).lost_only_oldest(100).is_err(), "fewer survivors than the buffer keeps");
    assert!(ledger_with(300, &[5, 6, 90]).lost_only_oldest(100).is_err(), "a hole after the run");
    assert!(ledger_with(10, &[]).lost_only_oldest(100).is_ok());
}

#[test]
fn a_kept_or_resumed_session_loses_nothing_either_way() {
    let clean: BTreeMap<Kind, Ledger> = [(Kind::Direct, ledger_with(10, &[]))].into_iter().collect();
    let holed: BTreeMap<Kind, Ledger> = [(Kind::Broadcast, ledger_with(10, &[4]))].into_iter().collect();
    assert!(judge(Outcome::Resumed, true, 100, &clean, &clean).is_empty());
    assert_eq!(judge(Outcome::Resumed, true, 100, &holed, &clean).len(), 1);
    assert_eq!(judge(Outcome::Kept, true, 100, &clean, &holed).len(), 1);
    assert_eq!(judge(Outcome::Lost, true, 100, &clean, &clean).len(), 1, "inside the grace a session must survive");
    let mut misread = ledger_with(10, &[]);
    misread.wrong_event = 1;
    let misread: BTreeMap<Kind, Ledger> = [(Kind::Chunk, misread)].into_iter().collect();
    assert_eq!(judge(Outcome::Kept, true, 100, &misread, &clean).len(), 1, "a frame heard as another kind");
}

#[test]
fn a_lost_session_still_owes_every_frame_b_sent_and_the_newest_dms() {
    let toward_b: BTreeMap<Kind, Ledger> = [
        (Kind::Direct, ledger_with(300, &(10..=150).collect::<Vec<_>>())),
        (Kind::Broadcast, ledger_with(300, &(10..=290).collect::<Vec<_>>())),
    ]
    .into_iter()
    .collect();
    let from_b: BTreeMap<Kind, Ledger> = [(Kind::Chunk, ledger_with(300, &[]))].into_iter().collect();
    assert!(judge(Outcome::Lost, false, 100, &toward_b, &from_b).is_empty());
    let from_b_holed: BTreeMap<Kind, Ledger> = [(Kind::Chunk, ledger_with(300, &[7]))].into_iter().collect();
    assert_eq!(judge(Outcome::Lost, false, 100, &toward_b, &from_b_holed).len(), 1);
    let thin: BTreeMap<Kind, Ledger> =
        [(Kind::Direct, ledger_with(300, &(10..=250).collect::<Vec<_>>()))].into_iter().collect();
    assert_eq!(judge(Outcome::Lost, false, 100, &thin, &from_b).len(), 1, "the buffer kept fewer than its cap");
}
