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

use super::network::get_http_runtime;
use super::storage::get_store;
use crate::crdt::valid_emote_hash;
use crate::hollowpack::{Role, MAX_FILE_BYTES};

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
    use futures_util::StreamExt;

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
