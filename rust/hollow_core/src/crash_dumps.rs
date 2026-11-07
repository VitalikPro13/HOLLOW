//! Keeps the process's memory out of crash dumps: it holds Olm and MLS secrets, the
//! database key and the identity (HOL-SEC-200).
//!
//! Unix sets RLIMIT_CORE to zero, which the kernel honours for core files and
//! systemd-coredump and apport honour for piped dumps. PR_SET_DUMPABLE stays on:
//! xdg-desktop-portal and PipeWire identify a client by opening /proc/PID/root, which
//! a non-dumpable process refuses them, so the flatpak would lose its portals and
//! audio. Windows keeps Error Reporting but without the heap in its dumps.
//! `hollow_crash.log` comes from Dart's error handlers and is not touched.

use std::sync::Once;

/// Idempotent; every process entry point (the app, the push fetch, the iOS extension,
/// the forwarder) calls it before any secret is loaded.
pub(crate) fn keep_secrets_out() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        if let Err(e) = forbid() {
            crate::hollow_log!("[HOLLOW-CRYPTO] Crash dumps not limited: {e}");
        }
    });
}

#[cfg(unix)]
fn forbid() -> Result<(), String> {
    let none = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: setrlimit reads the struct it is given and nothing else.
    if unsafe { libc::setrlimit(libc::RLIMIT_CORE, &none) } != 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok(())
}

#[cfg(windows)]
fn forbid() -> Result<(), String> {
    use windows_sys::Win32::System::ErrorReporting::{WerSetFlags, WER_FAULT_REPORTING_FLAG_NOHEAP};
    // SAFETY: WerSetFlags takes a flag word and touches only this process's WER settings.
    let hr = unsafe { WerSetFlags(WER_FAULT_REPORTING_FLAG_NOHEAP) };
    if hr < 0 {
        return Err(format!("WerSetFlags failed: {hr:#x}"));
    }
    Ok(())
}

#[cfg(not(any(unix, windows)))]
fn forbid() -> Result<(), String> {
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_process_that_holds_secrets_writes_no_core_dump_with_its_heap() {
        super::keep_secrets_out();
        #[cfg(unix)]
        {
            let mut held = libc::rlimit { rlim_cur: 1, rlim_max: 1 };
            // SAFETY: getrlimit writes only the struct it is given.
            assert_eq!(unsafe { libc::getrlimit(libc::RLIMIT_CORE, &mut held) }, 0);
            assert_eq!((held.rlim_cur, held.rlim_max), (0, 0), "core dumps are still allowed");
        }
        #[cfg(windows)]
        {
            use windows_sys::Win32::System::ErrorReporting::{WerGetFlags, WER_FAULT_REPORTING_FLAG_NOHEAP};
            use windows_sys::Win32::System::Threading::GetCurrentProcess;
            let mut flags = 0;
            // SAFETY: WerGetFlags writes only the flag word it is given.
            assert!(unsafe { WerGetFlags(GetCurrentProcess(), &mut flags) } >= 0);
            assert_ne!(flags & WER_FAULT_REPORTING_FLAG_NOHEAP, 0, "crash reports still carry the heap");
        }
    }
}
