"""SQLite queue plus explicit LRU. Never use filesystem atime for retention.

All readers take shared flock locks; eviction takes an exclusive nonblocking
lock inside a SQLite write transaction. Process death releases the file lock.
Only UUID-named files in this service's private clips directory are managed.
"""
from contextlib import contextmanager
import fcntl
import json
import logging
import os
from pathlib import Path
import re
import shutil
import sqlite3
import time
import uuid

from .config import Config

LOG = logging.getLogger(__name__)
CLIP_NAME = re.compile(r"^[0-9a-f]{32}(?:\.partial)?\.mp4$")


class StorageFull(RuntimeError):
    pass


class Store:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.root = Path(cfg.storage_dir)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.clips = self.root / "clips"
        self.clips.mkdir(exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(self.root / "index.sqlite3", timeout=15, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("PRAGMA wal_autocheckpoint=100")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS clips (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT UNIQUE NOT NULL,
                started_ns INTEGER NOT NULL,
                duration REAL NOT NULL,
                timing_quality TEXT NOT NULL DEFAULT 'capture_clock',
                bytes INTEGER NOT NULL,
                last_access_ns INTEGER NOT NULL,
                analysis TEXT NOT NULL DEFAULT 'pending',
                upload TEXT NOT NULL DEFAULT 'none',
                decision TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                retry_after REAL NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS lru ON clips(last_access_ns, seq);
            CREATE INDEX IF NOT EXISTS analysis_queue ON clips(analysis, seq);
            CREATE INDEX IF NOT EXISTS upload_queue ON clips(upload, retry_after, seq);
            CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)

    def close(self):
        self.db.close()

    @contextmanager
    def transaction(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
        except BaseException:
            self.db.rollback()
            raise
        else:
            self.db.commit()

    @contextmanager
    def role_lock(self, role: str):
        if role not in ("record", "worker", "upload", "maintenance"):
            raise ValueError("unknown role")
        with (self.root / f"{role}.lock").open("a+b") as f:
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise RuntimeError(f"another {role} process already uses this storage") from exc
            try:
                yield
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)

    def path(self, clip_id: str, partial=False) -> Path:
        if not re.fullmatch(r"[0-9a-f]{32}", clip_id):
            raise ValueError("invalid clip id")
        return self.clips / (clip_id + (".partial.mp4" if partial else ".mp4"))

    def new_partial(self) -> Path:
        return self.path(uuid.uuid4().hex, partial=True)

    def register(self, path: Path, started_ns: int, duration: float):
        clip_id = path.name.split(".")[0]
        if path != self.path(clip_id) or path.is_symlink():
            raise ValueError("not a managed finalized clip")
        self.db.execute("""INSERT OR IGNORE INTO clips
            (id, started_ns, duration, bytes, last_access_ns) VALUES (?,?,?,?,?)""",
            (clip_id, started_ns, duration, path.stat().st_size, started_ns))

    def finalize(self, partial: Path, started_ns: int, duration: float):
        clip_id = partial.name.split(".")[0]
        if partial != self.path(clip_id, partial=True) or partial.is_symlink():
            raise ValueError("not a managed partial clip")
        final = self.path(clip_id)
        with partial.open("rb") as f:
            os.fsync(f.fileno())
        os.replace(partial, final)
        # The rename is durable before publishing to the queue. Startup can
        # recover a completed file if power is lost before the DB insert.
        directory_fd = os.open(self.clips, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        self.register(final, started_ns, duration)
        return clip_id

    def get_state(self, key, default=None):
        row = self.db.execute("SELECT value FROM state WHERE key=?", (key,)).fetchone()
        return json.loads(row[0]) if row else default

    def set_state(self, key, value):
        self.db.execute("INSERT OR REPLACE INTO state VALUES (?,?)", (key, json.dumps(value, allow_nan=False)))

    def increment(self, key):
        self.set_state(key, self.get_state(key, 0) + 1)

    def managed_bytes(self):
        paths = list(self.clips.iterdir()) + list(self.root.glob("index.sqlite3*"))
        total = 0
        for path in paths:
            if path.is_symlink():
                continue
            try:
                if path.is_file():
                    total += path.stat().st_size
            except FileNotFoundError:
                pass
        return total

    def enforce_budget(self):
        """Reserve space for in-progress GOPs/metadata; evict completed LRU.

        Pending uploads are evictable: a finite ring cannot retain an unlimited
        offline queue. Their loss is counted. Currently read/written clips are
        protected. All workers share this same budget, without duplicate media.
        """
        with self.transaction():
            used = self.managed_bytes()
            target = self.cfg.max_bytes - self.cfg.reserve_bytes
            free = shutil.disk_usage(self.root).free
            for row in self.db.execute("SELECT * FROM clips ORDER BY last_access_ns, seq").fetchall():
                if used <= target and free >= self.cfg.min_free_bytes + self.cfg.reserve_bytes:
                    return
                path = self.path(row["id"])
                try:
                    with self._open_regular(path) as f:
                        try:
                            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except BlockingIOError:
                            continue
                        size = os.fstat(f.fileno()).st_size
                        path.unlink()
                        used -= size
                        free = shutil.disk_usage(self.root).free
                except FileNotFoundError:
                    pass
                if row["upload"] == "pending" or row["analysis"] == "pending":
                    self.increment("dropped_unprocessed_or_unsent")
                    LOG.warning("retention evicted undelivered clip %s", row["id"])
                self.db.execute("DELETE FROM clips WHERE id=?", (row["id"],))
        # File deletions cannot be rolled back. Commit their index removals and
        # loss counters even if protected files still prevent enough recovery.
        if used > target or free < self.cfg.min_free_bytes + self.cfg.reserve_bytes:
            raise StorageFull("no unlocked completed clips can satisfy storage budget/free-space reserve")

    @staticmethod
    def _open_regular(path):
        import stat
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            raise ValueError("clip is not a regular file")
        return os.fdopen(fd, "rb")

    @contextmanager
    def lease_next(self, role: str):
        # Selection and flock acquisition are atomic with respect to eviction.
        if role == "worker":
            query, args = "SELECT * FROM clips WHERE analysis='pending' ORDER BY seq LIMIT 1", ()
        elif role == "upload":
            query, args = ("SELECT * FROM clips WHERE upload='pending' AND retry_after<=? ORDER BY seq LIMIT 1", (time.time(),))
        else:
            raise ValueError("invalid queue")
        handle, row = None, None
        with self.transaction():
            row = self.db.execute(query, args).fetchone()
            if row:
                try:
                    handle = self._open_regular(self.path(row["id"]))
                    fcntl.flock(handle, fcntl.LOCK_SH)
                except FileNotFoundError:
                    self.db.execute("DELETE FROM clips WHERE id=?", (row["id"],))
                    self.increment("missing_clips")
                    row = None
        try:
            yield (dict(row), handle) if row else (None, None)
        finally:
            if handle:
                handle.close()

    def touch(self, clip_id):
        with self.transaction():
            if not self.db.execute("SELECT 1 FROM clips WHERE id=?", (clip_id,)).fetchone():
                raise ValueError("clip not found")
            self.db.execute("UPDATE clips SET last_access_ns=? WHERE id=?", (time.time_ns(), clip_id))

    def complete_analysis(self, row, decision, state):
        with self.transaction():
            self.db.execute("UPDATE clips SET analysis='done', decision=?, upload=CASE WHEN ? AND upload!='sent' THEN 'pending' ELSE upload END WHERE id=?",
                (json.dumps(decision, allow_nan=False), decision["send"], row["id"]))
            # Retain one neighboring clip on either side of a proposed trigger.
            if decision["candidate"]:
                previous = self.db.execute("SELECT id FROM clips WHERE seq<? ORDER BY seq DESC LIMIT 1", (row["seq"],)).fetchone()
                if previous:
                    self.db.execute("UPDATE clips SET upload='pending' WHERE id=? AND upload='none'", (previous["id"],))
            self.set_state("selector", state)

    def status(self):
        rows = self.db.execute("SELECT analysis, upload, count(*) AS count FROM clips GROUP BY analysis,upload").fetchall()
        oldest = self.db.execute("SELECT min(started_ns) FROM clips WHERE analysis='pending'").fetchone()[0]
        return {"managed_bytes": self.managed_bytes(), "max_bytes": self.cfg.max_bytes,
                "disk_free_bytes": shutil.disk_usage(self.root).free,
                "queues": [dict(r) for r in rows],
                "dropped_unprocessed_or_unsent": self.get_state("dropped_unprocessed_or_unsent", 0),
                "missing_clips": self.get_state("missing_clips", 0),
                "discarded_partial_clips": self.get_state("discarded_partial_clips", 0),
                "oldest_unanalyzed_age_seconds": max(0, (time.time_ns() - oldest) / 1e9) if oldest else None,
                "recorder": self.get_state("recorder", {}),
                "worker": self.get_state("worker", {}),
                "uploader": self.get_state("uploader", {})}
