//! What a Welcome phrase restore that minted this device leaves behind
//! (PHRASE_RESTORE_DESIGN 1.2 step 10): the Home card, the fresh-install branch of
//! `shared_servers::recovering` and the set-aside gate read it. This device's own row,
//! never in a copy (`scrub_device_secrets`, `forget_device_secrets`).

use serde::{Deserialize, Serialize};

use crate::storage::MessageStore;

/// `app_settings` key of the mark.
pub(crate) const KEY: &str = "welcome_restore";

/// How long the mark counts: the Home card, the set-aside retry and the server asks.
pub(crate) const WINDOW_MS: i64 = super::shared_servers::RECOVERY_WINDOW_MS;

/// Welcome's branch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Branch {
    /// No: a phrase admission.
    Admit,
    /// Yes: a phrase recovery.
    Recover,
}

impl Branch {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Branch::Admit => "admit",
            Branch::Recover => "recover",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Mark {
    pub(crate) at_ms: i64,
    pub(crate) branch: Branch,
    /// No roster was held here: a fresh install.
    pub(crate) empty: bool,
    /// The device the restore minted.
    pub(crate) device: String,
}

pub(crate) fn write(store: &MessageStore, mark: &Mark) -> Result<(), String> {
    let json = serde_json::to_string(mark).map_err(|e| format!("welcome restore mark: {e}"))?;
    store.save_setting(KEY, &json)
}

/// The mark, only when it names `local_device` and its window still runs at `now_ms`.
pub(crate) fn current(store: &MessageStore, local_device: &str, now_ms: i64) -> Option<Mark> {
    let mark: Mark = serde_json::from_str(&store.load_setting(KEY).ok()??).ok()?;
    (mark.device == local_device && now_ms.saturating_sub(mark.at_ms) < WINDOW_MS).then_some(mark)
}

/// Whether "Type my phrase again" may set this identity aside (6.2): a current mark,
/// no accepted friend, and no server held or being joined. Once someone else knows
/// this identity only Settings' erase remains.
pub(crate) fn may_set_aside(store: &MessageStore, local_device: &str, now_ms: i64) -> bool {
    current(store, local_device, now_ms).is_some()
        && store.load_friends(Some("accepted")).is_ok_and(|f| f.is_empty())
        && store.load_all_servers().is_ok_and(|s| s.is_empty())
        && store.load_pending_joins().is_ok_and(|p| p.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_mark_counts_only_for_its_device_and_its_window() {
        let store = MessageStore::open(":memory:", &"ab".repeat(32)).unwrap();
        let mark = Mark { at_ms: 1_000, branch: Branch::Admit, empty: true, device: "dev".into() };
        write(&store, &mark).unwrap();
        assert_eq!(current(&store, "dev", 1_000 + WINDOW_MS - 1), Some(mark));
        assert_eq!(current(&store, "dev", 1_000 + WINDOW_MS), None, "past its window");
        assert_eq!(current(&store, "other", 1_001), None, "another device's mark");
    }
}
