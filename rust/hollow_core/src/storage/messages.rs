use std::collections::{BTreeMap, HashMap};

use rusqlite::{params, Connection, OptionalExtension};

use crate::crdt::operations::CrdtOp;

/// Sync lookback overlap (ms). "Since" watermarks are per-sender MAX timestamps,
/// and a plain high-watermark permanently skips a message MISSED while a newer one
/// arrived, so requesters ask from `watermark - SYNC_LOOKBACK_MS`. Receivers dedup
/// the overlap by message_id, so the only cost is re-sent recent history.
pub(crate) const SYNC_LOOKBACK_MS: i64 = 30 * 60 * 1000;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

/// How far behind `since` a DM gap digest reaches. Past it a missed message stays
/// missed, which bounds both the digest on the wire and a responder's re-serve of
/// a day that can never converge (a row the other side rejects).
const SYNC_GAP_WINDOW_MS: i64 = 30 * DAY_MS;

/// The widest digest a responder honours; see `gap_span_ok`.
const SYNC_GAP_MAX_SPAN_MS: i64 = SYNC_GAP_WINDOW_MS + DAY_MS;

/// The digest window behind a sync's lookback-adjusted `since`, or None when
/// there is nothing behind it.
fn gap_window(since: i64) -> Option<(i64, i64)> {
    (since > 0).then(|| ((since - SYNC_GAP_WINDOW_MS).max(0), since))
}

/// The digest window of a channel ask: from a UTC day's start, so a day a cleared device
/// counts whole (`channel_cleared_days`) is compared whole; still within the span a
/// responder honours.
fn channel_gap_window(since: i64) -> Option<(i64, i64)> {
    gap_window(since).map(|(from, until)| (from.div_euclid(DAY_MS) * DAY_MS, until))
}

/// A responder ignores a digest it did not ask for the shape of: empty, inverted
/// or wider than the window, so a peer cannot make it hash and scan an entire
/// history per request.
fn gap_span_ok(g: &crate::node::types::GapDigest) -> bool {
    g.from < g.until && g.until - g.from <= SYNC_GAP_MAX_SPAN_MS
}

/// The days (as an SQL list) where our digest differs from theirs. A day only
/// they hold is left out: we have nothing to serve for it.
fn differing_days(
    ours: &crate::node::types::GapDigest,
    theirs: &crate::node::types::GapDigest,
) -> Option<String> {
    let known: HashMap<i64, (u32, u64)> =
        theirs.days.iter().map(|d| (d.d, (d.n, d.h))).collect();
    let days: Vec<String> = ours
        .days
        .iter()
        .filter(|o| known.get(&o.d) != Some(&(o.n, o.h)))
        .map(|o| o.d.to_string())
        .collect();
    (!days.is_empty()).then(|| days.join(","))
}

/// Stable 64-bit FNV-1a of a message_id. Both ends of a sync must agree on it, so
/// it can never change.
fn mid_hash(mid: &str) -> u64 {
    mid.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
    })
}

/// A user profile stored locally (ours or a peer's).
#[derive(Default)]
pub(crate) struct StoredProfile {
    pub peer_id: String,
    pub display_name: String,
    pub status: String,
    pub about_me: String,
    pub updated_at: i64,
    pub avatar_bytes: Option<Vec<u8>>,
    pub banner_bytes: Option<Vec<u8>>,
    pub twitch_username: String,
    /// Showcase board JSON (profile blocks; empty = no board).
    pub showcase_board: String,
    /// Showcase asset bundle blob (game covers/artwork keyed by hash).
    pub showcase_assets: Option<Vec<u8>>,
    /// Avatar frame ID (issue #54). `""` = none, `"b:<hue>"` = a built-in
    /// procedural frame, 64-hex = an asset-rail blob hash. Never bytes: the
    /// art rides the rail so it can be evicted, unlike a profile push.
    pub avatar_frame: String,
    /// Content hash of this person's ANIMATED avatar, `""` for none. The bytes ride the
    /// asset rail; `avatar_bytes` above holds only the STILL companion, which is what
    /// an old client and the guest thumb read.
    pub avatar_anim: String,
    /// Content hash of this person's ANIMATED banner, or `""` for none. See
    /// [`StoredProfile::avatar_anim`].
    pub banner_anim: String,
    /// Support credentials: a JSON array of self-contained blind-signature entries, or
    /// `""`. Written ONLY by `sanitize_incoming_support_creds` for a peer and from
    /// `support_creds_own` for us. Not covered by the profile signature: each entry
    /// binds the master peer id itself.
    pub support_creds: String,
    /// The SUBJECT's own signature over every field of this profile, persisted so we
    /// can forward it in a `ProfileRelay`. A relayed profile with no owner signature is
    /// refused, so one stored without it (a card, say) simply never gets relayed.
    pub profile_sig: Option<String>,
    /// Owner MASTER public key (base64 protobuf) paired with `profile_sig`.
    pub profile_pk: Option<String>,
    /// The avatar hash the signature was made over, stored rather than derived from
    /// `avatar_bytes`: announces are LIGHT, so our cached blob can lag the owner's and
    /// re-hashing a stale blob would produce a hash the signature does not cover.
    pub profile_avatar_hash: Option<String>,
    /// The banner and showcase-asset hashes the signature covers, for the same reason.
    pub profile_banner_hash: Option<String>,
    pub profile_assets_hash: Option<String>,
}

/// The subject's proof for a profile, moved as one unit because its parts are only
/// meaningful together: the blob hashes are the ones the signature covers, which the
/// stored blobs can lag. `None` at `save_profile` leaves the stored proof alone.
#[derive(Clone, Copy)]
pub(crate) struct ProfileProof<'a> {
    pub sig: &'a str,
    pub pk: &'a str,
    pub avatar_hash: &'a str,
    pub banner_hash: &'a str,
    pub assets_hash: &'a str,
}

/// A stored chat message.
pub(crate) struct StoredMessage {
    pub id: i64,
    pub peer_id: String,
    pub text: String,
    pub is_mine: bool,
    pub timestamp: i64,
    pub signature: Option<String>,
    pub public_key: Option<String>,
    pub message_id: Option<String>,
    pub edited_at: Option<i64>,
    pub hidden_at: Option<i64>,
    pub reply_to_mid: Option<String>,
    pub file_id: Option<String>,
    /// Link preview for the first URL in the message, persisted as JSON.
    pub link_preview: Option<crate::node::LinkPreviewRef>,
    /// Microsecond send timestamp for stable ordering. `None` for legacy rows, whose
    /// callers fall back to `timestamp * 1000`.
    pub order_us: Option<i64>,
    /// Signed album grouping id, `None` for a standalone message.
    pub album_id: Option<String>,
}

/// A stored channel message.
pub(crate) struct StoredChannelMessage {
    pub id: i64,
    pub server_id: String,
    pub channel_id: String,
    pub sender_id: String,
    pub text: String,
    pub is_mine: bool,
    pub timestamp: i64,
    pub signature: Option<String>,
    pub public_key: Option<String>,
    pub message_id: Option<String>,
    pub edited_at: Option<i64>,
    pub hidden_at: Option<i64>,
    pub reply_to_mid: Option<String>,
    pub file_id: Option<String>,
    /// Link preview for the first URL in the message, persisted as JSON.
    pub link_preview: Option<crate::node::LinkPreviewRef>,
    /// Microsecond send timestamp for stable ordering. `None` for legacy rows, whose
    /// callers fall back to `timestamp * 1000`.
    pub order_us: Option<i64>,
    /// Signed album grouping id, `None` for a standalone message.
    pub album_id: Option<String>,
}

/// One message row's signature-relevant fields (v2 message signing). Not a display
/// row: only what a signer or verifier needs to build the canonical payload.
pub(crate) struct MessageSigRow {
    pub text: String,
    pub timestamp: i64,
    pub signature: Option<String>,
    pub public_key: Option<String>,
    pub edited_at: Option<i64>,
    pub reply_to_mid: Option<String>,
    pub file_id: Option<String>,
    pub order_us: Option<i64>,
    pub link_preview: Option<crate::node::LinkPreviewRef>,
    pub album_id: Option<String>,
}

/// A channel message's place and claimed author, for the sync row-mutation guard.
pub(crate) struct ChannelRowOwner {
    pub server_id: String,
    pub channel_id: String,
    pub sender_id: String,
    pub public_key: Option<String>,
}

/// The device proofs of the changes riding some posts ([`MessageStore::change_proofs`]).
#[derive(Default)]
pub(crate) struct ChangeProofs {
    pub deletions: HashMap<String, crate::crdt::operations::DevProof>,
    pub cards: HashMap<String, crate::node::types::CardProof>,
    /// (message, emoji, reactor).
    pub reactions: HashMap<(String, String, String), crate::crdt::operations::DevProof>,
    pub files: HashMap<String, crate::crdt::operations::DevProof>,
}

/// A stored file metadata entry.
pub(crate) struct StoredFile {
    pub file_id: String,
    pub file_name: String,
    pub file_ext: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub chunk_count: u32,
    pub chunks_received: u32,
    pub is_image: bool,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub message_id: Option<String>,
    pub context_type: String,  // "dm" or "channel"
    pub context_id: String,    // peer_id for DM, "server_id:channel_id" for channel
    pub sender_id: String,
    pub is_mine: bool,
    pub created_at: i64,
    pub completed_at: Option<i64>,
    pub disk_path: Option<String>,
    pub hidden_at: Option<i64>,
    pub expired_at: Option<i64>,
    /// Link back to the underlying vault video when this file is its thumbnail,
    /// persisted as JSON.
    pub video_thumb: Option<crate::node::VideoThumbRef>,
    /// Share back-reference for share-backed (>34 MB) files, persisted so a
    /// manual download can rejoin the share swarm after a restart (issue #41).
    pub share_ref: Option<crate::node::ShareRef>,
    /// Tiny base64 WebP placeholder, rendered blurred under the Download button while
    /// the real bytes are gated or undownloaded.
    pub thumb_b64: Option<String>,
    /// Plaintext SHA-256 a committed file id hashes from (`node::file_commit`), kept
    /// so a card can be re-served with its commitment.
    pub sha256: Option<String>,
}

/// One sticker of the user's personal vault. `pack` is a free-form group name (`""`
/// = ungrouped) and `(pack, hash)` is the row identity, not the name.
#[derive(Clone, Debug)]
pub(crate) struct PersonalStickerRow {
    pub pack: String,
    pub hash: String,
    pub name: String,
    pub animated: bool,
    pub w: u32,
    pub h: u32,
    /// `"upload"` | `"klipy:<id>"` — provenance only, never fetched at
    /// display time (the bytes are already local and content-addressed).
    pub source: String,
    pub added_at: i64,
}

/// Encrypted SQLite message store.
pub(crate) struct MessageStore {
    conn: Connection,
    #[cfg(test)]
    _counted: open_connections::Counted,
}

/// Test-only: the connections open per database path, so a test that replaces a stopped
/// node's files waits for its last handle the way a process exit would drop it.
#[cfg(test)]
pub(crate) mod open_connections {
    use std::collections::HashMap;
    use std::sync::Mutex;

    static OPEN: Mutex<Option<HashMap<String, usize>>> = Mutex::new(None);

    fn with<T>(f: impl FnOnce(&mut HashMap<String, usize>) -> T) -> T {
        f(OPEN.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(HashMap::new))
    }

    pub(crate) struct Counted(String);

    impl Counted {
        pub(crate) fn new(path: &str) -> Self {
            with(|open| *open.entry(path.to_string()).or_default() += 1);
            Counted(path.to_string())
        }
    }

    impl Drop for Counted {
        fn drop(&mut self) {
            with(|open| {
                if let Some(n) = open.get_mut(&self.0) {
                    *n -= 1;
                    if *n == 0 {
                        open.remove(&self.0);
                    }
                }
            });
        }
    }

    /// Connections to `path` open right now, in this process.
    pub(crate) fn count(path: &str) -> usize {
        with(|open| open.get(path).copied().unwrap_or(0))
    }
}

/// Settings key prefix: when a block of a master was lifted.
const BLOCK_LIFTED_PREFIX: &str = "block_lifted:";

/// A stored profile stamped past this was planted (every ingest holds its stamp to the
/// frame), so any genuine profile replaces it; else it would outrank every real edit.
pub(crate) fn stored_profile_stamp_limit() -> i64 {
    crate::node::frame_auth::stored_stamp_limit(crate::node::frame_auth::now_ms())
}

/// One ended DM call as stored in `call_records`. Times are milliseconds;
/// `outcome` is the Dart side's word for how it ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CallRecordRow {
    pub call_id: String,
    pub peer_id: String,
    pub outgoing: bool,
    pub video: bool,
    pub outcome: String,
    pub started_at: i64,
    pub connected_at: Option<i64>,
    pub ended_at: i64,
}

/// Run one idempotent DDL statement (CREATE TABLE/INDEX …), mapping failure
/// to a labeled error. Shared with the vault ContentStore schema setup.
pub(crate) fn ddl(conn: &Connection, what: &str, sql: &str) -> Result<(), String> {
    conn.execute(sql, [])
        .map(|_| ())
        .map_err(|e| format!("Failed to create {what}: {e}"))
}

/// `app_settings` key of the next stream overlay slot to hand out.
const OVERLAY_NEXT_SLOT_SETTING: &str = "overlay_next_slot";

/// Image-check verdicts kept: a few KB of rows per thousand images, never decisive.
const MAX_IMAGE_VERDICTS: i64 = 50_000;
/// How far past the cap the table may grow before a trim pays for its scan.
const IMAGE_VERDICT_SLACK: i64 = 5_000;

fn now_ms_for_verdicts() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// One person on this device's stream overlay (`overlay_people`).
#[derive(Debug, Clone, PartialEq)]
pub struct OverlayPersonRow {
    pub master: String,
    pub slot: i64,
    pub added_at: i64,
    /// Our own picks for them, a local look (`overlay_look::normalize_local`).
    pub local_look: Option<String>,
    /// The look they shared with us.
    pub their_look: Option<String>,
    /// The field stamp `their_look` answers; 0 = none fetched.
    pub held_stamp: i64,
}

/// Run one idempotent migration statement in its own batch, ignoring the "already
/// exists" error a re-run produces. Never batch several: the first already-applied
/// statement would abort the rest.
/// The local clock a first store or fold is dated by.
fn seen_now() -> i64 {
    crate::crdt::hlc::wall_clock_ms().min(i64::MAX as u64) as i64
}

pub(crate) fn migrate(conn: &Connection, sql: &str) {
    conn.execute_batch(sql).unwrap_or(());
}

/// The upgrade seed of `cp_seen` (R3-4): every checkpoint held before 0.14, the base and
/// its parent among them, first folded at 0.
fn seed_cp_seen(conn: &Connection) {
    let Ok(mut stmt) = conn.prepare("SELECT server_id, op_json FROM crdt_ops WHERE op_json LIKE '%\"ServerCheckpoint\"%'") else { return };
    let Ok(rows) = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))) else { return };
    let held: Vec<(String, String)> = rows
        .filter_map(Result::ok)
        .filter_map(|(sid, json)| serde_json::from_str::<CrdtOp>(&json).ok().map(|op| (sid, op)))
        .filter(|(_, op)| matches!(op.payload, crate::crdt::operations::CrdtPayload::ServerCheckpoint { .. }))
        .map(|(sid, op)| (sid, hex::encode(op.content_hash())))
        .collect();
    for (sid, id) in held {
        let _ = conn.execute("INSERT OR IGNORE INTO cp_seen (server_id, content_id, first_fold_ms) VALUES (?1, ?2, 0)", params![sid, id]);
    }
}

/// One stored row per message id; rows from before ids carry none and are not keyed.
const CHANNEL_MID_INDEX: &str = "CREATE UNIQUE INDEX IF NOT EXISTS idx_channel_msgs_msg_id
     ON channel_messages (message_id) WHERE message_id IS NOT NULL;";

/// The sync watermarks seek each sender's first and last row on it
/// (`channel_sender_spans`).
const CHANNEL_SENDER_INDEX: &str = "CREATE INDEX IF NOT EXISTS idx_channel_msgs_sender_ts
     ON channel_messages (server_id, channel_id, sender_id, timestamp)";

/// Keep `channel_messages_fts` (external content, keyed by row id) in step.
const CHANNEL_FTS_TRIGGERS: &str = "
    CREATE TRIGGER IF NOT EXISTS channel_messages_fts_ai AFTER INSERT ON channel_messages BEGIN
        INSERT INTO channel_messages_fts(rowid, text) VALUES (new.id, new.text);
    END;
    CREATE TRIGGER IF NOT EXISTS channel_messages_fts_ad AFTER DELETE ON channel_messages BEGIN
        INSERT INTO channel_messages_fts(channel_messages_fts, rowid, text) VALUES('delete', old.id, old.text);
    END;
    CREATE TRIGGER IF NOT EXISTS channel_messages_fts_au AFTER UPDATE ON channel_messages BEGIN
        INSERT INTO channel_messages_fts(channel_messages_fts, rowid, text) VALUES('delete', old.id, old.text);
        INSERT INTO channel_messages_fts(rowid, text) VALUES (new.id, new.text);
    END;";

/// What a channel's history still lacks: every sender's rows from `from` up to `below`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelHole {
    pub below: i64,
    pub from: i64,
}

/// Rows one history-clear transaction deletes, so the node's writers never wait on
/// the whole clear.
const CLEAR_BATCH_ROWS: i64 = 2000;

/// Cleared ids a channel remembers within `CLEAR_SKEW_MS` of its floor; past it the
/// outright refusal moves up to the oldest one it had to forget.
const MAX_CLEARED_IDS: i64 = 4096;

/// One batch of the rows the floors refuse, into `temp.clear_batch`. The CROSS JOINs
/// keep the floors outermost: with no planner statistics SQLite walks every channel row.
const CLEAR_BATCH_SELECT: &str = "INSERT OR IGNORE INTO temp.clear_batch (id, mid)
     SELECT id, mid FROM (
         SELECT m.id, m.message_id AS mid FROM channel_floors f
         CROSS JOIN channel_messages m ON m.server_id = f.server_id AND m.channel_id = f.channel_id
         WHERE m.timestamp <= COALESCE(f.exact_from, f.floor_ts)
         UNION ALL
         SELECT m.id, m.message_id FROM channel_floors f
         CROSS JOIN channel_messages m ON m.server_id = f.server_id AND m.channel_id = f.channel_id
         WHERE m.message_id IS NULL AND m.timestamp <= f.floor_ts
         UNION ALL
         SELECT id, message_id FROM channel_messages WHERE id IN (SELECT id FROM temp.clear_near)
     ) LIMIT ?1";

/// The held rows at a remembered cleared id's time past the outright refusal, floors
/// outermost as above.
const CLEARED_NEAR_SELECT: &str = "SELECT DISTINCT m.id, m.message_id, f.server_id, f.channel_id FROM channel_floors f
     CROSS JOIN channel_cleared_ids k ON k.server_id = f.server_id AND k.channel_id = f.channel_id
     CROSS JOIN channel_messages m ON m.server_id = k.server_id AND m.channel_id = k.channel_id AND m.timestamp = k.ts
     WHERE m.message_id IS NOT NULL AND k.ts > COALESCE(f.exact_from, f.floor_ts)";

/// How far a member's clock may trail ours: a row this far behind a floor or more is
/// cleared history whatever its id; nearer, only an id this device cleared is.
const CLEAR_SKEW_MS: i64 = crate::crdt::hlc::MAX_DRIFT_MS as i64;

/// What a cleared row's id is remembered by: never the id itself.
fn cleared_id_hash(mid: &str) -> i64 {
    use sha2::{Digest, Sha256};
    let digest = Sha256::new().chain_update(b"hollow-cleared-id1:").chain_update(mid.as_bytes()).finalize();
    i64::from_be_bytes(digest[..8].try_into().unwrap_or_default())
}

/// SQL true for a row this device cleared, given the placeholders of its server,
/// channel, timestamp and `cleared_id_hash` (NULL for a row without an id).
fn floor_refuses_sql(sid: &str, cid: &str, ts: &str, hash: &str) -> String {
    format!(
        "EXISTS (SELECT 1 FROM channel_floors f WHERE f.server_id = {sid} AND f.channel_id = {cid}
           AND ({ts} <= COALESCE(f.exact_from, f.floor_ts)
                OR ({hash} IS NULL AND {ts} <= f.floor_ts)
                OR EXISTS (SELECT 1 FROM channel_cleared_ids k
                           WHERE k.server_id = {sid} AND k.channel_id = {cid} AND k.mid_hash = {hash})))"
    )
}

/// True while `channel_messages` still carries the `UNIQUE(..., text)` table
/// constraint of databases from before 0.14.
fn has_content_key(conn: &Connection) -> bool {
    conn.prepare("SELECT 1 FROM pragma_index_list('channel_messages') WHERE origin = 'u'")
        .and_then(|mut s| s.exists([]))
        .unwrap_or(false)
}

/// Give free pages back to the file system (`auto_vacuum = INCREMENTAL`): all of them,
/// or at most `pages`. The pragma frees one page per step, so it is stepped to the end;
/// `execute_batch` steps once and frees one page.
fn release_free_pages(conn: &Connection, pages: Option<u32>) {
    let sql = pages.map_or("PRAGMA incremental_vacuum".to_string(), |n| format!("PRAGMA incremental_vacuum({n})"));
    if let Ok(mut stmt) = conn.prepare(&sql) {
        if let Ok(mut rows) = stmt.query([]) {
            while let Ok(Some(_)) = rows.next() {}
        }
    }
}

fn table_exists(conn: &Connection, name: &str) -> bool {
    conn.prepare_cached("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1")
        .and_then(|mut s| s.exists([name]))
        .unwrap_or(false)
}

/// Run `body` in one `BEGIN IMMEDIATE` transaction: committed whole, or rolled back
/// whole on any error.
fn in_write_tx<T>(conn: &Connection, body: impl FnOnce(&Connection) -> Result<T, String>) -> Result<T, String> {
    conn.execute_batch("BEGIN IMMEDIATE").map_err(|e| format!("begin: {e}"))?;
    let done = body(conn).and_then(|out| conn.execute_batch("COMMIT").map(|_| out).map_err(|e| format!("commit: {e}")));
    if done.is_err() {
        let _ = conn.execute_batch("ROLLBACK");
    }
    done
}

/// Remember the ids a clear takes within `CLEAR_SKEW_MS` of a channel's floor (the
/// newest `MAX_CLEARED_IDS`; past them the outright refusal moves up) and above it,
/// and forget the ones the outright refusal now covers.
fn remember_cleared_ids(conn: &Connection, sid: &str, cid: &str, floor: i64, old_exact: Option<i64>) -> rusqlite::Result<()> {
    let mut exact = floor.saturating_sub(CLEAR_SKEW_MS).max(old_exact.unwrap_or(i64::MIN));
    let near: Vec<(String, i64)> = conn
        .prepare(
            "SELECT message_id, timestamp FROM channel_messages
             WHERE server_id = ?1 AND channel_id = ?2 AND message_id IS NOT NULL AND timestamp > ?3 AND timestamp <= ?4
             ORDER BY timestamp DESC LIMIT ?5",
        )?
        .query_map(params![sid, cid, exact, floor, MAX_CLEARED_IDS + 1], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    // A clock ahead of ours stamps past the floor, which never passes our clock: those
    // rows go by id, the nearest to the floor first.
    let fast: Vec<(String, i64)> = conn
        .prepare(
            "SELECT message_id, timestamp FROM channel_messages
             WHERE server_id = ?1 AND channel_id = ?2 AND message_id IS NOT NULL AND timestamp > ?3
             ORDER BY timestamp ASC LIMIT ?4",
        )?
        .query_map(params![sid, cid, floor, MAX_CLEARED_IDS], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    let mut put = conn.prepare("INSERT OR REPLACE INTO channel_cleared_ids (server_id, channel_id, mid_hash, ts) VALUES (?1, ?2, ?3, ?4)")?;
    for (mid, ts) in near.iter().chain(&fast) {
        put.execute(params![sid, cid, cleared_id_hash(mid), ts])?;
    }
    conn.execute(
        "DELETE FROM channel_cleared_ids WHERE server_id = ?1 AND channel_id = ?2 AND ts > ?3 AND mid_hash NOT IN (
             SELECT mid_hash FROM channel_cleared_ids WHERE server_id = ?1 AND channel_id = ?2 AND ts > ?3
             ORDER BY ts ASC LIMIT ?4)",
        params![sid, cid, floor, MAX_CLEARED_IDS],
    )?;
    // Only ids at or below the floor move the outright refusal, which never passes it.
    let forgotten: Option<i64> = conn
        .query_row(
            "SELECT ts FROM channel_cleared_ids WHERE server_id = ?1 AND channel_id = ?2 AND ts <= ?3
             ORDER BY ts DESC LIMIT 1 OFFSET ?4",
            params![sid, cid, floor, MAX_CLEARED_IDS],
            |r| r.get(0),
        )
        .ok();
    if let Some(cut) = forgotten {
        exact = exact.max(cut);
    }
    conn.execute("DELETE FROM channel_cleared_ids WHERE server_id = ?1 AND channel_id = ?2 AND ts <= ?3", params![sid, cid, exact])?;
    conn.execute("UPDATE channel_floors SET exact_from = ?3 WHERE server_id = ?1 AND channel_id = ?2", params![sid, cid, exact])?;
    Ok(())
}

/// Cleared senders a channel's asks name; past them the oldest go (their rows come back
/// in full to an ask and are refused).
const MAX_CLEARED_SENDERS: i64 = 4096;

/// Cleared rows a channel counts one by one near its newest; past them the oldest fold
/// into their day, which a digest ending among them then counts whole.
const MAX_CLEARED_TAIL: i64 = 4096;

/// Count one clear batch (`temp.clear_batch`) into what the cleared channels' asks still
/// count as held, in the batch's own transaction, before its rows go.
fn count_cleared_batch(conn: &Connection) -> rusqlite::Result<()> {
    let rows: Vec<(String, String, String, Option<String>, i64)> = conn
        .prepare_cached(
            "SELECT server_id, channel_id, sender_id, message_id, timestamp FROM channel_messages
             WHERE id IN (SELECT id FROM temp.clear_batch)",
        )?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))?
        .collect::<rusqlite::Result<_>>()?;
    let mut oldest: BTreeMap<(String, String), i64> = BTreeMap::new();
    {
        let mut sender = conn.prepare_cached(
            "INSERT INTO channel_cleared_senders (server_id, channel_id, sender_id, last_ts) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(server_id, channel_id, sender_id) DO UPDATE SET last_ts = MAX(last_ts, excluded.last_ts)",
        )?;
        let mut tail = conn.prepare_cached("INSERT OR IGNORE INTO channel_cleared_tail (server_id, channel_id, ts, h) VALUES (?1, ?2, ?3, ?4)")?;
        for (sid, cid, from, mid, ts) in &rows {
            sender.execute(params![sid, cid, from, ts])?;
            if let Some(mid) = mid {
                tail.execute(params![sid, cid, ts, mid_hash(mid) as i64])?;
            }
            let first = oldest.entry((sid.clone(), cid.clone())).or_insert(*ts);
            *first = (*first).min(*ts);
        }
    }
    count_cleared_proofs(conn)?;
    for ((sid, cid), first) in oldest {
        conn.execute(
            "UPDATE channel_floors SET history_from = MIN(COALESCE(history_from, ?3), ?3) WHERE server_id = ?1 AND channel_id = ?2",
            params![sid, cid, first],
        )?;
        settle_cleared_counts(conn, &sid, &cid)?;
    }
    Ok(())
}

/// Proving devices a server keeps per sender from its clears; past them the oldest go.
const MAX_CLEARED_DEVICES: i64 = 64;

/// Proving (sender, device) pairs a server keeps from its clears; past them the oldest go.
const MAX_CLEARED_DEVICE_ROWS: i64 = 4096;

/// The device a stored post-change proof names, and a card's own date.
fn proof_names(json: &str) -> Option<(String, Option<i64>)> {
    #[derive(serde::Deserialize)]
    struct Named {
        device: String,
        #[serde(default)]
        at: Option<i64>,
    }
    serde_json::from_str::<Named>(json).ok().map(|n| (n.device, n.at))
}

/// Count what each device proved in one clear batch, at the dates
/// `MessageStore::newest_post_of_device` reads, so a retire's window stays where it
/// was before the rows went.
fn count_cleared_proofs(conn: &Connection) -> rusqlite::Result<()> {
    const IN_BATCH: &str = "cm.id IN (SELECT id FROM temp.clear_batch)";
    // (server, sender or reactor, the date, the device or its proof JSON); is JSON, is a reaction.
    let sql: [(String, bool, bool); 5] = [
        (format!("SELECT cm.server_id, cm.sender_id, MAX(cm.timestamp, COALESCE(cm.edited_at, cm.timestamp)), cm.dev_device
                  FROM channel_messages cm WHERE {IN_BATCH} AND cm.dev_device IS NOT NULL"), false, false),
        (format!("SELECT cm.server_id, cm.sender_id, MAX(cm.timestamp, md.deleted_at), md.dev
                  FROM message_deletions md JOIN channel_messages cm ON cm.message_id = md.message_id WHERE {IN_BATCH} AND md.dev IS NOT NULL"), true, false),
        (format!("SELECT cm.server_id, cm.sender_id, cm.timestamp, cm.lp_dev FROM channel_messages cm WHERE {IN_BATCH} AND cm.lp_dev IS NOT NULL"), true, false),
        (format!("SELECT cm.server_id, mr.peer_id, MAX(cm.timestamp, mr.added_at), mr.dev
                  FROM message_reactions mr JOIN channel_messages cm ON cm.message_id = mr.message_id WHERE {IN_BATCH} AND mr.dev IS NOT NULL"), true, true),
        (format!("SELECT cm.server_id, cm.sender_id, cm.timestamp, f.meta_dev
                  FROM files f JOIN channel_messages cm ON cm.message_id = f.message_id WHERE {IN_BATCH} AND f.meta_dev IS NOT NULL"), true, false),
    ];
    let mut newest: BTreeMap<(String, String, String, bool), i64> = BTreeMap::new();
    for (sql, json, reactor) in &sql {
        let rows: Vec<(String, String, i64, String)> = conn
            .prepare(sql)?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
            .collect::<rusqlite::Result<_>>()?;
        for (sid, who, date, named) in rows {
            let (device, date) = if *json {
                let Some((device, at)) = proof_names(&named) else { continue };
                (device, at.map_or(date, |at| at.max(date)))
            } else {
                (named, date)
            };
            let top = newest.entry((sid, who, device, *reactor)).or_insert(date);
            *top = (*top).max(date);
        }
    }
    let mut servers: Vec<String> = Vec::new();
    {
        let mut put = conn.prepare_cached(
            "INSERT INTO channel_cleared_devices (server_id, sender_id, device, reactor, last_ts) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(server_id, sender_id, device, reactor) DO UPDATE SET last_ts = MAX(last_ts, excluded.last_ts)",
        )?;
        for ((sid, who, device, reactor), date) in newest {
            put.execute(params![sid, who, device, reactor, date])?;
            if servers.last() != Some(&sid) {
                servers.push(sid);
            }
        }
    }
    for sid in servers {
        conn.execute(
            "DELETE FROM channel_cleared_devices WHERE server_id = ?1 AND (device, reactor) NOT IN (
                 SELECT d.device, d.reactor FROM channel_cleared_devices d
                 WHERE d.server_id = ?1 AND d.sender_id = channel_cleared_devices.sender_id
                 ORDER BY d.last_ts DESC, d.device, d.reactor LIMIT ?2)",
            params![sid, MAX_CLEARED_DEVICES],
        )?;
        conn.execute(
            "DELETE FROM channel_cleared_devices WHERE server_id = ?1 AND (sender_id, device, reactor) NOT IN (
                 SELECT sender_id, device, reactor FROM channel_cleared_devices WHERE server_id = ?1
                 ORDER BY last_ts DESC, sender_id, device, reactor LIMIT ?2)",
            params![sid, MAX_CLEARED_DEVICE_ROWS],
        )?;
    }
    Ok(())
}

/// Keep one cleared channel's counts bounded. A later ask's `since` is at least the newest
/// cleared stamp, so its digest ends at or past that stamp's lookback and starts at or
/// past the window before it: rows below the lookback fold into their day (counted whole
/// by every such digest), days before the window go, and only the newest senders stay.
fn settle_cleared_counts(conn: &Connection, sid: &str, cid: &str) -> rusqlite::Result<()> {
    let top: Option<i64> = conn.query_row(
        "SELECT MAX(last_ts) FROM channel_cleared_senders WHERE server_id = ?1 AND channel_id = ?2",
        params![sid, cid],
        |r| r.get(0),
    )?;
    let Some(top) = top else { return Ok(()) };
    let cut = top.saturating_sub(SYNC_LOOKBACK_MS);
    let first_day = cut.saturating_sub(SYNC_GAP_WINDOW_MS).div_euclid(DAY_MS);
    let folded = "server_id = ?1 AND channel_id = ?2 AND (ts < ?3 OR (ts, h) NOT IN (
             SELECT ts, h FROM channel_cleared_tail WHERE server_id = ?1 AND channel_id = ?2 ORDER BY ts DESC LIMIT ?4))";
    let fold: Vec<(i64, i64)> = conn
        .prepare(&format!("SELECT ts, h FROM channel_cleared_tail WHERE {folded}"))?
        .query_map(params![sid, cid, cut, MAX_CLEARED_TAIL], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    conn.execute(&format!("DELETE FROM channel_cleared_tail WHERE {folded}"), params![sid, cid, cut, MAX_CLEARED_TAIL])?;
    let mut days: BTreeMap<i64, (i64, u64)> = BTreeMap::new();
    for (ts, h) in fold {
        let day = days.entry(ts.div_euclid(DAY_MS)).or_default();
        day.0 += 1;
        day.1 ^= h as u64;
    }
    for (day, (n, h)) in days {
        let held: Option<(i64, i64)> = conn
            .query_row(
                "SELECT n, h FROM channel_cleared_days WHERE server_id = ?1 AND channel_id = ?2 AND day = ?3",
                params![sid, cid, day],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let (n0, h0) = held.unwrap_or_default();
        conn.execute(
            "INSERT OR REPLACE INTO channel_cleared_days (server_id, channel_id, day, n, h) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![sid, cid, day, n0 + n, (h0 as u64 ^ h) as i64],
        )?;
    }
    conn.execute("DELETE FROM channel_cleared_days WHERE server_id = ?1 AND channel_id = ?2 AND day < ?3", params![sid, cid, first_day])?;
    conn.execute("DELETE FROM channel_cleared_tail WHERE server_id = ?1 AND channel_id = ?2 AND ts < ?3", params![sid, cid, first_day.saturating_mul(DAY_MS)])?;
    conn.execute(
        "DELETE FROM channel_cleared_senders WHERE server_id = ?1 AND channel_id = ?2 AND sender_id NOT IN (
             SELECT sender_id FROM channel_cleared_senders WHERE server_id = ?1 AND channel_id = ?2
             ORDER BY last_ts DESC, sender_id LIMIT ?3)",
        params![sid, cid, MAX_CLEARED_SENDERS],
    )?;
    Ok(())
}

/// Move the last rows of 0.12's one-row-per-device `revoked_devices` into
/// `revoked_marks` and drop it, in one transaction. Until it lands, reads and lifts
/// take the old table too, so a failed move never lets a removed device back.
fn move_old_revocations(conn: &Connection) -> Result<(), String> {
    if !table_exists(conn, "revoked_devices") {
        return Ok(());
    }
    in_write_tx(conn, |conn| {
        conn.execute_batch(
            "INSERT OR IGNORE INTO revoked_marks (device_peer_id, master_peer_id)
                 SELECT device_peer_id, master_peer_id FROM revoked_devices;
             DROP TABLE revoked_devices;",
        )
        .map_err(|e| e.to_string())
    })
}

/// A column definition read back from the table being rebuilt: only the plain shapes
/// our own DDL writes, so nothing a foreign database's schema says is run as SQL.
fn plain_column(name: &str, ty: &str, notnull: bool, default: Option<&str>, pk: bool) -> Option<String> {
    let name_ok = !name.is_empty()
        && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
        && !name.as_bytes()[0].is_ascii_digit();
    if !name_ok || default.is_some() {
        return None;
    }
    if pk {
        return (name == "id" && ty.eq_ignore_ascii_case("INTEGER")).then(|| "id INTEGER PRIMARY KEY AUTOINCREMENT".to_string());
    }
    let ty = ["TEXT", "INTEGER", "BLOB", "REAL"].into_iter().find(|t| t.eq_ignore_ascii_case(ty))?;
    Some(format!("{name} {ty}{}", if notnull { " NOT NULL" } else { "" }))
}

/// Drain a mapped-row iterator into a Vec, labeling the first read error.
fn collect_rows<T>(
    rows: impl Iterator<Item = rusqlite::Result<T>>,
    what: &str,
) -> Result<Vec<T>, String> {
    let mut out = Vec::new();
    for row in rows {
        out.push(row.map_err(|e| format!("Failed to read {what} row: {e}"))?);
    }
    Ok(out)
}

/// One sender of a channel: its oldest row (or, for a per-sender ask, its first row
/// the ask serves) and its newest row.
#[derive(Clone)]
struct SenderSpan {
    sender: String,
    first: i64,
    last: i64,
}

/// Senders a per-sender page reads one by one, past which a pass of the timestamp
/// index is cheap: at most this many.
const MAX_EARLY_SENDERS: usize = 64;

/// Where a per-sender page splits `spans` (sorted by `first`): the senders before the
/// split have no row at or after the split's first row, so the timestamp pass starts
/// there. The latest such split, so a sender that went quiet long ago never makes the
/// pass walk the rows everyone posted since.
fn early_sender_split(spans: &[SenderSpan]) -> usize {
    let mut split = 0;
    let mut newest = i64::MIN;
    for (i, span) in spans.iter().enumerate().take(MAX_EARLY_SENDERS + 1) {
        if i > 0 && newest < span.first {
            split = i;
        }
        newest = newest.max(span.last);
    }
    split
}

/// A signed per-message evidence row: (emoji, peer_id, at_ms, signature,
/// public_key) — shape shared by reaction sync rows and reaction removals.
pub(crate) type SignedEmojiRow = (String, String, i64, Option<String>, Option<String>);

/// A stored Olm session: (peer_id, pickle_json, sends, reads), the pickle wiped on drop.
pub(crate) type OlmSessionRow = (String, zeroize::Zeroizing<String>, i64, i64);

/// Column list every DM-message query selects, in [`dm_message_from_row`] order.
const DM_MSG_COLS: &str = "id, peer_id, text, is_mine, timestamp, signature, public_key, message_id, edited_at, hidden_at, reply_to_mid, file_id, link_preview_json, order_us, album_id";

/// Column list every channel-message query selects, in [`channel_message_from_row`] order.
const CHANNEL_MSG_COLS: &str = "id, server_id, channel_id, sender_id, text, is_mine, timestamp, signature, public_key, message_id, edited_at, hidden_at, reply_to_mid, file_id, link_preview_json, order_us, album_id";

/// The column tail shared by DM and channel message rows, in select order.
struct MsgTail {
    text: String,
    is_mine: bool,
    timestamp: i64,
    signature: Option<String>,
    public_key: Option<String>,
    message_id: Option<String>,
    edited_at: Option<i64>,
    hidden_at: Option<i64>,
    reply_to_mid: Option<String>,
    file_id: Option<String>,
    link_preview: Option<crate::node::LinkPreviewRef>,
    order_us: Option<i64>,
    album_id: Option<String>,
}

/// Read the shared message-column tail starting at column index `base` (2 for DM
/// rows, 4 for channel rows).
fn msg_tail_from_row(row: &rusqlite::Row<'_>, base: usize) -> rusqlite::Result<MsgTail> {
    Ok(MsgTail {
        text: row.get(base)?,
        is_mine: row.get::<_, i32>(base + 1)? != 0,
        timestamp: row.get(base + 2)?,
        signature: row.get(base + 3)?,
        public_key: row.get(base + 4)?,
        message_id: row.get(base + 5)?,
        edited_at: row.get(base + 6)?,
        hidden_at: row.get(base + 7)?,
        reply_to_mid: row.get(base + 8)?,
        file_id: row.get(base + 9)?,
        link_preview: row.get::<_, Option<String>>(base + 10)?
            .and_then(|s| serde_json::from_str(&s).ok()),
        order_us: row.get(base + 11)?,
        album_id: row.get(base + 12)?,
    })
}

/// Map one row selected via [`DM_MSG_COLS`] to a StoredMessage.
fn dm_message_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredMessage> {
    let t = msg_tail_from_row(row, 2)?;
    Ok(StoredMessage {
        id: row.get(0)?,
        peer_id: row.get(1)?,
        text: t.text,
        is_mine: t.is_mine,
        timestamp: t.timestamp,
        signature: t.signature,
        public_key: t.public_key,
        message_id: t.message_id,
        edited_at: t.edited_at,
        hidden_at: t.hidden_at,
        reply_to_mid: t.reply_to_mid,
        file_id: t.file_id,
        link_preview: t.link_preview,
        order_us: t.order_us,
        album_id: t.album_id,
    })
}

/// Column list every files query selects, in [`stored_file_from_row`] order.
const FILE_COLS: &str = "file_id, file_name, file_ext, mime_type, size_bytes, chunk_count, chunks_received, is_image, width, height, message_id, context_type, context_id, sender_id, is_mine, created_at, completed_at, disk_path, hidden_at, video_thumb_json, expired_at, share_ref_json, thumb_b64, sha256";

/// Map one row selected via [`FILE_COLS`] to a StoredFile.
fn stored_file_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredFile> {
    Ok(StoredFile {
        file_id: row.get(0)?,
        file_name: row.get(1)?,
        file_ext: row.get(2)?,
        mime_type: row.get(3)?,
        size_bytes: row.get::<_, i64>(4)? as u64,
        chunk_count: row.get::<_, u32>(5)?,
        chunks_received: row.get::<_, u32>(6)?,
        is_image: row.get::<_, i32>(7)? != 0,
        width: row.get::<_, Option<i64>>(8)?.map(|v| v as u32),
        height: row.get::<_, Option<i64>>(9)?.map(|v| v as u32),
        message_id: row.get(10)?,
        context_type: row.get(11)?,
        context_id: row.get(12)?,
        sender_id: row.get(13)?,
        is_mine: row.get::<_, i32>(14)? != 0,
        created_at: row.get(15)?,
        completed_at: row.get(16)?,
        disk_path: row.get(17)?,
        hidden_at: row.get(18)?,
        expired_at: row.get(20)?,
        video_thumb: MessageStore::parse_video_thumb_json(row.get::<_, Option<String>>(19)?),
        share_ref: row
            .get::<_, Option<String>>(21)?
            .and_then(|s| serde_json::from_str(&s).ok()),
        thumb_b64: row.get(22)?,
        sha256: row.get(23)?,
    })
}

/// Video extensions the media viewer treats as playable. Mirror of `_videoExtensions`
/// in `lib/src/ui/chat/file_attachment_widget.dart`; the two must stay in step.
pub(crate) const MEDIA_VIDEO_EXTS: &[&str] = &["mp4", "webm", "mov", "mkv", "avi", "m4v"];

/// One row of a conversation's media, with the message time it belongs to.
pub(crate) struct StoredMediaItem {
    pub file: StoredFile,
    /// Milliseconds. The owning message's timestamp, else the file's `created_at`.
    pub ts: i64,
    pub content_id: Option<String>,
    pub album_id: Option<String>,
}

/// Map one full profile row, blobs and proof triple included, to a StoredProfile.
fn profile_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredProfile> {
    Ok(StoredProfile {
        peer_id: row.get(0)?,
        display_name: row.get(1)?,
        status: row.get(2)?,
        about_me: row.get(3)?,
        updated_at: row.get(4)?,
        avatar_bytes: row.get(5)?,
        banner_bytes: row.get(6)?,
        twitch_username: row.get::<_, String>(7).unwrap_or_default(),
        showcase_board: row.get::<_, String>(8).unwrap_or_default(),
        showcase_assets: row.get(9).unwrap_or(None),
        profile_sig: row.get(10).unwrap_or(None),
        profile_pk: row.get(11).unwrap_or(None),
        profile_avatar_hash: row.get(12).unwrap_or(None),
        avatar_frame: row.get::<_, String>(13).unwrap_or_default(),
        avatar_anim: row.get::<_, String>(14).unwrap_or_default(),
        banner_anim: row.get::<_, String>(15).unwrap_or_default(),
        support_creds: row.get::<_, String>(16).unwrap_or_default(),
        profile_banner_hash: row.get(17).unwrap_or(None),
        profile_assets_hash: row.get(18).unwrap_or(None),
    })
}

/// Map one light profile row (no blobs) to a StoredProfile. The frame is an ID, not
/// bytes, so it rides the light load: every list that renders an avatar needs it.
fn profile_light_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredProfile> {
    Ok(StoredProfile {
        peer_id: row.get(0)?,
        display_name: row.get(1)?,
        status: row.get(2)?,
        about_me: row.get(3)?,
        updated_at: row.get(4)?,
        avatar_bytes: None,
        banner_bytes: None,
        twitch_username: row.get::<_, String>(5).unwrap_or_default(),
        showcase_board: row.get::<_, String>(6).unwrap_or_default(),
        showcase_assets: None,
        // Light loads are for RENDERING; relaying needs `load_profile`.
        profile_sig: None,
        profile_pk: None,
        profile_avatar_hash: None,
        profile_banner_hash: None,
        profile_assets_hash: None,
        avatar_frame: row.get::<_, String>(7).unwrap_or_default(),
        // Hashes, not bytes: a list needs to know an animated variant exists at all.
        avatar_anim: row.get::<_, String>(8).unwrap_or_default(),
        banner_anim: row.get::<_, String>(9).unwrap_or_default(),
        // Small capped text: renderers need it to light a support mark.
        support_creds: row.get::<_, String>(10).unwrap_or_default(),
    })
}

/// Map one row selected via [`CHANNEL_MSG_COLS`] to a StoredChannelMessage.
fn channel_message_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredChannelMessage> {
    let t = msg_tail_from_row(row, 4)?;
    Ok(StoredChannelMessage {
        id: row.get(0)?,
        server_id: row.get(1)?,
        channel_id: row.get(2)?,
        sender_id: row.get(3)?,
        text: t.text,
        is_mine: t.is_mine,
        timestamp: t.timestamp,
        signature: t.signature,
        public_key: t.public_key,
        message_id: t.message_id,
        edited_at: t.edited_at,
        hidden_at: t.hidden_at,
        reply_to_mid: t.reply_to_mid,
        file_id: t.file_id,
        link_preview: t.link_preview,
        order_us: t.order_us,
        album_id: t.album_id,
    })
}

/// A master-signed card as stored; `node::profile_card` verifies it on the way in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredCard {
    pub master: String,
    pub display_name: String,
    pub updated_at: i64,
    pub avatar_hash: String,
    pub sig: String,
    pub pk: String,
}

/// What clearing this device's server history took away.
#[derive(Debug, Default)]
pub struct ClearedHistory {
    pub messages: u64,
    /// The cleared messages' files (`file_id`, `file_ext`), whose rows are gone: the
    /// caller unlinks our own download of each through `at_rest`.
    pub files: Vec<(String, String)>,
}

/// How a channel row fared at [`MessageStore::insert_channel_message_judged`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChannelInsert {
    Stored,
    /// The id is already stored.
    Duplicate,
    /// History this device cleared: nothing about it may show or be stored.
    Cleared,
}

/// The path of a store that lives in this process's memory only, for as long as one
/// connection to it stays open; `name` keeps one node's store apart from another's.
pub fn guest_store_path(name: &str) -> String {
    format!("file:hollow-guest-{name}?mode=memory&cache=shared")
}

#[cfg(test)]
thread_local! {
    /// Opens made on this thread, so a test can prove an event-loop handler left the
    /// store to a blocking thread.
    pub(crate) static OPENS_ON_THIS_THREAD: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}

impl MessageStore {
    /// The database file this store reads, as SQLite names it.
    pub(crate) fn db_path(&self) -> Option<String> {
        self.conn.path().map(str::to_string)
    }
}

impl MessageStore {
    /// Open (or create) an encrypted database at `path` using `passphrase`.
    pub fn open(path: &str, passphrase: &str) -> Result<Self, String> {
        #[cfg(test)]
        OPENS_ON_THIS_THREAD.with(|n| n.set(n.get() + 1));
        #[cfg(test)]
        let started = std::time::Instant::now();
        let opened = Self::open_inner(path, passphrase);
        #[cfg(test)]
        super::store_pool::meter::note_open(started.elapsed().as_nanos() as u64);
        opened
    }

    fn open_inner(path: &str, passphrase: &str) -> Result<Self, String> {
        #[cfg(test)]
        let counted = open_connections::Counted::new(path);
        let conn =
            Connection::open(path).map_err(|e| format!("Failed to open database: {e}"))?;

        // Hex key format, so no quoting or injection question arises.
        conn.execute_batch(&format!("PRAGMA key = \"x'{}'\";", passphrase))
            .map_err(|e| format!("Failed to set encryption key: {e}"))?;

        // auto_vacuum conversion is deliberately NOT done here. `open()` is the universal
        // path and the CrdtStore/CryptoStore actors hold long-lived connections to the
        // same WAL file, so running `PRAGMA auto_vacuum` plus `VACUUM` on every concurrent
        // open raced the SQLCipher codec and spewed `hmac check failed for pgno=1`. The
        // one-time migration runs in a single-connection window at startup instead.

        // Journal mode: WAL everywhere EXCEPT iOS, where messages.db lives in the shared
        // App Group container for the NSE. WAL keeps a persistent `-shm` lock file open,
        // and RunningBoard kills any app suspended while holding a lock in a shared
        // container (`EXC_CRASH 0xdead10cc`); a rollback journal locks only during a
        // transaction. Chat write volume makes the speed difference negligible.
        #[cfg(target_os = "ios")]
        let journal_pragma = "PRAGMA journal_mode = TRUNCATE;";
        #[cfg(not(target_os = "ios"))]
        let journal_pragma = "PRAGMA journal_mode = WAL;";

        conn.execute_batch(&format!(
            "{journal_pragma}
             PRAGMA synchronous = NORMAL;
             PRAGMA cache_size = -8000;
             PRAGMA temp_store = MEMORY;
             PRAGMA busy_timeout = 4000;"
        )).map_err(|e| format!("Failed to set performance PRAGMAs: {e}"))?;

        // The schema DDL used to replay on EVERY open, costing real milliseconds on the
        // hot per-message paths, so it runs once per process per DB path instead. A fresh
        // process after an app update still self-heals new columns on its first open, and
        // the mutex serializes first-open DDL against concurrent opens.
        //
        // The path memo alone is NOT enough: a wipe (and the unit tests) can delete the
        // file and re-open the SAME path in one process, so a one-row sqlite_master probe
        // makes sure a schemaless file always gets the DDL.
        {
            use std::sync::{Mutex as StdMutex, OnceLock};
            static SCHEMA_DONE: OnceLock<StdMutex<std::collections::HashSet<String>>> =
                OnceLock::new();
            let done = SCHEMA_DONE
                .get_or_init(|| StdMutex::new(std::collections::HashSet::new()));
            let mut ready = done
                .lock()
                .map_err(|e| format!("Schema gate lock poisoned: {e}"))?;
            let has_core_table: bool = conn
                .query_row(
                    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='messages' LIMIT 1",
                    [],
                    |_| Ok(()),
                )
                .is_ok();
            if !ready.contains(path) || !has_core_table {
                Self::init_schema(&conn)?;
                ready.insert(path.to_string());
            }
        }

        Ok(MessageStore {
            conn,
            #[cfg(test)]
            _counted: counted,
        })
    }

    /// All schema DDL and idempotent data migrations. Runs once per process per DB
    /// path, gated in `open()`.
    fn init_schema(conn: &Connection) -> Result<(), String> {
        ddl(conn, "messages table",
            "CREATE TABLE IF NOT EXISTS messages (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                peer_id   TEXT    NOT NULL,
                text      TEXT    NOT NULL,
                is_mine   INTEGER NOT NULL,
                timestamp INTEGER NOT NULL
            )")?;

        ddl(conn, "index",
            "CREATE INDEX IF NOT EXISTS idx_messages_peer_ts ON messages (peer_id, timestamp)")?;

        // Olm account pickle (singleton row, id=1).
        ddl(conn, "olm_account table",
            "CREATE TABLE IF NOT EXISTS olm_account (
                id     INTEGER PRIMARY KEY CHECK (id = 1),
                pickle TEXT NOT NULL
            )")?;

        // `sends`, `reads`: how far the session has come (crypto `SessionVersion`); a
        // write that has not come further than the stored row is refused (AR-30).
        ddl(conn, "olm_sessions table",
            "CREATE TABLE IF NOT EXISTS olm_sessions (
                peer_id TEXT PRIMARY KEY,
                pickle  TEXT NOT NULL,
                sends   INTEGER NOT NULL DEFAULT 0,
                reads   INTEGER NOT NULL DEFAULT 0
            )")?;
        migrate(conn, "ALTER TABLE olm_sessions ADD COLUMN sends INTEGER NOT NULL DEFAULT 0");
        migrate(conn, "ALTER TABLE olm_sessions ADD COLUMN reads INTEGER NOT NULL DEFAULT 0");
        // A removed session's last version, so no copy of it written later comes back.
        ddl(conn, "olm_session_floors table",
            "CREATE TABLE IF NOT EXISTS olm_session_floors (
                peer_id TEXT PRIMARY KEY,
                sends   INTEGER NOT NULL,
                reads   INTEGER NOT NULL
            )")?;

        // Per sending device, the newest seal time of a frame our sessions decrypted.
        ddl(conn, "olm_read_marks table",
            "CREATE TABLE IF NOT EXISTS olm_read_marks (
                peer_id   TEXT PRIMARY KEY,
                sealed_ms INTEGER NOT NULL
            )")?;

        // The live-frame replay guard's nonces, kept until their frames turn stale so
        // the guard outlives a restart (AR-35). `share` is whom the row is charged to (a
        // placed sender's master, else the sender) and `placed` the pool it fills.
        ddl(conn, "live_frame_nonces table",
            "CREATE TABLE IF NOT EXISTS live_frame_nonces (
                sender     TEXT    NOT NULL,
                nonce      BLOB    NOT NULL,
                expires_ms INTEGER NOT NULL,
                share      TEXT    NOT NULL DEFAULT '',
                placed     INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (sender, nonce)
            )")?;
        migrate(conn, "ALTER TABLE live_frame_nonces ADD COLUMN share TEXT NOT NULL DEFAULT ''");
        migrate(conn, "ALTER TABLE live_frame_nonces ADD COLUMN placed INTEGER NOT NULL DEFAULT 0");
        ddl(conn, "live_frame_nonces share index",
            "CREATE INDEX IF NOT EXISTS live_frame_nonces_share ON live_frame_nonces (placed, share, expires_ms)")?;

        // No content key: two distinct posts alike in one millisecond are two rows, and a
        // message id is stored once (`CHANNEL_MID_INDEX`). A database from before keeps
        // its `UNIQUE(..., text)` table until `rebuild_channel_messages` runs at start.
        ddl(conn, "channel_messages table",
            "CREATE TABLE IF NOT EXISTS channel_messages (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                server_id  TEXT    NOT NULL,
                channel_id TEXT    NOT NULL,
                sender_id  TEXT    NOT NULL,
                text       TEXT    NOT NULL,
                is_mine    INTEGER NOT NULL,
                timestamp  INTEGER NOT NULL
            )")?;

        ddl(conn, "channel_messages index",
            "CREATE INDEX IF NOT EXISTS idx_channel_msgs ON channel_messages (server_id, channel_id, timestamp)")?;

        migrate(conn, "DROP INDEX IF EXISTS idx_channel_msgs_unique;");
        migrate(conn, "DROP INDEX IF EXISTS idx_channel_msgs_unique_legacy;");

        // -- CRDT tables (Phase 3) --

        ddl(conn, "servers table",
            "CREATE TABLE IF NOT EXISTS servers (
                server_id  TEXT PRIMARY KEY,
                state_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            )")?;

        ddl(conn, "crdt_ops table",
            "CREATE TABLE IF NOT EXISTS crdt_ops (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                server_id   TEXT NOT NULL,
                hlc_ms      INTEGER NOT NULL,
                hlc_counter INTEGER NOT NULL,
                author      TEXT NOT NULL,
                op_json     TEXT NOT NULL,
                UNIQUE(server_id, hlc_ms, hlc_counter, author)
            )")?;

        ddl(conn, "crdt_ops index",
            "CREATE INDEX IF NOT EXISTS idx_crdt_ops_server ON crdt_ops (server_id, hlc_ms)")?;
        // 0.14: a row the fold refuses now is parked (kept, not folded) until this epoch ms.
        migrate(conn, "ALTER TABLE crdt_ops ADD COLUMN parked_until INTEGER");
        // 0.14 (DEVICE_PROOF_DESIGN section 7): when this replica first stored a row, and
        // first folded a checkpoint as its base. Rows and checkpoints from before the
        // upgrade read 0, "before any T" (R3-4).
        migrate(conn, "ALTER TABLE crdt_ops ADD COLUMN seen_ms INTEGER NOT NULL DEFAULT 0");
        // The content id `seen_ms` dates: other content at the key is first stored anew.
        migrate(conn, "ALTER TABLE crdt_ops ADD COLUMN content_h TEXT NOT NULL DEFAULT ''");
        // 0.14 (section 7, N6): when each of our own kept rows was first dominated.
        ddl(conn, "own_kept table",
            "CREATE TABLE IF NOT EXISTS own_kept (
                server_id   TEXT NOT NULL,
                author      TEXT NOT NULL,
                hlc_ms      INTEGER NOT NULL,
                hlc_counter INTEGER NOT NULL,
                since_ms    INTEGER NOT NULL,
                PRIMARY KEY (server_id, author, hlc_ms, hlc_counter)
            )")?;
        ddl(conn, "floor_pending table",
            "CREATE TABLE IF NOT EXISTS floor_pending (
                server_id TEXT PRIMARY KEY,
                row_json  TEXT NOT NULL
            )")?;
        let upgrade = !table_exists(conn, "cp_seen");
        ddl(conn, "cp_seen table",
            "CREATE TABLE IF NOT EXISTS cp_seen (
                server_id     TEXT NOT NULL,
                content_id    TEXT NOT NULL,
                first_fold_ms INTEGER NOT NULL,
                PRIMARY KEY (server_id, content_id)
            )")?;
        if upgrade {
            seed_cp_seen(conn);
        }

        ddl(conn, "hlc_state table",
            "CREATE TABLE IF NOT EXISTS hlc_state (
                id          INTEGER PRIMARY KEY CHECK (id = 1),
                physical_ms INTEGER NOT NULL,
                counter     INTEGER NOT NULL,
                actor       TEXT NOT NULL
            )")?;

        // ALTER TABLE ADD COLUMN is safe for nullable columns; ignore "already exists".
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN signature TEXT;");
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN public_key TEXT;");
        migrate(conn, "ALTER TABLE messages ADD COLUMN signature TEXT;");
        migrate(conn, "ALTER TABLE messages ADD COLUMN public_key TEXT;");

        // DM dedup index, PARTIAL (message_id IS NULL) for the same reason as the channel
        // one: the original full-table content index made INSERT OR IGNORE silently drop
        // a distinct same-millisecond identical-text message AND its MessageReceived
        // event. Rows with a message_id dedup by dm_message_exists() at every insert site,
        // and the content index survives only as a backstop for legacy rows.
        migrate(conn, "DROP INDEX IF EXISTS idx_messages_dedup;");
        migrate(conn,
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_dedup_legacy
             ON messages (peer_id, timestamp, text, is_mine)
             WHERE message_id IS NULL;");

        // -- User profiles (Phase 3.5) --
        ddl(conn, "user_profiles table",
            "CREATE TABLE IF NOT EXISTS user_profiles (
                peer_id      TEXT PRIMARY KEY,
                display_name TEXT NOT NULL DEFAULT '',
                status       TEXT NOT NULL DEFAULT '',
                about_me     TEXT NOT NULL DEFAULT '',
                updated_at   INTEGER NOT NULL DEFAULT 0
            )")?;

        // ORDERED mixed list: an EMPTY label marks a swallowed idempotent migration (own
        // batch, "already exists" ignored), a non-empty label is fail-fast DDL. One loop
        // rather than a run of periodic calls, which Sonar CPD self-matches.
        const PHASE35_SCHEMA: &[(&str, &str)] = &[
            // Editing columns, then the message_id indexes edit lookups need.
            ("", "ALTER TABLE messages ADD COLUMN message_id TEXT;"),
            ("", "ALTER TABLE messages ADD COLUMN edited_at INTEGER;"),
            ("", "ALTER TABLE channel_messages ADD COLUMN message_id TEXT;"),
            ("", "ALTER TABLE channel_messages ADD COLUMN edited_at INTEGER;"),
            ("", "CREATE INDEX IF NOT EXISTS idx_messages_msg_id ON messages (message_id);"),
            ("", CHANNEL_MID_INDEX),
            // Edit history preserves previous text as evidence, plus prev_* columns for the
            // edit chain's provenance.
            ("message_edits table",
             "CREATE TABLE IF NOT EXISTS message_edits (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id  TEXT    NOT NULL,
                old_text    TEXT    NOT NULL,
                new_text    TEXT    NOT NULL,
                edited_at   INTEGER NOT NULL,
                signature   TEXT,
                public_key  TEXT
            )"),
            ("message_edits index",
             "CREATE INDEX IF NOT EXISTS idx_edits_msg_id ON message_edits (message_id)"),
            ("", "ALTER TABLE message_edits ADD COLUMN prev_signature TEXT;"),
            ("", "ALTER TABLE message_edits ADD COLUMN prev_public_key TEXT;"),
            ("", "ALTER TABLE message_edits ADD COLUMN prev_timestamp INTEGER;"),
            // hidden_at for deletion/hiding, plus the deletion evidence table holding the
            // text at deletion time.
            ("", "ALTER TABLE messages ADD COLUMN hidden_at INTEGER;"),
            ("", "ALTER TABLE channel_messages ADD COLUMN hidden_at INTEGER;"),
            ("message_deletions table",
             "CREATE TABLE IF NOT EXISTS message_deletions (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id  TEXT    NOT NULL,
                deleted_text TEXT   NOT NULL,
                deleted_at  INTEGER NOT NULL,
                signature   TEXT,
                public_key  TEXT
            )"),
            ("message_deletions index",
             "CREATE INDEX IF NOT EXISTS idx_deletions_msg_id ON message_deletions (message_id)"),
            ("", "ALTER TABLE messages ADD COLUMN reply_to_mid TEXT;"),
            ("", "ALTER TABLE channel_messages ADD COLUMN reply_to_mid TEXT;"),
            // Emoji reactions + removal history (Rat Files evidence).
            ("message_reactions table",
             "CREATE TABLE IF NOT EXISTS message_reactions (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id TEXT    NOT NULL,
                emoji      TEXT    NOT NULL,
                peer_id    TEXT    NOT NULL,
                added_at   INTEGER NOT NULL,
                signature  TEXT,
                public_key TEXT,
                UNIQUE(message_id, emoji, peer_id)
            )"),
            ("reactions index",
             "CREATE INDEX IF NOT EXISTS idx_reactions_msg_id ON message_reactions (message_id)"),
            ("reaction_removals table",
             "CREATE TABLE IF NOT EXISTS reaction_removals (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id TEXT    NOT NULL,
                emoji      TEXT    NOT NULL,
                peer_id    TEXT    NOT NULL,
                removed_at INTEGER NOT NULL,
                signature  TEXT,
                public_key TEXT
            )"),
            ("reaction_removals index",
             "CREATE INDEX IF NOT EXISTS idx_reaction_removals_msg_id ON reaction_removals (message_id)"),
            // Friends + app settings (key-value, general purpose).
            ("friends table",
             "CREATE TABLE IF NOT EXISTS friends (
                peer_id      TEXT PRIMARY KEY,
                status       TEXT NOT NULL,
                direction    TEXT NOT NULL DEFAULT '',
                requested_at INTEGER NOT NULL DEFAULT 0,
                updated_at   INTEGER NOT NULL DEFAULT 0
            )"),
            ("app_settings table",
             "CREATE TABLE IF NOT EXISTS app_settings (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )"),
            // Blocked peers (local block list, MASTER-keyed).
            ("blocked_peers table",
             "CREATE TABLE IF NOT EXISTS blocked_peers (
                peer_id    TEXT PRIMARY KEY,
                blocked_at INTEGER NOT NULL DEFAULT 0
            )"),
            // Custom emotes: a content-addressed blob cache shared across servers and DMs,
            // plus the user's own set (names are local, hashes global).
            ("emote_blobs table",
             "CREATE TABLE IF NOT EXISTS emote_blobs (
                hash     TEXT PRIMARY KEY,
                bytes    BLOB NOT NULL,
                animated INTEGER NOT NULL DEFAULT 0,
                added_at INTEGER NOT NULL DEFAULT 0
            )"),
            ("personal_emotes table",
             "CREATE TABLE IF NOT EXISTS personal_emotes (
                name     TEXT PRIMARY KEY,
                hash     TEXT NOT NULL,
                animated INTEGER NOT NULL DEFAULT 0,
                source   TEXT NOT NULL DEFAULT '',
                added_at INTEGER NOT NULL DEFAULT 0
            )"),
            // The sticker vault, keyed by (pack, hash) rather than by name the way emotes
            // are: an emote is TYPED as `:name:` so its name must be unique, while a sticker
            // is only ever picked visually, so adding the same image twice is a no-op instead
            // of an error. Bytes live in emote_blobs under kind='sticker'.
            ("personal_stickers table",
             "CREATE TABLE IF NOT EXISTS personal_stickers (
                pack     TEXT NOT NULL DEFAULT '',
                hash     TEXT NOT NULL,
                name     TEXT NOT NULL DEFAULT '',
                animated INTEGER NOT NULL DEFAULT 0,
                w        INTEGER NOT NULL DEFAULT 0,
                h        INTEGER NOT NULL DEFAULT 0,
                source   TEXT NOT NULL DEFAULT '',
                added_at INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (pack, hash)
            )"),
            // MLS identity (singleton row, id=1).
            ("mls_identity table",
             "CREATE TABLE IF NOT EXISTS mls_identity (
                id              INTEGER PRIMARY KEY CHECK (id = 1),
                signer_data     BLOB NOT NULL,
                credential_data BLOB NOT NULL,
                storage_data    BLOB
            )"),
            // The MLS store by row (0.13): `scope` '' is the live store, `past:{epoch}:{group}`
            // a kept past epoch. Replaces `mls_identity.storage_data`, the whole store in one
            // blob, which the first save after an upgrade empties.
            ("mls_storage table",
             "CREATE TABLE IF NOT EXISTS mls_storage (
                scope TEXT NOT NULL,
                k     BLOB NOT NULL,
                v     BLOB NOT NULL,
                PRIMARY KEY (scope, k)
            ) WITHOUT ROWID"),
            // File sharing (Phase 3.5).
            ("files table",
             "CREATE TABLE IF NOT EXISTS files (
                file_id         TEXT PRIMARY KEY,
                file_name       TEXT NOT NULL,
                file_ext        TEXT NOT NULL,
                mime_type       TEXT NOT NULL,
                size_bytes      INTEGER NOT NULL,
                chunk_count     INTEGER NOT NULL,
                chunks_received INTEGER NOT NULL DEFAULT 0,
                is_image        INTEGER NOT NULL DEFAULT 0,
                width           INTEGER,
                height          INTEGER,
                message_id      TEXT,
                context_type    TEXT NOT NULL,
                context_id      TEXT NOT NULL,
                sender_id       TEXT NOT NULL,
                is_mine         INTEGER NOT NULL DEFAULT 0,
                created_at      INTEGER NOT NULL,
                completed_at    INTEGER,
                disk_path       TEXT,
                hidden_at       INTEGER
            )"),
            ("files message_id index",
             "CREATE INDEX IF NOT EXISTS idx_files_message ON files (message_id)"),
            ("files context index",
             "CREATE INDEX IF NOT EXISTS idx_files_context ON files (context_type, context_id)"),
        ];
        for (what, sql) in PHASE35_SCHEMA {
            if what.is_empty() {
                migrate(conn, sql);
            } else {
                ddl(conn, what, sql)?;
            }
        }

        // video_thumb_json: a JSON VideoThumbRef when this file is a video's thumbnail.
        migrate(conn, "ALTER TABLE files ADD COLUMN video_thumb_json TEXT;");

        // When the retention timer expired the file: NULL = live, non-null = data deleted
        // from disk with the row kept as a placeholder.
        migrate(conn, "ALTER TABLE files ADD COLUMN expired_at INTEGER;");

        // Persisted ShareRef for share-backed (>34 MB) files. The share root hash and key
        // used to live only in the live FileHeader, so a manual download after a restart
        // had no way back into the swarm: the fallback FileRequest re-serves the bytes
        // with share_ref None and the requester's own 34 MB cap rejects them.
        migrate(conn, "ALTER TABLE files ADD COLUMN share_ref_json TEXT;");

        // Tiny base64 WebP placeholder, rendered blurred under the Download button while
        // the real bytes are gated or undownloaded.
        migrate(conn, "ALTER TABLE files ADD COLUMN thumb_b64 TEXT;");

        // Plaintext SHA-256 of a file whose id commits to it (`node::file_commit`).
        migrate(conn, "ALTER TABLE files ADD COLUMN sha256 TEXT;");

        ddl(conn, "file_chunks table",
            "CREATE TABLE IF NOT EXISTS file_chunks (
                file_id     TEXT    NOT NULL,
                chunk_index INTEGER NOT NULL,
                received_at INTEGER NOT NULL,
                PRIMARY KEY (file_id, chunk_index)
            )")?;

        // -- Migration: file_id column on messages --
        migrate(conn, "ALTER TABLE messages ADD COLUMN file_id TEXT;");
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN file_id TEXT;");

        // link_preview_json: a JSON LinkPreviewRef, written after the row is inserted.
        migrate(conn, "ALTER TABLE messages ADD COLUMN link_preview_json TEXT;");
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN link_preview_json TEXT;");
        // lp_at: when the frame that set the card was sealed; orders cards for one text.
        migrate(conn, "ALTER TABLE messages ADD COLUMN lp_at INTEGER;");
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN lp_at INTEGER;");

        // order_us, the microsecond send timestamp. The display ORDER BY uses it BEFORE
        // sender_id, so a sender's same-millisecond burst stays grouped and in true send
        // order instead of being alternated by the sender_id tiebreaker. Set by the
        // SENDER, carried over the wire untouched, NULL for legacy rows.
        migrate(conn, "ALTER TABLE messages ADD COLUMN order_us INTEGER;");
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN order_us INTEGER;");

        // album_id groups a sender's back-to-back items for rendering only; it is
        // bound by the v3 message signature.
        migrate(conn, "ALTER TABLE messages ADD COLUMN album_id TEXT;");
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN album_id TEXT;");
        // The device proof of a post (DEVICE_PROOF_DESIGN section 13), served back with it.
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN dev_device TEXT;");
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN dev_sig TEXT;");
        // Device proofs of the changes riding a post (section 13), JSON, served back.
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN lp_dev TEXT;");
        migrate(conn, "ALTER TABLE message_deletions ADD COLUMN dev TEXT;");
        migrate(conn, "ALTER TABLE message_reactions ADD COLUMN dev TEXT;");
        migrate(conn, "ALTER TABLE files ADD COLUMN meta_dev TEXT;");

        // updated_at tracks the last edit or delete, so sync queries catch changes to old
        // messages they would otherwise miss.
        migrate(conn, "ALTER TABLE messages ADD COLUMN updated_at INTEGER;");
        migrate(conn, "ALTER TABLE channel_messages ADD COLUMN updated_at INTEGER;");
        ddl(conn, "idx_messages_peer_updated",
            "CREATE INDEX IF NOT EXISTS idx_messages_peer_updated ON messages (peer_id, updated_at)")?;
        ddl(conn, "idx_channel_msgs_updated",
            "CREATE INDEX IF NOT EXISTS idx_channel_msgs_updated ON channel_messages (server_id, channel_id, updated_at)")?;
        // A table still keyed by content seeks senders on that key; building a second
        // index over its history inside `open()` would be a long write in any process.
        if !has_content_key(conn) {
            ddl(conn, "channel_messages sender index", CHANNEL_SENDER_INDEX)?;
        }

        // Where this device cleared a channel's history (Settings > Storage): rows at or
        // before `floor_ts` are never stored again, and sync asks start there. The
        // senders it held are named in those asks so nobody serves them again. Local by
        // nature; a backup or link snapshot leaves them behind (`scrub_device_secrets`).
        ddl(conn, "channel_floors table",
            "CREATE TABLE IF NOT EXISTS channel_floors (
                server_id  TEXT    NOT NULL,
                channel_id TEXT    NOT NULL,
                floor_ts   INTEGER NOT NULL,
                PRIMARY KEY (server_id, channel_id)
            )")?;
        // 0.14 development builds named a cleared channel's senders in its asks.
        migrate(conn, "DROP TABLE IF EXISTS channel_floor_senders; DROP TABLE IF EXISTS channel_sync_hole_senders;");
        // Rows up to `exact_from` are refused outright; above it, up to the floor, only
        // the ids this device cleared there, so a slow clock's later post still lands.
        migrate(conn, "ALTER TABLE channel_floors ADD COLUMN exact_from INTEGER;");
        ddl(conn, "channel_cleared_ids table",
            "CREATE TABLE IF NOT EXISTS channel_cleared_ids (
                server_id  TEXT    NOT NULL,
                channel_id TEXT    NOT NULL,
                mid_hash   INTEGER NOT NULL,
                ts         INTEGER NOT NULL,
                PRIMARY KEY (server_id, channel_id, mid_hash)
            ) WITHOUT ROWID")?;
        ddl(conn, "idx_cleared_ids_ts",
            "CREATE INDEX IF NOT EXISTS idx_cleared_ids_ts ON channel_cleared_ids (server_id, channel_id, ts)")?;
        // What a channel's history lacks when it begins here later than the channel's
        // (`note_held_page`, a copy's floors): every sender from `all_from` to `below`,
        // asked for by itself until a holder serves it whole.
        ddl(conn, "channel_sync_holes table",
            "CREATE TABLE IF NOT EXISTS channel_sync_holes (
                server_id  TEXT    NOT NULL,
                channel_id TEXT    NOT NULL,
                below      INTEGER NOT NULL,
                all_from   INTEGER,
                PRIMARY KEY (server_id, channel_id)
            )")?;
        // What a clear took, as the asks of a cleared channel still count it held
        // (`count_cleared_batch`): each sender's newest stamp, the id hashes of the
        // newest rows one by one (a digest may end among them), the rest per UTC day as
        // the gap digest counts a day. `history_from` = the oldest row it cleared.
        migrate(conn, "ALTER TABLE channel_floors ADD COLUMN history_from INTEGER;");
        ddl(conn, "channel_cleared_senders table",
            "CREATE TABLE IF NOT EXISTS channel_cleared_senders (
                server_id  TEXT    NOT NULL,
                channel_id TEXT    NOT NULL,
                sender_id  TEXT    NOT NULL,
                last_ts    INTEGER NOT NULL,
                PRIMARY KEY (server_id, channel_id, sender_id)
            ) WITHOUT ROWID")?;
        ddl(conn, "channel_cleared_tail table",
            "CREATE TABLE IF NOT EXISTS channel_cleared_tail (
                server_id  TEXT    NOT NULL,
                channel_id TEXT    NOT NULL,
                ts         INTEGER NOT NULL,
                h          INTEGER NOT NULL,
                PRIMARY KEY (server_id, channel_id, ts, h)
            ) WITHOUT ROWID")?;
        ddl(conn, "channel_cleared_days table",
            "CREATE TABLE IF NOT EXISTS channel_cleared_days (
                server_id  TEXT    NOT NULL,
                channel_id TEXT    NOT NULL,
                day        INTEGER NOT NULL,
                n          INTEGER NOT NULL,
                h          INTEGER NOT NULL,
                PRIMARY KEY (server_id, channel_id, day)
            ) WITHOUT ROWID")?;
        // The newest date of what each device proved in the rows a clear took, for a
        // retire's post window; `reactor` = `sender_id` is the reaction's peer id, which
        // may be the device itself.
        ddl(conn, "channel_cleared_devices table",
            "CREATE TABLE IF NOT EXISTS channel_cleared_devices (
                server_id TEXT    NOT NULL,
                sender_id TEXT    NOT NULL,
                device    TEXT    NOT NULL,
                reactor   INTEGER NOT NULL,
                last_ts   INTEGER NOT NULL,
                PRIMARY KEY (server_id, sender_id, device, reactor)
            ) WITHOUT ROWID")?;
        // A clear's downloads still to unlink: its batches commit before the unlink, so a
        // crash between them leaves the names here for the next start.
        ddl(conn, "channel_cleared_files table",
            "CREATE TABLE IF NOT EXISTS channel_cleared_files (
                file_id  TEXT NOT NULL,
                file_ext TEXT NOT NULL,
                PRIMARY KEY (file_id, file_ext)
            ) WITHOUT ROWID")?;

        // -- Migration: avatar/banner BLOB columns on user_profiles --
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN avatar BLOB;");
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN banner BLOB;");
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN twitch_username TEXT NOT NULL DEFAULT '';");
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN showcase_board TEXT NOT NULL DEFAULT '';");
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN showcase_assets BLOB;");
        // -- 0.8.5: the subject's own signature over the relayable profile
        // subset, so `ProfileRelay` can be authenticated rather than trusted.
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN profile_sig TEXT;");
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN profile_pk TEXT;");
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN profile_avatar_hash TEXT;");
        // -- 0.12: the signature covers every field, blobs by these hashes too.
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN profile_banner_hash TEXT;");
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN profile_assets_hash TEXT;");
        // -- issue #54: avatar frame ID. "" = none, "b:<hue>" = built-in,
        // 64-hex = an asset-rail blob hash. Never the bytes.
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN avatar_frame TEXT NOT NULL DEFAULT '';");
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN avatar_anim TEXT NOT NULL DEFAULT '';");
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN banner_anim TEXT NOT NULL DEFAULT '';");
        // -- Artist shop, phase 2: support credentials (JSON array, "" = none).
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN support_creds TEXT NOT NULL DEFAULT '';");
        // The retired per-master pin for `support_creds_sig`. Nothing reads or writes it:
        // `support_creds` requires a valid signature from every master, so there is no
        // baseline left to learn. The column stays so existing databases open unchanged.
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN support_creds_signed INTEGER NOT NULL DEFAULT 0;");
        // -- Stream overlay (#97): the signed `stream_overlay` field as received ("" =
        // absent) and its own stamp, outside the profile signature.
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN stream_overlay TEXT NOT NULL DEFAULT '';");
        migrate(conn, "ALTER TABLE user_profiles ADD COLUMN stream_overlay_at INTEGER NOT NULL DEFAULT 0;");
        // The people this device shows on its stream overlay. LOCAL to this device and
        // profile: no sync reads it. `slot` is the stable number OBS links use.
        ddl(conn, "overlay_people table",
            "CREATE TABLE IF NOT EXISTS overlay_people (
                master      TEXT PRIMARY KEY,
                slot        INTEGER NOT NULL,
                added_at    INTEGER NOT NULL,
                local_look  TEXT,
                their_look  TEXT,
                held_stamp  INTEGER NOT NULL DEFAULT 0
            )")?;
        // The avatar thumbnail a pending request's sealed card carried. Never in
        // `user_profiles.avatar`, whose bytes must hash to the signed avatar hash.
        migrate(conn, "ALTER TABLE friends ADD COLUMN card_thumb BLOB;");

        // -- Migration: content_id column on files (vault ↔ file_id link) --
        migrate(conn, "ALTER TABLE files ADD COLUMN content_id TEXT;");

        // Asset rail: emote_blobs generalizes to every content-addressed kind. The kind
        // is LOCAL bookkeeping for caps and eviction and never rides the wire.
        migrate(conn, "ALTER TABLE emote_blobs ADD COLUMN kind TEXT NOT NULL DEFAULT 'emote';");

        // Stream overlay images (#97) live apart from the asset rail, so an overlay
        // write never claims a hash the rail serves and the rail never sees one.
        ddl(conn, "overlay_blobs table",
            "CREATE TABLE IF NOT EXISTS overlay_blobs (
                hash     TEXT PRIMARY KEY,
                bytes    BLOB NOT NULL,
                animated INTEGER NOT NULL DEFAULT 0,
                added_at INTEGER NOT NULL DEFAULT 0
            )")?;

        // What the pure-Rust image check said about a peer's exact bytes (AR-28), so a
        // render path decodes each image once. `rule` names the check version.
        ddl(conn, "image_verdicts table",
            "CREATE TABLE IF NOT EXISTS image_verdicts (
                hash       TEXT PRIMARY KEY,
                ok         INTEGER NOT NULL,
                rule       INTEGER NOT NULL,
                checked_at INTEGER NOT NULL DEFAULT 0
            )")?;
        ddl(conn, "idx_image_verdicts_at",
            "CREATE INDEX IF NOT EXISTS idx_image_verdicts_at ON image_verdicts (checked_at)")?;

        // One row per DM call this device took part in, written by each side when the
        // call ends. LOCAL ONLY: its own table, so no sync, backfill, digest, unread
        // count, search, preview or archive export (all `messages` readers) sees it,
        // and there is nothing to sign.
        ddl(conn, "call_records table",
            "CREATE TABLE IF NOT EXISTS call_records (
                call_id      TEXT PRIMARY KEY,
                peer_id      TEXT NOT NULL,
                outgoing     INTEGER NOT NULL,
                video        INTEGER NOT NULL DEFAULT 0,
                outcome      TEXT NOT NULL,
                started_at   INTEGER NOT NULL,
                connected_at INTEGER,
                ended_at     INTEGER NOT NULL
            )")?;
        ddl(conn, "idx_call_records_peer",
            "CREATE INDEX IF NOT EXISTS idx_call_records_peer
             ON call_records (peer_id, started_at)")?;

        // -- Verified peers (RAT Files — peer identity verification) --
        ddl(conn, "verified_peers table",
            "CREATE TABLE IF NOT EXISTS verified_peers (
                peer_id     TEXT PRIMARY KEY,
                verified_at INTEGER NOT NULL
            )")?;

        // One row per NOTEWORTHY identity event for a contact. `alert_id` is deterministic
        // ("{kind}:{peer}:{detail}") so re-ingesting the same device list on every
        // reconnect can never pile up duplicates of a fact the user has seen. `peer_id` is
        // always the MASTER id: alerts are about a PERSON.
        ddl(conn, "security_alerts table",
            "CREATE TABLE IF NOT EXISTS security_alerts (
                alert_id        TEXT PRIMARY KEY,
                peer_id         TEXT NOT NULL,
                kind            TEXT NOT NULL,
                detail          TEXT NOT NULL DEFAULT '',
                created_at      INTEGER NOT NULL,
                acknowledged_at INTEGER
            )")?;
        ddl(conn, "idx_security_alerts_peer",
            "CREATE INDEX IF NOT EXISTS idx_security_alerts_peer
                ON security_alerts (peer_id, acknowledged_at)")?;
        // When the device a warning names left the roster (B3 (d)); the warning stays
        // until the person dismisses it.
        migrate(conn, "ALTER TABLE security_alerts ADD COLUMN resolved_at INTEGER");

        // The Curve25519 identity key first seen for a DEVICE. Keyed by device, not
        // master, because the Olm ratchet is per-device: each device legitimately has its
        // own key, and only a CHANGE within one device id means a reinstall or re-key.
        ddl(conn, "olm_key_pins table",
            "CREATE TABLE IF NOT EXISTS olm_key_pins (
                device_peer_id TEXT PRIMARY KEY,
                identity_key   TEXT NOT NULL,
                pinned_at      INTEGER NOT NULL
            )")?;

        // One row per share created, opened or downloaded. If the user loses the link and
        // the row is gone the file is unrecoverable, which is the point.
        ddl(conn, "shares table",
            "CREATE TABLE IF NOT EXISTS shares (
                root_hash       TEXT PRIMARY KEY,
                file_name       TEXT NOT NULL,
                file_ext        TEXT NOT NULL,
                mime            TEXT NOT NULL,
                total_size      INTEGER NOT NULL,
                chunk_size      INTEGER NOT NULL,
                chunk_count     INTEGER NOT NULL,
                manifest_json   TEXT NOT NULL,
                encryption_key  BLOB NOT NULL,
                share_link      TEXT NOT NULL,
                state           TEXT NOT NULL,
                seeding         INTEGER NOT NULL DEFAULT 1,
                disk_path       TEXT,
                save_dir        TEXT,
                bytes_uploaded  INTEGER NOT NULL DEFAULT 0,
                created_at      INTEGER NOT NULL,
                completed_at    INTEGER
            )")?;
        migrate(conn, "ALTER TABLE shares ADD COLUMN save_dir TEXT;");
        migrate(conn, "ALTER TABLE shares ADD COLUMN server_id TEXT;");
        migrate(conn, "ALTER TABLE shares ADD COLUMN context_type TEXT;");
        ddl(conn, "idx_shares_state",
            "CREATE INDEX IF NOT EXISTS idx_shares_state ON shares(state)")?;
        ddl(conn, "idx_shares_seeding",
            "CREATE INDEX IF NOT EXISTS idx_shares_seeding ON shares(seeding)")?;

        // -- Server blobs (CrdtStore: large settings like server_avatar) --
        ddl(conn, "server_blobs table",
            "CREATE TABLE IF NOT EXISTS server_blobs (
                server_id TEXT NOT NULL,
                key       TEXT NOT NULL,
                value     TEXT NOT NULL,
                PRIMARY KEY (server_id, key)
            )")?;

        // Have-bitmap per share, persisted so paused/restarted downloads resume
        // without re-fetching. bitmap_blob is little-endian-packed bits.
        ddl(conn, "share_chunks table",
            "CREATE TABLE IF NOT EXISTS share_chunks (
                root_hash    TEXT PRIMARY KEY,
                bitmap_blob  BLOB NOT NULL,
                updated_at   INTEGER NOT NULL
            )")?;

        // Durable "my meeting room" objects. access_code_hash is the conf-scoped code key,
        // never the plaintext code; co_hosts is a JSON array of master ids.
        ddl(conn, "conferences table",
            "CREATE TABLE IF NOT EXISTS conferences (
                conf_id          TEXT PRIMARY KEY,
                name             TEXT NOT NULL,
                waiting_room     INTEGER NOT NULL DEFAULT 1,
                access_code_hash TEXT,
                co_hosts         TEXT NOT NULL DEFAULT '[]',
                broadcast_mode   INTEGER NOT NULL DEFAULT 0,
                created_at       INTEGER NOT NULL
            )")?;

        // The founding nonce a meeting id hashes from with its host's master.
        migrate(conn, "ALTER TABLE conferences ADD COLUMN host_nonce TEXT;");
        // The key a meeting link carries next to the id (`conference::new_link_key`).
        migrate(conn, "ALTER TABLE conferences ADD COLUMN link_key TEXT;");

        // Content-sync FTS: the FTS table reads the main table on demand and triggers
        // keep it in sync.
        conn.execute_batch(&format!(
            "CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                text, content='messages', content_rowid='id'
            );
            CREATE TRIGGER IF NOT EXISTS messages_fts_ai AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS messages_fts_ad AFTER DELETE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, text) VALUES('delete', old.id, old.text);
            END;
            CREATE TRIGGER IF NOT EXISTS messages_fts_au AFTER UPDATE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, text) VALUES('delete', old.id, old.text);
                INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
            END;

            CREATE VIRTUAL TABLE IF NOT EXISTS channel_messages_fts USING fts5(
                text, content='channel_messages', content_rowid='id'
            );
            {CHANNEL_FTS_TRIGGERS}"
        )).unwrap_or_else(|e| {
            crate::hollow_log!("[HOLLOW] FTS5 setup failed (non-fatal): {e}");
        });

        // One-time FTS backfill for databases that existed before FTS was added.
        let fts_done: bool = conn
            .query_row(
                "SELECT 1 FROM app_settings WHERE key = 'fts_backfilled'",
                [],
                |_| Ok(true),
            )
            .unwrap_or(false);
        if !fts_done {
            conn.execute_batch(
                "INSERT OR IGNORE INTO messages_fts(messages_fts) VALUES('rebuild');
                 INSERT OR IGNORE INTO channel_messages_fts(channel_messages_fts) VALUES('rebuild');"
            ).unwrap_or_else(|e| {
                crate::hollow_log!("[HOLLOW] FTS5 rebuild failed (non-fatal): {e}");
            });
            let _ = conn.execute(
                "INSERT OR REPLACE INTO app_settings (key, value) VALUES ('fts_backfilled', '1')",
                [],
            );
        }

        // One row per master holding its full signed device list JSON plus a monotonic
        // version for replay protection. `device_links` is the reverse index the
        // device-to-master resolver reads.
        ddl(conn, "device_lists table",
            "CREATE TABLE IF NOT EXISTS device_lists (
                master_peer_id TEXT PRIMARY KEY,
                json           TEXT    NOT NULL,
                version        INTEGER NOT NULL DEFAULT 0,
                updated_at     INTEGER NOT NULL DEFAULT 0
            )")?;

        ddl(conn, "device_links table",
            "CREATE TABLE IF NOT EXISTS device_links (
                device_peer_id TEXT PRIMARY KEY,
                master_peer_id TEXT NOT NULL
            )")?;

        ddl(conn, "device_links index",
            "CREATE INDEX IF NOT EXISTS idx_device_links_master ON device_links (master_peer_id)")?;

        // Devices whose revocation we ENFORCED, one row per master whose roster removed
        // it. A revoked id resolves to itself once forgotten, so without this row it
        // looks like a stranger after a restart and passes key exchange. Per master so
        // one identity's recovery never lifts another's removal of the same key.
        ddl(conn, "revoked_marks table",
            "CREATE TABLE IF NOT EXISTS revoked_marks (
                device_peer_id TEXT NOT NULL,
                master_peer_id TEXT NOT NULL,
                PRIMARY KEY (device_peer_id, master_peer_id)
            )")?;
        if let Err(e) = move_old_revocations(conn) {
            crate::hollow_log!("[HOLLOW] revoked_devices not moved yet, still read: {e}");
        }

        // When THIS node first saw a device's pending join in a base: the clock its seven
        // days run on (design ID-1). Per base, so a recovery restarts it. Local by
        // nature; never synced. `roster_seen` was its per-device predecessor.
        migrate(conn, "DROP TABLE IF EXISTS roster_seen");
        ddl(conn, "roster_pending_seen table",
            "CREATE TABLE IF NOT EXISTS roster_pending_seen (
                master_peer_id TEXT NOT NULL,
                base           TEXT NOT NULL,
                device_peer_id TEXT NOT NULL,
                first_seen_ms  INTEGER NOT NULL,
                PRIMARY KEY (master_peer_id, base, device_peer_id)
            )")?;

        // When THIS node first saw each removal and vouch of our own identity's roster
        // (DEVICE_PROOF_DESIGN 8.5, 8.6): "lost or stolen" re-signs and keeps only what was
        // here before the moment the person last had the device. Kept 30 days after the
        // statement leaves the roster. Not `roster_seen`: that name is dropped above.
        let seen_is_new = !table_exists(conn, "roster_statement_seen");
        ddl(conn, "roster_statement_seen table",
            "CREATE TABLE IF NOT EXISTS roster_statement_seen (
                master_peer_id TEXT NOT NULL,
                digest         TEXT NOT NULL,
                first_seen_ms  INTEGER NOT NULL,
                dropped_ms     INTEGER,
                PRIMARY KEY (master_peer_id, digest)
            )")?;
        // An install from before this table: what its roster holds now predates any
        // answer to "when did you last have it" (`seed_roster_statements_once`).
        // A fresh database's first save holds nothing yet, so the mark dates nothing there.
        if seen_is_new {
            migrate(conn, "INSERT OR IGNORE INTO roster_statement_seen (master_peer_id, digest, first_seen_ms) VALUES ('*', '*', 0)");
        }

        // When each device of a contact identity last showed us a roster we hold all of,
        // and when we last asked it for one because it had not (AR-29). Local; never synced.
        ddl(conn, "roster_confirms table",
            "CREATE TABLE IF NOT EXISTS roster_confirms (
                master_peer_id TEXT NOT NULL,
                device_peer_id TEXT NOT NULL,
                confirmed_ms   INTEGER NOT NULL,
                asked_ms       INTEGER,
                voided_by_ms   INTEGER,
                PRIMARY KEY (master_peer_id, device_peer_id)
            )")?;
        // The send time of the newest DM from the device whose digest differed: an older
        // DM that matches never stamps the slot again.
        migrate(conn, "ALTER TABLE roster_confirms ADD COLUMN voided_by_ms INTEGER");
        // Roster asks the push fetch could not send (it never talks back): the node sends
        // them on its next relay session.
        ddl(conn, "roster_asks_due table",
            "CREATE TABLE IF NOT EXISTS roster_asks_due (
                subject_master TEXT NOT NULL,
                device_peer_id TEXT NOT NULL,
                due_ms         INTEGER NOT NULL,
                PRIMARY KEY (subject_master, device_peer_id)
            )")?;
        // When this device first carried each counting removal of its own identity in
        // its DMs (F2, 0.13): carried only until contacts show they hold it. Local.
        ddl(conn, "roster_removal_carried table",
            "CREATE TABLE IF NOT EXISTS roster_removal_carried (
                master_peer_id TEXT NOT NULL,
                base           TEXT NOT NULL,
                device_peer_id TEXT NOT NULL,
                first_ms       INTEGER NOT NULL,
                PRIMARY KEY (master_peer_id, base, device_peer_id)
            )")?;
        // The newest DM of each contact DEVICE that showed our own roster exactly as we
        // held it then, by our clock (F2): a removal stops riding to a contact only once
        // every device of it showed it holds it. Local.
        ddl(conn, "roster_carry_device_confirms table",
            "CREATE TABLE IF NOT EXISTS roster_carry_device_confirms (
                contact_master TEXT NOT NULL,
                device_peer_id TEXT NOT NULL,
                digest         TEXT NOT NULL,
                at_ms          INTEGER NOT NULL,
                PRIMARY KEY (contact_master, device_peer_id)
            )")?;
        // Contact rosters another process (the push fetch, the iOS NSE) changed in the
        // store: the running node re-reads them before its next DM to that identity.
        ddl(conn, "roster_dirty table",
            "CREATE TABLE IF NOT EXISTS roster_dirty (
                master_peer_id TEXT PRIMARY KEY,
                at_ms          INTEGER NOT NULL
            )")?;
        // Devices a recovery in such a roster dropped: the node moves the join locks
        // they could still extend once it reads the mark.
        ddl(conn, "roster_dropped table",
            "CREATE TABLE IF NOT EXISTS roster_dropped (
                master_peer_id TEXT NOT NULL,
                device_peer_id TEXT NOT NULL,
                PRIMARY KEY (master_peer_id, device_peer_id)
            )")?;
        // Co-members' rosters a member delivered in a sync answer or a checkpoint
        // (DEVICE_PROOF_DESIGN section 9, H3): never the book, never the resolver, read
        // only by server authority; one row per (master, recovery key).
        ddl(conn, "server_rosters table",
            "CREATE TABLE IF NOT EXISTS server_rosters (
                master_peer_id TEXT NOT NULL,
                r_pub          TEXT NOT NULL,
                json           TEXT NOT NULL,
                bytes          INTEGER NOT NULL,
                last_needed_ms INTEGER NOT NULL,
                PRIMARY KEY (master_peer_id, r_pub)
            )")?;

        // Local-only, unsigned human labels for devices (Step 8 Devices panel). NOT
        // synced or master-signed — each device names its own view of the device set.
        ddl(conn, "device_labels table",
            "CREATE TABLE IF NOT EXISTS device_labels (
                device_peer_id TEXT PRIMARY KEY,
                label          TEXT NOT NULL DEFAULT ''
            )")?;

        // What each of our siblings says it is: "desktop" or "phone", never more.
        ddl(conn, "device_kinds table",
            "CREATE TABLE IF NOT EXISTS device_kinds (
                device_peer_id TEXT PRIMARY KEY,
                kind           TEXT NOT NULL
            )")?;

        // A join whose members were ALL offline is not a failure: the request is persisted
        // here and deposited into the server room's `~join` ring, so it outlives the app
        // closing. `state` is 'pending' or 'rejected' (the row survives so the tile can say
        // why), and `requested_at` is the nonce every answer must name.
        ddl(conn, "pending_server_joins table",
            "CREATE TABLE IF NOT EXISTS pending_server_joins (
                server_id         TEXT PRIMARY KEY,
                requested_at      INTEGER NOT NULL,
                nsfw_confirmed    INTEGER NOT NULL DEFAULT 0,
                twitch_proof_json TEXT,
                state             TEXT NOT NULL DEFAULT 'pending',
                reason            TEXT NOT NULL DEFAULT '',
                last_deposited_at INTEGER NOT NULL DEFAULT 0,
                created_at        INTEGER NOT NULL
            )")?;
        // The carried KeyPackage, nullable: an older row falls back to bootstrapping on
        // co-presence.
        migrate(conn, "ALTER TABLE pending_server_joins ADD COLUMN key_package TEXT;");
        // The owner an invite pinned (a link to a pre-0.12 server carries `owner=`).
        migrate(conn, "ALTER TABLE pending_server_joins ADD COLUMN owner_pin TEXT;");
        // The invite's join key and our reply key for the row (join lane, claim C-24).
        migrate(conn, "ALTER TABLE pending_server_joins ADD COLUMN join_key TEXT;");
        migrate(conn, "ALTER TABLE pending_server_joins ADD COLUMN reply_secret TEXT;");

        // Art imported from a `.hollowpack`, keyed by the art's HASH because that is its
        // identity everywhere else. The bytes live in `emote_blobs` under the ordinary
        // rail kinds; this table is the provenance beside them, so "who made this and
        // under what licence" survives a rail eviction. Re-importing is an UPSERT: a buyer
        // who downloads their order twice owns the art once.
        ddl(conn, "owned_art table",
            "CREATE TABLE IF NOT EXISTS owned_art (
                hash        TEXT PRIMARY KEY,
                role        TEXT NOT NULL DEFAULT '',
                item_id     TEXT NOT NULL DEFAULT '',
                title       TEXT NOT NULL DEFAULT '',
                artist_name TEXT NOT NULL DEFAULT '',
                artist_slug TEXT NOT NULL DEFAULT '',
                artist_url  TEXT NOT NULL DEFAULT '',
                license     TEXT NOT NULL DEFAULT '',
                imported_at INTEGER NOT NULL DEFAULT 0
            )")?;
        ddl(conn, "owned_art item index",
            "CREATE INDEX IF NOT EXISTS idx_owned_art_item ON owned_art (item_id)")?;

        // Kept redeem codes. The shop's thank-you page hands the buyer a
        // `hollow://redeem/<code>` link and the app KEEPS it, so closing the page cannot
        // lose what they paid for.
        //
        // A deep link is REMOTE-AUTHORED input: the gate is the shape check plus a hard cap
        // of 64 rows, so the worst a hostile link can do is add one short string to a table
        // nothing else reads. No network call, no crypto, no profile change.
        ddl(conn, "redeem_codes table",
            "CREATE TABLE IF NOT EXISTS redeem_codes (
                code        TEXT PRIMARY KEY,
                received_at INTEGER NOT NULL DEFAULT 0
            )")?;

        // OUR support credentials: one row per redeemed item, holding the verified entry
        // JSON exactly as it rides the profile plus what the shop said the item was. Keyed
        // by item hash, so redeeming a second code for the same item replaces the row. The
        // profile field is rebuilt from this table, so a profile rewrite cannot lose one.
        ddl(conn, "support_creds_own table",
            "CREATE TABLE IF NOT EXISTS support_creds_own (
                item         TEXT PRIMARY KEY,
                entry_json   TEXT NOT NULL DEFAULT '',
                slug         TEXT NOT NULL DEFAULT '',
                title        TEXT NOT NULL DEFAULT '',
                artist_name  TEXT NOT NULL DEFAULT '',
                redeemed_at  INTEGER NOT NULL DEFAULT 0
            )")?;

        // Per-file at-rest keys (issue 78). Keyed by the random uid in the file
        // header, never by path, so a rename costs nothing. Deleting a row is the
        // cryptographic erase of that file.
        ddl(conn, "file_keys table",
            "CREATE TABLE IF NOT EXISTS file_keys (
                uid        BLOB PRIMARY KEY,
                key        BLOB NOT NULL,
                nonce      BLOB NOT NULL,
                version    INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL
            )")?;

        // Each identity's newest master-signed card (name and avatar hash) with its
        // proof, so we can show a stranger who wrote a public post (D6).
        ddl(conn, "signed_cards table",
            "CREATE TABLE IF NOT EXISTS signed_cards (
                master       TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                updated_at   INTEGER NOT NULL,
                avatar_hash  TEXT NOT NULL,
                sig          TEXT NOT NULL,
                pk           TEXT NOT NULL
            )")?;

        Ok(())
    }

    /// Keep a card the caller verified, unless we hold one at least as new. Of two
    /// cards at one stamp (two devices of one identity) the higher signature stays.
    pub fn save_signed_card(&self, card: &StoredCard) -> Result<bool, String> {
        self.conn
            .execute(
                "INSERT INTO signed_cards (master, display_name, updated_at, avatar_hash, sig, pk)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(master) DO UPDATE SET
                    display_name = excluded.display_name, updated_at = excluded.updated_at,
                    avatar_hash = excluded.avatar_hash, sig = excluded.sig, pk = excluded.pk
                 WHERE excluded.updated_at > signed_cards.updated_at
                    OR (excluded.updated_at = signed_cards.updated_at AND excluded.sig > signed_cards.sig)
                    OR signed_cards.updated_at > ?7",
                params![card.master, card.display_name, card.updated_at, card.avatar_hash, card.sig, card.pk, stored_profile_stamp_limit()],
            )
            .map(|n| n > 0)
            .map_err(|e| format!("Failed to save signed card: {e}"))
    }

    pub fn load_signed_card(&self, master: &str) -> Option<StoredCard> {
        self.conn
            .query_row(
                "SELECT master, display_name, updated_at, avatar_hash, sig, pk FROM signed_cards WHERE master = ?1",
                params![master],
                |r| Ok(StoredCard {
                    master: r.get(0)?,
                    display_name: r.get(1)?,
                    updated_at: r.get(2)?,
                    avatar_hash: r.get(3)?,
                    sig: r.get(4)?,
                    pk: r.get(5)?,
                }),
            )
            .ok()
    }

    /// Every at-rest file key, loaded once into the process key ring so reads
    /// never touch the database.
    pub fn load_file_keys(&self) -> Result<Vec<([u8; 16], [u8; 32], [u8; 8])>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT uid, key, nonce FROM file_keys")
            .map_err(|e| format!("Failed to prepare file_keys query: {e}"))?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, Vec<u8>>(0)?,
                    r.get::<_, Vec<u8>>(1)?,
                    r.get::<_, Vec<u8>>(2)?,
                ))
            })
            .map_err(|e| format!("Failed to query file_keys: {e}"))?;
        let mut out = Vec::new();
        for row in rows {
            let (uid, key, nonce) = row.map_err(|e| format!("Failed to read file_keys row: {e}"))?;
            let (Ok(uid), Ok(key), Ok(nonce)) = (
                <[u8; 16]>::try_from(uid.as_slice()),
                <[u8; 32]>::try_from(key.as_slice()),
                <[u8; 8]>::try_from(nonce.as_slice()),
            ) else {
                continue;
            };
            out.push((uid, key, nonce));
        }
        Ok(out)
    }

    pub fn insert_file_key(&self, uid: &[u8; 16], key: &[u8; 32], nonce: &[u8; 8]) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "INSERT OR REPLACE INTO file_keys (uid, key, nonce, version, created_at)
                 VALUES (?1, ?2, ?3, 1, ?4)",
                rusqlite::params![uid.as_slice(), key.as_slice(), nonce.as_slice(), now],
            )
            .map(|_| ())
            .map_err(|e| format!("Failed to store file key: {e}"))
    }

    pub fn delete_file_key(&self, uid: &[u8; 16]) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM file_keys WHERE uid = ?1", rusqlite::params![uid.as_slice()])
            .map(|_| ())
            .map_err(|e| format!("Failed to delete file key: {e}"))
    }

    /// One-time storage hygiene, run ONCE at node startup while a SINGLE connection
    /// holds the DB. Converts a legacy `auto_vacuum=0` database to INCREMENTAL (which
    /// needs a full `VACUUM`) and does one incremental reclaim.
    ///
    /// The single-connection window is required: the `VACUUM` takes an exclusive lock
    /// and the page-1 read races any other connection's SQLCipher codec, producing
    /// spurious `hmac check failed for pgno=1` noise. Idempotent, and a missing or
    /// locked DB is a non-fatal skip, since this is disk hygiene, not data integrity.
    pub fn migrate_auto_vacuum_once(path: &str, passphrase: &str) -> Result<(), String> {
        #[cfg(test)]
        let _counted = open_connections::Counted::new(path);
        let conn = Connection::open(path)
            .map_err(|e| format!("Failed to open database for migration: {e}"))?;
        conn.execute_batch(&format!("PRAGMA key = \"x'{}'\";", passphrase))
            .map_err(|e| format!("Failed to set encryption key: {e}"))?;
        let _ = conn.execute_batch("PRAGMA busy_timeout = 4000;");

        let rebuilt = match Self::rebuild_channel_messages(&conn) {
            Ok(rebuilt) => rebuilt,
            Err(e) => {
                crate::hollow_log!("[HOLLOW] channel_messages kept its content key for now: {e}");
                false
            }
        };

        let auto_vac: i32 = conn
            .query_row("PRAGMA auto_vacuum;", [], |r| r.get(0))
            .unwrap_or(0);
        if auto_vac == 0 {
            conn.execute_batch("PRAGMA auto_vacuum = INCREMENTAL; VACUUM;")
                .map_err(|e| format!("auto_vacuum migration failed: {e}"))?;
        }
        release_free_pages(&conn, if rebuilt { None } else { Some(100) });
        Ok(())
    }

    /// Rebuild a `channel_messages` table still keyed by content (before 0.14): the same
    /// rows, ids and columns, its indexes and search triggers, no content key, one row per
    /// message id (the oldest), and the sender index. One transaction: a failure or a
    /// crash leaves the old table whole and the next start tries again. Runs only in the
    /// startup window, never in `open()`: it rewrites the whole history.
    pub(crate) fn rebuild_channel_messages(conn: &Connection) -> Result<bool, String> {
        if !has_content_key(conn) {
            return Ok(false);
        }
        let columns: Vec<(String, String)> = {
            let mut stmt = conn
                .prepare("SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info('channel_messages') ORDER BY cid")
                .map_err(|e| format!("columns: {e}"))?;
            let rows = stmt
                .query_map([], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, bool>(2)?, r.get::<_, Option<String>>(3)?, r.get::<_, i64>(4)? != 0))
                })
                .map_err(|e| format!("columns: {e}"))?;
            let mut out = Vec::new();
            for row in rows {
                let (name, ty, notnull, default, pk) = row.map_err(|e| format!("columns: {e}"))?;
                let def = plain_column(&name, &ty, notnull, default.as_deref(), pk)
                    .ok_or_else(|| format!("column {name:?} is not one this build writes"))?;
                out.push((name, def));
            }
            out
        };
        let has = |col: &str| columns.iter().any(|(name, _)| name == col);
        if !has("message_id") {
            // The first open of this process adds it; the next start rebuilds.
            return Ok(false);
        }
        let names = columns.iter().map(|(name, _)| name.as_str()).collect::<Vec<_>>().join(", ");
        let defs = columns.iter().map(|(_, def)| def.as_str()).collect::<Vec<_>>().join(", ");
        in_write_tx(conn, |conn| {
            let run = |what: &str, sql: &str| conn.execute_batch(sql).map_err(|e| format!("{what}: {e}"));
            run("drop a leftover", "DROP TABLE IF EXISTS channel_messages_rebuild")?;
            run("create", &format!("CREATE TABLE channel_messages_rebuild ({defs})"))?;
            let kept = conn
                .execute(
                    &format!(
                        "INSERT INTO channel_messages_rebuild ({names})
                         SELECT {names} FROM channel_messages
                         WHERE message_id IS NULL
                            OR id IN (SELECT MIN(id) FROM channel_messages WHERE message_id IS NOT NULL GROUP BY message_id)
                         ORDER BY id"
                    ),
                    [],
                )
                .map_err(|e| format!("copy: {e}"))?;
            let seq: Option<i64> = conn
                .query_row("SELECT seq FROM sqlite_sequence WHERE name = 'channel_messages'", [], |r| r.get(0))
                .ok();
            let held: i64 = conn
                .query_row("SELECT COUNT(*) FROM channel_messages", [], |r| r.get(0))
                .map_err(|e| format!("count: {e}"))?;
            run("drop", "DROP TABLE channel_messages")?;
            run("rename", "ALTER TABLE channel_messages_rebuild RENAME TO channel_messages")?;
            // A dropped copy's id is never handed out again.
            if let Some(seq) = seq {
                conn.execute("UPDATE sqlite_sequence SET seq = MAX(seq, ?1) WHERE name = 'channel_messages'", [seq])
                    .map_err(|e| format!("sequence: {e}"))?;
            }
            run("time index", "CREATE INDEX idx_channel_msgs ON channel_messages (server_id, channel_id, timestamp)")?;
            run("id index", CHANNEL_MID_INDEX)?;
            run("sender index", CHANNEL_SENDER_INDEX)?;
            if has("updated_at") {
                run("updated index", "CREATE INDEX idx_channel_msgs_updated ON channel_messages (server_id, channel_id, updated_at)")?;
            }
            if table_exists(conn, "channel_messages_fts") {
                run("search triggers", CHANNEL_FTS_TRIGGERS)?;
                if kept as i64 != held {
                    run("search rebuild", "INSERT INTO channel_messages_fts(channel_messages_fts) VALUES('rebuild')")?;
                }
            }
            Ok(())
        })?;
        Ok(true)
    }

    pub fn wal_checkpoint(&self) -> Result<(), String> {
        self.conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")
            .map_err(|e| format!("WAL checkpoint failed: {e}"))
    }

    /// True while a transaction this connection began is still open, or a statement
    /// still holds a read open (a snapshot later reads would keep seeing).
    pub(crate) fn in_transaction(&self) -> bool {
        if !self.conn.is_autocommit() {
            return true;
        }
        // SAFETY: walks this connection's own statements without touching them.
        unsafe {
            let db = self.conn.handle();
            let mut stmt = rusqlite::ffi::sqlite3_next_stmt(db, std::ptr::null_mut());
            while !stmt.is_null() {
                if rusqlite::ffi::sqlite3_stmt_busy(stmt) != 0 {
                    return true;
                }
                stmt = rusqlite::ffi::sqlite3_next_stmt(db, stmt);
            }
        }
        false
    }

    /// Test-only: a statement stepped once and never reset, as a leaked row cursor leaves it.
    #[cfg(test)]
    pub(crate) fn hold_a_read_open_for_test(&self) {
        let mut stmt = self.conn.prepare("SELECT 1 UNION ALL SELECT 2").unwrap();
        let mut rows = stmt.query([]).unwrap();
        let _ = rows.next().unwrap();
        std::mem::forget(rows);
        std::mem::forget(stmt);
    }

    /// Gives back this connection's unused page cache.
    pub(crate) fn release_cache(&self) {
        let _ = self.conn.release_memory();
    }

    /// The bytes this connection's page cache holds.
    pub(crate) fn cache_used(&self) -> i64 {
        let (mut cur, mut high) = (0, 0);
        // SAFETY: reads a counter of this connection's own handle.
        unsafe {
            rusqlite::ffi::sqlite3_db_status(self.conn.handle(), rusqlite::ffi::SQLITE_DBSTATUS_CACHE_USED, &mut cur, &mut high, 0);
        }
        i64::from(cur)
    }

    #[cfg(test)]
    pub(crate) fn raw_handle(&self) -> *const rusqlite::ffi::sqlite3 {
        // SAFETY: the pointer is only compared, never dereferenced.
        unsafe { self.conn.handle() }
    }

    pub fn begin_transaction(&self) -> Result<(), String> {
        self.conn.execute_batch("BEGIN IMMEDIATE")
            .map_err(|e| format!("BEGIN failed: {e}"))
    }

    pub fn commit_transaction(&self) -> Result<(), String> {
        self.conn.execute_batch("COMMIT")
            .map_err(|e| format!("COMMIT failed: {e}"))
    }

    /// Drop an open transaction whose COMMIT failed, which leaves it open.
    pub fn rollback_transaction(&self) -> Result<(), String> {
        self.conn.execute_batch("ROLLBACK")
            .map_err(|e| format!("ROLLBACK failed: {e}"))
    }

    /// Land a verified synced DM on the local row of the same message stored without a
    /// mid (a legacy or mid-less delivery), which mid dedup cannot match, instead of
    /// inserting it twice.
    ///
    /// Only a row with NO mid, in the item's conversation AND direction, qualifies: a row
    /// with any mid is another message (a burst puts several in one millisecond), and the
    /// direction keeps the row's author the item's signer, as `change_may_touch_row` asks.
    /// The row becomes exactly the signed item, so it re-serves under that signature.
    /// Returns true when that happened, in which case the caller must NOT insert.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn reconcile_dm_by_timestamp(
        &self,
        peer_id: &str,
        is_mine: bool,
        new_text: &str,
        timestamp: i64,
        edited_at: Option<i64>,
        signature: Option<&str>,
        public_key: Option<&str>,
        extras: &crate::node::crypto_handler::SignedExtras<'_>,
    ) -> Result<bool, String> {
        let Some(message_id) = extras.mid else { return Ok(false) };
        let existing_id: Option<i64> = self
            .conn
            .query_row(
                "SELECT id FROM messages
                 WHERE peer_id = ?1 AND timestamp = ?2 AND is_mine = ?3 AND message_id IS NULL
                 LIMIT 1",
                params![peer_id, timestamp, is_mine as i32],
                |row| row.get(0),
            )
            .ok();

        let Some(row_id) = existing_id else {
            return Ok(false);
        };

        let order_us = extras.order_us.unwrap_or(timestamp.saturating_mul(1000));
        crate::chat_clock::observe(order_us.max(timestamp.saturating_mul(1000)));
        self.conn
            .execute(
                "UPDATE messages
                 SET message_id = ?1, text = ?2, edited_at = ?3,
                     signature = COALESCE(?4, signature),
                     public_key = COALESCE(?5, public_key),
                     reply_to_mid = ?6, file_id = ?7, order_us = ?8, album_id = ?9,
                     updated_at = ?10
                 WHERE id = ?11",
                params![
                    message_id, new_text, edited_at, signature, public_key,
                    extras.reply_to, extras.file_id, order_us, extras.album,
                    edited_at.unwrap_or(timestamp), row_id,
                ],
            )
            .map_err(|e| format!("Failed to reconcile DM row: {e}"))?;
        Ok(true)
    }

    /// Check if a DM message with the given message_id exists.
    pub fn dm_message_exists(&self, message_id: &str) -> bool {
        self.conn
            .query_row(
                "SELECT 1 FROM messages WHERE message_id = ?1 LIMIT 1",
                params![message_id],
                |_| Ok(()),
            )
            .is_ok()
    }

    /// Check if a channel message with the given message_id exists.
    pub fn channel_message_exists(&self, message_id: &str) -> bool {
        self.conn
            .query_row(
                "SELECT 1 FROM channel_messages WHERE message_id = ?1 LIMIT 1",
                params![message_id],
                |_| Ok(()),
            )
            .is_ok()
    }

    /// The ids in `message_ids` that name a deleted DM or channel message. An id
    /// we never held is NOT deleted: a reply to it may simply predate our history.
    pub fn deleted_message_ids(&self, message_ids: &[String]) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT 1 FROM message_deletions WHERE message_id = ?1
                 UNION ALL SELECT 1 FROM messages WHERE message_id = ?1 AND hidden_at IS NOT NULL
                 UNION ALL SELECT 1 FROM channel_messages WHERE message_id = ?1 AND hidden_at IS NOT NULL
                 LIMIT 1",
            )
            .map_err(|e| format!("Failed to prepare deleted-id query: {e}"))?;
        let mut out = Vec::new();
        for id in message_ids {
            let hit = stmt
                .exists(params![id])
                .map_err(|e| format!("Failed to query deleted ids: {e}"))?;
            if hit {
                out.push(id.clone());
            }
        }
        Ok(out)
    }

    /// Insert a message. Returns the row ID.
    ///
    /// `order_us` is the SENDER's microsecond send timestamp; pass `None` at receive
    /// or backfill sites that do not carry it and it defaults to `timestamp * 1000`,
    /// which orders identically to the legacy millisecond timestamp.
    #[allow(clippy::too_many_arguments)]
    pub fn insert(
        &self,
        peer_id: &str,
        text: &str,
        is_mine: bool,
        timestamp: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
        message_id: Option<&str>,
        reply_to_mid: Option<&str>,
        file_id: Option<&str>,
        order_us: Option<i64>,
        album_id: Option<&str>,
    ) -> Result<i64, String> {
        let order_us = order_us.unwrap_or(timestamp.saturating_mul(1000));
        // Every persisted stamp advances the Lamport send clock, so our NEXT send stamps
        // after everything we have seen and clock skew can no longer sort a reply above
        // the message it answers.
        crate::chat_clock::observe(order_us.max(timestamp.saturating_mul(1000)));
        let rows = self.conn
            .execute(
                "INSERT OR IGNORE INTO messages (peer_id, text, is_mine, timestamp, signature, public_key, message_id, reply_to_mid, file_id, order_us, album_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![peer_id, text, is_mine as i32, timestamp, signature, public_key, message_id, reply_to_mid, file_id, order_us, album_id],
            )
            .map_err(|e| format!("Failed to insert message: {e}"))?;
        if rows > 0 {
            Ok(self.conn.last_insert_rowid())
        } else {
            Ok(0) // Duplicate — ignored.
        }
    }

    /// Overwrite a DM row's text and signature with the caption's ONLY when the current
    /// text is a `[file:...]` sentinel.
    ///
    /// An offline captioned image arrives as TWO frames sharing one message_id: the
    /// inlined FileHeader (sentinel text, no signature) and the caption DM (the real
    /// signature over the caption). Whichever inserts first wins, so when the header
    /// won this promotes the row, which would otherwise render "Unsigned" forever.
    pub fn promote_file_sentinel_to_caption(
        &self,
        message_id: &str,
        text: &str,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        let rows = self.conn
            .execute(
                "UPDATE messages SET text = ?1, signature = ?2, public_key = ?3 \
                 WHERE message_id = ?4 AND text LIKE '[file:%]'",
                params![text, signature, public_key, message_id],
            )
            .map_err(|e| format!("promote_file_sentinel_to_caption: {e}"))?;
        Ok(rows > 0)
    }

    /// Set the link preview JSON for a DM row by `message_id`. No-op if none matches.
    pub fn update_link_preview(&self, message_id: &str, link_preview_json: &str) -> Result<(), String> {
        self.update_link_preview_in("messages", message_id, link_preview_json)
    }

    /// Set the link preview JSON for a channel row by `message_id`. No-op if none matches.
    pub fn update_channel_link_preview(&self, message_id: &str, link_preview_json: &str) -> Result<(), String> {
        self.update_link_preview_in("channel_messages", message_id, link_preview_json)
    }

    /// Shared link-preview setter. `table` is a fixed table name, never user input.
    fn update_link_preview_in(&self, table: &str, message_id: &str, link_preview_json: &str) -> Result<(), String> {
        self.conn
            .execute(
                &format!("UPDATE {table} SET link_preview_json = ?1 WHERE message_id = ?2"),
                params![link_preview_json, message_id],
            )
            .map_err(|e| format!("Failed to update {table} link preview: {e}"))?;
        Ok(())
    }

    /// Set (or clear) a DM row's link preview AND its signature together.
    pub fn update_link_preview_and_sig(
        &self,
        message_id: &str,
        link_preview_json: Option<&str>,
        signature: Option<&str>,
        public_key: Option<&str>,
        sealed_at: Option<i64>,
    ) -> Result<bool, String> {
        self.update_link_preview_and_sig_in(
            "messages", message_id, link_preview_json, signature, public_key, sealed_at,
        )
    }

    /// Channel twin of [`Self::update_link_preview_and_sig`].
    pub fn update_channel_link_preview_and_sig(
        &self,
        message_id: &str,
        link_preview_json: Option<&str>,
        signature: Option<&str>,
        public_key: Option<&str>,
        sealed_at: Option<i64>,
    ) -> Result<bool, String> {
        self.update_link_preview_and_sig_in(
            "channel_messages", message_id, link_preview_json, signature, public_key, sealed_at,
        )
    }

    /// The stamp a new card on channel row `message_id` must pass: its last card's or
    /// edit's, whichever is later. `None` = no such row.
    pub fn channel_card_floor(&self, message_id: &str) -> Option<i64> {
        self.card_floor_in("channel_messages", message_id)
    }

    /// DM twin of [`Self::channel_card_floor`].
    pub fn dm_card_floor(&self, message_id: &str) -> Option<i64> {
        self.card_floor_in("messages", message_id)
    }

    /// `table` is a fixed table name, never user input.
    fn card_floor_in(&self, table: &str, message_id: &str) -> Option<i64> {
        self.conn
            .query_row(
                &format!(
                    "SELECT MAX(COALESCE(lp_at, 0), COALESCE(edited_at, 0)) FROM {table} \
                     WHERE message_id = ?1"
                ),
                params![message_id],
                |row| row.get(0),
            )
            .ok()
    }

    /// Attach (or clear) a card and swap in the re-signature that covers it, in ONE
    /// statement. Returns whether a row matched.
    ///
    /// The pair is inseparable: the v2 signature binds `lp_digest`, so a row whose
    /// preview changed without its signature following would stop verifying and stop
    /// replicating through signed sync backfill.
    ///
    /// The re-signature carries the message's own time, so every card for one text
    /// verifies alike: a card sent live (`sealed_at`, when its frame was sealed) lands
    /// only if sealed after the card it replaces and after the row's last edit, or a
    /// replayed older one would put its card back. Signed sync backfill has no such
    /// time and passes `None`.
    ///
    /// Deliberately does NOT touch `text`, `edited_at` or `message_edits`: attaching a
    /// late card is not an edit. `table` is a fixed table name, never user input.
    fn update_link_preview_and_sig_in(
        &self,
        table: &str,
        message_id: &str,
        link_preview_json: Option<&str>,
        signature: Option<&str>,
        public_key: Option<&str>,
        sealed_at: Option<i64>,
    ) -> Result<bool, String> {
        let rows = match sealed_at {
            Some(at) => self.conn.execute(
                &format!(
                    "UPDATE {table} SET link_preview_json = ?1, signature = ?2, \
                     public_key = ?3, lp_at = ?5 WHERE message_id = ?4 \
                     AND ?5 > MAX(COALESCE(lp_at, 0), COALESCE(edited_at, 0))"
                ),
                params![link_preview_json, signature, public_key, message_id, at],
            ),
            None => self.conn.execute(
                &format!(
                    "UPDATE {table} SET link_preview_json = ?1, signature = ?2, \
                     public_key = ?3 WHERE message_id = ?4"
                ),
                params![link_preview_json, signature, public_key, message_id],
            ),
        }
        .map_err(|e| format!("Failed to update {table} link preview + sig: {e}"))?;
        Ok(rows > 0)
    }

    // -- Olm persistence --

    /// Save (upsert) the Olm account pickle.
    pub fn save_olm_account(&self, pickle_json: &str) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO olm_account (id, pickle) VALUES (1, ?1)
                 ON CONFLICT(id) DO UPDATE SET pickle = excluded.pickle",
                params![pickle_json],
            )
            .map_err(|e| format!("Failed to save olm account: {e}"))?;
        Ok(())
    }

    /// Load the Olm account pickle, if one exists.
    pub fn load_olm_account(&self) -> Result<Option<zeroize::Zeroizing<String>>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT pickle FROM olm_account WHERE id = 1")
            .map_err(|e| format!("Failed to prepare olm_account query: {e}"))?;
        let mut rows = stmt
            .query_map([], |row| row.get(0).map(zeroize::Zeroizing::new))
            .map_err(|e| format!("Failed to query olm_account: {e}"))?;
        match rows.next() {
            Some(Ok(pickle)) => Ok(Some(pickle)),
            Some(Err(e)) => Err(format!("Failed to read olm_account row: {e}")),
            None => Ok(None),
        }
    }

    /// Store a peer's session pickle at version `(sends, reads)`, but only past the
    /// stored row and any floor a removal left: two processes write this table (the
    /// node and the push fetch), so an older copy must never replace a newer one.
    /// Ordered `sends` first. An equal version keeps the row it finds, and counts as
    /// stored when that row is this very pickle (a repeat of a save that landed).
    /// Returns whether the pickle is now the stored one.
    pub fn save_olm_session(&self, peer_id: &str, pickle_json: &str, sends: i64, reads: i64) -> Result<bool, String> {
        let stored = self
            .conn
            .execute(
                "INSERT INTO olm_sessions (peer_id, pickle, sends, reads)
                 SELECT ?1, ?2, ?3, ?4
                 WHERE NOT EXISTS (
                     SELECT 1 FROM olm_session_floors f
                     WHERE f.peer_id = ?1 AND (f.sends, f.reads) >= (?3, ?4))
                 ON CONFLICT(peer_id) DO UPDATE SET
                     pickle = excluded.pickle, sends = excluded.sends, reads = excluded.reads
                 WHERE (excluded.sends, excluded.reads) > (olm_sessions.sends, olm_sessions.reads)
                    OR ((excluded.sends, excluded.reads) = (olm_sessions.sends, olm_sessions.reads)
                        AND excluded.pickle = olm_sessions.pickle)",
                params![peer_id, pickle_json, sends, reads],
            )
            .map_err(|e| format!("Failed to save olm session: {e}"))?;
        Ok(stored > 0)
    }

    /// A peer's stored session with its version: (pickle_json, sends, reads).
    pub fn load_olm_session(&self, peer_id: &str) -> Result<Option<(zeroize::Zeroizing<String>, i64, i64)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT pickle, sends, reads FROM olm_sessions WHERE peer_id = ?1")
            .map_err(|e| format!("Failed to prepare olm_sessions query: {e}"))?;
        let mut rows = stmt
            .query_map(params![peer_id], |row| Ok((zeroize::Zeroizing::new(row.get(0)?), row.get(1)?, row.get(2)?)))
            .map_err(|e| format!("Failed to query olm_sessions: {e}"))?;
        match rows.next() {
            Some(Ok(pickle)) => Ok(Some(pickle)),
            Some(Err(e)) => Err(format!("Failed to read olm_sessions row: {e}")),
            None => Ok(None),
        }
    }

    /// Delete a persisted Olm session, so a revoked device's session is not resurrected
    /// from the DB on restart. Idempotent. The floor it leaves outranks every copy of
    /// the session stored so far, so one written later by the push fetch, which loaded
    /// it before the removal, is refused too.
    pub fn delete_olm_session(&self, peer_id: &str) -> Result<(), String> {
        let drop_it = || -> rusqlite::Result<()> {
            self.conn.execute(
                "INSERT INTO olm_session_floors (peer_id, sends, reads)
                 SELECT ?1, COALESCE((SELECT sends FROM olm_sessions WHERE peer_id = ?1), 0) + 1, 0
                 WHERE true
                 ON CONFLICT(peer_id) DO UPDATE SET sends = excluded.sends, reads = excluded.reads
                 WHERE (excluded.sends, excluded.reads) > (olm_session_floors.sends, olm_session_floors.reads)",
                params![peer_id],
            )?;
            self.conn.execute("DELETE FROM olm_sessions WHERE peer_id = ?1", params![peer_id])?;
            Ok(())
        };
        self.conn
            .execute_batch("SAVEPOINT olm_session_drop")
            .map_err(|e| format!("Failed to delete olm session: {e}"))?;
        match drop_it() {
            Ok(()) => self.conn.execute_batch("RELEASE olm_session_drop"),
            Err(e) => {
                let _ = self.conn.execute_batch("ROLLBACK TO olm_session_drop; RELEASE olm_session_drop");
                Err(e)
            }
        }
        .map_err(|e| format!("Failed to delete olm session: {e}"))
    }

    /// Load all Olm session pickles (peer_id, pickle_json) pairs.
    #[cfg(test)]
    pub fn load_all_olm_sessions(&self) -> Result<Vec<(String, String)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT peer_id, pickle FROM olm_sessions")
            .map_err(|e| format!("Failed to prepare olm_sessions query: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|e| format!("Failed to query olm_sessions: {e}"))?;
        collect_rows(rows, "olm_sessions")
    }

    /// Every stored session with its version: (peer_id, pickle_json, sends, reads).
    pub fn load_olm_sessions_versioned(&self) -> Result<Vec<OlmSessionRow>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT peer_id, pickle, sends, reads FROM olm_sessions")
            .map_err(|e| format!("Failed to prepare olm_sessions query: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, zeroize::Zeroizing::new(row.get(1)?), row.get(2)?, row.get(3)?)))
            .map_err(|e| format!("Failed to query olm_sessions: {e}"))?;
        collect_rows(rows, "olm_sessions")
    }

    /// TEST-ONLY: put a stored session row back as it was, past every version check,
    /// as a database restored from a backup does.
    #[cfg(test)]
    pub fn restore_olm_session_for_test(&self, peer_id: &str, row: &(zeroize::Zeroizing<String>, i64, i64)) {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO olm_sessions (peer_id, pickle, sends, reads) VALUES (?1, ?2, ?3, ?4)",
                params![peer_id, row.0.as_str(), row.1, row.2],
            )
            .expect("restore an olm session row");
    }

    /// Every stored session's version, without its pickle: (peer_id, sends, reads).
    pub fn load_olm_session_versions(&self) -> Result<Vec<(String, i64, i64)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT peer_id, sends, reads FROM olm_sessions")
            .map_err(|e| format!("Failed to prepare olm_sessions query: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .map_err(|e| format!("Failed to query olm_sessions: {e}"))?;
        collect_rows(rows, "olm_sessions")
    }

    /// The floor each removed session left: (peer_id, sends, reads).
    pub fn load_olm_session_floors(&self) -> Result<Vec<(String, i64, i64)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT peer_id, sends, reads FROM olm_session_floors")
            .map_err(|e| format!("Failed to prepare olm_session_floors query: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .map_err(|e| format!("Failed to query olm_session_floors: {e}"))?;
        collect_rows(rows, "olm_session_floors")
    }

    /// Raise a sending device's read mark to `sealed_ms`. It never moves back: two
    /// processes share this table (the node and the push fetch).
    pub fn save_olm_read_mark(&self, peer_id: &str, sealed_ms: i64) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO olm_read_marks (peer_id, sealed_ms) VALUES (?1, ?2)
                 ON CONFLICT(peer_id) DO UPDATE SET sealed_ms = MAX(sealed_ms, excluded.sealed_ms)",
                params![peer_id, sealed_ms],
            )
            .map_err(|e| format!("Failed to save olm read mark: {e}"))?;
        Ok(())
    }

    /// Every sending device's read mark, (peer_id, sealed_ms).
    pub fn load_olm_read_marks(&self) -> Result<Vec<(String, i64)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT peer_id, sealed_ms FROM olm_read_marks")
            .map_err(|e| format!("Failed to prepare olm_read_marks query: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|e| format!("Failed to query olm_read_marks: {e}"))?;
        collect_rows(rows, "olm_read_marks")
    }

    /// Keep a live frame's nonce until `expires_ms`, charged to `share` in the `placed`
    /// pool; false when the row was already held.
    pub fn insert_live_frame_nonce(
        &self,
        sender: &str,
        nonce: &[u8],
        expires_ms: i64,
        share: &str,
        placed: bool,
    ) -> Result<bool, String> {
        self.conn
            .prepare_cached(
                "INSERT OR IGNORE INTO live_frame_nonces (sender, nonce, expires_ms, share, placed)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
            )
            .and_then(|mut stmt| stmt.execute(params![sender, nonce, expires_ms, share, placed]))
            .map(|changed| changed == 1)
            .map_err(|e| format!("Failed to note a live frame nonce: {e}"))
    }

    /// Drop the row of `share` in the `placed` pool that turns stale first; false when
    /// the share holds none.
    pub fn evict_live_frame_nonce(&self, share: &str, placed: bool) -> Result<bool, String> {
        self.conn
            .prepare_cached(
                "DELETE FROM live_frame_nonces WHERE rowid = (
                    SELECT rowid FROM live_frame_nonces WHERE placed = ?1 AND share = ?2
                    ORDER BY expires_ms LIMIT 1)",
            )
            .and_then(|mut stmt| stmt.execute(params![placed, share]))
            .map(|changed| changed == 1)
            .map_err(|e| format!("Failed to evict a live frame nonce: {e}"))
    }

    /// How many rows each (placed, share) holds.
    pub fn live_frame_nonce_shares(&self) -> Result<Vec<(bool, String, usize)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT placed, share, COUNT(*) FROM live_frame_nonces GROUP BY placed, share")
            .map_err(|e| format!("Failed to prepare live_frame_nonces shares: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get::<_, i64>(2)? as usize)))
            .map_err(|e| format!("Failed to query live_frame_nonces shares: {e}"))?;
        collect_rows(rows, "live_frame_nonces shares")
    }

    /// Forget every nonce outside `oldest_ms..=latest_ms`: stale ones, and ones stamped
    /// while our clock ran far ahead.
    pub fn prune_live_frame_nonces(&self, oldest_ms: i64, latest_ms: i64) -> Result<(), String> {
        self.conn
            .execute(
                "DELETE FROM live_frame_nonces WHERE expires_ms < ?1 OR expires_ms > ?2",
                params![oldest_ms, latest_ms],
            )
            .map_err(|e| format!("Failed to prune live frame nonces: {e}"))?;
        Ok(())
    }

    /// The nonces expiring in `oldest_ms..=latest_ms`, (sender, nonce, expires_ms).
    pub fn load_live_frame_nonces(&self, oldest_ms: i64, latest_ms: i64) -> Result<Vec<(String, Vec<u8>, i64)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached(
                "SELECT sender, nonce, expires_ms FROM live_frame_nonces WHERE expires_ms >= ?1 AND expires_ms <= ?2",
            )
            .map_err(|e| format!("Failed to prepare live_frame_nonces query: {e}"))?;
        let rows = stmt
            .query_map(params![oldest_ms, latest_ms], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .map_err(|e| format!("Failed to query live_frame_nonces: {e}"))?;
        collect_rows(rows, "live_frame_nonces")
    }

    /// Leave `account_pickle` as the only Olm state in this database, erased pages
    /// zeroed and the file rebuilt: for a host that keeps no record of its peers.
    pub fn keep_only_olm_account(&self, account_pickle: &str) -> Result<(), String> {
        self.conn
            .execute_batch(
                "PRAGMA secure_delete = ON;
                 DELETE FROM olm_sessions;
                 DELETE FROM olm_session_floors;
                 DELETE FROM olm_read_marks;
                 DELETE FROM live_frame_nonces;",
            )
            .map_err(|e| format!("Failed to erase Olm peers: {e}"))?;
        self.save_olm_account(account_pickle)?;
        self.conn
            .execute_batch("VACUUM; PRAGMA wal_checkpoint(TRUNCATE);")
            .map_err(|e| format!("Failed to rebuild the database: {e}"))
    }

    /// Load recent messages for a peer, oldest-first, excluding hidden ones.
    pub fn load_for_peer(
        &self,
        peer_id: &str,
        limit: i32,
    ) -> Result<Vec<StoredMessage>, String> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "SELECT {DM_MSG_COLS}
                 FROM messages
                 WHERE peer_id = ?1 AND hidden_at IS NULL
                 ORDER BY timestamp DESC, COALESCE(order_us, timestamp * 1000) DESC, message_id DESC, id DESC
                 LIMIT ?2",
            ))
            .map_err(|e| format!("Failed to prepare query: {e}"))?;

        let rows = stmt
            .query_map(params![peer_id, limit], dm_message_from_row)
            .map_err(|e| format!("Failed to query messages: {e}"))?;

        let mut messages = collect_rows(rows, "messages")?;
        messages.reverse(); // Oldest first for display.
        Ok(messages)
    }

    /// Single-value `MAX(timestamp)`-style query; no row or NULL → Ok(None).
    fn query_opt_ts(
        &self,
        sql: &str,
        params: &[&dyn rusqlite::types::ToSql],
        what: &str,
    ) -> Result<Option<i64>, String> {
        let mut stmt = self
            .conn
            .prepare(sql)
            .map_err(|e| format!("Failed to prepare {what} query: {e}"))?;
        let mut rows = stmt
            .query_map(params, |row| row.get::<_, Option<i64>>(0))
            .map_err(|e| format!("Failed to query {what}: {e}"))?;
        match rows.next() {
            Some(Ok(ts)) => Ok(ts),
            Some(Err(e)) => Err(format!("Failed to read {what}: {e}")),
            None => Ok(None),
        }
    }

    /// Latest DM timestamp for a peer, for sync requests. Received messages only, since
    /// sync only asks the peer for what THEY sent.
    pub fn get_latest_dm_timestamp(
        &self,
        peer_id: &str,
    ) -> Result<Option<i64>, String> {
        self.query_opt_ts(
            "SELECT MAX(timestamp) FROM messages WHERE peer_id = ?1 AND is_mine = 0",
            &[&peer_id],
            "dm latest timestamp",
        )
    }

    /// DM messages **we sent** at or after `since`, for sync responses: the requesting
    /// peer already has their own. Inclusive, because INSERT OR IGNORE handles the
    /// overlap, and hidden rows are included because evidence must sync.
    pub fn get_dm_messages_since(
        &self,
        peer_id: &str,
        since_timestamp: i64,
        limit: i32,
    ) -> Result<Vec<StoredMessage>, String> {
        self.query_dm_messages(
            &format!(
                "SELECT {DM_MSG_COLS}
                 FROM messages
                 WHERE peer_id = ?1 AND is_mine = 1 AND (timestamp >= ?2 OR updated_at >= ?2)
                 ORDER BY timestamp ASC, COALESCE(order_us, timestamp * 1000) ASC, message_id ASC
                 LIMIT ?3",
            ),
            &[&peer_id, &since_timestamp, &limit],
            "dm_messages_since",
        )
    }

    /// Run any DM-message query selecting [`DM_MSG_COLS`] and collect the rows.
    fn query_dm_messages(
        &self,
        sql: &str,
        params: &[&dyn rusqlite::types::ToSql],
        what: &str,
    ) -> Result<Vec<StoredMessage>, String> {
        let mut stmt = self
            .conn
            .prepare(sql)
            .map_err(|e| format!("Failed to prepare {what} query: {e}"))?;
        let rows = stmt
            .query_map(params, dm_message_from_row)
            .map_err(|e| format!("Failed to query {what}: {e}"))?;
        collect_rows(rows, what)
    }

    /// Latest DM timestamp in a conversation **regardless of direction**, for sibling
    /// backfill: a friend only re-serves what THEY sent, but a sibling serves both, so
    /// the requester's high-water mark must span both or we re-pull our own sends.
    pub fn get_latest_dm_timestamp_any(
        &self,
        peer_id: &str,
    ) -> Result<Option<i64>, String> {
        self.query_opt_ts(
            "SELECT MAX(timestamp) FROM messages WHERE peer_id = ?1",
            &[&peer_id],
            "dm latest-any timestamp",
        )
    }

    /// DM messages in a conversation newer than a timestamp **in BOTH directions**, for
    /// sibling backfill; `is_mine` rides along so the sibling renders each on the right
    /// side.
    ///
    /// Fresh messages use `timestamp > since` (STRICT) so the high-water message is not
    /// re-sent every reconnect, while `updated_at >= since` (inclusive) still re-syncs
    /// an edit, reaction or delete stamped on an already-synced message. Hidden rows
    /// are included because evidence must sync.
    pub fn get_dm_messages_for_sibling(
        &self,
        peer_id: &str,
        since_timestamp: i64,
        limit: i32,
    ) -> Result<Vec<StoredMessage>, String> {
        self.query_dm_messages(
            &format!(
                "SELECT {DM_MSG_COLS}
                 FROM messages
                 WHERE peer_id = ?1 AND (timestamp > ?2 OR updated_at >= ?2)
                 ORDER BY timestamp ASC, COALESCE(order_us, timestamp * 1000) ASC, message_id ASC
                 LIMIT ?3",
            ),
            &[&peer_id, &since_timestamp, &limit],
            "dm_messages_for_sibling",
        )
    }

    /// Where a DM catch-up sync starts (newest row minus the lookback overlap) and
    /// the digest of what we hold behind that point. `any_direction` picks the
    /// multi-device high-water mark; see `get_latest_dm_timestamp_any`.
    pub fn dm_sync_anchor(
        &self,
        peer_id: &str,
        any_direction: bool,
    ) -> (i64, Option<crate::node::types::GapDigest>) {
        let latest = if any_direction {
            self.get_latest_dm_timestamp_any(peer_id)
        } else {
            self.get_latest_dm_timestamp(peer_id)
        };
        let since = (latest.unwrap_or(None).unwrap_or(0) - SYNC_LOOKBACK_MS).max(0);
        (since, gap_window(since).and_then(|(from, until)| self.dm_gap_digest(peer_id, from, until).ok()))
    }

    /// Digest of what we hold in one channel behind our newest message minus the
    /// lookback overlap, which the per-sender watermarks already cover.
    pub fn channel_gap_anchor(
        &self,
        server_id: &str,
        channel_id: &str,
    ) -> Option<crate::node::types::GapDigest> {
        let latest = self.channel_ask_since(server_id, channel_id);
        let (from, until) = channel_gap_window((latest - SYNC_LOOKBACK_MS).max(0))?;
        let held = self.channel_held_from(server_id, channel_id);
        let counted = held.is_some() && self.counts_cleared(server_id, channel_id);
        let from = match held {
            // What we cleared counts as held, so a day we cleared compares as a full
            // holder's and the posts we missed after the clear show as missing.
            Some(_) if counted => from,
            // A later-starting device's lack below where it vouches is never shown as missing.
            Some(held) => from.max(held),
            None => from,
        };
        if from >= until {
            return None;
        }
        let mut digest = self
            .gap_digest(
                "SELECT message_id, timestamp FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND timestamp >= ?3 AND timestamp < ?4
                   AND message_id IS NOT NULL",
                &[&server_id, &channel_id, &from, &until],
                from,
                until,
            )
            .ok()?;
        if counted {
            self.add_cleared_counts(server_id, channel_id, &mut digest).ok()?;
        }
        Some(digest)
    }

    /// Fold what a clear counted into a digest of this channel's rows, over its window:
    /// whole days (they lie wholly inside it, see `settle_cleared_counts`) and the rows
    /// near the newest one by one.
    fn add_cleared_counts(&self, server_id: &str, channel_id: &str, digest: &mut crate::node::types::GapDigest) -> Result<(), String> {
        let err = |e: rusqlite::Error| format!("Failed to read the cleared counts: {e}");
        let mut days: BTreeMap<i64, (u32, u64)> = digest.days.iter().map(|d| (d.d, (d.n, d.h))).collect();
        let mut add = |day: i64, n: i64, h: i64| {
            let entry = days.entry(day).or_default();
            entry.0 = entry.0.saturating_add(u32::try_from(n).unwrap_or(u32::MAX));
            entry.1 ^= h as u64;
        };
        let (first, last) = (digest.from.div_euclid(DAY_MS), (digest.until - 1).div_euclid(DAY_MS));
        let mut stmt = self
            .conn
            .prepare_cached("SELECT day, n, h FROM channel_cleared_days WHERE server_id = ?1 AND channel_id = ?2 AND day >= ?3 AND day <= ?4")
            .map_err(err)?;
        for row in stmt.query_map(params![server_id, channel_id, first, last], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).map_err(err)? {
            let (day, n, h) = row.map_err(err)?;
            add(day, n, h);
        }
        let mut stmt = self
            .conn
            .prepare_cached("SELECT ts, h FROM channel_cleared_tail WHERE server_id = ?1 AND channel_id = ?2 AND ts >= ?3 AND ts < ?4")
            .map_err(err)?;
        for row in stmt.query_map(params![server_id, channel_id, digest.from, digest.until], |r| Ok((r.get::<_, i64>(0)?, r.get(1)?))).map_err(err)? {
            let (ts, h) = row.map_err(err)?;
            add(ts.div_euclid(DAY_MS), 1, h);
        }
        digest.days = days.into_iter().map(|(d, (n, h))| crate::node::types::GapDay { d, n, h }).collect();
        Ok(())
    }

    /// Per-day digest of the DM rows in `[from, until)` of one conversation, both
    /// directions.
    pub fn dm_gap_digest(
        &self,
        peer_id: &str,
        from: i64,
        until: i64,
    ) -> Result<crate::node::types::GapDigest, String> {
        self.gap_digest(
            "SELECT message_id, timestamp FROM messages
             WHERE peer_id = ?1 AND timestamp >= ?2 AND timestamp < ?3
               AND message_id IS NOT NULL",
            &[&peer_id, &from, &until],
            from,
            until,
        )
    }

    /// Fold `(message_id, timestamp)` rows into a per-day digest. Rows without a
    /// message_id cannot be deduplicated, so every caller leaves them out.
    fn gap_digest(
        &self,
        sql: &str,
        params: &[&dyn rusqlite::types::ToSql],
        from: i64,
        until: i64,
    ) -> Result<crate::node::types::GapDigest, String> {
        let mut stmt = self
            .conn
            .prepare_cached(sql)
            .map_err(|e| format!("Failed to prepare gap digest: {e}"))?;
        let rows = stmt
            .query_map(params, |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))
            .map_err(|e| format!("Failed to query gap digest: {e}"))?;
        let mut days: std::collections::BTreeMap<i64, (u32, u64)> = Default::default();
        for (mid, ts) in rows.flatten() {
            let day = days.entry(ts.div_euclid(DAY_MS)).or_default();
            day.0 += 1;
            day.1 ^= mid_hash(&mid);
        }
        Ok(crate::node::types::GapDigest {
            from,
            until,
            days: days
                .into_iter()
                .map(|(d, (n, h))| crate::node::types::GapDay { d, n, h })
                .collect(),
        })
    }

    /// The DM rows a requester is missing in its digest's range: every row on a
    /// day whose digest differs from ours, oldest first. `mine_only` keeps the
    /// one-directional friend contract.
    pub fn get_dm_gap_messages(
        &self,
        peer_id: &str,
        theirs: &crate::node::types::GapDigest,
        mine_only: bool,
        limit: i32,
    ) -> Result<Vec<StoredMessage>, String> {
        if !gap_span_ok(theirs) {
            return Ok(Vec::new());
        }
        let ours = self.dm_gap_digest(peer_id, theirs.from, theirs.until)?;
        let Some(days) = differing_days(&ours, theirs) else {
            return Ok(Vec::new());
        };
        let mine_filter = if mine_only { " AND is_mine = 1" } else { "" };
        // Hidden rows are included, as in every sibling query: evidence must sync.
        self.query_dm_messages(
            &format!(
                "SELECT {DM_MSG_COLS}
                 FROM messages
                 WHERE peer_id = ?1 AND timestamp >= ?2 AND timestamp < ?3
                   AND message_id IS NOT NULL{mine_filter}
                   AND (timestamp / {DAY_MS}) IN ({days})
                 ORDER BY timestamp ASC, COALESCE(order_us, timestamp * 1000) ASC, message_id ASC
                 LIMIT ?4",
            ),
            &[&peer_id, &theirs.from, &theirs.until, &limit],
            "dm_gap_messages",
        )
    }

    /// The channel rows a requester is missing in its digest's range; see
    /// [`Self::get_dm_gap_messages`].
    pub fn get_channel_gap_messages(
        &self,
        server_id: &str,
        channel_id: &str,
        theirs: &crate::node::types::GapDigest,
        limit: i32,
    ) -> Result<Vec<StoredChannelMessage>, String> {
        if !gap_span_ok(theirs) {
            return Ok(Vec::new());
        }
        let ours = self.gap_digest(
            "SELECT message_id, timestamp FROM channel_messages
             WHERE server_id = ?1 AND channel_id = ?2 AND timestamp >= ?3 AND timestamp < ?4
               AND message_id IS NOT NULL",
            &[&server_id, &channel_id, &theirs.from, &theirs.until],
            theirs.from,
            theirs.until,
        )?;
        let Some(days) = differing_days(&ours, theirs) else {
            return Ok(Vec::new());
        };
        let mut stmt = self
            .conn
            .prepare(&format!(
                "SELECT {CHANNEL_MSG_COLS}
                 FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND timestamp >= ?3 AND timestamp < ?4
                   AND message_id IS NOT NULL
                   AND (timestamp / {DAY_MS}) IN ({days})
                 ORDER BY timestamp ASC
                 LIMIT ?5",
            ))
            .map_err(|e| format!("Failed to prepare channel gap query: {e}"))?;
        let rows = stmt
            .query_map(
                params![server_id, channel_id, theirs.from, theirs.until, limit],
                channel_message_from_row,
            )
            .map_err(|e| format!("Failed to query channel gap: {e}"))?;
        collect_rows(rows, "channel_gap_messages")
    }

    // -- CRDT persistence methods --

    /// Save (upsert) a server's full CRDT state as JSON.
    pub fn save_server_state(&self, server_id: &str, state_json: &str) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "INSERT INTO servers (server_id, state_json, updated_at) VALUES (?1, ?2, ?3)
                 ON CONFLICT(server_id) DO UPDATE SET state_json = excluded.state_json, updated_at = excluded.updated_at",
                params![server_id, state_json, now],
            )
            .map_err(|e| format!("Failed to save server state: {e}"))?;
        Ok(())
    }

    /// Load a server's CRDT state JSON.
    pub fn load_server_state(&self, server_id: &str) -> Result<Option<String>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT state_json FROM servers WHERE server_id = ?1")
            .map_err(|e| format!("Failed to prepare servers query: {e}"))?;
        let mut rows = stmt
            .query_map(params![server_id], |row| row.get(0))
            .map_err(|e| format!("Failed to query servers: {e}"))?;
        match rows.next() {
            Some(Ok(json)) => Ok(Some(json)),
            Some(Err(e)) => Err(format!("Failed to read servers row: {e}")),
            None => Ok(None),
        }
    }

    /// Load all server states as (server_id, state_json) pairs.
    pub fn load_all_servers(&self) -> Result<Vec<(String, String)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT server_id, state_json FROM servers")
            .map_err(|e| format!("Failed to prepare servers query: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|e| format!("Failed to query servers: {e}"))?;
        collect_rows(rows, "servers")
    }

    /// Delete a server's CRDT state and all its CRDT ops from the database.
    pub fn delete_server_state(&self, server_id: &str) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM servers WHERE server_id = ?1", params![server_id])
            .map_err(|e| format!("Failed to delete server state: {e}"))?;
        self.conn
            .execute("DELETE FROM crdt_ops WHERE server_id = ?1", params![server_id])
            .map_err(|e| format!("Failed to delete server ops: {e}"))?;
        self.conn
            .execute("DELETE FROM cp_seen WHERE server_id = ?1", params![server_id])
            .map_err(|e| format!("Failed to delete first folds: {e}"))?;
        self.conn
            .execute("DELETE FROM own_kept WHERE server_id = ?1", params![server_id])
            .map_err(|e| format!("Failed to delete own rows' dates: {e}"))?;
        self.conn
            .execute("DELETE FROM floor_pending WHERE server_id = ?1", params![server_id])
            .map_err(|e| format!("Failed to delete the recovery row: {e}"))?;
        // A hole would ask the server's members for history after we left it; what a clear
        // counted goes with it (a floor without it asks as a device whose history begins later).
        for table in ["channel_sync_holes", "channel_cleared_senders", "channel_cleared_tail", "channel_cleared_days", "channel_cleared_devices"] {
            self.conn
                .execute(&format!("DELETE FROM {table} WHERE server_id = ?1"), params![server_id])
                .map_err(|e| format!("Failed to delete server holes: {e}"))?;
        }
        self.delete_server_blobs(server_id)
    }

    /// Insert a CRDT operation. Uses INSERT OR IGNORE for dedup via UNIQUE constraint.
    pub fn insert_crdt_op(&self, op: &CrdtOp) -> Result<(), String> {
        let op_json =
            serde_json::to_string(op).map_err(|e| format!("Failed to serialize CrdtOp: {e}"))?;
        self.conn
            .execute(
                "INSERT OR IGNORE INTO crdt_ops (server_id, hlc_ms, hlc_counter, author, op_json, seen_ms, content_h)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    op.server_id,
                    op.hlc.physical_ms as i64,
                    op.hlc.counter as i64,
                    op.author,
                    op_json,
                    seen_now(),
                    hex::encode(op.content_hash()),
                ],
            )
            .map_err(|e| format!("Failed to insert crdt_op: {e}"))?;
        Ok(())
    }

    /// Apply what one ingest changed (`crdt::fold::OpDelta`) in one savepoint: write
    /// every new or changed row with its parked mark (a lower-hash equivocation replaces
    /// the row at its key), then delete the rows it names. Only named rows go, so the
    /// founding op, which no fold ever drops, always stays.
    pub fn persist_op_delta(&self, delta: &crate::crdt::fold::OpDelta) -> Result<(), String> {
        self.conn
            .execute_batch("SAVEPOINT op_delta")
            .map_err(|e| format!("Failed to open op delta savepoint: {e}"))?;
        let applied = self.apply_op_delta(delta);
        let close = if applied.is_ok() { "RELEASE op_delta" } else { "ROLLBACK TO op_delta; RELEASE op_delta" };
        let _ = self.conn.execute_batch(close);
        applied
    }

    fn apply_op_delta(&self, delta: &crate::crdt::fold::OpDelta) -> Result<(), String> {
        for (op, parked) in &delta.rows {
            let op_json = serde_json::to_string(op).map_err(|e| format!("Failed to serialize CrdtOp: {e}"))?;
            self.conn
                .execute(
                    "INSERT INTO crdt_ops (server_id, hlc_ms, hlc_counter, author, op_json, parked_until, seen_ms, content_h)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                     ON CONFLICT(server_id, hlc_ms, hlc_counter, author)
                     DO UPDATE SET op_json = excluded.op_json, parked_until = excluded.parked_until,
                         seen_ms = CASE WHEN crdt_ops.content_h = excluded.content_h
                                          OR (crdt_ops.content_h = '' AND crdt_ops.op_json = excluded.op_json)
                                        THEN crdt_ops.seen_ms ELSE excluded.seen_ms END,
                         content_h = excluded.content_h",
                    params![
                        delta.server_id,
                        op.hlc.physical_ms as i64,
                        op.hlc.counter as i64,
                        op.author,
                        op_json,
                        parked.map(|p| p.min(i64::MAX as u64) as i64),
                        seen_now(),
                        hex::encode(op.content_hash()),
                    ],
                )
                .map_err(|e| format!("Failed to write crdt_op: {e}"))?;
        }
        if let Some(base) = &delta.base {
            self.conn
                .execute(
                    "INSERT OR IGNORE INTO cp_seen (server_id, content_id, first_fold_ms) VALUES (?1, ?2, ?3)",
                    params![delta.server_id, base, seen_now()],
                )
                .map_err(|e| format!("Failed to note a first fold: {e}"))?;
        }
        for ((author, ms, counter), since) in &delta.own_since {
            let key = params![delta.server_id, author, *ms as i64, *counter as i64];
            match since {
                Some(at) => self.conn.execute(
                    "INSERT OR REPLACE INTO own_kept (server_id, author, hlc_ms, hlc_counter, since_ms) VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![delta.server_id, author, *ms as i64, *counter as i64, (*at).min(i64::MAX as u64) as i64],
                ),
                None => self.conn.execute("DELETE FROM own_kept WHERE server_id = ?1 AND author = ?2 AND hlc_ms = ?3 AND hlc_counter = ?4", key),
            }
            .map_err(|e| format!("Failed to date an own row: {e}"))?;
        }
        match &delta.recovery {
            Some(Some(row)) => self.conn.execute(
                "INSERT OR REPLACE INTO floor_pending (server_id, row_json) VALUES (?1, ?2)",
                params![delta.server_id, row],
            ),
            Some(None) => self.conn.execute("DELETE FROM floor_pending WHERE server_id = ?1", params![delta.server_id]),
            None => Ok(0),
        }
        .map_err(|e| format!("Failed to write the recovery row: {e}"))?;
        if let Some(keep) = &delta.seen_keep {
            let keep = serde_json::to_string(keep).map_err(|e| format!("Failed to list kept first folds: {e}"))?;
            self.conn
                .execute(
                    "DELETE FROM cp_seen WHERE server_id = ?1 AND content_id NOT IN (SELECT value FROM json_each(?2))",
                    params![delta.server_id, keep],
                )
                .map_err(|e| format!("Failed to rotate first folds: {e}"))?;
        }
        for (author, hlc) in &delta.dropped {
            self.conn
                .execute(
                    "DELETE FROM crdt_ops WHERE server_id = ?1 AND hlc_ms = ?2 AND hlc_counter = ?3 AND author = ?4",
                    params![delta.server_id, hlc.physical_ms as i64, hlc.counter as i64, author],
                )
                .map_err(|e| format!("Failed to delete crdt_op: {e}"))?;
        }
        Ok(())
    }

    /// When this replica first folded checkpoint `content_id` as its base (0: before
    /// the 0.14 upgrade).
    pub fn cp_first_fold_ms(&self, server_id: &str, content_id: &str) -> Option<u64> {
        self.conn
            .query_row(
                "SELECT first_fold_ms FROM cp_seen WHERE server_id = ?1 AND content_id = ?2",
                params![server_id, content_id],
                |r| r.get::<_, i64>(0),
            )
            .ok()
            .map(|ms| ms.max(0) as u64)
    }

    /// The server's `floor_pending` row (section 8.8), local and never served.
    pub fn floor_pending(&self, server_id: &str) -> Option<String> {
        self.conn.query_row("SELECT row_json FROM floor_pending WHERE server_id = ?1", params![server_id], |r| r.get(0)).ok()
    }

    /// Every first-fold record of a server (content id hex -> ms; 0 before the upgrade).
    pub fn cp_first_folds(&self, server_id: &str) -> HashMap<String, u64> {
        let Ok(mut stmt) = self.conn.prepare("SELECT content_id, first_fold_ms FROM cp_seen WHERE server_id = ?1") else {
            return HashMap::new();
        };
        stmt.query_map(params![server_id], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?.max(0) as u64)))
            .map(|rows| rows.filter_map(Result::ok).collect())
            .unwrap_or_default()
    }

    /// When this replica first stored each row of a server, by (author, clock ms,
    /// counter); 0 for rows from before the 0.14 upgrade.
    /// When each of our own kept rows of a server was first dominated (`ServerState.own_since`).
    pub fn own_kept_since(&self, server_id: &str) -> HashMap<(String, u64, u32), u64> {
        let Ok(mut stmt) = self.conn.prepare("SELECT author, hlc_ms, hlc_counter, since_ms FROM own_kept WHERE server_id = ?1") else {
            return HashMap::new();
        };
        let rows = stmt.query_map(params![server_id], |r| {
            Ok((
                (r.get::<_, String>(0)?, r.get::<_, i64>(1)?.max(0) as u64, r.get::<_, i64>(2)?.clamp(0, i64::from(u32::MAX)) as u32),
                r.get::<_, i64>(3)?.max(0) as u64,
            ))
        });
        rows.map(|r| r.filter_map(Result::ok).collect()).unwrap_or_default()
    }

    /// When this replica first stored any op of a server (0: before the 0.14 upgrade).
    pub fn op_first_seen_ms(&self, server_id: &str) -> Option<u64> {
        self.conn
            .query_row("SELECT MIN(seen_ms) FROM crdt_ops WHERE server_id = ?1", params![server_id], |r| r.get::<_, Option<i64>>(0))
            .ok()
            .flatten()
            .map(|ms| ms.max(0) as u64)
    }

    pub fn op_seen_ms(&self, server_id: &str) -> Result<HashMap<(String, u64, u32), u64>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT author, hlc_ms, hlc_counter, seen_ms FROM crdt_ops WHERE server_id = ?1")
            .map_err(|e| format!("Failed to prepare seen_ms query: {e}"))?;
        let rows = stmt
            .query_map(params![server_id], |r| {
                Ok(((r.get::<_, String>(0)?, r.get::<_, i64>(1)?.max(0) as u64, r.get::<_, i64>(2)?.clamp(0, i64::from(u32::MAX)) as u32), r.get::<_, i64>(3)?.max(0) as u64))
            })
            .map_err(|e| format!("Failed to query seen_ms: {e}"))?;
        rows.collect::<Result<_, _>>().map_err(|e| format!("Failed to read seen_ms: {e}"))
    }

    /// Every stored row of a server with its parked mark, in clock order: what
    /// `ServerState::restore_op_log` rebuilds from.
    pub fn load_op_rows(&self, server_id: &str) -> Result<Vec<(CrdtOp, Option<u64>)>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT op_json, parked_until FROM crdt_ops WHERE server_id = ?1
                 ORDER BY hlc_ms, hlc_counter, author",
            )
            .map_err(|e| format!("Failed to prepare crdt_ops query: {e}"))?;
        let rows = stmt
            .query_map(params![server_id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)))
            .map_err(|e| format!("Failed to query crdt_ops: {e}"))?;
        let mut out = Vec::new();
        for row in rows {
            let (json, parked) = row.map_err(|e| format!("Failed to read crdt_ops row: {e}"))?;
            // One row this build cannot parse must not take the server's whole log with it.
            if let Ok(op) = serde_json::from_str::<CrdtOp>(&json) {
                out.push((op, parked.map(|p| p.max(0) as u64)));
            }
        }
        Ok(out)
    }

    /// Every distinct author of a channel post we hold in `server_id`, as stored.
    pub fn channel_authors(&self, server_id: &str) -> Vec<String> {
        let Ok(mut stmt) = self.conn.prepare_cached(
            "SELECT DISTINCT sender_id FROM channel_messages WHERE server_id = ?1",
        ) else {
            return Vec::new();
        };
        stmt.query_map(params![server_id], |row| row.get::<_, String>(0))
            .map(|rows| rows.filter_map(Result::ok).collect())
            .unwrap_or_default()
    }

    /// Prune a LEGACY-anchored server's ops to its newest `keep_count`. Anchored servers
    /// are never pruned by count: their state is rebuilt from every op since the anchor,
    /// and only a checkpoint drops rows (`persist_admitted_ops`).
    pub fn prune_crdt_ops(&self, server_id: &str, keep_count: usize) -> Result<usize, String> {
        let deleted = self.conn
            .execute(
                "DELETE FROM crdt_ops WHERE server_id = ?1 AND id NOT IN (
                    SELECT id FROM crdt_ops WHERE server_id = ?1
                    ORDER BY hlc_ms DESC, hlc_counter DESC LIMIT ?2
                )",
                params![server_id, keep_count as i64],
            )
            .map_err(|e| format!("Failed to prune crdt_ops: {e}"))?;
        Ok(deleted)
    }

    /// Save (upsert) a key-value blob for a server (e.g. server_avatar).
    pub fn save_server_blob(&self, server_id: &str, key: &str, value: &str) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO server_blobs (server_id, key, value) VALUES (?1, ?2, ?3)
                 ON CONFLICT(server_id, key) DO UPDATE SET value = excluded.value",
                params![server_id, key, value],
            )
            .map_err(|e| format!("Failed to save server blob: {e}"))?;
        Ok(())
    }

    /// Load a server blob by key.
    pub fn load_server_blob(&self, server_id: &str, key: &str) -> Result<Option<String>, String> {
        let mut stmt = self.conn
            .prepare_cached("SELECT value FROM server_blobs WHERE server_id = ?1 AND key = ?2")
            .map_err(|e| format!("Failed to prepare server_blobs query: {e}"))?;
        let mut rows = stmt
            .query_map(params![server_id, key], |row| row.get(0))
            .map_err(|e| format!("Failed to query server_blobs: {e}"))?;
        match rows.next() {
            Some(Ok(value)) => Ok(Some(value)),
            Some(Err(e)) => Err(format!("Failed to read server_blobs row: {e}")),
            None => Ok(None),
        }
    }

    /// Delete one blob of a server.
    pub fn delete_server_blob(&self, server_id: &str, key: &str) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM server_blobs WHERE server_id = ?1 AND key = ?2", params![server_id, key])
            .map_err(|e| format!("Failed to delete server blob: {e}"))?;
        Ok(())
    }

    /// Delete all blobs for a server.
    pub fn delete_server_blobs(&self, server_id: &str) -> Result<(), String> {
        self.conn
            .execute(
                "DELETE FROM server_blobs WHERE server_id = ?1",
                params![server_id],
            )
            .map_err(|e| format!("Failed to delete server blobs: {e}"))?;
        Ok(())
    }

    /// Load CRDT ops for a server, HLC-ordered: the newest `limit` (a legacy-anchored
    /// server, whose log is capped), or every row (an anchored one, rebuilt from them).
    pub fn load_ops_for_server(&self, server_id: &str, limit: Option<usize>) -> Result<Vec<CrdtOp>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT op_json FROM (
                     SELECT op_json, hlc_ms, hlc_counter, author FROM crdt_ops
                     WHERE server_id = ?1
                     ORDER BY hlc_ms DESC, hlc_counter DESC, author DESC LIMIT ?2
                 ) ORDER BY hlc_ms, hlc_counter, author",
            )
            .map_err(|e| format!("Failed to prepare crdt_ops query: {e}"))?;
        let limit = limit.map_or(-1, |n| n as i64);
        let rows = stmt
            .query_map(params![server_id, limit], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query crdt_ops: {e}"))?;
        let mut ops = Vec::new();
        for row in rows {
            let json = row.map_err(|e| format!("Failed to read crdt_ops row: {e}"))?;
            let op: CrdtOp = serde_json::from_str(&json)
                .map_err(|e| format!("Failed to deserialize CrdtOp: {e}"))?;
            ops.push(op);
        }
        Ok(ops)
    }

    /// Save (upsert) HLC state.
    pub fn save_hlc_state(
        &self,
        physical_ms: u64,
        counter: u32,
        actor: &str,
    ) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO hlc_state (id, physical_ms, counter, actor) VALUES (1, ?1, ?2, ?3)
                 ON CONFLICT(id) DO UPDATE SET physical_ms = excluded.physical_ms, counter = excluded.counter, actor = excluded.actor",
                params![physical_ms as i64, counter as i64, actor],
            )
            .map_err(|e| format!("Failed to save hlc_state: {e}"))?;
        Ok(())
    }

    // -- Channel message methods --

    /// Insert a channel message. Returns rows inserted, 0 for a duplicate or for
    /// history this device cleared.
    ///
    /// `order_us`: see [`Self::insert`].
    #[allow(clippy::too_many_arguments)]
    pub fn insert_channel_message(
        &self,
        server_id: &str,
        channel_id: &str,
        sender_id: &str,
        text: &str,
        is_mine: bool,
        timestamp: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
        message_id: Option<&str>,
        reply_to_mid: Option<&str>,
        file_id: Option<&str>,
        order_us: Option<i64>,
        album_id: Option<&str>,
    ) -> Result<usize, String> {
        self.insert_channel_message_judged(
            server_id, channel_id, sender_id, text, is_mine, timestamp, signature, public_key,
            message_id, reply_to_mid, file_id, order_us, album_id,
        )
        .map(|outcome| usize::from(outcome == ChannelInsert::Stored))
    }

    /// [`Self::insert_channel_message`], telling a duplicate from cleared history.
    #[allow(clippy::too_many_arguments)]
    pub fn insert_channel_message_judged(
        &self,
        server_id: &str,
        channel_id: &str,
        sender_id: &str,
        text: &str,
        is_mine: bool,
        timestamp: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
        message_id: Option<&str>,
        reply_to_mid: Option<&str>,
        file_id: Option<&str>,
        order_us: Option<i64>,
        album_id: Option<&str>,
    ) -> Result<ChannelInsert, String> {
        let order_us = order_us.unwrap_or(timestamp.saturating_mul(1000));
        // Lamport chat clock — see [`Self::insert`] and chat_clock.rs.
        crate::chat_clock::observe(order_us.max(timestamp.saturating_mul(1000)));
        // History this device cleared is refused in the same statement, on every path:
        // live, sync and push alike.
        let hash = message_id.map(cleared_id_hash);
        let rows = self.conn
            .execute(
                &format!(
                    "INSERT OR IGNORE INTO channel_messages (server_id, channel_id, sender_id, text, is_mine, timestamp, signature, public_key, message_id, reply_to_mid, file_id, order_us, album_id)
                     SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13
                     WHERE NOT {}",
                    floor_refuses_sql("?1", "?2", "?6", "?14"),
                ),
                params![server_id, channel_id, sender_id, text, is_mine as i32, timestamp, signature, public_key, message_id, reply_to_mid, file_id, order_us, album_id, hash],
            )
            .map_err(|e| format!("Failed to insert channel message: {e}"))?;
        if rows > 0 {
            return Ok(ChannelInsert::Stored);
        }
        Ok(if self.channel_floor_refuses(server_id, channel_id, timestamp, message_id) {
            ChannelInsert::Cleared
        } else {
            ChannelInsert::Duplicate
        })
    }

    /// Keep a post's device proof on its row; a row keeps the first proof it got, and the
    /// caller writes one only for a row it just stored.
    pub(crate) fn set_channel_post_proof(&self, message_id: &str, dev: &crate::crdt::operations::DevProof) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE channel_messages SET dev_device = ?2, dev_sig = ?3 WHERE message_id = ?1 AND dev_device IS NULL",
                params![message_id, dev.device, dev.sig],
            )
            .map(|_| ())
            .map_err(|e| format!("Failed to keep a post proof: {e}"))
    }

    /// The device proofs of `message_ids`, for a sync answer.
    pub(crate) fn channel_post_proofs(&self, message_ids: &[&str]) -> HashMap<String, crate::crdt::operations::DevProof> {
        let mut out = HashMap::new();
        let Ok(mut stmt) = self.conn.prepare_cached(
            "SELECT dev_device, dev_sig FROM channel_messages WHERE message_id = ?1 AND dev_device IS NOT NULL AND dev_sig IS NOT NULL",
        ) else {
            return out;
        };
        for mid in message_ids {
            if let Ok((device, sig)) = stmt.query_row(params![mid], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))) {
                out.insert((*mid).to_string(), crate::crdt::operations::DevProof { device, sig });
            }
        }
        out
    }

    /// Keep the device proof of the deletion `message_id`'s newest signed record holds.
    pub(crate) fn set_deletion_dev(&self, message_id: &str, dev: &crate::crdt::operations::DevProof) -> Result<(), String> {
        let json = serde_json::to_string(dev).map_err(|e| e.to_string())?;
        self.conn
            .execute(
                "UPDATE message_deletions SET dev = ?2 WHERE id = (SELECT id FROM message_deletions
                  WHERE message_id = ?1 AND signature IS NOT NULL ORDER BY id DESC LIMIT 1) AND dev IS NULL",
                params![message_id, json],
            )
            .map(|_| ())
            .map_err(|e| format!("Failed to keep a deletion proof: {e}"))
    }

    /// The card proof a channel row keeps with its card; `None` clears it.
    pub(crate) fn set_channel_card_proof(&self, message_id: &str, dev: Option<&crate::node::types::CardProof>) -> Result<(), String> {
        let json = dev.and_then(|d| serde_json::to_string(d).ok());
        self.conn
            .execute("UPDATE channel_messages SET lp_dev = ?2 WHERE message_id = ?1", params![message_id, json])
            .map(|_| ())
            .map_err(|e| format!("Failed to keep a card proof: {e}"))
    }

    /// Keep the device proof of the reaction `peer_id` added on `message_id` at `added_at`.
    pub(crate) fn set_reaction_dev(&self, message_id: &str, emoji: &str, peer_id: &str, added_at: i64, dev: &crate::crdt::operations::DevProof) -> Result<(), String> {
        let json = serde_json::to_string(dev).map_err(|e| e.to_string())?;
        self.conn
            .execute(
                "UPDATE message_reactions SET dev = ?4 WHERE message_id = ?1 AND emoji = ?2 AND peer_id = ?3 AND added_at = ?5",
                params![message_id, emoji, peer_id, json, added_at],
            )
            .map(|_| ())
            .map_err(|e| format!("Failed to keep a reaction proof: {e}"))
    }

    /// The device proof a file card keeps with its metadata; `None` clears it.
    pub(crate) fn set_file_meta_dev(&self, file_id: &str, dev: Option<&crate::crdt::operations::DevProof>) -> Result<(), String> {
        let json = dev.and_then(|d| serde_json::to_string(d).ok());
        self.conn
            .execute("UPDATE files SET meta_dev = ?2 WHERE file_id = ?1", params![file_id, json])
            .map(|_| ())
            .map_err(|e| format!("Failed to keep a file card proof: {e}"))
    }

    /// The change proofs riding `message_ids` (and their files), for a sync answer.
    pub(crate) fn change_proofs(&self, message_ids: &[&str], file_ids: &[&str]) -> ChangeProofs {
        fn parse<T: serde::de::DeserializeOwned>(json: Option<String>) -> Option<T> {
            json.and_then(|j| serde_json::from_str(&j).ok())
        }
        let mut out = ChangeProofs::default();
        let one = |sql: &str, key: &str| -> Option<String> {
            self.conn.prepare_cached(sql).ok()?.query_row(params![key], |r| r.get::<_, Option<String>>(0)).ok().flatten()
        };
        for mid in message_ids {
            let deletion = "SELECT dev FROM message_deletions WHERE message_id = ?1 AND signature IS NOT NULL ORDER BY id DESC LIMIT 1";
            if let Some(d) = parse(one(deletion, mid)) {
                out.deletions.insert((*mid).to_string(), d);
            }
            if let Some(c) = parse(one("SELECT lp_dev FROM channel_messages WHERE message_id = ?1", mid)) {
                out.cards.insert((*mid).to_string(), c);
            }
            if let Ok(mut stmt) = self.conn.prepare_cached("SELECT emoji, peer_id, dev FROM message_reactions WHERE message_id = ?1 AND dev IS NOT NULL") {
                let rows = stmt.query_map(params![mid], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, Option<String>>(2)?)));
                for (emoji, peer, dev) in rows.into_iter().flatten().flatten() {
                    if let Some(d) = parse(dev) {
                        out.reactions.insert(((*mid).to_string(), emoji, peer), d);
                    }
                }
            }
        }
        for fid in file_ids {
            if let Some(d) = parse(one("SELECT meta_dev FROM files WHERE file_id = ?1", fid)) {
                out.files.insert((*fid).to_string(), d);
            }
        }
        out
    }

    /// The newest date the gate judged of what `device` proved for `master` in a server
    /// (posts, edits, deletions, cards, reactions, file cards): what a retire of that
    /// device keeps counting (section 13).
    pub(crate) fn newest_post_of_device(&self, server_id: &str, master: &str, device: &str) -> Option<i64> {
        let newest = |sql: &str| {
            self.conn.query_row(sql, params![server_id, master, device], |r| r.get::<_, Option<i64>>(0)).ok().flatten()
        };
        let posts = newest(
            "SELECT MAX(MAX(timestamp, COALESCE(edited_at, timestamp))) FROM channel_messages WHERE server_id = ?1 AND sender_id = ?2 AND dev_device = ?3",
        );
        // What a clear of ours took still counts: the remover's window never drops below it.
        let cleared = newest(
            "SELECT MAX(last_ts) FROM channel_cleared_devices WHERE server_id = ?1 AND device = ?3 AND (sender_id = ?2 OR (reactor = 1 AND sender_id = ?3))",
        );
        posts.into_iter().chain(cleared).chain(self.newest_change_of_device(server_id, master, device)).max()
    }

    /// [`Self::newest_post_of_device`] over the change proofs, each judged at the later of
    /// its post's date and its own. Only a proof naming exactly `device` counts.
    fn newest_change_of_device(&self, server_id: &str, master: &str, device: &str) -> Option<i64> {
        // (the row's date, the proof); `instr` only narrows, the parse decides.
        const SQL: [&str; 4] = [
            "SELECT MAX(cm.timestamp, md.deleted_at), md.dev FROM message_deletions md JOIN channel_messages cm ON cm.message_id = md.message_id
              WHERE cm.server_id = ?1 AND cm.sender_id = ?2 AND md.dev IS NOT NULL AND instr(md.dev, ?3) > 0",
            "SELECT timestamp, lp_dev FROM channel_messages
              WHERE server_id = ?1 AND sender_id = ?2 AND lp_dev IS NOT NULL AND instr(lp_dev, ?3) > 0",
            "SELECT MAX(cm.timestamp, mr.added_at), mr.dev FROM message_reactions mr JOIN channel_messages cm ON cm.message_id = mr.message_id
              WHERE cm.server_id = ?1 AND mr.peer_id IN (?2, ?3) AND mr.dev IS NOT NULL AND instr(mr.dev, ?3) > 0",
            "SELECT cm.timestamp, f.meta_dev FROM files f JOIN channel_messages cm ON cm.message_id = f.message_id
              WHERE cm.server_id = ?1 AND cm.sender_id = ?2 AND f.meta_dev IS NOT NULL AND instr(f.meta_dev, ?3) > 0",
        ];
        let mut newest: Option<i64> = None;
        for sql in SQL {
            let Ok(mut stmt) = self.conn.prepare_cached(sql) else { continue };
            let rows = stmt.query_map(params![server_id, master, device], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)));
            for (date, json) in rows.into_iter().flatten().flatten() {
                if let Some((named, at)) = proof_names(&json)
                    && named == device
                {
                    // A card dates by its own `at`; the other kinds by their row.
                    newest = newest.max(Some(at.map_or(date, |at| at.max(date))));
                }
            }
        }
        newest
    }

    /// Whether a channel row, or a header, reaction or card riding one, is history
    /// this device cleared.
    pub fn channel_floor_refuses(&self, server_id: &str, channel_id: &str, timestamp: i64, message_id: Option<&str>) -> bool {
        self.conn
            .prepare_cached(&format!("SELECT {}", floor_refuses_sql("?1", "?2", "?3", "?4")))
            .and_then(|mut s| {
                s.query_row(params![server_id, channel_id, timestamp, message_id.map(cleared_id_hash)], |r| r.get(0))
            })
            .unwrap_or(false)
    }

    /// Test-only: the connection, for writing a row past every gate.
    #[cfg(test)]
    pub(crate) fn conn_for_test(&self) -> &Connection {
        &self.conn
    }

    /// Clear every server channel's history on THIS device; see [`Self::clear_history_in`].
    pub fn clear_channel_history(&self, now_ms: i64) -> Result<ClearedHistory, String> {
        self.clear_history_in(None, &[], now_ms)
    }

    /// Clear the history of every channel of `server_id` (every server when `None`) on
    /// THIS device (Settings > Storage, or a server's settings). Each channel first gets
    /// its floor: its newest row but never past `now_ms`, or `now_ms` for a channel of
    /// `channels` (server, channel) holding nothing yet. The ids cleared within
    /// `CLEAR_SKEW_MS` of it are remembered, and the senders it held. Then every row
    /// the floors refuse goes with what hangs off it, and the file shrinks. Nothing is
    /// sent: other members keep theirs.
    pub fn clear_history_in(&self, server_id: Option<&str>, channels: &[(String, String)], now_ms: i64) -> Result<ClearedHistory, String> {
        in_write_tx(&self.conn, |conn| {
            let err = |what: &'static str| move |e: rusqlite::Error| format!("{what}: {e}");
            conn.execute(
                "INSERT INTO channel_floors (server_id, channel_id, floor_ts)
                 SELECT server_id, channel_id, MIN(MAX(timestamp), ?1) FROM channel_messages
                 WHERE ?2 IS NULL OR server_id = ?2
                 GROUP BY server_id, channel_id
                 ON CONFLICT(server_id, channel_id) DO UPDATE SET floor_ts = MAX(floor_ts, excluded.floor_ts)",
                params![now_ms, server_id],
            )
            .map_err(err("floors"))?;
            for (sid, cid) in channels.iter().filter(|(sid, _)| server_id.is_none_or(|s| s == sid)) {
                conn.execute(
                    "INSERT INTO channel_floors (server_id, channel_id, floor_ts)
                     SELECT ?1, ?2, ?3 WHERE NOT EXISTS (SELECT 1 FROM channel_messages WHERE server_id = ?1 AND channel_id = ?2)
                     ON CONFLICT(server_id, channel_id) DO UPDATE SET floor_ts = MAX(floor_ts, excluded.floor_ts)",
                    params![sid, cid, now_ms],
                )
                .map_err(err("empty channel floors"))?;
            }
            let floors: Vec<(String, String, i64, Option<i64>)> = {
                let mut stmt = conn
                    .prepare("SELECT server_id, channel_id, floor_ts, exact_from FROM channel_floors WHERE ?1 IS NULL OR server_id = ?1")
                    .map_err(err("read floors"))?;
                let rows = stmt.query_map([server_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))).map_err(err("read floors"))?;
                collect_rows(rows, "floor")?
            };
            for (sid, cid, floor, old_exact) in floors {
                remember_cleared_ids(conn, &sid, &cid, floor, old_exact).map_err(err("cleared ids"))?;
            }
            // A clear's floor is its line: a hole would ask for what it threw away.
            conn.execute(
                "DELETE FROM channel_sync_holes WHERE EXISTS (SELECT 1 FROM channel_floors f
                     WHERE f.server_id = channel_sync_holes.server_id AND f.channel_id = channel_sync_holes.channel_id)",
                [],
            )
            .map(|_| ())
            .map_err(err("holes"))
        })
        .map_err(|e| format!("Failed to mark the cleared history: {e}"))?;
        self.finish_cleared_history()
    }

    /// Delete every row the floors refuse, with its edits, deletions, reactions and file
    /// rows, a batch per transaction, then give the file's pages back. The second half
    /// of a clear, and at start the rest of one a crash or kill cut short.
    pub fn finish_cleared_history(&self) -> Result<ClearedHistory, String> {
        let pending: bool = self
            .conn
            .query_row("SELECT EXISTS (SELECT 1 FROM channel_floors) OR EXISTS (SELECT 1 FROM channel_cleared_files)", [], |r| r.get(0))
            .map_err(|e| format!("Failed to read the floors: {e}"))?;
        if !pending {
            return Ok(ClearedHistory::default());
        }
        self.conn
            .execute_batch(
                "CREATE TEMP TABLE IF NOT EXISTS clear_batch (id INTEGER PRIMARY KEY, mid TEXT);
                 CREATE TEMP TABLE IF NOT EXISTS clear_near (id INTEGER PRIMARY KEY);
                 DELETE FROM temp.clear_near;",
            )
            .map_err(|e| format!("Failed to prepare the clear: {e}"))?;
        self.mark_cleared_near_floors().map_err(|e| format!("Failed to find the cleared rows: {e}"))?;
        let mut cleared = ClearedHistory::default();
        loop {
            let batch = in_write_tx(&self.conn, |conn| {
                let run = |sql: &str| conn.execute_batch(sql).map_err(|e| e.to_string());
                run("DELETE FROM temp.clear_batch")?;
                let rows = conn
                    .execute(CLEAR_BATCH_SELECT, [CLEAR_BATCH_ROWS])
                    .map_err(|e| e.to_string())?;
                if rows > 0 {
                    count_cleared_batch(conn).map_err(|e| e.to_string())?;
                    // Ids are sender-chosen: a DM sharing one keeps its evidence.
                    run(
                        "INSERT OR IGNORE INTO channel_cleared_files (file_id, file_ext)
                             SELECT file_id, file_ext FROM files
                             WHERE context_type = 'channel' AND message_id IN (SELECT mid FROM temp.clear_batch);
                         DELETE FROM file_chunks WHERE file_id IN (SELECT file_id FROM files
                             WHERE context_type = 'channel' AND message_id IN (SELECT mid FROM temp.clear_batch));
                         DELETE FROM files
                             WHERE context_type = 'channel' AND message_id IN (SELECT mid FROM temp.clear_batch);
                         DELETE FROM message_edits WHERE message_id IN (SELECT mid FROM temp.clear_batch)
                             AND NOT EXISTS (SELECT 1 FROM messages d WHERE d.message_id = message_edits.message_id);
                         DELETE FROM message_deletions WHERE message_id IN (SELECT mid FROM temp.clear_batch)
                             AND NOT EXISTS (SELECT 1 FROM messages d WHERE d.message_id = message_deletions.message_id);
                         DELETE FROM message_reactions WHERE message_id IN (SELECT mid FROM temp.clear_batch)
                             AND NOT EXISTS (SELECT 1 FROM messages d WHERE d.message_id = message_reactions.message_id);
                         DELETE FROM reaction_removals WHERE message_id IN (SELECT mid FROM temp.clear_batch)
                             AND NOT EXISTS (SELECT 1 FROM messages d WHERE d.message_id = reaction_removals.message_id);
                         DELETE FROM channel_messages WHERE id IN (SELECT id FROM temp.clear_batch);
                         DELETE FROM temp.clear_near WHERE id IN (SELECT id FROM temp.clear_batch);",
                    )?;
                }
                Ok(rows)
            })
            .map_err(|e| format!("Failed to clear messages: {e}"))?;
            if batch == 0 {
                break;
            }
            cleared.messages += batch as u64;
        }
        let mut stmt = self
            .conn
            .prepare("SELECT file_id, file_ext FROM channel_cleared_files")
            .map_err(|e| format!("Failed to read the cleared files: {e}"))?;
        let names = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
            .map_err(|e| format!("Failed to read the cleared files: {e}"))?;
        cleared.files = collect_rows(names, "cleared file")?;
        if cleared.messages > 0 {
            // Space only: a failure here leaves a larger file, never a wrong one.
            let _ = self.conn.execute_batch("INSERT INTO channel_messages_fts(channel_messages_fts) VALUES('optimize');");
            release_free_pages(&self.conn, None);
            let _ = self.wal_checkpoint();
        }
        Ok(cleared)
    }

    /// Forget the names of cleared files once the caller has unlinked them.
    pub fn forget_cleared_files(&self, files: &[(String, String)]) -> Result<(), String> {
        in_write_tx(&self.conn, |conn| {
            let mut forget = conn
                .prepare("DELETE FROM channel_cleared_files WHERE file_id = ?1 AND file_ext = ?2")
                .map_err(|e| e.to_string())?;
            for (file_id, ext) in files {
                forget.execute(params![file_id, ext]).map_err(|e| e.to_string())?;
            }
            Ok(())
        })
        .map_err(|e| format!("Failed to forget the cleared files: {e}"))
    }

    /// The rows past the outright refusal whose id this device cleared (within
    /// `CLEAR_SKEW_MS` below a floor, or stamped above it), into `temp.clear_near`:
    /// their ids are known only by hash, so each is found by its remembered time.
    fn mark_cleared_near_floors(&self) -> rusqlite::Result<()> {
        let mut near = self.conn.prepare(CLEARED_NEAR_SELECT)?;
        let rows = near
            .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, String>(3)?)))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut cleared = self.conn.prepare(
            "SELECT 1 FROM channel_cleared_ids WHERE server_id = ?1 AND channel_id = ?2 AND mid_hash = ?3",
        )?;
        let mut keep = self.conn.prepare("INSERT OR IGNORE INTO temp.clear_near (id) VALUES (?1)")?;
        for (id, mid, sid, cid) in rows {
            if cleared.exists(params![sid, cid, cleared_id_hash(&mid)])? {
                keep.execute([id])?;
            }
        }
        Ok(())
    }

    /// Server channel messages this device holds.
    pub fn count_all_channel_messages(&self) -> Result<u32, String> {
        self.conn
            .query_row("SELECT COUNT(*) FROM channel_messages", [], |r| r.get(0))
            .map_err(|e| format!("Failed to count channel messages: {e}"))
    }

    /// Load recent messages for a channel, oldest-first, excluding hidden ones.
    pub fn load_channel_messages(
        &self,
        server_id: &str,
        channel_id: &str,
        limit: i32,
    ) -> Result<Vec<StoredChannelMessage>, String> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "SELECT {CHANNEL_MSG_COLS}
                 FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND hidden_at IS NULL
                 ORDER BY timestamp DESC, COALESCE(order_us, timestamp * 1000) DESC, sender_id DESC, message_id DESC, id DESC
                 LIMIT ?3",
            ))
            .map_err(|e| format!("Failed to prepare channel_messages query: {e}"))?;

        let rows = stmt
            .query_map(params![server_id, channel_id, limit], channel_message_from_row)
            .map_err(|e| format!("Failed to query channel_messages: {e}"))?;

        let mut messages = collect_rows(rows, "channel_messages")?;
        messages.reverse(); // Oldest first for display.
        Ok(messages)
    }

    /// How far this device's history of a channel reaches, for sync asks and catch-up:
    /// its newest row, or the floor it cleared the channel up to when that is newer.
    pub fn get_latest_channel_timestamp(
        &self,
        server_id: &str,
        channel_id: &str,
    ) -> Result<Option<i64>, String> {
        self.query_opt_ts(
            "SELECT MAX(ts) FROM (
                 SELECT MAX(timestamp) AS ts FROM channel_messages WHERE server_id = ?1 AND channel_id = ?2
                 UNION ALL
                 SELECT floor_ts FROM channel_floors WHERE server_id = ?1 AND channel_id = ?2
             )",
            &[&server_id, &channel_id],
            "latest timestamp",
        )
    }

    /// Where a sync page from this device starts vouching for a channel: its oldest row
    /// at or after the point below which it lacks history (`i64::MAX` with none there),
    /// `None` for a device lacking none. One rule for a device that cleared the channel
    /// and one whose history begins later (a late join, a return, a copy): the value
    /// names a row the page serves or the asker holds, never the clear or the hole.
    pub fn channel_held_from(&self, server_id: &str, channel_id: &str) -> Option<i64> {
        let mark: i64 = self
            .conn
            .prepare_cached(
                "SELECT MAX(m) FROM (
                     SELECT MAX(f.floor_ts, COALESCE((SELECT MAX(k.ts) FROM channel_cleared_ids k
                         WHERE k.server_id = f.server_id AND k.channel_id = f.channel_id
                           AND k.ts > f.floor_ts AND k.ts <= f.floor_ts + ?3), f.floor_ts)) + 1 AS m
                     FROM channel_floors f WHERE f.server_id = ?1 AND f.channel_id = ?2
                     UNION ALL
                     SELECT below FROM channel_sync_holes WHERE server_id = ?1 AND channel_id = ?2
                 )",
            )
            .and_then(|mut s| s.query_row(params![server_id, channel_id, CLEAR_SKEW_MS], |r| r.get::<_, Option<i64>>(0)))
            // Unreadable: lacking everything, never vouching for what we may not hold.
            .unwrap_or(Some(i64::MAX))?;
        let oldest: Option<i64> = self
            .conn
            .prepare_cached("SELECT MIN(timestamp) FROM channel_messages WHERE server_id = ?1 AND channel_id = ?2 AND timestamp >= ?3")
            .and_then(|mut s| s.query_row(params![server_id, channel_id, mark], |r| r.get(0)))
            .unwrap_or(None);
        Some(oldest.unwrap_or(i64::MAX))
    }

    /// Whether a channel sync ask wants a row before `held_from`: a plain `since` (an ask
    /// naming no sender) or a named sender below it, a gap digest starting below it, or a
    /// sender we hold from it on that the ask leaves out (served in full). Reads only
    /// rows at or after it.
    pub fn channel_ask_reaches_below(
        &self,
        server_id: &str,
        channel_id: &str,
        held_from: i64,
        since: i64,
        sender_timestamps: &HashMap<String, i64>,
        gap_from: Option<i64>,
    ) -> bool {
        if (sender_timestamps.is_empty() && since.saturating_add(1) < held_from)
            || sender_timestamps.values().any(|ts| *ts < held_from)
            || gap_from.is_some_and(|from| from < held_from)
        {
            return true;
        }
        if sender_timestamps.is_empty() {
            return false;
        }
        // Unreadable: answered as reaching it, never as the whole channel.
        self.channel_sender_spans(server_id, channel_id)
            .map_or(true, |spans| spans.iter().any(|s| s.last >= held_from && !sender_timestamps.contains_key(&s.sender)))
    }

    /// Every sender a page vouching only from `held_from` serves, named from there on
    /// (an ask naming none, from past its `since`): what a holder lacking part of a
    /// channel serves, whatever the ask named.
    pub fn channel_marks_from(
        &self,
        server_id: &str,
        channel_id: &str,
        held_from: i64,
        since: i64,
        sender_timestamps: &HashMap<String, i64>,
    ) -> Result<HashMap<String, i64>, String> {
        let unnamed = if sender_timestamps.is_empty() { since.saturating_add(1).max(held_from) } else { held_from };
        // Every sender we hold is named, or the query serves it in full from below.
        Ok(self
            .channel_sender_spans(server_id, channel_id)?
            .into_iter()
            .map(|s| {
                let from = sender_timestamps.get(&s.sender).copied().unwrap_or(unnamed).max(held_from);
                (s.sender, from)
            })
            .collect())
    }

    /// What this device lacks of a channel whose history here begins later than the
    /// channel's: every sender's rows from `from` up to `below`.
    pub fn channel_hole(&self, server_id: &str, channel_id: &str) -> Option<ChannelHole> {
        self.conn
            .prepare_cached("SELECT below, COALESCE(all_from, 0) FROM channel_sync_holes WHERE server_id = ?1 AND channel_id = ?2")
            .and_then(|mut s| s.query_row(params![server_id, channel_id], |r| Ok(ChannelHole { below: r.get(0)?, from: r.get(1)? })))
            .ok()
    }

    /// A holder served the hole whole.
    pub fn close_channel_hole(&self, server_id: &str, channel_id: &str) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM channel_sync_holes WHERE server_id = ?1 AND channel_id = ?2", params![server_id, channel_id])
            .map(|_| ())
            .map_err(|e| format!("Failed to close a channel hole: {e}"))
    }

    /// Whether any row of a channel is held, for [`Self::note_held_page`].
    pub fn channel_holds_rows(&self, server_id: &str, channel_id: &str) -> Result<bool, String> {
        self.conn
            .prepare_cached("SELECT EXISTS (SELECT 1 FROM channel_messages WHERE server_id = ?1 AND channel_id = ?2)")
            .and_then(|mut s| s.query_row(params![server_id, channel_id], |r| r.get(0)))
            .map_err(|e| format!("Failed to read a channel: {e}"))
    }

    /// A page of our own ask that vouched only from `held`, in the transaction landing its
    /// rows (`landed` = the stamps of the rows ingest accepted), before any watermark
    /// moves. Only a device that held no row of the channel before the page and never
    /// cleared it opens a hole; one holding anything judges what it lacks by the gap
    /// digest, as for any watermark a live post moved, and keeps vouching for all it
    /// holds. A page of the hole's own ask narrows it to the oldest row it landed.
    #[allow(clippy::too_many_arguments)]
    pub fn note_held_page(
        &self,
        server_id: &str,
        channel_id: &str,
        held: i64,
        held_rows_before: bool,
        landed: &[i64],
        answers_hole: bool,
        now_ms: i64,
    ) -> Result<(), String> {
        if self.channel_floor(server_id, channel_id).is_some() {
            return Ok(());
        }
        let held = if held == i64::MAX { now_ms } else { held.min(now_ms.saturating_add(CLEAR_SKEW_MS)) };
        let first = landed.iter().copied().filter(|ts| *ts >= held).min();
        let err = |e: rusqlite::Error| format!("Failed to note a channel hole: {e}");
        match self.channel_hole(server_id, channel_id) {
            Some(hole) if answers_hole => {
                let Some(first) = first.filter(|f| *f < hole.below) else { return Ok(()) };
                self.conn
                    .execute(
                        "UPDATE channel_sync_holes SET below = ?3 WHERE server_id = ?1 AND channel_id = ?2",
                        params![server_id, channel_id, first],
                    )
                    .map_err(err)?;
                self.drop_filled_hole(server_id, channel_id)
            }
            Some(_) => Ok(()),
            None if held_rows_before => Ok(()),
            None => self
                .conn
                .execute(
                    "INSERT INTO channel_sync_holes (server_id, channel_id, below, all_from) VALUES (?1, ?2, ?3, 0)",
                    params![server_id, channel_id, first.unwrap_or(held)],
                )
                .map(|_| ())
                .map_err(err),
        }
    }

    /// A page of the hole's own ask that vouched for all it served ends at `end`: below
    /// it the hole is filled, so an ask cut short later starts there, not again from below.
    pub fn raise_channel_hole(&self, server_id: &str, channel_id: &str, end: i64) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE channel_sync_holes SET all_from = MAX(COALESCE(all_from, 0), ?3) WHERE server_id = ?1 AND channel_id = ?2",
                params![server_id, channel_id, end],
            )
            .map_err(|e| format!("Failed to raise a channel hole: {e}"))?;
        self.drop_filled_hole(server_id, channel_id)
    }

    fn drop_filled_hole(&self, server_id: &str, channel_id: &str) -> Result<(), String> {
        self.conn
            .execute(
                "DELETE FROM channel_sync_holes WHERE server_id = ?1 AND channel_id = ?2 AND COALESCE(all_from, 0) >= below",
                params![server_id, channel_id],
            )
            .map(|_| ())
            .map_err(|e| format!("Failed to close a channel hole: {e}"))
    }

    /// Whether a channel has a hole to ask for.
    pub fn channel_hole_open(&self, server_id: &str, channel_id: &str) -> bool {
        self.conn
            .prepare_cached("SELECT EXISTS (SELECT 1 FROM channel_sync_holes WHERE server_id = ?1 AND channel_id = ?2)")
            .and_then(|mut s| s.query_row(params![server_id, channel_id], |r| r.get(0)))
            .unwrap_or(false)
    }

    /// Whether what this device holds of a channel starts later than the channel did for
    /// a reason other than our own clear (a late join, a copy), until the rest arrives.
    pub fn channel_history_begins_later(&self, server_id: &str, channel_id: &str) -> bool {
        self.channel_hole_open(server_id, channel_id) && self.channel_floor(server_id, channel_id).is_none()
    }

    /// The senders a catch-up ask of a channel names, with their newest rows. A device
    /// that cleared the channel counts what it cleared as held, so it asks exactly as it
    /// would have without the clear; a device whose history begins later names only the
    /// rows it vouches for (`channel_held_from`), so its asks say no more than its answers.
    fn channel_ask_spans(&self, server_id: &str, channel_id: &str) -> Result<HashMap<String, i64>, String> {
        let held = self.channel_held_from(server_id, channel_id);
        let counted = held.is_some() && self.counts_cleared(server_id, channel_id);
        let mut spans: HashMap<String, i64> = self
            .channel_sender_spans(server_id, channel_id)?
            .into_iter()
            .filter(|s| counted || held.is_none_or(|from| s.last >= from))
            .map(|s| (s.sender, s.last))
            .collect();
        if counted {
            for (sender, last) in self.cleared_senders(server_id, channel_id)? {
                let newest = spans.entry(sender).or_insert(last);
                *newest = (*newest).max(last);
            }
        }
        Ok(spans)
    }

    /// The `since` of a catch-up ask: the newest row it names; with none, 0 (everything),
    /// or our clock for a channel we cleared, which wants nothing it would refuse.
    pub fn channel_ask_since(&self, server_id: &str, channel_id: &str) -> i64 {
        self.channel_ask_spans(server_id, channel_id)
            .ok()
            .and_then(|spans| spans.into_values().max())
            .unwrap_or_else(|| if self.channel_floor(server_id, channel_id).is_some() { crate::node::frame_auth::now_ms() } else { 0 })
    }

    /// Where a catch-up's next page may start: below it this device lacks the channel (a
    /// hole) or never held it (the oldest row a clear took), `None` for neither.
    pub fn channel_page_start(&self, server_id: &str, channel_id: &str) -> Option<i64> {
        let held = self.channel_held_from(server_id, channel_id)?;
        if self.counts_cleared(server_id, channel_id) {
            self.cleared_history_from(server_id, channel_id)
        } else {
            Some(held)
        }
    }

    /// Whether a clear of this channel took rows its asks still count as held.
    fn counts_cleared(&self, server_id: &str, channel_id: &str) -> bool {
        self.conn
            .prepare_cached("SELECT EXISTS (SELECT 1 FROM channel_cleared_senders WHERE server_id = ?1 AND channel_id = ?2)")
            .and_then(|mut s| s.query_row(params![server_id, channel_id], |r| r.get(0)))
            .unwrap_or(false)
    }

    /// The oldest row a clear of this channel took.
    fn cleared_history_from(&self, server_id: &str, channel_id: &str) -> Option<i64> {
        self.conn
            .prepare_cached("SELECT history_from FROM channel_floors WHERE server_id = ?1 AND channel_id = ?2")
            .and_then(|mut s| s.query_row(params![server_id, channel_id], |r| r.get(0)))
            .unwrap_or(None)
    }

    /// Every sender a clear of this channel took rows of, with its newest one.
    fn cleared_senders(&self, server_id: &str, channel_id: &str) -> Result<Vec<(String, i64)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT sender_id, last_ts FROM channel_cleared_senders WHERE server_id = ?1 AND channel_id = ?2")
            .map_err(|e| format!("Failed to read the cleared senders: {e}"))?;
        let rows = stmt
            .query_map(params![server_id, channel_id], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(|e| format!("Failed to read the cleared senders: {e}"))?;
        collect_rows(rows, "cleared senders")
    }

    /// Every sender of a channel we hold a row of.
    pub fn channel_sender_ids(&self, server_id: &str, channel_id: &str) -> Result<Vec<String>, String> {
        Ok(self.channel_sender_spans(server_id, channel_id)?.into_iter().map(|s| s.sender).collect())
    }

    /// Where this device cleared a channel's history, if it did.
    pub fn channel_floor(&self, server_id: &str, channel_id: &str) -> Option<i64> {
        self.conn
            .prepare_cached("SELECT floor_ts FROM channel_floors WHERE server_id = ?1 AND channel_id = ?2")
            .and_then(|mut s| s.query_row(params![server_id, channel_id], |r| r.get(0)))
            .ok()
    }

    /// Latest timestamp of the LOCAL user's own channel messages (`is_mine = 1`, so it
    /// stays correct across linked devices), for the send-side slow-mode gate. `None` on
    /// query failure: slow mode fails open rather than blocking sends on a DB error.
    pub fn latest_own_channel_ts(&self, server_id: &str, channel_id: &str) -> Option<i64> {
        self.conn
            .query_row(
                "SELECT MAX(timestamp) FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND is_mine = 1",
                params![server_id, channel_id],
                |row| row.get::<_, Option<i64>>(0),
            )
            .ok()
            .flatten()
    }

    /// Highest chat send-stamp across DMs and channels, seeding the Lamport clock at
    /// node start so a restart cannot mint stamps below stored ones from a peer whose
    /// clock runs ahead of ours.
    pub fn max_chat_stamp_us(&self) -> i64 {
        let q = |sql: &str| {
            self.conn
                .query_row(sql, [], |row| row.get::<_, Option<i64>>(0))
                .ok()
                .flatten()
                .unwrap_or(0)
        };
        q("SELECT MAX(COALESCE(order_us, timestamp * 1000)) FROM messages")
            .max(q("SELECT MAX(COALESCE(order_us, timestamp * 1000)) FROM channel_messages"))
    }

    /// Whether `sender_id` already has a channel message in the open interval
    /// (`from_ts`, `to_ts`), for the receive-side slow-mode gate.
    pub fn channel_sender_has_msg_in_range(
        &self,
        server_id: &str,
        channel_id: &str,
        sender_id: &str,
        from_ts: i64,
        to_ts: i64,
    ) -> bool {
        self.conn
            .query_row(
                "SELECT EXISTS(
                     SELECT 1 FROM channel_messages
                     WHERE server_id = ?1 AND channel_id = ?2 AND sender_id = ?3
                       AND timestamp > ?4 AND timestamp < ?5
                 )",
                params![server_id, channel_id, sender_id, from_ts, to_ts],
                |row| row.get::<_, bool>(0),
            )
            .unwrap_or(false)
    }

    /// Channel messages newer than a timestamp, for sync responses. Hidden rows
    /// included: evidence must sync.
    pub fn get_channel_messages_since(
        &self,
        server_id: &str,
        channel_id: &str,
        since_timestamp: i64,
        limit: i32,
    ) -> Result<Vec<StoredChannelMessage>, String> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "SELECT {CHANNEL_MSG_COLS}
                 FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND (timestamp > ?3 OR updated_at > ?3)
                 ORDER BY timestamp ASC
                 LIMIT ?4",
            ))
            .map_err(|e| format!("Failed to prepare messages_since query: {e}"))?;

        let rows = stmt
            .query_map(
                params![server_id, channel_id, since_timestamp, limit],
                channel_message_from_row,
            )
            .map_err(|e| format!("Failed to query messages_since: {e}"))?;

        collect_rows(rows, "messages_since")
    }

    /// A page of a public channel for the guest browser, newest first then
    /// reversed. Deleted rows never leave: their text is evidence for members
    /// (Rat Files), not for a stranger who was never there.
    pub fn get_visible_channel_messages_before(
        &self,
        server_id: &str,
        channel_id: &str,
        before_timestamp: i64,
        limit: i32,
    ) -> Result<Vec<StoredChannelMessage>, String> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "SELECT {CHANNEL_MSG_COLS}
                 FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND timestamp < ?3
                   AND hidden_at IS NULL
                 ORDER BY timestamp DESC
                 LIMIT ?4",
            ))
            .map_err(|e| format!("Failed to prepare messages_before query: {e}"))?;

        let rows = stmt
            .query_map(
                params![server_id, channel_id, before_timestamp, limit],
                channel_message_from_row,
            )
            .map_err(|e| format!("Failed to query messages_before: {e}"))?;

        let mut messages = collect_rows(rows, "messages_before")?;
        messages.reverse();
        Ok(messages)
    }

    /// Total message count for a channel (for health check comparison).
    /// Count all DM messages for a peer (including hidden/deleted). Used by archive sidebar.
    pub fn count_dm_messages(&self, peer_id: &str) -> u32 {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM messages WHERE peer_id = ?1",
                params![peer_id],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as u32
    }

    /// Count all visible DM messages across every peer, the Home card's multi-device
    /// sync-comparison number: DMs fully converge across a person's devices, unlike
    /// lazily-paged channel messages. Hidden rows are excluded because deletion
    /// tombstones are per-device and would skew the comparison.
    pub fn count_all_dm_messages(&self) -> u32 {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM messages WHERE hidden_at IS NULL",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as u32
    }

    pub fn count_channel_messages(
        &self,
        server_id: &str,
        channel_id: &str,
    ) -> u32 {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM channel_messages WHERE server_id = ?1 AND channel_id = ?2",
                params![server_id, channel_id],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as u32
    }

    /// Count channel messages newer than a given timestamp (for sync progress indication).
    pub fn count_channel_messages_since(
        &self,
        server_id: &str,
        channel_id: &str,
        since_timestamp: i64,
    ) -> Result<u32, String> {
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND timestamp > ?3",
                params![server_id, channel_id, since_timestamp],
                |row| row.get(0),
            )
            .map_err(|e| format!("Failed to count messages: {e}"))?;
        Ok(count as u32)
    }

    /// Delete DM messages older than `before_timestamp` for a specific peer.
    /// Returns the number of deleted rows.
    pub fn prune_dm_messages_before(&self, peer_id: &str, before_timestamp: i64) -> Result<u32, String> {
        let deleted = self.conn
            .execute(
                "DELETE FROM messages WHERE peer_id = ?1 AND timestamp < ?2",
                params![peer_id, before_timestamp],
            )
            .map_err(|e| format!("Failed to prune DM messages: {e}"))?;
        Ok(deleted as u32)
    }

    /// Delete channel messages in a time range for a server, so retention is
    /// forward-only: only messages created after the policy was set are pruned.
    pub fn prune_channel_messages_in_range(&self, server_id: &str, since: i64, before: i64) -> Result<u32, String> {
        let deleted = self.conn
            .execute(
                "DELETE FROM channel_messages WHERE server_id = ?1 AND timestamp >= ?2 AND timestamp < ?3",
                params![server_id, since, before],
            )
            .map_err(|e| format!("Failed to prune channel messages: {e}"))?;
        Ok(deleted as u32)
    }

    /// Count unread DM messages: those STRICTLY NEWER in MILLISECONDS than the
    /// `last_seen_message_id` row.
    ///
    /// Neither alternative works. By rowid, a sync backfill inserts older-timestamped
    /// rows with HIGHER rowids and they count forever, since the seen pointer is the
    /// newest-by-time message. By the full (timestamp, order_us, id) tuple, Dart marks
    /// seen from a millisecond-sorted `.last`, which in a same-millisecond burst may
    /// not be the tuple-max row, leaving the tail of the burst unread until the user
    /// sent something. Same-millisecond messages render together, so treating the whole
    /// millisecond as seen matches what the user saw. A missing seen row returns 0,
    /// never a count-everything degradation.
    ///
    /// The floor is the LATEST of three marks (#80): the seen row, the
    /// `seen_ts:` a sibling reported (it may name a row not backfilled here
    /// yet), and our own newest message, because being last to speak means the
    /// conversation was read. A pointer to nothing and no other mark stays 0.
    pub fn count_unread_dm(&self, peer_id: &str, last_seen_message_id: &str) -> u32 {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM messages m
                 WHERE m.peer_id = ?1
                   AND m.hidden_at IS NULL AND m.is_mine = 0
                   AND m.timestamp > (SELECT MAX(v) FROM (
                       SELECT s.timestamp AS v FROM messages s
                         WHERE s.peer_id = ?1 AND s.message_id = ?2
                       UNION ALL SELECT CAST(value AS INTEGER) FROM app_settings WHERE key = ?3
                       UNION ALL SELECT MAX(o.timestamp) FROM messages o
                         WHERE o.peer_id = ?1 AND o.is_mine = 1))",
                params![peer_id, last_seen_message_id, format!("seen_ts:dm:{peer_id}")],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as u32
    }

    /// Count unread channel messages strictly newer in milliseconds than the seen row;
    /// see [`Self::count_unread_dm`] for why.
    pub fn count_unread_channel(
        &self,
        server_id: &str,
        channel_id: &str,
        last_seen_message_id: &str,
    ) -> u32 {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM channel_messages m
                 WHERE m.server_id = ?1 AND m.channel_id = ?2
                   AND m.hidden_at IS NULL AND m.is_mine = 0
                   AND m.timestamp > (SELECT MAX(v) FROM (
                       SELECT s.timestamp AS v FROM channel_messages s
                         WHERE s.server_id = ?1 AND s.channel_id = ?2 AND s.message_id = ?3
                       UNION ALL SELECT CAST(value AS INTEGER) FROM app_settings WHERE key = ?4
                       UNION ALL SELECT MAX(o.timestamp) FROM channel_messages o
                         WHERE o.server_id = ?1 AND o.channel_id = ?2 AND o.is_mine = 1
                       UNION ALL SELECT COALESCE(c.exact_from, c.floor_ts) FROM channel_floors c
                         WHERE c.server_id = ?1 AND c.channel_id = ?2))",
                params![server_id, channel_id, last_seen_message_id,
                        format!("seen_ts:ch:{server_id}:{channel_id}")],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as u32
    }

    /// Count ALL non-hidden messages from others in a DM (for never-opened DMs).
    pub fn count_all_unread_dm(&self, peer_id: &str) -> u32 {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM messages m
                 WHERE m.peer_id = ?1 AND m.hidden_at IS NULL AND m.is_mine = 0
                   AND m.timestamp > COALESCE((SELECT MAX(v) FROM (
                       SELECT CAST(value AS INTEGER) AS v FROM app_settings WHERE key = ?2
                       UNION ALL SELECT MAX(o.timestamp) FROM messages o
                         WHERE o.peer_id = ?1 AND o.is_mine = 1)), -1)",
                params![peer_id, format!("seen_ts:dm:{peer_id}")],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as u32
    }

    /// Count ALL non-hidden messages from others in a channel (for never-opened channels).
    pub fn count_all_unread_channel(&self, server_id: &str, channel_id: &str) -> u32 {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM channel_messages m
                 WHERE m.server_id = ?1 AND m.channel_id = ?2
                   AND m.hidden_at IS NULL AND m.is_mine = 0
                   AND m.timestamp > COALESCE((SELECT MAX(v) FROM (
                       SELECT CAST(value AS INTEGER) AS v FROM app_settings WHERE key = ?3
                       UNION ALL SELECT MAX(o.timestamp) FROM channel_messages o
                         WHERE o.server_id = ?1 AND o.channel_id = ?2 AND o.is_mine = 1)), -1)",
                params![server_id, channel_id, format!("seen_ts:ch:{server_id}:{channel_id}")],
                |row| row.get::<_, i64>(0),
            )
            .unwrap_or(0) as u32
    }

    /// Count unread and mention-containing messages for a channel. A message counts as
    /// a mention if it contains any pattern in `mention_patterns` or has a reply_to.
    pub fn count_unread_channel_with_mentions(
        &self,
        server_id: &str,
        channel_id: &str,
        last_seen_message_id: Option<&str>,
        mention_patterns: &[String],
    ) -> (u32, u32) {
        let mut mention_clauses = Vec::new();
        let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
        param_values.push(Box::new(server_id.to_string()));
        param_values.push(Box::new(channel_id.to_string()));

        param_values.push(Box::new(format!("seen_ts:ch:{server_id}:{channel_id}")));
        let mut param_idx = 4;
        // The same three-mark floor as `count_unread_channel`; with no pointer the
        // sibling mark and our own newest post still floor, else everything counts.
        let seen_filter = if let Some(mid) = last_seen_message_id {
            param_values.push(Box::new(mid.to_string()));
            let f = format!(
                "AND timestamp > (SELECT MAX(v) FROM (
                     SELECT s.timestamp AS v FROM channel_messages s
                       WHERE s.server_id = ?1 AND s.channel_id = ?2 AND s.message_id = ?{param_idx}
                     UNION ALL SELECT CAST(value AS INTEGER) FROM app_settings WHERE key = ?3
                     UNION ALL SELECT MAX(o.timestamp) FROM channel_messages o
                       WHERE o.server_id = ?1 AND o.channel_id = ?2 AND o.is_mine = 1
                     UNION ALL SELECT COALESCE(c.exact_from, c.floor_ts) FROM channel_floors c
                       WHERE c.server_id = ?1 AND c.channel_id = ?2))"
            );
            param_idx += 1;
            f
        } else {
            "AND timestamp > COALESCE((SELECT MAX(v) FROM (
                 SELECT CAST(value AS INTEGER) AS v FROM app_settings WHERE key = ?3
                 UNION ALL SELECT MAX(o.timestamp) FROM channel_messages o
                   WHERE o.server_id = ?1 AND o.channel_id = ?2 AND o.is_mine = 1
                 UNION ALL SELECT COALESCE(c.exact_from, c.floor_ts) FROM channel_floors c
                   WHERE c.server_id = ?1 AND c.channel_id = ?2)), -1)"
                .to_string()
        };

        for pattern in mention_patterns {
            mention_clauses.push(format!("text LIKE ?{param_idx}"));
            param_values.push(Box::new(format!("%{pattern}%")));
            param_idx += 1;
        }
        // Any reply counts as a mention, matching the live path.
        mention_clauses.push("reply_to_mid IS NOT NULL".to_string());

        let mention_expr = mention_clauses.join(" OR ");
        let sql = format!(
            "SELECT COUNT(*), COUNT(CASE WHEN ({mention_expr}) THEN 1 END)
             FROM channel_messages
             WHERE server_id = ?1 AND channel_id = ?2 {seen_filter}
               AND hidden_at IS NULL AND is_mine = 0"
        );

        let params_refs: Vec<&dyn rusqlite::types::ToSql> =
            param_values.iter().map(|p| p.as_ref()).collect();
        self.conn
            .query_row(&sql, params_refs.as_slice(), |row| {
                Ok((
                    row.get::<_, i64>(0).unwrap_or(0) as u32,
                    row.get::<_, i64>(1).unwrap_or(0) as u32,
                ))
            })
            .unwrap_or((0, 0))
    }

    /// Get all distinct peer IDs that have DM messages.
    pub fn get_dm_peer_ids(&self) -> Vec<String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT DISTINCT peer_id FROM messages")
            .unwrap();
        let rows = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap();
        rows.filter_map(|r| r.ok()).collect()
    }

    /// Latest timestamp per sender for a channel, as `{ sender_id -> max_timestamp }`,
    /// minus the lookback, for the senders `channel_ask_spans` names.
    pub fn get_per_sender_timestamps(
        &self,
        server_id: &str,
        channel_id: &str,
    ) -> Result<HashMap<String, i64>, String> {
        // Lookback overlap: a MAX(timestamp) watermark permanently skips a message MISSED
        // while a newer one arrived, so ask from `watermark - LOOKBACK`. The overlap is
        // deduplicated by message_id on receipt.
        Ok(self
            .channel_ask_spans(server_id, channel_id)?
            .into_iter()
            .map(|(sender, last)| (sender, (last - SYNC_LOOKBACK_MS).max(0)))
            .collect())
    }

    /// Every sender of one channel with its oldest and newest row. Two index seeks per
    /// sender on `idx_channel_msgs_sender_ts`, never a pass over the channel's rows:
    /// sync asks this once per page.
    fn channel_sender_spans(&self, server_id: &str, channel_id: &str) -> Result<Vec<SenderSpan>, String> {
        let mut stmt = self
            .conn
            .prepare_cached(
                "WITH RECURSIVE senders(id) AS (
                     SELECT (SELECT MIN(sender_id) FROM channel_messages
                             WHERE server_id = ?1 AND channel_id = ?2)
                     UNION ALL
                     SELECT (SELECT MIN(sender_id) FROM channel_messages
                             WHERE server_id = ?1 AND channel_id = ?2 AND sender_id > senders.id)
                     FROM senders WHERE senders.id IS NOT NULL
                 )
                 SELECT id,
                        (SELECT MIN(timestamp) FROM channel_messages
                         WHERE server_id = ?1 AND channel_id = ?2 AND sender_id = senders.id),
                        (SELECT MAX(timestamp) FROM channel_messages
                         WHERE server_id = ?1 AND channel_id = ?2 AND sender_id = senders.id)
                 FROM senders WHERE id IS NOT NULL",
            )
            .map_err(|e| format!("Failed to prepare channel senders query: {e}"))?;
        let rows = stmt
            .query_map(params![server_id, channel_id], |row| {
                Ok(SenderSpan { sender: row.get(0)?, first: row.get(1)?, last: row.get(2)? })
            })
            .map_err(|e| format!("Failed to query channel senders: {e}"))?;
        collect_rows(rows, "channel senders")
    }

    /// Channel messages filling gaps from per-sender timestamps: known senders from
    /// their timestamp (inclusive, to catch same-millisecond messages), unknown senders
    /// in full, oldest first.
    ///
    /// Senders whose rows all come before the rest are read one by one (up to `limit`
    /// rows each), the others in one pass of the timestamp index from their first
    /// qualifying row. For the asks sync sends (a next page from where the last ended, a
    /// catch-up from recent watermarks) that reads about `limit` rows however deep in the
    /// history it starts; an ask naming a watermark far behind the others walks every
    /// row in between, as every page did before.
    pub fn get_channel_messages_since_per_sender(
        &self,
        server_id: &str,
        channel_id: &str,
        sender_timestamps: &HashMap<String, i64>,
        limit: i32,
    ) -> Result<Vec<StoredChannelMessage>, String> {
        if sender_timestamps.is_empty() {
            // No known senders — return everything.
            return self.get_channel_messages_since(server_id, channel_id, 0, limit);
        }
        let senders = self.channel_sender_spans(server_id, channel_id)?;
        let mut spans = self.qualifying_spans(server_id, channel_id, &senders, sender_timestamps)?;
        if spans.is_empty() || limit <= 0 {
            return Ok(Vec::new());
        }
        spans.sort_by_key(|s| s.first);
        let split = early_sender_split(&spans);
        let scan_from = spans[split].first;

        let mut rows = Vec::new();
        let mut early = self
            .conn
            .prepare_cached(&format!(
                "SELECT {CHANNEL_MSG_COLS} FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND sender_id = ?3 AND timestamp >= ?4
                 ORDER BY timestamp ASC, COALESCE(order_us, timestamp * 1000) ASC, message_id ASC
                 LIMIT ?5",
            ))
            .map_err(|e| format!("Failed to prepare per_sender early query: {e}"))?;
        for span in &spans[..split] {
            let found = early
                .query_map(params![server_id, channel_id, span.sender, span.first, limit], channel_message_from_row)
                .map_err(|e| format!("Failed to query per_sender early: {e}"))?;
            rows.extend(collect_rows(found, "per_sender early")?);
        }

        // From `scan_from` on, a row is out only when its sender is known and the row is
        // older than that sender's watermark. Watermarks of senders this channel does not
        // hold name no row.
        let behind: Vec<(&String, i64)> = senders
            .iter()
            .filter_map(|s| sender_timestamps.get(&s.sender).map(|ts| (&s.sender, *ts)))
            .filter(|(_, ts)| *ts > scan_from)
            .collect();
        let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> =
            vec![Box::new(server_id.to_string()), Box::new(channel_id.to_string()), Box::new(scan_from)];
        let mut excluded = Vec::new();
        for (sender, ts) in &behind {
            excluded.push(format!("(sender_id = ?{} AND timestamp < ?{})", param_values.len() + 1, param_values.len() + 2));
            param_values.push(Box::new((*sender).clone()));
            param_values.push(Box::new(*ts));
        }
        let exclusion = if excluded.is_empty() { String::new() } else { format!(" AND NOT ({})", excluded.join(" OR ")) };
        let sql = format!(
            "SELECT {CHANNEL_MSG_COLS}
             FROM channel_messages
             WHERE server_id = ?1 AND channel_id = ?2 AND timestamp >= ?3{exclusion}
             ORDER BY timestamp ASC, COALESCE(order_us, timestamp * 1000) ASC, message_id ASC
             LIMIT ?{}",
            param_values.len() + 1,
        );
        param_values.push(Box::new(limit));
        let params_ref: Vec<&dyn rusqlite::types::ToSql> = param_values.iter().map(|p| p.as_ref()).collect();
        let mut stmt = self.conn.prepare(&sql)
            .map_err(|e| format!("Failed to prepare per_sender_since query: {e}"))?;
        let found = stmt
            .query_map(params_ref.as_slice(), channel_message_from_row)
            .map_err(|e| format!("Failed to query per_sender_since: {e}"))?;
        rows.extend(collect_rows(found, "per_sender")?);

        rows.sort_by(|a, b| {
            let key = |m: &StoredChannelMessage| (m.timestamp, m.order_us.unwrap_or(m.timestamp * 1000));
            key(a).cmp(&key(b)).then_with(|| a.message_id.cmp(&b.message_id)).then_with(|| a.id.cmp(&b.id))
        });
        rows.truncate(limit as usize);
        Ok(rows)
    }

    /// Senders with a row a per-sender ask serves, each with the timestamp of its first
    /// such row and of its newest row.
    fn qualifying_spans(
        &self,
        server_id: &str,
        channel_id: &str,
        senders: &[SenderSpan],
        sender_timestamps: &HashMap<String, i64>,
    ) -> Result<Vec<SenderSpan>, String> {
        let mut first_from = self
            .conn
            .prepare_cached(
                "SELECT MIN(timestamp) FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND sender_id = ?3 AND timestamp >= ?4",
            )
            .map_err(|e| format!("Failed to prepare per_sender first query: {e}"))?;
        let mut spans = Vec::new();
        for span in senders {
            let mut span = span.clone();
            if let Some(since) = sender_timestamps.get(&span.sender) {
                let first: Option<i64> = first_from
                    .query_row(params![server_id, channel_id, span.sender, since], |row| row.get(0))
                    .map_err(|e| format!("Failed to query per_sender first: {e}"))?;
                let Some(first) = first else { continue };
                span.first = first;
            }
            spans.push(span);
        }
        Ok(spans)
    }

    /// Count channel messages that would be returned by per-sender sync.
    pub fn count_channel_messages_since_per_sender(
        &self,
        server_id: &str,
        channel_id: &str,
        sender_timestamps: &HashMap<String, i64>,
    ) -> Result<u32, String> {
        if sender_timestamps.is_empty() {
            return self.count_channel_messages_since(server_id, channel_id, 0);
        }
        let mut count_from = self
            .conn
            .prepare_cached(
                "SELECT COUNT(*) FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2 AND sender_id = ?3 AND timestamp >= ?4",
            )
            .map_err(|e| format!("Failed to prepare per_sender count: {e}"))?;
        let mut total = 0i64;
        let senders = self.channel_sender_spans(server_id, channel_id)?;
        for span in self.qualifying_spans(server_id, channel_id, &senders, sender_timestamps)? {
            let n: i64 = count_from
                .query_row(params![server_id, channel_id, span.sender, span.first], |row| row.get(0))
                .map_err(|e| format!("Failed to count per_sender messages: {e}"))?;
            total += n;
        }
        Ok(total as u32)
    }

    /// Load HLC state, if saved.
    pub fn load_hlc_state(&self) -> Result<Option<(u64, u32, String)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT physical_ms, counter, actor FROM hlc_state WHERE id = 1")
            .map_err(|e| format!("Failed to prepare hlc_state query: {e}"))?;
        let mut rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)? as u64,
                    row.get::<_, i64>(1)? as u32,
                    row.get::<_, String>(2)?,
                ))
            })
            .map_err(|e| format!("Failed to query hlc_state: {e}"))?;
        match rows.next() {
            Some(Ok(tuple)) => Ok(Some(tuple)),
            Some(Err(e)) => Err(format!("Failed to read hlc_state row: {e}")),
            None => Ok(None),
        }
    }

    // ── MLS Identity Persistence ──

    /// Write one MLS save: the identity, then the scopes it empties, then its rows. A
    /// savepoint inside the caller's transaction (or its own, outside one) makes the save
    /// land whole or not at all.
    pub fn save_mls_state(&self, save: &crate::crypto::mls_storage::MlsSave) -> Result<(), String> {
        let fail = |e: rusqlite::Error| format!("Failed to save MLS state: {e}");
        self.conn.execute_batch("SAVEPOINT mls_save").map_err(fail)?;
        let written = self.write_mls_save(save);
        let end = if written.is_ok() { "RELEASE mls_save" } else { "ROLLBACK TO mls_save; RELEASE mls_save" };
        self.conn.execute_batch(end).map_err(fail)?;
        written
    }

    fn write_mls_save(&self, save: &crate::crypto::mls_storage::MlsSave) -> Result<(), String> {
        let fail = |e: rusqlite::Error| format!("Failed to save MLS state: {e}");
        self.conn
            .execute(
                "INSERT INTO mls_identity (id, signer_data, credential_data, storage_data)
                 VALUES (1, ?1, ?2, NULL)
                 ON CONFLICT(id) DO UPDATE SET
                    signer_data = excluded.signer_data,
                    credential_data = excluded.credential_data,
                    storage_data = CASE WHEN ?3 THEN NULL ELSE mls_identity.storage_data END",
                params![save.signer, save.credential, save.drop_blob],
            )
            .map_err(fail)?;
        if let Some(keep) = &save.retain_only {
            let stored: Vec<String> = {
                let mut stmt = self.conn.prepare_cached("SELECT DISTINCT scope FROM mls_storage").map_err(fail)?;
                let rows = stmt.query_map([], |row| row.get(0)).map_err(fail)?;
                rows.collect::<Result<_, _>>().map_err(fail)?
            };
            for scope in stored.iter().filter(|s| !keep.contains(s)) {
                self.conn.execute("DELETE FROM mls_storage WHERE scope = ?1", params![scope]).map_err(fail)?;
            }
        }
        for scope in &save.cleared {
            self.conn.execute("DELETE FROM mls_storage WHERE scope = ?1", params![scope]).map_err(fail)?;
        }
        let mut put = self
            .conn
            .prepare_cached("INSERT OR REPLACE INTO mls_storage (scope, k, v) VALUES (?1, ?2, ?3)")
            .map_err(fail)?;
        let mut del = self.conn.prepare_cached("DELETE FROM mls_storage WHERE scope = ?1 AND k = ?2").map_err(fail)?;
        for (scope, k, v) in &save.rows {
            match v {
                Some(v) => put.execute(params![scope, k, v]).map_err(fail)?,
                None => del.execute(params![scope, k]).map_err(fail)?,
            };
        }
        Ok(())
    }

    /// Every stored MLS row, `(scope, key, value)`.
    pub fn load_mls_rows(&self) -> Result<Vec<(String, Vec<u8>, Vec<u8>)>, String> {
        Ok(self.load_mls_rows_in(|_| true)?.0)
    }

    /// The stored MLS rows of the scopes `wanted` keeps, and the names of the others,
    /// whose values are never read (a push fetch loads one server's past epochs).
    pub fn load_mls_rows_in(
        &self,
        wanted: impl Fn(&str) -> bool,
    ) -> Result<(Vec<(String, Vec<u8>, Vec<u8>)>, Vec<String>), String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT scope, k, v FROM mls_storage")
            .map_err(|e| format!("Failed to prepare mls_storage query: {e}"))?;
        let mut rows = stmt.query([]).map_err(|e| format!("Failed to query mls_storage: {e}"))?;
        let (mut kept, mut others) = (Vec::new(), std::collections::BTreeSet::new());
        let fail = |e: rusqlite::Error| format!("Failed to read mls_storage row: {e}");
        while let Some(row) = rows.next().map_err(fail)? {
            let scope: String = row.get(0).map_err(fail)?;
            if wanted(&scope) {
                kept.push((scope, row.get(1).map_err(fail)?, row.get(2).map_err(fail)?));
            } else {
                others.insert(scope);
            }
        }
        Ok((kept, others.into_iter().collect()))
    }

    /// TEST-ONLY: run raw SQL on this connection.
    #[cfg(test)]
    pub fn conn_execute_for_test(&self, sql: &str) {
        self.conn.execute_batch(sql).unwrap();
    }

    /// TEST-ONLY: lose every stored MLS row.
    #[cfg(test)]
    pub fn delete_mls_rows_for_test(&self) {
        self.conn.execute_batch("DELETE FROM mls_storage;").unwrap();
    }

    /// TEST-ONLY: back to the shape a 0.12 build left on disk.
    #[cfg(test)]
    pub fn drop_mls_rows_table_for_test(&self) {
        self.conn.execute_batch("DROP TABLE mls_storage; PRAGMA wal_checkpoint(TRUNCATE);").unwrap();
    }

    /// TEST-ONLY: an MLS identity as 0.12 stored it, the whole store in one blob.
    #[cfg(test)]
    pub fn save_mls_identity(
        &self,
        signer_data: &[u8],
        credential_data: &[u8],
        storage_data: &[u8],
    ) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO mls_identity (id, signer_data, credential_data, storage_data)
                 VALUES (1, ?1, ?2, ?3)
                 ON CONFLICT(id) DO UPDATE SET
                    signer_data = excluded.signer_data,
                    credential_data = excluded.credential_data,
                    storage_data = excluded.storage_data",
                params![signer_data, credential_data, storage_data],
            )
            .map_err(|e| format!("Failed to save MLS identity: {e}"))?;
        Ok(())
    }

    /// Remove everything that belongs to one device or to nobody's disk from a copy of
    /// the database leaving this device (a backup, a link snapshot): the Olm account,
    /// sessions and read marks, the replay guard's nonces, the MLS identity and groups, a
    /// 0.11 stored recovery phrase, and the image
    /// verdicts (only this install's own decodes may vouch for bytes, AR-28), and the
    /// floors of history this device cleared (a new device syncs it whole). Deleted
    /// pages are zeroed and the file rebuilt, so no free page still holds them.
    pub fn scrub_device_secrets(&self) -> Result<(), String> {
        // A copy lacks what the clear took, so it asks for it again and vouches only from
        // its oldest row past the floor, like any device whose history begins later; the
        // hole names that row, never the floor.
        self.conn
            .execute(
                "INSERT OR REPLACE INTO channel_sync_holes (server_id, channel_id, below, all_from)
                 SELECT f.server_id, f.channel_id,
                        COALESCE((SELECT MIN(m.timestamp) FROM channel_messages m
                            WHERE m.server_id = f.server_id AND m.channel_id = f.channel_id
                              AND m.timestamp > MAX(f.floor_ts, COALESCE((SELECT MAX(k.ts) FROM channel_cleared_ids k
                                  WHERE k.server_id = f.server_id AND k.channel_id = f.channel_id
                                    AND k.ts > f.floor_ts AND k.ts <= f.floor_ts + ?1), f.floor_ts))), ?2), 0
                 FROM channel_floors f",
                params![CLEAR_SKEW_MS, i64::MAX],
            )
            .map_err(|e| format!("Failed to keep what a copy lacks: {e}"))?;
        self.conn
            .execute_batch(
                "PRAGMA secure_delete = ON;
                 DELETE FROM olm_account;
                 DELETE FROM olm_sessions;
                 DELETE FROM olm_session_floors;
                 DELETE FROM olm_read_marks;
                 DELETE FROM live_frame_nonces;
                 DELETE FROM mls_identity;
                 DELETE FROM mls_storage;
                 DELETE FROM app_settings WHERE key = 'recovery_mnemonic';
                 DELETE FROM app_settings WHERE key >= 'retire_held:' AND key < 'retire_held;';
                 DELETE FROM app_settings WHERE key >= 'settle_owed:' AND key < 'settle_owed;';
                 DELETE FROM image_verdicts;
                 DELETE FROM channel_floors;
                 DELETE FROM channel_cleared_ids;
                 DELETE FROM channel_cleared_senders;
                 DELETE FROM channel_cleared_tail;
                 DELETE FROM channel_cleared_days;
                 DELETE FROM channel_cleared_files;",
            )
            .map_err(|e| format!("Failed to scrub device secrets: {e}"))?;
        self.conn
            .execute_batch("VACUUM;")
            .map_err(|e| format!("Failed to rebuild the scrubbed database: {e}"))
    }

    /// Delete the persisted MLS identity, used when a linked sibling detects it
    /// inherited the source device's identity and must mint a distinct one.
    pub fn clear_mls_identity(&self) -> Result<(), String> {
        self.conn
            .execute_batch("DELETE FROM mls_identity WHERE id = 1; DELETE FROM mls_storage;")
            .map_err(|e| format!("Failed to clear MLS identity: {e}"))?;
        Ok(())
    }

    /// Load MLS identity. Returns (signer_data, credential_data, storage_data) if exists.
    pub fn load_mls_identity(&self) -> Result<Option<(Vec<u8>, Vec<u8>, Option<Vec<u8>>)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT signer_data, credential_data, storage_data FROM mls_identity WHERE id = 1")
            .map_err(|e| format!("Failed to prepare mls_identity query: {e}"))?;
        let mut rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, Vec<u8>>(0)?,
                    row.get::<_, Vec<u8>>(1)?,
                    row.get::<_, Option<Vec<u8>>>(2)?,
                ))
            })
            .map_err(|e| format!("Failed to query mls_identity: {e}"))?;
        match rows.next() {
            Some(Ok(tuple)) => Ok(Some(tuple)),
            Some(Err(e)) => Err(format!("Failed to read mls_identity row: {e}")),
            None => Ok(None),
        }
    }

    // ── Multi-device signed device lists (Phase 6) ──

    /// Persist a master's roster and point its `device_links` at `devices`, its
    /// members, so a device that stopped being one no longer resolves to the master.
    pub fn save_device_list(
        &self,
        master_peer_id: &str,
        json: &str,
        version: u64,
        devices: &[String],
        updated_at: i64,
    ) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO device_lists (master_peer_id, json, version, updated_at)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(master_peer_id) DO UPDATE SET
                    json = excluded.json,
                    version = excluded.version,
                    updated_at = excluded.updated_at",
                rusqlite::params![master_peer_id, json, version as i64, updated_at],
            )
            .map_err(|e| format!("Failed to upsert device_lists: {e}"))?;

        // A device can only belong to one master, so INSERT OR REPLACE re-homes any device
        // that moved and the index stays consistent even for a dishonest list.
        self.conn
            .execute(
                "DELETE FROM device_links WHERE master_peer_id = ?1",
                [master_peer_id],
            )
            .map_err(|e| format!("Failed to clear device_links: {e}"))?;
        for dev in devices {
            self.conn
                .execute(
                    "INSERT OR REPLACE INTO device_links (device_peer_id, master_peer_id)
                     VALUES (?1, ?2)",
                    rusqlite::params![dev, master_peer_id],
                )
                .map_err(|e| format!("Failed to insert device_link: {e}"))?;
        }
        Ok(())
    }

    fn device_list_json(&self, master_peer_id: &str) -> Result<Option<serde_json::Value>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT json FROM device_lists WHERE master_peer_id = ?1")
            .map_err(|e| format!("Failed to prepare load_device_list: {e}"))?;
        let mut rows = stmt
            .query_map([master_peer_id], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query load_device_list: {e}"))?;
        match rows.next() {
            Some(Ok(json)) => Ok(serde_json::from_str(&json).ok()),
            _ => Ok(None),
        }
    }

    /// The 0.11 master-signed list stored for a master, read once to migrate it. `None`
    /// once a roster has replaced it.
    pub fn load_device_list(
        &self,
        master_peer_id: &str,
    ) -> Result<Option<crate::node::SignedDeviceList>, String> {
        Ok(self
            .device_list_json(master_peer_id)?
            .filter(|v| v.get("master_peer_id").is_some())
            .and_then(|v| serde_json::from_value(v).ok()))
    }

    /// When the roster stored for a master last changed, 0 for none.
    pub fn roster_updated_at(&self, master_peer_id: &str) -> i64 {
        self.conn
            .query_row("SELECT updated_at FROM device_lists WHERE master_peer_id = ?1", [master_peer_id], |row| row.get(0))
            .unwrap_or(0)
    }

    /// Every `server_rosters` row of `master`, oldest first: (recovery key, roster).
    pub fn load_server_rosters(&self, master: &str) -> Result<Vec<(String, crate::identity::roster::Roster)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT r_pub, json FROM server_rosters WHERE master_peer_id = ?1 ORDER BY rowid")
            .map_err(|e| format!("Failed to read server rosters: {e}"))?;
        let rows = stmt
            .query_map([master], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
            .map_err(|e| format!("Failed to read server rosters: {e}"))?;
        Ok(rows
            .filter_map(Result::ok)
            .filter_map(|(key, json)| serde_json::from_str(&json).ok().map(|r| (key, r)))
            .collect())
    }

    /// Write `master`'s row under `r_pub`, needed now.
    pub fn save_server_roster(&self, master: &str, r_pub: &str, json: &str, now_ms: i64) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO server_rosters (master_peer_id, r_pub, json, bytes, last_needed_ms) VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT (master_peer_id, r_pub) DO UPDATE SET json = ?3, bytes = ?4, last_needed_ms = ?5",
                rusqlite::params![master, r_pub, json, json.len() as i64, now_ms],
            )
            .map(|_| ())
            .map_err(|e| format!("Failed to save a server roster: {e}"))
    }

    /// The masters of every `server_rosters` row with its total bytes and last need.
    pub fn server_roster_rows(&self) -> Result<Vec<(String, String, i64, i64)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT master_peer_id, r_pub, bytes, last_needed_ms FROM server_rosters")
            .map_err(|e| format!("Failed to list server rosters: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)))
            .map_err(|e| format!("Failed to list server rosters: {e}"))?;
        Ok(rows.filter_map(Result::ok).collect())
    }

    /// `master`'s rows are needed at `now_ms`.
    pub fn note_server_roster_needed(&self, master: &str, now_ms: i64) -> Result<(), String> {
        self.conn
            .execute("UPDATE server_rosters SET last_needed_ms = ?2 WHERE master_peer_id = ?1", rusqlite::params![master, now_ms])
            .map(|_| ())
            .map_err(|e| format!("Failed to stamp a server roster: {e}"))
    }

    pub fn delete_server_roster(&self, master: &str, r_pub: &str) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM server_rosters WHERE master_peer_id = ?1 AND r_pub = ?2", rusqlite::params![master, r_pub])
            .map(|_| ())
            .map_err(|e| format!("Failed to delete a server roster: {e}"))
    }

    /// The roster stored for a master, unverified. `None` for no row or a 0.11 row; a
    /// row that does not read is an error, never "no roster".
    pub fn load_roster(
        &self,
        master_peer_id: &str,
    ) -> Result<Option<crate::identity::roster::Roster>, String> {
        let json: Option<String> = self
            .conn
            .query_row("SELECT json FROM device_lists WHERE master_peer_id = ?1", [master_peer_id], |row| row.get(0))
            .map(Some)
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                e => Err(format!("Failed to read the roster of {master_peer_id}: {e}")),
            })?;
        let Some(json) = json else { return Ok(None) };
        let value: serde_json::Value =
            serde_json::from_str(&json).map_err(|e| format!("The roster of {master_peer_id} does not read: {e}"))?;
        if value.get("master").is_none() {
            return Ok(None);
        }
        serde_json::from_value(value)
            .map(Some)
            .map_err(|e| format!("The roster of {master_peer_id} does not read: {e}"))
    }

    /// Record when this node first saw `device`'s pending join in `base`; the first
    /// stamp stays. Stamps of every other base go: a newer recovery never gives way.
    pub fn stamp_roster_seen(&self, master_peer_id: &str, base: &str, device_peer_id: &str, at_ms: i64) -> Result<(), String> {
        self.conn
            .execute(
                "DELETE FROM roster_pending_seen WHERE master_peer_id = ?1 AND base <> ?2",
                rusqlite::params![master_peer_id, base],
            )
            .map_err(|e| format!("Failed to prune roster_pending_seen: {e}"))?;
        self.conn
            .execute(
                "INSERT OR IGNORE INTO roster_pending_seen (master_peer_id, base, device_peer_id, first_seen_ms)
                 VALUES (?1, ?2, ?3, ?4)",
                rusqlite::params![master_peer_id, base, device_peer_id, at_ms],
            )
            .map_err(|e| format!("Failed to stamp roster_pending_seen: {e}"))?;
        Ok(())
    }

    /// Each stamped device of `master`: when it last confirmed our roster for it, and
    /// when we last asked it to.
    pub fn roster_confirm_slots(&self, master_peer_id: &str) -> std::collections::HashMap<String, (i64, Option<i64>)> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT device_peer_id, confirmed_ms, asked_ms FROM roster_confirms WHERE master_peer_id = ?1",
        ) else {
            return Default::default();
        };
        stmt.query_map([master_peer_id], |row| Ok((row.get::<_, String>(0)?, (row.get(1)?, row.get(2)?))))
            .map(|rows| rows.filter_map(Result::ok).collect())
            .unwrap_or_default()
    }

    /// When `device` last confirmed our roster for `master`.
    pub fn roster_confirmed_at(&self, master_peer_id: &str, device_peer_id: &str) -> Option<i64> {
        self.conn
            .query_row(
                "SELECT confirmed_ms FROM roster_confirms WHERE master_peer_id = ?1 AND device_peer_id = ?2",
                [master_peer_id, device_peer_id],
                |row| row.get(0),
            )
            .ok()
    }

    /// `device` confirmed our roster for `master` at `at_ms`, our clock's now. It
    /// replaces any older stamp outright, so one our clock wrote ahead never sticks.
    pub fn stamp_roster_confirmed(&self, master_peer_id: &str, device_peer_id: &str, at_ms: i64) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO roster_confirms (master_peer_id, device_peer_id, confirmed_ms) VALUES (?1, ?2, ?3)
                 ON CONFLICT(master_peer_id, device_peer_id) DO UPDATE SET confirmed_ms = excluded.confirmed_ms",
                rusqlite::params![master_peer_id, device_peer_id, at_ms],
            )
            .map_err(|e| format!("Failed to stamp roster_confirms: {e}"))?;
        Ok(())
    }

    /// A DM `device` sent at `sent_ms` (its own clock) showed a roster we hold all of:
    /// stamped at `at_ms`, unless a DM it sent at or after `sent_ms` showed one that differs.
    pub fn stamp_roster_confirmed_by_dm(
        &self,
        master_peer_id: &str,
        device_peer_id: &str,
        at_ms: i64,
        sent_ms: i64,
    ) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO roster_confirms (master_peer_id, device_peer_id, confirmed_ms) VALUES (?1, ?2, ?3)
                 ON CONFLICT(master_peer_id, device_peer_id) DO UPDATE SET confirmed_ms = excluded.confirmed_ms
                 WHERE roster_confirms.voided_by_ms IS NULL OR roster_confirms.voided_by_ms < ?4",
                rusqlite::params![master_peer_id, device_peer_id, at_ms, sent_ms],
            )
            .map_err(|e| format!("Failed to stamp roster_confirms: {e}"))?;
        Ok(())
    }

    /// A DM `device` sent at `sent_ms` showed a roster for `master` that differs from
    /// ours: its stamp and any expiry ask are void, so the next DM to `master` asks it
    /// first.
    pub fn unconfirm_roster(&self, master_peer_id: &str, device_peer_id: &str, sent_ms: i64) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO roster_confirms (master_peer_id, device_peer_id, confirmed_ms, asked_ms, voided_by_ms)
                 VALUES (?1, ?2, 0, NULL, ?3)
                 ON CONFLICT(master_peer_id, device_peer_id) DO UPDATE SET confirmed_ms = 0, asked_ms = NULL,
                 voided_by_ms = MAX(COALESCE(roster_confirms.voided_by_ms, excluded.voided_by_ms), excluded.voided_by_ms)",
                rusqlite::params![master_peer_id, device_peer_id, sent_ms],
            )
            .map_err(|e| format!("Failed to unconfirm roster_confirms: {e}"))?;
        Ok(())
    }

    /// We asked `device` for `master`'s roster at `at_ms` because its stamp ran out.
    pub fn mark_roster_expiry_asked(&self, master_peer_id: &str, device_peer_id: &str, at_ms: i64) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE roster_confirms SET asked_ms = ?3 WHERE master_peer_id = ?1 AND device_peer_id = ?2",
                rusqlite::params![master_peer_id, device_peer_id, at_ms],
            )
            .map_err(|e| format!("Failed to mark roster_confirms: {e}"))?;
        Ok(())
    }

    /// Note a roster ask about `subject` for `device` that is to go out later. Only
    /// the newest `cap` are kept.
    pub fn add_roster_ask_due(&self, subject: &str, device_peer_id: &str, at_ms: i64, cap: usize) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO roster_asks_due (subject_master, device_peer_id, due_ms) VALUES (?1, ?2, ?3)
                 ON CONFLICT(subject_master, device_peer_id) DO UPDATE SET due_ms = excluded.due_ms",
                rusqlite::params![subject, device_peer_id, at_ms],
            )
            .map_err(|e| format!("Failed to note a roster ask: {e}"))?;
        self.conn
            .execute(
                "DELETE FROM roster_asks_due WHERE rowid NOT IN
                 (SELECT rowid FROM roster_asks_due ORDER BY due_ms DESC, rowid DESC LIMIT ?1)",
                [cap as i64],
            )
            .map_err(|e| format!("Failed to trim roster asks: {e}"))?;
        Ok(())
    }

    /// Every roster ask noted for later, oldest first, removed as they are read. A row
    /// another process noted again meanwhile stays for the next read.
    pub fn take_roster_asks_due(&self) -> Vec<(String, String)> {
        let due: Vec<(String, String, i64)> = self
            .conn
            .prepare("SELECT subject_master, device_peer_id, due_ms FROM roster_asks_due ORDER BY due_ms, rowid")
            .and_then(|mut stmt| {
                stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?.collect::<Result<Vec<_>, _>>()
            })
            .unwrap_or_default();
        for (subject, device, at) in &due {
            let _ = self.conn.execute(
                "DELETE FROM roster_asks_due WHERE subject_master = ?1 AND device_peer_id = ?2 AND due_ms = ?3",
                rusqlite::params![subject, device, at],
            );
        }
        due.into_iter().map(|(subject, device, _)| (subject, device)).collect()
    }

    /// Stamp every member device of `master` at `at_ms`, or drop every stamp. Tests
    /// only: it ages a roster.
    #[cfg(test)]
    pub fn set_roster_confirmed_for_test(&self, master_peer_id: &str, at_ms: Option<i64>) {
        self.conn
            .execute("DELETE FROM roster_confirms WHERE master_peer_id = ?1", [master_peer_id])
            .expect("clear roster_confirms");
        if let Some(at) = at_ms {
            for device in self.device_links_for(master_peer_id).unwrap_or_default() {
                self.stamp_roster_confirmed(master_peer_id, &device, at).expect("set roster_confirms");
            }
        }
    }

    /// Every first-sight stamp for one master's pending joins in `base`.
    pub fn load_roster_seen(&self, master_peer_id: &str, base: &str) -> Result<std::collections::HashMap<String, i64>, String> {
        let mut stmt = self
            .conn
            .prepare_cached(
                "SELECT device_peer_id, first_seen_ms FROM roster_pending_seen
                 WHERE master_peer_id = ?1 AND base = ?2",
            )
            .map_err(|e| format!("Failed to prepare roster_pending_seen: {e}"))?;
        let rows = stmt
            .query_map([master_peer_id, base], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))
            .map_err(|e| format!("Failed to query roster_pending_seen: {e}"))?;
        Ok(collect_rows(rows, "roster_pending_seen")?.into_iter().collect())
    }

    /// Whether this database comes from before first sights were kept.
    pub fn roster_statements_marked(&self) -> Result<bool, String> {
        self.conn
            .query_row("SELECT COUNT(*) FROM roster_statement_seen WHERE master_peer_id = '*' AND digest = '*'", [], |row| {
                row.get::<_, i64>(0)
            })
            .map(|n| n > 0)
            .map_err(|e| format!("roster_statement_seen: {e}"))
    }

    /// Date `digests` of `master`'s roster first seen at 0 (held before the upgrade) and
    /// clear the upgrade mark, as one change: a crash between them would leave the held
    /// roster dated as news. False, writing nothing, when another process took the mark.
    pub fn seed_roster_statements_once(&self, master_peer_id: &str, digests: &[String]) -> Result<bool, String> {
        let err = |e: rusqlite::Error| format!("roster_statement_seen: {e}");
        self.conn.execute_batch("SAVEPOINT roster_seed").map_err(err)?;
        let seeded = (|| -> rusqlite::Result<bool> {
            for d in digests {
                self.conn.execute(
                    "INSERT OR IGNORE INTO roster_statement_seen (master_peer_id, digest, first_seen_ms) VALUES (?1, ?2, 0)",
                    rusqlite::params![master_peer_id, d],
                )?;
            }
            Ok(self.conn.execute("DELETE FROM roster_statement_seen WHERE master_peer_id = '*' AND digest = '*'", [])? > 0)
        })();
        let end = match seeded {
            Ok(true) => "RELEASE roster_seed",
            _ => "ROLLBACK TO roster_seed; RELEASE roster_seed",
        };
        self.conn.execute_batch(end).map_err(err)?;
        seeded.map_err(err)
    }

    /// Record which statements (`present`, by digest) `master`'s roster holds now: a new one
    /// is first seen `now_ms`, one that left is marked dropped, and a dropped row older than
    /// `keep_ms` goes. At most `cap` rows per master, the longest dropped first.
    pub fn note_roster_statements(&self, master_peer_id: &str, present: &[String], now_ms: i64, keep_ms: i64, cap: usize) -> Result<(), String> {
        let err = |e: rusqlite::Error| format!("roster_statement_seen: {e}");
        let mut stmt = self
            .conn
            .prepare_cached("SELECT digest, dropped_ms FROM roster_statement_seen WHERE master_peer_id = ?1")
            .map_err(err)?;
        let rows = stmt
            .query_map([master_peer_id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)))
            .map_err(err)?;
        let held: std::collections::HashMap<String, Option<i64>> = collect_rows(rows, "roster_statement_seen")?.into_iter().collect();
        let now: std::collections::HashSet<&str> = present.iter().map(String::as_str).collect();
        for d in present {
            match held.get(d) {
                None => {
                    self.conn
                        .execute(
                            "INSERT OR IGNORE INTO roster_statement_seen (master_peer_id, digest, first_seen_ms) VALUES (?1, ?2, ?3)",
                            rusqlite::params![master_peer_id, d, now_ms],
                        )
                        .map_err(err)?;
                }
                Some(Some(_)) => {
                    self.conn
                        .execute(
                            "UPDATE roster_statement_seen SET dropped_ms = NULL WHERE master_peer_id = ?1 AND digest = ?2",
                            rusqlite::params![master_peer_id, d],
                        )
                        .map_err(err)?;
                }
                Some(None) => {}
            }
        }
        for (d, dropped) in &held {
            if dropped.is_none() && !now.contains(d.as_str()) {
                self.conn
                    .execute(
                        "UPDATE roster_statement_seen SET dropped_ms = ?3 WHERE master_peer_id = ?1 AND digest = ?2",
                        rusqlite::params![master_peer_id, d, now_ms],
                    )
                    .map_err(err)?;
            }
        }
        self.conn
            .execute(
                "DELETE FROM roster_statement_seen WHERE master_peer_id = ?1 AND dropped_ms IS NOT NULL AND dropped_ms < ?2",
                rusqlite::params![master_peer_id, now_ms.saturating_sub(keep_ms)],
            )
            .map_err(err)?;
        self.conn
            .execute(
                "DELETE FROM roster_statement_seen WHERE master_peer_id = ?1 AND digest IN (
                     SELECT digest FROM roster_statement_seen WHERE master_peer_id = ?1 AND dropped_ms IS NOT NULL
                     ORDER BY dropped_ms ASC, digest ASC
                     LIMIT MAX(0, (SELECT COUNT(*) FROM roster_statement_seen WHERE master_peer_id = ?1) - ?2))",
                rusqlite::params![master_peer_id, cap as i64],
            )
            .map_err(err)?;
        Ok(())
    }

    /// When this node first saw the statement `digest` of `master`'s roster.
    pub fn roster_statement_first_seen(&self, master_peer_id: &str, digest: &str) -> Option<i64> {
        self.conn
            .prepare_cached("SELECT first_seen_ms FROM roster_statement_seen WHERE master_peer_id = ?1 AND digest = ?2")
            .and_then(|mut s| s.query_row([master_peer_id, digest], |row| row.get::<_, i64>(0)))
            .ok()
    }

    /// Turn this database into one from before first sights were kept and migrate it, as
    /// the first open of an upgraded app does. Tests only.
    #[cfg(test)]
    pub fn upgrade_from_before_first_sights_for_test(&self) {
        self.conn.execute_batch("DROP TABLE roster_statement_seen").expect("drop roster_statement_seen");
        Self::init_schema(&self.conn).expect("schema");
    }

    /// Back-date a statement's first sight. Tests only.
    #[cfg(test)]
    pub fn set_roster_statement_first_seen(&self, master_peer_id: &str, digest: &str, at_ms: i64) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO roster_statement_seen (master_peer_id, digest, first_seen_ms) VALUES (?1, ?2, ?3)",
                rusqlite::params![master_peer_id, digest, at_ms],
            )
            .map(|_| ())
            .map_err(|e| format!("roster_statement_seen: {e}"))
    }

    /// Back-date a first-sight stamp. Tests only: seven days do not pass in a test.
    #[cfg(test)]
    pub fn set_roster_seen(&self, master_peer_id: &str, base: &str, device_peer_id: &str, at_ms: i64) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO roster_pending_seen (master_peer_id, base, device_peer_id, first_seen_ms)
                 VALUES (?1, ?2, ?3, ?4)",
                rusqlite::params![master_peer_id, base, device_peer_id, at_ms],
            )
            .map_err(|e| format!("Failed to set roster_pending_seen: {e}"))?;
        Ok(())
    }

    /// The devices linked to `master_peer_id`: its members as last saved.
    pub fn device_links_for(&self, master_peer_id: &str) -> Result<std::collections::BTreeSet<String>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT device_peer_id FROM device_links WHERE master_peer_id = ?1")
            .map_err(|e| format!("Failed to prepare device_links_for: {e}"))?;
        let rows = stmt
            .query_map([master_peer_id], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query device_links_for: {e}"))?;
        Ok(collect_rows(rows, "device_link")?.into_iter().collect())
    }

    /// Load all (device_peer_id → master_peer_id) links for resolver warmup.
    pub fn get_all_device_links(&self) -> Result<Vec<(String, String)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT device_peer_id, master_peer_id FROM device_links")
            .map_err(|e| format!("Failed to prepare get_all_device_links: {e}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(|e| format!("Failed to query device_links: {e}"))?;
        collect_rows(rows, "device_link")
    }

    /// Every master whose stored row is a roster, not a 0.11 list.
    pub fn rostered_masters(&self) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT master_peer_id FROM device_lists WHERE json_extract(json, '$.master') IS NOT NULL")
            .map_err(|e| format!("Failed to prepare rostered_masters: {e}"))?;
        let rows = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query rostered_masters: {e}"))?;
        collect_rows(rows, "rostered_master")
    }

    /// Forget `master`'s revocation of devices its recovery, signed with the phrase,
    /// brought back: only the phrase can do that, and only for its own identity.
    pub fn clear_revoked_devices(&self, master_peer_id: &str, devices: &[String]) -> Result<(), String> {
        // An old row not moved yet is lifted with its own master's mark, never another's.
        let old = table_exists(&self.conn, "revoked_devices");
        for dev in devices {
            let tables: &[&str] = if old { &["revoked_marks", "revoked_devices"] } else { &["revoked_marks"] };
            for table in tables {
                self.conn
                    .execute(
                        &format!("DELETE FROM {table} WHERE device_peer_id = ?1 AND master_peer_id = ?2"),
                        rusqlite::params![dev, master_peer_id],
                    )
                    .map_err(|e| format!("Failed to clear revoked device: {e}"))?;
            }
        }
        Ok(())
    }

    /// Record devices whose revocation this node enforced. Removed only when a
    /// recovery brings the device back.
    pub fn record_revoked_devices(&self, master_peer_id: &str, devices: &[String]) -> Result<(), String> {
        for dev in devices {
            self.conn
                .execute(
                    "INSERT OR IGNORE INTO revoked_marks (device_peer_id, master_peer_id) VALUES (?1, ?2)",
                    rusqlite::params![dev, master_peer_id],
                )
                .map_err(|e| format!("Failed to record revoked device: {e}"))?;
        }
        Ok(())
    }

    /// Every (device, master) recorded by [`Self::record_revoked_devices`], with the rows
    /// of a 0.12 table whose move has not landed yet.
    pub fn revoked_marks(&self) -> Result<Vec<(String, String)>, String> {
        let sql = if table_exists(&self.conn, "revoked_devices") {
            "SELECT device_peer_id, master_peer_id FROM revoked_marks
             UNION SELECT device_peer_id, master_peer_id FROM revoked_devices ORDER BY 1, 2"
        } else {
            "SELECT device_peer_id, master_peer_id FROM revoked_marks ORDER BY 1, 2"
        };
        let mut stmt = self
            .conn
            .prepare_cached(sql)
            .map_err(|e| format!("Failed to prepare revoked_marks: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
            .map_err(|e| format!("Failed to query revoked_marks: {e}"))?;
        collect_rows(rows, "revoked_mark")
    }

    /// Every revoked device id, whoever removed it.
    #[cfg(test)]
    pub fn get_all_revoked_devices(&self) -> Result<Vec<String>, String> {
        Ok(self.revoked_marks()?.into_iter().map(|(device, _)| device).collect())
    }

    // ── Device labels (Step 8 Devices panel — local-only, unsigned) ──

    /// Set (or clear, when empty) the local human label for a device peer_id.
    pub fn set_device_label(&self, device_peer_id: &str, label: &str) -> Result<(), String> {
        if label.is_empty() {
            self.conn
                .execute(
                    "DELETE FROM device_labels WHERE device_peer_id = ?1",
                    params![device_peer_id],
                )
                .map_err(|e| format!("Failed to clear device label: {e}"))?;
        } else {
            self.conn
                .execute(
                    "INSERT INTO device_labels (device_peer_id, label) VALUES (?1, ?2)
                     ON CONFLICT(device_peer_id) DO UPDATE SET label = excluded.label",
                    params![device_peer_id, label],
                )
                .map_err(|e| format!("Failed to save device label: {e}"))?;
        }
        Ok(())
    }

    /// Load all local device labels (device_peer_id, label).
    pub fn get_all_device_labels(&self) -> Result<Vec<(String, String)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT device_peer_id, label FROM device_labels")
            .map_err(|e| format!("Failed to prepare device_labels query: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|e| format!("Failed to query device_labels: {e}"))?;
        collect_rows(rows, "device_labels")
    }

    /// Record a sibling's device kind. True when it changed.
    pub fn set_device_kind(&self, device_peer_id: &str, kind: &str) -> Result<bool, String> {
        let n = self
            .conn
            .execute(
                "INSERT INTO device_kinds (device_peer_id, kind) VALUES (?1, ?2)
                 ON CONFLICT(device_peer_id) DO UPDATE SET kind = excluded.kind WHERE kind != excluded.kind",
                params![device_peer_id, kind],
            )
            .map_err(|e| format!("Failed to save device kind: {e}"))?;
        Ok(n > 0)
    }

    /// Every known sibling's kind (device_peer_id, kind).
    pub fn get_all_device_kinds(&self) -> Result<Vec<(String, String)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT device_peer_id, kind FROM device_kinds")
            .map_err(|e| format!("Failed to prepare device_kinds query: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|e| format!("Failed to query device_kinds: {e}"))?;
        collect_rows(rows, "device_kinds")
    }

    // ── User Profile Persistence (Phase 3.5) ──

    /// Upsert a user profile, ours or a peer's. Nothing older than the stored row is
    /// written: a device back from away re-announces the profile it last held, and
    /// that copy must not undo an edit made on another device meanwhile. Two devices
    /// of one identity can sign different profiles at one stamp: of two signed copies
    /// the higher signature stays, so every replica keeps the same one.
    ///
    /// `avatar`, `banner`, `showcase_board`, `avatar_frame`, `avatar_anim` and
    /// `banner_anim` are three-state: `None` preserves what is stored (an update from a
    /// client that predates the field must not erase it), empty clears, else it sets.
    #[allow(clippy::too_many_arguments)]
    pub fn save_profile(
        &self,
        peer_id: &str,
        display_name: &str,
        status: &str,
        about_me: &str,
        updated_at: i64,
        avatar: Option<&[u8]>,
        banner: Option<&[u8]>,
        twitch_username: &str,
        showcase_board: Option<&str>,
        showcase_assets: Option<&[u8]>,
        // `None` leaves whatever proof is stored (COALESCE): a partial update must not
        // orphan an existing signature.
        proof: Option<ProfileProof<'_>>,
        avatar_frame: Option<&str>,
        avatar_anim: Option<&str>,
        banner_anim: Option<&str>,
        // Support credentials, same three states; the array must ALREADY be sanitized.
        support_creds: Option<&str>,
    ) -> Result<bool, String> {
        let profile_sig = proof.map(|p| p.sig);
        let profile_pk = proof.map(|p| p.pk);
        let profile_avatar_hash = proof.map(|p| p.avatar_hash);
        let profile_banner_hash = proof.map(|p| p.banner_hash);
        let profile_assets_hash = proof.map(|p| p.assets_hash);
        // Normalize an empty avatar/banner to an explicit NULL, since COALESCE cannot.
        let avatar_val: Option<&[u8]> = avatar.and_then(|b| if b.is_empty() { None } else { Some(b) });
        let banner_val: Option<&[u8]> = banner.and_then(|b| if b.is_empty() { None } else { Some(b) });
        let avatar_is_clear = avatar.is_some() && avatar.unwrap().is_empty();
        let banner_is_clear = banner.is_some() && banner.unwrap().is_empty();
        let assets_val: Option<&[u8]> = showcase_assets.and_then(|b| if b.is_empty() { None } else { Some(b) });
        let assets_is_clear = showcase_assets.is_some() && showcase_assets.unwrap().is_empty();

        let written = self.conn
            .execute(
                "INSERT INTO user_profiles (peer_id, display_name, status, about_me, updated_at, avatar, banner, twitch_username, showcase_board, showcase_assets, profile_sig, profile_pk, profile_avatar_hash, avatar_frame, avatar_anim, banner_anim, support_creds, profile_banner_hash, profile_assets_hash)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, COALESCE(?9, ''), ?10, ?11, ?12, ?13, COALESCE(?14, ''), COALESCE(?15, ''), COALESCE(?16, ''), COALESCE(?17, ''), ?18, ?19)
                 ON CONFLICT(peer_id) DO UPDATE SET
                    display_name = excluded.display_name,
                    status = excluded.status,
                    about_me = excluded.about_me,
                    updated_at = excluded.updated_at,
                    avatar = COALESCE(excluded.avatar, user_profiles.avatar),
                    banner = COALESCE(excluded.banner, user_profiles.banner),
                    twitch_username = excluded.twitch_username,
                    showcase_board = COALESCE(?9, user_profiles.showcase_board),
                    showcase_assets = COALESCE(excluded.showcase_assets, user_profiles.showcase_assets),
                    profile_sig = COALESCE(excluded.profile_sig, user_profiles.profile_sig),
                    profile_pk = COALESCE(excluded.profile_pk, user_profiles.profile_pk),
                    profile_avatar_hash = COALESCE(excluded.profile_avatar_hash, user_profiles.profile_avatar_hash),
                    profile_banner_hash = COALESCE(excluded.profile_banner_hash, user_profiles.profile_banner_hash),
                    profile_assets_hash = COALESCE(excluded.profile_assets_hash, user_profiles.profile_assets_hash),
                    avatar_frame = COALESCE(?14, user_profiles.avatar_frame),
                    avatar_anim = COALESCE(?15, user_profiles.avatar_anim),
                    banner_anim = COALESCE(?16, user_profiles.banner_anim),
                    support_creds = COALESCE(?17, user_profiles.support_creds)
                 WHERE excluded.updated_at > user_profiles.updated_at
                    OR (excluded.updated_at = user_profiles.updated_at
                        AND (?11 IS NULL OR user_profiles.profile_sig IS NULL OR ?11 >= user_profiles.profile_sig))
                    OR user_profiles.updated_at > ?20",
                params![peer_id, display_name, status, about_me, updated_at, avatar_val, banner_val, twitch_username, showcase_board, assets_val, profile_sig, profile_pk, profile_avatar_hash, avatar_frame, avatar_anim, banner_anim, support_creds, profile_banner_hash, profile_assets_hash, stored_profile_stamp_limit()],
            )
            .map_err(|e| format!("Failed to save profile: {e}"))?;
        // The freshness WHERE refused a stale profile: its clears must not land either.
        if written == 0 {
            return Ok(false);
        }

        // Explicitly clear avatar/banner if requested (COALESCE can't set NULL).
        if avatar_is_clear {
            self.conn.execute(
                "UPDATE user_profiles SET avatar = NULL WHERE peer_id = ?1",
                params![peer_id],
            ).map_err(|e| format!("Failed to clear avatar: {e}"))?;
        }
        if banner_is_clear {
            self.conn.execute(
                "UPDATE user_profiles SET banner = NULL WHERE peer_id = ?1",
                params![peer_id],
            ).map_err(|e| format!("Failed to clear banner: {e}"))?;
        }
        if assets_is_clear {
            self.conn.execute(
                "UPDATE user_profiles SET showcase_assets = NULL WHERE peer_id = ?1",
                params![peer_id],
            ).map_err(|e| format!("Failed to clear showcase assets: {e}"))?;
        }
        // A pending request's thumb stands in only until the full profile holds the
        // avatar or signs that there is none.
        if avatar_val.is_some() || avatar_is_clear || profile_avatar_hash == Some("") {
            self.retire_card_thumb(peer_id)?;
        }
        Ok(true)
    }

    /// The stamp and owner signature of the profile stored for `peer_id`.
    pub fn profile_stamp_sig(&self, peer_id: &str) -> Option<(i64, Option<String>)> {
        self.conn
            .query_row(
                "SELECT updated_at, profile_sig FROM user_profiles WHERE peer_id = ?1",
                params![peer_id],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, Option<String>>(1)?)),
            )
            .ok()
    }

    /// Store a profile CARD (A28): only the name and avatar of someone we are not close
    /// to. An empty `avatar_hash` clears the avatar and bytes set it; with neither the
    /// stored still stays until pulled. Nothing older than the row is written, and a
    /// row a card replaces loses its owner proof, which no longer matches its name, so
    /// it is never relayed. Returns whether it wrote.
    pub fn save_profile_card(
        &self,
        peer_id: &str,
        display_name: &str,
        updated_at: i64,
        avatar_hash: &str,
        avatar: Option<&[u8]>,
    ) -> Result<bool, String> {
        self.upsert_profile_card(peer_id, display_name, updated_at, avatar_hash, avatar, false)
    }

    /// [`Self::save_profile_card`] for a card that won its stamp's tie (its signature
    /// outranks the card stored at the same stamp): it replaces a card row at that stamp.
    pub fn replace_tied_profile_card(
        &self,
        peer_id: &str,
        display_name: &str,
        updated_at: i64,
        avatar_hash: &str,
        avatar: Option<&[u8]>,
    ) -> Result<bool, String> {
        self.upsert_profile_card(peer_id, display_name, updated_at, avatar_hash, avatar, true)
    }

    fn upsert_profile_card(
        &self,
        peer_id: &str,
        display_name: &str,
        updated_at: i64,
        avatar_hash: &str,
        avatar: Option<&[u8]>,
        won_tie: bool,
    ) -> Result<bool, String> {
        let avatar = avatar.filter(|b| !b.is_empty());
        let written = self.conn
            .execute(
                "INSERT INTO user_profiles (peer_id, display_name, updated_at, avatar)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(peer_id) DO UPDATE SET
                    display_name = excluded.display_name,
                    updated_at = excluded.updated_at,
                    avatar = CASE WHEN ?5 = '' THEN NULL ELSE COALESCE(excluded.avatar, user_profiles.avatar) END,
                    profile_sig = NULL, profile_pk = NULL, profile_avatar_hash = NULL,
                    profile_banner_hash = NULL, profile_assets_hash = NULL
                 WHERE excluded.updated_at > user_profiles.updated_at
                    OR (?7 AND excluded.updated_at = user_profiles.updated_at AND user_profiles.profile_sig IS NULL)
                    OR user_profiles.updated_at > ?6",
                params![peer_id, display_name, updated_at, avatar, avatar_hash, stored_profile_stamp_limit(), won_tie],
            )
            .map_err(|e| format!("Failed to save profile card: {e}"))?;
        if written > 0 {
            if avatar_hash.is_empty() {
                self.retire_card_thumb(peer_id)?;
            }
            return Ok(true);
        }
        // The same card again, now with the bytes it was pulled for.
        let Some(bytes) = avatar else {
            return Ok(false);
        };
        let set = self.conn
            .execute(
                "UPDATE user_profiles SET avatar = ?2 WHERE peer_id = ?1 AND updated_at = ?3",
                params![peer_id, bytes, updated_at],
            )
            .map_err(|e| format!("Failed to save profile card avatar: {e}"))?;
        Ok(set > 0)
    }

    // ── Stream overlay (#97) ──────────────────────────────────────

    /// The signed `stream_overlay` field held for `master` (stored JSON) and its stamp;
    /// `None` when we hold none.
    pub fn load_stream_overlay(&self, master: &str) -> Result<Option<(String, i64)>, String> {
        let row = self.conn.query_row(
            "SELECT stream_overlay, stream_overlay_at FROM user_profiles WHERE peer_id = ?1",
            params![master],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        );
        match row {
            Ok((json, at)) if !json.is_empty() => Ok(Some((json, at))),
            Ok(_) | Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(format!("Failed to read stream overlay field: {e}")),
        }
    }

    /// Keep `field_json` for `master` only when `at` is newer than the stamp we hold:
    /// an older field never replaces a newer one. `create` makes the profile row when
    /// there is none (our own identity only). Returns whether it was written.
    pub fn save_stream_overlay(&self, master: &str, field_json: &str, at: i64, create: bool) -> Result<bool, String> {
        let sql = if create {
            "INSERT INTO user_profiles (peer_id, stream_overlay, stream_overlay_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(peer_id) DO UPDATE SET
                stream_overlay = excluded.stream_overlay,
                stream_overlay_at = excluded.stream_overlay_at
             WHERE excluded.stream_overlay_at > user_profiles.stream_overlay_at"
        } else {
            "UPDATE user_profiles SET stream_overlay = ?2, stream_overlay_at = ?3
             WHERE peer_id = ?1 AND stream_overlay_at < ?3"
        };
        self.conn
            .execute(sql, params![master, field_json, at])
            .map(|n| n > 0)
            .map_err(|e| format!("Failed to save stream overlay field: {e}"))
    }

    fn overlay_person_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<OverlayPersonRow> {
        Ok(OverlayPersonRow {
            master: row.get(0)?,
            slot: row.get(1)?,
            added_at: row.get(2)?,
            local_look: row.get(3)?,
            their_look: row.get(4)?,
            held_stamp: row.get(5)?,
        })
    }

    /// Every person on this device's overlay, by slot.
    pub fn overlay_people(&self) -> Result<Vec<OverlayPersonRow>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT master, slot, added_at, local_look, their_look, held_stamp FROM overlay_people ORDER BY slot")
            .map_err(|e| format!("Failed to prepare overlay people: {e}"))?;
        let rows = stmt
            .query_map([], Self::overlay_person_row)
            .map_err(|e| format!("Failed to list overlay people: {e}"))?;
        collect_rows(rows, "overlay person")
    }

    pub fn overlay_person(&self, master: &str) -> Result<Option<OverlayPersonRow>, String> {
        match self.conn.query_row(
            "SELECT master, slot, added_at, local_look, their_look, held_stamp FROM overlay_people WHERE master = ?1",
            params![master],
            Self::overlay_person_row,
        ) {
            Ok(row) => Ok(Some(row)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(format!("Failed to read overlay person: {e}")),
        }
    }

    /// Add `master` with the next slot, or return the slot it already has. A slot is
    /// never handed out twice, so an old OBS link never shows somebody else.
    pub fn overlay_add_person(&self, master: &str, now_ms: i64) -> Result<i64, String> {
        if let Some(row) = self.overlay_person(master)? {
            return Ok(row.slot);
        }
        let highest: i64 = self
            .conn
            .query_row("SELECT COALESCE(MAX(slot), 0) FROM overlay_people", [], |row| row.get(0))
            .map_err(|e| format!("Failed to read overlay slots: {e}"))?;
        let counter = self
            .load_setting(OVERLAY_NEXT_SLOT_SETTING)?
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(1);
        let slot = counter.max(highest + 1).max(1);
        self.conn
            .execute(
                "INSERT INTO overlay_people (master, slot, added_at) VALUES (?1, ?2, ?3)",
                params![master, slot, now_ms],
            )
            .map_err(|e| format!("Failed to add overlay person: {e}"))?;
        self.save_setting(OVERLAY_NEXT_SLOT_SETTING, &(slot + 1).to_string())?;
        Ok(slot)
    }

    /// Remove `master` and everything kept for them; returns the row it removed.
    pub fn overlay_remove_person(&self, master: &str) -> Result<Option<OverlayPersonRow>, String> {
        let row = self.overlay_person(master)?;
        if row.is_some() {
            self.conn
                .execute("DELETE FROM overlay_people WHERE master = ?1", params![master])
                .map_err(|e| format!("Failed to remove overlay person: {e}"))?;
        }
        Ok(row)
    }

    /// Our own picks for `master` (`None` clears them). Returns whether a row changed.
    pub fn overlay_set_local_look(&self, master: &str, look: Option<&str>) -> Result<bool, String> {
        self.conn
            .execute("UPDATE overlay_people SET local_look = ?2 WHERE master = ?1", params![master, look])
            .map(|n| n > 0)
            .map_err(|e| format!("Failed to save overlay picks: {e}"))
    }

    /// The look `master` shared with us (`None` deletes it) and the field stamp it
    /// answers. Returns whether a row changed.
    pub fn overlay_set_their_look(&self, master: &str, look: Option<&str>, held_stamp: i64) -> Result<bool, String> {
        self.conn
            .execute(
                "UPDATE overlay_people SET their_look = ?2, held_stamp = ?3 WHERE master = ?1",
                params![master, look, held_stamp],
            )
            .map(|n| n > 0)
            .map_err(|e| format!("Failed to save overlay look: {e}"))
    }

    /// Load a profile for a specific peer.
    pub fn load_profile(&self, peer_id: &str) -> Result<Option<StoredProfile>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT peer_id, display_name, status, about_me, updated_at, avatar, banner, twitch_username, showcase_board, showcase_assets, profile_sig, profile_pk, profile_avatar_hash, avatar_frame, avatar_anim, banner_anim, support_creds, profile_banner_hash, profile_assets_hash
                 FROM user_profiles WHERE peer_id = ?1",
            )
            .map_err(|e| format!("Failed to prepare profile query: {e}"))?;
        let mut rows = stmt
            .query_map(params![peer_id], profile_from_row)
            .map_err(|e| format!("Failed to query profile: {e}"))?;
        match rows.next() {
            Some(Ok(profile)) => Ok(Some(profile)),
            Some(Err(e)) => Err(format!("Failed to read profile row: {e}")),
            None => Ok(None),
        }
    }

    /// Load all stored profiles.
    pub fn load_all_profiles(&self) -> Result<Vec<StoredProfile>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT peer_id, display_name, status, about_me, updated_at, avatar, banner, twitch_username, showcase_board, showcase_assets, profile_sig, profile_pk, profile_avatar_hash, avatar_frame, avatar_anim, banner_anim, support_creds, profile_banner_hash, profile_assets_hash
                 FROM user_profiles",
            )
            .map_err(|e| format!("Failed to prepare all profiles query: {e}"))?;
        let rows = stmt
            .query_map([], profile_from_row)
            .map_err(|e| format!("Failed to query all profiles: {e}"))?;
        collect_rows(rows, "profile")
    }

    /// Load all stored profiles WITHOUT avatar/banner blobs (light load for startup).
    pub fn load_all_profiles_light(&self) -> Result<Vec<StoredProfile>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT peer_id, display_name, status, about_me, updated_at, twitch_username, showcase_board, avatar_frame, avatar_anim, banner_anim, support_creds
                 FROM user_profiles",
            )
            .map_err(|e| format!("Failed to prepare light profiles query: {e}"))?;
        let rows = stmt
            .query_map([], profile_light_from_row)
            .map_err(|e| format!("Failed to query light profiles: {e}"))?;
        collect_rows(rows, "profile")
    }

    /// Load a single profile WITHOUT avatar/banner blobs (light load).
    pub fn load_profile_light(&self, peer_id: &str) -> Result<Option<StoredProfile>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT peer_id, display_name, status, about_me, updated_at, twitch_username, showcase_board, avatar_frame, avatar_anim, banner_anim, support_creds
                 FROM user_profiles WHERE peer_id = ?1",
            )
            .map_err(|e| format!("Failed to prepare light profile query: {e}"))?;
        let mut rows = stmt
            .query_map(params![peer_id], profile_light_from_row)
            .map_err(|e| format!("Failed to query light profile: {e}"))?;
        match rows.next() {
            Some(Ok(profile)) => Ok(Some(profile)),
            Some(Err(e)) => Err(format!("Failed to read profile row: {e}")),
            None => Ok(None),
        }
    }

    /// The avatar to paint for a peer: its stored still, else the card thumb on its
    /// friend row. Never for re-serving: a thumb is no signed avatar.
    pub fn load_avatar_for_display(&self, peer_id: &str) -> Result<Option<Vec<u8>>, String> {
        self.conn
            .query_row(
                "SELECT COALESCE(
                    (SELECT avatar FROM user_profiles WHERE peer_id = ?1),
                    (SELECT card_thumb FROM friends WHERE peer_id = ?1))",
                params![peer_id],
                |row| row.get(0),
            )
            .map_err(|e| format!("Failed to load avatar: {e}"))
    }

    /// Load only the avatar blob for a peer.
    pub fn load_avatar(&self, peer_id: &str) -> Result<Option<Vec<u8>>, String> {
        self.conn
            .query_row(
                "SELECT avatar FROM user_profiles WHERE peer_id = ?1",
                params![peer_id],
                |row| row.get(0),
            )
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                _ => Err(format!("Failed to load avatar: {e}")),
            })
    }

    /// Load only the showcase asset bundle blob for a peer.
    pub fn load_showcase_assets(&self, peer_id: &str) -> Result<Option<Vec<u8>>, String> {
        self.conn
            .query_row(
                "SELECT showcase_assets FROM user_profiles WHERE peer_id = ?1",
                params![peer_id],
                |row| row.get(0),
            )
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                _ => Err(format!("Failed to load showcase assets: {e}")),
            })
    }

    /// Load only the banner blob for a peer.
    pub fn load_banner(&self, peer_id: &str) -> Result<Option<Vec<u8>>, String> {
        self.conn
            .query_row(
                "SELECT banner FROM user_profiles WHERE peer_id = ?1",
                params![peer_id],
                |row| row.get(0),
            )
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                _ => Err(format!("Failed to load banner: {e}")),
            })
    }

    // ── Message Editing (Phase 3.5) ──

    /// Edit a channel message by message_id. Preserves old text in message_edits table.
    /// Returns true if the message was found and updated.
    /// Returns the sender_id for a channel message, if found.
    pub fn get_channel_message_sender(&self, message_id: &str) -> Option<String> {
        self.conn
            .query_row(
                "SELECT sender_id FROM channel_messages WHERE message_id = ?1",
                params![message_id],
                |row| row.get(0),
            )
            .ok()
    }

    /// Where a channel message lives and who it names as author.
    pub fn get_channel_message_owner(&self, message_id: &str) -> Option<ChannelRowOwner> {
        self.conn
            .query_row(
                "SELECT server_id, channel_id, sender_id, public_key FROM channel_messages WHERE message_id = ?1",
                params![message_id],
                |row| Ok(ChannelRowOwner {
                    server_id: row.get(0)?,
                    channel_id: row.get(1)?,
                    sender_id: row.get(2)?,
                    public_key: row.get(3)?,
                }),
            )
            .ok()
    }

    /// Returns whether a DM message is mine (true) or from the peer (false).
    pub fn get_dm_message_is_mine(&self, message_id: &str) -> Option<bool> {
        self.conn
            .query_row(
                "SELECT is_mine FROM messages WHERE message_id = ?1",
                params![message_id],
                |row| row.get::<_, i32>(0).map(|v| v != 0),
            )
            .ok()
    }

    /// The conversation peer_id (the OTHER party's master) a DM is filed under. Used by
    /// multi-device self fan-out: an edit, delete or reaction envelope carries no
    /// conversation, so the event is attributed by looking the row up by message_id.
    pub fn get_dm_message_peer(&self, message_id: &str) -> Option<String> {
        self.conn
            .query_row(
                "SELECT peer_id FROM messages WHERE message_id = ?1",
                params![message_id],
                |row| row.get(0),
            )
            .ok()
    }

    /// Current text of a channel message, used when signing deletions so the canonical
    /// payload reflects the text at deletion time.
    pub fn get_channel_message_text(&self, message_id: &str) -> Option<String> {
        self.conn
            .query_row(
                "SELECT text FROM channel_messages WHERE message_id = ?1",
                params![message_id],
                |row| row.get(0),
            )
            .ok()
    }

    /// Current text of a DM message, used when signing deletions so the canonical
    /// payload reflects the text at deletion time.
    pub fn get_dm_message_text(&self, message_id: &str) -> Option<String> {
        self.conn
            .query_row(
                "SELECT text FROM messages WHERE message_id = ?1",
                params![message_id],
                |row| row.get(0),
            )
            .ok()
    }

    /// One message row's signature-relevant fields (v2 message signing), loaded by the
    /// edit and delete SIGN sites, their VERIFY twins, and the Message Proof FFI.
    fn message_sig_row(&self, table: &str, message_id: &str) -> Option<MessageSigRow> {
        self.conn
            .query_row(
                &format!(
                    "SELECT text, timestamp, signature, public_key, edited_at, \
                     reply_to_mid, file_id, order_us, link_preview_json, album_id \
                     FROM {table} WHERE message_id = ?1"
                ),
                params![message_id],
                |row| {
                    Ok(MessageSigRow {
                        text: row.get(0)?,
                        timestamp: row.get(1)?,
                        signature: row.get(2)?,
                        public_key: row.get(3)?,
                        edited_at: row.get(4)?,
                        reply_to_mid: row.get(5)?,
                        file_id: row.get(6)?,
                        order_us: row.get(7)?,
                        link_preview: row
                            .get::<_, Option<String>>(8)?
                            .and_then(|json| serde_json::from_str(&json).ok()),
                        album_id: row.get(9)?,
                    })
                },
            )
            .ok()
    }

    /// [`Self::message_sig_row`] for the DM `messages` table.
    pub fn get_dm_message_sig_row(&self, message_id: &str) -> Option<MessageSigRow> {
        self.message_sig_row("messages", message_id)
    }

    /// [`Self::message_sig_row`] for the `channel_messages` table.
    pub fn get_channel_message_sig_row(&self, message_id: &str) -> Option<MessageSigRow> {
        self.message_sig_row("channel_messages", message_id)
    }

    pub fn set_channel_message_edited_at(&self, message_id: &str, edited_at: i64) -> Result<(), String> {
        self.conn.execute(
            "UPDATE channel_messages SET edited_at = ?1 WHERE message_id = ?2 AND edited_at IS NULL",
            params![edited_at, message_id],
        ).map_err(|e| format!("set_channel_message_edited_at: {e}"))?;
        Ok(())
    }

    /// `dev` = the edit's verified device proof: the row keeps the proof of the version
    /// it holds, or none (a post's proof never vouches for an edit's words).
    pub fn edit_channel_message(
        &self,
        message_id: &str,
        new_text: &str,
        edited_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
        dev: Option<&crate::crdt::operations::DevProof>,
    ) -> Result<bool, String> {
        self.edit_message_in("channel_messages", message_id, new_text, edited_at, signature, public_key, Some(dev))
    }

    /// Shared implementation of the edit methods. `table` is a fixed table name, never
    /// user input. Preserves the previous text and signature provenance in
    /// message_edits before overwriting, in one transaction.
    #[allow(clippy::too_many_arguments)]
    fn edit_message_in(
        &self,
        table: &str,
        message_id: &str,
        new_text: &str,
        edited_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
        proof: Option<Option<&crate::crdt::operations::DevProof>>,
    ) -> Result<bool, String> {
        // text, signature, public key, previous timestamp, last edit
        type EditRow = (String, Option<String>, Option<String>, i64, Option<i64>);
        let row: Option<EditRow> = self
            .conn
            .query_row(
                &format!("SELECT text, signature, public_key, COALESCE(edited_at, timestamp), edited_at FROM {table} WHERE message_id = ?1"),
                params![message_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
            )
            .ok();

        let Some((old_text, prev_sig, prev_pk, prev_ts, prev_edit)) = row else {
            return Ok(false); // Message not found.
        };

        if old_text == new_text {
            return Ok(false); // No change.
        }
        // Every edit is signed with its own time, so an older one replayed (the
        // relay holds every plaintext copy, sync serves stale ones) would put back
        // text its author already replaced (B10).
        if prev_edit.is_some_and(|prev| edited_at <= prev) {
            return Ok(false);
        }

        // A savepoint, since sync applies an edit inside its own batch transaction.
        self.conn.execute_batch("SAVEPOINT edit_message").map_err(|e| format!("SAVEPOINT: {e}"))?;
        let undo = || self.conn.execute_batch("ROLLBACK TO edit_message; RELEASE edit_message");

        if let Err(e) = self.conn.execute(
            "INSERT INTO message_edits (message_id, old_text, new_text, edited_at, signature, public_key, prev_signature, prev_public_key, prev_timestamp)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![message_id, old_text, new_text, edited_at, signature, public_key, prev_sig, prev_pk, prev_ts],
        ) {
            let _ = undo();
            return Err(format!("Failed to insert edit history: {e}"));
        }

        let result = match proof {
            None => self.conn.execute(
                &format!("UPDATE {table} SET text = ?1, edited_at = ?2, signature = ?3, public_key = ?4, updated_at = ?2 WHERE message_id = ?5"),
                params![new_text, edited_at, signature, public_key, message_id],
            ),
            Some(dev) => self.conn.execute(
                &format!("UPDATE {table} SET text = ?1, edited_at = ?2, signature = ?3, public_key = ?4, updated_at = ?2, dev_device = ?6, dev_sig = ?7 WHERE message_id = ?5"),
                params![new_text, edited_at, signature, public_key, message_id, dev.map(|d| &d.device), dev.map(|d| &d.sig)],
            ),
        };

        match result {
            Ok(rows) => {
                let _ = self.conn.execute_batch("RELEASE edit_message");
                Ok(rows > 0)
            }
            Err(e) => {
                let _ = undo();
                Err(format!("Failed to update {table} row: {e}"))
            }
        }
    }

    /// Repair a channel message's attributed sender and signature material
    /// (multi-device self-heal). A row stored before the device-to-master resolve fix
    /// can be keyed under a sender DEVICE id with signature material that no longer
    /// verifies against the master-id payload; when sync later delivers the SAME message
    /// id with a signature that DOES verify, the caller overwrites the local row with
    /// the verified values. `INSERT OR IGNORE` blocks re-inserting the corrupt row, so
    /// this UPDATE is the only way to converge it.
    pub fn repair_channel_message_sender(
        &self,
        message_id: &str,
        sender_id: &str,
        is_mine: bool,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        self.conn
            .execute(
                "UPDATE channel_messages SET sender_id = ?1, is_mine = ?2, signature = ?3, public_key = ?4 WHERE message_id = ?5",
                params![sender_id, is_mine as i32, signature, public_key, message_id],
            )
            .map(|rows| rows > 0)
            .map_err(|e| format!("repair_channel_message_sender: {e}"))
    }

    /// Edit a DM message by message_id. Preserves old text in message_edits table.
    /// Returns true if the message was found and updated.
    pub fn set_dm_message_edited_at(&self, message_id: &str, edited_at: i64) -> Result<(), String> {
        self.conn.execute(
            "UPDATE messages SET edited_at = ?1 WHERE message_id = ?2 AND edited_at IS NULL",
            params![edited_at, message_id],
        ).map_err(|e| format!("set_dm_message_edited_at: {e}"))?;
        Ok(())
    }

    pub fn edit_dm_message(
        &self,
        message_id: &str,
        new_text: &str,
        edited_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        self.edit_message_in("messages", message_id, new_text, edited_at, signature, public_key, None)
    }

    // ── Message Deletion / Hiding (Phase 3.5) ──

    /// Hide a channel message, preserving its text in message_deletions. The row stays
    /// in the DB as evidence but is filtered out of UI queries.
    pub fn hide_channel_message(
        &self,
        message_id: &str,
        deleted_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        self.hide_message_in("channel_messages", message_id, deleted_at, signature, public_key)
    }

    /// Hide a DM message by message_id. Preserves text in message_deletions table.
    /// Returns true if the message was found and hidden.
    pub fn hide_dm_message(
        &self,
        message_id: &str,
        deleted_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        self.hide_message_in("messages", message_id, deleted_at, signature, public_key)
    }

    /// Shared implementation of the hide methods. `table` is a fixed table name, never
    /// user input.
    fn hide_message_in(
        &self,
        table: &str,
        message_id: &str,
        deleted_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        let text: Option<String> = self
            .conn
            .query_row(
                &format!("SELECT text FROM {table} WHERE message_id = ?1"),
                params![message_id],
                |row| row.get(0),
            )
            .ok();

        let Some(text) = text else {
            return Ok(false); // Message not found.
        };

        self.conn
            .execute(
                "INSERT INTO message_deletions (message_id, deleted_text, deleted_at, signature, public_key)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![message_id, text, deleted_at, signature, public_key],
            )
            .map_err(|e| format!("Failed to insert deletion record: {e}"))?;

        let rows = self
            .conn
            .execute(
                &format!("UPDATE {table} SET hidden_at = ?1, updated_at = ?1 WHERE message_id = ?2"),
                params![deleted_at, message_id],
            )
            .map_err(|e| format!("Failed to hide {table} row: {e}"))?;

        Ok(rows > 0)
    }

    /// Lightweight hidden_at setter for channel messages during sync. Does NOT preserve
    /// evidence: the original deleter already did.
    pub fn set_channel_message_hidden(&self, message_id: &str, hidden_at: i64) -> Result<(), String> {
        self.set_message_hidden_in("channel_messages", message_id, hidden_at)
    }

    /// Lightweight hidden_at setter for DM messages during sync.
    pub fn set_dm_message_hidden(&self, message_id: &str, hidden_at: i64) -> Result<(), String> {
        self.set_message_hidden_in("messages", message_id, hidden_at)
    }

    /// Shared hidden_at setter. `table` is a fixed table name, never user input.
    fn set_message_hidden_in(&self, table: &str, message_id: &str, hidden_at: i64) -> Result<(), String> {
        self.conn
            .execute(
                &format!("UPDATE {table} SET hidden_at = ?1, updated_at = ?1 WHERE message_id = ?2"),
                params![hidden_at, message_id],
            )
            .map_err(|e| format!("Failed to set {table} hidden_at: {e}"))?;
        Ok(())
    }

    /// The stored deletion proof for a message from the latest SIGNED evidence row.
    /// `None` for pre-signing legacy deletions, which no longer propagate through sync.
    pub fn load_deletion_proof(&self, message_id: &str) -> Option<(i64, String, String)> {
        self.conn
            .query_row(
                "SELECT deleted_at, signature, public_key FROM message_deletions
                 WHERE message_id = ?1 AND signature IS NOT NULL AND public_key IS NOT NULL
                 ORDER BY id DESC LIMIT 1",
                params![message_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .ok()
    }

    /// `hidden_at` of a channel message row (`None` = visible or no such row).
    pub fn get_channel_message_hidden_at(&self, message_id: &str) -> Option<i64> {
        self.conn
            .query_row(
                "SELECT hidden_at FROM channel_messages WHERE message_id = ?1",
                params![message_id],
                |row| row.get(0),
            )
            .ok()
            .flatten()
    }

    /// `hidden_at` of a DM message row (`None` = visible or no such row).
    pub fn get_dm_message_hidden_at(&self, message_id: &str) -> Option<i64> {
        self.conn
            .query_row(
                "SELECT hidden_at FROM messages WHERE message_id = ?1",
                params![message_id],
                |row| row.get(0),
            )
            .ok()
            .flatten()
    }

    /// Sync-apply setter for a VERIFIED deletion: sets `hidden_at` and stores the proof
    /// once, so THIS node can re-serve the deletion. Without the store-forward,
    /// REJECT-ABSENT would stop deletions propagating past the first sync hop.
    pub fn set_channel_message_hidden_verified(
        &self,
        message_id: &str,
        hidden_at: i64,
        signature: &str,
        public_key: &str,
    ) -> Result<(), String> {
        self.set_message_hidden_verified_in("channel_messages", message_id, hidden_at, signature, public_key)
    }

    /// DM twin of [`Self::set_channel_message_hidden_verified`].
    pub fn set_dm_message_hidden_verified(
        &self,
        message_id: &str,
        hidden_at: i64,
        signature: &str,
        public_key: &str,
    ) -> Result<(), String> {
        self.set_message_hidden_verified_in("messages", message_id, hidden_at, signature, public_key)
    }

    /// Shared verified-hidden setter. `table` is a fixed name, never user input.
    /// Idempotent under re-apply: the evidence row is inserted only while none exists.
    fn set_message_hidden_verified_in(
        &self,
        table: &str,
        message_id: &str,
        hidden_at: i64,
        signature: &str,
        public_key: &str,
    ) -> Result<(), String> {
        let have_signed: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM message_deletions WHERE message_id = ?1 AND signature IS NOT NULL",
                params![message_id],
                |row| row.get(0),
            )
            .unwrap_or(0);
        if have_signed == 0 {
            let text: String = self
                .conn
                .query_row(
                    &format!("SELECT text FROM {table} WHERE message_id = ?1"),
                    params![message_id],
                    |row| row.get(0),
                )
                .unwrap_or_default();
            self.conn
                .execute(
                    "INSERT INTO message_deletions (message_id, deleted_text, deleted_at, signature, public_key)
                     VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![message_id, text, hidden_at, signature, public_key],
                )
                .map_err(|e| format!("Failed to store synced deletion proof: {e}"))?;
        }
        self.set_message_hidden_in(table, message_id, hidden_at)
    }

    // ── Emoji Reactions (Phase 3.5) ──────────────────────────────

    /// A stamp for our own add or removal of `emoji` on `message_id` that outranks
    /// every add and removal of it already recorded, whichever device's clock made them.
    pub fn next_reaction_stamp(&self, message_id: &str, emoji: &str, peer_id: &str) -> i64 {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        let held: Option<i64> = self
            .conn
            .query_row(
                "SELECT MAX(t) FROM (
                   SELECT added_at AS t FROM message_reactions WHERE message_id = ?1 AND emoji = ?2 AND peer_id = ?3
                   UNION ALL
                   SELECT removed_at FROM reaction_removals WHERE message_id = ?1 AND emoji = ?2 AND peer_id = ?3)",
                params![message_id, emoji, peer_id],
                |row| row.get(0),
            )
            .unwrap_or(None);
        held.map_or(now, |t| now.max(t.saturating_add(1)))
    }

    /// Add a reaction, at most 3 distinct emojis per user per message. Returns true only
    /// when a new reaction was inserted.
    pub fn add_reaction(
        &self,
        message_id: &str,
        emoji: &str,
        peer_id: &str,
        added_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(DISTINCT emoji) FROM message_reactions WHERE message_id = ?1 AND peer_id = ?2 AND emoji != ?3",
                params![message_id, peer_id, emoji],
                |row| row.get(0),
            )
            .unwrap_or(0);

        if count >= 3 {
            return Ok(false); // Limit reached.
        }
        // An add signed no later than its reactor's own removal is a replay or a
        // reordered copy, and would bring back a reaction they took away (B11).
        let removed_after: bool = self
            .conn
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM reaction_removals
                  WHERE message_id = ?1 AND emoji = ?2 AND peer_id = ?3 AND removed_at >= ?4)",
                params![message_id, emoji, peer_id, added_at],
                |row| row.get(0),
            )
            .unwrap_or(false);
        if removed_after {
            return Ok(false);
        }

        let rows = self
            .conn
            .execute(
                "INSERT OR IGNORE INTO message_reactions (message_id, emoji, peer_id, added_at, signature, public_key)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![message_id, emoji, peer_id, added_at, signature, public_key],
            )
            .map_err(|e| format!("Failed to add reaction: {e}"))?;
        Ok(rows > 0)
    }

    /// Remove a reaction, recording the removal as evidence. Returns true only when a
    /// reaction went.
    pub fn remove_reaction(
        &self,
        message_id: &str,
        emoji: &str,
        peer_id: &str,
        removed_at: i64,
        signature: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, String> {
        // Only a reaction added no later than the removal goes, or a replayed older
        // removal takes away a re-add (B11). A tie goes to the removal, as in
        // `add_reaction`, so both orders of delivery agree.
        let rows = self
            .conn
            .execute(
                "DELETE FROM message_reactions WHERE message_id = ?1 AND emoji = ?2 AND peer_id = ?3 AND added_at <= ?4",
                params![message_id, emoji, peer_id, removed_at],
            )
            .map_err(|e| format!("Failed to remove reaction: {e}"))?;

        // Record removal evidence (Rat Files), and the floor `add_reaction` checks,
        // even when the add has not arrived yet: a relay could deliver it second.
        self.conn
            .execute(
                "INSERT INTO reaction_removals (message_id, emoji, peer_id, removed_at, signature, public_key)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![message_id, emoji, peer_id, removed_at, signature, public_key],
            )
            .map_err(|e| format!("Failed to insert reaction removal record: {e}"))?;

        Ok(rows > 0)
    }

    /// Shared batch loader for the per-message evidence tables, grouping mapped rows by
    /// message_id. `table`/`cols`/`order_col` are fixed identifiers, never user input,
    /// and `map` reads the row STARTING AT INDEX 1, since index 0 is the message_id.
    fn load_grouped_by_message_id<T>(
        &self,
        table: &str,
        cols: &str,
        order_col: &str,
        message_ids: &[String],
        map: impl Fn(&rusqlite::Row<'_>) -> rusqlite::Result<T>,
    ) -> Result<HashMap<String, Vec<T>>, String> {
        if message_ids.is_empty() {
            return Ok(HashMap::new());
        }

        let placeholders: Vec<String> = message_ids.iter().enumerate().map(|(i, _)| format!("?{}", i + 1)).collect();
        let sql = format!(
            "SELECT message_id, {cols} FROM {table} WHERE message_id IN ({}) ORDER BY {order_col} ASC",
            placeholders.join(", ")
        );

        let mut stmt = self.conn.prepare(&sql)
            .map_err(|e| format!("Failed to prepare {table} batch query: {e}"))?;
        let params_vec: Vec<&dyn rusqlite::types::ToSql> = message_ids.iter().map(|s| s as &dyn rusqlite::types::ToSql).collect();
        let rows = stmt
            .query_map(params_vec.as_slice(), |row| {
                Ok((row.get::<_, String>(0)?, map(row)?))
            })
            .map_err(|e| format!("Failed to query {table}: {e}"))?;

        let mut result: HashMap<String, Vec<T>> = HashMap::new();
        for row in rows {
            let (mid, item) = row.map_err(|e| format!("Failed to read {table} row: {e}"))?;
            result.entry(mid).or_default().push(item);
        }
        Ok(result)
    }

    /// Load all reactions for a set of message IDs, keyed by message_id.
    pub fn load_reactions_for_messages(
        &self,
        message_ids: &[String],
    ) -> Result<HashMap<String, Vec<(String, String, i64)>>, String> {
        self.load_grouped_by_message_id(
            "message_reactions",
            "emoji, peer_id, added_at",
            "added_at",
            message_ids,
            |row| Ok((row.get(1)?, row.get(2)?, row.get(3)?)),
        )
    }

    /// Load all reactions with signatures for sync, keyed by message_id.
    pub fn load_reactions_for_sync(
        &self,
        message_ids: &[String],
    ) -> Result<HashMap<String, Vec<SignedEmojiRow>>, String> {
        self.load_grouped_by_message_id(
            "message_reactions",
            "emoji, peer_id, added_at, signature, public_key",
            "added_at",
            message_ids,
            |row| Ok((row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?)),
        )
    }

    // ── Archive queries ─────────────────────────────────────────

    /// Load ALL DM messages for a peer including hidden ones, oldest-first and
    /// unlimited, for the archive exporter.
    pub fn load_all_dm_messages(
        &self,
        peer_id: &str,
    ) -> Result<Vec<StoredMessage>, String> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "SELECT {DM_MSG_COLS}
                 FROM messages
                 WHERE peer_id = ?1
                 ORDER BY timestamp ASC, id ASC",
            ))
            .map_err(|e| format!("Failed to prepare load_all_dm_messages query: {e}"))?;

        let rows = stmt
            .query_map(params![peer_id], dm_message_from_row)
            .map_err(|e| format!("Failed to query all DM messages: {e}"))?;

        collect_rows(rows, "DM message")
    }

    /// Load ALL channel messages including hidden ones, oldest-first and unlimited, for
    /// the archive exporter.
    pub fn load_all_channel_messages(
        &self,
        server_id: &str,
        channel_id: &str,
    ) -> Result<Vec<StoredChannelMessage>, String> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "SELECT {CHANNEL_MSG_COLS}
                 FROM channel_messages
                 WHERE server_id = ?1 AND channel_id = ?2
                 ORDER BY timestamp ASC, id ASC",
            ))
            .map_err(|e| format!("Failed to prepare load_all_channel_messages query: {e}"))?;

        let rows = stmt
            .query_map(params![server_id, channel_id], channel_message_from_row)
            .map_err(|e| format!("Failed to query all channel messages: {e}"))?;

        collect_rows(rows, "channel message")
    }

    /// Load edit history for a batch of message IDs, keyed by message_id.
    pub fn load_edits_for_messages(
        &self,
        message_ids: &[String],
    ) -> Result<HashMap<String, Vec<(String, String, i64, Option<String>, Option<String>, Option<String>, Option<String>, Option<i64>)>>, String> {
        self.load_grouped_by_message_id(
            "message_edits",
            "old_text, new_text, edited_at, signature, public_key, prev_signature, prev_public_key, prev_timestamp",
            "edited_at",
            message_ids,
            |row| Ok((
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
                row.get(6)?,
                row.get(7)?,
                row.get(8)?,
            )),
        )
    }

    /// Load deletion evidence for a batch of message IDs, keyed by message_id.
    pub fn load_deletions_for_messages(
        &self,
        message_ids: &[String],
    ) -> Result<HashMap<String, Vec<(String, i64, Option<String>, Option<String>)>>, String> {
        self.load_grouped_by_message_id(
            "message_deletions",
            "deleted_text, deleted_at, signature, public_key",
            "deleted_at",
            message_ids,
            |row| Ok((row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
        )
    }

    /// Load reaction removal evidence for a batch of message IDs, keyed by message_id.
    pub fn load_reaction_removals_for_messages(
        &self,
        message_ids: &[String],
    ) -> Result<HashMap<String, Vec<SignedEmojiRow>>, String> {
        self.load_grouped_by_message_id(
            "reaction_removals",
            "emoji, peer_id, removed_at, signature, public_key",
            "removed_at",
            message_ids,
            |row| Ok((row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?)),
        )
    }

    // ── App Settings ──────────────────────────────────────────────

    /// Save a key-value setting (insert or update).
    // ── Search ────────────────────────────────────────────────────

    /// Search channel messages via the FTS5 index, falling back to LIKE on a match error.
    pub fn search_channel_messages(
        &self,
        server_id: &str,
        channel_id: &str,
        query: &str,
        limit: i32,
    ) -> Result<Vec<StoredChannelMessage>, String> {
        let fts_query = query.replace('"', "\"\"");
        let fts_pattern = format!("\"{}\"", fts_query);
        let mut stmt = self
            .conn
            .prepare(
                "SELECT cm.id, cm.server_id, cm.channel_id, cm.sender_id, cm.text, cm.is_mine, cm.timestamp, cm.signature, cm.public_key, cm.message_id, cm.edited_at, cm.hidden_at, cm.reply_to_mid, cm.file_id, cm.link_preview_json, cm.order_us, cm.album_id
                 FROM channel_messages cm
                 JOIN channel_messages_fts fts ON cm.id = fts.rowid
                 WHERE fts.text MATCH ?3 AND cm.server_id = ?1 AND cm.channel_id = ?2 AND cm.hidden_at IS NULL
                 ORDER BY cm.id DESC
                 LIMIT ?4",
            )
            .map_err(|e| format!("Failed to prepare FTS search query: {e}"))?;

        let rows = stmt
            .query_map(params![server_id, channel_id, fts_pattern, limit], channel_message_from_row)
            .map_err(|e| format!("Failed to search messages: {e}"))?;

        let mut messages = collect_rows(rows, "search")?;
        messages.reverse();
        Ok(messages)
    }

    /// Search DM messages by text content using FTS5 index.
    pub fn search_dm_messages(
        &self,
        peer_id: &str,
        query: &str,
        limit: i32,
    ) -> Result<Vec<StoredMessage>, String> {
        let fts_query = query.replace('"', "\"\"");
        let fts_pattern = format!("\"{}\"", fts_query);
        let mut stmt = self
            .conn
            .prepare(
                "SELECT m.id, m.peer_id, m.text, m.is_mine, m.timestamp, m.signature, m.public_key, m.message_id, m.edited_at, m.hidden_at, m.reply_to_mid, m.file_id, m.link_preview_json, m.order_us, m.album_id
                 FROM messages m
                 JOIN messages_fts fts ON m.id = fts.rowid
                 WHERE fts.text MATCH ?2 AND m.peer_id = ?1 AND m.hidden_at IS NULL
                 ORDER BY m.id DESC
                 LIMIT ?3",
            )
            .map_err(|e| format!("Failed to prepare FTS DM search query: {e}"))?;

        let rows = stmt
            .query_map(params![peer_id, fts_pattern, limit], dm_message_from_row)
            .map_err(|e| format!("Failed to search DM messages: {e}"))?;

        let mut messages = collect_rows(rows, "DM search")?;
        messages.reverse();
        Ok(messages)
    }

    // ── Friends ───────────────────────────────────────────────────

    /// Save or update a friend entry.
    pub fn save_friend(
        &self,
        peer_id: &str,
        status: &str,
        direction: &str,
        requested_at: i64,
    ) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                // `requested_at` ADVANCES on a pending row and is FROZEN on every other status,
                // because it is what every dedup and anti-downgrade guard measures against: a
                // pending row keeping its first value makes a genuinely newer request look newer
                // than the store on every re-delivery, so the mailbox replays it and the receiver
                // re-notifies forever. MAX(), not blind assign, so an out-of-order older copy never
                // walks the row backwards. Accepted and declined rows keep their ORIGINAL time: the
                // declined tombstone IS the freshness baseline a re-add has to beat. A card
                // thumb outlives only a pending or accepted row.
                "INSERT INTO friends (peer_id, status, direction, requested_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(peer_id) DO UPDATE SET
                   status = ?2, direction = ?3,
                   requested_at = CASE WHEN ?2 = 'pending'
                                       THEN MAX(requested_at, ?4)
                                       ELSE requested_at END,
                   updated_at = ?5,
                   card_thumb = CASE WHEN ?2 IN ('pending', 'accepted') THEN card_thumb END",
                params![peer_id, status, direction, requested_at, now],
            )
            .map_err(|e| format!("Failed to save friend: {e}"))?;
        Ok(())
    }

    /// Keep the avatar thumbnail a sealed card carried, only on the pending row of the
    /// request it came with. Returns whether the row changed.
    pub fn set_friend_card_thumb(
        &self,
        peer_id: &str,
        direction: &str,
        requested_at: i64,
        thumb: Option<&[u8]>,
    ) -> Result<bool, String> {
        self.conn
            .execute(
                "UPDATE friends SET card_thumb = ?4
                 WHERE peer_id = ?1 AND status = 'pending' AND direction = ?2 AND requested_at = ?3
                   AND card_thumb IS NOT ?4",
                params![peer_id, direction, requested_at, thumb],
            )
            .map(|n| n > 0)
            .map_err(|e| format!("Failed to save card thumb: {e}"))
    }

    /// Drop a friend's card thumb once a full profile or a newer card decides the avatar.
    fn retire_card_thumb(&self, peer_id: &str) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE friends SET card_thumb = NULL WHERE peer_id = ?1 AND card_thumb IS NOT NULL",
                params![peer_id],
            )
            .map(|_| ())
            .map_err(|e| format!("Failed to retire card thumb: {e}"))
    }

    /// Remove a friend entry entirely.
    pub fn remove_friend(&self, peer_id: &str) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM friends WHERE peer_id = ?1", params![peer_id])
            .map_err(|e| format!("Failed to remove friend: {e}"))?;
        Ok(())
    }

    /// Re-key a friend row from a DEVICE id to its MASTER id once the mapping is known.
    /// Friendships must key on the master (presence, DM and profile all do), but a
    /// friend added by TEMPORARY NICKNAME lands under the device id, because the relay
    /// claims nicknames under the WS-auth device socket.
    ///
    /// When a master row already exists: keep `accepted` over `pending`, keep the
    /// earliest non-zero `requested_at`, then delete the device row.
    pub fn migrate_friend_to_master(&self, device: &str, master: &str) -> Result<bool, String> {
        if device == master {
            return Ok(false);
        }
        let dev_row: Option<(String, String, i64)> = self
            .conn
            .query_row(
                "SELECT status, direction, requested_at FROM friends WHERE peer_id = ?1",
                params![device],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?)),
            )
            .ok();
        let Some((dev_status, dev_dir, dev_req)) = dev_row else {
            return Ok(false);
        };
        let mas_row: Option<(String, String, i64)> = self
            .conn
            .query_row(
                "SELECT status, direction, requested_at FROM friends WHERE peer_id = ?1",
                params![master],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?)),
            )
            .ok();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        let (status, direction, requested_at) = match mas_row {
            Some((m_status, m_dir, m_req)) => {
                // Prefer accepted; otherwise keep the master row's status.
                let status = if m_status == "accepted" || dev_status == "accepted" {
                    "accepted".to_string()
                } else {
                    m_status
                };
                let direction = if !m_dir.is_empty() { m_dir } else { dev_dir };
                let requested_at = match (m_req, dev_req) {
                    (0, d) => d,
                    (m, 0) => m,
                    (m, d) => m.min(d),
                };
                (status, direction, requested_at)
            }
            None => (dev_status, dev_dir, dev_req),
        };
        self.conn
            .execute(
                "INSERT INTO friends (peer_id, status, direction, requested_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(peer_id) DO UPDATE SET status = ?2, direction = ?3,
                     requested_at = ?4, updated_at = ?5",
                params![master, status, direction, requested_at, now],
            )
            .map_err(|e| format!("Failed to upsert master friend row: {e}"))?;
        self.conn
            .execute("DELETE FROM friends WHERE peer_id = ?1", params![device])
            .map_err(|e| format!("Failed to delete device friend row: {e}"))?;
        Ok(true)
    }

    /// Load all friends as (peer_id, status, direction, requested_at, updated_at).
    pub fn load_friends(
        &self,
        status_filter: Option<&str>,
    ) -> Result<Vec<(String, String, String, i64, i64)>, String> {
        let (sql, params_vec): (String, Vec<Box<dyn rusqlite::types::ToSql>>) = if let Some(s) = status_filter {
            (
                "SELECT peer_id, status, direction, requested_at, updated_at FROM friends WHERE status = ?1 ORDER BY updated_at DESC".into(),
                vec![Box::new(s.to_string())],
            )
        } else {
            (
                "SELECT peer_id, status, direction, requested_at, updated_at FROM friends ORDER BY updated_at DESC".into(),
                vec![],
            )
        };

        let params_refs: Vec<&dyn rusqlite::types::ToSql> = params_vec.iter().map(|p| p.as_ref()).collect();
        let mut stmt = self.conn.prepare(&sql).map_err(|e| format!("Failed to prepare friends query: {e}"))?;
        let rows = stmt
            .query_map(params_refs.as_slice(), |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                ))
            })
            .map_err(|e| format!("Failed to query friends: {e}"))?;

        collect_rows(rows, "friend")
    }

    // ── Parked server joins ───────────────────────────────────────

    /// Insert or replace a pending or rejected join row. `created_at` survives a repeat
    /// request so the tile keeps saying when you first asked, while `requested_at`
    /// becomes the new nonce.
    pub fn upsert_pending_join(&self, row: &PendingJoinRow) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO pending_server_joins
                    (server_id, requested_at, nsfw_confirmed, twitch_proof_json,
                     state, reason, last_deposited_at, created_at, key_package, owner_pin,
                     join_key, reply_secret)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                 ON CONFLICT(server_id) DO UPDATE SET
                    requested_at      = excluded.requested_at,
                    nsfw_confirmed    = excluded.nsfw_confirmed,
                    twitch_proof_json = excluded.twitch_proof_json,
                    state             = excluded.state,
                    reason            = excluded.reason,
                    last_deposited_at = excluded.last_deposited_at,
                    key_package       = excluded.key_package,
                    owner_pin         = excluded.owner_pin,
                    join_key          = excluded.join_key,
                    reply_secret      = excluded.reply_secret",
                params![
                    row.server_id,
                    row.requested_at,
                    row.nsfw_confirmed as i64,
                    row.twitch_proof_json,
                    row.state,
                    row.reason,
                    row.last_deposited_at,
                    row.created_at,
                    row.key_package,
                    row.owner_pin,
                    row.join_key,
                    row.reply_secret,
                ],
            )
            .map_err(|e| format!("Failed to upsert pending join: {e}"))?;
        Ok(())
    }

    /// Forget a pending join entirely (completed, or discarded by the user).
    pub fn delete_pending_join(&self, server_id: &str) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM pending_server_joins WHERE server_id = ?1", params![server_id])
            .map_err(|e| format!("Failed to delete pending join: {e}"))?;
        Ok(())
    }

    /// Every stored pending/rejected join, newest ask first.
    pub fn load_pending_joins(&self) -> Result<Vec<PendingJoinRow>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT server_id, requested_at, nsfw_confirmed, twitch_proof_json,
                        state, reason, last_deposited_at, created_at, key_package, owner_pin,
                        join_key, reply_secret
                 FROM pending_server_joins ORDER BY requested_at DESC",
            )
            .map_err(|e| format!("Failed to prepare pending join query: {e}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok(PendingJoinRow {
                    server_id: row.get(0)?,
                    requested_at: row.get(1)?,
                    nsfw_confirmed: row.get::<_, i64>(2)? != 0,
                    twitch_proof_json: row.get(3)?,
                    state: row.get(4)?,
                    reason: row.get(5)?,
                    last_deposited_at: row.get(6)?,
                    created_at: row.get(7)?,
                    key_package: row.get(8)?,
                    owner_pin: row.get(9)?,
                    join_key: row.get(10)?,
                    reply_secret: row.get(11)?,
                })
            })
            .map_err(|e| format!("Failed to query pending joins: {e}"))?;
        collect_rows(rows, "pending join")
    }

    /// Check if a peer is a friend (any status).
    pub fn get_friend_status(&self, peer_id: &str) -> Result<Option<String>, String> {
        let result = self.conn.query_row(
            "SELECT status FROM friends WHERE peer_id = ?1",
            params![peer_id],
            |row| row.get(0),
        );
        match result {
            Ok(s) => Ok(Some(s)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(format!("Failed to check friend status: {e}")),
        }
    }

    /// `(status, direction)` for a friend row, used to detect a MUTUAL request: an
    /// inbound request arriving while ours is `("pending", "outgoing")` means both sides
    /// asked and should converge to friends.
    pub fn get_friend_status_direction(
        &self,
        peer_id: &str,
    ) -> Result<Option<(String, String)>, String> {
        let result = self.conn.query_row(
            "SELECT status, direction FROM friends WHERE peer_id = ?1",
            params![peer_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        );
        match result {
            Ok(sd) => Ok(Some(sd)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(format!("Failed to read friend row: {e}")),
        }
    }

    /// `(status, direction, requested_at)` for a friend row. The anti-downgrade guard
    /// needs `requested_at` to tell a duplicate mailbox re-delivery from a genuine
    /// re-request, which is strictly newer and must refresh.
    pub fn get_friend_row(
        &self,
        peer_id: &str,
    ) -> Result<Option<(String, String, i64)>, String> {
        let result = self.conn.query_row(
            "SELECT status, direction, requested_at FROM friends WHERE peer_id = ?1",
            params![peer_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            },
        );
        match result {
            Ok(sdr) => Ok(Some(sdr)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(format!("Failed to read friend row: {e}")),
        }
    }

    // ── Blocked peers (local block list, MASTER-keyed) ───────────

    /// Block `master_peer_id` now. The stamp outranks any lifting we hold, even one a
    /// sibling with a clock ahead of ours stamped, or our devices would share the
    /// lifting as the newer word and undo this block.
    pub fn block_peer(&self, master_peer_id: &str) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
            .max(self.block_lifted_at(master_peer_id).saturating_add(1));
        self.conn
            .execute(
                "INSERT INTO blocked_peers (peer_id, blocked_at) VALUES (?1, ?2)
                 ON CONFLICT(peer_id) DO NOTHING",
                params![master_peer_id, now],
            )
            .map_err(|e| format!("Failed to block peer: {e}"))?;
        Ok(())
    }

    /// Block `master_peer_id` as of `at`, as one of our own devices did; an existing
    /// block keeps its own time.
    pub fn block_peer_at(&self, master_peer_id: &str, at: i64) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO blocked_peers (peer_id, blocked_at) VALUES (?1, ?2)
                 ON CONFLICT(peer_id) DO NOTHING",
                params![master_peer_id, at],
            )
            .map_err(|e| format!("Failed to block peer: {e}"))?;
        Ok(())
    }

    /// Lift a block, remembering when: our other devices must not bring an older block
    /// of the same person back. The stamp outranks the block it lifts, as in
    /// [`Self::block_peer`].
    pub fn unblock_peer(&self, master_peer_id: &str) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
            .max(self.blocked_at(master_peer_id).unwrap_or(0).saturating_add(1));
        self.unblock_peer_at(master_peer_id, now)
    }

    /// When the block of `master_peer_id` we hold was made, if we hold one.
    pub fn blocked_at(&self, master_peer_id: &str) -> Option<i64> {
        self.conn
            .query_row(
                "SELECT blocked_at FROM blocked_peers WHERE peer_id = ?1",
                params![master_peer_id],
                |row| row.get::<_, i64>(0),
            )
            .ok()
    }

    /// [`Self::unblock_peer`] as of `at`; a later lifting already noted keeps its time.
    pub fn unblock_peer_at(&self, master_peer_id: &str, at: i64) -> Result<(), String> {
        self.conn
            .execute(
                "DELETE FROM blocked_peers WHERE peer_id = ?1",
                params![master_peer_id],
            )
            .map_err(|e| format!("Failed to unblock peer: {e}"))?;
        let at = at.max(self.block_lifted_at(master_peer_id));
        self.save_setting(&format!("{BLOCK_LIFTED_PREFIX}{master_peer_id}"), &at.to_string())
    }

    /// When a block of `master_peer_id` was last lifted, 0 if never.
    pub fn block_lifted_at(&self, master_peer_id: &str) -> i64 {
        self.load_setting(&format!("{BLOCK_LIFTED_PREFIX}{master_peer_id}"))
            .ok()
            .flatten()
            .and_then(|v| v.parse().ok())
            .unwrap_or(0)
    }

    /// Every block lifted, as (master, when).
    pub fn lifted_blocks(&self) -> Vec<(String, i64)> {
        self.load_settings_with_prefix(BLOCK_LIFTED_PREFIX)
            .unwrap_or_default()
            .into_iter()
            .filter_map(|(key, at)| Some((key.strip_prefix(BLOCK_LIFTED_PREFIX)?.to_string(), at.parse().ok()?)))
            .collect()
    }

    /// Every block, as (master, since when).
    pub fn blocked_rows(&self) -> Result<Vec<(String, i64)>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT peer_id, blocked_at FROM blocked_peers")
            .map_err(|e| format!("Failed to prepare blocked query: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))
            .map_err(|e| format!("Failed to query blocked peers: {e}"))?;
        collect_rows(rows, "blocked")
    }

    /// All blocked master peer_ids, newest first.
    pub fn load_blocked_peers(&self) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT peer_id FROM blocked_peers ORDER BY blocked_at DESC")
            .map_err(|e| format!("Failed to prepare blocked query: {e}"))?;
        let rows = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query blocked peers: {e}"))?;
        collect_rows(rows, "blocked")
    }

    // ── Conference rooms (host-local; reports/shipped/voice-and-media/CONFERENCES_PLAN.md) ───

    pub fn upsert_conference(&self, row: &ConferenceRow) -> Result<(), String> {
        self.conn.execute(
            "INSERT INTO conferences (conf_id, name, waiting_room, access_code_hash, co_hosts, broadcast_mode, created_at, host_nonce, link_key)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
             ON CONFLICT(conf_id) DO UPDATE SET
                name = excluded.name,
                waiting_room = excluded.waiting_room,
                access_code_hash = excluded.access_code_hash,
                co_hosts = excluded.co_hosts,
                broadcast_mode = excluded.broadcast_mode,
                host_nonce = COALESCE(conferences.host_nonce, excluded.host_nonce),
                link_key = COALESCE(conferences.link_key, excluded.link_key)",
            rusqlite::params![
                row.conf_id, row.name, row.waiting_room as i64,
                row.access_code_hash, row.co_hosts, row.broadcast_mode as i64,
                row.created_at, row.host_nonce, row.link_key,
            ],
        ).map_err(|e| format!("Failed to upsert conference: {e}"))?;
        Ok(())
    }

    pub fn list_conferences(&self) -> Result<Vec<ConferenceRow>, String> {
        let mut stmt = self.conn.prepare(
            "SELECT conf_id, name, waiting_room, access_code_hash, co_hosts, broadcast_mode, created_at, host_nonce, link_key
             FROM conferences ORDER BY created_at DESC",
        ).map_err(|e| format!("Failed to prepare conference query: {e}"))?;
        let rows = stmt.query_map([], |row| {
            Ok(ConferenceRow {
                conf_id: row.get(0)?,
                name: row.get(1)?,
                waiting_room: row.get::<_, i64>(2)? != 0,
                access_code_hash: row.get(3)?,
                co_hosts: row.get(4)?,
                broadcast_mode: row.get::<_, i64>(5)? != 0,
                created_at: row.get(6)?,
                host_nonce: row.get(7)?,
                link_key: row.get(8)?,
            })
        }).map_err(|e| format!("Failed to query conferences: {e}"))?;
        collect_rows(rows, "conference")
    }

    pub fn get_conference(&self, conf_id: &str) -> Result<Option<ConferenceRow>, String> {
        Ok(self.list_conferences()?.into_iter().find(|c| c.conf_id == conf_id))
    }

    pub fn delete_conference(&self, conf_id: &str) -> Result<(), String> {
        self.conn.execute(
            "DELETE FROM conferences WHERE conf_id = ?1",
            rusqlite::params![conf_id],
        ).map_err(|e| format!("Failed to delete conference: {e}"))?;
        Ok(())
    }

    // ── Content-addressed asset blobs (emotes, banners, stickers, GIFs)
    //    + the personal emote set ───

    pub fn save_emote_blob(&self, hash: &str, bytes: &[u8], animated: bool) -> Result<(), String> {
        self.save_asset_blob(hash, bytes, animated, "emote")
    }

    /// Cache a content-addressed asset blob. `kind` is local bookkeeping for per-kind
    /// caps and eviction and never rides the wire.
    pub fn save_asset_blob(
        &self,
        hash: &str,
        bytes: &[u8],
        animated: bool,
        kind: &str,
    ) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        self.conn
            .execute(
                "INSERT INTO emote_blobs (hash, bytes, animated, added_at, kind)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(hash) DO NOTHING",
                params![hash, bytes, animated as i64, now, kind],
            )
            .map_err(|e| format!("Failed to save asset blob: {e}"))?;
        Ok(())
    }

    /// Record one file imported from a `.hollowpack`; the bytes went onto the asset rail
    /// under their hash and this is the provenance beside them. Idempotent by hash: a
    /// buyer who re-downloads their order still owns the art once.
    #[allow(clippy::too_many_arguments)]
    pub fn save_owned_art(
        &self,
        hash: &str,
        role: &str,
        item_id: &str,
        title: &str,
        artist_name: &str,
        artist_slug: &str,
        artist_url: &str,
        license: &str,
    ) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        self.conn
            .execute(
                "INSERT INTO owned_art
                   (hash, role, item_id, title, artist_name, artist_slug, artist_url, license, imported_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 ON CONFLICT(hash) DO UPDATE SET
                   role = excluded.role,
                   item_id = excluded.item_id,
                   title = excluded.title,
                   artist_name = excluded.artist_name,
                   artist_slug = excluded.artist_slug,
                   artist_url = excluded.artist_url,
                   license = excluded.license",
                params![
                    hash, role, item_id, title, artist_name, artist_slug, artist_url, license, now
                ],
            )
            .map_err(|e| format!("Failed to record owned art: {e}"))?;
        Ok(())
    }

    /// Every imported piece of shop art, newest first.
    #[allow(clippy::type_complexity)]
    pub fn list_owned_art(
        &self,
    ) -> Result<Vec<(String, String, String, String, String, String, String, String, i64)>, String>
    {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT hash, role, item_id, title, artist_name, artist_slug, artist_url,
                        license, imported_at
                 FROM owned_art ORDER BY imported_at DESC, hash ASC",
            )
            .map_err(|e| format!("Failed to prepare owned art list: {e}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, String>(7)?,
                    row.get::<_, i64>(8)?,
                ))
            })
            .map_err(|e| format!("Failed to list owned art: {e}"))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r.map_err(|e| format!("Failed to read owned art row: {e}"))?);
        }
        Ok(out)
    }

    /// Forgets one imported item (every file of it). Its bytes leave the evictor's
    /// keep-set, so they go the way of any cached asset unless something still wears
    /// them; importing the pack again restores the item.
    pub fn delete_owned_art_item(&self, item_id: &str) -> Result<usize, String> {
        self.conn
            .execute("DELETE FROM owned_art WHERE item_id = ?1", params![item_id])
            .map_err(|e| format!("Failed to remove owned art: {e}"))
    }

    /// The hash of every piece of shop art this install owns, feeding the evictor's
    /// keep-set: art somebody PAID for is never a cache entry, and there is no peer to
    /// re-pull it from.
    pub fn owned_art_hashes(&self) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT hash FROM owned_art")
            .map_err(|e| format!("Failed to prepare owned art hash scan: {e}"))?;
        let rows = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to scan owned art hashes: {e}"))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// Keep one redeem code from a `hollow://redeem/<code>` deep link. Returns whether a
    /// row was written: keeping the same code twice is a no-op, not an error. The caller
    /// has already checked the code's shape and the row cap.
    pub fn save_redeem_code(&self, code: &str) -> Result<bool, String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        let changed = self
            .conn
            .execute(
                "INSERT OR IGNORE INTO redeem_codes (code, received_at) VALUES (?1, ?2)",
                params![code, now],
            )
            .map_err(|e| format!("Failed to keep redeem code: {e}"))?;
        Ok(changed > 0)
    }

    /// Every kept redeem code, newest first.
    pub fn list_redeem_codes(&self) -> Result<Vec<(String, i64)>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT code, received_at FROM redeem_codes
                 ORDER BY received_at DESC, code ASC",
            )
            .map_err(|e| format!("Failed to prepare redeem code list: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))
            .map_err(|e| format!("Failed to list redeem codes: {e}"))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// Forget one kept redeem code. Deleting one never kept is not an error.
    pub fn delete_redeem_code(&self, code: &str) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM redeem_codes WHERE code = ?1", params![code])
            .map_err(|e| format!("Failed to forget redeem code: {e}"))?;
        Ok(())
    }

    /// How many redeem codes are kept. The cap is enforced against this.
    pub fn count_redeem_codes(&self) -> Result<u32, String> {
        self.conn
            .query_row("SELECT COUNT(*) FROM redeem_codes", [], |row| {
                Ok(row.get::<_, i64>(0)?.max(0) as u32)
            })
            .map_err(|e| format!("Failed to count redeem codes: {e}"))
    }

    /// Keep one of OUR support credentials, upserting by item: a second redemption for
    /// the same item replaces the entry.
    pub fn save_own_support_cred(
        &self,
        item: &str,
        entry_json: &str,
        slug: &str,
        title: &str,
        artist_name: &str,
    ) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        self.conn
            .execute(
                "INSERT INTO support_creds_own (item, entry_json, slug, title, artist_name, redeemed_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(item) DO UPDATE SET
                   entry_json = excluded.entry_json,
                   slug = excluded.slug,
                   title = excluded.title,
                   artist_name = excluded.artist_name,
                   redeemed_at = excluded.redeemed_at",
                params![item, entry_json, slug, title, artist_name, now],
            )
            .map_err(|e| format!("Failed to keep the support credential: {e}"))?;
        Ok(())
    }

    /// Rewrite the stored entry of one of our credentials, the only way to amend a kept
    /// row in place. Nothing calls it today.
    pub fn update_own_support_cred_entry(&self, item: &str, entry_json: &str) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE support_creds_own SET entry_json = ?2 WHERE item = ?1",
                params![item, entry_json],
            )
            .map_err(|e| format!("Failed to update the support credential: {e}"))?;
        Ok(())
    }

    /// Every credential this identity holds, newest first.
    #[allow(clippy::type_complexity)]
    pub fn list_own_support_creds(
        &self,
    ) -> Result<Vec<(String, String, String, String, String, i64)>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT item, entry_json, slug, title, artist_name, redeemed_at
                 FROM support_creds_own ORDER BY redeemed_at DESC, item ASC",
            )
            .map_err(|e| format!("Failed to prepare support credential list: {e}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, i64>(5)?,
                ))
            })
            .map_err(|e| format!("Failed to list support credentials: {e}"))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r.map_err(|e| format!("Failed to read support credential row: {e}"))?);
        }
        Ok(out)
    }

    /// Forget one of our credentials. Not offered in the UI, since a credential cannot
    /// be re-minted; the tests need a way.
    pub fn delete_own_support_cred(&self, item: &str) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM support_creds_own WHERE item = ?1", params![item])
            .map_err(|e| format!("Failed to forget the support credential: {e}"))?;
        Ok(())
    }

    /// (hash, animated, byte size) of every cached blob of one kind, newest first.
    /// Metadata only: bytes load per-hash via [`load_emote_blob`].
    pub fn list_asset_blobs_by_kind(
        &self,
        kind: &str,
    ) -> Result<Vec<(String, bool, u64)>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT hash, animated, LENGTH(bytes) FROM emote_blobs
                 WHERE kind = ?1 ORDER BY added_at DESC",
            )
            .map_err(|e| format!("Failed to prepare asset list: {e}"))?;
        let rows = stmt
            .query_map(params![kind], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)? != 0,
                    row.get::<_, i64>(2)?.max(0) as u64,
                ))
            })
            .map_err(|e| format!("Failed to list asset blobs: {e}"))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// Total bytes + row count of the asset blob cache (all kinds).
    pub fn asset_blob_usage(&self) -> Result<(u64, u32), String> {
        self.conn
            .query_row(
                "SELECT COALESCE(SUM(LENGTH(bytes)), 0), COUNT(*) FROM emote_blobs",
                [],
                |row| Ok((row.get::<_, i64>(0)?.max(0) as u64, row.get::<_, i64>(1)?.max(0) as u32)),
            )
            .map_err(|e| format!("Failed to read asset usage: {e}"))
    }

    /// LRU-evict asset blobs until the total is under `max_bytes * 0.8` (the file-cache
    /// evictor's hysteresis). Hashes in `keep` are never evicted: the caller passes
    /// everything still referenced, so eviction can only drop blobs that would be
    /// re-pulled on demand. Returns bytes freed.
    pub fn evict_asset_blobs(
        &self,
        max_bytes: u64,
        keep: &std::collections::HashSet<String>,
    ) -> Result<u64, String> {
        let (total, _) = self.asset_blob_usage()?;
        if total <= max_bytes {
            return Ok(0);
        }
        let target = (max_bytes as f64 * 0.8) as u64;
        let mut stmt = self
            .conn
            .prepare(
                "SELECT hash, LENGTH(bytes) FROM emote_blobs ORDER BY added_at ASC",
            )
            .map_err(|e| format!("Failed to prepare asset eviction scan: {e}"))?;
        let rows: Vec<(String, u64)> = stmt
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?.max(0) as u64))
            })
            .map_err(|e| format!("Failed to scan asset blobs: {e}"))?
            .filter_map(|r| r.ok())
            .collect();
        drop(stmt);

        let mut remaining = total;
        let mut freed = 0u64;
        for (hash, size) in rows {
            if remaining <= target {
                break;
            }
            if keep.contains(&hash) {
                continue;
            }
            if self
                .conn
                .execute("DELETE FROM emote_blobs WHERE hash = ?1", params![hash])
                .is_ok()
            {
                remaining = remaining.saturating_sub(size);
                freed += size;
            }
        }
        Ok(freed)
    }

    /// Delete every asset blob whose hash is NOT in `keep` (Storage Manager
    /// "clear" action). Returns bytes freed.
    pub fn clear_asset_blobs_except(
        &self,
        keep: &std::collections::HashSet<String>,
    ) -> Result<u64, String> {
        self.evict_asset_blobs(0, keep)
    }

    pub fn load_emote_blob(&self, hash: &str) -> Result<Option<Vec<u8>>, String> {
        let result = self.conn.query_row(
            "SELECT bytes FROM emote_blobs WHERE hash = ?1",
            params![hash],
            |row| row.get::<_, Vec<u8>>(0),
        );
        match result {
            Ok(bytes) => Ok(Some(bytes)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(format!("Failed to read emote blob: {e}")),
        }
    }

    /// The kind a rail blob is stored as, without reading its bytes.
    pub fn asset_blob_kind(&self, hash: &str) -> Result<Option<String>, String> {
        match self.conn.query_row(
            "SELECT kind FROM emote_blobs WHERE hash = ?1",
            params![hash],
            |row| row.get::<_, String>(0),
        ) {
            Ok(kind) => Ok(Some(kind)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(format!("Failed to read asset blob kind: {e}")),
        }
    }

    /// A rail blob and the kind it was stored as.
    pub fn load_asset_blob(&self, hash: &str) -> Result<Option<(Vec<u8>, String)>, String> {
        match self.conn.query_row(
            "SELECT bytes, kind FROM emote_blobs WHERE hash = ?1",
            params![hash],
            |row| Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, String>(1)?)),
        ) {
            Ok(found) => Ok(Some(found)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(format!("Failed to read asset blob: {e}")),
        }
    }

    /// Keep a stream overlay image (`overlay_blobs`, never the rail). Returns whether
    /// it was new.
    pub fn save_overlay_blob(&self, hash: &str, bytes: &[u8], animated: bool) -> Result<bool, String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        self.conn
            .execute(
                "INSERT INTO overlay_blobs (hash, bytes, animated, added_at) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(hash) DO NOTHING",
                params![hash, bytes, animated as i64, now],
            )
            .map(|n| n > 0)
            .map_err(|e| format!("Failed to save overlay image: {e}"))
    }

    /// The stored image-check verdict row `(code, checked_at_ms)` for these exact bytes
    /// (SHA-256 hex) under check version `rule`; codes are `image_gate`'s. A hit older
    /// than a day is touched, so the trim evicts the least recently USED rows.
    pub fn image_verdict(&self, hash: &str, rule: i64) -> Option<(i64, i64)> {
        let row = self
            .conn
            .query_row(
                "SELECT ok, checked_at FROM image_verdicts WHERE hash = ?1 AND rule = ?2",
                params![hash, rule],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
            )
            .ok()?;
        let now = now_ms_for_verdicts();
        if row.0 != 3 && now - row.1 > DAY_MS {
            let _ = self.conn.execute(
                "UPDATE image_verdicts SET checked_at = ?2 WHERE hash = ?1",
                params![hash, now],
            );
        }
        Some(row)
    }

    /// Keep an image-check verdict code, newest wins. The table is a cache: past
    /// [`MAX_IMAGE_VERDICTS`] plus slack the least recently used rows go, and a lost
    /// row costs one more decode.
    pub fn record_image_verdict(&self, hash: &str, code: i64, rule: i64) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO image_verdicts (hash, ok, rule, checked_at) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(hash) DO UPDATE SET ok = excluded.ok, rule = excluded.rule,
                 checked_at = excluded.checked_at",
                params![hash, code, rule, now_ms_for_verdicts()],
            )
            .map_err(|e| format!("Failed to save image verdict: {e}"))?;
        // A count only every 1024th new row: the trim is rare and the table small.
        if self.conn.last_insert_rowid() % 1024 == 0 {
            let rows: i64 = self
                .conn
                .query_row("SELECT COUNT(*) FROM image_verdicts", [], |r| r.get(0))
                .unwrap_or(0);
            if rows > MAX_IMAGE_VERDICTS + IMAGE_VERDICT_SLACK {
                self.conn
                    .execute(
                        "DELETE FROM image_verdicts WHERE hash IN (
                             SELECT hash FROM image_verdicts ORDER BY checked_at ASC LIMIT ?1)",
                        params![rows - MAX_IMAGE_VERDICTS],
                    )
                    .map_err(|e| format!("Failed to trim image verdicts: {e}"))?;
            }
        }
        Ok(())
    }

    /// Drop a verdict row: a check that said nothing about the bytes (no slot).
    pub fn forget_image_verdict(&self, hash: &str) {
        let _ = self.conn.execute("DELETE FROM image_verdicts WHERE hash = ?1", params![hash]);
    }

    pub fn load_overlay_blob(&self, hash: &str) -> Result<Option<Vec<u8>>, String> {
        match self.conn.query_row("SELECT bytes FROM overlay_blobs WHERE hash = ?1", params![hash], |row| {
            row.get::<_, Vec<u8>>(0)
        }) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(format!("Failed to read overlay image: {e}")),
        }
    }

    pub fn has_overlay_blob(&self, hash: &str) -> Result<bool, String> {
        self.conn
            .query_row("SELECT COUNT(*) FROM overlay_blobs WHERE hash = ?1", params![hash], |row| row.get::<_, i64>(0))
            .map(|n| n > 0)
            .map_err(|e| format!("Failed to check overlay image: {e}"))
    }

    /// Every overlay image held, with when it was stored.
    pub fn overlay_blob_stamps(&self) -> Result<Vec<(String, i64)>, String> {
        let mut stmt = self
            .conn
            .prepare("SELECT hash, added_at FROM overlay_blobs")
            .map_err(|e| format!("Failed to prepare overlay images: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))
            .map_err(|e| format!("Failed to list overlay images: {e}"))?;
        collect_rows(rows, "overlay image")
    }

    pub fn delete_overlay_blob(&self, hash: &str) -> Result<bool, String> {
        self.conn
            .execute("DELETE FROM overlay_blobs WHERE hash = ?1", params![hash])
            .map(|n| n > 0)
            .map_err(|e| format!("Failed to delete overlay image: {e}"))
    }

    /// The file this store reads, as SQLite names it ("" in memory).
    pub fn db_file(&self) -> String {
        self.conn.path().unwrap_or_default().to_string()
    }

    pub fn has_emote_blob(&self, hash: &str) -> Result<bool, String> {
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM emote_blobs WHERE hash = ?1",
                params![hash],
                |row| row.get(0),
            )
            .map_err(|e| format!("Failed to check emote blob: {e}"))?;
        Ok(count > 0)
    }

    /// A local write must outrank whatever stamp the row already carries, or a
    /// sibling whose clock runs ahead keeps winning the merge on the other device.
    fn next_personal_emote_stamp(&self, name: &str) -> i64 {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        let held: i64 = self
            .conn
            .query_row(
                "SELECT added_at FROM personal_emotes WHERE name = ?1",
                params![name],
                |row| row.get(0),
            )
            .unwrap_or(0);
        now.max(held + 1)
    }

    /// Returns the `added_at` stamp it wrote, which the sibling sync sends as the
    /// row's version: a local add is always the newest write of that name.
    pub fn add_personal_emote(
        &self,
        name: &str,
        hash: &str,
        animated: bool,
        source: &str,
    ) -> Result<i64, String> {
        let now = self.next_personal_emote_stamp(name);
        self.conn
            .execute(
                "INSERT INTO personal_emotes (name, hash, animated, source, added_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(name) DO UPDATE SET
                     hash = excluded.hash, animated = excluded.animated,
                     source = excluded.source, added_at = excluded.added_at",
                params![name, hash, animated as i64, source, now],
            )
            .map_err(|e| format!("Failed to add personal emote: {e}"))?;
        Ok(now)
    }

    /// Tombstones the name (empty hash) instead of deleting the row, and returns
    /// the removal stamp when a live row was there. Tombstones are never collected:
    /// a sibling that was offline still has to learn the removal.
    pub fn remove_personal_emote(&self, name: &str) -> Result<Option<i64>, String> {
        let now = self.next_personal_emote_stamp(name);
        let changed = self
            .conn
            .execute(
                "UPDATE personal_emotes SET hash = '', animated = 0, source = '', added_at = ?2
                 WHERE name = ?1 AND hash != ''",
                params![name, now],
            )
            .map_err(|e| format!("Failed to remove personal emote: {e}"))?;
        Ok(if changed > 0 { Some(now) } else { None })
    }

    /// Every row including tombstones, as (name, hash, animated, source, added_at).
    pub fn list_personal_emote_entries(
        &self,
    ) -> Result<Vec<(String, String, bool, String, i64)>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT name, hash, animated, source, added_at FROM personal_emotes
                 ORDER BY added_at DESC",
            )
            .map_err(|e| format!("Failed to prepare personal emote query: {e}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)? != 0,
                    row.get::<_, String>(3)?,
                    row.get::<_, i64>(4)?,
                ))
            })
            .map_err(|e| format!("Failed to query personal emotes: {e}"))?;
        collect_rows(rows, "personal emote")
    }

    /// Merges one sibling row under per-name last-write-wins; `false` = ours is
    /// newer and nothing changed.
    pub fn merge_personal_emote_entry(
        &self,
        name: &str,
        hash: &str,
        animated: bool,
        source: &str,
        added_at: i64,
    ) -> Result<bool, String> {
        let changed = self
            .conn
            .execute(
                "INSERT INTO personal_emotes (name, hash, animated, source, added_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(name) DO UPDATE SET
                     hash = excluded.hash, animated = excluded.animated,
                     source = excluded.source, added_at = excluded.added_at
                 WHERE excluded.added_at > personal_emotes.added_at",
                params![name, hash, animated as i64, source, added_at],
            )
            .map_err(|e| format!("Failed to merge personal emote: {e}"))?;
        Ok(changed > 0)
    }

    /// All live personal emotes as (name, hash, animated, source), newest first.
    pub fn list_personal_emotes(&self) -> Result<Vec<(String, String, bool, String)>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT name, hash, animated, source FROM personal_emotes
                 WHERE hash != '' ORDER BY added_at DESC",
            )
            .map_err(|e| format!("Failed to prepare personal emote query: {e}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)? != 0,
                    row.get::<_, String>(3)?,
                ))
            })
            .map_err(|e| format!("Failed to query personal emotes: {e}"))?;
        collect_rows(rows, "personal emote")
    }

    // ── Personal sticker vault ────────────────────────────────────

    /// One row of the personal sticker vault.
    pub fn add_personal_sticker(&self, row: &PersonalStickerRow) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        self.conn
            .execute(
                "INSERT INTO personal_stickers
                     (pack, hash, name, animated, w, h, source, added_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(pack, hash) DO UPDATE SET
                     name = excluded.name, animated = excluded.animated,
                     w = excluded.w, h = excluded.h, source = excluded.source",
                params![
                    row.pack,
                    row.hash,
                    row.name,
                    row.animated as i64,
                    row.w as i64,
                    row.h as i64,
                    row.source,
                    now
                ],
            )
            .map_err(|e| format!("Failed to add sticker: {e}"))?;
        Ok(())
    }

    pub fn remove_personal_sticker(&self, pack: &str, hash: &str) -> Result<(), String> {
        self.conn
            .execute(
                "DELETE FROM personal_stickers WHERE pack = ?1 AND hash = ?2",
                params![pack, hash],
            )
            .map_err(|e| format!("Failed to remove sticker: {e}"))?;
        Ok(())
    }

    /// Delete a whole pack. Blobs stay in the cache: they are content-addressed and may
    /// still be referenced by a sent message, so the LRU reclaims them later.
    pub fn remove_personal_sticker_pack(&self, pack: &str) -> Result<(), String> {
        self.conn
            .execute(
                "DELETE FROM personal_stickers WHERE pack = ?1",
                params![pack],
            )
            .map_err(|e| format!("Failed to remove sticker pack: {e}"))?;
        Ok(())
    }

    /// Move every sticker of `from` into `to`. Rows already in `to` with the same hash
    /// win, so a rename onto an existing pack merges instead of failing.
    pub fn rename_personal_sticker_pack(&self, from: &str, to: &str) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE OR REPLACE personal_stickers SET pack = ?2 WHERE pack = ?1",
                params![from, to],
            )
            .map_err(|e| format!("Failed to rename sticker pack: {e}"))?;
        Ok(())
    }

    /// The whole vault, pack-major and oldest-first inside each pack: upload order IS
    /// pack order, which is what makes a multi-part pack readable in the picker.
    pub fn list_personal_stickers(&self) -> Result<Vec<PersonalStickerRow>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT pack, hash, name, animated, w, h, source, added_at
                 FROM personal_stickers ORDER BY pack ASC, added_at ASC",
            )
            .map_err(|e| format!("Failed to prepare sticker query: {e}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok(PersonalStickerRow {
                    pack: row.get::<_, String>(0)?,
                    hash: row.get::<_, String>(1)?,
                    name: row.get::<_, String>(2)?,
                    animated: row.get::<_, i64>(3)? != 0,
                    w: row.get::<_, i64>(4)?.max(0) as u32,
                    h: row.get::<_, i64>(5)?.max(0) as u32,
                    source: row.get::<_, String>(6)?,
                    added_at: row.get::<_, i64>(7)?,
                })
            })
            .map_err(|e| format!("Failed to query stickers: {e}"))?;
        collect_rows(rows, "sticker")
    }

    /// Row count, for the authoring-side vault cap.
    pub fn personal_sticker_count(&self) -> Result<u32, String> {
        self.conn
            .query_row("SELECT COUNT(*) FROM personal_stickers", [], |row| {
                Ok(row.get::<_, i64>(0)?.max(0) as u32)
            })
            .map_err(|e| format!("Failed to count stickers: {e}"))
    }

    // ── App Settings ──────────────────────────────────────────────

    pub fn save_setting(&self, key: &str, value: &str) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO app_settings (key, value) VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![key, value],
            )
            .map_err(|e| format!("Failed to save setting: {e}"))?;
        Ok(())
    }

    pub fn delete_setting(&self, key: &str) -> Result<(), String> {
        self.conn
            .execute("DELETE FROM app_settings WHERE key = ?1", params![key])
            .map_err(|e| format!("Failed to delete setting: {e}"))?;
        Ok(())
    }

    /// Load ALL settings whose key starts with `prefix` in one query. Startup used to
    /// issue one FFI round-trip per server, channel and DM, hundreds of them, serially.
    pub fn load_settings_with_prefix(
        &self,
        prefix: &str,
    ) -> Result<Vec<(String, String)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached(
                "SELECT key, value FROM app_settings WHERE key >= ?1 AND key < ?1 || x'ff'",
            )
            .map_err(|e| format!("Failed to prepare settings prefix query: {e}"))?;
        let rows = stmt
            .query_map(params![prefix], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(|e| format!("Failed to query settings by prefix: {e}"))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    // ── Call records ──────────────────────────────────────────────

    /// Stores one ended DM call. A call id already recorded is left as it was, so a
    /// teardown that runs twice cannot rewrite the outcome.
    pub fn record_dm_call(&self, r: &CallRecordRow) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT OR IGNORE INTO call_records
                 (call_id, peer_id, outgoing, video, outcome, started_at, connected_at, ended_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    r.call_id,
                    r.peer_id,
                    r.outgoing,
                    r.video,
                    r.outcome,
                    r.started_at,
                    r.connected_at,
                    r.ended_at
                ],
            )
            .map_err(|e| format!("Failed to record call: {e}"))?;
        Ok(())
    }

    /// The newest `limit` calls with `peer_id`, oldest first.
    pub fn load_dm_call_records(
        &self,
        peer_id: &str,
        limit: u32,
    ) -> Result<Vec<CallRecordRow>, String> {
        let mut stmt = self
            .conn
            .prepare_cached(
                "SELECT call_id, peer_id, outgoing, video, outcome, started_at, connected_at, ended_at
                 FROM call_records WHERE peer_id = ?1
                 ORDER BY started_at DESC LIMIT ?2",
            )
            .map_err(|e| format!("Failed to prepare call records query: {e}"))?;
        let rows = stmt
            .query_map(params![peer_id, limit], |row| {
                Ok(CallRecordRow {
                    call_id: row.get(0)?,
                    peer_id: row.get(1)?,
                    outgoing: row.get(2)?,
                    video: row.get(3)?,
                    outcome: row.get(4)?,
                    started_at: row.get(5)?,
                    connected_at: row.get(6)?,
                    ended_at: row.get(7)?,
                })
            })
            .map_err(|e| format!("Failed to query call records: {e}"))?;
        let mut out = collect_rows(rows, "call record")?;
        out.reverse();
        Ok(out)
    }

    // ── Read markers (issue #80) ──────────────────────────────────
    //
    // A read pointer is the `seen:<key>` setting holding a message id. Siblings
    // exchange it with the row's timestamp, because the other device may hold a
    // different row set and has to place the pointer by time. A sibling's
    // timestamp is kept as `seen_ts:<key>` too: it can arrive BEFORE the rows it
    // covers are backfilled, and the counts floor on it either way.

    /// Millisecond timestamp of the row a read pointer names; `None` when the
    /// key is malformed or the row is absent locally.
    pub fn read_marker_timestamp(&self, key: &str, message_id: &str) -> Option<i64> {
        if let Some(peer) = key.strip_prefix("dm:") {
            self.conn
                .query_row(
                    "SELECT timestamp FROM messages WHERE peer_id = ?1 AND message_id = ?2",
                    params![peer, message_id],
                    |row| row.get::<_, i64>(0),
                )
                .ok()
        } else if key.starts_with("ch:") {
            self.conn
                .query_row(
                    "SELECT timestamp FROM channel_messages WHERE message_id = ?1",
                    params![message_id],
                    |row| row.get::<_, i64>(0),
                )
                .ok()
        } else {
            None
        }
    }

    /// Where reading stands for `key`: the later of the seen row's timestamp and
    /// the sibling-reported `seen_ts:`. `None` when neither exists.
    pub fn read_marker_floor(&self, key: &str) -> Option<i64> {
        let row = self
            .load_setting(&format!("seen:{key}"))
            .ok()
            .flatten()
            .and_then(|mid| self.read_marker_timestamp(key, &mid));
        let reported = self
            .load_setting(&format!("seen_ts:{key}"))
            .ok()
            .flatten()
            .and_then(|v| v.parse::<i64>().ok());
        match (row, reported) {
            (Some(a), Some(b)) => Some(a.max(b)),
            (a, None) => a,
            (None, b) => b,
        }
    }

    /// Every read pointer with a resolvable timestamp, as `(key, message_id, ts)`;
    /// `message_id` is empty for a conversation known only through a sibling mark.
    pub fn read_markers_snapshot(&self) -> Vec<(String, String, i64)> {
        let mut keys: Vec<(String, String)> = Vec::new();
        for (k, mid) in self.load_settings_with_prefix("seen:").unwrap_or_default() {
            if let Some(key) = k.strip_prefix("seen:") {
                keys.push((key.to_string(), mid));
            }
        }
        for (k, _) in self.load_settings_with_prefix("seen_ts:").unwrap_or_default() {
            if let Some(key) = k.strip_prefix("seen_ts:") {
                if !keys.iter().any(|(existing, _)| existing == key) {
                    keys.push((key.to_string(), String::new()));
                }
            }
        }
        keys.into_iter()
            .filter_map(|(key, mid)| {
                let ts = self.read_marker_floor(&key)?;
                Some((key, mid, ts))
            })
            .collect()
    }

    /// Adopt a sibling's read pointer for `key` when `ts` is later than where our
    /// reading stands: `seen_ts:` records it, and the newest local row at or before
    /// it becomes the seen message. Returns the pointer that now applies, empty
    /// when only the timestamp moved (no local row that old yet), `None` when
    /// nothing changed.
    pub fn apply_remote_read_marker(&self, key: &str, ts: i64) -> Result<Option<String>, String> {
        if !key.starts_with("dm:") && !key.starts_with("ch:") {
            return Err(format!("unknown read marker key: {key}"));
        }
        let current_ts = self.read_marker_floor(key).unwrap_or(-1);
        if ts <= current_ts {
            return Ok(None);
        }
        self.save_setting(&format!("seen_ts:{key}"), &ts.to_string())?;
        let setting = format!("seen:{key}");
        let candidate: Option<String> = if let Some(peer) = key.strip_prefix("dm:") {
            self.conn
                .query_row(
                    "SELECT message_id FROM messages
                     WHERE peer_id = ?1 AND timestamp <= ?2 AND message_id IS NOT NULL
                     ORDER BY timestamp DESC, id DESC LIMIT 1",
                    params![peer, ts],
                    |row| row.get(0),
                )
                .ok()
        } else if let Some(rest) = key.strip_prefix("ch:") {
            let (sid, cid) = rest.split_once(':').ok_or("malformed channel read marker")?;
            self.conn
                .query_row(
                    "SELECT message_id FROM channel_messages
                     WHERE server_id = ?1 AND channel_id = ?2 AND timestamp <= ?3
                       AND message_id IS NOT NULL
                     ORDER BY timestamp DESC, id DESC LIMIT 1",
                    params![sid, cid, ts],
                    |row| row.get(0),
                )
                .ok()
        } else {
            None
        };
        let Some(mid) = candidate else { return Ok(Some(String::new())) };
        // Same millisecond as the pointer we hold: only the timestamp moved.
        if self.read_marker_timestamp(key, &mid) == Some(current_ts) {
            return Ok(Some(String::new()));
        }
        self.save_setting(&setting, &mid)?;
        Ok(Some(mid))
    }

    /// Load a setting by key. Returns None if not set.
    pub fn load_setting(&self, key: &str) -> Result<Option<String>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT value FROM app_settings WHERE key = ?1")
            .map_err(|e| format!("Failed to prepare setting query: {e}"))?;
        let mut rows = stmt
            .query_map(params![key], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query setting: {e}"))?;
        match rows.next() {
            Some(Ok(val)) => Ok(Some(val)),
            Some(Err(e)) => Err(format!("Failed to read setting: {e}")),
            None => Ok(None),
        }
    }

    // ── Verified Peers (RAT Files) ─────────────────────────────────

    /// Mark a peer as identity-verified (fingerprint confirmed).
    pub fn set_peer_verified(&self, peer_id: &str) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "INSERT INTO verified_peers (peer_id, verified_at) VALUES (?1, ?2)
                 ON CONFLICT(peer_id) DO UPDATE SET verified_at = excluded.verified_at",
                params![peer_id, now],
            )
            .map_err(|e| format!("Failed to set peer verified: {e}"))?;
        Ok(())
    }

    /// Remove verified status from a peer.
    pub fn remove_peer_verified(&self, peer_id: &str) -> Result<(), String> {
        self.conn
            .execute(
                "DELETE FROM verified_peers WHERE peer_id = ?1",
                params![peer_id],
            )
            .map_err(|e| format!("Failed to remove peer verified: {e}"))?;
        Ok(())
    }

    /// Check if a peer is verified.
    pub fn is_peer_verified(&self, peer_id: &str) -> Result<bool, String> {
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM verified_peers WHERE peer_id = ?1",
                params![peer_id],
                |row| row.get(0),
            )
            .map_err(|e| format!("Failed to check peer verified: {e}"))?;
        Ok(count > 0)
    }

    /// Get all verified peers (peer_id, verified_at_ms).
    pub fn get_verified_peers(&self) -> Result<Vec<(String, i64)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT peer_id, verified_at FROM verified_peers ORDER BY verified_at DESC")
            .map_err(|e| format!("Failed to prepare verified_peers query: {e}"))?;
        let rows = stmt
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))
            .map_err(|e| format!("Failed to query verified_peers: {e}"))?;
        let mut result = Vec::new();
        for row in rows {
            if let Ok(r) = row {
                result.push(r);
            }
        }
        Ok(result)
    }

    // ── Security alerts (Issue 1-C) ────────────────────────────────

    /// Record a security alert for a contact. Returns `true` only when this is a NEW
    /// fact, which is how callers decide to emit a live event: a device list is
    /// re-ingested on every reconnect, so emitting unconditionally would re-raise a
    /// warning the user already dismissed. `peer_id` MUST be a master id.
    pub fn record_security_alert(
        &self,
        peer_id: &str,
        kind: &str,
        detail: &str,
        created_at: i64,
    ) -> Result<bool, String> {
        let alert_id = format!("{kind}:{peer_id}:{detail}");
        // A device that left and is back is news again.
        self.conn
            .execute("DELETE FROM security_alerts WHERE alert_id = ?1 AND resolved_at IS NOT NULL", params![alert_id])
            .map_err(|e| format!("Failed to record security alert: {e}"))?;
        let changed = self
            .conn
            .execute(
                "INSERT OR IGNORE INTO security_alerts
                    (alert_id, peer_id, kind, detail, created_at, acknowledged_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, NULL)",
                params![alert_id, peer_id, kind, detail, created_at],
            )
            .map_err(|e| format!("Failed to record security alert: {e}"))?;
        Ok(changed > 0)
    }

    /// All security alerts, newest first; `acknowledged_at` is `None` while unread.
    pub fn get_security_alerts(&self) -> Result<Vec<SecurityAlertRow>, String> {
        let mut stmt = self
            .conn
            .prepare_cached(
                "SELECT alert_id, peer_id, kind, detail, created_at, acknowledged_at, resolved_at
                   FROM security_alerts ORDER BY created_at DESC",
            )
            .map_err(|e| format!("Failed to prepare security_alerts query: {e}"))?;
        let rows = stmt
            .query_map([], |row| {
                Ok(SecurityAlertRow {
                    alert_id: row.get(0)?,
                    peer_id: row.get(1)?,
                    kind: row.get(2)?,
                    detail: row.get(3)?,
                    created_at: row.get(4)?,
                    acknowledged_at: row.get(5)?,
                    resolved_at: row.get(6)?,
                })
            })
            .map_err(|e| format!("Failed to query security_alerts: {e}"))?;
        Ok(rows.flatten().collect())
    }

    /// Mark one alert as read. Idempotent, keeping the first timestamp so "when did I
    /// dismiss this" stays truthful.
    pub fn acknowledge_security_alert(&self, alert_id: &str) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "UPDATE security_alerts SET acknowledged_at = ?2
                  WHERE alert_id = ?1 AND acknowledged_at IS NULL",
                params![alert_id, now],
            )
            .map_err(|e| format!("Failed to acknowledge security alert: {e}"))?;
        Ok(())
    }

    /// Mark every outstanding alert for one contact as read.
    pub fn acknowledge_security_alerts_for_peer(&self, peer_id: &str) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "UPDATE security_alerts SET acknowledged_at = ?2
                  WHERE peer_id = ?1 AND acknowledged_at IS NULL",
                params![peer_id, now],
            )
            .map_err(|e| format!("Failed to acknowledge security alerts: {e}"))?;
        Ok(())
    }

    /// Alerts of `kind` for `peer_id` not yet marked resolved, as (alert_id, detail).
    pub fn unresolved_security_alerts(&self, peer_id: &str, kind: &str) -> Result<Vec<(String, String)>, String> {
        let mut stmt = self
            .conn
            .prepare_cached(
                "SELECT alert_id, detail FROM security_alerts
                  WHERE peer_id = ?1 AND kind = ?2 AND resolved_at IS NULL",
            )
            .map_err(|e| format!("Failed to prepare security_alerts query: {e}"))?;
        let rows = stmt
            .query_map(params![peer_id, kind], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|e| format!("Failed to query security_alerts: {e}"))?;
        Ok(rows.flatten().collect())
    }

    /// The device `alert_id` names left the roster at `at_ms`; `dismiss` also reads it
    /// (the person removed it here). A read alert keeps its first read time.
    pub fn resolve_security_alert(&self, alert_id: &str, at_ms: i64, dismiss: bool) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE security_alerts SET resolved_at = ?2,
                    acknowledged_at = CASE WHEN ?3 THEN COALESCE(acknowledged_at, ?2) ELSE acknowledged_at END
                  WHERE alert_id = ?1",
                params![alert_id, at_ms, dismiss],
            )
            .map_err(|e| format!("Failed to resolve security alert: {e}"))?;
        Ok(())
    }

    // ── F2: carried removals (0.13) ────────────────────────────────

    /// When this device first carried each removal of `master`'s it was asked about,
    /// stamping `now_ms` for those it never had; rows of devices not asked about go.
    pub fn removal_carried_since(
        &self,
        master: &str,
        base: &str,
        devices: &[String],
        now_ms: i64,
    ) -> Result<HashMap<String, i64>, String> {
        let mut out = HashMap::new();
        let rows: Vec<(String, String)> = {
            let mut stmt = self
                .conn
                .prepare_cached("SELECT base, device_peer_id FROM roster_removal_carried WHERE master_peer_id = ?1")
                .map_err(|e| format!("Failed to read roster_removal_carried: {e}"))?;
            let rows = stmt
                .query_map(params![master], |row| Ok((row.get(0)?, row.get(1)?)))
                .map_err(|e| format!("Failed to read roster_removal_carried: {e}"))?;
            rows.flatten().collect()
        };
        for (b, d) in rows {
            if b != base || !devices.contains(&d) {
                self.conn
                    .execute(
                        "DELETE FROM roster_removal_carried WHERE master_peer_id = ?1 AND base = ?2 AND device_peer_id = ?3",
                        params![master, b, d],
                    )
                    .map_err(|e| format!("Failed to prune roster_removal_carried: {e}"))?;
            }
        }
        for d in devices {
            self.conn
                .execute(
                    "INSERT OR IGNORE INTO roster_removal_carried (master_peer_id, base, device_peer_id, first_ms)
                     VALUES (?1, ?2, ?3, ?4)",
                    params![master, base, d, now_ms],
                )
                .map_err(|e| format!("Failed to stamp roster_removal_carried: {e}"))?;
            let first: i64 = self
                .conn
                .query_row(
                    "SELECT first_ms FROM roster_removal_carried
                      WHERE master_peer_id = ?1 AND base = ?2 AND device_peer_id = ?3",
                    params![master, base, d],
                    |row| row.get(0),
                )
                .map_err(|e| format!("Failed to read roster_removal_carried: {e}"))?;
            out.insert(d.clone(), first);
        }
        Ok(out)
    }

    /// When this device first carried each removal of `master`'s in `base`, as stamped.
    pub fn removal_carried_at(&self, master: &str, base: &str) -> Result<HashMap<String, i64>, String> {
        let mut stmt = self
            .conn
            .prepare_cached(
                "SELECT device_peer_id, first_ms FROM roster_removal_carried WHERE master_peer_id = ?1 AND base = ?2",
            )
            .map_err(|e| format!("Failed to read roster_removal_carried: {e}"))?;
        let rows = stmt
            .query_map(params![master, base], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|e| format!("Failed to read roster_removal_carried: {e}"))?;
        Ok(rows.flatten().collect())
    }

    /// Stamp `now_ms` for each of `devices` that has no stamp yet in `base`.
    pub fn stamp_removal_carried(&self, master: &str, base: &str, devices: &[String], now_ms: i64) -> Result<(), String> {
        for d in devices {
            self.conn
                .execute(
                    "INSERT OR IGNORE INTO roster_removal_carried (master_peer_id, base, device_peer_id, first_ms)
                     VALUES (?1, ?2, ?3, ?4)",
                    params![master, base, d, now_ms],
                )
                .map_err(|e| format!("Failed to stamp roster_removal_carried: {e}"))?;
        }
        Ok(())
    }

    /// A DM of `contact`'s device `device` showed our own roster as `digest`, which we
    /// held at `at_ms`.
    pub fn set_carry_confirm(&self, contact: &str, device: &str, digest: &str, at_ms: i64) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO roster_carry_device_confirms (contact_master, device_peer_id, digest, at_ms)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(contact_master, device_peer_id) DO UPDATE
                    SET digest = excluded.digest, at_ms = excluded.at_ms
                    WHERE excluded.at_ms >= roster_carry_device_confirms.at_ms",
                params![contact, device, digest, at_ms],
            )
            .map_err(|e| format!("Failed to stamp roster_carry_device_confirms: {e}"))?;
        Ok(())
    }

    /// The newest (digest, at_ms) each device of `contact` confirmed of our own roster.
    pub fn carry_confirms(&self, contact: &str) -> HashMap<String, (String, i64)> {
        let Ok(mut stmt) = self.conn.prepare_cached(
            "SELECT device_peer_id, digest, at_ms FROM roster_carry_device_confirms WHERE contact_master = ?1",
        ) else {
            return HashMap::new();
        };
        stmt.query_map(params![contact], |row| Ok((row.get(0)?, (row.get(1)?, row.get(2)?))))
            .map(|rows| rows.flatten().collect())
            .unwrap_or_default()
    }


    /// Another process changed `master`'s roster in this store.
    pub fn mark_roster_dirty(&self, master: &str, at_ms: i64) -> Result<(), String> {
        self.conn
            .execute(
                "INSERT INTO roster_dirty (master_peer_id, at_ms) VALUES (?1, ?2)
                 ON CONFLICT(master_peer_id) DO UPDATE SET at_ms = excluded.at_ms",
                params![master, at_ms],
            )
            .map_err(|e| format!("Failed to mark roster_dirty: {e}"))?;
        Ok(())
    }

    pub fn roster_dirty(&self, master: &str) -> bool {
        self.conn
            .query_row("SELECT 1 FROM roster_dirty WHERE master_peer_id = ?1", params![master], |_| Ok(()))
            .is_ok()
    }

    /// Another process saw a recovery of `master` drop `devices`.
    pub fn add_roster_dropped(&self, master: &str, devices: &[String]) -> Result<(), String> {
        for d in devices {
            self.conn
                .execute("INSERT OR IGNORE INTO roster_dropped (master_peer_id, device_peer_id) VALUES (?1, ?2)", params![master, d])
                .map_err(|e| format!("Failed to note roster_dropped: {e}"))?;
        }
        Ok(())
    }

    /// Take the devices noted for `master` by [`Self::add_roster_dropped`].
    pub fn take_roster_dropped(&self, master: &str) -> Vec<String> {
        let taken: Vec<String> = self
            .conn
            .prepare("SELECT device_peer_id FROM roster_dropped WHERE master_peer_id = ?1 ORDER BY device_peer_id")
            .and_then(|mut stmt| stmt.query_map(params![master], |row| row.get(0)).map(|rows| rows.flatten().collect()))
            .unwrap_or_default();
        let _ = self.conn.execute("DELETE FROM roster_dropped WHERE master_peer_id = ?1", params![master]);
        taken
    }

    /// Take the dirty marks, of `master` only or of every identity.
    pub fn take_roster_dirty(&self, master: Option<&str>) -> Vec<String> {
        let taken: Vec<String> = match master {
            Some(m) => self
                .conn
                .query_row("SELECT master_peer_id FROM roster_dirty WHERE master_peer_id = ?1", params![m], |row| row.get(0))
                .ok()
                .into_iter()
                .collect(),
            None => self
                .conn
                .prepare("SELECT master_peer_id FROM roster_dirty")
                .and_then(|mut stmt| stmt.query_map([], |row| row.get(0)).map(|rows| rows.flatten().collect()))
                .unwrap_or_default(),
        };
        for m in &taken {
            let _ = self.conn.execute("DELETE FROM roster_dirty WHERE master_peer_id = ?1", params![m]);
        }
        taken
    }

    // ── Olm identity-key pins (Issue 1-C, TOFU) ────────────────────

    /// The Curve25519 identity key pinned for `device_peer_id`, `None` when we have
    /// never completed a key exchange with it.
    pub fn get_olm_key_pin(&self, device_peer_id: &str) -> Result<Option<String>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT identity_key FROM olm_key_pins WHERE device_peer_id = ?1")
            .map_err(|e| format!("Failed to prepare olm_key_pins query: {e}"))?;
        let mut rows = stmt
            .query_map(params![device_peer_id], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query olm_key_pins: {e}"))?;
        match rows.next() {
            Some(Ok(key)) => Ok(Some(key)),
            Some(Err(e)) => Err(format!("Failed to read olm key pin: {e}")),
            None => Ok(None),
        }
    }

    /// Pin (or re-pin) a device's Olm identity key.
    pub fn set_olm_key_pin(&self, device_peer_id: &str, identity_key: &str) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "INSERT INTO olm_key_pins (device_peer_id, identity_key, pinned_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(device_peer_id) DO UPDATE SET
                    identity_key = excluded.identity_key,
                    pinned_at    = excluded.pinned_at",
                params![device_peer_id, identity_key, now],
            )
            .map_err(|e| format!("Failed to set olm key pin: {e}"))?;
        Ok(())
    }

    // ── File sharing storage ────────────────────────────────────────

    /// Insert file metadata (called when FileHeader is received or file is sent).
    #[allow(clippy::too_many_arguments)]
    pub fn insert_file_metadata(
        &self,
        file_id: &str,
        file_name: &str,
        file_ext: &str,
        mime_type: &str,
        size_bytes: u64,
        chunk_count: u32,
        is_image: bool,
        width: Option<u32>,
        height: Option<u32>,
        message_id: Option<&str>,
        context_type: &str,
        context_id: &str,
        sender_id: &str,
        is_mine: bool,
        created_at: i64,
        video_thumb: Option<&crate::node::VideoThumbRef>,
        thumb_b64: Option<&str>,
        sha256: Option<&str>,
    ) -> Result<(), String> {
        let vthumb_json = video_thumb
            .and_then(|v| serde_json::to_string(v).ok());
        // UPSERT, not INSERT OR IGNORE: the background-fetch node may already have inserted
        // a MINIMAL placeholder row (it only had the file_id, since the real FileHeader is
        // never sent to an offline peer), so a later header must FILL IN the true
        // name/ext/size/dimensions. It deliberately leaves completed_at, disk_path and
        // chunks_received alone: those belong to the download path, and a re-arriving
        // header must never reset a finished file back to incomplete.
        self.conn
            .execute(
                "INSERT INTO files
                 (file_id, file_name, file_ext, mime_type, size_bytes,
                  chunk_count, is_image, width, height, message_id,
                  context_type, context_id, sender_id, is_mine, created_at,
                  video_thumb_json, thumb_b64, sha256)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
                 ON CONFLICT(file_id) DO UPDATE SET
                   file_name      = excluded.file_name,
                   file_ext       = excluded.file_ext,
                   mime_type      = excluded.mime_type,
                   size_bytes     = excluded.size_bytes,
                   chunk_count    = excluded.chunk_count,
                   is_image       = excluded.is_image,
                   width          = excluded.width,
                   height         = excluded.height,
                   message_id     = COALESCE(files.message_id, excluded.message_id),
                   video_thumb_json = COALESCE(excluded.video_thumb_json, files.video_thumb_json),
                   thumb_b64      = COALESCE(excluded.thumb_b64, files.thumb_b64),
                   sha256         = COALESCE(files.sha256, excluded.sha256)",
                params![
                    file_id, file_name, file_ext, mime_type,
                    size_bytes as i64, chunk_count, is_image as i32,
                    width.map(|w| w as i64), height.map(|h| h as i64),
                    message_id, context_type, context_id, sender_id,
                    is_mine as i32, created_at, vthumb_json, thumb_b64, sha256,
                ],
            )
            .map_err(|e| format!("Failed to insert file metadata: {e}"))?;
        Ok(())
    }


    /// Deserialize a VideoThumbRef JSON blob; `None` on null or a parse failure.
    fn parse_video_thumb_json(json: Option<String>) -> Option<crate::node::VideoThumbRef> {
        json.and_then(|s| serde_json::from_str(&s).ok())
    }

    /// Persist the ShareRef of a share-backed file. Kept out of `insert_file_metadata`
    /// so a re-arriving header without one never blanks a stored ShareRef.
    pub fn set_file_share_ref(
        &self,
        file_id: &str,
        share_ref: &crate::node::ShareRef,
    ) -> Result<(), String> {
        let json = serde_json::to_string(share_ref)
            .map_err(|e| format!("Failed to serialize share ref: {e}"))?;
        self.conn
            .execute(
                "UPDATE files SET share_ref_json = ?2 WHERE file_id = ?1",
                params![file_id, json],
            )
            .map_err(|e| format!("Failed to set share ref: {e}"))?;
        Ok(())
    }

    /// Mark a file as fully received.
    pub fn mark_file_complete(
        &self,
        file_id: &str,
        disk_path: &str,
    ) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "UPDATE files SET completed_at = ?1, disk_path = ?2 WHERE file_id = ?3",
                params![now, disk_path, file_id],
            )
            .map_err(|e| format!("Failed to mark file complete: {e}"))?;
        Ok(())
    }

    /// Re-resolve a completed file's `disk_path` against the CURRENT files directory.
    ///
    /// The stored path is absolute, captured when the download finished, but on iOS the
    /// data-container path is NOT stable across launches, so it can point at a
    /// now-nonexistent container even though the file moved with it. Files are stored as
    /// `{file_id}.{file_ext}`, so the current path is deterministic; if the rebuilt path
    /// exists we use it, otherwise the stored value is left alone because desktop paths
    /// are stable and some callers rely on the original string.
    fn resolve_disk_path(file: &mut StoredFile) {
        if file.completed_at.is_none() {
            return;
        }
        let Ok(files_dir) = crate::identity::data_dir().map(|d| d.join("files")) else {
            return;
        };
        let current = files_dir.join(format!("{}.{}", file.file_id, file.file_ext));
        if current.exists() {
            let current_str = current.to_string_lossy().to_string();
            if file.disk_path.as_deref() != Some(current_str.as_str()) {
                file.disk_path = Some(current_str);
            }
        }
    }

    /// Get file metadata by file_id.
    pub fn get_file_metadata(&self, file_id: &str) -> Result<Option<StoredFile>, String> {
        let mut stmt = self
            .conn
            .prepare(&format!("SELECT {FILE_COLS} FROM files WHERE file_id = ?1"))
            .map_err(|e| format!("Failed to prepare file query: {e}"))?;

        let result = stmt
            .query_row(params![file_id], stored_file_from_row)
            .ok();

        let result = result.map(|mut f| {
            Self::resolve_disk_path(&mut f);
            f
        });

        Ok(result)
    }

    pub fn get_file_metadata_batch(&self, file_ids: &[&str]) -> Result<std::collections::HashMap<String, StoredFile>, String> {
        use std::collections::HashMap;
        if file_ids.is_empty() { return Ok(HashMap::new()); }
        let placeholders: String = file_ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
        let sql = format!("SELECT {FILE_COLS} FROM files WHERE file_id IN ({placeholders})");
        let mut stmt = self.conn.prepare(&sql)
            .map_err(|e| format!("Failed to prepare batch file query: {e}"))?;
        let params: Vec<&dyn rusqlite::types::ToSql> = file_ids.iter()
            .map(|id| id as &dyn rusqlite::types::ToSql).collect();
        let rows = stmt.query_map(params.as_slice(), stored_file_from_row)
            .map_err(|e| format!("Failed to query batch file metadata: {e}"))?;
        let mut map = HashMap::new();
        for mut row in rows.flatten() {
            Self::resolve_disk_path(&mut row);
            map.insert(row.file_id.clone(), row);
        }
        Ok(map)
    }

    /// Get all files attached to a specific message.
    pub fn get_files_for_message(&self, message_id: &str) -> Result<Vec<StoredFile>, String> {
        let mut stmt = self
            .conn
            .prepare(&format!("SELECT {FILE_COLS} FROM files WHERE message_id = ?1"))
            .map_err(|e| format!("Failed to prepare files query: {e}"))?;

        let rows = stmt
            .query_map(params![message_id], stored_file_from_row)
            .map_err(|e| format!("Failed to query files: {e}"))?;

        let mut files = collect_rows(rows, "file")?;
        for f in &mut files {
            Self::resolve_disk_path(f);
        }
        Ok(files)
    }

    /// Images and videos of one conversation for the media viewer, newest first.
    ///
    /// `before_ts`/`after_ts` are exclusive millisecond bounds so a caller can page
    /// both ways from the item it opened. Hidden, expired and incomplete files, files
    /// whose message row is hidden, and files with no disk path are excluded.
    pub fn list_media_for_context(
        &self,
        context_type: &str,
        context_id: &str,
        before_ts: Option<i64>,
        after_ts: Option<i64>,
        limit: u32,
    ) -> Result<Vec<StoredMediaItem>, String> {
        let video_in = MEDIA_VIDEO_EXTS
            .iter()
            .map(|e| format!("'{e}'"))
            .collect::<Vec<_>>()
            .join(", ");
        // A DM file can only match the DM table and a channel file the channel table,
        // so one COALESCE over both is unambiguous.
        let ts_expr = "COALESCE(
                   (SELECT timestamp FROM messages WHERE message_id = files.message_id),
                   (SELECT timestamp FROM channel_messages WHERE message_id = files.message_id),
                   created_at)";
        let ord_expr = "COALESCE(
                   (SELECT order_us FROM messages WHERE message_id = files.message_id),
                   (SELECT order_us FROM channel_messages WHERE message_id = files.message_id),
                   0)";
        let album_expr = "COALESCE(
                   (SELECT album_id FROM messages WHERE message_id = files.message_id),
                   (SELECT album_id FROM channel_messages WHERE message_id = files.message_id))";
        // The bounds filter an aliased expression, so the select is wrapped rather than
        // repeating that expression three times.
        let sql = format!(
            "SELECT * FROM (
               SELECT {FILE_COLS}, content_id, {ts_expr} AS ts,
                      {ord_expr} AS ord, {album_expr} AS album FROM files
               WHERE context_type = ?1 AND context_id = ?2
                 AND completed_at IS NOT NULL
                 AND hidden_at IS NULL
                 AND expired_at IS NULL
                 AND (is_image = 1 OR lower(file_ext) IN ({video_in}))
                 AND NOT EXISTS (
                   SELECT 1 FROM messages m
                   WHERE m.message_id = files.message_id AND m.hidden_at IS NOT NULL)
                 AND NOT EXISTS (
                   SELECT 1 FROM channel_messages cm
                   WHERE cm.message_id = files.message_id AND cm.hidden_at IS NOT NULL)
             )
             WHERE (?3 IS NULL OR ts < ?3) AND (?4 IS NULL OR ts > ?4)
             ORDER BY ts DESC, ord DESC, file_id DESC
             LIMIT ?5"
        );
        // FILE_COLS is a comma list, so its column count is what the appended
        // columns sit behind.
        let extra = FILE_COLS.split(',').count();

        let mut stmt = self
            .conn
            .prepare(&sql)
            .map_err(|e| format!("Failed to prepare media query: {e}"))?;
        let rows = stmt
            .query_map(
                params![context_type, context_id, before_ts, after_ts, limit.clamp(1, 200)],
                |row| {
                    Ok(StoredMediaItem {
                        file: stored_file_from_row(row)?,
                        content_id: row.get(extra)?,
                        ts: row.get(extra + 1)?,
                        album_id: row.get(extra + 3)?,
                    })
                },
            )
            .map_err(|e| format!("Failed to query media: {e}"))?;

        let mut items = collect_rows(rows, "media")?;
        for item in &mut items {
            Self::resolve_disk_path(&mut item.file);
        }
        // A completed row with no path left is not viewable.
        items.retain(|i| i.file.disk_path.is_some());
        Ok(items)
    }

    /// Get all incomplete files (for sync resume).
    pub fn get_incomplete_files(&self) -> Result<Vec<StoredFile>, String> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "SELECT {FILE_COLS} FROM files WHERE completed_at IS NULL AND hidden_at IS NULL"
            ))
            .map_err(|e| format!("Failed to prepare incomplete files query: {e}"))?;

        let rows = stmt
            .query_map([], stored_file_from_row)
            .map_err(|e| format!("Failed to query incomplete files: {e}"))?;

        collect_rows(rows, "file")
    }

    /// Total bytes of completed files for a server; channel context_ids are
    /// "server_id:channel_id", so the match is a LIKE prefix.
    pub fn total_file_storage_for_server(&self, server_id: &str) -> Result<u64, String> {
        let pattern = format!("{server_id}:%");
        let result: i64 = self
            .conn
            .query_row(
                "SELECT COALESCE(SUM(size_bytes), 0) FROM files
                 WHERE context_type = 'channel' AND context_id LIKE ?1
                 AND completed_at IS NOT NULL",
                [&pattern],
                |row| row.get(0),
            )
            .map_err(|e| format!("Failed to sum file storage: {e}"))?;
        Ok(result.max(0) as u64)
    }

    /// Sum the byte-length of all message text for a server (across all channels).
    pub fn total_message_storage_for_server(&self, server_id: &str) -> Result<u64, String> {
        let result: i64 = self
            .conn
            .query_row(
                "SELECT COALESCE(SUM(LENGTH(text)), 0) FROM channel_messages WHERE server_id = ?1",
                params![server_id],
                |row| row.get(0),
            )
            .map_err(|e| format!("Failed to sum message storage: {e}"))?;
        Ok(result.max(0) as u64)
    }

    /// Get missing chunk indices for a file.
    pub fn get_missing_chunks(&self, file_id: &str) -> Result<Vec<u32>, String> {
        let file = self.get_file_metadata(file_id)?;
        let file = match file {
            Some(f) => f,
            None => return Err(format!("File not found: {file_id}")),
        };

        let mut stmt = self
            .conn
            .prepare(
                "SELECT chunk_index FROM file_chunks WHERE file_id = ?1",
            )
            .map_err(|e| format!("Failed to prepare chunks query: {e}"))?;

        let received: std::collections::HashSet<u32> = stmt
            .query_map(params![file_id], |row| row.get::<_, u32>(0))
            .map_err(|e| format!("Failed to query chunks: {e}"))?
            .filter_map(|r| r.ok())
            .collect();

        let missing: Vec<u32> = (0..file.chunk_count)
            .filter(|i| !received.contains(i))
            .collect();

        Ok(missing)
    }

    /// file_ids from messages that have one but no completed file entry, for finding
    /// files to download after message sync. Checks disk as well as the DB.
    ///
    /// A row the retention sweep marked EXPIRED is never returned: those bytes are gone
    /// by policy, so re-requesting them only asks holders that deleted them too.
    pub fn get_missing_file_ids(&self) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT DISTINCT cm.file_id FROM channel_messages cm
                 WHERE cm.file_id IS NOT NULL
                 AND cm.file_id NOT IN (SELECT file_id FROM files WHERE completed_at IS NOT NULL)
                 AND cm.file_id NOT IN (SELECT file_id FROM files WHERE expired_at IS NOT NULL)
                 UNION
                 SELECT DISTINCT m.file_id FROM messages m
                 WHERE m.file_id IS NOT NULL
                 AND m.file_id NOT IN (SELECT file_id FROM files WHERE completed_at IS NOT NULL)
                 AND m.file_id NOT IN (SELECT file_id FROM files WHERE expired_at IS NOT NULL)",
            )
            .map_err(|e| format!("Failed to prepare missing files query: {e}"))?;

        let rows = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query missing files: {e}"))?;

        Ok(Self::filter_ids_not_on_disk(rows))
    }

    /// Drop file ids whose bytes already exist in the files dir. Unreadable rows are
    /// skipped.
    fn filter_ids_not_on_disk(rows: impl Iterator<Item = rusqlite::Result<String>>) -> Vec<String> {
        let disk_file_ids = Self::disk_file_stems();
        rows.filter_map(|r| r.ok())
            .filter(|id| !disk_file_ids.contains(id))
            .collect()
    }

    /// File-id stems present in the files dir. A stem hit means the bytes exist,
    /// whatever the DB `completed_at` says.
    fn disk_file_stems() -> std::collections::HashSet<String> {
        let files_dir = crate::identity::data_dir()
            .unwrap_or_default()
            .join("files");
        std::fs::read_dir(&files_dir)
            .map(|entries| {
                entries.filter_map(|e| e.ok()).filter_map(|e| {
                    let name = e.file_name().to_string_lossy().to_string();
                    name.split('.').next().map(|s| s.to_string())
                }).collect()
            })
            .unwrap_or_default()
    }

    /// Like `get_missing_file_ids`, scoped to ONE DM conversation. Opening a DM must
    /// only re-request that thread's files: the account-global sweep re-requested every
    /// missing id from the DM peer on every open, leaking unrelated file ids to them.
    pub fn get_missing_file_ids_for_dm(&self, peer_id: &str) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT DISTINCT m.file_id FROM messages m
                 WHERE m.peer_id = ?1
                 AND m.file_id IS NOT NULL
                 AND m.file_id NOT IN (SELECT file_id FROM files WHERE completed_at IS NOT NULL)
                 AND m.file_id NOT IN (SELECT file_id FROM files WHERE expired_at IS NOT NULL)",
            )
            .map_err(|e| format!("Failed to prepare missing DM files query: {e}"))?;

        let rows = stmt
            .query_map([peer_id], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query missing DM files: {e}"))?;

        Ok(Self::filter_ids_not_on_disk(rows))
    }

    /// Like `get_missing_file_ids`, but scoped to ONE server's channels.
    pub fn get_missing_file_ids_for_server(&self, server_id: &str) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT DISTINCT cm.file_id FROM channel_messages cm
                 WHERE cm.server_id = ?1
                 AND cm.file_id IS NOT NULL
                 AND cm.file_id NOT IN (SELECT file_id FROM files WHERE completed_at IS NOT NULL)
                 AND cm.file_id NOT IN (SELECT file_id FROM files WHERE expired_at IS NOT NULL)",
            )
            .map_err(|e| format!("Failed to prepare missing server files query: {e}"))?;

        let rows = stmt
            .query_map([server_id], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query missing server files: {e}"))?;

        Ok(Self::filter_ids_not_on_disk(rows))
    }

    /// Scan completed files for stale disk_paths and reset those rows to incomplete so
    /// they are re-requested. Returns how many were reset.
    ///
    /// A stale ABSOLUTE path is not proof the bytes are gone: the data dir can move
    /// (iOS container rotation, profile changes) while the file is still at the current
    /// `data_dir/files/{file_id}.{ext}`. Those rows are HEALED instead of nulled, since
    /// nulling them marked good files missing and re-downloaded bytes we already hold.
    pub fn reset_stale_file_paths(&self) -> Result<u32, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT file_id, file_ext, disk_path FROM files
                 WHERE completed_at IS NOT NULL AND disk_path IS NOT NULL",
            )
            .map_err(|e| format!("Failed to prepare stale files query: {e}"))?;

        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })
            .map_err(|e| format!("Failed to query completed files: {e}"))?;

        let files_dir = crate::identity::data_dir().ok().map(|d| d.join("files"));
        let mut stale_ids = Vec::new();
        let mut healed: Vec<(String, String)> = Vec::new();
        for row in rows {
            if let Ok((file_id, file_ext, disk_path)) = row {
                if std::path::Path::new(&disk_path).exists() {
                    continue;
                }
                // Check the current canonical location before declaring the bytes missing.
                let current = files_dir
                    .as_ref()
                    .map(|d| d.join(format!("{file_id}.{file_ext}")));
                match current {
                    Some(p) if p.exists() => {
                        healed.push((file_id, p.to_string_lossy().to_string()));
                    }
                    _ => stale_ids.push(file_id),
                }
            }
        }

        if stale_ids.is_empty() && healed.is_empty() {
            return Ok(0);
        }

        let count = stale_ids.len() as u32;
        self.conn.execute_batch("BEGIN").map_err(|e| format!("BEGIN: {e}"))?;
        for (file_id, new_path) in &healed {
            self.conn
                .execute(
                    "UPDATE files SET disk_path = ?2 WHERE file_id = ?1",
                    rusqlite::params![file_id, new_path],
                )
                .map_err(|e| {
                    let _ = self.conn.execute_batch("ROLLBACK");
                    format!("Failed to heal stale file path {file_id}: {e}")
                })?;
        }
        for file_id in &stale_ids {
            self.conn
                .execute(
                    "UPDATE files SET disk_path = NULL, completed_at = NULL WHERE file_id = ?1",
                    rusqlite::params![file_id],
                )
                .map_err(|e| {
                    let _ = self.conn.execute_batch("ROLLBACK");
                    format!("Failed to reset stale file {file_id}: {e}")
                })?;
        }
        self.conn.execute_batch("COMMIT").map_err(|e| format!("COMMIT: {e}"))?;

        Ok(count)
    }

    /// Forget every path an imported database names outside `data_root`: another
    /// device's disk, or another profile's on this one, is never read, served or
    /// deleted from here. A file whose bytes landed with the snapshot points at its
    /// own copy; any other comes back through the normal gated pull. Returns the rows
    /// changed.
    pub fn forget_foreign_paths(&self, data_root: &std::path::Path) -> Result<u32, String> {
        self.forget_foreign_paths_staged(data_root, &data_root.join("files"))
    }

    /// [`Self::forget_foreign_paths`] for a database still in a landing's stage: a file
    /// whose bytes sit in `landed_files` points at where they will be placed. A path
    /// counts as ours only in its content folder under its own name, and a value that
    /// does not read as text counts as foreign; an error means nothing was changed.
    pub fn forget_foreign_paths_staged(
        &self,
        data_root: &std::path::Path,
        landed_files: &std::path::Path,
    ) -> Result<u32, String> {
        use rusqlite::types::ValueRef;
        use std::path::Path;
        // None = NULL, Some(None) = a value that is not text.
        fn column(v: ValueRef<'_>) -> Option<Option<String>> {
            match v {
                ValueRef::Null => None,
                ValueRef::Text(t) => Some(std::str::from_utf8(t).ok().map(str::to_owned)),
                _ => Some(None),
            }
        }
        let files_dir = data_root.join("files");
        let shares_dir = data_root.join("shares");
        // `final_file_path`'s shape: a trailing dot or an empty extension would name
        // another file on Windows.
        let content_name = |id: Option<&str>, ext: Option<&str>| {
            let (id, ext) = (id?, ext?);
            let id_ok = (1..=64).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric());
            (id_ok && crate::node::file_transfer::is_wire_ext(ext)).then(|| format!("{id}.{ext}"))
        };
        // A rowid and its values, each `column`'s reading.
        type Row = (i64, Vec<Option<Option<String>>>);
        let read_rows = |sql: &str, width: usize| -> Result<Vec<Row>, String> {
            let mut stmt = self.conn.prepare(sql).map_err(|e| format!("Failed to prepare path query: {e}"))?;
            let mut rows = stmt.query([]).map_err(|e| format!("Failed to query paths: {e}"))?;
            let mut out = Vec::new();
            while let Some(r) = rows.next().map_err(|e| format!("Failed to read paths: {e}"))? {
                let rowid: i64 = r.get(0).map_err(|e| format!("Failed to read a rowid: {e}"))?;
                let values = (1..=width)
                    .map(|i| r.get_ref(i).map(column))
                    .collect::<Result<_, _>>()
                    .map_err(|e| format!("Failed to read paths: {e}"))?;
                out.push((rowid, values));
            }
            Ok(out)
        };
        let files = read_rows("SELECT rowid, file_id, file_ext, disk_path FROM files WHERE disk_path IS NOT NULL", 3)?;
        let shares = read_rows(
            "SELECT rowid, disk_path, save_dir FROM shares WHERE disk_path IS NOT NULL OR save_dir IS NOT NULL",
            2,
        )?;

        let mut changed = 0u32;
        self.conn.execute_batch("BEGIN").map_err(|e| format!("BEGIN: {e}"))?;
        let result = (|| -> Result<(), String> {
            for (rowid, row) in &files {
                let text = |i: usize| row[i].clone().flatten();
                let name = content_name(text(0).as_deref(), text(1).as_deref());
                let ours = match (text(2), &name) {
                    (Some(p), Some(name)) => {
                        let p = Path::new(&p);
                        p.parent() == Some(files_dir.as_path()) && p.file_name() == Some(std::ffi::OsStr::new(name))
                    }
                    _ => false,
                };
                if ours {
                    continue;
                }
                match name.filter(|name| landed_files.join(name).is_file()) {
                    Some(name) => self
                        .conn
                        .execute(
                            "UPDATE files SET disk_path = ?2 WHERE rowid = ?1",
                            params![rowid, files_dir.join(name).to_string_lossy()],
                        )
                        .map_err(|e| format!("Failed to repoint a file: {e}"))?,
                    None => self
                        .conn
                        .execute(
                            "UPDATE files SET disk_path = NULL, completed_at = NULL WHERE rowid = ?1",
                            params![rowid],
                        )
                        .map_err(|e| format!("Failed to reset a file: {e}"))?,
                };
                changed += 1;
            }
            for (rowid, row) in &shares {
                let foreign_file = row[0].as_ref().is_some_and(|p| {
                    !p.as_deref().is_some_and(|p| {
                        let p = Path::new(p);
                        p.parent() == Some(shares_dir.as_path())
                            && p.file_name()
                                .and_then(|n| n.to_str())
                                .is_some_and(crate::node::share_handler::is_inert_file_name)
                    })
                });
                if foreign_file {
                    self.conn
                        .execute(
                            "UPDATE shares SET disk_path = NULL, seeding = 0,
                                 state = CASE WHEN state = 'completed' THEN 'stale' ELSE state END
                             WHERE rowid = ?1",
                            params![rowid],
                        )
                        .map_err(|e| format!("Failed to reset a share: {e}"))?;
                    changed += 1;
                }
                if row[1].as_ref().is_some_and(|p| p.as_deref().map(Path::new) != Some(shares_dir.as_path())) {
                    self.conn
                        .execute("UPDATE shares SET save_dir = NULL WHERE rowid = ?1", params![rowid])
                        .map_err(|e| format!("Failed to reset a share folder: {e}"))?;
                    changed += 1;
                }
            }
            // Both name a file or folder the user picked on the device that made the
            // database, never one in a content folder here.
            let settings = self
                .conn
                .execute("DELETE FROM app_settings WHERE key IN ('ringtone_path', 'share_download_path')", [])
                .map_err(|e| format!("Failed to forget path settings: {e}"))?;
            changed += settings as u32;
            Ok(())
        })();
        match result {
            Ok(()) => {
                self.conn.execute_batch("COMMIT").map_err(|e| format!("COMMIT: {e}"))?;
                Ok(changed)
            }
            Err(e) => {
                let _ = self.conn.execute_batch("ROLLBACK");
                Err(e)
            }
        }
    }

    // ── Storage Manager (downloaded-file disk usage) ────────────────────────

    /// Per-context disk usage of downloaded files as `(context_type, context_id, bytes,
    /// count)`, for files completed AND still on disk.
    pub fn storage_breakdown(&self) -> Result<Vec<(String, String, u64, u32)>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT context_type, context_id,
                        COALESCE(SUM(size_bytes), 0) AS bytes,
                        COUNT(*) AS cnt
                 FROM files
                 WHERE completed_at IS NOT NULL AND disk_path IS NOT NULL
                 GROUP BY context_type, context_id",
            )
            .map_err(|e| format!("Failed to prepare storage_breakdown: {e}"))?;

        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)? as u64,
                    row.get::<_, i64>(3)? as u32,
                ))
            })
            .map_err(|e| format!("Failed to query storage_breakdown: {e}"))?;

        let mut out = Vec::new();
        for row in rows.flatten() {
            out.push(row);
        }
        Ok(out)
    }

    /// Get the on-disk paths of completed files for a single conversation/server.
    pub fn disk_paths_for_context(
        &self,
        context_type: &str,
        context_id: &str,
    ) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT disk_path FROM files
                 WHERE context_type = ?1 AND context_id = ?2
                   AND completed_at IS NOT NULL AND disk_path IS NOT NULL",
            )
            .map_err(|e| format!("Failed to prepare disk_paths_for_context: {e}"))?;
        let rows = stmt
            .query_map(rusqlite::params![context_type, context_id], |row| {
                row.get::<_, String>(0)
            })
            .map_err(|e| format!("Failed to query disk_paths_for_context: {e}"))?;
        Ok(rows.flatten().collect())
    }

    /// Get every on-disk path of completed files (all conversations/servers).
    pub fn all_on_disk_paths(&self) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT disk_path FROM files
                 WHERE completed_at IS NOT NULL AND disk_path IS NOT NULL",
            )
            .map_err(|e| format!("Failed to prepare all_on_disk_paths: {e}"))?;
        let rows = stmt
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query all_on_disk_paths: {e}"))?;
        Ok(rows.flatten().collect())
    }

    /// Null disk_path and completed_at for one context's files, so the message renders
    /// as a re-downloadable card. Returns rows affected.
    pub fn null_disk_path_for_context(
        &self,
        context_type: &str,
        context_id: &str,
    ) -> Result<u32, String> {
        let n = self
            .conn
            .execute(
                "UPDATE files SET disk_path = NULL, completed_at = NULL
                 WHERE context_type = ?1 AND context_id = ?2
                   AND completed_at IS NOT NULL",
                rusqlite::params![context_type, context_id],
            )
            .map_err(|e| format!("Failed to null disk paths for context: {e}"))?;
        Ok(n as u32)
    }

    /// Null the disk_path + completed_at for ALL completed files. Returns rows
    /// affected. Used by "Clear all cached file bytes".
    pub fn null_disk_path_all(&self) -> Result<u32, String> {
        let n = self
            .conn
            .execute(
                "UPDATE files SET disk_path = NULL, completed_at = NULL
                 WHERE completed_at IS NOT NULL",
                [],
            )
            .map_err(|e| format!("Failed to null all disk paths: {e}"))?;
        Ok(n as u32)
    }

    /// file_ids for missing *image* files in a server, for late-joiner image sync in 6+
    /// member servers where other files use vault erasure shards.
    pub fn get_missing_image_file_ids_for_server(&self, server_id: &str) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT DISTINCT cm.file_id FROM channel_messages cm
                 JOIN files f ON cm.file_id = f.file_id
                 WHERE cm.server_id = ?1
                 AND f.is_image = 1
                 AND f.completed_at IS NULL
                 AND f.expired_at IS NULL",
            )
            .map_err(|e| format!("Failed to prepare missing image files query: {e}"))?;

        let rows = stmt
            .query_map([server_id], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query missing image files: {e}"))?;

        let mut ids = Vec::new();
        for row in rows {
            if let Ok(id) = row {
                ids.push(id);
            }
        }
        Ok(ids)
    }

    /// Link a vault content_id to a file record via its message_id.
    /// Who sent each file card a message carries.
    pub fn file_senders_for_message(&self, message_id: &str) -> Result<Vec<String>, String> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT sender_id FROM files WHERE message_id = ?1")
            .map_err(|e| format!("Failed to prepare file sender query: {e}"))?;
        let rows = stmt
            .query_map(params![message_id], |row| row.get::<_, String>(0))
            .map_err(|e| format!("Failed to query file senders: {e}"))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| format!("Failed to read file sender: {e}"))
    }

    pub fn set_file_content_id(&self, message_id: &str, content_id: &str) -> Result<(), String> {
        self.conn
            .execute(
                "UPDATE files SET content_id = ?1 WHERE message_id = ?2",
                params![content_id, message_id],
            )
            .map_err(|e| format!("Failed to set file content_id: {e}"))?;
        Ok(())
    }

    /// Every file card linked to a vault content id.
    pub fn files_with_content_id(&self, content_id: &str) -> Result<Vec<StoredFile>, String> {
        let mut stmt = self
            .conn
            .prepare(&format!("SELECT {FILE_COLS} FROM files WHERE content_id = ?1"))
            .map_err(|e| format!("Failed to prepare content file query: {e}"))?;
        let rows = stmt
            .query_map(params![content_id], stored_file_from_row)
            .map_err(|e| format!("Failed to query content files: {e}"))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| format!("Failed to read content file: {e}"))
    }

    /// The vault content_id for a file, `None` when it has none (DM files, small
    /// servers).
    pub fn get_content_id_for_file(&self, file_id: &str) -> Result<Option<String>, String> {
        self.conn
            .query_row(
                "SELECT content_id FROM files WHERE file_id = ?1",
                params![file_id],
                |row| row.get::<_, Option<String>>(0),
            )
            .map_err(|e| format!("Failed to query content_id: {e}"))
    }

    // -- Hollow Share (Phase 7A) --

    /// Insert or replace a share row, both at create time and when a link is opened
    /// before its manifest arrives.
    #[allow(clippy::too_many_arguments)]
    pub fn upsert_share(
        &self,
        root_hash: &str,
        file_name: &str,
        file_ext: &str,
        mime: &str,
        total_size: u64,
        chunk_size: u32,
        chunk_count: u32,
        manifest_json: &str,
        encryption_key: &[u8],
        share_link: &str,
        state: &str,
        seeding: bool,
        disk_path: Option<&str>,
        save_dir: Option<&str>,
        created_at: i64,
        server_id: Option<&str>,
        context_type: Option<&str>,
    ) -> Result<(), String> {
        self.conn.execute(
            "INSERT OR REPLACE INTO shares (
                root_hash, file_name, file_ext, mime, total_size, chunk_size, chunk_count,
                manifest_json, encryption_key, share_link, state, seeding, disk_path, save_dir,
                bytes_uploaded, created_at, completed_at, server_id, context_type
            ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,
                COALESCE((SELECT bytes_uploaded FROM shares WHERE root_hash = ?1), 0),
                ?15,
                (SELECT completed_at FROM shares WHERE root_hash = ?1),
                ?16, ?17
            )",
            params![
                root_hash, file_name, file_ext, mime,
                total_size as i64, chunk_size as i64, chunk_count as i64,
                manifest_json, encryption_key, share_link, state, seeding as i32,
                disk_path, save_dir, created_at, server_id, context_type,
            ],
        ).map_err(|e| format!("Failed to upsert share: {e}"))?;
        Ok(())
    }

    /// Update only the save_dir for a share.
    pub fn set_share_save_dir(&self, root_hash: &str, save_dir: &str) -> Result<(), String> {
        self.conn.execute(
            "UPDATE shares SET save_dir = ?2 WHERE root_hash = ?1",
            params![root_hash, save_dir],
        ).map_err(|e| format!("Failed to set save_dir: {e}"))?;
        Ok(())
    }

    pub fn load_share(&self, root_hash: &str) -> Result<Option<StoredShare>, String> {
        let mut stmt = self.conn.prepare(
            "SELECT root_hash, file_name, file_ext, mime, total_size, chunk_size, chunk_count,
                    manifest_json, encryption_key, share_link, state, seeding, disk_path,
                    bytes_uploaded, created_at, completed_at, save_dir, server_id, context_type
             FROM shares WHERE root_hash = ?1",
        ).map_err(|e| format!("Failed to prepare load_share: {e}"))?;
        let mut rows = stmt.query(params![root_hash])
            .map_err(|e| format!("Failed to query share: {e}"))?;
        if let Some(row) = rows.next().map_err(|e| format!("Row error: {e}"))? {
            Ok(Some(stored_share_from_row(row)?))
        } else {
            Ok(None)
        }
    }

    pub fn load_shares(&self) -> Result<Vec<StoredShare>, String> {
        let mut stmt = self.conn.prepare(
            "SELECT root_hash, file_name, file_ext, mime, total_size, chunk_size, chunk_count,
                    manifest_json, encryption_key, share_link, state, seeding, disk_path,
                    bytes_uploaded, created_at, completed_at, save_dir, server_id, context_type
             FROM shares ORDER BY created_at DESC",
        ).map_err(|e| format!("Failed to prepare load_shares: {e}"))?;
        let mut rows = stmt.query([])
            .map_err(|e| format!("Failed to query shares: {e}"))?;
        let mut out = Vec::new();
        while let Some(row) = rows.next().map_err(|e| format!("Row error: {e}"))? {
            out.push(stored_share_from_row(row)?);
        }
        Ok(out)
    }

    pub fn mark_share_complete(&self, root_hash: &str, disk_path: &str, completed_at: i64) -> Result<(), String> {
        self.conn.execute(
            "UPDATE shares SET state = 'completed', disk_path = ?2, completed_at = ?3 WHERE root_hash = ?1",
            params![root_hash, disk_path, completed_at],
        ).map_err(|e| format!("Failed to mark share complete: {e}"))?;
        Ok(())
    }

    pub fn update_share_disk_path(&self, root_hash: &str, disk_path: &str) -> Result<(), String> {
        self.conn.execute(
            "UPDATE shares SET disk_path = ?2 WHERE root_hash = ?1",
            params![root_hash, disk_path],
        ).map_err(|e| format!("Failed to update share disk_path: {e}"))?;
        Ok(())
    }

    pub fn set_share_state(&self, root_hash: &str, state: &str) -> Result<(), String> {
        self.conn.execute(
            "UPDATE shares SET state = ?2 WHERE root_hash = ?1",
            params![root_hash, state],
        ).map_err(|e| format!("Failed to set share state: {e}"))?;
        Ok(())
    }

    pub fn set_share_seeding(&self, root_hash: &str, seeding: bool) -> Result<(), String> {
        self.conn.execute(
            "UPDATE shares SET seeding = ?2 WHERE root_hash = ?1",
            params![root_hash, seeding as i32],
        ).map_err(|e| format!("Failed to set share seeding: {e}"))?;
        Ok(())
    }

    pub fn add_share_bytes_uploaded(&self, root_hash: &str, delta: u64) -> Result<(), String> {
        self.conn.execute(
            "UPDATE shares SET bytes_uploaded = bytes_uploaded + ?2 WHERE root_hash = ?1",
            params![root_hash, delta as i64],
        ).map_err(|e| format!("Failed to add share bytes_uploaded: {e}"))?;
        Ok(())
    }

    pub fn delete_share(&self, root_hash: &str) -> Result<(), String> {
        self.conn.execute(
            "DELETE FROM share_chunks WHERE root_hash = ?1",
            params![root_hash],
        ).map_err(|e| format!("Failed to delete share_chunks row: {e}"))?;
        self.conn.execute(
            "DELETE FROM shares WHERE root_hash = ?1",
            params![root_hash],
        ).map_err(|e| format!("Failed to delete share row: {e}"))?;
        Ok(())
    }

    pub fn save_chunk_bitmap(&self, root_hash: &str, bitmap: &[u8], updated_at: i64) -> Result<(), String> {
        self.conn.execute(
            "INSERT OR REPLACE INTO share_chunks (root_hash, bitmap_blob, updated_at) VALUES (?1, ?2, ?3)",
            params![root_hash, bitmap, updated_at],
        ).map_err(|e| format!("Failed to save chunk bitmap: {e}"))?;
        Ok(())
    }

    pub fn load_chunk_bitmap(&self, root_hash: &str) -> Result<Option<Vec<u8>>, String> {
        self.conn
            .query_row(
                "SELECT bitmap_blob FROM share_chunks WHERE root_hash = ?1",
                params![root_hash],
                |row| row.get::<_, Vec<u8>>(0),
            )
            .map(Some)
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(format!("Failed to load chunk bitmap: {other}")),
            })
    }
}

/// A recorded identity event for a contact. `kind` is one of the
/// [`crate::node::security_alerts`] constants and `detail` carries the device id or
/// the new Olm identity key, so the UI can show WHAT changed.
/// something did.
#[derive(Clone, Debug)]
pub struct SecurityAlertRow {
    pub alert_id: String,
    /// MASTER peer_id — an alert is about a person.
    pub peer_id: String,
    pub kind: String,
    pub detail: String,
    pub created_at: i64,
    /// `None` while the alert is still unread.
    pub acknowledged_at: Option<i64>,
    /// When the device it names left the roster; `None` while it is still there.
    pub resolved_at: Option<i64>,
}

/// A persisted server join that has not completed yet. Survives restarts on purpose:
/// parking a join means every member was offline, so the answer may arrive days
/// later on another run of the app.
#[derive(Clone, Debug)]
pub struct PendingJoinRow {
    pub server_id: String,
    /// Unix MILLISECONDS: the request nonce every answer must name.
    pub requested_at: i64,
    pub nsfw_confirmed: bool,
    pub twitch_proof_json: Option<String>,
    /// `pending` (still waiting) or `rejected` (a member said no).
    pub state: String,
    /// The reject reason string; empty while pending.
    pub reason: String,
    /// Unix MILLISECONDS of the last `~join` ring deposit.
    pub last_deposited_at: i64,
    pub created_at: i64,
    /// Base64 of the MLS KeyPackage this join will be added with; `None` for an older
    /// row or a join that never parked. Persisted because the private half lives in the
    /// MLS store and the answer can arrive days later.
    pub key_package: Option<String>,
    /// The owner the invite pinned; `None` for a link without one.
    pub owner_pin: Option<String>,
    /// The server's join key from the invite; `None` on a row from before 0.12,
    /// which can never be sent.
    pub join_key: Option<String>,
    /// Our reply key's secret half, hex: answers to the parked copy are sealed to it.
    pub reply_secret: Option<String>,
}

/// Persisted conference room (host-local; reports/shipped/voice-and-media/CONFERENCES_PLAN.md).
pub struct ConferenceRow {
    pub conf_id: String,
    pub name: String,
    pub waiting_room: bool,
    /// `conference::derive_code_key` of the access code (never plaintext).
    pub access_code_hash: Option<String>,
    /// The nonce the room's id hashes from with the host's master; `None` on a room
    /// made before 0.12, which cannot be started.
    pub host_nonce: Option<String>,
    /// The key the room's link carries; kept once set, so the link stays the same.
    pub link_key: Option<String>,
    /// JSON array of co-host master ids (phase 2 enforcement).
    pub co_hosts: String,
    pub broadcast_mode: bool,
    pub created_at: i64,
}

/// Persisted share row.
pub struct StoredShare {
    pub root_hash: String,
    pub file_name: String,
    pub file_ext: String,
    pub mime: String,
    pub total_size: u64,
    pub chunk_size: u32,
    pub chunk_count: u32,
    pub manifest_json: String,
    pub encryption_key: Vec<u8>,
    pub share_link: String,
    pub state: String,
    pub seeding: bool,
    pub disk_path: Option<String>,
    pub bytes_uploaded: u64,
    pub created_at: i64,
    pub completed_at: Option<i64>,
    pub save_dir: Option<String>,
    pub server_id: Option<String>,
    pub context_type: Option<String>,
}

fn stored_share_from_row(row: &rusqlite::Row<'_>) -> Result<StoredShare, String> {
    Ok(StoredShare {
        root_hash:      row.get(0).map_err(|e| format!("col 0: {e}"))?,
        file_name:      row.get(1).map_err(|e| format!("col 1: {e}"))?,
        file_ext:       row.get(2).map_err(|e| format!("col 2: {e}"))?,
        mime:           row.get(3).map_err(|e| format!("col 3: {e}"))?,
        total_size:     row.get::<_, i64>(4).map_err(|e| format!("col 4: {e}"))? as u64,
        chunk_size:     row.get::<_, i64>(5).map_err(|e| format!("col 5: {e}"))? as u32,
        chunk_count:    row.get::<_, i64>(6).map_err(|e| format!("col 6: {e}"))? as u32,
        manifest_json:  row.get(7).map_err(|e| format!("col 7: {e}"))?,
        encryption_key: row.get(8).map_err(|e| format!("col 8: {e}"))?,
        share_link:     row.get(9).map_err(|e| format!("col 9: {e}"))?,
        state:          row.get(10).map_err(|e| format!("col 10: {e}"))?,
        seeding:        row.get::<_, i32>(11).map_err(|e| format!("col 11: {e}"))? != 0,
        disk_path:      row.get::<_, Option<String>>(12).map_err(|e| format!("col 12: {e}"))?,
        bytes_uploaded: row.get::<_, i64>(13).map_err(|e| format!("col 13: {e}"))? as u64,
        created_at:     row.get(14).map_err(|e| format!("col 14: {e}"))?,
        completed_at:   row.get::<_, Option<i64>>(15).map_err(|e| format!("col 15: {e}"))?,
        save_dir:       row.get::<_, Option<String>>(16).map_err(|e| format!("col 16: {e}"))?,
        server_id:      row.get::<_, Option<String>>(17).unwrap_or(None),
        context_type:   row.get::<_, Option<String>>(18).unwrap_or(None),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// In-memory SQLCipher store for tests; the passphrase must be valid hex.
    fn mem_store() -> MessageStore {
        MessageStore::open(":memory:", &"ab".repeat(32)).expect("open in-memory store")
    }

    fn call(id: &str, peer: &str, started: i64, outcome: &str) -> CallRecordRow {
        CallRecordRow {
            call_id: id.into(),
            peer_id: peer.into(),
            outgoing: true,
            video: false,
            outcome: outcome.into(),
            started_at: started,
            connected_at: Some(started + 2_000),
            ended_at: started + 242_000,
        }
    }

    /// #97: the overlay columns and table arrive by additive migration, so a database
    /// from before them opens with every row intact and the field absent.
    #[test]
    fn an_existing_database_takes_the_overlay_schema() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let key = "ab".repeat(32);
        let old = tmp.path().join("old.db").to_string_lossy().into_owned();
        {
            let store = MessageStore::open(&old, &key).unwrap();
            assert!(store.save_profile_card("friend", "Fern", 10, "", None).unwrap());
            // Back to the shape a pre-overlay build left on disk.
            store.conn.execute_batch(
                "ALTER TABLE user_profiles DROP COLUMN stream_overlay;
                 ALTER TABLE user_profiles DROP COLUMN stream_overlay_at;
                 DROP TABLE overlay_people;
                 PRAGMA wal_checkpoint(TRUNCATE);",
            ).unwrap();
        }
        // A copy at a new path is a database this process has never migrated.
        let copy = tmp.path().join("copy.db").to_string_lossy().into_owned();
        std::fs::copy(&old, &copy).unwrap();
        let store = MessageStore::open(&copy, &key).unwrap();
        assert_eq!(store.load_profile("friend").unwrap().map(|p| p.display_name).as_deref(), Some("Fern"));
        assert_eq!(store.load_stream_overlay("friend").unwrap(), None, "absent until a field arrives");
        assert!(store.save_stream_overlay("friend", "{}", 5, false).unwrap());
        assert_eq!(store.load_stream_overlay("friend").unwrap(), Some(("{}".to_string(), 5)));
        assert_eq!(store.overlay_add_person("friend", 1).unwrap(), 1);
    }

    /// A deleted server leaves none of its blobs behind, and another server keeps its own.
    #[test]
    fn deleting_a_server_drops_its_blobs() {
        let store = mem_store();
        store.save_server_state("gone", "{}").unwrap();
        store.save_server_blob("gone", "server_avatar", "a").unwrap();
        store.save_server_blob("gone", "crdt_resync_mark", "m").unwrap();
        store.save_server_blob("kept", "server_avatar", "k").unwrap();
        store.delete_server_state("gone").unwrap();
        assert_eq!(store.load_server_blob("gone", "server_avatar").unwrap(), None);
        assert_eq!(store.load_server_blob("gone", "crdt_resync_mark").unwrap(), None);
        assert_eq!(store.load_server_blob("kept", "server_avatar").unwrap().as_deref(), Some("k"));
    }

    /// AR-29 (b3-fix): the roster freshness and ask tables arrive by additive migration,
    /// so a database from before them opens with its rows intact.
    #[test]
    fn b3_fix_an_existing_database_takes_the_roster_reach_tables() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let key = "ab".repeat(32);
        let old = tmp.path().join("old.db").to_string_lossy().into_owned();
        {
            let store = MessageStore::open(&old, &key).unwrap();
            assert!(store.save_profile_card("friend", "Fern", 10, "", None).unwrap());
            store.conn.execute_batch(
                "DROP TABLE roster_confirms;
                 DROP TABLE roster_asks_due;
                 PRAGMA wal_checkpoint(TRUNCATE);",
            ).unwrap();
        }
        let copy = tmp.path().join("copy.db").to_string_lossy().into_owned();
        std::fs::copy(&old, &copy).unwrap();
        let store = MessageStore::open(&copy, &key).unwrap();
        assert_eq!(store.load_profile("friend").unwrap().map(|p| p.display_name).as_deref(), Some("Fern"));
        assert_eq!(store.roster_confirmed_at("m", "d"), None);
        store.stamp_roster_confirmed("m", "d", 5).unwrap();
        assert_eq!(store.roster_confirm_slots("m").get("d"), Some(&(5, None)));
        store.add_roster_ask_due("m", "d", 5, 8).unwrap();
        assert_eq!(store.take_roster_asks_due(), [("m".to_string(), "d".to_string())]);
    }

    /// AR-29 (b3-fix L5): a stamp is our clock's now and replaces the one before it, so
    /// one written while the clock ran ahead never sticks; asks are noted at most `cap`.
    #[test]
    fn b3_fix_roster_stamps_replace_and_noted_asks_stay_bounded() {
        let store = mem_store();
        store.stamp_roster_confirmed("m", "d", 9_000_000).unwrap();
        store.stamp_roster_confirmed("m", "d", 1_000).unwrap();
        assert_eq!(store.roster_confirmed_at("m", "d"), Some(1_000), "a stamp from ahead of the clock stuck");
        store.mark_roster_expiry_asked("m", "d", 2_000).unwrap();
        assert_eq!(store.roster_confirm_slots("m").get("d"), Some(&(1_000, Some(2_000))));
        for i in 0..10 {
            store.add_roster_ask_due("m", &format!("d{i}"), i, 4).unwrap();
        }
        let due = store.take_roster_asks_due();
        assert_eq!(due.iter().map(|(_, d)| d.as_str()).collect::<Vec<_>>(), ["d6", "d7", "d8", "d9"], "the newest few, oldest first");
        assert!(store.take_roster_asks_due().is_empty(), "taken once");
    }

    #[test]
    fn a_stream_overlay_field_is_newest_wins_and_needs_a_row_unless_ours() {
        let store = mem_store();
        assert!(!store.save_stream_overlay("stranger", "{\"v\":1}", 5, false).unwrap(), "no row, nothing kept");
        assert_eq!(store.load_stream_overlay("stranger").unwrap(), None);
        assert!(store.save_stream_overlay("me", "a", 5, true).unwrap(), "our own row is made");
        store.save_profile_card("pal", "Pal", 1, "", None).unwrap();
        assert!(store.save_stream_overlay("pal", "new", 9, false).unwrap());
        assert!(!store.save_stream_overlay("pal", "old", 8, false).unwrap(), "older never replaces newer");
        assert!(!store.save_stream_overlay("pal", "same", 9, false).unwrap(), "an equal stamp changes nothing");
        assert!(!store.save_stream_overlay("me", "old", 4, true).unwrap());
        assert_eq!(store.load_stream_overlay("pal").unwrap(), Some(("new".to_string(), 9)));
        assert_eq!(store.load_stream_overlay("me").unwrap(), Some(("a".to_string(), 5)));
    }

    #[test]
    fn overlay_slots_are_stable_and_never_reused() {
        let store = mem_store();
        assert_eq!(store.overlay_add_person("a", 1).unwrap(), 1);
        assert_eq!(store.overlay_add_person("b", 2).unwrap(), 2);
        assert_eq!(store.overlay_add_person("a", 3).unwrap(), 1, "adding again keeps the slot");
        assert!(store.overlay_remove_person("b").unwrap().is_some());
        assert!(store.overlay_remove_person("b").unwrap().is_none());
        assert_eq!(store.overlay_add_person("c", 4).unwrap(), 3, "a freed slot is not handed to someone else");
        assert!(store.overlay_set_local_look("a", Some("{}")).unwrap());
        assert!(store.overlay_set_their_look("a", Some("{\"v\":1}"), 7).unwrap());
        let a = store.overlay_person("a").unwrap().unwrap();
        assert_eq!((a.local_look.as_deref(), a.their_look.as_deref(), a.held_stamp), (Some("{}"), Some("{\"v\":1}"), 7));
        assert!(!store.overlay_set_local_look("zz", Some("{}")).unwrap(), "no row for a person never added");
        assert_eq!(store.overlay_people().unwrap().iter().map(|p| p.slot).collect::<Vec<_>>(), vec![1, 3]);
    }

    /// A verdict is only one this install computed (AR-28): a restored or linked
    /// database arrives with none, so a source that wrote "pass" cannot vouch for bytes.
    #[test]
    fn a_staged_database_loses_its_image_verdicts() {
        let store = mem_store();
        store.record_image_verdict("h", 1, 1).unwrap();
        assert!(store.image_verdict("h", 1).is_some());
        store.scrub_device_secrets().unwrap();
        assert_eq!(store.image_verdict("h", 1), None);
    }

    /// A removal this device held for its retire round is this device's own work: a
    /// device landing a copy never finishes it (lead decision 11-05).
    #[test]
    fn a_staged_database_loses_its_held_removals() {
        let store = mem_store();
        store.save_setting("retire_held:dev", "one").unwrap();
        store.save_setting("retire_heldx", "kept").unwrap();
        store.save_setting("settle_owed:lost:dev", "{}").unwrap();
        store.scrub_device_secrets().unwrap();
        assert_eq!(store.load_setting("retire_held:dev").unwrap(), None);
        assert_eq!(store.load_setting("settle_owed:lost:dev").unwrap(), None, "an owed settling is this device's own work too");
        assert_eq!(store.load_setting("retire_heldx").unwrap().as_deref(), Some("kept"));
    }

    /// Read marks and replay-guard nonces describe this device's own Olm sessions and
    /// frames: a device landing a copy holds neither, so a copied mark would turn the
    /// re-key it needs into a quiet drop (AR-35 review LOW 5).
    #[test]
    fn a_staged_database_loses_its_olm_read_marks_and_live_frame_nonces() {
        let store = mem_store();
        store.save_olm_read_mark("peer", 5).unwrap();
        assert!(store.insert_live_frame_nonce("peer", &[1; 16], i64::MAX, "peer", false).unwrap());
        store.scrub_device_secrets().unwrap();
        assert!(store.load_olm_read_marks().unwrap().is_empty(), "a copy carried this device's read marks");
        assert!(store.load_live_frame_nonces(0, i64::MAX).unwrap().is_empty(), "a copy carried this device's live frame nonces");
    }

    /// Overlay images and rail blobs never share a row: the same bytes held as both
    /// are two rows, and deleting one leaves the other.
    #[test]
    fn overlay_images_live_apart_from_the_rail() {
        let store = mem_store();
        assert!(store.save_overlay_blob("h", b"x", false).unwrap());
        assert!(!store.save_overlay_blob("h", b"x", false).unwrap(), "already held");
        assert!(!store.has_emote_blob("h").unwrap(), "the rail never sees an overlay image");
        store.save_asset_blob("h", b"x", false, "emote").unwrap();
        assert_eq!(store.asset_blob_kind("h").unwrap().as_deref(), Some("emote"), "the rail stores its own copy");
        assert!(store.delete_overlay_blob("h").unwrap());
        assert!(store.has_emote_blob("h").unwrap(), "deleting the overlay image leaves the emote");
        assert!(!store.has_overlay_blob("h").unwrap());
        assert_eq!(store.load_overlay_blob("h").unwrap(), None);
    }

    /// D6: a guest's store is shared memory: every open sees the same rows while one
    /// connection holds it, and nothing of it outlives the last one.
    #[test]
    fn a_guest_store_lives_in_memory_only_while_held() {
        let path = guest_store_path("test-held");
        let key = "ab".repeat(32);
        let keeper = MessageStore::open(&path, &key).unwrap();
        MessageStore::open(&path, &key).unwrap()
            .insert_channel_message("s", "c", "al", "hi", false, 1, None, None, Some("m1"), None, None, None, None)
            .unwrap();
        assert!(MessageStore::open(&path, &key).unwrap().channel_message_exists("m1"), "seen by the next open");
        drop(keeper);
        assert!(!MessageStore::open(&path, &key).unwrap().channel_message_exists("m1"), "gone with the last connection");
        assert!(!std::path::Path::new("test-held").exists(), "never a file");
    }

    /// C9: the guest browser's pages never carry a deleted message.
    #[test]
    fn guest_pages_leave_deleted_messages_out() {
        let store = mem_store();
        for (mid, ts) in [("kept", 1_000), ("deleted", 2_000)] {
            store.insert_channel_message("s", "c", "al", mid, false, ts, None, None, Some(mid), None, None, None, None).unwrap();
        }
        store.set_channel_message_hidden("deleted", 3_000).unwrap();
        let page = store.get_visible_channel_messages_before("s", "c", i64::MAX, 50).unwrap();
        assert_eq!(page.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(), ["kept"]);
    }

    /// Call records come back per conversation, oldest first, and a second write
    /// for the same call never rewrites the first.
    #[test]
    fn call_records_round_trip_per_peer_and_keep_the_first_write() {
        let store = mem_store();
        store.record_dm_call(&call("c2", "mira", 2_000, "answered")).unwrap();
        store.record_dm_call(&call("c1", "mira", 1_000, "missed")).unwrap();
        store.record_dm_call(&call("c3", "juno", 3_000, "answered")).unwrap();
        store.record_dm_call(&call("c1", "mira", 1_000, "answered")).unwrap();

        let mira = store.load_dm_call_records("mira", 50).unwrap();
        assert_eq!(mira.iter().map(|r| r.call_id.as_str()).collect::<Vec<_>>(), ["c1", "c2"]);
        assert_eq!(mira[0].outcome, "missed", "a repeat teardown must not rewrite");
        assert_eq!(mira[1], call("c2", "mira", 2_000, "answered"));

        let newest = store.load_dm_call_records("mira", 1).unwrap();
        assert_eq!(newest.len(), 1);
        assert_eq!(newest[0].call_id, "c2", "the limit keeps the NEWEST calls");
    }

    /// A call record lives outside `messages`, so nothing that reads the DM rows
    /// (unread counts, sync and sibling serves, gap digests, archive export,
    /// search) can count it, send it or export it.
    #[test]
    fn call_records_never_reach_the_dm_message_readers() {
        let store = mem_store();
        let convo = "mira";
        store.insert(convo, "hello", false, 1_000, None, None, Some("m1"), None, None, None, None).unwrap();
        let digest_before = store.dm_gap_digest(convo, 0, 10_000_000).unwrap();

        let mut incoming = call("c1", convo, 5_000, "missed");
        incoming.outgoing = false;
        incoming.connected_at = None;
        store.record_dm_call(&incoming).unwrap();
        store.record_dm_call(&call("c2", convo, 6_000, "answered")).unwrap();

        assert_eq!(store.count_all_unread_dm(convo), 1, "only the real message is unread");
        assert_eq!(store.count_unread_dm(convo, "m1"), 0);
        assert_eq!(store.count_all_dm_messages(), 1);
        assert_eq!(store.get_dm_messages_for_sibling(convo, 0, 200).unwrap().len(), 1);
        assert_eq!(store.get_dm_messages_since(convo, 0, 200).unwrap().len(), 0);
        assert_eq!(store.load_all_dm_messages(convo).unwrap().len(), 1);
        assert_eq!(store.load_for_peer(convo, 200).unwrap().len(), 1);
        assert_eq!(store.get_latest_dm_timestamp_any(convo).unwrap(), Some(1_000));
        assert_eq!(store.dm_gap_digest(convo, 0, 10_000_000).unwrap(), digest_before);
        assert!(store.search_dm_messages(convo, "call", 50).unwrap().is_empty());
        assert_eq!(store.load_dm_call_records(convo, 50).unwrap().len(), 2);
    }

    /// Locks the multi-device peer-fallback responder branch: a friend serving a SINGLE
    /// device returns ONLY our own sends, while serving a MULTI-device requester returns
    /// BOTH directions, so it recovers messages sent from another offline device.
    #[test]
    fn sibling_serve_returns_both_directions_unlike_friend_serve() {
        let store = mem_store();
        let convo = "friend_master";
        // Three messages WE sent to the friend, three the friend sent to us.
        store.insert(convo, "mine 1", true, 100, None, None, Some("m1"), None, None, None, None).unwrap();
        store.insert(convo, "theirs 1", false, 110, None, None, Some("t1"), None, None, None, None).unwrap();
        store.insert(convo, "mine 2", true, 120, None, None, Some("m2"), None, None, None, None).unwrap();
        store.insert(convo, "theirs 2", false, 130, None, None, Some("t2"), None, None, None, None).unwrap();
        store.insert(convo, "mine 3", true, 140, None, None, Some("m3"), None, None, None, None).unwrap();
        store.insert(convo, "theirs 3", false, 150, None, None, Some("t3"), None, None, None, None).unwrap();

        // Friend path (one-directional): only the messages WE sent.
        let friend = store.get_dm_messages_since(convo, 0, 200).unwrap();
        assert_eq!(friend.len(), 3, "friend serve must return only is_mine=1");
        assert!(friend.iter().all(|m| m.is_mine), "friend serve leaked received msgs");

        // Sibling/peer-fallback path: BOTH directions.
        let both = store.get_dm_messages_for_sibling(convo, 0, 200).unwrap();
        assert_eq!(both.len(), 6, "peer-fallback serve must return both directions");
        assert_eq!(both.iter().filter(|m| m.is_mine).count(), 3);
        assert_eq!(both.iter().filter(|m| !m.is_mine).count(), 3);
    }

    /// A kind is stored once and reported as a change only when it differs.
    #[test]
    fn device_kind_upsert_reports_only_real_changes() {
        let store = mem_store();
        assert!(store.set_device_kind("d1", "phone").unwrap());
        assert!(!store.set_device_kind("d1", "phone").unwrap());
        assert!(store.set_device_kind("d1", "desktop").unwrap());
        assert_eq!(store.get_all_device_kinds().unwrap(), vec![("d1".to_string(), "desktop".to_string())]);
    }

    /// A reply's original reads as deleted only when we held it and it was hidden
    /// (a local delete or a bare sync hide, DM or channel), never when we never had it.
    #[test]
    fn deleted_message_ids_names_only_hidden_rows() {
        let store = mem_store();
        store.insert("friend", "dm kept", false, 100, None, None, Some("dk"), None, None, None, None).unwrap();
        store.insert("friend", "dm gone", false, 101, None, None, Some("dg"), None, None, None, None).unwrap();
        store.insert_channel_message("s", "c", "peer", "ch gone", false, 102, None, None, Some("cg"), None, None, None, None).unwrap();
        store.insert_channel_message("s", "c", "peer", "ch synced", false, 103, None, None, Some("cs"), None, None, None, None).unwrap();
        store.hide_dm_message("dg", 200, None, None).unwrap();
        store.hide_channel_message("cg", 201, None, None).unwrap();
        store.set_channel_message_hidden("cs", 202).unwrap();

        let asked: Vec<String> =
            ["dk", "dg", "cg", "cs", "never-held"].iter().map(|s| s.to_string()).collect();
        assert_eq!(store.deleted_message_ids(&asked).unwrap(), vec!["dg", "cg", "cs"]);
    }

    /// `load_deletion_proof` returns only a SIGNED evidence row, and the verified sync
    /// setter stores the proof exactly once under re-apply.
    #[test]
    fn deletion_proof_load_and_verified_setter_idempotency() {
        let store = mem_store();
        store.insert_channel_message("s", "c", "peer", "msg a", false, 100, None, None, Some("ma"), None, None, None, None).unwrap();
        store.insert_channel_message("s", "c", "peer", "msg b", false, 110, None, None, Some("mb"), None, None, None, None).unwrap();

        // A local (real) delete stores the proof; the loader returns it.
        store.hide_channel_message("ma", 200, Some("sig-a"), Some("pk-a")).unwrap();
        assert_eq!(
            store.load_deletion_proof("ma"),
            Some((200, "sig-a".to_string(), "pk-a".to_string())),
        );
        // Legacy bare hide: hidden, but no proof to serve.
        store.set_channel_message_hidden("mb", 210).unwrap();
        assert_eq!(store.get_channel_message_hidden_at("mb"), Some(210));
        assert_eq!(store.load_deletion_proof("mb"), None);

        // Verified sync setter: hides + stores the proof ONCE — a re-apply
        // (sync overlap) must not add a second, competing evidence row.
        store.insert("friend", "dm msg", false, 120, None, None, Some("md"), None, None, None, None).unwrap();
        store.set_dm_message_hidden_verified("md", 220, "sig-d", "pk-d").unwrap();
        store.set_dm_message_hidden_verified("md", 220, "sig-DIFFERENT", "pk-DIFFERENT").unwrap();
        assert_eq!(store.get_dm_message_hidden_at("md"), Some(220));
        assert_eq!(
            store.load_deletion_proof("md"),
            Some((220, "sig-d".to_string(), "pk-d".to_string())),
            "re-apply must not overwrite or duplicate the stored proof",
        );
    }

    /// A friend added by temporary nickname is stored under their DEVICE id, and once
    /// the mapping is learned the row must move to the master so presence, DM and
    /// profile line up. Covers the move, the merge with an existing master, and the
    /// device == master no-op.
    #[test]
    fn migrate_friend_device_to_master() {
        let device = "12D3KooWdeviceXYZ";
        let master = "12D3KooWmasterABC";

        // (1) Plain move: only a device row exists → it becomes the master row.
        {
            let store = mem_store();
            store.save_friend(device, "accepted", "", 100).unwrap();
            let moved = store.migrate_friend_to_master(device, master).unwrap();
            assert!(moved, "a stranded device row must migrate");
            let friends = store.load_friends(None).unwrap();
            assert_eq!(friends.len(), 1, "device row removed, master row added");
            assert_eq!(friends[0].0, master, "row is now keyed by master");
            assert_eq!(friends[0].1, "accepted");
        }

        // (2) Merge: a pending master row + an accepted device row → accepted wins.
        {
            let store = mem_store();
            store.save_friend(master, "pending", "outgoing", 50).unwrap();
            store.save_friend(device, "accepted", "", 100).unwrap();
            let moved = store.migrate_friend_to_master(device, master).unwrap();
            assert!(moved);
            let friends = store.load_friends(None).unwrap();
            assert_eq!(friends.len(), 1, "the two rows collapse into one master row");
            assert_eq!(friends[0].0, master);
            assert_eq!(friends[0].1, "accepted", "accepted must win over pending");
        }

        // (3) No-op when device == master (a single-device peer).
        {
            let store = mem_store();
            store.save_friend(master, "accepted", "", 100).unwrap();
            let moved = store.migrate_friend_to_master(master, master).unwrap();
            assert!(!moved, "device==master is a no-op");
            assert_eq!(store.load_friends(None).unwrap().len(), 1);
        }

        // (4) No-op when there is no device row to migrate.
        {
            let store = mem_store();
            store.save_friend(master, "accepted", "", 100).unwrap();
            let moved = store.migrate_friend_to_master(device, master).unwrap();
            assert!(!moved, "no device row → nothing to migrate");
        }
    }

    /// `requested_at` must ADVANCE while a row is pending and FREEZE on every other
    /// status, so the declined tombstone keeps the baseline a re-add has to beat and an
    /// accepted friendship keeps when it was asked for.
    /// HOL-SEC-039 (B10). Each edit is signed with its own time, and a replayed
    /// older one put back text its author had already replaced.
    #[test]
    fn authz_an_older_edit_never_reverts_a_newer_one() {
        let store = mem_store();
        store.insert("peer", "v1", false, 1_000, None, None, Some("m1"), None, None, None, None).unwrap();
        assert!(store.edit_dm_message("m1", "v2", 2_000, None, None).unwrap());
        assert!(store.edit_dm_message("m1", "v3", 3_000, None, None).unwrap());
        assert!(
            !store.edit_dm_message("m1", "v2", 2_000, None, None).unwrap(),
            "HOL-SEC-039: a replayed older edit was applied",
        );
        assert_eq!(store.get_dm_message_sig_row("m1").unwrap().text, "v3");
        assert!(store.edit_dm_message("m1", "v4", 4_000, None, None).unwrap());
    }

    /// Sync applies a batch inside one transaction, so an edit riding it must not
    /// open a second: SQLite refuses a nested BEGIN, and the edit was dropped.
    #[test]
    fn an_edit_inside_an_open_batch_applies() {
        let store = mem_store();
        store.insert("peer", "v1", false, 1_000, None, None, Some("m1"), None, None, None, None).unwrap();
        store.insert_channel_message("s", "c", "peer", "c1", false, 1_000, None, None, Some("m2"), None, None, None, None).unwrap();
        store.begin_transaction().unwrap();
        assert!(store.edit_dm_message("m1", "v2", 2_000, None, None).unwrap(), "a DM edit inside a batch");
        assert!(store.edit_channel_message("m2", "c2", 2_000, None, None, None).unwrap(), "a channel edit inside a batch");
        store.commit_transaction().unwrap();
        assert_eq!(store.get_dm_message_sig_row("m1").unwrap().text, "v2");
        assert_eq!(store.get_channel_message_sig_row("m2").unwrap().text, "c2");
        assert!(store.edit_dm_message("m1", "v3", 3_000, None, None).unwrap(), "and still on its own");
    }

    /// HOL-SEC-039 (B11). A reaction removal left nothing an add was checked
    /// against, so a replayed or reordered add brought the reaction back.
    #[test]
    fn authz_a_removed_reaction_stays_removed() {
        let store = mem_store();
        let has = |s: &MessageStore| {
            s.load_reactions_for_messages(&["m1".to_string()])
                .unwrap()
                .get("m1")
                .is_some_and(|r| !r.is_empty())
        };
        assert!(store.add_reaction("m1", "👍", "bob", 1_000, None, None).unwrap());
        store.remove_reaction("m1", "👍", "bob", 2_000, None, None).unwrap();
        assert!(!store.add_reaction("m1", "👍", "bob", 1_000, None, None).unwrap());
        assert!(!has(&store), "HOL-SEC-039: a replayed add resurrected a removed reaction");

        let reordered = mem_store();
        reordered.remove_reaction("m1", "👍", "bob", 2_000, None, None).unwrap();
        reordered.add_reaction("m1", "👍", "bob", 1_000, None, None).unwrap();
        assert!(!has(&reordered), "HOL-SEC-039: an add delivered after its removal landed");

        assert!(store.add_reaction("m1", "👍", "bob", 3_000, None, None).unwrap(), "a later re-add counts");
    }

    /// A29 (B11). A removal deleted the reaction whatever its time, so a replayed
    /// older one took away a later re-add.
    #[test]
    fn authz_an_old_unreaction_never_removes_a_later_re_add() {
        let store = mem_store();
        let has = |s: &MessageStore| {
            s.load_reactions_for_messages(&["m1".to_string()])
                .unwrap()
                .get("m1")
                .is_some_and(|r| !r.is_empty())
        };
        assert!(store.add_reaction("m1", "👍", "bob", 1_000, None, None).unwrap());
        assert!(store.remove_reaction("m1", "👍", "bob", 2_000, None, None).unwrap());
        assert!(store.add_reaction("m1", "👍", "bob", 3_000, None, None).unwrap());
        assert!(!store.remove_reaction("m1", "👍", "bob", 2_000, None, None).unwrap());
        assert!(has(&store), "a replayed older unreaction removed a later re-add");
        assert!(store.remove_reaction("m1", "👍", "bob", 3_000, None, None).unwrap(), "a tie goes to the removal");

        // Our own next change outranks a row a sibling stamped ahead of our clock.
        store.add_reaction("m2", "👍", "me", i64::MAX / 2, None, None).unwrap();
        assert!(store.next_reaction_stamp("m2", "👍", "me") > i64::MAX / 2);
    }

    /// A29 (B11). A card re-signs its row with the message's own time, so nothing
    /// ordered two cards for one text and a replayed older card replaced a newer one.
    #[test]
    fn authz_an_older_card_never_replaces_a_newer_one() {
        let store = mem_store();
        store.insert("peer", "see https://a", false, 1_000, None, None, Some("m1"), None, None, None, None).unwrap();
        let card = |title: &str| format!(r#"{{"url":"https://a","title":"{title}"}}"#);
        let title = || store.get_dm_message_sig_row("m1").unwrap().link_preview.map(|c| c.title);
        let set = |t: &str, at: Option<i64>| store.update_link_preview_and_sig("m1", Some(&card(t)), None, None, at).unwrap();

        assert!(set("A", Some(2_000)));
        assert!(set("B", Some(3_000)));
        assert!(!set("A", Some(2_000)), "a replayed older card was applied");
        assert_eq!(title().as_deref(), Some("B"));

        // A card sealed before the row's last edit belongs to an earlier version of it.
        assert!(store.edit_dm_message("m1", "see https://a again", 5_000, None, None).unwrap());
        assert!(!set("C", Some(4_000)), "a card from before the edit was applied");
        assert!(set("D", Some(6_000)));

        // Signed sync backfill carries no time and lands whatever the row holds.
        assert!(set("E", None));
        assert_eq!(title().as_deref(), Some("E"));
    }

    #[test]
    fn save_friend_advances_requested_at_for_pending_only() {
        let peer = "12D3KooWfriend";

        // Pending T0 → pending T2 advances.
        {
            let store = mem_store();
            store.save_friend(peer, "pending", "incoming", 100).unwrap();
            store.save_friend(peer, "pending", "incoming", 200).unwrap();
            assert_eq!(
                store.get_friend_row(peer).unwrap(),
                Some(("pending".to_string(), "incoming".to_string(), 200)),
                "a newer pending request must advance the stored timestamp",
            );
        }

        // Pending T2 → pending T0 keeps T2 (an out-of-order replay of an older
        // copy must never walk the row backwards).
        {
            let store = mem_store();
            store.save_friend(peer, "pending", "incoming", 200).unwrap();
            store.save_friend(peer, "pending", "incoming", 100).unwrap();
            assert_eq!(
                store.get_friend_row(peer).unwrap().map(|(_, _, r)| r),
                Some(200),
                "an older re-delivery must not rewind the stored timestamp",
            );
        }

        // Accepted (and declined) freeze it, whatever timestamp the write carries.
        {
            let store = mem_store();
            store.save_friend(peer, "pending", "outgoing", 100).unwrap();
            store.save_friend(peer, "accepted", "", 999).unwrap();
            assert_eq!(
                store.get_friend_row(peer).unwrap(),
                Some(("accepted".to_string(), String::new(), 100)),
                "accepting must keep the ORIGINAL request time",
            );
            store.save_friend(peer, "declined", "", 0).unwrap();
            assert_eq!(
                store.get_friend_row(peer).unwrap().map(|(_, _, r)| r),
                Some(100),
                "and the tombstone must preserve it as the re-add baseline",
            );
        }
    }

    /// A multi-device requester must use `get_latest_dm_timestamp_any`, since the friend
    /// high-water ignores our own sends and would miss the gap in them.
    #[test]
    fn latest_any_spans_both_directions() {
        let store = mem_store();
        let convo = "friend_master";
        // Our latest OUTGOING is newer than the latest INCOMING.
        store.insert(convo, "theirs", false, 100, None, None, Some("t1"), None, None, None, None).unwrap();
        store.insert(convo, "mine newer", true, 200, None, None, Some("m1"), None, None, None, None).unwrap();

        // is_mine=0-only high-water stops at the incoming message.
        assert_eq!(store.get_latest_dm_timestamp(convo).unwrap(), Some(100));
        // both-direction high-water sees our newer outgoing message.
        assert_eq!(store.get_latest_dm_timestamp_any(convo).unwrap(), Some(200));
    }

    /// #90: a row missing BEHIND the requester's `since` is re-served, only its
    /// day is, and a day both sides hold identically costs nothing.
    #[test]
    fn gap_digest_serves_only_the_differing_day() {
        let (full, partial) = (mem_store(), mem_store());
        let convo = "friend_master";
        let day = DAY_MS;
        let since = 10 * day;
        for store in [&full, &partial] {
            store.insert(convo, "day2", true, 2 * day + 5, None, None, Some("a"), None, None, None, None).unwrap();
            store.insert(convo, "day3 theirs", false, 3 * day + 5, None, None, Some("b"), None, None, None, None).unwrap();
            store.insert(convo, "newest", false, since + 5, None, None, Some("z"), None, None, None, None).unwrap();
        }
        full.insert(convo, "day3 missed", true, 3 * day + 9, None, None, Some("c"), None, None, None, None).unwrap();

        let theirs = partial.dm_gap_digest(convo, day, since).unwrap();
        assert_eq!(theirs.days.len(), 2, "one entry per non-empty day");
        let served: Vec<String> = full
            .get_dm_gap_messages(convo, &theirs, false, 200)
            .unwrap()
            .into_iter()
            .filter_map(|m| m.message_id)
            .collect();
        assert_eq!(served, ["b", "c"], "the whole differing day, and nothing past `since`");

        let mine_only: Vec<String> = full
            .get_dm_gap_messages(convo, &theirs, true, 200)
            .unwrap()
            .into_iter()
            .filter_map(|m| m.message_id)
            .collect();
        assert_eq!(mine_only, ["c"], "a one-directional friend serves only its own sends");

        let ours = full.dm_gap_digest(convo, day, since).unwrap();
        assert!(
            full.get_dm_gap_messages(convo, &ours, false, 200).unwrap().is_empty(),
            "matching digests serve nothing"
        );
    }

    /// A digest reaching further back than the window is ignored, so a peer cannot
    /// make us scan and ship a whole history per request.
    #[test]
    fn gap_digest_wider_than_the_window_is_ignored() {
        let store = mem_store();
        let convo = "friend_master";
        store.insert(convo, "old", true, DAY_MS, None, None, Some("a"), None, None, None, None).unwrap();
        let empty = |from, until| crate::node::types::GapDigest { from, until, days: Vec::new() };
        let too_wide = empty(0, SYNC_GAP_MAX_SPAN_MS + 2 * DAY_MS);
        assert!(store.get_dm_gap_messages(convo, &too_wide, false, 200).unwrap().is_empty());
        assert!(store.get_dm_gap_messages(convo, &empty(5, 5), false, 200).unwrap().is_empty());
        assert_eq!(
            store.get_dm_gap_messages(convo, &empty(0, 2 * DAY_MS), false, 200).unwrap().len(),
            1,
            "an in-bounds empty digest gets the whole window"
        );
    }

    /// The channel half: a row missed behind our newest message comes back, and
    /// the anchor leaves the lookback overlap to the per-sender watermarks.
    #[test]
    fn channel_gap_anchor_and_serve() {
        let (full, partial) = (mem_store(), mem_store());
        let newest = 10 * DAY_MS;
        for store in [&full, &partial] {
            store.insert_channel_message("s", "c", "alice", "early", false, 2 * DAY_MS, None, None, Some("e"), None, None, None, None).unwrap();
            store.insert_channel_message("s", "c", "bob", "newest", false, newest, None, None, Some("n"), None, None, None, None).unwrap();
        }
        full.insert_channel_message("s", "c", "alice", "missed", false, 3 * DAY_MS, None, None, Some("m"), None, None, None, None).unwrap();

        let theirs = partial.channel_gap_anchor("s", "c").expect("history behind the newest row");
        assert_eq!(theirs.until, newest - SYNC_LOOKBACK_MS);
        let served: Vec<String> = full
            .get_channel_gap_messages("s", "c", &theirs, 200)
            .unwrap()
            .into_iter()
            .filter_map(|m| m.message_id)
            .collect();
        assert_eq!(served, ["m"]);
        assert!(mem_store().channel_gap_anchor("s", "c").is_none(), "an empty channel has no gap");
    }

    /// A same-MILLISECOND burst from two senders must display grouped by sender in true
    /// send order (order_us), not alternated by the sender_id tiebreaker.
    #[test]
    fn channel_same_ms_burst_orders_by_order_us_not_sender() {
        let store = mem_store();
        let (sid, cid) = ("s1", "c1");
        let ms = 1_000i64;
        // Pixel's master id sorts AFTER AL's so the OLD sender_id-DESC tiebreaker
        // would have put Pixel first and then interleaved — proving the fix.
        let pixel = "zzz_pixel_master";
        let al = "aaa_al_master";
        // True send order: P1,P2,P3 then A1,A2,A3 — strictly increasing order_us.
        let send = |sender: &str, text: &str, mid: &str, ous: i64| {
            store.insert_channel_message(sid, cid, sender, text, false, ms,
                None, None, Some(mid), None, None, Some(ous), None).unwrap();
        };
        send(pixel, "P1", "p1", ms * 1000 + 10);
        send(pixel, "P2", "p2", ms * 1000 + 20);
        send(pixel, "P3", "p3", ms * 1000 + 30);
        send(al, "A1", "a1", ms * 1000 + 40);
        send(al, "A2", "a2", ms * 1000 + 50);
        send(al, "A3", "a3", ms * 1000 + 60);

        let order: Vec<String> = store
            .load_channel_messages(sid, cid, 100)
            .unwrap()
            .into_iter()
            .map(|m| m.text)
            .collect();
        assert_eq!(
            order,
            vec!["P1", "P2", "P3", "A1", "A2", "A3"],
            "same-ms burst must group by sender in true send order (order_us), not ping-pong"
        );
    }

    /// g13-h: two senders (or two devices of one identity) that saw the same message
    /// stamped ahead both mint the next microsecond. Rows tied on every sender stamp list
    /// by message id, never by the local insert order, so replicas show one order.
    #[test]
    fn chat_rows_tied_on_order_us_list_by_message_id() {
        let (ms, ous) = (1_000i64, 1_000_007i64);
        let dm = |first: &str, second: &str| {
            let store = mem_store();
            for mid in [first, second] {
                store.insert("peer", mid, false, ms, None, None, Some(mid), None, None, Some(ous), None).unwrap();
            }
            store.load_for_peer("peer", 10).unwrap().into_iter().map(|m| m.text).collect::<Vec<_>>()
        };
        assert_eq!(dm("aa", "bb"), dm("bb", "aa"), "DM rows listed in arrival order");
        let channel = |first: &str, second: &str| {
            let store = mem_store();
            for mid in [first, second] {
                store.insert_channel_message("s", "c", "master", mid, false, ms, None, None, Some(mid), None, None, Some(ous), None).unwrap();
            }
            store.load_channel_messages("s", "c", 10).unwrap().into_iter().map(|m| m.text).collect::<Vec<_>>()
        };
        assert_eq!(channel("aa", "bb"), channel("bb", "aa"), "channel rows listed in arrival order");
    }

    /// Legacy rows with NULL order_us still sort deterministically, falling back to
    /// timestamp then sender_id and id.
    #[test]
    fn channel_null_order_us_falls_back_deterministically() {
        let store = mem_store();
        let (sid, cid) = ("s1", "c1");
        // Distinct timestamps, NULL order_us (legacy rows) → ordered by timestamp.
        store.insert_channel_message(sid, cid, "x", "first", false, 100,
            None, None, Some("m1"), None, None, None, None).unwrap();
        store.insert_channel_message(sid, cid, "y", "second", false, 200,
            None, None, Some("m2"), None, None, None, None).unwrap();
        let order: Vec<String> = store
            .load_channel_messages(sid, cid, 100)
            .unwrap()
            .into_iter()
            .map(|m| m.text)
            .collect();
        assert_eq!(order, vec!["first", "second"], "legacy NULL rows order by timestamp");
    }

    /// The unread count is millisecond-granular: a sync-backfilled older row with a
    /// higher rowid must NOT count, and neither must a same-millisecond sibling of the
    /// seen row, because Dart marks seen from a millisecond-sorted `.last`.
    #[test]
    fn unread_counts_are_millisecond_granular() {
        let store = mem_store();

        // DM: seen row at ts=1000.
        let peer = "friend_master";
        store.insert(peer, "seen", false, 1000, None, None, Some("seen"), None, None, None, None).unwrap();
        // Same-ms burst sibling (higher rowid, same millisecond) — NOT unread.
        store.insert(peer, "same-ms", false, 1000, None, None, Some("m2"), None, None, None, None).unwrap();
        // Sync backfill: OLDER timestamp, higher rowid — NOT unread.
        store.insert(peer, "backfill", false, 500, None, None, Some("m3"), None, None, None, None).unwrap();
        // Genuinely newer — unread.
        store.insert(peer, "newer", false, 2000, None, None, Some("m4"), None, None, None, None).unwrap();
        assert_eq!(store.count_unread_dm(peer, "seen"), 1, "only the strictly-newer message is unread");
        // Missing seen row → 0, never count-everything.
        assert_eq!(store.count_unread_dm(peer, "no-such-mid"), 0);

        // Channel: same shape.
        let (sid, cid) = ("s-unread", "c-unread");
        store.insert_channel_message(sid, cid, "al", "seen", false, 1000,
            None, None, Some("ch-seen"), None, None, None, None).unwrap();
        store.insert_channel_message(sid, cid, "al", "same-ms", false, 1000,
            None, None, Some("ch2"), None, None, None, None).unwrap();
        store.insert_channel_message(sid, cid, "al", "backfill", false, 500,
            None, None, Some("ch3"), None, None, None, None).unwrap();
        store.insert_channel_message(sid, cid, "al", "newer", false, 2000,
            None, None, Some("ch4"), None, None, None, None).unwrap();
        assert_eq!(store.count_unread_channel(sid, cid, "ch-seen"), 1);
        assert_eq!(store.count_unread_channel(sid, cid, "gone"), 0);
        let (total, _) = store.count_unread_channel_with_mentions(sid, cid, Some("ch-seen"), &[]);
        assert_eq!(total, 1);
    }

    /// Being last to speak reads the conversation on every device: own rows floor
    /// the count even when the seen pointer never crossed them (#80).
    #[test]
    fn own_message_floors_unread_counts() {
        let store = mem_store();
        let peer = "friend_master";
        store.insert(peer, "theirs-old", false, 1000, None, None, Some("t1"), None, None, None, None).unwrap();
        store.insert(peer, "theirs-2", false, 1500, None, None, Some("t2"), None, None, None, None).unwrap();
        store.insert(peer, "mine", true, 2000, None, None, Some("m1"), None, None, None, None).unwrap();
        store.insert(peer, "theirs-new", false, 3000, None, None, Some("t3"), None, None, None, None).unwrap();
        // Pointer at the oldest row, yet only the message after our reply counts.
        assert_eq!(store.count_unread_dm(peer, "t1"), 1);
        // Never opened on this device: same floor.
        assert_eq!(store.count_all_unread_dm(peer), 1);

        let (sid, cid) = ("s-floor", "c-floor");
        store.insert_channel_message(sid, cid, "al", "theirs", false, 1000,
            None, None, Some("c1"), None, None, None, None).unwrap();
        store.insert_channel_message(sid, cid, "me", "mine", true, 2000,
            None, None, Some("c2"), None, None, None, None).unwrap();
        store.insert_channel_message(sid, cid, "al", "@everyone later", false, 3000,
            None, None, Some("c3"), None, None, None, None).unwrap();
        assert_eq!(store.count_unread_channel(sid, cid, "c1"), 1);
        assert_eq!(store.count_all_unread_channel(sid, cid), 1);
        let (total, mentions) = store.count_unread_channel_with_mentions(
            sid, cid, Some("c1"), &["@everyone".to_string()]);
        assert_eq!((total, mentions), (1, 1));
        let (total, _) = store.count_unread_channel_with_mentions(sid, cid, None, &[]);
        assert_eq!(total, 1);
    }

    /// A sibling's pointer is adopted by TIME against the rows this device holds,
    /// advances only forward, and the snapshot round-trips it (#80).
    #[test]
    fn remote_read_marker_advances_by_time_and_never_regresses() {
        let store = mem_store();
        let peer = "friend_master";
        store.insert(peer, "a", false, 1000, None, None, Some("d1"), None, None, None, None).unwrap();
        store.insert(peer, "b", false, 2000, None, None, Some("d2"), None, None, None, None).unwrap();
        store.insert(peer, "c", false, 3000, None, None, Some("d3"), None, None, None, None).unwrap();
        let key = format!("dm:{peer}");

        // The sibling read a row we do not hold (ts 2500): the newest row at or
        // before it becomes our pointer.
        assert_eq!(store.apply_remote_read_marker(&key, 2500).unwrap(), Some("d2".into()));
        assert_eq!(store.load_setting("seen:dm:friend_master").unwrap().as_deref(), Some("d2"));
        assert_eq!(store.count_unread_dm(peer, "d2"), 1);
        // Older than what we hold: ignored.
        assert_eq!(store.apply_remote_read_marker(&key, 1000).unwrap(), None);
        // Same millisecond: nothing to move.
        assert_eq!(store.apply_remote_read_marker(&key, 2000).unwrap(), None);
        // Forward again: the pointer lands on the newest row, the mark keeps 9000
        // so a row backfilled later at 4000 stays read.
        assert_eq!(store.apply_remote_read_marker(&key, 9000).unwrap(), Some("d3".into()));
        store.insert(peer, "late", false, 4000, None, None, Some("d4"), None, None, None, None).unwrap();
        assert_eq!(store.count_unread_dm(peer, "d3"), 0);
        assert_eq!(store.read_marker_floor(&key), Some(9000));
        store.insert(peer, "after", false, 9500, None, None, Some("d5"), None, None, None, None).unwrap();
        assert_eq!(store.count_unread_dm(peer, "d3"), 1);
        // Earlier than every local row and no pointer yet: the mark alone is
        // kept, and the count without a pointer floors on it.
        assert_eq!(store.apply_remote_read_marker("dm:nobody", 5).unwrap(), Some(String::new()));
        store.insert("nobody", "x", false, 3, None, None, Some("n1"), None, None, None, None).unwrap();
        store.insert("nobody", "y", false, 8, None, None, Some("n2"), None, None, None, None).unwrap();
        assert_eq!(store.count_all_unread_dm("nobody"), 1);

        let (sid, cid) = ("s-rm", "c-rm");
        store.insert_channel_message(sid, cid, "al", "x", false, 100,
            None, None, Some("k1"), None, None, None, None).unwrap();
        store.insert_channel_message(sid, cid, "al", "y", false, 200,
            None, None, Some("k2"), None, None, None, None).unwrap();
        let ch_key = format!("ch:{sid}:{cid}");
        assert_eq!(store.apply_remote_read_marker(&ch_key, 150).unwrap(), Some("k1".into()));
        assert!(store.apply_remote_read_marker("bogus:key", 1).is_err());

        let mut snap = store.read_markers_snapshot();
        snap.sort();
        assert_eq!(snap, vec![
            (ch_key.clone(), "k1".to_string(), 150),
            (key.clone(), "d3".to_string(), 9000),
            ("dm:nobody".to_string(), String::new(), 5),
        ]);
        assert_eq!(store.read_marker_timestamp(&key, "d1"), Some(1000));
        assert_eq!(store.read_marker_timestamp(&ch_key, "k2"), Some(200));
        assert_eq!(store.read_marker_timestamp(&key, "missing"), None);
    }

    // ── Storage Manager ────────────────────────────────────────────────────

    /// Insert a completed-on-disk file row for storage tests.
    fn insert_completed_file(
        store: &MessageStore,
        file_id: &str,
        ctype: &str,
        cid: &str,
        size: u64,
        disk_path: &str,
    ) {
        store
            .insert_file_metadata(
                file_id, file_id, "bin", "application/octet-stream", size,
                1, false, None, None, None, ctype, cid, "sender", false, 1000, None, None, None,
            )
            .unwrap();
        store.mark_file_complete(file_id, disk_path).unwrap();
    }

    /// `storage_breakdown` groups completed-on-disk files by context and sums them;
    /// incomplete files are excluded.
    #[test]
    fn storage_breakdown_sums_per_context() {
        let store = mem_store();
        insert_completed_file(&store, "f1", "dm", "alice", 100, "/tmp/f1");
        insert_completed_file(&store, "f2", "dm", "alice", 200, "/tmp/f2");
        insert_completed_file(&store, "f3", "channel", "s1:c1", 50, "/tmp/f3");
        // An incomplete file (no mark_file_complete) must NOT count.
        store
            .insert_file_metadata(
                "f4", "f4", "bin", "application/octet-stream", 999,
                1, false, None, None, None, "dm", "alice", "sender", false, 1000, None, None, None,
            )
            .unwrap();

        let rows = store.storage_breakdown().unwrap();
        let dm = rows.iter().find(|(t, c, _, _)| t == "dm" && c == "alice").unwrap();
        assert_eq!(dm.2, 300, "DM bytes = 100+200, excludes incomplete 999");
        assert_eq!(dm.3, 2, "DM file count = 2 completed");
        let ch = rows.iter().find(|(t, c, _, _)| t == "channel" && c == "s1:c1").unwrap();
        assert_eq!(ch.2, 50);
        assert_eq!(ch.3, 1);
    }

    /// `null_disk_path_for_context` clears one context only, leaving others untouched;
    /// `disk_paths_for_context` returns the paths to delete first.
    #[test]
    fn clear_context_nulls_only_that_context() {
        let store = mem_store();
        insert_completed_file(&store, "f1", "dm", "alice", 100, "/tmp/f1");
        insert_completed_file(&store, "f2", "dm", "bob", 200, "/tmp/f2");

        let paths = store.disk_paths_for_context("dm", "alice").unwrap();
        assert_eq!(paths, vec!["/tmp/f1".to_string()]);

        let n = store.null_disk_path_for_context("dm", "alice").unwrap();
        assert_eq!(n, 1);

        // alice now has no completed-on-disk file; bob still does.
        let rows = store.storage_breakdown().unwrap();
        assert!(
            !rows.iter().any(|(t, c, _, _)| t == "dm" && c == "alice"),
            "alice's files were nulled → not in breakdown"
        );
        assert!(
            rows.iter().any(|(t, c, _, _)| t == "dm" && c == "bob"),
            "bob's files untouched"
        );

        // The metadata row survives (re-downloadable card).
        let meta = store.get_file_metadata("f1").unwrap().unwrap();
        assert!(meta.disk_path.is_none() && meta.completed_at.is_none());
    }

    /// `null_disk_path_all` clears every completed file (Clear all cached bytes).
    #[test]
    fn clear_all_nulls_every_context() {
        let store = mem_store();
        insert_completed_file(&store, "f1", "dm", "alice", 100, "/tmp/f1");
        insert_completed_file(&store, "f2", "channel", "s1:c1", 50, "/tmp/f2");

        let n = store.null_disk_path_all().unwrap();
        assert_eq!(n, 2);
        assert!(store.storage_breakdown().unwrap().is_empty());
    }

    /// Keeping the same redeem code twice writes one row, forgetting removes it, and the
    /// count is what the API layer caps against.
    #[test]
    fn redeem_codes_keep_is_idempotent_and_capped() {
        let store = mem_store();
        assert_eq!(store.count_redeem_codes().unwrap(), 0);

        assert!(store.save_redeem_code("ABCDE-FGHIJ-12345").unwrap(), "first keep writes a row");
        assert!(
            !store.save_redeem_code("ABCDE-FGHIJ-12345").unwrap(),
            "keeping the same code again must not write a second row",
        );
        assert_eq!(store.count_redeem_codes().unwrap(), 1);

        // Fill to the cap the API enforces and check the count it reads.
        for i in 0..63 {
            assert!(store.save_redeem_code(&format!("CODE-{i:04}-XXXX")).unwrap());
        }
        assert_eq!(store.count_redeem_codes().unwrap(), 64);

        let listed = store.list_redeem_codes().unwrap();
        assert_eq!(listed.len(), 64);
        assert!(listed.iter().all(|(_, at)| *at > 0), "every row is stamped");

        store.delete_redeem_code("ABCDE-FGHIJ-12345").unwrap();
        assert_eq!(store.count_redeem_codes().unwrap(), 63);
        // Forgetting a code that was never kept is not an error.
        store.delete_redeem_code("NEVER-KEPT-0001").unwrap();
        assert_eq!(store.count_redeem_codes().unwrap(), 63);
    }

    // ── Media viewer list ──────────────────────────────────────────────────

    /// Seed one file row of the media-list fixtures. `complete` false leaves it
    /// mid-download.
    #[allow(clippy::too_many_arguments)]
    fn insert_media_row(
        store: &MessageStore,
        file_id: &str,
        ctype: &str,
        cid: &str,
        ext: &str,
        is_image: bool,
        created_at: i64,
        message_id: Option<&str>,
        complete: bool,
    ) {
        store
            .insert_file_metadata(
                file_id, &format!("{file_id}.{ext}"), ext, "application/octet-stream",
                10, 1, is_image, None, None, message_id, ctype, cid, "sender", false,
                created_at, None, None, None,
            )
            .unwrap();
        if complete {
            store
                .mark_file_complete(file_id, &format!("/tmp/{file_id}.{ext}"))
                .unwrap();
        }
    }

    fn media_ids(items: &[StoredMediaItem]) -> Vec<&str> {
        items.iter().map(|m| m.file.file_id.as_str()).collect()
    }

    /// Only completed, visible images and videos come back. The video carries an
    /// UPPERCASE extension, so the match is case-insensitive like the Dart mirror.
    #[test]
    fn media_list_filters_to_completed_visible_images_and_videos() {
        let store = mem_store();
        insert_media_row(&store, "img", "dm", "alice", "png", true, 1000, None, true);
        insert_media_row(&store, "vid", "dm", "alice", "MP4", false, 2000, None, true);
        insert_media_row(&store, "aud", "dm", "alice", "ogg", false, 3000, None, true);
        insert_media_row(&store, "doc", "dm", "alice", "pdf", false, 3100, None, true);
        insert_media_row(&store, "inc", "dm", "alice", "png", true, 3200, None, false);
        insert_media_row(&store, "hid", "dm", "alice", "png", true, 3300, None, true);
        insert_media_row(&store, "exp", "dm", "alice", "png", true, 3400, None, true);
        store
            .conn
            .execute("UPDATE files SET hidden_at = 1 WHERE file_id = 'hid'", [])
            .unwrap();
        store
            .conn
            .execute("UPDATE files SET expired_at = 1 WHERE file_id = 'exp'", [])
            .unwrap();

        let got = store.list_media_for_context("dm", "alice", None, None, 50).unwrap();
        assert_eq!(
            media_ids(&got),
            vec!["vid", "img"],
            "newest first, images and videos only",
        );
    }

    /// `ts` is the OWNING MESSAGE's time, not the file row's `created_at`, and the
    /// exclusive bounds page in both directions.
    #[test]
    fn media_list_uses_message_timestamp_and_pages_both_ways() {
        let store = mem_store();
        for (fid, mid, ts) in [("f1", "m1", 1000), ("f2", "m2", 2000), ("f3", "m3", 3000)] {
            store
                .insert("alice", "[file:x]", false, ts, None, None, Some(mid), None, Some(fid), None, None)
                .unwrap();
            // created_at is deliberately identical and far in the future.
            insert_media_row(&store, fid, "dm", "alice", "png", true, 9999, Some(mid), true);
        }
        let stamps = |items: &[StoredMediaItem]| items.iter().map(|m| m.ts).collect::<Vec<_>>();

        let all = store.list_media_for_context("dm", "alice", None, None, 50).unwrap();
        assert_eq!(stamps(&all), vec![3000, 2000, 1000], "message time wins over created_at");

        let older = store.list_media_for_context("dm", "alice", Some(3000), None, 50).unwrap();
        assert_eq!(stamps(&older), vec![2000, 1000], "before_ts is exclusive");

        let newer = store.list_media_for_context("dm", "alice", None, Some(1000), 50).unwrap();
        assert_eq!(stamps(&newer), vec![3000, 2000], "after_ts is exclusive");

        let one = store.list_media_for_context("dm", "alice", None, None, 1).unwrap();
        assert_eq!(stamps(&one), vec![3000], "limit takes the newest");
    }

    /// A file whose message row was hidden (deleted or moderated) is not listed, in
    /// a DM or a channel.
    #[test]
    fn media_list_excludes_files_of_hidden_messages() {
        let store = mem_store();
        store
            .insert("alice", "[file:x]", false, 1000, None, None, Some("m_gone"), None, Some("f_gone"), None, None)
            .unwrap();
        store
            .insert("alice", "[file:x]", false, 1100, None, None, Some("m_ok"), None, Some("f_ok"), None, None)
            .unwrap();
        insert_media_row(&store, "f_gone", "dm", "alice", "png", true, 1000, Some("m_gone"), true);
        insert_media_row(&store, "f_ok", "dm", "alice", "png", true, 1100, Some("m_ok"), true);
        store.set_dm_message_hidden("m_gone", 5000).unwrap();

        store
            .insert_channel_message("s1", "c1", "sender", "[file:x]", false, 1200, None, None, Some("cm_gone"), None, Some("f_ch"), None, None)
            .unwrap();
        insert_media_row(&store, "f_ch", "channel", "s1:c1", "png", true, 1200, Some("cm_gone"), true);
        store.set_channel_message_hidden("cm_gone", 5000).unwrap();

        let dm = store.list_media_for_context("dm", "alice", None, None, 50).unwrap();
        assert_eq!(media_ids(&dm), vec!["f_ok"], "hidden DM message drops its file");

        let channel = store.list_media_for_context("channel", "s1:c1", None, None, 50).unwrap();
        assert!(channel.is_empty(), "hidden channel message drops its file");
    }

    /// Media never leaks across conversations.
    #[test]
    fn media_list_is_scoped_to_its_context() {
        let store = mem_store();
        insert_media_row(&store, "a1", "dm", "alice", "png", true, 1000, None, true);
        insert_media_row(&store, "b1", "dm", "bob", "png", true, 2000, None, true);
        insert_media_row(&store, "c1", "channel", "s1:c1", "png", true, 3000, None, true);

        let alice = store.list_media_for_context("dm", "alice", None, None, 50).unwrap();
        assert_eq!(media_ids(&alice), vec!["a1"]);
        let channel = store.list_media_for_context("channel", "s1:c1", None, None, 50).unwrap();
        assert_eq!(media_ids(&channel), vec!["c1"]);
    }

    fn stored_session(store: &MessageStore, peer: &str) -> Option<(String, i64, i64)> {
        store.load_olm_session(peer).unwrap().map(|(pickle, sends, reads)| (pickle.to_string(), sends, reads))
    }

    /// AR-30: two processes write session pickles, so a copy that has not come as far
    /// as the stored row never replaces it, and `sends` outranks `reads`: a copy from a
    /// process that only decrypted can never put back a chain step that was sent.
    #[test]
    fn an_older_olm_session_copy_never_replaces_a_newer_one() {
        let store = mem_store();
        assert!(store.save_olm_session("bob", "sent-1", 1, 0).unwrap());
        assert!(!store.save_olm_session("bob", "read-from-older", 0, 7).unwrap(), "fewer sends, more reads");
        assert!(!store.save_olm_session("bob", "same-version", 1, 0).unwrap(), "an equal version keeps the row it finds");
        assert_eq!(stored_session(&store, "bob"), Some(("sent-1".into(), 1, 0)));
        assert!(store.save_olm_session("bob", "sent-1", 1, 0).unwrap(), "the same save again is stored");
        assert!(store.save_olm_session("bob", "read-after-send", 1, 3).unwrap());
        assert!(store.save_olm_session("bob", "sent-2", 2, 0).unwrap(), "a send outranks any number of reads");
        assert!(!store.save_olm_session("bob", "read-after-send", 1, 3).unwrap(), "a late copy of an older state");
        assert_eq!(stored_session(&store, "bob"), Some(("sent-2".into(), 2, 0)));
        assert!(store.save_olm_session("carol", "first", 0, 1).unwrap(), "another peer's row is its own");
    }

    /// A removal leaves a floor past every stored copy, so the push fetch writing back
    /// the session it loaded before the removal cannot bring it back.
    #[test]
    fn a_removed_olm_session_stays_removed_past_older_copies() {
        let store = mem_store();
        assert!(store.save_olm_session("dev", "live", 3, 2).unwrap());
        store.delete_olm_session("dev").unwrap();
        assert_eq!(stored_session(&store, "dev"), None);
        assert!(!store.save_olm_session("dev", "loaded-before-removal", 3, 9).unwrap());
        assert_eq!(stored_session(&store, "dev"), None, "an older copy came back");
        assert_eq!(store.load_olm_session_floors().unwrap(), vec![("dev".to_string(), 4, 0)]);
        assert!(store.save_olm_session("dev", "new-session", 4, 1).unwrap(), "a session built after the removal stores");
        store.delete_olm_session("dev").unwrap();
        assert_eq!(store.load_olm_session_floors().unwrap(), vec![("dev".to_string(), 5, 0)], "a floor only rises");
        store.delete_olm_session("never-stored").unwrap();
        assert!(store.save_olm_session("never-stored", "after", 1, 1).unwrap());
    }

    /// A 0.12.0 database holds sessions with no version: they read as version zero and
    /// the first save of the new build replaces them.
    #[test]
    fn a_0_12_0_olm_sessions_table_gains_versions() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("old.db").to_string_lossy().into_owned();
        let pass = "cd".repeat(32);
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(&format!("PRAGMA key = \"x'{pass}'\";")).unwrap();
            conn.execute_batch(
                "CREATE TABLE olm_sessions (peer_id TEXT PRIMARY KEY, pickle TEXT NOT NULL);
                 INSERT INTO olm_sessions (peer_id, pickle) VALUES ('bob', 'from-0.12.0');",
            )
            .unwrap();
        }
        let store = MessageStore::open(&path, &pass).unwrap();
        assert_eq!(store.load_olm_sessions_versioned().unwrap(), vec![("bob".into(), zeroize::Zeroizing::new("from-0.12.0".to_string()), 0, 0)]);
        assert!(!store.save_olm_session("bob", "same", 0, 0).unwrap());
        assert!(store.save_olm_session("bob", "next", 0, 1).unwrap());
        assert!(store.load_olm_session_floors().unwrap().is_empty());
        drop(store);
        let again = MessageStore::open(&path, &pass).unwrap();
        assert_eq!(stored_session(&again, "bob"), Some(("next".into(), 0, 1)), "a reopen keeps the migrated row");
    }
}

#[cfg(test)]
mod fs_review_tests {
    use super::MessageStore;
    use crate::node::crypto_handler::SignedExtras;

    const TS: i64 = 1_791_548_513_366;

    fn extras(mid: &str) -> SignedExtras<'_> {
        SignedExtras { mid: Some(mid), reply_to: None, file_id: None, order_us: None, lp_digest: None, album: None }
    }

    fn store() -> MessageStore {
        MessageStore::open(":memory:", &"ab".repeat(32)).expect("store")
    }

    /// fs-review: two distinct DMs from one sender in the same millisecond. A sync that
    /// brings the second must insert it, never graft it onto the first's row.
    #[test]
    fn a_same_millisecond_dm_is_never_reconciled_onto_another_message() {
        let store = store();
        store
            .insert("friend", "dm burst-1", false, TS, Some("sig1"), Some("pk"), Some("burst-1"), None, Some("file-1"), None, None)
            .expect("first DM");
        let merged = store
            .reconcile_dm_by_timestamp("friend", false, "dm burst-2", TS, None, Some("sig2"), Some("pk"), &extras("burst-2"))
            .expect("reconcile");
        assert!(store.dm_message_exists("burst-1"), "the first DM was overwritten by a different message");
        assert!(!merged, "a distinct same-millisecond DM was reconciled into another message's row");
    }

    /// fs-olm: the case reconcile exists for. A row stored without a mid takes the synced
    /// copy of the same message, and becomes exactly the signed item.
    #[test]
    fn a_row_without_a_mid_takes_its_synced_copy_whole() {
        let store = store();
        store
            .insert("friend", "hello", false, TS, Some("old-sig"), Some("pk"), None, Some("stale-reply"), Some("stale-file"), None, None)
            .expect("legacy DM");
        let item = SignedExtras {
            mid: Some("m-1"),
            reply_to: None,
            file_id: Some("file-1"),
            order_us: Some(TS * 1000 + 7),
            lp_digest: None,
            album: None,
        };
        let merged = store
            .reconcile_dm_by_timestamp("friend", false, "hello", TS, None, Some("sig"), Some("pk"), &item)
            .expect("reconcile");
        assert!(merged, "the mid-less row must take its synced copy instead of a duplicate");
        let rows = store.load_all_dm_messages("friend").expect("rows");
        assert_eq!(rows.len(), 1, "one row for one message");
        let row = &rows[0];
        assert_eq!(row.message_id.as_deref(), Some("m-1"));
        assert_eq!(row.signature.as_deref(), Some("sig"));
        assert_eq!(row.reply_to_mid, None, "the row keeps nothing its new signature does not bind");
        assert_eq!(row.file_id.as_deref(), Some("file-1"));
        assert_eq!(row.order_us, Some(TS * 1000 + 7));
        assert_eq!(row.edited_at, None, "an unedited item leaves the row unedited");
    }

    /// fs-olm: direction is part of the row's author. Our own synced message never lands
    /// on a mid-less row the friend sent, nor theirs on ours.
    #[test]
    fn a_synced_dm_never_reconciles_onto_a_row_of_the_other_direction() {
        let store = store();
        store
            .insert("friend", "theirs", false, TS, Some("sig-a"), Some("pk-a"), None, None, None, None, None)
            .expect("their DM");
        store
            .insert("friend", "ours", true, TS + 1, Some("sig-b"), Some("pk-b"), None, None, None, None, None)
            .expect("our DM");
        let ours_onto_theirs = store
            .reconcile_dm_by_timestamp("friend", true, "mine", TS, None, Some("sig"), Some("pk"), &extras("m-ours"))
            .expect("reconcile");
        let theirs_onto_ours = store
            .reconcile_dm_by_timestamp("friend", false, "yours", TS + 1, None, Some("sig"), Some("pk"), &extras("m-theirs"))
            .expect("reconcile");
        assert!(!ours_onto_theirs && !theirs_onto_ours, "a reconcile crossed directions");
        let texts: Vec<String> = store.load_all_dm_messages("friend").expect("rows").into_iter().map(|m| m.text).collect();
        assert_eq!(texts, ["theirs", "ours"]);
    }
}

// md-review
#[cfg(test)]
mod md_review {
    use super::*;

    fn store_in(root: &std::path::Path) -> MessageStore {
        MessageStore::open(root.join("messages.db").to_str().unwrap(), &"ab".repeat(32)).unwrap()
    }

    fn complete_file(store: &MessageStore, id: &str, path: &std::path::Path) {
        store
            .insert_file_metadata(
                id, id, "png", "image/png", 11, 1, true, None, None, None, "dm", "friend", "friend", false, 1000,
                None, None, None,
            )
            .unwrap();
        store.mark_file_complete(id, path.to_str().unwrap()).unwrap();
    }

    /// One row a crafted snapshot stores as a BLOB must not leave every other row's
    /// foreign path in place: the gate fails open on the first unreadable value.
    #[test]
    fn md_review_one_unreadable_row_does_not_keep_every_foreign_path() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("ours");
        std::fs::create_dir_all(root.join("files")).unwrap();
        let elsewhere = tmp.path().join("someone_elses.docx");
        std::fs::write(&elsewhere, b"not ours").unwrap();
        let store = store_in(&root);
        complete_file(&store, "aa11", &elsewhere);
        complete_file(&store, "bb22", &root.join("files").join("bb22.png"));
        store.conn.execute("UPDATE files SET disk_path = X'00' WHERE file_id = 'bb22'", []).unwrap();

        let outcome = store.forget_foreign_paths(&root);
        let f = store.get_file_metadata("aa11").unwrap().unwrap();
        assert_eq!(
            (f.disk_path.as_deref(), f.completed_at.is_some()),
            (None, false),
            "a path outside the data root survived the import ({outcome:?})"
        );
    }

    /// "Ours" means a content folder, not anything under the data root: the identity
    /// key, the database or a profile kept inside the root must never become a file
    /// row's bytes (served by FileRequest, deleted by "Clear" and by retention).
    #[test]
    fn md_review_a_path_in_the_root_but_outside_its_content_folders_is_forgotten() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("ours");
        std::fs::create_dir_all(root.join("files")).unwrap();
        std::fs::write(root.join("identity.key"), b"key").unwrap();
        let nested = root.join("work").join("files");
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::write(nested.join("cc33.png"), b"another profile's file").unwrap();
        let store = store_in(&root);
        complete_file(&store, "aa11", &root.join("identity.key"));
        complete_file(&store, "bb22", &root.join("messages.db"));
        complete_file(&store, "cc33", &nested.join("cc33.png"));

        store.forget_foreign_paths(&root).unwrap();
        for id in ["aa11", "bb22", "cc33"] {
            let f = store.get_file_metadata(id).unwrap().unwrap();
            assert_eq!(f.disk_path, None, "{id} still names a non-content file under the root");
        }
    }
}

// md-link
#[cfg(test)]
mod md_link_paths {
    use super::*;

    /// A repoint names the landed copy only by the row's exact `<file_id>.<ext>`: an
    /// id with a dot and an empty extension would name `filesa11.png.`, which
    /// Windows opens as another file's `aa11.png`.
    #[test]
    fn a_repoint_takes_only_the_exact_name_of_its_own_file() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("ours");
        std::fs::create_dir_all(root.join("files")).unwrap();
        std::fs::write(root.join("files").join("aa11.png"), b"HFE1 aa11").unwrap();
        let store = MessageStore::open(root.join("messages.db").to_str().unwrap(), &"cd".repeat(32)).unwrap();
        let elsewhere = tmp.path().join("presenter").join("x.png");
        std::fs::create_dir_all(root.join("files").join("x")).unwrap();
        for (id, ext) in [("aa11", "png"), ("aa11.png", ""), ("bb22", ""), ("x/../aa11", "png")] {
            store
                .insert_file_metadata(
                    id, id, ext, "image/png", 9, 1, true, None, None, None, "dm", "friend", "friend", false, 1000,
                    None, None, None,
                )
                .unwrap();
            store.mark_file_complete(id, elsewhere.to_str().unwrap()).unwrap();
        }
        std::fs::write(root.join("files").join("bb22."), b"").ok();

        store.forget_foreign_paths(&root).unwrap();
        let path_of = |id: &str| store.get_file_metadata(id).unwrap().unwrap().disk_path;
        let own = root.join("files").join("aa11.png").to_string_lossy().to_string();
        assert_eq!(path_of("aa11"), Some(own), "the landed copy was not taken");
        assert_eq!(path_of("aa11.png"), None, "a dotted id took another file's copy");
        assert_eq!(path_of("bb22"), None, "an empty extension took a copy");
        assert_eq!(path_of("x/../aa11"), None, "an id naming a path took another file's copy");
    }

    /// A value a crafted database stores as something other than text is foreign: its
    /// row is reset by rowid, and the rest of the gate still runs.
    #[test]
    fn an_unreadable_path_is_reset_and_the_gate_goes_on() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("ours");
        std::fs::create_dir_all(root.join("files")).unwrap();
        let store = MessageStore::open(root.join("messages.db").to_str().unwrap(), &"ef".repeat(32)).unwrap();
        let ours = |id: &str| root.join("files").join(format!("{id}.png"));
        for id in ["aa11", "bb22", "cc33"] {
            store
                .insert_file_metadata(
                    id, id, "png", "image/png", 9, 1, true, None, None, None, "dm", "friend", "friend", false, 1000,
                    None, None, None,
                )
                .unwrap();
            store.mark_file_complete(id, ours(id).to_str().unwrap()).unwrap();
        }
        store.conn.execute("UPDATE files SET disk_path = X'00' WHERE file_id = 'aa11'", []).unwrap();
        store.conn.execute("UPDATE files SET file_ext = X'01' WHERE file_id = 'bb22'", []).unwrap();
        let shared = root.join("shares").join("doc.pdf");
        store
            .upsert_share(
                &"aa".repeat(32), "doc", "pdf", "application/pdf", 6, 6, 1, "{}", &[7u8; 32], "link", "completed", true,
                Some(shared.to_str().unwrap()), Some(root.join("shares").to_str().unwrap()), 1000, None, None,
            )
            .unwrap();
        store.conn.execute("UPDATE shares SET disk_path = X'00', save_dir = X'01'", []).unwrap();

        store.forget_foreign_paths(&root).unwrap();
        let kind = |id: &str| -> String {
            store.conn.query_row("SELECT typeof(disk_path) FROM files WHERE file_id = ?1", [id], |r| r.get(0)).unwrap()
        };
        assert_eq!(kind("aa11"), "null", "a path that is not text was kept");
        assert_eq!(kind("bb22"), "null", "a row whose extension is not text kept its path");
        assert_eq!(kind("cc33"), "text", "a readable path of our own was dropped");
        let share: (String, String, i64) = store
            .conn
            .query_row("SELECT typeof(disk_path), typeof(save_dir), seeding FROM shares", [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .unwrap();
        assert_eq!(share, ("null".into(), "null".into(), 0), "a share kept a path that is not text");
    }

    /// Our content folder under another file's name is not ours, and a share is ours
    /// only in `shares/`, never as a file elsewhere under the root.
    #[test]
    fn a_path_under_another_files_name_or_outside_shares_is_forgotten() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let root = tmp.path().join("ours");
        std::fs::create_dir_all(root.join("files")).unwrap();
        std::fs::write(root.join("files").join("aa11.png"), b"HFE1 aa11").unwrap();
        let store = MessageStore::open(root.join("messages.db").to_str().unwrap(), &"ab".repeat(32)).unwrap();
        store
            .insert_file_metadata(
                "dd44", "dd44", "png", "image/png", 9, 1, true, None, None, None, "dm", "friend", "friend", false, 1000,
                None, None, None,
            )
            .unwrap();
        store.mark_file_complete("dd44", root.join("files").join("aa11.png").to_str().unwrap()).unwrap();
        let share = |hash: &str, path: &std::path::Path| {
            store
                .upsert_share(
                    hash, "doc", "pdf", "application/pdf", 6, 6, 1, "{}", &[7u8; 32], "link", "completed", true,
                    Some(path.to_str().unwrap()), None, 1000, None, None,
                )
                .unwrap();
        };
        share(&"aa".repeat(32), &root.join("messages.db"));
        share(&"bb".repeat(32), &root.join("shares").join("doc.pdf"));

        store.forget_foreign_paths(&root).unwrap();
        let f = store.get_file_metadata("dd44").unwrap().unwrap();
        assert_eq!(f.disk_path, None, "a row kept another file's bytes");
        let outside = store.load_share(&"aa".repeat(32)).unwrap().unwrap();
        assert_eq!((outside.disk_path, outside.seeding), (None, false), "a share serves the database");
        let inside = store.load_share(&"bb".repeat(32)).unwrap().unwrap();
        assert!(inside.disk_path.is_some() && inside.seeding, "a share in its own folder was dropped");
    }
}

#[cfg(test)]
mod w2c_revoked_marks {
    use super::*;

    const KEY: &str = "abababababababababababababababababababababababababababababababab";

    fn pair(d: &str, m: &str) -> (String, String) {
        (d.to_string(), m.to_string())
    }

    /// The raw rows of a (device, master) table, sorted; never the merged read.
    fn rows(store: &MessageStore, table: &str) -> Vec<(String, String)> {
        let mut stmt = store
            .conn
            .prepare(&format!("SELECT device_peer_id, master_peer_id FROM {table} ORDER BY 1, 2"))
            .unwrap();
        let out = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        out.map(|r| r.unwrap()).collect()
    }

    /// A database as 0.12 leaves it, plus `extra` SQL, before this build opens the file.
    fn old_db(db: &std::path::Path, extra: &str) {
        let old = Connection::open(db).unwrap();
        old.execute_batch(&format!(
            "PRAGMA key = \"x'{KEY}'\";
             CREATE TABLE revoked_devices (device_peer_id TEXT PRIMARY KEY, master_peer_id TEXT NOT NULL);
             INSERT INTO revoked_devices VALUES ('dev-old', 'master-o');
             {extra}"
        ))
        .unwrap();
    }

    /// 0.14: a database from before keeps every refusal, its old table moves into the
    /// per-master marks and is gone, and one identity's lifting leaves another's removal.
    #[test]
    fn w2c_old_revocations_move_into_the_marks_and_the_old_table_goes() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("messages.db");
        let open = || MessageStore::open(db.to_str().unwrap(), KEY).unwrap();
        old_db(&db, "");
        let store = open();
        assert_eq!(rows(&store, "revoked_marks"), vec![pair("dev-old", "master-o")], "the old rows were not copied");
        assert!(!table_exists(&store.conn, "revoked_devices"), "the old table outlived its move");

        store.record_revoked_devices("master-x", &["dev-old".to_string()]).unwrap();
        store.clear_revoked_devices("master-x", &["dev-old".to_string()]).unwrap();
        assert_eq!(store.revoked_marks().unwrap(), vec![pair("dev-old", "master-o")], "one identity lifted another's removal");
        drop(store);
        assert_eq!(open().revoked_marks().unwrap().len(), 1, "a second open lost a mark");
    }

    /// The copy and the drop are one step: a copy that fails (a busy or full disk) keeps
    /// the old table, whose rows still refuse in that session, and the next start moves
    /// them.
    #[test]
    fn w2c_a_failed_move_keeps_the_old_table_and_refuses() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("messages.db");
        let open = || MessageStore::open(db.to_str().unwrap(), KEY).unwrap();
        old_db(
            &db,
            "CREATE TABLE revoked_marks (device_peer_id TEXT NOT NULL, master_peer_id TEXT NOT NULL, PRIMARY KEY (device_peer_id, master_peer_id));
             CREATE TRIGGER fail_copy BEFORE INSERT ON revoked_marks WHEN new.device_peer_id = 'dev-old' BEGIN SELECT RAISE(ABORT, 'copy failed'); END;",
        );
        let store = open();
        assert!(rows(&store, "revoked_marks").is_empty(), "precondition: the copy failed");
        assert_eq!(rows(&store, "revoked_devices"), vec![pair("dev-old", "master-o")], "a failed copy dropped the old rows");
        assert_eq!(store.revoked_marks().unwrap(), vec![pair("dev-old", "master-o")], "a failed copy stopped refusing in this session");
        assert!(store.get_all_revoked_devices().unwrap().contains(&"dev-old".to_string()));

        // A removal recorded meanwhile lands in the marks only.
        store.record_revoked_devices("master-y", &["dev-new".to_string()]).unwrap();
        assert_eq!(rows(&store, "revoked_devices"), vec![pair("dev-old", "master-o")], "a record still wrote the old table");
        store.conn.execute_batch("DROP TRIGGER fail_copy").unwrap();
        // The next process's first open.
        MessageStore::init_schema(&store.conn).unwrap();
        assert!(!table_exists(&store.conn, "revoked_devices"), "the next start never dropped the old table");
        assert_eq!(rows(&store, "revoked_marks"), vec![pair("dev-new", "master-y"), pair("dev-old", "master-o")], "the next start never moved it");
    }

    /// While a failed move leaves the old table, a lift by the master its row names
    /// takes that row too (else the next start's move brings it back), and a lift by
    /// anyone else leaves it.
    #[test]
    fn w2c_a_lift_before_the_move_takes_only_its_own_old_row() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let store = MessageStore::open(tmp.path().join("messages.db").to_str().unwrap(), KEY).unwrap();
        store
            .conn
            .execute_batch(
                "CREATE TABLE revoked_devices (device_peer_id TEXT PRIMARY KEY, master_peer_id TEXT NOT NULL);
                 INSERT INTO revoked_devices VALUES ('dev', 'master-o');",
            )
            .unwrap();
        store.record_revoked_devices("master-x", &["dev".to_string()]).unwrap();
        store.clear_revoked_devices("master-x", &["dev".to_string()]).unwrap();
        assert_eq!(rows(&store, "revoked_devices"), vec![pair("dev", "master-o")], "another master's lift erased the old row");
        assert_eq!(store.revoked_marks().unwrap(), vec![pair("dev", "master-o")]);
        store.clear_revoked_devices("master-o", &["dev".to_string()]).unwrap();
        assert!(rows(&store, "revoked_devices").is_empty(), "its own master's lift left the old row");
        MessageStore::init_schema(&store.conn).unwrap();
        assert!(store.revoked_marks().unwrap().is_empty(), "the move brought a lifted removal back");
    }
}

#[cfg(test)]
mod g13w3_sync_cost {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    /// The per-sender WHERE 0.12.2 served pages with: one disjunct per known sender plus
    /// every unknown sender. The reference the page query must keep matching.
    fn old_where(sender_timestamps: &HashMap<String, i64>) -> (String, Vec<Box<dyn rusqlite::types::ToSql>>) {
        let mut conditions = Vec::new();
        let mut values: Vec<Box<dyn rusqlite::types::ToSql>> = vec![Box::new("srv".to_string()), Box::new("ch".to_string())];
        for (sender, ts) in sender_timestamps {
            conditions.push(format!("(sender_id = ?{} AND timestamp >= ?{})", values.len() + 1, values.len() + 2));
            values.push(Box::new(sender.clone()));
            values.push(Box::new(*ts));
        }
        let start = values.len() + 1;
        let marks: Vec<String> = (0..sender_timestamps.len()).map(|i| format!("?{}", start + i)).collect();
        conditions.push(format!("(sender_id NOT IN ({}))", marks.join(",")));
        values.extend(sender_timestamps.keys().map(|s| Box::new(s.clone()) as Box<dyn rusqlite::types::ToSql>));
        (conditions.join(" OR "), values)
    }

    fn old_page(store: &MessageStore, wm: &HashMap<String, i64>, limit: i32) -> (Vec<i64>, u32) {
        let (clause, mut values) = old_where(wm);
        let sql = format!(
            "SELECT id FROM channel_messages WHERE server_id = ?1 AND channel_id = ?2 AND ({clause})
             ORDER BY timestamp ASC, COALESCE(order_us, timestamp * 1000) ASC, message_id ASC LIMIT ?{}",
            values.len() + 1
        );
        values.push(Box::new(limit));
        let refs: Vec<&dyn rusqlite::types::ToSql> = values.iter().map(|v| v.as_ref()).collect();
        let mut stmt = store.conn.prepare(&sql).unwrap();
        let ids = stmt.query_map(refs.as_slice(), |r| r.get(0)).unwrap().map(|r| r.unwrap()).collect();
        let (clause, values) = old_where(wm);
        let refs: Vec<&dyn rusqlite::types::ToSql> = values.iter().map(|v| v.as_ref()).collect();
        let n: i64 = store
            .conn
            .query_row(&format!("SELECT COUNT(*) FROM channel_messages WHERE server_id = ?1 AND channel_id = ?2 AND ({clause})"), refs.as_slice(), |r| r.get(0))
            .unwrap();
        (ids, n as u32)
    }

    struct Rng(u64);
    impl Rng {
        fn below(&mut self, n: u64) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0 % n.max(1)
        }
    }

    /// `rows` posts by `senders` authors, a few of whom posted only long ago, with
    /// same-millisecond bursts told apart by their send stamps.
    fn channel(rows: i64, senders: u64, seed: u64) -> MessageStore {
        let store = MessageStore::open(":memory:", &"ab".repeat(32)).unwrap();
        let mut rng = Rng(seed);
        store.begin_transaction().unwrap();
        let mut ts = 1_000_000i64;
        for i in 0..rows {
            ts += rng.below(3) as i64;
            let quiet = i < rows / 10 && rng.below(4) == 0;
            let sender = if quiet { format!("quiet{}", rng.below(5)) } else { format!("author{:03}", rng.below(senders)) };
            let order_us = ts * 1000 + rng.below(1000) as i64;
            store
                .insert_channel_message("srv", "ch", &sender, &format!("post {i}"), false, ts, None, None, Some(&format!("m{i:06}")), None, None, Some(order_us), None)
                .unwrap();
        }
        store.commit_transaction().unwrap();
        store
    }

    fn new_page(store: &MessageStore, wm: &HashMap<String, i64>, limit: i32) -> (Vec<i64>, u32) {
        let ids = store.get_channel_messages_since_per_sender("srv", "ch", wm, limit).unwrap().iter().map(|m| m.id).collect();
        (ids, store.count_channel_messages_since_per_sender("srv", "ch", wm).unwrap())
    }

    #[test]
    fn per_sender_pages_serve_exactly_what_the_old_query_served() {
        let store = channel(3_000, 25, 7);
        let senders: Vec<String> = store.get_per_sender_timestamps("srv", "ch").unwrap().into_keys().collect();
        let (lo, hi) = (1_000_000i64, 1_000_000 + 3_000 * 2);
        let mut rng = Rng(99);
        let mut asks: Vec<HashMap<String, i64>> = Vec::new();
        for _ in 0..60 {
            let mut wm = HashMap::new();
            for s in &senders {
                if rng.below(3) > 0 {
                    wm.insert(s.clone(), lo + rng.below((hi - lo) as u64) as i64);
                }
            }
            if rng.below(4) == 0 {
                wm.insert(format!("stranger{}", rng.below(9)), lo + rng.below((hi - lo) as u64) as i64);
            }
            if wm.is_empty() {
                wm.insert("stranger".into(), 0);
            }
            asks.push(wm);
        }
        asks.push(senders.iter().map(|s| (s.clone(), hi + 10)).collect());
        asks.push(senders.iter().map(|s| (s.clone(), 0)).collect());
        // Our own watermarks, as a catch-up sends them.
        asks.push(store.get_per_sender_timestamps("srv", "ch").unwrap());
        for wm in &asks {
            for limit in [1, 200, 201] {
                assert_eq!(new_page(&store, wm, limit), old_page(&store, wm, limit), "ask {wm:?} limit {limit}");
            }
        }

        // An empty asker paging through to the end, as `channel_next_page_request` asks.
        let first = store.get_channel_messages_since("srv", "ch", 0, 200).unwrap();
        let mut known: std::collections::HashSet<String> = first.iter().map(|m| m.sender_id.clone()).collect();
        let mut last = first.iter().map(|m| m.timestamp).max().unwrap();
        let mut served: std::collections::HashSet<i64> = first.iter().map(|m| m.id).collect();
        loop {
            let wm: HashMap<String, i64> = known.iter().map(|s| (s.clone(), last)).collect();
            let page = store.get_channel_messages_since_per_sender("srv", "ch", &wm, 200).unwrap();
            assert_eq!(page.iter().map(|m| m.id).collect::<Vec<_>>(), old_page(&store, &wm, 200).0);
            served.extend(page.iter().map(|m| m.id));
            if page.len() < 200 {
                break;
            }
            last = page.iter().map(|m| m.timestamp).max().unwrap();
            known.extend(page.into_iter().map(|m| m.sender_id));
        }
        let served = served.len();
        assert!(served >= 3_000, "the walk reached the end ({served})");
    }

    extern "C" fn count_ops(counter: *mut std::ffi::c_void) -> std::ffi::c_int {
        // SAFETY: `vm_ops` passes a pointer to an AtomicU64 that outlives the handler.
        unsafe { (*(counter as *const AtomicU64)).fetch_add(1, Ordering::Relaxed) };
        0
    }

    /// SQLite virtual-machine steps (in hundreds) that `f` costs on `store`.
    fn vm_ops(store: &MessageStore, f: impl FnOnce()) -> u64 {
        let counter = AtomicU64::new(0);
        // SAFETY: the handler is removed before `counter` goes out of scope.
        unsafe {
            rusqlite::ffi::sqlite3_progress_handler(store.conn.handle(), 100, Some(count_ops), &counter as *const AtomicU64 as *mut std::ffi::c_void);
        }
        f();
        unsafe { rusqlite::ffi::sqlite3_progress_handler(store.conn.handle(), 0, None, std::ptr::null_mut()) };
        counter.load(Ordering::Relaxed)
    }

    /// The page an asker halfway through the history asks for next, and the
    /// watermarks it reads to ask: what each costs must not grow with the history.
    #[test]
    fn a_channel_page_costs_the_same_however_long_the_history() {
        let cost = |rows: i64| {
            let store = channel(rows, 100, 3);
            let senders: Vec<String> = store.get_per_sender_timestamps("srv", "ch").unwrap().into_keys().collect();
            let mid: i64 = store
                .conn
                .query_row("SELECT timestamp FROM channel_messages ORDER BY timestamp LIMIT 1 OFFSET ?1", [rows / 2], |r| r.get(0))
                .unwrap();
            let wm: HashMap<String, i64> = senders.into_iter().map(|s| (s, mid)).collect();
            let page = vm_ops(&store, || assert_eq!(store.get_channel_messages_since_per_sender("srv", "ch", &wm, 201).unwrap().len(), 201));
            let marks = vm_ops(&store, || assert!(!store.get_per_sender_timestamps("srv", "ch").unwrap().is_empty()));
            // A catch-up of the newest posts from an asker that holds the rest, among them
            // the quiet authors' posts from long ago.
            let newest: Vec<(String, i64)> = {
                let mut stmt = store
                    .conn
                    .prepare("SELECT sender_id, MAX(timestamp) FROM channel_messages WHERE timestamp < ?1 GROUP BY sender_id")
                    .unwrap();
                stmt.query_map([mid + (rows / 3)], |r| Ok((r.get(0)?, r.get(1)?))).unwrap().map(|r| r.unwrap()).collect()
            };
            let held: HashMap<String, i64> = newest.into_iter().map(|(s, ts)| (s, ts - 5)).collect();
            let catch_up = vm_ops(&store, || assert_eq!(store.get_channel_messages_since_per_sender("srv", "ch", &held, 201).unwrap().len(), 201));
            (page, marks, catch_up)
        };
        let (small, large) = (cost(2_000), cost(20_000));
        assert!(large.0 < small.0 * 2, "a page costs {} at 20k rows, {} at 2k", large.0, small.0);
        assert!(large.1 < small.1 * 2, "the watermarks cost {} at 20k rows, {} at 2k", large.1, small.1);
        assert!(large.2 < small.2 * 2, "a catch-up page costs {} at 20k rows, {} at 2k", large.2, small.2);
    }

    /// U18: a delta writes its rows and deletes only the rows it names, all or nothing:
    /// a channel NAMED "ServerCreated" is deleted like any row (F11 keyed the founding op
    /// on a JSON `LIKE`), a lower-hash op replaces the row at its key, and a parked mark
    /// round-trips. Also a 0.13 database gains the parked column.
    #[test]
    fn persist_is_one_transaction_and_keys_the_founding_op() {
        use crate::crdt::fold::OpDelta;
        use crate::crdt::hlc::HlcTimestamp;
        use crate::crdt::operations::CrdtPayload as P;
        let store = MessageStore::open(":memory:", &"ab".repeat(32)).expect("open in-memory store");
        let op = |tag: u8, ms: u64, payload: P| {
            let (kp, id, pk) = crate::crdt::testkeys::keys(tag);
            let mut op = CrdtOp { server_id: "S".into(), hlc: HlcTimestamp { physical_ms: ms, counter: 0, actor: id.clone() }, author: id, payload, auth: None, dev: None };
            op.sign(&kp, &pk);
            op
        };
        let key = |o: &CrdtOp| (o.author.clone(), o.hlc.clone());
        let founding = op(1, 50, P::ServerCreated { name: "s".into(), owner_peer_id: crate::crdt::testkeys::keys(1).1, nonce: "n".into() });
        let named = op(1, 100, P::ChannelAdded { channel_id: "c".into(), name: "ServerCreated".into(), category: None, channel_type: "text".into() });
        let rename = op(1, 150, P::ServerRenamed { new_name: "a".into() });
        let delta = |rows: Vec<(CrdtOp, Option<u64>)>, dropped: Vec<_>| OpDelta { server_id: "S".into(), rows, dropped, base: None, seen_keep: None, own_since: Vec::new(), recovery: None };
        store.persist_op_delta(&delta(vec![(founding.clone(), None), (named.clone(), None), (rename.clone(), Some(77))], vec![])).unwrap();
        let rows = store.load_op_rows("S").unwrap();
        assert_eq!(rows.iter().find(|(o, _)| o.hlc == rename.hlc).map(|r| r.1), Some(Some(77)), "the parked mark round-trips");
        store.persist_op_delta(&delta(vec![(rename.clone(), None)], vec![key(&named)])).unwrap();
        let rows = store.load_op_rows("S").unwrap();
        let ms: Vec<u64> = rows.iter().map(|(o, _)| o.hlc.physical_ms).collect();
        assert_eq!(ms, vec![50, 150], "only the named row went; the founding op stayed");
        assert_eq!(rows[1].1, None, "an unparked row loses its mark");
        let mut rival = op(1, 150, P::ServerRenamed { new_name: "b".into() });
        rival.hlc = rename.hlc.clone();
        rival.sign(&crate::crdt::testkeys::keys(1).0, &crate::crdt::testkeys::keys(1).2);
        store.persist_op_delta(&delta(vec![(rival.clone(), None)], vec![])).unwrap();
        let stored = store.load_op_rows("S").unwrap();
        assert!(matches!(&stored[1].0.payload, P::ServerRenamed { new_name } if new_name == "b"), "the winner replaces the row at its key");
        // All or nothing: a delta that fails halfway leaves the rows as they were.
        store.conn.execute_batch("CREATE TRIGGER no_delete BEFORE DELETE ON crdt_ops BEGIN SELECT RAISE(ABORT, 'no'); END;").unwrap();
        let failing = delta(vec![(named.clone(), None)], vec![key(&founding)]);
        assert!(store.persist_op_delta(&failing).is_err());
        assert_eq!(store.load_op_rows("S").unwrap().len(), 2, "the failed delta's write was rolled back");
        // A 0.13 table, without the column, gains it on open.
        let old = Connection::open_in_memory().unwrap();
        old.execute_batch("CREATE TABLE crdt_ops (id INTEGER PRIMARY KEY AUTOINCREMENT, server_id TEXT NOT NULL, hlc_ms INTEGER NOT NULL, hlc_counter INTEGER NOT NULL, author TEXT NOT NULL, op_json TEXT NOT NULL, UNIQUE(server_id, hlc_ms, hlc_counter, author)); INSERT INTO crdt_ops (server_id, hlc_ms, hlc_counter, author, op_json) VALUES ('S', 1, 0, 'a', '{}');").unwrap();
        migrate(&old, "ALTER TABLE crdt_ops ADD COLUMN parked_until INTEGER");
        let n: i64 = old.query_row("SELECT COUNT(*) FROM crdt_ops WHERE parked_until IS NULL", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 1, "the 0.13 row survives the migration unparked");
    }

    /// DEVICE_PROOF_DESIGN section 7 (R3-4): `seen_ms` is set once when a row is first
    /// stored, a base's first fold once; a 0.13 database reads 0 for both after the upgrade.
    #[test]
    fn first_store_and_first_fold_are_dated_once_and_the_upgrade_reads_zero() {
        use crate::crdt::fold::OpDelta;
        use crate::crdt::hlc::HlcTimestamp;
        use crate::crdt::operations::CrdtPayload as P;
        let op = |ms: u64, payload: P| {
            let (kp, id, pk) = crate::crdt::testkeys::keys(1);
            let mut op = CrdtOp { server_id: "S".into(), hlc: HlcTimestamp { physical_ms: ms, counter: 0, actor: id.clone() }, author: id, payload, auth: None, dev: None };
            op.sign(&kp, &pk);
            op
        };
        let rename = op(150, P::ServerRenamed { new_name: "a".into() });
        let cp = op(200, P::ServerCheckpoint { state: "{}".into(), covers: HlcTimestamp::zero("") });
        let cp_id = hex::encode(cp.content_hash());

        let old = Connection::open_in_memory().unwrap();
        old.execute_batch("CREATE TABLE crdt_ops (id INTEGER PRIMARY KEY AUTOINCREMENT, server_id TEXT NOT NULL, hlc_ms INTEGER NOT NULL, hlc_counter INTEGER NOT NULL, author TEXT NOT NULL, op_json TEXT NOT NULL, UNIQUE(server_id, hlc_ms, hlc_counter, author));").unwrap();
        for o in [&rename, &cp] {
            old.execute(
                "INSERT INTO crdt_ops (server_id, hlc_ms, hlc_counter, author, op_json) VALUES ('S', ?1, 0, ?2, ?3)",
                params![o.hlc.physical_ms as i64, o.author, serde_json::to_string(o).unwrap()],
            )
            .unwrap();
        }
        MessageStore::init_schema(&old).expect("the 0.14 schema over a 0.13 database");
        let zero: i64 = old.query_row("SELECT COUNT(*) FROM crdt_ops WHERE seen_ms = 0", [], |r| r.get(0)).unwrap();
        assert_eq!(zero, 2, "rows from before the upgrade were stored before any T");
        let seeded: i64 = old.query_row("SELECT first_fold_ms FROM cp_seen WHERE server_id = 'S' AND content_id = ?1", [&cp_id], |r| r.get(0)).unwrap();
        assert_eq!(seeded, 0, "a checkpoint held before the upgrade was first folded before any T");
        MessageStore::init_schema(&old).expect("a second run");
        let n: i64 = old.query_row("SELECT COUNT(*) FROM cp_seen", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 1, "the seed runs once");

        let store = MessageStore::open(":memory:", &"ab".repeat(32)).expect("open in-memory store");
        let delta = |rows: Vec<(CrdtOp, Option<u64>)>, base: Option<String>| OpDelta { server_id: "S".into(), rows, dropped: Vec::new(), base, seen_keep: None, own_since: Vec::new(), recovery: None };
        let before = crate::crdt::hlc::wall_clock_ms();
        store.persist_op_delta(&delta(vec![(rename.clone(), None), (cp.clone(), None)], Some(cp_id.clone()))).unwrap();
        let seen = store.op_seen_ms("S").unwrap();
        let first = seen[&(rename.author.clone(), 150, 0)];
        assert!(first >= before, "a new row is dated when first stored");
        let folded = store.cp_first_fold_ms("S", &cp_id).expect("the base's first fold");
        assert!(folded >= before);
        store.conn.execute("UPDATE crdt_ops SET seen_ms = 5 WHERE hlc_ms = 150", []).unwrap();
        store.conn.execute("UPDATE cp_seen SET first_fold_ms = 5", []).unwrap();
        store.persist_op_delta(&delta(vec![(rename.clone(), Some(9))], Some(cp_id.clone()))).unwrap();
        assert_eq!(store.op_seen_ms("S").unwrap()[&(rename.author.clone(), 150, 0)], 5, "rewriting a row never moves its date");
        assert_eq!(store.cp_first_fold_ms("S", &cp_id), Some(5), "folding a base again never moves its first fold");
        store.delete_server_state("S").unwrap();
        assert_eq!(store.cp_first_fold_ms("S", &cp_id), None, "a deleted server's first folds go with it");
    }

    /// Lead decision 11-05 (section 8.3): `seen_ms` dates the CONTENT a row holds, so an
    /// equivocation that replaces it at its key after T reads as first stored then, while
    /// a proof added to the same content keeps the row's date.
    #[test]
    fn a_row_replaced_by_other_content_is_dated_again() {
        use crate::crdt::fold::OpDelta;
        use crate::crdt::hlc::HlcTimestamp;
        use crate::crdt::operations::CrdtPayload as P;
        let (kp, id, pk) = crate::crdt::testkeys::keys(1);
        let op = |name: &str| {
            let mut op = CrdtOp { server_id: "S".into(), hlc: HlcTimestamp { physical_ms: 150, counter: 0, actor: id.clone() }, author: id.clone(), payload: P::ServerRenamed { new_name: name.into() }, auth: None, dev: None };
            op.sign(&kp, &pk);
            op
        };
        let store = MessageStore::open(":memory:", &"ab".repeat(32)).expect("open in-memory store");
        let delta = |o: &CrdtOp| OpDelta { server_id: "S".into(), rows: vec![(o.clone(), None)], dropped: Vec::new(), base: None, seen_keep: None, own_since: Vec::new(), recovery: None };
        let key = (id.clone(), 150, 0);
        store.persist_op_delta(&delta(&op("a"))).unwrap();
        store.conn.execute("UPDATE crdt_ops SET seen_ms = 5", []).unwrap();
        let mut proven = op("a");
        proven.sign_device(&crate::crdt::testkeys::keys(2).0);
        store.persist_op_delta(&delta(&proven)).unwrap();
        assert_eq!(store.op_seen_ms("S").unwrap()[&key], 5, "the same content with a proof keeps its date");
        let before = crate::crdt::hlc::wall_clock_ms();
        store.persist_op_delta(&delta(&op("b"))).unwrap();
        assert!(store.op_seen_ms("S").unwrap()[&key] >= before, "other content at the key is first stored now");

        // A row from before the upgrade holds no content id: its own JSON keeps the date,
        // other content does not.
        let old = op("a");
        store.conn.execute("DELETE FROM crdt_ops", []).unwrap();
        store
            .conn
            .execute(
                "INSERT INTO crdt_ops (server_id, hlc_ms, hlc_counter, author, op_json, seen_ms) VALUES ('S', 150, 0, ?1, ?2, 0)",
                params![id, serde_json::to_string(&old).unwrap()],
            )
            .unwrap();
        store.persist_op_delta(&delta(&old)).unwrap();
        assert_eq!(store.op_seen_ms("S").unwrap()[&key], 0, "an upgraded row rewritten as it was keeps its date");
        store.conn.execute("UPDATE crdt_ops SET content_h = ''", []).unwrap();
        store.persist_op_delta(&delta(&op("b"))).unwrap();
        assert!(store.op_seen_ms("S").unwrap()[&key] >= before, "and other content is first stored now");
    }

    /// Section 14: a rebuild's delta names the first folds that stay; the rest go.
    #[test]
    fn first_folds_rotate_to_what_a_rebuild_keeps() {
        use crate::crdt::fold::OpDelta;
        let store = MessageStore::open(":memory:", &"ab".repeat(32)).expect("open in-memory store");
        let delta = |base: &str, keep: Option<Vec<String>>| OpDelta { server_id: "S".into(), rows: Vec::new(), dropped: Vec::new(), base: Some(base.into()), seen_keep: keep, own_since: Vec::new(), recovery: None };
        store.persist_op_delta(&delta("a", None)).unwrap();
        store.persist_op_delta(&delta("b", None)).unwrap();
        store.persist_op_delta(&OpDelta { server_id: "T".into(), base: Some("a".into()), ..Default::default() }).unwrap();
        store.persist_op_delta(&delta("c", Some(vec!["a".into(), "c".into()]))).unwrap();
        let mut held: Vec<String> = store.cp_first_folds("S").into_keys().collect();
        held.sort();
        assert_eq!(held, vec!["a".to_string(), "c".to_string()]);
        assert!(store.cp_first_fold_ms("T", "a").is_some(), "another server's records stay");
    }
}

#[cfg(test)]
mod w2c_storage {
    use super::*;

    const KEY: &str = "abababababababababababababababababababababababababababababababab";

    fn post(store: &MessageStore, ch: &str, sender: &str, ts: i64, text: &str, mid: &str) -> usize {
        store
            .insert_channel_message("srv", ch, sender, text, false, ts, None, None, Some(mid), None, None, None, None)
            .unwrap()
    }

    fn mids(store: &MessageStore, ch: &str) -> Vec<String> {
        let mut stmt = store
            .conn
            .prepare("SELECT message_id FROM channel_messages WHERE server_id = 'srv' AND channel_id = ?1 ORDER BY id")
            .unwrap();
        stmt.query_map([ch], |r| r.get::<_, String>(0)).unwrap().map(|r| r.unwrap()).collect()
    }

    fn file_store(tmp: &std::path::Path) -> MessageStore {
        MessageStore::open(tmp.join("messages.db").to_str().unwrap(), KEY).unwrap()
    }

    fn index_names(store: &MessageStore) -> Vec<String> {
        let mut stmt = store
            .conn
            .prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'channel_messages' ORDER BY name")
            .unwrap();
        stmt.query_map([], |r| r.get::<_, String>(0)).unwrap().map(|r| r.unwrap()).collect()
    }

    /// A database as 0.13 leaves it: the `UNIQUE(..., text)` table, every later column,
    /// search and its triggers. Two rows share an id, as a race between two writers
    /// could leave them.
    fn old_channel_db(db: &std::path::Path) {
        {
            let old = Connection::open(db).unwrap();
            old.execute_batch(&format!(
                "PRAGMA key = \"x'{KEY}'\";
                 CREATE TABLE channel_messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, server_id TEXT NOT NULL, channel_id TEXT NOT NULL,
                    sender_id TEXT NOT NULL, text TEXT NOT NULL, is_mine INTEGER NOT NULL, timestamp INTEGER NOT NULL,
                    UNIQUE(server_id, channel_id, sender_id, timestamp, text));"
            ))
            .unwrap();
        }
        let store = file_store(db.parent().unwrap());
        assert!(has_content_key(&store.conn), "precondition: the old table keeps its content key on open");
        assert!(
            !index_names(&store).iter().any(|n| n == "idx_channel_msgs_sender_ts"),
            "an open indexed a whole old history",
        );
        // 0.13's id index was not unique.
        store
            .conn
            .execute_batch("DROP INDEX idx_channel_msgs_msg_id; CREATE INDEX idx_channel_msgs_msg_id ON channel_messages (message_id);")
            .unwrap();
        assert_eq!(post(&store, "ch", "alice", 1_000, "hello", "m1"), 1);
        assert_eq!(post(&store, "ch", "bob", 2_000, "searchable words", "m2"), 1);
        assert_eq!(post(&store, "ch", "bob", 2_000, "searchable words", "m3"), 0, "precondition: the old key drops a post alike");
        store
            .conn
            .execute_batch("INSERT INTO channel_messages (server_id, channel_id, sender_id, text, is_mine, timestamp, message_id) VALUES ('srv', 'ch', 'carol', 'second copy', 0, 3000, 'm1')")
            .unwrap();
    }

    /// Two different posts alike in sender, millisecond and text are two messages.
    #[test]
    fn w2c_two_posts_alike_in_one_millisecond_both_land() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let store = file_store(tmp.path());
        assert_eq!(post(&store, "ch", "alice", 1_000, "lol", "m1"), 1);
        assert_eq!(post(&store, "ch", "alice", 1_000, "lol", "m2"), 1, "the content key dropped a distinct post");
        assert_eq!(mids(&store, "ch"), vec!["m1", "m2"]);
    }

    /// Dedup is by message id: one id is one row, whatever its text, so two writers
    /// racing past the exists check still store a message once.
    #[test]
    fn w2c_one_message_id_is_stored_once() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let store = file_store(tmp.path());
        assert_eq!(post(&store, "ch", "alice", 1_000, "first", "m1"), 1);
        assert_eq!(post(&store, "ch", "alice", 1_000, "edited copy", "m1"), 0, "a second row took the same id");
        assert_eq!(post(&store, "other", "alice", 5_000, "elsewhere", "m1"), 0, "a second row took the same id");
        let legacy = |ts: i64| store.insert_channel_message("srv", "ch", "x", "no id", false, ts, None, None, None, None, None, None, None).unwrap();
        assert_eq!((legacy(1), legacy(1)), (1, 1), "rows without an id are not keyed");
    }

    /// The sync watermarks read each sender's first and last row by index seeks, on a
    /// new database and on a rebuilt one alike.
    #[test]
    fn w2c_sender_watermarks_seek_the_sender_index() {
        let plan = |store: &MessageStore| -> String {
            let mut stmt = store
                .conn
                .prepare("EXPLAIN QUERY PLAN SELECT MAX(timestamp) FROM channel_messages WHERE server_id = 'srv' AND channel_id = 'ch' AND sender_id = 'bob'")
                .unwrap();
            stmt.query_map([], |r| r.get::<_, String>(3)).unwrap().map(|r| r.unwrap()).collect::<Vec<_>>().join(" | ")
        };
        let fresh = crate::test_tmp::tempdir().unwrap();
        let p = plan(&file_store(fresh.path()));
        assert!(p.contains("idx_channel_msgs_sender_ts"), "a new database plans {p}");

        let old = crate::test_tmp::tempdir().unwrap();
        let db = old.path().join("messages.db");
        old_channel_db(&db);
        MessageStore::migrate_auto_vacuum_once(db.to_str().unwrap(), KEY).unwrap();
        let p = plan(&file_store(old.path()));
        assert!(p.contains("idx_channel_msgs_sender_ts"), "a rebuilt database plans {p}");
    }

    /// The start-up rebuild of a 0.13 database: the content key is gone, every row keeps
    /// its id and columns (one row per message id, the oldest), search still finds old
    /// and new rows, and ids keep counting up.
    #[test]
    fn w2c_an_old_database_loses_its_content_key_and_keeps_its_history() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("messages.db");
        old_channel_db(&db);
        let before: Vec<(i64, String, String)> = {
            let store = file_store(tmp.path());
            let mut stmt = store.conn.prepare("SELECT id, message_id, text FROM channel_messages ORDER BY id").unwrap();
            stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap().map(|r| r.unwrap()).collect()
        };
        MessageStore::migrate_auto_vacuum_once(db.to_str().unwrap(), KEY).unwrap();

        let store = file_store(tmp.path());
        assert!(!has_content_key(&store.conn), "the content key survived the rebuild");
        let after: Vec<(i64, String, String)> = {
            let mut stmt = store.conn.prepare("SELECT id, message_id, text FROM channel_messages ORDER BY id").unwrap();
            stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap().map(|r| r.unwrap()).collect()
        };
        assert_eq!(after, before[..2].to_vec(), "the rebuild lost a row or kept a second copy of an id");
        for name in ["idx_channel_msgs", "idx_channel_msgs_msg_id", "idx_channel_msgs_sender_ts", "idx_channel_msgs_updated"] {
            assert!(index_names(&store).iter().any(|n| n == name), "{name} is missing after the rebuild");
        }
        assert_eq!(store.search_channel_messages("srv", "ch", "searchable", 10).unwrap().len(), 1, "search lost an old row");
        assert_eq!(post(&store, "ch", "bob", 2_000, "searchable words", "m3"), 1, "a post alike is still dropped");
        assert_eq!(store.search_channel_messages("srv", "ch", "searchable", 10).unwrap().len(), 2, "search misses a new row");
        let newest: i64 = store.conn.query_row("SELECT MAX(id) FROM channel_messages", [], |r| r.get(0)).unwrap();
        assert!(newest > before.iter().map(|r| r.0).max().unwrap(), "ids started over");
        // Once rebuilt, a later start leaves the table alone.
        assert!(!MessageStore::rebuild_channel_messages(&store.conn).unwrap());
    }

    /// A rebuild that fails late (after the old table is dropped) changes nothing: the
    /// old table, its key, rows and search stay, and the next start finishes it.
    #[test]
    fn w2c_a_failed_rebuild_leaves_the_old_table_whole() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("messages.db");
        old_channel_db(&db);
        {
            let store = file_store(tmp.path());
            store
                .conn
                .execute_batch("DROP INDEX idx_channel_msgs_updated; CREATE INDEX idx_channel_msgs_updated ON friends (peer_id);")
                .unwrap();
        }
        let store = file_store(tmp.path());
        let err = MessageStore::rebuild_channel_messages(&store.conn).unwrap_err();
        assert!(err.contains("updated index"), "failed elsewhere: {err}");
        assert!(has_content_key(&store.conn), "a failed rebuild left a half-built table");
        assert_eq!(mids(&store, "ch"), vec!["m1", "m2", "m1"], "a failed rebuild lost rows");
        assert_eq!(store.search_channel_messages("srv", "ch", "searchable", 10).unwrap().len(), 1, "a failed rebuild broke search");
        assert!(!table_exists(&store.conn, "channel_messages_rebuild"));

        store.conn.execute_batch("DROP INDEX idx_channel_msgs_updated").unwrap();
        assert!(MessageStore::rebuild_channel_messages(&store.conn).unwrap(), "the next start did not rebuild");
        assert!(!has_content_key(&store.conn));
    }

    /// A schema the rebuild does not recognise (a foreign database's) is left alone,
    /// never run as SQL.
    #[test]
    fn w2c_a_rebuild_refuses_a_column_it_did_not_write() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("messages.db");
        old_channel_db(&db);
        let store = file_store(tmp.path());
        store.conn.execute_batch("ALTER TABLE channel_messages ADD COLUMN \"x) ; DROP TABLE friends; --\" TEXT").unwrap();
        assert!(MessageStore::rebuild_channel_messages(&store.conn).is_err());
        assert!(has_content_key(&store.conn) && table_exists(&store.conn, "friends"));
    }

    /// The rebuild reads column shapes back from the table it replaces; anything our own
    /// DDL never writes is refused rather than spliced into SQL.
    #[test]
    fn w2c_only_plain_columns_are_rebuilt() {
        assert_eq!(plain_column("text", "TEXT", true, None, false).as_deref(), Some("text TEXT NOT NULL"));
        assert_eq!(plain_column("lp_at", "integer", false, None, false).as_deref(), Some("lp_at INTEGER"));
        assert_eq!(plain_column("id", "INTEGER", false, None, true).as_deref(), Some("id INTEGER PRIMARY KEY AUTOINCREMENT"));
        for (name, ty, default, pk) in [
            ("x) ; DROP TABLE friends; --", "TEXT", None, false),
            ("Text", "TEXT", None, false),
            ("1col", "TEXT", None, false),
            ("", "TEXT", None, false),
            ("note", "TEXT); DROP TABLE friends; --", None, false),
            ("note", "VARCHAR(10)", None, false),
            ("note", "TEXT", Some("'x'"), false),
            ("rowkey", "INTEGER", None, true),
        ] {
            assert_eq!(plain_column(name, ty, false, default, pk), None, "{name:?} {ty:?} passed");
        }
    }

    /// Clearing takes this device's server history and keeps it gone: each channel's
    /// floor sits at its newest row, nothing at or before it is stored again on any
    /// path, a newer post lands, and the asks still name what it cleared.
    #[test]
    fn w2c_cleared_history_is_refused_when_it_comes_back() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let store = file_store(tmp.path());
        let t = 10 * CLEAR_SKEW_MS;
        post(&store, "ch", "alice", t + 1_000, "a", "m1");
        post(&store, "ch", "bob", t + 2_000, "b", "m2");
        post(&store, "quiet", "alice", t + 500, "c", "m3");
        let cleared = store.clear_channel_history(t + 10_000).unwrap();
        assert_eq!(cleared.messages, 3);
        assert_eq!(store.count_all_channel_messages().unwrap(), 0);
        assert_eq!((store.channel_floor("srv", "ch"), store.channel_floor("srv", "quiet")), (Some(t + 2_000), Some(t + 500)));

        assert_eq!(post(&store, "ch", "alice", t + 1_000, "a", "m1"), 0, "a cleared message came back");
        assert_eq!(post(&store, "ch", "bob", t + 2_000, "b", "m2"), 0, "the newest cleared message came back");
        assert_eq!(post(&store, "ch", "dave", t + 2_000 - CLEAR_SKEW_MS, "d", "m4"), 0, "an old message never held came in");
        assert_eq!(post(&store, "ch", "bob", t + 2_001, "new", "m5"), 1, "a post after the clear was refused");
        assert_eq!(post(&store, "fresh", "bob", 1, "elsewhere", "m6"), 1, "a channel never cleared refused history");
        assert_eq!(mids(&store, "ch"), vec!["m5"]);

        // Asks name every sender held or cleared from its newest row, as they did before the
        // clear, and never one the floor only refused.
        let marks = store.get_per_sender_timestamps("srv", "ch").unwrap();
        let lb = SYNC_LOOKBACK_MS;
        assert_eq!(marks, HashMap::from([("alice".to_string(), t + 1_000 - lb), ("bob".to_string(), t + 2_001 - lb)]));
    }

    /// A cleared channel asks as it did before its clear: the per-sender marks, `since` and
    /// gap digest count what it cleared, so they never stop at the floor, and a post
    /// arriving later asks below itself as a device that never cleared does.
    #[test]
    fn w2c_a_cleared_channel_asks_as_before_its_clear() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let (store, twin) = (file_store(tmp.path()), MessageStore::open(tmp.path().join("twin.db").to_str().unwrap(), KEY).unwrap());
        let day = 24 * 60 * 60 * 1000;
        let floor = 40 * day;
        for s in [&store, &twin] {
            post(s, "ch", "alice", floor - 5 * day, "old", "m1");
            post(s, "ch", "alice", floor, "newest", "m2");
        }
        store.clear_channel_history(floor + day).unwrap();
        let ask = |s: &MessageStore| {
            (s.channel_ask_since("srv", "ch"), s.get_per_sender_timestamps("srv", "ch").unwrap(), s.channel_gap_anchor("srv", "ch"))
        };
        assert_eq!(ask(&store), ask(&twin));
        assert_eq!(store.get_per_sender_timestamps("srv", "ch").unwrap(), HashMap::from([("alice".to_string(), floor - SYNC_LOOKBACK_MS)]));
        for s in [&store, &twin] {
            post(s, "ch", "bob", floor + 3 * day, "later", "m3");
        }
        assert_eq!(ask(&store), ask(&twin));
        let gap = store.channel_gap_anchor("srv", "ch").expect("a digest behind the newest post");
        assert!(gap.from < floor - 5 * day && gap.days.iter().map(|d| d.n).sum::<u32>() == 2, "the digest stops short of what it cleared: {gap:?}");
    }

    /// The floor never passes the clock: a post stamped ahead of it goes by its id, and
    /// a post sent after the clear is never refused for it.
    #[test]
    fn w2c_a_floor_never_reaches_past_now() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let store = file_store(tmp.path());
        post(&store, "ch", "skewed", 50_000, "from the future", "m1");
        post(&store, "ch", "alice", 9_000, "now-ish", "m2");
        assert_eq!(store.clear_channel_history(10_000).unwrap().messages, 2);
        assert_eq!(store.channel_floor("srv", "ch"), Some(10_000));
        assert!(mids(&store, "ch").is_empty());
        assert_eq!(post(&store, "ch", "alice", 10_001, "after", "m3"), 1);
    }

    /// The clear takes what hangs off a cleared message (edits, deletions, reactions,
    /// file rows) and hands back its downloads; DMs and their reactions stay.
    #[test]
    fn w2c_clear_takes_what_hangs_off_the_messages_and_leaves_dms() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let store = file_store(tmp.path());
        post(&store, "ch", "alice", 1_000, "with a file", "cm1");
        store.insert("friend", "a dm", false, 1_000, None, None, Some("dm1"), None, None, None, None).unwrap();
        assert!(store.add_reaction("cm1", "+1", "bob", 1_100, None, None).unwrap());
        assert!(store.add_reaction("dm1", "+1", "friend", 1_100, None, None).unwrap());
        store
            .conn
            .execute_batch(
                "INSERT INTO message_edits (message_id, old_text, new_text, edited_at) VALUES ('cm1', 'a', 'b', 1200);
                 INSERT INTO message_deletions (message_id, deleted_text, deleted_at) VALUES ('cm1', 'b', 1300);",
            )
            .unwrap();
        store
            .insert_file_metadata("f1", "a", "png", "image/png", 5, 1, true, None, None, Some("cm1"), "channel", "srv:ch", "alice", false, 1_000, None, None, None)
            .unwrap();
        store
            .insert_file_metadata("f2", "b", "png", "image/png", 5, 1, true, None, None, Some("dm1"), "dm", "friend", "friend", false, 1_000, None, None, None)
            .unwrap();
        // A DM file naming a cleared channel message's id (a peer reusing it) stays.
        store
            .insert_file_metadata("f3", "c", "png", "image/png", 5, 1, true, None, None, Some("cm1"), "dm", "friend", "friend", false, 1_000, None, None, None)
            .unwrap();
        store.conn.execute_batch("UPDATE files SET disk_path = '/files/' || file_id, completed_at = 1").unwrap();

        let cleared = store.clear_channel_history(10_000).unwrap();
        assert_eq!(cleared.files, vec![("f1".to_string(), "png".to_string())]);
        let count = |sql: &str| -> i64 { store.conn.query_row(sql, [], |r| r.get(0)).unwrap() };
        assert_eq!(count("SELECT COUNT(*) FROM message_edits WHERE message_id = 'cm1'"), 0);
        assert_eq!(count("SELECT COUNT(*) FROM message_deletions WHERE message_id = 'cm1'"), 0);
        assert_eq!(count("SELECT COUNT(*) FROM message_reactions WHERE message_id = 'cm1'"), 0);
        assert_eq!(count("SELECT COUNT(*) FROM files WHERE file_id = 'f1'"), 0);
        assert_eq!(count("SELECT COUNT(*) FROM messages WHERE message_id = 'dm1'"), 1, "a DM was cleared");
        assert_eq!(count("SELECT COUNT(*) FROM message_reactions WHERE message_id = 'dm1'"), 1, "a DM lost its reaction");
        assert_eq!(count("SELECT COUNT(*) FROM files WHERE file_id IN ('f2', 'f3')"), 2, "a DM lost its file");
    }

    /// More history than one batch is cleared whole, search forgets it, and the file
    /// gives its pages back.
    #[test]
    fn w2c_a_long_history_is_cleared_whole() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        MessageStore::migrate_auto_vacuum_once(tmp.path().join("messages.db").to_str().unwrap(), KEY).unwrap();
        let store = file_store(tmp.path());
        let n = CLEAR_BATCH_ROWS * 2 + 7;
        for i in 0..n {
            post(&store, "ch", "alice", 1_000 + i, "needle", &format!("m{i}"));
        }
        let pages = |p: &str| -> i64 { store.conn.query_row(&format!("PRAGMA {p}"), [], |r| r.get(0)).unwrap() };
        let held = pages("page_count");
        assert_eq!(store.clear_channel_history(1_000_000).unwrap().messages, n as u64);
        assert_eq!(store.count_all_channel_messages().unwrap(), 0);
        assert_eq!(pages("freelist_count"), 0, "the clear kept its freed pages");
        assert!(pages("page_count") < held, "the file did not shrink");
        assert!(store.search_channel_messages("srv", "ch", "needle", 10).unwrap().is_empty(), "search still finds cleared rows");
    }

    /// Measures the start-up rebuild and a clear on a 0.13-shaped encrypted file of
    /// `W2C_ROWS` channel rows (default 100k) with link cards, and writes the numbers to
    /// `W2C_MEASURE_OUT`. Run by hand: `cargo test --lib w2c_measure -- --ignored`.
    #[test]
    #[ignore]
    fn w2c_measure_rebuild_and_clear_on_a_large_history() {
        let rows: i64 = std::env::var("W2C_ROWS").ok().and_then(|v| v.parse().ok()).unwrap_or(100_000);
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("messages.db");
        old_channel_db(&db);
        let size = || -> u64 {
            ["", "-wal"].iter().filter_map(|x| std::fs::metadata(format!("{}{x}", db.display())).ok()).map(|m| m.len()).sum()
        };
        {
            let store = file_store(tmp.path());
            // A 0.13 database is already incremental: the measure is the rebuild alone.
            store.conn.execute_batch("PRAGMA auto_vacuum = INCREMENTAL; VACUUM;").unwrap();
            let card = serde_json::json!({"url": "https://example.com/a/long/path", "title": "A link card title", "description": "x".repeat(280)}).to_string();
            store.begin_transaction().unwrap();
            for i in 0..rows {
                let mid = format!("{:08x}-0000-4000-8000-{:012x}", i, i);
                let text = format!("message {i} with an ordinary amount of text in it, about a line long");
                store
                    .insert_channel_message("srv", &format!("ch{}", i % 8), &format!("12D3KooWsender{:04}", i % 300), &text, false, 1_700_000_000_000 + i * 1_000, Some(&"s".repeat(88)), Some(&"p".repeat(60)), Some(&mid), None, None, None, None)
                    .unwrap();
                store.conn.execute("UPDATE channel_messages SET link_preview_json = ?1 WHERE message_id = ?2", params![card, mid]).unwrap();
            }
            store.commit_transaction().unwrap();
            store.wal_checkpoint().unwrap();
        }
        let before = size();
        let (rebuild_ms, release_ms) = {
            let conn = Connection::open(&db).unwrap();
            conn.execute_batch(&format!("PRAGMA key = \"x'{KEY}'\";")).unwrap();
            let started = std::time::Instant::now();
            assert!(MessageStore::rebuild_channel_messages(&conn).unwrap());
            let rebuild_ms = started.elapsed().as_millis();
            let started = std::time::Instant::now();
            release_free_pages(&conn, None);
            (rebuild_ms, started.elapsed().as_millis())
        };
        let store = file_store(tmp.path());
        store.wal_checkpoint().unwrap();
        let rebuilt = size();
        assert!(!has_content_key(&store.conn));
        // `old_channel_db` holds two rows of its own.
        assert_eq!(store.count_all_channel_messages().unwrap() as i64, rows + 2);
        let started = std::time::Instant::now();
        assert_eq!(store.clear_channel_history(i64::MAX).unwrap().messages as i64, rows + 2);
        let clear_ms = started.elapsed().as_millis();
        let cleared = size();
        let pragma = |p: &str| -> i64 { store.conn.query_row(&format!("PRAGMA {p}"), [], |r| r.get(0)).unwrap_or(-1) };
        let report = format!(
            "rows={rows} before={before} rebuilt={rebuilt} (-{:.1}%) rebuild_ms={rebuild_ms} release_ms={release_ms} cleared={cleared} clear_ms={clear_ms} auto_vacuum={} freelist={} pages={}\n",
            100.0 * (before as f64 - rebuilt as f64) / before as f64,
            pragma("auto_vacuum"), pragma("freelist_count"), pragma("page_count"),
        );
        if let Ok(out) = std::env::var("W2C_MEASURE_OUT") {
            std::fs::write(out, report).unwrap();
        }
    }

    /// A copy of the database leaving this device (backup, link snapshot) leaves the
    /// floors behind: the new device syncs the whole history.
    #[test]
    fn w2c_a_device_copy_forgets_the_floors() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let store = file_store(tmp.path());
        post(&store, "ch", "alice", 1_000, "a", "m1");
        store.clear_channel_history(10_000).unwrap();
        store.scrub_device_secrets().unwrap();
        assert_eq!(store.channel_floor("srv", "ch"), None);
        assert_eq!(post(&store, "ch", "alice", 1_000, "a", "m1"), 1, "the copy still refuses the history");
    }
}

// w2-c: the hostile review's cases.
#[cfg(test)]
mod w2c_review_cases {
    use super::*;
    use crate::identity::native_identity::NativeKeypair;

    const KEY: &str = "abababababababababababababababababababababababababababababababab";

    fn file_store(tmp: &std::path::Path, name: &str) -> MessageStore {
        MessageStore::open(tmp.join(name).to_str().unwrap(), KEY).unwrap()
    }

    fn post(store: &MessageStore, sender: &str, ts: i64, text: &str, mid: &str) -> usize {
        store
            .insert_channel_message("srv", "ch", sender, text, false, ts, None, None, Some(mid), None, None, None, None)
            .unwrap()
    }

    fn pk_b64(k: &NativeKeypair) -> String {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD.encode(k.public_key_protobuf())
    }

    /// After a clear, every channel's "last seen" pointer names a row that is gone, and
    /// a missing seen row counts nothing: new posts and mentions stop counting as unread.
    #[test]
    fn w2c_unread_counts_survive_a_clear() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let store = file_store(tmp.path(), "messages.db");
        post(&store, "alice", 1_000, "seen before the clear", "m1");
        store.clear_channel_history(10_000).unwrap();
        post(&store, "alice", 20_000, "new after the clear", "m2");
        post(&store, "bob", 21_000, "@me look", "m3");
        assert_eq!(store.count_unread_channel("srv", "ch", "m1"), 2, "posts after a clear stopped counting as unread");
        let (total, mentions) = store.count_unread_channel_with_mentions("srv", "ch", Some("m1"), &["@me".to_string()]);
        assert_eq!((total, mentions), (2, 1), "posts and mentions after a clear stopped counting");
    }

    /// A page that served a sender this device never held (in full, from its first row)
    /// ends far below the floor; the next page asks EVERY sender from that end, so the
    /// responder re-serves the whole cleared history between there and the floor.
    #[test]
    fn w2c_a_next_page_after_a_clear_never_asks_below_the_floor() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let j = file_store(tmp.path(), "j.db");
        let o = file_store(tmp.path(), "o.db");
        // Xavier's rows sit far below the floor, past any clock's skew.
        let t = 10 * CLEAR_SKEW_MS;
        for (i, ts) in [t + 1_000, t + 2_000, t + 3_000, t + 5_000].into_iter().enumerate() {
            post(&j, "alice", ts, "old", &format!("a{i}"));
            post(&o, "alice", ts, "old", &format!("a{i}"));
        }
        post(&o, "xavier", 100, "never held by J", "x1");
        post(&o, "xavier", 200, "never held by J", "x2");
        j.clear_channel_history(t + 10_000).unwrap();
        assert_eq!(j.channel_floor("srv", "ch"), Some(t + 5_000));

        // O served xavier's old rows (J's ask did not name him); J refused them.
        let served: Vec<crate::node::types::SyncMessageItem> = serde_json::from_value(serde_json::json!([
            { "s": "xavier", "t": "never held by J", "ts": 100, "mid": "x1" },
            { "s": "xavier", "t": "never held by J", "ts": 200, "mid": "x2" },
        ]))
        .unwrap();
        assert_eq!(post(&j, "xavier", 100, "never held by J", "x1"), 0);
        assert_eq!(post(&j, "xavier", 200, "never held by J", "x2"), 0);
        let end = crate::node::sync_handler::ChannelPageEnd::of(&served).unwrap();
        let ask = crate::node::sync_handler::channel_next_page_request(&j, "srv", "ch", end, None);
        let crate::node::types::HavenMessage::ChannelSyncRequest { since_timestamp, sender_timestamps, gap, .. } = ask else {
            panic!("a channel ask")
        };
        let (env, _) = crate::node::sync_handler::build_channel_sync_batch(
            &o, "srv", "ch", since_timestamp, &sender_timestamps, gap.as_ref(), false, None,
        )
        .unwrap();
        let crate::node::types::MessageEnvelope::ChannelSyncBatch { messages, .. } = env else { panic!("a batch") };
        // Only the skew window below the floor comes again, and J refuses it by id.
        assert!(messages.iter().all(|m| m.ts > t + 5_000 - CLEAR_SKEW_MS), "the next page re-served history past the skew; J asked {sender_timestamps:?}");
        assert!(
            messages.iter().all(|m| j.channel_floor_refuses("srv", "ch", m.ts, m.mid.as_deref())),
            "the next page re-served a row J takes",
        );
    }

    /// A cleared item served again (a sender past the cap, an edit on the plain path, an
    /// ask that names nothing) has its row refused, but its reactions still land.
    #[test]
    fn w2c_a_cleared_items_reactions_are_not_stored_again() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let store = file_store(tmp.path(), "messages.db");
        let alice = NativeKeypair::from_secret_bytes(&[11; 32]);
        let bob = NativeKeypair::from_secret_bytes(&[12; 32]);
        let (a, b) = (alice.peer_id(), bob.peer_id());
        let (mid, ts, text) = ("5b1c2f0e-0000-4000-8000-000000000001", 1_000i64, "cleared");
        store
            .insert_channel_message("srv", "ch", &a, text, false, ts, None, None, Some(mid), None, None, Some(ts * 1000), None)
            .unwrap();
        store.clear_channel_history(10_000).unwrap();

        let extras = crate::node::crypto_handler::SignedExtras {
            mid: Some(mid), reply_to: None, file_id: None, order_us: Some(ts * 1000), lp_digest: None, album: None,
        };
        let (sig, pk) = crate::node::crypto_handler::sign_message_versioned(&alice, &pk_b64(&alice), "ch", "srv:ch", &a, ts, &extras, text);
        let (rsig, rpk) = crate::node::crypto_handler::sign_message(&bob, &pk_b64(&bob), &format!("reaction:{mid}:+1:{}", ts + 5));
        let item: crate::node::types::SyncMessageItem = serde_json::from_value(serde_json::json!({
            "s": a, "t": text, "ts": ts, "sig": sig, "pk": pk, "mid": mid, "order_us": ts * 1000,
            "reactions": [{ "e": "+1", "p": b, "ts": ts + 5, "sig": rsig, "pk": rpk }],
        }))
        .unwrap();
        let mut cache = crate::node::crypto_handler::PkCache::new();
        let (inserted, _) = crate::node::sync_handler::ingest_synced_channel_item(&store, "srv", "ch", &item, "local", &mut cache);
        assert_eq!(inserted, 0, "precondition: the floor refused the row");
        let reactions: i64 = store
            .conn
            .query_row("SELECT COUNT(*) FROM message_reactions WHERE message_id = ?1", [mid], |r| r.get(0))
            .unwrap();
        assert_eq!(reactions, 0, "a cleared message's reaction was stored again");
    }

    /// Edits, deletions and reactions are keyed by message id alone; a DM whose id
    /// equals a cleared channel message's (ids are sender-chosen) loses its evidence.
    #[test]
    fn w2c_a_clear_keeps_a_dms_evidence_under_a_shared_id() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let store = file_store(tmp.path(), "messages.db");
        post(&store, "alice", 1_000, "channel post", "shared");
        store.insert("friend", "a dm", false, 1_000, None, None, Some("shared"), None, None, None, None).unwrap();
        store
            .conn
            .execute_batch(
                "INSERT INTO message_edits (message_id, old_text, new_text, edited_at) VALUES ('shared', 'dm before', 'a dm', 1200);
                 INSERT INTO message_deletions (message_id, deleted_text, deleted_at) VALUES ('shared', 'a dm', 1300);
                 INSERT INTO message_reactions (message_id, emoji, peer_id, added_at) VALUES ('shared', '+1', 'friend', 1100);
                 INSERT INTO reaction_removals (message_id, emoji, peer_id, removed_at) VALUES ('shared', '+1', 'friend', 1150);",
            )
            .unwrap();
        store.clear_channel_history(10_000).unwrap();
        let count = |sql: &str| -> i64 { store.conn.query_row(sql, [], |r| r.get(0)).unwrap() };
        assert_eq!(count("SELECT COUNT(*) FROM messages WHERE message_id = 'shared'"), 1);
        for table in ["message_edits", "message_deletions", "message_reactions", "reaction_removals"] {
            assert_eq!(count(&format!("SELECT COUNT(*) FROM {table} WHERE message_id = 'shared'")), 1, "the clear erased a DM's {table}");
        }
    }
}

// w2-c
#[cfg(test)]
mod w2c_floors {
    use super::*;

    const KEY: &str = "abababababababababababababababababababababababababababababababab";
    const T: i64 = 10 * CLEAR_SKEW_MS;

    fn store(tmp: &std::path::Path) -> MessageStore {
        MessageStore::open(tmp.join("messages.db").to_str().unwrap(), KEY).unwrap()
    }

    fn post(store: &MessageStore, sid: &str, ch: &str, ts: i64, mid: Option<&str>) -> usize {
        store.insert_channel_message(sid, ch, "alice", "x", false, ts, None, None, mid, None, None, None, None).unwrap()
    }

    fn count(store: &MessageStore, sql: &str) -> i64 {
        store.conn.query_row(sql, [], |r| r.get(0)).unwrap()
    }

    /// A member whose clock trails ours posts after the clear, stamped just before the
    /// floor: it lands. What the clear took is refused there by its id, and anything
    /// further back than any clock's skew, or without an id, outright.
    #[test]
    fn w2c_a_slow_clocks_post_after_a_clear_lands() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let s = store(tmp.path());
        post(&s, "srv", "ch", T, Some("m1"));
        post(&s, "srv", "ch", T + 1_000, Some("m2"));
        s.clear_channel_history(T + 5_000).unwrap();
        assert_eq!(post(&s, "srv", "ch", T, Some("m1")), 0, "a cleared message came back near the floor");
        assert_eq!(post(&s, "srv", "ch", T + 500, Some("slow")), 1, "a slow clock's new post was refused");
        assert_eq!(post(&s, "srv", "ch", T + 1_000 - CLEAR_SKEW_MS, Some("old")), 0, "history past the skew came in");
        assert_eq!(post(&s, "srv", "ch", T + 1_001 - CLEAR_SKEW_MS, Some("near")), 1);
        assert_eq!(post(&s, "srv", "ch", T + 500, None), 0, "a row without an id came in below the floor");
        assert!(s.channel_floor_refuses("srv", "ch", T + 999_999, Some("m2")), "a cleared id passed above its floor");
        // A second clear takes the slow post too, and still refuses the first one's ids.
        s.clear_channel_history(T + 6_000).unwrap();
        assert_eq!(post(&s, "srv", "ch", T + 500, Some("slow")), 0, "the second clear's history came back");
        assert_eq!(post(&s, "srv", "ch", T, Some("m1")), 0, "the first clear's history came back");
    }

    /// The ids a channel remembers are bounded: past the cap the oldest go, and the
    /// outright refusal moves up over them, so none of them comes back.
    #[test]
    fn w2c_cleared_ids_are_bounded() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let s = store(tmp.path());
        let n = MAX_CLEARED_IDS + 10;
        s.begin_transaction().unwrap();
        for i in 0..n {
            post(&s, "srv", "ch", T + i, Some(&format!("m{i}")));
        }
        s.commit_transaction().unwrap();
        s.clear_channel_history(T + n + 1_000).unwrap();
        assert_eq!(count(&s, "SELECT COUNT(*) FROM channel_cleared_ids"), MAX_CLEARED_IDS);
        for i in [0, 9, 10, n - 1] {
            assert_eq!(post(&s, "srv", "ch", T + i, Some(&format!("m{i}"))), 0, "m{i} came back");
        }
        // A later clear with nothing new never moves the cut back over forgotten ids.
        s.clear_channel_history(T + n + 2_000).unwrap();
        for i in [0, 9] {
            assert_eq!(post(&s, "srv", "ch", T + i, Some(&format!("m{i}"))), 0, "m{i} came back after a second clear");
        }
        assert_eq!(post(&s, "srv", "ch", T + 9, Some("new-at-cut")), 0, "the cut moved down");
        assert_eq!(post(&s, "srv", "ch", T + 10, Some("new-above-cut")), 1, "the cut moved past the remembered ids");
        s.clear_channel_history(T + n + 3_000).unwrap();
        assert!(count(&s, "SELECT COUNT(*) FROM channel_cleared_ids") <= MAX_CLEARED_IDS, "a later clear grew the set past its cap");
    }

    /// A channel holding nothing at the clear (a server still backfilling) is cleared
    /// up to now too; a server's own clear leaves every other server alone.
    #[test]
    fn w2c_a_server_clear_takes_its_empty_channels_and_nothing_else() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let s = store(tmp.path());
        post(&s, "srv", "ch", T, Some("m1"));
        post(&s, "other", "ch", T, Some("o1"));
        let channels = [("srv", "empty"), ("other", "quiet")].map(|(a, b)| (a.to_string(), b.to_string()));
        let now = T + 10 * CLEAR_SKEW_MS;
        assert_eq!(s.clear_history_in(Some("srv"), &channels, now).unwrap().messages, 1);
        assert_eq!(s.channel_floor("srv", "empty"), Some(now));
        assert_eq!(post(&s, "srv", "empty", now - CLEAR_SKEW_MS, Some("backfill")), 0, "an empty channel's history came in");
        assert_eq!(post(&s, "srv", "empty", now - 1_000, Some("slow")), 1);
        assert_eq!((s.channel_floor("other", "ch"), s.channel_floor("other", "quiet")), (None, None), "another server got a floor");
        assert_eq!(count(&s, "SELECT COUNT(*) FROM channel_messages WHERE server_id = 'other'"), 1, "another server was cleared");
    }

    /// A clear cut short (a crash between its batches) finishes later: rows the floors
    /// refuse go, a slow clock's post that landed meanwhile stays.
    #[test]
    fn w2c_an_interrupted_clear_finishes_later() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let s = store(tmp.path());
        post(&s, "srv", "ch", T, Some("m1"));
        post(&s, "srv", "ch", T - 2 * CLEAR_SKEW_MS, Some("m0"));
        s.clear_channel_history(T + 5_000).unwrap();
        // What the batches had still to delete when the process died, put back raw.
        s.conn
            .execute_batch(&format!(
                "INSERT INTO channel_messages (server_id, channel_id, sender_id, text, is_mine, timestamp, message_id)
                 VALUES ('srv', 'ch', 'alice', 'x', 0, {T}, 'm1'), ('srv', 'ch', 'alice', 'x', 0, {}, 'm0'),
                        ('srv', 'ch', 'alice', 'x', 0, {T}, NULL);",
                T - 2 * CLEAR_SKEW_MS,
            ))
            .unwrap();
        assert_eq!(post(&s, "srv", "ch", T - 10, Some("slow")), 1);
        assert_eq!(s.finish_cleared_history().unwrap().messages, 3);
        let left: Vec<String> = {
            let mut stmt = s.conn.prepare("SELECT message_id FROM channel_messages").unwrap();
            stmt.query_map([], |r| r.get(0)).unwrap().map(|r| r.unwrap()).collect()
        };
        assert_eq!(left, vec!["slow".to_string()]);
        assert_eq!(s.finish_cleared_history().unwrap().messages, 0, "a finished clear found more to delete");
    }

    /// A retire's post window is the newest date of what the device proved here. A clear
    /// takes the rows, never the window: it stays as it was, a later post still moves
    /// it, and it goes with the server.
    #[test]
    fn a_cleared_remover_keeps_the_retired_devices_window() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let s = store(tmp.path());
        let proven = |mid: &str, ts: i64, device: &str| {
            s.conn
                .execute(
                    "INSERT INTO channel_messages (server_id, channel_id, sender_id, text, is_mine, timestamp, message_id, dev_device, dev_sig)
                     VALUES ('srv', 'ch', 'master', 'x', 0, ?1, ?2, ?3, 'sig')",
                    params![ts, mid, device],
                )
                .unwrap();
        };
        proven("m1", T, "laptop");
        proven("m0", T - 5_000, "laptop");
        proven("o1", T + 1, "phone");
        assert_eq!(s.newest_post_of_device("srv", "master", "laptop"), Some(T), "control: the window before the clear");
        s.clear_history_in(Some("srv"), &[("srv".to_string(), "ch".to_string())], T + 10 * CLEAR_SKEW_MS).unwrap();
        assert_eq!(count(&s, "SELECT COUNT(*) FROM channel_messages"), 0, "precondition: the clear took the rows");
        assert_eq!(s.newest_post_of_device("srv", "master", "laptop"), Some(T), "a clear lowered the retire window");
        assert_eq!(s.newest_post_of_device("srv", "master", "phone"), Some(T + 1));
        assert_eq!(s.newest_post_of_device("srv", "other", "laptop"), None, "another identity's window");
        assert_eq!(s.newest_post_of_device("other-srv", "master", "laptop"), None, "another server's window");
        // A second clear of an older row keeps the newer date.
        proven("m3", T - 1_000, "laptop");
        s.clear_history_in(Some("srv"), &[], T + 11 * CLEAR_SKEW_MS).unwrap();
        assert_eq!(s.newest_post_of_device("srv", "master", "laptop"), Some(T), "a later clear lowered the window");
        // A reaction under the device's own id counts for it; a post signed as that id does not.
        s.conn
            .execute_batch(&format!(
                "INSERT INTO channel_messages (server_id, channel_id, sender_id, text, is_mine, timestamp, message_id, dev_device, dev_sig)
                 VALUES ('srv', 'ch', 'tablet', 'x', 0, {a}, 'r1', 'tablet', 'sig'), ('srv', 'ch', 'bob', 'x', 0, {b}, 'r2', NULL, NULL);
                 INSERT INTO message_reactions (message_id, emoji, peer_id, added_at, dev) VALUES ('r2', '+1', 'tablet', {b}, '{{\"device\":\"tablet\",\"sig\":\"s\"}}');",
                a = T + 12 * CLEAR_SKEW_MS,
                b = T + 12 * CLEAR_SKEW_MS - 5,
            ))
            .unwrap();
        let tablet = s.newest_post_of_device("srv", "master", "tablet");
        assert_eq!(tablet, Some(T + 12 * CLEAR_SKEW_MS - 5), "control: the reaction counts, the lookalike post does not");
        s.clear_history_in(Some("srv"), &[], T + 13 * CLEAR_SKEW_MS).unwrap();
        assert_eq!(s.newest_post_of_device("srv", "master", "tablet"), tablet, "a clear changed what the device's own id proved");
        proven("m2", T + 20 * CLEAR_SKEW_MS, "laptop");
        assert_eq!(s.newest_post_of_device("srv", "master", "laptop"), Some(T + 20 * CLEAR_SKEW_MS), "a later post moves it");
        s.delete_server_state("srv").unwrap();
        assert_eq!(count(&s, "SELECT COUNT(*) FROM channel_cleared_devices"), 0, "the windows stayed after the server went");
    }

    /// What a clear keeps of the proving devices is bounded: per sender the newest
    /// devices, per server the newest pairs.
    #[test]
    fn cleared_device_windows_stay_bounded() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let s = store(tmp.path());
        let rows = MAX_CLEARED_DEVICE_ROWS + 100;
        let flood_from = rows - MAX_CLEARED_DEVICES - 10;
        let mut sql = String::from("BEGIN;");
        for i in 0..rows {
            let sender = if i >= flood_from { "flood".to_string() } else { format!("s{i}") };
            sql.push_str(&format!(
                "INSERT INTO channel_messages (server_id, channel_id, sender_id, text, is_mine, timestamp, message_id, dev_device, dev_sig)
                 VALUES ('srv', 'ch', '{sender}', 'x', 0, {}, 'm{i}', 'd{i}', 'sig');",
                T + i,
            ));
        }
        sql.push_str("COMMIT;");
        s.conn.execute_batch(&sql).unwrap();
        s.clear_channel_history(T + rows + 10 * CLEAR_SKEW_MS).unwrap();
        assert_eq!(count(&s, "SELECT COUNT(*) FROM channel_cleared_devices WHERE sender_id = 'flood'"), MAX_CLEARED_DEVICES, "one sender's devices");
        assert!(count(&s, "SELECT COUNT(*) FROM channel_cleared_devices") <= MAX_CLEARED_DEVICE_ROWS, "a server's pairs");
        let last = flood_from - 1;
        assert_eq!(s.newest_post_of_device("srv", &format!("s{last}"), &format!("d{last}")), Some(T + last), "another sender's newest pair went");
        assert_eq!(s.newest_post_of_device("srv", "s0", "d0"), None, "the server's oldest pair stayed");
        assert_eq!(s.newest_post_of_device("srv", "flood", &format!("d{flood_from}")), None, "a sender's oldest device stayed");
    }
}

// w2-c round 2
#[cfg(test)]
mod w2c_round2 {
    use super::*;
    use crate::node::channel_asks::Page;
    use crate::node::sync_handler::{build_channel_sync_batch, channel_next_page_request, channel_sync_request, ChannelPageEnd};
    use crate::node::types::{HavenMessage, MessageEnvelope, SyncMessageItem};

    const KEY: &str = "abababababababababababababababababababababababababababababababab";
    const T: i64 = 10 * CLEAR_SKEW_MS;

    fn store(tmp: &std::path::Path, name: &str) -> MessageStore {
        MessageStore::open(tmp.join(name).to_str().unwrap(), KEY).unwrap()
    }

    fn post_in(store: &MessageStore, ch: &str, sender: &str, mid: &str, ts: i64) -> usize {
        store.insert_channel_message("srv", ch, sender, mid, false, ts, None, None, Some(mid), None, None, None, None).unwrap()
    }

    fn post(store: &MessageStore, sender: &str, mid: &str, ts: i64) -> usize {
        post_in(store, "ch", sender, mid, ts)
    }

    fn ask(store: &MessageStore, ch: &str) -> (i64, HashMap<String, i64>, Option<crate::node::types::GapDigest>) {
        let HavenMessage::ChannelSyncRequest { since_timestamp, sender_timestamps, gap, .. } = channel_sync_request(store, "srv", ch, true)
        else {
            panic!("a channel ask")
        };
        (since_timestamp, sender_timestamps, gap)
    }

    fn answer(holder: &MessageStore, since: i64, marks: &HashMap<String, i64>) -> (Page, Vec<SyncMessageItem>) {
        let (env, _) = build_channel_sync_batch(holder, "srv", "ch", since, marks, None, false, None).unwrap();
        let MessageEnvelope::ChannelSyncBatch { messages, has_more, .. } = env else { panic!("a batch") };
        (Page::of(has_more, ChannelPageEnd::of(&messages).as_ref()), messages)
    }

    fn marks(pairs: &[(&str, i64)]) -> HashMap<String, i64> {
        pairs.iter().map(|(s, t)| (s.to_string(), *t)).collect()
    }

    /// A device that cleared its history holds nothing at or below its floor, so an ask
    /// reaching there (a joiner's, a returning member's, one leaving out a sender it
    /// held) is answered as stuck with nothing in it: the asker moves to another holder
    /// instead of ending its catch-up, or following this one past what it cleared.
    #[test]
    fn w2c_a_cleared_holder_never_ends_an_ask_below_its_floor() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let holder = store(tmp.path(), "holder.db");
        for (i, s) in ["alice", "bob", "alice", "bob"].iter().enumerate() {
            post(&holder, s, &format!("old{i}"), T + 1_000 * (i as i64 + 1));
        }
        holder.clear_channel_history(T + 10_000).unwrap();
        let floor = holder.channel_floor("srv", "ch").unwrap();
        assert_eq!(floor, T + 4_000);
        let joiner = store(tmp.path(), "joiner.db");
        let (since, first, _) = ask(&joiner, "ch");
        let stuck_and_empty = |(page, rows): (Page, Vec<SyncMessageItem>)| (page, rows.len());
        assert_eq!(stuck_and_empty(answer(&holder, since, &first)), (Page::Stuck, 0), "a joiner's first ask ended at a cleared holder");

        post(&holder, "carol", "after1", floor + 5_000);
        post(&holder, "carol", "after2", floor + 6_000);
        assert_eq!(stuck_and_empty(answer(&holder, since, &first)), (Page::Stuck, 0), "a cleared holder served its post-clear rows as the channel");
        // A returning member whose watermark sits at or below the floor.
        let back = marks(&[("alice", floor), ("bob", floor + 1), ("carol", floor + 1)]);
        assert_eq!(answer(&holder, 0, &back).0, Page::Stuck, "a returning member's ask ended at a cleared holder");
        // An ask leaving out a sender the holder cleared serves that sender in full.
        let partial = marks(&[("bob", floor + 1), ("carol", floor + 1)]);
        assert_eq!(answer(&holder, 0, &partial).0, Page::Stuck, "an ask leaving out a cleared sender ended");
        // A legacy ask reaching below the floor.
        assert_eq!(answer(&holder, floor - 1, &HashMap::new()).0, Page::Stuck, "a legacy ask below the floor ended");

        // The holder vouches from its oldest row past the floor (AR-39): an ask between
        // the two still reaches below it, so no ask finds where the floor lies.
        let held = holder.channel_held_from("srv", "ch").unwrap();
        assert_eq!(held, floor + 5_000);
        let between = marks(&[("alice", floor + 1), ("bob", floor + 1), ("carol", floor + 1)]);
        assert_eq!(answer(&holder, 0, &between).0, Page::Stuck, "an ask below the holder's oldest row ended");
        // Asks wholly past it are served as usual.
        let past = marks(&[("alice", held), ("bob", held), ("carol", held)]);
        let (page, rows) = answer(&holder, 0, &past);
        assert_eq!((page, rows.len()), (Page::Last, 2), "an ask past the floor was refused");
        let (page, rows) = answer(&holder, held - 1, &HashMap::new());
        assert_eq!((page, rows.len()), (Page::Last, 2), "a legacy ask past the floor was refused");
    }

    /// The floor lets a slow clock's new post land down to `exact_from`, so every sync ask
    /// starts there: per-sender watermarks, the plain watermark, the gap digest and the
    /// next page. The cleared ids in that window are refused again by their hash.
    #[test]
    fn w2c_sync_asks_reach_a_slow_clocks_post_the_floor_accepts() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let us = store(tmp.path(), "us.db");
        post(&us, "alice", "m1", T);
        us.clear_channel_history(T + 5_000).unwrap();
        let exact = T - CLEAR_SKEW_MS;
        let slow_ts = T - 60_000;
        assert!(!us.channel_floor_refuses("srv", "ch", slow_ts, Some("slow")), "precondition: the floor lets the slow post land");

        let responder = store(tmp.path(), "responder.db");
        post(&responder, "alice", "m1", T);
        post(&responder, "alice", "slow", slow_ts);
        let (since, wm, _) = ask(&us, "ch");
        assert_eq!(wm.get("alice"), Some(&(T - SYNC_LOOKBACK_MS)), "a sender is asked from its newest row's lookback, as before the clear");
        let (_, rows) = answer(&responder, since, &wm);
        assert!(rows.iter().any(|m| m.mid.as_deref() == Some("slow")), "sync never serves the slow clock's post");

        // A channel cleared while empty counts nothing: it asks for nothing older than our
        // clock, never naming the floor (a slow clock's post there comes live only).
        let now = T + 10 * CLEAR_SKEW_MS;
        us.clear_history_in(None, &[("srv".to_string(), "empty".to_string())], now).unwrap();
        let (since, wm, gap) = ask(&us, "empty");
        assert!(wm.is_empty() && gap.is_none());
        assert!(since >= crate::node::frame_auth::now_ms() - 60_000, "an empty cleared channel asked for its history: {since}");

        // The gap digest behind a later post counts the cleared row, so the day it shares
        // with the slow clock's post differs and is served; a next page that served a
        // sender from before the oldest row the clear took goes on from that row.
        let day = 24 * 60 * 60 * 1000;
        post(&us, "bob", "later", T + 3 * day);
        let gap = us.channel_gap_anchor("srv", "ch").expect("a digest behind the newest post");
        assert!(gap.from < exact && gap.days.iter().any(|d| d.n == 1), "the digest stops at the floor: {gap:?}");
        let (env, _) = build_channel_sync_batch(&responder, "srv", "ch", T + 3 * day, &HashMap::new(), Some(&gap), true, None).unwrap();
        let MessageEnvelope::ChannelSyncBatch { messages, .. } = env else { panic!("a batch") };
        assert!(messages.iter().any(|m| m.mid.as_deref() == Some("slow")), "the digest never brings the slow clock's post");
        let served: Vec<SyncMessageItem> = serde_json::from_value(serde_json::json!([
            { "s": "xavier", "t": "x", "ts": 100, "mid": "x1" },
            { "s": "xavier", "t": "x", "ts": 200, "mid": "x2" },
        ]))
        .unwrap();
        let HavenMessage::ChannelSyncRequest { since_timestamp, .. } =
            channel_next_page_request(&us, "srv", "ch", ChannelPageEnd::of(&served).unwrap(), None)
        else {
            panic!("a channel ask")
        };
        assert_eq!(since_timestamp, T, "a next page asks again for what the clear took");
    }

    /// A member whose clock runs ahead posted just before the clear: the post is stamped
    /// past our clock and so past the floor, and it goes with the clear all the same.
    /// Its id is refused after, and a post made after the clear still lands.
    #[test]
    fn w2c_a_fast_clocks_post_goes_with_the_clear() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let s = store(tmp.path(), "messages.db");
        let now = T;
        post(&s, "alice", "normal", now - 1_000);
        post(&s, "bob", "fast", now + 60_000);
        let cleared = s.clear_channel_history(now).unwrap();
        assert_eq!(cleared.messages, 2, "the clear left the fast clock's post");
        assert_eq!(s.count_all_channel_messages().unwrap(), 0);
        assert_eq!(s.channel_floor("srv", "ch"), Some(now), "the floor passed our clock");
        assert_eq!(post(&s, "bob", "fast", now + 60_000), 0, "the fast post came back");
        assert_eq!(post(&s, "bob", "next", now + 1), 1, "a post after the clear was refused");
        // The start-up finish takes nothing posted since.
        assert_eq!(s.finish_cleared_history().unwrap().messages, 0);
    }

    /// Posts stamped ahead of our clock cannot move the outright refusal past the floor,
    /// however many there are: a post made after the clear still lands.
    #[test]
    fn w2c_fast_posts_never_move_the_cut_past_the_floor() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let s = store(tmp.path(), "messages.db");
        let now = T;
        s.begin_transaction().unwrap();
        post(&s, "alice", "normal", now - 1_000);
        for i in 0..MAX_CLEARED_IDS + 10 {
            post(&s, "bob", &format!("f{i}"), now + 60_000 + i);
        }
        s.commit_transaction().unwrap();
        s.clear_channel_history(now).unwrap();
        assert_eq!(post(&s, "carol", "after", now + 1), 1, "the flood moved the cut past the floor");
        // A second flood while the first one's ids still sit above the next floor.
        s.begin_transaction().unwrap();
        for i in 0..MAX_CLEARED_IDS + 10 {
            post(&s, "bob", &format!("g{i}"), now + 120_000 + i);
        }
        s.commit_transaction().unwrap();
        s.clear_channel_history(now + 2).unwrap();
        let above: i64 = s.conn.query_row("SELECT COUNT(*) FROM channel_cleared_ids WHERE ts > ?1", [now + 2], |r| r.get(0)).unwrap();
        assert!(above <= MAX_CLEARED_IDS, "the ids above the floor grew past their cap: {above}");
        assert_eq!(post(&s, "carol", "after2", now + 3), 1, "the second flood moved the cut past the floor");
    }

    /// Fast ids take none of the near ids' room: with the near window full, the outright
    /// refusal stays where the near ids alone put it, so a slow clock's new post just
    /// above it still lands.
    #[test]
    fn w2c_fast_ids_never_move_the_cut_over_near_ids() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let s = store(tmp.path(), "messages.db");
        let now = T;
        s.begin_transaction().unwrap();
        for i in 0..MAX_CLEARED_IDS {
            post(&s, "alice", &format!("n{i}"), now - 1 - i);
        }
        for i in 0..10 {
            post(&s, "bob", &format!("f{i}"), now + 60_000 + i);
        }
        s.commit_transaction().unwrap();
        s.clear_channel_history(now).unwrap();
        assert_eq!(post(&s, "carol", "slow", now - MAX_CLEARED_IDS - 5), 1, "fast ids moved the cut over the near ids");
        assert_eq!(post(&s, "alice", "n0", now - 1), 0, "a near id came back");
    }

    fn file_row(s: &MessageStore, fid: &str, ext: &str, mid: &str) {
        s.insert_file_metadata(fid, "a", ext, "image/png", 5, 1, true, None, None, Some(mid), "channel", "srv:ch", "alice", false, 1_000, None, None, None)
            .unwrap();
    }

    /// The names of a clear's files outlive a crash between its batches and the unlink:
    /// they stay until the caller has unlinked them, and the start-up finish hands them
    /// back.
    #[test]
    fn w2c_a_cut_short_clear_still_names_its_files() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        {
            let s = store(tmp.path(), "messages.db");
            post(&s, "alice", "cm1", 1_000);
            post(&s, "alice", "cm2", 2_000);
            file_row(&s, "f1abcdef", "png", "cm1");
            file_row(&s, "f2abcdef", "c++", "cm2");
            let cleared = s.clear_channel_history(10_000).unwrap();
            assert_eq!(cleared.files.len(), 2);
            // The process dies here, before anything is unlinked.
        }
        let s = store(tmp.path(), "messages.db");
        let rest = s.finish_cleared_history().unwrap();
        let mut names = rest.files.clone();
        names.sort();
        let want = [("f1abcdef", "png"), ("f2abcdef", "c++")].map(|(a, b)| (a.to_string(), b.to_string())).to_vec();
        assert_eq!((rest.messages, names), (0, want), "a crash lost a cleared file's name");
        s.forget_cleared_files(&rest.files).unwrap();
        assert!(s.finish_cleared_history().unwrap().files.is_empty(), "an unlinked name was handed back again");
    }

    fn plan(s: &MessageStore, sql: &str) -> Vec<String> {
        let mut stmt = s.conn.prepare(&format!("EXPLAIN QUERY PLAN {sql}")).unwrap();
        let n = stmt.parameter_count();
        stmt.query_map(rusqlite::params_from_iter(std::iter::repeat_n(0i64, n)), |r| r.get::<_, String>(3))
            .unwrap()
            .map(|r| r.unwrap())
            .collect()
    }

    /// Every start runs the finish of a cut-short clear: on a device that never cleared
    /// it reads nothing, and on one that did it walks only the cleared channels, never
    /// the whole message table (no planner statistics on a fresh database).
    #[test]
    fn w2c_a_start_reads_no_channel_rows() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let s = store(tmp.path(), "messages.db");
        post(&s, "alice", "m1", T);
        let rest = s.finish_cleared_history().unwrap();
        assert_eq!((rest.messages, rest.files.len()), (0, 0));
        let staged = count_rows(&s, "SELECT COUNT(*) FROM sqlite_temp_master WHERE name IN ('clear_batch', 'clear_near')");
        assert_eq!(staged, 0, "a start with nothing cleared staged a clear");
        // A name still to unlink is handed back with no floor left to read.
        s.conn.execute("INSERT INTO channel_cleared_files (file_id, file_ext) VALUES ('f1abcdef', 'png')", []).unwrap();
        assert_eq!(s.finish_cleared_history().unwrap().files.len(), 1, "a start skipped a name still to unlink");
        s.forget_cleared_files(&[("f1abcdef".to_string(), "png".to_string())]).unwrap();

        s.clear_channel_history(T + 10_000).unwrap();
        // Every step on the message table seeks one cleared channel: a scan, or a walk of
        // the whole message_id index, reads every row.
        for sql in [CLEAR_BATCH_SELECT, CLEARED_NEAR_SELECT] {
            let steps = plan(&s, sql);
            let walks = |d: &String| (d.starts_with("SCAN m") || d.starts_with("SEARCH m ")) && !d.contains("(server_id=? AND channel_id=?");
            assert!(!steps.iter().any(walks), "a start walks the message table: {steps:?}");
        }
    }

    fn count_rows(s: &MessageStore, sql: &str) -> i64 {
        s.conn.query_row(sql, [], |r| r.get(0)).unwrap()
    }

    /// An ask whose gap digest reaches at or below the floor wants rows this device no
    /// longer holds there, however far past it the watermarks sit.
    #[test]
    fn w2c_a_gap_below_the_floor_is_never_answered_whole() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let holder = store(tmp.path(), "holder.db");
        post(&holder, "alice", "old", T + 1_000);
        holder.clear_channel_history(T + 10_000).unwrap();
        let floor = holder.channel_floor("srv", "ch").unwrap();
        post(&holder, "alice", "after", floor + 5_000);
        let past = marks(&[("alice", floor + 5_000)]);
        let with_gap = |from: i64| {
            let gap = crate::node::types::GapDigest { from, until: floor + 10_000, days: Vec::new() };
            let (env, _) = build_channel_sync_batch(&holder, "srv", "ch", 0, &past, Some(&gap), false, None).unwrap();
            let MessageEnvelope::ChannelSyncBatch { messages, has_more, .. } = env else { panic!("a batch") };
            Page::of(has_more, ChannelPageEnd::of(&messages).as_ref())
        };
        assert_eq!(with_gap(floor), Page::Stuck, "a gap at the floor was answered as complete");
        // The holder vouches from its oldest row past the floor (AR-39).
        assert_eq!(with_gap(floor + 4_999), Page::Stuck, "a gap below the holder's oldest row was answered as complete");
        assert_eq!(with_gap(floor + 5_000), Page::Last, "a gap past the floor was refused");
    }
}

// w3-ar39: a holder lacking part of a channel answers "held from X" (AR-39).
#[cfg(test)]
mod w3_ar39 {
    use super::*;
    use crate::node::channel_asks::Page;
    use crate::node::sync_handler::{build_channel_sync_batch, channel_hole_request, channel_next_page_request, ChannelPageEnd};
    use crate::node::types::{GapDigest, HavenMessage, MessageEnvelope, SyncMessageItem};

    const KEY: &str = "abababababababababababababababababababababababababababababababab";
    const T: i64 = 100 * CLEAR_SKEW_MS;

    fn store(tmp: &std::path::Path, name: &str) -> MessageStore {
        MessageStore::open(tmp.join(name).to_str().unwrap(), KEY).unwrap()
    }

    fn post(store: &MessageStore, sender: &str, mid: &str, ts: i64) {
        store.insert_channel_message("srv", "ch", sender, mid, false, ts, None, None, Some(mid), None, None, Some(ts * 1000), None).unwrap();
    }

    fn marks(pairs: &[(&str, i64)]) -> HashMap<String, i64> {
        pairs.iter().map(|(s, t)| (s.to_string(), *t)).collect()
    }

    fn served(env: &MessageEnvelope) -> (Vec<i64>, Option<bool>, Option<i64>) {
        let MessageEnvelope::ChannelSyncBatch { messages, has_more, held_from, .. } = env else { panic!("a batch") };
        (messages.iter().map(|m| m.ts).collect(), *has_more, *held_from)
    }

    fn answer(holder: &MessageStore, since: i64, marks: &HashMap<String, i64>, gap: Option<&GapDigest>, partial_ok: bool) -> MessageEnvelope {
        build_channel_sync_batch(holder, "srv", "ch", since, marks, gap, partial_ok, None).unwrap().0
    }

    /// A holder that cleared (floor at T + 3000, posts at T + 5000 on).
    fn cleared(tmp: &std::path::Path) -> MessageStore {
        let a = store(tmp, "cleared.db");
        for i in 0..4 {
            post(&a, "alice", &format!("old{i}"), T + 1_000 * (i + 1));
        }
        a.clear_channel_history(T + 10_000).unwrap();
        post(&a, "alice", "p1", T + 5_000);
        post(&a, "bob", "p2", T + 6_000);
        a
    }

    /// A holder whose history begins later: it held nothing when a page vouching from
    /// T + 5000 came in, and a full holder's hole pages since brought older rows before
    /// the ask was cut short.
    fn late(tmp: &std::path::Path) -> MessageStore {
        let j = store(tmp, "late.db");
        j.note_held_page("srv", "ch", T + 5_000, false, &[T + 5_000, T + 6_000], false, T + 20_000).unwrap();
        post(&j, "alice", "p1", T + 5_000);
        post(&j, "bob", "p2", T + 6_000);
        post(&j, "alice", "older", T - 50_000);
        post(&j, "gone", "gone", T - 40_000);
        j.raise_channel_hole("srv", "ch", T - 40_000).unwrap();
        j
    }

    /// The uniformity probe: a device that cleared and one whose history begins later,
    /// holding the same rows from where they vouch, answer every ask byte for byte alike,
    /// though the second holds older rows the first threw away.
    #[test]
    fn ar39_a_cleared_holder_and_a_late_holder_answer_alike() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let (a, j) = (cleared(tmp.path()), late(tmp.path()));
        assert_eq!(a.channel_held_from("srv", "ch"), Some(T + 5_000));
        assert_eq!(j.channel_held_from("srv", "ch"), Some(T + 5_000));
        let gap = GapDigest { from: T - 60_000, until: T + 7_000, days: Vec::new() };
        let asks: Vec<(i64, HashMap<String, i64>, Option<&GapDigest>)> = vec![
            (-1, HashMap::new(), None),
            (T - 60_000, HashMap::new(), None),
            (0, marks(&[("alice", T - 60_000)]), None),
            (0, marks(&[("alice", T + 5_000), ("bob", T + 6_000)]), None),
            (0, marks(&[("alice", T + 5_000)]), None),
            (0, marks(&[("alice", T + 5_000), ("bob", T + 6_000)]), Some(&gap)),
        ];
        for (since, named, gap) in &asks {
            for partial_ok in [true, false] {
                let (ours, theirs) = (answer(&a, *since, named, *gap, partial_ok), answer(&j, *since, named, *gap, partial_ok));
                assert_eq!(serde_json::to_string(&ours).unwrap(), serde_json::to_string(&theirs).unwrap(), "{since} {named:?} {gap:?} {partial_ok}");
                assert!(served(&theirs).0.iter().all(|ts| *ts >= T + 5_000), "a late holder served a row below where it vouches");
            }
        }
    }

    /// A page from a holder lacking part of the channel serves only rows from where it
    /// vouches, and says so whenever the ask reached below there.
    #[test]
    fn ar39_a_partial_page_names_where_it_vouches_from() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let a = cleared(tmp.path());
        let held = Some(T + 5_000);
        assert_eq!(served(&answer(&a, -1, &HashMap::new(), None, true)), (vec![T + 5_000, T + 6_000], None, held), "a joiner's ask");
        assert_eq!(served(&answer(&a, 0, &marks(&[("alice", T)]), None, true)), (vec![T + 5_000, T + 6_000], None, held), "a returner's ask");
        assert_eq!(served(&answer(&a, 0, &marks(&[("alice", T + 5_000)]), None, true)).2, held, "an ask leaving out a sender we hold");
        assert_eq!(served(&answer(&a, 0, &marks(&[("alice", T + 5_000), ("bob", T + 6_000)]), None, true)), (vec![T + 5_000, T + 6_000], None, None), "an ask past it");
        assert_eq!(served(&answer(&a, T + 5_000, &HashMap::new(), None, true)), (vec![T + 6_000], None, None), "a plain ask past it");
        // Holding nothing from where it vouches: nothing, from nowhere.
        let empty = store(tmp.path(), "empty.db");
        post(&empty, "alice", "x", T);
        empty.clear_channel_history(T + 1).unwrap();
        assert_eq!(served(&answer(&empty, -1, &HashMap::new(), None, true)), (vec![], None, Some(i64::MAX)));
        // A full holder says nothing of the kind.
        let full = store(tmp.path(), "full.db");
        post(&full, "alice", "x", T);
        assert_eq!(served(&answer(&full, -1, &HashMap::new(), None, true)), (vec![T], None, None));
    }

    /// An older asker never honours `held_from`, so a holder lacking what it asked for
    /// still answers it no rows and more to come; the new fields never wedge a parse.
    #[test]
    fn ar39_an_older_asker_still_moves_on_from_a_partial_holder() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let (a, j) = (cleared(tmp.path()), late(tmp.path()));
        for holder in [&a, &j] {
            let (rows, more, held) = served(&answer(holder, -1, &HashMap::new(), None, false));
            assert_eq!((rows.len(), Page::of(more, None), held), (0, Page::Stuck, None));
        }
        // An older asker's request parses as one that does not honour it.
        let old = r#"{"type":"ch_sync_req","server_id":"srv","channel_id":"ch","since_timestamp":0}"#;
        let HavenMessage::ChannelSyncRequest { partial_ok, until, .. } = serde_json::from_str(old).unwrap() else { panic!("a request") };
        assert!(!partial_ok && until.is_none());
        // A page without the field is a whole page, and an older peer reads ours.
        let old_page = r#"{"t":"ch_sync","sid":"srv","cid":"ch","messages":[]}"#;
        let MessageEnvelope::ChannelSyncBatch { held_from, .. } = serde_json::from_str(old_page).unwrap() else { panic!("a page") };
        assert_eq!(held_from, None);
        #[derive(serde::Deserialize)]
        #[allow(dead_code)]
        struct OlderPage { sid: String, cid: String, messages: Vec<SyncMessageItem>, #[serde(default)] has_more: Option<bool> }
        let ours = serde_json::to_value(answer(&a, -1, &HashMap::new(), None, true)).unwrap();
        assert!(ours.get("held_from").is_some());
        assert!(serde_json::from_value::<OlderPage>(ours).is_ok(), "an older peer cannot read a partial page");
        #[derive(serde::Deserialize)]
        #[allow(dead_code)]
        struct OlderAsk { server_id: String, channel_id: String, since_timestamp: i64, #[serde(default)] sender_timestamps: HashMap<String, i64> }
        let ask = channel_hole_request(&j, "srv", "ch").expect("the late holder's hole");
        let ask = serde_json::to_value(&ask).unwrap();
        assert!(ask.get("partial_ok").is_some() && ask.get("until").is_some());
        assert!(serde_json::from_value::<OlderAsk>(ask).is_ok(), "an older peer cannot read a hole ask");
    }

    /// The gap digest repair asks a partial holder for days it lacks: the page serves only
    /// what it vouches for and says where that starts.
    #[test]
    fn ar39_a_gap_digest_is_answered_only_from_where_the_holder_vouches() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let (a, j) = (cleared(tmp.path()), late(tmp.path()));
        let past = marks(&[("alice", T + 5_000), ("bob", T + 6_000)]);
        let gap = GapDigest { from: T - 60_000, until: T + 9_000, days: Vec::new() };
        for holder in [&a, &j] {
            let (rows, _, held) = served(&answer(holder, 0, &past, Some(&gap), true));
            assert_eq!((rows, held), (vec![T + 5_000, T + 6_000], Some(T + 5_000)));
        }
        let gap = GapDigest { from: T + 5_000, until: T + 9_000, days: Vec::new() };
        assert_eq!(served(&answer(&a, 0, &past, Some(&gap), true)).2, None, "a digest from where it vouches");
    }

    /// Only a device that held no row of the channel, and never cleared it, opens a hole:
    /// one holding anything keeps vouching for all it holds (a member catching up from a
    /// cleared one included), and gap repair stays the gap digest's job.
    #[test]
    fn ar39_only_a_device_holding_nothing_opens_a_hole() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let k = store(tmp.path(), "k.db");
        post(&k, "alice", "a", T);
        k.note_held_page("srv", "ch", T + 5_000, true, &[T + 5_000, T + 9_000], false, T + 20_000).unwrap();
        assert!(k.channel_hole("srv", "ch").is_none(), "a device holding rows opened a hole");
        assert_eq!(k.channel_held_from("srv", "ch"), None);
        // Holding nothing: everything below the oldest row the page landed.
        let joiner = store(tmp.path(), "joiner.db");
        joiner.note_held_page("srv", "ch", T + 5_000, false, &[T + 7_000, T + 6_000, T + 1_000], false, T + 20_000).unwrap();
        assert_eq!(joiner.channel_hole("srv", "ch"), Some(ChannelHole { below: T + 6_000, from: 0 }), "the oldest row it landed from where the page vouches");
        let empty = store(tmp.path(), "empty.db");
        empty.note_held_page("srv", "ch", i64::MAX, false, &[], false, T + 20_000).unwrap();
        assert_eq!(empty.channel_hole("srv", "ch").map(|h| h.below), Some(T + 20_000));
        assert_eq!(empty.channel_held_from("srv", "ch"), Some(i64::MAX), "a device holding nothing new serves as one lacking it");
        // A cleared device: its floor is its line.
        let cleared = store(tmp.path(), "cleared.db");
        post(&cleared, "alice", "x", T);
        cleared.clear_channel_history(T + 1).unwrap();
        cleared.note_held_page("srv", "ch", T + 5_000, false, &[T + 5_000], false, T + 20_000).unwrap();
        assert!(cleared.channel_hole("srv", "ch").is_none(), "a cleared device opened a hole below its floor");
    }

    /// The ask for a hole names every sender we hold from where the hole starts and stops
    /// at its top; a full holder's answer ends there, and its next page keeps the bound.
    #[test]
    fn ar39_a_hole_is_asked_for_by_itself() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let k = store(tmp.path(), "k.db");
        k.note_held_page("srv", "ch", T + 500_000, false, &[T + 500_000], false, T + 900_000).unwrap();
        post(&k, "alice", "a9", T + 500_000);
        post(&k, "bob", "b9", T + 600_000);
        let Some(HavenMessage::ChannelSyncRequest { since_timestamp, sender_timestamps, gap, partial_ok, until, .. }) = channel_hole_request(&k, "srv", "ch") else {
            panic!("a hole ask")
        };
        assert_eq!((since_timestamp, gap, partial_ok, until), (-1, None, true, Some(T + 500_000)));
        assert_eq!(sender_timestamps, marks(&[("alice", 0), ("bob", 0)]));
        let full = store(tmp.path(), "full.db");
        for i in 0..=250 {
            post(&full, "alice", &format!("f{i}"), T + i * 1_000);
        }
        post(&full, "alice", "top", T + 600_000);
        let (env, _) = build_channel_sync_batch(&full, "srv", "ch", since_timestamp, &sender_timestamps, None, true, until).unwrap();
        let MessageEnvelope::ChannelSyncBatch { messages, has_more, held_from, .. } = env else { panic!("a batch") };
        assert_eq!((messages.len(), Page::of(has_more, ChannelPageEnd::of(&messages).as_ref()), held_from), (200, Page::Next(T + 199_000), None));
        let HavenMessage::ChannelSyncRequest { sender_timestamps, until: next_until, since_timestamp, .. } =
            channel_next_page_request(&k, "srv", "ch", ChannelPageEnd::of(&messages).unwrap(), until)
        else {
            panic!("a next page")
        };
        assert_eq!(next_until, until, "the next page of a hole ask lost its bound");
        assert_eq!(since_timestamp, T + 199_000, "a hole's next page jumped to where we vouch");
        let (env, _) = build_channel_sync_batch(&full, "srv", "ch", since_timestamp, &sender_timestamps, None, true, next_until).unwrap();
        let (rows, more, _) = served(&env);
        assert!(rows.iter().all(|ts| *ts < T + 500_000) && rows.last() == Some(&(T + 250_000)), "{rows:?}");
        assert_eq!(more, None, "the page past the hole's top asked for more");
    }

    /// An answer to the hole's own ask narrows it only to a row it landed; a catch-up page
    /// never moves it, and a page vouching for all of it closes it once its rows are in.
    #[test]
    fn ar39_an_answer_to_the_hole_narrows_it() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let k = store(tmp.path(), "k.db");
        k.note_held_page("srv", "ch", T + 500_000, false, &[T + 500_000], false, T + 900_000).unwrap();
        post(&k, "alice", "a5", T + 500_000);
        k.note_held_page("srv", "ch", T + 400_000, true, &[T + 450_000, T + 420_000], true, T + 900_000).unwrap();
        assert_eq!(k.channel_hole("srv", "ch").map(|h| h.below), Some(T + 420_000), "narrowed to the oldest row it landed");
        k.note_held_page("srv", "ch", T + 100_000, true, &[], true, T + 900_000).unwrap();
        assert_eq!(k.channel_hole("srv", "ch").map(|h| h.below), Some(T + 420_000), "a page landing nothing narrowed it");
        k.note_held_page("srv", "ch", T + 100_000, true, &[T + 150_000], false, T + 900_000).unwrap();
        assert_eq!(k.channel_hole("srv", "ch").map(|h| h.below), Some(T + 420_000), "a catch-up page moved it");
        k.raise_channel_hole("srv", "ch", T + 420_000).unwrap();
        assert!(k.channel_hole("srv", "ch").is_none(), "a hole filled to its top is gone");
        // A page vouching from far ahead of our clock opens no hole past it.
        let j = store(tmp.path(), "j.db");
        j.note_held_page("srv", "ch", T + 90 * DAY_MS, false, &[], false, T + 900_000).unwrap();
        assert_eq!(j.channel_hole("srv", "ch").unwrap().below, T + 900_000 + CLEAR_SKEW_MS);
    }

    /// Where a cleared device vouches from counts the rows its clear took by id ahead of
    /// the floor (a fast clock), never one stamped past the drift.
    #[test]
    fn ar39_a_clear_vouches_past_what_it_took_by_id() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let a = store(tmp.path(), "a.db");
        post(&a, "alice", "old", T);
        post(&a, "fast", "ahead", T + 12_000);
        post(&a, "junk", "far", T + 10 * DAY_MS);
        a.clear_channel_history(T + 10_000).unwrap();
        let floor = a.channel_floor("srv", "ch").unwrap();
        post(&a, "bob", "slow", T + 11_000);
        post(&a, "bob", "after", T + 13_000);
        assert_eq!(a.channel_held_from("srv", "ch"), Some(T + 13_000), "floor {floor}");
    }

    /// A copy of a cleared device's database lacks what the clear took: it asks for it
    /// again and vouches only past it meanwhile; its own holes go with it.
    #[test]
    fn ar39_a_device_copy_keeps_what_it_lacks() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let a = cleared(tmp.path());
        a.scrub_device_secrets().unwrap();
        assert_eq!(a.channel_floor("srv", "ch"), None);
        assert_eq!(a.channel_hole("srv", "ch"), Some(ChannelHole { below: T + 5_000, from: 0 }), "the copy's hole names its oldest row, never the floor");
        assert_eq!(a.channel_held_from("srv", "ch"), Some(T + 5_000));
        assert!(a.channel_history_begins_later("srv", "ch"));
        let j = late(tmp.path());
        j.scrub_device_secrets().unwrap();
        assert!(j.channel_hole("srv", "ch").is_some());
        // A copy holding nothing past the floor asks for everything, bounded by nothing.
        let e = store(tmp.path(), "e.db");
        post(&e, "alice", "x", T);
        e.clear_channel_history(T + 1).unwrap();
        e.scrub_device_secrets().unwrap();
        assert_eq!(e.channel_hole("srv", "ch").map(|h| h.below), Some(i64::MAX));
        let Some(HavenMessage::ChannelSyncRequest { until, since_timestamp, .. }) = channel_hole_request(&e, "srv", "ch") else { panic!("a hole ask") };
        assert_eq!((until, since_timestamp), (None, -1));
    }

    /// `until` ends a full holder's page there, as the last.
    #[test]
    fn ar39_until_ends_the_page() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let full = store(tmp.path(), "full.db");
        for i in 0..5 {
            post(&full, "alice", &format!("m{i}"), T + i * 1_000);
        }
        let (env, _) = build_channel_sync_batch(&full, "srv", "ch", -1, &HashMap::new(), None, true, Some(T + 3_000)).unwrap();
        assert_eq!(served(&env), (vec![T, T + 1_000, T + 2_000], None, None));
        let gap = GapDigest { from: T, until: T + 5_000, days: Vec::new() };
        let (env, _) = build_channel_sync_batch(&full, "srv", "ch", 0, &marks(&[("alice", T + 4_000)]), Some(&gap), true, Some(T + 2_000)).unwrap();
        assert_eq!(served(&env).0, vec![T, T + 1_000], "a gap row past until");
    }

    /// A guest page from a late holder holds nothing below where it vouches, as a
    /// cleared device's holds nothing below its floor.
    #[test]
    fn ar39_a_guest_page_is_cut_where_the_holder_vouches() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let (a, j) = (cleared(tmp.path()), late(tmp.path()));
        let page = |n: &MessageStore| {
            let mut rows = n.get_visible_channel_messages_before("srv", "ch", i64::MAX, 50).unwrap();
            let more = crate::node::sync_handler::guest_page_bounded(n, "srv", "ch", &mut rows, 50);
            (rows.iter().map(|m| m.timestamp).collect::<Vec<_>>(), more)
        };
        assert_eq!(page(&a), page(&j));
        assert_eq!(page(&j), (vec![T + 5_000, T + 6_000], Some(true)));
    }

    /// A full holder's pages of the hole ask fill it from below as they land, so an ask
    /// cut short (a dropped socket, a holder's tenure) never asks for the filled part again.
    #[test]
    fn ar39_pages_filling_a_hole_keep_their_progress() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let j = store(tmp.path(), "j.db");
        j.note_held_page("srv", "ch", i64::MAX, false, &[], false, T + 900_000).unwrap();
        post(&j, "alice", "a9", T + 800_000);
        j.raise_channel_hole("srv", "ch", T + 200_000).unwrap();
        let Some(HavenMessage::ChannelSyncRequest { sender_timestamps, until, .. }) = channel_hole_request(&j, "srv", "ch") else { panic!("a hole ask") };
        assert_eq!((sender_timestamps, until), (marks(&[("alice", T + 200_000)]), Some(T + 900_000)));
        j.raise_channel_hole("srv", "ch", T + 900_000).unwrap();
        assert!(j.channel_hole("srv", "ch").is_none(), "a hole filled to its top is gone");
    }

    fn count_of(store: &MessageStore, sql: &str) -> i64 {
        store.conn_for_test().query_row(sql, [], |r| r.get(0)).unwrap()
    }

    /// What a clear counts stays bounded: the newest senders, the newest rows one by one,
    /// the rest by day, and no day a later ask's digest can never reach.
    #[test]
    fn ar39_cleared_counts_stay_bounded() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let a = store(tmp.path(), "a.db");
        let base = 200 * DAY_MS;
        a.begin_transaction().unwrap();
        post(&a, "ancient", "ancient", base - 100 * DAY_MS);
        for i in 0..5_000 {
            post(&a, &format!("s{i:04}"), &format!("m{i}"), base + i);
        }
        a.commit_transaction().unwrap();
        a.clear_channel_history(base + DAY_MS).unwrap();
        let senders = count_of(&a, "SELECT COUNT(*) FROM channel_cleared_senders");
        let tail = count_of(&a, "SELECT COUNT(*) FROM channel_cleared_tail");
        let folded = count_of(&a, "SELECT COALESCE(SUM(n), 0) FROM channel_cleared_days");
        assert_eq!((senders, tail), (MAX_CLEARED_SENDERS, MAX_CLEARED_TAIL));
        assert_eq!(folded, 5_000 - MAX_CLEARED_TAIL, "the rows past the tail fold into their day, the ancient one goes");
        assert_eq!(count_of(&a, "SELECT MIN(last_ts) FROM channel_cleared_senders"), base + 5_000 - MAX_CLEARED_SENDERS, "the newest senders stay");
        assert_eq!(count_of(&a, "SELECT history_from FROM channel_floors"), base - 100 * DAY_MS);
    }

    /// Holes and what a clear counted are deleted with the server (leave and delete both
    /// reach `delete_server_state`); a clear drops the holes of the channels it floors, and
    /// a copy of the database keeps none of the counts.
    #[test]
    fn ar39_holes_and_cleared_counts_go_with_the_server() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let a = store(tmp.path(), "a.db");
        let put = |sid: &str, cid: &str, mid: &str, ts: i64| {
            a.insert_channel_message(sid, cid, "alice", mid, false, ts, None, None, Some(mid), None, None, Some(ts * 1000), None).unwrap();
        };
        for (sid, cid) in [("srv", "ch"), ("srv", "other"), ("srv2", "ch")] {
            a.note_held_page(sid, cid, T, false, &[T], false, T + 1_000).unwrap();
            put(sid, cid, &format!("{sid}-{cid}"), T);
        }
        assert!(a.channel_hole_open("srv", "ch"), "precondition: holes");
        a.delete_server_state("srv").unwrap();
        assert!(!a.channel_hole_open("srv", "ch") && !a.channel_hole_open("srv", "other"), "a server's holes outlived it");
        assert!(a.channel_hole_open("srv2", "ch"));
        a.clear_history_in(Some("srv2"), &[], T + 2_000).unwrap();
        assert!(!a.channel_hole_open("srv2", "ch"), "a clear kept a hole below its floor");
        put("srv", "ch", "later", T + 5_000);
        a.clear_channel_history(T + 6_000).unwrap();
        let counted = |sid: &str| {
            ["channel_cleared_senders", "channel_cleared_tail"]
                .iter()
                .map(|t| a.conn_for_test().query_row(&format!("SELECT COUNT(*) FROM {t} WHERE server_id = ?1"), [sid], |r| r.get::<_, i64>(0)).unwrap())
                .sum::<i64>()
        };
        assert!(counted("srv") > 0 && counted("srv2") > 0, "precondition: both servers counted");
        a.delete_server_state("srv").unwrap();
        assert_eq!((counted("srv"), counted("srv2") > 0), (0, true), "a server's counts outlived it");
        a.scrub_device_secrets().unwrap();
        assert_eq!(counted("srv2"), 0, "a copy kept what this device cleared");
    }
}
