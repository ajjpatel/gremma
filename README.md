# Gremma

Local AI for older adults and people with low vision, built around **Google Gemma 4 E4B** on iPhone.

Gremma is a native SwiftUI prototype for a voice-led assistant that remembers where objects were seen, reads physical text aloud, and helps someone picture a place. Conversation and image understanding run through local Gemma; Apple Vision handles text recognition.

## Features

- **Record & Find:** record a room or import a video, confirm its room name, then ask where an item was last seen. Saved results include image evidence and video timestamps.
- **Remember a photo:** save visible objects and their reported locations; search, correct, or delete observations.
- **Read aloud:** read printed text, medicine labels, expiry markings, and US dollar denominations. The live camera waits for a tap, speaks a countdown, and supports cancellation.
- **Imagine:** hear guided Taj Mahal descriptions and ask questions using a bundled UNESCO fact pack.
- **Natural conversation:** speak or type freely. A local decision handler routes feature requests; general questions remain conversation.
- **Resume interrupted work:** completed video frames are saved, and retry continues at the unfinished frame. Ambiguous positions remain explicitly uncertain.

The current language is **English**, with **US dollars** for currency reading. Recognition and spoken replies take turns while the app is in the foreground. Typed input and accessible controls are also available.

## Get started

You need an Apple Silicon Mac, Xcode with an iOS 18-or-later SDK, and an iPhone running iOS 18 or later. Follow the [developer guide](Gremma/README.md) to configure signing, build the app, import a model, and run tests.

Model weights are **not included**. Import a compatible Gemma 4 E4B `.litertlm` file through model settings; E2B is a smaller alternative. Google AI Edge Gallery downloads remain in that app's private storage, so Gremma needs its own imported copy.

Dependencies, model downloads, and Apple development provisioning can require internet during setup. The implemented assistant flows make no app network requests. A complete airplane-mode cold-start trial remains pending.

## Validation and limits

**134 automated checks pass:** 78 core tests, 33 controlled routing checks, 10 deadline/cancellation tests, and 13 observation/storage scenarios. Controlled model responses test application behavior, not model accuracy.

Real iPhone trials confirmed speech recognition and replies, live camera reading, cancellable capture, and room confirmation. One failed recording recovered from frame 10 to **12/12 completed frames and 54 observations**, preserving all 40 earlier observations unchanged.

This is a hackathon prototype. Videos sample at most 12 frames and can miss objects. Visual descriptions and OCR can be wrong; locations are last-seen observations, not live tracking. Reading does not provide medicine advice or authenticate currency, and the app is not a navigation system. Broader accuracy, sustained voice use, and airplane-mode cold start still need testing with intended users.
