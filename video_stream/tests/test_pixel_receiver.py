"""Contract tests against the actual Java receiver used by the Pixel app.

The clip-upload workflow compiles it and supplies GREMMA_RECEIVER_CLASSPATH.
All uploads are synthetic bytes on loopback; no camera or model downloads.
"""
from dataclasses import replace
from datetime import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import select
import ssl
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid

from gremma_video.config import Config
from gremma_video.storage import Store
from gremma_video.upload import check_upload, send_clip, upload_one


@unittest.skipUnless(os.environ.get("GREMMA_RECEIVER_CLASSPATH"), "actual Pixel receiver is compiled in clip-upload CI")
class PixelReceiverTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cert_dir = tempfile.TemporaryDirectory()
        cls.keys = Path(cls.cert_dir.name) / "receiver.p12"
        subprocess.run(["keytool", "-genkeypair", "-alias", "receiver", "-keyalg", "EC",
                        "-groupname", "secp256r1", "-dname", "CN=Gremma test", "-validity", "2",
                        "-keystore", str(cls.keys), "-storetype", "PKCS12", "-storepass", "test-password"],
                       check=True, capture_output=True, timeout=30)
        der = subprocess.check_output(["keytool", "-exportcert", "-alias", "receiver",
                                       "-keystore", str(cls.keys), "-storepass", "test-password"], timeout=30)
        cls.pin = hashlib.sha256(der).hexdigest()

    @classmethod
    def tearDownClass(cls):
        cls.cert_dir.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = (self.root / "receiver.log").open("w")
        self.addCleanup(self.log.close)
        self.start_receiver()
        self.addCleanup(self.stop_receiver)
        self.token = patch.dict(os.environ, {"GREMMA_UPLOAD_TOKEN": "test-token-0123456789abcdef0123456789abcdef"})
        self.token.start()
        self.addCleanup(self.token.stop)
        self.cfg = Config(storage_dir=str(self.root / "sender"), upload_url=f"https://127.0.0.1:{self.port}/v1/clips",
                          upload_cert_sha256=self.pin, upload_timeout_seconds=5)
        self.clip_id = uuid.uuid4().hex
        self.payload = b"\x00\x00\x00\x18ftypmp42" + os.urandom(128_000)
        self.row = {"id": self.clip_id, "bytes": len(self.payload)}
        self.meta = {"schema_version": 1, "clip_id": self.clip_id, "device_id": "oracle-01",
                     "size_bytes": len(self.payload), "sha256": hashlib.sha256(self.payload).hexdigest(),
                     "started_at": "2026-10-24T12:34:56.123+00:00", "duration_seconds": 30.0,
                     "selection": {"send": True, "reasons": ["endpoint_change"]}}

    def start_receiver(self):
        self.process = subprocess.Popen(["java", "-cp", os.environ["GREMMA_RECEIVER_CLASSPATH"],
                                         "ReceiverHarness", str(self.root), str(self.keys)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)
        if not select.select([self.process.stdout], [], [], 20)[0]:
            self.stop_receiver()
            self.fail("receiver did not start")
        line = self.process.stdout.readline().decode().strip()
        self.assertTrue(line.startswith("READY:"), (self.root / "receiver.log").read_text())
        self.port = int(line.split(":")[1])

    def stop_receiver(self):
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        if self.process.stdout:
            self.process.stdout.close()

    def send(self, meta=None, payload=None):
        send_clip(self.cfg, self.row, io.BytesIO(self.payload if payload is None else payload), meta or self.meta)

    def saved(self):
        return list((self.root / "inbox").glob("*/metadata.json"))

    def test_health_and_real_multipart_upload_preserve_bytes_metadata_and_capture_time(self):
        self.assertTrue(check_upload(self.cfg)["receiver_ready"])
        self.send()
        path = self.saved()[0]
        self.assertEqual(json.loads(path.read_text()), self.meta)
        video = path.parent / "video.mp4"
        self.assertEqual(video.read_bytes(), self.payload)
        self.assertAlmostEqual(video.stat().st_mtime, datetime.fromisoformat(self.meta["started_at"]).timestamp(), places=2)
        self.assertEqual(list((self.root / "inbox").glob(".receiving-*")), [])

    def test_duplicate_after_receiver_restart_is_not_requeued(self):
        self.send()
        original = self.saved()[0].stat().st_mtime_ns
        self.stop_receiver()
        self.start_receiver()
        self.cfg = replace(self.cfg, upload_url=f"https://127.0.0.1:{self.port}/v1/clips")
        self.send()
        self.assertEqual(len(self.saved()), 1)
        self.assertEqual(self.saved()[0].stat().st_mtime_ns, original)

    def test_lost_ack_is_retried_without_duplicate_video(self):
        store = Store(self.cfg)
        self.addCleanup(store.close)
        part = store.new_partial()
        part.write_bytes(self.payload)
        store.finalize(part, 1_790_000_000_000_000_000, 30)
        store.db.execute("UPDATE clips SET analysis='done',upload='pending'")

        def lost_ack(*args):
            send_clip(*args)
            raise ConnectionResetError("simulated loss after receiver commit")

        upload_one(store, sender=lost_ack)
        self.assertEqual(store.db.execute("SELECT upload FROM clips").fetchone()[0], "pending")
        store.db.execute("UPDATE clips SET retry_after=0")
        upload_one(store)
        self.assertEqual(store.db.execute("SELECT upload FROM clips").fetchone()[0], "sent")
        self.assertEqual(len(self.saved()), 1)

    def test_checksum_mismatch_is_not_published(self):
        with self.assertRaisesRegex(RuntimeError, "422"):
            self.send(payload=b"x" * len(self.payload))
        self.assertEqual(self.saved(), [])

    def test_existing_id_cannot_be_overwritten(self):
        self.send()
        changed = b"x" * len(self.payload)
        with self.assertRaisesRegex(RuntimeError, "409"):
            self.send(meta={**self.meta, "sha256": hashlib.sha256(changed).hexdigest()}, payload=changed)
        self.assertEqual((self.saved()[0].parent / "video.mp4").read_bytes(), self.payload)

    def test_unpaired_certificate_sends_nothing(self):
        self.cfg = replace(self.cfg, upload_cert_sha256="0" * 64)
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.send()
        self.assertEqual(self.saved(), [])

    def test_wrong_token_and_path_traversal_do_not_publish(self):
        with patch.dict(os.environ, {"GREMMA_UPLOAD_TOKEN": "wrong"}):
            with self.assertRaises((RuntimeError, OSError)):
                self.send()
        with self.assertRaisesRegex(RuntimeError, "400"):
            self.send(meta={**self.meta, "device_id": "../../escape"})
        self.assertEqual(self.saved(), [])
