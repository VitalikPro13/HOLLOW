//! C-ABI entry point for the iOS Notification Service Extension (Tier B).
//!
//! The NSE runs in a separate ~24 MB process when the app is force-killed, and it
//! must show decrypted TEXT without advancing the canonical Olm ratchet the app
//! relies on, so it decrypts on a FORK built from the pickles and drops it. Raw C
//! ABI, not flutter_rust_bridge: Swift declares the prototypes in a bridging header
//! and links the same `libhollow_core.a` the Runner already force-loads.

use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::time::Duration;

use crate::crypto::OlmManager;

/// Decrypt a single Olm push message on a FORKED session, for the iOS NSE.
///
/// All string inputs are NUL-terminated UTF-8 owned by the caller:
/// - `account_pickle_json`: account pickle, needed for a first-contact PreKey.
/// - `session_pickle_json`: per-peer session pickle, `""` if there is none yet.
/// - `sender_identity_key_b64`: only for first contact, `""` otherwise.
/// - `message_type`: 0 = PreKey, 1 = Normal.
///
/// Returns a heap C string with the plaintext, or NULL on any failure; the caller
/// MUST free it with [`hollow_push_string_free`]. Never mutates on-disk state.
///
/// # Safety
/// Every pointer must be valid for the call, strings NUL-terminated, and
/// `ciphertext` readable for `ciphertext_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hollow_push_decrypt(
    account_pickle_json: *const c_char,
    session_pickle_json: *const c_char,
    sender_peer_id: *const c_char,
    sender_identity_key_b64: *const c_char,
    message_type: usize,
    ciphertext: *const u8,
    ciphertext_len: usize,
) -> *mut c_char {
    // Bail to NULL on anything malformed; every raw-pointer read is confined here.
    let (account, session, peer_id, sender_idk, ct_owned) = unsafe {
        let account = match cstr(account_pickle_json) {
            Some(s) => s,
            None => return ptr::null_mut(),
        };
        let session = cstr(session_pickle_json).unwrap_or_default();
        let peer_id = match cstr(sender_peer_id) {
            Some(s) if !s.is_empty() => s,
            _ => return ptr::null_mut(),
        };
        let sender_idk = cstr(sender_identity_key_b64).unwrap_or_default();
        if ciphertext.is_null() && ciphertext_len != 0 {
            return ptr::null_mut();
        }
        let ct: Vec<u8> = if ciphertext_len == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(ciphertext, ciphertext_len).to_vec()
        };
        (account, session, peer_id, sender_idk, ct)
    };

    let plaintext = match decrypt_forked(
        &account,
        &session,
        &peer_id,
        &sender_idk,
        message_type,
        &ct_owned,
    ) {
        Ok(p) => p,
        Err(_) => return ptr::null_mut(),
    };

    match CString::new(plaintext) {
        Ok(c) => c.into_raw(),
        Err(_) => ptr::null_mut(), // plaintext contained an interior NUL
    }
}

/// Free a string returned by [`hollow_push_decrypt`].
///
/// # Safety
/// `ptr` must be a pointer previously returned by [`hollow_push_decrypt`], or
/// NULL. Must not be called twice on the same pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hollow_push_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { drop(CString::from_raw(ptr)) };
    }
}

/// iOS NSE entry point: connect to OUR relay, fetch the buffered ciphertext for
/// `sender_peer_id`, decrypt it, and return the message text(s) as JSON.
///
/// The APNs push carries NO content (only `{wake, sender}`), so Apple never sees
/// message data; this is the same `node::fetch` pipeline Dart's Tier-2 fetch uses,
/// invoked here because iOS does not wake the Dart isolate when the app is
/// force-killed. Persisting the advanced session is single-writer-safe only
/// because the NSE is then the SOLE process holding it, so the Swift side MUST
/// check the App-Group heartbeat before calling.
///
/// Inputs (NUL-terminated UTF-8): `data_dir` must hold `messages.db` and the identity
/// file, `license_key` may be "", `timeout_secs` should be ~15 of the NSE's ~30 s, and
/// `server_room` is "" for a DM wake or the server_id of a CHANNEL wake, which
/// decrypts via MLS or signed public plaintext instead of Olm.
///
/// Returns a heap C string holding a JSON array (possibly `[]`), or NULL on hard
/// failure. Entries carry `{"text","message_id","timestamp","has_image"}` plus, for
/// channel wakes, names resolved from the local DB. Caller frees it.
///
/// # Safety
/// All string pointers must be valid NUL-terminated C strings for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hollow_push_fetch_and_decrypt(
    data_dir: *const c_char,
    relay_domain: *const c_char,
    sender_peer_id: *const c_char,
    license_key: *const c_char,
    timeout_secs: u32,
    server_room: *const c_char,
) -> *mut c_char {
    let (data_dir, relay_domain, sender, license, server_room) = unsafe {
        let data_dir = match cstr(data_dir) {
            Some(s) if !s.is_empty() => s,
            _ => return ptr::null_mut(),
        };
        let relay_domain = cstr(relay_domain).unwrap_or_default();
        let sender = match cstr(sender_peer_id) {
            Some(s) if !s.is_empty() => s,
            _ => return ptr::null_mut(),
        };
        let license = cstr(license_key).filter(|s| !s.is_empty());
        let server_room = cstr(server_room).filter(|s| !s.is_empty());
        (data_dir, relay_domain, sender, license, server_room)
    };

    match fetch_and_decrypt(
        &data_dir,
        &relay_domain,
        &sender,
        license.as_deref(),
        timeout_secs,
        server_room.as_deref(),
    ) {
        Ok(json) => CString::new(json).map(|c| c.into_raw()).unwrap_or(ptr::null_mut()),
        Err(_) => ptr::null_mut(),
    }
}

/// Pure-Rust core of the NSE fetch path: like `api::network::start_fetch_node` but with
/// an explicit `data_dir` (the App Group container) and its own single-threaded
/// runtime, since the extension process has no Dart isolate.
fn fetch_and_decrypt(
    data_dir: &str,
    relay_domain: &str,
    sender_peer_id: &str,
    license_key: Option<&str>,
    timeout_secs: u32,
    server_room: Option<&str>,
) -> Result<String, String> {
    use base64::Engine;

    crate::log::init();
    // Route data-dir-dependent paths (identity file, log) at the App Group copy.
    crate::identity::set_data_dir(data_dir.to_string())?;

    // Existing identity only — NEVER generate in the NSE (wrong peer_id + wrong
    // DB passphrase would yield an empty DB / undecryptable session).
    let id = match crate::identity::load_existing_identity()? {
        Some(id) => id,
        None => return Ok("[]".to_string()),
    };
    // DB passphrase is MASTER-derived (a device-derived one opens an empty DB) while
    // WS auth is the DEVICE key, because the relay keyed this device's push token
    // and offline buffer by its device id.
    let master_proto = id
        .keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("encode keypair: {e}"))?;
    let passphrase = hex::encode(&master_proto[..32.min(master_proto.len())]);
    let proto = id
        .device_keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("encode device keypair: {e}"))?;

    let db_path = std::path::Path::new(data_dir)
        .join("messages.db")
        .to_str()
        .ok_or("bad db path")?
        .to_string();

    let mut olm = {
        let store = crate::storage::MessageStore::open(&db_path, &passphrase)?;
        match store.load_olm_account()? {
            Some(account_json) => {
                let sessions = store.load_all_olm_sessions()?;
                OlmManager::from_pickles(&account_json, sessions)?
            }
            None => return Ok("[]".to_string()),
        }
    };

    let pub_key_b64 = base64::engine::general_purpose::STANDARD
        .encode(id.device_keypair.public_key_protobuf());
    let peer_id = id.device_keypair.peer_id();
    let local_master = id.keypair.peer_id();

    // Warm the resolver from persisted device links so the MASTER-paired DM room
    // + conversation key resolve correctly (single-device → self-map no-op).
    if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
        if let Ok(links) = store.get_all_device_links() {
            crate::node::resolver::warm_from_links(&links);
        }
    }
    crate::node::resolver::seed_self(&local_master, &[peer_id.clone(), local_master.clone()]);

    let relay = if relay_domain.is_empty() {
        "relay.anonlisten.com"
    } else {
        relay_domain
    };

    // Channel wake: load the one server's MLS group so buffered group ciphertext
    // decrypts. Failure degrades to a content-free line, synced on next open.
    let mut mls: Option<crate::crypto::MlsManager> = match server_room {
        Some(room) => {
            let store = crate::storage::MessageStore::open(&db_path, &passphrase)?;
            match store.load_mls_identity() {
                Ok(Some((signer, cred, storage))) => crate::crypto::MlsManager::from_persisted(
                    &signer,
                    &cred,
                    storage.as_deref(),
                    &[room.to_string()],
                )
                .ok(),
                _ => None,
            }
        }
        None => None,
    };

    // Own runtime — the NSE process has no global app runtime. current_thread keeps
    // the memory footprint minimal (the 24 MB NSE cap is the binding constraint).
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("tokio build: {e}"))?;

    let crypto_store = rt.block_on(async {
        crate::crypto::CryptoStore::open(db_path.clone(), passphrase.clone())
    })?;

    let results = rt.block_on(crate::node::fetch::run_fetch(
        relay,
        &peer_id,
        &local_master,
        &proto,
        &pub_key_b64,
        license_key,
        sender_peer_id,
        server_room,
        Duration::from_secs(timeout_secs as u64),
        &mut olm,
        &mut mls,
        &crypto_store,
        &db_path,
        &passphrase,
    ))?;

    // Persist final account state (consumed one-time keys).
    if let Ok(account_json) = olm.account_pickle_json() {
        crypto_store.save_account(account_json);
    }

    // Channel wakes render "Server • #channel" and "Name: text", so resolve those
    // names on-device rather than paying extra round-trips.
    let mut server_names: std::collections::HashMap<String, (String, std::collections::HashMap<String, String>)> =
        std::collections::HashMap::new();
    let mut sender_names: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    if server_room.is_some() && !results.is_empty() {
        if let Ok(store) = crate::storage::MessageStore::open(&db_path, &passphrase) {
            for dm in &results {
                if let Some(sid) = &dm.server_id {
                    if !server_names.contains_key(sid) {
                        if let Ok(Some(json)) = store.load_server_state(sid) {
                            if let Ok(state) =
                                serde_json::from_str::<crate::crdt::server_state::ServerState>(&json)
                            {
                                let channels = state
                                    .channels
                                    .iter()
                                    .map(|(id, c)| (id.clone(), c.name.clone()))
                                    .collect();
                                server_names.insert(sid.clone(), (state.name.read().clone(), channels));
                            }
                        }
                    }
                }
                if !sender_names.contains_key(&dm.from_peer) {
                    if let Ok(Some(p)) = store.load_profile_light(&dm.from_peer) {
                        sender_names.insert(dm.from_peer.clone(), p.display_name);
                    }
                }
            }
        }
    }

    // Built by hand so no Serialize derive crosses the C boundary; serde_json escapes.
    let items: Vec<serde_json::Value> = results
        .into_iter()
        .map(|dm| {
            let mut obj = serde_json::json!({
                // Emote tokens are unreadable hashes in a plain-text banner.
                "text": crate::node::emotes::emote_tokens_to_shortcodes(&dm.text),
                "message_id": dm.message_id,
                "timestamp": dm.timestamp,
                "has_image": dm.image_path.is_some(),
            });
            if let (Some(sid), Some(cid)) = (&dm.server_id, &dm.channel_id) {
                let map = obj.as_object_mut().unwrap();
                map.insert("server_id".into(), serde_json::Value::String(sid.clone()));
                map.insert("channel_id".into(), serde_json::Value::String(cid.clone()));
                if let Some((sname, channels)) = server_names.get(sid) {
                    map.insert("server_name".into(), serde_json::Value::String(sname.clone()));
                    if let Some(cname) = channels.get(cid) {
                        map.insert("channel_name".into(), serde_json::Value::String(cname.clone()));
                    }
                }
                if let Some(name) = sender_names.get(&dm.from_peer) {
                    map.insert("sender_name".into(), serde_json::Value::String(name.clone()));
                }
            }
            obj
        })
        .collect();
    Ok(serde_json::Value::Array(items).to_string())
}

/// Core fork-and-decrypt, pure Rust. Builds a THROWAWAY `OlmManager` from the
/// supplied pickles and drops it, so the canonical on-disk session is never touched.
fn decrypt_forked(
    account_pickle_json: &str,
    session_pickle_json: &str,
    peer_id: &str,
    sender_identity_key_b64: &str,
    message_type: usize,
    ciphertext: &[u8],
) -> Result<String, String> {
    if session_pickle_json.is_empty() {
        // First contact: create the inbound session on a fork. PreKey only.
        if message_type != 0 {
            return Err("no session and message is not a PreKey".into());
        }
        let mut fork = OlmManager::from_pickles(account_pickle_json, vec![])?;
        let bytes = fork.create_inbound_session(peer_id, sender_identity_key_b64, ciphertext)?;
        return String::from_utf8(bytes).map_err(|e| format!("plaintext not UTF-8: {e}"));
    }

    let mut fork = OlmManager::from_pickles(
        account_pickle_json,
        vec![(peer_id.to_string(), session_pickle_json.to_string())],
    )?;
    let bytes = fork.decrypt(peer_id, message_type, ciphertext)?;
    String::from_utf8(bytes).map_err(|e| format!("plaintext not UTF-8: {e}"))
}

/// Convert a C string pointer to an owned Rust String. None if null or not UTF-8.
unsafe fn cstr(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok().map(|s| s.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::OlmManager;

    // Exercises the pure-Rust core of the C ABI end to end.
    #[test]
    fn push_enrich_forked_decrypt_existing_session() {
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();
        let bob_idk = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();
        alice.create_outbound_session("bob", &bob_idk, &bob_otk).unwrap();
        let (_t, ct) = alice.encrypt("bob", b"hi").unwrap();
        let alice_idk = alice.identity_key_base64();
        bob.create_inbound_session("alice", &alice_idk, &ct).unwrap();
        let (t2, ct2) = bob.encrypt("alice", b"ack").unwrap();
        alice.decrypt("bob", t2, &ct2).unwrap();

        // Bob's canonical pickles (the phone's DB state).
        let acct = bob.account_pickle_json().unwrap();
        let sess = bob.session_pickle_json("alice").unwrap().unwrap();

        let (mt, ctp) = alice.encrypt("bob", b"push body").unwrap();

        let pt = decrypt_forked(&acct, &sess, "alice", "", mt, &ctp).unwrap();
        assert_eq!(pt, "push body");

        // The canonical session is untouched: a fresh load decrypts the same message.
        let mut app = OlmManager::from_pickles(&acct, vec![("alice".into(), sess)]).unwrap();
        assert_eq!(app.decrypt("alice", mt, &ctp).unwrap(), b"push body");
    }

    #[test]
    fn push_enrich_forked_decrypt_first_contact() {
        let mut alice = OlmManager::new();
        let mut bob = OlmManager::new();
        let bob_idk = bob.identity_key_base64();
        let bob_otk = bob.generate_one_time_key();
        alice.create_outbound_session("bob", &bob_idk, &bob_otk).unwrap();
        let (mt, ct) = alice.encrypt("bob", b"first").unwrap();
        let alice_idk = alice.identity_key_base64();
        let acct = bob.account_pickle_json().unwrap();

        // Empty session pickle = first contact; NSE creates inbound on a fork.
        let pt = decrypt_forked(&acct, "", "alice", &alice_idk, mt, &ct).unwrap();
        assert_eq!(pt, "first");
    }
}
