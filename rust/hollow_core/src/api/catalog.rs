//! Picker previews from the catalogs our own searches ask (GIFs and stickers, FFZ
//! emotes, IGDB covers): fetched only from the addresses those searches hand out and
//! handed to Dart only once the image check has decoded them whole (AR-28). The
//! upstream art behind our proxies is nobody's we trust.

use std::collections::VecDeque;
use std::sync::{Mutex, OnceLock};

use flutter_rust_bridge::frb;

use super::network::get_http_runtime;
use crate::node::image_gate::{judge_for_ffi, Verdict};

/// The proxy caps what it caches at 6 MB; anything bigger is not ours.
#[frb(ignore)]
const MAX_PREVIEW_BYTES: usize = 6 * 1024 * 1024 + 64 * 1024;

#[frb(ignore)]
const NOT_A_CATALOG: &str = "That preview is not from a Hollow catalog";

/// Whether `url` is one of the preview addresses a catalog search of ours hands out.
#[frb(ignore)]
pub(crate) fn preview_url_allowed(url: &str) -> bool {
    url_under(url, super::emotes::FFZ_IMAGE_BASE)
        || url_under(url, super::showcase::COVER_BASE)
        || super::gifs::media_url_permitted(url)
}

/// `url` read the way reqwest will fetch it, when it is plain https: no userinfo, a
/// host, and no encoded path separator a server could decode past our prefix. The
/// parse resolves dot segments and treats a backslash as a slash, so an allowlist
/// judges the host and path the request really goes to.
#[frb(ignore)]
pub(crate) fn https_url(url: &str) -> Option<reqwest::Url> {
    let after = url.strip_prefix("https://")?;
    if after.starts_with(['/', '\\']) {
        return None;
    }
    let u = reqwest::Url::parse(url).ok()?;
    let path = u.path().to_ascii_lowercase();
    (u.scheme() == "https"
        && u.username().is_empty()
        && u.password().is_none()
        && u.host_str().is_some_and(|h| !h.is_empty())
        && !path.contains("%2f")
        && !path.contains("%5c"))
    .then_some(u)
}

/// Whether `url` sits under `base` (an https address ending in '/'): the same host and
/// port, and a path below base's, both as reqwest reads them.
#[frb(ignore)]
pub(crate) fn url_under(url: &str, base: &str) -> bool {
    let (Some(u), Some(b)) = (https_url(url), https_url(base)) else { return false };
    u.host_str() == b.host_str()
        && u.port_or_known_default() == b.port_or_known_default()
        && b.path().ends_with('/')
        && u.path().starts_with(b.path())
}

/// A catalog preview's bytes, once the image check passed them. Errs with the
/// at-rest image errors, so Dart waits on a check exactly as it does for a file.
#[frb]
pub fn fetch_catalog_preview(url: String) -> Result<Vec<u8>, String> {
    preview_from(url, fetch)
}

#[frb(ignore)]
fn preview_from(url: String, fetch: impl FnOnce(String) -> Result<Vec<u8>, String>) -> Result<Vec<u8>, String> {
    preview_with(url, fetch, judge_for_ffi)
}

#[frb(ignore)]
fn preview_with(
    url: String,
    fetch: impl FnOnce(String) -> Result<Vec<u8>, String>,
    judge: impl FnOnce(&[u8]) -> Verdict,
) -> Result<Vec<u8>, String> {
    if !preview_url_allowed(&url) {
        return Err(NOT_A_CATALOG.into());
    }
    let bytes = match take_held(&url) {
        Some(bytes) => bytes,
        None => fetch(url.clone())?,
    };
    shown_or_held(&url, bytes, judge)
}

/// Fetched images the check was too busy for, at most this many and this many bytes.
#[frb(ignore)]
const MAX_HELD: usize = 16;
#[frb(ignore)]
const HELD_BYTES: usize = 32 * 1024 * 1024;

#[frb(ignore)]
fn held() -> &'static Mutex<VecDeque<(String, Vec<u8>)>> {
    static HELD: OnceLock<Mutex<VecDeque<(String, Vec<u8>)>>> = OnceLock::new();
    HELD.get_or_init(Default::default)
}

/// The bytes an earlier ask for `key` fetched while the image check was busy.
#[frb(ignore)]
pub(crate) fn take_held(key: &str) -> Option<Vec<u8>> {
    let mut held = held().lock().ok()?;
    let at = held.iter().position(|(k, _)| k == key)?;
    held.remove(at).map(|(_, bytes)| bytes)
}

/// `bytes` once `judge` passes them. While it is still busy they are kept under
/// `key`, so the re-ask Dart makes judges them again instead of downloading them
/// again; the oldest kept go first.
#[frb(ignore)]
pub(crate) fn shown_or_held(key: &str, bytes: Vec<u8>, judge: impl FnOnce(&[u8]) -> Verdict) -> Result<Vec<u8>, String> {
    match judge(&bytes) {
        Verdict::Pass => Ok(bytes),
        Verdict::Refused => Err(super::at_rest::IMAGE_REFUSED.into()),
        Verdict::NotYet => {
            if let Ok(mut held) = held().lock() {
                held.retain(|(k, _)| k != key);
                held.push_back((key.to_string(), bytes));
                while held.len() > MAX_HELD || held.iter().map(|(_, b)| b.len()).sum::<usize>() > HELD_BYTES {
                    held.pop_front();
                }
            }
            Err(super::at_rest::IMAGE_NOT_YET.into())
        }
    }
}

/// The client every catalog request is made with (searches, previews, picks, emote
/// and cover imports). Redirects are refused: our allowlists name addresses, and a
/// 3xx from any of them would walk the request to a host none of them names.
#[frb(ignore)]
pub(crate) fn catalog_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .user_agent(format!("Hollow/{}", super::updater::APP_VERSION))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| format!("Hollow could not start the request: {e}"))
}

#[frb(ignore)]
fn fetch(url: String) -> Result<Vec<u8>, String> {
    get_http_runtime()?.block_on(async move {
        let resp = catalog_client()?
            .get(&url)
            .timeout(std::time::Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| format!("The preview could not be fetched: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("The preview could not be fetched: HTTP {}", resp.status().as_u16()));
        }
        read_capped(resp).await
    })
}

#[frb(ignore)]
async fn read_capped(resp: reqwest::Response) -> Result<Vec<u8>, String> {
    use futures_util::StreamExt;
    if resp.content_length().is_some_and(|len| len > MAX_PREVIEW_BYTES as u64) {
        return Err("The preview is larger than Hollow will read".into());
    }
    let mut out = Vec::new();
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("The preview could not be fetched: {e}"))?;
        if out.len() + chunk.len() > MAX_PREVIEW_BYTES {
            return Err("The preview is larger than Hollow will read".into());
        }
        out.extend_from_slice(&chunk);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Only the addresses our own catalog searches hand out are fetched: a picker can
    /// never be pointed at another host, or at plain http.
    #[test]
    fn only_catalog_addresses_are_fetched() {
        for ok in [
            format!("{}123.png", super::super::emotes::FFZ_IMAGE_BASE),
            format!("{}co1x.jpg", super::super::showcase::COVER_BASE),
            "https://hollow.anonlisten.com/gifs/m/abc.webp".to_string(),
        ] {
            assert!(preview_url_allowed(&ok), "{ok} was refused");
        }
        for bad in [
            "https://evil.example/ffz/emotes/1.png",
            "http://hollow.anonlisten.com/ffz/emotes/1.png",
            "https://hollow.anonlisten.com.evil.example/gifs/x.webp",
            "file:///etc/passwd",
        ] {
            assert!(!preview_url_allowed(bad), "{bad} was allowed");
            assert_eq!(preview_from(bad.to_string(), |_| panic!("{bad} was fetched")), Err(NOT_A_CATALOG.into()));
        }
    }

    /// A tiny PNG an honest catalog would send.
    pub(crate) fn png() -> Vec<u8> {
        let mut out = std::io::Cursor::new(Vec::new());
        image::RgbaImage::new(4, 4).write_to(&mut out, image::ImageFormat::Png).expect("encode");
        out.into_inner()
    }

    /// A preview reaches Dart only once it decodes whole: a picture that does not is
    /// refused, whatever answered for it.
    #[test]
    fn a_preview_reaches_dart_only_after_the_image_check() {
        let url = format!("{}9.png", super::super::emotes::FFZ_IMAGE_BASE);
        let good = png();
        assert_eq!(preview_from(url.clone(), |_| Ok(good.clone())), Ok(good.clone()));
        let mut torn = good.clone();
        torn.truncate(good.len() / 2);
        assert!(preview_from(url, |_| Ok(torn)).is_err(), "a torn picture reached Dart");
    }

    /// A catalog answer that redirects is never followed, and no catalog fetcher
    /// builds a client that would follow one.
    #[test]
    fn catalog_fetchers_refuse_redirects() {
        use std::io::{Read, Write};
        let elsewhere = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let target = format!("http://{}/stolen", elsewhere.local_addr().unwrap());
        elsewhere.set_nonblocking(true).unwrap();
        let catalog = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let url = format!("http://{}/ffz/emotes/1.png", catalog.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (mut s, _) = catalog.accept().expect("accept");
            let mut buf = [0u8; 2048];
            let _ = s.read(&mut buf);
            let _ = write!(s, "HTTP/1.1 302 Found\r\nLocation: {target}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        });
        let status = get_http_runtime().expect("http runtime").block_on(async {
            let ask = catalog_client().unwrap().get(&url).timeout(std::time::Duration::from_secs(5));
            ask.send().await.map(|r| r.status().as_u16())
        });
        server.join().unwrap();
        assert_eq!(status.ok(), Some(302), "the redirect was followed");
        assert!(elsewhere.accept().is_err(), "the redirect's host was asked");

        let src = |f: &str| {
            std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/api").join(f))
                .expect("read api source")
        };
        for f in ["gifs.rs", "emotes.rs", "showcase.rs", "catalog.rs"] {
            let all = src(f);
            let code = all.split("#[cfg(test)]").next().unwrap_or_default();
            assert!(!code.contains("Client::new()"), "{f} builds a client that follows redirects");
            assert_eq!(code.matches("Client::builder()").count(), usize::from(f == "catalog.rs"), "{f} builds its own client");
        }
    }

    /// A preview the image check was too busy for is judged again from the bytes kept
    /// the first time: the re-ask downloads nothing, and what is kept stays bounded.
    #[test]
    fn a_preview_still_being_checked_is_never_fetched_twice() {
        let url = format!("{}held.png", super::super::emotes::FFZ_IMAGE_BASE);
        let good = png();
        let fetches = std::cell::Cell::new(0);
        let fetch = |_| {
            fetches.set(fetches.get() + 1);
            Ok(good.clone())
        };
        let not_yet: Result<Vec<u8>, String> = Err(super::super::at_rest::IMAGE_NOT_YET.into());
        assert_eq!(preview_with(url.clone(), fetch, |_| Verdict::NotYet), not_yet);
        assert_eq!(preview_with(url.clone(), fetch, |_| Verdict::NotYet), not_yet);
        assert_eq!(preview_with(url.clone(), fetch, |_| Verdict::Pass), Ok(good.clone()));
        assert_eq!(fetches.get(), 1, "a re-ask downloaded the preview again");
        assert_eq!(preview_with(url, fetch, |_| Verdict::Pass), Ok(good.clone()));
        assert_eq!(fetches.get(), 2, "a preview already handed over was kept");
        for i in 0..MAX_HELD + 4 {
            let _ = shown_or_held(&format!("bound-{i}"), good.clone(), |_| Verdict::NotYet);
        }
        assert!(held().lock().unwrap().len() <= MAX_HELD, "the kept previews grew past their bound");
    }

    /// Every catalog address is judged as reqwest will fetch it: a backslash or an
    /// '@' in the authority cannot name one host to the check and another to the
    /// fetch, and a dot segment cannot step out of the catalog's path.
    #[test]
    fn catalog_preview_refuses_a_backslash_authority() {
        let ffz = super::super::emotes::FFZ_IMAGE_BASE;
        let cover = super::super::showcase::COVER_BASE;
        for bad in [
            "https://evil.example\\@hollow.anonlisten.com/gifs/m/x.webp".to_string(),
            "https://evil.example\\@hollow.anonlisten.com/ffz/emotes/1.png".to_string(),
            "https://user@hollow.anonlisten.com/gifs/m/x.webp".to_string(),
            format!("{ffz}../../shop/redeem.php"),
            format!("{cover}%2e%2e/%2e%2e/secret"),
            format!("{cover}..%2f..%2fsecret"),
            format!("{ffz}..\\..\\secret"),
            "https://hollow.anonlisten.com:8443/gifs/m/x.webp".to_string(),
        ] {
            assert!(!preview_url_allowed(&bad), "{bad} was allowed");
        }
        // Judged where it lands: under the covers, not under the emotes.
        assert!(!url_under(&format!("{ffz}../../igdb/covers/x.jpg"), ffz));
        assert!(url_under(&format!("{ffz}../../igdb/covers/x.jpg"), cover));
        assert!(url_under(&format!("{ffz}1.png"), ffz));
        let refused = |r: Result<(), String>| r.is_err_and(|e| e.contains("not on the Hollow CDN"));
        assert!(refused(super::super::emotes::ffz_import_emote(format!("{ffz}../../x.png")).map(drop)), "the FFZ import stepped out of the CDN");
        assert!(refused(super::super::showcase::showcase_fetch_cover(format!("{cover}../../x.png")).map(drop)), "the cover fetch stepped out of the CDN");
        assert!(url_under("https://HOLLOW.anonlisten.com:443/ffz/emotes/2.png", ffz));
    }
}
