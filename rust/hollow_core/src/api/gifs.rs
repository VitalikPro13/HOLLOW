//! GIF picker — search/trending/categories via the Hollow website's Klipy
//! proxy, and the pick-time fetch + transcode into an asset-rail blob.
//!
//! PRIVACY MODEL (mirrors `emotes.rs` / `showcase.rs`): the GIF catalog is
//! touched ONLY at authoring time, ONLY through OUR website's no-log proxy
//! (the website holds the single upstream identity and the Klipy key; users
//! never contact Klipy or its CDN). The moment a GIF is picked it is
//! re-encoded into a content-addressed Hollow WebP blob (≤480px, ≤2 MB) and
//! replicates purely P2P over the asset rail — receivers of a message never
//! make an HTTP request for any GIF, ever. `gif_fetch_and_store` accepts an
//! ID, never a URL, and builds the fetch URL from the configured proxy base
//! itself, so it is structurally incapable of acting as a generic fetcher.
//! Search-result media URLs are prefix-checked against the same base before
//! they reach Dart.

use std::sync::{Mutex, OnceLock};

use flutter_rust_bridge::frb;
use sha2::{Digest, Sha256};

use super::network::{get_http_runtime, get_runtime};
use super::storage::get_store;

/// Default base URL of the Hollow website's GIF proxy (keep in sync with
/// GIFS_BASE_URL in gifs/config.php — trailing slash included). Self-hosters
/// override it via [set_gif_proxy_url].
const DEFAULT_GIF_PROXY: &str = "https://hollow.anonlisten.com/gifs/";
/// Proxy response-schema version (keep in sync with SEARCH_VER in
/// gifs/search.php). The server currently ignores it — sent as a reserved
/// cache-buster, same as the FFZ/IGDB endpoints.
const GIF_SCHEMA_VER: &str = "2";

static GIF_PROXY_BASE: OnceLock<Mutex<Option<String>>> = OnceLock::new();

fn proxy_base_store() -> &'static Mutex<Option<String>> {
    GIF_PROXY_BASE.get_or_init(|| Mutex::new(None))
}

fn gif_proxy_base() -> String {
    proxy_base_store()
        .lock()
        .ok()
        .and_then(|g| g.clone())
        .unwrap_or_else(|| DEFAULT_GIF_PROXY.to_string())
}

/// Configure the GIF proxy base URL (None/empty = back to the default).
/// Persisted on the Dart side and pushed at startup, like `set_relay_url`.
#[frb]
pub fn set_gif_proxy_url(base: Option<String>) -> Result<(), String> {
    let normalized = match base {
        None => None,
        Some(raw) => {
            let trimmed = raw.trim().trim_end_matches('/');
            if trimmed.is_empty() {
                None
            } else if !trimmed.starts_with("https://") {
                return Err("GIF proxy URL must start with https://".into());
            } else {
                // Exactly one trailing slash: the media-URL guard and every
                // request are prefix checks on `{base}`, and a slashless base
                // would let "https://host/gifs-evil.example/…" through.
                Some(format!("{trimmed}/"))
            }
        }
    };
    let store = proxy_base_store();
    let mut guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    *guard = normalized;
    Ok(())
}

/// One GIF search/browse result. All URLs point at OUR proxy, never at the
/// upstream provider — rows with foreign URLs are dropped at parse time.
pub struct GifItem {
    pub id: String,
    pub w: u32,
    pub h: u32,
    pub title: String,
    /// First-frame still WebP (~150px) — the grid default.
    pub still_url: String,
    /// Small animated variant (~150px WebP or GIF) — hover/viewport preview.
    pub sm_url: String,
}

/// One page of the proxy's normalized search/trending response.
pub struct GifPage {
    pub items: Vec<GifItem>,
    pub page: u32,
    pub has_next: bool,
    /// Unix seconds until which the proxy's upstream is cooling down
    /// (0 = healthy). An empty page with a non-zero value means "retry
    /// later", not "no results".
    pub backoff_until: i64,
}

/// A picked GIF, transcoded and cached as a `kind='gif'` asset blob. Feed
/// hash/w/h into the `[a:g:hash:w:h]` wire token.
pub struct StoredGif {
    pub hash: String,
    pub w: u32,
    pub h: u32,
    pub animated: bool,
}

/// Klipy slug shape, mirroring the proxy's ingest validation.
fn valid_gif_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 100
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

fn parse_gif_page(v: &serde_json::Value, base: &str) -> Result<GifPage, String> {
    if v.get("result").and_then(|r| r.as_bool()) != Some(true) {
        let msg = v
            .get("error")
            .and_then(|e| e.as_str())
            .unwrap_or("unknown error");
        return Err(format!("GIF search failed: {msg}"));
    }
    let items = v
        .get("items")
        .and_then(|i| i.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|it| {
                    let id = it.get("id")?.as_str()?;
                    if !valid_gif_id(id) {
                        return None;
                    }
                    let w = it.get("w")?.as_u64()? as u32;
                    let h = it.get("h")?.as_u64()? as u32;
                    if w == 0 || h == 0 || w > 8192 || h > 8192 {
                        return None;
                    }
                    Some(GifItem {
                        id: id.to_string(),
                        w,
                        h,
                        title: it
                            .get("title")
                            .and_then(|t| t.as_str())
                            .unwrap_or_default()
                            .to_string(),
                        still_url: it
                            .get("still")
                            .and_then(|u| u.as_str())
                            .filter(|u| u.starts_with(base))?
                            .to_string(),
                        sm_url: it
                            .get("sm")
                            .and_then(|u| u.as_str())
                            .filter(|u| u.starts_with(base))?
                            .to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(GifPage {
        items,
        page: v.get("page").and_then(|p| p.as_u64()).unwrap_or(1) as u32,
        has_next: v.get("has_next").and_then(|b| b.as_bool()).unwrap_or(false),
        backoff_until: v
            .get("meta")
            .and_then(|m| m.get("backoff_until"))
            .and_then(|b| b.as_i64())
            .unwrap_or(0),
    })
}

fn gif_query(params: Vec<(&'static str, String)>) -> Result<serde_json::Value, String> {
    // Mode only — NEVER the query text (privacy: search text stays out of logs).
    let mode = params
        .first()
        .map(|(k, _)| *k)
        .unwrap_or("?");
    let t0 = std::time::Instant::now();
    crate::hollow_log!("[HOLLOW-GIF] query start mode={mode}");
    let rt = get_http_runtime();
    let result = rt.block_on(async move {
        let base = gif_proxy_base();
        let client = reqwest::Client::new();
        let resp = client
            .post(format!("{base}search.php"))
            .form(&params)
            .timeout(std::time::Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| format!("GIF search failed: {e}"))?;
        if resp.status().as_u16() == 429 {
            return Err("GIF search rate-limited — try again in a few minutes".into());
        }
        if !resp.status().is_success() {
            return Err(format!("GIF search failed: HTTP {}", resp.status()));
        }
        resp.json::<serde_json::Value>()
            .await
            .map_err(|e| format!("GIF search returned invalid JSON: {e}"))
    });
    match &result {
        Ok(_) => crate::hollow_log!(
            "[HOLLOW-GIF] query ok mode={mode} in {}ms",
            t0.elapsed().as_millis()
        ),
        Err(e) => crate::hollow_log!(
            "[HOLLOW-GIF] query FAILED mode={mode} in {}ms: {e}",
            t0.elapsed().as_millis()
        ),
    }
    result
}

fn gif_query_page(mut params: Vec<(&'static str, String)>) -> Result<GifPage, String> {
    params.push(("per_page", "30".to_string()));
    params.push(("v", GIF_SCHEMA_VER.to_string()));
    let v = gif_query(params)?;
    parse_gif_page(&v, &gif_proxy_base())
}

/// Search GIFs via the website's no-log proxy. Authoring only.
#[frb]
pub fn gif_search(query: String, page: u32) -> Result<GifPage, String> {
    let q = query.trim().to_string();
    if q.is_empty() || q.chars().count() > 64 {
        return Ok(GifPage { items: vec![], page: 1, has_next: false, backoff_until: 0 });
    }
    gif_query_page(vec![("q", q), ("page", page.max(1).to_string())])
}

/// Trending GIFs — the picker's default (empty-search) view.
#[frb]
pub fn gif_trending(page: u32) -> Result<GifPage, String> {
    gif_query_page(vec![
        ("trending", "1".to_string()),
        ("page", page.max(1).to_string()),
    ])
}

/// Category names for the browse chips (server-cached for 7 days).
#[frb]
pub fn gif_categories() -> Result<Vec<String>, String> {
    let v = gif_query(vec![
        ("categories", "1".to_string()),
        ("v", GIF_SCHEMA_VER.to_string()),
    ])?;
    if v.get("result").and_then(|r| r.as_bool()) != Some(true) {
        return Err("GIF categories failed".into());
    }
    Ok(v.get("categories")
        .and_then(|c| c.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|c| c.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.chars().take(64).collect())
                .collect()
        })
        .unwrap_or_default())
}

/// Download a picked GIF's full-quality source through the proxy, re-encode
/// it into the ≤480px/≤2MB send format, and cache it as a `kind='gif'` asset
/// blob. Takes an ID and builds the URL itself — never a caller-supplied URL.
#[frb]
pub fn gif_fetch_and_store(id: String) -> Result<StoredGif, String> {
    if !valid_gif_id(&id) {
        return Err("Invalid GIF id".into());
    }
    let t0 = std::time::Instant::now();
    let rt = get_http_runtime();
    let raw = rt.block_on(async move {
        let base = gif_proxy_base();
        let client = reqwest::Client::new();
        let resp = client
            .get(format!("{base}f/{id}"))
            // full.php walks hd→xs upstream with a 30s curl budget — give it
            // more room than the 20s used for search.
            .timeout(std::time::Duration::from_secs(45))
            .send()
            .await
            .map_err(|e| format!("GIF download failed: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("GIF download failed: HTTP {}", resp.status()));
        }
        let bytes = resp
            .bytes()
            .await
            .map_err(|e| format!("GIF download failed: {e}"))?;
        // The proxy caps the source at 25 MB — anything past that is not ours.
        if bytes.len() > 26_000_000 {
            return Err("GIF download too large".into());
        }
        Ok(bytes.to_vec())
    })?;
    let dl_ms = t0.elapsed().as_millis();
    let (webp, w, h, animated) = crate::node::image_convert::process_gif_for_send(&raw)
        .inspect_err(|e| {
            crate::hollow_log!("[HOLLOW-GIF] fetch transcode FAILED: {e}");
        })?;
    crate::hollow_log!(
        "[HOLLOW-GIF] fetch ok: {} raw -> {} webp {}x{} (dl {dl_ms}ms, total {}ms)",
        raw.len(),
        webp.len(),
        w,
        h,
        t0.elapsed().as_millis()
    );
    let hash = hex::encode(Sha256::digest(&webp));
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.save_asset_blob(&hash, &webp, animated, "gif")?;
    Ok(StoredGif { hash, w, h, animated })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gif_ids_validate_like_the_proxy() {
        assert!(valid_gif_id("abc_DEF-123"));
        assert!(!valid_gif_id(""));
        assert!(!valid_gif_id("has space"));
        assert!(!valid_gif_id("dot.dot"));
        assert!(!valid_gif_id(&"x".repeat(101)));
    }

    #[test]
    fn gif_rows_drop_foreign_urls_and_bad_ids() {
        let base = "https://hollow.anonlisten.com/gifs/";
        let v: serde_json::Value = serde_json::from_str(&format!(
            r#"{{"result":true,
                "items":[
                  {{"id":"ok_1","w":480,"h":270,"title":"a",
                    "still":"{base}m/ok_1.still.webp","sm":"{base}m/ok_1.sm.webp","full":"{base}f/ok_1"}},
                  {{"id":"evil","w":480,"h":270,"title":"b",
                    "still":"https://evil.example/x.webp","sm":"{base}m/evil.sm.webp","full":"{base}f/evil"}},
                  {{"id":"bad id!","w":480,"h":270,"title":"c",
                    "still":"{base}m/x.still.webp","sm":"{base}m/x.sm.webp","full":"{base}f/x"}}
                ],
                "page":2,"has_next":true,"meta":{{"backoff_until":123}}}}"#
        ))
        .unwrap();
        let page = parse_gif_page(&v, base).unwrap();
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].id, "ok_1");
        assert_eq!(page.page, 2);
        assert!(page.has_next);
        assert_eq!(page.backoff_until, 123);
    }

    #[test]
    fn gif_page_surfaces_proxy_errors() {
        let v: serde_json::Value =
            serde_json::from_str(r#"{"result":false,"error":"rate_limited"}"#).unwrap();
        let err = parse_gif_page(&v, "https://x/").err().expect("must fail");
        assert!(err.contains("rate_limited"));
    }

    /// Manual live smoke test against the deployed proxy (network):
    /// `cargo test --lib gifs -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn live_proxy_smoke() {
        let t0 = std::time::Instant::now();
        let trending = gif_trending(1).expect("trending");
        println!("trending: {} items in {:?}", trending.items.len(), t0.elapsed());
        let t1 = std::time::Instant::now();
        let search = gif_search("cat".into(), 1).expect("search");
        println!("search: {} items in {:?}", search.items.len(), t1.elapsed());
        let t2 = std::time::Instant::now();
        let cats = gif_categories().expect("categories");
        println!("categories: {} in {:?}", cats.len(), t2.elapsed());
        assert!(!trending.items.is_empty());
        assert!(!search.items.is_empty());
    }

    /// Manual (live network): GIF search must survive a fully-saturated NODE
    /// runtime blocking pool (max_blocking_threads = 8, like a SQLCipher
    /// burst in the live app). Before the dedicated `get_http_runtime` this
    /// stalled the full 20s timeout without the request ever being SENT —
    /// reqwest resolves DNS on its runtime's blocking pool. THE app bug of
    /// 2026-07-29 ("GIF search never loads").
    /// `cargo test --lib gifs::tests::live_saturated -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn live_saturated_blocking_pool_smoke() {
        let rt = get_runtime();
        for _ in 0..8 {
            rt.spawn(async {
                let _ = tokio::task::spawn_blocking(|| {
                    std::thread::sleep(std::time::Duration::from_secs(45));
                })
                .await;
            });
        }
        std::thread::sleep(std::time::Duration::from_millis(300));
        let t0 = std::time::Instant::now();
        let r = gif_trending(1);
        let elapsed = t0.elapsed();
        println!(
            "saturated-pool trending: {:?} in {elapsed:?}",
            r.as_ref().map(|p| p.items.len())
        );
        assert!(r.is_ok(), "search must not starve behind node DB work");
        assert!(elapsed.as_secs() < 10, "must complete fast, not at timeout");
    }

    #[test]
    fn proxy_base_normalizes_and_rejects_http() {
        // One test owns the global static (parallel tests would race it).
        set_gif_proxy_url(Some("https://example.com/gifs".into())).unwrap();
        assert_eq!(gif_proxy_base(), "https://example.com/gifs/");
        assert!(set_gif_proxy_url(Some("http://example.com/gifs/".into())).is_err());
        // A rejected set leaves the previous value in place.
        assert_eq!(gif_proxy_base(), "https://example.com/gifs/");
        set_gif_proxy_url(Some("  ".into())).unwrap();
        assert_eq!(gif_proxy_base(), DEFAULT_GIF_PROXY);
        set_gif_proxy_url(None).unwrap();
        assert_eq!(gif_proxy_base(), DEFAULT_GIF_PROXY);
    }
}
