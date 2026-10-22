//! The server member cap (g13): a server stops admitting new members once it holds
//! [`MEMBER_CAP`] identities, or the owner's lower `max_members`.
//!
//! Enforced only where a member admits a joiner, never in the CRDT fold: a fold rule
//! one version applies and another does not splits who counts as a member, and an MLS
//! commit refused over that forks the group. So the cap is advisory load shaping, not a
//! security boundary; an older answerer can still admit past it.

use crate::crdt::server_state::ServerState;

/// The most identities a server admits. One number to raise as the scale fixes land.
pub(crate) const MEMBER_CAP: u32 = 512;

/// The cap in force: [`MEMBER_CAP`], or the owner's `max_members` when lower.
pub(crate) fn effective_cap(state: &ServerState) -> u32 {
    state.max_members().map_or(hard_cap(), |owner| owner.min(hard_cap()))
}

/// Whether the server takes no new member. `members` is keyed by master, so its length
/// is the identity count, the same count the fold's own `max_members` rule reads.
pub(crate) fn is_full(state: &ServerState) -> bool {
    state.members.len() as u32 >= effective_cap(state)
}

/// [`MEMBER_CAP`], lowered only by a harness test.
pub(crate) fn hard_cap() -> u32 {
    #[cfg(test)]
    if let Some(cap) = test_cap() {
        return cap;
    }
    MEMBER_CAP
}

#[cfg(test)]
static TEST_CAP: std::sync::Mutex<Option<u32>> = std::sync::Mutex::new(None);

#[cfg(test)]
fn test_cap() -> Option<u32> {
    TEST_CAP.lock().ok().and_then(|c| *c)
}

/// A harness test's lowered cap; `None` restores [`MEMBER_CAP`].
#[cfg(test)]
pub(crate) fn set_cap_for_test(cap: Option<u32>) {
    if let Ok(mut c) = TEST_CAP.lock() {
        *c = cap;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_cap_is_512_identities() {
        assert_eq!(MEMBER_CAP, 512);
    }
}
