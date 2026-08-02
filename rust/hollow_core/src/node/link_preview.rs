//! OpenGraph link preview fetcher.
//!
//! **Privacy contract:** This module is ONLY called from the sender side.
//! When a user types a URL into the compose box, Hollow fetches the OG tags
//! and embeds a preview card (title/description/domain + small WebP
//! thumbnail) into the outgoing message envelope. Receivers render the
//! embedded card and NEVER make an HTTP request to the previewed URL —
//! that's a privacy requirement, not a cache optimization. Routing link
//! fetches through N receivers would turn Hollow into an IP-harvesting
//! amplifier.
//!
//! Phase 6.75.

use std::sync::{Mutex, OnceLock};

use scraper::{Html, Selector};

use crate::node::image_convert;
use crate::node::LinkPreviewRef;

/// Max HTML response body we'll accept (2 MB). Modern bloated sites like
/// YouTube ship ~1.2 MB of inline JSON + JS in a single HTML document,
/// so a 1 MB cap cuts them off before the OG tags are even reachable.
/// 2 MB is generous enough to cover realistic sites while still refusing
/// pathologically-large responses. The 3-second total timeout is the
/// real ceiling on misbehavior.
const MAX_HTML_BYTES: usize = 2 * 1_024 * 1_024;
/// Max image response body we'll accept (4 MB). Typical OG images are
/// under 500 KB; cap at 4 MB to avoid pulling a huge hero shot we'd just
/// downsize anyway.
const MAX_IMAGE_BYTES: usize = 4 * 1_024 * 1_024;
/// Total timeout for the HTML + image fetches combined.
const FETCH_TIMEOUT_SECS: u64 = 3;
/// Max title length (chars).
const MAX_TITLE_CHARS: usize = 200;
/// Max description length (chars).
const MAX_DESC_CHARS: usize = 400;
/// Target max dimension for the thumbnail (px).
const THUMB_MAX_DIM: u32 = 400;
/// Thumbnail dimension for LARGE (social post) cards, which show the image
/// full-width across the card instead of as an 80px row thumb.
const THUMB_MAX_DIM_LARGE: u32 = 800;

/// Optional override that routes social lookups through a configured service
/// instead of calling the upstream API directly. `None`/empty = direct, which
/// is the default and the shipped behavior.
static EMBED_PROXY_BASE: OnceLock<Mutex<Option<String>>> = OnceLock::new();

/// The configured proxy base, or `None` for direct.
fn embed_proxy_base() -> Option<String> {
    EMBED_PROXY_BASE
        .get_or_init(|| Mutex::new(None))
        .lock()
        .ok()
        .and_then(|g| g.clone())
}

/// Set (or clear) the social-preview proxy base. Empty string clears it.
/// Validated by the FFI setter before Dart persists it, mirroring the GIF
/// proxy's shape.
pub fn set_embed_proxy_base(base: Option<String>) {
    if let Ok(mut g) = EMBED_PROXY_BASE.get_or_init(|| Mutex::new(None)).lock() {
        *g = base.filter(|s| !s.trim().is_empty());
    }
}
/// User-Agent we identify as.
///
/// The `compatible; …bot…` shape is load-bearing, not decoration: the embed
/// proxies people paste (fixupx, vxtiktok, ddinstagram) sniff for a
/// crawler-shaped UA and serve OpenGraph tags to it, while serving a JS shell
/// with no metadata to anything that looks like a browser. The `+url` is the
/// crawler convention — it is the only thing a site operator sees in their
/// access log besides an IP, and the page it points at explains what triggers
/// a fetch and how to block us. A `+url` that 404s reads as a scraper
/// pretending to be a crawler, so the page has to exist.
const USER_AGENT: &str =
    "Mozilla/5.0 (compatible; HollowBot/1.0; +https://anonlisten.com/bot)";

/// One shared HTTP client, keyed on the anti-censorship tunnel's SOCKS
/// address so it is rebuilt only when that changes. The old code built a
/// fresh `reqwest::Client` on every keystroke-triggered fetch, throwing away
/// the connection pool and re-doing the TLS config each time.
#[allow(clippy::type_complexity)]
static HTTP_CLIENT: OnceLock<Mutex<Option<(Option<String>, reqwest::Client)>>> =
    OnceLock::new();

/// The client to fetch with, honouring the proxy tunnel when it is up.
///
/// `reqwest::Client` is an `Arc` internally, so cloning the cached one is
/// cheap and every caller shares the same pool.
fn http_client() -> Result<reqwest::Client, String> {
    let proxy = crate::api::network::get_proxy_socks_addr();

    let cell = HTTP_CLIENT.get_or_init(|| Mutex::new(None));
    let mut guard = cell
        .lock()
        .map_err(|e| format!("HTTP client lock poisoned: {e}"))?;
    if let Some((cached_proxy, client)) = guard.as_ref()
        && *cached_proxy == proxy
    {
        return Ok(client.clone());
    }

    let mut builder = reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .timeout(std::time::Duration::from_secs(FETCH_TIMEOUT_SECS))
        .redirect(reqwest::redirect::Policy::limited(3));
    if let Some(addr) = proxy.as_deref() {
        // When the tunnel is up, preview fetches ride it too. Going direct
        // would leak the fetch to exactly the network the tunnel exists to
        // hide from, and would fail anyway whenever the previewed host is the
        // thing being blocked. `socks5h` keeps DNS resolution on the far side
        // so the hostname never hits the local resolver either.
        let p = reqwest::Proxy::all(format!("socks5h://{addr}"))
            .map_err(|e| format!("Invalid SOCKS proxy address: {e}"))?;
        builder = builder.proxy(p);
    }
    let client = builder
        .build()
        .map_err(|e| format!("Failed to build HTTP client: {e}"))?;

    *guard = Some((proxy, client.clone()));
    Ok(client)
}

/// Fetch OG metadata for `url` and build a `LinkPreviewRef`.
///
/// Social posts (see [`social`]) take the adapter path first, because sites
/// like X serve a crawler nothing worth rendering. Any adapter failure falls
/// back to the plain OpenGraph scrape below, which is exactly what shipped
/// before — a dead adapter degrades to the old behavior, never to an error.
///
/// Returns `Err` on any fetch/parse/compress failure so the caller can
/// silently drop the preview without blocking the message send.
pub async fn fetch_link_preview(url: &str) -> Result<LinkPreviewRef, String> {
    // Parse + sanity-check the URL up front. Extract the display domain.
    let parsed = reqwest::Url::parse(url)
        .map_err(|e| format!("Invalid URL: {e}"))?;
    if parsed.scheme() != "http" && parsed.scheme() != "https" {
        return Err(format!("Unsupported URL scheme: {}", parsed.scheme()));
    }
    let domain = parsed.host_str().unwrap_or("").to_string();

    let client = http_client()?;

    if let Some(kind) = social::classify(&parsed) {
        match social::fetch(&client, &parsed, kind, &domain).await {
            Ok(preview) => return Ok(preview),
            Err(e) => {
                hollow_log!("[HOLLOW-LP] Social adapter for {domain} failed ({e}); falling back to OpenGraph");
            }
        }
    }

    // Fetch the HTML with a body-size cap.
    let html_bytes = fetch_bounded(&client, url, MAX_HTML_BYTES).await?;
    let html_str = String::from_utf8_lossy(&html_bytes).into_owned();

    let parsed_meta = parse_og_metadata(&html_str);

    // Sites that publish a designed share image deserve the layout that
    // shows it, and they say so themselves via `twitter:card` / `og:type`.
    // Provisional here because the final call needs the image's REAL size,
    // which we only know after decoding it; this just picks how big to
    // download. `convert_to_webp_preview` only ever downscales, so guessing
    // large for a small source costs nothing.
    let maybe_large =
        declares_large_card(&parsed_meta) || parsed_meta.image_w.is_some_and(|w| w >= HERO_MIN_W);
    let thumb_dim = if maybe_large { THUMB_MAX_DIM_LARGE } else { THUMB_MAX_DIM };

    // Resolve og:image to an absolute URL if present, then fetch + compress.
    let mut thumb_webp_b64 = None;
    let mut thumb_w = None;
    let mut thumb_h = None;
    if let Some(img_src) = parsed_meta.image_url.as_deref() {
        if let Ok(img_url) = parsed.join(img_src) {
            if let Ok(bytes) = fetch_bounded(&client, img_url.as_str(), MAX_IMAGE_BYTES).await {
                if let Ok((webp_bytes, w, h)) =
                    image_convert::convert_to_webp_preview(&bytes, thumb_dim)
                {
                    use base64::Engine as _;
                    let engine = base64::engine::general_purpose::STANDARD;
                    thumb_webp_b64 = Some(engine.encode(&webp_bytes));
                    thumb_w = Some(w);
                    thumb_h = Some(h);
                }
            }
        }
    }

    let rich = if wants_large_card(&parsed_meta, thumb_w, thumb_h) {
        crate::node::RichCard {
            kind: Some("large".to_string()),
            // Prefer a declared `og:video` when it is a real media file — that
            // plays inline. Otherwise point at the page, so the card still
            // gets its "there's a video here" affordance and opens it. See
            // `isDirectPlayableVideo` on the Dart side for the split.
            video_url: declares_video(&parsed_meta).then(|| {
                parsed_meta
                    .video_url
                    .clone()
                    .filter(|v| v.ends_with(".mp4") || v.ends_with(".webm"))
                    .unwrap_or_else(|| url.to_string())
            }),
            ..Default::default()
        }
        .into_opt()
    } else {
        None
    };

    Ok(LinkPreviewRef {
        url: url.to_string(),
        title: truncate_chars(&parsed_meta.title, MAX_TITLE_CHARS),
        description: truncate_chars(&parsed_meta.description, MAX_DESC_CHARS),
        domain,
        site_name: parsed_meta.site_name,
        thumb_webp_b64,
        thumb_w,
        thumb_h,
        rich,
    })
}

/// Below this width a big card is worse than a small one — a 200px logo
/// stretched across the card is blurry and silly, and plenty of sites set
/// `og:image` to exactly that.
const MIN_LARGE_THUMB_W: u32 = 320;
/// An image nobody declared a card for, but which is unmistakably a made-for-
/// sharing hero: wide, and big enough to fill the card cleanly. The classic
/// 1200x630 social image lands here.
const HERO_MIN_W: u32 = 600;
const HERO_MIN_ASPECT: f32 = 1.3;
const HERO_MAX_ASPECT: f32 = 3.0;

/// Whether the page ASKED for a big card.
///
/// No host list: the web already standardised this. `twitter:card` is the
/// site declaring which layout it wants (`summary_large_image` / `player`
/// vs the default small `summary`), and `og:type` says whether the thing is
/// a video or a track. Those tags are near-universal on anything with a
/// designed share image, which is exactly the set that deserves the layout —
/// and it stays correct for sites nobody has ever added to a list.
fn declares_large_card(meta: &ParsedMeta) -> bool {
    let card = meta.twitter_card.to_ascii_lowercase();
    if card == "summary_large_image" || card == "player" {
        return true;
    }
    let ty = meta.og_type.to_ascii_lowercase();
    ty.starts_with("video") || ty.starts_with("music")
}

/// Whether the page says it holds a video, by the same declarations.
fn declares_video(meta: &ParsedMeta) -> bool {
    meta.twitter_card.eq_ignore_ascii_case("player")
        || meta.og_type.to_ascii_lowercase().starts_with("video")
        || meta.video_url.is_some()
}

/// Final layout call, once the thumbnail is decoded and its REAL size is
/// known (a declared `og:image:width` is a hint, not a promise).
fn wants_large_card(meta: &ParsedMeta, thumb_w: Option<u32>, thumb_h: Option<u32>) -> bool {
    // No image at all: a large card is just a compact one with worse spacing.
    let (Some(w), Some(h)) = (thumb_w, thumb_h) else {
        return false;
    };
    if w < MIN_LARGE_THUMB_W {
        return false;
    }
    if declares_large_card(meta) {
        return true;
    }
    // Undeclared, but shaped like a share image. Wikipedia's square 1200x1200
    // article logo fails the aspect test here, which is the point.
    let aspect = w as f32 / h.max(1) as f32;
    w >= HERO_MIN_W && (HERO_MIN_ASPECT..=HERO_MAX_ASPECT).contains(&aspect)
}

/// Rich previews for social posts, via key-free public APIs (issue #45).
///
/// **Why adapters at all:** X serves a crawler a login wall, so the plain
/// OpenGraph path produces an empty card for the single most-pasted link type
/// there is. FxEmbed reads the post server-side and hands back structured
/// JSON; TikTok publishes a key-free oEmbed endpoint.
///
/// **Why the client calls them directly** (and not via a Hollow-run proxy):
/// FxEmbed fetches the post itself, so X never sees the user's IP for the
/// metadata either way, and someone pasting an x.com link has almost always
/// just loaded that post in a browser anyway. Proxying would also collapse
/// every user into one IP against FxEmbed's per-IP budget, so a rate limit
/// would break previews for everyone at once instead of degrading per user.
/// The genuinely new exposure is FxEmbed's operator learning that some IP
/// looked up some post — which is what the opt-in proxy override below is
/// for. See tmp3.txt D2.
///
/// **Privacy contract is unchanged:** this is still sender-side only. The
/// receiver renders bytes that travelled with the message.
mod social {
    use super::{
        fetch_bounded, truncate_chars, MAX_DESC_CHARS, MAX_IMAGE_BYTES,
        MAX_TITLE_CHARS, THUMB_MAX_DIM_LARGE,
    };
    use crate::node::image_convert;
    use crate::node::LinkPreviewRef;

    /// X and its embed-proxy mirrors. Matched as host SUFFIXES against the
    /// parsed host — never as substrings, or `x.com.evil.tld` would qualify.
    const X_HOSTS: &[&str] = &[
        "x.com", "twitter.com", "fixupx.com", "fxtwitter.com", "vxtwitter.com", "twittpr.com",
    ];
    /// TikTok and its mirrors.
    const TIKTOK_HOSTS: &[&str] = &["tiktok.com", "vxtiktok.com", "tnktok.com"];

    /// Cap on an adapter's JSON response.
    const MAX_JSON_BYTES: usize = 512 * 1_024;

    #[derive(Clone, Copy)]
    pub(super) enum Kind {
        X,
        TikTok,
    }

    /// Which adapter, if any, owns this URL.
    pub(super) fn classify(url: &reqwest::Url) -> Option<Kind> {
        let host = url.host_str()?;
        if host_matches(host, X_HOSTS) {
            Some(Kind::X)
        } else if host_matches(host, TIKTOK_HOSTS) {
            Some(Kind::TikTok)
        } else {
            None
        }
    }

    /// True when `host` IS one of `suffixes` or is a subdomain of one.
    fn host_matches(host: &str, suffixes: &[&str]) -> bool {
        let h = host.trim_end_matches('.').to_ascii_lowercase();
        suffixes
            .iter()
            .any(|s| h == *s || h.ends_with(&format!(".{s}")))
    }

    pub(super) async fn fetch(
        client: &reqwest::Client,
        url: &reqwest::Url,
        kind: Kind,
        domain: &str,
    ) -> Result<LinkPreviewRef, String> {
        // An explicitly configured proxy takes over the whole adapter step.
        // Empty (the default) means direct, which is the shipped behavior.
        let normalized = match super::embed_proxy_base() {
            Some(base) => via_proxy(client, &base, url).await?,
            None => match kind {
                Kind::X => via_fxembed(client, url).await?,
                Kind::TikTok => via_tiktok_oembed(client, url).await?,
            },
        };
        Ok(build(normalized, client, url.as_str(), domain).await)
    }

    /// What every adapter reduces to before the shared image step.
    pub(super) struct Normalized {
        pub title: String,
        pub description: String,
        pub site_name: String,
        pub author: Option<String>,
        pub image_url: Option<String>,
        pub video_url: Option<String>,
        pub video_w: Option<u32>,
        pub video_h: Option<u32>,
    }

    /// Shared tail: fetch the post's image with the sender's own connection
    /// (exactly as the OpenGraph path does) and compress it to the WebP that
    /// actually travels with the message. A failed image is not fatal — a
    /// text-only large card still beats no card.
    async fn build(
        n: Normalized,
        client: &reqwest::Client,
        url: &str,
        domain: &str,
    ) -> LinkPreviewRef {
        let mut thumb_webp_b64 = None;
        let mut thumb_w = None;
        let mut thumb_h = None;
        if let Some(img) = n.image_url.as_deref()
            && let Ok(bytes) = fetch_bounded(client, img, MAX_IMAGE_BYTES).await
            && let Ok((webp, w, h)) =
                image_convert::convert_to_webp_preview(&bytes, THUMB_MAX_DIM_LARGE)
        {
            use base64::Engine as _;
            thumb_webp_b64 = Some(base64::engine::general_purpose::STANDARD.encode(&webp));
            thumb_w = Some(w);
            thumb_h = Some(h);
        }
        LinkPreviewRef {
            url: url.to_string(),
            title: truncate_chars(&n.title, MAX_TITLE_CHARS),
            description: truncate_chars(&n.description, MAX_DESC_CHARS),
            domain: domain.to_string(),
            site_name: n.site_name,
            thumb_webp_b64,
            thumb_w,
            thumb_h,
            rich: crate::node::RichCard {
                // A post, not a page: give it the layout that holds post text.
                kind: Some("large".to_string()),
                author: n.author,
                video_url: n.video_url,
                video_w: n.video_w,
                video_h: n.video_h,
            }
            .into_opt(),
        }
    }

    /// GET a JSON document with the same caps the HTML path uses.
    async fn get_json(
        client: &reqwest::Client,
        url: &str,
    ) -> Result<serde_json::Value, String> {
        let bytes = fetch_bounded(client, url, MAX_JSON_BYTES).await?;
        serde_json::from_slice(&bytes).map_err(|e| format!("Bad JSON: {e}"))
    }

    fn str_at<'a>(v: &'a serde_json::Value, path: &[&str]) -> Option<&'a str> {
        let mut cur = v;
        for key in path {
            cur = cur.get(key)?;
        }
        cur.as_str().filter(|s| !s.is_empty())
    }

    /// api.fxtwitter.com reads the post server-side and returns structured
    /// JSON. Parsed through `Value` rather than a mirrored struct so an
    /// upstream field addition or rename degrades one field instead of
    /// failing the whole card.
    async fn via_fxembed(
        client: &reqwest::Client,
        url: &reqwest::Url,
    ) -> Result<Normalized, String> {
        let id = status_id(url).ok_or("No status id in URL")?;
        let body = get_json(client, &format!("https://api.fxtwitter.com/2/status/{id}")).await?;
        parse_fxembed(&body)
    }

    /// Pull a [`Normalized`] out of an FxEmbed response body.
    ///
    /// Split out from the request so it can be tested against real payloads:
    /// the v2 endpoint nests the post under `status` while the v1 one uses
    /// `tweet`, which is exactly the mismatch that made every X card silently
    /// fall back to plain OpenGraph on first ship. Accept either key rather
    /// than betting on one.
    fn parse_fxembed(body: &serde_json::Value) -> Result<Normalized, String> {
        let tweet = body
            .get("status")
            .or_else(|| body.get("tweet"))
            .ok_or("No status/tweet in response")?;

        let author = match (
            str_at(tweet, &["author", "name"]),
            str_at(tweet, &["author", "screen_name"]),
        ) {
            (Some(name), Some(handle)) => Some(format!("{name} (@{handle})")),
            (Some(name), None) => Some(name.to_string()),
            (None, Some(handle)) => Some(format!("@{handle}")),
            (None, None) => None,
        };

        // Prefer the video (with its own poster) over a still photo.
        let video = tweet
            .get("media")
            .and_then(|m| m.get("videos"))
            .and_then(|v| v.as_array())
            .and_then(|a| a.first());
        let photo = tweet
            .get("media")
            .and_then(|m| m.get("photos"))
            .and_then(|v| v.as_array())
            .and_then(|a| a.first());

        let (video_url, video_w, video_h, poster) = match video {
            Some(v) => (
                str_at(v, &["url"]).map(str::to_string),
                v.get("width").and_then(|x| x.as_u64()).map(|x| x as u32),
                v.get("height").and_then(|x| x.as_u64()).map(|x| x as u32),
                str_at(v, &["thumbnail_url"]).map(str::to_string),
            ),
            None => (None, None, None, None),
        };
        let image_url = poster.or_else(|| photo.and_then(|p| str_at(p, &["url"]).map(str::to_string)));

        Ok(Normalized {
            // The post text IS the content, so it goes in the description
            // where the card gives it room; the title carries attribution.
            title: author.clone().unwrap_or_else(|| "Post on X".to_string()),
            description: str_at(tweet, &["text"]).unwrap_or_default().to_string(),
            site_name: "X".to_string(),
            author,
            image_url,
            video_url,
            video_w,
            video_h,
        })
    }

    /// The `/{user}/status/{id}` segment of an X URL.
    fn status_id(url: &reqwest::Url) -> Option<String> {
        let segments: Vec<&str> = url.path_segments()?.collect();
        let idx = segments
            .iter()
            .position(|s| *s == "status" || *s == "statuses")?;
        let id = segments.get(idx + 1)?;
        let id: String = id.chars().take_while(char::is_ascii_digit).collect();
        (!id.is_empty()).then_some(id)
    }

    /// TikTok's public, key-free oEmbed endpoint. No direct mp4 is exposed,
    /// so the card is large but has no play affordance.
    async fn via_tiktok_oembed(
        client: &reqwest::Client,
        url: &reqwest::Url,
    ) -> Result<Normalized, String> {
        let mut endpoint = reqwest::Url::parse("https://www.tiktok.com/oembed")
            .map_err(|e| e.to_string())?;
        endpoint.query_pairs_mut().append_pair("url", url.as_str());
        let body = get_json(client, endpoint.as_str()).await?;

        Ok(Normalized {
            title: str_at(&body, &["title"]).unwrap_or_default().to_string(),
            description: String::new(),
            site_name: "TikTok".to_string(),
            author: str_at(&body, &["author_name"]).map(|a| format!("@{a}")),
            image_url: str_at(&body, &["thumbnail_url"]).map(str::to_string),
            video_url: None,
            video_w: None,
            video_h: None,
        })
    }

    /// Optional override: hand the whole lookup to a configured service that
    /// speaks the same normalized shape. Off by default — see `tmp3.txt` D2
    /// for the parked `embed.anonlisten.com` design.
    async fn via_proxy(
        client: &reqwest::Client,
        base: &str,
        url: &reqwest::Url,
    ) -> Result<Normalized, String> {
        let mut endpoint = reqwest::Url::parse(&format!("{}/v1/preview", base.trim_end_matches('/')))
            .map_err(|e| format!("Bad embed proxy URL: {e}"))?;
        endpoint.query_pairs_mut().append_pair("url", url.as_str());
        let body = get_json(client, endpoint.as_str()).await?;

        Ok(Normalized {
            title: str_at(&body, &["title"]).unwrap_or_default().to_string(),
            description: str_at(&body, &["description"]).unwrap_or_default().to_string(),
            site_name: str_at(&body, &["site_name"]).unwrap_or_default().to_string(),
            author: str_at(&body, &["author"]).map(str::to_string),
            image_url: str_at(&body, &["image_url"]).map(str::to_string),
            video_url: str_at(&body, &["video_url"]).map(str::to_string),
            video_w: body.get("video_w").and_then(|x| x.as_u64()).map(|x| x as u32),
            video_h: body.get("video_h").and_then(|x| x.as_u64()).map(|x| x as u32),
        })
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn u(s: &str) -> reqwest::Url {
            reqwest::Url::parse(s).unwrap()
        }

        #[test]
        fn matches_hosts_and_subdomains_only() {
            assert!(host_matches("x.com", X_HOSTS));
            assert!(host_matches("mobile.x.com", X_HOSTS));
            assert!(host_matches("WWW.Twitter.Com", X_HOSTS));
            assert!(host_matches("x.com.", X_HOSTS)); // trailing root dot
            assert!(host_matches("www.tiktok.com", TIKTOK_HOSTS));
        }

        /// The lookalike cases a substring match would wave through.
        #[test]
        fn rejects_lookalike_hosts() {
            assert!(!host_matches("x.com.evil.tld", X_HOSTS));
            assert!(!host_matches("notx.com", X_HOSTS));
            assert!(!host_matches("tiktok.com.phish.io", TIKTOK_HOSTS));
            assert!(!host_matches("example.com", X_HOSTS));
            assert!(!host_matches("fake-tiktok.com", TIKTOK_HOSTS));
        }

        #[test]
        fn classifies_by_family() {
            assert!(matches!(classify(&u("https://x.com/a/status/1")), Some(Kind::X)));
            assert!(matches!(
                classify(&u("https://vm.tiktok.com/abc")),
                Some(Kind::TikTok)
            ));
            assert!(classify(&u("https://github.com/x/status/1")).is_none());
        }

        /// Both FxEmbed response shapes must parse. The `/2/status/{id}`
        /// endpoint nests the post under `status`; the older `/status/{id}`
        /// uses `tweet`. Reading only `tweet` is what silently sent every X
        /// link back to plain OpenGraph on first ship — the card looked
        /// almost right, so nothing screamed.
        #[test]
        fn parses_both_fxembed_container_keys() {
            let inner = serde_json::json!({
                "text": "WidgetStar releases NOW!!!",
                "author": {"name": "dimden", "screen_name": "dimden"},
                "media": {"photos": [{
                    "url": "https://pbs.twimg.com/media/abc.jpg?name=orig",
                    "width": 1673, "height": 1544
                }]}
            });

            for key in ["status", "tweet"] {
                let body = serde_json::json!({ key: inner.clone(), "code": 200 });
                let n = parse_fxembed(&body).expect(key);
                assert_eq!(n.author.as_deref(), Some("dimden (@dimden)"));
                assert_eq!(n.title, "dimden (@dimden)");
                assert_eq!(n.description, "WidgetStar releases NOW!!!");
                assert_eq!(n.site_name, "X");
                assert_eq!(
                    n.image_url.as_deref(),
                    Some("https://pbs.twimg.com/media/abc.jpg?name=orig")
                );
                assert!(n.video_url.is_none(), "a photo post has no video");
            }
        }

        /// A video post yields the mp4 plus its poster, so the card can play
        /// inline instead of bouncing to the browser.
        #[test]
        fn prefers_video_over_photo_and_keeps_its_poster() {
            let body = serde_json::json!({"status": {
                "text": "clip",
                "author": {"name": "A", "screen_name": "a"},
                "media": {
                    "photos": [{"url": "https://pbs.twimg.com/still.jpg"}],
                    "videos": [{
                        "url": "https://video.twimg.com/x/vid/720x1280/v.mp4",
                        "thumbnail_url": "https://pbs.twimg.com/poster.jpg",
                        "width": 720, "height": 1280
                    }]
                }
            }});
            let n = parse_fxembed(&body).unwrap();
            assert_eq!(
                n.video_url.as_deref(),
                Some("https://video.twimg.com/x/vid/720x1280/v.mp4")
            );
            // The poster wins over the still: it belongs to the video.
            assert_eq!(n.image_url.as_deref(), Some("https://pbs.twimg.com/poster.jpg"));
            assert_eq!((n.video_w, n.video_h), (Some(720), Some(1280)));
        }

        /// A miss (deleted/private post) must be an Err so the caller falls
        /// back to OpenGraph rather than shipping an empty card.
        #[test]
        fn missing_post_is_an_error_not_an_empty_card() {
            let body = serde_json::json!({"code": 404, "message": "NOT_FOUND"});
            assert!(parse_fxembed(&body).is_err());
        }

        #[test]
        fn extracts_status_ids() {
            assert_eq!(
                status_id(&u("https://x.com/someone/status/1234567890")).as_deref(),
                Some("1234567890")
            );
            // Trailing junk (query-ish path noise, photo sub-paths) is trimmed.
            assert_eq!(
                status_id(&u("https://twitter.com/a/status/42/photo/1")).as_deref(),
                Some("42")
            );
            assert!(status_id(&u("https://x.com/someone")).is_none());
            assert!(status_id(&u("https://x.com/a/status/notanid")).is_none());
        }
    }
}

/// Fetch a URL, streaming the body and aborting if it exceeds `max_bytes`.
async fn fetch_bounded(
    client: &reqwest::Client,
    url: &str,
    max_bytes: usize,
) -> Result<Vec<u8>, String> {
    let resp = client
        .get(url)
        .send()
        .await
        .map_err(|e| format!("HTTP request failed: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status()));
    }

    // If Content-Length is known and exceeds our cap, bail early.
    if let Some(len) = resp.content_length() {
        if len as usize > max_bytes {
            return Err(format!("Response too large: {len} bytes"));
        }
    }

    let bytes = resp
        .bytes()
        .await
        .map_err(|e| format!("Failed to read body: {e}"))?;
    if bytes.len() > max_bytes {
        return Err(format!("Response exceeded {max_bytes} bytes"));
    }
    Ok(bytes.to_vec())
}

/// Extracted OG metadata.
#[derive(Default)]
struct ParsedMeta {
    title: String,
    description: String,
    site_name: String,
    image_url: Option<String>,
    /// `og:type` — `website`, `article`, `video.other`, `music.song`, …
    og_type: String,
    /// `twitter:card` — `summary`, `summary_large_image`, `player`. The site
    /// declaring which layout it wants.
    twitter_card: String,
    /// `og:video` / `og:video:url` when present.
    video_url: Option<String>,
    /// Declared `og:image:width`, used only to pick the download size before
    /// we can measure the real thing.
    image_w: Option<u32>,
}

/// Parse OpenGraph tags from HTML with sensible fallbacks.
///
/// Preference order:
/// - title: `og:title` → `<title>` → ""
/// - description: `og:description` → `<meta name="description">` → ""
/// - site_name: `og:site_name` → ""
/// - image: `og:image` → `twitter:image` → None
fn parse_og_metadata(html: &str) -> ParsedMeta {
    let doc = Html::parse_document(html);

    // Scraper selectors are expensive to parse, so build them once per call.
    // Safe unwrap — these are static CSS selectors.
    let meta_sel = Selector::parse("meta").unwrap();
    let title_sel = Selector::parse("title").unwrap();

    // Collect all <meta> tags indexed by name/property.
    let mut og_title = None;
    let mut og_desc = None;
    let mut og_site = None;
    let mut og_image = None;
    let mut meta_desc = None;
    let mut twitter_image = None;
    let mut og_type = String::new();
    let mut twitter_card = String::new();
    let mut og_video = None;
    let mut image_w = None;

    for el in doc.select(&meta_sel) {
        let attrs = el.value();
        let prop = attrs.attr("property").or_else(|| attrs.attr("name"));
        let content = attrs.attr("content");
        if let (Some(key), Some(val)) = (prop, content) {
            if val.is_empty() {
                continue;
            }
            let key_lc = key.to_ascii_lowercase();
            match key_lc.as_str() {
                "og:title" => og_title = Some(val.to_string()),
                "og:description" => og_desc = Some(val.to_string()),
                "og:site_name" => og_site = Some(val.to_string()),
                "og:image" => og_image = Some(val.to_string()),
                "description" => meta_desc = Some(val.to_string()),
                "twitter:image" | "twitter:image:src" => {
                    twitter_image = Some(val.to_string())
                }
                // Layout declarations (issue #45) — see `wants_large_card`.
                "og:type" => og_type = val.to_string(),
                "twitter:card" => twitter_card = val.to_string(),
                "og:video" | "og:video:url" | "og:video:secure_url" => {
                    og_video.get_or_insert_with(|| val.to_string());
                }
                "og:image:width" => image_w = val.parse::<u32>().ok(),
                _ => {}
            }
        }
    }

    // Fallback to <title> tag if og:title is missing.
    let title_tag = doc
        .select(&title_sel)
        .next()
        .map(|el| el.text().collect::<String>().trim().to_string());

    ParsedMeta {
        title: og_title.or(title_tag).unwrap_or_default(),
        description: og_desc.or(meta_desc).unwrap_or_default(),
        site_name: og_site.unwrap_or_default(),
        image_url: og_image.or(twitter_image),
        og_type,
        twitter_card,
        video_url: og_video,
        image_w,
    }
}

/// Truncate `s` to at most `max_chars` Unicode characters, not bytes.
fn truncate_chars(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    s.chars().take(max_chars).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_full_og_metadata() {
        let html = r#"
            <html><head>
                <title>Fallback Title</title>
                <meta property="og:title" content="OG Title">
                <meta property="og:description" content="A nice description">
                <meta property="og:site_name" content="Example Site">
                <meta property="og:image" content="https://example.com/image.png">
            </head></html>
        "#;
        let m = parse_og_metadata(html);
        assert_eq!(m.title, "OG Title");
        assert_eq!(m.description, "A nice description");
        assert_eq!(m.site_name, "Example Site");
        assert_eq!(m.image_url.as_deref(), Some("https://example.com/image.png"));
    }

    #[test]
    fn falls_back_to_title_tag_and_meta_description() {
        let html = r#"
            <html><head>
                <title>Plain Title</title>
                <meta name="description" content="Plain meta description">
            </head></html>
        "#;
        let m = parse_og_metadata(html);
        assert_eq!(m.title, "Plain Title");
        assert_eq!(m.description, "Plain meta description");
        assert_eq!(m.site_name, "");
        assert_eq!(m.image_url, None);
    }

    #[test]
    fn twitter_image_fallback() {
        let html = r#"
            <html><head>
                <meta property="og:title" content="Hi">
                <meta name="twitter:image" content="https://example.com/t.jpg">
            </head></html>
        "#;
        let m = parse_og_metadata(html);
        assert_eq!(m.image_url.as_deref(), Some("https://example.com/t.jpg"));
    }

    #[test]
    fn malformed_html_does_not_panic() {
        let html = "<html><head><meta property='og:title' content='broken";
        let _m = parse_og_metadata(html);
        // Just must not panic.
    }

    #[test]
    fn empty_html_returns_empty_fields() {
        let m = parse_og_metadata("");
        assert_eq!(m.title, "");
        assert_eq!(m.description, "");
        assert_eq!(m.site_name, "");
        assert_eq!(m.image_url, None);
    }

    /// The layout comes from what the SITE declares, not from a host list —
    /// so it is already right for sites nobody has ever heard of.
    ///
    /// Fixtures are the real tags, measured 2026-08-02 from the live pages.
    #[test]
    fn sites_that_declare_a_big_card_get_one() {
        let cases: &[(&str, &str, &str, u32, u32)] = &[
            // (what, twitter:card, og:type, thumb w, thumb h)
            ("semgrep.dev", "summary_large_image", "website", 1366, 768),
            ("github repo", "summary_large_image", "object", 1200, 600),
            ("youtube watch", "player", "video.other", 1280, 720),
            ("instagram reel", "summary_large_image", "article", 640, 800),
            // Nobody declared anything, but 1200x630 is unmistakably a
            // made-for-sharing hero.
            ("undeclared hero", "", "", 1200, 630),
        ];
        for (what, card, ty, w, h) in cases {
            let meta = ParsedMeta {
                twitter_card: card.to_string(),
                og_type: ty.to_string(),
                ..Default::default()
            };
            assert!(wants_large_card(&meta, Some(*w), Some(*h)), "{what}");
        }
    }

    /// The cases a naive "big image → big card" rule would get wrong.
    #[test]
    fn undeclared_and_unsuitable_images_stay_compact() {
        let plain = ParsedMeta::default();

        // Wikipedia: no card declaration and a SQUARE 1200x1200 article logo.
        // Big, but not a share image — a giant square reads badly.
        assert!(!wants_large_card(&plain, Some(1200), Some(1200)));

        // The common case of og:image being a small site logo.
        assert!(!wants_large_card(&plain, Some(200), Some(200)));

        // Even a declared large card is refused when the image is too small
        // to fill it — stretching a 180px logo looks worse than a row.
        let declared = ParsedMeta {
            twitter_card: "summary_large_image".to_string(),
            ..Default::default()
        };
        assert!(!wants_large_card(&declared, Some(180), Some(180)));

        // No image at all (Hacker News).
        assert!(!wants_large_card(&declared, None, None));

        // An explicit small card is honoured.
        let small = ParsedMeta {
            twitter_card: "summary".to_string(),
            ..Default::default()
        };
        assert!(!wants_large_card(&small, Some(400), Some(400)));
    }

    /// The play affordance follows the same declarations.
    #[test]
    fn video_affordance_follows_declarations() {
        let yt = ParsedMeta {
            twitter_card: "player".to_string(),
            og_type: "video.other".to_string(),
            ..Default::default()
        };
        assert!(declares_video(&yt));

        let music = ParsedMeta {
            og_type: "music.song".to_string(),
            ..Default::default()
        };
        // Music gets the big art card, but nothing to play.
        assert!(declares_large_card(&music));
        assert!(!declares_video(&music));

        let article = ParsedMeta {
            twitter_card: "summary_large_image".to_string(),
            og_type: "article".to_string(),
            ..Default::default()
        };
        assert!(!declares_video(&article));
    }

    /// og:type / twitter:card are parsed out of real-shaped HTML.
    #[test]
    fn parses_card_declarations() {
        let html = r#"<html><head>
            <meta property="og:type" content="video.other">
            <meta name="twitter:card" content="player">
            <meta property="og:image:width" content="1280">
            <meta property="og:video:url" content="https://cdn.example/v.mp4">
        </head></html>"#;
        let m = parse_og_metadata(html);
        assert_eq!(m.og_type, "video.other");
        assert_eq!(m.twitter_card, "player");
        assert_eq!(m.image_w, Some(1280));
        assert_eq!(m.video_url.as_deref(), Some("https://cdn.example/v.mp4"));
        assert!(declares_large_card(&m) && declares_video(&m));
    }

    #[test]
    fn truncate_chars_respects_unicode() {
        // 5 emoji, each multi-byte. truncate_chars(3) should keep 3 code points.
        let s = "🙂🙂🙂🙂🙂";
        let truncated = truncate_chars(s, 3);
        assert_eq!(truncated.chars().count(), 3);
    }

    #[test]
    fn truncate_chars_noop_if_short_enough() {
        let s = "hello";
        assert_eq!(truncate_chars(s, 200), "hello");
    }

    /// Regression guard for the YouTube case: OG tags buried deep inside
    /// a huge bloated HTML document. As long as MAX_HTML_BYTES is large
    /// enough to fit the whole doc, parse_og_metadata should extract the
    /// tags correctly regardless of position.
    #[test]
    fn parses_youtube_shaped_html() {
        // Realistic YouTube structure: head with OG tags, followed by a
        // huge inline JSON blob that pushes total size past 1 MB.
        let padding = "x".repeat(600_000);
        let html = format!(
            r#"<!DOCTYPE html><html><head>
<meta property="og:site_name" content="YouTube">
<meta property="og:title" content="How Elon Musk Spends His Time">
<meta property="og:description" content="Sam Altman asked Elon Musk how he spends his time.">
<meta property="og:image" content="https://i.ytimg.com/vi/qszGzNoopTc/maxresdefault.jpg">
<script>var x = "{padding}";</script>
</head><body></body></html>"#
        );
        let m = parse_og_metadata(&html);
        assert_eq!(m.title, "How Elon Musk Spends His Time");
        assert_eq!(m.site_name, "YouTube");
        assert_eq!(
            m.description,
            "Sam Altman asked Elon Musk how he spends his time."
        );
        assert_eq!(
            m.image_url.as_deref(),
            Some("https://i.ytimg.com/vi/qszGzNoopTc/maxresdefault.jpg")
        );
    }
}
