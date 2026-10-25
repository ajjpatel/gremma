"""Opt-in real media test: RUN_GSTREAMER_SMOKE=1 on a Linux GStreamer host."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from gremma_video.config import load_config
from gremma_video.media import endpoint_images, probe
from gremma_video.storage import Store


@unittest.skipUnless(os.environ.get("RUN_GSTREAMER_SMOKE") == "1", "requires Linux GStreamer, GI, FFmpeg")
class GStreamerSmokeTest(unittest.TestCase):
    def test_continuous_recording_eos_and_playable_segments(self):
        with tempfile.TemporaryDirectory() as directory:
            cfg_path = Path(directory) / "config.toml"
            cfg_path.write_text('''
storage_dir = "data"
max_bytes = 128000000
reserve_bytes = 16000000
max_segment_bytes = 8000000
min_free_bytes = 0
segment_seconds = 2
source = "videotestsrc is-live=true pattern=ball ! video/x-raw,width=320,height=240,framerate=15/1"
encoder = "x264enc tune=zerolatency speed-preset=ultrafast bitrate=400 key-int-max=15"
''')
            log = Path(directory) / "record.log"
            with log.open("w") as output:
                process = subprocess.Popen([sys.executable, "-m", "gremma_video", "--config", str(cfg_path), "record"],
                                           stdout=output, stderr=output)
                try:
                    time.sleep(9)
                    process.send_signal(signal.SIGTERM)
                    returncode = process.wait(timeout=20)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
            self.assertEqual(returncode, 0, log.read_text())
            cfg = load_config(str(cfg_path))
            store = Store(cfg)
            try:
                rows = store.db.execute("SELECT * FROM clips ORDER BY seq").fetchall()
                self.assertGreaterEqual(len(rows), 3, log.read_text())
                durations = [probe(store.path(row["id"]), cfg) for row in rows]
                self.assertGreater(sum(durations), 6)
                self.assertTrue(all(0 < value <= 3 for value in durations))
                images, frames = endpoint_images(store.path(rows[0]["id"]))
                self.assertEqual(len(images), 2)
                self.assertGreater(frames["decoded_frames"], 1)
                self.assertGreater(frames["last_frame_seconds"], frames["first_frame_seconds"])
                self.assertFalse(list(store.clips.glob("*.partial.mp4")))
            finally:
                store.close()

    def test_endpoints_are_first_and_final_decoded_frames(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "red-then-blue.mp4"
            subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
                            "color=c=red:s=64x48:r=10:d=1", "-f", "lavfi", "-i",
                            "color=c=blue:s=64x48:r=10:d=1", "-filter_complex",
                            "[0:v][1:v]concat=n=2:v=1:a=0[v]", "-map", "[v]",
                            "-c:v", "libx264", "-pix_fmt", "yuv420p", str(path)],
                           check=True, capture_output=True, timeout=20)
            images, frames = endpoint_images(path)
            self.assertEqual(frames["decoded_frames"], 20)
            self.assertAlmostEqual(frames["first_frame_seconds"], 0)
            self.assertAlmostEqual(frames["last_frame_seconds"], 1.9)
            first, last = [image.getpixel((10, 10)) for image in images]
            self.assertGreater(first[0], 240)
            self.assertLess(first[2], 15)
            self.assertGreater(last[2], 240)
            self.assertLess(last[0], 15)
