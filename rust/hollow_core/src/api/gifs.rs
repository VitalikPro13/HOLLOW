//! The Klipy catalog client — search/trending/categories, plus the pick-time
//! fetch and transcode into an asset-rail blob.
//!
//! It serves TWO media kinds off one code path ([MediaKind]): GIFs, and the
//! stickers `api/stickers.rs` exposes to Dart. They differ only in the
//! upstream path segment, the id namespace, and which transcoder the pick
//! runs through — everything below (the two modes, the URL guards, the
//! allowlist, the rating handling) is shared, so a fix to one is a fix to
//! both. The normalized [GifItem] / [GifPage] / [StoredGif] shapes carry
//! both kinds; they keep their GIF-era names because renaming them would
//! churn every shipped call site for a cosmetic gain.
//!
//! TWO MODES, one contract. The app codes to the normalized [GifPage] shape
//! either way:
//!
//!   * PROXY (default) — everything goes through the Hollow website's no-log
//!     Klipy proxy. The website holds the single upstream identity and the
//!     Klipy key; users never contact Klipy or its CDN. Self-hosters point
//!     [set_gif_proxy_url] at their own copy of `gifs/`.
//!   * DIRECT — the user pastes their OWN Klipy key ([set_gif_api_key]) and
//!     the client talks to api.klipy.com itself. This is NOT a privacy
//!     upgrade and must never be sold as one: Klipy then sees the user's IP
//!     and every search under one stable key. It exists because a user's own
//!     key is a user's own rate limit, and because it removes any dependency
//!     on our server without needing to host PHP.
//!
//! PRIVACY MODEL (mirrors `emotes.rs` / `showcase.rs`): the GIF catalog is
//! touched ONLY at authoring time. The moment a GIF is picked it is
//! re-encoded into a content-addressed Hollow WebP blob (≤480px, ≤2 MB) and
//! replicates purely P2P over the asset rail — receivers of a message never
//! make an HTTP request for any GIF, ever, in EITHER mode.
//!
//! FETCHER DISCIPLINE, per mode:
//!   * PROXY — `gif_fetch_and_store` builds `{base}f/{id}` itself and ignores
//!     any caller-supplied URL outright. Structurally incapable of acting as
//!     a generic fetcher; media URLs handed to Dart are prefix-checked
//!     against the configured base.
//!   * DIRECT — the id resolves through a registry populated by OUR OWN parse
//!     of a response we requested. Only when that registry cannot help (a
//!     favourite saved in an earlier session, whose variants are long evicted)
//!     does the caller's remembered source URL apply, and then only if its
//!     host is on the user's media allowlist. That allowlist IS the guard
//!     here: every URL comes from Klipy's opaque CDN, so provenance cannot be
//!     re-derived from the URL, only constrained.

use std::collections::{BTreeSet, HashMap, VecDeque};
use std::sync::{Mutex, OnceLock};

use flutter_rust_bridge::frb;
use sha2::{Digest, Sha256};

use super::network::get_http_runtime;
use super::storage::get_store;

/// Default base URL of the Hollow website's GIF proxy (keep in sync with
/// GIFS_BASE_URL in gifs/config.php — trailing slash included). Self-hosters
/// override it via [set_gif_proxy_url].
const DEFAULT_GIF_PROXY: &str = "https://hollow.anonlisten.com/gifs/";
/// Proxy response-schema version (keep in sync with SEARCH_VER in
/// gifs/search.php). The server currently ignores it — sent as a reserved
/// cache-buster, same as the FFZ/IGDB endpoints.
const GIF_SCHEMA_VER: &str = "2";
/// Klipy API root for DIRECT mode. The key is a PATH segment (which is
/// exactly why a bundled key would be extractable, and why proxy mode keeps
/// it server-side).
const KLIPY_API_ROOT: &str = "https://api.klipy.com/api/v1/";
/// Media hosts direct mode may fetch grid images from. Suffix-matched, so
/// this one entry covers api./static./static2.klipy.com. Editable in
/// Settings: if Klipy moves its CDN, users fix it without an app release
/// (the picker surfaces every blocked host it saw — see
/// [gif_blocked_media_hosts]).
const DEFAULT_MEDIA_HOSTS: [&str; 1] = ["klipy.com"];
/// Content ratings Klipy accepts, mildest first.
const RATINGS: [&str; 4] = ["g", "pg", "pg-13", "r"];
/// Shipped default. NOTE this is the APP's default, deliberately one step
/// above gifs/search.php's own `DEFAULT_RATING` ('pg'): the PHP value only
/// applies to a request that sends no rating at all — i.e. a client older
/// than this feature — and quietly loosening what THEY receive would be a
/// change nobody opted into.
const DEFAULT_RATING: &str = "pg-13";
/// Grid variant preference (smallest usable first) — mirrors SIZE_SLOTS in
/// gifs/search.php.
const SIZE_SLOTS: [&str; 4] = ["sm", "xs", "md", "hd"];
/// Still-thumbnail preference. Klipy has no "still" format, but its jpg
/// variant IS a static frame, which keeps direct mode on the same
/// stills-in-the-grid bandwidth model the proxy gets from fetch.php.
const STILL_SLOTS: [&str; 4] = ["xs", "sm", "md", "hd"];
/// Pick-time variant preference (best first) — mirrors SLOT_ORDER in
/// gifs/full.php. The app scales down to ≤480px, so ask for the richest
/// source and walk down on failure.
const FULL_SLOTS: [&str; 4] = ["hd", "md", "sm", "xs"];
/// Upstream bytes we will accept for one pick (matches the proxy's cap).
const MAX_PICK_BYTES: usize = 26_000_000;
/// Direct-mode id→variants registry bound. A picker session browses a few
/// hundred items; past this the oldest are evicted.
const MAX_DIRECT_REGISTRY: usize = 600;
/// Blocked-host hints kept for the settings UI.
const MAX_BLOCKED_HOSTS: usize = 8;

static GIF_PROXY_BASE: OnceLock<Mutex<Option<String>>> = OnceLock::new();
static GIF_API_KEY: OnceLock<Mutex<Option<String>>> = OnceLock::new();
static GIF_MEDIA_HOSTS: OnceLock<Mutex<Vec<String>>> = OnceLock::new();
static GIF_BLOCKED_HOSTS: OnceLock<Mutex<BTreeSet<String>>> = OnceLock::new();
static GIF_DIRECT_SRC: OnceLock<Mutex<DirectRegistry>> = OnceLock::new();

fn proxy_base_store() -> &'static Mutex<Option<String>> {
    GIF_PROXY_BASE.get_or_init(|| Mutex::new(None))
}

fn api_key_store() -> &'static Mutex<Option<String>> {
    GIF_API_KEY.get_or_init(|| Mutex::new(None))
}

fn media_hosts_store() -> &'static Mutex<Vec<String>> {
    GIF_MEDIA_HOSTS.get_or_init(|| {
        Mutex::new(DEFAULT_MEDIA_HOSTS.iter().map(|h| h.to_string()).collect())
    })
}

fn blocked_hosts_store() -> &'static Mutex<BTreeSet<String>> {
    GIF_BLOCKED_HOSTS.get_or_init(|| Mutex::new(BTreeSet::new()))
}

fn direct_src_store() -> &'static Mutex<DirectRegistry> {
    GIF_DIRECT_SRC.get_or_init(|| Mutex::new(DirectRegistry::default()))
}

fn gif_proxy_base() -> String {
    proxy_base_store()
        .lock()
        .ok()
        .and_then(|g| g.clone())
        .unwrap_or_else(|| DEFAULT_GIF_PROXY.to_string())
}

fn gif_api_key() -> Option<String> {
    api_key_store().lock().ok().and_then(|g| g.clone())
}

fn media_hosts() -> Vec<String> {
    media_hosts_store()
        .lock()
        .map(|g| g.clone())
        .unwrap_or_else(|_| DEFAULT_MEDIA_HOSTS.iter().map(|h| h.to_string()).collect())
}

/// Upstream variant blobs for ids OUR OWN parse handed out, so pick-time can
/// resolve an id to a URL without Dart ever supplying one. Bounded FIFO.
///
/// `frb(ignore)`: private module state. Without it the derived `Default`
/// makes the bridge generate an opaque Dart class for it.
#[frb(ignore)]
#[derive(Default)]
struct DirectRegistry {
    map: HashMap<String, serde_json::Value>,
    order: VecDeque<String>,
}

impl DirectRegistry {
    fn insert(&mut self, id: &str, file: serde_json::Value) {
        if self.map.insert(id.to_string(), file).is_none() {
            self.order.push_back(id.to_string());
            while self.order.len() > MAX_DIRECT_REGISTRY {
                if let Some(old) = self.order.pop_front() {
                    self.map.remove(&old);
                }
            }
        }
    }

    fn get(&self, id: &str) -> Option<serde_json::Value> {
        self.map.get(id).cloned()
    }

    fn clear(&mut self) {
        self.map.clear();
        self.order.clear();
    }
}

/// Drop every cached upstream variant. Called whenever the mode or the media
/// allowlist changes — a stale entry could point at a host we no longer
/// allow.
fn clear_direct_registry() {
    if let Ok(mut reg) = direct_src_store().lock() {
        reg.clear();
    }
}

// ─── Settings FFI ───────────────────────────────────────────────────────────

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
    drop(guard);
    clear_direct_registry();
    Ok(())
}

/// A Klipy key rides in the URL PATH, so it must not be able to break out of
/// its segment or smuggle query state. Printable ASCII minus the delimiters.
fn valid_api_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 200
        && key
            .bytes()
            .all(|b| b.is_ascii_graphic() && !matches!(b, b'/' | b'?' | b'#' | b'%' | b'&' | b'\\'))
}

/// Set (or clear, with None/empty) the user's own Klipy API key. A key
/// present IS direct mode — one piece of state, so there is no "enabled but
/// no key" way to be broken.
#[frb]
pub fn set_gif_api_key(key: Option<String>) -> Result<(), String> {
    let normalized = match key {
        None => None,
        Some(raw) => {
            let trimmed = raw.trim().to_string();
            if trimmed.is_empty() {
                None
            } else if !valid_api_key(&trimmed) {
                return Err("That does not look like a Klipy API key".into());
            } else {
                Some(trimmed)
            }
        }
    };
    let store = api_key_store();
    let mut guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    *guard = normalized;
    drop(guard);
    // Mode change: registry entries and blocked-host hints belong to the old
    // mode.
    clear_direct_registry();
    if let Ok(mut blocked) = blocked_hosts_store().lock() {
        blocked.clear();
    }
    Ok(())
}

/// True while a user-supplied Klipy key is active (direct mode).
#[frb]
pub fn gif_direct_mode() -> bool {
    gif_api_key().is_some()
}

fn valid_media_host(host: &str) -> bool {
    !host.is_empty()
        && host.len() <= 253
        && host.contains('.')
        && !host.starts_with('.')
        && !host.ends_with('.')
        && !host.starts_with('-')
        && !host.ends_with('-')
        && host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
}

/// Replace the direct-mode media host allowlist (empty = back to defaults).
/// Entries are suffix-matched: "klipy.com" allows "static2.klipy.com".
#[frb]
pub fn set_gif_media_hosts(hosts: Vec<String>) -> Result<(), String> {
    let mut cleaned: Vec<String> = Vec::new();
    for raw in hosts {
        let h = raw.trim().trim_start_matches('.').to_ascii_lowercase();
        if h.is_empty() {
            continue;
        }
        if !valid_media_host(&h) {
            return Err(format!("Not a valid host name: {h}"));
        }
        if !cleaned.contains(&h) {
            cleaned.push(h);
        }
    }
    if cleaned.len() > 16 {
        return Err("Too many media hosts (16 max)".into());
    }
    if cleaned.is_empty() {
        cleaned = DEFAULT_MEDIA_HOSTS.iter().map(|h| h.to_string()).collect();
    }
    let store = media_hosts_store();
    let mut guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    *guard = cleaned;
    drop(guard);
    clear_direct_registry();
    if let Ok(mut blocked) = blocked_hosts_store().lock() {
        blocked.clear();
    }
    Ok(())
}

/// The shipped default allowlist — Dart reads it rather than mirroring it
/// (same rule as `default_role_permissions`).
#[frb]
pub fn default_gif_media_hosts() -> Vec<String> {
    DEFAULT_MEDIA_HOSTS.iter().map(|h| h.to_string()).collect()
}

/// Hosts whose media we refused since the last settings change. Surfaced in
/// Settings so a CDN move is a two-tap fix instead of a mystery empty grid.
#[frb]
pub fn gif_blocked_media_hosts() -> Vec<String> {
    blocked_hosts_store()
        .lock()
        .map(|g| g.iter().cloned().collect())
        .unwrap_or_default()
}

/// Per-URL verdicts, in input order: may the client fetch this media URL in
/// the CURRENT configuration? Always true under the active proxy base; in
/// direct mode also true for allowlisted hosts.
///
/// The saved GIF library asks this about the absolute URLs it stores for
/// direct-mode picks. Going back to proxy mode MUST hide them: fetching a
/// Klipy CDN URL while in proxy mode would defeat the entire point of proxy
/// mode, and a stale favourite is not a licence to do it. Dart asks rather
/// than duplicating the rule (same reason as `default_role_permissions`).
#[frb]
pub fn gif_media_urls_permitted(urls: Vec<String>) -> Vec<bool> {
    let base = gif_proxy_base();
    let direct = gif_api_key().is_some();
    urls.iter()
        .map(|u| u.starts_with(&base) || (direct && media_url_allowed(u)))
        .collect()
}

/// The default content rating. Dart owns rating POLICY (user setting, then
/// clamped for non-NSFW servers) and passes the result per call, so a rating
/// change can never serve results cached under another rating.
#[frb]
pub fn default_gif_rating() -> String {
    DEFAULT_RATING.to_string()
}

/// Ratings the picker may offer, mildest first.
#[frb]
pub fn gif_ratings() -> Vec<String> {
    RATINGS.iter().map(|r| r.to_string()).collect()
}

fn normalized_rating(raw: &str) -> String {
    let r = raw.trim().to_ascii_lowercase();
    if RATINGS.contains(&r.as_str()) {
        r
    } else {
        DEFAULT_RATING.to_string()
    }
}

/// Same clamp, for the sticker FFI in `api/stickers.rs` — an unknown rating
/// falls back to the default rather than reaching upstream.
pub(crate) fn normalized_rating_for(raw: &str) -> String {
    normalized_rating(raw)
}

// ─── URL guards ─────────────────────────────────────────────────────────────

/// Host of an https URL, lowercased. None for anything else — plaintext http
/// and non-URLs are refused outright rather than parsed leniently.
fn url_host(url: &str) -> Option<String> {
    let rest = url.strip_prefix("https://")?;
    let authority = rest.split(['/', '?', '#']).next()?;
    // Everything after the LAST '@': "https://static.klipy.com@evil.example/"
    // is a request to evil.example, and a first-match parse would allow it.
    let host_port = authority.rsplit('@').next()?;
    let host = if let Some(v6) = host_port.strip_prefix('[') {
        v6.split(']').next()?.to_string()
    } else {
        host_port.split(':').next()?.to_string()
    };
    if host.is_empty() {
        return None;
    }
    Some(host.to_ascii_lowercase())
}

/// Allowlist check WITHOUT recording — used where a miss is not news.
fn media_url_allowed(url: &str) -> bool {
    let Some(host) = url_host(url) else {
        return false;
    };
    media_hosts()
        .iter()
        .any(|h| host == *h || host.ends_with(&format!(".{h}")))
}

/// Allowlist check that remembers what it refused, so Settings can offer the
/// host to the user instead of leaving them with an empty grid.
fn media_url_ok(url: &str) -> bool {
    if media_url_allowed(url) {
        return true;
    }
    if let Some(host) = url_host(url)
        && let Ok(mut blocked) = blocked_hosts_store().lock()
        && blocked.len() < MAX_BLOCKED_HOSTS
    {
        blocked.insert(host);
    }
    false
}

// ─── Media kinds ────────────────────────────────────────────────────────────

/// Which Klipy catalog a call targets. Everything else about the two modes is
/// shared.
///
/// THE ID NAMESPACE IS THE LOAD-BEARING PART. Klipy slugs are per-catalog, so
/// a GIF and a sticker can carry the same slug — and both the proxy's `items`
/// registry and this module's direct-mode variant registry are keyed by bare
/// id. Sticker ids therefore get a `~` prefix everywhere they are handed out
/// (registry keys, media URLs, saved-library rows). GIF ids stay BARE on
/// purpose: the saved GIF library stores media paths relative to the proxy
/// base, so re-namespacing GIFs would 404 every favourite anyone has saved.
/// `~` is unreserved in URLs (RFC 3986) and outside the slug charset, so it
/// cannot collide with a real slug.
#[frb(ignore)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MediaKind {
    Gif,
    Sticker,
}

impl MediaKind {
    /// Path segment under `{root}/{key}/` in direct mode, and the `kind`
    /// param proxy mode sends to search.php.
    fn upstream_segment(self) -> &'static str {
        match self {
            MediaKind::Gif => "gifs",
            MediaKind::Sticker => "stickers",
        }
    }

    /// Namespace prefix on ids of this kind. See the type doc.
    fn id_prefix(self) -> &'static str {
        match self {
            MediaKind::Gif => "",
            MediaKind::Sticker => "~",
        }
    }

    /// The `emote_blobs.kind` a pick of this kind is stored under.
    fn asset_kind(self) -> &'static str {
        match self {
            MediaKind::Gif => "gif",
            MediaKind::Sticker => "sticker",
        }
    }

    /// Human label for log lines and error messages.
    fn label(self) -> &'static str {
        match self {
            MediaKind::Gif => "GIF",
            MediaKind::Sticker => "Sticker",
        }
    }
}

/// Klipy slug shape, mirroring the proxy's ingest validation, plus the
/// optional `~` sticker namespace prefix (see [MediaKind]). Accepting the
/// prefix HERE rather than per-kind is deliberate: `sticker_fetch_and_store`
/// and `gif_fetch_and_store` both build their own URL from the id, so a
/// mismatched prefix can only ever produce a 404, never a wrong fetch.
fn valid_gif_id(id: &str) -> bool {
    let bare = id.strip_prefix('~').unwrap_or(id);
    !bare.is_empty()
        && bare.len() <= 100
        && bare
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

// ─── Shared types ───────────────────────────────────────────────────────────

/// One GIF search/browse result. In proxy mode all URLs point at OUR proxy;
/// in direct mode at an allowlisted Klipy CDN host. Rows failing either
/// guard are dropped at parse time.
pub struct GifItem {
    pub id: String,
    pub w: u32,
    pub h: u32,
    pub title: String,
    /// Still frame (~150px) — the grid default.
    pub still_url: String,
    /// Small animated variant (~150px WebP or GIF) — hover/viewport preview.
    pub sm_url: String,
    /// Best-quality source, used at PICK time only. Carried on the item so a
    /// favourite saved in a direct-mode session can still be sent months
    /// later, when the in-RAM variant registry is long gone — see
    /// `gif_fetch_and_store`.
    pub full_url: String,
}

/// One page of the normalized search/trending response.
pub struct GifPage {
    pub items: Vec<GifItem>,
    pub page: u32,
    pub has_next: bool,
    /// Unix seconds until which the proxy's upstream is cooling down
    /// (0 = healthy, and always 0 in direct mode). An empty page with a
    /// non-zero value means "retry later", not "no results".
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

// ─── Proxy mode ─────────────────────────────────────────────────────────────

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
                        // The endpoint shape is ours (gifs/.htaccess), so a
                        // proxy that omits "full" is derived from rather than
                        // dropped.
                        full_url: it
                            .get("full")
                            .and_then(|u| u.as_str())
                            .filter(|u| u.starts_with(base))
                            .map(|u| u.to_string())
                            .unwrap_or_else(|| format!("{base}f/{id}")),
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

fn proxy_query(params: Vec<(&'static str, String)>) -> Result<serde_json::Value, String> {
    let rt = get_http_runtime();
    rt.block_on(async move {
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
    })
}

// ─── Direct mode ────────────────────────────────────────────────────────────

/// One-shot random customer id. Klipy REQUIRES the parameter but nothing
/// requires it to be stable, and a stable one would hand them a stitched
/// search history on top of the IP they already see. (Their ad products want
/// a durable id — we do not run ads.)
fn random_customer_id() -> String {
    let mut b = [0u8; 16];
    if getrandom::fill(&mut b).is_err() {
        // Never fatal: a weak nonce here leaks nothing, it just makes two
        // requests linkable to each other.
        let ns = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        b[..16].copy_from_slice(&ns.to_le_bytes());
    }
    hex::encode(b)
}

fn direct_query(
    key: &str,
    kind: MediaKind,
    path: &str,
    params: Vec<(&'static str, String)>,
) -> Result<serde_json::Value, String> {
    let url = format!("{KLIPY_API_ROOT}{key}/{}/{path}", kind.upstream_segment());
    let rt = get_http_runtime();
    rt.block_on(async move {
        let client = reqwest::Client::new();
        let resp = client
            .get(url)
            .query(&params)
            .query(&[("customer_id", random_customer_id())])
            .timeout(std::time::Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| format!("GIF search failed: {e}"))?;
        match resp.status().as_u16() {
            429 => return Err("Your Klipy key hit its rate limit — try again shortly".into()),
            401 | 403 => return Err("Klipy rejected your API key".into()),
            s if !(200..300).contains(&s) => return Err(format!("GIF search failed: HTTP {s}")),
            _ => {}
        }
        resp.json::<serde_json::Value>()
            .await
            .map_err(|e| format!("GIF search returned invalid JSON: {e}"))
    })
}

/// First `file[slot][fmt]` variant walking `slots` in preference order, as
/// (url, width, height). A missing SLOT must skip to the next one rather
/// than end the walk — Klipy omits sizes freely, and an item with only
/// `hd` is perfectly usable.
fn klipy_pick(
    file: &serde_json::Value,
    slots: &[&str],
    fmts: &[&str],
) -> Option<(String, u32, u32)> {
    for slot in slots {
        let Some(slot_obj) = file.get(slot) else {
            continue;
        };
        if let Some(found) = klipy_variant_in_slot(slot_obj, fmts) {
            return Some(found);
        }
    }
    None
}

fn klipy_variant_in_slot(slot_obj: &serde_json::Value, fmts: &[&str]) -> Option<(String, u32, u32)> {
    for fmt in fmts {
        let Some(v) = slot_obj.get(fmt) else { continue };
        let url = v.get("url").and_then(|u| u.as_str()).unwrap_or_default();
        if url.is_empty() {
            continue;
        }
        return Some((
            url.to_string(),
            v.get("width").and_then(|x| x.as_u64()).unwrap_or(0) as u32,
            v.get("height").and_then(|x| x.as_u64()).unwrap_or(0) as u32,
        ));
    }
    None
}

/// Normalize Klipy's own response into [GifPage]. This is the logic that
/// lives in gifs/search.php for proxy mode — direct mode has to own a copy,
/// which is the real cost of the feature: a provider swap stays a PHP change
/// for proxy users but becomes an app release for direct-mode users.
///
/// Item shape: { slug, title, type, file: { hd|md|sm|xs: { gif|webp|jpg|mp4:
/// {url,width,height,size} } } }. Ads arrive as { type:"ad", … } — dropped,
/// exactly like the proxy does.
fn parse_klipy_page(v: &serde_json::Value, kind: MediaKind) -> Result<GifPage, String> {
    if v.get("result").and_then(|r| r.as_bool()) != Some(true) {
        let msg = v
            .get("message")
            .or_else(|| v.get("error"))
            .and_then(|e| e.as_str())
            .unwrap_or("unknown error");
        return Err(format!("GIF search failed: {msg}"));
    }
    let data = v.get("data").ok_or("GIF search returned no data")?;
    let rows = data
        .get("data")
        .and_then(|d| d.as_array())
        .cloned()
        .unwrap_or_default();

    let mut items = Vec::new();
    for e in rows {
        if e.get("type").and_then(|t| t.as_str()) == Some("ad") {
            continue;
        }
        let Some(slug) = e.get("slug").and_then(|s| s.as_str()) else {
            continue;
        };
        // The upstream slug is BARE; everything downstream of this parse
        // (registry key, item id, saved-library row) uses the namespaced
        // form, so a sticker and a GIF sharing a slug stay distinct.
        let id = format!("{}{slug}", kind.id_prefix());
        if !valid_gif_id(&id) {
            continue;
        }
        let Some(file) = e.get("file") else { continue };
        // Grid dims come from the animated variant we will actually show.
        // mp4-only rows (clips) have neither and are unusable to us.
        let Some((sm_url, w, h)) = klipy_pick(file, &SIZE_SLOTS, &["webp", "gif"]) else {
            continue;
        };
        if w == 0 || h == 0 || w > 8192 || h > 8192 {
            continue;
        }
        let still_url = klipy_pick(file, &STILL_SLOTS, &["jpg", "png"])
            .map(|(u, _, _)| u)
            .unwrap_or_else(|| sm_url.clone());
        // Best-quality source for a later pick. Falls back to the small
        // variant rather than dropping the row: a lower-res send beats none.
        let full_url = klipy_pick(file, &FULL_SLOTS, &["webp", "gif"])
            .map(|(u, _, _)| u)
            .unwrap_or_else(|| sm_url.clone());
        if !media_url_ok(&sm_url) || !media_url_ok(&still_url) || !media_url_ok(&full_url) {
            continue;
        }
        if let Ok(mut reg) = direct_src_store().lock() {
            reg.insert(&id, file.clone());
        }
        items.push(GifItem {
            id,
            w,
            h,
            title: e
                .get("title")
                .and_then(|t| t.as_str())
                .unwrap_or_default()
                .chars()
                .take(120)
                .collect(),
            still_url,
            sm_url,
            full_url,
        });
    }
    Ok(GifPage {
        items,
        page: data
            .get("current_page")
            .and_then(|p| p.as_u64())
            .unwrap_or(1) as u32,
        has_next: data
            .get("has_next")
            .and_then(|b| b.as_bool())
            .unwrap_or(false),
        backoff_until: 0,
    })
}

// ─── Public API ─────────────────────────────────────────────────────────────

/// Search / trending dispatch. `query` empty = trending.
pub(crate) fn media_page(
    kind: MediaKind,
    query: Option<String>,
    page: u32,
    rating: &str,
) -> Result<GifPage, String> {
    let page = page.max(1);
    let mode = if query.is_some() { "search" } else { "trending" };
    let what = kind.upstream_segment();
    let t0 = std::time::Instant::now();
    let direct = gif_api_key();
    // Mode + kind only — NEVER the query text (privacy: search text stays out
    // of logs, ours included).
    crate::hollow_log!(
        "[HOLLOW-GIF] query start kind={what} mode={mode} via={}",
        if direct.is_some() { "direct" } else { "proxy" }
    );

    let result = match &direct {
        Some(key) => {
            let mut params: Vec<(&'static str, String)> = vec![
                ("page", page.to_string()),
                ("per_page", "30".to_string()),
                ("rating", rating.to_string()),
            ];
            let path = match &query {
                Some(q) => {
                    params.push(("q", q.clone()));
                    "search"
                }
                None => "trending",
            };
            direct_query(key, kind, path, params).and_then(|v| parse_klipy_page(&v, kind))
        }
        None => {
            let mut params: Vec<(&'static str, String)> = vec![
                ("page", page.to_string()),
                ("per_page", "30".to_string()),
                ("rating", rating.to_string()),
                ("v", GIF_SCHEMA_VER.to_string()),
                // Absent/"gifs" = the GIF catalog, so a proxy older than the
                // sticker feature keeps answering GIF requests unchanged.
                ("kind", what.to_string()),
            ];
            match &query {
                Some(q) => params.push(("q", q.clone())),
                None => params.push(("trending", "1".to_string())),
            }
            proxy_query(params).and_then(|v| parse_gif_page(&v, &gif_proxy_base()))
        }
    };

    match &result {
        Ok(p) => crate::hollow_log!(
            "[HOLLOW-GIF] query ok kind={what} mode={mode} items={} in {}ms",
            p.items.len(),
            t0.elapsed().as_millis()
        ),
        Err(e) => crate::hollow_log!(
            "[HOLLOW-GIF] query FAILED kind={what} mode={mode} in {}ms: {e}",
            t0.elapsed().as_millis()
        ),
    }
    result
}

/// Search GIFs. Authoring only. `rating` is one of `gif_ratings()`; anything
/// else falls back to the default rather than being sent upstream.
#[frb]
pub fn gif_search(query: String, page: u32, rating: String) -> Result<GifPage, String> {
    let q = query.trim().to_string();
    if q.is_empty() || q.chars().count() > 64 {
        return Ok(GifPage {
            items: vec![],
            page: 1,
            has_next: false,
            backoff_until: 0,
        });
    }
    media_page(MediaKind::Gif, Some(q), page, &normalized_rating(&rating))
}

/// Trending GIFs — the picker's default (empty-search) view.
#[frb]
pub fn gif_trending(page: u32, rating: String) -> Result<GifPage, String> {
    media_page(MediaKind::Gif, None, page, &normalized_rating(&rating))
}

/// The shared search entry point for [MediaKind::Sticker] (see
/// `api/stickers.rs`, which owns the sticker-facing FFI). An empty or
/// over-long query answers with an empty page rather than reaching upstream.
pub(crate) fn media_search(
    kind: MediaKind,
    query: String,
    page: u32,
    rating: String,
) -> Result<GifPage, String> {
    let q = query.trim().to_string();
    if q.is_empty() || q.chars().count() > 64 {
        return Ok(GifPage {
            items: vec![],
            page: 1,
            has_next: false,
            backoff_until: 0,
        });
    }
    media_page(kind, Some(q), page, &normalized_rating(&rating))
}

/// Category names for the browse chips (proxy caches them for 7 days).
#[frb]
pub fn gif_categories() -> Result<Vec<String>, String> {
    media_categories(MediaKind::Gif)
}

pub(crate) fn media_categories(kind: MediaKind) -> Result<Vec<String>, String> {
    let v = match gif_api_key() {
        Some(key) => direct_query(&key, kind, "categories", vec![])?,
        None => proxy_query(vec![
            ("categories", "1".to_string()),
            ("v", GIF_SCHEMA_VER.to_string()),
            ("kind", kind.upstream_segment().to_string()),
        ])?,
    };
    if v.get("result").and_then(|r| r.as_bool()) != Some(true) {
        return Err("GIF categories failed".into());
    }
    // Proxy hands back a flat name list; Klipy nests them under data and
    // wraps each in {category, query, preview_url}. Tolerate both here so
    // the two modes stay one contract for Dart.
    let node = v
        .get("categories")
        .or_else(|| v.get("data").and_then(|d| d.get("categories")))
        .or_else(|| v.get("data"))
        .cloned()
        .unwrap_or(serde_json::Value::Null);
    let Some(arr) = node.as_array() else {
        return Ok(vec![]);
    };
    Ok(arr
        .iter()
        .filter_map(|c| {
            let name = match c {
                serde_json::Value::String(s) => s.clone(),
                other => other
                    .get("category")
                    .or_else(|| other.get("query"))
                    .and_then(|n| n.as_str())
                    .unwrap_or_default()
                    .to_string(),
            };
            if name.is_empty() {
                None
            } else {
                Some(name.chars().take(64).collect::<String>())
            }
        })
        .collect())
}

/// Download a picked GIF's full-quality source, re-encode it into the
/// ≤480px/≤2MB send format, and cache it as a `kind='gif'` asset blob.
///
/// PROXY MODE ignores `source_url` entirely and builds `{base}f/{id}` — the
/// fetcher is structurally incapable of being pointed anywhere else.
///
/// DIRECT MODE resolves the variants OUR OWN parse registered for `id`, and
/// only if that RAM registry has no entry — a favourite saved in an earlier
/// session, which is the one case the registry cannot cover — falls back to
/// `source_url`, and then only if it passes the media host allowlist. That
/// allowlist is the guard in direct mode either way: every URL there comes
/// from Klipy's opaque CDN, so provenance cannot be re-derived, only
/// constrained.
#[frb]
pub fn gif_fetch_and_store(id: String, source_url: Option<String>) -> Result<StoredGif, String> {
    media_fetch_and_store(MediaKind::Gif, id, source_url)
}

/// Pick-time fetch + transcode for either kind. The only kind-dependent
/// parts are the transcoder (a sticker gets 512px/512 KB with alpha, a GIF
/// 480px/2 MB) and the asset-blob kind it lands under.
pub(crate) fn media_fetch_and_store(
    kind: MediaKind,
    id: String,
    source_url: Option<String>,
) -> Result<StoredGif, String> {
    if !valid_gif_id(&id) {
        return Err(format!("Invalid {} id", kind.label()));
    }
    let t0 = std::time::Instant::now();
    let raw = match gif_api_key() {
        Some(_) => direct_pick_bytes(kind, &id, source_url.as_deref())?,
        None => proxy_pick_bytes(&id)?,
    };
    let dl_ms = t0.elapsed().as_millis();
    let convert = match kind {
        MediaKind::Gif => crate::node::image_convert::process_gif_for_send,
        MediaKind::Sticker => crate::node::image_convert::process_sticker_for_send,
    };
    let (webp, w, h, animated) = convert(&raw).inspect_err(|e| {
        crate::hollow_log!("[HOLLOW-GIF] fetch transcode FAILED: {e}");
    })?;
    crate::hollow_log!(
        "[HOLLOW-GIF] fetch ok kind={}: {} raw -> {} webp {}x{} (dl {dl_ms}ms, total {}ms)",
        kind.upstream_segment(),
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
    ms.save_asset_blob(&hash, &webp, animated, kind.asset_kind())?;
    Ok(StoredGif {
        hash,
        w,
        h,
        animated,
    })
}

fn proxy_pick_bytes(id: &str) -> Result<Vec<u8>, String> {
    let url = format!("{}f/{id}", gif_proxy_base());
    let rt = get_http_runtime();
    rt.block_on(async move {
        let client = reqwest::Client::new();
        let resp = client
            .get(url)
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
        if bytes.len() > MAX_PICK_BYTES {
            return Err("GIF download too large".into());
        }
        Ok(bytes.to_vec())
    })
}

/// Direct mode: walk the registered variants best-first, host-checking each,
/// and take the first that downloads within the cap. Mirrors full.php's
/// walk-down so an oversize hd variant degrades instead of failing the pick.
/// Download candidates for a direct-mode pick, best-quality first. Split out
/// from the download itself so the registry/fallback/allowlist decisions are
/// unit-testable without network.
fn direct_pick_candidates(id: &str, source_url: Option<&str>) -> Vec<String> {
    let file = direct_src_store().lock().ok().and_then(|reg| reg.get(id));

    let mut candidates: Vec<String> = Vec::new();
    if let Some(file) = file {
        for slot in FULL_SLOTS {
            let Some(slot_obj) = file.get(slot) else {
                continue;
            };
            for fmt in ["webp", "gif"] {
                if let Some(url) = slot_obj
                    .get(fmt)
                    .and_then(|v| v.get("url"))
                    .and_then(|u| u.as_str())
                    .filter(|u| !u.is_empty())
                    && media_url_ok(url)
                {
                    candidates.push(url.to_string());
                }
            }
        }
    }
    // Registry miss (a favourite from an earlier session): the caller's
    // remembered source is the only way back to the bytes.
    if candidates.is_empty()
        && let Some(url) = source_url.filter(|u| media_url_ok(u))
    {
        candidates.push(url.to_string());
    }
    candidates
}

fn direct_pick_bytes(
    kind: MediaKind,
    id: &str,
    source_url: Option<&str>,
) -> Result<Vec<u8>, String> {
    let candidates = direct_pick_candidates(id, source_url);
    if candidates.is_empty() {
        return Err(format!(
            "That {} has no downloadable variant",
            kind.label().to_lowercase()
        ));
    }

    let rt = get_http_runtime();
    rt.block_on(async move {
        let client = reqwest::Client::new();
        let mut last_err = String::from("GIF download failed");
        for url in candidates {
            let resp = match client
                .get(&url)
                .timeout(std::time::Duration::from_secs(45))
                .send()
                .await
            {
                Ok(r) => r,
                Err(e) => {
                    last_err = format!("GIF download failed: {e}");
                    continue;
                }
            };
            if !resp.status().is_success() {
                last_err = format!("GIF download failed: HTTP {}", resp.status());
                continue;
            }
            match resp.bytes().await {
                Ok(b) if !b.is_empty() && b.len() <= MAX_PICK_BYTES => return Ok(b.to_vec()),
                Ok(_) => last_err = "GIF download too large".into(),
                Err(e) => last_err = format!("GIF download failed: {e}"),
            }
        }
        Err(last_err)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The module's settings live in process-wide statics, so every test that
    /// touches them serializes here (same reasoning as `resolver::test_lock`).
    fn settings_lock() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap_or_else(|e| e.into_inner())
    }

    /// Back to shipped defaults so one test's settings never leak into
    /// another's assertions.
    fn reset_settings() {
        set_gif_proxy_url(None).unwrap();
        set_gif_api_key(None).unwrap();
        set_gif_media_hosts(vec![]).unwrap();
    }

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
        assert_eq!(page.items[0].full_url, format!("{base}f/ok_1"));
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

    #[test]
    fn url_host_parses_and_refuses_tricks() {
        assert_eq!(url_host("https://static.klipy.com/a.gif").as_deref(), Some("static.klipy.com"));
        assert_eq!(url_host("https://STATIC.Klipy.com:443/a").as_deref(), Some("static.klipy.com"));
        // Userinfo must not win: this URL goes to evil.example.
        assert_eq!(
            url_host("https://static.klipy.com@evil.example/a.gif").as_deref(),
            Some("evil.example")
        );
        assert_eq!(url_host("https://[2001:db8::1]/a").as_deref(), Some("2001:db8::1"));
        // Plaintext and junk are refused rather than leniently parsed.
        assert!(url_host("http://static.klipy.com/a.gif").is_none());
        assert!(url_host("https:///a.gif").is_none());
        assert!(url_host("not a url").is_none());
    }

    #[test]
    fn media_hosts_suffix_match_and_validate() {
        let _g = settings_lock();
        reset_settings();
        assert_eq!(default_gif_media_hosts(), vec!["klipy.com".to_string()]);
        assert!(media_url_allowed("https://static2.klipy.com/x.webp"));
        assert!(media_url_allowed("https://klipy.com/x.webp"));
        // Suffix match must not be a substring match.
        assert!(!media_url_allowed("https://evilklipy.com/x.webp"));
        assert!(!media_url_allowed("https://klipy.com.evil.example/x.webp"));

        set_gif_media_hosts(vec!["  CDN.Example.com ".into(), ".klipy.com".into()]).unwrap();
        assert!(media_url_allowed("https://a.cdn.example.com/x.webp"));
        assert!(media_url_allowed("https://static.klipy.com/x.webp"));
        // Empty list resets to shipped defaults rather than blocking all media.
        set_gif_media_hosts(vec![]).unwrap();
        assert_eq!(media_hosts(), vec!["klipy.com".to_string()]);
        assert!(set_gif_media_hosts(vec!["no-dot".into()]).is_err());
        assert!(set_gif_media_hosts(vec!["bad host.com".into()]).is_err());
        reset_settings();
    }

    #[test]
    fn blocked_hosts_are_recorded_for_the_settings_ui() {
        let _g = settings_lock();
        reset_settings();
        assert!(!media_url_ok("https://cdn.unknown.example/x.webp"));
        assert!(gif_blocked_media_hosts().contains(&"cdn.unknown.example".to_string()));
        // Any settings change clears the hints — they describe one config.
        set_gif_media_hosts(vec!["unknown.example".into()]).unwrap();
        assert!(gif_blocked_media_hosts().is_empty());
        assert!(media_url_ok("https://cdn.unknown.example/x.webp"));
        reset_settings();
    }

    #[test]
    fn api_keys_cannot_break_out_of_the_url_path() {
        let _g = settings_lock();
        reset_settings();
        assert!(!gif_direct_mode());
        assert!(set_gif_api_key(Some("abc/../gifs".into())).is_err());
        assert!(set_gif_api_key(Some("abc?x=1".into())).is_err());
        assert!(set_gif_api_key(Some("abc#frag".into())).is_err());
        assert!(set_gif_api_key(Some("has space".into())).is_err());
        assert!(set_gif_api_key(Some("x".repeat(201))).is_err());
        assert!(!gif_direct_mode(), "a rejected key must not enable direct mode");
        set_gif_api_key(Some("  live_abc-123.def  ".into())).unwrap();
        assert!(gif_direct_mode());
        assert_eq!(gif_api_key().as_deref(), Some("live_abc-123.def"));
        set_gif_api_key(Some("  ".into())).unwrap();
        assert!(!gif_direct_mode(), "blank clears back to proxy mode");
        reset_settings();
    }

    #[test]
    fn ratings_normalize_to_a_known_value() {
        assert_eq!(normalized_rating("PG-13"), "pg-13");
        assert_eq!(normalized_rating(" r "), "r");
        assert_eq!(normalized_rating("xxx"), DEFAULT_RATING);
        assert_eq!(normalized_rating(""), DEFAULT_RATING);
        assert_eq!(default_gif_rating(), "pg-13");
        assert_eq!(gif_ratings().len(), 4);
    }

    fn klipy_item(slug: &str, host: &str, with_jpg: bool) -> String {
        let jpg = if with_jpg {
            format!(r#""jpg":{{"url":"https://{host}/{slug}.jpg","width":150,"height":84}},"#)
        } else {
            String::new()
        };
        format!(
            r#"{{"slug":"{slug}","title":"t {slug}","type":"gif",
                 "file":{{
                   "xs":{{{jpg}"webp":{{"url":"https://{host}/{slug}.xs.webp","width":150,"height":84}}}},
                   "hd":{{"webp":{{"url":"https://{host}/{slug}.hd.webp","width":480,"height":270}}}}
                 }}}}"#
        )
    }

    #[test]
    fn klipy_page_parses_strips_ads_and_guards_hosts() {
        let _g = settings_lock();
        reset_settings();
        let good = klipy_item("ok_1", "static.klipy.com", true);
        let no_jpg = klipy_item("ok_2", "static2.klipy.com", false);
        let foreign = klipy_item("bad_1", "cdn.evil.example", true);
        let v: serde_json::Value = serde_json::from_str(&format!(
            r#"{{"result":true,"data":{{"current_page":3,"has_next":true,"data":[
                 {good},
                 {{"type":"ad","width":300,"height":250,"content":"<html>"}},
                 {no_jpg},
                 {foreign},
                 {{"slug":"clip_only","title":"c","file":{{"hd":{{"mp4":{{"url":"https://static.klipy.com/c.mp4","width":480,"height":270}}}}}}}}
               ]}}}}"#
        ))
        .unwrap();

        let page = parse_klipy_page(&v, MediaKind::Gif).unwrap();
        let ids: Vec<&str> = page.items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(ids, vec!["ok_1", "ok_2"], "ad, foreign host and mp4-only row must all drop");
        assert_eq!(page.page, 3);
        assert!(page.has_next);
        // Grid dims come from the smallest animated variant, not the hd one.
        assert_eq!((page.items[0].w, page.items[0].h), (150, 84));
        // Klipy's jpg IS the still; without one we fall back to the animated
        // small rather than dropping the row.
        assert!(page.items[0].still_url.ends_with("ok_1.jpg"));
        assert_eq!(page.items[1].still_url, page.items[1].sm_url);
        // Pick-time source is the BEST variant, not the grid one.
        assert!(page.items[0].full_url.ends_with("ok_1.hd.webp"));
        // The foreign host is offered to the user instead of vanishing.
        assert!(gif_blocked_media_hosts().contains(&"cdn.evil.example".to_string()));
        // Parsing registers the variants so a pick needs no URL from Dart.
        assert!(direct_src_store().lock().unwrap().get("ok_1").is_some());
        assert!(direct_src_store().lock().unwrap().get("bad_1").is_none());
        reset_settings();
    }

    #[test]
    fn gif_ids_accept_the_sticker_namespace_prefix() {
        assert!(valid_gif_id("~abc_DEF-123"));
        // Only ONE leading prefix, and never a bare prefix.
        assert!(!valid_gif_id("~"));
        assert!(!valid_gif_id("~~abc"));
        // Still nowhere else in the id.
        assert!(!valid_gif_id("ab~c"));
        assert!(!valid_gif_id(&format!("~{}", "x".repeat(101))));
    }

    /// The reason the `~` namespace exists: Klipy slugs are per-catalog, so
    /// the SAME slug can arrive from both. Without the prefix the second
    /// parse would overwrite the first's registry entry and a GIF's media URL
    /// would start serving sticker bytes.
    #[test]
    fn sticker_and_gif_sharing_a_slug_stay_distinct() {
        let _g = settings_lock();
        reset_settings();
        clear_direct_registry();
        let page_json = |host: &str| {
            serde_json::from_str::<serde_json::Value>(&format!(
                r#"{{"result":true,"data":{{"current_page":1,"has_next":false,
                     "data":[{}]}}}}"#,
                klipy_item("shared", host, true)
            ))
            .unwrap()
        };

        let gifs = parse_klipy_page(&page_json("static.klipy.com"), MediaKind::Gif).unwrap();
        let stickers =
            parse_klipy_page(&page_json("static2.klipy.com"), MediaKind::Sticker).unwrap();
        assert_eq!(gifs.items[0].id, "shared");
        assert_eq!(stickers.items[0].id, "~shared");

        // Both registry entries survive, each pointing at its own CDN host.
        let reg = direct_src_store().lock().unwrap();
        assert!(reg.get("shared").is_some(), "GIF entry must survive");
        assert!(reg.get("~shared").is_some(), "sticker entry must survive");
        drop(reg);
        let gif_pick = direct_pick_candidates("shared", None);
        let sticker_pick = direct_pick_candidates("~shared", None);
        assert!(gif_pick.iter().all(|u| u.contains("static.klipy.com")));
        assert!(sticker_pick.iter().all(|u| u.contains("static2.klipy.com")));
        reset_settings();
    }

    /// Proxy mode: the id arrives ALREADY namespaced from search.php, and the
    /// derived `full` URL must keep the prefix or it resolves to the GIF.
    #[test]
    fn proxy_sticker_rows_keep_the_prefix_through_the_full_url_fallback() {
        let base = "https://hollow.anonlisten.com/gifs/";
        let v: serde_json::Value = serde_json::from_str(&format!(
            r#"{{"result":true,
                "items":[{{"id":"~shared","w":320,"h":320,"title":"s",
                  "still":"{base}m/~shared.still.webp","sm":"{base}m/~shared.sm.webp"}}],
                "page":1,"has_next":false}}"#
        ))
        .unwrap();
        let page = parse_gif_page(&v, base).unwrap();
        assert_eq!(page.items[0].id, "~shared");
        assert_eq!(page.items[0].full_url, format!("{base}f/~shared"));
    }

    #[test]
    fn media_kinds_map_to_upstream_and_asset_kinds() {
        assert_eq!(MediaKind::Gif.upstream_segment(), "gifs");
        assert_eq!(MediaKind::Sticker.upstream_segment(), "stickers");
        assert_eq!(MediaKind::Gif.asset_kind(), "gif");
        assert_eq!(MediaKind::Sticker.asset_kind(), "sticker");
        // The asset kinds must be ones the rail actually knows, or a pick
        // would be stored under a kind nothing can request back.
        for k in [MediaKind::Gif, MediaKind::Sticker] {
            assert!(
                crate::node::assets::AssetKind::from_db_kind(k.asset_kind()).is_some(),
                "{} is not a known AssetKind",
                k.asset_kind()
            );
        }
    }

    #[test]
    fn direct_picks_prefer_the_registry_and_fall_back_once() {
        let _g = settings_lock();
        reset_settings();
        clear_direct_registry();
        let v: serde_json::Value = serde_json::from_str(&format!(
            r#"{{"result":true,"data":{{"current_page":1,"has_next":false,
                 "data":[{}]}}}}"#,
            klipy_item("ok_1", "static.klipy.com", true)
        ))
        .unwrap();
        parse_klipy_page(&v, MediaKind::Gif).unwrap();

        // Registry hit: best quality first, and the caller's URL is not even
        // consulted.
        let c = direct_pick_candidates("ok_1", Some("https://static.klipy.com/other.webp"));
        assert!(c[0].ends_with("ok_1.hd.webp"), "hd before xs: {c:?}");
        assert!(!c.iter().any(|u| u.contains("other.webp")));

        // Registry miss (a favourite from an earlier session) — the caller's
        // remembered source is the only way back to the bytes…
        let c = direct_pick_candidates("gone_1", Some("https://static.klipy.com/gone.webp"));
        assert_eq!(c, vec!["https://static.klipy.com/gone.webp".to_string()]);

        // …but only ever through the allowlist.
        assert!(direct_pick_candidates("gone_1", Some("https://evil.example/x.webp")).is_empty());
        assert!(direct_pick_candidates("gone_1", Some("http://static.klipy.com/x.webp")).is_empty());
        assert!(direct_pick_candidates("gone_1", None).is_empty());
        reset_settings();
    }

    #[test]
    fn klipy_errors_and_empty_shapes_are_survivable() {
        let v: serde_json::Value =
            serde_json::from_str(r#"{"result":false,"message":"invalid key"}"#).unwrap();
        let err = parse_klipy_page(&v, MediaKind::Gif).err().expect("must fail");
        assert!(err.contains("invalid key"), "got: {err}");
        let v: serde_json::Value = serde_json::from_str(r#"{"result":true,"data":{}}"#).unwrap();
        let page = parse_klipy_page(&v, MediaKind::Gif).unwrap();
        assert!(page.items.is_empty());
        assert_eq!(page.page, 1);
        assert!(!page.has_next);
    }

    #[test]
    fn direct_registry_evicts_oldest_and_clears_on_mode_change() {
        let _g = settings_lock();
        reset_settings();
        {
            let mut reg = direct_src_store().lock().unwrap();
            reg.clear();
            for i in 0..(MAX_DIRECT_REGISTRY + 10) {
                reg.insert(&format!("id_{i}"), serde_json::json!({"n": i}));
            }
            assert_eq!(reg.map.len(), MAX_DIRECT_REGISTRY);
            assert!(reg.get("id_0").is_none(), "oldest evicted");
            assert!(reg.get(&format!("id_{}", MAX_DIRECT_REGISTRY + 9)).is_some());
        }
        // Switching modes must not leave entries pointing at the old world.
        set_gif_api_key(Some("k-1".into())).unwrap();
        assert!(direct_src_store().lock().unwrap().map.is_empty());
        reset_settings();
    }

    #[test]
    fn proxy_base_normalizes_and_rejects_http() {
        let _g = settings_lock();
        reset_settings();
        set_gif_proxy_url(Some("https://example.com/gifs".into())).unwrap();
        assert_eq!(gif_proxy_base(), "https://example.com/gifs/");
        assert!(set_gif_proxy_url(Some("http://example.com/gifs/".into())).is_err());
        // A rejected set leaves the previous value in place.
        assert_eq!(gif_proxy_base(), "https://example.com/gifs/");
        set_gif_proxy_url(Some("  ".into())).unwrap();
        assert_eq!(gif_proxy_base(), DEFAULT_GIF_PROXY);
        set_gif_proxy_url(None).unwrap();
        assert_eq!(gif_proxy_base(), DEFAULT_GIF_PROXY);
        reset_settings();
    }

    #[test]
    fn media_permission_answers_in_input_order_and_follows_the_mode() {
        let _g = settings_lock();
        reset_settings();
        let urls = vec![
            format!("{DEFAULT_GIF_PROXY}m/a.still.webp"),
            "https://static.klipy.com/a.webp".to_string(),
            "https://evil.example/a.webp".to_string(),
            "http://static.klipy.com/a.webp".to_string(),
        ];
        // Proxy mode: ONLY our own base. A CDN URL saved during a direct-mode
        // session must not be fetched once the key is gone.
        assert_eq!(
            gif_media_urls_permitted(urls.clone()),
            vec![true, false, false, false]
        );
        set_gif_api_key(Some("k-1".into())).unwrap();
        // Direct mode: allowlisted hosts too, and our proxy still works for
        // rows saved before the switch.
        assert_eq!(
            gif_media_urls_permitted(urls),
            vec![true, true, false, false]
        );
        reset_settings();
    }

    /// Manual live smoke test against the deployed proxy (network):
    /// `cargo test --lib gifs -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn live_proxy_smoke() {
        let t0 = std::time::Instant::now();
        let trending = gif_trending(1, "pg".into()).expect("trending");
        println!("trending: {} items in {:?}", trending.items.len(), t0.elapsed());
        let t1 = std::time::Instant::now();
        let search = gif_search("cat".into(), 1, "pg".into()).expect("search");
        println!("search: {} items in {:?}", search.items.len(), t1.elapsed());
        let t2 = std::time::Instant::now();
        let cats = gif_categories().expect("categories");
        println!("categories: {} in {:?}", cats.len(), t2.elapsed());
        assert!(!trending.items.is_empty());
        assert!(!search.items.is_empty());
    }

    /// Manual live DIRECT-mode smoke. Needs a real key:
    /// `HOLLOW_KLIPY_KEY=... cargo test --lib gifs::tests::live_direct -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn live_direct_smoke() {
        let Ok(key) = std::env::var("HOLLOW_KLIPY_KEY") else {
            println!("set HOLLOW_KLIPY_KEY to run this");
            return;
        };
        let _g = settings_lock();
        reset_settings();
        set_gif_api_key(Some(key)).unwrap();
        let trending = gif_trending(1, "pg".into()).expect("trending");
        println!("direct trending: {} items", trending.items.len());
        for item in trending.items.iter().take(3) {
            println!("  {} {}x{} still={}", item.id, item.w, item.h, item.still_url);
        }
        let cats = gif_categories().expect("categories");
        println!("direct categories: {cats:?}");
        let search = gif_search("cat".into(), 1, "pg".into()).expect("search");
        println!("direct search: {} items", search.items.len());
        assert!(!trending.items.is_empty());
        println!("blocked hosts seen: {:?}", gif_blocked_media_hosts());
        reset_settings();
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
        let rt = super::super::network::get_runtime();
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
        let r = gif_trending(1, "pg".into());
        let elapsed = t0.elapsed();
        println!(
            "saturated-pool trending: {:?} in {elapsed:?}",
            r.as_ref().map(|p| p.items.len())
        );
        assert!(r.is_ok(), "search must not starve behind node DB work");
        assert!(elapsed.as_secs() < 10, "must complete fast, not at timeout");
    }
}
