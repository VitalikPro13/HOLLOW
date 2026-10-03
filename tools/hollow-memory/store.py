import re
import sqlite3
import threading
from datetime import datetime, timezone

import numpy as np
import sqlite_vec

from config import DB_PATH, EMBEDDING_DIM, MODEL_ID

CORPORA = ("docs", "code")
_connection = None
_lock = threading.Lock()
_STOPWORDS = {"the", "a", "an", "of", "to", "in", "is", "and", "or", "for", "on", "with", "what", "how", "why",
              "does", "do", "we", "it", "that", "this", "who", "which", "can", "be", "by", "from", "at", "are",
              "not", "into", "its", "where", "when", "our", "us"}


def _conn() -> sqlite3.Connection:
    global _connection
    with _lock:
        if _connection is None:
            # Two sessions run two servers on this file; WAL keeps readers off the writer's lock.
            conn = sqlite3.connect(str(DB_PATH), check_same_thread=False, timeout=300.0, isolation_level=None)
            conn.enable_load_extension(True)
            sqlite_vec.load(conn)
            conn.enable_load_extension(False)
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA journal_mode=WAL")
            _connection = conn
    return _connection


def init_db():
    conn = _conn()
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            corpus TEXT NOT NULL, source TEXT NOT NULL, kind TEXT NOT NULL, heading TEXT NOT NULL,
            start_line INTEGER NOT NULL, end_line INTEGER NOT NULL,
            content TEXT NOT NULL, content_hash TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS chunks_by_source ON chunks(corpus, source);
        CREATE TABLE IF NOT EXISTS files (
            corpus TEXT NOT NULL, source TEXT NOT NULL, mtime_ns INTEGER NOT NULL, size INTEGER NOT NULL,
            PRIMARY KEY (corpus, source)
        );
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    """)
    dim = int(EMBEDDING_DIM)  # vec0 takes the dimension as DDL, never a bound parameter
    for corpus in CORPORA:
        conn.execute(f"CREATE VIRTUAL TABLE IF NOT EXISTS vec_{corpus} USING vec0(embedding float[{dim}])")
        conn.execute(f"CREATE VIRTUAL TABLE IF NOT EXISTS fts_{corpus} USING fts5(content, tokenize=\"unicode61 tokenchars '_'\")")
    row = conn.execute("SELECT value FROM meta WHERE key = 'model'").fetchone()
    if row and row["value"] != f"{MODEL_ID}:{dim}":
        clear_all()
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('model', ?)", (f"{MODEL_ID}:{dim}",))


def clear_all():
    conn = _conn()
    conn.execute("DELETE FROM chunks")
    conn.execute("DELETE FROM files")
    for corpus in CORPORA:
        conn.execute(f"DELETE FROM vec_{corpus}")
        conn.execute(f"DELETE FROM fts_{corpus}")


def _vec(v: np.ndarray) -> bytes:
    return np.asarray(v, dtype=np.float32).tobytes()


def refresh(corpus: str, list_files, chunk_file, embed, budget: int | None = None) -> dict:
    """Re-chunk files whose mtime or size moved and embed only chunks not already stored.

    With a budget, stops after that many new chunks; untouched files stay stale for the next call.
    """
    assert corpus in CORPORA
    conn = _conn()
    current = {}
    for path, source, kind in list_files():
        try:
            st = path.stat()
        except OSError:
            continue
        current[source] = (path, kind, st.st_mtime_ns, st.st_size)
    conn.execute("BEGIN IMMEDIATE")
    try:
        known = {r["source"]: (r["mtime_ns"], r["size"]) for r in
                 conn.execute("SELECT source, mtime_ns, size FROM files WHERE corpus = ?", (corpus,))}
        removed = [s for s in known if s not in current]
        changed = [s for s, (_, _, m, z) in current.items() if known.get(s) != (m, z)]
        for source in removed:
            _delete_source(conn, corpus, source)
        embedded = done = 0
        pending = []
        for source in changed:
            if budget is not None and embedded >= budget:
                break
            path, kind, mtime, size = current[source]
            try:
                chunks = chunk_file(path, source, kind)
            except OSError:
                continue
            seen = set()
            chunks = [c for c in chunks if not (c["content_hash"] in seen or seen.add(c["content_hash"]))]
            wanted = {c["content_hash"] for c in chunks}
            have, stale = {}, []
            for r in conn.execute("SELECT id, content_hash FROM chunks WHERE corpus = ? AND source = ?", (corpus, source)):
                if r["content_hash"] in wanted and r["content_hash"] not in have:
                    have[r["content_hash"]] = r["id"]
                else:
                    stale.append(r["id"])
            _delete_ids(conn, corpus, stale)
            fresh = [c for c in chunks if c["content_hash"] not in have]
            # Unchanged chunks keep their row but take the file's new line numbers.
            for c in chunks:
                if c["content_hash"] in have:
                    conn.execute("UPDATE chunks SET start_line = ?, end_line = ?, heading = ? WHERE id = ?",
                                 (c["start_line"], c["end_line"], c["heading"], have[c["content_hash"]]))
            pending.append((source, mtime, size, fresh))
            embedded += len(fresh)
        texts = [c["content"] for _, _, _, fresh in pending for c in fresh]
        vectors = embed(texts) if texts else np.zeros((0, EMBEDDING_DIM), dtype=np.float32)
        i = 0
        for source, mtime, size, fresh in pending:
            for c in fresh:
                cur = conn.execute(
                    "INSERT INTO chunks (corpus, source, kind, heading, start_line, end_line, content, content_hash)"
                    " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    (corpus, source, c["kind"], c["heading"], c["start_line"], c["end_line"], c["content"], c["content_hash"]))
                conn.execute(f"INSERT INTO vec_{corpus} (rowid, embedding) VALUES (?, ?)", (cur.lastrowid, _vec(vectors[i])))
                conn.execute(f"INSERT INTO fts_{corpus} (rowid, content) VALUES (?, ?)", (cur.lastrowid, c["content"]))
                i += 1
            conn.execute("INSERT OR REPLACE INTO files (corpus, source, mtime_ns, size) VALUES (?, ?, ?, ?)",
                         (corpus, source, mtime, size))
            done += 1
        conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                     (f"last_indexed_{corpus}", datetime.now(timezone.utc).isoformat(timespec="seconds")))
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    return {"files_updated": done, "files_removed": len(removed), "chunks_embedded": len(texts),
            "files_pending": len(changed) - done}


def _delete_ids(conn, corpus, ids):
    for rid in ids:
        conn.execute("DELETE FROM chunks WHERE id = ?", (rid,))
        conn.execute(f"DELETE FROM vec_{corpus} WHERE rowid = ?", (rid,))
        conn.execute(f"DELETE FROM fts_{corpus} WHERE rowid = ?", (rid,))


def _delete_source(conn, corpus, source):
    ids = [r["id"] for r in conn.execute("SELECT id FROM chunks WHERE corpus = ? AND source = ?", (corpus, source))]
    _delete_ids(conn, corpus, ids)
    conn.execute("DELETE FROM files WHERE corpus = ? AND source = ?", (corpus, source))


def _fts_query(query: str) -> str:
    """OR of the query's words; an identifier like HOL-SEC-079 or a::b becomes one phrase."""
    terms = []
    for word in query.split():
        parts = [p.lower() for p in re.findall(r"[A-Za-z0-9_]+", word)]
        parts = [p for p in parts if len(parts) > 1 or (p not in _STOPWORDS and len(p) > 1)]
        if parts:
            terms.append('"' + " ".join(parts) + '"')
    return " OR ".join(terms)


def looks_like_identifier(query: str) -> bool:
    return bool(re.search(r"\w_\w|[a-z][A-Z]|::|\w\(|[A-Z]{2,}-\d", query))


def search(corpus: str, query_vec: np.ndarray, query: str, limit: int, lex_weight: float = 1.0,
           pool: int = 50) -> list[dict]:
    """Reciprocal rank fusion of vector and BM25 rankings; lex_weight 0 is vector-only."""
    conn = _conn()
    scores = {}
    rows = conn.execute(f"SELECT rowid FROM vec_{corpus} WHERE embedding MATCH ? AND k = ? ORDER BY distance",
                        (_vec(query_vec), pool)).fetchall()
    for rank, r in enumerate(rows):
        scores[r["rowid"]] = scores.get(r["rowid"], 0.0) + 1.0 / (60 + rank)
    fts = _fts_query(query) if lex_weight else ""
    if fts:
        rows = conn.execute(f"SELECT rowid FROM fts_{corpus} WHERE fts_{corpus} MATCH ? ORDER BY bm25(fts_{corpus}) LIMIT ?",
                            (fts, pool)).fetchall()
        for rank, r in enumerate(rows):
            scores[r["rowid"]] = scores.get(r["rowid"], 0.0) + lex_weight / (60 + rank)
    best = sorted(scores, key=lambda k: -scores[k])[:limit]
    out = []
    for rid in best:
        r = conn.execute("SELECT * FROM chunks WHERE id = ?", (rid,)).fetchone()
        if r:
            out.append({**dict(r), "score": scores[rid]})
    return out


def get_stats() -> dict:
    conn = _conn()
    by = {f"{r['corpus']}/{r['kind']}": r["n"] for r in
          conn.execute("SELECT corpus, kind, COUNT(*) AS n FROM chunks GROUP BY corpus, kind ORDER BY corpus, kind")}
    files = {r["corpus"]: r["n"] for r in conn.execute("SELECT corpus, COUNT(*) AS n FROM files GROUP BY corpus")}
    meta = {r["key"]: r["value"] for r in conn.execute("SELECT key, value FROM meta")}
    return {"by_kind": by, "files": files, "meta": meta, "db_path": str(DB_PATH)}
