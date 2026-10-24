# Gremma video capture on VENTUNO Q

Continuous camera capture on the board's **Linux/Qualcomm processor**, bounded
local retention, EmbeddingGemma 2 clip selection, and optional delivery to a
phone. The STM32 microcontroller does not run the camera or embedding pipeline.
This directory is independent of the repository's existing iOS application.

## Data flow

```text
IMX708 → QMMF/CamX → hardware H.264 → 5-second MP4 segments
                                      ↓ atomic publication
                               16 GB ring + SQLite queue
                                      ↓ separate worker process
                    EmbeddingGemma 2 + sampled motion + heartbeat
                                      ↓ candidate + neighboring clips
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
The CPU reference backend uses the documented Sentence Transformers video API,
loads the text/vision model with audio disabled, and never downloads at runtime.
It does not claim Qualcomm NPU acceleration. Qualify CPU throughput first;
NPU deployment needs a separately validated model export/runtime.

The worker compares normalized video embeddings using cosine distance, and
also checks grayscale motion at 4 sampled frames/second. A candidate is selected
if semantic novelty **or** motion exceeds the configured threshold, or a periodic
heartbeat is due. Analysis errors send the clip rather than suppressing it.
One available previous clip and the following clip provide boundary context.

**Default `selection_mode = "observe"` sends every clip** while recording gate
scores. Change to `"filter"` after evaluating recall on your actual room/camera.
The supplied thresholds are starting values, not measured operating points.
Embedding similarity is not an activity detector: tiny objects, occlusions,
and brief actions can be missed. These outputs are candidate video evidence;
the phone must not turn “medicine handled” into verified ingestion.

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
model accuracy, or sustained real-time throughput. Hardware results and remaining
qualification are recorded in [board validation](docs/board-validation.md).
