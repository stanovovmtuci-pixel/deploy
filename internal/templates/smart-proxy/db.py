import sqlite3
import time
import threading

DB_PATH = None
_lock = threading.Lock()

def init(path):
    global DB_PATH
    DB_PATH = path
    conn = _conn()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS domains (
            domain      TEXT PRIMARY KEY,
            decision    TEXT NOT NULL,
            source      TEXT NOT NULL,
            block_type  TEXT,
            last_checked INTEGER NOT NULL,
            tcp_time    REAL,
            tls_time    REAL,
            http_status INTEGER,
            redirect_url TEXT,
            notes       TEXT
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS manual_overrides (
            domain      TEXT PRIMARY KEY,
            decision    TEXT NOT NULL,
            added_at    INTEGER NOT NULL,
            reason      TEXT
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_decision ON domains(decision)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_source ON domains(source)")
    conn.commit()
    conn.close()

def _conn():
    return sqlite3.connect(DB_PATH, check_same_thread=False)

def get_manual(domain):
    with _lock:
        conn = _conn()
        row = conn.execute(
            "SELECT decision, reason FROM manual_overrides WHERE domain=?",
            (domain,)
        ).fetchone()
        conn.close()
    if row:
        return {"decision": row[0], "reason": row[1]}
    return None

def get(domain):
    with _lock:
        conn = _conn()
        row = conn.execute(
            "SELECT decision, source, block_type, tcp_time, tls_time, http_status, redirect_url, notes FROM domains WHERE domain=?",
            (domain,)
        ).fetchone()
        conn.close()
    if row:
        return {
            "decision": row[0], "source": row[1], "block_type": row[2],
            "tcp_time": row[3], "tls_time": row[4], "http_status": row[5],
            "redirect_url": row[6], "notes": row[7]
        }
    return None

def save(domain, decision, source, block_type=None, tcp_time=None,
         tls_time=None, http_status=None, redirect_url=None, notes=None):
    with _lock:
        conn = _conn()
        conn.execute("""
            INSERT OR REPLACE INTO domains
            (domain, decision, source, block_type, last_checked, tcp_time, tls_time, http_status, redirect_url, notes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (domain, decision, source, block_type, int(time.time()),
              tcp_time, tls_time, http_status, redirect_url, notes))
        conn.commit()
        conn.close()

def save_manual(domain, decision, reason=None):
    with _lock:
        conn = _conn()
        conn.execute("""
            INSERT OR REPLACE INTO manual_overrides (domain, decision, added_at, reason)
            VALUES (?, ?, ?, ?)
        """, (domain, decision, int(time.time()), reason))
        conn.commit()
        conn.close()

def remove_manual(domain):
    with _lock:
        conn = _conn()
        deleted = conn.execute(
            "DELETE FROM manual_overrides WHERE domain=?", (domain,)
        ).rowcount
        conn.commit()
        conn.close()
    return deleted > 0

def delete_cached(domain):
    with _lock:
        conn = _conn()
        deleted = conn.execute(
            "DELETE FROM domains WHERE domain=?", (domain,)
        ).rowcount
        conn.commit()
        conn.close()
    return deleted > 0

def load_all():
    with _lock:
        conn = _conn()
        rows = conn.execute(
            "SELECT domain, decision, source, block_type FROM domains"
        ).fetchall()
        manuals = conn.execute(
            "SELECT domain, decision FROM manual_overrides"
        ).fetchall()
        conn.close()
    result = {row[0]: {"decision": row[1], "source": row[2], "block_type": row[3]} for row in rows}
    for row in manuals:
        result[row[0]] = {"decision": row[1], "source": "manual", "block_type": None}
    return result

def stats():
    with _lock:
        conn = _conn()
        rows = conn.execute(
            "SELECT decision, COUNT(*) FROM domains GROUP BY decision"
        ).fetchall()
        manual_count = conn.execute(
            "SELECT COUNT(*) FROM manual_overrides"
        ).fetchone()[0]
        total = conn.execute("SELECT COUNT(*) FROM domains").fetchone()[0]
        conn.close()
    s = {row[0]: row[1] for row in rows}
    s["manual"] = manual_count
    s["total"] = total
    return s

def list_manual():
    with _lock:
        conn = _conn()
        rows = conn.execute(
            "SELECT domain, decision, added_at, reason FROM manual_overrides ORDER BY added_at DESC"
        ).fetchall()
        conn.close()
    return [{"domain": r[0], "decision": r[1], "added_at": r[2], "reason": r[3]} for r in rows]

def list_by_source(source):
    with _lock:
        conn = _conn()
        rows = conn.execute(
            "SELECT domain, decision, block_type, last_checked FROM domains WHERE source=? ORDER BY domain",
            (source,)
        ).fetchall()
        conn.close()
    return [{"domain": r[0], "decision": r[1], "block_type": r[2], "last_checked": r[3]} for r in rows]
