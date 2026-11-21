//! What a push fetch keeps for the app, and the app's replay of it (HOL-SEC-244).
//!
//! The relay deletes what it buffered for a room as it hands it to the fetch socket.
//! The fetch shows DMs, edits, cards and file headers; every other durable frame it
//! read is stored (`MessageStore::keep_fetched_frame`) and the app hands it, sealed as it
//! arrived, to the same receive path as a frame from the relay once it holds that room
//! again. An Olm frame the fetch decrypted cannot be decrypted twice (its key is spent),
//! so its plaintext rides along, bound to that frame's ciphertext.

use std::collections::{HashSet, VecDeque};

use sha2::{Digest, Sha256};

use crate::storage::{KeptFrame, KeptPool};
use crate::node::types::{HavenMessage, Lane};
use crate::node::ws_client::WsEvent;

/// The plaintext our push fetch read from one Olm frame.
pub(crate) struct Opened {
    device: String,
    body_sha: [u8; 32],
    plaintext: Vec<u8>,
}

tokio::task_local! {
    /// Set only around the app's replay of one kept frame.
    pub(crate) static OPENED: Option<Box<Opened>>;
}

/// A kept frame on its way through the receive path. Boxed: the event loop's frame
/// holds it, and that frame sits near the worker stack's end.
pub(crate) struct Replay {
    pub(crate) opened: Option<Box<Opened>>,
}

/// The SHA-256 an Olm frame's `body` is bound by.
pub(crate) fn body_sha(body: &str) -> [u8; 32] {
    Sha256::digest(body.as_bytes()).into()
}

/// The plaintext the fetch kept for exactly this Olm frame from `device`, inside its replay.
pub(crate) fn opened_for(device: &str, body: &str) -> Option<Vec<u8>> {
    OPENED
        .try_with(|o| o.as_ref().filter(|o| o.device == device && o.body_sha == body_sha(body)).map(|o| o.plaintext.clone()))
        .ok()
        .flatten()
}

/// A frame worth keeping: one the relay may read and that is acted on however late.
/// Anything live-only would be judged stale by the time the app replays it.
pub(crate) fn durable(msg: &HavenMessage) -> bool {
    msg.lane() == Lane::Relay && !msg.live_only()
}

/// Store one frame the fetch read but does not handle, charged to `scope` in `pool`
/// (the friend's master or the server). `opened` = the Olm plaintext it decrypted from
/// the frame's `body`. False when it was not kept.
#[allow(clippy::too_many_arguments)]
pub(crate) fn keep(
    db_path: &str,
    db_passphrase: &str,
    pool: KeptPool,
    scope: &str,
    from: &str,
    room: &str,
    frame: &[u8],
    opened: Option<(&str, Vec<u8>)>,
) -> bool {
    let sender = crate::node::resolver::resolve(from);
    let kept = KeptFrame {
        seq: 0,
        pool,
        scope: scope.to_string(),
        device: from.to_string(),
        room: room.to_string(),
        frame: frame.to_vec(),
        opened: opened.map(|(body, plaintext)| (body_sha(body), plaintext)),
    };
    let stored = crate::storage::MessageStore::lease(db_path, db_passphrase)
        .and_then(|store| store.keep_fetched_frame(&sender, &kept, crate::node::frame_auth::now_ms()));
    match stored {
        Ok(kept) => kept,
        Err(e) => {
            crate::hollow_log!("[HOLLOW-FETCH] Could not keep a frame from {from} for the app: {e}");
            false
        }
    }
}

/// The app's queue of kept frames, ahead of anything new from the relay. A row is
/// forgotten only once its replay returned, so a stop mid-queue keeps the rest.
pub(crate) struct KeptQueue {
    db_path: String,
    db_passphrase: String,
    queue: VecDeque<KeptFrame>,
    /// Rows queued or being replayed: a second `members` answer queues none twice.
    queued: HashSet<i64>,
    /// The row handed out last: the loop asking for the next one means it returned.
    in_flight: Option<i64>,
}

impl KeptQueue {
    /// The queue for this database, after dropping what is past its time.
    pub(crate) fn new(db_path: &str, db_passphrase: &str) -> Self {
        if let Err(e) = crate::storage::MessageStore::lease(db_path, db_passphrase)
            .and_then(|store| store.sweep_fetch_kept(crate::node::frame_auth::now_ms()))
        {
            crate::hollow_log!("[HOLLOW-FETCH] Could not sweep the frames our push fetch kept: {e}");
        }
        KeptQueue {
            db_path: db_path.to_string(),
            db_passphrase: db_passphrase.to_string(),
            queue: VecDeque::new(),
            queued: HashSet::new(),
            in_flight: None,
        }
    }

    /// Queue what the fetch kept for `room`, now that we hold it again: on its `members`
    /// answer, which follows a fresh join and a resumed session alike.
    pub(crate) fn release(&mut self, room: &str) {
        let found = crate::storage::MessageStore::lease(&self.db_path, &self.db_passphrase)
            .and_then(|store| store.fetch_kept_for(room, crate::node::frame_auth::now_ms()));
        match found {
            Ok(kept) => {
                let fresh: Vec<KeptFrame> = kept.into_iter().filter(|k| self.queued.insert(k.seq)).collect();
                if !fresh.is_empty() {
                    crate::hollow_log!("[HOLLOW-FETCH] Replaying {} frame(s) our push fetch kept for {room}", fresh.len());
                    self.queue.extend(fresh);
                }
            }
            Err(e) => crate::hollow_log!("[HOLLOW-FETCH] Could not read the frames kept for {room}: {e}"),
        }
    }

    /// Forget the frame handed out last: its replay returned.
    fn replayed(&mut self) {
        let Some(seq) = self.in_flight.take() else { return };
        self.queued.remove(&seq);
        if let Err(e) = crate::storage::MessageStore::lease(&self.db_path, &self.db_passphrase)
            .and_then(|store| store.forget_fetch_kept(seq))
        {
            crate::hollow_log!("[HOLLOW-FETCH] Could not forget a replayed kept frame: {e}");
        }
    }

    /// The next kept frame as the relay delivered it, else the relay's next event.
    pub(crate) async fn next(
        &mut self,
        rx: &mut tokio::sync::mpsc::UnboundedReceiver<WsEvent>,
    ) -> Option<(WsEvent, Option<Box<Replay>>)> {
        self.replayed();
        if let Some(kept) = self.queue.pop_front() {
            self.in_flight = Some(kept.seq);
            let opened = kept.opened.map(|(sha, plaintext)| Box::new(Opened { device: kept.device.clone(), body_sha: sha, plaintext }));
            let event = WsEvent::DirectMessage { room: kept.room, from: kept.device, data: kept.frame };
            return Some((event, Some(Box::new(Replay { opened }))));
        }
        rx.recv().await.map(|event| (event, None))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn kept_plaintext_opens_only_its_own_frame_inside_its_replay() {
        let opened = Opened { device: "d1".into(), body_sha: body_sha("ct"), plaintext: b"pt".to_vec() };
        assert_eq!(opened_for("d1", "ct"), None, "outside a replay nothing stands in for a decrypt");
        OPENED
            .scope(Some(Box::new(opened)), async {
                assert_eq!(opened_for("d1", "ct").as_deref(), Some(&b"pt"[..]));
                assert_eq!(opened_for("d1", "other"), None, "another ciphertext still decrypts");
                assert_eq!(opened_for("d2", "ct"), None, "another device still decrypts");
            })
            .await;
    }

    #[test]
    fn only_durable_relay_lane_frames_are_kept() {
        assert!(durable(&HavenMessage::FriendRemove { at: None }));
        let olm = HavenMessage::Encrypted { message_type: 1, body: String::new(), identity_key: None, identity_sig: None, identity_pk: None };
        assert!(durable(&olm), "an Olm frame is judged by the app once open");
        assert!(!durable(&HavenMessage::KeyRequest { to: None, ts: None, sig: None, pk: None }), "live-only");
        assert!(!durable(&HavenMessage::AgeGateSync { entry: Default::default() }), "rides Olm only");
    }

    fn kept_store(dir: &crate::test_tmp::TestDir) -> (String, String) {
        let path = dir.path().join("queue.db").to_str().unwrap().to_string();
        (path, "pass".to_string())
    }

    async fn next_frame(q: &mut KeptQueue) -> Vec<u8> {
        let (_tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        match q.next(&mut rx).await {
            Some((WsEvent::DirectMessage { data, .. }, Some(_))) => data,
            _ => panic!("a kept frame was due"),
        }
    }

    /// HOL-SEC-244 review (NIT-6): a row goes only once its replay returned, a second
    /// `members` answer queues nothing twice, and a stop mid-queue keeps the rest.
    #[tokio::test]
    async fn a_kept_frame_is_forgotten_only_after_its_replay() {
        let dir = crate::test_tmp::tempdir().expect("tmp");
        let (path, pass) = kept_store(&dir);
        for n in 0..3u8 {
            assert!(keep(&path, &pass, KeptPool::Dm, "f", "f-dev", "room", &[n; 8], None));
        }
        let count = || crate::storage::MessageStore::lease(&path, &pass).unwrap().fetch_kept_count();
        let mut q = KeptQueue::new(&path, &pass);
        q.release("room");
        q.release("room");
        assert_eq!(q.queue.len(), 3, "a second release queues nothing twice");
        assert_eq!(next_frame(&mut q).await, [0u8; 8]);
        assert_eq!(count(), 3, "the frame being replayed is still kept");
        assert_eq!(next_frame(&mut q).await, [1u8; 8]);
        assert_eq!(count(), 2, "the replay that returned is forgotten");
        drop(q);
        let mut q = KeptQueue::new(&path, &pass);
        q.release("room");
        assert_eq!(next_frame(&mut q).await, [1u8; 8], "a stop mid-replay hands that frame back");
        assert_eq!(next_frame(&mut q).await, [2u8; 8]);
    }

    /// HOL-SEC-244 review (NIT-7): a frame past its time goes when the app starts, kept
    /// for a room it never joins again or not.
    #[tokio::test]
    async fn an_expired_frame_is_swept_at_start() {
        let dir = crate::test_tmp::tempdir().expect("tmp");
        let (path, pass) = kept_store(&dir);
        let old = KeptFrame { seq: 0, pool: KeptPool::Dm, scope: "f".into(), device: "d".into(), room: "gone".into(), frame: vec![1], opened: None };
        let store = crate::storage::MessageStore::lease(&path, &pass).unwrap();
        assert!(store.keep_fetched_frame("f", &old, 0).unwrap());
        drop(store);
        let _q = KeptQueue::new(&path, &pass);
        assert_eq!(crate::storage::MessageStore::lease(&path, &pass).unwrap().fetch_kept_count(), 0);
    }
}
