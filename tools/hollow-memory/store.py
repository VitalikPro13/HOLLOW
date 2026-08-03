import sqlite3
import struct
import sys
import threading
from datetime import datetime, timezone

import numpy as np
import sqlite_vec

from config import DB_PATH, EMBEDDING_DIM

_connection = None
_lock = threading.Lock()


def _serialize_vector(vec: np.ndarray) -> bytes:
    """Serialize a float32 vector to bytes for sqlite-vec."""
    return struct.pack(f"{len(vec)}f", *vec.tolist())


def _get_connection() -> sqlite3.Connection:
    """Get or create a persistent database connection."""
    global _connection
    if _connection is None:
        with _lock:
            if _connection is None:
                conn = sqlite3.connect(str(DB_PATH), check_same_thread=False, timeout=10.0)
                conn.enable_load_extension(True)
                sqlite_vec.load(conn)
                conn.enable_load_extension(False)
                conn.row_factory = sqlite3.Row
                _connection = conn
    return _connection


def init_db():
    """Create tables if they don't exist."""
    conn = _get_connection()
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL,
            heading TEXT NOT NULL,
            chunk_type TEXT NOT NULL,
            name TEXT NOT NULL,
            description TEXT NOT NULL,
            content TEXT NOT NULL,
            content_hash TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
    """)
    # vec0 takes the dimension as DDL syntax, so it cannot be a bound parameter.
    # Force it through int() to guarantee only a literal integer is ever
    # interpolated, whatever EMBEDDING_DIM is configured to.
    dim = int(EMBEDDING_DIM)
    conn.execute(f"""
        CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(
            embedding float[{dim}]
        )
    """)
    conn.commit()


def upsert_chunks(chunks: list[dict], embeddings: np.ndarray):
    """Incremental update: insert new, skip unchanged, delete removed."""
    conn = _get_connection()

    existing = {row[0]: row[1] for row in conn.execute("SELECT content_hash, id FROM chunks").fetchall()}
    new_hashes = {c["content_hash"] for c in chunks}

    # Delete chunks that no longer exist
    removed_hashes = set(existing.keys()) - new_hashes
    if removed_hashes:
        for h in removed_hashes:
            rid = existing[h]
            conn.execute("DELETE FROM chunks WHERE id = ?", (rid,))
            conn.execute("DELETE FROM vec_chunks WHERE rowid = ?", (rid,))

    # Insert new/changed chunks
    inserted = 0
    for i, chunk in enumerate(chunks):
        if chunk["content_hash"] in existing:
            continue

        cursor = conn.execute(
            "INSERT INTO chunks (source, heading, chunk_type, name, description, content, content_hash) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (chunk["source"], chunk["heading"], chunk["chunk_type"], chunk["name"], chunk["description"], chunk["content"], chunk["content_hash"]),
        )
        rowid = cursor.lastrowid
        vec_bytes = _serialize_vector(embeddings[i])
        conn.execute("INSERT INTO vec_chunks (rowid, embedding) VALUES (?, ?)", (rowid, vec_bytes))
        inserted += 1

    now = datetime.now(timezone.utc).isoformat()
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('last_indexed', ?)", (now,))
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('chunk_count', ?)", (str(len(chunks)),))

    conn.commit()
    return {"inserted": inserted, "removed": len(removed_hashes), "unchanged": len(chunks) - inserted}


def rebuild(chunks: list[dict], embeddings: np.ndarray):
    """Full rebuild: drop all data and re-insert."""
    conn = _get_connection()
    conn.execute("DELETE FROM chunks")
    conn.execute("DELETE FROM vec_chunks")

    for i, chunk in enumerate(chunks):
        cursor = conn.execute(
            "INSERT INTO chunks (source, heading, chunk_type, name, description, content, content_hash) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (chunk["source"], chunk["heading"], chunk["chunk_type"], chunk["name"], chunk["description"], chunk["content"], chunk["content_hash"]),
        )
        rowid = cursor.lastrowid
        vec_bytes = _serialize_vector(embeddings[i])
        conn.execute("INSERT INTO vec_chunks (rowid, embedding) VALUES (?, ?)", (rowid, vec_bytes))

    now = datetime.now(timezone.utc).isoformat()
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('last_indexed', ?)", (now,))
    conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('chunk_count', ?)", (str(len(chunks)),))

    conn.commit()


def search(query_embedding: np.ndarray, limit: int = 5) -> list[dict]:
    """Search for similar chunks. Returns list of dicts with metadata + distance."""
    conn = _get_connection()
    vec_bytes = _serialize_vector(query_embedding)

    rows = conn.execute("""
        SELECT v.rowid, v.distance, c.source, c.heading, c.chunk_type, c.name, c.description, c.content
        FROM vec_chunks v
        JOIN chunks c ON c.id = v.rowid
        WHERE v.embedding MATCH ? AND k = ?
        ORDER BY v.distance
    """, (vec_bytes, limit)).fetchall()

    return [
        {
            "id": row["rowid"],
            "distance": row["distance"],
            "source": row["source"],
            "heading": row["heading"],
            "chunk_type": row["chunk_type"],
            "name": row["name"],
            "description": row["description"],
            "content": row["content"],
        }
        for row in rows
    ]


def get_stats() -> dict:
    """Get index statistics."""
    conn = _get_connection()

    total = conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]

    type_counts = {}
    for row in conn.execute("SELECT chunk_type, COUNT(*) as cnt FROM chunks GROUP BY chunk_type"):
        type_counts[row["chunk_type"]] = row["cnt"]

    last_indexed = None
    row = conn.execute("SELECT value FROM meta WHERE key = 'last_indexed'").fetchone()
    if row:
        last_indexed = row["value"]

    return {
        "total_chunks": total,
        "by_type": type_counts,
        "last_indexed": last_indexed,
        "db_path": str(DB_PATH),
    }
