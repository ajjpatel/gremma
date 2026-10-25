from dataclasses import dataclass
from pathlib import Path
import math
import tomllib
from urllib.parse import urlsplit


@dataclass(frozen=True)
class Config:
    storage_dir: str = "./data"
    device_id: str = "oracle-01"
    max_bytes: int = 16_000_000_000  # Decimal GB, not GiB; models are separate.
    reserve_bytes: int = 256_000_000
    min_free_bytes: int = 1_000_000_000
    segment_seconds: int = 30
    max_segment_bytes: int = 64_000_000
    # These are GStreamer element descriptions, not shell commands.
    source: str = (
        "qtiqmmfsrc camera=0 name=camera video_0::type=preview ! "
        "video/x-raw,format=NV12_Q08C,width=1920,height=1080,framerate=30/1"
    )
    encoder: str = (
        'v4l2h264enc capture-io-mode=4 output-io-mode=5 '
        'extra-controls="controls,video_bitrate=4000000,video_gop_size=30,video_gop_closure=1,video_b_frames=0"'
    )
    model_path: str = "./models/embeddinggemma-2"
    model_revision: str = "local-snapshot"
    model_threads: int = 4
    inference_timeout_seconds: int = 90
    difference_threshold: float = 0.08
    analysis_start_seq: int = 0  # Optional reversible cutoff for existing queues.
    upload_url: str = ""
    upload_token_env: str = "GREMMA_UPLOAD_TOKEN"
    upload_ca_file: str = ""
    upload_timeout_seconds: int = 30
    ffmpeg: str = "ffmpeg"
    ffprobe: str = "ffprobe"

    def __post_init__(self):
        for name in ("max_bytes", "reserve_bytes", "segment_seconds", "max_segment_bytes",
                     "model_threads", "inference_timeout_seconds",
                     "upload_timeout_seconds"):
            value = getattr(self, name)
            if type(value) is not int or value <= 0:
                raise ValueError(f"{name} must be a positive integer")
        if type(self.min_free_bytes) is not int or self.min_free_bytes < 0:
            raise ValueError("min_free_bytes must be a nonnegative integer")
        if type(self.analysis_start_seq) is not int or self.analysis_start_seq < 0:
            raise ValueError("analysis_start_seq must be a nonnegative integer")
        if self.reserve_bytes < 2 * self.max_segment_bytes:
            raise ValueError("reserve_bytes must cover at least two max_segment_bytes")
        if self.max_bytes <= self.reserve_bytes:
            raise ValueError("max_bytes must exceed reserve_bytes")
        for name in ("difference_threshold",):
            value = getattr(self, name)
            if not isinstance(value, (int, float)) or not math.isfinite(value) or not 0 <= value <= 1:
                raise ValueError(f"{name} must be finite and between 0 and 1")
        for name in ("storage_dir", "source", "encoder", "model_path", "model_revision",
                     "device_id", "ffmpeg", "ffprobe", "upload_token_env"):
            if not isinstance(getattr(self, name), str) or not getattr(self, name).strip():
                raise ValueError(f"{name} must be a nonempty string")
        if any(c in self.device_id for c in "\r\n"):
            raise ValueError("device_id cannot contain newlines")
        if self.upload_url:
            url = urlsplit(self.upload_url)
            if url.scheme != "https" or not url.hostname or url.username or url.password or url.fragment:
                raise ValueError("upload_url must be HTTPS without embedded credentials or fragment")


def load_config(path: str) -> Config:
    file = Path(path).resolve()
    with file.open("rb") as f:
        values = tomllib.load(f)
    # Paths are relative to the config file, independent of systemd's cwd.
    for key in ("storage_dir", "model_path", "upload_ca_file"):
        value = values.get(key, getattr(Config(), key))
        if value:
            p = Path(value).expanduser()
            values[key] = str(p if p.is_absolute() else file.parent / p)
    return Config(**values)
