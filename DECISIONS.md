# Decisions

Settled choices, newest first. Change one only with a new entry here.

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
  `harness-archive-2026-11-19` tag. `make test` is `swift test` plus the
  tracker typecheck and Vitest; end-to-end testing is being evaluated
  separately.
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
