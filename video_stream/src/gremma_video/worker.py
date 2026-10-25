import logging
import multiprocessing
import os
from pathlib import Path
import signal
import threading
import time

from .config import Config
from .media import endpoint_images
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
            # The checkpoint defaults to BF16, which can be emulated slowly on
            # ARM CPUs without native BF16 instructions. Use the CPU FP32 path.
            model_kwargs={"dtype": torch.float32},
        )
        while True:
            path = connection.recv()
            if path is None:
                break
            images, frames = endpoint_images(Path(path), threads)
            embeddings = model.encode(
                [{"image": image} for image in images], batch_size=2,
                normalize_embeddings=True, show_progress_bar=False,
                processing_kwargs={"image": {"max_soft_tokens": 140}},
            )
            connection.send((True, {"first_embedding": embeddings[0].tolist(),
                                    "last_embedding": embeddings[1].tolist(),
                                    "frames": frames}))
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


def process_one(store, embedder):
    with store.lease_next("worker") as (row, _handle):
        if row is None:
            return False
        path = store.path(row["id"])
        started = time.monotonic()
        try:
            decision = decide(store.cfg, embedder.encode(path))
        except Exception as exc:
            LOG.warning("endpoint comparison unavailable for %s: %s", row["id"], exc)
            decision = decide(store.cfg, error=type(exc).__name__)
        store.complete_analysis(row, decision)
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
