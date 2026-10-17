//! Scale probe for a LOCAL relay: N protocol-speaking clients (auth v3 with a session,
//! acks and heartbeats like ws_client) in ONE unlocked room, driving join storms,
//! presence churn, room broadcasts (0x03) and topic sends (0x07). Egress is counted
//! on the client side (every frame the relay wrote to any client); relay CPU and RSS
//! come from `ps` on the relay's pid. Run it through bench/run_scale_probe.sh.
//!
//! Refuses any host but loopback: production is never a load target.

use base64::Engine;
use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, StreamExt};
use rand::rngs::OsRng;
use rand::Rng;
use serde_json::json;
use std::collections::HashMap;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc::{unbounded_channel, UnboundedSender};
use tokio::sync::Semaphore;
use tokio_tungstenite::tungstenite::Message;

const ROOM: &str = "scale-probe-room";
const TOPIC: &str = "scale-probe-topic";

// ---------------------------------------------------------------- counters

#[derive(Default)]
struct Kind {
    frames: AtomicU64,
    bytes: AtomicU64,
}

impl Kind {
    fn add(&self, n: usize) {
        self.frames.fetch_add(1, Relaxed);
        self.bytes.fetch_add(n as u64, Relaxed);
    }
    fn get(&self) -> (u64, u64) {
        (self.frames.load(Relaxed), self.bytes.load(Relaxed))
    }
}

#[derive(Default)]
struct Stats {
    all: Kind,
    members: Kind,
    peer_joined: Kind,
    peer_left: Kind,
    bin_room: Kind,
    bin_topic: Kind,
    hb_ack: Kind,
    other_text: Kind,
    other_bin: Kind,
    joined: AtomicU64,
    connected: AtomicU64,
    failed: AtomicU64,
    dropped: AtomicU64,
    sent_frames: AtomicU64,
    sent_bytes: AtomicU64,
    /// Broadcast delivery latency, log2 microsecond buckets.
    lat: [AtomicU64; 32],
    join_lat_us: Mutex<Vec<u64>>,
    other_types: Mutex<HashMap<String, u64>>,
}

#[derive(Clone, Copy, Default)]
struct Snap {
    all: (u64, u64),
    members: (u64, u64),
    peer_joined: (u64, u64),
    peer_left: (u64, u64),
    bin_room: (u64, u64),
    bin_topic: (u64, u64),
    hb_ack: (u64, u64),
    other_text: (u64, u64),
    other_bin: (u64, u64),
    sent: (u64, u64),
}

impl Stats {
    fn snap(&self) -> Snap {
        Snap {
            all: self.all.get(),
            members: self.members.get(),
            peer_joined: self.peer_joined.get(),
            peer_left: self.peer_left.get(),
            bin_room: self.bin_room.get(),
            bin_topic: self.bin_topic.get(),
            hb_ack: self.hb_ack.get(),
            other_text: self.other_text.get(),
            other_bin: self.other_bin.get(),
            sent: (self.sent_frames.load(Relaxed), self.sent_bytes.load(Relaxed)),
        }
    }
    fn lat_reset(&self) {
        for b in &self.lat {
            b.store(0, Relaxed);
        }
    }
    fn lat_pct(&self, p: f64) -> u64 {
        let counts: Vec<u64> = self.lat.iter().map(|b| b.load(Relaxed)).collect();
        let total: u64 = counts.iter().sum();
        if total == 0 {
            return 0;
        }
        let want = (total as f64 * p).ceil() as u64;
        let mut acc = 0;
        for (i, c) in counts.iter().enumerate() {
            acc += c;
            if acc >= want {
                return 1u64 << i;
            }
        }
        1u64 << 31
    }
}

fn d(a: (u64, u64), b: (u64, u64)) -> (u64, u64) {
    (a.0 - b.0, a.1 - b.1)
}

static STATS: std::sync::LazyLock<Stats> = std::sync::LazyLock::new(Stats::default);
static SENDER_ALIVE: AtomicBool = AtomicBool::new(true);
static STATS_FILE: std::sync::OnceLock<String> = std::sync::OnceLock::new();
static EPOCH: std::sync::LazyLock<Instant> = std::sync::LazyLock::new(Instant::now);

// ---------------------------------------------------------------- relay sampler

/// The relay process seen through `ps`: cumulative CPU seconds, RSS, peak RSS since the
/// last phase mark, and the %cpu samples of the running phase.
struct RelayProbe {
    pid: u32,
    peak_rss_kb: AtomicU64,
    samples: Mutex<Vec<f64>>,
}

/// The relay's `ps` line: from the run script's sampler file when one is named (a
/// process holding tens of thousands of sockets cannot reliably spawn `ps` itself),
/// else from `ps` directly.
fn ps(pid: u32) -> Option<(f64, u64, f64)> {
    let text = match STATS_FILE.get() {
        Some(path) => {
            let all = std::fs::read_to_string(path).ok()?;
            all.lines().rev().find(|l| l.split_whitespace().count() >= 3)?.to_string()
        }
        None => {
            let out = std::process::Command::new("ps")
                .args(["-o", "time=,rss=,%cpu=", "-p", &pid.to_string()])
                .output()
                .ok()?;
            String::from_utf8_lossy(&out.stdout).into_owned()
        }
    };
    let mut it = text.split_whitespace();
    let time = it.next()?;
    let rss: u64 = it.next()?.parse().ok()?;
    let pct: f64 = it.next()?.parse().ok()?;
    let mut secs = 0.0;
    for part in time.replace('-', ":").split(':') {
        secs = secs * 60.0 + part.parse::<f64>().ok()?;
    }
    Some((secs, rss, pct))
}

impl RelayProbe {
    fn start(pid: u32) -> Arc<Self> {
        let p = Arc::new(Self { pid, peak_rss_kb: AtomicU64::new(0), samples: Mutex::new(Vec::new()) });
        let q = p.clone();
        std::thread::spawn(move || loop {
            if let Some((_, rss, pct)) = ps(q.pid) {
                q.peak_rss_kb.fetch_max(rss, Relaxed);
                q.samples.lock().unwrap().push(pct);
            }
            std::thread::sleep(Duration::from_secs(1));
        });
        p
    }
    fn mark(&self) -> (f64, u64) {
        let (cpu, rss, _) = ps(self.pid).unwrap_or((0.0, 0, 0.0));
        self.peak_rss_kb.store(rss, Relaxed);
        self.samples.lock().unwrap().clear();
        (cpu, rss)
    }
}

struct Phase {
    name: String,
    t0: Instant,
    cpu0: f64,
    rss0: u64,
    s0: Snap,
}

fn phase(probe: &RelayProbe, name: &str) -> Phase {
    let (cpu0, rss0) = probe.mark();
    Phase { name: name.to_string(), t0: Instant::now(), cpu0, rss0, s0: STATS.snap() }
}

fn end_phase(probe: &RelayProbe, p: Phase, n: usize, extra: serde_json::Value, out: &Option<String>) -> serde_json::Value {
    let secs = p.t0.elapsed().as_secs_f64();
    let (cpu1, rss1, _) = ps(probe.pid).unwrap_or((0.0, 0, 0.0));
    let peak = probe.peak_rss_kb.load(Relaxed).max(rss1);
    let samples = probe.samples.lock().unwrap().clone();
    let max_pct = samples.iter().cloned().fold(0.0, f64::max);
    let s1 = STATS.snap();
    let all = d(s1.all, p.s0.all);
    let pair = |a: (u64, u64), b: (u64, u64)| {
        let x = d(a, b);
        json!([x.0, x.1])
    };
    let cpu = cpu1 - p.cpu0;
    let mut v = json!({
        "phase": p.name, "n": n, "secs": round3(secs),
        "relay_cpu_s": round3(cpu), "relay_cpu_pct": round3(if secs > 0.0 { 100.0 * cpu / secs } else { 0.0 }),
        "relay_cpu_pct_max_sample": max_pct,
        "relay_rss_mb_start": round3(p.rss0 as f64 / 1024.0), "relay_rss_mb_end": round3(rss1 as f64 / 1024.0),
        "relay_rss_mb_peak": round3(peak as f64 / 1024.0),
        "egress_frames": all.0, "egress_bytes": all.1,
        "egress_frames_per_s": round3(all.0 as f64 / secs.max(1e-9)),
        "egress_mbit_per_s": round3(all.1 as f64 * 8.0 / 1e6 / secs.max(1e-9)),
        "relay_cpu_us_per_frame": round3(if all.0 > 0 { cpu * 1e6 / all.0 as f64 } else { 0.0 }),
        "members": pair(s1.members, p.s0.members), "peer_joined": pair(s1.peer_joined, p.s0.peer_joined),
        "peer_left": pair(s1.peer_left, p.s0.peer_left), "bin_0x05": pair(s1.bin_room, p.s0.bin_room),
        "bin_0x08": pair(s1.bin_topic, p.s0.bin_topic), "hb_ack": pair(s1.hb_ack, p.s0.hb_ack),
        "other_text": pair(s1.other_text, p.s0.other_text), "other_bin": pair(s1.other_bin, p.s0.other_bin),
        "client_sent": pair(s1.sent, p.s0.sent),
        "connected": STATS.connected.load(Relaxed), "dropped": STATS.dropped.load(Relaxed),
        "sender_alive": SENDER_ALIVE.load(Relaxed),
    });
    if let (Some(o), Some(e)) = (v.as_object_mut(), extra.as_object()) {
        for (k, x) in e {
            o.insert(k.clone(), x.clone());
        }
    }
    println!("RESULT {}", v);
    if let Some(path) = out {
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(f, "{}", v);
        }
    }
    v
}

fn round3(x: f64) -> f64 {
    (x * 1000.0).round() / 1000.0
}

// ---------------------------------------------------------------- one client

const B58: &[u8] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

fn base58(data: &[u8]) -> String {
    let zeros = data.iter().take_while(|b| **b == 0).count();
    let mut buf = vec![0u8; (data.len() - zeros) * 138 / 100 + 1];
    for &byte in &data[zeros..] {
        let mut carry = byte as usize;
        for slot in buf.iter_mut().rev() {
            carry += 256 * (*slot as usize);
            *slot = (carry % 58) as u8;
            carry /= 58;
        }
    }
    let skip = buf.iter().take_while(|b| **b == 0).count();
    let mut out: String = std::iter::repeat_n('1', zeros).collect();
    out.extend(buf[skip..].iter().map(|&b| B58[b as usize] as char));
    out
}

struct Ident {
    key: SigningKey,
    peer_id: String,
    pub_b64: String,
}

fn ident() -> Ident {
    let key = SigningKey::generate(&mut OsRng);
    let raw = key.verifying_key().to_bytes();
    let mut proto = vec![0x08, 0x01, 0x12, 0x20];
    proto.extend_from_slice(&raw);
    let mut mh = vec![0x00, 0x24];
    mh.extend_from_slice(&proto);
    Ident {
        peer_id: base58(&mh),
        pub_b64: base64::engine::general_purpose::STANDARD.encode(&proto),
        key,
    }
}

#[derive(Debug)]
struct AcceptAny;

impl rustls::client::danger::ServerCertVerifier for AcceptAny {
    fn verify_server_cert(
        &self,
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &[rustls::pki_types::CertificateDer<'_>],
        _: &rustls::pki_types::ServerName<'_>,
        _: &[u8],
        _: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }
    fn verify_tls13_signature(
        &self,
        _: &[u8],
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::ring::default_provider().signature_verification_algorithms.supported_schemes()
    }
}

struct Ctx {
    port: u16,
    domain: String,
    tls: tokio_rustls::TlsConnector,
    next_port: AtomicU64,
}

/// One connected client: its sends go through `tx`, its reader counts and acks.
struct Client {
    peer_id: String,
    tx: UnboundedSender<Message>,
    alive: AtomicBool,
    joined: AtomicBool,
    is_sender: AtomicBool,
    join_sent: Mutex<Option<Instant>>,
}

impl Client {
    fn send_text(&self, v: serde_json::Value) {
        let s = v.to_string();
        STATS.sent_frames.fetch_add(1, Relaxed);
        STATS.sent_bytes.fetch_add(s.len() as u64, Relaxed);
        let _ = self.tx.send(Message::text(s));
    }
    fn send_bin(&self, b: Vec<u8>) {
        STATS.sent_frames.fetch_add(1, Relaxed);
        STATS.sent_bytes.fetch_add(b.len() as u64, Relaxed);
        let _ = self.tx.send(Message::binary(b));
    }
    fn join(&self) {
        *self.join_sent.lock().unwrap() = Some(Instant::now());
        self.send_text(json!({"type": "join", "room": ROOM}));
    }
    fn leave(&self) {
        self.joined.store(false, Relaxed);
        self.send_text(json!({"type": "leave", "room": ROOM}));
    }
}

/// The `type` of a relay JSON frame. nlohmann dumps keys sorted, so `type` sits last
/// and a big `members` frame is never parsed whole.
fn json_type(s: &str) -> &str {
    let Some(at) = s.rfind("\"type\":\"") else { return "" };
    let rest = &s[at + 8..];
    &rest[..rest.find('"').unwrap_or(0)]
}

const UNCOUNTED: [&str; 11] = [
    "auth_challenge", "auth_ok", "auth_failed", "resumed", "hb_ack", "ack", "reconnect", "members", "peer_joined",
    "peer_left", "kill_signal",
];

async fn connect(ctx: &Ctx, hidden: bool) -> Result<Arc<Client>, String> {
    let id = ident();
    // Explicit source ports past the ephemeral range's 16k: one loopback address then
    // holds up to ~55k sockets to one relay port.
    let stream = loop {
        let p = ctx.next_port.fetch_add(1, Relaxed);
        if p > 65535 {
            return Err("source ports exhausted".into());
        }
        if p as u16 == ctx.port {
            continue;
        }
        let sock = tokio::net::TcpSocket::new_v4().map_err(|e| e.to_string())?;
        let _ = sock.set_reuseaddr(true);
        if sock.bind(SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, p as u16))).is_err() {
            continue;
        }
        match sock.connect(SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, ctx.port))).await {
            Ok(s) => break s,
            Err(e) if e.kind() == std::io::ErrorKind::AddrInUse || e.raw_os_error() == Some(49) => continue,
            Err(e) => return Err(format!("connect: {e}")),
        }
    };
    let _ = stream.set_nodelay(true);
    let name = rustls::pki_types::ServerName::try_from("relay.bench.test").unwrap();
    let tls = ctx.tls.connect(name, stream).await.map_err(|e| format!("tls: {e}"))?;
    let url = format!("wss://127.0.0.1:{}/ws", ctx.port);
    let (ws, _) = tokio_tungstenite::client_async(url, tls).await.map_err(|e| format!("ws: {e}"))?;
    let (mut sink, mut read) = ws.split();

    sink.send(Message::text(r#"{"type":"auth_hello"}"#)).await.map_err(|e| e.to_string())?;
    let nonce = loop {
        match tokio::time::timeout(Duration::from_secs(30), read.next()).await {
            Ok(Some(Ok(Message::Text(t)))) => {
                let v: serde_json::Value = serde_json::from_str(&t).map_err(|e| e.to_string())?;
                if v["type"] == "auth_challenge" {
                    break v["nonce"].as_str().unwrap_or_default().to_string();
                }
            }
            Ok(Some(Ok(_))) => continue,
            other => return Err(format!("no challenge: {other:?}")),
        }
    };
    let ts = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
    let msg = format!("hollow-ws-auth3\n{}\n{}\n{}\n{}\nfull\n\nnew\n0", ctx.domain, nonce, id.peer_id, ts);
    let sig = base64::engine::general_purpose::STANDARD.encode(id.key.sign(msg.as_bytes()).to_bytes());
    let auth = json!({
        "type": "auth", "v": 3, "peer_id": id.peer_id, "public_key": id.pub_b64, "timestamp": ts,
        "signature": sig, "nonce": nonce, "domain": ctx.domain, "session": "new", "in_h": 0,
    });
    sink.send(Message::text(auth.to_string())).await.map_err(|e| e.to_string())?;
    loop {
        match tokio::time::timeout(Duration::from_secs(30), read.next()).await {
            Ok(Some(Ok(Message::Text(t)))) => match json_type(&t) {
                "auth_ok" => break,
                "auth_failed" => return Err(format!("auth failed: {t}")),
                _ => continue,
            },
            Ok(Some(Ok(_))) => continue,
            other => return Err(format!("no auth_ok: {other:?}")),
        }
    }
    if hidden {
        sink.send(Message::text(r#"{"type":"inactive"}"#)).await.map_err(|e| e.to_string())?;
    }

    let (tx, mut rx) = unbounded_channel::<Message>();
    let client = Arc::new(Client {
        peer_id: id.peer_id.clone(),
        tx: tx.clone(),
        alive: AtomicBool::new(true),
        joined: AtomicBool::new(false),
        is_sender: AtomicBool::new(false),
        join_sent: Mutex::new(None),
    });
    tokio::spawn(async move {
        while let Some(m) = rx.recv().await {
            let close = matches!(m, Message::Close(_));
            if sink.send(m).await.is_err() || close {
                break;
            }
        }
    });
    // Heartbeat like ws_client (HB_SECS 15), offset so a fleet does not beat in step.
    let hb_h = Arc::new(AtomicU64::new(0));
    {
        let tx = tx.clone();
        let h = hb_h.clone();
        let c = client.clone();
        tokio::spawn(async move {
            let off = rand::thread_rng().gen_range(0..15_000);
            tokio::time::sleep(Duration::from_millis(off)).await;
            loop {
                if !c.alive.load(Relaxed) {
                    break;
                }
                let m = format!(r#"{{"type":"hb","h":{}}}"#, h.load(Relaxed));
                if tx.send(Message::text(m)).is_err() {
                    break;
                }
                tokio::time::sleep(Duration::from_secs(15)).await;
            }
        });
    }
    let c = client.clone();
    tokio::spawn(async move {
        let mut h: u64 = 0;
        let mut acked: u64 = 0;
        while let Some(m) = read.next().await {
            let Ok(m) = m else { break };
            match m {
                Message::Text(t) => {
                    let n = t.len();
                    STATS.all.add(n);
                    let ty = json_type(&t);
                    match ty {
                        "members" => {
                            STATS.members.add(n);
                            if t.contains(ROOM) && !c.joined.swap(true, Relaxed) {
                                STATS.joined.fetch_add(1, Relaxed);
                                if let Some(at) = c.join_sent.lock().unwrap().take() {
                                    STATS.join_lat_us.lock().unwrap().push(at.elapsed().as_micros() as u64);
                                }
                            }
                        }
                        "peer_joined" => STATS.peer_joined.add(n),
                        "peer_left" => STATS.peer_left.add(n),
                        "hb_ack" | "ack" => STATS.hb_ack.add(n),
                        other => {
                            STATS.other_text.add(n);
                            *STATS.other_types.lock().unwrap().entry(other.to_string()).or_default() += 1;
                        }
                    }
                    if !UNCOUNTED.contains(&ty) {
                        h += 1;
                    }
                }
                Message::Binary(b) => {
                    let n = b.len();
                    STATS.all.add(n);
                    h += 1;
                    match b.first() {
                        Some(0x05) | Some(0x08) => {
                            if b[0] == 0x05 { STATS.bin_room.add(n) } else { STATS.bin_topic.add(n) }
                            // The payload's first 8 bytes: send time, microseconds since EPOCH.
                            let skip = if b[0] == 0x05 { 2 } else { 3 };
                            let mut at = 0;
                            let mut nul = 0;
                            for (i, x) in b.iter().enumerate().skip(1) {
                                if *x == 0 {
                                    nul += 1;
                                    if nul == skip {
                                        at = i + 1;
                                        break;
                                    }
                                }
                            }
                            if at > 0 && b.len() >= at + 8 {
                                let sent = u64::from_le_bytes(b[at..at + 8].try_into().unwrap());
                                let now = EPOCH.elapsed().as_micros() as u64;
                                let lat = now.saturating_sub(sent).max(1);
                                let bucket = (63 - lat.leading_zeros()) as usize;
                                STATS.lat[bucket.min(31)].fetch_add(1, Relaxed);
                            }
                        }
                        _ => STATS.other_bin.add(n),
                    }
                }
                Message::Close(_) => break,
                _ => {}
            }
            hb_h.store(h, Relaxed);
            if h - acked >= 16 {
                acked = h;
                let _ = c.tx.send(Message::text(format!(r#"{{"type":"ack","h":{h}}}"#)));
            }
        }
        if c.alive.swap(false, Relaxed) {
            STATS.dropped.fetch_add(1, Relaxed);
            if c.is_sender.load(Relaxed) {
                SENDER_ALIVE.store(false, Relaxed);
            }
        }
    });
    STATS.connected.fetch_add(1, Relaxed);
    Ok(client)
}

async fn connect_many(ctx: &Arc<Ctx>, n: usize, conc: usize, hidden: bool) -> Vec<Arc<Client>> {
    let sem = Arc::new(Semaphore::new(conc));
    let mut handles = Vec::with_capacity(n);
    for _ in 0..n {
        let ctx = ctx.clone();
        let sem = sem.clone();
        handles.push(tokio::spawn(async move {
            let _p = sem.acquire().await.unwrap();
            for attempt in 0..5 {
                match connect(&ctx, hidden).await {
                    Ok(c) => return Some(c),
                    Err(e) => {
                        let f = STATS.failed.fetch_add(1, Relaxed);
                        if f < 5 {
                            eprintln!("connect failed (attempt {attempt}): {e}");
                        }
                        tokio::time::sleep(Duration::from_millis(500)).await;
                    }
                }
            }
            None
        }));
    }
    let mut out = Vec::with_capacity(n);
    let mut last = Instant::now();
    for h in handles {
        if let Ok(Some(c)) = h.await {
            out.push(c);
        }
        if last.elapsed() > Duration::from_secs(10) {
            eprintln!("  connected {} / {n}", out.len());
            last = Instant::now();
        }
    }
    out
}

/// Waits until no client received a frame for `quiet`, or `cap` passed.
async fn settle(quiet: Duration, cap: Duration) -> bool {
    let start = Instant::now();
    // Heartbeat answers never stop, so they are not traffic a phase waits out.
    let busy = || STATS.all.frames.load(Relaxed) - STATS.hb_ack.frames.load(Relaxed);
    let mut last = busy();
    let mut since = Instant::now();
    loop {
        tokio::time::sleep(Duration::from_millis(50)).await;
        let now = busy();
        if now != last {
            last = now;
            since = Instant::now();
        } else if since.elapsed() >= quiet {
            return true;
        }
        if start.elapsed() > cap {
            return false;
        }
    }
}

async fn wait_joined(target: u64, cap: Duration) -> bool {
    let start = Instant::now();
    while STATS.joined.load(Relaxed) < target {
        if start.elapsed() > cap {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    true
}

// ---------------------------------------------------------------- main

struct Args(HashMap<String, String>);

impl Args {
    fn get<T: std::str::FromStr>(&self, k: &str, d: T) -> T {
        self.0.get(k).and_then(|v| v.parse().ok()).unwrap_or(d)
    }
    fn s(&self, k: &str, d: &str) -> String {
        self.0.get(k).cloned().unwrap_or_else(|| d.to_string())
    }
}

fn payload(size: usize) -> Vec<u8> {
    let mut p = vec![0x5a; size.max(8)];
    p[..8].copy_from_slice(&(EPOCH.elapsed().as_micros() as u64).to_le_bytes());
    p
}

#[tokio::main]
async fn main() {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    let mut map = HashMap::new();
    let mut i = 0;
    while i < raw.len() {
        if let Some(k) = raw[i].strip_prefix("--") {
            let v = raw.get(i + 1).cloned().unwrap_or_default();
            map.insert(k.to_string(), v);
            i += 2;
        } else {
            i += 1;
        }
    }
    let a = Args(map);
    let scenario = a.s("scenario", "storm");
    let n: usize = a.get("n", 1000);
    let port: u16 = a.get("port", 0);
    let pid: u32 = a.get("relay-pid", 0);
    let conc: usize = a.get("conc", 128);
    let out = a.0.get("out").cloned();
    let domain = a.s("domain", "relay.bench.test");
    if port == 0 || pid == 0 {
        eprintln!("usage: relay_scale_probe --port P --relay-pid PID --scenario storm|joinone|churn|bcast|topic --n N ...");
        std::process::exit(2);
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    let tls = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAny))
        .with_no_client_auth();
    let ctx = Arc::new(Ctx {
        port,
        domain: domain.clone(),
        tls: tokio_rustls::TlsConnector::from(Arc::new(tls)),
        next_port: AtomicU64::new(a.get("first-port", 10000)),
    });
    if let Some(f) = a.0.get("relay-stats") {
        let _ = STATS_FILE.set(f.clone());
    }
    let probe = RelayProbe::start(pid);
    let _ = *EPOCH;
    let fill = a.s("fill", "visible");
    let hidden_fill = fill == "hidden";
    let tag = json!({"scenario": scenario, "fill": fill});

    // Everyone connects first (not the subject of any phase but its own).
    let total = n + a.get::<usize>("extra", 0) + 1;
    let ph = phase(&probe, "connect");
    let clients = connect_many(&ctx, total, conc, hidden_fill).await;
    settle(Duration::from_millis(500), Duration::from_secs(10)).await;
    end_phase(&probe, ph, clients.len(), json!({"wanted": total, "failed_attempts": STATS.failed.load(Relaxed), "tag": tag}), &out);
    if clients.len() < total {
        eprintln!("only {} of {total} connected", clients.len());
    }
    let n = n.min(clients.len().saturating_sub(1));
    // clients[0] is the sender (always visible); clients[1..=n] the room; the rest extras.
    let sender = clients[0].clone();
    sender.is_sender.store(true, Relaxed);
    let room: Vec<Arc<Client>> = clients[1..=n].to_vec();
    let extras: Vec<Arc<Client>> = clients[n + 1..].to_vec();
    if hidden_fill {
        sender.send_text(json!({"type": "active"}));
    }

    // The room fills: every member joins at once (a join storm when visible).
    STATS.joined.store(0, Relaxed);
    let ph = phase(&probe, if hidden_fill { "fill_hidden" } else { "join_storm" });
    for c in &room {
        c.join();
    }
    let all_in = wait_joined(n as u64, Duration::from_secs(a.get("storm-cap-secs", 900))).await;
    let joined_secs = ph.t0.elapsed().as_secs_f64();
    let quiet = settle(Duration::from_secs(2), Duration::from_secs(a.get("storm-cap-secs", 900))).await;
    end_phase(&probe, ph, n, json!({"all_joined": all_in, "joined_secs": round3(joined_secs), "quiet": quiet,
        "joined": STATS.joined.load(Relaxed), "tag": tag}), &out);

    sender.join();
    wait_joined(n as u64 + 1, Duration::from_secs(60)).await;
    settle(Duration::from_secs(1), Duration::from_secs(120)).await;

    for sc in scenario.split(',') {
    match sc {
        "storm" => {}
        "rejoin_all" => {
            // Every member joins the room it already holds (what a door change makes each
            // client do, and the PeerLeft membership refresh): no announcement, but each
            // gets a full `members` list back.
            let ph = phase(&probe, "rejoin_all");
            let before = STATS.members.frames.load(Relaxed);
            for c in &room {
                c.send_text(json!({"type": "join", "room": ROOM}));
            }
            let start = Instant::now();
            while STATS.members.frames.load(Relaxed) - before < n as u64 && start.elapsed() < Duration::from_secs(600) {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            settle(Duration::from_secs(1), Duration::from_secs(600)).await;
            end_phase(&probe, ph, n, json!({"rejoins": n, "tag": tag}), &out);
        }
        "joinone" => {
            // Extras join one at a time: the marginal cost of one join into a room of N.
            let m = extras.len();
            STATS.join_lat_us.lock().unwrap().clear();
            let ph = phase(&probe, "join_one_by_one");
            for c in &extras {
                let before = STATS.joined.load(Relaxed);
                c.join();
                wait_joined(before + 1, Duration::from_secs(60)).await;
                settle(Duration::from_millis(200), Duration::from_secs(30)).await;
            }
            let mut lat = STATS.join_lat_us.lock().unwrap().clone();
            lat.sort();
            let med = lat.get(lat.len() / 2).copied().unwrap_or(0);
            end_phase(&probe, ph, n, json!({"joins": m, "join_reply_us_median": med,
                "join_reply_us_max": lat.last().copied().unwrap_or(0), "tag": tag}), &out);
        }
        "churn" => {
            // K members a second leave and come back (or blink inactive/active).
            let secs: f64 = a.get("churn-secs", 20.0);
            for mode in a.s("churn", "rejoin").split(',') {
            for k in a.s("churn-rates", "10").split(',').filter_map(|r| r.parse::<f64>().ok()) {
            let ph = phase(&probe, &format!("churn_{mode}_{k}per_s"));
            let every = Duration::from_secs_f64(1.0 / k);
            let deadline = Instant::now() + Duration::from_secs_f64(secs);
            let mut ops = 0u64;
            let mut tick = tokio::time::interval(every);
            while Instant::now() < deadline {
                tick.tick().await;
                let c = &room[rand::thread_rng().gen_range(0..room.len())];
                match mode {
                    "toggle" => {
                        c.send_text(json!({"type": "inactive"}));
                        let c = c.clone();
                        tokio::spawn(async move {
                            tokio::time::sleep(Duration::from_millis(500)).await;
                            c.send_text(json!({"type": "active"}));
                        });
                    }
                    _ => {
                        c.leave();
                        c.join();
                    }
                }
                ops += 1;
            }
            settle(Duration::from_secs(3), Duration::from_secs(120)).await;
            end_phase(&probe, ph, n, json!({"ops": ops, "rate": k, "mode": mode, "tag": tag}), &out);
            }
            }
        }
        "bcast" | "topic" => {
            let topic = sc == "topic";
            if topic {
                for c in room.iter().chain(std::iter::once(&sender)) {
                    c.send_text(json!({"type": "subscribe", "room": ROOM, "topics": [TOPIC]}));
                }
                settle(Duration::from_secs(1), Duration::from_secs(60)).await;
                // No answer confirms a subscribe; warm-up frames until nearly everyone hears one.
                let want = (n as u64 * 99) / 100;
                for _ in 0..120 {
                    let before = STATS.bin_topic.frames.load(Relaxed);
                    let mut f = vec![0x07];
                    f.extend_from_slice(ROOM.as_bytes());
                    f.push(0);
                    f.extend_from_slice(TOPIC.as_bytes());
                    f.push(0);
                    f.extend_from_slice(&payload(64));
                    sender.send_bin(f);
                    settle(Duration::from_millis(500), Duration::from_secs(30)).await;
                    if STATS.bin_topic.frames.load(Relaxed) - before >= want {
                        break;
                    }
                }
            }
            let size: usize = a.get("payload", 2048);
            for rate in a.s("rates", "1,10").split(',').filter_map(|r| r.parse::<f64>().ok()) {
                let secs: f64 = a.get("secs", 10.0);
                STATS.lat_reset();
                let ph = phase(&probe, &format!("{}_{}per_s", sc, rate));
                let every = Duration::from_secs_f64(1.0 / rate);
                let deadline = Instant::now() + Duration::from_secs_f64(secs);
                let mut tick = tokio::time::interval(every);
                let mut sent = 0u64;
                while Instant::now() < deadline {
                    tick.tick().await;
                    let mut f = Vec::with_capacity(size + 64);
                    f.push(if topic { 0x07 } else { 0x03 });
                    f.extend_from_slice(ROOM.as_bytes());
                    f.push(0);
                    if topic {
                        f.extend_from_slice(TOPIC.as_bytes());
                        f.push(0);
                    }
                    f.extend_from_slice(&payload(size));
                    sender.send_bin(f);
                    sent += 1;
                }
                let send_secs = ph.t0.elapsed().as_secs_f64();
                let drained = settle(Duration::from_secs(2), Duration::from_secs(300)).await;
                let s = STATS.snap();
                let got = d(if topic { s.bin_topic } else { s.bin_room }, if topic { ph.s0.bin_topic } else { ph.s0.bin_room }).0;
                end_phase(&probe, ph, n, json!({"rate": rate, "sent": sent, "payload": size, "send_secs": round3(send_secs),
                    "deliveries": got, "expected": sent * n as u64, "drained": drained,
                    "lat_p50_us": STATS.lat_pct(0.5), "lat_p99_us": STATS.lat_pct(0.99), "tag": tag}), &out);
            }
        }
        other => eprintln!("unknown scenario {other}"),
    }
    }

    let types = STATS.other_types.lock().unwrap().clone();
    if !types.is_empty() {
        println!("OTHER_TEXT_TYPES {}", serde_json::to_string(&types).unwrap_or_default());
    }
    for c in &clients {
        c.alive.store(false, Relaxed);
        let _ = c.tx.send(Message::Close(None));
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    let _ = sender.peer_id.len();
}
