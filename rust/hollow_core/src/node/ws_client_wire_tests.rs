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
        resume_backoff_cap: Duration::from_millis(200),
        grace: Duration::from_secs(120),
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
    /// The `inactive` flag, kept across sockets as the relay keeps it.
    inactive: bool,
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
    /// Every TCP connection accepted, authenticated or not.
    tcp_accepts: usize,
    /// Drop every new TCP connection before the WebSocket upgrade.
    refuse_new: bool,
    /// Auth frames read, before `auth_delay`.
    auths_seen: usize,
    /// Hold each auth frame this long before answering it.
    auth_delay: Option<Duration>,
    /// `inactive` / `active` / `end` with the connection each came on.
    controls_on: Vec<(u64, String)>,
    /// The connection of each `members` burst the real relay would send: one per
    /// resume, one per `active` on a session.
    bursts: Vec<u64>,
    /// Resumes that took the session from a socket still open (make before break).
    live_transfers: usize,
    /// The connection each `hb` and each `ack` came on.
    hbs_on: Vec<u64>,
    acks_on: Vec<u64>,
    /// Answer every auth frame (after `auth_delay`) with `auth_failed`.
    refuse_auth: bool,
    /// Hold each challenge this long: a slow new path.
    challenge_delay: Option<Duration>,
    /// When each TCP connection was accepted.
    accept_times: Vec<Instant>,
    /// The `type` of every client text frame, with its connection, in arrival order.
    text_types: Vec<(u64, String)>,
    /// Send `now` on challenges and heartbeat answers, this many seconds off real time.
    clock_off_secs: Option<i64>,
    /// The circuit breaker's start credit a fresh session's `auth_ok` names.
    credit: Option<i64>,
    /// Its breaker enforces: `auth_ok` and `resumed` say `enforced`.
    enforced: bool,
    /// Answer the next auth frame with the breaker's `cooldown` refusal for this long.
    cooldown_next: Option<u64>,
    /// When each counted client frame arrived, beside `got`.
    got_at: Vec<Instant>,
    /// Every auth frame's timestamp.
    auth_stamps: Vec<u64>,
}

fn relay_now(off_secs: i64) -> u64 {
    let real = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
    (real as i64 + off_secs) as u64
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
                {
                    let mut r = accept_state.lock().unwrap();
                    r.tcp_accepts += 1;
                    r.accept_times.push(Instant::now());
                }
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
    if state.lock().unwrap().refuse_new {
        return;
    }
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
    if let Some(off) = state.lock().unwrap().clock_off_secs {
        challenge["now"] = json!(relay_now(off));
    }
    let held = state.lock().unwrap().challenge_delay;
    if let Some(d) = held {
        tokio::time::sleep(d).await;
    }
    if w.send(Message::Text(challenge.to_string().into())).await.is_err() {
        return;
    }
    let auth: Value = match r.next().await {
        Some(Ok(Message::Text(t))) => serde_json::from_str(&t).unwrap_or_default(),
        _ => return,
    };
    let delay = {
        let mut s = state.lock().unwrap();
        s.auths_seen += 1;
        s.auth_stamps.push(auth["timestamp"].as_u64().unwrap_or_default());
        s.auth_delay
    };
    if let Some(d) = delay {
        tokio::time::sleep(d).await;
    }
    let cooldown = state.lock().unwrap().cooldown_next.take();
    if let Some(ms) = cooldown {
        // As the relay does: the refusal before anything binds, closed 1013.
        let _ = w.send(Message::Text(json!({ "type": "auth_failed", "error": "cooldown", "after_ms": ms }).to_string().into())).await;
        let close = tokio_tungstenite::tungstenite::protocol::CloseFrame { code: 1013.into(), reason: "cooldown".into() };
        let _ = w.send(Message::Close(Some(close))).await;
        tokio::time::sleep(Duration::from_millis(100)).await;
        return;
    }
    let refuse = state.lock().unwrap().refuse_auth;
    if !verify_auth(&auth, &nonce) || refuse {
        let _ = w.send(Message::Text(r#"{"type":"auth_failed","error":"Authentication failed"}"#.into())).await;
        if refuse {
            // As the relay does: the refusal, its 1008 close, and no reset under it.
            let close = tokio_tungstenite::tungstenite::protocol::CloseFrame { code: 1008.into(), reason: "bad_auth".into() };
            let _ = w.send(Message::Close(Some(close))).await;
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
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
                let mut resumed = json!({
                    "type": "resumed", "h": h, "gap": gap.is_some(), "reprove": reprove, "grace_secs": 120, "hb_secs": 15,
                });
                if s.enforced {
                    resumed["enforced"] = json!(true);
                }
                first.push(text(resumed));
                first.extend(replay);
                if let Some(c) = old.and_then(|o| s.conns.get(&o)) {
                    let _ = c.tx.send(Out::Close(1000, "moved"));
                }
                if old.is_some() {
                    s.live_transfers += 1;
                }
                s.bursts.push(id);
                sid_of_conn = Some(session.clone());
            } else {
                let failed = session != "new";
                let reason = if s.sessions.contains_key(&session) { "bad_h" } else { "unknown" };
                s.sessions.clear();
                let sid = random_hex(16);
                s.sessions.insert(
                    sid.clone(),
                    Sess { in_h: 0, sent: 0, acked: 0, ring: VecDeque::new(), conn: Some(id), inactive: false },
                );
                let mut ok = json!({ "type": "auth_ok", "sid": sid, "grace_secs": 120, "hb_secs": 15 });
                if let Some(credit) = s.credit {
                    ok["credit"] = json!(credit);
                }
                if s.enforced {
                    ok["enforced"] = json!(true);
                }
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
        // Biased to the outbox: a kill queued by the frame just read lands before the
        // next frame is read, so a reset after N frames counts exactly N.
        tokio::select! {
            biased;
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
            m = r.next() => match m {
                Some(Ok(msg)) => {
                    if zombie.load(Ordering::SeqCst) {
                        continue;
                    }
                    on_client_frame(&state, id, msg);
                }
                _ => break,
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
            s.text_types.push((id, v["type"].as_str().unwrap_or_default().to_string()));
            match v["type"].as_str().unwrap_or_default() {
                "hb" => {
                    let h = v["h"].as_u64().unwrap_or_default();
                    s.hbs.push(h);
                    s.hbs_on.push(id);
                    let in_h = match sid.as_ref().and_then(|x| s.sessions.get_mut(x)) {
                        Some(sess) => {
                            sess.ack(h);
                            sess.in_h
                        }
                        None => 0,
                    };
                    if !s.mute_hb_acks {
                        let mut ack = json!({ "type": "hb_ack", "h": in_h });
                        if let Some(off) = s.clock_off_secs {
                            ack["now"] = json!(relay_now(off));
                        }
                        send(ack);
                    }
                    return;
                }
                "ack" => {
                    let h = v["h"].as_u64().unwrap_or_default();
                    s.acks.push(h);
                    s.acks_on.push(id);
                    if let Some(sess) = sid.as_ref().and_then(|x| s.sessions.get_mut(x)) {
                        sess.ack(h);
                    }
                    return;
                }
                kind @ ("inactive" | "active" | "end") => {
                    let r = &mut *s;
                    r.controls.push(kind.to_string());
                    r.controls_on.push((id, kind.to_string()));
                    if kind != "end"
                        && let Some(sess) = sid.as_ref().and_then(|x| r.sessions.get_mut(x))
                    {
                        sess.inactive = kind == "inactive";
                        if kind == "active" {
                            r.bursts.push(id);
                        }
                    }
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
    s.got_at.push(Instant::now());
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
    // One listener throughout: a port given back between the two phases can be taken
    // by another test's socket under load. Until the relay starts it drops every dial.
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}/ws", listener.local_addr().unwrap());
    let (stop, mut stopped) = oneshot::channel::<()>();
    let refuser = tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = &mut stopped => return listener,
                dial = listener.accept() => drop(dial),
            }
        }
    });
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
    stop.send(()).unwrap();
    let listener = refuser.await.unwrap();
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
    // By content, not count: a reset can eat a post's ack, and a lost session sends it again.
    let saw = |k: u8| move |r: &mut Relay| r.binaries().contains(&vec![b'c', k]);

    for room in [ROOM, ROOM, "room-b"] {
        c.send(WsCommand::JoinRoom { room_code: room.into() });
    }
    c.post(1);
    relay.wait("the first post", T, saw(1)).await;
    assert_eq!(relay.with(|r| joins_on(r, 0)), [ROOM, ROOM, "room-b"], "a re-join is written: it asks for a fresh members");

    relay.kill();
    c.wait_kind("Resumed", T).await;
    c.send(WsCommand::JoinRoom { room_code: "room-b".into() });
    c.post(2);
    relay.wait("the second post", T, saw(2)).await;
    assert_eq!(relay.with(|r| joins_on(r, 1)), ["room-b"], "a resume rejoins nothing; a join after it is written");

    relay.with(|r| r.forget_sessions = true);
    relay.kill();
    c.wait_kind("Connected", T).await;
    for room in [ROOM, "room-b", ROOM] {
        c.send(WsCommand::JoinRoom { room_code: room.into() });
    }
    c.post(3);
    relay.wait("the third post", T, saw(3)).await;
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
    relay.wait("the fourth post", T, saw(4)).await;
    assert_eq!(relay.with(|r| joins_on(r, 3)), [ROOM, "room-b", ROOM], "outside the window a join is no echo");
}

/// Section 9.7: the drain hint delays the resume by what it names, then resumes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_drain_hint_waits_then_resumes() {
    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    // The client counts the wait from when it reads the hint, which is after this.
    let hinted = Instant::now();
    relay.tell(json!({ "type": "reconnect", "after_ms": 600 }));
    tokio::time::sleep(Duration::from_millis(50)).await;
    relay.kill();
    c.wait_kind("Suspended", T).await;
    c.wait_kind("Resumed", T).await;
    let took = hinted.elapsed();
    assert!(took >= Duration::from_millis(600), "waited for the hint: {took:?}");
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

// -- The app's lifecycle and the move to a better network (plan 11.4, 3.7) --

fn spawn_routed_client(url: &str, timing: Timing, route: Arc<Mutex<Option<std::net::IpAddr>>>) -> Client {
    spawn_seamed_client(url, timing, route, Arc::new(AtomicBool::new(false)))
}

/// A client whose route lookup and call flag the test sets.
fn spawn_seamed_client(
    url: &str,
    timing: Timing,
    route: Arc<Mutex<Option<std::net::IpAddr>>>,
    in_call: Arc<AtomicBool>,
) -> Client {
    let kp = keypair();
    let (cmd, cmd_rx) = mpsc::unbounded_channel();
    let (event_tx, events) = mpsc::unbounded_channel();
    let (ctl, ctl_rx) = mpsc::unbounded_channel();
    let route: Route = Arc::new(move |relay| route.lock().unwrap().or_else(|| route_source(relay)));
    let realtime: Realtime = Arc::new(move || in_call.load(Ordering::SeqCst));
    let task = spawn_routed(
        url.to_string(),
        kp.peer_id(),
        kp.to_protobuf_encoding().unwrap(),
        base64::engine::general_purpose::STANDARD.encode(kp.public_key_protobuf()),
        timing,
        route,
        realtime,
        cmd_rx,
        event_tx,
        ctl_rx,
    );
    Client { cmd, ctl, events, log: Vec::new(), directs: Vec::new(), _task: task }
}

/// An address on no interface of this machine: the OS "now" routes the relay elsewhere.
fn new_network() -> Option<std::net::IpAddr> {
    Some("10.255.255.1".parse().unwrap())
}

impl Client {
    fn app_nudge(&self, reason: &str) {
        let _ = self.ctl.send(Control::Nudge { reason: reason.into(), external: true });
    }

    fn background(&self, background: bool) {
        let _ = self.ctl.send(Control::Background(background));
    }

    async fn suspend(&mut self) {
        let (done, wait) = oneshot::channel();
        self.ctl.send(Control::Suspend(done)).unwrap();
        tokio::time::timeout(T, wait).await.expect("suspend returns").unwrap();
        self.wait_kind("Suspended", T).await;
    }
}

impl Relay {
    fn controls_of(&self, conn: u64) -> Vec<String> {
        self.controls_on.iter().filter(|(c, _)| *c == conn).map(|(_, k)| k.clone()).collect()
    }

    fn holds_inactive(&mut self) -> Option<bool> {
        self.live_session().map(|s| s.inactive)
    }

    fn bursts_on(&self, conn: u64) -> usize {
        self.bursts.iter().filter(|c| **c == conn).count()
    }

    fn text_types_on(&self, conn: u64) -> Vec<String> {
        self.text_types.iter().filter(|(c, _)| *c == conn).map(|(_, t)| t.clone()).collect()
    }
}

/// The relay hides a device from presence only once it holds `inactive`, and a fresh
/// session starts shown: the client writes the flag before its join replay, or every
/// room a backgrounded phone joins again would announce it first.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_fresh_session_writes_inactive_before_its_join_replay() {
    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    c.background(true);
    c.send(WsCommand::JoinRoom { room_code: ROOM.into() });
    relay
        .wait("inactive and the join on the first session", T, |r| {
            r.controls_of(0) == ["inactive"] && r.joins().iter().any(|(conn, _)| *conn == 0)
        })
        .await;

    relay.with(|r| r.forget_sessions = true);
    relay.kill();
    c.wait_kind("Connected", T).await;
    relay.wait("the replayed join on the fresh session", T, |r| r.joins().iter().any(|(conn, _)| *conn == 1)).await;
    let order = relay.with(|r| r.text_types_on(1));
    let inactive = order.iter().position(|t| t == "inactive");
    let join = order.iter().position(|t| t == "join");
    assert!(
        inactive.zip(join).is_some_and(|(flag, join)| flag < join),
        "`inactive` comes before the first join on a fresh session: {order:?}"
    );
}

/// Pinned FFI semantics: a flag the app sets while no socket is open reaches the relay
/// on the next open, a resume and a fresh session alike.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_flag_set_with_no_socket_goes_out_on_the_next_open() {
    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    c.suspend().await;
    c.background(true);
    c.settle(Duration::from_millis(300)).await;
    assert_eq!(relay.with(|r| r.tcp_accepts), 1, "going to the background reopens nothing");

    c.app_nudge("call");
    c.wait_kind("Resumed", T).await;
    relay.wait("the resumed session held inactive", T, |r| r.holds_inactive() == Some(true)).await;
    assert_eq!(relay.with(|r| r.controls_of(1)), ["inactive"]);

    relay.with(|r| r.forget_sessions = true);
    relay.kill();
    c.wait_kind("Connected", T).await;
    relay.wait("the fresh session held inactive", T, |r| r.holds_inactive() == Some(true)).await;
    assert_eq!(relay.with(|r| r.controls_of(2)), ["inactive"]);
}

/// Plan 11.4: an app that comes back while suspended resumes with the relay holding it
/// active again, so presence is no longer withheld.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_app_back_while_suspended_resumes_active() {
    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    c.background(true);
    relay.wait("inactive on the first socket", T, |r| r.holds_inactive() == Some(true)).await;
    c.suspend().await;
    c.background(false);
    c.wait_kind("Resumed", T).await;
    relay.wait("active again", T, |r| r.holds_inactive() == Some(false)).await;
    assert_eq!(relay.with(|r| r.controls_of(1)), ["active"]);
    assert_eq!(relay.with(|r| r.bursts_on(1)), 2, "the resume's members, then the one `active` asks for");
}

/// `inactive` / `active` are uncounted and never resent: a flag written into a socket
/// that turned out dead is written again on the socket that resumes the session.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_flag_written_into_a_dead_socket_is_written_again() {
    let relay = FakeRelay::start(true).await;
    let t = Timing {
        heartbeat: Duration::from_secs(30),
        heartbeat_background: Duration::from_millis(200),
        dead_after: Duration::from_secs(20),
        ..quick()
    };
    let mut c = spawn_client(&relay.url(), t);
    c.wait_kind("Connected", T).await;
    c.background(true);
    relay.wait("inactive", T, |r| r.holds_inactive() == Some(true)).await;
    let beats = relay.with(|r| r.hbs.len());
    relay.wait("two heartbeats after it, answered", T, |r| r.hbs.len() >= beats + 2).await;
    tokio::time::sleep(Duration::from_millis(100)).await;

    relay.zombie();
    tokio::time::sleep(Duration::from_millis(400)).await;
    c.background(false);
    c.wait_kind("Resumed", T).await;
    relay.wait("active on the socket that resumed", T, |r| r.holds_inactive() == Some(false)).await;
    assert_eq!(relay.with(|r| r.controls_of(1)), ["active"]);
}

/// No flag frame, so no second `members` burst, when the relay already holds the app's
/// flag: a confirmed flag is not written again after a resume.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn no_flag_and_no_second_members_burst_when_nothing_changed() {
    let relay = FakeRelay::start(true).await;
    let t = Timing { heartbeat_background: Duration::from_millis(200), ..quick() };
    let mut c = spawn_client(&relay.url(), t);
    c.wait_kind("Connected", T).await;
    c.post(1);
    relay.wait("the post", T, |r| r.binaries().len() == 1).await;
    relay.kill();
    c.wait_kind("Resumed", T).await;
    c.settle(Duration::from_millis(300)).await;
    relay.with(|r| {
        assert!(r.controls_of(1).is_empty(), "the relay starts every session active: {:?}", r.controls_on);
        assert_eq!(r.bursts_on(1), 1, "only the resume's own members");
    });

    c.background(true);
    relay.wait("inactive", T, |r| r.controls_of(1) == ["inactive"]).await;
    let beats = relay.with(|r| r.hbs.len());
    relay.wait("two heartbeats after it, answered", T, |r| r.hbs.len() >= beats + 2).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    relay.kill();
    c.wait_kind("Resumed", T).await;
    c.settle(Duration::from_millis(300)).await;
    relay.with(|r| {
        assert!(r.controls_of(2).is_empty(), "the relay is known to hold inactive: {:?}", r.controls_on);
        assert_eq!(r.holds_inactive(), Some(true));
    });
}

/// Pinned FFI semantics: a suspend ends only when the app comes back (`foreground`,
/// `focus`, `call`, `push`, or `relay_set_background(false)`); network and wake nudges,
/// the client's own included, never reopen the socket, cut a suspend short or move it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn only_the_app_coming_back_ends_a_suspend() {
    let relay = FakeRelay::start(true).await;
    let route = Arc::new(Mutex::new(None));
    let mut c = spawn_routed_client(&relay.url(), quick(), route.clone());
    c.wait_kind("Connected", T).await;
    c.suspend().await;
    for reason in ["network", "wake", "other"] {
        c.app_nudge(reason);
    }
    let _ = c.ctl.send(Control::Nudge { reason: "wake".into(), external: false });
    c.settle(Duration::from_millis(600)).await;
    assert_eq!(relay.with(|r| r.tcp_accepts), 1, "closed on purpose stays closed");

    let mut conn = 0;
    for reopen in ["focus", "call", "push", "background"] {
        if reopen == "background" {
            c.background(false);
        } else {
            c.app_nudge(reopen);
        }
        c.wait_kind("Resumed", T).await;
        conn += 1;
        c.suspend().await;
        relay
            .wait("the suspend close", T, |r| r.closes.iter().any(|(id, code, why)| *id == conn && *code == 1000 && why == "suspend"))
            .await;
    }

    c.app_nudge("foreground");
    c.wait_kind("Resumed", T).await;
    conn += 1;
    relay.with(|r| {
        r.withhold_acks = true;
        r.mute_hb_acks = true;
    });
    c.post(1);
    relay.wait("the post", T, |r| r.binaries().len() == 1).await;
    let accepts = relay.with(|r| r.tcp_accepts);
    let (done, wait) = oneshot::channel();
    c.ctl.send(Control::Suspend(done)).unwrap();
    tokio::time::sleep(Duration::from_millis(150)).await;
    *route.lock().unwrap() = new_network();
    c.app_nudge("network");
    tokio::time::timeout(T, wait).await.expect("suspend returns").unwrap();
    relay
        .wait("a suspend a network nudge did not cut short", T, |r| {
            r.closes.iter().any(|(id, code, why)| *id == conn && *code == 1000 && why == "suspend")
        })
        .await;
    c.settle(Duration::from_millis(600)).await;
    assert_eq!(relay.with(|r| r.tcp_accepts), accepts, "nor moved to a new socket");
}

/// A probe that was out when the app suspended is not raced: a socket raced past the
/// suspend would reopen what the app closed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_probe_out_when_the_app_suspends_is_never_raced() {
    let relay = FakeRelay::start(true).await;
    let t = Timing { heartbeat: Duration::from_secs(30), ..quick() };
    let mut c = spawn_client(&relay.url(), t);
    c.wait_kind("Connected", T).await;
    relay.with(|r| {
        r.withhold_acks = true;
        r.mute_hb_acks = true;
    });
    c.post(1);
    relay.wait("the post", T, |r| r.binaries().len() == 1).await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    c.app_nudge("foreground");
    relay.wait("the probe", T, |r| r.hbs.len() == 1).await;
    c.suspend().await;
    c.settle(Duration::from_millis(600)).await;
    assert_eq!(c.log, ["Connected", "Suspended"]);
    assert_eq!(relay.with(|r| r.tcp_accepts), 1, "no socket raced past the suspend");
}

/// A move whose new socket fails judges the old socket from a fresh heartbeat, not from
/// one that was out before the move.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failed_move_judges_the_old_socket_afresh() {
    let relay = FakeRelay::start(true).await;
    let t = Timing { heartbeat: Duration::from_secs(30), dead_after: Duration::from_millis(400), ..quick() };
    let mut c = spawn_routed_client(&relay.url(), t, Arc::new(Mutex::new(new_network())));
    c.wait_kind("Connected", T).await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    relay.with(|r| {
        r.mute_hb_acks = true;
        r.auth_delay = Some(Duration::from_millis(600));
        r.refuse_auth = true;
    });
    c.app_nudge("foreground");
    relay.wait("the probe", T, |r| r.hbs.len() == 1).await;
    c.app_nudge("network");
    relay.wait("the move's auth", T, |r| r.auths_seen == 2).await;
    relay.with(|r| r.mute_hb_acks = false);
    c.settle(Duration::from_millis(1200)).await;
    assert_eq!(c.log, ["Connected"], "the old socket answered the heartbeat after the failed move");
    assert_eq!(relay.with(|r| r.tcp_accepts), 2);
}

/// A race or a move may take the session off the old socket, so an answer heard there
/// after it started proves no flag arrived.
#[test]
fn a_second_socket_makes_the_old_ones_answers_prove_nothing() {
    let kp = keypair();
    let dial = Dial {
        url: "ws://127.0.0.1:9/ws".into(),
        peer_id: kp.peer_id(),
        keypair_proto: kp.to_protobuf_encoding().unwrap(),
        pub_key_b64: base64::engine::general_purpose::STANDARD.encode(kp.public_key_protobuf()),
        license_key: None,
        fetch: false,
    };
    for purpose in [Purpose::Race, Purpose::Move] {
        let (event_tx, _events) = mpsc::unbounded_channel();
        let mut client = super::Client::new(dial.clone(), quick(), event_tx, false);
        client.flag.fresh_session();
        client.flag.wrote(true);
        client.start_attempt(purpose);
        client.flag.beat_sent();
        client.flag.answered();
        client.flag.new_socket();
        assert!(client.flag.needs(true), "{purpose:?}");
    }
}

/// Coalescing: while a probe is out or a connect is under way, more nudges, the
/// foreground `relay_set_background(false)` among them, add nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nudges_coalesce_into_one_probe_or_one_connect() {
    let relay = FakeRelay::start(true).await;
    let t = Timing { heartbeat: Duration::from_secs(30), ..quick() };
    let mut c = spawn_client(&relay.url(), t);
    c.wait_kind("Connected", T).await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    relay.with(|r| r.mute_hb_acks = true);
    c.background(false);
    relay.wait("the probe", T, |r| r.hbs.len() == 1).await;
    for reason in ["foreground", "focus", "call", "network"] {
        c.app_nudge(reason);
    }
    c.settle(Duration::from_millis(120)).await;
    relay.with(|r| {
        assert_eq!(r.hbs.len(), 1, "one probe while it is out");
        assert!(r.controls_of(0).is_empty(), "the relay already holds active: {:?}", r.controls_on);
        r.mute_hb_acks = false;
    });
    c.wait_kind("Resumed", T).await;

    c.suspend().await;
    let accepts = relay.with(|r| {
        r.auth_delay = Some(Duration::from_millis(400));
        r.tcp_accepts
    });
    c.background(false);
    relay.wait("the connect under way", T, |r| r.tcp_accepts == accepts + 1).await;
    for reason in ["foreground", "focus", "call", "network"] {
        c.app_nudge(reason);
    }
    c.wait_kind("Resumed", T).await;
    c.settle(Duration::from_millis(300)).await;
    assert_eq!(relay.with(|r| r.tcp_accepts), accepts + 1, "one connect");
}

/// While a move is under way the old socket gets nothing: no queued frame, heartbeat or
/// ack is written into it (the flag: `a_network_change_moves_...`).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_move_writes_nothing_into_the_old_socket() {
    let relay = FakeRelay::start(true).await;
    let t = Timing { heartbeat: Duration::from_millis(150), ack_after: Duration::from_millis(100), ..quick() };
    let mut c = spawn_routed_client(&relay.url(), t, Arc::new(Mutex::new(new_network())));
    c.wait_kind("Connected", T).await;
    relay.with(|r| r.auth_delay = Some(Duration::from_millis(600)));
    relay.push(direct(b"s1"));
    c.wait_directs(&[b"s1"], T).await;
    c.app_nudge("network");
    relay.wait("the move's auth", T, |r| r.auths_seen == 2).await;
    let before = relay.with(|r| (r.hbs_on.clone(), r.acks_on.clone(), r.got.len()));
    c.post(1);
    c.wait_kind("Resumed", T).await;
    relay.with(|r| {
        let on_old = |seen: &[u64]| seen.iter().filter(|c| **c == 0).count();
        assert_eq!(on_old(&r.hbs_on), on_old(&before.0), "no heartbeat");
        assert_eq!(on_old(&r.acks_on), on_old(&before.1), "no ack");
        assert!(r.got[before.2..].iter().all(|(conn, _)| *conn == 1), "no queued frame");
    });
}

/// Plan 3.7: a network change that routes the relay through another local address moves
/// the session to a new socket while the old one still works. The old socket is left
/// unread meanwhile, so what the relay wrote into it comes back once, in the replay.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_network_change_moves_the_session_before_the_old_socket_breaks() {
    let relay = FakeRelay::start(true).await;
    let route = Arc::new(Mutex::new(None));
    let t = Timing { heartbeat: Duration::from_secs(30), ..quick() };
    let mut c = spawn_routed_client(&relay.url(), t, route.clone());
    c.wait_kind("Connected", T).await;
    c.send(WsCommand::JoinRoom { room_code: ROOM.into() });
    c.post(1);
    relay.wait("the post", T, |r| r.binaries() == posts(1..=1)).await;
    relay.push(direct(b"s1"));
    c.wait_directs(&[b"s1"], T).await;
    relay.wait("the client's ack of s1", T, |r| r.live_session().is_some_and(|s| s.acked == 1)).await;

    *route.lock().unwrap() = new_network();
    relay.with(|r| r.auth_delay = Some(Duration::from_millis(500)));
    c.app_nudge("network");
    relay.wait("the move's auth", T, |r| r.auths_seen == 2).await;
    relay.push(direct(b"s2"));
    relay.push(direct(b"s3"));
    c.post(2);
    c.background(true);
    c.app_nudge("network");
    c.app_nudge("foreground");
    c.wait_kind("Resumed", T).await;
    relay.with(|r| r.auth_delay = None);
    c.wait_directs(&[b"s1", b"s2", b"s3"], T).await;
    relay.wait("every post once, in order", T, |r| r.binaries() == posts(1..=2)).await;
    c.settle(Duration::from_millis(300)).await;
    assert_eq!(c.log, ["Connected", "Suspended", "Resumed{gap:false}"]);
    assert_eq!(c.directs.len(), 3, "nothing delivered twice");
    relay.with(|r| {
        assert!(r.acks.iter().chain(&r.hbs).all(|h| *h <= 3), "the client counted what the relay sent: {:?} {:?}", r.acks, r.hbs);
        assert_eq!(r.live_transfers, 1, "the session moved off a socket that was still open");
        assert_eq!(r.tcp_accepts, 2, "one move at a time");
        assert_eq!((r.auths[1].0, r.auths[1].2), (3, 1), "a resume counting only what the old socket delivered");
        assert!(r.closes.is_empty(), "the client never closed the old socket; the relay did");
        assert_eq!(r.joins().len(), 1, "a move rejoins nothing");
        assert_eq!(r.got.iter().filter(|(conn, _)| *conn == 0).count(), 2, "the join and the first post only");
        assert_eq!((r.controls_of(0), r.controls_of(1)), (vec![], vec!["inactive".to_string()]), "nothing is written into the old socket");
    });

    *route.lock().unwrap() = None;
    tokio::time::sleep(Duration::from_millis(400)).await;
    c.app_nudge("network");
    c.settle(Duration::from_millis(500)).await;
    assert_eq!(relay.with(|r| r.tcp_accepts), 2, "the new socket is on the OS's route now");
}

/// The app suspending in the middle of a move: the move is dropped, the old socket closes
/// on purpose and stays closed, and what the relay wrote into the unread socket comes
/// back once on the resume.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_suspend_during_a_move_cancels_it() {
    let relay = FakeRelay::start(true).await;
    let t = Timing { heartbeat: Duration::from_secs(30), ..quick() };
    let mut c = spawn_routed_client(&relay.url(), t, Arc::new(Mutex::new(new_network())));
    c.wait_kind("Connected", T).await;
    relay.push(direct(b"s1"));
    c.wait_directs(&[b"s1"], T).await;
    relay.with(|r| r.auth_delay = Some(Duration::from_millis(500)));
    c.app_nudge("network");
    relay.wait("the move's auth", T, |r| r.auths_seen == 2).await;
    relay.push(direct(b"s2"));
    c.suspend().await;
    c.settle(Duration::from_millis(800)).await;
    assert_eq!(c.log, ["Connected", "Suspended"], "suspended means closed, the move included");
    relay.with(|r| r.auth_delay = None);
    c.app_nudge("foreground");
    c.wait_kind("Resumed", T).await;
    relay.push(direct(b"s3"));
    c.wait_directs(&[b"s1", b"s2", b"s3"], T).await;
    c.settle(Duration::from_millis(300)).await;
    assert_eq!(c.directs.len(), 3, "nothing delivered twice");
}

/// A network event that leaves the relay's route alone (a VPN or virtual adapter coming
/// and going) costs nothing but the probe.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_network_event_on_the_same_route_costs_only_the_probe() {
    let relay = FakeRelay::start(true).await;
    let t = Timing { heartbeat: Duration::from_secs(30), ..quick() };
    let mut c = spawn_routed_client(&relay.url(), t, Arc::new(Mutex::new(None)));
    c.wait_kind("Connected", T).await;
    relay.push(direct(b"fresh"));
    c.wait_directs(&[b"fresh"], T).await;
    c.app_nudge("network");
    c.settle(Duration::from_millis(250)).await;
    assert_eq!(relay.with(|r| r.hbs.len()), 0, "a socket that just spoke is not even probed");
    tokio::time::sleep(Duration::from_millis(400)).await;
    c.app_nudge("network");
    c.settle(Duration::from_millis(500)).await;
    relay.with(|r| assert_eq!((r.hbs.len(), r.tcp_accepts), (1, 1)));
    assert_eq!(c.log, ["Connected"]);
}

/// A move whose new socket fails leaves the old socket as it was: no event, nothing
/// lost, the old socket carries on.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failed_move_keeps_the_old_socket() {
    let relay = FakeRelay::start(true).await;
    let t = Timing { heartbeat: Duration::from_secs(30), ..quick() };
    let mut c = spawn_routed_client(&relay.url(), t, Arc::new(Mutex::new(new_network())));
    c.wait_kind("Connected", T).await;
    relay.with(|r| r.refuse_new = true);
    c.app_nudge("network");
    relay.wait("the refused move", T, |r| r.tcp_accepts == 2).await;
    c.settle(Duration::from_millis(300)).await;
    c.post(1);
    relay.push(direct(b"s1"));
    relay.wait("the post on the old socket", T, |r| r.got.iter().filter(|(conn, _)| *conn == 0).count() == 1).await;
    c.wait_directs(&[b"s1"], T).await;
    assert_eq!(c.log, ["Connected"]);
    assert_eq!(relay.conn_count(), 1);
}

/// On a relay without sessions a new socket is a fresh login that drops what was in
/// flight on the old one, so a network change only probes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_without_sessions_is_only_probed_on_a_network_change() {
    let relay = FakeRelay::start(false).await;
    let t = Timing { heartbeat: Duration::from_secs(30), ..quick() };
    let mut c = spawn_routed_client(&relay.url(), t, Arc::new(Mutex::new(new_network())));
    c.wait_kind("Connected", T).await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    c.app_nudge("network");
    c.settle(Duration::from_millis(600)).await;
    assert_eq!(relay.with(|r| r.tcp_accepts), 1);
    assert_eq!(c.log, ["Connected"]);
}

/// A move holds nothing while its new socket is still being set up (a captive portal or a
/// slow path can take seconds): the old socket keeps carrying both ways until the new one
/// has the relay's challenge.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_move_holds_nothing_while_its_socket_is_dialled() {
    let relay = FakeRelay::start(true).await;
    let t = Timing { heartbeat: Duration::from_secs(30), ..quick() };
    let mut c = spawn_routed_client(&relay.url(), t, Arc::new(Mutex::new(new_network())));
    c.wait_kind("Connected", T).await;
    relay.with(|r| r.challenge_delay = Some(Duration::from_millis(800)));
    c.app_nudge("network");
    relay.wait("the move's socket", T, |r| r.tcp_accepts == 2).await;
    let sent = Instant::now();
    relay.push(direct(b"s1"));
    c.post(1);
    c.wait_directs(&[b"s1"], T).await;
    assert!(sent.elapsed() < Duration::from_millis(400), "delivered while the new socket waited: {:?}", sent.elapsed());
    relay
        .wait("the post on the old socket", T, |r| r.got.iter().any(|(conn, m)| *conn == 0 && matches!(m, Message::Binary(_))))
        .await;
    c.wait_kind("Resumed", T).await;
    relay.with(|r| r.challenge_delay = None);
    relay.push(direct(b"s2"));
    c.post(2);
    c.wait_directs(&[b"s1", b"s2"], T).await;
    relay.wait("both posts once, in order", T, |r| r.binaries() == posts(1..=2)).await;
    c.settle(Duration::from_millis(300)).await;
    assert_eq!(c.directs.len(), 2, "nothing delivered twice");
    assert_eq!(c.log, ["Connected", "Suspended", "Resumed{gap:false}"]);
}

/// A call in the background keeps the foreground heartbeat, so its signalling has fast
/// liveness; the background beat comes back once the call ends.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_call_in_the_background_keeps_the_foreground_heartbeat() {
    let relay = FakeRelay::start(true).await;
    let t = Timing { heartbeat: Duration::from_millis(150), heartbeat_background: Duration::from_secs(5), ..quick() };
    let in_call = Arc::new(AtomicBool::new(false));
    let mut c = spawn_seamed_client(&relay.url(), t, Arc::new(Mutex::new(None)), in_call.clone());
    c.wait_kind("Connected", T).await;
    c.background(true);
    relay.wait("inactive", T, |r| r.controls_of(0) == ["inactive"]).await;
    let beats = |relay: &FakeRelay| relay.with(|r| r.hbs.len());
    let idle = beats(&relay);
    tokio::time::sleep(Duration::from_millis(700)).await;
    assert_eq!(beats(&relay), idle, "the background beat");

    in_call.store(true, Ordering::SeqCst);
    let _ = c.ctl.send(Control::Realtime);
    let calling = beats(&relay);
    tokio::time::sleep(Duration::from_millis(700)).await;
    assert!(beats(&relay) >= calling + 3, "the foreground beat while the call lasts: {}", beats(&relay) - calling);

    in_call.store(false, Ordering::SeqCst);
    let _ = c.ctl.send(Control::Realtime);
    tokio::time::sleep(Duration::from_millis(250)).await;
    let ended = beats(&relay);
    tokio::time::sleep(Duration::from_millis(700)).await;
    assert_eq!(beats(&relay), ended, "the background beat once the call ended");
    c.drain();
    assert_eq!(c.log, ["Connected"]);
}

/// While the relay can still resume our session, a path that comes back by itself (no OS
/// event to nudge) is tried again within the short cap; past the grace, or once the relay
/// refused us, the full backoff.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_held_session_retries_within_the_short_cap_until_the_grace_ends_or_a_refusal() {
    let t = Timing {
        backoff_base: Duration::from_millis(20),
        backoff_cap: Duration::from_secs(3),
        resume_backoff_cap: Duration::from_millis(100),
        grace: Duration::from_millis(2500),
        ..quick()
    };
    let ms = Duration::from_millis;
    let tries = |relay: &FakeRelay, from: Instant, to: Instant| {
        relay.with(|r| r.accept_times.iter().filter(|at| **at >= from && **at < to).count())
    };

    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), t.clone());
    c.wait_kind("Connected", T).await;
    relay.with(|r| r.refuse_new = true);
    relay.kill();
    c.wait_kind("Suspended", T).await;
    let suspended = Instant::now();
    tokio::time::sleep_until(suspended + ms(2000)).await;
    let early = tries(&relay, suspended + ms(500), suspended + ms(2000));
    assert!(early >= 8, "{early} tries in 1.5 s inside the grace");
    tokio::time::sleep_until(suspended + ms(5000)).await;
    let late = tries(&relay, suspended + ms(3000), suspended + ms(5000));
    assert!(late <= 5, "{late} tries in 2 s past the grace");

    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), Timing { grace: Duration::from_secs(30), ..t });
    c.wait_kind("Connected", T).await;
    relay.with(|r| r.refuse_auth = true);
    relay.kill();
    c.wait_kind("Suspended", T).await;
    let suspended = Instant::now();
    tokio::time::sleep_until(suspended + ms(3000)).await;
    let refused = tries(&relay, suspended + ms(1500), suspended + ms(3000));
    assert!(refused <= 4, "{refused} refused tries in 1.5 s");

    relay.with(|r| r.refuse_auth = false);
    c.wait_kind("Resumed", Duration::from_secs(10)).await;
    relay.with(|r| r.refuse_new = true);
    relay.kill();
    c.wait_kind("Suspended", T).await;
    let suspended = Instant::now();
    tokio::time::sleep_until(suspended + ms(2000)).await;
    let again = tries(&relay, suspended + ms(500), suspended + ms(2000));
    assert!(again >= 8, "{again} tries in 1.5 s: a refusal is forgotten once a socket is up");
}

// -- A hostile relay against the client (handshake review, RESUMABLE_SESSIONS_PLAN.md
// section 4; audit file rs_handshake_review.md) --

/// A relay that resumes us below what it already acked is not describing our session:
/// the client starts over instead of resending into numbers it cannot trust.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hostile_relay_a_resume_below_its_own_ack_is_session_lost() {
    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    for k in 1..=3 {
        c.post(k);
    }
    relay.wait("three posts, each acked", T, |r| r.binaries().len() == 3 && r.live_session().is_some_and(|s| s.in_h == 3)).await;
    c.settle(Duration::from_millis(300)).await;
    relay.with(|r| r.resume_h = Some(1));
    relay.kill();
    c.wait_kind("Suspended", T).await;
    c.wait_kind("SessionLost", T).await;
    c.wait_kind("Connected", T).await;
    assert_eq!(c.log, ["Connected", "Suspended", "SessionLost", "Connected"]);
    let auths = relay.with(|r| r.auths.iter().map(|a| a.1.clone()).collect::<Vec<_>>());
    assert_eq!(auths.last().map(String::as_str), Some("new"), "the next socket asks for a fresh session");
}

/// A gap the relay says stands for 2^64-1 frames neither panics nor wedges the client: the
/// count saturates, the next resume is refused, and a fresh session carries on.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hostile_relay_a_gap_of_2_pow_64_neither_panics_nor_wedges() {
    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    relay.push(Message::Text(json!({ "type": "gap", "n": u64::MAX }).to_string().into()));
    relay.push(direct(b"after-the-gap"));
    c.wait_directs(&[b"after-the-gap"], T).await;
    relay.wait("an ack naming the saturated count", T, |r| r.acks.contains(&u64::MAX) || r.hbs.contains(&u64::MAX)).await;
    relay.kill();
    c.wait_kind("Suspended", T).await;
    c.wait_kind("Connected", T).await;
    assert_eq!(c.log, ["Connected", "Suspended", "SessionLost", "Connected"]);
    assert_eq!(relay.with(|r| r.auths[1].2), u64::MAX, "the resume named the count it held");
    c.post(9);
    relay.wait("a post on the fresh session", T, |r| r.binaries() == posts(9..=9)).await;
}

/// Auth answers arriving after the handshake are not answers: a mid-stream `resumed` or
/// `auth_ok` changes no session and no sid the client resumes with later.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hostile_relay_answers_outside_the_handshake_change_nothing() {
    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    let sid = relay.with(|r| r.sessions.keys().next().cloned().unwrap());
    let planted = "ffeeddccbbaa99887766554433221100";
    relay.tell(json!({ "type": "resumed", "h": 0, "gap": true, "reprove": true, "grace_secs": 1, "hb_secs": 1 }));
    relay.tell(json!({ "type": "auth_ok", "sid": planted, "resume_failed": "unknown" }));
    relay.tell(json!({ "type": "auth_failed", "error": "license_key_required" }));
    relay.tell(json!({ "type": "auth_challenge", "nonce": "00".repeat(32), "door_key": "k", "session": 1 }));
    relay.push(direct(b"still-here"));
    c.wait_directs(&[b"still-here"], T).await;
    c.settle(Duration::from_millis(300)).await;
    assert_eq!(c.log, ["Connected"], "nothing happened to the session");
    relay.kill();
    c.wait_kind("Resumed", T).await;
    assert_eq!(relay.with(|r| r.auths[1].1.clone()), sid, "the resume names the session the handshake gave");
}

/// A drain hint naming the longest wait there is still yields to the app: a nudge resumes
/// at once.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hostile_relay_a_drain_hint_cannot_outwait_a_nudge() {
    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    relay.tell(json!({ "type": "reconnect", "after_ms": u64::MAX }));
    tokio::time::sleep(Duration::from_millis(50)).await;
    relay.kill();
    c.wait_kind("Suspended", T).await;
    c.settle(Duration::from_millis(300)).await;
    assert_eq!(relay.conn_count(), 1, "the hint is honoured");
    let nudged = Instant::now();
    c.nudge();
    c.wait_kind("Resumed", T).await;
    assert!(nudged.elapsed() < Duration::from_secs(2), "a nudge ends the wait: {:?}", nudged.elapsed());
}

// r1-clock
/// Issue #72: a client whose clock is five minutes off signs the relay's time, so the
/// relay's verify (the fake checks the signature over the stamp) passes; the node hears
/// the offset, and again when a heartbeat answer shows it moved.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_skewed_clock_signs_the_relays_time_and_hears_the_offset() {
    let _clock = super::super::relay_clock::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let relay = FakeRelay::start(true).await;
    relay.with(|r| r.clock_off_secs = Some(-300));
    let mut c = spawn_client(&relay.url(), quick());
    let told = c.wait_kind("ClockOffset", T).await;
    c.wait_kind("Connected", T).await;
    let want = relay_now(-300);
    let stamp = relay.with(|r| r.auth_stamps[0]);
    assert!(stamp + 2 >= want && stamp <= want, "signed {stamp}, relay time {want}");
    let WsEvent::ClockOffset { offset_ms: Some(offset_ms) } = told else { panic!("{told:?}") };
    assert!((-301_000..=-298_500).contains(&offset_ms), "offset {offset_ms}");

    relay.with(|r| r.clock_off_secs = Some(120));
    let WsEvent::ClockOffset { offset_ms: Some(offset_ms) } = c.wait_kind("ClockOffset", T).await else {
        panic!("no re-measure")
    };
    assert!((118_500..=121_000).contains(&offset_ms), "a heartbeat answer re-measures: {offset_ms}");

    // The relay is swapped for one that tells no time: the offset is forgotten and the
    // node told so.
    relay.with(|r| r.clock_off_secs = None);
    relay.kill();
    let told = c.wait_kind("ClockOffset", T).await;
    assert!(matches!(told, WsEvent::ClockOffset { offset_ms: None }), "{told:?}");
    assert_eq!(super::super::relay_clock::offset_ms(), None);
    super::super::relay_clock::forget_for_test();
}

/// A relay older than 0.12.1 sends no time: the login carries our own clock, as before.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_without_a_clock_gets_ours() {
    let _clock = super::super::relay_clock::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    let ours = relay_now(0);
    let stamp = relay.with(|r| r.auth_stamps[0]);
    assert!(stamp + 2 >= ours && stamp <= ours, "signed {stamp}, our clock {ours}");
}

// r1-review
/// A fresh login the relay refuses (no session held, the issue #72 case) climbs the
/// backoff ladder on its own: its tries thin out as a held session's refusal does.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_login_backs_off_fully() {
    let t = Timing {
        backoff_base: Duration::from_millis(20),
        backoff_cap: Duration::from_secs(3),
        resume_backoff_cap: Duration::from_millis(100),
        ..quick()
    };
    let ms = Duration::from_millis;
    let relay = FakeRelay::start(true).await;
    relay.with(|r| r.refuse_auth = true);
    let start = Instant::now();
    let mut c = spawn_client(&relay.url(), t);
    tokio::time::sleep_until(start + ms(4000)).await;
    c.drain();
    let late = relay.with(|r| r.accept_times.iter().filter(|at| **at >= start + ms(2500)).count());
    assert!(late <= 4, "{late} refused tries in 1.5 s with no nudge");
}

/// After the relay refused us, a nudge (on desktop every window focus) must not dial
/// past the backoff: each such dial is another socket against the address's
/// new-connection window.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn r1_review_nudges_after_a_refusal_keep_the_backoff() {
    let t = Timing {
        backoff_base: Duration::from_millis(20),
        backoff_cap: Duration::from_secs(3),
        resume_backoff_cap: Duration::from_millis(100),
        ..quick()
    };
    let ms = Duration::from_millis;
    let relay = FakeRelay::start(true).await;
    relay.with(|r| r.refuse_auth = true);
    let start = Instant::now();
    let mut c = spawn_client(&relay.url(), t);
    tokio::time::sleep_until(start + ms(1000)).await;
    for i in 0..15u32 {
        c.nudge();
        tokio::time::sleep_until(start + ms(1000 + 200 * u64::from(i + 1))).await;
    }
    c.drain();
    let tries = relay.with(|r| r.accept_times.iter().filter(|at| **at >= start + ms(1000)).count());
    assert!(tries <= 6, "{tries} refused tries in 3 s of nudges");
}

/// A refusal while a call is live (ringing, a VC, a lobby, link presenting) still backs
/// off: `retry_wait` gives the steady call interval (1 s in production) whatever the
/// relay said, so a refused login dials once a second for as long as the call lasts.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn r1_review_a_refused_login_during_a_call_backs_off() {
    let t = Timing {
        backoff_base: Duration::from_millis(20),
        backoff_cap: Duration::from_secs(3),
        resume_backoff_cap: Duration::from_millis(100),
        realtime_retry: Duration::from_millis(100),
        ..quick()
    };
    let ms = Duration::from_millis;
    let relay = FakeRelay::start(true).await;
    relay.with(|r| r.refuse_auth = true);
    let in_call = Arc::new(AtomicBool::new(true));
    let start = Instant::now();
    let mut c = spawn_seamed_client(&relay.url(), t, Arc::new(Mutex::new(None)), in_call);
    tokio::time::sleep_until(start + ms(4000)).await;
    c.drain();
    let late = relay.with(|r| r.accept_times.iter().filter(|at| **at >= start + ms(2500)).count());
    assert!(late <= 4, "{late} refused tries in 1.5 s during a call");
}

/// The other side of the refusal rule: during a call, an ordinary lost relay (no
/// refusal) is still redialled at the steady call interval, never up the ladder.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_call_redials_a_lost_relay_at_the_call_interval() {
    let t = Timing {
        backoff_base: Duration::from_millis(20),
        backoff_cap: Duration::from_secs(3),
        resume_backoff_cap: Duration::from_millis(100),
        realtime_retry: Duration::from_millis(100),
        ..quick()
    };
    let ms = Duration::from_millis;
    let relay = FakeRelay::start(true).await;
    let in_call = Arc::new(AtomicBool::new(true));
    let mut c = spawn_seamed_client(&relay.url(), t, Arc::new(Mutex::new(None)), in_call);
    c.wait_kind("Connected", T).await;
    relay.with(|r| r.refuse_new = true);
    relay.kill();
    let start = Instant::now();
    tokio::time::sleep_until(start + ms(2500)).await;
    c.drain();
    let late = relay.with(|r| r.accept_times.iter().filter(|at| **at >= start + ms(1000)).count());
    assert!(late >= 8, "only {late} redials in 1.5 s during a call");
}

/// A login that succeeds after refusals clears them: the next ordinary loss during a
/// call is redialled at the call interval again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_login_after_a_refusal_clears_it() {
    let t = Timing {
        backoff_base: Duration::from_millis(20),
        backoff_cap: Duration::from_millis(800),
        resume_backoff_cap: Duration::from_millis(100),
        realtime_retry: Duration::from_millis(100),
        ..quick()
    };
    let ms = Duration::from_millis;
    let relay = FakeRelay::start(true).await;
    relay.with(|r| r.refuse_auth = true);
    let in_call = Arc::new(AtomicBool::new(true));
    let mut c = spawn_seamed_client(&relay.url(), t, Arc::new(Mutex::new(None)), in_call);
    tokio::time::sleep(ms(1200)).await;
    relay.with(|r| r.refuse_auth = false);
    c.wait_kind("Connected", T).await;
    relay.with(|r| r.refuse_new = true);
    relay.kill();
    let start = Instant::now();
    tokio::time::sleep_until(start + ms(2500)).await;
    c.drain();
    let late = relay.with(|r| r.accept_times.iter().filter(|at| **at >= start + ms(1000)).count());
    assert!(late >= 8, "only {late} redials in 1.5 s: the old refusal still holds the ladder");
}

/// After a refusal a network change still buys one immediate retry (a new network may
/// be a new address), and only one until a login succeeds.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn after_a_refusal_one_network_change_retries_at_once() {
    // The ladder's full jitter can draw any wait down to zero: a long base keeps its own
    // dials out of the counts, which measure only what the network changes dial.
    let t = Timing {
        backoff_base: Duration::from_secs(30),
        backoff_cap: Duration::from_secs(60),
        resume_backoff_cap: Duration::from_millis(100),
        nudge_quiet: Duration::from_millis(50),
        ..quick()
    };
    let ms = Duration::from_millis;
    let relay = FakeRelay::start(true).await;
    relay.with(|r| r.refuse_auth = true);
    let c = spawn_client(&relay.url(), t.clone());
    relay.wait("the first refusal", T, |r| r.auths_seen >= 1).await;
    tokio::time::sleep(ms(300)).await;
    let network = || {
        let _ = c.ctl.send(Control::Nudge { reason: "network".into(), external: true });
    };
    let nudged = Instant::now();
    network();
    tokio::time::sleep(ms(300)).await;
    // A connect younger than the quiet window stands for the nudge (nudges coalesce).
    let (after_first, dialled) = relay.with(|r| {
        (r.tcp_accepts, r.accept_times.iter().any(|at| *at + t.nudge_quiet >= nudged))
    });
    assert!(dialled, "the first network change after a refusal dials at once");
    for _ in 0..20 {
        network();
        tokio::time::sleep(ms(100)).await;
    }
    let later = relay.with(|r| r.tcp_accepts) - after_first;
    assert!(later <= 4, "{later} dials for 20 later network changes: they must wait for the ladder");
}

// -- The circuit breaker's pacing (relay_pace, G2) --

fn server_room(n: u8) -> String {
    format!("{:040x}", u128::from(n) + 1)
}

/// A relay with a breaker names the start credit; joins of rooms the node gave no bound for
/// are priced as the biggest server and go only while the mirror keeps the reserve.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_breaker_relay_paces_a_burst_of_joins() {
    let relay = FakeRelay::start_on(TcpListener::bind("127.0.0.1:0").await.unwrap(), true, |r| {
        r.credit = Some(20_000);
        r.enforced = true;
    });
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    for n in 0..4 {
        c.send(WsCommand::JoinRoom { room_code: server_room(n) });
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(relay.with(|r| r.joins().len()), 2, "20,000 W pays two big joins above the reserve");
    relay.wait("every join, as the mirror refills", Duration::from_secs(6), |r| r.joins().len() == 4).await;
}

/// Control frames never wait, but the relay charges them, so they come off the mirror and
/// hold back the next priced frame.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn control_frames_come_off_the_mirror() {
    let relay = FakeRelay::start_on(TcpListener::bind("127.0.0.1:0").await.unwrap(), true, |r| {
        r.credit = Some(20_000);
        r.enforced = true;
    });
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    for n in 0..30 {
        c.send(WsCommand::RoomBound { room_code: server_room(n), devices: 1 });
        c.send(WsCommand::JoinRoom { room_code: server_room(n) });
    }
    relay.wait("thirty small joins", T, |r| r.joins().len() == 30).await;
    // Each flag write costs one W per joined room plus itself: about 12,400 W in all.
    for i in 0..400 {
        c.background(i % 2 == 0);
    }
    relay.wait("the flag writes", T, |r| r.controls.len() >= 400).await;
    c.send(WsCommand::JoinRoom { room_code: server_room(200) });
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(relay.with(|r| r.joins().len()), 30, "the flags spent what a big join needs above the reserve");
    relay.wait("the big join once the mirror refilled", Duration::from_secs(20), |r| r.joins().len() == 31).await;
}

/// A room bound from the node prices a join by what the room holds.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_room_bound_lowers_the_price() {
    let relay = FakeRelay::start_on(TcpListener::bind("127.0.0.1:0").await.unwrap(), true, |r| {
        r.credit = Some(20_000);
        r.enforced = true;
    });
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    for n in 0..20 {
        c.send(WsCommand::RoomBound { room_code: server_room(n), devices: 10 });
        c.send(WsCommand::JoinRoom { room_code: server_room(n) });
    }
    relay.wait("twenty joins of small servers at once", Duration::from_millis(800), |r| r.joins().len() == 20).await;
}

/// While a big join waits, a small frame for a room nothing ahead of it touches goes
/// first; one for the waiting join's room keeps its place.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_small_frame_passes_a_paced_join_but_never_its_own_room() {
    let relay = FakeRelay::start_on(TcpListener::bind("127.0.0.1:0").await.unwrap(), true, |r| {
        r.credit = Some(20_000);
        r.enforced = true;
    });
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    c.send(WsCommand::JoinRoom { room_code: ROOM.into() });
    for n in 0..3 {
        c.send(WsCommand::JoinRoom { room_code: server_room(n) });
    }
    c.send(WsCommand::SendDirect { room_code: server_room(2), target_peer: "12D3KooWPeer".into(), data: b"after".to_vec() });
    c.send(WsCommand::SendDirect { room_code: ROOM.into(), target_peer: "12D3KooWOther".into(), data: b"call".to_vec() });
    relay.wait("the call signal", T, |r| r.got.iter().any(|(_, m)| matches!(m, Message::Binary(b) if b.ends_with(b"call")))).await;
    let order: Vec<String> = relay.with(|r| {
        r.got
            .iter()
            .map(|(_, m)| match m {
                Message::Binary(b) if b.ends_with(b"call") => "call".to_string(),
                Message::Binary(b) if b.ends_with(b"after") => "after".to_string(),
                Message::Text(t) => serde_json::from_str::<Value>(t).ok().and_then(|v| v["room"].as_str().map(str::to_string)).unwrap_or_default(),
                _ => String::new(),
            })
            .collect()
    });
    assert_eq!(order.iter().filter(|o| o.len() == 40).count(), 2, "the third big join still waits: {order:?}");
    relay.wait("the waiting join, then its room's direct", Duration::from_secs(6), |r| r.got.len() >= 6).await;
    let last: Vec<String> = relay.with(|r| {
        r.got
            .iter()
            .rev()
            .take(2)
            .map(|(_, m)| match m {
                Message::Binary(b) if b.ends_with(b"after") => "after".to_string(),
                Message::Text(t) => serde_json::from_str::<Value>(t).ok().and_then(|v| v["room"].as_str().map(str::to_string)).unwrap_or_default(),
                _ => String::new(),
            })
            .collect()
    });
    assert_eq!(last, vec!["after".to_string(), server_room(2)], "a room's frames keep their order");
}

/// The breaker's hint: no socket before the pause ends, a nudge included; the resume is
/// free, but the mirror assumes nothing, so even the frames to send again wait.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_breaker_pause_holds_every_dial_and_paces_the_resend() {
    let relay = FakeRelay::start_on(TcpListener::bind("127.0.0.1:0").await.unwrap(), true, |r| {
        r.credit = Some(400_000);
        r.enforced = true;
        r.withhold_acks = true;
    });
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    c.send(WsCommand::JoinRoom { room_code: ROOM.into() });
    c.post(1);
    relay.wait("the post", T, |r| r.binaries() == posts(1..=1)).await;
    relay.with(|r| r.resume_h = Some(1));
    let hinted = Instant::now();
    relay.tell(json!({ "type": "reconnect", "after_ms": 1500, "breaker": true }));
    tokio::time::sleep(Duration::from_millis(50)).await;
    relay.with(|r| {
        for conn in r.conns.values() {
            let _ = conn.tx.send(Out::Close(1013, "breaker"));
        }
    });
    c.wait_kind("Suspended", T).await;
    c.nudge();
    tokio::time::sleep(Duration::from_millis(200)).await;
    c.nudge();
    c.wait_kind("Resumed", T).await;
    assert!(hinted.elapsed() >= Duration::from_millis(1500), "no dial before the pause ended: {:?}", hinted.elapsed());
    assert_eq!(relay.conn_count(), 2, "one dial, after the pause");
    tokio::time::sleep(Duration::from_millis(1000)).await;
    assert_eq!(relay.with(|r| r.binaries()), posts(1..=1), "the post to send again waits for the mirror to refill");
}

/// A login the breaker refuses (`cooldown`) is no refusal: the client waits it out, then
/// resumes the session the relay held.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_cooldown_refusal_waits_and_resumes_the_held_session() {
    let relay = FakeRelay::start_on(TcpListener::bind("127.0.0.1:0").await.unwrap(), true, |r| {
        r.credit = Some(400_000);
        r.enforced = true;
    });
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    relay.with(|r| r.cooldown_next = Some(1200));
    relay.kill();
    c.wait_kind("Suspended", T).await;
    relay.wait("the refused login", T, |r| r.auths_seen >= 2).await;
    let refused = Instant::now();
    c.nudge();
    c.wait_kind("Resumed", T).await;
    assert!(refused.elapsed() >= Duration::from_millis(1000), "waited out the pause: {:?}", refused.elapsed());
    c.drain();
    assert!(!c.log.contains(&"SessionLost".to_string()), "the held session came back: {:?}", c.log);
}

/// A relay without a breaker names no credit: nothing is paced.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_relay_without_a_breaker_is_never_paced() {
    let relay = FakeRelay::start(true).await;
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    for n in 0..30 {
        c.send(WsCommand::JoinRoom { room_code: server_room(n) });
    }
    relay.wait("thirty big joins at once", Duration::from_millis(800), |r| r.joins().len() == 30).await;
}

/// The relay's numbers in the order its frames arrived: "<payload tail>" for the given
/// payloads, the room for a text frame.
fn arrivals(relay: &FakeRelay, tails: &[&str]) -> Vec<String> {
    relay.with(|r| {
        r.got
            .iter()
            .filter_map(|(_, m)| match m {
                Message::Binary(b) => tails.iter().find(|t| b.ends_with(t.as_bytes())).map(|t| t.to_string()),
                Message::Text(t) => serde_json::from_str::<Value>(t).ok().and_then(|v| v["room"].as_str().map(str::to_string)),
                _ => None,
            })
            .collect()
    })
}

/// MED 3 of the G2 review: a small frame never passes an earlier frame to the same
/// device, whatever room either rides (an Olm pre-key frame must arrive before the frame
/// that needs its session); one to another device still goes first.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn priority_lane_never_passes_an_earlier_frame_to_the_same_device() {
    let relay = FakeRelay::start_on(TcpListener::bind("127.0.0.1:0").await.unwrap(), true, |r| {
        r.credit = Some(20_000);
        r.enforced = true;
    });
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    c.send(WsCommand::JoinRoom { room_code: ROOM.into() });
    for n in 0..3 {
        c.send(WsCommand::JoinRoom { room_code: server_room(n) });
    }
    let x = "12D3KooWDeviceX";
    c.send(WsCommand::SendDirect { room_code: server_room(2), target_peer: x.into(), data: b"prekey".to_vec() });
    c.send(WsCommand::SendDirect { room_code: ROOM.into(), target_peer: x.into(), data: b"after-prekey".to_vec() });
    c.send(WsCommand::SendDirect { room_code: ROOM.into(), target_peer: "12D3KooWDeviceY".into(), data: b"other".to_vec() });
    relay.wait("the frame to another device", T, |r| r.got.iter().any(|(_, m)| matches!(m, Message::Binary(b) if b.ends_with(b"other")))).await;
    let early = arrivals(&relay, &["prekey", "after-prekey", "other"]);
    assert!(!early.iter().any(|a| a == "after-prekey"), "the second frame to X passed its first: {early:?}");
    relay
        .wait("both frames to X", Duration::from_secs(6), |r| r.got.iter().any(|(_, m)| matches!(m, Message::Binary(b) if b.ends_with(b"after-prekey"))))
        .await;
    let order: Vec<String> =
        arrivals(&relay, &["after-prekey", "prekey", "other"]).into_iter().filter(|a| a.ends_with("prekey")).collect();
    assert_eq!(order, vec!["prekey".to_string(), "after-prekey".to_string()], "X hears its frames in order");
}

/// MED 4 (lead decision): a shadow relay names a credit but closes nothing, so the client
/// mirrors it and never waits; the same relay enforcing after a restart says so on the
/// resume, and from then the client waits for its mirror.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_shadow_relays_credit_never_makes_the_client_wait() {
    let relay = FakeRelay::start_on(TcpListener::bind("127.0.0.1:0").await.unwrap(), true, |r| r.credit = Some(20_000));
    let mut c = spawn_client(&relay.url(), quick());
    c.wait_kind("Connected", T).await;
    for n in 0..30 {
        c.send(WsCommand::JoinRoom { room_code: server_room(n) });
    }
    relay.wait("thirty big joins at once, 50,000 W past the credit", Duration::from_millis(800), |r| r.joins().len() == 30).await;
    relay.with(|r| r.enforced = true);
    relay.kill();
    c.wait_kind("Resumed", T).await;
    for n in 30..34 {
        c.send(WsCommand::JoinRoom { room_code: server_room(n) });
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(relay.with(|r| r.joins().len()), 30, "an enforcing relay's resume makes the client wait for its mirror");
}
