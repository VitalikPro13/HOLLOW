//! What this relay's operator refuses to carry (t14-deny): servers and meetings named in
//! its denylist, and whether it takes our login at all. RAM only, per relay, never
//! persisted; a denial deletes nothing. While a server is denied the node sends nothing
//! scoped to it through this relay, whichever room a frame would ride (review D2).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::types::{HavenMessage, MessageEnvelope};
use super::ws_client::WsCommand;

/// How often a denied room or login is quietly tried again, before jitter.
pub(crate) const RETRY_EVERY: Duration = Duration::from_secs(6 * 3600);

/// The most a retry is pushed past [`RETRY_EVERY`], so a fleet of clients does not ask
/// the relay at one moment.
const RETRY_JITTER: Duration = Duration::from_secs(30 * 60);

/// When a refusal seen now is tried again.
pub(crate) fn retry_at(now: Instant) -> Instant {
    let mut roll = [0u8; 8];
    let _ = getrandom::fill(&mut roll);
    let jitter = u64::from_le_bytes(roll) % RETRY_JITTER.as_millis() as u64;
    now + RETRY_EVERY + Duration::from_millis(jitter)
}

/// The key a room is denied under: the relay compares ids exactly, a renamed room
/// differs only in case.
pub(crate) fn room_key(room: &str) -> String {
    room.to_ascii_lowercase()
}

/// Whether a `room_denied` may name `room` at all (review D12): only a server's room or
/// a meeting's. Inbox, DM, forwarder, own, link and share rooms never are, so a hostile
/// relay cannot silence them with it.
pub(crate) fn deniable_room(room: &str) -> bool {
    let key = room_key(room);
    match super::conference::conf_id_from_sid(&key) {
        Some(conf_id) => super::conference::is_pinned_conf_id(conf_id),
        None => crate::crdt::anchor::valid_server_id(&key),
    }
}

/// The room a refusal from the relay may take, as its key: one of our own servers, a
/// server we are joining or a meeting. A DM room has a legacy server id's shape, so only
/// the node, which knows its servers, can tell them apart (review D12).
pub(crate) fn ours_to_refuse(room: &str, is_our_server: impl Fn(&str) -> bool) -> Option<String> {
    if !deniable_room(room) {
        return None;
    }
    let key = room_key(room);
    (super::conference::is_conference_sid(&key) || is_our_server(&key)).then_some(key)
}

/// The denied key a server-scoped id names: a channel subgroup `{server}#{channel}`
/// belongs to its server.
fn scope_key(id: &str) -> String {
    room_key(id.split('#').next().unwrap_or(id))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mark {
    /// Refused; asked again at this time.
    Denied { retry_at: Instant },
    /// A join is out asking whether the refusal still holds: the join and the lock read
    /// may leave, nothing else does.
    Probing,
    /// The server's owner-signed home is another relay (`home_relay`): never probed, and
    /// only a home that names this relay again ends it.
    Elsewhere,
}

/// The most rooms named after a server ([`Denials::alias`]) kept; past it the map
/// starts over.
const ALIASES_MAX: usize = 256;

/// The rooms this relay refuses, shared by the node loop and its sealing stage.
#[derive(Clone, Default)]
pub(crate) struct Denials {
    rooms: Arc<Mutex<HashMap<String, Mark>>>,
    /// Rooms that carry one server's traffic under another name (a recovery pool's).
    aliases: Arc<Mutex<HashMap<String, String>>>,
    /// The relay each `Elsewhere` server lives on, as last told to Dart.
    homes: Arc<Mutex<HashMap<String, String>>>,
}

tokio::task_local! {
    /// The node loop's refusals, which the sealing stage it spawns shares.
    static DENIALS: Denials;
}

/// Run a node's event loop with refusals of its own: harness nodes share a process.
pub(crate) fn with_denials<F: std::future::Future>(event_loop: F) -> impl std::future::Future<Output = F::Output> {
    DENIALS.scope(Denials::default(), event_loop)
}

/// This node loop's refusals; outside a loop, an empty set of its own.
pub(crate) fn current() -> Denials {
    DENIALS.try_with(Denials::clone).unwrap_or_default()
}

/// Whether the relay this node loop dials refuses `id` (a room, a server id or a
/// subgroup key): what serving and repair paths ask before they act for a server.
pub(crate) fn denied(id: &str) -> bool {
    DENIALS.try_with(|d| d.is_denied(id)).unwrap_or(false)
}

/// We left `room` (a server or meeting): this node loop forgets the relay refused it.
pub(crate) fn forget(room: &str) {
    #[cfg(test)]
    if LEAVES_FORGET_NOTHING.load(std::sync::atomic::Ordering::Relaxed) {
        return;
    }
    let _ = DENIALS.try_with(|d| d.forget(room));
}

/// TEST-ONLY: leaves forget no refusal, so a test reaches the probe's own check.
#[cfg(test)]
pub(crate) static LEAVES_FORGET_NOTHING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

impl Denials {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Mark>> {
        self.rooms.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// `room` carries `server`'s traffic under another name: refused with it.
    pub(crate) fn alias(&self, room: &str, server: &str) {
        let mut aliases = self.aliases.lock().unwrap_or_else(|e| e.into_inner());
        if aliases.len() >= ALIASES_MAX {
            aliases.clear();
        }
        aliases.insert(room_key(room), scope_key(server));
    }

    /// Mark `room` refused; true the first time (a probe answered again counts too).
    pub(crate) fn deny(&self, room: &str, now: Instant) -> bool {
        let mut rooms = self.lock();
        if rooms.get(&room_key(room)) == Some(&Mark::Elsewhere) {
            return false;
        }
        let previous = rooms.insert(room_key(room), Mark::Denied { retry_at: retry_at(now) });
        !matches!(previous, Some(Mark::Denied { .. }))
    }

    fn homes(&self) -> std::sync::MutexGuard<'_, HashMap<String, String>> {
        self.homes.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Mark a server whose home is `relay`, another relay; true when the mark is new or
    /// names another relay than before.
    pub(crate) fn mark_elsewhere(&self, server: &str, relay: &str) -> bool {
        let key = room_key(server);
        let was = self.lock().insert(key.clone(), Mark::Elsewhere);
        let told = self.homes().insert(key, relay.to_string());
        was != Some(Mark::Elsewhere) || told.as_deref() != Some(relay)
    }

    /// The server's home is this relay again; true when that ends a mark.
    pub(crate) fn clear_elsewhere(&self, server: &str) -> bool {
        let mut rooms = self.lock();
        let key = room_key(server);
        self.homes().remove(&key);
        if rooms.get(&key) != Some(&Mark::Elsewhere) {
            return false;
        }
        rooms.remove(&key).is_some()
    }

    /// Every server marked as living on another relay, with the relay last told.
    pub(crate) fn elsewhere(&self) -> HashMap<String, String> {
        let rooms = self.lock();
        self.homes().iter().filter(|(k, _)| rooms.get(*k) == Some(&Mark::Elsewhere)).map(|(k, v)| (k.clone(), v.clone())).collect()
    }

    /// Whether `id` (a room, a server id or a subgroup key) is refused or being probed.
    pub(crate) fn is_denied(&self, id: &str) -> bool {
        let rooms = self.lock();
        if rooms.is_empty() {
            return false;
        }
        let key = scope_key(id);
        rooms.contains_key(&key)
            || self.aliases.lock().unwrap_or_else(|e| e.into_inner()).get(&key).is_some_and(|s| rooms.contains_key(s))
    }

    /// The relay let us back into `room` while we asked it again: true when that ends
    /// a refusal. A member list we did not ask for lifts nothing, since ws_client keeps
    /// refusing the room until a retry clears it.
    pub(crate) fn lift(&self, room: &str) -> bool {
        let mut rooms = self.lock();
        let key = room_key(room);
        if rooms.get(&key) != Some(&Mark::Probing) {
            return false;
        }
        rooms.remove(&key).is_some()
    }

    /// We left `room`: its refusal and every room named after it go, so no probe puts
    /// this socket back into it (review M2).
    pub(crate) fn forget(&self, room: &str) {
        let key = scope_key(room);
        self.lock().remove(&key);
        self.aliases.lock().unwrap_or_else(|e| e.into_inner()).retain(|alias, server| *alias != key && *server != key);
    }

    /// Forget every refused room `ours` no longer names, returning them: a probe asks
    /// only about rooms we still hold.
    pub(crate) fn forget_unless(&self, ours: impl Fn(&str) -> bool) -> Vec<String> {
        let gone: Vec<String> = self.lock().keys().filter(|key| !ours(key)).cloned().collect();
        for key in &gone {
            self.forget(key);
        }
        gone
    }

    /// A meeting's room we no longer hold, now probing as if refused: a start or knock
    /// asks about it before it holds the meeting again. Only a meeting room.
    pub(crate) fn probe_meeting_to_hold(&self, room: &str) -> bool {
        let key = room_key(room);
        if !super::conference::is_conference_sid(&key) || !deniable_room(&key) {
            return false;
        }
        self.lock().insert(key, Mark::Probing);
        true
    }

    /// `room` alone, now probing, if it is refused: a meeting's start or knock asks
    /// about its own room only.
    pub(crate) fn probe_one(&self, room: &str) -> bool {
        match self.lock().get_mut(&room_key(room)) {
            Some(mark @ Mark::Denied { .. }) => {
                *mark = Mark::Probing;
                true
            }
            _ => false,
        }
    }

    /// Every refused room, sorted.
    pub(crate) fn rooms(&self) -> Vec<String> {
        let mut rooms: Vec<String> = self.lock().keys().cloned().collect();
        rooms.sort();
        rooms
    }

    /// The refused rooms whose quiet retry is due, now probing.
    pub(crate) fn probe_due(&self, now: Instant) -> Vec<String> {
        self.probe(|mark| matches!(mark, Mark::Denied { retry_at } if *retry_at <= now))
    }

    /// Every refused room, now probing: the person asked to try again.
    pub(crate) fn probe_all(&self) -> Vec<String> {
        self.probe(|mark| matches!(mark, Mark::Denied { .. }))
    }

    fn probe(&self, due: impl Fn(&Mark) -> bool) -> Vec<String> {
        let mut rooms = self.lock();
        let mut out: Vec<String> = rooms
            .iter_mut()
            .filter(|(_, mark)| due(mark))
            .map(|(room, mark)| {
                *mark = Mark::Probing;
                room.clone()
            })
            .collect();
        out.sort();
        out
    }

    fn probing(&self, room: &str) -> bool {
        self.lock().get(&room_key(room)) == Some(&Mark::Probing)
    }

    /// The command as it may leave for the relay, `None` when everything in it is scoped
    /// to a refused server or meeting: the sealing stage's one gate (review D2).
    pub(crate) fn pass(&self, cmd: WsCommand) -> Option<WsCommand> {
        if self.lock().is_empty() {
            return Some(cmd);
        }
        if let WsCommand::LockGet { locks } = cmd {
            let locks: Vec<(String, String)> =
                locks.into_iter().filter(|(server, _)| !self.is_denied(server) || self.probing(server)).collect();
            return (!locks.is_empty()).then_some(WsCommand::LockGet { locks });
        }
        (!self.refuses(&cmd)).then_some(cmd)
    }

    fn refuses(&self, cmd: &WsCommand) -> bool {
        match cmd {
            WsCommand::JoinRoom { room_code } => self.is_denied(room_code) && !self.probing(room_code),
            WsCommand::JoinInbox { room_code, .. }
            | WsCommand::Subscribe { room_code, .. }
            | WsCommand::DiscoverPeers { room_code }
            | WsCommand::SetTopicBuffer { room_code, .. }
            | WsCommand::TopicCatchup { room_code, .. }
            | WsCommand::SendBinaryDirect { room_code, .. } => self.is_denied(room_code),
            WsCommand::LockPut { server, .. } => self.is_denied(server),
            WsCommand::SendToRoom { room_code, data }
            | WsCommand::SendPublic { room_code, data }
            | WsCommand::SendToRoomTopic { room_code, data, .. }
            | WsCommand::SendDirect { room_code, data, .. }
            | WsCommand::SendDirectImage { room_code, data, .. }
            | WsCommand::SendChannelDirect { room_code, data, .. } => {
                self.is_denied(room_code) || self.names_denied(haven_scope(data))
            }
            WsCommand::Carry { room, json, .. } => self.refuses_carry(room.as_deref(), json),
            WsCommand::AfterSave { frame, plaintext, .. } => {
                self.names_denied(envelope_scope(plaintext.as_bytes())) || self.refuses(frame)
            }
            WsCommand::AfterMlsSave { frame, .. } => self.refuses(frame),
            _ => false,
        }
    }

    /// Whether a carried envelope is scoped to a refused server, by its pinned room or
    /// what it is about.
    pub(crate) fn refuses_carry(&self, room: Option<&str>, json: &str) -> bool {
        if self.lock().is_empty() {
            return false;
        }
        room.is_some_and(|r| self.is_denied(r)) || self.names_denied(envelope_scope(json.as_bytes()))
    }

    fn names_denied(&self, scope: Option<String>) -> bool {
        scope.is_some_and(|s| self.is_denied(&s))
    }
}

/// Ask the relay again about `rooms`, already probing: the client forgets its refusal,
/// joins, and a pending join reads the lock afresh. Its answer is a `members` list (a
/// lift) or another refusal.
pub(crate) fn send_probes(
    ws_cmd_tx: &super::types::WsCmdTx,
    rooms: &[String],
    pending: &mut HashMap<String, super::types::PendingJoin>,
) {
    for room in rooms {
        hollow_log!("[HOLLOW-WS] Asking the relay again whether it carries {room}");
        let _ = ws_cmd_tx.send(WsCommand::RetryDenied { room: Some(room.clone()) });
        if let Some(join) = pending.get_mut(room) {
            join.lock_asked_at = None;
            join.lock_asks.clear();
            super::sync_handler::request_join_lock(ws_cmd_tx, room, join);
        }
        let _ = ws_cmd_tx.send(WsCommand::JoinRoom { room_code: room.clone() });
    }
}

/// The server or meeting a plaintext relay payload is about, if any.
pub(crate) fn haven_scope(data: &[u8]) -> Option<String> {
    serde_json::from_slice::<HavenMessage>(data).ok()?.server_scope()
}

/// The server or meeting an Olm envelope is about, if any.
pub(crate) fn envelope_scope(json: &[u8]) -> Option<String> {
    let envelope = serde_json::from_slice::<MessageEnvelope>(json).ok()?;
    if let MessageEnvelope::Carried { msg, .. } = &envelope {
        return msg.server_scope();
    }
    match envelope.place() {
        super::types::EnvelopePlace::Server { sid, .. } => Some(scope_key(sid)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const S: &str = "0123456789abcdef0123456789abcdef01234567";
    const LEGACY: &str = "0123456789abcdef0123456789abcdef";

    fn haven(msg: &HavenMessage) -> Vec<u8> {
        serde_json::to_vec(msg).unwrap()
    }

    #[test]
    fn only_server_and_meeting_rooms_can_be_denied() {
        assert!(deniable_room(S));
        assert!(deniable_room(&S.to_ascii_uppercase()));
        assert!(deniable_room(LEGACY));
        assert!(deniable_room(&format!("conf:{S}")));
        for room in [
            format!("inbox:{S}"),
            format!("fwd:{S}"),
            format!("{S}#general"),
            format!("conf:{LEGACY}"),
            "dm:abc".to_string(),
            format!("share:{S}"),
            format!("recovery:{S}"),
            String::new(),
        ] {
            assert!(!deniable_room(&room), "{room}");
        }
    }

    #[test]
    fn only_our_own_servers_and_meetings_are_taken_as_refused() {
        let ours = |key: &str| key == S;
        assert_eq!(ours_to_refuse(&S.to_ascii_uppercase(), ours).as_deref(), Some(S));
        let meeting = format!("conf:{S}");
        assert_eq!(ours_to_refuse(&meeting, ours), Some(meeting.clone()));
        // A DM room code has a legacy server id's shape.
        assert_eq!(ours_to_refuse(LEGACY, ours), None, "a DM-shaped room that is no server of ours");
        assert_eq!(ours_to_refuse(&format!("inbox:{S}"), |_| true), None);
    }

    #[test]
    fn a_denied_server_passes_nothing_scoped_to_it_and_everything_else() {
        let d = Denials::default();
        assert!(d.deny(&S.to_ascii_uppercase(), Instant::now()));
        let dm = "dm:0000".to_string();
        let crdt = haven(&HavenMessage::CrdtOpBroadcast { server_id: S.into(), op_json: "{}".into() });
        let sub = haven(&HavenMessage::TypingIndicator { server_id: format!("{S}#general"), channel_id: "general".into() });
        let other = haven(&HavenMessage::CrdtOpBroadcast { server_id: "f".repeat(40), op_json: "{}".into() });
        let refused = [
            WsCommand::JoinRoom { room_code: S.into() },
            WsCommand::Subscribe { room_code: S.into(), topics: vec![] },
            WsCommand::TopicCatchup { room_code: S.into(), channel_id: "c".into(), max_age_secs: 0, end: true },
            WsCommand::SendToRoom { room_code: S.into(), data: b"x".to_vec() },
            WsCommand::SendDirect { room_code: dm.clone(), target_peer: "p".into(), data: crdt.clone() },
            WsCommand::SendToRoom { room_code: dm.clone(), data: sub },
            WsCommand::LockPut { server: S.into(), owner: String::new(), links: vec![] },
            WsCommand::LockGet { locks: vec![(S.into(), String::new())] },
        ];
        for cmd in refused {
            let label = format!("{cmd:?}").chars().take(60).collect::<String>();
            assert!(d.pass(cmd).is_none(), "{label}");
        }
        assert!(d.pass(WsCommand::SendDirect { room_code: dm.clone(), target_peer: "p".into(), data: other }).is_some());
        assert!(d.pass(WsCommand::SendToRoom { room_code: dm, data: b"opaque".to_vec() }).is_some());
        assert!(d.pass(WsCommand::LeaveRoom { room_code: S.into() }).is_some());
        let mixed = d.pass(WsCommand::LockGet { locks: vec![(S.into(), String::new()), ("f".repeat(40), String::new())] });
        assert!(matches!(mixed, Some(WsCommand::LockGet { locks }) if locks.len() == 1 && locks[0].0 == "f".repeat(40)));
    }

    #[test]
    fn a_carried_or_olm_envelope_of_a_denied_server_is_kept_back() {
        let d = Denials::default();
        d.deny(S, Instant::now());
        let carried = MessageEnvelope::Carried {
            msg: Box::new(HavenMessage::CrdtOpBroadcast { server_id: S.into(), op_json: "{}".into() }),
            at_ms: 0,
        };
        let json = serde_json::to_string(&carried).unwrap();
        let carry = WsCommand::Carry { device: "d".into(), room: None, json, no_session: super::super::olm_lane::NoSession::Queue, ticket: None };
        assert!(d.pass(carry).is_none());
        let crdt = MessageEnvelope::CrdtOp { sid: S.into(), op_json: String::new() };
        let plaintext = serde_json::to_string(&crdt).unwrap();
        let frame = Box::new(WsCommand::SendDirect { room_code: "dm:1".into(), target_peer: "p".into(), data: b"olm".to_vec() });
        let olm = WsCommand::AfterSave { saved: crate::crypto::SessionSaved::failed(), frame, device: "p".into(), plaintext };
        assert!(d.pass(olm).is_none());
    }

    #[test]
    fn a_room_carrying_a_denied_server_under_another_name_is_refused_with_it() {
        let d = Denials::default();
        let pool = super::super::recovery_pool::pool_room(S, "token");
        d.alias(&pool, S);
        assert!(d.pass(WsCommand::JoinRoom { room_code: pool.clone() }).is_some(), "nothing refused yet");
        d.deny(S, Instant::now());
        assert!(d.pass(WsCommand::JoinRoom { room_code: pool.clone() }).is_none());
        assert!(d.pass(WsCommand::SendToRoom { room_code: pool, data: b"sealed".to_vec() }).is_none());
    }

    fn scoped_carry() -> WsCommand {
        let msg = HavenMessage::CrdtOpBroadcast { server_id: S.into(), op_json: "{}".into() };
        let json = serde_json::to_string(&MessageEnvelope::Carried { msg: Box::new(msg), at_ms: 0 }).unwrap();
        WsCommand::Carry { device: "d".into(), room: Some("dm:1".into()), json, no_session: super::super::olm_lane::NoSession::Queue, ticket: None }
    }

    /// The sealing stage hands the node a refused server's carry, so the node frees its
    /// carry-book place (`OlmLane::deliver`), and writes nothing for it.
    #[tokio::test]
    async fn the_sealing_stage_hands_a_refused_carry_back_to_the_node_and_writes_nothing() {
        let d = Denials::default();
        d.deny(S, Instant::now());
        let (relay, mut wire) = tokio::sync::mpsc::unbounded_channel();
        let (sealer, mut carries) =
            super::super::frame_auth::spawn_sealer(crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[3; 32]), relay, d);
        sealer.send(scoped_carry()).unwrap();
        let (_, answer) = carries.recv().await.expect("the node gets the carry to release it");
        answer.send(Vec::new()).unwrap();
        sealer.send(WsCommand::GetTurnCredentials).unwrap();
        assert!(matches!(wire.recv().await, Some(WsCommand::GetTurnCredentials)), "only what follows reaches the relay");
    }

    /// A refusal that lands while a carry is being encrypted still keeps its frames back.
    #[tokio::test]
    async fn a_refusal_during_a_carry_keeps_its_frames_back() {
        let d = Denials::default();
        let (relay, mut wire) = tokio::sync::mpsc::unbounded_channel();
        let (sealer, mut carries) = super::super::frame_auth::spawn_sealer(
            crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[3; 32]),
            relay,
            d.clone(),
        );
        sealer.send(scoped_carry()).unwrap();
        let (_, answer) = carries.recv().await.expect("the carry reaches the node");
        d.deny(S, Instant::now());
        let data = serde_json::to_vec(&HavenMessage::CrdtOpBroadcast { server_id: S.into(), op_json: "{}".into() }).unwrap();
        answer.send(vec![WsCommand::SendDirect { room_code: "dm:1".into(), target_peer: "d".into(), data }]).unwrap();
        sealer.send(WsCommand::GetTurnCredentials).unwrap();
        assert!(matches!(wire.recv().await, Some(WsCommand::GetTurnCredentials)), "the carried frame was written");
    }

    #[test]
    fn a_probe_lets_the_join_and_the_lock_read_out_and_nothing_else() {
        let d = Denials::default();
        let now = Instant::now();
        d.deny(S, now);
        assert!(d.probe_due(now).is_empty(), "the retry waits six hours");
        assert_eq!(d.probe_due(now + RETRY_EVERY + RETRY_JITTER), vec![S.to_string()]);
        assert!(d.pass(WsCommand::JoinRoom { room_code: S.into() }).is_some());
        assert!(d.pass(WsCommand::LockGet { locks: vec![(S.into(), String::new())] }).is_some());
        assert!(d.pass(WsCommand::SendToRoom { room_code: S.into(), data: vec![] }).is_none());
        assert!(d.deny(S, now), "a probe answered with a refusal is refused again");
        assert_eq!(d.probe_all(), vec![S.to_string()]);
        assert!(d.lift(S));
        assert!(d.pass(WsCommand::SendToRoom { room_code: S.into(), data: vec![] }).is_some());
    }

    /// A room we left is forgotten with every room named after it, and a probe asks
    /// only about the rooms still ours.
    #[test]
    fn a_left_room_is_forgotten_and_never_probed() {
        let d = Denials::default();
        let other = "f".repeat(40);
        d.deny(S, Instant::now());
        d.deny(&other, Instant::now());
        d.alias("recovery:pool", S);
        assert!(d.is_denied("recovery:pool"));
        assert_eq!(d.forget_unless(|key| key == other), vec![S.to_string()]);
        assert!(!d.is_denied(S) && !d.is_denied("recovery:pool"), "a left room and its aliases go");
        assert_eq!(d.probe_all(), vec![other.clone()], "only a room still ours is asked about");
        d.forget(&other.to_ascii_uppercase());
        assert!(d.rooms().is_empty());
        d.deny(S, Instant::now());
        assert!(!d.is_denied("recovery:pool"), "a room named after a server we left is not refused with it again");
    }

    /// One room is probed alone; one not refused is not probed at all.
    #[test]
    fn one_room_is_probed_alone() {
        let d = Denials::default();
        let other = "f".repeat(40);
        d.deny(S, Instant::now());
        d.deny(&other, Instant::now());
        assert!(d.probe_one(&S.to_ascii_uppercase()));
        assert!(!d.probe_one(S), "a room already probing is not asked twice");
        assert!(!d.probe_one("e".repeat(40).as_str()), "a room not refused is not asked about");
        assert_eq!(d.probe_all(), vec![other], "the other refusal was not asked about");
        assert!(d.lift(S));
    }

    #[test]
    fn an_unasked_member_list_lifts_nothing() {
        let d = Denials::default();
        d.deny(S, Instant::now());
        assert!(!d.lift(S), "a member list nobody asked for lifted the refusal");
        assert!(d.pass(WsCommand::SendToRoom { room_code: S.into(), data: vec![] }).is_none());
    }
}
