"""Compare the first and last frame of each clip independently."""
import math

from .config import Config


def normalize(vector):
    vector = [float(v) for v in vector]
    if not vector or any(not math.isfinite(v) for v in vector):
        raise ValueError("invalid embedding")
    norm = math.hypot(*vector)
    if not math.isfinite(norm) or norm <= 1e-12:
        raise ValueError("zero embedding")
    return [v / norm for v in vector]


def decide(cfg: Config, result=None, error=None):
    distance = None
    frames = None
    if error is None:
        if result is None:
            raise ValueError("endpoint embeddings missing")
        first = normalize(result["first_embedding"])
        last = normalize(result["last_embedding"])
        if len(first) != len(last):
            raise ValueError("endpoint embedding dimensions differ")
        distance = max(0.0, min(2.0, 1.0 - sum(a * b for a, b in zip(first, last))))
        frames = result.get("frames")
        changed = distance > cfg.difference_threshold
        reason = "endpoint_change" if changed else "endpoints_similar"
    else:
        # An unreadable clip/model failure is unknown, never proof of no change.
        changed, reason = True, "analysis_unavailable"
    return {"candidate": changed, "send": changed, "reasons": [reason],
            "method": "first_last_frame_embeddings", "cosine_distance": distance,
            "difference_threshold": cfg.difference_threshold, "frames": frames,
            "model_revision": cfg.model_revision, "error": error}
