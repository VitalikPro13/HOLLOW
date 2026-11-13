//! Age-restricted servers on phones (Apple 1.2): a phone hides a server flagged 18+
//! until the identity allows it from a computer (Android: or on that phone itself).
//!
//! The identity's choice is one stamped entry every device of ours holds; only a
//! computer authors it, and it reaches our phones only from our own devices
//! (`AgeGateSync`, judged by [`outranks`]). Hidden servers stay joined.

use serde::{Deserialize, Serialize};

use crate::crdt::server_state::ServerState;
use crate::storage::MessageStore;

/// The identity's choice for its phones, as JSON [`AgeGateEntry`].
pub(crate) const PHONES_KEY: &str = "age_gate_phones";
/// An Android phone's own toggle, never shared.
pub(crate) const LOCAL_KEY: &str = "age_gate_local";
/// A computer already offered the choice once.
pub(crate) const ASKED_KEY: &str = "age_gate_asked";
/// Set by an Android build installed from a store: it behaves like an iPhone.
pub(crate) const STORE_INSTALL_KEY: &str = "age_gate_store_install";
/// The relay refuses a longer list whole (`sib_mute.h`).
const MAX_SIB_SERVERS: usize = 256;
/// One row per server whose flags this device has caught up on.
const SETTLED_PREFIX: &str = "age_settled:";
/// This device's own yes to a server's 18+ question, per server.
const CONSENT_PREFIX: &str = "age_consent:";
/// Present once this database tracks settled servers; an older one held each server
/// fully before it learned to.
const SETTLED_INIT_KEY: &str = "age_settled_init";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    Desktop,
    Ios,
    Android,
}

#[cfg(test)]
thread_local! {
    static TEST_PLATFORM: std::cell::Cell<Option<Platform>> = const { std::cell::Cell::new(None) };
}

/// Make this test thread a phone (or back with `None`).
#[cfg(test)]
pub(crate) fn set_test_platform(platform: Option<Platform>) {
    TEST_PLATFORM.with(|p| p.set(platform));
}

/// Every thread of a harness test's process a phone, the event loops included, until
/// the guard drops. A thread's own [`set_test_platform`] still wins.
#[cfg(test)]
pub(crate) fn phone_process_for_test(platform: Platform) -> TestPlatformGuard {
    TEST_PLATFORM_ALL.store(platform as u8 + 1, std::sync::atomic::Ordering::SeqCst);
    TestPlatformGuard
}

#[cfg(test)]
static TEST_PLATFORM_ALL: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

#[cfg(test)]
pub(crate) struct TestPlatformGuard;

#[cfg(test)]
impl Drop for TestPlatformGuard {
    fn drop(&mut self) {
        TEST_PLATFORM_ALL.store(0, std::sync::atomic::Ordering::SeqCst);
    }
}

impl Platform {
    pub fn current() -> Self {
        #[cfg(test)]
        if let Some(platform) = TEST_PLATFORM.with(std::cell::Cell::get) {
            return platform;
        }
        #[cfg(test)]
        match TEST_PLATFORM_ALL.load(std::sync::atomic::Ordering::SeqCst) {
            1 => return Self::Desktop,
            2 => return Self::Ios,
            3 => return Self::Android,
            _ => {}
        }
        if cfg!(target_os = "ios") {
            Self::Ios
        } else if cfg!(target_os = "android") {
            Self::Android
        } else {
            Self::Desktop
        }
    }

    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Desktop => "desktop",
            Self::Ios => "ios",
            Self::Android => "android",
        }
    }
}

/// The identity's choice for its phones at the stamp a computer of ours set it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct AgeGateEntry {
    #[serde(default)]
    pub allow: bool,
    #[serde(default)]
    pub at: i64,
}

pub(crate) fn held(store: &MessageStore) -> Option<AgeGateEntry> {
    let raw = store.load_setting(PHONES_KEY).ok()??;
    serde_json::from_str(&raw).ok()
}

fn flag(store: &MessageStore, key: &str) -> bool {
    store.load_setting(key).ok().flatten().as_deref() == Some("true")
}

/// This phone's own toggle counts: an Android build that did not come from a store.
pub(crate) fn local_allowed(store: &MessageStore, platform: Platform) -> bool {
    platform == Platform::Android && !flag(store, STORE_INSTALL_KEY) && flag(store, LOCAL_KEY)
}

/// Whether this device shows age-restricted servers. Never received = closed.
pub(crate) fn allowed_here(store: &MessageStore, platform: Platform) -> bool {
    match platform {
        Platform::Desktop => true,
        Platform::Ios => held(store).is_some_and(|e| e.allow),
        Platform::Android => held(store).is_some_and(|e| e.allow) || local_allowed(store, platform),
    }
}

/// Whether a sibling's `incoming` replaces `held`: newest wins and OFF wins a tie. An
/// entry stamped past its frame's `ceiling` is refused (a clamped ON could outrank a
/// real OFF); a held row past what any frame could carry was planted.
pub(crate) fn outranks(held: Option<AgeGateEntry>, incoming: AgeGateEntry, ceiling: i64, now_ms: i64) -> bool {
    if incoming.at <= 0 || incoming.at > ceiling {
        return false;
    }
    let Some(held) = held else { return true };
    if held.at > super::frame_auth::stored_stamp_limit(now_ms) {
        return true;
    }
    incoming.at > held.at || (incoming.at == held.at && held.allow && !incoming.allow)
}

fn save(store: &MessageStore, entry: AgeGateEntry) -> Result<(), String> {
    let json = serde_json::to_string(&entry).map_err(|e| e.to_string())?;
    store.save_setting(PHONES_KEY, &json)
}

/// Take the entry one of our own devices shared. `Some(allow)` when what this device
/// shows may have changed.
pub(crate) fn take_sibling(store: &MessageStore, incoming: AgeGateEntry, ceiling: i64, now_ms: i64) -> Option<bool> {
    let before = held(store);
    if !outranks(before, incoming, ceiling, now_ms) || save(store, incoming).is_err() {
        return None;
    }
    hollow_log!("[HOLLOW-AGEGATE] Our other device set age-restricted servers on phones to {}", incoming.allow);
    (before.map(|e| e.allow) != Some(incoming.allow)).then_some(incoming.allow)
}

/// Author the identity's choice. Only a computer may: a phone hides by default and
/// must never open itself.
pub(crate) fn author(store: &MessageStore, platform: Platform, allow: bool, now_ms: i64) -> Result<AgeGateEntry, String> {
    if platform != Platform::Desktop {
        return Err("Only Hollow on a computer can change this".into());
    }
    // A sibling's clock running ahead never undoes a newer choice; a planted stamp
    // is not one to follow.
    let floor = held(store)
        .filter(|h| h.at <= super::frame_auth::stored_stamp_limit(now_ms))
        .map_or(0, |h| h.at.saturating_add(1));
    let entry = AgeGateEntry { allow, at: now_ms.max(floor) };
    save(store, entry)?;
    Ok(entry)
}

/// An Android phone's own toggle.
pub(crate) fn set_local(store: &MessageStore, platform: Platform, allow: bool) -> Result<(), String> {
    if platform != Platform::Android || flag(store, STORE_INSTALL_KEY) {
        return Err("This phone has no setting for this".into());
    }
    store.save_setting(LOCAL_KEY, if allow { "true" } else { "false" })
}

/// An Android build says at every start whether a store installed it: a store build
/// behaves like an iPhone, and a later sideload gets its toggle back, off. True when
/// the mark changed.
pub(crate) fn mark_store_install(store: &MessageStore, store_install: bool) -> Result<bool, String> {
    if flag(store, STORE_INSTALL_KEY) == store_install {
        return Ok(false);
    }
    if store_install {
        store.save_setting(STORE_INSTALL_KEY, "true")?;
    } else {
        store.delete_setting(STORE_INSTALL_KEY)?;
    }
    store.delete_setting(LOCAL_KEY)?;
    Ok(true)
}

/// Start tracking settled servers: the ones held now were held fully by an older build.
pub(crate) fn init_settled<'a>(store: &MessageStore, held: impl Iterator<Item = &'a str>) {
    if store.load_setting(SETTLED_INIT_KEY).ok().flatten().is_some() {
        return;
    }
    for sid in held {
        let _ = store.save_setting(&format!("{SETTLED_PREFIX}{sid}"), "1");
    }
    let _ = store.save_setting(SETTLED_INIT_KEY, "1");
}

pub(crate) fn is_settled(store: &MessageStore, server_id: &str) -> bool {
    store.load_setting(SETTLED_INIT_KEY).ok().flatten().is_none()
        || store.load_setting(&format!("{SETTLED_PREFIX}{server_id}")).ok().flatten().is_some()
}

/// A member's final catch-up answer for `server_id` landed. True when it was the first.
pub(crate) fn note_settled(store: &MessageStore, server_id: &str) -> bool {
    if is_settled(store, server_id) {
        return false;
    }
    store.save_setting(&format!("{SETTLED_PREFIX}{server_id}"), "1").is_ok()
}

/// A join of `server_id` starts: nothing we held of it says what it is now.
pub(crate) fn unsettle(store: &MessageStore, server_id: &str) {
    let _ = store.delete_setting(&format!("{SETTLED_PREFIX}{server_id}"));
}

/// Whether THIS device's person said yes to the 18+ question for `server_id`. Never
/// shared or copied: a reset or another device asks again.
pub(crate) fn consent_held(store: &MessageStore, server_id: &str) -> bool {
    store.load_setting(&format!("{CONSENT_PREFIX}{server_id}")).ok().flatten().is_some()
}

/// The person here answered yes for `server_id`; nothing a phone with the gate closed keeps.
pub(crate) fn note_consent(store: &MessageStore, platform: Platform, server_id: &str) {
    if allowed_here(store, platform) {
        let _ = store.save_setting(&format!("{CONSENT_PREFIX}{server_id}"), "1");
    }
}

/// The 18+ consent a join from this device may carry: the answer just given or one this
/// device holds, and none while the gate is closed, whatever the UI asked.
pub(crate) fn join_consent(store: &MessageStore, platform: Platform, server_id: &str, nsfw_confirmed: bool) -> bool {
    (nsfw_confirmed || consent_held(store, server_id)) && allowed_here(store, platform)
}

/// [`join_consent`] on the node's database; a store that will not open consents only
/// to what was just answered, and on a phone to nothing.
pub(crate) fn join_consent_at(db_path: &str, db_passphrase: &str, server_id: &str, nsfw_confirmed: bool) -> bool {
    let platform = Platform::current();
    match MessageStore::lease(db_path, db_passphrase) {
        Ok(store) => join_consent(&store, platform, server_id, nsfw_confirmed),
        Err(_) => platform == Platform::Desktop && nsfw_confirmed,
    }
}

/// The 18+ consent an automatic join from this device carries: only a yes it holds.
pub(crate) fn own_consent_at(db_path: &str, db_passphrase: &str, server_id: &str) -> bool {
    join_consent_at(db_path, db_passphrase, server_id, false)
}

/// [`note_settled`] on the node's database.
pub(crate) fn note_settled_at(db_path: &str, db_passphrase: &str, server_id: &str) -> bool {
    MessageStore::lease(db_path, db_passphrase).is_ok_and(|store| note_settled(&store, server_id))
}

/// [`unsettle`] on the node's database.
pub(crate) fn unsettle_at(db_path: &str, db_passphrase: &str, server_id: &str) {
    if let Ok(store) = MessageStore::lease(db_path, db_passphrase) {
        unsettle(&store, server_id);
    }
}

/// Whether `state` stays off this device: flagged 18+, or not yet known not to be
/// (a server mid-join folds its settings op late), while the gate is closed.
#[cfg(test)]
pub(crate) fn hidden(store: &MessageStore, platform: Platform, server_id: &str, state: &ServerState) -> bool {
    !allowed_here(store, platform) && hidden_when_closed(store, server_id, state)
}

pub(crate) fn hidden_when_closed(store: &MessageStore, server_id: &str, state: &ServerState) -> bool {
    state.is_nsfw() || !(state.settings.contains_key("is_nsfw") || is_settled(store, server_id))
}

/// [`hidden`] for a server read from `store`; one we do not hold counts as hidden.
pub(crate) fn server_hidden_in(store: &MessageStore, platform: Platform, server_id: &str) -> bool {
    if allowed_here(store, platform) {
        return false;
    }
    let state = store
        .load_server_state(server_id)
        .ok()
        .flatten()
        .and_then(|json| serde_json::from_str::<ServerState>(&json).ok());
    state.is_none_or(|s| hidden_when_closed(store, server_id, &s))
}

/// Whether a wake for `server_id` whose posts were not read must name nothing, the gate
/// open or not: flagged 18+, not yet known not to be, or not held.
pub(crate) fn server_age_restricted_in(store: &MessageStore, server_id: &str) -> bool {
    store
        .load_server_state(server_id)
        .ok()
        .flatten()
        .and_then(|json| serde_json::from_str::<ServerState>(&json).ok())
        .is_none_or(|s| hidden_when_closed(store, server_id, &s))
}

/// Every server of `states` [`hidden`] keeps off this device.
pub(crate) fn hidden_servers<'a>(
    store: &MessageStore,
    platform: Platform,
    states: impl Iterator<Item = (&'a String, &'a ServerState)>,
) -> Vec<String> {
    if allowed_here(store, platform) {
        return Vec::new();
    }
    let mut out: Vec<String> = states
        .filter(|(sid, st)| !st.is_deleted() && hidden_when_closed(store, sid, st))
        .map(|(sid, _)| sid.clone())
        .collect();
    out.sort_unstable();
    out
}

/// Dart's push filters for the relay with every hidden server at "nothing", so no
/// wake names one.
pub(crate) fn overlay_push_prefs(prefs_json: &str, hidden: &[String]) -> Option<String> {
    if hidden.is_empty() {
        return Some(prefs_json.to_string());
    }
    let mut prefs = serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(prefs_json).unwrap_or_default();
    for sid in hidden {
        prefs.insert(sid.clone(), serde_json::json!({ "level": "nothing", "channels": {} }));
    }
    serde_json::to_string(&prefs).ok()
}

/// The hidden set the relay last got and the one Dart last heard, kept apart so a
/// resend of the filters never swallows a move Dart has not heard.
#[derive(Default)]
pub(crate) struct Sent {
    relay: Option<Vec<String>>,
    told: Option<Vec<String>>,
    /// The view of the flags the relay last got with the filters.
    view: Option<(i64, i64)>,
}

/// The push filters for the relay with this device's own `~sib` terms.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct PrefsOut {
    pub json: String,
    /// This phone's own yes: it does not follow its siblings' marks.
    pub sib_local: bool,
    /// The (`at`, `set_at`) view a phone has caught up to: the relay lifts the marks its
    /// siblings set at or below it, as the filters already mute what this phone hides.
    pub sib_view: Option<(i64, i64)>,
}

impl Sent {
    /// [`Sent::step`] on the node's database; the bool is `allowed_here` once Dart must
    /// hear `AgeGateChanged`.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn due(
        &mut self,
        db_path: &str,
        db_passphrase: &str,
        server_states: &super::types::ServerStates,
        local_master: &str,
        dart_prefs: Option<&str>,
        force: bool,
        tell_dart: bool,
    ) -> (Option<PrefsOut>, Option<bool>) {
        let platform = Platform::current();
        let Ok(store) = MessageStore::lease(db_path, db_passphrase) else { return (None, None) };
        let hidden = hidden_servers(&store, platform, server_states.iter());
        let view = (platform != Platform::Desktop)
            .then(|| {
                let (at, set_at, _) = view_stamps(&store, server_states.iter(), local_master);
                stamps_for_relay(at, set_at, super::relay_clock::now_ms())
            })
            .flatten();
        let force = force || (view.is_some() && view != self.view);
        let (prefs, moved) = self.step(hidden, dart_prefs, force, tell_dart);
        let prefs = prefs.map(|json| {
            self.view = view;
            // Only this phone's own yes lifts its siblings' marks for it, never a computer's.
            PrefsOut { json, sib_local: local_allowed(&store, platform), sib_view: view }
        });
        (prefs, moved.then(|| allowed_here(&store, platform)))
    }

    /// The push filters to send now (Dart's own, hidden servers muted) when the hidden
    /// set moved since the relay's copy or `force`, and whether a `tell_dart` caller
    /// must report a move since Dart last heard. Nothing goes before Dart's own prefs:
    /// the relay replaces the whole filter set, `~dm` mutes included.
    fn step(&mut self, hidden: Vec<String>, dart_prefs: Option<&str>, force: bool, tell_dart: bool) -> (Option<String>, bool) {
        let moved = tell_dart && self.told.as_ref().is_some_and(|before| *before != hidden);
        if tell_dart || self.told.is_none() {
            self.told = Some(hidden.clone());
        }
        let Some(dart_prefs) = dart_prefs else { return (None, moved) };
        if !force && self.relay.as_ref() == Some(&hidden) {
            return (None, moved);
        }
        let first = self.relay.is_none();
        let prefs = if first && !force && hidden.is_empty() { None } else { overlay_push_prefs(dart_prefs, &hidden) };
        self.relay = Some(hidden);
        (prefs, moved)
    }
}

/// What a computer tells the relay to silence on its siblings (`mute_siblings`): the
/// flagged servers our identity holds while its phones hide them, none once they show.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct SiblingMute {
    pub at: i64,
    pub set_at: i64,
    pub servers: Vec<String>,
}

/// How far ahead of the relay's clock it takes a stamp (`sib_mute.h` MAX_FUTURE_MS).
const RELAY_FUTURE_MS: i64 = 10 * 60 * 1000;
/// Kept back from that bound for our reading of the relay's clock.
const RELAY_FUTURE_SLACK_MS: i64 = 30_000;

/// The view of the flags this device holds, as the relay orders it: the choice's stamp
/// (never chosen = closed, the oldest choice) and the newest clock among the `is_nsfw`
/// registers of the servers we hold and our own admission to each. Data only, so two
/// devices with the same view stamp it alike and a staler view never stamps it newer.
pub(crate) fn view_stamps<'a>(
    store: &MessageStore,
    states: impl Iterator<Item = (&'a String, &'a ServerState)>,
    local_master: &str,
) -> (i64, i64, Vec<&'a String>) {
    let at = held(store).map_or(1, |e| e.at).max(1);
    let ms = |physical: u64| i64::try_from(physical).unwrap_or(i64::MAX);
    let mut set_at = 1;
    let mut flagged = Vec::new();
    for (sid, state) in states {
        if !state.members.contains_key(local_master) || !crate::crdt::anchor::valid_server_id(sid) {
            continue;
        }
        if let Some(reg) = state.settings.get("is_nsfw") {
            set_at = set_at.max(ms(reg.hlc().physical_ms));
        }
        if let Some(span) = state.member_record.get(local_master).and_then(|spans| spans.last()) {
            set_at = set_at.max(ms(span.from_ms));
        }
        if state.is_nsfw() {
            flagged.push(sid);
        }
    }
    (at, set_at, flagged)
}

/// The [`SiblingMute`] this computer stands behind now; phones send none.
pub(crate) fn sibling_mute<'a>(
    store: &MessageStore,
    platform: Platform,
    states: impl Iterator<Item = (&'a String, &'a ServerState)>,
    local_master: &str,
) -> Option<SiblingMute> {
    if platform != Platform::Desktop {
        return None;
    }
    let (at, set_at, flagged) = view_stamps(store, states, local_master);
    let mut servers: Vec<String> =
        if held(store).is_some_and(|e| e.allow) { Vec::new() } else { flagged.into_iter().cloned().collect() };
    servers.sort();
    servers.truncate(MAX_SIB_SERVERS);
    Some(SiblingMute { at, set_at, servers })
}

/// The (`at`, `set_at`) pair as the relay at `relay_now_ms` takes it: a register clocked
/// ahead (a server's future op) counts as now plus the drift the CRDT allows, and a choice
/// stamped past what the relay accepts sends nothing yet, so the caller tries again later.
pub(crate) fn stamps_for_relay(at: i64, set_at: i64, relay_now_ms: i64) -> Option<(i64, i64)> {
    if at > relay_now_ms.saturating_add(RELAY_FUTURE_MS - RELAY_FUTURE_SLACK_MS) {
        return None;
    }
    let ahead = i64::try_from(crate::crdt::hlc::MAX_DRIFT_MS).unwrap_or(i64::MAX);
    Some((at, set_at.min(relay_now_ms.saturating_add(ahead)).max(1)))
}

/// [`stamps_for_relay`] for a whole frame.
pub(crate) fn frame_for_relay(mute: &SiblingMute, relay_now_ms: i64) -> Option<SiblingMute> {
    let (at, set_at) = stamps_for_relay(mute.at, mute.set_at, relay_now_ms)?;
    Some(SiblingMute { at, set_at, servers: mute.servers.clone() })
}

/// Share the identity's choice we hold with every other device of ours, an away one
/// through our inbox. Only a computer shares what it authored.
pub(crate) fn share_with_own_devices(
    ws_cmd_tx: &super::types::WsCmdTx,
    ws_room_peers: &super::types::WsRoomPeers,
    local_master: &str,
    local_device: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    if Platform::current() != Platform::Desktop {
        return;
    }
    let Some(entry) = MessageStore::lease(db_path, db_passphrase).ok().and_then(|s| held(&s)) else { return };
    let sent = super::olm_lane::carry_to_every_own_device(
        ws_cmd_tx, ws_room_peers, local_master, local_device, &super::types::HavenMessage::AgeGateSync { entry },
    );
    hollow_log!("[HOLLOW-AGEGATE] Shared the phones' age-restricted choice ({}) with {sent} device(s) of ours", entry.allow);
}

/// The choice we hold, for one sibling we just verified (through our inbox, so an
/// away one gets it on return).
pub(crate) fn share_with_sibling(
    ws_cmd_tx: &super::types::WsCmdTx,
    sibling: &str,
    local_master: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    let Some(entry) = MessageStore::lease(db_path, db_passphrase).ok().and_then(|s| held(&s)) else { return };
    let own_inbox = format!("inbox:{local_master}");
    super::olm_lane::carry(
        ws_cmd_tx, sibling, Some(&own_inbox), &super::types::HavenMessage::AgeGateSync { entry },
        super::olm_lane::NoSession::Queue,
    );
}

/// What a phone shows once everything the relay held for it arrived; nothing on a
/// computer, which holds nothing back.
pub(crate) fn settled_allowed_at(db_path: &str, db_passphrase: &str) -> Option<bool> {
    let platform = Platform::current();
    if platform == Platform::Desktop {
        return None;
    }
    MessageStore::lease(db_path, db_passphrase).ok().map(|store| allowed_here(&store, platform))
}

/// Take a sibling's [`AgeGateSync`]: `Some(allowed here)` when this device's view moved.
pub(crate) fn take_sibling_at(
    sender: &str,
    local_master: &str,
    entry: AgeGateEntry,
    frame_ts_ms: i64,
    db_path: &str,
    db_passphrase: &str,
) -> Option<bool> {
    if !super::resolver::is_own_unrevoked_device(sender, local_master) {
        hollow_log!("[HOLLOW-SECURITY] Dropped an age-restricted choice from {sender}, not a device of ours");
        return None;
    }
    let store = MessageStore::lease(db_path, db_passphrase).ok()?;
    let ceiling = super::frame_auth::stamp_ceiling(frame_ts_ms);
    take_sibling(&store, entry, ceiling, super::types::now_ms())?;
    Some(allowed_here(&store, Platform::current()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::admin_lww::AdminLwwReg;
    use crate::crdt::hlc::HlcTimestamp;

    fn store() -> (crate::test_tmp::TestDir, MessageStore) {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("age.db").to_string_lossy().into_owned();
        let store = MessageStore::open(&path, &"ab".repeat(32)).unwrap();
        (tmp, store)
    }

    fn entry(allow: bool, at: i64) -> AgeGateEntry {
        AgeGateEntry { allow, at }
    }

    const NOW: i64 = 1_800_000_000_000;

    fn server(nsfw: Option<bool>) -> ServerState {
        let mut s = ServerState::new("s".into(), "s".into(), "owner".into());
        if let Some(on) = nsfw {
            s.settings.insert("is_nsfw".into(), AdminLwwReg::new(on.to_string(), HlcTimestamp::zero(""), 0));
        }
        s
    }

    #[test]
    fn agegate_absent_entry_is_closed_on_ios_and_android_open_on_desktop() {
        let (_t, st) = store();
        assert!(allowed_here(&st, Platform::Desktop));
        assert!(!allowed_here(&st, Platform::Ios));
        assert!(!allowed_here(&st, Platform::Android));
        save(&st, entry(true, NOW)).unwrap();
        assert!(allowed_here(&st, Platform::Ios) && allowed_here(&st, Platform::Android));
        save(&st, entry(false, NOW + 1)).unwrap();
        assert!(!allowed_here(&st, Platform::Ios));
    }

    #[test]
    fn agegate_newest_stamp_wins_and_off_wins_a_tie() {
        let ceiling = NOW + 10;
        assert!(outranks(None, entry(true, NOW), ceiling, NOW));
        assert!(outranks(Some(entry(true, NOW)), entry(false, NOW + 1), ceiling, NOW));
        assert!(!outranks(Some(entry(false, NOW + 1)), entry(true, NOW), ceiling, NOW), "an older ON never undoes an OFF");
        assert!(outranks(Some(entry(true, NOW)), entry(false, NOW), ceiling, NOW), "OFF wins a tie");
        assert!(!outranks(Some(entry(false, NOW)), entry(true, NOW), ceiling, NOW), "ON never wins a tie");
        assert!(!outranks(Some(entry(true, NOW)), entry(true, NOW), ceiling, NOW));
        assert!(!outranks(None, entry(true, 0), ceiling, NOW), "an unstamped entry is no claim");
    }

    #[test]
    fn agegate_an_entry_stamped_past_its_frame_is_refused() {
        assert!(!outranks(None, entry(true, NOW + 11), NOW + 10, NOW));
        assert!(!outranks(Some(entry(false, NOW)), entry(true, NOW + 11), NOW + 10, NOW));
        let (_t, st) = store();
        assert_eq!(take_sibling(&st, entry(true, NOW + 11), NOW + 10, NOW), None);
        assert_eq!(held(&st), None, "nothing stored");
    }

    #[test]
    fn agegate_a_planted_row_gives_way_to_a_genuine_entry() {
        let planted = entry(true, super::super::frame_auth::stored_stamp_limit(NOW) + 1);
        assert!(outranks(Some(planted), entry(false, NOW), NOW + 10, NOW));
    }

    #[test]
    fn agegate_take_sibling_stores_the_newest_and_reports_a_change() {
        let (_t, st) = store();
        assert_eq!(take_sibling(&st, entry(true, NOW), NOW + 10, NOW), Some(true));
        assert_eq!(take_sibling(&st, entry(true, NOW + 1), NOW + 10, NOW), None, "newer, same value");
        assert_eq!(held(&st), Some(entry(true, NOW + 1)));
        assert_eq!(take_sibling(&st, entry(false, NOW + 2), NOW + 10, NOW), Some(false));
        assert_eq!(take_sibling(&st, entry(false, NOW + 2), NOW + 10, NOW), None, "a repeat of the same entry");
        assert_eq!(take_sibling(&st, entry(true, NOW + 1), NOW + 10, NOW), None, "older");
        assert_eq!(held(&st), Some(entry(false, NOW + 2)));
    }

    #[test]
    fn agegate_phones_never_author_the_identity_choice() {
        let (_t, st) = store();
        assert!(author(&st, Platform::Ios, true, NOW).is_err());
        assert!(author(&st, Platform::Android, true, NOW).is_err());
        assert_eq!(held(&st), None);
        assert_eq!(author(&st, Platform::Desktop, true, NOW).unwrap(), entry(true, NOW));
        assert_eq!(author(&st, Platform::Desktop, false, NOW - 5).unwrap(), entry(false, NOW + 1), "past the held stamp");
    }

    #[test]
    fn agegate_android_local_toggle_opens_only_android() {
        let (_t, st) = store();
        assert!(set_local(&st, Platform::Ios, true).is_err());
        assert!(set_local(&st, Platform::Desktop, true).is_err());
        st.save_setting(LOCAL_KEY, "true").unwrap();
        assert!(!allowed_here(&st, Platform::Ios), "a planted local key never opens an iPhone");
        st.delete_setting(LOCAL_KEY).unwrap();
        set_local(&st, Platform::Android, true).unwrap();
        assert!(allowed_here(&st, Platform::Android));
        mark_store_install(&st, true).unwrap();
        assert!(!allowed_here(&st, Platform::Android), "a store build behaves like an iPhone");
        assert!(set_local(&st, Platform::Android, true).is_err());
    }

    #[test]
    fn agegate_hidden_servers_fail_closed_until_settled() {
        let (_t, st) = store();
        init_settled(&st, ["old"].into_iter());
        let (unknown, flagged, clean) = (server(None), server(Some(true)), server(Some(false)));
        let sid = |s: &str| s.to_string();
        assert!(hidden(&st, Platform::Ios, "new", &unknown), "a server not caught up hides");
        assert!(!hidden(&st, Platform::Ios, "old", &unknown), "one held before tracking began shows");
        assert!(!hidden(&st, Platform::Ios, "new", &clean), "the register says what it is");
        assert!(hidden(&st, Platform::Ios, "old", &flagged));
        assert!(!hidden(&st, Platform::Desktop, "new", &flagged));
        assert!(note_settled(&st, "new") && !note_settled(&st, "new"));
        assert!(!hidden(&st, Platform::Ios, "new", &unknown));
        unsettle(&st, "new");
        assert!(hidden(&st, Platform::Ios, "new", &unknown), "a new join forgets it");
        let states = [(sid("new"), unknown), (sid("old"), flagged), (sid("x"), clean)];
        assert_eq!(hidden_servers(&st, Platform::Ios, states.iter().map(|(a, b)| (a, b))), vec![sid("new"), sid("old")]);
        save(&st, entry(true, NOW)).unwrap();
        assert!(hidden_servers(&st, Platform::Ios, states.iter().map(|(a, b)| (a, b))).is_empty());
    }

    #[test]
    fn agegate_a_closed_gate_never_sends_nsfw_consent() {
        let (_t, st) = store();
        assert!(!join_consent(&st, Platform::Ios, "s", true), "an iPhone never consents while closed");
        assert!(!join_consent(&st, Platform::Android, "s", true));
        assert!(join_consent(&st, Platform::Desktop, "s", true));
        assert!(!join_consent(&st, Platform::Desktop, "s", false));
        note_consent(&st, Platform::Ios, "s");
        assert!(!consent_held(&st, "s"), "a closed phone keeps no yes");
        assert!(!join_consent(&st, Platform::Ios, "s", false));
        save(&st, entry(true, NOW)).unwrap();
        assert!(join_consent(&st, Platform::Ios, "s", true));
    }

    fn flagged(id: &str, member: &str, nsfw: bool, at_ms: u64) -> (String, ServerState) {
        let mut s = ServerState::new(id.into(), "S".into(), "o".into());
        s.members.insert(member.into(), crate::crdt::server_state::MemberInfo { peer_id: member.into(), display_name: String::new() });
        s.settings.insert(
            "is_nsfw".into(),
            AdminLwwReg::new(nsfw.to_string(), HlcTimestamp { physical_ms: at_ms, counter: 0, actor: "o".into() }, 0),
        );
        (id.into(), s)
    }

    /// A computer names only the flagged servers it holds while its phones hide them, and
    /// stamps its view by the data alone (review M1).
    #[test]
    fn w4_iospush_a_computer_mutes_only_held_flagged_servers_and_stamps_each_move() {
        let (_t, st) = store();
        let me = "me";
        let a = "0123456789abcdef0123456789abcdef01234567";
        let b = "abcdefabcdefabcdefabcdefabcdefab";
        let states = vec![flagged(a, me, true, 10), flagged(b, me, false, 20), flagged("1111111111111111111111111111111111111111", "other", true, 30)];
        let mute = |states: &Vec<(String, ServerState)>| sibling_mute(&st, Platform::Desktop, states.iter().map(|(k, v)| (k, v)), me).unwrap();
        assert_eq!(sibling_mute(&st, Platform::Ios, states.iter().map(|(k, v)| (k, v)), me), None, "a phone mutes nobody");
        let first = mute(&states);
        assert_eq!(first.servers, vec![a.to_string()], "only a flagged server we hold");
        assert_eq!(first.at, 1, "never chosen = closed, the oldest choice");
        assert_eq!(first.set_at, 20, "the newest flag register of a server we hold");
        assert_eq!(mute(&states), first, "an unmoved view keeps its stamp");
        let unflagged = vec![flagged(a, me, false, 40), flagged(b, me, false, 20)];
        let moved = mute(&unflagged);
        assert!(moved.servers.is_empty() && moved.set_at == 40, "an unflag moves the stamp");
        let mut joined = states.clone();
        joined[2].1.members.insert(me.into(), crate::crdt::server_state::MemberInfo { peer_id: me.into(), display_name: String::new() });
        joined[2].1.member_record.insert(me.into(), vec![span(60)]);
        let after_join = mute(&joined);
        assert!(after_join.servers.len() == 2 && after_join.set_at == 60, "our own admission moves the stamp");
        save(&st, entry(true, NOW + 80)).unwrap();
        let on = mute(&states);
        assert!(on.servers.is_empty() && on.at == NOW + 80, "phones showing: nothing muted, the choice's stamp");
    }

    fn span(from_ms: u64) -> crate::crdt::server_state::MemberSpan {
        crate::crdt::server_state::MemberSpan { from_ms, until_ms: u64::MAX, ..Default::default() }
    }

    /// The relay judges both stamps against its own clock: a server's op clocked ahead is
    /// taken as the CRDT's drift ahead of it, and a choice stamped past what it accepts
    /// waits (review MED-2).
    #[test]
    fn w4_iospush_stamps_fit_the_relays_clock_or_wait() {
        let drift = i64::try_from(crate::crdt::hlc::MAX_DRIFT_MS).unwrap();
        assert_eq!(stamps_for_relay(5, 7, NOW), Some((5, 7)));
        assert_eq!(stamps_for_relay(5, NOW + 3_600_000, NOW), Some((5, NOW + drift)), "a future op is clamped");
        assert_eq!(stamps_for_relay(NOW + 9 * 60_000, 7, NOW), Some((NOW + 9 * 60_000, 7)));
        assert_eq!(stamps_for_relay(NOW + 10 * 60_000, 7, NOW), None, "a choice the relay would refuse waits");
        let m = SiblingMute { at: 2, set_at: NOW + 3_600_000, servers: vec!["s".into()] };
        assert_eq!(frame_for_relay(&m, NOW).unwrap().set_at, NOW + drift);
    }

    /// Only a sideloaded Android phone whose own toggle allows tells the relay it does not
    /// follow its siblings' marks; an iPhone or a store build never does (review L3).
    #[test]
    fn w4_iospush_only_a_phones_own_local_yes_lifts_its_siblings_marks() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("due.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        let st = MessageStore::open(&path, &pass).unwrap();
        let states = super::super::types::ServerStates::new();
        let sib_local = |platform| {
            set_test_platform(Some(platform));
            let out = Sent::default().due(&path, &pass, &states, "me", Some("{}"), true, false).0.map(|p| p.sib_local);
            set_test_platform(None);
            out
        };
        assert_eq!(sib_local(Platform::Android), Some(false), "a closed phone follows its siblings");
        st.save_setting(LOCAL_KEY, "true").unwrap();
        assert_eq!(sib_local(Platform::Android), Some(true), "its own local yes");
        assert_eq!(sib_local(Platform::Ios), Some(false), "an iPhone has no local yes");
        st.save_setting(STORE_INSTALL_KEY, "true").unwrap();
        assert_eq!(sib_local(Platform::Android), Some(false), "a store build behaves like an iPhone");
    }

    /// The view's stamp reads no clock: a computer that has not read a flag stamps its
    /// set below one that has, however much later it sends (review MED-1).
    #[test]
    fn w4_iospush_a_later_send_of_an_older_view_stamps_it_no_newer() {
        let (_t1, fresh) = store();
        let (_t2, stale) = store();
        let a = "0123456789abcdef0123456789abcdef01234567";
        let b = "abcdefabcdefabcdefabcdefabcdefab";
        let hour_ago = u64::try_from(super::super::frame_auth::now_ms() - 3_600_000).unwrap();
        let fresh_view = [flagged(a, "me", true, hour_ago), flagged(b, "me", true, hour_ago + 10)];
        let f = sibling_mute(&fresh, Platform::Desktop, fresh_view.iter().map(|(k, v)| (k, v)), "me").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(5));
        let stale_view = [flagged(a, "me", true, hour_ago), flagged(b, "me", false, hour_ago - 10)];
        let s = sibling_mute(&stale, Platform::Desktop, stale_view.iter().map(|(k, v)| (k, v)), "me").unwrap();
        assert!(s.set_at < f.set_at, "the later send of an older view outranks the fresher one");
    }

    /// A phone hands the relay the view it caught up to whenever that view moves, its
    /// hidden set unmoved or not, so marks it has passed are lifted (review LOW-8).
    #[test]
    fn w4_iospush_a_phone_tells_the_relay_each_view_it_catches_up_to() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("view.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        let _st = MessageStore::open(&path, &pass).unwrap();
        let a = "0123456789abcdef0123456789abcdef01234567";
        let mut states = super::super::types::ServerStates::new();
        let (id, s) = flagged(a, "me", false, 40);
        states.insert(id, s);
        set_test_platform(Some(Platform::Ios));
        let mut sent = Sent::default();
        let mut due = |states: &super::super::types::ServerStates| sent.due(&path, &pass, states, "me", Some("{}"), false, true).0;
        let first = due(&states).map(|p| p.sib_view);
        let again = due(&states);
        let (id, s) = flagged(a, "me", false, 50);
        states.insert(id, s);
        let moved = due(&states).map(|p| p.sib_view);
        set_test_platform(None);
        assert_eq!(first, Some(Some((1, 40))), "the first view goes out");
        assert_eq!(again, None, "an unmoved view is not sent again");
        assert_eq!(moved, Some(Some((1, 50))), "a moved view goes out though nothing new is hidden");
    }

    /// A rejoin carries the 18+ yes only where THIS device gave it for THAT server.
    #[test]
    fn w4_iospush_a_join_carries_only_the_consent_this_device_holds() {
        let (_t, st) = store();
        assert!(!join_consent(&st, Platform::Desktop, "adult", false));
        note_consent(&st, Platform::Desktop, "adult");
        assert!(join_consent(&st, Platform::Desktop, "adult", false), "a yes given here before");
        assert!(!join_consent(&st, Platform::Desktop, "other", false), "a yes is per server");
        assert!(!join_consent(&st, Platform::Ios, "adult", false), "a closed gate outranks any yes");
    }

    #[test]
    fn agegate_hidden_servers_are_muted_at_the_relay() {
        assert_eq!(overlay_push_prefs("{}", &[]).as_deref(), Some("{}"));
        let out = overlay_push_prefs(r#"{"a":{"level":"mentions","channels":{}}}"#, &["s".into()]).unwrap();
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["s"]["level"], "nothing");
        assert_eq!(v["a"]["level"], "mentions");
    }

    fn level_of(prefs: &str, sid: &str) -> serde_json::Value {
        serde_json::from_str::<serde_json::Value>(prefs).unwrap()[sid]["level"].clone()
    }

    #[test]
    fn agegate_a_move_seen_by_a_prefs_resend_still_reaches_dart() {
        let mut sent = Sent::default();
        let prefs = Some("{}");
        assert_eq!(sent.step(vec![], prefs, true, false), (Some("{}".into()), false), "Dart's first prefs, the baseline");
        let (resend, moved) = sent.step(vec!["s".into()], prefs, true, false);
        assert_eq!(level_of(&resend.unwrap(), "s"), "nothing", "a resend mutes the newly hidden server");
        assert!(!moved, "a caller that tells Dart nothing reports no move");
        assert_eq!(sent.step(vec!["s".into()], prefs, false, true), (None, true), "the next tick still tells Dart");
        assert_eq!(sent.step(vec!["s".into()], prefs, false, true), (None, false), "and only once");
        let (_, moved) = sent.step(vec![], prefs, true, false);
        assert!(!moved);
        assert_eq!(sent.step(vec![], prefs, false, true), (None, true), "the server settling shows again");
    }

    #[test]
    fn agegate_no_overlay_is_sent_before_darts_prefs() {
        let mut sent = Sent::default();
        assert_eq!(sent.step(vec!["s".into()], None, false, true), (None, false), "a tick before Dart's prefs");
        assert_eq!(sent.step(vec!["s".into()], None, true, false), (None, false), "a reconnect before Dart's prefs");
        let dart = r#"{"~dm":{"level":"nothing","channels":{"d1":"nothing"}}}"#;
        let (first, _) = sent.step(vec!["s".into()], Some(dart), true, false);
        let first = first.expect("Dart's prefs carry the overlay");
        assert_eq!(level_of(&first, "s"), "nothing");
        assert_eq!(level_of(&first, "~dm"), "nothing", "the DM mutes survive");
        assert_eq!(sent.step(vec!["s".into()], Some(dart), false, true), (None, false), "the relay holds it already");
    }

    #[test]
    fn agegate_a_sideloaded_start_after_a_store_install_gets_its_toggle_back() {
        let (_t, st) = store();
        assert!(!mark_store_install(&st, false).unwrap(), "a sideload start changes nothing");
        set_local(&st, Platform::Android, true).unwrap();
        assert!(mark_store_install(&st, true).unwrap());
        assert!(!mark_store_install(&st, true).unwrap(), "the same mark again is no change");
        assert!(!allowed_here(&st, Platform::Android) && set_local(&st, Platform::Android, true).is_err());
        assert!(mark_store_install(&st, false).unwrap(), "a sideload start lifts the mark");
        assert!(!allowed_here(&st, Platform::Android), "the toggle comes back off");
        set_local(&st, Platform::Android, true).unwrap();
        assert!(allowed_here(&st, Platform::Android));
    }

    // rv-iospush (review RED tests)

    /// Two computers of one identity: the one that has not read a flag yet must never
    /// outrank the one that has, or its smaller set opens that server's wakes (review M1).
    #[test]
    fn rv_iospush_a_computer_with_an_older_view_never_outranks_a_fresher_one() {
        let (_t1, fresh) = store();
        let (_t2, stale) = store();
        let a = "0123456789abcdef0123456789abcdef01234567";
        let b = "abcdefabcdefabcdefabcdefabcdefab";
        let ms = |t: i64| u64::try_from(t).unwrap();
        let fresh_view = [flagged(a, "me", true, ms(NOW - 1000)), flagged(b, "me", true, ms(NOW - 10))];
        let f = sibling_mute(&fresh, Platform::Desktop, fresh_view.iter().map(|(k, v)| (k, v)), "me").unwrap();
        let stale_view = [flagged(a, "me", true, ms(NOW - 1000)), flagged(b, "me", false, ms(NOW - 5000))];
        let s = sibling_mute(&stale, Platform::Desktop, stale_view.iter().map(|(k, v)| (k, v)), "me").unwrap();
        assert_eq!(s.at, f.at);
        assert!(!s.servers.contains(&b.to_string()));
        assert!(s.set_at <= f.set_at, "a computer that has not read a flag outranks one that has");
    }

    /// A computer whose clock runs an hour slow reads a new flag: its set must outrank
    /// the older set another computer sent, or the flagged server wakes a sleeping phone.
    #[test]
    fn rv_iospush_a_slow_clock_computer_still_carries_a_new_flag() {
        let (_t1, ok) = store();
        let (_t2, slow) = store();
        let a = "0123456789abcdef0123456789abcdef01234567";
        let b = "abcdefabcdefabcdefabcdefabcdefab";
        let ms = |t: i64| u64::try_from(t).unwrap();
        let before = [flagged(a, "me", true, ms(NOW - 1000)), flagged(b, "me", false, ms(NOW - 900))];
        let first = sibling_mute(&ok, Platform::Desktop, before.iter().map(|(k, v)| (k, v)), "me").unwrap();
        let _ = sibling_mute(&slow, Platform::Desktop, before.iter().map(|(k, v)| (k, v)), "me");
        let after = [flagged(a, "me", true, ms(NOW - 1000)), flagged(b, "me", true, ms(NOW + 1000))];
        let next = sibling_mute(&slow, Platform::Desktop, after.iter().map(|(k, v)| (k, v)), "me").unwrap();
        assert!(next.servers.contains(&b.to_string()));
        assert!(next.set_at > first.set_at, "the relay keeps the older set: the new flag never reaches the sleeping phone");
    }
}
