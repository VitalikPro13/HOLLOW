//! Process-wide Lamport clock for chat-message send stamps.
//!
//! Display order is keyed on the sender-stamped `(timestamp ms, order_us)`, and
//! raw wall-clock stamps break causality across skewed machines: a reply typed on
//! a machine running seconds behind sorts ABOVE the message it answers. Every
//! ingest calls `observe` and every send stamps `max(now_us, clock + 1)`, so a
//! reply always stamps after everything its sender had seen, and both ordering
//! keys derive from the ONE stamp (`ts = stamp / 1000`). `observe` clamps to
//! local-now plus 5 minutes so a peer with a wildly-future clock cannot drag our
//! own sends into the far future. The clock is process-global, so harness nodes
//! share one, which only strengthens the ordering they assert.

use std::sync::atomic::{AtomicI64, Ordering};

static CLOCK_US: AtomicI64 = AtomicI64::new(0);

/// Refuse to chase stamps more than this far ahead of our own clock.
const MAX_FORWARD_SKEW_US: i64 = 5 * 60 * 1_000_000;

fn now_us() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros() as i64
}

/// Advance the clock to at least `seen_us`, the stamp of any chat message being
/// persisted (our own are no-ops).
pub(crate) fn observe(seen_us: i64) {
    observe_on(&CLOCK_US, seen_us, now_us());
}

/// Mint the next send stamp (microseconds): strictly greater than every stamp
/// observed so far and never behind the local clock. The signed millisecond
/// timestamp is `stamp / 1000`.
pub(crate) fn next_send_stamp_us() -> i64 {
    next_on(&CLOCK_US, now_us())
}

fn observe_on(clock: &AtomicI64, seen_us: i64, now_us: i64) {
    let capped = seen_us.min(now_us + MAX_FORWARD_SKEW_US);
    clock.fetch_max(capped, Ordering::Relaxed);
}

fn next_on(clock: &AtomicI64, now_us: i64) -> i64 {
    let mut prev = clock.load(Ordering::Relaxed);
    loop {
        let next = now_us.max(prev + 1);
        match clock.compare_exchange_weak(prev, next, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return next,
            Err(p) => prev = p,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Tests drive a LOCAL AtomicI64 with explicit `now` values — the real
    // global clock is never touched, so parallel tests can't cross-pollute.

    #[test]
    fn send_stamps_are_strictly_increasing_even_with_frozen_clock() {
        let clock = AtomicI64::new(0);
        let now = 1_000_000;
        let a = next_on(&clock, now);
        let b = next_on(&clock, now);
        let c = next_on(&clock, now);
        assert!(a < b && b < c, "stamps must be strictly increasing: {a} {b} {c}");
        assert_eq!(a, now, "first stamp with an idle clock is local now");
    }

    #[test]
    fn reply_stamps_after_seen_message_despite_clock_behind() {
        // Our wall clock runs BEHIND the peer's: their message is stamped at
        // 5_000_000 while ours reads 1_000_000, and the reply must still stamp
        // after the seen message.
        let clock = AtomicI64::new(0);
        observe_on(&clock, 5_000_000, 1_000_000);
        let reply = next_on(&clock, 1_000_000);
        assert!(reply > 5_000_000, "reply {reply} must sort after the seen 5_000_000");
    }

    #[test]
    fn far_future_stamp_is_clamped_not_chased() {
        // A peer stamped an hour ahead: the clock advances at most 5 minutes past
        // local now, so our own sends are not poisoned.
        let clock = AtomicI64::new(0);
        let now = 1_000_000_000;
        let hour_ahead = now + 3_600 * 1_000_000;
        observe_on(&clock, hour_ahead, now);
        let stamp = next_on(&clock, now);
        assert!(stamp <= now + MAX_FORWARD_SKEW_US + 1, "stamp {stamp} chased a poisoned clock");
        assert!(stamp > now, "stamp must still be ahead of the observed clamp");
    }

    #[test]
    fn observing_old_stamps_never_rewinds() {
        let clock = AtomicI64::new(0);
        let now = 9_000_000;
        let first = next_on(&clock, now);
        observe_on(&clock, 1_000, now); // ancient backfill row
        let second = next_on(&clock, now);
        assert!(second > first, "old observations must not rewind the clock");
    }
}
