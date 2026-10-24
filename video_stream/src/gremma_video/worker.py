import logging
import multiprocessing
import os
from pathlib import Path
import signal
import threading
import time

from .config import Config
from .media import motion_score
from .selection import decide
from .storage import Store

LOG = logging.getLogger(__name__)


def _embedding_server(connection, model_path, threads):
    """An isolated CPU reference backend, using Google's documented media API.

    Model loading/inference can hang or OOM without stopping the recorder. This
    is NOT a claim of Qualcomm NPU acceleration; that needs a validated export.
    """
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    try:
        import torch
        from sentence_transformers import SentenceTransformer
        torch.set_num_threads(threads)
        import json
        with (Path(model_path) / "config.json").open() as f:
            model_config = json.load(f)
        if model_config.get("model_type") != "embedding_gemma2":
            raise ValueError("model_path must contain EmbeddingGemma 2, not text-only EmbeddingGemma")
        model = SentenceTransformer(
            model_path, device="cpu", local_files_only=True,
            config_kwargs={"audio_config": None},
        )
        while True:
            path = connection.recv()
            if path is None:
                break
            embedding = model.encode({"video": path}, normalize_embeddings=True)
            connection.send((True, embedding.reshape(-1).tolist()))
    except EOFError:
        pass
    except Exception as exc:
        connection.send((False, f"{type(exc).__name__}: {exc}"))
    finally:
        connection.close()


class Embedder:
    def __init__(self, cfg):
        self.cfg = cfg
        self.process = None
        self.connection = None
        self.retry_at = 0

    def encode(self, path):
        if time.monotonic() < self.retry_at:
            raise RuntimeError("embedding backend cooling down after failure")
        try:
            if self.process is None:
                if not Path(self.cfg.model_path).is_dir():
                    raise FileNotFoundError("model snapshot missing; run the documented model setup")
                context = multiprocessing.get_context("spawn")
                self.connection, child = context.Pipe()
                self.process = context.Process(target=_embedding_server,
                    args=(child, self.cfg.model_path, self.cfg.model_threads), daemon=True)
                self.process.start()
                child.close()
            self.connection.send(str(path))
            if not self.connection.poll(self.cfg.inference_timeout_seconds):
                raise TimeoutError("embedding load/inference deadline exceeded")
            ok, result = self.connection.recv()
            if not ok:
                raise RuntimeError(result)
            return result
        except Exception:
            self.close()
            self.retry_at = time.monotonic() + 60
            raise

    def close(self):
        if self.process:
            self.process.terminate()
            self.process.join(timeout=5)
            if self.process.is_alive():
                self.process.kill()
                self.process.join(timeout=5)
        if self.connection:
            self.connection.close()
        self.process = self.connection = None


def process_one(store, embedder, motion_fn=motion_score):
    with store.lease_next("worker") as (row, _handle):
        if row is None:
            return False
        path = store.path(row["id"])
        started = time.monotonic()
        vector, motion, errors = None, None, []
        try:
            vector = embedder.encode(path)
            # Validate before the gate, so bad model output takes fail-open path.
            from .selection import normalize
            vector = normalize(vector)
        except Exception as exc:
            vector = None
            errors.append(f"embedding:{type(exc).__name__}")
            LOG.warning("embedding unavailable for %s: %s", row["id"], exc)
        try:
            motion = motion_fn(path, store.cfg)
        except Exception as exc:
            errors.append(f"motion:{type(exc).__name__}")
            LOG.warning("motion unavailable for %s: %s", row["id"], exc)
        decision, state = decide(store.cfg, row, vector, motion,
                                 store.get_state("selector", {}), ";".join(errors) or None)
        store.complete_analysis(row, decision, state)
        store.set_state("worker", {"last_clip_id": row["id"], "analyzed_at_ns": time.time_ns(),
                                  "processing_seconds": time.monotonic() - started, "error": decision["error"]})
        LOG.info("analyzed %s send=%s reasons=%s", row["id"], decision["send"], decision["reasons"])
        return True


def worker(cfg: Config, once=False):
    store = Store(cfg)
    embedder = Embedder(cfg)
    stop = threading.Event()
    handlers = {}
    for sig in (signal.SIGTERM, signal.SIGINT):
        handlers[sig] = signal.signal(sig, lambda *_: stop.set())
    try:
        with store.role_lock("worker"):
            while not stop.is_set():
                worked = process_one(store, embedder)
                if once:
                    break
                if not worked:
                    stop.wait(1)
    finally:
        embedder.close()
        store.close()
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
