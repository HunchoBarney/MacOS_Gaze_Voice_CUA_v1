# Decisions

Settled choices, newest first. Change one only with a new entry here.

## 2026-11-20 — Ask rarely, offer undo (KAR-69)

- A consequential press Jarvis chose itself no longer asks first when the
  app can take it back: Move to Trash in Finder, Delete and Archive in
  Mail, Delete in Notes, TextEdit, Pages, Numbers and Keynote, and Send in
  Mail inside its Undo Send delay. Jarvis presses, then says what it did
  and "Say undo to bring it back"; the offer stands for 10 s from when it
  is spoken (Mail: never past its delay, less 3 s), once per task.
- Undo is the app's own ⌘Z menu item, read over Accessibility by its key
  equivalent before and after the press (Apple platform API, no new
  dependency). An offer stands only when the press changed that item, and
  a spoken "undo" invokes that exact item in that app, and refuses if the
  app shows anything else since.
- Mail's delay is read from `UndoSendDelayTime` in the `com.apple.mail`
  domain, a name taken from Mail's binary. It fails closed: a send asks
  unless Mail has written that key with at least 7 s (4 s of offer after
  3 s to say it). Mail's shipped default, with no key written, still asks.
- Update Now, Upgrade Now, Restart Now, Install and Restart, Restart and
  Shut Down are a `.restart` consequence. Nothing takes a restart back,
  so Jarvis always asks when it chose the press, and the person's words
  cover it only as "click Restart". "Format" is no longer a delete phrase
  (Format Disk stays on the never list), and a "show me how" or "how do I"
  goal covers no press.
- Known limit: Mail's undo item reads only "Undo Delete". If the person
  deletes another message inside the window, a spoken "undo" reverses
  their newer delete; Accessibility can't tell the two apart.
- Still asking: Pay, Call, Allow and other permission prompts, account
  changes, unnamed presses, permanent or wholesale deletes, sends outside
  Mail, and any press with nobody to hear the offer. The never list and the
  password refusal run before any of this and are unchanged.
- Not physically verified yet: the AX titles each app shows, and invoking
  Undo by menu path in a background app.

## 2026-11-21 — The gaze ring lights only a control the tracker can resolve (JARA-55)

- Main's ring stays the one gaze highlight, and it takes a control only when
  the error band can single it out: σ at most 1.5× the control's larger
  side, no bigger than 320×200 pt, never a window or container (group,
  table, list, scroll area). Past that, nothing highlights; there is still
  no permanently drawn gaze pointer (KAR-75). A press glow (Jarvis pressing
  a named control) is not a gaze guess and skips the gate, and dwell never
  fires on a target the ring refused.
- A cursor parked on a control weighs ×2.5 up to σ 40 pt; above that its
  log-bonus scales by (40/σ)², the rate gaze evidence itself thins out. A
  tie that includes the highlighted control holds for the 0.2 s consensus
  window and then releases it. The listening-start halo is gone, and the
  gaze ring stands down whenever the answer or guide halo shows.
- New gaze visuals (orb, glow, calibration look) moved to JARA-57's UI Lab.
  Evaluated during this work and rejected: libraries.dev ThinkingOrbsKit (MIT,
  14ae9d2; filled fixed-size loader redrawn every frame) and metasidd/Orb
  0.2 (MIT, a48fc33; filled orb with endless blurs and particles).

## 2026-11-21 — Every visible surface lives in the UI gallery

- The owner asked for one page that shows every visible component on its
  own and together. `make gallery` renders each surface offscreen from
  fixture state, in every state, light and dark, with Reduce Motion off and
  on, plus combined desktop scenes. `make gallery-deploy` publishes the
  site to Cloudflare Pages (project `jarvis-ui-gallery`). See
  gallery/README.md.
- A PR that adds or changes a visible component updates its gallery page
  in the same PR, redeploys, and links before and after in its body.
- The native harness hosts the real views through `@testable import`. It
  copies product code only where the state is private (the menu-bar item
  and menu), and those replicas cite their lines. No product code changes
  to make the gallery work.
- The site's libraries (Motion, cmdk, Lenis, NumberFlow and Sonner, all
  MIT, plus Paper Shaders under Apache-2.0) are pinned in gallery/site
  and listed with versions in gallery/site/REUSE.md.

## 2026-11-20 — Quiet by default: no chimes unless Sounds is on

- The owner: "the chimes and noises it makes are super annoying and not
  good experience". Jarvis is always listening, so it plays no non-speech
  sound by default. The glow, the indicator and the task row carry
  success, failure, stalls and questions; speech is heard only where words
  are needed, and spoken answers and the "Looking…" filler are unchanged.
- One setting, Settings → Replies → Sounds (`soundsEnabled`), off by
  default, brings back the Glass and Basso earcons. Installs that had it on
  are moved to off once (`soundsQuietByDefault`); a later choice sticks.
- New feedback, Live (L3+) included, follows the same rule: visual first,
  speech only for words, never a new chime.

## 2026-11-20 — Memory stays on the Mac, in SQLite through GRDB

- Behind `voice.live` (JARA-49 L8). Jarvis remembers people, preferences,
  things you asked it to remember, and one-line summaries of finished
  requests (kept 90 days) in one SQLite file,
  `~/Library/Application Support/Jarvis/Memory/memory.sqlite`. It writes
  nowhere else, opens the file only on first use, and never syncs it. Raw
  audio and transcripts are never stored.
- Open source: GRDB.swift 7.12.0 (MIT), pinned in `Package.swift` and
  recorded in `ThirdParty/GRDB`, with SQLite's FTS5 for relevance. Our code
  is the schema, the intents and the Settings screen.
- Forgetting means gone: `secure_delete` and FTS5 `secure-delete` overwrite
  deleted text, and Forget Everything rebuilds the index and vacuums the
  file. Context for a Live session is read fresh on every call, so a deleted
  memory never reaches a later session.
- "Remember X", "who's X?" / "what do you remember about X" and "forget
  that" are answered before a request becomes a task, so they never reach
  the activity log. A bare "who's X?" with no memory goes on to the rest of
  Jarvis.

## 2026-11-20 — Writing by instruction checks words on device (L7)

- "Type this …" takes the exact span after the lead-in ("type this",
  "write this down", "type the following", or a bare "type"/"write" before
  a quote) up to a closing quote, a spoken "end quote" or the end of speech.
  Before typing, Apple's on-device `SpeechAnalyzer` (Speech framework,
  macOS 26, no download or network) transcribes the last 20 s of the
  hands-free speech the lane sent. Same words, ignoring case and
  punctuation, types at once with the conversation transcript's formatting.
  Different words, or no on-device transcript, shows the text and waits for
  "type it". Every insert is read back through Accessibility.
- Speech Recognition permission is requested at the first "type this"
  (`NSSpeechRecognitionUsageDescription`); until it is granted, every
  literal is shown before typing. L5 onboarding should cover the prompt.
- "Come up with a reply for this" drafts with `TerraClient` (Responses API,
  `store: false`), puts the draft in the focused field unsent and reads its
  first line. Only "send it", with the draft still in the field of the same
  app, sends, through the spine's own "click Send".
- No library needed: span extraction is about 150 lines over string
  matching, and the transcriber is Apple's.

## 2026-11-20 — The hands-free plan is approved (KAR-75)

- The owner approved the hands-free GPT-Live plan and its eight
  recommendations ("Ok I approve"). The roadmap is L0 docs, L4 delete Fn,
  L1 Live transport, L2 delegation bridge and ledger, L3 listening states,
  L5 onboarding, L6 gaze, L7 writing, L8 memory, L9 proactivity, L10
  metering and plans, and L11 Live by default with the Realtime lane
  deleted. Everything after L0 sits behind `voice.live` until L11.
- Single commands go through Live at launch. An on-device path is built
  anyway for the usage-limit fallback, and one-shot commands move to it
  on the $30 plan only if measured cost per typical user passes about $20
  a month.
- Plans: $30 includes 300 Live minutes (a Standby minute counts 0.4) and
  100 multi-step tasks; $100 includes 1,000 Live minutes and 400 tasks. At
  the limit the current conversation finishes, then Jarvis keeps working
  in on-device basic voice until renewal; a top-up adds 150 Live minutes
  for $10. Developer accounts are uncapped.
- In a session opened with the wake word an explicit request acts at
  once. After a Standby resume or in reply to an alert, a send, delete,
  buy or post asks one short question first. While the Mac plays audio,
  Standby needs the name to resume.
- Reading other apps' notification banners (through Accessibility, on
  the Mac) is an opt-in onboarding choice.
- Spoken alerts use Jarvis's own voice through OpenAI TTS, with Apple's
  on-device voice as the offline fallback.
- The second cursor is a small ring that flashes when "this" is resolved,
  plus the highlight before a press; no permanently drawn gaze pointer.
- The Wispr Flow comparison is a reference benchmark for "type this", not
  a release gate.
- `.agent/` stays archived at `harness-archive-2026-11-19`; only these
  repository docs carry the direction.
- Transport: WebRTC through stasel/WebRTC (Google libwebrtc, BSD-3-Clause),
  pinned in L1. It is the transport OpenAI recommends and the only one
  billed at the Standby rate.

## 2026-11-20 — Jarvis is hands-free; there is no Fn key

- Owner: Jarvis is a hands-free, always-on personal agent. No Fn
  anywhere: no Fn push-to-talk, no Fn dictation, no Fn choice in
  onboarding. Every push-to-talk assumption is obsolete.
- `FnInput`, the Hold fn mode (`ListeningMode.pushToTalk`), the
  commit-on-release path, #542 and the Fn owner-test items are deleted
  (roadmap L4). Until then they are dead ends, not features to extend.
- Pause Listening in the menu bar is how you turn listening off.
- Users: technical users, ordinary users and older users alike.

## 2026-11-20 — Voice moves to gpt-live-1.1

- OpenAI gpt-live-1.1 (`v1/live/sessions`) is the voice: full duplex, no
  manual turn commits. Owner: it "feels like talking to a person".
- It lands behind `voice.live`, off by default until the owner's physical
  checks pass on a signed build. Then Live becomes the default and the
  gpt-realtime-2.1 lane (`RealtimeVoiceLane`) is deleted (L11).

## 2026-11-20 — Listening states: Asleep, Talking, Standby

- Asleep: the on-device wake word (Vosk) listens. Free; nothing leaves
  the Mac. Talking: a Live session, $0.05/min. Standby: the session is
  paused after a short silence (about 8 s, to be tuned), $0.02/min; just
  talk to resume, no name needed.
- The follow-up window is about 90 s since the last turn, then Asleep.
  "That's all" goes to Asleep at once; "stay with me" holds the session
  open until "that's all" or a long cap. Pause Listening is Off.
- A visible glow shows the state and replaces the Fn capsule; the
  menu-bar item stays.
- Today's "Standby" listening mode (wait for "Hey Jarvis") becomes
  Asleep; the name Standby moves to the paused session.

## 2026-11-20 — The Live session talks; Jarvis acts

- Wake word → Live session → client delegation into the existing spine:
  FastLane/IntentRouter, Jev, Cua or native APIs, consent, undo and
  verification. gpt-live-1.1 never acts on its own.
- Exactly-once authority holds under full duplex and bystander speech: a
  client ledger admits each request once, whatever the session repeats,
  and speech not addressed to Jarvis causes no action. With no commits,
  the committed input transcript no longer decides a turn.
- An explicit request ("click send") runs at once with a highlight,
  except for the Standby-resume and alert-reply question in the approved
  plan above. Confirm only consequential actions the user didn't ask
  for. Scam hard-refusals stay.

## 2026-11-20 — Gaze is a second cursor

- With eye tracking on, gaze resolves "this" and "that" in "click this"
  or "open this". It never wakes Jarvis and never acts alone.
- Eye tracking stays optional and off by default.

## 2026-11-20 — Jarvis speaks up, rarely

- Owner: "saying important stuff", but "not annoyingly proactive".
- Speak now: a meeting starting now or a clash, an urgent message from an
  important person, a reply you were waiting on, a reminder you asked
  for, and scam, fake-alert or security warnings. Show on the glow:
  spoken only when you ask "what's up". Save the rest for "what did I
  miss".
- One sentence and an offer. Never while you're talking, on a call,
  screen-sharing or presenting; macOS Focus is respected. Alerts are
  bundled and capped, learn from "not now", and a setting turns them up
  or down.
- Alerts use a cheaper one-way TTS; a Live session opens only if you
  answer.

## 2026-11-20 — Writing by instruction, memory on the Mac

- "Type this 'blah blah'" inserts the words verbatim. "Come up with a
  reply for this" drafts, then confirms before sending.
- Memory of people, preferences and past requests stays on the Mac, and
  you can view and delete any of it.

## 2026-11-20 — Plans and keys

- A $30/month tier with usage limits, and a $100/month tier.
- Users never handle API keys: hosted credentials (KAR-38) replace the
  Settings key fields, as planned on 2026-11-19.

## 2026-11-20 — The Mac ends hands-free turns

- Hands-free (and Standby once woken) no longer uses Realtime's
  `semantic_vad`: `turn_detection` is null in every input mode. The Silero
  gate ends the turn after `VoiceActivityGate.Tuning.endOfTurn` of quiet
  (0.6 s, rounded up to whole 256 ms chunks: 0.77 s) and the lane sends
  `input_audio_buffer.commit`; the server's `committed` names the item the
  turn binds to. The gate sends no trailing silence. This supersedes the
  hangover and silence tail in "Hands-free uploads only speech".
- Measured before (JARA-41, 24 paid turns): semantic VAD cut 3 turns inside
  450–500 ms pauses and committed at p90 3.3 s after speech. A pause shorter
  than `endOfTurn` can't fill the quiet chunks the gate needs, so it no
  longer splits a turn.

## 2026-11-20 — Equivalent phrasings through a small command grammar

- "get Safari open", "hop over to desktop 2", "label everything", "I can't
  find Notes", "hit Save" and "read my screen" are read by
  `CommandGrammar`: lead-ins ("I want to", "let's", "help me"), a verb
  class, an object and a particle, rewritten to the canonical command the
  fast lane already parses. A rewrite is used only when that canonical
  command parses to the family's action, and a phrase that already parses
  is left alone, so the grammar adds phrasings without changing existing
  commands. Screen questions are classified, not rewritten, so the question
  reaches the screen reader verbatim. Jev's semantic router stays the
  fallback for what the grammar can't read.
- No maintained intent grammar fits a Swift app: Home Assistant's hassil
  (Apache-2.0) is the closest, but it is Python, and Apple's NaturalLanguage
  framework tags words without matching intents. The grammar is about 250
  lines over the existing parsers.
- Measured in `CommandPhrasingTests` (pass = same admission and fast action
  as the canonical command; "!" rows must differ): design set 40/86 on main
  → 86/86; same-author held-out set 32/72 → 71/72; a blind set written by
  an agent that never saw the parser 51/72 → 66/72.

## 2026-11-20 — The owner's physical checks run as e2e flows

- The owner's checklist items for #548, #560 (25–29), #562 (24), #583 and L7
  (#595) are flows in `e2e/`, so the owner grants permissions and the run
  does the rest. They speak with `say`, act on fixture windows that record
  what happens to them, and read other apps through Accessibility from the
  native helper. They never ask for a permission: `run.sh` checks the
  grants and stops with what to grant.
- What stays with the owner: a keyboard Escape (#583 deliberately ignores a
  posted one, and a flow checks that), putting the Mac to sleep, and spoken
  checks only meaningful in his voice. Those run with `JARVIS_E2E_OWNER=1`.
  The agent turn and the reply draft spend on paid calls beyond Realtime and
  run with `JARVIS_E2E_PAID=1`.
- A held Fn is posted at the HID event tap, which is where Jarvis read Fn
  before #583, so a build that still listens for Fn fails the check.

## 2026-11-20 — A fifth end-to-end flow: "stop" mid-scroll

- `stop-scroll` says "Hey Jarvis, scroll down", "keep scrolling", then "stop"
  while the scroll repeats, and checks that the fixture list stops and stays
  put. The task is the ongoing scroll because its three commands are decided
  on the Mac with no model call, so the flow is deterministic apart from
  hearing the lines. A stop in the middle of a model-planned task is not
  covered: when the stop lands would depend on the model's pace.

## 2026-11-20 — End-to-end flows run on e2e's macOS engine

- Four flows on a signed build (`e2e/`, `make e2e`): the first run, "show
  names" then a click, a question about the window, and the wake word. Every
  turn starts with "Hey Jarvis"; nothing presses Fn. Only what Swift seam tests can't reach; they run only on the
  owner's go, under the desktop lock, and put the Mac back afterwards.
- Runner: e2e 0.24.0 (Apache-2.0). Engine: `@e2e-dev/desktop` from
  e2e-inc/e2e#1953 at 7e0b7d2 (Apache-2.0, not yet released), built locally
  against `@e2e-dev/core` 0.24.0. It drives agent-desktop 1.3.1 (Vercel Labs,
  Apache-2.0), downloaded and checked against its SHA-256. Our code is the
  adapter: the flows, a small native helper that counts and quits apps, a
  fixture window, and the harness that saves and restores the Mac's state.
- The checks read the Mac or Jarvis's ordinary windows, never Cua: Jarvis
  acts through Cua, so testing it with Cua would share its failure modes.
- Rejected: our own Cua engine for e2e (duplicates upstream's), XCUITest
  (needs an Xcode UI-test target).

## 2026-11-20 — Local CI queues in the build lane

- Local CI no longer skips a tick when the lane is busy. Each head's
  \`make test\` takes a high-priority ticket in \`~/.capy/work/lane/lane.sh\`
  and runs in local CI's own checkout (\`LANE_NO_MIRROR=1\`), so it goes
  ahead of focused jobs without preempting the one running. One local-ci job
  still runs at a time. A lane that never frees up posts \`error\`, which
  local CI retries an hour later, not \`failure\`.

## 2026-11-20 — The owner's keys live in a Cloudflare Worker

- Extended by the hands-free plan (2026-11-20): L1 adds a Live session
  route that exchanges the WebRTC offer, and L10 meters Talking and
  Standby minutes and enforces the plan limits.
- People using Jarvis never hold an OpenAI or TypeSafe key. `CredentialService/`
  is a Cloudflare Worker (owner's choice) named `jarvis-keys` on workers.dev.
  Each install registers anonymously for a token kept in Keychain; no sign-in.
- Realtime: the Worker mints an OpenAI client secret (`/v1/realtime/client_secrets`,
  60 s to start a session, model pinned) and the app opens its socket to
  OpenAI with it. Responses (Terra) and Jev (TypeSafe) calls go through the
  Worker, which allows only the configured models and refuses tools and
  streaming on Responses.
- Limits live in one SQLite-backed Durable Object, so checks and charges are
  strongly consistent; KV is eventually consistent and can't hold a limit.
  Per install: requests per minute per route and estimated spend per UTC
  day ($1 default). Global: $5 a day (lowered from $20 when the repository
  went public), new installs per network and per day,
  a `PAUSED` variable and an admin pause, and per-install revoke.
- Open source: Hono 4.13.19 (MIT) for routing, Wrangler 4.165.0 (MIT or
  Apache-2.0) to run and deploy. Our code is the ledger and the proxy rules.
- Realtime spend is an estimate per minted secret, because the socket goes
  straight to OpenAI. A relay through the Worker would measure it exactly
  but adds a hop to every audio frame.
- The Live broker sends `delegation: {type: "client"}` because the API
  rejects the documented `null` (seen in a real connect test, 2026-11-20).

## 2026-11-20 — Standby opens a session on the wake word

- Superseded in part by "Listening states" above: Fn is gone, the 8 s
  session close becomes Standby with a 90 s follow-up window, and this
  wake-word mode is now called Asleep. The shared microphone tap, the
  1.5 s pre-roll and standing down when another app uses the microphone
  still hold.
- Standby keeps the voice lane's microphone open, as Hold fn already does,
  and the wake word hears its tap. Nothing streams until the wake phrase.
- A wake opens a hands-free session from 1.5 s before the phrase, so
  "Hey Jarvis, open Mail" is heard in one breath. The tap's replay buffer
  grew from 1 s to 5 s to cover the checker's second and a cold socket;
  Fn holds still replay only what follows the press.
- The session closes after 8 s with no turn, reply or task, and Standby
  rearms. Fn, Pause Listening, and another app using the microphone (a
  call, a recording; Core Audio process objects) stand Standby down.

## 2026-11-20 — The wake word is Vosk, not our own detector

- "Hey <name>" (default "Hey Jarvis") is spotted on the Mac by Vosk 0.3.44
  (Alpha Cephei, Apache-2.0) with `vosk-model-small-en-us-0.15`
  (Apache-2.0), both pinned by SHA-256 in `ThirdParty/Vosk`. Our code is
  the adapter: microphone tap, 16 kHz conversion, a 3.5 s buffer and two
  grammar recognizers. A listener that knows only the wake phrase runs on
  everything; its hits are decoded again with every first name in macOS's
  `/usr/share/dict/propernames` as a rival, and count at 0.6 confidence.
- Measured with the shipped code on 28 synthetic `say` voices plus 60 min
  of speech (LibriSpeech and `say` paragraphs): "Hey Jarvis" 80/84
  accepted, "Hey Nova" 53/56, 0 false wakes in 60 min, below 1 % of an M1
  core while speech plays. Near-misses ("Hey Marvin", "Hey jars", "Hey Noah",
  the bare name) wake it 7/140 and 5/56 times. Short names that sound like another first name are
  missed more ("Hey Jake" 56/84, heard as "Hey Jay").
- A name must be in the model's vocabulary (41 of 45 names tried).
- Rejected: sherpa-onnx keyword spotting (the only small English KWS model
  is trained on GigaSpeech, whose audio is non-commercial, and it accepted
  44–55 %); Apple's on-device recognizer as the checker (it mishears names,
  "AJ" or "Jane" for Jake, 360 ms per check, no accuracy gained over Vosk);
  openWakeWord's pretrained models (CC BY-NC-SA); Picovoice (cost); and
  any hand-built detector.
- The app grows by 80 MB (68 MB model, 12 MB library).

## 2026-11-20 — GPT-Live runs over LiveKit's WebRTC build (L1, behind voice.live)

- GPT-Live-1.1 sessions use WebRTC (`v1/live/sessions`), the transport
  OpenAI recommends and the only one billed at the Standby rate. The Mac
  never holds a key: it sends its SDP offer to the credential Worker's
  `POST /v1/live/sessions` (#582), which fixes the model, client
  delegation, no tools, `store: false` and the speech wake policy.
- libwebrtc comes from LiveKit's build, livekit/webrtc-xcframework
  150.7871.08 (BSD-3-Clause libwebrtc, Apache-2.0 packaging), pinned in
  `ThirdParty/WebRTC`. Only its 29 MB macOS framework is fetched.
- Why not stasel/WebRTC: its macOS build has no custom audio device, and
  two captures of one microphone failed on the owner's Mac: without voice
  processing our tap lost up to 3.35 s at a time, and with it WebRTC heard
  near-silence. LiveKit's AVAudioEngine audio module owns the microphone
  once, records without a call, and lets Jarvis tap the same engine, which
  kept our tap continuous before, during and after a call
  (`ThirdParty/WebRTC/README.md`).

## 2026-11-21 — Live listening states and the one-breath request (L3, behind voice.live)

- One microphone owner: LiveKit's audio engine records from the moment
  listening is armed. The Vosk wake word hears its input on the Mac, and
  nothing else opens an input while `voice.live` is on.
- "Hey Jarvis" opens a Live session. Jarvis closes it 8 s after a wake
  that brought no request, 90 s after the last turn, on "that's all", or,
  after "stay with me", 30 minutes after the last turn. Live's own idle
  timeout (8 s) moves it to Standby in between. The glow shows hearing and
  thinking, silently.
- The request said in the same breath reaches Live as audio. The engine's
  input runs through `LiveInputRelay`: from just before the wake moment it
  is held until `session.started`, then played into the input track in
  real time, skipping quiet 10 ms frames while behind, so the connect lag
  is gone by the first pause. WebRTC forbids `session.input_audio.append`,
  and with client delegation GPT-Live has no typed user turn
  (`response.item.create` is Responses-only), so neither faster-than-real
  time replay nor a transcribed text turn is available. If the capture
  falls 8 s behind it is dropped and Live asks the user to say it again.

## 2026-11-20 — CI runs on the owner's Mac

- GitHub Actions stays off for billing. `scripts/local-ci.sh` runs the CI
  test job (`make test`) on the Mac and posts a `local-ci` commit status,
  which needs no Actions minutes. A launchd agent polls open same-repository
  PRs and main every 5 minutes, one job at a time, at low priority, and only
  while no other `swift-build`/`swift-test`/`swift-frontend`/`xcodebuild`
  runs. Dependabot PRs run only with the `local-ci` label; fork PRs never run.
- Local CI tests a PR head merged into current main (`git merge-tree`, never
  committed) and names that main in the status, so a green PR doesn't need
  main merged in just to refresh CI. A result stays valid while main's later
  commits touch none of the PR's non-Markdown files; a conflict posts
  `error` without a run.
- nektos/act (MIT) was considered to run `ci.yml` itself. In host mode it
  copies the local directory instead of checking out the head, and
  `setup-node` downloads its own Node, while the job's only real step is
  `make test`. So the script calls `make test` directly and `ci.yml` stays
  the definition of the step. The `package` job (a full signed release
  build) is not run locally. No self-hosted Actions runner: it needs Actions
  and runs workflow code on the owner's main Mac.

## 2026-11-20 — Hands-free uploads only speech

- Applies to the gpt-realtime-2.1 lane, which goes in L11. Whether the
  Live lane keeps this gate is decided in L1/L3.
- Hands-free audio is scored on the Mac by Silero VAD v6.2.1 (MIT, Core ML,
  `ThirdParty/SileroVAD`) and sent to Realtime only while someone is
  speaking, with one second of pre-roll and 0.8 s of hangover. After that
  the lane sends digital silence until Realtime reports the end of speech
  (at most 4 s), because `semantic_vad` closes turns on the audio it
  receives. If the model can't load, hands-free doesn't start.
- Wake-word work builds on this gate. On-device Apple speech recognition
  costs 10–21 % of an M1 core while speech is present, so it can only
  verify candidate windows, never run on every utterance.

## 2026-11-19 — Reset to one build from source

- One command, `make release`, builds the app from source: pinned runtimes,
  the release Swift binary, the tracker, staging, signing, zip and checksum.
  Candidates are no longer cloned from earlier signed apps.
- One Codex binary per bundle: `CodexRuntime/codex` and
  `CodexRuntime/bin/codex` are hard links to the same signed file.
- Speech is OpenAI Realtime only (superseded 2026-11-20: gpt-live-1.1
  replaces it). The on-device FluidAudio transcriber and voice were
  removed with their models. `LocalSpeechSession` still owns turn
  admission.
- The test harness (live trials, user audits, replays, evidence writers,
  request budgets, spend counter, `JARVIS_*` overrides in app code) left the
  app. Diagnostics are Export Logs plus MetricKit.
- The `.agent/` phase harness was retired. It is preserved in the
  `harness-archive-2026-11-19` tag. `make test` is `swift test --parallel`
  plus the tracker typecheck and Vitest; end-to-end testing is being
  evaluated separately.
- The OpenAI and TypeSafe key fields stay in Settings until a hosted
  credentials service replaces them.

## Standing decisions

- **Providers:** OpenAI (gpt-live-1.1 voice; gpt-realtime-2.1 until L11)
  and TypeSafe (Jev) only. Jev is the primary semantic chooser; direct
  grounded operations need no model call.
- **Screenshots:** no model receives them, the voice session included. Jev
  and screen questions decide from the accessibility tree and on-screen
  text; giving a decider pixels again is a new decision.
- **Eye tracking:** optional and off by default. Gaze is a second cursor
  for "this" and "that"; it targets, it never actuates and never wakes
  Jarvis. Deciders receive the resolved target identity, never raw gaze
  coordinates. Dwell is an accessibility opt-in, off by default. Every
  gaze flow also works without gaze.
- **Permissions:** granted once during onboarding; no recurring prompts in
  product flows.
- **Hardware floor:** 8 GB M1.
- **Signing:** a local self-signed identity for the owner and testers.
  Developer ID and notarization are not in place yet.
- **Reuse first:** existing code and platform APIs, then maintained open
  source, before a new subsystem.
- **Keys:** secrets live in Keychain only. Hosted credentials (KAR-38)
  mean users never handle keys.
- **Voice control:** voice fully controls the Mac. No step needs Fn or
  any other key.
