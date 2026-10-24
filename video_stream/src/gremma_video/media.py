import json
import math
from pathlib import Path
import subprocess

from .config import Config


def probe(path: Path, cfg: Config) -> float:
    result = subprocess.run(
        [cfg.ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=codec_name:format=duration", "-of", "json", str(path)],
        check=True, capture_output=True, timeout=15,
    )
    data = json.loads(result.stdout)
    duration = float(data.get("format", {}).get("duration", 0))
    if not data.get("streams") or not math.isfinite(duration) or duration <= 0:
        raise ValueError("clip has no usable video stream/duration")
    return duration


def motion_score(path: Path, cfg: Config) -> float:
    """Maximum changed-pixel fraction between sampled grayscale frames.

    This is a recall-oriented companion to semantic novelty, not recognition.
    Sampling and downscaling can still miss small/brief actions.
    """
    width, height = 160, 90
    result = subprocess.run(
        [cfg.ffmpeg, "-nostdin", "-v", "error", "-i", str(path), "-an",
         "-vf", f"fps=4,scale={width}:{height}", "-frames:v", "64",
         "-pix_fmt", "gray", "-f", "rawvideo", "pipe:1"],
        check=True, capture_output=True, timeout=30,
    )
    size = width * height
    raw = result.stdout
    if len(raw) < 2 * size or len(raw) % size:
        raise ValueError("too few decoded frames to estimate motion")
    score = 0.0
    for offset in range(size, len(raw), size):
        previous, current = raw[offset - size:offset], raw[offset:offset + size]
        changed = sum(abs(a - b) >= 20 for a, b in zip(previous, current))
        score = max(score, changed / size)
    return score
