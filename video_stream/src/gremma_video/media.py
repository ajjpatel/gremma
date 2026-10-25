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


def endpoint_images(path: Path, threads=4):
    """Decode to EOF, retaining only the first and final displayed frames.

    Run inside the inference subprocess so its deadline bounds decoding too.
    Seeking to duration minus a guessed interval can select an earlier frame,
    especially with variable frame rates; decoding to EOF avoids that guess.
    """
    import av
    with av.open(str(path)) as container:
        if not container.streams.video:
            raise ValueError("clip has no video stream")
        stream = container.streams.video[0]
        stream.thread_type = "AUTO"
        stream.codec_context.thread_count = threads
        first = last = None
        count = 0
        for frame in container.decode(stream):
            if first is None:
                first = frame
            last = frame
            count += 1
        if count < 2:
            raise ValueError("clip needs at least two decoded frames")
        metadata = {"decoded_frames": count,
                    "first_frame_seconds": first.time,
                    "last_frame_seconds": last.time}
        return [first.to_image(), last.to_image()], metadata
