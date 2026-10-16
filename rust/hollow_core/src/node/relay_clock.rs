//! The relay's clock as it last told us (`now` on `auth_challenge` and `hb_ack`).
//!
//! ONLY stamps the relay itself judges read it: the login, ring control and nickname
//! claims. Anything a peer judges (message times, `order_us`, HLC, frame seals,
//! roster statements, kill orders) stays on our own clock, else the relay could move
//! it. A device whose clock is off still logs in and still has its relay-checked
//! statements accepted; the offset also drives the app's clock warning (issue #72).

use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Duration;

/// No relay has told us its time yet.
const UNKNOWN: i64 = i64::MIN;

/// A relay `now` outside these unix seconds (2023 to 2100) is ignored, so a broken
/// relay cannot push stamps or the warning somewhere absurd.
const SANE_SECS: std::ops::RangeInclusive<u64> = 1_700_000_000..=4_102_444_800;

/// Relay clock minus ours, in milliseconds.
static OFFSET_MS: AtomicI64 = AtomicI64::new(UNKNOWN);

/// Our wall clock in unix milliseconds (debug builds add the fleet's simulated skew).
pub(crate) fn local_ms() -> i64 {
    let real = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    real.saturating_add(simulated_skew_ms())
}

/// The relay's clock minus ours, from a relay `now` (whole seconds, so its true time
/// is half a second past it on average) read when our clock said `local_ms`.
pub(crate) fn offset_from(relay_secs: u64, local_ms: i64) -> Option<i64> {
    SANE_SECS
        .contains(&relay_secs)
        .then(|| (relay_secs as i64) * 1000 + 500 - local_ms)
}

/// Takes in a relay `now` that just arrived; returns the offset it gives.
pub(crate) fn observe(relay_secs: u64) -> Option<i64> {
    let offset = offset_from(relay_secs, local_ms())?;
    OFFSET_MS.store(offset, Ordering::Relaxed);
    Some(offset)
}

/// The last measured offset, `None` until a relay that sends its time answered.
pub(crate) fn offset_ms() -> Option<i64> {
    let o = OFFSET_MS.load(Ordering::Relaxed);
    (o != UNKNOWN).then_some(o)
}

/// Our best reading of the relay's clock in unix milliseconds: our own clock when no
/// relay has told us its time.
pub(crate) fn now_ms() -> i64 {
    local_ms().saturating_add(offset_ms().unwrap_or(0))
}

/// An offset in whole seconds, rounded to the nearest (a relay `now` is whole seconds).
pub(crate) fn offset_secs(offset_ms: i64) -> i64 {
    (offset_ms + offset_ms.signum() * 500) / 1000
}

/// The login timestamp: the challenge's `now` plus what elapsed since it arrived, or
/// our own clock (unix seconds) from a relay that sends no time.
pub(crate) fn login_secs(relay_now: Option<u64>, elapsed: Duration, local_secs: u64) -> u64 {
    match relay_now.filter(|t| SANE_SECS.contains(t)) {
        Some(t) => t.saturating_add(elapsed.as_secs()),
        None => local_secs,
    }
}

/// Debug builds only: a `clock_skew_secs` file in the data dir (one signed integer)
/// moves our clock as this module reads it, so the fleet can show a skewed device
/// without touching the machine's clock.
#[cfg(debug_assertions)]
fn simulated_skew_ms() -> i64 {
    static SKEW: std::sync::OnceLock<i64> = std::sync::OnceLock::new();
    if let Some(s) = SKEW.get() {
        return *s;
    }
    let Ok(dir) = crate::identity::data_dir() else { return 0 };
    let secs = std::fs::read_to_string(dir.join("clock_skew_secs"))
        .ok()
        .and_then(|s| s.trim().parse::<i64>().ok())
        .unwrap_or(0);
    *SKEW.get_or_init(|| secs.clamp(-86_400 * 365, 86_400 * 365) * 1000)
}

#[cfg(not(debug_assertions))]
fn simulated_skew_ms() -> i64 {
    0
}

/// Tests that move the process-wide offset hold this, so threads never see each other's.
#[cfg(test)]
pub(crate) static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// The relay we reach tells no time: our stamps fall back to our own clock.
pub(crate) fn forget() {
    OFFSET_MS.store(UNKNOWN, Ordering::Relaxed);
}

#[cfg(test)]
pub(crate) fn forget_for_test() {
    forget();
}

#[cfg(test)]
mod tests {
    use super::*;

    const RELAY: u64 = 1_790_000_000;

    #[test]
    fn login_signs_relay_time_plus_elapsed() {
        // A local clock 82 s behind (the reporter's case) signs the relay's time.
        let local = RELAY - 82;
        assert_eq!(login_secs(Some(RELAY), Duration::from_millis(300), local), RELAY);
        assert_eq!(login_secs(Some(RELAY), Duration::from_millis(2_400), local), RELAY + 2);
        assert_eq!(login_secs(Some(RELAY), Duration::ZERO, RELAY + 600), RELAY);
    }

    #[test]
    fn login_without_relay_time_signs_our_clock() {
        assert_eq!(login_secs(None, Duration::from_secs(5), RELAY - 82), RELAY - 82);
    }

    #[test]
    fn an_absurd_relay_time_is_ignored() {
        assert_eq!(login_secs(Some(0), Duration::ZERO, RELAY), RELAY);
        assert_eq!(login_secs(Some(u64::MAX), Duration::ZERO, RELAY), RELAY);
        assert_eq!(offset_from(0, 0), None);
        assert_eq!(offset_from(u64::MAX, i64::MAX), None);
    }

    #[test]
    fn offset_seconds_round_to_the_nearest() {
        assert_eq!(offset_secs(81_600), 82);
        assert_eq!(offset_secs(81_400), 81);
        assert_eq!(offset_secs(-599_700), -600);
        assert_eq!(offset_secs(400), 0);
        assert_eq!(offset_secs(0), 0);
    }

    #[test]
    fn offset_is_relay_minus_ours() {
        let at = (RELAY as i64) * 1000;
        assert_eq!(offset_from(RELAY, at - 82_000), Some(82_500));
        assert_eq!(offset_from(RELAY, at + 600_000), Some(-599_500));
        assert_eq!(offset_from(RELAY, at + 500), Some(0));
    }
}
