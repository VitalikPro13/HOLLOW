//! The app's client for the Hollow Shop (shop.anonlisten.com).
//!
//! READ-ONLY against the shop. This module fetches the public catalog and the
//! preview art it names, and that is all it takes from the network. The only
//! thing it WRITES anywhere is the local `redeem_codes` table, which holds the
//! codes a `hollow://redeem/<code>` deep link carries until phase 2 can turn
//! one into a blind-signed support credential.
//!
//! **Nothing fetched here is ever stored on the asset rail.** A preview is a
//! picture of something for sale, not something we own: it has no pack behind
//! it, no licence row, no provenance, and it must never end up indistinguishable
//! from art the buyer actually has. Owned art enters Hollow through exactly one
//! door, [`crate::api::network::import_hollowpack`], which verifies a whole
//! `.hollowpack` before a single byte lands. `fetch_shop_art` returns bytes to
//! the caller and keeps none.
//!
//! The catalog is parsed TOLERANTLY: a listing the shop adds a field to, or one
//! whose files went bad, narrows or drops rather than failing the whole fetch.
//! A wall that is one card short beats a wall that will not load.

use flutter_rust_bridge::frb;
use serde::{Deserialize, Deserializer};
use sha2::{Digest, Sha256};

use base64::Engine;

use super::network::get_http_runtime;
use super::storage::get_store;
use crate::crdt::valid_emote_hash;
use crate::hollow_log;
use crate::hollowpack::{Role, MAX_FILE_BYTES};

const B64: base64::engine::GeneralPurpose = base64::engine::general_purpose::STANDARD;

// ── Origin ────────────────────────────────────────────────────────────

/// The shop.
pub const SHOP_ORIGIN: &str = "https://shop.anonlisten.com";

/// Largest catalog document we will read. The live catalog is a few tens of
/// kilobytes; 4 MB is room for a shop a hundred times its size and still a
/// bound.
const MAX_CATALOG_BYTES: usize = 4 * 1024 * 1024;

/// Most redeem codes one install keeps. A buyer has a handful; a hostile
/// `hollow://redeem/…` link farm has this many and then nothing.
const MAX_KEPT_REDEEM_CODES: u32 = 64;

/// The shop origin.
///
/// In DEBUG builds only, `HOLLOW_SHOP_ORIGIN` in the environment overrides it,
/// which is how the local dev shop at `http://localhost:3000` is reached.
/// Release builds ignore the variable: a store you can point elsewhere with an
/// environment variable is a store somebody else can point elsewhere.
#[frb]
pub fn shop_origin() -> String {
    if cfg!(debug_assertions) {
        if let Ok(raw) = std::env::var("HOLLOW_SHOP_ORIGIN") {
            let trimmed = raw.trim().trim_end_matches('/');
            if !trimmed.is_empty() {
                return trimmed.to_string();
            }
        }
    }
    SHOP_ORIGIN.trim_end_matches('/').to_string()
}

// ── What the app sees ─────────────────────────────────────────────────

/// One file of a listing, named by the SHA-256 of its processed bytes: the same
/// number `import_hollowpack` recomputes and the same number the profile field
/// carries once the art is worn.
#[derive(Debug, Clone)]
pub struct ShopFile {
    /// A `.hollowpack` role: `frame`, `avatar`, `avatar_anim`, `avatar_still`,
    /// `banner`, `banner_anim` or `banner_still`. Anything else was dropped.
    pub role: String,
    pub sha256: String,
    pub bytes: u64,
    /// 0 when the shop did not record a size.
    pub w: u32,
    pub h: u32,
    pub animated: bool,
}

/// Who made a listing.
#[derive(Debug, Clone)]
pub struct ShopArtist {
    pub slug: String,
    pub display_name: String,
    pub bio: String,
    /// Hash of the artist page's header art, `""` when there is none.
    pub header_hash: String,
    /// `{origin}/@{slug}`, or `""` when the slug is not a shape we will build
    /// a URL out of.
    pub url: String,
}

/// One thing for sale, already reduced to what a card needs to draw.
#[derive(Debug, Clone)]
pub struct ShopListing {
    pub slug: String,
    pub title: String,
    pub description: String,
    /// The kinds a profile can WEAR from this listing, in the shop's fixed
    /// order (frame, avatar, banner) and never anything else.
    pub kinds: Vec<String>,
    pub price_cents: u32,
    /// Always two decimals: `$5` beside `$4.99` reads as a rounding.
    pub price_label: String,
    /// The list price while the piece is on sale, 0 otherwise. `price_cents`
    /// is always what a buyer pays; this is the number the card strikes
    /// through beside it.
    pub was_cents: u32,
    /// [`Self::was_cents`] as the shop writes it, `""` when there is no sale.
    pub was_label: String,
    pub license: String,
    pub created_at: String,
    pub artist: ShopArtist,
    pub files: Vec<ShopFile>,
    /// The one picture that IS this item, and its address on the shop.
    pub display_hash: String,
    /// The still sibling of [`Self::display_hash`], for a viewer who asked for
    /// stillness. `""` when the display file is already still (or when no
    /// still was shipped: freezing an animation is not something we do).
    pub still_hash: String,
    /// The kind the card draws, `""` when the listing names none.
    pub primary_kind: String,
    /// Two kinds or more.
    pub bundle: bool,
    /// The display file is a wide strip (aspect 2:1 or wider) rather than a
    /// square.
    pub wide: bool,
    /// The support credential's item hash for this listing (64-hex), or `""`
    /// when the listing was put up before credentials existed. What
    /// `list_own_support_creds` items compare against: "you support this".
    pub credential_item: String,
    /// `{origin}/item/{slug}`: the listing's own address. A hash is the ART's
    /// address, and a bundle carries the same frame hash as the single frame
    /// on purpose, so a link by hash opened whichever listing the shop found
    /// first (the bug Vitalik hit on 2026-09-02). The shop still redirects an
    /// old hash link, single before set.
    pub item_url: String,
}

/// The public catalog as the app consumes it.
#[derive(Debug, Clone)]
pub struct ShopCatalog {
    /// The origin it came from, so a card can build its own links without
    /// asking again.
    pub origin: String,
    pub generated_at: String,
    pub listings: Vec<ShopListing>,
}

// ── Wire shapes ───────────────────────────────────────────────────────
//
// Every field defaults and every unknown field is ignored, so a shop that
// grows a column keeps working against an app that has not shipped yet. The
// two helpers below make that per-FIELD and per-ELEMENT rather than
// per-document: one listing written by a newer dashboard must not be able to
// blank the catalog.

/// Deserialize a field, falling back to `Default` when it is the wrong type.
fn lenient<'de, D, T>(d: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: serde::de::DeserializeOwned + Default,
{
    let v = serde_json::Value::deserialize(d)?;
    Ok(serde_json::from_value(v).unwrap_or_default())
}

/// Deserialize a list, dropping the elements that do not fit rather than the
/// list.
fn lenient_vec<'de, D, T>(d: D) -> Result<Vec<T>, D::Error>
where
    D: Deserializer<'de>,
    T: serde::de::DeserializeOwned,
{
    let v = serde_json::Value::deserialize(d)?;
    let serde_json::Value::Array(items) = v else {
        return Ok(Vec::new());
    };
    Ok(items
        .into_iter()
        .filter_map(|i| serde_json::from_value::<T>(i).ok())
        .collect())
}

#[frb(ignore)]
#[derive(Debug, Default, Deserialize)]
struct RawCatalog {
    #[serde(default, deserialize_with = "lenient")]
    generated_at: String,
    #[serde(default, deserialize_with = "lenient_vec")]
    listings: Vec<RawListing>,
}

#[frb(ignore)]
#[derive(Debug, Default, Deserialize)]
struct RawListing {
    #[serde(default, deserialize_with = "lenient")]
    slug: String,
    #[serde(default, deserialize_with = "lenient")]
    title: String,
    #[serde(default, deserialize_with = "lenient")]
    description: String,
    #[serde(default, deserialize_with = "lenient_vec")]
    kinds: Vec<String>,
    #[serde(default, deserialize_with = "lenient")]
    price_cents: f64,
    /// The list price while a sale is on, absent otherwise (the shop only
    /// writes it during a sale).
    #[serde(default, deserialize_with = "lenient")]
    was_cents: f64,
    #[serde(default, deserialize_with = "lenient")]
    license: String,
    #[serde(default, deserialize_with = "lenient")]
    created_at: String,
    #[serde(default, deserialize_with = "lenient")]
    artist: RawArtist,
    #[serde(default, deserialize_with = "lenient_vec")]
    files: Vec<RawFile>,
    /// The support credential's item hash, once the listing has an issuing
    /// key. Absent on listings from before phase 2.
    #[serde(default, deserialize_with = "lenient")]
    item: String,
}

#[frb(ignore)]
#[derive(Debug, Default, Deserialize)]
struct RawArtist {
    #[serde(default, deserialize_with = "lenient")]
    slug: String,
    #[serde(default, deserialize_with = "lenient")]
    display_name: String,
    #[serde(default, deserialize_with = "lenient")]
    bio: String,
    #[serde(default, deserialize_with = "lenient")]
    header_hash: Option<String>,
}

#[frb(ignore)]
#[derive(Debug, Default, Deserialize)]
struct RawFile {
    #[serde(default, deserialize_with = "lenient")]
    role: String,
    #[serde(default, deserialize_with = "lenient")]
    sha256: String,
    #[serde(default, deserialize_with = "lenient")]
    bytes: f64,
    #[serde(default, deserialize_with = "lenient")]
    w: Option<f64>,
    #[serde(default, deserialize_with = "lenient")]
    h: Option<f64>,
    #[serde(default, deserialize_with = "lenient")]
    animated: bool,
}

// ── Display rules (a port of the shop's own catalog.js) ───────────────
//
// These decide which file represents a piece. They are the SHOP's rules, not
// ours: the card the app draws and the card the website draws must be the same
// card, so this is a faithful port of `src/lib/server/catalog.js` and any
// change belongs there first.

/// The kinds a profile can wear, in the order a listing is represented by.
const KIND_ORDER: [&str; 3] = ["frame", "avatar", "banner"];

/// `(animated role, still role, base role)` for one kind. `anim` is the piece
/// when it may move, `still` the sibling for a viewer who asked for stillness,
/// `base` the single-file case.
fn kind_roles(kind: &str) -> Option<(Option<&'static str>, Option<&'static str>, &'static str)> {
    match kind {
        "frame" => Some((None, None, "frame")),
        "avatar" => Some((Some("avatar_anim"), Some("avatar_still"), "avatar")),
        "banner" => Some((Some("banner_anim"), Some("banner_still"), "banner")),
        _ => None,
    }
}

/// The kind a role carries, for the case where a listing's declared kinds
/// disagree with the files it shipped and the files get the last word.
fn kind_of_role(role: &str) -> Option<&'static str> {
    match role {
        "frame" => Some("frame"),
        "avatar" | "avatar_anim" | "avatar_still" => Some("avatar"),
        "banner" | "banner_anim" | "banner_still" => Some("banner"),
        _ => None,
    }
}

/// First file per role, in file order. A role is a slot, and a duplicate is a
/// data problem the wall must not resolve by flickering between two pictures.
fn by_role<'a>(files: &'a [ShopFile], role: &str) -> Option<&'a ShopFile> {
    files.iter().find(|f| f.role == role)
}

/// The file that represents one KIND of a listing.
fn file_for_kind<'a>(files: &'a [ShopFile], kind: &str, reduced: bool) -> Option<&'a ShopFile> {
    let (anim_role, still_role, base_role) = kind_roles(kind)?;
    let still = still_role.and_then(|r| by_role(files, r));
    // A viewer who asked for stillness gets the still, and only when one was
    // actually shipped.
    if reduced && still.is_some() {
        return still;
    }
    let anim = anim_role.and_then(|r| by_role(files, r));
    anim.or_else(|| by_role(files, base_role)).or(still)
}

/// The kind a listing is represented BY.
fn primary_kind_of(kinds: &[String], files: &[ShopFile]) -> Option<&'static str> {
    let has = |k: &str| kinds.iter().any(|x| x == k);
    // A SET leads with its banner: the 3:1 strip is the only shape wide enough
    // to say that a bundle is more than one thing.
    if kinds.len() >= 2 && has("banner") && file_for_kind(files, "banner", false).is_some() {
        return Some("banner");
    }
    KIND_ORDER
        .into_iter()
        .find(|k| has(k) && file_for_kind(files, k, false).is_some())
        // A listing whose kinds do not match its files still has to hang
        // somewhere, so the files get the last word.
        .or_else(|| {
            KIND_ORDER
                .into_iter()
                .find(|k| file_for_kind(files, k, false).is_some())
        })
}

/// The one picture that IS the item, still-swapped when `reduced`.
fn display_file_for<'a>(
    kinds: &[String],
    files: &'a [ShopFile],
    reduced: bool,
) -> Option<&'a ShopFile> {
    if let Some(kind) = primary_kind_of(kinds, files)
        && let Some(file) = file_for_kind(files, kind, reduced)
    {
        return Some(file);
    }
    files.first()
}

/// Cents as the shop writes them, always two decimals.
fn price_label(cents: u32) -> String {
    format!("${}.{:02}", cents / 100, cents % 100)
}

// ── Sanitising ────────────────────────────────────────────────────────

/// A slug is an address fragment we paste into a URL, so it gets the shape
/// check rather than an escape: lowercase alphanumeric and dashes, starting
/// with an alphanumeric.
fn valid_slug(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.starts_with(|c: char| c.is_ascii_lowercase() || c.is_ascii_digit())
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// Trim and cap a remote string at `max` CHARACTERS (never bytes: a cap that
/// splits a multi-byte character is a panic waiting for its first non-Latin
/// title).
fn clamp(s: &str, max: usize) -> String {
    let t = s.trim();
    if t.chars().count() <= max {
        return t.to_string();
    }
    t.chars().take(max).collect()
}

fn sanitize_file(raw: RawFile) -> Option<ShopFile> {
    let sha256 = raw.sha256.trim().to_string();
    if !valid_emote_hash(&sha256) {
        return None;
    }
    let role = raw.role.trim().to_string();
    // The role vocabulary is the pack format's and is not the shop's to
    // extend: a role we cannot place is a file we cannot draw.
    Role::parse(&role).ok()?;
    let dim = |v: Option<f64>| -> u32 {
        v.filter(|n| n.is_finite() && *n > 0.0)
            .map(|n| n.min(u32::MAX as f64) as u32)
            .unwrap_or(0)
    };
    Some(ShopFile {
        role,
        sha256,
        bytes: if raw.bytes.is_finite() && raw.bytes > 0.0 {
            raw.bytes.min(u64::MAX as f64) as u64
        } else {
            0
        },
        w: dim(raw.w),
        h: dim(raw.h),
        animated: raw.animated,
    })
}

fn sanitize_listing(raw: RawListing, origin: &str) -> Option<ShopListing> {
    let slug = clamp(&raw.slug, 64);
    if !valid_slug(&slug) {
        return None;
    }
    let title = clamp(&raw.title, 200);
    if title.is_empty() {
        return None;
    }

    let files: Vec<ShopFile> = raw.files.into_iter().filter_map(sanitize_file).collect();
    if files.is_empty() {
        // A piece with no picture cannot be hung, and a card with a broken
        // image is worse than a wall that is one item shorter.
        return None;
    }

    // Declared kinds first, narrowed to the three that exist and deduped into
    // the fixed order. A wall that reshuffles between two loads is not a wall.
    let declared: Vec<String> = raw.kinds.iter().map(|k| k.trim().to_string()).collect();
    let mut kinds: Vec<String> = KIND_ORDER
        .iter()
        .filter(|k| declared.iter().any(|d| d == *k))
        .map(|k| k.to_string())
        .collect();
    if kinds.is_empty() {
        // The files get the last word.
        kinds = KIND_ORDER
            .iter()
            .filter(|k| files.iter().any(|f| kind_of_role(&f.role) == Some(**k)))
            .map(|k| k.to_string())
            .collect();
    }

    let display = display_file_for(&kinds, &files, false)?;
    let display_hash = display.sha256.clone();
    let wide = display.w > 0 && display.h > 0 && display.w as f64 / display.h as f64 >= 2.0;
    let still_hash = display_file_for(&kinds, &files, true)
        .map(|f| f.sha256.clone())
        .filter(|h| *h != display_hash)
        .unwrap_or_default();
    let primary_kind = primary_kind_of(&kinds, &files)
        .unwrap_or_default()
        .to_string();

    let price_cents = if raw.price_cents.is_finite() {
        raw.price_cents.round().clamp(0.0, u32::MAX as f64) as u32
    } else {
        0
    };
    // A "was" that is not above the price is not a sale, whatever the shop
    // sent: the card would strike through a number the buyer never saves.
    let was_cents = if raw.was_cents.is_finite() {
        let w = raw.was_cents.round().clamp(0.0, u32::MAX as f64) as u32;
        if w > price_cents { w } else { 0 }
    } else {
        0
    };

    let artist_slug = clamp(&raw.artist.slug, 64);
    let artist = ShopArtist {
        url: if valid_slug(&artist_slug) {
            format!("{origin}/@{artist_slug}")
        } else {
            // A slug we will not build a URL out of costs the listing its
            // artist link, never the listing.
            String::new()
        },
        slug: artist_slug,
        display_name: clamp(&raw.artist.display_name, 200),
        bio: clamp(&raw.artist.bio, 4000),
        header_hash: raw
            .artist
            .header_hash
            .map(|h| h.trim().to_string())
            .filter(|h| valid_emote_hash(h))
            .unwrap_or_default(),
    };

    Some(ShopListing {
        credential_item: if valid_emote_hash(&raw.item) { raw.item.clone() } else { String::new() },
        item_url: if valid_slug(&slug) {
            format!("{origin}/item/{slug}")
        } else {
            // A slug we will not paste into a URL leaves the hash link, which
            // the shop redirects to the listing it best matches.
            format!("{origin}/item/{display_hash}")
        },
        bundle: kinds.len() >= 2,
        slug,
        title,
        description: clamp(&raw.description, 4000),
        kinds,
        price_cents,
        price_label: price_label(price_cents),
        was_cents,
        was_label: if was_cents > 0 { price_label(was_cents) } else { String::new() },
        license: clamp(&raw.license, 1000),
        created_at: clamp(&raw.created_at, 64),
        artist,
        files,
        display_hash,
        still_hash,
        primary_kind,
        wide,
    })
}

/// Turn one `/api/catalog.json` body into a catalog. Split from the fetch so
/// the shop's shape is testable without network.
pub(crate) fn parse_catalog(body: &[u8], origin: &str) -> Result<ShopCatalog, String> {
    let raw: RawCatalog = serde_json::from_slice(body)
        .map_err(|e| format!("The shop sent a catalog Hollow could not read: {e}"))?;
    Ok(ShopCatalog {
        origin: origin.to_string(),
        generated_at: clamp(&raw.generated_at, 64),
        listings: raw
            .listings
            .into_iter()
            .filter_map(|l| sanitize_listing(l, origin))
            .collect(),
    })
}

// ── Fetching ──────────────────────────────────────────────────────────

/// The one HTTP client every shop request is made with.
///
/// Two things are pinned here and nowhere else.
///
/// The User-Agent is plain and honest: the shop's logs are the shop's, and an
/// app that lies about what it is cannot be blocked by a keeper who needs to.
///
/// Redirects are REFUSED outright. [`shop_origin`] is a pinned address, and a
/// pinned origin that follows a 3xx is not pinned: whoever answers on it could
/// walk the app to any host it liked, and `fetch_shop_art` would then be a
/// general-purpose fetcher wearing the shop's name. A redirect surfaces
/// through the ordinary status path instead, as "The shop answered with status
/// 301". The shop serves https and redirects nothing, so this costs a live
/// request nothing.
fn shop_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .user_agent(format!("Hollow/{}", super::updater::APP_VERSION))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| format!("Hollow could not start the request: {e}"))
}

/// GET `url` with a body cap that is checked BEFORE the body is read
/// (Content-Length) and again as it arrives, so a server that lies about its
/// length still cannot make us allocate past the cap.
async fn fetch_bounded(
    client: &reqwest::Client,
    url: &str,
    timeout_secs: u64,
    max_bytes: usize,
    accept: Option<&str>,
) -> Result<Vec<u8>, String> {
    let mut req = client
        .get(url)
        .timeout(std::time::Duration::from_secs(timeout_secs));
    if let Some(a) = accept {
        req = req.header(reqwest::header::ACCEPT, a);
    }
    let resp = req
        .send()
        .await
        .map_err(|e| format!("The shop could not be reached: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!(
            "The shop answered with status {}",
            resp.status().as_u16()
        ));
    }
    read_bounded(resp, max_bytes).await
}

/// Read a response body under a cap: Content-Length first, then every chunk.
async fn read_bounded(resp: reqwest::Response, max_bytes: usize) -> Result<Vec<u8>, String> {
    use futures_util::StreamExt;

    if let Some(len) = resp.content_length()
        && len > max_bytes as u64
    {
        return Err("The shop sent more than Hollow will read".into());
    }
    let mut out: Vec<u8> = Vec::new();
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("The shop could not be reached: {e}"))?;
        if out.len() + chunk.len() > max_bytes {
            return Err("The shop sent more than Hollow will read".into());
        }
        out.extend_from_slice(&chunk);
    }
    Ok(out)
}

/// Fetch the shop's public catalog.
///
/// Runs on [`get_http_runtime`], never the node runtime: reqwest resolves DNS
/// on its runtime's blocking pool and the node's is routinely saturated by
/// SQLCipher bursts, so a shared runtime turns a browse into a stall.
#[frb]
pub fn fetch_shop_catalog() -> Result<ShopCatalog, String> {
    let origin = shop_origin();
    let url = format!("{origin}/api/catalog.json");
    let rt = get_http_runtime();
    let body = rt.block_on(async move {
        let client = shop_client()?;
        fetch_bounded(
            &client,
            &url,
            15,
            MAX_CATALOG_BYTES,
            Some("application/json"),
        )
        .await
    })?;
    parse_catalog(&body, &origin)
}

/// Check bytes that arrived from the shop against the hash that named them.
///
/// Content addressing IS the integrity check here, exactly as it is on the
/// asset rail: the shop hands out `/art/<sha256>`, so bytes that do not hash
/// to that address are not the art, whatever answered. The container check on
/// top of it keeps a non-WebP from ever reaching a decoder that assumes one.
pub(crate) fn check_art_bytes(hash: &str, bytes: &[u8]) -> Result<(), String> {
    if hex::encode(Sha256::digest(bytes)) != hash {
        return Err("The shop sent art that does not match its hash".into());
    }
    if bytes.len() < 16 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WEBP" {
        return Err("The shop sent art that is not a WebP image".into());
    }
    Ok(())
}

/// Fetch one piece of preview art by its hash.
///
/// The bytes are RETURNED and stored nowhere. Preview art is not owned art: it
/// arrives with no pack, no licence and no provenance, and the rail is for
/// things this install actually has. The caller renders it and lets it go.
#[frb]
pub fn fetch_shop_art(hash: String) -> Result<Vec<u8>, String> {
    if !valid_emote_hash(&hash) {
        return Err("That is not a shop art address".into());
    }
    let origin = shop_origin();
    let url = format!("{origin}/art/{hash}");
    let rt = get_http_runtime();
    let bytes = rt.block_on(async move {
        let client = shop_client()?;
        fetch_bounded(&client, &url, 20, MAX_FILE_BYTES, None).await
    })?;
    check_art_bytes(&hash, &bytes)?;
    Ok(bytes)
}

// ── Kept redeem codes ─────────────────────────────────────────────────

/// One redeem code this install is holding on to.
#[derive(Debug, Clone)]
pub struct KeptRedeemCode {
    pub code: String,
    /// Unix milliseconds.
    pub received_at: i64,
}

/// The shape a Creem license key takes, and the whole gate on a deep link.
///
/// `hollow://redeem/<code>` is remote-authored: anyone can put that link
/// anywhere and get a click. Nothing downstream parses the code, so the shape
/// check plus the row cap is the entire attack surface, and it stays that way
/// until phase 2 gives the code a meaning.
pub(crate) fn valid_redeem_code(code: &str) -> bool {
    (8..=128).contains(&code.len())
        && code
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// Keep a redeem code from a `hollow://redeem/<code>` link.
///
/// Returns whether it was newly kept; a code kept twice is a no-op rather than
/// an error, because the buyer clicking their thank-you link again is not a
/// mistake they should see a toast about.
#[frb]
pub fn keep_redeem_code(code: String) -> Result<bool, String> {
    let code = code.trim().to_string();
    if !valid_redeem_code(&code) {
        return Err("That does not look like a redeem code".into());
    }
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    // Already kept beats the cap: re-clicking a link the buyer already used
    // must never be the thing that gets refused.
    if ms.list_redeem_codes()?.iter().any(|(c, _)| *c == code) {
        return Ok(false);
    }
    if ms.count_redeem_codes()? >= MAX_KEPT_REDEEM_CODES {
        return Err(format!(
            "Hollow already keeps {MAX_KEPT_REDEEM_CODES} codes; forget one first"
        ));
    }
    ms.save_redeem_code(&code)
}

/// Every kept redeem code, newest first.
#[frb]
pub fn list_redeem_codes() -> Result<Vec<KeptRedeemCode>, String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    Ok(ms
        .list_redeem_codes()?
        .into_iter()
        .map(|(code, received_at)| KeptRedeemCode { code, received_at })
        .collect())
}

/// Forget one kept redeem code.
#[frb]
pub fn forget_redeem_code(code: String) -> Result<(), String> {
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    ms.delete_redeem_code(code.trim())
}

// ── Support credentials: redeem (phase 2) ─────────────────────────────
//
// The one WRITE this module makes against the shop: redeeming a Creem license
// key into a support credential (design 5.3, 12.6, 13.23). Two round trips,
// no cookies, no identity in the clear:
//
//   POST /api/redeem/lookup {code}     the listing's public facts and its
//                                      issuing key chain; nothing burns
//   POST /api/redeem {code, blinded}   the blind signature and a one-shot
//                                      token for the pack; the code burns
//   GET  /api/redeem/pack/<token>      the .hollowpack, once
//
// The identity never leaves this machine: the shop signs a BLINDED message
// and cannot tell which master peer id it vouched for. What comes back is
// verified against the root key pinned in `support_creds.rs` before it is
// kept, and it is kept BEFORE the pack is fetched, because after the second
// round trip the code is spent and the credential is the thing that was
// bought. A pack that fails to arrive is a sentence in the outcome, not a
// lost purchase: the Creem download carries the same pack.

use crate::node::support_creds::{
    self, CredentialEntry, T_ITEM, T_TWITCH_FOLLOW, T_TWITCH_OWNER,
};

/// The largest `.hollowpack` the redeem path will read: eight files at the
/// per-file cap, with room.
const MAX_PACK_BYTES: usize = 40 * 1024 * 1024;

/// `app_settings` key: whether OUR credentials carry the next-to-name badge
/// (design 5.6, off by default). New credentials inherit it.
pub(crate) const SUPPORT_BADGE_SETTING: &str = "support_badge";

/// `app_settings` key: the union this device published just before it hid,
/// so a hide and an unhide round-trip even on a device whose own
/// `support_creds_own` table is empty. Cleared once an unhide has written
/// the marks back onto our profile row.
pub(crate) const SUPPORT_SHELF_SETTING: &str = "support_creds_shelf";

/// `app_settings` key: a JSON array of item hashes this device has removed.
/// Local, because the table it shadows is local: it stops a copy of the same
/// credential arriving on our own profile row from a sibling's announce and
/// quietly bringing the mark back.
pub(crate) const SUPPORT_REMOVED_SETTING: &str = "support_creds_removed";

/// `app_settings` key: whether this device holds our marks back entirely.
///
/// Local to this device and NEVER on the wire. A hidden holder announces the
/// explicit clear (`""`), which every receiver already reads as "no
/// credentials"; there is no flag for a viewer to ignore, and no way for one
/// to tell a holder who is hiding from a holder who never bought anything.
/// The `support_creds_own` records are untouched, so switching it back
/// republishes exactly what was there.
pub(crate) const SUPPORT_HIDDEN_SETTING: &str = "support_hidden";

/// What `redeem_lookup` learned about a code.
#[derive(Debug, Clone)]
pub struct RedeemLookup {
    /// `ok`, or why not: `refused` (refunded), `burned` (already redeemed),
    /// `unknown` (not a key this shop sold), `nokey` (listed before
    /// credentials existed; the keeper can fix it).
    pub status: String,
    /// The shop's sentence when `status` is not `ok`.
    pub message: String,
    pub slug: String,
    pub title: String,
    pub artist_name: String,
    pub artist_slug: String,
    pub item_url: String,
    pub kinds: Vec<String>,
    /// The credential's item hash, 64-hex, once `ok`.
    pub item: String,
    /// The file hashes the credential will vouch for.
    pub parts: Vec<String>,
    /// This identity already holds a credential for this item (13.23): a
    /// second redemption changes nothing, keep the code and gift it.
    pub already_supported: bool,
}

/// What redeeming landed.
#[derive(Debug, Clone)]
pub struct RedeemOutcome {
    /// The credential's item hash. The mark is saved and announced.
    pub item: String,
    pub title: String,
    pub artist_name: String,
    /// The pack, imported, when it arrived; `None` with `pack_error` set
    /// when it did not. The credential is kept either way.
    pub imported: Option<super::network::HollowpackImport>,
    pub pack_error: String,
    /// Something to say that is not a failure: the pack's files and the
    /// credential's parts did not agree, say.
    pub warning: String,
}

/// One of OUR credentials, for Settings.
#[derive(Debug, Clone)]
pub struct OwnSupportCred {
    pub item: String,
    pub parts: Vec<String>,
    pub slug: String,
    pub title: String,
    pub artist_name: String,
    /// Unix milliseconds.
    pub redeemed_at: i64,
    pub badge: bool,
}

// Wire shapes, tolerant like the catalog's.

#[frb(ignore)]
#[derive(Debug, Default, Deserialize)]
struct RawLookup {
    #[serde(default, deserialize_with = "lenient")]
    status: String,
    #[serde(default, deserialize_with = "lenient")]
    message: String,
    #[serde(default, deserialize_with = "lenient")]
    listing: RawLookupListing,
}

#[frb(ignore)]
#[derive(Debug, Default, Deserialize)]
struct RawLookupListing {
    #[serde(default, deserialize_with = "lenient")]
    slug: String,
    #[serde(default, deserialize_with = "lenient")]
    title: String,
    #[serde(default, deserialize_with = "lenient")]
    url: String,
    #[serde(default, deserialize_with = "lenient_vec")]
    kinds: Vec<String>,
    #[serde(default, deserialize_with = "lenient")]
    artist: RawArtist,
    #[serde(default, deserialize_with = "lenient")]
    item: String,
    #[serde(default, deserialize_with = "lenient_vec")]
    parts: Vec<String>,
    #[serde(default, deserialize_with = "lenient")]
    key: String,
    #[serde(default, deserialize_with = "lenient")]
    key_sig: String,
    #[serde(default, deserialize_with = "lenient")]
    issuer: String,
    #[serde(default, deserialize_with = "lenient")]
    issuer_sig: String,
}

#[frb(ignore)]
#[derive(Debug, Default, Deserialize)]
struct RawRedeem {
    #[serde(default, deserialize_with = "lenient")]
    blind_sig: String,
    #[serde(default, deserialize_with = "lenient")]
    pack_token: String,
    #[serde(default, deserialize_with = "lenient")]
    message: String,
}

/// POST a JSON body and read a bounded answer. The status rides back with
/// the bytes: a refusal is a sentence in a 4xx body and the caller wants it.
async fn post_json_bounded(
    client: &reqwest::Client,
    url: &str,
    body: &serde_json::Value,
    timeout_secs: u64,
    max_bytes: usize,
) -> Result<(u16, Vec<u8>), String> {
    let req = client
        .post(url)
        .timeout(std::time::Duration::from_secs(timeout_secs))
        .header(reqwest::header::ACCEPT, "application/json")
        .json(body);
    let resp = req
        .send()
        .await
        .map_err(|e| format!("The shop could not be reached: {e}"))?;
    let status = resp.status().as_u16();
    let bytes = read_bounded(resp, max_bytes).await?;
    Ok((status, bytes))
}

/// The sentence in a JSON error body, or the status when there is none.
fn shop_refusal(status: u16, body: &[u8]) -> String {
    let said = serde_json::from_slice::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v.get("message").and_then(|m| m.as_str()).map(|s| clamp(s, 300)))
        .filter(|s| !s.is_empty());
    said.unwrap_or_else(|| format!("The shop answered with status {status}"))
}

async fn lookup_remote(origin: &str, code: &str) -> Result<RawLookup, String> {
    let client = shop_client()?;
    let url = format!("{origin}/api/redeem/lookup");
    let (status, body) =
        post_json_bounded(&client, &url, &serde_json::json!({ "code": code }), 15, 256 * 1024).await?;
    if status == 429 {
        return Err("The shop is asking for a pause; try again in a few minutes".into());
    }
    if !(200..300).contains(&status) {
        return Err(shop_refusal(status, &body));
    }
    serde_json::from_slice::<RawLookup>(&body)
        .map_err(|e| format!("The shop's answer could not be read: {e}"))
}

async fn redeem_remote(origin: &str, code: &str, blinded: &[u8]) -> Result<RawRedeem, String> {
    let client = shop_client()?;
    let url = format!("{origin}/api/redeem");
    let body = serde_json::json!({ "code": code, "blinded": B64.encode(blinded) });
    let (status, answer) = post_json_bounded(&client, &url, &body, 40, 256 * 1024).await?;
    if status == 429 {
        return Err("The shop is asking for a pause; try again in a few minutes".into());
    }
    if !(200..300).contains(&status) {
        return Err(shop_refusal(status, &answer));
    }
    let parsed = serde_json::from_slice::<RawRedeem>(&answer)
        .map_err(|e| format!("The shop's answer could not be read: {e}"))?;
    if parsed.blind_sig.is_empty() {
        return Err("The shop answered without a signature".into());
    }
    Ok(parsed)
}

async fn fetch_pack(origin: &str, token: &str) -> Result<Vec<u8>, String> {
    if token.is_empty() || token.len() > 128 || !token.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err("The shop sent no usable pack token".into());
    }
    let client = shop_client()?;
    let url = format!("{origin}/api/redeem/pack/{token}");
    fetch_bounded(&client, &url, 60, MAX_PACK_BYTES, None).await
}

/// The sentence for a lookup that is not `ok`.
fn lookup_refusal(looked: &RawLookup) -> String {
    if !looked.message.is_empty() {
        return clamp(&looked.message, 300);
    }
    match looked.status.as_str() {
        "refused" => "This code was refunded, so it cannot be redeemed".into(),
        "burned" => "This code has already been redeemed".into(),
        "nokey" => "This item was listed before support marks existed; the shop keeper can add its key".into(),
        "unknown" => "The shop does not know this code".into(),
        other => format!("The shop would not redeem this code ({other})"),
    }
}

/// Our master peer id, which the credential binds. The node has to be up:
/// the profile that carries the mark is announced through it.
fn my_master_peer_id() -> Result<String, String> {
    super::network::get_local_peer_id().ok_or_else(|| "Hollow is still starting; try again in a moment".to_string())
}

/// The holder's badge preference, inherited by every new credential. ON
/// until switched off (Vitalik, 2026-09-02: a mark is a badge), so an
/// absent setting reads as on.
fn support_badge_preference() -> bool {
    let store = get_store();
    let Ok(guard) = store.lock() else { return true };
    let Some(ms) = guard.as_ref() else { return true };
    badge_on(ms.load_setting(SUPPORT_BADGE_SETTING).ok().flatten().as_deref())
}

/// The setting's reading: only an explicit "0" switches the badge off.
pub(crate) fn badge_on(setting: Option<&str>) -> bool {
    setting != Some("0")
}

/// The hide setting's reading: only an explicit "1" hides. An absent setting
/// is a holder who never touched the switch, and their marks show.
pub(crate) fn hidden_on(setting: Option<&str>) -> bool {
    setting == Some("1")
}

/// A lookup answer after which the code is worth nothing to anyone: the
/// shop burned it, refunded it, or has never heard of it. `nokey` (listed
/// before support marks existed), `paused` and `rail` are not on this list,
/// because the same code answers `ok` once the shop is ready.
pub(crate) fn lookup_status_is_dead(status: &str) -> bool {
    matches!(status, "burned" | "refused" | "unknown")
}

/// Look a code up: what it buys, and whether this identity already supports
/// it. Nothing burns.
#[frb]
pub fn redeem_lookup(code: String) -> Result<RedeemLookup, String> {
    let code = code.trim().to_string();
    if !valid_redeem_code(&code) {
        return Err("That does not look like a redeem code".into());
    }
    let origin = shop_origin();
    let looked = get_http_runtime().block_on(lookup_remote(&origin, &code))?;
    let status = clamp(&looked.status, 16);
    if lookup_status_is_dead(&status) {
        // A kept code the shop will never honour again does not sit in
        // "Codes kept for later" (Vitalik, 2026-09-02). Best effort: the
        // answer is the thing, and the code may never have been kept.
        let _ = forget_redeem_code(code.clone());
    }
    let l = &looked.listing;
    let already_supported = if status == "ok" && valid_emote_hash(&l.item) {
        let store = get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        ms.list_own_support_creds()?.iter().any(|(item, ..)| *item == l.item)
    } else {
        false
    };
    Ok(RedeemLookup {
        message: if status == "ok" { String::new() } else { lookup_refusal(&looked) },
        status,
        slug: clamp(&l.slug, 64),
        title: clamp(&l.title, 120),
        artist_name: clamp(&l.artist.display_name, 80),
        artist_slug: clamp(&l.artist.slug, 64),
        item_url: if l.url.starts_with(&origin) { clamp(&l.url, 200) } else { String::new() },
        kinds: l.kinds.iter().filter(|k| KIND_ORDER.contains(&k.as_str())).cloned().collect(),
        item: if valid_emote_hash(&l.item) { l.item.clone() } else { String::new() },
        parts: l.parts.iter().filter(|p| valid_emote_hash(p)).cloned().collect(),
        already_supported,
    })
}

/// Redeem a code: mint the credential, keep it, announce it, then fetch and
/// import the pack.
///
/// Order matters. The chain the shop published is verified against the
/// pinned root BEFORE the code is spent, so a shop with a broken key never
/// burns a purchase. The credential is stored and announced BEFORE the pack
/// is fetched, so a network hiccup after the burn costs a download the buyer
/// also has in their email, never the mark.
#[frb]
pub fn redeem_code(code: String) -> Result<RedeemOutcome, String> {
    let code = code.trim().to_string();
    if !valid_redeem_code(&code) {
        return Err("That does not look like a redeem code".into());
    }
    let master = my_master_peer_id()?;
    let origin = shop_origin();
    let rt = get_http_runtime();
    let root = support_creds::root_verifying_key();

    // 1. What the code buys, and the key that will sign for it.
    let looked = rt.block_on(lookup_remote(&origin, &code))?;
    if looked.status != "ok" {
        return Err(lookup_refusal(&looked));
    }
    let l = looked.listing;
    let chain = support_creds::verify_chain(
        T_ITEM, &l.item, &l.parts, 0, &l.key, &l.key_sig, &l.issuer, &l.issuer_sig, &root,
    )
    .map_err(|e| format!("The shop's signing key did not check out, so nothing was redeemed: {e}"))?;

    // 2. Blind. From here the shop sees a number, never who we are.
    let request = support_creds::blind_request(&chain.key_der, T_ITEM, &master, &chain.item, 0)?;

    // 3. Redeem. This is the burn.
    let answer = rt.block_on(redeem_remote(&origin, &code, &request.blinded))?;
    let blind_sig = B64
        .decode(answer.blind_sig.trim())
        .map_err(|_| "The shop's signature is not base64".to_string())?;

    // 4. Unblind, then verify the whole entry exactly as a viewer will.
    let sig = support_creds::finish_request(&chain.key_der, &request, &blind_sig)?;
    let entry = CredentialEntry {
        t: T_ITEM,
        item: l.item.clone(),
        period: 0,
        parts: chain.parts.clone(),
        key: l.key,
        key_sig: l.key_sig,
        issuer: l.issuer,
        issuer_sig: l.issuer_sig,
        sig: B64.encode(&sig),
        badge: support_badge_preference(),
    };
    support_creds::verify_entry(&entry, &master, &root)
        .map_err(|e| format!("The credential the shop returned does not verify: {e}"))?;

    // 5. Keep it, then say so to everyone.
    let title = clamp(&l.title, 120);
    let artist_name = clamp(&l.artist.display_name, 80);
    keep_own_credential(&entry, &clamp(&l.slug, 64), &title, &artist_name)?;
    let _ = forget_redeem_code(code);

    // 6. The pack, through the one import door.
    let (imported, pack_error) = match rt.block_on(fetch_pack(&origin, &answer.pack_token)) {
        Ok(bytes) => match super::network::import_hollowpack_bytes(&bytes) {
            Ok(i) => (Some(i), String::new()),
            Err(e) => (None, e),
        },
        Err(e) => (None, e),
    };
    let warning = match &imported {
        Some(i) => {
            let pack_hashes: Vec<&str> = i.files.iter().map(|f| f.hash.as_str()).collect();
            if chain.parts.iter().any(|p| !pack_hashes.contains(&p.as_str())) {
                "The pack does not carry every file the credential names, so the mark may not light for all of it".into()
            } else {
                String::new()
            }
        }
        None => String::new(),
    };
    Ok(RedeemOutcome { item: entry.item, title, artist_name, imported, pack_error, warning })
}

/// Keep one of our credentials and republish the profile field.
fn keep_own_credential(entry: &CredentialEntry, slug: &str, title: &str, artist_name: &str) -> Result<(), String> {
    {
        let store = get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        keep_own_cred_row(ms, entry, slug, title, artist_name)?;
    }
    republish_support_creds()
}

/// The item hashes this device has removed, newest last.
fn removed_items(ms: &crate::storage::MessageStore) -> Vec<String> {
    let raw = ms
        .load_setting(SUPPORT_REMOVED_SETTING)
        .ok()
        .flatten()
        .unwrap_or_default();
    serde_json::from_str::<Vec<String>>(&raw).unwrap_or_default()
}

fn save_removed_items(
    ms: &crate::storage::MessageStore,
    items: &[String],
) -> Result<(), String> {
    let json = serde_json::to_string(items).map_err(|e| e.to_string())?;
    ms.save_setting(SUPPORT_REMOVED_SETTING, &json)
}

/// One credential this device can vouch for, with whatever names it has.
#[frb(ignore)]
struct UnionEntry {
    entry: CredentialEntry,
    slug: String,
    title: String,
    artist_name: String,
    /// Unix milliseconds, 0 for an entry this device did not mint.
    redeemed_at: i64,
}

/// Everything this identity holds, as far as THIS device can tell: the rows
/// it minted itself (with their names), then the shelf a hide put aside, then
/// whatever a sibling's announce wrote onto our own profile row. Deduplicated
/// by item with the first source winning, and minus the items this device has
/// removed.
///
/// The profile row is the bridge between devices. `support_creds_own` is
/// per-device and does not replicate, so without the row a sibling that
/// redeemed one item would republish its own single row and wipe every mark
/// the other device minted, for everyone. Nothing is trusted for being in the
/// row: [`support_creds::keep_verified`] still drops every entry not signed
/// for THIS master, so a transplanted entry someone pasted onto our profile
/// never rides our announce.
///
/// The one edge that stays: a mark removed on a device that did not mint it
/// comes back if the MINTING device republishes later, because the tombstone
/// is local and the table does not replicate. Removing it on the device that
/// holds the row is final. A replicating table is a later unit.
fn own_credential_union(
    ms: &crate::storage::MessageStore,
    master: &str,
) -> Result<Vec<UnionEntry>, String> {
    let removed = removed_items(ms);
    let mut out: Vec<UnionEntry> = Vec::new();
    let mut seen: Vec<String> = Vec::new();

    for (item, entry_json, slug, title, artist_name, redeemed_at) in
        ms.list_own_support_creds()?
    {
        if removed.contains(&item) || seen.contains(&item) {
            continue;
        }
        let Ok(entry) = serde_json::from_str::<CredentialEntry>(&entry_json) else {
            continue;
        };
        seen.push(item);
        out.push(UnionEntry { entry, slug, title, artist_name, redeemed_at });
    }

    let shelf = ms
        .load_setting(SUPPORT_SHELF_SETTING)
        .ok()
        .flatten()
        .unwrap_or_default();
    let row = ms
        .load_profile(master)?
        .map(|p| p.support_creds)
        .unwrap_or_default();
    for json in [shelf, row] {
        for entry in support_creds::parse_stored(&json) {
            if removed.contains(&entry.item) || seen.contains(&entry.item) {
                continue;
            }
            seen.push(entry.item.clone());
            out.push(UnionEntry {
                entry,
                slug: String::new(),
                title: String::new(),
                artist_name: String::new(),
                redeemed_at: 0,
            });
        }
    }
    Ok(out)
}

/// The `support_creds` field this device should publish right now.
///
/// Split out of [`republish_support_creds`] so the rule is testable without a
/// running node: the announce needs one, this does not.
pub(crate) fn published_creds_json(
    ms: &crate::storage::MessageStore,
    master: &str,
) -> Result<String, String> {
    if hidden_on(ms.load_setting(SUPPORT_HIDDEN_SETTING).ok().flatten().as_deref()) {
        // "Hide my support marks" is about the SHOP marks (t = 1 and 2), so
        // the filter is by type, not a clear of the whole field: a verified
        // Twitch account is a different claim on the same field and its chip
        // keeps showing. With no Twitch entry this is still the explicit
        // clear, which is exactly what a holder with no credentials at all
        // announces, so hiding stays indistinguishable from never having
        // bought anything. The records stay where they are, and the shelf
        // holds the rest.
        let kept: Vec<CredentialEntry> = support_creds::parse_stored(&union_json(ms, master)?)
            .into_iter()
            .filter(|e| e.t == T_TWITCH_OWNER)
            .collect();
        return Ok(support_creds::encode_entries(&kept));
    }
    union_json(ms, master)
}

/// The union this device would publish if it were not hiding: verified,
/// deduplicated, capped and encoded.
///
/// Kept separate from [`published_creds_json`] because the shelf needs the
/// marks THEMSELVES, and asking the publish path for them while hiding is on
/// answers with the clear.
fn union_json(ms: &crate::storage::MessageStore, master: &str) -> Result<String, String> {
    // The glyph flag is decided HERE, from the setting, rather than read off
    // whatever the entry was stored with: the entry may have arrived on our
    // profile row from a device that answered the question differently, and
    // the switch has to work from whichever device the holder is sitting at.
    let badge = badge_on(ms.load_setting(SUPPORT_BADGE_SETTING).ok().flatten().as_deref());
    let entries: Vec<CredentialEntry> = own_credential_union(ms, master)?
        .into_iter()
        .map(|u| CredentialEntry { badge, ..u.entry })
        .collect();
    // The same filter every receiver applies, so what we announce is exactly
    // what they will keep: verified, one per item, capped.
    let kept = support_creds::keep_verified(entries, master, &support_creds::root_verifying_key());
    Ok(support_creds::encode_entries(&kept))
}

/// Recompute the field and write it onto our own profile row, handing back
/// what an announce should carry. The store half of
/// [`republish_support_creds`].
fn republish_to_row(
    ms: &crate::storage::MessageStore,
    master: &str,
) -> Result<String, String> {
    let json = published_creds_json(ms, master)?;
    let (name, status, about, updated_at, twitch) = match ms.load_profile(master)? {
        Some(p) => (p.display_name, p.status, p.about_me, p.updated_at, p.twitch_username),
        None => (String::new(), String::new(), String::new(), 0, String::new()),
    };
    ms.save_profile(
        master, &name, &status, &about, updated_at, None, None, &twitch, None, None, None, None,
        None, None, Some(&json),
    )?;
    Ok(json)
}

/// Hide or unhide, minus the announce. Split out so the round trip is
/// testable without a node.
///
/// Hiding shelves the union FIRST, because the clear wipes our own profile
/// row too and on a device whose table is empty the row was the only copy.
/// Unhiding republishes the union (the shelf is part of it) and only then
/// drops the shelf, so nothing is thrown away before it has been written
/// back.
///
/// The shelf is filled from [`union_json`], never from what we would publish,
/// and only on the way IN to hiding. A second hide while hiding is already on
/// (a retried toggle, another surface sending the same value, a double press)
/// would otherwise shelve the clear it publishes, and the next unhide on a
/// device with an empty table would find nothing and announce the clear for
/// good.
fn apply_hidden(
    ms: &crate::storage::MessageStore,
    master: &str,
    hidden: bool,
) -> Result<String, String> {
    let already_hidden =
        hidden_on(ms.load_setting(SUPPORT_HIDDEN_SETTING).ok().flatten().as_deref());
    if hidden && !already_hidden {
        let shelved = union_json(ms, master)?;
        ms.save_setting(SUPPORT_SHELF_SETTING, &shelved)?;
    }
    ms.save_setting(SUPPORT_HIDDEN_SETTING, if hidden { "1" } else { "0" })?;
    let json = republish_to_row(ms, master)?;
    if !hidden {
        ms.save_setting(SUPPORT_SHELF_SETTING, "")?;
    }
    Ok(json)
}

/// Forget one mark on this device: drop the row it minted, if it minted one,
/// and remember that we did. The store half of [`remove_own_support_cred`].
fn forget_own_cred(ms: &crate::storage::MessageStore, item: &str) -> Result<(), String> {
    ms.delete_own_support_cred(item)?;
    // Only a real item hash earns a tombstone, so the setting cannot be grown
    // by a caller passing junk.
    if !valid_emote_hash(item) {
        return Ok(());
    }
    let mut removed = removed_items(ms);
    if removed.iter().any(|i| i == item) {
        return Ok(());
    }
    removed.push(item.to_string());
    save_removed_items(ms, &removed)
}

/// Keep one of our credentials on this device.
///
/// A fresh redemption of something this device had removed means the holder
/// wants it back, so the tombstone goes with it.
fn keep_own_cred_row(
    ms: &crate::storage::MessageStore,
    entry: &CredentialEntry,
    slug: &str,
    title: &str,
    artist_name: &str,
) -> Result<(), String> {
    let json = serde_json::to_string(entry).map_err(|e| e.to_string())?;
    ms.save_own_support_cred(&entry.item, &json, slug, title, artist_name)?;
    let removed = removed_items(ms);
    if removed.contains(&entry.item) {
        let kept: Vec<String> = removed.into_iter().filter(|i| *i != entry.item).collect();
        save_removed_items(ms, &kept)?;
    }
    Ok(())
}

/// Ask the node to announce `json` as our `support_creds`.
///
/// Best effort by design: the row is already written, and the next profile
/// save carries the field if the node is not up at this moment.
pub(crate) fn announce_support_creds(master: &str, json: String) -> Result<(), String> {
    let cmd_tx = {
        let node = super::network::get_node();
        let guard = node.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        guard.as_ref().map(|s| s.cmd_tx.clone())
    };
    let Some(tx) = cmd_tx else { return Ok(()) };
    let (display_name, status, about_me, twitch_username) = {
        let store = get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        match ms.load_profile(master)? {
            Some(p) => (p.display_name, p.status, p.about_me, p.twitch_username),
            None => (String::new(), String::new(), String::new(), String::new()),
        }
    };
    let sent = super::network::get_runtime().block_on(tx.send(
        crate::node::NodeCommand::UpdateProfile {
            display_name,
            status,
            about_me,
            avatar_bytes: None,
            banner_bytes: None,
            twitch_username,
            showcase_board: None,
            showcase_assets: None,
            avatar_frame: None,
            avatar_anim: None,
            banner_anim: None,
            support_creds: Some(json),
        },
    ));
    if sent.is_err() {
        hollow_log!("[HOLLOW-SHOP] The support credential is kept; the announce waits for the next profile save");
    }
    Ok(())
}

/// Rebuild our `support_creds` profile field, write it onto our profile row,
/// and ask the node to announce it.
///
/// The row is written HERE, not only by the node: a later profile save from
/// the UI passes `None` (preserve) for this field and reads the row, so the
/// row has to be right even if the node is down at this moment.
fn republish_support_creds() -> Result<(), String> {
    let master = my_master_peer_id()?;
    let json = {
        let store = get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        republish_to_row(ms, &master)?
    };
    announce_support_creds(&master, json)
}


// ── Twitch credentials: the shop as an OAuth verifier ─────────────────
//
// The same chain as a redeemed mark, a different check at the top: instead of
// a Creem licence key the shop validates a Twitch access token, reads the
// facts Twitch itself reports, and blind-signs them under a key for exactly
// that `(type, item, period)`. Two round trips, same shape as redeem:
//
//   POST /api/twitch/key     what the credential will say, and the chain
//                            that will sign it; nothing is spent
//   POST /api/twitch/verify  the blind signature over OUR master id
//
// The shop learns "login X (id Y) is verified in window N" or "user Y follows
// channel Z at bucket B, tier T". It never learns a Hollow identity: the
// message it signs is blinded. We learn nothing we have to trust: the chain
// is checked against the root pinned in `support_creds.rs` BEFORE the second
// round trip, and the finished entry is verified exactly as a viewer will.

/// The `/api/twitch/key` answer.
#[frb(ignore)]
#[derive(Debug, Default, Deserialize)]
pub(crate) struct RawTwitchKey {
    #[serde(default)]
    t: u8,
    #[serde(default, deserialize_with = "lenient")]
    item: String,
    #[serde(default, deserialize_with = "lenient_vec")]
    parts: Vec<String>,
    #[serde(default)]
    period: u32,
    #[serde(default, deserialize_with = "lenient")]
    key: String,
    #[serde(default, deserialize_with = "lenient")]
    key_sig: String,
    #[serde(default, deserialize_with = "lenient")]
    issuer: String,
    #[serde(default, deserialize_with = "lenient")]
    issuer_sig: String,
}

/// The two calls the Twitch flow makes, as a pair of closures.
///
/// Two closures rather than a trait for one reason: the bridge scans every
/// trait in `crate::api` and would generate a Dart class for this one, plus an
/// opaque type for the `Option<&str>` in it. Nothing here crosses the FFI.
/// The tests build one that answers from the TEST issuing keys, so the suite
/// never touches the network; [`TwitchVerifier::http`] is the real one.
#[frb(ignore)]
#[allow(clippy::type_complexity)] // two request shapes, spelled out once
pub(crate) struct TwitchVerifier<'a> {
    /// `(kind, token, broadcaster_id)` -> what the credential will say.
    key: Box<dyn Fn(&str, &str, Option<&str>) -> Result<RawTwitchKey, String> + 'a>,
    /// `(kind, token, broadcaster_id, item, period, blinded)` -> blind signature.
    sign: Box<dyn Fn(&str, &str, Option<&str>, &str, u32, &[u8]) -> Result<Vec<u8>, String> + 'a>,
}

/// The sentence for one of the contract's status words. The shop's own
/// message is used only for a word we do not know: these five are ours to
/// word, and they are what the user reads.
fn twitch_refusal(status: u16, body: &[u8]) -> String {
    let said = serde_json::from_slice::<serde_json::Value>(body).ok();
    let word = said
        .as_ref()
        .and_then(|v| v.get("status").and_then(|s| s.as_str()))
        .unwrap_or("");
    match word {
        "token" => "Twitch would not accept that sign in. Connect Twitch again.".into(),
        "not_following" => "Twitch says you do not follow that channel.".into(),
        "slow" => "The shop is asking for a pause; try again in a few minutes".into(),
        "rail" => "Twitch could not be reached, so nothing was verified. Try again shortly.".into(),
        "mismatch" => {
            "Twitch answered differently the second time, so nothing was signed. Try again.".into()
        }
        _ => shop_refusal(status, body),
    }
}

/// The common half of both request bodies.
fn twitch_request_body(
    kind: &str,
    token: &str,
    broadcaster_id: Option<&str>,
) -> serde_json::Map<String, serde_json::Value> {
    let mut body = serde_json::Map::new();
    body.insert("kind".into(), kind.into());
    body.insert("token".into(), token.into());
    if let Some(bid) = broadcaster_id {
        body.insert("broadcaster_id".into(), bid.into());
    }
    body
}

/// POST to the shop and read the bounded answer, or the sentence for its
/// status word.
fn twitch_post(origin: &str, path: &str, body: serde_json::Value) -> Result<Vec<u8>, String> {
    let url = format!("{origin}{path}");
    let client = shop_client()?;
    let (status, answer) =
        get_http_runtime().block_on(post_json_bounded(&client, &url, &body, 30, 64 * 1024))?;
    if !(200..300).contains(&status) {
        return Err(twitch_refusal(status, &answer));
    }
    Ok(answer)
}

impl TwitchVerifier<'static> {
    /// The real one, against the shop at `origin`.
    pub(crate) fn http(origin: String) -> Self {
        let key_origin = origin.clone();
        Self {
            key: Box::new(move |kind, token, bid| {
                let body =
                    serde_json::Value::Object(twitch_request_body(kind, token, bid));
                let answer = twitch_post(&key_origin, "/api/twitch/key", body)?;
                serde_json::from_slice::<RawTwitchKey>(&answer)
                    .map_err(|e| format!("The shop's answer could not be read: {e}"))
            }),
            sign: Box::new(move |kind, token, bid, item, period, blinded| {
                let mut body = twitch_request_body(kind, token, bid);
                body.insert("item".into(), item.into());
                body.insert("period".into(), period.into());
                body.insert("blinded".into(), B64.encode(blinded).into());
                let answer = twitch_post(
                    &origin,
                    "/api/twitch/verify",
                    serde_json::Value::Object(body),
                )?;
                #[derive(Deserialize)]
                struct Signed {
                    #[serde(default)]
                    blind_sig: String,
                }
                let parsed = serde_json::from_slice::<Signed>(&answer)
                    .map_err(|e| format!("The shop's answer could not be read: {e}"))?;
                if parsed.blind_sig.is_empty() {
                    return Err("The shop answered without a signature".into());
                }
                B64.decode(parsed.blind_sig.trim())
                    .map_err(|_| "The shop's signature is not base64".to_string())
            }),
        }
    }
}

/// Mint one Twitch credential for `master`.
///
/// Order matters, the same way it does for a redemption: the chain the shop
/// published is verified against the PINNED root before the second round trip
/// blinds anything, and the finished entry is verified exactly as a viewer
/// will before it is stored. A shop with a broken key gets a refusal here, not
/// a credential nobody can read.
pub(crate) fn mint_twitch_credential(
    verifier: &TwitchVerifier<'_>,
    kind: &str,
    token: &str,
    broadcaster_id: Option<&str>,
    master: &str,
) -> Result<CredentialEntry, String> {
    let t = if kind == "owner" { T_TWITCH_OWNER } else { T_TWITCH_FOLLOW };
    let answer = (verifier.key)(kind, token, broadcaster_id)?;
    if answer.t != t {
        return Err("The shop answered for a different kind of credential".into());
    }
    let root = support_creds::root_verifying_key();
    let chain = support_creds::verify_chain(
        t, &answer.item, &answer.parts, answer.period, &answer.key, &answer.key_sig,
        &answer.issuer, &answer.issuer_sig, &root,
    )
    .map_err(|e| format!("The shop's signing key did not check out, so nothing was verified: {e}"))?;
    // A follow credential has to be about the channel we asked about: the
    // owner's gate compares `parts[0]` to its own channel id, and a joiner
    // that shipped a credential for some other channel would simply be
    // refused with a confusing sentence.
    if broadcaster_id.is_some_and(|bid| chain.parts.first().map(String::as_str) != Some(bid)) {
        return Err("The shop answered about a different channel".into());
    }

    let request = support_creds::blind_request(&chain.key_der, t, master, &chain.item, answer.period)?;
    let blind_sig = (verifier.sign)(
        kind, token, broadcaster_id, &answer.item, answer.period, &request.blinded,
    )?;
    let sig = support_creds::finish_request(&chain.key_der, &request, &blind_sig)?;
    let entry = CredentialEntry {
        t,
        item: answer.item,
        period: answer.period,
        parts: chain.parts,
        key: answer.key,
        key_sig: answer.key_sig,
        issuer: answer.issuer,
        issuer_sig: answer.issuer_sig,
        sig: B64.encode(&sig),
        badge: false,
    };
    support_creds::verify_entry(&entry, master, &root)
        .map_err(|e| format!("The credential the shop returned does not verify: {e}"))?;
    Ok(entry)
}

/// Drop every verified-account credential this device holds except `keep`.
///
/// The cap is one, and [`support_creds::keep_verified`] keeps the FIRST that
/// verifies — so a stale entry for an account the holder no longer uses would
/// win over the fresh one. The tombstone goes with it, which is also what
/// stops a sibling's older announce putting the old account back on our row.
fn drop_other_twitch_owner_creds(
    ms: &crate::storage::MessageStore,
    master: &str,
    keep: Option<&str>,
) -> Result<(), String> {
    let mut stale: Vec<String> = Vec::new();
    for (item, entry_json, ..) in ms.list_own_support_creds()? {
        if Some(item.as_str()) == keep {
            continue;
        }
        let Ok(entry) = serde_json::from_str::<CredentialEntry>(&entry_json) else {
            continue;
        };
        if entry.t == T_TWITCH_OWNER {
            stale.push(item);
        }
    }
    // Whatever a sibling wrote onto our own profile row counts too: the union
    // republishes it, so an old account would come straight back.
    let row = ms
        .load_profile(master)
        .ok()
        .flatten()
        .map(|p| p.support_creds)
        .unwrap_or_default();
    for entry in support_creds::parse_stored(&row) {
        if entry.t == T_TWITCH_OWNER && Some(entry.item.as_str()) != keep && !stale.contains(&entry.item) {
            stale.push(entry.item);
        }
    }
    for item in stale {
        forget_own_cred(ms, &item)?;
    }
    Ok(())
}

/// Verify OUR Twitch account and keep the credential.
///
/// Split from the `#[frb]` entry point so the whole flow is testable without
/// a node or a network: hands back the login and the `support_creds` field
/// the caller should announce.
pub(crate) fn verify_twitch_owner_with(
    verifier: &TwitchVerifier<'_>,
    token: &str,
    master: &str,
) -> Result<(String, String), String> {
    let entry = mint_twitch_credential(verifier, "owner", token, None, master)?;
    let login = entry.parts.get(1).cloned().unwrap_or_default();
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    drop_other_twitch_owner_creds(ms, master, Some(&entry.item))?;
    // No slug (this is not a listing), the login as the title, and "twitch"
    // as the artist: Settings reads the same table for every credential.
    keep_own_cred_row(ms, &entry, "", &login, "twitch")?;
    let json = republish_to_row(ms, master)?;
    Ok((login, json))
}

/// Forget every verified-account credential, for good. What Disconnect does
/// before it wipes the token: the chip must go with the connection.
///
/// Answers the master and the field to announce, or `None` when the node is
/// not up yet. The table is cleaned either way, so the credential does not
/// come back at the next boot; only the announce waits.
pub(crate) fn forget_twitch_owner_creds() -> Result<Option<(String, String)>, String> {
    let master = super::network::get_local_peer_id();
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    drop_other_twitch_owner_creds(ms, master.as_deref().unwrap_or(""), None)?;
    match master {
        Some(m) => {
            let json = republish_to_row(ms, &m)?;
            Ok(Some((m, json)))
        }
        None => Ok(None),
    }
}

/// The verified Twitch login this identity currently publishes, and the
/// window its credential was minted in. `None` when there is none.
pub(crate) fn own_twitch_owner_entry() -> Option<CredentialEntry> {
    let master = super::network::get_local_peer_id()?;
    let store = get_store();
    let guard = store.lock().ok()?;
    let ms = guard.as_ref()?;
    let root = support_creds::root_verifying_key();
    own_credential_union(ms, &master)
        .ok()?
        .into_iter()
        .map(|u| u.entry)
        .find(|e| e.t == T_TWITCH_OWNER && support_creds::verify_entry(e, &master, &root).is_ok())
}

/// Every credential this identity holds, as far as this device can tell:
/// the ones it minted first, with their names, then the ones that reached it
/// on our own profile row from a sibling, which carry no names and no redeem
/// date. Removed items are left out.
///
/// The announce cap is NOT applied here. The cap is about what rides a light
/// profile announce; a holder of four marks is holding four.
#[frb]
pub fn list_own_support_creds() -> Result<Vec<OwnSupportCred>, String> {
    let master = super::network::get_local_peer_id();
    let store = get_store();
    let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    let ms = guard.as_ref().ok_or("Message store is not open")?;
    let badge = badge_on(ms.load_setting(SUPPORT_BADGE_SETTING).ok().flatten().as_deref());
    // Before the node is up there is no master to verify against, and an
    // unverified row entry is not something to show as ours.
    let Some(master) = master else {
        return Ok(ms
            .list_own_support_creds()?
            .into_iter()
            .map(|(item, entry_json, slug, title, artist_name, redeemed_at)| {
                let entry: CredentialEntry = serde_json::from_str(&entry_json).unwrap_or_default();
                OwnSupportCred { item, parts: entry.parts, slug, title, artist_name, redeemed_at, badge }
            })
            .collect());
    };
    let root = support_creds::root_verifying_key();
    Ok(own_credential_union(ms, &master)?
        .into_iter()
        .filter(|u| support_creds::verify_entry(&u.entry, &master, &root).is_ok())
        .map(|u| OwnSupportCred {
            item: u.entry.item,
            parts: u.entry.parts,
            slug: u.slug,
            title: u.title,
            artist_name: u.artist_name,
            redeemed_at: u.redeemed_at,
            badge,
        })
        .collect())
}

/// Whether OUR marks also sit next to our name (design 5.6). Off by default.
#[frb]
pub fn support_badge_enabled() -> bool {
    support_badge_preference()
}

/// Show, or stop showing, our marks next to our name. One profile save.
///
/// The setting is the only copy of the answer: [`published_creds_json`]
/// stamps it onto every entry it publishes, table and profile row alike, so
/// the switch works from whichever device the holder is sitting at rather
/// than only from the one that redeemed.
#[frb]
pub fn set_support_badge(show: bool) -> Result<(), String> {
    {
        let store = get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        ms.save_setting(SUPPORT_BADGE_SETTING, if show { "1" } else { "0" })?;
    }
    republish_support_creds()
}

/// Whether this device is holding our marks back (design 5.6, off by
/// default). Local to this device: a second install of the same identity
/// answers for itself.
#[frb]
pub fn support_marks_hidden() -> bool {
    let store = get_store();
    let Ok(guard) = store.lock() else { return false };
    let Some(ms) = guard.as_ref() else { return false };
    hidden_on(ms.load_setting(SUPPORT_HIDDEN_SETTING).ok().flatten().as_deref())
}

/// Hide, or stop hiding, our marks. One profile save.
///
/// Hiding announces the explicit clear, so every peer drops what they stored
/// and nobody can tell a holder who is hiding from somebody who never bought
/// anything. The credentials themselves stay in the table, so switching it
/// back publishes exactly what was there.
#[frb]
pub fn set_support_marks_hidden(hidden: bool) -> Result<(), String> {
    let master = my_master_peer_id()?;
    let json = {
        let store = get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        apply_hidden(ms, &master, hidden)?
    };
    announce_support_creds(&master, json)
}

/// Forget one of our credentials, for good.
///
/// There is no way back: the code that minted it is spent (12.6), and the
/// shop will not sign a second one for the same purchase. The files stay in
/// the library; only the mark goes. Forgetting an item this identity never
/// held is not an error, so a double press costs nothing.
///
/// The removal is remembered locally as well as applied, because the same
/// credential can arrive again on our own profile row from a sibling. What
/// that does NOT cover is the sibling itself: a mark removed on a device
/// that did not mint it comes back if the MINTING device republishes, since
/// `support_creds_own` does not replicate. Removing it where it was minted
/// is final. See [`own_credential_union`].
#[frb]
pub fn remove_own_support_cred(item: String) -> Result<(), String> {
    {
        let store = get_store();
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        forget_own_cred(ms, item.trim())?;
    }
    republish_support_creds()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A minimal but real RIFF/WEBP container: enough header that the
    /// container check passes, with a payload to hash.
    fn webp_bytes(payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&((payload.len() + 4) as u32).to_le_bytes());
        out.extend_from_slice(b"WEBP");
        out.extend_from_slice(payload);
        while out.len() < 16 {
            out.push(0);
        }
        out
    }

    fn sha_hex(bytes: &[u8]) -> String {
        hex::encode(Sha256::digest(bytes))
    }

    /// A distinct 64-hex hash per test file, so the fixtures read as addresses
    /// rather than as noise.
    fn h(tag: &str) -> String {
        let mut s = String::new();
        while s.len() < 64 {
            s.push_str(tag);
        }
        s.truncate(64);
        s
    }

    fn file(role: &str, hash: &str, w: u32, h_: u32, animated: bool) -> ShopFile {
        ShopFile {
            role: role.into(),
            sha256: hash.into(),
            bytes: 1234,
            w,
            h: h_,
            animated,
        }
    }

    #[test]
    fn catalog_parses_the_live_shape_tolerantly() {
        let good = h("ab");
        let anim = h("cd");
        let still = h("ef");
        let body = format!(
            r#"{{
              "generated_at": "2026-09-02T10:00:00.000Z",
              "an_unknown_top_level_field": {{ "the shop": "grew a column" }},
              "listings": [
                {{
                  "slug": "gilded-frame",
                  "title": "Gilded frame",
                  "description": "A frame.",
                  "kinds": ["frame"],
                  "price_cents": 499,
                  "was_cents": 699,
                  "license": "Personal use",
                  "created_at": "2026-08-01T00:00:00.000Z",
                  "sales_this_week": 12,
                  "artist": {{
                    "slug": "nadia",
                    "display_name": "Nadia",
                    "bio": "Paints frames.",
                    "header_hash": null,
                    "links": []
                  }},
                  "files": [
                    {{ "role": "frame", "sha256": "{good}", "bytes": 4096,
                       "w": 512, "h": 512, "animated": false }},
                    {{ "role": "frame", "sha256": "not-a-hash", "bytes": 1,
                       "w": 8, "h": 8, "animated": false }}
                  ]
                }},
                {{
                  "slug": "all-bad-files",
                  "title": "Nothing survives",
                  "kinds": ["avatar"],
                  "price_cents": 100,
                  "artist": {{ "slug": "nadia", "display_name": "Nadia", "bio": "" }},
                  "files": [
                    {{ "role": "avatar", "sha256": "ZZZZ", "bytes": 1 }}
                  ]
                }},
                {{
                  "slug": "kinds-from-files",
                  "title": "Kinds come from the files",
                  "kinds": [],
                  "price_cents": 250,
                  "artist": {{ "slug": "nadia", "display_name": "Nadia", "bio": "" }},
                  "files": [
                    {{ "role": "avatar_anim", "sha256": "{anim}", "bytes": 9,
                       "w": 512, "h": 512, "animated": true }},
                    {{ "role": "avatar_still", "sha256": "{still}", "bytes": 8,
                       "w": 512, "h": 512, "animated": false }}
                  ]
                }}
              ]
            }}"#
        );

        let cat = parse_catalog(body.as_bytes(), "https://shop.example").expect("parses");
        assert_eq!(cat.generated_at, "2026-09-02T10:00:00.000Z");
        assert_eq!(cat.origin, "https://shop.example");
        assert_eq!(
            cat.listings.len(),
            2,
            "the listing whose only file had a bad hash must drop whole"
        );

        let frame = &cat.listings[0];
        assert_eq!(frame.slug, "gilded-frame");
        assert_eq!(frame.files.len(), 1, "the bad-hash file must be dropped");
        assert_eq!(frame.files[0].sha256, good);
        assert_eq!(frame.price_cents, 499);
        assert_eq!(frame.price_label, "$4.99");
        assert_eq!((frame.was_cents, frame.was_label.as_str()), (699, "$6.99"), "on sale: the list price rides beside the price");
        assert_eq!(frame.artist.header_hash, "", "a null header hash is empty");
        assert_eq!(frame.artist.url, "https://shop.example/@nadia");
        assert_eq!(
            frame.item_url, "https://shop.example/item/gilded-frame",
            "the item link is the listing's own slug, never the art's hash"
        );
        assert!(!frame.bundle);

        let derived = &cat.listings[1];
        assert_eq!(
            derived.kinds,
            vec!["avatar".to_string()],
            "empty kinds must be derived from the files' roles"
        );
        assert_eq!(derived.display_hash, anim);
        assert_eq!(derived.still_hash, still);
        assert_eq!(derived.price_label, "$2.50");
        assert_eq!((derived.was_cents, derived.was_label.as_str()), (0, ""), "no sale, no was");
    }

    #[test]
    fn display_hash_follows_the_site_rule() {
        // (a) A bundle with a banner and a frame leads with the banner.
        let banner = h("1a");
        let frame = h("2b");
        let bundle_files = vec![
            file("banner", &banner, 1200, 480, false),
            file("frame", &frame, 512, 512, false),
        ];
        let bundle_kinds = vec!["frame".to_string(), "banner".to_string()];
        assert_eq!(
            display_file_for(&bundle_kinds, &bundle_files, false)
                .unwrap()
                .sha256,
            banner,
        );
        assert_eq!(
            primary_kind_of(&bundle_kinds, &bundle_files),
            Some("banner")
        );

        // (b) An avatar with an anim and a still displays the anim and names
        //     the still as its reduced sibling.
        let anim = h("3c");
        let still = h("4d");
        let avatar_files = vec![
            file("avatar_anim", &anim, 512, 512, true),
            file("avatar_still", &still, 512, 512, false),
        ];
        let avatar_kinds = vec!["avatar".to_string()];
        assert_eq!(
            display_file_for(&avatar_kinds, &avatar_files, false)
                .unwrap()
                .sha256,
            anim,
        );
        assert_eq!(
            display_file_for(&avatar_kinds, &avatar_files, true)
                .unwrap()
                .sha256,
            still,
        );

        // (c) Frame only: it is the display, and there is no still sibling.
        let only_frame = vec![file("frame", &frame, 512, 512, true)];
        let frame_kinds = vec!["frame".to_string()];
        assert_eq!(
            display_file_for(&frame_kinds, &only_frame, false)
                .unwrap()
                .sha256,
            frame,
        );
        assert_eq!(
            display_file_for(&frame_kinds, &only_frame, true)
                .unwrap()
                .sha256,
            frame,
            "a frame has no still sibling, so reduced returns the same file",
        );

        // (d) A still-only avatar: reduced and unreduced are the same file, so
        //     the listing carries no separate still hash.
        let still_only = vec![file("avatar_still", &still, 512, 512, false)];
        let listing = sanitize_listing(
            RawListing {
                slug: "still-only".into(),
                title: "Still only".into(),
                kinds: vec!["avatar".into()],
                files: vec![RawFile {
                    role: "avatar_still".into(),
                    sha256: still.clone(),
                    bytes: 10.0,
                    w: Some(512.0),
                    h: Some(512.0),
                    animated: false,
                }],
                ..Default::default()
            },
            "https://shop.example",
        )
        .expect("a still-only avatar is a listing");
        assert_eq!(listing.display_hash, still);
        assert_eq!(listing.still_hash, "");
        assert_eq!(
            display_file_for(&["avatar".to_string()], &still_only, false)
                .unwrap()
                .sha256,
            still,
        );

        // (e) Shape: a 1200x480 banner is wide, a 512 square is not.
        let wide = sanitize_listing(
            RawListing {
                slug: "wide-banner".into(),
                title: "Wide banner".into(),
                kinds: vec!["banner".into()],
                files: vec![RawFile {
                    role: "banner".into(),
                    sha256: banner.clone(),
                    bytes: 10.0,
                    w: Some(1200.0),
                    h: Some(480.0),
                    animated: false,
                }],
                ..Default::default()
            },
            "https://shop.example",
        )
        .unwrap();
        assert!(wide.wide, "1200x480 is 2.5:1 and hangs wide");

        let tall = sanitize_listing(
            RawListing {
                slug: "square-frame".into(),
                title: "Square frame".into(),
                kinds: vec!["frame".into()],
                files: vec![RawFile {
                    role: "frame".into(),
                    sha256: frame.clone(),
                    bytes: 10.0,
                    w: Some(512.0),
                    h: Some(512.0),
                    animated: false,
                }],
                ..Default::default()
            },
            "https://shop.example",
        )
        .unwrap();
        assert!(!tall.wide, "a 512 square is not a strip");
    }

    #[test]
    fn art_bytes_are_refused_on_hash_mismatch() {
        let bytes = webp_bytes(b"the real art");
        let other = sha_hex(&webp_bytes(b"different art"));
        let err = check_art_bytes(&other, &bytes).expect_err("a mismatch must refuse");
        assert!(err.contains("does not match its hash"), "{err}");

        // Right hash, wrong container: still refused, and the rail never sees
        // a non-WebP.
        let not_webp = b"GIF89a this is not a webp at all".to_vec();
        let err = check_art_bytes(&sha_hex(&not_webp), &not_webp)
            .expect_err("a non-WebP must refuse");
        assert!(err.contains("not a WebP"), "{err}");
    }

    #[test]
    fn art_bytes_pass_when_hash_and_container_match() {
        let bytes = webp_bytes(b"the real art");
        let hash = sha_hex(&bytes);
        assert!(valid_emote_hash(&hash));
        check_art_bytes(&hash, &bytes).expect("matching bytes must pass");
    }

    #[test]
    fn badge_is_on_unless_switched_off() {
        assert!(badge_on(None), "an absent setting is on");
        assert!(badge_on(Some("1")));
        assert!(!badge_on(Some("0")));
        assert!(badge_on(Some("anything else")), "only an explicit 0 switches it off");
    }

    #[test]
    fn dead_lookup_statuses_are_the_three_final_ones() {
        for dead in ["burned", "refused", "unknown"] {
            assert!(lookup_status_is_dead(dead), "{dead}");
        }
        for alive in ["ok", "nokey", "paused", "rail", "invalid", ""] {
            assert!(!lookup_status_is_dead(alive), "{alive}");
        }
    }

    #[test]
    fn redeem_code_shape_is_enforced() {
        assert!(valid_redeem_code("ABCDE-FGHIJ-12345"));
        assert!(valid_redeem_code("abc_DEF-012"));
        assert!(!valid_redeem_code("ABCDEFG"), "7 characters is too short");
        assert!(
            !valid_redeem_code(&"A".repeat(129)),
            "129 characters is too long"
        );
        assert!(!valid_redeem_code("ABCDE FGHIJ"), "a space is not a code");
        assert!(!valid_redeem_code("ABCDE/FGHIJ"), "a slash is not a code");
        assert!(!valid_redeem_code("ABCDE%2FGHIJ"), "a percent is not a code");
    }

    /// The 64-row cap lives at the API layer, so it is tested by driving the
    /// `#[frb]` function against an installed in-memory store.
    #[test]
    fn redeem_codes_are_capped_at_sixty_four() {
        let _lock = crate::api::storage::store_test_lock();
        crate::api::storage::set_test_store(
            crate::storage::MessageStore::open(":memory:", &"ab".repeat(32))
                .expect("open in-memory store"),
        );

        for i in 0..MAX_KEPT_REDEEM_CODES {
            assert!(
                keep_redeem_code(format!("CODE-{i:04}-XXXX")).expect("keep"),
                "code {i} must be kept",
            );
        }
        // Re-keeping one we already hold is a no-op even at the cap.
        assert!(!keep_redeem_code("CODE-0000-XXXX".into()).expect("re-keep"));

        let err = keep_redeem_code("ONE-TOO-MANY-0001".into()).expect_err("the cap must refuse");
        assert!(err.contains("forget one first"), "{err}");

        assert_eq!(
            list_redeem_codes().expect("list").len(),
            MAX_KEPT_REDEEM_CODES as usize,
        );
        forget_redeem_code("CODE-0000-XXXX".into()).expect("forget");
        assert!(
            keep_redeem_code("ONE-TOO-MANY-0001".into()).expect("room again"),
            "forgetting one must make room",
        );

        // A badly shaped code never reaches the store.
        assert!(keep_redeem_code("nope".into()).is_err());
    }

    // ── Support marks: hiding and removing ────────────────────────────
    //
    // These drive the pure half of the republish (`published_creds_json` and
    // the store halves around it): the table, our own profile row, the shelf
    // and the local settings in, the field to announce out. The announce
    // itself needs a running node and stays best effort exactly as it is;
    // what has to be right is the STRING, because `""` on the wire is the
    // explicit clear every receiver already honours, and a device that
    // publishes it by mistake wipes the holder's marks everywhere.

    /// An in-memory store installed as the process-global one, with the lock
    /// that keeps parallel tests from swapping it under each other.
    fn with_test_store() -> std::sync::MutexGuard<'static, ()> {
        let lock = crate::api::storage::store_test_lock();
        crate::api::storage::set_test_store(
            crate::storage::MessageStore::open(":memory:", &"ab".repeat(32))
                .expect("open in-memory store"),
        );
        lock
    }

    fn with_store<T>(body: impl FnOnce(&crate::storage::MessageStore) -> T) -> T {
        let guard = get_store().lock().unwrap_or_else(|e| e.into_inner());
        body(guard.as_ref().expect("store installed"))
    }

    /// Two real credentials for `master`, kept the way a redeem keeps them.
    fn seed_two_creds(master: &str) -> (CredentialEntry, CredentialEntry) {
        let one = support_creds::testing::mint_for(master, &[h("11")]);
        let two = support_creds::testing::mint_for(master, &[h("22")]);
        with_store(|ms| {
            for (entry, slug, title, artist) in [
                (&one, "gilded-frame", "Gilded frame", "Nadia"),
                (&two, "night-banner", "Night banner", "Ada"),
            ] {
                ms.save_own_support_cred(
                    &entry.item,
                    &serde_json::to_string(entry).expect("entry json"),
                    slug,
                    title,
                    artist,
                )
                .expect("keep");
            }
        });
        (one, two)
    }

    #[test]
    fn hidden_default_is_shown() {
        assert!(!hidden_on(None), "an absent setting is not hidden");
        assert!(hidden_on(Some("1")));
        assert!(!hidden_on(Some("0")));
        assert!(!hidden_on(Some("anything else")), "only an explicit 1 hides");
    }

    #[test]
    fn hidden_marks_publish_a_clear_and_keep_the_records() {
        let _lock = with_test_store();
        let master = "master-peer-hides";
        let (one, two) = seed_two_creds(master);

        let shown = with_store(|ms| published_creds_json(ms, master).expect("json"));
        let parsed = support_creds::parse_stored(&shown);
        assert_eq!(parsed.len(), 2, "both marks ride the field while shown: {shown}");

        with_store(|ms| ms.save_setting(SUPPORT_HIDDEN_SETTING, "1").expect("hide"));
        let hidden = with_store(|ms| published_creds_json(ms, master).expect("json"));
        assert_eq!(
            hidden, "",
            "hidden publishes the explicit clear, never a shorter list",
        );
        assert_eq!(
            with_store(|ms| ms.list_own_support_creds().expect("list").len()),
            2,
            "hiding must not touch a single record: the credentials are not re-mintable",
        );

        with_store(|ms| ms.save_setting(SUPPORT_HIDDEN_SETTING, "0").expect("show"));
        let back = with_store(|ms| published_creds_json(ms, master).expect("json"));
        let parsed = support_creds::parse_stored(&back);
        assert_eq!(parsed.len(), 2, "switching back publishes both again: {back}");
        let items: Vec<&str> = parsed.iter().map(|e| e.item.as_str()).collect();
        assert!(items.contains(&one.item.as_str()) && items.contains(&two.item.as_str()));
    }

    #[test]
    fn remove_own_support_cred_shrinks_the_announce_and_the_last_one_clears_it() {
        let _lock = with_test_store();
        let master = "master-peer-removes";
        let (one, two) = seed_two_creds(master);

        // Forgetting something this identity never held changes nothing.
        with_store(|ms| ms.delete_own_support_cred(&h("ee")).expect("unknown item is a no-op"));
        let json = with_store(|ms| published_creds_json(ms, master).expect("json"));
        assert_eq!(support_creds::parse_stored(&json).len(), 2);

        with_store(|ms| ms.delete_own_support_cred(&one.item).expect("remove one"));
        let json = with_store(|ms| published_creds_json(ms, master).expect("json"));
        let parsed = support_creds::parse_stored(&json);
        assert_eq!(parsed.len(), 1, "one mark leaves, one stays: {json}");
        assert_eq!(parsed[0].item, two.item);

        with_store(|ms| ms.delete_own_support_cred(&two.item).expect("remove the last"));
        let json = with_store(|ms| published_creds_json(ms, master).expect("json"));
        assert_eq!(
            json, "",
            "the last one out announces the explicit clear, not an empty array",
        );
    }

    /// Write `entries` onto our own profile row, the way a sibling's announce
    /// does when it reaches this device.
    fn seed_row(ms: &crate::storage::MessageStore, master: &str, entries: &[CredentialEntry]) {
        let json = support_creds::encode_entries(entries);
        ms.save_profile(
            master, "", "", "", 0, None, None, "", None, None, None, None, None, None,
            Some(&json),
        )
        .expect("seed the profile row");
    }

    fn row_of(ms: &crate::storage::MessageStore, master: &str) -> String {
        ms.load_profile(master)
            .expect("load profile")
            .map(|p| p.support_creds)
            .unwrap_or_default()
    }

    fn items_of(json: &str) -> Vec<String> {
        support_creds::parse_stored(json)
            .into_iter()
            .map(|e| e.item)
            .collect()
    }

    fn shelf_of(ms: &crate::storage::MessageStore) -> String {
        ms.load_setting(SUPPORT_SHELF_SETTING)
            .expect("load shelf")
            .unwrap_or_default()
    }

    #[test]
    fn sibling_with_an_empty_table_republishes_the_masters_marks() {
        let _lock = with_test_store();
        let master = "master-peer-sibling";
        let a = support_creds::testing::mint_for(master, &[h("11")]);
        let b = support_creds::testing::mint_for(master, &[h("22")]);
        with_store(|ms| seed_row(ms, master, &[a.clone(), b.clone()]));

        // This device never redeemed anything: its own table is empty and the
        // profile row a sibling wrote is all it has.
        assert!(with_store(|ms| ms.list_own_support_creds().expect("list")).is_empty());
        let json = with_store(|ms| published_creds_json(ms, master).expect("json"));
        let items = items_of(&json);
        assert_eq!(
            items.len(),
            2,
            "a sibling must republish what the master holds, not its own empty table: {json}",
        );
        assert!(items.contains(&a.item) && items.contains(&b.item));

        // Now this device redeems one of its own. It ADDS; it does not replace
        // the two the other device minted.
        let c = support_creds::testing::mint_for(master, &[h("33")]);
        with_store(|ms| keep_own_cred_row(ms, &c, "third", "Third", "Ada").expect("keep"));
        let json = with_store(|ms| published_creds_json(ms, master).expect("json"));
        let items = items_of(&json);
        assert_eq!(items.len(), 3, "a redeem on a sibling must not wipe the rest: {json}");
        assert!(items.contains(&c.item));

        // Settings lists the same union, so a sibling can manage what it can
        // now publish. The `#[frb]` wrapper needs a running node for the
        // master, so the union underneath it is what is checked here.
        let listed = with_store(|ms| own_credential_union(ms, master).expect("union"));
        assert_eq!(listed.len(), 3);
        assert!(
            listed.iter().any(|u| u.title == "Third" && u.redeemed_at > 0),
            "the one this device minted keeps its names and its date",
        );
        assert_eq!(
            listed
                .iter()
                .filter(|u| u.title.is_empty() && u.artist_name.is_empty() && u.redeemed_at == 0)
                .count(),
            2,
            "the two that arrived on the row carry no names and no date",
        );
    }

    #[test]
    fn a_row_entry_for_another_master_never_rides_the_announce() {
        let _lock = with_test_store();
        let master = "master-peer-transplant";
        let mine = support_creds::testing::mint_for(master, &[h("11")]);
        // Minted for somebody else and sitting on our row: worthless, and the
        // union must not launder it just because it is stored locally.
        let theirs = support_creds::testing::mint_for("somebody-else", &[h("22")]);
        with_store(|ms| seed_row(ms, master, &[theirs.clone(), mine.clone()]));

        let json = with_store(|ms| published_creds_json(ms, master).expect("json"));
        assert_eq!(
            items_of(&json),
            vec![mine.item.clone()],
            "only what is signed for THIS master rides: {json}",
        );
        assert!(!json.contains(&theirs.item), "the transplant is gone: {json}");
    }

    #[test]
    fn badge_setting_applies_to_every_published_entry() {
        let _lock = with_test_store();
        let master = "master-peer-badge";
        let mine = support_creds::testing::mint_for(master, &[h("11")]);
        let from_row = support_creds::testing::mint_for(master, &[h("22")]);
        assert!(!mine.badge && !from_row.badge, "minted without the glyph");
        with_store(|ms| {
            keep_own_cred_row(ms, &mine, "one", "One", "Ada").expect("keep");
            seed_row(ms, master, std::slice::from_ref(&from_row));
            ms.save_setting(SUPPORT_BADGE_SETTING, "1").expect("glyph on");
        });

        let on = with_store(|ms| published_creds_json(ms, master).expect("json"));
        let parsed = support_creds::parse_stored(&on);
        assert_eq!(parsed.len(), 2, "{on}");
        assert!(
            parsed.iter().all(|e| e.badge),
            "the setting decides for every entry, the table's and the row's alike: {on}",
        );

        with_store(|ms| ms.save_setting(SUPPORT_BADGE_SETTING, "0").expect("glyph off"));
        let off = with_store(|ms| published_creds_json(ms, master).expect("json"));
        let parsed = support_creds::parse_stored(&off);
        assert_eq!(parsed.len(), 2, "{off}");
        assert!(parsed.iter().all(|e| !e.badge), "and it decides both ways: {off}");
    }

    #[test]
    fn hide_and_unhide_round_trip_from_a_device_with_an_empty_table() {
        let _lock = with_test_store();
        let master = "master-peer-roundtrip";
        let a = support_creds::testing::mint_for(master, &[h("11")]);
        let b = support_creds::testing::mint_for(master, &[h("22")]);
        with_store(|ms| seed_row(ms, master, &[a.clone(), b.clone()]));

        let hidden = with_store(|ms| apply_hidden(ms, master, true).expect("hide"));
        assert_eq!(hidden, "", "hiding announces the explicit clear");
        assert_eq!(
            with_store(|ms| row_of(ms, master)),
            "",
            "our own row clears too, so our own card shows no chip while hidden",
        );
        assert_eq!(
            items_of(&with_store(shelf_of)).len(),
            2,
            "the shelf holds exactly what the clear took, on a device whose table is empty",
        );

        let back = with_store(|ms| apply_hidden(ms, master, false).expect("unhide"));
        let items = items_of(&back);
        assert_eq!(items.len(), 2, "unhiding brings both back from an empty table: {back}");
        assert!(items.contains(&a.item) && items.contains(&b.item));
        assert_eq!(
            items_of(&with_store(|ms| row_of(ms, master))).len(),
            2,
            "and writes them back onto the row",
        );
        assert_eq!(
            with_store(shelf_of),
            "",
            "the shelf is dropped only after the row holds them again",
        );
    }

    #[test]
    fn hiding_twice_keeps_the_shelf() {
        let _lock = with_test_store();
        let master = "master-peer-hide-twice";
        let a = support_creds::testing::mint_for(master, &[h("11")]);
        let b = support_creds::testing::mint_for(master, &[h("22")]);
        with_store(|ms| seed_row(ms, master, &[a.clone(), b.clone()]));

        assert_eq!(with_store(|ms| apply_hidden(ms, master, true).expect("hide")), "");
        let shelf = with_store(shelf_of);
        assert_eq!(items_of(&shelf).len(), 2, "the first hide shelves both: {shelf}");

        // A retried toggle, another surface sending the same value, a double
        // press: the shelf must not be overwritten with the clear that hiding
        // publishes, because on this device the shelf is the only copy.
        assert_eq!(
            with_store(|ms| apply_hidden(ms, master, true).expect("hide again")),
            "",
        );
        assert_eq!(
            with_store(shelf_of),
            shelf,
            "hiding while already hidden must leave the shelf exactly as it was",
        );

        let back = with_store(|ms| apply_hidden(ms, master, false).expect("unhide"));
        let items = items_of(&back);
        assert_eq!(items.len(), 2, "unhiding after two hides still brings both back: {back}");
        assert!(items.contains(&a.item) && items.contains(&b.item));
    }

    #[test]
    fn remove_from_a_device_that_did_not_mint_it_sticks_on_that_device() {
        let _lock = with_test_store();
        let master = "master-peer-tombstone";
        let a = support_creds::testing::mint_for(master, &[h("11")]);
        let b = support_creds::testing::mint_for(master, &[h("22")]);
        with_store(|ms| seed_row(ms, master, &[a.clone(), b.clone()]));

        with_store(|ms| forget_own_cred(ms, &a.item).expect("forget"));
        let json = with_store(|ms| published_creds_json(ms, master).expect("json"));
        assert_eq!(items_of(&json), vec![b.item.clone()], "the removed mark leaves: {json}");

        // The row still carries it, because the row is what a sibling wrote.
        // A second republish must not let it back in.
        assert_eq!(items_of(&with_store(|ms| row_of(ms, master))).len(), 2);
        let again = with_store(|ms| published_creds_json(ms, master).expect("json"));
        assert_eq!(items_of(&again), vec![b.item.clone()], "the tombstone holds: {again}");

        // Redeeming the same item again says the holder wants it back.
        with_store(|ms| keep_own_cred_row(ms, &a, "one", "One", "Ada").expect("re-redeem"));
        let after = with_store(|ms| published_creds_json(ms, master).expect("json"));
        assert_eq!(
            items_of(&after).len(),
            2,
            "a fresh credential for the same item clears the tombstone: {after}",
        );
        assert!(
            with_store(removed_items).is_empty(),
            "and takes the tombstone with it",
        );

        // Junk never grows the tombstone list.
        with_store(|ms| forget_own_cred(ms, "not-an-item").expect("no-op"));
        assert!(with_store(removed_items).is_empty());
    }


    // ── The two Twitch types on the same field ────────────────────────

    /// A canned `/api/twitch/key` + `/api/twitch/verify` pair, built from the
    /// TEST issuing keys. No network, and it COUNTS its signatures so a test
    /// can prove nothing was blinded on a path that should have refused
    /// first.
    struct CannedVerifier {
        key: support_creds::testing::TestTypedKey,
        t: u8,
        item: String,
        parts: Vec<String>,
        period: u32,
        /// Break the root link, the way a shop with a wrong issuer would.
        bad_chain: bool,
        signed: std::cell::Cell<usize>,
    }

    impl CannedVerifier {
        fn owner(master_period: u32, user_id: &str, login: &str) -> Self {
            let parts = vec![user_id.to_string(), login.to_string()];
            let (item, parts) = support_creds::twitch_owner_item(&parts).expect("owner parts");
            Self {
                key: support_creds::testing::test_typed_key(T_TWITCH_OWNER, &item, master_period),
                t: T_TWITCH_OWNER,
                item: hex::encode(item),
                parts,
                period: master_period,
                bad_chain: false,
                signed: std::cell::Cell::new(0),
            }
        }
    }

    impl CannedVerifier {
        /// The pair of closures `mint_twitch_credential` calls.
        fn as_verifier(&self) -> TwitchVerifier<'_> {
            TwitchVerifier {
                key: Box::new(move |_kind, _token, _bid| {
                    Ok(RawTwitchKey {
                        t: self.t,
                        item: self.item.clone(),
                        parts: self.parts.clone(),
                        period: self.period,
                        key: B64.encode(&self.key.pk_der),
                        key_sig: B64.encode(self.key.key_sig),
                        issuer: B64.encode(self.key.issuer.pk),
                        issuer_sig: if self.bad_chain {
                            B64.encode([0u8; 64])
                        } else {
                            B64.encode(self.key.issuer.root_sig)
                        },
                    })
                }),
                sign: Box::new(move |_kind, _token, _bid, _item, _period, blinded| {
                    self.signed.set(self.signed.get() + 1);
                    Ok(support_creds::testing::blind_sign_with(&self.key, blinded))
                }),
            }
        }
    }

    fn twitch_entry(ms: &crate::storage::MessageStore, master: &str) -> Option<CredentialEntry> {
        support_creds::parse_stored(&published_creds_json(ms, master).expect("json"))
            .into_iter()
            .find(|e| e.t == T_TWITCH_OWNER)
    }

    #[test]
    fn hidden_keeps_the_twitch_entry_and_hides_the_marks() {
        let _lock = with_test_store();
        let master = "master-peer-twitch-hides";
        let (one, two) = seed_two_creds(master);
        let account =
            support_creds::testing::mint_owner_for(master, "12345", "somestreamer", support_creds::now_period());
        with_store(|ms| {
            keep_own_cred_row(ms, &account, "", "somestreamer", "twitch").expect("keep");
        });

        let shown = with_store(|ms| published_creds_json(ms, master).expect("json"));
        assert_eq!(
            support_creds::parse_stored(&shown).len(),
            3,
            "two marks and the account ride the field while shown: {shown}",
        );

        with_store(|ms| ms.save_setting(SUPPORT_HIDDEN_SETTING, "1").expect("hide"));
        let hidden = with_store(|ms| published_creds_json(ms, master).expect("json"));
        let kept = support_creds::parse_stored(&hidden);
        assert_eq!(
            kept.len(),
            1,
            "hiding is about the SHOP marks; the verified account keeps publishing: {hidden}",
        );
        assert_eq!(kept[0].t, T_TWITCH_OWNER);
        assert!(
            !hidden.contains(&one.item) && !hidden.contains(&two.item),
            "and neither mark is in it: {hidden}",
        );

        // Unhiding brings the marks back and does not duplicate the account.
        with_store(|ms| ms.save_setting(SUPPORT_HIDDEN_SETTING, "0").expect("show"));
        let back = with_store(|ms| published_creds_json(ms, master).expect("json"));
        assert_eq!(support_creds::parse_stored(&back).len(), 3, "{back}");

        // A holder with no account credential still publishes the explicit
        // clear when hiding, so hiding stays indistinguishable from never
        // having bought anything.
        with_store(|ms| {
            forget_own_cred(ms, &account.item).expect("forget the account");
            ms.save_setting(SUPPORT_HIDDEN_SETTING, "1").expect("hide");
        });
        assert_eq!(
            with_store(|ms| published_creds_json(ms, master).expect("json")),
            "",
            "no account, no field",
        );
    }

    #[test]
    fn twitch_verify_owner_stores_and_publishes() {
        let _lock = with_test_store();
        let master = "master-peer-twitch-verify";
        let period = support_creds::now_period();

        let verifier = CannedVerifier::owner(period, "12345", "somestreamer");
        let (login, json) =
            verify_twitch_owner_with(&verifier.as_verifier(), "an-access-token", master).expect("verifies");
        assert_eq!(login, "somestreamer");
        assert_eq!(verifier.signed.get(), 1, "exactly one blind signature was asked for");

        let published = support_creds::parse_stored(&json);
        assert_eq!(published.len(), 1, "{json}");
        assert_eq!(published[0].t, T_TWITCH_OWNER);
        assert_eq!(
            published[0].parts,
            vec!["12345".to_string(), "somestreamer".to_string()],
        );
        assert_eq!(published[0].period, period);
        // What we publish is what a viewer will keep.
        support_creds::verify_entry(&published[0], master, &support_creds::root_verifying_key())
            .expect("the published entry verifies for our master");

        // It is on our own row, and in the table with names Settings can read.
        assert_eq!(items_of(&with_store(|ms| row_of(ms, master))), vec![published[0].item.clone()]);
        let listed = with_store(|ms| ms.list_own_support_creds().expect("list"));
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].3, "somestreamer", "the login is the title");
        assert_eq!(listed[0].4, "twitch", "and the artist names where it came from");

        // Verifying a DIFFERENT account replaces the first: the cap is one,
        // and `keep_verified` keeps the first that verifies, so a stale entry
        // would otherwise outlive the account it names.
        let second = CannedVerifier::owner(period, "54321", "another_one");
        let (login, json) =
            verify_twitch_owner_with(&second.as_verifier(), "an-access-token", master).expect("verifies");
        assert_eq!(login, "another_one");
        let published = support_creds::parse_stored(&json);
        assert_eq!(published.len(), 1, "one account, never two: {json}");
        assert_eq!(published[0].parts[1], "another_one");
        assert!(
            with_store(|ms| twitch_entry(ms, master)).is_some_and(|e| e.parts[1] == "another_one"),
        );

        // And Disconnect takes it away.
        with_store(|ms| {
            drop_other_twitch_owner_creds(ms, master, None).expect("forget");
            republish_to_row(ms, master).expect("republish")
        });
        assert_eq!(
            with_store(|ms| published_creds_json(ms, master).expect("json")),
            "",
            "disconnecting leaves no verified chip behind",
        );
    }

    #[test]
    fn twitch_verify_owner_refuses_a_bad_chain_before_blinding() {
        let _lock = with_test_store();
        let master = "master-peer-twitch-badchain";
        let period = support_creds::now_period();

        let mut verifier = CannedVerifier::owner(period, "12345", "somestreamer");
        verifier.bad_chain = true;
        let err = verify_twitch_owner_with(&verifier.as_verifier(), "an-access-token", master)
            .expect_err("a chain that does not lead to the pinned root must refuse");
        assert!(err.contains("did not check out"), "{err}");
        assert_eq!(
            verifier.signed.get(),
            0,
            "nothing was blinded: the chain is checked BEFORE the second round trip",
        );
        assert_eq!(
            with_store(|ms| published_creds_json(ms, master).expect("json")),
            "",
            "and nothing was stored",
        );

        // A credential outside its window is refused at the same door, so a
        // shop answering with a stale key cannot make us wear one.
        let stale = CannedVerifier::owner(period.saturating_sub(3), "12345", "somestreamer");
        let err = verify_twitch_owner_with(&stale.as_verifier(), "an-access-token", master)
            .expect_err("a stale window must refuse");
        assert!(err.contains("did not check out"), "{err}");
        assert_eq!(stale.signed.get(), 0);
    }

    #[test]
    fn a_follow_credential_must_name_the_channel_we_asked_about() {
        let _lock = with_test_store();
        let master = "master-peer-follow-channel";
        let period = support_creds::now_period();
        let parts = vec!["67890".to_string(), "30".to_string(), "0".to_string()];
        let (item, parts) = support_creds::twitch_follow_item(&parts).expect("follow parts");
        let verifier = CannedVerifier {
            key: support_creds::testing::test_typed_key(T_TWITCH_FOLLOW, &item, period),
            t: T_TWITCH_FOLLOW,
            item: hex::encode(item),
            parts,
            period,
            bad_chain: false,
            signed: std::cell::Cell::new(0),
        };

        // The channel we asked about: fine.
        let entry = mint_twitch_credential(&verifier.as_verifier(), "follow", "tok", Some("67890"), master)
            .expect("the follow credential mints");
        assert_eq!(entry.t, T_TWITCH_FOLLOW);

        // A different one: refused before anything is blinded a second time.
        let before = verifier.signed.get();
        let err = mint_twitch_credential(&verifier.as_verifier(), "follow", "tok", Some("11111"), master)
            .expect_err("a credential for another channel must refuse");
        assert!(err.contains("different channel"), "{err}");
        assert_eq!(verifier.signed.get(), before, "and nothing was blinded for it");
    }

    /// Manual live smoke against the real shop (network):
    /// `cargo nextest run --lib shop::tests::live_catalog_smoke --run-ignored all --no-capture`
    #[test]
    #[ignore]
    fn live_catalog_smoke() {
        let cat = fetch_shop_catalog().expect("the live shop must answer");
        println!(
            "origin={} generated_at={} listings={}",
            cat.origin,
            cat.generated_at,
            cat.listings.len()
        );
        for l in &cat.listings {
            println!(
                "  {} by {} — {} {:?} display={} still={:?} wide={} bundle={}",
                l.title,
                l.artist.slug,
                l.price_label,
                l.kinds,
                &l.display_hash[..12],
                l.still_hash.get(..12),
                l.wide,
                l.bundle,
            );
        }
        assert!(!cat.listings.is_empty());
    }
}
