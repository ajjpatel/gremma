"""Candidate gate: semantic novelty OR motion OR periodic heartbeat.

Scores are heuristics, not probabilities, object detections, or proof that an
action occurred. Observe mode sends every clip until recall is measured.
"""
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


def decide(cfg: Config, row, vector, motion, previous, error=None):
    fingerprint = f"{cfg.model_path}@{cfg.model_revision}"
    if previous.get("fingerprint") != fingerprint:
        previous = {}
    reasons = []
    distance = None
    if vector is not None:
        vector = normalize(vector)
        reference = previous.get("vector")
        if reference and len(reference) == len(vector):
            distance = max(0.0, min(2.0, 1.0 - sum(a * b for a, b in zip(vector, normalize(reference)))))
            if distance >= cfg.novelty_threshold:
                reasons.append("semantic_change")
        else:
            reasons.append("baseline")
    if motion is not None:
        if not math.isfinite(motion) or not 0 <= motion <= 1:
            raise ValueError("invalid motion score")
        if motion >= cfg.motion_threshold:
            reasons.append("motion")
    if error or vector is None or motion is None:
        reasons.append("analysis_unavailable")
    last_trigger = previous.get("last_trigger_ns", 0)
    delta = row["started_ns"] - last_trigger
    if not last_trigger or delta < 0 or delta >= cfg.heartbeat_seconds * 1_000_000_000:
        reasons.append("heartbeat")
    candidate = bool(reasons)
    send = candidate or previous.get("post_context", False) or cfg.selection_mode == "observe"
    if previous.get("post_context"):
        reasons.append("post_context")
    if cfg.selection_mode == "observe":
        reasons.append("observe_mode")
    decision = {"candidate": candidate, "send": bool(send), "reasons": reasons,
                "cosine_distance": distance, "motion_fraction": motion,
                "model_revision": cfg.model_revision, "error": error,
                "selection_mode": cfg.selection_mode}
    state = {"fingerprint": fingerprint, "vector": vector or previous.get("vector"),
             "last_trigger_ns": row["started_ns"] if candidate else last_trigger,
             "post_context": candidate}
    return decision, state
