//! The relay's fold of an identity's rosters as a second source (design ROSTER-CHECK).
//!
//! A joiner meets co-members as strangers: every roster it holds for one came from
//! other members or from that identity's own devices, and all of them may predate a
//! removal. Before a KeyPackage reaches a foreign device, or a Welcome from one is
//! taken, the relay is asked for the statements it holds (`roster_check`), which every
//! device of the identity shows it; they are verified here and merged under OUR key, so
//! the relay can withhold a removal but never invent one or choose the key.
//!
//! RAM only, one book per node loop, every table bounded by our own asks.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::identity::roster::Roster;
use super::types::HavenMessage;

/// How long an answer, and what it placed, stands.
pub(crate) const FRESH: Duration = Duration::from_secs(60);
/// One ask per master in this long.
pub(crate) const ASK_EVERY: Duration = Duration::from_secs(5);
/// How long a decision or a staged roster waits for the answer.
pub(crate) const WAIT: Duration = Duration::from_secs(5);
/// A held master's roster is checked in the background at most this often.
pub(crate) const BACKGROUND_EVERY: Duration = Duration::from_secs(600);
const MAX_ENTRIES: usize = 1024;
/// Deliverers, and riders, kept with one staged roster.
const MAX_RIDERS: usize = 4;
/// Held KeyPackages per (server, package owner): one asker's forwards never push out
/// another's, nor our own.
const HELD_PER_OWNER: usize = 16;
/// Profile bytes held with staged rosters in all; past it a profile is kept without its
/// blobs, which its hashes pull once it lands.
const RIDER_BYTES: usize = 32 << 20;
/// How often a roster that landed alone looks for a device of its identity to ask by.
const RECHECK_POLL: Duration = Duration::from_secs(1);

/// What the merged copies say about one device of a foreign identity in one server.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Placed {
    /// Counted and removed by nothing: it may be handed a KeyPackage.
    Ask,
    /// Not counted, or no answer: nothing goes to it, nothing from it is taken yet.
    Skip,
    /// The relay's copy holds a recovery key other than ours: one of the two was fooled.
    Conflict,
    /// The merged authority removes it.
    Removed,
}

/// A foreign identity's devices in one server, judged with the relay's copy merged in.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Placement {
    pub counted: BTreeSet<String>,
    pub removed: BTreeSet<String>,
    pub conflict: bool,
}

impl Placement {
    pub(crate) fn of(&self, device: &str) -> Placed {
        if self.conflict {
            Placed::Conflict
        } else if self.removed.contains(device) {
            Placed::Removed
        } else if self.counted.contains(device) {
            Placed::Ask
        } else {
            Placed::Skip
        }
    }

    fn names(&self, device: &str) -> bool {
        self.counted.contains(device) || self.removed.contains(device)
    }
}

/// Whether a decision about one foreign identity may go ahead now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Confirm {
    /// Judged (or no check applies): the per-device gate decides.
    Ready,
    /// Asked and waiting for the answer.
    Wait,
    /// Nothing usable came back: leave this identity out for now.
    Skip,
}

struct Asked {
    master: String,
    room: String,
    device: String,
    at: Instant,
}

/// What rode in with a staged roster, and lands after it.
#[derive(Debug)]
pub(crate) enum Rider {
    /// Nothing (a roster notice).
    Nothing,
    /// A `ProfileUpdate` or `ProfileCard` and its frame stamp, handled again once the
    /// roster lands, so the profile is never fetched twice.
    Profile(Box<(HavenMessage, i64)>),
    /// A join ask's card, kept and stored once the roster places its sender.
    Card(Option<super::join_stash::HeldCard>),
}

impl Rider {
    fn bytes(&self) -> usize {
        match self {
            Rider::Profile(p) => profile_bytes(&p.0),
            Rider::Nothing | Rider::Card(_) => 0,
        }
    }

    fn same_kind(&self, other: &Rider) -> bool {
        std::mem::discriminant(self) == std::mem::discriminant(other)
    }
}

fn profile_bytes(msg: &HavenMessage) -> usize {
    4096 + match msg {
        HavenMessage::ProfileUpdate { avatar_b64, banner_b64, showcase_assets_b64, .. } => {
            avatar_b64.len() + banner_b64.len() + showcase_assets_b64.len()
        }
        HavenMessage::ProfileCard { avatar_b64, .. } => avatar_b64.len(),
        _ => 0,
    }
}

/// `msg` without its blobs: empty means "no change", and the hashes it keeps pull them.
fn light(mut msg: HavenMessage) -> HavenMessage {
    match &mut msg {
        HavenMessage::ProfileUpdate { avatar_b64, banner_b64, showcase_assets_b64, .. } => {
            avatar_b64.clear();
            banner_b64.clear();
            showcase_assets_b64.clear();
        }
        HavenMessage::ProfileCard { avatar_b64, .. } => avatar_b64.clear(),
        _ => {}
    }
    msg
}

/// A first-sight roster held until the relay's copy is merged into it: every roster that
/// counts its own deliverer, merged.
#[derive(Debug)]
pub(crate) struct Staged {
    /// Verified, and merged with every later one.
    pub roster: Roster,
    /// The first deliverer.
    pub sender: String,
    /// Later deliverers, each counted by the roster it brought.
    pub also: Vec<String>,
    /// What rode in, with its deliverer.
    pub riders: Vec<(String, Rider)>,
    servers: Vec<String>,
    at: Instant,
}

impl Staged {
    /// Every deliverer, the first first.
    pub(crate) fn deliverers(&self) -> impl Iterator<Item = &String> {
        std::iter::once(&self.sender).chain(&self.also)
    }

    /// The deliverer the roster lands as: the first that `members` (the landed roster's
    /// own fold) still counts; none when the merge removed every one.
    pub(crate) fn landing_deliverer(&self, members: &BTreeSet<String>) -> Option<String> {
        self.deliverers().find(|d| members.contains(*d)).cloned()
    }
}

/// A KeyPackage frame for a device not judged yet.
struct Held {
    server: String,
    master: String,
    device: String,
    /// The identity the package seats: ours, or a forwarded asker's.
    owner: String,
    msg: HavenMessage,
    at: Instant,
    next: Instant,
}

#[derive(Default)]
struct Book {
    answers: bool,
    local_master: String,
    asks: HashMap<String, Asked>,
    last_ask: HashMap<String, Instant>,
    copies: HashMap<String, (Instant, Option<Roster>)>,
    /// Devices a null answer named: it judges that ask alone.
    nulls: HashMap<String, Instant>,
    placements: HashMap<(String, String), (Instant, Placement)>,
    staged: HashMap<String, Staged>,
    /// (server, master, devices, since) a gate could not decide and wants asked.
    wants: Vec<(String, String, Vec<String>, Instant)>,
    /// (device, master): a Welcome sender the merged authority removes, owed the roster.
    notices: Vec<(String, String)>,
    background: HashMap<String, Instant>,
    /// Masters whose roster landed alone: asked once a device of theirs shows.
    rechecks: HashMap<String, (Vec<String>, Instant)>,
    recheck_at: Option<Instant>,
    held: Vec<Held>,
    /// Profile frames whose roster landed: (sender, frame, stamp), handled again.
    replays: Vec<(String, HavenMessage, i64)>,
    /// Masters a decision wanted asked about before any device of theirs showed.
    unasked: HashMap<String, Instant>,
    alerted: HashSet<String>,
    /// An answer or placement came in since the last pass.
    poke: bool,
    /// When a staged roster or a held frame is next due.
    due: Option<Instant>,
}

fn trim<K: Clone + Eq + std::hash::Hash, V>(map: &mut HashMap<K, V>, at: impl Fn(&V) -> Instant) {
    while map.len() > MAX_ENTRIES {
        let Some(oldest) = map.iter().min_by_key(|(_, v)| at(v)).map(|(k, _)| k.clone()) else { break };
        map.remove(&oldest);
    }
}

fn earliest(due: Option<Instant>, at: Instant) -> Option<Instant> {
    Some(due.map_or(at, |d| d.min(at)))
}

static BOOKS: Mutex<Option<HashMap<String, Book>>> = Mutex::new(None);

/// One book per node loop: harness nodes share the process.
fn loop_key() -> String {
    #[cfg(test)]
    {
        super::lock_keeper::loop_device_id().unwrap_or_default()
    }
    #[cfg(not(test))]
    {
        String::new()
    }
}

fn with<R>(f: impl FnOnce(&mut Book) -> R) -> R {
    let mut guard = BOOKS.lock().unwrap_or_else(|p| p.into_inner());
    let books = guard.get_or_insert_with(HashMap::new);
    f(books.entry(loop_key()).or_default())
}

/// A node loop starts with an empty book: nothing a previous loop in this process asked,
/// judged or held carries over.
pub(crate) fn reset_for_loop() {
    with(|b| *b = Book::default());
}

/// What the relay said on login or resume, and whose node this is.
pub(crate) fn set_relay(answers: bool, local_master: &str) {
    with(|b| {
        b.answers = answers;
        b.local_master = local_master.to_string();
        if !answers {
            b.asks.clear();
        }
    });
}

fn foreign(b: &Book, master: &str) -> bool {
    !b.local_master.is_empty() && !super::resolver::same_identity(master, &b.local_master)
}

/// Whether `master` is another identity than ours, on a relay that answers checks.
pub(crate) fn applies(master: &str) -> bool {
    with(|b| b.answers && foreign(b, master))
}

fn fresh_null(b: &Book, device: &str, now: Instant) -> bool {
    b.nulls.get(device).is_some_and(|t| now.saturating_duration_since(*t) < FRESH)
}

fn placement_for(b: &Book, server: &str, device: &str, now: Instant) -> Option<Placed> {
    let master = super::resolver::resolve(device);
    let fresh = |at: &Instant| now.saturating_duration_since(*at) < FRESH;
    if let Some((at, p)) = b.placements.get(&(server.to_string(), master))
        && fresh(at)
    {
        return Some(p.of(device));
    }
    // A device only the server's view places: whichever judged master names it.
    b.placements
        .iter()
        .filter(|((s, _), (at, p))| s == server && fresh(at) && p.names(device))
        .map(|(_, (_, p))| p.of(device))
        .min_by_key(|p| match p {
            Placed::Removed => 0,
            Placed::Conflict => 1,
            Placed::Skip => 2,
            Placed::Ask => 3,
        })
}

/// The fresh judgement of `device` (of certified `master`) in `server`, if any.
pub(crate) fn placed(server: &str, master: &str, device: &str) -> Option<Placed> {
    let now = Instant::now();
    with(|b| {
        let (at, p) = b.placements.get(&(server.to_string(), master.to_string()))?;
        (now.saturating_duration_since(*at) < FRESH).then(|| p.of(device))
    })
}

/// Whether a KeyPackage for `server` may go to `device`: always on a relay without the
/// check and for our own identity; otherwise only to a device the relay's copy, merged
/// with ours, counts and removes nothing of.
pub(crate) fn allows(server: &str, device: &str) -> bool {
    let now = Instant::now();
    with(|b| {
        if !b.answers || !foreign(b, &super::resolver::resolve(device)) {
            return true;
        }
        placement_for(b, server, device, now) == Some(Placed::Ask)
    })
}

/// What the KeyPackage gate says of one device.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Gate {
    /// No check applies, or the merged copies count it: send.
    Pass,
    /// Not judged yet: hold the frame for the answer.
    Hold,
    /// Judged and not counted, removed or in conflict, or a null answer named it: not now.
    Refuse,
}

/// [`allows`], telling a device not judged yet from one judged out.
pub(crate) fn gate(server: &str, device: &str) -> Gate {
    let now = Instant::now();
    with(|b| {
        if !b.answers || !foreign(b, &super::resolver::resolve(device)) {
            return Gate::Pass;
        }
        match placement_for(b, server, device, now) {
            Some(Placed::Ask) => Gate::Pass,
            Some(_) => Gate::Refuse,
            None if fresh_null(b, device, now) => Gate::Refuse,
            None => Gate::Hold,
        }
    })
}

/// The identity a KeyPackage frame seats: ours for our own, the forwarded asker's for a
/// forward ("" = ours, "?" = a package that names nobody).
fn package_owner(msg: &HavenMessage) -> String {
    use base64::Engine as _;
    match msg {
        HavenMessage::MlsKeyPackageForward { key_package, .. } => base64::engine::general_purpose::STANDARD
            .decode(key_package)
            .ok()
            .and_then(|bytes| crate::crypto::MlsManager::key_package_identity(&bytes).ok())
            .and_then(|leaf| leaf.bound().map(|l| l.master.clone()))
            .unwrap_or_else(|| "?".to_string()),
        _ => String::new(),
    }
}

/// Hold a KeyPackage frame for `device` (of `master`) until the relay's copy judges it,
/// at most [`FRESH`]; [`HELD_PER_OWNER`] per (server, package owner), and a full book
/// gives way from its heaviest owner.
pub(crate) fn hold(server: &str, master: &str, device: &str, msg: HavenMessage) {
    let owner = package_owner(&msg);
    let now = Instant::now();
    with(|b| {
        let mine = |h: &Held| h.server == server && h.owner == owner;
        if b.held.iter().filter(|h| mine(h)).count() >= HELD_PER_OWNER
            && let Some(i) = b.held.iter().position(mine)
        {
            b.held.remove(i);
        }
        b.held.push(Held {
            server: server.to_string(),
            master: master.to_string(),
            device: device.to_string(),
            owner,
            msg,
            at: now,
            next: now + ASK_EVERY,
        });
        if b.held.len() > MAX_ENTRIES {
            let mut weight: HashMap<(&str, &str), usize> = HashMap::new();
            for h in &b.held {
                *weight.entry((h.server.as_str(), h.owner.as_str())).or_default() += 1;
            }
            let heaviest = weight.into_iter().max_by_key(|(_, n)| *n).map(|((s, o), _)| (s.to_string(), o.to_string()));
            if let Some((s, o)) = heaviest
                && let Some(i) = b.held.iter().position(|h| h.server == s && h.owner == o)
            {
                b.held.remove(i);
            }
        }
        b.due = earliest(b.due, now + ASK_EVERY);
    });
}

fn release_due(b: &Book, now: Instant) -> bool {
    b.poke || b.due.is_some_and(|t| now >= t)
}

/// Held frames the relay's copy counts the device of, to send now. A frame waits while
/// its device is not judged, not counted or in conflict, asked about again every
/// [`ASK_EVERY`], and is dropped only when the merged copies remove its device or after
/// [`FRESH`]. Runs only when an answer came in or something fell due.
pub(crate) fn take_released() -> Vec<(String, HavenMessage)> {
    let now = Instant::now();
    with(|b| {
        if b.held.is_empty() || !release_due(b, now) {
            return Vec::new();
        }
        let mut out = Vec::new();
        for mut h in std::mem::take(&mut b.held) {
            let placed = if !b.answers || !foreign(b, &super::resolver::resolve(&h.device)) {
                Some(Placed::Ask)
            } else {
                placement_for(b, &h.server, &h.device, now)
            };
            match placed {
                Some(Placed::Ask) => out.push((h.device, h.msg)),
                Some(Placed::Removed) => {
                    hollow_log!("[HOLLOW-SECURITY] A KeyPackage for {} never went to {}: the relay's copy of {}'s roster removes it", h.server, h.device, h.master);
                }
                _ if now.saturating_duration_since(h.at) >= FRESH => {
                    hollow_log!("[HOLLOW-SECURITY] A KeyPackage for {} never went to {}: no copy of {}'s roster counted it in time", h.server, h.device, h.master);
                }
                _ => {
                    if now >= h.next {
                        want_in(b, &h.server, &h.master, vec![h.device.clone()], now);
                        h.next = now + ASK_EVERY;
                    }
                    b.held.push(h);
                }
            }
        }
        out
    })
}

fn want_in(b: &mut Book, server: &str, master: &str, devices: Vec<String>, now: Instant) {
    if !b.answers || !foreign(b, master) {
        return;
    }
    if b.wants.len() < MAX_ENTRIES && !b.wants.iter().any(|(s, m, ..)| s == server && m == master) {
        b.wants.push((server.to_string(), master.to_string(), devices, now));
    }
}

/// A gate could not decide `master` in `server`: ask about it at the next drain.
pub(crate) fn want(server: &str, master: &str, devices: Vec<String>) {
    let now = Instant::now();
    with(|b| want_in(b, server, master, devices, now));
}

/// A random 16-hex ask id; also the jitter source for the roster re-show timer.
pub(crate) fn random_u64() -> u64 {
    let mut b = [0u8; 8];
    let _ = getrandom::fill(&mut b);
    u64::from_le_bytes(b)
}

fn nonce() -> String {
    format!("{:016x}", random_u64())
}

/// Send one ask for `master`, naming a device of it the server room shows us that no
/// null answer named lately. `devices` come from a roster of `master` (our placement, or
/// a staged roster that counts them), as does [`super::resolver::devices_for`].
fn send_ask(
    b: &mut Book,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    server: &str,
    master: &str,
    devices: &[String],
    now: Instant,
) -> bool {
    let room = server.split('#').next().unwrap_or(server);
    let Some(shown) = ws_room_peers.get(room) else { return false };
    let mut named: Vec<String> = devices.to_vec();
    named.extend(super::resolver::devices_for(master));
    let Some(device) = named.into_iter().find(|d| shown.contains(d) && !fresh_null(b, d, now)) else { return false };
    let n = nonce();
    b.asks.insert(n.clone(), Asked { master: master.to_string(), room: room.to_string(), device: device.clone(), at: now });
    trim(&mut b.asks, |a| a.at);
    b.last_ask.insert(master.to_string(), now);
    trim(&mut b.last_ask, |t| *t);
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::RosterCheck {
        room_code: room.to_string(),
        master: master.to_string(),
        device,
        n,
    });
    true
}

fn outstanding(b: &Book, master: &str) -> Option<Instant> {
    b.asks.values().filter(|a| a.master == master).map(|a| a.at).max()
}

/// Before a decision about `master` in `server` (a walk's target): ready when judged or
/// when no check applies, else ask once and wait up to [`WAIT`]. A null answer about
/// every device named leaves the identity out for now.
pub(crate) fn confirm(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
    server: &str,
    master: &str,
    devices: &[String],
) -> Confirm {
    let now = Instant::now();
    with(|b| {
        if !b.answers || !foreign(b, master) {
            return Confirm::Ready;
        }
        let judged = b.placements.get(&(server.to_string(), master.to_string()));
        if judged.is_some_and(|(at, _)| now.saturating_duration_since(*at) < FRESH)
            || devices.iter().any(|d| placement_for(b, server, d, now).is_some())
        {
            return Confirm::Ready;
        }
        if let Some(at) = outstanding(b, master) {
            return if now.saturating_duration_since(at) < WAIT { Confirm::Wait } else { Confirm::Skip };
        }
        if !devices.is_empty() && devices.iter().all(|d| fresh_null(b, d, now)) {
            return Confirm::Skip;
        }
        if b.last_ask.get(master).is_some_and(|t| now.saturating_duration_since(*t) < ASK_EVERY) {
            return Confirm::Wait;
        }
        if send_ask(b, ws_cmd_tx, ws_room_peers, server, master, devices, now) {
            b.unasked.remove(master);
            return Confirm::Wait;
        }
        // No device of it shows in the server room yet (presence lags a join): wait a
        // while, then leave it out of this pass.
        let since = *b.unasked.entry(master.to_string()).or_insert(now);
        trim(&mut b.unasked, |t| *t);
        if now.saturating_duration_since(since) < WAIT { Confirm::Wait } else { Confirm::Skip }
    })
}

/// Send the asks gates wanted, and the re-checks of rosters that landed alone. Cheap
/// when there are none.
pub(crate) fn drain(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, HashSet<String>>,
) {
    let now = Instant::now();
    with(|b| {
        // A want no shown device of its master can carry yet (presence lags a join) is
        // kept for the next drain, for up to [`WAIT`]: dropped, a staged roster would land
        // alone with nobody asked.
        let mut keep = Vec::new();
        for (server, master, devices, since) in std::mem::take(&mut b.wants) {
            let answered = b.copies.get(&master).is_some_and(|(at, _)| now.saturating_duration_since(*at) < FRESH);
            if answered || outstanding(b, &master).is_some() {
                continue;
            }
            let recent = b.last_ask.get(&master).is_some_and(|t| now.saturating_duration_since(*t) < ASK_EVERY);
            let sent = !recent && send_ask(b, ws_cmd_tx, ws_room_peers, &server, &master, &devices, now);
            if !sent && now.saturating_duration_since(since) < WAIT {
                keep.push((server, master, devices, since));
            }
        }
        b.wants.extend(keep);
        if b.recheck_at.is_some_and(|t| now >= t) {
            let mut left = HashMap::new();
            for (master, (servers, since)) in std::mem::take(&mut b.rechecks) {
                let answered = b.copies.get(&master).is_some_and(|(at, c)| c.is_some() && now.saturating_duration_since(*at) < FRESH);
                if answered || now.saturating_duration_since(since) >= BACKGROUND_EVERY {
                    continue;
                }
                let recent = b.last_ask.get(&master).is_some_and(|t| now.saturating_duration_since(*t) < ASK_EVERY);
                let sent = !recent
                    && outstanding(b, &master).is_none_or(|a| now.saturating_duration_since(a) >= WAIT)
                    && servers.iter().any(|s| send_ask(b, ws_cmd_tx, ws_room_peers, s, &master, &[], now));
                if !sent {
                    left.insert(master, (servers, since));
                }
            }
            b.rechecks = left;
            b.recheck_at = (!b.rechecks.is_empty()).then(|| now + RECHECK_POLL);
        }
        b.asks.retain(|_, a| now.saturating_duration_since(a.at) < FRESH);
    });
}

/// The relay's answer, kept only for an ask of ours with that nonce, master, room and
/// device. `Some(copy)`: the verified statements, or `None` for a null answer, which
/// judges that ask alone: the device it named, never the identity's other asks.
pub(crate) fn take_answer(
    room: &str,
    master: &str,
    device: &str,
    n: &str,
    roster: Option<serde_json::Value>,
) -> Option<Option<Roster>> {
    let now = Instant::now();
    with(|b| {
        let asked = b.asks.get(n)?;
        if asked.master != master || asked.room != room || asked.device != device {
            return None;
        }
        b.asks.remove(n);
        let copy = roster.and_then(|v| serde_json::from_value::<Roster>(v).ok()).and_then(|r| {
            (r.master == master && r.within_caps()).then(|| r.verified(super::roster_book::now_ms()))
        });
        if copy.is_some() {
            // One copy serves every ask for the master.
            b.asks.retain(|_, a| a.master != master);
            b.copies.insert(master.to_string(), (now, copy.clone()));
            trim(&mut b.copies, |(at, _)| *at);
            b.nulls.remove(device);
        } else {
            b.nulls.insert(device.to_string(), now);
            trim(&mut b.nulls, |t| *t);
        }
        b.poke = true;
        Some(copy)
    })
}

/// Record what the relay's copy, merged with ours, says of `master` in `server`.
pub(crate) fn set_placement(server: &str, master: &str, placement: Placement) {
    with(|b| {
        if placement.conflict && b.alerted.insert(master.to_string()) {
            hollow_log!(
                "[HOLLOW-SECURITY] The relay holds another recovery key for {master} than we do: none of its devices is asked or taken until that settles"
            );
        }
        b.placements.insert((server.to_string(), master.to_string()), (Instant::now(), placement));
        trim(&mut b.placements, |(at, _)| *at);
        b.poke = true;
    });
}

fn add_rider(b: &Book, riders: &mut Vec<(String, Rider)>, sender: &str, rider: Rider) {
    if matches!(rider, Rider::Nothing) {
        return;
    }
    riders.retain(|(s, r)| !(s == sender && r.same_kind(&rider)));
    let held: usize = b.staged.values().flat_map(|s| &s.riders).map(|(_, r)| r.bytes()).sum::<usize>()
        + riders.iter().map(|(_, r)| r.bytes()).sum::<usize>()
        + b.replays.iter().map(|(_, m, _)| profile_bytes(m)).sum::<usize>();
    let rider = match rider {
        Rider::Profile(p) if held + profile_bytes(&p.0) > RIDER_BYTES => Rider::Profile(Box::new((light(p.0), p.1))),
        other => other,
    };
    riders.push((sender.to_string(), rider));
    if riders.len() > MAX_RIDERS {
        riders.remove(0);
    }
}

/// Hold a first-sight roster for the relay's copy and ask about it in `servers`. Only a
/// roster whose own verified fold counts its deliverer is held (the rule its landing
/// applies), and a later one for the same master merges into it; any other comes back
/// with its rider.
#[must_use]
pub(crate) fn stage(roster: Roster, sender: &str, rider: Rider, servers: &[String]) -> Option<Rider> {
    let now_ms = super::roster_book::now_ms();
    let roster = roster.verified(now_ms);
    let counted = roster.fold(|_| None, now_ms).members;
    if !counted.contains(sender) {
        hollow_log!("[HOLLOW-SECURITY] Did not hold a first roster for {} from {sender}: it does not count its deliverer", roster.master);
        return Some(rider);
    }
    let master = roster.master.clone();
    hollow_log!("[HOLLOW-ROSTER] Holding a first roster for {master} from {sender} until the relay's copy is merged in");
    let now = Instant::now();
    with(|b| {
        let mut entry = b.staged.remove(&master).unwrap_or_else(|| Staged {
            roster: Roster::new(&master),
            sender: sender.to_string(),
            also: Vec::new(),
            riders: Vec::new(),
            servers: Vec::new(),
            at: now,
        });
        entry.roster = entry.roster.merged(&roster);
        if entry.deliverers().all(|d| d != sender) && entry.also.len() < MAX_RIDERS {
            entry.also.push(sender.to_string());
        }
        for server in servers {
            if !entry.servers.contains(server) {
                entry.servers.push(server.clone());
            }
        }
        let mut riders = std::mem::take(&mut entry.riders);
        add_rider(b, &mut riders, sender, rider);
        entry.riders = riders;
        b.staged.insert(master.clone(), entry);
        trim(&mut b.staged, |s| s.at);
        let mut devices = vec![sender.to_string()];
        devices.extend(counted.into_iter().filter(|d| d != sender));
        for server in servers {
            if b.wants.len() < MAX_ENTRIES && !b.wants.iter().any(|(s, m, ..)| s == server && *m == master) {
                b.wants.push((server.clone(), master.clone(), devices.clone(), now));
            }
        }
        b.due = earliest(b.due, now + WAIT);
        // A fresh copy is already here: it lands at the next pass.
        b.poke |= b.copies.get(&master).is_some_and(|(at, c)| c.is_some() && now.saturating_duration_since(*at) < FRESH);
    });
    None
}

/// Whether a first-sight roster for `master` is held for the relay's copy.
#[cfg(test)]
pub(crate) fn is_staged(master: &str) -> bool {
    with(|b| b.staged.contains_key(master))
}

#[cfg(test)]
pub(crate) fn take_staged(master: &str) -> Option<Staged> {
    with(|b| b.staged.remove(master))
}

/// A roster about to land: a held master's background check waits its full span, and
/// one landing without the relay's copy is asked about once a device of it shows.
fn landing(b: &mut Book, staged: &Staged, alone: bool, now: Instant) {
    b.background.insert(staged.roster.master.clone(), now);
    trim(&mut b.background, |t| *t);
    if alone && b.answers {
        b.rechecks.insert(staged.roster.master.clone(), (staged.servers.clone(), now));
        trim(&mut b.rechecks, |(_, t)| *t);
        b.recheck_at = earliest(b.recheck_at, now);
    }
}

/// The staged roster an answer about `master` lands: any held copy lands it; a null
/// answer only one that asked by naming one of its deliverers.
pub(crate) fn take_staged_for_answer(master: &str, device: &str, copy_held: bool) -> Option<Staged> {
    let now = Instant::now();
    with(|b| {
        let ours = b.staged.get(master).is_some_and(|s| copy_held || s.deliverers().any(|d| d == device));
        let staged = if ours { b.staged.remove(master) } else { None }?;
        landing(b, &staged, !copy_held, now);
        Some(staged)
    })
}

/// Staged rosters ready to land: with a fresh copy for their master (an ask spaced by
/// [`ASK_EVERY`] serves a roster staged again meanwhile), or alone once [`WAIT`] passed
/// with none. Runs only when an answer came in or something fell due.
pub(crate) fn take_ready_staged() -> Vec<(Staged, Option<Option<Roster>>)> {
    let now = Instant::now();
    with(|b| {
        if b.staged.is_empty() || !release_due(b, now) {
            return Vec::new();
        }
        let ready: Vec<(String, Option<Option<Roster>>)> = b
            .staged
            .iter()
            .filter_map(|(m, s)| match b.copies.get(m) {
                Some((at, Some(copy))) if now.saturating_duration_since(*at) < FRESH => Some((m.clone(), Some(Some(copy.clone())))),
                _ if now.saturating_duration_since(s.at) >= WAIT && outstanding(b, m).is_none_or(|a| now.saturating_duration_since(a) >= WAIT) => {
                    Some((m.clone(), None))
                }
                _ => None,
            })
            .collect();
        let mut out = Vec::new();
        for (m, copy) in ready {
            if let Some(s) = b.staged.remove(&m) {
                landing(b, &s, copy.is_none(), now);
                out.push((s, copy));
            }
        }
        out
    })
}

/// After a pass over staged rosters and held frames: the next time either falls due.
pub(crate) fn settle() {
    let now = Instant::now();
    with(|b| {
        b.poke = false;
        let staged = b.staged.iter().map(|(m, s)| s.at.max(outstanding(b, m).unwrap_or(s.at)) + WAIT);
        let held = b.held.iter().map(|h| h.next.min(h.at + FRESH));
        let next = staged.chain(held).min();
        b.due = next.map(|t| t.max(now + Duration::from_millis(50)));
    });
}

/// A landed roster's profile frame, to be handled again by its own arm.
pub(crate) fn replay(sender: &str, msg: HavenMessage, frame_ts: i64) {
    with(|b| {
        if b.replays.len() < MAX_ENTRIES {
            b.replays.push((sender.to_string(), msg, frame_ts));
        }
    });
}

/// What rode in with a staged roster that just landed: profile frames are queued to be
/// handled again only when the roster is now `held` and `members` counts their deliverer
/// (a roster the book does not keep stays a first sight: replayed, its profile would be
/// staged, landed and replayed again on every loop turn); join-ask cards come back to land.
pub(crate) fn after_landing(
    master: &str,
    riders: Vec<(String, Rider)>,
    held: bool,
    members: &BTreeSet<String>,
) -> Vec<(String, Option<super::join_stash::HeldCard>)> {
    let mut cards = Vec::new();
    for (from, rider) in riders {
        match rider {
            Rider::Profile(p) if held && members.contains(&from) => replay(&from, p.0, p.1),
            Rider::Profile(_) => {
                hollow_log!("[HOLLOW-ROSTER] Dropped a profile from {from} held with {master}'s first roster: the roster did not land with it");
            }
            Rider::Card(card) => cards.push((from, card)),
            Rider::Nothing => {}
        }
    }
    cards
}

/// The profile frames to handle again now.
pub(crate) fn take_replays() -> Vec<(String, HavenMessage, i64)> {
    with(|b| std::mem::take(&mut b.replays))
}

/// A held foreign master's roster is checked again in the background at most once per
/// [`BACKGROUND_EVERY`].
pub(crate) fn background(master: &str, servers: &[String]) {
    let now = Instant::now();
    with(|b| {
        if !b.answers || !foreign(b, master) {
            return;
        }
        if b.background.get(master).is_some_and(|t| now.saturating_duration_since(*t) < BACKGROUND_EVERY) {
            return;
        }
        b.background.insert(master.to_string(), now);
        trim(&mut b.background, |t| *t);
        if let Some(server) = servers.first()
            && b.wants.len() < MAX_ENTRIES
        {
            b.wants.push((server.clone(), master.to_string(), Vec::new(), now));
        }
    });
}

/// A Welcome sender the merged authority removes is owed the roster that shows it.
pub(crate) fn note_refused_sender(device: &str, master: &str) {
    with(|b| {
        if b.notices.len() < MAX_ENTRIES {
            b.notices.push((device.to_string(), master.to_string()));
        }
    });
}

/// The notices owed, each with the relay's copy that shows the removal.
pub(crate) fn take_notices() -> Vec<(String, Roster)> {
    with(|b| {
        let owed = std::mem::take(&mut b.notices);
        owed.into_iter()
            .filter_map(|(device, master)| b.copies.get(&master).and_then(|(_, c)| c.clone()).map(|r| (device, r)))
            .collect()
    })
}

/// Whether the loop has anything to drain, land or release now. Staged rosters and held
/// frames count only once an answer came in or one fell due.
pub(crate) fn has_work() -> bool {
    let now = Instant::now();
    with(|b| {
        !b.wants.is_empty()
            || !b.notices.is_empty()
            || !b.replays.is_empty()
            || b.recheck_at.is_some_and(|t| now >= t)
            || ((!b.staged.is_empty() || !b.held.is_empty()) && release_due(b, now))
    })
}

#[cfg(test)]
pub(crate) fn clear_for_test() {
    with(|b| *b = Book::default());
}

/// As if `master`'s last ask was [`ASK_EVERY`] ago.
#[cfg(test)]
fn age_last_ask_for_test(master: &str) {
    with(|b| {
        if let Some(t) = b.last_ask.get_mut(master) {
            *t -= ASK_EVERY;
        }
    });
}

// -- The relay's rule, mirrored for the harness relay (relay-uws/src/roster_check.h) --

/// Everything the relay's answer depends on.
#[cfg(test)]
#[derive(Clone, Debug, Default, serde::Deserialize)]
pub(crate) struct RelayFacts {
    pub full: bool,
    pub master: String,
    pub device: String,
    #[serde(rename = "n")]
    pub nonce: String,
    pub room: String,
    pub asker_in_room: bool,
    pub locked: bool,
    pub newest_door: bool,
    pub device_listed: bool,
    pub placed: bool,
}

#[cfg(test)]
fn peer_id_shape(id: &str) -> bool {
    (40..=64).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric() && !matches!(b, b'0' | b'O' | b'I' | b'l'))
}

#[cfg(test)]
fn nonce_shape(n: &str) -> bool {
    !n.is_empty() && n.len() <= 32 && n.bytes().all(|b| b.is_ascii_digit() || b.is_ascii_lowercase())
}

#[cfg(test)]
/// Rooms named like a server: 32 or 40 lowercase hex.
pub(crate) fn room_shape(room: &str) -> bool {
    matches!(room.len(), 32 | 40) && room.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[cfg(test)]
/// Whether the relay answers with the statements it holds (`roster_check::answers`).
pub(crate) fn relay_answers_with(f: &RelayFacts) -> bool {
    f.full
        && peer_id_shape(&f.master)
        && peer_id_shape(&f.device)
        && nonce_shape(&f.nonce)
        && room_shape(&f.room)
        && f.asker_in_room
        && (!f.locked || f.newest_door)
        && f.device_listed
        && f.placed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_relay_rule_matches_the_shared_vectors() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../relay-uws/test/roster_check_vectors.json");
        let v: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).expect("vectors")).expect("parse");
        let cases = v["cases"].as_array().expect("cases");
        assert!(!cases.is_empty());
        for c in cases {
            let facts: RelayFacts = serde_json::from_value(c.clone()).expect("facts");
            assert_eq!(relay_answers_with(&facts), c["answers"].as_bool().unwrap(), "{}", c["name"]);
        }
    }

    fn rooms(room: &str, devices: &[&str]) -> HashMap<String, HashSet<String>> {
        [(room.to_string(), devices.iter().map(|d| d.to_string()).collect())].into()
    }

    const ROOM: &str = "0123456789abcdef0123456789abcdef";

    fn sent(rx: &mut tokio::sync::mpsc::UnboundedReceiver<super::super::ws_client::WsCommand>) -> Vec<(String, String, String, String)> {
        let mut out = Vec::new();
        while let Ok(super::super::ws_client::WsCommand::RosterCheck { room_code, master, device, n }) = rx.try_recv() {
            out.push((room_code, master, device, n));
        }
        out
    }

    #[test]
    fn an_answer_counts_only_for_an_ask_of_ours() {
        let (_, m, _) = crate::crdt::testkeys::keys(61);
        let (_, d, _) = crate::crdt::testkeys::keys(62);
        let (_, us, _) = crate::crdt::testkeys::keys(63);
        clear_for_test();
        set_relay(true, &us);
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        assert_eq!(confirm(&tx, &rooms(ROOM, &[&d]), ROOM, &m, std::slice::from_ref(&d)), Confirm::Wait);
        let asks = sent(&mut rx);
        assert_eq!(asks.len(), 1, "one ask");
        let (room, master, device, n) = asks[0].clone();
        assert_eq!((room.as_str(), master.as_str(), device.as_str()), (ROOM, m.as_str(), d.as_str()));
        assert_eq!(confirm(&tx, &rooms(ROOM, &[&d]), ROOM, &m, std::slice::from_ref(&d)), Confirm::Wait, "waits, asks no more");
        assert!(sent(&mut rx).is_empty());
        assert!(take_answer(ROOM, &m, &d, "0000000000000000", None).is_none(), "an unknown nonce is dropped");
        assert!(take_answer(ROOM, &d, &d, &n, None).is_none(), "another master is dropped");
        assert!(take_answer("ffffffffffffffffffffffffffffffff", &m, &d, &n, None).is_none(), "another room is dropped");
        let other = serde_json::to_value(Roster::new(&d)).unwrap();
        assert_eq!(take_answer(ROOM, &m, &d, &n, Some(other)), Some(None), "a copy for another master holds nothing");
        assert!(take_answer(ROOM, &m, &d, &n, None).is_none(), "an ask is answered once");
    }

    #[test]
    fn the_gate_passes_only_what_a_fresh_placement_asks() {
        let (_, m, _) = crate::crdt::testkeys::keys(64);
        let (_, d, _) = crate::crdt::testkeys::keys(65);
        let (_, gone, _) = crate::crdt::testkeys::keys(66);
        let (_, us, _) = crate::crdt::testkeys::keys(67);
        clear_for_test();
        assert!(allows(ROOM, &d), "a relay that never said it checks lets everything through");
        set_relay(true, &us);
        assert!(!allows(ROOM, &d), "unjudged: nothing goes");
        assert_eq!(gate(ROOM, &d), Gate::Hold, "unjudged: held for the answer");
        assert!(allows(ROOM, &us), "our own identity is never checked");
        assert_eq!(gate(ROOM, &us), Gate::Pass, "nor held");
        set_placement(ROOM, &m, Placement { counted: [d.clone()].into(), removed: [gone.clone()].into(), conflict: false });
        assert!(allows(ROOM, &d), "a device only the view places, counted");
        assert!(!allows(ROOM, &gone), "removed");
        assert_eq!(gate(ROOM, &gone), Gate::Refuse, "and refused, never held");
        assert!(!allows("ffffffffffffffffffffffffffffffff", &d), "judged for one server only");
        set_placement(ROOM, &m, Placement { counted: [d.clone()].into(), removed: Default::default(), conflict: true });
        assert!(!allows(ROOM, &d), "a key conflict lets nothing through");
        set_relay(false, &us);
        assert!(allows(ROOM, &gone), "a relay without the check: as before");
    }

    /// `(master, device, a legacy roster of the master counting the device)`.
    fn counting(master: u8, device: u8) -> (String, String, Roster) {
        let (mk, m, _) = crate::crdt::testkeys::keys(master);
        let (dk, d, _) = crate::crdt::testkeys::keys(device);
        (m, d, Roster::legacy_for_test(&mk, &[&dk]))
    }

    #[test]
    fn a_staged_roster_lands_with_a_fresh_answer_or_alone_after_the_wait() {
        let (m, d, roster) = counting(68, 69);
        let (_, us, _) = crate::crdt::testkeys::keys(70);
        clear_for_test();
        set_relay(true, &us);
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        assert!(stage(roster.clone(), &d, Rider::Nothing, &[ROOM.to_string()]).is_none(), "held");
        assert!(is_staged(&m));
        assert!(take_ready_staged().is_empty(), "waits for its answer");
        drain(&tx, &rooms(ROOM, &[&d]));
        let asks = sent(&mut rx);
        assert_eq!(asks.len(), 1, "the drain asks about it");
        let copy = serde_json::to_value(&roster).unwrap();
        assert!(take_answer(ROOM, &m, &d, &asks[0].3, Some(copy)).is_some_and(|c| c.is_some()));
        assert!(stage(roster, &d, Rider::Nothing, &[ROOM.to_string()]).is_none(), "held");
        let ready = take_ready_staged();
        assert_eq!(ready.len(), 1, "staged again within the answer's freshness: it lands at once");
        assert!(matches!(ready[0].1, Some(Some(_))), "with the copy we hold");
    }
    /// A staged roster whose deliverer the room does not show yet (presence lags a join)
    /// is asked about once it shows, not left to land alone.
    #[test]
    fn a_want_no_shown_device_can_carry_yet_is_asked_once_one_shows() {
        let (m, d, roster) = counting(71, 72);
        let (_, us, _) = crate::crdt::testkeys::keys(73);
        clear_for_test();
        set_relay(true, &us);
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        assert!(stage(roster, &d, Rider::Nothing, &[ROOM.to_string()]).is_none(), "held");
        drain(&tx, &rooms(ROOM, &[]));
        assert!(sent(&mut rx).is_empty(), "nobody to name yet");
        drain(&tx, &rooms(ROOM, &[&d]));
        let asks = sent(&mut rx);
        assert_eq!(asks.len(), 1, "asked once the deliverer shows");
        assert_eq!(asks[0].1, m);
    }

    #[test]
    fn a_placement_reads_removal_before_count_and_conflict_before_both() {
        let p = Placement {
            counted: ["a".to_string(), "b".to_string()].into(),
            removed: ["b".to_string()].into(),
            conflict: false,
        };
        assert_eq!(p.of("a"), Placed::Ask);
        assert_eq!(p.of("b"), Placed::Removed, "a removal wins over a count");
        assert_eq!(p.of("c"), Placed::Skip);
        let c = Placement { conflict: true, ..p };
        assert_eq!(c.of("a"), Placed::Conflict);
        assert_eq!(c.of("b"), Placed::Conflict, "a key conflict never refuses");
    }

    /// rv-rostercheck (reviewer): a staged roster that does not count its deliverer
    /// makes the drain name that deliverer to the relay, whose fold of the master never
    /// places it: the null answer then judges the master for every server for 60 s and
    /// wipes every other ask about it.
    #[test]
    fn rv_an_ask_never_names_a_deliverer_the_staged_roster_does_not_count() {
        let (_, m, _) = crate::crdt::testkeys::keys(76);
        let (_, c, _) = crate::crdt::testkeys::keys(77);
        let (_, us, _) = crate::crdt::testkeys::keys(78);
        clear_for_test();
        set_relay(true, &us);
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let _ = stage(Roster::new(&m), &c, Rider::Nothing, &[ROOM.to_string()]);
        drain(&tx, &rooms(ROOM, &[&c]));
        let asks = sent(&mut rx);
        clear_for_test();
        assert!(asks.iter().all(|(_, _, dev, _)| *dev != c), "the ask named {c}, which no roster of {m} counts");
    }

    #[cfg(test)]
    fn held_len() -> usize {
        with(|b| b.held.len())
    }

    fn own_package(server: &str) -> HavenMessage {
        HavenMessage::MlsKeyPackage { server_id: server.to_string(), key_package: "a2V5".into(), channel_id: None }
    }

    /// HIGH-1: a second first sight of the same identity merges into the first, never
    /// replaces it; a roster that does not count its own deliverer is never held.
    #[test]
    fn a_later_staged_roster_merges_into_the_earlier_one() {
        let (mk, m, _) = crate::crdt::testkeys::keys(80);
        let (d1k, d1, _) = crate::crdt::testkeys::keys(81);
        let (d2k, d2, _) = crate::crdt::testkeys::keys(82);
        let (_, us, _) = crate::crdt::testkeys::keys(83);
        clear_for_test();
        set_relay(true, &us);
        assert!(stage(Roster::legacy_for_test(&mk, &[&d1k]), &d1, Rider::Nothing, &[ROOM.to_string()]).is_none(), "held");
        assert!(stage(Roster::new(&m), &d2, Rider::Nothing, &[ROOM.to_string()]).is_some(), "counts nobody: not held");
        assert!(stage(Roster::legacy_for_test(&mk, &[&d2k]), &d2, Rider::Nothing, &[ROOM.to_string()]).is_none(), "held");
        let staged = take_staged(&m).expect("staged");
        clear_for_test();
        assert_eq!(staged.landing_deliverer(&[d1.clone(), d2.clone()].into()), Some(d1.clone()), "the first counted deliverer");
        assert_eq!(staged.landing_deliverer(&[d2.clone()].into()), Some(d2.clone()), "a removed first deliverer gives way");
        assert_eq!(staged.landing_deliverer(&BTreeSet::new()), None, "nobody counted lands nothing");
        assert_eq!(staged.sender, d1, "the first deliverer stays");
        assert_eq!(staged.also, vec![d2.clone()]);
        let st = staged.roster.fold(|_| None, super::super::roster_book::now_ms());
        assert!(st.is_member(&d1) && st.is_member(&d2), "the later roster merged into the earlier one");
    }

    /// HIGH-1: a null answer judges the ask it answers, never the identity: no staged
    /// roster of another deliverer lands on it and nothing else about the master is wiped.
    #[test]
    fn a_null_answer_judges_only_its_own_ask() {
        let (mk, m, _) = crate::crdt::testkeys::keys(84);
        let (_, d1, _) = crate::crdt::testkeys::keys(85);
        let (d2k, d2, _) = crate::crdt::testkeys::keys(86);
        let (_, us, _) = crate::crdt::testkeys::keys(87);
        clear_for_test();
        set_relay(true, &us);
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        assert_eq!(confirm(&tx, &rooms(ROOM, &[&d1]), ROOM, &m, std::slice::from_ref(&d1)), Confirm::Wait);
        let asks = sent(&mut rx);
        assert_eq!(take_answer(ROOM, &m, &d1, &asks[0].3, None), Some(None));
        assert_eq!(confirm(&tx, &rooms(ROOM, &[&d1]), ROOM, &m, std::slice::from_ref(&d1)), Confirm::Skip, "the walk passes on");
        assert_eq!(gate(ROOM, &d1), Gate::Refuse, "nothing goes to the device it named for now");
        assert!(stage(Roster::legacy_for_test(&mk, &[&d2k]), &d2, Rider::Nothing, &[ROOM.to_string()]).is_none(), "held");
        assert!(take_ready_staged().is_empty(), "another device's staged roster waits for its own answer");
        assert_eq!(gate(ROOM, &d2), Gate::Hold, "and nothing judged its deliverer");
        assert!(take_staged_for_answer(&m, &d1, false).is_none(), "a null about another device lands nothing");
        assert!(take_staged_for_answer(&m, &d2, false).is_some(), "a null about its deliverer lands it alone");
        // The next ask names a device no null answer named.
        age_last_ask_for_test(&m);
        let both = [d1.clone(), d2.clone()];
        assert_eq!(confirm(&tx, &rooms(ROOM, &[&d1, &d2]), ROOM, &m, &both), Confirm::Wait);
        let again = sent(&mut rx);
        clear_for_test();
        assert_eq!(again.iter().map(|a| a.2.as_str()).collect::<Vec<_>>(), vec![d2.as_str()], "the ask named the device the null answer named");
    }

    /// LOW-5: a held KeyPackage waits out a key conflict or a device not counted (asked
    /// again), and is dropped only when the merged copies remove its device.
    #[test]
    fn a_held_key_package_is_dropped_only_on_a_removal() {
        let (_, m, _) = crate::crdt::testkeys::keys(88);
        let (_, d, _) = crate::crdt::testkeys::keys(89);
        let (_, us, _) = crate::crdt::testkeys::keys(90);
        clear_for_test();
        set_relay(true, &us);
        hold(ROOM, &m, &d, own_package(ROOM));
        set_placement(ROOM, &m, Placement { counted: [d.clone()].into(), removed: Default::default(), conflict: true });
        assert!(take_released().is_empty());
        assert_eq!(held_len(), 1, "a key conflict keeps it held");
        set_placement(ROOM, &m, Placement { removed: [d.clone()].into(), ..Placement::default() });
        assert!(take_released().is_empty());
        assert_eq!(held_len(), 0, "a removal drops it");
        clear_for_test();
    }

    /// LOW-4: one asker's forwards never push out our own package or another asker's, and
    /// the held frames are looked at only when an answer comes or one falls due.
    #[test]
    fn held_key_packages_give_way_per_owner_and_wait_for_their_due_time() {
        let (_, m, _) = crate::crdt::testkeys::keys(91);
        let (_, d, _) = crate::crdt::testkeys::keys(92);
        let (_, us, _) = crate::crdt::testkeys::keys(93);
        clear_for_test();
        set_relay(true, &us);
        hold(ROOM, &m, &d, own_package(ROOM));
        assert!(!has_work(), "nothing to look at before an answer or the due time");
        for i in 0..2 * HELD_PER_OWNER {
            let forward = HavenMessage::MlsKeyPackageForward { server_id: ROOM.into(), key_package: format!("one{i}"), channel_id: None };
            hold(ROOM, &m, &d, forward);
        }
        assert_eq!(held_len(), 1 + HELD_PER_OWNER, "one asker holds at most its share in a server");
        for i in 0..2 * MAX_ENTRIES {
            let server = format!("{:032x}", i % 80);
            let forward = HavenMessage::MlsKeyPackageForward { server_id: server.clone(), key_package: format!("junk{i}"), channel_id: None };
            hold(&server, &m, &d, forward);
        }
        assert!(held_len() <= MAX_ENTRIES);
        set_placement(ROOM, &m, Placement { counted: [d.clone()].into(), ..Placement::default() });
        let released = take_released();
        clear_for_test();
        assert!(
            released.iter().any(|(_, msg)| matches!(msg, HavenMessage::MlsKeyPackage { server_id, .. } if server_id == ROOM)),
            "our own package was pushed out by forwards"
        );
    }

    /// MED-2's bound: profiles held with staged rosters stay within [`RIDER_BYTES`]; past
    /// it a profile is kept without its blobs.
    #[test]
    fn a_profile_past_the_byte_budget_is_kept_light() {
        let (m, d, roster) = counting(94, 95);
        let (_, us, _) = crate::crdt::testkeys::keys(96);
        clear_for_test();
        set_relay(true, &us);
        let card = HavenMessage::ProfileCard {
            card: Default::default(),
            avatar_b64: "A".repeat(RIDER_BYTES),
            device_list: None,
        };
        assert!(stage(roster, &d, Rider::Profile(Box::new((card, 1))), &[ROOM.to_string()]).is_none(), "held");
        let staged = take_staged(&m).expect("staged");
        clear_for_test();
        match &staged.riders[..] {
            [(sender, Rider::Profile(p))] => {
                assert_eq!(sender, &d);
                assert!(matches!(&p.0, HavenMessage::ProfileCard { avatar_b64, .. } if avatar_b64.is_empty()), "kept whole past the budget");
            }
            other => panic!("the profile was not kept: {other:?}"),
        }
    }

    /// LOW-6: a node loop starts from an empty book, and the roster re-show timer never
    /// bursts after a stalled loop.
    #[test]
    fn the_loop_starts_with_an_empty_book_and_a_delayed_reshow() {
        let (_, us, _) = crate::crdt::testkeys::keys(97);
        clear_for_test();
        set_relay(true, &us);
        hold(ROOM, &us, &us, own_package(ROOM));
        reset_for_loop();
        assert_eq!(held_len(), 0);
        assert!(!applies("someone"), "a fresh loop has not heard the relay yet");
        let swarm = include_str!("swarm.rs").replace("\r\n", "\n");
        let start = swarm.find("let mut roster_show_timer").expect("the re-show timer");
        let head = &swarm[..start];
        assert!(head.contains("super::roster_check::reset_for_loop();"), "the loop keeps a previous loop's book");
        assert!(
            swarm[start..start + 600].contains("roster_show_timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay)"),
            "the re-show timer bursts after a stall"
        );
    }

    /// A profile is handled again only once its roster is held and counts its deliverer.
    #[test]
    fn a_profile_replays_only_after_its_roster_landed() {
        let (m, d, _) = counting(98, 99);
        let (_, other, _) = crate::crdt::testkeys::keys(100);
        clear_for_test();
        let rider = |from: &str| (from.to_string(), Rider::Profile(Box::new((HavenMessage::ProfileRequest, 1))));
        let counted: BTreeSet<String> = [d.clone()].into();
        assert!(after_landing(&m, vec![rider(&d)], false, &counted).is_empty());
        assert!(take_replays().is_empty(), "a roster the book did not keep replays nothing");
        let _ = after_landing(&m, vec![rider(&other)], true, &counted);
        assert!(take_replays().is_empty(), "a deliverer the roster does not count replays nothing");
        let _ = after_landing(&m, vec![rider(&d)], true, &counted);
        assert_eq!(take_replays().len(), 1, "a landed roster's profile is handled again");
        clear_for_test();
    }
}
