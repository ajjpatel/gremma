# Gremma video capture on VENTUNO Q

Continuous camera capture on the board's **Linux/Qualcomm processor**, bounded
local retention, EmbeddingGemma 2 clip selection, and optional delivery to a
phone. The STM32 microcontroller does not run the camera or embedding pipeline.
This directory is independent of the repository's existing iOS application.

## Data flow

```text
IMX708 → QMMF/CamX → hardware H.264 → 30-second MP4 segments
                                      ↓ atomic publication
                               16 GB ring + SQLite queue
                                      ↓ separate worker process
                    EmbeddingGemma 2: first frame vs last frame
                                      ↓ changed clips only
                               persistent upload queue
                                      ↓ optional authenticated HTTPS
                                  Pixel application
```

The recorder, analyzer, and uploader run separately. Model loading, a failed
inference, or a disconnected phone does not block the camera. MP4s enter the
queue only after GStreamer reports that the segment is closed, the file is
synced, and its name is atomically changed from `.partial.mp4` to `.mp4`.

## Retention behavior

- `max_bytes = 16000000000` is **16 decimal GB**, covering managed videos,
  partial videos, and SQLite state/WAL. Model weights and system logs are outside
  this budget. At 4 Mbit/s, 16 GB represents roughly 8.9 hours before reserves
  and overhead; actual encoder bitrate determines retention time.
- Explicit LRU uses `last_access_ns` in SQLite. A newly recorded clip starts with
  its capture time. `touch CLIP_ID` promotes a clip after a deliberate user
  access. Internal inference, hashing, and upload do not promote it. Without
  user touches, this has the oldest-first behavior of a dashcam.
- Active segments and clips currently being analyzed/uploaded cannot be evicted.
  Process-owned file locks prevent concurrent deletion; locks release on crash.
- The upload queue references the same files; it does not make another video copy.
  **Queued but unsent clips can expire** when the ring fills. This keeps storage
  bounded during a long outage; `status` reports the cumulative loss counter.
- The recorder reserves 256 MB for current/finalizing segments and metadata,
  checks usage each second, and requires another 1 GB free on the filesystem.
  It stops on unresolved pressure or stalled/oversized segments and is restarted
  by systemd. This is an application budget, not a filesystem quota: encoder
  bursts between checks can exceed a threshold. Use a dedicated filesystem or
  filesystem quota if a strict physical 16 GB ceiling is required.
- On restart, finalized orphan MP4s are recovered. An interrupted, unplayable
  tail is discarded and counted. Recovered timestamps are explicitly approximate.
  Unrelated files are never pruned. Keep this service's data directory private.

## Clip selection

Use **`google/embeddinggemma-2`**, not the original text-only EmbeddingGemma.
The CPU reference backend decodes each finalized clip to its actual first and
last displayed frames, embeds those two images independently with audio disabled,
and compares their normalized vectors using cosine distance. It queues the whole
clip when `distance > difference_threshold` (initial value `0.08`); otherwise it
marks that clip analyzed and moves to the next eligible clip in recording order.
There is no cross-clip baseline, motion trigger, heartbeat, or neighbor forwarding.

The model receives only two images, each with a 140-token visual budget. Decoding
runs to EOF so variable frame rates and delayed codec frames do not cause an
approximate seek to pick the wrong endpoint. Only the two endpoint images are
retained in memory. Images and embeddings are not written as separate artifacts.

The reference stack uses FP32 on CPU and PyAV decoding, with versions in
`requirements.cpu-aarch64.txt`. Model loading and decoding share a bounded
subprocess deadline. If comparison fails, the clip is queued with
`analysis_unavailable`; an error is not treated as an unchanged scene.
No Qualcomm NPU acceleration is claimed.

Calibrate the difference threshold against representative scenes. This detects
endpoint changes, not all activity: an action that returns the scene to its
starting appearance can be missed. Embeddings can also miss small objects or
react to lighting/camera changes. The phone receives candidate evidence, not
proof of an event or medicine ingestion.

For an existing installation, `analysis_start_seq` can start analysis at a newer
sequence without modifying earlier queue entries. The default `0` processes all
pending clips. Resetting it to `0` resumes older clips still retained by the ring;
`status` reports `pending_before_start_seq` separately.

## Setup and commands

Follow [board bring-up](docs/board-setup.md) for driver installation, camera
qualification, model download, and service setup. Give the Pixel developer the
[receiver contract](docs/receiver-contract.md). No network upload happens until
an endpoint is configured and the uploader is started.

From this directory, after installing the package:

```bash
cp config.example.toml config.local.toml
gremma-video --config config.local.toml doctor
gremma-video --config config.local.toml record
# Separate terminals/processes:
gremma-video --config config.local.toml worker
gremma-video --config config.local.toml status
gremma-video --config config.local.toml list
# After implementing/configuring the phone receiver:
gremma-video --config config.local.toml upload
```

For a local prerecorded MP4, use `ingest /absolute/path/clip.mp4`, then
`worker --once`. `check-model /absolute/path/clip.mp4` runs real inference and
fails explicitly if the model cannot load, unlike the operational fail-open
worker. `recover` requires the recorder to be stopped. `prune` applies retention
immediately. Config paths resolve relative to the TOML file.

## Verification

The standard-library suite exercises LRU/locks, storage pressure, crash recovery,
queue persistence, selection, error handling, multipart uploads, and acknowledgements:

```bash
PYTHONPATH=src python3 -m unittest discover -s tests -v
```

Real GStreamer segmentation/EOS/FFmpeg validation is opt-in on a suitable host:

```bash
RUN_GSTREAMER_SMOKE=1 PYTHONPATH=src python3 -m unittest discover -s tests -v
```

Neither synthetic video nor mocked embeddings establish IMX708 compatibility,
endpoint-change accuracy, or sustained real-time throughput. Hardware results and remaining
qualification are recorded in [board validation](docs/board-validation.md).
