//! Pacing for secrets typed at this device's prompts (AR-24). With the wrap tied to
//! the hardware, guessing can only happen here, and this is what slows it: the first
//! few misses are free (typos), then each waits longer, up to an hour. The count is
//! per profile, on disk, so a restart does not reset it. It never wipes anything.
//!
//! Only a TYPED success clears it: the launch secret the keystore hands back at every
//! start must not, or killing and reopening the app would reset the count. A try is
//! charged BEFORE anything is derived and refunded when it proved nothing (the
//! hardware did not answer), so two prompts at once, or a process killed mid-try,
//! never get a free guess.
//!
//! Waits are measured on the boot clock (it counts sleep and no one can set it), so
//! moving the wall clock never ends or stretches a wait. Across a reboot the boot
//! clock restarts: once it reads less than the stamp the full wait starts again, and
//! while it reads more, the time since the reboot is still less than the time since
//! the miss. The wall time is kept beside it only for the record.

use std::path::Path;
use std::sync::Mutex;

pub(crate) const FILE: &str = "identity.attempts";

/// Dart matches the leading marker and reads the seconds after it.
pub(crate) const MARKER: &str = "too_many_attempts";

/// What a prompt answers when the try could not be written down: fail closed.
pub(crate) const NOT_RECORDED: &str =
    "attempt_not_recorded: Hollow could not note this try on this device, so it was not checked";

/// Misses allowed before the first wait.
const FREE: u32 = 4;

/// The wait after `failures` misses in a row, in seconds.
pub(crate) fn wait_secs(failures: u32) -> u64 {
    match failures.saturating_sub(FREE) {
        0 => 0,
        1 => 30,
        2 => 60,
        3 => 5 * 60,
        4 => 15 * 60,
        _ => 60 * 60,
    }
}

/// Now on both clocks, in milliseconds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Clock {
    pub wall_ms: i64,
    pub boot_ms: i64,
}

impl Clock {
    pub(crate) fn now() -> Self {
        let wall_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        Self { wall_ms, boot_ms: boot_clock_ms().unwrap_or(wall_ms) }
    }
}

/// Milliseconds since boot, sleep included.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn boot_clock_ms() -> Option<i64> {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: `ts` is a valid out-pointer for the call.
    (unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &mut ts) } == 0)
        .then(|| ts.tv_sec as i64 * 1000 + ts.tv_nsec as i64 / 1_000_000)
}

#[cfg(target_vendor = "apple")]
fn boot_clock_ms() -> Option<i64> {
    #[repr(C)]
    struct Timebase {
        numer: u32,
        denom: u32,
    }
    unsafe extern "C" {
        fn mach_continuous_time() -> u64;
        fn mach_timebase_info(info: *mut Timebase) -> i32;
    }
    let mut tb = Timebase { numer: 0, denom: 0 };
    // SAFETY: `tb` is a valid out-pointer; both calls have no other preconditions.
    let ticks = unsafe {
        if mach_timebase_info(&mut tb) != 0 || tb.denom == 0 {
            return None;
        }
        mach_continuous_time()
    };
    let nanos = ticks as u128 * tb.numer as u128 / tb.denom as u128;
    Some((nanos / 1_000_000) as i64)
}

#[cfg(windows)]
fn boot_clock_ms() -> Option<i64> {
    // SAFETY: no preconditions.
    Some(unsafe { windows_sys::Win32::System::SystemInformation::GetTickCount64() } as i64)
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_vendor = "apple", windows)))]
fn boot_clock_ms() -> Option<i64> {
    None
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct State {
    failures: u32,
    wall_ms: i64,
    /// `None` when the file has no boot stamp: the wait restarts from the next read.
    boot_ms: Option<i64>,
}

fn read(root: &Path) -> State {
    let Ok(text) = std::fs::read_to_string(root.join(FILE)) else { return State::default() };
    let mut parts = text.split_whitespace();
    let failures = parts.next().and_then(|p| p.parse().ok());
    let wall_ms = parts.next().and_then(|p| p.parse().ok());
    let boot_ms = parts.next().and_then(|p| p.parse().ok());
    match (failures, wall_ms) {
        (Some(failures), Some(wall_ms)) => State { failures, wall_ms, boot_ms },
        _ => State::default(),
    }
}

#[cfg(test)]
thread_local! {
    static WRITES_FAIL: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Test only: every write of the count fails, as on a full or read-only disk.
#[cfg(test)]
pub(crate) fn fail_writes_for_test(fail: bool) {
    WRITES_FAIL.with(|f| f.set(fail));
}

fn write(root: &Path, s: State) -> Result<(), String> {
    #[cfg(test)]
    if WRITES_FAIL.with(std::cell::Cell::get) {
        return Err(NOT_RECORDED.into());
    }
    if s == State::default() {
        return match std::fs::remove_file(root.join(FILE)) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(NOT_RECORDED.into()),
            _ => Ok(()),
        };
    }
    let staged = root.join(format!("{FILE}.tmp"));
    let boot = s.boot_ms.map(|b| b.to_string()).unwrap_or_default();
    std::fs::write(&staged, format!("{} {} {boot}", s.failures, s.wall_ms))
        .and_then(|_| std::fs::rename(&staged, root.join(FILE)))
        .map_err(|_| NOT_RECORDED.to_string())
}

/// Serializes read-modify-write of the count in this process: two prompts at once
/// must each pay for their try.
static COUNT: Mutex<()> = Mutex::new(());

fn locked() -> std::sync::MutexGuard<'static, ()> {
    COUNT.lock().unwrap_or_else(|e| e.into_inner())
}

/// Milliseconds of the wait that have passed on the boot clock, `None` after a reboot
/// the clock shows (it went back) or with no boot stamp.
fn elapsed_ms(s: &State, now: Clock) -> Option<i64> {
    let boot = s.boot_ms?;
    (now.boot_ms >= boot).then(|| now.boot_ms - boot)
}

/// Seconds still due, restarting the wait from `now` after a reboot.
fn remaining_locked(root: &Path, now: Clock) -> u64 {
    let s = read(root);
    let wait_ms = wait_secs(s.failures) as i64 * 1000;
    if wait_ms == 0 {
        return 0;
    }
    let elapsed = match elapsed_ms(&s, now) {
        Some(e) => e,
        None => {
            let _ = write(root, State { wall_ms: now.wall_ms, boot_ms: Some(now.boot_ms), ..s });
            0
        }
    };
    ((wait_ms - elapsed).max(0) as u64).div_ceil(1000)
}

/// Seconds still to wait before the next try, 0 when one may go now.
pub(crate) fn remaining_secs(root: &Path, now: Clock) -> u64 {
    let _g = locked();
    remaining_locked(root, now)
}

/// A try paid for before it was made; [`refund`] takes it back.
#[must_use]
pub(crate) struct Charge {
    before: State,
}

/// Refuses while a wait is due, else counts this try as a miss now. `Err` (and
/// nothing derived) when the count could not be written.
pub(crate) fn charge(root: &Path, now: Clock) -> Result<Charge, String> {
    let _g = locked();
    match remaining_locked(root, now) {
        0 => {}
        secs => return Err(format!("{MARKER}: {secs}")),
    }
    let before = read(root);
    let after = State {
        failures: before.failures.saturating_add(1),
        wall_ms: now.wall_ms,
        boot_ms: Some(now.boot_ms),
    };
    write(root, after)?;
    if read(root) != after {
        return Err(NOT_RECORDED.into());
    }
    Ok(Charge { before })
}

/// Takes back a try that proved nothing. A try charged since keeps its own charge.
pub(crate) fn refund(root: &Path, charge: Charge) {
    let _g = locked();
    let now = read(root);
    let back = if now.failures == charge.before.failures.saturating_add(1) {
        charge.before
    } else {
        State { failures: now.failures.saturating_sub(1), ..now }
    };
    let _ = write(root, if back.failures == 0 { State::default() } else { back });
}

/// A typed success, or a new lock: the count starts again.
pub(crate) fn succeeded(root: &Path) {
    let _g = locked();
    if read(root) != State::default() {
        let _ = write(root, State::default());
    }
}

#[cfg(test)]
pub(crate) fn set_for_test(root: &Path, failures: u32, at: Clock) {
    write(root, State { failures, wall_ms: at.wall_ms, boot_ms: Some(at.boot_ms) }).unwrap();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(wall_ms: i64, boot_ms: i64) -> Clock {
        Clock { wall_ms, boot_ms }
    }

    /// One miss charged and kept, as a wrong secret leaves it.
    fn miss(root: &Path, now: Clock) {
        let _ = charge(root, now).expect("no wait due");
    }

    // b5-device-bound

    #[test]
    fn b5_typos_are_free_then_each_miss_waits_longer() {
        assert_eq!((1..=4).map(wait_secs).sum::<u64>(), 0, "four misses wait for nothing");
        let waits: Vec<u64> = (5..=10).map(wait_secs).collect();
        assert_eq!(waits, vec![30, 60, 300, 900, 3600, 3600]);
        assert!(waits.windows(2).all(|w| w[0] <= w[1]), "a wait never shrinks");
    }

    #[test]
    fn b5_the_wait_survives_a_restart_and_ends_on_time() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let t0 = 1_000_000;
        for i in 0..5 {
            miss(tmp.path(), at(t0 + i, t0 + i));
        }
        // A fresh read of the file is what a restarted app sees.
        assert!(charge(tmp.path(), at(t0 + 5, t0 + 5)).err().unwrap().starts_with(MARKER));
        assert_eq!(remaining_secs(tmp.path(), at(t0 + 4 + 29_500, t0 + 4 + 29_500)), 1);
        assert_eq!(remaining_secs(tmp.path(), at(t0 + 4 + 30_000, t0 + 4 + 30_000)), 0);
    }

    #[test]
    fn b5_a_clock_set_back_does_not_end_the_wait() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        set_for_test(tmp.path(), 6, at(10_000_000, 50_000));
        assert_eq!(remaining_secs(tmp.path(), at(1_000, 50_000)), 60);
    }

    /// The wall clock set an hour forward: the boot clock still says seconds.
    #[test]
    fn a_clock_set_forward_never_ends_a_wait() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        set_for_test(tmp.path(), 9, at(10_000_000, 50_000));
        assert_eq!(remaining_secs(tmp.path(), at(10_000_000 + 2 * 3_600_000, 51_000)), 3599);
        assert!(charge(tmp.path(), at(10_000_000 + 2 * 3_600_000, 51_000)).is_err());
        // The real hour passes on the boot clock: the wait is over.
        assert_eq!(remaining_secs(tmp.path(), at(10_000_000 + 2 * 3_600_000, 50_000 + 3_600_000)), 0);
    }

    /// A reboot resets the boot clock: the full wait starts again from the first read
    /// after it, whatever the wall clock says.
    #[test]
    fn a_reboot_restarts_the_wait() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        set_for_test(tmp.path(), 6, at(10_000_000, 900_000));
        let wall = 10_000_000 + 50_000;
        assert_eq!(remaining_secs(tmp.path(), at(wall, 20_000)), 60, "the wait restarts at once");
        assert_eq!(remaining_secs(tmp.path(), at(wall + 30_000, 50_000)), 30, "and runs from then");
        assert_eq!(remaining_secs(tmp.path(), at(wall + 60_000, 80_000)), 0);
        // A file without a boot stamp restarts the same way.
        std::fs::write(tmp.path().join(FILE), "6 10000000").unwrap();
        assert_eq!(remaining_secs(tmp.path(), at(wall, 20_000)), 60);
    }

    #[test]
    fn b5_a_success_clears_the_count() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        set_for_test(tmp.path(), 3, at(5, 5));
        succeeded(tmp.path());
        assert_eq!(remaining_secs(tmp.path(), at(6, 6)), 0);
        assert!(!tmp.path().join(FILE).exists());
    }

    /// The try is paid before anything is derived; a try that proved nothing comes
    /// back, and a try charged in between keeps its own charge.
    #[test]
    fn a_try_is_charged_first_and_refunded_only_when_it_proved_nothing() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let first = charge(tmp.path(), at(10, 10)).unwrap();
        assert_eq!(read(tmp.path()).failures, 1, "charged before the derivation");
        let second = charge(tmp.path(), at(11, 11)).unwrap();
        assert_eq!(read(tmp.path()).failures, 2, "a second prompt at once pays too");
        refund(tmp.path(), first);
        assert_eq!(read(tmp.path()).failures, 1);
        refund(tmp.path(), second);
        assert!(!tmp.path().join(FILE).exists(), "nothing proved, nothing kept");
    }

    #[test]
    fn a_try_that_cannot_be_noted_is_refused() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        fail_writes_for_test(true);
        let refused = charge(tmp.path(), at(10, 10)).err();
        fail_writes_for_test(false);
        assert_eq!(refused.as_deref(), Some(NOT_RECORDED));
    }
}
