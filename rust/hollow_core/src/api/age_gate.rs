//! Age-restricted servers on phones: the gate's state for Settings and the hidden set
//! for every surface Dart draws (`node::age_gate` holds the rules).

use flutter_rust_bridge::frb;

use crate::node::age_gate::{self, Platform};
use crate::storage::MessageStore;

/// The gate as this device sees it.
pub struct AgeGateFfi {
    /// "desktop", "ios" or "android".
    pub platform: String,
    /// The identity's choice for its phones.
    pub phones_allow: bool,
    /// This Android phone's own toggle (always false elsewhere).
    pub local_allow: bool,
    /// Whether this device shows age-restricted servers.
    pub allowed_here: bool,
    /// This computer already offered the choice after an 18+ join.
    pub asked: bool,
}

fn with_store<T>(f: impl FnOnce(&MessageStore) -> Result<T, String>) -> Result<T, String> {
    let store = super::storage::get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    f(ms)
}

#[frb]
pub fn age_gate_status() -> Result<AgeGateFfi, String> {
    let platform = Platform::current();
    with_store(|st| {
        Ok(AgeGateFfi {
            platform: platform.name().to_string(),
            phones_allow: age_gate::held(st).is_some_and(|e| e.allow),
            local_allow: age_gate::local_allowed(st, platform),
            allowed_here: age_gate::allowed_here(st, platform),
            asked: st.load_setting(age_gate::ASKED_KEY).ok().flatten().is_some(),
        })
    })
}

/// The identity's choice for its phones. A computer only; every device of ours hears it.
#[frb]
pub fn set_age_gate_for_phones(allow: bool) -> Result<(), String> {
    with_store(|st| age_gate::author(st, Platform::current(), allow, crate::node::types::now_ms()).map(|_| ()))?;
    let _ = super::network::send_node_command(crate::node::NodeCommand::AgeGateChanged);
    Ok(())
}

/// An Android phone's own toggle; refused on every other build and on store installs.
#[frb]
pub fn set_age_gate_on_this_phone(allow: bool) -> Result<(), String> {
    with_store(|st| age_gate::set_local(st, Platform::current(), allow))?;
    let _ = super::network::send_node_command(crate::node::NodeCommand::AgeGateChanged);
    Ok(())
}

/// An Android build says at start whether a store installed it: a store build behaves
/// like an iPhone, a sideload keeps its own toggle.
#[frb]
pub fn set_age_gate_store_install(store_install: bool) -> Result<(), String> {
    if Platform::current() != Platform::Android {
        return Ok(());
    }
    if with_store(|st| age_gate::mark_store_install(st, store_install))? {
        let _ = super::network::send_node_command(crate::node::NodeCommand::AgeGateChanged);
    }
    Ok(())
}

/// The one-time offer after an 18+ join was shown on this computer.
#[frb]
pub fn mark_age_gate_asked() -> Result<(), String> {
    with_store(|st| st.save_setting(age_gate::ASKED_KEY, "1"))
}

/// Every joined server this device hides (empty on a computer or an open gate).
#[frb]
pub fn age_hidden_servers() -> Result<Vec<String>, String> {
    with_store(|st| {
        let states: Vec<(String, crate::crdt::server_state::ServerState)> = st
            .load_all_servers()?
            .into_iter()
            .filter_map(|(sid, json)| serde_json::from_str(&json).ok().map(|s| (sid, s)))
            .collect();
        Ok(age_gate::hidden_servers(st, Platform::current(), states.iter().map(|(a, b)| (a, b))))
    })
}

/// Whether a notification for `server_id` must not show. Safe in a push isolate (opens
/// the store itself); `None` when the identity is locked and nothing can be judged.
#[frb]
pub fn server_age_hidden(server_id: String) -> Option<bool> {
    crate::log::init();
    let platform = Platform::current();
    if platform == Platform::Desktop {
        return Some(false);
    }
    let Ok(Some(id)) = crate::identity::load_existing_identity() else {
        return None;
    };
    let proto = id.keypair.to_protobuf_encoding().ok()?;
    let passphrase = hex::encode(&proto[..32.min(proto.len())]);
    let db_path = crate::identity::data_dir()
        .ok()
        .and_then(|d| d.join("messages.db").to_str().map(str::to_string))?;
    let store = MessageStore::open(&db_path, &passphrase).ok()?;
    Some(age_gate::server_hidden_in(&store, platform, &server_id))
}
