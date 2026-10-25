# Gremma developer guide

The Android Studio project is in [`AndroidStudio/`](AndroidStudio/README.md). It is an early Android implementation; see its README for implemented features and remaining iOS parity work.

Native SwiftUI iPhone app with [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) **0.18.1** and Gemma **E4B** for visual activity analysis. Apple Speech provides on-device English voice input; speech synthesis reads answers aloud. Video indexing does not transcribe audio. See the [product overview](../README.md).

## Build and run

Requirements: Apple Silicon Mac, Xcode with an iOS 18-or-later SDK, Python 3, Git, and Git LFS. Target iOS 18+. Physical-device checks use an iPhone 16 Pro Max.

From the repository root, configure your signing identity:

```sh
export GREMMA_DEVELOPMENT_TEAM=YOUR_TEAM_ID
export GREMMA_BUNDLE_ID=com.example.gremma
python3 Gremma/generate_project.py
GIT_LFS_SKIP_SMUDGE=1 xcodebuild -resolvePackageDependencies \
  -project Gremma/Gremma.xcodeproj -scheme Gremma \
  -clonedSourcePackagesDirPath .build/SourcePackages -scmProvider system
./Gremma/scripts/build.sh 'id=YOUR_CONNECTED_DEVICE_ID'
```

Alternatively open `Gremma/Gremma.xcodeproj`, select the Gremma scheme and iPhone, then build/run. Enable Developer Mode and complete Xcode's signing/trust steps. The script builds but does not install. Its product is `.build/DerivedData/Build/Products/Debug-iphoneos/Gremma.app`.

Regenerate the project after adding Swift files. Keep downloaded dependencies for offline development. The app requests the increased-memory-limit entitlement for E4B.

## Models and permissions

Import the compatible E4B `.litertlm` file in local-model settings or copy it into the app's `Documents/Models` via file sharing. The app selects E4B only; smaller models already downloaded are retained but not used. Weights are excluded from Git. AI Edge Gallery downloads are in that app's private container, so Gremma needs its own copy.

Grant camera access to record activities. New recordings contain video only and require no microphone permission. Microphone and speech permissions are used by the separate Talk to Gremma controls, which require on-device English recognition and never fall back to a cloud recognizer. Imported clips may contain audio, but activity indexing ignores it. Enable medicine video-log reminders separately in the app and allow iOS notifications.

## How activity memory works

1. Keep the original video locally, preserving its bytes. Establish recording time from an app recording, container metadata, or an explicit date entered before processing. Import time is a separate value.
2. Analyze six-second windows using six chronological full-scene samples and preceding context. A short E4B prompt describes the main activity; a second constrained extraction records one continuous activity and, when supported, one distinct transition. Full-scene input preserves household context that hand crops can lose. Unstated timestamps use the window's range. Alternative directions, such as an object being placed or taken away, remain uncertain and cannot update its location. A disappearance alone must not establish pickup. The model uses its highest supported vision budget (280 tokens per image for the downloaded E4B). Invalid structured output gets one text-only repair; if validation still fails, the visual description is saved as an explicitly uncertain, unclassified note. Such notes never update item location or medicine status. Native inference or storage failures retain resumable progress. Optional hand-crop probes remain explicit diagnostics, not the normal indexing path.
3. Commit each segment transactionally into SQLite before advancing its queue checkpoint. Stable segment IDs make a replay replace its prior batch without duplicating it. Earlier segments survive cancellation and failure.
4. Query entity/time indexes for common factual questions, then have E4B generate a concise answer from the resolved evidence. Broader requests use a short E4B decision prompt and bounded retrieval. Retrieval never rereads the source video to answer a simple stored-fact question; evidence thumbnails are loaded after starting the spoken answer.

Completion depends only on visual activity segments. Silent video needs no special handling and never waits for speech recognition. A completed clip with no events is labeled **Analyzed · no clear activity found**. **Analyze again** reprocesses the saved source, replacing each segment only when its new analysis is committed.

Activity history and latest known state are separate concepts. A pickup supersedes the earlier location; it does not erase the placement. Out-of-order uploads use occurrence time, never arrival time. Unknown dates cannot satisfy a daily medicine log. Ambiguous entity matches do not silently merge different keys or wallets.

Deletion removes the source video and its associated derived records, including any older stored transcripts or observations. Session conversation and spoken-repeat caches are cleared to avoid retaining deleted evidence. The original imported video in Photos remains untouched.

Public sample clips are explicitly marked **Demo footage** and have unknown recording dates. The user's focused collection is configured in `Documents/FocusCollection.json`: keys, glasses, wallet handling, TV remote, and eating. Ordinary object/activity questions may retrieve selected sample clips when no matching personal evidence exists; answers identify sample footage and describe only the visible state. Personal evidence takes priority. Samples cannot satisfy personal daily logs, date-specific questions, or medicine reminders. Other recordings stay saved behind “Show all recordings” in the video library.

Explicit user corrections carry separate `user_confirmed` provenance. The timeline and location answer identify those labels as user-confirmed rather than autonomous recognition. They remain linked to their source video, survive model reanalysis, and are removed when that video is deleted. A later observed pickup can still supersede an earlier confirmed placement.

The connected-device developer importer reads `Documents/DemoImports/manifest.json` plus its MP4/MOV files when launched with `--gremma-import-demos`. It stores all originals before indexing them sequentially and resumes incomplete segments. Content hashes prevent duplicate imports even if the manifest is reordered. The manifest's activity titles and reviewer answers are never supplied to vision inference. Downloaded videos and private diagnostic reports stay outside Git. An explicit `--gremma-verify-demo-recall` run checks every imported demo through the normal text-input controller; it does not test microphone recognition or write new activity facts.

## Reminder semantics

Morning is midnight–noon; evening is noon–midnight in the phone's current timezone. Checks occur at **9 AM and 9 PM**. A clear video tagged as medicine-taking suppresses the corresponding upcoming check; uncertain evidence is described as uncertain. No log never means a missed dose.

Notifications are scheduled for seven calendar days, refreshed when Gremma opens or its activity data changes. The UI displays the scheduling horizon. The app cannot run continuous inference while closed; reminders use iOS local notifications, not a background model.

## Storage compatibility and recovery

The default bundle ID remains `com.ajjkumar.aster2026` to update the original prototype without replacing its container. Set `GREMMA_BUNDLE_ID` only for a separate installation.

Legacy `AsterMemory`, `AsterVideoQueue`, and model-selection keys remain intact. New activity data uses `GremmaActivity/activities.sqlite`. Existing sightings are preserved as older photo/frame memories; they are not silently converted into actions. Existing videos can be processed through the new activity pipeline after setting a trustworthy recording date.

Activity progress is separate from the old per-frame progress. Historical audio checkpoints and transcripts remain stored for compatibility; the current pipeline does not process or display transcripts, and old audio errors cannot block a visually completed clip. Existing data is preserved. Failed visual work resumes at the unfinished segment. Timeouts and cancellation release the interface. If a native model call remains stuck after cancellation, the app requires reopening before further Gemma inference, including memory answers; saved records remain available in the timeline.

## Validation

Run from the repository root:

```sh
./Gremma/CoreTests/run.sh
./Gremma/CoreTests/run-runtime.sh
./Gremma/CoreTests/run_observation_repairs.sh
./Gremma/CoreTests/run_coordinator_boundaries.sh
./Gremma/CoreTests/run-activity.sh
./Gremma/CoreTests/run-temporal-video.sh
./Gremma/CoreTests/run-activity-routing.sh
./Gremma/CoreTests/run-reminders.sh
./Gremma/CoreTests/run-video-speech-policy.sh
```

These cover legacy compatibility plus activity transactions, chronology, identity ambiguity, pickups, deletion, medicine windows/DST, routing, and temporal extraction validation. Controlled model tests do not establish vision accuracy.

Device checks on 24 October 2026 verified E4B six-frame video processing and saved-memory retrieval. The user's wide-room clip did not automatically identify the small keys. At the user's explicit request, it now has a separately marked user-confirmed keys-placement record with the video-observed windowsill location. The normal controller returned that location with evidence in 0.224 seconds (SQLite lookup: 0.003 seconds), and the user confirmed the spoken answer and video evidence on the phone. This validates retrieval of the confirmed record, not automatic key recognition. The 15 imported household samples and their individual recognition/answer results are tracked in [the activity test plan](docs/HOUSEHOLD_ACTIVITY_TEST_PLAN.md).

Complete automatic placement/pickup recognition, a fresh video-only camera recording, and the full airplane-mode flow still need physical-device validation. Use a visible placement followed by pickup in separate clips, ask about the location after each, and inspect the source evidence. Test both fresh silent recordings and imported clips with known dates. Uncertain visual notes remain searchable but cannot establish a confident item location or medicine log. Keep a non-medication prop for a staged medicine-log demo.

An earlier installed build completed 18 controller-level saved-memory checks without execution errors or opening the camera/library. Keys returned in 0.109 seconds from a direct lookup; the 15 numbered demo summaries took 3.26–7.85 seconds (median 4.53 seconds). These historical timings exclude speech recognition and playback and predate the model-only memory answer path below. Numbered retrieval succeeded, but answers repeated recognition errors in several clips; the natural utensils query found no matching answer. A deterministic spoken prefix preserves uncertainty whenever the supplied video evidence contains uncertain records. All 15 sources were present during that run, and demo footage was excluded from the personal daily-history check. See the test plan for individual accuracy limits; passing the controller checks does not establish reliable activity recognition.

Normal operational diagnostics contain metadata. Explicit synthetic diagnostics use temporary stores and synthetic fixtures; they must not be described as real-world accuracy tests. Optional raw observation debug reports can contain personal surroundings and stay local, outside Git.

## Deferred hardware integration

A prototype uploader and local receiver for Arduino VENTUNO Q are retained for later work. They are not exposed in the current app flow, and no physical-board integration is claimed. See `scripts/VENTUNO_UPLOAD.md` for the provisional interface. Current priority is recording, manual upload, and reliable app behavior.

## Focused conversation UI and performance

The main screen shows the question, answer, expandable evidence, voice controls, and response metrics. Video recovery, medicine overview, and developer panels no longer occupy the conversation screen; recording, import, library, reminders, and model settings are in the menu.

The initial focused run on 24 October 2026 completed all seven natural questions without empty answers, errors, or capture/library misroutes. The five core questions are keys, wallet, glasses, TV remote, and eating; passport and eating-today checks correctly found no matching evidence. That build used direct database answers for keys and missing records. The updated path now sends every activity-memory answer through E4B, including keys, medicine logs and missing evidence. Retrieval still resolves item chronology and medicine time windows before generation. Focused sample footage is used only when eligible personal evidence is missing. The model stays loaded between requests; short text-only evidence and concise output avoid repeating vision analysis.

TPUT comes from LiteRT-LM's native decode tokens/second, enabled through its benchmark instrumentation; no synthetic benchmark, character estimate, or stream-chunk token count is used. TTFT measures first generated text arriving at the app relative to accepted question input, including routing/loading. TPOT replaces TTLT in the UI: `(last text arrival - first text arrival) / (native output token count - 1)`, displayed in milliseconds; fewer than two tokens or missing/invalid timing yields a dash. Arrival timings do not mean incremental text was displayed. Answer time ends when the final answer is ready, before speech playback and optional evidence-image decoding. Fixed interface confirmations can still display dashes for token metrics; prior-query metrics are rejected.

The user's 15-second Office recording from 24 October at 5:35 PM is explicitly labeled as a user-confirmed medicine-taking video. It satisfies that evening's video-log check; the record does not identify a medication or dose. This annotation is not an automatic vision-recognition result.

The subsequent model-only recall check completed six real-device questions with nonempty answers, positive native output-token counts, TPOT values, and no capture/library misroutes. The first keys query took 5.25 s including loading; the five warm requests took 1.41–2.92 s, with TPOT 43.7–45.8 ms/token. The keys answer retained the windowsill/living-room fact, and the medicine answer reported a video log. 51 activity/metrics tests and 71 routing checks passed. Measurements vary with output length and device state. The glasses and eating sample IDs are absent from the later queue/database snapshot; the glasses query correctly returned no saved evidence. No missing recordings were recreated.
