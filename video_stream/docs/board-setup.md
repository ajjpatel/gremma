# Board bring-up

Target: Arduino VENTUNO Q, Linux on its Qualcomm MPU, Raspberry Pi Camera Module
3 / Sony IMX708, EmbeddingGemma 2. Commands here run **on the board** unless noted.

## 1. Camera/OS prerequisites

Power the board off before changing the ribbon cable. Verify the camera's cable
pinout, contact orientation, and port against the board documentation; a matching
CSI connector alone does not establish electrical or software compatibility.
Use the proper Camera Module 3 adapter cable for the board's 22-pin port.

Arduino announced IMX708 support in GStreamer/CamX on October 20, 2026, but its
worked example used another sensor. The exact installed image still needs a
probe/capture test:

- [Arduino IMX708 support announcement](https://forum.arduino.cc/t/request-add-camera-support-for-arduino-ventuno-q-and-uno-q/1446752)
- [VENTUNO Q MIPI-CSI guide](https://docs.arduino.cc/tutorials/ventuno-q/mipi-csi-camera/)
- [Arduino camera-stack setup](https://docs.arduino.cc/tutorials/ventuno-q/ros2-perception-rgb-cam/)

```bash
cat /etc/os-release
uname -a
sudo apt-get update
sudo apt-get install --no-install-recommends \
  gstreamer1.0-plugins-qcom-qmmfsrc ffmpeg v4l-utils \
  python3-gi python3-venv gir1.2-gst-plugins-base-1.0 \
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
  gstreamer1.0-plugins-ugly gstreamer1.0-libav
gst-inspect-1.0 qtiqmmfsrc
gst-inspect-1.0 v4l2h264enc
gst-inspect-1.0 splitmuxsink
v4l2-ctl --list-devices
sudo journalctl -k --no-pager
```

The `qmmfsrc` package is the camera-specific component of the larger
`gstreamer1.0-plugins-qcom` metapackage. A newly installed camera stack may require
a reboot to initialize the sensor. Check active work before rebooting. Do not
use Raspberry Pi's `rpicam-vid`/Picamera2 on this Qualcomm camera stack.

## 2. Install this component

Copy/clone the repository to the board, then enter `video_stream`:

```bash
python3 -m venv --system-site-packages .venv
.venv/bin/python -m pip install -e .
cp config.example.toml config.local.toml
.venv/bin/gremma-video --config config.local.toml doctor
```

`--system-site-packages` exposes apt's GI bindings to the virtual environment.
The core recorder/queue does not require PyTorch or a model download.

First test the recorder without accessing a camera:

```bash
RUN_GSTREAMER_SMOKE=1 PYTHONPATH=src .venv/bin/python -m unittest discover -s tests -v
```

Then inspect the encoder device identified by `gst-inspect-1.0 v4l2h264enc`:

```bash
v4l2-ctl --device /dev/video33 --list-ctrls
```

The device number is image-dependent. Check the exact bitrate/GOP control names.
Edit `source` and `encoder` in `config.local.toml` accordingly. The initial profile
requests 1080p30, 4 Mbit/s, a one-second GOP, and 30-second clips. Resolution,
NV12 versus NV12_Q08C, and DMA buffer modes are driver-dependent. Start with
640x480 if the sensor rejects 1080p, then increase resolution after negotiation
works. Small-object usefulness must be evaluated at the eventual resolution.

```bash
.venv/bin/gremma-video --config config.local.toml record
```

Stop with Ctrl-C after several clips, then inspect `status`, `list`, and the
MP4s with `ffprobe`. Keyframe-driven splitting can vary from the target duration.
The watchdog stops a pipeline that does not finalize segments.

## 3. Install and qualify EmbeddingGemma 2

```bash
.venv/bin/python -m pip install -r requirements.cpu-aarch64.txt
.venv/bin/python -m pip install -e '.[embedding]'
```

Install the CPU PyTorch wheels first. Current default Linux ARM64 wheels on
PyPI include CUDA dependencies, which this Qualcomm board cannot use. See
[PyTorch's installation guidance](https://pytorch.org/get-started/locally/).
PyAV decodes the clip endpoints; Sentence Transformers embeds only those images.

If board Wi-Fi is unreliable, download Linux ARM64 wheels on the Mac and copy
them over USB. The target platform flags below are essential: Mac wheels cannot
run on the board. Run from the Mac's `video_stream` checkout with Python 3.12:

```bash
python3 -m pip download -d /tmp/gremma-wheelhouse --only-binary=:all: \
  --platform manylinux_2_28_aarch64 --platform manylinux_2_17_aarch64 \
  --platform manylinux2014_aarch64 --python-version 3.12 \
  --implementation cp --abi cp312 -r requirements.cpu-aarch64.txt wheel setuptools
adb devices
adb push /tmp/gremma-wheelhouse /home/arduino/gremma-wheelhouse
adb shell
```

ADB is included in Google's [SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools).
Arduino documents this USB shell in its [VENTUNO Q access instructions](https://docs.arduino.cc/tutorials/ventuno-q/getting-started-ros2/).
Inside the board's `video_stream` directory, install from those local wheels:

```bash
.venv/bin/python -m pip install --no-index --find-links /home/arduino/gremma-wheelhouse \
  -r requirements.cpu-aarch64.txt wheel
.venv/bin/python -m pip install --no-index --no-build-isolation -e '.[embedding]'
.venv/bin/python -m pip check
```

The model snapshot can likewise be downloaded on the Mac with the helper below
and copied to the board with `adb push`; preserve `snapshot-revision.txt`.

Download once while connected. The included helper resolves a fixed model SHA,
verifies each file, and prints the revision to put in `model_revision`. Serving
never downloads or trusts remote Python code:

```bash
python3 scripts/download_model.py --destination models/embeddinggemma-2
```

The helper uses the public, ungated model repository. If its access policy
changes, use Hugging Face's authenticated `snapshot_download` after completing
any required account/license flow. Do not put a token in this repo.
The model config identifies `embedding_gemma2`; the worker rejects another model.
Library versions must understand that architecture. See Google's
[EmbeddingGemma 2 API examples](https://developers.googleblog.com/embeddinggemma-2-the-developer-guide/).

```bash
.venv/bin/gremma-video --config config.local.toml check-model /absolute/path/to/one-clip.mp4
.venv/bin/gremma-video --config config.local.toml worker
```

Check repeated warm-inference time, memory, temperature, queue depth and capture
continuity while recording. A 30-second recording interval needs sustained
analysis throughput of at least one clip per 30 seconds. Each comparison embeds
only the first and last frame, using a 140-token visual budget per image.
The bounded ring cannot compensate for a permanently slower analyzer.

Collect representative labeled examples of keys being placed, medicine being
handled, groceries arriving, empty scenes, lighting changes, occlusions, and
events crossing clip boundaries. Measure endpoint-change recall and the forwarded-video fraction, then tune
`difference_threshold`. An action that leaves matching endpoint scenes will be
skipped even if intermediate frames show activity.

## 4. Run at boot

`deploy/gremma-video@.service` is a systemd template for separate `record`,
`worker`, and `upload` services. It assumes code/venv at
`/opt/gremma/video_stream`, configuration at `/etc/gremma-video/config.toml`, a
dedicated `gremma-video` user, and `storage_dir = "/var/lib/gremma-video"`.
Set `model_path` to the absolute downloaded model directory. Make the code and
model readable by that user. Its `video`/`render` group access may need to be
extended for the installed vendor camera service (inspect that service first).

```bash
sudo useradd --system --user-group --home-dir /var/lib/gremma-video gremma-video
sudo install -d -m 0755 /etc/gremma-video
sudo install -m 0644 config.local.toml /etc/gremma-video/config.toml
sudo install -m 0644 deploy/gremma-video@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gremma-video@record gremma-video@worker
sudo journalctl -u gremma-video@record -u gremma-video@worker -f
```

For the optional receiver, configure its HTTPS URL/CA and store
`GREMMA_UPLOAD_TOKEN=...` in root-owned mode-0600 `/etc/gremma-video/upload.env`.
Enable `gremma-video@upload` only after the receiver contract is implemented.
Restart services after configuration changes. Record only in agreed locations;
this pipeline captures video without an audio track. At-rest encryption is a
separate deployment concern; local files use private permissions.
