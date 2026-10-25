**Offline visual assistant — product and build plan**

October 23, 2026 · English · US dollars · Initial target: the user's iPhone

This is the current scope, incorporating the user's decision to retain the complete feature set and prioritize Record & Find, Visualization, Reading, and voice interaction. It supersedes feature-cut recommendations in [Hackathon Feasibility Review.md](<Hackathon Feasibility Review.md>); that review remains useful technical and competitive evidence. This document specifies planned work, not implemented or tested functionality.

**Product direction**

Build an offline assistant that helps blind and low-vision people remember their surroundings, access printed information, and form mental pictures through conversation. Make the demonstration visually memorable and technically convincing while preserving accessible controls and honest answers. A polished demo is a first-class deliverable. Winning one or more prizes is the objective, not a promised outcome.

All original features remain in the product scope. Build stages describe dependency order and validation; they do not silently remove features. The four named priorities receive the first complete implementations. More extensive features remain visible in the backlog with their actual platform constraints. An eight-hour event can demonstrate a subset of the completed capabilities without implying the entire product is finished.

Confirmed: team of 3–4; iPhone available for later connection; Gemma-4-E4B-it (~3.66 GB) and EmbeddingGemma-2 downloaded in AI Edge Gallery. English and USD are the selected initial language/currency. The plans identify an iPhone 16 Pro Max, but exact hardware, iOS, signing team and Gallery model artifacts still require inspection.

**Installation and hackathon entry are separate decisions**

The app can be built for the user's own iPhone without an App Store release. Xcode still needs an Apple signing account, device trust, and Developer Mode. A free Personal Team supports device testing; its profiles expire after seven days and require reinstalling. Advanced capabilities may need a different entitlement/signing configuration. Do not buy membership until an actual requirement is established. [Apple account guidance](https://developer.apple.com/help/account/basics/about-your-developer-account)

Building a personal prototype now is compatible with this plan. For hackathon submission, the organizer requires open-source code and original demonstrated work created at the event, while allowing extensions to existing projects. Preserve a clear pre-event baseline and document event-day contributions; do not portray earlier work as newly created. No App Store submission is required by the event rules reviewed. Mobile AI is the primary target and Best Use of LiteRT the additional target. Eligibility for a particular entry remains the organizer's decision. [Event](https://www.agihouse.org/events/the-google-gemma-hardware-hackathon)

**The four priority experiences**

| Experience | User's task | First complete implementation |
|---|---|---|
| Record & Find | “I recorded my kitchen. Where were my keys last seen?” | Record or import video, index selected frames locally, retain evidence and time, retrieve by name or description. |
| Imagine / Visualization | “Help me picture the Taj Mahal. Describe the layout.” | Offline fact-backed descriptions, familiar comparisons, short/detailed versions and follow-up conversation. |
| Read | “Read this medicine label. What expiry date is printed? What dollar bill is this?” | OCR-backed reading, source-preserving field extraction, explicit unclear results and USD denomination identification. |
| Voice throughout | “Find my keys. Repeat that. Read the next line. Go home.” | Shared voice routing, spoken progress and results, accessible recovery, and equivalent native controls. |

**Record & Find: genuine home-video processing**

Support both recording inside the app and importing a video selected by the user. A short room clip is the first test case; it exercises the same pipeline intended for longer home videos. Single-photo “Remember this” is an additional quick action, not a replacement for video support.

The sequence is: name the room → capture/import → select useful frames → describe visible items and landmarks with Gemma → embed searchable evidence with EmbeddingGemma 2 → persist observations → answer questions from that evidence. Save the source video, image, actual frame time, capture time when known, import time, room label and model provenance. Do not invent a historical capture date when imported metadata is unavailable.

Use asynchronous frame extraction, correct video orientation, bounded image sizes, and actual returned timestamps. Requested extraction time may differ from the returned frame. Scene-change sampling should include periodic coverage so a quiet section is not ignored. No generic detector is allowed to exclude objects such as keys simply because its label set lacks them. [Apple video-frame extraction](https://developer.apple.com/documentation/avfoundation/creating-images-from-a-video-asset)

Indexing is a foreground, resumable job. Persist per-frame progress through extraction, captioning, embedding and commit. Pause for interactive requests and backgrounding; resume without duplicate records. Show which portions are already searchable. A completed job means selected frames were processed, not that every object in the home was found.

Find combines exact labels/aliases and semantic matching. Return an observation with “last seen” wording, room, time and source image. Keep previous observations. Ask for clarification when two items match. Handle absent items and partially indexed videos explicitly. Do not assert a current location after an unseen move. User corrections and names remain distinguishable from model-generated observations.

Acceptance: portrait/landscape video; recording and import; pause/restart/resume; semantic and exact queries; similar mugs; absent object; newer observation; delete and re-query; original frame opens at the right video time. Include a fresh object placement in demo rehearsal to prove indexing is real.

**Imagine: a conversation that builds a mental picture**

The first fully supported landmark is the Taj Mahal. Bundle a sourced offline fact pack, a simple illustrative layout, and supporting vocabulary. Gemma provides a coherent verbal walkthrough: overall shape → scale → spatial arrangement → materials → a memorable detail. Offer short and detailed versions, pause/repeat, “describe that another way,” and follow-ups.

Use familiar comparisons carefully. Numeric comparisons come from known dimensions and deterministic arithmetic, not invented measurements. Separate factual geometry from illustrative analogies. For unsupported landmarks or questions, explain what is unknown and offer the available description. An English-language conversational feature does not imply universal historical knowledge.

For the visual presentation, a restrained schematic can progressively highlight the gate, garden, central building and dome as narration progresses. It is a prepared illustration linked to a sourced fact pack; it is not a live 3D reconstruction or a newly generated photograph. The spoken experience remains complete without seeing it.

Acceptance: short and detailed Taj Mahal descriptions, two relevant follow-ups, one unsupported-detail question, one verified scale comparison, repeat, pause/resume, and offline operation. Facts and narration should remain consistent across follow-ups.

**Read: medicine labels, expiry dates and USD stay in scope**

Use Apple Vision OCR as the primary evidence source. Store the recognized text, candidate confidence and bounding boxes with the image. Add capture quality checks and deterministic field parsing. Gemma can organize the response, but consequential fields must map back to actual recognized spans. A confidence value is not a probability that a label is correct. [Apple text recognition](https://developer.apple.com/documentation/vision/recognizing-text-in-images)

Medicine labels: read the printed name, strength, units and directions; preserve the original wording. Never infer missing digits, dosage instructions, patient identity, or suitability. A cropped unit, uncertain decimal or conflicting capture triggers a retake or an explicit unreadable field. The feature transcribes printed information; it does not recommend treatment or how much to take.

Expiry: preserve the printed date and label association. Distinguish an expiry date from manufacturing or lot information. For an ambiguous format such as `03/04/27`, read it as printed and ask for clarification instead of silently choosing a date. If only a month and year are printed, do not invent a day. No assertion that an item is safe to consume or use follows from reading a date.

USD: start with one banknote at a time and the seven currently issued denominations: $1, $2, $5, $10, $20, $50 and $100. Match denomination wording/numerals in context; serial numbers and unrelated digits must not become a value. Handle front/back, rotation, partial visibility and conflicting evidence. Ask for another view when needed. Denomination recognition does not authenticate a banknote. Coin recognition remains in the currency backlog with separate recognition/testing needs. [US Currency Education Program](https://www.uscurrency.gov/denominations)

Acceptance: clear sample labels; blur; cropped text; decimal/unit confusion; missing expiry; ambiguous dates; denomination examples; a serial-number distractor; no reliable result. Consequential text is spoken only after validation rather than streamed before checks finish. Demonstration fixtures should use non-personal printed examples; successful fixtures are not clinical validation.

**Voice is the interaction system**

The home screen is a conversation with one prominent Talk/Stop control. A lightweight Gemma coordinator interprets natural speech and recent context, answers general conversation, and selects focused read, remember, find, describe, or visualization handlers. All model tasks share one resident engine. People should not need to memorize feature commands; unclear intent prompts a natural clarification. Keep advanced controls in a secondary tools sheet. Runtime validation and the current implementation limits are recorded in Aster/README.md.

Once the app is open and initial system permissions are granted, each main workflow must be reachable through speech. Use a shared state machine: ready, listening, capturing, indexing, analyzing, speaking, paused and failed. Commands include record/stop recording, choose a room, indexing status, find, read, imagine, shorter/more detail, repeat, next line, back/home and delete with explicit confirmation.

Support a large talk control and an active in-app listening mode. Reliable spoken interruption during TTS is an explicit device-test requirement: manage echo and audio routing, and verify that the app does not interpret its own speech as a command. Half-duplex push-to-talk alone must not be labeled hands-free. Keep an always-available accessible stop control and recoverable states while voice interruption is being implemented.

Check on-device recognition support and assets; never silently send speech to a server. Voice-only operation applies inside our app after setup. iOS system permission dialogs and system media pickers use their own accessibility behavior. Importing through a system picker is not guaranteed to be entirely controllable by our custom command recognizer. [Apple offline speech capability](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)

Native labeled controls, VoiceOver focus, readable transcripts, adjustable speech rate, and haptic state changes remain available. Do not overlap every app announcement with VoiceOver. Test noisy-room recognition, permission denial, headphone changes, phone calls, background/foreground transitions and spoken interruption. Continuous background wake-word operation is platform-constrained and is not implied by fully voice-driven foreground interaction.

**Additional painpoints worth addressing**

These are recommended additions that reuse the four primary workflows. They do not require independent model stacks.

| Addition | Why it helps | Concrete behavior |
|---|---|---|
| Capture coaching | A person may not know the label is clipped or the camera is moving too fast. | Brief “hold steady,” “more light,” or “text is cut off” prompts with a capture-complete cue. Avoid constant chatter. |
| An adaptable reading surface | Low-vision users may prefer large text, contrast and speech together. | Reflow OCR into adjustable text, keep current-line highlighting, and offer “repeat that line.” |
| Personal labels and corrections | Similar items and personally meaningful names are difficult for generic recognition. | “Call this my travel mug” and “this is the spare key,” with persistent aliases and user-provided notes. |
| Read appliance displays | Timers and control labels are another everyday print-access task. | A Read submode for clear display text and labels; glare or ambiguous digits requests another view. No claim that the app operated a control. |

Capture guidance and personal-object workflows are supported by Microsoft's participatory Find My Things research. AFB discusses magnification, reflow and contrast for reading. RNIB documents practical audio labeling of household items. These support the needs, not a claim that our particular interface is already effective. [Microsoft research](https://www.microsoft.com/en-us/research/story/find-my-things/), [AFB reading guidance](https://www.afb.org/aw/22/7/17624), [RNIB labeling](https://www.rnib.org.uk/living-with-sight-loss/independent-living/labelling/)

Treat capture coaching and readable text as shared design requirements; add personal aliases as part of memory. Appliance display recognition expands the Read test set once its label flow works. Arrange feedback from a willing blind or low-vision user if possible; a sighted teammate using VoiceOver is useful verification but not a substitute for user research.

**The rest of the original scope remains visible**

| Capability | Planned route / constraint |
|---|---|
| On-demand scene narration | Reuse camera + Gemma, with short context-aware descriptions. |
| Hazard awareness | Separate depth/perception subsystem with validity checks and measured latency; never put Gemma in the time-critical loop. No autonomous navigation claim. |
| Daily updates | Calendar/reminders with permission; optionally use the app's own recent observations. |
| Email/message summaries | Explicitly shared/imported content first; provider APIs may be a separate connected mode. No arbitrary access to Apple Mail or iMessage databases. A networked mode cannot be presented as entirely offline. |
| Long videos / multiple rooms | Extend the same durable indexing queue, storage management, coverage reporting and cancellation. |
| Background indexing | Investigate OS-scheduled opportunities; preserve foreground resume because execution time is not guaranteed. |
| Additional languages/currencies | Add artifacts and test sets explicitly after English/USD. |
| Android / Pixel | Share schemas and prompts; platform integration remains separate. Prioritize if a device and independent developer are available. |

These are retained commitments to explore and implement where supported, not claims that every platform restriction can be overcome. Any requirement that proves unsupported will be reported explicitly rather than represented by a simulated feature.

**Technical foundation**

Native SwiftUI; AVFoundation; LiteRT-LM pinned to a tested release; Gemma 4 E4B first with E2B available as a fallback; EmbeddingGemma 2; Apple Vision; native speech/TTS; SQLite and local media files. The engine, retrieval, capture and voice layers are shared by all modes. Each mode has its own bounded conversation/history policy. Model files are imported/downloaded into our container; Gallery's private downloads are not automatically accessible. [Swift runtime](https://developers.google.com/edge/litert-lm/swift), [embedding runtime](https://developers.google.com/edge/litert-lm/embedding_models)

One scheduler prioritizes interactive work over indexing. Keep concurrency bounded. Separately define model residency: serial inference does not reduce the memory occupied by two loaded models. Test E4B and EmbeddingGemma 2 separately, then together; if needed, batch captioning and embedding with controlled unloading. Persist enough progress that switching modes never loses indexed work. No stable simultaneous-residency claim before measurement.

Use app-local media, backup exclusions appropriate to the privacy claim, no content analytics, and deletion that removes associated records, thumbnails and vectors. Handle a delete occurring during an indexing job. Record actual timings without storing private label text or home imagery in ordinary debug logs.

**Presentation: make useful behavior look impressive**

Use a coherent high-contrast visual system with large typography, a restrained accent color, clear camera framing and readable transcripts. Provide light/dark and low-motion behavior. Three primary surfaces—Remember/Find, Read and Imagine—with a persistent talk control keep the interface comprehensible.

The distinctive visuals should come from real work: a video timeline fills with processed evidence frames; a query highlights the matched observation; a reading result shows its original text crop; Imagine highlights a prepared schematic as the narration advances. Motion explains state changes and is reduced when requested. Never display fabricated confidence, speed, detected objects, progress or offline status.

An optional presentation view can expose model name, measured latency and processing counts for judges. Those engineering details do not clutter the ordinary user flow. The projected visual experience supports the same app behavior; it is not a separate canned demo.

Rehearse a three-minute sequence covering a short video scan/Find, a concise Read example, and a short Imagine follow-up, all operated through voice. Give live indexing actual time; the presenter explains the problem while measured processing progresses. Choose how many reading examples fit only after timing the device. Use workbench time for additional medicine/expiry/currency cases, missing-item behavior, persistence and deletion. Keep all features in the app even if the stage script concentrates on fewer examples.

Prepare a recording of the working custom app as contingency, with pre-indexed data clearly identified when used. Preserve a known working build, charge between demonstrations and check performance on a warmer phone. Originality and reliability matter alongside appearance; current Google samples already cover much of the generic camera/memory functionality.

**Build stages and ownership**

| Stage | Deliverable | Completion evidence |
|---|---|---|
| 1. Foundation | Xcode project, shared app state, accessible shell, model import and adapters | Builds; explicit development fixtures; initial unit checks pass. |
| 2. First iPhone checkpoint | Signing, camera, speech, E4B vision and embedding execution | Actual phone responses, timings, memory observations and offline restart. |
| 3. Shared voice + Read | Mode routing, TTS, OCR, label/date/USD logic, accessible results | Required speech routes and clear/unclear reading tests pass. |
| 4. Imagine | Sourced Taj Mahal pack, structured narration and follow-ups | Consistent offline answers, controls and unsupported-question handling. |
| 5. Record & Find | Real video capture/import, durable indexing, semantic retrieval and evidence | Pause/resume, restart, absent/duplicate items, corrections and deletion pass. |
| 6. Additional scope | Scene narration, daily updates, awareness and other retained work | Each capability earns a working status through its own tests. |
| 7. Demo release | Visual polish, measured results, recording, repository documentation | Repeated full runs and a clearly documented event contribution. |

Stages 3–5 can be developed in parallel after shared interfaces are fixed. Integrate frequently; do not leave all four experiences to be connected at the end. A team member owns runtime/camera, one owns memory/indexing, one owns Read/Imagine UI and fixtures, and product/testing/demo ownership is shared or assigned to the fourth member. Codex can implement and review these areas, but one physical phone remains a shared testing resource.

Prepare the project, compile integrations, test persistence/parsers/video fixtures and build the UI before requesting the phone. Then connect it as soon as the installable shell/runtime integration is ready. Do not wait for every feature to be complete before discovering a signing or memory problem. Simulator fixtures must be labeled development-only and never presented as live model execution.

The event's short build window does not make all retained scope an eight-hour guarantee. Keep every item visible; report working, partially working, and unverified states honestly. Time decisions choose what to integrate and demonstrate next, not what to pretend is finished.

**Definition of a demo-ready build**

All four priority modes work from a real input to a useful output on the phone. Recorded observations survive restart; reading preserves source information; visualization follows its fact pack; voice reaches every main workflow after setup. The app has usable failed/unknown/cancelled states, and critical flows work offline. E4B and embedding memory behavior is measured. No invented answers, model metrics or preloaded records are passed off as fresh results.

Measure load time, indexing throughput, first useful speech, retrieval time, errors, and repeated-run degradation. Separate correct answers, correct refusals, wrong answers, unnecessary refusals and runtime failures. Keep a regression set for each mode. A small demo test set establishes demo readiness, not general safety or accessibility validation.

No app implementation or device verification is claimed by this planning document. The immediate implementation milestone is the buildable native foundation, followed by the first physical-device checkpoint.
