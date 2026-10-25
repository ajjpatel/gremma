from dataclasses import replace
import json
import math
import multiprocessing
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
import uuid

from gremma_video.capture import recover
from gremma_video.config import Config, load_config
from gremma_video.selection import decide, normalize
from gremma_video.storage import Store, StorageFull
from gremma_video.upload import send_clip, upload_one
from gremma_video.worker import Embedder, process_one


def endpoints(first=(1, 0), last=(1, 0)):
    return {"first_embedding": first, "last_embedding": last,
            "frames": {"decoded_frames": 900, "first_frame_seconds": 0,
                       "last_frame_seconds": 29.9666666667}}


def hang_embedding(connection):
    time.sleep(60)


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.cfg = Config(storage_dir=self.temp.name, max_bytes=20_000_000,
                          reserve_bytes=2_000_000, max_segment_bytes=1_000_000,
                          min_free_bytes=0)
        self.store = Store(self.cfg)
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.store.close)

    def clip(self, started=1, size=200_000):
        partial = self.store.new_partial()
        partial.write_bytes(b"x" * size)
        return self.store.finalize(partial, started, 5.0)

    def pressure(self, remove_bytes=1):
        self.store.cfg = replace(self.cfg, max_bytes=self.store.managed_bytes() + self.cfg.reserve_bytes - remove_bytes)

    def test_lru_is_explicit_and_survives_reopen(self):
        first, second, third = self.clip(1), self.clip(2), self.clip(3)
        self.store.touch(first)
        other = Store(self.cfg)
        self.addCleanup(other.close)
        self.assertGreater(other.db.execute("SELECT last_access_ns FROM clips WHERE id=?", (first,)).fetchone()[0], 3)
        self.pressure()
        self.store.enforce_budget()
        self.assertTrue(self.store.path(first).exists())
        self.assertFalse(self.store.path(second).exists())
        self.assertTrue(self.store.path(third).exists())

    def test_reading_for_analysis_does_not_refresh_lru(self):
        clip_id = self.clip(10)
        with self.store.lease_next("worker") as (row, handle):
            self.assertEqual(row["id"], clip_id)
            handle.read(10)
        self.assertEqual(self.store.db.execute("SELECT last_access_ns FROM clips").fetchone()[0], 10)

    def test_leased_clip_survives_eviction_by_other_connection(self):
        first, second = self.clip(1), self.clip(2)
        other = Store(self.cfg)
        self.addCleanup(other.close)
        self.pressure()
        other.cfg = self.store.cfg
        with self.store.lease_next("worker"):
            other.enforce_budget()
            self.assertTrue(self.store.path(first).exists())
            self.assertFalse(self.store.path(second).exists())

    def test_only_pinned_clip_means_pressure_not_unsafe_delete(self):
        clip_id = self.clip()
        self.pressure()
        with self.store.lease_next("worker"):
            with self.assertRaises(StorageFull):
                self.store.enforce_budget()
        self.assertTrue(self.store.path(clip_id).exists())

    def test_partial_eviction_commits_before_unresolved_pressure_error(self):
        pinned, evicted = self.clip(1), self.clip(2)
        self.pressure(remove_bytes=300_000)
        with self.store.lease_next("worker"):
            with self.assertRaises(StorageFull):
                self.store.enforce_budget()
        self.assertTrue(self.store.path(pinned).exists())
        self.assertFalse(self.store.path(evicted).exists())
        self.assertIsNone(self.store.db.execute("SELECT id FROM clips WHERE id=?", (evicted,)).fetchone())
        self.assertEqual(self.store.get_state("dropped_unprocessed_or_unsent"), 1)

    def test_active_partial_is_counted_and_never_evicted(self):
        old = self.clip()
        active = self.store.new_partial()
        active.write_bytes(b"a" * 100_000)
        self.pressure()
        self.store.enforce_budget()
        self.assertTrue(active.exists())
        self.assertFalse(self.store.path(old).exists())

    def test_pending_queue_eviction_is_counted(self):
        clip_id = self.clip()
        self.store.db.execute("UPDATE clips SET analysis='done',upload='pending'")
        self.pressure()
        self.store.enforce_budget()
        self.assertFalse(self.store.path(clip_id).exists())
        self.assertEqual(self.store.get_state("dropped_unprocessed_or_unsent"), 1)

    def test_disk_pressure_evicts_even_below_media_budget(self):
        clip_id = self.clip()
        usage = Mock(free=0)
        with patch("gremma_video.storage.shutil.disk_usage", return_value=usage):
            with self.assertRaises(StorageFull):
                self.store.enforce_budget()
        self.assertFalse(self.store.path(clip_id).exists())

        self.assertEqual(self.store.db.execute("SELECT count(*) FROM clips").fetchone()[0], 0)
        self.assertEqual(self.store.get_state("dropped_unprocessed_or_unsent"), 1)

    def test_unknown_files_are_counted_but_never_deleted(self):
        unrelated = self.store.clips / "family.mp4"
        unrelated.write_bytes(b"do not delete")
        self.pressure()
        with self.assertRaises(StorageFull):
            self.store.enforce_budget()
        self.assertTrue(unrelated.exists())

    def test_role_lock_prevents_two_recorders(self):
        other = Store(self.cfg)
        self.addCleanup(other.close)
        with self.store.role_lock("record"):
            with self.assertRaises(RuntimeError):
                with other.role_lock("record"):
                    self.fail("second recorder acquired lock")

    def test_path_traversal_and_symlink_rejected(self):
        with self.assertRaises(ValueError):
            self.store.path("../../other")
        outside = Path(self.temp.name) / "outside.mp4"
        outside.write_bytes(b"untouched")
        path = self.store.path(uuid.uuid4().hex)
        path.symlink_to(outside)
        with self.assertRaises(ValueError):
            self.store.register(path, 0, 1)
        self.assertEqual(outside.read_bytes(), b"untouched")

    def test_recovery_orphans_and_corrupt_tail(self):
        completed = self.store.path(uuid.uuid4().hex)
        completed.write_bytes(b"valid")
        partial = self.store.new_partial()
        partial.write_bytes(b"valid")
        broken = self.store.new_partial()
        broken.write_bytes(b"truncated")
        unrelated = self.store.clips / "unrelated.mp4"
        unrelated.write_bytes(b"keep")

        def fake_probe(path, _cfg):
            if path == broken:
                raise subprocess.CalledProcessError(1, "ffprobe")
            return 5.0

        with patch("gremma_video.capture.probe", side_effect=fake_probe):
            recover(self.store)
        self.assertEqual(self.store.db.execute("SELECT count(*) FROM clips").fetchone()[0], 2)
        self.assertFalse(broken.exists())
        self.assertFalse(partial.exists())
        self.assertTrue(unrelated.exists())
        self.assertEqual(self.store.get_state("discarded_partial_clips"), 1)
        self.assertEqual(self.store.db.execute("SELECT timing_quality FROM clips").fetchone()[0], "recovered_estimate")

    def test_missing_probe_does_not_destroy_orphans(self):
        partial = self.store.new_partial()
        partial.write_bytes(b"possibly valid")
        with patch("gremma_video.capture.probe", side_effect=FileNotFoundError):
            with self.assertRaises(FileNotFoundError):
                recover(self.store)
        self.assertTrue(partial.exists())

    def test_probe_timeout_does_not_destroy_orphans(self):
        partial = self.store.new_partial()
        partial.write_bytes(b"possibly valid")
        with patch("gremma_video.capture.probe", side_effect=subprocess.TimeoutExpired("ffprobe", 15)):
            with self.assertRaises(subprocess.TimeoutExpired):
                recover(self.store)
        self.assertTrue(partial.exists())

    def test_missing_queue_file_is_accounted(self):
        clip_id = self.clip()
        self.store.path(clip_id).unlink()
        with self.store.lease_next("worker") as (row, handle):
            self.assertIsNone(row)
            self.assertIsNone(handle)
        self.assertEqual(self.store.get_state("missing_clips"), 1)

    def test_worker_error_fails_open_and_queue_is_durable(self):
        self.clip()
        model = Mock()
        model.encode.side_effect = TimeoutError()
        self.assertTrue(process_one(self.store, model))
        other = Store(self.cfg)
        self.addCleanup(other.close)
        row = other.db.execute("SELECT * FROM clips").fetchone()
        self.assertEqual(row["upload"], "pending")
        self.assertIn("analysis_unavailable", json.loads(row["decision"])["reasons"])
        self.assertFalse(process_one(self.store, model))

    def test_only_changed_clip_is_queued_across_restart(self):
        first, second, third = [self.clip(n * 30_000_000_000) for n in range(1, 4)]
        model = Mock()
        model.encode.return_value = endpoints()
        process_one(self.store, model)
        model.encode.return_value = endpoints(last=(0, 1))
        process_one(self.store, model)
        other = Store(self.cfg)
        self.addCleanup(other.close)
        model.encode.return_value = endpoints(first=(0, 1), last=(0, 1))
        process_one(other, model)
        statuses = dict(other.db.execute("SELECT id,upload FROM clips"))
        self.assertEqual(statuses, {first: "none", second: "pending", third: "none"})
        self.assertEqual([c.args[0].name for c in model.encode.call_args_list],
                         [f"{clip_id}.mp4" for clip_id in (first, second, third)])

    def test_invalid_endpoint_output_is_preserved_for_upload(self):
        self.clip()
        model = Mock()
        model.encode.return_value = endpoints(last=(math.nan, 0))
        process_one(self.store, model)
        row = self.store.db.execute("SELECT * FROM clips").fetchone()
        self.assertEqual(row["upload"], "pending")
        self.assertEqual(json.loads(row["decision"])["error"], "ValueError")

    def test_analysis_cutoff_leaves_older_queue_entries_reversible(self):
        old, new = self.clip(1), self.clip(2)
        self.store.cfg = replace(self.cfg, analysis_start_seq=2)
        with self.store.lease_next("worker") as (row, _):
            self.assertEqual(row["id"], new)
        self.assertEqual(self.store.status()["pending_before_start_seq"], 1)
        self.store.cfg = self.cfg
        with self.store.lease_next("worker") as (row, _):
            self.assertEqual(row["id"], old)

    def test_upload_retries_and_acknowledges_without_deleting(self):
        clip_id = self.clip()
        self.store.db.execute("UPDATE clips SET upload='pending'")
        sender = Mock(side_effect=OSError("offline"))
        upload_one(self.store, sender)
        row = self.store.db.execute("SELECT * FROM clips").fetchone()
        self.assertEqual(row["upload"], "pending")
        self.assertEqual(row["attempts"], 1)
        self.assertGreater(row["retry_after"], time.time())
        self.assertFalse(upload_one(self.store, sender))
        self.store.db.execute("UPDATE clips SET retry_after=0")
        sender.side_effect = None
        upload_one(self.store, sender)
        self.assertEqual(self.store.db.execute("SELECT upload FROM clips").fetchone()[0], "sent")
        self.assertTrue(self.store.path(clip_id).exists())
        self.assertEqual(sender.call_args.args[3]["clip_id"], clip_id)
        self.assertEqual(len(sender.call_args.args[3]["sha256"]), 64)

    def test_late_analysis_does_not_requeue_an_acknowledged_clip(self):
        self.clip()
        self.store.db.execute("UPDATE clips SET upload='sent'")
        model = Mock()
        model.encode.return_value = endpoints(last=(0, 1))
        process_one(self.store, model)
        self.assertEqual(self.store.db.execute("SELECT upload FROM clips").fetchone()[0], "sent")

    def test_bad_ack_never_counts_as_delivered(self):
        clip_id = self.clip()
        self.store.db.execute("UPDATE clips SET upload='pending'")
        self.store.cfg = replace(self.cfg, upload_url="https://receiver.local/clips")
        conn = Mock()
        response = Mock(status=200)
        response.read.return_value = b'{"stored": true, "clip_id": "wrong"}'
        conn.getresponse.return_value = response
        with patch.dict("os.environ", {"GREMMA_UPLOAD_TOKEN": "test"}), patch(
                "gremma_video.upload.http.client.HTTPSConnection", return_value=conn):
            upload_one(self.store)
        self.assertEqual(self.store.db.execute("SELECT upload FROM clips").fetchone()[0], "pending")
        self.assertTrue(self.store.path(clip_id).exists())

    def test_streamed_upload_body_length_and_matching_ack(self):
        clip_id = self.clip()
        self.store.db.execute("UPDATE clips SET upload='pending'")
        self.store.cfg = replace(self.cfg, upload_url="https://receiver.local/clips")
        conn = Mock()
        response = Mock(status=201)
        response.read.return_value = json.dumps({"stored": True, "clip_id": clip_id}).encode()
        conn.getresponse.return_value = response
        with patch.dict("os.environ", {"GREMMA_UPLOAD_TOKEN": "test"}), patch(
                "gremma_video.upload.http.client.HTTPSConnection", return_value=conn):
            upload_one(self.store)
        headers = dict(call.args for call in conn.putheader.call_args_list)
        sent = b"".join(call.args[0] for call in conn.send.call_args_list)
        self.assertEqual(len(sent), int(headers["Content-Length"]))
        self.assertIn(b'"clip_id": "' + clip_id.encode() + b'"', sent)
        self.assertEqual(self.store.db.execute("SELECT upload FROM clips").fetchone()[0], "sent")


class SelectionTest(unittest.TestCase):
    def setUp(self):
        self.cfg = Config()

    def test_identical_endpoints_are_skipped_immediately(self):
        decision = decide(self.cfg, endpoints())
        self.assertFalse(decision["send"])
        self.assertEqual(decision["cosine_distance"], 0)
        self.assertEqual(decision["reasons"], ["endpoints_similar"])

    def test_changed_endpoints_are_selected(self):
        decision = decide(self.cfg, endpoints(last=(0, 1)))
        self.assertTrue(decision["send"])
        self.assertEqual(decision["cosine_distance"], 1)
        self.assertEqual(decision["reasons"], ["endpoint_change"])
        self.assertAlmostEqual(decision["frames"]["last_frame_seconds"], 29.9666666667)

    def test_comparison_is_independent_of_previous_clip(self):
        decide(self.cfg, endpoints(last=(0, 1)))
        decision = decide(self.cfg, endpoints(first=(0, 1), last=(0, 1)))
        self.assertFalse(decision["send"])

    def test_vectors_are_normalized_before_comparison(self):
        decision = decide(self.cfg, endpoints(first=(2, 0), last=(100, 0)))
        self.assertFalse(decision["send"])

    def test_distance_must_exceed_threshold(self):
        decision = decide(replace(self.cfg, difference_threshold=1), endpoints(last=(0, 1)))
        self.assertFalse(decision["send"])

    def test_invalid_embeddings_rejected(self):
        for vector in ([], [0, 0], [math.nan], [math.inf]):
            with self.subTest(vector=vector), self.assertRaises(ValueError):
                normalize(vector)
        with self.assertRaises(ValueError):
            decide(self.cfg, endpoints(last=(1, 0, 0)))

    def test_analysis_failure_does_not_claim_unchanged(self):
        decision = decide(self.cfg, error="TimeoutError")
        self.assertIn("analysis_unavailable", decision["reasons"])
        self.assertTrue(decision["send"])
        self.assertIsNone(decision["cosine_distance"])


class ConfigTest(unittest.TestCase):
    def test_invalid_storage_or_threshold_rejected(self):
        for overrides in ({"max_bytes": 1}, {"segment_seconds": 0},
                          {"reserve_bytes": 1}, {"difference_threshold": math.nan},
                          {"difference_threshold": 2}):
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                Config(**overrides)

    def test_upload_requires_https_and_no_embedded_credentials(self):
        for url in ("http://phone/clips", "https://user:pass@phone/clips", "ftp://phone/clips"):
            with self.assertRaises(ValueError):
                Config(upload_url=url)

    def test_relative_paths_follow_config_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            path.write_text('storage_dir="clips"\nmodel_path="weights"\n')
            cfg = load_config(str(path))
            self.assertEqual(cfg.storage_dir, str(Path(directory).resolve() / "clips"))
            self.assertEqual(cfg.model_path, str(Path(directory).resolve() / "weights"))

    def test_missing_model_fails_without_download(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = Embedder(Config(model_path=str(Path(directory) / "missing")))
            with self.assertRaises(FileNotFoundError):
                runner.encode(Path("clip.mp4"))
            self.assertIsNone(runner.process)

    def test_inference_timeout_terminates_child(self):
        context = multiprocessing.get_context("spawn")
        parent, child = context.Pipe()
        process = context.Process(target=hang_embedding, args=(child,), daemon=True)
        process.start()
        child.close()
        runner = Embedder(Config(inference_timeout_seconds=1))
        runner.process, runner.connection = process, parent
        try:
            with self.assertRaises(TimeoutError):
                runner.encode(Path("test.mp4"))
            self.assertFalse(process.is_alive())
            self.assertIsNone(runner.process)
        finally:
            runner.close()


if __name__ == "__main__":
    unittest.main()
