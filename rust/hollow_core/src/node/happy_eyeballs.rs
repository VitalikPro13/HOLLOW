//! Happy Eyeballs v2 (RFC 8305) for the relay dial. A relay name can publish an IPv6
//! address that silently drops packets (a home router blocking inbound IPv6, a rotated
//! prefix); a dial that waits out each address's SYN timeout (about 21 s on Windows,
//! 75 s on macOS) never reaches the working IPv4 one inside the 10 s handshake.

use std::collections::VecDeque;
use std::future::Future;
use std::io;
use std::net::SocketAddr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use futures_util::stream::{FuturesUnordered, StreamExt};

/// RFC 8305's recommended Connection Attempt Delay.
pub(crate) const STAGGER: Duration = Duration::from_millis(250);

/// How long a family whose dial stalled after TCP gives the lead to the other one.
pub(crate) const STALL_HOLD: Duration = Duration::from_secs(300);
/// Relays remembered at once; the oldest note gives way.
const STALL_HOSTS: usize = 16;

/// The dial order: the family of the resolver's first address leads, since that order
/// carries the OS's address policy (RFC 8305 §4: prefer-IPv4 settings, gai.conf, Teredo
/// and ULA sorting), then the families alternate, each in the resolver's order.
pub(crate) fn interleave(addrs: Vec<SocketAddr>) -> Vec<SocketAddr> {
    let lead_v6 = addrs.first().is_some_and(SocketAddr::is_ipv6);
    let (v6, v4): (VecDeque<_>, VecDeque<_>) = addrs.into_iter().partition(SocketAddr::is_ipv6);
    let (mut first, mut second) = if lead_v6 { (v6, v4) } else { (v4, v6) };
    let mut order = Vec::with_capacity(first.len() + second.len());
    while !(first.is_empty() && second.is_empty()) {
        order.extend(first.pop_front());
        order.extend(second.pop_front());
    }
    order
}

/// (relay host, the family that stalled is IPv6, when). RAM only.
static STALLED: Mutex<Vec<(String, bool, Instant)>> = Mutex::new(Vec::new());

fn stalled() -> std::sync::MutexGuard<'static, Vec<(String, bool, Instant)>> {
    STALLED.lock().unwrap_or_else(|p| p.into_inner())
}

fn note_stalled_at(host: &str, v6: bool, at: Instant) {
    let mut held = stalled();
    held.retain(|(h, _, _)| h != host);
    if held.len() >= STALL_HOSTS {
        held.remove(0);
    }
    held.push((host.to_string(), v6, at));
}

fn note_upgraded(host: &str, v6: bool) {
    stalled().retain(|(h, f, _)| !(h == host && *f == v6));
}

/// `addrs` for a dial to `host`: when a dial there connected TCP over one family but
/// never finished the upgrade within [`STALL_HOLD`], the other family's addresses go
/// first, so a path that answers SYNs and then stalls cannot win every reconnect.
pub(crate) fn order_for(host: &str, addrs: Vec<SocketAddr>) -> Vec<SocketAddr> {
    order_at(host, addrs, Instant::now())
}

fn order_at(host: &str, mut addrs: Vec<SocketAddr>, now: Instant) -> Vec<SocketAddr> {
    let held = stalled().iter().find(|(h, _, _)| h == host).filter(|(_, _, at)| now.saturating_duration_since(*at) < STALL_HOLD).map(|(_, v6, _)| *v6);
    if let Some(v6) = held {
        addrs.sort_by_key(|a| a.is_ipv6() == v6);
    }
    addrs
}

/// Armed from a won TCP connect to the end of the WebSocket upgrade. Dropped armed (an
/// error, or the handshake timeout cancelling the dial), it notes the family as stalled
/// for this relay.
pub(crate) struct StallGuard {
    host: String,
    addr: Option<SocketAddr>,
}

impl StallGuard {
    pub(crate) fn arm(host: &str, addr: Option<SocketAddr>) -> Self {
        StallGuard { host: host.to_string(), addr }
    }

    pub(crate) fn upgraded(mut self) {
        if let Some(a) = self.addr.take() {
            note_upgraded(&self.host, a.is_ipv6());
        }
    }
}

impl Drop for StallGuard {
    fn drop(&mut self) {
        if let Some(a) = self.addr.take() {
            note_stalled_at(&self.host, a.is_ipv6(), Instant::now());
            crate::hollow_log!("[HOLLOW-WS] relay dial: {a} connected but the upgrade never finished; the other family leads for a while");
        }
    }
}

/// The first connection to succeed over `addrs` in [`interleave`] order, with its attempt
/// number (0 = the first address tried). Each attempt starts `stagger` after the one
/// before, or at once when one fails; the losers are dropped. Unbounded in time: the
/// caller's handshake timeout bounds it.
pub(crate) async fn race<T, F, Fut>(addrs: Vec<SocketAddr>, stagger: Duration, connect: F) -> io::Result<(T, usize)>
where
    F: Fn(SocketAddr) -> Fut,
    Fut: Future<Output = io::Result<T>>,
{
    let mut queue = interleave(addrs).into_iter().enumerate();
    let mut attempts = FuturesUnordered::new();
    let start = |(n, addr): (usize, SocketAddr)| {
        let attempt = connect(addr);
        async move { (n, attempt.await) }
    };
    let mut last_err = None;
    loop {
        if attempts.is_empty() {
            match queue.next() {
                Some(next) => attempts.push(start(next)),
                None => {
                    return Err(last_err.unwrap_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "the relay's name resolves to no address")));
                }
            }
        }
        let more = queue.len() > 0;
        tokio::select! {
            Some((n, result)) = attempts.next() => match result {
                Ok(conn) => return Ok((conn, n)),
                Err(e) => {
                    last_err = Some(e);
                    if let Some(next) = queue.next() {
                        attempts.push(start(next));
                    }
                }
            },
            _ = tokio::time::sleep(stagger), if more => {
                if let Some(next) = queue.next() {
                    attempts.push(start(next));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};
    use tokio::time::Instant;
    type StdInstant = std::time::Instant;

    fn v6(n: u16) -> SocketAddr {
        SocketAddr::from(([0x2001, 0xdb8, 0, 0, 0, 0, 0, n], 443))
    }

    fn v4(n: u8) -> SocketAddr {
        SocketAddr::from(([192, 0, 2, n], 443))
    }

    /// What a scripted address does when dialled, in milliseconds.
    #[derive(Clone, Copy)]
    enum Answer {
        After(u64),
        FailAfter(u64),
        Never,
    }

    /// A dial seam over scripted addresses: it records when each attempt started and
    /// counts the attempts dropped unfinished.
    #[derive(Clone, Default)]
    struct Script {
        plan: Arc<Vec<(SocketAddr, Answer)>>,
        started: Arc<Mutex<Vec<(SocketAddr, Duration)>>>,
        dropped: Arc<AtomicUsize>,
    }

    struct CountDrop(Arc<AtomicUsize>, bool);

    impl Drop for CountDrop {
        fn drop(&mut self) {
            if !self.1 {
                self.0.fetch_add(1, Ordering::SeqCst);
            }
        }
    }

    impl Script {
        fn new(plan: &[(SocketAddr, Answer)]) -> Self {
            Script { plan: Arc::new(plan.to_vec()), ..Default::default() }
        }

        async fn run(&self, t0: Instant) -> io::Result<(SocketAddr, usize)> {
            let me = self.clone();
            // Bounded, so a race that never ends fails at once under the paused clock.
            let raced = race(self.plan.iter().map(|(a, _)| *a).collect(), STAGGER, move |addr| {
                let me = me.clone();
                async move {
                    me.started.lock().unwrap().push((addr, t0.elapsed()));
                    let answer = me.plan.iter().find(|(a, _)| *a == addr).map(|(_, x)| *x).unwrap();
                    let mut guard = CountDrop(me.dropped.clone(), false);
                    let out = match answer {
                        Answer::After(ms) => {
                            tokio::time::sleep(Duration::from_millis(ms)).await;
                            Ok(addr)
                        }
                        Answer::FailAfter(ms) => {
                            tokio::time::sleep(Duration::from_millis(ms)).await;
                            Err(io::Error::new(io::ErrorKind::ConnectionRefused, "refused"))
                        }
                        Answer::Never => std::future::pending().await,
                    };
                    guard.1 = true;
                    out
                }
            });
            tokio::time::timeout(Duration::from_secs(60), raced)
                .await
                .unwrap_or_else(|_| Err(io::Error::new(io::ErrorKind::TimedOut, "the race never ended")))
        }

        fn starts(&self) -> Vec<(SocketAddr, u64)> {
            self.started.lock().unwrap().iter().map(|(a, d)| (*a, d.as_millis() as u64)).collect()
        }
    }

    #[test]
    fn the_first_family_follows_the_resolver_order() {
        assert_eq!(interleave(vec![v4(1), v6(1), v4(2)]), vec![v4(1), v6(1), v4(2)]);
        assert_eq!(interleave(vec![v6(1), v4(1)]), vec![v6(1), v4(1)]);
        assert_eq!(interleave(vec![v4(1), v4(2), v6(1), v6(2), v6(3)]), vec![v4(1), v6(1), v4(2), v6(2), v6(3)]);
        assert_eq!(interleave(vec![v6(1), v6(2), v4(1)]), vec![v6(1), v4(1), v6(2)]);
        assert_eq!(interleave(vec![v4(1), v4(2)]), vec![v4(1), v4(2)]);
        assert_eq!(interleave(vec![]), Vec::<SocketAddr>::new());
    }

    #[test]
    fn a_stalled_family_gives_the_lead_for_a_while() {
        let t0 = StdInstant::now();
        let host = "stall-order.test";
        assert_eq!(order_at(host, vec![v6(1), v4(1)], t0), vec![v6(1), v4(1)], "nothing noted, the resolver's order");
        note_stalled_at(host, true, t0);
        assert_eq!(order_at(host, vec![v6(1), v6(2), v4(1)], t0 + Duration::from_secs(1)), vec![v4(1), v6(1), v6(2)]);
        assert_eq!(order_at("other.test", vec![v6(1), v4(1)], t0), vec![v6(1), v4(1)], "another relay keeps its order");
        assert_eq!(order_at(host, vec![v6(1), v4(1)], t0 + STALL_HOLD), vec![v6(1), v4(1)], "the hold ends");
        note_stalled_at(host, false, t0);
        assert_eq!(order_at(host, vec![v4(1), v6(1)], t0), vec![v6(1), v4(1)]);
        note_upgraded(host, false);
        assert_eq!(order_at(host, vec![v4(1), v6(1)], t0), vec![v4(1), v6(1)], "an upgrade over it clears the note");
    }

    #[test]
    fn the_stall_notes_stay_bounded() {
        let t0 = StdInstant::now();
        for n in 0..=STALL_HOSTS {
            note_stalled_at(&format!("bound-{n}.test"), true, t0);
        }
        assert!(stalled().len() <= STALL_HOSTS);
        assert_eq!(order_at("bound-0.test", vec![v6(1), v4(1)], t0), vec![v6(1), v4(1)], "the oldest note gave way");
        assert_eq!(order_at(&format!("bound-{STALL_HOSTS}.test"), vec![v6(1), v4(1)], t0), vec![v4(1), v6(1)]);
    }

    #[test]
    fn a_guard_notes_only_when_dropped_armed() {
        let host = "guard.test";
        StallGuard::arm(host, Some(v4(1))).upgraded();
        assert_eq!(order_for(host, vec![v4(1), v6(1)]), vec![v4(1), v6(1)], "an upgrade notes nothing");
        drop(StallGuard::arm(host, Some(v4(1))));
        assert_eq!(order_for(host, vec![v4(1), v6(1)]), vec![v6(1), v4(1)]);
        StallGuard::arm(host, Some(v4(1))).upgraded();
        assert_eq!(order_for(host, vec![v4(1), v6(1)]), vec![v4(1), v6(1)], "an upgrade over that family clears it");
    }

    /// #153: a relay with A + AAAA records whose IPv6 address blackholes. The dial must
    /// reach the live IPv4 listener well inside the handshake, never wait out the SYN.
    #[tokio::test]
    async fn a_dead_ipv6_address_falls_back_to_ipv4_within_the_handshake() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let live = listener.local_addr().unwrap();
        let dead = SocketAddr::new("2001:db8::dead".parse().unwrap(), live.port());
        let handshake = crate::node::relay_session::Timing::default().handshake;
        let t0 = std::time::Instant::now();
        let dialled = tokio::time::timeout(
            handshake,
            race(vec![dead, live], STAGGER, |addr| async move {
                if addr == dead {
                    // A blackholed address: no SYN-ACK, no RST, ever.
                    std::future::pending::<io::Result<tokio::net::TcpStream>>().await
                } else {
                    tokio::net::TcpStream::connect(addr).await
                }
            }),
        )
        .await;
        let (tcp, attempt) = dialled.expect("the dial waited out the handshake on the dead IPv6 address").unwrap();
        assert_eq!(tcp.peer_addr().unwrap(), live);
        assert_eq!(attempt, 1, "IPv6 was tried first");
        assert!(t0.elapsed() < handshake / 2, "took {:?}", t0.elapsed());
    }

    #[tokio::test(start_paused = true)]
    async fn the_first_family_to_answer_wins() {
        // IPv6 is slow: IPv4 starts after the stagger and wins; the IPv6 attempt is dropped.
        let t0 = Instant::now();
        let s = Script::new(&[(v6(1), Answer::After(600)), (v4(1), Answer::After(0))]);
        assert_eq!(s.run(t0).await.unwrap(), (v4(1), 1));
        assert_eq!(t0.elapsed(), STAGGER);
        assert_eq!(s.starts(), vec![(v6(1), 0), (v4(1), 250)]);
        assert_eq!(s.dropped.load(Ordering::SeqCst), 1, "the losing attempt was dropped");

        // IPv6 answers inside the stagger: IPv4 never starts.
        let t0 = Instant::now();
        let s = Script::new(&[(v6(1), Answer::After(100)), (v4(1), Answer::After(0))]);
        assert_eq!(s.run(t0).await.unwrap(), (v6(1), 0));
        assert_eq!(t0.elapsed(), Duration::from_millis(100));
        assert_eq!(s.starts(), vec![(v6(1), 0)]);
    }

    #[tokio::test(start_paused = true)]
    async fn the_attempts_start_one_stagger_apart() {
        let t0 = Instant::now();
        let s = Script::new(&[
            (v4(1), Answer::Never),
            (v4(2), Answer::Never),
            (v6(1), Answer::Never),
            (v6(2), Answer::After(0)),
        ]);
        assert_eq!(s.run(t0).await.unwrap(), (v6(2), 3));
        assert_eq!(s.starts(), vec![(v4(1), 0), (v6(1), 250), (v4(2), 500), (v6(2), 750)]);
        assert_eq!(s.dropped.load(Ordering::SeqCst), 3);
    }

    #[tokio::test(start_paused = true)]
    async fn a_failed_attempt_starts_the_next_at_once() {
        let t0 = Instant::now();
        let s = Script::new(&[(v6(1), Answer::FailAfter(10)), (v4(1), Answer::After(5))]);
        assert_eq!(s.run(t0).await.unwrap(), (v4(1), 1));
        assert_eq!(s.starts(), vec![(v6(1), 0), (v4(1), 10)]);
        assert_eq!(t0.elapsed(), Duration::from_millis(15));

        // With another attempt still open, a failure starts the next one at once too.
        let t0 = Instant::now();
        let s = Script::new(&[(v6(1), Answer::Never), (v4(1), Answer::FailAfter(50)), (v6(2), Answer::After(0))]);
        assert_eq!(s.run(t0).await.unwrap(), (v6(2), 2));
        assert_eq!(s.starts(), vec![(v6(1), 0), (v4(1), 250), (v6(2), 300)]);
    }

    #[tokio::test(start_paused = true)]
    async fn every_address_failing_returns_the_last_error() {
        let t0 = Instant::now();
        let s = Script::new(&[(v6(1), Answer::FailAfter(10)), (v4(1), Answer::FailAfter(400))]);
        let err = s.run(t0).await.unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::ConnectionRefused);
        assert_eq!(t0.elapsed(), Duration::from_millis(410));
        let none = race(vec![], STAGGER, |_| async { Ok::<(), io::Error>(()) }).await.unwrap_err();
        assert_eq!(none.kind(), io::ErrorKind::InvalidInput);
    }
}
