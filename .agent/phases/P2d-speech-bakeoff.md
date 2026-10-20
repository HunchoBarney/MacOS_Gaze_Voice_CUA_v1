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
.agent/phases/P2d-speech-bakeoff.md
.agent/acceptance/P2d.json
.agent/PROGRESS.md
```

No production code changes. No bench/ changes. Package.swift untouched
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
  (AVAudioEngine → 16 kHz mono wav), stores ground truth = the prompt.
  ~5 min human step. Phrases shaped like the four hero jobs (inbox,
  browser, gaze+command, calendar/notes/reminders).
- **TCC risk (G1 finding)**: a bare `swift run` binary has no bundle /
  Info.plist — macOS may attribute the mic prompt to the parent
  terminal or refuse. Fallback order if AVAudioEngine capture is
  denied: (a) `afrecord` (Terminal's TCC identity), (b) a minimal
  signed `.app` wrapper for the recorder. The path taken is recorded
  in the manifest.
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
  → the engines are fine; the stall is in the app's audio routing /
  buffering (record evidence: partial timestamps vs chunk timeline).
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
  difference) is reported as "statistically tied" not a fake win.
- No "feels better" verdicts; every claim cites row data.

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

- [ ] M1 scaffold: spike package, phrases manifest, record command
      (compile-verified), corpus recorded (HUMAN: ~5 min), baseline
      `results/dirty-baseline.txt` captured before first spike write
- [ ] M2 drivers + metrics: both engines transcribe+stream identical
      audio; WER/latency/RAM instrumentation; dry-run on library clips
- [ ] M3 runs + report: corpus × engines × iterations, partials
      diagnosis, REPORT.md + verdict; Surprises filled
- [ ] M4 acceptance + judge + commit

## Surprises & findings (fill during execution)

_(empty until M2+)_

## Decision Log

| # | Date | Decision | Why |
|---|---|---|---|

## Outcomes & Retrospective

_(fill at G7)_

## Handoff

_(fill at G7 — must name: chosen engine + role(s), the live-partials
fix locus for P3, required TCC/authorization grants for onboarding,
model size/RAM facts for P12 packaging)_
