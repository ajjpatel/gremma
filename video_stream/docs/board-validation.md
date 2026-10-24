# Validation record — October 24, 2026

Target inspected over SSH: VENTUNO Q, Ubuntu 24.04.4 LTS, ARM64,
kernel `6.8.0-1078-qcom`. No credentials, household footage, or device network
addresses are included in this repository.

## Completed checks

- Local Python suite: 33 tests passed; one real-media test requires GStreamer.
- ARM64 board run after installing media dependencies: **34 tests passed** in
  15.83 seconds, including real GStreamer synthetic recording, playable MP4
  segments, graceful EOS, and FFmpeg motion extraction.
- Hardware `v4l2h264enc` exists and advertises NV12, NV21, and NV12_Q08C inputs.
- The starting image lacked `qtiqmmfsrc`, FFmpeg, and V4L2 diagnostic tools.
- Read-only inspection identified the actual camera/encoder stack prerequisites.
- Installed QMMF source, GStreamer good/bad/ugly/libav components, FFmpeg, V4L2
  tools, and Python virtual-environment support. The missing `h264parse` plugin
  was caught by the media test and resolved with the bad-plugins package.
- Encoder controls include `video_gop_size`, `video_gop_closure`,
  `video_b_frames`, and `video_bitrate`; the default profile uses those controls.
- Hardware `v4l2h264enc` also produced continuous five-second MP4s for over
  three minutes from a 640x480 NV12 synthetic source. That test used
  `capture-io-mode=4 output-io-mode=2` because synthetic frames use system
  memory. The camera's proposed DMA-import mode (`output-io-mode=5`) remains
  unqualified until the sensor is detected.
- EmbeddingGemma 2 snapshot `914f7f89142e33e77833254d9c9b90c3cef7303b`
  downloaded and passed per-file integrity verification.

## Camera detection blocker

Installed CamX QCS9100 version `1.0.13+repack1` loads the IMX708 sensor module
definitions. After restarting `cam-server.service`, it still reports zero
probed sensors and zero cameras. Kernel messages show `rpi_imx708 read id: 0x0
expected id 0x708` and I²C NACK/read errors. Physical IMX708 capture is therefore
**not validated**. Check cable orientation/pinout, connector seating, port and
sensor power with the board powered off; a known-good cable/camera comparison
may be needed. These logs do not establish which component is at fault.

## Model runtime bring-up

The CPU runtime installation is in progress. Default PyPI Linux ARM64 PyTorch
wheels attempted to fetch CUDA dependencies; installation was stopped and
switched to PyTorch's CPU wheel index. The first CPU download timed out and was
retried. No model-inference or throughput result is claimed yet.

## Qualification still required

Physical IMX708 detection/capture, actual model inference, warm sustained
processing rate, camera-plus-model soak testing,
on-device quota rollover, and delivery to the future Pixel receiver. The code
does not claim these have passed until measured results are recorded here.

The synthetic test covers segmentation, graceful EOS, playable MP4s, and motion
extraction. It cannot establish real-world event recall. The Pixel receiver is
a proposed contract; there is no implemented Pixel application in this change.
