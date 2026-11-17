# P11 — eye-polish ExecPlan

> Status: draft; documentation authorized, source G1/G2 pending
> Track: eyes plus serialized agent-owned gaze integration
> Depends on: P8, P5; M0 corrects an already-required default in C1
> Branch: `ship/v1-p11` · Acceptance: `.agent/acceptance/P11.json`
> Contracts: resolved-target hint, separate selection, tracker IPC, §1/§2/§8

## Purpose

Make looking reliably identify a target without acting by itself, keep
selection explicit, and meet whole-product resource/recovery budgets.

## Context

Read PROGRAM's visionOS interaction decision, SHIP-PLAN and P8 handoff.
`Gaze/DwellClick.swift` currently defaults an absent mode to `.safe`;
PROGRAM requires off. GazeService/CandidateFeed/Stream/Pointer and
TargetOverlay already exist. Swift source belongs to the agent writer,
EyeTracking to the eyes writer; freeze shared integration before testing.

## Reuse decision

Reuse existing gaze components, P8 Core ML runtime and the native AX/
geometry/target resolver. Use platform display/camera notifications and
existing overlay styles, not another tracker or coordinate-control engine.
Existing source/fixtures and REUSE.md are the first candidates.

## Owned paths

```text
Sources/JevVoice/Gaze/DwellClick.swift
Sources/JevVoice/Gaze/GazeService.swift
Sources/JevVoice/Gaze/GazeCandidateFeed.swift
Sources/JevVoice/Gaze/GazeStream.swift
Sources/JevVoice/Gaze/GazePointer.swift
Sources/JevVoice/Gaze/TrackerHost.swift
Sources/JevVoice/UI/TargetOverlay.swift
Sources/JevVoice/UI/SettingsView.swift
Sources/JevVoice/Drive/VoiceTaskCoordinator.swift
Sources/JevVoice/Drive/JevDecider.swift
Sources/JevVoice/Drive/RecoveryDecider.swift
Sources/JevVoice/Drive/BrowserDecider.swift
Tests/JevVoiceAppTests/DwellClickTests.swift
Tests/JevVoiceAppTests/GazeCandidateFeedTests.swift
Tests/JevVoiceAppTests/GazeLaneTests.swift
Tests/JevVoiceAppTests/GazeWiringTests.swift
Tests/JevVoiceAppTests/GazeRefusalStateTests.swift
Tests/JevVoiceAppTests/TargetOverlayTests.swift
Tests/JevVoiceAppTests/TrackerFlowTests.swift
EyeTracking/web/src/App.tsx
EyeTracking/web/src/styles.css
EyeTracking/web/src/inference/**
EyeTracking/electron/main.cjs
scripts/tracker-smoke.sh
scripts/verification-lane.sh
bench/tasks/p11-*.json
.agent/phases/P11-eye-polish.md
.agent/acceptance/P11.json
.agent/results/P11/**
.agent/CONTRACTS.md
.agent/PROGRESS.md
```

## Non-goals

No gaze-only actuation by default, raw coordinates as model authority,
host-app layout modification, silent calibration reset or no-gaze feature
loss. Do not treat a pointer animation as a resolved element.

## Milestones

### M0 — correct the default before C1 promotion

**Change:** set fresh-profile dwell off and review existing preference
origins/migration. Preserve only a demonstrable explicit opt-in; do not
treat an absent/malformed/automatically seeded preference as consent.
Use existing DwellClick/UX tests; add a `p11` lane mode with affected tests.

**Check:** `scripts/verification-lane.sh p11` → fresh/invalid preferences
produce no dwell input; explicit off stays off; opt-in has >=1s dwell
plus look-away and remains suppressed during voice/asks/picks.

**Evidence:** `.agent/results/P11/default-policy-review.md`, source hash,
preference cases and no-input observations. This does not close full P11.

### M1 — fresh resolved targeting across deciders

**Change:** bind gaze to actual AX/window identity and freshness. Give
deciders only resolved hints. Show hover/confidence; select by voice/key/
click. Invalidate on face loss, window/display changes or stale generation.
Apply >=60pt/about 2.5-degree target-spacing guidance to Jev's overlays;
offer disambiguation for tiny/ambiguous host controls.

**Check:** `scripts/verification-lane.sh p11` → wrong/stale/ambiguous
targets cannot act; no gaze still supports the workflow; changed subject
cannot inherit a previous hint. Inspect real overlay geometry.

**Evidence:** `.agent/results/P11/integration.json` and consumer review
covering Jev/Terra-recovery/Browser/coordinator, not only a rendered dot.

### M2 — adaptive resources and smoke

**Change:** adapt sampling and background work while preserving active
tracking floor; prune unused packaged models and bound histories/queues.
Add tracker-smoke to the existing verification lane, including wake/
reconnect and actual runtime status.

**Check:** `scripts/verification-lane.sh p11` for offline guards;
`python3 scripts/with-desktop-lock.py scripts/verification-lane.sh p11-live`
for the declared live population. New p11-live is a reviewed
implementation deliverable. >=95% strict gaze success with PROGRAM
statistics, >=15fps active, wake <=5s, RSS <=2.5GB and idle CPU <=10%
with normal app/speech/tracker configuration. Report footprint as extra
evidence, not a replacement for the RSS gate.

**Evidence:** `.agent/results/P11/qualification.json`, smoke output,
actual camera/gaze/human cases, resource series and artifact manifest.

## Acceptance mapping

| Criterion | Milestone | Evidence |
|---|---|---|
| P11-1 | M0 | dwell default/migration/opt-in behavior |
| P11-2 | M1 | fresh resolved hints and separate selection |
| P11-3 | M1 | geometry/disambiguation/no-gaze alternatives |
| P11-4 | M2 | adaptive runtime, resources and smoke |
| P11-5 | M2 | physical gaze/recovery success |
| P11-6 | M2 | independent review/handoff |

## Gates

G1/G2 and scoped G4 passed for the C1 M0 correction; additional M1/M2 work
still needs its own contract. M0 can precede P8/P5 because it restores
an existing locked requirement; whole-phase acceptance cannot. G3 is
serialized. G5/G6 share final real-camera and physical input evidence
only when source/artifact and population match.

## Progress

- [x] Draft/default-fail criteria prepared.
- [x] M0 off-by-default source correction and nonempty verification lane.
- [ ] M1 target integration.
- [ ] M2 performance/smoke/qualification.

## Surprises & Discoveries

The `.safe` default is a source-confirmed mismatch, not evidence that an
unintended physical click was observed. Keep that distinction in reports.

## Decision Log

| Date | Decision | Reason |
|---|---|---|
| 2026-11-15 | Correct dwell early; qualify the full gaze path with P8/P5 later | Preserve the locked interaction model without waiting to remove the unsafe default |

## Outcomes & Retrospective

C1 corrected the dwell policy and passed the nonempty P11 checks plus
independent source/candidate G4. Full live gaze/physical qualification is
pending. Six phase acceptance criteria remain false.

## Handoff

C1 M0 source correction is implemented in the signed c292 candidate:
safe fresh defaults, explicit opt-in, learned-write isolation and a 1s floor.
The mandatory nonempty P11 lane passed and scoped G4 passed. Runtime
gaze/physical qualification and whole-phase criteria remain open.
Current artifact, evidence and next human check:
[C1 handoff](../results/P4/c1-handoff.md).

Next: M1 target integration with its P8/P5 consumers and the later combined
physical qualification. Reuse the completed C1 correction. Keep gaze
non-actuating on invalid state, preserve the prior
verified runtime, and report actual degraded behavior instead of a stale
target. Agent and eyes writers never edit each other's paths concurrently.
