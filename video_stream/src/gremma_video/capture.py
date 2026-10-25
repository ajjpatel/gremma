"""GStreamer runs continuously; only finalized segments enter the queue."""
import logging
from pathlib import Path
import signal
import subprocess
import time

from .config import Config
from .media import probe
from .storage import CLIP_NAME, Store, StorageFull

LOG = logging.getLogger(__name__)


def recover(store: Store):
    """Call only with the recorder role lock. Recover valid orphaned segments.

    An interrupted MP4 without its final header is discarded. Older completed
    segments remain independent and playable. Unrelated files are never deleted.
    """
    with store.transaction():
        for row in store.db.execute("SELECT id FROM clips").fetchall():
            if not store.path(row["id"]).is_file():
                store.db.execute("DELETE FROM clips WHERE id=?", (row["id"],))
                store.increment("missing_clips")
    for path in sorted(store.clips.iterdir()):
        if not CLIP_NAME.fullmatch(path.name) or path.is_symlink():
            continue
        clip_id = path.name.split(".")[0]
        if store.db.execute("SELECT 1 FROM clips WHERE id=?", (clip_id,)).fetchone():
            continue
        # A missing executable is an installation error, not corrupt media.
        try:
            duration = probe(path, store.cfg)
        except FileNotFoundError:
            raise
        except (subprocess.CalledProcessError, ValueError) as exc:
            LOG.warning("discarding unfinalized/unreadable orphan %s: %s", path.name, type(exc).__name__)
            path.unlink()
            with store.transaction():
                store.increment("discarded_partial_clips")
            continue
        # After an unclean shutdown, mtime is only an approximate capture clock.
        started = path.stat().st_mtime_ns - int(duration * 1e9)
        if ".partial." in path.name:
            store.finalize(path, started, duration)
        else:
            store.register(path, started, duration)
        store.db.execute("UPDATE clips SET timing_quality='recovered_estimate' WHERE id=?", (clip_id,))
        LOG.info("recovered %s", clip_id)


def record(cfg: Config):
    # GI is provided by the board's apt packages, not a pip-installed mock.
    import gi
    gi.require_version("Gst", "1.0")
    from gi.repository import GLib, Gst

    Gst.init(None)
    store = Store(cfg)
    with store.role_lock("record"):
        recover(store)
        store.enforce_budget()
        pipeline = Gst.parse_launch(
            f"{cfg.source} ! queue max-size-buffers=8 ! {cfg.encoder} ! "
            "h264parse config-interval=-1 ! splitmuxsink name=segments "
            f"max-size-time={cfg.segment_seconds * 1_000_000_000} "
            "max-size-bytes=0 send-keyframe-requests=true async-finalize=true muxer-factory=mp4mux"
        )
        sink = pipeline.get_by_name("segments")
        sink.connect("format-location", lambda *_: str(store.new_partial()))
        loop = GLib.MainLoop()
        opened = {}
        last_closed = time.monotonic()
        failure = None
        stopping_at = None

        def stop(reason=None):
            nonlocal failure, stopping_at
            if reason and failure is None:
                failure = reason
                LOG.error("stopping recorder: %s", reason)
            if stopping_at is None:
                stopping_at = time.monotonic()
                pipeline.send_event(Gst.Event.new_eos())

        def on_message(_bus, message):
            nonlocal last_closed
            try:
                if message.type == Gst.MessageType.ERROR:
                    err, debug = message.parse_error()
                    stop(f"GStreamer: {err.message}; {debug}")
                    loop.quit()
                elif message.type == Gst.MessageType.EOS:
                    loop.quit()
                elif message.type == Gst.MessageType.ELEMENT:
                    structure = message.get_structure()
                    if not structure:
                        return
                    name = structure.get_name()
                    if name == "splitmuxsink-fragment-opened":
                        path = structure.get_value("location")
                        running = int(structure.get_value("running-time"))
                        clock = pipeline.get_clock()
                        base = time.time_ns() - int(clock.get_time() - pipeline.get_base_time())
                        opened[path] = (base + running, time.monotonic())
                    elif name == "splitmuxsink-fragment-closed":
                        path = Path(structure.get_value("location"))
                        duration = probe(path, cfg)
                        started, _ = opened.pop(str(path), (time.time_ns() - int(duration * 1e9), 0))
                        clip_id = store.finalize(path, started, duration)
                        last_closed = time.monotonic()
                        store.set_state("recorder", {"last_clip_id": clip_id, "last_closed_ns": time.time_ns(), "state": "recording"})
                        LOG.info("finalized %s %.2fs", clip_id, duration)
                        store.enforce_budget()
            except Exception as exc:
                stop(f"{type(exc).__name__}: {exc}")

        def housekeeping():
            nonlocal failure
            try:
                if stopping_at is not None:
                    if time.monotonic() - stopping_at > 10:
                        failure = failure or "EOS finalization timeout"
                        loop.quit()
                    return True
                # If keyframe requests are ignored, storage cannot grow without
                # bound waiting for a GOP. A supervisor restarts the camera.
                if time.monotonic() - last_closed > max(30, cfg.segment_seconds * 4):
                    stop("no completed segment within watchdog interval")
                for path in store.clips.glob("*.partial.mp4"):
                    if path.stat().st_size > cfg.max_segment_bytes:
                        stop("active segment exceeded max_segment_bytes; check encoder GOP/bitrate")
                store.enforce_budget()
            except (StorageFull, OSError) as exc:
                stop(str(exc))
            return True

        bus = pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message", on_message)
        GLib.timeout_add(1000, housekeeping)
        old_handlers = {}
        for sig in (signal.SIGTERM, signal.SIGINT):
            old_handlers[sig] = signal.signal(sig, lambda *_: GLib.idle_add(lambda: (stop(), False)[1]))
        try:
            store.set_state("recorder", {"state": "starting", "since_ns": time.time_ns()})
            result = pipeline.set_state(Gst.State.PLAYING)
            if result == Gst.StateChangeReturn.FAILURE:
                failure = "camera pipeline could not enter PLAYING"
                raise RuntimeError(failure)
            loop.run()
        finally:
            pipeline.set_state(Gst.State.NULL)
            bus.remove_signal_watch()
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
            store.set_state("recorder", {"state": "failed" if failure else "stopped", "reason": failure, "since_ns": time.time_ns()})
            store.close()
        if failure:
            raise RuntimeError(failure)
