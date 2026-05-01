use serde::{Deserialize, Serialize};
use crate::crdt::server_state::ServerState;

pub(crate) const TWITCH_CLIENT_ID: &str = "z3piofwp5qr458qfn0ncn6a501ua05";

const DEVICE_CODE_URL: &str = "https://id.twitch.tv/oauth2/device";
const TOKEN_URL: &str = "https://id.twitch.tv/oauth2/token";
const VALIDATE_URL: &str = "https://id.twitch.tv/oauth2/validate";
const HELIX_BASE: &str = "https://api.twitch.tv/helix";

// ── Twitch API response types ───────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct TwitchDeviceCodeResponse {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub expires_in: u64,
    pub interval: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct TwitchTokenResponse {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_in: u64,
    #[serde(default)]
    pub token_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct TwitchValidateResponse {
    pub client_id: String,
    pub login: String,
    pub user_id: String,
    pub expires_in: u64,
}

// ── Twitch proof (attached to join requests) ────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct TwitchProof {
    pub twitch_user_id: String,
    #[serde(default)]
    pub twitch_username: String,
    pub followed_at: Option<String>,
    pub is_subscribed: bool,
    #[serde(default)]
    pub sub_tier: Option<String>,
    pub timestamp: i64,
}

// ── Server-side Twitch settings (read from CRDT) ───────────────────

pub(crate) struct TwitchServerSettings {
    pub channel_id: String,
    pub channel_name: String,
    pub min_follow_days: u32,
    pub require_sub: bool,
    pub owner_verify: bool,
}

impl TwitchServerSettings {
    pub fn from_server_state(state: &ServerState) -> Option<Self> {
        let enabled = state.settings.get("twitch_verification_enabled")
            .map(|reg| reg.read().clone())
            .unwrap_or_default();
        if enabled != "true" {
            return None;
        }

        let channel_id = state.settings.get("twitch_channel_id")
            .map(|reg| reg.read().clone())
            .unwrap_or_default();
        if channel_id.is_empty() {
            return None;
        }

        let channel_name = state.settings.get("twitch_channel_name")
            .map(|reg| reg.read().clone())
            .unwrap_or_default();

        let min_follow_days = state.settings.get("twitch_min_follow_days")
            .and_then(|reg| reg.read().parse::<u32>().ok())
            .unwrap_or(0);

        let require_sub = state.settings.get("twitch_require_sub")
            .map(|reg| reg.read() == "true")
            .unwrap_or(false);

        let owner_verify = state.settings.get("twitch_owner_verify")
            .map(|reg| reg.read() == "true")
            .unwrap_or(false);

        Some(Self { channel_id, channel_name, min_follow_days, require_sub, owner_verify })
    }
}

// ── Device Code Grant flow ──────────────────────────────────────────

pub(crate) async fn start_device_flow() -> Result<TwitchDeviceCodeResponse, String> {
    let client = reqwest::Client::new();
    let resp = client
        .post(DEVICE_CODE_URL)
        .form(&[
            ("client_id", TWITCH_CLIENT_ID),
            ("scopes", "user:read:follows user:read:subscriptions"),
        ])
        .send()
        .await
        .map_err(|e| format!("Twitch device flow request failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("Twitch device flow failed ({status}): {body}"));
    }

    resp.json::<TwitchDeviceCodeResponse>()
        .await
        .map_err(|e| format!("Failed to parse device code response: {e}"))
}

pub(crate) async fn poll_for_token(
    device_code: &str,
    interval_secs: u64,
) -> Result<TwitchTokenResponse, String> {
    let client = reqwest::Client::new();
    let mut interval = std::cmp::max(interval_secs, 5);

    loop {
        tokio::time::sleep(std::time::Duration::from_secs(interval)).await;

        let resp = client
            .post(TOKEN_URL)
            .form(&[
                ("client_id", TWITCH_CLIENT_ID),
                ("device_code", device_code),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ])
            .send()
            .await
            .map_err(|e| format!("Twitch token poll failed: {e}"))?;

        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();

        if status.is_success() {
            let token: TwitchTokenResponse = serde_json::from_str(&body)
                .map_err(|e| format!("Failed to parse token response: {e}"))?;
            return Ok(token);
        }

        // Parse error response to decide whether to keep polling.
        #[derive(Deserialize)]
        struct ErrorResp {
            #[serde(default)]
            message: String,
        }
        let err: ErrorResp = serde_json::from_str(&body).unwrap_or(ErrorResp {
            message: body.clone(),
        });

        if err.message.contains("authorization_pending") {
            continue;
        } else if err.message.contains("slow_down") {
            interval += 5;
            continue;
        } else {
            return Err(format!("Twitch auth failed: {}", err.message));
        }
    }
}

// ── Token management ────────────────────────────────────────────────

pub(crate) async fn refresh_access_token(
    refresh_token: &str,
) -> Result<TwitchTokenResponse, String> {
    let client = reqwest::Client::new();
    let resp = client
        .post(TOKEN_URL)
        .form(&[
            ("client_id", TWITCH_CLIENT_ID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token),
        ])
        .send()
        .await
        .map_err(|e| format!("Twitch token refresh failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("Twitch token refresh failed ({status}): {body}"));
    }

    resp.json::<TwitchTokenResponse>()
        .await
        .map_err(|e| format!("Failed to parse refresh response: {e}"))
}

pub(crate) async fn validate_token(
    access_token: &str,
) -> Result<TwitchValidateResponse, String> {
    let client = reqwest::Client::new();
    let resp = client
        .get(VALIDATE_URL)
        .header("Authorization", format!("OAuth {access_token}"))
        .send()
        .await
        .map_err(|e| format!("Twitch token validation failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("Twitch token invalid ({status}): {body}"));
    }

    resp.json::<TwitchValidateResponse>()
        .await
        .map_err(|e| format!("Failed to parse validate response: {e}"))
}

// ── Helix API checks ───────────────────────────────────────────────

pub(crate) async fn check_follow(
    access_token: &str,
    user_id: &str,
    broadcaster_id: &str,
) -> Result<Option<String>, String> {
    let client = reqwest::Client::new();
    let url = format!(
        "{HELIX_BASE}/channels/followed?user_id={user_id}&broadcaster_id={broadcaster_id}"
    );
    let resp = client
        .get(&url)
        .header("Client-Id", TWITCH_CLIENT_ID)
        .header("Authorization", format!("Bearer {access_token}"))
        .send()
        .await
        .map_err(|e| format!("Twitch follow check failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("Twitch follow check failed ({status}): {body}"));
    }

    #[derive(Deserialize)]
    struct FollowData {
        #[serde(default)]
        followed_at: String,
    }
    #[derive(Deserialize)]
    struct FollowResp {
        data: Vec<FollowData>,
    }

    let follow_resp: FollowResp = resp.json().await
        .map_err(|e| format!("Failed to parse follow response: {e}"))?;

    Ok(follow_resp.data.first().map(|d| d.followed_at.clone()))
}

pub(crate) async fn check_subscription(
    access_token: &str,
    user_id: &str,
    broadcaster_id: &str,
) -> Result<(bool, Option<String>), String> {
    let client = reqwest::Client::new();
    let url = format!(
        "{HELIX_BASE}/subscriptions/user?broadcaster_id={broadcaster_id}&user_id={user_id}"
    );
    let resp = client
        .get(&url)
        .header("Client-Id", TWITCH_CLIENT_ID)
        .header("Authorization", format!("Bearer {access_token}"))
        .send()
        .await
        .map_err(|e| format!("Twitch subscription check failed: {e}"))?;

    let status = resp.status();

    // 404 = not subscribed (normal)
    if status == reqwest::StatusCode::NOT_FOUND {
        return Ok((false, None));
    }

    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("Twitch subscription check failed ({status}): {body}"));
    }

    #[derive(Deserialize)]
    struct SubData {
        #[serde(default)]
        tier: String,
    }
    #[derive(Deserialize)]
    struct SubResp {
        data: Vec<SubData>,
    }

    let sub_resp: SubResp = resp.json().await
        .map_err(|e| format!("Failed to parse subscription response: {e}"))?;

    match sub_resp.data.first() {
        Some(sub) => Ok((true, Some(sub.tier.clone()))),
        None => Ok((false, None)),
    }
}

// ── Proof generation (joiner-side) ─────────────────────────────────

pub(crate) async fn generate_proof(
    access_token: &str,
    twitch_user_id: &str,
    twitch_username: &str,
    broadcaster_id: &str,
) -> Result<TwitchProof, String> {
    let followed_at = check_follow(access_token, twitch_user_id, broadcaster_id).await?;
    let (is_subscribed, sub_tier) = check_subscription(access_token, twitch_user_id, broadcaster_id).await?;

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    Ok(TwitchProof {
        twitch_user_id: twitch_user_id.to_string(),
        twitch_username: twitch_username.to_string(),
        followed_at,
        is_subscribed,
        sub_tier,
        timestamp: now,
    })
}

// ── Proof validation (server-side, sync — no network calls) ────────

pub(crate) fn validate_proof(
    proof: &TwitchProof,
    settings: &TwitchServerSettings,
) -> Result<(), String> {
    if proof.twitch_user_id.is_empty() {
        return Err("Missing Twitch user ID in proof".to_string());
    }

    // Check proof freshness (reject proofs older than 5 minutes).
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    let age_secs = now - proof.timestamp;
    if age_secs > 300 || age_secs < -60 {
        return Err("Twitch proof expired (older than 5 minutes)".to_string());
    }

    // Check follow requirement.
    match &proof.followed_at {
        None => {
            return Err(format!(
                "You must follow {} to join this server",
                settings.channel_name
            ));
        }
        Some(followed_at) => {
            if settings.min_follow_days > 0 {
                let follow_days = parse_follow_age_days(followed_at);
                if follow_days < settings.min_follow_days {
                    return Err(format!(
                        "You must follow {} for at least {} days (currently {} days)",
                        settings.channel_name, settings.min_follow_days, follow_days
                    ));
                }
            }
        }
    }

    // Check subscription requirement.
    if settings.require_sub && !proof.is_subscribed {
        return Err(format!(
            "You must be subscribed to {} to join this server",
            settings.channel_name
        ));
    }

    Ok(())
}

fn parse_follow_age_days(followed_at: &str) -> u32 {
    // Twitch returns ISO 8601: "2023-01-15T12:34:56Z"
    // Parse manually to avoid adding chrono dependency.
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    let follow_epoch = parse_iso8601_to_epoch(followed_at).unwrap_or(now);
    let diff = now.saturating_sub(follow_epoch);
    (diff / 86400) as u32
}

fn parse_iso8601_to_epoch(s: &str) -> Option<u64> {
    // Minimal ISO 8601 parser for "YYYY-MM-DDTHH:MM:SSZ"
    let s = s.trim_end_matches('Z');
    let (date, time) = s.split_once('T')?;
    let parts: Vec<&str> = date.split('-').collect();
    if parts.len() != 3 { return None; }
    let year: u64 = parts[0].parse().ok()?;
    let month: u64 = parts[1].parse().ok()?;
    let day: u64 = parts[2].parse().ok()?;

    let time_parts: Vec<&str> = time.split(':').collect();
    if time_parts.len() != 3 { return None; }
    let hour: u64 = time_parts[0].parse().ok()?;
    let min: u64 = time_parts[1].parse().ok()?;
    let sec: u64 = time_parts[2].parse().ok()?;

    // Days from epoch (1970-01-01) using a simple algorithm.
    let mut total_days: u64 = 0;
    for y in 1970..year {
        total_days += if is_leap(y) { 366 } else { 365 };
    }
    let days_in_month = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    for m in 1..month {
        total_days += days_in_month[m as usize] as u64;
        if m == 2 && is_leap(year) {
            total_days += 1;
        }
    }
    total_days += day - 1;

    Some(total_days * 86400 + hour * 3600 + min * 60 + sec)
}

fn is_leap(year: u64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}
