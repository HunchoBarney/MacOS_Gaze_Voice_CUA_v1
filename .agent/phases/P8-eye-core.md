# P8 — eye-core ExecPlan

> Status: draft; documentation authorized, source G1/G2 pending
> Track: eyes, with a sequenced host integration
> Depends on: P2a · Branch: `ship/v1-p8`
> Acceptance: `.agent/acceptance/P8.json` · Contracts: tracker IPC, §2, §8

## Purpose

Run the proven Core ML approach in the actual camera-to-gaze pipeline,
with durable calibration and automatic camera/wake recovery on M1/8GB.

## Context

Read P2a's handoff, SHIP-PLAN C3 and REUSE. Production
`EyeTracking/web/src/inference/runtimes.ts` still uses the web runtime;
the accepted node/Core ML result is under `EyeTracking/spikes/ort-node/`.
It measured model inference on seeded inputs, not complete camera FPS.
`Sources/JevVoice/Gaze/TrackerHost.swift` and TrackerContractTests own
the app-facing startup/readiness boundary.

## Reuse decision

Promote compatible `onnxruntime-node` Core ML support from the existing
spike into the Electron utility process. Preserve the measured CPU
detector fallback for no-face failure. Use Electron's maintained process
and IPC facilities, existing frame/preprocessing/calibration code and
platform camera APIs. Pin compatible versions/model hashes; an upstream
latest release is not an automatic upgrade. No native tracker rewrite.

## Owned paths

```text
EyeTracking/package.json
EyeTracking/pnpm-lock.yaml
EyeTracking/electron/main.cjs
EyeTracking/electron/preload.cjs
EyeTracking/electron/externalApi.cjs
EyeTracking/electron/externalStore.cjs
EyeTracking/electron/storeContract.test.mjs
EyeTracking/electron/coremlUtility.cjs
EyeTracking/electron/coremlUtility.test.mjs
EyeTracking/web/src/inference/**
EyeTracking/web/src/App.tsx
EyeTracking/web/src/uiState.ts
EyeTracking/web/src/uiState.test.ts
EyeTracking/scripts/qualify-runtime.cjs
EyeTracking/README.md
Sources/JevVoice/Gaze/TrackerHost.swift
Tests/JevVoiceAppTests/TrackerContractTests.swift
Tests/JevVoiceAppTests/TrackerHostTests.swift
scripts/verification-lane.sh
.agent/phases/P8-eye-core.md
.agent/acceptance/P8.json
.agent/results/P8/**
.agent/CONTRACTS.md
.agent/PROGRESS.md
```

Assign tracker and host changes by named paths under PLANS §5. The
integration owner sequences Swift, shared verification and metadata
changes after reviewing the IPC handoff; never edit shared files in parallel.

## Non-goals

No model retraining, new inference engine, raw gaze coordinates sent as
decider authority, automatic selection on look or seed-only FPS claim.
Keep supported no-gaze operation available.

## Milestones

### M1 — production runtime and lifecycle

**Change:** establish the utility-process inference and existing host IPC
contract; load model resources from the packaged location; bound frame
queues and dispose sessions/tensors on recovery. Report actual backend,
readiness and degraded fallback. Preserve camera/preprocessing semantics.
Add a `p8` lane mode combining affected tracker and host contract checks.

**Check:** `scripts/verification-lane.sh p8` → nonempty suites pass for
no-face, dropped/late frames, utility crash, invalid tensor/model resource,
camera disconnect and old-generation output. No stale gaze is admitted.

**Evidence:** `.agent/results/P8/contract-review.md`, `source-review.md`
and runtime/model/package manifest with reuse/license decision.

### M2 — calibration, recovery and target feedback

**Change:** persist calibration with model/camera/display geometry identity;
recover camera/sleep state, prompt on drift and report invalid calibration
honestly. Keep target hover/confidence feedback and separate selection.
Do not silently reuse incompatible calibration or freeze a stale target.

**Check:** `scripts/verification-lane.sh p8`; controlled real-camera
reopen/wake/display-change cases through the packaged tracker.

**Evidence:** `.agent/results/P8/recovery.json` with monotonic timings,
actual backend, camera status, calibration identity and observed target.

### M3 — whole-pipeline qualification

**Change:** add `p8-live` to the existing lane, invoking the owned
qualify-runtime tool only with declared live scope. It measures real
camera-to-target frames while the signed app and speech are active.

**Check:** `python3 scripts/with-desktop-lock.py scripts/verification-lane.sh p8-live`
→ >=15fps on M1/8GB, calibration >=80% first try on the frozen
participant/attempt population, wake recovery <=5s; no seeded inference
substituted for live frames. Report frame age/queue drops and RSS/CPU.
The whole product must retain PROGRAM's resource budgets.

**Evidence:** `.agent/results/P8/qualification.json`, raw frame/recovery
rows, declared calibration attempts, runtime hashes and physical evidence.
Source/fixture, camera and human evidence are distinct.

## Acceptance mapping

| Criterion | Milestone | Evidence |
|---|---|---|
| P8-1 | M1 | actual production backend and reusable runtime |
| P8-2 | M1/M2 | IPC, lifecycle and stale-frame refusal |
| P8-3 | M2 | durable calibration and feedback |
| P8-4 | M3 | actual FPS/wake/calibration bars |
| P8-5 | M3 | combined resource and recovery behavior |
| P8-6 | M3 | independent review/handoff |

## Gates

G1/G2 pending. G3 remains serialized across worktrees. G5 requires a
real camera and recorded hardware/runtime, not model microbenchmarks.
G6 calibration/target feedback is grouped with the final gaze session.
No live flag is implied by this plan; p8/p8-live are implementation
deliverables and must prove nonempty real coverage before qualification.

## Progress

- [x] Draft/default-fail criteria prepared.
- [ ] M1 runtime.
- [ ] M2 calibration/recovery.
- [ ] M3 live qualification.

## Surprises & Discoveries

The successful P2a spike is not the production runtime. Web/WASM fallback
may keep the app responsive without meeting the release FPS requirement.
Such a fallback must be labeled, not presented as Core ML qualification.

## Decision Log

2026-11-17, KAR-28: keep renderer presence and scorer display separate
from action authority. Track the originating video observation, not its
latest delivery time. An entered source gap or replaced target cannot
extend a hold, and a recent repeated frame cannot refresh it. See the
KAR-28 entry in CONTRACTS. No physical or phase verdict follows.

| Date | Decision | Reason |
|---|---|---|
| 2026-11-15 | Promote the existing spike through Electron IPC | Avoid a tracker rewrite and measure the actual combined product |

## Outcomes & Retrospective

No runtime switch or new FPS/calibration claim. Six criteria remain false.

## Handoff

Next: inspect the exact P2a runtime/model compatibility and freeze the IPC
handoff. Preserve the current packaged tracker for rollback; a failed
native backend disables stale targeting and reports the actual fallback.
P11 consumes resolved fresh targets only after this seam is reviewed.
