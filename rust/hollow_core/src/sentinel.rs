//! Self-diagnosis performance sentinels.
//!
//! Quiet by default: sentinels log ONLY anomalies, rate-limited or latched, every
//! line carrying the grep-able "[SENTINEL]" prefix. The healthy path is timestamp
//! math with no allocation and no logging, and a line never carries content or ids
//! that fingerprint: variant names, durations and queue depths only.

use std::time::{Duration, Instant};

/// Swarm-loop stall sentinel: an iteration over the threshold logs the arm's variant
/// NAME only, at most one line per 5 s, with the stalls in between summarized on the
/// next line. A local of the event loop, so single-task state with no atomics.
pub(crate) struct LoopStall {
    threshold: Duration,
    min_line_gap: Duration,
    last_line: Option<Instant>,
    suppressed: u32,
    worst_ms: u128,
}

impl LoopStall {
    pub(crate) fn new() -> Self {
        Self {
            threshold: Duration::from_millis(200),
            min_line_gap: Duration::from_secs(5),
            last_line: None,
            suppressed: 0,
            worst_ms: 0,
        }
    }

    /// Called at the top of every iteration with the PREVIOUS arm's name and start,
    /// which is what covers the `continue;` early-exits in the dispatch arms.
    pub(crate) fn check(&mut self, arm: &'static str, name: &'static str, started: Instant) {
        let elapsed = started.elapsed();
        if elapsed <= self.threshold {
            return;
        }
        if let Some(line) = self.observe(arm, name, elapsed.as_millis(), Instant::now()) {
            crate::hollow_log!("{line}");
        }
    }

    /// Pure rate-limit core (unit-tested; `check` is the logging wrapper).
    fn observe(
        &mut self,
        arm: &str,
        name: &str,
        ms: u128,
        now: Instant,
    ) -> Option<String> {
        let due = self
            .last_line
            .is_none_or(|t| now.duration_since(t) >= self.min_line_gap);
        if due {
            let suffix = if self.suppressed > 0 {
                format!(" (+{} suppressed, worst {}ms)", self.suppressed, self.worst_ms)
            } else {
                String::new()
            };
            self.suppressed = 0;
            self.worst_ms = 0;
            self.last_line = Some(now);
            Some(format!("[SENTINEL] swarm {arm} {name} {ms}ms{suffix}"))
        } else {
            self.suppressed += 1;
            if ms > self.worst_ms {
                self.worst_ms = ms;
            }
            None
        }
    }
}

/// Persistence-actor backlog sentinel, latched: it logs on the first crossing of the
/// depth threshold, then only when the high-water mark doubles, so a wedged actor
/// produces a handful of lines per session rather than a stream.
pub(crate) struct BacklogLatch {
    name: &'static str,
    next_log: usize,
    high_water: usize,
}

impl BacklogLatch {
    pub(crate) fn new(name: &'static str, threshold: usize) -> Self {
        Self {
            name,
            next_log: threshold.max(1),
            high_water: 0,
        }
    }

    /// Sample the queue depth (receiver side, after a recv).
    pub(crate) fn observe(&mut self, depth: usize) {
        if let Some(line) = self.observe_core(depth) {
            crate::hollow_log!("{line}");
        }
    }

    /// Pure latch core (unit-tested; `observe` is the logging wrapper).
    fn observe_core(&mut self, depth: usize) -> Option<String> {
        if depth > self.high_water {
            self.high_water = depth;
        }
        if depth < self.next_log {
            return None;
        }
        while self.next_log <= depth {
            self.next_log = self.next_log.saturating_mul(2);
        }
        Some(format!(
            "[SENTINEL] {} backlog depth={} high_water={}",
            self.name, depth, self.high_water
        ))
    }
}

/// Runtime starvation heartbeat: a 1 s tokio interval where a tick more than 500 ms
/// late starts an episode, and ONE line logs when it ends with the worst drift. Catches
/// blocking calls that starve the runtime whichever task hid them.
pub(crate) fn spawn_runtime_heartbeat() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        tokio::spawn(async {
            let period = Duration::from_secs(1);
            let mut interval = tokio::time::interval(period);
            // Delay, not the default Burst: after a stall the next tick should be a full
            // period later, not a rapid catch-up volley.
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            interval.tick().await; // consume immediate first tick
            let mut last = Instant::now();
            // Some(worst_drift_ms) while inside a starvation episode.
            let mut episode_worst_ms: Option<u128> = None;
            loop {
                interval.tick().await;
                let now = Instant::now();
                let drift_ms = now
                    .duration_since(last)
                    .saturating_sub(period)
                    .as_millis();
                last = now;
                if drift_ms > 500 {
                    episode_worst_ms =
                        Some(episode_worst_ms.map_or(drift_ms, |w| w.max(drift_ms)));
                } else if let Some(worst) = episode_worst_ms.take() {
                    crate::hollow_log!(
                        "[SENTINEL] runtime starvation ended, worst drift +{worst}ms"
                    );
                }
            }
        });
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loop_stall_rate_limits_to_one_line_per_window() {
        let mut s = LoopStall::new();
        let t0 = Instant::now();
        // First stall logs immediately.
        let l1 = s.observe("cmd", "SendMessage", 350, t0);
        assert_eq!(
            l1.as_deref(),
            Some("[SENTINEL] swarm cmd SendMessage 350ms")
        );
        // Within the 5s window: suppressed.
        assert!(s.observe("cmd", "SendMessage", 400, t0 + Duration::from_secs(1)).is_none());
        assert!(s.observe("ws", "Message", 900, t0 + Duration::from_secs(2)).is_none());
        // Window over: logs again with the suppressed summary.
        let l2 = s.observe("timer", "mls_batch", 250, t0 + Duration::from_secs(5));
        assert_eq!(
            l2.as_deref(),
            Some("[SENTINEL] swarm timer mls_batch 250ms (+2 suppressed, worst 900ms)")
        );
        // Summary state reset after emission.
        let l3 = s.observe("cmd", "JoinRoom", 300, t0 + Duration::from_secs(10));
        assert_eq!(l3.as_deref(), Some("[SENTINEL] swarm cmd JoinRoom 300ms"));
    }

    #[test]
    fn backlog_latch_logs_once_then_only_on_doubling() {
        let mut b = BacklogLatch::new("crdt_store", 256);
        // Below threshold: silent, but high-water tracks.
        assert!(b.observe_core(10).is_none());
        assert!(b.observe_core(255).is_none());
        // First crossing logs.
        assert_eq!(
            b.observe_core(300).as_deref(),
            Some("[SENTINEL] crdt_store backlog depth=300 high_water=300")
        );
        // Anything below the next doubling (512) stays silent — latched.
        assert!(b.observe_core(400).is_none());
        assert!(b.observe_core(511).is_none());
        assert!(b.observe_core(300).is_none());
        // Doubling crossed: one more line, high-water carried.
        assert_eq!(
            b.observe_core(600).as_deref(),
            Some("[SENTINEL] crdt_store backlog depth=600 high_water=600")
        );
        // Next latch point is now 1024.
        assert!(b.observe_core(1000).is_none());
        assert!(b.observe_core(1024).is_some());
    }

    #[test]
    fn backlog_latch_high_water_survives_dips() {
        let mut b = BacklogLatch::new("crypto_store", 256);
        assert!(b.observe_core(300).is_some());
        assert!(b.observe_core(5).is_none());
        // A later crossing reports the true session high-water mark.
        assert_eq!(
            b.observe_core(700).as_deref(),
            Some("[SENTINEL] crypto_store backlog depth=700 high_water=700")
        );
    }
}
