import argparse
import importlib.util
import json
import logging
import os
from pathlib import Path
import shutil
import subprocess
import time

from .config import load_config
from .storage import Store


def doctor(cfg):
    """Read-only environment report; never installs packages or opens a camera."""
    import platform
    result = {"platform": platform.platform(), "machine": platform.machine(),
              "model_path_exists": Path(cfg.model_path).is_dir(),
              "gi_available": importlib.util.find_spec("gi") is not None,
              "sentence_transformers_available": importlib.util.find_spec("sentence_transformers") is not None,
              "binaries": {p: shutil.which(p) for p in (cfg.ffmpeg, cfg.ffprobe, "gst-inspect-1.0")},
              "source": cfg.source, "encoder": cfg.encoder, "upload_configured": bool(cfg.upload_url)}
    commands = {"os_release": ["cat", "/etc/os-release"],
                "qcom_packages": ["dpkg-query", "-W", "gstreamer1.0-plugins-qcom"],
                "camera_source": ["gst-inspect-1.0", "qtiqmmfsrc"],
                "hardware_encoder": ["gst-inspect-1.0", "v4l2h264enc"],
                "h264_parser": ["gst-inspect-1.0", "h264parse"],
                "mp4_muxer": ["gst-inspect-1.0", "mp4mux"],
                "segmenter": ["gst-inspect-1.0", "splitmuxsink"]}
    for name, command in commands.items():
        try:
            run = subprocess.run(command, capture_output=True, text=True, timeout=10)
            result[name] = {"returncode": run.returncode, "output": (run.stdout + run.stderr)[-12000:]}
        except (OSError, subprocess.TimeoutExpired) as exc:
            result[name] = {"error": str(exc)}
    return result


def ingest(store, source):
    """Import a local test clip through the same atomic publication path."""
    from .media import probe
    source = Path(source).resolve()
    duration = probe(source, store.cfg)
    if source.stat().st_size > store.cfg.max_segment_bytes:
        raise ValueError("input exceeds max_segment_bytes; split it first")
    with store.role_lock("record"):
        store.enforce_budget()
        partial = store.new_partial()
        try:
            shutil.copyfile(source, partial)
            clip_id = store.finalize(partial, time.time_ns() - int(duration * 1e9), duration)
            store.db.execute("UPDATE clips SET timing_quality='import_time' WHERE id=?", (clip_id,))
            return clip_id
        finally:
            partial.unlink(missing_ok=True)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description="Gremma board camera pipeline")
    parser.add_argument("--config", required=True, help="TOML configuration file")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("record", "worker", "upload", "status", "doctor", "prune", "recover", "list"):
        command = sub.add_parser(name)
        if name in ("worker", "upload"):
            command.add_argument("--once", action="store_true")
    sub.add_parser("ingest").add_argument("path")
    sub.add_parser("check-model").add_argument("path", help="local short MP4 for actual embedding inference")
    sub.add_parser("touch").add_argument("clip_id")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    cfg = load_config(args.config)
    if args.command == "doctor":
        print(json.dumps(doctor(cfg), indent=2))
        return
    if args.command == "check-model":
        from .media import motion_score, probe
        from .selection import normalize
        from .worker import Embedder
        path = Path(args.path).resolve()
        duration = probe(path, cfg)
        model = Embedder(cfg)
        started = time.monotonic()
        try:
            vector = normalize(model.encode(path))
            print(json.dumps({"duration_seconds": duration, "dimensions": len(vector),
                              "inference_seconds_including_load": time.monotonic() - started,
                              "motion_fraction": motion_score(path, cfg),
                              "model_revision": cfg.model_revision}, indent=2))
        finally:
            model.close()
        return
    if args.command == "record":
        from .capture import record
        record(cfg)
        return
    if args.command == "worker":
        from .worker import worker
        worker(cfg, args.once)
        return
    if args.command == "upload":
        from .upload import upload
        upload(cfg, args.once)
        return
    store = Store(cfg)
    try:
        if args.command == "status":
            print(json.dumps(store.status(), indent=2))
        elif args.command == "list":
            print(json.dumps([dict(row) for row in store.db.execute(
                "SELECT id,started_ns,duration,timing_quality,analysis,upload,decision FROM clips ORDER BY seq DESC LIMIT 100")], indent=2))
        elif args.command == "touch":
            store.touch(args.clip_id)
        elif args.command == "ingest":
            print(ingest(store, args.path))
        elif args.command == "prune":
            store.enforce_budget()
        elif args.command == "recover":
            from .capture import recover
            with store.role_lock("record"):
                recover(store)
                store.enforce_budget()
    finally:
        store.close()


if __name__ == "__main__":
    main()
