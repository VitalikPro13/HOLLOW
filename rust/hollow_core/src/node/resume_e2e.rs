//! The real `ws_client` against the real relay, with B's path through the zombie
//! proxy (`tools/zombie_proxy`) frozen for a window and then thawed or dropped,
//! counting every frame A and B send each other across it
//! (RESUMABLE_SESSIONS_PLAN.md section 6). `scripts/resume_e2e.sh` starts the relay
//! and the proxy and runs the ignored test with:
//!
//! | variable | |
//! |---|---|
//! | `HOLLOW_E2E_URL_A`, `HOLLOW_E2E_URL_B` | the proxy routes A and B dial (`ws://`) |
//! | `HOLLOW_E2E_PROXY_CTL`, `HOLLOW_E2E_ROUTE_B` | the proxy's control address, B's route |
//! | `HOLLOW_E2E_WINDOW_SECS` | how long B's path stays frozen |
//! | `HOLLOW_E2E_END` | `thaw` or `drop` when the window ends |
//! | `HOLLOW_E2E_RATE` | frames per second, each way |
//! | `HOLLOW_E2E_SETTLE_SECS` | how long stragglers may take |
//! | `HOLLOW_E2E_REPORT` | where the JSON result goes |
//! | `HOLLOW_DATA_DIR` | a scratch directory (required) |

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

use super::ws_client::{spawn_ws_client, WsCommand, WsEvent};
use crate::identity::native_identity::NativeKeypair;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Before = 0,
    During = 1,
    After = 2,
}

impl Phase {
    const ALL: [Phase; 3] = [Phase::Before, Phase::During, Phase::After];

    fn name(self) -> &'static str {
        match self {
            Phase::Before => "before",
            Phase::During => "during",
            Phase::After => "after",
        }
    }

    fn from_u8(value: u8) -> Phase {
        match value {
            0 => Phase::Before,
            1 => Phase::During,
            _ => Phase::After,
        }
    }
}

/// One direction's frames by sequence number: when each was sent, when it first
/// arrived.
#[derive(Default)]
struct Ledger {
    sent: BTreeMap<u64, Phase>,
    arrived: BTreeMap<u64, u64>,
    duplicates: u64,
    out_of_order: u64,
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
            "by_phase": by_phase,
            "first_arrival_after_window_ms": first_after.map(|ms| ms - window_end_ms),
            "last_arrival_ms": self.arrived.values().max().copied(),
        })
    }
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

/// The sequence number of one of this run's frames in direction `dir`.
fn parse_frame(data: &[u8], run: &str, dir: &str) -> Option<u64> {
    let text = std::str::from_utf8(data).ok()?;
    text.strip_prefix(&format!("e2e:{run}:{dir}:"))?.parse().ok()
}

fn frame(run: &str, dir: &str, seq: u64) -> Vec<u8> {
    format!("e2e:{run}:{dir}:{seq}").into_bytes()
}

struct Config {
    url_a: String,
    url_b: String,
    proxy_ctl: String,
    route_b: String,
    window: Duration,
    end: String,
    rate: f64,
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
        Config {
            url_a,
            url_b,
            proxy_ctl: var("HOLLOW_E2E_PROXY_CTL").expect("HOLLOW_E2E_PROXY_CTL"),
            route_b: var("HOLLOW_E2E_ROUTE_B").unwrap_or_else(|| "b".into()),
            window: secs("HOLLOW_E2E_WINDOW_SECS", 5.0),
            end,
            rate: var("HOLLOW_E2E_RATE").and_then(|v| v.parse().ok()).unwrap_or(2.0),
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

/// Counts this run's frames into `ledger` and every other event into the timeline.
fn spawn_receiver(
    mut events: mpsc::UnboundedReceiver<WsEvent>,
    side: &'static str,
    run: String,
    dir: &'static str,
    ledger: Arc<Mutex<Ledger>>,
    timeline: Timeline,
    t0: Instant,
) {
    tokio::spawn(async move {
        while let Some(event) = events.recv().await {
            let ms = t0.elapsed().as_millis() as u64;
            match &event {
                WsEvent::DirectMessage { data, .. } => {
                    if let Some(seq) = parse_frame(data, &run, dir) {
                        ledger.lock().unwrap_or_else(|e| e.into_inner()).record_arrival(seq, ms);
                    }
                }
                WsEvent::RoomBudgetUpdate { .. } => {}
                other => {
                    let mut entry = serde_json::json!({ "ms": ms, "side": side, "event": other.kind() });
                    if let WsEvent::Resumed { gap } = other {
                        entry["gap"] = serde_json::Value::Bool(*gap);
                    }
                    timeline.lock().unwrap_or_else(|e| e.into_inner()).push(entry);
                }
            }
        }
    });
}

#[allow(clippy::too_many_arguments)]
fn spawn_sender(
    cmd: mpsc::UnboundedSender<WsCommand>,
    room: String,
    target: String,
    run: String,
    dir: &'static str,
    rate: f64,
    phase: Arc<AtomicU8>,
    stop: Arc<AtomicBool>,
    ledger: Arc<Mutex<Ledger>>,
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
            ledger.lock().unwrap_or_else(|e| e.into_inner()).record_sent(seq, now);
            let data = frame(&run, dir, seq);
            if cmd.send(WsCommand::SendDirect { room_code: room.clone(), target_peer: target.clone(), data }).is_err() {
                break;
            }
        }
    });
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
    let b_peer = b.peer.clone();
    wait_for_event(&mut a.events, Duration::from_secs(15), "A to see B", |e| sees(e, &room, &b_peer)).await;
    let a_peer = a.peer.clone();
    wait_for_event(&mut b.events, Duration::from_secs(15), "B to see A", |e| sees(e, &room, &a_peer)).await;

    let t0 = Instant::now();
    let phase = Arc::new(AtomicU8::new(Phase::Before as u8));
    let stop = Arc::new(AtomicBool::new(false));
    let ab = Arc::new(Mutex::new(Ledger::default()));
    let ba = Arc::new(Mutex::new(Ledger::default()));
    let timeline: Timeline = Arc::new(Mutex::new(Vec::new()));
    spawn_receiver(b.events, "b", run.clone(), "ab", ab.clone(), timeline.clone(), t0);
    spawn_receiver(a.events, "a", run.clone(), "ba", ba.clone(), timeline.clone(), t0);
    spawn_sender(a.cmd.clone(), room.clone(), b.peer.clone(), run.clone(), "ab", cfg.rate, phase.clone(), stop.clone(), ab.clone());
    spawn_sender(b.cmd.clone(), room.clone(), a.peer.clone(), run.clone(), "ba", cfg.rate, phase.clone(), stop.clone(), ba.clone());

    tokio::time::sleep(cfg.before).await;
    proxy(&cfg.proxy_ctl, &format!("freeze route:{}", cfg.route_b)).await;
    let window_start = t0.elapsed().as_millis() as u64;
    phase.store(Phase::During as u8, Ordering::SeqCst);
    tokio::time::sleep(cfg.window).await;
    proxy(&cfg.proxy_ctl, &format!("{} route:{}", cfg.end, cfg.route_b)).await;
    let window_end = t0.elapsed().as_millis() as u64;
    phase.store(Phase::After as u8, Ordering::SeqCst);
    tokio::time::sleep(cfg.after).await;
    stop.store(true, Ordering::SeqCst);

    let all_in = || {
        ab.lock().unwrap_or_else(|e| e.into_inner()).lost().is_empty()
            && ba.lock().unwrap_or_else(|e| e.into_inner()).lost().is_empty()
    };
    let settle_deadline = Instant::now() + cfg.settle;
    while !all_in() && Instant::now() < settle_deadline {
        tokio::time::sleep(Duration::from_millis(250)).await;
    }

    let ab_report = ab.lock().unwrap_or_else(|e| e.into_inner()).report(window_end);
    let ba_report = ba.lock().unwrap_or_else(|e| e.into_inner()).report(window_end);
    let report = serde_json::json!({
        "window_s": cfg.window.as_secs_f64(),
        "end": cfg.end,
        "rate_per_s": cfg.rate,
        "window_start_ms": window_start,
        "window_end_ms": window_end,
        "settled_ms": t0.elapsed().as_millis() as u64,
        "a_to_b": ab_report,
        "b_to_a": ba_report,
        "events": timeline.lock().unwrap_or_else(|e| e.into_inner()).clone(),
    });
    let text = serde_json::to_string_pretty(&report).unwrap_or_default();
    if let Some(path) = &cfg.report {
        std::fs::write(path, &text).expect("report");
    }
    crate::hollow_log!("[E2E] {text}");
    let lost_ab = report["a_to_b"]["lost"].as_u64().unwrap_or(0);
    let lost_ba = report["b_to_a"]["lost"].as_u64().unwrap_or(0);
    assert!(
        lost_ab == 0 && lost_ba == 0,
        "lost {lost_ab} of {} A->B and {lost_ba} of {} B->A across a {}s window ended by {}",
        report["a_to_b"]["sent"], report["b_to_a"]["sent"], cfg.window.as_secs_f64(), cfg.end
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
    assert_eq!(parse_frame(&frame("r1", "ab", 42), "r1", "ab"), Some(42));
    assert_eq!(parse_frame(&frame("r0", "ab", 42), "r1", "ab"), None);
    assert_eq!(parse_frame(&frame("r1", "ba", 42), "r1", "ab"), None);
    assert_eq!(parse_frame(b"e2e:r1:ab:x", "r1", "ab"), None);
    assert_eq!(ranges(&[1, 2, 3, 7, 9, 10]), "1-3,7,9-10");
}
