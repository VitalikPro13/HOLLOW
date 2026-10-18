//! Push wakes as FCM and APNs carry them.

use std::collections::HashMap;

use flutter_rust_bridge::frb;

/// The wake an FCM data block carries (`type`, `sender`, `server`, `channel`, `mention`),
/// or None to drop it: once this install registered its wake key set, only a fresh
/// block sealed to it counts, and only once (AR-26). `tap` asks only which chat a
/// tapped banner opens, which an old banner may still ask.
#[frb]
pub fn open_push_wake(fields: HashMap<String, String>, tap: bool) -> Option<HashMap<String, String>> {
    use crate::crypto::push_seal::{open_wake, Reader};
    let root = crate::identity::data_dir().ok()?;
    let fields = fields.into_iter().collect();
    let reader = if tap { Reader::Tap } else { Reader::App };
    open_wake(&root, &fields, reader).map(|wake| wake.into_iter().collect())
}
