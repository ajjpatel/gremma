from http.server import BaseHTTPRequestHandler, HTTPServer
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("upload_video", Path(__file__).resolve().parents[1] / "scripts" / "upload_video.py")
uploader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(uploader)


class UploaderTests(unittest.TestCase):
    def test_public_destinations_rejected_before_connect(self):
        with patch("socket.getaddrinfo", return_value=[(2, 1, 6, "", ("8.8.8.8", 80))]):
            with self.assertRaisesRegex(ValueError, "private"):
                uploader.destination("http://public.example")

    def test_url_credentials_and_paths_rejected(self):
        for url in ("https://192.168.1.2", "http://token@192.168.1.2", "http://192.168.1.2/v1/videos", "http://192.168.1.2?token=secret"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                uploader.destination(url)

    def test_recording_time_requires_timezone(self):
        with self.assertRaises(ValueError):
            uploader.recording_timestamp("2026-10-24T09:00:00")
        self.assertEqual(uploader.recording_timestamp("2026-10-24T09:00:00Z"), "2026-10-24T09:00:00+00:00")

    def test_private_address_rules(self):
        self.assertTrue(uploader.is_private_address("192.168.2.3"))
        self.assertTrue(uploader.is_private_address("fe80::12%eth0"))
        self.assertFalse(uploader.is_private_address("8.8.8.8"))
        self.assertFalse(uploader.is_private_address("192.0.2.10"))

    def test_streamed_body_and_metadata(self):
        observed = {}

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                remaining = int(self.headers["Content-Length"])
                body = bytearray()
                while remaining:
                    chunk = self.rfile.read(min(8192, remaining))
                    body.extend(chunk)
                    remaining -= len(chunk)
                observed.update(body=bytes(body), path=self.path, headers=dict(self.headers))
                payload = json.dumps({"status": "queued", "video_id": "fixture-video"}).encode()
                self.send_response(202)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "clip.mp4"
            body = bytes(range(256)) * 600
            path.write_bytes(body)
            server = HTTPServer(("127.0.0.1", 0), Handler)
            worker = threading.Thread(target=server.handle_request, daemon=True)
            worker.start()
            try:
                result = uploader.upload(path, f"http://127.0.0.1:{server.server_port}",
                                         "2026-10-24T09:00:00-07:00", "Kitchen", "test-only-token")
                self.assertEqual(result["video_id"], "fixture-video")
                self.assertEqual(observed["body"], body)
                self.assertEqual(observed["path"], "/v1/videos")
                self.assertEqual(observed["headers"]["X-Recorded-At"], "2026-10-24T09:00:00-07:00")
                self.assertEqual(observed["headers"]["Authorization"], "Bearer test-only-token")
                self.assertEqual(observed["headers"]["Content-Type"], "video/mp4")
            finally:
                worker.join(timeout=5)
                server.server_close()

    def test_token_newline_rejected_without_network(self):
        with self.assertRaises(ValueError):
            uploader.upload(Path("not-read.mp4"), "http://127.0.0.1", "2026-10-24T09:00:00Z", "Kitchen", "x\r\nInjected")


if __name__ == "__main__":
    unittest.main()
