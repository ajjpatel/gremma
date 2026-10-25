# Model readiness

Verified October 23, 2026, Pacific time. **Five files downloaded and verified: 6,947,966,825 bytes (6.95 GB).** Every file matches both the exact size and SHA-256 published in its Hugging Face repository's LFS metadata. Downloads use pinned repository revisions and required no account or token. This proves file integrity; it does not prove inference quality or iPhone performance.

| Local model file | Bytes | Status | SHA-256 |
|---|---:|---|---|
| [Gemma 4 E4B primary](/Users/ajjkumarp/Documents/Personal/Extras/Hackathon-Gemma/.models/gemma-4-E4B-it.litertlm) | 3,659,530,240 | verified | `0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0` |
| [Gemma 4 E2B fallback](/Users/ajjkumarp/Documents/Personal/Extras/Hackathon-Gemma/.models/gemma-4-E2B-it.litertlm) | 2,588,147,712 | verified | `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c` |
| [EmbeddingGemma 2 text/vision 440M](/Users/ajjkumarp/Documents/Personal/Extras/Hackathon-Gemma/.models/embeddinggemma-2-text-vision-440m.litertlm) | 387,710,976 | verified | `92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0` |
| [EmbeddingGemma 2 text 270M fallback](/Users/ajjkumarp/Documents/Personal/Extras/Hackathon-Gemma/.models/embeddinggemma-2-text-270m.litertlm) | 164,626,432 | verified | `2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb` |
| [Whisper base multilingual (future)](/Users/ajjkumarp/Documents/Personal/Extras/Hackathon-Gemma/.models/audio/ggml-base.bin) | 147,951,465 | verified | `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe` |

The full machine-readable record contains each exact filename, revision, public download URL, expected/actual hash and local path: [manifest.json](/Users/ajjkumarp/Documents/Personal/Extras/Hackathon-Gemma/.models/manifest.json). Audio also has its own [manifest](/Users/ajjkumarp/Documents/Personal/Extras/Hackathon-Gemma/.models/audio/manifest.json). The Gemma files are generic CPU/GPU `.litertlm` builds, not chip-specific or web variants. The Whisper file is a `whisper.cpp` GGML model, not a LiteRT-LM model.

**Sources and licenses.** Original model cards are the licensing authority: [Gemma 4 E4B](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm), [Gemma 4 E2B](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm), [EmbeddingGemma 2 text/vision](https://huggingface.co/litert-community/embeddinggemma-2-text-vision-440m-litert-lm), [EmbeddingGemma 2 text](https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm), and [Whisper conversion](https://huggingface.co/ggerganov/whisper.cpp). Their public card metadata declares Apache-2.0 for the four Gemma artifacts and MIT for Whisper. Preserve applicable notices if distributing models. Keep the weights and build caches out of Git and shared project attachments; `.gitignore` excludes `.models/` and `.build/`.

**Current app readiness.** The app contains chat/vision and text-embedding API integration, with LiteRT-LM pinned to **v0.18.1**, commit `bda624851d74be34d4e1f7fac1fc4155939539c7`. E2B and E4B have completed controlled text and synthetic-image inference on the iPhone 16 Pro Max. E4B selected the expected actions in all 14 fixed coordinator cases, including conversational recall and a three-exchange follow-up. With the increased-memory entitlement and two-stage observation extraction, E4B also passed the three synthetic object/shape/blank checks; nonempty results passed isolated save, reopen, search, and image-evidence checks. E4B is selected in the installed normal app. These are small fixture sets, not a general accuracy claim. The user has now confirmed a real Hello → recognized text → spoken reply and live camera preview → captured text read aloud. Speech requests require on-device recognition in code. Embeddings, broader visual accuracy, sustained memory/thermal behavior, and Aster's airplane-mode restart still require device testing. See Aster/README.md for measured results and limitations. Image embedding remains an available runtime capability; the current app embedding call uses text. [Google embedding API](https://developers.google.com/edge/litert-lm/embedding_models)

**Audio is reserved for a future feature.** The generic E4B model already includes audio weights. The installed v0.18.1 Swift source exposes `Content.audioFile`, `Content.audioData`, and an `audioBackend` configuration; the audio executor is disabled when that backend is nil. Google's [Swift audio example](https://developers.google.com/edge/litert-lm/swift#Audio_Input) documents transcription. Aster does not currently wire audio files into Gemma or include a Whisper runtime. Its voice commands use Apple's on-device speech recognizer. Whisper base is a small, multilingual specialist fallback with an [iOS/Swift implementation route](https://github.com/ggml-org/whisper.cpp). Whisper's translation task outputs English; another target language requires a text-translation stage such as Gemma. [Whisper task scope](https://github.com/openai/whisper#command-line-usage)

**Getting models onto the phone.** AI Edge Gallery owns its private app container. Its downloaded weights cannot be opened directly by Aster; our app needs its own imported or copied files. Import the chosen chat model plus the selected embedding model, and allow storage for model copies and caches. The E2B and text-only files are fallback options, not a requirement to keep all models loaded. Keep Whisper on the Mac until a compatible runtime is implemented.

**Offline development cache.** [SourcePackages](/Users/ajjkumarp/Documents/Personal/Extras/Hackathon-Gemma/.build/SourcePackages) contains the LiteRT-LM checkout and iOS/macOS XCFramework artifacts. A project-local [git-lfs 3.8.1 executable](/Users/ajjkumarp/Documents/Personal/Extras/Hackathon-Gemma/.build/tools/git-lfs) is available; its [installation record](/Users/ajjkumarp/Documents/Personal/Extras/Hackathon-Gemma/.build/tools/git-lfs-install.json) records a verified release-archive checksum, not a verified signature. Preserve these folders for tomorrow. Cache presence does not guarantee that adding or updating dependencies will work offline; keep the pinned version and prove an offline build before relying on it.

**Connected-device check.** The iPhone is confirmed as an iPhone 16 Pro Max running iOS 27.0.1, paired by USB, with Developer Mode enabled. The earlier `connected (no DDI)` condition cleared: a subsequent `device info details` query automatically completed Apple's developer-disk personalization/installation, and the final device list reports `connected`, `ddiServicesAvailable=true`, readiness state 7. The phone reported no passcode requirement. No device or Xcode restart/reset was performed for this audit. Signing and app execution are separate checks; the DDI condition alone no longer requires user action. [Apple Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device), [Apple component guidance](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)

**Recheck every downloaded file without network access:**

```sh
python3 - <<'PYVERIFY'
import hashlib, json
from pathlib import Path
root = Path('/Users/ajjkumarp/Documents/Personal/Extras/Hackathon-Gemma/.models')
manifest = json.loads((root / 'manifest.json').read_text())
for model in manifest['models']:
    path = root / model['filename']
    assert path.stat().st_size == model['expected_size_bytes'], path
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            digest.update(block)
    assert digest.hexdigest() == model['expected_sha256'], path
    print('VERIFIED', model['filename'])
PYVERIFY
```
