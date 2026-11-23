//! Raises the open-file soft limit at every process entry. launchd starts macOS and iOS
//! processes at 256 (the macOS app reached Rust init at 2560 on the mini) and Linux at
//! 1024; WebRTC opens sockets per network interface and connection, so a machine with
//! many interfaces runs out at boot (EMFILE), and every later open in the process fails,
//! the node's included.
//!
//! Only the soft limit moves and only upward, never past the hard limit, the OS's own
//! per-process cap or `CAP`. Windows has no descriptor limit for the handles and sockets
//! the app uses (the CRT's `_setmaxstdio` counts only C `FILE*` streams), so there it is
//! a no-op. Android usually starts at 32768 already, where it is a no-op too.

use std::sync::Once;

/// Far above what a busy app holds (about 124 steady, bursts at boot) and below macOS
/// OPEN_MAX (10240). On Linux it passes FD_SETSIZE (1024): a select() user would fail on
/// a descriptor above 1024, which before this was an EMFILE anyway.
#[cfg_attr(not(unix), allow(dead_code))]
const CAP: u64 = 8192;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Raised {
    before: u64,
    after: u64,
}

/// Idempotent; called beside `crash_dumps::keep_secrets_out` at every process entry.
/// Logs each time, since the first call (app init) comes before the log file opens.
pub(crate) fn raise_soft_limit() {
    static ONCE: Once = Once::new();
    static OUTCOME: std::sync::OnceLock<Result<Raised, String>> = std::sync::OnceLock::new();
    ONCE.call_once(|| {
        let _ = OUTCOME.set(raise());
    });
    match OUTCOME.get() {
        Some(Ok(r)) if r.after != r.before => {
            crate::hollow_log!("[HOLLOW] Open file limit raised from {} to {}", r.before, r.after);
        }
        Some(Ok(_)) | None => {}
        Some(Err(e)) => crate::hollow_log!("[HOLLOW] Open file limit not raised: {e}"),
    }
}

/// The soft limit to ask for, or `None` when the current one is already enough.
#[cfg_attr(not(unix), allow(dead_code))]
fn target(soft: u64, hard: u64, os_cap: Option<u64>) -> Option<u64> {
    let want = CAP.min(hard).min(os_cap.unwrap_or(u64::MAX));
    (want > soft).then_some(want)
}

#[cfg(unix)]
#[allow(clippy::unnecessary_cast)] // rlim_t is u32 on 32-bit Android and Linux
fn raise() -> Result<Raised, String> {
    let mut lim = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: getrlimit writes only the struct it is given.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) } != 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    let before = lim.rlim_cur as u64;
    let Some(want) = target(before, lim.rlim_max as u64, os_cap()) else {
        return Ok(Raised { before, after: before });
    };
    let new = libc::rlimit { rlim_cur: want as libc::rlim_t, rlim_max: lim.rlim_max };
    // SAFETY: setrlimit reads the struct it is given and nothing else.
    if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &new) } != 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok(Raised { before, after: want })
}

#[cfg(not(unix))]
fn raise() -> Result<Raised, String> {
    Ok(Raised { before: 0, after: 0 })
}

/// Darwin refuses a soft limit above kern.maxfilesperproc even under an unlimited hard one.
#[cfg(target_vendor = "apple")]
fn os_cap() -> Option<u64> {
    let mut v: libc::c_int = 0;
    let mut len = std::mem::size_of::<libc::c_int>();
    // SAFETY: the name is NUL-terminated and the output buffer is a c_int of `len` bytes.
    let rc = unsafe {
        libc::sysctlbyname(
            c"kern.maxfilesperproc".as_ptr(),
            (&mut v as *mut libc::c_int).cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    (rc == 0 && v > 0).then_some(v as u64)
}

#[cfg(all(unix, not(target_vendor = "apple")))]
fn os_cap() -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_open_file_target_stays_under_every_cap_and_never_lowers() {
        assert_eq!(target(256, u64::MAX, Some(245_760)), Some(CAP));
        assert_eq!(target(256, 4096, None), Some(4096));
        assert_eq!(target(256, u64::MAX, Some(2048)), Some(2048));
        assert_eq!(target(1024, 1024, None), None, "already at the hard limit");
        assert_eq!(target(65_536, 524_288, None), None, "a higher soft limit is kept");
    }

    #[cfg(unix)]
    #[test]
    #[allow(clippy::unnecessary_cast)] // rlim_t is u32 on 32-bit Android and Linux
    fn raises_the_open_file_soft_limit() {
        fn get() -> libc::rlimit {
            let mut lim = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
            // SAFETY: getrlimit writes only the struct it is given.
            assert_eq!(unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) }, 0);
            lim
        }
        fn set(lim: libc::rlimit) {
            // SAFETY: setrlimit reads the struct it is given and nothing else.
            assert_eq!(unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &lim) }, 0);
        }
        struct Restore(libc::rlimit);
        impl Drop for Restore {
            fn drop(&mut self) {
                // SAFETY: as in `set`; the limit read at the start is always settable.
                unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &self.0) };
            }
        }
        let start = get();
        let _restore = Restore(start);
        // The macOS default soft limit, the one the app ran out of.
        let low = 256.min(start.rlim_max);
        set(libc::rlimit { rlim_cur: low, rlim_max: start.rlim_max });

        let raised = raise().expect("raise");

        let now = get();
        let hard = start.rlim_max as u64;
        let expect = CAP.min(hard).min(os_cap().unwrap_or(u64::MAX)).max(low as u64);
        assert_eq!(now.rlim_cur as u64, expect, "soft open-file limit not raised");
        assert_eq!(now.rlim_max, start.rlim_max, "the hard limit must not change");
        assert_eq!(raised, Raised { before: low as u64, after: expect });
    }

    #[test]
    fn every_process_entry_that_keeps_secrets_out_also_raises_the_limit() {
        fn walk(dir: &std::path::Path, out: &mut Vec<String>) {
            for e in std::fs::read_dir(dir).expect("src dir").flatten() {
                let p = e.path();
                if p.is_dir() {
                    walk(&p, out);
                } else if p.extension().is_some_and(|x| x == "rs") {
                    let src = std::fs::read_to_string(&p).expect("read").replace("\r\n", "\n");
                    let lines: Vec<&str> = src.lines().map(str::trim).collect();
                    for (i, l) in lines.iter().enumerate() {
                        if *l == "crate::crash_dumps::keep_secrets_out();"
                            && lines.get(i + 1) != Some(&"crate::open_files::raise_soft_limit();")
                        {
                            out.push(format!("{}:{}", p.display(), i + 1));
                        }
                    }
                }
            }
        }
        let mut missing = Vec::new();
        walk(&std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src"), &mut missing);
        assert!(missing.is_empty(), "entries without raise_soft_limit: {missing:?}");
    }
}
