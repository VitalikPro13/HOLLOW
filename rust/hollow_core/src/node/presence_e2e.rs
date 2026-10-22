//! The real `ws_client` against the real relay (g13 presence audits): an observer's
//! digest audits under churn (joins, leaves, the app going to the background and back,
//! sockets dropped and resumed, one dropped with an audit in flight) must never see a
//! difference that is not there, and one lost `peer_joined` must show as exactly one
//! drift. The proof that the relay's answer never runs ahead of the presence frames it
//! sums, end to end.
//!
//! Needs the relay on 127.0.0.1 with `--domain 127.0.0.1` and the zombie proxy
//! (`tools/zombie_proxy`) with two TLS routes, `o` for the observer and `a` for the
//! others; then:
//!
//! ```text
//! HOLLOW_DATA_DIR=<scratch> HOLLOW_E2E_URL_O=ws://127.0.0.1:<o>/ws HOLLOW_E2E_URL_A=ws://127.0.0.1:<a>/ws \
//!   HOLLOW_E2E_PROXY_CTL=127.0.0.1:<control> \
//!   cargo test --lib node::presence_e2e -- --ignored --nocapture
//! ```

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use base64::Engine;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

use super::presence_audit::Verdict;
use super::ws_client::{presence_hooks, set_background, spawn_ws_client, WsCommand, WsEvent};
use crate::identity::native_identity::NativeKeypair;

struct Client {
    peer: String,
    cmd: mpsc::UnboundedSender<WsCommand>,
    events: Option<mpsc::UnboundedReceiver<WsEvent>>,
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
    Client { peer, cmd, events: Some(events) }
}

async fn connected(c: &mut Client) {
    let events = c.events.as_mut().expect("events");
    let ok = tokio::time::timeout(Duration::from_secs(30), async {
        while let Some(e) = events.recv().await {
            if matches!(e, WsEvent::Connected) {
                return true;
            }
        }
        false
    })
    .await;
    assert!(matches!(ok, Ok(true)), "{} connects", c.peer);
}

/// Drains `c`'s events from now on, counting its drifts.
fn drain(c: &mut Client) -> Arc<AtomicUsize> {
    let drifts = Arc::new(AtomicUsize::new(0));
    let (n, mut events) = (drifts.clone(), c.events.take().expect("events"));
    tokio::spawn(async move {
        while let Some(e) = events.recv().await {
            if matches!(e, WsEvent::PresenceDrift { .. }) {
                n.fetch_add(1, Ordering::SeqCst);
            }
        }
    });
    drifts
}

async fn proxy(ctl: &str, line: &str) {
    let stream = tokio::net::TcpStream::connect(ctl).await.expect("proxy control");
    let (read, mut write) = stream.into_split();
    write.write_all(format!("{line}\n").as_bytes()).await.expect("proxy write");
    let mut answer = String::new();
    BufReader::new(read).read_line(&mut answer).await.expect("proxy read");
    assert!(answer.contains("\"ok\": true") || answer.contains("\"ok\":true"), "the proxy refused {line}: {answer}");
}

fn verdicts_of(peer: &str, room: &str) -> Vec<Verdict> {
    presence_hooks::VERDICTS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .iter()
        .filter(|(p, r, _)| p == peer && r == room)
        .map(|(_, _, v)| *v)
        .collect()
}

/// One audit by `o` of `room`, through to its final verdict (a recheck included).
async fn audit(o: &Client, room: &str) -> Vec<Verdict> {
    let before = verdicts_of(&o.peer, room).len();
    o.cmd.send(WsCommand::DiscoverPeers { room_code: room.to_string() }).expect("ask");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(25);
    loop {
        let seen: Vec<Verdict> = verdicts_of(&o.peer, room)[before..].to_vec();
        if seen.iter().any(|v| matches!(v, Verdict::Same | Verdict::Drift | Verdict::Backoff(_))) {
            return seen;
        }
        assert!(tokio::time::Instant::now() < deadline, "no verdict for an audit of {room}: {seen:?}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "needs a relay and the zombie proxy: see the module doc"]
async fn presence_audits_never_drift_under_churn_and_catch_one_lost_frame() {
    let var = |n: &str| std::env::var(n).unwrap_or_else(|_| panic!("{n}: see the module doc"));
    let (url_o, url_a, ctl) = (var("HOLLOW_E2E_URL_O"), var("HOLLOW_E2E_URL_A"), var("HOLLOW_E2E_PROXY_CTL"));
    let room = format!("e2e-presence-{:x}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis());

    let mut o = spawn_client(&url_o);
    connected(&mut o).await;
    let drifts = drain(&mut o);
    o.cmd.send(WsCommand::JoinRoom { room_code: room.clone() }).expect("join");
    let mut actors: Vec<Client> = (0..5).map(|_| spawn_client(&url_a)).collect();
    for a in actors.iter_mut() {
        connected(a).await;
        drain(a);
        a.cmd.send(WsCommand::JoinRoom { room_code: room.clone() }).expect("join");
    }
    tokio::time::sleep(Duration::from_secs(2)).await;

    let mut all: Vec<Vec<Verdict>> = Vec::new();
    all.push(audit(&o, &room).await);
    for round in 0..4 {
        // Leaves and joins racing the ask itself.
        let a = &actors[round % actors.len()];
        a.cmd.send(WsCommand::LeaveRoom { room_code: room.clone() }).expect("leave");
        o.cmd.send(WsCommand::DiscoverPeers { room_code: room.clone() }).expect("ask");
        a.cmd.send(WsCommand::JoinRoom { room_code: room.clone() }).expect("join");
        tokio::time::sleep(Duration::from_millis(500)).await;
        all.push(audit(&o, &room).await);
    }
    // Everyone to the background and back: the others hide, the observer's presence is
    // withheld, `active` brings its members back.
    set_background(true);
    tokio::time::sleep(Duration::from_secs(3)).await;
    set_background(false);
    tokio::time::sleep(Duration::from_secs(3)).await;
    all.push(audit(&o, &room).await);
    // The others' sockets reset and resume.
    proxy(&ctl, "drop route:a").await;
    tokio::time::sleep(Duration::from_secs(5)).await;
    all.push(audit(&o, &room).await);
    // The observer's socket resets with an ask in flight; its answer may come back out of
    // the ring after the resume's members.
    o.cmd.send(WsCommand::DiscoverPeers { room_code: room.clone() }).expect("ask");
    proxy(&ctl, "drop route:o").await;
    actors[0].cmd.send(WsCommand::LeaveRoom { room_code: room.clone() }).expect("leave");
    tokio::time::sleep(Duration::from_secs(6)).await;
    all.push(audit(&o, &room).await);

    let flat: Vec<&Verdict> = all.iter().flatten().collect();
    println!("CHURN_VERDICTS {flat:?}");
    assert!(!flat.iter().any(|v| matches!(v, Verdict::Drift | Verdict::Backoff(_))), "a drift under churn: {flat:?}");
    assert_eq!(drifts.load(Ordering::SeqCst), 0, "no PresenceDrift reached the node under churn");
    let rechecks = flat.iter().filter(|v| matches!(v, Verdict::Recheck)).count();
    println!("CHURN_RECHECKS {rechecks}");

    // One lost frame: exactly one drift, and the re-join settles it.
    *presence_hooks::LOSE_JOINED.lock().unwrap() = Some((o.peer.clone(), 1));
    let mut late = spawn_client(&url_a);
    connected(&mut late).await;
    drain(&mut late);
    late.cmd.send(WsCommand::JoinRoom { room_code: room.clone() }).expect("join");
    tokio::time::sleep(Duration::from_secs(2)).await;
    let lost = audit(&o, &room).await;
    assert_eq!(lost, vec![Verdict::Recheck, Verdict::Drift], "a lost frame is one recheck, then one drift");
    assert_eq!(drifts.load(Ordering::SeqCst), 1);
    o.cmd.send(WsCommand::JoinRoom { room_code: room.clone() }).expect("the node's re-join");
    tokio::time::sleep(Duration::from_secs(12)).await;
    assert_eq!(verdicts_of(&o.peer, &room).last(), Some(&Verdict::Same), "the re-join's verify matches");
    assert_eq!(audit(&o, &room).await, vec![Verdict::Same]);
    assert_eq!(drifts.load(Ordering::SeqCst), 1, "exactly one drift in all");
    println!("PRESENCE_E2E_PASS");
}
