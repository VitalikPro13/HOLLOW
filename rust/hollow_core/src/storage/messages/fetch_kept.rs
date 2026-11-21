//! Frames a push fetch took from the relay but does not handle itself (HOL-SEC-244).
//!
//! The relay deletes a room's offline buffer as it hands it to the fetch socket, so
//! whatever the fetch cannot show waits here for the app, which replays it through the
//! live receive path. DM rooms and server rooms have budgets of their own, so no server
//! member can push out what a friend sent. Within a budget each ROOM is one share (a DM
//! room is one friend, a server room one server), since identities are free; a full
//! budget gives up a frame of the room holding the most bytes, from its heaviest sender.

use rusqlite::{params, Connection, OptionalExtension};
use sha2::{Digest, Sha256};

use super::{ddl, MessageStore};

/// Which budget a kept frame is charged to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum KeptPool {
    /// A DM wake: the room of one friend, or our own.
    Dm,
    /// A channel wake: one server's room.
    Server,
}

impl KeptPool {
    fn code(self) -> i64 {
        match self {
            KeptPool::Dm => 0,
            KeptPool::Server => 1,
        }
    }

    /// (rows, bytes) this budget holds at most.
    fn limits(self) -> (i64, i64) {
        match self {
            KeptPool::Dm => (KEPT_DM_ROWS, KEPT_DM_BYTES),
            KeptPool::Server => (KEPT_SERVER_ROWS, KEPT_SERVER_BYTES),
        }
    }
}

/// Frames kept at most for DM rooms, whoever sent them.
pub(crate) const KEPT_DM_ROWS: i64 = 384;
/// Bytes kept at most for DM rooms, frames and their opened plaintext together.
pub(crate) const KEPT_DM_BYTES: i64 = 6 * 1024 * 1024;
/// Frames kept at most for server rooms.
pub(crate) const KEPT_SERVER_ROWS: i64 = 128;
/// Bytes kept at most for server rooms.
pub(crate) const KEPT_SERVER_BYTES: i64 = 2 * 1024 * 1024;
/// One frame larger than this is not kept: a sync page or card that big comes again.
pub(crate) const KEPT_MAX_FRAME: i64 = 1024 * 1024;
/// What a row costs beyond its bytes, so a flood of empty frames still pays.
const ROW_WEIGHT: i64 = 256;
/// A frame the app never gets to replay (a room it no longer joins) goes after this.
pub(crate) const KEPT_TTL_MS: i64 = 30 * 24 * 60 * 60 * 1000;

/// One kept frame, as the relay delivered it to the fetch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct KeptFrame {
    /// The row, once stored: the app forgets it by this after its replay.
    pub seq: i64,
    pub pool: KeptPool,
    /// What the frame is charged to and purged with: the friend's master (ours for our
    /// own room) for a DM room, the server id for a server room.
    pub scope: String,
    /// The device that sealed it.
    pub device: String,
    pub room: String,
    /// The sealed relay frame, unchanged.
    pub frame: Vec<u8>,
    /// For an Olm frame the fetch decrypted: the SHA-256 of its `body` and the
    /// plaintext, since that message key is spent.
    pub opened: Option<([u8; 32], Vec<u8>)>,
}

pub(super) fn create(conn: &Connection) -> Result<(), String> {
    ddl(conn, "fetch_kept table",
        "CREATE TABLE IF NOT EXISTS fetch_kept (
            seq       INTEGER PRIMARY KEY AUTOINCREMENT,
            pool      INTEGER NOT NULL,
            scope     TEXT NOT NULL,
            sender    TEXT NOT NULL,
            device    TEXT NOT NULL,
            room      TEXT NOT NULL,
            frame     BLOB NOT NULL,
            frame_sha BLOB NOT NULL UNIQUE,
            body_sha  BLOB,
            opened    BLOB,
            weight    INTEGER NOT NULL,
            kept_ms   INTEGER NOT NULL
        )")?;
    ddl(conn, "fetch_kept room index", "CREATE INDEX IF NOT EXISTS idx_fetch_kept_room ON fetch_kept (room, seq)")?;
    ddl(conn, "fetch_kept scope index", "CREATE INDEX IF NOT EXISTS idx_fetch_kept_scope ON fetch_kept (pool, scope)")
}

/// Drop every kept frame charged to `scope` in `pool`, or the whole pool's when `None`.
pub(super) fn purge(conn: &Connection, pool: KeptPool, scope: Option<&str>) -> Result<(), String> {
    conn.execute(
        "DELETE FROM fetch_kept WHERE pool = ?1 AND (?2 IS NULL OR scope = ?2)",
        params![pool.code(), scope],
    )
    .map(|_| ())
    .map_err(|e| format!("fetch_kept purge: {e}"))
}

fn err(e: rusqlite::Error) -> String {
    format!("fetch_kept: {e}")
}

impl MessageStore {
    /// Keep a frame for the app. `sender` is the master that sealed it. False when it
    /// was not kept: too big, or its room (or, within the room, its sender) would hold
    /// the most with nothing kept. A frame already kept counts as kept; one kept as it
    /// came takes the plaintext of a later read of the same frame.
    pub(crate) fn keep_fetched_frame(&self, sender: &str, kept: &KeptFrame, now_ms: i64) -> Result<bool, String> {
        let opened_len = kept.opened.as_ref().map_or(0, |(_, p)| p.len() as i64);
        let weight = kept.frame.len() as i64 + opened_len + ROW_WEIGHT;
        if weight > KEPT_MAX_FRAME + ROW_WEIGHT {
            return Ok(false);
        }
        let frame_sha = Sha256::digest(&kept.frame).to_vec();
        let tx = self.conn.unchecked_transaction().map_err(err)?;
        tx.execute("DELETE FROM fetch_kept WHERE kept_ms < ?1", params![now_ms.saturating_sub(KEPT_TTL_MS)]).map_err(err)?;
        let held: Option<(i64, bool)> = tx
            .query_row("SELECT seq, opened IS NOT NULL FROM fetch_kept WHERE frame_sha = ?1", params![frame_sha], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .optional()
            .map_err(err)?;
        // The same frame kept as it came, now with what a read of it found: the row
        // keeps its place in the replay order.
        let reuse_seq = match held {
            Some((seq, false)) if kept.opened.is_some() => {
                tx.execute("DELETE FROM fetch_kept WHERE seq = ?1", params![seq]).map_err(err)?;
                Some(seq)
            }
            Some(_) => return Ok(true),
            None => None,
        };
        let (max_rows, max_bytes) = kept.pool.limits();
        loop {
            let (rows, bytes): (i64, i64) = tx
                .query_row(
                    "SELECT COUNT(*), COALESCE(SUM(weight), 0) FROM fetch_kept WHERE pool = ?1",
                    params![kept.pool.code()],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .map_err(err)?;
            if rows < max_rows && bytes + weight <= max_bytes {
                break;
            }
            // Nothing to give up: the incoming frame alone is the heaviest share, and
            // the transaction ends unwritten.
            let Some(victim) = victim(&tx, kept.pool, &kept.scope, sender, weight)? else { return Ok(false) };
            if tx.execute("DELETE FROM fetch_kept WHERE seq = ?1", params![victim]).map_err(err)? == 0 {
                return Ok(false);
            }
        }
        let (body_sha, opened) = match &kept.opened {
            Some((sha, plaintext)) => (Some(sha.to_vec()), Some(plaintext.as_slice())),
            None => (None, None),
        };
        tx.execute(
            "INSERT INTO fetch_kept (seq, pool, scope, sender, device, room, frame, frame_sha, body_sha, opened, weight, kept_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            params![
                reuse_seq, kept.pool.code(), kept.scope, sender, kept.device, kept.room, kept.frame, frame_sha,
                body_sha, opened, weight, now_ms
            ],
        )
        .map_err(err)?;
        tx.commit().map_err(err)?;
        Ok(true)
    }

    /// Every frame kept for `room` and still in date, oldest first. Nothing is removed:
    /// the app forgets each one once its replay returned ([`Self::forget_fetch_kept`]).
    pub(crate) fn fetch_kept_for(&self, room: &str, now_ms: i64) -> Result<Vec<KeptFrame>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT seq, pool, scope, device, room, frame, body_sha, opened FROM fetch_kept
                 WHERE room = ?1 AND kept_ms >= ?2 ORDER BY seq",
            )
            .map_err(err)?;
        let rows = stmt
            .query_map(params![room, now_ms.saturating_sub(KEPT_TTL_MS)], |r| {
                let body_sha: Option<Vec<u8>> = r.get(6)?;
                let opened: Option<Vec<u8>> = r.get(7)?;
                Ok(KeptFrame {
                    seq: r.get(0)?,
                    pool: if r.get::<_, i64>(1)? == KeptPool::Dm.code() { KeptPool::Dm } else { KeptPool::Server },
                    scope: r.get(2)?,
                    device: r.get(3)?,
                    room: r.get(4)?,
                    frame: r.get(5)?,
                    opened: body_sha.and_then(|s| <[u8; 32]>::try_from(s).ok()).zip(opened),
                })
            })
            .map_err(err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(err)
    }

    /// Forget one kept frame: its replay returned.
    pub(crate) fn forget_fetch_kept(&self, seq: i64) -> Result<(), String> {
        self.conn.execute("DELETE FROM fetch_kept WHERE seq = ?1", params![seq]).map(|_| ()).map_err(err)
    }

    /// Drop every kept frame past its time.
    pub(crate) fn sweep_fetch_kept(&self, now_ms: i64) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM fetch_kept WHERE kept_ms < ?1", params![now_ms.saturating_sub(KEPT_TTL_MS)])
            .map(|_| ())
            .map_err(err)
    }

    #[cfg(test)]
    pub(crate) fn fetch_kept_count(&self) -> i64 {
        self.conn.query_row("SELECT COUNT(*) FROM fetch_kept", [], |r| r.get(0)).unwrap_or(-1)
    }

    /// Test-only: what a later replay finds for `room`, forgetting it as a replay would.
    #[cfg(test)]
    pub(crate) fn take_fetch_kept(&self, room: &str, now_ms: i64) -> Result<Vec<KeptFrame>, String> {
        let kept = self.fetch_kept_for(room, now_ms)?;
        for k in &kept {
            self.forget_fetch_kept(k.seq)?;
        }
        Ok(kept)
    }
}

/// The row a full `pool` gives up for `incoming` bytes charged to `scope` and `sender`:
/// the oldest frame of the heaviest sender in the heaviest scope, the incoming one
/// counted. On a tie the incoming scope, then the incoming sender, gives way; `None`
/// when that leaves the incoming frame itself, holding nothing, as the one to go.
fn victim(conn: &Connection, pool: KeptPool, scope: &str, sender: &str, incoming: i64) -> Result<Option<i64>, String> {
    let Some(heaviest_scope) = heaviest(
        conn,
        "SELECT scope, SUM(weight) FROM fetch_kept WHERE pool = ?1 GROUP BY scope",
        params![pool.code()],
        scope,
        incoming,
    )?
    else {
        return Ok(None);
    };
    let charged = if heaviest_scope == scope { incoming } else { 0 };
    let Some(heaviest_sender) = heaviest(
        conn,
        "SELECT sender, SUM(weight) FROM fetch_kept WHERE pool = ?1 AND scope = ?2 GROUP BY sender",
        params![pool.code(), heaviest_scope],
        sender,
        charged,
    )?
    else {
        return Ok(None);
    };
    conn.query_row(
        "SELECT MIN(seq) FROM fetch_kept WHERE pool = ?1 AND scope = ?2 AND sender = ?3",
        params![pool.code(), heaviest_scope, heaviest_sender],
        |r| r.get::<_, Option<i64>>(0),
    )
    .map_err(err)
}

/// The key `query` finds holding the most weight once `incoming` is added to `own`
/// (`own` takes nothing when `incoming` is 0); on a tie `own` gives way, never a key
/// already holding.
fn heaviest(conn: &Connection, query: &str, args: impl rusqlite::Params, own: &str, incoming: i64) -> Result<Option<String>, String> {
    let mut stmt = conn.prepare(query).map_err(err)?;
    let mut shares: Vec<(String, i64)> =
        stmt.query_map(args, |r| Ok((r.get(0)?, r.get(1)?))).map_err(err)?.filter_map(Result::ok).collect();
    let charged = incoming > 0;
    if charged {
        match shares.iter_mut().find(|(k, _)| k == own) {
            Some(held) => held.1 += incoming,
            None => shares.push((own.to_string(), incoming)),
        }
    }
    Ok(shares
        .into_iter()
        .max_by(|(a_key, a), (b_key, b)| a.cmp(b).then_with(|| (charged && a_key == own).cmp(&(charged && b_key == own))))
        .map(|(k, _)| k))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (crate::test_tmp::TestDir, MessageStore) {
        let dir = crate::test_tmp::tempdir().expect("tmp");
        let path = dir.path().join("kept.db");
        let store = MessageStore::open(path.to_str().unwrap(), "pass").expect("store");
        (dir, store)
    }

    /// A frame for `room` in `pool`, charged to the room.
    fn frame_in(pool: KeptPool, device: &str, room: &str, n: usize, size: usize) -> KeptFrame {
        let mut bytes = vec![n as u8; size];
        bytes.extend_from_slice(format!("{device}:{room}:{n}").as_bytes());
        KeptFrame { seq: 0, pool, scope: room.into(), device: device.into(), room: room.into(), frame: bytes, opened: None }
    }

    fn frame(device: &str, room: &str, n: usize, size: usize) -> KeptFrame {
        frame_in(KeptPool::Dm, device, room, n, size)
    }

    fn senders(store: &MessageStore) -> Vec<String> {
        let mut stmt = store.conn.prepare("SELECT sender FROM fetch_kept ORDER BY seq").unwrap();
        stmt.query_map([], |r| r.get(0)).unwrap().filter_map(Result::ok).collect()
    }

    fn strip(kept: Vec<KeptFrame>) -> Vec<KeptFrame> {
        kept.into_iter().map(|k| KeptFrame { seq: 0, ..k }).collect()
    }

    #[test]
    fn a_kept_frame_comes_back_once_whole_and_in_order() {
        let (_d, store) = store();
        let mut opened = frame("d1", "dm-room", 1, 10);
        opened.opened = Some(([7; 32], b"{\"delete\":{}}".to_vec()));
        let raw = frame("d1", "dm-room", 2, 10);
        assert!(store.keep_fetched_frame("m1", &opened, 1_000).unwrap());
        assert!(store.keep_fetched_frame("m1", &raw, 1_000).unwrap());
        assert!(store.keep_fetched_frame("m1", &raw, 1_000).unwrap(), "a frame already kept counts as kept");
        assert!(store.keep_fetched_frame("m1", &frame("d1", "other", 3, 10), 1_000).unwrap());
        assert_eq!(store.fetch_kept_count(), 3, "the same frame is kept once");
        assert_eq!(strip(store.fetch_kept_for("dm-room", 1_000).unwrap()).len(), 2, "a read forgets nothing");
        assert_eq!(strip(store.take_fetch_kept("dm-room", 1_000).unwrap()), vec![opened, raw]);
        assert!(store.fetch_kept_for("dm-room", 1_000).unwrap().is_empty(), "a forgotten frame is not replayed again");
        assert_eq!(store.fetch_kept_count(), 1, "another room's frame waits for its own room");
    }

    /// HOL-SEC-244 review (NIT-5): a later read of a frame kept as it came attaches what
    /// it found to that row, in its place, instead of being turned away as a duplicate.
    #[test]
    fn a_frame_kept_as_it_came_takes_the_plaintext_of_a_later_read() {
        let (_d, store) = store();
        let raw = frame("d1", "dm-room", 1, 10);
        let after = frame("d1", "dm-room", 2, 10);
        assert!(store.keep_fetched_frame("m1", &raw, 1_000).unwrap());
        assert!(store.keep_fetched_frame("m1", &after, 1_000).unwrap());
        let mut read = raw.clone();
        read.opened = Some(([3; 32], b"plain".to_vec()));
        assert!(store.keep_fetched_frame("m1", &read, 1_000).unwrap(), "the plaintext is kept");
        assert!(store.keep_fetched_frame("m1", &raw, 1_000).unwrap());
        assert_eq!(strip(store.take_fetch_kept("dm-room", 1_000).unwrap()), vec![read, after], "one row, in its first place");
    }

    #[test]
    fn a_full_table_evicts_the_heaviest_sender_never_another() {
        let (_d, store) = store();
        let big = KEPT_MAX_FRAME as usize - 1024;
        assert!(store.keep_fetched_frame("friend", &frame("f", "r", 0, 1000), 0).unwrap());
        for n in 0..6 {
            assert!(store.keep_fetched_frame("flood", &frame("x", "r", n, big), 0).unwrap());
        }
        assert_eq!(store.fetch_kept_count(), 7, "the budget holds the friend and six floods");
        // Past the byte budget: the flooder gives up its own oldest, the friend keeps its frame.
        assert!(store.keep_fetched_frame("flood", &frame("x", "r", 9, big), 0).unwrap());
        let held = senders(&store);
        assert_eq!(held.first().map(String::as_str), Some("friend"));
        assert_eq!(held.iter().filter(|s| *s == "flood").count(), 6);
        // A newcomer lighter than the flood evicts from the flood.
        assert!(store.keep_fetched_frame("other", &frame("o", "r", 0, big / 2), 0).unwrap());
        let held = senders(&store);
        assert_eq!(held.iter().filter(|s| *s == "friend").count(), 1, "the friend kept its frame");
        assert_eq!(held.iter().filter(|s| *s == "other").count(), 1);
    }

    #[test]
    fn a_full_table_of_rows_evicts_the_sender_holding_most() {
        let (_d, store) = store();
        for n in 0..(KEPT_DM_ROWS - 1) as usize {
            assert!(store.keep_fetched_frame("flood", &frame("x", "r", n, 4), 0).unwrap());
        }
        assert!(store.keep_fetched_frame("friend", &frame("f", "r", 0, 4), 0).unwrap());
        assert!(store.keep_fetched_frame("friend", &frame("f", "r", 1, 4), 0).unwrap());
        assert_eq!(store.fetch_kept_count(), KEPT_DM_ROWS);
        assert_eq!(senders(&store).iter().filter(|s| *s == "friend").count(), 2, "the flood gave way, not the friend");
    }

    #[test]
    fn a_sender_that_would_hold_most_with_nothing_kept_is_turned_away() {
        let (_d, store) = store();
        let held = ["a", "b", "c", "d", "e", "f"];
        for (n, s) in held.iter().enumerate() {
            assert!(store.keep_fetched_frame(s, &frame(s, "r", n, KEPT_MAX_FRAME as usize - 1024), 0).unwrap());
        }
        // No room left, and this one alone would outweigh every holder: it gives way.
        assert!(!store.keep_fetched_frame("z", &frame("z", "r", 0, KEPT_MAX_FRAME as usize - 16), 0).unwrap());
        assert_eq!(senders(&store), held);
        assert!(!store.keep_fetched_frame("a", &frame("a", "r", 1, KEPT_MAX_FRAME as usize + 1), 0).unwrap(), "an oversized frame is never kept");
    }

    /// HOL-SEC-244 review (SHOULD-1): a room is one share, however many senders it has,
    /// and a newcomer room that would hold the most with nothing kept is turned away.
    #[test]
    fn a_crowd_in_one_room_evicts_only_its_own_room() {
        let (_d, store) = store();
        for n in 0..3 {
            assert!(store.keep_fetched_frame("friend", &frame("f", "dm-friend", n, 64), 0).unwrap());
        }
        for n in 0..(KEPT_DM_ROWS as usize * 2) {
            let s = format!("crowd{n}");
            let _ = store.keep_fetched_frame(&s, &frame(&s, "dm-crowd", n, 64), 0).unwrap();
        }
        assert_eq!(senders(&store).iter().filter(|s| *s == "friend").count(), 3, "the crowd's room paid for its own frames");
        assert_eq!(store.fetch_kept_count(), KEPT_DM_ROWS);

        let (_d2, store) = self::store();
        let rooms = ["dm-a", "dm-b", "dm-c", "dm-d", "dm-e", "dm-f"];
        for (n, room) in rooms.iter().enumerate() {
            assert!(store.keep_fetched_frame("f", &frame("f", room, n, KEPT_MAX_FRAME as usize - 1024), 0).unwrap());
        }
        assert!(!store.keep_fetched_frame("n", &frame("n", "dm-new", 0, KEPT_MAX_FRAME as usize - 16), 0).unwrap());
        assert_eq!(store.fetch_kept_count(), rooms.len() as i64, "every room kept its frame");
    }

    /// HOL-SEC-244 review (SHOULD-1): server rooms never take a DM room's budget, nor
    /// weigh a DM room when they choose what to give up.
    #[test]
    fn a_server_room_never_evicts_a_dm_room() {
        let (_d, store) = store();
        assert!(store.keep_fetched_frame("friend", &frame("f", "dm-room", 0, 512 * 1024), 0).unwrap());
        for n in 0..(KEPT_SERVER_ROWS as usize * 3) {
            let kept = store.keep_fetched_frame("member", &frame_in(KeptPool::Server, "m", "srv", n, 1024), 0).unwrap();
            assert!(kept, "a full server room gives up its own oldest frame");
        }
        assert_eq!(senders(&store).iter().filter(|s| *s == "friend").count(), 1);
        assert_eq!(store.fetch_kept_count(), 1 + KEPT_SERVER_ROWS, "server rooms fill only their own budget");
    }

    /// A frame for a lighter room makes its space in the heaviest room, from that room's
    /// heaviest sender, however heavy the frame is next to each of them.
    #[test]
    fn a_heavy_frame_makes_room_in_the_heaviest_room() {
        let (_d, store) = store();
        for n in 0..KEPT_DM_ROWS as usize {
            assert!(store.keep_fetched_frame(&format!("c{n}"), &frame("c", "dm-crowd", n, 64), 0).unwrap());
        }
        assert!(store.keep_fetched_frame("friend", &frame("f", "dm-friend", 0, 64 * 1024), 0).unwrap(), "the crowd's room gives way");
        assert_eq!(store.fetch_kept_count(), KEPT_DM_ROWS);
    }

    /// Two shares of the same weight: the one already holding stays.
    #[test]
    fn a_tie_turns_the_newcomer_away() {
        let (_d, store) = store();
        let same = |n: usize| KeptFrame { frame: format!("{n:08}").into_bytes(), ..frame("d", "r", 0, 0) };
        for n in 0..KEPT_DM_ROWS as usize {
            assert!(store.keep_fetched_frame(&format!("s{n}"), &same(n), 0).unwrap());
        }
        assert!(!store.keep_fetched_frame("late", &same(99_999), 0).unwrap(), "a newcomer as heavy as each holder gives way");
        assert!(senders(&store).iter().all(|s| s != "late"));
    }

    #[test]
    fn a_frame_kept_past_its_time_is_gone() {
        let (_d, store) = store();
        assert!(store.keep_fetched_frame("m", &frame("d", "r", 0, 4), 0).unwrap());
        assert!(store.fetch_kept_for("r", KEPT_TTL_MS + 1).unwrap().is_empty());
        assert_eq!(store.fetch_kept_count(), 1);
        store.sweep_fetch_kept(KEPT_TTL_MS + 1).unwrap();
        assert_eq!(store.fetch_kept_count(), 0, "the sweep drops it without a keep");
    }

    /// HOL-SEC-244 review (NIT-7): an unfriend, a server leave and a history clear take
    /// that room's kept frames with them.
    #[test]
    fn a_rooms_frames_go_with_the_friendship_the_server_and_the_history() {
        let (_d, store) = store();
        let dm = |scope: &str, n| KeptFrame { scope: scope.into(), ..frame("d", &format!("dm-{scope}"), n, 4) };
        let srv = |sid: &str, n| frame_in(KeptPool::Server, "d", sid, n, 4);
        store.save_friend("ann", "accepted", "outgoing", 1).unwrap();
        for k in [dm("ann", 0), dm("bob", 1), srv("s1", 2), srv("s2", 3), srv("s3", 4)] {
            assert!(store.keep_fetched_frame("x", &k, 0).unwrap());
        }
        store.save_friend("ann", "accepted", "outgoing", 1).unwrap();
        assert_eq!(store.fetch_kept_count(), 5, "a friendship that stays keeps its frames");
        store.save_friend("ann", "removed", "outgoing", 1).unwrap();
        assert!(store.fetch_kept_for("dm-ann", 0).unwrap().is_empty(), "unfriended");
        store.remove_friend("bob").unwrap();
        assert!(store.fetch_kept_for("dm-bob", 0).unwrap().is_empty(), "friend row removed");
        store.delete_server_state("s1").unwrap();
        assert!(store.fetch_kept_for("s1", 0).unwrap().is_empty(), "server left");
        store.clear_history_in(Some("s2"), &[], 1).unwrap();
        assert!(store.fetch_kept_for("s2", 0).unwrap().is_empty(), "that server's history cleared");
        assert_eq!(store.fetch_kept_count(), 1);
        store.clear_channel_history(1).unwrap();
        assert_eq!(store.fetch_kept_count(), 0, "every server's history cleared");
    }

    /// Review HOL-SEC-244: the fair share was an identity, and identities are free. A
    /// friend holding three frames must outlast any flood of one-frame identities in a
    /// server room, the next one included.
    #[test]
    fn rev244_one_frame_sybils_evict_a_friends_kept_frames() {
        let (_d, store) = store();
        for n in 0..3 {
            assert!(store.keep_fetched_frame("friend", &frame("f", "dm-room", n, 64), 0).unwrap());
        }
        for n in 0..((KEPT_DM_ROWS + KEPT_SERVER_ROWS) as usize - 3) {
            let s = format!("sybil{n}");
            let _ = store.keep_fetched_frame(&s, &frame_in(KeptPool::Server, &s, "srv", n, 64), 0).unwrap();
        }
        let _ = store.keep_fetched_frame("sybil-next", &frame_in(KeptPool::Server, "sybil-next", "srv", 0, 64), 0).unwrap();
        assert_eq!(
            senders(&store).iter().filter(|s| *s == "friend").count(),
            3,
            "a flood of one-frame identities in a server room evicted a friend's kept DM frame",
        );
    }
}
