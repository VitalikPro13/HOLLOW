//! ws_client against an in-process relay speaking RESUMABLE_SESSIONS_PLAN.md section 9:
//! sessions, counting, acks, resume, zombie windows, make before break, suspend, the
//! drain hint. The relay here is test code; the real one is `relay-uws`.

use std::collections::{HashMap, VecDeque};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, oneshot, Notify};
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::Message;

use super::*;
use crate::identity::native_identity::NativeKeypair;
use crate::node::relay_session::{self, Entry, Timing};

const ROOM: &str = "room-a";
const SENDER: &str = "12D3KooWSender";

fn quick() -> Timing {
    Timing {
        heartbeat: Duration::from_millis(500),
        heartbeat_background: Duration::from_secs(3),
        dead_after: Duration::from_millis(1000),
        nudge_quiet: Duration::from_millis(300),
        probe: Duration::from_millis(250),
        ack_after: Duration::from_millis(100),
        suspend_wait: Duration::from_millis(800),
        sleep_jump: Duration::from_secs(5),
        backoff_base: Duration::from_millis(20),
        backoff_cap: Duration::from_millis(200),
        realtime_retry: Duration::from_millis(100),
        auth_reply: Duration::from_secs(3),
        handshake: Duration::from_secs(3),
        replay_echo: Duration::from_millis(1500),
    }
}

// -- The relay --

enum Out {
    Frame(Message),
    /// Close with this code and reason, then drop the socket.
    Close(u16, &'static str),
    /// Drop the socket with no close frame: a reset, as a dead path or a killed relay.
    Kill,
}

struct Conn {
    tx: mpsc::UnboundedSender<Out>,
    zombie: Arc<AtomicBool>,
    wake: Arc<Notify>,
    sid: Option<String>,
    counted: usize,
}

struct Sess {
    in_h: u64,
    sent: u64,
    acked: u64,
    ring: VecDeque<(u64, Message)>,
    conn: Option<u64>,
}

impl Sess {
    fn ack(&mut self, h: u64) {
        if h < self.acked || h > self.sent {
            return;
        }
        while self.ring.front().is_some_and(|(seq, _)| *seq <= h) {
            self.ring.pop_front();
        }
        self.acked = h;
    }
}

#[derive(Default)]
struct Relay {
    offer_sessions: bool,
    door_key: String,
    conns: HashMap<u64, Conn>,
    next_conn: u64,
    /// Each connection's challenge nonce, by connection number.
    nonces: Vec<String>,
    sessions: HashMap<String, Sess>,
    /// Every auth frame: (v, session, in_h).
    auths: Vec<(u64, String, u64)>,
    /// Every counted client frame that reached the relay: (connection, frame).
    got: Vec<(u64, Message)>,
    hbs: Vec<u64>,
    acks: Vec<u64>,
    controls: Vec<String>,
    closes: Vec<(u64, u16, String)>,
    withhold_acks: bool,
    mute_hb_acks: bool,
    forget_sessions: bool,
    resume_h: Option<u64>,
    gap_next_resume: Option<u64>,
    reprove: bool,
    /// Reset connection number 0 after it counted this many frames.
    reset_first_after: Option<usize>,
}

impl Relay {
    fn binaries(&self) -> Vec<Vec<u8>> {
        self.got
            .iter()
            .filter_map(|(_, m)| match m {
                Message::Binary(b) if b.first() == Some(&0x03) => {
                    let at = b.iter().position(|&x| x == 0)?;
                    Some(b[at + 1..].to_vec())
                }
                _ => None,
            })
            .collect()
    }

    fn texts(&self) -> Vec<(u64, Value)> {
        self.got
            .iter()
            .filter_map(|(c, m)| match m {
                Message::Text(t) => serde_json::from_str(t).ok().map(|v| (*c, v)),
                _ => None,
            })
            .collect()
    }

    fn joins(&self) -> Vec<(u64, Value)> {
        self.texts().into_iter().filter(|(_, v)| v["type"] == "join").collect()
    }

    fn live_session(&mut self) -> Option<&mut Sess> {
        self.sessions.values_mut().next()
    }
}

struct FakeRelay {
    addr: SocketAddr,
    state: Arc<Mutex<Relay>>,
}

impl FakeRelay {
    async fn start(offer_sessions: bool) -> Self {
        Self::start_on(TcpListener::bind("127.0.0.1:0").await.unwrap(), offer_sessions, |_| {})
    }

    fn start_on(listener: TcpListener, offer_sessions: bool, tune: impl FnOnce(&mut Relay)) -> Self {
        let addr = listener.local_addr().unwrap();
        let mut relay = Relay { offer_sessions, ..Relay::default() };
        tune(&mut relay);
        let state = Arc::new(Mutex::new(relay));
        let accept_state = state.clone();
        tokio::spawn(async move {
            while let Ok((tcp, _)) = listener.accept().await {
                tokio::spawn(serve(accept_state.clone(), tcp));
            }
        });
        Self { addr, state }
    }

    fn url(&self) -> String {
        format!("ws://{}/ws", self.addr)
    }

    fn with<T>(&self, f: impl FnOnce(&mut Relay) -> T) -> T {
        f(&mut self.state.lock().unwrap())
    }

    async fn wait(&self, what: &str, within: Duration, mut done: impl FnMut(&mut Relay) -> bool) {
        let deadline = Instant::now() + within;
        loop {
            if self.with(&mut done) {
                return;
            }
            assert!(Instant::now() < deadline, "the relay never saw: {what}");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    /// A stream frame to the client: ringed under its session, written when live.
    fn push(&self, msg: Message) {
        self.with(|r| {
            let target = match r.sessions.values_mut().next() {
                Some(s) => {
                    s.sent += 1;
                    s.ring.push_back((s.sent, msg.clone()));
                    s.conn
                }
                None => r.conns.keys().max().copied(),
            };
            if let Some(conn) = target.and_then(|c| r.conns.get(&c))
                && !conn.zombie.load(Ordering::SeqCst)
            {
                let _ = conn.tx.send(Out::Frame(msg));
            }
        });
    }

    /// Text that is not a stream frame (an answer, a hint), to the newest connection.
    fn tell(&self, text: Value) {
        self.with(|r| {
            if let Some(conn) = r.conns.keys().max().and_then(|c| r.conns.get(c)) {
                let _ = conn.tx.send(Out::Frame(Message::Text(text.to_string().into())));
            }
        });
    }

    /// Every live connection stops reading and writing: frames vanish both ways.
    fn zombie(&self) {
        self.with(|r| {
            for c in r.conns.values() {
                c.zombie.store(true, Ordering::SeqCst);
                c.wake.notify_one();
            }
        });
    }

    fn kill(&self) {
        self.with(|r| {
            for c in r.conns.values() {
                let _ = c.tx.send(Out::Kill);
            }
        });
    }

    fn conn_count(&self) -> u64 {
        self.with(|r| r.next_conn)
    }
}

fn random_hex(bytes: usize) -> String {
    let mut b = vec![0u8; bytes];
    getrandom::fill(&mut b).unwrap();
    hex::encode(b)
}

fn verify_auth(auth: &Value, nonce: &str) -> bool {
    let s = |k: &str| auth[k].as_str().unwrap_or_default().to_string();
    let mode = if auth["fetch"] == true { "fetch" } else { "full" };
    let ts = auth["timestamp"].as_u64().unwrap_or_default();
    let message = if auth["v"] == 3 {
        relay_session::auth_v3_message(
            &s("domain"), nonce, &s("peer_id"), ts, mode, "", &s("session"), auth["in_h"].as_u64().unwrap_or(u64::MAX),
        )
    } else {
        auth_v2_message(&s("domain"), nonce, &s("peer_id"), ts, mode, "")
    };
    let Some(key) = crate::crypto::safety_number::pubkey_from_peer_id(&s("peer_id")) else { return false };
    let Ok(key) = ed25519_dalek::VerifyingKey::from_bytes(&key) else { return false };
    let Ok(sig) = base64::engine::general_purpose::STANDARD.decode(s("signature")) else { return false };
    let Ok(sig) = ed25519_dalek::Signature::from_slice(&sig) else { return false };
    s("nonce") == nonce && s("domain") == "127.0.0.1" && key.verify_strict(message.as_bytes(), &sig).is_ok()
}

async fn serve(state: Arc<Mutex<Relay>>, tcp: TcpStream) {
    let _ = tcp.set_zero_linger();
    let Ok(ws) = tokio_tungstenite::accept_async(tcp).await else { return };
    let (mut w, mut r) = ws.split();
    let nonce = random_hex(32);
    match r.next().await {
        Some(Ok(Message::Text(t))) if t.contains("auth_hello") => {}
        _ => return,
    }
    let (offer, door_key) = {
        let s = state.lock().unwrap();
        (s.offer_sessions, s.door_key.clone())
    };
    let mut challenge = json!({ "type": "auth_challenge", "nonce": nonce, "door_key": door_key });
    if offer {
        challenge["session"] = json!(1);
    }
    if w.send(Message::Text(challenge.to_string().into())).await.is_err() {
        return;
    }
    let auth: Value = match r.next().await {
        Some(Ok(Message::Text(t))) => serde_json::from_str(&t).unwrap_or_default(),
        _ => return,
    };
    if !verify_auth(&auth, &nonce) {
        let _ = w.send(Message::Text(r#"{"type":"auth_failed","error":"Authentication failed"}"#.into())).await;
        return;
    }

    let (tx, mut rx) = mpsc::unbounded_channel::<Out>();
    let zombie = Arc::new(AtomicBool::new(false));
    let wake = Arc::new(Notify::new());
    let text = |v: Value| Message::Text(v.to_string().into());
    // The answer, then a resume's replay, go out before anything the queue holds.
    let (id, first) = {
        let mut s = state.lock().unwrap();
        let id = s.next_conn;
        s.next_conn += 1;
        s.nonces.push(nonce.clone());
        let v = auth["v"].as_u64().unwrap_or(0);
        let session = auth["session"].as_str().unwrap_or_default().to_string();
        let in_h = auth["in_h"].as_u64().unwrap_or(0);
        s.auths.push((v, session.clone(), in_h));
        let mut first = Vec::new();
        let mut sid_of_conn = None;
        if v != 3 {
            first.push(text(json!({ "type": "auth_ok" })));
        } else {
            let resumable = !s.forget_sessions
                && s.sessions.get(&session).is_some_and(|x| in_h >= x.acked && in_h <= x.sent);
            if resumable {
                let gap = s.gap_next_resume.take();
                let forced_h = s.resume_h.take();
                let reprove = s.reprove;
                let sess = s.sessions.get_mut(&session).unwrap();
                let old = sess.conn.replace(id);
                sess.ack(in_h);
                let mut replay: Vec<Message> = sess.ring.iter().map(|(_, m)| m.clone()).collect();
                if let Some(n) = gap {
                    let n = n.min(replay.len() as u64);
                    replay.drain(..n as usize);
                    replay.insert(0, text(json!({ "type": "gap", "n": n })));
                    for _ in 0..n {
                        sess.ring.pop_front();
                    }
                }
                let h = forced_h.unwrap_or(sess.in_h);
                first.push(text(json!({
                    "type": "resumed", "h": h, "gap": gap.is_some(), "reprove": reprove, "grace_secs": 120, "hb_secs": 15,
                })));
                first.extend(replay);
                if let Some(c) = old.and_then(|o| s.conns.get(&o)) {
                    let _ = c.tx.send(Out::Close(1000, "moved"));
                }
                sid_of_conn = Some(session.clone());
            } else {
                let failed = session != "new";
                let reason = if s.sessions.contains_key(&session) { "bad_h" } else { "unknown" };
                s.sessions.clear();
                let sid = random_hex(16);
                s.sessions.insert(sid.clone(), Sess { in_h: 0, sent: 0, acked: 0, ring: VecDeque::new(), conn: Some(id) });
                let mut ok = json!({ "type": "auth_ok", "sid": sid, "grace_secs": 120, "hb_secs": 15 });
                if failed {
                    ok["resume_failed"] = json!(reason);
                }
                first.push(text(ok));
                sid_of_conn = Some(sid);
            }
        }
        s.conns.insert(id, Conn { tx: tx.clone(), zombie: zombie.clone(), wake: wake.clone(), sid: sid_of_conn, counted: 0 });
        (id, first)
    };
    for m in first {
        if w.send(m).await.is_err() {
            forget_conn(&state, id);
            return;
        }
    }
    loop {
        if zombie.load(Ordering::SeqCst) {
            // Hold the socket open and never touch it: a path that died silently.
            let _keep = (w, r);
            std::future::pending::<()>().await;
            return;
        }
        tokio::select! {
            m = r.next() => match m {
                Some(Ok(msg)) => {
                    if zombie.load(Ordering::SeqCst) {
                        continue;
                    }
                    on_client_frame(&state, id, msg);
                }
                _ => break,
            },
            out = rx.recv() => match out {
                Some(Out::Frame(m)) => {
                    if zombie.load(Ordering::SeqCst) {
                        continue;
                    }
                    if w.send(m).await.is_err() {
                        break;
                    }
                }
                Some(Out::Close(code, reason)) => {
                    let frame = tokio_tungstenite::tungstenite::protocol::CloseFrame { code: code.into(), reason: reason.into() };
                    let _ = w.send(Message::Close(Some(frame))).await;
                    tokio::time::sleep(Duration::from_millis(50)).await;
                    break;
                }
                Some(Out::Kill) | None => break,
            },
            _ = wake.notified() => {}
        }
    }
    forget_conn(&state, id);
}

fn forget_conn(state: &Arc<Mutex<Relay>>, id: u64) {
    let mut s = state.lock().unwrap();
    s.conns.remove(&id);
    for sess in s.sessions.values_mut() {
        if sess.conn == Some(id) {
            sess.conn = None;
        }
    }
}

fn on_client_frame(state: &Arc<Mutex<Relay>>, id: u64, msg: Message) {
    let mut s = state.lock().unwrap();
    let sid = s.conns.get(&id).and_then(|c| c.sid.clone());
    let tx = s.conns.get(&id).map(|c| c.tx.clone());
    let send = |v: Value| {
        if let Some(tx) = &tx {
            let _ = tx.send(Out::Frame(Message::Text(v.to_string().into())));
        }
    };
    match &msg {
        Message::Text(t) => {
            let v: Value = serde_json::from_str(t).unwrap_or_default();
            match v["type"].as_str().unwrap_or_default() {
                "hb" => {
                    let h = v["h"].as_u64().unwrap_or_default();
                    s.hbs.push(h);
                    let in_h = match sid.as_ref().and_then(|x| s.sessions.get_mut(x)) {
                        Some(sess) => {
                            sess.ack(h);
                            sess.in_h
                        }
                        None => 0,
                    };
                    if !s.mute_hb_acks {
                        send(json!({ "type": "hb_ack", "h": in_h }));
                    }
                    return;
                }
                "ack" => {
                    let h = v["h"].as_u64().unwrap_or_default();
                    s.acks.push(h);
                    if let Some(sess) = sid.as_ref().and_then(|x| s.sessions.get_mut(x)) {
                        sess.ack(h);
                    }
                    return;
                }
                kind @ ("inactive" | "active" | "end") => {
                    s.controls.push(kind.to_string());
                    return;
                }
                _ => {}
            }
        }
        Message::Binary(_) => {}
        Message::Close(frame) => {
            let (code, reason) = frame.as_ref().map(|f| (u16::from(f.code), f.reason.to_string())).unwrap_or((0, String::new()));
            s.closes.push((id, code, reason));
            return;
        }
        _ => return,
    }
    let withhold = s.withhold_acks;
    let in_h = sid.as_ref().and_then(|x| s.sessions.get_mut(x)).map(|sess| {
        sess.in_h += 1;
        sess.in_h
    });
    s.got.push((id, msg));
    if let Some(h) = in_h
        && !withhold
    {
        send(json!({ "type": "ack", "h": h }));
    }
    let reset_after = s.reset_first_after;
    if let Some(conn) = s.conns.get_mut(&id) {
        conn.counted += 1;
        if id == 0 && reset_after == Some(conn.counted) {
            let _ = conn.tx.send(Out::Kill);
        }
    }
}

// -- The client --

struct Client {
    cmd: mpsc::UnboundedSender<WsCommand>,
    ctl: mpsc::UnboundedSender<Control>,
    events: mpsc::UnboundedReceiver<WsEvent>,
    log: Vec<String>,
    directs: Vec<Vec<u8>>,
    _task: tokio::task::JoinHandle<()>,
}

fn keypair() -> NativeKeypair {
    NativeKeypair::from_secret_bytes(&[7; 32])
}

fn spawn_client_with(url: &str, timing: Timing, queued: Vec<WsCommand>) -> Client {
    let kp = keypair();
    let (cmd, cmd_rx) = mpsc::unbounded_channel();
    let (event_tx, events) = mpsc::unbounded_channel();
    let (ctl, ctl_rx) = mpsc::unbounded_channel();
    for c in queued {
        cmd.send(c).unwrap();
    }
    let task = spawn_with(
        url.to_string(),
        kp.peer_id(),
        kp.to_protobuf_encoding().unwrap(),
        base64::engine::general_purpose::STANDARD.encode(kp.public_key_protobuf()),
        timing,
        cmd_rx,
        event_tx,
        ctl_rx,
    );
    Client { cmd, ctl, events, log: Vec::new(), directs: Vec::new(), _task: task }
}

fn spawn_client(url: &str, timing: Timing) -> Client {
    spawn_client_with(url, timing, Vec::new())
}

fn label(e: &WsEvent) -> String {
    match e {
        WsEvent::Resumed { gap } => format!("Resumed{{gap:{gap}}}"),
        other => other.kind().to_string(),
    }
}

const SESSION_KINDS: [&str; 4] = ["Connected", "Suspended", "Resumed", "SessionLost"];

impl Client {
    fn send(&self, cmd: WsCommand) {
        self.cmd.send(cmd).unwrap();
    }

    fn post(&self, k: u8) {
        self.send(WsCommand::SendToRoom { room_code: ROOM.into(), data: vec![b'c', k] });
    }

    fn nudge(&self) {
        let _ = self.ctl.send(Control::Nudge { reason: "foreground".into(), external: true });
    }

    fn take(&mut self, e: &WsEvent) {
        if SESSION_KINDS.contains(&e.kind()) {
            self.log.push(label(e));
        }
        if let WsEvent::DirectMessage { data, .. } = e {
            self.directs.push(data.clone());
        }
    }

    /// Waits for the next event of `kind`, keeping the session events and directs seen.
    async fn wait_kind(&mut self, kind: &str, within: Duration) -> WsEvent {
        let deadline = Instant::now() + within;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let e = tokio::time::timeout(left, self.events.recv())
                .await
                .unwrap_or_else(|_| panic!("no {kind} within {within:?}; session events so far {:?}", self.log))
                .expect("the client stopped");
            self.take(&e);
            if e.kind() == kind {
                return e;
            }
        }
    }

    /// Drains what arrived without waiting for more.
    fn drain(&mut self) {
        while let Ok(e) = self.events.try_recv() {
            self.take(&e);
        }
    }

    async fn settle(&mut self, d: Duration) {
        let deadline = Instant::now() + d;
        while let Ok(Some(e)) = tokio::time::timeout(deadline.saturating_duration_since(Instant::now()), self.events.recv()).await {
            self.take(&e);
        }
    }

    async fn wait_directs(&mut self, want: &[&[u8]], within: Duration) {
        let deadline = Instant::now() + within;
        while self.directs.len() < want.len() {
            let left = deadline.saturating_duration_since(Instant::now());
            match tokio::time::timeout(left, self.events.recv()).await {
                Ok(Some(e)) => self.take(&e),
                _ => break,
            }
        }
        let got: Vec<&[u8]> = self.directs.iter().map(|d| d.as_slice()).collect();
        assert_eq!(got, want, "relay-to-client frames, each once and in order");
    }
}

fn direct(payload: &[u8]) -> Message {
    let mut frame = vec![0x06];
    frame.extend_from_slice(ROOM.as_bytes());
    frame.push(0);
    frame.extend_from_slice(SENDER.as_bytes());
    frame.push(0);
    frame.extend_from_slice(payload);
    Message::Binary(frame.into())
}

fn posts(ks: std::ops::RangeInclusive<u8>) -> Vec<Vec<u8>> {
    ks.map(|k| vec![b'c', k]).collect()
}

const T: Duration = Duration::from_secs(5);

// -- Tests --

/// The relay swallows frames both ways; the dead rule drops the socket, the resume
/// replays the relay's ring and the client's unacked frames, and nothing is lost or
/// doubled.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_zombie_window_loses_nothing_in_either_direction() {
    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    c.send(WsCommand::JoinRoom { room_code: ROOM.into() });
    c.send(WsCommand::Subscribe { room_code: ROOM.into(), topics: vec!["t1".into()] });
    for k in 1..=3 {
        c.post(k);
    }
    relay.wait("the first three posts", T, |r| r.binaries() == posts(1..=3)).await;
    relay.push(direct(b"s1"));
    c.wait_directs(&[b"s1"], T).await;
    relay.wait("the client's ack of s1", T, |r| r.live_session().is_some_and(|s| s.acked == 1)).await;

    relay.zombie();
    for k in 4..=6 {
        c.post(k);
    }
    for s in [b"s2", b"s3", b"s4"] {
        relay.push(direct(s));
    }
    c.wait_kind("Suspended", T).await;
    c.wait_kind("Resumed", T).await;
    assert_eq!(c.directs, [b"s1".to_vec()], "Resumed comes before any replayed frame");
    relay.wait("every post once, in order", T, |r| r.binaries() == posts(1..=6)).await;
    c.wait_directs(&[b"s1", b"s2", b"s3", b"s4"], T).await;
    c.settle(Duration::from_millis(300)).await;
    assert_eq!(c.log, ["Connected", "Suspended", "Resumed{gap:false}"]);
    let room_state = relay.with(|r| r.texts().iter().filter(|(_, v)| v["type"] == "join" || v["type"] == "subscribe").count());
    assert_eq!(room_state, 2, "a resume joins and subscribes nothing again");
    let auths = relay.with(|r| r.auths.clone());
    assert_eq!(auths[0], (3, "new".to_string(), 0));
    assert_eq!((auths[1].0, auths[1].2), (3, 1), "the resume names the session and the one frame it handled");
    assert!(relay_session::is_sid_shape(&auths[1].1));
}

/// A write that fails in the middle of a flush keeps every command behind it (plan 1.6:
/// the old flush dropped the batch tail).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failed_write_mid_flush_keeps_the_rest_of_the_queue() {
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let url = format!("ws://127.0.0.1:{port}/ws");
    const N: u8 = 8;
    let big = |k: u8| {
        let mut d = vec![k; 4 * 1024 * 1024];
        d[0] = b'c';
        d[1] = k;
        d
    };
    let queued = (1..=N).map(|k| WsCommand::SendToRoom { room_code: ROOM.into(), data: big(k) }).collect();
    let mut c = spawn_client_with(&url, quick(), queued);
    c.wait_kind("SessionLost", Duration::from_secs(10)).await;
    let listener = TcpListener::bind(("127.0.0.1", port)).await.unwrap();
    let relay = FakeRelay::start_on(listener, false, |r| r.reset_first_after = Some(1));
    relay
        .wait("the last queued frame", Duration::from_secs(25), |r| r.binaries().iter().any(|p| p[1] == N))
        .await;
    let first = relay.with(|r| r.got.iter().filter(|(c, _)| *c == 0).count());
    assert!((1..N as usize).contains(&first), "the first socket died mid-flush: {first} frame(s)");
}

/// The entry whose write failed on a session-less socket goes back in front of the queue
/// unchanged, ahead of everything behind it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failed_write_keeps_its_own_command_in_front() {
    let relay = FakeRelay::start(false).await;
    let kp = keypair();
    let dial = Dial {
        url: relay.url(),
        peer_id: kp.peer_id(),
        keypair_proto: kp.to_protobuf_encoding().unwrap(),
        pub_key_b64: base64::engine::general_purpose::STANDARD.encode(kp.public_key_protobuf()),
        license_key: None,
        fetch: false,
    };
    let (event_tx, _events) = mpsc::unbounded_channel();
    let mut client = super::Client::new(dial.clone(), quick(), event_tx, false);
    let opened = open_socket(dial, true, None, quick()).await.unwrap();
    let up = relay_session::judge(&opened.ask, false, opened.reply).unwrap();
    client.establish(opened.stream, opened.door, up).await;
    client.socket.as_mut().unwrap().write.close().await.unwrap();
    for k in 1..=3 {
        client.enqueue(WsCommand::SendToRoom { room_code: ROOM.into(), data: vec![b'c', k] });
    }
    client.pump().await;
    assert!(client.socket.is_none(), "the failed write dropped the socket");
    let mut left = Vec::new();
    while let Some(entry) = client.out.pop() {
        if let Entry::Command(WsCommand::SendToRoom { data, .. }) = entry {
            left.push(data);
        }
    }
    assert_eq!(left, posts(1..=3), "nothing moved, nothing went missing");
}

/// With a session, the same failure loses nothing at all: written frames wait for the
/// relay's ack and the resume sends what it did not count.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failed_write_mid_flush_loses_nothing_with_a_session() {
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let url = format!("ws://127.0.0.1:{port}/ws");
    let relay = FakeRelay::start_on(TcpListener::bind(("127.0.0.1", port)).await.unwrap(), true, |r| {
        r.reset_first_after = Some(2);
        r.withhold_acks = true;
    });
    let mut c = spawn_client(&url, quick());
    c.wait_kind("Connected", T).await;
    for k in 1..=8u8 {
        let mut d = vec![k; 1024 * 1024];
        d[0] = b'c';
        d[1] = k;
        c.send(WsCommand::SendToRoom { room_code: ROOM.into(), data: d });
    }
    c.wait_kind("Suspended", T).await;
    c.wait_kind("Resumed", T).await;
    relay
        .wait("all eight frames, each once", Duration::from_secs(10), |r| {
            r.binaries().iter().map(|p| p[1]).collect::<Vec<_>>() == (1..=8).collect::<Vec<u8>>()
        })
        .await;
}

/// A burst bigger than the unwritten bound (a file stream) loses nothing while the socket
/// carries it: the client takes commands from the node only as fast as it writes them.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_burst_bigger_than_the_queue_waits_in_the_node_channel() {
    let relay = FakeRelay::start(true).await;
    let t = Timing { dead_after: Duration::from_secs(20), ..quick() };
    let mut c = spawn_client(&relay.url(), t);
    c.wait_kind("Connected", T).await;
    relay.with(|r| {
        r.withhold_acks = true;
        r.mute_hb_acks = true;
    });
    const N: u8 = 48;
    for k in 1..=N {
        let mut d = vec![k; 1024 * 1024];
        d[0] = b'c';
        d[1] = k;
        c.send(WsCommand::SendToRoom { room_code: ROOM.into(), data: d });
    }
    relay.wait("the first 8 MiB, then flow control", T, |r| r.binaries().len() >= 7).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    let h = relay.with(|r| {
        r.withhold_acks = false;
        r.mute_hb_acks = false;
        r.live_session().map(|s| s.in_h).unwrap_or_default()
    });
    relay.tell(json!({ "type": "ack", "h": h }));
    relay
        .wait("every frame of the burst, in order", Duration::from_secs(30), |r| {
            r.binaries().iter().map(|p| p[1]).collect::<Vec<_>>() == (1..=N).collect::<Vec<u8>>()
        })
        .await;
    c.drain();
    assert_eq!(c.log, ["Connected"]);
}

/// Section 9.2: a gapped ring resumes with `gap:true`, and the gap counts as every frame
/// it stands for.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_resume_with_a_gap_says_so_and_counts_the_gap() {
    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    relay.zombie();
    for s in [b"s1", b"s2", b"s3", b"s4"] {
        relay.push(direct(s));
    }
    relay.with(|r| r.gap_next_resume = Some(2));
    c.wait_kind("Suspended", T).await;
    assert_eq!(label(&c.wait_kind("Resumed", T).await), "Resumed{gap:true}");
    assert!(c.directs.is_empty(), "Resumed comes before the replay");
    c.wait_directs(&[b"s3", b"s4"], T).await;
    relay.wait("an ack or heartbeat saying 4", T, |r| r.acks.contains(&4) || r.hbs.contains(&4)).await;
}

/// Section 9.8: a session the relay forgot reads as SessionLost then Connected, the
/// rooms are joined again before anything else, and the frames the lost session never
/// had acked go out again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failed_resume_is_session_lost_then_connected() {
    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    c.send(WsCommand::JoinRoom { room_code: ROOM.into() });
    c.send(WsCommand::Subscribe { room_code: ROOM.into(), topics: vec!["t1".into()] });
    relay.wait("the join", T, |r| r.joins().len() == 1).await;
    relay.with(|r| r.withhold_acks = true);
    c.post(1);
    relay.wait("the post", T, |r| r.binaries() == posts(1..=1)).await;
    relay.with(|r| r.forget_sessions = true);
    relay.kill();
    c.post(2);
    c.wait_kind("Suspended", T).await;
    c.wait_kind("Connected", T).await;
    assert_eq!(c.log, ["Connected", "Suspended", "SessionLost", "Connected"]);
    relay
        .wait("the replay, then the unacked posts, then the queue, on the new socket", T, |r| {
            let on_new: Vec<String> = r
                .got
                .iter()
                .filter(|(conn, _)| *conn == 1)
                .map(|(_, m)| match m {
                    Message::Text(t) => serde_json::from_str::<Value>(t).unwrap()["type"].as_str().unwrap().to_string(),
                    Message::Binary(b) => format!("bin:{}", b.last().copied().unwrap_or_default()),
                    _ => String::new(),
                })
                .collect();
            on_new == ["join", "subscribe", "bin:1", "bin:2"]
        })
        .await;
    let first = relay.with(|r| r.got.iter().find(|(conn, m)| *conn == 0 && matches!(m, Message::Binary(_))).map(|(_, m)| m.clone()));
    let again = relay.with(|r| r.got.iter().find(|(conn, m)| *conn == 1 && matches!(m, Message::Binary(_))).map(|(_, m)| m.clone()));
    assert_eq!(first, again, "the dead session's frame goes out again byte for byte");
}

/// Section 9.4: a relay that resumes us at an `h` above what we wrote is not talking
/// about our session.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_h_above_what_we_wrote_is_session_lost() {
    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    c.post(1);
    relay.wait("the post", T, |r| r.binaries().len() == 1).await;
    relay.with(|r| r.resume_h = Some(1000));
    relay.kill();
    c.wait_kind("Suspended", T).await;
    c.wait_kind("SessionLost", T).await;
    c.wait_kind("Connected", T).await;
    assert_eq!(c.log, ["Connected", "Suspended", "SessionLost", "Connected"]);
    let auths = relay.with(|r| r.auths.iter().map(|a| a.1.clone()).collect::<Vec<_>>());
    assert_eq!(auths.len(), 3);
    assert_eq!((auths[0].as_str(), auths[2].as_str()), ("new", "new"), "the third socket starts a fresh session");
}

/// Section 9.5: nothing heard for the dead window after a heartbeat closes the socket,
/// while a socket that keeps delivering is never judged dead, answered or not.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_dead_rule_drops_a_silent_socket_and_spares_a_busy_one() {
    let relay = FakeRelay::start(true).await;
    let t = quick();
    let mut c = spawn_client(&relay.url(), t.clone());
    c.wait_kind("Connected", T).await;
    relay.with(|r| r.mute_hb_acks = true);
    let busy_until = Instant::now() + t.dead_after * 3;
    let mut k = 0u32;
    let mut last_frame = Instant::now();
    while Instant::now() < busy_until {
        k += 1;
        relay.push(direct(format!("d{k}").as_bytes()));
        last_frame = Instant::now();
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    relay.zombie();
    c.drain();
    assert_eq!(c.log, ["Connected"], "a socket that keeps delivering is alive");

    c.wait_kind("Suspended", T).await;
    let took = last_frame.elapsed();
    assert!(took >= t.dead_after, "dead only a full window after a heartbeat that followed the last frame: {took:?}");
    assert!(
        took <= Duration::from_millis(100) + t.heartbeat + t.dead_after + Duration::from_millis(700),
        "found within a beat and the window: {took:?}"
    );
}

/// Section 9.6: a frame within the quiet window means a nudge does nothing at all.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_nudge_on_a_live_socket_within_2_s_does_nothing() {
    let relay = FakeRelay::start(true).await;
    let t = Timing { heartbeat: Duration::from_secs(30), ..quick() };
    let mut c = spawn_client(&relay.url(), t);
    c.wait_kind("Connected", T).await;
    relay.push(direct(b"fresh"));
    c.wait_directs(&[b"fresh"], T).await;
    c.nudge();
    c.settle(Duration::from_millis(250)).await;
    assert_eq!(relay.with(|r| r.hbs.len()), 0, "no probe for a socket that just spoke");
    assert_eq!(relay.conn_count(), 1);

    tokio::time::sleep(Duration::from_millis(400)).await;
    c.nudge();
    relay.wait("a probe for a quiet socket", T, |r| r.hbs.len() == 1).await;
    c.settle(Duration::from_millis(500)).await;
    assert_eq!(relay.conn_count(), 1, "an answered probe opens nothing");
    assert_eq!(c.log, ["Connected"]);
}

/// Section 9.6: a nudge on a dead socket races a new socket after the probe deadline,
/// long before the dead rule would fire, and the new socket takes the session over.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_nudge_on_a_dead_socket_makes_before_it_breaks() {
    let relay = FakeRelay::start(true).await;
    let t = Timing { heartbeat: Duration::from_secs(30), dead_after: Duration::from_secs(20), ..quick() };
    let mut c = spawn_client(&relay.url(), t);
    c.wait_kind("Connected", T).await;
    c.post(1);
    relay.wait("the post", T, |r| r.binaries().len() == 1).await;
    relay.zombie();
    c.post(2);
    relay.push(direct(b"lost-in-the-zombie"));
    tokio::time::sleep(Duration::from_millis(400)).await;
    let nudged = Instant::now();
    c.nudge();
    c.wait_kind("Resumed", T).await;
    assert!(nudged.elapsed() < Duration::from_secs(3), "the race won well inside the dead window: {:?}", nudged.elapsed());
    assert_eq!(c.log, ["Connected", "Suspended", "Resumed{gap:false}"]);
    relay.wait("the post written into the zombie", T, |r| r.binaries() == posts(1..=2)).await;
    c.wait_directs(&[b"lost-in-the-zombie"], T).await;
    assert_eq!(relay.conn_count(), 2);
}

/// Section 9.6: suspend writes the queue, waits for the relay's ack, closes 1000
/// `suspend`, and stays closed until the next nudge resumes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn suspend_flushes_closes_and_waits_for_a_nudge() {
    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    for k in 1..=5 {
        c.post(k);
    }
    let (done_tx, done_rx) = oneshot::channel();
    c.ctl.send(Control::Suspend(done_tx)).unwrap();
    tokio::time::timeout(T, done_rx).await.expect("suspend returns").unwrap();
    relay.with(|r| {
        assert_eq!(r.binaries(), posts(1..=5), "everything queued went out before the close");
        assert_eq!(r.live_session().map(|s| s.in_h), Some(5));
    });
    relay
        .wait("a 1000 suspend close", T, |r| r.closes.iter().any(|(_, code, reason)| *code == 1000 && reason == "suspend"))
        .await;
    c.wait_kind("Suspended", T).await;
    c.post(6);
    let _ = c.ctl.send(Control::Nudge { reason: "wake".into(), external: false });
    c.settle(Duration::from_millis(600)).await;
    assert_eq!(relay.conn_count(), 1, "closed until the app nudges; the client's own wake nudge does not count");
    c.nudge();
    c.wait_kind("Resumed", T).await;
    relay.wait("the post queued while suspended", T, |r| r.binaries() == posts(1..=6)).await;
    assert_eq!(c.log, ["Connected", "Suspended", "Resumed{gap:false}"]);
}

/// Section 9.1: a relay that does not offer sessions gets today's v2 frame and no
/// session frames, and still the fast liveness: a WebSocket ping is the heartbeat.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_without_sessions_gets_v2_and_the_faster_liveness() {
    let relay = FakeRelay::start(false).await;
    let t = quick();
    let mut c = spawn_client(&relay.url(), t.clone());
    c.wait_kind("Connected", T).await;
    c.post(1);
    relay.wait("the post", T, |r| r.binaries().len() == 1).await;
    tokio::time::sleep(t.heartbeat * 3).await;
    c.drain();
    assert_eq!(c.log, ["Connected"], "pings keep a healthy v2 socket alive");
    relay.with(|r| {
        assert_eq!(r.auths[0].0, 2, "v2 to a relay that offered nothing");
        assert!(r.hbs.is_empty() && r.acks.is_empty() && r.controls.is_empty(), "no session frames to an old relay");
    });
    let silent_from = Instant::now();
    relay.zombie();
    c.wait_kind("SessionLost", T).await;
    assert!(silent_from.elapsed() <= t.heartbeat + t.dead_after + Duration::from_millis(700));
    c.wait_kind("Connected", T).await;
    assert_eq!(c.log, ["Connected", "SessionLost", "Connected"]);
}

/// The lead's join rule: the node's join of a room right after our fresh-session replay
/// wrote the identical one (its Connected work echoing the replay) is dropped, once.
/// Every other join is written, identical or not: a re-join is how the node asks for a
/// fresh `members` (the stale-presence self-heal).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn only_the_nodes_echo_of_the_replay_is_dropped() {
    let relay = FakeRelay::start(true).await;
    let t = quick();
    let mut c = spawn_client(&relay.url(), t.clone());
    c.wait_kind("Connected", T).await;
    let joins_on = |r: &mut Relay, conn: u64| {
        r.joins().iter().filter(|(c, _)| *c == conn).map(|(_, v)| v["room"].as_str().unwrap().to_string()).collect::<Vec<_>>()
    };

    for room in [ROOM, ROOM, "room-b"] {
        c.send(WsCommand::JoinRoom { room_code: room.into() });
    }
    c.post(1);
    relay.wait("the first post", T, |r| r.binaries().len() == 1).await;
    assert_eq!(relay.with(|r| joins_on(r, 0)), [ROOM, ROOM, "room-b"], "a re-join is written: it asks for a fresh members");

    relay.kill();
    c.wait_kind("Resumed", T).await;
    c.send(WsCommand::JoinRoom { room_code: "room-b".into() });
    c.post(2);
    relay.wait("the second post", T, |r| r.binaries().len() == 2).await;
    assert_eq!(relay.with(|r| joins_on(r, 1)), ["room-b"], "a resume rejoins nothing; a join after it is written");

    relay.with(|r| r.forget_sessions = true);
    relay.kill();
    c.wait_kind("Connected", T).await;
    for room in [ROOM, "room-b", ROOM] {
        c.send(WsCommand::JoinRoom { room_code: room.into() });
    }
    c.post(3);
    relay.wait("the third post", T, |r| r.binaries().len() == 3).await;
    assert_eq!(
        relay.with(|r| joins_on(r, 2)),
        [ROOM, "room-b", ROOM],
        "the replay, each echo dropped once, then the self-heal re-join"
    );

    relay.kill();
    c.wait_kind("Connected", T).await;
    tokio::time::sleep(t.replay_echo + Duration::from_millis(300)).await;
    c.send(WsCommand::JoinRoom { room_code: ROOM.into() });
    c.post(4);
    relay.wait("the fourth post", T, |r| r.binaries().len() == 4).await;
    assert_eq!(relay.with(|r| joins_on(r, 3)), [ROOM, "room-b", ROOM], "outside the window a join is no echo");
}

/// Section 9.7: the drain hint delays the resume by what it names, then resumes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_drain_hint_waits_then_resumes() {
    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    relay.tell(json!({ "type": "reconnect", "after_ms": 600 }));
    tokio::time::sleep(Duration::from_millis(50)).await;
    let hinted = Instant::now();
    relay.kill();
    c.wait_kind("Suspended", T).await;
    c.wait_kind("Resumed", T).await;
    let took = hinted.elapsed();
    assert!(took >= Duration::from_millis(550), "waited for the hint: {took:?}");
    assert!(took < Duration::from_millis(2000), "then resumed at once: {took:?}");
    assert_eq!(relay.conn_count(), 2, "one reconnect, after the wait");
}

fn door_key() -> String {
    super::super::sealed_box::key_to_text(&super::super::sealed_box::public_of(&[0x22; 32]))
}

fn proof_for(relay: &FakeRelay, conn: usize, room: &str, door: [u8; 32]) -> Option<String> {
    let nonce = relay.with(|r| r.nonces[conn].clone());
    let session = RelaySession { domain: "127.0.0.1".into(), nonce, peer_id: keypair().peer_id(), door_key: door_key() };
    door_proof(&session, room, &door)
}

/// Section 9.8: door proofs keep the session's first nonce across a resume, and a
/// `reprove` resume proves every door again for the new socket.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn door_proofs_keep_the_sessions_nonce_until_reprove() {
    let relay = FakeRelay::start(true).await;
    relay.with(|r| r.door_key = door_key());
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    c.send(WsCommand::SetDoor { room_code: "srv".into(), door: Some(DoorSecret(zeroize::Zeroizing::new([0x11; 32]))) });
    c.send(WsCommand::JoinRoom { room_code: "srv".into() });
    let first = proof_for(&relay, 0, "srv", [0x11; 32]).unwrap();
    relay.wait("the proved join", T, |r| r.joins().iter().any(|(_, v)| v["door_proof"] == first.as_str())).await;

    relay.kill();
    c.wait_kind("Resumed", T).await;
    c.send(WsCommand::SetDoor { room_code: "srv".into(), door: Some(DoorSecret(zeroize::Zeroizing::new([0x12; 32]))) });
    let newer = proof_for(&relay, 0, "srv", [0x12; 32]).unwrap();
    relay
        .wait("the new door proved with the session's first nonce", T, |r| {
            r.joins().iter().any(|(conn, v)| *conn == 1 && v["door_proof"] == newer.as_str())
        })
        .await;

    relay.with(|r| r.reprove = true);
    relay.kill();
    c.wait_kind("Resumed", T).await;
    let reproved = proof_for(&relay, 2, "srv", [0x12; 32]).unwrap();
    relay
        .wait("every door proved again for the new socket", T, |r| {
            r.joins().iter().any(|(conn, v)| *conn == 2 && v["door_proof"] == reproved.as_str())
        })
        .await;
}

/// Acks go out after 16 frames or the ack window, and every heartbeat carries the count.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_client_acks_every_16_frames_or_after_the_window() {
    let relay = FakeRelay::start(true).await;
    let t = Timing { heartbeat: Duration::from_secs(30), ack_after: Duration::from_millis(300), ..quick() };
    let mut c = spawn_client(&relay.url(), t);
    c.wait_kind("Connected", T).await;
    for k in 0..20u8 {
        relay.push(direct(&[k]));
    }
    relay.wait("an ack at 16", T, |r| r.acks.contains(&16)).await;
    relay.wait("an ack at 20 after the window", T, |r| r.acks.contains(&20)).await;
    assert_eq!(relay.with(|r| r.acks.clone()), [16, 20]);
}
