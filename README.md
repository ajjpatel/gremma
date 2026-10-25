# Gremma

A voice-first memory assistant for older adults with low vision, built with **Gemma E4B on iPhone**.

Record or upload a video. Gremma analyzes the visible activity and lets you ask what happened or where something was last seen.

## Project components

- [iPhone app and developer guide](Gremma/README.md)
- [Android Studio app](Gremma/AndroidStudio/README.md)
- [Ventuno Q camera capture and clip selection](video_stream/README.md)

The feature and validation notes below describe the iPhone app. Each component's guide documents its own setup and integration status.

## Current app

- **Activity memory:** ordered video frames distinguish supported placements, pickups, movements, sightings, and possible medicine-taking activities. Every event retains a video reference and recording time when known.
- **Changing locations:** a later pickup invalidates an earlier location answer. Previous events remain in history; answers describe the latest evidence rather than claiming live tracking.
- **Today and history:** browse visible activities, review evidence, and play original videos. Unknown recording dates stay outside daily logs.
- **Medicine video logs:** optional local notifications at **9 AM and 9 PM** report a missing morning/evening video log. This never establishes whether medicine was taken or missed.
- **Grounded model answers:** indexed records supply the evidence, and Gemma E4B generates every memory answer. The conversation screen shows throughput, time to first token, time per output token, and total answer time.
- **Video management:** record up to 60 seconds without microphone audio, import clips up to 10 minutes, delete a video and its derived memory, or resume processing from saved activity checkpoints. Completed clips can be analyzed again; clips with no recognized activity say so explicitly.

The current pipeline analyzes video only. Silent recordings are valid; imported audio is not transcribed. The dedicated **Imagine** and **Read aloud camera** features have been removed from the interface. Spoken answers and voice control remain.

## Build

See the [developer guide](Gremma/README.md) for Xcode signing, E4B import, architecture, and tests. Model weights, recordings, and diagnostics are not distributed in this repository. Existing model downloads in another app's private storage cannot be directly shared with Gremma.

The assistant uses local processing. Setup, model downloads, and development provisioning may need internet. Full airplane-mode operation must be tested on the target phone; on-device English speech support is required.

## Prototype limits

Activity recognition samples video and can miss brief actions. Object identity and visual interpretation can be wrong. Ambiguity must stay explicit. A medicine log is video evidence, not a dose or adherence record. Visible interactions do not establish what people said or identify them.

Controlled tests exercise persistence, chronology, pickup invalidation, deletion, routing, and reminder scheduling. They do not establish real-world recognition accuracy. See the developer guide for device validation status.

**Later stage:** a Ventuno Q upload prototype is saved separately from the current user flow. Manual recording and import are the current delivery priority. The board integration has not been validated on physical hardware.
