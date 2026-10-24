# Gremma developer guide

The Android Studio project is in [`AndroidStudio/`](AndroidStudio/README.md). It is an early Android implementation; see its README for implemented features and remaining iOS parity work.

Gremma is a SwiftUI iPhone app using [Google LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM), pinned to **0.18.1**, for local Gemma conversation and vision. See the [product overview](../README.md).

## Build and sign

Requirements: an Apple Silicon Mac, Xcode with an iOS 18-or-later SDK, Python 3, Git, and Git LFS on `PATH`. The project targets **iOS 18.0** and ARM64. Physical-device testing has used an iPhone 16 Pro Max on iOS 27.0.1.

Run these commands from the repository root, using your own signing team and unique bundle identifier:

```sh
export GREMMA_DEVELOPMENT_TEAM=YOUR_TEAM_ID
export GREMMA_BUNDLE_ID=com.example.gremma
python3 Gremma/generate_project.py

GIT_LFS_SKIP_SMUDGE=1 xcodebuild \
  -resolvePackageDependencies \
  -project Gremma/Gremma.xcodeproj \
  -scheme Gremma \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -scmProvider system

./Gremma/scripts/build.sh 'id=YOUR_CONNECTED_DEVICE_ID'
```

Alternatively, open `Gremma/Gremma.xcodeproj`, select the **Gremma** scheme and your iPhone, and build in Xcode. Enable Developer Mode on the phone and check Signing & Capabilities. Xcode handles installation; the phone may require trusting the development profile.

The script regenerates the project, honors the signing overrides, and builds using the pinned dependency cache. It does not install or launch the result. Output: `.build/DerivedData/Build/Products/Debug-iphoneos/Gremma.app`. Regenerate after adding source files. Keep the dependency cache available for offline development.

The app requests the increased-memory-limit entitlement. Model size, available memory, device capabilities, and signing support affect E4B operation. E2B is a smaller alternative. Simulator builds do not establish physical-device inference performance.

## Models and offline setup

No weights are distributed here. Import compatible `.litertlm` files through **Settings → Import model file**, or copy them into the app's `Documents/Models` using file sharing and refresh the list. The runtime validates model metadata before loading. Google AI Edge Gallery's private downloads cannot be directly reused by another app.

Gemma 4 E4B is the main conversation/vision model. E2B is supported as an alternative. An embedding import/API exists, but saved-memory search currently uses names, aliases, and rooms. Semantic retrieval and local audio translation are not connected to the product flow.

Download dependencies and weights, complete Apple provisioning, and verify on-device English speech before an offline demonstration. Recognition requires on-device support rather than silently using a server. **A complete Gremma airplane-mode cold start remains unverified.**

## Architecture and recovery

`AgentCoordinator` uses one resident Gemma model to select a validated action or answer a general question. `AppController` dispatches native feature handlers. Model operations run sequentially; there are no separately resident model agents. Stop, repeat, and an applicable video retry can bypass model routing.

`ObservationService` describes an image, then extracts structured observations. Every original name/location must occur in the description. This verifies textual support, not visual truth or object identity. Repeated generic names retain all supported positions under an explicit uncertainty statement. Unsupported or malformed responses still fail validation. Retrieval favors the latest canonical name/room sighting; cross-frame identity tracking is not implemented.

Apple Vision performs OCR. Voice is English, foreground-only, and pauses listening during replies and processing. Camera capture waits for a cancellable spoken countdown. Recorded clips end after 20 seconds or an explicit Stop; imported videos can be up to 10 minutes. Indexing samples at most 12 frames.

A room is confirmed before indexing. Each frame's observations/evidence are committed as one atomic batch; a separate atomic queue write advances the checkpoint. If interrupted between writes, replay safely replaces that frame's batch. Earlier frames and the original video remain intact. The UI displays saved progress and resumes at the unfinished frame. Rejected extraction receives one bounded whole-frame retry before pausing with a reason.

Frame extraction and OCR have 30-second caller deadlines. Generation has a 90-second maximum and a 45-second no-progress limit, with up to four seconds for cancellation to drain. Loading, embeddings, and native disposal also have bounded waits. A native worker that does not return is retained safely and further Gemma requests require reopening the app. Controls are released so OCR and saved-memory tools remain available. This does not guarantee recovery from every OS or native crash.

## Storage compatibility

The displayed app and project are **Gremma**. The default installed bundle identifier remains `com.ajjkumar.aster2026` to update the existing prototype without replacing its data container. Set `GREMMA_BUNDLE_ID` for a separate installation.

Storage names `AsterMemory`, `AsterVideoQueue`, and the `Aster.selectedChatModelFilename` / `Aster.selectedEmbeddingModelFilename` preferences are intentionally retained. Renaming them independently would hide existing memories, pending videos, or model selections. Models remain in `Documents/Models`; evidence and queues are in Application Support, excluded from backup. Video deletion removes the app's copy and associated observations while preserving an original imported video in Photos.

Generated builds, models, captures, diagnostics, and local installers stay outside source control.

## Tests and validation

Run all four suites from the repository root:

```sh
./Gremma/CoreTests/run.sh
./Gremma/CoreTests/run_coordinator_boundaries.sh
./Gremma/CoreTests/run-runtime.sh
./Gremma/CoreTests/run_observation_repairs.sh
```

| Suite | Passing checks | Scope |
| --- | ---: | --- |
| Core | 78 | Retrieval, reading, decoding, video persistence and deletion |
| Coordinator boundaries | 33 | Controlled decisions and room-confirmation boundaries |
| Runtime deadlines | 10 | Injected stalls, cancellation and late completion |
| Observation scenarios | 13 | Grounding, ambiguity, repair, storage and spoken retrieval |
| **Total** | **134** | Application behavior, not a model-accuracy benchmark |

A real recording resumed after 9 of 12 sampled frames. The remaining three frames completed in about 46 seconds, producing **54 observations**, with all **40 original records** and the first nine timestamps unchanged. The final phone run produced distinct names; explicit ambiguity preservation was exercised by controlled service/storage tests. User trials also confirmed speech recognition/reply, live label reading, cancellable capture, and room confirmation.

Remaining device checks include a fresh Stop/Resume trial, import/deletion flows, varied rooms and labels, VoiceOver and large text, sustained thermal/voice behavior, and airplane-mode cold start. Implementation and controlled tests do not establish real-world accuracy.

## Local diagnostics

Normal runtime/recovery reports in `Documents/Diagnostics` contain operational metadata without raw replies or images. Optional launch arguments:

- `--gremma-diagnostics`: synthetic OCR, text, and vision checks.
- `--gremma-coordinator-diagnostics`: model decisions without executing actions.
- `--gremma-observation-diagnostics`: synthetic observations in a scratch store.
- `--gremma-voice-diagnostics`: recognizer metadata and visible developer status.
- `--gremma-resume-video JOB_ID`: resume the specified real recording and save its observations.
- `--gremma-observation-debug`: explicitly capture up to eight raw visual descriptions and extraction responses locally. Disabled normally; these records can contain details of the user's surroundings.

Synthetic diagnostics do not establish camera accuracy. A report left running indicates interruption, not necessarily a crash. Keep personal captures and raw diagnostic exports outside the repository.
