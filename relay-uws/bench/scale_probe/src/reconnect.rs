//! `--scenario reconnect`: a carrier-NAT reconnect wave, every socket from this machine's ONE
//! address (DESIGN_RELAY_014 section 5, V1-V3). Phases, each one RESULT line:
//!   fresh    N new devices log in at once: all in, refusals, the start credit each was told
//!   zombies  every device keeps its socket open (a NAT rebind) and resumes on a new one
//!   restart  `--restart-cmd` restarts the relay; every device waits out its hint and resumes
//! `--host` may name a private LAN address (a test relay box); anything public is refused.

use super::{ident, json_type, Ident};
use base64::Engine;
use ed25519_dalek::Signer;
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering::Relaxed};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;
use tokio_tungstenite::tungstenite::Message;

type Tls = tokio_rustls::client::TlsStream<tokio::net::TcpStream>;
type Ws = tokio_tungstenite::WebSocketStream<Tls>;

/// Stream frames ws_client does not count (presence, control, answers).
const UNCOUNTED: [&str; 12] = [
    "auth_challenge", "auth_ok", "auth_failed", "resumed", "hb_ack", "ack", "reconnect", "members", "peer_joined",
    "peer_left", "presence", "kill_signal",
];

pub struct Target {
    pub host: IpAddr,
    pub port: u16,
    pub domain: String,
    pub tls: tokio_rustls::TlsConnector,
}

/// Loopback and private LAN addresses only: production is never a load target.
pub fn allowed_host(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_loopback() || v4.is_private() || v4.is_link_local(),
        IpAddr::V6(v6) => v6.is_loopback() || (v6.segments()[0] & 0xfe00) == 0xfc00,
    }
}

/// One device: its identity, its session and what its socket has counted.
struct Device {
    id: Ident,
    sid: Mutex<String>,
    h: Arc<AtomicU64>,
    /// The last reconnect hint the relay sent, -1 for none.
    hint_ms: Arc<AtomicI64>,
    /// The close code the relay ended the socket with, 0 while open.
    closed: Arc<AtomicU64>,
    sink: Mutex<Option<SplitSink<Ws, Message>>>,
    /// Which socket is the device's own now: a superseded socket's reader writes nothing.
    socket: Arc<AtomicU64>,
}

enum Login {
    Fresh { credit: i64 },
    Resumed,
    Lost,
    Refused(String),
}

async fn open(t: &Target) -> Result<(SplitSink<Ws, Message>, SplitStream<Ws>), String> {
    let tcp = tokio::net::TcpStream::connect(SocketAddr::new(t.host, t.port)).await.map_err(|e| format!("connect: {e}"))?;
    let _ = tcp.set_nodelay(true);
    let name = rustls::pki_types::ServerName::try_from(t.domain.clone()).map_err(|e| e.to_string())?;
    let tls = t.tls.connect(name, tcp).await.map_err(|e| format!("tls: {e}"))?;
    let url = format!("wss://{}/ws", t.domain);
    let (ws, _) = tokio_tungstenite::client_async(url, tls).await.map_err(|e| format!("ws: {e}"))?;
    Ok(ws.split())
}

async fn next_text(read: &mut SplitStream<Ws>) -> Result<String, String> {
    loop {
        match tokio::time::timeout(Duration::from_secs(30), read.next()).await {
            Ok(Some(Ok(Message::Text(t)))) => return Ok(t.to_string()),
            Ok(Some(Ok(Message::Close(c)))) => return Err(format!("closed {}", c.map(|c| u16::from(c.code)).unwrap_or(0))),
            Ok(Some(Ok(_))) => continue,
            other => return Err(format!("{other:?}")),
        }
    }
}

/// Logs `d` in on a new socket, asking for `session` ("new" or its sid), and starts its reader.
async fn login(t: &Target, d: &Arc<Device>, session: &str) -> Login {
    let (mut sink, mut read) = match open(t).await {
        Ok(x) => x,
        Err(e) => return Login::Refused(e),
    };
    if sink.send(Message::text(r#"{"type":"auth_hello"}"#)).await.is_err() {
        return Login::Refused("hello".into());
    }
    let nonce = match next_text(&mut read).await {
        Ok(t) => serde_json::from_str::<Value>(&t).ok().and_then(|v| v["nonce"].as_str().map(str::to_string)),
        Err(e) => return Login::Refused(e),
    };
    let Some(nonce) = nonce else { return Login::Refused("no challenge".into()) };
    let in_h = if session == "new" { 0 } else { d.h.load(Relaxed) };
    let ts = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
    let msg = format!("hollow-ws-auth3\n{}\n{}\n{}\n{}\nfull\n\n{}\n{}", t.domain, nonce, d.id.peer_id, ts, session, in_h);
    let sig = base64::engine::general_purpose::STANDARD.encode(d.id.key.sign(msg.as_bytes()).to_bytes());
    let auth = json!({
        "type": "auth", "v": 3, "peer_id": d.id.peer_id, "public_key": d.id.pub_b64, "timestamp": ts,
        "signature": sig, "nonce": nonce, "domain": t.domain, "session": session, "in_h": in_h,
    });
    if sink.send(Message::text(auth.to_string())).await.is_err() {
        return Login::Refused("auth send".into());
    }
    let answer = loop {
        match next_text(&mut read).await {
            Ok(t) if matches!(json_type(&t), "auth_ok" | "resumed" | "auth_failed") => break t,
            Ok(_) => continue,
            Err(e) => return Login::Refused(e),
        }
    };
    let v: Value = serde_json::from_str(&answer).unwrap_or_default();
    let out = match json_type(&answer) {
        "auth_failed" => return Login::Refused(answer),
        // Its `h` counts what the relay read from us; our own count of what we read goes on.
        "resumed" => Login::Resumed,
        _ => {
            *d.sid.lock().await = v["sid"].as_str().unwrap_or_default().to_string();
            d.h.store(0, Relaxed);
            if session == "new" { Login::Fresh { credit: v["credit"].as_i64().unwrap_or(-1) } } else { Login::Lost }
        }
    };
    d.hint_ms.store(-1, Relaxed);
    d.closed.store(0, Relaxed);
    *d.sink.lock().await = Some(sink);
    let (h, hint, closed, socket) = (d.h.clone(), d.hint_ms.clone(), d.closed.clone(), d.socket.clone());
    let mine = socket.fetch_add(1, Relaxed) + 1;
    tokio::spawn(async move {
        while let Some(Ok(m)) = read.next().await {
            if socket.load(Relaxed) != mine {
                return;
            }
            match m {
                Message::Text(t) => {
                    let ty = json_type(&t);
                    if ty == "reconnect" {
                        let v: Value = serde_json::from_str(&t).unwrap_or_default();
                        hint.store(v["after_ms"].as_i64().unwrap_or(0), Relaxed);
                    }
                    if !UNCOUNTED.contains(&ty) {
                        h.fetch_add(1, Relaxed);
                    }
                }
                Message::Binary(_) => {
                    h.fetch_add(1, Relaxed);
                }
                Message::Close(c) if socket.load(Relaxed) == mine => {
                    closed.store(c.map(|c| u16::from(c.code) as u64).unwrap_or(1005), Relaxed);
                    return;
                }
                _ => {}
            }
        }
        if socket.load(Relaxed) == mine {
            closed.store(1006, Relaxed);
        }
    });
    out
}

#[derive(Default)]
struct Tally {
    fresh: usize,
    resumed: usize,
    lost: usize,
    refused: Vec<String>,
    credits: Vec<i64>,
}

async fn wave(t: &Arc<Target>, devs: &[Arc<Device>], fresh: bool) -> (Tally, f64) {
    let t0 = Instant::now();
    let mut jobs = Vec::new();
    for d in devs {
        let (t, d) = (t.clone(), d.clone());
        jobs.push(tokio::spawn(async move {
            let session = if fresh { "new".to_string() } else { d.sid.lock().await.clone() };
            login(&t, &d, &session).await
        }));
    }
    let mut tally = Tally::default();
    for j in jobs {
        match j.await {
            Ok(Login::Fresh { credit }) => {
                tally.fresh += 1;
                tally.credits.push(credit);
            }
            Ok(Login::Resumed) => tally.resumed += 1,
            Ok(Login::Lost) => tally.lost += 1,
            Ok(Login::Refused(why)) => tally.refused.push(why),
            Err(e) => tally.refused.push(e.to_string()),
        }
    }
    (tally, t0.elapsed().as_secs_f64())
}

fn report(phase: &str, n: usize, tally: &Tally, secs: f64, extra: Value, out: &Option<String>) {
    let mut refused: Vec<String> = tally.refused.iter().map(|r| r.chars().take(80).collect()).collect();
    refused.sort();
    refused.dedup();
    let min_credit = tally.credits.iter().copied().min().unwrap_or(-1);
    let line = json!({
        "phase": phase, "n": n, "secs": (secs * 1000.0).round() / 1000.0, "fresh": tally.fresh,
        "resumed": tally.resumed, "session_lost": tally.lost, "refused": tally.refused.len(),
        "refusal_kinds": refused, "min_credit": min_credit, "extra": extra,
    });
    println!("RESULT {line}");
    if let Some(path) = out {
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(f, "{line}");
        }
    }
}

/// The three waves in an order the default limits allow from one address: fresh logins, a
/// wait for the address's bucket to refill, the zombie wave, then the restart.
pub async fn run(t: Target, n: usize, refill_secs: u64, restart_cmd: Option<String>, out: Option<String>) -> bool {
    let t = Arc::new(t);
    let devs: Vec<Arc<Device>> = (0..n)
        .map(|_| {
            Arc::new(Device {
                id: ident(),
                sid: Mutex::new(String::new()),
                h: Arc::new(AtomicU64::new(0)),
                hint_ms: Arc::new(AtomicI64::new(-1)),
                closed: Arc::new(AtomicU64::new(0)),
                sink: Mutex::new(None),
                socket: Arc::new(AtomicU64::new(0)),
            })
        })
        .collect();
    let mut pass = true;

    let (tally, secs) = wave(&t, &devs, true).await;
    pass &= tally.fresh == n && tally.refused.is_empty();
    report("reconnect_fresh", n, &tally, secs, json!({}), &out);
    for d in &devs {
        if let Some(s) = d.sink.lock().await.as_mut() {
            let _ = s.send(Message::text(r#"{"type":"join","room":"scale-probe-cgnat","pv":2}"#)).await;
        }
    }

    tokio::time::sleep(Duration::from_secs(refill_secs)).await;
    // The old sockets stay open: the relay must let each device take its own slot back.
    let old: Vec<_> = {
        let mut v = Vec::new();
        for d in &devs {
            v.push(d.sink.lock().await.take());
        }
        v
    };
    let (tally, secs) = wave(&t, &devs, false).await;
    pass &= tally.resumed == n && tally.refused.is_empty();
    report("reconnect_zombies", n, &tally, secs, json!({"old_sockets_open": old.iter().filter(|s| s.is_some()).count()}), &out);
    drop(old);

    let Some(cmd) = restart_cmd else { return pass };
    tokio::time::sleep(Duration::from_secs(2)).await;
    let t0 = Instant::now();
    let status = std::process::Command::new("sh").arg("-c").arg(&cmd).status();
    let restarted = status.map(|s| s.success()).unwrap_or(false);
    // Every socket closes; each device waits out the hint it was given (or 2 s), as ws_client does.
    let deadline = Instant::now() + Duration::from_secs(60);
    while Instant::now() < deadline && devs.iter().any(|d| d.closed.load(Relaxed) == 0) {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let hints: Vec<i64> = devs.iter().map(|d| d.hint_ms.load(Relaxed)).collect();
    let mut codes: std::collections::BTreeMap<u64, usize> = Default::default();
    for d in &devs {
        *codes.entry(d.closed.load(Relaxed)).or_default() += 1;
    }
    let mut jobs = Vec::new();
    for d in &devs {
        let (t, d) = (t.clone(), d.clone());
        jobs.push(tokio::spawn(async move {
            let wait = d.hint_ms.load(Relaxed);
            tokio::time::sleep(Duration::from_millis(if wait > 0 { wait as u64 } else { 2000 })).await;
            for _ in 0..30 {
                let sid = d.sid.lock().await.clone();
                match login(&t, &d, &sid).await {
                    Login::Refused(why) if why.starts_with("connect") => tokio::time::sleep(Duration::from_millis(500)).await,
                    other => return other,
                }
            }
            Login::Refused("relay never came back".into())
        }));
    }
    let mut tally = Tally::default();
    for j in jobs {
        match j.await {
            Ok(Login::Resumed) => tally.resumed += 1,
            Ok(Login::Lost) => tally.lost += 1,
            Ok(Login::Fresh { .. }) => tally.fresh += 1,
            Ok(Login::Refused(why)) => tally.refused.push(why),
            Err(e) => tally.refused.push(e.to_string()),
        }
    }
    let hinted = hints.iter().filter(|h| **h > 0).count();
    let (lo, hi) = (hints.iter().filter(|h| **h > 0).min().copied(), hints.iter().max().copied());
    pass &= restarted && tally.resumed == n && tally.refused.is_empty();
    report(
        "reconnect_restart",
        n,
        &tally,
        t0.elapsed().as_secs_f64(),
        json!({"restart_ok": restarted, "hinted": hinted, "hint_min_ms": lo, "hint_max_ms": hi, "close_codes": format!("{codes:?}")}),
        &out,
    );
    pass
}
