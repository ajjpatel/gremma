# Gremma household activity video corpus

## Current focus: five recordings and natural questions

Updated 24 October 2026. The active collection is now the original keys recording plus glasses, wallet handling, TV remote, and eating. Other recordings remain saved but are outside the focused collection. No clip numbers or “demo” phrasing are required in questions.

| Ask | Verified answer content / limit |
|---|---|
| “Where are my keys?” | Windowsill in the living room, from the user's explicitly confirmed label and saved video evidence. |
| “Where is my wallet?” | A black wallet is being held in hands in the saved sample video. It does not establish a later storage location. |
| “Where are my glasses?” | Glasses end up on the person's face in the saved sample video. No later location is visible. |
| “Where is the TV remote?” | A hand holds the remote near the television in the saved sample video. |
| “Have I eaten?” | The saved sample shows someone cutting food and eating. It does not establish that the user ate today. |

All five returned nonempty answers through the normal controller in the initial focused test. “Where is my passport?” and “Did I eat today?” correctly returned no matching saved evidence. These were controller tests; the user should also try the same phrases by voice. Saved uncertainty and sample-source labels are preserved. The main screen has Q&A and a bottom TPUT/TTFT/TPOT/Answer strip; tools are under the menu. The updated answer path uses E4B for all memory answers, including keys and missing evidence, rather than returning database text directly.

The newly uploaded personal Office video from 24 October at 5:35 PM has the user's confirmed medicine-taking label. Ask “Did I take my medicine this evening?” The expected answer is that a medicine-taking video is logged; it must not invent the medication or dose. This personal video is additional to the five-clip focus and is visible in the library.

Later-state note: the glasses and eating sample recordings are absent from the phone's queue/database snapshot taken after the medicine upload. Their initial results above describe the earlier test collection. The final E4B check correctly answered the glasses question with no saved evidence; the absent clips were not restored. Keys, medicine and wallet answers were verified using the final model-generated path.

The user's newly authorized fallback is a clearly identified activity annotation when recognition fails. It must remain distinguishable from automatic inference, as with the existing confirmed keys label. The other four selected clips currently use their actual saved model descriptions; no new activity annotations were needed for this run.

The larger research collection below is retained as history and is no longer the immediate test scope.

Research checked 24 October 2026. These are proposed evaluation cases, not recognition capabilities already validated on E4B. The current app analyzes silent visual activity; it does not need narration.

Start with self-recorded clips using consenting team members. This gives known object identity, recording time, location, and before/after state. Uploading/indexing the clips creates searchable memories; it does not train Gemma or automatically improve recognition.

## Why these cases

Misplaced everyday belongings are a concrete memory problem: the National Institute on Aging specifically discusses keeping keys, wallets/purses, phones, and glasses in consistent places. This supports prioritizing item-location memory without implying that all older people have cognitive impairment. [NIA: Memory Problems, Forgetfulness, and Aging](https://www.nia.nih.gov/health/memory-loss-and-forgetfulness/memory-forgetfulness-and-aging-whats-normal-and-whats-not)

Primary research with blind participants reports difficulty locating misplaced objects and practical information needs during domestic activities. Its findings support object retrieval and household routines as useful test categories; they do not validate this app. [Turkstra et al., Assistive technology use in domestic activities by people who are blind](https://arxiv.org/abs/2305.03019)

Low-vision guidance covers organizing the kitchen, household cleaning, clothing, and medication labeling. A real-life low-vision study also found many attended objects were small and within reach, which argues for clear hand/object framing rather than wide room shots. [Wisconsin DHS](https://www.dhs.wisconsin.gov/obvi/eyediseases/living-lowvision.htm), [Real-life visual-demands study](https://pmc.ncbi.nlm.nih.gov/articles/PMC7476655/)

## Fifteen proposed activities

All recording scripts are silent, normally 6–10 seconds. “Expected answer” is a test oracle after the visible event has actually been recognized and saved; it is not a claim about current model accuracy. Times should be real recording times, shown as [time] below.

| Priority | Activity / pain point | What to film | Expected stored evidence and test question | Honest expected answer / limit |
|---|---|---|---|---|
| 1 | Place and later pick up keys; finding an essential item | Clip A: show keys, place on a clear tray, release hand and hold view. Clip B later: lift those keys and leave view. | `placed(keys, tray)` then `picked_up(keys)`; “Where are my keys?” | After A: “Last seen on the tray at [time].” After B: “Picked up at [time]; I haven't seen where they went next.” Small-object identity is currently a hard case. |
| 2 | Put glasses beside the bed; finding a visual aid | Set a distinct glasses frame beside a closed book; later pick it up. | `placed(glasses, bedside table)`; “Where did I leave my glasses?” | “Last seen beside the book on the bedside table at [time].” Must distinguish glasses from their case. |
| 3 | Put phone down / on a charger; locating communication device | Place a phone on a visibly distinct desk or charging pad; show the hand leaving. | `placed(phone, desk/pad)`; “Where is my phone?” | “Last seen on the desk/charging pad at [time].” Do not infer the phone is charging from placement alone. |
| 4 | Put wallet or purse away; finding essentials before leaving | Put wallet in an open basket, keeping it visible after release. | `placed(wallet, basket)`; “Where did I put my wallet?” | “Last seen in the basket at [time].” Use an open container before testing opaque drawers. |
| 5 | Move remote between sofa and side table; latest location | A: remote placed on sofa. B later: same remote moved to table. | Two dated placements; “Where is the remote now?” | “Most recently seen on the side table at [time].” An old clip imported later must not override newer recording time. |
| 6 | Park a cane or walking aid; finding an aid | Place an available cane beside an armchair, or park a walker there. | `placed/moved(cane or walker, beside chair)`; “Where is my cane?” | “Last seen beside the armchair at [time].” A large, visible prop should be easier than keys; no navigation instructions. |
| 7 | Put mail in a tray/folder; finding documents | Place blank envelopes into an open tray; show the final position. | `placed(envelopes, tray)`; “Where did I put the mail?” | “Last seen in the tray at [time].” Do not claim bill contents, payment, or a deadline. |
| 8 | Put groceries into a refrigerator; remembering storage | Show a distinctive carton/bottle, place it on a visible shelf, then withdraw hand. | `placed(carton/bottle, refrigerator shelf)`; “Where did I put the milk?” | Name milk only if visually identifiable; otherwise “The carton was last seen on the refrigerator shelf.” Do not infer freshness or safe temperature. Occlusion makes this a harder test. |
| 9 | Eat from a plate; recalling a daily routine | Show plate and spoon, then a clear spoon-to-mouth action. | `other(eating from plate)` with time; “Do I have a lunch video today?” | “A video at [time] shows eating from a plate.” It does not prove a complete meal, quantity, or nutrition. |
| 10 | Drink from a cup; recalling a routine | Lift a large contrasting cup to mouth, then put it down. | `other(drinking from cup)` and possibly `placed(cup, table)`; “When was drinking last recorded?” | “The last video showing a drink from a cup was at [time].” No claim about fluid identity, amount, or hydration. |
| 11 | Wash a cup/dish; remembering a chore | At the sink, visibly scrub/rinse one mug, then place it on a drying rack. | `other(washing mug)` plus possible `placed(mug, rack)`; “Did I record washing the mug?” | “A video at [time] shows the mug being washed.” Not proof of sanitization. |
| 12 | Fold and put away laundry; remembering a chore/location | Fold one contrasting towel, put it into an open basket. | `other(folding towel)` and `placed(towel, basket)`; “What did I do with the laundry?” | “The video shows a towel being folded and placed in the basket.” Not proof that all laundry is finished. |
| 13 | Water a houseplant; avoiding forgotten/repeated chores | Pour from a watering can into one clearly visible plant pot. | `other(watering plant)` with time; “When did I last water the plant?” | “The latest video showing watering this plant was at [time].” No recommendation to water again or judgment of amount. |
| 14 | Medicine-taking video log; checking for a missing log | Use a clearly staged, non-medication prop with visible organizer context and a hand-to-mouth gesture; no real drug ingestion for the demo. | A possible medicine-taking video event; “Is there a medicine-taking video this morning?” | “A medicine-taking video was logged at [time]” or “No medicine-taking video is logged.” Never “you took/missed your dose.” A bottle held in a hand alone must not pass. This is a high-uncertainty case and must be labeled as a staged demo. |
| 15 | Another person arrives / people interact; recalling a social event | Two consenting teammates greet one another and sit together. | `other(visible greeting/interaction)`; “Was anyone here earlier?” | “A video at [time] shows two people interacting.” No inferred names, relationship, spoken words, or verified visitor identity. |

Suggested first demo set: keys placement/pickup, remote relocation, glasses placement, watering a plant, folding a towel. Add the medicine-log case only after its positive and negative cases are checked. Larger contrasting objects are candidate easier cases, not guaranteed successes.

## Recording and indexing protocol

- Film one principal action per clip: about 2 seconds before, 2–4 seconds during the action, and 2–3 seconds after release/contact. Keep the hand, object, and destination visible together. This is a proposed capture protocol, not a model requirement that should be forced onto an older user.
- Use a steady camera, normal indoor light, and visible contrast. Avoid starting with tiny objects at the far side of a room. Retain a wide-view version as a separate robustness test instead of silently replacing it with an easy version.
- For object updates, record separate placement and pickup/move clips of the same item. Do not combine several similar objects in the first evaluation.
- Keep the actual recording time. Do not assign today's date to stock footage to make a daily log appear complete. If its date is unknown, use undated/general-history evaluation.
- Keep a small manifest outside the model prompt: filename, actual recording time, room, true object, true action, destination, expected final state. The manifest is the evaluator's ground truth, not an answer injected into Gemma.
- Validate identity, action, destination, and timestamp separately. Recognizing a key is not proof of placing it; finding it in the final frame alone supports a sighting.
- After pickup, require the answer to stop asserting the old location. Then upload an older placement clip after the pickup and check that import order does not roll back the latest state.
- Delete one video and verify its linked events disappear. Any answer based on older remaining evidence should retain its older timestamp.
- Include a negative clip: a hand passes over the object without lifting it; a medicine bottle is held without a taking gesture; an empty surface contains no item. None should become a completed action.

## Downloaded demo clips: phone numbers 1–15

Updated 24 October 2026. All 15 silent demo clips have been copied to and registered in Gremma on the connected iPhone. Their numbers below follow `demoNumber` in `.build/demo-videos/all-manifest.json` exactly. **These are phone clip numbers, not the priority numbers in the proposed-activities table above.**

**All 15 clips completed indexing on the iPhone without a job error. Recognition remains inconsistent.** Clips 4–15 received one analysis pass; clips 1 and 3 were reanalyzed using the current prompt, and clip 2 retains its earlier watering analysis. The saved results below were compared with decoded source frames on 24 October 2026. The final installed build completed eighteen questions through the normal app controller without execution errors or opening the camera/library. This verifies routing and completion, not answer accuracy; several answers repeat the recognition errors below. The user has confirmed that the original personal-key answer and evidence image work. That personal key identity/action was explicitly confirmed by the user, so it is not an autonomous key-recognition success.

The source/download checks and local contact-sheet inspections are complete. Six exact decoded frames were inspected per exported clip for 1–9, and twelve for 10–15. This verifies that the test inputs contain the stated visible actions; it does not establish E4B accuracy. All outputs have zero audio tracks. Clips 1–3 are 10 seconds long; clip 4 is 5.625 seconds; clips 5–15 are approximately 5.8 seconds. The shorter segments were selected after inspecting the action, and are intended to fit one six-second inference window.

Use the numbered question first to test whether Gremma can retrieve the correct recording. Then use the natural question to test activity-based retrieval. The visible-evidence column is the evaluator's reference, not text to inject into Gemma or prepopulate as an activity record. If a clip is unindexed or unclear, an honest incomplete/uncertain answer is preferable to an invented event.

| Phone clip | Source footage and creator credit | What the exported clip actually shows / limit | Questions to ask aloud |
|---|---|---|---|
| 1 | [Folding clothes — Sarah Chai](https://www.pexels.com/video/woman-folding-clothes-7279093/) | A seated person folds small clothing on a table beside a laundry basket. No wardrobe storage or completion of all laundry. | “What happened in demo clip 1?” / “Was someone folding clothes in the demo videos?” |
| 2 | [Watering flowers — Coverr](https://www.pexels.com/video/watering-plants-854161/) | Water pours from a watering can onto flowering plants outdoors. This is garden watering, not specifically an indoor houseplant; water amount and adequacy are unknown. | “What happened in demo clip 2?” / “What was used to water the flowers in the demo footage?” |
| 3 | [Washing utensils — Engin Akyurt](https://www.pexels.com/video/a-person-washing-dishes-4319304/) | Hands wash cutlery with a soapy sponge at a sink and place utensils in a nearby glass. This does not prove all dishes were washed or sanitized. | “What happened in demo clip 3?” / “What was being cleaned at the sink in demo clip 3?” |
| 4 | [Placing a car-key fob — Anastasia Shuraeva](https://www.pexels.com/video/leaving-keys-on-the-table-4513069/) | A hand puts a key fob attached to a dark leather key case onto a pale marble-like surface, then withdraws. No later pickup; this close-up is a separate test from the user's earlier small-key recording. | “What happened in demo clip 4?” / “Where was the key fob placed in the demo footage?” |
| 5 | [Putting on eyeglasses — Kaboompics](https://www.pexels.com/video/a-close-up-of-a-woman-putting-on-eyeglasses-8547606/) | A person puts glasses onto their face, adjusts them, and lowers their hands. This substitutes wearing glasses for the planned furniture-placement case. | “What happened in demo clip 5?” / “What did the person do with the glasses in demo clip 5?” |
| 6 | [Placing a phone on a table — cottonbro studio](https://www.pexels.com/video/a-person-using-his-phone-and-putting-it-on-the-table-7223986/) | A hand leaves a phone screen-up on a light wooden tabletop beside a dark bowl and green tray. No charging or phone-content claim. | “What happened in demo clip 6?” / “Where did the phone end up in the demo footage?” |
| 7 | [Handling an open wallet — Nicola Barts](https://www.pexels.com/video/a-person-holding-an-empty-wallet-7924953/) | Hands hold an open black wallet and move through compartments; cards are visible. This substitutes wallet handling for placement. It provides no put-down location or evidence of a purchase. | “What happened in demo clip 7?” / “What did the hands do with the wallet in demo clip 7?” |
| 8 | [Using a television remote — 2type](https://www.pexels.com/video/a-person-using-remote-control-switching-the-television-7184588/) | A hand points a remote at a television and presses buttons while the display changes. This substitutes remote use for relocation; no put-down location is shown. | “What happened in demo clip 8?” / “What device was the person using in demo clip 8?” |
| 9 | [Arranging a bed — Liliana Drew](https://www.pexels.com/video/a-woman-in-a-white-uniform-is-reaching-for-a-bed-9473226/) | A person rearranges pillows and bedding, lifting and replacing a pillow. This is an explicitly different household routine replacing unavailable cane/walker footage; it does not test mobility-aid location. | “What happened in demo clip 9?” / “What was the person arranging on the bed in demo clip 9?” |
| 10 | [Unpacking groceries — Nataliya Vaitkevich](https://www.pexels.com/video/woman-putting-groceries-on-the-kitchen-counter-8938185/) | A person takes vegetables from a grocery bag and puts them on a kitchen counter beside a laptop. Counter placement substitutes for refrigerator storage. | “What happened in demo clip 10?” / “Where were the groceries put in demo clip 10?” |
| 11 | [Pulling a letter from an envelope — Ron Lach](https://www.pexels.com/video/close-up-video-of-a-person-opening-an-envelope-9841387/) | Hands pull a paper letter partway from an already-open envelope beside a desk. This substitutes mail handling for tray placement; no reading, payment, or letter-content claim. | “What happened in demo clip 11?” / “What happened with the envelope in demo clip 11?” |
| 12 | [Eating at a table — Ketut Subiyanto](https://www.pexels.com/video/video-of-people-eating-breakfast-4753174/) | A person cuts food, lifts a forkful to their mouth, then lowers the fork. A brief eating action does not establish a completed meal, quantity, or nutrition. | “What happened in demo clip 12?” / “Is there a demo video of someone eating?” |
| 13 | [Drinking from a cup — Anastasia Shuraeva](https://www.pexels.com/video/woman-drinking-from-a-cup-and-looking-out-4068575/) | A person beside a large window raises a cup to their mouth, drinks, then lowers it. The liquid and quantity are not established. | “What happened in demo clip 13?” / “Where was the person drinking from a cup in demo clip 13?” |
| 14 | [Greeting with a hug — Cedric Fauntleroy](https://www.pexels.com/video/a-man-and-a-woman-hugging-while-other-people-are-talking-7251364/) | Two people approach, embrace, and separate indoors. Visible interaction only: no names, relationship, conversation contents, or verified visitor identity. | “What happened in demo clip 14?” / “How did the people greet each other in the demo footage?” |
| 15 | [Peeling a banana — Pavel Danilyuk](https://www.pexels.com/video/a-person-peeling-a-banana-4386642/) | Hands pull the first strip of peel from a banana over a kitchen counter. Food preparation is the explicit substitute for the medicine example; this clip does not test medicine-taking detection. | “What happened in demo clip 15?” / “What fruit was being peeled in demo clip 15?” |

### Actual saved results on the iPhone

These judgments describe this set of clips, not a general accuracy estimate. “Uncertain note” means the visual description was retained after structured extraction did not produce usable events. “Structured rows” means parsing succeeded; it does not certify the claims. Neither storage outcome should be counted as successful recognition by itself.

| Phone clip | Visual description compared with the source | Saved representation |
|---|---|---|
| 1 — laundry | **Partial.** Clothing handling and folding/sorting are recognized after reanalysis, but the action remains ambiguous; putting fabric into versus taking it from the basket is unresolved. | Two uncertain notes. |
| 2 — watering | **Core action correct.** Watering flowers is recognized. The can is inconsistently described as pink and white across windows. | Structured rows; repeated observations. |
| 3 — utensils | **Mixed; incorrect detail remains.** The first window recognizes washing dishes and a fork/spoon in a glass. The second incorrectly describes washing food, possibly a lobster tail. | Structured rows; the incorrect food claim is marked uncertain. |
| 4 — key fob | **Partial; key identification failed.** Placement on a white marble-like surface is described, but the object remains a generic metallic object beside a leather fob. | One uncertain note; no key-placement state. |
| 5 — glasses | **Correct core sequence.** Glasses are brought toward the face and are worn at the end. | One uncertain note. |
| 6 — phone | **Partial.** Smartphone and wooden-table location are recognized. The placement transition is omitted, and being seated is unsupported. | Two structured `other` rows about a hand; no phone-placement state. |
| 7 — wallet | **Correct core activity.** Hands handle a black wallet containing cards. No put-down location is claimed. | One uncertain note. |
| 8 — remote | **Partial.** Holding a remote near a television is recognized; button presses and screen changes are omitted. | One structured `other` row about a hand. |
| 9 — bed | **Partial, useful description.** Reaching toward pillows and smoothing a blanket on the bed are recognized. Lifting and replacing a pillow is omitted. | Two structured `other` rows. |
| 10 — groceries | **Wrong principal action.** Kitchen/produce context is recognized, but cutting an orange vegetable with a knife is invented. The clip shows unpacking and placing produce. | One uncertain note. |
| 11 — envelope | **Partial context; target action missed.** Document handling is described, but envelope/letter removal is absent, and the suggestion of an open book is unsupported. | One uncertain note. |
| 12 — eating | **Correct core sequence.** Cutting food, followed by eating, matches the clip. | One uncertain note. |
| 13 — drinking | **Wrong principal action.** The description says spraying a window; the source shows drinking from a cup beside the window. | One uncertain note. |
| 14 — greeting | **Mixed.** An embrace is recognized, but dancing is invented. | One uncertain note. |
| 15 — banana | **Correct core sequence.** Holding a whole banana and then peeling it to expose the fruit matches the clip. | One uncertain note. |

All clips have saved evidence, but the new key and phone placement samples did not produce usable placed-object state transitions. Correct glasses, wallet, eating, and banana descriptions remain unstructured notes. The saved evidence is available for recall; the controller results below separate successful retrieval from correct recognition. No manifest action labels were inserted as inferred events or model answers.

### Final answer checks

The final installed build completed all 18 controller queries: the personal keys question, all 15 numbered demo questions, one natural utensils question, and personal daily history. No query raised an execution error or opened the camera/library. Numbered demo answers took **3.26–7.85 seconds, median 4.53 seconds**; the keys answer took **0.109 seconds**, including a **0.00143-second** saved-record lookup. These timings exclude speech recognition and playback. The user separately confirmed the spoken keys answer and video evidence before this batch.

Numbered questions retrieved the appropriate clips. The answers for clips **5, 7, 12, and 15** communicate the correct core glasses, wallet, eating, and banana actions; these are the best initial tests. Clips 10 and 13 repeat wrong actions, while clips 3, 11, and 14 retain incorrect or incomplete details. The natural question “What was used to wash the utensils in the demo video?” returned no matching saved answer. “What did I do today?” used personal records and excluded the demonstration videos.

The model initially omitted activity uncertainty even when evidence was marked uncertain. The final build adds an explicit spoken/displayed prefix from the saved evidence headers: “Some of the saved video analysis is uncertain.” The final device run verified that prefix for all 11 numbered answers whose evidence includes uncertain records. This prevents the label from being dropped; it does not correct a wrong visual description. Unknown recording dates remain stated. All 41 activity-memory tests pass, including full-description retrieval, phone/smartphone matching, and uncertainty preservation.

Gremma was reopened in its normal voice interface after the checks. These developer queries exercise the normal controller answer path; they are not fifteen separate microphone-recognition tests or an airplane-mode acceptance test.

The collection contains 15 real demonstration clips, with the substitutions above. It does **not** yet cover the full original feature plan: there is no medicine-taking sample, cane/walker parking, paired key pickup, remote relocation, glasses/wallet storage, mail-tray placement, or refrigerator-storage sequence. Those still need suitable self-recorded clips. Indexing the current collection cannot establish that those unrepresented cases work.

Actual recording dates are unknown for all 15 samples. Source publication dates, download dates, and app import dates must not become evidence that the user performed these activities today. Keep the clips labeled as demonstrations; use undated/general-history questions rather than testing personal morning/evening medicine or meal logs with this footage.

Source URLs, credits, local paths, hashes, durations, and visual-check notes are retained in `.build/demo-videos/all-manifest.json` and the per-batch manifests. Raw videos and contact sheets remain outside Git under `.build/demo-videos/`; only this documentation belongs in the repository. Pexels permits free use and modification subject to its terms. Do not imply endorsement, personal identity, or that depicted people have low vision, memory impairment, or another condition. The watering clip's individual license link resolves to Pexels' CC0 guidance; the other checked source pages link to the Pexels License. [Pexels license](https://www.pexels.com/license/), [Pexels terms](https://www.pexels.com/terms-of-service/), [CC0 guidance](https://www.pexels.com/creative-commons-images/)

Charades is a relevant research dataset of household actions, but it is less practical for this quick corpus: the challenge advertises a 13 GB 480p archive, the old primary project URL currently redirects to the Ai2 homepage, and I did not verify a current video-license file or individual downloadable samples. Do not describe it as a ready-to-import approved collection. [Charades challenge](https://vuchallenge.org/charades.html), [dataset paper](https://arxiv.org/abs/1604.01753)
