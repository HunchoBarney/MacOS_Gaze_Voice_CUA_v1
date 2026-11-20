# Decisions

Settled choices, newest first. Change one only with a new entry here.

## 2026-11-20 — The owner's keys live in a Cloudflare Worker

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
  day ($1 default). Global: $20 a day, new installs per network and per day,
  a `PAUSED` variable and an admin pause, and per-install revoke.
- Open source: Hono 4.13.19 (MIT) for routing, Wrangler 4.165.0 (MIT or
  Apache-2.0) to run and deploy. Our code is the ledger and the proxy rules.
- Realtime spend is an estimate per minted secret, because the socket goes
  straight to OpenAI. A relay through the Worker would measure it exactly
  but adds a hop to every audio frame.

## 2026-11-20 — Standby opens a session on the wake word

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
## 2026-11-20 — CI runs on the owner's Mac

- GitHub Actions stays off for billing. `scripts/local-ci.sh` runs the CI
  test job (`make test`) on the Mac and posts a `local-ci` commit status,
  which needs no Actions minutes. A launchd agent polls open same-repository
  PRs and main every 5 minutes, one job at a time, at low priority, and only
  while no other `swift-build`/`swift-test`/`swift-frontend`/`xcodebuild`
  runs. Dependabot PRs run only with the `local-ci` label; fork PRs never run.
- nektos/act (MIT) was considered to run `ci.yml` itself. In host mode it
  copies the local directory instead of checking out the head, and
  `setup-node` downloads its own Node, while the job's only real step is
  `make test`. So the script calls `make test` directly and `ci.yml` stays
  the definition of the step. The `package` job (a full signed release
  build) is not run locally. No self-hosted Actions runner: it needs Actions
  and runs workflow code on the owner's main Mac.

## 2026-11-20 — Hands-free uploads only speech

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
- Speech is OpenAI Realtime only. The on-device FluidAudio transcriber and
  voice were removed with their models. `LocalSpeechSession` still owns
  turn admission.
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

- **Providers:** OpenAI (Realtime voice) and TypeSafe (Jev) only. Jev is the
  primary semantic chooser; direct grounded operations need no model call.
- **Screenshots:** never sent to Realtime; pixels only when a decider needs
  them, one capture reused per step.
- **Eye tracking:** gaze targets, it never actuates. Deciders receive the
  resolved target identity, never raw gaze coordinates. Dwell is an
  accessibility opt-in, off by default. Every gaze flow also works without
  gaze.
- **Permissions:** granted once during onboarding; no recurring prompts in
  product flows.
- **Hardware floor:** 8 GB M1.
- **Signing:** a local self-signed identity for the owner and testers.
  Developer ID and notarization are not in place yet.
- **Reuse first:** existing code and platform APIs, then maintained open
  source, before a new subsystem.
