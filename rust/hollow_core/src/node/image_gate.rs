//! The one door a peer's image passes before any native decoder sees it (AR-28): the
//! pure-Rust check of [`super::image_check`], once per exact bytes, its verdict kept in
//! `image_verdicts` so a render path never decodes twice.
//!
//! Every surface that hands peer image bytes to Dart (or to the overlay's browser
//! source) without a tap asks here first and shows its honest fallback on `false`.

use std::sync::mpsc;
use std::collections::HashSet;
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::Duration;

use super::image_check::{self, Budget, Facts, Refusal, RULE};
use crate::storage::MessageStore;

/// Checks running at once: each may hold a few hundred MB of decoded pixels.
const MAX_RUNNING: usize = 2;
/// How long a caller waits for a free slot before giving up for now.
pub(crate) const SLOT_WAIT: Duration = Duration::from_secs(60);
/// Slack past the check's own deadline before the caller stops waiting on its thread.
const JOIN_SLACK: Duration = Duration::from_secs(5);

/// How one bounded run ended.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Outcome {
    Pass(Facts),
    Refused(Refusal),
    /// No slot or no thread: says nothing about the bytes, so it is never kept.
    Busy,
}

/// Hex SHA-256 of `bytes`, the key a verdict is kept under.
pub(crate) fn digest(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(bytes))
}

fn slots() -> &'static (Mutex<usize>, Condvar) {
    static SLOTS: OnceLock<(Mutex<usize>, Condvar)> = OnceLock::new();
    SLOTS.get_or_init(|| (Mutex::new(0), Condvar::new()))
}

struct Slot;

impl Slot {
    fn take(wait: Duration) -> Option<Slot> {
        let (lock, cvar) = slots();
        let guard = lock.lock().ok()?;
        let (mut running, timeout) = cvar.wait_timeout_while(guard, wait, |n| *n >= MAX_RUNNING).ok()?;
        if timeout.timed_out() && *running >= MAX_RUNNING {
            return None;
        }
        *running += 1;
        Some(Slot)
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        let (lock, cvar) = slots();
        if let Ok(mut running) = lock.lock() {
            *running = running.saturating_sub(1);
        }
        cvar.notify_one();
    }
}

/// The check on a thread of its own, at most [`MAX_RUNNING`] at once, waiting at most
/// `slot_wait` for a slot. A decoder that never returns keeps only its own slot; the
/// caller stops waiting at the deadline.
pub(crate) fn run_bounded(bytes: &[u8], slot_wait: Duration) -> Outcome {
    run_on_thread(bytes, Budget::PEER, slot_wait, JOIN_SLACK, image_check::check_with)
}

#[cfg(test)]
fn run_bounded_with(bytes: &[u8], budget: Budget) -> Outcome {
    run_on_thread(bytes, budget, SLOT_WAIT, JOIN_SLACK, image_check::check_with)
}

fn run_on_thread(
    bytes: &[u8],
    budget: Budget,
    slot_wait: Duration,
    slack: Duration,
    check: fn(&[u8], &Budget) -> Result<Facts, Refusal>,
) -> Outcome {
    let Some(slot) = Slot::take(slot_wait) else {
        return Outcome::Busy;
    };
    let owned = bytes.to_vec();
    let (tx, rx) = mpsc::channel();
    let spawned = std::thread::Builder::new().name("image-check".into()).spawn(move || {
        let _slot = slot;
        let _ = tx.send(check(&owned, &budget));
    });
    if spawned.is_err() {
        return Outcome::Busy;
    }
    match rx.recv_timeout(budget.max_time + slack) {
        Ok(Ok(facts)) => Outcome::Pass(facts),
        Ok(Err(refusal)) => Outcome::Refused(refusal),
        Err(mpsc::RecvTimeoutError::Timeout) => Outcome::Refused(Refusal::OverTime),
        Err(mpsc::RecvTimeoutError::Disconnected) => Outcome::Refused(Refusal::Panicked),
    }
}

/// What a surface may do with an image now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Verdict {
    Pass,
    Refused,
    /// Not judged yet (no slot, or another thread is checking these bytes): show the
    /// loading state, never the refusal, and re-read later.
    NotYet,
}

/// Stored verdict codes (`image_verdicts.ok`).
pub(crate) const CODE_REFUSED: i64 = 0;
pub(crate) const CODE_PASS: i64 = 1;
/// Written BEFORE a decode: a check the OS killed mid-way (jetsam, the low-memory
/// killer) reads as a refusal at the next start instead of a crash loop.
pub(crate) const CODE_CHECKING: i64 = 2;
/// A wall-clock refusal, which depends on the device and its load: it holds a day,
/// then the bytes are checked again. Only deterministic refusals are kept for good.
pub(crate) const CODE_TIMED_OUT: i64 = 3;
const TIMED_OUT_HOLDS_MS: i64 = 24 * 60 * 60 * 1000;

/// Slot wait for a caller on Flutter's FFI pool: it must never park there.
pub(crate) const FFI_SLOT_WAIT: Duration = Duration::from_millis(250);

fn in_flight() -> &'static Mutex<HashSet<String>> {
    static SET: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    SET.get_or_init(Default::default)
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// How a stored row reads now; `None` = check again.
fn read_row(hash: &str, code: i64, checked_at: i64) -> Option<Verdict> {
    match code {
        CODE_PASS => Some(Verdict::Pass),
        CODE_REFUSED => Some(Verdict::Refused),
        CODE_CHECKING if in_flight().lock().is_ok_and(|f| f.contains(hash)) => Some(Verdict::NotYet),
        CODE_CHECKING => Some(Verdict::Refused),
        CODE_TIMED_OUT if now_ms() - checked_at < TIMED_OUT_HOLDS_MS => Some(Verdict::Refused),
        _ => None,
    }
}

/// The verdict on `bytes`: a kept one, else a fresh check. `record(hash, Some(code))`
/// keeps a code, `record(hash, None)` forgets the row (a check that said nothing).
pub(crate) fn judge_with(
    bytes: &[u8],
    slot_wait: Duration,
    lookup: impl FnOnce(&str) -> Option<(i64, i64)>,
    mut record: impl FnMut(&str, Option<i64>),
) -> Verdict {
    let hash = digest(bytes);
    if let Some(v) = lookup(&hash).and_then(|(code, at)| read_row(&hash, code, at)) {
        return v;
    }
    if !in_flight().lock().is_ok_and(|mut f| f.insert(hash.clone())) {
        return Verdict::NotYet;
    }
    record(&hash, Some(CODE_CHECKING));
    let verdict = match run_bounded(bytes, slot_wait) {
        Outcome::Pass(_) => {
            record(&hash, Some(CODE_PASS));
            Verdict::Pass
        }
        Outcome::Refused(why) => {
            hollow_log!("[HOLLOW-SECURITY] Refused a peer image {}: it {why}", &hash[..12]);
            let code = if why == Refusal::OverTime { CODE_TIMED_OUT } else { CODE_REFUSED };
            record(&hash, Some(code));
            Verdict::Refused
        }
        Outcome::Busy => {
            record(&hash, None);
            Verdict::NotYet
        }
    };
    if let Ok(mut f) = in_flight().lock() {
        f.remove(&hash);
    }
    verdict
}

/// [`judge_with`] against a store this caller holds.
pub(crate) fn judge_in(store: &MessageStore, bytes: &[u8], slot_wait: Duration) -> Verdict {
    judge_with(bytes, slot_wait, |h| store.image_verdict(h, RULE), |h, code| match code {
        Some(code) => {
            let _ = store.record_image_verdict(h, code, RULE);
        }
        None => store.forget_image_verdict(h),
    })
}

/// [`judge_with`] against the app's shared store, locked only around the lookup and
/// the record, never across the decode. The caller must not hold that lock.
pub(crate) fn judge_shared(bytes: &[u8], slot_wait: Duration) -> Verdict {
    let store = crate::api::storage::get_store();
    judge_with(
        bytes,
        slot_wait,
        |h| store.lock().ok()?.as_ref()?.image_verdict(h, RULE),
        |h, code| {
            if let Ok(guard) = store.lock()
                && let Some(ms) = guard.as_ref()
            {
                match code {
                    Some(code) => {
                        let _ = ms.record_image_verdict(h, code, RULE);
                    }
                    None => ms.forget_image_verdict(h),
                }
            }
        },
    )
}

/// Whether a stored verdict refuses `hash` now, without decoding anything.
pub(crate) fn is_refused(store: &MessageStore, hash: &str) -> bool {
    store
        .image_verdict(hash, RULE)
        .and_then(|(code, at)| read_row(hash, code, at))
        == Some(Verdict::Refused)
}

/// The verdict for a caller on Flutter's FFI pool: a short slot wait, and when that
/// is not enough, a check on a thread of our own that tells Dart to re-read.
pub(crate) fn judge_for_ffi(bytes: &[u8]) -> Verdict {
    let verdict = judge_shared(bytes, FFI_SLOT_WAIT);
    if verdict == Verdict::NotYet {
        recheck_later(bytes.to_vec());
    }
    verdict
}

fn rechecking() -> &'static Mutex<HashSet<String>> {
    static SET: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    SET.get_or_init(Default::default)
}

fn recheck_later(bytes: Vec<u8>) {
    let hash = digest(&bytes);
    if !rechecking().lock().is_ok_and(|mut r| r.insert(hash.clone())) {
        return;
    }
    let ours = hash.clone();
    let spawned = std::thread::Builder::new().name("image-recheck".into()).spawn(move || {
        let hash = ours;
        let deadline = std::time::Instant::now() + SLOT_WAIT + Budget::PEER.max_time;
        while judge_shared(&bytes, SLOT_WAIT) == Verdict::NotYet && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(500));
        }
        if let Ok(mut r) = rechecking().lock() {
            r.remove(&hash);
        }
        let _ = crate::api::network::send_node_command(crate::node::NodeCommand::ImagesRechecked { hashes: vec![hash] });
    });
    if spawned.is_err()
        && let Ok(mut r) = rechecking().lock()
    {
        r.remove(&hash);
    }
}

/// `bytes` when they pass, else `None` (refused or not judged yet): the shape of
/// every optional image field crossing to Dart.
pub(crate) fn shown(bytes: Option<Vec<u8>>) -> Option<Vec<u8>> {
    bytes.filter(|b| judge_for_ffi(b) == Verdict::Pass)
}

/// A rail blob as Dart may paint it: `None` = not held yet or not judged yet (a
/// re-check event follows), `Some(empty)` = the image check refused it (show the
/// fallback, never pull again), else the stored bytes unchanged, which passed.
pub(crate) fn rail_blob_shown(hash: &str) -> Result<Option<Vec<u8>>, String> {
    let store = crate::api::storage::get_store();
    let (bytes, refused) = {
        let guard = store.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        let ms = guard.as_ref().ok_or("Message store is not open")?;
        (ms.load_emote_blob(hash)?, is_refused(ms, hash))
    };
    Ok(match bytes {
        None if refused => Some(Vec::new()),
        None => None,
        Some(b) => match judge_for_ffi(&b) {
            Verdict::Pass => Some(b),
            Verdict::Refused => Some(Vec::new()),
            Verdict::NotYet => None,
        },
    })
}

/// A guest event with every stranger image checked, inside one budget for the whole
/// event: what is not judged in time leaves as `None`. Runs off the node loop and
/// off the event forwarder, so a page of hostile avatars delays only itself.
pub(crate) fn guest_event_checked(event: crate::node::NetworkEvent) -> crate::node::NetworkEvent {
    use crate::node::NetworkEvent as E;
    let deadline = std::time::Instant::now() + GUEST_EVENT_BUDGET;
    let check = |bytes: Option<Vec<u8>>| {
        let wait = deadline.saturating_duration_since(std::time::Instant::now());
        bytes.filter(|b| !wait.is_zero() && judge_shared(b, wait) == Verdict::Pass)
    };
    match event {
        E::PublicChannelListReceived { server_id, server_name, channels, server_avatar, server_banner_thumb } => {
            E::PublicChannelListReceived {
                server_id,
                server_name,
                channels,
                server_avatar: check(server_avatar),
                server_banner_thumb: check(server_banner_thumb),
            }
        }
        E::PublicChannelSyncReceived { server_id, channel_id, messages, has_more, mut sender_profiles } => {
            for profile in &mut sender_profiles {
                profile.avatar = check(profile.avatar.take());
            }
            E::PublicChannelSyncReceived { server_id, channel_id, messages, has_more, sender_profiles }
        }
        other => other,
    }
}

/// What checking one guest event's images may take before the rest go out unpainted.
const GUEST_EVENT_BUDGET: Duration = Duration::from_secs(20);

/// Emit a guest event once its images are checked, from a task of its own.
pub(crate) fn emit_guest_event(event_tx: &tokio::sync::mpsc::Sender<crate::node::NetworkEvent>, event: crate::node::NetworkEvent) {
    let tx = event_tx.clone();
    tokio::spawn(async move {
        if let Ok(event) = tokio::task::spawn_blocking(move || guest_event_checked(event)).await {
            let _ = tx.send(event).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png(w: u32, h: u32) -> Vec<u8> {
        let img = image::RgbaImage::from_pixel(w, h, image::Rgba([10, 200, 30, 255]));
        let mut out = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Png).unwrap();
        out
    }

    #[test]
    fn a_decoder_that_outlasts_the_deadline_is_a_refusal_not_a_wait() {
        let mut slow = Budget::PEER;
        slow.max_time = Duration::ZERO;
        let gif = {
            let mut out = Vec::new();
            {
                let mut enc = image::codecs::gif::GifEncoder::new(&mut out);
                for _ in 0..3 {
                    enc.encode_frame(image::Frame::new(image::RgbaImage::new(8, 8))).unwrap();
                }
            }
            out
        };
        assert_eq!(run_bounded_with(&gif, slow), Outcome::Refused(Refusal::OverTime));
        assert!(matches!(run_bounded(&png(4, 4), SLOT_WAIT), Outcome::Pass(_)));
    }

    /// A decoder stuck inside one frame never answers: the caller gives up at the
    /// deadline and calls it a refusal, it never waits on the thread.
    #[test]
    fn a_decoder_that_never_returns_is_a_refusal_at_the_deadline() {
        fn stuck(_: &[u8], _: &Budget) -> Result<Facts, Refusal> {
            std::thread::sleep(Duration::from_secs(3));
            Err(Refusal::Empty)
        }
        let mut budget = Budget::PEER;
        budget.max_time = Duration::from_millis(50);
        let started = std::time::Instant::now();
        let outcome = run_on_thread(&png(2, 2), budget, SLOT_WAIT, Duration::from_millis(100), stuck);
        assert_eq!(outcome, Outcome::Refused(Refusal::OverTime));
        assert!(started.elapsed() < Duration::from_secs(2), "the caller waited on the thread");
    }

    /// A kept verdict answers without decoding; a fresh one is kept either way, and a
    /// provisional "checking" row is written before the decode starts.
    #[test]
    fn a_verdict_is_kept_and_reused() {
        let good = png(6, 6);
        let mut bad = good.clone();
        bad.truncate(30);

        let mut kept: Vec<(String, Option<i64>)> = Vec::new();
        let mut keep = |h: &str, c: Option<i64>| kept.push((h.to_string(), c));
        assert_eq!(judge_with(&good, SLOT_WAIT, |_| None, &mut keep), Verdict::Pass);
        assert_eq!(judge_with(&bad, SLOT_WAIT, |_| None, &mut keep), Verdict::Refused);
        assert_eq!(
            kept,
            vec![
                (digest(&good), Some(CODE_CHECKING)),
                (digest(&good), Some(CODE_PASS)),
                (digest(&bad), Some(CODE_CHECKING)),
                (digest(&bad), Some(CODE_REFUSED)),
            ]
        );

        // The kept answer wins over the bytes, so nothing is decoded twice.
        let no_record = |_: &str, _: Option<i64>| panic!("a hit records nothing");
        assert_eq!(judge_with(&good, SLOT_WAIT, |_| Some((CODE_REFUSED, now_ms())), no_record), Verdict::Refused);
        assert_eq!(judge_with(&bad, SLOT_WAIT, |_| Some((CODE_PASS, now_ms())), no_record), Verdict::Pass);
    }

    /// A check the OS killed mid-way left "checking" behind: at the next start that
    /// reads as a refusal, never as a reason to decode the same bytes again.
    #[test]
    fn a_check_killed_mid_way_is_a_refusal_after_restart() {
        let good = png(5, 5);
        let no_record = |_: &str, _: Option<i64>| panic!("a crash leftover records nothing");
        assert_eq!(judge_with(&good, SLOT_WAIT, |_| Some((CODE_CHECKING, 1)), no_record), Verdict::Refused);
    }

    /// A wall-clock refusal holds a day, then the bytes are checked again.
    #[test]
    fn a_timed_out_refusal_expires() {
        let good = png(4, 3);
        let no_record = |_: &str, _: Option<i64>| panic!("a fresh timeout records nothing");
        assert_eq!(judge_with(&good, SLOT_WAIT, |_| Some((CODE_TIMED_OUT, now_ms())), no_record), Verdict::Refused);
        let mut kept = Vec::new();
        let stale = now_ms() - TIMED_OUT_HOLDS_MS - 1;
        assert_eq!(judge_with(&good, SLOT_WAIT, |_| Some((CODE_TIMED_OUT, stale)), |_, c| kept.push(c)), Verdict::Pass);
        assert_eq!(kept, vec![Some(CODE_CHECKING), Some(CODE_PASS)]);
    }

    /// No slot is not a refusal: nothing is kept and the surface shows "not yet".
    #[test]
    fn a_busy_check_is_not_yet_and_keeps_nothing() {
        // Holds every slot: never beside a test that needs one within the FFI wait.
        let _l = crate::api::storage::store_test_lock();
        let held: Vec<Slot> = (0..MAX_RUNNING).filter_map(|_| Slot::take(SLOT_WAIT)).collect();
        assert_eq!(held.len(), MAX_RUNNING);
        let mut kept = Vec::new();
        let v = judge_with(&png(3, 7), Duration::from_millis(20), |_| None, |_, c| kept.push(c));
        drop(held);
        assert_eq!(v, Verdict::NotYet);
        assert_eq!(kept, vec![Some(CODE_CHECKING), None], "the provisional row is forgotten");
    }

    /// A caller on Flutter's FFI pool waits a moment for a slot, never the minute a
    /// background caller may: it gets "not yet" and a re-check follows.
    #[test]
    fn an_ffi_caller_never_parks_waiting_for_a_slot() {
        // Holds every slot: never beside a test that needs one within the FFI wait.
        let _l = crate::api::storage::store_test_lock();
        let held: Vec<Slot> = (0..MAX_RUNNING).filter_map(|_| Slot::take(SLOT_WAIT)).collect();
        let started = std::time::Instant::now();
        let v = judge_for_ffi(&png(9, 2));
        let waited = started.elapsed();
        drop(held);
        assert_eq!(v, Verdict::NotYet);
        assert!(waited < Duration::from_secs(2), "an FFI caller waited {waited:?} for a slot");
    }

    #[test]
    fn verdicts_persist_per_rule_in_the_store() {
        let store = MessageStore::open(":memory:", &"ab".repeat(32)).unwrap();
        let bad = b"\x89PNG\r\n\x1a\nnot really".to_vec();
        assert_eq!(judge_in(&store, &bad, SLOT_WAIT), Verdict::Refused);
        assert_eq!(store.image_verdict(&digest(&bad), RULE).map(|r| r.0), Some(CODE_REFUSED));
        assert_eq!(store.image_verdict(&digest(&bad), RULE + 1), None, "another rule checks again");
        assert!(is_refused(&store, &digest(&bad)));
        let good = png(3, 3);
        assert_eq!(judge_in(&store, &good, SLOT_WAIT), Verdict::Pass);
        assert_eq!(store.image_verdict(&digest(&good), RULE).map(|r| r.0), Some(CODE_PASS));
        store.forget_image_verdict(&digest(&good));
        assert_eq!(store.image_verdict(&digest(&good), RULE), None);
    }
}

/// Each Dart crossing on its own: an undecodable image never crosses, a valid one
/// crosses byte-identical. Kept apart per crossing so a mutation at any one fails here.
#[cfg(test)]
mod crossing_tests {
    use super::*;
    use crate::api::storage::{set_test_store, store_test_lock};

    fn good() -> Vec<u8> {
        let img = image::RgbaImage::from_fn(12, 9, |x, y| image::Rgba([x as u8 * 20, y as u8 * 25, 90, 255]));
        let mut out = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Png).unwrap();
        out
    }

    /// A PNG whose header and size are in order and whose pixel data is not.
    fn bad() -> Vec<u8> {
        let mut b = good();
        let n = b.len();
        for x in &mut b[45..n - 16] {
            *x = 0x5A;
        }
        assert!(image_check::check(&b).is_err());
        b
    }

    fn fresh_store() -> MessageStore {
        MessageStore::open(":memory:", &"ab".repeat(32)).unwrap()
    }

    fn profile_with(store: &MessageStore, peer: &str, avatar: &[u8], banner: &[u8]) {
        store
            .save_profile(peer, "P", "", "", 1, Some(avatar), Some(banner), "", None, None, None, None, None, None, None)
            .unwrap();
    }

    #[test]
    fn a_rail_blob_crosses_only_after_the_check() {
        let _l = store_test_lock();
        let store = fresh_store();
        let (good, bad) = (good(), bad());
        let (gh, bh) = (digest(&good), digest(&bad));
        // Stored before 0.13 or by a local path: never checked at receipt.
        store.save_asset_blob(&gh, &good, false, "emote").unwrap();
        store.save_asset_blob(&bh, &bad, false, "sticker").unwrap();
        set_test_store(store);

        assert_eq!(crate::api::emotes::get_emote_bytes(gh.clone()).unwrap(), Some(good));
        assert_eq!(crate::api::emotes::get_emote_bytes(bh.clone()).unwrap(), Some(Vec::new()), "refused = empty");
        assert_eq!(crate::api::emotes::get_emote_bytes("c".repeat(64)).unwrap(), None, "unknown = pull it");

        // The lazy verdict is kept, so the asker never pulls the refused hash.
        let guard = get_store_for_test();
        let ms = guard.as_ref().unwrap();
        assert_eq!(ms.image_verdict(&bh, RULE).map(|r| r.0), Some(CODE_REFUSED));
        assert_eq!(ms.image_verdict(&gh, RULE).map(|r| r.0), Some(CODE_PASS));
    }

    #[test]
    fn a_refused_hash_we_never_cached_crosses_as_refused() {
        let _l = store_test_lock();
        let store = fresh_store();
        let h = "d".repeat(64);
        store.record_image_verdict(&h, CODE_REFUSED, RULE).unwrap();
        set_test_store(store);
        assert_eq!(crate::api::emotes::get_emote_bytes(h).unwrap(), Some(Vec::new()));
    }

    #[test]
    fn a_profile_still_crosses_only_after_the_check() {
        let _l = store_test_lock();
        let store = fresh_store();
        profile_with(&store, "bad-peer", &bad(), &bad());
        profile_with(&store, "good-peer", &good(), &good());
        set_test_store(store);

        use crate::api::storage::{get_avatar, get_banner, get_profile, get_all_profiles};
        assert_eq!(get_avatar("bad-peer".into()).unwrap(), None);
        assert_eq!(get_banner("bad-peer".into()).unwrap(), None);
        let p = get_profile("bad-peer".into()).unwrap().unwrap();
        assert!(p.avatar_bytes.is_none() && p.banner_bytes.is_none());
        assert!(get_all_profiles().unwrap().iter().filter(|p| p.peer_id == "bad-peer").all(|p| p.avatar_bytes.is_none() && p.banner_bytes.is_none()));

        assert_eq!(get_avatar("good-peer".into()).unwrap(), Some(good()));
        assert_eq!(get_banner("good-peer".into()).unwrap(), Some(good()));
        let p = get_profile("good-peer".into()).unwrap().unwrap();
        assert_eq!((p.avatar_bytes, p.banner_bytes), (Some(good()), Some(good())));
    }

    #[test]
    fn an_overlay_image_crosses_only_after_the_check() {
        let _l = store_test_lock();
        let store = fresh_store();
        let (good, bad) = (good(), bad());
        store.save_overlay_blob(&digest(&good), &good, false).unwrap();
        store.save_overlay_blob(&digest(&bad), &bad, false).unwrap();
        set_test_store(store);
        assert_eq!(crate::api::overlay::overlay_image_bytes(digest(&bad)), None);
        assert_eq!(crate::api::overlay::overlay_image_bytes(digest(&good)), Some(good));
    }

    #[test]
    fn a_showcase_image_crosses_only_after_the_check() {
        let _l = store_test_lock();
        let store = fresh_store();
        let (good, bad) = (good(), bad());
        let bundle = crate::api::showcase::encode_asset_bundle(&[(digest(&good), good.clone()), (digest(&bad), bad)]);
        store
            .save_profile("p", "P", "", "", 1, None, None, "", None, Some(&bundle), None, None, None, None, None)
            .unwrap();
        set_test_store(store);
        let shown = crate::api::showcase::get_showcase_assets("p".into()).unwrap();
        assert_eq!(shown.len(), 1, "the refused image is left out");
        assert_eq!(shown[0].bytes, good);
    }

    #[test]
    fn an_attachment_crosses_only_after_the_check() {
        let _l = store_test_lock();
        set_test_store(fresh_store());
        let dir = crate::test_tmp::tempdir().unwrap();
        let (gp, bp) = (dir.path().join("good.png"), dir.path().join("bad.png"));
        std::fs::write(&gp, good()).unwrap();
        std::fs::write(&bp, bad()).unwrap();
        let read = |p: &std::path::Path| crate::api::at_rest::read_at_rest_image(p.to_string_lossy().into_owned());
        assert_eq!(read(&gp).unwrap(), good(), "a valid image passes unchanged");
        assert!(read(&bp).is_err(), "an undecodable image never reaches Dart");
    }

    #[test]
    fn a_strangers_images_on_a_guest_event_cross_only_after_the_check() {
        let _l = store_test_lock();
        set_test_store(fresh_store());
        let ev = crate::node::NetworkEvent::PublicChannelListReceived {
            server_id: "s".into(),
            server_name: "S".into(),
            channels: vec![],
            server_avatar: Some(bad()),
            server_banner_thumb: Some(good()),
        };
        match super::guest_event_checked(ev) {
            crate::node::NetworkEvent::PublicChannelListReceived { server_avatar, server_banner_thumb, .. } => {
                assert_eq!(server_avatar, None);
                assert_eq!(server_banner_thumb, Some(good()));
            }
            _ => unreachable!(),
        }
        let ev = crate::node::NetworkEvent::PublicChannelSyncReceived {
            server_id: "s".into(),
            channel_id: "c".into(),
            messages: vec![],
            has_more: false,
            sender_profiles: vec![
                crate::node::types::SyncSenderProfileFfi { peer_id: "a".into(), name: None, avatar: Some(bad()) },
                crate::node::types::SyncSenderProfileFfi { peer_id: "b".into(), name: None, avatar: Some(good()) },
            ],
        };
        match super::guest_event_checked(ev) {
            crate::node::NetworkEvent::PublicChannelSyncReceived { sender_profiles, .. } => {
                assert_eq!(sender_profiles[0].avatar, None);
                assert_eq!(sender_profiles[1].avatar, Some(good()));
            }
            _ => unreachable!(),
        }
    }

    #[test]
    fn a_servers_icons_and_banner_cross_only_after_the_check() {
        use base64::Engine as _;
        use crate::crdt::admin_lww::AdminLwwReg;
        use crate::crdt::hlc::HlcTimestamp;
        let _l = store_test_lock();
        let store = fresh_store();
        let (good, bad) = (good(), bad());
        let (gh, bh) = (digest(&good), digest(&bad));
        store.save_asset_blob(&gh, &good, false, "banner").unwrap();
        store.save_asset_blob(&bh, &bad, false, "avatar").unwrap();
        let hlc = HlcTimestamp { physical_ms: 1, counter: 0, actor: "o".into() };
        let set = |state: &mut crate::crdt::server_state::ServerState, k: &str, v: String| {
            state.settings.insert(k.into(), AdminLwwReg::new(v, hlc.clone(), 3));
        };
        let b64 = |b: &[u8]| base64::engine::general_purpose::STANDARD.encode(b);
        for (sid, still, banner, anim) in [("bad", b64(&bad), bh.clone(), bh.clone()), ("good", b64(&good), gh.clone(), gh.clone())] {
            let mut state = crate::crdt::server_state::ServerState::new(sid.into(), "S".into(), "o".into());
            set(&mut state, "server_avatar", still);
            set(&mut state, "server_banner", banner);
            set(&mut state, "server_avatar_anim", anim);
            store.save_server_state(sid, &serde_json::to_string(&state).unwrap()).unwrap();
        }
        set_test_store(store);

        use crate::api::crdt::{get_server_avatar, get_server_avatar_anim, get_server_banner};
        assert_eq!(get_server_avatar("bad".into()).unwrap(), None);
        assert_eq!(get_server_banner("bad".into()).unwrap().unwrap().bytes, Some(Vec::new()));
        assert_eq!(get_server_avatar_anim("bad".into()).unwrap().unwrap().bytes, Some(Vec::new()));
        assert_eq!(get_server_avatar("good".into()).unwrap(), Some(good.clone()));
        assert_eq!(get_server_banner("good".into()).unwrap().unwrap().bytes, Some(good.clone()));
        assert_eq!(get_server_avatar_anim("good".into()).unwrap().unwrap().bytes, Some(good));
    }

    #[test]
    fn a_notification_icon_crosses_only_after_the_check() {
        let store = fresh_store();
        profile_with(&store, "bad-peer", &bad(), &good());
        profile_with(&store, "good-peer", &good(), &good());
        assert_eq!(crate::api::network::push_profile_in_for_test(&store, "bad-peer"), None);
        assert_eq!(crate::api::network::push_profile_in_for_test(&store, "good-peer"), Some(good()));
    }

    fn get_store_for_test() -> std::sync::MutexGuard<'static, Option<MessageStore>> {
        crate::api::storage::get_store().lock().unwrap()
    }
}

