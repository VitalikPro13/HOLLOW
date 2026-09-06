use std::sync::{Mutex, OnceLock};

use flutter_rust_bridge::frb;

use super::network::get_runtime;
use super::shop::{self, TwitchVerifier};
use super::storage::get_store;
use crate::hollow_log;
use crate::node::support_creds;
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

/// What [`twitch_verify_owner`] came back with.
///
/// Not a `Result`: a refusal from the shop is an ANSWER, and the caller shows its
/// sentence rather than treating it as a crash. `Err` is kept for the things that
/// stop the call happening at all, like no connected account.
pub struct TwitchVerifyOutcome {
    /// The credential is minted, kept and announced.
    pub verified: bool,
    /// The login the purple chip will draw. Empty unless `verified`.
    pub login: String,
    /// What to tell the user when it is not verified. Empty on success.
    pub message: String,
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

    let validate = rt.block_on(twitch::validate_token(&token_resp.access_token))?;

    save_tw_setting(KEY_REFRESH_TOKEN, &token_resp.refresh_token)?;
    save_tw_setting(KEY_USER_ID, &validate.user_id)?;
    save_tw_setting(KEY_TWITCH_USERNAME, &validate.login)?;

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

    {
        let cache = get_token_cache().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        if let Some(ref cached) = *cache {
            if now < cached.expires_at {
                let since_validated = now.duration_since(cached.last_validated);
                if since_validated < std::time::Duration::from_secs(3600) {
                    return Ok(true);
                }
                // Need hourly validation — fall through.
            }
        }
    }

    let refresh_token = load_tw_setting(KEY_REFRESH_TOKEN)?;
    let refresh_token = match refresh_token {
        Some(t) if !t.is_empty() => t,
        _ => return Ok(false),
    };

    let rt = get_runtime();
    let token_resp = match rt.block_on(twitch::refresh_access_token(&refresh_token)) {
        Ok(resp) => resp,
        Err(_) => {
            let _ = save_tw_setting(KEY_REFRESH_TOKEN, "");
            return Ok(false);
        }
    };

    // Twitch refresh tokens are one-time use, so the old one is already invalid.
    save_tw_setting(KEY_REFRESH_TOKEN, &token_resp.refresh_token)?;

    let validate = rt.block_on(twitch::validate_token(&token_resp.access_token));
    let validated_now = validate.is_ok();
    if let Ok(ref v) = validate {
        let _ = save_tw_setting(KEY_TWITCH_USERNAME, &v.login);
    }

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
    // The chip goes with the connection, and FIRST: the credential outlives the token
    // by design, so wiping the token alone would leave a verified chip on the profile
    // of somebody who just disconnected.
    match shop::forget_twitch_owner_creds() {
        Ok(Some((master, json))) => {
            let _ = shop::announce_support_creds(&master, json);
        }
        Ok(None) => {}
        Err(e) => {
            hollow_log!("[HOLLOW-TWITCH] Could not drop the account credential on disconnect: {e}");
            return Err(format!("Could not remove the verified Twitch mark: {e}"));
        }
    }

    save_tw_setting(KEY_REFRESH_TOKEN, "")?;
    save_tw_setting(KEY_USER_ID, "")?;
    save_tw_setting(KEY_TWITCH_USERNAME, "")?;

    let mut cache = get_token_cache().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    *cache = None;

    Ok(())
}

// ── Verified Twitch credentials ─────────────────────────────────────
//
// The token never leaves this machine for anyone but the shop's verifier, which reads
// it, asks Twitch and blind-signs what Twitch said. What comes back binds OUR master
// peer id and nothing else, so the shop cannot tell which identity it vouched for.

/// A fresh access token, or the sentence to show instead.
fn access_token() -> Result<String, String> {
    if !twitch_ensure_token()? {
        return Err("Connect Twitch first".to_string());
    }
    let cache = get_token_cache().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    cache
        .as_ref()
        .map(|c| c.access_token.clone())
        .ok_or_else(|| "Connect Twitch first".to_string())
}

fn verifier() -> TwitchVerifier<'static> {
    TwitchVerifier::http(shop::shop_origin())
}

/// Verify the connected Twitch account and wear the credential.
///
/// What the Connect flow ends with and what the chip draws from. The credential is
/// kept and announced in one profile save; nothing else on the profile changes.
#[frb]
pub fn twitch_verify_owner() -> Result<TwitchVerifyOutcome, String> {
    let master = super::network::get_local_peer_id()
        .ok_or("Hollow is still starting; try again in a moment")?;
    let token = access_token()?;
    match shop::verify_twitch_owner_with(&verifier(), &token, &master) {
        Ok((login, json)) => {
            shop::announce_support_creds(&master, json)?;
            Ok(TwitchVerifyOutcome { verified: true, login, message: String::new() })
        }
        Err(message) => Ok(TwitchVerifyOutcome {
            verified: false,
            login: String::new(),
            message,
        }),
    }
}

/// Verify that we follow `broadcaster_id`, and answer the credential as JSON.
///
/// This rides a join request to a Twitch-gated server and never touches the profile: a
/// follow credential names a channel somebody watches, which is theirs to hand to
/// that channel's server and to nobody else.
#[frb]
pub fn twitch_verify_follow(broadcaster_id: String) -> Result<String, String> {
    let bid = broadcaster_id.trim().to_string();
    if !support_creds::valid_twitch_id(&bid) {
        return Err("That server does not name a Twitch channel".to_string());
    }
    let master = super::network::get_local_peer_id()
        .ok_or("Hollow is still starting; try again in a moment")?;
    let token = access_token()?;
    let entry = shop::mint_twitch_credential(&verifier(), "follow", &token, Some(&bid), &master)?;
    serde_json::to_string(&entry).map_err(|e| format!("Could not read the credential: {e}"))
}

/// When this device last tried to refresh the account credential.
static LAST_MAINTAIN: OnceLock<Mutex<Option<std::time::Instant>>> = OnceLock::new();

/// Keep the account credential fresh, silently.
///
/// A credential is minted for a 90-day window and verifies for that window and the
/// next, so there is a whole window in which to renew it from the persisted refresh
/// token without asking the user. Called at start-up, with a cooldown so a
/// long-running app asks the shop at most once a day.
///
/// Answers whether a fresh credential was minted; every refusal is `false`, never an
/// error the user sees.
#[frb]
pub fn twitch_maintain_owner_credential() -> Result<bool, String> {
    {
        let mut last = LAST_MAINTAIN
            .get_or_init(|| Mutex::new(None))
            .lock()
            .map_err(|e| format!("Lock poisoned: {e}"))?;
        let now = std::time::Instant::now();
        if let Some(at) = *last {
            if now.duration_since(at) < std::time::Duration::from_secs(86_400) {
                return Ok(false);
            }
        }
        *last = Some(now);
    }
    if !twitch_is_connected().unwrap_or(false) {
        return Ok(false);
    }
    // Already minted in the window we are standing in. An absent credential is a build
    // that connected Twitch before credentials existed, and it wants one.
    if let Some(entry) = shop::own_twitch_owner_entry() {
        if entry.period == support_creds::now_period() {
            return Ok(false);
        }
    }
    match twitch_verify_owner() {
        Ok(outcome) => {
            if !outcome.verified {
                hollow_log!("[HOLLOW-TWITCH] Silent re-verify did not land: {}", outcome.message);
            }
            Ok(outcome.verified)
        }
        Err(e) => {
            hollow_log!("[HOLLOW-TWITCH] Silent re-verify skipped: {e}");
            Ok(false)
        }
    }
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
