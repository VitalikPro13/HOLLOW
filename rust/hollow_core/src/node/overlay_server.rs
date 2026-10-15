//! Loopback page server for the OBS stream overlay (#97, plan section 7).
//!
//! Any local program and any website the user visits can reach a loopback port, so
//! every request passes the Host check (DNS rebinding), the Origin check and the
//! token before anything else, and an image is served only while the current
//! projection names it. Nothing about paths or people is logged.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, RwLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, watch, Semaphore};

use super::NetworkEvent;

/// Clear of the Windows dynamic range (49152 and up).
const PORT_LOW: u16 = 20000;
const PORT_HIGH: u16 = 39999;
const PORT_TRIES: usize = 64;
const MAX_HEAD_BYTES: usize = 8 * 1024;
const MAX_CONNECTIONS: usize = 16;
const MAX_STREAMS: u32 = 8;
const IDLE_TIMEOUT: Duration = Duration::from_secs(30);
/// A fresh socket must name itself quickly, so silent preconnects cannot hold slots.
const FIRST_HEAD_TIMEOUT: Duration = Duration::from_secs(5);
const HEARTBEAT: Duration = Duration::from_secs(15);
/// A stalled reader (a frozen OBS) must not hold a stream slot forever.
const WRITE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_SNAPSHOT_BYTES: usize = 1024 * 1024;
const MAX_LIVE_BYTES: usize = 64 * 1024;
const MAX_PEOPLE: usize = 200;
const MAX_SLOT: u64 = 1_000_000;
const MAX_NAME_CHARS: usize = 64;
const MAX_MASTER_CHARS: usize = 128;
const DEFAULT_COLOUR: &str = "#a1a1aa";
const LINK_FILE: &str = "overlay_server.json";
const LOOK_STATES: [&str; 6] = ["idle", "talking", "muted", "deafened", "blink", "loud"];
const PERSON_STATES: [&str; 4] = ["idle", "talking", "muted", "deafened"];

const PAGE_HTML: &str = include_str!("overlay_page/overlay.html");
const PAGE_JS: &str = include_str!("overlay_page/overlay.js");
const PAGE_CSS: &str = include_str!("overlay_page/overlay.css");

const SECURITY_HEADERS: &str = "Cache-Control: no-store\r\n\
X-Content-Type-Options: nosniff\r\n\
Referrer-Policy: no-referrer\r\n\
Cross-Origin-Resource-Policy: same-origin\r\n\
Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; connect-src 'self'; frame-ancestors 'none'\r\n";

// ---------------------------------------------------------------------------
// Storage seam

/// The port, token and "Run the overlay for OBS" choice of this profile.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub(crate) struct SavedLink {
    #[serde(default)]
    pub port: u16,
    #[serde(default)]
    pub token: String,
    #[serde(default)]
    pub enabled: bool,
}

/// Everything the server reads from disk, behind one seam so tests run without a
/// profile.
pub(crate) trait Backend: Send + Sync {
    fn load_link(&self) -> Option<SavedLink>;
    fn save_link(&self, link: &SavedLink) -> Result<(), String>;
    /// The animated avatar's rail hash from `master`'s stored profile.
    fn anim_avatar(&self, master: &str) -> Option<String>;
    fn still_avatar(&self, master: &str) -> Option<Vec<u8>>;
    /// The rail kind a held blob was stored under, `None` when we do not hold it.
    fn blob_kind(&self, hash: &str) -> Option<String>;
    fn blob(&self, hash: &str) -> Option<Vec<u8>>;
    /// Whether we hold `hash` as a stream overlay image (never a rail blob).
    fn holds_overlay_image(&self, hash: &str) -> bool;
    fn overlay_image(&self, hash: &str) -> Option<Vec<u8>>;
    /// Whether `master`'s signed field says "off"; true when it cannot be read.
    fn field_off(&self, master: &str) -> bool;
    /// Whether we block `master`.
    fn blocked(&self, master: &str) -> bool;
    /// The overlay images `master`'s look may name (`overlay::drawable_images`).
    fn look_images(&self, master: &str) -> HashSet<String>;
    /// Our own master; `None` while the node is down.
    fn local_master(&self) -> Option<String>;
}

/// Reads through the long-lived FFI store, never a fresh `MessageStore::open`.
struct DbBackend;

fn with_store<T>(f: impl FnOnce(&crate::storage::MessageStore) -> Option<T>) -> Option<T> {
    let guard = crate::api::storage::get_store().lock().ok()?;
    f(guard.as_ref()?)
}

impl Backend for DbBackend {
    fn load_link(&self) -> Option<SavedLink> {
        read_link(&crate::identity::data_dir().ok()?)
    }
    fn save_link(&self, link: &SavedLink) -> Result<(), String> {
        write_link(&crate::identity::data_dir()?, link)
    }
    fn anim_avatar(&self, master: &str) -> Option<String> {
        with_store(|ms| ms.load_profile_light(master).ok().flatten()).map(|p| p.avatar_anim)
    }
    fn still_avatar(&self, master: &str) -> Option<Vec<u8>> {
        with_store(|ms| ms.load_avatar_for_display(master).ok().flatten())
    }
    fn blob_kind(&self, hash: &str) -> Option<String> {
        with_store(|ms| ms.asset_blob_kind(hash).ok().flatten())
    }
    fn blob(&self, hash: &str) -> Option<Vec<u8>> {
        with_store(|ms| ms.load_emote_blob(hash).ok().flatten())
    }
    fn holds_overlay_image(&self, hash: &str) -> bool {
        with_store(|ms| ms.has_overlay_blob(hash).ok()).unwrap_or(false)
    }
    fn overlay_image(&self, hash: &str) -> Option<Vec<u8>> {
        with_store(|ms| ms.load_overlay_blob(hash).ok().flatten())
    }
    fn field_off(&self, master: &str) -> bool {
        let master = super::resolver::resolve(master);
        with_store(|ms| Some(super::overlay::field_of(ms, &master) == super::overlay::FieldValue::Off))
            .unwrap_or(true)
    }
    fn blocked(&self, master: &str) -> bool {
        super::blocklist::is_blocked(master)
    }
    fn look_images(&self, master: &str) -> HashSet<String> {
        let master = super::resolver::resolve(master);
        with_store(|ms| Some(super::overlay::drawable_images(ms, &master))).unwrap_or_default()
    }
    fn local_master(&self) -> Option<String> {
        crate::api::network::get_local_peer_id()
    }
}

/// A plain file in the profile's root: per profile (#47), never carried by a device
/// link, and swept by the wipe. The token guards against websites, not against
/// programs running as the user, which can read OBS's scene files anyway.
fn read_link(root: &Path) -> Option<SavedLink> {
    let text = std::fs::read_to_string(root.join(LINK_FILE)).ok()?;
    let link: SavedLink = serde_json::from_str(&text).ok()?;
    (valid_token(&link.token) && (link.port == 0 || port_in_range(link.port))).then_some(link)
}

fn write_link(root: &Path, link: &SavedLink) -> Result<(), String> {
    let text = serde_json::to_string(link).map_err(|e| format!("Failed to save the overlay link: {e}"))?;
    let staged = root.join(format!("{LINK_FILE}.tmp"));
    std::fs::write(&staged, text).map_err(|e| format!("Failed to save the overlay link: {e}"))?;
    std::fs::rename(&staged, root.join(LINK_FILE))
        .map_err(|e| format!("Failed to save the overlay link: {e}"))
}

fn backend_slot() -> &'static RwLock<Arc<dyn Backend>> {
    static SLOT: OnceLock<RwLock<Arc<dyn Backend>>> = OnceLock::new();
    SLOT.get_or_init(|| RwLock::new(Arc::new(DbBackend)))
}

fn backend() -> Arc<dyn Backend> {
    backend_slot().read().unwrap_or_else(|e| e.into_inner()).clone()
}

// ---------------------------------------------------------------------------
// Projection: what a page may see, built from what Dart published

#[derive(Clone, Debug, PartialEq, Serialize)]
struct Effects {
    talking: &'static str,
    scale_with_voice: bool,
    idle: &'static str,
    transition: &'static str,
    hold_ms: u32,
    blink_every_s: f64,
    loud_threshold: f64,
    mirror: bool,
    shadow: &'static str,
}

/// Only the base the canonical defaults are read over; every key overrides it.
const PARSE_BASE: Effects = Effects {
    talking: "bounce",
    scale_with_voice: false,
    idle: "none",
    transition: "crossfade",
    hold_ms: 250,
    blink_every_s: 5.0,
    loud_threshold: 0.75,
    mirror: false,
    shadow: "none",
};

impl Default for Effects {
    /// The look manifest's own defaults, so a plain avatar and a look missing a key
    /// draw exactly as `overlay_look` says everywhere.
    fn default() -> Self {
        static DEFAULTS: OnceLock<Effects> = OnceLock::new();
        DEFAULTS
            .get_or_init(|| {
                let canonical = super::overlay_look::normalize("{}").unwrap_or_default();
                let look: Value = serde_json::from_str(&canonical).unwrap_or(Value::Null);
                parse_effects(look.get("effects"), &PARSE_BASE)
            })
            .clone()
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
struct Layout {
    direction: &'static str,
    align: &'static str,
    size: u32,
    gap: u32,
    names: &'static str,
    only_talking: bool,
    only_added: bool,
    self_when_inactive: &'static str,
    defaults: Effects,
}

impl Default for Layout {
    fn default() -> Self {
        Self {
            direction: "row",
            align: "center",
            size: 160,
            gap: 12,
            names: "pill",
            only_talking: false,
            only_added: false,
            self_when_inactive: "idle",
            defaults: Effects::default(),
        }
    }
}

/// A look with every state reduced to a hash we hold, or empty.
#[derive(Clone, Debug, PartialEq)]
struct Look {
    states: [String; 6],
    effects: Effects,
}

#[derive(Clone, Debug, PartialEq)]
struct Person {
    slot: u32,
    is_self: bool,
    in_room: bool,
    added: bool,
    name: String,
    colour: String,
    /// Hash of the avatar image, or empty for the initials circle.
    avatar: String,
    look: Option<Look>,
}

#[derive(Clone, Debug, Default, PartialEq)]
struct Projected {
    layout: Layout,
    people: Vec<Person>,
}

#[derive(Clone, Debug, PartialEq)]
enum ImgSource {
    /// A rail blob of this kind, stored under its own hash.
    Blob(&'static str),
    /// A stream overlay image, stored under its own hash.
    Overlay,
    /// `master`'s still avatar from the profile store, named by the hash of its bytes.
    Still(String),
}

type Allowlist = HashMap<String, ImgSource>;

#[derive(Clone, Debug, Default, PartialEq)]
struct Live {
    people: Vec<(u32, &'static str, f64)>,
    self_active: bool,
}

fn pick(v: Option<&Value>, allowed: &[&'static str], default: &'static str) -> &'static str {
    v.and_then(Value::as_str)
        .and_then(|s| allowed.iter().find(|a| **a == s).copied())
        .unwrap_or(default)
}

fn number(v: Option<&Value>, lo: f64, hi: f64, default: f64) -> f64 {
    v.and_then(Value::as_f64).filter(|n| n.is_finite()).map_or(default, |n| n.clamp(lo, hi))
}

fn flag(v: Option<&Value>, default: bool) -> bool {
    v.and_then(Value::as_bool).unwrap_or(default)
}

fn is_hash(s: &str) -> bool {
    crate::crdt::valid_emote_hash(s)
}

fn valid_token(s: &str) -> bool {
    is_hash(s)
}

fn port_in_range(p: u16) -> bool {
    (PORT_LOW..=PORT_HIGH).contains(&p)
}

fn parse_effects(v: Option<&Value>, base: &Effects) -> Effects {
    let Some(o) = v.and_then(Value::as_object) else { return base.clone() };
    Effects {
        talking: pick(o.get("talking"), &["none", "bounce", "shake", "pop", "glow"], base.talking),
        scale_with_voice: flag(o.get("scale_with_voice"), base.scale_with_voice),
        idle: pick(o.get("idle"), &["none", "dim", "grayscale"], base.idle),
        transition: pick(o.get("transition"), &["instant", "crossfade"], base.transition),
        hold_ms: number(o.get("hold_ms"), 0.0, 600.0, f64::from(base.hold_ms)).round() as u32,
        blink_every_s: number(o.get("blink_every_s"), 2.0, 12.0, base.blink_every_s),
        loud_threshold: number(o.get("loud_threshold"), 0.5, 0.95, base.loud_threshold),
        mirror: flag(o.get("mirror"), base.mirror),
        shadow: pick(o.get("shadow"), &["none", "soft", "outline"], base.shadow),
    }
}

fn parse_layout(v: Option<&Value>) -> Layout {
    let d = Layout::default();
    let Some(o) = v.and_then(Value::as_object) else { return d };
    Layout {
        direction: pick(o.get("direction"), &["row", "column", "grid"], d.direction),
        align: pick(o.get("align"), &["start", "center", "end"], d.align),
        size: number(o.get("size"), 48.0, 512.0, f64::from(d.size)).round() as u32,
        gap: number(o.get("gap"), 0.0, 64.0, f64::from(d.gap)).round() as u32,
        names: pick(o.get("names"), &["none", "plain", "pill"], d.names),
        only_talking: flag(o.get("only_talking"), d.only_talking),
        only_added: flag(o.get("only_added"), d.only_added),
        self_when_inactive: pick(o.get("self_when_inactive"), &["idle", "hidden"], d.self_when_inactive),
        defaults: parse_effects(o.get("defaults"), &d.defaults),
    }
}

/// Control and bidi-override characters dropped, at most 64 characters kept.
fn clean_name(v: Option<&Value>) -> String {
    let raw = v.and_then(Value::as_str).unwrap_or("");
    raw.chars()
        .filter(|c| !c.is_control() && !matches!(*c, '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{200E}' | '\u{200F}'))
        .take(MAX_NAME_CHARS)
        .collect::<String>()
        .trim()
        .to_string()
}

fn clean_colour(v: Option<&Value>) -> String {
    match v.and_then(Value::as_str) {
        Some(c) if c.len() == 7 && c.starts_with('#') && c[1..].bytes().all(|b| b.is_ascii_hexdigit()) => {
            c.to_ascii_lowercase()
        }
        _ => DEFAULT_COLOUR.to_string(),
    }
}

fn plausible_master(m: &str) -> bool {
    !m.is_empty() && m.len() <= MAX_MASTER_CHARS && m.bytes().all(|b| b.is_ascii_alphanumeric())
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

/// Whether we hold `hash` as a rail blob of `kind`.
fn held_as(b: &dyn Backend, hash: &str, kind: &str) -> bool {
    is_hash(hash) && b.blob_kind(hash).as_deref() == Some(kind)
}

/// Whether we hold `hash` as an overlay image: a look names nothing else, so it can
/// never probe for an emote or sticker the streamer holds.
fn held_overlay(b: &dyn Backend, hash: &str) -> bool {
    is_hash(hash) && b.holds_overlay_image(hash)
}

fn resolve_avatar(b: &dyn Backend, master: &str, allow: &mut Allowlist) -> String {
    if !plausible_master(master) {
        return String::new();
    }
    let profile = super::assets::AssetKind::Profile.db_kind();
    if let Some(anim) = b.anim_avatar(master).filter(|h| held_as(b, h, profile)) {
        allow.insert(anim.clone(), ImgSource::Blob(profile));
        return anim;
    }
    match b.still_avatar(master).filter(|s| !s.is_empty()) {
        Some(still) => {
            let hash = sha256_hex(&still);
            allow.insert(hash.clone(), ImgSource::Still(master.to_string()));
            hash
        }
        None => String::new(),
    }
}

/// The page reads only the canonical look `overlay_look::normalize` returns (a
/// refused look draws the plain avatar), each state reduced to an overlay image we
/// hold.
/// `only`, for anyone but us, is the images their look may name.
fn resolve_look(b: &dyn Backend, v: Option<&Value>, only: Option<&HashSet<String>>, allow: &mut Allowlist) -> Option<Look> {
    let canonical = super::overlay_look::normalize(&v?.to_string()).ok()?;
    let o: Value = serde_json::from_str(&canonical).ok()?;
    let states_in = o.get("states").and_then(Value::as_object);
    let states = LOOK_STATES.map(|key| {
        let hash = states_in.and_then(|s| s.get(key)).and_then(Value::as_str).unwrap_or("");
        if only.is_none_or(|o| o.contains(hash)) && held_overlay(b, hash) {
            allow.insert(hash.to_string(), ImgSource::Overlay);
            hash.to_string()
        } else {
            String::new()
        }
    });
    Some(Look { states, effects: parse_effects(o.get("effects"), &Effects::default()) })
}

/// Validates and projects a published snapshot; the allowlist is exactly the images
/// it names.
fn project(json: &str, b: &dyn Backend) -> Result<(Projected, Allowlist), String> {
    if json.len() > MAX_SNAPSHOT_BYTES {
        return Err("Overlay snapshot too large".into());
    }
    let root: Value = serde_json::from_str(json).map_err(|_| "Overlay snapshot is not valid JSON".to_string())?;
    let layout = parse_layout(root.get("layout"));
    let mut allow = Allowlist::new();
    let mut people = Vec::new();
    let mut slots = HashSet::new();
    let mut have_self = false;
    // Unknown while the node is down: then nobody counts as us, since this only keeps
    // us from being drawn twice and never hides anyone else.
    let me = b.local_master();
    let is_us = |master: &str| me.as_deref().is_some_and(|me| super::resolver::resolve(master) == me);
    for p in root.get("people").and_then(Value::as_array).into_iter().flatten().take(MAX_PEOPLE) {
        let Some(slot) = p.get("slot").and_then(Value::as_u64).filter(|s| *s <= MAX_SLOT) else { continue };
        if !slots.insert(slot) {
            continue;
        }
        let is_self = flag(p.get("is_self"), false) && !have_self;
        have_self |= is_self;
        let master = p.get("master").and_then(Value::as_str).unwrap_or("");
        // Behind Dart's own filter: someone whose field says "off" or whom we block
        // never reaches a page, nor someone we cannot name, nor we a second time.
        if !is_self && (!plausible_master(master) || b.field_off(master) || b.blocked(master) || is_us(master)) {
            continue;
        }
        let only = (!is_self).then(|| b.look_images(master));
        people.push(Person {
            slot: slot as u32,
            is_self,
            in_room: flag(p.get("in_room"), false),
            added: flag(p.get("added"), false),
            name: clean_name(p.get("name")),
            colour: clean_colour(p.get("colour")),
            avatar: resolve_avatar(b, master, &mut allow),
            look: resolve_look(b, p.get("look"), only.as_ref(), &mut allow),
        });
    }
    Ok((Projected { layout, people }, allow))
}

fn parse_live(json: &str) -> Result<Live, String> {
    if json.len() > MAX_LIVE_BYTES {
        return Err("Overlay live update too large".into());
    }
    let root: Value = serde_json::from_str(json).map_err(|_| "Overlay live update is not valid JSON".to_string())?;
    let mut seen = HashSet::new();
    let people = root
        .get("people")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .take(MAX_PEOPLE)
        .filter_map(|p| {
            let slot = p.get("slot").and_then(Value::as_u64).filter(|s| *s <= MAX_SLOT)?;
            seen.insert(slot).then(|| {
                let level = (number(p.get("level"), 0.0, 1.0, 0.0) * 1000.0).round() / 1000.0;
                (slot as u32, pick(p.get("state"), &PERSON_STATES, "idle"), level)
            })
        })
        .collect();
    Ok(Live { people, self_active: flag(root.get("self_active"), true) })
}

#[derive(Clone, Debug, PartialEq)]
enum View {
    Room,
    Me,
    Person(u32),
}

fn parse_slot(s: &str) -> Option<u32> {
    if s.is_empty() || s.len() > 7 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse::<u64>().ok().filter(|n| *n <= MAX_SLOT).map(|n| n as u32)
}

fn parse_view(query: &str) -> Option<View> {
    let value = query.split('&').find_map(|kv| kv.strip_prefix("view="))?;
    match value {
        "room" => Some(View::Room),
        "me" => Some(View::Me),
        v => parse_slot(v.strip_prefix("p/").or_else(|| v.strip_prefix("p%2F")).or_else(|| v.strip_prefix("p%2f"))?)
            .map(View::Person),
    }
}

fn view_people<'a>(p: &'a Projected, view: &View) -> Vec<&'a Person> {
    match view {
        View::Room => {
            let mut out: Vec<&Person> = p.people.iter().filter(|x| x.in_room && x.is_self).collect();
            out.extend(p.people.iter().filter(|x| x.in_room && !x.is_self));
            out
        }
        View::Me => p.people.iter().filter(|x| x.is_self).collect(),
        View::Person(slot) => p.people.iter().filter(|x| x.slot == *slot).collect(),
    }
}

fn img_url(token: &str, hash: &str) -> String {
    if hash.is_empty() {
        String::new()
    } else {
        format!("/{token}/img/{hash}")
    }
}

fn render_snapshot(p: &Projected, view: &View, token: &str) -> String {
    let people: Vec<Value> = view_people(p, view)
        .into_iter()
        .map(|x| {
            let look = x.look.as_ref().map(|l| {
                let states: serde_json::Map<String, Value> = LOOK_STATES
                    .iter()
                    .zip(l.states.iter())
                    .map(|(k, h)| ((*k).to_string(), Value::String(img_url(token, h))))
                    .collect();
                json!({ "states": states, "effects": l.effects })
            });
            json!({
                "slot": x.slot,
                "self": x.is_self,
                "added": x.added,
                "name": x.name,
                "colour": x.colour,
                "avatar": img_url(token, &x.avatar),
                "look": look,
            })
        })
        .collect();
    json!({ "layout": p.layout, "people": people }).to_string()
}

fn render_live(live: &Live, p: Option<&Projected>, view: &View) -> String {
    let shown: HashSet<u32> = p.map(|p| view_people(p, view).iter().map(|x| x.slot).collect()).unwrap_or_default();
    let people: Vec<Value> = live
        .people
        .iter()
        .filter(|(slot, _, _)| shown.contains(slot))
        .map(|(slot, state, level)| json!({ "slot": slot, "state": state, "level": level }))
        .collect();
    json!({ "people": people, "self_active": live.self_active }).to_string()
}

// ---------------------------------------------------------------------------
// Server state

struct Running {
    port: u16,
    token: String,
    accept: tokio::task::JoinHandle<()>,
}

impl Running {
    /// Aborts the server and waits briefly for the listener to close, so turning it
    /// straight back on finds its own port free instead of moving it.
    fn halt(self) {
        self.accept.abort();
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        while !self.accept.is_finished() && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(2));
        }
    }
}

struct Server {
    running: Option<Running>,
    locked: bool,
    port_changed: bool,
    open_streams: u32,
    snap: Option<Arc<Projected>>,
    /// The snapshot as Dart published it, projected again when a field or block changes.
    raw: Option<Arc<str>>,
    snap_gen: u64,
    live: Option<Arc<Live>>,
    live_gen: u64,
    allow: Allowlist,
}

/// Locked until Dart says the app is unlocked: Rust holds no App Lock state of its own.
impl Default for Server {
    fn default() -> Self {
        Self {
            running: None,
            locked: true,
            port_changed: false,
            open_streams: 0,
            snap: None,
            raw: None,
            snap_gen: 0,
            live: None,
            live_gen: 0,
            allow: Allowlist::new(),
        }
    }
}

fn state() -> MutexGuard<'static, Server> {
    static STATE: OnceLock<Mutex<Server>> = OnceLock::new();
    STATE.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner())
}

/// Bumped on every change a stream may have to forward.
fn wake_tx() -> &'static watch::Sender<u64> {
    static WAKE: OnceLock<watch::Sender<u64>> = OnceLock::new();
    WAKE.get_or_init(|| watch::channel(0).0)
}

fn wake() {
    wake_tx().send_modify(|g| *g = g.wrapping_add(1));
}

/// Serializes publishers so an older projection never lands after a newer one.
fn publish_lock() -> MutexGuard<'static, ()> {
    static LOCK: Mutex<()> = Mutex::new(());
    LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

/// What `overlay_server_status` reports.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Status {
    pub enabled: bool,
    pub running: bool,
    pub port: u16,
    pub port_changed: bool,
    pub open_streams: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Links {
    pub room: String,
    pub me: String,
    pub person_base: String,
}

fn links_for(port: u16, token: &str) -> Links {
    let base = format!("http://127.0.0.1:{port}/{token}");
    Links { room: format!("{base}/room"), me: format!("{base}/me"), person_base: format!("{base}/p/") }
}

pub(crate) fn status() -> Status {
    let saved = backend().load_link();
    let st = state();
    Status {
        enabled: saved.as_ref().is_some_and(|l| l.enabled),
        running: st.running.is_some(),
        port: st.running.as_ref().map(|r| r.port).or(saved.map(|l| l.port)).unwrap_or(0),
        port_changed: st.port_changed,
        open_streams: st.open_streams,
    }
}

fn mint_token() -> Result<String, String> {
    let mut raw = [0u8; 32];
    getrandom::fill(&mut raw).map_err(|e| format!("RNG failed: {e}"))?;
    Ok(hex::encode(raw))
}

fn random_port() -> Result<u16, String> {
    let mut raw = [0u8; 2];
    getrandom::fill(&mut raw).map_err(|e| format!("RNG failed: {e}"))?;
    Ok(PORT_LOW + u16::from_le_bytes(raw) % (PORT_HIGH - PORT_LOW + 1))
}

/// Binds the saved port, else a random one; the bool says the saved port was lost.
fn bind_port(saved: u16) -> Result<(std::net::TcpListener, bool), String> {
    if let Some(l) = (saved != 0).then(|| std::net::TcpListener::bind(("127.0.0.1", saved)).ok()).flatten() {
        return Ok((l, false));
    }
    for _ in 0..PORT_TRIES {
        let port = random_port()?;
        if let Ok(l) = std::net::TcpListener::bind(("127.0.0.1", port)) {
            return Ok((l, saved != 0));
        }
    }
    Err("No free port for the overlay".into())
}

/// Starts (or stops) the server and remembers the choice for this profile.
pub(crate) fn set_enabled(enabled: bool) -> Result<Status, String> {
    if cfg!(any(target_os = "android", target_os = "ios")) {
        return Err("The overlay for OBS runs on desktop only".into());
    }
    let b = backend();
    if !enabled {
        if let Some(mut link) = b.load_link() {
            link.enabled = false;
            b.save_link(&link)?;
        }
        stop();
        state().port_changed = false;
        return Ok(status());
    }
    {
        let mut st = state();
        if st.running.is_none() {
            let mut link = match b.load_link() {
                Some(l) => l,
                None => SavedLink { port: 0, token: mint_token()?, enabled: true },
            };
            let (listener, moved) = bind_port(link.port)?;
            let port = listener.local_addr().map_err(|e| format!("Failed to read the overlay port: {e}"))?.port();
            link.port = port;
            // OBS keeps sending the old link to whatever listens on the old port now.
            if moved {
                link.token = mint_token()?;
            }
            link.enabled = true;
            b.save_link(&link)?;
            listener.set_nonblocking(true).map_err(|e| format!("Failed to start the overlay: {e}"))?;
            let rt = crate::api::network::get_runtime();
            let listener = {
                let _ctx = rt.enter();
                TcpListener::from_std(listener).map_err(|e| format!("Failed to start the overlay: {e}"))?
            };
            let accept = rt.spawn(accept_loop(listener, port));
            st.running = Some(Running { port, token: link.token, accept });
            if moved {
                st.port_changed = true;
                emit(NetworkEvent::OverlayPortChanged { port });
            }
        } else if let Some(mut link) = b.load_link().filter(|l| !l.enabled) {
            link.enabled = true;
            b.save_link(&link)?;
        }
    }
    wake();
    Ok(status())
}

fn stop() {
    let running = state().running.take();
    if let Some(r) = running {
        r.halt();
    }
    wake();
}

/// The wipe stops the server and forgets what it served, with no Dart round trip.
pub(crate) fn stop_for_wipe() {
    let running = {
        let mut st = state();
        st.snap = None;
        st.raw = None;
        st.live = None;
        st.allow.clear();
        st.port_changed = false;
        st.locked = true;
        st.running.take()
    };
    if let Some(r) = running {
        r.halt();
    }
    wake();
}

pub(crate) fn links() -> Result<Links, String> {
    if let Some(r) = state().running.as_ref() {
        return Ok(links_for(r.port, &r.token));
    }
    match backend().load_link() {
        Some(l) if l.port != 0 => Ok(links_for(l.port, &l.token)),
        _ => Err("The overlay has not run yet".into()),
    }
}

/// Mints a new token; every old link and open stream stops working at once.
pub(crate) fn reset_link() -> Result<Links, String> {
    let b = backend();
    let token = mint_token()?;
    let link = {
        let mut st = state();
        let mut link = b.load_link().unwrap_or_default();
        link.token = token.clone();
        if let Some(r) = st.running.as_mut() {
            link.port = r.port;
            link.enabled = true;
            b.save_link(&link)?;
            r.token = token;
        } else {
            b.save_link(&link)?;
        }
        st.port_changed = false;
        link
    };
    wake();
    if link.port == 0 {
        return Err("The overlay has not run yet".into());
    }
    Ok(links_for(link.port, &link.token))
}

pub(crate) fn publish(snapshot_json: &str) -> Result<(), String> {
    let _order = publish_lock();
    let (projected, allow) = project(snapshot_json, &*backend())?;
    {
        let mut st = state();
        st.snap = Some(Arc::new(projected));
        st.raw = Some(Arc::from(snapshot_json));
        st.allow = allow;
        st.snap_gen = st.snap_gen.wrapping_add(1);
    }
    wake();
    Ok(())
}

/// A field or a block changed: project the last snapshot again, so a page drops
/// whoever may no longer be drawn without waiting for Dart. Streams hear only a
/// projection that differs.
pub(crate) fn reproject() {
    let _order = publish_lock();
    let Some(raw) = state().raw.clone() else { return };
    let Ok((projected, allow)) = project(&raw, &*backend()) else { return };
    {
        let mut st = state();
        // A wipe in between leaves nothing to bring back.
        let current = st.raw.as_ref().is_some_and(|r| Arc::ptr_eq(r, &raw));
        if !current || (st.snap.as_deref() == Some(&projected) && st.allow == allow) {
            return;
        }
        st.snap = Some(Arc::new(projected));
        st.allow = allow;
        st.snap_gen = st.snap_gen.wrapping_add(1);
    }
    wake();
}

pub(crate) fn publish_live(live_json: &str) -> Result<(), String> {
    let live = parse_live(live_json)?;
    {
        let mut st = state();
        st.live = Some(Arc::new(live));
        st.live_gen = st.live_gen.wrapping_add(1);
    }
    wake();
    Ok(())
}

/// The server is process-global, so every test that drives it takes turns.
#[cfg(test)]
pub(crate) fn test_serial() -> MutexGuard<'static, ()> {
    static LOCK: Mutex<()> = Mutex::new(());
    LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

#[cfg(test)]
pub(crate) fn use_db_backend_for_test() {
    *backend_slot().write().unwrap_or_else(|e| e.into_inner()) = Arc::new(DbBackend);
}

/// The slots the current projection shows.
#[cfg(test)]
pub(crate) fn snapshot_slots_for_test() -> Option<Vec<u32>> {
    state().snap.as_ref().map(|p| p.people.iter().map(|x| x.slot).collect())
}

/// App Lock: streams get `locked` and serve nothing until unlock.
pub(crate) fn set_locked(locked: bool) {
    state().locked = locked;
    wake();
}

// ---------------------------------------------------------------------------
// Events to Dart

fn event_sink() -> &'static Mutex<Option<mpsc::WeakSender<NetworkEvent>>> {
    static SINK: OnceLock<Mutex<Option<mpsc::WeakSender<NetworkEvent>>>> = OnceLock::new();
    SINK.get_or_init(|| Mutex::new(None))
}

/// Points events at the running node's channel. Weak, so a stopped node's channel
/// still closes.
pub(crate) fn set_event_sink(tx: mpsc::WeakSender<NetworkEvent>) {
    *event_sink().lock().unwrap_or_else(|e| e.into_inner()) = Some(tx);
}

/// One forwarder keeps the events in order.
fn emit(ev: NetworkEvent) {
    static OUTBOX: OnceLock<mpsc::UnboundedSender<NetworkEvent>> = OnceLock::new();
    let tx = OUTBOX.get_or_init(|| {
        let (tx, mut rx) = mpsc::unbounded_channel::<NetworkEvent>();
        crate::api::network::get_runtime().spawn(async move {
            while let Some(ev) = rx.recv().await {
                let sink = event_sink().lock().unwrap_or_else(|e| e.into_inner()).as_ref().and_then(|w| w.upgrade());
                if let Some(sink) = sink {
                    let _ = sink.send(ev).await;
                }
            }
        });
        tx
    });
    let _ = tx.send(ev);
}

// ---------------------------------------------------------------------------
// HTTP

#[cfg(not(test))]
fn idle_timeout() -> Duration {
    IDLE_TIMEOUT
}

#[cfg(not(test))]
fn first_head_timeout() -> Duration {
    FIRST_HEAD_TIMEOUT
}

#[cfg(not(test))]
fn heartbeat_every() -> Duration {
    HEARTBEAT
}

#[cfg(test)]
static TEST_TIMING_MS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Tests scale the idle cut to three times the first-head cut, as in production.
#[cfg(test)]
fn idle_timeout() -> Duration {
    match TEST_TIMING_MS.load(std::sync::atomic::Ordering::Relaxed) {
        0 => IDLE_TIMEOUT,
        ms => Duration::from_millis(ms * 3),
    }
}

#[cfg(test)]
fn first_head_timeout() -> Duration {
    match TEST_TIMING_MS.load(std::sync::atomic::Ordering::Relaxed) {
        0 => FIRST_HEAD_TIMEOUT,
        ms => Duration::from_millis(ms),
    }
}

#[cfg(test)]
fn heartbeat_every() -> Duration {
    match TEST_TIMING_MS.load(std::sync::atomic::Ordering::Relaxed) {
        0 => HEARTBEAT,
        ms => Duration::from_millis(ms),
    }
}

async fn accept_loop(listener: TcpListener, port: u16) {
    let permits = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    // Dropping the set (the task aborted) aborts every connection with it.
    let mut conns = tokio::task::JoinSet::new();
    loop {
        while conns.try_join_next().is_some() {}
        // The permit is taken BEFORE accept so an over-limit client waits in the
        // backlog instead of being accepted and starved.
        let Ok(permit) = permits.clone().acquire_owned().await else { return };
        let stream = match listener.accept().await {
            Ok((s, _)) => s,
            Err(_) => {
                tokio::time::sleep(Duration::from_millis(50)).await;
                continue;
            }
        };
        conns.spawn(async move {
            let _permit = permit;
            let _ = serve_connection(stream, port).await;
        });
    }
}

struct Request {
    method_ok: bool,
    head_only: bool,
    target: String,
    hosts: Vec<String>,
    origins: Vec<String>,
    close: bool,
}

#[derive(Clone, Debug, PartialEq)]
enum Route {
    Page,
    Js,
    Css,
    Events(View),
    Img(String),
}

fn parse_request(head: &[u8]) -> Option<Request> {
    let text = std::str::from_utf8(head).ok()?;
    let mut lines = text.split("\r\n");
    let mut parts = lines.next()?.split(' ');
    let method = parts.next()?;
    let target = parts.next()?.to_string();
    let version = parts.next()?;
    if !version.starts_with("HTTP/1.") || parts.next().is_some() {
        return None;
    }
    let mut req = Request {
        method_ok: matches!(method, "GET" | "HEAD"),
        head_only: method == "HEAD",
        target,
        hosts: Vec::new(),
        origins: Vec::new(),
        close: version == "HTTP/1.0",
    };
    for line in lines {
        let Some((name, value)) = line.split_once(':') else { continue };
        let value = value.trim().to_string();
        match name.trim().to_ascii_lowercase().as_str() {
            "host" => req.hosts.push(value),
            "origin" => req.origins.push(value),
            "connection" => req.close = value.eq_ignore_ascii_case("close"),
            _ => {}
        }
    }
    Some(req)
}

/// DNS rebinding: a page on any domain can point that domain at 127.0.0.1, but its
/// requests still name that domain in Host.
fn host_ok(hosts: &[String], port: u16) -> bool {
    let [host] = hosts else { return false };
    let Some((name, p)) = host.rsplit_once(':') else { return false };
    p == port.to_string() && (name == "127.0.0.1" || name.eq_ignore_ascii_case("localhost"))
}

/// Same-origin requests carry no Origin or our own; anything else is a foreign page.
fn origin_ok(origins: &[String], host: &str) -> bool {
    match origins {
        [] => true,
        [origin] => origin.strip_prefix("http://").is_some_and(|o| o.eq_ignore_ascii_case(host)),
        _ => false,
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn route_target(target: &str, token: &str) -> Option<Route> {
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let (given, sub) = path.strip_prefix('/')?.split_once('/')?;
    if !constant_time_eq(given.as_bytes(), token.as_bytes()) {
        return None;
    }
    match sub {
        "room" | "me" => Some(Route::Page),
        "overlay.js" => Some(Route::Js),
        "overlay.css" => Some(Route::Css),
        "events" => parse_view(query).map(Route::Events),
        s => {
            if let Some(slot) = s.strip_prefix("p/") {
                parse_slot(slot).map(|_| Route::Page)
            } else {
                s.strip_prefix("img/").filter(|h| is_hash(h)).map(|h| Route::Img(h.to_string()))
            }
        }
    }
}

/// Every check a request passes before it reaches a route; `None` is a bare 404.
fn gate(req: &Request, port: u16, token: &str) -> Option<Route> {
    if !req.method_ok || !host_ok(&req.hosts, port) || !origin_ok(&req.origins, &req.hosts[0]) {
        return None;
    }
    route_target(&req.target, token)
}

async fn serve_connection(mut stream: TcpStream, port: u16) -> std::io::Result<()> {
    let mut buf: Vec<u8> = Vec::with_capacity(1024);
    let mut first = true;
    loop {
        let limit = if first { first_head_timeout() } else { idle_timeout() };
        first = false;
        let deadline = tokio::time::Instant::now() + limit;
        let Some(head) = read_head(&mut stream, &mut buf, deadline).await? else { return Ok(()) };
        let Some(req) = parse_request(&head) else { return Ok(()) };
        let keep = !req.close && req.method_ok;
        let token = state().running.as_ref().map(|r| r.token.clone());
        let route = token.as_deref().and_then(|t| gate(&req, port, t).map(|r| (r, t.to_string())));
        match route {
            // A request that failed a gate gets its socket back from us at once.
            None => return write_bare(&mut stream, "404 Not Found", false).await,
            Some((Route::Events(view), token)) if !req.head_only => {
                return serve_events(stream, view, token).await;
            }
            Some((route, token)) => respond(&mut stream, &req, route, &token, keep).await?,
        }
        if !keep {
            return Ok(());
        }
    }
}

/// One request head, or `None` when the peer closed, the head overran the cap or
/// the whole head missed its deadline.
async fn read_head(
    stream: &mut TcpStream,
    buf: &mut Vec<u8>,
    deadline: tokio::time::Instant,
) -> std::io::Result<Option<Vec<u8>>> {
    loop {
        if let Some(at) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            if at > MAX_HEAD_BYTES {
                return Ok(None);
            }
            let head = buf[..at].to_vec();
            buf.drain(..at + 4);
            return Ok(Some(head));
        }
        if buf.len() > MAX_HEAD_BYTES {
            return Ok(None);
        }
        let mut chunk = [0u8; 1024];
        let n = match tokio::time::timeout_at(deadline, stream.read(&mut chunk)).await {
            Ok(Ok(0)) | Err(_) => return Ok(None),
            Ok(Ok(n)) => n,
            Ok(Err(e)) => return Err(e),
        };
        buf.extend_from_slice(&chunk[..n]);
    }
}

async fn write_bare(stream: &mut TcpStream, status: &str, keep: bool) -> std::io::Result<()> {
    let conn = if keep { "keep-alive" } else { "close" };
    let head = format!("HTTP/1.1 {status}\r\nContent-Length: 0\r\n{SECURITY_HEADERS}Connection: {conn}\r\n\r\n");
    write_timed(stream, head.as_bytes()).await
}

async fn write_timed(stream: &mut TcpStream, bytes: &[u8]) -> std::io::Result<()> {
    match tokio::time::timeout(WRITE_TIMEOUT, async {
        stream.write_all(bytes).await?;
        stream.flush().await
    })
    .await
    {
        Ok(r) => r,
        Err(_) => Err(std::io::Error::other("overlay write timed out")),
    }
}

fn page_html(token: &str) -> String {
    PAGE_HTML.replace("__TOKEN__", token)
}

/// Content type from the bytes; anything that is not an image we draw is refused.
fn sniff_image(bytes: &[u8]) -> Option<&'static str> {
    if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("image/jpeg")
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some("image/gif")
    } else {
        None
    }
}

/// The image's bytes, only while they still hash to the name the projection gave them.
fn load_image(b: &dyn Backend, hash: &str, src: &ImgSource) -> Option<(Vec<u8>, &'static str)> {
    let bytes = match src {
        ImgSource::Blob(kind) if held_as(b, hash, kind) => b.blob(hash)?,
        ImgSource::Blob(_) => return None,
        ImgSource::Overlay if held_overlay(b, hash) => b.overlay_image(hash)?,
        ImgSource::Overlay => return None,
        ImgSource::Still(master) => b.still_avatar(master)?,
    };
    if sha256_hex(&bytes) != hash {
        return None;
    }
    let ctype = sniff_image(&bytes)?;
    Some((bytes, ctype))
}

async fn respond(stream: &mut TcpStream, req: &Request, route: Route, token: &str, keep: bool) -> std::io::Result<()> {
    let (body, ctype): (Vec<u8>, &str) = match route {
        Route::Page => (page_html(token).into_bytes(), "text/html; charset=utf-8"),
        Route::Js => (PAGE_JS.as_bytes().to_vec(), "text/javascript; charset=utf-8"),
        Route::Css => (PAGE_CSS.as_bytes().to_vec(), "text/css; charset=utf-8"),
        Route::Events(_) => (Vec::new(), "text/event-stream"),
        Route::Img(hash) => {
            let src = {
                let st = state();
                if st.locked { None } else { st.allow.get(&hash).cloned() }
            };
            let Some(src) = src else { return write_bare(stream, "404 Not Found", keep).await };
            let b = backend();
            let loaded = tokio::task::spawn_blocking(move || load_image(&*b, &hash, &src)).await.ok().flatten();
            match loaded {
                Some(found) => found,
                None => return write_bare(stream, "404 Not Found", keep).await,
            }
        }
    };
    let conn = if keep { "keep-alive" } else { "close" };
    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\n{SECURITY_HEADERS}Connection: {conn}\r\n\r\n",
        body.len()
    );
    write_timed(stream, head.as_bytes()).await?;
    if !req.head_only {
        write_timed(stream, &body).await?;
    }
    Ok(())
}

/// Holds one of the stream slots; dropping it (the task ended or was aborted) frees it.
struct StreamSlot;

impl StreamSlot {
    fn take() -> Option<Self> {
        let mut st = state();
        if st.running.is_none() || st.open_streams >= MAX_STREAMS {
            return None;
        }
        st.open_streams += 1;
        emit(NetworkEvent::OverlayStreamsChanged { open: st.open_streams });
        Some(Self)
    }
}

impl Drop for StreamSlot {
    fn drop(&mut self) {
        let mut st = state();
        st.open_streams = st.open_streams.saturating_sub(1);
        emit(NetworkEvent::OverlayStreamsChanged { open: st.open_streams });
    }
}

#[derive(Default)]
struct Sent {
    locked: Option<bool>,
    snap: Option<u64>,
    live: Option<u64>,
}

fn sse(event: &str, data: &str) -> String {
    format!("event: {event}\ndata: {data}\n\n")
}

/// What this stream has not seen yet, or `None` once its token is no longer the
/// server's (the link was reset or the server stopped).
fn pending(sent: &mut Sent, view: &View, token: &str) -> Option<String> {
    let st = state();
    if st.running.as_ref().is_none_or(|r| r.token != token) {
        return None;
    }
    let mut out = String::new();
    if st.locked {
        if sent.locked != Some(true) {
            out.push_str(&sse("locked", "{}"));
            *sent = Sent { locked: Some(true), snap: None, live: None };
        }
        return Some(out);
    }
    if sent.locked != Some(false) || sent.snap != Some(st.snap_gen) {
        let empty = Projected::default();
        let snap = st.snap.as_deref().unwrap_or(&empty);
        out.push_str(&sse("snapshot", &render_snapshot(snap, view, token)));
        sent.snap = Some(st.snap_gen);
        sent.live = None;
    }
    sent.locked = Some(false);
    if let Some(live) = st.live.as_deref().filter(|_| sent.live != Some(st.live_gen)) {
        out.push_str(&sse("live", &render_live(live, st.snap.as_deref(), view)));
        sent.live = Some(st.live_gen);
    }
    Some(out)
}

async fn serve_events(mut stream: TcpStream, view: View, token: String) -> std::io::Result<()> {
    let Some(_slot) = StreamSlot::take() else {
        return write_bare(&mut stream, "503 Service Unavailable", false).await;
    };
    let mut wake_rx = wake_tx().subscribe();
    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n{SECURITY_HEADERS}Connection: keep-alive\r\n\r\nretry: 3000\n\n"
    );
    write_timed(&mut stream, head.as_bytes()).await?;
    let mut sent = Sent::default();
    let every = heartbeat_every();
    let mut beat = tokio::time::interval_at(tokio::time::Instant::now() + every, every);
    let mut scratch = [0u8; 512];
    loop {
        wake_rx.mark_unchanged();
        let Some(out) = pending(&mut sent, &view, &token) else { return Ok(()) };
        if !out.is_empty() {
            write_timed(&mut stream, out.as_bytes()).await?;
        }
        tokio::select! {
            changed = wake_rx.changed() => if changed.is_err() { return Ok(()) },
            _ = beat.tick() => write_timed(&mut stream, b": hb\n\n").await?,
            // An EventSource sends nothing after its request: a read means it left.
            _ = stream.read(&mut scratch) => return Ok(()),
        }
    }
}

#[cfg(test)]
#[path = "overlay_server_tests.rs"]
mod tests;
