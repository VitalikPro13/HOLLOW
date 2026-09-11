//! Loopback HTTP server for at-rest media (issue 78).
//!
//! fvp/mdk and audioplayers can only take a URL, so encrypted attachments are
//! served from `127.0.0.1` and decrypted per range on the way out. Confined to
//! the data root and gated on a per-process random token, because any local
//! program can reach a loopback port.

use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Semaphore;

use super::at_rest;

const MAX_HEAD_BYTES: usize = 8 * 1024;
const IDLE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
const MAX_CONNECTIONS: usize = 64;
const STREAM_PIECE: usize = 1024 * 1024;

fn server_slot() -> &'static Mutex<Option<(u16, String)>> {
    static SLOT: OnceLock<Mutex<Option<(u16, String)>>> = OnceLock::new();
    SLOT.get_or_init(|| Mutex::new(None))
}

/// A `http://127.0.0.1:…` URL a media player can open for `path`. Starts the
/// server on first use.
pub fn media_url(path: &Path) -> Result<String, String> {
    let root = canonical_root()?;
    let full = std::fs::canonicalize(path).map_err(|e| format!("Failed to resolve path: {e}"))?;
    let rel = full
        .strip_prefix(&root)
        .map_err(|_| "Media must live under the Hollow data folder".to_string())?;
    let rel = rel
        .components()
        .map(|c| c.as_os_str().to_string_lossy().to_string())
        .collect::<Vec<_>>()
        .join("/");

    let (port, token) = ensure_started()?;
    Ok(format!("http://127.0.0.1:{port}/{token}/{}", percent_encode(&rel)))
}

fn canonical_root() -> Result<PathBuf, String> {
    let dir = crate::identity::data_dir()?;
    std::fs::canonicalize(&dir).map_err(|e| format!("Failed to resolve data folder: {e}"))
}

fn ensure_started() -> Result<(u16, String), String> {
    let mut slot = server_slot().lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    if let Some(existing) = slot.as_ref() {
        return Ok(existing.clone());
    }
    let mut raw = [0u8; 32];
    getrandom::fill(&mut raw).map_err(|e| format!("RNG failed: {e}"))?;
    let token = hex::encode(raw);

    let rt = crate::api::network::get_runtime();
    let listener = rt
        .block_on(async { TcpListener::bind(("127.0.0.1", 0)).await })
        .map_err(|e| format!("Failed to start the local media server: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("Failed to read the local media port: {e}"))?
        .port();

    let token_for_task = token.clone();
    rt.spawn(async move { accept_loop(listener, token_for_task).await });
    *slot = Some((port, token.clone()));
    Ok((port, token))
}

async fn accept_loop(listener: TcpListener, token: String) {
    let permits = std::sync::Arc::new(Semaphore::new(MAX_CONNECTIONS));
    loop {
        // The permit is taken BEFORE accept so an over-limit client waits in the
        // backlog instead of being accepted and starved.
        let Ok(permit) = permits.clone().acquire_owned().await else { return };
        let Ok((stream, _)) = listener.accept().await else { continue };
        let token = token.clone();
        tokio::spawn(async move {
            let _permit = permit;
            let _ = serve_connection(stream, &token).await;
        });
    }
}

async fn serve_connection(mut stream: TcpStream, token: &str) -> std::io::Result<()> {
    let mut buf: Vec<u8> = Vec::with_capacity(1024);
    loop {
        let Some(head) = read_head(&mut stream, &mut buf).await? else { return Ok(()) };
        let Some(req) = parse_request(&head) else {
            return Ok(());
        };
        let keep = !req.close;
        respond(&mut stream, &req, token, keep).await?;
        if !keep {
            return Ok(());
        }
    }
}

/// Read one request head. `None` means the peer closed, the head overran the cap
/// or the socket went idle; every one of those ends the connection.
async fn read_head(stream: &mut TcpStream, buf: &mut Vec<u8>) -> std::io::Result<Option<Vec<u8>>> {
    loop {
        if let Some(at) = find_head_end(buf) {
            let head = buf[..at].to_vec();
            buf.drain(..at + 4);
            return Ok(Some(head));
        }
        if buf.len() > MAX_HEAD_BYTES {
            return Ok(None);
        }
        let mut chunk = [0u8; 1024];
        let n = match tokio::time::timeout(IDLE_TIMEOUT, stream.read(&mut chunk)).await {
            Ok(Ok(0)) | Err(_) => return Ok(None),
            Ok(Ok(n)) => n,
            Ok(Err(e)) => return Err(e),
        };
        buf.extend_from_slice(&chunk[..n]);
    }
}

fn find_head_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n")
}

struct Request {
    head_only: bool,
    target: String,
    range: Option<String>,
    close: bool,
}

fn parse_request(head: &[u8]) -> Option<Request> {
    let text = std::str::from_utf8(head).ok()?;
    let mut lines = text.split("\r\n");
    let mut parts = lines.next()?.split(' ');
    let method = parts.next()?;
    let target = parts.next()?.to_string();
    let version = parts.next()?;
    if !version.starts_with("HTTP/1.") {
        return None;
    }
    let head_only = match method {
        "GET" => false,
        "HEAD" => true,
        _ => return None,
    };
    let mut range = None;
    let mut close = version == "HTTP/1.0";
    for line in lines {
        let Some((name, value)) = line.split_once(':') else { continue };
        match name.trim().to_ascii_lowercase().as_str() {
            "range" => range = Some(value.trim().to_string()),
            "connection" => close = value.trim().eq_ignore_ascii_case("close"),
            _ => {}
        }
    }
    Some(Request { head_only, target, range, close })
}

async fn respond(
    stream: &mut TcpStream,
    req: &Request,
    token: &str,
    keep: bool,
) -> std::io::Result<()> {
    let Some(path) = resolve(&req.target, token) else {
        return write_status(stream, 404, "Not Found", keep).await;
    };
    let Ok(total) = at_rest::plaintext_len(&path) else {
        return write_status(stream, 404, "Not Found", keep).await;
    };

    let (start, end, partial) = match req.range.as_deref() {
        None => (0u64, total.saturating_sub(1), false),
        Some(spec) => match parse_range(spec, total) {
            Some(r) => (r.0, r.1, true),
            None => return write_status(stream, 416, "Range Not Satisfiable", keep).await,
        },
    };
    if total == 0 {
        return write_status(stream, 200, "OK", keep).await;
    }
    let len = end - start + 1;

    let mut head = String::new();
    if partial {
        head.push_str("HTTP/1.1 206 Partial Content\r\n");
        head.push_str(&format!("Content-Range: bytes {start}-{end}/{total}\r\n"));
    } else {
        head.push_str("HTTP/1.1 200 OK\r\n");
    }
    head.push_str(&format!("Content-Type: {}\r\n", content_type(&path)));
    head.push_str(&format!("Content-Length: {len}\r\n"));
    head.push_str("Accept-Ranges: bytes\r\n");
    head.push_str("Cache-Control: no-store\r\n");
    head.push_str(if keep { "Connection: keep-alive\r\n\r\n" } else { "Connection: close\r\n\r\n" });
    stream.write_all(head.as_bytes()).await?;
    if req.head_only {
        return stream.flush().await;
    }

    // A failure here lands AFTER a Content-Length the client is already counting
    // against, so the connection has to die rather than let the next request head be
    // read against a half-sent body.
    let mut at = start;
    while at <= end {
        let take = ((end - at + 1) as usize).min(STREAM_PIECE);
        let p = path.clone();
        let bytes = match tokio::task::spawn_blocking(move || at_rest::read_range(&p, at, take)).await
        {
            Ok(Ok(b)) if !b.is_empty() => b,
            _ => return Err(std::io::Error::other("at-rest read failed mid-body")),
        };
        stream.write_all(&bytes).await?;
        at += bytes.len() as u64;
    }
    stream.flush().await
}

async fn write_status(
    stream: &mut TcpStream,
    code: u16,
    reason: &str,
    keep: bool,
) -> std::io::Result<()> {
    let conn = if keep { "keep-alive" } else { "close" };
    let head = format!(
        "HTTP/1.1 {code} {reason}\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: {conn}\r\n\r\n"
    );
    stream.write_all(head.as_bytes()).await?;
    stream.flush().await
}

/// `/{token}/{rel}` to an absolute path, or `None` for a bad token or anything
/// that does not resolve under the data root.
fn resolve(target: &str, token: &str) -> Option<PathBuf> {
    let target = target.split(['?', '#']).next().unwrap_or(target);
    let rest = target.strip_prefix('/')?;
    let (given, rel) = rest.split_once('/')?;
    if !constant_time_eq(given.as_bytes(), token.as_bytes()) {
        return None;
    }
    let rel = percent_decode(rel)?;
    let relp = PathBuf::from(rel.replace('\\', "/"));
    if relp.components().any(|c| !matches!(c, Component::Normal(_))) {
        return None;
    }
    let root = canonical_root().ok()?;
    let full = std::fs::canonicalize(root.join(relp)).ok()?;
    full.starts_with(&root).then_some(full)
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// One range only. `bytes=a-b`, `bytes=a-`, `bytes=-n`; anything else is 416.
fn parse_range(spec: &str, total: u64) -> Option<(u64, u64)> {
    let body = spec.strip_prefix("bytes=")?;
    if body.contains(',') || total == 0 {
        return None;
    }
    let (from, to) = body.split_once('-')?;
    let (start, end) = if from.is_empty() {
        let n: u64 = to.trim().parse().ok()?;
        if n == 0 {
            return None;
        }
        (total.saturating_sub(n), total - 1)
    } else {
        let start: u64 = from.trim().parse().ok()?;
        let end = if to.trim().is_empty() {
            total - 1
        } else {
            to.trim().parse::<u64>().ok()?.min(total - 1)
        };
        (start, end)
    };
    (start <= end && start < total).then_some((start, end))
}

fn content_type(path: &Path) -> &'static str {
    static TYPES: OnceLock<HashMap<&'static str, &'static str>> = OnceLock::new();
    let map = TYPES.get_or_init(|| {
        HashMap::from([
            ("mp4", "video/mp4"),
            ("m4v", "video/mp4"),
            ("webm", "video/webm"),
            ("mkv", "video/x-matroska"),
            ("mov", "video/quicktime"),
            ("ogg", "audio/ogg"),
            ("oga", "audio/ogg"),
            ("opus", "audio/ogg"),
            ("wav", "audio/wav"),
            ("mp3", "audio/mpeg"),
            ("m4a", "audio/mp4"),
            ("aac", "audio/aac"),
            ("flac", "audio/flac"),
            ("webp", "image/webp"),
            ("png", "image/png"),
            ("jpg", "image/jpeg"),
            ("jpeg", "image/jpeg"),
            ("gif", "image/gif"),
        ])
    });
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .and_then(|e| map.get(e.as_str()).copied())
        .unwrap_or("application/octet-stream")
}

fn percent_encode(rel: &str) -> String {
    let mut out = String::with_capacity(rel.len());
    for b in rel.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~' | b'/') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn percent_decode(s: &str) -> Option<String> {
    let raw = s.as_bytes();
    let mut out = Vec::with_capacity(raw.len());
    let mut i = 0;
    while i < raw.len() {
        if raw[i] == b'%' {
            let hex = raw.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(std::str::from_utf8(hex).ok()?, 16).ok()?);
            i += 3;
        } else {
            out.push(raw[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Read, Write};

    fn http(port: u16, req: &str) -> (String, Vec<u8>) {
        let mut sock = std::net::TcpStream::connect(("127.0.0.1", port)).expect("connect");
        sock.write_all(req.as_bytes()).expect("send");
        let mut reader = BufReader::new(sock);
        read_one(&mut reader, req.starts_with("HEAD "))
    }

    /// A HEAD response announces the length it WOULD send and sends no body, so
    /// the caller says which it asked for.
    fn read_one(
        reader: &mut BufReader<std::net::TcpStream>,
        head_only: bool,
    ) -> (String, Vec<u8>) {
        let mut head = String::new();
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).expect("read head") == 0 {
                break;
            }
            if line == "\r\n" {
                break;
            }
            head.push_str(&line);
        }
        let len: usize = head
            .lines()
            .find_map(|l| l.strip_prefix("Content-Length: "))
            .and_then(|v| v.trim().parse().ok())
            .unwrap_or(0);
        let mut body = vec![0u8; if head_only { 0 } else { len }];
        if !body.is_empty() {
            reader.read_exact(&mut body).expect("read body");
        }
        (head, body)
    }

    #[test]
    fn at_rest_server_range_semantics() {
        let _g = crate::node::resolver::test_lock();
        let dir = tempfile::tempdir().expect("tempdir");
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", dir.path()) };
        at_rest::reset_for_test();
        let db = dir.path().join("messages.db").to_string_lossy().to_string();
        at_rest::init(&db, &"5c".repeat(32)).expect("ring");

        let data: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
        let media = dir.path().join("files").join("clip.mp4");
        at_rest::write_all(&media, &data).expect("write");

        let url = media_url(&media).expect("url");
        let rest = url.strip_prefix("http://127.0.0.1:").expect("loopback only");
        let (port_s, path) = rest.split_once('/').expect("path");
        let port: u16 = port_s.parse().expect("port");
        let token = path.split('/').next().expect("token").to_string();

        let (head, body) = http(port, &format!("GET /{path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"));
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
        assert!(head.contains("Content-Type: video/mp4"), "{head}");
        assert!(head.contains("Accept-Ranges: bytes"), "{head}");
        assert_eq!(body, data, "a plain GET returns the decrypted file");

        let (head, body) = http(port, &format!("HEAD /{path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"));
        assert!(head.contains("Content-Length: 300000"), "{head}");
        assert!(body.is_empty(), "HEAD carries no body");

        let (head, body) = http(
            port,
            &format!("GET /{path} HTTP/1.1\r\nHost: x\r\nRange: bytes=100-199\r\nConnection: close\r\n\r\n"),
        );
        assert!(head.starts_with("HTTP/1.1 206"), "{head}");
        assert!(head.contains("Content-Range: bytes 100-199/300000"), "{head}");
        assert_eq!(body, data[100..200]);

        let (head, body) = http(
            port,
            &format!("GET /{path} HTTP/1.1\r\nHost: x\r\nRange: bytes=-50\r\nConnection: close\r\n\r\n"),
        );
        assert!(head.starts_with("HTTP/1.1 206"), "{head}");
        assert_eq!(body, &data[data.len() - 50..]);

        let (head, _) = http(
            port,
            &format!("GET /{path} HTTP/1.1\r\nHost: x\r\nRange: bytes=0-10,20-30\r\nConnection: close\r\n\r\n"),
        );
        assert!(head.starts_with("HTTP/1.1 416"), "multiple ranges are refused: {head}");

        let (head, _) = http(
            port,
            &format!("GET /{token}/..%2F..%2Fsecret.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"),
        );
        assert!(head.starts_with("HTTP/1.1 404"), "traversal must 404: {head}");

        let (head, _) = http(
            port,
            &format!("GET /{}/files/clip.mp4 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", "0".repeat(64)),
        );
        assert!(head.starts_with("HTTP/1.1 404"), "a wrong token must 404: {head}");

        let sock = std::net::TcpStream::connect(("127.0.0.1", port)).expect("connect");
        let mut reader = BufReader::new(sock);
        reader
            .get_mut()
            .write_all(format!("HEAD /{path} HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes())
            .expect("send");
        let (h1, _) = read_one(&mut reader, true);
        reader
            .get_mut()
            .write_all(format!("HEAD /{path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").as_bytes())
            .expect("send second");
        let (h2, _) = read_one(&mut reader, true);
        assert!(h1.starts_with("HTTP/1.1 200") && h2.starts_with("HTTP/1.1 200"), "{h1}{h2}");

        // A body that fails mid-stream must close the connection: the client is
        // already counting bytes against a Content-Length it can never reach, and a
        // kept-alive socket would read its next request head out of the shortfall.
        let mut raw = std::fs::read(&media).expect("raw");
        let len = raw.len();
        raw[len - 1] ^= 0x55;
        std::fs::write(&media, &raw).expect("tamper");

        let sock = std::net::TcpStream::connect(("127.0.0.1", port)).expect("connect");
        let mut reader = BufReader::new(sock);
        reader
            .get_mut()
            .write_all(format!("GET /{path} HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes())
            .expect("send");
        let mut head = String::new();
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).expect("read head") == 0 || line == "\r\n" {
                break;
            }
            head.push_str(&line);
        }
        assert!(head.contains("Content-Length: 300000"), "{head}");
        let mut body = Vec::new();
        reader.read_to_end(&mut body).expect("read what arrives");
        assert!(
            body.len() < 300_000,
            "the server must cut the connection short, got a full body of {} bytes",
            body.len(),
        );
    }
}
