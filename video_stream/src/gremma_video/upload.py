"""Optional HTTPS push; same clip ID is reused on every retry.

The receiver must persist atomically and acknowledge this ID. A 2xx alone does
not acknowledge a clip. No raw footage is sent unless upload_url is configured.
"""
from datetime import datetime, timezone
import hashlib
import http.client
import json
import logging
import os
import signal
import ssl
import threading
import time
from urllib.parse import urlsplit
import uuid

from .config import Config
from .storage import Store

LOG = logging.getLogger(__name__)


def metadata(store, row, digest):
    return {"schema_version": 1, "clip_id": row["id"], "device_id": store.cfg.device_id,
            "started_at": datetime.fromtimestamp(row["started_ns"] / 1e9, timezone.utc).isoformat(),
            "duration_seconds": row["duration"], "timing_quality": row["timing_quality"],
            "size_bytes": row["bytes"], "sha256": digest,
            "selection": json.loads(row["decision"]) if row["decision"] else {"reasons": ["analysis_unavailable"]}}


def send_clip(cfg, row, handle, meta):
    token = os.environ.get(cfg.upload_token_env, "")
    if not token or any(c in token for c in "\r\n"):
        raise ValueError("upload bearer token is missing or invalid")
    boundary = uuid.uuid4().hex
    prefix = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"metadata\"\r\n"
              "Content-Type: application/json\r\n\r\n").encode() + json.dumps(meta).encode()
    prefix += (f"\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"video\"; "
               f"filename=\"{row['id']}.mp4\"\r\nContent-Type: video/mp4\r\n\r\n").encode()
    suffix = f"\r\n--{boundary}--\r\n".encode()
    url = urlsplit(cfg.upload_url)
    context = ssl.create_default_context(cafile=cfg.upload_ca_file or None)
    conn = http.client.HTTPSConnection(url.hostname, url.port or 443,
                                     timeout=cfg.upload_timeout_seconds, context=context)
    deadline = time.monotonic() + cfg.upload_timeout_seconds

    def remaining():
        value = deadline - time.monotonic()
        if value <= 0:
            raise TimeoutError("clip upload deadline exceeded")
        if conn.sock:
            conn.sock.settimeout(value)

    try:
        # No redirect following: credentials and video stay on the chosen host.
        target = url.path or "/"
        if url.query:
            target += "?" + url.query
        conn.putrequest("POST", target)
        conn.putheader("Authorization", f"Bearer {token}")
        conn.putheader("Idempotency-Key", f"{cfg.device_id}:{row['id']}")
        conn.putheader("Content-Type", f"multipart/form-data; boundary={boundary}")
        conn.putheader("Content-Length", str(len(prefix) + row["bytes"] + len(suffix)))
        conn.endheaders()
        remaining()
        conn.send(prefix)
        handle.seek(0)
        while block := handle.read(256 * 1024):
            remaining()
            conn.send(block)
        remaining()
        conn.send(suffix)
        response = conn.getresponse()
        remaining()
        body = response.read(65537)
        if not 200 <= response.status < 300 or len(body) > 65536:
            raise RuntimeError(f"receiver did not acknowledge clip: HTTP {response.status}")
        result = json.loads(body)
        if result.get("clip_id") != row["id"] or result.get("stored") is not True:
            raise RuntimeError("receiver acknowledgement does not match clip")
    finally:
        conn.close()


def upload_one(store, sender=send_clip):
    with store.lease_next("upload") as (row, handle):
        if row is None:
            return False
        try:
            digest = hashlib.file_digest(handle, "sha256").hexdigest()
            sender(store.cfg, row, handle, metadata(store, row, digest))
        except Exception as exc:
            # Bound the exponent even after months offline.
            delay = min(300, 2 ** min(row["attempts"] + 1, 9))
            store.db.execute("UPDATE clips SET attempts=attempts+1,retry_after=? WHERE id=?",
                             (time.time() + delay, row["id"]))
            LOG.warning("upload retry %s in %ss (%s)", row["id"], delay, type(exc).__name__)
        else:
            store.db.execute("UPDATE clips SET upload='sent' WHERE id=?", (row["id"],))
            store.set_state("uploader", {"last_clip_id": row["id"], "acknowledged_at_ns": time.time_ns()})
            LOG.info("receiver acknowledged %s", row["id"])
        return True


def upload(cfg: Config, once=False):
    if not cfg.upload_url:
        raise ValueError("upload_url is not configured; clips remain queued locally")
    store = Store(cfg)
    stop = threading.Event()
    handlers = {}
    for sig in (signal.SIGTERM, signal.SIGINT):
        handlers[sig] = signal.signal(sig, lambda *_: stop.set())
    try:
        with store.role_lock("upload"):
            while not stop.is_set():
                worked = upload_one(store)
                if once:
                    break
                if not worked:
                    stop.wait(1)
    finally:
        store.close()
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
