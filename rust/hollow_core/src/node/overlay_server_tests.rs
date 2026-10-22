use super::*;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream as StdStream;
use std::time::Instant;

fn serial() -> MutexGuard<'static, ()> {
    test_serial()
}

#[derive(Default)]
struct MemBackend {
    link: Mutex<Option<SavedLink>>,
    stills: HashMap<String, Vec<u8>>,
    anims: HashMap<String, String>,
    blobs: HashMap<String, Vec<u8>>,
    /// Rail kinds; a blob in `blobs` without one is an overlay image.
    kinds: HashMap<String, String>,
    /// Masters whose field says "off".
    off: HashSet<String>,
    blocked: HashSet<String>,
    /// Images each master's look may name.
    looks: HashMap<String, HashSet<String>>,
    me: Option<String>,
}

impl Backend for MemBackend {
    fn load_link(&self) -> Option<SavedLink> {
        self.link.lock().unwrap().clone()
    }
    fn save_link(&self, link: &SavedLink) -> Result<(), String> {
        *self.link.lock().unwrap() = Some(link.clone());
        Ok(())
    }
    fn anim_avatar(&self, master: &str) -> Option<String> {
        self.anims.get(master).cloned()
    }
    fn still_avatar(&self, master: &str) -> Option<Vec<u8>> {
        self.stills.get(master).cloned()
    }
    fn blob_kind(&self, hash: &str) -> Option<String> {
        self.blobs.contains_key(hash).then(|| self.kinds.get(hash).cloned()).flatten()
    }
    fn blob(&self, hash: &str) -> Option<Vec<u8>> {
        self.kinds.contains_key(hash).then(|| self.blobs.get(hash).cloned()).flatten()
    }
    fn holds_overlay_image(&self, hash: &str) -> bool {
        self.blobs.contains_key(hash) && !self.kinds.contains_key(hash)
    }
    fn overlay_image(&self, hash: &str) -> Option<Vec<u8>> {
        self.holds_overlay_image(hash).then(|| self.blobs.get(hash).cloned()).flatten()
    }
    fn field_off(&self, master: &str) -> bool {
        self.off.contains(master)
    }
    fn blocked(&self, master: &str) -> bool {
        self.blocked.contains(master)
    }
    fn look_images(&self, master: &str) -> HashSet<String> {
        self.looks.get(master).cloned().unwrap_or_default()
    }
    fn local_master(&self) -> Option<String> {
        self.me.clone()
    }
}

fn png(seed: u8) -> Vec<u8> {
    let img = image::RgbaImage::from_fn(4, 4, |x, y| image::Rgba([seed, x as u8 * 40, y as u8 * 40, 255]));
    let mut out = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageRgba8(img).write_to(&mut out, image::ImageFormat::Png).unwrap();
    out.into_inner()
}

/// A fresh server state with `b` behind it; returns the backend for inspection.
fn fresh(b: MemBackend) -> Arc<MemBackend> {
    stop_for_wipe();
    {
        let mut st = state();
        st.locked = false;
        st.snap_gen = 0;
        st.live_gen = 0;
    }
    TEST_TIMING_MS.store(0, std::sync::atomic::Ordering::Relaxed);
    let b = Arc::new(b);
    *backend_slot().write().unwrap() = b.clone();
    b
}

fn running() -> (u16, String) {
    let st = state();
    let r = st.running.as_ref().expect("running");
    (r.port, r.token.clone())
}

fn host(port: u16) -> String {
    format!("127.0.0.1:{port}")
}

/// One request on a fresh connection; the status line and headers, then the body.
fn http(port: u16, raw: &str) -> (String, Vec<u8>) {
    let mut sock = StdStream::connect(("127.0.0.1", port)).unwrap();
    sock.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    sock.write_all(raw.as_bytes()).unwrap();
    let mut reader = BufReader::new(sock);
    read_response(&mut reader, raw.starts_with("HEAD "))
}

fn read_response(reader: &mut BufReader<StdStream>, head_only: bool) -> (String, Vec<u8>) {
    let mut head = String::new();
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
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
        reader.read_exact(&mut body).unwrap();
    }
    (head, body)
}

fn get(port: u16, path: &str) -> (String, Vec<u8>) {
    http(port, &format!("GET {path} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n", host(port)))
}

/// An open event stream: reads `event:`/`data:` pairs, skipping comments.
struct Stream {
    reader: BufReader<StdStream>,
}

impl Stream {
    fn open(port: u16, token: &str, view: &str) -> (Self, String) {
        let mut sock = StdStream::connect(("127.0.0.1", port)).unwrap();
        sock.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        sock.write_all(
            format!("GET /{token}/events?view={view} HTTP/1.1\r\nHost: {}\r\n\r\n", host(port)).as_bytes(),
        )
        .unwrap();
        let mut reader = BufReader::new(sock);
        let mut head = String::new();
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                break;
            }
            head.push_str(&line);
        }
        (Self { reader }, head)
    }

    fn line(&mut self) -> Option<String> {
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) | Err(_) => None,
            Ok(_) => Some(line.trim_end_matches('\n').to_string()),
        }
    }

    /// The next event of any type, as (type, data).
    fn next(&mut self) -> Option<(String, String)> {
        let mut kind = None;
        loop {
            let line = self.line()?;
            if let Some(k) = line.strip_prefix("event: ") {
                kind = Some(k.to_string());
            } else if let Some(d) = line.strip_prefix("data: ") {
                return Some((kind.take().unwrap_or_default(), d.to_string()));
            }
        }
    }

    /// Drains what was already sent; the server must close well inside the read timeout.
    fn ends(&mut self, why: &str) {
        let started = Instant::now();
        while self.next().is_some() {}
        assert!(started.elapsed() < Duration::from_secs(3), "{why}");
    }

    fn until(&mut self, want: &str) -> Value {
        loop {
            let (kind, data) = self.next().unwrap_or_else(|| panic!("stream ended before {want}"));
            if kind == want {
                return serde_json::from_str(&data).unwrap();
            }
        }
    }
}

const MASTER_SELF: &str = "SelfMaster1";
const MASTER_FRIEND: &str = "FriendMaster2";

fn hash_of(bytes: &[u8]) -> String {
    sha256_hex(bytes)
}

/// A backend holding: our still avatar, a friend's still avatar, two look blobs.
fn sample_backend() -> (MemBackend, String, String) {
    let idle = png(10);
    let talk = png(20);
    let (hi, ht) = (hash_of(&idle), hash_of(&talk));
    let mut b = MemBackend::default();
    b.stills.insert(MASTER_SELF.into(), png(1));
    b.stills.insert(MASTER_FRIEND.into(), png(2));
    b.blobs.insert(hi.clone(), idle);
    b.blobs.insert(ht.clone(), talk);
    (b, hi, ht)
}

fn sample_snapshot(hi: &str, ht: &str) -> String {
    json!({
        "v": 1,
        "layout": { "direction": "row", "size": 120 },
        "people": [
            { "slot": 4, "master": MASTER_FRIEND, "in_room": true, "added": true, "name": "Friend", "colour": "#112233", "look": null },
            { "slot": 0, "master": MASTER_SELF, "is_self": true, "in_room": true, "name": "Me", "colour": "#445566",
              "look": { "states": { "idle": hi, "talking": ht }, "effects": { "talking": "glow" } } },
            { "slot": 7, "master": "Outsider3", "in_room": false, "added": true, "name": "Away", "colour": "#778899" }
        ]
    })
    .to_string()
}

// ---------------------------------------------------------------------------
// Projection

#[test]
fn projection_drops_master_and_cleans_every_field() {
    let (b, hi, _) = sample_backend();
    let unknown = "ab".repeat(32);
    let long = format!("\u{202E}{}\u{0007}", "n".repeat(100));
    let snap = json!({
        "layout": { "direction": "diagonal", "align": "left", "size": 9999, "gap": -5, "names": "huge",
                    "only_talking": "yes", "self_when_inactive": "hidden",
                    "defaults": { "talking": "explode", "hold_ms": 99999 } },
        "people": [ { "slot": 0, "master": MASTER_SELF, "is_self": true, "in_room": true, "name": long, "colour": "red",
                      "look": { "states": { "idle": hi, "talking": unknown },
                                "effects": { "hold_ms": 10000, "loud_threshold": 2, "blink_every_s": 1, "talking": "explode",
                                             "shadow": "outline", "mirror": true, "transition": 3 } } } ]
    })
    .to_string();
    let (p, allow) = project(&snap, &b).unwrap();
    let out = render_snapshot(&p, &View::Room, "tok");
    assert!(!out.contains("master") && !out.contains(MASTER_SELF), "no peer id reaches a page: {out}");

    let v: Value = serde_json::from_str(&out).unwrap();
    let l = &v["layout"];
    assert_eq!((l["direction"].as_str(), l["align"].as_str(), l["names"].as_str()), (Some("row"), Some("center"), Some("pill")));
    assert_eq!((l["size"].as_u64(), l["gap"].as_u64()), (Some(512), Some(0)));
    assert_eq!(l["only_talking"], json!(false));
    assert_eq!(l["self_when_inactive"], json!("hidden"));
    assert_eq!((l["defaults"]["talking"].as_str(), l["defaults"]["hold_ms"].as_u64()), (Some("bounce"), Some(600)));

    let me = &v["people"][0];
    let name = me["name"].as_str().unwrap();
    assert_eq!(name.chars().count(), 64);
    assert!(name.chars().all(|c| c == 'n'), "control and bidi characters are dropped: {name:?}");
    assert_eq!(me["colour"], json!(DEFAULT_COLOUR));
    let still = hash_of(&png(1));
    assert_eq!(me["avatar"], json!(format!("/tok/img/{still}")));
    let states = &me["look"]["states"];
    assert_eq!(states["idle"], json!(format!("/tok/img/{hi}")));
    assert_eq!(states["talking"], json!(""), "a hash we do not hold becomes empty");
    assert_eq!(states["muted"], json!(""));
    let fx = &me["look"]["effects"];
    assert_eq!(fx["hold_ms"], json!(600));
    assert_eq!(fx["loud_threshold"], json!(0.95));
    assert_eq!(fx["blink_every_s"], json!(2.0));
    assert_eq!(fx["talking"], json!("bounce"));
    assert_eq!(fx["transition"], json!("crossfade"));
    assert_eq!((fx["shadow"].as_str(), fx["mirror"].as_bool()), (Some("outline"), Some(true)));

    let mut want: Vec<&String> = vec![&still, &hi];
    want.sort();
    let mut got: Vec<&String> = allow.keys().collect();
    got.sort();
    assert_eq!(got, want, "the allowlist is exactly what the projection names");
}

#[test]
fn names_lose_control_and_bidi_characters() {
    assert_eq!(clean_name(Some(&json!("a\u{0007}b\u{202E}c\u{2066}d\n"))), "abcd");
}

#[test]
fn room_view_leaves_out_a_self_who_is_not_in_the_room() {
    let snap = json!({ "people": [
        { "slot": 0, "is_self": true, "in_room": false, "name": "me" },
        { "slot": 5, "master": "Them5", "in_room": true, "name": "them" }
    ] })
    .to_string();
    let (p, _) = project(&snap, &MemBackend::default()).unwrap();
    let room: Vec<u32> = view_people(&p, &View::Room).iter().map(|x| x.slot).collect();
    assert_eq!(room, vec![5]);
    assert_eq!(view_people(&p, &View::Me).len(), 1, "the just me view still has us");
}

#[test]
fn colour_must_be_rrggbb() {
    for (given, want) in [
        (json!("#ABCDEF"), "#abcdef"),
        (json!("#abc"), DEFAULT_COLOUR),
        (json!("#12345g"), DEFAULT_COLOUR),
        (json!("#1234567"), DEFAULT_COLOUR),
        (json!("rgb(1,2,3)"), DEFAULT_COLOUR),
        (json!("#12345;}"), DEFAULT_COLOUR),
        (json!(7), DEFAULT_COLOUR),
    ] {
        assert_eq!(clean_colour(Some(&given)), want, "{given}");
    }
}

#[test]
fn animated_avatar_wins_only_when_held() {
    let anim_bytes = png(99);
    let anim = hash_of(&anim_bytes);
    let mut b = MemBackend::default();
    b.stills.insert(MASTER_SELF.into(), png(1));
    b.anims.insert(MASTER_SELF.into(), anim.clone());
    let snap = json!({ "people": [ { "slot": 0, "master": MASTER_SELF, "is_self": true, "in_room": true } ] }).to_string();
    let (p, _) = project(&snap, &b).unwrap();
    assert_eq!(p.people[0].avatar, hash_of(&png(1)), "an animation we do not hold falls back to the still");
    b.blobs.insert(anim.clone(), anim_bytes);
    b.kinds.insert(anim.clone(), "emote".into());
    let (p, _) = project(&snap, &b).unwrap();
    assert_eq!(p.people[0].avatar, hash_of(&png(1)), "an avatar animation must be a profile blob");
    b.kinds.insert(anim.clone(), "profile".into());
    let (p, allow) = project(&snap, &b).unwrap();
    assert_eq!(p.people[0].avatar, anim);
    assert_eq!(allow.get(&anim), Some(&ImgSource::Blob("profile")));
}

#[test]
fn an_image_is_served_only_while_its_bytes_match_the_name() {
    let mut b = MemBackend::default();
    let (still, blob, text) = (png(1), png(2), b"not an image at all".to_vec());
    b.stills.insert(MASTER_SELF.into(), still.clone());
    b.blobs.insert(hash_of(&blob), blob.clone());
    b.blobs.insert(hash_of(&text), text.clone());
    b.blobs.insert(hash_of(&still), blob.clone());
    let still_src = ImgSource::Still(MASTER_SELF.into());
    assert_eq!(load_image(&b, &hash_of(&still), &still_src).map(|x| x.1), Some("image/png"));
    assert!(load_image(&b, &hash_of(&blob), &still_src).is_none(), "the avatar changed since the projection");
    assert!(load_image(&b, &hash_of(&blob), &ImgSource::Overlay).is_some());
    assert!(load_image(&b, &hash_of(&blob), &ImgSource::Blob("profile")).is_none(), "the kind is checked again on serve");
    assert!(load_image(&b, &hash_of(&still), &ImgSource::Overlay).is_none(), "a blob that does not hash to its name");
    assert!(load_image(&b, &hash_of(&text), &ImgSource::Overlay).is_none(), "only images we draw");
}

#[test]
fn views_pick_their_people_and_self_comes_first() {
    let (b, hi, ht) = sample_backend();
    let (p, _) = project(&sample_snapshot(&hi, &ht), &b).unwrap();
    let slots = |v: &View| view_people(&p, v).iter().map(|x| x.slot).collect::<Vec<_>>();
    assert_eq!(slots(&View::Room), vec![0, 4], "room = people in the room, self first");
    assert_eq!(slots(&View::Me), vec![0]);
    assert_eq!(slots(&View::Person(7)), vec![7]);
    assert!(slots(&View::Person(9)).is_empty());
}

#[test]
fn duplicate_slots_and_a_second_self_are_dropped() {
    let snap = json!({ "people": [
        { "slot": 1, "is_self": true, "in_room": true, "name": "a" },
        { "slot": 1, "master": "B1", "in_room": true, "name": "b" },
        { "slot": 2, "master": "C2", "is_self": true, "in_room": true, "name": "c" },
        { "slot": 2000000, "in_room": true, "name": "d" },
        { "slot": -1, "in_room": true, "name": "e" }
    ] })
    .to_string();
    let (p, _) = project(&snap, &MemBackend::default()).unwrap();
    let got: Vec<(u32, bool, &str)> = p.people.iter().map(|x| (x.slot, x.is_self, x.name.as_str())).collect();
    assert_eq!(got, vec![(1, true, "a"), (2, false, "c")]);
}

#[test]
fn bad_bodies_are_refused_whole() {
    assert!(project("not json", &MemBackend::default()).is_err());
    let huge = format!("{{\"people\":[],\"pad\":\"{}\"}}", "x".repeat(MAX_SNAPSHOT_BYTES));
    assert!(project(&huge, &MemBackend::default()).is_err());
    assert!(parse_live("[").is_err());
    assert!(parse_live(&"x".repeat(MAX_LIVE_BYTES + 1)).is_err());
}

#[test]
fn live_is_clamped_and_filtered_per_view() {
    let (b, hi, ht) = sample_backend();
    let (p, _) = project(&sample_snapshot(&hi, &ht), &b).unwrap();
    let live = parse_live(
        &json!({ "self_active": false, "people": [
            { "slot": 0, "state": "talking", "level": 3.5 },
            { "slot": 4, "state": "screaming", "level": -2 },
            { "slot": 7, "state": "muted", "level": 0.123456 },
            { "slot": 0, "state": "idle", "level": 0.1 }
        ] })
        .to_string(),
    )
    .unwrap();
    let room: Value = serde_json::from_str(&render_live(&live, Some(&p), &View::Room)).unwrap();
    assert_eq!(room["self_active"], json!(false));
    assert_eq!(
        room["people"],
        json!([ { "slot": 0, "state": "talking", "level": 1.0 }, { "slot": 4, "state": "idle", "level": 0.0 } ])
    );
    let away: Value = serde_json::from_str(&render_live(&live, Some(&p), &View::Person(7))).unwrap();
    assert_eq!(away["people"], json!([ { "slot": 7, "state": "muted", "level": 0.123 } ]));
}

// ---------------------------------------------------------------------------
// Request gates

fn req(target: &str, hosts: &[&str], origins: &[&str], method_ok: bool) -> Request {
    Request {
        method_ok,
        head_only: false,
        target: target.into(),
        hosts: hosts.iter().map(|s| s.to_string()).collect(),
        origins: origins.iter().map(|s| s.to_string()).collect(),
        close: true,
    }
}

#[test]
fn host_check_stops_dns_rebinding() {
    let port = 23456;
    for ok in ["127.0.0.1:23456", "localhost:23456", "LocalHost:23456"] {
        assert!(host_ok(&[ok.into()], port), "{ok}");
    }
    for bad in [
        "evil.example:23456",
        "127.0.0.1",
        "127.0.0.1:23457",
        "127.0.0.1:23456.evil",
        "127.0.0.2:23456",
        "[::1]:23456",
        "localhost.evil:23456",
        "",
    ] {
        assert!(!host_ok(&[bad.into()], port), "{bad}");
    }
    assert!(!host_ok(&[], port), "no Host");
    assert!(!host_ok(&["127.0.0.1:23456".into(), "evil:23456".into()], port), "two Hosts");
}

#[test]
fn origin_check_refuses_foreign_pages() {
    let h = "127.0.0.1:23456";
    assert!(origin_ok(&[], h));
    assert!(origin_ok(&["http://127.0.0.1:23456".into()], h));
    for bad in ["https://evil.example", "null", "http://localhost:23456", "https://127.0.0.1:23456", "http://127.0.0.1:23457", ""] {
        assert!(!origin_ok(&[bad.into()], h), "{bad}");
    }
    assert!(!origin_ok(&["http://127.0.0.1:23456".into(), "http://127.0.0.1:23456".into()], h));
}

#[test]
fn token_and_routes() {
    let t = "ab".repeat(32);
    let other = format!("{}c", &t[..63]);
    let h = "ab".repeat(32);
    assert_eq!(route_target(&format!("/{t}/room"), &t), Some(Route::Page));
    assert_eq!(route_target(&format!("/{t}/me?x=1"), &t), Some(Route::Page));
    assert_eq!(route_target(&format!("/{t}/p/12"), &t), Some(Route::Page));
    assert_eq!(route_target(&format!("/{t}/overlay.js"), &t), Some(Route::Js));
    assert_eq!(route_target(&format!("/{t}/overlay.css"), &t), Some(Route::Css));
    assert_eq!(route_target(&format!("/{t}/events?view=room"), &t), Some(Route::Events(View::Room)));
    assert_eq!(route_target(&format!("/{t}/events?view=p%2F3"), &t), Some(Route::Events(View::Person(3))));
    assert_eq!(route_target(&format!("/{t}/img/{h}"), &t), Some(Route::Img(h.clone())));
    for bad in [
        format!("/{other}/room"),
        format!("/{}/room", &t[..63]),
        format!("/{t}x/room"),
        "/room".to_string(),
        format!("/{t}"),
        format!("/{t}/"),
        format!("/{t}/p/abc"),
        format!("/{t}/p/99999999"),
        format!("/{t}/img/{}", h.to_uppercase()),
        format!("/{t}/img/../room"),
        format!("/{t}/events"),
        format!("/{t}/events?view=all"),
        format!("http://127.0.0.1/{t}/room"),
    ] {
        assert_eq!(route_target(&bad, &t), None, "{bad}");
    }
    assert!(gate(&req(&format!("/{t}/room"), &["127.0.0.1:1"], &[], true), 1, &t).is_some());
    assert!(gate(&req(&format!("/{t}/room"), &["127.0.0.1:1"], &[], false), 1, &t).is_none(), "method gate");
}

#[test]
fn link_file_round_trips_and_refuses_junk() {
    let dir = crate::test_tmp::tempdir().unwrap();
    let link = SavedLink { port: 23456, token: "cd".repeat(32), enabled: true };
    write_link(dir.path(), &link).unwrap();
    assert_eq!(read_link(dir.path()), Some(link));
    std::fs::write(dir.path().join(LINK_FILE), r#"{"port":80,"token":"x","enabled":true}"#).unwrap();
    assert_eq!(read_link(dir.path()), None);
    std::fs::write(dir.path().join(LINK_FILE), format!(r#"{{"port":80,"token":"{}"}}"#, "cd".repeat(32))).unwrap();
    assert_eq!(read_link(dir.path()), None, "a port outside the quiet range");
}

#[test]
fn page_files_carry_no_inline_script_and_no_html_sinks() {
    let html = page_html(&"ab".repeat(32));
    assert!(!html.contains("__TOKEN__"));
    assert_eq!(html.matches("<script").count(), html.matches("<script src=").count());
    for sink in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function"] {
        assert!(!PAGE_JS.contains(sink), "overlay.js must not use {sink}");
    }
    let js = PAGE_JS.replace("'http://www.w3.org/2000/svg'", "");
    assert!(!js.contains("http:") && !js.contains("https:"), "the page loads nothing external");
    assert!(!PAGE_CSS.contains("url(") && !PAGE_CSS.contains("@import"));
}

// ---------------------------------------------------------------------------
// Real sockets

#[test]
fn server_end_to_end_over_raw_http() {
    let _s = serial();
    let (b, hi, ht) = sample_backend();
    let mut b = b;
    let stray = png(33);
    let stray_hash = hash_of(&stray);
    b.blobs.insert(stray_hash.clone(), stray);
    fresh(b);
    set_enabled(true).unwrap();
    let (port, t) = running();
    publish(&sample_snapshot(&hi, &ht)).unwrap();

    let (head, body) = get(port, &format!("/{t}/room"));
    assert!(head.starts_with("HTTP/1.1 200"), "{head}");
    for h in [
        "Content-Type: text/html",
        "Cache-Control: no-store",
        "X-Content-Type-Options: nosniff",
        "Referrer-Policy: no-referrer",
        "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; connect-src 'self'",
    ] {
        assert!(head.contains(h), "missing {h}: {head}");
    }
    assert!(!head.to_ascii_lowercase().contains("access-control"), "no CORS, ever");
    assert!(String::from_utf8(body).unwrap().contains(&format!("/{t}/overlay.js")));

    let (head, body) = http(port, &format!("HEAD /{t}/overlay.js HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n", host(port)));
    assert!(head.starts_with("HTTP/1.1 200") && head.contains("text/javascript") && body.is_empty(), "{head}");

    let refused = [
        format!("GET /{t}/room HTTP/1.1\r\nHost: evil.example:{port}\r\nConnection: close\r\n\r\n"),
        format!("GET /{t}/room HTTP/1.1\r\nConnection: close\r\n\r\n"),
        format!("GET /{t}/room HTTP/1.1\r\nHost: {}\r\nOrigin: https://evil.example\r\nConnection: close\r\n\r\n", host(port)),
        format!("GET /{}/room HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n", "0".repeat(64), host(port)),
        format!("POST /{t}/room HTTP/1.1\r\nHost: {}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", host(port)),
        format!("OPTIONS /{t}/room HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n", host(port)),
    ];
    for raw in &refused {
        let (head, body) = http(port, raw);
        assert!(head.starts_with("HTTP/1.1 404") && body.is_empty(), "{raw}\n{head}");
    }
    let (head, _) = http(
        port,
        &format!("GET /{t}/me HTTP/1.1\r\nHost: localhost:{port}\r\nOrigin: http://localhost:{port}\r\nConnection: close\r\n\r\n"),
    );
    assert!(head.starts_with("HTTP/1.1 200"), "our own origin passes: {head}");

    // Images: only what the projection names, never another blob we hold.
    let (head, body) = get(port, &format!("/{t}/img/{hi}"));
    assert!(head.starts_with("HTTP/1.1 200") && head.contains("Content-Type: image/png"), "{head}");
    assert_eq!(hash_of(&body), hi);
    let still = hash_of(&png(2));
    assert!(get(port, &format!("/{t}/img/{still}")).0.starts_with("HTTP/1.1 200"), "the friend's still avatar");
    assert!(get(port, &format!("/{t}/img/{stray_hash}")).0.starts_with("HTTP/1.1 404"), "held but not named");

    // The stream: snapshot, then live; lock blanks it, unlock resends.
    let (mut s, head) = Stream::open(port, &t, "room");
    assert!(head.starts_with("HTTP/1.1 200") && head.contains("text/event-stream"), "{head}");
    let snap = s.until("snapshot");
    let slots: Vec<u64> = snap["people"].as_array().unwrap().iter().map(|p| p["slot"].as_u64().unwrap()).collect();
    assert_eq!(slots, vec![0, 4]);
    assert_eq!(snap["people"][0]["look"]["states"]["talking"], json!(format!("/{t}/img/{ht}")));
    publish_live(&json!({ "people": [ { "slot": 4, "state": "talking", "level": 0.5 } ] }).to_string()).unwrap();
    let live = s.until("live");
    assert_eq!(live["people"][0]["state"], json!("talking"));

    set_locked(true);
    s.until("locked");
    assert!(get(port, &format!("/{t}/img/{hi}")).0.starts_with("HTTP/1.1 404"), "nothing is served while locked");
    publish_live(&json!({ "people": [ { "slot": 4, "state": "muted" } ] }).to_string()).unwrap();
    set_locked(false);
    let (kind, _) = s.next().unwrap();
    assert_eq!(kind, "snapshot", "unlock resends the snapshot first");
    assert_eq!(s.until("live")["people"][0]["state"], json!("muted"));

    // A new projection that drops the friend drops their avatar from the allowlist.
    publish(&json!({ "people": [ { "slot": 0, "master": MASTER_SELF, "is_self": true, "in_room": true } ] }).to_string()).unwrap();
    s.until("snapshot");
    assert!(get(port, &format!("/{t}/img/{still}")).0.starts_with("HTTP/1.1 404"));
    assert!(get(port, &format!("/{t}/img/{hi}")).0.starts_with("HTTP/1.1 404"));

    set_enabled(false).unwrap();
    s.ends("stopping ends every stream");
}

#[test]
fn oversized_head_is_cut_without_an_answer() {
    let _s = serial();
    fresh(MemBackend::default());
    set_enabled(true).unwrap();
    let (port, t) = running();
    for terminated in [false, true] {
        let mut sock = StdStream::connect(("127.0.0.1", port)).unwrap();
        sock.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut raw = format!("GET /{t}/room HTTP/1.1\r\nHost: {}\r\nX-Pad: {}", host(port), "a".repeat(9000));
        if terminated {
            raw.push_str("\r\n\r\n");
        }
        let _ = sock.write_all(raw.as_bytes());
        let mut got = Vec::new();
        let _ = sock.read_to_end(&mut got);
        assert!(got.is_empty(), "no response to a head over 8 KiB (terminated: {terminated})");
    }
    set_enabled(false).unwrap();
}

#[test]
fn connection_cap_holds_the_seventeenth_back() {
    let _s = serial();
    fresh(MemBackend::default());
    set_enabled(true).unwrap();
    let (port, t) = running();
    let held: Vec<StdStream> = (0..MAX_CONNECTIONS).map(|_| StdStream::connect(("127.0.0.1", port)).unwrap()).collect();
    std::thread::sleep(Duration::from_millis(200));
    let mut extra = StdStream::connect(("127.0.0.1", port)).unwrap();
    extra
        .write_all(format!("GET /{t}/me HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n", host(port)).as_bytes())
        .unwrap();
    std::thread::sleep(Duration::from_millis(600));
    // A read timeout leaves a Windows socket unusable, so look without blocking.
    extra.set_nonblocking(true).unwrap();
    let mut buf = [0u8; 16];
    let waiting = matches!(extra.read(&mut buf), Err(e) if e.kind() == std::io::ErrorKind::WouldBlock);
    extra.set_nonblocking(false).unwrap();
    assert!(waiting, "the 17th connection waits");
    drop(held);
    extra.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut reader = BufReader::new(extra);
    assert!(read_response(&mut reader, false).0.starts_with("HTTP/1.1 200"), "served once a slot frees");
    set_enabled(false).unwrap();
}

#[test]
fn stream_cap_answers_the_ninth_with_503() {
    let _s = serial();
    fresh(MemBackend::default());
    set_enabled(true).unwrap();
    let (port, t) = running();
    let mut open = Vec::new();
    for _ in 0..MAX_STREAMS {
        let (mut s, head) = Stream::open(port, &t, "me");
        assert!(head.starts_with("HTTP/1.1 200"), "{head}");
        s.until("snapshot");
        open.push(s);
    }
    assert_eq!(status().open_streams, MAX_STREAMS);
    let (_, head) = Stream::open(port, &t, "me");
    assert!(head.starts_with("HTTP/1.1 503"), "{head}");
    drop(open.pop());
    let deadline = Instant::now() + Duration::from_secs(5);
    while status().open_streams != MAX_STREAMS - 1 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(status().open_streams, MAX_STREAMS - 1, "a page that leaves frees its slot");
    set_enabled(false).unwrap();
}

#[test]
fn streams_heartbeat_and_idle_sockets_drop() {
    let _s = serial();
    fresh(MemBackend::default());
    TEST_TIMING_MS.store(150, std::sync::atomic::Ordering::Relaxed);
    set_enabled(true).unwrap();
    let (port, t) = running();
    let (mut s, _) = Stream::open(port, &t, "me");
    s.until("snapshot");
    let started = Instant::now();
    loop {
        let line = s.line().expect("stream open");
        if line == ": hb" {
            break;
        }
        assert!(started.elapsed() < Duration::from_secs(3), "no heartbeat");
    }
    // A connection that never sends a head is dropped after the idle timeout; the
    // stream above stays open past it.
    let mut idle = StdStream::connect(("127.0.0.1", port)).unwrap();
    idle.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
    let mut buf = [0u8; 8];
    assert_eq!(idle.read(&mut buf).unwrap_or(0), 0, "idle socket closed");
    let mut beats = 0;
    while beats < 2 {
        if s.line().expect("the stream outlives the idle timeout") == ": hb" {
            beats += 1;
        }
    }
    TEST_TIMING_MS.store(0, std::sync::atomic::Ordering::Relaxed);
    set_enabled(false).unwrap();
}

#[test]
fn a_silent_new_socket_is_cut_before_a_kept_alive_one() {
    let _s = serial();
    fresh(MemBackend::default());
    TEST_TIMING_MS.store(200, std::sync::atomic::Ordering::Relaxed);
    set_enabled(true).unwrap();
    let (port, t) = running();
    let mut kept = StdStream::connect(("127.0.0.1", port)).unwrap();
    kept.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    kept.write_all(format!("GET /{t}/me HTTP/1.1\r\nHost: {}\r\n\r\n", host(port)).as_bytes()).unwrap();
    let mut reader = BufReader::new(kept.try_clone().unwrap());
    assert!(read_response(&mut reader, false).0.starts_with("HTTP/1.1 200"));
    let mut silent = StdStream::connect(("127.0.0.1", port)).unwrap();
    silent.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    std::thread::sleep(Duration::from_millis(400));
    let mut buf = [0u8; 8];
    assert_eq!(silent.read(&mut buf).unwrap_or(0), 0, "a socket that never names itself is cut at the first-head deadline");
    kept.set_nonblocking(true).unwrap();
    let open = matches!(kept.read(&mut buf), Err(e) if e.kind() == std::io::ErrorKind::WouldBlock);
    TEST_TIMING_MS.store(0, std::sync::atomic::Ordering::Relaxed);
    set_enabled(false).unwrap();
    assert!(open, "a kept-alive socket waits the full idle period");
}

#[test]
fn busy_port_moves_saves_and_tells_dart() {
    let _s = serial();
    let squatter = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let busy = loop {
        let p = random_port().unwrap();
        if std::net::TcpListener::bind(("127.0.0.1", p)).is_ok() {
            drop(squatter);
            break std::net::TcpListener::bind(("127.0.0.1", p)).unwrap();
        }
    };
    let busy_port = busy.local_addr().unwrap().port();
    let b = MemBackend::default();
    *b.link.lock().unwrap() = Some(SavedLink { port: busy_port, token: "ef".repeat(32), enabled: true });
    let b = fresh(b);
    let (tx, mut rx) = mpsc::channel::<NetworkEvent>(16);
    set_event_sink(tx.downgrade());

    let st = set_enabled(true).unwrap();
    assert!(st.running && st.port_changed && st.port != busy_port && port_in_range(st.port), "{st:?}");
    let saved = b.load_link().unwrap();
    assert_eq!(saved.port, st.port, "the new port is saved");
    assert!(valid_token(&saved.token) && saved.token != "ef".repeat(32), "a moved port gets a new token");
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut seen = None;
    while seen.is_none() && Instant::now() < deadline {
        match rx.try_recv() {
            Ok(NetworkEvent::OverlayPortChanged { port }) => seen = Some(port),
            Ok(_) => {}
            Err(_) => std::thread::sleep(Duration::from_millis(20)),
        }
    }
    assert_eq!(seen, Some(st.port), "OverlayPortChanged");

    // Turning it off and on again keeps the new port quietly.
    set_enabled(false).unwrap();
    let again = set_enabled(true).unwrap();
    assert_eq!((again.port, again.port_changed), (st.port, false));
    set_enabled(false).unwrap();
    assert!(!b.load_link().unwrap().enabled, "the choice is saved");
    drop(busy);
}

#[test]
fn first_start_mints_a_link_in_the_quiet_range() {
    let _s = serial();
    let b = fresh(MemBackend::default());
    let st = set_enabled(true).unwrap();
    assert!(st.running && !st.port_changed && port_in_range(st.port));
    let saved = b.load_link().unwrap();
    assert!(valid_token(&saved.token) && saved.enabled && saved.port == st.port);
    let l = links().unwrap();
    assert_eq!(l.room, format!("http://127.0.0.1:{}/{}/room", st.port, saved.token));
    assert_eq!(l.person_base, format!("http://127.0.0.1:{}/{}/p/", st.port, saved.token));
    set_enabled(false).unwrap();
}

#[test]
fn reset_link_kills_the_old_token_and_its_streams() {
    let _s = serial();
    fresh(MemBackend::default());
    set_enabled(true).unwrap();
    let (port, old) = running();
    let (mut s, _) = Stream::open(port, &old, "me");
    s.until("snapshot");
    let links = reset_link().unwrap();
    let (_, new) = running();
    assert_ne!(old, new);
    assert!(links.me.contains(&new));
    s.ends("the old page's stream ends");
    assert!(get(port, &format!("/{old}/me")).0.starts_with("HTTP/1.1 404"));
    assert!(get(port, &format!("/{new}/me")).0.starts_with("HTTP/1.1 200"));
    set_enabled(false).unwrap();
}

#[test]
fn the_wipe_stops_the_server_and_forgets_the_snapshot() {
    let _s = serial();
    let _g = crate::node::resolver::test_lock();
    let (b, hi, ht) = sample_backend();
    fresh(b);
    set_enabled(true).unwrap();
    let (port, t) = running();
    publish(&sample_snapshot(&hi, &ht)).unwrap();
    let (mut s, _) = Stream::open(port, &t, "room");
    s.until("snapshot");

    let dir = crate::test_tmp::tempdir().unwrap();
    crate::api::wipe::destroy_data_root(dir.path()).unwrap();
    assert!(!status().running);
    assert!(state().snap.is_none() && state().allow.is_empty());
    s.ends("the wipe ends every stream");
    assert!(StdStream::connect(("127.0.0.1", port)).is_err(), "the port is closed");
}

// ---------------------------------------------------------------------------
// Dev helper: screenshots of the page in headless Edge (Chromium, like OBS's CEF).
// Runs only with HOLLOW_OVERLAY_SHOTS=<folder>; never part of a suite.

mod shots {
    use super::*;
    use image::{Rgba, RgbaImage};

    #[derive(Clone, Copy)]
    enum Mouth {
        Closed,
        Open,
        Wide,
        Cross,
    }

    fn fill_ellipse(img: &mut RgbaImage, cx: f32, cy: f32, rx: f32, ry: f32, c: [u8; 4]) {
        for (x, y, p) in img.enumerate_pixels_mut() {
            let (dx, dy) = ((x as f32 - cx) / rx, (y as f32 - cy) / ry);
            if dx * dx + dy * dy <= 1.0 {
                *p = Rgba(c);
            }
        }
    }

    fn fill_rect(img: &mut RgbaImage, x0: u32, y0: u32, w: u32, h: u32, c: [u8; 4]) {
        for y in y0..(y0 + h).min(img.height()) {
            for x in x0..(x0 + w).min(img.width()) {
                img.put_pixel(x, y, Rgba(c));
            }
        }
    }

    /// A tall PNGtuber-style character on a transparent background.
    fn character(tint: [u8; 3], mouth: Mouth, eyes_open: bool, phones: bool) -> Vec<u8> {
        let mut img = RgbaImage::new(240, 300);
        let dark = [tint[0] / 3, tint[1] / 3, tint[2] / 3, 255];
        fill_ellipse(&mut img, 120.0, 250.0, 90.0, 60.0, dark);
        fill_ellipse(&mut img, 120.0, 130.0, 100.0, 108.0, dark);
        fill_ellipse(&mut img, 120.0, 130.0, 94.0, 102.0, [tint[0], tint[1], tint[2], 255]);
        for ex in [85.0f32, 155.0] {
            if eyes_open {
                fill_ellipse(&mut img, ex, 115.0, 17.0, 19.0, [255, 255, 255, 255]);
                fill_ellipse(&mut img, ex, 118.0, 8.0, 9.0, [20, 20, 30, 255]);
            } else {
                fill_rect(&mut img, ex as u32 - 16, 114, 32, 5, [20, 20, 30, 255]);
            }
        }
        match mouth {
            Mouth::Closed => fill_rect(&mut img, 100, 175, 40, 6, [60, 20, 30, 255]),
            Mouth::Open => fill_ellipse(&mut img, 120.0, 180.0, 22.0, 16.0, [120, 20, 40, 255]),
            Mouth::Wide => {
                fill_ellipse(&mut img, 120.0, 182.0, 36.0, 28.0, [120, 20, 40, 255]);
                fill_ellipse(&mut img, 62.0, 160.0, 14.0, 9.0, [240, 110, 120, 255]);
                fill_ellipse(&mut img, 178.0, 160.0, 14.0, 9.0, [240, 110, 120, 255]);
            }
            Mouth::Cross => {
                for i in 0..30u32 {
                    fill_rect(&mut img, 105 + i, 165 + i / 2, 4, 4, [60, 20, 30, 255]);
                    fill_rect(&mut img, 105 + i, 180 - i / 2, 4, 4, [60, 20, 30, 255]);
                }
            }
        }
        if phones {
            fill_rect(&mut img, 10, 100, 26, 70, [40, 40, 48, 255]);
            fill_rect(&mut img, 204, 100, 26, 70, [40, 40, 48, 255]);
            fill_rect(&mut img, 30, 22, 180, 12, [40, 40, 48, 255]);
        }
        encode(img)
    }

    /// A square "photo" avatar.
    fn photo(a: [u8; 3], b: [u8; 3]) -> Vec<u8> {
        let img = RgbaImage::from_fn(256, 256, |x, y| {
            let t = (x + y) as f32 / 510.0;
            let mix = |i: usize| (a[i] as f32 * (1.0 - t) + b[i] as f32 * t) as u8;
            let ring = (x as i32 - 128).pow(2) + (y as i32 - 110).pow(2) < 52 * 52;
            if ring { Rgba([250, 240, 230, 255]) } else { Rgba([mix(0), mix(1), mix(2), 255]) }
        });
        encode(img)
    }

    fn encode(img: RgbaImage) -> Vec<u8> {
        let mut out = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(img).write_to(&mut out, image::ImageFormat::Png).unwrap();
        out.into_inner()
    }

    struct Art {
        backend: MemBackend,
        me: Value,
        cat: Value,
    }

    fn art() -> Art {
        let tint = [120, 190, 255];
        let cat_tint = [255, 190, 110];
        let mut b = MemBackend::default();
        let mut put = |bytes: Vec<u8>| {
            let h = hash_of(&bytes);
            b.blobs.insert(h.clone(), bytes);
            h
        };
        let me = json!({
            "idle": put(character(tint, Mouth::Closed, true, false)),
            "talking": put(character(tint, Mouth::Open, true, false)),
            "muted": put(character(tint, Mouth::Cross, true, false)),
            "deafened": put(character(tint, Mouth::Closed, true, true)),
            "blink": put(character(tint, Mouth::Closed, false, false)),
            "loud": put(character(tint, Mouth::Wide, true, false)),
        });
        let cat = json!({ "idle": put(character(cat_tint, Mouth::Closed, true, false)) });
        b.stills.insert("FriendAva".into(), photo([90, 60, 200], [230, 80, 160]));
        Art { backend: b, me, cat }
    }

    fn person(slot: u32, master: &str, name: &str, colour: &str, look: Value) -> Value {
        json!({ "slot": slot, "master": master, "in_room": true, "added": slot == 1 || slot == 3, "is_self": slot == 0,
                "name": name, "colour": colour, "look": look })
    }

    fn crew(a: &Art, me_fx: Value, cat_fx: Value) -> Vec<Value> {
        vec![
            person(0, "SelfMaster", "Vitalik", "#5eb5ff", json!({ "states": a.me, "effects": me_fx })),
            person(1, "FriendAva", "Aurora", "#c084fc", Value::Null),
            person(2, "NoAvatar", "Dr Faust", "#facc15", Value::Null),
            person(3, "CatMaster", "Mochi", "#fb923c", json!({ "states": a.cat, "effects": cat_fx })),
        ]
    }

    fn snapshot(layout: Value, people: Vec<Value>) -> String {
        json!({ "v": 1, "layout": layout, "people": people }).to_string()
    }

    fn live(states: &[(u32, &str, f64)]) -> String {
        let people: Vec<Value> = states.iter().map(|(s, st, l)| json!({ "slot": s, "state": st, "level": l })).collect();
        json!({ "people": people, "self_active": true }).to_string()
    }

    fn shoot(edge: &str, out: &Path, profile: &Path, url: &str, name: &str, size: (u32, u32)) -> std::path::PathBuf {
        let raw = out.join(format!("{name}.png"));
        let _ = std::fs::remove_file(&raw);
        let mut child = std::process::Command::new(edge)
            .args([
                "--headless=new".to_string(),
                "--disable-gpu".to_string(),
                "--no-first-run".to_string(),
                "--disable-extensions".to_string(),
                "--hide-scrollbars".to_string(),
                "--default-background-color=00000000".to_string(),
                format!("--user-data-dir={}", profile.display()),
                format!("--window-size={},{}", size.0, size.1),
                "--timeout=2500".to_string(),
                format!("--screenshot={}", raw.display()),
                url.to_string(),
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("start Edge");
        let deadline = Instant::now() + Duration::from_secs(40);
        while child.try_wait().unwrap().is_none() {
            if Instant::now() > deadline {
                let _ = child.kill();
                panic!("Edge hung on {name}");
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        assert!(raw.exists(), "no screenshot for {name}");
        raw
    }

    /// Lays a shot over a busy stream stand-in: white, black, then loud colour.
    fn busy(raw: &Path) -> RgbaImage {
        let top = image::open(raw).unwrap().to_rgba8();
        let (w, h) = top.dimensions();
        let mut base = RgbaImage::from_fn(w, h, |x, y| match x * 3 / w {
            0 => if (x + y) % 24 < 3 { Rgba([210, 210, 210, 255]) } else { Rgba([250, 250, 250, 255]) },
            1 => if (x + 2 * y) % 30 < 4 { Rgba([60, 60, 70, 255]) } else { Rgba([12, 12, 16, 255]) },
            _ => {
                let t = y as f32 / h as f32;
                let stripe = (x / 12 + y / 12) % 2 == 0;
                let c = [(255.0 * t) as u8, if stripe { 220 } else { 90 }, (255.0 * (1.0 - t)) as u8];
                Rgba([c[0], c[1], c[2], 255])
            }
        });
        for (x, y, p) in top.enumerate_pixels() {
            let a = f32::from(p[3]) / 255.0;
            let b = base.get_pixel_mut(x, y);
            for i in 0..3 {
                b[i] = (f32::from(p[i]) * a + f32::from(b[i]) * (1.0 - a)) as u8;
            }
        }
        base
    }

    /// Lays a transparent shot over a checkerboard so transparency shows.
    fn checker(raw: &Path) -> RgbaImage {
        let top = image::open(raw).unwrap().to_rgba8();
        let mut base = RgbaImage::from_fn(top.width(), top.height(), |x, y| {
            if (x / 16 + y / 16) % 2 == 0 { Rgba([200, 200, 200, 255]) } else { Rgba([120, 120, 120, 255]) }
        });
        for (x, y, p) in top.enumerate_pixels() {
            let a = f32::from(p[3]) / 255.0;
            let b = base.get_pixel_mut(x, y);
            for i in 0..3 {
                b[i] = (f32::from(p[i]) * a + f32::from(b[i]) * (1.0 - a)) as u8;
            }
        }
        base
    }

    #[test]
    #[ignore]
    fn page_fixture_screenshots() {
        let Ok(out) = std::env::var("HOLLOW_OVERLAY_SHOTS") else { return };
        let out = std::path::PathBuf::from(out);
        std::fs::create_dir_all(&out).unwrap();
        let edge = std::env::var("HOLLOW_EDGE")
            .unwrap_or_else(|_| r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe".into());
        let profile = out.join("edge-profile");
        let _s = serial();
        let mut a = art();
        fresh(std::mem::take(&mut a.backend));
        set_enabled(true).unwrap();
        let (port, t) = running();
        let base = format!("http://127.0.0.1:{port}/{t}");
        let me_fx = json!({ "talking": "bounce", "idle": "none", "transition": "crossfade", "hold_ms": 250 });
        let cat_fx = json!({ "talking": "glow" });
        let crew_default = crew(&a, me_fx, cat_fx.clone());
        let row = json!({ "direction": "row", "align": "center", "size": 160, "gap": 16, "names": "pill" });
        let wide = (900, 300);
        let all = |s: &str, l: f64| live(&[(0, s, l), (1, s, l), (2, s, l), (3, s, l)]);

        type Fixture<'a> = (&'a str, String, String, &'a str, (u32, u32));
        let mut fixtures: Vec<Fixture> = vec![
            ("01_idle_row_pill", snapshot(row.clone(), crew_default.clone()), all("idle", 0.0), "room", wide),
            ("02_talking_bounce_glow", snapshot(row.clone(), crew_default.clone()), all("talking", 0.6), "room", wide),
            (
                "03_muted_deafened_fallbacks",
                snapshot(row.clone(), crew_default.clone()),
                live(&[(0, "muted", 0.0), (1, "muted", 0.0), (2, "deafened", 0.0), (3, "deafened", 0.0)]),
                "room",
                wide,
            ),
            (
                "04_loud_scale_pop_deafened_image",
                snapshot(
                    row.clone(),
                    crew(
                        &a,
                        json!({ "talking": "glow", "scale_with_voice": true, "loud_threshold": 0.7 }),
                        json!({ "talking": "pop", "scale_with_voice": true }),
                    ),
                ),
                live(&[(0, "talking", 0.95), (1, "deafened", 0.0), (2, "idle", 0.0), (3, "talking", 1.0)]),
                "room",
                wide,
            ),
            (
                "05_grid_plain_dim_grayscale_mirror_shadows",
                snapshot(
                    json!({ "direction": "grid", "align": "start", "size": 128, "gap": 24, "names": "plain",
                            "defaults": { "idle": "grayscale", "shadow": "outline" } }),
                    crew(&a, json!({ "idle": "dim", "shadow": "soft" }), json!({ "mirror": true, "shadow": "outline" })),
                ),
                all("idle", 0.0),
                "room",
                (640, 420),
            ),
            (
                "06_column_only_talking",
                snapshot(
                    json!({ "direction": "column", "align": "start", "size": 96, "gap": 8, "names": "plain", "only_talking": true }),
                    crew_default.clone(),
                ),
                live(&[(0, "talking", 0.5), (1, "idle", 0.0), (2, "talking", 0.5), (3, "muted", 0.0)]),
                "room",
                (300, 420),
            ),
            (
                "07_me_view_shake_no_names",
                snapshot(json!({ "size": 256, "names": "none" }), crew(&a, json!({ "talking": "shake" }), cat_fx)),
                live(&[(0, "talking", 0.7)]),
                "me",
                (420, 360),
            ),
            (
                "08_only_added_filter",
                snapshot(json!({ "size": 140, "names": "pill", "only_added": true }), crew_default.clone()),
                all("idle", 0.0),
                "room",
                wide,
            ),
            (
                "09_person_link_p1",
                snapshot(json!({ "size": 200, "names": "pill" }), crew_default.clone()),
                live(&[(1, "talking", 0.5)]),
                "p/1",
                (420, 320),
            ),
        ];
        let mut hostile = crew_default.clone();
        hostile[1]["name"] = json!(format!("<img src=x onerror=alert(1)>{}", "W".repeat(80)));
        fixtures.push(("10_hostile_name_is_text", snapshot(row.clone(), hostile), all("idle", 0.0), "room", wide));

        let mut shots = Vec::new();
        for (name, snap, lv, view, size) in fixtures {
            publish(&snap).unwrap();
            publish_live(&lv).unwrap();
            let raw = shoot(&edge, &out, &profile, &format!("{base}/{view}"), name, size);
            let img = checker(&raw);
            img.save(out.join(format!("{name}_checker.png"))).unwrap();
            shots.push(img);
        }
        // Plain names in light and dark colours over a busy background.
        let mut plain = crew_default.clone();
        for (i, c) in ["#5eb5ff", "#1e3a8a", "#111111", "#fef08a"].iter().enumerate() {
            plain[i]["colour"] = json!(c);
        }
        publish(&snapshot(json!({ "size": 150, "gap": 60, "names": "plain" }), plain)).unwrap();
        publish_live(&all("idle", 0.0)).unwrap();
        let raw = shoot(&edge, &out, &profile, &format!("{base}/room"), "12_plain_names_light_and_dark", (1000, 300));
        busy(&raw).save(out.join("12_plain_names_light_and_dark_busy.png")).unwrap();
        shots.push(busy(&raw));
        publish(&snapshot(row, crew_default)).unwrap();
        set_locked(true);
        let raw = shoot(&edge, &out, &profile, &format!("{base}/room"), "11_locked_blank", wide);
        let locked = image::open(&raw).unwrap().to_rgba8();
        assert!(locked.pixels().all(|p| p[3] == 0), "a locked page draws nothing");
        shots.push(checker(&raw));
        set_locked(false);
        set_enabled(false).unwrap();

        let width = shots.iter().map(RgbaImage::width).max().unwrap();
        let height: u32 = shots.iter().map(|s| s.height() + 8).sum();
        let mut sheet = RgbaImage::from_pixel(width, height, Rgba([24, 24, 28, 255]));
        let mut y = 0u32;
        for s in &shots {
            image::imageops::overlay(&mut sheet, s, 0, i64::from(y));
            y += s.height() + 8;
        }
        sheet.save(out.join("all_states_combined.png")).unwrap();
        let _ = std::fs::remove_dir_all(&profile);
    }

    /// The real page script and stylesheet on a file page whose EventSource
    /// replays a snapshot, then one state change 800 ms later, with the
    /// crossfade held at its midpoint so the shot lands inside it on any clock.
    fn fade_page(dir: &Path, name: &str, person: &Value, from: &str, to: &str, hang: u16) -> std::path::PathBuf {
        let layout = json!({
            "direction": "row", "align": "center", "size": 160, "gap": 16, "names": "none",
            "only_talking": false, "only_added": false, "self_when_inactive": "idle",
            "defaults": person["look"]["effects"]
        });
        let snap = json!({ "layout": layout, "people": [person] }).to_string();
        let live = |s: &str| json!({ "people": [{ "slot": 0, "state": s, "level": 0.5 }], "self_active": true }).to_string();
        let html = format!(
            r#"<!doctype html><html><head><meta charset="utf-8"><style>{css}
.person[data-transition="crossfade"] .frame img.layer,
.person[data-transition="crossfade"] .initials {{ transition-duration: 1000s !important; transition-delay: -500s !important; }}
</style></head><body><div id="overlay" class="overlay"></div>
<img hidden alt="" src="http://127.0.0.1:{hang}/hang">
<script>
window.EventSource = function () {{
  var on = {{}};
  this.addEventListener = function (t, f) {{ on[t] = f; }};
  setTimeout(function () {{
    on.snapshot({{ data: {snap:?} }});
    on.live({{ data: {a:?} }});
    setTimeout(function () {{ on.live({{ data: {b:?} }}); }}, 800);
  }}, 50);
}};
EventSource.CLOSED = 2;
</script><script>{js}</script></body></html>"#,
            css = PAGE_CSS,
            js = PAGE_JS,
            snap = snap,
            a = live(from),
            b = live(to),
            hang = hang,
        );
        let path = dir.join(format!("{name}.html"));
        std::fs::write(&path, html).unwrap();
        path
    }

    /// Alpha a few pixels in from the top corners of the drawn person's box.
    fn corner_alpha(raw: &Path) -> (u8, u8) {
        let img = image::open(raw).unwrap().to_rgba8();
        let lit: Vec<(u32, u32)> =
            img.enumerate_pixels().filter(|(_, _, p)| p[3] > 0).map(|(x, y, _)| (x, y)).collect();
        assert!(!lit.is_empty(), "the shot drew nothing");
        let x0 = lit.iter().map(|p| p.0).min().unwrap();
        let x1 = lit.iter().map(|p| p.0).max().unwrap();
        let y0 = lit.iter().map(|p| p.1).min().unwrap();
        (img.get_pixel(x0 + 4, y0 + 4)[3], img.get_pixel(x1 - 4, y0 + 4)[3])
    }

    /// Mid-crossfade frames: an avatar leaving or arriving keeps its circle for
    /// the whole fade, whatever the image on the other side is.
    #[test]
    #[ignore]
    fn crossfade_keeps_the_avatar_circle() {
        let Ok(out) = std::env::var("HOLLOW_OVERLAY_SHOTS") else { return };
        let out = std::path::PathBuf::from(out).join("crossfade");
        std::fs::create_dir_all(&out).unwrap();
        let edge = std::env::var("HOLLOW_EDGE")
            .unwrap_or_else(|_| r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe".into());
        let profile = out.join("edge-profile");
        std::fs::write(out.join("avatar.png"), photo([90, 60, 200], [230, 80, 160])).unwrap();
        let tint = [120, 190, 255];
        std::fs::write(out.join("talking.png"), character(tint, Mouth::Open, true, false)).unwrap();
        std::fs::write(out.join("muted.png"), character(tint, Mouth::Cross, true, false)).unwrap();
        let fx = json!({ "talking": "none", "idle": "none", "transition": "crossfade", "hold_ms": 0,
                         "blink_every_s": 12, "loud_threshold": 0.75, "mirror": false, "shadow": "none",
                         "scale_with_voice": false });
        let me = |avatar: &str| {
            json!({
                "slot": 0, "self": true, "added": false, "name": "Vitalik", "colour": "#5eb5ff", "avatar": avatar,
                "look": { "states": { "idle": "", "talking": "talking.png", "muted": "muted.png", "deafened": "",
                                      "blink": "", "loud": "" }, "effects": fx }
            })
        };
        let cases = [
            ("fade_1_avatar_to_talking", me("avatar.png"), "idle", "talking", true),
            ("fade_2_talking_to_avatar", me("avatar.png"), "talking", "idle", true),
            ("fade_3_avatar_to_muted", me("avatar.png"), "idle", "muted", true),
            ("fade_4_initials_to_talking", me(""), "idle", "talking", false),
        ];
        // An image that never loads keeps the page loading, so Edge shoots at its
        // timeout, after the state change, as it does for the served page.
        let hang = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let hang_port = hang.local_addr().unwrap().port();
        let mut shots = Vec::new();
        let mut square = Vec::new();
        for (name, person, from, to, circle) in cases {
            let page = fade_page(&out, name, &person, from, to, hang_port);
            let url = format!("file:///{}", page.display().to_string().replace('\\', "/"));
            let raw = shoot(&edge, &out, &profile, &url, name, (420, 220));
            if circle {
                let (l, r) = corner_alpha(&raw);
                if l > 16 || r > 16 {
                    square.push(format!("{name}: corner alpha {l}/{r}"));
                }
            }
            let img = checker(&raw);
            img.save(out.join(format!("{name}_checker.png"))).unwrap();
            shots.push(img);
        }
        let width = shots.iter().map(RgbaImage::width).sum::<u32>() + 8 * (shots.len() as u32 - 1);
        let height = shots.iter().map(RgbaImage::height).max().unwrap();
        let mut sheet = RgbaImage::from_pixel(width, height, Rgba([24, 24, 28, 255]));
        let mut x = 0u32;
        for s in &shots {
            image::imageops::overlay(&mut sheet, s, i64::from(x), 0);
            x += s.width() + 8;
        }
        sheet.save(out.join("crossfade_combined.png")).unwrap();
        drop(hang);
        let _ = std::fs::remove_dir_all(&profile);
        assert!(square.is_empty(), "the avatar lost its circle mid-fade: {square:?}");
    }
}

// ---------------------------------------------------------------------------
// Reviewer (wave so): each test states the property the server should hold.

/// A connection a foreign page opened (any Host but ours) must not keep a slot:
/// a page can keep sockets alive with one cheap 404 per idle period on many
/// `*.localhost` names, and OBS then waits in the backlog for good.
#[test]
fn review_foreign_host_404_does_not_keep_its_slot() {
    let _s = serial();
    fresh(MemBackend::default());
    TEST_TIMING_MS.store(300, std::sync::atomic::Ordering::Relaxed);
    set_enabled(true).unwrap();
    let (port, t) = running();
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mut squatters = Vec::new();
    for i in 0..MAX_CONNECTIONS {
        let stop = stop.clone();
        squatters.push(std::thread::spawn(move || {
            let sock = StdStream::connect(("127.0.0.1", port)).unwrap();
            sock.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut w = sock.try_clone().unwrap();
            let mut reader = BufReader::new(sock);
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                let raw = format!("GET /x HTTP/1.1\r\nHost: s{i}.localhost:{port}\r\n\r\n");
                if w.write_all(raw.as_bytes()).is_err() {
                    return;
                }
                let (head, _) = read_response(&mut reader, false);
                if head.is_empty() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(150));
            }
        }));
    }
    std::thread::sleep(Duration::from_millis(300));
    let mut obs = StdStream::connect(("127.0.0.1", port)).unwrap();
    obs.write_all(format!("GET /{t}/me HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n", host(port)).as_bytes())
        .unwrap();
    // Several idle periods: the squatters' sockets are long past any idle cut.
    std::thread::sleep(Duration::from_millis(1500));
    obs.set_nonblocking(true).unwrap();
    let mut buf = [0u8; 16];
    let starved = matches!(obs.read(&mut buf), Err(e) if e.kind() == std::io::ErrorKind::WouldBlock);
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    for s in squatters {
        let _ = s.join();
    }
    TEST_TIMING_MS.store(0, std::sync::atomic::Ordering::Relaxed);
    set_enabled(false).unwrap();
    assert!(!starved, "OBS's request is starved by sockets that never passed the Host gate");
}

/// The idle cut must bound a whole head, not each read: a trickle of one byte per
/// idle period otherwise holds a slot for 8 KiB of idle periods.
#[test]
fn review_trickled_head_is_cut_by_a_total_deadline() {
    let _s = serial();
    fresh(MemBackend::default());
    TEST_TIMING_MS.store(300, std::sync::atomic::Ordering::Relaxed);
    set_enabled(true).unwrap();
    let (port, _) = running();
    let mut sock = StdStream::connect(("127.0.0.1", port)).unwrap();
    let started = Instant::now();
    let mut alive = true;
    while started.elapsed() < Duration::from_millis(2400) {
        if sock.write_all(b"G").is_err() {
            alive = false;
            break;
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    if alive {
        sock.set_nonblocking(true).unwrap();
        let mut buf = [0u8; 4];
        alive = matches!(sock.read(&mut buf), Err(e) if e.kind() == std::io::ErrorKind::WouldBlock);
    }
    TEST_TIMING_MS.store(0, std::sync::atomic::Ordering::Relaxed);
    set_enabled(false).unwrap();
    assert!(!alive, "a head trickled for 8 idle periods still holds its connection");
}

/// A look may name only overlay images (plan section 7): any other rail blob the
/// streamer holds (a private server's emote, a sticker from a DM) must not become
/// an allowlisted image, or a person's look turns the public stream into an oracle
/// for what the streamer holds.
#[test]
fn review_a_look_names_only_overlay_kind_blobs() {
    let _s = serial();
    let _st = crate::api::storage::store_test_lock();
    let ms = crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).expect("store");
    let sticker = png(77);
    let h = hash_of(&sticker);
    ms.save_asset_blob(&h, &sticker, false, "sticker").unwrap();
    crate::api::storage::set_test_store(ms);
    let snapshot = json!({
        "layout": {},
        "people": [ { "slot": 3, "master": "Probe1", "in_room": true, "name": "x", "colour": "#112233",
                      "look": { "states": { "idle": h } } } ]
    })
    .to_string();
    let (_, allow) = project(&snapshot, &DbBackend).unwrap();
    crate::api::storage::set_test_store(crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).unwrap());
    assert!(!allow.contains_key(&h), "a sticker blob was allowlisted as a look image");
}

/// When the saved port is lost every OBS link breaks anyway, while OBS keeps sending
/// the old token to whatever now listens on the old port: the move should mint a
/// new token for free.
#[test]
fn review_a_moved_port_mints_a_new_token() {
    let _s = serial();
    let busy = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let busy = loop {
        let p = random_port().unwrap();
        if let Ok(l) = std::net::TcpListener::bind(("127.0.0.1", p)) {
            drop(busy);
            break l;
        }
    };
    let busy_port = busy.local_addr().unwrap().port();
    let b = MemBackend::default();
    *b.link.lock().unwrap() = Some(SavedLink { port: busy_port, token: "ef".repeat(32), enabled: true });
    let b = fresh(b);
    let st = set_enabled(true).unwrap();
    let token = b.load_link().unwrap().token;
    set_enabled(false).unwrap();
    drop(busy);
    assert!(st.port_changed);
    assert_ne!(token, "ef".repeat(32), "the old token survives a port move");
}

/// Rust holds no App Lock state of its own, so the server must start dark and
/// serve only after Dart says the app is unlocked, never the other way round.
#[test]
fn review_the_server_starts_locked() {
    assert!(Server::default().locked, "a server Dart never told about App Lock serves at once");
}

// ---------------------------------------------------------------------------
// so-merge: the projection behind the look manifest and the field

/// Defense in depth behind Dart: someone who turned "Let others show me" off never
/// reaches a page, nor does someone the snapshot does not name; we always do.
#[test]
fn merge_projection_drops_a_person_whose_field_is_off() {
    let (mut b, hi, ht) = sample_backend();
    b.off.insert(MASTER_FRIEND.into());
    b.off.insert(MASTER_SELF.into());
    let (p, allow) = project(&sample_snapshot(&hi, &ht), &b).unwrap();
    let slots: Vec<u32> = p.people.iter().map(|x| x.slot).collect();
    assert_eq!(slots, vec![0, 7], "the friend whose field is off is gone, we stay");
    assert!(!allow.contains_key(&hash_of(&png(2))), "the dropped friend's avatar is not servable");

    let snap = json!({ "people": [ { "slot": 9, "in_room": true, "name": "nobody" } ] }).to_string();
    let (p, _) = project(&snap, &MemBackend::default()).unwrap();
    assert!(p.people.is_empty(), "a person with no master is not shown");
}

/// The page draws a person exactly as `overlay_look` defines the look: the same
/// defaults for an absent key and for a plain avatar, and a look that is not
/// canonical refused whole.
#[test]
fn merge_looks_and_defaults_follow_the_look_manifest() {
    let canonical: Value = serde_json::from_str(&super::super::overlay_look::normalize("{}").unwrap()).unwrap();
    let want = parse_effects(canonical.get("effects"), &PARSE_BASE);
    assert_eq!(Effects::default(), want);
    assert_eq!(Layout::default().defaults, want);

    let (b, hi, _) = sample_backend();
    let mut allow = Allowlist::new();
    let look = resolve_look(&b, Some(&json!({ "states": { "idle": hi } })), None, &mut allow).unwrap();
    assert_eq!(look.effects, want, "an absent effect key takes the manifest's default");
    assert!(look.effects.scale_with_voice, "the manifest's scale_with_voice default");

    for bad in [json!({ "states": { "idle": hi, "muted": "XYZ" } }), json!({ "states": { "loud": hi.to_uppercase() } })] {
        let mut allow = Allowlist::new();
        assert!(resolve_look(&b, Some(&bad), None, &mut allow).is_none(), "{bad}");
        assert!(allow.is_empty(), "a refused look names no image: {bad}");
    }
}

/// With no profile store to read a field from, nobody but us is shown.
#[test]
fn merge_the_field_check_fails_closed_without_a_store() {
    assert!(crate::api::storage::get_store().lock().unwrap().is_none(), "precondition: no store in this process");
    assert!(DbBackend.field_off("SomeMaster1"));
}

// so-core-fix
/// A person we block never reaches a page, whatever Dart published, like a field
/// that says "off"; we always do.
#[test]
fn fix_projection_drops_a_person_we_block() {
    let (mut b, hi, ht) = sample_backend();
    let (p, _) = project(&sample_snapshot(&hi, &ht), &b).unwrap();
    let before: Vec<u32> = p.people.iter().map(|x| x.slot).collect();
    assert!(before.len() > 2, "CONTROL: the friend is shown: {before:?}");
    b.blocked.insert(MASTER_FRIEND.into());
    b.blocked.insert(MASTER_SELF.into());
    let (p, allow) = project(&sample_snapshot(&hi, &ht), &b).unwrap();
    let slots: Vec<u32> = p.people.iter().map(|x| x.slot).collect();
    assert_eq!(slots, vec![0, 7], "the blocked friend is gone, we stay");
    assert!(!allow.contains_key(&hash_of(&png(2))), "the blocked friend's avatar is not servable");
}

/// The server's store seam reads the block list, so the projection's block check
/// holds in the running app and not only against a test backend.
#[test]
fn fix_the_db_backend_reads_the_block_list() {
    let _g = crate::node::resolver::test_lock();
    let m = "Blockedmaster1";
    assert!(!DbBackend.blocked(m), "CONTROL: nobody blocked");
    crate::node::blocklist::block(m);
    let blocked = DbBackend.blocked(m);
    crate::node::blocklist::unblock(m);
    assert!(blocked, "a blocked master reads as shown");
}

/// Look images come from the overlay table only: the same bytes held as a sticker on
/// the rail are never allowlisted, and once held as an overlay image they are, and
/// the served bytes come from that table.
#[test]
fn fix_look_images_come_from_the_overlay_table() {
    let _s = serial();
    let _st = crate::api::storage::store_test_lock();
    let ms = crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).expect("store");
    let image = png(78);
    let h = hash_of(&image);
    ms.save_asset_blob(&h, &image, false, "sticker").unwrap();
    crate::api::storage::set_test_store(ms);
    let snapshot = json!({
        "layout": {},
        "people": [ { "slot": 0, "is_self": true, "in_room": true, "name": "x", "colour": "#112233",
                      "look": { "states": { "idle": h } } } ]
    })
    .to_string();
    let (_, as_sticker) = project(&snapshot, &DbBackend).unwrap();
    {
        let guard = crate::api::storage::get_store().lock().unwrap();
        guard.as_ref().unwrap().save_overlay_blob(&h, &image, false).unwrap();
    }
    let (_, as_overlay) = project(&snapshot, &DbBackend).unwrap();
    let served = as_overlay.get(&h).and_then(|src| load_image(&DbBackend, &h, src)).map(|(bytes, _)| bytes);
    crate::api::storage::set_test_store(crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).unwrap());
    assert!(!as_sticker.contains_key(&h), "a sticker blob was allowlisted as a look image");
    assert_eq!(as_overlay.get(&h), Some(&ImgSource::Overlay), "an overlay image is allowlisted");
    assert_eq!(served, Some(image), "and served from the overlay table");
}

// so-review-fix
fn state_index(name: &str) -> usize {
    LOOK_STATES.iter().position(|s| *s == name).unwrap()
}

/// Defense in depth behind `apply_answer`: someone else's look draws only the
/// images they may be drawn with (`Backend::look_images`: our picks, their look while
/// they share), whatever Dart published; our own look draws any overlay image we hold.
#[test]
fn review_fix_a_look_draws_only_what_the_person_may_be_drawn_with() {
    let (mut b, hi, ht) = sample_backend();
    let snap = json!({ "people": [
        { "slot": 0, "master": MASTER_SELF, "is_self": true, "in_room": true, "look": { "states": { "idle": hi } } },
        { "slot": 4, "master": MASTER_FRIEND, "in_room": true, "added": true,
          "look": { "states": { "idle": hi, "talking": ht } } }
    ] })
    .to_string();
    let (p, allow) = project(&snap, &b).unwrap();
    let friend = p.people.iter().find(|x| x.slot == 4).unwrap().look.clone().unwrap();
    assert!(friend.states.iter().all(String::is_empty), "a look the person may not be drawn with: {:?}", friend.states);
    assert_eq!(p.people[0].look.as_ref().unwrap().states[state_index("idle")], hi, "our own look is drawn");
    assert!(!allow.contains_key(&ht), "the friend's image is servable");

    b.looks.insert(MASTER_FRIEND.into(), HashSet::from([ht.clone()]));
    let (p, allow) = project(&snap, &b).unwrap();
    let friend = p.people.iter().find(|x| x.slot == 4).unwrap().look.clone().unwrap();
    assert_eq!(friend.states[state_index("talking")], ht, "an image the person may be drawn with");
    assert_eq!(friend.states[state_index("idle")], "", "only those images");
    assert_eq!(allow.get(&ht), Some(&ImgSource::Overlay));
}

/// We are drawn once: an entry that is not marked as us but names our master, or a
/// device of ours, never reaches a page.
#[test]
fn review_fix_projection_never_draws_us_twice() {
    let _g = crate::node::resolver::test_lock();
    crate::node::resolver::update("OurSibling8", MASTER_SELF);
    let (mut b, _, _) = sample_backend();
    let snap = json!({ "people": [
        { "slot": 0, "master": MASTER_SELF, "is_self": true, "in_room": true },
        { "slot": 3, "master": MASTER_SELF, "in_room": true },
        { "slot": 5, "master": "OurSibling8", "in_room": true },
        { "slot": 4, "master": MASTER_FRIEND, "in_room": true }
    ] })
    .to_string();
    let slots = |b: &MemBackend| project(&snap, b).unwrap().0.people.iter().map(|x| x.slot).collect::<Vec<_>>();
    let unknown = slots(&b);
    b.me = Some(MASTER_SELF.into());
    let known = slots(&b);
    crate::node::resolver::forget_for_test("OurSibling8");
    assert_eq!(unknown, vec![0, 3, 5, 4], "CONTROL: with the node down nobody counts as us");
    assert_eq!(known, vec![0, 4], "we, or a device of ours, were drawn twice");
}

/// A field or block change re-projects the last snapshot: the page drops whoever may
/// no longer be drawn, streams hear only a projection that changed, and a wipe in
/// between leaves nothing to bring back.
#[test]
fn review_fix_reproject_follows_a_changed_field() {
    let _s = serial();
    let (b, hi, ht) = sample_backend();
    fresh(b);
    publish(&sample_snapshot(&hi, &ht)).unwrap();
    let gen0 = state().snap_gen;
    reproject();
    assert_eq!(state().snap_gen, gen0, "nothing changed, yet the streams heard a new snapshot");

    let (mut off, _, _) = sample_backend();
    off.off.insert(MASTER_FRIEND.into());
    *backend_slot().write().unwrap() = Arc::new(off);
    reproject();
    assert_ne!(state().snap_gen, gen0, "the streams never heard");
    assert_eq!(snapshot_slots_for_test(), Some(vec![0, 7]), "the friend whose field turned off is still drawn");

    stop_for_wipe();
    reproject();
    assert_eq!(snapshot_slots_for_test(), None, "a wipe's snapshot came back");
}

/// The store seam behind `look_images` reads `overlay::drawable_images`: their look
/// only while they share, our picks always.
#[test]
fn review_fix_the_db_backend_draws_a_look_only_while_shared() {
    use crate::identity::native_identity::NativeKeypair;
    use super::super::overlay::{ingest_field, sign_field, FieldValue};
    let _s = serial();
    let _st = crate::api::storage::store_test_lock();
    let ms = crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).expect("store");
    let owner = NativeKeypair::from_secret_bytes(&[213; 32]);
    let m = owner.peer_id();
    let (theirs, pick) = ("a".repeat(64), "b".repeat(64));
    let look = |h: &str| super::super::overlay_look::normalize(&format!(r#"{{"stamp":5,"states":{{"idle":"{h}"}}}}"#)).unwrap();
    ms.save_profile_card(&m, "Pia", 1, "", None).unwrap();
    ms.overlay_add_person(&m, 1).unwrap();
    assert!(ingest_field(&ms, &m, Some(&sign_field(&owner, FieldValue::Share(5), 10)), i64::MAX, None));
    ms.overlay_set_their_look(&m, Some(&look(&theirs)), 5).unwrap();
    ms.overlay_set_local_look(&m, Some(&look(&pick))).unwrap();
    crate::api::storage::set_test_store(ms);
    let shared = DbBackend.look_images(&m);
    {
        let guard = crate::api::storage::get_store().lock().unwrap();
        let ms = guard.as_ref().unwrap();
        assert!(ingest_field(ms, &m, Some(&sign_field(&owner, FieldValue::Show, 20)), i64::MAX, None));
        ms.overlay_set_their_look(&m, Some(&look(&theirs)), 5).unwrap();
    }
    let shown = DbBackend.look_images(&m);
    crate::api::storage::set_test_store(crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).unwrap());
    assert_eq!(shared, HashSet::from([theirs, pick.clone()]));
    assert_eq!(shown, HashSet::from([pick]), "a look no longer shared is drawable");
}

/// AR-28: the browser source decodes natively too, so the store backend hands it
/// only images that passed the pure-Rust check, each kind on its own.
#[test]
fn the_browser_source_gets_only_images_that_pass_the_check() {
    let _l = crate::api::storage::store_test_lock();
    let good = {
        let img = image::RgbaImage::from_pixel(10, 10, image::Rgba([1, 2, 3, 255]));
        let mut out = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Png).unwrap();
        out
    };
    let mut bad = good.clone();
    let n = bad.len();
    for b in &mut bad[45..n - 16] {
        *b = 0x5A;
    }
    let ms = crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).unwrap();
    let (gh, bh) = (super::super::image_gate::digest(&good), super::super::image_gate::digest(&bad));
    for (h, b) in [(&gh, &good), (&bh, &bad)] {
        ms.save_asset_blob(h, b, false, "emote").unwrap();
        ms.save_overlay_blob(h, b, false).unwrap();
    }
    ms.save_profile("bad", "B", "", "", 1, Some(&bad), None, "", None, None, None, None, None, None, None).unwrap();
    ms.save_profile("good", "G", "", "", 1, Some(&good), None, "", None, None, None, None, None, None, None).unwrap();
    crate::api::storage::set_test_store(ms);

    assert_eq!(DbBackend.blob(&bh), None);
    assert_eq!(DbBackend.overlay_image(&bh), None);
    assert_eq!(DbBackend.still_avatar("bad"), None);
    assert_eq!(DbBackend.blob(&gh), Some(good.clone()));
    assert_eq!(DbBackend.overlay_image(&gh), Some(good.clone()));
    assert_eq!(DbBackend.still_avatar("good"), Some(good));
    crate::api::storage::set_test_store(crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).unwrap());
}
