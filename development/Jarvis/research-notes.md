# Research notes — still-valid findings

Consolidated 2026-10-18 (P0 doc normalization) from the deleted files
`development/eyetracking-robustness-research.md` and
`development/eyetracking-facelandmarker-eval.md`. Point-in-time audits were
deleted outright; this file keeps only research that still informs P2a,
P8, P10, and P11. Sources cited at the bottom.

## 1. Webcam eye-tracking — honest accuracy math

- 1° ≈ 1.05 cm @60 cm ≈ ~38 px on 31.5" 2560×1440 (≈89 px/cm on 13" MBP
  Retina → same band is 0.2–0.65° there — harder).
- 20 px ≈ 0.5°: **below consumer IR** (Tobii IS5 p95-of-population
  1.71–1.76°). Not a sane webcam spec.
- Defensible spec: **p50 ≈55–90 px, p90 ≈100–160 px @QHD@60 cm**, tails
  worse under backlight/glare.
- Kappa angle (optical vs visual axis, ±5°, person-specific) is
  unremovable by image-only models — per-user calibration is the only
  fix → featuremap-v3 architecture is the right bet.
- Personalized systems in situ: PACE 2.56°, WebEyeTrack ~2.2°, SPAZE
  2.70° (9 samples). WebGazer uncontrolled eval: 10–13°. Within-dataset
  CNN SOTA ~3.9–4.1°; cross-dataset 5–10°.

### Validated as-is (don't churn)

- SaccadeAwareGazeFilter dispersion-window = GUIDe/Tobii US11915521
  pattern; better than One-Euro for assistive pointing.
- Dwell-lock anchor; bounded drift correction + ⌘⇧G escalation;
  EyeValidity blink machine; binocular coherence snap;
  constant-velocity coast ≤400 ms (I-KF territory).
- Pursuit label lag ~120 ms consistent with literature (~100–125 ms).

### Implemented (2026-10-16 round)

- Recency-weighted fixation mean (GUIDe); self-label suppression near
  click landings (COMETIC insight: idle-rest is weakest cue,
  click/commit strongest); tightened verify gates + gated corner
  regions; implicit refit O(n³)→closed-form LOO + capped pools;
  scale-invariant depth gate; squint mid-band release; jaw baseline
  gated on speech.

### Deferred / needs A-B (ordered by leverage)

1. **Per-crop contrast normalization** — `createGazeInput` only
   `/127.5-1`; percentile-stretch or CLAHE on the 160² crop is the
   highest-leverage lighting mitigation (+14% detection low-light, Kim &
   Hong'13). Shifts input statistics vs training dist → MUST A/B via
   `--accuracy-test` before adopting.
2. **Glare/saturation gating** — saturated-pixel fraction in eye boxes →
   fold into confidence product or emitHold. Free compute; covers
   glasses-glare tail.
3. **Camera controls** — MediaTrackConstraints
   exposureMode/exposureCompensation; locked exposure prevents
   auto-exposure hunts during head motion.
4. **Appearance model provenance** — `mobileone_s0_gaze.onnx` is
   Gaze360-trained (±140° outdoor, 12.58° MAE) vs our frontal ±25°
   regime. An MPIIGaze/MPIIFaceGaze-domain replacement is plausibly a
   real improvement; verify provenance hash first. Second-order to
   featuremap adaptation.
5. **Implicit refit cadence** ≥90 s→~60 s defensible (adoption gate
   protects the map, not the interval).
6. **Feature lag** at click labels: eye arrives ~200 ms pre-click; could
   tighten featureAt to 300–400 ms pre-rest.

### Dwell UX (evidence) — relevant to P11

- Static dwell: **500–600 ms** sweet spot (Helmert'08; Paulus &
  Remijn'21). <450 ms double-triggers novices.
- Dynamic dwell > static (meta-analysis); short ~450 ms frequent
  targets, ~800 ms destructive.
- Apple Dwell Control patterns to copy: movement tolerance px,
  **post-action re-arm tolerance** (must leave/re-enter before refire),
  conservative 2–3 s default.
- MAGIC pointing (Zhai CHI'99): gaze warps + second channel commits —
  our lip-click/implicit_sample is this pattern; keep bimodal.

### Not supported by evidence — don't claim

- <1.5° sustained webcam accuracy. Dead reckoning past ~500 ms (saccades
  are ballistic; snap-on-landing is correct because saccadic suppression
  hides it). Click/dwell labels alone fixing >0.09 regional bias (needs
  drift path or quick recal — both exist). Jaw-robust features
  (plausible, unbenchmarked). FaceLandmarker upgrade (same signal class
  as existing mesh — see §2).

## 2. MediaPipe FaceLandmarker eval — verdict: HOLD

Evaluation only, 2026-10-12. Queue as the first robustness spike **if**
calibration plateaus or blink/pose artifacts dominate the error budget —
not a standing dependency.

- **Package**: `@mediapipe/tasks-vision` 1.1.0 (2026-10-06), Apache-2.0
  incl. weights; nightly-RC cadence — pin, never float.
- **Cost**: ~+17 MB shipped (13 MB wasm + 3.6 MB `face_landmarker.task`);
  a whole second inference engine in the worker. Inference ≈ BlazeFace +
  256² mesh + MLP: 5.2 ms median GPU / 6.1 ms WASM on M4 Pro (third-party
  bench); extrapolated ordinary-laptop wasm ~10–25 ms/call. Viable only
  at AppearanceChannel-style cadence (~5–10 Hz, ≤10% duty ≈1–2.5 ms
  amortized) — not full frame rate.
- **What it buys**: metric head pose (4×4 Procrustes matrix — attacks
  the "changing head position" error term our yaw/pitch proxies only
  approximate); trained blink/aperture blendshapes (independent of the
  gaze model's `depthHealthy` collapse mode); jaw/mouth for free (could
  retire `vsdlm_l` lip-motion); independent iris source; fallback
  detector (bundled BlazeFace self-tracks via ROI).
- **What it does NOT add**: a gaze vector — iris-center-in-eye-box is a
  feature, not a direction; per-user regression remains the binding
  constraint, and featuremap-v3 already has one. Its 5-pt iris ring is
  sparser than our 8-pt contour + eyeball center (481 pts/eye).
- **Accuracy context**: MediaPipe-landmark gaze pipelines post-
  calibration land at 1–3° (FaceMesh+regression 1.12–1.3°; Enhanced Gaze
  Tracker 3.2°; EMC-Gaze 2.9–5.8°; WebGazer ~4.2°) — edge of our target,
  not inside it. Value is **robustness at the tails**: pose extremes,
  blink transitions, jaw drift, detector loss.
- **Production analogs**: Google Project Gameface (assistive cursor),
  OCULA (AAC), peekr (Stanford — closest public analog: FaceMesh + ONNX
  gaze in a worker, 9-pt calibration, Kalman), webcam_gaze_webapp
  (13-dim feature → kernel ridge + ~500-sample pursuit — same
  feature→regression→screen design as featuremap-v3).
- **Spike criteria if approved**: `--accuracy-test` 9-pt held-out A/B;
  integrate only if mean/p95 px error improves ≥~15% or it measurably
  rescues a known tail (depthHealthy collapses, blink-transition holds,
  head-turned frames) — otherwise hold permanently. Flag-gated like
  `--no-appearance-model`.
- **Uncertainty**: no public FaceLandmarker-vs-160²-eye-mesh gaze
  head-to-head; GPU delegate inside an Electron worker unverified
  (assume CPU); trained `eyeBlink` vs mesh-EAR + state machine
  unproven; MediaPipe wasm is opaquer than our ONNX sessions.

## Sources

Krafka CVPR'16 (iTracker); Papoutsaki IJCAI'16 + JEMR'25; MPIIGaze
TPAMI'19 + L2CS/RAGE-net/AGE-Net; Huang CHI'16 PACE; Wang CHI'25
COMETIC; WebEyeTrack arXiv:2508.19544; Pfeuffer UIST'13; Ramirez Gomez &
Gellersen ETRA'18 Smooth-i; Tripathi & Guenter WACV'17 GPR; Hornof &
Halverson BRMIC'02 RFL; Lindén ICCVW'19 SPAZE; Kumar/Klingner GUIDe
ETRA'08; Casiez CHI'12 1€; Komogortsev & Khan EICS'09 I-KF; Model &
Eizenman TBME'10; Tobii IS5 datasheet; ETRA'21 sunlight study; Kim &
Hong'13 CLAHE; FAZE ETRA'24; Helmert'08; Paulus & Remijn'21; Zhai CHI'99
MAGIC; IEEE 10752957; arXiv 2603.12388 EMC-Gaze; mediapipe/tasks-vision
npm + GitHub issues #6098 #5828 #5479 #5130 #5169.
