//! Pure admission + budget policy for the media forwarder.
//!
//! Everything here is a pure function over plain arguments so the policy is
//! unit-testable without any I/O (the media plane itself is outside harness
//! scope by doctrine — D6 field verification covers it).
//!
//! Iron rule (locked decision 5): the budget REFUSES NEW work — new streams,
//! new legs — with explicit `FwdError` codes. It NEVER evicts or degrades an
//! existing leg.

use std::time::{Duration, Instant};

/// Wire error codes for `MessageEnvelope::FwdError`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FwdErrorCode {
    /// A count cap (streams per sender, legs per stream) is exhausted.
    Full,
    /// The global egress bandwidth budget is exhausted.
    OverBudget,
    /// Sender isn't allowed to do that (spoofed origin, not the stream owner,
    /// viewer not on the allowlist).
    NotAuthorized,
    /// The referenced stream isn't registered.
    UnknownStream,
    /// The forwarder is draining for shutdown.
    ShuttingDown,
}

impl FwdErrorCode {
    pub(crate) fn as_wire(&self) -> &'static str {
        match self {
            Self::Full => "full",
            Self::OverBudget => "over_budget",
            Self::NotAuthorized => "not_authorized",
            Self::UnknownStream => "unknown_stream",
            Self::ShuttingDown => "shutting_down",
        }
    }
}

/// Budget caps (from `ForwarderConfig`).
#[derive(Debug, Clone)]
pub(crate) struct BudgetCfg {
    pub max_streams_global: u32,
    pub max_streams_per_sender: u32,
    pub max_legs_per_stream: u32,
    /// Global egress budget in bits/sec. 0 = unlimited.
    pub max_egress_bps: u64,
}

/// Kill legs that never reached ICE `Connected` after this long (DoS bound:
/// an attacker registering streams and never connecting must not pin ports).
pub(crate) const UNCONNECTED_LEG_TTL: Duration = Duration::from_secs(60);

/// May `sender` register one more stream?
pub(crate) fn can_register(
    sender_stream_count: u32,
    global_stream_count: u32,
    cfg: &BudgetCfg,
) -> Result<(), FwdErrorCode> {
    if sender_stream_count >= cfg.max_streams_per_sender {
        return Err(FwdErrorCode::Full);
    }
    if global_stream_count >= cfg.max_streams_global {
        return Err(FwdErrorCode::Full);
    }
    Ok(())
}

/// May one more egress leg attach to a stream?
///
/// `current_egress_bps` is the forwarder-wide egress estimate; admission
/// refuses NEW legs once the budget is exhausted but never touches existing
/// ones (a stream mid-flight pushing past the cap keeps flowing).
pub(crate) fn can_attach(
    stream_leg_count: u32,
    current_egress_bps: u64,
    cfg: &BudgetCfg,
) -> Result<(), FwdErrorCode> {
    if stream_leg_count >= cfg.max_legs_per_stream {
        return Err(FwdErrorCode::Full);
    }
    if cfg.max_egress_bps > 0 && current_egress_bps >= cfg.max_egress_bps {
        return Err(FwdErrorCode::OverBudget);
    }
    Ok(())
}

/// Should an unconnected leg be swept? (`true` = kill it.)
pub(crate) fn sweep_unconnected(spawned_at: Instant, connected: bool, now: Instant) -> bool {
    !connected && now.duration_since(spawned_at) >= UNCONNECTED_LEG_TTL
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> BudgetCfg {
        BudgetCfg {
            max_streams_global: 16,
            max_streams_per_sender: 4,
            max_legs_per_stream: 32,
            max_egress_bps: 100_000_000,
        }
    }

    #[test]
    fn register_caps() {
        assert!(can_register(0, 0, &cfg()).is_ok());
        assert!(can_register(3, 3, &cfg()).is_ok());
        // 5th stream from one sender refused.
        assert_eq!(can_register(4, 4, &cfg()), Err(FwdErrorCode::Full));
        // Global cap refused even for a fresh sender.
        assert_eq!(can_register(0, 16, &cfg()), Err(FwdErrorCode::Full));
    }

    #[test]
    fn attach_caps() {
        assert!(can_attach(0, 0, &cfg()).is_ok());
        assert_eq!(can_attach(32, 0, &cfg()), Err(FwdErrorCode::Full));
        assert_eq!(
            can_attach(0, 100_000_000, &cfg()),
            Err(FwdErrorCode::OverBudget)
        );
        // Just below the budget still admits.
        assert!(can_attach(0, 99_999_999, &cfg()).is_ok());
    }

    #[test]
    fn attach_unlimited_bps_when_zero() {
        let mut c = cfg();
        c.max_egress_bps = 0;
        assert!(can_attach(0, u64::MAX, &c).is_ok());
    }

    #[test]
    fn unconnected_sweep_timing() {
        let now = Instant::now();
        let old = now - Duration::from_secs(61);
        let fresh = now - Duration::from_secs(5);
        assert!(sweep_unconnected(old, false, now));
        assert!(!sweep_unconnected(fresh, false, now));
        // Connected legs are never swept regardless of age.
        assert!(!sweep_unconnected(old, true, now));
    }

    #[test]
    fn wire_codes() {
        assert_eq!(FwdErrorCode::Full.as_wire(), "full");
        assert_eq!(FwdErrorCode::OverBudget.as_wire(), "over_budget");
        assert_eq!(FwdErrorCode::NotAuthorized.as_wire(), "not_authorized");
        assert_eq!(FwdErrorCode::UnknownStream.as_wire(), "unknown_stream");
        assert_eq!(FwdErrorCode::ShuttingDown.as_wire(), "shutting_down");
    }
}
