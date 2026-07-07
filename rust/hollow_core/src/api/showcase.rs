//! Profile Showcase Board — IGDB game search + asset processing.
//!
//! PRIVACY MODEL: the website endpoint (which holds the single Twitch/IGDB
//! app credential and write-through-caches covers onto our CDN) is touched
//! ONLY at authoring time, by the profile OWNER. Everything a viewer sees is
//! replicated profile data — receivers never contact IGDB, the website, or
//! any third party. `showcase_fetch_cover` therefore refuses any URL that is
//! not on our own CDN, so it can never be abused as a generic fetcher.

use base64::Engine;
use flutter_rust_bridge::frb;
use sha2::{Digest, Sha256};

use super::network::get_runtime;
use super::storage::get_store;

/// Base URL of the Hollow website's cached IGDB endpoint.
const ENDPOINT_BASE: &str = "https://hollow.anonlisten.com/igdb";
/// Covers must come from here and nowhere else.
const COVER_BASE: &str = "https://hollow.anonlisten.com/igdb/covers/";
/// Endpoint response-schema version (keep in sync with SEARCH_VER in
/// search.php). Sent as a `v` query param — the endpoint ignores it, but it
/// changes the URL on every schema bump so CDN-cached responses from older
/// versions can never be served to a newer client.
const ENDPOINT_SCHEMA_VER: &str = "9";

/// One processed showcase image, content-addressed by its hash. The board
/// JSON references assets by [hash]; the bytes replicate in the profile's
/// asset bundle (full-profile pulls only, never the light announce).
pub struct ShowcaseAsset {
    pub hash: String,
    pub bytes: Vec<u8>,
}

/// One row of the FAST search response (?q=) — basics only. Card details
/// are fetched separately via [showcase_game_details] when the user actually
/// picks a game (one pick = one enrichment request; searching stays instant).
pub struct GameSearchResult {
    pub id: i64,
    pub name: String,
    pub year: Option<u32>,
    /// "Main Game" / "Mod" / "DLC" / "Update" / … (endpoint-mapped IGDB category).
    pub game_type: Option<String>,
    pub cover_url: Option<String>,
}

/// Card details for ONE picked game (?id= mode). [details_json] is the
/// endpoint's `details` object verbatim (description, requirements,
/// platforms, metacritic, release date, achievements, deduped dev/publisher
/// credits with logo URLs + social links, copyright, store links, key-art
/// URL) — baked into the block at authoring so a viewer fetches NOTHING.
/// [logo_urls]/[artwork_url] are surfaced (CDN-filtered) so the composer can
/// fetch + bundle the images and rewrite the baked JSON to asset hashes.
pub struct GameCardDetails {
    pub details_json: String,
    pub logo_urls: Vec<String>,
    pub artwork_url: Option<String>,
}

fn make_asset(bytes: Vec<u8>) -> ShowcaseAsset {
    let hash = hex::encode(Sha256::digest(&bytes));
    ShowcaseAsset { hash, bytes }
}

/// Search IGDB via the website's write-through cache. Authoring-time only.
#[frb]
pub fn showcase_game_search(query: String) -> Result<Vec<GameSearchResult>, String> {
    let q = query.trim().to_string();
    if q.is_empty() {
        return Ok(vec![]);
    }
    let rt = get_runtime();
    rt.block_on(async move {
        let client = reqwest::Client::new();
        let resp = client
            .get(format!("{ENDPOINT_BASE}/search.php"))
            .query(&[("q", q.as_str()), ("v", ENDPOINT_SCHEMA_VER)])
            .timeout(std::time::Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| format!("Game search failed: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("Game search failed: HTTP {}", resp.status()));
        }
        let items: Vec<serde_json::Value> = resp
            .json()
            .await
            .map_err(|e| format!("Game search returned invalid JSON: {e}"))?;
        Ok(items
            .iter()
            .filter_map(|v| {
                Some(GameSearchResult {
                    id: v.get("id")?.as_i64()?,
                    name: v.get("name")?.as_str()?.to_string(),
                    year: v.get("year").and_then(|y| y.as_u64()).map(|y| y as u32),
                    game_type: v
                        .get("type")
                        .and_then(|t| t.as_str())
                        .map(String::from),
                    cover_url: v
                        .get("cover")
                        .and_then(|c| c.as_str())
                        .filter(|c| c.starts_with(COVER_BASE))
                        .map(String::from),
                })
            })
            .collect())
    })
}

/// Fetch card details for ONE game (authoring-time, on pick). Returns None
/// when the endpoint has nothing for this game.
#[frb]
pub fn showcase_game_details(game_id: i64) -> Result<Option<GameCardDetails>, String> {
    if game_id <= 0 {
        return Ok(None);
    }
    let rt = get_runtime();
    rt.block_on(async move {
        let client = reqwest::Client::new();
        let resp = client
            .get(format!("{ENDPOINT_BASE}/search.php"))
            .query(&[
                ("id", game_id.to_string().as_str()),
                ("v", ENDPOINT_SCHEMA_VER),
            ])
            .timeout(std::time::Duration::from_secs(25))
            .send()
            .await
            .map_err(|e| format!("Game details failed: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("Game details failed: HTTP {}", resp.status()));
        }
        let body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| format!("Game details returned invalid JSON: {e}"))?;
        let Some(details) = body.get("details").filter(|d| d.is_object()) else {
            return Ok(None);
        };
        // Image URLs surfaced for the composer; any non-CDN URL is dropped
        // (this can never become a generic fetcher).
        let logo_urls: Vec<String> = details
            .get("companies")
            .and_then(|c| c.as_array())
            .map(|cos| {
                cos.iter()
                    .filter_map(|co| co.get("logo").and_then(|l| l.as_str()))
                    .filter(|u| u.starts_with(COVER_BASE))
                    .map(String::from)
                    .collect()
            })
            .unwrap_or_default();
        let artwork_url = details
            .get("artwork")
            .and_then(|a| a.as_str())
            .filter(|u| u.starts_with(COVER_BASE))
            .map(String::from);
        Ok(Some(GameCardDetails {
            details_json: serde_json::to_string(details)
                .map_err(|e| format!("Game details re-encode failed: {e}"))?,
            logo_urls,
            artwork_url,
        }))
    })
}

/// Download an image FROM OUR CDN (authoring-time only). The allowlist is the
/// privacy boundary — this can never be abused as a generic fetcher.
fn fetch_cdn_image(url: String) -> Result<Vec<u8>, String> {
    if !url.starts_with(COVER_BASE) {
        return Err("Image URL is not on the Hollow CDN".into());
    }
    let rt = get_runtime();
    rt.block_on(async move {
        let client = reqwest::Client::new();
        let resp = client
            .get(&url)
            .timeout(std::time::Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| format!("Image download failed: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("Image download failed: HTTP {}", resp.status()));
        }
        let bytes = resp
            .bytes()
            .await
            .map_err(|e| format!("Image download failed: {e}"))?;
        if bytes.len() > 2_000_000 {
            return Err("Image download too large".into());
        }
        Ok(bytes.to_vec())
    })
}

/// Download a game cover / company logo FROM OUR CDN (authoring-time only)
/// and process it into a content-addressed showcase asset (≤400px lossy
/// WebP — alpha survives, so transparent logos stay transparent).
#[frb]
pub fn showcase_fetch_cover(url: String) -> Result<ShowcaseAsset, String> {
    let raw = fetch_cdn_image(url)?;
    let processed = crate::node::image_convert::process_showcase_cover(&raw)?;
    Ok(make_asset(processed))
}

/// Download landscape key art FROM OUR CDN (authoring-time only). Processed
/// at the artwork budget (≤800px lossy WebP) — it's the card's hero image,
/// so the cover's 400px thumbnail cap would visibly blur it.
#[frb]
pub fn showcase_fetch_key_art(url: String) -> Result<ShowcaseAsset, String> {
    let raw = fetch_cdn_image(url)?;
    let processed = crate::node::image_convert::process_showcase_artwork(&raw)?;
    Ok(make_asset(processed))
}

/// Process user-picked artwork (image or GIF) into a showcase asset.
#[frb]
pub fn process_showcase_artwork(raw_bytes: Vec<u8>) -> Result<ShowcaseAsset, String> {
    let processed = crate::node::image_convert::process_showcase_artwork(&raw_bytes)?;
    Ok(make_asset(processed))
}

/// All showcase assets replicated for [peer_id]'s profile.
#[frb]
pub fn get_showcase_assets(peer_id: String) -> Result<Vec<ShowcaseAsset>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    let bundle = ms.load_showcase_assets(&peer_id)?;
    Ok(match bundle {
        Some(bytes) => decode_asset_bundle(&bytes)
            .into_iter()
            .map(|(hash, bytes)| ShowcaseAsset { hash, bytes })
            .collect(),
        None => vec![],
    })
}

// ── Bundle codec (JSON map hash → base64) ─────────────────────────────
// The bundle is opaque bytes to the replication layer; only authoring and
// display decode it. Tolerant decode: garbage → empty (a malicious bundle
// renders as nothing, never crashes).

pub(crate) fn encode_asset_bundle(assets: &[(String, Vec<u8>)]) -> Vec<u8> {
    let map: serde_json::Map<String, serde_json::Value> = assets
        .iter()
        .map(|(hash, bytes)| {
            (
                hash.clone(),
                serde_json::Value::String(
                    base64::engine::general_purpose::STANDARD.encode(bytes),
                ),
            )
        })
        .collect();
    serde_json::to_vec(&map).unwrap_or_default()
}

pub(crate) fn decode_asset_bundle(data: &[u8]) -> Vec<(String, Vec<u8>)> {
    let Ok(map) = serde_json::from_slice::<serde_json::Map<String, serde_json::Value>>(data)
    else {
        return vec![];
    };
    map.into_iter()
        .filter_map(|(hash, v)| {
            let b64 = v.as_str()?;
            let bytes = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
            // Content-addressing is the integrity check: a hash that doesn't
            // match its bytes is dropped.
            if hex::encode(Sha256::digest(&bytes)) != hash {
                return None;
            }
            Some((hash, bytes))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundle_roundtrip_and_integrity() {
        let a = make_asset(vec![1, 2, 3]);
        let b = make_asset(vec![9, 9, 9, 9]);
        let encoded = encode_asset_bundle(&[
            (a.hash.clone(), a.bytes.clone()),
            (b.hash.clone(), b.bytes.clone()),
        ]);
        let decoded = decode_asset_bundle(&encoded);
        assert_eq!(decoded.len(), 2);
        assert!(decoded.iter().any(|(h, by)| *h == a.hash && *by == a.bytes));

        // Tampered bytes under a stale hash are dropped.
        let tampered = encode_asset_bundle(&[(a.hash.clone(), vec![7, 7, 7])]);
        assert!(decode_asset_bundle(&tampered).is_empty());
        // Garbage decodes to empty, never errors.
        assert!(decode_asset_bundle(b"not json").is_empty());
    }
}
