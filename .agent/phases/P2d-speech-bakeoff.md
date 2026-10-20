# P2d — SpeechAnalyzer vs Parakeet bake-off + live-partials diagnosis

- Track: voice | Depends on: P1 | Branch: `ship/v1-p2d`
- Gate evidence (PROGRAM.md): "latency/WER/RAM table; winner picked"

## Context

The product contract (PROGRAM.md) needs a local-first transcriber:
"Fn down → local ASR (live partials) … Fn up → local final ≤200 ms".
The incumbent is `LocalTranscriber` (FluidAudio 0.17.5):
`parakeet-realtime-eou-120m` streams ~160 ms ghost partials + EOU flag,
`parakeet-ultra` batch-refines the final. Verified problems: "first
partial arrives only after release" and "three transcribers loaded".
The challenger is Apple's `Speech` framework (`SpeechAnalyzer` /
`SpeechTranscriber`, macOS 26+ — WWDC25 API): on-device, maintained by
Apple, possibly better punctuation/locale support, unknown latency
profile. This spike measures both on identical audio and picks ONE
engine (or a justified hybrid) for P3 to build around.

## Owned paths

```text
spikes/speech-bakeoff/**
scripts/verification-lane.sh
.agent/phases/P2d-speech-bakeoff.md
.agent/acceptance/P2d.json
.agent/PROGRESS.md
```

No production code changes. No bench/ changes. Root Package.swift untouched
(the spike is a standalone SwiftPM package; it does NOT add a target to
the app package).

## Acceptance mapping

- P2d-1 → M1 (scaffold, baseline)
- P2d-2 → M1 (corpus record + manifest)
- P2d-3 → M2/M3 (symmetric engine rows)
- P2d-4 → M2 (resource instrumentation)
- P2d-5 → M3 (partials diagnosis)
- P2d-6 → M3 (report + verdict)
- P2d-7 → M3 (hygiene + authorization facts)
- P2d-8 → M4 (judge + commits)

## Approach

### Corpus (M1) — recorded, per user choice (option b)

- `spikes/speech-bakeoff/` = standalone SwiftPM CLI (`swift run bakeoff <cmd>`),
  dep: FluidAudio **exact 0.17.5** (same pin as the app). If the SPM
  cache misses and a network fetch is unavailable, fallback = local
  path dependency on `.build/checkouts/FluidAudio` (fragile — that dir
  is regenerable; used only as fallback and labeled if used).
- `bakeoff record` walks ~15 prompted hero-command phrases (manifest
  `corpus/phrases.json`), records each utterance from the default mic
  (AVAudioRecorder native file → offline 16 kHz mono wav), stores ground
  truth = the prompt, confirmed by the speaker before accepting each clip.
  ~5 min human step. Phrases shaped like the four hero jobs (inbox,
  browser, gaze+command, calendar/notes/reminders).
- **TCC risk (G1 finding)**: a bare `swift run` binary has no bundle /
  Info.plist — macOS may attribute the mic prompt to the parent
  terminal or refuse. The recorder checks audio authorization before
  capture and surfaces a denial with a remedy; it never resets TCC or
  repeatedly requests a denied grant. A signed recorder app remains a
  future option if CLI attribution blocks the test environment.
- Held-out supplement: copy the 3 FluidAudio repo test wavs
  (`.build/checkouts/FluidAudio/Tests/.../SlidingWindow/Fixtures/*.wav`,
  real speech 17–21 s) into `corpus/library/` with their reference
  texts — longer-form sanity, free.
- ALL recorded audio gitignored (`corpus/recordings/` + `corpus/library/*.wav`);
  manifest + prompt texts committed. User voice never enters git.

### Drivers (M2)

- `ParakeetDriver`: `StreamingEouAsrManager` (.ms160 chunks — mirror of
  LocalTranscriber) for streaming partials + EOU; `AsrManager` +
  `.ultra` for batch final — same dual-model arrangement as production.
- `SpeechAnalyzerDriver`: `SpeechTranscriber` + `SpeechAnalyzer`
  streaming API (`modules:` transcriber, volatile+final result stream);
  locale en-US; measure both its streaming partials and finalization.
  Discover + record required authorization/TCC grants (feeds the
  permissions-once decision).
- Feeding: chunked-file simulation — each wav streamed in 160 ms chunks
  through the same ingestion path a live mic would use. Timestamps
  captured per event: first non-empty partial, last partial update,
  EOU/finalization, final text.

### Metrics (M2)

Pre-run correction (before measuring the user's corpus): the debug smoke
rows are discovery-only. Release builds are the scored evidence. Compare
`parakeet`, `speechanalyzer` (progressive), and `speechanalyzer-fast`
(`volatileResults` + `fastResults`, same en_US module). Keep three warm
iterations of every clip per variant, plus a separately labeled first
inference warm-up. Each variant runs in a fresh child process with a
bounded timeout; no downloads or microphone capture during the bench.

Use the same energy-delimited view of each recording, without changing
the WAV: 20 ms RMS windows, threshold max(-45 dBFS, peak-window RMS
minus 30 dB), 200 ms padding at both edges. Store source SHA-256, trim
offsets, input duration and reference text. This avoids scoring the
recorder's arbitrary trailing silence as "instant finalization".
Library clips have tail-phrase assertions only, not full WER references.

Timestamp with a monotonic clock. Chunk availability is the END of each
160 ms interval. Scheduled audio end is fixed at input sample duration,
not when the model finishes draining. Report processing/feed lag rather
than hiding it. `eou_ms` is nullable with its engine-specific meaning;
Speech segment finality is not an EOU detector. Capture callback times
synchronously, before any actor hop, and retain all finalized Apple
segments by their audio ranges. Empty transcripts cannot be `ok`.

Aggregate WER = sum(word edits) / sum(reference words), not median
per-command WER (which can hide every long-command error). The 2 percentage
point / 50 ms tolerances below are engineering ties, NOT statistical
significance claims. Report paired per-clip ranges and p95 as well as p50.
Resource sampling uses separate processes and locked RSS sampling, with
load and inference peaks separated. Apple XPC service memory must be
listed separately; client RSS alone is not Apple's total RAM. Unavailable
asset bytes or unattributable service memory remain explicit gaps, never
zero. A directional pick with such gaps is not packaging/release proof.
Fresh-process load is not a cache-purged load; warm reuse is measured
separately. Existing system/model caches will not be deleted.

Per clip × engine rows: `clip, engine, variant, wall_ms,
first_partial_ms, last_partial_ms, eou_ms, final_ms_after_audio_end,
partial_count, partial_flicker (edit distance between consecutive
partials), transcript_final, wer_final, status, rss_load_mb,
rss_transcribe_mb`.
**Field mapping (G1 finding)**: `eou_ms` is engine-specific —
Parakeet emits an explicit EOU signal; SpeechAnalyzer finalizes
segments instead. Mapping: Parakeet `eou_ms` = EOU flag timestamp;
SpeechAnalyzer `eou_ms` = timestamp of the LAST `isFinal` result in
the stream. If an engine never finalizes mid-stream, `eou_ms` =
`stream_end` — still comparable, labeled in the report.
**Simulation caveat**: latencies are measured against the 160 ms
chunk-feed timeline, not wall-clock speech — comparable across engines,
mildly optimistic vs live mic. Labeled in the report.
Plus: cold + warm model-load ms; peak RSS delta (load, then transcribe)
via `proc_pid_rusage`; model bytes on disk (Parakeet dirs measured
directly; SpeechAnalyzer via its asset inventory or documented path).
WER: normalized (lowercase, strip punctuation) Levenshtein on words —
implemented in the spike, no external dep.

### Live-partials diagnosis (M3)

The verified problem: first partial arrives only after Fn release.
Distinguish engine vs pipeline:

- If chunked-file simulation yields mid-stream partials on both engines
  → streaming capability is demonstrated, NOT proof the engines are
  fast enough or that a particular app call site is broken. Combine
  timestamps, backlog and read-only production-path inspection to
  identify P3 hypotheses; physical Fn/microphone behavior remains a
  separate integration check.
- If an engine emits nothing until "stream end" in simulation → engine
  config/limitation; record which API knob controls it.
- Output: a labeled finding ([verified]/[documented]) telling P3 exactly
  where the fix lives. The fix itself is P3 scope.

### Runs (M3)

- Cold start per engine (fresh process, cold model cache where possible).
- ≥3 warm iterations per clip per engine; report p50 + spread.
- Same machine, back-to-back, screen locked state irrelevant (CPU only).
- `bakeoff report` → results/REPORT.md: per-engine latency table, WER
  table, RAM/disk table, partials-cadence table, verdict vs rule.

## Verdict rule (predeclared)

Winner must be picked from MEASURED rows:

- **PICK <engine>** if it beats-or-matches the other on: final WER on
  recorded corpus, first-partial latency, final latency after audio
  end — and is not worse on RAM by >2× or disk by >1.5×.
- **Mixed outcome (G1 finding)**: if engines split the three metrics,
  decide by priority order — (1) `final_ms_after_audio_end` (the ≤200 ms
  product contract is the binding constraint), then (2) `wer_final`,
  then (3) `first_partial_ms`. If the split maps cleanly onto
  stream-vs-batch roles (one engine best at partials, the other best at
  final accuracy) → **HYBRID** with named roles; this is the only
  sanctioned HYBRID shape.
- **INCONCLUSIVE** if either engine can't run (blocked_env) or recorded
  corpus <10 usable clips — name the blocker.
- Bars referenced, not invented: first partial ≤300 ms target; final
  ≤200 ms after EOU ideal (report actuals; missing the ideal is a
  finding, not an automatic fail — but the verdict must say by how much).
- **Corpus power caveat**: ~15 short recorded commands + 3 library
  clips ≈ a few hundred words — WER granularity is ~1%/error;
  single-speaker, quiet-room bias. Verdicts are DIRECTIONAL picks for
  the product lane, labeled as such; a close call (<2% WER, <50 ms
  difference) is reported as "within engineering tolerance", not a
  statistically significant win or tie.
- No "feels better" verdicts; every claim cites row data.

### Accuracy-First Product Gate (User Correction After This Run)

This is an explicit POST-RUN policy change, not a retroactive change to
the measured rows or the predeclared performance rule above. Preserve
the historical speed-only outcome; it no longer selects a product
default. Current product decision: **HOLD, no production ASR selected**.

- Known action-changing errors block promotion even when aggregate WER
  differs by less than 2pp. GitHub->GateHub is not acceptable as a
  production regression in exchange for 66ms faster finalization.
- Before choosing a default, fix the known critical regressions and
  validate intent plus critical slots (target, recipient, date/time,
  amount, negation) on both existing cases and previously unseen
  confusable cases. Canonical number/hyphen formatting is not the same
  as changing the user's intended entity.
- Evaluate general on-device vocabulary context and grounded entity
  resolution, not per-utterance expected-answer injection. Do not blindly
  rewrite one real service/name into another because they sound alike.
- Real uncertainty should trigger a concise clarification or safe
  refusal, never a silent wrong action. Measure clarification burden and
  successful autonomous coverage; asking on every turn cannot pass.
- No claim of "zero possible ASR mistakes". The enforceable boundary is
  that uncertain recognition must not silently become wrong actuation.
  Send/book/delete confirmations remain product safety checks, distinct
  from one-time system permissions.
- P2d can accept a sound benchmark and an accuracy-blocked conclusion;
  that is NOT approval of the production engine or proof that the
  accuracy correction is implemented. Future corrective experiments
  must declare evaluation cases/rules before measuring; do not tune
  this corpus and claim general accuracy.

## Safety / env

- Mic capture only via the `record` command with the user driving —
  the one-time macOS mic TCC prompt for the spike binary is expected
  and recorded (user pre-approved).
- No desktop mutation; no app interaction; CPU/RAM measurement only.
- Speech framework authorization discovery is a measured step — record
  what the API demands, don't assume.
- User recordings stay local + gitignored. No audio leaves the machine
  (SpeechAnalyzer on-device mode + Parakeet fully local — verify
  SpeechAnalyzer doesn't require server fallback; if it does on this
  config, that's a recorded finding, likely disqualifying for the
  "local first" decision).

## Gates

- G1: this plan (judge-vetted) + `.agent/acceptance/P2d.json`
- G2: contract = milestones below, owned paths above
- G3: spike package builds (`swift build` inside spikes/speech-bakeoff);
  scripts run; py_compile/swiftc syntax checks pass
- G4: fresh-context judge on acceptance criteria
- G5: the corpus runs ARE the live bench (mic-recorded real voice)
- G7: PROGRESS.md entry; commits on `ship/v1-p2d`

## Milestones

- [x] M1 scaffold: spike package, phrases manifest, record command
      (compile-verified), corpus recorded (HUMAN: ~5 min), baseline
      `results/dirty-baseline.txt` captured before first spike write
- [x] M2 drivers + metrics: both engines transcribe+stream identical
      audio; WER/latency/RAM instrumentation; dry-run on library clips
- [x] M3 runs + report: corpus × engines × iterations, partials
      diagnosis, REPORT.md + verdict; Surprises filled
- [x] M4 acceptance + judge + commit

## Surprises & findings (fill during execution)

- Recorder v1/v2 reused AVAudioConverter after signaling endOfStream
  inside each tap. The observed 0.1s files are NOT evidence of an stdin
  stop race. Replaced the tap with native file recording, verified file
  duration, and offline conversion. Existing clips are preserved; a
  retake uses a unique filename and replaces only the manifest reference
  after confirmation. Old manifests without peak remain readable.
- Recorder checks run via `scripts/verification-lane.sh speech`; live
  capture is separately opt-in with `JARVIS_RECORDER_LIVE=1` and the
  desktop lock. No recorded audio is staged or committed.
- The recorder resumes accepted clips, requires an interactive terminal,
  flushes accidental keystrokes during capture, and requires speaker
  confirmation of the prompt. Malformed CLI options fail cleanly rather
  than trapping. Manifest decode/write failures propagate, not silently
  reset progress.
- 15/15 speaker-confirmed WAVs verified after recording (102 seconds
  original audio, 16 kHz mono). No WAV changed during preprocessing;
  source hashes are recorded by the runner.
- Release tests initially invoked the executable's CLI entry point with
  Swift Testing arguments (`unknown command --test-bundle-path`). A thin
  executable plus testable BakeoffCore library removed that observed
  failure. Optimized tests now execute the real regression suite rather
  than treating a successful link or zero discovered tests as proof.
- Read-only production inspection identifies a concrete display-wiring
  gap: main.swift:599-613 routes local partials only into the command
  router (or clears the callbacks in STT-only mode). Visible text instead
  comes from remote transcriptDelta -> .partial -> VoiceController.
  P3 must wire LOCAL, turn-tagged partials into that display path. No
  production edit or physical Fn verification is performed in this spike.

## Decision Log

| # | Date | Decision | Why |
|---|---|---|---|
| 1 | 2026-10-19 | Extend owned paths to the verification runner's speech scope | Recorder regression tests must use the serialized verification entry point, not ad-hoc builds; no production sources change |
| 2 | 2026-10-19 | Correct benchmark timing, segment aggregation, corpus WER and resource attribution before scoring recorded corpus; add Apple fast-results variant | Legacy debug harness moved audio-end after processing, dropped earlier Apple finals, used median WER, and could select a winner with incomplete coverage. Archive discovery rows; require full paired release coverage and expose resource gaps. No model/speech asset downloads during measurement |
| 3 | 2026-10-19 | Directional PICK SpeechAnalyzer with volatileResults + fastResults; no production promotion yet | Run 20261020T034959348218Z: all 162 scored rows ok. Command final p50/p95 = 84.4/213.1ms versus Parakeet 150.0/389.1ms and standard Apple 209.5/1025.6ms. Corpus WER fast/standard 5.15%, Parakeet 4.12% (within the predeclared 2pp accuracy tolerance). First-partial 300ms target missed by all; Apple GitHub->GateHub error needs guarding; Apple service/asset attribution and physical Fn integration remain gaps |
| 4 | 2026-10-19 | User accuracy correction supersedes D3 as a product recommendation: HOLD, no default selected | Speed-only comparison remains historical evidence, not a production choice. Known critical intent/entity errors block promotion; evaluate vocabulary/grounding on held-out confusable cases and count clarification burden. This does not pretend the ASR error is already fixed |

## Outcomes & Retrospective

G4 independent review PASS (agent b827626b, including verifier-risk
recheck); milestone commit 425bba6 landed on ship/v1-p2d. Acceptance
and handoff record G7 closure. Run 20261020T034959348218Z produced 162 scored release
rows plus 3 excluded warm-ups: 15 confirmed commands and 3 real library
clips, 3 repetitions, 3 variants. All engine processes exited 0 and were
reaped; all 15 source WAV hashes remained unchanged. Independent Python
verification recomputes WER, timing, coverage and event attribution.

The earlier debug smoke numbers are not representative release results.
Do not infer the app's root cause or general-model quality from one clip
or treat repeated utterances as independent speakers. Report literal
WER alongside actual error pairs: Apple misrecognized GitHub as GateHub;
other errors include number/hyphen formatting and Parakeet's extra filler.
The directionally fastest engine is not automatically ship-quality.
The verdict accepts the SPIKE and accuracy-blocked handoff, not an ASR
promotion. Initial verifier-attribution risk is fixed with four
fail-before/pass-after regression guards; the final independent report
is results/G4-review.md. Unverified product/resource limitations remain.

## Handoff

- **Production gate**: HOLD, no production ASR selected. D4 supersedes
  D3 as a product recommendation; accuracy is a prerequisite to a
  latency comparison, not an averaged-away tradeoff.
- **Performance-only P3 experiment**: SpeechAnalyzer + SpeechTranscriber en_US with
  reportingOptions [.volatileResults, .fastResults], one local
  transcript source. Matches the root package's macOS 26 deployment
  floor. Do not retain two simultaneously loaded ASR engines just to
  mask errors, and do not remove FluidAudio wholesale (TTS also uses it).
- **Speed limits**: fast-results command final p50 84.4ms/p95 213.1ms,
  but first partial p50 2119ms; 41/45 finalizations met 200ms, 0/45
  first partials met 300ms. These are energy-delimited file-replay
  latencies with 200ms tail padding, not physical Fn timings. Per-turn
  preparation p50 30.6ms is separate; prepare during hold/warm-up,
  buffer audio while becoming ready, and measure the real path in P3.
- **Accuracy limit**: 5.15% literal corpus WER versus Parakeet 4.12%.
  Apple GitHub->GateHub is a real named-entity error, not punctuation.
  SDK AnalysisContext.contextualStrings[.general] is available for a
  prospective app-name vocabulary test; no biased run was measured.
  Correctness/verification must stay ahead of an unconditional speed pick.
- **Live-partials fix locus**: main.swift:599-613 must bind local
  partials to turn-tagged transcript display, separately from
  LocalCommandRouter speculation. The current displayed .partial
  originates in remote RealtimeVoiceLane transcriptDelta, not local ASR.
  This code-inspection finding is not proof a packaged-app fix works.
- **Onboarding**: capture used the existing authorized microphone;
  file-based SpeechTranscriber ran with legacy speech-authorization
  status 0 (not requested). No benchmark download/fallback code runs.
  Clean-Mac grant attribution and XPC network observation are not proven.
  Install/check local assets during onboarding, not after dropping a
  user's first utterance.
- **P12 resources**: Parakeet required model files total 856362338 bytes;
  client sampled load/inference peaks 447.6/172.6 MiB. Fast Apple client
  peak ~20.9 MiB is NOT total engine RAM: shared localspeechrecognition
  observed up to 600.2 MiB. Shared Apple ASR inventory = 162235114 bytes,
  exclusive en_US footprint unknown. Recheck steady combined app+tracker
  resources before certifying RAM/disk ratios or packaging bars.
- **Gate state**: M1-M4 complete as a measured SPIKE with an
  accuracy-blocked product conclusion; G4 independent judge PASS
  including attribution-risk recheck; G7 milestone 425bba6 committed.
  Acceptance 8/8 records the relayed verdict. No production files changed.
