use std::sync::{Mutex, OnceLock};

use flutter_rust_bridge::frb;

use super::network::get_runtime;
use super::storage::get_store;
use crate::node::twitch;

// ── In-memory token cache ───────────────────────────────────────────

struct CachedToken {
    access_token: String,
    expires_at: std::time::Instant,
    last_validated: std::time::Instant,
}

static TWITCH_TOKEN: OnceLock<Mutex<Option<CachedToken>>> = OnceLock::new();

fn get_token_cache() -> &'static Mutex<Option<CachedToken>> {
    TWITCH_TOKEN.get_or_init(|| Mutex::new(None))
}

// ── FFI structs ─────────────────────────────────────────────────────

pub struct TwitchDeviceFlowResult {
    pub user_code: String,
    pub verification_uri: String,
    pub device_code: String,
    pub interval_secs: u64,
}

// ── Settings keys ───────────────────────────────────────────────────

const KEY_REFRESH_TOKEN: &str = "twitch_refresh_token";
const KEY_USER_ID: &str = "twitch_user_id";
const KEY_TWITCH_USERNAME: &str = "twitch_username";

fn save_tw_setting(key: &str, value: &str) -> Result<(), String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.save_setting(key, value)
}

fn load_tw_setting(key: &str) -> Result<Option<String>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.load_setting(key)
}

// ── FFI functions ───────────────────────────────────────────────────

#[frb]
pub fn twitch_start_device_flow() -> Result<TwitchDeviceFlowResult, String> {
    let rt = get_runtime();
    let resp = rt.block_on(twitch::start_device_flow())?;
    Ok(TwitchDeviceFlowResult {
        user_code: resp.user_code,
        verification_uri: resp.verification_uri,
        device_code: resp.device_code,
        interval_secs: resp.interval,
    })
}

#[frb]
pub fn twitch_poll_for_token(device_code: String, interval_secs: u64) -> Result<String, String> {
    let rt = get_runtime();
    let token_resp = rt.block_on(twitch::poll_for_token(&device_code, interval_secs))?;

    // Validate to get user_id.
    let validate = rt.block_on(twitch::validate_token(&token_resp.access_token))?;

    // Persist refresh token + user_id to SQLCipher.
    save_tw_setting(KEY_REFRESH_TOKEN, &token_resp.refresh_token)?;
    save_tw_setting(KEY_USER_ID, &validate.user_id)?;
    save_tw_setting(KEY_TWITCH_USERNAME, &validate.login)?;

    // Cache access token in memory.
    let now = std::time::Instant::now();
    let expires_at = now + std::time::Duration::from_secs(token_resp.expires_in.saturating_sub(60));
    let mut cache = get_token_cache().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    *cache = Some(CachedToken {
        access_token: token_resp.access_token,
        expires_at,
        last_validated: now,
    });

    Ok(validate.user_id)
}

#[frb]
pub fn twitch_ensure_token() -> Result<bool, String> {
    let now = std::time::Instant::now();

    // Check if we have a cached token that's still valid.
    {
        let cache = get_token_cache().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        if let Some(ref cached) = *cache {
            if now < cached.expires_at {
                // Token still valid. Check if hourly validation is needed.
                let since_validated = now.duration_since(cached.last_validated);
                if since_validated < std::time::Duration::from_secs(3600) {
                    return Ok(true);
                }
                // Need hourly validation — fall through.
            }
        }
    }

    // Try to refresh from stored refresh token.
    let refresh_token = load_tw_setting(KEY_REFRESH_TOKEN)?;
    let refresh_token = match refresh_token {
        Some(t) if !t.is_empty() => t,
        _ => return Ok(false),
    };

    let rt = get_runtime();
    let token_resp = match rt.block_on(twitch::refresh_access_token(&refresh_token)) {
        Ok(resp) => resp,
        Err(_) => {
            // Refresh failed (expired or revoked). Clear stored tokens.
            let _ = save_tw_setting(KEY_REFRESH_TOKEN, "");
            return Ok(false);
        }
    };

    // Save new refresh token (one-time use — old one is now invalid).
    save_tw_setting(KEY_REFRESH_TOKEN, &token_resp.refresh_token)?;

    // Validate to confirm token is good + refresh stored username.
    let validate = rt.block_on(twitch::validate_token(&token_resp.access_token));
    let validated_now = validate.is_ok();
    if let Ok(ref v) = validate {
        let _ = save_tw_setting(KEY_TWITCH_USERNAME, &v.login);
    }

    // Cache the new access token.
    let expires_at = now + std::time::Duration::from_secs(token_resp.expires_in.saturating_sub(60));
    let mut cache = get_token_cache().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    *cache = Some(CachedToken {
        access_token: token_resp.access_token,
        expires_at,
        last_validated: if validated_now { now } else { now - std::time::Duration::from_secs(3600) },
    });

    Ok(true)
}

#[frb]
pub fn twitch_generate_proof(broadcaster_id: String) -> Result<String, String> {
    // Ensure we have a valid token.
    let has_token = twitch_ensure_token()?;
    if !has_token {
        return Err("No Twitch account connected. Please authenticate first.".to_string());
    }

    let user_id = load_tw_setting(KEY_USER_ID)?
        .ok_or("Twitch user ID not found")?;

    let access_token = {
        let cache = get_token_cache().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        cache.as_ref().ok_or("Token cache empty")?.access_token.clone()
    };

    let username = load_tw_setting(KEY_TWITCH_USERNAME)?
        .unwrap_or_default();

    let rt = get_runtime();
    let proof = rt.block_on(twitch::generate_proof(&access_token, &user_id, &username, &broadcaster_id))?;
    serde_json::to_string(&proof).map_err(|e| format!("Failed to serialize proof: {e}"))
}

#[frb]
pub fn twitch_disconnect() -> Result<(), String> {
    save_tw_setting(KEY_REFRESH_TOKEN, "")?;
    save_tw_setting(KEY_USER_ID, "")?;
    save_tw_setting(KEY_TWITCH_USERNAME, "")?;

    let mut cache = get_token_cache().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    *cache = None;

    Ok(())
}

#[frb]
pub fn twitch_is_connected() -> Result<bool, String> {
    let user_id = load_tw_setting(KEY_USER_ID)?;
    Ok(user_id.is_some_and(|id| !id.is_empty()))
}

#[frb]
pub fn twitch_get_user_id() -> Result<Option<String>, String> {
    let user_id = load_tw_setting(KEY_USER_ID)?;
    Ok(user_id.filter(|id| !id.is_empty()))
}

#[frb]
pub fn twitch_get_username() -> Result<Option<String>, String> {
    let username = load_tw_setting(KEY_TWITCH_USERNAME)?;
    Ok(username.filter(|u| !u.is_empty()))
}
