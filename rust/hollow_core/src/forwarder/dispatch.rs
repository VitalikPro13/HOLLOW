//! fwd_* admission decisions.
//!
//! The decision functions are PURE (no I/O, no engine state mutation) so the
//! whole authorization surface is unit-testable: the engine gathers a view of
//! the relevant state, asks, then applies.
//!
//! Deliberately NO control-frame rate limiter (removed 2026-08-07): the
//! per-peer token bucket that lived here dropped frames with zero trace —
//! the silent-drop class the relay refuses (`feedback_relay_rules`) and a
//! suspect in the vanished-large-frame field defect. Every refusal on this
//! surface is an explicit `FwdError`; unwanted frames fail the cheap parse
//! path and get logged.

use super::budget::{can_attach, can_register, BudgetCfg, FwdErrorCode};

/// What the engine knows about a stream when admitting a request.
#[derive(Debug, Clone)]
pub(crate) struct StreamView {
    pub owner: String,
    pub sender_allowlisted: bool,
    pub egress_leg_count: u32,
}

/// May `sender` register a stream claiming `origin_peer`?
///
/// The origin peer MUST be the Olm-authenticated sender — this is the
/// forwarder-side twin of the vc-lane spoof guard: with a shared SFrame group
/// key, a spoofed registration would attribute the registrant's pixels to a
/// victim.
pub(crate) fn admit_register(
    origin_peer: &str,
    sender: &str,
    sender_stream_count: u32,
    global_stream_count: u32,
    already_registered_by_sender: bool,
    shutting_down: bool,
    cfg: &BudgetCfg,
) -> Result<(), FwdErrorCode> {
    if shutting_down {
        return Err(FwdErrorCode::ShuttingDown);
    }
    if origin_peer != sender {
        return Err(FwdErrorCode::NotAuthorized);
    }
    // Idempotent re-register (allowlist replacement) bypasses the count caps —
    // it creates nothing new.
    if already_registered_by_sender {
        return Ok(());
    }
    can_register(sender_stream_count, global_stream_count, cfg)
}

/// May `sender` perform an owner-only operation (auth update, unregister,
/// ingest offer) on a stream?
pub(crate) fn admit_owner_op(
    stream: Option<&StreamView>,
    sender: &str,
) -> Result<(), FwdErrorCode> {
    match stream {
        None => Err(FwdErrorCode::UnknownStream),
        Some(s) if s.owner != sender => Err(FwdErrorCode::NotAuthorized),
        Some(_) => Ok(()),
    }
}

/// May `sender` attach an egress leg to a stream?
pub(crate) fn admit_attach(
    stream: Option<&StreamView>,
    current_egress_bps: u64,
    shutting_down: bool,
    cfg: &BudgetCfg,
) -> Result<(), FwdErrorCode> {
    if shutting_down {
        return Err(FwdErrorCode::ShuttingDown);
    }
    let Some(s) = stream else {
        return Err(FwdErrorCode::UnknownStream);
    };
    if !s.sender_allowlisted {
        return Err(FwdErrorCode::NotAuthorized);
    }
    can_attach(s.egress_leg_count, current_egress_bps, cfg)
}

/// May `sender` detach / answer an egress leg? (Must own one on that stream —
/// the engine looks the leg up by sender, so existence IS ownership; this
/// helper only maps absence to the right code.)
pub(crate) fn admit_viewer_op(has_leg: bool) -> Result<(), FwdErrorCode> {
    if has_leg {
        Ok(())
    } else {
        Err(FwdErrorCode::NotAuthorized)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> BudgetCfg {
        BudgetCfg {
            max_streams_global: 16,
            max_streams_per_sender: 4,
            max_legs_per_stream: 32,
            max_egress_bps: 0,
        }
    }

    fn view(owner: &str, allowlisted: bool, legs: u32) -> StreamView {
        StreamView {
            owner: owner.into(),
            sender_allowlisted: allowlisted,
            egress_leg_count: legs,
        }
    }

    #[test]
    fn register_requires_origin_eq_sender() {
        assert_eq!(
            admit_register("12D3KooWVictim", "12D3KooWAttacker", 0, 0, false, false, &cfg()),
            Err(FwdErrorCode::NotAuthorized)
        );
        assert!(admit_register("12D3KooWS", "12D3KooWS", 0, 0, false, false, &cfg()).is_ok());
    }

    #[test]
    fn register_shutdown_and_idempotency() {
        assert_eq!(
            admit_register("s", "s", 0, 0, false, true, &cfg()),
            Err(FwdErrorCode::ShuttingDown)
        );
        // Re-register bypasses the caps (creates nothing new).
        assert!(admit_register("s", "s", 4, 16, true, false, &cfg()).is_ok());
        // Fresh registration at the cap refused.
        assert_eq!(
            admit_register("s", "s", 4, 4, false, false, &cfg()),
            Err(FwdErrorCode::Full)
        );
    }

    #[test]
    fn owner_ops() {
        assert_eq!(admit_owner_op(None, "s"), Err(FwdErrorCode::UnknownStream));
        assert_eq!(
            admit_owner_op(Some(&view("owner", false, 0)), "not-owner"),
            Err(FwdErrorCode::NotAuthorized)
        );
        assert!(admit_owner_op(Some(&view("s", false, 0)), "s").is_ok());
    }

    #[test]
    fn attach_gates() {
        assert_eq!(
            admit_attach(None, 0, false, &cfg()),
            Err(FwdErrorCode::UnknownStream)
        );
        assert_eq!(
            admit_attach(Some(&view("o", false, 0)), 0, false, &cfg()),
            Err(FwdErrorCode::NotAuthorized)
        );
        assert!(admit_attach(Some(&view("o", true, 0)), 0, false, &cfg()).is_ok());
        assert_eq!(
            admit_attach(Some(&view("o", true, 32)), 0, false, &cfg()),
            Err(FwdErrorCode::Full)
        );
        assert_eq!(
            admit_attach(Some(&view("o", true, 0)), 0, true, &cfg()),
            Err(FwdErrorCode::ShuttingDown)
        );
    }

    #[test]
    fn viewer_ops() {
        assert!(admit_viewer_op(true).is_ok());
        assert_eq!(admit_viewer_op(false), Err(FwdErrorCode::NotAuthorized));
    }
}
