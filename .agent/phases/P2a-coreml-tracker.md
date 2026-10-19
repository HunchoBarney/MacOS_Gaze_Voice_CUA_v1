# P2a — Core ML tracker spike ExecPlan

> Status: draft
> Track: eyes · Depends on: P1 (done) · Branch: `ship/v1-p2a`
> Acceptance: `.agent/acceptance/P2a.json` · Contracts touched: none

## Purpose

Decide — with numbers on the shipping floor — whether `onnxruntime-node`
with the Core ML execution provider can drive the tracker's ONNX models
at ≥15 FPS on an 8 GB M1. The answer gates P8's inference path:
**promote** (Core ML becomes the v1 eye runtime) or **discard**
(documented fallback). This is a measurement spike: the deliverable is a
verdict + a reproducible bench script, not production wiring.

## Context

- The hardware floor is THIS machine: `MacBookPro17,1` = M1, 8 GB
  (bench env snapshot `bench/results/env-20261019T045744Z.json`) — no
  extrapolation needed or allowed; verdict must be measured here.
- Models under test: every `.onnx` in `EyeTracking/public/models/` (6
  today — discover dynamically, never hardcode: `gaze_1x3x160x160`,
  `gaze_Nx3x160x160`, `mobileone_s0_gaze`,
  `retinaface_mbn025_with_postprocess_480x640_max1000_th0.70`,
  `vsdlm_l`, `yolomit_t_wholebody28_1x3x480x640`).
  `gaze_Nx3x160x160` has a **symbolic batch dim** — policy: symbolic
  dims resolve to the production batch size read from the inference
  worker's actual call sites during M1 (default 1 when undeterminable);
  the chosen value is recorded per model in the inventory table.
- The real pipeline is cadenced (verified
  `EyeTracking/web/src/inference/inferenceWorker.ts`): `models.detect`
  runs at ≤1 Hz (`DETECT_INTERVAL_MS = 1000`, :296,844-845);
  `appearance.estimate` ~5 Hz via `appearanceChannel.maybeRun` (:897);
  `estimateLipMotion` only when `enableLipMotion &&
  detector === "yolo"` and a mouth is present (:954-957); only
  `models.estimate` is unconditional per frame (:903). M1 must map each
  model file to its pipeline role (estimate/detect/appearance/lip/off)
  from source and record the mapping.
- **Chain = cadence-weighted effective per-frame cost at the 15 FPS
  target:** `effective_ms = Σ unconditional_models.p50 +
  Σ cadenced_models.p50 × (cadence_hz / 15)`. The strict "every model
  every iteration" total is also reported for contrast, but the
  verdict uses the cadence-weighted number — it models production.
- Current production path: `onnxruntime-web@1.30.0` inside the Electron
  tracker (wasm/webgpu). Prior observed numbers (prior session, this
  machine): wasm ~366 ms/frame ≈ 2.7 FPS; WebGPU ~9–20 FPS healthy
  runs. The spike re-measures a same-box wasm baseline in Node
  (single-threaded — no COOP/COEP, wasm binary resolved inside the
  spike dir) rather than trusting memory.
- Release bar (PROGRAM release bars + P8 row): **≥15 FPS on 8 GB M1**
  → cadence-weighted effective chain p50 ≤ 66.7 ms. Record p95 + RSS
  too (8 GB machine — a fast-but-fat win is still a finding).
- Dep: `onnxruntime-node@1.30.0` (published 2026-09-14, ≥7 days old —
  supply-chain rule satisfied). `onnxruntime-web@1.30.0` for the wasm
  baseline. The spike dir is **self-contained** — its own
  `package.json`+lockfile, `npm install` inside it (npm, not pnpm:
  keeps EyeTracking's single-package pnpm setup — `packageManager:
  pnpm@10.33.0`, no workspace file — and the user's uncommitted
  `package.json`/`pnpm-lock.yaml` untouched).
- EP-binding honesty: Core ML can silently fall back to CPU per-op.
  Proof runs in a **separate profiling pass** (see M2) — never on the
  timed iterations, since per-node profiling distorts the p50 being
  judged. Bound-fraction (nodes on CoreML / total) is recorded as data.
- Load failures are spike data: `InferenceSession.create` throwing → a
  `load_error` result row (per EP), never an abort; a model that can't
  run under ort-node belongs in the verdict reasoning.
- Related phases/handoffs: P8 consumes the verdict; P11's "fps-adaptive
  sampling floors" wants the headroom number. The P1 session-label
  wedge bug is assigned to **P4** — not this phase.
- Pre-existing dirty baseline (for the P2a-1 check):
  `EyeTracking/package.json` diff = `onnxruntime-web` 1.26.0→1.30.0 +
  `@litertjs/core` 2.5.2 removed; `pnpm-lock.yaml` mirrors it. Both are
  the user's uncommitted work — P2a must not add any new hunks.

## Owned paths

```text
EyeTracking/spikes/ort-node/**
.agent/phases/P2a-coreml-tracker.md
.agent/acceptance/P2a.json
.agent/PROGRESS.md
```

Writing outside this list is a violation — including
`EyeTracking/package.json`, `pnpm-lock.yaml`, or anything under
`EyeTracking/web`/`electron`/`public` (read-only for this phase).

## Non-goals

- No production wiring, no Electron/tracker code changes — P8 does the
  integration decision with this phase's numbers.
- No fix for the session-label wedge (P4-owned), no bench/ changes.
- No model retraining, quantization, or file changes to `public/models/`.
- No commits until acceptance evidence + judge PASS (G7).

## Milestones

### M1 — spike scaffolding + model/chain inventory
**Change:** `EyeTracking/spikes/ort-node/` with its own `package.json`
(`onnxruntime-node@1.30.0`, `onnxruntime-web@1.30.0`, `"type":"module"`)
+ committed lockfile + `.gitignore` (`node_modules/`). `measure.mjs`
skeleton: CLI (`--ep cpu|coreml|wasm`, `--iters N`, `--warmup N`,
`--chain`, `--profile`, `--report`, `--smoke`, `--out PATH` default
`results/results.json`), model discovery over
`EyeTracking/public/models/*.onnx`. Read
`EyeTracking/web/src/inference/inferenceWorker.ts` + its model-loading
modules; record the inventory table in this file — per model: filename,
introspected inputs (names/shapes/dtypes, symbolic-dim resolution
chosen), and pipeline role (estimate|detect|appearance|lip|off) with
its real cadence from source.
**Check:** `cd EyeTracking/spikes/ort-node && npm install` clean;
`node measure.mjs --smoke` lists all 6 models with introspected input
names/shapes/dtypes.
**Evidence:** command outputs; the model/shape/role/cadence table in
this phase file.

### M2 — per-model latency × EP, with separate EP-binding proof
**Change:** `measure.mjs` complete: per model × EP — seed-deterministic
input tensors matching the M1-resolved shapes (fill policy documented;
record the seed), ≥20 warmup + ≥100 timed iterations (configurable;
`--smoke` = 2+8), `performance.now()` per run → median/p50/p95 ms, RSS
= max of `process.memoryUsage().rss` sampled once per iteration +
post-run sample. `InferenceSession.create` throwing → `load_error` row
(per EP), run continues. Each session torn down between measurements.
Timed runs carry NO profiling. `--profile` is a separate pass
(small fixed iters, profiling on): `endProfiling()` writes to the
spike dir cwd → parsed immediately → profile moved under
`results/profiles/<model>-<ep>.json` (committed) → results.json row
gets `coreml_bound: true|false` + `bound_nodes`/`total_nodes` when any
node's provider names CoreML, else `coreml_unbound: true`. ort-web
wasm baseline runs in the same script (`--ep wasm`, numThreads 1).
**Check:** `node measure.mjs --ep cpu --smoke`, `--ep coreml --smoke`,
`--ep wasm --smoke`, and `--profile --ep coreml` produce rows; every
coreml row shows `coreml_bound:true` or `coreml_unbound:true`.
**Evidence:** `results.json` rows + `results/profiles/*.json`.

### M3 — chain composition + report + verdict
**Change:** `--chain` mode computes the cadence-weighted effective
per-frame cost per EP (`Σ unconditional.p50 + Σ cadenced.p50 ×
cadence_hz/15`, formula in Context) and also reports the strict
all-models-per-iteration total for contrast — measured from the
recorded per-model rows, same warmup/iters discipline for any missing
measurements. `--report` aggregates `results.json` → `REPORT.md`
(default `results/REPORT.md` next to `--out`): per-model table
(median/p95/RSS per EP incl. `load_error`/`coreml_unbound` flags),
chain table (weighted + strict per EP), the 66.7 ms bar, and the
verdict — **PROMOTE** iff weighted effective p50 ≥15 FPS on `coreml`
on this machine, **DISCARD** with documented fallback (options ranked:
keep onnxruntime-web WebGPU + cadence cuts; CPU-EP hybrid; reduced
model set; defer eyes) otherwise. `load_error`/`coreml_unbound`
outcomes belong in the verdict reasoning. `results/` (results.json +
REPORT.md + profiles/) is **committed** — it is the spike's
deliverable.
**Check:** `node measure.mjs --chain --ep coreml` + `node measure.mjs
--report` produce REPORT.md with every table populated and a one-line
verdict.
**Evidence:** `results/REPORT.md` + `results/results.json` +
`results/profiles/` under `EyeTracking/spikes/ort-node/`.

### M4 — acceptance, judge, handoff
**Change:** fill `.agent/acceptance/P2a.json` evidence; update this
file's Progress/Surprises/Retrospective/Handoff; PROGRESS.md entry;
the orchestrator creates branch `ship/v1-p2a` at implementation start
— stage owned paths by name → `check-owned-paths.py P2a` → milestone
commit → handoff commit.
**Check:** `python3 scripts/check-acceptance.py
.agent/acceptance/P2a.json --green` → all pass; `python3
scripts/check-owned-paths.py P2a` staged → OK.
**Evidence:** acceptance file + commit hashes.

## Acceptance mapping

| acceptance/P2a.json id | Milestone | Check layer |
|---|---|---|
| P2a-1 | M1 | contract |
| P2a-2 | M1 | unit (smoke) |
| P2a-3 | M2 | unit (smoke) |
| P2a-4 | M2 | contract |
| P2a-5 | M2 | contract |
| P2a-6 | M3 | contract |
| P2a-7 | M3 | contract |
| P2a-8 | M4 | judge review |

## Gates

- G1: plan presented to user for approval (pending — created
  2026-10-19).
- G2: milestone checks above are the contract — judge review of this
  file + P2a.json stands in (bounded spike, no cross-phase seams).
- G5: this phase IS a measurement — the 66.7 ms bar is its acceptance,
  not a separate bench run.
- G6: no UX surface — no human checklist.

## Model inventory (verified from source + introspected, M1)

| Model | Introspected input (name, dtype, resolved shape) | Role | Cadence (source) |
|---|---|---|---|
| `gaze_1x3x160x160.onnx` | `input` float32 [1,3,160,160] | estimate | every frame, unconditional — `inferenceWorker.ts:903`, tensor built `runtimes.ts:227` |
| `gaze_Nx3x160x160.onnx` | `input` float32 [N,3,160,160] → N resolved to **1** | off/unused | unreferenced by shipped defaults — `electron/main.cjs:357-371` loads `gaze_1x3x160x160` only |
| `mobileone_s0_gaze.onnx` | `input` float32 [1,3,448,448] | appearance | ~5 Hz — `appearanceChannel.maybeRun` `inferenceWorker.ts:897`, `APPEARANCE_PERIOD_MS=220` `core.ts:811` (~4.5 Hz, weighted 5); wasm-only in prod `runtimes.ts:142-157` |
| `retinaface_mbn025_with_postprocess_480x640_max1000_th0.70.onnx` | `input` float32 [1,3,480,640] | detect (default) | ≤1 Hz — `DETECT_INTERVAL_MS=1000` `inferenceWorker.ts:296,844-845`; default detector `electron/main.cjs:354-364` |
| `yolomit_t_wholebody28_1x3x480x640.onnx` | `images` float32 [1,3,480,640] | detect (alternate, `--detector yolo`) | ≤1 Hz — same `DETECT_INTERVAL_MS`; input name `session.inputNames[0]` `runtimes.ts:187` |
| `vsdlm_l.onnx` | `images` float32 [1,3,30,48] | lip | 0 — off unless `--enable-lip-motion && detector===yolo` `electron/main.cjs:372`, `inferenceWorker.ts:954-957` |

## Progress

- [x] M1 scaffold + inventory
- [x] M2 per-model × EP measurements + EP-binding proof
- [x] M3 chain + report + verdict
- [ ] M4 acceptance + judge + commits

## Surprises & Discoveries

- **G1 judge (fresh context, 2026-10-19) — FAIL→fixed.** The real
  pipeline is cadenced, not per-frame (`detect` ≤1 Hz,
  `appearance` ~5 Hz, only `estimate` unconditional —
  `inferenceWorker.ts:296,844-845,897,903,954-957`); the verdict's
  denominator is now the cadence-weighted effective cost, not a strict
  chain. Also fixed pre-implementation: `gaze_Nx3x160x160` symbolic
  batch dim (resolution policy added), no `load_error` vocabulary,
  profiling-on-timed-runs contamination (separate `--profile` pass),
  P2a-1's non-mechanical git-status check (recorded dirty baseline),
  missing `--report`/default-out/RSS cadence in the CLI spec.
- EyeTracking carries user-uncommitted dep changes
  (`onnxruntime-web` 1.26→1.30, `@litertjs/core` removed) — the spike
  is self-contained partly to avoid entangling them.
- `onnxruntime-node` latest stable is 1.30.0 — matching the user's
  ort-web upgrade exactly; no version drift to manage.
- The tracker's 90 s boot/head-detect cycling observed during P1 is
  irrelevant here — the spike measures model inference offline.
- **Spike verdict (measured 2026-10-19 on MacBookPro17,1 / M1 / 8 GB,
  node v26.8.1, ort-node 1.30.0): PROMOTE.** CoreML weighted effective
  chain p50 = **5.01 ms (≈200 FPS)** vs the 66.7 ms bar; strict
  all-models-per-iter = 20.82 ms. CPU EP effective = 151.78 ms (6.6 FPS);
  same-box single-thread wasm = 531.09 ms (1.9 FPS) — consistent with
  the remembered ~366 ms/frame wasm regime (gaze alone p50 456.5 ms).
  Caveat: `retinaface` **run_errors** under CoreML whenever NMS selects
  zero boxes (`{-1,3}` tensor arrives as `{0,3}` — CoreML EP rejects
  zero-element dynamic tensors), i.e. every no-face frame in production;
  the default detector must run on CPU EP (or the yolo variant on
  CoreML, which works: p50 9.90 ms). Detector-on-CPU fallback costs
  +2.68 ms weighted → effective ≈ 7.03 ms (≈142 FPS) — verdict
  unchanged. All models bind CoreML partially (bound/total: gaze_1 3/6,
  gaze_N 6/18, mobileone 3/3, retinaface 7/22, vsdlm 6/12, yolomit
  9/18; ORT assigns shape/Concat residue ops to CPU deliberately). Full
  tables: `EyeTracking/spikes/ort-node/results/`.
- `mobileone_s0_gaze` input is **[1,3,448,448]**, not 480² —
  `APPEARANCE_INPUT_SIZE = 448` (`core.ts:810`); introspection confirms.
- npm's global cache was EACCES on this machine — the spike installed
  with `npm install --cache /tmp/npm-cache-ort-node`; the committed
  lockfile is normal npm output.
- ort-node requires `profileFilePrefix` when `enableProfiling` is set,
  and ORT creates the 0-byte profile file at session-create (filled at
  `endProfiling`/release) — matching on a unique per-model prefix beats
  snapshot-diffing the cwd.
- `session.inputMetadata` is an array of `{name,isTensor,type,shape}`
  (not name-keyed, `shape` not `dimensions`) in ort-node 1.30.

## Decision Log

| # | Date | Decision | Why |
|---|---|---|---|
| 1 | 2026-10-19 | PROMOTE ort-node + CoreML EP as the v1 eye runtime path | Weighted effective chain p50 5.01 ms (≈200 FPS) ≤ 66.7 ms bar on the 8 GB M1 floor; strict 20.82 ms also under bar. Detector runs CPU EP (retinaface CoreML run_errors on zero-box NMS) or yolo variant; fallback verdict unchanged at ≈7.03 ms weighted. |

## Outcomes & Retrospective

The spike answered the phase's question decisively on the hardware floor
itself: CoreML EP under `onnxruntime-node@1.30.0` runs the production
pipeline's cadence-weighted effective per-frame cost at **5.01 ms p50
(≈199.6 FPS)** — 13× under the 66.7 ms / ≥15 FPS bar, on an
8 GB MacBookPro17,1 with node v26.8.1. Strict all-models-per-frame is
20.82 ms — still 3× under bar. The same-box wasm baseline (531 ms
effective, 1.9 FPS) confirms that ort-web wasm was never viable and that
the CoreML promotion is load-bearing, not marginal.

What worked: self-contained npm spike avoided the user's dirty
`package.json`/`pnpm-lock.yaml` entirely; dynamic model discovery +
input introspection caught a wrong remembered shape (mobileone is 448²
not 480²); the separate `--profile` pass proved real per-model CoreML
binding without contaminating timed runs; `load_error`/`run_error` row
statuses let the retinaface/CoreML fault surface as data instead of
aborting the spike.

What the spike found that no plan predicted: retinaface's fused NMS
**run_errors under CoreML on every zero-detection frame** — not a bench
artifact, a production path (any no-face frame). The detector therefore
runs CPU EP in the promoted architecture (or the yolo variant on
CoreML); the honest fallback still measures ≈7.03 ms weighted
(≈142 FPS). The judge's independent recomputation matched every number
exactly and flagged the misleading default-detector column, now fixed
(† footnote in REPORT.md).

## Handoff

**Verdict: PROMOTE** `onnxruntime-node` + CoreML EP for the v1 eye
runtime (Decision Log #1).

Measured on the floor machine (MacBookPro17,1 / M1 / 8 GB / node
v26.8.1), 20 warmup + 100 iters, seed 42:

| EP | effective weighted p50 | fps | strict p50 | weighted p95 | peak RSS |
|---|---|---|---|---|---|
| coreml | 5.01 ms | 199.6 | 20.82 ms | 7.99 ms | 557 MB |
| cpu | 151.78 ms | 6.6 | 454.19 ms | 177.27 ms | 379 MB |
| wasm (1-thread) | 531.09 ms | 1.9 | 1509.49 ms | 634.83 ms | 742 MB |

Artifacts (committed): `EyeTracking/spikes/ort-node/` —
`measure.mjs` (reproducible: `node measure.mjs --ep <cpu|coreml|wasm>
[--smoke|--chain|--profile|--report]`), `results/results.json`,
`results/REPORT.md`, `results/profiles/*.json` (per-model CoreML binding
proof).

What P8 should assume:

- **Architecture**: sessions on `onnxruntime-node` (not ort-web) with
  per-role EP choice — gaze estimate + appearance + lip on `coreml`;
  the **default retinaface detector on `cpu` EP** (CoreML faults on
  zero-box NMS output — every no-face frame; run_error is persistent,
  not transient). The `yolomit` detector variant binds+runs fine on
  CoreML (p50 9.90 ms) if detector choice is ever revisited.
- **Budget**: at 15 FPS cadence the whole model chain costs ~5–7 ms of
  the 66.7 ms frame budget — inference is NOT the bottleneck; camera
  capture, preprocessing (`createGazeInput`/`createRetinaFaceInput`
  crops), and calibration are where the remaining frame time lives.
  Those were out of spike scope (inputs were seeded noise; real-frame
  preprocessing cost is unmeasured).
- **Honesty caveats for P8's plan**: RSS numbers are per-session peaks
  within one process, not steady-state pipeline memory; spike inputs
  are seeded uniform noise — real frames may shift p50 modestly
  (mobileone/retinaface are detection-class nets where content affects
  postprocess load); `gaze_Nx3x160x160` was benched at N=1 and is
  unreferenced by shipped defaults.
- **P4 carryover (unchanged owner)**: the `--mcp-stdio` session-label
  wedge stays assigned to P4; this phase touched no daemon/session code.
