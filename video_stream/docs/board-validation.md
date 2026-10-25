# Board validation — October 24, 2026 (Pacific time)

Target: Arduino VENTUNO Q, Ubuntu 24.04.4 LTS, ARM64, kernel
`6.8.0-1078-qcom`. Credentials, network addresses, and household footage are
excluded from the repository.

## Automated and retention checks

- Current local suite: **35 passed, two Linux media tests skipped**.
- Current board suite: **37 passed in 15.02 seconds**, including continuous
  GStreamer recording, finalized MP4 playback, graceful EOS, and actual first/
  last frame extraction. A red-then-blue H.264 test decoded all 20 frames and
  verified the endpoints at 0.0 and 1.9 seconds, including delayed codec frames.
- Queue tests verify that only the changed clip is queued, identical endpoints
  are skipped immediately, comparison is independent of previous clips, failure
  is explicit, and a configured analysis cutoff leaves earlier queue entries
  untouched and resumable.
- A separate real-recording rollover check used a 3 MB budget with a 1 MB
  reserve: 23 clips produced, oldest 13 expired, ten remained. Managed usage
  was 1,477,099 bytes; the first and last remaining MP4s passed FFprobe. Loss
  accounting was 13, with zero missing files or discarded partials.
- This verifies retention at a small budget; a full 16 GB soak is outstanding.

## Camera and recorder

The initial IMX708 sensor probe returned `0x0` instead of `0x708`. Reconnecting
the camera and restarting `cam-server.service` resolved detection. CamX QCS9100
`1.0.13+repack1` worked without a kernel upgrade.

Physical H.264 capture passed at 640x480 and 1920x1080, approximately 30 fps.
The 1080p test produced twelve playable clips, and a complete clip decoded with
FFmpeg without errors. Camera input is NV12_Q08C; hardware encoder modes are
capture 4 / output 5. Controls use `video_gop_size`, `video_gop_closure`,
`video_b_frames`, and `video_bitrate`.

`gremma-video@record.service` is enabled for boot and has restarted automatically
after board reboots. Recovery retains finalized clips and counts discarded
unfinished tails. The deployment now requests **30-second segments**, replacing
the earlier five-second bring-up profile. The first four new clips measured
29.006, 29.362, 29.620, and 29.003 seconds. Keyframe-driven durations must be read
from each finalized clip's metadata.

Configuration: `/etc/gremma-video/config.toml`. Storage:
`/var/lib/gremma-video`, with a 16,000,000,000-byte budget. This development
installation runs as `arduino`, using the virtual environment and source at
`/home/arduino/gremma-video-dev/video_stream`; it starts after `cam-server.service`.
The generic dedicated-user installation is documented in board setup.

The earlier 551 bring-up clips and their queue records remain untouched.
`analysis_start_seq = 552` starts the new worker at the 30-second profile.
Setting it back to `0` resumes older pending clips that have not expired.

## Model runtime

EmbeddingGemma 2 snapshot `914f7f89142e33e77833254d9c9b90c3cef7303b` passed
per-file integrity verification. CPU dependencies were downloaded on the Mac
and installed offline through USB after Wi-Fi downloads stalled. A 297 MB
bundle transferred at 39.5 MB/s; transferred checksums and `pip check` passed.

The current implementation uses CPU FP32, four model threads, PyAV endpoint
decoding, and a 140-token visual budget for each of the two images. The pinned
reference versions are in `requirements.cpu-aarch64.txt`. Only first and last
frames are embedded; no intermediate-frame or cross-clip inference is used.

The actual 1080p endpoint benchmark used a 29.006-second camera clip containing
868 decoded frames, with endpoint timestamps 0.000 and 28.973 seconds. Both
embeddings had 768 dimensions. Startup plus first comparison took **35.71 s**;
the next two comparisons took **21.20 s** and **21.34 s**, while recording
continued. All three returned the same cosine distance, 0.28171, above the
0.08 threshold. This passes the short throughput check for the 30-second target;
it is not a long thermal or workload soak.

`gremma-video@worker.service` is enabled for boot and running. The live queue
confirmed both outcomes: sequence 552 was queued with distance 0.28171; sequence
553 was skipped with distance 0.01990. Neither had an analysis error. The worker
reported 20.86 seconds for the second clip. Both recorder and worker had zero
service restarts; their memory usage was approximately 191 MB and 2.85 GB.
The uploader remains disabled because the Pixel receiver is not implemented.

## Remaining qualification

Sustained camera-plus-model throughput, a full 16 GB rollover soak, labeled
endpoint-change recall/threshold calibration, and delivery to a real Pixel
receiver. Endpoint comparison cannot detect an action whose ending scene matches
its starting scene, and it does not establish medicine ingestion.
